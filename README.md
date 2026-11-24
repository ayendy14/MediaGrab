# MediaGrab

A small Windows tray app: press a keyboard shortcut while a YouTube video or Spotify song is open in your browser (or with its link copied), and download it as audio or video.

## Features

- **One shortcut** (default `Ctrl+Alt+Y`) opens a window with the title, length, thumbnail and link
- **File types:** mp3 (default), m4a, opus, flac, wav, or mp4 video (Best / 1080p / 720p / 480p / 360p)
- **Trim** with a start and end time, choose the folder and the file name. Empty boxes use your defaults
- **Spotify songs:** reads the title and artist from Spotify, finds the best match on YouTube Music by length, and lets you pick another match if needed
- **Song info and cover art** saved inside the files
- **Downloads window** with progress bars and a download history; warns before downloading the same thing twice, and shows why a download failed
- **Clipboard mode:** works with a copied YouTube or Spotify link
- **Settings window** for every default, plus "Start with Windows"; to change the shortcut, click its box and press the new keys
- **Modern look** with rounded controls; follows the Windows light or dark mode setting
- **Self-contained:** downloads [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [ffmpeg](https://ffmpeg.org) once, on first run, and checks yt-dlp for updates at each start. Damaged or half-finished downloads of these tools are detected and fetched again

## Install

1. Download `MediaGrab.exe` from [Releases](../../releases) (or build it, below).
2. Double-click it. The first run downloads yt-dlp and ffmpeg (about 130 MB, one time).
3. Use the tray icon (red circle) to open Downloads and Settings, download a copied link, or exit.

Starting a newer MediaGrab closes the one that is running. If something goes wrong, `%LOCALAPPDATA%\MediaGrab\log.txt` shows what happened.

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

## Automatic build and releases

Every change to `main` is built and tested on Windows by GitHub Actions (`.github/workflows/build.yml`). The test downloads yt-dlp and ffmpeg, tries a download, presses the keyboard shortcut, changes it in Settings, and takes screenshots of every window in light mode and in dark mode at 150% size. The exe and screenshots can be downloaded from the run's page under **Artifacts**.

To publish a new version:

1. Change `$Version` at the top of `src/MediaGrab.ps1` and commit it.
2. On GitHub, open **Releases**, then **Draft a new release**, type a new tag such as `v1.0.1`, and click **Publish release**.
3. After a few minutes, `MediaGrab.exe` is attached to the release automatically.

## Notes

Spotify audio is copy-protected, so Spotify songs are downloaded from their YouTube match. Only download content you have the right to download.
