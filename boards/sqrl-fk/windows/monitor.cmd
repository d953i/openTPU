@echo off
rem Optional: watch the card (otpu-smi): its build, temperature, memory, how busy it is and which program uses it,
rem refreshed every second; Ctrl+C ends it. Reads registers only, so it can run beside a chat. Asks for administrator
rem rights (the card's driver opens for administrators only).
net session >nul 2>&1 && goto :admin
powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
exit /b
:admin
call "%~dp0..\host\otpu-fk.cmd" -m opentpu.host.smi --dev sqrlfk0 -l 1
pause
