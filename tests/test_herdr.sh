#!/usr/bin/env bash
# bk sobre Herdr (bk backend herdr, lib/herdr.sh): cada proyecto es un espacio y cada chat o agente una pestaña.
# bk ve un herdr-app y un hc falsos (tests/herdr_fake.py) que guardan espacios, pestañas y terminales en un
# archivo y anotan lo que les piden; también un tmux, un gh y un open falsos. Nada toca el Herdr
# real ni tu config: HOME es un directorio temporal.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_BACKEND BK_ACCOUNT BK_ACCOUNT_CLAUDE BK_TASK_DIR BK_PROJECT BK_WS_NAME \
      WORKTREE_LOCK_AGENT WORKTREE_LOCK_PID BK_HC BK_HERDR_APP HERDR_APP_HOME BK_HD_IDS_LOCK
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" BK_FORCE=1 BK_BOT=0 HD_FAKE="$TMP/hd" \
       BK_HANDOFF_DIR="$TMP/handoff" BK_HERDR_WAIT=1 BK_HERDR_OPEN="touch $TMP/opened"
mkdir -p "$HOME" "$TMP/fake" "$HD_FAKE"
for b in app hc; do
  n=$([ $b = app ] && echo herdr-app || echo hc)
  printf '#!/bin/sh\nexec python3 "%s/herdr_fake.py" %s "$@"\n' "$HERE" "$b" >"$TMP/fake/$n"
done
for b in tmux gh open; do printf '#!/bin/sh\necho "%s $*" >> "%s/otros.log"\nexit 1\n' "$b" "$TMP" >"$TMP/fake/$b"; done
chmod +x "$TMP/fake"/*; : >"$TMP/otros.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
has() { case "$1" in *"$2"*) echo si ;; *) echo no ;; esac; }

STATE="$HOME/.cache/sketchybar/agents"
plain() { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" "$@"; }                    # sin BK_BACKEND: decide la config
bk()    { PATH="$TMP/fake:$PATH" BK_BACKEND=herdr "$ROOT/bin/bk" "$@"; }
log()   { cat "$HD_FAKE/log" 2>/dev/null; }
st()    { jq "$@" "$HD_FAKE/state.json"; }
tasks() { python3 "$ROOT/lib/tasks.py" "$@"; }

# Un proyecto Barrilete mínimo, con origin y un prepare.sh falso (como tests/test_candado.sh)
REPO="$TMP/proj"
git init -q -b main "$REPO"; git init -q --bare "$TMP/origin.git"; git -C "$REPO" remote add origin "$TMP/origin.git"
mkdir -p "$REPO/scripts/agents" "$REPO/.claude/skills/implement-issue"; : >"$REPO/scripts/agents/guardrails.py"
# prepare.sh crea un worktree de verdad: bk saca el proyecto del repo principal del worktree (<repo>-wt/<n>)
cat >"$REPO/.claude/skills/implement-issue/prepare.sh" <<EOF
#!/bin/sh
[ -d "$TMP/proj-wt/\$1" ] || git -C "$REPO" worktree add -q -b "w\$1" "$TMP/proj-wt/\$1" >/dev/null 2>&1
echo "Worktree: $TMP/proj-wt/\$1"
EOF
chmod +x "$REPO/.claude/skills/implement-issue/prepare.sh"
git -C "$REPO" add -A; git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m init

# --- bk backend: tmux salvo que la config o BK_BACKEND digan herdr ---
check_eq "$(plain backend)" "tmux" "backend: sin config es tmux"
plain backend herdr >/dev/null
check_eq "$(cat "$HOME/.config/bk/backend")" "herdr" "backend herdr: queda en ~/.config/bk/backend"
check_eq "$(plain backend)" "herdr" "backend: lee la config"
check_eq "$(BK_BACKEND=tmux plain backend)" "tmux" "backend: BK_BACKEND manda sobre la config"
plain backend otro >/dev/null 2>&1; check_eq "$?" "1" "backend: un valor desconocido falla"
check_eq "$(cat "$HOME/.config/bk/backend")" "herdr" "backend: un valor desconocido no cambia la config"
plain backend tmux >/dev/null; check_eq "$(plain backend)" "tmux" "backend tmux: vuelve"

# --- bk (sin comando): el espacio del proyecto con su chat ---
(cd "$REPO" && bk >/dev/null 2>&1); check_eq "$?" "0" "bk: abre el workspace"
check_eq "$(log | grep -c '^app do space.new')" "1" "bk: crea el espacio"
check_eq "$(st -r '.spaces[0].name + " " + .spaces[0].tabs[0].name')" "proj chat" "bk: el espacio se llama como el proyecto y su pestaña, chat"
check_eq "$(st -c '.terms.t1.argv')" "[\"env\",\"BK_BACKEND=herdr\",\"BK_PROJECT=$REPO\",\"claude\"]" "bk: el chat es un claude con BK_PROJECT"
check_eq "$(st -r '.terms.t1.labels | .["bk.kind"] + " " + .["bk.win"] + " " + .["bk.project"]')" "chat proj proj" "bk: la terminal del chat queda etiquetada"
: >"$HD_FAKE/log"; (cd "$REPO" && bk >/dev/null 2>&1)
check_eq "$(log | grep -c -e 'space.new' -e 'tab.new')" "0" "bk otra vez: no crea otro espacio ni otro chat"
check_eq "$(log | grep -c 'tab.select {"id": "tb1"}')" "1" "bk otra vez: muestra el chat que ya estaba"

# --- bk run: el agente en una pestaña del espacio, con sus variables y etiquetas ---
: >"$HD_FAKE/log"; (cd "$REPO" && bk run 7 --role implementer >"$TMP/out" 2>&1); check_eq "$?" "0" "bk run: lanza"
WT="$TMP/proj-wt/7"; TD="$XDG_STATE_HOME/bk/tasks/proj/7-implementer"
check_eq "$(grep -c '^tmux' "$TMP/otros.log")" "0" "bk run: no llama a tmux"
check_eq "$(log | grep -c '^app do space.new')" "0" "bk run: no crea otro espacio"
check_eq "$(st -r '.spaces[0].tabs[1].name + " " + .terms.t2.cwd')" "i7 $WT" "bk run: pestaña i7 en el espacio del proyecto, en su worktree"
A=$(st -r '.terms.t2.argv | join("\n")')
check_eq "$(sed -n 1p <<<"$A")" "env" "bk run: las variables van con env"
for v in "BK_BACKEND=herdr" "BARRILETE_ROLE=implementer" "BARRILETE_MODEL=sonnet" "BARRILETE_ISSUE=#7" "BK_TASK_DIR=$TD"; do
  check_eq "$(grep -cxF "$v" <<<"$A")" "1" "bk run: el agente recibe $v"
done
check_eq "$(st -r '.terms.t2.argv[-3:] | .[0] + " " + .[1]')" "bash -c" "bk run: el comando corre en bash -c"
check_eq "$(st -r '.terms.t2.argv[-1]')" "claude --model sonnet '/implement-issue 7'; '$ROOT/bin/bk' _ended '$TD'" "bk run: claude con el prompt, y después cierra la tarea"
check_eq "$(st -c '.terms.t2.labels | [.["bk.kind"], .["bk.win"], .["bk.project"], .["bk.role"], .["bk.ref"]]')" '["agent","i7","proj","implementer","#7"]' "bk run: la terminal queda etiquetada"
check_eq "$(st -r '.terms.t1.labels["bk.id"] + " " + .terms.t2.labels["bk.id"]')" "1 2" "bk run: el agente toma su número de ventana al nacer, después del chat"
check_eq "$(jq -r '.pane + " " + .state' "$STATE/bk-i7.json")" "t2 waiting" "bk run: el pre-registro anota la terminal como pane"
check_eq "$(st -c '.view')" '["sp1","tb1"]' "bk run: no te saca de lo que estabas mirando"
check_eq "$(tasks state proj 7-implementer)" "in_progress" "bk run: la tarea queda en curso"
check_eq "$(jq -r .window "$TD/task.json")" "i7" "bk run: la tarea anota la ventana"

: >"$HD_FAKE/log"; (cd "$REPO" && bk run 7 --role implementer >/dev/null 2>&1)
check_eq "$(log | grep -c 'tab.new')" "0" "bk run otra vez: con la tarea activa no lanza otro agente"

# Si no se puede etiquetar la terminal, bk no la encontraría más: la cierra y no deja la tarea abierta
: >"$HD_FAKE/log"; : >"$HD_FAKE/fail-label"
out=$(cd "$REPO" && bk review 11 2>&1); rc=$?; rm -f "$HD_FAKE/fail-label"
check_eq "$rc" "1" "bk review sin poder etiquetar: falla"
check_eq "$(has "$out" "no pude lanzar pr11 en Herdr")" "si" "bk review sin poder etiquetar: lo dice"
check_eq "$(st -r '[.spaces[0].tabs[].name] | index("pr11") // "no"')" "no" "bk review sin poder etiquetar: no deja la pestaña"
check_eq "$(tasks state proj pr11-reviewer)" "cancelled" "bk review sin poder etiquetar: no deja la tarea en curso"

(cd "$REPO" && bk review 9 >/dev/null 2>&1); check_eq "$?" "0" "bk review: lanza"
R=$(st -r '.terms | to_entries[] | select(.value.labels["bk.win"] == "pr9") | .key')
check_eq "$(st -r --arg t "$R" '.terms[$t].labels | .["bk.role"] + " " + .["bk.ref"]')" "reviewer #9" "bk review: reviewer del PR"
out=$(cd "$REPO" && bk plan una idea 2>&1 && cd "$REPO" && bk plan otra idea 2>&1); rc=$?
check_eq "$rc" "1" "bk plan dos veces: la segunda falla"
check_eq "$(has "$out" "ya existe la ventana 'plan'")" "si" "bk plan dos veces: dice que la ventana ya existe"

# --- bk ls / go / peek ---
out=$(bk ls 2>&1)
check_eq "$(grep -c -e '^. i7 ' -e '^. pr9 ' <<<"$out")" "2" "bk ls: muestra los agentes de Herdr"
check_eq "$(grep -c '^chats' <<<"$out")" "1" "bk ls: muestra los chats"
: >"$HD_FAKE/log"; bk go i7 >/dev/null 2>&1
check_eq "$(log | grep -c -e 'space.select {"id": "sp1"}' -e 'tab.select {"id": "tb2"}')" "2" "bk go: muestra la pestaña del agente"
: >"$HD_FAKE/log"; bk go proj >/dev/null 2>&1
check_eq "$(log | grep -c 'tab.select {"id": "tb1"}')" "1" "bk go <chat>: muestra la pestaña del chat"
printf 'línea vieja\n⏺ Terminé el paso 2\n' >"$HD_FAKE/screen-t2"
check_eq "$(bk peek i7 2>&1 | tail -1)" "⏺ Terminé el paso 2" "bk peek: lee la pantalla de la terminal"

# --- bk say: escribe, respeta los menús y encola si el agente trabaja ---
: >"$HD_FAKE/log"; bk say i7 "hola agente" >/dev/null 2>&1
check_eq "$(log)" "hc send t2 hola agente" "bk say: le escribe a la terminal del agente"
printf '¿Aprobar?\n❯ 1. Sí\n  2. No\nEnter to select · Esc to cancel\n' >"$HD_FAKE/screen-t2"
: >"$HD_FAKE/log"; out=$(bk say i7 "mejor explicame" 2>&1); rc=$?
check_eq "$rc $(log | grep -c send)" "1 0" "bk say con un menú abierto: no manda texto"
check_eq "$(has "$out" "tiene un menú abierto")" "si" "bk say con un menú abierto: avisa"
: >"$HD_FAKE/log"; bk say i7 2 >/dev/null 2>&1
check_eq "$(log)" "hc send --force t2 2" "bk say con un menú abierto: un número pasa, forzado"
rm -f "$HD_FAKE/screen-t2"; mkdir -p "$STATE"
echo "{\"pane\": \"t2\", \"state\": \"working\", \"ts\": $(date +%s)}" >"$STATE/sesion-i7.json"
: >"$HD_FAKE/log"; out=$(bk say i7 "para después" 2>&1)
check_eq "$(log | grep -c send) $(has "$out" encolado)" "0 si" "bk say a un agente que trabaja: lo encola"
bk _drain "$TD" t2 >/dev/null 2>&1
check_eq "$(log)" "hc send t2 para después" "bk _drain: escribe lo encolado en su terminal"

# --- bk stop ---
echo "{\"pane\": \"$R\", \"state\": \"idle\", \"ts\": 1}" >"$STATE/sesion-pr9.json"
: >"$HD_FAKE/log"; bk stop i7 >/dev/null 2>&1; check_eq "$?" "0" "bk stop: cierra"
check_eq "$(log)" "hc kill t2" "bk stop: cierra la terminal del agente"
check_eq "$(tasks state proj 7-implementer)" "cancelled" "bk stop: cancela su tarea"
check_eq "$(ls "$STATE" | tr '\n' ' ')" "bk-plan.json bk-pr9.json sesion-pr9.json " "bk stop: borra el estado de ese agente y no el de otros"

# --- bk chat ---
: >"$HD_FAKE/log"; (cd "$REPO" && bk chat >/dev/null 2>&1)
check_eq "$(log | grep -c '^app do tab.new')" "1" "bk chat: otra pestaña del mismo espacio"
C=$(st -r '.terms | to_entries[] | select(.value.labels["bk.win"] == "proj-2") | .key')
check_eq "$(st -r --arg t "$C" '[.spaces[0].tabs[] | select(.terminals[0] == $t) | .name][0]')" "chat-2" "bk chat: se llama chat-2 y su chat, proj-2"
(cd "$REPO" && bk chat --nombre Idea >/dev/null 2>&1)
check_eq "$(st -r '.terms | to_entries[] | select(.value.labels["bk.win"] == "proj-3") | .value.labels["bk.name"]')" "Idea" "bk chat --nombre: el chat lleva ese nombre"
check_eq "$(st -r '[.spaces[0].tabs[].name] | index("Idea") != null')" "true" "bk chat --nombre: la pestaña también"
(cd "$REPO" && bk chat --suelto >/dev/null 2>&1)
check_eq "$(st -r '.spaces[1].name + " " + .spaces[1].folder')" "chats $HOME/.bk/chats" "bk chat --suelto: en el espacio chats, en su carpeta"
cp "$HD_FAKE/state.json" "$TMP/antes.json"; : >"$HD_FAKE/log"
out=$(cd "$REPO" && bk --dry-run chat --rama "Un cambio" 2>&1)
check_eq "$(log | wc -l | tr -d ' ') $(cmp -s "$HD_FAKE/state.json" "$TMP/antes.json" && echo igual)" "0 igual" "bk --dry-run chat --rama: no toca Herdr"
check_eq "$([ -d "$TMP/proj-wt/chat-un-cambio" ] && echo hay || echo no)" "no" "bk --dry-run chat --rama: no crea el worktree"
(cd "$REPO" && bk chat --rama "Un cambio" >/dev/null 2>&1)
check_eq "$(st -r '.spaces[2].name + " " + .spaces[2].folder')" "proj-un-cambio $TMP/proj-wt/chat-un-cambio" "bk chat --rama: un espacio propio en el worktree de la rama"
check_eq "$(git -C "$TMP/proj-wt/chat-un-cambio" branch --show-current)" "chat/un-cambio" "bk chat --rama: en la rama chat/<nombre>"
git -C "$REPO" worktree add -q -b claude/5-algo "$TMP/proj-wt/5-algo" HEAD
cp "$HD_FAKE/state.json" "$TMP/antes.json"; : >"$HD_FAKE/log"
out=$(bk --dry-run chat --carpeta "$TMP/proj-wt/5-algo" 2>&1)
check_eq "$(log | wc -l | tr -d ' ') $(cmp -s "$HD_FAKE/state.json" "$TMP/antes.json" && echo igual) $(has "$out" "proj-5-algo")" "0 igual si" "bk --dry-run chat --carpeta: dice el espacio y no toca Herdr"
bk chat --carpeta "$TMP/proj-wt/5-algo" >/dev/null 2>&1
check_eq "$(st -r '[.spaces[] | select(.name == "proj-5-algo") | .folder] | first')" "$TMP/proj-wt/5-algo" "bk chat --carpeta: un espacio <proyecto>-<carpeta> en esa carpeta (Enter en alt+b)"
check_eq "$(bk chat --carpeta "$TMP/no-existe" 2>&1 >/dev/null | grep -c 'no existe la carpeta')" "1" "bk chat --carpeta con una carpeta que no existe"

# --- handoff desde Herdr: el origen es el chat de la terminal ---
PATH="$TMP/fake:$PATH" BK_BACKEND=herdr HC_TERMINAL_ID=t1 "$ROOT/bin/bk" handoff --pedido --sid abc123 >/dev/null 2>&1
check_eq "$(jq -r '.session' "$BK_HANDOFF_DIR/abc123.json" 2>/dev/null)" "proj" "bk handoff --pedido en Herdr: anota de qué chat viene"

# --- el resumen quedó escrito (bk handoff --listo, lo corre el hook): si lo pidió la persona se abre solo ---
H="$ROOT/lib/handoff.py"; tabs() { st '[.spaces[].tabs[]] | length'; }
printf '# resumen\n' >"$BK_HANDOFF_DIR/abc123.md"; n0=$(tabs); : >"$HD_FAKE/log"
bk handoff --listo abc123 >/dev/null 2>&1
check_eq "$(( $(tabs) - n0 )) $(log | grep -c 'mod.open')" "1 0" "handoff --listo, pedido por la persona: abre solo el chat nuevo, sin aviso"
last=$(st -r '.terms | to_entries | last | .value.argv | join(" ")')
check_eq "$(has "$last" "handoff.py' take 'abc123'")" "si" "handoff --listo: el chat nuevo arranca con el resumen de esa sesión"
n0=$(tabs); bk handoff --listo abc123 >/dev/null 2>&1
check_eq "$(( $(tabs) - n0 ))" "0" "handoff --listo otra vez: no abre otro chat"
rm -f "$BK_HANDOFF_DIR"/abc123.*
# si lo pidió el aviso rojo: un aviso de Herdr, y el clic (bk handoff --seguir) abre el chat
(cd "$REPO" && HC_TERMINAL_ID=t1 BK_HC="$TMP/fake/hc" PATH="$TMP/fake:$PATH" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import handoff; handoff.request("rojo1", cwd=sys.argv[2])' "$ROOT/lib" "$REPO") >/dev/null
printf '# resumen\n' >"$BK_HANDOFF_DIR/rojo1.md"; n0=$(tabs); : >"$HD_FAKE/log"
bk handoff --listo rojo1 >/dev/null 2>&1
check_eq "$(( $(tabs) - n0 )) $(log | grep -c 'mod.open {"name": "bk-aviso"}')" "0 1" "handoff --listo, pedido por el aviso rojo: no abre nada, muestra un aviso de Herdr"
check_eq "$(jq -r '.title + " | " + .mod' "$HOME/.cache/bk/herdr-aviso.json")" "Resumen listo: proj | bk-seguir" "el aviso dice de qué chat es y su clic abre bk-seguir"
bk handoff --seguir >/dev/null 2>&1
last=$(st -r '.terms | to_entries | last | .value.argv | join(" ")')
check_eq "$(( $(tabs) - n0 )) $(has "$last" "take 'rojo1'")" "1 si" "handoff --seguir (el clic): abre el chat nuevo con el resumen listo"
rm -f "$BK_HANDOFF_DIR"/rojo1.*
bk handoff --seguir >/dev/null 2>&1; check_eq "$?" "1" "handoff --seguir sin resumenes listos: falla"

# --- bk s retoma una sesión cerrada (lib/sessions.py): bk chat con WS_CHAT_CMD, un chat más del proyecto ---
n0=$(tabs); WS_CHAT_CMD="cd '$REPO' && claude --resume abc-123" BK_PROJECT="$REPO" bk chat >/dev/null 2>&1
last=$(st -r '.terms | to_entries | last | .value | (.argv | join(" ")) + " | " + .labels["bk.kind"] + " " + .labels["bk.project"]')
check_eq "$(( $(tabs) - n0 )) $(has "$last" "bash -c cd '$REPO' && claude --resume abc-123 | chat proj")" "1 si" "bk chat con WS_CHAT_CMD: un chat más del proyecto que corre ese comando (retomar desde bk s)"

# --- Herdr cerrado: lo abre y espera; si no responde, no lanza ni deja una tarea ---
: >"$HD_FAKE/closed"; rm -f "$TMP/opened"
out=$(cd "$REPO" && bk run 12 --role implementer 2>&1); rc=$?
check_eq "$rc $(has "$out" "Herdr no respondió")" "1 si" "Herdr cerrado: bk run falla y lo dice"
check_eq "$([ -f "$TMP/opened" ] && echo si || echo no)" "si" "Herdr cerrado: intenta abrirlo"
tasks state proj 12-implementer >/dev/null 2>&1; check_eq "$?" "4" "Herdr cerrado: no crea la tarea"
out=$(cd "$REPO" && BK_HERDR_OPEN="rm -f $HD_FAKE/closed" bk run 12 --role implementer 2>&1); rc=$?
check_eq "$rc $(st -r '[.spaces[0].tabs[].name] | index("i12") != null')" "0 true" "Herdr cerrado: si abre a tiempo, lanza"

# --- lo que es del workspace de tmux no corre con Herdr ---
for c in rail sidebar; do
  out=$(bk "$c" 2>&1); rc=$?
  check_eq "$rc $(has "$out" "es del workspace de tmux")" "1 si" "bk $c con Herdr: avisa y no abre nada de tmux"
done
check_eq "$(grep -c '^tmux' "$TMP/otros.log")" "0" "con Herdr, ningún comando de esta prueba llamó a tmux"
check_eq "$(grep -c '^open' "$TMP/otros.log")" "0" "ni abrió la app real (open)"

# --- el hook de estado anota la terminal de Herdr como pane ---
HOOK="$TMP/agent_hook.sh"
sed "s#^export PATH=.*#export PATH=\"$TMP/fake:\$PATH\"#" "$ROOT/hooks/agent_state.sh" >"$HOOK"
ev() { printf '{"session_id":"%s","hook_event_name":"%s","cwd":"%s"}' "$1" "$2" "$REPO"; }
echo '{"pane": "t9", "state": "waiting"}' >"$STATE/bk-i99.json"
ev s1 SessionStart | HC_TERMINAL_ID=t9 bash "$HOOK"
check_eq "$(jq -r .pane "$STATE/s1.json")" "t9" "hook: en Herdr el pane es HC_TERMINAL_ID"
check_eq "$([ -f "$STATE/bk-i99.json" ] && echo queda || echo borrado)" "borrado" "hook: al arrancar la sesión borra el pre-registro de esa terminal"
ev s2 SessionStart | TMUX_PANE=%3 HC_TERMINAL_ID=t9 bash "$HOOK"
check_eq "$(jq -r .pane "$STATE/s2.json")" "%3" "hook: dentro de tmux manda TMUX_PANE"
ev s3 SessionStart | bash "$HOOK"
check_eq "$(jq -r '.pane // "nada"' "$STATE/s3.json")" "nada" "hook: fuera de tmux y de Herdr no anota pane"
# ~/.claude/settings.json llega al hook por la ruta de cuando era un plugin de Sketchybar (~/.config/sketchybar apunta
# a dotfiles/sketchybar): mientras esa ruta esté registrada, el enlace tiene que seguir ahí y correr tal cual
VIEJA="$ROOT/dotfiles/sketchybar/plugins/agent_hook.sh"
check_eq "$(readlink "$VIEJA")" "../../../hooks/agent_state.sh" "hook: la ruta vieja es un enlace al hook de estado"
ev s4 SessionStart | HC_TERMINAL_ID=t4 "$VIEJA"
check_eq "$(jq -r '.state + " " + .pane' "$STATE/s4.json" 2>/dev/null)" "idle t4" "hook: por la ruta vieja corre y anota el estado"

# Los atajos de tmux en Herdr: bk backend herdr instala los mods bk-* y las teclas alt+… sin pisar las que ya hay
APP="$HOME/.config/herdr-app"; mkdir -p "$APP/mods/bk"; : >"$APP/mods/bk/main.js"
printf '{"global": {"cmd-t": "tab.new", "alt-k": "tab.close", "alt-g": "bk.changes", "alt-0": "bk.last", "alt-f9": "bk.last", "alt-2": "space.select:2", "alt-3": "space.select:5", "alt-,": "app.settings"}, "terminal": {"cmd-c": "terminal.copy"}}\n' >"$APP/keys.json"
cp "$APP/keys.json" "$TMP/keys.antes"; : >"$HD_FAKE/log"
bk backend herdr >/dev/null 2>&1
check_eq "$(cmp -s "$ROOT/herdr/mods/bk/main.js" "$APP/mods/bk-term/main.js" && cmp -s "$ROOT/herdr/mods/bk/mod.json" "$APP/mods/bk-agent9/mod.json" && echo igual)" "igual" "atajos: bk backend herdr copia el mod de las acciones a una carpeta por comando"
# Cada tecla que abre un mod tiene su carpeta completa (una acción o un panel del hub); faltan = las que no
faltan=$(jq -r '.global[] | select(type == "string" and startswith("mod.open:bk-")) | sub("mod.open:"; "")' "$ROOT/herdr/keys.json" \
  | while read -r m; do { [ -f "$APP/mods/$m/main.js" ] && [ -f "$APP/mods/$m/mod.json" ]; } || printf '%s ' "$m"; done)
check_eq "$faltan$(ls "$APP/mods" | grep -c '^bk$') $(ls "$APP/mods" | grep -cE '^bk-(aviso|seguir)$')" "0 2" "atajos: una carpeta con main.js y mod.json por cada tecla que abre un mod, más los dos sin tecla (bk-aviso, bk-seguir), y se va la versión anterior (mods/bk)"
check_eq "$(jq -r '.global["alt-s"] + " " + .global["alt-shift-3"] + " " + .global["alt-9"]' "$APP/keys.json")" "mod.open:bk-sessions mod.open:bk-agent3 mod.open:bk-go9" "atajos: suma las teclas alt+…; alt+N va a la ventana con ese número"
check_eq "$(jq -r '.global["alt-k"] + " " + .global["cmd-t"] + " " + .terminal["cmd-c"]' "$APP/keys.json")" "tab.close tab.new terminal.copy" "atajos: no pisa una tecla que ya hace otra cosa ni las demás"
check_eq "$(jq -r '.global["alt-g"] + " " + .global["alt-0"] + " " + (.global["alt-f9"] // "sin")' "$APP/keys.json")" "mod.open:bk-changes mod.open:bk-last sin" "atajos: actualiza las teclas de la versión anterior de bk y saca la que ya no existe"
check_eq "$(jq -r '.global["alt-2"] + " " + .global["alt-3"] + " " + .global["alt-,"]' "$APP/keys.json")" "mod.open:bk-go2 space.select:5 mod.open:bk-look" "atajos: una tecla que sigue como la dejó una versión anterior de bk se actualiza; una que cambiaste vos, no"
# El mod de las acciones se abre y se cierra solo: su popup mide en px. Hasta 1 es una fracción de la ventana
# (1×1 era un popup invisible a pantalla completa que se comía los clics mientras la acción corría)
check_eq "$(jq -r '(.overlay.width > 1) and (.overlay.height > 1)' "$ROOT/herdr/mods/bk/mod.json")" "true" "atajos: el popup del mod de las acciones no es una fracción de la ventana"
# Los paneles del hub: el mismo paquete en cada carpeta, con su view.js y el tamaño de su ventana
check_eq "$(cat "$APP/mods/bk-issues/view.js") $(cmp -s "$ROOT/herdr/mods/hub/kit.js" "$APP/mods/bk-issues/kit.js" && cmp -s "$ROOT/herdr/mods/hub/main.js" "$APP/mods/bk-prs/main.js" && echo igual)" 'export const VIEW = "issues"; igual' "hub: cada vista es el mismo paquete con un view.js que dice cuál es"
check_eq "$(jq -c '[.place, .overlay]' "$APP/mods/bk-agents/mod.json")" "$(jq -c '["none", .agents.overlay]' "$ROOT/herdr/mods/hub/views.json")" "hub: el mod.json de cada vista lleva place none y el tamaño de views.json"
sin_vista=$(jq -r 'keys[]' "$ROOT/herdr/mods/hub/views.json" | while read -r v; do { [ -f "$ROOT/herdr/mods/hub/$v.js" ] && grep -q "from \"./$v.js\"" "$ROOT/herdr/mods/hub/main.js" && [ -d "$APP/mods/bk-$v" ]; } || printf '%s ' "$v"; done)
check_eq "$sin_vista" "" "hub: cada vista de views.json tiene su archivo, está en main.js y se instala"
check_eq "$(cd "$ROOT/lib" && python3 -c 'import herdr_install as H; print(H.mod_first(["main.js", "a.svg", "mod.json"]))')" "['mod.json', 'a.svg', 'main.js']" "instalador: mod.json va primero (si Herdr ve antes un main.js, acopla el mod en el layout)"
check_eq "$(cmp -s "$TMP/keys.antes" "$APP/keys.json.antes-de-bk" && echo igual)" "igual" "atajos: guarda el keys.json de antes"
check_eq "$(log | grep -c 'mod.open')" "0" "atajos: no deja ningún mod abierto"
cp "$APP/keys.json" "$TMP/keys.despues"; echo otra >"$APP/keys.json.antes-de-bk"
bk backend herdr >/dev/null 2>&1
check_eq "$(cmp -s "$TMP/keys.despues" "$APP/keys.json" && echo igual)" "igual" "atajos: instalar de nuevo no cambia las teclas"
jq 'del(.global["alt-g"])' "$TMP/keys.despues" >"$APP/keys.json"; bk backend herdr >/dev/null 2>&1
check_eq "$(jq -r '.global["alt-g"]' "$APP/keys.json") $(cat "$APP/keys.json.antes-de-bk")" "mod.open:bk-changes otra" "atajos: repone una tecla que falta y no pisa el primer respaldo"
echo '{roto' >"$APP/keys.json"; bk backend herdr >/dev/null 2>&1
check_eq "$(cat "$APP/keys.json")" "{roto" "atajos: un keys.json inválido no se toca"

# Los paneles de bk y su layout, uno solo (bk-lavanda): sigue al repo mientras no lo retoques
rm -rf "$APP/mods" "$APP/layouts"; mkdir -p "$APP/layouts"; echo '{}' >"$APP/keys.json"
echo '{"id":"root"}' >"$APP/layouts/main.json"; : >"$HD_FAKE/log"
L="$APP/layouts/bk-lavanda.json"; SRC="$ROOT/herdr/layouts/bk-lavanda.json"; MARK="$APP/bk-lavanda.instalado"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
bk backend herdr >/dev/null 2>&1
check_eq "$(cmp -s "$ROOT/herdr/mods/tareas/main.js" "$APP/mods/bk-tareas/main.js" && cmp -s "$ROOT/herdr/mods/lado/mod.json" "$APP/mods/bk-lado/mod.json" && cmp -s "$ROOT/herdr/mods/agentes/main.js" "$APP/mods/bk-agentes/main.js" && echo igual)" "igual" "paneles: copia agentes, tareas y lado a mods/bk-<nombre>"
check_eq "$(cmp -s "$SRC" "$L" && echo igual) $(cat "$MARK")" "igual $(sha "$SRC")" "layout: instala bk-lavanda y anota qué instaló"
check_eq "$(ls "$APP/layouts" | tr '\n' ' ') $(cat "$APP/layouts/main.json")" 'bk-lavanda.json bk-lavanda.svg main.json  {"id":"root"}' "layout: uno solo, con su vista previa, y no toca el main de Herdr"
# La vista previa: el layout la nombra en "preview" (una ruta dentro de la carpeta de Herdr). Se copia si falta o si
# difiere. PV sale del layout y solo se lee; lo que el test escribe va a PVD, una ruta fija dentro del Herdr de prueba
PV=$(jq -r '.preview // "sin-preview"' "$SRC"); PVS="$ROOT/herdr/layouts/bk-lavanda.svg"; PVD="$APP/layouts/bk-lavanda.svg"
check_eq "$PV $(cmp -s "$ROOT/herdr/$PV" "$APP/$PV" && echo igual)" "layouts/bk-lavanda.svg igual" "layout: instala la vista previa que nombra (preview)"
echo '<svg/>' >"$PVD"; out=$(bk backend herdr 2>&1)
check_eq "$(cmp -s "$PVS" "$PVD" && echo igual) $(has "$out" "layout bk-lavanda: al día (vista previa actualizada)")" "igual si" "layout: una vista previa distinta a la del repo se actualiza, y se dice"
# no se puede copiar (hay una carpeta con su nombre): avisa y lo que viene después, las teclas, se instala igual
rm -f "$PVD"; mkdir "$PVD"; jq 'del(.global["alt-g"])' "$APP/keys.json" >"$TMP/k" && mv "$TMP/k" "$APP/keys.json"
out=$(bk backend herdr 2>&1)
check_eq "$(has "$out" "no pude copiar la vista previa") $(jq -r '.global["alt-g"]' "$APP/keys.json") $(ls "$APP/layouts" | grep -c 'tmp$')" "si mod.open:bk-changes 0" "layout: si la vista previa no se puede copiar, avisa, no deja restos y el resto se instala igual"
rmdir "$PVD"; bk backend herdr >/dev/null 2>&1
check_eq "$(cmp -s "$PVS" "$PVD" && echo igual)" "igual" "layout: cuando se puede de nuevo, la vista previa vuelve"
check_eq "$(log | grep -c 'layout.switch')" "0" "layout: instalar no cambia el layout que se muestra"
sin_mod=$(jq -r '[.. | objects | .content?.mod? // empty | select(startswith("bk-"))] | unique[]' "$SRC" | while read -r m; do [ -f "$APP/mods/$m/main.js" ] || printf '%s ' "$m"; done)
check_eq "$sin_mod$(jq -r '[.. | objects | .content?.mod? // empty | select(startswith("bk-"))] | unique | length > 3' "$SRC")" "true" "layout: los mods de bk que nombra se instalan todos"
# kit.js, las piezas de dibujo de los paneles del layout: un mod no importa de otra carpeta, así que cada uno lleva
# su copia. Todas iguales (la de agentes es la referencia), y cada una se instala al lado del main.js que la importa
KITS=$(cd "$ROOT/herdr/mods" && for d in *; do [ "$d" = hub ] || [ ! -f "$d/kit.js" ] || printf '%s ' "$d"; done)
distintos=$(for m in $KITS; do cmp -s "$ROOT/herdr/mods/agentes/kit.js" "$ROOT/herdr/mods/$m/kit.js" || printf '%s ' "$m"; done)
check_eq "$KITS| $distintos" "agentes cabecera lado marca pestanas | " "kit.js: las copias de agentes, cabecera, lado, marca y pestanas son el mismo archivo"
# La lista de espacios en carpetas: lo suyo se instala con cada mod (el modelo va en los dos que lo usan)
check_eq "$(for f in bk-agentes/lista.js bk-agentes/editar.js bk-agentes/espacios.js bk-menu/espacios.js bk-menu/chevron-up.svg; do [ -f "$APP/mods/$f" ] || printf '%s ' "$f"; done)$(cmp -s "$APP/mods/bk-agentes/espacios.js" "$APP/mods/bk-menu/espacios.js" && echo igual)" "igual" "espacios: la lista, su diálogo, el modelo (en agentes y en el menú) y el icono de Subir se instalan"
sin_kit=$(grep -l 'from "./kit.js"' "$ROOT"/herdr/mods/*/main.js | while read -r f; do m=$(basename "$(dirname "$f")"); [ "$m" = hub ] || cmp -s "$ROOT/herdr/mods/$m/kit.js" "$APP/mods/bk-$m/kit.js" || printf '%s ' "$m"; done)
check_eq "$(grep -l 'from "./kit.js"' "$ROOT"/herdr/mods/*/main.js | grep -vc '/hub/') $sin_kit" "5 " "kit.js: cada panel que lo importa lo tiene instalado en su carpeta"
# Los temas de bk: se instalan, siguen al repo mientras nadie los retoque y no pisan uno tuyo
T1=$(ls "$ROOT/herdr/themes" | head -1)
check_eq "$(ls "$ROOT/herdr/themes" | while read -r f; do cmp -s "$ROOT/herdr/themes/$f" "$APP/themes/$f" || printf '%s ' "$f"; done)$(jq -r --arg f "$T1" '.[$f]' "$APP/bk-temas.json")" "$(sha "$ROOT/herdr/themes/$T1")" "temas: instala los de herdr/themes y anota qué instaló"
echo '{"background":"#000000"}' >"$APP/themes/$T1"; jq --arg f "$T1" --arg s "$(sha "$APP/themes/$T1")" '.[$f] = $s' "$APP/bk-temas.json" >"$TMP/temas" && mv "$TMP/temas" "$APP/bk-temas.json"
bk backend herdr >/dev/null 2>&1
check_eq "$(cmp -s "$ROOT/herdr/themes/$T1" "$APP/themes/$T1" && echo igual)" "igual" "temas: una copia que bk instaló y nadie tocó se actualiza con la del repo"
echo '{"background":"#111111"}' >"$APP/themes/$T1"; out=$(bk backend herdr 2>&1)
check_eq "$(cat "$APP/themes/$T1") $(has "$out" "no piso los tuyos: $T1")" '{"background":"#111111"} si' "temas: uno retocado no se pisa, y se avisa"
# bk-noche pasó a llamarse bk-neon: la copia vieja que bk instaló se va; una retocada queda
echo '{"background":"#15142b"}' >"$APP/themes/bk-noche.json"
jq --arg s "$(sha "$APP/themes/bk-noche.json")" '.["bk-noche.json"] = $s' "$APP/bk-temas.json" >"$TMP/temas" && mv "$TMP/temas" "$APP/bk-temas.json"
out=$(bk backend herdr 2>&1)
check_eq "$([ -e "$APP/themes/bk-noche.json" ] && echo queda || echo se-fue) $(jq -r '.["bk-noche.json"] // "sin-marca"' "$APP/bk-temas.json") $(has "$out" "se fue bk-noche → bk-neon")" "se-fue sin-marca si" "temas: el bk-noche que bk instaló se borra (ahora es bk-neon), y se dice"
echo '{"background":"#15142b"}' >"$APP/themes/bk-noche.json"
jq '.["bk-noche.json"] = "otro"' "$APP/bk-temas.json" >"$TMP/temas" && mv "$TMP/temas" "$APP/bk-temas.json"
bk backend herdr >/dev/null 2>&1
check_eq "$([ -e "$APP/themes/bk-noche.json" ] && echo queda)" "queda" "temas: un bk-noche retocado no se borra"
rm -f "$APP/themes/bk-noche.json"
# Los tres de bk: completos, legibles (contraste WCAG) y de la claridad que dicen; el layout los usa de par
check_eq "$(python3 - "$ROOT/herdr" <<'PY'
import json, re, sys
root = sys.argv[1]
def lum(h):
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (1, 3, 5))
    f = lambda c: c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
def cr(a, b):
    x, y = sorted((lum(a), lum(b)), reverse=True)
    return (x + 0.05) / (y + 0.05)
NEED = ("canvas", "chrome", "background", "surface", "popover", "raised", "hover", "selected", "border", "input",
        "foreground", "muted", "dim", "accent", "accent_foreground", "working", "blocked", "done", "idle")
bad = []
for name, light in (("bk-neon", False), ("bk-pastel", False), ("bk-dia", True)):
    t = json.load(open(f"{root}/themes/{name}.json")); c = t.get("colors", {})
    hexes = [t["background"], t["foreground"], t["selection"], *t["ansi"], *c.values()]
    if len(t["ansi"]) != 16 or not all(re.fullmatch(r"#[0-9a-f]{6}", h) for h in hexes): bad.append(f"{name}: forma")
    if [k for k in NEED if k not in c]: bad.append(f"{name}: faltan {[k for k in NEED if k not in c]}")
    if (lum(t["background"]) > 0.5) != light: bad.append(f"{name}: claridad")
    for fg, n in (("foreground", 7), ("muted", 4.5), ("dim", 3), ("accent", 3), ("working", 3), ("blocked", 3), ("done", 3)):
        for bg in ("background", "chrome", "selected"):
            if cr(c[fg], c[bg]) < n: bad.append(f"{name}: {fg}/{bg}")
    if cr(c["accent_foreground"], c["accent"]) < 4.5: bad.append(f"{name}: accent_foreground")
    if min(cr(a, t["background"]) for a in t["ansi"][1:7] + t["ansi"][9:15]) < 3: bad.append(f"{name}: ansi")
lay = json.load(open(f"{root}/layouts/bk-lavanda.json"))["theme"]
if lay != {"light": "bk-dia", "dark": "bk-neon"}: bad.append(f"layout: {lay}")
print(" ".join(bad) or "ok")
PY
)" "ok" "temas: bk-neon, bk-pastel y bk-dia completos, legibles y de su claridad; el layout usa bk-dia de día y bk-neon de noche"
echo '{"id":"viejo"}' >"$L"; sha "$L" >"$MARK"; bk backend herdr >/dev/null 2>&1
check_eq "$(cmp -s "$SRC" "$L" && echo igual) $(cat "$MARK")" "igual $(sha "$SRC")" "layout: una copia que bk instaló y nadie tocó se actualiza con la del repo"
jq '.retoque = 1' "$SRC" >"$L"; cp "$L" "$TMP/retocado"; echo '<svg/>' >"$PVD"; out=$(bk backend herdr 2>&1)
check_eq "$(cmp -s "$TMP/retocado" "$L" && echo igual) $(has "$out" "lo retocaste, no lo piso") $(cat "$MARK")" "igual si $(sha "$SRC")" "layout: una copia retocada no se pisa, y se avisa"
check_eq "$(cmp -s "$PVS" "$PVD" && echo igual)" "igual" "layout: con el layout retocado, la vista previa igual sigue a la del repo"
rm -f "$MARK"; echo '{"id":"de otro"}' >"$L"; bk backend herdr >/dev/null 2>&1
check_eq "$(cat "$L") $([ -f "$MARK" ] && echo marca || echo sin)" '{"id":"de otro"} sin' "layout: una copia que bk no instaló tampoco se pisa"
rm -f "$L"; bk backend herdr >/dev/null 2>&1
check_eq "$(cmp -s "$SRC" "$L" && echo igual)" "igual" "layout: borrarlo y repetir trae el del repo"

# --- bk s (lib/sessions.py): el id de la terminal en cada fila y el cierre sin demora ---
check_eq "$(cd "$ROOT/lib" && python3 -c 'import sessions as S; print(S.where({"herdr": True, "window": "t2d barrilete-kit / pr285"}))')" "t2d barrilete-kit / pr285" "bk s: una sesión de Herdr se muestra con el id de su terminal"
check_eq "$(cd "$ROOT/lib" && python3 -c 'import sessions as S, json; S.sh = lambda *a: json.dumps({"terminals": [{"address": "t2d", "state": "live", "where": "kit / pr285"}, {"address": "t9", "state": "live"}]}); print(sorted(v["window"] for v in S.herdr_panes().values()))')" "['t2d kit / pr285', 't9']" "bk s: herdr_panes pone el id delante del espacio y la pestaña"
check_eq "$(cd "$ROOT/lib" && env -u ESCDELAY python3 -c 'import os, sessions; print(os.environ.get("ESCDELAY"))')" "25" "bk s: esc cierra sin la espera de un segundo de curses (ESCDELAY)"
check_eq "$(cd "$ROOT/lib" && ESCDELAY=300 python3 -c 'import os, sessions; print(os.environ.get("ESCDELAY"))')" "300" "bk s: respeta un ESCDELAY que la persona ya definió"

# --- números fijos de ventana (bk.id), adopción de lo abierto desde Herdr y handoff pedido desde afuera ---
rm -f "$HD_FAKE/state.json" "$STATE"/*.json; rm -rf "$BK_HANDOFF_DIR"; : >"$HD_FAKE/log"
fake() { python3 "$HERE/herdr_fake.py" "$@"; }
idof() { st -r --arg t "$1" '.terms[$t].labels["bk.id"] // "sin"'; }
newtab() { fake app do tab.new "$(jq -cn --arg s "$(st -r '.spaces[0].id')" --arg f "$REPO" --arg a "$1" '{space: $s, name: $a, folder: $f, argv: [$a]}')" | jq -r .terminal; }
(cd "$REPO" && bk >/dev/null 2>&1); (cd "$REPO" && bk chat >/dev/null 2>&1)
check_eq "$(idof t1) $(idof t2)" "1 2" "número de ventana: cada chat toma al nacer el libre más chico"
fake hc kill t1 >/dev/null; (cd "$REPO" && bk chat >/dev/null 2>&1)
check_eq "$(idof t3)" "1" "número de ventana: el de una ventana que se cerró vuelve a estar libre"
# un claude abierto desde Herdr (el + de las pestañas): sin etiquetas de bk, informa estado
fst() { jq "$@" "$HD_FAKE/state.json" >"$TMP/st" && mv "$TMP/st" "$HD_FAKE/state.json"; }   # retocar el Herdr falso
informa() { fst --arg t "$1" '.terms[$t].status = {"app": "claude-code", "state": "idle"}'; }
T4=$(newtab claude); informa "$T4"
got=$(bk _adopt "$T4" 2>/dev/null)
check_eq "$got $(st -r --arg t "$T4" '.terms[$t].labels | .["bk.kind"] + " " + .["bk.project"] + " " + .["bk.win"] + " " + .["bk.id"]')" "3 chat proj proj 3" "adopción: un agente abierto desde Herdr pasa a ser un chat de su proyecto, con su número"
check_eq "$(bk _adopt "$T4" 2>/dev/null) $(st -r --arg t "$T4" '.terms[$t].labels["bk.win"]')" "3 proj" "adopción: repetirla no cambia ni el número ni el nombre"
T5=$(newtab zsh); bk _adopt "$T5" >/dev/null 2>&1
check_eq "$(st -r --arg t "$T5" '.terms[$t] | .argv[0] + " " + (.labels["bk.kind"] // "sin") + " " + (.labels["bk.id"] // "sin")')" "zsh sin sin" "adopción: una shell (no informa estado) no se toca"
T6=$(newtab claude); informa "$T6"; fst --arg t "$T6" 'del(.terms[$t].labels["herdr.tab"])'; bk _adopt "$T6" >/dev/null 2>&1
check_eq "$(st -r --arg t "$T6" '.terms[$t] | .status.app + " " + (.labels["bk.kind"] // "sin") + " " + (.labels["bk.id"] // "sin")')" "claude-code sin sin" "adopción: un agente sin pestaña (un popup) no se toca"
T7=$(newtab claude); informa "$T7"; bk _adopt "$T7" >/dev/null 2>&1
check_eq "$(st -r --arg t "$T7" '.terms[$t].labels | .["bk.win"] + " " + .["bk.id"]')" "proj-4 4" "adopción: si el nombre del proyecto ya es de otro chat, toma el primero libre (proj-4) y el número que sigue"
: >"$HD_FAKE/log"; (cd "$REPO" && bk go 3 >/dev/null 2>&1)
check_eq "$(log | grep -c "pane.focus {\"terminal\": \"$T4\"}")" "1" "bk go N: muestra la ventana con ese número fijo"
: >"$HD_FAKE/log"; (cd "$REPO" && bk say 2 "hola vos" >/dev/null 2>&1)
check_eq "$(log | grep -c '^hc send t2 hola vos')" "1" "bk say N: le escribe a la ventana con ese número"
(cd "$REPO" && bk go 9 >/dev/null 2>&1); check_eq "$?" "1" "bk go N: un número que nadie tiene no inventa una ventana"
# alt+h: el pedido de resumen llega desde afuera del chat (bk handoff --term), con o sin "y cerrá este chat"
echo "{\"pane\": \"$T4\", \"state\": \"idle\"}" >"$STATE/sidA.json"; : >"$HD_FAKE/log"
bk handoff --term "$T4" --cerrar >/dev/null 2>&1
check_eq "$(log | grep -c "^hc send $T4 .*handoff --pedido --sid sidA") $(cat "$BK_HANDOFF_DIR/sidA.cerrar" 2>/dev/null)" "1 $T4" "handoff --term --cerrar: le pide el resumen a ese chat y anota que después se cierra"
bk handoff --term "$T4" >/dev/null 2>&1
check_eq "$([ -f "$BK_HANDOFF_DIR/sidA.cerrar" ] && echo queda || echo sin)" "sin" "handoff --term sin --cerrar: no deja la marca de un pedido anterior"
echo '{"pane": "t2", "state": "idle"}' >"$STATE/sidB.json"; : >"$HD_FAKE/log"
bk handoff 2 >/dev/null 2>&1
check_eq "$(log | grep -c '^hc send t2 .*handoff --pedido --sid sidB')" "1" "handoff N: el chat también se nombra por su número de ventana"
# un agente abierto desde Herdr que la barra todavía no adoptó: handoff --term lo adopta y le pide el resumen
T8=$(newtab claude); informa "$T8"; echo "{\"pane\": \"$T8\", \"state\": \"idle\"}" >"$STATE/sidE.json"; : >"$HD_FAKE/log"
bk handoff --term "$T8" >/dev/null 2>&1
check_eq "$(log | grep -c "^hc send $T8 .*handoff --pedido --sid sidE") $(st -r --arg t "$T8" '.terms[$t].labels["bk.kind"] // "sin"')" "1 chat" "handoff --term: adopta una terminal que bk no conocía y le pide el resumen"
# el agente escribe el resumen (bk handoff --pedido deja el .json; el hook corre --listo): abre el nuevo y cierra el viejo
pedido() { PATH="$TMP/fake:$PATH" BK_BACKEND=herdr HC_TERMINAL_ID="$1" "$ROOT/bin/bk" handoff --pedido --sid "$2" >/dev/null 2>&1; echo "# resumen" >"$BK_HANDOFF_DIR/$2.md"; }
bk handoff --term "$T4" --cerrar >/dev/null 2>&1; pedido "$T4" sidA; : >"$HD_FAKE/log"
bk handoff --listo sidA >/dev/null 2>&1
check_eq "$(log | grep -c '^app do tab.new') $(log | grep -c "^hc kill $T4") $([ -f "$BK_HANDOFF_DIR/sidA.cerrar" ] && echo queda || echo sin)" "1 1 sin" "handoff --listo con la marca: abre el chat nuevo y cierra el viejo"
bk handoff --term t2 --cerrar >/dev/null 2>&1; pedido t2 sidB; mv "$STATE/sidB.json" "$STATE/sidC.json"; : >"$HD_FAKE/log"
bk handoff --listo sidB >/dev/null 2>&1
check_eq "$(log | grep -c '^app do tab.new') $(log | grep -c '^hc kill t2')" "1 0" "handoff --listo: si esa terminal ya es de otra sesión, no la cierra"
echo '{"pane": "t3", "state": "idle"}' >"$STATE/sidD.json"
bk handoff --term t3 --cerrar >/dev/null 2>&1; pedido t3 sidD; touch -t 202001010000 "$BK_HANDOFF_DIR/sidD.cerrar"; : >"$HD_FAKE/log"
bk handoff --listo sidD >/dev/null 2>&1
check_eq "$(log | grep -c '^app do tab.new') $(log | grep -c '^hc kill t3')" "1 0" "handoff --listo: una marca de hace más de media hora no cierra nada"

echo "1..$N"
[ "$FAILED" -eq 0 ]
