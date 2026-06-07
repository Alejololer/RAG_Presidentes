"""
Prueba funcional end-to-end del flujo de chat (sin levantar el servidor):
llama a la misma lógica que el endpoint /chat.
Requiere Ollama corriendo con qwen2.5:7b.

Ejecutar:  .venv\Scripts\python.exe test_chat.py
"""

import asyncio
from app import chat, Prompt


PREGUNTAS = [
    # Impersonación + datos de un presidente concreto
    "¿Cuáles fueron tus principales obras públicas, Eloy Alfaro?",
    # Otro presidente (verifica que no se mezclen)
    "Gabriel García Moreno, ¿qué legislación impulsaste?",
    # Anti-alucinación: dato ausente del archivo
    "Eloy Alfaro, ¿qué opinas sobre las criptomonedas y el bitcoin?",
    # Sin presidente nombrado: debe pedir aclaración
    "¿Quién fue el mejor presidente de todos?",
]


async def main():
    for q in PREGUNTAS:
        print("=" * 70)
        print("PREGUNTA:", q)
        out = await chat(Prompt(prompt=q))
        print("PRESIDENTE DETECTADO:", out.get("presidente"))
        fuentes = out.get("fuentes", [])
        print("FUENTES:", [f"{f['presidente']} / {f['seccion']}" for f in fuentes])
        print("RESPUESTA:\n", out["response"])
        print()


if __name__ == "__main__":
    asyncio.run(main())
