#!/usr/bin/env python3
"""Store and summarize local, privacy-minimized routing feedback (project ADR-002).

  bk routing dispatch | outcome   validate one JSON object from stdin and append it to events.jsonl
  bk routing summary              per-cell metrics of the last 180 days (individual events)
  bk routing compact [--dry-run]  fold the events older than 180 days into monthly aggregates and drop them
  bk routing aggregates           the monthly aggregates (older than the window)

Retention (ADR-002 D9): an individual line lives at most RETENTION_DAYS. A task (run_id + task_id: its dispatches
and outcomes) is compacted as a whole as soon as its oldest line expires, so no line outlives the limit; its newer
lines are dropped early and leave the summary window early. `dispatch`, `outcome` and `summary` compact first, so
the limit holds without a scheduler.

Store layout (${XDG_STATE_HOME:-~/.local/state}/bk/routing/, 0700, files 0600):
  events.jsonl        individual events (append-only between compactions)
  aggregates.json     monthly cells without run/task/issue/repo IDs or free text; carries a `generation`
  .lock               flock: every read and write of the store takes it, so an append never races a rewrite
  events.jsonl.gen-N  the compacted events file waiting to replace events.jsonl (crash window only)

Crash-safe, idempotent compaction: write events.jsonl.gen-<G+1> completely (fsync), then replace aggregates.json
with generation G+1 (the commit point), then rename the gen file over events.jsonl. On the next lock, recover()
finishes a committed rename (N == G) or deletes an uncommitted one (N != G). Running compact again with nothing
expired changes nothing.
"""
import fcntl
import glob
import json
import os
import re
import sys
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone

STATE_HOME = os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
STORE_DIR = os.path.join(STATE_HOME, "bk", "routing")
EVENTS = os.path.join(STORE_DIR, "events.jsonl")
AGGREGATES = os.path.join(STORE_DIR, "aggregates.json")
LOCK = os.path.join(STORE_DIR, ".lock")
RETENTION_DAYS = 180
AGG_SCHEMA = "bk.routing-aggregates.v1"
HIST_FIELDS = ("review_rounds", "human_interventions", "blockers_count", "duration_s")
HIST_CAP_FIELDS = {"review_rounds", "human_interventions", "blockers_count"}
HIST_CAP = 10   # small-count metrics at 10 or more share the "10+" bucket
INT_FIELDS = ("duration_s", "review_rounds", "blockers_count", "human_interventions", "context_compactions",
              "fresh_sessions", "context_peak")
BOOL_FIELDS = ("ci_first_pass", "merged")
TASK_TYPES = {"feature", "fix", "hotfix", "review", "documentation", "refactor", "other"}
AREAS = {"agents", "cli", "herdr", "docs", "infra", "other", "unknown"}
PRIORITIES = {"low", "normal", "high", "critical"}
RISK_FLAGS = {"business_logic", "sensitive_path", "hotfix", "security"}
PROVIDERS = {"claude", "codex", "agy", "unknown"}
HARNESSES = {"claude-code", "codex", "herdr", "unknown"}
ROLES = {"orchestrator", "implementer", "implementer-light", "reviewer", "documentation", "reader"}
REASONS = {"affinity", "load_balance", "exploration", "hotfix", "manual", "fallback"}
APPROVALS = {"pending", "approved", "overridden", "rejected"}
OVERRIDES = {"human_choice", "candidate_unavailable", "policy_gate", "rejected", "other"}
STATUSES = {"completed", "failed", "incomplete", "cancelled"}
RESULTS = {"pr", "blocked", "escalated", "dropped", "question"}
CONTEXT_SOURCES = {"harness", "provider", "unknown"}
MODEL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,79})?$")
UTC_TS = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$")
REASON_DETAILS = {"model_affinity", "role_affinity", "known_success", "lower_load", "slot_available",
                  "low_sample", "explicit_exploration", "hotfix_priority", "user_selected",
                  "provider_unavailable", "policy_fallback", "unknown"}


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


def integer(value, field, minimum=0):
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


def model(value):
    if not isinstance(value, str) or not MODEL_ID.fullmatch(value):
        fail("valor inválido en model_id")


def candidate(value):
    require_keys(value, ("provider", "model_id", "harness", "role", "active_slots", "evidence_n"))
    enum(value["provider"], PROVIDERS, "provider")
    model(value["model_id"])
    enum(value["harness"], HARNESSES, "harness")
    enum(value["role"], ROLES, "role")
    integer(value["active_slots"], "active_slots")
    integer(value["evidence_n"], "evidence_n")


def selected(value):
    require_keys(value, ("provider", "model_id", "harness", "role"))
    enum(value["provider"], PROVIDERS, "provider")
    model(value["model_id"])
    enum(value["harness"], HARNESSES, "harness")
    enum(value["role"], ROLES, "role")


def validate_dispatch(data):
    require_keys(data, ("run_id", "task_id", "issue", "task_type", "area", "priority", "critical",
                        "risk_flags", "eligible", "selected", "reason_code", "reason_detail_code",
                        "evidence_window_days",
                        "approval"), ("override_code",))
    identifier(data["run_id"], "run_id")
    identifier(data["task_id"], "task_id")
    integer(data["issue"], "issue", 1)
    enum(data["task_type"], TASK_TYPES, "task_type")
    enum(data["area"], AREAS, "area")
    enum(data["priority"], PRIORITIES, "priority")
    if not isinstance(data["critical"], bool):
        fail("valor inválido en critical")
    integer(data["evidence_window_days"], "evidence_window_days", 1)
    if (not isinstance(data["risk_flags"], list)
            or any(not isinstance(flag, str) for flag in data["risk_flags"])
            or len(data["risk_flags"]) != len(set(data["risk_flags"]))):
        fail("valor inválido en risk_flags")
    for flag in data["risk_flags"]:
        enum(flag, RISK_FLAGS, "risk_flags")
    if not isinstance(data["eligible"], list) or not data["eligible"]:
        fail("eligible debe tener al menos un candidato")
    for item in data["eligible"]:
        candidate(item)
    selected(data["selected"])
    selected_key = tuple(data["selected"][field] for field in ("provider", "model_id", "harness", "role"))
    if not any(tuple(item[field] for field in ("provider", "model_id", "harness", "role")) == selected_key
               for item in data["eligible"]):
        fail("selected debe estar en eligible")
    enum(data["reason_code"], REASONS, "reason_code")
    enum(data["reason_detail_code"], REASON_DETAILS, "reason_detail_code")
    enum(data["approval"], APPROVALS, "approval")
    if "override_code" in data:
        enum(data["override_code"], OVERRIDES, "override_code")
    if data["approval"] in ("overridden", "rejected") and "override_code" not in data:
        fail("override_code es obligatorio para approval overridden o rejected")
    if data["approval"] in ("pending", "approved") and "override_code" in data:
        fail("override_code no corresponde a approval pending o approved")


def validate_outcome(data):
    require_keys(data, ("run_id", "task_id", "status", "result_kind", "provider", "model_id", "harness",
                        "duration_s", "review_rounds", "blockers_count", "ci_first_pass", "merged",
                        "human_interventions", "context_compactions", "fresh_sessions", "context_peak",
                        "context_source"))
    identifier(data["run_id"], "run_id")
    identifier(data["task_id"], "task_id")
    enum(data["status"], STATUSES, "status")
    enum(data["result_kind"], RESULTS, "result_kind")
    enum(data["provider"], PROVIDERS, "provider")
    model(data["model_id"])
    enum(data["harness"], HARNESSES, "harness")
    for field in ("duration_s", "review_rounds", "blockers_count", "human_interventions",
                  "context_compactions", "fresh_sessions"):
        if data[field] is not None:
            integer(data[field], field)
    for field in ("ci_first_pass", "merged"):
        if data[field] is not None and not isinstance(data[field], bool):
            fail(f"valor inválido en {field}")
    if data["context_peak"] is not None:
        integer(data["context_peak"], "context_peak")
    enum(data["context_source"], CONTEXT_SOURCES, "context_source")


def validate_event(event):
    if not isinstance(event, dict) or event.get("v") != 1 or event.get("kind") not in ("dispatch", "outcome"):
        fail("evento inválido")
    if not isinstance(event.get("event_id"), str):
        fail("evento inválido")
    try:
        if str(uuid.UUID(event["event_id"])) != event["event_id"]:
            fail("evento inválido")
    except ValueError:
        fail("evento inválido")
    if not isinstance(event.get("ts"), str) or not UTC_TS.fullmatch(event["ts"]) or parse_ts(event["ts"]) is None:
        fail("evento inválido")
    payload = {key: value for key, value in event.items() if key not in ("v", "event_id", "ts", "kind")}
    (validate_dispatch if event["kind"] == "dispatch" else validate_outcome)(payload)


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_ts(value):
    """Epoch seconds of an event's ts, or None if it is not a UTC timestamp."""
    if not isinstance(value, str) or not UTC_TS.fullmatch(value):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.timestamp() if parsed.tzinfo else None


def ensure_dir():
    os.makedirs(STORE_DIR, mode=0o700, exist_ok=True)
    os.chmod(STORE_DIR, 0o700)


def fsync_dir():
    fd = os.open(STORE_DIR, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_atomic(path, text):
    """Write text to path in one step: temp file in the same dir, fsync, rename. Never a half-written file."""
    fd, tmp = tempfile.mkstemp(dir=STORE_DIR, prefix=".routing-tmp-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        fsync_dir()
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


@contextmanager
def locked(recover_state=True, create=True):
    """Lock the store; mutating operations are exclusive, dry-run readers are shared and do not recover state."""
    if not os.path.isdir(STORE_DIR):
        if not create:
            yield
            return
        ensure_dir()
    elif create:
        ensure_dir()
    if not create and not os.path.exists(LOCK):
        yield
        return
    flags = os.O_RDWR | os.O_CREAT if create else os.O_RDONLY
    fd = os.open(LOCK, flags, 0o600) if create else os.open(LOCK, flags)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if create else fcntl.LOCK_SH)
        if recover_state:
            recover()
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def empty_aggregates():
    return {"schema": AGG_SCHEMA, "generation": 0, "retention_days": RETENTION_DAYS, "outcomes": [], "dispatches": []}


def count_map(value, allowed, field):
    if not isinstance(value, dict) or any(not isinstance(key, str) or key not in allowed for key in value):
        fail(f"agregado inválido en {field}")
    for count in value.values():
        integer(count, field)


def validate_aggregate_rows(data):
    require_keys(data, ("schema", "generation", "retention_days", "outcomes", "dispatches"), ("compacted_at",))
    integer(data["generation"], "generation")
    if data["schema"] != AGG_SCHEMA or data["retention_days"] != RETENTION_DAYS:
        fail("versión o retención inválida en agregados")
    if "compacted_at" in data and (not isinstance(data["compacted_at"], str)
                                    or not UTC_TS.fullmatch(data["compacted_at"])):
        fail("marca temporal inválida en agregados")
    if not isinstance(data["outcomes"], list) or not isinstance(data["dispatches"], list):
        fail("filas inválidas en agregados")
    outcome_fields = {"month", "provider", "model_id", "harness", "role", "task_type", "area", "n", "with_dispatch",
                      "status", "result_kind", "context_source", "clean_success", "clean_success_known", "metrics",
                      "flags", "histograms"}
    dispatch_fields = set(DISPATCH_KEYS) | {"n", "eligible_total", "risk_flags"}
    for cell in data["outcomes"]:
        require_keys(cell, outcome_fields)
        if not isinstance(cell["month"], str) or not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", cell["month"]):
            fail("mes inválido en agregado")
        enum(cell["provider"], PROVIDERS, "provider")
        model(cell["model_id"])
        enum(cell["harness"], HARNESSES, "harness")
        enum(cell["role"], ROLES | {"unknown"}, "role")
        enum(cell["task_type"], TASK_TYPES | {"unknown"}, "task_type")
        enum(cell["area"], AREAS, "area")
        for field in ("n", "with_dispatch", "clean_success", "clean_success_known"):
            integer(cell[field], field)
        count_map(cell["status"], STATUSES, "status")
        count_map(cell["result_kind"], RESULTS, "result_kind")
        count_map(cell["context_source"], CONTEXT_SOURCES, "context_source")
        require_keys(cell["metrics"], INT_FIELDS)
        for field in INT_FIELDS:
            metric = cell["metrics"][field]
            require_keys(metric, ("known", "unknown", "sum", "min", "max"))
            for count in ("known", "unknown", "sum"):
                integer(metric[count], count)
            for bound in ("min", "max"):
                if metric[bound] is not None:
                    integer(metric[bound], bound)
        require_keys(cell["flags"], BOOL_FIELDS)
        for field in BOOL_FIELDS:
            require_keys(cell["flags"][field], ("true", "false", "unknown"))
            for count in cell["flags"][field].values():
                integer(count, field)
        require_keys(cell["histograms"], HIST_FIELDS)
        for field in HIST_FIELDS:
            values = cell["histograms"][field]
            if not isinstance(values, dict):
                fail(f"histograma inválido en {field}")
            for label, count in values.items():
                if not isinstance(label, str) or not label.isdigit() and not (field in HIST_CAP_FIELDS and label == "10+"):
                    fail(f"histograma inválido en {field}")
                integer(count, field)
    for cell in data["dispatches"]:
        require_keys(cell, dispatch_fields)
        if not isinstance(cell["month"], str) or not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", cell["month"]):
            fail("mes inválido en agregado")
        enum(cell["provider"], PROVIDERS, "provider")
        model(cell["model_id"])
        enum(cell["harness"], HARNESSES, "harness")
        enum(cell["role"], ROLES, "role")
        enum(cell["task_type"], TASK_TYPES, "task_type")
        enum(cell["area"], AREAS, "area")
        enum(cell["priority"], PRIORITIES, "priority")
        if not isinstance(cell["critical"], bool):
            fail("critical inválido en agregado")
        enum(cell["reason_code"], REASONS, "reason_code")
        enum(cell["reason_detail_code"], REASON_DETAILS, "reason_detail_code")
        enum(cell["approval"], APPROVALS, "approval")
        if cell["override_code"] != "none":
            enum(cell["override_code"], OVERRIDES, "override_code")
        for field in ("n", "eligible_total"):
            integer(cell[field], field)
        count_map(cell["risk_flags"], RISK_FLAGS, "risk_flags")


def load_aggregates():
    try:
        with open(AGGREGATES, encoding="utf-8") as stream:
            data = json.load(stream)
    except FileNotFoundError:
        return empty_aggregates()
    if not isinstance(data, dict):
        # Never overwrite what cannot be read: that would drop the counts already compacted.
        raise ValueError(f"{AGGREGATES} no es un archivo de agregados válido; revisalo antes de compactar")
    try:
        validate_aggregate_rows(data)
    except (ValueError, TypeError, KeyError):
        raise ValueError(f"{AGGREGATES} no es un archivo de agregados válido; revisalo antes de compactar") from None
    return data


def recover():
    """Finish or roll back a compaction cut by a crash (call with the lock held). With unreadable aggregates it
    leaves the gen file alone: load_aggregates() then stops every write until the person looks at it."""
    try:
        generation = load_aggregates()["generation"]
    except ValueError:
        generation = None
    for path in glob.glob(EVENTS + ".gen-*"):
        suffix = path.rsplit(".gen-", 1)[1]
        if generation is not None and suffix.isdigit() and int(suffix) == generation:
            os.replace(path, EVENTS)   # aggregates already committed: the events file must follow
            fsync_dir()
        elif generation is not None:
            os.unlink(path)            # not committed: the old events file is still the truth
    for path in glob.glob(os.path.join(STORE_DIR, ".routing-tmp-*")):
        try:
            os.unlink(path)
        except OSError:
            pass


def record(kind, data):
    (validate_dispatch if kind == "dispatch" else validate_outcome)(data)
    with locked():
        event_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"bk.routing.v1:{kind}:{data['run_id']}:{data['task_id']}"))
        for existing in read_events():
            if existing.get("event_id") != event_id:
                continue
            old_payload = {k: v for k, v in existing.items() if k not in ("v", "event_id", "ts", "kind")}
            if old_payload != data:
                fail(f"ya existe un evento {kind} distinto para esta tarea")
            compact_locked()
            return existing
        now = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        event = {"v": 1, "event_id": event_id, "ts": now, "kind": kind, **data}
        fd = os.open(EVENTS, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
        os.fchmod(fd, 0o600)
        try:
            size = os.lseek(fd, 0, os.SEEK_END)
            prefix = b"" if size == 0 or os.pread(fd, 1, size - 1) == b"\n" else b"\n"
            encoded = prefix + json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
            offset = 0
            while offset < len(encoded):
                written = os.write(fd, encoded[offset:])
                if written == 0:
                    raise OSError("no se pudo anexar el evento")
                offset += written
            os.fsync(fd)
            if size == 0:
                fsync_dir()
        finally:
            os.close(fd)
        compact_locked()
    return event


def read_lines():
    """(raw line, event or None) for every line of events.jsonl; None marks a line that is not a valid v1 event."""
    try:
        with open(EVENTS, "rb") as stream:
            for raw in stream:
                if not raw.strip():
                    continue
                try:
                    event = json.loads(raw.decode("utf-8"))
                    validate_event(event)
                except (UnicodeDecodeError, ValueError, TypeError, KeyError):
                    yield raw, None
                    continue
                yield raw, event
    except FileNotFoundError:
        return


def read_events():
    for _, event in read_lines():
        if event is not None:
            yield event


def hist_key(field, value):
    return f"{HIST_CAP}+" if field in HIST_CAP_FIELDS and value >= HIST_CAP else str(value)


def outcome_cell(cells, event, dispatch):
    """Add an expired outcome to its monthly cell (month of the outcome; role, type and area from its dispatch)."""
    dispatch = dispatch or {}
    chosen = dispatch.get("selected", {})
    key = {"month": event["ts"][:7], "provider": event.get("provider", "unknown"),
           "model_id": event.get("model_id", "unknown"), "harness": event.get("harness", "unknown"),
           "role": chosen.get("role", "unknown"), "task_type": dispatch.get("task_type", "unknown"),
           "area": dispatch.get("area", "unknown")}
    ident = tuple(key.values())
    cell = cells.get(ident)
    if cell is None:
        cell = cells[ident] = {**key, "n": 0, "with_dispatch": 0, "status": {}, "result_kind": {},
                               "context_source": {}, "clean_success": 0, "clean_success_known": 0,
                               "metrics": {f: {"known": 0, "unknown": 0, "sum": 0, "min": None, "max": None}
                                           for f in INT_FIELDS},
                               "flags": {f: {"true": 0, "false": 0, "unknown": 0} for f in BOOL_FIELDS},
                               "histograms": {f: {} for f in HIST_FIELDS}}
    cell["n"] += 1
    cell["with_dispatch"] += int(bool(dispatch))
    for field in ("status", "result_kind", "context_source"):
        value = event.get(field, "unknown")
        cell[field][value] = cell[field].get(value, 0) + 1
    # Same definition as summary(): completed PR, merged, at most one review round; unknown while merged is null.
    completed_pr = event.get("status") == "completed" and event.get("result_kind") == "pr"
    unknown = completed_pr and (event.get("merged") is None
                                or (event.get("merged") is True and event.get("review_rounds") is None))
    if not unknown:
        cell["clean_success_known"] += 1
        cell["clean_success"] += int(completed_pr and event.get("merged") is True
                                     and isinstance(event.get("review_rounds"), int) and event["review_rounds"] <= 1)
    for field in INT_FIELDS:
        value, metric = event.get(field), cell["metrics"][field]
        if isinstance(value, int) and not isinstance(value, bool):
            metric["known"] += 1
            metric["sum"] += value
            metric["min"] = value if metric["min"] is None else min(metric["min"], value)
            metric["max"] = value if metric["max"] is None else max(metric["max"], value)
            if field in HIST_FIELDS:
                bucket = cell["histograms"][field]
                label = hist_key(field, value)
                bucket[label] = bucket.get(label, 0) + 1
        else:
            metric["unknown"] += 1
    for field in BOOL_FIELDS:
        value = event.get(field)
        cell["flags"][field]["true" if value is True else "false" if value is False else "unknown"] += 1


def dispatch_cell(cells, event):
    """Add an expired dispatch (a proposal) to its monthly cell, by what was proposed and why."""
    chosen = event.get("selected", {})
    key = {"month": event["ts"][:7], "provider": chosen.get("provider", "unknown"),
           "model_id": chosen.get("model_id", "unknown"), "harness": chosen.get("harness", "unknown"),
           "role": chosen.get("role", "unknown"), "task_type": event.get("task_type", "unknown"),
           "area": event.get("area", "unknown"), "priority": event.get("priority", "unknown"),
           "critical": event.get("critical") is True, "reason_code": event.get("reason_code", "unknown"),
           "reason_detail_code": event.get("reason_detail_code", "unknown"),
           "approval": event.get("approval", "unknown"), "override_code": event.get("override_code", "none")}
    ident = tuple(key.values())
    cell = cells.get(ident)
    if cell is None:
        cell = cells[ident] = {**key, "n": 0, "eligible_total": 0, "risk_flags": {}}
    cell["n"] += 1
    cell["eligible_total"] += len(event.get("eligible") or [])
    for flag in event.get("risk_flags") or []:
        cell["risk_flags"][flag] = cell["risk_flags"].get(flag, 0) + 1


OUTCOME_KEYS = ("month", "provider", "model_id", "harness", "role", "task_type", "area")
DISPATCH_KEYS = ("month", "provider", "model_id", "harness", "role", "task_type", "area", "priority", "critical",
                 "reason_code", "reason_detail_code", "approval", "override_code")


def merge_cells(old, new, keys):
    """Add the counts of the new cells into the old ones with the same key; returns the merged list, sorted."""
    def add(a, b):
        for k, v in b.items():
            if isinstance(v, dict):
                add(a.setdefault(k, {}), v)
            elif k in ("min", "max"):
                pick = min if k == "min" else max
                a[k] = v if a.get(k) is None else a[k] if v is None else pick(a[k], v)
            elif isinstance(v, int) and not isinstance(v, bool):
                a[k] = a.get(k, 0) + v
    index = {tuple(c.get(k) for k in keys): c for c in old}
    for cell in new:
        ident = tuple(cell.get(k) for k in keys)
        if ident in index:
            add(index[ident], {k: v for k, v in cell.items() if k not in keys})
        else:
            index[ident] = cell
    return sorted(index.values(), key=lambda c: tuple(str(c.get(k)) for k in keys))


def compact_locked(dry_run=False, now=None):
    """Fold every task whose oldest line is past the retention into monthly cells and drop all its lines; lines that
    are not valid v1 events are dropped too. Call with the lock held. Returns a report with counts only."""
    now = datetime.now(timezone.utc).timestamp() if now is None else now
    cutoff = now - RETENTION_DAYS * 86400
    lines = list(read_lines())
    groups = {}
    for _, event in lines:
        if event is not None:
            groups.setdefault((event.get("run_id"), event.get("task_id")), []).append(event)
    expired = {k for k, evs in groups.items() if min(parse_ts(e["ts"]) for e in evs) < cutoff}
    malformed = sum(1 for _, e in lines if e is None)
    report = {"cutoff": iso(cutoff), "expired_tasks": len(expired),
              "expired_events": sum(len(groups[k]) for k in expired), "malformed_dropped": malformed,
              "kept_events": sum(len(v) for k, v in groups.items() if k not in expired), "dry_run": dry_run}
    if dry_run or (not expired and not malformed):
        return report   # nothing to do: no write, no new generation (idempotent)
    outcomes, dispatches = {}, {}
    for key in expired:
        last_dispatch = None
        for event in sorted(groups[key], key=lambda e: parse_ts(e["ts"])):
            if event["kind"] == "dispatch":
                dispatch_cell(dispatches, event)
                last_dispatch = event
            else:
                outcome_cell(outcomes, event, last_dispatch)
    store = load_aggregates()
    generation = store["generation"] + 1
    store.update({"schema": AGG_SCHEMA, "generation": generation, "retention_days": RETENTION_DAYS,
                  "compacted_at": iso(now),
                  "outcomes": merge_cells(store.get("outcomes", []), list(outcomes.values()), OUTCOME_KEYS),
                  "dispatches": merge_cells(store.get("dispatches", []), list(dispatches.values()), DISPATCH_KEYS)})
    kept = b"".join(raw if raw.endswith(b"\n") else raw + b"\n" for raw, e in lines
                    if e is not None and (e.get("run_id"), e.get("task_id")) not in expired).decode("utf-8")
    pending = f"{EVENTS}.gen-{generation}"
    write_atomic(pending, kept)                                                          # 1. new events, complete
    write_atomic(AGGREGATES, json.dumps(store, ensure_ascii=False, indent=1) + "\n")     # 2. commit point
    os.replace(pending, EVENTS)                                                          # 3. follow the commit
    fsync_dir()
    report["generation"] = generation
    return report


def compact(dry_run=False):
    with locked(recover_state=not dry_run, create=not dry_run):
        return compact_locked(dry_run=dry_run)


def aggregates(dry_run=False):
    with locked(recover_state=not dry_run, create=not dry_run):
        return load_aggregates()


def summary(window_days=RETENTION_DAYS, dry_run=False):
    now = datetime.now(timezone.utc).timestamp()
    with locked(recover_state=not dry_run, create=not dry_run):
        if not dry_run:
            compact_locked(now=now)
        events = list(read_events())
        archived = load_aggregates()
    as_of = datetime.fromtimestamp(now, timezone.utc)
    since = now - window_days * 86400
    dispatches = {}
    pairs = {}
    for event in events:
        try:
            event_time = datetime.fromisoformat(event.get("ts", "").replace("Z", "+00:00")).timestamp()
        except (TypeError, ValueError):
            continue
        key_task = (event.get("run_id"), event.get("task_id"))
        if event.get("kind") == "dispatch":
            dispatches[key_task] = event
            continue
        if event_time < since:
            continue
        if event.get("kind") != "outcome":
            continue
        dispatch = dispatches.get(key_task, {})
        chosen = dispatch.get("selected", {})
        key = (event.get("provider", "unknown"), event.get("model_id", "unknown"), event.get("harness", "unknown"),
               chosen.get("role", "unknown"), dispatch.get("task_type", "unknown"), dispatch.get("area", "unknown"))
        item = pairs.setdefault(key, {"n": 0, "clean_success": 0, "clean_success_known": 0, "escalated": 0,
                                      "review_rounds": [], "duration_s": [], "human_interventions": []})
        item["n"] += 1
        clean_unknown = (event.get("status") == "completed" and event.get("result_kind") == "pr"
                         and (event.get("merged") is None
                              or (event.get("merged") is True and event.get("review_rounds") is None)))
        if not clean_unknown:
            item["clean_success_known"] += 1
            item["clean_success"] += int(event.get("status") == "completed" and event.get("result_kind") == "pr"
                                          and event.get("merged") is True and event.get("review_rounds") <= 1)
        if event.get("result_kind") == "escalated":
            item["escalated"] += 1
        for field in ("review_rounds", "duration_s", "human_interventions"):
            if isinstance(event.get(field), int) and not isinstance(event[field], bool):
                item[field].append(event[field])
    by_candidate = {}
    for (provider, model_id, harness, role, task_type, area), data in pairs.items():
        by_candidate.setdefault((provider, model_id, harness, role, task_type), {})[area] = data

    def combine(parts):
        merged = {"n": 0, "clean_success": 0, "clean_success_known": 0, "escalated": 0,
                  "review_rounds": [], "duration_s": [], "human_interventions": []}
        for part in parts:
            for field in ("n", "clean_success", "clean_success_known", "escalated"):
                merged[field] += part[field]
            for field in ("review_rounds", "duration_s", "human_interventions"):
                merged[field].extend(part[field])
        return merged

    output = []
    for (provider, model_id, harness, role, task_type), areas in sorted(by_candidate.items()):
        all_area_n = sum(data["n"] for data in areas.values())
        if all_area_n < 20:
            display_areas = {"suppressed": combine(areas.values())}
        else:
            display_areas = {area: data for area, data in areas.items() if data["n"] >= 20}
            small = [data for data in areas.values() if data["n"] < 20]
            if small:
                display_areas["suppressed"] = combine(small)
        for area, data in sorted(display_areas.items()):
            n = data["n"]
            level = "insufficient" if n < 20 else "exploratory" if n < 50 else "established"
            row = {"provider": provider, "model_id": model_id, "harness": harness, "role": role,
                   "task_type": task_type, "area": area, "n": n, "evidence_level": level,
                   "clean_success_rate": (data["clean_success"] / data["clean_success_known"]
                                          if data["clean_success_known"] else None),
                   "clean_success_coverage": data["clean_success_known"] / n if n else 0,
                   "escalation_rate": data["escalated"] / n if n else 0}
            for field, source in (("review_rounds_median", "review_rounds"), ("median_duration_s", "duration_s"),
                                  ("human_interventions_median", "human_interventions")):
                values = sorted(data[source])
                if values:
                    mid = len(values) // 2
                    row[field] = values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2
                else:
                    row[field] = None
            row["coverage"] = {field: len(data[source]) / n for field, source in
                               (("review_rounds", "review_rounds"), ("duration_s", "duration_s"),
                                ("human_interventions", "human_interventions"))}
            row["trend"] = "unknown"
            output.append(row)
    stamp = as_of.isoformat(timespec="seconds").replace("+00:00", "Z")
    start = datetime.fromtimestamp(since, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    return {"schema": "bk.routing-summary.v1", "as_of": stamp, "window": {"from": start, "to": stamp,
                                                                          "days": window_days}, "groups": output,
            "archive": {"outcomes": archived["outcomes"], "dispatches": archived["dispatches"]}}


def main(argv):
    args = argv[1:]
    dry_run = "--dry-run" in args
    args = [arg for arg in args if arg != "--dry-run"]
    if len(args) != 1 or args[0] not in ("dispatch", "outcome", "summary", "compact", "aggregates"):
        print("uso: bk routing {dispatch|outcome|summary|compact [--dry-run]|aggregates}"
              "  (dispatch/outcome leen un objeto JSON de stdin)", file=sys.stderr)
        return 2
    command = args[0]
    try:
        if command == "summary":
            print(json.dumps(summary(dry_run=dry_run), ensure_ascii=False, indent=2))
        elif command == "compact":
            print(json.dumps(compact(dry_run=dry_run), ensure_ascii=False, indent=2))
        elif command == "aggregates":
            print(json.dumps(aggregates(dry_run=dry_run), ensure_ascii=False, indent=2))
        else:
            payload = json.load(sys.stdin)
            (validate_dispatch if command == "dispatch" else validate_outcome)(payload)
            if dry_run:
                print(json.dumps({"dry_run": True, "kind": command, "valid": True}))
            else:
                event = record(command, payload)
                print(json.dumps({"event_id": event["event_id"], "kind": event["kind"], "ts": event["ts"]}))
    except (ValueError, OSError) as exc:
        print(f"bk routing: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
