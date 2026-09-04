# 微信分享辅助脚本：把本地服务器穿透到公网，自动抓取公网链接并复制到剪贴板
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File share.ps1 [-Port 8000]
# 需要已安装 cpolar 或 cloudflared 之一，详见 README

param(
    [int]$Port = 8000
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$url = $null
$proc = $null
$script:loginIssue = $false
$script:cp = $null

# 状态文件：页面轮询展示（诊断"公网地址生成中"卡住的原因）
$statusFile = Join-Path $root 'tunnel-status.txt'
function Write-Status {
    param([string]$Text)
    try { [System.IO.File]::WriteAllText($statusFile, $Text, (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

function Find-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $search = @(
        "$root\$Name.exe",
        "$root\$Name",
        "$env:USERPROFILE\$Name.exe",
        "$env:LOCALAPPDATA\$Name\$Name.exe",
        "$env:APPDATA\$Name\$Name.exe",
        "$env:ProgramFiles\$Name\$Name.exe",
        "${env:ProgramFiles(x86)}\$Name\$Name.exe",
        "$env:LOCALAPPDATA\Programs\$Name\$Name.exe"
    )
    foreach ($p in $search) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-CpolarConfigPath {
    return (Join-Path $env:USERPROFILE '.cpolar\cpolar.yml')
}

# 检查 cpolar 是否已配置 authtoken
function Test-CpolarConfigured {
    $cfg = Get-CpolarConfigPath
    if (Test-Path $cfg) {
        $c = Get-Content $cfg -Raw
        if ($c -match 'authtoken:\s*\S') { return $true }
    }
    return $false
}

# 从配置读取第一个隧道名（cpolar 无 --all，需位置参数指定）
function Get-CpolarTunnelName {
    $cfg = Get-CpolarConfigPath
    if (Test-Path $cfg) {
        $m = [regex]::Match((Get-Content $cfg -Raw), '(?m)^\s{2}([a-zA-Z0-9_-]+):\s*$')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# 从 cpolar 日志解析公网地址（9200 Web UI 默认关闭，日志是可靠来源）
function Get-UrlFromTunnelLog {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        $logText = Get-Content $Path -Raw
        $m = [regex]::Match($logText, 'Tunnel established at (https://[^\s"]+)')
        if (-not $m.Success) { $m = [regex]::Match($logText, '"PublicUrl":"(https://[^"]+)"') }
        if ($m.Success) { return $m.Groups[1].Value }
    } catch { }
    return $null
}

# 自动登录 cpolar：已有配置则不动；有保存的 token 则应用；否则引导输入一次
function Ensure-CpolarLogin {
    param([string]$CpolarExe)
    if (Test-CpolarConfigured) {
        Write-Host "检测到 cpolar 已配置登录凭据（~\.cpolar\cpolar.yml）" -ForegroundColor DarkGray
        return
    }
    $tokenFile = Join-Path $root 'cpolar-token.txt'
    $token = ''
    if (Test-Path $tokenFile) {
        $token = (Get-Content $tokenFile -Raw).Trim()
    }
    if (-not $token) {
        Write-Host ""
        Write-Host "cpolar 需要登录（一次性配置）。" -ForegroundColor Cyan
        Write-Host "获取 Authtoken：浏览器登录 https://dashboard.cpolar.com -> Auth 页面 -> 复制" -ForegroundColor DarkGray
        $token = (Read-Host "请输入 cpolar Authtoken（直接回车跳过）").Trim()
        if ($token) {
            [System.IO.File]::WriteAllText($tokenFile, $token, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "已保存到 cpolar-token.txt（含登录凭据，请勿分享该文件）" -ForegroundColor Green
        }
    }
    if ($token) {
        Write-Host "正在应用 cpolar 登录凭据..." -ForegroundColor Cyan
        Write-Status "正在登录 cpolar…"
        & $CpolarExe authtoken $token 2>&1 | Out-Null
        Start-Sleep -Seconds 1
        Write-Host "cpolar 登录凭据已应用" -ForegroundColor Green
    } else {
        Write-Status "未配置 cpolar Authtoken（隧道可能无法启动；可在面板 http://127.0.0.1:9200 查看）"
    }
}

# 修复登录：清除旧凭据（"用户不一致"等登录异常）并引导输入最新 Authtoken
function Repair-CpolarLogin {
    param([string]$CpolarExe)
    Write-Host "正在修复 cpolar 登录..." -ForegroundColor Yellow
    $cfg = Get-CpolarConfigPath
    if (Test-Path $cfg) {
        Remove-Item $cfg -Force -ErrorAction SilentlyContinue
        Write-Host "已清除旧配置: $cfg" -ForegroundColor Yellow
    }
    Remove-Item (Join-Path $root 'cpolar-token.txt') -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "请复制最新 Authtoken：浏览器登录 https://dashboard.cpolar.com -> Auth（验证）页面" -ForegroundColor Cyan
    Write-Host "注意：旧 token 可能因改密码/多设备登录而失效，务必复制页面上的最新值" -ForegroundColor DarkGray
    $token = (Read-Host "请输入新的 cpolar Authtoken").Trim()
    if (-not $token) {
        Write-Status "未输入新 Authtoken，登录修复未完成"
        return $false
    }
    [System.IO.File]::WriteAllText((Join-Path $root 'cpolar-token.txt'), $token, (New-Object System.Text.UTF8Encoding($false)))
    Write-Status "已更新 cpolar 凭据，正在重新登录…"
    & $CpolarExe authtoken $token 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    Write-Host "cpolar 凭据已更新" -ForegroundColor Green
    return $true
}

# 从 cpolar 面板（127.0.0.1:9200）探测公网地址（新版 cpolar 可能只显示在面板里）
function Get-CpolarDashboardUrl {
    param([int]$DashboardPort)
    try {
        $json = Invoke-RestMethod "http://127.0.0.1:$DashboardPort/api/tunnels" -TimeoutSec 3
        $t = @($json.tunnels) | Where-Object { $_.public_url } | Select-Object -First 1
        if ($t -and $t.public_url) { return $t.public_url }
    } catch { }
    try {
        $html = (Invoke-WebRequest "http://127.0.0.1:$DashboardPort" -UseBasicParsing -TimeoutSec 3).Content
        $m = [regex]::Match($html, 'https://[a-z0-9\-\.]+\.cpolar\.(top|cn)')
        if ($m.Success) { return $m.Value }
    } catch { }
    return $null
}

function Start-Tunnel {
    param([string]$Exe, [string]$Args, [string]$UrlPattern, [string]$ToolName, [int]$DashboardPort = 0)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Args
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $script:proc = [System.Diagnostics.Process]::Start($psi)
    $script:url = $null
    $script:output = New-Object System.Collections.ArrayList
    $script:loginIssue = $false

    $handler = {
        param($s, $e)
        if ($e.Data) {
            [void]$script:output.Add($e.Data)
            if ($script:output.Count -gt 40) { $script:output.RemoveAt(0) }
            $m = [regex]::Match($e.Data, $UrlPattern)
            if ($m.Success) { $script:url = $m.Value }
        }
    }
    $script:proc.add_OutputDataReceived($handler)
    $script:proc.add_ErrorDataReceived($handler)
    $script:proc.BeginOutputReadLine()
    $script:proc.BeginErrorReadLine()

    Write-Host "正在启动 $ToolName 隧道（首次可能需要 10~30 秒）..." -ForegroundColor Cyan
    Write-Status "$ToolName 隧道启动中（首次 10~30 秒）…"
    $deadline = (Get-Date).AddSeconds(90)
    $lastDash = (Get-Date).AddSeconds(-10)
    while (-not $script:url -and -not $script:proc.HasExited -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        # 每 5 秒探测一次面板（cpolar）
        if ($DashboardPort -and ((Get-Date) - $lastDash).TotalSeconds -ge 5) {
            $lastDash = Get-Date
            $du = Get-CpolarDashboardUrl $DashboardPort
            if ($du) { $script:url = $du }
        }
        # 从日志解析 URL（cpolar 9200 Web UI 默认关闭，日志是可靠来源）
        if (-not $script:url -and $script:tunnelLog) {
            $script:url = Get-UrlFromTunnelLog $script:tunnelLog
        }
    }

    if (-not $script:url) {
        Write-Host "$ToolName 未能获取到公网链接。" -ForegroundColor Yellow
        $tail = ($script:output | Select-Object -Last 5) -join ' | '
        if ($tail.Length -gt 220) { $tail = $tail.Substring(0, 220) }
        if ($tail) { Write-Host "最近输出: $tail" -ForegroundColor DarkGray }

        # 检测登录相关错误（cpolar）
        if ($ToolName -eq 'cpolar') {
            if ($tail -match '用户不一致|inconsistent|login|authentication|401|unauthorized|token|auth|登录|exceed|限制') {
                $script:loginIssue = $true
                if ($tail -match 'exceed|限制|登录数') {
                    Write-Status "cpolar 登录数超限：请在 dashboard.cpolar.com 账号设置里退出其他设备后重试"
                } else {
                    Write-Status "cpolar 登录异常（可能是旧凭据/用户不一致）：将引导重新配置 Authtoken"
                }
                Write-Host "检测到 cpolar 登录异常，将自动修复..." -ForegroundColor Yellow
            } elseif ($tail -match 'port|address already in use') {
                Write-Status "cpolar 端口冲突：请检查端口占用后重试"
            } else {
                Write-Host "请检查 cpolar 面板（http://127.0.0.1:9200）：是否已登录？隧道是否 online？" -ForegroundColor Yellow
                Write-Status "cpolar 未生成地址：请打开 http://127.0.0.1:9200 检查登录与隧道状态、本地端口是否为 $Port"
            }
        } else {
            Write-Status "$ToolName 启动超时：请检查网络（$tail）"
        }
        return $false
    }
    return $true
}

Write-Host "==============================================" -ForegroundColor DarkGray
Write-Host "  微信分享模式 - 本地端口: $Port" -ForegroundColor White
Write-Host "==============================================" -ForegroundColor DarkGray

# 先清除旧公网地址文件：页面轮询到文件被清空后会立即作废旧地址，避免复制到过期链接
Remove-Item (Join-Path $root 'share-config.js') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $root 'current-url.txt') -Force -ErrorAction SilentlyContinue
Write-Status "正在启动公网隧道…"
Write-Host "已清除旧分享地址（新地址生成后页面会自动更新）" -ForegroundColor DarkGray

$cf = Find-Tool 'cloudflared'
$script:cp = Find-Tool 'cpolar'

if ($cf) {
    if (-not (Start-Tunnel $cf "tunnel --url http://localhost:$Port --no-autoupdate" 'https://[a-z0-9\-]+\.trycloudflare\.com' 'Cloudflare')) {
        if (-not $script:cp) { Write-Status "隧道启动失败，请查看本窗口提示"; Read-Host "按回车退出"; exit 1 }
    }
}

if (-not $script:url -and $script:cp) {
    $script:tunnelLog = Join-Path $root 'cpolar-tunnel.log'
    # 若 cpolar 已在后台运行（如开机自启），不重复启动，直接读取隧道地址
    $cpolarRunning = @(Get-Process cpolar -ErrorAction SilentlyContinue).Count -gt 0
    if ($cpolarRunning) {
        Write-Host "检测到 cpolar 已在后台运行，直接读取隧道地址…" -ForegroundColor Cyan
        Write-Status "cpolar 已在运行，读取隧道地址…"
        $dl = (Get-Date).AddSeconds(40)
        while (-not $script:url -and (Get-Date) -lt $dl) {
            $script:url = Get-UrlFromTunnelLog $script:tunnelLog
            if (-not $script:url) { $script:url = Get-CpolarDashboardUrl 9200 }
            if (-not $script:url) { Start-Sleep -Seconds 2 }
        }
        if (-not $script:url) { Write-Status "cpolar 已在运行但未取到隧道地址，请检查 cpolar-tunnel.log" }
    } else {
        Ensure-CpolarLogin $script:cp
        Remove-Item $script:tunnelLog -Force -ErrorAction SilentlyContinue
        # 配置里有隧道则 cpolar start <隧道名> -log <文件>，否则临时 http 隧道
        $tunnelName = Get-CpolarTunnelName
        $tunnelArgs = if ($tunnelName) { "start $tunnelName -log `"$script:tunnelLog`"" } else { "http $Port -log `"$script:tunnelLog`"" }
        $ok = Start-Tunnel $script:cp $tunnelArgs 'https://[\w.\-]+\.cpolar\.(top|cn)' 'cpolar' 9200
        if (-not $ok -and $script:loginIssue) {
            # 登录异常：自动修复（清旧凭据 + 重新输入 Authtoken）后重试一次
            $repaired = Repair-CpolarLogin $script:cp
            if ($repaired) {
                Start-Sleep -Seconds 1
                Remove-Item $script:tunnelLog -Force -ErrorAction SilentlyContinue
                $ok = Start-Tunnel $script:cp $tunnelArgs 'https://[\w.\-]+\.cpolar\.(top|cn)' 'cpolar' 9200
            }
        }
        if (-not $ok) {
            Read-Host "按回车退出"
            exit 1
        }
    }
}

if (-not $script:url) {
    Write-Host ""
    Write-Host "未找到 cloudflared 或 cpolar，请先安装其中一个：" -ForegroundColor Yellow
    Write-Host "  [推荐-国内] cpolar   https://www.cpolar.com/  （免费注册，下载 Windows 版并安装）"
    Write-Host "  [全球可用] cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
    Write-Host "               （下载后重命名为 cloudflared.exe 放到本目录即可，无需注册）"
    Write-Host ""
    Write-Status "未找到 cpolar/cloudflared，请先安装（见「启动.bat」或本窗口提示）"
    Write-Host "装好后重新双击「启动.bat」。"
    Read-Host "按回车退出"
    exit 1
}

$url = $script:url
Write-Host ""
Write-Host "公网链接已生成: $url" -ForegroundColor Green
Write-Host "已复制到剪贴板，可直接粘贴到微信发送。" -ForegroundColor Green
Set-Clipboard -Value $url
$url | Set-Content -Path (Join-Path $root '分享链接.txt') -Encoding UTF8
Write-Host "链接已保存到: 分享链接.txt" -ForegroundColor DarkGray

# 把最新公网地址同步进 share-config.js（页面"分享/复制"会自动读取，隧道重启后无需手动改）
$configJs = "window.__SHARE_PUBLIC_URL = '$url';"
[System.IO.File]::WriteAllText((Join-Path $root 'share-config.js'), $configJs, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "已同步最新公网地址到 share-config.js（页面将自动使用最新地址）" -ForegroundColor DarkGray

# 写入 current-url.txt：已打开的网页会定时轮询此文件，自动更新分享链接与二维码（无需刷新网页）
[System.IO.File]::WriteAllText((Join-Path $root 'current-url.txt'), $url, (New-Object System.Text.UTF8Encoding($false)))
Write-Status "已生成公网地址"
Write-Host "已写入 current-url.txt（已打开的网页会自动更新分享链接和二维码）" -ForegroundColor DarkGray

# 自测公网链接是否可访问（帮助排查"手机打不开"）
Write-Host ""
Write-Host "正在自测公网链接（15 秒超时）..." -ForegroundColor Cyan
try {
    $resp = Invoke-WebRequest -Uri $url -TimeoutSec 15 -UseBasicParsing
    if ($resp.StatusCode -eq 200) {
        Write-Host "自测通过：HTTP 200，手机浏览器打开该链接即可。" -ForegroundColor Green
    } else {
        Write-Host "自测异常：HTTP $($resp.StatusCode)" -ForegroundColor Yellow
    }
}
catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code) {
        Write-Host "自测失败：HTTP $code（隧道通但页面返回异常）" -ForegroundColor Yellow
    }
    else {
        Write-Host "自测失败：公网无法连接该链接，请按顺序检查：" -ForegroundColor Red
        Write-Host "  1. 本地服务器是否在运行？本机浏览器打开 http://localhost:$Port 试试" -ForegroundColor Yellow
        Write-Host "  2. cpolar 面板（http://127.0.0.1:9200）里隧道状态是否为 online" -ForegroundColor Yellow
        Write-Host "  3. 隧道本地端口是否指向 $Port（cpolar 默认是 80，需改为 $Port 或新建指向 $Port 的隧道）" -ForegroundColor Yellow
        Write-Host "  4. cpolar 是否已登录（免费版需登录后才生成隧道）" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "网页右下角有「分享 / 二维码」按钮，可用微信扫一扫打开。" -ForegroundColor DarkGray
Write-Host ""
Write-Host "注意：此窗口保持开启时链接才有效；按回车将关闭隧道并退出。" -ForegroundColor Yellow
Read-Host "按回车退出"

if ($proc -and -not $proc.HasExited) {
    try { $proc.Kill() } catch {}
}
