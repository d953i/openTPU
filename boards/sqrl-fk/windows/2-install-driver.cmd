@echo off
rem Step 2 (once): install the card's Windows driver, sqrlfk.sys 2.1 (prebuilt\sqrlfk-windows\2.1). It is test-signed,
rem which Windows accepts only in test-signing mode: this turns that mode on the first time (Secure Boot must be off in
rem the PC's firmware setup), then asks you to restart and run it again. Asks for administrator rights.
net session >nul 2>&1 && goto :admin
powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
exit /b
:admin
setlocal
bcdedit /enum {current} | findstr /r /c:"^testsigning *Yes" >nul
if not errorlevel 1 goto :install
echo Windows' test-signing mode is off, and the card's driver needs it.
echo Secure Boot must be off first (in the PC's firmware setup: press F2 or Del while it starts).
choice /c YN /m "Turn test signing on now"
if errorlevel 2 exit /b 1
bcdedit /set testsigning on
if errorlevel 1 (
    echo.
    echo Windows refused: Secure Boot is probably still on. Turn it off in the firmware setup and run this again.
    pause
    exit /b 1
)
echo.
echo Test signing is on. Restart Windows ("Test Mode" then shows on the desktop) and run 2-install-driver.cmd again.
pause
exit /b 0
:install
echo Installing the driver; Windows asks whether to install software from an unverified publisher: choose Install.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\..\prebuilt\sqrlfk-windows\2.1\install.ps1"
if errorlevel 1 (echo. & echo The driver was not installed: see the message above.) else (echo. & echo Done. Next: 3-setup.cmd.)
pause
