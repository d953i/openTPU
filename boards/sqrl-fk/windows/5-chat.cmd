@echo off
rem Step 5: chat with a model on the card: the largest model in models\ (or 5-chat.cmd Qwen3.5-4B [options]), with
rem the most context the card holds and 4-bit weights (fp4; --wformat int8 for 8-bit). Type a message and press Enter; /help lists the commands, /quit or Ctrl+C ends
rem it. The first chat with a model prepares it for some minutes and answers slowly at first; later ones start in
rem seconds. Asks for administrator rights (the card's driver opens for administrators only).
net session >nul 2>&1 && goto :admin
if "%~1"=="" (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'") else (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'")
exit /b
:admin
setlocal
if not "%~1"=="" (
    call "%~dp0..\host\otpu-fk.cmd" chat %*
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
call "%~dp0..\host\otpu-fk.cmd" chat %MODEL%
pause
