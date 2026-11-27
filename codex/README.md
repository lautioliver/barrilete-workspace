# Perfiles de Codex de bk

Un perfil por tipo de rol, para gastar menos tokens. `bk codex install` los copia a `$CODEX_HOME` (`~/.codex`) y
`bk` los usa al lanzar un agente con provider `codex` (`codex -p <perfil> -m <modelo>`): el modelo sigue saliendo
del perfil de bk o de `roles.yml`; el perfil de Codex pone el resto. A mano: `codex -p bk-liviano`.

| perfil | roles | qué pone |
|---|---|---|
| `bk-orquestador` | planner, orchestrator | Sol medio (Plan mode alto), hasta 2 subagentes en Luna |
| `bk-implementador` | implementer | Sol bajo, sin subagentes |
| `bk-liviano` | implementer-light, reviewer | Luna medio, sin subagentes |

Los tres: sin resumen de razonamiento, respuestas cortas (`model_verbosity = "low"`), salida de herramientas
recortada y sin plugins, apps, navegador, computer use ni generación de imágenes. Esas herramientas se mandan
en cada llamada aunque no se usen.

Medido el 2026-11-26 con Codex 0.170 (contexto total de entrada de un turno "Respondé solo: OK", desde este repo):
config de siempre 21,9k · `bk-orquestador` 18,6k · `bk-implementador` 17,1k · `bk-liviano` 14,9k. Sacar las
herramientas pesa más que bajar el razonamiento. Cada llamada vuelve a mandar ese contexto, así que el ahorro se
repite en cada turno.

Codex valida cada archivo por separado: no se puede apagar desde acá un MCP definido en `config.toml`
(`[mcp_servers.x] enabled = false` da `invalid transport`). Con `codex --strict-config -p <perfil>` una clave
desconocida es un error.
