#!/usr/bin/env bash
# Herdr colgado (hc no responde): lib/agents.py lo espera una sola vez por corrida, no una por terminal. Un hc
# falso que duerme y cuenta las veces que lo llamaron; nada toca el Herdr real.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
printf '#!/bin/sh\necho x >>"%s/calls"\nsleep 5\n' "$TMP" >"$TMP/hc"; chmod +x "$TMP/hc"
printf '#!/bin/sh\necho x >>"%s/ok-calls"\necho "{}"\n' "$TMP" >"$TMP/hc-ok"; chmod +x "$TMP/hc-ok"
run() {   # <hc> <código python con AG ya importado>
  (cd "$ROOT/lib" && BK_HC="$1" BK_BACKEND=herdr python3 -c "import agents as AG, sessions as SS
$2")
}
out=$(run "$TMP/hc" 'print(repr(AG.sh(AG.HC, "ls", timeout=1)), repr(AG.sh(AG.HC, "get", "t1", timeout=1)), repr(SS.sh(AG.HC, "ls")))')
check_eq "$out $(wc -l <"$TMP/calls" | tr -d ' ')" "'' '' '' 1" "hc colgado: la primera llamada vence y las demás (también las de sessions.py) no lo esperan"
out=$(run "$TMP/hc" 'AG.sh(AG.HC, "ls", timeout=1); print(AG.sh("echo", "sigue").strip())')
check_eq "$out" "sigue" "hc colgado: los comandos que no son hc siguen andando"
out=$(run "$TMP/hc-ok" 'print(AG.sh(AG.HC, "ls").strip(), AG.sh(AG.HC, "ls").strip())')
check_eq "$out $(wc -l <"$TMP/ok-calls" | tr -d ' ')" "{} {} 2" "hc que responde: cada llamada va a Herdr"
echo "1..$N"
[ "$FAILED" -eq 0 ]
