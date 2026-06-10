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

1. Asegúrate de tener **[Ollama](https://ollama.com)** instalado y corriendo, con
   el modelo descargado:
   ```
   ollama pull qwen2.5:7b
   ```
2. Doble clic en **`iniciar_rag.bat`** (o `lanzar_rag_desde_cmd.bat` si no usas
   PowerShell). La primera vez creará el entorno e indexará los datos.
3. Abre tu navegador en **http://localhost:8010**

> La primera ejecución descarga el modelo de embeddings (~1 GB) y genera el
> índice. Las siguientes son inmediatas.

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
