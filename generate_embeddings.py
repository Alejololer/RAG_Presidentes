"""
(Re)genera el índice vectorial en ChromaDB desde el dataset de presidentes.

Ejecutar tras cambiar el dataset, el modelo de embeddings o la estrategia de chunking:
    python generate_embeddings.py
"""

import time

from utils import load_records, build_chunks, embed_and_store

t0 = time.time()
print(f"[1/3] Cargando dataset...", flush=True)
records = load_records()
print(f"      Cargados {len(records)} presidentes desde el JSONL.", flush=True)

print(f"[2/3] Construyendo chunks...", flush=True)
chunks = build_chunks(records)
print(f"      Generados {len(chunks)} chunks (1 por presidente x seccion, sub-dividiendo largos).", flush=True)

print(f"[3/3] Generando embeddings + indexando en ChromaDB...", flush=True)
n = embed_and_store(chunks)
elapsed = time.time() - t0
print(f"[OK] Indexados {n} chunks de {len(records)} presidentes en ChromaDB.", flush=True)
print(f"[OK] Tiempo total: {elapsed:.1f}s", flush=True)
