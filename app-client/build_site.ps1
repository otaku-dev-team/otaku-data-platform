# 按站烘焙客户端（Windows / PowerShell 版）。与 build_site.sh 等价。
#
# 用法：
#   .\build_site.ps1 -Site otaku
#   .\build_site.ps1 -Site otaku -BuildMode debug
#   .\build_site.ps1 -Site otaku -Target apk -BuildMode debug
#   .\build_site.ps1 -Site otaku -DryRun
#   .\build_site.ps1 -List
#
# 值来自 sites\<site>\site.conf，格式与 bash 版共用一份文件。
# 边界见 docs/site-branding.md §3：图标与 Windows 包标识仍需人工替换。

[CmdletBinding()]
param(
    [string]$Site,
    [ValidateSet('windows', 'apk')][string]$Target = 'windows',
    [ValidateSet('debug', 'profile', 'release')][string]$BuildMode = 'release',
    [switch]$DryRun,
    [switch]$List,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Write-Say([string]$Message) { Write-Host "[build_site] $Message" }
function Stop-Fail([string]$Message) {
    Write-Host "[build_site] 失败：$Message" -ForegroundColor Red
    exit 1
}

function Show-Sites {
    $dirs = Get-ChildItem -Path sites -Directory -ErrorAction SilentlyContinue
    if (-not $dirs) {
        Write-Say 'sites\ 下没有站点'
        return
    }
    foreach ($d in $dirs) {
        if (Test-Path (Join-Path $d.FullName 'site.conf')) { Write-Host "  $($d.Name)" }
    }
}

function Get-ConfValue([string]$Key, [string]$Path) {
    $match = Select-String -Path $Path -Pattern "^\s*$Key\s*=" | Select-Object -Last 1
    if (-not $match) { return '' }
    $value = ($match.Line -split '=', 2)[1].Trim()
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Format-Arg([string]$Value) {
    if ($Value -match '[\s"]') { return '"' + $Value.Replace('"', '\"') + '"' }
    return $Value
}

if ($Help) {
    Write-Host @'
按站烘焙客户端 —— 一条命令出这个站的包。

用法：
  .\build_site.ps1 -Site <站点键> [-Target windows|apk] [-BuildMode debug|profile|release] [-DryRun]
  .\build_site.ps1 -List

参数：
  -Site       必填。sites\<键>\site.conf 里的站点
  -Target     windows（默认）| apk
  -BuildMode  debug | profile | release（默认）
  -DryRun     只打印命令，不构建
  -List       列出已有站点
'@
    exit 0
}

if ($List) {
    Write-Say '已有站点：'
    Show-Sites
    exit 0
}

if (-not $Site) { Stop-Fail '缺少 -Site（-List 看有哪些站）' }

$conf = Join-Path 'sites' (Join-Path $Site 'site.conf')
if (-not (Test-Path $conf)) {
    Write-Say "找不到 $conf"
    Show-Sites
    exit 1
}

$required = @('SITE_ID', 'APP_NAME', 'BRAND_COMPANY', 'APP_ID', 'API_BASE_URL')
foreach ($key in $required) {
    if (-not (Get-ConfValue $key $conf)) { Stop-Fail "$conf 缺少 $key（或值为空）" }
}

$siteId = Get-ConfValue 'SITE_ID' $conf
$appName = Get-ConfValue 'APP_NAME' $conf
$brandCompany = Get-ConfValue 'BRAND_COMPANY' $conf
$appId = Get-ConfValue 'APP_ID' $conf
$apiBaseUrl = Get-ConfValue 'API_BASE_URL' $conf
# 可选：来源站地址（HTML 页面，给 App 内 WebView 登录 / 注册用）。
# 不填不报错，只是登录页不显示站点入口——与不注入时的默认行为一致。
$siteBaseUrl = Get-ConfValue 'SITE_BASE_URL' $conf

if (-not ($apiBaseUrl -match '^https?://')) {
    Stop-Fail "API_BASE_URL 要以 http:// 或 https:// 开头，当前：$apiBaseUrl"
}
if ($siteBaseUrl -and -not ($siteBaseUrl -match '^https?://')) {
    Stop-Fail "SITE_BASE_URL 要以 http:// 或 https:// 开头，当前：$siteBaseUrl"
}
if ($Target -eq 'apk' -and $BuildMode -eq 'release' -and $apiBaseUrl -match '^http://') {
    Write-Say '注意：release 包连的是明文 HTTP，Android 会拒绝（release 只认 HTTPS）'
    Write-Say '      联调请用 -BuildMode debug，或等域名到位换成 https://'
}

$flutterArgs = @(
    'build', $Target, "--$BuildMode",
    "--dart-define=APP_NAME=$appName",
    "--dart-define=SITE_ID=$siteId",
    "--dart-define=BRAND_COMPANY=$brandCompany",
    "--dart-define=API_BASE_URL=$apiBaseUrl"
)
if ($siteBaseUrl) {
    $flutterArgs += "--dart-define=SITE_BASE_URL=$siteBaseUrl"
}
if ($Target -eq 'apk') {
    $flutterArgs += "-PappName=$appName"
    $flutterArgs += "-PappId=$appId"
}

Write-Say "站点：$Site（$siteId）"
Write-Say "应用名：$appName ｜ 归属：$brandCompany ｜ 包名：$appId"
Write-Say "后端：$apiBaseUrl"
if ($siteBaseUrl) {
    Write-Say "站点：$siteBaseUrl（App 内登录 / 注册）"
} else {
    Write-Say '站点地址未配置（SITE_BASE_URL）——App 内登录入口将不显示'
}
$printed = ($flutterArgs | ForEach-Object { Format-Arg $_ }) -join ' '
Write-Say "命令：flutter $printed"

if ($DryRun) {
    Write-Say '-DryRun：没有构建'
    exit 0
}

& flutter @flutterArgs
if ($LASTEXITCODE -ne 0) { Stop-Fail "flutter build 退出码 $LASTEXITCODE" }

$cfg = 'Release'
if ($BuildMode -eq 'debug') { $cfg = 'Debug' }
if ($BuildMode -eq 'profile') { $cfg = 'Profile' }

if ($Target -eq 'windows') {
    $exe = Get-ChildItem -Path 'build/windows' -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\runner\\$cfg\\" } |
        Select-Object -First 1
    if (-not $exe) { Stop-Fail "构建结束了但没找到产物（windows/$BuildMode）" }
    $artifact = $exe.FullName
} else {
    $artifact = "build/app/outputs/flutter-apk/app-$BuildMode.apk"
    if (-not (Test-Path $artifact)) { Stop-Fail "构建结束了但没找到产物（apk/$BuildMode）" }
}

$sizeKb = [math]::Round((Get-Item $artifact).Length / 1KB)
Write-Say "产物：$artifact（${sizeKb} KB）"

# 品牌自检：字符串缺失只警告，不判失败（AOT 可能优化掉，硬门槛会造假红）。
$dataDir = Join-Path (Split-Path $artifact -Parent) 'data'
$hit = $null
foreach ($probe in @((Join-Path $dataDir 'flutter_assets/kernel_blob.bin'), (Join-Path $dataDir 'app.so'))) {
    if ((Test-Path $probe) -and -not $hit) {
        try {
            $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($probe))
            if ($text.Contains($appName)) { $hit = $probe }
        } catch {
            # 读不了就当没验到，继续看下一个探针
        }
    }
}
if ($hit) {
    Write-Say "品牌自检：产物里找到了「$appName」（$(Split-Path $hit -Leaf)）"
} else {
    Write-Say "品牌自检：产物里没找到「$appName」——不一定是错（AOT 可能优化掉），"
    Write-Say '          但首站交付前请人工开一次 App 确认应用名与窗口标题'
}

Write-Say '还剩两件手工的（docs/site-branding.md §3）：'
Write-Say '  - 图标：android/app/src/main/res/mipmap-*/ic_launcher.png 与 windows/runner/resources/app_icon.ico'
Write-Say '  - Windows 包标识：windows/runner/Runner.rc 的 CompanyName / ProductName / FileDescription'
