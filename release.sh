#!/bin/bash
# Выпуск новой версии одной командой:
#   ./release.sh 1.1 notes.md
# Поднимает версию в Info.plist, коммитит, собирает DMG, пушит и публикует релиз v<версия> на GitHub.
# Запускать в ветке main.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"

VERSION="${1:?Укажите версию, например 1.1}"
NOTES="${2:?Укажите файл с release notes}"
[ -f "$NOTES" ] || { echo "Нет файла $NOTES"; exit 1; }
# Работа идёт в tested-branch; релиз — только из main, куда проверенное вливается отдельно:
#   git checkout main && git merge --ff-only tested-branch
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "Релиз выпускается только из main (сейчас: $(git rev-parse --abbrev-ref HEAD))"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Есть незакоммиченные изменения — сначала коммит"; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "Тег v$VERSION уже есть"; exit 1; }

# Версия: CFBundleShortVersionString = 1.1, CFBundleVersion = число коммитов (растёт само)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(git rev-list --count HEAD) + 1 ))" Info.plist
git commit -q -am "Release $VERSION"

./make_dmg.sh
DMG="build/iPod-Converter-${VERSION}.dmg"

git push -q
gh release create "v$VERSION" "$DMG" --target main --title "iPod Converter $VERSION" --notes-file "$NOTES"
echo "Опубликовано: v$VERSION"
