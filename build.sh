#!/bin/bash
# Собирает «iPod Converter.app» в папку build/.
set -euo pipefail
cd "$(dirname "$0")"

# SDK 27 из Command Line Tools требует макро-плагин SwiftUI, которого нет без Xcode → берём SDK 26.x
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$SDK" ] && [ ! -d /Applications/Xcode.app ]; then export SDKROOT="$SDK"; fi
swift build -c release

APP="build/iPod Converter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/iPodConverter "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

# Встроенный ffmpeg (собирается ./build_ffmpeg.sh). Без него приложение возьмёт ffmpeg из Homebrew.
if [ -x vendor/ffmpeg/ffmpeg ] && [ -x vendor/ffmpeg/ffprobe ]; then
    cp vendor/ffmpeg/ffmpeg vendor/ffmpeg/ffprobe "$APP/Contents/Resources/"
    codesign --force -s - "$APP/Contents/Resources/ffmpeg" "$APP/Contents/Resources/ffprobe"
    echo "ffmpeg встроен"
else
    echo "Внимание: vendor/ffmpeg нет — приложению понадобится brew install ffmpeg (соберите ./build_ffmpeg.sh)"
fi
codesign --force --deep -s - "$APP"

echo "Готово: $(pwd)/$APP"
