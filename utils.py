import json
import faiss
import numpy as np
from sentence_transformers import SentenceTransformer
import os
import pickle

INDEX_PATH = "faiss_index.bin"
DOCS_PATH = "docs.pkl"
MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
model = SentenceTransformer(MODEL_NAME)

def build_documents_from_json(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)

    docs = []
    for item in data:
        texto = (
            f"Nombre: {item['nombre']}\n"
            f"Periodo: {item['periodo']}\n"
            f"Tipo de mandato: {item['tipo_mandato']}\n"
            f"Partido: {item['partido']}\n"
            f"Logros: {item['logros']}"
        )
        docs.append(texto)
    return docs

def embed_and_store(docs):
    embeddings = model.encode(docs, show_progress_bar=True)
    dim = embeddings.shape[1]
    index = faiss.IndexFlatL2(dim)
    index.add(np.array(embeddings).astype("float32"))
    faiss.write_index(index, INDEX_PATH)
    with open(DOCS_PATH, "wb") as f:
        pickle.dump(docs, f)

def query_docs(question, top_k=3):
    if not os.path.exists(INDEX_PATH) or not os.path.exists(DOCS_PATH):
        return []
    index = faiss.read_index(INDEX_PATH)
    with open(DOCS_PATH, "rb") as f:
        docs = pickle.load(f)
    emb = model.encode([question])
    D, I = index.search(np.array(emb).astype("float32"), top_k)
    return [docs[i] for i in I[0] if i < len(docs)]
