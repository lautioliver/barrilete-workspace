#!/usr/bin/env bash
# OpenCode v2.3.2 BK guardrails adapter - isolated tests (no real home/model required for unit path).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/agents/tap.sh"
tap_begin "$0"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bk-opencode-test.XXXXXX")"
tap_at_exit "rm -rf '$TMP'"

# Nada de lo real: HOME, estado y cache van al tmp (land.py y task_events.py escriben bajo ~).
mkdir -p "$TMP/home"
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/home/state" XDG_CONFIG_HOME="$TMP/home/config" REPO="$ROOT"
unset BK_TASK_DIR BK_LAND_REPO BK_MAIN_OK BK_LANDING

NODE_TEST="$TMP/test.mjs"
cat > "$NODE_TEST" <<'NODE'
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const repo = process.env.REPO;
const mod = await import(pathToFileURL(path.join(repo, '.opencode/plugins/bk-guardrails/index.mjs')).href + '?t=' + Date.now());
const plugin = mod.default;

function mkctx(options = {}, dir = process.cwd()) {
  const hooks = { permission: [], shell: [], toolBefore: [], toolAfter: [], session: [] };
  const ctx = {
    options,
    location: { directory: dir, project: { directory: dir, canonical: dir } },
    permission: { hook: async (_n, cb) => hooks.permission.push(cb) },
    shell: { hook: async (_n, cb) => hooks.shell.push(cb) },
    tool: { hook: async (n, cb) => (n === 'execute.before' ? hooks.toolBefore : hooks.toolAfter).push(cb) },
    session: { hook: async (_n, cb) => hooks.session.push(cb) },
    event: { subscribe: () => ({}) },
  };
  return { ctx, hooks };
}

// Siempre sale con 0: cada caso se informa como "ok - <nombre>" o "not ok - <nombre>" y el test bash
// lo comprueba por nombre (un caso que no corre o falla no puede pasar desapercibido).
async function test(name, fn) {
  try { await fn(); console.log('ok - ' + name); }
  catch (e) { console.log('not ok - ' + name); console.error(e && e.stack || e); }
}

const scriptsOf = (...files) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bk-scripts-'));
  const scriptsDir = path.join(tmp, 'scripts/agents');
  fs.mkdirSync(scriptsDir, { recursive: true });
  fs.mkdirSync(path.join(tmp, 'lib'), { recursive: true });
  for (const f of files) fs.copyFileSync(path.join(repo, 'scripts/agents', f), path.join(scriptsDir, f));
  return { tmp, scriptsDir };
};

await test('plugin blocks git push via tool.execute.before', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'shell', input: { command: 'git push origin main' } }), /Blocked/);
});
await test('plugin blocks --no-verify via shell.create.before', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.shell[0]({ command: 'git commit -m x --no-verify', cwd: repo }), /--no-verify|skipping hooks|Blocked/i);
});
await test('plugin blocks git tag via tool.execute.before', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'shell', input: { command: 'git tag v1.0.0' } }), /Blocked/);
});
await test('plugin blocks gh pr merge via permission.evaluate', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  const ev = { action: 'shell', resources: ['gh pr merge 1'], effect: 'ask' };
  await hooks.permission[0](ev);
  assert.equal(ev.effect, 'deny');
  assert.match(String(ev.message), /Blocked/);
});
await test('plugin blocks gh release create via tool.execute.before', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'shell', input: { command: 'gh release create v1.0.0' } }), /Blocked/);
});
await test('plugin resolves scriptsDir explicitly outside repo cwd', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bk-sdir-'));
  const scriptsDir = path.join(tmp, 'scripts/agents');
  fs.mkdirSync(scriptsDir, { recursive: true });
  fs.copyFileSync(path.join(repo, 'scripts/agents/guardrails.py'), path.join(scriptsDir, 'guardrails.py'));
  fs.copyFileSync(path.join(repo, 'scripts/agents/task_events.py'), path.join(scriptsDir, 'task_events.py'));
  const elsewhere = fs.mkdtempSync(path.join(os.tmpdir(), 'bk-else-'));
  const { ctx, hooks } = mkctx({ scriptsDir }, elsewhere);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'shell', input: { command: 'git push origin main' } }), /Blocked/);
});
await test('plugin allows safe command', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  await hooks.toolBefore[0]({ tool: 'shell', input: { command: 'git status' } });
});
const FAKE_LAND = `#!/usr/bin/env python3
import sys, os, json
if sys.argv[1:] != ["hook"]:
    sys.stderr.write("land.py: uso desconocido: %r\\n" % sys.argv[1:])
    sys.exit(2)
ev = json.load(sys.stdin)
open(os.environ["LAND_LOG"], "a").write(json.dumps(ev) + "\\n")
if os.environ.get("LAND_DENY") and ev.get("hook_event_name") == "PreToolUse":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
        "permissionDecisionReason": "main está protegido: nadie edita su checkout."}}))
`;
const landSetup = () => {
  const { tmp, scriptsDir } = scriptsOf('guardrails.py', 'task_events.py');
  fs.writeFileSync(path.join(tmp, 'lib/land.py'), FAKE_LAND);
  process.env.LAND_LOG = path.join(tmp, 'land.log');
  return { tmp, scriptsDir };
};
await test('plugin runs land hook with the hook subcommand on edit', async () => {
  const { tmp, scriptsDir } = landSetup();
  const { ctx, hooks } = mkctx({ scriptsDir }, tmp);
  await plugin.setup(ctx);
  const fp = path.join(tmp, 'a.txt');
  await hooks.toolBefore[0]({ tool: 'edit', input: { file_path: fp } });
  await hooks.toolAfter[0]({ tool: 'edit', status: 'completed', input: { file_path: fp } });
  const lines = fs.readFileSync(process.env.LAND_LOG, 'utf8').trim().split(/\n+/).map(JSON.parse);
  assert.equal(lines.length, 2);
  assert.equal(lines[0].hook_event_name, 'PreToolUse');
  assert.equal(lines[1].hook_event_name, 'PostToolUse');
  assert.equal(lines[0].tool_input.file_path, fp);
  delete process.env.LAND_LOG;
});
await test('plugin blocks the edit when the land hook denies', async () => {
  const { tmp, scriptsDir } = landSetup();
  process.env.LAND_DENY = '1';
  const { ctx, hooks } = mkctx({ scriptsDir }, tmp);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'edit', input: { file_path: path.join(tmp, 'a.txt') } }), /main está protegido/);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'write', input: { file_path: path.join(tmp, 'b.txt') } }), /main está protegido/);
  delete process.env.LAND_DENY;
  delete process.env.LAND_LOG;
});
await test('plugin blocks a real edit of the main checkout through the real land.py', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bk-main-'));
  const git = (...a) => spawnSync('git', ['-C', dir, ...a], { encoding: 'utf8' });
  git('init', '-q', '-b', 'main');
  git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'init');
  fs.writeFileSync(path.join(dir, 'a.txt'), 'x');
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, dir);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'edit', input: { file_path: path.join(dir, 'a.txt') } }), /main está protegido/);
});
await test('plugin task events only with BK_TASK_DIR and relevant commands', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bk-task-'));
  const taskDir = path.join(tmp, 'task');
  fs.mkdirSync(taskDir, { recursive: true });
  fs.writeFileSync(path.join(taskDir, 'task.json'), JSON.stringify({id:'t1',created:'2026-01-01T00:00:00.000Z',status:'pending_approval',seq:0,updated:'2026-01-01T00:00:00.000Z'}));
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, tmp);
  const old = process.env.BK_TASK_DIR;
  process.env.BK_TASK_DIR = taskDir;
  await plugin.setup(ctx);
  await hooks.session[0]({ sessionID: 's1' });
  await hooks.toolAfter[0]({ tool: 'shell', status: 'completed', input: { command: 'git commit -m test' }, result: { output: '[main abc1234] test' } });
  await hooks.toolAfter[0]({ tool: 'shell', status: 'completed', input: { command: 'echo hi' }, result: { output: 'hi' } });
  const events = fs.readFileSync(path.join(taskDir, 'events.jsonl'), 'utf8').trim().split(/\n+/).map(JSON.parse);
  assert.ok(events.some(e => e.type === 'task.started'));
  assert.ok(events.some(e => e.type === 'commit'));
  assert.ok(!events.some(e => JSON.stringify(e).includes('echo hi')));
  if (old === undefined) delete process.env.BK_TASK_DIR; else process.env.BK_TASK_DIR = old;
});
await test('plugin no task events without BK_TASK_DIR', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bk-task2-'));
  const taskDir = path.join(tmp, 'task');
  fs.mkdirSync(taskDir, { recursive: true });
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, tmp);
  const old = process.env.BK_TASK_DIR;
  delete process.env.BK_TASK_DIR;
  await plugin.setup(ctx);
  await hooks.session[0]({ sessionID: 's1' });
  assert.ok(!fs.existsSync(path.join(taskDir, 'events.jsonl')));
  if (old === undefined) delete process.env.BK_TASK_DIR; else process.env.BK_TASK_DIR = old;
});
await test('plugin denies shell when guardrails.py is missing at setup', async () => {
  const { tmp, scriptsDir } = scriptsOf();
  const { ctx, hooks } = mkctx({ scriptsDir }, tmp);
  let failed = false;
  try { await plugin.setup(ctx); } catch { failed = true; }
  if (!failed) await assert.rejects(() => hooks.toolBefore[0]({ tool: 'shell', input: { command: 'git status' } }));
});
await test('plugin denies shell when guardrails.py crashes', async () => {
  const { tmp, scriptsDir } = scriptsOf();
  fs.writeFileSync(path.join(scriptsDir, 'guardrails.py'), 'import sys\nsys.exit(1)\n');
  const { ctx, hooks } = mkctx({ scriptsDir }, tmp);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'shell', input: { command: 'git status' } }), /guardrail/i);
  await assert.rejects(() => hooks.shell[0]({ command: 'git status', cwd: tmp }), /guardrail/i);
});
await test('plugin denies the permission when guardrails.py crashes', async () => {
  const { tmp, scriptsDir } = scriptsOf();
  fs.writeFileSync(path.join(scriptsDir, 'guardrails.py'), 'import sys\nsys.exit(1)\n');
  const { ctx, hooks } = mkctx({ scriptsDir }, tmp);
  await plugin.setup(ctx);
  const ev = { action: 'shell', resources: ['git status'], effect: 'allow' };
  await hooks.permission[0](ev);
  assert.equal(ev.effect, 'deny');
});
await test('plugin blocks bk say via tool.execute.before', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'shell', input: { command: 'bk say hola' } }), /Blocked|human/i);
});
await test('plugin blocks bk approve via tool.execute.before', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  await assert.rejects(() => hooks.toolBefore[0]({ tool: 'shell', input: { command: 'bk approve 3' } }), /Blocked|human/i);
});
await test('plugin allows bk land --wait and bk routing summary', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  await hooks.toolBefore[0]({ tool: 'shell', input: { command: 'bk land --wait' } });
  await hooks.toolBefore[0]({ tool: 'shell', input: { command: 'bk routing summary' } });
});
await test('plugin blocks git push when the tool is named bash or Bash', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  for (const tool of ['bash', 'Bash'])
    await assert.rejects(() => hooks.toolBefore[0]({ tool, input: { command: 'git push origin main' } }), /Blocked/);
});
await test('plugin blocks patch-style edit tools when the land hook denies', async () => {
  const { tmp, scriptsDir } = landSetup();
  process.env.LAND_DENY = '1';
  const { ctx, hooks } = mkctx({ scriptsDir }, tmp);
  await plugin.setup(ctx);
  for (const tool of ['multiedit', 'patch', 'apply_patch'])
    await assert.rejects(() => hooks.toolBefore[0]({ tool, input: { filePath: path.join(tmp, 'a.txt') } }), /main está protegido/);
  delete process.env.LAND_DENY;
  delete process.env.LAND_LOG;
});
await test('plugin setup fails loudly when no shell hook can be registered', async () => {
  const { ctx } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  delete ctx.shell; delete ctx.tool; delete ctx.permission;
  await assert.rejects(() => plugin.setup(ctx));
});
await test('plugin denies the permission when evaluating throws', async () => {
  const { ctx, hooks } = mkctx({ scriptsDir: path.join(repo, 'scripts/agents') }, repo);
  await plugin.setup(ctx);
  const ev = { action: 'shell', get resources() { throw new Error('forma rara'); }, effect: 'allow' };
  await hooks.permission[0](ev);
  assert.equal(ev.effect, 'deny');
});
NODE

node_out=""
tap_run node_out 0 node "$NODE_TEST"
tap_check $? "opencode-plugin-node-exits-clean" "el test de node terminó sin romperse"
node_out="$node_out"$'\n'   # $(...) se come el salto de línea final: sin esto el último caso nunca coincide

# Cada caso de node se comprueba por nombre: uno que no corre o que falla no pasa desapercibido.
node_case() { [[ "$node_out" == *$'\nok - '"$1"$'\n'* || "$node_out" == "ok - $1"$'\n'* ]]; }
node_case "plugin blocks git push via tool.execute.before"; tap_check $? "node case: plugin blocks git push via tool.execute.before"
node_case "plugin blocks --no-verify via shell.create.before"; tap_check $? "node case: plugin blocks --no-verify via shell.create.before"
node_case "plugin blocks git tag via tool.execute.before"; tap_check $? "node case: plugin blocks git tag via tool.execute.before"
node_case "plugin blocks gh pr merge via permission.evaluate"; tap_check $? "node case: plugin blocks gh pr merge via permission.evaluate"
node_case "plugin blocks gh release create via tool.execute.before"; tap_check $? "node case: plugin blocks gh release create via tool.execute.before"
node_case "plugin resolves scriptsDir explicitly outside repo cwd"; tap_check $? "node case: plugin resolves scriptsDir explicitly outside repo cwd"
node_case "plugin allows safe command"; tap_check $? "node case: plugin allows safe command"
node_case "plugin runs land hook with the hook subcommand on edit"; tap_check $? "node case: plugin runs land hook with the hook subcommand on edit"
node_case "plugin blocks the edit when the land hook denies"; tap_check $? "node case: plugin blocks the edit when the land hook denies"
node_case "plugin blocks a real edit of the main checkout through the real land.py"; tap_check $? "node case: plugin blocks a real edit of the main checkout through the real land.py"
node_case "plugin task events only with BK_TASK_DIR and relevant commands"; tap_check $? "node case: plugin task events only with BK_TASK_DIR and relevant commands"
node_case "plugin no task events without BK_TASK_DIR"; tap_check $? "node case: plugin no task events without BK_TASK_DIR"
node_case "plugin denies shell when guardrails.py is missing at setup"; tap_check $? "node case: plugin denies shell when guardrails.py is missing at setup"
node_case "plugin denies shell when guardrails.py crashes"; tap_check $? "node case: plugin denies shell when guardrails.py crashes"
node_case "plugin denies the permission when guardrails.py crashes"; tap_check $? "node case: plugin denies the permission when guardrails.py crashes"
node_case "plugin blocks bk say via tool.execute.before"; tap_check $? "node case: plugin blocks bk say via tool.execute.before"
node_case "plugin blocks bk approve via tool.execute.before"; tap_check $? "node case: plugin blocks bk approve via tool.execute.before"
node_case "plugin allows bk land --wait and bk routing summary"; tap_check $? "node case: plugin allows bk land --wait and bk routing summary"
node_case "plugin blocks git push when the tool is named bash or Bash"; tap_check $? "node case: plugin blocks git push when the tool is named bash or Bash"
node_case "plugin blocks patch-style edit tools when the land hook denies"; tap_check $? "node case: plugin blocks patch-style edit tools when the land hook denies"
node_case "plugin setup fails loudly when no shell hook can be registered"; tap_check $? "node case: plugin setup fails loudly when no shell hook can be registered"
node_case "plugin denies the permission when evaluating throws"; tap_check $? "node case: plugin denies the permission when evaluating throws"

# opencode.jsonc de verdad, normalizado por opencode (sin servicio: --standalone; HOME en el tmp)
if command -v opencode >/dev/null 2>&1; then
  cfg_out=$(cd "$ROOT" && opencode debug config --standalone 2>/dev/null); cfg_rc=$?
  tap_check $cfg_rc "opencode-config-debug-real" "opencode debug config carga el opencode.jsonc del repo"
  printf '%s' "$cfg_out" > "$TMP/config.json"
  cat > "$TMP/eval.py" <<'PY'
import json, re, sys
doc = next(d for d in json.load(open(sys.argv[1])) if d.get("path", "").endswith("opencode.jsonc"))
rules = doc["info"]["permissions"]
def rx(r): return re.compile("^" + re.escape(r).replace("\\*\\*", ".*").replace("\\*", ".*") + "$")
def effect(action, res):
    out = None   # la última regla que coincide gana
    for r in rules:
        if r["action"] == action and rx(r["resource"]).match(res):
            out = r["effect"]
    return out
for action, res, want in [l.split("|") for l in sys.argv[2:]]:
    got = effect(action, res)
    if got != want:
        print("FAIL %s %r: want %s got %s" % (action, res, want, got))
PY
  rule_check() { # id acción recurso efecto
    local out; out=$(python3 "$TMP/eval.py" "$TMP/config.json" "$2|$3|$4"); [ -z "$out" ]
  }
  rule_check x shell "git push origin main" deny; tap_check $? "config-real-deny-git-push" "git push → deny"
  rule_check x shell "git tag v1" deny; tap_check $? "config-real-deny-git-tag" "git tag → deny"
  rule_check x shell "gh release create v1" deny; tap_check $? "config-real-deny-release" "gh release create → deny"
  rule_check x shell "gh pr merge 1" deny; tap_check $? "config-real-deny-pr-merge" "gh pr merge → deny"
  rule_check x shell "git commit -m x --no-verify" deny; tap_check $? "config-real-deny-no-verify" "--no-verify → deny"
  rule_check x shell "bk say hola" deny; tap_check $? "config-real-deny-bk-say" "bk say → deny"
  rule_check x shell "bk approve 3" deny; tap_check $? "config-real-deny-bk-approve" "bk approve → deny"
  rule_check x shell "bk land --wait" allow; tap_check $? "config-real-allow-bk-land" "bk land --wait sigue permitido"
  rule_check x shell "gh workflow run x" ask; tap_check $? "config-real-ask-workflow" "gh workflow → ask"
  rule_check x shell 'bash -c "git push origin main"' ask; tap_check $? "config-real-ask-bash-interpreter" "bash -c ya no evade los deny"
  rule_check x shell 'sh -c "gh pr merge 3"' ask; tap_check $? "config-real-ask-sh-interpreter" "sh -c ya no evade los deny"
  rule_check x shell 'python3 -c "import os"' ask; tap_check $? "config-real-ask-python-interpreter" "python3 -c pregunta"
  rule_check x shell 'node -e "1"' ask; tap_check $? "config-real-ask-node-interpreter" "node -e pregunta"
  rule_check x edit "opencode.jsonc" ask; tap_check $? "config-real-ask-edit-opencode-config" "editar opencode.jsonc pregunta"
  rule_check x edit ".opencode/plugins/bk-guardrails/index.mjs" ask; tap_check $? "config-real-ask-edit-plugin" "editar el plugin pregunta"
  rule_check x edit "scripts/agents/guardrails.py" ask; tap_check $? "config-real-ask-edit-guardrails" "editar guardrails.py pregunta"
  rule_check x edit "githooks/reference-transaction" ask; tap_check $? "config-real-ask-edit-githooks" "editar githooks pregunta"
  rule_check x edit ".env" deny; tap_check $? "config-real-deny-env" ".env → deny"
  rule_check x edit ".github/workflows/ci.yml" ask; tap_check $? "config-real-ask-github" ".github/** → ask"
  rule_check x edit "package.json" ask; tap_check $? "config-real-ask-package-json" "package.json → ask"
else
  tap_skip "opencode-config-debug-real" "opencode no está instalado"
fi

# main sigue protegido por el hook de git: un repo de prueba con el hook real
GR="$TMP/gitrepo"; mkdir -p "$GR"
git -C "$GR" init -q -b main
git -C "$GR" config user.name t; git -C "$GR" config user.email t@t
git -C "$GR" config core.hooksPath "$ROOT/githooks"
cat > "$TMP/commit_main.py" <<'PY'
import subprocess, sys
r = subprocess.run(["git", "-C", sys.argv[1], "commit", "--allow-empty", "-m", "directo a main"], capture_output=True, text=True)
print("rejected=%s" % (r.returncode != 0))
print(r.stderr)
PY
hook_out=""
contains() { [[ "$1" == *"$2"* ]]; }
tap_run hook_out 0 python3 "$TMP/commit_main.py" "$GR"
contains "$hook_out" "rejected=True"; tap_check $? "git-hook-rejects-commit-on-main" "git commit directo en main se rechaza"
contains "$hook_out" "main está protegido"; tap_check $? "git-hook-explains-main-protected" "el rechazo explica que main está protegido"
refs=$(git -C "$GR" for-each-ref refs/heads); [ -z "$refs" ]; tap_check $? "git-hook-main-not-moved" "main no se movió"

tap_done
