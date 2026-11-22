@echo off
rem Arranca el servidor del modelo; los argumentos se pasan a iniciar.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0iniciar.ps1" %*
pause
