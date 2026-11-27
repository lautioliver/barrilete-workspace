#!/usr/bin/env python3
"""Registra sesiones de Codex para bk y completa handoffs al terminar el turno."""
import json
import os
import subprocess
import sys
import time


def main():
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError):
        return
    sid = str(event.get("session_id") or "")
    if not sid or event.get("agent_id"):
        return
    event_name = event.get("hook_event_name", "")
    root = os.environ.get("BK_AGENT_STATE_DIR", os.path.expanduser("~/.cache/sketchybar/agents"))
    os.makedirs(root, exist_ok=True)
    path = os.path.join(root, os.path.basename(sid) + ".json")
    if event_name == "SessionEnd":
        try:
            os.remove(path)
        except OSError:
            pass
        return
    state = {
        "pane": os.environ.get("TMUX_PANE") or os.environ.get("HC_TERMINAL_ID", ""),
        "state": {"SessionStart": "idle", "UserPromptSubmit": "working", "PreToolUse": "working",
                  "PostToolUse": "working", "PermissionRequest": "waiting", "Stop": "done",
                  "Interrupt": "done"}.get(event_name, ""),
        "cwd": str(event.get("cwd") or os.getcwd()), "tool": str(event.get("tool_name") or "-"),
        "provider": "codex", "account": os.environ.get("BK_ACCOUNT_CODEX", "default"), "ts": time.time(),
    }
    if state["state"]:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(state, f)
        os.replace(tmp, path)
    if event_name == "Stop":
        handoffs = os.environ.get("BK_HANDOFF_DIR", os.path.expanduser("~/.local/state/bk/handoffs"))
        if os.path.isfile(os.path.join(handoffs, os.path.basename(sid) + ".md")):
            bk = os.environ.get("BK_HANDOFF_BK") or os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "bin", "bk")
            subprocess.Popen([bk, "handoff", "--listo", sid], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
