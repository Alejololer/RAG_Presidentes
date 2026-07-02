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
    # Test-DockerDaemon relaja ErrorActionPreference localmente; sin eso el stderr
    # de docker info (WARNING de arranque frio) seria un error terminante en PS 5.1.
    $running = Test-DockerDaemon
    return @{ Installed = $true; Running = $running; Version = $version }
}

function Test-DockerBuildx {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    # Scope local de EAP="Continue": evita que el stderr de docker (cuando el
    # daemon esta frio o buildx no esta) termine el script en PS 5.1.
    & { $ErrorActionPreference = "Continue"; docker buildx version > $null 2>&1 }
    return ($LASTEXITCODE -eq 0)
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
    # Scope local de EAP="Continue": ver nota en Test-DockerDaemon.
    & { $ErrorActionPreference = "Continue"; docker image inspect "${name}:${tag}" > $null 2>&1 }
    return ($LASTEXITCODE -eq 0)
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

    # En Windows con Docker Desktop, host.docker.internal funciona siempre,
    # asi que dejamos USE_HOST_NETWORK=bridge (default en .env.example).
    # (En Linux el setup.sh lo cambia a USE_HOST_NETWORK=host)
}

function Install-Docker {
    $docker = Test-DockerInstalled
    if ($docker.Installed) { return }

    Show-DockerNotInstalledGuide
    $resp = Read-Host "Abrir la pagina de descarga en el navegador? (s/n)"
    if ($resp -eq "s" -or $resp -eq "S") {
        Start-Process "https://www.docker.com/products/docker-desktop/"
    }
    Write-Info "Instala Docker Desktop, reinicia si es necesario, y vuelve a correr este script."
    exit 1
}

# Verifica que Docker este instalado Y corriendo antes de cualquier comando.
# Si no lo esta, muestra una guia clara y termina con exit 1.
# Esta funcion se llama al inicio de build, start, reindex, stop, logs, etc.
function Ensure-DockerRunning {
    $docker = Test-DockerInstalled
    if (-not $docker.Installed) {
        Show-DockerNotInstalledGuide
        exit 1
    }

    # Docker esta instalado. Verificar que este corriendo.
    if (-not (Test-DockerDaemon)) {
        Show-DockerNotRunningGuide
        exit 1
    }
}

# Devuelve $true si el daemon de Docker responde (docker info -> exit 0).
#
# IMPORTANTE (la causa del bug "Docker NO esta corriendo" en falso):
# El script corre via rag.bat con `powershell.exe` (Windows PowerShell 5.1).
# En 5.1, con $ErrorActionPreference="Stop" (global, linea ~39), CUALQUIER
# escritura a stderr de un comando nativo se promueve a un error TERMINANTE.
# `docker info` emite "WARNING: No blkio throttle..." a stderr en arranque frio,
# asi que el try/catch caia al catch y reportaba el daemon como caido aunque el
# exit code fuera 0. La solucion: relajar ErrorActionPreference a "Continue" en
# un scope local (& { ... }) para esta llamada; el resto del script conserva
# "Stop". $LASTEXITCODE es global, asi que sigue visible tras el bloque.
function Test-DockerDaemon {
    & { $ErrorActionPreference = "Continue"; docker info > $null 2>&1 }
    return ($LASTEXITCODE -eq 0)
}

# Guia detallada: Docker no instalado. Pasos segun el OS.
function Show-DockerNotInstalledGuide {
    $os = Get-OsType

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " Docker no esta instalado en esta PC" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Info "El setup necesita Docker Desktop para construir y correr el servicio."
    Write-Host ""

    switch ($os) {
        "windows" {
            Write-Host "Estas en Windows. Pasos para instalar Docker:" -ForegroundColor White
            Write-Host ""
            Write-Host "  1. Descarga Docker Desktop desde:"
            Write-Host "       https://www.docker.com/products/docker-desktop/" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  2. Ejecuta el instalador Docker Desktop Installer.exe"
            Write-Host "     - Te pedira usar WSL 2 como backend (recomendado)."
            Write-Host "     - Reinicia Windows cuando lo pida."
            Write-Host ""
            Write-Host "  3. Abre Docker Desktop desde el menu Inicio."
            Write-Host "     Espera a que el icono de la ballena en la barra de tareas"
            Write-Host "     diga 'Docker Desktop is running'."
            Write-Host ""
            Write-Host "  4. Vuelve a correr este script en PowerShell."
        }
        "macos" {
            Write-Host "Estas en macOS. Pasos para instalar Docker:" -ForegroundColor White
            Write-Host ""
            Write-Host "  1. Descarga Docker Desktop desde:"
            Write-Host "       https://www.docker.com/products/docker-desktop/" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  2. Abre el archivo .dmg descargado y arrastra Docker a Aplicaciones."
            Write-Host ""
            Write-Host "  3. Abre Docker Desktop desde Aplicaciones y espera a que el"
            Write-Host "     icono de la barra de menu muestre 'Docker Desktop is running'."
            Write-Host ""
            Write-Host "  4. Vuelve a correr este script."
        }
        "linux" {
            Write-Host "Estas en Linux. Pasos para instalar Docker:" -ForegroundColor White
            Write-Host ""
            Write-Host "  Ubuntu / Debian:"
            Write-Host "    curl -fsSL https://get.docker.com -o get-docker.sh"
            Write-Host "    sudo sh get-docker.sh"
            Write-Host "    sudo usermod -aG docker `$USER"
            Write-Host "    # Cierra sesion y vuelve a entrar para que tome efecto"
            Write-Host ""
            Write-Host "  Fedora / RHEL:"
            Write-Host "    sudo dnf install docker docker-compose-plugin"
            Write-Host "    sudo systemctl start docker"
            Write-Host "    sudo usermod -aG docker `$USER"
            Write-Host ""
            Write-Host "  Arch:"
            Write-Host "    sudo pacman -S docker docker-compose"
            Write-Host "    sudo systemctl start docker.service"
            Write-Host "    sudo usermod -aG docker `$USER"
            Write-Host ""
            Write-Host "  Despues de instalar, vuelve a correr este script."
        }
        default {
            Write-Host "Instala Docker desde:" -ForegroundColor White
            Write-Host "  https://www.docker.com/products/docker-desktop/" -ForegroundColor Cyan
        }
    }
    Write-Host ""
}

# Guia detallada: Docker instalado pero NO corriendo.
function Show-DockerNotRunningGuide {
    $os = Get-OsType

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " Docker esta instalado pero NO esta corriendo" -ForegroundColor Red
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Info "Docker Desktop es un programa que tiene que estar abierto y"
    Write-Info "corriendo para que podamos construir y levantar contenedores."
    Write-Host ""
    Write-Info "Si llegaste aca, probablemente viste un error como:"
    Write-Host "  Cannot connect to the Docker daemon at unix:///.../docker.sock" -ForegroundColor Yellow
    Write-Host "  Is the docker daemon running?" -ForegroundColor Yellow
    Write-Host ""
    Write-Info "Eso significa que el cliente (docker) esta instalado pero el"
    Write-Info "servicio/daemon no esta activo. Solucion:"
    Write-Host ""

    switch ($os) {
        "windows" {
            Write-Host "  1. Abre Docker Desktop desde el menu Inicio." -ForegroundColor White
            Write-Host "     (Si no lo tienes instalado, mira la guia de instalacion)"
            Write-Host ""
            Write-Host "  2. Espera ~30 segundos a que el motor arranque. El icono de"
            Write-Host "     la ballena en la barra de tareas pasara de"
            Write-Host "     'Docker Desktop is starting' a 'Docker Desktop is running'."
            Write-Host ""
            Write-Host "  3. Vuelve a correr este script en PowerShell."
            Write-Host ""
            Write-Host "  Si Docker Desktop esta abierto pero igual no anda:" -ForegroundColor Gray
            Write-Host "    - Click derecho en el icono > Troubleshoot > Restart"
            Write-Host "    - O cierra y vuelve a abrir Docker Desktop"
            Write-Host ""
            Write-Host "  Si usas WSL 2 y el error persiste:" -ForegroundColor Gray
            Write-Host "    - PowerShell como Administrador:"
            Write-Host "      wsl --shutdown"
            Write-Host "      wsl"
            Write-Host "    - Despues vuelve a abrir Docker Desktop."
        }
        "macos" {
            Write-Host "  1. Abre Docker Desktop desde Aplicaciones." -ForegroundColor White
            Write-Host "     (Si no lo tienes instalado, mira la guia de instalacion)"
            Write-Host ""
            Write-Host "  2. Espera ~30 segundos a que el motor arranque. Lo sabras"
            Write-Host "     cuando el icono de la ballena en la barra superior"
            Write-Host "     deje de animarse y diga 'Docker Desktop is running'."
            Write-Host ""
            Write-Host "  3. Vuelve a correr este script."
            Write-Host ""
            Write-Host "  Si Docker Desktop esta abierto pero igual no anda:" -ForegroundColor Gray
            Write-Host "    - Menu Docker > Troubleshoot > Restart Docker Desktop"
            Write-Host "    - O cierra y vuelve a abrir Docker Desktop"
        }
        "linux" {
            Write-Host "  1. Inicia el servicio de Docker:" -ForegroundColor White
            Write-Host ""
            Write-Host "     sudo systemctl start docker"
            Write-Host "     sudo systemctl enable docker  # para que arranque con el sistema"
            Write-Host ""
            Write-Host "  2. Verifica que este corriendo:"
            Write-Host ""
            Write-Host "     sudo systemctl status docker"
            Write-Host ""
            Write-Host "  3. Si usas un usuario no-root, asegurate de estar en el grupo docker:"
            Write-Host ""
            Write-Host "     sudo usermod -aG docker `$USER"
            Write-Host "     # Cierra sesion y vuelve a entrar"
            Write-Host ""
            Write-Host "  4. Vuelve a correr este script."
        }
        default {
            Write-Host "Inicia el servicio de Docker segun tu sistema operativo." -ForegroundColor White
            Write-Host "Vuelve a correr este script cuando este corriendo."
        }
    }
    Write-Host ""
    Write-Info "Para verificar manualmente que Docker esta corriendo:"
    Write-Host "  docker info" -ForegroundColor Cyan
    Write-Host ""
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

# El Dockerfile hornea chroma_db/ por COPY (NO lo genera en build). Si falta,
# lo generamos localmente (get_model() usa GPU si esta disponible). Sin chroma_db/
# ni Python, el build no puede continuar -> guiar al usuario a 'pull'.
function Ensure-ChromaDb {
    if ((Test-Path "chroma_db") -and (Get-ChildItem "chroma_db" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Write-Ok "chroma_db local presente (se horneara en la imagen)"
        return
    }
    Write-Warn "No hay chroma_db/ local; el build lo necesita. Generandolo..."
    $py = if (Test-Path ".venv\Scripts\python.exe") { ".venv\Scripts\python.exe" }
          elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" }
          else { $null }
    if (-not $py) {
        Write-Fail "No hay chroma_db/ ni Python para generarlo. Usa 'pull' para bajar la imagen publica, o genera el indice en una maquina con Python (GPU recomendado)."
        throw "chroma_db ausente"
    }
    $env:PYTHONIOENCODING = "utf-8"
    & $py generate_embeddings.py
    if ($LASTEXITCODE -ne 0) { throw "Fallo generando chroma_db" }
    Write-Ok "chroma_db generado"
}

function Build-Image {
    Ensure-DockerRunning
    Write-Step "Construyendo imagen Docker..."
    Write-Info "Descarga modelo (cacheado) y hornea el chroma_db local. Rapido si el cache esta caliente."

    Ensure-Buildx
    Ensure-ChromaDb

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
    Ensure-DockerRunning
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

function Invoke-Pull {
    Ensure-DockerRunning
    Write-Step "Descargando imagen de Docker Hub..."
    Write-Info "Registry: alejololer/rag-presidentes"
    Write-Info "Esto descarga ~1 GB la primera vez."

    if ($DryRun) {
        Write-Host "  [DRY-RUN] docker compose pull rag" -ForegroundColor Magenta
        return
    }

    try {
        docker compose pull rag
        if ($LASTEXITCODE -ne 0) { throw "docker compose pull fallo" }
        Write-Ok "Imagen descargada/actualizada"
    } catch {
        Write-Fail "No se pudo descargar la imagen del registry."
        Write-Info "Posibles causas:"
        Write-Info "  - Sin conexion a internet"
        Write-Info "  - La imagen no fue publicada todavia (corre publish.ps1 o ./publish.sh primero)"
        Write-Info "  - Tag especifico no existe (revisar IMAGE_VERSION en .env)"
        throw
    }
}

function Start-Service {
    Ensure-DockerRunning

    # Si la imagen del registry no esta local, intentar pull automatico.
    # Si el pull falla, hace build local (caso dev que no ha publicado aun).
    $image = Test-ImageExists $ImageName $ImageTag
    if (-not $image) {
        Write-Info "Imagen local no encontrada, intentando descargar de Docker Hub..."
        try {
            Invoke-Pull
        } catch {
            Write-Warn "No se pudo descargar del registry. Intentando build local..."
            try {
                Ensure-ChromaDb
                docker compose build rag
                if ($LASTEXITCODE -ne 0) { throw "Build local fallo" }
            } catch {
                Write-Fail "Build local tambien fallo. Revisa tu conexion o publica la imagen primero."
                throw
            }
        }
    }

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
    Ensure-DockerRunning
    Write-Step "Deteniendo servicio..."
    if ($DryRun) {
        Write-Host "  [DRY-RUN] docker compose down" -ForegroundColor Magenta
        return
    }
    docker compose down
    Write-Ok "Servicio detenido (volume de chroma_db preservado)"
}

function Show-Logs {
    Ensure-DockerRunning
    Write-Step "Mostrando logs (Ctrl+C para salir)..."
    if ($DryRun) { return }
    docker compose logs -f --tail=100 rag
}

function Test-Health {
    Ensure-DockerRunning
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
    Ensure-DockerRunning
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
    Ensure-DockerRunning
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
    # Imprime el menu. NO lee input. La lectura se hace en el caller.
    Clear-Host
    Write-Banner
    Write-Host "Selecciona una opcion:" -ForegroundColor White
    Write-Host ""
    Write-Host "  [Uso diario]" -ForegroundColor Cyan
    Write-Host "  1)  Iniciar servicio         (docker compose up -d, pull auto si no hay imagen)"
    Write-Host "  2)  Detener servicio         (docker compose down)"
    Write-Host "  3)  Ver logs                 (docker compose logs -f)"
    Write-Host "  4)  Verificar salud          (curl /health + smoke test /chat)"
    Write-Host ""
    Write-Host "  [Avanzadas]" -ForegroundColor Cyan
    Write-Host "  5)  Setup completo           (primera vez: build, configura, levanta)"
    Write-Host "  6)  Build imagen             (rebuild local con ultima version del codigo)"
    Write-Host "  7)  Pull imagen              (descarga de Docker Hub: alejololer/rag-presidentes)"
    Write-Host "  8)  Re-indexar dataset       (regenera ChromaDB desde el JSONL)"
    Write-Host "  9)  Actualizar codigo        (git pull + rebuild + restart)"
    Write-Host "  10) Reconfigurar / Desinstalar (submenu)"
    Write-Host "  0)  Salir"
    Write-Host ""
    # Estado resumido (best-effort, no bloqueante)
    if ([Environment]::UserInteractive) {
        Write-Host "--- Estado actual ---" -ForegroundColor Gray
        try { Show-StatusBrief } catch { Write-Warn "No se pudo leer el estado" }
        Write-Host ""
    }
}

function Show-ConfigUninstall-Menu {
    Clear-Host
    Write-Banner
    Write-Host "Submenu - Reconfigurar / Desinstalar" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) Reconfigurar (editar .env)" -ForegroundColor White
    Write-Host "  2) Desinstalar (down -v + remove imagen)" -ForegroundColor White
    Write-Host "  0) Volver al menu principal" -ForegroundColor White
    Write-Host ""
    $sub = Read-Host "Opcion"
    switch ($sub) {
        "1" { Edit-Config }
        "2" { Uninstall-All }
        "0" { return }
        default {
            Write-Warn "Opcion invalida: '$sub'"
            if ([Environment]::UserInteractive) { Start-Sleep -Seconds 1 }
        }
    }
}

function Show-StatusBrief {
    # Version resumida de Show-Status que no falla si falta docker
    $docker = Test-DockerInstalled
    if ($docker.Installed) {
        Write-Info "Docker: $($docker.Version)"
    } else {
        Write-Warn "Docker: NO instalado"
    }
    $arch = Get-Arch
    Write-Info "OS: Windows | Arch: $arch"

    $image = Test-ImageExists $ImageName $ImageTag
    if ($image) {
        Write-Info "Imagen: ${ImageName}:${ImageTag} OK"
    } else {
        Write-Info "Imagen: no construida (opcion 1 o 2)"
    }

    $running = Test-ServiceRunning
    if ($running) {
        Write-Info "Servicio: corriendo"
    } else {
        Write-Info "Servicio: detenido"
    }
}

function Pause-Interactive {
    # Pausa al final de cada opcion. Tolerante a no-interactivo.
    if ([Environment]::UserInteractive) {
        Write-Host ""
        Read-Host "Presiona Enter para volver al menu"
    }
}

function Read-MenuOption {
    # Lee la opcion del usuario. Retorna la cadena normalizada.
    # Termina el proceso si el usuario hace Ctrl+C o Ctrl+Z.
    $opt = Read-Host "Opcion"
    return $opt.Trim()
}

# =============================================================================
# Main
# =============================================================================

switch ($Command.ToLower()) {
    "setup"     { Invoke-FullSetup }
    "build"     { Initialize-Env; Build-Image }
    "reindex"   { Invoke-Reindex }
    "pull"      { Invoke-Pull }
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
            Show-Menu
            $opt = Read-MenuOption
            if ($null -eq $opt) {
                # Ctrl+C: salir limpio
                Write-Ok "Chau!"
                return
            }
            switch ($opt) {
                "1"  { Initialize-Env; Start-Service; Pause-Interactive }
                "2"  { Stop-Service; Pause-Interactive }
                "3"  { Show-Logs; Pause-Interactive }
                "4"  { Test-Health; Pause-Interactive }
                "5"  { Invoke-FullSetup; Pause-Interactive }
                "6"  { Initialize-Env; Build-Image; Pause-Interactive }
                "7"  { Invoke-Pull; Pause-Interactive }
                "8"  { Invoke-Reindex; Pause-Interactive }
                "9"  { Update-Code; Pause-Interactive }
                "10" { Show-ConfigUninstall-Menu }
                "0"  { Write-Ok "Chau!"; return }
                "q"  { Write-Ok "Chau!"; return }
                "quit"  { Write-Ok "Chau!"; return }
                "exit"  { Write-Ok "Chau!"; return }
                "salir" { Write-Ok "Chau!"; return }
                "" {
                    # Input vacio: volver a mostrar menu sin warn
                }
                default {
                    Write-Warn "Opcion invalida: '$opt' (usa 0-10)"
                    if ([Environment]::UserInteractive) { Start-Sleep -Seconds 1 }
                }
            }
        }
    }
    default {
        Write-Fail "Comando desconocido: $Command"
        Write-Info "Comandos validos: setup, build, reindex, pull, start, stop, logs, health, update, config, uninstall"
        exit 1
    }
}
