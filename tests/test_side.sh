#!/usr/bin/env bash
# bk _side (lib/herdr_side.py): los datos del panel derecho de bk en Herdr. Un repo de verdad en un directorio
# temporal con un worktree; nada toca tu config (HOME temporal) y no se pide el uso (--usage lee transcripts).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"; unset BK_CONTEXT_FILE   # el umbral sale de este HOME
unset BK_BACKEND BK_PROJECT GIT_DIR GIT_WORK_TREE
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
side() { "$ROOT/bin/bk" _side "$@"; }
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

REPO="$TMP/proj"; WT="$TMP/proj-wt/7"
g init -q -b main "$REPO"; printf 'uno\ndos\n' >"$REPO/a.txt"; echo x >"$REPO/borrar.txt"
g -C "$REPO" add -A; g -C "$REPO" commit -qm inicio
g -C "$REPO" worktree add -q -b w7 "$WT" >/dev/null 2>&1

check_eq "$(side "$REPO" | jq -c '[.project, .branch, .dirty, (.changes | length), has("usage")]')" '["proj","main",0,0,false]' "limpio: proyecto, rama, nada sin commitear y sin uso si no se pide"
check_eq "$(side "$WT" | jq -c '[.project, .branch]')" '["proj","w7"]' "desde un worktree: el proyecto es el repo principal y la rama la del worktree"

printf 'uno\ndos\ntres\ncuatro\n' >"$WT/a.txt"; rm "$WT/borrar.txt"; echo n >"$WT/nuevo.txt"
check_eq "$(side "$REPO" | jq -c '[.dirty, (.changes | map(.name + "@" + .branch))]')" '[0,["7@w7"]]' "cambios: aparece el worktree que tiene algo, no el repo limpio"
check_eq "$(side "$WT" | jq -c '[.dirty, (.changes[0].files | map(.code + " " + .path + " +" + .add + " -" + .del))]')" '[3,["M a.txt +2 -0","D borrar.txt +0 -1","A nuevo.txt + -"]]' "cambios: modificado, borrado y nuevo, con sus líneas"

for i in $(seq 1 45); do echo "$i" >"$REPO/f$i.txt"; done
check_eq "$(side "$REPO" | jq -c '.changes[] | select(.name == "proj") | [(.files | length), .more]')" '[40,5]' "cambios: hasta 40 archivos por carpeta y cuántos quedaron afuera"

mkdir "$TMP/suelta"
check_eq "$(side "$TMP/suelta" | jq -c '[.project, .branch, (.changes | length)]')" '["","",0]' "fuera de un repo: sin proyecto ni cambios"
check_eq "$(side "$TMP/no-existe" | jq -c '[.project, (.changes | length)]')" '["",0]' "una carpeta que no existe no rompe"
check_eq "$(side "$REPO" | jq -c '.profile | map(.role) | index("implementer") != null')" "true" "perfil: los roles de bk roles"

# contexto: el de la sesión de Claude más reciente de esa carpeta (transcript en ~/.claude/projects/<ruta con - por todo lo que no es letra o número>)
sesion() { # <carpeta> <archivo> <tokens de entrada> <segundos de antigüedad>
  local d="$HOME/.claude/projects/$(printf %s "$1" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$d"
  printf '{"type":"assistant","message":{"model":"x","usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}\n' "$3" >"$d/$2.jsonl"
  touch -t "$(date -v-"$4"S +%Y%m%d%H%M.%S)" "$d/$2.jsonl"
}
check_eq "$(side "$REPO" | jq -c '.context')" "null" "contexto: sin sesión de Claude en la carpeta es null"
sesion "$REPO" vieja 450000 600; sesion "$REPO" nueva 170000 5
check_eq "$(side "$REPO" | jq -c '.context')" '{"tokens":170000,"level":"warn","limit":200000}' "contexto: toma la sesión más reciente de la carpeta, dice el nivel (ámbar desde 150k) y el umbral"
sesion "$REPO" nueva 250000 5
check_eq "$(side "$REPO" | jq -c '.context.level')" '"high"' "contexto: rojo desde 200k (el umbral por defecto)"
mkdir -p "$HOME/.config/bk"; echo 300k >"$HOME/.config/bk/context"
check_eq "$(side "$REPO" | jq -c '[.context.level, .context.limit]')" '["warn",300000]' "contexto: con bk context 300k, 250k es ámbar y el umbral sale en limit"
rm -f "$HOME/.config/bk/context"
sesion "$REPO" nueva 90000 5
check_eq "$(side "$REPO" | jq -c '.context')" '{"tokens":90000,"level":"","limit":200000}' "contexto: por debajo de 150k sin nivel"
check_eq "$(side "$WT" | jq -c '.context')" "null" "contexto: un worktree no hereda la sesión del repo principal"

# Caché de los demás worktrees (Herdr pide esto cada 4 s): la carpeta propia siempre fresca, las otras hasta
# BK_SIDE_TTL o hasta que cambie su index, su HEAD o su carpeta. El caché vive en el HOME temporal.
rm -f "$REPO"/f*.txt; g -C "$WT" checkout -q -- . 2>/dev/null; g -C "$WT" clean -qfd
cambios() { side "$1" | jq -c '[.changes[] | .name + ":" + (.files | length | tostring)]'; }
check_eq "$(cambios "$REPO")" '[]' "caché: todo limpio"
sleep 1; echo otra >>"$WT/a.txt"   # solo contenido: no cambia ni el index ni la carpeta
check_eq "$(cambios "$REPO")" '[]' "caché: un cambio de contenido en otro worktree espera al TTL"
check_eq "$(cambios "$WT")" '["7:1"]' "caché: la carpeta de la terminal siempre se mira de nuevo"
check_eq "$(cambios "$REPO")" '["7:1"]' "caché: lo que vio la terminal del worktree les sirve a las demás"
echo otra >>"$WT/borrar.txt"
check_eq "$(cambios "$REPO")" '["7:1"]' "caché: otro cambio de contenido sigue esperando"
check_eq "$(BK_SIDE_TTL=0 cambios "$REPO")" '["7:2"]' "caché: con el TTL vencido se mira de nuevo"
sleep 1; g -C "$WT" commit -qam todo
check_eq "$(cambios "$REPO")" '[]' "caché: un commit en otro worktree (cambia su index) se ve enseguida"
g -C "$REPO" checkout -q -- .; g -C "$REPO" status --porcelain >/dev/null; sleep 1; touch "$REPO/borrar.txt"   # misma letra, otra fecha: git querría reescribir el index
ix=$(stat -f %m%N "$REPO/.git/index" 2>/dev/null || stat -c %Y "$REPO/.git/index")
side "$REPO" >/dev/null
check_eq "$(stat -f %m%N "$REPO/.git/index" 2>/dev/null || stat -c %Y "$REPO/.git/index")" "$ix" "git sin locks opcionales: mirar no reescribe el index (no le traba un commit a un agente)"

echo "1..$N"
[ "$FAILED" -eq 0 ]
