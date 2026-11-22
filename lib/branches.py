#!/usr/bin/env python3
"""Las ramas de cada proyecto y cuáles se pueden borrar sin perder nada (bk _hub branches, alt+b, la limpieza sola).

Una rama está **terminada** si entró a la principal:
  - su PR está mergeado y la rama apunta al mismo commit que el PR (si después se le sumó algo, ya no: eso no entró), o
  - bk land la entró (lo anota en landed.json) y la rama sigue en ese commit.
Una rama que solo está "contenida" en main (una recién creada, sin commits) no cuenta como terminada para la limpieza
sola: puede ser trabajo que recién empieza. A mano (ctrl+x en alt+b) sí se puede borrar, porque no se pierde nada.

Se borra (worktree, rama local y la del remoto si apunta al mismo commit) solo si además:
  - no es la rama principal ni la que tiene el checkout principal,
  - su worktree no tiene nada sin commitear (ni archivos nuevos) y
  - ningún proceso tiene su carpeta de trabajo adentro del worktree (un chat o un agente trabajando ahí).
`git worktree remove` va sin --force: si git ve algo, frena él también.

  branches.py list [dir…]      el JSON de bk _hub branches
  branches.py rm <repo> <rama> borrar una (lo de ctrl+x)
  branches.py sweep [--dry-run] la limpieza sola: borra las terminadas de todos los proyectos
"""
import json
import os
import re
import subprocess
import sys
import time

PR_TTL = 120          # cuánto vale la lista de PRs de un repo (s)
SWEEP_EVERY = 600     # cada cuánto corre la limpieza sola (s)
GH_TIMEOUT = 20


def cache_dir():
    base = os.environ.get("BK_CACHE_DIR") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "bk")
    return base


def landed_path():
    return os.path.join(cache_dir(), "landed.json")


def git(top, *a, timeout=10):
    try:
        p = subprocess.run(["git", "-C", top, *a], capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"})
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.SubprocessError) as e:
        return 1, "", str(e)


def out(top, *a, timeout=10):
    rc, o, _ = git(top, *a, timeout=timeout)
    return o if rc == 0 else ""


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


# ---------- el repo ----------
def project_top(d):
    """El repo principal, aunque d sea un worktree. "" fuera de un repo."""
    common = out(d, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    if common.endswith("/.git"):
        return common[: -len("/.git")]
    return out(d, "rev-parse", "--show-toplevel").strip()


def remote_of(top):
    """(remoto, owner/repo) del primer remoto de GitHub: origin primero (workspace usa respaldo). ("", "") sin."""
    names = out(top, "remote").split()
    for r in sorted(names, key=lambda n: n != "origin"):
        m = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?/?$", out(top, "remote", "get-url", r).strip())
        if m:
            return r, m.group(1)
    return "", ""


def default_branch(top, remote):
    if remote:
        ref = out(top, "symbolic-ref", "-q", "--short", f"refs/remotes/{remote}/HEAD").strip()
        if ref.startswith(remote + "/"):
            return ref[len(remote) + 1:]
    for b in ("main", "master"):
        if git(top, "show-ref", "-q", "--verify", f"refs/heads/{b}")[0] == 0:
            return b
    return out(top, "branch", "--show-current").strip() or "main"


def worktrees(top):
    """{rama: carpeta} de los worktrees (sin el principal) y la rama del checkout principal."""
    wts, main_branch, cur = {}, "", None
    for line in out(top, "worktree", "list", "--porcelain").splitlines() + [""]:
        if line.startswith("worktree "):
            cur = {"path": line[len("worktree "):]}
        elif line.startswith("branch ") and cur is not None:
            cur["branch"] = line[len("branch refs/heads/"):]
        elif not line and cur:
            if os.path.realpath(cur["path"]) == os.path.realpath(top):
                main_branch = cur.get("branch", "")
            elif cur.get("branch"):
                wts[cur["branch"]] = cur["path"]
            cur = None
    return wts, main_branch


def local_branches(top):
    fmt = "%(refname:short)%00%(objectname)%00%(committerdate:unix)%00%(subject)"
    rows = []
    for line in out(top, "for-each-ref", f"--format={fmt}", "refs/heads").splitlines():
        p = line.split("\0")
        if len(p) == 4:
            rows.append({"name": p[0], "sha": p[1], "ts": int(p[2] or 0), "subject": p[3]})
    return rows


def remote_tips(top, remote):
    """{rama: sha} de las ramas del remoto que git ya conoce (sin fetch: lo hace sweep, una vez)."""
    if not remote:
        return {}
    tips = {}
    for line in out(top, "for-each-ref", "--format=%(refname)%00%(objectname)", f"refs/remotes/{remote}").splitlines():
        ref, _, sha = line.partition("\0")
        name = ref[len(f"refs/remotes/{remote}/"):]
        if name != "HEAD":
            tips[name] = sha
    return tips


def dirty(path):
    return len([l for l in out(path, "status", "--porcelain").splitlines() if l.strip()])


def busy_dirs():
    """Las carpetas de trabajo de todos los procesos del usuario (lsof). Si lsof falla: None (nada es seguro)."""
    try:
        p = subprocess.run(["lsof", "-a", "-d", "cwd", "-u", str(os.getuid()), "-Fn"], capture_output=True,
                           text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode not in (0, 1) or not p.stdout:
        return None
    return {os.path.realpath(l[1:]) for l in p.stdout.splitlines() if l.startswith("n/")}


def in_use(path, busy):
    if busy is None:
        return True
    real = os.path.realpath(path)
    return any(d == real or d.startswith(real + "/") for d in busy)


# ---------- GitHub y bk land ----------
def prs(slug, fresh=False):
    """{rama: el PR más nuevo de esa rama} de los últimos 200 (abiertos, cerrados y mergeados). Se guarda PR_TTL s.
    Sin conexión: lo último guardado, o {}."""
    if not slug:
        return {}, False
    path = os.path.join(cache_dir(), "hub", "branches-prs-" + re.sub(r"[^A-Za-z0-9._-]", "_", slug) + ".json")
    old = read_json(path)
    if isinstance(old, dict) and not fresh and 0 <= time.time() - old.get("ts", 0) < PR_TTL:
        return old.get("data") or {}, False
    try:
        p = subprocess.run(["gh", "pr", "list", "-R", slug, "--state", "all", "--limit", "200", "--json",
                            "number,state,headRefName,headRefOid,url,title"], capture_output=True, text=True,
                           timeout=GH_TIMEOUT)
        rows = json.loads(p.stdout) if p.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        rows = None
    if not isinstance(rows, list):
        return ((old or {}).get("data") or {}), True
    data = {}
    for r in sorted(rows, key=lambda r: r.get("number", 0)):
        data[r.get("headRefName") or ""] = {"n": r.get("number"), "state": (r.get("state") or "").lower(),
                                            "sha": r.get("headRefOid") or "", "url": r.get("url") or "",
                                            "title": r.get("title") or ""}
    write_json(path, {"ts": time.time(), "data": data})
    return data, False


def note_landed(top, branch, sha):
    """bk land: esta rama entró a main en este commit (la limpieza sola la puede borrar mientras siga ahí)."""
    path = landed_path()
    data = read_json(path)
    data = data if isinstance(data, dict) else {}
    data.setdefault(os.path.realpath(top), {})[branch] = sha
    write_json(path, data)


def landed(top):
    data = read_json(landed_path())
    return (data or {}).get(os.path.realpath(top), {}) if isinstance(data, dict) else {}


# ---------- el estado de cada rama ----------
def info(top, busy=None, fresh=False, with_busy=True):
    """{project, path, repo, base, stale, items: [rama…]} de un repo. Cada rama: {name, sha, ts, subject, worktree,
    dirty, ahead, pr, remote, done, how, contained, busy, can_rm, why}."""
    remote, slug = remote_of(top)
    base = default_branch(top, remote)
    wts, main_branch = worktrees(top)
    pr_by, stale = prs(slug, fresh)
    done_land = landed(top)
    tips = remote_tips(top, remote)
    if with_busy and busy is None:
        busy = busy_dirs()
    items = []
    for b in local_branches(top):
        name, sha = b["name"], b["sha"]
        if name == base:
            continue
        wt = wts.get(name)
        pr = pr_by.get(name)
        how = ""
        if pr and pr["state"] == "merged" and pr["sha"] == sha:
            how = f"PR #{pr['n']} mergeado"
        elif done_land.get(name) == sha:
            how = "entró con bk land"
        contained = git(top, "merge-base", "--is-ancestor", sha, base)[0] == 0
        ahead = 0 if contained else len(out(top, "rev-list", f"{base}..{sha}").split())
        d = dirty(wt) if wt and os.path.isdir(wt) else 0
        use = bool(wt) and with_busy and in_use(wt, busy)
        why = ""
        if name == main_branch:
            why = "es la rama del checkout principal"
        elif not how and not contained:
            why = (f"PR #{pr['n']} abierto" if pr and pr["state"] == "open" else
                   f"tiene {ahead} commit{'s' if ahead != 1 else ''} que no están en {base}")
        elif d:
            why = f"su worktree tiene {d} cambio{'s' if d != 1 else ''} sin commitear"
        elif use:
            why = "hay un proceso trabajando en su worktree"
        items.append({"name": name, "sha": sha, "ts": b["ts"], "subject": b["subject"], "worktree": wt or "",
                      "dirty": d, "ahead": ahead, "pr": pr, "remote": tips.get(name) == sha, "done": bool(how),
                      "how": how, "contained": contained, "busy": use, "can_rm": not why, "why": why})
    items.sort(key=lambda r: (not r["done"], -r["ts"]))
    return {"project": os.path.basename(top.rstrip("/")), "path": top, "repo": slug, "base": base, "stale": stale,
            "items": items}


def remove(top, name, sweep=False, busy=None):
    """Borra el worktree, la rama y la del remoto (si apunta al mismo commit). sweep: solo si está terminada (no
    alcanza con estar contenida en main). Devuelve (ok, texto)."""
    data = info(top, busy=busy)
    row = next((r for r in data["items"] if r["name"] == name), None)
    if row is None:
        return False, f"no existe la rama {name}"
    if not row["can_rm"]:
        return False, f"{name}: {row['why']}"
    if sweep and not row["done"]:
        return False, f"{name}: no está terminada"
    if row["worktree"]:
        rc, _, err = git(top, "worktree", "remove", row["worktree"])
        if rc != 0:
            return False, f"{name}: git no quiso borrar el worktree: {err.strip()}"
    rc, _, err = git(top, "branch", "-D", name)
    if rc != 0:
        return False, f"{name}: git no quiso borrar la rama: {err.strip()}"
    remote, _ = remote_of(top)
    gone_remote = False
    if row["remote"] and remote:
        gone_remote = git(top, "push", "-q", remote, "--delete", name, timeout=30)[0] == 0
    return True, name + (" (también en GitHub)" if gone_remote else "")


# ---------- la limpieza sola ----------
def projects():
    """Los repos donde bk trabaja: los de BK_PROJECTS (separados por :) o los de bk new (espacios y recientes)."""
    env = os.environ.get("BK_PROJECTS")
    if env is not None:
        dirs = [d for d in env.split(":") if d]
    else:
        sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
        import herdr_hub as HUB
        try:
            dirs = [p["path"] for p in HUB.projects([])["items"]]
        except Exception:
            dirs = []
    tops, seen = [], set()
    for d in dirs:
        top = project_top(d) if os.path.isdir(d) else ""
        if top and os.path.realpath(top) not in seen:
            seen.add(os.path.realpath(top))
            tops.append(top)
    return tops


def sweep(dry=False):
    """Borra las ramas terminadas de todos los proyectos. {removed: [{project, branch}], kept: […]}."""
    busy = busy_dirs()
    removed, failed = [], []
    for top in projects():
        remote, _ = remote_of(top)
        if remote and not dry:
            git(top, "fetch", "-q", "--prune", remote, timeout=30)
        for row in info(top, busy=busy, fresh=True)["items"]:
            if not row["done"] or not row["can_rm"]:
                continue
            if dry:
                removed.append({"project": os.path.basename(top), "branch": row["name"]})
                continue
            ok, text = remove(top, row["name"], sweep=True, busy=busy)
            (removed if ok else failed).append({"project": os.path.basename(top), "branch": row["name"], "text": text})
    return {"removed": removed, "failed": failed, "dry": dry}


def due():
    """¿Toca correr la limpieza sola? Marca la hora si sí (una sola corrida cada SWEEP_EVERY)."""
    stamp = os.path.join(cache_dir(), "branches-sweep.stamp")
    try:
        if time.time() - os.path.getmtime(stamp) < SWEEP_EVERY:
            return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(stamp), exist_ok=True)
    with open(stamp, "w") as f:
        f.write(str(int(time.time())))
    return True


def main(argv):
    cmd, args = (argv[0] if argv else ""), argv[1:]
    if cmd == "list":
        dirs = [a for a in args if a != "--fresh"]
        tops = [project_top(d) for d in dirs] if dirs else projects()
        busy = busy_dirs()
        print(json.dumps({"projects": [info(t, busy=busy, fresh="--fresh" in args) for t in tops if t]},
                         ensure_ascii=False))
        return 0
    if cmd == "rm" and len(args) == 2:
        ok, text = remove(project_top(args[0]) or args[0], args[1])
        print(text)
        return 0 if ok else 1
    if cmd == "sweep":
        print(json.dumps(sweep("--dry-run" in args), ensure_ascii=False))
        return 0
    print("uso: branches.py list [dir…] [--fresh] | rm <repo> <rama> | sweep [--dry-run]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
