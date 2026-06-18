@echo off
echo ==========================================
echo INICIANDO SISTEMA RAG (ChromaDB) SIN POWERSHELL
echo ==========================================

REM Crear entorno virtual si no existe
IF NOT EXIST .venv (
    echo [1/3] Creando entorno virtual...
    python -m venv .venv
)

REM Activar entorno virtual en cmd
call .venv\Scripts\activate.bat

REM Instalar dependencias
echo [2/3] Instalando requirements.txt...
pip install -r requirements.txt

REM Generar embeddings si aun no existen
IF NOT EXIST chroma_db (
    echo Generando indice ChromaDB...
    python generate_embeddings.py
)

REM Ejecutar servidor FastAPI
echo [3/3] Ejecutando app web...
uvicorn app:app --reload --port 8010

pause
