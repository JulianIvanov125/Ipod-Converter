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
codesign --force --deep -s - "$APP"

echo "Готово: $(pwd)/$APP"
