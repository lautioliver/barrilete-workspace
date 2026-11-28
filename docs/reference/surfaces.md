# Superficies — barrilete-workspace

> Cada pantalla o URL pública: quién entra, con qué permiso, qué puede hacer.

No hay URLs ni usuarios: todo corre en la máquina de la persona, con sus permisos. Las superficies son el comando, las pantallas de terminal y los paneles de Herdr. La lista completa de comandos está en la ayuda de `bin/bk` (`bk --help`) y la de teclas de Herdr, en el [README](../../README.md) (*Todo con teclas*); acá no se repiten.

| Superficie | Dónde | Qué se hace |
|---|---|---|
| `bk <comando>` | cualquier terminal | lanzar y manejar agentes, chats, cuentas, perfiles, tareas, `bk land` |
| Workspace de tmux | sesión `bk-<proyecto>` | chat, riel (`lib/rail.py`), tira (`lib/sidebar.py`), agentes en vivo (`bk watch --all`) |
| Pantallas de terminal (`curses`) | `bk s`, `bk monitor`, `bk palette`, `bk new`, `bk changes`, `bk stats`, `bk song ui`, `bk customize` | elegir, mirar, lanzar |
| Herdr, layout `bk-lavanda` | `~/.config/herdr-app` | barra de agentes, franja de arriba, cabecera de cada pane, panel derecho (Estado y TODO), barra de estado |
| Paneles de Herdr | teclas `alt+…` → mods `bk-<vista>` | issues, PRs, te esperan, épica, agentes, nuevo, sesiones, resumen, cambios, ramas, uso, hoja de teclas, radio, aspecto |
| Comandos internos | `bk _hub`, `bk _do`, `bk _side`, `bk _epica`, `bk _todo`… | solo los llaman los mods y los hooks; el contrato de cada tema de `_hub` está en `lib/herdr_hub.py` |

Lo que un agente no hace en nombre de la persona: `bk say` escribe como si fuera su teclado (responder un menú o aprobar un plan) y `bk approve` lanza una tarea propuesta. La persona los corre desde una terminal humana separada, fuera del chat o la sesión del agente; guardrails y CLI bloquean llamadas desde sesiones de agente.
