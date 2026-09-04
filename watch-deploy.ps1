# ============================================================
#  多设备自动部署监控（后台静默运行）
#  监控以下内容，检测到变化后自动：
#    1) build-static.ps1 打包到 发布/
#    2) cloudbase-deploy.ps1 部署到 CloudBase 静态托管
#  监控对象：
#    - model.glb           （设备 1，C4D 导出覆盖）
#    - models.json         （设备清单/名称/路径）
#    - models\*.glb        （设备 2~10）
#    - thumbs\*            （缩略图）
#  检测机制（双保险）：
#    - FileSystemWatcher 事件（即时）
#    - 每 10 秒轮询 LastWriteTime（可靠兜底，任何环境可用）
#  启动: 由 启动.bat 第 8 步后台拉起（最小化窗口）
#  日志: watch-deploy.log
#  首次运行若未登录 tcb，会自动触发 tcb login 授权
# ============================================================
param(
    [string]$WatchPath = 'D:\C4D\3D  word',
    [string]$EnvId = 'baigukeji-d6g7omgxc78b09a62',
    [string]$SiteUrl = 'https://naigukeji-baigukeji-d6g7omgxc78b09a62.webapps.tcloudbase.com/',
    [int]$QuietSeconds = 5,
    [int]$CooldownSeconds = 30,
    [int]$PollSeconds = 10
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:logFile = Join-Path $WatchPath 'watch-deploy.log'
$script:watchPath = $WatchPath
$script:glbPath = Join-Path $WatchPath 'model.glb'
$script:cfgPath  = Join-Path $WatchPath 'models.json'
$script:envId = $EnvId
$script:siteUrl = $SiteUrl
$script:quietSeconds = $QuietSeconds
$script:cooldownSeconds = $CooldownSeconds

# 需要监控的子目录（新 GLB / 缩略图）
$script:subDirs = @('models', 'thumbs')

function Log([string]$msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    try { Add-Content -Path $script:logFile -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

Log '=== 多设备自动部署监控启动 ==='
Log '监控: model.glb / models.json / models\*.glb / thumbs\*'

# 确保子目录存在
foreach ($d in $script:subDirs) {
    $dir = Join-Path $script:watchPath $d
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# 首次运行登录检查（已登录则跳过）
$probe = & tcb env list 2>&1
if ($LASTEXITCODE -ne 0 -or ($probe -match '无有效身份信息|请使用.*login')) {
    Log '需要登录 tcb：请在输出中完成授权（tcb login），一次性即可...'
    & tcb login
    Start-Sleep -Seconds 2
    Log '登录流程已触发，若失败请手动运行: tcb login'
}

# 收集所有受监控文件的快照 { 路径 -> LastWriteTime }（目录会递归扫描，新文件也能发现）
function Get-WatchedState {
    $state = @{}
    $paths = @($script:glbPath, $script:cfgPath)
    foreach ($d in $script:subDirs) {
        $dir = Join-Path $script:watchPath $d
        if (Test-Path $dir) {
            Get-ChildItem $dir -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $paths += $_.FullName }
        }
    }
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $state[$p] = (Get-Item $p).LastWriteTime
        }
    }
    return $state
}

$script:lastState = Get-WatchedState
$script:lastDeploy = Get-Date

# 部署动作（冷却 + 防占用 + 打包 + 部署）
function Invoke-Deploy {
    if (($(Get-Date) - $script:lastDeploy).TotalSeconds -lt $script:cooldownSeconds) { return }
    $script:lastDeploy = Get-Date

    # 等待文件写入稳定（若 model.glb 存在且被 C4D 占用则等待）
    Start-Sleep -Seconds $script:quietSeconds
    $ready = $true
    if (Test-Path $script:glbPath) {
        $ready = $false
        for ($i = 0; $i -lt 10; $i++) {
            try {
                $fs = [System.IO.File]::Open($script:glbPath, 'Open', 'Read', 'ReadWrite')
                $fs.Close()
                $ready = $true
                break
            } catch {
                Start-Sleep -Milliseconds 1000
            }
        }
    }
    if (-not $ready) { Log 'model.glb 仍被占用，跳过本次部署'; return }

    Log '检测到变化，开始自动打包...'
    try {
        & (Join-Path $script:watchPath 'build-static.ps1') -NoPrompt | Out-Null
        Log '打包完成，开始部署到 CloudBase...'
        & (Join-Path $script:watchPath 'cloudbase-deploy.ps1') -NoPrompt -EnvId $script:envId | Out-Null
        Log "OK 自动部署成功！访问链接: $script:siteUrl"
    } catch {
        Log ("FAIL 自动部署失败: " + $_.Exception.Message)
    }
}

# 双保险 1：FileSystemWatcher 即时事件（多数 Windows 环境有效）
function New-Watcher {
    param([string]$Path, [string]$Filter, [bool]$Recurse)
    $w = New-Object System.IO.FileSystemWatcher
    $w.Path = $Path
    $w.Filter = $Filter
    $w.IncludeSubdirectories = $Recurse
    $w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size -bor [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::CreationTime
    $action = { try { Invoke-Deploy } catch { } }
    Register-ObjectEvent -InputObject $w -EventName Changed -Action $action | Out-Null
    Register-ObjectEvent -InputObject $w -EventName Created -Action $action | Out-Null
    Register-ObjectEvent -InputObject $w -EventName Renamed -Action $action | Out-Null
    $w.EnableRaisingEvents = $true
}

# 根目录：model.glb 与 models.json
New-Watcher $script:watchPath 'model.glb' $false
New-Watcher $script:watchPath 'models.json' $false
# 子目录：models/ 与 thumbs/（递归，任何扩展名——按需判断）
foreach ($d in $script:subDirs) {
    New-Watcher (Join-Path $script:watchPath $d) '*' $true
}

# 双保险 2：轮询 LastWriteTime（任何环境都可靠）
Log ("监控中：等待变化（每 $PollSeconds 秒检查一次，关闭窗口即停止）...")
while ($true) {
    Start-Sleep -Seconds $PollSeconds
    $newState = Get-WatchedState
    $changed = $false
    # 新增或修改
    foreach ($k in $newState.Keys) {
        if (-not $script:lastState.ContainsKey($k) -or $script:lastState[$k] -ne $newState[$k]) { $changed = $true; break }
    }
    # 删除
    if (-not $changed) {
        foreach ($k in $script:lastState.Keys) {
            if (-not $newState.ContainsKey($k)) { $changed = $true; break }
        }
    }
    $script:lastState = $newState
    if ($changed) {
        Log '检测到 model.glb / models.json / models / thumbs 变化'
        Invoke-Deploy
    }
    # 泵 FileSystemWatcher 事件队列
    while ($null -ne (Wait-Event -Timeout 1)) { }
}
