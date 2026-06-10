# =============================================================================
# RAG Presidentes Ecuador - Setup interactivo (Windows PowerShell)
#
# Uso:
#   .\setup.ps1                    # Menu interactivo
#   .\setup.ps1 setup              # Setup completo
#   .\setup.ps1 build              # Build imagen
#   .\setup.ps1 reindex            # Regenerar ChromaDB
#   .\setup.ps1 start              # Iniciar servicio
#   .\setup.ps1 stop               # Detener servicio
#   .\setup.ps1 logs               # Ver logs
#   .\setup.ps1 health             # Health check
#   .\setup.ps1 update             # git pull + rebuild
#   .\setup.ps1 config             # Editar .env
#   .\setup.ps1 uninstall          # Desinstalar
#
# Flags:
#   -Auto                          # Modo no-interactivo (asume defaults)
#   -Gpu                           # Build con soporte GPU NVIDIA
#   -Platform <plat>               # Forzar plataforma (linux/amd64 | linux/arm64)
#   -DryRun                        # Mostrar que haria sin ejecutar
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "",

    [switch]$Auto,
    [switch]$Gpu,
    [string]$Platform = "",
    [switch]$DryRun
)

# =============================================================================
# Configuracion global
# =============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

# Forzar UTF-8 en la consola (evitar problemas con acentos en cp1252)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$LogFile = Join-Path $ScriptDir "setup.log"
$EnvFile = Join-Path $ScriptDir ".env"
$EnvExample = Join-Path $ScriptDir ".env.example"
$ImageName = "rag-presidentes"
$ImageTag = "1.0.0"

# =============================================================================
# Funciones de output
# =============================================================================

function Write-Banner {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " RAG Presidentes Ecuador - Setup" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step { param($msg) Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Gray }

function Write-Log {
    param($level, $msg)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$level] $msg"
    Add-Content -Path $LogFile -Value $line
}

function Run-Command {
    param(
        [string]$cmd,
        [string]$description = ""
    )
    if ($description) { Write-Step $description }
    if ($DryRun) {
        Write-Host "  [DRY-RUN] $cmd" -ForegroundColor Magenta
        return
    }
    Write-Log "INFO" "Ejecutando: $cmd"
    Write-Host "  > $cmd" -ForegroundColor DarkGray
    try {
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
            throw "Comando fallo con exit code $LASTEXITCODE"
        }
    } catch {
        Write-Fail "Error: $_"
        Write-Log "ERROR" "$_"
        throw
    }
}

# =============================================================================
# Deteccion de entorno
# =============================================================================

function Get-OsType { return "windows" }

function Get-Arch {
    if ([System.Environment]::Is64BitOperatingSystem) {
        if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
            return "arm64"
        }
        return "amd64"
    }
    return "amd64"
}

function Test-DockerInstalled {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return @{ Installed = $false; Running = $false; Version = "" }
    }
    $version = (docker --version 2>$null) -replace "Docker version ", "" -replace ",.*", ""
    $running = $false
    try {
        $info = docker info 2>&1
        $running = ($LASTEXITCODE -eq 0)
    } catch { $running = $false }
    return @{ Installed = $true; Running = $running; Version = $version }
}

function Test-DockerBuildx {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    try {
        $null = docker buildx version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Test-Ollama {
    param([string]$host = "http://localhost:11434")
    try {
        $response = Invoke-WebRequest -Uri "$host/api/tags" -Method GET -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $tags = $response.Content | ConvertFrom-Json
        $models = @($tags.models | ForEach-Object { $_.name })
        $hasQwen = $models | Where-Object { $_ -like "qwen2.5:7b*" }
        return @{
            Reachable = $true
            Models = $models
            HasQwen = ($hasQwen -ne $null)
            Host = $host
        }
    } catch {
        return @{ Reachable = $false; Models = @(); HasQwen = $false; Host = $host }
    }
}

function Test-ImageExists {
    param([string]$name, [string]$tag)
    try {
        $null = docker image inspect "${name}:${tag}" 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Test-ServiceRunning {
    try {
        $null = docker compose ps --services --filter "status=running" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Show-Status {
    Write-Banner
    Write-Host "Estado actual:" -ForegroundColor White
    Write-Host ""

    $docker = Test-DockerInstalled
    if ($docker.Installed) {
        Write-Ok "Docker instalado: $($docker.Version)"
    } else {
        Write-Fail "Docker no instalado (descargalo de https://www.docker.com/products/docker-desktop/)"
    }
    if ($docker.Running) {
        Write-Ok "Docker corriendo"
    } else {
        Write-Warn "Docker no esta corriendo (abrir Docker Desktop)"
    }

    $buildx = Test-DockerBuildx
    if ($buildx) {
        Write-Ok "Docker buildx disponible (multi-arch OK)"
    } else {
        Write-Warn "Docker buildx no disponible (multi-arch limitado)"
    }

    $arch = Get-Arch
    Write-Host "  [INFO] Arquitectura del host: $arch" -ForegroundColor Gray

    $ollama = Test-Ollama
    if ($ollama.Reachable) {
        Write-Ok "Ollama accesible en $($ollama.Host) ($($ollama.Models.Count) modelos)"
        if (-not $ollama.HasQwen) {
            Write-Warn "  Modelo qwen2.5:7b NO descargado. Ejecuta: ollama pull qwen2.5:7b"
        }
    } else {
        Write-Warn "Ollama no accesible en $($ollama.Host)"
    }

    $image = Test-ImageExists $ImageName $ImageTag
    if ($image) {
        Write-Ok "Imagen $ImageName`:$ImageTag construida"
    } else {
        Write-Warn "Imagen $ImageName`:$ImageTag NO existe (requiere build)"
    }

    $running = Test-ServiceRunning
    if ($running) {
        Write-Ok "Servicio RAG corriendo"
    } else {
        Write-Warn "Servicio RAG detenido"
    }

    if (Test-Path $EnvFile) {
        Write-Ok ".env configurado"
    } else {
        Write-Warn ".env no existe (usar opcion 9 para configurar)"
    }

    Write-Host ""
}

# =============================================================================
# Funciones principales
# =============================================================================

function Initialize-Env {
    if (-not (Test-Path $EnvFile)) {
        if (Test-Path $EnvExample) {
            Copy-Item $EnvExample $EnvFile
            Write-Ok ".env creado desde .env.example"
        } else {
            Write-Fail ".env.example no encontrado"
        }
    } else {
        Write-Info ".env ya existe"
    }

    # En Windows con Docker Desktop, host.docker.internal funciona siempre.
    # (En Linux el setup.sh lo cambia a USE_HOST_NETWORK=true)
}

function Install-Docker {
    $docker = Test-DockerInstalled
    if ($docker.Installed) { return }

    Write-Warn "Docker no esta instalado."
    $resp = Read-Host "Abrir la pagina de descarga en el navegador? (s/n)"
    if ($resp -eq "s" -or $resp -eq "S") {
        Start-Process "https://www.docker.com/products/docker-desktop/"
    }
    Write-Info "Instala Docker Desktop, reinicia si es necesario, y vuelve a correr este script."
    exit 1
}

function Ensure-Buildx {
    if (Test-DockerBuildx) { return }

    Write-Step "Creando builder buildx para multi-arch..."
    try {
        docker buildx create --name multiarch --use 2>&1 | Out-Null
        docker buildx inspect --bootstrap 2>&1 | Out-Null
        Write-Ok "Builder multiarch listo"
    } catch {
        Write-Warn "No se pudo crear builder multiarch. Build limitado a plataforma local."
    }
}

function Build-Image {
    Write-Step "Construyendo imagen Docker..."
    Write-Info "Esto puede tardar 5-10 minutos la primera vez (descarga modelo + genera ChromaDB)."

    Ensure-Buildx

    $platform = if ($Platform) { $Platform } else { "linux/$(Get-Arch)" }
    Write-Info "Plataforma: $platform"

    $buildArgs = @()
    if ($Gpu) {
        $buildArgs += "--build-arg"
        $buildArgs += "INSTALL_GPU=true"
    }

    if ($DryRun) {
        Write-Host "  [DRY-RUN] docker buildx build --platform $platform -t ${ImageName}:${ImageTag} ." -ForegroundColor Magenta
        return
    }

    try {
        docker buildx build --platform $platform -t "${ImageName}:${ImageTag}" -t "${ImageName}:latest" @buildArgs --load .
        if ($LASTEXITCODE -ne 0) { throw "Build fallo" }
        Write-Ok "Imagen construida: ${ImageName}:${ImageTag}"
    } catch {
        Write-Fail "Error en build: $_"
        throw
    }
}

function Invoke-Reindex {
    Write-Step "Re-generando ChromaDB en volume temporal..."
    Write-Info "Levanta un contenedor efimero para regenerar el indice."

    if ($DryRun) {
        Write-Host "  [DRY-RUN] docker compose run --rm rag python generate_embeddings.py" -ForegroundColor Magenta
        return
    }

    try {
        # Levanta el servicio, regenera, baja
        docker compose up -d rag 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "No se pudo levantar el servicio" }
        docker compose exec rag python generate_embeddings.py
        if ($LASTEXITCODE -ne 0) { throw "Reindex fallo" }
        Write-Ok "ChromaDB regenerado"
    } catch {
        Write-Fail "Error en reindex: $_"
        throw
    } finally {
        docker compose down 2>&1 | Out-Null
    }
}

function Start-Service {
    Write-Step "Iniciando servicio..."
    if ($DryRun) {
        Write-Host "  [DRY-RUN] docker compose up -d" -ForegroundColor Magenta
        return
    }
    try {
        docker compose up -d
        if ($LASTEXITCODE -ne 0) { throw "No se pudo iniciar el servicio" }
        Write-Ok "Servicio iniciado. Esperando healthcheck..."
        $healthy = $false
        for ($i = 1; $i -le 30; $i++) {
            Start-Sleep -Seconds 2
            $status = docker compose ps --format json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($status.Health -eq "healthy") {
                $healthy = $true
                break
            }
        }
        if ($healthy) {
            Write-Ok "Servicio saludable"
        } else {
            Write-Warn "Servicio iniciado pero aun no esta saludable. Revisa logs (opcion 6)."
        }
    } catch {
        Write-Fail "Error: $_"
        throw
    }
}

function Stop-Service {
    Write-Step "Deteniendo servicio..."
    if ($DryRun) {
        Write-Host "  [DRY-RUN] docker compose down" -ForegroundColor Magenta
        return
    }
    docker compose down
    Write-Ok "Servicio detenido (volume de chroma_db preservado)"
}

function Show-Logs {
    Write-Step "Mostrando logs (Ctrl+C para salir)..."
    if ($DryRun) { return }
    docker compose logs -f --tail=100 rag
}

function Test-Health {
    Write-Step "Health check..."
    if ($DryRun) { return }

    $port = 8010
    if (Test-Path $EnvFile) {
        $envContent = Get-Content $EnvFile | Where-Object { $_ -match "^PUERTO=" }
        if ($envContent) { $port = ($envContent -split "=", 2)[1].Trim() }
    }

    $baseUrl = "http://localhost:${port}"
    Write-Info "Endpoint: $baseUrl"

    # Health endpoint
    try {
        $response = Invoke-WebRequest -Uri "$baseUrl/health" -Method GET -TimeoutSec 5 -UseBasicParsing
        Write-Ok "GET /health -> $($response.StatusCode)"
        Write-Host $response.Content
    } catch {
        Write-Fail "GET /health fallo: $_"
        return
    }
    Write-Host ""

    # Smoke test /chat
    Write-Step "Smoke test /chat..."
    $prompt = Read-Host "Prompt de prueba (Enter para usar default: 'Eloy Alfaro, saludame en una oracion')"
    if (-not $prompt) { $prompt = "Eloy Alfaro, saludame en una oracion" }

    try {
        $body = @{ prompt = $prompt } | ConvertTo-Json
        $response = Invoke-WebRequest -Uri "$baseUrl/chat" -Method POST -ContentType "application/json" -Body $body -TimeoutSec 30 -UseBasicParsing
        Write-Ok "POST /chat -> $($response.StatusCode)"
        $json = $response.Content | ConvertFrom-Json
        Write-Host "Presidente: $($json.presidente)"
        Write-Host "Fuentes locales: $($json.fuentes.Count)"
        Write-Host "Fuentes externas: $($json.fuentes_externas.Count)"
        Write-Host ""
        Write-Host "Respuesta:" -ForegroundColor Cyan
        Write-Host $json.response
    } catch {
        Write-Fail "POST /chat fallo: $_"
    }
}

function Update-Code {
    Write-Step "Actualizando codigo (git pull + rebuild)..."

    if (-not (Test-Path ".git")) {
        Write-Warn "No es un repo git. No se puede hacer pull."
        return
    }

    if ($DryRun) {
        Write-Host "  [DRY-RUN] git pull" -ForegroundColor Magenta
        Write-Host "  [DRY-RUN] docker buildx build ..." -ForegroundColor Magenta
        return
    }

    git pull
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "git pull fallo"
        return
    }
    Write-Ok "Codigo actualizado"

    Write-Info "Rebuilding imagen con el nuevo codigo..."
    Build-Image

    Write-Info "Reiniciando servicio..."
    Stop-Service
    Start-Service
}

function Edit-Config {
    if (-not (Test-Path $EnvFile)) {
        Initialize-Env
    }

    Write-Step "Configuracion actual:"
    Get-Content $EnvFile | Where-Object { $_ -match "^[A-Z]" -and $_ -notmatch "^#" } | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Gray
    }
    Write-Host ""

    $resp = Read-Host "Abrir .env en el editor default? (s/n)"
    if ($resp -eq "s" -or $resp -eq "S") {
        Start-Process notepad.exe $EnvFile
        Write-Warn "Despues de editar, reinicia el servicio (opcion 4)"
    }
}

function Uninstall-All {
    Write-Warn "Esto eliminara: contenedor, imagen, y opcionalmente volumes."
    $resp = Read-Host "Continuar? (s/n)"
    if ($resp -ne "s" -and $resp -ne "S") { return }

    if ($DryRun) {
        Write-Host "  [DRY-RUN] docker compose down -v" -ForegroundColor Magenta
        Write-Host "  [DRY-RUN] docker rmi ${ImageName}:${ImageTag}" -ForegroundColor Magenta
        return
    }

    try {
        docker compose down -v 2>&1 | Out-Null
        docker rmi "${ImageName}:${ImageTag}" 2>&1 | Out-Null
        docker rmi "${ImageName}:latest" 2>&1 | Out-Null
        Write-Ok "Desinstalacion completa"
    } catch {
        Write-Fail "Error: $_"
    }
}

function Invoke-FullSetup {
    Write-Banner
    Write-Step "Setup completo de RAG Presidentes Ecuador"
    Write-Host ""

    Install-Docker
    Initialize-Env
    Build-Image
    Start-Service
    Test-Health
    Write-Host ""
    Write-Ok "Setup completo! El servicio esta corriendo en http://localhost:8010"
}

# =============================================================================
# Menu interactivo
# =============================================================================

function Show-Menu {
    Show-Status
    Write-Host "Selecciona una opcion:" -ForegroundColor White
    Write-Host ""
    Write-Host "  1)  Setup completo           (verifica Docker, build, configura, levanta)"
    Write-Host "  2)  Build imagen             (rebuild con ultima version del codigo)"
    Write-Host "  3)  Re-indexar dataset       (regenera ChromaDB desde el JSONL)"
    Write-Host "  4)  Iniciar servicio         (docker compose up -d)"
    Write-Host "  5)  Detener servicio         (docker compose down)"
    Write-Host "  6)  Ver logs                 (docker compose logs -f)"
    Write-Host "  7)  Verificar salud          (curl /health + smoke test /chat)"
    Write-Host "  8)  Actualizar codigo        (git pull + rebuild + restart)"
    Write-Host "  9)  Reconfigurar             (editar .env)"
    Write-Host "  10) Desinstalar              (down -v + remove imagen)"
    Write-Host "  0)  Salir"
    Write-Host ""
    $opt = Read-Host "Opcion"
    return $opt
}

# =============================================================================
# Main
# =============================================================================

switch ($Command.ToLower()) {
    "setup"     { Invoke-FullSetup }
    "build"     { Initialize-Env; Build-Image }
    "reindex"   { Invoke-Reindex }
    "start"     { Initialize-Env; Start-Service }
    "stop"      { Stop-Service }
    "logs"      { Show-Logs }
    "health"    { Test-Health }
    "update"    { Update-Code }
    "config"    { Edit-Config }
    "uninstall" { Uninstall-All }
    "" {
        # Modo interactivo
        while ($true) {
            $opt = Show-Menu
            switch ($opt) {
                "1"  { Invoke-FullSetup; pause; Clear-Host }
                "2"  { Initialize-Env; Build-Image; pause; Clear-Host }
                "3"  { Invoke-Reindex; pause; Clear-Host }
                "4"  { Initialize-Env; Start-Service; pause; Clear-Host }
                "5"  { Stop-Service; pause; Clear-Host }
                "6"  { Show-Logs; pause; Clear-Host }
                "7"  { Test-Health; pause; Clear-Host }
                "8"  { Update-Code; pause; Clear-Host }
                "9"  { Edit-Config; pause; Clear-Host }
                "10" { Uninstall-All; pause; Clear-Host }
                "0"  { Write-Ok "Chau!"; return }
                default { Write-Warn "Opcion invalida"; Start-Sleep -Seconds 1; Clear-Host }
            }
        }
    }
    default {
        Write-Fail "Comando desconocido: $Command"
        Write-Info "Comandos validos: setup, build, reindex, start, stop, logs, health, update, config, uninstall"
        exit 1
    }
}
