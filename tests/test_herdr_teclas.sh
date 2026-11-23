#!/usr/bin/env bash
# La hoja de teclas (alt+/, herdr/mods/hub/keys.js): Comandos (alt+k) y la hoja misma son la puerta a todo y van
# arriba en su propio grupo, no entre los agentes del kit; los agentes del kit siguen en el suyo. Solo node: sin Herdr.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
. "$ROOT/scripts/agents/tap.sh"
tap_begin "tests/test_herdr_teclas.sh"

grupos() {   # → "grupo de alt+k|grupo de alt+/|grupo de alt+i|primer grupo"
  node --input-type=module - "$ROOT/herdr/mods/hub/keys.js" <<'JS'
import fs from 'node:fs';
const src = fs.readFileSync(process.argv[2], 'utf8')
  .replace(/^import [\s\S]*?;$/gm, '').replace(/^export default class \w+/m, 'class Keys').replace(/^export /gm, '');
const K = new Function('div', 'h_flex', 'keys', 'commands', 'run', 'shared', 'props', 'notify', 'Panel', 'rank', 'chips', 'lit',
  src + '\nreturn { entries, GROUPS };')(() => ({}), () => ({}), () => [], () => [], () => {}, () => null, () => ({}), () => {}, class {}, () => [], () => ({}), () => ({}));
const kb = (action, keys) => ({ section: 'global', keys, action });
const g = Object.fromEntries(K.entries([kb('mod.open:bk-palette', 'alt-k'), kb('mod.open:bk-keys', 'alt-/'), kb('mod.open:bk-issues', 'alt-i')], '')
  .map((e) => [e.action, e.group]));
process.stdout.write([g['mod.open:bk-palette'], g['mod.open:bk-keys'], g['mod.open:bk-issues'], K.GROUPS[0]].join('|'));
JS
}

out=$(grupos)
IFS='|' read -r comandos hoja issues primero <<<"$out"
[ -n "$primero" ] && [ "$primero" != "Agentes del kit" ] && [ "$comandos" = "$primero" ] && [ "$hoja" = "$primero" ]
tap_check $? "teclas: Comandos y esta hoja van arriba en su propio grupo, no entre los agentes del kit" "«${out}»"

[ "$issues" = "Agentes del kit" ]
tap_check $? "teclas: implementar un issue sigue entre los agentes del kit" "«${out}»"

tap_done
