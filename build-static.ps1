# 生成静态发布包：把查看器打包成可直接上传托管服务的文件
# （部署后即使电脑关机，链接也能正常访问）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File build-static.ps1 [-NoPrompt]

param(
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root '发布'

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  生成静态发布包 -> 发布/ 文件夹" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1) 清空并重建发布目录（只删内容，避免文件夹被占用时报错）
if (Test-Path $dist) {
    Get-ChildItem $dist -Force | Remove-Item -Recurse -Force
}
New-Item -ItemType Directory -Path $dist -Force | Out-Null

# 2) 本地依赖库
$libDir = Join-Path $dist 'lib'
New-Item -ItemType Directory -Path $libDir | Out-Null
$ok = $true
foreach ($f in @('three.module.js', 'OrbitControls.js', 'GLTFLoader.js', 'lil-gui.esm.min.js', 'qrcode.min.js')) {
    $src = Join-Path $root "lib\$f"
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $libDir $f)
        Write-Host "已复制 lib\$f"
    } else {
        # qrcode 缺失只警告（二维码会回退 CDN），其余缺失则发布包不完整
        if ($f -eq 'qrcode.min.js') {
            Write-Host "提示：lib\$f 不存在（二维码将回退 CDN，可运行「启动.bat」自动下载）" -ForegroundColor DarkGray
        } else {
            Write-Host "缺少 lib\$f —— 请先运行「启动.bat」自动下载" -ForegroundColor Yellow
            $ok = $false
        }
    }
}

# 3) 内嵌模型（从当前 model.glb 重新生成）
$glb = Join-Path $root 'model.glb'
if (Test-Path $glb) {
    $len = (Get-Item $glb).Length
    if ($len -lt 8MB) {
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($glb))
        [System.IO.File]::WriteAllText((Join-Path $dist 'model-embedded.js'), "window.__EMBEDDED_GLB = '$b64';", (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "已内嵌模型 model.glb ($len bytes) -> model-embedded.js"
    } else {
        Copy-Item $glb (Join-Path $dist 'model.glb')
        Write-Host "模型超过 8MB，走请求路径：需一并上传 model.glb" -ForegroundColor Yellow
    }
} else {
    Write-Host "警告：未找到 model.glb，发布后页面将提示模型缺失" -ForegroundColor Yellow
}

# 4) 页面与模型文件
Copy-Item (Join-Path $root 'index.html') (Join-Path $dist 'index.html')
if (Test-Path $glb) { Copy-Item $glb (Join-Path $dist 'model.glb') }

# 5) 多设备配置与模型目录（models.json + models/ + thumbs/）
$cfg = Join-Path $root 'models.json'
if (Test-Path $cfg) {
    Copy-Item $cfg (Join-Path $dist 'models.json')
    Write-Host "已复制 models.json（设备清单）"
} else {
    Write-Host "缺少 models.json —— 页面将无法显示设备列表" -ForegroundColor Yellow
    $ok = $false
}
$modelsDir = Join-Path $root 'models'
if (Test-Path $modelsDir) {
    Copy-Item $modelsDir (Join-Path $dist 'models') -Recurse -Force
    Write-Host "已复制 models/ 目录（device-02..10 模型）"
}
$thumbsDir = Join-Path $root 'thumbs'
if (Test-Path $thumbsDir) {
    Copy-Item $thumbsDir (Join-Path $dist 'thumbs') -Recurse -Force
    Write-Host "已复制 thumbs/ 目录（缩略图）"
}

# 6) 上传说明
$readme = @"
============================================
  发布包已生成！把「发布」文件夹里的全部内容
  上传到托管服务后，电脑关机也能通过链接访问。
============================================

【推荐方案】腾讯云 COS 静态网站托管（国内快，微信可打开）
  1. 注册/登录腾讯云，完成实名认证（免费）
  2. 控制台 -> 对象存储 COS -> 创建存储桶
     - 名称随意，地域选离你近的（如成都/重庆）
     - 访问权限选「公有读私有写」
  3. 存储桶 -> 基础配置 -> 静态网站 -> 开启
     （索引文档填 index.html）
  4. 把「发布」文件夹里的所有文件上传到存储桶根目录
  5. 存储桶 -> 域名管理 -> 复制「静态网站域名」访问
     形如: https://xxx.cos-website.ap-chengdu.myqcloud.com
  费用：免费额度内基本不花钱，超出后按存储/流量计费（很小）

【备选方案】
  - 阿里云 OSS 静态网站（与 COS 类似，流程相同）
  - Gitee Pages（免费，需实名认证 + 仓库审核）
  - Vercel（免费，把「发布」文件夹拖进 https://vercel.com 即可，
    但国内访问可能不稳定）

【更新模型】
  1. 设备 1：导出新的 model.glb 后重新生成发布包即可（「启动.bat」会自动部署）
  2. 设备 2~10：把 C4D 导出的 GLB 放到 models/ 文件夹，
     命名对应 models.json 里的路径（如 models/device-02.glb），
     然后重新生成发布包并上传/部署
  3. 缩略图：把图片放到 thumbs/ 文件夹，并在 models.json 里填写
     thumbnail 路径；不填则页面自动显示编号占位图

【注意事项】
  - 部署后页面会自动把当前访问地址作为分享链接，
    无需再配置 cpolar 公网地址
  - 微信打开若提示拦截，点右上角「在浏览器中打开」即可
  - 首次打开会加载 lib/ 库（约 300KB gzip），正常网络几秒完成
  - 切换设备时按需加载 GLB，自动释放上一台设备的内存；
    模型缺失会提示「模型加载失败」，不影响其他设备浏览
"@
[System.IO.File]::WriteAllText((Join-Path $dist '上传说明.txt'), $readme, (New-Object System.Text.UTF8Encoding($true)))

Write-Host ""
if ($ok) {
    Write-Host "发布包生成完成：" -ForegroundColor Green
    Write-Host "  $dist" -ForegroundColor Green
    Write-Host "把该文件夹里的所有内容上传到托管服务即可（步骤见「上传说明.txt」）" -ForegroundColor Green
} else {
    Write-Host "发布包生成不完整（缺少依赖库），请先运行「下载依赖.bat」后重试。" -ForegroundColor Yellow
}
if (-not $NoPrompt) { Read-Host "按回车退出" }
