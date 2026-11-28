# barrilete-workspace

Workspace personal de agentes sobre [Barrilete Kit](https://github.com/lautioliver/barrilete-kit), manejado desde la terminal.
Los agentes corren en tmux o Herdr; `bk ls`, la tira y `bk monitor` muestran su estado (rol, modelo, issue) y `bk checkpoints`, lo que te espera. Cursor Agent abierto en una terminal de Herdr también se adopta como ventana de agente.

```
bk                 (workspace)      bk s             (sesiones)
bk plan "<idea>"   bk run <issue>   bk review <pr>   bk fix <pr> "…"   bk orchestrate
bk ls              bk go <ventana>  bk stop <ventana>  bk clean [--yes]
bk peek [ventana]  bk say <ventana> "…"   bk watch [ventana|--all]
bk monitor         bk checkpoints   bk tasks         bk done <resultado>   bk approve <tarea>
bk account         bk account use <cuenta> [--relaunch]   bk run … --account <cuenta>
bk machines sync [--dry-run]
bk roles           bk mode <rol>    bk profile [perfil]  bk song [estación]   bk theme [day|night|auto]
bk ask [tarea "…"] bk models [provider]
```

## Workspace (`bk`)
Uno por proyecto: `bk` en la carpeta de un proyecto abre (o retoma) la sesión tmux `bk-<proyecto>`;
`bk open <proyecto|ruta>` lo abre en una ventana nueva de Ghostty, en el escritorio donde estás.
Así cada escritorio de macOS tiene su proyecto. El riel, el footer y `alt+a` muestran solo los agentes,
cambios y tokens de ese proyecto (el repo y sus worktrees `<repo>-wt/*`); los agentes
siguen todos en la sesión `agents`. `bk open` sin argumento lista los workspaces abiertos.

```
┌──────────────────────────┬──────────────────┐
│                          │ agentes en vivo  │
│  chat · orquestador      │ (bk watch --all) │
│  (claude)                ├──────────────────┤
│                          │ radio            │
└──────────────────────────┴──────────────────┘
```

- **Chat**: un `claude` donde hablás con los agentes (mensajes entre sesiones) y les respondés con `bk say`.
- **Agentes en vivo**: un panel que se reparte entre los agentes que trabajan (encabezado con rol/modelo/estado
  y lo último que dijeron); los terminados van abajo en una línea. Solo lectura.
- Las proporciones se reacomodan solas al conectarse o redimensionar (hooks de tmux → `bk _layout`).
- **Número fijo**: cada workspace toma al crearse el número libre más bajo (`@bk_id`) y lo conserva aunque se
  cierren otros; la tira, el header, `bk ls` y `alt+1…9` usan ese número, cada uno con su color.
  En la tira, los workspaces del mismo proyecto (`BK_PROJECT`) quedan juntos y una línea a la izquierda los une
  (`╭ │ ╰`); cada proyecto va donde está su número más bajo y el tooltip dice cuál es.
- **Quién lanzó a quién**: debajo de cada ventana de la tira (`└`) van sus subagentes vivos como `5.3 reviewer`
  (el 3.º que lanzó el workspace 5, contando los que ya terminaron, así el número no cambia; la descripción y el id
  `agent-…`, en el tooltip) y los agentes bk que lanzó, por su ventana
  (`f268`). Abajo de la línea, cada agente bk va por el nombre de su ventana y con `←3` (lo lanzó el workspace 3),
  `←f268` (otro agente) o `←?` (esa ventana ya se cerró). `bk` lo anota al lanzar (`@bk_parent` de la ventana:
  la sesión, no su número, que se reusa). Los agentes lanzados antes de esto no lo tienen. La tira mide 14
  columnas (`SIDE_W` en `lib/layout.conf`, con las demás proporciones del workspace: el riel al 34 %, mínimo 46).
- **Un solo estilo**: los colores de todas las vistas salen de la paleta de `lib/gentle.py` (día y noche, la que
  cambia `bk theme`) y el glifo, el texto y el color de cada estado, de `gentle.STATES`: `⠋` trabajando · `!` te
  espera o pide permiso · `?` te pregunta · `⚠` ¿trabado? · `✓` listo · `○` libre. La tira, el riel, el monitor,
  `bk ls` y los overlays dicen lo mismo.
- **Contexto de cada sesión**: cada llamada vuelve a leer todo el contexto, así que una sesión larga sale cara.
  La tira marca `▪` (rojo desde el umbral, 200k por defecto; ámbar desde 3/4 del umbral; el número en el tooltip), el riel lo muestra por agente y
  para este chat, `bk monitor` en la columna CTX, y `bk land` sugiere `/clear` o un chat nuevo si el chat que lo
  corrió pasa el ámbar. Sale del último turno del transcript (`usage.context_of`), sin llamar a ningún modelo.
  Al agente se lo dice un hook de Claude Code (`lib/context_hook.py`, en `UserPromptSubmit` y `PostToolUse`): un mensaje
  en su contexto al cruzar el ámbar (recomendar `/clear` o un chat nuevo: con Herdr, `alt+h`, que pide el resumen; con tmux, `alt+n`), al cruzar el umbral (cerrar en un punto estable y dejar
  el resumen para seguir, abajo; un agente de bk termina con su `bk done`) y después cada +100k. No repite (estado en `~/.cache/bk/context_hook/`),
  no corre en subagentes y ante cualquier error no dice nada. Se instala en `~/.claude/settings.json`, en `hooks`:
  `{"type": "command", "command": "python3 ~/barrilete-workspace/lib/context_hook.py", "timeout": 5}` en
  `UserPromptSubmit` y en `PostToolUse` (con `"matcher": "*"`).
  **El umbral lo elegís vos**: `bk context 300k` (o en `alt+h`, «Con cuánto contexto seguir en un chat nuevo») lo
  guarda en `~/.config/bk/context` para todos los chats; `bk context default` vuelve a 200k, la ventana estándar de
  contexto de Claude. El ámbar va en 3/4 del umbral.
- **Seguir en un chat nuevo (handoff)**: el resumen tiene siempre el mismo formato (`lib/handoff.py`): de dónde viene
  (sesión, workspace y número, rama, cuenta: lo completa bk, no el agente), hecho, falta (empezando por el primer paso),
  te espera a vos, no tocar y archivos y comandos; como mucho 40 líneas. Queda en
  `~/.local/state/bk/handoffs/<session_id>.md`. Lo pide el aviso rojo, o vos: `bk handoff [N]` se lo pide al chat del
  workspace N (desde Claude, `! bk handoff` imprime el pedido; desde Codex, corré `bk handoff` en su terminal). `bk chat --desde N` (o «↪ Seguir desde ws N» en
  `alt+n`) abre un workspace más en la misma carpeta y con la misma cuenta, con el resumen como primer mensaje (va como
  argumento del proveedor de origen, sin `send-keys`), lo borra y te pregunta si cierra el viejo. Codex registra su sesión con `hooks/codex_handoff.py` y, al terminar el turno que guardó el resumen, bk abre el chat nuevo con Codex. `bk handoff --listos`: los que hay. Los tres están también en la paleta (`alt+k`). Mientras espera, la tira
  marca ese workspace con `↪` (en lugar del `▪` de contexto) y `bk s` marca su fila con `↪`, también en recientes.
  **El chat nuevo se abre solo**: cuando Claude guarda el resumen, su hook (`lib/context_hook.py`, en el Write de
  ese archivo) corre `bk handoff --listo <sesión>`; Codex hace lo mismo al terminar el turno que lo guardó (`Stop`,
  `hooks/codex_handoff.py`). Si lo pediste vos con `bk handoff`, bk abre el chat nuevo en el
  momento (`bk chat --desde`); si lo pidió el aviso rojo, no abre nada solo: con Herdr sale un aviso «Resumen listo»
  que lo abre al hacerle clic (`bk handoff --seguir`, el resumen listo más nuevo; dura diez minutos), y con tmux queda
  la marca `↪` como siempre. Una sola vez por pedido, aunque el agente guarde el archivo de nuevo; con tmux, fuera de
  tmux no abre nada. El `.json` anota quién lo pidió (`via`).
  **Con Herdr** el pedido también llega desde afuera del chat: `bk handoff --term <terminal>` se lo pide al chat de
  esa terminal (si bk no la conocía, la adopta) y `bk handoff N`, al de la ventana N. Con `--cerrar`, el chat viejo
  se cierra cuando el nuevo abre: bk anota la terminal en `<session_id>.cerrar`, junto al resumen, y
  `bk handoff --listo` la cierra solo si sigue siendo la de esa sesión y la marca tiene menos de media hora. Un
  pedido sin `--cerrar` borra la marca de uno anterior. Es lo que corre `alt+h`, con sus dos opciones.
  **Con Herdr el chat nuevo sigue siendo el mismo trabajo**: nace con el nombre del viejo (uno puesto a mano pasa
  como puesto a mano, y `bk name` o el doble clic lo cambian; uno automático lo sigue actualizando `lib/names.py`) o,
  si el viejo no tenía, con el título del resumen; su estado es «sigue: <primer paso de Falta>». Queda unido al viejo
  (etiquetas `bk.from` en el nuevo y `bk.next` en el viejo) y en la barra de agentes el viejo no tiene fila propia:
  va debajo del nuevo, en una línea «antes» plegada que se despliega con un clic y se cierra con su cruz. Plegada
  igual lleva la marca si el viejo te espera o sigue trabajando, y el nuevo se ordena por lo más urgente de los dos.
  Cerrar el nuevo (`Cerrar…` en el clic derecho de su terminal, o ctrl+x en `alt+s`) abre un popup con la cadena
  entera de chats «antes» (título, cuándo, estado), todos marcados: Enter cierra los marcados, «Cerrar todos (N)» (o
  ctrl+Enter) cierra todos, y espacio o un clic desmarca el que querés guardar. Un chat sin «antes» abierto se cierra
  como siempre; un viejo fijado no entra en la cadena.

## Herdr en vez de tmux (`bk backend herdr`)
`bk backend herdr` hace que los chats y los agentes vivan en la app [Herdr](https://herdr.dev) y no en tmux
(`bk backend tmux` vuelve; queda en `~/.config/bk/backend`, y `BK_BACKEND` manda para un comando). No hay riel,
tira ni footer: la lista de espacios y la de agentes de Herdr muestran lo mismo.
Además instala en `~/.config/herdr-app` lo de `herdr/` del repo (`lib/herdr_install.py`): las teclas, los mods de
las acciones, los paneles, los temas y el layout `bk-lavanda` con su vista previa. Correrlo de nuevo trae lo que
cambió en el repo. Un layout, un tema o una tecla que retocaste quedan como están; los mods y la vista previa se
pisan con los del repo (se editan acá).

- **Un espacio por proyecto**: `bk` en la carpeta del proyecto abre (o muestra) el espacio `<proyecto>` con su
  chat en la pestaña `chat`. `bk chat` pregunta qué proveedor usar (`agy`, `codex`, `cc` o `cursor`) y suma otra pestaña (`chat-2`…); `bk chat --rama X` abre el espacio
  `<proyecto>-<x>` en su worktree y `bk chat --suelto` va al espacio `chats`.
- **Una pestaña por agente**: `bk run`, `fix`, `review`, `plan` y `orchestrate` lanzan al agente en una pestaña
  del espacio de su proyecto (`i42`, `pr57`…) sin sacarte de la que estás mirando. Herdr muestra su estado.
- **Nombres vivos** (`lib/names.py`): el título que Claude le pone a un chat sale del primer mensaje y no cambia más.
  Al terminar cada turno, cuando el chat queda 20 s quieto, haiku lee lo último (el recap, tus pedidos y su
  respuesta) y la pestaña pasa a llamarse por el tema de ahora; el segundo renglón de la barra de agentes dice en qué
  quedó (✓ terminó, ? te espera). Un nombre tuyo (`bk name`, «Renombrar» en el clic derecho de la terminal, `/rename`) manda: solo cambia el
  estado. `BK_NAMES_OFF=1` lo apaga.
- `bk ls`, `go`, `peek`, `say`, `stop`, `handoff`, `name`, `open` y `term` andan igual; `bk watch <agente>` muestra
  su pestaña. Lo que es del workspace de tmux (`rail`, `sidebar`) avisa y no
  corre: herdr-core ya mantiene vivas las terminales. `bk account use` va por espacio (ver *Cuentas*); `--account X` anda.
  `bk palette`, `new`, `changes`, `stats` y `s` en una terminal siguen siendo las pantallas de siempre; en Herdr
  sus teclas abren los paneles de abajo.
- **Número fijo de ventana**: cada chat y cada agente toma al nacer el número libre más chico (la etiqueta `bk.id`
  de su terminal) y lo conserva hasta cerrarse; el de una ventana que se cerró vuelve a estar libre. `alt+1…9` va
  a esa ventana, esté en el espacio que esté. El número va en un chip en la barra izquierda, las pestañas, la
  cabecera de cada pane y la barra de estado, y en las listas de `alt+a` y `alt+s`. Por comando: `bk go 3`,
  `bk say 3 "…"`, `bk peek 3`, `bk handoff 3`. Un número de una o dos cifras es primero el de la ventana; si nadie
  lo tiene, vale como antes (un issue o un PR). Para el agente del issue 7 habiendo una ventana 7: `bk say i7 "…"`.
  `bk stop` y `bk watch` leen el número igual: `bk stop 7` cierra el agente de la ventana 7, no el del issue 7
  (ese es `bk stop i7`).
- **Adopción**: un agente abierto desde Herdr (el `+` de las pestañas: no tiene etiquetas de bk) pasa a ser un
  chat de su proyecto. Cursor Agent pasa a ser agente y recibe estado por los hooks del proyecto. Toma el nombre `<proyecto>` (o `<proyecto>-2`… si ya es de otro chat) y su número, y desde
  ahí `bk ls`, `say`, `go` y `handoff` andan con él como con los de `bk chat`. Solo se adopta una terminal viva,
  con pestaña y que informa estado de agente: una shell no se toca. Lo hace la barra de estado de `bk-lavanda`
  cada 1,5 s, una vez por terminal (`bk _adopt <terminal>`), y también `bk handoff --term`.
- **Otras máquinas** (`hc machine add <máquina>`): los agentes que corren en otra máquina de Herdr se ven y se
  manejan desde acá. Su terminal tiene la dirección `<máquina>/<t>` y se adopta igual (el proyecto se le pregunta
  a esa máquina; los números de ventana se reparten acá, así no se repiten). El estado lo anota el hook de allá:
  bk lo trae con `hc exec --on <máquina> bk _states`, lo guarda 5 s (`BK_REMOTE_TTL`) y a una máquina que no
  responde le vuelve a preguntar recién a los 30 s, con un tope de 4 s por consulta (`BK_REMOTE_TIMEOUT`). A todas a la vez: dos colgadas no suman dos esperas.
  Para eso la otra máquina necesita `bk` en el PATH con el backend en herdr y los hooks de Claude registrados.
  `BK_REMOTE=0` lo apaga. Lo que depende de archivos de esa máquina todavía sale vacío para sus agentes: el
  título del issue, los subagentes, las tareas y la cola de `bk say`.
- **Todo con teclas**: `herdr/keys.json` se suma al `keys.json` de Herdr sin pisar las teclas que ya hacen otra
  cosa (dice cuáles quedaron ocupadas) y con respaldo en `keys.json.antes-de-bk`. Las que había puesto una versión
  anterior de bk y siguen igual se actualizan: `alt+1…9` iba al espacio N y ahora va a la ventana N; `alt+,` abría
  los ajustes de Herdr y ahora abre Aspecto. Herdr deja de actualizar un `keys.json` editado. Una tecla no puede
  correr un programa ni pasar argumentos: abre un mod por su nombre (`mod.open:bk-issues`). Por eso hay dos
  paquetes, cada uno copiado a una carpeta por tecla:
  - `herdr/mods/hub/` → `mods/bk-<vista>`: los paneles, dibujados por Herdr (no son terminales). Es el mismo
    paquete en cada carpeta: `view.js` dice cuál es, `views.json` da su título y tamaño y `kit.js` es la base
    (buscador, lista y pie con las teclas del panel). Leen de `bk _hub` y lanzan con `bk _do` (más abajo).
  - `herdr/mods/bk/` → `mods/bk-<acción>`: las acciones sin panel. Hacen lo suyo y se cierran: nada queda abierto
    (una ventana del mod siempre a la escucha tapaba los clics de toda la app).

  | Tecla | Qué hace | Corre |
  |---|---|---|
  | `alt+k` | Comandos: todo lo que se puede hacer, por nombre y con su tecla. Planear y orquestar se lanzan desde acá | `bk plan`, `bk orchestrate`… |
  | `alt+i` | Implementar un issue: los abiertos del proyecto que mirás (del remoto de GitHub: `origin` o, si no hay, el que haya). Enter lanza al agente (o va a su pestaña si ya corre); Tab cambia el rol | `bk run <n>` |
  | `alt+r` | Revisar o corregir un PR. Enter lanza al reviewer, o lo aprueba si el kit ya lo propuso; Tab pide una instrucción y lanza el fix; ctrl+g vuelve a correr los checks que fallaron; ctrl+o lo abre en GitHub | `bk review`, `bk approve`, `bk fix`, `bk rerun --go` |
  | `alt+e` | Te esperan: tareas y aprobaciones. Enter lanza el reviewer propuesto o va a la pestaña del agente; Tab suma el historial | `bk approve` |
  | `alt+p` | La épica del chat que mirás (si no tiene y hay varias, una lista para elegir): sus sub-issues por estado, quién espera a quién y el camino más largo. Enter va al agente o, sobre uno libre, lo lanza con confirmación. En un repo donde no se puede lanzar (sin barrilete-kit 2 o más nuevo, como uno con el kit 0.9) no ofrece «Lanzar»: dice por qué, lo mismo que diría `bk run` (`lib/kit_check.py`); `g` abre GitHub | `bk run <n>` |
  | `alt+t` | El panel derecho en la pestaña TODO: los pasos del issue que trabaja el chat que mirás (el issue sale como en `alt+p`), las casillas `- [ ]` de su cuerpo por sección, tildadas o no. Solo lee; el clic en el issue lo abre en GitHub. Otra vez `alt+t` vuelve a Estado | `bk _todo` |
  | `alt+a` | Agentes: los que te esperan arriba y, al lado, lo último de la terminal del elegido. Enter va a su pestaña, Tab le escribe, ctrl+x dos veces lo cierra, ctrl+o lo espía | `bk say`, `bk stop` |
  | `alt+n` | Nuevo: chat, chat en una rama, chat con nombre, el resumen de este chat para seguir en uno nuevo (abre `alt+h`), terminal, chat suelto, otro proyecto (o una ruta) y seguir desde un resumen listo | `bk chat …`, `bk open` |
  | `alt+s` | Sesiones: saltar a una abierta o retomar una reciente en un chat nuevo; ctrl+x dos veces cierra una abierta (una que siguió de otros chats abiertos: ctrl+x una vez abre el popup de su cadena «antes») | `bk _hub session-go`, `bk stop` |
  | `alt+h` | Resumen y seguir en un chat nuevo: se lo pide al chat que mirás, dejándolo abierto o cerrándolo cuando el nuevo abre. Abajo, los resúmenes listos | `bk handoff --term <t> [--cerrar]`, `bk chat --desde` |
  | `alt+g` | El panel derecho en la pestaña Cambios: lo sin commitear del proyecto y de los worktrees de los agentes. El clic en un archivo abre su diff en un popup (esc lo cierra). Otra vez `alt+g` vuelve a Estado | |
  | `alt+b` | Ramas de todos los proyectos, separadas por proyecto (el que mirás primero): si ya entró (PR mergeado o `bk land`), su PR, su worktree y lo sin commitear. Enter abre un chat en su worktree (o le crea uno); ctrl+x dos veces la borra, solo si no se pierde nada; ctrl+o abre su PR | `bk chat --carpeta`, `bk _hub branch-rm` |
  | `alt+u` | Uso y costo: hoy, el mes, los últimos 30 días, por modelo y por proyecto (un chat en una subcarpeta cuenta para su repo o worktree) | |
  | `alt+/` | Hoja de teclas: lee el `keys.json` de Herdr y dice qué hace cada una; Enter la corre | |
  | `alt+m` | Radio | `bk song …` |
  | `alt+,` | Aspecto: tema, paneles, tamaño y fuente de la terminal | |
  | `alt+1…9` | Ir a la ventana con ese número fijo | |
  | `alt+shift+1…9` | Ir al agente N del espacio que mirás, en el orden de las pestañas | |
  | `alt+c` | Chat nuevo en el proyecto que mirás; pregunta el proveedor (`agy`, `codex`, `cc` o `cursor`) | `bk chat` |
  | `alt+j` | Ir al próximo que te espera: primero los que preguntan, después los que terminaron; cada pulsación pasa al siguiente | |
  | `alt+0` | Volver a la pestaña donde estabas | |
  | `alt+q` | Volver al chat del espacio | |
  | `alt+x` | Terminal rápida del espacio: la muestra y la esconde sin cerrarla | |
  | `alt+y` | Piola, el ayudante del workspace: una sesión de Codex en un popup, en el repo de `bk`, para lo que no ande. El encargo de `lib/ayudante.md` (quién es, su voz, dónde mirar y qué no hacer solo) va como instrucciones de Codex, no como mensaje, y Piola se presenta al abrir. Una sola para toda la ventana, sin pestaña ni fila en la lista de agentes; la tecla (o el botón «Piola» de la franja de arriba, que muestra si trabaja, te espera o terminó) la muestra y la esconde sin cerrarla. El popup lleva una cabecera con su nombre, su estado y el botón de esconder: Esc no lo cierra, va a Codex. Codex corre con tu config de siempre. Temporal: hasta que el workspace quede pulido | `bk _ayuda` |
  | `alt+.` | Mostrar u ocultar el panel derecho | `layout.toggle:lado` de Herdr |
  | `alt+z` | Agrandar el pane | `pane.zoom` de Herdr |

  Las catorce primeras abren un panel; las ocho que siguen son acciones sin panel; las dos últimas, comandos de Herdr.
  Sin tecla: `bk-out` (la salida de un comando que solo imprime: tokens, roles, cuentas…; lo abre `alt+k`),
  `bk-profiles` (perfiles de modelos y tareas; lo abre «Perfiles de modelos y tareas…» de `alt+k`),
  `bk-aviso` (muestra los avisos que pide bk; solo un mod puede avisar), `bk-seguir` (el clic del aviso «Resumen
  listo») y `bk-pop` (abre en una terminal sobre la ventana lo que pide un panel que ya se cerró: «Monitor de agentes»
  y «Ver un subagente» de `alt+k`, la radio a pantalla completa, el editor de perfiles). El rastro de `alt+0` y la adopción los lleva el mod `bk-barra`, que está en `bk-lavanda`: en un layout
  que no lo tenga, `alt+0` no tiene a dónde volver y adoptar queda para `bk _adopt <terminal>` o `bk handoff --term`.
- **Ramas que se borran solas**: una rama que ya entró a la principal (su PR se mergeó en el mismo commit al que
  apunta, o la entró `bk land`) se borra sola con su worktree y, si apunta al mismo commit, la de GitHub. Lo hace
  `lib/branches.py` (`bk _hub branch-sweep`), que la barra de estado dispara cada 10 min como mucho, en todos los
  proyectos de `bk new`, y avisa qué borró. Nunca toca la rama principal, una con commits que no entraron, un
  worktree con algo sin commitear (ni archivos nuevos) ni uno donde trabaja un proceso (si `lsof` falla, ningún
  worktree). Una recién creada, sin commits, tampoco: puede ser trabajo que empieza; a mano (alt+b) sí. En GitHub,
  los repos de barrilete además borran la rama de un PR al mergearlo («Automatically delete head branches»).
  `BK_NO_SWEEP=1` la apaga. Tests: `tests/test_branches.sh`.
- `bk s` en una terminal: cada sesión abierta muestra el id de su terminal (`t2d`, el que usan `bk say`, `bk peek`
  y `hc`) y esc cierra sin la espera de un segundo de curses (`ESCDELAY` 25 ms). Enter sobre una sesión abierta
  muestra su pestaña de Herdr y sobre una reciente la retoma en un chat más del espacio de su proyecto (`bk chat`
  con `claude --resume`, en la carpeta de la sesión); `x` no cierra pestañas de Herdr, y una sesión cuya terminal
  ya no está pasa a recientes.
- **Los paneles del layout**: `bk backend herdr` copia cada carpeta de `herdr/mods` (menos `bk` y `hub`) a
  `mods/bk-<nombre>`, y el layout que las muestra, uno solo: `bk-lavanda` (ver *Estética Lavanda*). `agentes` es
  la barra izquierda (espacios y agentes, cada uno con el chip de su número), `marca` su cabecera y su pie,
  `pestanas` la franja de arriba (el contexto del chat enfocado en un renglón: proyecto, épica, issue y rol, los agentes que te esperan y el botón «Piola» de `alt+y`), `ayudante` la cabecera del popup de Piola, `cabecera` la de cada pane, `lado` el panel derecho y `barra` la barra de estado.
  `agentes`, `pestanas`, `cabecera`, `lado` y `marca` comparten las piezas de dibujo de `kit.js`: un mod no puede
  importar de otra carpeta, así que cada uno lleva su copia y un test falla si dejan de ser iguales. El lado
  derecho sale de `bk _side` (proyecto, rama, perfil de roles, contexto de la sesión de Claude de la carpeta, uso
  de hoy y lo que quedó sin commitear en el proyecto y sus worktrees). Instalar no cambia el layout que ves.
- **Temas**: `herdr/themes/*.json` van a `themes/` de Herdr y se eligen en `alt+,` o en los ajustes de Herdr. Los
  de bk: `bk-neon` (violeta oscuro, acento lavanda; antes se llamaba `bk-noche`), `bk-pastel` (oscuro suave, con
  rosa, menta, lila y durazno), `bk-gentleman` (casi negro, acento rosa fuerte y champán; sale del tema
  Gentleman-Sexy de pi), `bk-gentleman-cute` (el mismo fondo con rosa suave, menta y celeste; del tema
  Gentleman-Cute), `bk-dia` (claro, papel cálido con acento lavanda, para usar de día),
  `bk-papel` (claro, papel blanco y tinta negra con amarillo, coral e índigo, del estilo de Paperfolio) y
  `bk-papel-night` (su versión de noche: tinta casi negra, texto blanco cálido, bordes suaves y acento amarillo); además
  `catppuccin-mocha`, `rose-pine` y `tokyo-night`. Siguen al repo mientras no los retoques: bk anota qué instaló
  (`bk-temas.json`) y solo pisa una copia que sigue igual a esa; un tema tuyo con el mismo nombre queda como está y
  se avisa. El `bk-noche` y el `bk-tinta` que instalaron versiones anteriores (ahora `bk-neon` y `bk-papel-night`) se
  borran si nadie los tocó.
  En `alt+,`, elegir un tema de la otra claridad (`bk-dia` con la apariencia oscura, o uno oscuro con la clara)
  cambia también la apariencia (`appearance` en `settings.json`); si no, Herdr no lo mostraría.
- Cómo está hecho (`lib/herdr.sh`): `herdr-app` crea espacios y pestañas y `hc` (herdr-core) lee, escribe y cierra
  las terminales. Lo que en tmux era el nombre de la ventana y sus `@opciones` son etiquetas de la terminal
  (`bk.kind`, `bk.win`, `bk.project`, `bk.role`, `bk.ref`, `bk.id`, y `bk.adopted` en las adoptadas), y el "pane"
  es su dirección (`t7`), que el hook de estado toma de `HC_TERMINAL_ID`.
- **Qué está probado**: con un Herdr falso (`tests/herdr_fake.py`), `tests/test_herdr.sh` prueba los comandos de
  `lib/herdr.sh`, el instalador (teclas, mods, paneles, temas, layout y vista previa), los números fijos, la
  adopción y `bk handoff --term/--cerrar`; `tests/test_side.sh`, los datos del lado derecho; `tests/test_hub.sh`,
  los de los paneles. Partes de algunos mods corren en `node`, sin Herdr (`tests/test_herdr_subagents.sh`,
  `tests/test_herdr_tasks.sh`, `tests/test_herdr_lineage.sh`, `tests/test_herdr_cerrar.sh`, `tests/test_herdr_epica.sh`). Lo que no está probado: apretar las teclas. macOS no deja mandarle teclas a Herdr
  desde un script, así que ninguna prueba recorre tecla → mod → acción dentro de la app.

## Sesiones (`bk s` · `C-a s`)
Selector estilo Orca (`lib/sessions.py`): arriba las sesiones abiertas (Enter salta a su pane; un agente que
terminó se revive con `claude --resume` en el mismo pane), abajo las recientes de todas las carpetas
(Enter las retoma en una ventana nueva de `agents`, en su carpeta). `/` busca, `x` cierra un agente o un workspace.
Una sesión abierta fuera de tmux aparece como `afuera` y no se duplica.
Cada chat de un workspace muestra su número fijo con su color (`ws 3`, el mismo de la tira y `alt+N`), así sabés cuál
es. `x` sobre un workspace lo cierra entero (chat, riel y tira) después de confirmar con `y`; la conversación queda en
recientes. El workspace donde estás no se cierra desde ahí. Por comando: `tmux kill-session -t '=bk-<nombre>'` (con comillas
en zsh, que expande el `=`).

Una sesión cuya terminal se cerró sin que Claude avisara (o que quedó en consola vacía: la terminal sigue, pero ya
solo corre el shell) no figura como abierta: pasa a recientes y queda anotada en `~/.cache/bk/dead.json` con el
motivo. `bk revive` las lista y las retoma todas juntas, cada una como Enter sobre una reciente (un chat más de su
proyecto con Herdr, una ventana de `agents` con tmux); `bk revive <id>…` solo esas (alcanza el principio del id),
`bk revive --forget [<id>…]` las saca de la lista sin retomarlas y `bk --dry-run revive` solo las muestra. Una
anotada sale sola de la lista si vuelve a abrirse o a los 7 días. Un cierre tuyo de la pestaña se ve igual que una
caída, así que la lista puede traer chats que cerraste a propósito: para eso están los ids y `--forget`.

## Hablar con los agentes sin entrar
- `bk peek [ventana]`: la pantalla de un agente (sin ventana: las últimas líneas de todos).
- `bk say <ventana> "…"`: escribe en su ventana como si fuera tu teclado; sirve para responder un menú o aprobar un plan.
  Corré `bk say` desde una terminal humana separada, fuera del chat o la sesión del agente. Los guardrails bloquean el
  comando dentro de herramientas de agentes y el CLI verifica el proceso que lo invoca.
- `bk watch [ventana]`: espejo en vivo de un agente; sin ventana toma el próximo libre.
- `bk fix <pr> "instrucción"`: implementer sobre la rama de un PR abierto, reusando su worktree.

- `bk run` reusa el kit: `routing.py` elige el rol y `prepare.sh --worktree` asigna el issue y crea el worktree.
- `roles.yml` dice qué provider/modelo corre cada rol; un proyecto lo pisa con `.barrilete/roles.yml`.
- Perfiles de modelos (`bk profile`, `profiles.yml`): un juego de provider/modelo por rol (`normal`, `barato`, `a-fondo`, `codex`)
  que se cambia de una vez y vale para todos los proyectos. `bk profile barato` lo elige y `bk profile off` vuelve a
  `roles.yml`; en `alt+k` hay un renglón «Usar el perfil …» por perfil y «Perfiles de modelos y tareas…» abre el panel
  (→ edita un perfil, enter en un rol elige el modelo, «Otro…» acepta cualquier `provider/modelo`, así un perfil mezcla
  `claude/…` y `codex/…`). Editar copia los de fábrica a `~/.config/bk/profiles.yml`, que desde ahí manda.
  Solo cambia modelos: el modo sale de `roles.yml`. Orden: `.barrilete/roles.yml` del proyecto, el perfil y `roles.yml`.
  Los agentes que ya corren siguen con el modelo con el que arrancaron.
- Tareas (`bk ask`, `tareas.yml`): un modelo de cualquier proveedor (claude, codex, gemini) para un trabajo puntual,
  con una descripción que lee el orquestador para saber cuándo usarla. De fábrica: `imagenes` → `codex/gpt-6.1-sol`
  y `investigar` → `codex/gpt-6.1-sol` (codex corre con `--search`: búsqueda web). Antes era Gemini, pero su CLI
  busca siempre con `gemini-3.5-flash`, sea cual sea el modelo, y con la cuota gratis da 429. `bk ask imagenes "…"` corre sin pantalla en
  `~/.cache/bk/ask/<fecha>-<tarea>/` (codex escribe solo ahí; gemini sin `--yolo`; claude solo texto), imprime la
  respuesta y los archivos que dejó, y corta a los 10 min (`--timeout`); si el proveedor se quedó sin cuota (429) lo
  dice. `bk ask set <tarea> <provider>/<modelo> <para qué>` y `bk ask rm` las editan (en `~/.config/bk/tareas.yml`).
  Gemini es solo para tareas: no puede ocupar un rol (no tiene las barandas de Claude Code).
- `bk models [provider]`: los modelos para elegir. Codex sale de su CLI (`codex debug models`, guardado un día);
  Claude Code y Gemini no listan los suyos, así que salen de `models.yml` más `~/.config/bk/models.yml`.
  El panel «Perfiles de modelos y tareas» de `alt+k` los muestra agrupados por proveedor, y solo los proveedores con
  sesión iniciada (`bk models --providers`): claude y codex según sus cuentas (`bk account`), gemini si tiene clave
  (variable de entorno, `~/.gemini/oauth_creds.json` o el llavero; solo se mira que exista).
- `--dry-run` en cualquier comando de agentes, y en `bk ws` y `bk chat` (también `--rama`, `--suelto` y `--desde`), muestra qué haría sin lanzar ni abrir nada.
- Perfiles de Codex (`codex/`, `bk codex`): `bk codex install` copia a `~/.codex` tres perfiles que gastan menos tokens
  (`bk-orquestador`, `bk-implementador`, `bk-liviano`; las cuentas de `bk account` los ven por symlink) y `bk codex`
  dice si están al día. Un agente `codex` arranca con el de su rol (`codex -p bk-implementador -m <modelo>`: el modelo
  sigue saliendo del perfil de bk); sin el archivo instalado, sin `-p`. Apagan plugins, apps, navegador, computer use e
  imágenes, que se mandan en cada llamada: el contexto de un turno baja de 21,9k a 14,9k–18,6k tokens (medido con
  Codex 0.170; detalle en `codex/README.md`). `bk ask` no los usa (`imagenes` necesita generar imágenes). El perfil de
  bk `codex` pone el implementer en `codex/gpt-6.2-sol` y deja el resto en Claude.
- Provider `codex`: los perfiles se probaron con `codex exec`; lanzar un agente `codex` desde bk, todavía no. Las barandas y los eventos de las tareas le llegan por el `.codex/hooks.json`
  del proyecto (los trae el kit), pero no está verificado que Codex los dispare igual que Claude Code.

- `bk song` reproduce radios de techno/house en segundo plano con mpv (`bk song help`); un género que no está en la lista se busca en radio-browser.info.
  `bk song ui` abre una pantalla en vivo con el gráfico del sonido (niveles reales de cada canal) y control con teclas; al salir, la música sigue.

Instalación: `ln -sf ~/barrilete-workspace/bin/bk ~/.local/bin/bk` y `brew install tmux mpv`.

## Tareas (ADR-005 del kit)
Cada agente de `bk run`, `bk review` o `bk fix` trabaja sobre una tarea (`<issue>-<rol>`, `pr<n>-<rol>`) con estado y
eventos, en `~/.local/state/bk/tasks/<proyecto>/<id>/` (`task.json` y `events.jsonl`); el agente recibe la carpeta en
`BK_TASK_DIR` y los hooks del kit anotan inicio, espera, commits y PRs.
- Un segundo `bk run` sobre el mismo issue no lanza otro agente (con cualquiera de los dos implementers).
- `bk run` suelta el candado del worktree (`agent-lock` del kit) que tomó `prepare.sh` antes de lanzar al agente: el
  agente lo toma como su primer paso y `bk done` lo suelta. Si el candado es de otro agente vivo, `bk run` no lanza.
- El agente cierra con `bk done pr <n>` (o `blockers`, `dropped "…"`, `escalate "…"`); si termina sin cerrarla queda
  `incomplete`, y `bk stop` la deja `cancelled`.
- Su PR propone `pr<n>-reviewer`, que arranca con `bk approve` desde una terminal humana separada. Con `--orchestrated` (lo usa `/orchestrate`) no hay
  propuesta: el orquestador lanza al reviewer.
- `bk say` a un agente que trabaja se encola hasta que termine el turno (`--now` para ya).
- `bk tasks` las lista con su carpeta; `bk tasks prune --yes` borra las terminadas (nada se borra solo).

### Estética Lavanda

`bk backend herdr` instala también `bk-lavanda`. Activarlo:
`herdr-app do layout.switch --name bk-lavanda`.
A la izquierda, la marca (un barrilete de silueta simple, con fondo del color del estado), los espacios y los agentes, cada uno con el chip de su número de ventana y su marca de
estado; angosta queda en un riel con solo los chips. En el centro, las pestañas y los panes, cada pane con su
cabecera (número, programa, qué hace, carpeta y rama). A la derecha, tres pestañas: Estado, con dos tarjetas
(sesión y GitHub); TODO, los pasos del issue del chat que mirás (`alt+t`); y Cambios, lo sin commitear, con el diff de
cada archivo en un popup al hacerle clic (`alt+g`). `alt+.` esconde el panel. Abajo, la barra de estado: proyecto, rama, cuenta, qué te espera, uso de hoy, CPU y memoria de cada computadora (`cpu 3%  mem 56%`), radio y las
teclas de comandos y de la hoja de teclas. La cuenta es la de Claude de la terminal que mirás: su mail (de su
`.claude.json`, sin preguntarle a Claude), una sola vez; si no hay mail, muestra el nombre de `bk account`.
En un popup muestra la cuenta elegida para el espacio, no el login principal de Claude. El panel derecho muestra
la cuenta de su terminal. Un clic en ella abre el panel Cuentas para cambiarla. La marca de estado es la misma en todos, con los colores `blocked`, `done` y `working`
del tema: en `bk-neon`, ámbar te espera, verde listo y rosa trabajando.

**Espacios en carpetas.** La lista de espacios se ordena a mano y se agrupa en carpetas de un nivel. El botón de
carpeta del rótulo `ESPACIOS` crea una; arrastrar una fila la cambia de lugar (la línea dice dónde cae) y soltarla
sobre una carpeta la mete adentro (sobre la suya, la saca). Lo mismo está en el clic derecho, sin mouse: `Mover a…`,
`Subir`, `Bajar`, y en una carpeta `Nombre, color e imagen…` y `Borrar la carpeta` (no cierra nada: sus espacios
quedan sueltos). Un clic en la carpeta la pliega; plegada muestra lo más urgente de adentro y no esconde el espacio
que estás mirando. Cada carpeta y cada espacio puede tener color (una muestra del tema o un `#rrggbb`; el espacio
usa el de su carpeta si no eligió uno) e imagen: en el diálogo, soltá el archivo o pegá su ruta (png, jpg, webp o
svg, hasta 1 MB); `bk _logo` la copia a `mods/bk-agentes/logos/` de Herdr, que es de donde Herdr muestra imágenes.
- Un espacio se recuerda por su nombre, no por su id: bk abre siempre `<proyecto>` para un proyecto, así que
  cerrarlo y reabrirlo conserva lugar, color e imagen. Renombrarlo también.
- Un espacio nuevo cae debajo del de su proyecto (la etiqueta `bk.project` de sus terminales), en su carpeta: el
  worktree de una rama queda con su proyecto. Si no hay ninguno, va suelto al final.
- Uno cerrado que acomodaste en una carpeta sigue ahí, apagado: un clic lo reabre (`bk open` en su carpeta) y
  `Quitar de la lista` lo olvida. Los que nunca tocaste se olvidan solos al cerrarse.
- El orden de Herdr sigue al de la lista (`space.move`): `space.next`/`space.prev` y los agentes "por espacio" van
  como los ves. Cada máquina queda en su bloque, como en Herdr.
- El estado es un solo valor de Herdr, `shared` `bk.espacios` (en su `shared.json`); las carpetas plegadas, del
  panel. Las reglas están en `herdr/mods/agentes/espacios.js` (sin dibujo; el menú lleva su copia), la lista en
  `lista.js` y el diálogo en `editar.js`. Tests: `tests/test_espacios.sh` (necesita `node`): el modelo, la lista y
  el diálogo con un Herdr falso que hace de mouse, y `bk _logo`. Lo que no prueba: arrastrar dentro de la app.
El layout nombra un par de temas, `bk-neon` con la apariencia oscura y `bk-dia` con la clara, y la fuente de la
interfaz, SF Mono; la
de la terminal es la tuya (`alt+,` la cambia, y también el tema, el tamaño y qué paneles se ven).
El perfil de roles va en un renglón que sigue abajo si no entra, encabezado por el perfil de modelos activo (`bk profile`);
fuera de un proyecto, el panel lo dice.

GitHub muestra hasta cinco PRs abiertos con enlaces al navegador, borrador,
revisión y CI. Requiere `gh` autenticado (`gh auth status`) y un remoto GitHub;
se actualiza cada minuto y al cambiar de carpeta, sin bloquear el estado local.
Si no puede consultar GitHub, muestra el error sin ocultar los cambios de Git.
El layout vive en `herdr/layouts/bk-lavanda.json` y es el único de bk. `bk backend herdr` lo mantiene igual al
del repo mientras no lo retoques: anota qué instaló (`bk-lavanda.instalado` en la carpeta de Herdr) y solo pisa una
copia que sigue igual a esa. Si lo retocaste queda como está y avisa; para volver al del repo, borrá
`~/.config/herdr-app/layouts/bk-lavanda.json` y repetí. Para volver al de Herdr: `herdr-app do layout.switch --name main`.
Su vista previa (`herdr/layouts/bk-lavanda.svg`, la que el layout nombra en `preview`) se copia al lado si falta o
si difiere de la del repo, también cuando el layout está retocado.
El layout `bk` de la primera versión ya no se instala; si te quedó `layouts/bk.json`, podés borrarlo.

## main protegido (`bk land`)
Varias sesiones trabajan a la vez sobre este repo. Nadie edita el checkout de `main` ni commitea en `main`: cada sesión
trabaja en su rama y su worktree (`git worktree add -b <rama> ../barrilete-workspace-wt/<rama> main`) y entra con `bk land`.
- **Claims**: al editar un archivo en un worktree, el hook de Claude Code (`.claude/settings.json`) lo registra a nombre de
  la rama. Si otra rama que empezó antes también lo modifica, le avisa al agente que no corra los checks todavía.
- **Orden**: una rama espera a las ramas activas que empezaron antes que ella y comparten algún archivo. Es un solo
  orden por hora de inicio, así que no hay deadlock. Las ramas sin actividad en 3 h o sin worktree no bloquean.
- **`bk land --wait`**, desde el worktree con todo commiteado:
  1. espera su turno;
  2. con el mutex de `main` tomado, rebasa sobre `main`;
  3. corre `lib/checks.sh`, una sola vez;
  4. hace el fast-forward;
  5. anota la rama y su commit (`~/.cache/bk/landed.json`): la limpieza sola borra el worktree y la rama cuando
     ya no corre nada ahí (ver *Ramas que se borran solas*).
  Si choca, el choque queda en su worktree: `main` nunca queda a medias.
- **Qué devuelve `bk land`**: 0 entró · 3 en cola · 4 choque en el rebase · 5 checks en rojo · 6 no pudo hacer el fast-forward.
- **`bk claims`** muestra quién modifica qué y quién espera a quién; `bk release` suelta los claims de una rama.
- **El hook de git** (`githooks/reference-transaction`, con `git config core.hooksPath githooks`) rechaza cualquier
  cambio de `main` que no venga de `bk land`, aunque uses `--no-verify`, y no deja reescribirla. La salida de
  emergencia es `BK_MAIN_OK=1`.

## Cuentas (`bk account`, port de bk-shell#17)
Cada sesión de bk puede usar otra cuenta de Claude Code o de Codex, y pueden correr dos a la vez; las conversaciones son
las mismas (`/resume` y `alt+s` ven todas).
- `bk account new claude trabajo` crea la cuenta en `~/.local/state/bk/accounts/trabajo` y abre su login. Lo compartido
  (`projects/`, settings, `CLAUDE.md`, skills, hooks) es un symlink a `~/.claude`; las credenciales son propias.
  Sin nombre (`bk account new claude`) se nombra sola: `claude-2`, `claude-3`… (la de siempre es la 1).
- `bk account use trabajo` la pone en esta sesión: los agentes y chats que lances desde acá corren con ella
  (`--relaunch`: también el chat principal, retomando su conversación). `bk account use default` vuelve a la de siempre.
- `bk run … --account X` solo para un lanzamiento. El riel muestra en Status el mail de la cuenta de la sesión,
  también el de la default. Es la que eligió la sesión: con `bk account use` sin `--relaunch`, el chat que ya estaba
  abierto sigue con la anterior hasta relanzarlo.
- `bk account login <cuenta>` rehace el login de una cuenta; `bk account login default` el de la de siempre (`~/.claude`),
  aunque esta sesión use otra. Si dos cuentas muestran el mismo email en `bk account`, en la práctica son una sola.
- En Herdr, `alt+k` tiene «Agregar una cuenta de Claude…», «Agregar una cuenta de Codex…» y «Volver a iniciar sesión en
  una cuenta…»: piden el nombre (minúsculas, números y guiones; uno que no sirve vuelve a preguntar) y abren
  `bk account new` o `bk account login` en una terminal sobre la ventana, que se cierra cuando termina el login.
- Con Herdr no hay sesión de tmux: `bk account use` elige la cuenta para el espacio del proyecto donde lo corrés
  (queda en `~/.local/state/bk/accounts/.espacios.json`), y lo que lances en ese espacio corre con ella; `bk account`
  dice cuál usa. `--relaunch` abre el chat del espacio de nuevo con esa cuenta, retomando la conversación, y cierra el
  viejo. En `alt+k` cada cuenta tiene su fila («Usar la cuenta de Claude trabajo en abra»; la que usa, marcada); los
  temas y las fuentes de Ghostty no aparecen (los de Herdr están en «Aspecto»).
- **Panel Cuentas** (clic en la cuenta de la barra de abajo, o «Cuentas: cambiar de cuenta con un clic…» en `alt+k`): las
  cuentas de Claude y de Codex por su mail (el de Codex sale del `auth.json` de la cuenta), con la que usa el espacio
  marcada «en uso» y las que no tienen sesión, «sin sesión». Un clic (o enter) en una es `bk account use` para el espacio
  de la terminal que mirás y, si esa terminal es un chat de Claude, lo relanza ahí mismo con la cuenta nueva
  retomando su conversación (`bk account use <cuenta> --relaunch --terminal tX`: sale con `/exit` y vuelve a abrir
  `claude --resume`; no toca un chat que trabaja o te espera, ni uno del que no sabe qué conversación retomar).
  Una sin sesión abre su login; `ctrl+l` rehace el de la elegida. «Agregar una cuenta…» abre el login directo, sin pedir
  nombre (`bk account new claude`), en una terminal sobre la ventana.

## La misma versión en cada máquina (`bk machines sync`)
Con Herdr y más de una máquina (`hc machine ls`), `bk machines sync` deja en cada máquina conectada el mismo commit
de bk que tiene esta y corre `bk backend herdr` allá. `bk machines sync --dry-run` (o `bk --dry-run machines sync`)
dice qué haría y solo mira.
- Los commits que a la otra máquina le faltan viajan en un `git bundle` por `hc exec -i`: anda sin pushear y sin que
  la otra llegue a GitHub.
- Allá no se toca el checkout de la persona: el commit queda en un worktree propio, `<repo>-wt/bk-sync`, sin rama
  (`<repo>` es el repo del bk que esa máquina ya tiene instalado), y `~/.local/bin/bk` pasa a apuntar ahí.
- Frena antes de empezar si el bk de acá tiene cambios sin commitear: la otra máquina no quedaría igual.
- Una máquina desconectada se saltea. Una que no tiene bk en `~/.local/bin/bk` (se instala una vez a mano), o cuyo
  `bk-sync` tiene cambios sin commitear, no se toca y se avisa; las demás siguen.
- Sale con 0 si quedaron todas al día, con 3 si alguna no, y con 1 si no pudo empezar.

## Lo que te espera (`bk monitor` · `bk checkpoints`)
- `bk monitor`: pantalla para el otro monitor. Arriba *Te esperan* (preguntas, permisos y checkpoints, con el comando
  para contestar); después agentes y chats en tablas, las tareas, los desvíos en vivo agrupados (los graves suenan) y el
  costo de hoy. La memoria libre va en el encabezado.
- `bk checkpoints` (`--json`): planes por aprobar, reviewers propuestos, PRs para revisar o mergear y lecciones, cada uno
  con su comando. Es la misma lista que *Te esperan*; ya no está en el riel.
- Los PRs salen de una caché (`~/.cache/bk/checkpoints_prs.json`) que `bk _prs` baja de GitHub: tus PRs abiertos con
  CI en verde y una review sin bloqueantes ni commits posteriores, y las reviews que te pidieron. `bk checkpoints` y
  `bk monitor` lo lanzan en segundo plano cuando la caché tiene más de 2 minutos, así que con el monitor cerrado se
  actualiza recién al correr `bk checkpoints`. Sin red, la caché queda como estaba. Test: `tests/test_prs.sh`, con un
  `gh` falso.

## Supervisión local (`bk supervisor`)
`bk supervisor propose` lee un `bk.supervisor-plan.v1` cerrado desde stdin. `bk supervisor approve <run_id>` presenta el plan en una terminal humana separada y reserva issues/PRs y slots bajo un lock atómico: máximo tres implementadores, una review por PR. Si no hay slots, queda en cola; los hotfix van primero y no interrumpen. `bk supervisor status` muestra el estado local, con los leases de cada plan, y `cancel` libera una propuesta o reserva con confirmación humana, solo si ningún lease arrancó. El store y el bus están bajo `~/.local/state/bk/supervisor/` (o `XDG_STATE_HOME`); los planes terminados y los eventos se retienen 30 días. Una alta del bus cortada a mitad (la última línea sin fin de línea) se descarta; cualquier otra línea inválida frena sin modificar nada.

Al reservar, cada asignación (incluidos subagentes y relanzamientos) recibe un lease `reserved`. El ciclo es `reserved → running → stale → completed|released`: un adaptador de harness confirma el inicio (PID con su hora de inicio y sesión del harness) y renueva el heartbeat cada 60 s en el estado, sin escribir eventos. `bk supervisor reconcile` marca `stale` un lease sin heartbeat por más de 5 minutos, sin soltar issue ni slot; si después llega un heartbeat con la misma identidad (PID, hora de inicio y sesión) y el adaptador confirma el proceso y la sesión vivos, vuelve a `running` y deja un evento `lease.recovered`. Lo libera (`released`) solo si verifica que el proceso y la sesión del harness ya no existen; si no puede verificarlo, lo informa en `needs_human`. No hay liberación forzada. Un plan se cierra cuando todos sus leases terminan, y eso promueve la cola. Hoy no hay ningún adaptador verificado (`verified_harnesses` vacío en `status`): ningún lease puede arrancar ni cerrarse, y `bk supervisor` no lanza agentes. `--dry-run` solo valida o muestra (`reconcile --dry-run` informa sin escribir).

## Retroalimentación (`bk learn`)
`bk routing dispatch` y `bk routing outcome` leen un objeto JSON por stdin y anexan eventos validados al store local
`${XDG_STATE_HOME:-~/.local/state}/bk/routing/events.jsonl`; `bk routing summary` muestra métricas de la ventana reciente
y el archivo de agregados mensuales, sin IDs de tarea, issue o repo. Ningún evento individual dura más de 180 días: cuando la línea más
vieja de una tarea (`run_id` + `task_id`) vence, la tarea entera se suma a `aggregates.json` (celdas por mes y
proveedor/modelo/harness/rol/tipo/área, con conteos de conocidos y desconocidos, sin IDs ni texto) y sus líneas se
borran. `dispatch` y `outcome` anexan primero y compactan bajo el mismo lock; `summary` compacta antes de leer.
`bk routing compact [--dry-run]` lo hace a
mano (o solo cuenta qué haría) y `bk routing aggregates` muestra los agregados. Todo pasa bajo un `flock` del store, y la
compactación se puede cortar en cualquier punto: la próxima operación la termina o la deshace, y repetirla no cuenta dos
veces. `bk --dry-run routing dispatch|outcome` solo valida; `bk --dry-run routing compact` informa sin escribir. Este registro no se sincroniza ni se envía a los proveedores. El contrato y sus gates siguen propuestos en
[`ADR-002`](docs/decisions/ADR-002-retroalimentacion-del-ruteo-local.md); estos comandos no despachan agentes.

`lib/learn.py` lee los transcripts y registra desvíos en el vault de Obsidian (`~/Documents/Obsidian Vault/agents`):
barandas, verificaciones fallidas, contratos de subagentes (patrones automáticos) y tus correcciones, rechazos
e interrupciones (para leer en el resumen del día). Un patrón repetido ≥3 veces en 14 días propone una lección;
las que marcás `accepted` con su regla pasan a `agents/INDEX.md`, que Claude Code importa desde `~/.claude/CLAUDE.md`.
`bk lessons` lista las que esperan revisión; también salen en `bk checkpoints` y en *Te esperan* de `bk monitor`.
`bk learn` se corre a mano: lo corría cada ~2 minutos la barra de Sketchybar, que ya no está.
Además, cada desvío de una sesión de un proyecto con el kit, y cada hallazgo de las reviews de los repos de
`~/.config/bk/retros.json`, va al store de ese proyecto como evento v1 (ADR-007 del kit, `lib/learn_store.py`). Lo
escribe el `scripts/agents/learning.py` del proyecto, así que el store (`local` o `branch`), el nombre y el validador
son los del kit; un proyecto sin ese script no recibe nada. Solo metadatos: el tipo del desvío en `class`
(`guardrail-block`, `user-correction`…), el modelo de la sesión (en un hallazgo, el de la sesión que abrió el PR; si no
se sabe, `unknown`), `harness: claude-code`, el rol, el `area:` del issue de la rama y `evidence_ref` (la ruta del
transcript, solo su nombre con store `branch` porque la ruta lleva tu usuario, o la URL del PR); nunca texto del transcript, tuyo o de la review. El vault queda como vista personal y sus
eventos viejos no se migran. No manda lo de antes de su primera corrida ni repite eventos, tampoco con `--rebuild`
(estado en `~/.cache/barrilete/learn-store.json`). Con store `branch`, subirlo es `learning.py push` del proyecto.
Tests: `tests/test_learn_store.sh` (usa el `learning.py` del main de `~/barrilete-kit`, o `BK_KIT_REPO`).
`bk learn effect` mide si cada regla que aplica un proyecto baja los hallazgos de review que dice evitar (ADR-006 D10
del kit). Las reglas son las `accepted` de barrilete-rules en el SHA del `.barrilete/rules.lock` de cada repo de
`~/.config/bk/retros.json` (se clona una vez por SHA en `~/.cache/bk/rules/`) más las de `.barrilete/rules/`, según su
`scope`; ya no lee las lecciones del vault. Por regla: hallazgos de sus `classes` por ronda (y qué parte del total
son) en los PRs abiertos antes y después de `accepted`, y, si tiene `check`, cuántas corridas fallan según los eventos
`check_run` de `.barrilete/learning/events.jsonl` (sin eventos: "sin datos"). Al final dice qué parte de los hallazgos
cae en `other` y qué etiquetas usan las reviews que no están en `classes.yml`. Escribe `agents/efecto.md`; las que dan
*no baja* son para pasar a check, reescribir o retirar (decide la persona). Tests: `tests/test_effect.sh`.
`bk bitacora [tema]` (alt+k «Bitácora: guardar lo de este chat…») le escribe `/bitacora <tema>` a un chat de Claude, y
la skill `bitacora` del kit (barrilete-kit#343) guarda lo de esa conversación como una entrada de `docs/bitacora.html`,
en la sección del tema. Sin tema, el chat propone uno y te lo confirma. Le escribe al chat que mirás si es un Claude
(el hook tiene su estado); si no, al chat de bk de ese espacio. alt+k le pasa la terminal que mirás (`--to`). Con un
menú abierto en el chat no escribe nada (el Enter elegiría la opción marcada). Reemplaza a la bitácora de agentes
generada (`lib/bitacora.py` y el `scripts/agents/bitacora.py` del kit, que #343 sacó). Tests: `tests/test_bitacora.sh`.

## Dotfiles
- `dotfiles/tmux.conf` → `~/.config/tmux/tmux.conf`
- `dotfiles/ghostty/bk-day`: tema violeta pastel (modo day). `bk theme` apunta la línea `theme` de la config de Ghostty
  a ese archivo (day), a `Shades Of Purple` (night) o a los dos según macOS (auto), y recarga Ghostty con SIGUSR2.

`~/.config/tmux/tmux.conf` es un enlace simbólico a este repo: se edita acá y queda versionado.

## Hook de estado (`hooks/agent_state.sh`)
Un hook de Claude Code anota el estado de cada sesión (trabajando, te espera, terminó, en segundo plano), su rol, modelo,
issue y pane en `~/.cache/sketchybar/agents/<sesión>.json`; de ahí leen `bk ls`, la tira, el riel, `bk monitor`, `bk s` y
los paneles de Herdr. También escribe el `bk say` encolado cuando el agente termina el turno y, en Herdr, lanza los
nombres vivos de los chats (`lib/names.py`). La carpeta conserva el
nombre de cuando el estado era de la barra de Sketchybar, que ya no está: las sesiones vivas escriben ahí.

Va registrado en `~/.claude/settings.json` en `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionRequest`, `Notification`, `SubagentStart`, `SubagentStop`, `Stop`, `StopFailure` y
`SessionEnd`: `{"type": "command", "command": "~/barrilete-workspace/hooks/agent_state.sh", "timeout": 5}`.
Una instalación de antes lo registra como `~/.config/sketchybar/plugins/agent_hook.sh` (con `~/.config/sketchybar`
enlazado a `dotfiles/sketchybar`); por eso queda el enlace versionado `dotfiles/sketchybar/plugins/agent_hook.sh`, que
apunta al hook. Al cambiar esa ruta en `settings.json` se pueden borrar el enlace y `~/.config/sketchybar`.

### Tareas en Herdr

Las tareas del kit se ven con `alt+e`: por aprobar, te esperan y en marcha; Tab suma el historial. Enter sobre un
reviewer propuesto se lanza con `bk approve <tarea>` desde una terminal humana separada; sobre una tarea con agente, va a su pestaña. La barra de estado dice
cuántas te esperan y su clic abre el mismo panel. Los datos son los de `bk _tasks` (lo mismo que `bk tasks --json`,
con el título de cada issue o PR: de la caché de `bk ls`; lo que falta se le pide a GitHub, hasta 8 por vez).

El tablero «Tareas de Barrilete» (`herdr/mods/tareas`, con su espacio **Barrilete · Tareas**) quedó abandonado:
`bk-lavanda` ya no lo muestra ni tiene su acceso en la barra izquierda. El mod sigue en el repo y `bk backend herdr`
lo sigue copiando a `mods/bk-tareas`, pero nada lo abre. Tests: `tests/test_herdr_tasks.sh` (necesita `node`) y
`tests/test_tasks_titles.sh`.

### Subagentes de Claude en Herdr

El panel `bk-agentes`, clon del panel nativo, conserva estados, agrupación, pines
y subagentes de herdr-core. También muestra debajo de cada sesión sus subagentes
internos de Claude (`Agent`), con descripción, tipo y número estable como bk-shell.
`bk _subagents` relaciona los hooks de sesión con los metadatos de Claude: excluye
los terminados y los que llevan más de diez minutos sin escribir, igual que bk-shell.
Se actualiza cada cuatro segundos; el clic abre `bk sub` para seguir el transcript
en una pestaña de solo lectura. No envía instrucciones al subagente.

Un chat que terminó el turno dejando comandos en segundo plano (tests, CI, un `Monitor`) no aparece como listo:
Herdr lo ve quieto, pero `bk _subagents` también devuelve cuántos comandos siguen corriendo en cada terminal (los que
el hook contó al terminar el turno, `state: "background"`). La fila tiene su marca (un medio círculo que gira, ◐) y
su sección, **En 2º plano**, entre Trabajando y Quietos, con «N en 2º plano» en su segunda línea (sin el número si el hook no lo tiene). Si Herdr ve que te espera o que trabaja, manda Herdr. La barra de abajo, las pestañas y la cabecera
del pane siguen con el estado de Herdr.

### Las épicas en la barra

Entre ESPACIOS y AGENTES, `bk-agentes` tiene la sección **ÉPICAS** (plegable): una tarjeta por cada épica en la que
trabajan los chats (una aunque la tengan varios, aunque estén en espacios distintos) con **#N título k/n**, una barra
con un segmento por sub-issue (hecho, con agente, libre o bloqueado, en ese orden) y una línea con lo que importa:
**ahora #324 · t75 · destraba 5 · 1 libre** si un chat trabaja en uno (destraba: los abiertos que lo esperan, directa
o indirectamente), si no **2 libres: kit#325, workspace#11**. Si la épica cruza repos, el número lleva el repo y una
línea dice cuánto lleva cada uno (`kit 2/4 · workspace 1/5`). La fila de cada agente dice **#324 de #321**. Van
primero las épicas con algo libre (donde podés lanzar), después las demás en curso. Si los chats de algún espacio ya
no tienen épica, queda una sola en gris al final: la última que tuvo el espacio que la dejó más recientemente
(guardada entre reinicios).

El clic en la tarjeta, o `alt+p` (la épica del chat que mirás; si no tiene, la única en curso o, con varias, una lista para elegirla con ↑↓ y ⏎), abre el detalle: AHORA,
LIBRES, BLOQUEADOS (cada uno con lo que espera) y HECHOS plegado, con el camino más largo de esperas. ↑↓ mueven, ⏎ (o el
clic) va al agente de los de AHORA, `g` abre GitHub, `esc` cierra. ⏎ sobre un libre pide
confirmación mostrando `bk run N · en <carpeta>` y el segundo ⏎ lo lanza ahí, suelto (`bk _do`: sigue aunque se
cierre el popup y avisa al terminar, con el error si falló; el rol lo decide bk). Los datos los deja la barra en `shared("bk.epics")`.

`bk _epica <carpeta> [rama] [texto] [terminal]` (`lib/herdr_epica.py`; `bk _epica --json '[[carpeta, rama, texto,
terminal], …]'` para todos los chats en una llamada) saca el issue de la carpeta (un worktree `<repo>-wt/1152` o `<repo>-wt/1152-algo`), de
la conversación de Claude de esa terminal (el último `<repo>-wt/N` o `prepare.sh N` en los comandos que corrió: un
chat abierto en el checkout principal implementa en un worktree sin mover su carpeta, y la rama del checkout
puede ser de otro chat), de la rama (`claude/1152-…`, `claude/<tipo>/1152-…`) o de un `#1152` en el nombre del
chat; el repo, del remoto `origin` (o del único remoto de GitHub). La épica es su padre en GitHub (puede estar en
otro repo) o el issue mismo si tiene sub-issues. De cada épica trae los sub-issues (`/sub_issues`, de cualquier
repo) y, de los abiertos, los issues abiertos que los bloquean (`/dependencies/blocked_by`), y en `dirs` dónde
lanzar los de cada repo: el checkout principal de sus chats, si no `~/<nombre del repo>`. A GitHub le pregunta una
vez por issue y por épica, en paralelo, y lo guarda cinco minutos en `~/.cache/bk/epica.json` y
`~/.cache/bk/epica-subs.json`: la barra pregunta cuando cambian los chats y cada minuto, nunca en cada dibujo. Sin
red, lo último guardado.

La cabecera de Lavanda muestra **BK** y el barrilete de la marca, que cambia según haya quien te espere, quien
trabaje o nadie (`herdr/mods/marca/bk-wait.svg`, `bk-fly.svg`, `bk-rest.svg`). El mod propio `bk-marca` conserva
los controles de búsqueda y de la barra lateral sin editar Herdr, y en su pie van ajustes, aspecto y agregar una
máquina.

Entre la marca y la lupa van tus **accesos directos** (`herdr/mods/marca/accesos.js`): una página, una carpeta, un
archivo o una app, que el clic abre con `open`. Se agregan soltando archivos o apps sobre la cabecera, o con el +
(aparece al pasar por encima; siempre, si no hay ninguno), que abre un popup para pegar una URL o una ruta
(`github.com/x`, `localhost:3000`, `~/Documents`, `obsidian://…`) o elegir una carpeta. El clic derecho sobre uno
abre esa lista, donde se sacan con ×. Entran los que caben en el ancho de la barra; los demás, en un +N. Se guardan
en `~/.config/herdr-app/bk-accesos.json`.

### Datos para los paneles nativos (`bk _hub`) y acciones sueltas (`bk _do`)

Un mod de Herdr solo puede correr programas y leer su salida. `bk _hub <tema>` (`lib/herdr_hub.py`) le da cada
cosa en un JSON: `issues`, `prs`, `agents`, `sessions` (y `session-go <sid>`), `changes` (y `diff <raíz> <archivo>`),
`stats`, `projects`, `handoffs`, `checkpoints`, `song`, `status` (lo de la barra de estado, en una llamada barata) y
`palette`. Usa las mismas funciones que los comandos de la terminal (`bk ls`, `bk s`, `bk changes`, `bk tokens`…),
así que muestran lo mismo. Si no puede, sale con 1 y una línea en stderr. Lo que le pregunta a GitHub se guarda 60 s
en `~/.cache/bk/hub/` (`--fresh` lo saltea; sin red sale lo guardado con `"stale": true`). El contrato de cada
tema está en el encabezado de `lib/herdr_hub.py`.

`bk _do [--cwd DIR] [--title T] -- <args de bk…>` corre ese `bk` suelto de quien lo pidió (sobrevive al panel),
con la salida en `~/.cache/bk/hub/do/<fecha>-<pid>.log`, y vuelve en el acto con `{"ok": true, "log": …}`. Al
terminar deja un aviso de Herdr con la última línea de la salida: `success` si salió con 0, `error` si no (si esa
línea es un JSON, como el de `bk _hub session-go`, el aviso lo dice en palabras). Con `--dry-run` dice qué
correría y no deja log ni aviso. Los avisos de bk (`hd_notice`) van a una cola, un archivo por aviso en
`~/.cache/bk/herdr-avisos/`, para que dos casi juntos no se pisen; `~/.cache/bk/herdr-aviso.json` sigue quedando
con el último. El mod `bk-aviso` muestra la cola en orden, cada aviso con su nivel (uno de error queda 15 s a la
vista, el resto 5 s; el que abre un mod con el clic, diez minutos), y la vacía; uno de hace más de diez minutos
se borra sin mostrarse. Tests: `tests/test_hub.sh` y `tests/test_herdr_mods.sh`.
