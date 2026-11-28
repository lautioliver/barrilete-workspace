#!/usr/bin/env python3
"""Require human-only BK commands to run outside a provider agent process tree."""
import os
import re
import subprocess
import sys

AGENT_PROCESS = re.compile(r"(?:^|[/\s])(?:claude|codex|agy|antigravity)(?:$|[/\s])", re.I)


# ps by absolute path: looking it up in PATH would let a fake `ps` placed first in PATH hide the agent.
PS_PATHS = ("/bin/ps", "/usr/bin/ps")


def process_table():
    ps = next((path for path in PS_PATHS if os.access(path, os.X_OK)), None)
    if ps is None:
        raise OSError("ps not found")
    result = subprocess.run([ps, "-axo", "pid=,ppid=,comm="], check=True, capture_output=True, text=True,
                            env={"PATH": "/bin:/usr/bin", "LC_ALL": "C"})
    table = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            try:
                table[int(parts[0])] = (int(parts[1]), parts[2])
            except ValueError:
                continue
    return table


def reason():
    if os.environ.get("BK_TASK_DIR"):
        return "BK_TASK_DIR identifies an active BK task"
    table = process_table()
    pid = os.getppid()
    seen = set()
    for _ in range(128):
        if pid <= 1:
            return None
        if pid in seen or pid not in table:
            return "the caller process tree could not be verified"
        seen.add(pid)
        parent, command = table[pid]
        if AGENT_PROCESS.search(command):
            return "the command was invoked from an agent session"
        pid = parent
    return "the caller process tree could not be verified"


def main(argv):
    if len(argv) != 2 or argv[1] not in ("say", "approve", "cancel"):
        print("uso interno: human_cli.py {say|approve|cancel}", file=sys.stderr)
        return 2
    try:
        blocked = reason()
    except (OSError, subprocess.SubprocessError):
        blocked = "the caller process tree could not be verified"
    if blocked:
        print(f"bk {argv[1]}: {blocked}; ejecutalo desde una terminal humana separada, fuera del chat del agente.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
