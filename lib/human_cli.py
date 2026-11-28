#!/usr/bin/env python3
"""Require human-only BK commands to run outside a provider agent process tree."""
import os
import re
import subprocess
import sys

AGENT_PROCESS = re.compile(r"(?:^|[/\s])(?:claude|claude-code|codex|agy|antigravity|cursor-agent)(?:$|[/\s])", re.I)
# An agent installed with npm runs as `node <script>`: `comm` says node, and the agent is the script in args.
INTERPRETERS = re.compile(r"^(?:node|nodejs|bun|deno)$")


# ps by absolute path: looking it up in PATH would let a fake `ps` placed first in PATH hide the agent.
PS_PATHS = ("/bin/ps", "/usr/bin/ps")


def process_table():
    ps = next((path for path in PS_PATHS if os.access(path, os.X_OK)), None)
    if ps is None:
        raise OSError("ps not found")
    def column(fields):
        # comm and args can hold spaces: each one goes in its own call, as the last column.
        result = subprocess.run([ps, "-axo", fields], check=True, capture_output=True, text=True,
                                env={"PATH": "/bin:/usr/bin", "LC_ALL": "C"})
        rows = {}
        for line in result.stdout.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) == 3:
                try:
                    rows[int(parts[0])] = (int(parts[1]), parts[2])
                except ValueError:
                    continue
        return rows

    comms = column("pid=,ppid=,comm=")
    args = column("pid=,ppid=,args=")
    return {pid: (ppid, comm, args.get(pid, (ppid, ""))[1]) for pid, (ppid, comm) in comms.items()}


def is_agent(comm, args):
    """The executable (comm or the first word of args) or, under an interpreter, the script it runs."""
    if AGENT_PROCESS.search(comm):
        return True
    words = args.split()
    if not words:
        return False
    if AGENT_PROCESS.search(words[0]):
        return True
    if INTERPRETERS.match(os.path.basename(words[0])) or INTERPRETERS.match(os.path.basename(comm)):
        script = next((w for w in words[1:] if not w.startswith("-")), "")
        return bool(AGENT_PROCESS.search(script))
    return False


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
        parent, comm, args = table[pid]
        if is_agent(comm, args):
            return "the command was invoked from an agent session"
        pid = parent
    return "the caller process tree could not be verified"


def human_only(args):
    """The human-only command that `bk <args>` runs, also through _do or _do_run (#45); None if it runs none.

    Follows bin/bk: with _hub/_do/_do_run first, the arguments go as they are; otherwise --dry-run and
    --account X come out wherever they are. bk _do [--cwd D] [--title T] -- <cmd> and bk _do_run <log> <title>
    [--] <cmd> run another bk.
    """
    for _ in range(64):
        if args[:1] == ["_do"]:
            i = 1
            while i < len(args) and args[i] != "--":
                if args[i] not in ("--cwd", "--title") or i + 1 >= len(args):
                    return None      # bk _do rejects it: nothing runs
                i += 2
            args = args[i + 1:]
            continue
        if args[:1] == ["_do_run"]:
            args = args[3:]
            if args[:1] == ["--"]:
                args = args[1:]
            continue
        if args[:1] == ["_hub"]:
            if args[1:2] != ["_do"]:
                return None      # the other topics only read: none runs a bk command
            args = args[1:]      # bk _hub _do … is bk _do … (_do is a topic of lib/herdr_hub.py)
            continue
        words, i = [], 0
        while i < len(args):
            if args[i] == "--account":
                i += 2
                continue
            if args[i] != "--dry-run":
                words.append(args[i])
            i += 1
        if words[:1] in (["_do"], ["_do_run"], ["_hub"]):
            args = words
            continue
        if words[:1] in (["say"], ["approve"]):
            return words[0]
        if words[:2] in (["supervisor", "approve"], ["supervisor", "cancel"]):
            return " ".join(words[:2])
        return None
    return "bk"              # nested beyond reason: treat it as human-only


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
