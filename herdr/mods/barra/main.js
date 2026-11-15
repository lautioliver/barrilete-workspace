// La barra de abajo de bk en Herdr: dónde estás (proyecto, rama, cuenta), qué te espera, el uso de hoy, la radio
// y las dos teclas que abren todo lo demás. Además lleva dos cosas que necesitan a alguien siempre despierto:
//   · el rastro de pestañas (shared "bk.trail"), para que alt+0 vuelva a donde estabas
//   · que bk conozca cada agente: uno abierto desde Herdr (sin etiquetas de bk) se adopta como chat de su
//     proyecto y toma su número fijo de ventana (bk _adopt → hd_adopt en lib/herdr.sh)
// Los datos que no son de Herdr salen de `bk _hub status <carpeta>`, cada 10 s y al cambiar de pestaña.

import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { exec, spaces, agents, terminals, focused, theme, run, keys, shared, setShared, home } from "herdr";

const EVERY = 10000;
const GLYPH = { alt: "⌥", cmd: "⌘", ctrl: "⌃", shift: "⇧" };
const bin = () => shared("bk.bin") || "bk";
const human = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1) + "M" : n >= 1e3 ? Math.round(n / 1e3) + "k" : String(Math.round(n ?? 0)));
const keyText = (action) => {
  const k = keys().find((b) => b.section === "global" && b.action === action)?.keys;
  return k ? k.split("-").map((p) => GLYPH[p] ?? p.toUpperCase()).join("") : null;
};

// --- dibujo: las mismas piezas que el resto de bk-lavanda (herdr/mods/agentes/kit.js), copiadas acá ---
// Un color del tema con transparencia; uno que ya la trae queda como está.
const al = (c, a) => (/^#[0-9a-fA-F]{6}$/.test(c ?? "") ? c + a : c ?? "#00000000");
// La marca de estado: trabajando late (un cuadro cada 450 ms), te espera es un disco con !, listo un tilde, quieto un anillo.
function mark(t, status, box = 12) {
  const wrap = (el) => div().size(box).flex_none().flex().items_center().justify_center().child(el);
  if (status === "working") return div().size(box).flex_none().flex().items_center().justify_center()
    .text_size(box - 2).line_height(1).text_color(t.working).frames(["●", "●", "•"], 450);
  if (status === "blocked") return div().size(box).flex_none().rounded_full().bg(t.blocked).flex().items_center().justify_center()
    .text_size(box - 4).line_height(1).font_bold().text_color(t.accent_foreground).child("!");
  if (status === "done") return wrap(svg("mods/workspace-chrome/check.svg").size(box - 1).text_color(t.done));
  return wrap(div().size(Math.round(box * 0.57)).rounded_full().border(1.5).border_color(t.idle ?? t.dim));
}
// Una tecla: el número de la ventana (on) o un atajo.
function keycap(t, text, on = false) {
  return div().min_w(18).h(18).px(4).flex_none().flex().items_center().justify_center().rounded(5).border_1()
    .border_color(on ? al(t.accent, "88") : t.border).bg(on ? al(t.accent, "26") : t.raised)
    .text_size(10.5).line_height(1).font_semibold().text_color(on ? t.accent : t.muted).child(String(text));
}

export default class Barra extends View {
  init(_props, cx) {
    this.data = null;
    this.cwd = null;
    this.at = 0;
    this.busy = false;
    this.tried = new Set();
    this.adopting = false;
    const load = async (cx) => {
      const dir = focused()?.cwd || home();
      if (this.busy || (dir === this.cwd && Date.now() - this.at < EVERY - 500)) return;
      this.busy = true;
      try {
        const r = await exec(bin(), ["_hub", "status", dir], { cwd: home(), timeout: 8000 });
        this.data = r.code === 0 ? JSON.parse(r.stdout) : null;
      } catch (_e) {
        this.data = null;
      }
      this.cwd = dir;
      this.at = Date.now();
      this.busy = false;
      cx.notify();
    };
    cx.spawn(load);
    cx.timer.every(EVERY, (cx) => cx.spawn(load));
    // De fondo y sin redibujar: el rastro y la adopción
    cx.timer.every(1500, (cx) => {
      this.trail();
      if ((focused()?.cwd || home()) !== this.cwd) cx.spawn(load);
      cx.spawn(async () => this.adopt());
    });
  }

  trail() {
    const f = focused();
    if (!f?.space || !f?.tab) return;
    const old = shared("bk.trail") ?? [];
    if (old[0]?.space === f.space && old[0]?.tab === f.tab) return;
    setShared("bk.trail", [{ space: f.space, tab: f.tab }, ...old.filter((p) => p.tab !== f.tab)].slice(0, 12));
  }

  async adopt() {
    if (this.adopting) return;
    const all = terminals();
    const need = agents().map((a) => a.address).filter((addr) => {
      if (this.tried.has(addr)) return false;   // las de otra máquina (omarchy/t28) también: hd_adopt sabe con ellas
      const t = all.find((x) => x.address === addr);
      return t && t.state === "live" && !t.labels?.["bk.id"];
    });
    if (!need.length) return;
    this.adopting = true;
    for (const addr of need) {
      this.tried.add(addr);
      try { await exec(bin(), ["_adopt", addr], { cwd: home(), timeout: 15000 }); } catch (_e) { /* la próxima terminal */ }
    }
    this.adopting = false;
  }

  render() {
    const t = theme();
    const d = this.data;
    const space = spaces().find((s) => s.active);
    const list = agents();
    const n = (st) => list.filter((a) => a.status === st).length;
    const blocked = n("blocked"), done = n("done"), working = n("working");
    const waiting = (d?.waiting ?? 0) + (d?.pending ?? 0);
    const seg = (id, action, tip) => h_flex().id(id).flex_none().h(20).px(6).gap(6).items_center().rounded(5)
      .when(Boolean(tip), (el) => el.tooltip(tip ?? ""))
      .when(Boolean(action), (el) => el.cursor_pointer().hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click(() => run("mod.open", { name: action })));
    const icon = (name, color) => svg("mods/workspace-chrome/" + name + ".svg").size(12).flex_none().text_color(color ?? t.dim);
    const hint = (action, what) => {
      const k = keyText(action);
      if (!k) return div();
      return h_flex().id("b-hint-" + what).flex_none().h(20).px(4).gap(5).items_center().rounded(5).cursor_pointer()
        .hover((s) => s.bg(t.hover)).on_click(() => run("mod.open", { name: action.split(":")[1] }))
        .child(keycap(t, k))
        .child(div().text_color(t.dim).child(what));
    };
    const project = d?.project || space?.name || "~";
    const branch = d?.branch || space?.branch;
    const esperan = blocked + waiting;
    const here = focused()?.terminal;
    const id = here ? terminals().find((x) => x.address === here)?.labels?.["bk.id"] : null;
    return h_flex().id("bk-barra").size_full().pl(10).pr(8).gap(2).items_center().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.5).text_color(t.muted)
      .child(seg("b-project", "bk-new", "Proyecto de la terminal que mirás · abrir otro")
        .child(id ? keycap(t, id, true) : div().size(7).rounded_full().bg(t.accent))
        .child(div().font_medium().text_color(t.foreground).child(project)))
      .when(Boolean(branch), (el) => el.child(seg("b-branch", "bk-changes", "Rama y cambios sin commitear").child(icon("git-branch")).child(div().max_w(260).truncate().child(branch ?? ""))
        .when(Boolean(d?.dirty), (x) => x.child(div().text_color(t.blocked).child("±" + d.dirty)))))
      .when(Boolean(d?.account || d?.email), (el) => el.child(seg("b-account", null, `Cuenta de Claude de esta terminal${d?.account ? ` (bk account ${d.account})` : ""}`)
        .child(svg("mods/bk-barra/cuenta.svg").size(12).flex_none().text_color(d?.account ? t.working : t.dim))
        .when(Boolean(d?.account), (x) => x.child(div().font_medium().text_color(t.working).child(d.account)))
        .when(Boolean(d?.email), (x) => x.child(div().max_w(240).truncate().text_color(t.dim).child(d.email)))))
      .child(div().flex_1())
      .when(esperan > 0, (el) => el.child(seg("b-wait", "bk-tasks", "Lo que espera por vos").bg(al(t.blocked, "1f")).child(mark(t, "blocked"))
        .child(div().font_medium().text_color(t.blocked).child(esperan + (esperan === 1 ? " te espera" : " te esperan")))))
      .when(done > 0, (el) => el.child(seg("b-done", "bk-next", "Terminaron y todavía no los miraste").child(mark(t, "done")).child(div().text_color(t.done).child(done + (done === 1 ? " listo" : " listos")))))
      .when(working > 0, (el) => el.child(seg("b-work", "bk-agents", "Agentes trabajando").child(mark(t, "working")).child(div().text_color(t.working).child(working + " trabajando"))))
      .when(esperan + done + working === 0, (el) => el.child(seg("b-quiet", "bk-agents", "Agentes").child(mark(t, "idle")).child(list.length + (list.length === 1 ? " agente" : " agentes"))))
      .when(d?.cost_today != null, (el) => el.child(seg("b-cost", "bk-stats", "Uso de hoy").child(div().text_color(t.dim).child("hoy")).child(human(d?.tokens_today ?? 0) + " · $" + (d?.cost_today ?? 0).toFixed(2))))
      .when(Boolean(d?.song?.playing), (el) => el.child(seg("b-song", "bk-song", "Radio").child(div().text_color(t.accent).child("♪")).child(div().max_w(180).truncate().child(d?.song?.title || d?.song?.station || "radio"))))
      .when(Boolean(d?.focus), (el) => el.child(seg("b-focus", null, "Foco").child(div().text_color(t.blocked).child("◷")).child((d?.focus?.label ?? "foco") + " " + (d?.focus?.left_min ?? 0) + " min")))
      .child(div().w(4))
      .child(hint("mod.open:bk-palette", "comandos"))
      .child(hint("mod.open:bk-keys", "teclas"));
  }
}
