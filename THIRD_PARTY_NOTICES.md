# Third-party components

The release DMG bundles `ffmpeg` and `ffprobe` built by [`build_ffmpeg.sh`](build_ffmpeg.sh)
(static, arm64, macOS 14+). They contain:

| Component | Version | License | Source |
|---|---|---|---|
| FFmpeg | 9.0.2 | GPL-3.0-or-later (built with `--enable-gpl --enable-version3`) | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |
| x264 | r3222 | GPL-2.0-or-later | https://code.videolan.org/videolan/x264 |
| LAME | 4.0 | LGPL-2.0-or-later | https://lame.sourceforge.io |
| mpg123 | 1.33.7 | LGPL-2.1-or-later | https://www.mpg123.de |

The exact build configuration is in `build_ffmpeg.sh`; running it reproduces the bundled
binaries from the sources above (x264, LAME and mpg123 static libraries come from Homebrew).

iPod, iPod classic, iPod nano, iPod touch, Apple Music and iTunes are trademarks of Apple Inc.
This project is not affiliated with or endorsed by Apple.

Online services used at runtime (optional, can be turned off in the app):
- iTunes Search API — filling missing track tags and covers
- LRCLIB (lrclib.net) — synced lyrics
