#!/usr/bin/env bash
# Los espacios de la barra izquierda en carpetas (herdr/mods/agentes/espacios.js): el modelo corre en node, sin Herdr.
# Es puro: recibe el estado guardado (shared "bk.espacios") y los espacios de Herdr, y devuelve el estado nuevo.
# Después, bk _logo (lib/espacios.py), que copia la imagen de una carpeta o de un espacio adonde Herdr la puede
# mostrar, sobre una carpeta temporal. Lo que no se prueba acá: arrastrar con el mouse dentro de la app.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/herdr/mods/agentes/espacios.js" "$TMP/espacios.mjs"

node --input-type=module - "$TMP/espacios.mjs" <<'JS'
import assert from 'node:assert/strict';
const E = await import(process.argv[2]);
let n = 0;
const ok = (what) => console.log(`ok ${++n} - ${what}`);
const sp = (id, name, extra = {}) => ({ id, name, folder: `/p/${name}`, machine: null, ...extra });
const live = [sp('s1', 'abra'), sp('s2', 'bk'), sp('s3', 'chats')];
// Lo que se ve: las carpetas con sus filas entre corchetes, los cerrados con ~
const draw = (st, spaces) => E.view(st, spaces).map((r) => r.kind === 'carpeta'
  ? `${r.c.nombre}[${r.filas.map((f) => (f.s ? '' : '~') + f.key).join(' ')}]` : (r.s ? '' : '~') + r.key).join(' ');

// 1: sin estado
let st = E.sync(E.clean(null), live);
assert.equal(draw(st, live), 'abra bk chats');
assert.equal(E.sync(st, live), st, 'sin cambios devuelve el mismo objeto (no se guarda de más)');
ok('sin estado: los espacios en el orden de Herdr, todos sueltos');

// 2: crear, renombrar y borrar una carpeta
st = E.createFolder(st, 'c1', 'Abra');
assert.equal(draw(st, live), 'abra bk chats Abra[]');
st = E.move(st, 'e:abra', { dentro: 'c1' });
st = E.move(st, 'e:bk', { dentro: 'c1' });
st = E.move(st, 'c:c1', { antes: 'e:chats' });
assert.equal(draw(st, live), 'Abra[abra bk] chats');
st = E.renameFolder(st, 'c1', '  Trabajo ');
assert.equal(draw(st, live), 'Trabajo[abra bk] chats');
assert.equal(E.renameFolder(st, 'c1', '   '), st, 'un nombre vacío no cambia nada');
const sin = E.removeFolder(st, 'c1');
assert.equal(draw(sin, live), 'abra bk chats');
assert.equal(sin.carpetas.c1, undefined);
ok('carpetas: se crean, se renombran y al borrarlas sus espacios quedan sueltos en ese lugar');

// 3: mover espacios adentro, afuera y entre carpetas; mover una carpeta
st = E.createFolder(st, 'c2', 'Otros');
assert.equal(draw(st, live), 'Trabajo[abra bk] chats Otros[]');
st = E.move(st, 'e:bk', { dentro: 'c2' });
assert.equal(draw(st, live), 'Trabajo[abra] chats Otros[bk]');
st = E.move(st, 'e:chats', { dentro: 'c2', antes: 'e:bk' });
assert.equal(draw(st, live), 'Trabajo[abra] Otros[chats bk]');
st = E.move(st, 'e:chats', { despues: 'c:c1' });
assert.equal(draw(st, live), 'Trabajo[abra] chats Otros[bk]');
st = E.move(st, 'c:c2', { antes: 'c:c1' });
assert.equal(draw(st, live), 'Otros[bk] Trabajo[abra] chats');
assert.equal(E.move(st, 'c:c2', { dentro: 'c1' }), st, 'una carpeta no entra en otra');
assert.equal(E.move(st, 'e:nadie', { dentro: 'c1' }), st, 'lo que no existe no se mueve');
assert.equal(E.move(st, 'e:bk', { antes: 'e:bk' }), st, 'soltar algo sobre sí mismo no cambia nada');
st = E.nudge(st, 'e:chats', -1);
assert.equal(draw(st, live), 'Otros[bk] chats Trabajo[abra]');
st = E.nudge(st, 'e:chats', 1);
assert.equal(draw(st, live), 'Otros[bk] Trabajo[abra] chats');
assert.equal(E.nudge(st, 'e:chats', 1), st, 'el último no baja más');
ok('mover: adentro, afuera, entre carpetas, la carpeta entera, y subir o bajar un lugar');

// 4: un espacio nuevo
const more = [...live, sp('s4', 'abra-fix'), sp('s5', 'suelto')];
st = E.sync(st, more, new Map([['s1', 'abra'], ['s4', 'abra']]));
assert.equal(draw(st, more), 'Otros[bk] Trabajo[abra abra-fix] chats suelto');
ok('espacio nuevo: debajo del espacio de su proyecto (en su carpeta), o suelto al final');

// 5: cerrar y reabrir; renombrar
let open = more.filter((s) => s.id !== 's1' && s.id !== 's4' && s.id !== 's5');
st = E.sync(st, open);
assert.equal(draw(st, open), 'Otros[bk] Trabajo[~abra] chats');
assert.equal(st.espacios['abra-fix'], undefined, 'el que nadie acomodó se olvida al cerrarse');
assert.equal(st.espacios.abra.carpeta, '/p/abra', 'el cerrado recuerda su carpeta, para reabrirlo');
st = E.setLook(st, 'e:abra', { color: 'ansi3', imagen: 'mods/bk-agentes/logos/a.png' });
open = [...open, sp('s9', 'abra')];
st = E.sync(st, open);
assert.equal(draw(st, open), 'Otros[bk] Trabajo[abra] chats');
assert.deepEqual([st.espacios.abra.id, st.espacios.abra.color, st.espacios.abra.imagen], ['s9', 'ansi3', 'mods/bk-agentes/logos/a.png']);
const renamed = open.map((s) => (s.id === 's9' ? sp('s9', 'abra-web') : s));
st = E.sync(st, renamed);
assert.equal(draw(st, renamed), 'Otros[bk] Trabajo[abra-web] chats');
assert.deepEqual([st.espacios.abra, st.espacios['abra-web'].color], [undefined, 'ansi3']);
const gone = E.forget(E.sync(st, renamed.filter((s) => s.id !== 's9')), 'abra-web');
assert.equal(draw(gone, renamed.filter((s) => s.id !== 's9')), 'Otros[bk] Trabajo[] chats');
// suelto y cerrado: no se muestra, pero si lo acomodaste vuelve a su lugar
let loose = E.sync(E.move(st, 'e:chats', { antes: 'c:c2' }), renamed.filter((s) => s.id !== 's3'));
assert.equal(draw(loose, renamed.filter((s) => s.id !== 's3')), 'Otros[bk] Trabajo[abra-web]');
loose = E.sync(loose, [...renamed.filter((s) => s.id !== 's3'), sp('s10', 'chats')]);
assert.equal(draw(loose, [...renamed.filter((s) => s.id !== 's3'), sp('s10', 'chats')]), 'chats Otros[bk] Trabajo[abra-web]');
// otra máquina: su clave lleva la máquina, y cerrado no queda como acceso (bk open abre acá)
const far = [...renamed, sp('pc/s1', 'abra-web', { machine: 'pc' })];
let rem = E.sync(st, far);
assert.equal(draw(rem, far), 'Otros[bk] Trabajo[abra-web] chats abra-web@pc');
rem = E.sync(E.move(rem, 'e:abra-web@pc', { dentro: 'c1' }), renamed);
assert.equal(draw(rem, renamed), 'Otros[bk] Trabajo[abra-web] chats');
ok('cerrado y reabierto conserva lugar, color e imagen; renombrado, también; "quitar de la lista" lo olvida');

// 6: color
st = E.setLook(st, 'c:c1', { color: '#8b5cf6' });
assert.equal(E.colorOf(st, 'abra-web'), 'ansi3');
st = E.setLook(st, 'e:abra-web', { color: null });
assert.equal(E.colorOf(st, 'abra-web'), '#8b5cf6');
assert.equal(E.colorOf(st, 'chats'), null);
assert.equal(E.setLook(st, 'c:c1', { color: 'rojo' }), st, 'un color que no es del tema ni #rrggbb se rechaza');
assert.equal(E.setLook(st, 'c:c1', { color: '#12' }), st);
assert.equal(st.espacios['abra-web'].imagen, 'mods/bk-agentes/logos/a.png', 'cambiar el color no toca la imagen');
assert.equal(E.setLook(st, 'e:abra-web', { imagen: null }).espacios['abra-web'].imagen, null);
ok('color: el espacio hereda el de su carpeta, el propio gana, y uno inválido se rechaza');

// 7: el orden de Herdr sigue al de la lista
const now = [sp('s2', 'bk'), sp('s9', 'abra-web'), sp('s3', 'chats'), sp('pc/a', 'x', { machine: 'pc' }), sp('pc/b', 'y', { machine: 'pc' })];
let ord = E.sync(st, now);
assert.deepEqual(E.target(ord, now), ['s2', 's9', 's3', 'pc/a', 'pc/b']);
assert.deepEqual(E.moves(now.map((s) => s.id), E.target(ord, now)), []);
ord = E.move(E.move(ord, 'e:chats', { antes: 'c:c2' }), 'e:y@pc', { antes: 'e:chats' });
assert.equal(draw(ord, now), 'y@pc chats Otros[bk] Trabajo[abra-web] x@pc');
assert.deepEqual(E.target(ord, now), ['s3', 's2', 's9', 'pc/b', 'pc/a'], 'cada máquina en su bloque, las de acá primero');
const plan = E.moves(now.map((s) => s.id), E.target(ord, now));
assert.deepEqual(plan, [{ id: 's3', index: 1 }, { id: 'pc/b', index: 4 }]);
const applied = now.map((s) => s.id);
for (const m of plan) { applied.splice(applied.indexOf(m.id), 1); applied.splice(m.index - 1, 0, m.id); }
assert.deepEqual(applied, E.target(ord, now));
ok('orden: los space.move justos para que Herdr quede como la lista, por máquina, y ninguno si ya coincide');

// 8: un estado que no se entiende
for (const bad of ['{', 42, [], { v: 99, raiz: ['e:x'] }, { v: 1, raiz: 'no', carpetas: [], espacios: null }]) {
  assert.equal(draw(E.sync(E.clean(bad), live), live), 'abra bk chats');
}
const dirty = E.clean({ v: 1, raiz: ['c:c1', 'c:nada', 'e:abra', 'e:abra', 7], espacios: { abra: { color: 'rojo', fijo: true }, bk: 3 },
  carpetas: { c1: { nombre: 'A', miembros: ['bk', 'abra', 'fantasma'], color: '#zzzzzz' }, c9: { nombre: 'Perdida', miembros: [] } } });
assert.equal(draw(E.sync(dirty, live), live), 'A[bk abra] Perdida[] chats');
assert.deepEqual([dirty.carpetas.c1.color, dirty.espacios.abra.color], [null, null]);
ok('estado roto, de otra versión o a medias: se ignora lo que no sirve y la lista no se rompe');

// 9: las muestras de color son colores válidos
assert.ok(E.COLORS.length >= 6 && E.COLORS.every(E.validColor) && E.validColor('#A1b2C3') && E.validColor(null) && !E.validColor(''));
assert.deepEqual([E.keyOf(sp('a', 'x')), E.keyOf(sp('a', 'x', { machine: 'pc' }))], ['x', 'x@pc']);
ok('colores: las muestras son nombres del tema; además vale #rrggbb, y null es "sin color"');

// 10: varios espacios abiertos con el mismo nombre (dos checkouts del mismo proyecto)
const dup = [sp('m1', 'mobile'), sp('a1', 'app'), sp('m2', 'mobile'), sp('r1', 'mobile', { machine: 'pc' }), sp('r2', 'mobile', { machine: 'pc' })];
let d = E.sync(E.clean(null), dup);
assert.equal(draw(d, dup), 'mobile app mobile#2 mobile@pc mobile#2@pc', 'cada uno con su fila');
assert.equal(E.sync(d, dup), d, 'y el estado queda quieto');
assert.deepEqual(E.target(d, dup), ['m1', 'a1', 'm2', 'r1', 'r2'], 'el orden nombra a todos');
assert.deepEqual(E.moves(dup.map((s) => s.id), E.target(d, dup)), [], 'sin nada que mover no se pide nada');
const turned = [dup[2], dup[1], dup[0], dup[4], dup[3]];
assert.equal(E.sync(d, turned), d, 'Herdr los dio vuelta: cada uno conserva su clave, por su id');
assert.deepEqual([E.keyFor(d, turned, 'm2'), E.keyFor(d, turned, 'r1'), E.keyFor(d, turned, 'nadie')], ['mobile#2', 'mobile@pc', null]);
d = E.move(E.createFolder(d, 'c1', 'Abra'), 'e:mobile#2', { dentro: 'c1' });
assert.equal(draw(d, turned), 'mobile app mobile@pc mobile#2@pc Abra[mobile#2]');
const one = E.sync(d, turned.filter((s) => s.id !== 'm1'));
assert.equal(draw(one, turned.filter((s) => s.id !== 'm1')), 'app mobile@pc mobile#2@pc Abra[mobile#2]', 'cerrar el primero no le cambia la clave al otro');
ok('nombres repetidos: cada espacio tiene su fila y su lugar, y Herdr no queda con movimientos pendientes');
JS

# La lista y el diálogo (herdr/mods/agentes/lista.js y editar.js) con un Herdr falso: cada elemento anota sus
# manejadores por id, y el test hace lo que haría el mouse (apretar en una fila, soltar en otra).
node --input-type=module - "$ROOT" "$TMP/espacios.mjs" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const [root, model] = process.argv.slice(2);
const E = await import(model);
let n = 0;
const ok = (what) => console.log(`ok ui ${++n} - ${what}`);
const src = (f) => fs.readFileSync(`${root}/herdr/mods/agentes/${f}.js`, 'utf8').replace(/^import .*;$/gm, '').replace(/^export /gm, '');
let reg = {}, ran = [], execd = [], opened = [], store = {}, live = [], P = {};
const el = () => {
  const me = { h: {} };
  const p = new Proxy(me, { get: (_, key) => (...a) => {
    if (key === 'id') { me.id = a[0]; reg[a[0]] = me.h; }
    else if (key === 'on_mouse_down' || key === 'on_mouse_up') me.h[`${key}:${a[0]}`] = a[1];
    else if (String(key).startsWith('on_')) me.h[key] = a[0];
    else if (key === 'when' && a[0]) a[1](p);
    return p;
  } });
  return p;
};
globalThis.localStorage = { d: {}, getItem(k) { return this.d[k] ?? null; }, setItem(k, v) { this.d[k] = v; } };
const cx = { notify() {}, stop_propagation() {}, timer: { after() {} }, spawn: (f) => f(cx) };
const shared = (k) => store[k] ?? null, setShared = (k, v) => { store[k] = v; };
const iconButton = (_t, id, _i, action) => el().id(id).on_click(action);
const L = new Function('div', 'svg', 'image', 'v_flex', 'h_flex', 'spaces', 'agents', 'terminals', 'run', 'shared', 'setShared', 'openOverlay',
  'exec', 'notify', 'home', 'checking', 'ICONS', 'RANK', 'al', 'mark', 'iconButton', 'rule', 'E', src('lista') + '\nreturn { Lista, avatar, paint, menu, edit };')(
  el, el, el, el, el, () => live, () => [], () => [], (name, args) => ran.push([name, args]), shared, setShared, (o) => opened.push(o),
  async (...a) => { execd.push(a); return { code: 0, stdout: '', stderr: '' }; }, () => {}, () => '/home/yo', () => false, 'i/', { blocked: 4, done: 3, working: 2, idle: 1 },
  (c) => c, el, iconButton, el, E);
const t = new Proxy({}, { get: (_, k) => `#${String(k)}` });
const sp = (id, name, extra = {}) => ({ id, name, folder: `/p/${name}`, machine: null, branch: null, status: 'idle', active: false, ...extra });
live = [sp('s1', 'abra', { active: true }), sp('s2', 'bk', { status: 'blocked' }), sp('s3', 'chats')];
let st = E.sync(E.clean(null), [...live, sp('s0', 'viejo')]);
st = E.move(E.move(E.createFolder(st, 'c1', 'Trabajo'), 'e:abra', { dentro: 'c1' }), 'e:viejo', { dentro: 'c1' });
store[E.KEY] = st;
const lista = new L.Lista();
const draw = () => { reg = {}; lista.section(t); return E.view(E.clean(store[E.KEY]), live).map((r) => (r.kind === 'carpeta'
  ? `${r.c.nombre}[${r.filas.map((f) => (f.s ? '' : '~') + f.key).join(' ')}]` : r.key)).join(' '); };
const dragTo = (a, b) => { reg[a]['on_mouse_down:left'](); if (a !== b) reg[b].on_mouse_move({}, cx); reg[b]['on_mouse_up:left']({}, cx); };

assert.equal(draw(), 'bk chats Trabajo[abra ~viejo]');
assert.deepEqual(Object.keys(reg).filter((k) => /^(sp|fo)-/.test(k)).sort(), ['fo-c1', 'sp-list', 'sp-s1', 'sp-s2', 'sp-s3', 'sp-x-viejo']);
assert.deepEqual(ran.map((r) => [r[0], r[1].id]), [['space.move', 's2'], ['space.move', 's3']], 'Herdr queda en el orden de la lista');
ok('dibuja los sueltos, la carpeta y, apagado, el cerrado que quedó en ella; y ordena Herdr como la lista');

ran = [];
dragTo('sp-s2', 'fo-c1');
assert.equal(draw(), 'chats Trabajo[abra ~viejo bk]');
dragTo('sp-s3', 'sp-s1');
assert.equal(draw(), 'Trabajo[abra chats ~viejo bk]', 'venía de arriba: queda después de la fila');
assert.ok(!ran.some((r) => r[0] === 'space.select'), 'soltar no es un clic');
dragTo('sp-s1', 'fo-c1');
assert.equal(draw(), 'abra Trabajo[chats ~viejo bk]');
dragTo('fo-c1', 'sp-s1');
assert.equal(draw(), 'Trabajo[chats ~viejo bk] abra');
dragTo('sp-s1', 'sp-s2');
assert.equal(draw(), 'Trabajo[chats ~viejo abra bk]', 'venía de abajo: queda antes de la fila');
ok('arrastrar: a una carpeta, a un lugar dentro de ella, afuera (soltado sobre la suya), y la carpeta entera');

reg['sp-s2']['on_mouse_down:left']();
reg['sp-s1'].on_mouse_move({}, cx);
reg['sp-list']['on_mouse_up:left']({}, cx);
assert.deepEqual([draw(), lista.drag], ['Trabajo[chats ~viejo abra bk]', null]);
ok('soltar fuera de una fila no mueve nada');

ran = [];
dragTo('sp-s3', 'sp-s3');
assert.deepEqual(ran.filter((r) => r[0] === 'space.select'), [['space.select', { id: 's3' }]]);
dragTo('sp-x-viejo', 'sp-x-viejo');
assert.deepEqual(execd[0].slice(0, 2), ['bk', ['_do', '--cwd', '/p/viejo', '--title', 'Abrir viejo', '--', 'open', '/p/viejo']]);
ok('un clic muestra el espacio; en uno cerrado, lo reabre con bk open en su carpeta');

dragTo('fo-c1', 'fo-c1');
draw();
assert.deepEqual(Object.keys(reg).filter((k) => k.startsWith('sp-') && k !== 'sp-list'), ['sp-s1'], 'plegada, queda a la vista solo el espacio que mirás');
assert.equal(JSON.parse(localStorage.getItem('carpetas.plegadas'))[0], 'c1');
reg = {}; lista.railSection(t);
assert.deepEqual(Object.keys(reg).sort(), ['fo-c1', 'sp-s1']);
ok('un clic en la carpeta la pliega (y se recuerda); el riel muestra la carpeta y el espacio que mirás');

opened = [];
reg = {}; lista.section(t);
reg['folder-new'].on_click({}, cx);
const made = Object.keys(store[E.KEY].carpetas).find((k) => k !== 'c1');
assert.deepEqual([store[E.KEY].carpetas[made].nombre, opened[0].mod, opened[0].props], ['Carpeta nueva', 'bk-agentes', { editar: `c:${made}` }]);
reg['sp-s1']['on_mouse_down:right']({}, cx);
reg['fo-c1']['on_mouse_down:right']({}, cx);
assert.deepEqual(opened.slice(1).map((o) => [o.mod, o.props]), [['bk-menu', { tab: 'space', target: { id: 's1' } }], ['bk-menu', { tab: 'folder', target: { id: 'c1' } }]]);
ok('el botón de carpeta nueva la crea y abre su diálogo; el clic derecho abre el menú de bk');

// El diálogo: nombre, color e imagen, aplicados al momento
const inputs = [];
const InputState = { new: (o = {}) => { const i = { v: o.value ?? '', h: {}, on(e, f) { this.h[e] = f; }, value() { return this.v; }, set_value(v) { this.v = v; }, focus() {} }; inputs.push(i); return i; } };
const closed = [];
const Editar = new Function('div', 'svg', 'v_flex', 'h_flex', 'InputState', 'Input', 'shared', 'setShared', 'props', 'closeOverlay', 'exec', 'ICONS', 'E', 'avatar', 'paint',
  src('editar') + '\nreturn Editar;')(el, el, el, el, InputState, { new: el }, shared, setShared, () => P, (o) => closed.push(o),
  async (cmd, args) => (args[1] === '/mal.txt' ? { code: 1, stdout: '', stderr: 'no es una imagen (png, jpg, webp o svg): mal.txt\n' } : { code: 0, stdout: 'mods/bk-agentes/logos/x.png\n', stderr: '' }),
  'i/', E, L.avatar, L.paint);
P = { editar: 'c:c1', overlay: 'o1' };
let d = new Editar(cx);
reg = {}; d.render(t);
const [name, hex, path] = inputs;
assert.equal(name.value(), 'Trabajo');
name.set_value('Laburo'); name.h.change({}, cx);
reg['color-ansi4'].on_click({}, cx);
assert.deepEqual([store[E.KEY].carpetas.c1.nombre, store[E.KEY].carpetas.c1.color], ['Laburo', 'ansi4']);
hex.set_value('#12'); hex.h.change({}, cx);
assert.equal(store[E.KEY].carpetas.c1.color, 'ansi4', 'un hex a medias no cambia nada');
hex.set_value('#8b5cf6'); hex.h.change({}, cx);
assert.equal(store[E.KEY].carpetas.c1.color, '#8b5cf6');
reg['color-none'].on_click({}, cx);
assert.equal(store[E.KEY].carpetas.c1.color, null);
ok('diálogo de una carpeta: el nombre, una muestra, un color exacto y "sin color" se aplican al momento');
path.set_value('/mal.txt'); path.h.submit({}, cx);
await new Promise((r) => setTimeout(r, 5));
assert.deepEqual([d.error, store[E.KEY].carpetas.c1.imagen], ['no es una imagen (png, jpg, webp o svg): mal.txt', null]);
reg = {}; d.render(t);
reg['bk-editar'].on_drop({ paths: ['/tmp/logo.png'] }, cx);
await new Promise((r) => setTimeout(r, 5));
assert.deepEqual([d.error, store[E.KEY].carpetas.c1.imagen], [null, 'mods/bk-agentes/logos/x.png']);
reg = {}; d.render(t);
reg['img-off'].on_click({}, cx);
assert.equal(store[E.KEY].carpetas.c1.imagen, null);
name.h.submit();
assert.deepEqual(closed, ['o1']);
ok('diálogo: la imagen entra por la ruta o soltando el archivo (bk _logo), su error se muestra, y se puede quitar');
inputs.length = 0;
P = { editar: 'e:abra', overlay: 'o2' };
d = new Editar(cx);
reg = {}; d.render(t);
assert.equal(inputs.length, 2, 'un espacio no lleva campo de nombre (se renombra con su menú)');
reg['color-ansi3'].on_click({}, cx);
assert.deepEqual([store[E.KEY].espacios.abra.color, store[E.KEY].espacios.abra.fijo], ['ansi3', true]);
P = { editar: 'e:nadie', overlay: 'o3' };
new Editar(cx).render(t);
ok('diálogo de un espacio: color e imagen; de algo que ya no está, no falla');

// Herdr no deja el orden como se pidió (otra pantalla, un espacio que no se mueve): no se insiste sin fin
live = [sp('s1', 'abra'), sp('s2', 'bk')];
store[E.KEY] = E.move(E.sync(E.clean(null), live), 'e:bk', { antes: 'e:abra' });
const terca = new L.Lista(), now = Date.now;
let clock = 1e6;
Date.now = () => clock;
ran = [];
for (let i = 0; i < 10; i++) { terca.section(t); clock += 5000; }
Date.now = now;
const pedidos = ran.filter((r) => r[0] === 'space.move').length;
assert.ok(pedidos >= 1 && pedidos <= 3, `pidió ${pedidos} veces el mismo orden`);
ok('orden que Herdr no toma: se pide unas pocas veces y se deja, sin bucle');

// Las pantallas conectadas comparten el orden de los espacios y cada una tiene su lista: si las dos lo impusieran
// entero se pisarían sin fin. Cada pantalla ordena solo los espacios de su máquina.
live = [sp('s1', 'abra'), sp('s2', 'bk'), sp('pc/a', 'x', { machine: 'pc' }), sp('pc/b', 'y', { machine: 'pc' })];
store[E.KEY] = E.move(E.move(E.sync(E.clean(null), live), 'e:bk', { antes: 'e:abra' }), 'e:y@pc', { antes: 'e:x@pc' });
ran = [];
new L.Lista().section(t);
assert.deepEqual(ran.filter((r) => r[0] === 'space.move').map((r) => r[1]), [{ id: 's2', index: 1 }], 'los de otra máquina no se tocan');
ok('orden: solo se mueven en Herdr los espacios de esta máquina');

// Otra pantalla (con otra lista) devuelve el orden cada vez que Herdr lo toma: tampoco ahí se insiste sin fin
const base = [sp('s1', 'abra'), sp('s2', 'bk'), sp('s3', 'chats')];
live = [...base];
store[E.KEY] = E.move(E.sync(E.clean(null), live), 'e:chats', { antes: 'e:abra' });
const pelea = new L.Lista();
let vueltas = 0;
clock = 2e6; Date.now = () => clock;
for (let i = 0; i < 10; i++) {
  ran = [];
  pelea.section(t);
  const plan = ran.filter((r) => r[0] === 'space.move');
  if (plan.length) vueltas++;
  for (const [, m] of plan) { const at = live.findIndex((x) => x.id === m.id); live.splice(m.index - 1, 0, live.splice(at, 1)[0]); }
  clock += 5000; pelea.section(t);          // Herdr lo tomó, la barra lo ve aplicado…
  live = [...base]; clock += 5000;          // …y la otra pantalla lo devuelve
}
assert.ok(vueltas >= 1 && vueltas <= 3, `peleó ${vueltas} vueltas`);
// Si la lista cambia (la persona mueve algo), se vuelve a pedir
store[E.KEY] = E.move(E.clean(store[E.KEY]), 'e:bk', { antes: 'e:chats' });
ran = []; pelea.section(t);
Date.now = now;
assert.ok(ran.some((r) => r[0] === 'space.move'), 'un orden nuevo sí se pide');
ok('orden que otra pantalla devuelve: se pide unas pocas veces y se deja, hasta que la lista cambie');
JS

# bk _logo: la imagen va a mods/bk-agentes/logos/<hash>.<ext> de la carpeta de Herdr y dice la ruta relativa
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok logo $N - $3"; else echo "not ok logo $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
APP="$TMP/herdr-app"; mkdir -p "$APP" "$TMP/img dir" "$TMP/home"
is_logo() { case "$1" in mods/bk-agentes/logos/*."$2") echo si ;; *) echo "no: $1" ;; esac; }
fails() { local out rc=0; out=$(logo "$@" 2>&1 >/dev/null) || rc=$?; echo "$out $rc"; }   # lo que dice por stderr y con qué sale
logo() { HERDR_APP_HOME="$APP" python3 "$ROOT/lib/espacios.py" logo "$@"; }
printf '\x89PNG\r\n\x1a\n0000' >"$TMP/img dir/a.png"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$TMP/img dir/b.SVG"
printf 'hola' >"$TMP/img dir/c.txt"
printf 'hola' >"$TMP/img dir/falsa.png"
out=$(logo "$TMP/img dir/a.png")
check_eq "$(is_logo "$out" png) $(cmp -s "$TMP/img dir/a.png" "$APP/$out" && echo igual)" "si igual" "copia la imagen y dice la ruta que entiende image()"
check_eq "$(logo "$TMP/img dir/a.png") $(ls "$APP/mods/bk-agentes/logos" | wc -l | tr -d ' ')" "$out 1" "la misma imagen dos veces: la misma ruta, una sola copia"
out2=$(logo "file://$TMP/img%20dir/b.SVG")
check_eq "$(is_logo "$out2" svg)" "si" "acepta svg, la extensión en mayúsculas y una ruta file:// (lo que pega Finder)"
check_eq "$(fails "$TMP/img dir/c.txt")" "no es una imagen (png, jpg, webp o svg): c.txt 1" "lo que no es una imagen se rechaza, y se dice"
check_eq "$(logo "$TMP/img dir/falsa.png" 2>/dev/null; echo $?)" "1" "un .png que no es un png se rechaza"
check_eq "$(fails "$TMP/no-esta.png")" "no encuentro no-esta.png 1" "un archivo que no está: se dice"
head -c 1100000 /dev/zero | cat "$TMP/img dir/a.png" - >"$TMP/grande.png"
check_eq "$(fails "$TMP/grande.png") $(ls "$APP/mods/bk-agentes/logos" | wc -l | tr -d ' ')" "la imagen pesa más de 1 MB: grande.png 1 2" "una imagen de más de 1 MB se rechaza y no deja restos"
check_eq "$(HOME="$TMP/home" BK_BACKEND=herdr HERDR_APP_HOME="$APP" "$ROOT/bin/bk" _logo "$TMP/img dir/a.png")" "$out" "bk _logo es ese comando"

# El menú del clic derecho lleva su copia del modelo (un mod no importa de otra carpeta)
check_eq "$(cmp -s "$ROOT/herdr/mods/agentes/espacios.js" "$ROOT/herdr/mods/menu/espacios.js" && echo igual)" "igual" "espacios.js: la copia del menú es el mismo archivo que la de la barra"
[ "$FAILED" -eq 0 ] || exit 1
