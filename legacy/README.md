# Legacy Scripts (pre-Docker)

> **Estos scripts son del sistema anterior basado en `venv` + `pip install`.**
> Quedan acá como referencia historica, pero **NO se usan** en el sistema actual.

## Por que fueron deprecados

El sistema ahora se distribuye como imagen Docker. Las ventajas:
- Sin instalar Python, torch, sentence-transformers localmente
- Sin conflictos de venv entre maquinas
- Reproducible: misma imagen, mismo comportamiento
- Distribuible via Docker Hub (`alejololer/rag-presidentes`)

## Que usar en su lugar

Doble clic en **`rag.bat`** (en el directorio raiz) o desde CMD:

```cmd
rag.bat setup    REM equivalente al antiguo iniciar_rag.bat
rag.bat start    REM equivalente a la parte de "iniciar"
```

Para macOS / Linux:

```bash
./setup.sh setup
./setup.sh start
```

## Que hacia el sistema legacy

`iniciar_rag.bat` y `lanzar_rag_desde_cmd.bat` hacian:
1. Crear un `.venv` con `python -m venv`
2. Instalar dependencias: `pip install -r requirements.txt`
3. Generar embeddings: `python generate_embeddings.py`
4. Levantar uvicorn: `uvicorn app:app --reload --port 8010`

Todo esto ahora lo hace Docker automaticamente.

## Si necesitás volver al modo legacy

```cmd
cd ..
legacy\iniciar_rag.bat
```

Pero **no lo recomendamos** salvo que tengas un caso muy especifico donde
no puedas usar Docker (ej. una PC con Windows 7 que no soporta Docker Desktop).
