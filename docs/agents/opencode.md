# OpenCode + guardrails de BK

Integración de OpenCode v2.3.2 con los guardrails del proyecto, sin duplicar lógica.

## Qué se integra

- **Guardrails**: `.opencode/plugins/bk-guardrails/` adapta eventos de OpenCode a `scripts/agents/guardrails.py`.
- **Edición/sensible**: el plugin llama `lib/land.py hook` (el subcomando `hook`, con el mismo JSON que en Claude Code) en `tool.execute.before/after` para `edit`, `write`, `multiedit`, `patch` y `apply_patch`, con el path real. Un deny de `PreToolUse` frena la edición (editar el checkout de `main`).
- **Falla cerrado**: si el plugin no logra registrar ningún hook que frene el shell, `setup` falla con un error en vez de cargarse sin proteger nada.
- **Falla cerrado (comandos)**: si `guardrails.py` no existe, no arranca, se cuelga o sale con un estado que no es 0 ni 2, el plugin frena el comando de shell (y deniega el permiso) en vez de dejarlo pasar. Lo mismo para `lib/land.py` en `PreToolUse` si existe y falla. Si falta `lib/land.py` la guarda de edición no corre (la protección de `main` sigue en el hook de git).
- **Eventos de tarea**: el plugin llama `scripts/agents/task_events.py` solo para comandos relevantes (`git commit`, `gh pr create`) y, best-effort, `SessionStart/UserPromptSubmit/Stop` cuando hay `BK_TASK_DIR`.
- **Protección de main**: no cambia; `githooks/reference-transaction` sigue siendo la barrera Git.

## Configuración

- `opencode.jsonc` en la raíz del repo (no en `.opencode/`) define permisos nativos OpenCode:
  - `deny`: `git push *`, `git tag *`, `gh release create *`, `gh pr merge *`, `bk say *`, `bk approve *` (se corren solo desde una terminal humana, ver `AGENTS.md`), `*--no-verify*`, `.env*`.
  - `ask`: `.github/**`, `package.json`, `gh workflow *`, los archivos del propio guardrail (`opencode.jsonc`, `.opencode/**`, `scripts/agents/guardrails.py`, `githooks/**`) y los intérpretes (`bash`, `sh`, `python3`, `node`, por defecto: no están en allow porque evadirían los deny).
  - `allow`: lecturas/comandos seguros habituales (`git status/diff/log/show/branch/rev-parse`, `bk *`, etc.).
- El plugin se registra como paquete local: `./.opencode/plugins/bk-guardrails` con `options.scriptsDir`.

## Comportamiento confirmado (v2.3.2)

- `opencode debug config` normaliza `permission` a `permissions` con `action/resource/effect`; la última regla gana.
- Hooks disponibles en plugin v2: `permission.hook('evaluate')`, `shell.hook('create.before')`, `tool.hook('execute.before/after')`, `session.hook(...)`, `event.subscribe`.
- `permission.evaluate` puede cambiar `effect/message` en allow/ask; denys configurados pueden no pasar por hook.
- `shell.create.before` recibe `command/cwd/timeout/shell/env`; tirar error bloquea antes de ejecutar.
- En `opencode run` no interactivo sin `--auto`, los `ask` se rechazan como `permission.rejected`. Con `--auto`, los asks no denegados se auto-aprueban.
- En TUI, los `ask` deben requerir confirmación humana; validar manualmente en la UI.

## Límites

- El plugin es adaptador; la política semántica vive en scripts BK existentes.
- Sin `BK_TASK_DIR`, `task_events.py` no escribe eventos de tarea.
- El mapeo `Stop` por `event.subscribe` es best-effort según eventos expuestos por el runtime.
- La configuración debe estar en el directorio/contexto donde se ejecuta OpenCode; un worktree hijo no hereda automáticamente el `opencode.jsonc` del padre en probes locales.
- No reemplaza hooks Git ni la aprobación humana para acciones sensibles.
