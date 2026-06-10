#!/bin/sh
# =============================================================================
# RAG Presidentes Ecuador - entrypoint del contenedor
# Se ejecuta al iniciar el contenedor. Verifica:
#   1. Que chroma_db exista (precomputado en la imagen, pero por si acaso)
#   2. Que Ollama sea accesible (warn-only, no bloqueante)
#   3. Arranca uvicorn
# =============================================================================

set -e

echo "=========================================="
echo "  RAG Presidentes Ecuador - Iniciando"
echo "=========================================="

# -----------------------------------------------------------------------------
# 1) Verificar ChromaDB
# -----------------------------------------------------------------------------
if [ ! -d "chroma_db" ] || [ -z "$(ls -A chroma_db 2>/dev/null)" ]; then
    echo "[WARN] chroma_db no encontrado, regenerando (tarda 1-3 min)..."
    python generate_embeddings.py
else
    echo "[OK] chroma_db presente (precomputado en la imagen)"
fi

# -----------------------------------------------------------------------------
# 2) Verificar Ollama (no bloqueante: degrada con gracia)
# -----------------------------------------------------------------------------
if [ -n "$OLLAMA_HOST" ]; then
    echo "[INFO] OLLAMA_HOST=$OLLAMA_HOST"
    if curl -s --max-time 3 -f "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then
        echo "[OK] Ollama accesible"
        # Check que el modelo este descargado
        if curl -s --max-time 3 "$OLLAMA_HOST/api/tags" | grep -q "$OLLAMA_MODEL"; then
            echo "[OK] Modelo $OLLAMA_MODEL disponible"
        else
            echo "[WARN] Modelo $OLLAMA_MODEL NO encontrado en Ollama. Ejecuta: ollama pull $OLLAMA_MODEL"
        fi
    else
        echo "[WARN] Ollama no accesible en $OLLAMA_HOST"
        echo "[WARN] El retrieval funcionara, pero el LLM no respondera hasta que Ollama este disponible."
    fi
else
    echo "[WARN] OLLAMA_HOST no configurado"
fi

# -----------------------------------------------------------------------------
# 3) Arrancar uvicorn
# -----------------------------------------------------------------------------
echo ""
echo "[INFO] Arrancando uvicorn en 0.0.0.0:8010 ..."
exec uvicorn app:app --host 0.0.0.0 --port 8010 --workers 1
