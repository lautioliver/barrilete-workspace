# Glosario — barrilete-workspace

> Palabras del dominio que no se cambian. Una por fila: término, definición, cómo se llama en el código y a qué contexto pertenece (ver [contextos](contexts.md)).

| Término | Definición | Nombre en el código | Contexto |
|---|---|---|---|
| backend | Dónde viven los chats y los agentes: el workspace de tmux o la app Herdr | `BK_BACKEND`, `~/.config/bk/backend`, `lib/herdr.sh` | — |
| workspace | Con tmux, la sesión `bk-<proyecto>` con chat, riel y tira; uno por proyecto | `bk ws`, `@bk_id` | — |
| espacio | Con Herdr, el lugar de un proyecto: su chat y una pestaña por agente | etiqueta `bk.project` | — |
| lista de espacios | El orden, las carpetas, el color y la imagen de los espacios en la barra de Herdr; una copia por máquina (ADR-001) | `shared("bk.espacios")` (mod `agentes`, de #8) | — |
| máquina | Una computadora conectada a Herdr; entre máquinas se nombra por su hostname, no por el alias de `hc machine` (ADR-001) | `.machine`, `host` de `hc machine ls` | — |
| chat | Un `claude` donde habla la persona; no tiene tarea | `bk chat`, `bk.kind` | — |
| agente | Una sesión que bk lanza con un rol sobre un issue o un PR, en su ventana o pestaña | `launch` en `bin/bk`, `lib/agents.py` | — |
| rol | Qué hace un agente: `implementer`, `implementer-light`, `reviewer`, `planner`, `orchestrator` | `BARRILETE_ROLE`, `roles.yml` | — |
| ventana | El nombre del agente: `i<issue>`, `pr<n>` | `bk.win`, nombre de la ventana de tmux | — |
| número fijo | El número libre más bajo que toma un chat o un agente al nacer y conserva hasta cerrarse | `@bk_id`, `bk.id` | — |
| tarea | El trabajo de un agente, con estado y eventos (ADR-005 del kit) | `lib/tasks.py`, `task.json`, `events.jsonl` | — |
| te espera | Un agente o chat que necesita a la persona (pregunta, permiso, terminó) | estados `waiting`, `permission`, `question` | — |
| checkpoint | Algo que un agente no puede hacer por la persona y la espera: un plan, un reviewer propuesto, un PR, una lección | `lib/checkpoints.py` | — |
| resumen (handoff) | El texto con formato fijo para seguir un chat en uno nuevo | `lib/handoff.py`, `bk handoff` | — |
| umbral de contexto | Cuánto contexto lleva un chat antes de pedirle el resumen; ámbar en 3/4 | `~/.config/bk/context`, `lib/context_hook.py` | — |
| land | Entrar una rama a `main`: esperar turno, rebasar, checks y fast-forward | `bk land`, `lib/land.py` | — |
| claim | El registro de qué archivos modifica una rama, para ordenar los land | `lib/land.py`, `bk claims` | — |
| adopción | Que bk tome como chat suyo un agente abierto desde Herdr sin sus etiquetas | `bk _adopt`, `bk.adopted` | — |
| épica | El issue padre de lo que trabaja un chat, con sus sub-issues | `lib/herdr_epica.py`, `bk _epica` | — |
| perfil | Un juego de provider/modelo por rol que se cambia de una vez | `lib/profiles.py`, `profiles.yml` | — |
| cuenta | Una config de Claude Code o Codex propia, con las mismas conversaciones | `lib/accounts.py`, `bk account` | — |
| desvío | Algo que un agente hizo mal y quedó registrado (baranda, verificación fallida, corrección) | `lib/learn.py`, `lib/deviations.py` | — |
| marca de sesión (propuesto) | El archivo que escribe el hook de inicio de una sesión de un harness (`sessions/<harness>-<session_id>.json`, con `pid`, `process_start`, `ended_at`) para que el supervisor sepa si sigue viva; nunca prueba por sí sola | `sessions/<harness>-<session_id>.json` (ADR-003 de este repo) | — |
| lease sin enlazar (propuesto) | Un lease `reserved`: todavía no se sabe qué proceso y sesión lo usan (un lease iniciado siempre tiene `session_id`) | `new_lease` (`lib/supervisor.py`) | — |
| enlazar (propuesto) | Asociar a un lease una marca de sesión y su proceso; cuándo y cómo se elige la marca está abierto (ADR-003, *Preguntas abiertas*). Hoy `start_lease` recibe el `session_id` | `start_lease` (`lib/supervisor.py`) | — |

La columna Contexto queda en «—» mientras no haya contextos declarados (ver [contextos](contexts.md)). Un término que no está acá se propone en el PR que lo introduce.
