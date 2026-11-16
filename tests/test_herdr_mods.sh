#!/usr/bin/env bash
# Los mods de bk en Herdr que se pueden probar sin abrir Herdr: el mod de las acciones (herdr/mods/bk/main.js) corre
# en node con un herdr falso. Sus avisos: muestra la cola que deja hd_notice (lib/herdr.sh) y la vacía, sobre una
# cola en una carpeta temporal; ls y rm son los de verdad y los avisos los escribe el hd_notice real. Su despacho:
# qué nombres atiende. Y la fila de la lista de agentes.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
Q="$HOME/.cache/bk/herdr-avisos"

# hd_notice de verdad, con un herdr-app que no abre nada (anota que lo llamaron)
WS="$ROOT"; info() { :; }; hd_app() { echo "$*" >>"$TMP/app.log"; }
eval "$(sed -n '/^hd_notice() {$/,/^}$/p' "$ROOT/lib/herdr.sh")"   # (bash 3.2 no lee un . <(…))
declare -F hd_notice >/dev/null || { echo "not ok - no encontré hd_notice en lib/herdr.sh"; exit 1; }
hd_notice "Resumen listo: proj" "Clic para seguir en un chat nuevo" bk-seguir
hd_notice "Chat nuevo" "listo" "" success "$TMP/a.log"
hd_notice "bk run 42" "prepare.sh rechazó #42" "" error "$TMP/b.log"
[ "$(ls "$Q" | wc -l | tr -d ' ')" = 3 ] || { echo "not ok - hd_notice no dejó los tres avisos en la cola"; exit 1; }

node --input-type=module - "$ROOT" "$HOME" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
const [root, home] = process.argv.slice(2);
const Q = `${home}/.cache/bk/herdr-avisos`;
const source = fs.readFileSync(`${root}/herdr/mods/bk/main.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Bk', 'class Bk');
let notes = [], ran = [], onExec = null;
const exec = async (cmd, args) => {
  ran.push([cmd, ...args]);
  assert.ok(['ls', 'rm'].includes(cmd) && args.every((a) => a === '-f' || a.startsWith(Q)), `el mod solo lista y borra en la cola: ${cmd} ${args.join(' ')}`);
  if (onExec) await onExec(cmd, args);
  try {
    return { code: 0, stdout: execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }), stderr: '' };
  } catch (e) {
    return { code: e.status ?? 1, stdout: e.stdout ?? '', stderr: e.stderr ?? '' };
  }
};
const readTextFile = async (p) => (fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null);
const nope = (name) => () => { throw Error(`aviso no usa ${name}`); };
const Bk = new Function('View', 'div', 'hc', 'exec', 'run', 'props', 'openOverlay', 'closeOverlay', 'focused', 'terminals',
  'spaces', 'agents', 'home', 'notify', 'shared', 'setShared', 'readTextFile', source + '\nreturn Bk;')(
  class {}, () => ({}), nope('hc'), exec, nope('run'), () => ({}), nope('openOverlay'), nope('closeOverlay'), () => null,
  () => [], () => [], () => [], () => home, (n) => notes.push(n), () => null, nope('setShared'), readTextFile);
const bk = new Bk();
const queue = () => fs.readdirSync(Q).sort();
const put = (name, obj) => fs.writeFileSync(`${Q}/${name}`, typeof obj === 'string' ? obj : JSON.stringify(obj));
const now = Math.floor(Date.now() / 1000);
let n = 0;
const ok = (what) => console.log(`ok ${++n} - ${what}`);

// 1-4: los tres avisos de hd_notice, en el orden en que se pidieron
await bk.handle('aviso');
assert.deepEqual(notes.map((x) => x.title), ['Resumen listo: proj', 'Chat nuevo', 'bk run 42']);
ok('muestra todos los avisos de la cola, del más viejo al más nuevo');
assert.deepEqual([notes[0].level, notes[0].timeout, notes[0].action], ['info', 600000, { name: 'mod.open', args: { name: 'bk-seguir' } }]);
ok('el que trae un mod: su clic lo abre y espera diez minutos');
assert.deepEqual(notes.slice(1).map((x) => [x.level, x.body, x.timeout, x.action]),
  [['success', 'listo', 5000, undefined], ['error', 'prepare.sh rechazó #42', 15000, undefined]]);
ok('los de bk _do: con su nivel y su texto, sin clic, y el error queda más tiempo a la vista');
assert.deepEqual(queue(), []);
ok('la cola queda vacía');

// 5: sin nada que mostrar
notes = [];
await bk.handle('aviso');
assert.deepEqual(notes, []);
fs.rmSync(Q, { recursive: true });
await bk.handle('aviso');
assert.deepEqual(notes, []);
ok('con la cola vacía, o sin la carpeta, no avisa nada ni falla');
fs.mkdirSync(Q, { recursive: true });

// 6: los viejos se borran sin mostrarse
put('1000000000-1.json', { title: 'viejo', body: 'de ayer', mod: '', level: 'info', ts: now - 601 });
put('1000000001-1.json', { title: 'justo', body: '', mod: '', level: 'info', ts: now - 590 });
await bk.handle('aviso');
assert.deepEqual([notes.map((x) => x.title), queue()], [['justo'], []]);
ok('un aviso de hace más de diez minutos se borra sin mostrarse; uno de menos, se muestra');

// 7: lo que no es un aviso
notes = [];
put('1-1.json', '{"title": "cortado');
put('2-1.json', '[1, 2]');
put('3-1.json', { body: 'sin título', ts: now });
put('4-1.json', { title: 'raro', level: 'toString', mod: { name: 'x' }, ts: now });
put('5-1.json.tmp', { title: 'a medio escribir', ts: now });
put('notas.txt', 'no es de la cola');
await bk.handle('aviso');
assert.deepEqual(notes, [{ title: 'raro', body: '', level: 'info', timeout: 5000 }]);
ok('un archivo roto, uno sin título y un nivel o un mod que no son tales: no rompen, y el nivel cae en info');
assert.deepEqual(queue(), ['5-1.json.tmp', 'notas.txt']);
ok('borra solo los .json de la cola: el .tmp que hd_notice está escribiendo y lo ajeno quedan');
fs.rmSync(`${Q}/5-1.json.tmp`); fs.rmSync(`${Q}/notas.txt`);

// 9: avisa antes de borrar, de a uno
notes = []; ran = [];
put('1-1.json', { title: 'uno', ts: now }); put('2-1.json', { title: 'dos', ts: now });
const seen = [];
onExec = (cmd, args) => { if (cmd === 'rm') seen.push([args.at(-1).split('/').pop(), notes.map((x) => x.title).join('+'), queue().join('+')]); };
await bk.handle('aviso');
onExec = null;
assert.deepEqual(seen, [['1-1.json', 'uno', '1-1.json+2-1.json'], ['2-1.json', 'uno+dos', '2-1.json']]);
ok('cada aviso se muestra antes de borrar su archivo: si la copia se cierra en el medio, el resto queda en la cola');

// 10: un aviso que llega mientras se muestra la cola no se pierde
notes = [];
put('1-1.json', { title: 'uno', ts: now });
onExec = (cmd) => { if (cmd === 'rm') put('9-1.json', { title: 'tarde', ts: now }); };
await bk.handle('aviso');
onExec = null;
assert.deepEqual([notes.map((x) => x.title), queue()], [['uno'], ['9-1.json']]);
await bk.handle('aviso');
assert.deepEqual([notes.map((x) => x.title), queue()], [['uno', 'tarde'], []]);
ok('uno que llega mientras tanto queda en la cola y sale en la próxima apertura');

// Despacho: este mod se instala con el nombre de cada tecla que no es una vista del hub, más aviso y seguir
// (lib/herdr_install.py). Cada uno de esos nombres tiene su acción; una vista del hub nunca pasa por acá.
const keys = JSON.parse(fs.readFileSync(`${root}/herdr/keys.json`, 'utf8'));
const views = Object.keys(JSON.parse(fs.readFileSync(`${root}/herdr/mods/hub/views.json`, 'utf8')));
const byKey = Object.values(keys).flatMap((b) => Object.values(b))
  .filter((a) => typeof a === 'string' && a.startsWith('mod.open:bk-')).map((a) => a.slice('mod.open:bk-'.length));
const mine = [...new Set([...byKey.filter((c) => !views.includes(c)), 'aviso', 'seguir'])].sort();
let said = [], hcs = [], overlays = [];
const Bk2 = new Function('View', 'div', 'hc', 'exec', 'run', 'props', 'openOverlay', 'closeOverlay', 'focused', 'terminals',
  'spaces', 'agents', 'home', 'notify', 'shared', 'setShared', 'readTextFile', source + '\nreturn Bk;')(
  class {}, () => ({}), async (a) => { hcs.push(a); return { code: 0, stdout: '{"address":"t9"}', stderr: '' }; },
  async () => ({ code: 0, stdout: '', stderr: '' }), () => {}, () => ({}), (o) => { overlays.push(o); return 'o1'; }, () => {},
  () => ({ space: 's1', tab: 'tb1', cwd: '/proj', terminal: 't1' }), () => [], () => [], () => [], () => '/home/yo',
  (x) => said.push(x), () => null, () => {}, async () => null);
const bk2 = new Bk2();
assert.ok(mine.length >= 20 && views.length >= 10, `teclas y vistas leídas: ${mine.length} y ${views.length}`);
for (const c of mine) {
  said = [];
  await bk2.handle(c);
  assert.deepEqual(said.filter((x) => String(x.body).startsWith('comando desconocido')), [], `bk-${c} tiene su acción`);
}
ok(`cada nombre con que se instala el mod tiene su acción (${mine.length}: ${mine.filter((c) => !/\d$/.test(c)).join(', ')}, go1…9, agent1…9)`);
hcs = []; overlays = [];
await bk2.handle('seguir');
assert.ok(hcs.length === 1 && hcs[0].at(-1).includes('bk handoff --seguir'), 'seguir corre bk handoff --seguir en una terminal');
assert.deepEqual([overlays.length, overlays[0]?.width, overlays[0]?.height, overlays[0]?.layout?.content?.terminal], [1, 0.6, 0.3, 't9']);
ok('seguir (el clic de «Resumen listo») abre bk handoff --seguir en un popup sobre la ventana');
hcs = []; overlays = [];
for (const v of views) {
  said = [];
  await bk2.handle(v);
  assert.deepEqual(said.map((x) => x.body), [`comando desconocido: ${v}`], `la vista ${v} es del hub: este mod no le abre un popup`);
}
assert.deepEqual([hcs, overlays], [[], []]);
ok(`las ${views.length} vistas del hub (comandos, cambios, sesiones…) no son popups de terminal de este mod`);

// Aspecto (herdr/mods/hub/look.js): un tema de la otra claridad cambia también la apariencia de settings.json
const lookSrc = fs.readFileSync(`${root}/herdr/mods/hub/look.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Look', 'class Look').replace(/^export /gm, '');
let files = {}, cmds = [], cur = { dark: true, theme_dark: 'bk-neon', theme_light: 'bk-dia' };
const Panel = class { work(cx, label, fn) { this.busy = label; this.pending = fn(cx).catch((e) => { this.error = String(e?.message ?? e); }); } };
const Look = new Function('div', 'h_flex', 'run', 'themes', 'fonts', 'settings', 'layout', 'layouts', 'shared', 'appHome', 'readTextFile',
  'writeTextFile', 'Panel', 'rank', 'lit', 'pill', lookSrc + '\nreturn { Look, withSetting, withFont };')(
  () => ({}), () => ({}), (name, args) => cmds.push([name, args]),
  () => [{ name: 'bk-neon', light: false }, { name: 'bk-pastel', light: false }, { name: 'bk-dia', light: true }], () => [],
  () => cur, () => ({}), () => [], () => 'bk-lavanda', () => '/app',
  async (p) => files[p] ?? null, async (p, text, expected) => { if ((files[p] ?? null) !== expected) throw Error('cambió'); files[p] = text; },
  Panel, () => 0, () => '', () => ({}));
const look = new Look.Look();
const settingsOf = () => JSON.parse(files['/app/settings.json']);
const go = async (name) => { cmds = []; look.said = null; look.pick({ name, light: name === 'bk-dia' }, look.now(), { notify() {} }); await look.pending; };
files['/app/settings.json'] = JSON.stringify({ zoom: 1, appearance: 'dark', font: 'SF Mono' }, null, 2) + '\n';
await go('bk-dia');
assert.deepEqual([settingsOf().appearance, settingsOf().zoom, settingsOf().font, cmds], ['light', 1, 'SF Mono', [['app.theme', { name: 'bk-dia' }]]]);
assert.match(look.said, /bk-dia.*clara/);
ok('Aspecto: elegir bk-dia con la apariencia oscura la pasa a clara (y no toca lo demás de settings.json)');
cur = { dark: false, theme_dark: 'bk-neon', theme_light: 'bk-dia' };
await go('bk-pastel');
assert.deepEqual([settingsOf().appearance, cmds], ['dark', [['app.theme', { name: 'bk-pastel' }]]]);
ok('Aspecto: volver a uno oscuro la pasa a oscura');
cur = { dark: true, theme_dark: 'bk-pastel', theme_light: 'bk-dia' };
const before = files['/app/settings.json'];
await go('bk-neon');
assert.deepEqual([files['/app/settings.json'], cmds, look.said], [before, [['app.theme', { name: 'bk-neon' }]], 'tema: bk-neon']);
ok('Aspecto: un tema de la misma claridad no toca settings.json');
files['/app/settings.json'] = '[1]'; look.error = null;
await go('bk-dia');
assert.deepEqual([files['/app/settings.json'], cmds], ['[1]', []]);
assert.match(look.error, /no toqué settings.json/);
ok('Aspecto: con un settings.json que no es un objeto no lo pisa ni cambia el tema, y lo dice');
assert.equal(Look.withFont('{"a":1}', 'Menlo'), '{\n  "a": 1,\n  "font": "Menlo"\n}\n');
ok('Aspecto: la fuente sigue guardándose igual');

// El menú del clic derecho de bk (herdr/mods/menu → bk-menu)
const menuSrc = fs.readFileSync(`${root}/herdr/mods/menu/main.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Menu', 'class Menu').replace(/^export /gm, '');
let mTerms = [], mPanes = [], mKeys = [], opened = [], mSpaces = [], store = {};
// El modelo de la lista de espacios (espacios.js), que el menú importa de su carpeta
fs.copyFileSync(`${root}/herdr/mods/menu/espacios.js`, `${home}/espacios.mjs`);
const E = await import(`${home}/espacios.mjs`);
const M = new Function('View', 'div', 'svg', 'v_flex', 'h_flex', 'run', 'props', 'closeOverlay', 'openOverlay', 'theme', 'keys',
  'terminals', 'spaces', 'panes', 'exec', 'shared', 'setShared', 'E', menuSrc + '\nreturn { items, height, shortcut, keyParts, openMenu, arrange, WIDTH };')(
  class {}, () => ({}), () => ({}), () => ({}), () => ({}), () => {}, () => ({}), () => {}, (o) => opened.push(o), () => ({}),
  () => mKeys, () => mTerms, () => mSpaces, () => mPanes, async () => ({ code: 1 }), (k) => store[k] ?? null, (k, v) => { store[k] = v; }, E);
mTerms = [{ address: 't1', labels: {} }, { address: 't2', parent: 't1', labels: { 'herdr.right-click': 'program' } }];
mPanes = [{ pane: 'p1' }];
const pane = M.items({ tab: 'pane', target: { pane: 'p1', terminal: 't1' } });
assert.deepEqual(pane.map((x) => x[1]), ['pane.split', 'pane.split', 'pane.zoom', 'terminal.right_click', 'pane.close']);
assert.deepEqual(pane.map((x) => x[0]), ['Dividir a la derecha', 'Dividir abajo', 'Agrandar', 'Clic derecho: al programa', 'Cerrar']);
assert.ok(pane.every((x) => x[2].pane === 'p1' || x[2].terminal === 't1'), 'actúa sobre la terminal del clic');
ok('menú: las opciones de una terminal en una pestaña, en castellano, sobre la terminal del clic');
const sub = M.items({ tab: 'pane', target: { pane: 'bloque', terminal: 't2' } });
assert.deepEqual(sub.map((x) => x[0]), ['Clic derecho: menú de Herdr', 'Devolver a t1']);
ok('menú: una terminal fuera de una pestaña no se divide ni se cierra; un sub-agente se devuelve a su padre');
assert.deepEqual(M.items({ tab: 'space', target: { id: 's' } }, 'linked').map((x) => x[1]), ['space.rename', 'worktree', 'worktree', 'worktree', 'space.close']);
assert.deepEqual(M.items({ tab: 'space', target: { id: 's' } }, null).map((x) => x[1]), ['space.rename', 'space.close']);
assert.deepEqual(M.items({ tab: 'tab', target: { id: 'c', space: 's' } }).map((x) => x[1]), ['tab.rename', 'tab.new', 'tab.close']);
ok('menú: espacio (con los worktrees si es un repo) y pestaña');
assert.equal(M.height(pane), 12 + 5 * 32 + 2 * 9);
assert.equal(JSON.parse(fs.readFileSync(`${root}/herdr/mods/menu/mod.json`, 'utf8')).overlay.height, M.height(pane));
assert.ok(M.WIDTH >= 280 && JSON.parse(fs.readFileSync(`${root}/herdr/mods/menu/mod.json`, 'utf8')).overlay.width === M.WIDTH);
ok('menú: el alto justo para las opciones de una terminal, y ancho para el texto y las teclas');
mKeys = [{ section: 'global', keys: 'cmd-d', action: 'pane.split:right' }, { section: 'global', keys: 'cmd-shift-w', action: 'pane.close' }, { section: 'tab', keys: 'x', action: 'pane.zoom' }];
assert.deepEqual([M.keyParts(M.shortcut('pane.split', { direction: 'right', pane: 'p1' })), M.keyParts(M.shortcut('pane.close', { pane: 'p1' })), M.shortcut('pane.zoom', {})],
  [['⌘', 'D'], ['⌘', '⇧', 'W'], '']);
ok('menú: las teclas en símbolos (⌘ ⇧ D), solo las globales');
M.openMenu('pane', { pane: 'p1', terminal: 't1' });
assert.deepEqual([opened[0].mod, opened[0].width, opened[0].height], ['bk-menu', M.WIDTH, M.height(pane)]);
const lay = JSON.parse(fs.readFileSync(`${root}/herdr/layouts/bk-lavanda.json`, 'utf8'));
const users = ['agentes/lista', 'pestanas/main'].map((m) => fs.readFileSync(`${root}/herdr/mods/${m}.js`, 'utf8'));
assert.deepEqual([lay.terminal_menu, users.map((u) => u.includes('mod: "bk-menu"') && !u.includes('mod: "menu"'))], ['bk-menu', [true, true]]);
ok('menú: el layout, la lista de agentes y las pestañas usan bk-menu, no el de Herdr');

// El menú de la lista de espacios: carpetas, orden, color e imagen (el estado, en shared "bk.espacios")
mSpaces = [{ id: 's', name: 'abra', folder: '/p/abra', machine: null }, { id: 'r', name: 'bk', folder: '/p/bk', machine: null }];
store[E.KEY] = E.sync(E.clean(null), mSpaces);
const draw = () => E.view(E.clean(store[E.KEY]), mSpaces).map((r) => (r.kind === 'carpeta' ? `${r.c.nombre}[${r.filas.map((f) => (f.s ? '' : '~') + f.key).join(' ')}]` : r.key)).join(' ');
const spaceMenu = M.items({ tab: 'space', target: { id: 's' } }, 'main');
assert.deepEqual(spaceMenu.map((x) => x[0]), ['Renombrar', 'Mover a…', 'Color e imagen…', 'Subir', 'Bajar', 'Worktree nuevo', 'Abrir un worktree', 'Cerrar']);
assert.equal(M.height(M.items({ tab: 'space', target: { id: 's' } }, 'linked')), 12 + 9 * 32 + 9);
assert.match(fs.readFileSync(`${root}/herdr/mods/agentes/lista.js`, 'utf8'), /space: 12 \+ 9 \* 32 \+ 9, closed: 12 \+ 3 \* 32 \+ 9, folder: 12 \+ 4 \* 32 \+ 9,/);
ok('menú de un espacio: además de lo de Herdr, moverlo a una carpeta, su color e imagen, subir y bajar');
opened = [];
M.arrange({ op: 'nueva', ref: 'e:abra' });
const fid = Object.keys(store[E.KEY].carpetas)[0];
assert.deepEqual([draw(), opened[0].mod, opened[0].props], ['bk Carpeta nueva[abra]', 'bk-agentes', { editar: `c:${fid}` }]);
ok('"Carpeta nueva…": crea la carpeta con ese espacio adentro y abre su diálogo para nombrarla');
const mover = M.items({ tab: 'mover', target: { key: 'bk' } });
assert.deepEqual(mover.map((x) => x[0]), ['Carpeta nueva', 'Carpeta nueva…']);
assert.deepEqual(M.items({ tab: 'mover', target: { key: 'abra' } }).map((x) => x[0]), ['Carpeta nueva…', 'Sacar de la carpeta']);
opened = [];
M.arrange({ op: 'mover', ref: 'e:bk' });
assert.deepEqual([opened[0].mod, opened[0].height, opened[0].props], ['bk-menu', M.height(mover), { tab: 'mover', target: { key: 'bk' } }]);
M.arrange(mover[0][2]);
assert.equal(draw(), 'Carpeta nueva[abra bk]');
M.arrange({ op: 'subir', ref: 'e:bk' });
assert.equal(draw(), 'Carpeta nueva[bk abra]');
M.arrange({ op: 'sacar', ref: 'e:bk' });
assert.equal(draw(), 'Carpeta nueva[abra] bk');
M.arrange({ op: 'subir', ref: 'e:bk' });
assert.equal(draw(), 'bk Carpeta nueva[abra]');
ok('"Mover a…": lista las otras carpetas y del alto justo; mover, sacar, subir y bajar cambian la lista');
const folderMenu = M.items({ tab: 'folder', target: { id: fid } });
assert.deepEqual(folderMenu.map((x) => x[0]), ['Nombre, color e imagen…', 'Subir', 'Bajar', 'Borrar la carpeta']);
assert.equal(M.height(folderMenu), 12 + 4 * 32 + 9);
mSpaces = mSpaces.filter((x) => x.id !== 's');
store[E.KEY] = E.sync(E.clean(store[E.KEY]), mSpaces);
assert.equal(draw(), 'bk Carpeta nueva[~abra]');
const closedMenu = M.items({ tab: 'closed', target: { key: 'abra' } });
assert.deepEqual([closedMenu.map((x) => x[0]), M.height(closedMenu)], [['Color e imagen…', 'Mover a…', 'Quitar de la lista'], 12 + 3 * 32 + 9]);
M.arrange(closedMenu[2][2]);
assert.equal(draw(), 'bk Carpeta nueva[]');
M.arrange(folderMenu[3][2]);
assert.deepEqual([draw(), store[E.KEY].carpetas], ['bk', {}]);
ok('carpeta y espacio cerrado: sus menús, del alto justo; quitar de la lista y borrar la carpeta');
assert.ok(fs.existsSync(`${root}/herdr/mods/menu/chevron-up.svg`), 'el icono de Subir va con el mod');
console.log(`1..${n}`);
JS
# La lista de agentes (herdr/mods/agentes): la antigüedad de la fila no va en una caja de ancho fijo. En 28 px
# entraba «12m» y «ahora» se partía en dos renglones (2026-11-15).
row=$(grep -c 'ago(now - when)' "$ROOT/herdr/mods/agentes/main.js")
fit=$(grep 'ago(now - when)' "$ROOT/herdr/mods/agentes/main.js" | grep -c 'div()\.flex_none()\.min_w(28)\.whitespace_nowrap()\.text_right()[^()]*(timeColor)\.child(ago(now - when))')
[ "$row $fit" = "1 1" ] || { echo "not ok - agentes: la antigüedad de la fila va en una caja de ancho fijo o se puede partir ($row $fit)"; exit 1; }
echo "ok - agentes: la antigüedad de la fila no se parte (ancho mínimo, sin salto de renglón)"
# La cuenta en la barra y en el panel lado: el mail que dan bk _hub status y bk _side (--account de la terminal)
B="$ROOT/herdr/mods/barra/main.js"; LD="$ROOT/herdr/mods/lado/main.js"
c1=$(grep -c 'when(Boolean(d?.account || d?.email)' "$B"); c2=$(grep -c 'child(d.email)' "$B"); c3=$(grep -c 'svg("mods/bk-barra/cuenta.svg")' "$B")
c4=$(grep -c '...(acct ? \["--account", acct\] : \[\])' "$LD"); c5=$(grep -c 'child(d.email || ' "$LD")
c6=$(ls "$ROOT/herdr/mods/barra/cuenta.svg" "$ROOT/herdr/mods/lado/cuenta.svg" 2>/dev/null | wc -l | tr -d ' ')
[ "$c1$c2$c3$c4$c5$c6" = "111112" ] || { echo "not ok - la cuenta: la barra o el panel lado no muestran el mail ($c1$c2$c3$c4$c5$c6)"; exit 1; }
echo "ok - la cuenta: la barra muestra el mail aunque sea la de siempre, y el panel lado pide el de la cuenta de su terminal"
[ "$(grep -c 'mod.open --name bk-aviso' "$TMP/app.log")" = 3 ] || { echo "not ok - hd_notice no abrió bk-aviso por cada aviso"; exit 1; }
echo "ok - hd_notice abre bk-aviso una vez por aviso"
