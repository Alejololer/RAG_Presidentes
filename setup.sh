#!/usr/bin/env bash
# =============================================================================
# RAG Presidentes Ecuador - Setup interactivo (macOS / Linux / Git Bash)
#
# Uso:
#   ./setup.sh                    # Menu interactivo
#   ./setup.sh setup              # Setup completo
#   ./setup.sh build              # Build imagen
#   ./setup.sh reindex            # Regenerar ChromaDB
#   ./setup.sh start              # Iniciar servicio
#   ./setup.sh stop               # Detener servicio
#   ./setup.sh logs               # Ver logs
#   ./setup.sh health             # Health check
#   ./setup.sh update             # git pull + rebuild
#   ./setup.sh config             # Editar .env
#   ./setup.sh uninstall          # Desinstalar
#
# Flags:
#   --auto                         # Modo no-interactivo (asume defaults)
#   --gpu                          # Build con soporte GPU NVIDIA
#   --platform <plat>              # Forzar plataforma (linux/amd64 | linux/arm64)
#   --dry-run                      # Mostrar que haria sin ejecutar
#   -h, --help                     # Ayuda
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuracion global
# =============================================================================

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

LOG_FILE="$SCRIPT_DIR/setup.log"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
IMAGE_NAME="rag-presidentes"
IMAGE_TAG="1.0.0"

# Flags parseados
AUTO_MODE=false
GPU_BUILD=false
FORCE_PLATFORM=""
DRY_RUN=false
COMMAND=""

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
        setup|build|reindex|pull|start|stop|logs|health|update|config|uninstall|help)
            COMMAND="$1"; shift ;;
        --auto) AUTO_MODE=true; shift ;;
        --gpu) GPU_BUILD=true; shift ;;
        --platform) FORCE_PLATFORM="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0 ;;
        *) echo "Argumento desconocido: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Funciones de output
# =============================================================================

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

banner() {
    echo ""
    echo -e "${C_CYAN}========================================${C_NC}"
    echo -e "${C_CYAN} RAG Presidentes Ecuador - Setup${C_NC}"
    echo -e "${C_CYAN}========================================${C_NC}"
    echo ""
}

step() { echo -e "${C_CYAN}[*]${C_NC} $*"; log "INFO" "$*"; }
ok()   { echo -e "${C_GREEN}[OK]${C_NC} $*"; log "INFO" "$*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_NC} $*"; log "WARN" "$*"; }
fail() { echo -e "${C_RED}[FAIL]${C_NC} $*"; log "ERROR" "$*"; }
info() { echo -e "${C_GRAY}[INFO]${C_NC} $*"; log "INFO" "$*"; }

run_cmd() {
    local desc="$1"; shift
    local cmd="$*"
    step "$desc"
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} $cmd"
        return 0
    fi
    log "INFO" "Ejecutando: $cmd"
    echo -e "  ${C_GRAY}>${C_NC} $cmd"
    if ! eval "$cmd"; then
        fail "Comando fallo: $cmd"
        return 1
    fi
}

# =============================================================================
# Deteccion de entorno
# =============================================================================

detect_os() {
    case "$OSTYPE" in
        darwin*)  echo "macos" ;;
        linux*)   echo "linux" ;;
        msys*|cygwin*|win32*) echo "windows-gitbash" ;;
        *)        echo "unknown" ;;
    esac
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "$arch" ;;
    esac
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "not_installed"
        return
    fi
    local version
    version=$(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')
    local running=false
    if docker info &>/dev/null; then
        running=true
    fi
    echo "installed:$version:running:$running"
}

check_buildx() {
    if ! command -v docker &>/dev/null; then
        echo "no_docker"
        return
    fi
    if docker buildx version &>/dev/null; then
        echo "available"
    else
        echo "unavailable"
    fi
}

check_ollama() {
    local host="${1:-http://localhost:11434}"
    local response
    response=$(curl -s --max-time 3 "$host/api/tags" 2>/dev/null || echo "")
    if [ -z "$response" ]; then
        echo "unreachable"
        return
    fi
    local has_qwen=false
    if echo "$response" | grep -q '"qwen2.5:7b"'; then
        has_qwen=true
    fi
    local count
    count=$(echo "$response" | grep -o '"name"' | wc -l | tr -d ' ')
    echo "reachable:$count:qwen:$has_qwen"
}

check_image() {
    if docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" &>/dev/null; then
        echo "exists"
    else
        echo "missing"
    fi
}

check_service() {
    if docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "rag"; then
        echo "running"
    else
        echo "stopped"
    fi
}

show_status() {
    banner
    echo -e "Estado actual:${C_NC}"
    echo ""

    local docker_status
    docker_status=$(check_docker)
    if [ "$docker_status" = "not_installed" ]; then
        fail "Docker no instalado (descargalo de https://www.docker.com/products/docker-desktop/)"
    else
        local ver running
        IFS=':' read -r _ ver _ running <<< "$docker_status"
        ok "Docker instalado: $ver"
        if [ "$running" = "true" ]; then
            ok "Docker corriendo"
        else
            warn "Docker no esta corriendo (abrir Docker Desktop)"
        fi
    fi

    local buildx
    buildx=$(check_buildx)
    case "$buildx" in
        available) ok "Docker buildx disponible (multi-arch OK)" ;;
        unavailable) warn "Docker buildx no disponible (multi-arch limitado)" ;;
        no_docker) ;;
    esac

    info "Arquitectura del host: $(detect_arch)"
    info "OS detectado: $(detect_os)"

    # En Linux, host.docker.internal no funciona: avisamos
    if [ "$(detect_os)" = "linux" ]; then
        info "Linux detectado: se usara USE_HOST_NETWORK=host automaticamente"
    fi

    local ollama
    ollama=$(check_ollama)
    if [[ "$ollama" == unreachable* ]]; then
        warn "Ollama no accesible en http://localhost:11434"
    else
        IFS=':' read -r _ count _ has_qwen <<< "$ollama"
        ok "Ollama accesible ($count modelos)"
        if [ "$has_qwen" = "false" ]; then
            warn "  Modelo qwen2.5:7b NO descargado. Ejecuta: ollama pull qwen2.5:7b"
        fi
    fi

    local img
    img=$(check_image)
    if [ "$img" = "exists" ]; then
        ok "Imagen ${IMAGE_NAME}:${IMAGE_TAG} construida"
    else
        warn "Imagen ${IMAGE_NAME}:${IMAGE_TAG} NO existe (requiere build)"
    fi

    local svc
    svc=$(check_service)
    if [ "$svc" = "running" ]; then
        ok "Servicio RAG corriendo"
    else
        warn "Servicio RAG detenido"
    fi

    if [ -f "$ENV_FILE" ]; then
        ok ".env configurado"
    else
        warn ".env no existe (usar opcion 9 para configurar)"
    fi
    echo ""
}

# =============================================================================
# Funciones principales
# =============================================================================

init_env() {
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$ENV_EXAMPLE" ]; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            ok ".env creado desde .env.example"
        else
            fail ".env.example no encontrado"
            return 1
        fi
    else
        info ".env ya existe"
    fi

    # En Linux, host.docker.internal no funciona. Forzar USE_HOST_NETWORK=host.
    # El valor debe ser "host" o "bridge" (NUNCA true/false — Docker los rechaza).
    if [ "$(detect_os)" = "linux" ]; then
        if grep -q "^USE_HOST_NETWORK=" "$ENV_FILE"; then
            sed -i 's/^USE_HOST_NETWORK=.*/USE_HOST_NETWORK=host/' "$ENV_FILE"
            info "USE_HOST_NETWORK=host (Linux necesita red host para Ollama)"
        fi
    fi
}

install_docker() {
    local status
    status=$(check_docker)
    if [ "$status" != "not_installed" ]; then return 0; fi

    warn "Docker no esta instalado."
    if [ "$AUTO_MODE" = false ]; then
        read -p "Abrir pagina de descarga? (s/n) " resp
        if [ "$resp" = "s" ] || [ "$resp" = "S" ]; then
            if [ "$(detect_os)" = "macos" ]; then
                open "https://www.docker.com/products/docker-desktop/"
            else
                xdg-open "https://www.docker.com/products/docker-desktop/" 2>/dev/null || \
                    echo "Abre: https://www.docker.com/products/docker-desktop/"
            fi
        fi
    fi
    fail "Instala Docker y vuelve a correr este script."
    exit 1
}

# Verifica que Docker este instalado Y corriendo antes de cualquier comando.
# Si no lo esta, muestra una guia clara segun el OS y termina con exit 1.
# Esta funcion se llama al inicio de build, start, reindex, stop, logs, etc.
ensure_docker_running() {
    local status
    status=$(check_docker)

    if [ "$status" = "not_installed" ]; then
        print_docker_not_installed_guide
        exit 1
    fi

    # Docker esta instalado. Verificar que este corriendo.
    if ! docker info &>/dev/null 2>&1; then
        print_docker_not_running_guide
        exit 1
    fi
}

# Guia detallada: Docker no instalado. Que hacer segun el OS.
print_docker_not_installed_guide() {
    local os
    os=$(detect_os)

    echo ""
    echo -e "${C_RED}============================================================${C_NC}"
    echo -e "${C_RED} Docker no esta instalado en esta PC${C_NC}"
    echo -e "${C_RED}============================================================${C_NC}"
    echo ""
    echo "El setup necesita Docker Desktop para construir y correr el servicio."
    echo ""

    case "$os" in
        macos)
            echo "Estas en macOS. Pasos para instalar Docker:"
            echo ""
            echo "  1. Descarga Docker Desktop desde:"
            echo "       https://www.docker.com/products/docker-desktop/"
            echo ""
            echo "  2. Abre el archivo .dmg descargado y arrastra Docker a Aplicaciones."
            echo ""
            echo "  3. Abre Docker Desktop desde Aplicaciones y espera a que"
            echo "     el icono de la barra de menu muestre 'Docker Desktop is running'."
            echo ""
            echo "  4. Vuelve a correr este script."
            ;;
        windows-gitbash)
            echo "Estas en Windows. Pasos para instalar Docker:"
            echo ""
            echo "  1. Descarga Docker Desktop desde:"
            echo "       https://www.docker.com/products/docker-desktop/"
            echo ""
            echo "  2. Ejecuta el instalador Docker Desktop Installer.exe"
            echo "     - Te pedira usar WSL 2 como backend (recomendado)."
            echo "     - Reinicia Windows cuando lo pida."
            echo ""
            echo "  3. Abre Docker Desktop desde el menu Inicio."
            echo "     Espera a que el icono de la barra de tareas diga"
            echo "     'Docker Desktop is running'."
            echo ""
            echo "  4. Vuelve a correr este script en PowerShell o Git Bash."
            ;;
        linux)
            echo "Estas en Linux. Pasos para instalar Docker:"
            echo ""
            echo "  Ubuntu / Debian:"
            echo "    curl -fsSL https://get.docker.com -o get-docker.sh"
            echo "    sudo sh get-docker.sh"
            echo "    sudo usermod -aG docker \$USER"
            echo "    # Cierra sesion y vuelve a entrar para que tome efecto"
            echo ""
            echo "  Fedora / RHEL:"
            echo "    sudo dnf install docker docker-compose-plugin"
            echo "    sudo systemctl start docker"
            echo "    sudo systemctl enable docker"
            echo "    sudo usermod -aG docker \$USER"
            echo ""
            echo "  Arch:"
            echo "    sudo pacman -S docker docker-compose"
            echo "    sudo systemctl start docker.service"
            echo "    sudo usermod -aG docker \$USER"
            echo ""
            echo "  Despues de instalar, vuelve a correr este script."
            ;;
        *)
            echo "Instala Docker desde: https://www.docker.com/products/docker-desktop/"
            echo "O usando el gestor de paquetes de tu distribucion."
            ;;
    esac
    echo ""
}

# Guia detallada: Docker instalado pero NO corriendo.
print_docker_not_running_guide() {
    local os
    os=$(detect_os)

    echo ""
    echo -e "${C_RED}============================================================${C_NC}"
    echo -e "${C_RED} Docker esta instalado pero NO esta corriendo${C_NC}"
    echo -e "${C_RED}============================================================${C_NC}"
    echo ""
    echo "Docker Desktop es un programa que tiene que estar abierto y"
    echo "corriendo para que podamos construir y levantar contenedores."
    echo ""
    echo "Si llegaste aca, probablemente viste un error como:"
    echo "  Cannot connect to the Docker daemon at unix:///.../docker.sock"
    echo "  Is the docker daemon running?"
    echo ""
    echo "Eso significa que el cliente (docker) esta instalado pero el"
    echo "servicio/daemon no esta activo. Solucion:"
    echo ""

    case "$os" in
        macos)
            echo "  1. Abre Docker Desktop desde Aplicaciones."
            echo "     (Si no lo tienes instalado, mira la guia de instalacion)"
            echo ""
            echo "  2. Espera ~30 segundos a que el motor arranque. Lo sabras"
            echo "     cuando el icono de la ballena en la barra superior"
            echo "     deje de animarse y diga 'Docker Desktop is running'."
            echo ""
            echo "  3. Vuelve a correr este script."
            echo ""
            echo "  Si Docker Desktop esta abierto pero igual no anda:"
            echo "    - Menu Docker > Troubleshoot > Restart Docker Desktop"
            echo "    - O cierra y vuelve a abrir Docker Desktop"
            ;;
        windows-gitbash)
            echo "  1. Abre Docker Desktop desde el menu Inicio."
            echo "     (Si no lo tienes instalado, mira la guia de instalacion)"
            echo ""
            echo "  2. Espera ~30 segundos a que el motor arranque. El icono"
            echo "     de la ballena en la barra de tareas pasara de"
            echo "     'Docker Desktop is starting' a 'Docker Desktop is running'."
            echo ""
            echo "  3. Vuelve a correr este script en PowerShell o Git Bash."
            echo ""
            echo "  Si Docker Desktop esta abierto pero igual no anda:"
            echo "    - Click derecho en el icono > Troubleshoot > Restart"
            echo "    - O cierra y vuelve a abrir Docker Desktop"
            echo ""
            echo "  Si usas WSL 2 y el error persiste:"
            echo "    - PowerShell como Administrador:"
            echo "      wsl --shutdown"
            echo "      wsl"
            echo "    - Despues vuelve a abrir Docker Desktop."
            ;;
        linux)
            echo "  1. Inicia el servicio de Docker:"
            echo ""
            echo "     sudo systemctl start docker"
            echo "     sudo systemctl enable docker  # para que arranque con el sistema"
            echo ""
            echo "  2. Verifica que este corriendo:"
            echo ""
            echo "     sudo systemctl status docker"
            echo ""
            echo "  3. Si usas un usuario no-root, asegurate de estar en el grupo docker:"
            echo ""
            echo "     sudo usermod -aG docker \$USER"
            echo "     # Cierra sesion y vuelve a entrar"
            echo ""
            echo "  4. Vuelve a correr este script."
            echo ""
            echo "  Si usas Docker Desktop (raro en Linux):"
            echo "    - Abre Docker Desktop desde tu escritorio"
            echo "    - Espera a que el motor arranque"
            echo "    - Vuelve a correr este script"
            ;;
        *)
            echo "Inicia el servicio de Docker segun tu sistema operativo."
            echo "Vuelve a correr este script cuando este corriendo."
            ;;
    esac
    echo ""
    echo "Para verificar manualmente que Docker esta corriendo:"
    echo "  docker info"
    echo ""
}

ensure_buildx() {
    if [ "$(check_buildx)" = "available" ]; then return 0; fi

    step "Creando builder buildx para multi-arch..."
    if [ "$DRY_RUN" = true ]; then return 0; fi
    if docker buildx create --name multiarch --use 2>/dev/null && \
       docker buildx inspect --bootstrap 2>/dev/null; then
        ok "Builder multiarch listo"
    else
        warn "No se pudo crear builder multiarch. Build limitado a plataforma local."
    fi
}

build_image() {
    ensure_docker_running
    step "Construyendo imagen Docker..."
    info "Esto puede tardar 5-10 minutos la primera vez (descarga modelo + genera ChromaDB)."

    ensure_buildx

    local platform="${FORCE_PLATFORM:-linux/$(detect_arch)}"
    info "Plataforma: $platform"

    local gpu_args=""
    if [ "$GPU_BUILD" = true ]; then
        gpu_args="--build-arg INSTALL_GPU=true"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} docker buildx build --platform $platform -t ${IMAGE_NAME}:${IMAGE_TAG} ."
        return 0
    fi

    if ! docker buildx build --platform "$platform" \
        -t "${IMAGE_NAME}:${IMAGE_TAG}" \
        -t "${IMAGE_NAME}:latest" \
        $gpu_args \
        --load .; then
        fail "Build fallo. Revisa $LOG_FILE"
        return 1
    fi
    ok "Imagen construida: ${IMAGE_NAME}:${IMAGE_TAG}"
}

reindex() {
    ensure_docker_running
    step "Re-generando ChromaDB..."
    info "Levanta un contenedor efimero para regenerar el indice."

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} docker compose run --rm rag python generate_embeddings.py"
        return 0
    fi

    # Necesitamos el servicio corriendo para usar exec
    if ! docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "rag"; then
        info "Servicio no esta corriendo, levantando temporalmente..."
        docker compose up -d rag
        sleep 3
    fi

    if docker compose exec rag python generate_embeddings.py; then
        ok "ChromaDB regenerado"
    else
        fail "Reindex fallo"
        return 1
    fi
}

# Descarga la imagen del registry (Docker Hub) si no esta local.
# Si la imagen no existe ni local ni en el registry, falla con mensaje claro
# (no cae automaticamente a build - eso lo maneja start_service).
pull_image() {
    ensure_docker_running
    step "Descargando imagen de Docker Hub..."
    info "Registry: juanprof/rag-presidentes"
    info "Esto descarga ~1 GB la primera vez."

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} docker compose pull rag"
        return 0
    fi

    if docker compose pull rag; then
        ok "Imagen descargada/actualizada"
    else
        fail "No se pudo descargar la imagen del registry."
        info "Posibles causas:"
        info "  - Sin conexion a internet"
        info "  - La imagen no fue publicada todavia (corre ./publish.sh o publish.ps1 primero)"
        info "  - Tag especifico no existe (revisar IMAGE_VERSION en .env)"
        return 1
    fi
}

start_service() {
    ensure_docker_running

    # Si la imagen del registry (juanprof/rag-presidentes:VERSION) no esta
    # localmente, intentar pull automatico. Si el pull falla, hace build
    # local (caso dev que aun no publico la primera version).
    if ! check_image > /dev/null 2>&1; then
        info "Imagen local no encontrada, intentando descargar de Docker Hub..."
        if pull_image 2>/dev/null; then
            ok "Imagen descargada del registry"
        else
            warn "No se pudo descargar del registry. Intentando build local..."
            if [ "$DRY_RUN" = false ]; then
                docker compose build rag || {
                    fail "Build local tambien fallo. Revisa tu conexion o publica la imagen primero."
                    return 1
                }
            fi
        fi
    fi

    step "Iniciando servicio..."
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} docker compose up -d"
        return 0
    fi

    if ! docker compose up -d; then
        fail "No se pudo iniciar el servicio"
        return 1
    fi

    info "Esperando healthcheck..."
    local healthy=false
    for i in {1..30}; do
        sleep 2
        local status
        status=$(docker compose ps --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
        if [ "$status" = "healthy" ]; then
            healthy=true
            break
        fi
    done

    if [ "$healthy" = true ]; then
        ok "Servicio saludable"
    else
        warn "Servicio iniciado pero aun no responde. Revisa logs (opcion 6)."
    fi
}

stop_service() {
    ensure_docker_running
    step "Deteniendo servicio..."
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} docker compose down"
        return 0
    fi
    docker compose down
    ok "Servicio detenido (volume de chroma_db preservado)"
}

show_logs() {
    ensure_docker_running
    step "Mostrando logs (Ctrl+C para salir)..."
    if [ "$DRY_RUN" = true ]; then return 0; fi
    docker compose logs -f --tail=100 rag
}

test_health() {
    ensure_docker_running
    step "Health check..."
    if [ "$DRY_RUN" = true ]; then return 0; fi

    local port=8010
    if [ -f "$ENV_FILE" ]; then
        port=$(grep "^PUERTO=" "$ENV_FILE" | cut -d'=' -f2 | tr -d ' \r\n' || echo "8010")
    fi
    local base_url="http://localhost:${port}"
    info "Endpoint: $base_url"

    # Health endpoint
    if response=$(curl -s --max-time 5 "$baseUrl/health" 2>/dev/null); then
        ok "GET /health -> OK"
        echo "$response"
    else
        fail "GET /health fallo"
        return 1
    fi
    echo ""

    # Smoke test /chat
    step "Smoke test /chat..."
    local prompt
    if [ "$AUTO_MODE" = true ]; then
        prompt="Eloy Alfaro, saludame en una oracion"
    else
        read -p "Prompt (Enter para default): " prompt
        [ -z "$prompt" ] && prompt="Eloy Alfaro, saludame en una oracion"
    fi

    local body
    body=$(printf '{"prompt": "%s"}' "$prompt")

    if response=$(curl -s --max-time 30 -X POST -H "Content-Type: application/json" \
        -d "$body" "$base_url/chat" 2>/dev/null); then
        ok "POST /chat -> OK"
        # Pretty print con python o jq si estan disponibles
        if command -v python3 &>/dev/null; then
            echo "$response" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f'Presidente: {d.get(\"presidente\")}')
    print(f'Fuentes locales: {len(d.get(\"fuentes\", []))}')
    print(f'Fuentes externas: {len(d.get(\"fuentes_externas\", []))}')
    print('')
    print('Respuesta:')
    print(d.get('response', ''))
except Exception as e:
    print(sys.stdin.read())
"
        else
            echo "$response"
        fi
    else
        fail "POST /chat fallo"
    fi
}

update_code() {
    ensure_docker_running
    step "Actualizando codigo (git pull + rebuild)..."

    if [ ! -d ".git" ]; then
        warn "No es un repo git. No se puede hacer pull."
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} git pull"
        return 0
    fi

    if git pull; then
        ok "Codigo actualizado"
    else
        fail "git pull fallo"
        return 1
    fi

    info "Rebuilding imagen..."
    build_image

    info "Reiniciando servicio..."
    stop_service
    start_service
}

edit_config() {
    if [ ! -f "$ENV_FILE" ]; then
        init_env
    fi

    step "Configuracion actual:"
    grep -E "^[A-Z]" "$ENV_FILE" | grep -v "^#" | while read -r line; do
        echo -e "  ${C_GRAY}$line${C_NC}"
    done
    echo ""

    if [ "$AUTO_MODE" = true ]; then return 0; fi

    read -p "Abrir .env en el editor default? (s/n) " resp
    if [ "$resp" = "s" ] || [ "$resp" = "S" ]; then
        if [ "$(detect_os)" = "macos" ]; then
            open "$ENV_FILE"
        elif [ "$(detect_os)" = "windows-gitbash" ]; then
            notepad "$ENV_FILE" &
        else
            ${EDITOR:-nano} "$ENV_FILE"
        fi
        warn "Despues de editar, reinicia el servicio (opcion 4)"
    fi
}

uninstall_all() {
    ensure_docker_running
    warn "Esto eliminara: contenedor, imagen, y opcionalmente volumes."
    if [ "$AUTO_MODE" = false ]; then
        read -p "Continuar? (s/n) " resp
        [ "$resp" != "s" ] && [ "$resp" != "S" ] && return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} docker compose down -v"
        echo -e "  ${C_MAGENTA}[DRY-RUN]${C_NC} docker rmi ${IMAGE_NAME}:${IMAGE_TAG}"
        return 0
    fi

    docker compose down -v 2>/dev/null || true
    docker rmi "${IMAGE_NAME}:${IMAGE_TAG}" 2>/dev/null || true
    docker rmi "${IMAGE_NAME}:latest" 2>/dev/null || true
    ok "Desinstalacion completa"
}

full_setup() {
    banner
    step "Setup completo de RAG Presidentes Ecuador"
    echo ""

    install_docker
    init_env
    build_image
    start_service
    test_health
    echo ""
    ok "Setup completo! Servicio corriendo en http://localhost:8010"
}

# =============================================================================
# Menu interactivo
# =============================================================================

pause_interactive() {
    # Pausa amigable al final de cada opcion. Tolerante a stdin no interactivo.
    if [ -t 0 ]; then
        echo ""
        read -rp "Presiona Enter para volver al menu..." _
    fi
}

show_menu() {
    # Imprime el menu y el estado resumido. NO lee input.
    # La lectura se hace en el caller con prompt_menu_input.
    clear 2>/dev/null || true
    banner
    echo "Selecciona una opcion:"
    echo ""
    echo "  [Uso diario]"
    echo "  1)  Iniciar servicio         (docker compose up -d, pull auto si no hay imagen)"
    echo "  2)  Detener servicio         (docker compose down)"
    echo "  3)  Ver logs                 (docker compose logs -f)"
    echo "  4)  Verificar salud          (curl /health + smoke test /chat)"
    echo ""
    echo "  [Avanzadas]"
    echo "  5)  Setup completo           (primera vez: build, configura, levanta)"
    echo "  6)  Build imagen             (rebuild local con ultima version del codigo)"
    echo "  7)  Pull imagen              (descarga de Docker Hub: juanprof/rag-presidentes)"
    echo "  8)  Re-indexar dataset       (regenera ChromaDB desde el JSONL)"
    echo "  9)  Actualizar codigo        (git pull + rebuild + restart)"
    echo "  10) Reconfigurar / Desinstalar (submenu)"
    echo "  0)  Salir"
    echo ""

    # Mostrar estado actual como contexto (best-effort, no bloqueante)
    if [ -t 0 ]; then
        echo -e "${C_GRAY}--- Estado actual ---${C_NC}"
        show_status_brief 2>/dev/null || true
        echo ""
    fi
}

# Lee el input del usuario de forma robusta.
# - Detecta EOF (Ctrl+D) y retorna 1.
# - Detecta input vacio y retorna "" sin error.
# - Escribe el prompt a stderr para no contaminar stdout.
prompt_menu_input() {
    local opt=""
    # Imprimir prompt a stderr para que no se mezcle con stdout
    echo -n "Opcion: " >&2
    if ! read -r opt; then
        # EOF / stdin cerrado
        echo "" >&2
        return 1
    fi
    # Trim
    opt="${opt// /}"
    echo "$opt"
    return 0
}

# Version resumida del estado para mostrar junto al menu (no falla si docker no esta)
show_status_brief() {
    local docker_status
    docker_status=$(check_docker 2>/dev/null || echo "not_installed")
    if [ "$docker_status" = "not_installed" ]; then
        warn "Docker no instalado"
    else
        info "Docker: OK | $(detect_os) | $(detect_arch)"
    fi

    local img
    img=$(check_image 2>/dev/null || echo "missing")
    if [ "$img" = "exists" ]; then
        info "Imagen: ${IMAGE_NAME}:${IMAGE_TAG} OK"
    else
        info "Imagen: no construida (opcion 1 o 2)"
    fi

    local svc
    svc=$(check_service 2>/dev/null || echo "stopped")
    if [ "$svc" = "running" ]; then
        info "Servicio: corriendo en http://localhost:${PUERTO:-8010}"
    else
        info "Servicio: detenido"
    fi
}

# Submenu para la opcion 10: configurar o desinstalar
submenu_config_uninstall() {
    clear 2>/dev/null || true
    echo ""
    echo "  Submenu:"
    echo ""
    echo "  1) Reconfigurar (editar .env)"
    echo "  2) Desinstalar (down -v + remove imagen)"
    echo "  0) Volver al menu principal"
    echo ""
    local sub
    read -rp "Opcion: " sub
    case "$sub" in
        1) edit_config ;;
        2) uninstall_all ;;
        0) return 0 ;;
        *) warn "Opcion invalida" ;;
    esac
}

# =============================================================================
# Main
# =============================================================================

case "$COMMAND" in
    setup)     full_setup ;;
    build)     init_env; build_image ;;
    reindex)   reindex ;;
    pull)      pull_image ;;
    start)     init_env; start_service ;;
    stop)      stop_service ;;
    logs)      show_logs ;;
    health)    test_health ;;
    update)    update_code ;;
    config)    edit_config ;;
    uninstall) uninstall_all ;;
    help|-h|--help)
        sed -n '2,25p' "$0"
        exit 0 ;;
    "")
        # Modo interactivo
        while true; do
            # Imprimir menu (a stdout, separado del read)
            show_menu
            # Leer opcion del usuario
            if ! opt=$(prompt_menu_input); then
                # EOF / Ctrl+D
                echo ""
                ok "Chau!"
                exit 0
            fi

            case "$opt" in
                1)  init_env; start_service; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                2)  stop_service; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                3)  show_logs; pause_interactive ;;
                4)  test_health; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                5)  full_setup; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                6)  init_env; build_image; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                7)  pull_image; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                8)  reindex; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                9)  update_code; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                10) submenu_config_uninstall; [ "$AUTO_MODE" = false ] && pause_interactive ;;
                0|q|quit|exit|salir)
                    ok "Chau!"
                    exit 0
                    ;;
                "")
                    # Input vacio: volver a mostrar menu sin warn
                    ;;
                *)
                    warn "Opcion invalida: '$opt' (usa 0-10)"
                    sleep 1
                    ;;
            esac
        done
        ;;
    *)
        fail "Comando desconocido: $COMMAND"
        info "Comandos validos: setup, build, reindex, start, stop, logs, health, update, config, uninstall"
        exit 1
        ;;
esac
