# Arquitectura implementada — barrilete-workspace

> Lo que corre hoy. Si otro documento dice otra cosa, gana este (y el código).

## Piezas

- **`bin/bk`** (bash): el punto de entrada. Tiene la ayuda (`usage`), despacha cada comando y lanza a los agentes. Los comandos con `_` delante (`bk _hub`, `_do`, `_side`, `_epica`, `_todo`, `_adopt`…) son internos: los llaman los mods de Herdr, los hooks y la tira.
- **Backend** (`BK_BACKEND`, o `~/.config/bk/backend`): `tmux` por defecto; `herdr` carga las funciones de `lib/herdr.sh`, que usan `herdr-app` (espacios y pestañas) y `hc` (leer, escribir y cerrar terminales). Lo que en tmux es el nombre de la ventana y sus `@opciones`, en Herdr son etiquetas de la terminal (`bk.kind`, `bk.win`, `bk.project`, `bk.role`, `bk.ref`, `bk.id`).
- **`lib/*.py`** (Python, biblioteca estándar): cada comando con lógica o pantalla tiene su módulo (ver [módulos](../reference/modules.md)). Las pantallas de terminal son `curses`.
- **Feedback de ruteo** (`lib/routing_feedback.py`): `bk routing` valida eventos de despacho/resultados y guarda JSONL local bajo `${XDG_STATE_HOME:-~/.local/state}/bk/routing/` bajo un `flock`; a los 180 días compacta cada tarea en `aggregates.json` (mensual, sin IDs) y borra sus líneas; su resumen no se replica por Herdr ni se envía al proveedor. El bus/los leases propuestos por ADR-003 tienen otro directorio (`bk/supervisor/`).
- **Arbitraje local** (`lib/supervisor.py`): `bk supervisor` valida planes y reserva issues/PRs y slots de forma atómica antes de cualquier lanzamiento. Lleva un lease por asignación (`reserved → running → stale → completed|released`) y `reconcile` marca `stale` sin heartbeat por 5 min (un heartbeat verificado de la misma identidad lo devuelve a `running`) y libera solo con salida verificada de proceso y sesión; sin adaptador de harness registrado ningún lease arranca, y no lanza procesos; el store de planes y eventos queda en `${XDG_STATE_HOME:-~/.local/state}/bk/supervisor/`.
- **`herdr/`**: mods en JavaScript (paneles del hub, acciones sin panel, piezas del layout), `keys.json`, el layout `bk-lavanda` y los temas. `lib/herdr_install.py` los copia a `~/.config/herdr-app`. Un mod solo puede correr programas y leer su salida: pide los datos a `bk _hub <tema>` (JSON) y lanza con `bk _do`.
- **Hooks**: `hooks/agent_state.sh` (estado de cada sesión de Claude Code), `hooks/codex_handoff.py` (registro de sesiones Codex y cierre de handoff), `scripts/agents/cursor_state.py` (estado de Cursor Agent), `lib/context_hook.py` (aviso de contexto alto), `lib/tmux_guard.py` (frena `tmux kill-server` sobre el servidor real) y los del kit (`scripts/agents/guardrails.py`, `task_events.py`). `githooks/reference-transaction` rechaza cualquier cambio de `main` que no venga de `bk land`.

## Cómo fluye el estado

1. Claude Code y Cursor Agent disparan sus hooks de ciclo de vida.
2. `hooks/agent_state.sh` y `scripts/agents/cursor_state.py` escriben en `~/.cache/sketchybar/agents/<sesión>.json`: estado, rol, modelo, issue y pane (en Herdr, la terminal de `HC_TERMINAL_ID`).
3. `lib/agents.py` lee esos archivos y los cruza con las ventanas de tmux o las terminales de Herdr; de ahí leen `bk ls`, la tira, el riel, `bk monitor`, `bk s` y `bk _hub`.
4. Los glifos y colores de cada estado salen de `gentle.STATES` (`lib/gentle.py`).

## Cómo se lanza un agente (`bk run <issue>`)

`routing.py` del kit (`.claude/skills/orchestrate/`) elige el rol, `prepare.sh --worktree` asigna el issue y crea el worktree, `lib/tasks.py` crea la tarea (`~/.local/state/bk/tasks/<proyecto>/<id>/`) y bk abre la ventana (tmux) o la pestaña (Herdr) con `claude`, el rol y `BK_TASK_DIR` en el entorno. El agente cierra con `bk done`. Detalle en [recorridos](../reference/journeys.md).

## Estado en disco

Sin base de datos. Ver [dominio y datos](../reference/domain.md).

## Tests

`tests/test_*.sh`: bash con salida TAP propia (`ok N - …`). Apuntan todo a carpetas temporales y, para Herdr, usan un `herdr-app` y un `hc` falsos (`tests/herdr_fake.py`). `lib/checks.sh` corre la sintaxis de bash, `py_compile`, `lib/check_test_fns.py` y todos los tests; es lo que corre `bk land`. Lo que no está probado: apretar las teclas dentro de Herdr.
