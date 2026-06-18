# =============================================================================
# RAG Presidentes Ecuador - Publish a Docker Hub
#
# Construye la imagen multi-arch y la pushea a Docker Hub para distribucion.
#
# Uso:
#   .\publish.ps1 -Version 1.0.0
#   .\publish.ps1 -Version 1.0.0 -Platform linux/amd64
#   .\publish.ps1 -Version 1.1.0 -NoPush    # solo build local
#   .\publish.ps1 -Version 1.0.0 -DryRun    # muestra que haria sin ejecutar
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Platform = "linux/amd64,linux/arm64",
    [string]$DockerUser = "juanprof",
    [string]$ImageName = "rag-presidentes",
    [switch]$NoPush,
    [switch]$DryRun
)

# =============================================================================
# Configuracion
# =============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

# Forzar UTF-8 (la consola Windows default es cp1252)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$FullImage = "${DockerUser}/${ImageName}"
$TaggedImage = "${FullImage}:${Version}"
$LatestImage = "${FullImage}:latest"

# =============================================================================
# Funciones de output
# =============================================================================

function Write-Step { param($msg) Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Gray }

# =============================================================================
# Banner
# =============================================================================

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " RAG Presidentes - Publish a Docker Hub" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Registry:   Docker Hub (docker.io)"
Write-Host "  Usuario:    $DockerUser"
Write-Host "  Imagen:     $FullImage"
Write-Host "  Version:    $Version"
Write-Host "  Plataformas: $Platform"
Write-Host "  Push:       $(-not $NoPush)"
Write-Host "  DryRun:     $DryRun"
Write-Host ""

# =============================================================================
# Validaciones previas
# =============================================================================

Write-Step "Verificando Docker..."
try {
    $null = docker version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Docker no responde" }
    Write-Ok "Docker disponible"
} catch {
    Write-Fail "Docker no esta disponible. Abri Docker Desktop y reintenta."
    exit 1
}

# Validar formato de version (semver basico)
if ($Version -notmatch "^\d+\.\d+\.\d+") {
    Write-Warn "La version '$Version' no sigue semver (X.Y.Z). Continuamos igual pero ojo."
}

Write-Host ""

# =============================================================================
# DryRun: mostrar comandos sin ejecutar
# =============================================================================

if ($DryRun) {
    Write-Step "Modo DRY-RUN: mostrando que haria..."
    Write-Host ""
    Write-Host "  1. docker login"
    Write-Host "  2. docker buildx create --name rag-multiarch --use"
    Write-Host "  3. docker buildx build \\"
    Write-Host "         --platform $Platform \\"
    Write-Host "         -t $TaggedImage \\"
    Write-Host "         -t $LatestImage \\"
    if ($NoPush) {
        Write-Host "         --load ."
    } else {
        Write-Host "         --push ."
    }
    Write-Host ""
    Write-Info "Para ejecutar de verdad, correr sin -DryRun"
    exit 0
}

# =============================================================================
# Login a Docker Hub
# =============================================================================

if (-not $NoPush) {
    Write-Step "Login a Docker Hub..."
    Write-Info "Te pedira username y password. Si tenes 2FA activado, usa un Personal Access Token."
    Write-Host ""

    docker login
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Login fallo. Verifica tus credenciales."
        exit 1
    }
    Write-Ok "Login exitoso"
    Write-Host ""
}

# =============================================================================
# Buildx: asegurar builder multi-arch
# =============================================================================

Write-Step "Configurando builder multi-arch..."
try {
    $null = docker buildx create --name rag-multiarch --use 2>&1
    Write-Info "Builder 'rag-multiarch' creado/ya existe"
} catch {
    Write-Info "Builder ya existe o se reutiliza"
}

try {
    $null = docker buildx inspect --bootstrap 2>&1
} catch {
    Write-Warn "No se pudo hacer bootstrap del builder (puede que ya este listo)"
}
Write-Host ""

# =============================================================================
# Build + Push (o solo Build)
# =============================================================================

if ($NoPush) {
    Write-Step "Build local (sin push) de $TaggedImage..."
    Write-Info "Plataforma: $Platform"
    Write-Info "Esto puede tardar 5-10 minutos la primera vez."
    Write-Host ""

    try {
        docker buildx build --platform $Platform -t $TaggedImage --load .
        if ($LASTEXITCODE -ne 0) { throw "Build fallo" }
    } catch {
        Write-Fail "Build fallo: $_"
        exit 1
    }

    Write-Host ""
    Write-Ok "Build local completo: $TaggedImage"
    Write-Info "Para subir a Docker Hub, correr sin -NoPush"
} else {
    Write-Step "Build + Push de $TaggedImage..."
    Write-Info "Plataforma: $Platform"
    Write-Info "Esto puede tardar 5-10 minutos la primera vez (descarga modelo + genera ChromaDB + push)."
    Write-Host ""

    try {
        docker buildx build `
            --platform $Platform `
            -t $TaggedImage `
            -t $LatestImage `
            --push .

        if ($LASTEXITCODE -ne 0) { throw "Build o push fallo" }
    } catch {
        Write-Fail "Build/push fallo: $_"
        exit 1
    }

    Write-Host ""
    Write-Ok "Imagen publicada: $TaggedImage"
    Write-Ok "Tambien taggeada como: $LatestImage"
    Write-Host ""
    Write-Info "Pullable desde cualquier PC con:"
    Write-Host "    docker pull $TaggedImage" -ForegroundColor White
    Write-Host ""
    Write-Info "Tag especifico en docker-compose.yml (mas seguro que :latest):"
    Write-Host "    image: ${FullImage}:${Version}" -ForegroundColor White
}

# =============================================================================
# Verificacion post-push
# =============================================================================

if (-not $NoPush) {
    Write-Step "Verificando que la imagen es pullable desde Docker Hub..."
    # No hacemos docker pull (tarda mucho), solo confirmamos via docker manifest
    try {
        $null = docker manifest inspect $TaggedImage 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Manifest visible en Docker Hub"
        } else {
            Write-Warn "No se pudo inspeccionar el manifest (puede tardar unos minutos en propagarse)"
        }
    } catch {
        Write-Warn "No se pudo inspeccionar el manifest (puede tardar unos minutos en propagarse)"
    }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " [OK] Publish completo" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
