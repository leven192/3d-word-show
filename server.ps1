# 零依赖的极简静态文件服务器（PowerShell，无需安装 Python/Node）
# 特性：gzip 压缩（.js/.html 等）、lib/ 目录浏览器缓存、空连接快速超时
# 用法: powershell -ExecutionPolicy Bypass -File server.ps1
# 默认端口 8000，可通过参数指定: -Port 9000

param(
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# MIME 类型表
$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.mjs'  = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.glb'  = 'model/gltf-binary'
    '.gltf' = 'model/gltf+json; charset=utf-8'
    '.bin'  = 'application/octet-stream'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.webp' = 'image/webp'
    '.gif'  = 'image/gif'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.txt'  = 'text/plain; charset=utf-8'
    '.woff' = 'font/woff'
    '.woff2'= 'font/woff2'
}

# 适合 gzip 的文件类型（.glb 等二进制已压缩，不再处理）
$compressible = @('.html', '.htm', '.css', '.js', '.mjs', '.json', '.gltf', '.svg', '.txt', '.ico')

function Send-Response {
    param($Stream, [int]$StatusCode, [string]$StatusText, [string]$ContentType, [byte[]]$Body,
          [switch]$Gzipped, [string]$CacheControl)

    $head = "HTTP/1.1 $StatusCode $StatusText`r`n" +
            "Content-Type: $ContentType`r`n" +
            "Content-Length: $($Body.Length)`r`n" +
            "Connection: close`r`n" +
            "Cache-Control: $CacheControl`r`n" +
            "Vary: Accept-Encoding`r`n" +
            "Access-Control-Allow-Origin: *`r`n"
    if ($Gzipped) { $head += "Content-Encoding: gzip`r`n" }
    $head += "`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    try {
        $Stream.Write($headBytes, 0, $headBytes.Length)
        if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
        $Stream.Flush()
    } catch {
        # 客户端断开，忽略
    }
}

function Compress-Gzip {
    param([byte[]]$Data)
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionLevel]::Optimal)
    $gz.Write($Data, 0, $Data.Length)
    $gz.Dispose()
    return $ms.ToArray()
}

function Handle-Client {
    param($Client)

    $stream = $null
    try {
        $stream = $Client.GetStream()
        $stream.ReadTimeout = 3000   # 空连接/慢连接 3 秒即放弃，避免阻塞后续请求

        # 读取请求头（请求行 + 头部，最多 16KB）
        $buffer = New-Object byte[] 16384
        $sb = New-Object System.Text.StringBuilder
        $headText = ''
        while ($sb.Length -lt 16384) {
            $n = $stream.Read($buffer, 0, $buffer.Length)
            if ($n -le 0) { break }
            [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $n))
            $acc = $sb.ToString()
            if ($acc.Contains("`r`n`r`n") -or $acc.Contains("`n`n")) { break }
        }
        $raw = $sb.ToString()
        if (-not $raw) { return }   # 空连接（预连接/探测），直接关闭

        $lines = $raw -split "`n"
        $requestLine = $lines[0].TrimEnd("`r")
        if (-not $requestLine) { return }

        $parts = $requestLine -split ' '
        if ($parts.Count -lt 2 -or $parts[0] -notin @('GET', 'HEAD')) {
            Send-Response $stream 405 'Method Not Allowed' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Method Not Allowed')) -CacheControl 'no-store'
            return
        }

        # 解析 Accept-Encoding
        $acceptGzip = $false
        foreach ($line in $lines) {
            $t = $line.TrimEnd("`r")
            if ($t -match '^Accept-Encoding\s*:' -and $t -match 'gzip') { $acceptGzip = $true; break }
        }

        # 解析路径
        $path = $parts[1]
        $path = [Uri]::UnescapeDataString($path)
        if ($path -match '^https?://') {
            $path = $path -replace '^https?://[^/]+', ''
        }
        $path = ($path -split '[?#]')[0]
        if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }

        # 请求日志（便于排查"哪个文件没加载出来"）
        Write-Host ("{0:HH:mm:ss}  {1}  {2}" -f (Get-Date), $parts[0], $path)

        $rel = $path.TrimStart('/') -replace '/', [IO.Path]::DirectorySeparatorChar
        $file = [IO.Path]::GetFullPath((Join-Path $root $rel))

        # 防目录穿越
        $rootFull = [IO.Path]::GetFullPath($root)
        if (-not $file.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            Send-Response $stream 403 'Forbidden' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Forbidden')) -CacheControl 'no-store'
            return
        }

        if (-not (Test-Path $file -PathType Leaf)) {
            $msg = "404 Not Found: $path"
            $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
            Send-Response $stream 404 'Not Found' 'text/plain; charset=utf-8' $bytes -CacheControl 'no-store'
            return
        }

        $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
        $contentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }

        # lib/ 目录缓存 1 天（库文件基本不变），其余不缓存（保证更新即时生效）
        $cacheControl = if ($path.StartsWith('/lib/')) { 'public, max-age=86400' } else { 'no-store' }

        $body = [IO.File]::ReadAllBytes($file)
        $gzipped = $false
        if ($acceptGzip -and $compressible.Contains($ext) -and $body.Length -gt 512) {
            $body = Compress-Gzip $body
            $gzipped = $true
        }
        Send-Response $stream 200 'OK' $contentType $body -Gzipped:$gzipped -CacheControl $cacheControl
    }
    catch {
        try { Send-Response $stream 500 'Internal Server Error' 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Server Error')) -CacheControl 'no-store' } catch {}
    }
    finally {
        try { $Client.Close() } catch {}
    }
}

# 启动时自动把 model.glb 内嵌为 model-embedded.js
# （页面直接用内存解析，不发起模型网络请求，任何浏览器/微信都不会卡在模型加载）
# 注意：内嵌失败（如 model.glb 正被 C4D 占用）不能阻断服务器启动，页面会回退到常规请求
$glbPath = Join-Path $root 'model.glb'
$embPath = Join-Path $root 'model-embedded.js'
try {
    if (Test-Path $glbPath) {
        $glbLen = (Get-Item $glbPath).Length
        if ($glbLen -lt 8MB) {
            $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($glbPath))
            [System.IO.File]::WriteAllText($embPath, "window.__EMBEDDED_GLB = '$b64';", (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "已内嵌模型 model.glb ($glbLen bytes) -> model-embedded.js" -ForegroundColor Green
        } else {
            Write-Host "模型超过 8MB 不内嵌（走常规请求路径）" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "警告：模型内嵌失败（model.glb 可能被占用），页面将回退到常规请求路径" -ForegroundColor Yellow
    Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkGray
}

# 端口可能因旧进程刚退出而短暂占用：重试绑定，避免闪退
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
for ($i = 1; $i -le 6; $i++) {
    try {
        $listener.Start()
        break
    } catch {
        if ($i -ge 6) {
            Write-Host "端口 $Port 无法绑定：$($_.Exception.Message)" -ForegroundColor Red
            Write-Host "请关闭占用该端口的程序后重试，或换端口：server.ps1 -Port 9000" -ForegroundColor Yellow
            Read-Host "按回车退出"
            exit 1
        }
        Write-Host "端口 $Port 仍被占用，1 秒后重试（$i/5）..." -ForegroundColor Yellow
        Start-Sleep -Seconds 1
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    }
}
Write-Host "GLB 查看器服务器已启动: http://localhost:$Port/  (gzip + 缓存已开启)"
Write-Host "根目录: $root"
Write-Host "按 Ctrl+C 停止"

while ($true) {
    try {
        $client = $listener.AcceptTcpClient()
        Handle-Client $client
    }
    catch {
        Write-Host "连接处理出错: $($_.Exception.Message)"
    }
}
