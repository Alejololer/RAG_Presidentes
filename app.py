import json
import os

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
import requests

from utils import (
    retrieve,
    resolve_president,
    get_known_names,
    SECTION_LABELS,
    MODEL_NAME,
    _get_collection,
)
from research_tool import research_for_chat

# --- Configuración por entorno (compatible con arquitectura distribuida) ---
# En el ecosistema "Opción 2049", Ollama corre en el Nodo de IA (GPU), no en
# la misma máquina que este servicio. Por eso el host es configurable.
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_URL = f"{OLLAMA_HOST.rstrip('/')}/api/generate"
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:7b")
RAG_TOP_K = int(os.getenv("RAG_TOP_K", "5"))
# Orígenes permitidos para CORS (el frontend Next.js vive en otro origen).
CORS_ORIGINS = os.getenv("CORS_ORIGINS", "*").split(",")

app = FastAPI(title="Servicio RAG - Presidentes del Ecuador (Opción 2049)")

# CORS para que la Web App (Next.js) y el Worker puedan consumir el servicio.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in CORS_ORIGINS],
    allow_methods=["*"],
    allow_headers=["*"],
)

templates = Jinja2Templates(directory="templates")

# Lista canónica de presidentes (se carga una vez al iniciar).
KNOWN_NAMES = get_known_names()


class Prompt(BaseModel):
    prompt: str
    # Presidente actual de la conversación (sticky). El cliente reenvía el
    # `presidente` que recibió en la respuesta anterior para dar continuidad.
    presidente: str | None = None


def build_context(resultados):
    """Construye el bloque de CONTEXTO etiquetado por presidente y sección."""
    bloques = []
    for r in resultados:
        etiqueta = SECTION_LABELS.get(r["seccion"], r["seccion"])
        bloques.append(f"[Fuente: {r['presidente']} — {etiqueta}]\n{r['text']}")
    return "\n---\n".join(bloques)


def build_system_prompt(presidente, hay_contexto):
    """
    Prompt impersonador en 1ª persona + anti-alucinación estricta.
    Si no se detectó presidente, se usa una voz de guía neutral.
    """
    if presidente:
        return (
            f"Eres {presidente}, presidente del Ecuador. Respondes SIEMPRE en primera persona, "
            f"como si tú mismo hablaras, con tu tono, tu época, tu ideología y tu forma de expresarte. "
            "Reglas estrictas:\n"
            "1. Usa ÚNICAMENTE la información del CONTEXTO de abajo. Es tu memoria y tu biografía.\n"
            "2. Si la respuesta no está en el CONTEXTO, di con honestidad que no recuerdas o no cuentas "
            "con esa información. NUNCA inventes datos ni uses conocimiento externo o de otros presidentes.\n"
            "3. No hables de hechos posteriores a tu vida ni de otros presidentes salvo que aparezcan en el CONTEXTO.\n"
            "4. Habla de forma cercana y humana, pero fiel a los datos."
        )
    # Sin presidente identificado: guía neutral que pide precisión.
    ejemplos = ", ".join(KNOWN_NAMES[:6])
    return (
        "Eres un guía del archivo histórico de presidentes del Ecuador. "
        "El usuario no especificó claramente de qué presidente desea hablar. "
        "Pídele amablemente que indique el nombre del presidente sobre el que quiere preguntar. "
        f"Puedes mencionar algunos disponibles como ejemplo: {ejemplos}, entre otros. "
        "No inventes información ni respondas sobre un presidente concreto sin que lo nombren."
    )


@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse(request, "index.html")


@app.get("/health")
async def health():
    """Health check para orquestación (Cloudflare Tunnel / Worker / monitoreo)."""
    return {
        "status": "ok",
        "presidentes_indexados": len(KNOWN_NAMES),
        "modelo_llm": OLLAMA_MODEL,
        "ollama_host": OLLAMA_HOST,
    }


@app.get("/stats")
async def stats():
    """Estado de la base de datos vectorial + auditoría de calidad del dataset.

    Lee el reporte de auditoría precomputado (`audit_report.json`, generado por
    `audit_data.py`) y lo combina con el conteo real de chunks en ChromaDB.
    Pensado para mostrar el estado de la BD en la UI (demo)."""
    # Conteo real de chunks indexados en ChromaDB (degrada con gracia).
    try:
        chunks = _get_collection(create=False).count()
    except Exception:
        chunks = None

    calidad = None
    try:
        with open("audit_report.json", encoding="utf-8") as f:
            rep = json.load(f)
        tot = rep.get("totales", {})
        anomalias = rep.get("anomalias_longitud", {})
        calidad = {
            "registros_raw": tot.get("registros_raw"),
            "registros_limpios": tot.get("registros_limpios"),
            "secciones_esperadas": tot.get("secciones_esperadas"),
            "nombres_corregidos": len(rep.get("nombres_sucios", [])),
            "claves_no_mapeadas": len(rep.get("claves_no_mapeadas", {})),
            "secciones_faltantes": len(rep.get("secciones_faltantes", {})),
            "chunks_con_cruce": len(rep.get("chunks_con_cruce_de_presidentes", {})),
            "contradicciones_fechas": len(rep.get("contradicciones_fechas", {})),
            "secciones_muy_cortas": len(anomalias.get("muy_cortas", [])),
        }
    except FileNotFoundError:
        calidad = None

    return {
        "presidentes": len(KNOWN_NAMES),
        "chunks": chunks,
        "modelo_llm": OLLAMA_MODEL,
        "modelo_embeddings": MODEL_NAME,
        "vector_db": "ChromaDB (coseno)",
        "calidad": calidad,
    }


@app.post("/chat")
async def chat(data: Prompt):
    # 1. Resolver el presidente: detecta el del mensaje o mantiene el sticky
    #    de la conversación (persistencia entre mensajes de seguimiento).
    presidente = resolve_president(data.prompt, data.presidente, KNOWN_NAMES)

    # 2. Recuperar contexto filtrado por ese presidente (evita mezcla).
    resultados = retrieve(data.prompt, president=presidente, top_k=RAG_TOP_K)

    # 3. Capa 2 (research): si el retrieval local es debil/ausente, complementar
    #    con Wikipedia ES. Trigger conservador (pocas requests). El usuario NO
    #    ve la fuente (decision de diseno del equipo), pero queda registrada
    #    internamente en 'fuentes_externas' para trazabilidad.
    research_ctx, fuentes_externas = research_for_chat(
        local_chunks=resultados,
        question=data.prompt,
        president=presidente,
    )

    # 4. Construir el bloque de contexto combinando local + research.
    if resultados:
        contexto_local = build_context(resultados)
    else:
        contexto_local = "(No hay información disponible en el archivo histórico para esta pregunta.)"

    if research_ctx:
        contexto = (
            f"{contexto_local}\n\n"
            f"--- Contexto complementario ---\n{research_ctx}"
        )
    else:
        contexto = contexto_local

    # 5. System prompt anti-alucinación (intacto, no se menciona la fuente al usuario).
    system_prompt = build_system_prompt(presidente, bool(resultados) or bool(research_ctx))
    full_prompt = (
        f"{system_prompt}\n\n"
        f"CONTEXTO:\n{contexto}\n\n"
        f"Pregunta del usuario: {data.prompt}"
    )

    # 6. Generar respuesta con Ollama (temperatura baja = menos invención).
    try:
        res = requests.post(OLLAMA_URL, json={
            "model": OLLAMA_MODEL,
            "prompt": full_prompt,
            "stream": False,
            "options": {"temperature": 0.35},
        })
        respuesta = res.json().get("response", "⚠️ Respuesta vacía")
    except Exception as e:
        return {"response": f"⚠️ Error al contactar con Ollama: {str(e)}"}

    # 7. Devolver respuesta + fuentes (trazabilidad interna).
    fuentes = [
        {"presidente": r["presidente"], "seccion": SECTION_LABELS.get(r["seccion"], r["seccion"])}
        for r in resultados
    ]
    return {
        "response": respuesta,
        "presidente": presidente,
        "fuentes": fuentes,
        "fuentes_externas": fuentes_externas,  # nuevo: para monitoreo interno
    }
