#!/bin/bash
# Linux-версия iPod Converter (GTK4 + libadwaita). Запускать на Linux (Ubuntu 24.04+, Fedora 40+…).
# Нужны: Swift 6 (swiftly), pkg-config, libgtk-4-dev, libadwaita-1-dev; для работы — ffmpeg.
#   Ubuntu/Debian: sudo apt install ffmpeg libadwaita-1-dev libgtk-4-dev pkg-config
# Результат: build-linux/ipod-converter — один файл, Swift внутри (--static-swift-stdlib).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --static-swift-stdlib --scratch-path .build-linux
mkdir -p build-linux
cp .build-linux/release/iPodConverter build-linux/ipod-converter
strip build-linux/ipod-converter || true
echo "Готово: build-linux/ipod-converter"
echo "Окно: ./build-linux/ipod-converter   Консоль: ./build-linux/ipod-converter convert --ipod nano7 --max ФАЙЛЫ"
