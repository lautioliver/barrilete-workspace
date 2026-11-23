// alt+/: la hoja de atajos. Lee keys.json (keys()) y dice qué hace cada tecla con palabras, agrupado. Las que
// son la misma cosa con otro número o dirección (⌥1…9, ⌘⌥←↑↓→) van en una sola fila. Enter hace lo que dice
// la fila (las de número o dirección preguntan cuál). send: y terminal (teclas que van al programa) no se muestran.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { keys, commands, run, shared, props, notify } from "herdr";
import { Panel, rank, chips, lit } from "./kit.js";

const INICIO = "Para empezar", KIT = "Agentes del kit", CHATS = "Chats", IR = "Ir", VER = "Ver", VENTANA = "Ventana y panes", TERMINAL = "Terminal";
const GROUPS = [INICIO, KIT, CHATS, IR, VER, VENTANA, TERMINAL];

// acción de keys.json → [grupo, qué hace]. El orden de acá es el orden dentro de cada grupo.
const NAMES = {
  "mod.open:bk-palette": [INICIO, "Comandos: todo lo que hace bk"],
  "mod.open:bk-keys": [INICIO, "Esta hoja"],
  "mod.open:bk-issues": [KIT, "Implementar un issue"],
  "mod.open:bk-prs": [KIT, "Revisar o corregir un PR"],
  "mod.open:bk-tasks": [KIT, "Te esperan: tareas y aprobaciones"],
  "mod.open:bk-agents": [KIT, "Agentes: ver, escribirles, cerrar"],
  "mod.open:bk-next": [KIT, "Ir al que te espera"],
  "mod.open:bk-epica": [KIT, "La épica de este chat: sub-issues, bloqueos y lanzar"],
  "mod.open:bk-todo": [KIT, "TODO del panel derecho: los pasos del issue de este chat"],
  "mod.open:bk-chat": [CHATS, "Chat nuevo en este proyecto"],
  "mod.open:bk-new": [CHATS, "Nuevo… (rama, suelto, otro proyecto)"],
  "mod.open:bk-sessions": [CHATS, "Sesiones: saltar o retomar"],
  "mod.open:bk-handoff": [CHATS, "Resumen y seguir en un chat nuevo"],
  "mod.open:bk-back": [CHATS, "Volver al chat del espacio"],
  "mod.open:bk-last": [CHATS, "Volver a donde estabas"],
  "mod.open:picker": [IR, "Ir a un espacio o pestaña…"],
  "tab.next": [IR, "Pestaña siguiente"],
  "tab.prev": [IR, "Pestaña anterior"],
  "space.next": [IR, "Espacio siguiente"],
  "space.prev": [IR, "Espacio anterior"],
  "agent.next": [IR, "Agente siguiente de la lista"],
  "agent.prev": [IR, "Agente anterior de la lista"],
  "mod.open:bk-cambios": [VER, "Cambios del panel derecho: lo sin commitear y su diff"],
  "mod.open:bk-branches": [VER, "Ramas de todos los proyectos"],
  "mod.open:bk-stats": [VER, "Uso y costo"],
  "mod.open:bk-term": [VER, "Terminal rápida"],
  "mod.open:bk-ayuda": [VER, "Piola: el ayudante del workspace (Codex)"],
  "mod.open:bk-song": [VER, "Radio"],
  "mod.open:bk-look": [VER, "Aspecto"],
  "layout.toggle:sidebar": [VER, "Mostrar u ocultar la barra izquierda"],
  "layout.toggle:lado": [VER, "Mostrar u ocultar el panel derecho"],
  "layout.switch": [VER, "Siguiente layout"],
  "app.zoom_in": [VER, "Agrandar todo"],
  "app.zoom_out": [VER, "Achicar todo"],
  "app.zoom_reset": [VER, "Tamaño normal"],
  "app.palette": [VER, "Comandos de Herdr"],
  "app.settings": [VER, "Ajustes de Herdr"],
  "app.help": [VER, "Teclas de Herdr"],
  "tab.new": [VENTANA, "Pestaña nueva"],
  "tab.close": [VENTANA, "Cerrar esta pestaña"],
  "tab.rename": [VENTANA, "Renombrar esta pestaña"],
  "space.new": [VENTANA, "Espacio nuevo"],
  "space.rename": [VENTANA, "Renombrar este espacio"],
  "space.close": [VENTANA, "Cerrar este espacio"],
  "pane.split:right": [VENTANA, "Dividir a la derecha"],
  "pane.split:down": [VENTANA, "Dividir abajo"],
  "pane.zoom": [VENTANA, "Agrandar este pane"],
  "pane.close": [VENTANA, "Cerrar este pane"],
  "window.minimize": [VENTANA, "Minimizar la ventana"],
  "window.maximize": [VENTANA, "Maximizar la ventana"],
  "window.close": [VENTANA, "Cerrar la ventana"],
  "app.hide": [VENTANA, "Ocultar Herdr"],
  "app.hide_others": [VENTANA, "Ocultar las otras apps"],
  "app.show_all": [VENTANA, "Mostrar todas las apps"],
  "app.quit": [VENTANA, "Salir de Herdr"],
  "app.reset": [VENTANA, "Salida de emergencia: volver al layout de Herdr"],
  "terminal.search": [TERMINAL, "Buscar en la terminal"],
  "terminal.copy": [TERMINAL, "Copiar"],
  "terminal.paste": [TERMINAL, "Pegar"],
  "terminal.paste_image": [TERMINAL, "Pegar una imagen"],
};
const ORDER = Object.keys(NAMES);

const DIGIT = { ask: "¿Cuál? Un número del 1 al 9.", parse: (s) => (/^[1-9]$/.test(s.trim()) ? s.trim() : null) };
const WAYS = { left: ["izquierda", "izq", "i", "left", "←"], right: ["derecha", "der", "d", "right", "→"], up: ["arriba", "a", "up", "↑"], down: ["abajo", "b", "down", "↓"] };
const WAY = { ask: "¿Hacia dónde? izquierda, derecha, arriba o abajo (o i, d, a, b).", parse: (s) => Object.keys(WAYS).find((w) => WAYS[w].includes(s.trim().toLowerCase())) ?? null };
const ARROW = { left: "←", right: "→", up: "↑", down: "↓" };

// Muchas teclas, una sola fila: la acción cambia solo en el número o la dirección. after: detrás de qué acción va.
const FAMILIES = [
  { re: /^mod\.open:bk-go([1-9])$/, group: IR, title: "Ir a la ventana N", label: "ventana", after: "mod.open:bk-last", make: (v) => `mod.open:bk-go${v}`, ...DIGIT },
  { re: /^mod\.open:bk-agent([1-9])$/, group: IR, title: "Agente N de este espacio", label: "agente", after: "mod.open:bk-last", make: (v) => `mod.open:bk-agent${v}`, ...DIGIT },
  { re: /^space\.select:([1-9])$/, group: IR, title: "Espacio N", label: "espacio", after: "mod.open:bk-last", make: (v) => `space.select:${v}`, ...DIGIT },
  { re: /^tab\.select:([1-9])$/, group: IR, title: "Pestaña N", label: "pestaña", after: "mod.open:bk-last", make: (v) => `tab.select:${v}`, ...DIGIT },
  { re: /^pane\.go:(left|right|up|down)$/, group: IR, title: "Pasar al pane de al lado", label: "pane", after: "agent.prev", make: (v) => `pane.go:${v}`, ...WAY },
  { re: /^pane\.swap:(left|right|up|down)$/, group: VENTANA, title: "Cambiar este pane de lugar con el de al lado", label: "mover", after: "pane.close", make: (v) => `pane.swap:${v}`, ...WAY },
];

// Lo que no se hace desde la hoja con un Enter de más: cierra la ventana entera
const NO_RUN = new Set(["app.quit", "app.reset", "window.close"]);
const NUMERIC = new Set(["index", "px", "weight", "lines", "pages"]);

// Una acción que no está en la tabla: su nombre, con espacios ("tab.settle" → "tab settle", "mod.open:x" → "Abrir x")
export function derived(action) {
  const i = action.indexOf(":");
  const name = i < 0 ? action : action.slice(0, i), arg = i < 0 ? "" : action.slice(i + 1);
  if (name === "mod.open") return `Abrir ${arg}`;
  const words = name.replace(/[._]/g, " ");
  return arg ? `${words} ${arg}` : words;
}

function groupOf(action, section) {
  if (section === "terminal" || /^terminal\./.test(action)) return TERMINAL;
  if (/^(agent\.|(space|tab)\.(next|prev|select))/.test(action)) return IR;
  if (/^(layout\.|mod\.open:)/.test(action)) return VER;
  return VENTANA;
}

// "cmd-alt-left" → ["cmd-alt", "left"]; "cmd--" → ["cmd", "-"]
function splitKey(k) {
  if (k.endsWith("--")) return [k.slice(0, -2), "-"];
  const i = k.lastIndexOf("-");
  return i < 0 ? ["", k] : [k.slice(0, i), k.slice(i + 1)];
}

// Las variantes de una familia en una tecla: ["1","2",…,"9"] → "1…9"; direcciones → "←↑↓→"
function span(parts) {
  if (parts.every((p) => /^\d$/.test(p))) {
    const n = [...new Set(parts)].sort();
    return n.length > 2 && Number(n[n.length - 1]) - Number(n[0]) === n.length - 1 ? `${n[0]}…${n[n.length - 1]}` : n.join(" ");
  }
  return ["left", "up", "down", "right"].filter((d) => parts.includes(d)).map((d) => ARROW[d]).join("") || parts.join(" ");
}

// keys() → filas: una por acción (con todas sus teclas) o por familia
export function entries(binds, layoutName) {
  const out = new Map();
  for (const b of binds) {
    const action = typeof b.action === "string" ? b.action : b.action?.command ?? "";
    if (!action || action === "terminal" || action.startsWith("send:")) continue;
    if (b.section.startsWith("layout:") && b.section !== `layout:${layoutName}`) continue;
    const fam = FAMILIES.find((f) => f.re.test(action));
    const where = b.section === "global" || b.section === "terminal" || b.section.startsWith("layout:") ? "" : b.section.replace(/^mod:/, "");
    const id = fam ? `fam:${fam.title}` : `${b.section === "terminal" ? "t:" : ""}${action}`;
    if (!out.has(id)) {
      const [group, title] = fam ? [fam.group, fam.title] : (NAMES[action] ?? [groupOf(action, b.section), derived(action)]);
      out.set(id, { id, group, title, fam: fam ?? null, action, args: typeof b.action === "string" ? null : (b.action?.args ?? {}), where, binds: [] });
    }
    out.get(id).binds.push(b.keys);
  }
  for (const e of out.values()) {
    if (!e.fam) { e.keys = e.binds.slice(0, 2); continue; }
    // por prefijo (⌥, ⌃…): cada uno es una forma de apretarla
    const by = new Map();
    for (const k of e.binds) {
      const [pre, last] = splitKey(k);
      by.set(pre, [...(by.get(pre) ?? []), last]);
    }
    e.keys = [...by].slice(0, 2).map(([pre, lasts]) => `${pre ? `${pre}-` : ""}${span(lasts)}`);
  }
  const at = (e) => (e.fam ? ORDER.indexOf(e.fam.after) + (FAMILIES.indexOf(e.fam) + 1) / 10 : ORDER.includes(e.action) ? ORDER.indexOf(e.action) : ORDER.length);
  return [...out.values()].sort((a, b) => at(a) - at(b));
}

// "tab.select:3" → ["tab.select", { index: 3 }]: el valor llena el primer argumento del comando
export function call(action, cmds) {
  const i = action.indexOf(":");
  const name = i < 0 ? action : action.slice(0, i), value = i < 0 ? null : action.slice(i + 1);
  const first = cmds.find((c) => c.name === name)?.args?.[0]?.name;
  if (value === null || !first) return [name, {}];
  return [name, { [first]: NUMERIC.has(first) && /^-?\d+(\.\d+)?$/.test(value) ? Number(value) : value }];
}

// Buscar por tecla: "alt k", "cmd+shift+d", "⌥k" → { mods: ["alt"], key: "k" }. null si no nombra un modificador
// (entonces se busca por descripción).
const MODS = { alt: "alt", option: "alt", opt: "alt", "⌥": "alt", cmd: "cmd", command: "cmd", "⌘": "cmd", ctrl: "ctrl", control: "ctrl", "⌃": "ctrl", shift: "shift", "⇧": "shift" };
const ALIAS = { esc: "escape", "←": "left", "→": "right", "↑": "up", "↓": "down", "↵": "enter", "⇥": "tab" };
export function chord(text) {
  const tokens = text.toLowerCase().replace(/[⌥⌘⌃⇧]/g, (g) => ` ${g} `).split(/[\s+]+|-(?=.)/).filter(Boolean);
  const mods = tokens.filter((x) => MODS[x]).map((x) => MODS[x]);
  const rest = tokens.filter((x) => !MODS[x]);
  if (!mods.length || rest.length > 1) return null;
  return { mods: [...new Set(mods)], key: rest.length ? (ALIAS[rest[0]] ?? rest[0]) : "" };
}

// Las filas con una tecla así: con tecla, los mismos modificadores; solo modificadores, las que los tengan todos
export function byChord(all, q) {
  const score = (k) => {
    const [pre, last] = splitKey(k);
    const mods = pre ? pre.split("-") : [];
    if (!q.mods.every((m) => mods.includes(m))) return 0;
    if (!q.key) return mods.length === q.mods.length ? 2 : 1;
    return mods.length === q.mods.length && last.startsWith(q.key) ? (last === q.key ? 2 : 1) : 0;
  };
  return all.map((e) => ({ e, n: Math.max(0, ...e.binds.map(score)) })).filter((x) => x.n).sort((a, b) => b.n - a.n).map((x) => x.e);
}

export default class Keys extends Panel {
  setup() {
    this.title = "Teclas";
    this.placeholder = "¿Qué querés hacer? (o una tecla: alt k)";
  }

  subtitle() { return "enter hace lo que dice la fila"; }

  rows() {
    const all = entries(keys(), shared("layout") ?? "");
    if (this.query.trim()) {
      const q = chord(this.query);
      const hit = q ? byChord(all, q) : [];
      if (hit.length) return hit.map((e) => ({ key: e.id, e }));
      return rank(all, this.query, (e) => [e.title, `${e.binds.join(" ")} ${e.action}`]).map(({ item, hits }) => ({ key: item.id, e: item, hits }));
    }
    const rows = [];
    for (const g of GROUPS) {
      const members = all.filter((e) => e.group === g);
      if (members.length) rows.push({ head: g }, ...members.map((e) => ({ key: e.id, e })));
    }
    return rows;
  }

  draw(t, r, on) {
    const e = r.e;
    return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(div().flex_1().min_w(0).child(lit(t, e.title, r.hits, on ? t.foreground : t.muted)))
      .when(Boolean(e.where), (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(`en ${e.where}`)))
      .children(e.keys.flatMap((k, i) => [
        ...(i ? [div().flex_none().text_size(10.5).text_color(t.dim).child("o")] : []),
        chips(t, k, on),
      ]));
  }

  hints(row) {
    const e = row?.e;
    const what = !e ? "hacer" : e.fam ? "elegir cuál y hacerlo" : NO_RUN.has(e.action) ? "solo con su tecla" : "hacerlo";
    return [["enter", what], ["up", ""], ["down", "elegir"], ["escape", "cerrar"]];
  }

  empty() { return this.query.trim() ? null : "keys.json no tiene teclas."; }

  fire(action, args) {
    const own = String(props()?.overlay ?? "").replace(/^mod-/, "");
    if (action === `mod.open:${own}`) return;   // esta hoja: ya está abierta
    this.close();
    if (args) return run(action, args);
    const [name, a] = call(action, commands());
    run(name, a);
  }

  enter(r) {
    const e = r.e;
    if (e.fam) {
      return this.askFor({
        label: e.fam.label, title: e.title, help: e.fam.ask, verb: "hacerlo",
        run: (text) => {
          const v = e.fam.parse(text);
          if (v === null) return notify({ title: e.title, body: `«${text}» no va. ${e.fam.ask}`, level: "warning" });
          this.fire(e.fam.make(v), null);
        },
      });
    }
    if (NO_RUN.has(e.action)) return notify({ title: e.title, body: "Esa se hace con su tecla, no desde la hoja.", level: "info", timeout: 3000 });
    this.fire(e.action, e.args);
  }
}
