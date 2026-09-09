@echo off
rem ============================================================
rem DeepSeek Harness one-click launcher (thin wrapper).
rem NOTE: keep this file ASCII-only (cmd uses the system code page;
rem       non-ASCII text can break the if-block parsing).
rem Double-click to run. Default port 3080.
rem Usage: start-web.bat  /  start-web.bat -Port 9090 -SkipUpdate
rem All arguments are forwarded to start-web.ps1.
rem ============================================================

set "POWERSHELL=powershell"
where powershell >nul 2>nul || set "POWERSHELL=pwsh"

"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-web.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%EXITCODE%"=="0" (
  echo [FAILED] Exit code %EXITCODE%. See the messages above.
) else (
  echo [DONE] Launcher finished. You may close this window.
)
echo.
pause >nul
exit /b %EXITCODE%
