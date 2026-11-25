# Servidor LLM remoto

Sirve en local, con `llama-server` (llama.cpp), el Qwen3.8-27B oficial en 4 bits y lo expone por ngrok con una API compatible con OpenAI y la misma clave que LM Studio. Sustituye a LM Studio como servidor para varios proyectos: solo cambia quién atiende el puerto 1234. Además puede cargar la LoRA del Setas (proyecto `../chat_setaloca`), que solo se aplica a las peticiones que la piden.

## Requisitos

- Windows con una GPU NVIDIA (probado en una RTX 5090 de 32 GB) y ngrok instalado y con sesión iniciada.
- El modelo `lmstudio-community/Qwen3.8-27B-GGUF` (Q4_K_M) descargado por LM Studio en `~/.lmstudio/models`.
- `bin/` con `llama-server.exe` (llama.cpp build 12633 para CUDA 13.5 y sus DLL) y `lora/setas-lora-v2-p3-f16.gguf` (la LoRA v2 del Setas, que pide la búsqueda de actualidad; la v1, `setas-lora-f16.gguf`, se conserva). Ambas carpetas están fuera de Git.
- Un `.env` (copia de `.env.example`) con `LM_STUDIO_API_KEY` y `NGROK_DOMINIO`.

## Arranque

1. Cierra LM Studio, o al menos su servidor, porque usa el mismo puerto 1234.
2. Ejecuta `iniciar.bat` y elige con el teclado: flechas arriba y abajo para el contexto (de 8.192 en 8.192), RePág y AvPág para saltos mayores, `L` para activar o quitar la LoRA, `V` para activar o quitar la visión (imágenes), `E` para activar o quitar los embeddings e Intro para arrancar. Verás una estimación de la memoria de GPU, con un aviso si puede no caber.
3. Para saltarte el menú: `iniciar.bat -Contexto 65536 -SinLora -SinVision -SinEmbeddings -SinNgrok -Puerto 1235`.

Para pararlo, pulsa Ctrl+C. Si ya hay un ngrok en marcha, el script no abre otro ni lo toca; si lo ha abierto el propio script, lo cierra al salir. Si cierras la ventana con la X en lugar de Ctrl+C, el ngrok (y, con embeddings, el segundo servidor y el proxy) pueden quedarse abiertos.

## Una petición a la vez

El servidor atiende un solo espacio (`-np 1`): si dos proyectos o dos personas piden a la vez, la segunda petición **espera su turno y no da error** (`llama-server` encola las peticiones cuando no hay espacio libre). Así, toda la conversación que se está atendiendo dispone del contexto completo que elijas en el menú, en lugar de la mitad. Contrapartida: si dos conversaciones largas se alternan, el servidor tiene que releer el contexto de cada una cada vez, y al que espera le llega la respuesta más tarde. Los clientes deben tolerar esa espera (la web de `chat_setaloca` espera hasta 120 s).

## Uso desde otros proyectos

Los mismos valores que con LM Studio: `LM_STUDIO_BASE_URL` (URL de ngrok terminada en `/v1`) y `LM_STUDIO_API_KEY`. El nombre del modelo se ignora. Funcionan el streaming, `reasoning_effort: none` y las respuestas estructuradas (`response_format` con `json_schema`). Sin indicar `reasoning_effort`, el modelo piensa antes de responder.

Para pedir la LoRA, añade `"lora": [{"id": 0, "scale": 1.0}]` al cuerpo de la petición. Sin ese campo se responde con el modelo base.

## Contexto y velocidad medidos

Con la RTX 5090 y la caché de contexto en 16 bits (las mediciones se hicieron con 2 espacios; con 1 la memoria es la misma):

| Contexto | Memoria de GPU | Velocidad |
|---|---|---|
| 32.768 | 20,6 GB | 75 tok/s (50 con LoRA) |
| 131.072 | 26,8 GB | 75 tok/s |
| 200.000 | 31,2 GB | 75 tok/s |
| 220.000 | 31,8 GB | 22 tok/s (desborda a la RAM) |

Por encima de 200.000 el script comprime la caché a 8 bits, y con 262.144 (el máximo del modelo) sigue a unos 50 tok/s con 27,5 GB. Si hay otro modelo o aplicaciones usando la GPU, baja el contexto. Tener la LoRA cargada pero sin pedirla no ralentiza el resto de peticiones.

## Visión (imágenes)

Con la visión activada (por defecto), el servidor carga también el adaptador `mmproj-Qwen3.8-27B-BF16.gguf` de la carpeta de LM Studio y acepta imágenes en el formato de OpenAI (`{"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}`). Sin él, el servidor ignora las imágenes (`/props` indica `vision: false`).

- **Memoria medida:** la visión añade unos 1,8 GB de GPU (22,1 GB frente a 20,6 GB con 32.768 de contexto y LoRA). Con contextos muy largos puede no caber: el menú avisa y conviene quitarla con `V` o bajar el contexto.
- **Coste por imagen:** el logo del Setas (894×1338 píxeles) ocupó unos 1.180 tokens de contexto y se procesó en unos 2 segundos. Una imagen más pequeña ocupa menos.
- **Con la LoRA:** funciona (la LoRA solo toca las capas de lenguaje), pero se entrenó solo con texto y el estilo del Setas se nota poco al describir imágenes.

## Embeddings (bge-m3)

Con los embeddings activados (por defecto), el servidor atiende también `POST /v1/embeddings` con el modelo `gpustack/bge-m3-GGUF` (Q8_0, descargado por LM Studio en `~/.lmstudio/models`), por el mismo puerto, el mismo túnel y la misma clave. Devuelve vectores de 1.024 números ya normalizados, compatibles con los de `@cf/baai/bge-m3` de Cloudflare Workers AI (coseno de 0,999 entre ambos).

- **Cómo funciona:** bge-m3 corre en un segundo `llama-server` **solo por CPU** (8 hilos, sin memoria de GPU, unos 0,8 GB de RAM) en el puerto `Puerto + 101`, el Qwen pasa al `Puerto + 100` y `proxy.py` (Python sin dependencias, lanzado con `uv run`) atiende el puerto público: manda `/v1/embeddings` a bge-m3 y todo lo demás al Qwen, con el streaming trozo a trozo. Cada petición va en su propio hilo, así que un vector no espera a que termine una respuesta del chat. Los registros de los dos procesos van a `embeddings*.log` y `proxy*.log`.
- **Sin embeddings** (`E` o `-SinEmbeddings`), el servidor arranca exactamente como antes, sin proxy.
- **Velocidad medida:** 0,02 s una consulta corta, 0,09 s una tarjeta de unos 300 caracteres y 35 s para 546 tarjetas. Admite textos de hasta 8.192 tokens.
- **Requisito:** `uv` instalado (descarga un Python la primera vez si no lo hay).
