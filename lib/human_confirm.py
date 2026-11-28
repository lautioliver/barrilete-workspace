"""Confirmación de una persona por el mecanismo del sistema (macOS LocalAuthentication), #57.

Va después de human_cli.reason() (que niega a los agentes por el árbol de procesos) y antes del efecto.
Es fail-closed: solo "ok" permite la operación. Cancelar, error, timeout, salida no reconocida, un
mecanismo no disponible o un destino que no se puede mostrar sin ambigüedad la deniegan. No hay
fallback a TTY, no hay tokens reutilizables ni credenciales.

Frescura: cada pedido crea un LAContext nuevo sin permitir reutilizar la autenticación.
El diálogo muestra solo la operación y un identificador validado (nunca el texto de un mensaje).
"""
import re
import subprocess
import sys

OSASCRIPT = "/usr/bin/osascript"
TIMEOUT_S = 180  # una persona tiene este tiempo para responder; después se deniega

OPERACIONES = ("bk say", "bk approve", "bk cancel", "bk supervisor approve", "bk supervisor cancel")
# Identificador estable: si no cumple, no se muestra ni se recorta; se deniega.
DESTINO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,63}$")

# JXA (osascript -l JavaScript): llama a LAContext directamente, sin paquetes ni toolchain.
# deviceOwnerAuthentication: Touch ID o la contraseña del sistema, nunca el TTY.
# El run loop espera la respuesta del bloque; argv[0] es el motivo que la persona ve.
JXA = r"""
ObjC.import('Foundation');
ObjC.import('LocalAuthentication');
function run(argv) {
  const politica = $.LAPolicyDeviceOwnerAuthentication;
  const ctx = $.LAContext.alloc.init;
  if (!ctx.canEvaluatePolicyError(politica, null)) { return 'unavailable'; }
  let resultado = null;
  const respuesta = ObjC.block('v@?B@', function (ok, error) {
    resultado = ok ? 'ok' : ('denied:' + (error ? error.code : 'unknown'));
  });
  ctx.evaluatePolicyLocalizedReasonReply(politica, argv[0], respuesta);
  const bucle = $.NSRunLoop.currentRunLoop;
  while (resultado === null) {
    bucle.runModeBeforeDate($.NSDefaultRunLoopMode, $.NSDate.dateWithTimeIntervalSinceNow(0.2));
  }
  return resultado;
}
"""


def touch_id(motivo):
    """Backend real: 'ok', 'denied:<code>', 'unavailable', 'timeout' o 'error'. El script va por stdin."""
    try:
        r = subprocess.run([OSASCRIPT, "-l", "JavaScript", "-", motivo], input=JXA, capture_output=True,
                           text=True, timeout=TIMEOUT_S, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    except subprocess.TimeoutExpired:
        return "timeout"
    except OSError:
        return "error"
    if r.returncode != 0:
        return "error"
    salida = r.stdout.strip()
    if salida in ("ok", "unavailable") or salida.startswith("denied:"):
        return salida
    return "error"


def confirmar(operacion, destino, backend=None):
    """(ok, estado). Pide a la persona confirmar `operacion` sobre `destino` (identificador validado)."""
    if operacion not in OPERACIONES:
        return False, "operación no reconocida"
    if not isinstance(destino, str) or not DESTINO.fullmatch(destino):
        return False, "destino no mostrable sin ambigüedad"
    motivo = f"{operacion} {destino}"
    try:
        estado = (backend or touch_id)(motivo)
    except Exception:  # cualquier fallo del mecanismo es una denegación, nunca un permiso
        estado = "error"
    return estado == "ok", estado


def main(argv):
    """Uso desde bk: human_confirm.py <operación> <destino>. Sale 0 solo si la persona confirma."""
    if len(argv) != 3:
        print("uso: human_confirm.py <operación> <destino>", file=sys.stderr)
        return 2
    ok, estado = confirmar(argv[1], argv[2])
    if not ok:
        print(f"bk: confirmación denegada ({estado}); no se ejecuta", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
