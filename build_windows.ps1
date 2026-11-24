# Windows-версия iPod Converter: окно WinUI 3 (windows/WinUI) + Swift-движок (iPodConverter.exe serve) + ffmpeg.
# Запускать на Windows (ARM64 или x64). Нужны: Swift для Windows, Visual Studio Build Tools (C++ и Windows SDK),
# .NET SDK 9; ffmpeg.exe и ffprobe.exe — путь в -FFmpegDir или в PATH.
#   powershell -ExecutionPolicy Bypass -File build_windows.ps1 [-FFmpegDir C:\Tools\ffmpeg\bin]
# Результат: build-windows\iPod Converter\ — запуск «iPod Converter.exe».
param([string]$FFmpegDir = "")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$dist = Join-Path $PSScriptRoot "build-windows\iPod Converter"
$engineDir = Join-Path $dist "engine"

Write-Host "== Swift-движок"
swift build -c release
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }

Write-Host "== Окно WinUI ($arch)"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
dotnet publish windows\WinUI\iPodConverter.WinUI.csproj -c Release -r "win-$arch" -p:Platform=$($arch.ToUpper()) -o $dist
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

Write-Host "== Движок и библиотеки Swift"
New-Item -ItemType Directory -Force $engineDir | Out-Null
Copy-Item ".build\release\iPodConverter.exe" $engineDir
# Рантайм Swift (swiftCore.dll, Foundation.dll…) — рядом с движком, чтобы не требовать установленный Swift.
$core = (Get-Command swiftCore.dll -ErrorAction SilentlyContinue).Source
if (-not $core) { throw "swiftCore.dll not found in PATH" }
Get-ChildItem (Split-Path $core) -Filter *.dll | Copy-Item -Destination $engineDir

Write-Host "== ffmpeg"
if (-not $FFmpegDir) { $FFmpegDir = Split-Path ((Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source) }
foreach ($t in "ffmpeg.exe", "ffprobe.exe") {
    $src = Join-Path $FFmpegDir $t
    if (-not (Test-Path $src)) { throw "$t not found in $FFmpegDir" }
    Copy-Item $src $engineDir
}
Copy-Item LICENSE, THIRD_PARTY_NOTICES.md $dist

$size = (Get-ChildItem $dist -Recurse | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("Готово: {0}  ({1:N0} МБ)" -f $dist, $size)
