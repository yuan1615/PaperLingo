# Changelog

Notable changes are recorded here. Version numbers follow `MAJOR.MINOR.PATCH`; v0.x releases may change behavior and data formats.

## [0.1.0] - 2026-10-15

### Added

- Native SwiftUI / AppKit reader for selectable-text PDFs and imported web articles.
- Local English-to-Chinese translation with TranslateGemma 4B through Ollama.
- OmniVoice pronunciation, slow playback, voice selection and macOS system voice option.
- Incremental sentence/clause synthesis, streamed audio events and ordered playback.
- Personal vocabulary with lookup frequency, context, source pages and JSON export.
- Recognition and listening practice with spaced review and local daily notifications.
- Collapsible panels, focus mode, keyboard shortcuts and an overlay audio player.
- Self-contained Apple Silicon offline app / DMG build and relocated-runtime verification.
- Repository documentation, MIT source license, third-party notices and a macOS CI template.

### Fixed

- Enlarged control hit targets and removed hidden overlays that intercepted clicks.
- Kept playback status from moving the reading document.
- Stopped stale playback after cancellation or a new speech request.
- Stopped owned model services synchronously when the app exits.
- Pinned Python and OmniVoice downloads to the versions expected by the offline packager; rejected incomplete model snapshots before marking them ready.

### Known limitations

- Apple Silicon / macOS 14+ target; scanned PDF OCR and cloud sync are not implemented.
- Model accuracy and gap-free speech playback are not guaranteed.
- Offline app builds use ad-hoc signing by default and are not Apple-notarized.

[0.1.0]: https://github.com/yuan1615/PaperLingo/releases/tag/v0.1.0
