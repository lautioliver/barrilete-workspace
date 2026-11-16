#!/usr/bin/env python3
"""La imagen de una carpeta o de un espacio de la barra de Herdr (herdr/mods/agentes).

  espacios.py logo <archivo | file://…>

Herdr solo muestra imágenes de su carpeta (~/.config/herdr-app, o HERDR_APP_HOME): copia el archivo a
mods/bk-agentes/logos/<sha256 corto>.<ext> e imprime esa ruta relativa, la que entiende image(). La misma imagen
dos veces da la misma ruta y una sola copia. Acepta png, jpg, webp y svg de hasta 1 MB; lo demás lo rechaza con una
línea en stderr (la barra la muestra) y sale con 1.
"""
import hashlib, os, sys
from urllib.parse import unquote, urlparse

MAX = 1024 * 1024
EXT = {"png": "png", "jpg": "jpg", "jpeg": "jpg", "webp": "webp", "svg": "svg"}
DIR = os.path.join("mods", "bk-agentes", "logos")


def looks_like(ext, data):
    """El contenido es de ese tipo (no solo el nombre)."""
    if ext == "png":
        return data.startswith(b"\x89PNG\r\n\x1a\n")
    if ext == "jpg":
        return data.startswith(b"\xff\xd8")
    if ext == "webp":
        return data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    return b"<svg" in data[:4096].lower()


def logo(src):
    if src.startswith("file://"):
        src = unquote(urlparse(src).path)
    src = os.path.expanduser(src.strip())
    name = os.path.basename(src)
    if not os.path.isfile(src):
        raise ValueError(f"no encuentro {name}")
    ext = EXT.get(name.rsplit(".", 1)[-1].lower() if "." in name else "")
    if not ext:
        raise ValueError(f"no es una imagen (png, jpg, webp o svg): {name}")
    if os.path.getsize(src) > MAX:
        raise ValueError(f"la imagen pesa más de 1 MB: {name}")
    with open(src, "rb") as f:
        data = f.read()
    if not looks_like(ext, data):
        raise ValueError(f"no es una imagen (png, jpg, webp o svg): {name}")
    home = os.environ.get("HERDR_APP_HOME") or os.path.expanduser("~/.config/herdr-app")
    rel = os.path.join(DIR, f"{hashlib.sha256(data).hexdigest()[:16]}.{ext}")
    dst = os.path.join(home, rel)
    if not os.path.isfile(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst + ".tmp", "wb") as f:
            f.write(data)
        os.replace(dst + ".tmp", dst)
    return rel


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "logo":
        print("uso: espacios.py logo <archivo>", file=sys.stderr); return 2
    try:
        print(logo(sys.argv[2]))
    except (ValueError, OSError) as e:
        print(e if isinstance(e, ValueError) else f"no pude copiar la imagen: {e.strerror or e}", file=sys.stderr); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
