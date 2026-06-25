@echo off
setlocal EnableExtensions

REM Gitea runner / Rust / Tauri / Dioxus desktop build toolchain.
REM Skips during OOBE first-logon (a:\); runs when packer executes C:\Windows\Temp\script.bat.
if exist C:\build-tools-installed exit /b 0
echo %~f0 | findstr /I "Windows\\Temp" >nul
if errorlevel 1 exit /b 0

REM MSVC linker + Windows SDK (required for Rust on Windows)
choco install visualstudio2022buildtools -y --package-parameters "--passive --norestart"
choco install visualstudio2022-workload-vctools -y --package-parameters "--includeRecommended --passive --norestart"

REM WebView2 runtime (Tauri + Dioxus desktop)
choco install microsoft-edge-webview2 -y

REM Rust (MSVC toolchain is selected below)
choco install rust -y

set "PATH=%USERPROFILE%\.cargo\bin;%PATH%"
rustup default stable-msvc
rustup target add x86_64-pc-windows-msvc

REM Version control + JS runtime for Tauri frontends
choco install git -y
choco install nodejs-lts -y

REM Installer bundling (Tauri MSI / NSIS)
choco install wixtoolset -y
choco install nsis -y

REM Common native build helpers for Rust crates
choco install cmake -y
choco install ninja -y
choco install 7zip.install -y

REM Gitea act_runner (register manually with: act_runner register)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$dir='C:\Program Files\gitea-act-runner';" ^
  "New-Item -ItemType Directory -Force -Path $dir | Out-Null;" ^
  "$release = Invoke-RestMethod 'https://gitea.com/api/v1/repos/gitea/act_runner/releases/latest';" ^
  "$asset = $release.assets | Where-Object { $_.name -match 'windows-amd64\.exe$' } | Select-Object -First 1;" ^
  "if (-not $asset) { throw 'act_runner windows-amd64 release asset not found' };" ^
  "Invoke-WebRequest -Uri $asset.browser_download_url -OutFile (Join-Path $dir 'act_runner.exe');" ^
  "$machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine');" ^
  "if ($machinePath -notlike ('*' + $dir + '*')) { [Environment]::SetEnvironmentVariable('PATH', $machinePath.TrimEnd(';') + ';' + $dir, 'Machine') }"

echo installed > C:\build-tools-installed
exit /b 0
