# Changelog

Notable changes are recorded here. Version numbers follow `MAJOR.MINOR.PATCH`; v0.x releases may change behavior and data formats.

## [0.2.0] - Unreleased

### Added

- Research library with bibliographic records, categories, tags, favorites, reading states and personal research purpose.
- Independent personal notes for ideas, questions, tasks and reproduction records; selected quotes and source-page links.
- Local structured paper summaries with Qwen3.6 27B Q4, six research topics, matched original quotes and explicit adoption of metadata suggestions.
- CJK keyword search across metadata, notes, summaries and extracted text; multilingual semantic retrieval with Qwen3 Embedding 0.6B.
- Cancellable document processing, resumable map-stage cache, versioned vector indexes and Markdown archive export.
- Transactional v0.1 database upgrade with a consistent pre-upgrade SQLite backup, including committed WAL contents.
- Research model installer with disk preflight, progress reporting, checksum-verified Ollama pulls and interrupted metadata recovery.
- Library and selection-note keyboard shortcuts, compact library navigation and floating processing status while reading.

### Changed

- Open into the research library; retain existing papers, vocabulary, reading positions and reminder preferences.
- Pause owned OmniVoice service during large-model summarization and unload research models after processing.
- Version offline package names from Info.plist; select required complete models and preflight staging/image space.

### Validation status

- Regression checks: 18 Swift core checks and 23 Python checks passed.
- Isolated native UI: metadata, notes, quote/page capture, unsaved-edit protection, keyword retrieval and Markdown export verified.
- Real research model inference and final app delivery are still undergoing acceptance; see the v0.2 verification document when available.

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
