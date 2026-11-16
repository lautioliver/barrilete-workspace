#!/usr/bin/env python3
"""bk learn effect: ¿las reglas que aplica cada proyecto bajan los hallazgos que dicen evitar? (ADR-006 D10)

Las reglas son las que el proyecto aplica de verdad: las `accepted` de barrilete-rules en el SHA de su
`.barrilete/rules.lock` (se clona una vez por SHA en ~/.cache/bk/rules/<sha>, como hace sync-rules del kit) más las
propias de `.barrilete/rules/`, filtradas por `scope` ("*" o el proyecto). Ya no lee las lecciones del vault.

Por cada regla con `classes` mide los hallazgos de review de esas clases por ronda de review, en los PRs abiertos
antes y después de su `accepted`, sumando las rondas de todos los proyectos que la aplican. Las rondas salen de
GitHub (todas las reviews con secciones Bloqueantes / Para corregir, también las que no tienen hallazgos).
Si la regla tiene `check`, suma su tasa de fallo: los eventos `check_run` que verify.py del kit deja en
`.barrilete/learning/events.jsonl` (sin eventos: "sin datos").

Además dice qué parte de los hallazgos cae en `other` y qué etiquetas usan las reviews que no están en
`classes.yml` (esas no se mapean a mano: se agregan a barrilete-rules o se corrige la review).

  effect.py [--days N] [--json] [--no-write]   tabla en la terminal y agents/efecto.md en el vault

Para tests: BK_EFFECT_PRS=<json {repo: [PRs]}> reemplaza a GitHub; BK_EFFECT_REPOS=<rutas separadas por :> reemplaza
la lista de repos; BK_RULES_URL=<url git> reemplaza a https://github.com/<repo>.git; BK_RULES_CACHE, a la caché.
"""
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
from deviations import FINDING_SECTION, finding_class, review_findings  # noqa: E402

VAULT = os.path.expanduser(os.environ.get("BARRILETE_VAULT", "~/Documents/Obsidian Vault"))
AG = os.path.join(VAULT, "agents")
RETRO_REPOS_CONF = os.path.expanduser("~/.config/bk/retros.json")
CACHE = os.path.expanduser(os.environ.get("BK_RULES_CACHE", "~/.cache/bk/rules"))
MIN_ROUNDS = 6       # menos rondas después de aceptarla: poca muestra para decir algo
MIN_CASES = 3        # menos hallazgos de la clase antes: no hay qué comparar
SHA = re.compile(r"^[0-9a-f]{40}$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def parse_value(raw):
    """Un valor del frontmatter de una regla: `[a, b]` es una lista; las comillas se sacan (igual que sync-rules)."""
    raw = re.sub(r"\s+#.*$", "", raw).strip()
    if raw.startswith("[") and raw.endswith("]"):
        return [parse_value(x) for x in raw[1:-1].split(",") if x.strip()]
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1]
    return raw


def frontmatter(txt):
    m = re.match(r"---\n(.*?)\n---", txt, re.S)
    out = {}
    for l in (m.group(1) if m else "").splitlines():
        if not l.strip() or l[0] in " \t#":
            continue
        k, _, v = l.partition(":")
        if _:
            out[k.strip()] = parse_value(v)
    return out


def parse_ts(s):
    s = (s or "").strip()
    if not s:
        return None
    try:
        if len(s) == 10:
            return datetime.fromisoformat(s).astimezone()   # fecha sola: medianoche local
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def as_list(v):
    if v in (None, ""):
        return []
    return v if isinstance(v, list) else [v]


def read_lock(root):
    """{repo, sha} del .barrilete/rules.lock del proyecto, o None si no tiene o está mal."""
    path = os.path.join(root, ".barrilete", "rules.lock")
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return None
    lock = {}
    for l in lines:
        l = l.strip()
        if l and not l.startswith("#") and "=" in l:
            k, v = l.split("=", 1)
            lock[k.strip()] = v.strip()
    if not REPO.match(lock.get("repo", "")) or not SHA.match(lock.get("sha", "")):
        return None
    return lock


def store_at(lock):
    """La carpeta de barrilete-rules en el SHA del lock (clonada una vez por SHA). Sale si no puede clonarla."""
    dest = os.path.join(CACHE, lock["sha"])
    if os.path.isdir(os.path.join(dest, "rules")):
        return dest
    url = os.environ.get("BK_RULES_URL") or f"https://github.com/{lock['repo']}.git"
    tmp = dest + f".tmp{os.getpid()}"
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    os.makedirs(CACHE, exist_ok=True)
    for args in (["clone", "--quiet", "--no-checkout", "--", url, tmp],
                 ["-c", "advice.detachedHead=false", "-C", tmp, "checkout", "--quiet", lock["sha"]]):
        r = subprocess.run(["git", *args], capture_output=True, text=True, env=env)
        if r.returncode != 0:
            subprocess.run(["rm", "-rf", tmp])
            sys.exit(f"bk learn effect: no pude traer {lock['repo']}@{lock['sha'][:7]} ({url}): "
                     f"{(r.stderr.strip().splitlines() or [''])[-1][:200]}")
    try:
        os.rename(tmp, dest)
    except OSError:   # otra corrida llegó primero
        subprocess.run(["rm", "-rf", tmp])
    return dest


def load_rules(directory, origin):
    out = {}
    for f in sorted(glob.glob(os.path.join(directory, "*.md"))):
        fm = frontmatter(open(f, encoding="utf-8", errors="replace").read())
        rid = fm.get("id") or os.path.basename(f)[:-3]
        out[rid] = {"id": rid, "status": fm.get("status"), "scope": as_list(fm.get("scope")) or ["*"],
                    "classes": as_list(fm.get("classes")), "check": fm.get("check") or None,
                    "accepted": parse_ts(fm.get("accepted")), "origin": origin}
    return out


def project_of(root, name):
    try:
        p = json.load(open(os.path.join(root, ".agent-kit.json"), encoding="utf-8")).get("project")
        if isinstance(p, str) and p:
            return p
    except (OSError, ValueError, AttributeError):
        pass
    return name


def project_rules(root, name):
    """(reglas accepted que el proyecto aplica, ids de classes.yml de su store). ({}, None) si no tiene rules.lock."""
    lock = read_lock(root)
    if not lock:
        return {}, None
    store = store_at(lock)
    rules = load_rules(os.path.join(store, "rules"), f"{lock['repo']}@{lock['sha'][:7]}")
    rules.update(load_rules(os.path.join(root, ".barrilete", "rules"), ".barrilete/rules"))
    project = project_of(root, name)
    try:
        known = set(re.findall(r"^- id:\s*([a-z0-9-]+)", open(os.path.join(store, "classes.yml"), encoding="utf-8").read(), re.M))
    except OSError:
        known = None
    applied = {rid: r for rid, r in rules.items()
               if r["status"] == "accepted" and ("*" in r["scope"] or project in r["scope"] or name in r["scope"])}
    return applied, known


def check_runs(root):
    """{rule_id o check: [runs, fails]} de los eventos check_run de .barrilete/learning/events.jsonl."""
    out = {}
    try:
        lines = open(os.path.join(root, ".barrilete", "learning", "events.jsonl"), encoding="utf-8").read().splitlines()
    except OSError:
        return out
    for l in lines:
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if not isinstance(e, dict) or e.get("kind") != "check_run" or e.get("outcome") not in ("pass", "fail"):
            continue
        for key in {k for k in (e.get("rule_id"), e.get("check")) if isinstance(k, str) and k}:
            c = out.setdefault(key, [0, 0])
            c[0] += 1
            c[1] += e["outcome"] == "fail"
    return out


def repos():
    """[(ruta, nombre, owner/nombre o None)] de los repos de ~/.config/bk/retros.json (o BK_EFFECT_REPOS)."""
    env = os.environ.get("BK_EFFECT_REPOS")
    if env:
        rs = [r for r in env.split(":") if r]
    else:
        try:
            rs = json.load(open(RETRO_REPOS_CONF)).get("repos", [])
        except (OSError, ValueError):
            rs = ["~/barrilete-kit"]
    out = []
    for r in rs:
        path = os.path.expanduser(r)
        try:
            url = subprocess.run(["git", "-C", path, "remote", "get-url", "origin"], capture_output=True, text=True).stdout
        except OSError:
            url = ""
        m = re.search(r"github\.com[:/]([^/]+/[^/\s]+?)(?:\.git)?\s*$", url or "")
        full = m.group(1) if m else None
        out.append((path, full.split("/")[-1] if full else os.path.basename(path.rstrip("/")), full))
    return out


def fetch_prs(repo_list):
    """{nombre: [{number, createdAt, reviews}]}. BK_EFFECT_PRS=<archivo json> lo reemplaza (tests)."""
    fx = os.environ.get("BK_EFFECT_PRS")
    if fx:
        return json.load(open(fx))
    env = {k: v for k, v in os.environ.items() if k not in ("GH_CONFIG_DIR", "GH_TOKEN")}
    out = {}
    for _, name, full in repo_list:
        if not full:
            continue
        p = subprocess.run(["gh", "pr", "list", "--repo", full, "--state", "all", "--limit", "200",
                            "--json", "number,createdAt,reviews"], capture_output=True, text=True, env=env, timeout=90)
        if p.returncode != 0:
            sys.exit(f"bk learn effect: no pude leer los PRs de {full}: {p.stderr.strip()[:200]}")
        out[name] = json.loads(p.stdout or "[]")
    return out


def rounds(prs_by_repo):
    """Cada review con secciones de hallazgos es una ronda: (repo, PR, creado, [clases de sus hallazgos])."""
    out = []
    for repo, prs in prs_by_repo.items():
        for p in prs:
            created = parse_ts(p.get("createdAt"))
            for r in p.get("reviews") or []:
                body = r.get("body") or ""
                if not any(FINDING_SECTION.match(l) for l in body.splitlines()):
                    continue
                out.append({"repo": repo, "pr": p["number"], "created": created,
                            "classes": [finding_class(i) for i in review_findings(body)]})
    return out


def stats(rs, classes):
    n = len(rs)
    total = sum(len(r["classes"]) for r in rs)
    cls = sum(1 for r in rs for c in r["classes"] if c in classes)
    return {"rounds": n, "prs": len({(r["repo"], r["pr"]) for r in rs}), "findings": total, "class": cls,
            "rate": cls / n if n else None, "share": cls / total if total else None}


def verdict(b, a):
    if a["rounds"] < MIN_ROUNDS:
        return "poca muestra", f"solo {a['rounds']} rondas después; esperar"
    if not b["rounds"]:
        return "sin antes", "no hay rondas de antes para comparar"
    if not b["class"]:
        return "no había", "la clase no aparecía antes: la regla no tiene qué bajar"
    if b["class"] < MIN_CASES:
        return "pocos casos", f"solo {b['class']} hallazgo(s) de la clase antes: no alcanza para comparar"
    if a["rate"] <= b["rate"] * 0.5:
        return "baja", "la clase bajó a la mitad o menos"
    if a["rate"] < b["rate"] or (a["share"] is not None and b["share"] and a["share"] < b["share"] * 0.75):
        return "baja algo", "baja, pero poco: mirar de nuevo con más rondas"
    return "no baja", "reescribirla (más concreta, en el momento justo) o retirarla"


def class_summary(rs, known, since):
    """Qué parte de los hallazgos de las rondas desde `since` cae en other, y las etiquetas fuera de classes.yml."""
    recent = [c for r in rs if r["created"] and r["created"] >= since for c in r["classes"]]
    unknown = {}
    for r in rs:
        for c in r["classes"]:
            if c != "other" and known.get(r["repo"]) is not None and c not in known[r["repo"]]:
                unknown[c] = unknown.get(c, 0) + 1
    return {"since": since.strftime("%Y-%m-%d"), "findings": len(recent), "other": recent.count("other"),
            "share": recent.count("other") / len(recent) if recent else None,
            "unknown": dict(sorted(unknown.items(), key=lambda kv: (-kv[1], kv[0])))}


def measure(days):
    repo_list = repos()
    rs = rounds(fetch_prs(repo_list))
    applied, known, runs = {}, {}, {}
    for path, name, _ in repo_list:
        rules, known[name] = project_rules(path, name)
        for rid, r in rules.items():
            applied.setdefault(rid, dict(r, repos=[]))["repos"].append(name)
        for k, (n, f) in check_runs(path).items():
            c = runs.setdefault(k, [0, 0])
            c[0] += n
            c[1] += f
    res = []
    for rid, rule in sorted(applied.items()):
        row = {"rule": rid, "classes": rule["classes"], "repos": rule["repos"], "check": rule["check"]}
        if rule["check"]:
            n, f = runs.get(rid) or runs.get(rule["check"]) or [0, 0]
            row["check_runs"] = {"runs": n, "fails": f, "rate": f / n if n else None}
        if not rule["classes"]:
            row.update(verdict="no se mide", why="sin classes en la regla")
        elif not rule["accepted"]:
            row.update(verdict="sin fecha", why="falta accepted: en la regla")
        else:
            acc = rule["accepted"]
            mine = [r for r in rs if r["repo"] in rule["repos"]]
            before = [r for r in mine if r["created"] and acc - timedelta(days=days) <= r["created"] < acc]
            after = [r for r in mine if r["created"] and r["created"] >= acc]
            b, a = stats(before, rule["classes"]), stats(after, rule["classes"])
            v, why = verdict(b, a)
            row.update(accepted=acc.astimezone().strftime("%Y-%m-%d %H:%M"), before=b, after=a, verdict=v, why=why)
        res.append(row)
    since = datetime.now(timezone.utc) - timedelta(days=days)
    return {"rules": res, "classes": class_summary(rs, known, since)}


def fmt(x, pct=False):
    if x is None:
        return "—"
    return f"{x * 100:.0f}%" if pct else f"{x:.2f}"


def check_txt(r):
    c = r.get("check_runs")
    if not c:
        return "sin check"
    if not c["runs"]:
        return f"`{r['check']}`: sin datos"
    return f"`{r['check']}`: falla {c['fails']} de {c['runs']} ({fmt(c['rate'], True)})"


def summary_lines(cs):
    out = [f"Hallazgos en `other` desde el {cs['since']}: {cs['other']} de {cs['findings']}"
           + (f" ({fmt(cs['share'], True)})" if cs["share"] is not None else "") + "."]
    if cs["unknown"]:
        out.append("Etiquetas que no están en classes.yml: "
                   + ", ".join(f"`{k}` ({v})" for k, v in cs["unknown"].items())
                   + ". Sumarlas a barrilete-rules o corregir la review.")
    return out


def render(data, days):
    res = data["rules"]
    lines = [f"# Efecto de las reglas\n",
             f"Generado por `bk learn effect` el {datetime.now().strftime('%Y-%m-%d %H:%M')}. Reglas que aplica cada proyecto "
             "(barrilete-rules en el SHA de su `rules.lock` y `.barrilete/rules/`). Hallazgos de review de las clases "
             f"que la regla quiere evitar, por ronda de review, en PRs abiertos hasta {days} días antes de aceptarla y "
             "después. *Parte* = qué parte de todos los hallazgos son de esa clase (no sube si las reviews se "
             "ponen más duras).\n",
             "| regla | clases | proyectos | aceptada | antes: por ronda (parte) · rondas | después: por ronda (parte) · rondas | check | veredicto |",
             "|---|---|---|---|---|---|---|---|"]
    for r in res:
        b, a = r.get("before"), r.get("after")
        lines.append(
            f"| `{r['rule']}` | {', '.join(r['classes']) or '—'} | {', '.join(r['repos'])} | {r.get('accepted', '—')} | "
            + (f"{fmt(b['rate'])} ({fmt(b['share'], True)}) · {b['rounds']}" if b else "—") + " | "
            + (f"{fmt(a['rate'])} ({fmt(a['share'], True)}) · {a['rounds']}" if a else "—") + " | "
            + f"{check_txt(r)} | **{r['verdict']}**: {r['why']} |")
    lines += [""] + summary_lines(data["classes"])
    lines += ["", "Veredictos:",
              "- **baja**: la clase bajó a la mitad o menos.",
              "- **baja algo**: baja poco.",
              "- **no baja**: para pasar a check, reescribir o retirar (decide la persona, ADR-006 D10).",
              f"- **poca muestra**: menos de {MIN_ROUNDS} rondas después; esperar.",
              f"- **pocos casos**: menos de {MIN_CASES} hallazgos de la clase antes.",
              "",
              "`accepted` y `classes` salen del frontmatter de cada regla: se corrigen en barrilete-rules o en `.barrilete/rules/`.", ""]
    return "\n".join(lines)


def main(argv):
    days = int(argv[argv.index("--days") + 1]) if "--days" in argv else 30
    data = measure(days)
    if "--json" in argv:
        print(json.dumps(data, ensure_ascii=False, default=str))
        return 0
    for r in data["rules"]:
        b, a = r.get("before"), r.get("after")
        head = f"{r['verdict']:<13} {r['rule']}"
        if b and a:
            head += (f"  antes {fmt(b['rate'])}/ronda ({fmt(b['share'], True)}, {b['rounds']} rondas)"
                     f" → después {fmt(a['rate'])}/ronda ({fmt(a['share'], True)}, {a['rounds']} rondas)")
        print(head)
        print(f"{'':<14}{r['why']}" + (f" · {check_txt(r)}" if r.get("check") else ""))
    if not data["rules"]:
        print("Ningún repo tiene reglas accepted que medir (¿falta .barrilete/rules.lock?).")
    print()
    for l in summary_lines(data["classes"]):
        print(l)
    if "--no-write" not in argv and os.path.isdir(AG):
        with open(os.path.join(AG, "efecto.md"), "w", encoding="utf-8") as f:
            f.write(render(data, days))
        print(f"\n→ {os.path.join(AG, 'efecto.md')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
