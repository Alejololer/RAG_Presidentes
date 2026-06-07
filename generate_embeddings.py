"""
(Re)genera el índice vectorial en ChromaDB desde el dataset de presidentes.

Ejecutar tras cambiar el dataset, el modelo de embeddings o la estrategia de chunking:
    python generate_embeddings.py
"""

from utils import load_records, build_chunks, embed_and_store

records = load_records()
print(f"Cargados {len(records)} presidentes desde el JSONL.")

chunks = build_chunks(records)
print(f"Generados {len(chunks)} chunks (1 por presidente x sección, sub-dividiendo largos).")

n = embed_and_store(chunks)
print(f"[OK] Indexados {n} chunks de {len(records)} presidentes en ChromaDB.")
