# CLAUDE.md — Servicio RAG Presidentes del Ecuador

Microservicio RAG que responde consultas **impersonando a presidentes del Ecuador**
en 1ª persona, usando solo un archivo histórico curado. Es el "Sistema RAG" del
ecosistema transmedia **Opción 2049** (ver `Arquitectura y funcionamiento de la
página web.pdf`).

## Comandos

```powershell
# Entorno (venv obligatorio — NO instalar en Python global)
.\.venv\Scripts\activate

# (Re)indexar dataset en ChromaDB
.\.venv\Scripts\python.exe generate_embeddings.py

# Levantar servicio
.\.venv\Scripts\python.exe -m uvicorn app:app --reload --port 8010

# Pruebas
.\.venv\Scripts\python.exe test_rag.py      # aislamiento/detección/chunking
.\.venv\Scripts\python.exe test_chat.py     # flujo end-to-end (requiere Ollama)
```

Requiere **Ollama** corriendo con `qwen2.5:7b` (`ollama pull qwen2.5:7b`).

## Arquitectura del código

- **`utils.py`** — núcleo RAG (toda la lógica vive aquí):
  - `load_records()` — carga **JSONL** (no `json.load`: el archivo es un objeto por línea).
  - `build_chunks()` — **1 chunk = 1 presidente × 1 sección** (chunking semántico estructural); sub-divide secciones largas. Produce ~2147 chunks.
  - `embed_and_store()` — embeddings e5 + ChromaDB (colección `presidentes`, distancia coseno).
  - `detect_president()` — identifica el presidente de la pregunta (match de tokens normalizados).
  - `retrieve()` — **filtra por `where={presidente}` ANTES de la similitud** + umbral de distancia. Esto es lo que evita la mezcla de presidentes.
- **`app.py`** — FastAPI. Endpoints: `POST /chat`, `GET /health`, `GET /` (demo HTML). Prompt impersonador + anti-alucinación. Config por env vars.
- **`generate_embeddings.py`** — script de (re)indexado.

## Convenciones / decisiones (con su porqué)

- **Vector DB: ChromaDB**, no FAISS. FAISS plano no soporta filtrado por metadata, que es justo lo que arregla el bug de mezcla de chunks entre presidentes.
- **LLM: qwen2.5:7b** vía Ollama (no Llama 3.2). Mejor español y seguimiento de instrucciones. Configurable con `OLLAMA_MODEL`.
- **Embeddings: `intfloat/multilingual-e5-base`**. Requiere prefijos **`query:`** (consultas) y **`passage:`** (documentos) — omitirlos degrada la calidad. Ya está manejado en `utils.py`.
- **Anti-alucinación estricta**: el system prompt obliga a usar SOLO el contexto; sin fallback al conocimiento del modelo. `temperature=0.35`.
- **Impersonación**: responde en 1ª persona como el presidente detectado; voz de guía neutral si no se detecta ninguno.

## Gotchas (importante)

- **El dataset `presidentes_ecuador.json` es JSONL** (un JSON por línea), NO un array JSON. Usar `load_records()`, nunca `json.load()`.
- **Las claves del JSON tienen tildes, espacios y mojibake potencial.** El mapeo de secciones en `utils.py` (`SECTION_SLUGS`) usa match por subcadena normalizada (sin tildes) — robusto a esos problemas. Si cambia el dataset, verificar que `test_rag.py` reporte "Claves NO mapeadas: NINGUNA".
- **GPU NVIDIA**: `sentence-transformers` instala **torch CPU** por defecto. Para GPU (RTX 50xx/Blackwell) hay que reinstalar torch desde el índice CUDA cu128 (ver README). `get_model()` selecciona `cuda` si está disponible.
- **Consola Windows (cp1252)**: no imprimir emojis en scripts (`✅` rompe con `UnicodeEncodeError`). Para ejecutar usar `$env:PYTHONIOENCODING="utf-8"`.
- **`chroma_db/` es regenerable** — está en `.gitignore`. Si se corrompe, borrar y re-ejecutar `generate_embeddings.py`.
- **Datos sucios conocidos**: 3 registros tenían el campo `Nombre` contaminado con texto desbordado de otra sección (Bucaram, Enríquez Gallo, Mancheno). `load_records()` los limpia cortando en el primer bloque de 2+ espacios o salto de línea. Si añades datos, revisa que `test_rag.py` siga en "DETECCIÓN: TODO OK".
- **Tokenización en `detect_president`**: usar `re.findall(r"\w+", ...)`, no `.split()`, para que la puntuación pegada (p. ej. "Moreno,") no rompa el match con el token del nombre.

## Compatibilidad Opción 2049

Despliegue distribuido: Ollama vive en el **Nodo de IA (GPU)**, no en localhost.
Config por env vars: `OLLAMA_HOST`, `OLLAMA_MODEL`, `RAG_TOP_K`, `CORS_ORIGINS`.
El servicio es consumible por la Web App (Next.js) y el Worker vía HTTP (CORS activo).

## Estado / historial

Reescritura completa (jun 2026) que resolvió los bugs originales:
- Índice FAISS desactualizado (dataset viejo de 55 regs) → ChromaDB con 74 presidentes.
- Mezcla de chunks entre presidentes → filtrado por metadata.
- Fallback al conocimiento del modelo → anti-alucinación estricta.
- Mismatch código↔datos (claves inexistentes) → carga JSONL robusta.
- Artefactos obsoletos `faiss_index.bin` y `docs.pkl` eliminados.
