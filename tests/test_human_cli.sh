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

# bk _do suelta el comando (start_new_session) y su árbol termina en launchd: el chequeo va en _do, antes de
# soltarlo, con el árbol de quien lo pidió (#45). do.py <quién> <args de _do…>: imprime negado/lanzado/dry.
cat >"$TMP/do.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["HC_LIB"])
os.environ["BK_CACHE_DIR"] = os.environ["HC_CACHE"]
os.environ.pop("BK_TASK_DIR", None)
os.environ.pop("BK_DRY", None)
import herdr_hub as hh
import human_cli as hc
quien = sys.argv[1]
ancestro = ("node", "node /opt/homebrew/bin/claude -p hola") if quien == "agente" else ("herdr-app", "/Applications/Herdr.app/herdr-app")
hc.process_table = lambda: {100: (1,) + ancestro, 200: (100, "/bin/zsh", "-zsh")}
hc.os.getppid = lambda: 200
lanzados = []
class Proc:
    pid = 4242
def popen(cmd, **kw):
    lanzados.append(cmd)
    return Proc()
hh.subprocess.Popen = popen
try:
    r = hh.do(sys.argv[2:])
except hh.Fail as exc:
    print(f"negado: {exc}")
else:
    print("dry" if r.get("dry") else ("lanzado" if lanzados else "nada"))
PY
export HC_CACHE="$TMP/cache"
do_() { tap_run out 0 python3 "$TMP/do.py" "$@"; }

while IFS= read -r args; do
  eval "set -- $args"
  do_ agente --cwd "$TMP" -- "$@"
  [ "${out%%:*}" = negado ]; tap_check $? "bk _do niega a un agente un comando de una persona" "_do -- $args → $out"
done <<'EOF'
say 3 si
approve t1
supervisor approve x
supervisor cancel x
--account w approve t1
_do -- approve t1
_do --cwd /tmp -- say 3 si
_do_run /tmp/l t -- supervisor approve x
EOF

do_ agente --cwd "$TMP" -- say 3 si
case "$out" in *"invoked from an agent session"*) r=0 ;; *) r=1 ;; esac
[ "$r" = 0 ]; tap_check $? "bk _do dice por qué lo niega" "got: $out"

while IFS= read -r args; do
  eval "set -- $args"
  do_ herdr --cwd "$TMP" -- "$@"
  [ "$out" = lanzado ]; tap_check $? "bk _do desde Herdr (una persona) lanza el comando de una persona" "_do -- $args → $out"
done <<'EOF'
approve t1
say 3 si
supervisor approve x
EOF

do_ agente --cwd "$TMP" -- _hub _do -- approve t1
[ "${out%%:*}" = negado ]; tap_check $? "bk _do niega a un agente un comando de una persona dentro de _hub _do" "got: $out"
do_ agente --cwd "$TMP" -- _hub issues
[ "$out" = lanzado ]; tap_check $? "bk _do de un agente lanza bk _hub" "got: $out"

do_ agente --cwd "$TMP" -- run 42
[ "$out" = lanzado ]; tap_check $? "bk _do de un agente lanza lo que no es de una persona" "got: $out"
do_ agente --cwd "$TMP" -- approve t1 --dry-run
[ "$out" = dry ]; tap_check $? "bk _do --dry-run de un agente no corre nada y no se niega" "got: $out"

# Pasado el tope de anidado, human_only lo trata como de una persona y dice por qué sin repetir "bk": el aviso es
# "bk <lo que devuelve>: …" (antes salía "bk bk: …").
tap_run out 0 python3 -c 'import os, sys; sys.path.insert(0, os.environ["HC_LIB"]); import human_cli as hc
print(hc.human_only(["_do", "--"] * 70 + ["run", "1"]))'
[ "$out" = "_do anidado" ]; tap_check $? "human_only da un nombre propio al pasar el tope de anidado" "got: $out"

# #57: test_human_confirm.py (confirmación fail-closed, con backends falsos: nunca abre el diálogo real)
tap_run out 0 python3 "$ROOT/scripts/agents/test_human_confirm.py"
[ "$TAP_RC" = 0 ]; tap_check $? "test_human_confirm.py: sus pruebas pasan (sin diálogo real)" "rc=$TAP_RC"

tap_done
