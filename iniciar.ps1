# Arranca llama-server con el Qwen3.8 oficial, la LoRA del Setas, la visión y el modelo de
# embeddings bge-m3 (opcionales) y el túnel de ngrok.
#
# Uso: iniciar.bat
#      iniciar.bat -Contexto 65536 -SinLora -SinVision -SinEmbeddings -SinNgrok
param(
    [int]$Contexto = 0,
    [int]$Puerto = 1234,
    [switch]$SinLora,
    [switch]$SinVision,
    [switch]$SinEmbeddings,
    [switch]$SinNgrok
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$raiz = $PSScriptRoot
$modelo = 'C:\Users\ivans\.lmstudio\models\lmstudio-community\Qwen3.8-27B-GGUF\Qwen3.8-27B-Q4_K_M.gguf'
$lora = 'lora/setas-lora-v2-p3-f16.gguf'
# Adaptador de visión del mismo modelo: sin él, el servidor ignora las imágenes.
$mmproj = 'C:\Users\ivans\.lmstudio\models\lmstudio-community\Qwen3.8-27B-GGUF\mmproj-Qwen3.8-27B-BF16.gguf'
# Modelo de embeddings, siempre por CPU: no ocupa memoria de GPU.
$modeloEmbeddings = 'C:\Users\ivans\.lmstudio\models\gpustack\bge-m3-GGUF\bge-m3-Q8_0.gguf'
$hilosEmbeddings = 8
$puerto = $Puerto
$minimo = 8192
$maximo = 262144
$paso = 8192
# Por encima de este contexto la caché de 16 bits no cabe en la GPU y todo va a 2 tok/s.
$maximoCacheCompleta = 200000

# Mediciones en la RTX 5090: GB de GPU en uso, con 2,4 GB ya ocupados por Windows.
$gbBase = 18.0
$gbLora = 0.5
$gbVision = 1.8
# Por encima de esto, la GPU (32 GB, con Windows usando 2,4) empieza a desbordar a la RAM.
$gbLimite = 31.0
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
.PARAMETER conVision
    Si se carga el adaptador de visión.
.OUTPUTS
    GB estimados, incluida la memoria que ya usa Windows.
#>
function Get-GbEstimados([int]$tokens, [bool]$conLora, [bool]$conVision) {
    $porToken = if ($tokens -gt $maximoCacheCompleta) { $gbPorTokenComprimida } else { $gbPorTokenCompleta }
    $extra = $(if ($conLora) { $gbLora } else { 0 }) + $(if ($conVision) { $gbVision } else { 0 })
    return $gbBase + $extra + $tokens * $porToken
}

<#
.SYNOPSIS
    Convierte un interruptor en el texto que muestra el menú.
.PARAMETER activado
    Si la opción está activada.
.OUTPUTS
    'SI' o 'NO'.
#>
function Get-SiNo([bool]$activado) {
    if ($activado) { return 'SI' }
    return 'NO'
}

<#
.SYNOPSIS
    Deja elegir el contexto, la LoRA, la visión y los embeddings con el teclado.
.PARAMETER contextoInicial
    Contexto con el que empieza el selector.
.PARAMETER conLoraInicial
    Si la LoRA empieza activada.
.PARAMETER conVisionInicial
    Si la visión empieza activada.
.PARAMETER conEmbeddingsInicial
    Si el modelo de embeddings empieza activado.
.OUTPUTS
    Matriz con el contexto elegido y si se usan la LoRA, la visión y los embeddings.
#>
function Select-Opciones(
    [int]$contextoInicial, [bool]$conLoraInicial, [bool]$conVisionInicial,
    [bool]$conEmbeddingsInicial
) {
    $tokens = $contextoInicial
    $conLora = $conLoraInicial
    $conVision = $conVisionInicial
    $conEmbeddings = $conEmbeddingsInicial
    Write-Host ''
    Write-Host ('Arriba/abajo: contexto (+/- 8.192)   RePag/AvPag: +/- 32.768   L: LoRA   ' +
        'V: visión   E: embeddings   Intro: iniciar')
    while ($true) {
        $gb = Get-GbEstimados $tokens $conLora $conVision
        $nota = if ($gb -gt $gbLimite) { 'PUEDE NO CABER' }
            elseif ($tokens -gt $maximoCacheCompleta) { 'caché comprimida a 8 bits' }
            else { 'caché normal' }
        $texto = ('  Contexto {0,7:N0} | LoRA {1,-2} | Visión {2,-2} | Embeddings {3,-2} | ' +
            'GPU aprox. {4,4:N1} de 32 GB | {5}      ') -f $tokens, (Get-SiNo $conLora),
            (Get-SiNo $conVision), (Get-SiNo $conEmbeddings), $gb, $nota
        Write-Host "`r$texto" -NoNewline
        $tecla = [Console]::ReadKey($true)
        switch ($tecla.Key) {
            'UpArrow' { $tokens = [Math]::Min($maximo, $tokens + $paso) }
            'DownArrow' { $tokens = [Math]::Max($minimo, $tokens - $paso) }
            'PageUp' { $tokens = [Math]::Min($maximo, $tokens + 4 * $paso) }
            'PageDown' { $tokens = [Math]::Max($minimo, $tokens - 4 * $paso) }
            'L' { $conLora = -not $conLora }
            'V' { $conVision = -not $conVision }
            'E' { $conEmbeddings = -not $conEmbeddings }
            'Enter' { Write-Host ''; return @($tokens, $conLora, $conVision, $conEmbeddings) }
        }
    }
}

$entorno = Read-Env (Join-Path $raiz '.env')
$conLora = -not $SinLora
$conVision = -not $SinVision
$conEmbeddings = -not $SinEmbeddings
if ($Contexto -le 0) {
    $Contexto, $conLora, $conVision, $conEmbeddings = Select-Opciones 65536 $conLora $conVision `
        $conEmbeddings
}
if ($conVision -and -not (Test-Path $mmproj)) {
    Write-Host "No encuentro el adaptador de visión ($mmproj): se arranca sin visión."
    $conVision = $false
}
if ($conEmbeddings -and -not (Test-Path $modeloEmbeddings)) {
    Write-Host "No encuentro el modelo de embeddings ($modeloEmbeddings): se arranca sin él."
    $conEmbeddings = $false
}
# Con embeddings, el proxy atiende el puerto público y reparte las peticiones entre los dos
# servidores, que escuchan en puertos internos. Sin ellos, todo es como antes.
$puertoLenguaje = if ($conEmbeddings) { $puerto + 100 } else { $puerto }
$puertoEmbeddings = $puerto + 101
$Contexto = [Math]::Min($maximo, [Math]::Max($minimo, $Contexto))
$cache = if ($Contexto -gt $maximoCacheCompleta) { 'q8_0' } else { 'f16' }

# Un solo espacio (-np 1): las peticiones simultáneas esperan su turno, sin error, y la conversación
# que está atendiendo el servidor dispone de todo el contexto elegido (con -np 2 se partiría a la mitad).
$argumentos = @(
    '-m', $modelo, '-c', $Contexto, '-ngl', '99', '-np', '1', '-fit', 'off', '-fa', 'on',
    '-ctk', $cache, '-ctv', $cache, '--jinja', '--host', '127.0.0.1', '--port', $puertoLenguaje,
    '--api-key', $entorno['LM_STUDIO_API_KEY']
)
# Escala 0 por defecto: solo responde con la LoRA quien la pide en la petición.
if ($conLora) { $argumentos += @('--lora-scaled', "${lora}:0.0") }
if ($conVision) { $argumentos += @('--mmproj', $mmproj) }

$ngrokActivo = Get-Process ngrok -ErrorAction SilentlyContinue
if (-not $SinNgrok -and $entorno['NGROK_DOMINIO'] -and -not $ngrokActivo) {
    $ngrokPropio = Start-Process ngrok -PassThru -WindowStyle Minimized -ArgumentList `
        'http', "--url=https://$($entorno['NGROK_DOMINIO'])", $puerto
}

Write-Host ("Servidor en http://127.0.0.1:$puerto con contexto $Contexto (caché $cache), " +
    "LoRA: $conLora, visión: $conVision, embeddings: $conEmbeddings")
Write-Host 'Para pararlo, pulsa Ctrl+C. Si el ngrok lo ha abierto este script, se cierra también.'
# Desde la carpeta del repositorio: el formato RUTA:ESCALA de la LoRA no admite "C:\".
Set-Location $raiz
try {
    if ($conEmbeddings) {
        # bge-m3 usa la agrupación cls; con el lote igual al contexto admite
        # textos de hasta 8.192 tokens.
        $argumentosEmbeddings = @(
            '-m', $modeloEmbeddings, '--embedding', '--pooling', 'cls', '-ngl', '0',
            '--device', 'none', '-t', $hilosEmbeddings, '-c', '8192', '-b', '8192', '-ub', '8192',
            '-np', '1', '--host', '127.0.0.1', '--port', $puertoEmbeddings,
            '--api-key', $entorno['LM_STUDIO_API_KEY']
        )
        $embeddings = Start-Process .\bin\llama-server.exe -ArgumentList $argumentosEmbeddings `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput 'embeddings.log' `
            -RedirectStandardError 'embeddings-errores.log'
        $proxy = Start-Process uv -ArgumentList 'run', 'proxy.py', $puerto, $puertoLenguaje, `
            $puertoEmbeddings -PassThru -WindowStyle Hidden -RedirectStandardOutput 'proxy.log' `
            -RedirectStandardError 'proxy-errores.log'
    }
    & .\bin\llama-server.exe @argumentos
} finally {
    # Se deja todo como estaba: solo se cierra lo que abrió este script.
    foreach ($proceso in @($embeddings, $proxy)) {
        # /T cierra también los hijos (uv lanza Python como proceso hijo).
        if ($proceso) { & taskkill /PID $proceso.Id /T /F 2>&1 | Out-Null }
    }
    if ($ngrokPropio) { Stop-Process -Id $ngrokPropio.Id -Force -ErrorAction SilentlyContinue }
}
