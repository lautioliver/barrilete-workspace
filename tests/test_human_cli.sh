#!/usr/bin/env bash
# lib/human_cli.py: bk approve/cancel/say se niegan si algún ancestro del proceso es un agente (#35).
# El árbol de procesos es falso (se reemplaza process_table y getppid); además se mira, solo leyendo, el `ps` real.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck disable=SC1091  # tap.sh se carga en tiempo de ejecución
. "$ROOT/scripts/agents/tap.sh"
tap_begin "tests/test_human_cli.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
# shellcheck disable=SC2016  # se expande al salir, no ahora
tap_at_exit 'rm -rf "$TMP"'
export PYTHONPYCACHEPREFIX="$TMP/pycache"
out=""                                  # lo asigna tap_run

# drv.py "<comm>" "<args>": un árbol 1 <- 100 (el ancestro dado) <- 200 (bk, el que llama); imprime el motivo.
cat >"$TMP/drv.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["HC_LIB"])
import human_cli as hc
os.environ.pop("BK_TASK_DIR", None)
comm, args = sys.argv[1], sys.argv[2]
hc.process_table = lambda: {100: (1, comm, args), 200: (100, "/bin/zsh", "-zsh")}
hc.os.getppid = lambda: 200
try:
    print(hc.reason() or "libre")
except (ValueError, TypeError) as exc:     # un árbol que no entiende no es un caso: se informa
    print(f"error: {exc}")
PY
export HC_LIB="$ROOT/lib"
why() { tap_run out 0 python3 "$TMP/drv.py" "$1" "$2"; }

AG="the command was invoked from an agent session"
while IFS='|' read -r comm args; do
  why "$comm" "$args"
  [ "$out" = "$AG" ]; tap_check $? "un agente como ancestro se niega" "comm=$comm args=$args → $out"
done <<'EOF'
/Users/u/.local/share/claude/versions/2.1.332|claude --resume
node|node /opt/homebrew/bin/claude -p hola
node|node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js
node|node /opt/homebrew/bin/codex
/opt/homebrew/bin/codex|/opt/homebrew/bin/codex exec
/Users/u/.local/share/cursor-agent/versions/2026.11.22/node|/Users/u/.local/bin/cursor-agent --use-system-ca /Users/u/.local/share/cursor-agent/versions/2026.11.22/index.js
node|cursor-agent --use-system-ca /x/index.js
/usr/local/bin/node|node --use-system-ca /Users/u/.local/bin/cursor-agent
/Users/u/.local/bin/agy|agy
EOF

while IFS='|' read -r comm args; do
  why "$comm" "$args"
  [ "$out" = libre ]; tap_check $? "un ancestro humano no se niega" "comm=$comm args=$args → $out"
done <<'EOF'
tmux|tmux new-session -s claude
/bin/zsh|-zsh
/usr/bin/less|less /Users/u/notas/claude
node|node /Users/u/app/server.js --name codex
/usr/bin/vim|vim claude.md
EOF

# process_table trae comm y args de cada proceso (ps real, solo lectura): el propio python aparece con su script.
tap_run out 0 python3 -c 'import os, sys; sys.path.insert(0, os.environ["HC_LIB"]); import human_cli as hc
row = hc.process_table()[os.getpid()]
print("ok" if len(row) == 3 and row[0] == os.getppid() and "import human_cli" in row[2] else repr(row))'
[ "$out" = ok ]; tap_check $? "process_table lee comm y args de ps" "got: $out"

# #57: test_human_confirm.py (confirmación fail-closed, con backends falsos: nunca abre el diálogo real)
tap_run out 0 python3 "$ROOT/scripts/agents/test_human_confirm.py"
[ "$TAP_RC" = 0 ]; tap_check $? "test_human_confirm.py: sus pruebas pasan (sin diálogo real)" "rc=$TAP_RC"

tap_done
