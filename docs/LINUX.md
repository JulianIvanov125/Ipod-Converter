# iPod Converter for Linux

The Linux version converts music and videos for iPod 5G/5.5G, iPod classic, iPod nano and iPod touch —
the same presets as the Mac app (Standard or Maximum quality), tags and covers kept, AAC audio without clipping,
and a Duplicates filter for videos. It is a GTK4/libadwaita app with a command line mode.

**What is different from the Mac app:** Linux has no iTunes / Music app, so iPod Converter does not sync the iPod.
It puts the converted files into an output folder; copy them to the iPod with
[Rhythmbox](https://wiki.gnome.org/Apps/Rhythmbox), [Strawberry](https://www.strawberrymusicplayer.org) or
gtkpod (see [Copying to the iPod](#copying-to-the-ipod)). There is also no player, no Apple Music tag lookup and no
in-app updates yet.

## Requirements

- A 64-bit Linux with **GTK 4.12+** and **libadwaita 1.4+**: Ubuntu 24.04+, Debian 13+, Linux Mint 22+,
  Pop!_OS 24.04+, Fedora 39+, openSUSE Tumbleweed, Arch / Manjaro
- **ffmpeg** (from your distribution)
- x86_64 (most PCs) or aarch64 (ARM, e.g. Raspberry Pi 5 with a 64-bit OS)

## Install

Download the file for your system from the [latest release](https://github.com/JulianIvanov125/Ipod-Converter/releases/latest).
Not sure which one? Run `uname -m`: `x86_64` → *amd64* / *x86_64* files, `aarch64` → *arm64* / *aarch64* files.

### Ubuntu, Debian, Linux Mint, Pop!_OS — `.deb`

```bash
sudo apt install ./ipod-converter_<version>_amd64.deb
```

`apt` installs ffmpeg, GTK and libadwaita automatically. Then open **iPod Converter** from the app menu.
To remove: `sudo apt remove ipod-converter`.

### Any other distribution — `.tar.gz`

1. Install the dependencies:
   - Fedora: `sudo dnf install ffmpeg-free gtk4 libadwaita` (or `ffmpeg` from RPM Fusion)
   - Arch / Manjaro: `sudo pacman -S ffmpeg gtk4 libadwaita`
   - others: install `ffmpeg`, GTK 4 and libadwaita with your package manager
2. Unpack and install into your home folder (no sudo needed):

```bash
tar xzf ipod-converter-<version>-x86_64.tar.gz
cd ipod-converter-<version>-x86_64
./install.sh
```

It installs to `~/.local` and adds **iPod Converter** to the app menu. To remove, delete
`~/.local/bin/ipod-converter`, `~/.local/share/applications/io.github.ipodconverter.linux.desktop`
and `~/.local/share/icons/hicolor/*/apps/io.github.ipodconverter.linux.png`.

## Use

1. Drop music or videos into the window, or press **Add files** (the folder button adds whole folders).
2. Pick your **iPod** and the **quality**: *Standard* plays everywhere; *Maximum* (iPod 5.5G, classic, nano 3–5
   and nano 7) gives a sharper picture and bigger files.
3. Choose the **output folder** (top right; default `~/Videos`).
4. Press **Convert**. Videos go to `iPod Converter Video/Music Videos | Films | Serials`, music to
   `iPod Converter Music`. Music that already plays on the iPod is copied as is, without re-encoding.

**Duplicates:** switch the list to **Duplicates** to see the same video added more than once (also older copies
like `…_ipod5g_480.m4v`). The best copy stays; pick another one with **Keep this one instead**, move extras to the
Trash with the trash button. Versions of one video made for different iPods are not counted as duplicates.

### Command line

```bash
ipod-converter convert --ipod nano7 --max --out ~/Videos ~/Downloads/clips
ipod-converter dups ~/Videos/iPod\ Converter\ Video
ipod-converter models        # list of iPod ids: classic5G, classic55G, nano7, …
```

## Copying to the iPod

iPod Converter prepares the files; another app writes them to the iPod's database:

- **Rhythmbox** (GNOME, Ubuntu): plug in the iPod, it appears in the sidebar — drag the converted files onto it.
- **Strawberry** (KDE and others): *Device* view → copy to device.
- **gtkpod**: classic tool for iPod classic / video; may not be packaged on newer distributions.

iPod nano 6th/7th generation and iPod touch use a database these Linux apps can't write — for those, copy the
converted files on a Mac or Windows PC with Finder / iTunes.

## Logs

`~/.local/state/ipod-converter/iPodConverter.log` — attach it when reporting a problem.

## Build from source

```bash
sudo apt install ffmpeg libadwaita-1-dev libgtk-4-dev pkg-config     # Ubuntu / Debian
# Swift 6: https://www.swift.org/install/linux/ (swiftly)
./build_linux.sh                 # → build-linux/ipod-converter
./make_linux_packages.sh         # → .deb and .tar.gz for this machine's architecture
```
