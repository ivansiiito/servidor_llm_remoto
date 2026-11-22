# Arranca llama-server con el Qwen3.8 oficial, la LoRA del Setas (opcional) y el túnel de ngrok.
#
# Uso: iniciar.bat
#      iniciar.bat -Contexto 65536 -SinLora -SinNgrok
param(
    [int]$Contexto = 0,
    [int]$Puerto = 1234,
    [switch]$SinLora,
    [switch]$SinNgrok
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$raiz = $PSScriptRoot
$modelo = 'C:\Users\ivans\.lmstudio\models\lmstudio-community\Qwen3.8-27B-GGUF\Qwen3.8-27B-Q4_K_M.gguf'
$lora = 'lora/setas-lora-f16.gguf'
$puerto = $Puerto
$minimo = 8192
$maximo = 262144
$paso = 8192
# Por encima de este contexto la caché de 16 bits no cabe en la GPU y todo va a 2 tok/s.
$maximoCacheCompleta = 200000

# Mediciones en la RTX 5090: GB de GPU en uso, con 2,4 GB ya ocupados por Windows.
$gbBase = 18.0
$gbLora = 0.5
$gbPorTokenCompleta = 0.000063
$gbPorTokenComprimida = 0.000034

<#
.SYNOPSIS
    Lee las variables de un archivo .env.
.PARAMETER ruta
    Ruta del archivo .env.
.OUTPUTS
    Tabla hash con nombre y valor de cada variable.
#>
function Read-Env([string]$ruta) {
    $variables = @{}
    foreach ($linea in Get-Content $ruta) {
        if ($linea -match '^\s*([A-Z_]+)=(.*)$') { $variables[$Matches[1]] = $Matches[2].Trim() }
    }
    return $variables
}

<#
.SYNOPSIS
    Estima la memoria de GPU que ocupará el servidor.
.PARAMETER tokens
    Tamaño del contexto.
.PARAMETER conLora
    Si se carga la LoRA.
.OUTPUTS
    GB estimados, incluida la memoria que ya usa Windows.
#>
function Get-GbEstimados([int]$tokens, [bool]$conLora) {
    $porToken = if ($tokens -gt $maximoCacheCompleta) { $gbPorTokenComprimida } else { $gbPorTokenCompleta }
    return $gbBase + $(if ($conLora) { $gbLora } else { 0 }) + $tokens * $porToken
}

<#
.SYNOPSIS
    Deja elegir el contexto y la LoRA con el teclado.
.PARAMETER contextoInicial
    Contexto con el que empieza el selector.
.PARAMETER conLoraInicial
    Si la LoRA empieza activada.
.OUTPUTS
    Matriz con el contexto elegido y si se usa la LoRA.
#>
function Select-Opciones([int]$contextoInicial, [bool]$conLoraInicial) {
    $tokens = $contextoInicial
    $conLora = $conLoraInicial
    Write-Host ''
    Write-Host 'Arriba/abajo: contexto (+/- 8.192)   RePag/AvPag: +/- 32.768   L: LoRA   Intro: iniciar'
    while ($true) {
        $gb = Get-GbEstimados $tokens $conLora
        $nota = if ($tokens -gt $maximoCacheCompleta) { 'caché comprimida a 8 bits' } else { 'caché normal' }
        $texto = '  Contexto {0,7:N0} tokens | LoRA {1,-3} | GPU aprox. {2,4:N1} GB de 32 | {3}   ' -f `
            $tokens, $(if ($conLora) { 'SI' } else { 'NO' }), $gb, $nota
        Write-Host "`r$texto" -NoNewline
        $tecla = [Console]::ReadKey($true)
        switch ($tecla.Key) {
            'UpArrow' { $tokens = [Math]::Min($maximo, $tokens + $paso) }
            'DownArrow' { $tokens = [Math]::Max($minimo, $tokens - $paso) }
            'PageUp' { $tokens = [Math]::Min($maximo, $tokens + 4 * $paso) }
            'PageDown' { $tokens = [Math]::Max($minimo, $tokens - 4 * $paso) }
            'L' { $conLora = -not $conLora }
            'Enter' { Write-Host ''; return @($tokens, $conLora) }
        }
    }
}

$entorno = Read-Env (Join-Path $raiz '.env')
$conLora = -not $SinLora
if ($Contexto -le 0) {
    $Contexto, $conLora = Select-Opciones 65536 $conLora
}
$Contexto = [Math]::Min($maximo, [Math]::Max($minimo, $Contexto))
$cache = if ($Contexto -gt $maximoCacheCompleta) { 'q8_0' } else { 'f16' }

$argumentos = @(
    '-m', $modelo, '-c', $Contexto, '-ngl', '99', '-np', '2', '-fit', 'off', '-fa', 'on',
    '-ctk', $cache, '-ctv', $cache, '--jinja', '--host', '127.0.0.1', '--port', $puerto,
    '--api-key', $entorno['LM_STUDIO_API_KEY']
)
# Escala 0 por defecto: solo responde con la LoRA quien la pide en la petición.
if ($conLora) { $argumentos += @('--lora-scaled', "${lora}:0.0") }

$ngrokActivo = Get-Process ngrok -ErrorAction SilentlyContinue
if (-not $SinNgrok -and $entorno['NGROK_DOMINIO'] -and -not $ngrokActivo) {
    $ngrokPropio = Start-Process ngrok -PassThru -WindowStyle Minimized -ArgumentList `
        'http', "--url=https://$($entorno['NGROK_DOMINIO'])", $puerto
}

Write-Host "Servidor en http://127.0.0.1:$puerto con contexto $Contexto (caché $cache), LoRA: $conLora"
Write-Host 'Para pararlo, pulsa Ctrl+C. Si el ngrok lo ha abierto este script, se cierra también.'
# Desde la carpeta del repositorio: el formato RUTA:ESCALA de la LoRA no admite "C:\".
Set-Location $raiz
try {
    & .\bin\llama-server.exe @argumentos
} finally {
    # Se deja todo como estaba: solo se cierra el túnel que abrió este script.
    if ($ngrokPropio) { Stop-Process -Id $ngrokPropio.Id -Force -ErrorAction SilentlyContinue }
}
