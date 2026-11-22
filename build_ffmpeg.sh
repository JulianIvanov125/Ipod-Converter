#!/bin/bash
# Собирает самодостаточные ffmpeg и ffprobe (arm64, macOS 14+) для встраивания в приложение.
#   ./build_ffmpeg.sh [путь к ffmpeg-<версия>.tar.xz]
# Без аргумента скачивает исходники с ffmpeg.org и сверяет SHA-256 с формулой Homebrew.
# Нужны Homebrew-пакеты x264, lame и mpg123 (из них берутся только статические .a),
# а для dav1d (программный декодер AV1) — meson, ninja и nasm: его собираем из исходников статически.
# Результат: vendor/ffmpeg/ffmpeg и vendor/ffmpeg/ffprobe — без зависимостей от Homebrew.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"
ROOT=$(pwd)
VER=9.0.2
OUT="$ROOT/vendor/ffmpeg"
# Сборка — во временной папке без пробелов: configure у ffmpeg не понимает пробелы в путях флагов.
WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/ipodconverter-ffmpeg-build"
case "$WORK" in *" "*) WORK="/tmp/ipodconverter-ffmpeg-build" ;; esac
mkdir -p "$OUT" "$WORK"

TARBALL="${1:-$WORK/ffmpeg-$VER.tar.xz}"
if [ ! -f "$TARBALL" ]; then
    curl -sL -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
    WANT=$(brew info --json=v2 ffmpeg | python3 -c "import sys,json; print(json.load(sys.stdin)['formulae'][0]['urls']['stable']['checksum'])")
    [ "$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)" = "$WANT" ] || { echo "SHA-256 не совпал"; exit 1; }
fi

# Статические библиотеки — в отдельную папку без .dylib, чтобы линкер не взял динамические.
DEPS="$WORK/deps"
rm -rf "$DEPS"; mkdir -p "$DEPS/lib/pkgconfig" "$DEPS/include"
X264=$(brew --prefix x264); LAME=$(brew --prefix lame); MPG123=$(brew --prefix mpg123)
# libmp3lame из Homebrew собран с декодером mpg123 — его статическая библиотека тоже нужна.
cp "$X264/lib/libx264.a" "$LAME/lib/libmp3lame.a" "$MPG123/lib/libmpg123.a" "$DEPS/lib/"
cp "$X264"/include/x264*.h "$DEPS/include/"
cp -R "$LAME/include/lame" "$DEPS/include/"
cat > "$DEPS/lib/pkgconfig/x264.pc" <<PC
prefix=$DEPS
Name: x264
Description: H.264 encoder (static)
Version: $(pkg-config --modversion x264)
Libs: -L$DEPS/lib -lx264 -lpthread -lm
Cflags: -I$DEPS/include
PC

# dav1d — декодер AV1 для Mac без аппаратного AV1 (M1/M2). Исходники сверяем с формулой Homebrew.
DAV1D_VER=$(brew info --json=v2 dav1d | python3 -c "import sys,json; print(json.load(sys.stdin)['formulae'][0]['versions']['stable'])")
DAV1D_SHA=$(brew info --json=v2 dav1d | python3 -c "import sys,json; print(json.load(sys.stdin)['formulae'][0]['urls']['stable']['checksum'])")
DAV1D_TAR="$WORK/dav1d-$DAV1D_VER.tar.bz2"
[ -f "$DAV1D_TAR" ] || curl -sL -o "$DAV1D_TAR" "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VER/dav1d-$DAV1D_VER.tar.bz2"
[ "$(shasum -a 256 "$DAV1D_TAR" | cut -d' ' -f1)" = "$DAV1D_SHA" ] || { echo "SHA-256 dav1d не совпал"; exit 1; }
rm -rf "$WORK/dav1d-$DAV1D_VER"; tar -xf "$DAV1D_TAR" -C "$WORK"
( cd "$WORK/dav1d-$DAV1D_VER" &&
  CFLAGS="-mmacosx-version-min=14.0" meson setup build --prefix="$DEPS" --libdir=lib --buildtype=release \
      --default-library=static -Denable_tools=false -Denable_tests=false > "$WORK/dav1d.log" 2>&1 &&
  ninja -C build install >> "$WORK/dav1d.log" 2>&1 ) || { tail -5 "$WORK/dav1d.log"; exit 1; }

SRC="$WORK/ffmpeg-$VER"
rm -rf "$SRC"; tar -xf "$TARBALL" -C "$WORK"
cd "$SRC"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"   # только наши .pc — никакого Homebrew
./configure \
    --arch=arm64 --cc=clang \
    --disable-autodetect \
    --enable-gpl --enable-version3 \
    --enable-libx264 --enable-libmp3lame --enable-libdav1d \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-zlib --enable-bzlib --enable-iconv \
    --disable-shared --enable-static \
    --disable-ffplay --disable-doc --disable-debug --disable-network \
    --pkg-config-flags=--static \
    --extra-cflags="-I$DEPS/include -mmacosx-version-min=14.0" \
    --extra-ldflags="-L$DEPS/lib -mmacosx-version-min=14.0" \
    --extra-libs="-lmpg123 -liconv" > "$WORK/configure.log" || { tail -5 "$WORK/configure.log"; exit 1; }
make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe > "$WORK/make.log" 2>&1 || { grep -E "error" "$WORK/make.log" | head -5; exit 1; }
strip ffmpeg ffprobe
cp ffmpeg ffprobe "$OUT/"
echo "Готово: $OUT ($(du -sh "$OUT" | cut -f1))"
