# Módulos — barrilete-workspace

> Dónde vive cada cosa en el código y qué es responsable de qué.

Cada archivo de `lib/` dice en su encabezado qué hace y cómo se usa; esta tabla los agrupa.

| Área | Archivos | Responsable de |
|---|---|---|
| Entrada | `bin/bk` | ayuda, despacho de comandos, lanzamiento de agentes, workspace de tmux |
| Backend Herdr | `lib/herdr.sh`, `lib/herdr_install.py`, `herdr/` | espacios, pestañas y etiquetas en Herdr; instalar mods, teclas, temas y layout |
| Varias máquinas | `lib/machines.py` | `bk machines sync`: el mismo commit de bk en cada máquina conectada a Herdr |
| Datos para Herdr | `lib/herdr_hub.py`, `lib/herdr_side.py`, `lib/herdr_epica.py` (con `lib/kit_check.py`: dónde se puede lanzar y por qué no), `lib/herdr_todo.py`, `lib/herdr_tasks.py`, `lib/herdr_subagents.py` | el JSON de cada panel (`bk _hub`, `_side`, `_epica`, `_todo`, `_tasks`, `_subagents`) |
| Agentes y estado | `hooks/agent_state.sh`, `lib/agents.py`, `lib/gentle.py`, `lib/names.py` | estado de cada sesión, quién es quién, glifos y colores, nombres vivos |
| Tareas | `lib/tasks.py`, `lib/checkpoints.py` | tareas del kit (ADR-005), `bk done`, `bk approve`; lo que te espera |
| Seguir en otro chat | `lib/handoff.py`, `lib/context_hook.py` | formato del resumen; aviso de contexto alto |
| Entrar a main | `lib/land.py`, `githooks/reference-transaction`, `lib/checks.sh` | `bk land`, claims, hook que protege `main`, los checks |
| Ramas | `lib/branches.py`, `lib/changes.py`, `lib/clean.py` | ramas y worktrees que se pueden borrar, lo sin commitear, limpieza de restos |
| Pantallas de terminal | `lib/sessions.py`, `lib/monitor.py`, `lib/palette.py`, `lib/new.py`, `lib/rail.py`, `lib/sidebar.py`, `lib/agents_view.py`, `lib/subwatch.py`, `lib/customize.py`, `lib/stats.py`, `lib/song_ui.py` | `bk s`, `monitor`, `palette`, `new`, riel, tira, `watch --all`, `sub`, `customize`, `stats`, `song ui` |
| Modelos y cuentas | `lib/profiles.py`, `lib/models.py`, `lib/ask.py`, `lib/accounts.py`, `lib/ghapp.py` | perfiles, modelos por proveedor, `bk ask`, cuentas por sesión, GitHub App de los agentes |
| Uso y retroalimentación | `lib/usage.py`, `lib/metrics.py`, `lib/learn.py`, `lib/deviations.py`, `lib/effect.py`, `bin/bk` (`bk bitacora`) | tokens y costo, métricas por PR, desvíos y lecciones, efecto de las reglas, bitácora (se la pide a un chat) |
| Feedback de ruteo | `lib/routing_feedback.py`, `bin/bk` (`bk routing`) | eventos locales validados, resumen JSON de resultados por proveedor/modelo/rol y compactación a agregados mensuales a los 180 días |
| Arbitraje local | `lib/supervisor.py`, `bin/bk` (`bk supervisor`) | validación de planes, aprobación humana, reserva atómica de issues/PRs y slots, cola prioritaria, estado y transiciones de leases (`reconcile`: stale a los 5 min, liberación solo verificada); no lanza agentes y sin adaptador de harness ningún lease arranca |
| Barandas | `lib/tmux_guard.py`, `lib/check_test_fns.py`, `lib/human_cli.py`, `scripts/agents/guardrails.py` | no tirar el tmux real; que un test no corra el `bk` real; impedir `bk say` y `bk approve` desde procesos de agentes |
| Varios | `lib/song.sh`, `lib/agent_sound.sh`, `lib/layout.conf`, `dotfiles/` | radio, sonidos, proporciones del workspace, configs de tmux y Ghostty |
| Tests | `tests/test_*.sh`, `tests/herdr_fake.py`, `tests/herdr_stub/` | un test por área; Herdr falso |
