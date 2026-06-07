from utils import build_documents_from_json, embed_and_store

docs = build_documents_from_json("presidentes_ecuador.json")
embed_and_store(docs)

print("✅ FAISS index generado desde JSON.")
