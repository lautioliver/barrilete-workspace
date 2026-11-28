---
skill: implement-issue
issue: 36
pr: 55
area: none
paths: docs/decisions/ADR-003-supervision-local-y-leases.md, docs/decisions/supervision-local-y-leases.html, docs/reference/glossary.md
date: 2026-11-28
skill_sha: 6178344b6aed453e550d10ea5943573013ff79f4
model: sonnet
role: implementer
agent_sha: 6178344b6aed453e550d10ea5943573013ff79f4
---
**Desvíos:** sin commit en rojo ni `red.sh` (solo docs, declarado `sin tests` en el PR). Corrí `verify.py` con todo commiteado; no corrí `/code-review` en esta vuelta (solo docs, revisé el diff a mano). No guardé la retro hasta que la persona la pidió.
**Decisiones no cubiertas:** el árbol venía con un diff sin commitear de otro implementer (puntos 3 y 5, ADR-004/005, base de PR); lo incluí porque el PR y el chat lo daban por decidido, y lo avisé. Qué hacer con un lease `reserved` y la sesión padre no estaba decidido: lo dejé como pregunta abierta y quité del texto la regla que elegía la marca.
**Lo que encontró la revisión:** el punto del límite global seguía diciendo "subagentes internos" en el ADR y en el boceto HTML; y las decisiones no estaban respaldadas por un comentario de la persona en #36/PR.
**Propuesta:** que la skill diga cómo retomar un PR existente (qué hacer con un diff sin commitear heredado) y que `verify.py` avise cuando tarda más de 120 s para correrlo en segundo plano.
