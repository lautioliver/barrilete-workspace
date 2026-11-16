// La barra izquierda de bk-lavanda: los espacios (sueltos o en carpetas: lista.js) y, debajo, los agentes con sus
// sub-agentes (quién lanzó a quién). Cada agente lleva el chip con su número fijo de ventana (alt+N), su título, dónde está y la marca
// de estado, la misma que usan las pestañas, la cabecera de cada pane y la barra de abajo.
// Dos vistas (el botón de la derecha de "AGENTES"): por prioridad (te esperan, listos, trabajando, quietos)
// o por espacio. Angosta (riel), solo los chips con su marca.
// Nació como clon del `agents` de Herdr 0.1.15: el orden, los pins y el árbol de sub-agentes son los suyos.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, focused, spaces, run, theme, shared, setShared, setAgentOrder, openOverlay, closeOverlay, props, window, layout, exec, home } from "herdr";
import { ICONS, PROSE, RANK, al, find, narrow, ago, ids, said, picto, mark, keycap, iconButton, rule } from "./kit.js";
import { Lista, menu } from "./lista.js";
import { Editar } from "./editar.js";

const SUBS_EVERY = 4000;
const bin = () => shared("bk.bin") || "bk";

// Al riel (en macOS, con lugar para los botones de la ventana) o de vuelta al ancho que tenía.
function toggleSidebar() {
  const width = find(layout(), "sidebar")?.size?.px;
  if (!narrow()) setShared("sidebar.width", width);
  setShared("sidebar.collapsed", !narrow());
  run("layout.resize", { id: "sidebar", px: narrow() ? (shared("sidebar.width") ?? 288) : window()?.platform === "macos" ? 76 : 44 });
}

// Un sub-agente sin pane no está en agents(): su palabra cruda, con error como "te espera". Nunca "listo":
// le rinde a su padre, y la novedad es el listo del padre.
const kidStatus = (k, listed) => {
  const s = listed.get(k.address) ?? k.status;
  return s === "error" ? "blocked" : s === "done" ? "idle" : s;
};
const SORTS = [
  { id: "priority", label: "Por prioridad", icon: "clock" },
  { id: "grouped", label: "Por espacio", icon: "layers" },
];
const sortOf = () => SORTS.find((s) => s.id === shared("agents.sort")) ?? SORTS[0];
const SECTION = { 4: "Te esperan", 3: "Listos", 2: "Trabajando", 1: "Quietos" };
const SECTION_STATUS = { 4: "blocked", 3: "done", 2: "working" };
// La marca de un sub-agente. tests/test_herdr_subagents.sh evalúa tree() y subRow() de este archivo sin sus
// imports (solo les pasa View, div, svg, h_flex, v_flex, agents, run y home): por eso subRow no usa del kit
// nada más que esto, y sin kit dibuja un hueco.
const subMark = (t, st) => (typeof mark === "function" ? mark(t, st, 12) : div());

export default class Agents extends View {
  init(_props, cx) {
    if (props()?.sortMenu) return;
    if (props()?.editar) { this.editar = new Editar(cx); return; }
    this.lista = new Lista();
    this.folded = new Set();
    this.claudeSubs = {};
    this.subsRaw = "";
    this.subError = null;
    const refresh = async (cx) => {
      if (this.subBusy) return;
      this.subBusy = true;
      let changed = false;
      try {
        const r = await exec(bin(), ["_subagents"], { timeout: 8000 });
        if (r.code !== 0) throw new Error(r.stderr.trim() || "bk _subagents no respondió");
        if (r.stdout !== this.subsRaw) {
          this.claudeSubs = JSON.parse(r.stdout).by_terminal ?? {};
          this.subsRaw = r.stdout;
          changed = true;
        }
        if (this.subError) changed = true;
        this.subError = null;
      } catch (e) {
        const msg = String(e?.message ?? e);
        changed = msg !== this.subError;
        this.subError = msg;
      } finally { this.subBusy = false; }
      // Solo se redibuja si cambió algo: cada dibujo de un mod repinta la ventana entera.
      if (changed) cx.notify();
    };
    cx.spawn(refresh);
    cx.timer.every(SUBS_EVERY, (cx) => cx.spawn(refresh));
    // El último estado de cada agente y cuándo cambió (ms), guardado entre reinicios.
    this.changed = JSON.parse(localStorage.getItem("changed") ?? "{}");
    this.pendingPins = JSON.parse(localStorage.getItem("pins") ?? "[]");
    if (!this.pendingPins.length) localStorage.removeItem("pins");
    this.migratingPins = new Set();
    cx.timer.every(30000, (cx) => cx.notify());   // los "hace 12m"
  }

  // Anota los agentes que cambiaron de estado. Listo y quieto cuentan como uno: mirar a uno que terminó lo
  // pasa de listo a quieto, y mirar no es que el agente haya hecho algo.
  track(list, now) {
    let dirty = false;
    for (const a of list) {
      const s = a.status === "done" ? "idle" : a.status;
      if (this.changed[a.address]?.s === s) continue;
      this.changed[a.address] = { s, at: now };
      dirty = true;
    }
    if (!dirty) return;
    const listed = new Set(list.map((a) => a.address));
    for (const [k, c] of Object.entries(this.changed)) if (!listed.has(k) && now - c.at > 30 * 86400000) delete this.changed[k];
    localStorage.setItem("changed", JSON.stringify(this.changed));
  }

  // Los pins de la versión vieja (guardados acá) pasan a la etiqueta de su terminal cuando vuelve.
  migratePins(all) {
    if (!this.pendingPins.length) return;
    const listed = new Map(all.filter((t) => t.state === "live").map((t) => [t.address, t]));
    const pending = this.pendingPins.filter((address) => {
      const terminal = listed.get(address);
      if (!terminal) return true;
      if (terminal.labels?.["herdr.pinned"]) return false;
      if (!this.migratingPins.has(address)) {
        this.migratingPins.add(address);
        run("terminal.pin", { terminal: address, pinned: true });
      }
      return true;
    });
    if (pending.length === this.pendingPins.length) return;
    this.pendingPins = pending;
    if (pending.length) localStorage.setItem("pins", JSON.stringify(pending));
    else localStorage.removeItem("pins");
  }

  since(a) {
    return this.changed[a.address]?.at ?? 0;
  }

  sortMenu(t) {
    const on = sortOf().id;
    return v_flex().w_full().p(5).bg(t.popover).text_size(12.5)
      .child(div().px(8).pt(4).pb(6).text_size(10.5).font_semibold().text_color(t.accent).child("ORDENAR AGENTES"))
      .children(SORTS.map((s) => h_flex().id(`sort-${s.id}`).h(30).px(8).gap(9).rounded(6).items_center().text_color(t.foreground)
        .hover((el) => el.bg(t.hover))
        .on_click(() => { setShared("agents.sort", s.id); closeOverlay(props().overlay); })
        .child(svg(`${ICONS}${s.icon}.svg`).size(14).flex_none().text_color(t.muted))
        .child(div().flex_1().child(s.label))
        .when(s.id === on, (el) => el.child(svg(`${ICONS}check.svg`).size(14).flex_none().text_color(t.accent)))));
  }

  // Los sub-agentes vivos de `addr`, en profundidad, cada uno con las líneas del árbol delante.
  tree(all, addr, lead = []) {
    const kids = all.filter((k) => k.parent === addr && k.state === "live");
    return kids.flatMap((k, i) => {
      const last = i === kids.length - 1;
      return [
        { t: k, lines: [...lead, last ? "└" : "├"] },
        ...this.tree(all, k.address, [...lead, last ? "" : "│"]),
      ];
    });
  }

  subRow(t, s, shown) {
    const k = s.t;
    const st = kidStatus(k, this.listed);
    const on = k.address === shown;
    return h_flex().id(`sub-${k.address}`).pl(19).pr(8).h(24).flex_none().rounded(6).items_center().text_size(11.5).cursor_pointer()
      .when(on, (el) => el.bg(t.selected))
      .hover((x) => x.bg(t.hover))
      .on_click(() => {
        if (k.transcript) {
          const parent = agents().find((a) => a.address === k.parent);
          if (parent) run("space.select", { id: parent.space });
          run("tab.new", { ...(parent ? { space: parent.space } : {}), name: k.name.split(" · ")[0], folder: home(), argv: ["bk", "sub", k.transcript] });
        } else if (this.listed.has(k.address)) run("pane.focus", { terminal: k.address });
        else run("terminal.peek", { terminal: k.address });
      })
      .tooltip(k.transcript ? `${k.name}${k.background ? " · segundo plano" : ""} · clic para seguirlo en vivo` : k.name || k.address)
      .children(s.lines.map((l, i) => div().self_start().mt(-3).w(i === s.lines.length - 1 ? 14 : 10).h(15).mr(i === s.lines.length - 1 ? 7 : 4).flex_none()
        .when(Boolean(l), (el) => el.border_l(1).border_color(t.input))
        .when(l === "└" || l === "├", (el) => el.border_b(1).rounded_bl(5))))
      .child(div().flex_1().min_w(0).truncate().text_color(on ? t.foreground : t.muted).child(k.name || k.template || k.program?.name || k.address))
      .when(Boolean(k.background), (el) => el.child(div().flex_none().ml(6).text_size(10.5).text_color(t.dim).child("2º")))
      .child(div().ml(6).child(subMark(t, st)));
  }

  render(cx) {
    const t = theme();
    if (props()?.sortMenu) return this.sortMenu(t);
    if (this.editar) return this.editar.render(t);
    const collapsed = narrow();
    const sort = sortOf();
    let list = agents();
    this.listed = new Map(list.map((a) => [a.address, a.status]));
    const native = terminals();
    const numbers = ids(native);
    const internal = Object.entries(this.claudeSubs).flatMap(([parent, children]) =>
      children.map((child) => ({
        address: `claude:${parent}:${child.id}`, parent, state: "live", status: "working",
        name: `${child.number}. ${child.type === "general-purpose" ? "general" : child.type} · ${child.description}`,
        transcript: child.path, background: child.background,
      })));
    const all = [...native, ...internal];
    this.migratePins(all);
    const shown = focused()?.agent;
    const now = Date.now();
    this.track(list, now);
    // Un sub-agente con pane también está en agents(): donde un árbol lo muestra no lleva fila propia, salvo fijado.
    const nested = new Set(collapsed ? [] : list.flatMap((a) => this.tree(all, a.address).map((s) => s.t.address)));
    list = list.filter((a) => a.pinned || !nested.has(a.address));
    const tabCounts = new Map();
    for (const a of list) tabCounts.set(a.tab, (tabCounts.get(a.tab) ?? 0) + 1);
    const byPriority = sort.id === "priority";
    const urgency = new Map(list.map((a) => [a.address, Math.max(RANK[a.status] ?? 0, ...this.tree(all, a.address).map((s) => RANK[kidStatus(s.t, this.listed)] ?? 0))]));
    const rankOf = (a) => urgency.get(a.address);
    if (byPriority) list = [...list].sort((x, y) => rankOf(y) - rankOf(x) || this.since(y) - this.since(x) || y.seq - x.seq);
    const pinned = list.filter((a) => a.pinned);
    const rest = list.filter((a) => !a.pinned);
    list = [...pinned, ...rest];
    setAgentOrder(list.map((a) => a.address));

    const sp = spaces();
    const tabs = new Map(sp.flatMap((s) => s.tabs).map((tab) => [tab.id, tab]));
    // El título de la fila: lo que el agente dice que hace. Una pestaña que alguien nombró a mano gana; los
    // nombres automáticos (chat-3, 2, el del programa) no dicen nada y van a la segunda línea.
    const titleOf = (a) => {
      const tab = tabs.get(a.tab);
      const own = said(a.title, a.program, a.address);
      const auto = !tab?.named || /^(chat-\d+|\d+)$/.test(tab.name) || tab.name === a.program?.name || tabCounts.get(a.tab) > 1;
      return (auto ? own : "") || (tab?.named ? tab.name : "") || own || a.program?.name || a.address;
    };
    const metaOf = (a, title, full) => {
      const tab = tabs.get(a.tab);
      const machine = a.address.includes("/") ? a.address.split("/")[0] : null;
      const tabName = tab?.named && tab.name !== title ? tab.name : null;
      return [machine, full ? a.space_name : null, tabName ?? (a.program?.name !== title ? a.program?.name : null)].filter(Boolean).join(" · ");
    };

    // El chevron que pliega los sub-agentes; plegado, cuántos son, con el color del más urgente.
    const fold = (a, subs) => {
      const sts = subs.map((s) => kidStatus(s.t, this.listed));
      const top = sts.reduce((m, s) => ((RANK[s] ?? 0) > (RANK[m] ?? 0) ? s : m), null);
      const open = !this.folded.has(a.address);
      return div().id(`fold-${a.address}`).h(16).px(2).gap(2).flex().flex_none().items_center().rounded(4).text_size(10.5)
        .text_color(open ? t.dim : (t[top] ?? t.dim)).cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click((_e, cx) => {
          cx.stop_propagation();
          open ? this.folded.add(a.address) : this.folded.delete(a.address);
          cx.notify();
        })
        .child(svg(`${ICONS}chevron-${open ? "down" : "right"}.svg`).size(11).flex_none())
        .when(!open, (el) => el.child(String(subs.length)));
    };

    const row = (a, subs = []) => {
      const n = numbers.get(a.address);
      if (collapsed) {
        // El riel: el chip con su número y, en la esquina, la marca si no está quieto.
        return h_flex().id(`ag-${a.address}`).relative().h(30).flex_none().justify_center().items_center().cursor_pointer()
          .tooltip(titleOf(a))
          .on_click(() => run("pane.focus", { pane: a.pane }))
          .child(div().p(3).rounded(8).when(a.focused, (el) => el.bg(t.selected)).child(keycap(t, n, { on: a.focused })))
          .when(a.status !== "idle", (el) => el.child(div().absolute().top(0).right(15).rounded_full().bg(t.chrome).child(mark(t, a.status, 12))));
      }
      const when = this.since(a);
      const isPinned = a.pinned;
      const full = byPriority || isPinned;   // sin un rótulo de espacio arriba, la fila dice el suyo
      const title = titleOf(a);
      const meta = metaOf(a, title, full);
      const quiet = a.status === "idle" && !a.focused;
      const pic = picto(a.program, 12, t.dim);
      const pin = div().id(`pin-${a.address}`).flex_none().p(1).rounded(4).text_color(t.dim).cursor_pointer()
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .tooltip(isPinned ? "Soltar" : "Fijar arriba")
        .on_click((_e, cx) => {
          cx.stop_propagation();
          run("terminal.pin", { terminal: a.address, pinned: !isPinned });
          this.hovered = null;   // la fila se va de abajo del puntero y no llega el aviso de salida
          cx.notify();
        })
        .child(svg(`${ICONS}${isPinned ? "pin-off" : "pin"}.svg`).size(12));
      const timeColor = a.status === "blocked" ? t.blocked : a.status === "working" ? t.working : t.dim;
      const waits = a.status === "blocked";
      // La que te espera es una tarjeta con borde ámbar: se encuentra sin leer.
      return h_flex().id(`ag-${a.address}`).px(7).h(44).flex_none().rounded(8).items_center().gap(10).cursor_pointer()
        .border_1().border_color(waits ? al(t.blocked, "59") : "#00000000")
        .when(a.focused, (el) => el.bg(t.selected))
        .when(!a.focused && waits, (el) => el.bg(al(t.blocked, "14")))
        .hover((s) => s.bg(a.focused ? t.selected : waits ? al(t.blocked, "22") : t.hover))
        .on_hover((on, cx) => {
          if (on) this.hovered = a.address;
          else if (this.hovered === a.address) this.hovered = null;
          cx.notify();
        })
        .on_click(() => run("pane.focus", { pane: a.pane }))
        .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); menu("pane", { pane: a.pane, terminal: a.address }); })
        .child(keycap(t, n, { on: a.focused }))
        .child(v_flex().flex_1().min_w(0).gap(3)
          .child(h_flex().gap(6).items_center()
            .child(div().flex_1().min_w(0).truncate().font_family(PROSE).text_size(13).line_height(1.25).font_medium().text_color(quiet ? t.muted : t.foreground).child(title))
            .when(subs.length > 0, (el) => el.child(fold(a, subs)))
            .child(mark(t, a.status)))
          .child(h_flex().gap(5).items_center().text_size(11).line_height(1.25).text_color(t.dim)
            .when(Boolean(pic), (el) => el.child(pic))
            .child(div().flex_1().min_w(0).truncate().child(meta))
            .when(this.hovered === a.address, (el) => el.child(pin))
            .when(this.hovered !== a.address && isPinned, (el) => el.child(svg(`${ICONS}pin.svg`).size(11).flex_none()))
            .when(this.hovered !== a.address && Boolean(when), (el) => el.child(div().flex_none().min_w(28).whitespace_nowrap().text_right().text_color(timeColor).child(ago(now - when))))));
    };

    const withKids = (a) => {
      const subs = collapsed ? [] : this.tree(all, a.address);
      const r = row(a, subs);
      if (this.folded.has(a.address)) return [r];
      return [r, ...subs.map((s) => this.subRow(t, s, shown))];
    };

    // Los grupos, en el orden de la lista: secciones por prioridad o espacios. Los agentes de un espacio
    // vienen juntos en agents(), así que los vecinos arman el grupo.
    const groups = pinned.length ? [{ id: "pinned", label: "Fijados", status: null, members: pinned }] : [];
    for (const a of rest) {
      const r = rankOf(a) || RANK.idle;
      const id = byPriority ? `sec-${r}` : `sp-${a.space}`;
      if (groups.at(-1)?.id === id) groups.at(-1).members.push(a);
      else groups.push({ id, label: byPriority ? SECTION[r] : a.space_name || "", status: byPriority ? SECTION_STATUS[r] : null, members: [a] });
    }

    // El rótulo de un grupo; lo pliega. Plegado dice cuántos son y el estado más urgente.
    const header = (g, first) => {
      const open = !this.folded.has(g.id);
      const top = g.members.reduce((m, a) => ((RANK[a.status] ?? 0) > (RANK[m] ?? 0) ? a.status : m), null);
      return h_flex().id(`g-${g.id}`).px(8).h(first ? 22 : 30).pt(first ? 0 : 8).flex_none().gap(6).items_center().text_size(11).cursor_pointer()
        .hover((s) => s.text_color(t.foreground))
        .on_click((_e, cx) => {
          open ? this.folded.add(g.id) : this.folded.delete(g.id);
          cx.notify();
        })
        .child(div().flex_shrink(1).min_w(0).truncate().font_medium().text_color(t[g.status] ?? t.muted).child(g.label))
        .child(div().flex_none().text_color(t.dim).child(String(g.members.length)))
        .child(div().flex_1())
        .when(!open, (el) => el
          .when(!byPriority && top && top !== "idle", (x) => x.child(mark(t, top, 12)))
          .child(svg(`${ICONS}chevron-right.svg`).size(11).flex_none().text_color(t.dim)));
    };
    const rows = collapsed
      ? list.flatMap(withKids)
      : groups.flatMap((g, i) => [header(g, i === 0), ...(this.folded.has(g.id) ? [] : g.members.flatMap(withKids))]);

    if (collapsed) {
      return v_flex().size_full().min_h(0).bg(t.chrome).pt(4)
        .child(v_flex().flex_none().max_h(200).overflow_hidden().children(this.lista.railSection(t)))
        .child(div().flex_none().mx(22).my(6).h(1).bg(t.border))
        .child(v_flex().id("ag-list").flex_1().min_h(0).overflow_y_scrollbar().children(rows))
        .child(h_flex().h(30).flex_none().items_center().justify_center()
          .child(iconButton(t, "collapse", "sidebar", toggleSidebar, { tip: "Abrir la barra", size: 15 })));
    }
    return v_flex().size_full().min_h(0).bg(t.chrome).pl(8).pr(4).pt(8).text_size(12.5)
      // Soltar lo que se arrastraba de la lista de espacios fuera de ella no mueve nada
      .on_mouse_up("left", (_e, cx) => { if (this.lista.drag) { this.lista.drag = null; cx.notify(); } })
      .children(this.lista.section(t))
      .child(div().h(6).flex_none())
      .child(rule(t, "AGENTES", [
        iconButton(t, "ag-sort", sort.icon, () => openOverlay({ mod: "bk-agentes", kind: "popup", width: 200, height: 110, props: { sortMenu: true } }), { tip: `Orden: ${sort.label.toLowerCase()}` }),
      ]))
      .when(list.length === 0, (el) => el.child(div().px(8).pt(2).text_size(11.5).text_color(t.dim).child("Todavía no hay agentes. Aparecen acá cuando avisan su estado.")))
      .when(Boolean(this.subError), (el) => el.child(div().px(8).pb(4).text_size(11).text_color(t.blocked).tooltip(this.subError || "").child("No pude leer los sub-agentes de Claude")))
      .child(v_flex().id("ag-list").flex_1().min_h(0).pr(4).pb(8).gap(1).overflow_y_scrollbar().children(rows));
  }
}
