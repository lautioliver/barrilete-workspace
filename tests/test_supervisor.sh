#!/usr/bin/env bash
# bk supervisor: reservas, cola y ciclo de leases con un adaptador de harness falso (ADR-003).
# El estado va a un XDG_STATE_HOME temporal; los procesos de los leases son `sleep` propios del test.
# No lanza agentes ni toca ~/.local/state real.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
check_has() { N=$((N+1)); case "$1" in *"$2"*) echo "ok $N - $3" ;; *) echo "not ok $N - $3 (got '$1', want '*$2*')"; FAILED=$((FAILED+1)) ;; esac; }

export XDG_STATE_HOME="$TMP/state"
export PYTHONPYCACHEPREFIX="$TMP/pycache"
SESSIONS="$TMP/sessions"; mkdir -p "$SESSIONS"
STORE="$XDG_STATE_HOME/bk/supervisor"

# Driver: importa lib/supervisor.py con el estado temporal, registra el adaptador falso si SV_ADAPTER=1,
# corre el reloj SV_OFFSET segundos y contesta las confirmaciones humanas (las prueba otra capa: human_cli).
cat >"$TMP/sv.py" <<'PY'
import builtins, json, os, sys, uuid
from datetime import timedelta
sys.path.insert(0, os.environ["SV_LIB"])
import supervisor as sv

SESS = os.environ["SV_SESSIONS"]

class FakeAdapter:
    def session_state(self, session_id):
        try:
            value = open(os.path.join(SESS, session_id)).read().strip()
        except FileNotFoundError:
            return "absent"
        if value == "raise":
            raise RuntimeError("adaptador roto")
        return value

if os.environ.get("SV_ADAPTER") == "1":
    sv.HARNESS_ADAPTERS["claude-code"] = FakeAdapter()
offset = int(os.environ.get("SV_OFFSET", "0"))
real_now = sv.now
sv.now = lambda: real_now() + timedelta(seconds=offset)
sv.require_terminal = lambda action: None
if not os.environ.get("SV_REAL_HUMAN"):    # el control del árbol de procesos se prueba aparte (SV_REAL_HUMAN=1)
    sv.require_human = lambda action, run_id: None
if os.environ.get("SV_SLOW"):        # agranda la ventana entre leer y escribir el estado
    import time
    real_write = sv.write_state
    sv.write_state = lambda state: (time.sleep(float(os.environ["SV_SLOW"])), real_write(state))[1]
if os.environ.get("SV_GO"):          # barrera: todos los procesos arrancan juntos
    import time
    while not os.path.exists(os.environ["SV_GO"]):
        time.sleep(0.002)

def rid(name): return str(uuid.uuid5(uuid.NAMESPACE_URL, "run/" + name))
def lid(name, i): return str(uuid.uuid5(uuid.NAMESPACE_URL, f"lease/{name}/{i}"))
def tid(name, i): return str(uuid.uuid5(uuid.NAMESPACE_URL, f"task/{name}/{i}"))

cmd, args = sys.argv[1], sys.argv[2:]
try:
    if cmd == "propose":            # propose <run> role:kind:num:priority ...
        name, specs = args[0], args[1:]
        assignments = []
        for i, spec in enumerate(specs):
            role, kind, num, prio = spec.split(":")
            assignments.append({"task_id": tid(name, i), "lease_id": lid(name, i), "resource_kind": kind,
                                "resource_number": int(num), "task_type": "feature", "area": "cli",
                                "priority": prio, "critical": False, "risk_flags": [], "provider": "claude",
                                "model_id": "claude-sonnet-5-5", "harness": "claude-code", "role": role,
                                "worktree": "/tmp/wt-" + name})
        print(sv.propose({"schema": sv.PLAN_SCHEMA, "run_id": rid(name), "assignments": assignments})["status"])
    elif cmd in ("approve", "cancel"):
        word = "APROBAR" if cmd == "approve" else "CANCELAR"
        builtins.input = lambda prompt: f"{word} {rid(args[0])}"
        sys.stdout = open(os.devnull, "w")     # display_plan
        result = getattr(sv, cmd)(rid(args[0]))
        sys.stdout = sys.__stdout__
        print(result["status"])
    elif cmd == "pstart":
        print(sv.process_start_time(int(args[0])))
    elif cmd == "start":             # start <run> <i> <pid> <session> [process_start]
        start = args[4] if len(args) > 4 else sv.process_start_time(int(args[2]))
        print(sv.start_lease(rid(args[0]), lid(args[0], int(args[1])), int(args[2]), start, args[3])["status"])
    elif cmd == "heartbeat":         # heartbeat <run> <i> <pid> <session>
        start = sv.process_start_time(int(args[2])) or "gone"
        print(sv.heartbeat_lease(rid(args[0]), lid(args[0], int(args[1])), int(args[2]), start, args[3])["status"])
    elif cmd == "finish":
        print(sv.finish_lease(rid(args[0]), lid(args[0], int(args[1])))["status"])
    elif cmd == "reconcile":
        r = sv.reconcile(dry_run=bool(args))
        print(f"stale={len(r['stale'])} released={len(r['released'])} human={len(r['needs_human'])}")
    elif cmd == "lease":
        with sv.locked():
            rec = sv.plan_record(sv.read_state(), rid(args[0]))
        print(rec["leases"][lid(args[0], int(args[1]))]["status"])
    elif cmd == "field":             # field <run> <i> <campo>
        with sv.locked():
            rec = sv.plan_record(sv.read_state(), rid(args[0]))
        print(rec["leases"][lid(args[0], int(args[1]))][args[2]])
    elif cmd == "plan":
        with sv.locked():
            print(sv.plan_record(sv.read_state(), rid(args[0]))["status"])
    elif cmd == "plans":             # plans <estado>: cuántos planes hay en ese estado
        with sv.locked():
            print(sum(r["status"] == args[0] for r in sv.read_state()["plans"]))
    elif cmd == "slots":
        print(sv.status()["reserved_implementers"])
    elif cmd == "events":
        kinds = [e["kind"] for e in sv.event_rows()]
        print(kinds.count(args[0]))
    elif cmd == "legacy":            # quita los leases de un plan reservado, como un estado viejo
        state = json.load(open(sv.STATE))
        for rec in state["plans"]:
            if rec["plan"]["run_id"] == rid(args[0]):
                del rec["leases"]
        json.dump(state, open(sv.STATE, "w"))
        print("ok")
except ValueError as exc:
    sys.stdout = sys.__stdout__
    print("error: " + str(exc))
PY
sv()  { SV_LIB="$ROOT/lib" SV_SESSIONS="$SESSIONS" SV_ADAPTER="${ADAPTER:-1}" SV_OFFSET="${OFFSET:-0}" python3 "$TMP/sv.py" "$@"; }
# race <dir> <comando...> ;: corre cada comando (separados por ';') en paralelo detrás de una barrera,
# con la escritura del estado demorada; deja la salida de cada uno en <dir>/<n>.
race() {
  local dir=$1 i=0 args=() pids=(); shift; mkdir -p "$dir"
  for word in "$@" ";"; do
    if [ "$word" = ";" ]; then
      SV_GO="$dir/go" SV_SLOW=0.15 sv "${args[@]}" >"$dir/$i" 2>&1 & pids+=("$!")
      i=$((i+1)); args=()
    else args+=("$word"); fi
  done
  sleep 0.5; : >"$dir/go"
  for p in "${pids[@]}"; do wait "$p"; done
}
outs() { cat "$1"/[0-9]* | sort | uniq -c | sed 's/^ *//' | tr '\n' '|'; }
spawn() { sleep 600 & PIDS+=("$!"); LAST=$!; }
session() { printf '%s\n' "$2" >"$SESSIONS/$1"; }

# --- reserva y slots ---------------------------------------------------------------------------------
check_eq "$(sv propose a implementer:issue:1:normal implementer:issue:2:normal reviewer:pr:9:normal)" pending "propose deja el plan pendiente"
check_eq "$(sv approve a)" reserved "approve reserva el plan"
check_eq "$(sv lease a 0)" reserved "cada asignación recibe un lease reserved"
check_eq "$(sv slots)" 2 "los implementadores ocupan slot; el reviewer no"
check_eq "$(sv propose b implementer:issue:3:normal implementer:issue:4:normal)" pending "otro plan se propone"
check_eq "$(sv approve b)" queued "sin slots el plan queda en cola"
check_eq "$(sv propose c implementer:issue:1:hotfix)" pending "un plan sobre un issue reservado se propone"
check_has "$(sv approve c)" "ya está reservado" "no se aprueba un issue con lease activo"
check_eq "$(sv propose d implementer:issue:5:hotfix)" pending "un hotfix se propone"
check_eq "$(sv approve d)" reserved "un hotfix que entra en el slot libre se reserva"
check_eq "$(sv slots)" 3 "tres implementadores es el máximo"

# --- arranque: adaptador, proceso y sesión -----------------------------------------------------------
spawn; P0=$LAST; spawn; P1=$LAST
session s0 alive; session s1 alive
check_has "$(ADAPTER=0 sv start a 0 "$P0" s0)" "no hay adaptador verificado" "sin adaptador el lease no arranca"
check_eq "$(sv lease a 0)" reserved "sin adaptador sigue reserved"
check_has "$(sv start a 0 "$P0" s0 'Thu Jan  1 00:00:00 1970')" "no pudo confirmar" "otra hora de inicio no es el mismo proceso"
check_has "$(sv start a 0 "$P0" nadie)" "no pudo confirmar" "una sesión que el adaptador no ve no arranca"
check_eq "$(sv start a 0 "$P0" s0)" running "con proceso y sesión confirmados arranca"
check_eq "$(sv events lease.started)" 1 "el arranque deja un evento lease.started"
check_has "$(sv start a 1 "$P0" s1)" "lease ambiguo" "el mismo proceso no toma dos leases"
check_has "$(sv start a 1 "$P1" s0)" "lease ambiguo" "la misma sesión no toma dos leases"
check_has "$(sv start a 0 "$P0" s0)" "no está reservado" "un lease no arranca dos veces"
check_eq "$(sv start a 1 "$P1" s1)" running "el segundo implementador arranca"
check_has "$(sv cancel a)" "leases iniciados" "no se cancela un plan con leases iniciados"

# --- heartbeat y stale -------------------------------------------------------------------------------
check_has "$(sv heartbeat a 0 "$P1" s0)" "no coincide" "un heartbeat con otra identidad se rechaza"
BEFORE=$(sv events lease.started)
check_eq "$(OFFSET=120 sv heartbeat a 0 "$P0" s0)" running "el heartbeat renueva el lease"
check_eq "$(sv events lease.started)" "$BEFORE" "el heartbeat no escribe eventos"
check_eq "$(OFFSET=360 sv reconcile)" "stale=1 released=0 human=1" "a los 5 min sin heartbeat el lease 1 queda stale y retenido"
check_eq "$(sv lease a 0)" running "el lease 0, renovado a los 2 min, sigue running"
check_eq "$(sv lease a 1)" stale "el lease 1 pasa a stale"
check_eq "$(sv slots)" 3 "un lease stale conserva su slot"
check_has "$(OFFSET=360 sv heartbeat a 1 "$P0" s1)" "no coincide" "un lease stale no vuelve con otra identidad"
session s1 unknown
check_has "$(OFFSET=360 sv heartbeat a 1 "$P1" s1)" "sigue stale" "sin sesión confirmada un lease stale no vuelve"
session s1 absent
check_has "$(OFFSET=360 sv heartbeat a 1 "$P1" s1)" "sigue stale" "con la sesión ausente un lease stale no vuelve"
session s1 alive
check_has "$(OFFSET=360 ADAPTER=0 sv heartbeat a 1 "$P1" s1)" "no hay adaptador" "sin adaptador un lease stale no vuelve"
check_eq "$(sv lease a 1)" stale "los heartbeats rechazados lo dejan stale"
check_eq "$(sv events lease.recovered)" 0 "un heartbeat rechazado no escribe lease.recovered"
check_eq "$(OFFSET=360 sv heartbeat a 1 "$P1" s1)" running "misma identidad con proceso y sesión vivos: vuelve a running"
check_eq "$(sv field a 1 stale_at)" None "al volver se limpia stale_at"
check_eq "$(sv events lease.recovered)" 1 "la recuperación deja un evento lease.recovered"
check_eq "$(OFFSET=420 sv heartbeat a 1 "$P1" s1)" running "un heartbeat común después no escribe otro evento"
check_eq "$(sv events lease.recovered)" 1 "sigue habiendo un solo lease.recovered"
check_eq "$(OFFSET=650 sv heartbeat a 0 "$P0" s0)" running "el lease 0 se renueva"
check_eq "$(OFFSET=730 sv reconcile)" "stale=1 released=0 human=1" "sin heartbeat otra vez, el lease 1 vuelve a stale"
check_eq "$(OFFSET=360 sv reconcile --dry-run)" "stale=0 released=0 human=1" "dry-run informa el retenido"

# --- liberación verificada ---------------------------------------------------------------------------
kill "$P1"; wait "$P1" 2>/dev/null
check_eq "$(OFFSET=360 sv reconcile)" "stale=0 released=0 human=1" "proceso muerto con sesión viva: no se libera"
session s1 raise
check_eq "$(OFFSET=360 sv reconcile)" "stale=0 released=0 human=1" "si el adaptador falla, no se libera"
session s1 unknown
check_eq "$(OFFSET=360 sv reconcile)" "stale=0 released=0 human=1" "sesión desconocida: no se libera"
session s1 absent
check_eq "$(OFFSET=360 sv reconcile --dry-run)" "stale=0 released=1 human=0" "dry-run dice que liberaría"
check_eq "$(sv lease a 1)" stale "dry-run no escribe"
check_eq "$(OFFSET=360 ADAPTER=0 sv reconcile)" "stale=0 released=0 human=1" "sin adaptador no se libera"
check_eq "$(OFFSET=360 sv reconcile)" "stale=0 released=1 human=0" "proceso y sesión ausentes: se libera"
check_eq "$(sv lease a 1)" released "el lease queda released"
check_eq "$(sv events lease.released)" 1 "la liberación deja un evento lease.released"

# --- cierre del lease y del plan ---------------------------------------------------------------------
check_has "$(sv finish a 0)" "no se verificó" "no se cierra con el proceso vivo"
kill "$P0"; wait "$P0" 2>/dev/null
check_has "$(sv finish a 0)" "no se verificó" "no se cierra con la sesión viva"
session s0 absent
check_eq "$(sv plan a)" reserved "el plan sigue reservado mientras falte un lease"
check_has "$(sv finish a 2)" "no está iniciado" "el reviewer sin arrancar no se cierra"
check_eq "$(sv cancel d)" cancelled "un plan sin leases iniciados se cancela"
check_eq "$(sv lease d 0)" cancelled "cancelar cancela sus leases"
check_eq "$(sv plan b)" reserved "cancelar libera slots y promueve la cola"
spawn; P2=$LAST; session s2 alive
check_eq "$(sv start a 2 "$P2" s2)" running "arranca el reviewer"
kill "$P2"; wait "$P2" 2>/dev/null; session s2 absent
check_eq "$(sv finish a 2)" completed "el reviewer se cierra con salida verificada"
check_eq "$(sv finish a 0)" completed "el lease 0 se cierra con salida verificada"
check_eq "$(sv plan a)" closed "con todos los leases terminados el plan se cierra"
check_eq "$(sv events plan.closed)" 1 "el cierre deja un evento plan.closed"
check_eq "$(sv slots)" 2 "el plan cerrado ya no ocupa slots"

# --- carreras: varios procesos a la vez sobre el mismo store -----------------------------------------
export XDG_STATE_HOME="$TMP/race"
R="$TMP/r"
race "$R/p" propose r1 implementer:issue:7:normal \; propose r2 implementer:issue:7:normal \; \
            propose r3 implementer:issue:7:normal \; propose r4 implementer:issue:7:normal \; \
            propose r5 implementer:issue:7:normal \; propose r6 implementer:issue:7:normal
check_eq "$(outs "$R/p")" "6 pending|" "seis propose simultáneos terminan bien"
check_eq "$(sv plans pending)" 6 "ningún propose simultáneo pierde su plan"
race "$R/dup" propose d1 implementer:issue:8:normal \; propose d1 implementer:issue:8:normal \; \
              propose d1 implementer:issue:8:normal
check_eq "$(outs "$R/dup")" "2 error: run_id ya existe|1 pending|" "tres propose con el mismo run_id: uno solo entra"
race "$R/a" approve r1 \; approve r2 \; approve r3 \; approve r4 \; approve r5 \; approve r6
check_eq "$(grep -l '^reserved$' "$R/a"/[0-9]* | wc -l | tr -d ' ')" 1 "seis approve sobre el mismo issue: uno solo reserva"
check_eq "$(grep -l 'ya está reservado' "$R/a"/[0-9]* | wc -l | tr -d ' ')" 5 "los otros cinco ven el issue reservado"
check_eq "$(sv plans reserved)" 1 "el estado tiene un solo plan reservado"
check_eq "$(sv events plan.reserved)" 1 "el bus tiene un solo plan.reserved"
check_eq "$(sv slots)" 1 "el issue ocupa un solo slot"

export XDG_STATE_HOME="$TMP/race-slots"
for n in 1 2 3 4 5 6; do sv propose "s$n" "implementer:issue:2$n:normal" >/dev/null; done
race "$R/s" approve s1 \; approve s2 \; approve s3 \; approve s4 \; approve s5 \; approve s6
check_eq "$(outs "$R/s")" "3 queued|3 reserved|" "seis approve en issues distintos: tres reservan y tres esperan"
check_eq "$(sv slots)" 3 "la carrera no pasa el límite de tres implementadores"
check_eq "$(sv events plan.queued)" 3 "el bus registra los tres encolados"
export XDG_STATE_HOME="$TMP/state"

# --- estado viejo y CLI ------------------------------------------------------------------------------
check_eq "$(sv legacy b)" ok "se simula un estado anterior a los leases"
check_eq "$(sv lease b 0)" reserved "un plan reservado sin leases los recibe al leerse"
OUT=$(python3 "$ROOT/lib/supervisor.py" status)
check_has "$OUT" '"verified_harnesses": []' "status: sin adaptadores reales registrados"
check_has "$OUT" '"stale_after_seconds": 300' "status muestra el umbral de stale"
check_has "$(python3 "$ROOT/lib/supervisor.py" reconcile --dry-run)" '"dry_run": true' "el CLI expone reconcile --dry-run"
# approve y cancel controlan ellos mismos que no los llame un agente (no solo bin/bk): entrar directo al módulo,
# con una terminal (un pty se consigue en una línea), desde una tarea bk (BK_TASK_DIR), se niega y no cambia nada.
sv propose gate implementer:issue:91:normal >/dev/null
OUT=$(SV_REAL_HUMAN=1 BK_TASK_DIR="$TMP" sv approve gate)
check_has "$OUT" "error: " "supervisor.approve desde una tarea se niega aunque haya terminal"
check_eq "$(sv plan gate)" pending "supervisor.approve negado no reserva el plan"
OUT=$(SV_REAL_HUMAN=1 BK_TASK_DIR="$TMP" sv cancel gate)
check_has "$OUT" "error: " "supervisor.cancel desde una tarea se niega aunque haya terminal"
check_eq "$(sv plan gate)" pending "supervisor.cancel negado no cancela el plan"
check_eq "$(sv cancel gate)" cancelled "setup: se limpia el plan del control"

# bk supervisor sin subcomando: el uso del supervisor, no un "unbound variable" de bin/bk (set -u).
bkr() { HOME="$TMP/home" "$ROOT/bin/bk" "$@"; }
mkdir -p "$TMP/home"
OUT=$(bkr supervisor 2>&1); RC=$?
check_eq "$RC" 2 "bk supervisor sin subcomando sale con el código de uso"
check_has "$OUT" "uso: bk supervisor" "bk supervisor sin subcomando muestra el uso"
case "$OUT" in *"unbound variable"*) R=hay ;; *) R=no ;; esac
check_eq "$R" no "bk supervisor sin subcomando no corta por set -u"
check_eq "$(stat -f %Lp "$STORE" 2>/dev/null || stat -c %a "$STORE")" 700 "el store es privado"

echo "1..$N"
[ "$FAILED" -eq 0 ]
