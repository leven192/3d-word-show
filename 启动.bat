@echo off
rem ============================================================
rem  ONE-CLICK START - everything runs automatically:
rem   1. cleanup old instances (server / tunnel)
rem   2. ensure local libs (one-time download if missing)
rem   3. rebuild latest release package (embed newest model.glb)
rem   4. start local server
rem   5. start public tunnel (latest share URL)
rem   6. open webpage
rem   7. sync release package to Tencent COS (permanent link)
rem   8. deploy to Vercel (auto-update https://3d-word.vercel.app)
rem      (skipped if Vercel CLI not installed)
rem ============================================================
cd /d "%~dp0"

echo [1/7] Cleaning old instances...
taskkill /IM cpolar.exe /F >nul 2>&1
taskkill /IM cloudflared.exe /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq GLB Viewer Server*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq GLB Tunnel*" /F >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } } catch {}"
timeout /t 2 /nobreak >nul

echo [2/7] Checking local libs (one-time download if missing)...
if not exist "%~dp0lib\qrcode.min.js" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-deps.ps1"
)

echo [3/7] Building latest release package...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-static.ps1" -NoPrompt
if errorlevel 1 echo [WARN] build package failed - will use previous release folder.

echo [4/7] Starting server...
start "GLB Viewer Server" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"

echo [5/7] Starting public tunnel...
start "GLB Tunnel" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0share.ps1"

echo [6/7] Opening webpage...
timeout /t 3 /nobreak >nul
start "" http://localhost:8000

echo [7/7] Syncing to Tencent COS (permanent link, works even when PC is off)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-cos.ps1"
if errorlevel 1 echo [WARN] COS sync did not complete - check API keys / network. Local preview still works.

echo [8/8] Deploying to Vercel (auto-update webpage: https://3d-word.vercel.app)...
where vercel >nul 2>&1
if %errorlevel%==0 (
    vercel --prod --yes
    if errorlevel 1 (
        echo [WARN] Vercel deploy failed - check network / login / project link.
    ) else (
        echo [OK] Vercel webpage updated.
    )
) else (
    echo [SKIP] Vercel CLI not installed - webpage NOT auto-updated.
    echo        One-time setup: install Node, then: npm i -g vercel ^&^& vercel login ^&^& vercel link
)

echo.
echo Done. Local webpage: http://localhost:8000  |  Public webpage: https://3d-word.vercel.app
echo.
