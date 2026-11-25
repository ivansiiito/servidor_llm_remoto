# /// script
# requires-python = ">=3.12"
# ///
"""Proxy que reparte las peticiones entre el modelo de lenguaje y el de embeddings.

Uso: uv run proxy.py PUERTO PUERTO_LENGUAJE PUERTO_EMBEDDINGS

Las rutas de embeddings van a bge-m3 y todo lo demás al modelo de lenguaje.
Cada petición se atiende en su propio hilo y las respuestas en streaming se
reenvían trozo a trozo, en cuanto llegan.
"""

import http.client
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RUTAS_EMBEDDINGS = ('/v1/embeddings', '/embeddings')
# Cabeceras que describen la conexión y no se reenvían.
CABECERAS_DE_SALTO = {
    'connection',
    'keep-alive',
    'proxy-connection',
    'transfer-encoding',
    'te',
    'trailer',
    'upgrade',
    'host',
}
TAMANO_TROZO = 65536


def elegir_puerto(ruta: str, puerto_lenguaje: int, puerto_embeddings: int) -> int:
    """Devuelve el puerto del servidor que debe atender una ruta.

    :param ruta: Ruta de la petición, con o sin parámetros.
    :param puerto_lenguaje: Puerto del modelo de lenguaje.
    :param puerto_embeddings: Puerto del modelo de embeddings.
    :return: Puerto al que se reenvía la petición.
    """
    ruta_sin_parametros = ruta.split('?', 1)[0].rstrip('/')
    if ruta_sin_parametros in RUTAS_EMBEDDINGS:
        return puerto_embeddings
    return puerto_lenguaje


class Reenviador(BaseHTTPRequestHandler):
    """Reenvía cada petición al servidor que le corresponde."""

    puerto_lenguaje = 0
    puerto_embeddings = 0

    def reenviar(self) -> None:
        """Pasa la petición al servidor elegido y copia su respuesta.

        :return: Nada.
        """
        puerto = elegir_puerto(self.path, self.puerto_lenguaje, self.puerto_embeddings)
        longitud = int(self.headers.get('Content-Length') or 0)
        cuerpo = self.rfile.read(longitud) if longitud else None
        cabeceras = {
            nombre: valor
            for nombre, valor in self.headers.items()
            if nombre.lower() not in CABECERAS_DE_SALTO
        }
        # Sin tiempo de espera: una generación larga puede tardar minutos.
        conexion = http.client.HTTPConnection('127.0.0.1', puerto)
        try:
            try:
                conexion.request(self.command, self.path, body=cuerpo, headers=cabeceras)
                respuesta = conexion.getresponse()
            except OSError:
                self.responder_error(puerto)
                return
            self.send_response_only(respuesta.status, respuesta.reason)
            for nombre, valor in respuesta.getheaders():
                if nombre.lower() not in CABECERAS_DE_SALTO:
                    self.send_header(nombre, valor)
            # Respondemos en HTTP/1.0: el final del cuerpo es el cierre.
            self.send_header('Connection', 'close')
            self.end_headers()
            while trozo := respuesta.read1(TAMANO_TROZO):
                self.wfile.write(trozo)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # El cliente se ha ido: al cerrar la conexión con el servidor,
            # llama-server deja de generar, como si le hubiera llegado directa.
            pass
        finally:
            conexion.close()

    def responder_error(self, puerto: int) -> None:
        """Responde 502 cuando el servidor de destino no está disponible.

        :param puerto: Puerto que no ha respondido.
        :return: Nada.
        """
        error = {
            "code": 502,
            "message": f'El servidor del puerto {puerto} no responde',
            "type": 'unavailable_error',
        }
        mensaje = json.dumps({"error": error}).encode()
        self.send_response_only(502)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(mensaje)))
        self.end_headers()
        self.wfile.write(mensaje)

    do_GET = do_POST = do_PUT = do_DELETE = do_OPTIONS = do_HEAD = reenviar

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Silencia el registro de cada petición: ya lo hace llama-server.

        :param format: Formato del mensaje (nombre exigido por la clase base).
        :param args: Valores del mensaje.
        :return: Nada.
        """


def main() -> None:
    """Arranca el proxy con los puertos de la línea de órdenes.

    :return: Nada.
    """
    puerto, puerto_lenguaje, puerto_embeddings = (int(valor) for valor in sys.argv[1:4])
    Reenviador.puerto_lenguaje = puerto_lenguaje
    Reenviador.puerto_embeddings = puerto_embeddings
    servidor = ThreadingHTTPServer(('127.0.0.1', puerto), Reenviador)
    servidor.daemon_threads = True
    print(f'Proxy en 127.0.0.1:{puerto}: lenguaje {puerto_lenguaje}, '
          f'embeddings {puerto_embeddings}', flush=True)
    servidor.serve_forever()


if __name__ == '__main__':
    main()
