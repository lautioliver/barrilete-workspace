#!/usr/bin/env bash
# Perfiles de Codex de bk (codex/, lib/codex_profiles.py): bk codex install/status y el -p que agent_cmd suma por rol.
# CODEX_HOME y HOME temporales: nada toca tu ~/.codex.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" CODEX_HOME="$TMP/codex"; mkdir -p "$HOME"
unset BK_BACKEND BK_PROJECT
# codex falso: agent_cmd solo pide que exista
mkdir -p "$TMP/fake"; printf '#!/bin/sh\nexit 0\n' >"$TMP/fake/codex"; chmod +x "$TMP/fake/codex"; export PATH="$TMP/fake:$PATH"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
B="$ROOT/bin/bk"
cmd() { "$B" _agent_cmd "$@"; }

check_eq "$("$B" codex | grep -c ': falta$')" "3" "sin instalar: los tres faltan"
check_eq "$(cmd implementer codex gpt-6.2-sol 'x')" "codex -m gpt-6.2-sol 'x'" "sin el perfil instalado, codex sin -p"
check_eq "$("$B" --dry-run codex install 2>&1 | sed "s/\x1b\[[0-9;]*m//g"; ls "$CODEX_HOME" 2>/dev/null | wc -l | tr -d ' ')" "(dry-run: copiaría $ROOT/codex/bk-*.config.toml a $CODEX_HOME)
0" "install --dry-run no copia nada"
check_eq "$("$B" codex install | grep -c ': instalado$')" "3" "install copia los tres"
for f in "$ROOT"/codex/bk-*.config.toml; do
  check_eq "$(cmp -s "$f" "$CODEX_HOME/${f##*/}" && echo igual)" "igual" "install: ${f##*/} igual al del repo"
done
check_eq "$("$B" codex install | grep -c ': ya estaba$')" "3" "install de nuevo no cambia nada"
echo '# a mano' >>"$CODEX_HOME/bk-liviano.config.toml"
check_eq "$("$B" codex | grep bk-liviano)" "bk-liviano.config.toml: desactualizado" "status ve un archivo cambiado"
check_eq "$("$B" codex install | grep bk-liviano)" "bk-liviano.config.toml: actualizado" "install lo vuelve al del repo"

check_eq "$(cmd implementer codex gpt-6.2-sol 'issue #3 ñ')" "codex -p bk-implementador -m gpt-6.2-sol 'issue #3 ñ'" "implementer: bk-implementador, con acentos"
check_eq "$(cmd orchestrator codex gpt-6.2-sol x) | $(cmd planner codex m x)" "codex -p bk-orquestador -m gpt-6.2-sol 'x' | codex -p bk-orquestador -m m 'x'" "orchestrator y planner: bk-orquestador"
check_eq "$(cmd reviewer codex m x) | $(cmd implementer-light codex m x)" "codex -p bk-liviano -m m 'x' | codex -p bk-liviano -m m 'x'" "reviewer e implementer-light: bk-liviano"
check_eq "$(cmd otro codex m x)" "codex -m m 'x'" "un rol sin perfil: sin -p"
check_eq "$(cmd implementer claude sonnet x)" "claude --model sonnet 'x'" "claude no cambia"

# Cada perfil es TOML válido y solo con lo que se espera (Codex valida aparte con --strict-config)
check_eq "$(python3 -c '
import sys, tomllib
for p in sys.argv[1:]:
    d = tomllib.load(open(p, "rb"))
    assert d["model_verbosity"] == "low" and d["model_reasoning_summary"] == "none", p
    assert d["features"] == {"plugins": False, "apps": False, "browser_use": False, "computer_use": False, "image_generation": False}, p
    assert "mcp_servers" not in d, p
print("ok")' "$ROOT"/codex/bk-*.config.toml)" "ok" "los perfiles: verbosidad baja, sin resumen, sin herramientas que no se usan"

# Las cuentas de bk account los comparten por symlink
check_eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import accounts, codex_profiles; print(all(f in accounts.SHARED["codex"] for f in codex_profiles.FILES))' "$ROOT/lib")" "True" "accounts.SHARED comparte los tres"

# De punta a punta: bk --dry-run orchestrate en un proyecto que pone el orquestador en codex
REPO="$TMP/proj"; git init -q -b main "$REPO"; mkdir -p "$REPO/.barrilete"; echo "{}" >"$REPO/.agent-kit.json"; mkdir -p "$REPO/scripts/agents"; : >"$REPO/scripts/agents/guardrails.py"
echo "orchestrator: codex/gpt-6.2-sol main" >"$REPO/.barrilete/roles.yml"
check_eq "$(cd "$REPO" && "$B" --dry-run orchestrate 2>&1 | sed -n 's/^  cmd: //p')" "codex -p bk-orquestador -m gpt-6.2-sol '/orchestrate'" "launch (orchestrate --dry-run) le pasa el rol a agent_cmd"

echo "1..$N"
[ "$FAILED" -eq 0 ]
