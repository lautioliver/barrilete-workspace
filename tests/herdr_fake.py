#!/usr/bin/env python3
"""Un Herdr falso para tests/test_herdr.sh: `herdr_fake.py app …` hace de herdr-app y `herdr_fake.py hc …` de hc.

Guarda espacios, pestañas y terminales en $HD_FAKE/state.json y anota en $HD_FAKE/log lo que cambia algo
(app do …, hc send/kill/label). Nunca toca el Herdr real.
  $HD_FAKE/closed          si existe, la ventana está cerrada: herdr-app status / ls / do salen con 1
  $HD_FAKE/screen-<t>      lo que devuelve `hc read <t>`
  $HD_FAKE/fail-label      si existe, `hc label` falla (para probar que bk no deja un agente sin etiquetas)
  $HD_FAKE/machines        las otras máquinas de `hc machine ls`, una por línea: <nombre> [estado]
  $HD_FAKE/exec-<m>-<sub>  lo que imprime `hc exec --on <m> bk <sub> …`; si no está, la máquina no responde
Una terminal de otra máquina es una entrada más de terms, con la dirección <máquina>/<t> (un test la agrega).
"""
import json
import os
import sys

FAKE = os.environ["HD_FAKE"]
STATE = os.path.join(FAKE, "state.json")


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"n": 0, "tabs": 0, "spaces": [], "terms": {}, "view": [None, None]}


def save(st):
    with open(STATE, "w") as f:
        json.dump(st, f)


def log(line):
    with open(os.path.join(FAKE, "log"), "a") as f:
        f.write(line + "\n")


def out(obj, rc=0):
    print(json.dumps(obj))
    sys.exit(rc)


def new_term(st, space, tab, folder, argv):
    st["n"] += 1
    addr = f"t{st['n']}"
    st["terms"][addr] = {"labels": {"herdr.space": space, "herdr.tab": tab}, "cwd": folder, "argv": argv}
    return addr


def app(args):
    st = load()
    if os.path.exists(os.path.join(FAKE, "closed")):
        sys.stderr.write("herdr-app: no window\n")
        sys.exit(1)
    cmd = args[0] if args else ""
    if cmd == "status":
        out({"space": st["view"][0], "tab": st["view"][1], "layout": "main"})
    if cmd == "ls":
        out({"spaces": [{"id": s["id"], "name": s["name"], "folder": s["folder"], "machine": None,
                         "tabs": [{"id": t["id"], "name": t["name"],
                                   "terminals": [{"terminal": a} for a in t["terminals"]]} for t in s["tabs"]]}
                        for s in st["spaces"]]})
    if cmd != "do":
        sys.exit(2)
    name = args[1]
    a = {}
    rest = args[2:]
    if rest and rest[0].startswith("{"):
        a = json.loads(rest[0])
    else:
        for k, v in zip(rest[0::2], rest[1::2]):
            a[k.lstrip("-")] = v
    log("app do %s %s" % (name, json.dumps(a, sort_keys=True, ensure_ascii=False)))
    if name == "space.new":
        st["tabs"] += 1
        sp = {"id": f"sp{len(st['spaces']) + 1}", "name": a.get("name", ""), "folder": a.get("folder", ""), "tabs": []}
        tb = {"id": f"tb{st['tabs']}", "name": a.get("tab", ""), "terminals": []}
        addr = new_term(st, sp["id"], tb["id"], a.get("folder", ""), a.get("argv") or [])
        tb["terminals"].append(addr)
        sp["tabs"].append(tb)
        st["spaces"].append(sp)
        st["view"] = [sp["id"], tb["id"]]   # Herdr muestra lo nuevo
        save(st)
        out({"space": sp["id"], "tab": tb["id"], "terminal": addr})
    if name == "tab.new":
        sp = next((s for s in st["spaces"] if s["id"] == a.get("space")), None)
        if not sp:
            out({"error": "no such space"}, 1)
        st["tabs"] += 1
        tb = {"id": f"tb{st['tabs']}", "name": a.get("name", ""), "terminals": []}
        addr = new_term(st, sp["id"], tb["id"], a.get("folder", ""), a.get("argv") or [])
        tb["terminals"].append(addr)
        sp["tabs"].append(tb)
        st["view"] = [sp["id"], tb["id"]]
        save(st)
        out({"space": sp["id"], "tab": tb["id"], "terminal": addr})
    if name == "space.select":
        st["view"] = [a.get("id"), None]
        save(st)
        out({"ok": True})
    if name == "tab.select":
        st["view"][1] = a.get("id")
        save(st)
        out({"ok": True})
    out({"ok": True})   # tab.rename, pane.focus, terminal.open…: solo quedan en el log


def hc(args):
    st = load()
    cmd = args[0] if args else ""
    rest = [x for x in args[1:] if x not in ("--json", "--")]
    if cmd == "ls":
        want = [rest[i + 1] for i, x in enumerate(rest) if x == "--label"]
        terms = []
        for addr, t in st["terms"].items():
            if all(t["labels"].get(w.split("=", 1)[0]) == w.split("=", 1)[1] for w in want):
                terms.append({"address": addr, "cwd": t["cwd"], "state": "live"})
        out({"terminals": terms})
    if cmd == "get":
        t = st["terms"].get(rest[0])
        if not t:
            sys.exit(1)
        # status: lo que informa un agente (un test lo pone en state.json: {"app": "claude-code", "state": "idle"});
        # una shell no tiene
        out({"address": rest[0], "cwd": t["cwd"], "labels": t["labels"], "argv": t["argv"], "state": "live",
             "status": t.get("status"), "foreground": {"cwd": t["cwd"]}})
    if cmd == "label":
        if os.path.exists(os.path.join(FAKE, "fail-label")) or rest[0] not in st["terms"]:
            sys.exit(1)
        for kv in rest[1:]:
            k, v = kv.split("=", 1)
            st["terms"][rest[0]]["labels"][k] = v
        save(st)
        log("hc label " + " ".join(rest))
        out({"address": rest[0]})
    if cmd == "read":
        try:
            with open(os.path.join(FAKE, "screen-" + rest[0])) as f:
                sys.stdout.write(f.read())
        except OSError:
            pass
        sys.exit(0)
    if cmd == "send":
        log("hc send " + " ".join(rest))
        out({"started": True})
    if cmd == "machine":   # hc machine ls: una máquina por línea en $HD_FAKE/machines ("pc" o "pc disconnected")
        ms = []
        try:
            with open(os.path.join(FAKE, "machines")) as f:
                for ln in f:
                    p = ln.split()
                    if p:
                        ms.append({"name": p[0], "state": p[1] if len(p) > 1 else "connected"})
        except OSError:
            pass
        out({"machines": ms})
    if cmd == "exec":   # hc exec --on <m> <programa> <sub> …: imprime $HD_FAKE/exec-<m>-<sub>; si no está, falla
        a, on = list(args[1:]), ""
        while a and a[0].startswith("--"):
            if a[0] == "--on":
                on = a[1]
            a = a[1:] if a[0] in ("--json", "--stdin") else a[2:]
        log("hc exec --on %s %s" % (on, " ".join(a)))
        try:
            with open(os.path.join(FAKE, "exec-%s-%s" % (on, a[1] if len(a) > 1 else ""))) as f:
                sys.stdout.write(f.read())
        except OSError:
            sys.exit(1)
        sys.exit(0)
    if cmd == "kill":
        if rest[0] not in st["terms"]:
            sys.exit(1)
        del st["terms"][rest[0]]
        for s in st["spaces"]:
            s["tabs"] = [t for t in s["tabs"] if rest[0] not in t["terminals"]]
        save(st)
        log("hc kill " + rest[0])
        out({"state": "finished"})
    sys.exit(2)


if __name__ == "__main__":
    (app if sys.argv[1] == "app" else hc)(sys.argv[2:])
