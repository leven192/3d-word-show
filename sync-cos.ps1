# ============================================================
#  同步发布包到腾讯云 COS（增量上传：只传新增/修改过的文件）
#
#  功能：
#   1. 自动检测 coscli（未安装则自动从 GitHub 下载）
#   2. 首次运行引导输入 SecretId / SecretKey 并保存配置
#   3. 用 coscli sync 增量同步「发布」文件夹到存储桶
#   4. 同步完成后打印网站访问地址并自测
#
#  用法：powershell -NoProfile -ExecutionPolicy Bypass -File 同步到COS.ps1
# ============================================================

param(
    [string]$Bucket = 'my-3d-site-1469467156',
    [string]$Region = 'ap-guangzhou',
    [string]$SourceDir = ''
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $SourceDir) { $SourceDir = Join-Path $root '发布' }
if (-not (Test-Path $SourceDir)) {
    Write-Host "未找到发布目录: $SourceDir" -ForegroundColor Red
    Write-Host "请先双击「生成发布包.bat」生成发布包，再运行本脚本。" -ForegroundColor Yellow
    Read-Host "按回车退出"
    exit 1
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  同步到腾讯云 COS" -ForegroundColor Cyan
Write-Host "  存储桶: $Bucket  地域: $Region" -ForegroundColor Cyan
Write-Host "  本地目录: $SourceDir" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# ---------- 1) 检测 / 下载 coscli ----------
$coscli = $null
$candidates = @()
$cmd = Get-Command coscli -ErrorAction SilentlyContinue
if ($cmd) { $candidates += $cmd.Source }
$candidates += (Join-Path $root 'coscli.exe')
$candidates += (Join-Path $root 'coscli-windows-amd64.exe')
$candidates += (Join-Path $env:USERPROFILE 'coscli.exe')
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { $coscli = $c; break }
}

if (-not $coscli) {
    Write-Host ""
    Write-Host "未检测到 coscli，正在自动下载（约 14MB）..." -ForegroundColor Cyan
    $exe = Join-Path $root 'coscli.exe'
    $urls = @(
        'https://cosbrowser.cloud.tencent.com/software/coscli/coscli-windows-amd64.exe',
        'https://github.com/tencentyun/coscli/releases/latest/download/coscli-windows-amd64.exe'
    )
    $downloaded = $false
    foreach ($u in $urls) {
        try {
            Invoke-WebRequest -Uri $u -OutFile $exe -UseBasicParsing -TimeoutSec 180
            if ((Get-Item $exe).Length -gt 1000000) { $downloaded = $true; break }
        } catch { }
    }
    if ($downloaded) {
        $coscli = $exe
        Write-Host "下载完成: $exe" -ForegroundColor Green
    } else {
        Write-Host "自动下载失败，请手动安装 coscli：" -ForegroundColor Red
        Write-Host "  A) 腾讯官方源: https://cosbrowser.cloud.tencent.com/software/coscli/coscli-windows-amd64.exe"
        Write-Host "  B) 官方文档  : https://cloud.tencent.com/document/product/436/63144"
        Write-Host "下载后把文件重命名为 coscli.exe，放到本脚本所在目录，再重新运行本脚本。"
        Read-Host "按回车退出"
        exit 1
    }
}

# 确认 coscli 可运行
try {
    $ver = & $coscli --version 2>&1 | Select-Object -First 1
    Write-Host "coscli 就绪: $ver" -ForegroundColor Green
} catch {
    Write-Host "coscli 无法运行：$($_.Exception.Message)" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

# ---------- 2) 检查 / 配置凭据（coscli v1.0.x 使用 $HOME/.cos.yaml，密钥加密存储） ----------
$configPath = Join-Path $HOME '.cos.yaml'
function Test-CoscliAuth {
    # 实测验证密钥可用（配置存在但密钥无效时会在这里失败）
    & $coscli ls "cos://$Bucket/" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

$configured = $false
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw
    if ($cfg -match 'secretid:\s*\S') { $configured = $true }
}

function Ask-Credentials {
    Write-Host ""
    Write-Host "需要配置腾讯云 API 密钥（只保存在本机）。" -ForegroundColor Cyan
    Write-Host "获取方式：腾讯云控制台 -> 访问管理 CAM -> API 密钥管理 -> 新建密钥" -ForegroundColor DarkGray
    $sid = Read-Host "请输入 SecretId"
    $skey = Read-Host "请输入 SecretKey"
    if (-not $sid -or -not $skey) {
        Write-Host "密钥不能为空。" -ForegroundColor Red
        Read-Host "按回车退出"
        exit 1
    }
    Write-Host "正在写入 coscli 配置（加密存储）..." -ForegroundColor Cyan
    & $coscli config add -i $sid -k $skey -b $Bucket -r $Region -a main 2>&1 | Out-Null
    Start-Sleep -Seconds 1
}

if (-not $configured -or -not (Test-CoscliAuth)) {
    Ask-Credentials
    if (-not (Test-CoscliAuth)) {
        Write-Host ""
        Write-Host "密钥校验失败：SecretId/SecretKey 可能不正确，或网络不通。" -ForegroundColor Red
        Write-Host "请确认密钥复制完整（可在 https://console.cloud.tencent.com/cam/capi 查看）。" -ForegroundColor Yellow
        Read-Host "按回车退出"
        exit 1
    }
}
Write-Host "coscli 凭据校验通过" -ForegroundColor Green

# ---------- 3) 增量同步 ----------
Write-Host ""
Write-Host "开始增量同步（只上传新增/修改的文件）..." -ForegroundColor Cyan
$src = (($SourceDir -replace '\\', '/').TrimEnd('/')) + '/'
$dst = "cos://$Bucket/"
& $coscli sync $src $dst -r
if ($LASTEXITCODE -ne 0) {
    Write-Host "同步失败（exit $LASTEXITCODE）。" -ForegroundColor Red
    Write-Host "请检查：密钥是否正确 / 存储桶名称地域是否匹配 / 网络是否通畅。" -ForegroundColor Yellow
    Read-Host "按回车退出"
    exit 1
}

# ---------- 4) 打印访问地址 + 自测 ----------
$siteUrl = "https://$Bucket.cos-website.$Region.myqcloud.com"
Write-Host ""
Write-Host "=============== 同步完成 ===============" -ForegroundColor Green
Write-Host "网站访问地址: $siteUrl" -ForegroundColor Green
Write-Host "把这个链接发给微信好友即可（电脑关机也能访问）" -ForegroundColor Green
Write-Host ""
Write-Host "正在自测..." -ForegroundColor DarkGray
try {
    $resp = Invoke-WebRequest -Uri $siteUrl -TimeoutSec 15 -UseBasicParsing
    Write-Host "自测: HTTP $($resp.StatusCode) OK，网站可正常访问" -ForegroundColor Green
} catch {
    Write-Host "自测: 暂时无法访问" -ForegroundColor Yellow
    Write-Host "请检查：1) COS 控制台已开启「静态网站」且索引文档为 index.html" -ForegroundColor Yellow
    Write-Host "        2) 存储桶访问权限为「公有读」（或配置了授权）" -ForegroundColor Yellow
    Write-Host "        3) 刚上传的文件需要几秒到几分钟生效" -ForegroundColor Yellow
}
Read-Host "按回车退出"
