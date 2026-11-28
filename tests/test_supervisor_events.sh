#!/usr/bin/env bash
# bk supervisor (lib/supervisor.py): el bus nunca registra un hito que el estado no guardó. Cerrar un plan y
# promover la cola escriben su evento después de write_state; si esa escritura falla, el evento no queda (#35).
# El estado va a un XDG_STATE_HOME temporal, el adaptador de harness es falso y los procesos son `sleep` propios.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck disable=SC1091  # tap.sh se carga en tiempo de ejecución
. "$ROOT/scripts/agents/tap.sh"
tap_begin "tests/test_supervisor_events.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
PIDS=""
out=""                                  # lo asigna tap_run
# shellcheck disable=SC2016  # se expande al salir, no ahora
tap_at_exit 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"'
export PYTHONPYCACHEPREFIX="$TMP/pycache"
mkdir -p "$TMP/sessions"

# drv.py [--fail-write N] [--offset S] <cmd> ...: la N-ésima llamada a write_state de este proceso falla.
cat >"$TMP/drv.py" <<'PY'
import builtins, os, sys, uuid
from datetime import timedelta
sys.path.insert(0, os.environ["SV_LIB"])
import supervisor as sv

args = sys.argv[1:]
fail_write = offset = 0
while args and args[0].startswith("--"):
    if args[0] == "--fail-write":
        fail_write = int(args[1])
    elif args[0] == "--offset":
        offset = int(args[1])
    args = args[2:]

class Adapter:
    def session_state(self, session_id):
        try:
            return open(os.path.join(os.environ["SV_SESSIONS"], session_id)).read().strip()
        except FileNotFoundError:
            return "absent"

sv.HARNESS_ADAPTERS["claude-code"] = Adapter()
sv.require_terminal = lambda action: None
sv.require_human = lambda action, run_id: None
real_now = sv.now
sv.now = lambda: real_now() + timedelta(seconds=offset)
real_write, calls = sv.write_state, [0]
def write_state(state):
    calls[0] += 1
    if calls[0] == fail_write:
        raise ValueError("escritura fallida")
    real_write(state)
sv.write_state = write_state

def rid(name): return str(uuid.uuid5(uuid.NAMESPACE_URL, "run/" + name))
def lid(name, i): return str(uuid.uuid5(uuid.NAMESPACE_URL, f"lease/{name}/{i}"))

cmd, rest = args[0], args[1:]
try:
    if cmd == "propose":           # propose <run> <issue>... (un implementador por issue)
        name = rest[0]
        plan = {"schema": sv.PLAN_SCHEMA, "run_id": rid(name), "assignments": [
            {"task_id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"task/{name}/{i}")), "lease_id": lid(name, i),
             "resource_kind": "issue", "resource_number": int(n), "task_type": "feature", "area": "cli",
             "priority": "normal", "critical": False, "risk_flags": [], "provider": "claude",
             "model_id": "claude-sonnet-5-5", "harness": "claude-code", "role": "implementer",
             "worktree": "/tmp/wt-" + name} for i, n in enumerate(rest[1:])]}
        print(sv.propose(plan)["status"])
    elif cmd in ("approve", "cancel"):
        word = "APROBAR" if cmd == "approve" else "CANCELAR"
        builtins.input = lambda prompt: f"{word} {rid(rest[0])}"
        sys.stdout = open(os.devnull, "w")
        result = getattr(sv, cmd)(rid(rest[0]))
        sys.stdout = sys.__stdout__
        print(result["status"])
    elif cmd == "start":           # start <run> <i> <pid> <session>
        pid = int(rest[2])
        print(sv.start_lease(rid(rest[0]), lid(rest[0], int(rest[1])), pid, sv.process_start_time(pid),
                             rest[3])["status"])
    elif cmd == "finish":
        print(sv.finish_lease(rid(rest[0]), lid(rest[0], int(rest[1])))["status"])
    elif cmd == "reconcile":
        r = sv.reconcile()
        print(f"stale={len(r['stale'])} released={len(r['released'])}")
    elif cmd == "plan":
        with sv.locked():
            print(sv.plan_record(sv.read_state(), rid(rest[0]))["status"])
    elif cmd == "events":          # events <kind>: cuántos hay en el bus
        print([e["kind"] for e in sv.event_rows()].count(rest[0]))
except ValueError as exc:
    sys.stdout = sys.__stdout__
    print("error: " + str(exc))
PY

# Cada escenario usa su propio store.
use_store() { export XDG_STATE_HOME="$TMP/$1"; }
export SV_LIB="$ROOT/lib" SV_SESSIONS="$TMP/sessions"
sv() { tap_run out 0 python3 "$TMP/drv.py" "$@"; }
# proc.py spawn: un `sleep` huérfano (lo recoge el sistema, sin wait) e imprime su PID.
# proc.py stop <pid>: lo mata y espera a que desaparezca.
cat >"$TMP/proc.py" <<'EOF'
import os, signal, subprocess, sys, time
if sys.argv[1] == "spawn":
    print(subprocess.Popen(["sleep", "600"], start_new_session=True, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid)
    sys.exit(0)
pid = int(sys.argv[2])
os.kill(pid, signal.SIGTERM)
for _ in range(500):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.01)
print("stopped")
EOF
spawn() { tap_run out 0 python3 "$TMP/proc.py" spawn; LAST=$out; PIDS="$PIDS $LAST"; }
stop() { tap_run out 0 python3 "$TMP/proc.py" stop "$1"; }

# --- finish: el último lease cierra el plan y promueve la cola -------------------------------------------
use_store finish
sv propose a 1;    sv approve a
sv propose b 2 3;  sv approve b
sv propose q 4;    sv approve q
[ "$out" = queued ]; tap_check $? "setup finish: q queda en cola" "got: $out"
spawn; P=$LAST; printf 'alive\n' >"$TMP/sessions/fa"
sv start a 0 "$P" fa
[ "$out" = running ]; tap_check $? "setup finish: el lease de a arranca" "got: $out"
stop "$P"; printf 'absent\n' >"$TMP/sessions/fa"
sv --fail-write 2 finish a 0
[ "$out" = "error: escritura fallida" ]; tap_check $? "setup finish: falla guardar el cierre" "got: $out"
sv plan a
[ "$out" = reserved ]; tap_check $? "setup finish: el estado no guardó el cierre" "got: $out"
sv events plan.closed
[ "$out" = 0 ]; tap_check $? "finish sin cierre guardado no deja plan.closed" "plan.closed en el bus: $out"
sv events plan.reserved
[ "$out" = 2 ]; tap_check $? "finish sin promoción guardada no deja plan.reserved" "plan.reserved en el bus: $out (a y b)"

# --- cancel: cancelar libera slots y promueve la cola ----------------------------------------------------
use_store cancel
sv propose a 1 2 3; sv approve a
sv propose q 4;     sv approve q
[ "$out" = queued ]; tap_check $? "setup cancel: q queda en cola" "got: $out"
sv --fail-write 2 cancel a
[ "$out" = "error: escritura fallida" ]; tap_check $? "setup cancel: falla guardar la promoción" "got: $out"
sv plan q
[ "$out" = queued ]; tap_check $? "setup cancel: el estado no guardó la promoción" "got: $out"
sv events plan.reserved
[ "$out" = 1 ]; tap_check $? "cancel sin promoción guardada no deja plan.reserved" "plan.reserved en el bus: $out (solo a)"

# --- reconcile: liberar el último lease cierra el plan ---------------------------------------------------
use_store reconcile
sv propose a 1; sv approve a
spawn; P=$LAST; printf 'alive\n' >"$TMP/sessions/ra"
sv start a 0 "$P" ra
stop "$P"; printf 'absent\n' >"$TMP/sessions/ra"
sv --offset 400 --fail-write 2 reconcile
[ "$out" = "error: escritura fallida" ]; tap_check $? "setup reconcile: falla guardar el cierre" "got: $out"
sv plan a
[ "$out" = reserved ]; tap_check $? "setup reconcile: el estado no guardó el cierre" "got: $out"
sv events plan.closed
[ "$out" = 0 ]; tap_check $? "reconcile sin cierre guardado no deja plan.closed" "plan.closed en el bus: $out"

# --- sin fallas, los hitos sí quedan -----------------------------------------------------------------------
use_store ok
sv propose a 1;   sv approve a
sv propose b 2 3; sv approve b
sv propose q 4;   sv approve q
spawn; P=$LAST; printf 'alive\n' >"$TMP/sessions/oa"
sv start a 0 "$P" oa
stop "$P"; printf 'absent\n' >"$TMP/sessions/oa"
sv finish a 0
[ "$out" = completed ]; tap_check $? "setup ok: el lease se cierra" "got: $out"
sv events plan.closed
[ "$out" = 1 ]; tap_check $? "con el cierre guardado queda plan.closed" "plan.closed en el bus: $out"
sv events plan.reserved
[ "$out" = 3 ]; tap_check $? "con la promoción guardada queda plan.reserved" "plan.reserved en el bus: $out"

# --- una escritura cortada (sin "\n" final) no bloquea el bus ----------------------------------------------
# Un corte a mitad de una alta deja la última línea a medias: se descarta, y las altas siguientes no se pegan a ella.
use_store torn
EV="$TMP/torn/bk/supervisor/events.jsonl"
sv propose a 1
printf '{"v":1,"event_id":"x' >>"$EV"
sv propose b 2
[ "$out" = pending ]; tap_check $? "propose con la última línea cortada sigue andando" "got: $out"
sv approve b
[ "$out" = reserved ]; tap_check $? "approve con la última línea cortada sigue andando" "got: $out"
sv events plan.proposed
[ "$out" = 2 ]; tap_check $? "la línea cortada se descarta y los eventos nuevos quedan" "plan.proposed en el bus: $out"
printf '{"v":1,"event_id":"x' >>"$EV"
sv cancel b
[ "$out" = cancelled ]; tap_check $? "cancel con la última línea cortada sigue andando" "got: $out"
sv events plan.cancelled
[ "$out" = 1 ]; tap_check $? "cancel anexa su evento en una línea propia" "plan.cancelled en el bus: $out"
# start no compacta el bus antes de anexar: la alta tiene que cortar ella misma la línea a medias.
sv propose d 4; sv approve d
printf '{"v":1,"event_id":"x' >>"$EV"
spawn; P=$LAST; printf 'alive\n' >"$TMP/sessions/td"
sv start d 0 "$P" td
[ "$out" = running ]; tap_check $? "start con la última línea cortada sigue andando" "got: $out"
sv events lease.started
[ "$out" = 1 ]; tap_check $? "start anexa su evento en una línea propia" "lease.started en el bus: $out"
stop "$P"
# Una línea inválida que sí termina en "\n" no es un corte: sigue frenando para no perder datos.
printf 'basura\n' >>"$EV"
sv propose c 3
case "$out" in "error: "*"línea inválida"*) r=0 ;; *) r=1 ;; esac
tap_check $r "una línea inválida completa sigue frenando" "got: $out"

tap_done
