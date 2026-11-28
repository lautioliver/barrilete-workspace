# Recorridos — barrilete-workspace

> Flujos de punta a punta, paso por paso, con los archivos que intervienen.

## Implementar un issue (`bk run <n>`, o `alt+i` en Herdr)

1. `bin/bk` busca la raíz del proyecto (tiene que tener `scripts/agents/guardrails.py`).
2. `.claude/skills/orchestrate/routing.py` del proyecto elige el rol (`implementer` o `implementer-light`); `roles.yml`, el perfil (`lib/profiles.py`) y `.barrilete/roles.yml` dicen el provider y el modelo.
3. `.claude/skills/implement-issue/prepare.sh --worktree` asigna el issue y crea el worktree.
4. `lib/tasks.py create` crea la tarea `<n>-<rol>`; si ya hay una activa, no se lanza otro agente.
5. bk suelta el candado del worktree, abre la ventana `i<n>` (tmux) o la pestaña (Herdr, `lib/herdr.sh`) y corre el agente con `BK_TASK_DIR`.
6. `hooks/agent_state.sh` anota su estado; los hooks del kit, los eventos de la tarea.
7. El agente abre el PR y cierra con `bk done pr <n>`: la tarea queda `completed` y se propone `pr<n>-reviewer`, que la persona lanza con `bk approve` desde una terminal humana separada.

## Entrar a main (`bk land --wait`)

1. Desde el worktree de la rama, con todo commiteado.
2. `lib/land.py` espera a las ramas activas que empezaron antes y comparten archivos (claims).
3. Con el mutex de `main`, rebasa sobre `main` y corre `lib/checks.sh` una vez.
4. Hace el fast-forward (el hook `githooks/reference-transaction` lo deja pasar) y anota la rama en `~/.cache/bk/landed.json`.
5. `lib/branches.py` borra después la rama y el worktree cuando ya no corre nada ahí.

## Seguir en un chat nuevo (`bk handoff`, o `alt+h`)

1. `lib/context_hook.py` avisa al agente al cruzar el ámbar y el umbral de contexto (o la persona lo pide con `bk handoff [N]`).
2. El agente escribe el resumen con el formato de `lib/handoff.py` en `~/.local/state/bk/handoffs/<session_id>.md`.
3. El hook ve el Write de ese archivo y corre `bk handoff --listo <sesión>`.
4. `bk chat --desde` abre el chat nuevo en la misma carpeta y con la misma cuenta, con el resumen como primer mensaje.

## Un panel de Herdr (por ejemplo `alt+i`)

1. `herdr/keys.json` abre el mod `bk-issues` (`mod.open:bk-issues`), una copia de `herdr/mods/hub/`.
2. El mod corre `bk _hub issues` (`lib/herdr_hub.py`) y dibuja el JSON con `kit.js`.
3. Enter corre `bk _do -- run <n>`: bk lanza suelto, deja el log en `~/.cache/bk/hub/do/` y avisa al terminar.
