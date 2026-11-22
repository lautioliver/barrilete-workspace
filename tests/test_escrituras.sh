#!/usr/bin/env bash
# Archivos que escriben varios bk a la vez (los paneles de Herdr, dos ventanas, el riel): una escritura que se corta
# a la mitad no deja el archivo roto. Si se rompía, titles.json volvía a pedir todos los títulos a GitHub y ui.json
# perdía el aspecto elegido. Todo en una carpeta temporal (HOME y BK_CACHE_DIR apuntan ahí).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
mkdir -p "$TMP/.cache/bk" "$TMP/.cache/barrilete" "$TMP/.config/bk"
cut() {   # <archivo> <código que lo escribe, con AG, SS y G importados>: json.dump escribe medio archivo y falla
  echo '{"viejo": 1}' >"$1"
  (cd "$ROOT/lib" && HOME="$TMP" BK_CACHE_DIR="$TMP/.cache/bk" python3 -c "
import json, agents as AG, sessions as SS, gentle as G
def cortado(obj, f, *a, **k):
    f.write('{\"nuevo\": ')
    raise OSError('disco lleno')
json.dump = cortado
try:
    $2
except OSError:
    pass
print(json.load(open('$1')))")
}
check_eq "$(cut "$TMP/.cache/bk/titles.json" 'AG.save_titles({"a": "b"})')" "{'viejo': 1}" "titles.json: una escritura cortada deja el archivo anterior"
check_eq "$(cut "$TMP/.cache/barrilete/sessions.json" 'SS.save_cache({"a": {}})')" "{'viejo': 1}" "sessions.json: una escritura cortada deja el archivo anterior"
check_eq "$(cut "$TMP/.config/bk/ui.json" 'G.save_ui({"a": 1})')" "{'viejo': 1}" "ui.json: una escritura cortada deja el aspecto anterior"
left=$(find "$TMP" -name '*.tmp' | wc -l | tr -d ' ')
check_eq "$left" "0" "las escrituras cortadas no dejan temporales"
echo '[1]' >"$TMP/.config/bk/ui.json"
got=$(cd "$ROOT/lib" && HOME="$TMP" python3 -c 'import gentle as G; print(G.ui() == G.DEFAULTS)' 2>&1 | tail -1)
check_eq "$got" "True" "un ui.json que no es un objeto vale como el aspecto de siempre"
echo "1..$N"
[ "$FAILED" -eq 0 ]
