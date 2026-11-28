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
# es <esperado> <descripción> <args de drv.py…>: corre drv.py y compara su salida.
es() {
  local want="$1" d="$2" r=1; shift 2
  st "$@"
  if [ "$out" = "$want" ]; then r=0; fi
  tap_check "$r" "$d" "$out"
}

M='{"schema":1,"harness":"codex","session_id":"s-1","pid":4242,"process_start":"Sat Nov 28 05:00:00 2026","ended_at":null}'
ME='{"schema":1,"harness":"codex","session_id":"s-1","pid":4242,"process_start":"Sat Nov 28 05:00:00 2026","ended_at":"2026-11-28T06:00:00Z"}'
P='["Sat Nov 28 05:00:00 2026","/opt/homebrew/bin/codex"]'
APP='["Sat Nov 28 05:00:00 2026","/opt/homebrew/bin/codex app-server --listen stdio://"]'
OTRO='["Sat Nov 28 07:00:00 2026","/opt/homebrew/bin/codex"]'
con() { python3 -c 'import json,sys; m=json.loads(sys.argv[1]); m.update(json.loads(sys.argv[2])); print(json.dumps(m))' "$1" "$2"; }

# 1. Hoy falta evidencia (ADR-003: Codex no recibe adaptador hasta verificar): todo es unknown.
es unknown "sin evidencia verificada, una sesión que parece viva es unknown" none "$M" "$P"
es unknown "sin evidencia verificada, una sesión que parece terminada es unknown" none "$ME" null

# 2. Con la evidencia marcada como verificada, la lógica propia de Codex.
es alive "marca, mismo PID y hora, proceso codex: alive" all "$M" "$P"
es absent "ended_at y proceso ausente: absent" all "$ME" null
es absent "ended_at y PID reusado (otra hora): absent" all "$ME" "$OTRO"
es unknown "proceso ausente sin ended_at: unknown (Codex declara SessionEnd)" all "$M" null
es unknown "ended_at con el proceso vivo: unknown" all "$ME" "$P"

# 3. app-server: un daemon compartido; su PID no identifica una sesión.
es unknown "PID de codex app-server: unknown" all "$M" "$APP"
es unknown "PID de codex app-server con ended_at: unknown, no absent" all "$ME" "$APP"
es unknown "marca de una sesión de app-server: unknown" all "$(con "$M" '{"transport":"app-server"}')" "$P"

# 4. Identidad que no se puede acreditar.
es unknown "marca sin PID (Codex: PID unknown): unknown" all "$(con "$M" '{"pid":null}')" "$P"
es unknown "PID que no es entero: unknown" all "$(con "$M" '{"pid":"4242"}')" "$P"
es unknown "PID decimal: unknown" all "$(con "$M" '{"pid":4242.0}')" "$P"
es unknown "PID 1 (launchd): unknown" all "$(con "$M" '{"pid":1}')" "$P"
es unknown "marca sin hora de inicio: unknown" all "$(con "$M" '{"process_start":null}')" "$P"
es unknown "subagente (comparte session_id con el padre): unknown" all "$(con "$M" '{"parent_thread_id":"t-0"}')" "$P"
es unknown "marca de otro harness: unknown" all "$(con "$M" '{"harness":"claude-code"}')" "$P"
es unknown "marca de otra sesión: unknown" all "$(con "$M" '{"session_id":"s-2"}')" "$P"
es unknown "schema desconocido: unknown" all "$(con "$M" '{"schema":2}')" "$P"
es unknown "sin marca: unknown" all null "$P"
es unknown "marca que no es un objeto: unknown" all '"texto"' "$P"
es unknown "ps falla: unknown" all "$M" raise
es unknown "mismo PID y hora pero otro programa: unknown" all "$M" '["Sat Nov 28 05:00:00 2026","/usr/bin/python3 x.py"]'

# 5. El adaptador no se registra (ADR-003: sin adaptador hasta verificar; #40: bk run sigue sin reservar).
tap_run out 0 python3 -c 'import os,sys; sys.path.insert(0, os.environ["SC_LIB"]); import supervisor_codex, supervisor; print(sorted(supervisor.HARNESS_ADAPTERS))'
r=1; if [ "$out" = "[]" ]; then r=0; fi
tap_check "$r" "importar el adaptador no lo registra en HARNESS_ADAPTERS" "$out"

tap_done
