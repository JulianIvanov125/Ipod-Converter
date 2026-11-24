#!/bin/bash
# Пакеты Linux-версии: .deb (Ubuntu/Debian/Mint/Pop!_OS) и .tar.gz (любой дистрибутив).
# Запускать на Linux той архитектуры, для которой собираем (x86_64 или aarch64).
#   ./make_linux_packages.sh            → build-linux/ipod-converter_<версия>_<arch>.deb и .tar.gz
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Info.plist)
case "$(uname -m)" in
    x86_64) DEBARCH=amd64; TARARCH=x86_64 ;;
    aarch64|arm64) DEBARCH=arm64; TARARCH=aarch64 ;;
    *) echo "Неизвестная архитектура $(uname -m)"; exit 1 ;;
esac
APPID=io.github.ipodconverter.linux

./build_linux.sh
OUT=build-linux
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Общая раскладка файлов (как в /usr)
install_tree() {
    local root="$1"
    install -Dm755 "$OUT/ipod-converter" "$root/usr/bin/ipod-converter"
    install -Dm644 linux/$APPID.desktop "$root/usr/share/applications/$APPID.desktop"
    install -Dm644 linux/$APPID.metainfo.xml "$root/usr/share/metainfo/$APPID.metainfo.xml"
    for s in 64 128 256 512; do
        install -Dm644 "linux/icons/$APPID-$s.png" "$root/usr/share/icons/hicolor/${s}x${s}/apps/$APPID.png"
    done
    install -Dm644 LICENSE "$root/usr/share/doc/ipod-converter/copyright"
    install -Dm644 docs/LINUX.md "$root/usr/share/doc/ipod-converter/README.md"
}

# .deb
DEB="$STAGE/deb"
install_tree "$DEB"
mkdir -p "$DEB/DEBIAN"
SIZE=$(du -sk "$DEB/usr" | cut -f1)
cat > "$DEB/DEBIAN/control" <<CTL
Package: ipod-converter
Version: $VERSION
Section: video
Priority: optional
Architecture: $DEBARCH
Depends: ffmpeg, libgtk-4-1 (>= 4.12), libadwaita-1-0 (>= 1.4), libc6 (>= 2.35), libstdc++6, libgcc-s1
Recommends: libgtk-4-media-gstreamer, gstreamer1.0-libav, gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad, rhythmbox | strawberry | gtkpod
Installed-Size: $SIZE
Maintainer: Julian Ivanov <ivanovulian@gmail.com>
Homepage: https://github.com/JulianIvanov125/Ipod-Converter
Description: Convert music and videos for classic iPods
 Converts videos and music so they play on iPod 5G/5.5G, iPod classic,
 iPod nano and iPod touch: resolution and H.264 profile for each model
 (Standard or Maximum quality), AAC audio without clipping, tags and covers.
 Finds duplicate videos. Copy the results to the iPod with Rhythmbox,
 gtkpod or Strawberry.
CTL
cat > "$DEB/DEBIAN/postinst" <<'PI'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
PI
chmod 755 "$DEB/DEBIAN/postinst"
cp "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$DEB" "$OUT/ipod-converter_${VERSION}_${DEBARCH}.deb" >/dev/null

# .tar.gz: те же файлы + install.sh (ставит в ~/.local, без sudo)
TARDIR="$STAGE/ipod-converter-$VERSION-$TARARCH"
install_tree "$TARDIR"
cat > "$TARDIR/install.sh" <<'IS'
#!/bin/sh
# Установка в ~/.local (без sudo). Нужны ffmpeg, GTK 4.12+ и libadwaita 1.4+ из вашего дистрибутива.
set -e
cd "$(dirname "$0")"
PREFIX="${PREFIX:-$HOME/.local}"
cp -r usr/bin usr/share "$PREFIX/"
sed -i "s|^Exec=ipod-converter|Exec=$PREFIX/bin/ipod-converter|" "$PREFIX/share/applications/io.github.ipodconverter.linux.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$PREFIX/share/applications" || true
echo "Installed to $PREFIX. Start “iPod Converter” from the app menu or run: $PREFIX/bin/ipod-converter"
command -v ffmpeg >/dev/null || echo "Note: ffmpeg is not installed — install it with your package manager."
IS
chmod 755 "$TARDIR/install.sh"
tar -C "$STAGE" -czf "$OUT/ipod-converter-$VERSION-$TARARCH.tar.gz" "$(basename "$TARDIR")"
(cd "$OUT" && sha256sum "ipod-converter_${VERSION}_${DEBARCH}.deb" "ipod-converter-$VERSION-$TARARCH.tar.gz")
