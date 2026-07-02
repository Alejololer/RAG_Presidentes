@echo off
REM =============================================================================
REM RAG Presidentes Ecuador - Entry point para Windows
REM
REM Uso:
REM   rag.bat                  Menu interactivo (9 opciones)
REM   rag.bat start            Inicia el servicio
REM   rag.bat stop             Detiene el servicio
REM   rag.bat logs             Ver logs en vivo
REM   rag.bat health           Health check + smoke test
REM   rag.bat setup            Setup completo (primera vez)
REM   rag.bat build            Build imagen local
REM   rag.bat pull             Descarga imagen de Docker Hub
REM   rag.bat update           git pull + rebuild
REM   rag.bat config           Editar .env
REM   rag.bat uninstall        Desinstalar todo
REM   rag.bat help             Muestra esta ayuda
REM =============================================================================

setlocal
cd /d "%~dp0"

REM ======================
REM Si hay argumentos, delegar a setup.ps1 (modo no-interactivo)
REM ======================
if not "%~1"=="" goto DELEGATE

REM ======================
REM Modo interactivo: mostrar menu
REM ======================
:MENU
cls
echo ========================================
echo   RAG Presidentes Ecuador
echo ========================================
echo.
echo   [Uso diario]
echo   1) Iniciar servicio
echo   2) Detener servicio
echo   3) Ver logs
echo   4) Verificar salud (/health + /chat)
echo.
echo   [Avanzadas]
echo   5) Setup completo (primera vez)
echo   6) Build imagen (local)
echo   7) Pull imagen (Docker Hub)
echo   8) Actualizar codigo (git pull + rebuild)
echo   9) Reconfigurar (.env)
echo.
echo   10) Desinstalar
echo.
echo   0) Salir
echo.
set /p "op=Opcion: "

if "%op%"=="0"  exit /b 0
if "%op%"=="1"  call :RUN setup.ps1 start
if "%op%"=="2"  call :RUN setup.ps1 stop
if "%op%"=="3"  call :RUN setup.ps1 logs
if "%op%"=="4"  call :RUN setup.ps1 health
if "%op%"=="5"  call :RUN setup.ps1 setup
if "%op%"=="6"  call :RUN setup.ps1 build
if "%op%"=="7"  call :RUN setup.ps1 pull
if "%op%"=="8"  call :RUN setup.ps1 update
if "%op%"=="9"  call :RUN setup.ps1 config
if "%op%"=="10" call :RUN setup.ps1 uninstall

echo.
echo Opcion invalida o no reconocida.
timeout /t 2 /nobreak >nul
goto MENU

REM ======================
REM Subrutina: ejecutar setup.ps1 con un comando
REM ======================
:RUN
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %~1 %~2 %~3
set RC=%ERRORLEVEL%
if not "%RC%"=="0" (
    echo.
    echo [ERROR] setup.ps1 %~1 termino con codigo %RC%
    echo.
    pause
)
goto MENU

REM ======================
REM Subrutina: delegar argumentos
REM ======================
:DELEGATE
if /i "%~1"=="help" (
    echo.
    echo rag.bat - RAG Presidentes Ecuador
    echo.
    echo Menu interactivo (9 opciones + salir):
    echo   1) Iniciar   2) Detener   3) Logs   4) Salud
    echo   5) Setup     6) Build     7) Pull   8) Update
    echo   9) Config    10) Uninstall 0) Salir
    echo.
    echo Comandos directos (no interactivos):
    echo   rag.bat start   ^<^> setup.ps1 start
    echo   rag.bat stop    ^<^> setup.ps1 stop
    echo   rag.bat logs    ^<^> setup.ps1 logs
    echo   rag.bat health  ^<^> setup.ps1 health
    echo   rag.bat setup   ^<^> setup.ps1 setup
    echo   rag.bat build   ^<^> setup.ps1 build
    echo   rag.bat pull    ^<^> setup.ps1 pull
    echo   rag.bat update  ^<^> setup.ps1 update
    echo   rag.bat config  ^<^> setup.ps1 config
    echo   rag.bat uninstall ^<^> setup.ps1 uninstall
    echo.
    echo Imagen Docker Hub: alejololer/rag-presidentes:1.0.0
    echo.
    exit /b 0
)

REM Pasar todos los argumentos a setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
exit /b %ERRORLEVEL%
