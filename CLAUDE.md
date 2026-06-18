# CLAUDE.md — Servicio RAG Presidentes del Ecuador

Microservicio RAG que responde consultas **impersonando a presidentes del Ecuador**
en 1ª persona, usando solo un archivo histórico curado. Es el "Sistema RAG" del
ecosistema transmedia **Opción 2049** (ver `Arquitectura y funcionamiento de la
página web.pdf`).

## Comandos

### Opción A — Setup con Docker (recomendado para producción)
```powershell
# Windows (PowerShell)
.\setup.ps1                    # Menu interactivo (10 opciones)
.\setup.ps1 setup              # Setup completo (build + start + health)
.\setup.ps1 start              # Solo iniciar
.\setup.ps1 logs               # Ver logs
.\setup.ps1 --help             # Mas opciones
```

```bash
# macOS / Linux / Git Bash
./setup.sh                     # Menu interactivo
./setup.sh setup               # Setup completo
./setup.sh --help              # Mas opciones
```

### Opción B — Desarrollo local sin Docker
```powershell
# Entorno (venv obligatorio — NO instalar en Python global)
.\.venv\Scripts\activate

# (Re)indexar dataset en ChromaDB
.\.venv\Scripts\python.exe generate_embeddings.py

# Levantar servicio
.\.venv\Scripts\python.exe -m uvicorn app:app --reload --port 8010

# Pruebas
.\.venv\Scripts\python.exe test_rag.py      # aislamiento/detección/chunking
.\.venv\Scripts\python.exe test_research.py # capa 2 (research/Wikipedia)
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
- **`research_tool.py`** — **Capa 2 (research)**: complementa el retrieval local con extractos de Wikipedia ES cuando el dataset local es débil. Trigger conservador (pocas requests). NO se menciona la fuente al usuario (decisión de diseño). Cache LRU en RAM (TTL 1h) y timeout 5s para no degradar el chat si Wikipedia cae.
  - `should_research()` — dispara solo si: (a) no se detecta presidente, (b) 0 chunks locales, (c) distancia promedio > 0.5, o (d) pregunta contiene disparador explícito ("según fuentes externas", etc.).
  - `wikipedia_search()` — busca en `https://es.wikipedia.org/w/api.php` (action=query, list=search, prop=extracts con exintro).
  - `_extract_relevant()` — filtra extractos que no mencionan al presidente (evita contaminar con info de otros mandatarios).
- **`app.py`** — FastAPI. Endpoints: `POST /chat`, `GET /health`, `GET /` (demo HTML). Prompt impersonador + anti-alucinación. Config por env vars. Integra `research_for_chat()` después de `retrieve()` y devuelve `fuentes_externas` en la respuesta (trazabilidad interna, NO visible al usuario).
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
- **Research tool degrada con gracia**: si Wikipedia ES no responde (timeout, red caída, sin página para el presidente), `research_for_chat()` devuelve `("", [])` y el chat sigue funcionando solo con el retrieval local. Verificado en `test_research.py::test_returns_empty_on_network_failure`.
- **Tests con mocks**: `test_research.py` mockea `requests` con `unittest.mock.patch` para evitar dependencia de red real. Esto permite correr la suite completa offline, pero en CI conviene también un test "live" opcional contra Wikipedia (gated por una env var tipo `LIVE_WIKI=1`).

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

## Empaquetado y distribución

- **`Dockerfile`** multi-stage: builder genera ChromaDB precomputado, runtime lo copia. Multi-arch (`linux/amd64` + `linux/arm64`).
- **`docker-compose.yml`** lee de `.env` (creado desde `.env.example` por el setup script). Usa `image: juanprof/rag-presidentes:1.0.0` del registry publico + `build:` local como fallback.
- **`rag.bat`** (Windows): entry point con menu de 10 opciones. Doble clic para abrir menu. Todas las opciones delegan a `setup.ps1`.
- **`setup.ps1`** (Windows, motor del .bat) y **`setup.sh`** (macOS/Linux): menu interactivo con 10 opciones + modo `--auto` + flag `--gpu` + `--platform` + `--dry-run`.
- **`publish.sh`** (macOS/Linux) y **`publish.ps1`** (Windows): build multi-arch + push a Docker Hub (`juanprof/rag-presidentes`). Sin CI/CD, manual. Flags equivalentes: `--version` / `-Version`, `--no-push` / `-NoPush`, `--dry-run` / `-DryRun`.
- **Flujo en PC destino**: la primera vez `start` hace `docker compose pull` automaticamente desde Docker Hub (~1 GB). Las siguientes veces es instantáneo. Si la imagen no esta en el registry (caso dev pre-release), hace build local como fallback.
- **Linux gotcha**: `host.docker.internal` no funciona en el bridge de Docker en Linux. El setup script configura `USE_HOST_NETWORK=host` automaticamente para que el contenedor use la red del host.
- **HTTPS**: el contenedor expone HTTP plano. Para acceso desde internet usar Cloudflare Tunnel, Tailscale, o un reverse proxy externo. NO se incluye TLS en la imagen (agrega complejidad sin beneficio si ya hay proxy).
- **Legacy**: `legacy/` contiene los scripts pre-Docker (`iniciar_rag.bat`, `lanzar_rag_desde_cmd.bat`) deprecados pero conservados como referencia historica.
