# ADR-003 — Supervisión local, bus de coordinación y leases globales

## Estado

Propuesto

## Contexto

Boceto visual del modelo: [supervisión local de agentes](supervision-local-y-leases.html).

El flujo actual organiza agentes en torno a un orquestador y a la interacción visible con la persona. El piloto agrega un supervisor Codex que puede coordinar orquestadores de varios proveedores, más de un implementador simultáneo y subagentes que hoy pueden quedar fuera del conteo y la atribución. El feedback de ruteo de ADR-002 es local. Esta rama agrega un árbitro previo al lanzamiento y el estado y las transiciones de leases, pero ningún adaptador de harness verificado: no hay leases vivos, recuperación de workers ni identidad de aprobación humana validada por harness.

## Decisión propuesta

1. **Estado de coordinación por máquina.** El supervisor lee y escribe el estado operativo en `${XDG_STATE_HOME:-~/.local/state}/bk/supervisor/`, separado del store de métricas de ADR-002 (`bk/routing/`). El alcance propuesto incluye propuestas, asignaciones, leases y eventos breves de hito con claves cerradas. La implementación actual guarda planes, reservas, leases y eventos de plan y de lease; no registra actividad de workers porque ningún adaptador puede iniciar un lease todavía. No se guarda en el repo, learning ADR-007, Herdr ni un servicio remoto. Herdr puede seguir mostrando el estado que ya publica, pero no recibe ni replica este estado nuevo.
2. **Codex supervisa por defecto.** Codex Supervisor puede proponer asignaciones, leer el bus local, arbitrar conflictos y pausar o replanificar. No implementa por su rol de supervisor, no aprueba en nombre de la persona, no mergea ni publica. El plan completo se muestra a la persona y requiere su aprobación explícita antes del primer lanzamiento.
3. **Orquestadores de proveedor.** Claude Opus y Agy Neon reciben tareas independientes, sin duplicar issues; delegan implementación a trabajadores de su proveedor y reportan hitos breves y códigos cerrados. No editan como implementadores. El rol `documentation` usa un proveedor Codex y entrega su reporte al supervisor. Hydrogen corre como implementador-light independiente de `bk` para poder atribuir tarea, worktree, lease y métricas; no corre oculto como subagente de Neon. SerHigh-Q y Hydrogen pueden ser lectores rápidos de archivos pesados solo después de validar sus IDs exactos en los catálogos.
4. **Árbitro y reserva antes del lanzamiento.** Un único archivo de estado JSON se modifica bajo un lock de sistema local (`flock`) y se reemplaza atómicamente. En la aprobación del plan, el árbitro reserva el issue y los slots requeridos antes de lanzar cualquier proceso. Cada implementador, incluido cada subagente y relanzamiento, posee un lease propio con `run_id`, `task_id`, proveedor/modelo/harness/rol, worktree y marca de heartbeat. El mismo recurso no puede recibir dos leases activos. No se inicia una tarea si no se puede adquirir issue y slot juntos.
5. **Límites globales.** Como máximo hay tres implementadores activos contando proveedores, subagentes internos y relanzamientos. Hay como máximo una revisión activa por PR. Una tarea hotfix entra a una cola prioritaria; espera un slot, nunca interrumpe un trabajo en curso, y luego corre un implementador seguido por un revisor.
6. **Aprobación humana no falsificable por una tarea.** `bk say` y `bk approve` solo se aceptan desde una terminal humana separada, fuera del chat o árbol de procesos de un agente. El hook de Bash los bloquea en invocaciones de herramientas de agentes y el CLI comprueba el árbol de procesos y la ausencia de `BK_TASK_DIR`. Un mensaje, texto de plan o evento del bus no es aprobación. Son guardrails de aplicación, no aislamiento del sistema operativo; la validación por harness debe comprobar que la sesión no pueda rodearlos mediante otro proceso. Si esa frontera no se sostiene, no se habilitan lanzamientos reales.
7. **Adaptadores y atribución.** Cada adaptador identifica en el evento el proveedor, el modelo exacto y el harness realmente usados. Una integración sin identidad comprobable devuelve `unknown`, no inventa atribución. Agy necesita adaptador propio para estado, eventos y barandas. Codex en vivo y sus hooks se validan antes de contar con ellos para guardar estado o proteger comandos. `task_events.py` y guardrails deben cubrir las herramientas reales que puede invocar cada harness.
8. **Contexto y reinicios.** Solo se compacta o crea una sesión nueva en un checkpoint seguro. Se conserva `run_id`, issue, worktree y lease; el nuevo proceso recibe el checkpoint mínimo de la misma tarea. Un lector de archivos pesados trabaja en sesión fresca y devuelve hallazgos acotados. Un chat nuevo no se cuenta como limpieza de caché del proveedor.
9. **Revisión y gates existentes.** Se mantiene GitHub, worktrees, PR y `main` protegido. Se conserva la revisión cruzada cuando hay un revisor disponible. Las rutas sensibles y lógica de negocio siguen sus gates; la aprobación de una tarea o propuesta no sustituye la aprobación humana requerida para esas acciones.

## Relación propuesta con ADR-004 y ADR-005 del kit

- **ADR-004:** ampliar el actor orquestador singular a un supervisor y orquestadores de proveedores paralelos; conservar que la persona aprueba el plan y los traspasos, y enmendar D4 para que `bk say` y `bk approve` se ejecuten desde una terminal humana separada, nunca desde el chat/sesión agente. La decisión de asignar un rol a `bk` o subagente queda subordinada al lease global y debe incluir subagentes internos en el conteo.
- **ADR-005:** extender el contrato de tarea para representar `run_id`, proveedor/harness/modelo real, lease, heartbeat, worktree y atribución de subagentes. La reserva del issue ocurre al aceptar el plan, antes de crear o lanzar la tarea. Los estados `pending` y el cierre de `bk done` continúan siendo fuente de estado de tarea, no prueba de aprobación humana.
- Estas enmiendas requieren propuesta al equipo del kit; este ADR de proyecto no modifica ni reemplaza los ADR aceptados del kit.

## Barandas para habilitar corridas reales

No se habilita el piloto con agentes reales hasta completar y verificar el ciclo de leases (incluida la liberación/recuperación); validar que el límite global incluya todos los subagentes; probar la reserva de issue y slots en carreras concurrentes; verificar por harness el bloqueo de aprobación emitida por una tarea y la cobertura de hooks por herramienta; implementar el adaptador Agy; y acordar enmiendas a ADR-004/005. También se confirma que el estado existente visible entre máquinas de Herdr no transporte el nuevo bus.

## Implementación presente en esta rama

`bk supervisor propose|approve|status|cancel` valida planes cerrados, presenta la aprobación en terminal interactiva, reserva issue/PR y slots bajo `flock`, y deja excedentes en cola con prioridad hotfix. El estado se reemplaza atómicamente y los eventos de plan se retienen 30 días. Los planes impiden duplicar recursos dentro de sí mismos y entre reservas. Cada asignación reservada lleva su lease en `state.json` y el slot se cuenta por lease activo (`reserved`, `running` o `stale`), así que subagentes y relanzamientos, que son asignaciones explícitas, ocupan slot. `lib/supervisor.py` implementa las transiciones del contrato de abajo: `start_lease`, `heartbeat_lease` y `finish_lease` son la entrada para un adaptador futuro y no se exponen en el CLI; `bk supervisor reconcile` marca `stale` y libera solo con salida verificada; un heartbeat verificado devuelve un lease `stale` a `running`. La verificación de proceso compara PID y hora de inicio (`ps -o lstart=` con `TZ=UTC`); la de sesión la da el adaptador del harness (`HARNESS_ADAPTERS`), que hoy está vacío. Sin adaptador, todo inicio, cierre o liberación se rechaza y el lease conserva issue y slot. `cancel` solo procede si ningún lease arrancó. Esta etapa no lanza procesos ni recibe hitos de orquestadores, y no satisface por sí sola los gates de lanzamiento.

## Contrato propuesto para el ciclo de lease

Cada asignación aprobada ya lleva un `lease_id` opaco. El adaptador futuro será responsable de enlazarlo con una tarea y proceso concretos; los comandos de ciclo de vida no deben confiar en un `run_id` aislado como prueba de identidad.

```text
pending --aprobación humana--> reserved --inicio confirmado por adaptador--> running
   |                              |                                          |       |
   +--aprobado sin slot--> queued  +--cancelación antes del inicio           |       +--heartbeat ausente 5 min--> stale
                                  ^                                          |       ^                              |
                                  |                                          |       +--heartbeat de la misma ------+
                                  |                                          |          identidad, proceso y harness vivos
                                  +------ promoción al liberar slot          +--cierre verificado                    +--proceso y harness ausentes
                                                                                         |                             verificados
                                                                                         v                                  |
                                                                                    completed                              v
                                                                                                                          released

pending, queued o reserved --cancelación antes del inicio--> cancelled
```

- La reserva toma issue/PR y slots como una sola operación atómica. Los subagentes y relanzamientos son asignaciones explícitas y cuentan en el límite de tres; un proceso orquestador no consume slot.
- El adaptador actualiza `last_heartbeat_at` cada 60 segundos dentro del estado bajo el mismo `flock`. Los heartbeats actualizan estado, no agregan una línea al bus cada minuto. Al superar cinco minutos, `reconcile` marca `stale`; no libera recursos. Si después llega un heartbeat con el mismo PID, la misma hora de inicio y la misma sesión, y el adaptador confirma que el proceso y la sesión del harness siguen vivos, el lease vuelve a `running` (limpia `stale_at`) y escribe `lease_recovered`; es el caso de una máquina que se suspendió. Otra identidad, o una sesión ausente o no verificable, lo deja `stale`.
- Para permitir `completed` o `released`, el adaptador debe acreditar identidad de proceso (PID más hora de inicio) y ausencia tanto del proceso como de la sesión del harness. Que el PID haya desaparecido no basta si el harness o un subagente puede seguir vivo. Identidad o estado no verificables mantienen el lease `stale`, conservan issue y slot, y requieren intervención humana.
- Los hitos persistidos usan códigos cerrados (`lease_started`, `lease_stale`, `lease_recovered`, `lease_completed`, `lease_released`) sin heartbeat por evento ni texto libre. El estado terminal y los hitos se purgan a los 30 días; leases activos o `stale` no vencen por retención.
- `pending`, `queued` y `reserved` pueden cancelarse antes del inicio. No se ofrece `force release` mientras no exista una verificación confiable del adaptador. El cierre de tarea informado por `bk done` no prueba por sí solo que el proceso haya terminado.

Este contrato sigue propuesto hasta validar cómo cada harness acredita identidad, sesión y subagentes. El código implementa estas transiciones, pero sin un adaptador registrado ninguna pasa de `reserved`; el CLI solo expone `reconcile`.

## Propuesta concreta para revisión (no aceptada)

Los valores de heartbeat, stale y retención fueron confirmados por Lautaro en el chat el 2026-11-27. El resto sigue como propuesta; esto no habilita lanzamientos ni cambios a hooks o permisos.

1. **Lease y heartbeat (valores confirmados).** El adaptador renueva el lease cada 60 segundos. A los 5 minutos sin heartbeat pasa a `stale`, pero no libera el issue ni el slot automáticamente. El supervisor verifica identidad de proceso (PID más hora de inicio) y estado del harness; solo libera si confirma que el proceso terminó, y escribe un evento `lease_released` con código cerrado. Si la identidad no se puede verificar, mantiene la reserva y pide intervención humana. No se reutiliza un lease ambiguo: un lease `stale` solo vuelve a `running` con la misma identidad (PID, hora de inicio y sesión) y con el proceso y el harness confirmados vivos.
2. **Aprobación humana (flujo confirmado; validación pendiente).** La persona ejecuta `bk say` o `bk approve` desde una terminal humana separada, fuera del chat o árbol de procesos del agente. El hook niega esos comandos en herramientas de agente; el CLI rechaza una tarea activa o un árbol de procesos de harness. El gate está implementado en esta rama, pero debe validarse por harness y no se considera aislamiento contra un proceso que logre escapar del árbol de agente.
3. **Límite global (alcance ya acordado).** Máximo tres implementadores, contando subagentes internos y relanzamientos. El reviewer queda fuera de esos slots y tiene un límite de una review activa por PR. Los procesos orquestadores no consumen slots.
4. **Bus y retención (valores confirmados).** `state.json` mantiene propuestas y leases vigentes; al cerrar una tarea conserva solo su estado terminal durante 30 días. `events.jsonl` es append-only, usa códigos cerrados y no contiene texto libre; conserva hitos 30 días y se compacta/elimina localmente al vencer. Una última línea sin fin de línea (una alta cortada a mitad) no es un evento: se descarta y la próxima alta la corta; una línea inválida completa sigue frenando. Nada se replica por Herdr, ADR-007, Git o servicio remoto. No se almacenan prompts, respuestas ni transcripciones.
5. **Evidencia de adaptadores.** Antes del primer lanzamiento, una verificación documentada por harness debe probar: identidad del modelo usado, lectura/publicación del bus local, cobertura de guardrails para todas las herramientas de escritura/aprobación, rechazo de aprobación desde tarea, recuperación de leases y cumplimiento de los límites en una carrera concurrente. Los IDs exactos se copian de catálogos consultados en vivo; sin dato verificable se registra `unknown` y no se usa ese adaptador para despacho.

## Preguntas abiertas

- ¿Quién acepta y coordina las enmiendas de ADR-004/005 en el kit? Este repo solo propone el cambio; no reemplaza los ADR aceptados ni autoriza cambios al kit.
- ¿Qué prueba en vivo acredita Codex y qué versiones de Agy/Hydrogen/SerHigh-Q se consideran IDs exactos del catálogo?

## Decisiones confirmadas en el chat

- 2026-11-27: `bk say` y `bk approve` se ejecutan desde una terminal humana separada, fuera del chat o sesión del agente. El flujo `! bk say` dentro del chat deja de usarse.
- 2026-11-27: heartbeat cada 60 segundos; lease `stale` tras 5 minutos sin señal, sin liberación automática; estados terminales e hitos del bus con retención de 30 días.
- 2026-11-28: un lease `stale` vuelve a `running` con un heartbeat de la misma identidad (PID, hora de inicio y sesión) si el adaptador confirma el proceso y la sesión vivos; deja un hito `lease_recovered`. Cualquier otra cosa lo mantiene `stale`.
- El límite global de tres implementadores y una review activa por PR ya estaba acordado en el handoff.

## Consecuencias

- La reserva única evita que dos orquestadores asignen el mismo issue o excedan los slots por carrera.
- La supervisión local conserva atribución común entre sesiones y proveedores, sin convertir el bus en un canal de sincronización de Herdr.
- La frontera de aprobación quedó definida como una terminal humana separada; su rechazo desde cada harness, la resistencia a escapes de proceso y la recuperación de leases deben validarse antes de la ejecución.
- Este documento propone el modelo; no activa asignación automática, lanzamientos, cambios de hooks ni cambios en los ADR del kit.
