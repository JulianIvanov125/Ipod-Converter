# iPod Converter

A macOS app that turns any video or music file into something your iPod actually plays —
iPod 5G/5.5G, iPod classic, iPod nano and iPod touch. Drop files in, pick your iPod, press Convert.
Everything is done locally with a bundled FFmpeg.

![Music](docs/screenshots/music.png)
![Videos](docs/screenshots/videos.png)

## Download

Get the latest DMG from **[Releases](https://github.com/JulianIvanov125/Ipod-Converter/releases/latest)**,
open it and drag **iPod Converter** to Applications.

- Requires a Mac with Apple Silicon and macOS 14 or later. Nothing else to install — FFmpeg is built in.
- The app is not notarized by Apple. On first launch macOS will block it: open
  **System Settings → Privacy & Security** and click **Open Anyway**.

## Features

**Video**
- A preset for every video iPod: resolution, H.264 profile/level and bitrate within the device limits;
  a "Maximum" 640×480 mode for 5.5G and iPod classic
- Reads MKV, AVI, WMV, WebM, MPG/VOB, TS, MOV, MP4 and more, including AV1 (4K YouTube downloads);
  deinterlaces DVD/TV recordings
- Sorts files into music videos, films and TV series with proper iTunes tags; series are grouped by
  show and season — episode names are parsed in English, Russian, Ukrainian and Belarusian
  (`S01E02`, `1x02`, `Season 1 Episode 2`, `Сезон 1 Серия 2`, `1 сезон 2 серія` …)
- Checkboxes, type filter, change the type of many videos at once
- Custom output settings on top of the preset: MP4/MOV, HEVC, up to 1080p, video and audio bitrate
- Output files are named with the target, e.g. `Lost S01E01 [iPod 5.5G].m4v`; leftovers of older conversions
  (`_ipod5g_480`, "Unknown Artist" tags) are cleaned up
- Big batches run as a queue (two videos at a time) with an overall progress bar

**Music**
- Output format: Auto, AAC, MP3 or Apple Lossless — globally or per track; files the iPod already plays are copied
  without re-encoding. The Type column shows the current format → the result for the selected iPod
- FLAC, ALAC, WAV/AIFF (24-bit, hi-res), APE, WavPack, DSD, Opus, Ogg Vorbis, WMA, MP3, AAC
- Missing tags and covers are filled from the Apple Music catalog; existing tags are never overwritten
- Star ratings read from files and synced with the Music app
- Column sorting and search that ignores Latin/Cyrillic and wrong keyboard layout (`kino` = `Кино` = `rbyj`)

**Player**
- Preview originals and converted files; mini player for video, Apple Music–style bar for tracks
- Full screen with synced lyrics (.lrc, file tags or LRCLIB) and visualizers that follow the song's dynamics:
  a 20 Hz – 20 kHz equalizer, a water-ripple simulation tinted by the cover, and flowing cover colors
- Volume, repeat, shuffle; shows up in macOS Now Playing and reacts to media keys

**Your iPods**
- Connected iPods are detected automatically and shown under their own names (e.g. "Alex's iPod nano"),
  with capacity and free space; the bottom bar tells you whether the converted files will fit
- Every iPod tab keeps its own state — what was converted, what failed — so converting for one iPod
  doesn't mark files as done for another

**iPod sync**
- Videos go straight to the Music / TV app into a playlist per iPod model, so each iPod syncs only its own
  playlist in Finder
- Tracks go to your Music library; optionally into a playlist of your own, and a cover maker creates
  Apple Music–style placeholder covers for it
- If something fails, "Copy for support" gives a report with what succeeded, where it failed and the error text

**Look** — Clear Glass design, light/dark theme, English / Russian / Ukrainian / Belarusian.

## Use with Claude (MCP)

iPod Converter includes an [MCP](https://modelcontextprotocol.io) server, so Claude can use it for you: “what fits on my nano?”, “convert this album for my iPod 5G and put it in a playlist”, “find duplicate tracks in ~/Music/CD”.

Claude Code:

```bash
claude mcp add ipod-converter -- "/Applications/iPod Converter.app/Contents/MacOS/iPodConverter" --mcp
```

Claude Desktop — add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ipod-converter": {
      "command": "/Applications/iPod Converter.app/Contents/MacOS/iPodConverter",
      "args": ["--mcp"]
    }
  }
}
```

| Tool | What it does | Changes files |
|---|---|---|
| `list_ipods` | Connected iPods: model, name, capacity, free space | No |
| `inspect_files` | Current format → result for the iPod, estimated size, whether it fits | No |
| `find_duplicates` | Duplicate tracks: which copy to keep, which are extra | No |
| `convert` | Converts for the iPod and adds to Music/TV (optionally into a playlist) | Creates new files |
| `fill_tags` | Fills missing tags and covers from Apple Music into the original files (no re-encoding) | Yes |
| `trash_duplicates` | Moves extra copies to the Trash (the kept copy is never touched) | Yes |

The server runs without a window and uses the output folder chosen in the app, so open the app once first. Your app settings are not changed.

## Build from source

Needs Xcode Command Line Tools and Homebrew.

```bash
brew install x264 lame mpg123   # static libraries for the bundled FFmpeg
brew install meson ninja nasm   # to build dav1d (AV1 decoder) from source
./build_ffmpeg.sh               # builds vendor/ffmpeg/{ffmpeg,ffprobe}
./build.sh                      # builds build/iPod Converter.app
./make_dmg.sh                   # optional: packs the app into a DMG
```

## License

GPL-3.0 — see [LICENSE](LICENSE). The app bundles FFmpeg built with x264, LAME, mpg123 and dav1d; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

iPod, Apple Music and iTunes are trademarks of Apple Inc. This project is not affiliated with Apple.
