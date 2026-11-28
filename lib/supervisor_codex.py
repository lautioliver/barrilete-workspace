"""Adaptador de Codex para el supervisor (#40). Stub del rojo: todavía no decide nada."""

EVIDENCE = {"session_payload": False, "pid_terminal": False, "pid_app_server": False}


class CodexAdapter:
    def __init__(self, read_mark, process_info=None, evidence=None):
        self.read_mark = read_mark

    def session_state(self, session_id):
        return "alive"
