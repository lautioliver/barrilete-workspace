---
skill: implement-issue
issue: 45
pr: 56
area: infra
paths: lib/human_cli.py, lib/herdr_hub.py, scripts/agents/guardrails.py, scripts/agents/test_guardrails.py, tests/test_human_cli.sh, tests/test_hub.sh, README.md
date: 2026-11-28
skill_sha: 6178344b6aed453e550d10ea5943573013ff79f4
model: opus
role: session
---
**Desvíos:** `/security-review` no corrió: revisa la rama de la sesión (main), no el worktree; revisión a mano de variantes. El rojo de Python (test_guardrails.py) no pasa por red.sh porque `red` no tiene stack de Python: va descrito en el PR. Le puse `priority:high` al PR y el check de labels lo rechazó (priority solo en issues).
**Decisiones no cubiertas:** la propuesta del issue ("_do rechaza siempre") rompía el botón de aprobar del hub de Herdr, que usa `bk _do -- approve`; se le preguntó a la persona y eligió chequear en _do con el árbol de quien llama. Un test viejo (test_hub 128) dependía del agujero y se cambió de comando.
**Lo que encontró la revisión:** /code-review: `_hub _do` es otro `_do` y se escapaba de los dos chequeos; un `--dry-run` como valor de `--title`/`--cwd` apagaba el hook; `a_ojo` no veía `_do`. A mano: `''` se tomaba como separador de comandos en el hook, y la recursión del hook fallaba abierta con anidado hondo. Ya existía: procesos colgados de launchd (doble fork, tmux new-window) pasan por humanos (issue aparte, pendiente de confirmación).
**Propuesta:** que implement-issue diga que `/security-review` no sirve desde un worktree distinto del checkout de la sesión, y que priority no va en PRs.
