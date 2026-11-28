#!/usr/bin/env bash
# El proveedor del chat en tmux: BK_CHAT_PROVIDER fija el comando que abre (#48) y `bk chat --suelto` abre el
# proveedor elegido con su cuenta, no claude fijo (#47). Con un tmux falso que solo anota lo que le piden: no abre
# nada en tu tmux. Las cuentas viven en una carpeta temporal (XDG_STATE_HOME).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
# shellcheck disable=SC1091  # tap.sh se carga en tiempo de ejecución
. "$ROOT/scripts/agents/tap.sh"
tap_begin "tests/test_chat_provider.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
# shellcheck disable=SC2016  # se expande al salir, no ahora
tap_at_exit 'rm -rf "$TMP"'
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_BACKEND BK_ACCOUNT BK_ACCOUNT_CLAUDE BK_ACCOUNT_CODEX CLAUDE_CONFIG_DIR CODEX_HOME \
      BK_PROJECT BK_WS_NAME BK_SESSION BK_CHAT_PROVIDER WS_CHAT_CMD WS_CHAT_PROVIDER WS_SESSION BK_ACCOUNTS_DIR BK_TASK_DIR
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" XDG_CACHE_HOME="$TMP/cache" XDG_CONFIG_HOME="$TMP/config" \
       BK_BACKEND=tmux BK_FORCE=1 BK_BOT=0 PYTHONPYCACHEPREFIX="$TMP/pycache"
mkdir -p "$HOME" "$TMP/fake"
LOG="$TMP/tmux.log"
# tmux falso: anota cada llamada (argumentos separados por tab), no hay sesiones y lo que crea es el pane %1
cat >"$TMP/fake/tmux" <<EOF
#!/bin/sh
printf '%s\t' "\$@" >>"$LOG"; printf '\n' >>"$LOG"
case "\$1" in
  has-session) exit 1 ;;
  new-session|new-window|split-window) echo %1 ;;
esac
exit 0
EOF
for b in claude codex agy cursor-agent open gh; do printf '#!/bin/sh\nexit 0\n' >"$TMP/fake/$b"; done
chmod +x "$TMP/fake"/*
export PATH="$TMP/fake:$PATH"
out=""                                  # lo asigna tap_run

ACC="$XDG_STATE_HOME/bk/accounts"
tap_run out 0 python3 "$ROOT/lib/accounts.py" new codex cdx
tap_run out 0 python3 "$ROOT/lib/accounts.py" new claude trabajo
REPO="$TMP/proj"
tap_run out 0 git init -q -b main "$REPO"
tap_run out 0 git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cd "$REPO"

# open_bk <proveedor> <args de bk…>: corre bk con ese proveedor (sin terminal: stdin de /dev/null, así no pregunta)
# y deja en $cmd el comando del primer new-session/new-window, y en $envs los -e que le pasó.
open_bk() {
  local p="$1"; shift
  : >"$LOG"
  export BK_CHAT_PROVIDER="$p"           # vacío es lo mismo que sin definir: el de siempre
  tap_run out 0 "$ROOT/bin/bk" "$@" </dev/null
  cmd=$(awk -F'\t' '$1 == "new-session" || $1 == "new-window" { print $(NF-1); exit }' <"$LOG")
  envs=$(awk -F'\t' '$1 == "new-session" || $1 == "new-window" { for (i = 1; i < NF; i++) if ($i == "-e") print $(i+1); exit }' <"$LOG")
}
# open_chat <proveedor> <args de bk chat…>: lo mismo con bk chat
open_chat() { local p="$1"; shift; open_bk "$p" chat "$@"; }
cmd=""; envs=""

# --- #48: BK_CHAT_PROVIDER cambia el comando del chat del proyecto ---
while IFS='|' read -r prov want; do
  open_chat "$prov"
  [ "$cmd" = "$want; exec \$SHELL" ]; tap_check $? "bk chat con BK_CHAT_PROVIDER abre ese proveedor" "$prov → $cmd"
done <<'EOF'
codex|codex
cursor|cursor-agent
agy|agy
cc|claude
claude|claude
EOF

# --- #47: bk chat --suelto abre el proveedor elegido ---
while IFS='|' read -r prov want; do
  open_chat "$prov" --suelto
  [ "$cmd" = "$want" ]; tap_check $? "bk chat --suelto abre el proveedor elegido" "$prov → $cmd"
done <<'EOF'
codex|codex
cursor|cursor-agent
agy|agy
cc|claude
EOF

# --- #47: con la cuenta del proveedor elegido, no la de claude ---
export BK_ACCOUNT_CODEX=cdx BK_ACCOUNT_CLAUDE=trabajo
open_chat codex --suelto
printf '%s\n' "$envs" | grep -qx "CODEX_HOME=$ACC/cdx"
tap_check $? "bk chat --suelto con codex pasa la cuenta de codex" "$(printf '%s' "$envs" | tr '\n' ' ')"
[[ "$envs" != *CLAUDE_CONFIG_DIR=* ]]
tap_check $? "bk chat --suelto con codex no pasa la cuenta de claude" "$(printf '%s' "$envs" | tr '\n' ' ')"
open_chat "" --suelto
[ "$cmd" = claude ]; tap_check $? "bk chat --suelto sin proveedor sigue abriendo claude" "$cmd"
printf '%s\n' "$envs" | grep -qx "CLAUDE_CONFIG_DIR=$ACC/trabajo"
tap_check $? "bk chat --suelto sin proveedor pasa la cuenta de claude" "$(printf '%s' "$envs" | tr '\n' ' ')"
unset BK_ACCOUNT_CODEX BK_ACCOUNT_CLAUDE

# --- un nombre que no está en la lista no abre claude en su lugar: falla y lo dice ---
: >"$LOG"
export BK_CHAT_PROVIDER=gpt
tap_run out 1 "$ROOT/bin/bk" chat --suelto </dev/null
[[ "$out" == *"BK_CHAT_PROVIDER=gpt no es un proveedor del chat"* ]]
tap_check $? "BK_CHAT_PROVIDER desconocido falla y lo dice" "$out"
n=$(awk -F'\t' '$1 == "new-session" || $1 == "new-window" { c++ } END { print c + 0 }' <"$LOG")
[ "$n" = 0 ]
tap_check $? "BK_CHAT_PROVIDER desconocido no abre ningún chat" "abrió $n"

# --- quien le pasa a bk chat su comando (retomar una sesión: WS_CHAT_CMD) no lo pierde por BK_CHAT_PROVIDER ---
export WS_CHAT_CMD="claude --resume abc"
open_chat codex --suelto
[ "$cmd" = "claude --resume abc" ]; tap_check $? "BK_CHAT_PROVIDER no pisa el WS_CHAT_CMD de quien llama" "$cmd"
unset WS_CHAT_CMD

# --- bk (el chat del workspace del proyecto) abre el proveedor de BK_CHAT_PROVIDER, con su cuenta ---
export BK_ACCOUNT_CODEX=cdx
open_bk codex ws "$REPO"
[ "$cmd" = "codex; exec \$SHELL" ]; tap_check $? "bk con BK_CHAT_PROVIDER abre ese proveedor en el workspace" "$cmd"
printf '%s\n' "$envs" | grep -qx "CODEX_HOME=$ACC/cdx"
tap_check $? "bk con BK_CHAT_PROVIDER pasa la cuenta de ese proveedor" "$(printf '%s' "$envs" | tr '\n' ' ')"
unset BK_ACCOUNT_CODEX

tap_done
