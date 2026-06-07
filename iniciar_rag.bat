@echo off
echo ==========================================
echo     INICIANDO SISTEMA RAG (FAISS)
echo ==========================================

REM Crear entorno virtual si no existe
IF NOT EXIST venv (
  echo [1/4] Creando entorno virtual...
  python -m venv venv
)

REM Activar entorno virtual
call venv\Scripts\activate

REM Instalar dependencias
echo [2/4] Instalando dependencias...
pip install -r requirements.txt

REM Generar embeddings si aún no existe la base FAISS
IF NOT EXIST faiss_index.bin (
  echo [3/4] Generando índice FAISS...
  python generate_embeddings.py
)

REM Iniciar la app web
echo [4/4] Iniciando servidor FastAPI...
uvicorn app:app --reload --port 8010

pause
