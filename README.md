# MediaGrab

A small Windows tray app: press a keyboard shortcut while a YouTube video or Spotify song is open in your browser (or with its link copied), and download it as audio or video.

## Features

- **One shortcut** (default `Ctrl+Alt+Y`) opens a window with the title, length, thumbnail and link
- **File types:** mp3 (default), m4a, opus, flac, wav, or mp4 video (Best / 1080p / 720p / 480p / 360p)
- **Trim** with a start and end time, choose the folder and the file name. Empty boxes use your defaults
- **Spotify songs:** reads the title and artist from Spotify, finds the best match on YouTube Music by length, and lets you pick another match if needed
- **Song info and cover art** saved inside the files
- **Downloads window** with live progress and a download history; warns before downloading the same thing twice
- **Clipboard mode:** works with a copied YouTube or Spotify link
- **Settings window** for every default, plus "Start with Windows"
- **Self-contained:** downloads [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [ffmpeg](https://ffmpeg.org) on first run and keeps yt-dlp updated

## Install

1. Download `MediaGrab.exe` from [Releases](../../releases) (or build it, below).
2. Double-click it. The first run downloads yt-dlp and ffmpeg (about 130 MB, one time).
3. Use the tray icon (red circle) to open Downloads and Settings, or to exit.

Windows SmartScreen may warn about an unsigned app: click **More info**, then **Run anyway**.

## Supported browsers

Chrome, Edge, Firefox, Brave, Opera and Vivaldi (editable in Settings).

## How it works

`MediaGrab.exe` is a small Go launcher that embeds `src/MediaGrab.ps1` and runs it with the PowerShell built into Windows. The script reads the browser's address bar through Windows UI Automation and runs yt-dlp.

Files are stored in `%LOCALAPPDATA%\MediaGrab` (settings, history, yt-dlp and ffmpeg).

## Build

Requires Go 1.24 or newer:

```sh
./build.sh
```

This produces `MediaGrab.exe` in the repository folder.

## Notes

Spotify audio is copy-protected, so Spotify songs are downloaded from their YouTube match. Only download content you have the right to download.
