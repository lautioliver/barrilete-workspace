#!/usr/bin/env python3
"""Instala en Herdr lo de bk (herdr/ del repo): el mod `bk` de las acciones sin panel, los paneles nativos del hub
(una carpeta por vista), las teclas alt+…, los paneles del layout (cada carpeta de herdr/mods), los temas y el
layout `bk-lavanda` que los muestra, con su vista previa.

  herdr_install.py <herdr/ del repo> <carpeta de Herdr (~/.config/herdr-app)>

El mod se copia a mods/bk-<comando>, una carpeta por tecla. Las teclas se suman a keys.json sin pisar nada: una tecla que ya hace otra cosa
queda como está y se avisa. Antes del primer cambio guarda keys.json.antes-de-bk (una sola vez). Herdr deja de
actualizar un keys.json editado: sus atajos nuevos habrá que sumarlos a mano. Imprime qué hizo; correrlo de
nuevo no cambia nada.

Teclas propias: ~/.config/bk/keys.json (o BK_KEYS), con la forma de herdr/keys.json, manda sobre las del repo.
Una acción pone esa tecla; null la saca: no se instala y, si bk ya la había puesto, se va. Sirve para un teclado
donde alt+… escribe algo (en el español, alt+1, alt+2 y alt+3 son |, @ y #).
"""
import filecmp, hashlib, json, os, shutil, sys


NO_KEY = ("bk-aviso", "bk-seguir")   # mods sin tecla: los abre bk (un aviso de Herdr) o el clic en ese aviso
HUB = "hub"   # herdr/mods/hub: los paneles nativos (paleta, issues, PRs…), un mismo paquete instalado una vez por vista


# Teclas que una versión anterior de bk instaló con otra acción: si siguen igual a esa, se actualizan (no son
# una elección tuya). alt+1…9 iba al espacio por posición y ahora va a la ventana con ese número fijo.
MOVED = {**{f"alt-{n}": f"space.select:{n}" for n in range(1, 10)}, "alt-,": "app.settings"}

# Los paneles de bk: cada carpeta de herdr/mods (menos el mod de las teclas y el paquete del hub) →
# mods/bk-<nombre>. El layout bk-lavanda dice dónde va cada uno.
LAYOUT = "bk-lavanda"


def mod_first(names):
    """mod.json antes que el resto: si Herdr ve primero un main.js en una carpeta nueva, acopla una copia del mod
    en el layout que se muestra (el mod.json es el que dice "place": "none")."""
    return sorted(names, key=lambda fn: (fn != "mod.json", fn))


def panel_names(src):
    root = os.path.join(src, "mods")
    return sorted(n for n in os.listdir(root) if n not in (HUB, "bk") and os.path.isfile(os.path.join(root, n, "main.js")))


def panels(src, home):
    copied, names = 0, panel_names(src)
    for name in names:
        a, b = os.path.join(src, "mods", name), os.path.join(home, "mods", "bk-" + name)
        os.makedirs(b, exist_ok=True)
        for fn in mod_first(f for f in os.listdir(a) if os.path.isfile(os.path.join(a, f)) and not f.startswith(".")):
            if not (os.path.isfile(os.path.join(b, fn)) and filecmp.cmp(os.path.join(a, fn), os.path.join(b, fn), shallow=False)):
                shutil.copyfile(os.path.join(a, fn), os.path.join(b, fn)); copied += 1
    print(f"paneles bk: {'actualizados' if copied else 'al día'} ({', '.join('bk-' + n for n in names)})")


# Temas que bk instaló con otro nombre: si la copia sigue igual a lo que bk instaló, se va (el nuevo la reemplaza)
RENAMED_THEMES = {"bk-noche.json": "bk-neon.json"}


def themes(src, home):
    """Los temas de bk (herdr/themes/*.json) → themes/ de Herdr, para elegirlos en alt+, o en los ajustes. Siguen
    al repo mientras no los retoques: bk anota el sha256 de lo que instaló (bk-temas.json) y solo pisa una copia
    que sigue igual a esa; un tema tuyo con el mismo nombre queda como está. Uno que cambió de nombre
    (RENAMED_THEMES) se borra con la misma regla: solo si sigue igual a lo que bk instaló."""
    a = os.path.join(src, "themes")
    if not os.path.isdir(a):
        return
    mark = os.path.join(home, "bk-temas.json")
    try:
        was = json.load(open(mark))
    except (OSError, ValueError):
        was = {}
    now, done, kept = dict(was), 0, []
    os.makedirs(os.path.join(home, "themes"), exist_ok=True)
    for fn in sorted(f for f in os.listdir(a) if f.endswith(".json")):
        want, have = os.path.join(a, fn), os.path.join(home, "themes", fn)
        new = digest(want)
        if os.path.exists(have) and digest(have) != new and digest(have) != was.get(fn):
            kept.append(fn); continue
        if not os.path.exists(have) or digest(have) != new:
            shutil.copyfile(want, have + ".tmp"); os.replace(have + ".tmp", have); done += 1
        now[fn] = new
    gone = []
    for old in RENAMED_THEMES:
        have = os.path.join(home, "themes", old)
        if old in now and os.path.exists(have) and digest(have) == now[old]:
            os.remove(have); gone.append(old)
        if old in now and not os.path.exists(have):
            del now[old]
    if now != was:
        put(mark, json.dumps(now, indent=1, sort_keys=True) + "\n")
    print(f"temas bk: {'actualizados' if done or gone else 'al día'}" + (f" (no piso los tuyos: {', '.join(kept)})" if kept else "")
          + (f" (se fue {', '.join(g[:-5] + ' → ' + RENAMED_THEMES[g][:-5] for g in gone)})" if gone else ""))


def put(path, text):
    """Escribe el archivo solo si cambia (guardar de más hace recargar el mod en Herdr). 1 si escribió."""
    try:
        if open(path).read() == text:
            return 0
    except OSError:
        pass
    with open(path + ".tmp", "w") as f:
        f.write(text)
    os.replace(path + ".tmp", path)
    return 1


def hub_views(src):
    """Las vistas del paquete hub: {nombre: {title, overlay}} (herdr/mods/hub/views.json)."""
    try:
        return json.load(open(os.path.join(src, "mods", HUB, "views.json")))
    except (OSError, ValueError):
        return {}


def hub(src, home):
    """Cada vista del hub en su carpeta mods/bk-<vista>: los mismos archivos, un view.js que dice cuál es y el
    mod.json con el tamaño de su ventana. Una tecla abre un mod por su nombre y no le puede pasar argumentos."""
    views, a, copied = hub_views(src), os.path.join(src, "mods", HUB), 0
    files = sorted(f for f in os.listdir(a) if f.endswith((".js", ".svg")) and f != "view.js") if views else []
    for name, spec in sorted(views.items()):
        dst = os.path.join(home, "mods", "bk-" + name)
        os.makedirs(dst, exist_ok=True)
        mod = {"place": "none", "title": spec.get("title", "bk")}
        if spec.get("overlay"):
            mod["overlay"] = spec["overlay"]
        copied += put(os.path.join(dst, "mod.json"), json.dumps(mod, ensure_ascii=False) + "\n")   # primero: ver mod_first
        copied += put(os.path.join(dst, "view.js"), f"export const VIEW = {json.dumps(name)};\n")
        for fn in files:
            if not (os.path.isfile(os.path.join(dst, fn)) and filecmp.cmp(os.path.join(a, fn), os.path.join(dst, fn), shallow=False)):
                shutil.copyfile(os.path.join(a, fn), os.path.join(dst, fn)); copied += 1
    print(f"paneles del hub: {'actualizados' if copied else 'al día'} ({len(views)} vistas)")
    return set("bk-" + n for n in views)


def digest(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def preview(src, home):
    """La vista previa del layout (herdr/layouts/bk-lavanda.svg, la que el .json nombra en "preview") → layouts/ de
    Herdr. Es un dibujo, no algo que se retoque: se copia si falta o si difiere de la del repo. 1 si copió.
    Si no se puede (hay una carpeta con ese nombre, no hay permiso) avisa y sigue: el resto se instala igual."""
    want, have = os.path.join(src, "layouts", LAYOUT + ".svg"), os.path.join(home, "layouts", LAYOUT + ".svg")
    if not os.path.isfile(want) or (os.path.isfile(have) and filecmp.cmp(want, have, shallow=False)):
        return 0
    try:
        os.makedirs(os.path.dirname(have), exist_ok=True)
        shutil.copyfile(want, have + ".tmp"); os.replace(have + ".tmp", have)
    except OSError as e:
        print(f"layout {LAYOUT}: no pude copiar la vista previa a {have} ({e.strerror or e})")
        try:
            os.remove(have + ".tmp")
        except OSError:
            pass   # no llegó a escribirse
        return 0
    return 1


def layout(src, home):
    """El layout de bk, uno solo: herdr/layouts/bk-lavanda.json del repo → layouts/ de Herdr. Sigue al repo mientras
    no lo retoques: bk anota qué instaló (bk-lavanda.instalado, su sha256) y solo pisa una copia que sigue igual a
    esa. Una copia retocada (o una que bk no instaló) queda como está y se avisa. No cambia el layout que se
    muestra: eso es `herdr-app do layout.switch --name bk-lavanda`. Su vista previa (preview) va primero, así el
    .json nunca nombra un dibujo que todavía no está."""
    want, have = os.path.join(src, "layouts", LAYOUT + ".json"), os.path.join(home, "layouts", LAYOUT + ".json")
    mark = os.path.join(home, LAYOUT + ".instalado")
    drawn = preview(src, home)
    new = digest(want)
    try:
        was = open(mark).read().strip()
    except OSError:
        was = ""
    if not os.path.exists(have):
        what = f"instalado (herdr-app do layout.switch --name {LAYOUT})"
    elif digest(have) == new:
        what = "al día"
    elif was and digest(have) == was:
        what = "actualizado"
    else:
        print(f"layout {LAYOUT}: lo retocaste, no lo piso (para tomar el del repo, borrá {have} y repetí)"); return
    if what != "al día":
        os.makedirs(os.path.dirname(have), exist_ok=True)
        tmp = have + ".tmp"
        shutil.copyfile(want, tmp); os.replace(tmp, have)
    if was != new:
        with open(mark, "w") as f:
            f.write(new + "\n")
    print(f"layout {LAYOUT}: {what}" + (" (vista previa actualizada)" if drawn and what == "al día" else ""))


def own_keys():
    """Las teclas propias: ({sección: {tecla: acción | None}}, ruta). Sin archivo, {}; si no se puede leer o no
    tiene esa forma, None: las teclas no se tocan (instalar las del repo pisaría lo que el archivo quería evitar)."""
    path = os.environ.get("BK_KEYS") or os.path.expanduser("~/.config/bk/keys.json")
    try:
        mine = json.load(open(path))
    except FileNotFoundError:
        return {}, path
    except (OSError, ValueError):
        return None, path
    ok = isinstance(mine, dict) and all(isinstance(b, dict) and all(a is None or isinstance(a, str) for a in b.values())
                                        for b in mine.values())
    return (mine if ok else None), path


def is_ours(action, key):
    """Una tecla que puso bk (esta versión o una anterior), no una elección tuya."""
    return isinstance(action, str) and (action.startswith("bk.") or action.startswith("mod.open:bk-") or action == MOVED.get(key))


def main():
    src, home = sys.argv[1], sys.argv[2]
    if not os.path.isdir(home):
        print(f"no existe {home}: abrí Herdr una vez y repetí"); return 1
    want = json.load(open(os.path.join(src, "keys.json")))
    # Una carpeta por comando (mods/bk-<comando>), todas con el mismo mod: una tecla abre un mod por su nombre
    # y no puede pasarle argumentos. mods/bk era la versión con una copia siempre abierta: se va.
    # Los mods salen de las teclas del repo y de las propias: el de una tecla sacada se instala igual (la paleta lo abre)
    mine, mine_path = own_keys()
    views = hub(src, home)
    names = sorted(({a.split(":", 1)[1] for b in list(want.values()) + list((mine or {}).values()) for a in b.values()
                     if isinstance(a, str) and a.startswith("mod.open:bk-")} | set(NO_KEY)) - views)
    mod, copied = os.path.join(src, "mods", "bk"), 0
    for name in names:
        dst = os.path.join(home, "mods", name)
        os.makedirs(dst, exist_ok=True)
        for fn in ("mod.json", "main.js"):   # mod.json primero: ver mod_first
            a, b = os.path.join(mod, fn), os.path.join(dst, fn)
            if not (os.path.isfile(b) and filecmp.cmp(a, b, shallow=False)):
                shutil.copyfile(a, b); copied += 1
    shutil.rmtree(os.path.join(home, "mods", "bk"), ignore_errors=True)
    print(f"mods bk-*: {'actualizados' if copied else 'al día'} ({len(names)} en {os.path.join(home, 'mods')})")

    panels(src, home)
    themes(src, home)
    layout(src, home)

    path = os.path.join(home, "keys.json")
    try:
        keys = json.load(open(path))
    except FileNotFoundError:
        print("teclas: no hay keys.json (abrí Herdr una vez y repetí)"); return 1
    except ValueError as e:
        print(f"teclas: keys.json no es JSON válido, no lo toco ({e})"); return 1
    if mine is None:
        print(f"teclas: {mine_path} no es JSON válido con la forma de herdr/keys.json, no toco las teclas"); return 1
    added, taken, gone = [], [], []
    for section, binds in mine.items():
        for key, action in binds.items():
            if action is not None:
                want.setdefault(section, {})[key] = action
                continue
            want.get(section, {}).pop(key, None)
            if is_ours(keys.get(section, {}).get(key), key):   # la había puesto bk: se va; una tuya queda
                del keys[section][key]; gone.append(key)
    for section, binds in want.items():
        have = keys.setdefault(section, {})
        for key, action in binds.items():
            ours = is_ours(have.get(key), key)
            if key not in have or (ours and have[key] != action):   # las de una versión anterior de bk se actualizan
                have[key] = action; added.append(key)
            elif have[key] != action:
                taken.append(f"{key} (ya es {json.dumps(have[key], ensure_ascii=False)})")
    stale = [(b, k) for b in keys.values() for k, a in b.items() if a == "bk.last"]   # alt+0 de la versión anterior
    for b, k in stale:
        del b[k]
    if added or stale or gone:
        backup = path + ".antes-de-bk"
        if not os.path.exists(backup):
            shutil.copyfile(path, backup)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(keys, f, indent=2, ensure_ascii=False); f.write("\n")
        os.replace(tmp, path)
    print(f"teclas: {len(added)} nuevas o actualizadas" + (f", {len(gone)} sacadas" if gone else "")
          + (f", {len(taken)} ocupadas: " + ", ".join(taken) if taken else ""))
    if mine:
        print(f"teclas propias: {sum(len(b) for b in mine.values())} ({mine_path})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
