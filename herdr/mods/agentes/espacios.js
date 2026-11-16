// Los espacios de la barra izquierda en carpetas: el orden, las carpetas y el color y la imagen de cada cosa.
// Es el modelo solo, sin dibujo ni Herdr: funciones que reciben el estado y devuelven el nuevo (o el mismo
// objeto si no cambió nada, para no guardar de más). El estado vive en shared("bk.espacios"):
//   { v: 1,
//     raiz: ["c:<id>", "e:<clave>", …],                 lo que se ve arriba de todo, en orden
//     carpetas: { <id>: { nombre, color, imagen, miembros: [<clave>, …] } },
//     espacios: { <clave>: { color, imagen, carpeta, id, maquina, fijo } } }
// Una referencia es "c:<id>" (una carpeta) o "e:<clave>" (un espacio). La clave de un espacio es su nombre
// (nombre@máquina en otra máquina), no su id: bk abre siempre el mismo nombre para un proyecto, así que cerrarlo
// y reabrirlo conserva su lugar. Con varios abiertos del mismo nombre, los demás son nombre#2, nombre#3… (keysOf). `fijo`: lo acomodaste vos (lo moviste o le pusiste color o imagen); los demás
// se olvidan al cerrarse. Un espacio cerrado y fijo sigue en su carpeta, apagado, para reabrirlo con un clic.
// Va igual en agentes y en menu (un mod de Herdr no puede importar de otra carpeta): si lo cambiás, copialo.

export const VERSION = 1;
export const KEY = "bk.espacios";
// Las muestras: nombres del tema, para que el color acompañe al tema que elijas
export const COLORS = ["ansi5", "ansi4", "ansi6", "ansi2", "ansi3", "ansi1", "ansi13", "accent"];

export const validColor = (c) => c === null || COLORS.includes(c) || /^#[0-9a-fA-F]{6}$/.test(typeof c === "string" ? c : "");
export const keyOf = (s) => (s.machine ? `${s.name}@${s.machine}` : s.name);
// La clave número n de un espacio entre los que se llaman igual: nombre, nombre#2, nombre#3…
const nth = (s, n) => (n === 1 ? keyOf(s) : `${s.name}#${n}${s.machine ? `@${s.machine}` : ""}`);
export const empty = () => ({ v: VERSION, raiz: [], carpetas: {}, espacios: {} });

const isObj = (x) => Boolean(x) && typeof x === "object" && !Array.isArray(x);
const str = (x) => (typeof x === "string" && x ? x : null);
const copy = (st) => JSON.parse(JSON.stringify(st));
const entry = (e = {}) => ({
  color: validColor(e.color ?? null) ? e.color ?? null : null, imagen: str(e.imagen), carpeta: str(e.carpeta),
  id: str(e.id), maquina: str(e.maquina), fijo: e.fijo === true,
});

// El estado guardado, o uno vacío si no se entiende (otra versión, JSON roto). De uno a medias queda lo que sirve:
// cada cosa en un solo lugar (el primero donde aparece) y nada que apunte a algo que no está.
export function clean(raw) {
  if (typeof raw === "string") { try { raw = JSON.parse(raw); } catch { return empty(); } }
  if (!isObj(raw) || raw.v !== VERSION) return empty();
  const out = empty();
  const seen = new Set();
  const take = (key) => {
    if (typeof key !== "string" || !key || seen.has(key)) return false;
    seen.add(key);
    out.espacios[key] = entry(isObj(raw.espacios) && isObj(raw.espacios[key]) ? raw.espacios[key] : {});
    return true;
  };
  const folders = isObj(raw.carpetas) ? raw.carpetas : {};
  const folder = (id) => {
    const c = folders[id];
    if (!isObj(c) || out.carpetas[id]) return false;
    out.carpetas[id] = { nombre: str(c.nombre) ?? "Carpeta", color: validColor(c.color ?? null) ? c.color ?? null : null,
      imagen: str(c.imagen), miembros: (Array.isArray(c.miembros) ? c.miembros : []).filter(take) };
    return true;
  };
  for (const ref of Array.isArray(raw.raiz) ? raw.raiz : []) {
    if (typeof ref !== "string") continue;
    if (ref.startsWith("c:") ? folder(ref.slice(2)) : ref.startsWith("e:") && take(ref.slice(2))) out.raiz.push(ref);
  }
  for (const id of Object.keys(folders)) if (folder(id)) out.raiz.push(`c:${id}`);   // una carpeta que no estaba en la lista
  for (const key of Object.keys(isObj(raw.espacios) ? raw.espacios : {})) if (take(key)) out.raiz.push(`e:${key}`);
  return out;
}

// Dónde está una referencia: la lista que la tiene (la raíz o los miembros de una carpeta), su lugar y su carpeta
function where(st, ref) {
  const at = st.raiz.indexOf(ref);
  if (at !== -1) return { list: st.raiz, i: at, dentro: null, item: ref };
  if (!ref.startsWith("e:")) return null;
  const key = ref.slice(2);
  for (const [id, c] of Object.entries(st.carpetas)) {
    const i = c.miembros.indexOf(key);
    if (i !== -1) return { list: c.miembros, i, dentro: id, item: key };
  }
  return null;
}
// La clave de cada espacio abierto (clave → espacio). Entre varios con el mismo nombre, el que el estado ya conoce
// por su id conserva la suya (aunque Herdr los dé vuelta o se cierre otro) y los demás toman la primera libre.
export function keysOf(st, spaces) {
  const out = new Map(), rest = [];
  for (const s of spaces) {
    let key = null;
    for (let n = 1; n <= spaces.length && !key; n++) { const k = nth(s, n); if (st.espacios[k]?.id === s.id && !out.has(k)) key = k; }
    key ? out.set(key, s) : rest.push(s);
  }
  for (const s of rest) { let n = 1; while (out.has(nth(s, n))) n++; out.set(nth(s, n), s); }
  // en el orden de Herdr, que es el de los espacios nuevos
  const at = new Map(spaces.map((s, i) => [s, i]));
  return new Map([...out].sort((a, b) => at.get(a[1]) - at.get(b[1])));
}
// La clave de un espacio abierto, por su id (null si no está)
export const keyFor = (st, spaces, id) => [...keysOf(st, spaces)].find(([, s]) => s.id === id)?.[0] ?? null;

export const folderOf = (st, key) => where(st, `e:${key}`)?.dentro ?? null;

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const done = (st, next) => (same(st, next) ? st : next);

// El estado al día con los espacios que hay: los nuevos toman su lugar, un renombrado conserva el suyo, y los
// cerrados que nadie acomodó se olvidan. `projects`: id del espacio → su proyecto de bk (etiqueta bk.project).
export function sync(st, spaces, projects = new Map()) {
  const next = copy(st);
  const live = keysOf(st, spaces);
  // El mismo id con otro nombre es un renombre: la clave vieja pasa a la nueva, en su lugar
  for (const [key, s] of live) {
    if (next.espacios[key]) continue;
    const old = Object.keys(next.espacios).find((k) => next.espacios[k].id === s.id && !live.has(k));
    if (!old) continue;
    const at = where(next, `e:${old}`);
    at.list[at.i] = at.dentro ? key : `e:${key}`;
    next.espacios[key] = next.espacios[old];
    delete next.espacios[old];
  }
  const projectOf = (key) => (live.has(key) ? projects.get(live.get(key).id) : null) ?? null;
  for (const [key, s] of live) {
    if (!next.espacios[key]) {
      next.espacios[key] = entry();
      // Debajo del espacio de su proyecto (el que se llama como él, o cualquier otro suyo) y de los que ya lo siguen
      const p = projects.get(s.id);
      const anchor = p && (p !== key && next.espacios[p] ? p : Object.keys(next.espacios).find((k) => k !== key && projectOf(k) === p));
      const at = anchor ? where(next, `e:${anchor}`) : null;
      if (at) {
        const mine = (item) => { const k = at.dentro ? item : item.startsWith("e:") ? item.slice(2) : null; return k !== null && (k === p || projectOf(k) === p); };
        let i = at.i;
        while (i + 1 < at.list.length && mine(at.list[i + 1])) i++;
        at.list.splice(i + 1, 0, at.dentro ? key : `e:${key}`);
      } else next.raiz.push(`e:${key}`);
    }
    const e = next.espacios[key];
    e.id = s.id;
    e.carpeta = s.folder || e.carpeta;
    e.maquina = s.machine ?? null;
  }
  for (const key of Object.keys(next.espacios)) {
    if (live.has(key) || next.espacios[key].fijo) continue;
    const at = where(next, `e:${key}`);
    if (at) at.list.splice(at.i, 1);
    delete next.espacios[key];
  }
  return done(st, next);
}

// Lo que se dibuja, de arriba abajo: { kind: "carpeta", id, c, filas: [{ key, s, e }] } o { kind: "espacio", key, s, e }.
// `s` es el espacio de Herdr, null si está cerrado. Un cerrado se ve solo dentro de una carpeta y si es de esta
// máquina (reabrirlo es `bk open`, que abre acá).
export function view(st, spaces) {
  const live = keysOf(st, spaces);
  const placed = new Set();
  const row = (key) => { placed.add(key); return { key, s: live.get(key) ?? null, e: st.espacios[key] ?? entry() }; };
  const out = [];
  for (const ref of st.raiz) {
    if (ref.startsWith("c:")) {
      const id = ref.slice(2), c = st.carpetas[id];
      if (c) out.push({ kind: "carpeta", id, c, filas: c.miembros.map(row).filter((f) => f.s || (f.e.fijo && !f.e.maquina)) });
    } else {
      const f = row(ref.slice(2));
      if (f.s) out.push({ kind: "espacio", ...f });
    }
  }
  // Uno que el estado todavía no conoce (se abrió recién): al final, suelto
  for (const [key, s] of live) if (!placed.has(key)) out.push({ kind: "espacio", key, s, e: entry() });
  return out;
}

export function createFolder(st, id, nombre) {
  if (!id || st.carpetas[id]) return st;
  const next = copy(st);
  next.carpetas[id] = { nombre: String(nombre ?? "").trim() || "Carpeta", color: null, imagen: null, miembros: [] };
  next.raiz.push(`c:${id}`);
  return next;
}

export function renameFolder(st, id, nombre) {
  const name = String(nombre ?? "").trim();
  if (!st.carpetas[id] || !name || st.carpetas[id].nombre === name) return st;
  const next = copy(st);
  next.carpetas[id].nombre = name;
  return next;
}

// Borrar una carpeta no cierra nada: sus espacios quedan sueltos donde estaba ella
export function removeFolder(st, id) {
  const i = st.raiz.indexOf(`c:${id}`);
  if (!st.carpetas[id] || i === -1) return st;
  const next = copy(st);
  next.raiz.splice(i, 1, ...next.carpetas[id].miembros.map((k) => `e:${k}`));
  delete next.carpetas[id];
  return next;
}

const target_ = (st, ref) => (ref.startsWith("c:") ? st.carpetas[ref.slice(2)] : st.espacios[ref.slice(2)]);

// El color y la imagen de una carpeta o de un espacio: look trae `color`, `imagen` o los dos; null los saca
export function setLook(st, ref, look) {
  if (!target_(st, ref) || ("color" in look && !validColor(look.color))) return st;
  const next = copy(st);
  const x = target_(next, ref);
  if ("color" in look) x.color = look.color;
  if ("imagen" in look) x.imagen = str(look.imagen);
  if (ref.startsWith("e:")) x.fijo = true;
  return done(st, next);
}

// El color de un espacio: el suyo o, si no eligió, el de su carpeta. null: ninguno (la barra le da uno fijo).
export function colorOf(st, key) {
  const dentro = folderOf(st, key);
  return st.espacios[key]?.color ?? (dentro ? st.carpetas[dentro].color : null) ?? null;
}

// Mover una carpeta o un espacio. dest: { dentro: <carpeta> } al final de esa carpeta; { antes | despues: <ref> }
// junto a eso, donde esté (con `dentro`, en esa carpeta); {} al final, suelto. Una carpeta no entra en otra:
// soltada sobre un espacio de una carpeta, queda junto a esa carpeta.
export function move(st, ref, dest = {}) {
  if (!target_(st, ref) || !where(st, ref)) return st;
  const folder = ref.startsWith("c:");
  let side = dest.antes ? "antes" : dest.despues ? "despues" : null;
  let anchor = side ? dest[side] : null;
  if (anchor === ref || (dest.dentro && (folder || !st.carpetas[dest.dentro]))) return st;
  if (anchor && !where(st, anchor)) return st;
  const next = copy(st);
  if (anchor && folder && where(next, anchor).dentro) anchor = `c:${where(next, anchor).dentro}`;
  if (anchor === ref) return st;
  const from = where(next, ref);
  from.list.splice(from.i, 1);
  const key = ref.slice(2);
  const at = anchor ? where(next, anchor) : null;
  const dentro = dest.dentro ?? at?.dentro ?? null;
  const list = dentro ? next.carpetas[dentro].miembros : next.raiz;
  const i = at && at.dentro === dentro ? at.i + (side === "despues" ? 1 : 0) : list.length;
  list.splice(i, 0, dentro ? key : ref);
  if (!folder) next.espacios[key].fijo = true;
  return done(st, next);
}

// Un lugar arriba (-1) o abajo (1) entre sus vecinos. `shown(ref)`: cuáles se ven (salta los que no).
export function nudge(st, ref, dir, shown = () => true) {
  const at = where(st, ref);
  if (!at) return st;
  const asRef = (item) => (at.dentro ? `e:${item}` : item);
  let j = at.i + dir;
  while (j >= 0 && j < at.list.length && !shown(asRef(at.list[j]))) j += dir;
  if (j < 0 || j >= at.list.length) return st;
  return move(st, ref, { [dir < 0 ? "antes" : "despues"]: asRef(at.list[j]) });
}

// "Quitar de la lista": olvidar un espacio (el cerrado que quedó en su carpeta). Abierto, vuelve como uno nuevo.
export function forget(st, key) {
  const at = where(st, `e:${key}`);
  if (!st.espacios[key]) return st;
  const next = copy(st);
  if (at) where(next, `e:${key}`).list.splice(at.i, 1);
  delete next.espacios[key];
  return next;
}

// Los ids de los espacios abiertos en el orden de la lista, cada máquina en su bloque (Herdr pone primero los de
// esta y no deja sacar un espacio del bloque de su máquina).
export function target(st, spaces) {
  const blocks = [...new Set(spaces.map((s) => s.machine ?? null))];
  const ids = view(st, spaces).flatMap((r) => (r.kind === "carpeta" ? r.filas : [r])).filter((f) => f.s).map((f) => f.s);
  return blocks.flatMap((m) => ids.filter((s) => (s.machine ?? null) === m).map((s) => s.id));
}

// Los space.move {id, index} (index desde 1) que llevan `order` a `want`, cada uno contando los anteriores
export function moves(order, want) {
  const now = [...order], out = [];
  for (let i = 0; i < want.length; i++) {
    const from = now.indexOf(want[i]);
    if (from === i || from === -1) continue;
    out.push({ id: want[i], index: i + 1 });
    now.splice(i, 0, now.splice(from, 1)[0]);
  }
  return out;
}
