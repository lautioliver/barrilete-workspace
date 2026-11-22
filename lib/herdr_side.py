#!/usr/bin/env python3
"""Los datos del panel derecho de bk en Herdr (herdr/mods/lado), en un JSON: lo que mostraba el riel de tmux
(lib/rail.py: Status y Changes), sin dibujar nada.

  herdr_side.py <carpeta> [--usage] [--account <nombre>]     (bk _side <carpeta> …)

  project, path   el proyecto de esa carpeta: su repo principal aunque la carpeta sea un worktree
  branch, dirty   la rama de la carpeta y cuántos archivos tiene sin commitear
  profile         [{role, model, mode}] de `bk roles` en el proyecto (model con su provider si no es claude)
  profile_name    el perfil de modelos activo (bk profile), o ""
  changes         [{name, branch, path, files: [{code, path, add, del}], more}] por cada worktree del proyecto con
                  algo sin commitear (hasta MAX_FILES archivos; `more` dice cuántos quedaron afuera)
  context         {tokens, level, limit} de la sesión de Claude más reciente de esa carpeta (level: "", "warn"
                  desde 3/4 del umbral, "high" desde el umbral; limit: el umbral de bk context), o null si no tiene
  usage           solo con --usage (lee los transcripts, tarda más): tokens y costo de hoy, acá y en total
  email           el mail de la cuenta de Claude de esa terminal (--account, la etiqueta bk.account; sin ella, la
                  de siempre), o null si no tiene sesión iniciada

Fuera de un repo de git: project y branch vacíos, sin changes.

Lo corre Herdr cada pocos segundos, así que cuida la máquina: los git son de solo lectura y no toman el index.lock
(GIT_OPTIONAL_LOCKS=0: no le traban un commit a un agente), el worktree de la carpeta se mira siempre y los demás se
guardan en ~/.cache/bk/side/ hasta BK_SIDE_TTL segundos (20), o hasta que cambie su index, su HEAD o su carpeta
(un commit, un archivo nuevo arriba de todo). Los que hay que mirar se miran en paralelo. Solo escribe ese caché.
"""
import hashlib, json, os, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.realpath(__file__))
MAX_FILES = 40
CACHE = os.path.join(os.environ.get("BK_CACHE_DIR", os.path.expanduser("~/.cache/bk")), "side")
GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0")


def ttl():
    try:
        return float(os.environ.get("BK_SIDE_TTL", "20"))
    except ValueError:
        return 20.0


def sh(*a, cwd=None, timeout=6):
    try:
        env = GIT_ENV if a and a[0] == "git" else None
        return subprocess.run(a, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def project_top(cwd):
    """El repo principal: el mismo aunque cwd sea un worktree (como project_top de bin/bk)."""
    common = sh("git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    if common.endswith("/.git"):
        return common[: -len("/.git")]
    return sh("git", "-C", cwd, "rev-parse", "--show-toplevel").strip()


def worktrees(top):
    """Las carpetas de cada worktree del proyecto (las usa también lib/herdr_hub.py)."""
    return [w for w, _ in worktrees_git(top)]


def worktrees_git(top):
    """[(carpeta, su gitdir)] de cada worktree del proyecto; el gitdir sale de .git/worktrees, sin otro git."""
    out, cur = [], None
    for l in sh("git", "-C", top, "worktree", "list", "--porcelain").splitlines():
        if l.startswith("worktree "):
            cur = l[len("worktree "):]
            out.append(cur)
    if not out:
        return [(top, os.path.join(top, ".git"))]
    common = os.path.join(top, ".git")
    names = {}
    wdir = os.path.join(common, "worktrees")
    try:
        for n in os.listdir(wdir):
            try:
                with open(os.path.join(wdir, n, "gitdir")) as f:
                    names[os.path.dirname(f.read().strip())] = os.path.join(wdir, n)
            except OSError:
                pass
    except OSError:
        pass
    return [(w, common if w == top else names.get(w, "")) for w in out]


def stamp(root, gitdir):
    """Lo que cambia sin abrir un proceso cuando algo pasa en el worktree: su index, su HEAD y su carpeta."""
    out = []
    for p in (os.path.join(gitdir, "index") if gitdir else "", os.path.join(gitdir, "HEAD") if gitdir else "", root):
        try:
            out.append(os.stat(p).st_mtime_ns) if p else out.append(0)
        except OSError:
            out.append(0)
    return out


def cache_file(top):
    return os.path.join(CACHE, hashlib.sha1(top.encode()).hexdigest()[:16] + ".json")


def load_cache(top):
    try:
        with open(cache_file(top)) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_cache(top, d):
    try:
        os.makedirs(CACHE, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=CACHE, suffix=".tmp")
        with os.fdopen(fd, "w") as f:
            json.dump(d, f)
        os.replace(tmp, cache_file(top))
    except OSError:
        pass


def all_changes(top, here):
    """changes_of de cada worktree: el de `here` siempre fresco, los demás del caché si siguen valiendo."""
    wts = worktrees_git(top)
    old, now, limit = load_cache(top), time.time(), ttl()
    keep, todo = {}, []
    for root, gitdir in wts:
        st = stamp(root, gitdir)
        c = old.get(root)
        mine = here == root or here.startswith(root + os.sep)
        if not mine and c and c.get("stamp") == st and now - c.get("at", 0) < limit:
            keep[root] = c
        else:
            todo.append((root, st))
    if todo:
        with ThreadPoolExecutor(max_workers=min(8, len(todo))) as ex:
            for (root, st), ch in zip(todo, ex.map(lambda t: changes_of(t[0]), todo)):
                keep[root] = {"at": now, "stamp": st, "changes": ch}
        save_cache(top, keep)
    return [keep[r]["changes"] for r, _ in wts if keep.get(r, {}).get("changes")]


def changes_of(root):
    st = [l for l in sh("git", "-C", root, "status", "--porcelain").splitlines() if l.strip()]
    if not st:
        return None
    num = {}
    for l in sh("git", "-C", root, "diff", "--numstat", "HEAD").splitlines():
        p = l.split("\t")
        if len(p) == 3:
            num[p[2]] = (p[0], p[1])
    files = []
    for l in st[:MAX_FILES]:
        code, path = l[:2].strip() or "M", l[3:]
        a, d = num.get(path, ("", ""))
        files.append({"code": "A" if code == "??" else code, "path": path,
                      "add": a if a != "-" else "", "del": d if d != "-" else ""})
    return {"name": os.path.basename(root), "path": root, "files": files, "more": max(0, len(st) - MAX_FILES),
            "branch": sh("git", "-C", root, "branch", "--show-current").strip()}


def profile(top):
    rows = []
    for l in sh(os.path.join(os.path.dirname(HERE), "bin", "bk"), "roles", cwd=top or None).splitlines():
        p = l.split()
        if len(p) >= 2 and "/" in p[1]:
            prov, _, model = p[1].partition("/")
            rows.append({"role": p[0], "model": model if prov == "claude" else p[1], "mode": p[2] if len(p) > 2 else ""})
    return rows


def profile_name():
    """El perfil de modelos activo (bk profile), o "" si no hay o ya no existe."""
    sys.path.insert(0, HERE)
    import profiles as PR
    return PR.data()["active"] or ""


def usage(name):
    try:
        u = json.loads(sh(sys.executable, os.path.join(HERE, "usage.py"), "--json", timeout=20))
    except ValueError:
        return None
    mine = [v for k, v in u.get("by_project", {}).items() if name and (k == name or k.startswith(name + "#"))]
    return {"tokens": u.get("tokens", 0), "cost": u.get("cost_usd", 0),
            "here_tokens": sum(v["tokens"] for v in mine), "here_cost": sum(v["cost"] for v in mine)}


def context(cwd):
    sys.path.insert(0, HERE)
    import usage as U
    return U.context_of_cwd(cwd)


def main():
    argv = sys.argv[1:]
    acct = argv[argv.index("--account") + 1] if "--account" in argv[:-1] else ""
    if "--account" in argv:
        i = argv.index("--account")
        del argv[i:i + 2]
    args = [a for a in argv if not a.startswith("--")]
    cwd = os.path.abspath(os.path.expanduser(args[0] if args else "."))
    home = os.path.expanduser("~")
    top = project_top(cwd) if os.path.isdir(cwd) else ""
    out = {"project": os.path.basename(top) if top else "", "path": (top or cwd).replace(home, "~", 1),
           "branch": "", "dirty": 0, "profile": profile(top), "profile_name": profile_name(), "changes": [],
           "context": context(cwd)}
    if top:
        out["branch"] = sh("git", "-C", cwd, "branch", "--show-current").strip()
        out["dirty"] = len([l for l in sh("git", "-C", cwd, "status", "--porcelain").splitlines() if l.strip()])
        out["changes"] = all_changes(top, os.path.realpath(cwd))
    if "--usage" in sys.argv:
        out["usage"] = usage(out["project"])
    sys.path.insert(0, HERE)
    import accounts as ACC
    out["email"] = ACC.email(acct)
    json.dump(out, sys.stdout, ensure_ascii=False)
    print()


if __name__ == "__main__":
    main()
