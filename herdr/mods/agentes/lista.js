// Los espacios de la barra izquierda: sueltos o en carpetas que se pliegan, cada cosa con su color y su imagen.
// Arrastrar reordena (la línea dice dónde cae) y soltar sobre una carpeta mete el espacio adentro; soltado sobre
// la suya, lo saca. Lo mismo se hace con el clic derecho (Mover a…, Subir, Bajar), para no depender del mouse.
// Un espacio cerrado que acomodaste en una carpeta sigue ahí, apagado: un clic lo reabre (bk open).
// Las reglas son de espacios.js (el estado, shared "bk.espacios"); acá va solo el dibujo y el arrastre.

import { div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { spaces, agents, terminals, run, shared, setShared, openOverlay, exec, notify, home, checking } from "herdr";
import { ICONS, RANK, al, mark, iconButton, rule } from "./kit.js";
import * as E from "./espacios.js";

const TINTS = ["ansi4", "ansi5", "ansi6", "ansi13", "ansi3", "ansi2"];
const hash = (s) => { let h = 0; for (const ch of String(s)) h = (h * 31 + ch.charCodeAt(0)) >>> 0; return h; };
const bin = () => shared("bk.bin") || "bk";
const ROWS = 10;      // hasta tantas filas la lista mide lo que ocupa; con más, se desplaza dentro de ese alto
const TRIES = 3;       // y si Herdr no lo toma o otra pantalla lo devuelve, no se insiste sin fin
const SETTLE = 2000;  // un space.move puede perder contra otro cambio: no se repite el mismo pedido antes de esto

// El menú del clic derecho (mods/bk-menu), del alto de sus opciones (6 px arriba y abajo, 32 por opción, 9 por raya)
const MENU_H = { space: 12 + 9 * 32 + 9, closed: 12 + 3 * 32 + 9, folder: 12 + 4 * 32 + 9, pane: 12 + 5 * 32 + 2 * 9 };
export const menu = (tab, target) => openOverlay({ mod: "bk-menu", kind: "popup", width: 300, height: MENU_H[tab], props: { tab, target } });
// El diálogo de una carpeta o de un espacio: nombre (la carpeta), color e imagen
export const edit = (ref) => openOverlay({ mod: "bk-agentes", kind: "popup", width: 340, height: ref.startsWith("c:") ? 318 : 268, props: { editar: ref } });

// Un color guardado (un nombre del tema o #rrggbb) como color de verdad
export const paint = (t, c) => (c?.startsWith?.("#") ? c : t[c]) ?? null;
const worst = (list) => list.reduce((m, s) => ((RANK[s] ?? 0) > (RANK[m] ?? 0) ? s : m), null);

// La imagen, o la inicial sobre un tinte de su color
export function avatar(t, { imagen, color, name, size = 18, on = false, dim = false }) {
  if (imagen) return image(imagen).w(size).h(size).flex_none().rounded(size > 20 ? 6 : 5).opacity(dim ? 0.45 : 1);
  return div().size(size).flex_none().rounded(size > 20 ? 6 : 5).bg(al(color, on ? "40" : "26")).flex().items_center().justify_center()
    .text_size(size > 20 ? 11.5 : 10.5).line_height(1).font_bold().text_color(color).opacity(dim ? 0.5 : 1)
    .child([...(name ?? "")][0]?.toUpperCase() ?? "?");
}

export class Lista {
  constructor() {
    try { this.folded = new Set(JSON.parse(localStorage.getItem("carpetas.plegadas") ?? "[]")); } catch { this.folded = new Set(); }
    this.drag = null;       // { ref, over }: lo que se arrastra y la fila que tiene debajo
    this.ordering = null;
  }

  // El estado al día con los espacios de Herdr; si cambió (uno nuevo, uno renombrado), se guarda
  state(sp) {
    const raw = shared(E.KEY);
    const labels = new Map(terminals().map((x) => [x.address, x.labels?.["bk.project"]]));
    const projects = new Map();
    for (const a of agents()) if (labels.get(a.address) && !projects.has(a.space)) projects.set(a.space, labels.get(a.address));
    const st = E.sync(E.clean(raw), sp, projects);
    // (herdr-app check dibuja el mod de verdad: ahí no se guarda ni se mueve nada)
    if (!checking() && JSON.stringify(st) !== JSON.stringify(raw ?? null)) setShared(E.KEY, st);
    return st;
  }

  // Herdr en el orden de la lista: space.next/prev y los agentes "por espacio" siguen lo que se ve. Solo los
  // espacios de esta máquina (van primero): las pantallas conectadas comparten el orden y cada una tiene su
  // lista, así que si todas lo impusieran entero se pisarían sin fin.
  order(st, sp) {
    const mine = new Set(sp.filter((s) => !s.machine).map((s) => s.id));
    const have = sp.map((s) => s.id).filter((id) => mine.has(id)), want = E.target(st, sp).filter((id) => mine.has(id));
    const plan = E.moves(have, want);
    // La cuenta es por orden pedido y no se borra cuando Herdr lo toma: si otra pantalla lo devuelve, vuelve a
    // faltar lo mismo. Empieza de nuevo cuando cambia lo que se quiere (moviste algo, se abrió o cerró un espacio).
    const key = JSON.stringify(want);
    if (this.ordering?.key !== key) this.ordering = { key, at: 0, tries: 0 };
    if (!plan.length || checking()) return;
    if (this.ordering.tries >= TRIES || Date.now() - this.ordering.at < SETTLE) return;
    this.ordering.at = Date.now();
    this.ordering.tries++;
    for (const m of plan) run("space.move", m);
  }

  toggle(id, cx) {
    this.folded.has(id) ? this.folded.delete(id) : this.folded.add(id);
    localStorage.setItem("carpetas.plegadas", JSON.stringify([...this.folded]));
    cx.notify();
  }

  newFolder() {
    const id = "c" + Date.now().toString(36);
    setShared(E.KEY, E.createFolder(E.clean(shared(E.KEY)), id, "Carpeta nueva"));
    edit(`c:${id}`);
  }

  // Reabrir un espacio cerrado: bk open en su carpeta (el espacio de ese proyecto, con su chat)
  reopen(key, e) {
    if (!e.carpeta) return notify({ title: `No sé dónde estaba ${key}`, body: "Quitalo de la lista con el clic derecho.", level: "error" });
    exec(bin(), ["_do", "--cwd", e.carpeta, "--title", `Abrir ${key}`, "--", "open", e.carpeta], { timeout: 15000 })
      .then((r) => { if (r.code !== 0) notify({ title: `No pude abrir ${key}`, body: (r.stderr || r.stdout).trim().split("\n").pop() ?? "", level: "error" }); })
      .catch((err) => notify({ title: `No pude abrir ${key}`, body: String(err?.message ?? err), level: "error" }));
  }

  // Soltar `ref` sobre `over`. Sobre una carpeta, un espacio entra (o sale, si ya era de ella y queda justo antes);
  // sobre cualquier otra fila queda del lado hacia donde iba: después si venía de arriba, antes si de abajo.
  drop(st, ref, over) {
    if (ref === over) return st;
    if (over.startsWith("c:") && ref.startsWith("e:")) {
      const id = over.slice(2);
      return E.folderOf(st, ref.slice(2)) === id ? E.move(st, ref, { antes: over }) : E.move(st, ref, { dentro: id });
    }
    const side = this.flat.indexOf(ref) < this.flat.indexOf(over) ? "despues" : "antes";
    return E.move(st, ref, { [side]: over });
  }

  // Lo común a toda fila: se arrastra, recibe lo que le sueltan y, sin arrastre, hace `click`
  handle(el, ref, click) {
    return el.cursor_pointer()
      .on_mouse_down("left", () => { this.drag = { ref, over: ref }; })
      .on_mouse_move((_e, cx) => {
        if (this.drag && this.drag.over !== ref) { this.drag.over = ref; cx.notify(); }
      })
      .on_mouse_up("left", (_e, cx) => {
        const d = this.drag;
        this.drag = null;
        if (!d) return;
        cx.stop_propagation();
        if (d.ref === ref) click(cx);
        else if (d.over === ref) {
          const st = E.clean(shared(E.KEY)), next = this.drop(st, d.ref, ref);
          if (next !== st) setShared(E.KEY, next);
        }
        cx.notify();
      });
  }

  // Lo que se le dibuja a la fila que tiene el arrastre encima: la línea de dónde cae, o el marco de "entra acá"
  aim(t, el, ref) {
    const d = this.drag;
    if (!d || d.over !== ref || d.ref === ref) return el.when(d?.ref === ref && d.over !== ref, (x) => x.opacity(0.5));
    if (ref.startsWith("c:") && d.ref.startsWith("e:")) return el.bg(al(t.accent, "22"));
    const below = this.flat.indexOf(d.ref) < this.flat.indexOf(ref);
    return el.child(div().absolute().left(0).right(0).h(2).rounded_full().bg(t.accent).when(below, (l) => l.bottom(0)).when(!below, (l) => l.top(0)));
  }

  colorOf(t, st, f) {
    const herdr = f.s ? (shared("space.colors") ?? {})[f.s.id] : null;
    return paint(t, E.colorOf(st, f.key)) ?? paint(t, herdr) ?? t[TINTS[hash(f.s?.id ?? f.key) % TINTS.length]] ?? t.accent;
  }
  folderColor(t, r) {
    return paint(t, r.c.color) ?? t[TINTS[hash(r.id) % TINTS.length]] ?? t.accent;
  }

  // Un espacio: imagen o inicial, nombre, la rama si no es la de siempre, y la marca si algo ahí te necesita.
  // Cerrado (f.s null): apagado, y el clic lo reabre.
  spaceRow(t, st, f, inside) {
    const s = f.s, ref = `e:${f.key}`;
    const color = this.colorOf(t, st, f);
    const name = s?.name ?? f.key;
    const tile = avatar(t, { imagen: f.e.imagen, color, name, on: Boolean(s?.active), dim: !s });
    const base = h_flex().id(`sp-${s?.id ?? "x-" + f.key}`).relative().h(28).pl(inside ? 22 : 8).pr(8).gap(9).flex_none().rounded(8).items_center();
    if (!s) {
      return this.aim(t, this.handle(base, ref, () => this.reopen(f.key, f.e)), ref)
        .hover((x) => x.bg(t.hover))
        .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); menu("closed", { key: f.key }); })
        .tooltip(`Cerrado · clic para abrirlo${f.e.carpeta ? " en " + f.e.carpeta.replace(home(), "~") : ""}`)
        .child(tile)
        .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(name));
    }
    const loud = s.status && s.status !== "idle";
    const usual = !s.branch || s.branch === "main" || s.branch === "master" || s.branch.toLowerCase() === s.name.toLowerCase();
    return this.aim(t, this.handle(base, ref, () => run("space.select", { id: s.id })), ref)
      .when(s.active, (el) => el.bg(t.selected))
      .when(!s.active, (el) => el.hover((x) => x.bg(t.hover)))
      .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); menu("space", { id: s.id }); })
      .child(tile)
      .child(div().flex_shrink(0).max_w(usual ? 190 : 130).truncate().text_color(s.active ? t.foreground : t.muted).when(s.active, (el) => el.font_medium()).child(name))
      .when(Boolean(s.machine), (el) => el.child(div().flex_none().text_size(10.5).text_color(t.dim).child(`@${s.machine}`)))
      .child(div().flex_1().min_w(0).truncate().text_right().text_size(11).text_color(t.dim).child(usual ? "" : s.branch))
      .when(loud, (el) => el.child(mark(t, s.status, 12)));
  }

  // El encabezado de una carpeta: imagen o inicial, nombre, cuántos tiene y la flecha. Plegada, la marca de lo
  // más urgente de adentro.
  folderRow(t, r) {
    const ref = `c:${r.id}`, open = !this.folded.has(r.id);
    const color = this.folderColor(t, r);
    const top = worst(r.filas.map((f) => f.s?.status).filter(Boolean));
    const base = h_flex().id(`fo-${r.id}`).relative().h(28).px(8).gap(9).flex_none().rounded(8).items_center();
    return this.aim(t, this.handle(base, ref, (cx) => this.toggle(r.id, cx)), ref)
      .hover((x) => x.bg(t.hover))
      .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); menu("folder", { id: r.id }); })
      .child(avatar(t, { imagen: r.c.imagen, color, name: r.c.nombre }))
      .child(div().flex_shrink(1).min_w(0).truncate().font_semibold().text_color(t.foreground).child(r.c.nombre))
      .child(div().flex_none().text_size(11).text_color(t.dim).child(String(r.filas.length)))
      .child(div().flex_1())
      .when(!open && top && top !== "idle", (el) => el.child(mark(t, top, 12)))
      .child(svg(`${ICONS}chevron-${open ? "down" : "right"}.svg`).size(11).flex_none().text_color(t.dim));
  }

  // Las filas de la barra ancha, de arriba abajo. Una carpeta plegada no esconde el espacio que estás mirando.
  rows(t, st, sp) {
    const shown = E.view(st, sp);
    const inFolder = (r) => (this.folded.has(r.id) ? r.filas.filter((f) => f.s?.active) : r.filas);
    this.flat = shown.flatMap((r) => (r.kind === "carpeta" ? [`c:${r.id}`, ...inFolder(r).map((f) => `e:${f.key}`)] : [`e:${r.key}`]));
    return shown.flatMap((r) => (r.kind === "carpeta"
      ? [this.folderRow(t, r), ...inFolder(r).map((f) => this.spaceRow(t, st, f, true))]
      : [this.spaceRow(t, st, r, false)]));
  }

  // El riel: un cuadrado por carpeta (clic: la pliega) y por espacio abierto, con la marca en la esquina
  rail(t, st, sp) {
    const chip = (id, tip, tile, on, status, act, right) => {
      const el = h_flex().id(id).relative().h(30).flex_none().justify_center().items_center().cursor_pointer().tooltip(tip)
        .on_click(act)
        .child(div().p(3).rounded(8).when(on, (x) => x.bg(t.selected)).child(tile))
        .when(status && status !== "idle", (x) => x.child(div().absolute().top(0).right(15).rounded_full().bg(t.chrome).child(mark(t, status, 12))));
      return right ? el.on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); right(); }) : el;
    };
    const space = (f) => chip(`sp-${f.s.id}`, f.s.name, avatar(t, { imagen: f.e.imagen, color: this.colorOf(t, st, f), name: f.s.name, size: 22, on: f.s.active }),
      f.s.active, f.s.status, () => run("space.select", { id: f.s.id }), () => menu("space", { id: f.s.id }));
    return E.view(st, sp).flatMap((r) => {
      if (r.kind !== "carpeta") return [space(r)];
      const open = !this.folded.has(r.id), live = r.filas.filter((f) => f.s);
      const head = chip(`fo-${r.id}`, r.c.nombre, div().rounded(7).border_1().border_color(al(this.folderColor(t, r), open ? "00" : "88"))
        .child(avatar(t, { imagen: r.c.imagen, color: this.folderColor(t, r), name: r.c.nombre, size: 22 })),
        false, open ? null : worst(live.map((f) => f.s.status).filter(Boolean)), (_e, cx) => this.toggle(r.id, cx), () => menu("folder", { id: r.id }));
      return [head, ...(open ? live : live.filter((f) => f.s.active)).map(space)];
    });
  }

  // La sección entera: el rótulo con sus botones y la lista
  section(t) {
    const sp = spaces(), st = this.state(sp);
    this.order(st, sp);
    const rows = this.rows(t, st, sp);
    const list = (rows.length > ROWS ? v_flex().id("sp-list").h(ROWS * 29).overflow_y_scrollbar() : v_flex().id("sp-list")).flex_none().gap(1).pr(4)
      // Soltar fuera de una fila no mueve nada
      .on_mouse_up("left", (_e, cx) => { if (this.drag) { this.drag = null; cx.notify(); } })
      .children(rows);
    return [
      rule(t, "ESPACIOS", [
        iconButton(t, "folder-new", "folder-plus", () => this.newFolder(), { tip: "Carpeta nueva" }),
        iconButton(t, "space-new", "plus", () => run("space.new"), { tip: "Espacio nuevo" }),
      ]),
      list,
    ];
  }

  railSection(t) {
    const sp = spaces(), st = this.state(sp);
    this.order(st, sp);
    return this.rail(t, st, sp);
  }
}
