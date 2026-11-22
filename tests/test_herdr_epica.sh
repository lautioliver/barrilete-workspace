#!/usr/bin/env bash
# La épica del chat enfocado en la barra de agentes: bk _epica (lib/herdr_epica.py) con un gh falso, y el bloque
# ÉPICA de herdr/mods/agentes en node con Herdr falso. HOME y caché en un directorio temporal; no abre ventanas.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
TMP=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" BK_CACHE_DIR="$TMP/cache"
unset BK_BACKEND BK_PROJECT GIT_DIR GIT_WORK_TREE
mkdir -p "$HOME" "$TMP/fake"
# gh falso: #10 es la épica (sub-issues 2/5) de #11; #12 no tiene épica; #13 es épica sin padre. Sin red: falla.
# Los sub-issues de #10: #11 abierto, #12 cerrado y o/x#5 (otro repo), bloqueado por #11 (abierto) y #12 (cerrado).
# #21 tiene su épica en otro repo: o/k#20.
cat >"$TMP/fake/gh" <<FAKE
#!/bin/sh
echo "\$*" >>"$TMP/gh.log"
[ -f "$TMP/sin-red" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
case "\$2" in
  repos/o/r/issues/11/parent) echo '{"number":10,"title":"La épica","sub_issues_summary":{"completed":2,"total":5}}' ;;
  repos/o/r/issues/13) echo '{"number":13,"title":"Otra épica","sub_issues_summary":{"completed":1,"total":3}}' ;;
  repos/o/r/issues/12) echo '{"number":12,"title":"Suelto","sub_issues_summary":{"completed":0,"total":0}}' ;;
  repos/o/r/issues/21/parent) echo '{"number":20,"title":"Cruza","repository_url":"https://api.github.com/repos/o/k","sub_issues_summary":{"completed":0,"total":2}}' ;;
  repos/o/r/issues/10/sub_issues*) echo '[{"number":11,"title":"Once","state":"open","repository_url":"https://api.github.com/repos/o/r"},{"number":12,"title":"Doce","state":"closed","repository_url":"https://api.github.com/repos/o/r"},{"number":5,"title":"Cinco","state":"open","repository_url":"https://api.github.com/repos/o/x"}]' ;;
  repos/o/x/issues/5/dependencies/blocked_by) echo '[{"number":11,"state":"open","repository_url":"https://api.github.com/repos/o/r"},{"number":12,"state":"closed","repository_url":"https://api.github.com/repos/o/r"}]' ;;
  repos/o/r/issues/11/dependencies/blocked_by) echo '[]' ;;
  repos/o/r/issues/*/parent) echo '{"message":"No parent issue found","status":"404"}'; echo "gh: No parent issue found (HTTP 404)" >&2; exit 1 ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/fake/gh"; : >"$TMP/gh.log"
N=0; FAILED=0
check_eq() { N=$((N+1)); if [ "$1" = "$2" ]; then echo "ok $N - $3"; else echo "not ok $N - $3 (got '$1', want '$2')"; FAILED=$((FAILED+1)); fi; }
ep() { PATH="$TMP/fake:$PATH" "$ROOT/bin/bk" _epica "$@"; }
calls() { wc -l <"$TMP/gh.log" | tr -d ' '; }

REPO="$TMP/proj"; git init -q -b main "$REPO"; git -C "$REPO" remote add origin "git@github.com:o/r.git"
mkdir -p "$TMP/proj-wt"; git -C "$REPO" commit -q --allow-empty -m x; git -C "$REPO" worktree add -q -b w "$TMP/proj-wt/11"

check_eq "$(ep "$REPO" claude/11-algo | jq -c '{issue, repo, epic: (.epic | del(.subs, .dirs, .nolaunch))}')" '{"issue":11,"repo":"o/r","epic":{"repo":"o/r","number":10,"title":"La épica","done":2,"total":5}}' "rama claude/<n>-…: la épica es el padre del issue, con su avance"
check_eq "$(ep "$REPO" claude/feat/11-algo | jq -c '[.issue, .epic.number]')" '[11,10]' "rama claude/<tipo>/<n>-…"
check_eq "$(ep "$TMP/proj-wt/11" w | jq -c '[.issue, .epic.number]')" '[11,10]' "worktree <repo>-wt/<n>: el issue sale de la carpeta"
check_eq "$(ep "$REPO" main 'Arreglar el login #11' | jq -c '[.issue, .epic.number]')" '[11,10]' "en main, el #<n> del nombre del chat"
check_eq "$(ep "$REPO" claude/13-x | jq -c '[.issue, .epic.number, .epic.done, .epic.total]')" '[13,13,1,3]' "un issue con sub-issues es su propia épica"
check_eq "$(ep "$REPO" claude/12-x | jq -c .)" '{"issue":12,"repo":"o/r","epic":null}' "issue sin épica: epic null"
: >"$TMP/gh.log"
check_eq "$(ep "$REPO" main 'sin número' | jq -c .) $(calls)" '{"issue":null,"repo":null,"epic":null} 0' "sin issue: null y no le pregunta nada a GitHub"
check_eq "$(ep "$REPO" release/2026-11 | jq -c .issue)" 'null' "una rama sin <n>- no es un issue"

: >"$TMP/gh.log"; ep "$REPO" claude/11-algo >/dev/null; ep "$REPO" claude/12-x >/dev/null
check_eq "$(calls)" "0" "la segunda vez sale de la caché (también el «no tiene épica»): no vuelve a pedir"
python3 - "$BK_CACHE_DIR/epica.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
for v in c.values(): v["at"] -= 3600
json.dump(c, open(p, "w"))
PY
ep "$REPO" claude/11-algo >/dev/null
check_eq "$(calls)" "1" "vencida la caché, vuelve a preguntar"

touch "$TMP/sin-red"
python3 - "$BK_CACHE_DIR/epica.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
for v in c.values(): v["at"] -= 3600
json.dump(c, open(p, "w"))
PY
check_eq "$(ep "$REPO" claude/11-algo | jq -c '[.epic.number, .offline]')" '[10,null]' "sin red: lo último guardado, aunque esté vencido"
check_eq "$(ep "$REPO" claude/14-x | jq -c .)" '{"issue":14,"repo":"o/r","epic":null,"offline":true}' "sin red y sin nada guardado: null y offline"
rm "$TMP/sin-red"
check_eq "$(ep "$REPO" claude/14-x | jq -c .epic)" 'null' "el error de red no se guardó como «no tiene épica»: con red vuelve a preguntar"
check_eq "$(tail -1 "$TMP/gh.log")" "api repos/o/r/issues/14" "…y pregunta de verdad"

# Varios chats en una llamada (la barra pide los de todos los espacios juntos)
: >"$TMP/gh.log"; rm -f "$BK_CACHE_DIR/epica.json"
check_eq "$(ep --json "[[\"$REPO\",\"claude/11-a\",\"\"],[\"$REPO\",\"main\",\"nada\"],[\"$REPO\",\"claude/13-b\",\"\"],[\"$TMP/proj-wt/11\",\"w\",\"\"]]" | jq -c 'map(.epic.number)')" '[10,null,13,10]' "--json: una respuesta por chat, en el mismo orden"
check_eq "$(grep -c 'issues/11/parent' "$TMP/gh.log") $(calls)" "1 3" "--json: a GitHub una vez por issue (el #11 de dos chats, una vez; el #13, dos pedidos)"
check_eq "$(ep --json 'no es json' 2>&1; echo "rc=$?")" "bk _epica --json '[[carpeta, rama, texto, terminal], …]'
rc=1" "--json con algo que no es una lista: el uso, y falla"

# Los sub-issues de cada épica (la sección ÉPICAS y su popup): en su propia caché, aparte
export BK_CACHE_DIR="$TMP/cache-subs"; : >"$TMP/gh.log"; mkdir -p "$HOME/x"
E=$(ep "$TMP/proj-wt/11" w)
check_eq "$(jq -c '[.epic.subs[] | [.repo, .number, .state, .title, .blocked_by]]' <<<"$E")" '[["o/r",11,"open","Once",[]],["o/r",12,"closed","Doce",[]],["o/x",5,"open","Cinco",[{"repo":"o/r","number":11}]]]' "subs: los sub-issues de la épica (de otro repo también) y, de los abiertos, sus bloqueos abiertos"
check_eq "$(grep -c 'issues/12/dependencies' "$TMP/gh.log")" "0" "de un sub-issue cerrado no pide bloqueos"
check_eq "$(jq -c .repo <<<"$E")" '"o/r"' "cada chat dice el repo de su issue"
check_eq "$(jq -cS .epic.dirs <<<"$E")" "{\"o/r\":\"$REPO\",\"o/x\":\"$HOME/x\"}" "dirs: el checkout principal del chat (no su worktree) y ~/<nombre> para un repo sin chat"
check_eq "$(jq -cS '.epic.nolaunch | keys' <<<"$E")" '["o/r","o/x"]' "nolaunch: los repos sin barrilete-kit no se ofrecen para lanzar"
check_eq "$(jq -r '.epic.nolaunch["o/x"]' <<<"$E")" "x no es un proyecto Barrilete: no tiene barrilete-kit (.agent-kit.json)" "nolaunch: con el motivo en palabras"
mkdir -p "$HOME/x/scripts/agents" && : >"$HOME/x/scripts/agents/guardrails.py"
check_eq "$(ep "$TMP/proj-wt/11" w | jq -c '.epic.nolaunch | keys')" '["o/r"]' "nolaunch: un repo con el kit 2 (scripts/agents/guardrails.py) sí se puede lanzar"
rm -rf "$HOME/x"
check_eq "$(ep "$TMP/proj-wt/11" w | jq -c .epic.dirs)" "{\"o/r\":\"$REPO\"}" "…un repo sin chat ni carpeta en ~: sin dir (no se puede lanzar ahí)"
check_eq "$(ep "$REPO" claude/21-x | jq -c '[.epic.repo, .epic.number]')" '["o/k",20]' "la épica en otro repo: el repo sale de su repository_url, no del chat"
RESP="$TMP/resp"; git init -q -b main "$RESP"; git -C "$RESP" remote add respaldo "https://github.com/o/r.git"
check_eq "$(ep "$RESP" claude/11-a | jq -c '[.repo, .epic.number]')" '["o/r",10]' "sin origin, el único remoto de GitHub (el workspace tiene solo respaldo)"
: >"$TMP/gh.log"; ep "$REPO" claude/11-a >/dev/null
check_eq "$(grep -c 'sub_issues\|dependencies' "$TMP/gh.log")" "0" "los sub-issues salen de su caché: no vuelve a pedir"
age() { python3 - "$1" <<'PY2'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
for v in c.values(): v["at"] -= 3600
json.dump(c, open(p, "w"))
PY2
}
age "$BK_CACHE_DIR/epica-subs.json"; ep "$REPO" claude/11-a >/dev/null
check_eq "$(grep -c 'issues/10/sub_issues' "$TMP/gh.log")" "1" "vencida su caché, los vuelve a pedir"
touch "$TMP/sin-red"; age "$BK_CACHE_DIR/epica-subs.json"; age "$BK_CACHE_DIR/epica.json"
check_eq "$(ep "$REPO" claude/11-a | jq -c '[.epic.number, (.epic.subs | length)]')" '[10,3]' "sin red: los sub-issues guardados, aunque estén vencidos"
rm "$BK_CACHE_DIR/epica-subs.json"
check_eq "$(ep "$REPO" claude/11-a | jq -c '[.epic.number, (.epic | has("subs"))]')" '[10,false]' "sin red y sin sub-issues guardados: la épica sin subs (no una lista vacía)"
rm "$TMP/sin-red"; export BK_CACHE_DIR="$TMP/cache"

# La conversación de Claude de la terminal: un chat abierto en el checkout principal implementa en un worktree sin
# mover su carpeta, y la rama del checkout puede ser de otro chat. Manda el último worktree o prepare.sh de sus comandos.
export BK_PROJECTS="$TMP/projects"   # el estado de los chats: bin/bk lo lee de $HOME/.cache/sketchybar/agents
mkdir -p "$HOME/.cache/sketchybar/agents" "$BK_PROJECTS/p"
echo '{"pane":"t9","ts":1}' >"$HOME/.cache/sketchybar/agents/s9.json"
cmd() { jq -cn --arg c "$1" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}'; }
out() { jq -cn --arg c "$1" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"toolu_1",content:$c}]}}'; }   # como las de verdad: dice tool_use
{ cmd ".claude/skills/implement-issue/prepare.sh 12"; cmd "cd $TMP/proj-wt/13 && git status"; out "$TMP/proj-wt/11 [w] $TMP/proj-wt/14"; } >"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c '[.issue, .epic.number]')" '[13,13]' "conversación: el último worktree de sus comandos manda sobre la rama del checkout; lo que le respondieron no cuenta"
cmd "cd $REPO && bash .claude/skills/implement-issue/prepare.sh 12" >>"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c .issue)" '12' "…el último: prepare.sh <n> también"
cmd "ls $TMP/otro-wt/77 $TMP/proj-wt/15x" >>"$BK_PROJECTS/p/s9.jsonl"
cmd "echo 'corré prepare.sh 16' && python3 - <<'EOF'\nx = 'prepare.sh 17'\nEOF" >>"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c .issue)" '12' "el worktree de otro repo, uno que no es <n> o un prepare.sh nombrado en un texto (no corrido) no cuentan"
cmd "cd $TMP/proj-wt/19-0087 && git status" >>"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c .issue)" '12' "un worktree <n>-<dígitos> no es <n>-<descripción>: no cuenta"
cmd "cd $TMP/proj-wt/18-avisos && git status" >>"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c .issue)" '18' "conversación: un worktree <repo>-wt/<n>-<descripción> (como la rama del kit) también cuenta"
git -C "$REPO" worktree add -q -b w18 "$TMP/proj-wt/18-avisos"
check_eq "$(ep "$TMP/proj-wt/18-avisos" w18 | jq -c .issue)" '18' "carpeta: un chat en <repo>-wt/<n>-<descripción> tiene el issue <n>"
check_eq "$(ep "$TMP/proj-wt/11" w "" t9 | jq -c .issue)" '11' "un chat en su propio worktree: manda la carpeta"
check_eq "$(ep "$REPO" claude/11-algo "" t8 | jq -c .issue)" '11' "una terminal sin conversación: la rama, como antes"
: >"$BK_PROJECTS/p/s9.jsonl"
check_eq "$(ep "$REPO" claude/11-algo "" t9 | jq -c .issue)" '11' "una conversación sin worktree: la rama"
check_eq "$(jq -r 'keys[0]' "$BK_CACHE_DIR/epica-sesiones.json")" "$BK_PROJECTS/p/s9.jsonl" "guarda lo leído de cada conversación (por tamaño: no relee si no creció)"
unset BK_PROJECTS

# La sección ÉPICAS (herdr/mods/agentes), su popup y alt+p (herdr/mods/bk), con Herdr falso
node --input-type=module - "$ROOT" <<'JS' && { N=$((N+1)); echo "ok $N - mod: la sección ÉPICAS, su popup, lanzar y alt+p"; } || { N=$((N+1)); FAILED=$((FAILED+1)); echo "not ok $N - mod: la sección ÉPICAS, su popup, lanzar y alt+p"; }
import fs from 'node:fs';
import assert from 'node:assert/strict';
const root = process.argv[2];
const load = (f, name) => fs.readFileSync(`${root}/herdr/mods/${f}/main.js`, 'utf8')
  .replace(/^import [\s\S]*?;$/gm, '').replace(`export default class ${name}`, `class ${name}`);
const node = () => {
  const n = { $id: null, $kids: [], $click: null, $tip: null, $color: [], $bg: [], $key: null, $hover: null, $cut: false };
  const p = new Proxy(n, { get: (o, k) => {
    if (typeof k === 'string' && k.startsWith('$')) return o[k];
    if (k === 'then') return undefined;   // que await no lo tome por una promesa
    return (...a) => {
      if (k === 'id') o.$id = a[0];
      else if (k === 'child') o.$kids.push(a[0]);
      else if (k === 'children') o.$kids.push(...a[0]);
      else if (k === 'when' && a[0]) a[1](p);
      else if (k === 'on_click') o.$click = a[0];
      else if (k === 'on_key_down') o.$key = a[0];
      else if (k === 'tooltip') o.$tip = a[0];
      else if (k === 'text_color') o.$color.push(a[0]);
      else if (k === 'bg') o.$bg.push(a[0]);
      else if (k === 'truncate') o.$cut = true;
      return p;
    };
  } });
  return p;
};
const walk = (n, out = []) => { if (n && n.$kids) { out.push(n); for (const k of n.$kids) walk(k, out); } return out; };
const text = (n) => walk(n).flatMap((x) => x.$kids).filter((k) => typeof k === 'string');
const find = (out, id) => walk(out).find((x) => x.$id === id);
const ids = (out, re) => walk(out).map((x) => x.$id).filter((i) => re.test(i ?? ''));

let AG = [], narrowNow = false, reply = null, execs = [], store = {}, shared = {}, overlays = [], closed = [], runs = [], P = {}, focusedT = null, notes = [];
const T = { foreground: 'FG', muted: 'MUT', dim: 'DIM', accent: 'ACC', done: 'DONE', working: 'WORK', raised: 'RAI', blocked: 'BLK' };
const SP = [{ id: 's1', name: 'abra', tabs: [] }, { id: 's2', name: 'otro', tabs: [] }, { id: 's3', name: 'vacio', tabs: [] }];
let runReply = { code: 0, stdout: '', stderr: '' };
const deps = {
  View: class {}, div: node, svg: node, h_flex: node, v_flex: node,
  agents: () => AG, terminals: () => AG.map((a) => ({ address: a.address, state: 'live', labels: a.labels ?? {} })),
  focused: () => focusedT, panes: () => AG.map((a) => ({ pane: a.pane, cwd: a.cwd, branch: a.branch, title: a.title })),
  spaces: () => SP, run: (...a) => runs.push(a), theme: () => new Proxy(T, { get: (o, k) => o[k] ?? '#000' }),
  shared: (k) => shared[k], setShared: (k, v) => { shared[k] = JSON.parse(JSON.stringify(v)); },
  setAgentOrder: () => {}, openOverlay: (o) => { overlays.push(o); return 'ov1'; }, closeOverlay: (id) => closed.push(id), props: () => P, window: () => ({}), layout: () => ({}),
  exec: async (cmd, args, opts) => {
    execs.push([cmd, ...args, ...(opts?.cwd ? [`cwd=${opts.cwd}`] : [])]);
    if (args[0] === '_subagents') return { code: 0, stdout: '{"by_terminal":{}}' };
    if (args[0] === '_epica') return reply(JSON.parse(args[2]));
    if (args[0] === '_do') return runReply;
    return { code: 0, stdout: '' };
  },
  home: () => '/h', ICONS: '', PROSE: '', RANK: { blocked: 4, done: 3, working: 2, idle: 1 }, al: (c) => c,
  find: () => ({ size: { px: 300 } }),
  narrow: () => narrowNow, ago: () => '1m', ids: () => new Map(), said: (t) => t, picto: () => null, mark: () => '', keycap: () => '',
  iconButton: (t, id, icon, action) => node().id(id).on_click(action), rule: (t, label, right = []) => node().id(`rule-${label}`).child(label).children(right),
  // La lista de espacios (lista.js) y su diálogo (editar.js) tienen su test (test_espacios.sh): acá, con su regla y su lista, sin filas
  Lista: class { section(t) { return [deps.rule(t, 'ESPACIOS'), node().id('sp-list')]; } railSection() { return []; } }, menu: () => {}, Editar: class {},
};
const Agents = new Function(...Object.keys(deps), load('agentes', 'Agents') + '\nreturn Agents;')(...Object.values(deps));
globalThis.localStorage = { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = v; }, removeItem: (k) => { delete store[k]; } };
let pending = [];
let focuses = 0; const afters = [];
const cx = { spawn(f) { pending.push(f(cx)); }, timer: { every() {}, after(ms, f) { afters.push(f); } }, notify() {}, stop_propagation() {}, focus_handle: () => ({ focus() { focuses++; } }) };
const settle = async () => { while (pending.length) await pending.shift(); };
const epicCalls = () => execs.filter((e) => e[1] === '_epica');
const draw = async (v) => { v.render(cx); await settle(); return v.render(cx); };
const agent = (address, space, cwd, branch, title, labels) => ({ address, space, space_name: space, pane: `p-${address}`, tab: `tab-${address}`, status: 'idle', cwd, branch, title, labels, seq: 0 });

// #10 cruza dos repos: r#11 tiene agente (t1), r#12 está cerrado, r#15 espera a r#11, r#16 espera a r#15, x#5 está libre
const sub = (repo, number, state, blocked_by = []) => ({ repo, number, title: `Sub ${number}`, state, blocked_by });
const E10 = { repo: 'o/r', number: 10, title: 'La épica', done: 1, total: 5, dirs: { 'o/r': '/h/r', 'o/x': '/h/x' },
  subs: [sub('o/r', 11, 'open'), sub('o/r', 12, 'closed'), sub('o/r', 15, 'open', [{ repo: 'o/r', number: 11 }]),
    sub('o/r', 16, 'open', [{ repo: 'o/r', number: 15 }]), sub('o/x', 5, 'open')] };
const E13 = { repo: 'o/r', number: 13, title: 'Otra', done: 2, total: 3 };   // sin subs todavía: la barra con done/total
const BY = { 'claude/11-a': [11, E10], 'claude/10-e': [10, E10], 'claude/14-c': [14, E13] };
reply = (qs) => ({ code: 0, stdout: JSON.stringify(qs.map(([, b]) => (BY[b] ? { issue: BY[b][0], repo: 'o/r', epic: BY[b][1] } : { issue: null, repo: null, epic: null }))) });

AG = [agent('t1', 's1', '/abra', 'claude/11-a', 'uno'), agent('t2', 's1', '/abra', 'main', 'dos', { 'bk.name': 'Dos' }), agent('t3', 's2', '/otro', 'main', 'tres')];
let v = new Agents(); v.init({}, cx); await settle();
let out = await draw(v);
assert.deepEqual(epicCalls()[0], ['bk', '_epica', '--json', JSON.stringify([['/abra', 'claude/11-a', 'uno', 't1'], ['/abra', 'main', 'Dos dos', 't2'], ['/otro', 'main', 'tres', 't3']])], 'una sola llamada con carpeta, rama y nombre de cada chat');
assert.deepEqual(ids(find(out, 'sp-list'), /^epic-/), [], 'las épicas ya no van debajo de los espacios');
const order = walk(out).map((x) => x.$id).filter((i) => /^(rule-|sp-list|epic-list)/.test(i ?? ''));
assert.deepEqual(order, ['rule-ESPACIOS', 'sp-list', 'rule-ÉPICAS', 'epic-list', 'rule-AGENTES'], 'la sección ÉPICAS va entre ESPACIOS y AGENTES');
assert.deepEqual(ids(out, /^epic-o/), ['epic-o/r#10'], 'una tarjeta por épica');
let c = find(out, 'epic-o/r#10');
assert.deepEqual(text(c), ['#10', 'La épica', '1/5', 'ahora ', 'r#11 · t1', ' · destraba 2', ' · 1 libre', 'r 1/4 · x 0/1'], 'la tarjeta: #N título k/n, qué corre, qué destraba, cuántos libres y el avance por repo');
const segs = c.$kids[1].$kids.map((k) => k.$bg[0]);
assert.deepEqual(segs, ['DONE', 'WORK', 'ACC', 'RAI', 'RAI'], 'la barra: un segmento por sub-issue, hecho / con agente / libre / bloqueado');
const meta = find(out, 'ag-t1');
assert.ok(text(meta).includes('#11 de #10'), 'la fila del agente dice «#11 de #10»');
assert.ok(!text(find(out, 'ag-t2')).some((s) => / de #/.test(s)), 'un chat sin épica no lo dice');
assert.equal(shared['bk.epics'].byTerminal.t1, 'o/r#10', 'shared bk.epics: la épica de cada terminal (para alt+p)');
assert.ok(shared['bk.epics'].epics['o/r#10'].height > 200, 'y el alto del popup');
await draw(v); await draw(v);
assert.equal(epicCalls().length, 1, 'los mismos chats: no vuelve a preguntar en cada dibujo');

// Clic en la tarjeta: el popup junto a ella
c.$click();
assert.deepEqual([overlays.at(-1).mod, overlays.at(-1).kind, overlays.at(-1).props, overlays.at(-1).at.x], ['bk-agentes', 'popup', { epic: 'o/r#10' }, 306], 'clic: el popup de esa épica, a la derecha de la barra');

// Sin libres: «N libres: …» cuando nadie trabaja; la épica sin subs, con done/total
AG = [agent('t4', 's2', '/otro', 'claude/14-c', 'cuatro'), agent('t1', 's1', '/abra', 'main', 'uno')];
out = await draw(v);
assert.deepEqual(ids(out, /^epic-o/), ['epic-o/r#13', 'epic-o/r#10'], 'la del chat y la última vista de abra');
assert.deepEqual(find(out, 'epic-o/r#13').$kids[1].$kids.map((k) => k.$bg[0]), ['DONE', 'DONE', 'RAI'], 'sin sub-issues: la barra con done/total');
c = find(out, 'epic-o/r#10');
assert.ok(text(c).includes('la última vista · ningún chat la tiene ahora'), 'la última vista de un espacio lo dice');
assert.ok(c.$kids[1].$kids.every((k) => ['DIM', 'RAI'].includes(k.$bg[0])) && c.$kids[0].$kids.every((k) => k.$color.every((x) => x === 'DIM')), 'y va en gris');
AG = [agent('t2', 's1', '/abra', 'claude/10-e', 'dos')];
out = await draw(v);
assert.deepEqual(text(find(out, 'epic-o/r#10')).slice(3, 4), ['2 libres: r#11, x#5'], 'nadie trabaja en un sub-issue: cuáles están libres');
assert.ok(text(find(out, 'ag-t2')).includes('épica #10'), 'el chat que trabaja la épica misma: «épica #10»');

// Plegar la sección
find(out, 'epicas-fold').$click({}, cx);
out = await draw(v);
assert.deepEqual([ids(out, /^epic-o/), text(find(out, 'rule-ÉPICAS')).includes('2')], [[], true], 'plegada: sin tarjetas, dice cuántas (la de abra y la última vista de otro)');
find(out, 'epicas-fold').$click({}, cx);

// Orden: primero las que tienen algo LIBRE (#10: r#11 y x#5), después las demás en curso (#13, sin subs), al final la gris
AG = [agent('t4', 's2', '/otro', 'claude/14-c', 'cuatro'), agent('t2', 's1', '/abra', 'claude/10-e', 'dos')];
out = await draw(v);
assert.deepEqual(ids(out, /^epic-o/), ['epic-o/r#10', 'epic-o/r#13'], 'la que tiene libres va primero aunque su agente esté después');
assert.deepEqual(Object.keys(shared['bk.epics'].epics), ['o/r#10', 'o/r#13'], 'y en ese orden la comparte (el selector de alt+p)');
assert.ok(JSON.parse(store.epicsAt).s1 > 0 && JSON.parse(store.epicsAt).s2 > 0, 'guarda cuándo cada espacio tuvo su épica');

// Una sola gris: de los espacios sin épica ahora, la del que la tuvo más recientemente
AG = [agent('t1', 's1', '/abra', 'main', 'uno'), agent('t3', 's2', '/otro', 'main', 'tres')];
v.lastEpics = { s1: E10, s2: E13 }; v.lastAt = { s1: 100, s2: 200 };
out = await draw(v);
assert.deepEqual(ids(out, /^epic-o/), ['epic-o/r#13'], 'dos espacios sin épica: una sola gris, la más reciente (#13 de otro)');
v.lastAt = { s1: 300, s2: 200 };
out = await draw(v);
assert.deepEqual(ids(out, /^epic-o/), ['epic-o/r#10'], 'si la de abra es más reciente, queda esa');
assert.ok(text(find(out, 'epic-o/r#10')).includes('la última vista · ningún chat la tiene ahora'), 'y sigue en gris');

// El riel (angosto): sin épicas
narrowNow = true;
assert.equal(ids(await draw(v), /^epic-|rule-ÉPICAS/).length, 0, 'en el riel no hay épicas');
narrowNow = false;

// El popup: otra copia del mod con props { epic }, los datos de shared
AG = [agent('t1', 's1', '/abra', 'claude/11-a', 'uno')];
await draw(v);
P = { epic: 'o/r#10', overlay: 'ov9' };
afters.length = 0;
const pop = new Agents(); pop.init(P, cx);
focuses = 0; afters.forEach((f) => f());
assert.equal(focuses, 1, 'el popup vuelve a pedir el foco después de abrirse: abierto con clic, la terminal se lo saca y las teclas no llegan');
let o = pop.render(cx);
const rowsOf = (o) => ids(o, /^er-/);
assert.ok(!/epic-rows"\)\.flex_1/.test(load('agentes', 'Agents')), 'las filas del popup sin flex_1: en un popup quedan en alto cero');
assert.ok(/epic-rows"\)\.flex_none\(\)\.h\(listH\)\.overflow_y_scrollbar\(\)/.test(load('agentes', 'Agents')), 'las filas del popup con alto en px y scroll: HECHOS desplegado no tapa el pie');
assert.deepEqual(text(o).filter((s) => /^(AHORA|LIBRES|BLOQUEADOS|HECHOS)$/.test(s)), ['AHORA', 'LIBRES', 'BLOQUEADOS', 'HECHOS'], 'grupos AHORA, LIBRES, BLOQUEADOS y HECHOS');
assert.deepEqual(rowsOf(o), ['er-o/r#11', 'er-o/x#5', 'er-o/r#15', 'er-o/r#16'], 'HECHOS empieza plegado');
assert.ok(text(o).includes('camino más largo: r#11 → r#15 → r#16 · 3 pasos'), 'el camino más largo');
assert.ok(text(o).includes('espera r#11') && text(o).includes('espera r#15'), 'cada bloqueado dice qué espera');
assert.ok(text(o).includes('1 · r#12'), 'HECHOS plegado dice cuáles');
const key = (k) => { o.$key({ key: k }, cx); o = pop.render(cx); };
key('enter');
assert.deepEqual([runs.at(-1), closed.at(-1)], [['pane.focus', { terminal: 't1' }], 'ov9'], '⏎ en uno con agente: su pane, y cierra');
key('down'); key('g');
assert.deepEqual(execs.at(-1), ['open', 'https://github.com/o/x/issues/5'], 'g: el elegido en GitHub');
const opened = execs.length; key('down'); key('enter');
assert.equal(find(o, 'epic-confirm'), undefined, '⏎ en un bloqueado: no lanza');
assert.equal(execs.length, opened, '⏎ en un bloqueado: tampoco abre GitHub (eso es g)');
key('l');
assert.equal(find(o, 'epic-confirm'), undefined, 'la l ya no lanza');
key('up'); key('enter');
assert.ok(text(find(o, 'epic-confirm')).includes('bk run 5 · en ~/x'), '⏎ en un libre: la confirmación con el comando y la carpeta de su repo');
key('escape');
assert.equal(find(o, 'epic-confirm'), undefined, 'esc cancela la confirmación (no cierra)');
// Un repo con un kit viejo (nolaunch): ni «Lanzar» ni confirmación, y el motivo a la vista
const sharedE = () => shared['bk.epics'].epics['o/r#10'].e;
sharedE().nolaunch = { 'o/x': 'x tiene el kit 0.9.0: para lanzar agentes hace falta barrilete-kit 2 o más nuevo. Actualizá el kit de x' };
o = pop.render(cx);
const tried = execs.length;
assert.ok(!find(o, 'launch-o/x#5') && text(o).includes('no se puede lanzar') && text(find(o, 'epic-nolaunch')).join(' ').startsWith('x tiene el kit 0.9.0: para lanzar'), 'kit viejo: la fila dice que no se puede y debajo, por qué');
assert.equal(find(o, 'epic-nolaunch').$cut, false, 'kit viejo: el motivo va entero, en varios renglones si hace falta, no cortado con …');
key('enter'); key('enter');
assert.deepEqual([find(o, 'epic-confirm'), execs.length], [undefined, tried], 'kit viejo: ⏎ no pide confirmar ni lanza');
delete sharedE().nolaunch; o = pop.render(cx);
assert.ok(find(o, 'launch-o/x#5') && !find(o, 'epic-nolaunch'), 'con el kit al día, vuelve «Lanzar»');
key('enter'); runReply = { code: 1, stdout: '', stderr: 'algo\nprepare.sh rechazó #5\n' };
key('enter');
const shut = closed.length; for (let i = 0; i < 2; i++) { o.$key({ key: 'escape' }, cx); o = pop.render(cx); }
assert.ok(closed.length === shut && text(o).includes('lanzando…'), 'mientras bk _do arranca, esc espera y la fila dice «lanzando…»');
await settle(); o = pop.render(cx);
assert.deepEqual(execs.at(-1), ['bk', '_do', '--cwd', '/h/x', '--title', 'Lanzar #5', '--', 'run', '5', 'cwd=/h/x'], '⏎ lanza: bk run N suelto (bk _do), en la carpeta de su repo');
assert.ok(text(o).includes('prepare.sh rechazó #5'), 'si falla, el error queda en la fila');
assert.equal(find(o, 'epic-err')?.$cut, false, 'el error del lanzamiento va entero, no cortado con …');
runReply = { code: 0, stdout: '', stderr: '' };
key('enter'); key('enter'); await settle(); o = pop.render(cx);
assert.ok(text(o).includes('lanzado') && !text(o).includes('prepare.sh rechazó #5'), 'si sale bien, «lanzado» y sin el error');
find(o, 'epic-done').$click({}, cx); o = pop.render(cx);
assert.deepEqual(rowsOf(o).at(-1), 'er-o/r#12', 'clic en HECHOS: se despliega');
const before = closed.length; key('escape');
assert.equal(closed.length, before + 1, 'esc cierra');

// alt+p (mods/bk, handle "epica"): el popup de la épica del chat enfocado
const Bk = new Function('View', 'div', 'hc', 'exec', 'run', 'props', 'openOverlay', 'closeOverlay', 'focused', 'terminals', 'spaces', 'agents', 'home', 'notify', 'shared', 'setShared', 'readTextFile',
  load('bk', 'Bk') + '\nreturn Bk;')(class {}, node, async () => ({}), deps.exec, deps.run, () => ({}), deps.openOverlay, deps.closeOverlay, () => focusedT,
  deps.terminals, deps.spaces, deps.agents, deps.home, (n) => notes.push(n), deps.shared, deps.setShared, async () => null);
focusedT = { terminal: 't1' };
await new Bk().handle('epica');
assert.deepEqual([overlays.at(-1).mod, overlays.at(-1).props, overlays.at(-1).height], ['bk-agentes', { epic: 'o/r#10' }, shared['bk.epics'].epics['o/r#10'].height], 'alt+p: la épica del chat enfocado, del alto justo');

// Un chat sin épica: con una sola en curso la abre; con varias, el selector
const two = { epics: { 'o/r#10': { e: E10, stale: false, height: 300 }, 'o/r#13': { e: E13, stale: true, height: 250 } }, byTerminal: { t1: 'o/r#10' }, pickHeight: 104 };
shared['bk.epics'] = { ...two, epics: { 'o/r#13': two.epics['o/r#13'] } };
focusedT = { terminal: 't9' };
await new Bk().handle('epica');
assert.deepEqual(overlays.at(-1).props, { epic: 'o/r#13' }, 'chat sin épica y una sola en curso: esa');
shared['bk.epics'] = two;
await new Bk().handle('epica');
assert.deepEqual([overlays.at(-1).mod, overlays.at(-1).kind, overlays.at(-1).props, overlays.at(-1).height], ['bk-agentes', 'dialog', { epicPick: true }, 104], 'chat sin épica y varias: el selector, del alto justo');
P = { epicPick: true, overlay: 'ov7' };
const pick = new Agents(); pick.init(P, cx);
let po = pick.render(cx);
assert.deepEqual(ids(po, /^pick-/), ['pick-o/r#10', 'pick-o/r#13'], 'el selector: una fila por épica, en el orden de la barra');
assert.deepEqual(text(find(po, 'pick-o/r#13')), ['#13', 'Otra', '2/3'], 'cada una con #N, título y avance');
po.$key({ key: 'down' }, cx); po = pick.render(cx);
po.$key({ key: 'enter' }, cx);
assert.deepEqual([closed.at(-1), overlays.at(-1).props, overlays.at(-1).height], ['ov7', { epic: 'o/r#13' }, 250], '↓ ⏎: cierra el selector y abre esa épica');

shared['bk.epics'] = { epics: {}, byTerminal: {} };
await new Bk().handle('epica');
assert.match(notes.at(-1).body, /ningún chat tiene una épica/, 'sin épicas: lo dice');
JS

echo "1..$N"
[ "$FAILED" -eq 0 ]
