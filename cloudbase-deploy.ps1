# ============================================================
#  CloudBase 静态托管一键部署脚本
#  功能: 检查 tcb -> 检查登录 -> 部署「发布/」到 CloudBase 静态托管 -> 提示缓存刷新
#  用法: powershell -NoProfile -ExecutionPolicy Bypass -File cloudbase-deploy.ps1 [-EnvId <环境ID>] [-NoPrompt]
# ============================================================
param(
    [string]$EnvId = 'baigukeji-d6g7omgxc78b09a62',
    [string]$SiteUrl = 'https://naigukeji-baigukeji-d6g7omgxc78b09a62.webapps.tcloudbase.com/',
    [switch]$NoPrompt
)
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$src = Join-Path $root '发布'

if (-not (Test-Path $src)) {
    Write-Host "未找到发布目录: $src（请先双击「启动.bat」生成）" -ForegroundColor Red
    if (-not $NoPrompt) { Read-Host "按回车退出" }
    exit 1
}

# 1) 检查 tcb CLI
$tcb = Get-Command tcb -ErrorAction SilentlyContinue
if (-not $tcb) {
    Write-Host "未安装 CloudBase CLI (tcb)。安装命令：" -ForegroundColor Yellow
    Write-Host "  1) 安装 Node.js: https://nodejs.org  或  winget install OpenJS.NodeJS.LTS"
    Write-Host "  2) npm i -g @cloudbase/cli"
    Write-Host "装好后重新运行本脚本。"
    if (-not $NoPrompt) { Read-Host "按回车退出" }
    exit 1
}

# 2) 检查登录状态（未登录则交互登录一次）
$probe = & tcb env list 2>&1
if ($LASTEXITCODE -ne 0 -or ($probe -match '无有效身份信息|请使用.*login')) {
    Write-Host "需要登录腾讯云账号..." -ForegroundColor Cyan
    Write-Host "将打开登录流程，请在弹出的页面确认授权。" -ForegroundColor DarkGray
    & tcb login
    Start-Sleep -Seconds 2
    $probe = & tcb env list 2>&1
    if ($LASTEXITCODE -ne 0 -or ($probe -match '无有效身份信息')) {
        Write-Host "登录失败，请手动运行: tcb login" -ForegroundColor Red
        if (-not $NoPrompt) { Read-Host "按回车退出" }
        exit 1
    }
}

# 3) 部署（发布/ 全量上传到静态托管根路径，忽略说明 txt）
Write-Host "正在部署: $src" -ForegroundColor Cyan
Write-Host "目标环境: $EnvId" -ForegroundColor Cyan
& tcb hosting deploy $src -e $EnvId --ignore "*.txt" 2>&1 | ForEach-Object { Write-Output $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Host "部署失败（exit $LASTEXITCODE）。请检查：登录状态 / 环境 ID / 网络。" -ForegroundColor Red
    if (-not $NoPrompt) { Read-Host "按回车退出" }
    exit 1
}

# 4) 结果
Write-Host ""
Write-Host "============== 部署完成 ===============" -ForegroundColor Green
Write-Host "网站地址: $SiteUrl" -ForegroundColor Green
Write-Host "缓存: CDN 会在数分钟内自动刷新（无需手动操作）；急用可浏览器无痕模式验证" -ForegroundColor DarkGray
if (-not $NoPrompt) { Read-Host "按回车退出" }
