import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO_FROM_HERE = path.resolve(HERE, '../../..');

function asString(v) { return typeof v === 'string' ? v : ''; }
function asObj(v) { return v && typeof v === 'object' ? v : {}; }
function normalizePath(p, base) {
  if (!p || typeof p !== 'string') return '';
  return path.isAbsolute(p) ? p : path.resolve(base || process.cwd(), p);
}

function resolveScriptsDir(options, ctx) {
  const opt = asObj(options);
  const explicit = asString(opt.scriptsDir || opt.scripts_dir || opt.root || opt.bkScriptsDir);
  const base = ctx?.location?.directory || process.cwd();
  if (explicit) return normalizePath(explicit, base);
  return path.join(REPO_FROM_HERE, 'scripts', 'agents');
}

function scriptPath(scriptsDir, rel) { return path.join(scriptsDir, rel); }
function exists(p) { try { return !!p && fs.existsSync(p); } catch { return false; } }

function runPython(script, input, env, args = []) {
  if (!exists(script)) return { skipped: true, status: 0, stdout: '', stderr: '' };
  try {
    const r = spawnSync('python3', [script, ...args], {
      input: typeof input === 'string' ? input : JSON.stringify(input ?? {}),
      encoding: 'utf8',
      env: env || process.env,
      maxBuffer: 2 * 1024 * 1024,
      timeout: 15000,
    });
    return { skipped: false, status: r.status ?? 1, stdout: r.stdout || '', stderr: r.stderr || '', error: r.error };
  } catch (error) {
    return { skipped: false, status: 1, stdout: '', stderr: String(error?.message || error), error };
  }
}

function parseDenyResult(res) {
  if (!res || res.skipped) return null;
  const stdout = asString(res.stdout).trim();
  const stderr = asString(res.stderr).trim();
  if (stdout) {
    try {
      const obj = JSON.parse(stdout);
      // Claude Code (y lib/land.py) anidan la decisión en hookSpecificOutput.
      const o = { ...obj, ...asObj(obj.hookSpecificOutput) };
      const decision = asString(o.permissionDecision || o.permission || o.decision || o.effect).toLowerCase();
      if (decision === 'deny' || decision === 'block' || decision === 'rejected') {
        const msg = asString(o.agent_message || o.permissionDecisionReason || o.user_message || o.message || o.reason).trim();
        return msg || stderr || 'Blocked by BK guardrails';
      }
    } catch {
      // not JSON
    }
  }
  if (res.status === 2) return stderr || stdout || 'Blocked by BK guardrails';
  return null;
}

// Un guardrail que no pudo correr (no arrancó, se colgó o salió con un estado que no es 0 ni 2) no permite nada:
// devuelve el motivo para frenar, en vez de dejar pasar en silencio.
function guardFailure(res, name) {
  if (!res) return null;
  if (res.skipped) return `BK guardrail no disponible: falta ${name}; se frena el comando por seguridad.`;
  if (res.error || (res.status !== 0 && res.status !== 2)) {
    const why = asString(res.error?.message) || asString(res.stderr).trim().split('\n').pop() || `estado ${res.status}`;
    return `BK guardrail falló al evaluar el comando (${name}: ${why}); se frena por seguridad.`;
  }
  return null;
}

function deny(message) {
  const err = new Error(message || 'Blocked by BK guardrails');
  err.name = 'BKGuardrailDenied';
  return err;
}

const SHELL_TOOLS = new Set(['shell', 'bash', 'Bash']);
// Herramientas que modifican archivos: todas pasan por el hook de land.
const EDIT_TOOLS = new Set(['edit', 'write', 'multiedit', 'patch', 'apply_patch']);
const isShellTool = (t) => SHELL_TOOLS.has(asString(t));
const isEditTool = (t) => EDIT_TOOLS.has(asString(t));

function commandFromToolEvent(event) {
  const input = asObj(event?.input);
  return isShellTool(event?.tool) ? asString(input.command) : '';
}

function fileFromToolEvent(event) {
  const input = asObj(event?.input);
  return asString(input.file_path || input.path || input.filePath || input.file);
}

function outputText(result) {
  if (typeof result === 'string') return result;
  const r = asObj(result);
  if (typeof r.output === 'string') return r.output;
  const out = asObj(r.output);
  if (typeof out.output === 'string') return out.output;
  if (typeof out.stdout === 'string') return out.stdout;
  if (typeof r.stdout === 'string') return r.stdout;
  try { return JSON.stringify(result ?? ''); } catch { return ''; }
}

function shouldRecordShellTask(command) {
  const cmd = asString(command);
  return /\bgit\b[\s\S]*\bcommit\b/.test(cmd) || /\bgh\b[\s\S]*\bpr\b[\s\S]*\bcreate\b/.test(cmd);
}

function taskPayloadForShell(command, result) {
  if (!shouldRecordShellTask(command)) return null;
  return {
    hook_event_name: 'PostToolUse',
    tool_name: 'Bash',
    tool_input: { command: asString(command) },
    tool_response: { stdout: outputText(result) },
  };
}

function guardrailsPayload(command, cwd) {
  const cmd = asString(command);
  const dir = asString(cwd) || process.cwd();
  // Use Claude/Bash shape so guardrails.py exits 2 on deny; keep command/cwd for compatibility.
  return { tool_name: 'Bash', tool_input: { command: cmd }, command: cmd, cwd: dir };
}

function landPayload(eventName, filePath, cwd) {
  return { hook_event_name: eventName, tool_name: 'Edit', tool_input: { file_path: filePath }, cwd: asString(cwd) || process.cwd() };
}

function logDebug(enabled, ...args) {
  if (!enabled) return;
  try { console.error('[bk-opencode]', ...args); } catch {}
}

export default {
  id: 'bk-guardrails',
  async setup(ctx) {
    const opt = asObj(ctx?.options);
    const scriptsDir = resolveScriptsDir(opt, ctx);
    const guardrailsPy = scriptPath(scriptsDir, 'guardrails.py');
    const taskEventsPy = scriptPath(scriptsDir, 'task_events.py');
    const landPy = normalizePath(asString(opt.landPy || opt.land_py) || path.resolve(scriptsDir, '../../lib/land.py'), ctx?.location?.directory || process.cwd());
    const env = { ...process.env };
    const debug = !!opt.debug;
    const seenStart = new Set();

    const emitTask = (payload) => {
      if (!payload) return;
      if (!process.env.BK_TASK_DIR) return;
      runPython(taskEventsPy, payload, env);
    };

    const evalShellCommand = (command, cwd) => {
      const cmd = asString(command);
      if (!cmd) return null;
      const res = runPython(guardrailsPy, guardrailsPayload(cmd, cwd), env);
      return parseDenyResult(res) || guardFailure(res, 'guardrails.py');
    };

    // lib/land.py hook (mismo hook que en Claude Code): un deny frena la edición.
    const evalEdit = (eventName, filePath, cwd) => {
      if (!filePath || !exists(landPy)) return null;
      const res = runPython(landPy, landPayload(eventName, filePath, cwd), env, ['hook']);
      if (eventName !== 'PreToolUse') return null;
      return parseDenyResult(res) || guardFailure(res, 'lib/land.py');
    };

    if (!exists(guardrailsPy)) {
      console.error(`[bk-opencode] falta ${guardrailsPy}: los comandos de shell se frenan hasta que exista.`);
    }

    let guarded = 0; // hooks que frenan el shell: si ninguno se registra, el plugin no protege nada
    if (ctx?.permission?.hook) {
      try {
        await ctx.permission.hook('evaluate', async (event) => {
          try {
            if (asString(event?.action) !== 'shell') return;
            const resources = Array.isArray(event?.resources) ? event.resources : [];
            const command = asString(resources[0]);
            const msg = evalShellCommand(command, ctx?.location?.directory || process.cwd());
            if (msg) {
              event.effect = 'deny';
              event.message = msg;
            }
          } catch (err) {
            logDebug(debug, 'permission.evaluate error', err);
            event.effect = 'deny';
            event.message = 'BK guardrail falló al evaluar el permiso; se frena por seguridad.';
          }
        });
        guarded++;
      } catch (err) { logDebug(debug, 'permission hook register error', err); }
    }

    if (ctx?.shell?.hook) {
      try {
        await ctx.shell.hook('create.before', async (event) => {
          const msg = evalShellCommand(event?.command, event?.cwd || ctx?.location?.directory || process.cwd());
          if (msg) throw deny(msg);
        });
        guarded++;
      } catch (err) { logDebug(debug, 'shell hook register error', err); }
    }

    if (ctx?.tool?.hook) {
      try {
        await ctx.tool.hook('execute.before', async (event) => {
          const tool = asString(event?.tool);
          if (isShellTool(tool)) {
            const msg = evalShellCommand(commandFromToolEvent(event), ctx?.location?.directory || process.cwd());
            if (msg) throw deny(msg);
          }
          if (isEditTool(tool)) {
            const fp = normalizePath(fileFromToolEvent(event), ctx?.location?.directory || process.cwd());
            const msg = evalEdit('PreToolUse', fp, ctx?.location?.directory);
            if (msg) throw deny(msg);
          }
        });
        guarded++;
      } catch (err) { logDebug(debug, 'tool.execute.before register error', err); }

      try {
        await ctx.tool.hook('execute.after', async (event) => {
          try {
            const tool = asString(event?.tool);
            const status = asString(event?.status);
            if (isEditTool(tool) && status === 'completed') {
              const fp = normalizePath(fileFromToolEvent(event), ctx?.location?.directory || process.cwd());
              evalEdit('PostToolUse', fp, ctx?.location?.directory);
            }
            if (isShellTool(tool) && status === 'completed') {
              emitTask(taskPayloadForShell(commandFromToolEvent(event), event?.result));
            }
          } catch (err) { logDebug(debug, 'tool.execute.after error', err); }
        });
      } catch (err) { logDebug(debug, 'tool.execute.after register error', err); }
    }

    if (guarded === 0) {
      throw new Error('bk-guardrails: no se pudo registrar ningún hook que frene el shell (¿cambió la API de plugins de OpenCode?)');
    }

    // Best-effort task lifecycle mapping for OpenCode sessions.
    if (ctx?.session?.hook) {
      try {
        await ctx.session.hook('prompt', async (event) => {
          try {
            const sid = asString(event?.sessionID) || 'unknown';
            if (!seenStart.has(sid)) {
              seenStart.add(sid);
              emitTask({ hook_event_name: 'SessionStart' });
            }
            emitTask({ hook_event_name: 'UserPromptSubmit' });
          } catch (err) { logDebug(debug, 'session.prompt error', err); }
        });
      } catch (err) { logDebug(debug, 'session.prompt register error', err); }
    }

    // Best-effort event subscription: map idle/finish to Stop when available.
    try {
      const sub = ctx?.event?.subscribe;
      if (typeof sub === 'function') {
        const handler = (e) => {
          try {
            const type = asString(e?.type || e?.event?.type || e?.properties?.type);
            if (!type) return;
            if (
              type === 'session.idle' ||
              type === 'session.status.idle' ||
              type === 'session.execution.succeeded' ||
              type === 'session.execution.failed' ||
              type === 'session.execution.interrupted'
            ) {
              emitTask({ hook_event_name: 'Stop' });
            }
          } catch (err) { logDebug(debug, 'event handler error', err); }
        };
        const r = sub(handler);
        if (r && typeof r?.then === 'function') r.catch(() => {});
      }
    } catch (err) { logDebug(debug, 'event.subscribe error', err); }
  },
};
