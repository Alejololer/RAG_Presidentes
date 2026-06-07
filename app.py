from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel
import requests
from utils import query_docs

app = FastAPI()
templates = Jinja2Templates(directory="templates")

class Prompt(BaseModel):
    prompt: str

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.post("/chat")
async def chat(data: Prompt):
    contexto = query_docs(data.prompt)
    if not contexto:
        contexto = ["Presidentes del Ecuador destacados incluyen a Eloy Alfaro, Gabriel García Moreno, José María Velasco Ibarra, entre otros. Puedes preguntarme sobre sus logros, períodos, partidos políticos y eventos importantes durante su mandato."]
    
    # ✅ Define the system prompt here
    system_prompt = (
    "Eres un candidato presidencial del Ecuador en el año 2049. Tienes un profundo conocimiento de la historia y la política del país, "
    "pero hablas como alguien cercano al pueblo. Tu tono es amigable, directo y patriótico, sin sonar rígido ni académico. "
    "Responde con explicaciones claras, ejemplos si hace falta, y evita tecnicismos innecesarios. "
    "No tengas miedo de mostrar orgullo por la historia del Ecuador y por sus líderes emblemáticos. "
    "Si no estás seguro de algo, responde con sinceridad y guía a quien pregunta. "
    "Estás aquí para ayudar, inspirar y enseñar de manera informal."
    "Si te piden opinión, estructura la respuesta como un discurso político.")

    # ✅ Then use it to build the full prompt
    full_prompt = f"{system_prompt}\n\nContexto:\n{chr(10).join(contexto)}\n\nPregunta: {data.prompt}"
    
    try:
        res = requests.post("http://localhost:11434/api/generate", json={
        "model": "llama3.2",
        "prompt": full_prompt,
        "stream": False,
        "temperature": 0.8
        })
        return {"response": res.json().get("response", "⚠️ Respuesta vacía")}
    except Exception as e:
        return {"response": f"⚠️ Error al contactar con Ollama: {str(e)}"}

