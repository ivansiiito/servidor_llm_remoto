# Proyecto Servidor LLM remoto

Servidor local de modelos para varios proyectos de Iván: `llama-server` con el Qwen3.8-27B oficial (Q4_K_M de LM Studio), túnel de ngrok y, opcionalmente, la LoRA del Setas que se aplica por petición. Lee `README.md` para el uso y las mediciones.

## Reglas

- Las claves y el dominio de ngrok están en `.env` (fuera de Git) y no se muestran nunca. `.env.example` lista los nombres.
- `bin/`, `lora/` y los registros están fuera de Git.
- La LoRA se carga con `--lora-scaled RUTA:0.0` desde la carpeta del repositorio (el formato no admite `C:\`). `--lora-init-without-apply` no funciona en el build 12633: arrancaba con escala 1.
- Por encima de 200.000 de contexto se usa caché de 8 bits; con 16 bits la GPU (32 GB) desborda y baja a 2-20 tok/s.
- Tras cambiar `iniciar.ps1`, prueba con `-SinNgrok -Puerto 1235` si LM Studio puede estar usando el 1234.
- No hagas commit ni push sin que Iván lo pida.
