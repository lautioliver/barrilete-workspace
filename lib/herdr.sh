# shellcheck shell=bash
# bk sobre Herdr en vez de tmux (lo carga bin/bk; se elige con `bk backend herdr`).
# Cada proyecto es un espacio de Herdr; cada chat y cada agente, una pestaña de ese espacio. No hay riel,
# tira ni footer: la lista de espacios y la de agentes de Herdr ya muestran lo mismo.
#   herdr-app  maneja la ventana: espacios y pestañas (necesita la app abierta)
#   hc         herdr-core: las terminales. Leer la pantalla, escribir, etiquetar, cerrar
# Lo que en tmux era el nombre de la ventana (i42, pr57) y sus @opciones acá son etiquetas de la terminal:
#   bk.kind     agent | chat
#   bk.win      la "ventana" del agente (i42) o el nombre del chat (abra, abra-2, abra-<rama>)
#   bk.project  el proyecto · bk.role · bk.ref · bk.account · bk.name (el nombre que le pusiste a un chat)
#   bk.id       el número fijo de la ventana (más abajo) · bk.adopted=1 si bk la adoptó (hd_adopt)
# El "pane" de bk es la dirección de la terminal (t7): la que el hook de estado anota como pane
# (HC_TERMINAL_ID), así que pane_state, bk say en cola y el pre-registro andan igual que en tmux.
HD_APP="${BK_HERDR_APP:-herdr-app}"
HD_HC="${BK_HC:-hc}"

hd_app() { "$HD_APP" "$@"; }
hd_hc()  { "$HD_HC" "$@"; }

need_herdr() {
  command -v "$HD_APP" >/dev/null || die "falta herdr-app (instalá Herdr, o volvé a tmux: bk backend tmux)"
  command -v "$HD_HC" >/dev/null || die "falta hc, el herdr-core (instalá Herdr, o volvé a tmux: bk backend tmux)"
}

# hd_up: crear espacios y pestañas necesita la ventana de Herdr abierta. Si no lo está, la abre y espera.
hd_up() {
  need_herdr
  hd_app status >/dev/null 2>&1 && return 0
  info "abriendo Herdr…"
  if [ -n "${BK_HERDR_OPEN:-}" ]; then $BK_HERDR_OPEN >/dev/null 2>&1 || true
  else open -ga Herdr >/dev/null 2>&1 || true; fi
  local i
  for i in $(seq "${BK_HERDR_WAIT:-30}"); do
    hd_app status >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  die "Herdr no respondió: abrilo y volvé a correr el comando"
}

# hd_install: las teclas alt+…, los mods bk-* (acciones y paneles), los temas y el layout bk-lavanda en Herdr
# (herdr/ del repo → ~/.config/herdr-app; lib/herdr_install.py).
# No corta bk: si algo falla, avisa.
HD_HOME="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
hd_install() {
  python3 "$WS/lib/herdr_install.py" "$WS/herdr" "$HD_HOME" || info "(los atajos de bk no quedaron instalados en Herdr)"
}

# hd_notice <título> <texto> [mod] [nivel] [log]: un aviso de Herdr; al hacerle clic abre ese mod (bk-seguir).
# nivel: info (si no se dice) | success | warning | error. log: el archivo con la salida de lo que avisa (bk _do).
# Solo un mod puede avisar: bk deja el aviso en la cola ~/.cache/bk/herdr-avisos/<epoch>-<pid>.json, uno por
# archivo (dos avisos casi juntos no se pisan), y abre bk-aviso, que los muestra, los borra y se cierra.
#   {"title": "…", "body": "…", "mod": "bk-seguir" | "", "level": "info", "ts": <epoch>, "log": "…" (solo si hay)}
# ~/.cache/bk/herdr-aviso.json, el aviso único de antes, sigue quedando con el último (lo lee el bk-aviso viejo).
hd_notice() {
  local dir="$HOME/.cache/bk/herdr-avisos" old="$HOME/.cache/bk/herdr-aviso.json" level="${4:-info}" json name f k=1
  case "$level" in info|success|warning|error) ;; *) level=info ;; esac
  json=$(jq -cn --arg title "$1" --arg body "$2" --arg mod "${3:-}" --arg level "$level" --arg log "${5:-}" \
           '{title: $title, body: $body, mod: $mod, level: $level, ts: (now | floor)}
            + (if $log != "" then {log: $log} else {} end)') || return 1
  mkdir -p "$dir" || return 1
  name="$(date +%s)-$$"; f="$dir/$name.json"
  while [ -e "$f" ]; do k=$((k + 1)); f="$dir/$name-$k.json"; done   # dos avisos del mismo bk en un segundo
  # primero con otro nombre (no termina en .json): el mod nunca lee un aviso a medio escribir
  printf '%s\n' "$json" >"$f.tmp" && mv "$f.tmp" "$f" || return 1
  printf '%s\n' "$json" >"$old.tmp" && mv "$old.tmp" "$old" || true
  hd_app do mod.open --name bk-aviso >/dev/null 2>&1 || info "(Herdr no mostró el aviso: $1)"
}

# hd_json <arg…>: los argumentos como un array JSON (el argv de una pestaña). Con python y no con jq --args,
# que se queda con los que empiezan con guion (-c).
hd_json() { python3 -c 'import json, sys; print(json.dumps(sys.argv[1:], ensure_ascii=False))' "$@"; }

# hd_space_id <nombre>: el id del espacio de esta máquina con ese nombre (vacío si no hay)
hd_space_id() {
  hd_app ls 2>/dev/null | jq -r --arg n "$1" '[.spaces[]? | select(.name == $n and .machine == null) | .id] | first // empty' 2>/dev/null || true
}

# hd_find <etiqueta=valor>…: direcciones de las terminales vivas que tienen todas esas etiquetas
hd_find() {
  local a=() kv
  for kv in "$@"; do a+=(--label "$kv"); done
  hd_hc ls --json "${a[@]}" 2>/dev/null | jq -r '.terminals[]?.address // empty' 2>/dev/null || true
}

# hd_label <terminal> <etiqueta>: su valor (vacío si no la tiene)
hd_label() { hd_hc get "$1" --json 2>/dev/null | jq -r --arg k "$2" '.labels[$k] // empty' 2>/dev/null || true; }

# Las consultas de este archivo nunca cortan bk: si Herdr no responde devuelven vacío (con pipefail, un hc
# caído dentro de $(…) hacía salir a bk sin decir nada).
hd_term_of_win() { hd_find bk.kind=agent "bk.win=$1" | head -1; }   # la terminal del agente de esa ventana
hd_chat_term()   { hd_find bk.kind=chat "bk.win=$1" | head -1; }    # la terminal del chat con ese nombre

# hd_agents: "ventana<TAB>terminal" de cada agente vivo
hd_agents() {
  local t
  for t in $(hd_find bk.kind=agent); do printf '%s\t%s\n' "$(hd_label "$t" bk.win)" "$t"; done
}

# Lo que estás mirando ("espacio<TAB>pestaña") y volver a eso: lanzar un agente no te saca de donde estás
hd_view() { hd_app status 2>/dev/null | jq -r '[.space // "", .tab // ""] | @tsv' 2>/dev/null || true; }
hd_show() {
  [ -z "${1:-}" ] || hd_app do space.select --id "$1" >/dev/null 2>&1 || true
  [ -z "${2:-}" ] || hd_app do tab.select --id "$2" >/dev/null 2>&1 || true
}

# hd_open_tab <espacio> <pestaña> <carpeta> <argv…>: una pestaña nueva en el espacio con ese nombre; si el espacio
# no existe, lo crea con esa pestaña. Imprime la dirección de la terminal. Los argumentos van como un objeto
# JSON: con --name, un nombre como "42" o "true" llegaría como número. Antes de llamarla: hd_up.
hd_open_tab() {
  local space="$1" tab="$2" dir="$3" sp out args; shift 3
  sp=$(hd_space_id "$space")
  if [ -n "$sp" ]; then
    args=$(jq -cn --arg space "$sp" --arg name "$tab" --arg folder "$dir" --argjson argv "$(hd_json "$@")" \
             '{space: $space, name: $name, folder: $folder, argv: $argv}')
    out=$(hd_app do tab.new "$args") \
      || { printf 'bk: Herdr no creó la pestaña %s: %s\n' "$tab" "$out" >&2; return 1; }
  else
    args=$(jq -cn --arg name "$space" --arg tab "$tab" --arg folder "$dir" --argjson argv "$(hd_json "$@")" \
             '{name: $name, tab: $tab, folder: $folder, argv: $argv}')
    out=$(hd_app do space.new "$args") \
      || { printf 'bk: Herdr no creó el espacio %s: %s\n' "$space" "$out" >&2; return 1; }
  fi
  out=$(jq -r '.terminal // empty' <<<"$out" 2>/dev/null)
  [ -n "$out" ] || { printf 'bk: Herdr no informó la terminal de %s\n' "$tab" >&2; return 1; }
  printf '%s' "$out"
}

# hd_launch <ventana> <carpeta> <comando de shell> [-e VAR=valor …]: el agente en una pestaña nueva del espacio
# de su proyecto, con esas variables. No cambia lo que estás mirando. Imprime la dirección de la terminal.
# Herdr corre el argv en tu shell interactiva y la deja abierta cuando el agente termina (para leer lo último).
# Antes de llamarla: hd_up (acá no, porque su salida se captura).
hd_launch() {
  local win="$1" dir="$2" full="$3" kv envv=() view t; shift 3
  for kv in "$@"; do [ "$kv" = -e ] || envv+=("$kv"); done
  view=$(hd_view)
  t=$(hd_open_tab "$(project_of "$dir")" "$win" "$dir" \
        env BK_BACKEND=herdr "${envv[@]+"${envv[@]}"}" bash -c "$full") || return 1
  # shellcheck disable=SC2086
  [ -z "${view//[[:space:]]/}" ] || hd_show $view
  printf '%s' "$t"
}

# hd_chat <nombre del chat> <espacio> <pestaña> <carpeta> <proyecto>: un claude en una pestaña del espacio (que se
# crea si no está) y a la vista. WS_CHAT_CMD cambia lo que corre (bk chat --desde); BK_WS_NAME lo nombra.
# HD_TAB (un nombre automático de la pestaña) y HD_LABELS (etiquetas de más) los pone hd_chat_from; la terminal
# nueva queda en HD_NEW_TERM.
hd_chat() {
  local ws="$1" space="$2" tab="$3" dir="$4" top="$5" t kv CTA envv=()
  account_args claude
  for kv in "${CTA[@]+"${CTA[@]}"}"; do [ "$kv" = -e ] || envv+=("$kv"); done
  hd_up
  tab="${BK_WS_NAME:-${HD_TAB:-$tab}}"
  if [ -n "${WS_CHAT_CMD:-}" ]; then
    t=$(hd_open_tab "$space" "$tab" "$dir" \
          env BK_BACKEND=herdr "BK_PROJECT=$top" "${envv[@]+"${envv[@]}"}" bash -c "$WS_CHAT_CMD") || exit 1
  else
    t=$(hd_open_tab "$space" "$tab" "$dir" \
          env BK_BACKEND=herdr "BK_PROJECT=$top" "${envv[@]+"${envv[@]}"}" claude) || exit 1
  fi
  HD_NEW_TERM="$t"
  local lab=(bk.kind=chat "bk.win=$ws" "bk.project=$(project_of "$top")") cta
  cta=$(account_of claude); [ -z "$cta" ] || lab+=("bk.account=$cta")
  [ -z "${BK_WS_NAME:-}" ] || lab+=("bk.name=$BK_WS_NAME")
  lab+=("${HD_LABELS[@]+"${HD_LABELS[@]}"}")
  hd_hc label "$t" "${lab[@]}" >/dev/null 2>&1 || info "(no pude etiquetar el chat $ws: bk ls no lo va a mostrar)"
  local n; n=$(hd_id_give "$t" 2>/dev/null) || n=""
  info "chat $ws → Herdr, espacio $space${n:+ · ventana $n}"
}

# hd_free <base>: el primer nombre de chat libre: <base>-2, <base>-3…
hd_free() {
  local k=2
  while [ -n "$(hd_chat_term "$1-$k")" ]; do k=$((k + 1)); done
  printf '%s-%s' "$1" "$k"
}

# hd_relaunch_chat <espacio>: el chat del espacio vuelve a arrancar con la cuenta del espacio (bk account use
# --relaunch), retomando su conversación: uno nuevo con claude --resume en el mismo espacio y después se cierra el
# viejo (si el nuevo no abre, el viejo queda). No si está trabajando o esperando una respuesta tuya.
hd_relaunch_chat() {
  local name="$1" t sid="" st="" j dir nm
  t=$(hd_chat_term "$name"); [ -n "$t" ] || die "el espacio $name no tiene un chat de bk"
  read -r sid st < <(pane_sid "$t"; echo)
  case "$st" in working|waiting|background) die "el chat está trabajando o te espera: relanzalo cuando termine" ;; esac
  case "$sid" in bk-*) sid="" ;; esac
  j=$(hd_hc get "$t" --json 2>/dev/null) || die "no encuentro el chat de $name en Herdr"
  dir=$(jq -r '.cwd // ""' <<<"$j"); [ -d "$dir" ] || dir=$PWD
  nm=$(jq -r '.labels["bk.name"] // ""' <<<"$j")
  # Sin la cuenta que traía este bk (la del chat viejo, si se corrió desde ahí): manda la del espacio
  BK_ACCOUNT="" BK_ACCOUNT_CLAUDE="" BK_WS_NAME="$nm" WS_CHAT_CMD="claude${sid:+ --resume $(sq "$sid")}" \
    hd_chat "$name" "$name" chat "$dir" "$(project_top "$dir")"
  hd_hc kill "$t" >/dev/null 2>&1 || info "(no pude cerrar el chat anterior, $t)"
  info "chat relanzado${sid:+ (retoma $sid)}"
}

# hd_relaunch <terminal> <cuenta>: el Claude de esa terminal sale (/exit) y vuelve a arrancar en la misma shell con
# la cuenta nueva, retomando su conversación (--resume con el id que anotó el hook de estado). No toca un chat que
# trabaja o te espera, una terminal sin Claude, ni uno sin conversación conocida: avisa y sale con 1.
hd_relaunch() {
  local t="$1" acct="$2" j app state sid="" st="" i cmd kv
  j=$(hd_hc get "$t" --json 2>/dev/null) || { info "no encuentro la terminal $t en Herdr"; return 1; }
  app=$(jq -r '.status.app // ""' <<<"$j"); state=$(jq -r '.status.state // ""' <<<"$j")
  [ "$app" = claude-code ] || { info "$t no tiene un Claude abierto: los chats nuevos ya salen con la cuenta nueva"; return 1; }
  [ "$(jq -r '.labels["bk.account"] // "" | if . == "" then "default" else . end' <<<"$j")" != "$acct" ] \
    || { info "el chat de $t ya usa la cuenta $acct"; return 0; }
  case "$state" in working|blocked|waiting|background)
    info "el chat de $t está trabajando o te espera: sigue con la cuenta anterior hasta que lo relances"; return 1 ;;
  esac
  read -r sid st < <(pane_sid "$t"; echo)
  case "$st" in working|waiting|background)
    info "el chat de $t está trabajando o te espera: sigue con la cuenta anterior hasta que lo relances"; return 1 ;;
  esac
  case "$sid" in ""|bk-*) info "no sé qué conversación retoma el chat de $t: no lo cierro (abrí uno nuevo, ya sale con la cuenta nueva)"; return 1 ;; esac
  if [ "$acct" = default ]; then cmd="env -u CLAUDE_CONFIG_DIR -u BK_ACCOUNT_CLAUDE claude --resume $sid"
  else kv=$(python3 "$ACCOUNTS" env "$acct") || return 1; cmd="env $kv BK_ACCOUNT_CLAUDE=$acct claude --resume $sid"; fi
  hd_hc send "$t" "/exit" >/dev/null 2>&1 || { info "no pude cerrar el Claude de $t"; return 1; }
  for i in $(seq $(( ${BK_RELAUNCH_WAIT:-10} * 5 ))); do
    [ "$(hd_hc get "$t" --json 2>/dev/null | jq -r '.status.app // ""')" = claude-code ] || break
    sleep 0.2
  done
  # Si Claude sigue abierto, el comando le llegaría como un mensaje: mejor no mandarlo
  [ "$(hd_hc get "$t" --json 2>/dev/null | jq -r '.status.app // ""')" != claude-code ] \
    || { info "el Claude de $t no salió: no lo relanzo (salí con /exit y corré $cmd)"; return 1; }
  hd_hc send "$t" "$cmd" >/dev/null 2>&1 || { info "no pude volver a abrir Claude en $t: corré $cmd"; return 1; }
  local lab="$acct"; [ "$acct" != default ] || lab=""
  hd_hc label "$t" "bk.account=$lab" >/dev/null 2>&1 || true
  info "chat de $t relanzado con la cuenta $acct (retoma $sid)"
}

# hd_workspace [carpeta]: el espacio del proyecto de esa carpeta con su chat. Si ya está, lo muestra; si se le
# cerró el chat, le pone uno nuevo.
hd_workspace() {
  if [ "$DRY" -eq 1 ]; then
    info "(dry-run: abriría el espacio $(project_of "${1:-$PWD}" 2>/dev/null) de Herdr en ${1:-$PWD})"
    return 0
  fi
  local dir top name sp t
  dir=$(cd "${1:-$PWD}" && pwd) || die "no existe $1"
  top=$(project_top "$dir"); name=$(project_of "$dir")
  hd_up
  sp=$(hd_space_id "$name")
  t=$(hd_chat_term "$name")
  if [ -z "$sp" ] || [ -z "$t" ]; then hd_chat "$name" "$name" chat "$dir" "$top"; return; fi
  hd_go "$t"
  info "→ $name (ya estaba abierto)"
}

# hd_go <terminal>: mostrar su pestaña
hd_go() {
  local t="$1" sp tab
  IFS='|' read -r sp tab < <(hd_hc get "$t" --json 2>/dev/null | jq -r '[.labels["herdr.space"] // "", .labels["herdr.tab"] // ""] | join("|")' 2>/dev/null) || true
  [ -n "$tab" ] || die "no encuentro la pestaña de $t en Herdr"
  hd_up
  hd_show "$sp" "$tab"
  hd_app do pane.focus --terminal "$t" >/dev/null 2>&1 || true
}

# hd_chat_cmd: bk chat [--suelto | --rama <nombre> | --desde <chat> | --nombre <X>] con Herdr
hd_chat_cmd() {
  local loose=0 branch="" want_branch=0 from="" top name dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --suelto) loose=1; shift ;;
      --desde) from="${2:-}"; [ -n "$from" ] || die "bk chat --desde <chat|sesión>   (los resumenes listos: bk handoff --listos)"; shift 2 ;;
      --nombre) export BK_WS_NAME="${2:?--nombre necesita un nombre}"; shift 2 ;;
      --rama) want_branch=1; branch="${2:-}"; [ $# -ge 2 ] && shift 2 || shift ;;
      --carpeta) dir="${2:?--carpeta necesita una carpeta}"; shift 2 ;;
      *) break ;;
    esac
  done
  if [ -n "$from" ]; then hd_chat_from "$from"; return; fi
  if [ -n "$dir" ]; then
    # Un chat en esa carpeta (el worktree de una rama, desde alt+b): su espacio <proyecto>-<carpeta>, como --rama
    [ -d "$dir" ] || die "no existe la carpeta $dir"
    dir=$(cd "$dir" && pwd -P); top=$(project_top "$dir"); name="$(project_of "$top")-$(basename "$dir")"
    [ "$DRY" -eq 1 ] && { info "(dry-run: abriría el espacio $name de Herdr en $dir)"; return 0; }
    [ -z "$(hd_chat_term "$name")" ] || { hd_go "$(hd_chat_term "$name")"; info "→ $name (ya estaba abierto)"; return; }
    hd_chat "$name" "$name" chat "$dir" "$top"
    return
  fi
  if [ "$loose" = 1 ]; then
    # Chat sin proyecto: en una carpeta propia (~/.bk/chats), así Claude no lee tu home ni pide confiar en ella
    top="$HOME/.bk/chats"
    [ "$DRY" -eq 1 ] && { info "(dry-run: abriría un chat sin proyecto en $top)"; return 0; }
    mkdir -p "$top"
    name=suelto; [ -z "$(hd_chat_term suelto)" ] || name=$(hd_free suelto)
    hd_chat "$name" chats "$name" "$top" "$top"
    return
  fi
  top=$(project_top "${BK_PROJECT:-$PWD}"); name=$(project_of "$top")
  if [ "$want_branch" = 1 ]; then
    # Una rama aparte: su worktree y su espacio (<proyecto>-<rama>), para varios cambios del proyecto sin pisarse
    chat_branch_wt "$top" "$branch"
    [ "$DRY" -eq 1 ] && { info "(dry-run: abriría el espacio $name-$CHAT_SLUG de Herdr en $CHAT_WT)"; return 0; }
    [ -z "$(hd_chat_term "$name-$CHAT_SLUG")" ] || { hd_go "$(hd_chat_term "$name-$CHAT_SLUG")"; info "→ $name-$CHAT_SLUG (ya estaba abierto)"; return; }
    hd_chat "$name-$CHAT_SLUG" "$name-$CHAT_SLUG" chat "$CHAT_WT" "$top"
    return
  fi
  # Otro chat del proyecto: una pestaña más de su espacio (chat-2, chat-3…)
  [ "$DRY" -eq 1 ] && { info "(dry-run: abriría otro chat en el espacio $name de Herdr)"; return 0; }
  local ws; ws=$(hd_free "$name")
  hd_chat "$ws" "$name" "chat-${ws##*-}" "$top" "$top"
}

# bk chat --desde <chat|sesión>: un chat nuevo del mismo proyecto que arranca con el resumen que dejó otro
# (lib/handoff.py). El resumen va como argumento de claude y el chat nuevo lo borra al tomarlo.
hd_chat_from() {
  local q="$1" row sid dir acct old top name ws
  row=$(python3 "$WS/lib/handoff.py" find "$q") \
    || die "no hay un resumen listo de «${q}» (bk handoff $q lo pide; los listos: bk handoff --listos)"
  IFS=$'\t' read -r sid dir acct old <<<"$row"
  [ -d "$dir" ] || die "la carpeta del resumen ya no existe: $dir"
  top=$(project_top "$dir"); name=$(project_of "$top")
  [ -z "${BK_ACCOUNT:-}" ] || acct="$BK_ACCOUNT"   # bk --account X chat --desde abra: manda la que pediste
  BK_ACCOUNT="$acct"
  WS_CHAT_CMD="p=\$(python3 $(sq "$WS/lib/handoff.py") take $(sq "$sid")) && claude -- \"\$p\" || claude"
  if [ "$DRY" -eq 1 ]; then printf '%s\t%s\t%s\t%s\n' "$name" "$dir" "$acct" "$WS_CHAT_CMD"; return; fi
  # Sigue siendo el mismo trabajo: el chat nuevo nace con el nombre del viejo y en qué quedó, y queda unido a él
  # (bk.from) para que la barra de agentes lo muestre en su lugar. El resumen se lee ahora: el chat nuevo lo
  # borra apenas arranca. Un nombre puesto a mano pasa como nombre a mano (bk name o doble clic lo cambian); uno
  # automático pasa como automático, y lib/names.py lo sigue actualizando si el tema cambia.
  local oldt="" hand="" auto="" title="" status=""
  [ -z "$old" ] || oldt=$(hd_chat_term "$old")
  if [ -n "$oldt" ]; then hand=$(hd_label "$oldt" bk.name); auto=$(hd_label "$oldt" bk.autotitle); fi
  { IFS= read -r title; IFS= read -r status; } < <(python3 "$WS/lib/handoff.py" brief "$sid" 2>/dev/null) || true
  HD_LABELS=()
  if [ -n "$hand" ] && [ -z "${BK_WS_NAME:-}" ]; then BK_WS_NAME="$hand"
  elif [ -n "${auto:-$title}" ]; then HD_TAB="${auto:-$title}"; HD_LABELS+=("bk.autotitle=$HD_TAB"); fi
  [ -z "$status" ] || HD_LABELS+=("bk.status=sigue: $status")
  [ -z "$oldt" ] || HD_LABELS+=("bk.from=$oldt")
  ws=$(hd_free "$name")
  hd_chat "$ws" "$name" "chat-${ws##*-}" "$dir" "$top"
  [ -z "$oldt" ] || [ -z "${HD_NEW_TERM:-}" ] || hd_hc label "$oldt" "bk.next=$HD_NEW_TERM" >/dev/null 2>&1 || true
  info "→ $ws sigue desde ${old:-$sid}, con la cuenta $acct. El chat viejo queda debajo del nuevo en la barra: cerralo cuando quieras"
}

# bk name ["nombre" | -]: el nombre del chat de esta terminal (la etiqueta bk.name y el de su pestaña)
hd_name() {
  local t="${HC_TERMINAL_ID:-}" tab
  [ -n "$t" ] && [ "$(hd_label "$t" bk.kind)" = chat ] || die "bk name va desde un chat de bk en Herdr"
  if [ $# -eq 0 ]; then hd_label "$t" bk.name; return; fi
  tab=$(hd_label "$t" herdr.tab)
  if [ "$1" = - ]; then
    hd_hc label "$t" bk.name= >/dev/null 2>&1 || true
    [ -z "$tab" ] || hd_app do tab.rename "$(jq -cn --arg id "$tab" '{id: $id, name: ""}')" >/dev/null 2>&1 || true
    info "sin nombre: $(hd_label "$t" bk.win)"; return
  fi
  hd_hc label "$t" "bk.name=$*" >/dev/null || die "no pude nombrar el chat"
  [ -z "$tab" ] || hd_app do tab.rename "$(jq -cn --arg id "$tab" --arg name "$*" '{id: $id, name: $name}')" >/dev/null 2>&1 || true
  info "$(hd_label "$t" bk.win) se llama «$*» (bk say/go $*)"
}

# bk open [proyecto|ruta]: el espacio de ese proyecto. Sin argumento: los espacios abiertos.
hd_open() {
  local q="${1:-}" dir
  if [ -z "$q" ]; then
    need_herdr
    hd_app ls 2>/dev/null | jq -r '.spaces[]? | "  \(.name)\t\(.tabs | length) pestañas\t\(.folder)"' | column -t -s $'\t'
    echo; info "bk open <proyecto|ruta> abre (o muestra) el espacio de ese proyecto"
    return
  fi
  dir=$(resolve_project "$q") || dir=""   # sin el ||, set -e cortaba acá y bk salía con 1 sin decir nada
  [ -n "$dir" ] || die "no encuentro el proyecto '$q' (pasá la ruta, o bk open para ver los abiertos)"
  hd_workspace "$dir"
}

# bk stop <agente>: cierra su terminal (con ella se va su pestaña) y limpia su estado
hd_stop() {
  local win="$1" t td f
  t=$(hd_term_of_win "$win"); [ -n "$t" ] || die "no encuentro la terminal de $win en Herdr"
  td=$(python3 "$TASKS" find --window "$win" 2>/dev/null || true)
  [ -z "$td" ] || python3 "$TASKS" cancel "$td" >/dev/null
  hd_hc kill "$t" >/dev/null 2>&1 || die "Herdr no cerró $win ($t)"
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] && [ "$(jq -r '.pane // ""' "$f" 2>/dev/null)" = "$t" ] && rm -f "$f"
  done
  info "cerrada $win (el worktree, si había, queda: cleanup.sh lo limpia cuando el issue cierre)"
}

# ---------- números fijos de ventana ----------
# Cada chat o agente de Herdr toma al aparecer el número libre más chico (etiqueta bk.id) y lo conserva hasta
# cerrarse, como los workspaces de tmux (ws_ids): alt+N va a esa ventana, bk go N la muestra y bk say N "…" le
# escribe. Los reparte hd_adopt, que corre al lanzar (hd_chat, launch) y cuando la barra de Herdr ve una
# terminal de agente sin número (bk _adopt).
HD_IDS_LOCK="${BK_HD_IDS_LOCK:-$HOME/.cache/bk/herdr-ids.lock}"

# hd_id_term <n>: la terminal viva con ese número (vacío si no hay)
hd_id_term() { hd_find "bk.id=$1" | head -1; }

# hd_id_give <terminal>: su número; si no tiene, el libre más chico. Con candado: dos chats que nacen juntos
# no toman el mismo.
hd_id_give() {
  local t="$1" n i k=1
  n=$(hd_label "$t" bk.id); [ -z "$n" ] || { printf '%s' "$n"; return 0; }
  mkdir -p "${HD_IDS_LOCK%/*}"
  for i in $(seq 40); do
    mkdir "$HD_IDS_LOCK" 2>/dev/null && break
    # un candado de más de 10 s es de un proceso que murió
    [ -z "$(find "$HD_IDS_LOCK" -maxdepth 0 -mmin +0.17 2>/dev/null)" ] || rmdir "$HD_IDS_LOCK" 2>/dev/null
    sleep 0.1
  done
  n=$(hd_label "$t" bk.id)
  if [ -z "$n" ]; then
    while [ -n "$(hd_id_term "$k")" ]; do k=$((k + 1)); done
    n="$k"
    hd_hc label "$t" "bk.id=$n" >/dev/null 2>&1 || n=""
  fi
  rmdir "$HD_IDS_LOCK" 2>/dev/null
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# hd_adopt <terminal>: que bk conozca esa terminal. Un agente abierto desde Herdr (el + de las pestañas: un
# claude o un codex sin etiquetas de bk) pasa a ser un chat de su proyecto (<proyecto>, <proyecto>-2…), así
# bk ls, bk say, bk go y bk handoff andan con él igual que con los que abre bk chat. Y le da su número.
# Imprime el número. No toca lo que no es un agente con pestaña (una shell, un popup, un subagente).
# Vale también para el agente de otra máquina de Herdr (omarchy/t28): las etiquetas y los números se reparten
# acá, así no se repiten entre máquinas.
hd_adopt() {
  local t="$1" j kind dir top name ws
  j=$(hd_hc get "$t" --json 2>/dev/null) || return 1
  [ "$(jq -r '.state // ""' <<<"$j" 2>/dev/null)" = live ] || return 0
  kind=$(jq -r '.labels["bk.kind"] // ""' <<<"$j" 2>/dev/null)
  case "$kind" in
    chat|agent) ;;
    "")
      [ -n "$(jq -r '.labels["herdr.tab"] // ""' <<<"$j")" ] || return 0
      [ -n "$(jq -r '.status.app // ""' <<<"$j")" ] || return 0
      dir=$(jq -r '.cwd // ""' <<<"$j")
      case "$t" in
        */*)   # de otra máquina (<máquina>/<t>): la carpeta es de allá, así que el proyecto se le pregunta a
               # ella; si no tiene bk o no responde, el nombre de la carpeta
          [ -n "$dir" ] || return 0
          name=$(hd_hc exec --on "${t%%/*}" --timeout 8 bk _project "$dir" 2>/dev/null | head -1) || name=""
          [ -n "$name" ] || name=$(basename "$dir" | tr '.:' '__') ;;
        *)
          [ -d "$dir" ] || return 0
          top=$(project_top "$dir"); name=$(project_of "$top") ;;
      esac
      ws="$name"; [ -z "$(hd_chat_term "$name")" ] || ws=$(hd_free "$name")
      hd_hc label "$t" bk.kind=chat "bk.win=$ws" "bk.project=$name" bk.adopted=1 >/dev/null 2>&1 || return 1 ;;
    *) return 0 ;;
  esac
  hd_id_give "$t"
}

# hd_id_win <n>: la ventana de bk con ese número, como la entienden go y say (i42, o chat:<nombre>)
hd_id_win() {
  local t; t=$(hd_id_term "$1"); [ -n "$t" ] || return 1
  case "$(hd_label "$t" bk.kind)" in
    chat) printf 'chat:%s' "$(hd_label "$t" bk.win)" ;;
    *)    printf '%s' "$(hd_label "$t" bk.win)" ;;
  esac
}
