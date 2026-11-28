#!/usr/bin/env bash
# lib/supervisor_codex.py: session_state del adaptador de Codex (#40, ADR-003 "Acreditación por harness").
# Sin agentes ni procesos reales: la marca y el proceso son falsos (read_mark y process_info inyectados).
# La lectura genérica de marcas es de #39; acá solo se prueba lo propio de Codex.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck disable=SC1091  # tap.sh se carga en tiempo de ejecución
. "$ROOT/scripts/agents/tap.sh"
tap_begin "tests/test_supervisor_codex.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
# shellcheck disable=SC2016  # se expande al salir, no ahora
tap_at_exit 'rm -rf "$TMP"'
export PYTHONPYCACHEPREFIX="$TMP/pycache"
out=""                                  # lo asigna tap_run

# drv.py <evidencia: all|none> <marca JSON|null> <proceso JSON|null|raise> [session_id]: imprime session_state.
cat >"$TMP/drv.py" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SC_LIB"])
import supervisor_codex as sc
ev, mark, proc = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
sid = sys.argv[4] if len(sys.argv) > 4 else "s-1"
def process_info(pid):
    if proc == "raise":
        raise OSError("ps falló")
    return None if proc == "null" else tuple(json.loads(proc))
evidence = {k: True for k in sc.EVIDENCE} if ev == "all" else None
a = sc.CodexAdapter(read_mark=lambda harness, s: mark if harness == "codex" and s == sid else None,
                    process_info=process_info, evidence=evidence)
print(a.session_state(sid))
PY
export SC_LIB="$ROOT/lib"
st() { tap_run out 0 python3 "$TMP/drv.py" "$@"; }

M='{"schema":1,"harness":"codex","session_id":"s-1","pid":4242,"process_start":"Sat Nov 28 05:00:00 2026","ended_at":null}'
ME='{"schema":1,"harness":"codex","session_id":"s-1","pid":4242,"process_start":"Sat Nov 28 05:00:00 2026","ended_at":"2026-11-28T06:00:00Z"}'
P='["Sat Nov 28 05:00:00 2026","/opt/homebrew/bin/codex"]'
APP='["Sat Nov 28 05:00:00 2026","/opt/homebrew/bin/codex app-server --listen stdio://"]'
OTRO='["Sat Nov 28 07:00:00 2026","/opt/homebrew/bin/codex"]'
con() { python3 -c 'import json,sys; m=json.loads(sys.argv[1]); m.update(json.loads(sys.argv[2])); print(json.dumps(m))' "$1" "$2"; }

# 1. Hoy falta evidencia (ADR-003: Codex no recibe adaptador hasta verificar): todo es unknown.
st none "$M" "$P";  [ "$out" = unknown ]; tap_check $? "sin evidencia verificada, una sesión que parece viva es unknown" "$out"
st none "$ME" null; [ "$out" = unknown ]; tap_check $? "sin evidencia verificada, una sesión que parece terminada es unknown" "$out"

# 2. Con la evidencia marcada como verificada, la lógica propia de Codex.
st all "$M" "$P";   [ "$out" = alive ];   tap_check $? "marca, mismo PID y hora, proceso codex: alive" "$out"
st all "$ME" null;  [ "$out" = absent ];  tap_check $? "ended_at y proceso ausente: absent" "$out"
st all "$ME" "$OTRO"; [ "$out" = absent ]; tap_check $? "ended_at y PID reusado (otra hora): absent" "$out"
st all "$M" null;   [ "$out" = unknown ]; tap_check $? "proceso ausente sin ended_at: unknown (Codex declara SessionEnd)" "$out"
st all "$ME" "$P";  [ "$out" = unknown ]; tap_check $? "ended_at con el proceso vivo: unknown" "$out"

# 3. app-server: un daemon compartido; su PID no identifica una sesión.
st all "$M" "$APP"; [ "$out" = unknown ]; tap_check $? "PID de codex app-server: unknown" "$out"
st all "$ME" "$APP"; [ "$out" = unknown ]; tap_check $? "PID de codex app-server con ended_at: unknown, no absent" "$out"
st all "$(con "$M" '{"transport":"app-server"}')" "$P"; [ "$out" = unknown ]; tap_check $? "marca de una sesión de app-server: unknown" "$out"

# 4. Identidad que no se puede acreditar.
st all "$(con "$M" '{"pid":null}')" "$P"; [ "$out" = unknown ]; tap_check $? "marca sin PID (Codex: PID unknown): unknown" "$out"
st all "$(con "$M" '{"pid":"4242"}')" "$P"; [ "$out" = unknown ]; tap_check $? "PID que no es entero: unknown" "$out"
st all "$(con "$M" '{"pid":1}')" "$P"; [ "$out" = unknown ]; tap_check $? "PID 1 (launchd): unknown" "$out"
st all "$(con "$M" '{"process_start":null}')" "$P"; [ "$out" = unknown ]; tap_check $? "marca sin hora de inicio: unknown" "$out"
st all "$(con "$M" '{"parent_thread_id":"t-0"}')" "$P"; [ "$out" = unknown ]; tap_check $? "subagente (comparte session_id con el padre): unknown" "$out"
st all "$(con "$M" '{"harness":"claude-code"}')" "$P"; [ "$out" = unknown ]; tap_check $? "marca de otro harness: unknown" "$out"
st all "$(con "$M" '{"session_id":"s-2"}')" "$P"; [ "$out" = unknown ]; tap_check $? "marca de otra sesión: unknown" "$out"
st all "$(con "$M" '{"schema":2}')" "$P"; [ "$out" = unknown ]; tap_check $? "schema desconocido: unknown" "$out"
st all null "$P";   [ "$out" = unknown ]; tap_check $? "sin marca: unknown" "$out"
st all '"texto"' "$P"; [ "$out" = unknown ]; tap_check $? "marca que no es un objeto: unknown" "$out"
st all "$M" raise;  [ "$out" = unknown ]; tap_check $? "ps falla: unknown" "$out"
st all "$M" '["Sat Nov 28 05:00:00 2026","/usr/bin/python3 x.py"]'; [ "$out" = unknown ]; tap_check $? "mismo PID y hora pero otro programa: unknown" "$out"

# 5. El adaptador no se registra (ADR-003: sin adaptador hasta verificar; #40: bk run sigue sin reservar).
tap_run out 0 python3 -c 'import os,sys; sys.path.insert(0, os.environ["SC_LIB"]); import supervisor_codex, supervisor; print(sorted(supervisor.HARNESS_ADAPTERS))'
[ "$out" = "[]" ]; tap_check $? "importar el adaptador no lo registra en HARNESS_ADAPTERS" "$out"

tap_done
