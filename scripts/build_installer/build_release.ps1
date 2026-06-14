# scripts/build_installer/build_release.ps1
#
# Wuthering Waves Convene Gacha Analyzer — Windows 一鍵打包腳本
#
# 流程：
#   1. 從 pubspec.yaml 讀版本號
#   2. 偵測 Inno Setup 6 與 Rust toolchain (cargo) 是否安裝
#   3. flutter pub get + flutter build windows --release
#   4. 呼叫 ISCC.exe 編譯 installer.iss
#   5. 報告產物路徑
#
# 用法：
#   .\scripts\build_installer\build_release.ps1

$ErrorActionPreference = 'Stop'

# 切到專案根目錄（以本腳本為基準往上一層）
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $ProjectRoot

# --- 1. 讀版本號 -------------------------------------------------------------
$PubspecPath = Join-Path $ProjectRoot 'pubspec.yaml'
if (-not (Test-Path $PubspecPath)) {
    throw "pubspec.yaml not found at: $PubspecPath"
}

$VersionLine = Select-String -Path $PubspecPath -Pattern '^version:\s*([^\s+]+)' | Select-Object -First 1
if (-not $VersionLine) {
    throw "Failed to parse version from pubspec.yaml"
}
$Version = $VersionLine.Matches[0].Groups[1].Value
Write-Host "Version: $Version" -ForegroundColor Cyan

# --- 2. 偵測 ISCC.exe ---------------------------------------------------------
function Find-ISCC {
    # 註冊表
    $RegKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1'
    )
    foreach ($key in $RegKeys) {
        if (Test-Path $key) {
            $loc = (Get-ItemProperty $key -ErrorAction SilentlyContinue).InstallLocation
            if ($loc) {
                $iscc = Join-Path $loc 'ISCC.exe'
                if (Test-Path $iscc) { return $iscc }
            }
        }
    }

    # 預設安裝路徑
    $FallbackPaths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    foreach ($p in $FallbackPaths) {
        if (Test-Path $p) { return $p }
    }

    # PATH lookup（CI 環境 / chocolatey 安裝走這條）
    $onPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    return $null
}

$ISCC = Find-ISCC
if (-not $ISCC) {
    Write-Host ""
    Write-Host "Inno Setup 6 not found. Please install:" -ForegroundColor Red
    Write-Host "  https://jrsoftware.org/isdl.php" -ForegroundColor Yellow
    Write-Host "  (requires 6.3 or above)" -ForegroundColor Yellow
    exit 1
}
Write-Host "Inno Setup: $ISCC" -ForegroundColor Cyan

# --- 2b. 偵測 cargo (Rust) ----------------------------------------------------
# Rust 編譯透過 cargokit 掛在 `flutter build windows` 的 CMake 流程上，缺 cargo
# 會在建置中段才爆且錯誤埋在 CMake log 裡，故先在此早早給出清楚提示。
$Cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $Cargo) {
    Write-Host ""
    Write-Host "Rust toolchain (cargo) not found. Please install:" -ForegroundColor Red
    Write-Host "  https://rustup.rs/" -ForegroundColor Yellow
    exit 1
}
Write-Host "Cargo: $($Cargo.Source)" -ForegroundColor Cyan

# --- 3. Flutter build --------------------------------------------------------
Write-Host ""
Write-Host "==> flutter pub get" -ForegroundColor Green
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

Write-Host ""
Write-Host "==> flutter build windows --release" -ForegroundColor Green
# webview_windows 第三方 plugin 仍引用已棄用的 <experimental/coroutine>，新版 MSVC
# （VS 18 / MSVC 14.51）已把它從警告升級成硬錯誤（C2338 / STL1011），導致建置中斷。
# 在 plugin 上游修正前，透過 MSVC 的 CL 環境變數全域注入官方建議的抑制巨集讓建置通過。
$SilenceCoroutine = '/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS'
$env:CL = if ($env:CL) { "$env:CL $SilenceCoroutine" } else { $SilenceCoroutine }
Write-Host "CL=$env:CL" -ForegroundColor DarkGray
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

# --- 3a. (Optional) Sign app exe before packaging --------------------------
if ($env:WINDOWS_SIGN_PFX_BASE64 -and $env:WINDOWS_SIGN_PASSWORD) {
    Write-Host ""
    Write-Host "==> Signing app exe (TODO: signtool)" -ForegroundColor Yellow
    # TODO(signing): 用 base64 還原 pfx, 呼叫 signtool sign /f ... /p ... build\windows\x64\runner\Release\*.exe
}
else {
    Write-Host ""
    Write-Host "==> Skip app exe signing (no cert configured)" -ForegroundColor DarkGray
}

# --- 3b. WebView2 Evergreen Bootstrapper（安裝檔隨附，缺 Runtime 時靜默安裝）-----
# 喚取立繪功能依賴 WebView2。多數 Win10/11 已內建 Runtime；少數缺的機器由安裝程式
# 偵測後靜默補裝（見 installer.iss 的 WebView2NotInstalled / [Run]）。此處於編譯安裝檔
# 前把官方 Bootstrapper 下載到 installer.iss 同目錄供其嵌入。
$WebView2Setup = Join-Path $PSScriptRoot 'MicrosoftEdgeWebview2Setup.exe'
if (-not (Test-Path $WebView2Setup)) {
    Write-Host ""
    Write-Host "==> Downloading WebView2 Evergreen Bootstrapper" -ForegroundColor Green
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' `
        -OutFile $WebView2Setup -UseBasicParsing
}
Write-Host "WebView2 Bootstrapper: $WebView2Setup" -ForegroundColor Cyan

# --- 4. 編譯安裝檔 ----------------------------------------------------------
$InstallerDir = Join-Path $ProjectRoot 'build\installer'
New-Item -ItemType Directory -Force $InstallerDir | Out-Null

$IssPath = Join-Path $ProjectRoot 'scripts\build_installer\installer.iss'

Write-Host ""
Write-Host "==> ISCC compile" -ForegroundColor Green
& $ISCC "/DMyAppVersion=$Version" $IssPath
if ($LASTEXITCODE -ne 0) { throw "ISCC compile failed" }

# --- 4a. (Optional) Sign installer after ISCC ------------------------------
if ($env:WINDOWS_SIGN_PFX_BASE64 -and $env:WINDOWS_SIGN_PASSWORD) {
    Write-Host ""
    Write-Host "==> Signing installer (TODO: signtool)" -ForegroundColor Yellow
    # TODO(signing): signtool sign /f ... /p ... <installer.exe>
}
else {
    Write-Host ""
    Write-Host "==> Skip installer signing (no cert configured)" -ForegroundColor DarkGray
}

# --- 5. 報告產物 -------------------------------------------------------------
$Output = Join-Path $InstallerDir "Wuthering_Waves_Convene_Gacha_Analyzer-Setup-$Version.exe"
Write-Host ""
Write-Host "Done! Output:" -ForegroundColor Green
Write-Host "  $Output" -ForegroundColor Cyan
