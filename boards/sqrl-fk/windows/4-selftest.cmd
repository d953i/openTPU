@echo off
rem Step 4: check the card: openTPU's self-test (link, memory, compute), its last stage Qwen3.5-0.8B bit for bit
rem against openTPU's simulator, with 4-bit (fp4) weights as the chat uses. Every line should say PASS, the last one "ALL PASS". Asks for administrator rights
rem (the card's driver opens for administrators only).
net session >nul 2>&1 && goto :admin
powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
exit /b
:admin
setlocal
set "MODEL="
if exist "%~dp0..\..\..\models\Qwen3.5-0.8B\config.json" set "MODEL=--model qwen35"
call "%~dp0..\host\otpu-fk.cmd" -m opentpu.host.selftest --dev sqrlfk0 %MODEL% --wformat fp4
pause
