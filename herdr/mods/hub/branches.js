// alt+b: las ramas de todos los proyectos, separadas por proyecto (el que mirás primero). Cada una dice si ya entró
// a la principal (PR mergeado o bk land), su PR, su worktree y lo que tiene sin commitear. Enter abre un chat en su
// worktree (o le crea uno); ctrl+x dos veces la borra (worktree, rama y la de GitHub), solo si no se pierde nada;
// ctrl+o abre su PR. Las terminadas se borran solas cada 10 min (lib/branches.py). Los datos: bk _hub branches.

import { div } from "gpui-kit";
import { h_flex } from "gpui-base";
import { notify } from "herdr";
import { Panel, rank, bk, launch, cwd, lit, pill, ago, tilde, lastLine, openUrl } from "./kit.js";

const SURE_MS = 4000;   // cuánto espera el segundo ctrl+x
const PR = { open: ["abierto", "working"], merged: ["mergeado", "done"], closed: ["cerrado", "dim"] };

export default class Branches extends Panel {
  setup() {
    this.title = "Ramas";
    this.placeholder = "Rama, proyecto o número de PR…";
    this.dir = cwd();
    this.data = { projects: [] };
    this.confirm = null;   // la clave de la fila que espera el segundo ctrl+x
  }

  async load() {
    this.data = await bk(["_hub", "branches", this.dir, "--all"], { json: true, timeout: 60000 });
  }

  subtitle() {
    const all = (this.data.projects ?? []).flatMap((p) => p.items);
    const done = all.filter((b) => b.done).length;
    if (this.loading && !all.length) return "";   // la primera lectura: «Leyendo…» abajo, no «0 ramas»
    return [all.length + (all.length === 1 ? " rama" : " ramas"), done ? done + " terminadas" : null].filter(Boolean).join(" · ");
  }

  rows() {
    const out = [];
    for (const p of this.data.projects ?? []) {
      const items = p.items.map((b) => ({ key: p.path + "\u0000" + b.name, p, b }));
      const found = this.query.trim()
        ? rank(items, this.query, (r) => [r.b.name, p.name + (r.b.pr ? " #" + r.b.pr.n + " " + r.b.pr.title : "")])
        : items.map((item) => ({ item, hits: null }));
      if (!found.length) continue;
      out.push({ head: p.name, note: [p.base, p.stale ? "sin conexión" : null].filter(Boolean).join(" · ") });
      out.push(...found.map(({ item, hits }) => ({ ...item, hits })));
    }
    return out;
  }

  empty() { return this.query.trim() ? "Ninguna rama coincide." : "No hay ramas fuera de la principal."; }

  draw(t, r, on) {
    const b = r.b, sure = this.confirm === r.key;
    const pr = b.pr ? PR[b.pr.state] : null;
    const min = b.ts ? Math.max(0, Math.round((Date.now() / 1000 - b.ts) / 60)) : null;
    return h_flex().flex_1().min_w(0).gap(10).items_center()
      .child(div().flex_1().min_w(0).child(lit(t, b.name, r.hits, on ? t.foreground : t.muted)))
      .when(sure, (el) => el.child(div().flex_none().text_size(11).text_color(t.blocked).child("ctrl+x de nuevo para borrar")))
      .when(!sure && b.done, (el) => el.child(pill(t, "terminada", t.done)))
      .when(!sure && Boolean(pr), (el) => el.child(pill(t, "PR #" + b.pr.n + " " + pr[0], t[pr[1]] ?? t.dim)))
      .when(!sure && !b.done && b.ahead > 0, (el) => el.child(pill(t, b.ahead + (b.ahead === 1 ? " commit" : " commits"), t.dim)))
      .when(!sure && b.dirty > 0, (el) => el.child(pill(t, b.dirty + " sin commitear", t.blocked)))
      .when(!sure && b.busy, (el) => el.child(pill(t, "en uso", t.working)))
      .when(Boolean(b.worktree), (el) => el.child(div().flex_none().max_w(170).truncate().text_size(11.5).text_color(t.dim).child(tilde(b.worktree))))
      .when(min !== null, (el) => el.child(div().flex_none().w(44).text_size(11).text_color(t.dim).child(ago(min))));
  }

  hints(row) {
    const tail = [["ctrl-r", "recargar"], ["escape", "cerrar"]];
    if (!row?.b) return tail;
    const h = [["enter", row.b.worktree ? "chat en su worktree" : "chat (crea el worktree)"],
      ["ctrl-x", this.confirm === row.key ? "de nuevo para borrar" : "borrar"]];
    if (row.b.pr?.url) h.push(["ctrl-o", "ver el PR"]);
    return [...h, ...tail];
  }

  moved() {
    if (this.confirm && this.confirm !== this.current()?.key) this.confirm = null;
  }

  enter(r, cx) {
    const { p, b } = r;
    return this.work(cx, "abriendo…", async () => {
      let res = null, err = "";
      try {
        res = await bk(["_hub", "branch-open", p.path, b.name], { json: true, timeout: 30000 });
      } catch (e) {
        err = String(e?.message ?? e);
      }
      if (!res?.path) return notify({ title: "No pude abrir " + b.name, body: err, level: "error" });
      this.close();
      launch("Chat en " + b.name, ["chat", "--carpeta", res.path], res.path);
    });
  }

  key(e, row, cx) {
    if (!row?.b || !e.modifiers.control) return false;
    if (e.key === "o") {
      if (row.b.pr?.url) openUrl(row.b.pr.url);
      return true;
    }
    if (e.key !== "x") return false;
    this.remove(row, cx);
    return true;
  }

  // El primer ctrl+x pregunta (en la fila y en el pie); el segundo, sobre la misma fila, borra.
  remove(row, cx) {
    const { p, b } = row;
    if (!b.can_rm) return notify({ title: "No borro " + b.name, body: b.why, level: "warning", timeout: 6000 });
    if (this.confirm !== row.key) {
      this.confirm = row.key;
      const n = (this.asked = (this.asked ?? 0) + 1);
      cx.timer.after(SURE_MS, (cx) => {
        if (this.asked !== n || !this.confirm) return;
        this.confirm = null;
        cx.notify();
      });
      return;
    }
    this.confirm = null;
    return this.work(cx, "borrando…", async () => {
      let ok = false, body = "";
      try {
        const r = await bk(["_hub", "branch-rm", p.path, b.name], { timeout: 60000 });
        ok = r.code === 0;
        body = ok ? p.name : lastLine(r.stderr) || `bk salió con ${r.code}`;
      } catch (err) {
        body = String(err?.message ?? err);
      }
      notify({ title: ok ? "Borré " + b.name : "No pude borrar " + b.name, body, level: ok ? "success" : "error" });
      try { await this.load(); } catch (_) { /* queda la lista que había */ }
    });
  }
}
