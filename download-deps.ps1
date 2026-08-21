# 一次性下载 three.js / lil-gui 到本地 lib/ 目录（之后页面秒开，不再依赖任何 CDN）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File download-deps.ps1

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$libDir = Join-Path $root 'lib'

if (-not (Test-Path $libDir)) { New-Item -ItemType Directory -Path $libDir | Out-Null }

function Get-FileWithFallback {
    param([string]$Out, [string[]]$Urls)
    foreach ($u in $Urls) {
        try {
            Write-Host "下载: $u"
            Invoke-WebRequest -Uri $u -OutFile $Out -UseBasicParsing -TimeoutSec 60
            $len = (Get-Item $Out).Length
            if ($len -gt 0) {
                Write-Host "   -> OK ($len bytes)"
                return $true
            }
        }
        catch {
            Write-Host "   -> 失败: $($_.Exception.Message)"
        }
    }
    return $false
}

$sources = @{
    'three.module.js'  = @(
        'https://registry.npmmirror.com/three/0.160.0/files/build/three.module.js',
        'https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.module.js',
        'https://unpkg.com/three@0.160.0/build/three.module.js'
    )
    'OrbitControls.js' = @(
        'https://registry.npmmirror.com/three/0.160.0/files/examples/jsm/controls/OrbitControls.js',
        'https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/controls/OrbitControls.js',
        'https://unpkg.com/three@0.160.0/examples/jsm/controls/OrbitControls.js'
    )
    'GLTFLoader.js'    = @(
        'https://registry.npmmirror.com/three/0.160.0/files/examples/jsm/loaders/GLTFLoader.js',
        'https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/loaders/GLTFLoader.js',
        'https://unpkg.com/three@0.160.0/examples/jsm/loaders/GLTFLoader.js'
    )
    'utils/BufferGeometryUtils.js' = @(
        'https://registry.npmmirror.com/three/0.160.0/files/examples/jsm/utils/BufferGeometryUtils.js',
        'https://cdn.jsdelivr.net/npm/three@0.160.0/examples/jsm/utils/BufferGeometryUtils.js',
        'https://unpkg.com/three@0.160.0/examples/jsm/utils/BufferGeometryUtils.js'
    )
    'lil-gui.esm.min.js' = @(
        'https://registry.npmmirror.com/lil-gui/0.20.0/files/dist/lil-gui.esm.min.js',
        'https://cdn.jsdelivr.net/npm/lil-gui@0.20.0/dist/lil-gui.esm.min.js',
        'https://unpkg.com/lil-gui@0.20.0/dist/lil-gui.esm.min.js'
    )
    'qrcode.min.js' = @(
        # node-qrcode 浏览器构建（build/qrcode.js 或 build/qrcode.min.js，多版本候选）
        'https://registry.npmmirror.com/qrcode/latest/files/build/qrcode.js',
        'https://cdn.jsdelivr.net/npm/qrcode/build/qrcode.js',
        'https://unpkg.com/qrcode/build/qrcode.js',
        'https://registry.npmmirror.com/qrcode/1.5.4/files/build/qrcode.js',
        'https://cdn.jsdelivr.net/npm/qrcode@1.5.4/build/qrcode.js',
        'https://unpkg.com/qrcode@1.5.4/build/qrcode.js',
        'https://registry.npmmirror.com/qrcode/1.5.1/files/build/qrcode.js',
        'https://cdn.jsdelivr.net/npm/qrcode@1.5.1/build/qrcode.js',
        'https://unpkg.com/qrcode@1.5.1/build/qrcode.js',
        'https://registry.npmmirror.com/qrcode/latest/files/build/qrcode.min.js',
        'https://cdn.jsdelivr.net/npm/qrcode/build/qrcode.min.js',
        'https://unpkg.com/qrcode/build/qrcode.min.js'
    )
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  下载 three.js / lil-gui 本地依赖（一次性）" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

$ok = $true
New-Item -ItemType Directory -Path (Join-Path $libDir 'utils') -Force | Out-Null
foreach ($name in $sources.Keys) {
    $out = Join-Path $libDir $name
    if (Test-Path $out) {
        Write-Host "已存在，跳过: $name"
        continue
    }
    if (-not (Get-FileWithFallback -Out $out -Urls $sources[$name])) { $ok = $false }
}

# 修补 addons 的裸导入 'three' -> 相对路径（这样无需 importmap，老内核/微信也能加载）
foreach ($f in @('OrbitControls.js', 'GLTFLoader.js')) {
    $p = Join-Path $libDir $f
    if (Test-Path $p) {
        $content = [System.IO.File]::ReadAllText($p)
        if ($content -match "from 'three';") {
            $patched = $content -replace "from 'three';", "from './three.module.js';"
            [System.IO.File]::WriteAllText($p, $patched, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "已修补 $f ：'three' 导入改为相对路径（老内核兼容）" -ForegroundColor Green
        } elseif ($content -match "from './three.module.js';") {
            Write-Host "$f 已是相对路径导入（无需修补）" -ForegroundColor DarkGray
        } else {
            Write-Host "警告: $f 中未找到 'three' 导入，格式可能不同" -ForegroundColor Yellow
        }
        # GLTFLoader 依赖的 utils 相对路径修正
        if ($content -match "from '../utils/BufferGeometryUtils.js';") {
            $patched = $content -replace "from '../utils/BufferGeometryUtils.js';", "from './utils/BufferGeometryUtils.js';"
            [System.IO.File]::WriteAllText($p, $patched, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "已修补 $f ：utils 路径改为 ./utils/（本地兼容）" -ForegroundColor Green
        }
    }
}
# BufferGeometryUtils 的 'three' 导入修正（它在 lib/utils/ 下，相对 three 是上一级）
$bfu = Join-Path $libDir 'utils\BufferGeometryUtils.js'
if (Test-Path $bfu) {
    $bc = [System.IO.File]::ReadAllText($bfu)
    if ($bc -match "from 'three';") {
        [System.IO.File]::WriteAllText($bfu, $bc -replace "from 'three';", "from '../three.module.js';", (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "已修补 utils/BufferGeometryUtils.js ：'three' 导入改为相对路径" -ForegroundColor Green
    } elseif ($bc -match "from '../three.module.js';") {
        Write-Host "utils/BufferGeometryUtils.js 已是相对路径导入（无需修补）" -ForegroundColor DarkGray
    }
}

Write-Host ""
if ($ok) {
    Write-Host "依赖下载完成！" -ForegroundColor Green
    Write-Host "现在双击「启动.bat」或「启动-分享.bat」即可，页面将使用本地依赖秒开，任何浏览器/微信都能快速加载。" -ForegroundColor Green
} else {
    Write-Host "部分文件下载失败，请检查网络后重新运行本脚本。" -ForegroundColor Yellow
}
Read-Host "按回车退出"
