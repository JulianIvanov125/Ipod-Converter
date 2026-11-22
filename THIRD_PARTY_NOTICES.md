# Third-party components

The release DMG bundles `ffmpeg` and `ffprobe` built by [`build_ffmpeg.sh`](build_ffmpeg.sh)
(static, arm64, macOS 14+). They contain:

| Component | Version | License | Source |
|---|---|---|---|
| FFmpeg | 9.0.2 | GPL-3.0-or-later (built with `--enable-gpl --enable-version3`) | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |
| x264 | r3222 | GPL-2.0-or-later | https://code.videolan.org/videolan/x264 |
| LAME | 4.0 | LGPL-2.0-or-later | https://lame.sourceforge.io |
| mpg123 | 1.33.7 | LGPL-2.1-or-later | https://www.mpg123.de |
| dav1d | 1.5.5 | BSD-2-Clause | https://code.videolan.org/videolan/dav1d |

The exact build configuration is in `build_ffmpeg.sh`; running it reproduces the bundled
binaries from the sources above (x264, LAME and mpg123 static libraries come from Homebrew;
dav1d is built from its source tarball, checked against the Homebrew formula's SHA-256).

iPod, iPod classic, iPod nano, iPod touch, Apple Music and iTunes are trademarks of Apple Inc.
This project is not affiliated with or endorsed by Apple.

Online services used at runtime (optional, can be turned off in the app):
- iTunes Search API — filling missing track tags and covers
- LRCLIB (lrclib.net) — synced lyrics

## dav1d license

```
Copyright © 2018-2025, VideoLAN and dav1d authors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
