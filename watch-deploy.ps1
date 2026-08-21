# ============================================================
#  model.glb 自动部署监控（后台静默运行）
#  监控 model.glb，检测到修改/覆盖（如 C4D 导出新版本）后自动：
#    1) build-static.ps1 打包到 发布/
#    2) cloudbase-deploy.ps1 部署到 CloudBase 静态托管
#  检测机制（双保险）：
#    - FileSystemWatcher 事件（即时）
#    - 每 10 秒轮询 LastWriteTime（可靠兜底，任何环境可用）
#  启动: 双击 start-watcher.bat（最小化窗口）
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
$script:envId = $EnvId
$script:siteUrl = $SiteUrl
$script:quietSeconds = $QuietSeconds
$script:cooldownSeconds = $CooldownSeconds

function Log([string]$msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    try { Add-Content -Path $script:logFile -Value $line -Encoding UTF8 } catch {}
    Write-Host $line
}

Log '=== 自动部署监控启动 ==='
Log ("监控文件: " + $script:glbPath)

# 首次运行登录检查（已登录则跳过）
$probe = & tcb env list 2>&1
if ($LASTEXITCODE -ne 0 -or ($probe -match '无有效身份信息|请使用.*login')) {
    Log '需要登录 tcb：请在输出中完成授权（tcb login），一次性即可...'
    & tcb login
    Start-Sleep -Seconds 2
    Log '登录流程已触发，若失败请手动运行: tcb login'
}

$script:lastWrite = (Get-Item $script:glbPath).LastWriteTime
$script:lastDeploy = Get-Date

# 部署动作（冷却 + 防占用 + 打包 + 部署）
function Invoke-Deploy {
    if (($(Get-Date) - $script:lastDeploy).TotalSeconds -lt $script:cooldownSeconds) { return }
    $script:lastDeploy = Get-Date

    # 等待文件写入稳定，并检查是否仍被 C4D 占用
    Start-Sleep -Seconds $script:quietSeconds
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
    if (-not $ready) { Log 'model.glb 仍被占用，跳过本次部署'; return }

    Log '检测到 model.glb 变化，开始自动打包...'
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
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $script:watchPath
$watcher.Filter = 'model.glb'
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size -bor [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::CreationTime

$action = {
    try {
        $script:lastWrite = (Get-Item $script:glbPath).LastWriteTime
    } catch { }
    Invoke-Deploy
}
Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action | Out-Null
$watcher.EnableRaisingEvents = $true

# 双保险 2：轮询 LastWriteTime（任何环境都可靠）
Log ("监控中：等待 model.glb 变化（每 $PollSeconds 秒检查一次，关闭窗口即停止）...")
while ($true) {
    Start-Sleep -Seconds $PollSeconds
    try {
        $now = (Get-Item $script:glbPath).LastWriteTime
        if ($now -ne $script:lastWrite) {
            $script:lastWrite = $now
            Invoke-Deploy
        }
    } catch { }
    # 泵 FileSystemWatcher 事件队列
    while ($null -ne (Wait-Event -Timeout 1)) { }
}
