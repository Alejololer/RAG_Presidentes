"""
Núcleo del RAG de Presidentes del Ecuador.

Pipeline:
  load_records()    -> carga el JSONL y normaliza claves (nombre + 13 secciones)
  build_chunks()    -> 1 chunk por (presidente x sección), sub-dividiendo secciones largas
  embed_and_store() -> embeddings multilingües (e5) + ChromaDB con metadata por presidente
  detect_president()-> identifica de qué presidente trata la pregunta
  retrieve()        -> búsqueda semántica filtrada por presidente (evita mezcla de contexto)
"""

import json
import os
import re
import unicodedata

import chromadb
from sentence_transformers import SentenceTransformer

# --- Configuración --------------------------------------------------------

DATA_PATH = "presidentes_ecuador.json"
CHROMA_PATH = "chroma_db"
COLLECTION_NAME = "presidentes"
MODEL_NAME = "intfloat/multilingual-e5-base"

# Límite aproximado de palabras por chunk antes de sub-dividir una sección larga.
MAX_WORDS_PER_CHUNK = 350
CHUNK_OVERLAP_WORDS = 40

# Umbral de distancia (coseno). Resultados por encima se descartan como irrelevantes.
# Calibrable; con e5 normalizado, distancias < ~0.30 suelen ser muy relevantes.
DISTANCE_THRESHOLD = 0.55

# Mapa de secciones: (substrings a buscar en la clave) -> slug estable.
# Se hace por subcadena sobre la clave normalizada (sin tildes, minúsculas) para
# ser robusto a problemas de codificación, espacios extra y variaciones menores.
SECTION_SLUGS = [
    (("periodos de actuacion", "periodos presidenciales"), "periodos_politicos"),
    (("datos demograficos",), "datos_demograficos"),
    (("capital global",), "capital_global"),
    (("redes y vinculaciones",), "redes_sociales"),
    (("posicionamiento politico", "posicionamiento politico-ideolog"), "posicionamiento_ideologico"),
    (("legislacion",), "legislacion"),
    (("obra publica",), "obra_publica"),
    (("manejo de los bienes",), "bienes_comunes"),
    (("posicionamiento con los derechos humanos", "derechos humanos"), "derechos_humanos"),
    (("relaciones politicas en el plano",), "relaciones_internacionales"),
    (("marcas de oratoria",), "oratoria"),
    (("imaginarios sobre el personaje",), "imaginarios"),
    (("fuentes bibliograficas",), "fuentes"),
]

# Etiquetas legibles por slug (para construir el contexto que ve la LLM).
SECTION_LABELS = {
    "periodos_politicos": "Períodos de actuación política",
    "datos_demograficos": "Datos demográficos",
    "capital_global": "Capital global (formación, familia)",
    "redes_sociales": "Redes y vinculaciones sociales",
    "posicionamiento_ideologico": "Posicionamiento político-ideológico",
    "legislacion": "Legislación expedida o fomentada",
    "obra_publica": "Obra pública",
    "bienes_comunes": "Manejo de los bienes comunes",
    "derechos_humanos": "Posicionamiento en derechos humanos",
    "relaciones_internacionales": "Relaciones políticas regionales y globales",
    "oratoria": "Marcas de oratoria",
    "imaginarios": "Imaginarios sobre el personaje",
    "fuentes": "Fuentes bibliográficas",
}

# --- Modelo de embeddings (carga perezosa singleton) ----------------------

_model = None


def get_model():
    global _model
    if _model is None:
        import torch
        device = "cuda" if torch.cuda.is_available() else "cpu"
        _model = SentenceTransformer(MODEL_NAME, device=device)
    return _model


# --- Utilidades de texto --------------------------------------------------

def _strip_accents(text):
    nfkd = unicodedata.normalize("NFKD", text)
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def _normalize(text):
    """minúsculas, sin tildes, espacios colapsados — para matching robusto."""
    return re.sub(r"\s+", " ", _strip_accents(text).lower()).strip()


def _slug(text):
    base = _normalize(text)
    return re.sub(r"[^a-z0-9]+", "_", base).strip("_")


def _key_to_slug(key):
    """Devuelve el slug de sección para una clave del JSON, o None si es el nombre/desconocida."""
    nk = _normalize(key)
    if nk.startswith("nombre"):
        return None
    for substrings, slug in SECTION_SLUGS:
        if any(s in nk for s in substrings):
            return slug
    return None


# --- Carga de datos -------------------------------------------------------

def load_records(path=DATA_PATH):
    """
    Carga el archivo JSONL (un objeto JSON por línea) de forma robusta.
    Devuelve lista de dicts: {"nombre": str, "secciones": {slug: texto, ...}}.
    """
    records = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)

            nombre = None
            secciones = {}
            for key, value in item.items():
                if _normalize(key).startswith("nombre"):
                    # Algunos registros tienen el campo Nombre contaminado con texto
                    # desbordado de otra sección (separado por 2+ espacios o salto de
                    # línea). Tomamos solo el nombre real (primer segmento limpio).
                    nombre = re.split(r"\s{2,}|\n", str(value).strip())[0].strip()
                    continue
                slug = _key_to_slug(key)
                if slug and value and str(value).strip():
                    secciones[slug] = str(value).strip()

            if nombre:
                records.append({"nombre": nombre, "secciones": secciones})
    return records


# --- Chunking estructural-semántico ---------------------------------------

def _split_long_text(text, max_words=MAX_WORDS_PER_CHUNK, overlap=CHUNK_OVERLAP_WORDS):
    """
    Sub-divide un texto largo respetando fronteras de párrafo cuando es posible,
    con un pequeño solapamiento entre fragmentos para no perder contexto.
    """
    words = text.split()
    if len(words) <= max_words:
        return [text]

    # Intentar primero por párrafos; agrupar párrafos hasta llenar el límite.
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks = []
    current = []
    current_len = 0
    for para in paragraphs:
        plen = len(para.split())
        if current_len + plen > max_words and current:
            chunks.append("\n\n".join(current))
            current = [para]
            current_len = plen
        else:
            current.append(para)
            current_len += plen
    if current:
        chunks.append("\n\n".join(current))

    # Si algún chunk por párrafos sigue siendo gigante (párrafo único enorme),
    # caer a ventanas de palabras con solapamiento.
    final = []
    for ch in chunks:
        w = ch.split()
        if len(w) <= max_words:
            final.append(ch)
            continue
        step = max_words - overlap
        for start in range(0, len(w), step):
            final.append(" ".join(w[start:start + max_words]))
            if start + max_words >= len(w):
                break
    return final


def build_chunks(records):
    """
    1 chunk por (presidente x sección). Las secciones largas se sub-dividen.
    Devuelve lista de dicts: {id, text, presidente, seccion, chunk_index}.
    El campo `text` se almacena con prefijo "passage: " requerido por los modelos e5.
    """
    chunks = []
    for rec in records:
        nombre = rec["nombre"]
        pres_slug = _slug(nombre)
        for seccion, texto in rec["secciones"].items():
            partes = _split_long_text(texto)
            for i, parte in enumerate(partes):
                label = SECTION_LABELS.get(seccion, seccion)
                # El texto embebido incluye nombre+sección para anclar semánticamente.
                cuerpo = f"{nombre} — {label}: {parte}"
                chunks.append({
                    "id": f"{pres_slug}__{seccion}__{i}",
                    "text": f"passage: {cuerpo}",
                    "presidente": nombre,
                    "seccion": seccion,
                    "chunk_index": i,
                })
    return chunks


# --- Indexado en ChromaDB -------------------------------------------------

def _get_collection(create=False):
    client = chromadb.PersistentClient(path=CHROMA_PATH)
    if create:
        # Recrear desde cero para evitar índices viejos/inconsistentes.
        try:
            client.delete_collection(COLLECTION_NAME)
        except Exception:
            pass
        # Distancia coseno: e5 funciona mejor con similitud coseno.
        return client.create_collection(
            name=COLLECTION_NAME, metadata={"hnsw:space": "cosine"}
        )
    return client.get_collection(COLLECTION_NAME)


def embed_and_store(chunks, batch_size=32, progress=True):
    """
    Embebe los chunks y los guarda en ChromaDB con metadata por presidente.

    Args:
        chunks: lista de dicts {id, text, presidente, seccion, chunk_index}.
        batch_size: chunks por lote. Default 32 (mas chico que antes para
            dar mejor feedback y menor pico de RAM).
        progress: si True, imprime progreso por batch con flush (importante
            para que el output sea visible en Docker build, donde el
            buffering de Python puede ocultar prints durante minutos).

    Returns:
        Cantidad de chunks indexados.
    """
    import sys
    import time

    model = get_model()
    collection = _get_collection(create=True)
    total = len(chunks)
    n_batches = (total + batch_size - 1) // batch_size
    start_time = time.time()

    if progress:
        print(f"  Embedding + indexado: {total} chunks en {n_batches} batches...", flush=True)

    for i, start in enumerate(range(0, total, batch_size)):
        batch = chunks[start:start + batch_size]
        texts = [c["text"] for c in batch]
        # encode() retorna numpy array en CPU; lo convertimos una sola vez
        # al final (en vez de iterar Python con tolist() por elemento).
        emb_array = model.encode(
            texts, show_progress_bar=False, normalize_embeddings=True
        )
        # .tolist() sobre el array completo es mucho mas rapido que iterar.
        embeddings = emb_array.tolist()
        collection.add(
            ids=[c["id"] for c in batch],
            documents=texts,
            embeddings=embeddings,
            metadatas=[
                {
                    "presidente": c["presidente"],
                    "seccion": c["seccion"],
                    "chunk_index": c["chunk_index"],
                }
                for c in batch
            ],
        )
        if progress:
            elapsed = time.time() - start_time
            done = min(start + batch_size, total)
            pct = 100 * done / total
            # Estimar tiempo restante
            if done > 0:
                rate = done / elapsed
                remaining = (total - done) / rate if rate > 0 else 0
                eta = f", ETA ~{remaining:.0f}s" if remaining > 1 else ""
            else:
                eta = ""
            print(
                f"  [{i + 1}/{n_batches}] {done}/{total} chunks ({pct:.0f}%) "
                f"- {elapsed:.1f}s elapsed{eta}",
                flush=True,
            )

    return collection.count()


# --- Detección de presidente ----------------------------------------------

def get_known_names(path=DATA_PATH):
    """Lista de nombres canónicos de presidentes (para detección y UI)."""
    return [r["nombre"] for r in load_records(path)]


def detect_president(question, known_names):
    """
    Identifica a qué presidente se refiere la pregunta comparando tokens del
    nombre (normalizados, sin tildes) contra la pregunta. Devuelve el nombre
    canónico o None. Ante varios candidatos, prefiere el de match más largo.
    """
    q = _normalize(question)
    # Tokenizar por palabras (\w+) para que la puntuación pegada (p. ej. "Moreno,")
    # no impida el match con el token del nombre ("moreno").
    q_tokens = set(re.findall(r"\w+", q))
    best = None
    best_score = 0
    # Apellidos/nombres muy genéricos que por sí solos no deben disparar match.
    stop = {"de", "la", "del", "los", "las", "y", "san", "santa"}

    for nombre in known_names:
        name_tokens = [t for t in re.findall(r"\w+", _normalize(nombre)) if t not in stop and len(t) > 2]
        if not name_tokens:
            continue
        # Cuenta cuántos tokens significativos del nombre aparecen en la pregunta.
        matched = [t for t in name_tokens if t in q_tokens]
        score = len(matched)
        # Bonus si coincide el nombre completo como subcadena.
        if _normalize(nombre) in q:
            score += 10
        if score > best_score:
            best_score = score
            best = nombre

    # Exigir al menos un token significativo coincidente.
    return best if best_score >= 1 else None


# --- Recuperación ---------------------------------------------------------

def retrieve(question, president=None, top_k=5, threshold=DISTANCE_THRESHOLD):
    """
    Recupera los chunks más relevantes. Si se indica `president`, restringe la
    búsqueda a ese presidente (filtro de metadata) ANTES de la similitud, lo que
    elimina la mezcla de contexto entre presidentes.

    Devuelve lista de dicts: {text, presidente, seccion, distance}.
    Filtra resultados cuya distancia supere `threshold` (irrelevantes).
    """
    try:
        collection = _get_collection(create=False)
    except Exception:
        return []

    model = get_model()
    q_emb = model.encode(
        [f"query: {question}"], normalize_embeddings=True
    ).tolist()

    where = {"presidente": president} if president else None
    res = collection.query(
        query_embeddings=q_emb,
        n_results=top_k,
        where=where,
        include=["documents", "metadatas", "distances"],
    )

    docs = res.get("documents", [[]])[0]
    metas = res.get("metadatas", [[]])[0]
    dists = res.get("distances", [[]])[0]

    out = []
    for doc, meta, dist in zip(docs, metas, dists):
        if dist is not None and dist > threshold:
            continue
        # Quitar el prefijo "passage: " que se usó solo para el embedding.
        clean = doc[len("passage: "):] if doc.startswith("passage: ") else doc
        out.append({
            "text": clean,
            "presidente": meta.get("presidente"),
            "seccion": meta.get("seccion"),
            "distance": dist,
        })
    return out
