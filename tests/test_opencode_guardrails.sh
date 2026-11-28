#!/usr/bin/env bash
# OpenCode v2.3.2 BK guardrails adapter - isolated tests (no real home/model required for unit path).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/agents/tap.sh"
tap_begin "$0"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bk-opencode-test.XXXXXX")"
tap_at_exit 'rm -rf "$TMP"'

NODE_TEST="$TMP/test.mjs"
cat > "$NODE_TEST" <<'NODE'
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

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

async function test(name, fn) {
  try { await fn(); console.log('ok - ' + name); }
  catch (e) { console.error('not ok - ' + name); console.error(e && e.stack || e); process.exitCode = 1; }
}

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
await test('plugin runs land hook on edit with real path', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bk-land-'));
  const scriptsDir = path.join(tmp, 'scripts/agents');
  const libDir = path.join(tmp, 'lib');
  fs.mkdirSync(scriptsDir, { recursive: true });
  fs.mkdirSync(libDir, { recursive: true });
  fs.copyFileSync(path.join(repo, 'scripts/agents/guardrails.py'), path.join(scriptsDir, 'guardrails.py'));
  fs.copyFileSync(path.join(repo, 'scripts/agents/task_events.py'), path.join(scriptsDir, 'task_events.py'));
  fs.writeFileSync(path.join(libDir, 'land.py'), '#!/usr/bin/env python3\nimport sys,os\np=os.environ["LAND_LOG"]\nopen(p,"a").write(sys.stdin.read().strip()+"\\n")\n');
  const { ctx, hooks } = mkctx({ scriptsDir }, tmp);
  process.env.LAND_LOG = path.join(tmp, 'land.log');
  await plugin.setup(ctx);
  const fp = path.join(tmp, 'a.txt');
  await hooks.toolBefore[0]({ tool: 'edit', input: { file_path: fp } });
  await hooks.toolAfter[0]({ tool: 'edit', status: 'completed', input: { file_path: fp } });
  const lines = fs.readFileSync(process.env.LAND_LOG, 'utf8').trim().split(/\n+/);
  assert.equal(lines.length, 2);
  assert.match(lines[0], /PreToolUse/);
  assert.match(lines[1], /PostToolUse/);
  delete process.env.LAND_LOG;
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
NODE

node_out=""
tap_run node_out 0 env REPO="$ROOT" node "$NODE_TEST"
tap_check $? "opencode-plugin-unit" "node adapter unit tests"
printf '%s\n' "$node_out" | grep -q '^ok - ' ; tap_check $? "opencode-plugin-unit-cases" "node adapter reported ok cases"

if command -v opencode >/dev/null 2>&1; then
  CFG="$TMP/cfg"; mkdir -p "$CFG"
  cat > "$CFG/opencode.jsonc" <<'JSON'
{"$schema":"https://opencode.ai/config.json","permission":{"bash":{"*":"ask","git push *":"deny","*--no-verify*":"deny","gh workflow *":"ask"},"edit":{"*":"allow",".env*":"deny",".github/**":"ask","package.json":"ask"}}}
JSON
  cfg_out=$(cd "$CFG" && opencode debug config 2>&1); cfg_rc=$?
  tap_check $cfg_rc "opencode-config-debug" "opencode debug config runs"
  printf '%s' "$cfg_out" | grep -q '"resource": "git push \*"' ; tap_check $? "opencode-config-normalize-push-deny" "debug config normalizes push deny"
  printf '%s' "$cfg_out" | grep -q '"resource": ".github/\*\*"' ; tap_check $? "opencode-config-normalize-github-ask" "debug config normalizes .github ask"
  printf '%s' "$cfg_out" | grep -q '"resource": "gh workflow \*"' ; tap_check $? "opencode-config-normalize-workflow-ask" "debug config normalizes gh workflow ask"
else
  tap_skip "opencode-config-normalize-push-deny" "opencode not installed"
  tap_skip "opencode-config-normalize-github-ask" "opencode not installed"
  tap_skip "opencode-config-normalize-workflow-ask" "opencode not installed"
fi

# git-level protection must remain unchanged
[ -f "$ROOT/githooks/reference-transaction" ]; tap_check $? "git-hook-reference-transaction-present" "main protection hook remains present"
grep -q 'refs/heads/main' "$ROOT/githooks/reference-transaction"; tap_check $? "git-hook-reference-transaction-main" "hook still protects main"

tap_done
