#!/usr/bin/env bash
# bk profile (lib/profiles.py) y cómo lo lee bin/bk (profile_spec, role_spec): perfiles de modelos globales.
# HOME temporal: nada toca tu ~/.config/bk. Se comprueba que el profiles.yml del repo no cambie.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
unset BK_BACKEND BK_PROJECT GIT_DIR GIT_WORK_TREE
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
B="$ROOT/bin/bk"
spec() { (cd "${2:-$TMP}" && "$B" roles) | awk -v r="$1" '$1 == r { print $2 }'; }
CONF="$HOME/.config/bk"
REPO_SUM=$(shasum "$ROOT/profiles.yml")

check_eq "$(spec implementer) $(spec reviewer)" "claude/sonnet claude/sonnet" "sin perfil: los modelos de roles.yml"
check_eq "$("$B" profile --json | jq -c '[.active, (.profiles | map(.name))]')" '[null,["normal","barato","a-fondo","codex"]]' "de fábrica: normal, barato, a-fondo y codex, ninguno activo"

"$B" profile barato >/dev/null
check_eq "$(cat "$CONF/profile")" "barato" "bk profile <nombre> guarda el activo"
check_eq "$(spec reviewer) $(spec planner)" "claude/haiku claude/sonnet" "con barato, bk roles da los modelos del perfil"
check_eq "$(cd "$TMP" && "$B" roles | awk '$1 == "reviewer" { print $3 }')" "sub" "el modo sigue saliendo de roles.yml"
check_eq "$(cd "$TMP" && "$B" roles | head -1)" "perfil: barato (bk profile para cambiarlo)" "bk roles dice el perfil activo"
check_eq "$([ -e "$CONF/profiles.yml" ] && echo copia || echo sin)" "sin" "elegir un perfil no copia el archivo"

"$B" profile set barato reviewer codex/gpt-5 >/dev/null 2>&1
check_eq "$(spec reviewer) $(spec implementer)" "codex/gpt-5 claude/sonnet" "set: un perfil mezcla providers"
check_eq "$([ -f "$CONF/profiles.yml" ] && echo copia)" "copia" "set copia los de fábrica a ~/.config/bk/profiles.yml"
check_eq "$(shasum "$ROOT/profiles.yml")" "$REPO_SUM" "set no toca el profiles.yml del repo"
check_eq "$(grep -c '^# Perfiles de modelos' "$CONF/profiles.yml") $(grep -c 'codex/gpt-5' "$CONF/profiles.yml")" "1 1" "set cambia una sola línea y deja los comentarios"

# Python (bk profile --json) y el awk de bin/bk leen igual, también con un archivo a mano con comentarios y huecos
cat >"$CONF/profiles.yml" <<'EOF'
# a mano
uno:   # comentario en el título
  planner: codex/o3   # al lado
  # implementer: claude/opus
  reviewer: claude/haiku
suelto: claude/opus
  implementer: claude/opus
dos:
  implementer: claude/claude-opus-5-5
EOF
"$B" profile uno >/dev/null
check_eq "$(spec planner) $(spec implementer) $(spec reviewer)" "codex/o3 claude/sonnet claude/haiku" "awk: comentarios, rol comentado (cae en roles.yml) y título con comentario"
check_eq "$("$B" profile --json | jq -c '[.profiles[] | select(.name == "uno") | .roles]')" '[{"planner":"codex/o3","reviewer":"claude/haiku"}]' "python lee igual que awk"
"$B" profile dos >/dev/null
check_eq "$(spec implementer) $("$B" profile --json | jq -r '.profiles | map(.name) | join(",")')" "claude/claude-opus-5-5 uno,dos" "un renglón sin sangría que no es perfil corta el bloque (en los dos)"

# El perfil activo que ya no existe: cada rol vuelve a roles.yml, sin romper
echo fantasma >"$CONF/profile"
check_eq "$(spec implementer) $("$B" profile --json | jq -c '[.active, .missing]')" 'claude/sonnet [null,"fantasma"]' "activo que no está en el archivo: roles.yml y se avisa"

# El .barrilete/roles.yml de un proyecto le gana al perfil
"$B" profile uno >/dev/null
mkdir -p "$TMP/proj/.barrilete"; git -C "$TMP/proj" init -q
echo "planner: claude/haiku main" >"$TMP/proj/.barrilete/roles.yml"
check_eq "$(spec planner "$TMP/proj") $(spec reviewer "$TMP/proj")" "claude/haiku claude/haiku" "proyecto > perfil > roles.yml"

# Errores: no cambian nada
rm "$CONF/profiles.yml"; "$B" profile normal >/dev/null
"$B" profile nada >/dev/null 2>&1; rc1=$?
"$B" profile set normal reviewer foo/x >/dev/null 2>&1; rc2=$?
"$B" profile set normal nadie claude/opus >/dev/null 2>&1; rc3=$?
"$B" profile set normal reviewer 'claude/x;rm' >/dev/null 2>&1; rc4=$?
"$B" profile set Mal reviewer claude/opus >/dev/null 2>&1; rc5=$?
check_eq "$rc1$rc2$rc3$rc4$rc5 $(cat "$CONF/profile") $([ -e "$CONF/profiles.yml" ] && echo copia || echo sin)" "11111 normal sin" "perfil, provider, rol, modelo o nombre inválidos: error y nada cambia"
"$B" profile rm normal >/dev/null 2>&1; rc=$?
check_eq "$rc $("$B" profile --json | jq -r '.profiles | map(.name) | join(",")')" "1 normal,barato,a-fondo,codex" "no borra el activo"

# new y rm
"$B" profile new viaje a-fondo >/dev/null; "$B" profile set viaje implementer codex/gpt-5-codex >/dev/null 2>&1
check_eq "$("$B" profile --json | jq -c '.profiles[] | select(.name == "viaje") | [.roles.planner, .roles.implementer]')" '["claude/opus","codex/gpt-5-codex"]' "new copia otro perfil y set lo edita"
"$B" profile new viaje >/dev/null 2>&1; rc=$?
check_eq "$rc" "1" "new no pisa uno que existe"
"$B" profile rm barato >/dev/null
check_eq "$("$B" profile --json | jq -r '.profiles | map(.name) | join(",")') $(grep -c '^$' "$CONF/profiles.yml")" "normal,a-fondo,codex,viaje 4" "rm saca el bloque y deja un solo hueco entre perfiles"
check_eq "$("$B" profile --json | jq -c '.profiles[] | select(.name == "a-fondo") | .roles | length')" "5" "rm no se lleva el perfil de al lado"

"$B" profile off >/dev/null
check_eq "$([ -e "$CONF/profile" ] && echo hay || echo no) $(spec implementer)" "no claude/sonnet" "off: sin perfil, roles.yml"

# Los datos de alt+k y del panel derecho
"$B" profile a-fondo >/dev/null
check_eq "$("$B" _hub palette | jq -c '[.profile.active, (.profile.profiles | map(.name) | index("viaje") != null)]')" '["a-fondo",true]' "_hub palette trae los perfiles y el activo"
check_eq "$("$B" _hub palette | jq -r '.profile.profiles[] | select(.name == "normal") | .models')" "opus · sonnet · haiku" "_hub palette: los modelos de cada perfil, sin repetir (lo corto de alt+k)"
check_eq "$("$B" _hub palette | jq -r '.profile.profiles[] | select(.name == "viaje") | .models')" "opus · codex/gpt-5-codex · sonnet" "_hub palette: con el provider si no es claude"
check_eq "$("$B" _side "$TMP" | jq -c '[.profile_name, (.profile[] | select(.role == "implementer") | .model)]')" '["a-fondo","opus"]' "_side: el perfil activo y los modelos que da"
"$B" profile viaje >/dev/null
check_eq "$("$B" _side "$TMP" | jq -r '.profile[] | select(.role == "implementer") | .model')" "codex/gpt-5-codex" "_side: el provider se ve si no es claude"
check_eq "$(shasum "$ROOT/profiles.yml")" "$REPO_SUM" "el profiles.yml del repo quedó igual"

echo "1..$N"
[ "$FAILED" -eq 0 ]
