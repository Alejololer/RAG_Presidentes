"""
Capa 2 del RAG: tool de research con Wikipedia ES.

Cuando el retrieval local es insuficiente (0 chunks relevantes, distancias altas,
o no se detecta presidente), complementamos con un extracto de Wikipedia ES.
Esto preserva la voz del presidente y la regla anti-alucinacion: el extracto
se integra en el prompt como contexto adicional etiquetado, y el LLM decide
como sintetizarlo.

Diseno:
  - Trigger conservador (pocas requests): solo dispara en 3 casos claros.
  - Cache LRU en memoria con TTL 1h para no repetir queries.
  - Timeout 5s en la API: si Wikipedia cae, el chat sigue funcionando.
  - Filtro de relevancia por presidente: extractos que no lo mencionan se
    descartan (evita contaminar el contexto con info de otros mandatarios).
  - NO se menciona la fuente al usuario (decision explicita del equipo).
"""

import re
import time
from functools import lru_cache
from typing import Optional

import requests

WIKI_API_ES = "https://es.wikipedia.org/w/api.php"
USER_AGENT = "RAG-Presidentes-Ecuador/1.0 (educational project)"
DEFAULT_TIMEOUT = 5  # segundos
CACHE_TTL_SECONDS = 3600  # 1 hora
MAX_RESULTS = 3
MAX_WORDS_PER_RESULT = 250  # cota por extracto para no diluir el contexto local
MIN_CHARS_PER_EXTRACT = 80  # descarta extractos vacios o stubs


# --- Cache LRU simple con TTL -------------------------------------------

_cache: dict[str, tuple[float, list[dict]]] = {}


def _cache_get(key: str) -> Optional[list[dict]]:
    if key in _cache:
        ts, value = _cache[key]
        if time.time() - ts < CACHE_TTL_SECONDS:
            return value
        del _cache[key]
    return None


def _cache_set(key: str, value: list[dict]) -> None:
    _cache[key] = (time.time(), value)


# --- Trigger: cuando disparar research -----------------------------------

# Umbral de "recuperacion local debil". Si la distancia promedio del top-k es
# mayor a esto, el retrieval no encontro nada solido.
WEAK_AVG_DISTANCE_THRESHOLD = 0.50

# Senales explicitas en la pregunta que justifican ir a Wikipedia.
_EXTERNAL_TRIGGERS = (
    "segun fuentes externas",
    "segun fuentes",
    "historicamente",
    "en el contexto mundial",
    "a nivel internacional",
    "comparado con",
    "en el ambito global",
)


def should_research(
    local_chunks: list[dict],
    question: str,
    president: Optional[str],
) -> bool:
    """
    Decide si vale la pena complementar con Wikipedia.

    Disparo conservador: solo si se cumple al menos una de estas:
      1. No se detecto presidente (pregunta general, sin filtro de metadata).
      2. Retrieval local devolvio 0 chunks.
      3. Distancia promedio del top-k local > WEAK_AVG_DISTANCE_THRESHOLD.
      4. La pregunta contiene un disparador explicito de contexto externo.
    """
    # Caso 1: pregunta sin presidente identificado -> vista general.
    if not president:
        return True

    # Caso 2: retrieval vacio.
    if not local_chunks:
        return True

    # Caso 3: distancia promedio alta -> datos locales debiles.
    distances = [c.get("distance") for c in local_chunks if c.get("distance") is not None]
    if distances and (sum(distances) / len(distances)) > WEAK_AVG_DISTANCE_THRESHOLD:
        return True

    # Caso 4: disparador explicito del usuario.
    q_low = question.lower()
    if any(trigger in q_low for trigger in _EXTERNAL_TRIGGERS):
        return True

    return False


# --- Llamada a Wikipedia ES ---------------------------------------------

def _wiki_search_titles(query: str, limit: int = MAX_RESULTS) -> list[dict]:
    """Devuelve [{title, pageid}, ...] para la busqueda."""
    try:
        r = requests.get(
            WIKI_API_ES,
            params={
                "action": "query",
                "list": "search",
                "srsearch": query,
                "srlimit": str(limit),
                "format": "json",
                "utf8": 1,
                "origin": "*",
            },
            headers={"User-Agent": USER_AGENT},
            timeout=DEFAULT_TIMEOUT,
        )
        r.raise_for_status()
        data = r.json()
        hits = data.get("query", {}).get("search", [])
        return [{"title": h["title"], "pageid": h["pageid"]} for h in hits]
    except Exception:
        return []


def _wiki_extracts(pageids: list[int]) -> dict[int, str]:
    """Devuelve {pageid: extract_plain_text} para los pageids dados."""
    if not pageids:
        return {}
    try:
        r = requests.get(
            WIKI_API_ES,
            params={
                "action": "query",
                "prop": "extracts",
                "exintro": 1,           # solo el resumen introductorio
                "explaintext": 1,       # texto plano, no HTML
                "pageids": "|".join(str(p) for p in pageids),
                "format": "json",
                "utf8": 1,
                "origin": "*",
            },
            headers={"User-Agent": USER_AGENT},
            timeout=DEFAULT_TIMEOUT,
        )
        r.raise_for_status()
        data = r.json()
        pages = data.get("query", {}).get("pages", {})
        # Normalizar keys: la API puede devolver pageids como string o int.
        # Guardamos ambas formas para que el lookup posterior sea robusto.
        out = {}
        for pid, p in pages.items():
            extract = p.get("extract", "")
            out[str(pid)] = extract
            try:
                out[int(pid)] = extract
            except (ValueError, TypeError):
                pass
        return out
    except Exception:
        return {}


def wikipedia_search(query: str, max_results: int = MAX_RESULTS) -> list[dict]:
    """
    Busca en Wikipedia ES y devuelve extractos relevantes.

    Devuelve lista de dicts: [{"title", "extract", "url"}, ...].
    En caso de fallo de red o API, devuelve lista vacia (degrada con gracia).
    """
    if not query or not query.strip():
        return []

    cache_key = f"q::{query.strip().lower()}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    titles = _wiki_search_titles(query, limit=max_results)
    if not titles:
        _cache_set(cache_key, [])
        return []

    pageids = [t["pageid"] for t in titles]
    extracts = _wiki_extracts(pageids)

    out = []
    for t in titles:
        extract = extracts.get(t["pageid"], "").strip()
        if len(extract) < MIN_CHARS_PER_EXTRACT:
            continue
        out.append({
            "title": t["title"],
            "extract": extract,
            "url": f"https://es.wikipedia.org/wiki/{t['title'].replace(' ', '_')}",
        })

    _cache_set(cache_key, out)
    return out


# --- Filtrado por relevancia --------------------------------------------

def _normalize_for_match(text: str) -> str:
    """Minusculas, sin tildes, colapsa espacios -> matching robusto."""
    import unicodedata
    nfkd = unicodedata.normalize("NFKD", text)
    no_accents = "".join(c for c in nfkd if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", no_accents.lower()).strip()


def _extract_relevant(president: str, results: list[dict]) -> list[dict]:
    """
    Si se identifico un presidente, filtra los extractos que NO lo mencionan
    (ni por nombre completo ni por apellido). Asi evitamos contaminar el
    contexto con info de otros mandatarios.

    Si NINGUN extracto lo menciona, devolvemos los mejores tal cual (es
    mejor que nada: el LLM puede usar contexto general).
    """
    if not president:
        return results

    pres_norm = _normalize_for_match(president)
    pres_tokens = [t for t in re.findall(r"\w{4,}", pres_norm)]

    matching = []
    non_matching = []
    for r in results:
        text_norm = _normalize_for_match(r["extract"])
        # Match por nombre completo O por cualquier token significativo.
        if pres_norm in text_norm or any(t in text_norm for t in pres_tokens):
            matching.append(r)
        else:
            non_matching.append(r)

    # Priorizamos los que SI mencionan al presidente; si no hay ninguno,
    # caemos a los generales (mejor contexto que nada).
    return matching if matching else results


def _truncate(text: str, max_words: int) -> str:
    words = text.split()
    if len(words) <= max_words:
        return text
    return " ".join(words[:max_words]) + "..."


# --- Construccion del bloque de contexto ---------------------------------

def build_research_context(
    president: Optional[str],
    question: str,
) -> tuple[str, list[dict]]:
    """
    Punto de entrada principal: dispara la busqueda en Wikipedia (si aplica)
    y devuelve (bloque_de_contexto, fuentes_externas).

    El bloque de contexto es vacio ("") si no hay resultados o si el trigger
    no se activa. Las fuentes externas son para trazabilidad interna (el
    usuario NO las ve, por decision de diseno).

    Estructura del bloque devuelto:
        [Contexto complementario]
        [Titulo 1] URL
        <extracto 1>
        ---
        [Titulo 2] URL
        <extracto 2>
    """
    if not should_research([], question, president):
        # Caso atipico: el caller decidio no investigar. Devolvemos vacio.
        return "", []

    # Query a Wikipedia: presidente + pregunta (sin presidente: solo pregunta).
    if president:
        query = f"{president} Ecuador"
    else:
        query = question

    results = wikipedia_search(query)
    if not results:
        return "", []

    results = _extract_relevant(president, results)
    if not results:
        return "", []

    bloques = []
    fuentes = []
    for r in results:
        extract = _truncate(r["extract"], MAX_WORDS_PER_RESULT)
        bloques.append(f"[{r['title']}]\n{extract}")
        fuentes.append({"titulo": r["title"], "url": r["url"]})

    bloque = "\n---\n".join(bloques)
    return bloque, fuentes


def research_for_chat(
    local_chunks: list[dict],
    question: str,
    president: Optional[str],
) -> tuple[str, list[dict]]:
    """
    Wrapper de alto nivel para usar desde app.py.

    Devuelve (contexto_investigacion, fuentes_externas).
    Si no se dispara research, devuelve ("", []).
    """
    if not should_research(local_chunks, question, president):
        return "", []
    return build_research_context(president, question)
