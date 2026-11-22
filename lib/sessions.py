#!/usr/bin/env python3
"""bk s: selector de sesiones de Claude Code, estilo Orca.

Arriba, las sesiones abiertas (con su estado): Enter salta a su pane de tmux.
Abajo, las recientes de todas las carpetas (~/.claude/projects): Enter la retoma con
`claude --resume` en una ventana nueva de la sesión tmux "agents", en su carpeta.

Cada chat de un workspace lleva su número fijo (el de la tira y alt+N), con su color: "ws 3".
Con ↪ en lugar del ●: ese chat dejó el resumen para seguir en uno nuevo (lib/handoff.py). También en recientes,
si ya se cerró: bk chat --desde o «Seguir desde» en alt+n lo toma.

Con Herdr (bk backend herdr): una sesión abierta vive en una terminal de Herdr (su "pane" es la dirección, t7);
Enter muestra su pestaña y retomar una reciente abre un chat más en el espacio de su proyecto (bk chat). x no
cierra pestañas de Herdr. Las sesiones que sigan en tmux andan como siempre.

Teclas: ↑↓/jk moverse · / buscar · enter abrir · x cerrar (un agente: su ventana; un workspace: todo el
workspace, con confirmación; la conversación queda en recientes) · q/esc salir
"""
import curses, glob, json, os, re, shlex, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gentle as G  # noqa: E402  (paleta del tema, una sola para todas las vistas)

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import handoff as HO  # noqa: E402  (resumenes listos para seguir en un chat nuevo)
import agents as AG  # noqa: E402
from agents import backend, HC  # noqa: E402  (tmux o Herdr, lo mismo que decide bin/bk)

APP = os.environ.get("BK_HERDR_APP") or shutil.which("herdr-app") or "herdr-app"
BK = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "bin", "bk")

PROJECTS = os.path.expanduser("~/.claude/projects")
STATE = os.path.expanduser("~/.cache/sketchybar/agents")
CACHE = os.path.expanduser("~/.cache/barrilete/sessions.json")
SESSION = os.environ.get("BK_SESSION", "agents")
RECENT = 80
# curses espera un segundo después de un esc por si viene una secuencia (flechas): con esc para cerrar, se
# sentía como si el selector tardara en irse. 25 ms alcanza para las flechas; si la persona definió ESCDELAY, queda.
os.environ.setdefault("ESCDELAY", "25")
SKIP_DIRS = re.compile(r"-private-tmp-|scratch-workspaces|scratchpad")
# bk revive: las sesiones que murieron sin avisar (sid -> cwd, pane, estado, cuándo y por qué)
DEAD = os.path.expanduser("~/.cache/bk/dead.json")
DEAD_DAYS = 7
SHELLS = {"zsh", "bash", "fish", "sh", "dash", "nu"}   # lo que Herdr dice que corre en una terminal sin agente
GRACE = 60   # segundos desde el último evento de la sesión antes de creerle a Herdr que no hay agente
WHY = {"cerrada": "terminal cerrada", "vacia": "consola vacía"}


def sh(*args):
    """Como agents.sh (y con su mismo corte: si hc no respondió una vez, no se lo vuelve a esperar), con 3 s."""
    return AG.sh(*args, timeout=3)


def tmux_panes():
    """pane_id -> dict(target, window, session, dead, wsid). wsid: el número fijo del workspace (@bk_id)."""
    out = {}
    for l in sh("tmux", "list-panes", "-a", "-F",
                "#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}\t#{pane_dead}\t#{@bk_id}").splitlines():
        p = l.split("\t")
        if len(p) == 6:
            out[p[0]] = {"session": p[1], "target": f"{p[1]}:{p[2]}", "window": p[3], "dead": p[4] == "1",
                         "wsid": p[5] if p[1].startswith("bk") and p[5].isdigit() else ""}
    return out


def herdr_panes():
    """dirección -> dict como el de tmux_panes, de las terminales vivas de Herdr. Vacío si Herdr no responde."""
    try:
        ls = json.loads(sh(HC, "ls", "--json") or "{}")
    except ValueError:
        return {}
    out = {}
    for t in ls.get("terminals") or []:
        addr = t.get("address")
        if addr and t.get("state") == "live":
            # el id de la terminal (t2d) delante de "espacio / pestaña": es el que usan bk say, bk peek y hc
            out[addr] = {"session": "herdr", "target": addr, "window": f"{addr} {t['where']}" if t.get("where") else addr,
                         "dead": False, "agent": t.get("agent") or "",
                         "wsid": "", "herdr": True}
    return out


def gone(pane, panes, hpanes):
    """¿La sesión corría en un pane que ya no existe? Cada pane lo juzga su dueño, y solo si respondió: un pane
    de tmux (%5) con la lista de tmux, una terminal de Herdr (t7) con la de Herdr. Una lista vacía no prueba nada."""
    if not pane:
        return False
    mine = panes if pane.startswith("%") else hpanes
    return bool(mine) and pane not in mine


AGENT_PROCS = {"claude", "codex"}


def agent_terminals():
    """Las terminales de Herdr (su HC_TERMINAL_ID) donde corre de verdad un claude o un codex, según los procesos.
    Herdr dice "zsh" cuando el agente no encabeza la terminal (bash -c '… && claude …', bk run con su _ended)."""
    names = {}
    for line in sh("ps", "-axww", "-o", "pid=,comm=").splitlines():
        pid, _, comm = line.strip().partition(" ")
        names[pid] = os.path.basename(comm.strip())
    out = set()
    for line in sh("ps", "-axwwE", "-o", "pid=,command=").splitlines():
        pid, _, rest = line.strip().partition(" ")
        if names.get(pid) in AGENT_PROCS:
            m = re.search(r"(?:^|\s)HC_TERMINAL_ID=(\S+)", rest)
            if m:
                out.add(m.group(1))
    return out


def hollow(s, hpanes, alive=agent_terminals):
    """¿Su terminal de Herdr sigue viva pero ya no corre un agente, solo el shell? Claude murió sin mandar
    SessionEnd y quedó la consola vacía. Una sesión recién lanzada no cuenta: Herdr tarda en ver al agente. Antes
    de creerle a Herdr se miran los procesos (alive): si en esa terminal corre un claude o un codex, está viva."""
    pane = hpanes.get(s.get("pane") or "")
    if not (pane and pane.get("agent") in SHELLS and time.time() - (s.get("ts") or 0) > GRACE):
        return False
    return s.get("pane") not in alive()


def read_dead():
    try:
        d = json.load(open(DEAD))
    except Exception:
        return {}
    return d if isinstance(d, dict) else {}


def write_dead(d):
    try:
        os.makedirs(os.path.dirname(DEAD), exist_ok=True)
        tmp = f"{DEAD}.{os.getpid()}"
        json.dump(d, open(tmp, "w"))
        os.replace(tmp, DEAD)
    except OSError:
        pass


def note_dead(sid, s, why):
    """Anota una sesión que murió sin avisar (why: "cerrada" su terminal, o "vacia" la consola)."""
    d = read_dead()
    d[sid] = {"cwd": s.get("cwd") or "", "pane": s.get("pane") or "", "state": s.get("state") or "",
              "at": int(time.time()), "why": why}
    write_dead(d)


def dead():
    """Las sesiones anotadas como muertas, de la más vieja a la más nueva. Salen de la lista las que volvieron a
    abrirse (tienen estado otra vez) y las de hace más de DEAD_DAYS días."""
    d, rows = read_dead(), []
    keep = {sid: x for sid, x in d.items() if isinstance(x, dict)
            and not os.path.exists(os.path.join(STATE, sid + ".json"))
            and time.time() - (x.get("at") or 0) < DEAD_DAYS * 86400}
    if keep != d:
        write_dead(keep)
    for sid, x in sorted(keep.items(), key=lambda kv: (kv[1].get("at") or 0, kv[0])):
        path = next(iter(glob.glob(os.path.join(PROJECTS, "*", sid + ".jsonl"))), None)
        meta = transcript_meta(path, {}) if path else {}
        cwd = meta.get("cwd") or x.get("cwd") or ""
        rows.append({"sid": sid, "cwd": cwd, "proj": project_name(cwd) if cwd else "", "why": x.get("why") or "cerrada",
                     "at": x.get("at") or 0, "title": meta.get("title") or meta.get("first") or "(sin mensajes)"})
    return rows


def transcript_meta(path, cache):
    """cwd, título y primer mensaje de un transcript (cacheado por mtime)."""
    st = os.stat(path)
    key = path
    c = cache.get(key)
    if c and c.get("mtime") == st.st_mtime:
        return c
    cwd = title = first = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if not cwd and '"cwd"' in line:
                    m = re.search(r'"cwd":"((?:[^"\\]|\\.)*)"', line)
                    if m:
                        cwd = m.group(1).replace("\\\\", "\\")
                if '"custom-title"' in line or '"ai-title"' in line:
                    try:
                        o = json.loads(line)
                        t = o.get("customTitle") or o.get("aiTitle")
                        if t and (o.get("type") == "custom-title" or not title.startswith("!")):
                            title = ("!" + t) if o.get("type") == "custom-title" else t
                    except Exception:
                        pass
                elif not first and '"type":"user"' in line and '"isMeta":true' not in line:
                    try:
                        o = json.loads(line)
                        c_ = o.get("message", {}).get("content")
                        if isinstance(c_, list):
                            c_ = next((x.get("text") for x in c_ if isinstance(x, dict) and x.get("type") == "text"), "")
                        if isinstance(c_, str) and c_.strip() and not c_.startswith("<"):
                            first = " ".join(c_.split())[:120]
                    except Exception:
                        pass
    except OSError:
        pass
    c = {"mtime": st.st_mtime, "cwd": cwd, "title": title.lstrip("!"), "first": first}
    cache[key] = c
    return c


def mark_handoffs(rows, sids):
    """Marca (handoff=True) las filas cuya sesión dejó un resumen listo."""
    for r in rows:
        r["handoff"] = bool(r.get("sid")) and r["sid"] in sids
    return rows


def save_cache(cache):
    try:
        G.save_json(CACHE, cache)
    except OSError:
        pass


def load(prune=True):
    """(abiertas, recientes). prune=False: no borra el estado de las sesiones cuyo pane ya no existe (igual pasan a
    recientes); lo usa bk _hub, que solo mira."""
    panes = tmux_panes()
    hpanes = herdr_panes() if backend() == "herdr" else {}
    live = {}  # session_id -> estado
    memo = {}

    def alive():   # los procesos se miran una vez y solo si hace falta
        if "a" not in memo:
            memo["a"] = agent_terminals()
        return memo["a"]
    for f in glob.glob(os.path.join(STATE, "*.json")):
        sid = os.path.basename(f)[:-5]
        if sid.startswith("bk-"):
            continue
        try:
            s = json.load(open(f))
        except Exception:
            continue
        # Corría en un pane de tmux que ya no existe: la ventana se cerró sin que Claude mandara
        # Stop/SessionEnd y el estado quedó congelado ("trabajando" para siempre). Está muerta:
        # va a recientes (enter la retoma) y se borra el estado para que nadie la cuente.
        # Solo si tmux (o Herdr, si el pane es una terminal suya) respondió: una lista vacía no prueba nada.
        # Lo mismo si su terminal de Herdr sigue pero quedó en consola vacía (Claude murió y quedó el shell).
        # Antes de borrar el estado se anota en el registro de muertas, que es lo que retoma bk revive.
        why = "cerrada" if gone(s.get("pane"), panes, hpanes) else "vacia" if hollow(s, hpanes, alive) else None
        if why:
            if prune:
                note_dead(sid, s, why)
                try:
                    os.remove(f)
                except OSError:
                    pass
            continue
        live[sid] = s
    try:
        cache = json.load(open(CACHE))
    except Exception:
        cache = {}
    files = []
    for d in os.listdir(PROJECTS) if os.path.isdir(PROJECTS) else []:
        if SKIP_DIRS.search(d):
            continue
        for p in glob.glob(os.path.join(PROJECTS, d, "*.jsonl")):
            try:
                files.append((os.path.getmtime(p), p))
            except OSError:
                pass
    files.sort(reverse=True)
    rows_open, rows_recent = [], []
    seen = set()
    for mtime, p in files[:RECENT]:
        sid = os.path.basename(p)[:-6]
        meta = transcript_meta(p, cache)
        cwd = meta["cwd"] or ""
        proj = project_name(cwd) if cwd else os.path.basename(os.path.dirname(p))
        row = {"sid": sid, "cwd": cwd, "proj": proj, "title": meta["title"] or meta["first"] or "(sin mensajes)",
               "mtime": mtime}
        if sid in live:
            s = live[sid]
            pane = panes.get(s.get("pane") or "") or hpanes.get(s.get("pane") or "")
            row.update(state=s.get("state"), role=s.get("role"), ref=s.get("ref"), pane=s.get("pane"),
                       herdr=bool(pane and pane.get("herdr")),
                       target=pane["target"] if pane else None, window=where(pane),
                       dead=pane["dead"] if pane else False, session=pane["session"] if pane else None,
                       wsid=pane["wsid"] if pane else "")
            rows_open.append(row)
        else:
            rows_recent.append(row)
        seen.add(sid)
    # Abiertas sin transcript todavía (recién lanzadas): igual se muestran
    for sid, s in live.items():
        if sid not in seen:
            pane = panes.get(s.get("pane") or "") or hpanes.get(s.get("pane") or "")
            rows_open.append({"sid": sid, "herdr": bool(pane and pane.get("herdr")), "cwd": s.get("cwd", ""), "proj": project_name(s.get("cwd", "")),
                              "title": "(recién abierta)", "mtime": s.get("ts", 0), "state": s.get("state"),
                              "role": s.get("role"), "ref": s.get("ref"), "pane": s.get("pane"),
                              "target": pane["target"] if pane else None,
                              "window": where(pane), "dead": False,
                              "session": pane["session"] if pane else None, "wsid": pane["wsid"] if pane else ""})
    # Ventanas de agentes muertas (el agente salió y la ventana quedó): para poder cerrarlas
    for pid, pane in panes.items():
        if pane["session"] == SESSION and pane["dead"] and not any(r.get("pane") == pid for r in rows_open):
            # Claude deja impreso "claude --resume <id>" al salir: con eso se puede revivir
            m = re.search(r"claude --resume ([0-9a-f-]{36})", sh("tmux", "capture-pane", "-p", "-t", pid))
            rows_open.append({"sid": m.group(1) if m else None, "cwd": "", "proj": "",
                              "title": "terminó · enter lo retoma acá" if m else "terminó (ventana abierta)",
                              "mtime": 0, "state": "ended", "target": pane["target"], "window": pane["window"],
                              "pane": pid, "dead": True, "session": pane["session"], "wsid": ""})
    save_cache(cache)
    rows_open.sort(key=lambda r: -r["mtime"])
    sids = HO.ready_sids()
    return mark_handoffs(rows_open, sids), mark_handoffs(rows_recent, sids)


def where(pane):
    """Nombre corto de dónde vive: la ventana si es un agente de bk; "ws 3" si es el chat de un workspace (su
    número fijo, el de la tira); si no, la sesión tmux."""
    if not pane:
        return None
    if pane.get("herdr"):   # "espacio / pestaña", como lo muestra Herdr
        return pane["window"]
    if pane["session"] == SESSION:
        return pane["window"]
    if pane.get("wsid"):
        return f"ws {pane['wsid']}"
    return f"{pane['session']}:{pane['window']}"


def close_action(it, current):
    """Qué hace x sobre una fila: ("window", destino) un agente · ("session", sesión) un workspace entero ·
    ("error", motivo). El workspace desde el que abriste el selector no: te dejaría sin sesión."""
    sess = it.get("session")
    if it.get("herdr"):
        return "error", "vive en Herdr: cerrá su pestaña ahí (o bk stop <agente>)"
    if it.get("target") and it.get("pane") and sess == SESSION:
        return "window", it["target"]
    if sess and sess.startswith("bk"):
        if sess == current:
            return "error", "es el workspace donde estás: cerralo desde otro"
        return "session", sess
    return "error", "solo cierro agentes (sesión tmux 'agents') y workspaces (bk-…)"


def project_name(cwd):
    parts = cwd.rstrip("/").split("/")
    if len(parts) > 1 and parts[-2].endswith("-wt"):
        return parts[-2][:-3] + "#" + parts[-1]
    if "/.claude/worktrees/" in cwd:
        return cwd.split("/.claude/worktrees/")[0].rsplit("/", 1)[-1] + "~wt"
    return parts[-1] or "~"


def ago(ts):
    if not ts:
        return ""
    d = time.time() - ts
    if d < 3600:
        return f"hace {int(d // 60)}m"
    if d < 86400:
        return time.strftime("hoy %H:%M", time.localtime(ts)) if time.localtime(ts).tm_yday == time.localtime().tm_yday \
            else time.strftime("ayer %H:%M", time.localtime(ts))
    if d < 7 * 86400:
        return time.strftime("%a %H:%M", time.localtime(ts))
    return time.strftime("%d/%m", time.localtime(ts))


STATE_TXT = {k: G.STATES[k][1] for k in ("background", "working", "waiting", "done", "idle", "ended")}


def current_workspace():
    """Workspace bk desde el que se abrió el selector (alt+s / prefijo+s), o None."""
    if not os.environ.get("TMUX"):
        return None
    s = os.environ.get("BK_FROM") or sh("tmux", "display-message", "-p", "#{session_name}").strip()
    return s if s.startswith("bk") else None


def quiet(*cmd, env=None):
    return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env).returncode


def herdr_show(addr):
    """Los pasos para mostrar la pestaña de esa terminal de Herdr (lo que hace bk go), o None si no tiene."""
    try:
        labels = json.loads(sh(HC, "get", addr, "--json") or "{}").get("labels") or {}
    except ValueError:
        labels = {}
    if not labels.get("herdr.tab"):
        return None
    steps = [[APP, "do", "space.select", "--id", labels["herdr.space"]]] if labels.get("herdr.space") else []
    steps += [[APP, "do", "tab.select", "--id", labels["herdr.tab"]], [APP, "do", "pane.focus", "--terminal", addr]]
    return [lambda c=c: quiet(*c) for c in steps]


def herdr_resume(r, cwd):
    """Retomar una sesión cerrada con Herdr: un chat más en el espacio de su proyecto (bk chat), que arranca con
    claude --resume en la carpeta de la sesión (Claude la busca por carpeta). Con exec, claude queda al frente de
    la terminal y Herdr lo ve como agente (si no, ve el bash de -c y la toma por consola vacía). Devuelve si se abrió."""
    env = dict(os.environ, BK_BACKEND="herdr", BK_PROJECT=cwd,
               WS_CHAT_CMD=f"cd {shlex.quote(cwd)} && exec claude --resume {shlex.quote(r['sid'])}")
    if quiet(BK, "chat", env=env) != 0:
        print("bk: no pude abrir el chat en Herdr (probá: bk chat)", file=sys.stderr)
        return False
    return True


def tmux_resume(r, cwd):
    """Retomar una sesión cerrada con tmux: una ventana nueva de la sesión "agents" con claude --resume, en su
    carpeta, sin saltar a ella. Devuelve (pane, nombre de la ventana); pane vacío si tmux no la abrió."""
    name = "r-" + re.sub(r"[^A-Za-z0-9#-]", "", r["proj"])[:12]
    has = subprocess.run(["tmux", "has-session", "-t", SESSION], capture_output=True).returncode == 0
    new = (["tmux", "new-window", "-d", "-t", SESSION + ":", "-n", name] if has
           else ["tmux", "new-session", "-d", "-s", SESSION, "-n", name])
    pane = sh(*new, "-P", "-F", "#{pane_id}", "-c", cwd, f"claude --resume {r['sid']}").strip()
    if pane:
        subprocess.run(["tmux", "set-option", "-w", "-t", pane, "remain-on-exit", "on"], capture_output=True)
    return pane, name


def revive(args):
    """bk revive [--dry-run] [--forget] [<id>…]: retoma todos juntos los chats que murieron sin avisar (los que
    anota load()), cada uno como Enter sobre una reciente. Con ids (o su principio), solo esos; --forget los saca
    de la lista sin retomarlos. Devuelve el código de salida."""
    dry = "--dry-run" in args or bool(os.environ.get("BK_DRY"))
    forget = "--forget" in args
    want = [a for a in args if not a.startswith("--")]
    load()   # anota las que murieron desde la última vez que alguien miró
    rows = dead()
    if want:
        picked = []
        for w in want:
            found = [r for r in rows if r["sid"].startswith(w)]
            if len(found) != 1:
                print(f"bk: {'no hay un' if not found else 'hay más de un'} chat muerto anotado que empiece con {w}"
                      " (bk revive --dry-run los lista)", file=sys.stderr)
                return 1
            picked += [r for r in found if r not in picked]
        rows = picked
    if not rows:
        print("no hay chats muertos anotados")
        return 0
    print(f"{len(rows)} {'chat muerto' if len(rows) == 1 else 'chats muertos'}:")
    for r in rows:
        print(f"  {r['sid'][:8]}  {r['proj']:<24} {ago(r['at']):<11} {WHY.get(r['why'], r['why']):<17} {r['title'][:60]}")
    if dry:
        print("(dry-run: no se retomó ni se olvidó nada)")
        return 0
    failed = []
    if not forget:
        herdr = backend() == "herdr"
        for r in rows:
            cwd = r["cwd"] if r["cwd"] and os.path.isdir(r["cwd"]) else os.path.expanduser("~")
            if not (herdr_resume(r, cwd) if herdr else tmux_resume(r, cwd)[0]):
                failed.append(r["sid"])
    d = read_dead()
    for r in rows:
        if r["sid"] not in failed:
            d.pop(r["sid"], None)
    write_dead(d)
    done = len(rows) - len(failed)
    print(f"{'olvidados' if forget else 'retomados'}: {done}" + (f" · no se pudo: {' '.join(s[:8] for s in failed)}" if failed else ""))
    return 1 if failed else 0


def open_row(r):
    """Devuelve (mensaje_error | None, pasos a ejecutar después de cerrar curses).

    Un paso es un comando (lista) o una función sin argumentos. Dentro de un workspace, el agente
    se trae al lugar del chat (como alt+shift+N; alt+q vuelve), en vez de saltar a la sesión "agents".
    """
    in_tmux = bool(os.environ.get("TMUX"))
    ws = current_workspace()

    def show(pane, target):
        # Agentes de la sesión "agents": al lugar del chat del workspace. Los que ya viven en un
        # workspace (su chat, o uno de visita): saltar ahí.
        if ws and target.split(":")[0] == SESSION:
            return [["bk", "_agent", ws, pane]]
        if in_tmux:
            return [["tmux", "switch-client", "-t", pane], ["tmux", "select-window", "-t", pane],
                    ["tmux", "select-pane", "-t", pane]]
        return [["tmux", "attach", "-t", pane]]

    if r.get("herdr"):
        steps = herdr_show(r["pane"])
        return (None, steps) if steps else ("no encuentro su pestaña en Herdr (¿un subagente sin pestaña?)", None)
    if r.get("dead"):
        # Pane muerto (remain-on-exit): no acepta teclas. Revivirlo con la misma sesión de Claude.
        if not r.get("sid"):
            return "esa ventana terminó y no sé qué sesión era: cerrala con x", None
        return None, [["tmux", "respawn-pane", "-k", "-t", r["pane"], f"claude --resume {r['sid']}"]] \
            + show(r["pane"], r["target"])
    if r.get("target"):
        return None, show(r["pane"], r["target"])
    if r.get("state"):  # abierta pero fuera de tmux (otra ventana de Ghostty): no duplicarla
        return "esa sesión está abierta en otra terminal: retomala ahí", None
    cwd = r["cwd"] if r["cwd"] and os.path.isdir(r["cwd"]) else os.path.expanduser("~")
    if backend() == "herdr":
        return None, [lambda: herdr_resume(r, cwd)]
    def resume():
        pane, name = tmux_resume(r, cwd)
        if not pane:
            return
        steps = show(pane, f"{SESSION}:{name}")
        for cmd in steps:
            if cmd[:2] == ["tmux", "attach"]:
                os.execvp("tmux", ["tmux", "attach", "-t", pane])
            subprocess.run(cmd)

    return None, [resume]


def ui(scr):
    curses.curs_set(0)
    curses.use_default_colors()
    A = G.curses_attrs(ids=True)   # con ids: el color de cada número de workspace, el de la tira y el header
    MAUVE, GREEN, YELLOW, RED, BLUE, GRAY = (A[k] for k in ("rose", "green", "amber", "red", "iris", "muted"))
    n_ids = len(G.ID_NIGHT)

    def id_attr(n):
        return A[f"id{(int(n) - 1) % n_ids}"] | curses.A_BOLD if n else BLUE
    confirm = None   # ("session", nombre, número, estado): esperando y/n para cerrar un workspace
    st_color = {k: A[G.STATES[k][2]] for k in STATE_TXT}   # el color de cada estado, el mismo que en la tira
    opened, recent = load()
    query, typing, sel, top, msg = "", False, 0, 0, ""

    while True:
        q = query.lower()
        match = lambda r: not q or q in f"{r['proj']} {r['title']} {r.get('window') or ''}".lower()
        items = [("h", "abiertas")] + [("r", r) for r in opened if match(r)] + \
                [("h", "recientes")] + [("r", r) for r in recent if match(r)]
        selectable = [i for i, it in enumerate(items) if it[0] == "r"]
        sel = max(0, min(sel, len(selectable) - 1))
        H, W = scr.getmaxyx()
        body = H - 3
        cur = selectable[sel] if selectable else -1
        if cur < top:
            top = cur
        if cur >= top + body:
            top = cur - body + 1
        scr.erase()
        scr.addnstr(0, 0, " sesiones de Claude ", W - 1, MAUVE | curses.A_BOLD)
        if query or typing:
            scr.addnstr(0, 21, f"/ {query}" + ("▏" if typing else ""), W - 22, YELLOW)
        wcol = min(max([10] + [len(r.get("window") or "afuera") for r in opened]), max(10, W // 3))   # el id de Herdr no entra en 10
        for row, i in enumerate(range(top, min(len(items), top + body)), 1):
            kind, it = items[i]
            if kind == "h":
                scr.addnstr(row, 0, f"─ {it} " + "─" * W, W - 1, MAUVE)
                continue
            attr = curses.A_REVERSE if i == cur else 0
            if it.get("state"):
                mark = "↪" if it.get("handoff") else "●"
                where = it.get("window") or "afuera"
                st = STATE_TXT.get(it["state"], it["state"] or "")
                head = f" {mark} {where:<{wcol}} {it['proj'][:18]:<18} "
                tail = f" {st:<10} {ago(it['mtime']):>12} "
                mid = f"{(it.get('role') or '')[:11]:<11} {it['title']}"
                scr.addnstr(row, 0, " " * (W - 1), W - 1, attr)
                scr.addnstr(row, 0, head, W - 1, attr | (BLUE if it.get("target") else GRAY))
                if it.get("wsid"):   # "ws 3" con el color de su número
                    scr.addnstr(row, 3, where, W - 4, attr | id_attr(it["wsid"]))
                scr.addnstr(row, len(head), mid[: max(0, W - 1 - len(head) - len(tail))], W - 1 - len(head), attr)
                if W - 1 - len(tail) > len(head):
                    scr.addnstr(row, W - 1 - len(tail), tail, len(tail), attr | st_color.get(it["state"], 0))
            else:
                head = f" {'↪' if it.get('handoff') else ' '} {it['proj'][:29]:<29} "
                tail = f" {ago(it['mtime']):>12} "
                scr.addnstr(row, 0, " " * (W - 1), W - 1, attr)
                scr.addnstr(row, 0, head, W - 1, attr | BLUE)
                scr.addnstr(row, len(head), it["title"][: max(0, W - 1 - len(head) - len(tail))], W - 1 - len(head), attr)
                if W - 1 - len(tail) > len(head):
                    scr.addnstr(row, W - 1 - len(tail), tail, len(tail), attr | GRAY)
        help_ = "escribí para buscar · enter abrir · esc listo" if typing else \
            "↑↓ moverse · / buscar · enter abrir · x cerrar · r recargar · q salir"
        if not typing and cur >= 0 and items[cur][1].get("handoff"):
            it = items[cur][1]
            help_ = (f"↪ dejó el resumen para seguir: bk chat --desde {it.get('wsid') or it['sid'][:8]} "
                     "(o «Seguir desde» en alt+n) · " + help_)
        if confirm:
            busy = " ¡su chat está trabajando!" if confirm[3] in ("working", "background", "waiting") else ""
            msg = f"¿Cerrar el workspace {confirm[2] or ''} ({confirm[1]}) con su chat, riel y tira?{busy} y/n"
        scr.addnstr(H - 1, 0, (msg or help_)[: W - 1], W - 1, (RED if msg else GRAY))
        msg = ""
        scr.refresh()

        k = scr.get_wch()
        if confirm:
            if k in ("y", "Y", "s", "S"):
                subprocess.run(["tmux", "kill-session", "-t", f"={confirm[1]}"], capture_output=True)
                opened, recent = load()
            confirm = None
            continue
        if typing:
            if k in ("\x1b", "\n") or k == curses.KEY_ENTER:
                typing = False
                if k != "\x1b":
                    continue
            elif k in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                query = query[:-1]
            elif isinstance(k, str) and k.isprintable():
                query += k
                sel = 0
            continue
        if k in ("q", "\x1b"):
            if query and k == "\x1b":
                query = ""
                continue
            return None
        if k in (curses.KEY_DOWN, "j"):
            sel += 1
        elif k in (curses.KEY_UP, "k"):
            sel -= 1
        elif k == "/":
            typing = True
        elif k == "r":
            opened, recent = load()
        elif k == "x" and cur >= 0:
            it = dict(items[cur][1])
            if it.get("pane") and not it.get("herdr"):   # dónde vive ahora (pudo moverse desde que se cargó la lista)
                it["session"] = tmux_panes().get(it["pane"], {}).get("session")
            what, arg = close_action(it, current_workspace())
            if what == "window":
                subprocess.run(["tmux", "kill-window", "-t", arg], capture_output=True)
                if it.get("sid"):
                    try:
                        os.remove(os.path.join(STATE, it["sid"] + ".json"))
                    except OSError:
                        pass
                opened, recent = load()
            elif what == "session":
                confirm = ("session", arg, it.get("wsid"), it.get("state"))
            else:
                msg = arg
        elif k in ("\n", curses.KEY_ENTER) and cur >= 0:
            err, after = open_row(items[cur][1])
            if err:
                msg = err
            else:
                return after


def main():
    if sys.argv[1:2] == ["revive"]:
        sys.exit(revive(sys.argv[2:]))
    if not sys.stdout.isatty():
        o, r = load()
        for x in o:
            print("↪" if x.get("handoff") else "●", x.get("window") or "afuera", x["proj"], STATE_TXT.get(x.get("state"), ""), x["title"][:60], sep="\t")
        for x in r[:20]:
            print("↪" if x.get("handoff") else " ", x["proj"], ago(x["mtime"]), x["title"][:60], sep="\t")
        return
    after = curses.wrapper(ui)
    for cmd in after or []:
        if callable(cmd):
            cmd()
            continue
        if cmd[:2] == ["tmux", "attach"]:
            os.execvp("tmux", cmd)
        subprocess.run(cmd)


if __name__ == "__main__":
    main()
