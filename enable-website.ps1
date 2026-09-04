# ============================================================
#  开启腾讯云 COS 存储桶的「静态网站」功能（一键）
#  用法: powershell -NoProfile -ExecutionPolicy Bypass -File enable-website.ps1
#  说明：从 ~/.cos.yaml 读取密钥（sync-cos.ps1 配置的），
#        用 COS V5 签名调用 PUT ?website 开启静态网站。
# ============================================================

$ErrorActionPreference = 'Stop'
$Bucket = 'my-3d-site-1469467156'
$Region = 'ap-guangzhou'
$bucketHost = "$Bucket.cos.$Region.myqcloud.com"

# 从 coscli 配置读取密钥（明文模式）
$cfgPath = Join-Path $HOME '.cos.yaml'
$sid = ''
$skey = ''
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw
    if ($cfg -match '(?m)^\s*secretid:\s*"?([^\s""]+)') { $sid = $Matches[1] }
    if ($cfg -match '(?m)^\s*secretkey:\s*"?([^\s""]+)') { $skey = $Matches[1] }
}
if (-not $sid -or -not $skey) {
    Write-Host "未在 ~/.cos.yaml 中找到密钥，请先运行 sync-cos.ps1 配置，或手动输入：" -ForegroundColor Yellow
    $sid = Read-Host "SecretId"
    $skey = Read-Host "SecretKey"
}
if (-not $sid -or -not $skey) { Write-Host "密钥不能为空"; Read-Host "按回车退出"; exit 1 }

function Hex([byte[]]$b) { return ([BitConverter]::ToString($b) -replace '-', '').ToLower() }

# COS V5 签名
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$keyTime = "$now;$($now + 600)"
$httpString = "put`n/`nwebsite=`nhost=$bucketHost`n"
$sha1 = [System.Security.Cryptography.SHA1]::Create()
$httpStringHash = Hex($sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes($httpString)))
$stringToSign = "sha1`n$keyTime`n$httpStringHash`n"
$hmac = [System.Security.Cryptography.HMACSHA1]::new([Text.Encoding]::UTF8.GetBytes($skey))
$signKey = Hex($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($keyTime)))
$signature = Hex($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign)))
$auth = "q-sign-algorithm=sha1&q-ak=$sid&q-sign-time=$keyTime&q-key-time=$keyTime&q-header-list=host&q-url-param-list=website&q-signature=$signature"

# 请求体：索引文档 index.html
$body = '<?xml version="1.0" encoding="UTF-8"?><WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument></WebsiteConfiguration>'
$bodyFile = Join-Path $env:TEMP 'cos-website.xml'
[System.IO.File]::WriteAllText($bodyFile, $body, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "正在开启静态网站（PUT ?website）..." -ForegroundColor Cyan
$respFile = Join-Path $env:TEMP 'cos-website-resp.txt'
Remove-Item $respFile -Force -ErrorAction SilentlyContinue
$code = & curl.exe -s -o $respFile -w "%{http_code}" -X PUT "https://$bucketHost/?website" -H "Host: $bucketHost" -H "Authorization: $auth" -H "Content-Type: application/xml" --data-binary "@$bodyFile" 2>&1

Write-Host ("HTTP 状态码: " + $code) -ForegroundColor $(if ($code -eq '200') { 'Green' } else { 'Red' })
if (Test-Path $respFile) {
    $respBody = Get-Content $respFile -Raw
    if ($respBody -match '<Code>([^<]+)</Code>') {
        Write-Host ("错误: " + $Matches[1]) -ForegroundColor Red
        if ($respBody -match '<Message>([^<]+)</Message>') { Write-Host ("  " + $Matches[1]) -ForegroundColor Yellow }
    }
}

if ($code -eq '200') {
    Write-Host ""
    Write-Host "静态网站已开启！" -ForegroundColor Green
    Write-Host "访问地址: https://$Bucket.cos-website.$Region.myqcloud.com" -ForegroundColor Green
    Write-Host "（若显示权限错误，请确认存储桶访问权限为「公有读私有写」）" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "开启失败。请尝试：控制台 -> 对象存储 COS -> 存储桶 -> 基础配置 -> 静态网站 -> 开启" -ForegroundColor Yellow
}
Read-Host "按回车退出"
