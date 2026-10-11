# ============================================================
#  大小周历 · 局域网服务
#  零依赖：Windows 自带 PowerShell + .NET 即可运行，无需安装 Node / Python
#  用法：双击「启动局域网服务.bat」
#
#  数据文件：data.json           （排班配置，所有访问者共用）
#  配置文件：server-config.json  （端口、管理员密码）
# ============================================================
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$HtmlFile  = Join-Path $Root "大小周历.html"
$DataFile  = Join-Path $Root "data.json"
$ConfFile  = Join-Path $Root "server-config.json"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------- 读取服务配置 ----------------
$Port          = 8080
$AdminPassword = "admin123"
if (Test-Path $ConfFile) {
  try {
    $c = [System.IO.File]::ReadAllText($ConfFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($c.port)          { $Port = [int]$c.port }
    if ($c.adminPassword) { $AdminPassword = [string]$c.adminPassword }
  } catch {
    Write-Host "[警告] server-config.json 解析失败，改用默认配置。" -ForegroundColor Yellow
  }
} else {
  $init = @{ port = $Port; adminPassword = $AdminPassword } | ConvertTo-Json
  [System.IO.File]::WriteAllText($ConfFile, $init, $Utf8NoBom)
  Write-Host "[初始化] 已生成 server-config.json（默认管理员密码 admin123）。" -ForegroundColor Cyan
}

# ---------------- 数据（排班配置） ----------------
function New-DefaultCfg {
  $d      = Get-Date
  $offset = (([int]$d.DayOfWeek + 6) % 7)   # 周一记 0
  $mon    = $d.AddDays(-$offset)
  return [ordered]@{
    startMonday = $mon.ToString("yyyy-MM-dd")
    mode        = "odd"
    sat         = $true
    sun         = $false
    onlyBig     = $true
    hours       = 8
    ov          = ""
    extraHol    = ""
  }
}

function Get-SafeCfg($o) {
  $safe = New-DefaultCfg
  if ($o) {
    foreach ($k in @("startMonday", "mode", "sat", "sun", "onlyBig", "hours", "ov", "extraHol")) {
      $v = $o.$k
      if ($null -ne $v) { $safe[$k] = $v }
    }
  }
  if ($safe.startMonday -notmatch '^\d{4}-\d{2}-\d{2}$') { $safe.startMonday = (New-DefaultCfg).startMonday }
  if ($safe.mode -ne "odd" -and $safe.mode -ne "even")    { $safe.mode = "odd" }
  $safe.sat     = [bool]$safe.sat
  $safe.sun     = [bool]$safe.sun
  $safe.onlyBig = [bool]$safe.onlyBig
  $h = 0.0
  [void][double]::TryParse([string]$safe.hours, [ref]$h)
  if ($h -lt 1)  { $h = 1 }
  if ($h -gt 16) { $h = 16 }
  $safe.hours = $h
  if ($null -eq $safe.ov)       { $safe.ov = "" }
  if ($null -eq $safe.extraHol) { $safe.extraHol = "" }
  return $safe
}

function New-Ms { return [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

$script:Data = @{ cfg = (New-DefaultCfg); mtime = (New-Ms) }

function Save-Data {
  $script:Data.mtime = New-Ms
  $json = $script:Data | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($DataFile, $json, $Utf8NoBom)
}

function Load-Data {
  if (-not (Test-Path $DataFile)) { Save-Data; return }
  try {
    $o = [System.IO.File]::ReadAllText($DataFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($o -and $o.cfg) {
      $script:Data.cfg = $o.cfg
      if ($o.mtime) { $script:Data.mtime = [long]$o.mtime }
    }
  } catch {
    Write-Host "[警告] data.json 读取失败：$($_.Exception.Message)" -ForegroundColor Yellow
  }
}
Load-Data

# ---------------- 管理员会话 ----------------
$script:Sessions = @{}
$SessionTTL = 12 * 3600   # 12 小时

function New-Token {
  $t = [guid]::NewGuid().ToString("N")
  $script:Sessions[$t] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $SessionTTL
  return $t
}
function Test-Admin($token) {
  if (-not $token) { return $false }
  $exp = $script:Sessions[$token]
  if ($null -eq $exp) { return $false }
  if ($exp -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { $script:Sessions.Remove($token); return $false }
  return $true
}

# ---------------- HTTP 小工具 ----------------
function Write-Response($stream, [int]$code, [string]$ctype, [byte[]]$body) {
  $reason = switch ($code) {
    200 { "OK" } 204 { "No Content" } 400 { "Bad Request" }
    401 { "Unauthorized" } 404 { "Not Found" } 405 { "Method Not Allowed" }
    default { "OK" }
  }
  $head = "HTTP/1.1 $code $reason`r`n" +
          "Content-Type: $ctype`r`n" +
          "Content-Length: $($body.Length)`r`n" +
          "Cache-Control: no-store`r`n" +
          "Access-Control-Allow-Origin: *`r`n" +
          "Access-Control-Allow-Headers: Content-Type, X-Admin-Token`r`n" +
          "Access-Control-Allow-Methods: GET, POST, OPTIONS`r`n" +
          "Connection: close`r`n`r`n"
  $hb = [System.Text.Encoding]::UTF8.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}
function Write-Json($stream, [int]$code, $obj) {
  $json = $obj | ConvertTo-Json -Depth 12 -Compress
  Write-Response $stream $code "application/json; charset=utf-8" ([System.Text.Encoding]::UTF8.GetBytes($json))
}
function Write-Text($stream, [int]$code, [string]$text) {
  Write-Response $stream $code "text/plain; charset=utf-8" ([System.Text.Encoding]::UTF8.GetBytes($text))
}

function New-BadRequest {
  return @{ method = ""; url = ""; headers = @{}; body = (New-Object byte[] 0) }
}

function Read-Request($stream) {
  # 浏览器常会预先建立空闲连接（preconnect），首字节迟迟不来。
  # 真实请求的首字节在 TCP 建连后几乎立刻到达，所以这里只等 500ms：
  # 拿不到数据就当作空闲连接立即关闭，避免占住服务拖慢其他人。
  $wait = 0
  while (-not $stream.DataAvailable -and $wait -lt 500) {
    Start-Sleep -Milliseconds 20
    $wait += 20
  }
  if (-not $stream.DataAvailable) { return $null }

  $ms   = New-Object System.IO.MemoryStream
  $buf  = New-Object byte[] 16384
  $end  = -1
  try { $stream.ReadTimeout = 15000 } catch {}
  while ($end -lt 0) {
    $n = $stream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $ms.Write($buf, 0, $n)
    $arr = $ms.ToArray()
    for ($i = 0; $i -le $arr.Length - 4; $i++) {
      if ($arr[$i] -eq 13 -and $arr[$i + 1] -eq 10 -and $arr[$i + 2] -eq 13 -and $arr[$i + 3] -eq 10) {
        $end = $i + 4; break
      }
    }
    if ($ms.Length -gt 65536 -and $end -lt 0) { break }
  }
  if ($end -lt 0) { return (New-BadRequest) }

  $arr        = $ms.ToArray()
  $headerText = [System.Text.Encoding]::UTF8.GetString($arr, 0, $end)
  $lines      = $headerText -split "`r`n"
  $parts      = $lines[0] -split " "
  if ($parts.Length -lt 2) { return (New-BadRequest) }

  $headers = @{}
  for ($i = 1; $i -lt $lines.Length; $i++) {
    $ln = $lines[$i]
    if (-not $ln) { continue }
    $p = $ln.IndexOf(":")
    if ($p -gt 0) { $headers[$ln.Substring(0, $p).Trim().ToLower()] = $ln.Substring($p + 1).Trim() }
  }

  $len = 0
  if ($headers.ContainsKey("content-length")) { [void][int]::TryParse($headers["content-length"], [ref]$len) }
  if ($len -lt 0) { $len = 0 }
  if ($len -gt 4194304) { return (New-BadRequest) }   # 上限 4MB，异常请求直接拒绝，避免耗尽内存
  $body = New-Object byte[] $len
  if ($len -gt 0) {
    $have = $arr.Length - $end
    if ($have -gt $len) { $have = $len }
    if ($have -lt 0)    { $have = 0 }
    if ($have -gt 0)    { [Array]::Copy($arr, $end, $body, 0, $have) }
    $read = $have
    while ($read -lt $len) {
      $n = $stream.Read($body, $read, $len - $read)
      if ($n -le 0) { break }
      $read += $n
    }
  }

  return @{ method = $parts[0].ToUpper(); url = $parts[1]; headers = $headers; body = $body }
}

# ---------------- 路由 ----------------
function Handle-Request($stream) {
  $req = Read-Request $stream
  if ($null -eq $req) { return }                                  # 空闲连接，静默关闭
  if (-not $req.method) { Write-Text $stream 400 "Bad Request"; return }

  $method = $req.method
  $path   = $req.url
  $qi     = $path.IndexOf("?")
  if ($qi -ge 0) { $path = $path.Substring(0, $qi) }
  $path   = [System.Uri]::UnescapeDataString($path)
  $token  = $req.headers["x-admin-token"]

  if ($method -eq "OPTIONS") { Write-Response $stream 204 "text/plain; charset=utf-8" (New-Object byte[] 0); return }

  if ($path -eq "/api/config") {
    if ($method -eq "GET") {
      Write-Json $stream 200 @{ cfg = $script:Data.cfg; mtime = $script:Data.mtime; admin = (Test-Admin $token) }
      return
    }
    if ($method -eq "POST") {
      if (-not (Test-Admin $token)) { Write-Json $stream 401 @{ error = "unauthorized" }; return }
      try {
        $txt = [System.Text.Encoding]::UTF8.GetString($req.body)
        $o   = $txt | ConvertFrom-Json
        if ($null -eq $o.cfg) { Write-Json $stream 400 @{ error = "missing cfg" }; return }
        $script:Data.cfg = Get-SafeCfg $o.cfg
        Save-Data
        Write-Host ("[{0}] 管理员已更新排班配置" -f (Get-Date -Format "MM-dd HH:mm:ss")) -ForegroundColor Green
        Write-Json $stream 200 @{ ok = $true; mtime = $script:Data.mtime }
      } catch {
        Write-Json $stream 400 @{ error = $_.Exception.Message }
      }
      return
    }
    Write-Json $stream 405 @{ error = "method not allowed" }
    return
  }

  if ($path -eq "/api/login" -and $method -eq "POST") {
    try {
      $o = [System.Text.Encoding]::UTF8.GetString($req.body) | ConvertFrom-Json
      if ($o.password -eq $AdminPassword) { Write-Json $stream 200 @{ token = (New-Token) } }
      else {
        Write-Host ("[{0}] 管理员登录失败（密码错误）" -f (Get-Date -Format "MM-dd HH:mm:ss")) -ForegroundColor Yellow
        Write-Json $stream 401 @{ error = "wrong password" }
      }
    } catch { Write-Json $stream 400 @{ error = "bad request" } }
    return
  }

  if ($path -eq "/api/logout" -and $method -eq "POST") {
    if ($token) { $script:Sessions.Remove($token) }
    Write-Json $stream 200 @{ ok = $true }
    return
  }

  if ($path -eq "/api/session" -and $method -eq "GET") {
    Write-Json $stream 200 @{ admin = (Test-Admin $token) }
    return
  }

  if ($path -eq "/api/ping") { Write-Json $stream 200 @{ ok = $true }; return }

  if ($method -eq "GET" -and ($path -eq "/" -or $path -eq "/index.html")) {
    if (Test-Path $HtmlFile) {
      Write-Response $stream 200 "text/html; charset=utf-8" ([System.IO.File]::ReadAllBytes($HtmlFile))
    } else {
      Write-Text $stream 500 "未找到 大小周历.html，请确认它与 server.ps1 在同一目录。"
    }
    return
  }

  Write-Text $stream 404 "Not Found"
}

# ---------------- 启动 ----------------
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
try {
  $listener.Start()
} catch {
  Write-Host ""
  Write-Host "启动失败：端口 $Port 可能已被占用。" -ForegroundColor Red
  Write-Host "请关闭占用该端口的程序，或修改 server-config.json 里的 port 换一个端口。" -ForegroundColor Red
  Write-Host ""
  Read-Host "按回车键退出"
  exit 1
}

$ips = @()
try {
  $ips = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.OperationalStatus -eq "Up" } |
    ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
    Where-Object {
      $_.Address.AddressFamily -eq "InterNetwork" -and
      $_.Address.IPAddressToString -notlike "127.*" -and
      $_.Address.IPAddressToString -notlike "169.254.*"
    } |
    ForEach-Object { $_.Address.IPAddressToString } |
    Select-Object -Unique
} catch {}

Write-Host ""
Write-Host "  大小周历 · 局域网服务已启动" -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "  本机访问：   http://localhost:$Port/"
if ($ips) {
  foreach ($ip in $ips) { Write-Host "  同事访问：   http://${ip}:$Port/" -ForegroundColor Green }
} else {
  Write-Host "  （未检测到局域网 IP，请用 ipconfig 查看本机地址）" -ForegroundColor Yellow
}
Write-Host "  管理员密码： $AdminPassword   （改 server-config.json 后重启生效）"
Write-Host ""
Write-Host "  数据保存在 data.json；所有访问者看到同一份排班。" -ForegroundColor DarkGray
Write-Host "  首次运行若弹出防火墙提示，请选择「允许访问」，否则同事无法打开。" -ForegroundColor DarkGray
Write-Host "  按 Ctrl+C 可停止服务。" -ForegroundColor DarkGray
Write-Host ""

while ($true) {
  $client = $listener.AcceptTcpClient()
  try {
    $client.ReceiveTimeout = 15000
    $client.SendTimeout    = 15000
    Handle-Request $client.GetStream()
  } catch {
    # 单个请求出错不影响服务继续运行
  } finally {
    try { $client.Close() } catch {}
  }
}
