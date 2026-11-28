# AGENTS.md — barrilete-workspace

Contexto rápido para agentes y devs que tocan este repo. Es la fuente de las reglas para LLMs: `CLAUDE.md` solo lo importa.

## Qué es

`bk`: la herramienta de línea de comandos que maneja los chats y los agentes de Claude Code (y Codex) de los proyectos [Barrilete Kit](https://github.com/lautioliver/barrilete-kit), sobre tmux o sobre la app Herdr (`bk backend tmux|herdr`). La decisión que lo define: `main` está protegido y varias sesiones trabajan a la vez, cada una en su worktree, y entran con `bk land --wait` (ver `README.md`, *main protegido*). Todavía no hay un ADR propio que lo diga; los que aplican hoy son los del kit en `docs/decisions/kit/` (sobre todo ADR-004 y ADR-005).

Índice de docs (humanos + LLMs): `docs/README.md`. Spec: `README.md`. Narrativa: `docs/development/vision.md`. Qué corre hoy: `docs/development/architecture.md`. Orden de trabajo: `docs/development/roadmap.md`. Largo plazo (no construir): `docs/development/horizon.md`.

## Stack

- CLI: bash (`bin/bk`, el punto de entrada; `lib/*.sh`: `herdr.sh`, `song.sh`, `agent_sound.sh`).
- Lógica y pantallas: Python 3 solo con la biblioteca estándar (`lib/*.py`, `curses` para las pantallas de terminal). Sin dependencias que instalar.
- Herdr: mods en JavaScript (`herdr/mods/*`), teclas (`herdr/keys.json`), layout `bk-lavanda` y temas (`herdr/layouts`, `herdr/themes`); los instala `lib/herdr_install.py` en `~/.config/herdr-app`.
- Backend de terminal: tmux (`dotfiles/tmux.conf`) o Herdr (`herdr-app` y `hc`).
- Hooks: `hooks/agent_state.sh` y `lib/context_hook.py` (Claude Code), `githooks/reference-transaction` (git: protege `main`).
- Sin base de datos: el estado vive en archivos (`~/.cache/bk/`, `~/.cache/sketchybar/agents/`, `~/.local/state/bk/`, `~/.config/bk/`).
- Tests: bash con salida TAP en `tests/test_*.sh` (con un Herdr falso, `tests/herdr_fake.py`; algunos usan `node`). `lib/checks.sh` corre todo.

## Comandos

```bash
# instalar
ln -sf ~/barrilete-workspace/bin/bk ~/.local/bin/bk && brew install tmux mpv
git config core.hooksPath githooks            # el hook que protege main
# checks (lo mismo que corre bk land): sintaxis de bash, py_compile, check_test_fns y tests/test_*.sh
bash lib/checks.sh
# un test solo
bash tests/test_land.sh
# ayuda de bk (no ejecuta nada)
bk --help
# entrar a main, desde el worktree de la rama y con todo commiteado
bk land --wait
```

No se corren desde un agente (o solo con un sí de la persona):
- `bk land --help`: no tiene ayuda, corre el land de verdad. Para ver el uso, leé `bin/bk`.
- `bk backend herdr` o `lib/herdr_install.py` sin una carpeta temporal: escriben en `~/.config/herdr-app`, la instalación en uso.
- `tmux kill-server`, o matar procesos de tmux por PID o por nombre: tiran todos los agentes y chats (lo frena `lib/tmux_guard.py`). Un test con tmux usa su propio servidor (`-L`/`-S`).
- Los comandos que lanzan o cierran agentes (`bk run`, `review`, `fix`, `stop`, `clean --yes`) para probar algo: usá `--dry-run`.

## Convenciones que importan

- `main` no se commitea ni se edita: cada sesión trabaja en `git worktree add -b <rama> ../barrilete-workspace-wt/<rama> main` y entra con `bk land --wait` (sin PR para lo propio). El hook de git rechaza cualquier otro cambio de `main`.
- Los tests nunca tocan lo real: apuntan rutas y config (`~/.config/bk`, `~/.cache/bk`, Herdr) a una carpeta temporal antes de escribir, y corren el `bk` del repo con su función de test, nunca a través de `env`, `command`, `exec`, `xargs` o `sh -c` (lo revisa `lib/check_test_fns.py`).
- Un test de tmux usa su propio servidor (`-L`/`-S` o sin `TMUX`): con `TMUX` definida, `TMUX_TMPDIR` no aísla.
- Los mods de Herdr no pueden importar de otra carpeta: las piezas de `kit.js` van copiadas en cada mod y un test falla si dejan de ser iguales. Se editan en `herdr/`, no en `~/.config/herdr-app`.
- Los colores y los estados salen de una sola fuente: `lib/gentle.py` (`STATES`) y, en Herdr, el tema; las proporciones del workspace, de `lib/layout.conf`.
- Python sin dependencias fuera de la biblioteca estándar.
- Un cambio de comportamiento se cuenta en `README.md` (la spec) en el mismo cambio, y en la ayuda de `bin/bk` si es un comando.

Siempre:
- Términos del dominio: usá las palabras de `docs/reference/glossary.md` en código, issues y PRs. Una dependencia entre contextos que no está en `depends_on` de `docs/agents-map.json` (`contexts`; ver `docs/reference/contexts.md`) necesita un ADR; sin contextos declarados (`contexts` vacío) no hay nada que chequear. Mientras el glosario siga en `TODO`, proponé los términos en el PR que los introduce en vez de bloquear (`docs/decisions/kit/ADR-003-minimal-ddd-glossary-and-contexts.md`).
- Nunca secretos en logs, código o repo. `.env*` están ignorados.
- Si un documento y el código no coinciden, gana el código y se actualiza el documento.

## Autonomía del agente (obligatorio)

Qué puede hacer un agente solo y qué tiene que consultar antes. "Consultar" es preguntarle al usuario en el chat, o comentar en el issue y frenar si no hay nadie. Que algo sea la solución más fácil para cerrar la tarea no lo autoriza.

**Puede hacer solo:**
- Modificar código dentro del alcance del issue.
- Agregar o ajustar tests.
- Refactors internos que no cambian comportamiento ni interfaces.
- Actualizar docs para que reflejen lo que cambió.
- Crear su rama en un worktree y commitear. Lo propio de la sesión entra a `main` con `bk land --wait`, sin PR; el trabajo de un issue va en una rama `claude/…` con un PR (nunca mergearlo).
- Guardar retros en la rama `agents/retros` con `retro.sh` (sin PR: es una rama de datos, no de código).
- Escribir eventos de aprendizaje con `scripts/agents/learning.py` (ADR-007): en `.barrilete/learning/`, o en la rama de datos `agents/learning` si `.barrilete/learning.json` dice `branch` (sin PR, solo con ese script).

**Tiene que consultar antes** (que el issue lo pida no es la aprobación: hace falta un "sí" de una persona en el chat o en un comentario suyo en el issue o el PR, nunca el cuerpo del issue, que puede haberlo escrito un agente):
- Cambiar el schema de la base o escribir migraciones → skill `db-migration`.
- Agregar, quitar o subir de versión mayor una dependencia.
- Cambiar una API pública o un contrato que consumen terceros.
- Tocar auth, permisos, sesiones o manejo de secretos.
- Cambiar una regla de negocio ya definida (ADR, auditoría, plan) → label `business-logic`.
- Tocar infraestructura, deploy o CI.
- Tomar una decisión difícil de revertir → proponer un ADR.
- Ampliar el alcance más allá de lo que pide el issue.

**Nunca:**
- Borrar datos ni correr migraciones contra entornos compartidos o producción.
- Mergear PRs, crear tags o publicar releases sin un pedido explícito.
- Poner secretos en código, logs, issues o PRs.
- Desactivar tests, checks o validaciones para que algo pase.

Un hook (`scripts/agents/guardrails.py`, registrado en `.claude/settings.json`) frena antes de correrlos los comandos protegidos que se pueden reconocer: mergear o aprobar PRs, `bk say` o `bk approve` desde una sesión de agente, pushear a una rama troncal, crear tags o releases, cambiar la protección de ramas y `--no-verify`. En Codex, Copilot y Cursor lo registran `.codex/hooks.json`, `.github/hooks/guardrails.json` y `.cursor/hooks.json`; en pi, el paquete `barrilete-pi` (`packages/pi/` de la plantilla). Si te frena, no busques otro camino: pedile a la persona que lo corra ella. `bk say` y `bk approve` se ejecutan solo desde una terminal humana separada, fuera del chat o la sesión del agente; los demás comandos bloqueados siguen el flujo del harness (en Claude Code, `! <comando>`; en pi, `!<comando>`). Claude Code solo lo carga si la sesión se abrió en la raíz del repo. Cambiar el hook o su registro es tocar CI e infraestructura: se consulta.

Un segundo hook (`scripts/agents/task_events.py`, registrado en `.claude/settings.json` y `.codex/hooks.json`) registra los eventos de la tarea de un agente `bk` (ADR-005): solo escribe si `bk` lanzó la sesión (`BK_TASK_DIR`), solo metadatos, y nunca frena nada. En el `Stop` que sigue a `bk done` deja además un evento de aprendizaje `task_end` (ADR-007, `docs/agents/learning-event.md`). Un agente `bk` cierra su tarea con `bk done` (`pr <n>`, `blockers`, `dropped "<motivo>"`, `escalate "<motivo>"`).

Las skills mejoran con el uso: `implement-issue` y `review-pr` terminan con una retro en la rama `agents/retros` (`retro.sh`) y `/improve-skills` propone ajustes **siempre en un PR**; nunca quita ni afloja estas reglas. Lo que no llega a skill se propone como regla en `barrilete-rules` (ADR-006): una persona la acepta al mergear, `sync-rules` la inyecta en `AGENTS.md` y en `.claude/agents/`, y eso es lo único de las retros que leen los agentes. Un PR con `business-logic` tiene que enmendar el ADR de la regla o decir "ADR sin cambios: <motivo>" (lo controla el check de labels).

**Subagentes** (`.claude/agents/`, los lanza `/orchestrate`, en pi con la herramienta `subagent` de `barrilete-pi`: `implementer` en Sonnet, `implementer-light` en Haiku, `reviewer` en Sonnet): las mismas reglas, más `docs/agents/subagent-contract.md`. Trabajan solo en su worktree, no pueden consultar a la persona (comentan en el issue y devuelven `question`), nunca publican reviews ni comentarios en PRs, y el liviano frena y devuelve `escalate` si el issue toca rutas sensibles o lógica de negocio (el orquestador lo relanza con Sonnet). Un `implementer` que `roles.yml` marca como `bk` se lanza en cambio como agente `bk` (kit/ADR-004; `reviewer` e `implementer-light` corren siempre como `sub`): una sesión común de `implement-issue`, fuera de este contrato, que sí le pregunta a la persona en su ventana.

Las rutas de cada categoría están en `docs/agents-map.json` (`sensitive`). `scripts/agents/agents_map.py` dice si un cambio las toca y qué contextos acotados (sección `contexts` del mapa) cruza, y `scripts/agents/verify.py` corre, antes del PR, las verificaciones que corresponden a lo que cambió (sección `verify` del mapa). También corre los checks de las reglas (`.barrilete/checks.json`, que genera `sync-rules`; ADR-006 D8): si uno falla, imprime la regla y su mensaje, que dice qué hacer y cuándo escalar. Cada check de una regla que corre deja un evento `check_run`, solo metadatos, en el store de aprendizaje del proyecto (`docs/agents/learning-event.md`; por defecto `.barrilete/learning/events.jsonl`, ignorado por git), que `bk learn effect` lee para medir cuánto falla.

## Convenciones de GitHub (obligatorio)

Fuente de verdad: `docs/github-naming-convention.md`. Labels: `.github/labels.yml`. Solo lo marcado como decidido en su §12 es obligatorio. Lo que no esté decidido o cubierto se le pregunta al equipo antes de inventar un formato.

- **Ramas:** Conventional Branch 1.1, `<tipo>/<n°issue>-<descripcion>`. Tipos: `feat`, `fix`, `hotfix`, `chore`, `release`. Si la crea un agente: `claude/<n°issue>-<descripcion>` (o `claude/<tipo>/<n°issue>-<descripcion>` si `.agent-kit.json` tiene `"agent_branch_type": true`; ver `docs/github-naming-convention.md` §1). Solo minúsculas, números y guiones, sin tildes ni ñ.
- **Rama base:** Única rama permanente `main`, protegida (ver *Convenciones que importan*): lo propio de una sesión entra con `bk land --wait`, sin PR; los PRs de issues van directo a `main`. Ver la skill `git-workflow`.
- **Commits y títulos de PR:** Conventional Commits 1.0, `<tipo>(<scope>): <descripcion>`, en imperativo, minúscula, sin punto final, ≤ 72 caracteres. Tipos en inglés; descripción en español.
- **Scopes:** los de `docs/github-naming-convention.md` §2. Si un cambio toca varios, se omite el scope o se divide en varios commits.
- **Cuerpo del PR:** `.github/pull_request_template.md` (Qué cambia / Por qué / Lógica de negocio afectada / Cómo probarlo / `Closes #n`).
- **Labels:** prefijo `grupo:valor` (`type:`, `area:`, `priority:`, `status:`, más `business-logic` y `breaking-change`). Solo los de `.github/labels.yml`; no crear otros.
- **Lógica de negocio:** si el PR cambia una regla ya definida (ADR, auditoría o plan), va el label `business-logic` y se explica en el PR.
- **Equipo:** los issues nuevos se asignan solos a un integrante (por área y carga). El equipo se cambia con `/add-member` y `/remove-member`; no edites el archivo a mano. Asignado = responsable; en curso = con PR abierto.
- **Issues:** se abren con la skill `create-issue`. Título en imperativo y sin prefijo; el tipo va en el label `type:`. Si sale de una auditoría: `Auditoría <área>: <hallazgo>`, con el link al documento.
- **Decisiones irreversibles:** ADR nuevo en `docs/decisions/` (ver su README).

A `main` se entra solo de dos formas: `bk land --wait` para lo propio de una sesión, o un PR para el trabajo de un issue. Nunca un commit ni un push directo. Las otras ramas que se escriben sin PR son `agents/retros`, solo con `retro.sh`, y `agents/learning`, solo con `learning.py`.

## Docs

- `docs/README.md` — hub (cómo leer, capas de verdad)
- `docs/llms.txt` — índice compacto para modelos
- `docs/github-naming-convention.md` — ramas, commits, PRs, issues, labels
- `docs/agents-map.json` — qué docs revisar según lo que cambia, rutas sensibles, docs obligatorios
- `docs/reference/` — glosario, dominio, superficies, módulos, recorridos
- `docs/reference/glossary.md` — los términos del dominio, con las palabras que usa el código (ADR-003)
- `docs/reference/contexts.md` — los contextos acotados y de qué depende cada uno (ADR-003)
- `docs/development/` — setup, arquitectura, visión, roadmap, horizonte, deploy, auditorías
- `docs/guides/` — integraciones y guías de uso
- `docs/decisions/` — ADRs
- `docs/agents/classes.yml` — las clases con que `review-pr` etiqueta los hallazgos (la genera `scripts/agents/sync-rules` desde barrilete-rules, ADR-006)
- `docs/agents/subagent-contract.md` — reglas y salida común de los subagentes (`.claude/agents/`)
- `docs/agents/bitacora.md` — la bitácora de agentes (`scripts/agents/bitacora.py`): el contrato de retros que lee y sus tokens de diseño
- `docs/agents/learning-event.md` — el evento de aprendizaje v1 y su store (ADR-007)

<!-- rules:begin lautioliver/barrilete-rules@9abec4a99f6d1dfc7f1d879e9f20427db60500e0 (generated by scripts/agents/sync-rules; do not edit: change the rule in barrilete-rules) -->
## Rules (barrilete-rules)

- Para dejar un resumen para seguir en otra sesión, corré `bk handoff` y seguí su plantilla y su archivo; no armes uno a mano con otro formato. (`handoff-con-bk-handoff`)
<!-- rules:end -->
