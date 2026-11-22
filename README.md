# Servidor LLM remoto

Sirve en local, con `llama-server` (llama.cpp), el Qwen3.8-27B oficial en 4 bits y lo expone por ngrok con una API compatible con OpenAI y la misma clave que LM Studio. Sustituye a LM Studio como servidor para varios proyectos: solo cambia quién atiende el puerto 1234. Además puede cargar la LoRA del Setas (proyecto `../chat_setaloca`), que solo se aplica a las peticiones que la piden.

## Requisitos

- Windows con una GPU NVIDIA (probado en una RTX 5090 de 32 GB) y ngrok instalado y con sesión iniciada.
- El modelo `lmstudio-community/Qwen3.8-27B-GGUF` (Q4_K_M) descargado por LM Studio en `~/.lmstudio/models`.
- `bin/` con `llama-server.exe` (llama.cpp build 12633 para CUDA 13.5 y sus DLL) y `lora/setas-lora-f16.gguf`. Ambas carpetas están fuera de Git.
- Un `.env` (copia de `.env.example`) con `LM_STUDIO_API_KEY` y `NGROK_DOMINIO`.

## Arranque

1. Cierra LM Studio, o al menos su servidor, porque usa el mismo puerto 1234.
2. Ejecuta `iniciar.bat` y elige con el teclado: flechas arriba y abajo para el contexto (de 8.192 en 8.192), RePág y AvPág para saltos mayores, `L` para activar o quitar la LoRA, `V` para activar o quitar la visión (imágenes) e Intro para arrancar. Verás una estimación de la memoria de GPU, con un aviso si puede no caber.
3. Para saltarte el menú: `iniciar.bat -Contexto 65536 -SinLora -SinVision -SinNgrok -Puerto 1235`.

Para pararlo, pulsa Ctrl+C. Si ya hay un ngrok en marcha, el script no abre otro ni lo toca; si lo ha abierto el propio script, lo cierra al salir. Si cierras la ventana con la X en lugar de Ctrl+C, el ngrok puede quedarse abierto.

## Uso desde otros proyectos

Los mismos valores que con LM Studio: `LM_STUDIO_BASE_URL` (URL de ngrok terminada en `/v1`) y `LM_STUDIO_API_KEY`. El nombre del modelo se ignora. Funcionan el streaming, `reasoning_effort: none` y las respuestas estructuradas (`response_format` con `json_schema`). Sin indicar `reasoning_effort`, el modelo piensa antes de responder.

Para pedir la LoRA, añade `"lora": [{"id": 0, "scale": 1.0}]` al cuerpo de la petición. Sin ese campo se responde con el modelo base.

## Contexto y velocidad medidos

Con la RTX 5090, caché de contexto en 16 bits y 2 espacios de petición:

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
