@echo off
rem Step 1 (once): write the openTPU image to an FK33's flash over JTAG and bring the card back in Windows
rem (prebuilt\sqrl-fk33\a3\fk33_flash.ps1; about 10 minutes). Needs Vivado Lab Edition (free) or Vivado, any version,
rem in C:\Xilinx or C:\AMDDesignTools and a micro-USB cable from the card's USB port (its built-in JTAG) to the PC. Asks for administrator rights. Afterwards restart the PC fully.
rem Options pass through: 1-flash-fk33.cmd -Target <name>   (with several cards on USB: picks one)
net session >nul 2>&1 && goto :admin
if "%~1"=="" (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'") else (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'")
exit /b
:admin
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\..\prebuilt\sqrl-fk33\a3\fk33_flash.ps1" %*
if errorlevel 1 (echo. & echo The flash did not finish: see the message above.) else (echo. & echo Done. Shut the PC down, start it again, then run 2-install-driver.cmd.)
pause
