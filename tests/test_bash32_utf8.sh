#!/usr/bin/env bash
# El bash 3.2 de macOS (el de #!/bin/bash) con un locale UTF-8 (es_AR.UTF-8) se come el carácter no ASCII que sigue a
# una variable sin llaves: "«$q»" sale "«\xc2" y "$x…" sale basura. Toda variable pegada a un carácter no ASCII va
# con llaves: "«${q}»", "${x}…". Este test busca las que no en los scripts de shell del repo.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
N=0; FAILED=0
ok()  { N=$((N+1)); echo "ok $N - $1"; }
bad() { N=$((N+1)); echo "not ok $N - $1"; FAILED=$((FAILED+1)); }

# Las líneas de un archivo con una variable sin llaves pegada a un byte no ASCII ($1, $? y compañía no cuentan).
# Los comentarios no se expanden: no cuentan.
scan() { perl -ne 'print "$ARGV:$.: $_" if !/^\s*#/ && /(?<!\\)\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]/; close ARGV if eof' "$@"; }

# El detector mismo: marca lo malo y deja pasar lo bueno.
printf '%s\n' 'echo "«$q»"' >"$TMP/mal1.sh"; printf '%s\n' 'echo "esperando $x…"' >"$TMP/mal2.sh"
printf '%s\n' 'echo "«${q}»" "${x}…" "$1…" "\$q»" "$q ·"' '  # un comentario con «$q»' >"$TMP/bien.sh"
[ -n "$(scan "$TMP/mal1.sh")" ] && ok "marca «\$q»" || bad "marca «\$q»"
[ -n "$(scan "$TMP/mal2.sh")" ] && ok "marca \$x…" || bad "marca \$x…"
[ -z "$(scan "$TMP/bien.sh")" ] && ok "deja pasar las variables con llaves, posicionales, escapadas o con espacio" \
  || bad "deja pasar lo bueno (marcó: $(scan "$TMP/bien.sh"))"

# El problema es real con el bash de macOS: si este caso deja de fallar, el test sigue valiendo pero conviene saberlo.
if [ -x /bin/bash ] && locale -a 2>/dev/null | grep -qi '^es_AR.UTF-8$'; then
  out=$(LC_ALL=es_AR.UTF-8 /bin/bash -c 'q=hola; printf %s "«${q}»"')
  [ "$out" = "«hola»" ] && ok "con llaves sale bien en /bin/bash con es_AR.UTF-8" || bad "con llaves sale '$out'"
fi

# Los scripts de shell del repo: .sh, bin/, hooks/, githooks/ y cualquier otro con #! de sh o bash.
files=()
while IFS= read -r f; do
  [ -f "$ROOT/$f" ] || continue
  case "$f" in
    *.py|*.js|*.json|*.md|*.yml|*.txt|tests/test_bash32_utf8.sh) continue ;;
    *.sh|bin/*|hooks/*|githooks/*) files+=("$ROOT/$f") ;;
    *) head -c 64 "$ROOT/$f" 2>/dev/null | grep -qE '^#!.*(ba)?sh' && files+=("$ROOT/$f") ;;
  esac
done < <(git -C "$ROOT" ls-files)
[ "${#files[@]}" -gt 20 ] && ok "encontró ${#files[@]} scripts de shell" || bad "encontró solo ${#files[@]} scripts de shell"
found=$(scan "${files[@]}" | sed "s#^$ROOT/##")
if [ -z "$found" ]; then ok "ninguna variable sin llaves pegada a un carácter no ASCII"
else bad "variables sin llaves pegadas a un carácter no ASCII (poné llaves):"; printf '%s\n' "$found" | sed 's/^/# /'; fi

echo "1..$N"
[ "$FAILED" -eq 0 ]
