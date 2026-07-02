# syntax=docker/dockerfile:1.6
# =============================================================================
# RAG Presidentes Ecuador - Dockerfile
# Multi-stage, multi-arch (linux/amd64 + linux/arm64), con ChromaDB precomputado.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: builder
# - Instala deps Python
# - Pre-carga el modelo de embeddings (multilingual-e5-base)
# - Genera el indice ChromaDB en build-time (queda "baked" en la imagen)
# -----------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM python:3.11-slim AS builder

WORKDIR /app

# Deps del sistema necesarias para compilar algunas wheels (torch, chromadb).
# Solo se usan en este stage; el runtime es mas liviano.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
    && rm -rf /var/lib/apt/lists/*

# Instalar dependencias Python (cache de layer: solo se reinstala si cambia requirements.txt)
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# Pre-cargar el modelo de embeddings (~1 GB) en el cache de HuggingFace.
# Esto evita que el modelo se descargue en cada arranque del contenedor.
RUN python -c "from sentence_transformers import SentenceTransformer; \
    SentenceTransformer('intfloat/multilingual-e5-base')"

# NOTA: el indice ChromaDB NO se genera aqui. Se genera localmente (en GPU,
# ~minutos vs ~14 min en CPU emulada) con `python generate_embeddings.py` y se
# hornea por COPY en el runtime stage. Los vectores son identicos vengan de
# GPU o CPU. Trade-off: el build depende del chroma_db/ local del maintainer
# (menos reproducible). Para regenerar reproducible-en-build, restaurar el
# `RUN generate_embeddings.py` que estaba aqui.
# ponytail: bake local chroma_db; volver a generar-en-build si se pierde el artefacto local

# -----------------------------------------------------------------------------
# Stage 2: runtime
# - Imagen slim sin compiladores
# - Copia deps Python + cache del modelo + chroma_db precomputado + codigo
# - Tamaño objetivo: ~3 GB
# -----------------------------------------------------------------------------
FROM python:3.11-slim

LABEL maintainer="RAG Presidentes Ecuador Team" \
      version="1.0.0" \
      description="Microservicio RAG que impersona presidentes del Ecuador"

WORKDIR /app

# Deps runtime minimas para torch/chromadb (libgomp para paralelismo, curl para healthcheck)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Copiar dependencias Python instaladas en el builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Copiar cache del modelo de embeddings (HuggingFace)
# Sin esto, el primer request tardaria minutos en descargar el modelo
COPY --from=builder /root/.cache/huggingface /root/.cache/huggingface

# Copiar el ChromaDB precomputado LOCALMENTE (generado en GPU, ver builder stage).
# Se hornea desde el contexto de build, no desde el builder.
COPY chroma_db ./chroma_db

# Copiar codigo de la aplicacion
COPY app.py .
COPY utils.py .
COPY research_tool.py .
COPY generate_embeddings.py .
COPY presidentes_ecuador.json .
COPY templates/ ./templates/

# Copiar entrypoint y asegurar LF + permisos de ejecucion (CRLF rompe en Linux)
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh \
    && chmod +x /entrypoint.sh \
    && echo "[OK] entrypoint.sh listo"

# Puerto del servicio
EXPOSE 8010

# Forzar stdout sin buffer: los logs de uvicorn, healthcheck y errores
# se ven en tiempo real con `docker logs` (sin esto, puede haber silencio
# de varios segundos entre eventos).
ENV PYTHONUNBUFFERED=1

# Healthcheck: el contenedor se considera sano si /health responde 200
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://localhost:8010/health || exit 1

# Arrancar via entrypoint (verifica chroma_db y ollama antes de levantar uvicorn)
ENTRYPOINT ["/entrypoint.sh"]
