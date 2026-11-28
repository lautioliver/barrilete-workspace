"""Adaptador de Codex para el supervisor (#40, ADR-003 "Acreditación por harness").

session_state(session_id) -> "alive" | "absent" | "unknown", contrastando la marca de sesión que dejó el hook
con el proceso vivo (PID y hora de inicio). Ante cualquier duda, "unknown": eso nunca libera un lease.

Lo propio de Codex:
- Hoy falta evidencia (payload de sesión en los hooks, PID en terminal y en `codex app-server`): mientras
  EVIDENCE tenga algo en False, todo es "unknown". Se pasa a True solo con la verificación documentada en ADR-003.
- `codex app-server` es un daemon compartido: su PID no identifica una sesión.
- Un subagente comparte `session_id` con su padre (`parent_thread_id` en la marca): no se acredita.
- Codex declara `SessionEnd`: el fin exige `ended_at` y el proceso ausente (o el PID reusado).

La lectura de la marca (ruta, JSON, escritura atómica) es genérica y la trae #39: acá llega por `read_mark`.
Este módulo no se registra en `supervisor.HARNESS_ADAPTERS` (ADR-003: Codex no recibe adaptador hasta verificar).
"""
import os
import subprocess

import supervisor

HARNESS = "codex"
EVIDENCE = {"session_payload": False, "pid_terminal": False, "pid_app_server": False}
MARK_SCHEMA = 1


def is_app_server(command):
    words = command.split()
    return any(os.path.basename(w) == "codex" and words[i + 1:i + 2] == ["app-server"] for i, w in enumerate(words))


def is_codex(command):
    words = command.split()
    return any(os.path.basename(w) == "codex" for w in words[:2])


def process_info(pid):
    """(hora de inicio, comando) del PID, o None si no existe. OSError si ps no puede verificarlo."""
    start = supervisor.process_start_time(pid)
    if start is None:
        return None
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=5)
    if result.returncode != 0 or not result.stdout.strip():
        return None
    return start, result.stdout.strip()


class CodexAdapter:
    def __init__(self, read_mark, process_info=process_info, evidence=None):
        self.read_mark = read_mark
        self.process_info = process_info
        self.evidence = dict(EVIDENCE if evidence is None else evidence)

    def session_state(self, session_id):
        try:
            return self._state(session_id)
        except Exception:  # una falla del adaptador nunca prueba nada
            return "unknown"

    def _state(self, session_id):
        if not all(self.evidence.get(k) is True for k in EVIDENCE):
            return "unknown"
        mark = self.read_mark(HARNESS, session_id)
        if not isinstance(mark, dict) or mark.get("schema") != MARK_SCHEMA:
            return "unknown"
        if mark.get("harness") != HARNESS or mark.get("session_id") != session_id:
            return "unknown"
        if mark.get("parent_thread_id") is not None or mark.get("transport") == "app-server":
            return "unknown"
        pid, start, ended = mark.get("pid"), mark.get("process_start"), mark.get("ended_at")
        if type(pid) is not int or pid <= 1 or not isinstance(start, str) or not start:
            return "unknown"
        if ended is not None and not (isinstance(ended, str) and ended):
            return "unknown"
        proc = self.process_info(pid)  # si ps falla, session_state da unknown
        if proc is None or proc[0] != start:  # el proceso no está o el PID es de otro
            return "absent" if ended else "unknown"
        command = proc[1]
        if is_app_server(command) or not is_codex(command):
            return "unknown"
        return "unknown" if ended else "alive"
