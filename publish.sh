#!/usr/bin/env bash
# =============================================================================
# RAG Presidentes Ecuador - Publish a Docker Hub (bash)
#
# Construye la imagen (amd64 por defecto) y la pushea a Docker Hub.
# NOTA: el Dockerfile NO genera embeddings en build; hornea el chroma_db/ local
# (generado con `python generate_embeddings.py`, GPU si disponible). Si falta, este
# script lo genera antes de buildear.
#
# Uso:
#   ./publish.sh --version 1.0.0
#   ./publish.sh --version 1.0.0 --platform linux/amd64
#   ./publish.sh --version 1.1.0 --no-push
#   ./publish.sh --version 1.0.0 --dry-run
#   ./publish.sh --help
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuracion
# =============================================================================

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

DOCKER_USER="alejololer"
IMAGE_NAME="rag-presidentes"
VERSION=""
PLATFORM="linux/amd64"
NO_PUSH=false
DRY_RUN=false

# Colores (deshabilitados si no es TTY)
if [ -t 1 ]; then
    C_CYAN='\033[0;36m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[1;33m'
    C_RED='\033[0;31m'
    C_GRAY='\033[0;90m'
    C_MAGENTA='\033[0;35m'
    C_NC='\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_MAGENTA=''; C_NC=''
fi

# =============================================================================
# Parseo de argumentos
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version)  VERSION="$2"; shift 2 ;;
        -p|--platform) PLATFORM="$2"; shift 2 ;;
        -u|--user)     DOCKER_USER="$2"; shift 2 ;;
        -i|--image)    IMAGE_NAME="$2"; shift 2 ;;
        --no-push)     NO_PUSH=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '2,14p' "$0"
            echo ""
            exit 0 ;;
        *) echo -e "${C_RED}Argumento desconocido: $1${C_NC}"; exit 1 ;;
    esac
done

# =============================================================================
# Funciones de output
# =============================================================================

log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $*" >> "$SCRIPT_DIR/publish.log" 2>/dev/null || true
}

step() { echo -e "${C_CYAN}[*]${C_NC} $*"; log "INFO" "$*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_NC} $*"; log "INFO" "$*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_NC} $*"; log "WARN" "$*"; }
fail() { echo -e "${C_RED}[FAIL]${C_NC} $*"; log "ERROR" "$*"; }
info() { echo -e "${C_GRAY}[INFO]${C_NC} $*"; log "INFO" "$*"; }

# =============================================================================
# Validaciones
# =============================================================================

if [ -z "$VERSION" ]; then
    fail "Falta --version. Uso: ./publish.sh --version 1.0.0"
    exit 1
fi

FULL_IMAGE="${DOCKER_USER}/${IMAGE_NAME}"
TAGGED_IMAGE="${FULL_IMAGE}:${VERSION}"
LATEST_IMAGE="${FULL_IMAGE}:latest"

# Strings legibles para logs
if [ "$NO_PUSH" = true ]; then PUSH_STR="false"; else PUSH_STR="true"; fi

# Banner
echo ""
echo -e "${C_CYAN}=========================================${C_NC}"
echo -e "${C_CYAN} RAG Presidentes - Publish a Docker Hub${C_NC}"
echo -e "${C_CYAN}=========================================${C_NC}"
echo ""
info "Registry:   Docker Hub (docker.io)"
info "Usuario:    $DOCKER_USER"
info "Imagen:     $FULL_IMAGE"
info "Version:    $VERSION"
info "Plataformas: $PLATFORM"
info "Push:       $PUSH_STR"
info "DryRun:     $DRY_RUN"
echo ""

# Validar Docker
step "Verificando Docker..."
if ! command -v docker &>/dev/null; then
    fail "Docker no esta instalado."
    exit 1
fi
if ! docker info &>/dev/null 2>&1; then
    fail "Docker no esta corriendo. Abrir Docker Desktop y reintentar."
    exit 1
fi
ok "Docker disponible"

# Validar formato de version
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    warn "La version '$VERSION' no sigue semver (X.Y.Z). Continuamos igual."
fi

echo ""

# =============================================================================
# DryRun: mostrar comandos sin ejecutar
# =============================================================================

if [ "$DRY_RUN" = true ]; then
    step "Modo DRY-RUN: mostrando que haria..."
    echo ""
    if [ "$NO_PUSH" = false ]; then
        echo "  1. docker login"
    fi
    echo "  2. docker buildx create --name rag-multiarch --use"
    echo "  3. docker buildx build \\"
    echo "         --platform $PLATFORM \\"
    echo "         -t $TAGGED_IMAGE \\"
    echo "         -t $LATEST_IMAGE \\"
    if [ "$NO_PUSH" = true ]; then
        echo "         --load ."
    else
        echo "         --push ."
    fi
    echo ""
    info "Para ejecutar de verdad, correr sin --dry-run"
    exit 0
fi

# =============================================================================
# Login a Docker Hub
# =============================================================================

if [ "$NO_PUSH" = false ]; then
    step "Login a Docker Hub..."
    info "Te pedira username y password. Si tenes 2FA, usa un Personal Access Token."
    echo ""
    if ! docker login; then
        fail "Login fallo. Verifica tus credenciales."
        exit 1
    fi
    ok "Login exitoso"
    echo ""
fi

# =============================================================================
# ChromaDB: asegurar que exista localmente (se hornea por COPY en el Dockerfile)
# =============================================================================
# El Dockerfile ya NO genera embeddings en build. Si no hay chroma_db/, lo
# generamos aca (get_model() usa GPU automaticamente si esta disponible).
step "Verificando chroma_db local..."
if [ ! -d chroma_db ] || [ -z "$(ls -A chroma_db 2>/dev/null)" ]; then
    warn "No hay chroma_db/ local. Generandolo (necesario para el build)..."
    PY=""
    if [ -x ".venv/bin/python" ]; then PY=".venv/bin/python"
    elif command -v python3 >/dev/null 2>&1; then PY="python3"
    elif command -v python >/dev/null 2>&1; then PY="python"; fi
    if [ -z "$PY" ]; then
        fail "No hay chroma_db/ ni Python para generarlo. Genera el indice en una maquina con Python (GPU recomendado) antes de publicar."
        exit 1
    fi
    PYTHONIOENCODING=utf-8 "$PY" generate_embeddings.py || { fail "Fallo generando chroma_db"; exit 1; }
    ok "chroma_db generado"
else
    ok "chroma_db local presente"
fi
echo ""

# =============================================================================
# Buildx: asegurar builder
# =============================================================================

step "Configurando builder multi-arch..."
if docker buildx create --name rag-multiarch --use 2>/dev/null; then
    info "Builder 'rag-multiarch' creado"
else
    info "Builder 'rag-multiarch' ya existe, reusando"
fi
if ! docker buildx inspect --bootstrap 2>/dev/null; then
    warn "Bootstrap del builder fallo (puede que ya este listo)"
fi
echo ""

# =============================================================================
# Build + Push (o solo Build)
# =============================================================================

if [ "$NO_PUSH" = true ]; then
    step "Build local (sin push) de $TAGGED_IMAGE..."
    info "Plataforma: $PLATFORM"
    info "Esto puede tardar 5-10 minutos la primera vez."
    echo ""

    if ! docker buildx build --platform "$PLATFORM" -t "$TAGGED_IMAGE" --load .; then
        fail "Build fallo"
        exit 1
    fi

    echo ""
    ok "Build local completo: $TAGGED_IMAGE"
    info "Para subir a Docker Hub, correr sin --no-push"
else
    step "Build + Push de $TAGGED_IMAGE..."
    info "Plataforma: $PLATFORM"
    info "Descarga modelo (cacheado), hornea el chroma_db local y pushea. Rapido si el cache esta caliente."
    echo ""

    if ! docker buildx build \
        --platform "$PLATFORM" \
        -t "$TAGGED_IMAGE" \
        -t "$LATEST_IMAGE" \
        --push .; then
        fail "Build o push fallo"
        exit 1
    fi

    echo ""
    ok "Imagen publicada: $TAGGED_IMAGE"
    ok "Tambien taggeada como: $LATEST_IMAGE"
    echo ""
    info "Pullable desde cualquier PC con:"
    echo -e "    ${C_CYAN}docker pull $TAGGED_IMAGE${C_NC}"
    echo ""
    info "Tag especifico en docker-compose.yml (mas seguro que :latest):"
    echo -e "    ${C_CYAN}image: ${FULL_IMAGE}:${VERSION}${C_NC}"
fi

# =============================================================================
# Verificacion post-push
# =============================================================================

if [ "$NO_PUSH" = false ]; then
    step "Verificando que la imagen es visible en Docker Hub..."
    if docker manifest inspect "$TAGGED_IMAGE" &>/dev/null; then
        ok "Manifest visible en Docker Hub"
    else
        warn "No se pudo inspeccionar el manifest (puede tardar unos minutos en propagarse)"
    fi
fi

echo ""
echo -e "${C_GREEN}=========================================${C_NC}"
echo -e "${C_GREEN} [OK] Publish completo${C_NC}"
echo -e "${C_GREEN}=========================================${C_NC}"
echo ""
