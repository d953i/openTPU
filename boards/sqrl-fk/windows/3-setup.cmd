@echo off
rem Step 3 (once): set up this PC to run models on the card: a Python environment in build\venv-win (about 1 GB;
rem boards\sqrl-fk\host\setup_win_python.ps1) and the models into models\ (default Qwen3.5-0.8B, 1.6 GB, which the
rem self-test uses, and Qwen3.5-9B, 18 GB). Other models: 3-setup.cmd Qwen3.5-2B Qwen3.5-4B. Needs Python 3.10 or later
rem (python.org; 3.12 or 3.13 recommended) and the internet; no administrator rights. Run again any time to add models.
setlocal
set "MODELS=%*"
if "%MODELS%"=="" set "MODELS=Qwen3.5-0.8B Qwen3.5-9B"
set "LIST="
for %%m in (%MODELS%) do call set "LIST=%%LIST%%,%%m"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\host\setup_win_python.ps1" -Model %LIST:~1%
if errorlevel 1 (echo. & echo Setup did not finish: see the message above.) else (echo. & echo Done. Next: 4-selftest.cmd.)
pause
