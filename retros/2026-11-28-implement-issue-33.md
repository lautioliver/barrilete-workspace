---
skill: implement-issue
issue: 33
pr: 43
area: infra
paths: opencode.jsonc, .opencode/plugins/bk-guardrails/, tests/test_opencode_guardrails.sh, README.md, AGENTS.md, docs/agents/opencode.md, docs/agents-map.json, docs/development/architecture.md
date: 2026-11-28
skill_sha: 6178344b6aed453e550d10ea5943573013ff79f4
model: unknown
role: session
---
**Desvíos:** El PR #43 y su commit en rojo ya existían; esta sesión solo integró `origin/main` (fix de #53) para destrabar el CI, actualizó el cuerpo del PR y verificó checks. No se corrió `prepare.sh` ni `red.sh` de nuevo. `/code-review` y `/security-review` no existen en esta sesión de OpenCode: se revisó el diff contra `main` a mano y se hicieron correr `lib/checks.sh`, `check-docs.py`, el test de OpenCode (47/47) y `verify.py`. El push lo ejecutó la persona en una terminal normal porque el plugin del propio PR deniega todo `git push`, incluso a la rama de trabajo.
**Decisiones no cubiertas:** Traer el fix del test 129 desde `main` con un merge en vez de arreglarlo en este PR (era ajeno al issue y ya estaba merged en #53). No se cambió ninguna regla de negocio ni se ampliaron permisos.
**Lo que encontró la revisión:** La revisión previa de barrilete-dot había marcado 4 bloqueantes (hook de land sin el subcomando `hook`, deny del hook descartado, guardrail fallando abierto y allows que evadían los deny); ya estaban corregidos en commits anteriores. El único CI en rojo restante era el caso 129 de README, preexistente en `main`, resuelto por #53.
**Propuesta:** `opencode.jsonc` deniega `git push` de forma global, así que el propio agente no puede publicar su PR y tiene que pedir una terminal humana. Aflojarlo a deny solo de refs troncales (`main`) con allow explícito para `git push origin HEAD` haría la integración usable sin debilitar la protección de `main`.
