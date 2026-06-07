import os

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
import requests

from utils import retrieve, detect_president, get_known_names, SECTION_LABELS

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
    return templates.TemplateResponse("index.html", {"request": request})


@app.get("/health")
async def health():
    """Health check para orquestación (Cloudflare Tunnel / Worker / monitoreo)."""
    return {
        "status": "ok",
        "presidentes_indexados": len(KNOWN_NAMES),
        "modelo_llm": OLLAMA_MODEL,
        "ollama_host": OLLAMA_HOST,
    }


@app.post("/chat")
async def chat(data: Prompt):
    # 1. Detectar de qué presidente trata la pregunta.
    presidente = detect_president(data.prompt, KNOWN_NAMES)

    # 2. Recuperar contexto filtrado por ese presidente (evita mezcla).
    resultados = retrieve(data.prompt, president=presidente, top_k=RAG_TOP_K)

    # 3. Construir prompt. Sin fallback al conocimiento del modelo:
    #    si no hay contexto, el system prompt anti-alucinación lo maneja.
    system_prompt = build_system_prompt(presidente, bool(resultados))
    contexto = build_context(resultados) if resultados else "(No hay información disponible en el archivo para esta pregunta.)"
    full_prompt = (
        f"{system_prompt}\n\n"
        f"CONTEXTO:\n{contexto}\n\n"
        f"Pregunta del usuario: {data.prompt}"
    )

    # 4. Generar respuesta con Ollama (temperatura baja = menos invención).
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

    # 5. Devolver respuesta + fuentes (trazabilidad).
    fuentes = [
        {"presidente": r["presidente"], "seccion": SECTION_LABELS.get(r["seccion"], r["seccion"])}
        for r in resultados
    ]
    return {
        "response": respuesta,
        "presidente": presidente,
        "fuentes": fuentes,
    }
