#!/usr/bin/env bash
# bk s (lib/sessions.py): el número del workspace en cada chat y qué cierra x. Sin tmux: datos de prueba.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
py() { python3 - "$ROOT/lib" "$@" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import sessions as S
cmd, a = sys.argv[2], sys.argv[3:]
if cmd == "where":   # sesión ventana wsid
    print(S.where({"session": a[0], "window": a[1], "wsid": a[2] if len(a) > 2 else ""}))
elif cmd == "close":   # sesión actual
    it = {"session": a[0] or None, "target": f"{a[0]}:1", "pane": "%1"}
    print(*S.close_action(it, a[1] or None))
PY
}
check_eq "$(py where bk-barrilete-workspace main 3)" "ws 3" "chat de un workspace: su número fijo"
check_eq "$(py where agents i226)" "i226" "agente: su ventana"
check_eq "$(py where term-abra zsh)" "term-abra:zsh" "otra sesión sin número: sesión y ventana"
check_eq "$(py close agents bk-x)" "window agents:1" "x sobre un agente: cierra su ventana"
check_eq "$(py close bk-barrilete-workspace bk-otro)" "session bk-barrilete-workspace" "x sobre otro workspace: cierra el workspace (con confirmación)"
check_eq "$(py close bk-otro bk-otro | cut -d' ' -f1)" "error" "x sobre el workspace donde estás: no"
check_eq "$(py close term-abra bk-otro | cut -d' ' -f1)" "error" "x sobre otra sesión de tmux: no"

# --- Con Herdr: saltar a una sesión es mostrar su pestaña; retomar una reciente, un chat más de su proyecto ---
# hc, herdr-app y bk falsos: nada toca el Herdr real ni abre chats
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/hc" <<EOF
#!/bin/sh
echo "hc \$*" >>"$TMP/log"
case "\$1 \$2" in
  "ls --json") echo '{"terminals":[{"address":"t7","state":"live","where":"proj / chat"},{"address":"t8","state":"finished","where":"proj / 2"}]}' ;;
  "get t7")    echo '{"labels":{"herdr.space":"sp1","herdr.tab":"tb7"}}' ;;
  "get t9")    echo '{"labels":{}}' ;;
esac
EOF
printf '#!/bin/sh\necho "app $*" >>"%s/log"\necho "{}"\n' "$TMP" >"$TMP/herdr-app"
printf '#!/bin/sh\necho "bk $* | $BK_BACKEND | $BK_PROJECT | $WS_CHAT_CMD" >>"%s/log"\n' "$TMP" >"$TMP/bk"
printf '#!/bin/sh\necho "tmux $*" >>"%s/log"\nexit 1\n' "$TMP" >"$TMP/tmux"
chmod +x "$TMP"/*; mkdir -p "$TMP/dir con espacio"
hpy() { : >"$TMP/log"; PATH="$TMP:$PATH" BK_HC="$TMP/hc" BK_HERDR_APP="$TMP/herdr-app" BK_BACKEND="${BACK:-herdr}" python3 - "$ROOT/lib" "$TMP" "$@" <<'PY2'
import sys; sys.path.insert(0, sys.argv[1]); import sessions as S
tmp, cmd, a = sys.argv[2], sys.argv[3], sys.argv[4:]
S.BK = tmp + "/bk"
def run(res):
    err, steps = res
    for st in steps or []:
        st() if callable(st) else S.subprocess.run(st)
    print(err or "ok")
if cmd == "panes":
    print(sorted(S.herdr_panes()), S.where(S.herdr_panes()["t7"]))
elif cmd == "gone":   # pane, panes de tmux, terminales de Herdr
    print(S.gone(a[0], dict.fromkeys(a[1].split()), dict.fromkeys(a[2].split())))
elif cmd == "open":   # dirección de una sesión abierta en Herdr
    run(S.open_row({"sid": "s1", "pane": a[0], "target": a[0], "herdr": True, "state": "idle"}))
elif cmd == "resume":   # carpeta de una sesión reciente
    run(S.open_row({"sid": "abc-123", "cwd": a[0], "proj": "proj"}))
elif cmd == "close":
    print(S.close_action({"herdr": True, "pane": "t7", "target": "t7", "session": "herdr"}, None)[1].split(":")[0])
PY2
}
check_eq "$(hpy panes)" "['t7'] t7 proj / chat" "Herdr: las terminales vivas, con el id de la terminal delante de su espacio y pestaña (una terminada no cuenta)"
check_eq "$(hpy gone t8 '%1' 't7')" "True" "una sesión cuya terminal de Herdr ya no está: se fue"
check_eq "$(hpy gone t7 '%1' 't7')" "False" "una sesión en una terminal viva de Herdr: sigue, aunque tmux no la conozca"
check_eq "$(hpy gone t7 '%1' '')" "False" "Herdr no respondió (o el backend es tmux): no se da por muerta una terminal suya"
check_eq "$(hpy gone '%5' '%1' 't7')" "True" "un pane de tmux que ya no está: se fue"
check_eq "$(hpy gone '%5' '' 't7')" "False" "tmux no respondió: no se da por muerto un pane suyo"
check_eq "$(hpy open t7)" "ok" "Herdr: enter sobre una sesión abierta no da error"
check_eq "$(grep -c '^tmux' "$TMP/log") $(grep '^app' "$TMP/log" | tr '\n' ';')" "0 app do space.select --id sp1;app do tab.select --id tb7;app do pane.focus --terminal t7;" "Herdr: muestra su espacio, su pestaña y la enfoca, sin tmux"
check_eq "$(hpy open t9 | cut -d' ' -f1-3) $(grep -c '^app' "$TMP/log")" "no encuentro su 0" "Herdr: una terminal sin pestaña avisa y no hace nada"
check_eq "$(hpy resume "$TMP/dir con espacio")" "ok" "Herdr: enter sobre una reciente no da error"
check_eq "$(grep -c '^tmux' "$TMP/log") $(grep '^bk' "$TMP/log")" "0 bk chat | herdr | $TMP/dir con espacio | cd '$TMP/dir con espacio' && exec claude --resume abc-123" "Herdr: retomar es bk chat en su proyecto, con claude --resume en la carpeta de la sesión, sin tmux"
BACK=tmux hpy resume "$TMP/dir con espacio" >/dev/null
check_eq "$(grep -c '^bk' "$TMP/log") $(grep -c '^tmux has-session' "$TMP/log")" "0 1" "con tmux, retomar sigue siendo una ventana de tmux"
check_eq "$(hpy close)" "vive en Herdr" "x sobre una sesión de Herdr: no cierra nada y dice dónde cerrarla"
# --- bk revive: los chats que murieron sin avisar quedan anotados y se retoman todos juntos ---
# Estado, transcripts y registro en la carpeta temporal; el hc falso dice qué terminales hay y qué corre en cada una
R="$TMP/r"; mkdir -p "$R/state" "$R/projects/-proj"
cat >"$TMP/hc" <<EOF
#!/bin/sh
echo "hc \$*" >>"$TMP/log"
case "\$1 \$2" in
  "ls --json") echo '{"terminals":[{"address":"t7","state":"live","agent":"claude-code","status":"idle","where":"proj / chat"},{"address":"t6","state":"live","agent":"zsh","where":"proj / 2"},{"address":"t5","state":"live","agent":"zsh","where":"proj / 3"},{"address":"t8","state":"live","agent":"zsh","where":"proj / 4"}]}' ;;
esac
EOF
# Los procesos: en t6 solo queda el shell; en t8 corre un claude detrás de un bash -c (Herdr dice zsh)
cat >"$TMP/ps" <<'EOF'
#!/bin/sh
case "$*" in
  *E*) echo "  101 -zsh TERM=x HC_TERMINAL_ID=t6"; echo "  202 claude -- hola TERM=x HC_TERMINAL_ID=t8"
       echo "  303 /bin/bash -c claude TERM=x HC_TERMINAL_ID=t6" ;;
  *)   echo "  101 -zsh"; echo "  202 /Users/x/.local/bin/claude"; echo "  303 /bin/bash" ;;
esac
EOF
chmod +x "$TMP/ps"
seed() {   # sid pane hace-cuántos-segundos: una sesión con su estado y su transcript
  printf '{"state":"working","pane":"%s","cwd":"%s","ts":%s}\n' "$2" "$TMP/dir con espacio" "$(( $(date +%s) - $3 ))" >"$R/state/$1.json"
  printf '{"type":"user","cwd":"%s","message":{"content":"hola %s"}}\n' "$TMP/dir con espacio" "$1" >"$R/projects/-proj/$1.jsonl"
}
rpy() { : >"$TMP/log"; PATH="$TMP:$PATH" BK_HC="$TMP/hc" BK_HERDR_APP="$TMP/herdr-app" BK_BACKEND="${BACK:-herdr}" python3 - "$ROOT/lib" "$TMP" "$@" <<'PY3'
import sys; sys.path.insert(0, sys.argv[1]); import sessions as S
tmp, cmd, a = sys.argv[2], sys.argv[3], sys.argv[4:]
S.BK, S.STATE, S.PROJECTS, S.CACHE, S.DEAD = tmp + "/bk", tmp + "/r/state", tmp + "/r/projects", tmp + "/r/cache.json", tmp + "/r/dead.json"
if cmd == "open":   # las abiertas; con "look", sin anotar ni borrar (como bk _hub)
    print(*sorted(r["sid"] for r in S.load(prune=a[:1] != ["look"])[0]))
elif cmd == "dead":
    print(*[f"{d['sid']}:{d['why']}" for d in S.dead()])
elif cmd == "revive":
    sys.exit(S.revive(a))
PY3
}
seed viva t7 500; seed cerrada t9 500; seed vacia t6 500; seed nueva t5 5
check_eq "$(rpy open look)" "nueva viva" "una sesión con la terminal en consola vacía (o cerrada) no figura como abierta; una recién lanzada sí"
check_eq "$(rpy dead) $(ls "$R/state" | wc -l | tr -d ' ')" " 4" "mirar (bk _hub) no anota ni borra nada"
check_eq "$(rpy open)" "nueva viva" "bk s: las mismas abiertas"
check_eq "$(rpy dead)" "cerrada:cerrada vacia:vacia" "las que murieron sin avisar quedan anotadas, con el motivo"
check_eq "$(ls "$R/state" | tr '\n' ' ')" "nueva.json viva.json " "y su estado viejo se borra, como antes"
check_eq "$(rpy revive --dry-run | grep -c 'cerrada\|vacia') $(grep -c '^bk' "$TMP/log") $(rpy dead | wc -w | tr -d ' ')" "2 0 2" "bk revive --dry-run: las lista y no abre ni olvida nada"
check_eq "$(rpy revive nada >/dev/null 2>&1; echo $?) $(grep -c '^bk' "$TMP/log")" "1 0" "bk revive <algo que no está anotado>: error y no abre nada"
rpy revive cerr >/dev/null
check_eq "$(grep '^bk' "$TMP/log")" "bk chat | herdr | $TMP/dir con espacio | cd '$TMP/dir con espacio' && exec claude --resume cerrada" "bk revive <principio del id>: retoma solo esa, como Enter sobre una reciente"
check_eq "$(rpy dead)" "vacia:vacia" "la retomada sale de la lista"
seed otra t9 500; rpy open >/dev/null; rpy revive >/dev/null
check_eq "$(grep -c '^bk chat' "$TMP/log") $(rpy dead | wc -w | tr -d ' ')" "2 0" "bk revive: retoma todas las anotadas y la lista queda vacía"
check_eq "$(rpy revive)" "no hay chats muertos anotados" "sin nada anotado, lo dice"
seed vuelve t9 500; rpy open >/dev/null; seed vuelve t7 5
check_eq "$(rpy dead)" "" "una anotada que volvió a abrirse (por otro lado) deja de estar muerta"
seed adios t9 500; rpy open >/dev/null; rpy revive --forget >/dev/null
check_eq "$(grep -c '^bk' "$TMP/log") $(rpy dead | wc -w | tr -d ' ')" "0 0" "bk revive --forget: las saca de la lista sin abrir nada"
# El caso real (2026-11-21): un chat que siguió de un resumen corre claude detrás de bash -c y Herdr dice "zsh";
# sin mirar los procesos, bk ls lo daba por muerto, le borraba el estado y bk revive lo duplicaba
rm -f "$R/dead.json" "$R"/state/*.json; seed escondida t8 500; seed vacia t6 500
check_eq "$(rpy open)" "escondida" "un claude vivo detrás de un bash -c (Herdr dice zsh) sigue abierto"
check_eq "$(rpy dead)" "vacia:vacia" "y no queda anotado como muerto; la consola vacía de verdad sí"
echo "1..$N"
[ "$FAILED" -eq 0 ]
