// El diálogo de una carpeta o de un espacio de la barra (props { editar: "c:<id>" | "e:<clave>" }): el nombre (solo
// la carpeta; un espacio se renombra con su menú), el color y la imagen. Cada cambio se aplica al momento y se ve
// en la barra; Enter o Esc cierran. La imagen: soltá el archivo encima o pegá su ruta (Herdr no tiene selector de
// archivos); bk _logo la copia adonde Herdr la puede mostrar.

import { div, svg } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { shared, setShared, props, closeOverlay, exec } from "herdr";
import { ICONS } from "./kit.js";
import * as E from "./espacios.js";
import { avatar, paint } from "./lista.js";

const bin = () => shared("bk.bin") || "bk";

export class Editar {
  constructor(cx) {
    this.ref = props().editar;
    this.error = null;
    this.busy = false;
    const x = this.target();
    const close = () => closeOverlay(props().overlay);
    if (this.isFolder()) {
      this.name = InputState.new({ placeholder: "Nombre de la carpeta", value: x?.nombre ?? "" });
      this.name.on("change", () => this.apply((st) => E.renameFolder(st, this.ref.slice(2), this.name.value())));
      this.name.on("submit", close);
    }
    this.hex = InputState.new({ placeholder: "#rrggbb", value: x?.color?.startsWith?.("#") ? x.color : "" });
    this.hex.on("change", (_e, cx) => {
      const v = this.hex.value().trim();
      if (/^#[0-9a-fA-F]{6}$/.test(v)) this.apply((st) => E.setLook(st, this.ref, { color: v }));
      cx.notify();
    });
    this.hex.on("submit", close);
    this.path = InputState.new({ placeholder: "Soltá una imagen acá o pegá su ruta" });
    this.path.on("submit", (_e, cx) => this.setImage(this.path.value(), cx));
    const first = this.name ?? this.hex;
    first.focus();
    cx.timer.after(30, () => first.focus());
  }

  isFolder() { return this.ref.startsWith("c:"); }
  state() { return E.clean(shared(E.KEY)); }
  target() {
    const st = this.state();
    return this.isFolder() ? st.carpetas[this.ref.slice(2)] : st.espacios[this.ref.slice(2)];
  }
  apply(change) {
    const st = this.state(), next = change(st);
    if (next !== st) setShared(E.KEY, next);
  }

  setImage(src, cx) {
    src = String(src ?? "").trim();
    if (!src || this.busy) return;
    this.busy = true;
    this.error = null;
    cx.spawn(async (cx) => {
      try {
        const r = await exec(bin(), ["_logo", src], { timeout: 8000 });
        if (r.code !== 0) throw new Error(r.stderr.trim().split("\n").pop() || "no pude copiar la imagen");
        this.apply((st) => E.setLook(st, this.ref, { imagen: r.stdout.trim() }));
        this.path.set_value("");
      } catch (e) { this.error = String(e?.message ?? e); }
      this.busy = false;
      cx.notify();
    });
    cx.notify();
  }

  render(t) {
    const x = this.target();
    const close = () => closeOverlay(props().overlay);
    const root = v_flex().id("bk-editar").size_full().min_h(0).p(14).gap(12).bg(t.popover).text_size(12.5)
      .on_key_down((e) => { if (e.key === "escape") close(); });
    if (!x) return root.child(div().text_color(t.dim).child("Eso ya no está en la lista."));
    const folder = this.isFolder();
    const name = folder ? x.nombre : this.ref.slice(2);
    const st = this.state();
    const own = x.color;                                                    // lo que eligió; null: sin color propio
    const shownColor = paint(t, folder ? own : E.colorOf(st, this.ref.slice(2))) ?? t.accent;
    const label = (text) => div().text_size(10.5).font_semibold().text_color(t.accent).child(text);
    const field = (state) => h_flex().h(30).px(9).items_center().rounded(7).border_1().border_color(t.input).bg(t.background)
      .child(Input.new(state).flex_1().h_full().text_size(12.5).text_color(t.foreground));
    const swatch = (c) => div().id(`color-${c}`).size(22).flex_none().rounded_full().cursor_pointer().bg(paint(t, c) ?? t.accent)
      .border(2).border_color(own === c ? t.foreground : "#00000000")
      .tooltip(c)
      .on_click((_e, cx) => { this.hex.set_value(""); this.apply((s) => E.setLook(s, this.ref, { color: c })); cx.notify(); });
    const none = div().id("color-none").size(22).flex_none().rounded_full().cursor_pointer().flex().items_center().justify_center()
      .border_1().border_color(own === null ? t.foreground : t.input).text_color(t.dim)
      .tooltip(folder ? "Sin color: uno fijo por la carpeta" : "Sin color propio: el de su carpeta")
      .on_click((_e, cx) => { this.hex.set_value(""); this.apply((s) => E.setLook(s, this.ref, { color: null })); cx.notify(); })
      .child(svg(`${ICONS}x.svg`).size(11));
    return root
      // Soltar un archivo en cualquier parte del diálogo
      .on_drop((e, cx) => this.setImage(e.paths?.[0], cx))
      .child(h_flex().gap(10).items_center()
        .child(avatar(t, { imagen: x.imagen, color: shownColor, name, size: 28 }))
        .child(v_flex().flex_1().min_w(0)
          .child(div().truncate().font_semibold().text_size(13).text_color(t.foreground).child(name))
          .child(div().text_size(11).text_color(t.dim).child(folder ? "Carpeta" : "Espacio"))))
      .when(folder, (el) => el.child(v_flex().gap(5).child(label("NOMBRE")).child(field(this.name))))
      .child(v_flex().gap(6).child(label("COLOR"))
        .child(h_flex().gap(6).items_center().children([...E.COLORS.map(swatch), none]))
        .child(h_flex().gap(8).items_center()
          .child(div().w(110).child(field(this.hex)))
          .child(div().flex_1().text_size(11).text_color(t.dim).child(own?.startsWith?.("#") ? "color propio" : "o un color exacto"))))
      .child(v_flex().gap(5).child(label("IMAGEN"))
        .child(h_flex().gap(8).items_center()
          .child(div().flex_1().min_w(0).child(field(this.path)))
          .when(Boolean(x.imagen), (el) => el.child(div().id("img-off").flex_none().px(8).h(26).flex().items_center().rounded(6).cursor_pointer()
            .text_size(11.5).text_color(t.muted).bg(t.raised).hover((s) => s.text_color(t.foreground))
            .on_click((_e, cx) => { this.apply((s) => E.setLook(s, this.ref, { imagen: null })); cx.notify(); })
            .child("Quitar"))))
        .child(div().text_size(11).text_color(this.error ? t.blocked : t.dim)
          .child(this.error ?? (this.busy ? "Copiando…" : "png, jpg, webp o svg, hasta 1 MB. Enter la pone."))));
  }
}
