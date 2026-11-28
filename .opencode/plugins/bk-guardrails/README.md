# bk-guardrails (OpenCode plugin)

Plugin local de OpenCode para integrar Barrilete con `scripts/agents/guardrails.py`, `lib/land.py hook` y `scripts/agents/task_events.py` sin duplicar lógica.

## Qué hace

- `permission.evaluate` + `shell.create.before` + `tool.execute.before` (shell): ejecuta `guardrails.py` y bloquea antes de ejecutar cuando el script sale con código 2 o no puede correr (falla cerrado: falta el script, `python3` no arranca, estado distinto de 0 y 2).
- `tool.execute.before/after` (edit/write): ejecuta `lib/land.py hook` con `PreToolUse`/`PostToolUse` y el path real del archivo; un deny de `PreToolUse` frena la edición.
- `tool.execute.after` (shell, completado): registra en `task_events.py` solo comandos relevantes (`git commit`, `gh pr create`) con stdout como `tool_response.stdout`.
- `session.prompt`: emite `SessionStart` (una vez por sesión vista por el plugin) y `UserPromptSubmit` a `task_events.py`.
- `event.subscribe`: best-effort para mapear eventos de fin/idle a `Stop` cuando OpenCode los expone al plugin.

## Configuración

En `opencode.jsonc`:

```jsonc
{
  "plugins": [
    {
      "package": "./.opencode/plugins/bk-guardrails",
      "options": {
        "scriptsDir": "./scripts/agents"
      }
    }
  ]
}
```

`options.scriptsDir` es la ruta explícita al directorio de scripts (relativa al directorio de OpenCode). También acepta `scripts_dir`/`root`; opcional `landPy`/`land_py`.

## Límites

- El plugin es un adaptador: la política semántica sigue en scripts BK existentes.
- Los eventos de tarea dependen de `BK_TASK_DIR`; sin esa variable, `task_events.py` no escribe nada.
- El mapeo de `Stop` por suscripción de eventos es best-effort según lo que exponga la versión/runtime de OpenCode.
- No reemplaza `githooks/reference-transaction` (protección de `main` a nivel Git).
