# PCompanion

<p align="center">
  <img src="assets/banner.png" alt="PCompanion Banner" width="100%">
</p>

Native teleprompter companion for presentations and recordings. The macOS app
uses a notch-adjacent overlay, and the iOS app provides a touch-first prompt
surface for iPhone and iPad.

## Quick Demo

> Demo assets below are placeholders. Replace with real captures before public
> launch.

<!--
![PCompanion hero screenshot](docs/media/hero.png)
*Hero view of the overlay panel and settings workflow.*

![Presentation Companion scrolling demo GIF](docs/media/notchprompt-demo.gif)
*In-use scrolling demo with start/pause and speed adjustments.*
-->

## Features

- Menu bar utility workflow (`PC` status item).
- Notch-adjacent floating overlay with transport controls.
- Start/pause, reset, and configurable jump controls.
- Click the left third of the script area to scroll back; double-click to scroll back twice the configured pace.
- Click the middle third to start, pause, or resume.
- Click the right third to scroll forward; double-click to scroll forward twice the configured pace.
- Adjustable speed, font size, overlay width, overlay height, opacity, and fast forward/backward scrolling pace.
- Resize the prompt overlay directly with the bottom-right resize handle; the window recenters after resizing.
- Optional countdown before scrolling starts.
- Edit scripts directly in Settings with a scrollable, resizable text area.
- Import/export plain text scripts.
- Optional local-microphone controls for auto pause/resume and automatic speed adjustment based on speaking pace on macOS and iOS, guarded by a configurable voice detection threshold that defaults to 5 dB.
- Voice-triggered resume is blocked after a mouse pause until you click to resume, so Q&A audio does not restart the script.
- Privacy mode (`NSWindow.SharingType`, best-effort/app-dependent).

## Requirements

- macOS version supported by the current deployment target in
  `notchprompt.xcodeproj`.
- Apple Silicon or Intel Mac for the macOS app.
- iPhone or iPad running iOS 17 or later for the iOS app.

## Version

Current version: V1.1. Each pushed app update should increment the version by 0.1.

## Install (Recommended)

1. Open GitHub Releases:
   `https://github.com/techtony2018/notchprompt/releases`
2. Download the latest `.dmg` release asset.
3. Open the DMG and drag `PCompanion.app` to `Applications`.
4. Launch `PCompanion.app`.

### Unsigned Build Note

This build is currently unsigned/unnotarized, so macOS may show security prompts.

If macOS shows:

- `Apple could not verify "PCompanion" is free of malware...`
- or `"PCompanion" is damaged and can’t be opened`

run:

```bash
xattr -cr "/Applications/PCompanion.app"
open "/Applications/PCompanion.app"
```

If it is still blocked:

1. Open `System Settings -> Privacy & Security`.
2. Click **Open Anyway** for `PCompanion`.
3. Launch again.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌥⌘P` | Start / Pause |
| `⌥⌘R` | Reset scroll |
| `⌥⌘J` | Jump back 5s |
| `⌥⌘H` | Toggle Privacy Mode |
| `⌥⌘O` | Toggle overlay visibility |
| `⌥⌘=` | Increase speed |
| `⌥⌘-` | Decrease speed |

## Build From Source

```bash
git clone https://github.com/techtony2018/notchprompt.git
cd notchprompt
open notchprompt.xcodeproj
```

CLI build:

```bash
xcodebuild -project notchprompt.xcodeproj -scheme notchprompt -configuration Debug build
xcodebuild -project notchprompt.xcodeproj -scheme "Presentation Companion" -configuration Debug -sdk iphonesimulator build
```

## License

MIT. See `LICENSE`.
