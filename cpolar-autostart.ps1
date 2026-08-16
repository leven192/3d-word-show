# ============================================================
#  cpolar 开机自启脚本（静默后台运行）
#  - 确保本地服务器(server.ps1, 端口8000)在运行
#  - 后台启动 `cpolar start <隧道名> -log <文件>`，加载 cpolar.yml 里的隧道
#  - 已运行则不重复启动
#  - 抓取公网地址写入 current-url.txt / share-config.js（页面自动使用）
#  由「安装cpolar开机自启.bat」放入 Windows 启动文件夹的 vbs 调用
# ============================================================

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$log = Join-Path $root 'cpolar-autostart.log'
function Log {
    param([string]$t)
    try { Add-Content -Path $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $t) } catch {}
}

Log 'cpolar-autostart 开始'

# 1) 确保本地服务器运行（隧道需要后端服务，端口 8000）
try {
    $listen = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue
    if (-not $listen) {
        Log '本地服务器未运行，正在启动 server.ps1'
        # 注意：Start-Process 的 ArgumentList 数组不会给含空格的路径加引号，
        # 必须用显式带引号的字符串，否则路径被拆成多个参数导致启动失败
        $serverPs1 = Join-Path $root 'server.ps1'
        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$serverPs1`""
        Start-Sleep -Seconds 4
    } else {
        Log '本地服务器已在运行'
    }
} catch {
    Log ("服务器检查异常: " + $_.Exception.Message)
}

# 2) 查找 cpolar（PATH 或常见安装路径）
$cp = $null
$cmd = Get-Command cpolar -ErrorAction SilentlyContinue
if ($cmd) { $cp = $cmd.Source }
if (-not $cp) {
    foreach ($p in @(
        "$env:ProgramFiles\cpolar\cpolar.exe",
        "${env:ProgramFiles(x86)}\cpolar\cpolar.exe",
        "$env:LOCALAPPDATA\cpolar\cpolar.exe",
        "$env:APPDATA\cpolar\cpolar.exe",
        "$env:USERPROFILE\cpolar.exe",
        "$env:USERPROFILE\AppData\Local\cpolar\cpolar.exe",
        (Join-Path $root 'cpolar.exe')
    )) {
        if (Test-Path $p) { $cp = $p; break }
    }
}
if (-not $cp) {
    Log '未找到 cpolar（PATH 和常见路径均无）'
    exit 0
}
Log ("cpolar 路径: " + $cp)

# 3) 若已在运行则不重复启动
$running = @(Get-Process cpolar -ErrorAction SilentlyContinue)
# 从配置读取隧道名（注意：cpolar 无 --all 参数，需用位置参数指定隧道名）
$cfgPath = Join-Path $env:USERPROFILE '.cpolar\cpolar.yml'
$tunnelName = ''
if (Test-Path $cfgPath) {
    $cfgText = Get-Content $cfgPath -Raw
    $m = [regex]::Match($cfgText, '(?m)^\s{2}([a-zA-Z0-9_-]+):\s*$')
    if ($m.Success) { $tunnelName = $m.Groups[1].Value }
}
$tunnelLog = Join-Path $root 'cpolar-tunnel.log'
Remove-Item $tunnelLog -Force -ErrorAction SilentlyContinue

if ($running.Count -gt 0) {
    Log ("cpolar 已在运行（PID " + $running[0].Id + "），跳过启动")
} elseif ($tunnelName) {
    Log "正在后台启动 cpolar start $tunnelName -log $tunnelLog"
    try {
        # 日志路径含空格：必须显式加引号（ArgumentList 数组不会自动加）
        Start-Process -FilePath $cp -ArgumentList "start $tunnelName -log `"$tunnelLog`""
        Log 'cpolar 已启动'
    } catch {
        Log ("cpolar 启动失败: " + $_.Exception.Message)
    }
} else {
    Log '配置中未找到隧道，尝试临时 http 隧道 (cpolar http 8000)'
    try {
        Start-Process -FilePath $cp -ArgumentList "http 8000 -log `"$tunnelLog`""
    } catch {
        Log ("cpolar 启动失败: " + $_.Exception.Message)
    }
}

# 4) 等待隧道就绪，从日志解析公网地址写入页面轮询文件（最多等 60 秒）
#    注意：cpolar 的 9200 Web UI 默认关闭，地址只能从日志/输出获取
$deadline = (Get-Date).AddSeconds(60)
$got = $false
$loopCount = 0
while (-not $got -and (Get-Date) -lt $deadline) {
    $loopCount++
    $u = $null
    if (Test-Path $tunnelLog) {
        $logText = Get-Content $tunnelLog -Raw
        $m = [regex]::Match($logText, 'Tunnel established at (https://[^\s"]+)')
        if (-not $m.Success) { $m = [regex]::Match($logText, '"PublicUrl":"(https://[^"]+)"') }
        if ($m.Success) { $u = $m.Groups[1].Value }
    }
    if ($u) {
        try {
            [System.IO.File]::WriteAllText((Join-Path $root 'current-url.txt'), $u, (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::WriteAllText((Join-Path $root 'share-config.js'), "window.__SHARE_PUBLIC_URL = '$u';", (New-Object System.Text.UTF8Encoding($false)))
            Log ("已获取公网地址: " + $u)
        } catch { }
        $got = $true
        break
    }
    # cpolar 进程已退出则停止等待，避免空等
    if ($loopCount -ge 2 -and -not (Get-Process cpolar -ErrorAction SilentlyContinue)) {
        Log 'cpolar 进程未在运行，停止等待日志'
        break
    }
    Start-Sleep -Seconds 2
}
if (-not $got) { Log '未在 60 秒内获取到公网地址（cpolar 可能未运行或登录失效，请查看 cpolar 面板）' }
Log 'cpolar-autostart 完成'
