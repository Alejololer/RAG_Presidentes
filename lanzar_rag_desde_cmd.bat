@echo off
echo ==========================================
echo INICIANDO SISTEMA RAG (FAISS) SIN POWERSHELL
echo ==========================================

REM Crear entorno virtual si no existe
IF NOT EXIST venv (
    echo 🛠️ Creando entorno virtual...
    python -m venv venv
)

REM Activar entorno virtual en cmd
call venv\Scripts\activate.bat

REM Verificar instalación de FAISS-CPU
pip show faiss-cpu >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo 📦 Instalando faiss-cpu...
    pip install faiss-cpu
)

REM Instalar otras dependencias
echo 📦 Instalando requirements.txt...
pip install -r requirements.txt

REM Generar embeddings si aún no existen
IF NOT EXIST faiss_index.bin (
    echo 🧠 Generando índice FAISS...
    python generate_embeddings.py
)

REM Ejecutar servidor FastAPI
echo 🚀 Ejecutando app web...
uvicorn app:app --reload --port 8010

pause
