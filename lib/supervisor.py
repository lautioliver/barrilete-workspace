#!/usr/bin/env python3
"""Local plan arbitration, reservations and lease lifecycle for the BK supervisor.

This module never launches agents. Lease transitions that depend on a live process (start, heartbeat,
completion, release) require a harness adapter that can verify the process and harness session; none is
registered yet (HARNESS_ADAPTERS is empty), so those transitions refuse and keep the issue and slot held.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone

STATE_HOME = os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
STORE_DIR = os.path.join(STATE_HOME, "bk", "supervisor")
STATE = os.path.join(STORE_DIR, "state.json")
EVENTS = os.path.join(STORE_DIR, "events.jsonl")
LOCK = os.path.join(STORE_DIR, ".lock")
SCHEMA = "bk.supervisor.v1"
PLAN_SCHEMA = "bk.supervisor-plan.v1"
EVENT_TYPES = {"plan.proposed", "plan.approved", "plan.queued", "plan.reserved", "plan.cancelled",
               "plan.closed", "lease.started", "lease.stale", "lease.recovered", "lease.completed",
               "lease.released"}
REASON_CODES = {"proposed", "human_approved", "slot_limit", "cancelled", "queue_promoted", "all_leases_ended",
                "adapter_confirmed", "heartbeat_timeout", "heartbeat_recovered", "verified_exit"}
PLAN_STATUSES = {"pending", "queued", "reserved", "cancelled", "closed"}
PLAN_TERMINAL = {"cancelled", "closed"}
# reserved -> running -> stale; stale -> running (same identity, process and session verified alive);
# running|stale -> completed|released (only with verified exit);
# reserved -> cancelled (only before start, together with its plan).
LEASE_STATUSES = {"reserved", "running", "stale", "completed", "released", "cancelled"}
LEASE_ACTIVE = {"reserved", "running", "stale"}
LEASE_TERMINAL = {"completed", "released", "cancelled"}
HEARTBEAT_SECONDS = 60
STALE_SECONDS = 300
SESSION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
# harness -> adapter object with session_state(session_id) -> "alive" | "absent" | "unknown".
# Empty on purpose: no harness has a validated way to prove its session (and subagents) ended
# (ADR-003, "Barandas para habilitar corridas reales"). Without an adapter, start/finish/release refuse.
HARNESS_ADAPTERS = {}
TASK_TYPES = {"feature", "fix", "hotfix", "review", "documentation", "refactor", "other"}
AREAS = {"agents", "cli", "herdr", "docs", "infra", "other", "unknown"}
PRIORITIES = {"low", "normal", "high", "hotfix"}
RISK_FLAGS = {"business_logic", "sensitive_path", "hotfix", "security"}
PROVIDERS = {"claude", "codex", "agy", "unknown"}
HARNESSES = {"claude-code", "codex", "herdr", "unknown"}
ROLES = {"implementer", "implementer-light", "reviewer", "documentation", "reader"}
MODEL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,79})?$")
MAX_IMPLEMENTERS = 3
RETENTION_DAYS = 30


def fail(message):
    raise ValueError(message)


def require_keys(obj, required, optional=()):
    if not isinstance(obj, dict):
        fail("se esperaba un objeto JSON")
    missing = set(required) - obj.keys()
    extra = obj.keys() - set(required) - set(optional)
    if missing:
        fail("faltan campos: " + ", ".join(sorted(missing)))
    if extra:
        fail("campos no permitidos: " + ", ".join(sorted(extra)))


def enum(value, allowed, field):
    if not isinstance(value, str) or value not in allowed:
        fail(f"valor inválido en {field}")


def integer(value, field, minimum=1):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        fail(f"valor inválido en {field}")


def identifier(value, field):
    if not isinstance(value, str):
        fail(f"valor inválido en {field}")
    try:
        if str(uuid.UUID(value)) != value:
            fail(f"valor inválido en {field}")
    except ValueError:
        fail(f"valor inválido en {field}")


def timestamp(value, field):
    if not isinstance(value, str):
        fail(f"valor inválido en {field}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"valor inválido en {field}")
    if parsed.tzinfo is None or parsed.utcoffset().total_seconds() != 0:
        fail(f"valor inválido en {field}")


def validate_assignment(item):
    require_keys(item, ("task_id", "lease_id", "resource_kind", "resource_number", "task_type", "area",
                        "priority", "critical", "risk_flags", "provider", "model_id", "harness", "role",
                        "worktree"))
    identifier(item["task_id"], "task_id")
    identifier(item["lease_id"], "lease_id")
    enum(item["resource_kind"], {"issue", "pr"}, "resource_kind")
    integer(item["resource_number"], "resource_number")
    enum(item["task_type"], TASK_TYPES, "task_type")
    enum(item["area"], AREAS, "area")
    enum(item["priority"], PRIORITIES, "priority")
    if not isinstance(item["critical"], bool):
        fail("valor inválido en critical")
    if (not isinstance(item["risk_flags"], list)
            or any(not isinstance(flag, str) for flag in item["risk_flags"])
            or len(item["risk_flags"]) != len(set(item["risk_flags"]))):
        fail("valor inválido en risk_flags")
    for flag in item["risk_flags"]:
        enum(flag, RISK_FLAGS, "risk_flags")
    enum(item["provider"], PROVIDERS, "provider")
    if not isinstance(item["model_id"], str) or not MODEL_ID.fullmatch(item["model_id"]):
        fail("valor inválido en model_id")
    enum(item["harness"], HARNESSES, "harness")
    enum(item["role"], ROLES, "role")
    if item["role"] == "reviewer" and item["resource_kind"] != "pr":
        fail("reviewer requiere resource_kind pr")
    if item["role"] != "reviewer" and item["resource_kind"] != "issue":
        fail("un rol distinto de reviewer requiere resource_kind issue")
    path = item["worktree"]
    if (not isinstance(path, str) or not path or not os.path.isabs(path)
            or any(ord(char) < 32 or ord(char) == 127 for char in path)):
        fail("worktree debe ser una ruta absoluta local sin controles")


def validate_plan(plan):
    require_keys(plan, ("schema", "run_id", "assignments"))
    if plan["schema"] != PLAN_SCHEMA:
        fail("schema de plan inválido")
    identifier(plan["run_id"], "run_id")
    if not isinstance(plan["assignments"], list) or not plan["assignments"]:
        fail("assignments debe contener al menos un worker")
    task_ids, lease_ids, resources = set(), set(), set()
    for item in plan["assignments"]:
        validate_assignment(item)
        if item["task_id"] in task_ids or item["lease_id"] in lease_ids:
            fail("task_id y lease_id deben ser únicos dentro del plan")
        task_ids.add(item["task_id"])
        lease_ids.add(item["lease_id"])
        resource = (item["resource_kind"], item["resource_number"])
        if resource in resources:
            fail("el plan no puede asignar dos tareas al mismo issue o PR")
        resources.add(resource)
    implementers = sum(item["role"] in ("implementer", "implementer-light")
                       for item in plan["assignments"])
    if implementers > MAX_IMPLEMENTERS:
        fail(f"un plan no puede requerir más de {MAX_IMPLEMENTERS} implementadores")


def now():
    return datetime.now(timezone.utc)


def iso(value=None):
    return (value or now()).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def ensure_dir():
    os.makedirs(STORE_DIR, mode=0o700, exist_ok=True)
    os.chmod(STORE_DIR, 0o700)


@contextmanager
def locked(write=False):
    if write:
        ensure_dir()
    elif not os.path.isdir(STORE_DIR):
        yield
        return
    lock_path_exists = os.path.exists(LOCK)
    if not write and not lock_path_exists:
        yield
        return
    flags = os.O_RDWR | os.O_CREAT if write else os.O_RDONLY
    fd = os.open(LOCK, flags, 0o600) if write else os.open(LOCK, flags)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if write else fcntl.LOCK_SH)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def empty_state():
    return {"schema": SCHEMA, "plans": []}


def new_lease():
    return {"status": "reserved", "pid": None, "process_start": None, "session_id": None,
            "started_at": None, "last_heartbeat_at": None, "stale_at": None, "ended_at": None}


def validate_lease(lease):
    require_keys(lease, ("status", "pid", "process_start", "session_id", "started_at", "last_heartbeat_at",
                         "stale_at", "ended_at"))
    enum(lease["status"], LEASE_STATUSES, "lease.status")
    started = lease["status"] in ("running", "stale", "completed", "released")
    for field in ("started_at", "last_heartbeat_at"):
        if (lease[field] is not None) != started:
            fail(f"{field} no coincide con el estado del lease")
        if lease[field] is not None:
            timestamp(lease[field], field)
    if started:
        integer(lease["pid"], "pid")
        if not isinstance(lease["process_start"], str) or not 0 < len(lease["process_start"]) <= 64:
            fail("valor inválido en process_start")
        if not isinstance(lease["session_id"], str) or not SESSION_ID.fullmatch(lease["session_id"]):
            fail("valor inválido en session_id")
    elif any(lease[f] is not None for f in ("pid", "process_start", "session_id")):
        fail("un lease sin iniciar no tiene proceso")
    if lease["stale_at"] is not None:
        timestamp(lease["stale_at"], "stale_at")
    if lease["status"] == "stale" and lease["stale_at"] is None:
        fail("un lease stale requiere stale_at")
    if (lease["status"] in LEASE_TERMINAL) != (lease["ended_at"] is not None):
        fail("ended_at no coincide con el estado del lease")
    if lease["ended_at"] is not None:
        timestamp(lease["ended_at"], "ended_at")


def validate_state(data):
    require_keys(data, ("schema", "plans"))
    if data["schema"] != SCHEMA or not isinstance(data["plans"], list):
        fail(f"{STATE} no es un estado de supervisor válido")
    for record in data["plans"]:
        require_keys(record, ("plan", "status", "created_at", "approved_at", "closed_at"),
                     ("queue_reason", "leases"))
        validate_plan(record["plan"])
        enum(record["status"], PLAN_STATUSES, "status")
        timestamp(record["created_at"], "created_at")
        if record["approved_at"] is not None:
            timestamp(record["approved_at"], "approved_at")
        if record["closed_at"] is not None:
            timestamp(record["closed_at"], "closed_at")
        if (record["status"] in PLAN_TERMINAL) != (record["closed_at"] is not None):
            fail("closed_at no coincide con el estado terminal")
        if "queue_reason" in record and record["queue_reason"] is not None:
            enum(record["queue_reason"], {"slot_limit"}, "queue_reason")
        leases = record.get("leases")
        if record["status"] in ("reserved", "closed") and leases is None:
            fail("un plan reservado requiere leases")
        if leases is None:
            continue
        expected = {a["lease_id"] for a in record["plan"]["assignments"]}
        if not isinstance(leases, dict) or set(leases) != expected:
            fail("leases no coincide con las asignaciones del plan")
        for lease in leases.values():
            validate_lease(lease)
        statuses = {lease["status"] for lease in leases.values()}
        if record["status"] == "closed" and not statuses <= {"completed", "released"}:
            fail("un plan cerrado solo tiene leases completed o released")
        if record["status"] == "cancelled" and not statuses <= {"cancelled"}:
            fail("un plan cancelado solo tiene leases cancelled")
        if record["status"] in ("pending", "queued"):
            fail("un plan sin reservar no tiene leases")


def read_state():
    try:
        with open(STATE, encoding="utf-8") as stream:
            data = json.load(stream)
    except FileNotFoundError:
        return empty_state()
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail(f"{STATE} no se puede leer; no se modificó")
    if isinstance(data, dict) and isinstance(data.get("plans"), list):
        for record in data["plans"]:
            # States written before leases existed: a reserved plan gets one unstarted lease per assignment.
            if (isinstance(record, dict) and record.get("status") == "reserved" and "leases" not in record
                    and isinstance(record.get("plan"), dict)
                    and isinstance(record["plan"].get("assignments"), list)):
                record["leases"] = {a.get("lease_id"): new_lease() for a in record["plan"]["assignments"]
                                    if isinstance(a, dict)}
    validate_state(data)
    return data


def atomic_write(path, payload):
    fd, tmp = tempfile.mkstemp(dir=STORE_DIR, prefix=".supervisor-tmp-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        directory_fd = os.open(STORE_DIR, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def event_rows():
    try:
        with open(EVENTS, encoding="utf-8") as stream:
            for line in stream:
                if not line.endswith("\n"):
                    return        # alta cortada a mitad (solo puede ser la última): no es un evento
                try:
                    event = json.loads(line)
                    require_keys(event, ("v", "event_id", "ts", "kind", "run_id", "assignment_count",
                                         "implementer_count", "priority", "reason_code"))
                    if event["v"] != 1 or event["kind"] not in EVENT_TYPES:
                        fail("evento inválido")
                    identifier(event["event_id"], "event_id")
                    identifier(event["run_id"], "run_id")
                    timestamp(event["ts"], "ts")
                    integer(event["assignment_count"], "assignment_count", 0)
                    integer(event["implementer_count"], "implementer_count", 0)
                    enum(event["priority"], PRIORITIES, "priority")
                    enum(event["reason_code"], REASON_CODES, "reason_code")
                except (ValueError, TypeError, KeyError, json.JSONDecodeError):
                    fail(f"{EVENTS} contiene una línea inválida; no se modificó")
                yield event
    except FileNotFoundError:
        return


def compact_events_locked(cutoff):
    kept = [event for event in event_rows() if parse_time(event["ts"]) >= cutoff]
    try:
        with open(EVENTS, encoding="utf-8") as stream:
            count = sum(1 for _ in stream)
    except FileNotFoundError:
        return
    if len(kept) != count:
        atomic_write(EVENTS, "".join(json.dumps(e, separators=(",", ":")) + "\n" for e in kept))


def prune_state_locked(state, cutoff):
    state["plans"] = [
        item for item in state["plans"]
        if item["status"] not in PLAN_TERMINAL or parse_time(item["closed_at"]) >= cutoff
    ]


def plan_priority(plan):
    priorities = [a["priority"] for a in plan["assignments"]]
    for priority in ("hotfix", "high", "normal", "low"):
        if priority in priorities:
            return priority
    return "normal"


def drop_torn_tail_locked():
    """Cut an unterminated last line (a write interrupted mid-way) so the next event starts on its own line."""
    try:
        with open(EVENTS, "rb+") as stream:
            size = stream.seek(0, os.SEEK_END)
            if size == 0:
                return
            stream.seek(size - 1)
            if stream.read(1) == b"\n":
                return
            end = size
            while end > 0:
                start = max(0, end - 4096)
                stream.seek(start)
                chunk = stream.read(end - start)
                cut = chunk.rfind(b"\n")
                if cut >= 0:
                    stream.truncate(start + cut + 1)
                    return
                end = start
            stream.truncate(0)
    except FileNotFoundError:
        return


def append_event_locked(kind, plan, reason_code, assignment=None):
    assignments = [assignment] if assignment is not None else plan["assignments"]
    event = {"v": 1, "event_id": str(uuid.uuid4()), "ts": iso(), "kind": kind,
             "run_id": plan["run_id"], "assignment_count": len(assignments),
             "implementer_count": sum(a["role"] in ("implementer", "implementer-light")
                                      for a in assignments),
             "priority": plan_priority({"assignments": assignments}), "reason_code": reason_code}
    drop_torn_tail_locked()
    with open(EVENTS, "a", encoding="utf-8") as stream:
        os.chmod(EVENTS, 0o600)
        stream.write(json.dumps(event, separators=(",", ":")) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def active_resource_owner(state, assignment, excluding_run=None):
    for record in state["plans"]:
        if record["status"] not in ("queued", "reserved") or record["plan"]["run_id"] == excluding_run:
            continue
        for other in record["plan"]["assignments"]:
            if (other["resource_kind"], other["resource_number"]) == (
                    assignment["resource_kind"], assignment["resource_number"]):
                return record["plan"]["run_id"]
    return None


def resources_available(state, plan):
    for assignment in plan["assignments"]:
        owner = active_resource_owner(state, assignment, plan["run_id"])
        if owner:
            fail(f"el recurso {assignment['resource_kind']} #{assignment['resource_number']} ya está reservado")
    return True


def is_implementer(assignment):
    return assignment["role"] in ("implementer", "implementer-light")


def reserved_implementers(state):
    """Slots held by leases that are reserved, running or stale. A stale lease keeps its slot."""
    return sum(
        is_implementer(assignment)
        for record in state["plans"] if record["status"] == "reserved"
        for assignment in record["plan"]["assignments"]
        if record["leases"][assignment["lease_id"]]["status"] in LEASE_ACTIVE
    )


def reserve(record):
    record["status"] = "reserved"
    record["queue_reason"] = None
    record["leases"] = {a["lease_id"]: new_lease() for a in record["plan"]["assignments"]}


def promote_queue(state, events):
    """Reserves queued plans that now fit. The plan.reserved events go to `events`: the caller appends them
    to the bus only after write_state, so the bus never records a promotion the state did not keep."""
    queued = [r for r in state["plans"] if r["status"] == "queued"]
    queued.sort(key=lambda r: (
        0 if any(a["priority"] == "hotfix" for a in r["plan"]["assignments"]) else 1,
        r["created_at"], r["plan"]["run_id"]))
    for record in queued:
        needed = sum(a["role"] in ("implementer", "implementer-light")
                     for a in record["plan"]["assignments"])
        if reserved_implementers(state) + needed <= MAX_IMPLEMENTERS:
            reserve(record)
            events.append(("plan.reserved", record["plan"], "queue_promoted"))
        else:
            break


def write_state(state):
    validate_state(state)
    atomic_write(STATE, json.dumps(state, ensure_ascii=False, indent=2) + "\n")


def propose(plan):
    validate_plan(plan)
    with locked(write=True):
        state = read_state()
        cutoff = now().timestamp() - RETENTION_DAYS * 86400
        prune_state_locked(state, datetime.fromtimestamp(cutoff, timezone.utc))
        compact_events_locked(datetime.fromtimestamp(cutoff, timezone.utc))
        if any(record["plan"]["run_id"] == plan["run_id"] for record in state["plans"]):
            fail("run_id ya existe")
        state["plans"].append({"plan": plan, "status": "pending", "created_at": iso(), "approved_at": None,
                               "closed_at": None})
        write_state(state)
        append_event_locked("plan.proposed", plan, "proposed")
    return {"run_id": plan["run_id"], "status": "pending", "assignments": len(plan["assignments"])}


def plan_record(state, run_id):
    for record in state["plans"]:
        if record["plan"]["run_id"] == run_id:
            return record
    fail("no existe ese run_id")


def display_plan(record):
    plan = record["plan"]
    print(f"Plan {plan['run_id']} · {len(plan['assignments'])} asignaciones")
    for a in plan["assignments"]:
        print(f"- {a['role']} {a['provider']}/{a['model_id']} [{a['harness']}] · "
              f"{a['resource_kind']} #{a['resource_number']} · {a['priority']}")
        print(f"  worktree: {a['worktree']}")
    print(f"Estado: {record['status']}")


def require_terminal(action):
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        fail(f"bk supervisor {action} requiere una terminal humana interactiva")


def require_human(action, run_id):
    """The process-tree gate of human_cli, here too: entering the module directly (python3 supervisor.py
    approve, under a pty) must not skip it. A terminal alone is not proof of a person. #57: after the
    tree gate, the person confirms with the system mechanism (one prompt, before the effect)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import human_cli
    from human_confirm import confirmar
    try:
        blocked = human_cli.reason()
    except (OSError, subprocess.SubprocessError):
        blocked = "the caller process tree could not be verified"
    if blocked:
        fail(f"bk supervisor {action}: {blocked}; ejecutalo desde una terminal humana separada")
    ok, estado = confirmar(f"bk supervisor {action}", run_id)
    if not ok:
        fail(f"bk supervisor {action}: confirmación denegada ({estado}); no se ejecuta")


def approve(run_id):
    identifier(run_id, "run_id")
    require_terminal("approve")
    require_human("approve", run_id)
    with locked():
        initial = read_state()
        record = plan_record(initial, run_id)
        if record["status"] != "pending":
            fail(f"el plan no está pendiente ({record['status']})")
        resources_available(initial, record["plan"])
        snapshot = json.loads(json.dumps(record))
    display_plan(snapshot)
    expected = f"APROBAR {run_id}"
    answer = input(f"Confirmá escribiendo '{expected}': ").strip()
    if answer != expected:
        return {"run_id": run_id, "status": "pending", "approved": False}
    with locked(write=True):
        state = read_state()
        cutoff = datetime.fromtimestamp(now().timestamp() - RETENTION_DAYS * 86400, timezone.utc)
        prune_state_locked(state, cutoff)
        compact_events_locked(cutoff)
        record = plan_record(state, run_id)
        if record["status"] != "pending":
            fail(f"el plan cambió mientras se confirmaba ({record['status']})")
        resources_available(state, record["plan"])
        record["approved_at"] = iso()
        needed = sum(a["role"] in ("implementer", "implementer-light")
                     for a in record["plan"]["assignments"])
        if reserved_implementers(state) + needed <= MAX_IMPLEMENTERS:
            reserve(record)
            reason_code = "human_approved"
            event_kind = "plan.reserved"
        else:
            record["status"] = "queued"
            record["queue_reason"] = "slot_limit"
            reason_code = "slot_limit"
            event_kind = "plan.queued"
        write_state(state)
        append_event_locked("plan.approved", record["plan"], "human_approved")
        append_event_locked(event_kind, record["plan"], reason_code)
        return {"run_id": run_id, "status": record["status"], "approved": True,
                "reserved_implementers": needed, "queue_reason": record.get("queue_reason")}


def cancel(run_id):
    identifier(run_id, "run_id")
    require_terminal("cancel")
    require_human("cancel", run_id)
    with locked():
        initial = read_state()
        snapshot = json.loads(json.dumps(plan_record(initial, run_id)))
        if snapshot["status"] in PLAN_TERMINAL:
            fail(f"el plan ya terminó ({snapshot['status']})")
        require_unstarted(snapshot)
    display_plan(snapshot)
    expected = f"CANCELAR {run_id}"
    answer = input(f"Confirmá escribiendo '{expected}': ").strip()
    if answer != expected:
        return {"run_id": run_id, "status": snapshot["status"], "cancelled": False}
    with locked(write=True):
        state = read_state()
        cutoff = datetime.fromtimestamp(now().timestamp() - RETENTION_DAYS * 86400, timezone.utc)
        prune_state_locked(state, cutoff)
        compact_events_locked(cutoff)
        record = plan_record(state, run_id)
        if record["status"] != snapshot["status"]:
            fail("el plan cambió mientras se confirmaba")
        require_unstarted(record)
        stamp = iso()
        record["status"] = "cancelled"
        record["queue_reason"] = None
        record["closed_at"] = stamp
        if record.get("leases") is not None:
            for lease in record["leases"].values():
                lease["status"] = "cancelled"
                lease["ended_at"] = stamp
        write_state(state)
        append_event_locked("plan.cancelled", record["plan"], "cancelled")
        promoted = []
        promote_queue(state, promoted)
        if promoted:
            write_state(state)
            for event in promoted:
                append_event_locked(*event)
        return {"run_id": run_id, "status": "cancelled", "cancelled": True}


def require_unstarted(record):
    leases = record.get("leases") or {}
    if any(lease["status"] != "reserved" for lease in leases.values()):
        fail("el plan tiene leases iniciados; solo se cancela antes del inicio")


# --- Lease lifecycle -------------------------------------------------------------------------------
# start_lease, heartbeat_lease and finish_lease are the entry points for a future harness adapter.
# They are not exposed on the CLI: an adapter must be registered in HARNESS_ADAPTERS after its
# per-harness validation (ADR-003). reconcile() is safe to run by anyone: it only marks stale and
# releases when the exit of both the process and the harness session is verified.

def find_lease(state, run_id, lease_id):
    record = plan_record(state, run_id)
    for assignment in record["plan"]["assignments"]:
        if assignment["lease_id"] == lease_id:
            if record["status"] not in ("reserved", "closed"):
                fail(f"el plan no está reservado ({record['status']})")
            return record, assignment, record["leases"][lease_id]
    fail("no existe ese lease_id en el plan")


def process_start_time(pid):
    """Start time of a live PID as reported by ps, or None if no such process."""
    result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                            timeout=5, env={"PATH": "/bin:/usr/bin", "LC_ALL": "C", "TZ": "UTC"})
    value = result.stdout.strip()
    if result.returncode != 0 and not value:
        return None
    if result.returncode != 0:
        raise OSError("ps no pudo verificar el proceso")
    return value or None


def process_state(pid, process_start):
    """alive: same PID and start time; absent: no process or PID reused by another one; unknown otherwise."""
    try:
        current = process_start_time(pid)
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    if current is None:
        return "absent"
    return "alive" if current == process_start else "absent"


def harness_state(assignment, session_id):
    adapter = HARNESS_ADAPTERS.get(assignment["harness"])
    if adapter is None or session_id is None:
        return "unknown"
    try:
        result = adapter.session_state(session_id)
    except Exception:  # an adapter failure never counts as proof of exit
        return "unknown"
    return result if result in ("alive", "absent") else "unknown"


def require_adapter(assignment):
    if assignment["harness"] not in HARNESS_ADAPTERS:
        fail(f"no hay adaptador verificado para el harness {assignment['harness']}; el lease sigue reservado")


def validate_identity(pid, process_start, session_id):
    integer(pid, "pid")
    if not isinstance(process_start, str) or not 0 < len(process_start) <= 64:
        fail("valor inválido en process_start")
    if not isinstance(session_id, str) or not SESSION_ID.fullmatch(session_id):
        fail("valor inválido en session_id")


def identity_in_use(state, pid, process_start, session_id, excluding):
    for record in state["plans"]:
        for lease_id, lease in (record.get("leases") or {}).items():
            if lease_id == excluding or lease["status"] not in ("running", "stale"):
                continue
            if (lease["pid"], lease["process_start"]) == (pid, process_start) or lease["session_id"] == session_id:
                return True
    return False


def close_finished_plans(state, events):
    """Closes reserved plans whose leases all ended, and promotes the queue. Like promote_queue, it
    collects its events in `events` for the caller to append after write_state."""
    closed = 0
    for record in state["plans"]:
        if record["status"] != "reserved":
            continue
        if all(lease["status"] in ("completed", "released") for lease in record["leases"].values()):
            record["status"] = "closed"
            record["closed_at"] = iso()
            events.append(("plan.closed", record["plan"], "all_leases_ended"))
            closed += 1
    if closed:
        promote_queue(state, events)
    return closed


def start_lease(run_id, lease_id, pid, process_start, session_id):
    """reserved -> running, only with a registered adapter that confirms the process and the session."""
    identifier(run_id, "run_id")
    identifier(lease_id, "lease_id")
    validate_identity(pid, process_start, session_id)
    with locked(write=True):
        state = read_state()
        record, assignment, lease = find_lease(state, run_id, lease_id)
        require_adapter(assignment)
        if lease["status"] != "reserved":
            fail(f"el lease no está reservado ({lease['status']})")
        if identity_in_use(state, pid, process_start, session_id, lease_id):
            fail("ese proceso o sesión ya tiene un lease activo; no se reutiliza un lease ambiguo")
        if process_state(pid, process_start) != "alive" or harness_state(assignment, session_id) != "alive":
            fail("el adaptador no pudo confirmar el proceso y la sesión; el lease sigue reservado")
        stamp = iso()
        lease.update(status="running", pid=pid, process_start=process_start, session_id=session_id,
                     started_at=stamp, last_heartbeat_at=stamp)
        write_state(state)
        append_event_locked("lease.started", record["plan"], "adapter_confirmed", assignment)
    return {"run_id": run_id, "lease_id": lease_id, "status": "running"}


def heartbeat_lease(run_id, lease_id, pid, process_start, session_id):
    """Renews a running lease (every HEARTBEAT_SECONDS). Updates state only; it writes no bus event.
    A stale lease comes back to running only with the same PID, start time and session, and with the
    process and the harness session verified alive (e.g. after the machine slept); that writes
    lease.recovered. Anything unverifiable keeps it stale."""
    identifier(run_id, "run_id")
    identifier(lease_id, "lease_id")
    validate_identity(pid, process_start, session_id)
    with locked(write=True):
        state = read_state()
        record, assignment, lease = find_lease(state, run_id, lease_id)
        require_adapter(assignment)
        if lease["status"] not in ("running", "stale"):
            fail(f"el lease no está corriendo ({lease['status']})")
        if (lease["pid"], lease["process_start"], lease["session_id"]) != (pid, process_start, session_id):
            fail("la identidad no coincide con la del lease")
        if process_state(pid, process_start) != "alive":
            fail("el proceso del lease no está vivo")
        recovered = lease["status"] == "stale"
        if recovered and harness_state(assignment, session_id) != "alive":
            fail("el adaptador no confirmó la sesión del harness; el lease sigue stale")
        lease["last_heartbeat_at"] = iso()
        if recovered:
            lease.update(status="running", stale_at=None)
        write_state(state)
        if recovered:
            append_event_locked("lease.recovered", record["plan"], "heartbeat_recovered", assignment)
    return {"run_id": run_id, "lease_id": lease_id, "status": "running"}


def verified_exit(assignment, lease):
    return (process_state(lease["pid"], lease["process_start"]) == "absent"
            and harness_state(assignment, lease["session_id"]) == "absent")


def finish_lease(run_id, lease_id):
    """running|stale -> completed, only if the process and the harness session are verified gone.
    `bk done` alone is not proof: the task may report done while the process or a subagent lives on."""
    identifier(run_id, "run_id")
    identifier(lease_id, "lease_id")
    with locked(write=True):
        state = read_state()
        record, assignment, lease = find_lease(state, run_id, lease_id)
        require_adapter(assignment)
        if lease["status"] not in ("running", "stale"):
            fail(f"el lease no está iniciado ({lease['status']})")
        if not verified_exit(assignment, lease):
            fail("no se verificó la salida del proceso y de la sesión; el lease conserva issue y slot")
        lease["status"] = "completed"
        lease["ended_at"] = iso()
        write_state(state)
        append_event_locked("lease.completed", record["plan"], "verified_exit", assignment)
        closing = []
        if close_finished_plans(state, closing):
            write_state(state)
            for event in closing:
                append_event_locked(*event)
    return {"run_id": run_id, "lease_id": lease_id, "status": "completed"}


def reconcile(dry_run=False):
    """running without heartbeat for STALE_SECONDS -> stale (keeps issue and slot);
    stale -> released only with verified exit of process and harness session. Never force-releases."""
    with (locked() if dry_run else locked(write=True)):
        state = read_state()
        current = now()
        stale, released, held, events = [], [], [], []
        for record in state["plans"]:
            if record["status"] != "reserved":
                continue
            for assignment in record["plan"]["assignments"]:
                lease = record["leases"][assignment["lease_id"]]
                ref = {"run_id": record["plan"]["run_id"], "lease_id": assignment["lease_id"]}
                if (lease["status"] == "running"
                        and (current - parse_time(lease["last_heartbeat_at"])).total_seconds() > STALE_SECONDS):
                    stale.append(ref)
                    if not dry_run:
                        lease["status"] = "stale"
                        lease["stale_at"] = iso(current)
                        events.append(("lease.stale", record["plan"], "heartbeat_timeout", assignment))
                if lease["status"] == "stale" or (dry_run and ref in stale):
                    if verified_exit(assignment, lease):
                        released.append(ref)
                        if not dry_run:
                            lease["status"] = "released"
                            lease["ended_at"] = iso()
                            events.append(("lease.released", record["plan"], "verified_exit", assignment))
                    else:
                        held.append(ref)
        if not dry_run and (stale or released):
            write_state(state)
            for event in events:
                append_event_locked(*event)
            closing = []
            if close_finished_plans(state, closing):
                write_state(state)
                for event in closing:
                    append_event_locked(*event)
    return {"stale": stale, "released": released, "needs_human": held, "dry_run": dry_run}


def status():
    with locked():
        state = read_state()
    rows = []
    for record in state["plans"]:
        plan = record["plan"]
        rows.append({"run_id": plan["run_id"], "status": record["status"], "created_at": record["created_at"],
                     "approved_at": record["approved_at"], "assignments": len(plan["assignments"]),
                     "implementers": sum(a["role"] in ("implementer", "implementer-light")
                                         for a in plan["assignments"]),
                     "priority": plan_priority(plan),
                     "leases": {status_name: sum(lease["status"] == status_name
                                                 for lease in (record.get("leases") or {}).values())
                                for status_name in sorted(LEASE_STATUSES)},
                     "stale_lease_ids": sorted(lease_id for lease_id, lease in
                                               (record.get("leases") or {}).items()
                                               if lease["status"] == "stale")})
    queued = sorted((r for r in rows if r["status"] == "queued"),
                    key=lambda r: (0 if r["priority"] == "hotfix" else 1, r["created_at"], r["run_id"]))
    for index, row in enumerate(queued, 1):
        row["queue_position"] = index
    return {"schema": SCHEMA, "max_implementers": MAX_IMPLEMENTERS,
            "heartbeat_seconds": HEARTBEAT_SECONDS, "stale_after_seconds": STALE_SECONDS,
            "verified_harnesses": sorted(HARNESS_ADAPTERS),
            "reserved_implementers": reserved_implementers(state), "plans": rows}


def main(argv):
    args = argv[1:]
    dry_run = "--dry-run" in args
    args = [arg for arg in args if arg != "--dry-run"]
    if not args or args[0] not in ("propose", "approve", "status", "cancel", "reconcile"):
        print("uso: bk supervisor {propose|approve <run_id>|status|cancel <run_id>|reconcile}", file=sys.stderr)
        return 2
    command = args[0]
    try:
        if command == "propose":
            plan = json.load(sys.stdin)
            validate_plan(plan)
            result = ({"run_id": plan["run_id"], "status": "pending", "dry_run": True}
                      if dry_run else propose(plan))
        elif command == "approve":
            if len(args) != 2:
                fail("uso: bk supervisor approve <run_id>")
            if dry_run:
                with locked():
                    record = plan_record(read_state(), args[1])
                display_plan(record)
                result = {"run_id": args[1], "status": record["status"], "dry_run": True}
            else:
                result = approve(args[1])
        elif command == "cancel":
            if len(args) != 2:
                fail("uso: bk supervisor cancel <run_id>")
            if dry_run:
                with locked():
                    record = plan_record(read_state(), args[1])
                display_plan(record)
                result = {"run_id": args[1], "status": record["status"], "dry_run": True}
            else:
                result = cancel(args[1])
        elif command == "reconcile":
            if len(args) != 1:
                fail("uso: bk supervisor reconcile")
            result = reconcile(dry_run)
        else:
            if len(args) != 1:
                fail("uso: bk supervisor status")
            result = status()
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f"bk supervisor: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
