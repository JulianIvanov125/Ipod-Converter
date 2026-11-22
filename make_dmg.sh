#!/bin/bash
# Собирает приложение и упаковывает его в build/iPod-Converter-<версия>.dmg
# (внутри — «iPod Converter.app» и ярлык «Applications» для перетаскивания).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

APP="build/iPod Converter.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="build/iPod-Converter-${VERSION}.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "iPod Converter ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify -quiet "$DMG"

echo "Готово: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
