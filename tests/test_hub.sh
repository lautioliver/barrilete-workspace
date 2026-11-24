#!/usr/bin/env bash
# bk _hub (lib/herdr_hub.py) y bk _do: los datos de los paneles nativos de Herdr y las acciones sueltas con aviso.
# Todo vive en un directorio temporal: HOME, tareas, resúmenes, caché, un repo con su worktree, un Herdr falso
# (tests/herdr_fake.py), un gh falso que contesta desde archivos y un mpv falso (un socket que responde como el de
# bk song). También tmux, open y sketchybar falsos. Nada toca el Herdr real, GitHub, la música ni tu config (el
# origin del repo es de github.com para que bk sepa su owner/repo: GIT_SSH_COMMAND=false, por si algo hiciera fetch).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); MPV_PID=""
trap '[ -z "$MPV_PID" ] || kill "$MPV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
unset TMUX TMUX_PANE HC_TERMINAL_ID BK_BACKEND BK_ACCOUNT BK_ACCOUNT_CLAUDE BK_TASK_DIR BK_PROJECT BK_WS_NAME BK_HC \
      BK_HERDR_APP BK_CACHE_DIR XDG_CACHE_HOME BK_TASKS_DIR BK_PROJECTS BK_STATE_DIR GIT_DIR GIT_WORK_TREE \
      GH_CONFIG_DIR GH_TOKEN BK_HUB_DEBUG WS_CHAT_CMD BK_SESSION BK_CONFIG_DIR BK_SONG_CACHE
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" HD_FAKE="$TMP/hd" BK_HANDOFF_DIR="$TMP/handoff" \
       BK_PRS_CACHE="$TMP/prs-cache.json" BARRILETE_VAULT="$TMP/vault" BK_CHECKPOINTS_OFFLINE=1 BK_NEW_SKIP='-wt/' \
       BK_FORCE=1 BK_BOT=0 BK_HERDR_WAIT=1 BK_HERDR_OPEN=true GIT_SSH_COMMAND=false GIT_TERMINAL_PROMPT=0 BK_NO_SWEEP=1
mkdir -p "$HOME" "$TMP/fake" "$HD_FAKE" "$TMP/s"
for b in app hc; do
  n=$([ $b = app ] && echo herdr-app || echo hc)
  printf '#!/bin/sh\nexec python3 "%s/herdr_fake.py" %s "$@"\n' "$HERE" "$b" >"$TMP/fake/$n"
done
for b in tmux open sketchybar; do printf '#!/bin/sh\necho "%s $*" >> "%s/otros.log"\nexit 1\n' "$b" "$TMP" >"$TMP/fake/$b"; done
# gh: contesta desde $TMP/gh-*.json y anota cada pedido. sin-red: no responde nada; sin-links: falla la lista corta de PRs
cat >"$TMP/fake/gh" <<FAKE
#!/bin/sh
echo "\$*" >>"$TMP/gh.log"
[ -f "$TMP/sin-red" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
case "\$1 \$2" in
  "issue list") case "\$*" in *"-R o/r"*) cat "$TMP/gh-issues.json" ;; *) echo "falta -R o/r" >&2; exit 3 ;; esac ;;
  "pr list")    case "\$*" in
                  *statusCheckRollup*) cat "$TMP/gh-prs.json" ;;
                  *) [ -f "$TMP/sin-links" ] && exit 1; cat "$TMP/gh-links.json" ;;
                esac ;;
  "api "*)      echo "Título de \${2##*/}" ;;
  *) exit 1 ;;
esac
FAKE
printf '#!/bin/sh\nexit 1\n' >"$TMP/hc-roto"
chmod +x "$TMP/fake"/* "$TMP/hc-roto"; : >"$TMP/otros.log"; : >"$TMP/gh.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
has() { case "$1" in *"$2"*) echo si ;; *) echo no ;; esac; }
bk()  { PATH="$TMP/fake:$PATH" BK_BACKEND=herdr "$ROOT/bin/bk" "$@"; }
hub() { bk _hub "$@"; }
# La música: BK_SONG_CACHE relativo y desde $TMP, porque la ruta de un socket de unix no pasa de ~100 caracteres
hubs() { (cd "$TMP" && BK_SONG_CACHE=s hub "$@"); }
tk()  { python3 "$ROOT/lib/tasks.py" "$@"; }
g()   { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
calls() { wc -l <"$TMP/gh.log" | tr -d ' '; }
lines() { printf '%s' "$1" | grep -c '' ; }
# espera <segundos> <comando…>: hasta que salga bien (lo que corre suelto termina cuando quiere)
espera() { local n=$(( $1 * 10 )); shift; while [ "$n" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; n=$((n - 1)); done; return 1; }
# viejo <archivo> <minutos>: como si lo hubieran escrito hace tanto
viejo() { python3 -c 'import os, sys, time; t = time.time() - 60 * int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
reciente() { python3 -c 'import os, sys, time; sys.exit(0 if time.time() - os.path.getmtime(sys.argv[1]) < 60 else 1)' "$1"; }
HUBC="$HOME/.cache/bk/hub"; STATE="$HOME/.cache/sketchybar/agents"; PROJ="$HOME/.claude/projects"
TASKS="$XDG_STATE_HOME/bk/tasks"; AV="$HOME/.cache/bk/herdr-avisos"; TODAY=$(date +%Y-%m-%d)

# ---------- lo que hay: un repo con cambios, su worktree, tareas, Herdr, sesiones ----------
REPO="$TMP/proj"; WT="$TMP/proj-wt/7"
g init -q -b main "$REPO"; g -C "$REPO" remote add origin "git@github.com:o/r.git"
mkdir -p "$REPO/scripts/agents"; : >"$REPO/scripts/agents/guardrails.py"
printf 'uno\ndos\ntres\n' >"$REPO/a.txt"; echo x >"$REPO/borrar.txt"; echo igual >"$REPO/igual.txt"
printf '\000\001\002\n' >"$REPO/img.bin"
g -C "$REPO" add -A; g -C "$REPO" commit -qm inicio
g -C "$REPO" worktree add -q -b w7 "$WT" >/dev/null 2>&1
g -C "$REPO" worktree add -q --detach "$TMP/proj-wt/limpio" >/dev/null 2>&1   # otro worktree, sin rama y sin nada sin commitear
g init -q -b main "$TMP/otro"; mkdir -p "$TMP/suelta" "$TMP/sinsesiones" "$HOME/.bk/chats"
# sin commitear en el repo: 4 archivos que git sigue y 8 nuevos
printf 'uno\nDOS\ntres\ncuatro\n' >"$REPO/a.txt"; rm "$REPO/borrar.txt"; printf '\000\003\004\005\n' >"$REPO/img.bin"
printf 's1\ns2\n' >"$REPO/staged.txt"; g -C "$REPO" add staged.txt
printf 'hola\nmundo\n' >"$REPO/nuevo.txt"; echo x >"$REPO/con espacio ñ.txt"; printf '\000\001\002\n' >"$REPO/datos.bin"
seq 1 700 >"$REPO/largo.txt"; python3 -c 'print("a" * 3000)' >"$REPO/ancho.txt"; echo raro >"$REPO/--dry-run"
echo secreto >"$TMP/afuera.txt"; ln -s "$TMP/afuera.txt" "$REPO/enlace"; ln -s "$TMP" "$REPO/puente"
printf 'uno\ndos\ntres\nwt\n' >"$WT/a.txt"

tk create proj 7-implementer --role implementer --ref "#7" --repo "$REPO" --worktree "$WT" --window i7 >/dev/null
tk create proj pr9-reviewer --role reviewer --ref "#9" --pr 9 --repo "$REPO" --pending >/dev/null
tk create proj pr12-implementer --role implementer --ref "#5" --repo "$REPO" --window f12 >/dev/null
tk create proj pr3-reviewer --role reviewer --ref "#3" --pr 3 --repo "$REPO" --window pr3 >/dev/null
tk status "$TASKS/proj/pr3-reviewer" waiting
tk create proj 20-implementer --role implementer --ref "#20" --repo "$REPO" >/dev/null
tk cancel "$TASKS/proj/20-implementer" >/dev/null
tk create otro 20-implementer --role implementer --ref "#20" --repo "$TMP/otro" >/dev/null

# Herdr: el espacio proj con su chat (t1) y dos agentes (t2 i7, t3 pr9), una shell suelta (t4) y otros espacios
jq -n --arg repo "$REPO" --arg wt "$WT" --arg tmp "$TMP" --arg home "$HOME" '
  def term($sp; $tb; $cwd; $l): {labels: ({"herdr.space": $sp, "herdr.tab": $tb} + $l), cwd: $cwd, argv: []};
  {n: 4, tabs: 7, view: ["sp1", "tb1"],
   spaces: [
     {id: "sp1", name: "proj", folder: $repo, tabs: [{id: "tb1", name: "chat", terminals: ["t1"]},
        {id: "tb2", name: "i7", terminals: ["t2"]}, {id: "tb3", name: "pr9", terminals: ["t3"]}]},
     {id: "sp2", name: "chats", folder: ($home + "/.bk/chats"), tabs: [{id: "tb4", name: "1", terminals: ["t4"]}]},
     {id: "sp3", name: "sinsesiones", folder: ($tmp + "/sinsesiones"), tabs: [{id: "tb5", name: "1", terminals: []}]},
     {id: "sp4", name: "proj-rama", folder: $wt, tabs: [{id: "tb6", name: "chat", terminals: []}]}],
   terms: {
     t1: term("sp1"; "tb1"; $repo; {"bk.kind": "chat", "bk.win": "proj", "bk.project": "proj", "bk.name": "Idea",
                                    "bk.account": "trabajo", "bk.id": "1"}),
     t2: term("sp1"; "tb2"; $wt; {"bk.kind": "agent", "bk.win": "i7", "bk.project": "proj", "bk.role": "implementer",
                                  "bk.ref": "#7", "bk.id": "2"}),
     t3: term("sp1"; "tb3"; $repo; {"bk.kind": "agent", "bk.win": "pr9", "bk.project": "proj", "bk.role": "reviewer",
                                    "bk.ref": "#9"}),
     t4: term("sp2"; "tb4"; ($tmp + "/suelta"); {})}}' >"$HD_FAKE/state.json"
st() { jq "$@" "$HD_FAKE/state.json"; }
# estados <segundos de más en el ts del agente i7>: lo que anota el hook de cada sesión
estados() {
  local now; now=$(date +%s); mkdir -p "$STATE"
  echo "{\"pane\": \"t1\", \"state\": \"waiting\", \"wait\": \"permission\", \"ts\": $((now - 120)), \"cwd\": \"$REPO\", \"model\": \"claude-fable-5-2\"}" >"$STATE/sid-chat.json"
  echo "{\"pane\": \"t2\", \"state\": \"done\", \"ts\": $((now - 600 + ${1:-0})), \"cwd\": \"$WT\", \"role\": \"implementer\", \"model\": \"claude-sonnet-5-20260101\", \"ref\": \"#7\"}" >"$STATE/sid-i7.json"
  echo "{\"pane\": \"t3\", \"state\": \"working\", \"ts\": $((now - 60)), \"cwd\": \"$REPO\", \"role\": \"reviewer\", \"model\": \"claude-opus-5\"}" >"$STATE/sid-pr9.json"
}
estados
# una sesión que corría en una terminal que ya no está (t9), en un repo con cambios donde no hay ningún agente
echo "{\"pane\": \"t9\", \"state\": \"working\", \"ts\": 1, \"cwd\": \"$TMP/otro\"}" >"$STATE/muerta.json"; echo x >"$TMP/otro/suelto.txt"
mkdir -p "$HOME/.cache/bk"; echo '{"o/r#7": "Arreglar el login", "o/r#9": "PR de prueba"}' >"$HOME/.cache/bk/titles.json"
printf 'línea vieja\n⏺ ¿Publico el PR?\n' >"$HD_FAKE/screen-t2"

# ---------- temas que no existen ----------
err=$(hub 2>&1 >/dev/null); check_eq "$? $(lines "$err")" "2 1" "sin tema: sale con 2 y una línea"
out=$(hub nada 2>"$TMP/err"); check_eq "$? [$out] $(lines "$(cat "$TMP/err")") $(has "$(cat "$TMP/err")" "temas: issues | prs")" "2 [] 1 si" "tema desconocido: sale con 2, nada en stdout y una línea que nombra los temas"

# ---------- status: una llamada barata para la barra ----------
c0=$(calls)
S=$(hub status "$REPO")
check_eq "$(jq -c '[.project, .branch, .dirty, .account, .waiting, .pending, .working]' <<<"$S")" '["proj","main",12,"trabajo",1,1,3]' "status: proyecto, rama, sin commitear, cuenta del chat principal y las tareas de todos los proyectos por estado"
check_eq "$(jq -c '[.tokens_today, .cost_today, .song]' <<<"$S")" '[null,null,null]' "status: sin estado de uso y sin música, null"
check_eq "$(jq -c '[has("focus"), has("mode")]' <<<"$S")" '[false,false]' "status: sin el pomodoro ni el modo de Sketchybar, que ya no están"
espera 10 test -f "$HOME/.cache/barrilete/usage-$TODAY.json"; check_eq "$?" "0" "status sin estado de uso: lo pide en segundo plano"
check_eq "$(hub status "$WT" | jq -c '[.project, .branch, .dirty]')" '["proj","w7",1]' "status desde un worktree: el proyecto es el repo principal y la rama la del worktree"
check_eq "$(hub status "$TMP/otro" | jq -c '[.project, .branch, .dirty]') $(hub status "$TMP/proj-wt/limpio" | jq -c '[.project, .branch, .dirty]')" '["otro","main",1] ["proj","",0]' "status de un repo sin commits (su rama) y de un worktree con el HEAD suelto (sin rama)"
check_eq "$(hub status "$TMP/suelta" | jq -c '[.project, .branch, .dirty, .account]')" '["suelta","",0,null]' "status fuera de un repo: la carpeta, sin rama ni cuenta"
out=$(hub status "$TMP/no-existe"); check_eq "$? $(jq -c '[.project, .branch, .working]' <<<"$out")" '0 ["","",3]' "status de una carpeta que ya no existe: no rompe la barra"
check_eq "$(hub status "$TMP/suelta" --terminal t1 | jq -r .account) $(hub status "$REPO" --terminal t3 | jq -r .account) $(BK_ACCOUNT_CLAUDE=otra hub status "$TMP/suelta" | jq -r .account)" "trabajo null otra" "status: la cuenta de esa terminal (--terminal) o la del entorno"
# Un popup no tiene login propio: toma la cuenta elegida para el espacio.
mkdir -p "$XDG_STATE_HOME/bk/accounts/trabajo"
echo claude >"$XDG_STATE_HOME/bk/accounts/trabajo/proveedor"
echo '{"proj":{"claude":"trabajo"}}' >"$XDG_STATE_HOME/bk/accounts/.espacios.json"
st '.terms.t4.labels = {"bk.kind":"popup"}' >"$TMP/state-next.json"
cp "$TMP/state-next.json" "$HD_FAKE/state.json"
check_eq "$(hub status "$REPO" --terminal t4 | jq -r .account)" "trabajo" "status: un popup usa la cuenta del espacio, no la principal"
st '.terms.t4.labels = {}' >"$TMP/state-next.json"
cp "$TMP/state-next.json" "$HD_FAKE/state.json"
rm "$XDG_STATE_HOME/bk/accounts/.espacios.json"
st '.terms.t4.labels = {"bk.kind":"popup"}' >"$TMP/state-next.json"
cp "$TMP/state-next.json" "$HD_FAKE/state.json"
check_eq "$(hub status "$REPO" --terminal t4 | jq -c '[.account,.email]')" '[null,null]' "status: popup sin cuenta del espacio no inventa el login principal"
st '.terms.t4.labels = {} | .terms.t4.status = {"app":"codex"}' >"$TMP/state-next.json"
cp "$TMP/state-next.json" "$HD_FAKE/state.json"
check_eq "$(hub status "$REPO" --terminal t4 | jq -c '[.account,.email]')" '[null,null]' "status: Codex no muestra el login principal de Claude"
st 'del(.terms.t4.status)' >"$TMP/state-next.json"
cp "$TMP/state-next.json" "$HD_FAKE/state.json"
st '.terms.t4.labels = {}' >"$TMP/state-next.json"
cp "$TMP/state-next.json" "$HD_FAKE/state.json"
# El mail de la cuenta: del .claude.json de la de siempre (HOME) o de la carpeta de bk account; sin preguntarle a Claude
ACC="$XDG_STATE_HOME/bk/accounts"; mkdir -p "$ACC/trabajo" "$ACC/cdx"
echo claude >"$ACC/trabajo/proveedor"; echo codex >"$ACC/cdx/proveedor"
echo '{"oauthAccount": {"emailAddress": "trabajo@ejemplo.com"}}' >"$ACC/trabajo/.claude.json"
echo '{"oauthAccount": {"emailAddress": "yo@ejemplo.com"}, "projects": {}}' >"$HOME/.claude.json"
echo '{"oauthAccount": {"emailAddress": "no-va@ejemplo.com"}}' >"$ACC/cdx/.claude.json"
check_eq "$(hub status "$REPO" | jq -r .email) $(hub status "$TMP/suelta" | jq -r .email) $(BK_ACCOUNT_CLAUDE=cdx hub status "$TMP/suelta" | jq -r .email) $(BK_ACCOUNT_CLAUDE=nadie hub status "$TMP/suelta" | jq -r .email)" \
  "trabajo@ejemplo.com yo@ejemplo.com null null" "status: el mail de la cuenta (la nombrada, la de siempre); una de Codex o que no existe, null"
side() { python3 "$ROOT/lib/herdr_side.py" "$@" | jq -r .email; }
check_eq "$(side "$TMP/suelta" --account trabajo) $(side "$TMP/suelta") $(side "$TMP/suelta" --account default) $(side "$TMP/suelta" --account cdx)" \
  "trabajo@ejemplo.com yo@ejemplo.com yo@ejemplo.com null" "bk _side --account: el mail de la cuenta de la terminal; sin ella o default, la de siempre"
echo '{"oauthAccount": ' >"$HOME/.claude.json"; a=$(side "$TMP/suelta")
echo '{"oauthAccount": {"emailAddress": "sin-arroba"}}' >"$HOME/.claude.json"; b=$(side "$TMP/suelta")
echo '{"oauthAccount": "x"}' >"$HOME/.claude.json"; c=$(side "$TMP/suelta")
echo '[1]' >"$HOME/.claude.json"; d=$(side "$TMP/suelta")
rm -f "$HOME/.claude.json"; e=$(side "$TMP/suelta")
check_eq "$a $b $c $d $e" "null null null null null" "el mail: un .claude.json roto, sin arroba, con otra forma o que no está, null sin romper"
m=$(python3 "$ROOT/lib/accounts.py" email trabajo); r1=$?; python3 "$ROOT/lib/accounts.py" email >/dev/null 2>&1; r2=$?
check_eq "$m $r1 $r2" \
  "trabajo@ejemplo.com 0 1" "accounts.py email: el mail, o sale con 1 si no hay"
rm -rf "$ACC/trabajo" "$ACC/cdx"
U="$HOME/.cache/barrilete/usage-$TODAY.json"
echo '{"offsets": {}, "msgs": {"x1": ["claude-sonnet-5", "proj", 1000000, 100000, 0, 0, 5000000]}}' >"$U"
check_eq "$(hub status "$REPO" | jq -c '[.tokens_today, (.cost_today * 100 | round)]')" '[1100000,400]' "status: tokens y costo de hoy del estado que deja usage.py"
viejo "$U" 120; check_eq "$(hub status "$REPO" | jq -c '.tokens_today')" '1100000' "status con el estado de uso viejo: contesta con lo que hay"
espera 10 reciente "$U"; check_eq "$?" "0" "status con el estado de uso viejo: lo renueva en segundo plano"
check_eq "$(calls)" "$c0" "status: no consulta a GitHub"
rm -f "$HOME/.cache/barrilete"/usage-*.json

# ---------- issues ----------
cat >"$TMP/gh-issues.json" <<'EOF'
[{"number":5,"title":"Cinco","labels":[],"updatedAt":"2026-11-01T10:00:00Z","url":"https://github.com/o/r/issues/5","assignees":[]},
 {"number":20,"title":"Veinte","labels":[{"name":"type:bug"},{"name":"area:infra"}],"updatedAt":"2026-11-10T16:58:46Z","url":"https://github.com/o/r/issues/20","assignees":[{"login":"ana"},{"login":"beto"}]},
 {"number":7,"title":"Siete","labels":[],"updatedAt":"2026-11-02T10:00:00Z","url":"https://github.com/o/r/issues/7","assignees":[]},
 {"number":3,"title":"Tres","labels":[],"updatedAt":"2026-11-03T10:00:00Z","url":"https://github.com/o/r/issues/3","assignees":[]}]
EOF
cat >"$TMP/gh-links.json" <<'EOF'
[{"number":9,"headRefName":"otra-rama","closingIssuesReferences":[{"number":7,"repository":{"name":"r","owner":{"login":"o"}}},{"number":3,"repository":{"name":"x","owner":{"login":"o"}}}]},
 {"number":12,"headRefName":"claude/5-arreglo","closingIssuesReferences":[]}]
EOF
I=$(hub issues "$REPO")
check_eq "$(jq -c '[.project, .repo, .stale, (.items | map(.n))]' <<<"$I")" '["proj","o/r",false,[20,7,5,3]]' "issues: proyecto, repo y los abiertos, el más nuevo primero"
check_eq "$(jq -c '.items[0] | [.title, .labels, .assignees, .updated, .url]' <<<"$I")" '["Veinte",["type:bug","area:infra"],["ana","beto"],"2026-11-10T16:58:46Z","https://github.com/o/r/issues/20"]' "issues: título, etiquetas, asignados, fecha y url"
check_eq "$(jq -c '.items | map(.task | if . then [.id, .status, .window] else null end)' <<<"$I")" '[null,["7-implementer","in_progress","i7"],["pr12-implementer","in_progress","f12"],null]' "issues: la tarea activa de cada uno (no la cancelada, ni la de otro proyecto, ni un reviewer)"
check_eq "$(jq -c '.items | map(.pr)' <<<"$I")" '[null,9,12,null]' "issues: el PR que lo cierra (lo que dice GitHub de este repo, o la rama claude/<issue>-…)"
n=$(calls); check_eq "$(hub issues "$WT" | jq -c '[.project, (.items | length)]') $(calls)" "[\"proj\",4] $n" "issues desde el worktree: el mismo proyecto, y sale de la caché sin volver a pedir"
hub issues "$REPO" --fresh >/dev/null; check_eq "$(( $(calls) - n ))" "2" "issues --fresh: vuelve a pedir (issues y PRs)"
old() { jq '.ts = 0' "$HUBC/$1" >"$TMP/c.json" && mv "$TMP/c.json" "$HUBC/$1"; }   # esa caché, vencida
old issues-o_r.json; old links-o_r.json; : >"$TMP/sin-red"
out=$(hub issues "$REPO" 2>"$TMP/err"); check_eq "$? $(jq -c '[.stale, (.items | length), .items[1].pr]' <<<"$out")" '0 [true,4,9]' "issues con la caché vencida y sin red: lo guardado, marcado stale"
rm -f "$HUBC"/issues-* "$HUBC"/links-*
out=$(hub issues "$REPO" 2>"$TMP/err"); check_eq "$? [$out] $(lines "$(cat "$TMP/err")") $(has "$(cat "$TMP/err")" "error connecting")" "1 [] 1 si" "issues sin caché y sin red: sale con 1 y una línea con lo que dijo gh"
rm -f "$TMP/sin-red"; : >"$TMP/sin-links"
check_eq "$(hub issues "$REPO" | jq -c '[.stale, (.items | map(.pr))]')" '[false,[null,null,null,null]]' "issues si no se pueden pedir los PRs: salen igual, sin PR"
rm -f "$TMP/sin-links"; old issues-o_r.json
jq '. + [{"number":21,"title":"Nuevo","labels":[],"updatedAt":"","url":"","assignees":[]}]' "$TMP/gh-issues.json" >"$TMP/c.json" && mv "$TMP/c.json" "$TMP/gh-issues.json"
check_eq "$(hub issues "$REPO" | jq -c '[.stale, .items[0].n]')" '[false,21]' "issues con la caché vencida y con red: trae lo nuevo"
out=$(hub issues "$TMP/suelta" 2>"$TMP/err"); check_eq "$? [$out] $(has "$(cat "$TMP/err")" "no tiene un remoto de GitHub")" "1 [] si" "issues fuera de un repo de GitHub: sale con 1 y lo dice"
g init -q -b main "$TMP/resp"; g -C "$TMP/resp" remote add respaldo "https://github.com/o/r.git"
check_eq "$(hub issues "$TMP/resp" 2>/dev/null | jq -c '[.project, .repo]')" '["resp","o/r"]' "issues sin origin: usa el único remoto de GitHub (el workspace tiene solo respaldo)"

# ---------- prs ----------
cat >"$TMP/gh-prs.json" <<'EOF'
[{"number":9,"title":"Nueve","headRefName":"otra-rama","isDraft":false,"author":{"login":"ana"},"updatedAt":"2026-11-10T17:09:38Z","url":"https://github.com/o/r/pull/9","reviewDecision":"APPROVED",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},{"__typename":"StatusContext","state":"SUCCESS"}]},
 {"number":12,"title":"Doce","headRefName":"claude/5-arreglo","isDraft":true,"author":{"login":"bot"},"updatedAt":"","url":"","reviewDecision":"CHANGES_REQUESTED",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""}]},
 {"number":13,"title":"Trece","headRefName":"r13","isDraft":false,"author":{"login":"ana"},"updatedAt":"","url":"","reviewDecision":"REVIEW_REQUIRED",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"QUEUED","conclusion":""}]},
 {"number":14,"title":"Catorce","headRefName":"r14","isDraft":false,"author":null,"updatedAt":"","url":"","reviewDecision":"","statusCheckRollup":[]},
 {"number":15,"title":"Quince","headRefName":"r15","isDraft":false,"author":{"login":"ana"},"updatedAt":"","url":"","reviewDecision":null,
  "statusCheckRollup":[{"__typename":"StatusContext","state":"PENDING"}]}]
EOF
P=$(hub prs "$REPO")
check_eq "$(jq -c '[.project, .repo, .stale, (.items | map(.n))]' <<<"$P")" '["proj","o/r",false,[15,14,13,12,9]]' "prs: proyecto, repo y los abiertos, el más nuevo primero"
check_eq "$(jq -c '.items[-1] | [.title, .branch, .draft, .author, .updated, .url]' <<<"$P")" '["Nueve","otra-rama",false,"ana","2026-11-10T17:09:38Z","https://github.com/o/r/pull/9"]' "prs: título, rama, borrador, autor, fecha y url"
check_eq "$(jq -c '.items | map(.review)' <<<"$P")" '["none","none","required","changes","approved"]' "prs: la decisión de review"
check_eq "$(jq -c '.items | map(.ci)' <<<"$P")" '["pending","none","pending","fail","ok"]' "prs: el CI (uno fallido manda; uno sin terminar; todos bien; sin checks)"
check_eq "$(jq -c '.items | map(.task | if . then [.id, .status, .window] else null end)' <<<"$P")" '[null,null,null,["pr12-implementer","in_progress","f12"],["pr9-reviewer","pending",null]]' "prs: la tarea de cada PR (el reviewer propuesto que lanza bk approve, el implementer de bk fix)"
check_eq "$(jq -c '[.items[3].draft, .items[1].author]' <<<"$P")" '[true,""]' "prs: un borrador, y uno sin autor"
n=$(calls); hub prs "$REPO" >/dev/null; check_eq "$(calls)" "$n" "prs: la segunda vez sale de la caché"
old prs-o_r.json; : >"$TMP/sin-red"
out=$(hub prs "$REPO"); check_eq "$? $(jq -c '[.stale, (.items | length)]' <<<"$out")" '0 [true,5]' "prs con la caché vencida y sin red: lo guardado, marcado stale"
rm -f "$HUBC"/prs-*
out=$(hub prs "$REPO" 2>"$TMP/err"); check_eq "$? [$out] $(lines "$(cat "$TMP/err")")" "1 [] 1" "prs sin caché y sin red: sale con 1 y una línea"
rm -f "$TMP/sin-red"

# ---------- agents ----------
estados
A=$(hub agents)
check_eq "$(jq -c '.items | map([.win, .kind, .project, .role, .ref, .title, .state, .waiting, .since_min, .terminal])' <<<"$A")" '[["i7","agent","proj","implementer","#7","Arreglar el login","done",true,10,"t2"],["pr9","agent","proj","reviewer","#9","PR de prueba","working",false,1,"t3"],["proj","chat","proj","chat","","Idea","waiting",true,2,"t1"]]' "agents: agentes y chats en el orden de bk ls (el que te espera primero), con sus etiquetas, título, estado y terminal"
check_eq "$(jq -c '.items | map([.model, .name, .account, .id])' <<<"$A")" '[["sonnet-5","",null,2],["opus-5","",null,null],["fable-5-2","Idea","trabajo",1]]' "agents: modelo, nombre del chat, cuenta y número fijo de ventana"
check_eq "$(jq -c '[.items[0].label, .items[0].why, .items[0].question, .items[2].why]' <<<"$A")" '["#7 Arreglar el login","te pregunta","¿Publico el PR?","pide permiso"]' "agents: el título como en bk ls y por qué te espera cada uno"
check_eq "$(jq -r '.items | map(.win) | join(" ")' <<<"$A")" "$(bk ls | grep -v '^◆' | sed -nE 's/^[^ ]+ +([^ ]+) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')" "agents: el mismo orden que bk ls"
printf '⏺ ¿Otra cosa?\n' >"$HD_FAKE/screen-t2"
check_eq "$(hub agents | jq -r '.items[0].question')" "¿Publico el PR?" "agents: sin un evento nuevo de la sesión no vuelve a leer su pantalla"
estados 1
check_eq "$(hub agents | jq -r '.items[0].question')" "¿Otra cosa?" "agents: con un evento nuevo, la lee otra vez"
: >"$TMP/gh.log"
jq --arg repo "$REPO" '.terms.t5 = {labels: {"bk.kind": "agent", "bk.win": "i8", "bk.project": "proj"}, cwd: $repo, argv: []}' "$HD_FAKE/state.json" >"$TMP/c.json" && mv "$TMP/c.json" "$HD_FAKE/state.json"
check_eq "$(hub agents | jq -c '.items | map(select(.win == "i8") | [.title, .state, .role, .ref])')" '[["","","",""]]' "agents: uno sin título guardado ni estado sale igual, sin esperar a GitHub"
espera 10 grep -q 'api repos/o/r/issues/8' "$TMP/gh.log"; check_eq "$?" "0" "agents: el título que falta se pide en segundo plano"
espera 10 grep -q 'o/r#8' "$HOME/.cache/bk/titles.json"
check_eq "$(hub agents | jq -r '.items[] | select(.win == "i8") | .title')" "Título de 8" "agents: la corrida siguiente ya lo tiene"
out=$(BK_HC="$TMP/hc-roto" hub agents); check_eq "$? $out" '0 {"items": []}' "agents si Herdr no responde: una lista vacía"
jq 'del(.terms.t5)' "$HD_FAKE/state.json" >"$TMP/c.json" && mv "$TMP/c.json" "$HD_FAKE/state.json"

# ---------- changes y diff ----------
C=$(hub changes "$TMP/suelta")
check_eq "$(jq -c '.roots | map([.name, .path, .branch, (.files | length)])' <<<"$C")" "[[\"7\",\"$WT\",\"w7\",1],[\"proj\",\"$REPO\",\"main\",12]]" "changes desde otra carpeta: donde trabaja cada agente vivo (no la carpeta de una sesión que no es un agente)"
C=$(hub changes "$REPO")
check_eq "$(jq -c '.roots | map(.name + "@" + .branch + ":" + (.files | length | tostring))' <<<"$C")" '["proj@main:12","7@w7:1"]' "changes: el repo de la carpeta y el worktree de cada agente vivo, una vez cada uno"
f() { jq -c --arg p "$1" '.roots[0].files[] | select(.path == $p) | [.code, .add, .del]' <<<"$C"; }
check_eq "$(f a.txt) $(f borrar.txt) $(f staged.txt)" '["M",2,1] ["D",0,1] ["A",2,0]' "changes: modificado, borrado y agregado, con sus líneas"
check_eq "$(f nuevo.txt) $(f "con espacio ñ.txt") $(f img.bin) $(f datos.bin)" '["A",2,null] ["A",1,null] ["M",null,null] ["A",null,null]' "changes: los nuevos con sus líneas (un nombre con espacio y ñ llega entero) y los binarios sin número"
check_eq "$(jq -c '.roots[1].files' <<<"$C")" '[{"code":"M","path":"a.txt","add":1,"del":0}]' "changes: los archivos del worktree del agente"
check_eq "$(BK_HC="$TMP/hc-roto" hub changes "$TMP/suelta")" '{"roots": []}' "changes fuera de un repo y sin agentes: nada"
sum='.roots | map(.name + "@" + .branch + ":" + (.files | length | tostring))'
check_eq "$(BK_HC="$TMP/hc-roto" hub changes "$REPO" | jq -c "$sum") $(BK_HC="$TMP/hc-roto" hub changes "$WT" | jq -c "$sum")" '["proj@main:12","7@w7:1"] ["7@w7:1","proj@main:12"]' "changes sin agentes: la carpeta primero y los demás worktrees de su proyecto que tienen algo (el limpio no sale)"
check_eq "$(BK_HC="$TMP/hc-roto" hub changes "$REPO" | jq -c '.roots | map(.path) | sort')" "$(bk _side "$REPO" | jq -c '.changes | map(.path) | sort')" "changes: las mismas carpetas que el panel derecho (bk _side)"
d() { hub diff "$REPO" "$1" | jq -c '[(.lines | map([.t, .s])), .truncated]'; }
check_eq "$(d a.txt)" '[[["@","@@ -1,3 +1,4 @@"],[" ","uno"],["-","dos"],["+","DOS"],[" ","tres"],["+","cuatro"]],false]' "diff de un archivo modificado: el bloque, contexto, quitadas y agregadas, sin el encabezado de git"
check_eq "$(d nuevo.txt)" '[[["@","@@ -0,0 +1,2 @@"],["+","hola"],["+","mundo"]],false]' "diff de un archivo nuevo: entero, como agregado"
check_eq "$(d "$(jq -r '.roots[0].files[] | select(.path | startswith("con")) | .path' <<<"$C")")" '[[["@","@@ -0,0 +1,1 @@"],["+","x"]],false]' "diff con el nombre que dio changes (con espacio y ñ)"
check_eq "$(d staged.txt)" '[[["@","@@ -0,0 +1,2 @@"],["+","s1"],["+","s2"]],false]' "diff de un archivo nuevo ya agregado al índice: sin restos del encabezado"
check_eq "$(d borrar.txt)" '[[["@","@@ -1 +0,0 @@"],["-","x"]],false]' "diff de un archivo borrado"
check_eq "$(d igual.txt)" '[[["h","(sin cambios contra HEAD)"]],false]' "diff de un archivo sin cambios: lo dice"
check_eq "$(d datos.bin) $(d img.bin)" '[[["h","(binario, 4 bytes)"]],false] [[["h","(binario: sin diff de texto)"]],false]' "diff de un binario, nuevo o modificado: una línea que lo dice"
check_eq "$(hub diff "$REPO" largo.txt | jq -c '[(.lines | length), .truncated, .lines[0].s, .lines[-1].s]')" '[600,true,"@@ -0,0 +1,700 @@","599"]' "diff de más de 600 líneas: las primeras 600 y truncated"
check_eq "$(hub diff "$REPO" ancho.txt | jq -c '[(.lines[1].s | length), (.lines[1].s | endswith("…")), .truncated]')" '[2001,true,false]' "diff: una línea larguísima se corta en 2000 caracteres"
check_eq "$(d enlace)" "[[[\"h\",\"(enlace simbólico → $TMP/afuera.txt)\"]],false]" "diff de un enlace hacia afuera: dice adónde apunta, no lo lee"
check_eq "$(d --dry-run)" '[[["@","@@ -0,0 +1,1 @@"],["+","raro"]],false]' "diff de un archivo que se llama --dry-run: bk no se queda con el argumento"
for bad in ../afuera.txt "$TMP/afuera.txt" puente/afuera.txt no-existe.txt scripts; do
  out=$(hub diff "$REPO" "$bad" 2>"$TMP/err"); check_eq "$? [$out] $(lines "$(cat "$TMP/err")")" "1 [] 1" "diff de ${bad#"$TMP"} (fuera de la raíz, por un enlace hacia afuera, inexistente o una carpeta): sale con 1 y una línea"
done
out=$(hub diff "$TMP/suelta" a.txt 2>"$TMP/err"); check_eq "$? $(has "$(cat "$TMP/err")" "no es un repo de git")" "1 si" "diff en una raíz que no es un repo: sale con 1"
out=$(hub diff "$REPO" 2>"$TMP/err"); check_eq "$? $(has "$(cat "$TMP/err")" "uso: bk _hub diff")" "1 si" "diff sin archivo: sale con 1 y dice cómo se usa"

# ---------- sessions ----------
# transcript <carpeta> <sid> <cwd> <primer mensaje> [minutos de antigüedad]
transcript() {
  mkdir -p "$PROJ/$1"
  printf '{"type":"user","cwd":"%s","message":{"content":"%s"}}\n' "$3" "$4" >"$PROJ/$1/$2.jsonl"
  [ -z "${5:-}" ] || viejo "$PROJ/$1/$2.jsonl" "$5"
}
transcript p1 sid-chat "$REPO" "hola"; echo '{"type":"custom-title","customTitle":"Charla"}' >>"$PROJ/p1/sid-chat.jsonl"
transcript p1 sid-i7 "$WT" "arreglá el login" 1
transcript p1 vieja "$REPO" "una sesión cerrada" 30
transcript p2 muerta "$TMP/otro" "se cerró su terminal" 5
transcript p2 tmuxera "$REPO" "vive en tmux" 7
for i in $(seq 1 45); do transcript p3 "relleno$i" "$REPO" "relleno $i" $((100 + i)); done
echo "{\"pane\": \"%5\", \"state\": \"idle\", \"ts\": 1, \"cwd\": \"$REPO\"}" >"$STATE/tmuxera.json"
mkdir -p "$BK_HANDOFF_DIR"
echo "{\"sid\": \"vieja\", \"session\": \"proj-2\", \"name\": \"Sigo\", \"cwd\": \"$REPO\", \"account\": \"trabajo\"}" >"$BK_HANDOFF_DIR/vieja.json"
echo "# resumen" >"$BK_HANDOFF_DIR/vieja.md"; viejo "$BK_HANDOFF_DIR/vieja.md" 15
X=$(hub sessions)
check_eq "$(jq -c '.open | map(.sid) | sort' <<<"$X")" '["sid-chat","sid-i7","sid-pr9","tmuxera"]' "sessions: las abiertas (la que corría en una terminal que ya no está, no)"
o() { jq -c --arg s "$1" '.open[] | select(.sid == $s) | [.project, .title, .state, .terminal, .cwd, .where, .handoff]' <<<"$X"; }
check_eq "$(o sid-chat)" "[\"proj\",\"Charla\",\"waiting\",\"t1\",\"$REPO\",\"t1\",false]" "sessions: una abierta con su proyecto, título, estado, terminal y carpeta"
check_eq "$(o sid-i7) $(o sid-pr9)" "[\"proj#7\",\"arreglá el login\",\"done\",\"t2\",\"$WT\",\"t2\",false] [\"proj\",\"(recién abierta)\",\"working\",\"t3\",\"$REPO\",\"t3\",false]" "sessions: la de un worktree, y una recién abierta que todavía no tiene transcript"
check_eq "$(o tmuxera | jq -c '.[3]')" 'null' "sessions: una abierta fuera de Herdr no tiene terminal"
r() { jq -c --arg s "$1" '.recent[] | select(.sid == $s) | [.project, .title, .cwd, .age_min, .account, .handoff]' <<<"$X"; }
check_eq "$(r vieja)" "[\"proj\",\"una sesión cerrada\",\"$REPO\",30,\"trabajo\",true]" "sessions: una reciente con su antigüedad; dejó un resumen, así que se sabe su cuenta"
check_eq "$(r muerta)" "[\"otro\",\"se cerró su terminal\",\"$TMP/otro\",5,null,false]" "sessions: la que corría en una terminal cerrada pasa a recientes"
check_eq "$(jq -c '[(.recent | length), .recent[0].sid, .recent[1].sid, .recent[-1].sid]' <<<"$X")" '[40,"muerta","vieja","relleno38"]' "sessions: hasta 40 recientes, la más nueva primero"
check_eq "$([ -f "$STATE/muerta.json" ] && echo queda || echo borrado)" "queda" "sessions: solo mira, no borra el estado de la sesión muerta (eso lo hace bk s)"

: >"$HD_FAKE/log"
out=$(hub session-go sid-chat); check_eq "$? $out" '0 {"ok": true, "did": "show"}' "session-go de una abierta: show"
check_eq "$(grep -c -e 'space.select {"id": "sp1"}' -e 'tab.select {"id": "tb1"}' -e 'pane.focus {"terminal": "t1"}' "$HD_FAKE/log") $(grep -c 'tab.new' "$HD_FAKE/log")" "3 0" "session-go de una abierta: muestra su espacio, su pestaña y su terminal, sin abrir nada"
: >"$HD_FAKE/log"; n0=$(st '.terms | length')
out=$(hub session-go vieja); check_eq "$? $out" '0 {"ok": true, "did": "resume"}' "session-go de una reciente: resume"
last=$(st -r '.terms | to_entries | last | .value | (.argv | join(" ")) + " | " + .labels["bk.kind"] + " " + .labels["bk.project"]')
check_eq "$(( $(st '.terms | length') - n0 )) $(has "$last" "claude --resume vieja | chat proj") $(has "$last" "cd $REPO &&")" "1 si si" "session-go de una reciente: un chat más de su proyecto que la retoma en su carpeta"
for bad in no-existe tmuxera; do
  n0=$(grep -c . "$HD_FAKE/log"); out=$(hub session-go "$bad" 2>"$TMP/err")
  check_eq "$? [$out] $(lines "$(cat "$TMP/err")") $(( $(grep -c . "$HD_FAKE/log") - n0 ))" "1 [] 1 0" "session-go $bad (no existe, o vive fuera de Herdr): sale con 1, una línea y no toca Herdr"
done
: >"$HD_FAKE/closed"; out=$(hub session-go sid-chat 2>"$TMP/err"); rc=$?; rm -f "$HD_FAKE/closed"
check_eq "$rc [$out] $(has "$(cat "$TMP/err")" "Herdr no mostró")" "1 [] si" "session-go con Herdr cerrado: sale con 1 y lo dice"
out=$(hub session-go 2>"$TMP/err"); check_eq "$? $(has "$(cat "$TMP/err")" "uso: bk _hub session-go")" "1 si" "session-go sin sesión: dice cómo se usa"
: >"$HD_FAKE/log"
check_eq "$(bk --dry-run _hub session-go vieja) $(hub session-go sid-chat --dry-run) $(grep -c . "$HD_FAKE/log")" '{"ok": true, "did": "resume", "dry": true} {"ok": true, "did": "show", "dry": true} 0' "session-go con --dry-run (el de bk o el suyo): dice qué haría y no toca Herdr"

# ---------- projects ----------
check_eq "$(hub projects | jq -c '.items | map([.name, .path, .open])')" "[[\"proj\",\"$REPO\",true],[\"sinsesiones\",\"$TMP/sinsesiones\",true],[\"otro\",\"$TMP/otro\",false]]" "projects: los de los espacios de Herdr primero (una vez cada uno; el de chats sueltos no es un proyecto) y los de tus sesiones recientes"
g init -q -b main "$TMP/tercero"; transcript p4 t3ro "$TMP/tercero" "otro proyecto"
check_eq "$(hub projects | jq -c '.items | map(.name)')" '["proj","sinsesiones","otro"]' "projects: las carpetas recientes se guardan un minuto"
check_eq "$(hub projects --fresh | jq -c '.items | map([.name, .open])')" '[["proj",true],["sinsesiones",true],["tercero",false],["otro",false]]' "projects --fresh: las vuelve a buscar"
: >"$HD_FAKE/closed"; out=$(hub projects); rc=$?; rm -f "$HD_FAKE/closed"
check_eq "$rc $(jq -c '.items | map([.name, .open])' <<<"$out")" '0 [["tercero",false],["proj",false],["otro",false]]' "projects con Herdr cerrado: las recientes, ninguna abierta"

# ---------- handoffs ----------
echo "{\"sid\": \"otra\", \"cwd\": \"$TMP/otro\", \"account\": \"default\"}" >"$BK_HANDOFF_DIR/otra.json"
echo "# otro resumen" >"$BK_HANDOFF_DIR/otra.md"; viejo "$BK_HANDOFF_DIR/otra.md" 5
echo '{"sid": "sinmd"}' >"$BK_HANDOFF_DIR/sinmd.json"; echo '{"sid": "vacia"}' >"$BK_HANDOFF_DIR/vacia.json"; : >"$BK_HANDOFF_DIR/vacia.md"
check_eq "$(hub handoffs | jq -c '.items | map([.sid, .name, .project, .age_min, .session, .account])')" '[["otra","","otro",5,"",null],["vieja","Sigo","proj",15,"proj-2","trabajo"]]' "handoffs: los resúmenes listos, el más nuevo primero (uno sin escribir o vacío no cuenta)"
check_eq "$(hub handoffs | jq -r '.items | map(.sid) | join(" ")')" "$(bk handoff --listos | cut -f1 | tr '\n' ' ' | sed 's/ $//')" "handoffs: los mismos que bk handoff --listos"
check_eq "$(BK_HANDOFF_DIR="$TMP/no-hay" hub handoffs)" '{"items": []}' "handoffs sin ninguno: una lista vacía"

# ---------- checkpoints ----------
echo "[{\"kind\": \"review\", \"repo\": \"o/r\", \"number\": 9, \"title\": \"Nueve\", \"url\": \"u\", \"updated\": \"${TODAY}T00:00:00Z\"}]" >"$BK_PRS_CACHE"
mkdir -p "$BARRILETE_VAULT/agents/lessons"; printf -- '---\nstatus: proposed\nscope: global\n---\n# Una lección\n' >"$BARRILETE_VAULT/agents/lessons/l1.md"
K=$(hub checkpoints)
check_eq "$(jq -c '.items | map([.kind, .what])' <<<"$K")" '[["reviewer","reviewer propuesto"],["review","te pidieron una review"],["lesson","lección propuesta"]]' "checkpoints: lo que te espera, envuelto en items"
check_eq "$(jq -c '.items' <<<"$K")" "$(bk checkpoints --json | jq -c .)" "checkpoints: el mismo JSON que bk checkpoints --json"
check_eq "$(BK_PRS_CACHE="$TMP/no-hay.json" BARRILETE_VAULT="$TMP/no-hay" hub checkpoints | jq -c '.items | map(.kind)')" '["reviewer"]' "checkpoints si falta una fuente: las demás salen igual"

# ---------- palette ----------
L=$(hub palette)
check_eq "$(jq -c '.items' <<<"$L")" "$(python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import palette as P
print(json.dumps([dict(zip(("group", "label", "cmd", "arg", "kind"), e)) for e in P.ENTRIES], ensure_ascii=False, separators=(",", ":")))' "$ROOT/lib")" "palette: las ENTRIES de lib/palette.py, en su orden"
check_eq "$(jq -c '[.items[0], (.items | map(.kind) | unique), (.items | map(select(.arg == null)) | length > 0)]' <<<"$L")" '[{"group":"Agentes","label":"Implementar un issue","cmd":"run","arg":"issue","kind":"run"},["run","show","view"],true]' "palette: grupo, etiqueta, comando, argumento pedido (o null) y tipo"

# ---------- song ----------
mkdir -p "$HOME/.config/bk"; echo 'mia|cumbia-villera|La Mía|http://ejemplo.invalid/radio' >"$HOME/.config/bk/song-stations"
check_eq "$(hubs song)" '{"playing": false, "paused": false, "station": null, "title": null, "genre": null, "genres": ["cumbia-villera", "techno", "house", "rock", "reggaeton", "cachengue"]}' "song sin música: nada suena, y los géneros de bk song con los tuyos"
printf 'rockpop\tRock & Pop 95.9\trock\n' >"$TMP/s/song.station"; : >"$TMP/s/song.sock"
check_eq "$(hubs song | jq -c '[.playing, .station]') $(ls "$TMP/s" | tr '\n' ' ')" '[false,null] song.sock song.station ' "song con un socket viejo (mpv murió solo): nada suena, y no borra nada"
rm -f "$TMP/s/song.sock"
cat >"$TMP/mpv.py" <<'PY'
import json, os, socket, sys
path, conf = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(5)
while True:
    c, _ = s.accept()
    c.sendall(b'{"event":"idle"}\n')   # mpv también manda eventos por el mismo socket
    for line in c.makefile("rb"):
        req = json.loads(line)
        props = json.load(open(conf))
        name = req["command"][1]
        ans = {"data": props[name], "error": "success"} if name in props else {"error": "property unavailable"}
        c.sendall((json.dumps({**ans, "request_id": req.get("request_id")}) + "\n").encode())
    c.close()
PY
echo '{"pause": false, "metadata": {"icy-title": "Soda Stereo - De música ligera"}, "media-title": "stream"}' >"$TMP/mpv.json"
(cd "$TMP" && exec python3 mpv.py s/song.sock mpv.json) & MPV_PID=$!
espera 10 test -S "$TMP/s/song.sock"
check_eq "$(hubs song | jq -c '[.playing, .paused, .station, .title, .genre]')" '[true,false,"Rock & Pop 95.9","Soda Stereo - De música ligera","rock"]' "song sonando: la estación, su género y el tema de la radio"
check_eq "$(hubs status "$REPO" | jq -c .song)" '{"playing":true,"station":"Rock & Pop 95.9","title":"Soda Stereo - De música ligera"}' "status: lo que suena"
echo '{"pause": true, "metadata": {}, "media-title": "http://ejemplo.invalid/stream.mp3"}' >"$TMP/mpv.json"
check_eq "$(hubs song | jq -c '[.playing, .paused, .station, .title]')" '[false,true,"Rock & Pop 95.9",null]' "song en pausa; sin tema de la radio, la url de mpv no es un tema"
echo '{"pause": false, "media-title": "Un tema de YouTube"}' >"$TMP/mpv.json"
check_eq "$(hubs song | jq -r .title)" "Un tema de YouTube" "song: sin tema de la radio, el título de mpv"
kill "$MPV_PID" 2>/dev/null; wait "$MPV_PID" 2>/dev/null; MPV_PID=""; rm -f "$TMP/s/song.sock" "$TMP/s/song.station"

# ---------- stats ----------
# uso <carpeta> <sid> <id del mensaje> <modelo> <cwd> <días atrás> <in> <out> <caché leído>: una respuesta de Claude
uso() {
  mkdir -p "$PROJ/$1"
  python3 - "$PROJ/$1/$2.jsonl" "$3" "$4" "$5" "$6" "$7" "$8" "$9" <<'PY'
import json, sys, time
from datetime import datetime, timezone
path, mid, model, cwd, days, i, o, cr = sys.argv[1:]
ts = datetime.fromtimestamp(time.time() - 86400 * int(days), timezone.utc).isoformat().replace("+00:00", "Z")
with open(path, "a") as f:
    f.write(json.dumps({"type": "assistant", "timestamp": ts, "cwd": cwd, "message": {"id": mid, "model": model, "usage": {
        "input_tokens": int(i), "output_tokens": int(o), "cache_read_input_tokens": int(cr)}}}, separators=(",", ":")) + "\n")
PY
}
uso u1 hoy m1 claude-sonnet-5 "$REPO/herdr/mods" 0 1000000 100000 5000000   # desde una subcarpeta: cuenta como proj
uso u1 hoy m2 claude-haiku-5-5 "$WT/lib" 0 2000000 1000000 0
uso u1 ayer m3 claude-sonnet-5 "$REPO" 1 500000 0 0
uso u1 antes m4 claude-sonnet-5 "$REPO" 3 250000 0 0
T=$(hub stats); cents='(.cost * 100 | round)'
check_eq "$(jq -c "[.today.tokens, (.today | $cents), .today.cache_read]" <<<"$T")" '[4100000,470,5000000]' "stats: hoy, como bk tokens (tokens sin las lecturas de caché, que van aparte)"
check_eq "$(jq -c ".today.by_model | map([.model, .name, .tokens, $cents])" <<<"$T")" '[["claude-sonnet-5","sonnet 5",1100000,400],["claude-haiku-5-5","haiku 5.5",3000000,70]]' "stats: hoy por modelo, el más caro primero"
check_eq "$(jq -c ".today.by_project | map([.project, .tokens, $cents])" <<<"$T")" '[["proj",1100000,400],["proj#7",3000000,70]]' "stats: hoy por proyecto (un chat en una subcarpeta cuenta para su repo o worktree)"
check_eq "$(jq -c "[(.days | length), .days[-1].date, (.days[-4:] | map([.tokens, $cents]))]" <<<"$T")" "[30,\"$TODAY\",[[250000,50],[0,0],[500000,100],[9100000,470]]]" "stats: los últimos 30 días hasta hoy, con ceros donde no hubo uso (como bk stats: con las lecturas de caché)"
check_eq "$(jq -c "[.streak, .total.tokens, (.total | $cents), .total.sessions]" <<<"$T")" '[2,9850000,620,3]' "stats: racha de días seguidos y totales"
uso u1 hoy m5 claude-sonnet-5 "$REPO" 0 1000000 0 0
check_eq "$(hub stats | jq -c '.today.tokens')" '4100000' "stats: se guarda un minuto"
check_eq "$(hub stats --fresh | jq -c '[.today.tokens, .total.tokens]')" '[5100000,10850000]' "stats --fresh: vuelve a contar"

# ---------- bk _do: correr bk suelto y avisar al terminar ----------
navisos() { ls "$AV" 2>/dev/null | grep -c '\.json$'; }
hay() { [ "$(navisos)" -ge "$1" ]; }
ultimo() { cat "$AV/$(ls "$AV" | grep '\.json$' | tail -1)"; }
ROLES=$(cd "$REPO" && bk roles)
rm -rf "$AV"; : >"$HD_FAKE/log"
out=$(bk _do --cwd "$REPO" --title "Roles" -- roles); rc=$?; LOGF=$(jq -r .log <<<"$out")
check_eq "$rc $(jq -r .ok <<<"$out") $(has "$LOGF" "$HUBC/do/") $(jq -r '.pid | type' <<<"$out")" "0 true si number" "_do: vuelve con ok, el log y el pid"
espera 15 hay 1; check_eq "$(navisos)" "1" "_do: al terminar deja un aviso en la cola"
check_eq "$(ultimo | jq -c '[.title, .level, .body, .mod, .log, (.ts | type)]')" "[\"Roles\",\"success\",\"$(tail -1 <<<"$ROLES")\",\"\",\"$LOGF\",\"number\"]" "_do que sale bien: aviso success con la última línea de la salida y el log"
check_eq "$(cat "$LOGF")" "$ROLES" "_do: el log tiene la salida del comando"
espera 10 grep -q 'mod.open' "$HD_FAKE/log"   # abrir el mod es lo último que hace hd_notice
check_eq "$(grep -c 'mod.open {"name": "bk-aviso"}' "$HD_FAKE/log") $(ls "$AV" | grep -vc '\.json$') $(jq -c '[.title, .level]' "$HOME/.cache/bk/herdr-aviso.json")" '1 0 ["Roles","success"]' "_do: abre bk-aviso, no deja temporales en la cola y el archivo viejo queda con el último aviso"
rm -rf "$AV"; out=$(bk _do --cwd "$WT" --title Carpeta -- _hub status); espera 15 hay 1
check_eq "$(jq -r .branch "$(jq -r .log <<<"$out")")" "w7" "_do --cwd: el comando corre en esa carpeta"
rm -rf "$AV"; bk _do --cwd "$REPO" -- approve nada >/dev/null; espera 15 hay 1
check_eq "$(ultimo | jq -c '[.title, .level, .body]')" "[\"bk approve nada\",\"error\",\"bk: no hay una tarea pendiente 'nada' (bk tasks)\"]" "_do que falla: aviso error con la última línea; sin --title, el comando"
rm -rf "$AV"; out=$(bk _do --title Sonido -- sound off); espera 15 hay 1
check_eq "$(ultimo | jq -c '[.level, .body]') $(grep -c "$(printf '\033')" "$(jq -r .log <<<"$out")")" '["success","sonidos apagados"] 1' "_do: el texto del aviso va sin los colores que sí están en el log"
rm -rf "$AV"; bk _do -- roles >/dev/null; bk _do -- tasks >/dev/null; espera 15 hay 2
check_eq "$(navisos) $(cat "$AV"/*.json | jq -r .title | sort | tr '\n' '|')" "2 bk roles|bk tasks|" "_do: dos avisos casi juntos no se pisan"
rm -rf "$AV"; : >"$HD_FAKE/closed"
t0=$(python3 -c 'import time; print(time.time())')
out=$(BK_HERDR_WAIT=6 bk _do --cwd "$REPO" --title Chat -- chat); PID=$(jq -r .pid <<<"$out")
check_eq "$(python3 -c 'import sys, time; print("ya" if time.time() - float(sys.argv[1]) < 2 else "tarde")' "$t0") $(navisos)" "ya 0" "_do vuelve en el acto: el comando sigue corriendo y todavía no avisó"
check_eq "$(ps -o pgid= -p "$PID" | tr -d ' ')" "$PID" "_do: lo que lanza corre en su propia sesión (no muere con quien lo pidió)"
espera 20 hay 1; rm -f "$HD_FAKE/closed"
check_eq "$(ultimo | jq -c '[.title, .level, .body]')" '["Chat","error","bk: Herdr no respondió: abrilo y volvé a correr el comando"]' "_do: el aviso llega cuando el comando termina, con su error"
# --dry-run (el de bk, o entre los argumentos del bk de adentro): dice qué correría y no deja log ni aviso
cp "$HD_FAKE/state.json" "$TMP/antes.json"; rm -rf "$AV"; n0=$(ls "$HUBC/do" | wc -l | tr -d ' ')
out=$(bk _do --cwd "$REPO" --title Run -- run 21 --role implementer --dry-run)
check_eq "$? $(jq -c '[.ok, .dry, .cmd, .cwd, has("pid"), has("log")]' <<<"$out")" "0 [true,true,[\"bk\",\"run\",\"21\",\"--role\",\"implementer\",\"--dry-run\"],\"$REPO\",false,false]" "_do -- run … --dry-run: dice qué correría, con sus argumentos tal cual, y no lo corre"
out=$(bk --dry-run _do --cwd "$REPO" --title Run -- run 21 --role implementer)
check_eq "$? $(jq -c '[.dry, .cmd]' <<<"$out")" '0 [true,["bk","run","21","--role","implementer"]]' "bk --dry-run _do …: lo mismo"
tk state proj 21-implementer >/dev/null 2>&1; trc=$?
check_eq "$(ls "$HUBC/do" | wc -l | tr -d ' ') $(navisos) $(cmp -s "$HD_FAKE/state.json" "$TMP/antes.json" && echo igual) $trc" "$n0 0 igual 4" "_do con --dry-run: ni log, ni aviso, ni nada lanzado"
# los argumentos del bk de adentro pasan tal cual: este bk no valida su --account
rm -rf "$AV"; out=$(bk _do --title Cuenta -- roles --account nada); rc=$?; espera 15 hay 1
check_eq "$rc $(jq -r .ok <<<"$out") $(ultimo | jq -r '.level + " " + .body')" "0 true error bk: no existe la cuenta nada (bk account)" "_do -- … --account X: lo valida el bk de adentro, y su error llega como aviso"
# si la última línea de la salida es un JSON, el aviso lo dice en palabras
av() { printf '%s\n' "$1" >"$TMP/salida.log"; python3 "$ROOT/lib/herdr_hub.py" _aviso "$TMP/salida.log" "$2" | tr '\n' '|'; }
check_eq "$(av 'abriendo…
{"ok": true, "did": "show"}' 0) $(av '{"ok": true, "did": "resume"}' 0)" "success|ya estaba abierta: la mostré| success|retomada en un chat nuevo|" "aviso de bk _hub session-go: lo que hizo, en palabras"
check_eq "$(av '{"ok": true, "log": "x", "pid": 3}' 0)" "success|listo|" "aviso de otro JSON con ok: listo"
check_eq "$(av '{"error": "no  pude", "ok": true}' 0)" "error|no pude|" "aviso de un JSON con error: ese texto y nivel error, aunque haya salido con 0"
check_eq "$(av '{roto' 0) $(av '{"otra": 1}' 1) $(av '["ok"]' 0)" 'success|{roto| error|{"otra": 1}| success|["ok"]|' "aviso de algo que no es un JSON de esos: la línea tal cual"
check_eq "$(av '' 0) $(av '' 3)" "success|listo| error|salió con 3|" "aviso de un comando sin salida: listo, o con qué salió"
rm -rf "$AV"; bk _do --title Ir -- _hub session-go sid-chat >/dev/null; espera 15 hay 1
check_eq "$(ultimo | jq -c '[.title, .level, .body]')" '["Ir","success","ya estaba abierta: la mostré"]' "_do -- _hub session-go: el aviso no muestra el JSON crudo"
n0=$(ls "$HUBC/do" | wc -l | tr -d ' ')
for bad in "roles" "--" "--cwd $TMP/no-existe -- roles" "--title"; do
  # shellcheck disable=SC2086
  out=$(bk _do $bad 2>"$TMP/err"); check_eq "$? [$out] $(lines "$(cat "$TMP/err")")" "1 [] 1" "_do ${bad/"$TMP"/…} (mal usado, o en una carpeta que no existe): sale con 1 y una línea"
done
check_eq "$(ls "$HUBC/do" | wc -l | tr -d ' ')" "$n0" "_do mal usado: no lanza nada"

# ---------- el aviso de siempre (el resumen listo) también va a la cola, con nivel info ----------
(cd "$REPO" && HC_TERMINAL_ID=t1 BK_HC="$TMP/fake/hc" PATH="$TMP/fake:$PATH" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import handoff as H; H.request("rojo1", cwd=sys.argv[2])' "$ROOT/lib" "$REPO") >/dev/null
printf '# resumen\n' >"$BK_HANDOFF_DIR/rojo1.md"; rm -rf "$AV"
bk handoff --listo rojo1 >/dev/null 2>&1
check_eq "$(navisos) $(ultimo | jq -c '[.title, .body, .mod, .level, has("log")]')" '1 ["Resumen listo: proj «Idea»","Clic para seguir en un chat nuevo","bk-seguir","info",false]' "hd_notice sin nivel: info, con el mod del clic y sin log"

# bk _hub mira siempre Herdr, pero lo que lanza bk _do corre con el backend de quien lo pidió
rm -rf "$AV"; PATH="$TMP/fake:$PATH" BK_BACKEND=tmux "$ROOT/bin/bk" _do --title Backend -- backend >/dev/null; espera 15 hay 1
check_eq "$(ultimo | jq -r .body)" "tmux" "_do: el bk de adentro corre con el entorno de quien lo pidió, sin el backend cambiado"

check_eq "$(grep -c -e '^tmux' -e '^open' "$TMP/otros.log")" "$(grep -c '^tmux list-panes -a' "$TMP/otros.log")" "nada de esto abrió una app ni le pidió a tmux otra cosa que la lista de panes (bk s la mira)"
echo "1..$N"
[ "$FAILED" -eq 0 ]
