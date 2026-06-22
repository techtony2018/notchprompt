# Changelog

## 1.0.149 - 2026-06-22

- Added Text to Speech settings for voice, speech rate, pitch, and volume on macOS and iOS.
- Added a speaker preview button in Text to Speech settings; changing the voice or TTS options while previewing now restarts preview with the selected settings.
- Filtered Text to Speech voice choices by the selected script/recognition language group.
- Improved iOS voice selection with a scrollable voice sheet so long voice lists remain usable.
- Made Text to Speech read from the current prompt anchor, pause/resume with presentation playback, stop on reset or end-of-script, and continue from the beginning when Play in loops is enabled.

## 1.1.1 - 2026-02-27

- Fixed shortcut reliability by moving app-wide keyboard shortcuts to Carbon system hotkeys instead of fragile event monitors.
- Added explicit status-menu warnings when one or more shortcuts are unavailable because another app already owns them.
- Fixed pause/resume behavior so scrolling resumes from the current position instead of jumping back to the beginning.

## 1.1.0 - 2026-02-25

- Fixed macOS compatibility packaging/build settings so release artifacts advertise a minimum macOS that includes 15.7.x.
- Fixed settings usability by making the settings content scrollable and reachable at smaller window heights while keeping the window resizable.
- Fixed multi-display behavior so the overlay prefers the built-in MacBook display by default, with user-selected display override and robust fallback to menu-bar screen.
- Added release compatibility check script used in CI to print deployment target and built app minimum system version.
