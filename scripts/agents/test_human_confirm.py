"""Confirmación humana por el mecanismo del sistema (#57): estados permitido, cancelado, error y no disponible.

Nunca dispara una confirmación real: el backend se reemplaza por fixtures, y el osascript real se
reemplaza por un fake en subprocess.run. Datos ficticios: tarea-ficticia-1, bk say, etc.
"""
import os
import subprocess
import sys
import unittest
from unittest import mock

AQUI = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(os.path.dirname(AQUI)), "lib")
sys.path.insert(0, LIB)
import human_cli  # noqa: E402
import human_confirm  # noqa: E402


def fijo(estado):
    return lambda motivo: estado


def que_lanza(exc):
    def backend(motivo):
        raise exc
    return backend


class Estados(unittest.TestCase):
    def test_permitido_solo_con_ok(self):
        self.assertEqual(human_confirm.confirmar("bk say", "tarea-ficticia-1", fijo("ok")), (True, "ok"))

    def test_cancelado_o_denegado_no_permite(self):
        for estado in ("denied:-128", "denied:-2"):
            self.assertEqual(human_confirm.confirmar("bk approve", "tarea-ficticia-1", fijo(estado)),
                             (False, estado))

    def test_no_disponible_no_permite(self):
        self.assertEqual(human_confirm.confirmar("bk approve", "tarea-ficticia-1", fijo("unavailable")),
                         (False, "unavailable"))

    def test_error_o_timeout_no_permite(self):
        self.assertEqual(human_confirm.confirmar("bk say", "x", fijo("error"))[0], False)
        self.assertEqual(human_confirm.confirmar("bk say", "x", fijo("timeout"))[0], False)

    def test_excepcion_del_mecanismo_es_denegacion(self):
        self.assertEqual(human_confirm.confirmar("bk say", "x", que_lanza(OSError("ficticio"))), (False, "error"))

    def test_salida_desconocida_no_permite(self):
        self.assertEqual(human_confirm.confirmar("bk say", "x", fijo("sí, dale"))[0], False)


class Motivo(unittest.TestCase):
    """Lo que la persona ve: operación e identificador validado, nunca texto libre."""

    def visto(self, operacion, destino):
        vistos = []
        ok, estado = human_confirm.confirmar(operacion, destino, lambda m: vistos.append(m) or "ok")
        return ok, vistos

    def test_muestra_operacion_y_destino(self):
        ok, vistos = self.visto("bk supervisor approve", "run-ficticio-9")
        self.assertTrue(ok)
        self.assertEqual(vistos, ["bk supervisor approve run-ficticio-9"])

    def test_destino_con_saltos_o_espacios_se_deniega_sin_llamar_al_mecanismo(self):
        for destino in ("linea1\nlinea2", "tarea ficticia", "", "x" * 65, "-rf", None):
            vistos = []
            ok, estado = human_confirm.confirmar("bk say", destino, lambda m: vistos.append(m) or "ok")
            self.assertFalse(ok, repr(destino))
            self.assertEqual(vistos, [], repr(destino))

    def test_operacion_fuera_de_la_lista_se_deniega(self):
        vistos = []
        ok, _ = human_confirm.confirmar("bk merge", "tarea-ficticia-1", lambda m: vistos.append(m) or "ok")
        self.assertFalse(ok)
        self.assertEqual(vistos, [])


class Backend(unittest.TestCase):
    """touch_id() con osascript falso: solo interpreta la salida, nunca abre el diálogo."""

    def con_salida(self, stdout="", rc=0):
        return mock.patch.object(human_confirm.subprocess, "run",
                                 return_value=subprocess.CompletedProcess([], rc, stdout, ""))

    def test_interpreta_cada_salida(self):
        with self.con_salida("ok\n"):
            self.assertEqual(human_confirm.touch_id("motivo-ficticio"), "ok")
        with self.con_salida("denied:-128"):
            self.assertEqual(human_confirm.touch_id("motivo-ficticio"), "denied:-128")
        with self.con_salida("unavailable"):
            self.assertEqual(human_confirm.touch_id("motivo-ficticio"), "unavailable")

    def test_salida_rara_o_rc_distinto_de_cero_es_error(self):
        with self.con_salida("algo raro"):
            self.assertEqual(human_confirm.touch_id("m"), "error")
        with self.con_salida("ok", rc=1):
            self.assertEqual(human_confirm.touch_id("m"), "error")

    def test_timeout_es_timeout(self):
        with mock.patch.object(human_confirm.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired(["osascript"], 1)):
            self.assertEqual(human_confirm.touch_id("m"), "timeout")

    def test_el_script_va_por_stdin_y_el_motivo_por_argumento(self):
        with self.con_salida("ok") as run:
            human_confirm.touch_id("bk say tarea-ficticia-1")
        args, kwargs = run.call_args
        self.assertEqual(args[0][-1], "bk say tarea-ficticia-1")
        self.assertEqual(kwargs["input"], human_confirm.JXA)
        self.assertIn("LAPolicyDeviceOwnerAuthentication", kwargs["input"])

    def test_sin_osascript_es_error(self):
        with mock.patch.object(human_confirm.subprocess, "run", side_effect=OSError("ficticio")):
            self.assertEqual(human_confirm.touch_id("m"), "error")


class Cli(unittest.TestCase):
    """Lo que llama bk (bin/bk: confirmar_humano): 0 solo con ok; cualquier otra cosa es no."""

    def test_ok_sale_0(self):
        with mock.patch.object(human_confirm, "touch_id", return_value="ok"):
            self.assertEqual(human_confirm.main(["human_confirm.py", "bk say", "chat-ficticio-1"]), 0)

    def test_denegada_sale_1(self):
        with mock.patch.object(human_confirm, "touch_id", return_value="denied:-128"):
            self.assertEqual(human_confirm.main(["human_confirm.py", "bk approve", "tarea-ficticia-1"]), 1)

    def test_uso_incorrecto_sale_2(self):
        self.assertEqual(human_confirm.main(["human_confirm.py", "bk say"]), 2)


class Arbol(unittest.TestCase):
    """human_cli: solo niega a los agentes por el árbol; la confirmación va en cada efecto (bin/bk)."""

    def test_humano_pasa_sin_confirmar_en_el_gate(self):
        with mock.patch.object(human_cli, "reason", return_value=None), \
                mock.patch.object(human_confirm, "touch_id") as t:
            self.assertEqual(human_cli.main(["human_cli.py", "say"]), 0)
        t.assert_not_called()

    def test_agente_se_niega(self):
        with mock.patch.object(human_cli, "reason", return_value="the command was invoked from an agent session"):
            self.assertEqual(human_cli.main(["human_cli.py", "approve"]), 1)


if __name__ == "__main__":
    unittest.main()
