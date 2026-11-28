"""Claude Code adapter for the supervisor (ADR-003, contract merged in #55, 0364135).

Reads the session marks that Claude Code hooks write to
${XDG_STATE_HOME:-~/.local/state}/bk/supervisor/sessions/claude-code-<session_id>.json and never writes them.
A mark alone proves nothing: every answer is checked against the live process (PID and start time,
supervisor.process_state). Anything that cannot be verified is "unknown", which keeps the lease as it is.

Not registered in supervisor.HARNESS_ADAPTERS: registering it, the hooks that write the marks and the
launch through `bk run` wait for approval (#39, #42). Only the Python standard library.
"""
import json
import os

import supervisor as sv

HARNESS = "claude-code"
MARK_SCHEMA = 1
MARK_KEYS = {"schema", "harness", "session_id", "pid", "process_start", "started_at", "ended_at",
             "run_id", "lease_id"}
MAX_MARK_BYTES = 4096
PREFIX = HARNESS + "-"


def sessions_dir():
    return os.path.join(sv.STORE_DIR, "sessions")


def _uuid_or_none(value):
    if value is None:
        return True
    try:
        sv.identifier(value, "id")
    except ValueError:
        return False
    return True


def _instant(value):
    """The UTC instant of an ISO timestamp with zone (supervisor.timestamp), or None if it is not one."""
    try:
        sv.timestamp(value, "timestamp")
        return sv.parse_time(value)
    except (ValueError, TypeError):
        return None


def read_mark(session_id):
    """The validated mark of a session, or None if it is missing, unreadable or not trustworthy."""
    if not isinstance(session_id, str) or not sv.SESSION_ID.fullmatch(session_id):
        return None
    path = os.path.join(sessions_dir(), f"{PREFIX}{session_id}.json")
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return None
    try:  # O_NONBLOCK: a FIFO in place of a mark reads empty instead of hanging the supervisor
        raw = os.read(fd, MAX_MARK_BYTES + 1)
    except OSError:
        return None
    finally:
        os.close(fd)
    if len(raw) > MAX_MARK_BYTES:
        return None
    try:
        mark = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(mark, dict) or set(mark) != MARK_KEYS:
        return None
    pid = mark["pid"]
    if (mark["schema"] != MARK_SCHEMA or type(mark["schema"]) is not int
            or mark["harness"] != HARNESS or mark["session_id"] != session_id
            or type(pid) is not int or pid <= 0
            or not isinstance(mark["process_start"], str) or not 0 < len(mark["process_start"]) <= 64
            or _instant(mark["started_at"]) is None
            or not (mark["ended_at"] is None or _instant(mark["ended_at"]) is not None)
            or not _uuid_or_none(mark["run_id"]) or not _uuid_or_none(mark["lease_id"])):
        return None
    if mark["ended_at"] is not None and _instant(mark["ended_at"]) < _instant(mark["started_at"]):
        return None
    return mark


class ClaudeCodeAdapter:
    def session_state(self, session_id):
        """alive: mark without ended_at and its process alive with the same start time.
        absent: ended_at (SessionEnd ran) and the process gone or its PID reused.
        unknown: anything else, including SessionEnd with the process still alive, or the process gone
        without SessionEnd (Claude Code has an end event, so its absence is not proof)."""
        mark = read_mark(session_id)
        if mark is None:
            return "unknown"
        proc = sv.process_state(mark["pid"], mark["process_start"])
        if mark["ended_at"] is None:
            return "alive" if proc == "alive" else "unknown"
        return "absent" if proc == "absent" else "unknown"

    def link_mark(self, run_id, lease_id):
        """(pid, process_start, session_id) of the mark to link to a reserved lease, or None.

        Candidates: marks with this run_id and lease_id, without ended_at, whose process is alive. If
        that process also has an ended mark of this lease (a /clear or resume before the link), None.
        In Claude Code a subagent fires SubagentStart, not SessionStart, so it leaves no mark (ADR-003,
        "Enlace del lease"). Marks of more than one process, or a tie for the oldest, are ambiguous:
        None, and the lease stays reserved."""
        try:
            sv.identifier(run_id, "run_id")
            sv.identifier(lease_id, "lease_id")
        except ValueError:
            return None
        try:
            names = os.listdir(sessions_dir())
        except OSError:
            return None
        candidates, ended = [], set()
        for name in names:
            if not (name.startswith(PREFIX) and name.endswith(".json")):
                continue
            mark = read_mark(name[len(PREFIX):-len(".json")])
            if mark is None or mark["run_id"] != run_id or mark["lease_id"] != lease_id:
                continue
            if sv.process_state(mark["pid"], mark["process_start"]) != "alive":
                continue
            if mark["ended_at"] is not None:
                ended.add((mark["pid"], mark["process_start"]))
                continue
            candidates.append(mark)
        if not candidates or len({(m["pid"], m["process_start"]) for m in candidates}) > 1:
            return None
        # A session of this lease that ended while its process lives on (/clear, resume): the session
        # changed before the link, and ADR-003 keeps that unknown until verified. Not linked.
        if (candidates[0]["pid"], candidates[0]["process_start"]) in ended:
            return None
        candidates.sort(key=lambda m: _instant(m["started_at"]))
        if len(candidates) > 1 and _instant(candidates[0]["started_at"]) == _instant(candidates[1]["started_at"]):
            return None
        first = candidates[0]
        return first["pid"], first["process_start"], first["session_id"]
