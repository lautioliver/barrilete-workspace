# ADR-002 — Retroalimentación local del ruteo de agentes

## Estado

Propuesto

## Contexto

Codex supervisa las corridas de agentes y propone cómo repartir tareas entre proveedores y modelos. Para que la persona pueda entender esas decisiones y Codex pueda usar evidencia en repartos posteriores, BK necesita registrar qué opciones había, qué eligió, por qué y qué resultado tuvo cada tarea.

El aprendizaje de ADR-007 mide reglas del proyecto y puede guardarse en una rama de datos. Este registro tiene otro propósito: orientar el ruteo de agentes de esta instalación de BK. No debe heredar la opción de publicación de ADR-007 ni enviar datos a otra máquina.

## Decisión propuesta

1. **Store local exclusivo.** Guardar los eventos en `${XDG_STATE_HOME:-~/.local/state}/bk/routing/`, fuera del repositorio. No sincronizar, publicar ni replicar estos datos por Herdr. El dashboard local lee ese mismo store. El proveedor del modelo sigue recibiendo solo el resumen mínimo que BK le entrega para decidir.
2. **Dos eventos append-only**, JSONL UTF-8, con `v: 1`, timestamp UTC y campos cerrados. Rechazar claves desconocidas y valores fuera de catálogo; no guardar texto libre.
3. **Evento `dispatch`** — una fila por tarea propuesta:

   | Campo | Contenido |
   |---|---|
   | `event_id`, `ts`, `v`, `kind` | UUID local, timestamp UTC, `1`, `dispatch` |
   | `run_id`, `task_id` | UUID locales opacos; nunca incluyen título, repo o persona |
   | `issue`, `task_type`, `area`, `priority`, `critical` | Número de issue, tipo (`feature`, `fix`, `hotfix`, `review`, `documentation`, `refactor`, `other`), área (`agents`, `cli`, `herdr`, `docs`, `infra`, `other`, `unknown`), prioridad y booleano crítico |
   | `risk_flags` | Lista sin repetidos de `business_logic`, `sensitive_path`, `hotfix` o `security` |
   | `eligible` | Candidatos considerados: cada uno tiene `provider`, `model_id`, `harness`, `role`, `active_slots` y `evidence_n` |
   | `selected` | Proveedor, modelo, harness y rol propuestos |
   | `reason_code`, `reason_detail_code` | razón general (`affinity`, `load_balance`, `exploration`, `hotfix`, `manual`, `fallback`) y detalle de catálogo cerrado (`model_affinity`, `role_affinity`, `known_success`, `lower_load`, `slot_available`, `low_sample`, `explicit_exploration`, `hotfix_priority`, `user_selected`, `provider_unavailable`, `policy_fallback`, `unknown`) |
   | `evidence_window_days` | Cantidad de días del resumen usado; `evidence_n` conserva la muestra por candidato |
   | `approval` | `pending`, `approved`, `overridden` o `rejected`; el lanzamiento no ocurre antes de aprobación humana |
   | `override_code` | Código cerrado (`human_choice`, `candidate_unavailable`, `policy_gate`, `rejected`, `other`) obligatorio con `approval: overridden` o `rejected`, prohibido con `pending` o `approved` |

4. **Evento `outcome`** — una fila al cerrar o cancelar la tarea, enlazada por `task_id` y `run_id`:

   `status` (`completed`, `failed`, `incomplete`, `cancelled`), `result_kind` (`pr`, `blocked`, `escalated`, `dropped`, `question`), proveedor, modelo y harness realmente usados, `duration_s`, `review_rounds`, `blockers_count`, `ci_first_pass`, `merged` (solo si se conoce; `null` si no está disponible al cierre), `human_interventions`, `context_compactions`, `fresh_sessions`, `context_peak` y `context_source` (`harness`, `provider`, `unknown`). Las medidas que el harness no expone admiten `null`. Registrar modelo/harness reales para atribuir el resultado, incluso si difieren de la propuesta.

5. **Privacidad por minimización.** Nunca registrar prompts, respuestas, títulos de issues, nombres de personas o clientes, paths, contenido de archivos, diffs, transcript, credenciales, ni texto libre. Issue/PR son números; el repo no se guarda en el evento ni se transmite al proveedor. UUID opacos separan tareas de distintos repos.
6. **Resumen previo al despacho.** BK construye un JSON versionado para Codex con fecha de corte, candidatos disponibles, carga y conteos agregados por `provider × model_id × task_type` (y área solo cuando la celda alcanza `n ≥ 20`), tasas observadas y tendencia. Cada celda devuelve `n` y `evidence_level`: `insufficient` (`n < 20`), `exploratory` (`20 ≤ n < 50`) o `established` (`n ≥ 50`). Sin muestra suficiente, Codex conserva el ruteo seguro vigente y puede proponer exploración solo en tareas no críticas. El resumen no contiene eventos individuales ni texto de negocio.
7. **No inventar precisión.** La primera versión informa resultados por separado: éxito limpio, escalados, rondas de review, duración e intervención humana. No combina todo en un score único. La UI muestra `n`, ventana temporal, cobertura de datos y valores desconocidos junto a cada métrica. La evidencia es `insufficient` para `n < 20`, `exploratory` para `20 ≤ n < 50` y `established` para `n ≥ 50`. Una muestra pequeña no crea una preferencia automática. El ruteo adaptativo requiere una decisión posterior basada en datos.
8. **Contexto de agentes.** Guardar uso y reinicios solo cuando el harness los reporte de forma fiable; no inferir tokens ni equiparar ventana de contexto con caché del proveedor. Rotar a una sesión nueva es un evento operativo ligado a la misma tarea/worktree/lease, no una tarea nueva.
9. **Retención.** Conservar eventos individuales durante 180 días. Al vencer ese plazo, compactarlos en agregados locales por proveedor/modelo/rol/tipo de tarea/área y ventana mensual, y eliminar las líneas individuales vencidas. Los agregados mantienen conteos de conocidos/desconocidos y no incluyen identificadores de corrida, tarea, issue o repo.

## Contrato de entrada para Codex

El resumen previo al despacho debe incluir exactamente:

```json
{
  "schema": "bk.routing-context.v1",
  "as_of": "2026-11-27T00:00:00Z",
  "task": {
    "type": "fix",
    "area": "agents",
    "priority": "normal",
    "risk_flags": [],
    "critical": false
  },
  "constraints": {
    "implementer_limit": 3,
    "active_implementers": 1,
    "review_limit_per_pr": 1,
    "human_approval_required": true
  },
  "candidates": [
    {
      "provider": "claude",
      "model_id": "claude-sonnet-5-5",
      "harness": "claude-code",
      "role": "implementer",
      "active_slots": 1,
      "evidence": {
        "n": 12,
        "level": "insufficient",
        "clean_success_rate": null,
        "median_duration_s": null,
        "escalation_rate": null,
        "review_rounds_median": null,
        "human_interventions_median": null,
        "trend": "unknown"
      }
    }
  ],
  "policy": {
    "adaptive_routing": false,
    "exploration_allowed": true,
    "exploration_rate": 0.1
  }
}
```

Los valores de ejemplo son ilustrativos. `model_id` debe ser la versión exacta del catálogo/sesión; si no se conoce, se usa `unknown` y esa corrida no se mezcla con versiones identificadas. `clean_success_rate` significa tarea completada con PR mergeado, sin escalado y con no más de una ronda de review; si `merged` aún no se conoce, queda `null`.

`run_id` y `task_id` son UUID opacos generados por BK, y `model_id` admite un ID de catálogo con un namespace opcional (`proveedor/modelo`). `bk routing dispatch` recibe por stdin un objeto con los campos de tarea anteriores, `evidence_window_days`, `eligible`, `selected`, `reason_code`, `reason_detail_code` y `approval`; `critical` es booleano. Cada candidato de `eligible` lleva `provider`, `model_id`, `harness`, `role`, `active_slots` y `evidence_n`; `selected` debe coincidir con uno de esos candidatos. `bk routing outcome` recibe `run_id`, `task_id`, `status`, `result_kind`, modelo/harness/proveedor reales y las medidas listadas arriba. Las medidas no disponibles se envían como `null`. Ambos comandos rechazan claves desconocidas y valores fuera de catálogo. `bk routing summary` informa la ventana reciente, suprime el área cuando `n < 20` y conserva los agregados mensuales; `bk routing compact [--dry-run]` aplica la retención de D9 a mano y `bk routing aggregates` muestra el archivo agregado. `--dry-run` en `dispatch` y `outcome` solo valida el objeto.

Codex devuelve una propuesta estructurada con `selected`, `reason_code` y `reason_detail_code` (catálogo cerrado). BK valida que el candidato exista, haya slot y cumpla las barandas; la persona confirma o corrige antes del lanzamiento. El texto explicativo para la persona puede generarse en la interfaz, pero no se persiste como texto libre.

## Cómo se cumple la retención

Implementación acordada de D9:

- **Unidad: la tarea.** Una tarea (`run_id` + `task_id`, con sus `dispatch` y `outcome`) se compacta entera cuando vence su línea más vieja. Ninguna línea pasa los 180 días; las más nuevas de esa tarea se borran antes y salen antes de la ventana de `summary`. Así el `outcome` se compacta junto a su `dispatch` y conserva rol, tipo y área aunque la tarea cruce el límite.
- **Agregados** (`aggregates.json`, `schema: bk.routing-aggregates.v1`): celdas por mes (`AAAA-MM` del evento) y proveedor/modelo/harness/rol/tipo/área. Los `outcome` guardan `n`, conteos por `status`, `result_kind` y `context_source`, éxito limpio y su cobertura, y por cada medida conocidos, desconocidos, suma, mínimo y máximo; `review_rounds`, `human_interventions` y `blockers_count` guardan además un histograma (de `0` a `9`, y `10+`), y `duration_s` un histograma exacto, para poder sacar medianas de varios meses. Los `dispatch` guardan `n` por candidato elegido, prioridad, crítico, `reason_code`, `reason_detail_code`, `approval` y `override_code`, más los conteos de `risk_flags` y de candidatos. Sin `run_id`, `task_id`, `event_id`, issue ni repo.
- **Cuándo:** `dispatch`, `outcome` y `summary` compactan antes de escribir o leer, y `bk routing compact` lo hace a mano (`--dry-run` solo cuenta). No hace falta un proceso programado.
- **Concurrencia:** toda lectura y escritura del store toma un `flock` exclusivo (`.lock`). Un `append` nunca se mezcla con una reescritura.
- **Idempotencia y cortes:** `aggregates.json` lleva una `generation`. La compactación escribe primero el archivo de eventos nuevo completo (`events.jsonl.gen-<G+1>`), después reemplaza `aggregates.json` con `G+1` (el punto de commit) y al final renombra el de eventos. Si se corta, la próxima operación termina el renombre (si el commit pasó) o borra el archivo pendiente (si no). Sin nada vencido no escribe nada. Un `aggregates.json` ilegible frena toda escritura en vez de pisarlo.
- **Líneas rotas:** las que no son un evento v1 válido (sin `ts` UTC, JSON cortado) se borran al compactar, porque no se pueden fechar ni contar. El reporte dice cuántas.

La retención se aplica por tarea: al vencer el evento individual más viejo, se compactan y eliminan juntos todos sus eventos, incluso los más nuevos. Por eso algunos duran menos de 180 días. Esta decisión conserva la relación dispatch/outcome sin guardar IDs en los agregados.

## Alternativas descartadas

- Reutilizar ADR-007: permite un store de rama, mide reglas y tiene otro umbral; mezclar ambos dominios podría publicar telemetría local.
- Guardar razonamientos o prompts completos: mejora la explicación superficial, pero conserva contenido de negocio y puede enviarlo al proveedor; se eligen códigos y agregados auditables.
- Un score compuesto desde el primer día: oculta qué dimensión cambió y magnifica muestras pequeñas; primero se presentan métricas separadas.
- Medir contexto por estimación común a todos los proveedores: los harnesses exponen datos distintos y algunos no exponen ninguno.

## Consecuencias

- El usuario puede inspeccionar cada propuesta y la evidencia agregada, y Codex puede recibir el mismo resumen estructurado en cada corrida.
- Los modelos nuevos parten sin evidencia suficiente y no desplazan automáticamente una opción probada.
- La retención acordada es de 180 días para eventos individuales, con compactación mensual local. Está en `lib/routing_feedback.py` (ver *Cómo se cumple la retención*). Habilitar el registro continuo sigue esperando los gates de ADR-003 (despacho real, lease global).
- Este ADR define el contrato de datos, no aprueba por sí solo el despacho autónomo, el scheduler global, los hooks de nuevos proveedores ni cambios a las aprobaciones humanas.

## Decisiones cerradas en esta revisión

- `merged` se registra como `null` cuando no se conoce al cierre. Consultarlo desde GitHub queda fuera de la primera versión.
- Los eventos individuales se compactan por tarea al vencer el más viejo; ninguno supera 180 días y algunos se eliminan antes. Los agregados mensuales locales no contienen IDs de corrida, tarea, issue o repo.
