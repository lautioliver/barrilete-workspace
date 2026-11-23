#!/usr/bin/env python3
"""Los datos de los paneles nativos de bk en Herdr (herdr/mods/hub): un JSON por tema, sin dibujar nada.

  herdr_hub.py <tema> [argumentos]        (bk _hub <tema> …)

Cada tema imprime UN JSON y sale con 0. Si no puede: una línea en stderr y sale con 1 (2 si el tema no existe).
`dir` es la carpeta de la terminal en foco (sin él, la actual); el proyecto es el de bk: la raíz del repo, o el repo
principal si la carpeta es un worktree. Agentes, chats y espacios salen siempre de Herdr (BK_BACKEND=herdr).

  issues [dir] [--fresh]   {project, repo, stale, items: [{n, title, labels, updated, url, assignees, task, pr}]}
                           los issues abiertos (hasta 50), el más nuevo primero. task: la tarea activa del kit para ese
                           issue ({id, status, window}) o null. pr: un PR abierto que lo cierra (lo que dice GitHub
                           o, si no, la rama claude/<issue>-… del kit) o null
  prs [dir] [--fresh]      {project, repo, stale, items: [{n, title, branch, draft, author, updated, url, review, ci,
                           task}]}  los PRs abiertos (hasta 30). review: approved | changes | required | none.
                           ci: ok | fail | pending | none. task: la tarea activa de ese PR (pr57-reviewer en pending
                           es lo que lanza bk approve)
  agents                   {items: [{win, kind, project, role, ref, title, label, state, waiting, why, question,
                           since_min, terminal, model, name, account, id}]}  los agentes y chats de bk vivos, en el
                           orden de bk ls (agentes y después chats; en cada grupo, los que te esperan primero).
                           kind: agent | chat. win: lo que toman bk go/say/stop. label: el título como lo muestra
                           bk ls. id: su número fijo de ventana (bk.id) o null
  sessions                 {open: [{sid, project, title, state, terminal, cwd, age_min, where, handoff}],
                           recent: [{sid, project, title, cwd, age_min, account, handoff}]}  lo que muestra bk s
                           (recientes: hasta 40). terminal: null si la sesión abierta no vive en Herdr. account: solo
                           se sabe de una sesión que dejó un resumen (handoff); si no, null
  session-go <sid>         lo que hace Enter en bk s: muestra la pestaña de la abierta o retoma la cerrada en un chat
                           nuevo de su proyecto. {ok: true, did: "show" | "resume"}. Con --dry-run (o bk --dry-run
                           _hub session-go …) dice qué haría, con "dry": true, y no toca Herdr
  changes [dir]            {roots: [{name, path, branch, files: [{code, path, add, del}]}]}  lo sin commitear en el
                           repo de dir, en los demás worktrees de su proyecto (los de bk _side) y donde trabaja cada
                           agente vivo: una vez cada raíz y solo las que tienen algo. add y del son números, o null
                           si no se sabe (un binario)
  diff <raíz> <archivo>    {lines: [{t, s}], truncated}  el diff contra HEAD. t: "+" "-" " " (s sin ese primer
                           carácter), "@" (el encabezado del bloque) o "h" (una nota: binario, sin cambios…). Un
                           archivo nuevo va entero como "+". Hasta 600 líneas, de hasta 2000 caracteres cada una
  stats [--fresh]          {today: {tokens, cost, cache_read, by_model: [{model, name, tokens, cost}],
                           by_project: [{project, tokens, cost}]}, days: [{date, tokens, cost}], streak,
                           total: {tokens, cost, sessions}}
                           today es lo de bk tokens (lib/usage.py): tokens SIN las lecturas de caché, que van aparte
                           en cache_read. days (los últimos 30 días, con ceros) y total son lo de bk stats
                           (lib/stats.py): tokens CON las lecturas de caché. Se guarda 60 s
  projects [--fresh]       {items: [{name, path, open}]}  los proyectos de bk new: primero los de los espacios de
                           Herdr y después las carpetas de tus sesiones recientes (se guardan 60 s). open: ya hay
                           un espacio con su nombre (el que abre bk o bk open)
  handoffs                 {items: [{sid, name, project, age_min, session, account}]}  los resúmenes listos
                           (bk handoff --listos), el más nuevo primero
  checkpoints              {items: […]}  el JSON de bk checkpoints --json tal cual
  song                     {playing, paused, station, title, genre, genres}  lo que suena, mirando el estado que
                           deja lib/song.sh (song.station y el socket de mpv): no arranca ni corta nada. Para eso:
                           bk song [género|estación] reproduce, bk song stop corta, bk song next / prev cambian de
                           estación dentro del género y bk song pause pausa o sigue
  branches [dir] [--all] [--fresh]
                           {projects: [{name, project, path, repo, base, stale, items: [{name, sha, ts, subject,
                           worktree, dirty, ahead, pr, remote, done, how, contained, busy, can_rm, why}]}]}  las
                           ramas de cada proyecto (lib/branches.py), sin la principal y solo los que tienen alguna.
                           Con dir: ese proyecto; con --all (o sin dir): todos los de bk new, el de dir primero.
                           done: entró a la principal (PR mergeado en ese commit, o bk land). can_rm: se puede borrar
                           sin perder nada; si no, why dice por qué
  branch-rm <repo> <rama>  borra su worktree, la rama y la del remoto si apunta al mismo commit. {ok, text}
  branch-open <repo> <rama>
                           {path, created}  la carpeta donde abrir un chat en esa rama: su worktree, o uno nuevo en
                           ../<repo>-wt/<rama> si no tiene
  branch-sweep [--if-due] [--dry-run]
                           la limpieza sola: borra las ramas terminadas (done y can_rm) de todos los proyectos y
                           avisa. La dispara status, cada 10 min como mucho. {removed, failed, dry}
  status [dir] [--terminal t7]
                           {project, branch, dirty, account, waiting, pending, working, tokens_today,
                           cost_today, song}  una llamada barata para la barra de estado: sin gh y sin leer
                           transcripts. waiting/pending/working: las tareas del kit de todos los proyectos por estado
                           (working = in_progress). account: la cuenta de Claude de esa terminal (o del chat
                           principal del proyecto); null es la de siempre. tokens_today y cost_today salen del estado
                           que deja lib/usage.py (~/.cache/barrilete/usage-<fecha>.json) y se renuevan en segundo
                           plano si tiene más de 60 s; null si todavía no hay. song: {playing, station, title} o
                           null si no suena nada
  palette                  {items: [{group, label, cmd, arg, kind}], profile: {active, profiles: [{name, summary, models}]}}
                           las ENTRIES de lib/palette.py y los perfiles de modelos (lib/profiles.py)

  herdr_hub.py _do [--cwd DIR] [--title T] -- <args de bk…>      (bk _do …)
      Corre `bk <args>` suelto de quien lo pidió (otra sesión: sobrevive al panel), con la salida en
      <caché>/do/<fecha>-<pid>.log, y vuelve en el acto con {ok: true, log, pid}. Cuando termina, bk deja un aviso de
      Herdr (hd_notice, lib/herdr.sh): success si salió con 0, error si no, con la última línea de la salida. Si
      esa línea es un JSON va en palabras: "ya estaba abierta: la mostré" o "retomada en un chat nuevo" si trae
      "did" (bk _do -- _hub session-go <sid>), "listo" si trae "ok": true, y si trae "error", ese texto y nivel error.
      Es para comandos que terminan solos (run, review, fix, chat, approve…), no para las vistas de pantalla
      completa (changes, s, stats), que necesitan una terminal.
      Con --dry-run (bk --dry-run _do …, o entre los argumentos del bk de adentro) no corre nada ni deja log ni
      aviso: imprime {ok: true, dry: true, cmd, cwd} con lo que correría.

Lo que consulta a GitHub se guarda 60 s en <caché> = ${BK_CACHE_DIR:-${XDG_CACHE_HOME:-~/.cache}/bk}/hub; --fresh lo
saltea. Si gh falla y hay algo guardado, sale eso con "stale": true.
"""
import json, os, re, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.realpath(__file__))
BK = os.path.join(os.path.dirname(HERE), "bin", "bk")
sys.path.insert(0, HERE)
ENV = dict(os.environ)               # el entorno con que llamaron a bk: el de lo que lanza bk _do
os.environ["BK_BACKEND"] = "herdr"   # lib/agents.py y lib/sessions.py: lo que hay en Herdr, diga lo que diga la config

TTL = 60            # segundos que vale lo guardado
GH_TIMEOUT = 8
MAX_LINES, MAX_COLS, MAX_BYTES = 600, 2000, 512 * 1024   # tope de un diff
RECENT = 40
APP = os.environ.get("BK_HERDR_APP") or "herdr-app"


class Fail(Exception):
    """Un error para mostrar: una línea en stderr y salida 1."""


def run(*a, cwd=None, timeout=6):
    """(código, stdout, stderr). El código es None si no arrancó o no terminó a tiempo (el motivo va en stderr)."""
    try:
        r = subprocess.run(a, capture_output=True, text=True, timeout=timeout, cwd=cwd, errors="replace")
        return r.returncode, r.stdout, r.stderr
    except FileNotFoundError:
        return None, "", f"falta {a[0]}"
    except subprocess.TimeoutExpired:
        return None, "", f"{a[0]} no respondió en {timeout} s"
    except OSError as e:
        return None, "", f"{a[0]}: {e}"


def last(text):
    """La última línea no vacía."""
    return next((l.strip() for l in reversed((text or "").splitlines()) if l.strip()), "")


def spawn(*a):
    """Algo en segundo plano, suelto de este proceso (no se espera)."""
    try:
        subprocess.Popen(a, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except OSError:
        return False
    return True


# ---------- caché ----------
def cache_dir():
    base = os.environ.get("BK_CACHE_DIR") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "bk")
    return os.path.join(base, "hub")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def cached(key, fetch, fresh=False):
    """(datos, viejos): lo guardado si tiene menos de TTL; si no, fetch() y se guarda. Si fetch falla (Fail) y hay
    algo guardado, eso con viejos=True. fresh: no mira la edad de lo guardado."""
    path = os.path.join(cache_dir(), re.sub(r"[^A-Za-z0-9._-]", "_", key) + ".json")
    old = read_json(path)
    if not (isinstance(old, dict) and isinstance(old.get("ts"), (int, float)) and "data" in old):
        old = None
    if old and not fresh and 0 <= time.time() - old["ts"] < TTL:
        return old["data"], False
    try:
        data = fetch()
    except Fail:
        if old:
            return old["data"], True
        raise
    write_json(path, {"ts": time.time(), "data": data})
    return data, False


# ---------- proyecto, GitHub y tareas ----------
def name_of(top):
    """El nombre del proyecto de esa raíz, como project_of de bin/bk (el del espacio de Herdr y el de sus tareas)."""
    return os.path.basename(top.rstrip("/")).replace(".", "_").replace(":", "_")


def project(d):
    """(nombre, raíz) del proyecto de la carpeta: la raíz del repo, o el repo principal si es un worktree. Fuera de
    un repo, la carpeta misma."""
    import herdr_side as SIDE
    d = os.path.abspath(os.path.expanduser(d or "."))
    if not os.path.isdir(d):
        raise Fail(f"no existe la carpeta {d}")
    top = SIDE.project_top(d) or d
    return name_of(top), top


def split_args(args, flags=(), opts=()):
    """(posicionales, {opción: valor}). flags no llevan valor; opts sí."""
    pos, got, it = [], {}, iter(args)
    for a in it:
        if a in flags:
            got[a] = True
        elif a in opts:
            v = next(it, None)
            if v is None:
                raise Fail(f"{a} necesita un valor")
            got[a] = v
        else:
            pos.append(a)
    return pos, got


def repo(d):
    import agents as AG
    name, top = project(d)
    slug = AG.repo_of(top)
    if not slug:
        raise Fail(f"{name} no tiene un remoto de GitHub (git remote -v)")
    return name, top, slug


def gh_json(slug, *args):
    rc, out, err = run("gh", *args, "-R", slug, timeout=GH_TIMEOUT)
    if rc != 0:
        raise Fail("GitHub no respondió: " + (last(err) or f"gh salió con {rc}"))
    try:
        data = json.loads(out)
    except ValueError:
        raise Fail("gh devolvió algo que no es JSON")
    if not isinstance(data, list):
        raise Fail("gh no devolvió una lista")
    return data


def active_tasks(name, top):
    """Las tareas activas del kit de ese proyecto, en el orden de bk tasks (las que te esperan primero)."""
    import tasks as TK
    real, out = os.path.realpath(top), []
    for t in TK.tasks():
        if t.get("status") not in TK.ACTIVE:
            continue
        if (os.path.realpath(t["repo"]) == real) if t.get("repo") else (t.get("project") == name):
            out.append(t)
    return out


def named(account):
    """Una cuenta de bk account, o None si es la de siempre (default)."""
    return account if account and account != "default" else None


def brief(t):
    return {"id": t.get("id"), "status": t.get("status"), "window": t.get("window") or None} if t else None


def task_of_issue(ts, n):
    """La tarea de un implementer sobre ese issue (bk run <n>, o bk fix sobre su PR: su ref es el issue). El ref
    de un reviewer es el PR, no un issue."""
    return next((t for t in ts if str(t.get("ref") or "").lstrip("#") == str(n) and t.get("role") != "reviewer"), None)


def task_of_pr(ts, n):
    """La tarea de ese PR: pr<n>-reviewer (bk review, o propuesta por bk done) o pr<n>-implementer (bk fix)."""
    return next((t for t in ts if t.get("pr") == n or str(t.get("id") or "").startswith(f"pr{n}-")), None)


def pr_links(prs, slug):
    """{issue: PR abierto que lo cierra}. Primero lo que dice GitHub (closingIssuesReferences); si no, la rama del
    kit (claude/<issue>-…, como la lee bk fix). Si son varios, el PR más nuevo."""
    by_branch, by_ref = {}, {}
    for p in sorted(prs, key=lambda p: p.get("number") or 0):
        m = re.match(r"claude/(\d+)-", p.get("headRefName") or "")
        if m:
            by_branch[int(m.group(1))] = p["number"]
        for ref in p.get("closingIssuesReferences") or []:
            r = ref.get("repository") or {}
            full = f"{(r.get('owner') or {}).get('login', '')}/{r.get('name', '')}"
            if full in ("/", slug) and isinstance(ref.get("number"), int):
                by_ref[ref["number"]] = p["number"]
    return {**by_branch, **by_ref}


def issues(args):
    pos, got = split_args(args, flags=("--fresh",))
    name, top, slug = repo(pos[0] if pos else ".")
    fresh, links = "--fresh" in got, {}

    def get_links():   # en paralelo con los issues; si falla, los issues salen igual, sin su PR
        try:
            prs, _ = cached(f"links-{slug}", lambda: gh_json(
                slug, "pr", "list", "--state", "open", "--limit", "100", "--json",
                "number,headRefName,closingIssuesReferences"), fresh)
        except Fail:
            return
        links.update(pr_links(prs, slug))

    th = threading.Thread(target=get_links)
    th.start()
    try:
        data, stale = cached(f"issues-{slug}", lambda: gh_json(
            slug, "issue", "list", "--state", "open", "--limit", "50", "--json",
            "number,title,labels,updatedAt,url,assignees"), fresh)
    finally:
        th.join()
    ts = active_tasks(name, top)
    items = [{"n": i["number"], "title": i.get("title") or "",
              "labels": [l.get("name", "") for l in i.get("labels") or []],
              "updated": i.get("updatedAt") or "", "url": i.get("url") or "",
              "assignees": [a.get("login", "") for a in i.get("assignees") or []],
              "task": brief(task_of_issue(ts, i["number"])), "pr": links.get(i["number"])}
             for i in sorted(data, key=lambda i: -i["number"])]
    return {"project": name, "repo": slug, "stale": stale, "items": items}


REVIEW = {"APPROVED": "approved", "CHANGES_REQUESTED": "changes", "REVIEW_REQUIRED": "required"}
CI_FAIL = {"FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"}
CI_OK = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def ci_of(checks):
    """ok | fail | pending | none de los checks de un PR (statusCheckRollup): uno que falló manda; si no, uno que
    no terminó."""
    seen = set()
    for c in checks or []:
        st = c.get("conclusion") or c.get("state") or ""   # la conclusión de un CheckRun (vacía hasta que termina) o
        seen.add("fail" if st in CI_FAIL else "ok" if st in CI_OK else "pending")   # el estado de un StatusContext
    return next((k for k in ("fail", "pending", "ok") if k in seen), "none")


def prs(args):
    pos, got = split_args(args, flags=("--fresh",))
    name, top, slug = repo(pos[0] if pos else ".")
    data, stale = cached(f"prs-{slug}", lambda: gh_json(
        slug, "pr", "list", "--state", "open", "--limit", "30", "--json",
        "number,title,headRefName,isDraft,author,updatedAt,url,reviewDecision,statusCheckRollup"), "--fresh" in got)
    ts = active_tasks(name, top)
    items = [{"n": p["number"], "title": p.get("title") or "", "branch": p.get("headRefName") or "",
              "draft": bool(p.get("isDraft")), "author": (p.get("author") or {}).get("login", ""),
              "updated": p.get("updatedAt") or "", "url": p.get("url") or "",
              "review": REVIEW.get(p.get("reviewDecision") or "", "none"), "ci": ci_of(p.get("statusCheckRollup")),
              "task": brief(task_of_pr(ts, p["number"]))}
             for p in sorted(data, key=lambda p: -p["number"])]
    return {"project": name, "repo": slug, "stale": stale, "items": items}


# ---------- agentes y chats ----------
def quick_questions(AG, sts):
    """gather() mira la pantalla de cada agente quieto para ver si terminó preguntando (hc read), y la primera
    lectura de una terminal tarda más de un segundo. Acá las que hagan falta van todas juntas, y cada una se guarda
    por (terminal, ts y estado de su sesión): la pantalla de un agente quieto no cambia hasta su próximo evento."""
    look, path = AG.last_question, os.path.join(cache_dir(), "questions.json")
    old = read_json(path)
    old = old if isinstance(old, dict) else {}

    def key(p):
        st = sts.get(p) or {}
        return f"{st.get('ts')}:{st.get('state')}"

    panes = list(AG.windows().values())
    known = {p: old[p][1] for p in panes
             if isinstance(old.get(p), list) and len(old[p]) == 2 and old[p][0] == key(p)}
    need = [p for p in panes if p not in known and (sts.get(p) or {}).get("state") in ("waiting", "done", "idle")]
    found = {}
    threads = [threading.Thread(target=lambda p=p: found.__setitem__(p, look(p))) for p in need]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    known.update(found)
    now = {p: [key(p), q] for p, q in known.items()}
    if now != old:
        write_json(path, now)
    return lambda pane: known[pane] if pane in known else look(pane)


def warm_titles():
    """Los títulos que falten los busca lib/agents.py warm en segundo plano (como al lanzar un agente): la corrida
    siguiente ya los tiene. Como mucho una vez por minuto."""
    stamp = os.path.join(cache_dir(), "warm.stamp")
    try:
        if time.time() - os.path.getmtime(stamp) < TTL:
            return
    except OSError:
        pass
    os.makedirs(cache_dir(), exist_ok=True)
    with open(stamp, "w"):
        pass
    spawn(sys.executable, os.path.join(HERE, "agents.py"), "warm")


def agents(args):
    import agents as AG
    labels, memo, terms = {}, {}, AG.hc_terms

    def hc_terms(kind):   # una consulta a Herdr por tipo en toda la corrida, y de paso las etiquetas de cada terminal
        if kind not in memo:
            memo[kind] = terms(kind)
            labels.update(dict(memo[kind]))
        return memo[kind]

    AG.hc_terms = hc_terms
    sts = AG.states()
    AG.last_question = quick_questions(AG, sts)
    items, missing = [], False
    for a in AG.gather(fetch_titles=False):
        chat, lab = a["kind"] == "chat", labels.get(a["pane"], {})
        missing = missing or (not chat and not a["title"] and bool(a["num"] or a["ref"]))
        model = a["model"] or re.sub(r"^claude-|-\d{8}$", "", (sts.get(a["pane"]) or {}).get("model") or "")
        items.append({
            "win": a["ws"] if chat else a["win"], "kind": "chat" if chat else "agent",
            "project": lab.get("bk.project") or a["project"], "role": lab.get("bk.role") or a["role"],
            "ref": lab.get("bk.ref") or (f"#{a['ref']}" if a["ref"] else ""),
            "title": a["title"], "label": AG.label(a, 60), "state": a["state"], "waiting": a["asks"],
            "why": a["why"], "question": a["question"], "since_min": a["mins"], "terminal": a["pane"] or None,
            "model": model, "name": lab.get("bk.name", ""), "account": named(lab.get("bk.account")),
            "id": int(lab["bk.id"]) if str(lab.get("bk.id", "")).isdigit() else None,
        })
    if missing:
        warm_titles()
    return {"items": items}


# ---------- sesiones ----------
def age_min(ts):
    return max(0, int((time.time() - ts) // 60)) if ts else 0


def sessions(args):
    import handoff as HO
    import sessions as S
    opened, recent = S.load(prune=False)
    out = {"open": [], "recent": []}
    for r in opened:
        if not r.get("sid"):   # una ventana de tmux que terminó sin decir qué sesión era: no hay cómo retomarla
            continue
        out["open"].append({"sid": r["sid"], "project": r["proj"], "title": r["title"], "state": r.get("state") or "",
                            "terminal": r.get("pane") if r.get("herdr") else None, "cwd": r["cwd"],
                            "age_min": age_min(r["mtime"]), "where": r.get("window") or None,
                            "handoff": bool(r.get("handoff"))})
    for r in recent[:RECENT]:
        meta = (HO.load_meta(r["sid"]) or {}) if r.get("handoff") else {}
        out["recent"].append({"sid": r["sid"], "project": r["proj"], "title": r["title"], "cwd": r["cwd"],
                              "age_min": age_min(r["mtime"]), "account": named(meta.get("account")),
                              "handoff": bool(r.get("handoff"))})
    return out


def session_go(args):
    import sessions as S
    pos, got = split_args(args, flags=("--dry-run",))
    if len(pos) != 1 or not pos[0]:
        raise Fail("uso: bk _hub session-go <sid>")
    sid, dry = pos[0], {"dry": True} if "--dry-run" in got or os.environ.get("BK_DRY") else None
    opened, recent = S.load(prune=False)
    r = next((x for x in opened if x.get("sid") == sid), None)
    if r:
        if not r.get("herdr"):
            raise Fail("esa sesión está abierta fuera de Herdr (en tmux u otra terminal): seguila ahí")
        steps = S.herdr_show(r["pane"])
        if not steps:
            raise Fail("no encuentro su pestaña en Herdr (¿un subagente sin pestaña?)")
        if dry:
            return {"ok": True, "did": "show", **dry}
        codes = [step() for step in steps]
        if codes[-2] != 0:   # …, tab.select, pane.focus: sin la pestaña no se mostró nada
            raise Fail("Herdr no mostró la pestaña de esa sesión (¿está abierto?)")
        return {"ok": True, "did": "show"}
    r = next((x for x in recent if x["sid"] == sid), None)
    if not r:
        raise Fail(f"no hay una sesión {sid} entre las abiertas ni las recientes")
    if dry:
        return {"ok": True, "did": "resume", **dry}
    cwd = r["cwd"] if r["cwd"] and os.path.isdir(r["cwd"]) else os.path.expanduser("~")
    if not S.herdr_resume(r, cwd):
        raise Fail("no pude abrir el chat en Herdr (probá: bk chat)")
    return {"ok": True, "did": "resume"}


# ---------- cambios ----------
def changes(args):
    from concurrent.futures import ThreadPoolExecutor
    import agents as AG
    import changes as CH
    import herdr_side as SIDE
    d = os.path.abspath(os.path.expanduser(args[0] if args else "."))
    top = SIDE.project_top(d) if os.path.isdir(d) else ""
    sts = AG.states()
    agents = [(sts.get(p) or {}).get("cwd") or AG.pane_cwd(p) for p in AG.windows().values()]
    # La carpeta, los worktrees de su proyecto (los mismos que mira bk _side) y donde trabaja cada agente vivo
    found = CH.roots([d]) + (SIDE.worktrees(top) if top else []) + CH.roots([c for c in agents if c and os.path.isdir(c)])
    tops, seen = [], set()
    for t in found:
        if os.path.isdir(t) and os.path.realpath(t) not in seen:
            seen.add(os.path.realpath(t))
            tops.append(t)
    with ThreadPoolExecutor(8) as pool:   # un git status por raíz, a la vez: un proyecto puede tener decenas de worktrees
        loaded = list(pool.map(lambda t: CH.load([t]), tops))
    roots = []
    for it in (it for items in loaded for it in items):
        if it[0] == "root":
            roots.append({"name": os.path.basename(it[1]), "path": it[1], "branch": it[2], "files": []})
        else:
            _, _, code, path, add, rm = it
            roots[-1]["files"].append({"code": code, "path": path, "add": int(add) if add.isdigit() else None,
                                       "del": int(rm) if rm.isdigit() else None})
    return {"roots": roots}


def note(text):
    return {"lines": [{"t": "h", "s": text}], "truncated": False}


def clip(lines):
    """Hasta MAX_LINES líneas de hasta MAX_COLS caracteres."""
    out = [{"t": l["t"], "s": l["s"] if len(l["s"]) <= MAX_COLS else l["s"][:MAX_COLS] + "…"} for l in lines[:MAX_LINES]]
    return out, len(lines) > MAX_LINES


def parse_diff(text):
    """La salida de git diff de un archivo, sin su encabezado (diff --git, index, ---, +++…)."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    start = next((i for i, l in enumerate(lines) if l.startswith("@@")), None)
    head = lines[:start]
    if any(l.startswith("Binary files ") or l.startswith("GIT binary patch") for l in head):
        return note("(binario: sin diff de texto)")
    if start is None:   # solo cambió el modo, o un renombre sin cambios: lo que diga el encabezado
        out, cut = clip([{"t": "h", "s": l} for l in head if not l.startswith(("diff --git", "index "))])
        return {"lines": out or [{"t": "h", "s": "(sin diff de texto)"}], "truncated": cut}
    body = []
    for l in lines[start:]:
        if l.startswith("@@"):
            body.append({"t": "@", "s": l})
        elif l[:1] in ("+", "-", " ", ""):
            body.append({"t": l[:1] or " ", "s": l[1:]})
        else:   # "\ No newline at end of file"
            body.append({"t": "h", "s": l.lstrip("\\ ")})
    out, cut = clip(body)
    return {"lines": out, "truncated": cut}


def whole_file(full, path):
    """Un archivo nuevo: entero, como líneas agregadas."""
    if os.path.islink(full):
        return note(f"(enlace simbólico → {os.readlink(full)})")
    if not os.path.isfile(full):
        raise Fail(f"no existe el archivo {path}")
    with open(full, "rb") as f:
        data = f.read(MAX_BYTES + 1)
    if b"\0" in data[:8000]:
        return note(f"(binario, {os.path.getsize(full)} bytes)")
    big = len(data) > MAX_BYTES
    text = data[:MAX_BYTES].decode("utf-8", "replace")
    body = text.split("\n")
    if body and body[-1] == "":
        body.pop()
    out, cut = clip([{"t": "@", "s": f"@@ -0,0 +1,{len(body)} @@"}] + [{"t": "+", "s": l} for l in body])
    return {"lines": out, "truncated": cut or big}


def diff(args):
    if len(args) != 2 or not args[0] or not args[1]:
        raise Fail("uso: bk _hub diff <raíz> <archivo>")
    root, path = os.path.realpath(os.path.expanduser(args[0])), args[1]
    if not os.path.isdir(root) or run("git", "-C", root, "rev-parse", "--show-toplevel")[0] != 0:
        raise Fail(f"{root} no es un repo de git")
    full = os.path.normpath(os.path.join(root, path))
    # Su carpeta, ya resuelta, tiene que quedar adentro: ni "..", ni una ruta de otro lado, ni un enlace hacia afuera
    if not (os.path.realpath(os.path.dirname(full)) + os.sep).startswith(root + os.sep):
        raise Fail("el archivo tiene que estar dentro de esa raíz")
    if os.path.isdir(full) and not os.path.islink(full):
        raise Fail(f"{path} es una carpeta")
    git = ("git", "-C", root, "-c", "core.quotepath=false")
    rc, out, err = run(*git, "diff", "--no-color", "--no-ext-diff", "--no-textconv", "HEAD", "--", path)
    if rc is None:
        return note(f"({err})")
    if rc == 0 and out.strip():
        return parse_diff(out)
    # Sin diff contra HEAD: sin cambios, o un archivo que HEAD no conoce (nuevo, o un repo sin commits)
    if rc == 0 and run(*git, "ls-files", "--", path)[1].strip():
        return note("(sin cambios contra HEAD)")
    return whole_file(full, path)


# ---------- uso ----------
def money(x):
    return round(x or 0.0, 2)


def stats(args):
    def build():
        import fcntl
        from datetime import date, timedelta
        import stats as ST
        os.makedirs(cache_dir(), exist_ok=True)
        with open(os.path.join(cache_dir(), "stats.lock"), "w") as lock:   # un solo escaneo a la vez: stats.py
            fcntl.flock(lock, fcntl.LOCK_EX)                               # guarda su estado con un nombre fijo
            st = ST.load()
            ST.scan(st)
            ST.save(st)
        s = ST.summary(st)
        rc, out, err = run(sys.executable, os.path.join(HERE, "usage.py"), "--json", timeout=20)
        try:
            u = json.loads(out) if rc == 0 else None
        except ValueError:
            u = None
        if not isinstance(u, dict):
            raise Fail("no pude leer el uso de hoy (lib/usage.py): " + (last(err) or "sin salida"))

        def rows(bucket, field, extra=lambda k: {}):
            return [{field: k, **extra(k), "tokens": v.get("tokens", 0), "cost": money(v.get("cost"))}
                    for k, v in sorted(bucket.items(), key=lambda kv: -kv[1].get("cost", 0))]

        end = date.today()
        days = [(end - timedelta(days=n)).isoformat() for n in range(29, -1, -1)]
        return {
            "today": {"tokens": u.get("tokens", 0), "cost": money(u.get("cost_usd")),
                      "cache_read": (u.get("breakdown") or {}).get("cr", 0),
                      "by_model": rows(u.get("by_model") or {}, "model", lambda m: {"name": ST.model_name(m)}),
                      "by_project": rows(u.get("by_project") or {}, "project")},
            "days": [{"date": d, "tokens": s["per_day"].get(d, {}).get("tokens", 0),
                      "cost": money(s["per_day"].get(d, {}).get("cost"))} for d in days],
            "streak": s["current_streak"],
            "total": {"tokens": s["total_tokens"], "cost": money(s["cost"]), "sessions": s["sessions"]},
        }

    return cached("stats", build, "--fresh" in args)[0]


def usage_today():
    """(tokens, costo) de hoy según el estado que deja lib/usage.py, sin escanear nada. Si ese estado tiene más de
    TTL (o no está), lo renueva usage.py en segundo plano: la llamada siguiente lo encuentra."""
    from datetime import datetime
    import usage as U
    today = datetime.now().strftime("%Y-%m-%d")
    path = os.path.join(U.CACHE_DIR, f"usage-{today}.json")
    try:
        age = time.time() - os.path.getmtime(path)
    except OSError:
        age = None
    if age is None or age > TTL:
        spawn(sys.executable, os.path.join(HERE, "usage.py"), "--json")
    if age is None:
        return None, None
    msgs = U.load_state(today)[1].get("msgs")
    if not isinstance(msgs, dict):
        return None, None
    s = U.summarize(msgs)
    return s["tokens"], s["cost_usd"]


# ---------- proyectos, resúmenes, checkpoints ----------
def herdr_spaces():
    """Los espacios de Herdr de esta máquina: [(nombre, carpeta)]. Vacío si Herdr no está abierto."""
    rc, out, _ = run(APP, "ls", timeout=4)
    try:
        ls = json.loads(out) if rc == 0 else {}
    except ValueError:
        ls = {}
    return [(s.get("name") or "", s.get("folder") or "") for s in ls.get("spaces") or [] if s.get("machine") is None]


def projects(args):
    import functools
    import herdr_side as SIDE

    def recent():
        import new as NEW
        NEW.toplevel = functools.lru_cache(maxsize=None)(NEW.toplevel)   # una consulta a git por carpeta, no por sesión
        return NEW.recent_projects()

    spaces = herdr_spaces()
    names, paths, loose = {n for n, _ in spaces}, [], os.path.expanduser("~/.bk/chats")
    for _, folder in spaces:   # los que ya están en Herdr primero, como en bk new (el de chats sueltos no es un proyecto)
        if not os.path.isdir(folder) or os.path.realpath(folder) == os.path.realpath(loose):
            continue
        top = SIDE.project_top(folder) or folder
        if top not in paths:
            paths.append(top)
    for p in cached("projects", recent, "--fresh" in args)[0]:
        if p not in paths and os.path.isdir(p):
            paths.append(p)
    return {"items": [{"name": name_of(p), "path": p, "open": name_of(p) in names} for p in paths]}


def handoffs(args):
    import handoff as HO
    return {"items": [{"sid": m["sid"], "name": m.get("name") or "",
                       "project": name_of(m["cwd"]) if m.get("cwd") else "", "age_min": age_min(mtime),
                       "session": m.get("session") or "", "account": named(m.get("account"))}
                      for mtime, m in HO.ready()]}


def checkpoints(args):
    import checkpoints as CK
    cs = CK.items()
    return {"items": cs} if isinstance(cs, list) else cs


def palette(args):
    import palette as PAL
    import profiles as PR
    d = PR.data()
    return {"items": [{"group": g, "label": label, "cmd": cmd, "arg": arg, "kind": kind}
                      for g, label, cmd, arg, kind in PAL.ENTRIES],
            "profile": {"active": d["active"], "profiles": [{"name": p["name"], "summary": p["summary"], "models": p["models"]} for p in d["profiles"]]},
            "accounts": accounts_here()}


def accounts_here():
    """Las cuentas (sin preguntarle al CLI si tienen sesión: es lento) y cuál usa el espacio del proyecto de acá
    (bk account use, lib/accounts.py)."""
    import accounts as AC
    try:
        sp = project(os.getcwd())[0]
    except Exception:
        sp = ""
    mine = AC.spaces().get(sp, {}) if sp else {}
    mine = mine if isinstance(mine, dict) else {}
    using = {p: (mine.get(p) if mine.get(p) and AC.provider(mine.get(p)) == p else "default") for p in AC.VAR}
    return {"space": sp, "using": using, "list": [{"name": n, "provider": AC.provider(n)} for n in AC.names()]}


# ---------- música ----------
def song_dir():
    return os.environ.get("BK_SONG_CACHE") or os.path.expanduser("~/.cache/bk")


def mpv_get(path, *props, timeout=0.3):
    """Propiedades del mpv de bk song por su socket IPC (solo lee). None si no hay un mpv escuchando ahí."""
    import socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    out = {}
    try:
        s.connect(path)
        for i, p in enumerate(props, 1):
            s.sendall((json.dumps({"command": ["get_property", p], "request_id": i}) + "\n").encode())
        buf, deadline = b"", time.monotonic() + timeout
        while len(out) < len(props) and time.monotonic() < deadline:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                rid = m.get("request_id")   # sin request_id: un evento de mpv
                if isinstance(rid, int) and 1 <= rid <= len(props):
                    out[props[rid - 1]] = m.get("data") if m.get("error") == "success" else None
    except OSError:
        return out or None
    finally:
        s.close()
    return out or None


NOT_A_TITLE = re.compile(r"^(https?:.*|.*\.(mp3|aac|m3u8)|stream|live|radio|listen|main)$")


def now_playing():
    """{playing, paused, station, title, genre} de lo que suena, o None si no suena nada. El tema, con la regla de
    cur_title de lib/song.sh: el de la radio (icy-title) y, si no hay, el de mpv salvo que sea la url o el archivo."""
    d = song_dir()
    m = mpv_get(os.path.join(d, "song.sock"), "pause", "metadata", "media-title")
    if m is None or "pause" not in m:
        return None
    try:
        with open(os.path.join(d, "song.station"), encoding="utf-8") as f:
            parts = f.readline().rstrip("\n").split("\t")
    except OSError:
        parts = []
    meta = m.get("metadata") if isinstance(m.get("metadata"), dict) else {}
    title = meta.get("icy-title") or meta.get("title") or m.get("media-title") or ""
    title = " ".join(str(title).split())
    if NOT_A_TITLE.match(title):
        title = ""
    return {"playing": m["pause"] is not True, "paused": m["pause"] is True,
            "station": (parts[1] if len(parts) > 1 else "") or None, "title": title or None,
            "genre": (parts[2] if len(parts) > 2 else "") or None}


def song(args):
    now = now_playing() or {"playing": False, "paused": False, "station": None, "title": None, "genre": None}
    rc, out, err = run(os.path.join(HERE, "song.sh"), "genres", timeout=4)
    if rc != 0:
        raise Fail("no pude leer los géneros de bk song: " + (last(err) or "sin salida"))
    return {**now, "genres": [g for g in out.split("\n") if g.strip()]}


# ---------- barra de estado ----------
def account_of(AG, term, name):
    """La cuenta de Claude (bk account) de esa terminal de Herdr; sin terminal, la de este entorno o la del chat
    principal del proyecto. None: la de siempre."""
    def label(addr):
        try:
            return (json.loads(AG.sh(AG.HC, "get", addr, "--json") or "{}").get("labels") or {})
        except ValueError:
            return {}

    if term:
        acct = label(term).get("bk.account")
    else:
        acct = os.environ.get("BK_ACCOUNT_CLAUDE")
        if not acct:
            try:
                ls = json.loads(AG.sh(AG.HC, "ls", "--json", "--label", "bk.kind=chat", "--label", f"bk.project={name}") or "{}")
            except ValueError:
                ls = {}
            chats = [(t.get("address") or "", label(t.get("address") or "")) for t in ls.get("terminals") or []]
            main = [l for _, l in chats if l.get("bk.win") == name] or [l for _, l in chats]
            acct = main[0].get("bk.account") if main else None
    return named(acct)


def branch_of(head):
    """La rama, de la primera línea de git status --branch ("main...origin/main [ahead 1]"). Sin rama (un HEAD
    suelto), "": lo mismo que git branch --show-current."""
    if head.startswith("HEAD (no branch)"):
        return ""
    for unborn in ("No commits yet on ", "Initial commit on "):   # un repo sin commits
        if head.startswith(unborn):
            head = head[len(unborn):]
    return head.split("...")[0]


def status(args):
    import agents as AG
    import herdr_side as SIDE
    import tasks as TK
    pos, got = split_args(args, opts=("--terminal",))
    d = os.path.abspath(os.path.expanduser(pos[0] if pos else "."))
    out, top, acct = {"project": "", "branch": "", "dirty": 0}, "", []
    if os.path.isdir(d):   # una carpeta que ya no existe no rompe la barra
        top = SIDE.project_top(d)
        out["project"] = name_of(top or d)
    # la cuenta (dos consultas a Herdr) mientras git mira el repo: la barra pide esto cada 10 s
    th = threading.Thread(target=lambda: acct.append(account_of(AG, got.get("--terminal"), out["project"])))
    th.start()
    if top:
        st = [l for l in SIDE.sh("git", "-C", d, "status", "--porcelain", "--branch").splitlines() if l.strip()]
        if st and st[0].startswith("## "):
            out["branch"], st = branch_of(st[0][3:]), st[1:]
        out["dirty"] = len(st)
    th.join()
    out["account"] = acct[0] if acct else None
    import accounts as ACC
    out["email"] = ACC.email(out["account"])
    by = {}
    for t in TK.tasks():
        by[t.get("status")] = by.get(t.get("status"), 0) + 1
    out.update(waiting=by.get("waiting", 0), pending=by.get("pending", 0), working=by.get("in_progress", 0))
    out["tokens_today"], out["cost_today"] = usage_today()
    now = now_playing()
    out["song"] = {k: now[k] for k in ("playing", "station", "title")} if now else None
    if not os.environ.get("BK_NO_SWEEP"):   # la limpieza de ramas terminadas: suelta, cada 10 min como mucho
        import branches as BR
        if BR.due():
            spawn(BK, "_hub", "branch-sweep")
    return out


# ---------- ramas (alt+b) ----------
def branches(args):
    import branches as BR
    pos, got = split_args(args, flags=("--fresh", "--all"))
    if "--all" in got or not pos:
        tops = BR.projects()
        if pos:   # el proyecto que mirás, primero
            first = BR.project_top(os.path.abspath(os.path.expanduser(pos[0])))
            tops = ([first] if first else []) + [t for t in tops if os.path.realpath(t) != os.path.realpath(first or "")]
    else:
        tops = [BR.project_top(os.path.abspath(os.path.expanduser(pos[0])))]
    busy = BR.busy_dirs()
    out = []
    for top in tops:
        if not top:
            continue
        p = BR.info(top, busy=busy, fresh="--fresh" in got)
        p["name"] = name_of(top)
        if p["items"]:
            out.append(p)
    return {"projects": out}


def branch_rm(args):
    import branches as BR
    if len(args) != 2:
        raise Fail("uso: bk _hub branch-rm <repo> <rama>")
    top = BR.project_top(os.path.abspath(os.path.expanduser(args[0])))
    if not top:
        raise Fail(f"{args[0]} no es un repo git")
    ok, text = BR.remove(top, args[1])
    if not ok:
        raise Fail(text)
    return {"ok": True, "text": text}


def branch_open(args):
    """La carpeta donde abrir un chat en esa rama: su worktree, o uno nuevo en ../<repo>-wt/<rama> si no tiene."""
    import branches as BR
    if len(args) != 2:
        raise Fail("uso: bk _hub branch-open <repo> <rama>")
    top = BR.project_top(os.path.abspath(os.path.expanduser(args[0])))
    if not top:
        raise Fail(f"{args[0]} no es un repo git")
    name = args[1]
    wts, main_branch = BR.worktrees(top)
    if name == main_branch:
        return {"path": top, "created": False}
    if wts.get(name):
        return {"path": wts[name], "created": False}
    if BR.git(top, "show-ref", "-q", "--verify", f"refs/heads/{name}")[0] != 0:
        raise Fail(f"no existe la rama {name}")
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", name.split("/")[-1]).strip("-") or "rama"
    base = os.path.join(os.path.dirname(top), os.path.basename(top) + "-wt")
    path, k = os.path.join(base, slug), 2
    while os.path.exists(path):
        path, k = os.path.join(base, f"{slug}-{k}"), k + 1
    if os.environ.get("BK_DRY"):
        return {"path": path, "created": True, "dry": True}
    rc, _, err = BR.git(top, "worktree", "add", "-q", path, name)
    if rc != 0:
        raise Fail("git no pudo crear el worktree: " + last(err))
    return {"path": path, "created": True}


def branch_sweep(args):
    """La limpieza sola: borra las ramas terminadas y avisa. --if-due: solo si pasaron 10 min de la última."""
    import branches as BR
    if "--if-due" in args and not BR.due():
        return {"skipped": True}
    res = BR.sweep("--dry-run" in args)
    if res["removed"] and not res["dry"]:
        names = [f"{r['project']}: {r['branch']}" for r in res["removed"]]
        more = f" y {len(names) - 3} más" if len(names) > 3 else ""
        title = "Ramas terminadas borradas" if len(names) > 1 else "Rama terminada borrada"
        run(BK, "_notice", title, ", ".join(names[:3]) + more, "info", timeout=10)
    return res


# ---------- bk _do ----------
DO_USAGE = "uso: bk _do [--cwd DIR] [--title T] -- <args de bk…>"


DID = {"show": "ya estaba abierta: la mostré", "resume": "retomada en un chat nuevo"}   # bk _hub session-go


def last_line(path):
    """La última línea no vacía de la salida de un comando, sin códigos ANSI ni de control."""
    import gentle as G
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 64 * 1024))
            data = f.read()
    except OSError:
        return ""
    text = G.ANSI.sub("", data.decode("utf-8", "replace")).replace("\r", "\n")
    for line in reversed(text.split("\n")):
        line = re.sub(r"[\x00-\x1f\x7f]", "", line).strip()
        if line:
            return line
    return ""


def notice_of(path, rc):
    """(nivel, texto) del aviso con que termina bk _do: success o error según cómo salió el comando, y la última
    línea de su salida. Si esa línea es un JSON (bk _hub session-go) va en palabras: lo que hizo si trae "did",
    "listo" si trae "ok": true; y si trae "error", ese texto con nivel error aunque haya salido con 0."""
    line = last_line(path)
    level, body = ("success", line or "listo") if rc == 0 else ("error", line or f"salió con {rc}")
    try:
        j = json.loads(line) if line.startswith("{") else None   # un objeto, o nada
    except ValueError:
        j = None
    if j:
        if j.get("error"):
            level, body = "error", " ".join(str(j["error"]).split())
        elif j.get("did") in DID:
            body = DID[j["did"]]
        elif j.get("ok") is True:
            body = "listo"
    return level, body[:300]


def do(args):
    cwd, title, i = None, "", 0
    while i < len(args) and args[i] != "--":
        if args[i] not in ("--cwd", "--title") or i + 1 >= len(args):
            raise Fail(DO_USAGE)
        if args[i] == "--cwd":
            cwd = args[i + 1]
        else:
            title = args[i + 1]
        i += 2
    cmd = args[i + 1:]
    if i >= len(args) or not cmd:
        raise Fail(DO_USAGE)
    cwd = os.path.abspath(os.path.expanduser(cwd or "."))
    if not os.path.isdir(cwd):
        raise Fail(f"no existe la carpeta {cwd}")
    if os.environ.get("BK_DRY") or "--dry-run" in cmd:   # bk --dry-run _do …, o el --dry-run del bk de adentro
        return {"ok": True, "dry": True, "cmd": ["bk"] + cmd, "cwd": cwd}
    logs = os.path.join(cache_dir(), "do")
    os.makedirs(logs, exist_ok=True)
    for old in os.listdir(logs):   # los logs de más de una semana se van
        p = os.path.join(logs, old)
        try:
            if old.endswith(".log") and time.time() - os.path.getmtime(p) > 7 * 86400:
                os.remove(p)
        except OSError:
            continue
    log = os.path.join(logs, f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}.log")
    with open(log, "ab") as f:   # otra sesión: no muere con el panel que lo pidió ni le deja abierta su salida
        p = subprocess.Popen([BK, "_do_run", log, title, "--"] + cmd, cwd=cwd, env=ENV, stdin=subprocess.DEVNULL,
                             stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
    return {"ok": True, "log": log, "pid": p.pid}


TOPICS = {"issues": issues, "prs": prs, "agents": agents, "sessions": sessions, "session-go": session_go,
          "changes": changes, "diff": diff, "stats": stats, "projects": projects, "handoffs": handoffs,
          "checkpoints": checkpoints, "song": song, "status": status, "palette": palette, "_do": do,
          "branches": branches, "branch-rm": branch_rm, "branch-open": branch_open, "branch-sweep": branch_sweep}


def main(argv):
    for stream in (sys.stdout, sys.stderr):   # UTF-8 siempre: un mod puede correr bk sin LANG
        stream.reconfigure(encoding="utf-8", errors="replace")
    topic, args = (argv[0] if argv else ""), argv[1:]
    if topic == "_aviso":   # (interno) _aviso <log> <código de salida>: el nivel y el texto del aviso de bk _do_run
        if len(args) != 2 or not args[1].lstrip("-").isdigit():
            return 2
        print("\n".join(notice_of(args[0], int(args[1]))))
        return 0
    if topic not in TOPICS:
        names = " | ".join(t for t in TOPICS if not t.startswith("_"))
        print(f"bk: bk _hub <tema> [argumentos]   (temas: {names})", file=sys.stderr)
        return 2
    try:
        text = json.dumps(TOPICS[topic](args), ensure_ascii=False)   # entero o nada: nunca medio JSON
    except Fail as e:
        print(f"bk: {e}", file=sys.stderr)
        return 1
    except Exception as e:   # un tema roto no deja al panel con un traceback: una línea, y salida 1
        if os.environ.get("BK_HUB_DEBUG"):
            raise
        print(f"bk: _hub {topic} falló: {type(e).__name__}: {' '.join(str(e).split())}", file=sys.stderr)
        return 1
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
