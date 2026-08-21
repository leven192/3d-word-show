@echo off
rem ============================================================
rem  ONE-CLICK START - everything runs automatically:
rem   1. cleanup old instances (server / tunnel)
rem   2. ensure local libs (one-time download if missing)
rem   3. rebuild latest release package (embed newest model.glb)
rem   4. start local server
rem   5. start public tunnel (latest share URL)
rem   6. open webpage
rem   7. deploy to CloudBase static hosting (auto-update public site)
rem   8. start auto-deploy watcher (model.glb changes auto-deploy)
rem   9. git add . / commit "update" / push (auto-update GitHub)
rem ============================================================
cd /d "%~dp0"

echo [1/9] Cleaning old instances...
taskkill /IM cpolar.exe /F >nul 2>&1
taskkill /IM cloudflared.exe /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq GLB Viewer Server*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq GLB Tunnel*" /F >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } } catch {}"
timeout /t 2 /nobreak >nul

echo [2/9] Checking local libs (one-time download if missing)...
if not exist "%~dp0lib\qrcode.min.js" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-deps.ps1"
)

echo [3/9] Building latest release package...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-static.ps1" -NoPrompt
if errorlevel 1 echo [WARN] build package failed - will use previous release folder.

echo [4/9] Starting server...
start "GLB Viewer Server" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"

echo [5/9] Starting public tunnel...
start "GLB Tunnel" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0share.ps1"

echo [6/9] Opening webpage...
timeout /t 3 /nobreak >nul
start "" http://localhost:8000

echo [7/9] Deploying to CloudBase static hosting (auto-update public site)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cloudbase-deploy.ps1" -NoPrompt
if errorlevel 1 echo [WARN] CloudBase deploy failed - see output above.

echo [8/9] Starting auto-deploy watcher (model.glb changes auto-deploy)...
start "GLB Auto-Deploy Watcher" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watch-deploy.ps1"
echo       Watcher running minimized. Log: watch-deploy.log

echo [9/9] Git update: add / commit / push...
where git >nul 2>&1
if %errorlevel%==0 (
    git add .
    git commit -m "update"
    git push
) else (
    echo [SKIP] Git not found - skip push.
)

echo.
echo Done. Local: http://localhost:8000
echo        Public: https://naigukeji-baigukeji-d6g7omgxc78b09a62.webapps.tcloudbase.com/
echo        Auto-deploy watcher running (close its minimized window to stop).
echo.
