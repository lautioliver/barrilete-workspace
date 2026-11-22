#!/usr/bin/env bash
# El encabezado de Ramas (alt+b, herdr/mods/hub/branches.js): mientras lee por primera vez no dice «0 ramas», con datos
# cuenta las ramas y las terminadas, y al recargar no vuelve a cero. Solo node: sin Herdr ni bk.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
. "$ROOT/scripts/agents/tap.sh"
tap_begin "tests/test_herdr_branches.sh"

sub() {   # $1: JSON con loading y data → el subtítulo
  node --input-type=module - "$ROOT/herdr/mods/hub/branches.js" "$1" <<'JS'
import fs from 'node:fs';
const src = fs.readFileSync(process.argv[2], 'utf8')
  .replace(/^import [\s\S]*?;$/gm, '').replace('export default class Branches', 'class Branches');
const Branches = new Function('Panel', 'cwd', src + '\nreturn Branches;')(class {}, () => '/p');
const b = new Branches(); b.setup(); Object.assign(b, JSON.parse(process.argv[3]));
process.stdout.write(b.subtitle());
JS
}

two='{"projects":[{"items":[{"name":"a","done":true},{"name":"b"}]}]}'

out=$(sub '{"loading":true}')
[ -z "$out" ]
tap_check $? "ramas: mientras lee la primera vez no cuenta cero" "«${out}»"

out=$(sub "{\"loading\":false,\"data\":$two}")
[ "$out" = "2 ramas · 1 terminadas" ]
tap_check $? "ramas: con datos cuenta las ramas y las terminadas" "«${out}»"

out=$(sub "{\"loading\":true,\"data\":$two}")
[ "$out" = "2 ramas · 1 terminadas" ]
tap_check $? "ramas: al recargar sigue mostrando la cuenta" "«${out}»"

out=$(sub '{"loading":false,"data":{"projects":[]}}')
[ "$out" = "0 ramas" ]
tap_check $? "ramas: ya leído y sin ramas, dice cero" "«${out}»"

tap_done
