#!/usr/bin/env bash
# bk --dry-run chat / ws: dice qué abriría y no abre nada. El 2026-11-05, `bk --dry-run chat` abrió cuatro
# workspaces reales desde un test. Acá bk ve un tmux falso que solo anota lo que le piden y falla.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE BK_BACKEND BK_ACCOUNT BK_ACCOUNT_CLAUDE
export HOME="$TMP/home"; mkdir -p "$HOME"
mkdir -p "$TMP/fake"; printf '#!/bin/sh\necho "$*" >> "%s/tmux.log"\nexit 1\n' "$TMP" >"$TMP/fake/tmux"; chmod +x "$TMP/fake/tmux"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
REPO="$TMP/proj"; git init -q -b main "$REPO"; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
# run <args>: salida de bk (sin colores) desde el repo; cuenta lo que intentó crear en tmux
run() { : >"$TMP/tmux.log"; (cd "$REPO" && PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" --dry-run "$@" 2>&1) | sed 's/\x1b\[[0-9;]*m//g'; }
created() { grep -c -E '^(new-session|new-window|split-window|switch-client|attach)' "$TMP/tmux.log"; }

check_eq "$(run chat)" "(dry-run: abriría el workspace bk-proj-2 en $REPO)" "bk chat: dice qué workspace abriría"
check_eq "$(created)" "0" "bk chat: no abre nada en tmux"
check_eq "$(run chat --rama 'Prueba ñ')" "(dry-run: crearía la rama chat/prueba-n en $TMP/proj-wt/chat-prueba-n)
(dry-run: abriría el workspace bk-proj-prueba-n en $TMP/proj-wt/chat-prueba-n)" "bk chat --rama: dice qué rama y workspace"
check_eq "$(created)" "0" "bk chat --rama: no abre nada en tmux"
check_eq "$(ls "$TMP" | grep -c proj-wt)" "0" "bk chat --rama: no crea el worktree"
check_eq "$(git -C "$REPO" branch --list 'chat/*' | wc -l | tr -d ' ')" "0" "bk chat --rama: no crea la rama"
check_eq "$(run chat --suelto)" "(dry-run: abriría un chat sin proyecto en $HOME/.bk/chats)" "bk chat --suelto: dice dónde"
check_eq "$(created)" "0" "bk chat --suelto: no abre nada en tmux"
check_eq "$([ -d "$HOME/.bk/chats" ] && echo sí || echo no)" "no" "bk chat --suelto: no crea la carpeta"
check_eq "$(run ws "$REPO")" "(dry-run: abriría el workspace bk-proj en $REPO)" "bk ws: dice qué workspace"
check_eq "$(created)" "0" "bk ws: no abre nada en tmux"

echo "1..$N"
[ "$FAILED" -eq 0 ]
