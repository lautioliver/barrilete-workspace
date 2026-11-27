#!/usr/bin/env python3
"""Registra el estado de Cursor Agent en el store que consume bk ls."""
import json
import os
import sys
import time


def main():
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    pane = os.environ.get("HC_TERMINAL_ID", "")
    if not pane:
        return 0
    kind = event.get("hook_event_name", "")
    if kind == "sessionEnd":
        state = "done"
    elif kind in ("sessionStart", "afterAgentResponse", "stop"):
        state = "idle" if kind != "stop" else "done"
    else:
        state = "working"
    sid = str(event.get("conversation_id") or event.get("session_id") or "cursor-" + pane)
    cwd = str(event.get("cwd") or os.getcwd())
    model = str(event.get("model") or "")
    root = os.environ.get("BK_AGENT_STATE_DIR", os.path.expanduser("~/.cache/sketchybar/agents"))
    os.makedirs(root, exist_ok=True)
    target = os.path.join(root, "cursor-" + sid.replace("/", "_") + ".json")
    data = {"pane": pane, "state": state, "cwd": cwd, "model": model, "role": "cursor", "ts": time.time()}
    tmp = target + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
