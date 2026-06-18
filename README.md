# Servicio RAG — Presidentes del Ecuador (Proyecto *Opción 2049*)

Microservicio de **Retrieval-Augmented Generation (RAG)** que permite "conversar"
con los presidentes del Ecuador. El usuario pregunta y el sistema responde **en
primera persona, impersonando al presidente** correspondiente, usando
**únicamente** información de un archivo histórico curado (74 presidentes, 13
secciones temáticas cada uno).

Forma parte del ecosistema transmedia **Opción 2049**, donde actúa como el
"servicio de RAG" del backend que responde consultas del público.

---

## 📖 Parte 1 — Guía de usuario

### ¿Qué hace?

- Preguntas como *"Eloy Alfaro, ¿cuáles fueron tus obras públicas?"* obtienen una
  respuesta **en la voz del propio presidente**, con su tono e ideología.
- Las respuestas se basan **solo** en el archivo histórico: si el dato no está,
  el presidente **lo reconoce con honestidad** en vez de inventar.
- Cada respuesta incluye las **fuentes** (qué presidente y qué sección se usaron).

### Ejemplos de uso

| Pregunta | Comportamiento |
|----------|----------------|
| "Háblame de las obras de Eloy Alfaro" | Responde como Alfaro, solo con datos de Alfaro |
| "García Moreno, ¿qué leyes impulsaste?" | Responde como García Moreno, sin mezclar otros |
| "Alfaro, ¿qué opinas del bitcoin?" | "No puedo opinar, viví en otro siglo" (no inventa) |
| "¿Quién fue el mejor presidente?" | Pide que especifiques de quién hablar |

### Cómo arrancarlo (Windows)

#### Opción A — Setup interactivo con Docker (Recomendado para producción)

1. Instala **[Docker Desktop](https://www.docker.com/products/docker-desktop/)**
   y **[Ollama](https://ollama.com)** con el modelo:
   ```
   ollama pull qwen2.5:7b
   ```
2. Abre PowerShell en la carpeta del proyecto y ejecuta:
   ```powershell
   .\setup.ps1
   ```
3. Selecciona opción **1) Setup completo**. El script verifica Docker, builda
   la imagen con el ChromaDB precomputado, y levanta el servicio.
4. Verifica en **http://localhost:8010/health**

Comandos útiles:
```powershell
.\setup.ps1 start     # Iniciar
.\setup.ps1 stop      # Detener
.\setup.ps1 logs      # Ver logs
.\setup.ps1 health    # Smoke test
.\setup.ps1 update    # git pull + rebuild
.\setup.ps1 --help    # Mas opciones
```

#### Opción B — Sin Docker (desarrollo local, scripts legacy)

1. Doble clic en **`iniciar_rag.bat`** (o `lanzar_rag_desde_cmd.bat` si no usas
   PowerShell). La primera vez creará el entorno e indexará los datos.
2. Abre tu navegador en **http://localhost:8010**

> La primera ejecución descarga el modelo de embeddings (~1 GB) y genera el
> índice. Las siguientes son inmediatas.

---

## 🐳 Despliegue con Docker (recomendado para producción)

### ¿Por qué Docker?

- **Reproducibilidad total**: misma imagen, mismo comportamiento, en cualquier PC.
- **Cero "en mi máquina funciona"**: el entorno está empaquetado.
- **ChromaDB precomputado**: la imagen ya incluye el índice generado. Arranque instantáneo.
- **Multi-arquitectura**: `linux/amd64` y `linux/arm64` con un solo build.

### Estructura de archivos Docker

```
proyecto/
├── Dockerfile                  # Multi-stage, multi-arch, ChromaDB precomputado
├── docker-compose.yml          # Servicio único, configurable via .env
├── .dockerignore               # Exclusiones de build
├── .env.example                # Plantilla de configuracion (copiar a .env)
├── entrypoint.sh               # Arranque del contenedor (verifica ChromaDB + Ollama)
├── rag.bat                     # Entry point Windows (menu de 10 opciones)
├── setup.ps1                   # Setup interactivo Windows (motor detras de rag.bat)
├── setup.sh                    # Setup interactivo macOS/Linux
├── publish.ps1                 # Build multi-arch + push a Docker Hub
├── legacy/                     # Scripts .bat pre-Docker (deprecados)
│   ├── iniciar_rag.bat
│   ├── lanzar_rag_desde_cmd.bat
│   └── README.md
└── (código de la app)
```

### Setup en una PC nueva (Windows)

```cmd
REM 1. Instalar prerequisitos
REM    - Docker Desktop: https://www.docker.com/products/docker-desktop/
REM    - Ollama: https://ollama.com
REM    - Modelo: ollama pull qwen2.5:7b

REM 2. Doble clic en rag.bat (o desde CMD):
rag.bat
REM Opcion 5: Setup completo (primera vez)
```

O si preferis PowerShell directo:
```powershell
.\setup.ps1 setup
```

### Setup en una PC nueva (macOS / Linux)

```bash
./setup.sh                     # Menu interactivo
# Opcion 5: Setup completo (primera vez)
```

La primera vez el script:
1. Verifica Docker.
2. **Descarga la imagen de Docker Hub** (`juanprof/rag-presidentes:1.0.0`, ~1 GB).
3. Genera/usa `.env`.
4. Levanta el servicio.

Las siguientes veces es instantáneo (la imagen ya está local).

### Publicar una version nueva (mantenedores)

```powershell
# 1. Login a Docker Hub (una vez, te pide user/pass)
docker login

# 2. Build multi-arch + push automatico
.\publish.ps1 -Version 1.1.0
```

Las imagenes quedan publicadas en:
- `juanprof/rag-presidentes:1.1.0` (tag especifico)
- `juanprof/rag-presidentes:latest` (tag mobile, NO recomendado para produccion)

Verificable con:
```bash
docker pull juanprof/rag-presidentes:1.1.0
```

### Build local (sin publicar)

Si queres iterar sin pushear al registry:

```powershell
.\setup.ps1 build --platform linux/amd64
```

Esto buildea la imagen localmente (no la sube a Docker Hub) y queda como
`juanprof/rag-presidentes:1.0.0` en tu cache local. `start` la usa
automaticamente.

### Configuración (.env)

El archivo `.env` se crea automáticamente desde `.env.example`. Variables clave:

| Variable | Default | Descripción |
|----------|---------|-------------|
| `PUERTO` | `8010` | Puerto del servicio |
| `OLLAMA_HOST` | `http://host.docker.internal:11434` | URL de Ollama en el host |
| `OLLAMA_MODEL` | `qwen2.5:7b` | Modelo a usar |
| `RAG_TOP_K` | `5` | Chunks recuperados por consulta |
| `CORS_ORIGINS` | `*` | Origenes CORS permitidos |

**Nota sobre Linux**: en Linux, `host.docker.internal` no funciona por defecto.
El setup script configura `USE_HOST_NETWORK=true` automáticamente.

### HTTPS

El contenedor expone HTTP plano en el puerto 8010. Para acceso desde internet:

- **Cloudflare Tunnel** (recomendado, gratis): instala `cloudflared` en la PC destino,
  crea un tunnel que apunta a `http://localhost:8010`, y obtén una URL HTTPS.
- **Tailscale** (red privada): instala Tailscale y compartí el acceso a la PC.
- **Nginx/Caddy como reverse proxy** con Let's Encrypt (más complejo).

### Troubleshooting

| Problema | Solución |
|----------|----------|
| `docker: command not found` | Instala Docker Desktop y reinicia |
| `Cannot connect to Ollama` | Verifica que Ollama corre: `curl http://localhost:11434/api/tags` |
| `qwen2.5:7b not found` | Ejecuta: `ollama pull qwen2.5:7b` |
| Build muy lento | Limpia cache: `docker builder prune`. Usa `--platform` para build nativo. |
| Imagen muy grande (~3.5 GB) | Normal: incluye Python + torch + modelo embeddings pre-cargado |
| Contenedor reinicia en bucle | `.\setup.ps1 logs` para ver el error |

---

## 🔧 Parte 2 — Documentación técnica

### Arquitectura del servicio

```
Pregunta del usuario
   │
   ▼
detect_president()         ← identifica de qué presidente trata la pregunta
   │
   ▼
retrieve(pregunta, presidente)              ← CAPA 1: dataset local
   │   ChromaDB: filtra where={presidente}  ANTES de la similitud semántica
   │   → elimina la mezcla de contexto entre presidentes
   ▼
¿Recuperación local débil?
   │   NO → usar solo local
   │   SÍ ↓
research_for_chat(...)                       ← CAPA 2: Wikipedia ES (opcional)
   │   Trigger conservador: 0 chunks, dist>0.5, sin presidente,
   │   o disparador explícito ("según fuentes externas")
   │   NO se menciona la fuente al usuario
   ▼
Contexto etiquetado [Presidente — Sección] + [Wikipedia - título]
   │
   ▼
Ollama (qwen2.5:7b)        ← prompt impersonador + anti-alucinación, temp 0.35
   │
   ▼
Respuesta en 1ª persona + fuentes (locales + externas para trazabilidad)
```

### Stack

| Componente | Tecnología |
|------------|-----------|
| API web | FastAPI + Uvicorn |
| Embeddings | `intfloat/multilingual-e5-base` (Sentence-Transformers, GPU) |
| Vector DB | **ChromaDB** (persistente, filtrado por metadata) |
| LLM | **qwen2.5:7b** vía Ollama |
| Frontend demo | Jinja2 + `templates/index.html` |

### Estructura de archivos

```
app.py                    Endpoints FastAPI (/chat, /health, /)
utils.py                  Núcleo RAG: carga, chunking, embeddings, retrieve
research_tool.py          Capa 2: research con Wikipedia ES (trigger conservador)
generate_embeddings.py    (Re)indexa el dataset en ChromaDB
presidentes_ecuador.json  Dataset histórico (JSONL: 74 presidentes)
templates/index.html      Interfaz web de demostración
test_rag.py               Pruebas de carga, chunking, detección y aislamiento
test_research.py          Pruebas de la capa 2 (research) con mocks
test_chat.py              Prueba funcional end-to-end del flujo de chat
chroma_db/                Índice vectorial persistente (regenerable)
requirements.txt          Dependencias Python
```

### Instalación manual (entorno virtual)

```powershell
python -m venv .venv
.\.venv\Scripts\activate
pip install -r requirements.txt
# GPU NVIDIA (RTX 40xx/50xx): instalar torch con CUDA
pip install --force-reinstall torch --index-url https://download.pytorch.org/whl/cu128
python generate_embeddings.py        # indexa los 74 presidentes (~2147 chunks)
uvicorn app:app --reload --port 8010
```

### Configuración por variables de entorno

El servicio está diseñado para el despliegue distribuido de *Opción 2049*, donde
**Ollama corre en el Nodo de IA (GPU)**, no en la misma máquina.

| Variable | Por defecto | Descripción |
|----------|-------------|-------------|
| `OLLAMA_HOST` | `http://localhost:11434` | Host del Nodo de IA donde corre Ollama |
| `OLLAMA_MODEL` | `qwen2.5:7b` | Modelo a usar (debe estar `pull`-eado en ese nodo) |
| `RAG_TOP_K` | `5` | Nº de chunks recuperados por consulta |
| `CORS_ORIGINS` | `*` | Orígenes permitidos (ej. URL del frontend Next.js), separados por coma |

Ejemplo apuntando al Nodo de IA:
```powershell
$env:OLLAMA_HOST="http://10.147.0.20:11434"
$env:CORS_ORIGINS="https://opcion2049.example"
uvicorn app:app --host 0.0.0.0 --port 8010
```

### Contrato de la API

**`POST /chat`**
```json
// Request
{ "prompt": "Eloy Alfaro, cuéntame de tu obra pública" }

// Response
{
  "response": "Hermano mío, te hablo con la voz...",
  "presidente": "Eloy Alfaro Delgado",
  "fuentes": [
    { "presidente": "Eloy Alfaro Delgado", "seccion": "Obra pública" }
  ]
}
```

**`GET /health`** → estado del servicio, nº de presidentes, modelo y host de Ollama.

### Pruebas

```powershell
.\.venv\Scripts\python.exe test_rag.py     # aislamiento, detección, chunking
.\.venv\Scripts\python.exe test_research.py # capa 2 (research) - mocks, sin red
.\.venv\Scripts\python.exe test_chat.py    # flujo completo (requiere Ollama)
```

### Capa 2: research con Wikipedia

Cuando el retrieval local es débil (0 chunks relevantes, distancia promedio
> 0.5, no se detecta presidente, o el usuario pide "según fuentes externas"),
el sistema complementa el contexto con un extracto de Wikipedia ES.

**Reglas de diseño**:
- Trigger conservador: pocas requests, solo cuando el local es claramente insuficiente.
- El extracto se etiqueta como `[Wikipedia - título]` en el contexto, pero el
  LLM lo integra a la voz del presidente **sin mencionar la fuente al usuario**.
- Si Wikipedia no responde (timeout, red caída, sin página), `research_for_chat()`
  devuelve vacío y el chat sigue funcionando solo con el retrieval local.
- Cache LRU en RAM (TTL 1h) para evitar requests repetidos en preguntas comunes.

### Compatibilidad con la arquitectura *Opción 2049*

Este servicio cumple el rol de **"Sistema RAG"** descrito en la arquitectura del
proyecto: procesa la matriz histórica `.json`, genera embeddings semánticos y
responde consultas del público sobre presidentes del Ecuador. Es consumible por
la Web App (Next.js) y el Worker vía HTTP (CORS + host configurable).

**Mejoras técnicas respecto al diseño original** (documentadas para el equipo):

| Diseño original | Implementación actual | Motivo |
|-----------------|----------------------|--------|
| FAISS (índice plano) | **ChromaDB** | Filtrado por metadata → aísla chunks por presidente (evita mezcla) |
| Llama 3.2 | **qwen2.5:7b** | Mejor español y seguimiento de instrucciones |
| Embeddings genéricos | **multilingual-e5-base** | Optimizado para español |

> Si el despliegue exige FAISS o Llama 3.2 por restricciones del nodo, el diseño
> es intercambiable: `utils.py` aísla la capa de vector DB y `OLLAMA_MODEL` permite
> volver a Llama. La mejora clave (filtrado por presidente) es la que resuelve el
> bug de mezcla y debe conservarse.
