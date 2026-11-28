#!/usr/bin/env bash
# Adaptador de Claude Code del supervisor (ADR-003, contrato integrado en #55, 0364135):
# lee las marcas de sesión de sessions/claude-code-<session_id>.json y nunca escribe.
# Todo va a un XDG_STATE_HOME temporal; los procesos de las marcas son `sleep` propios del test.
# No registra el adaptador en HARNESS_ADAPTERS de lib/supervisor.py (eso queda para la aprobación):
# el driver lo registra solo dentro de su propio proceso para probar el ciclo de lease.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
# shellcheck disable=SC1091  # tap.sh se carga en tiempo de ejecución
. "$ROOT/scripts/agents/tap.sh"
tap_begin "tests/test_claude_code_adapter.sh"
tap_at_exit cleanup
check_eq() { local r=0; [ "$1" = "$2" ] || r=1; tap_check "$r" "$3" "got '$1', want '$2'"; }   # el id es el tercer argumento, literal

export XDG_STATE_HOME="$TMP/state"
export PYTHONPYCACHEPREFIX="$TMP/pycache"
MARKS="$XDG_STATE_HOME/bk/supervisor/sessions"; mkdir -p "$MARKS"

cat >"$TMP/cc.py" <<'PY'
import builtins, json, os, sys, uuid
sys.path.insert(0, os.environ["CC_LIB"])
import supervisor as sv
import harness_claude_code as cc

def rid(name): return str(uuid.uuid5(uuid.NAMESPACE_URL, "run/" + name))
def lid(name, i): return str(uuid.uuid5(uuid.NAMESPACE_URL, f"lease/{name}/{i}"))

cmd, args = sys.argv[1], sys.argv[2:]
try:
    if cmd == "pstart":
        print(sv.process_start_time(int(args[0])))
    elif cmd == "mark":       # mark <session_id> <pid> <process_start> <started_at> <ended_at|-> [run lease|- -]
        sid, pid, start, started, ended = args[:5]
        run = rid(args[5]) if len(args) > 5 and args[5] != "-" else None
        lease = lid(args[5], int(args[6])) if len(args) > 6 and args[6] != "-" else None
        mark = {"schema": 1, "harness": "claude-code", "session_id": sid, "pid": int(pid),
                "process_start": start, "started_at": started, "ended_at": None if ended == "-" else ended,
                "run_id": run, "lease_id": lease}
        with open(os.path.join(cc.sessions_dir(), f"claude-code-{sid}.json"), "w") as f:
            json.dump(mark, f)
    elif cmd == "state":
        print(cc.ClaudeCodeAdapter().session_state(args[0]))
    elif cmd == "link":       # link <run> <i>
        found = cc.ClaudeCodeAdapter().link_mark(rid(args[0]), lid(args[0], int(args[1])))
        print("none" if found is None else found[2])
    elif cmd == "lease":      # lease <run> <step>: ciclo real de supervisor.py con el adaptador registrado acá
        sv.HARNESS_ADAPTERS["claude-code"] = cc.ClaudeCodeAdapter()
        sv.require_terminal = lambda action: None
        sv.require_human = lambda action: None
        name, step = args
        if step == "plan":
            builtins.input = lambda prompt: f"APROBAR {rid(name)}"
            sv.propose({"schema": sv.PLAN_SCHEMA, "run_id": rid(name), "assignments": [{
                "task_id": str(uuid.uuid5(uuid.NAMESPACE_URL, "task/" + name)), "lease_id": lid(name, 0),
                "resource_kind": "issue", "resource_number": 900, "task_type": "feature", "area": "cli",
                "priority": "normal", "critical": False, "risk_flags": [], "provider": "claude",
                "model_id": "claude-sonnet-5-5", "harness": "claude-code", "role": "implementer",
                "worktree": "/tmp/wt-" + name}]})
            sys.stdout = open(os.devnull, "w")
            sv.approve(rid(name))
            sys.stdout = sys.__stdout__
            print("reserved")
        elif step == "start":
            found = cc.ClaudeCodeAdapter().link_mark(rid(name), lid(name, 0))
            if found is None:
                print("no-link")
            else:
                print(sv.start_lease(rid(name), lid(name, 0), *found)["status"])
        elif step == "finish":
            print(sv.finish_lease(rid(name), lid(name, 0))["status"])
except ValueError as e:
    print("error: " + str(e))
PY
cc() { CC_LIB="$ROOT/lib" python3 "$TMP/cc.py" "$@"; }
spawn() { sleep 600 & PIDS+=("$!"); LAST=$!; }
T0="2026-11-28T06:00:00Z"; T1="2026-11-28T06:00:05Z"; T2="2026-11-28T06:00:09Z"

# --- session_state -----------------------------------------------------------------------------------
spawn; P1=$LAST; S1=$(cc pstart "$P1")
cc mark s-alive "$P1" "$S1" "$T0" -
check_eq "$(cc state s-alive)" alive "marca sin ended_at y su proceso vivo con esa hora: alive"
check_eq "$(cc state s-missing)" unknown "sin marca: unknown (no prueba ni vida ni fin)"
# Una ruta en el session_id saldría del prefijo: claude-code-x/../s-trav.json es sessions/s-trav.json.
mkdir -p "$MARKS/claude-code-x"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["session_id"]="x/../s-trav"; json.dump(m,open(sys.argv[2],"w"))' \
  "$MARKS/claude-code-s-alive.json" "$MARKS/s-trav.json"
check_eq "$(cc state x/../s-trav)" unknown "session_id inválido (ruta): unknown, no se lee fuera del prefijo"

cc mark s-ended-alive "$P1" "$S1" "$T0" "$T1"
check_eq "$(cc state s-ended-alive)" unknown "ended_at con el proceso vivo: unknown (no se libera)"

spawn; P2=$LAST; S2=$(cc pstart "$P2")
cc mark s-gone "$P2" "$S2" "$T0" "$T1"
cc mark s-gone-noend "$P2" "$S2" "$T0" -
kill "$P2"; wait "$P2" 2>/dev/null || true
check_eq "$(cc state s-gone)" absent "ended_at y el proceso ausente: absent"
check_eq "$(cc state s-gone-noend)" unknown "proceso ausente sin SessionEnd: unknown (Claude Code tiene evento de fin)"

cc mark s-reused "$P1" "Mon Jan  1 00:00:00 2001" "$T0" -
check_eq "$(cc state s-reused)" unknown "marca vencida (PID con otra hora de inicio) sin ended_at: unknown"
cc mark s-reused-end "$P1" "Mon Jan  1 00:00:00 2001" "$T0" "$T1"
check_eq "$(cc state s-reused-end)" absent "marca vencida con ended_at: el proceso de la marca ya no existe, absent"

printf '{not json' >"$MARKS/claude-code-s-corrupt.json"
check_eq "$(cc state s-corrupt)" unknown "marca ilegible: unknown"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["schema"]=2; m["session_id"]="s-schema"; json.dump(m,open(sys.argv[2],"w"))' \
  "$MARKS/claude-code-s-alive.json" "$MARKS/claude-code-s-schema.json"
check_eq "$(cc state s-schema)" unknown "otro schema: unknown"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["extra"]=1; m["session_id"]="s-extra"; json.dump(m,open(sys.argv[2],"w"))' \
  "$MARKS/claude-code-s-alive.json" "$MARKS/claude-code-s-extra.json"
check_eq "$(cc state s-extra)" unknown "una clave fuera del schema 1: unknown"
badtime() {  # badtime <session> <campo> <valor>: copia de s-alive con un campo de hora malformado
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["session_id"]=sys.argv[3]; m[sys.argv[4]]=sys.argv[5]; json.dump(m,open(sys.argv[2],"w"))' \
    "$MARKS/claude-code-s-alive.json" "$MARKS/claude-code-$1.json" "$1" "$2" "$3"
}
badtime s-notz started_at "2026-11-28T06:00:00"
check_eq "$(cc state s-notz)" unknown "started_at sin zona horaria: unknown"
badtime s-offset started_at "2026-11-28T03:00:00-03:00"
check_eq "$(cc state s-offset)" unknown "started_at con zona que no es UTC: unknown"
badtime s-text started_at "ayer"
check_eq "$(cc state s-text)" unknown "started_at que no es ISO: unknown"
badtime s-badend ended_at "2026-13-01T00:00:00Z"
check_eq "$(cc state s-badend)" unknown "ended_at malformado (mes 13): unknown"
cc mark s-backwards "$P2" "$S2" "$T0" "2026-11-28T05:00:00Z"   # P2 ya terminó: sin el control daría absent
check_eq "$(cc state s-backwards)" unknown "ended_at anterior a started_at: unknown"
cp "$MARKS/claude-code-s-alive.json" "$MARKS/claude-code-s-other.json"
check_eq "$(cc state s-other)" unknown "el session_id de adentro no coincide con el nombre: unknown"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["harness"]="agy"; m["session_id"]="s-harness"; json.dump(m,open(sys.argv[2],"w"))' \
  "$MARKS/claude-code-s-alive.json" "$MARKS/claude-code-s-harness.json"
check_eq "$(cc state s-harness)" unknown "marca de otro harness: unknown"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["pid"]=True; m["session_id"]="s-bool"; m["ended_at"]="2026-11-28T06:00:05Z"; json.dump(m,open(sys.argv[2],"w"))' \
  "$MARKS/claude-code-s-alive.json" "$MARKS/claude-code-s-bool.json"
check_eq "$(cc state s-bool)" unknown "pid que no es entero: unknown"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["session_id"]="s-link"; json.dump(m,open(sys.argv[2],"w"))' \
  "$MARKS/claude-code-s-alive.json" "$TMP/afuera.json"
ln -s "$TMP/afuera.json" "$MARKS/claude-code-s-link.json"
check_eq "$(cc state s-link)" unknown "marca que es un enlace simbólico: unknown"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); m["session_id"]="s-big"; open(sys.argv[2],"w").write(json.dumps(m)+" "*5000)' \
  "$MARKS/claude-code-s-alive.json" "$MARKS/claude-code-s-big.json"
check_eq "$(cc state s-big)" unknown "marca más grande que el límite: unknown, no se lee entera"
mkfifo "$MARKS/claude-code-s-fifo.json"
check_eq "$(cc state s-fifo)" unknown "un FIFO en lugar de la marca: unknown, sin colgarse"

# --- link_mark: el enlace del lease reserved -------------------------------------------------------
check_eq "$(cc link r-none 0)" none "sin marca de ese lease: no enlaza (queda reserved)"
spawn; P3=$LAST; S3=$(cc pstart "$P3")
cc mark l-one "$P3" "$S3" "$T0" - r-one 0
cc mark l-otherlease "$P3" "$S3" "$T0" - r-one 1
check_eq "$(cc link r-one 0)" l-one "una marca con ese run y ese lease y su proceso vivo: enlaza esa"

spawn; P4=$LAST; S4=$(cc pstart "$P4")
cc mark l-amb-a "$P3" "$S3" "$T0" - r-amb 0
cc mark l-amb-b "$P4" "$S4" "$T1" - r-amb 0
check_eq "$(cc link r-amb 0)" none "dos procesos distintos con el mismo lease: ambiguo, no enlaza"

cc mark l-old "$P4" "$S4" "$T0" - r-same 0
cc mark l-new "$P4" "$S4" "$T2" - r-same 0
check_eq "$(cc link r-same 0)" l-old "dos marcas del mismo proceso: la más vieja"
cc mark l-tie-a "$P4" "$S4" "$T1" - r-tie 0
cc mark l-tie-b "$P4" "$S4" "$T1" - r-tie 0
check_eq "$(cc link r-tie 0)" none "dos marcas del mismo proceso con la misma hora: ambiguo, no enlaza"
cc mark l-tz-a "$P4" "$S4" "2026-11-28T06:00:05Z" - r-tz 0
cc mark l-tz-b "$P4" "$S4" "2026-11-28T06:00:05+00:00" - r-tz 0
check_eq "$(cc link r-tz 0)" none "el mismo instante escrito distinto: ambiguo, no enlaza"
cc mark l-frac "$P4" "$S4" "2026-11-28T06:00:09.500Z" - r-inst 0
cc mark l-whole "$P4" "$S4" "2026-11-28T06:00:09Z" - r-inst 0
check_eq "$(cc link r-inst 0)" l-whole "la más vieja por instante, no por texto (09Z antes que 09.500Z)"

spawn; P5=$LAST; S5=$(cc pstart "$P5")
cc mark l-ended "$P5" "$S5" "$T0" "$T1" r-ended 0
check_eq "$(cc link r-ended 0)" none "marca con ended_at: no enlaza"
# /clear o resume antes del enlace: la sesión del proceso cambió (ADR-003: queda unknown hasta verificarlo).
cc mark l-clear-old "$P5" "$S5" "$T0" "$T1" r-clear 0
cc mark l-clear-new "$P5" "$S5" "$T2" - r-clear 0
check_eq "$(cc link r-clear 0)" none "una marca terminada del mismo proceso y lease (un /clear antes del enlace): no enlaza"
cc mark l-dead "$P2" "$S2" "$T0" - r-dead 0
check_eq "$(cc link r-dead 0)" none "marca de un proceso que ya no existe: no enlaza"
cc mark l-stale "$P5" "Mon Jan  1 00:00:00 2001" "$T0" - r-stale 0
check_eq "$(cc link r-stale 0)" none "marca vencida (PID reutilizado): no enlaza"

# --- ciclo de lease real con el adaptador ------------------------------------------------------------
check_eq "$(cc lease c1 plan)" reserved "plan aprobado: lease reserved"
check_eq "$(cc lease c1 start)" no-link "sin marca, start no enlaza: el lease sigue reserved"
spawn; P6=$LAST; S6=$(cc pstart "$P6")
cc mark c-main "$P6" "$S6" "$T0" - c1 0
check_eq "$(cc lease c1 start)" running "con la marca de la sesión: running"
cc mark c-main "$P6" "$S6" "$T0" "$T1" c1 0
check_eq "$(cc lease c1 finish)" "error: no se verificó la salida del proceso y de la sesión; el lease conserva issue y slot" \
  "SessionEnd con el proceso vivo: no se libera"
kill "$P6"; wait "$P6" 2>/dev/null || true
check_eq "$(cc lease c1 finish)" completed "SessionEnd y el proceso ausente: completed"

tap_done
