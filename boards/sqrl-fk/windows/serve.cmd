@echo off
rem Optional: serve a model to other programs as an OpenAI-style API at http://127.0.0.1:8000/v1 (any OpenAI client or
rem chat app that takes a custom server address): the largest model in models\, or serve.cmd Qwen3.5-4B --port 8001.
rem Close the window to stop it. Asks for administrator rights (the card's driver opens for administrators only).
net session >nul 2>&1 && goto :admin
if "%~1"=="" (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'") else (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'")
exit /b
:admin
setlocal
if not "%~1"=="" (
    call "%~dp0..\host\otpu-fk.cmd" serve %*
    pause
    exit /b
)
set "MODEL="
for %%m in (Qwen3.5-0.8B Qwen3.5-2B Qwen3.5-4B Qwen3.5-9B) do if exist "%~dp0..\..\..\models\%%m\config.json" set "MODEL=%%m"
if "%MODEL%"=="" (
    echo No model in the models folder: run 3-setup.cmd first.
    pause
    exit /b 1
)
call "%~dp0..\host\otpu-fk.cmd" serve %MODEL%
pause
