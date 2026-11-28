# Dominio y datos — barrilete-workspace

> Entidades, tablas, IDs, estados y sus transiciones.

No hay base de datos: todo es archivos en la máquina de la persona.

## Dónde vive cada dato

| Dato | Archivo | Lo escribe |
|---|---|---|
| Estado de cada sesión de Claude | `~/.cache/sketchybar/agents/<sesión>.json` | `hooks/agent_state.sh` |
| Tareas de los agentes | `~/.local/state/bk/tasks/<proyecto>/<id>/task.json` y `events.jsonl` | `lib/tasks.py`, los hooks del kit |
| Resúmenes para seguir (handoff) | `~/.local/state/bk/handoffs/<session_id>.md` (y `.json`, `.cerrar`) | el agente, con el formato de `lib/handoff.py` |
| Cuentas | `~/.local/state/bk/accounts/<nombre>/` | `lib/accounts.py` |
| Claims de `bk land` | `~/.local/state/bk/claims/` (`BK_CLAIMS_DIR`) | `lib/land.py`, el hook de `.claude/settings.json` |
| Ramas que entraron | `~/.cache/bk/landed.json` | `lib/land.py` |
| Caché de PRs de checkpoints | `~/.cache/bk/checkpoints_prs.json` | `bk _prs` |
| Caché del hub de Herdr | `~/.cache/bk/hub/` | `lib/herdr_hub.py` |
| Épicas | `~/.cache/bk/epica.json`, `epica-subs.json` | `lib/herdr_epica.py` |
| Feedback del ruteo (ADR-002) | `${XDG_STATE_HOME:-~/.local/state}/bk/routing/`: `events.jsonl` (180 días como máximo), `aggregates.json` (mensual, sin IDs), `.lock` | `lib/routing_feedback.py` |
| Config de la persona | `~/.config/bk/` (`backend`, `context`, `profiles.yml`, `tareas.yml`, `models.yml`, `gh-app.json`) | los comandos de bk |

## IDs

- **Tarea**: `<issue>-<rol>` o `pr<n>-<rol>` (por ejemplo `42-implementer`, `pr57-reviewer`).
- **Ventana de agente**: `i<issue>` o `pr<n>` (`i42`, `pr57`).
- **Número fijo** (`@bk_id` en tmux, etiqueta `bk.id` en Herdr): el número libre más bajo al nacer; se conserva hasta cerrarse.

## Estados

**Tarea** (`lib/tasks.py`, ADR-005 del kit): `pending` → `in_progress` ↔ `waiting` → terminal. Los terminales no cambian nunca:
- `completed`: `bk done pr <n>` o `bk done blockers`.
- `failed`: `bk done dropped "…"` o `bk done escalate "…"`.
- `incomplete`: el proceso terminó sin `bk done`.
- `cancelled`: la persona lo paró (`bk stop`).

**Sesión** (`gentle.STATES` en `lib/gentle.py`): `working` (trabajando), `background`, `waiting` (te espera), `permission`, `question`, `stale` (¿trabado?), `trust`, `done` (listo), `idle` (libre), `ended`, `none`, `error`.
