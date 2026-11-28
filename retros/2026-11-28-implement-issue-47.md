---
skill: implement-issue
issue: 47
pr: 58
area: none
paths: bin/bk, tests/test_chat_provider.sh, README.md
date: 2026-11-28
skill_sha: 6178344b6aed453e550d10ea5943573013ff79f4
model: opus
role: session
---
**Desvíos:** Dos issues (#47 y #48) en un solo PR, a pedido de la persona; `prepare.sh` toma uno solo, así que #48 lo asigné a mano. `--name 47-48-…` le volvió a poner el número delante (`claude/47-47-48-…`) y tuve que renombrar la rama; el worktree quedó con el nombre duplicado. El primer verde agregó casos (nombre desconocido) con `tap_run out 1`, que nunca pasaron por rojo; los probé rompiendo el código a mano.
**Decisiones no cubiertas:** Que un `BK_CHAT_PROVIDER` desconocido falle en vez de abrir Claude (lo dejé dicho en el PR). Que `bk` con tmux también saque el comando del proveedor (lo trajo la revisión, fuera de la letra de los issues).
**Lo que encontró la revisión:** `/code-review` encontró 3 importantes: el arreglo pisaba el `WS_CHAT_CMD` de quien llama (retomar desde `bk s` dejaba de hacer --resume), el test se colgaba en una terminal (faltaba el stdin de /dev/null) y `workspace()` pasaba la cuenta de codex pero abría claude. Los tres los vi solo por la revisión.
**Propuesta:** En `prepare.sh --name`, no anteponer el número si la descripción ya empieza con él. En la skill: al tocar una función compartida (`choose_chat_provider`), buscar a todos sus llamadores antes del verde, también los de otros backends (Herdr, `lib/sessions.py`).
