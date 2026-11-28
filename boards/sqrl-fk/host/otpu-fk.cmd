@echo off
rem openTPU's tools on a SQRL FK33 / FK35 under Windows (otpu_fk_run.py; docs/sqrl-fk.md "Windows host"):
rem   otpu-fk -m opentpu.host.selftest [--model qwen35]
rem   otpu-fk -m opentpu.host.smi --dev sqrlfk0
rem   otpu-fk chat Qwen3.5-9B
rem OTPU_TARGET: sqrl-fk35 (default) or sqrl-fk33. Python: OTPU_PYTHON, else build\venv-win of the repository
rem (setup_win_python.ps1: numpy, torch, transformers, ... for models), else the one AMD's 2025.2 tools ship (3.13
rem with numpy: enough for the selftest without models). The card: sqrlfk.sys, driver 2.1 or later.
setlocal
chcp 65001 >nul
set "PYTHONIOENCODING=utf-8"
set "HOSTDIR=%~dp0"
for %%I in ("%HOSTDIR%..\..\..") do set "REPO=%%~fI"
if not defined OTPU_PYTHON if exist "%REPO%\build\venv-win\Scripts\python.exe" set "OTPU_PYTHON=%REPO%\build\venv-win\Scripts\python.exe"
if not defined OTPU_PYTHON set "OTPU_PYTHON=C:\AMDDesignTools\2025.2\tps\win64\python-3.13.0\python.exe"
if not exist "%OTPU_PYTHON%" (
    echo Python not found: "%OTPU_PYTHON%". Run setup_win_python.ps1, or set OTPU_PYTHON to a Python 3.10+ with numpy.
    exit /b 1
)
set "PYTHONPATH=%REPO%;%HOSTDIR:~0,-1%"
"%OTPU_PYTHON%" "%HOSTDIR%otpu_fk_run.py" %*
exit /b %ERRORLEVEL%
