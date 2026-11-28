---
skill: implement-issue
issue: 35
pr: 44
area: infra
paths: lib/supervisor.py, lib/human_cli.py, bin/bk, .codex/hooks.json, scripts/agents/test_guardrails.py, tests/test_supervisor.sh, tests/test_supervisor_events.sh, tests/test_human_cli.sh
date: 2026-11-28
skill_sha: 6178344b6aed453e550d10ea5943573013ff79f4
model: opus
role: session
---
**Desvíos:** se abrió el PR con dos checks de verify.py en rojo (shellcheck de tests/test_herdr.sh y orchestrate 129), los dos ya rojos en origin/main y verificados en un checkout limpio; quedan en #52 y en el PR. El rojo de 840ecd4 no tiene bloque de red.sh porque tests/test_supervisor.sh no usa tap.sh: se pegaron las líneas `not ok` reales.
**Decisiones no cubiertas:** /security-review tomó el diff del checkout de main (vacío) y no el del worktree: hubo que lanzarlo a mano sobre `origin/main...HEAD` del worktree. El salto con `bk _do` quedó fuera del alcance por decisión de la persona (#45).
**Lo que encontró la revisión:** /code-review: línea cortada en events.jsonl, `$1` sin argumentos con set -u, human_cli ciego a node/cursor-agent, hook de handoff sin guarda. /security-review: approve/cancel se podían aprobar desde un agente entrando directo a supervisor.py bajo un pty (arreglado) y `bk _do -- say` saltea hook y human_cli (#45). De paso: .codex/hooks.json de main repite claves y deja sin registrar el guardrails de Codex.
**Propuesta:** que implement-issue diga cómo correr /security-review desde un worktree distinto del checkout de la sesión; pasar tests/test_supervisor.sh a tap.sh para que red.sh lo vea.
