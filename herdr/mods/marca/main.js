// La cabecera de la barra izquierda de bk-lavanda (el barrilete de la marca, que cambia según haya quien te
// espere, quien trabaje o nadie; tus accesos directos; buscar; plegar la barra) y, con props.footer, su pie de una
// línea (ajustes, aspecto, agregar una máquina). Con props.accesos, el popup de los accesos (accesos.js).
// Nació como clon de workspace-chrome de Herdr 0.1.15.

import { View, div, image, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { theme, run, props, window, shared, setShared, updates, layout, agents, openOverlay } from "herdr";
import { find, narrow, iconButton, tilde } from "./kit.js";
import { KEY, Gestor, readList, add, normalize, openTarget, face, popupHeight } from "./accesos.js";

// Al riel (en macOS, con lugar para los botones de la ventana) o de vuelta al ancho que tenía.
function toggleSidebar() {
  const width = find(layout(), "sidebar")?.size?.px;
  if (!narrow()) setShared("sidebar.width", width);
  setShared("sidebar.collapsed", !narrow());
  run("layout.resize", { id: "sidebar", px: narrow() ? (shared("sidebar.width") ?? 288) : window()?.platform === "macos" ? 76 : 44 });
}

const TILE = 26;   // un acceso: 24 px y el espacio entre botones

export default class Marca extends View {
  init(_props, cx) {
    if (props()?.accesos) { this.gestor = new Gestor(cx); return; }
    if (props()?.footer) return;
    this.hovered = false;
    if (shared(KEY) == null) cx.spawn(async () => { const l = await readList(); if (shared(KEY) == null) setShared(KEY, l); });
  }

  // El popup de los accesos, donde hiciste clic
  manage() {
    const n = (shared(KEY) ?? []).length;
    openOverlay({ mod: "bk-marca", kind: "popup", at: "pointer", width: 340, height: popupHeight(n + 1), props: { accesos: true } });
  }

  // Los accesos que entran entre la marca y la lupa; si no entran todos, el último lugar es un +N que abre la lista.
  // El + para agregar se ve siempre si no hay ninguno, y al pasar por encima si ya hay (su lugar queda reservado:
  // que aparezca no corre a los demás).
  shortcuts(t, room) {
    const list = shared(KEY) ?? [];
    const plus = list.length === 0 || this.hovered;
    const slots = Math.floor(room / TILE) - 1;
    const over = list.length > slots;
    const shown = list.slice(0, over ? Math.max(0, slots - 1) : slots);
    const stop = (_e, cx) => cx.stop_propagation();
    const tile = (a, i) => div().id(`acc-${i}`).size(24).flex_none().flex().items_center().justify_center().rounded(6).cursor_pointer()
      .text_color(t.muted).hover((s) => s.bg(t.hover).text_color(t.foreground))
      .tooltip(`${a.name} · ${tilde(a.target)}`)
      .on_mouse_down("left", stop)
      .on_mouse_down("right", (_e, cx) => { cx.stop_propagation(); this.manage(); })
      .on_click((_e, cx) => { cx.stop_propagation(); openTarget(a.target); })
      .child(face(t, a));
    const rest = list.length - shown.length;
    return [
      ...(plus && slots >= 0 ? [iconButton(t, "acc-add", "mods/bk-marca/plus.svg", () => this.manage(), { tip: "Agregar un acceso directo: pegá una URL o una ruta, o soltá un archivo acá", stop: true, size: 14 })] : []),
      ...shown.map(tile),
      ...(over && slots >= 1 ? [div().id("acc-more").h(24).px(5).flex_none().flex().items_center().rounded(6).cursor_pointer()
        .text_size(11).text_color(t.dim).hover((s) => s.bg(t.hover).text_color(t.foreground))
        .tooltip(list.slice(shown.length).map((a) => a.name).join(" · "))
        .on_mouse_down("left", stop).on_click((_e, cx) => { cx.stop_propagation(); this.manage(); }).child(`+${rest}`)] : []),
    ];
  }

  footer(t, collapsed) {
    const ready = Boolean(updates()?.app?.ready);
    const dot = div().size(6).flex_none().rounded_full().bg(t.accent);
    if (collapsed) {
      return h_flex().size_full().bg(t.chrome).items_center().justify_center()
        .child(div().relative().child(iconButton(t, "settings", "mods/bk-marca/settings.svg", () => run("app.settings"), { tip: "Ajustes" }))
          .when(ready, (el) => el.child(dot.absolute().top(2).right(2))));
    }
    return h_flex().size_full().bg(t.chrome).pl(8).pr(8).pb(4).gap(2).items_center().text_size(12)
      .child(h_flex().id("settings").h(26).px(8).gap(8).flex_none().items_center().rounded(6).cursor_pointer().text_color(t.muted)
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click(() => run("app.settings"))
        .child(svg("mods/bk-marca/settings.svg").size(14).flex_none())
        .child("Ajustes")
        .when(ready, (el) => el.child(dot).tooltip("Hay una actualización lista")))
      .child(div().flex_1())
      .child(iconButton(t, "theme", "mods/bk-marca/theme.svg", () => run("mod.open", { name: "bk-look" }), { tip: "Aspecto: tema, fuente, tamaño" }))
      .child(iconButton(t, "machine", "mods/bk-marca/plus.svg", () => run("mod.open", { name: "machine-add" }), { tip: "Agregar una máquina" }));
  }

  render(cx) {
    const t = theme();
    if (props()?.accesos) return this.gestor.render(cx);
    const collapsed = narrow();
    if (props()?.footer) return this.footer(t, collapsed);
    const w = window();
    const lights = w?.platform === "macos" && !w?.fullscreen;
    // En el riel de macOS los botones de la ventana ocupan la fila; la barra se abre desde abajo de la lista.
    if (collapsed) {
      return h_flex().size_full().bg(t.chrome).items_center().justify_center()
        .when(!lights, (el) => el.child(iconButton(t, "sidebar-toggle", "mods/bk-marca/sidebar.svg", toggleSidebar, { tip: "Abrir la barra", stop: true, size: 15 })));
    }
    const list = agents();
    const waiting = list.filter((a) => a.status === "blocked").length;
    const working = list.filter((a) => a.status === "working").length;
    // Silueta de barrilete legible a 20 px; el fondo indica si alguien espera. Sin animación.
    const mood = waiting ? "wait" : working ? "fly" : "rest";
    const tip = waiting ? `Barrilete Kit · ${waiting === 1 ? "1 agente te espera" : waiting + " agentes te esperan"}` : working ? `Barrilete Kit · ${working} trabajando` : "Barrilete Kit · todo quieto";
    // Arrastrada a un ancho intermedio, la fila deja primero el nombre y después la lupa.
    const width = find(layout(), "sidebar")?.size?.px ?? 288;
    // Lo que queda entre la marca (24 + 8, y el nombre) y los botones de la derecha
    const room = width - (lights ? 80 : 14) - 8 - 32 - (width >= 208 ? 30 : 0) - (width >= 184 ? 26 : 0) - 26;
    return h_flex().id("brand").size_full().bg(t.chrome).pl(lights ? 80 : 14).pr(8).gap(2).items_center()
      .on_hover((hovered, cx) => { if (this.hovered !== hovered) { this.hovered = hovered; cx.notify(); } })
      .on_drop((e) => add((e.paths ?? []).map((p) => normalize(p)).filter(Boolean)).catch(() => {}))
      .child(h_flex().flex_1().min_w(0).gap(8).items_center().tooltip(tip)
        .child(div().size(24).flex_none().rounded(7).bg(mood === "wait" ? t.blocked : t.accent).flex().items_center().justify_center()
          .child(image(`mods/bk-marca/bk-${mood}.svg`).size(20)))
        .when(width >= 208, (el) => el.child(div().text_size(13).font_bold().text_color(t.foreground).child("BK"))))
      .children(this.shortcuts(t, room))
      .when(width >= 184, (el) => el.child(iconButton(t, "search", "mods/bk-marca/search.svg", () => run("mod.open", { name: "picker" }), { tip: "Buscar", stop: true, size: 15 })))
      .child(iconButton(t, "sidebar-toggle", "mods/bk-marca/sidebar.svg", toggleSidebar, { tip: "Plegar la barra", stop: true, size: 15 }));
  }
}
