# Windows-версия iPod Converter: окно WinUI 3 (windows/WinUI) + Swift-движок (iPodConverter.exe serve) + ffmpeg.
# Запускать на Windows. Нужны: Swift для Windows, Visual Studio Build Tools (C++ для ARM64/x64 и Windows SDK), .NET SDK 9;
# ffmpeg.exe и ffprobe.exe нужной архитектуры — папка в -FFmpegDir (или в PATH).
#   powershell -ExecutionPolicy Bypass -File build_windows.ps1 -Arch x64 -FFmpegDir C:\Tools\ffmpeg-win64\bin
# На ARM64-машине x64 собирается кросс-компиляцией (и запускается там же через эмуляцию — можно проверить).
# Результат: build-windows\<arch>\iPod Converter\ и архив build-windows\iPod-Converter-<версия>-Windows-<arch>.zip
param(
    [ValidateSet("arm64", "x64")][string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }),
    [string]$FFmpegDir = "",
    [string]$Version = ""   # по умолчанию — из Info.plist
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# Версия — та же, что у Mac-приложения (Info.plist поднимает release.sh).
$plist = Get-Content Info.plist -Raw
$version = if ($Version) { $Version } else { [regex]::Match($plist, "<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>").Groups[1].Value }
$triple = if ($Arch -eq "arm64") { "aarch64-unknown-windows-msvc" } else { "x86_64-unknown-windows-msvc" }
$out = Join-Path $PSScriptRoot "build-windows\$Arch"
$dist = Join-Path $out "iPod Converter"
$engineDir = Join-Path $dist "engine"

Write-Host "== Swift engine $version ($triple)"
# Рантайм Swift вшит в exe (-static-stdlib): устанавливать Swift пользователю не нужно, DLL рядом не нужны.
swift build -c release --build-system native --triple $triple --scratch-path ".build-win-$Arch" -Xswiftc -static-stdlib
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }

Write-Host "== WinUI window ($Arch)"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish windows\WinUI\iPodConverter.WinUI.csproj -c Release -r "win-$Arch" -p:Platform=$($Arch.ToUpper()) -p:Version=$version -o $dist
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

Write-Host "== engine + ffmpeg"
New-Item -ItemType Directory -Force $engineDir | Out-Null
Copy-Item ".build-win-$Arch\$triple\release\iPodConverter.exe" $engineDir
if (-not $FFmpegDir) { $FFmpegDir = Split-Path ((Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source) }
foreach ($t in "ffmpeg.exe", "ffprobe.exe") {
    $src = Join-Path $FFmpegDir $t
    if (-not (Test-Path $src)) { throw "$t not found in $FFmpegDir" }
    Copy-Item $src $engineDir
}
Copy-Item LICENSE, THIRD_PARTY_NOTICES.md $dist

Write-Host "== zip"
$zip = Join-Path $PSScriptRoot "build-windows\iPod-Converter-$version-Windows-$Arch.zip"
if (Test-Path $zip) { Remove-Item $zip }
tar.exe -a -c -f $zip -C $out "iPod Converter"
if ($LASTEXITCODE -ne 0) { throw "zip failed" }
$size = (Get-Item $zip).Length / 1MB
Write-Host ("Done: {0}  ({1:N0} MB)" -f $zip, $size)
