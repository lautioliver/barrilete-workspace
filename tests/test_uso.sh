#!/usr/bin/env bash
# El uso de cada computadora en la barra de abajo (herdr/mods/barra/uso.js): CPU y memoria de esta y de las
# otras máquinas conectadas. El modelo corre en node, sin Herdr; la lectura (un sh sin nada que instalar) corre
# de verdad en esta máquina. Lo que no se prueba acá: que Herdr la corra en otra máquina (exec con `on`).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/herdr/mods/barra/uso.js" "$TMP/uso.mjs"

node --input-type=module - "$TMP/uso.mjs" <<'JS'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
const U = await import(process.argv[2]);
let n = 0;
const ok = (what) => console.log(`ok ${++n} - ${what}`);

// 1: la lectura es una línea "cpu_sumada núcleos memoria_total memoria_usada nombre"
assert.deepEqual(U.parse('184.6 8 16000000000 8000000000 mac-de-lu\n'), { cpu: 23, mem: 50, host: 'mac-de-lu' });
assert.deepEqual(U.parse('1200 8 100 100 pc'), { cpu: 100, mem: 100, host: 'pc' }, 'nunca más de 100');
assert.deepEqual(U.parse('0 4 1000 10'), { cpu: 0, mem: 1, host: null }, 'sin nombre también sirve');
for (const bad of ['', 'sin herdr', '12 0 100 50 x', '12 4 0 50 x', 'a b c d e', null, undefined]) assert.equal(U.parse(bad), null, `"${bad}" no es una lectura`);
ok('parse: CPU repartida entre los núcleos y memoria usada, en porcentaje; lo que no se entiende es null');

// 2: la lectura de verdad, en esta máquina
const real = U.parse(execFileSync('sh', ['-c', U.READ], { encoding: 'utf8' }));
assert.ok(real, 'la lectura de esta máquina se entiende');
assert.ok(real.cpu >= 0 && real.cpu <= 100 && real.mem > 0 && real.mem <= 100 && real.host, JSON.stringify(real));
ok(`lectura: corre con sh en esta máquina (${real.host}: CPU ${real.cpu}%, memoria ${real.mem}%)`);

// 3: a quién se le pregunta
const ms = [{ name: null, layout: 'ready' }, { name: 'pc', layout: 'ready' }, { name: 'nas', layout: 'unavailable' }, { name: 'pc', layout: 'ready' }, { name: 'vps', layout: 'loading' }];
assert.deepEqual(U.targets(ms), [null, 'pc', 'vps']);
assert.deepEqual(U.targets([]), [null], 'esta máquina siempre');
ok('máquinas: esta y las conectadas, una vez cada una; a la que no está disponible no se le pregunta');

// 4: lo que se muestra
const now = 1e6;
const read = { '': { cpu: 23, mem: 61, host: 'mac', at: now }, pc: { cpu: 91, mem: 34, host: 'omarchy', at: now }, vps: { cpu: 5, mem: 5, host: 'vps', at: now - U.STALE - 1 } };
assert.deepEqual(U.rows([null, 'pc', 'vps', 'nueva'], read, now), [
  { key: '', name: 'mac', cpu: 23, mem: 61, high: false },
  { key: 'pc', name: 'pc', cpu: 91, mem: 34, high: true },
], 'una lectura vieja o que nunca llegó no se muestra');
assert.equal(U.rows([null], { '': { cpu: 10, mem: U.HIGH, host: null, at: now } }, now)[0].high, true);
assert.equal(U.rows([null], { '': { cpu: 10, mem: 10, host: null, at: now } }, now)[0].name, 'esta', 'sin nombre: "esta"');
assert.deepEqual(['MacBook-Pro-de-Luciano', 'omarchy', 'pc-del-living', 'servidor.casa.lan', 'unnombrelarguisimosincortes'].map(U.short),
  ['MacBook', 'omarchy', 'pc-del-living', 'servidor', 'unnombrelarg…'], 'un nombre largo queda en su primera parte');
ok('filas: esta máquina con su nombre, las otras con el de Herdr, y en rojo la que está al límite');
JS

# La barra lo usa: lee cada máquina con exec `on` y dibuja una pieza por máquina
B="$ROOT/herdr/mods/barra/main.js"
c1=$(grep -c 'from "./uso.js"' "$B"); c2=$(grep -c 'exec("sh", \["-c", U.READ\], { on: m' "$B"); c3=$(grep -c '"b-uso-' "$B")
[ "$c1$c2$c3" = "111" ] || { echo "not ok - la barra no lee o no dibuja el uso de las máquinas ($c1$c2$c3)"; exit 1; }
echo "ok - la barra: pide la lectura en cada máquina y muestra una pieza por cada una"
