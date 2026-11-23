// La barra izquierda de bk-lavanda: los espacios (sueltos o en carpetas: lista.js), las épicas (sección ÉPICAS; con
// props { epic }, este mod es su popup de detalle) y, debajo, los agentes con sus sub-agentes (quién lanzó a
// quién). Cada agente lleva el chip con su número fijo de ventana (alt+N), su título, dónde está y la marca
// de estado, la misma que usan las pestañas, la cabecera de cada pane y la barra de abajo.
// Dos vistas (el botón de la derecha de "AGENTES"): por prioridad (te esperan, listos, trabajando, quietos)
// o por espacio. Angosta (riel), solo los chips con su marca.
// Nació como clon del `agents` de Herdr 0.1.15: el orden, los pins y el árbol de sub-agentes son los suyos.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, terminals, focused, panes, spaces, run, theme, shared, setShared, setAgentOrder, openOverlay, closeOverlay, props, window, layout, exec, home, settings } from "herdr";
import { ICONS, PROSE, RANK, al, find, narrow, ago, ids, said, picto, mark, keycap, iconButton, rule } from "./kit.js";
import { Lista, menu } from "./lista.js";
import { Editar } from "./editar.js";

const SUBS_EVERY = 4000;
const EPIC_EVERY = 60000;   // bk _epica guarda lo de GitHub unos minutos: esto solo vuelve a leer su caché
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
// Un turno que terminó dejando comandos en segundo plano (tests, CI…) no está listo: Herdr ve el chat quieto y lo
// marca listo o quieto; el hook de bk lo anota (bk _subagents, "background": terminal → cuántos). Va con su marca y su
// sección (En 2º plano, debajo de Trabajando), con «N en 2º plano» en su segunda línea. Si Herdr ve otra cosa
// (te espera, trabajando), manda Herdr.
const withBackground = (list, bg) => list.map((a) => {
  const n = bg?.[a.address];
  return typeof n === "number" && (a.status === "done" || a.status === "idle") ? { ...a, status: "background", bgCount: n } : a;
});
// Sin cuenta (0: el hook la perdió), sin número.
const bgText = (a) => (typeof a.bgCount !== "number" ? null : a.bgCount > 0 ? `${a.bgCount} en 2º plano` : "en 2º plano");
const SORTS = [
  { id: "priority", label: "Por prioridad", icon: "clock" },
  { id: "grouped", label: "Por espacio", icon: "layers" },
];
const sortOf = () => SORTS.find((s) => s.id === shared("agents.sort")) ?? SORTS[0];
const SECTION = { 4: "Te esperan", 3: "Listos", 2: "Trabajando", 1.5: "En 2º plano", 1: "Quietos" };
const SECTION_STATUS = { 4: "blocked", 3: "done", 2: "working", 1.5: "working" };
// De dónde sale la épica de cada chat: la carpeta y la rama de su pane, su nombre (#123 en bk.name o bk.autotitle) y
// su terminal (bk lee en su conversación de Claude el worktree donde trabajó). bk _epica (lib/herdr_epica.py) saca de ahí el issue y su épica.
function epicQueries() {
  const byPane = new Map(panes().map((p) => [p.pane, p]));
  const labels = new Map(terminals().map((x) => [x.address, x.labels ?? {}]));
  return agents().map((a) => {
    const p = byPane.get(a.pane) ?? {};
    const l = labels.get(a.address) ?? {};
    return { address: a.address, space: a.space, q: [p.cwd ?? "", p.branch ?? "", [l["bk.name"], l["bk.autotitle"], p.title ?? a.title].filter(Boolean).join(" "), a.address] };
  });
}

// Las épicas (sección ÉPICAS y su popup). Cada sub-issue es: hecho, con agente (un chat trabaja en él), libre (abierto
// y sin bloqueos abiertos) o bloqueado. La barra va en ese orden, un segmento por sub-issue.
const ekey = (x) => `${x.repo}#${x.number}`;
const short = (repo) => String(repo).split("/").pop().split("-").pop();
// El número de un sub-issue: con su repo delante si la épica cruza repos (kit#324, workspace#11)
const num = (s, cross) => (cross ? `${short(s.repo)}#${s.number}` : `#${s.number}`);
const KINDS = ["done", "work", "free", "wait"];
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
// La épica en filas y números. chats: [{ address, pane, issue, repo }] de los agentes vivos. null sin sub-issues
// (bk no los pudo traer todavía): la tarjeta usa done/total.
function plan(e, chats) {
  if (!Array.isArray(e?.subs)) return null;
  const agentOf = new Map();
  for (const c of chats) if (c.issue && c.repo && !agentOf.has(`${c.repo}#${c.issue}`)) agentOf.set(`${c.repo}#${c.issue}`, c);
  const rows = e.subs.map((s) => {
    const open = s.state === "open";
    const agent = open ? agentOf.get(ekey(s)) ?? null : null;
    const blocked_by = open ? s.blocked_by ?? [] : [];
    return { ...s, blocked_by, key: ekey(s), kind: !open ? "done" : agent ? "work" : blocked_by.length ? "wait" : "free", agent };
  });
  const open = new Set(rows.filter((r) => r.kind !== "done").map((r) => r.key));
  // Quién espera a quién, entre los abiertos de la épica
  const waiters = new Map();
  for (const r of rows) for (const b of r.blocked_by) if (open.has(ekey(b))) waiters.set(ekey(b), [...(waiters.get(ekey(b)) ?? []), r.key]);
  // Lo que destraba cada uno: los abiertos que lo esperan, directa o indirectamente (una vuelta no cuenta dos veces)
  const below = (k) => {
    const seen = new Set(), todo = [k];
    while (todo.length) for (const w of waiters.get(todo.pop()) ?? []) if (w !== k && !seen.has(w)) { seen.add(w); todo.push(w); }
    return seen.size;
  };
  for (const r of rows) r.unblocks = r.kind === "done" ? 0 : below(r.key);
  // El camino más largo de esperas (si hay vueltas, se cortan)
  const memo = new Map();
  const longest = (k, path) => {
    if (memo.has(k)) return memo.get(k);
    let best = [];
    for (const w of waiters.get(k) ?? []) {
      if (path.has(w)) continue;
      path.add(w);
      const p = longest(w, path);
      path.delete(w);
      if (p.length > best.length) best = p;
    }
    const out = [k, ...best];
    memo.set(k, out);
    return out;
  };
  const path = [...open].map((k) => longest(k, new Set([k]))).reduce((m, p) => (p.length > m.length ? p : m), []);
  const repos = [...new Set([e.repo, ...rows.map((r) => r.repo)])].filter((r) => rows.some((x) => x.repo === r))
    .map((repo) => ({ repo, done: rows.filter((r) => r.repo === repo && r.kind === "done").length, total: rows.filter((r) => r.repo === repo).length }));
  const cross = repos.length > 1;
  const by = Object.fromEntries(KINDS.map((k) => [k, rows.filter((r) => r.kind === k)]));
  const label = new Map(rows.map((r) => [r.key, num(r, cross)]));
  return { rows, by, cross, repos, path: path.length > 1 ? path.map((k) => label.get(k)) : [], label };
}
// La línea de la tarjeta: qué corre y qué destraba, o qué está libre. Partes [texto, color].
function nextLine(t, p) {
  const { work, free, wait } = p.by;
  if (!work.length && !free.length && !wait.length) return [["completa", t.done]];
  const out = [];
  if (work.length) {
    const w = work[0];
    out.push(["ahora ", t.dim], [`${num(w, p.cross)} · ${w.agent.address}${work.length > 1 ? ` +${work.length - 1}` : ""}`, t.working]);
    if (w.unblocks) out.push([` · destraba ${w.unblocks}`, t.dim]);
    out.push([free.length ? ` · ${plural(free.length, "libre", "libres")}` : " · nada libre", free.length ? t.accent : t.dim]);
  } else if (free.length) out.push([`${plural(free.length, "libre", "libres")}: ${free.map((r) => num(r, p.cross)).join(", ")}`, t.accent]);
  else out.push([`nada libre · ${plural(wait.length, "bloqueado", "bloqueados")}`, t.dim]);
  return out;
}
// El popup de una épica: ancho fijo, alto justo para sus filas (HECHOS plegado) y la confirmación de lanzar.
// 880 y no 520: con 520 se cortaban los títulos y el camino más largo (2026-11-17). mods/bk usa el mismo ancho.
const POP_W = 880;
// El selector de alt+p (mods/bk lo abre con este alto: encabezado + una fila por épica)
const PICK = { head: 34, row: 30, pad: 10 };
const POP = { head: 104, group: 36, row: 36, confirm: 50, foot: 44, max: 720, char: 7.2, pad: 22 };
function popHeight(p) {
  if (!p) return 200;
  const groups = ["work", "free", "wait"].filter((k) => p.by[k].length).length + (p.by.done.length ? 1 : 0);
  const rows = p.by.work.length + p.by.free.length + p.by.wait.length;
  return Math.min(POP.max, POP.head + groups * POP.group + rows * POP.row + (p.by.free.length ? POP.confirm : 0) + POP.foot + 8);
}
// La marca de un sub-agente. tests/test_herdr_subagents.sh evalúa tree() y subRow() de este archivo sin sus
// imports (solo les pasa View, div, svg, h_flex, v_flex, agents, run y home): por eso subRow no usa del kit
// nada más que esto, y sin kit dibuja un hueco.
const subMark = (t, st) => (typeof mark === "function" ? mark(t, st, 12) : div());

export default class Agents extends View {
  init(_props, cx) {
    if (props()?.sortMenu) return;
    if (props()?.editar) { this.editar = new Editar(cx); return; }
    if (props()?.epic || props()?.epicPick) {
      this.at = 0;
      this.doneOpen = false;
      this.confirm = null;   // el sub-issue que espera el segundo ⏎ para lanzarse
      this.busy = null;
      this.errors = new Map();
      this.launched = new Set();
      this.handle = cx.focus_handle();
      this.handle.focus();
      // Abierto con clic, el foco vuelve a la terminal de abajo al soltar: se lo pide de nuevo (como bk-stats)
      cx.timer.after(300, () => this.handle.focus());
      return;
    }
    this.lista = new Lista();
    this.folded = new Set();
    this.openPrev = new Set();   // las líneas «antes» desplegadas (plegadas por defecto)
    this.claudeSubs = {};
    this.background = {};
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
          const data = JSON.parse(r.stdout);
          this.claudeSubs = data.by_terminal ?? {};
          this.background = data.background ?? {};
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
    // La épica de cada chat, y la última vista de cada espacio: si ninguno de sus chats tiene, queda esa (en gris),
    // guardada entre reinicios.
    this.chats = new Map();   // terminal → { issue, repo, epic } (solo los que tienen épica)
    this.lastEpics = JSON.parse(localStorage.getItem("epics") ?? "{}");
    this.lastAt = JSON.parse(localStorage.getItem("epicsAt") ?? "{}");   // espacio → cuándo un chat la tuvo (ms)
    this.epicKey = null;
    this.epicAt = 0;
    cx.timer.every(EPIC_EVERY, (cx) => { this.epicAt = 0; cx.notify(); });
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

  // Los chats que siguieron en otro por un handoff (etiqueta bk.from del nuevo, lib/herdr.sh): el mismo trabajo
  // en una sola fila. Devuelve { prev: nuevo → viejo, hidden: los viejos que van debajo de su nuevo }. Un viejo
  // fijado conserva su fila; si dos chats dicen venir del mismo, lo toma el primero de la lista; una cadena
  // que vuelve sobre sí misma (no debería pasar) se corta.
  lineage(list, labelsOf) {
    const live = new Map(list.map((a) => [a.address, a]));
    const prev = new Map();
    const taken = new Set();
    for (const a of list) {
      const from = labelsOf.get(a.address)?.["bk.from"];
      const old = from ? live.get(from) : null;   // uno que dice venir de sí mismo es una vuelta: se corta abajo
      if (!old || old.pinned || taken.has(from)) continue;
      let p = from, loop = false;
      while (p && !loop) { loop = p === a.address; p = prev.get(p); }
      if (loop) continue;
      prev.set(a.address, from);
      taken.add(from);
    }
    return { prev, hidden: taken };
  }

  // Pide las épicas de todos los chats en una llamada, si cambiaron los chats (o dónde están) o pasó EPIC_EVERY.
  // Una a la vez. Llamado al dibujar.
  epicRefresh(cx) {
    const qs = epicQueries();
    const key = JSON.stringify(qs.map((x) => x.q));
    if (this.epicBusy || (key === this.epicKey && Date.now() - this.epicAt < EPIC_EVERY)) return;
    this.epicBusy = true;
    this.epicKey = key;
    this.epicAt = Date.now();
    cx.spawn(async (cx) => {
      try {
        const r = qs.length ? await exec(bin(), ["_epica", "--json", JSON.stringify(qs.map((x) => x.q))], { timeout: 30000 }) : { code: 0, stdout: "[]" };
        // Si bk falla, no se sabe de quién es cada una: quedan las últimas vistas, en gris
        const out = r.code === 0 ? JSON.parse(r.stdout) : [];
        this.chats = new Map(qs.map((x, i) => [x.address, out[i]?.epic ? out[i] : null]));
        let dirty = false;
        for (const x of qs) {
          const e = this.chats.get(x.address)?.epic;
          if (e && JSON.stringify(e) !== JSON.stringify(this.lastEpics[x.space])) { this.lastEpics[x.space] = e; dirty = true; }
          if (e) this.lastAt[x.space] = Date.now();
        }
        if (dirty) localStorage.setItem("epics", JSON.stringify(this.lastEpics));
        localStorage.setItem("epicsAt", JSON.stringify(this.lastAt));
      } catch { this.chats = new Map(); } finally {
        this.epicBusy = false;
        cx.notify();
      }
    });
  }

  // Las épicas de la sección: las de los chats, sin repetir; y una gris (stale): de los espacios cuyos chats ya no
  // tienen ninguna, la última vista en el que la tuvo más recientemente. Cada una con sus chats vivos, para saber qué
  // sub-issue tiene agente. Orden: primero las que tienen algo LIBRE (donde se puede actuar), después las demás en
  // curso, al final la gris; dentro de cada grupo, el orden de los agentes.
  epicList() {
    const live = agents();
    const byPane = new Map(live.map((a) => [a.address, a.pane]));
    const chats = [...this.chats].filter(([addr, c]) => c && byPane.has(addr)).map(([address, c]) => ({ address, pane: byPane.get(address), issue: c.issue, repo: c.repo }));
    const out = new Map();
    for (const a of live) {
      const e = this.chats.get(a.address)?.epic;
      if (e && !out.has(ekey(e))) out.set(ekey(e), { e, stale: false });
    }
    const gone = spaces().map((s) => s.id).filter((id) => {
      const last = this.lastEpics[id];
      return last && !out.has(ekey(last)) && !live.some((a) => a.space === id && this.chats.get(a.address)?.epic);
    });
    const newest = gone.sort((a, b) => (this.lastAt[b] ?? 0) - (this.lastAt[a] ?? 0))[0];
    if (newest) out.set(ekey(this.lastEpics[newest]), { e: this.lastEpics[newest], stale: true });
    const rank = (x) => (x.stale ? 2 : (plan(x.e, chats)?.by.free.length ?? 0) > 0 ? 0 : 1);
    return [...out.values()].map((x, i) => ({ x, i })).sort((a, b) => rank(a.x) - rank(b.x) || a.i - b.i)
      .map(({ x }) => ({ ...x, key: ekey(x.e), chats: x.stale ? [] : chats }));
  }

  // Lo que necesita el popup (otra copia de este mod) y alt+p (mods/bk): en shared "bk.epics". Solo si cambió:
  // setShared redibuja todos los mods.
  share(list) {
    const val = {
      epics: Object.fromEntries(list.map((x) => [x.key, { e: x.e, stale: x.stale, chats: x.chats, height: popHeight(plan(x.e, x.chats)) }])),
      pickHeight: PICK.head + list.length * PICK.row + PICK.pad,
      byTerminal: Object.fromEntries([...this.chats].filter(([, c]) => c?.epic).map(([addr, c]) => [addr, ekey(c.epic)])),
    };
    const json = JSON.stringify(val);
    if (json !== this.sharedJson) { this.sharedJson = json; setShared("bk.epics", val); }
  }

  // La barra segmentada: un segmento por sub-issue (hecho, con agente, libre, bloqueado). Sin sub-issues, done/total.
  segs(t, e, p, stale, h = 6) {
    const colors = p ? KINDS.flatMap((k) => p.by[k].map(() => ({ done: t.done, work: t.working, free: t.accent, wait: t.raised })[k]))
      : [...Array(e.total || 0)].map((_, i) => (i < e.done ? t.done : t.raised));
    return h_flex().h(h).gap(2).flex_none().children(colors.map((c) => div().flex_1().h(h).rounded(2).bg(stale && c !== t.raised ? t.dim : c)));
  }

  // La tarjeta de una épica: #N título k/n, la barra, qué corre o qué está libre, y los repos si cruza. Clic: el popup.
  epicCard(t, x) {
    const { e, stale } = x;
    const p = plan(e, x.chats);
    const line = stale ? [["la última vista · ningún chat la tiene ahora", t.dim]] : p ? nextLine(t, p) : [];
    return v_flex().id(`epic-${x.key}`).flex_none().mr(4).my(1).pl(10).pr(8).py(7).gap(5).rounded(8).bg(t.surface ?? t.raised).cursor_pointer()
      .hover((el) => el.bg(t.hover))
      .tooltip(`${e.repo}#${e.number} ${e.title}${stale ? " · la última vista: ningún chat la tiene ahora" : ""} · clic: el detalle`)
      .on_mouse_down("left", (ev) => { this.clickY = ev.position?.y ?? null; })
      .on_click(() => this.openEpic(x.key))
      .child(h_flex().gap(6).items_center().text_size(11.5)
        .child(div().flex_none().text_size(9.5).font_semibold().text_color(stale ? t.dim : t.accent).child(`#${e.number}`))
        .child(div().flex_1().min_w(0).truncate().text_color(stale ? t.dim : t.foreground).child(e.title))
        .child(div().flex_none().text_size(10.5).text_color(t.dim).child(`${e.done}/${e.total}`)))
      .child(this.segs(t, e, p, stale))
      .when(line.length > 0, (el) => el.child(h_flex().min_w(0).text_size(10.5).whitespace_nowrap().overflow_hidden()
        .children(line.map(([s, c]) => div().flex_none().text_color(stale ? t.dim : c).child(s)))))
      .when(Boolean(p?.cross) && !stale, (el) => el.child(div().truncate().text_size(10).text_color(t.dim)
        .child(p.repos.map((r) => `${short(r.repo)} ${r.done}/${r.total}`).join(" · "))));
  }

  // El popup junto a la tarjeta (a la derecha de la barra, a la altura del clic)
  openEpic(key) {
    const h = shared("bk.epics")?.epics?.[key]?.height ?? 400;
    const x = (narrow() ? 44 : find(layout(), "sidebar")?.size?.px ?? 288) + 6;
    const y = Math.max(8, (this.clickY ?? 120) - 30);
    openOverlay({ mod: "bk-agentes", kind: "popup", width: POP_W, height: h, at: { x, y }, props: { epic: key } });
  }

  // El popup: la épica entera, AHORA / LIBRES / BLOQUEADOS / HECHOS (plegado). ↑↓ mueven; ⏎ va al agente (AHORA) o
  // lanza un libre (con confirmación: bk run N en la carpeta de su repo, suelto con bk _do); g GitHub; esc cierra.
  epicPopup(t) {
    const key = props().epic;
    const x = shared("bk.epics")?.epics?.[key];
    const close = () => closeOverlay(props().overlay);
    if (!x) return v_flex().id("epic-pop").track_focus(this.handle).size_full().p(16).bg(t.popover).text_size(12.5).text_color(t.dim)
      .on_key_down((ev) => { if (ev.key === "escape") close(); })
      .child(`No tengo los datos de ${key}: la barra todavía no los trajo.`);
    const { e } = x;
    const p = plan(e, x.chats);
    const rows = p ? [...p.by.work, ...p.by.free, ...p.by.wait, ...(this.doneOpen ? p.by.done : [])] : [];
    this.at = Math.min(this.at, Math.max(0, rows.length - 1));
    const sel = rows[this.at];
    const gh = (r) => exec("open", [`https://github.com/${r.repo}/issues/${r.number}`]);
    // ⏎ (o clic): en AHORA va al agente; en un libre pide confirmar el lanzamiento. GitHub es solo g.
    const enter = (r) => {
      if (r?.agent) { close(); return run("pane.focus", { terminal: r.agent.address }); }
      if (r?.kind === "free" && canLaunch(r) && !this.launched.has(r.key)) this.confirm = r.key;
    };
    // Se lanza solo en un repo con carpeta y con un kit que bk sabe usar (nolaunch: bk _epica dice por qué no)
    const noWhy = (r) => e.nolaunch?.[r.repo] ?? "";
    const canLaunch = (r) => Boolean(e.dirs?.[r.repo]) && !noWhy(r);
    const launch = (r, cx) => {
      const dir = e.dirs?.[r.repo];
      if (!canLaunch(r) || this.busy) return;
      this.busy = r.key;
      this.errors.delete(r.key);
      cx.spawn(async (cx) => {
        try {
          // bk _do lo deja corriendo suelto (sigue aunque se cierre el popup) y avisa al terminar, con el error si falla
          const res = await exec(bin(), ["_do", "--cwd", dir, "--title", `Lanzar #${r.number}`, "--", "run", String(r.number)], { cwd: dir, timeout: 15000 });
          if (res.code !== 0) this.errors.set(r.key, (res.stderr || res.stdout || "").trim().split("\n").filter(Boolean).pop() || `bk run salió con ${res.code}`);
          else this.launched.add(r.key);
        } catch (err) { this.errors.set(r.key, String(err?.message ?? err)); }
        this.busy = null;
        this.confirm = null;
        cx.notify();
      });
    };
    const home_ = home();
    const where = (r) => (e.dirs?.[r.repo] ?? "").replace(home_, "~");
    // La columna de las etiquetas, al ancho de la más larga (kit#324, workspace#12): los títulos arrancan parejos
    const labelW = Math.max(48, Math.ceil(Math.max(0, ...[...(p?.label.values() ?? [])].map((l) => String(l).length)) * POP.char) + 2);
    const indent = POP.pad + labelW + 12;
    const row = (r) => {
      const i = rows.indexOf(r);
      const on = i === this.at;
      const err = this.errors.get(r.key);
      const right = r.kind === "work" ? [div().text_color(t.working).child(r.agent.address)]
        : r.kind === "wait" ? [div().text_color(t.dim).child(`espera ${r.blocked_by.map((b) => p.label.get(ekey(b)) ?? `${short(b.repo)}#${b.number}`).join(", ")}`)]
        : r.kind === "free" ? [this.busy === r.key ? div().text_color(t.dim).child("lanzando…")
          : this.launched.has(r.key) ? div().text_color(t.done).tooltip("bk avisa cuando el agente arranca, o si falló").child("lanzado")
          : on && noWhy(r) ? div().id(`nolaunch-${r.key}`).text_color(t.blocked).tooltip(noWhy(r)).child("no se puede lanzar")
          : on && e.dirs?.[r.repo] ? div().id(`launch-${r.key}`).px(8).py(2).rounded(5).bg(t.accent).text_color(t.accent_foreground ?? t.background).font_medium().cursor_pointer()
            .on_click((_ev, cx) => { cx.stop_propagation(); this.confirm = r.key; cx.notify(); }).child("Lanzar")
          : on ? div().text_color(t.dim).child(`sin carpeta para ${short(r.repo)}`) : div()]
        : [];
      const main = h_flex().id(`er-${r.key}`).h(POP.row).flex_none().px(POP.pad).gap(12).items_center().cursor_pointer()
        .when(on, (el) => el.bg(t.selected).border_l(2).border_color(t.accent))
        .hover((el) => el.bg(on ? t.selected : t.hover))
        .on_hover((h, cx) => { if (h && this.at !== i) { this.at = i; cx.notify(); } })
        .on_click((_ev, cx) => { this.at = i; enter(r); cx.notify(); })
        .tooltip(`${r.repo}#${r.number} ${r.title}${r.unblocks ? ` · destraba ${r.unblocks}` : ""}`)
        .child(div().flex_none().w(labelW).text_size(11).text_color(t.dim).child(p.label.get(r.key)))
        .child(div().flex_1().min_w(0).truncate().text_color(r.kind === "wait" || r.kind === "done" ? t.dim : t.foreground).child(r.title))
        .child(h_flex().flex_none().gap(6).items_center().text_size(11).children(right));
      const extra = [];
      // Elegido en un repo donde no se puede lanzar: el motivo entero, debajo y en los renglones que haga falta (lo mismo que diría bk run)
      if (on && r.kind === "free" && noWhy(r) && !err) extra.push(div().id("epic-nolaunch").mx(POP.pad).ml(indent).mb(6).text_size(11).line_height(1.4).text_color(t.blocked).child(noWhy(r)));
      if (err) extra.push(div().id("epic-err").mx(POP.pad).ml(indent).mb(6).text_size(11).line_height(1.4).text_color(t.blocked).child(err));
      if (this.confirm === r.key) {
        // Un solo renglón: el comando y su carpeta a la izquierda, los botones a la derecha
        extra.push(h_flex().id("epic-confirm").mx(POP.pad).ml(indent).mb(6).px(10).py(5).gap(10).items_center().rounded(7).border_1().border_color(al(t.accent, "66")).bg(al(t.accent, "12")).text_size(11.5).text_color(t.muted)
          .tooltip("Abre un worktree y un agente nuevo. El rol lo decide bk.")
          .child(div().flex_1().min_w(0).truncate().child(div().text_color(t.foreground).child(`bk run ${r.number} · en ${where(r)}`)))
          .child(div().id("epic-go").flex_none().px(8).py(1).rounded(5).bg(t.accent).text_color(t.accent_foreground ?? t.background).font_medium().cursor_pointer()
            .on_click((_ev, cx) => launch(r, cx)).child("⏎ Lanzar"))
          .child(div().id("epic-cancel").flex_none().px(8).py(1).rounded(5).border_1().border_color(t.border).cursor_pointer()
            .on_click((_ev, cx) => { this.confirm = null; cx.notify(); }).child("esc")));
      }
      return [main, ...extra];
    };
    const group = (title, list, more = "") => (list.length ? [h_flex().h(POP.group).flex_none().px(POP.pad).pt(12).gap(6).items_center().text_size(10.5)
      .child(div().font_semibold().text_color(t.muted).child(title)).child(div().text_color(t.dim).child(`${list.length}${more}`)), ...list.flatMap(row)] : []);
    const doneHead = p && p.by.done.length ? h_flex().id("epic-done").h(POP.group).flex_none().px(POP.pad).pt(12).gap(6).items_center().text_size(10.5).cursor_pointer()
      .on_click((_ev, cx) => { this.doneOpen = !this.doneOpen; cx.notify(); })
      .child(div().text_color(t.dim).child(this.doneOpen ? "▾" : "▸"))
      .child(div().font_semibold().text_color(t.muted).child("HECHOS"))
      .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(`${p.by.done.length}${this.doneOpen ? "" : ` · ${p.by.done.map((r) => p.label.get(r.key)).join(", ")}`}`)) : null;
    // La lista: alto en px (el popup menos encabezado y pie) y scroll. Con flex_1 queda en alto cero; con alto
    // fijo, HECHOS desplegado o la confirmación de lanzar se desplazan adentro en vez de tapar el pie.
    const listH = Math.max(POP.row, (x.height ?? 400) - (this.headH ?? POP.head) - POP.foot - 2);
    const key_ = (k, what) => h_flex().gap(5).items_center().child(div().px(4).rounded(4).border_1().border_color(t.border).text_size(10).child(k)).child(what);
    return v_flex().id("epic-pop").track_focus(this.handle).size_full().min_h(0).bg(t.popover).text_size(13)
      .on_mouse_down("left", () => this.handle.focus())   // un clic adentro le devuelve las teclas
      .on_key_down((ev, cx) => {
        if (this.busy) return;   // mientras bk _do arranca (un instante), las teclas esperan
        if (this.confirm) {
          const r = rows.find((x) => x.key === this.confirm);
          if (ev.key === "enter" && r) launch(r, cx);
          else if (ev.key === "escape") this.confirm = null;
          else return;
          return cx.notify();
        }
        if (ev.key === "down" && rows.length) this.at = (this.at + 1) % rows.length;
        else if (ev.key === "up" && rows.length) this.at = (this.at + rows.length - 1) % rows.length;
        else if (ev.key === "enter") enter(sel);
        else if (ev.key === "g") return gh(sel ?? e);
        else if (ev.key === "escape") return close();
        else return;
        cx.notify();
      })
      .child(v_flex().id("epic-head").flex_none().px(POP.pad).pt(18).pb(14).gap(10).border_b(1).border_color(t.border)
        .on_size_change((size, cx) => {
          const h = Math.ceil(size.height / (settings().zoom ?? 1));
          if (h !== this.headH) { this.headH = h; cx.notify(); }
        })
        .child(h_flex().gap(8).items_center()
          .child(div().flex_none().text_size(10).font_semibold().text_color(t.accent).child(`ÉPICA #${e.number}`))
          .child(div().flex_1().min_w(0).truncate().text_size(14).font_medium().text_color(t.foreground).child(e.title))
          .child(div().flex_none().text_color(t.dim).child(`${e.done}/${e.total}`)))
        .child(this.segs(t, e, p, false, 7))
        .child(div().text_size(11).text_color(t.dim).child(   // el camino largo baja de renglón en vez de cortarse
          x.stale ? "la última vista: ningún chat la tiene ahora"
            : !p ? "sin los sub-issues todavía (bk no pudo preguntarle a GitHub)"
              : p.path.length ? `camino más largo: ${p.path.join(" → ")} · ${plural(p.path.length, "paso", "pasos")}` : "sin esperas entre los sub-issues")))
      .child(v_flex().id("epic-rows").flex_none().h(listH).overflow_y_scrollbar().pb(6)
        .children(p ? [
          ...group("AHORA", p.by.work),
          ...group("LIBRES", p.by.free, p.by.free.length ? "" : ""),
          ...group("BLOQUEADOS", p.by.wait),
          ...(doneHead ? [doneHead, ...(this.doneOpen ? p.by.done.flatMap(row) : [])] : []),
        ] : []))
      .child(h_flex().flex_none().h(POP.foot).px(POP.pad).gap(12).items_center().border_t(1).border_color(t.border).text_size(11).text_color(t.dim)
        .child(key_("↑↓", "mover")).child(key_("⏎", "lanzar o ir al agente")).child(key_("g", "GitHub")).child(key_("esc", "cerrar")));
  }

  // alt+p desde un chat sin épica, con varias en curso: cuál abrir. ↑↓ mueven, ⏎ o clic la abre, esc cierra.
  epicPick(t) {
    const all = shared("bk.epics")?.epics ?? {};
    const keys = Object.keys(all);
    this.at = Math.min(this.at, Math.max(0, keys.length - 1));
    const open = (k) => {
      closeOverlay(props().overlay);
      if (k) openOverlay({ mod: "bk-agentes", kind: "dialog", width: POP_W, height: all[k]?.height ?? 400, props: { epic: k } });
    };
    return v_flex().id("epic-pick").track_focus(this.handle).size_full().min_h(0).p(5).bg(t.popover).text_size(12.5)
      .on_mouse_down("left", () => this.handle.focus())
      .on_key_down((ev, cx) => {
        if (ev.key === "down" && keys.length) this.at = (this.at + 1) % keys.length;
        else if (ev.key === "up" && keys.length) this.at = (this.at + keys.length - 1) % keys.length;
        else if (ev.key === "enter") return open(keys[this.at]);
        else if (ev.key === "escape") return closeOverlay(props().overlay);
        else return;
        cx.notify();
      })
      .child(div().px(8).pt(4).pb(6).text_size(10.5).font_semibold().text_color(t.accent).child("¿QUÉ ÉPICA?"))
      .children(keys.map((k, i) => {
        const { e, stale } = all[k];
        const on = i === this.at;
        return h_flex().id(`pick-${k}`).h(PICK.row).flex_none().px(8).gap(9).rounded(6).items_center().cursor_pointer()
          .when(on, (el) => el.bg(t.selected))
          .hover((el) => el.bg(on ? t.selected : t.hover))
          .on_hover((h, cx) => { if (h && this.at !== i) { this.at = i; cx.notify(); } })
          .on_click(() => open(k))
          .child(div().flex_none().text_size(11).font_semibold().text_color(stale ? t.dim : t.accent).child(`#${e.number}`))
          .child(div().flex_1().min_w(0).truncate().text_color(stale ? t.dim : t.foreground).child(e.title))
          .child(div().flex_none().text_size(11).text_color(t.dim).child(`${e.done}/${e.total}`));
      }));
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
    if (props()?.epic) return this.epicPopup(t);
    if (props()?.epicPick) return this.epicPick(t);
    const collapsed = narrow();
    const sort = sortOf();
    let list = withBackground(agents(), this.background);
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
    const labelsOf = new Map(native.map((x) => [x.address, x.labels ?? {}]));
    const byAddress = new Map(list.map((a) => [a.address, a]));
    // Un chat que siguió en otro (handoff) va debajo del nuevo, en la línea «antes»; en el riel no hay dónde
    const { prev, hidden } = collapsed ? { prev: new Map(), hidden: new Set() } : this.lineage(list, labelsOf);
    const tabCounts = new Map();
    for (const a of list) tabCounts.set(a.tab, (tabCounts.get(a.tab) ?? 0) + 1);
    const byPriority = sort.id === "priority";
    const urgency = new Map(list.map((a) => [a.address, Math.max(RANK[a.status] ?? 0, ...this.tree(all, a.address).map((s) => RANK[kidStatus(s.t, this.listed)] ?? 0))]));
    // Lo que te necesita en un chat viejo sube con su nuevo: la fila se ordena por lo más urgente de la cadena
    const chained = (addr, seen = new Set()) => {
      const old = prev.get(addr);
      if (!old || seen.has(old)) return urgency.get(addr) ?? 0;
      seen.add(old);
      return Math.max(urgency.get(addr) ?? 0, chained(old, seen));
    };
    for (const a of list) if (prev.has(a.address)) urgency.set(a.address, chained(a.address));
    list = list.filter((a) => !hidden.has(a.address));
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
      // En qué quedó el chat (lib/names.py, etiqueta bk.status) dice más que chat-3 o el nombre del programa
      const status = labelsOf.get(a.address)?.["bk.status"];
      if (status) return [bgText(a), full ? a.space_name : null, status].filter(Boolean).join(" · ");
      const tab = tabs.get(a.tab);
      const machine = a.address.includes("/") ? a.address.split("/")[0] : null;
      const tabName = tab?.named && tab.name !== title ? tab.name : null;
      return [bgText(a), machine, full ? a.space_name : null, tabName ?? (a.program?.name !== title ? a.program?.name : null)].filter(Boolean).join(" · ");
    };

    // «#324 de #321»: el issue del chat y su épica (la sección ÉPICAS); el chat que trabaja la épica misma, «épica #321»
    const ofEpic = (a) => {
      const c = this.chats.get(a.address);
      if (!c?.epic || !c.issue) return null;
      const self = c.issue === c.epic.number && c.repo === c.epic.repo;
      const mine = c.repo && c.repo !== c.epic.repo ? `${short(c.repo)}#${c.issue}` : `#${c.issue}`;
      return { text: self ? `épica #${c.epic.number}` : `${mine} de #${c.epic.number}`, tip: `${c.epic.repo}#${c.epic.number} ${c.epic.title}` };
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
        // Doble clic: renombrar, igual que «Renombrar» del clic derecho (el nombre a mano manda sobre el automático)
        .on_mouse_down("left", (e) => { if (e.click_count === 2 && a.tab) run("tab.rename", { id: a.tab }); })
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
            .when(Boolean(ofEpic(a)), (el) => el.child(div().flex_none().text_color(t.accent).tooltip(ofEpic(a)?.tip ?? "").child(ofEpic(a)?.text ?? "")))
            .when(this.hovered === a.address, (el) => el.child(pin))
            .when(this.hovered !== a.address && isPinned, (el) => el.child(svg(`${ICONS}pin.svg`).size(11).flex_none()))
            .when(this.hovered !== a.address && Boolean(when), (el) => el.child(div().flex_none().min_w(28).whitespace_nowrap().text_right().text_color(timeColor).child(ago(now - when))))));
    };

    // La línea «antes»: el chat del que este siguió (handoff), plegado. Desplegado muestra su fila entera, con
    // sus sub-agentes y su propio «antes». Plegado igual avisa si algo ahí te espera o sigue trabajando.
    const prevLine = (old, depth) => {
      const open = this.openPrev.has(old.address);
      const top = SECTION_STATUS[urgency.get(old.address)];
      const loud = top === "blocked" || top === "working";
      const head = h_flex().id(`prev-${old.address}`).pl(19).pr(8).h(24).flex_none().gap(5).rounded(6).items_center().text_size(11.5).cursor_pointer()
        .hover((x) => x.bg(t.hover))
        .tooltip(open ? "Plegar el chat anterior" : "El chat del que este siguió (handoff): clic para verlo")
        .on_click((_e, cx) => {
          open ? this.openPrev.delete(old.address) : this.openPrev.add(old.address);
          cx.notify();
        })
        .child(svg(`${ICONS}chevron-${open ? "down" : "right"}.svg`).size(11).flex_none().text_color(t.dim))
        .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(`antes: ${titleOf(old)}`))
        .when(loud, (el) => el.child(mark(t, top, 12)))
        .child(div().id(`prev-x-${old.address}`).flex_none().p(1).rounded(4).text_color(t.dim).cursor_pointer()
          .hover((s) => s.bg(t.hover).text_color(t.foreground))
          .tooltip("Cerrar el chat anterior")
          .on_click((_e, cx) => { cx.stop_propagation(); run("tab.close", { id: old.tab }); })
          .child(svg(`${ICONS}x.svg`).size(11)));
      if (!open) return [head];
      return [head, v_flex().pl(14).gap(1).children(withKids(old, depth + 1))];
    };

    const withKids = (a, depth = 0) => {
      const subs = collapsed ? [] : this.tree(all, a.address);
      const r = row(a, subs);
      const old = depth < 8 ? byAddress.get(prev.get(a.address)) : null;
      const before = old ? prevLine(old, depth) : [];
      if (this.folded.has(a.address)) return [r, ...before];
      return [r, ...subs.map((s) => this.subRow(t, s, shown)), ...before];
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
    this.epicRefresh(cx);
    const epics = this.epicList();
    this.share(epics);
    const epicsOpen = !this.folded.has("epicas");
    return v_flex().size_full().min_h(0).bg(t.chrome).pl(8).pr(4).pt(8).text_size(12.5)
      // Soltar lo que se arrastraba de la lista de espacios fuera de ella no mueve nada
      .on_mouse_up("left", (_e, cx) => { if (this.lista.drag) { this.lista.drag = null; cx.notify(); } })
      .children(this.lista.section(t))
      .child(div().h(6).flex_none())
      // ÉPICAS: una tarjeta por épica; se pliega como los grupos de AGENTES. Sin épicas, no está.
      .when(epics.length > 0, (el) => el
        .child(rule(t, "ÉPICAS", [div().text_size(10.5).text_color(t.dim).child(epicsOpen ? "" : String(epics.length)),
          iconButton(t, "epicas-fold", `chevron-${epicsOpen ? "down" : "right"}`, (_e, cx) => { epicsOpen ? this.folded.add("epicas") : this.folded.delete("epicas"); cx.notify(); }, { tip: epicsOpen ? "Plegar las épicas" : "Mostrar las épicas", size: 12 })]))
        .when(epicsOpen, (x) => x.child((epics.length > 3 ? v_flex().id("epic-list").h(3 * 82).overflow_y_scrollbar() : v_flex().id("epic-list")).flex_none().gap(2).children(epics.map((e) => this.epicCard(t, e)))))
        .child(div().h(6).flex_none()))
      .child(rule(t, "AGENTES", [
        iconButton(t, "ag-sort", sort.icon, () => openOverlay({ mod: "bk-agentes", kind: "popup", width: 200, height: 110, props: { sortMenu: true } }), { tip: `Orden: ${sort.label.toLowerCase()}` }),
      ]))
      .when(list.length === 0, (el) => el.child(div().px(8).pt(2).text_size(11.5).text_color(t.dim).child("Todavía no hay agentes. Aparecen acá cuando avisan su estado.")))
      .when(Boolean(this.subError), (el) => el.child(div().px(8).pb(4).text_size(11).text_color(t.blocked).tooltip(this.subError || "").child("No pude leer los sub-agentes de Claude")))
      .child(v_flex().id("ag-list").flex_1().min_h(0).pr(4).pb(8).gap(1).overflow_y_scrollbar().children(rows));
  }
}
