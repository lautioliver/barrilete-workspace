#!/usr/bin/env python3
"""Perfiles de Codex de bk (codex/bk-*.config.toml): qué perfil usa cada rol y su instalación en $CODEX_HOME.

  codex_profiles.py for-role <rol> [codex_home]   el perfil del rol si está instalado (nada si no)
  codex_profiles.py install <codex/ del repo> <codex_home>   copia los que faltan o cambiaron; dice qué hizo
  codex_profiles.py status <codex/ del repo> <codex_home>    instalado, desactualizado o falta, uno por renglón

Codex lee `-p <nombre>` como $CODEX_HOME/<nombre>.config.toml sobre config.toml. Las cuentas de bk account
comparten estos archivos con la principal por symlink (lib/accounts.py, SHARED).
"""
import filecmp, os, shutil, sys

ROLES = {"planner": "bk-orquestador", "orchestrator": "bk-orquestador", "implementer": "bk-implementador",
         "implementer-light": "bk-liviano", "reviewer": "bk-liviano"}
NAMES = sorted(set(ROLES.values()))
FILES = [f"{n}.config.toml" for n in NAMES]


def home(arg=None):
    return arg or os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def for_role(role, codex_home=None):
    name = ROLES.get(role)
    if name and os.path.isfile(os.path.join(home(codex_home), f"{name}.config.toml")):
        return name
    return ""


def state(src, dst):
    if not os.path.isfile(dst):
        return "falta"
    return "instalado" if filecmp.cmp(src, dst, shallow=False) else "desactualizado"


def install(src_dir, codex_home):
    os.makedirs(codex_home, exist_ok=True)
    for fn in FILES:
        src, dst = os.path.join(src_dir, fn), os.path.join(codex_home, fn)
        st = state(src, dst)
        if st == "instalado":
            print(f"{fn}: ya estaba")
            continue
        shutil.copyfile(src, dst + ".tmp")
        os.replace(dst + ".tmp", dst)
        print(f"{fn}: {'actualizado' if st == 'desactualizado' else 'instalado'}")


def main(argv):
    if len(argv) >= 2 and argv[0] == "for-role":
        print(for_role(argv[1], argv[2] if len(argv) > 2 else None))
    elif len(argv) == 3 and argv[0] == "install":
        install(argv[1], argv[2])
    elif len(argv) == 3 and argv[0] == "status":
        for fn in FILES:
            print(f"{fn}: {state(os.path.join(argv[1], fn), os.path.join(argv[2], fn))}")
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
