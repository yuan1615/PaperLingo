# Changelog

Notable changes are recorded here. Version numbers follow `MAJOR.MINOR.PATCH`; v0.x releases may change behavior and data formats.

## [0.2.7] - 2026-10-20

### Added

- Contextual vocabulary explanations with the installed Qwen3.6 27B model: concise meaning, interpretation in the saved paper sentence and one usage hint. Reading selections continue to use TranslateGemma alone.
- Automatically explain only the expanded word or phrase after a short debounce, cache it locally, and reuse cached explanations during review without model inference. Preserve the original translation and learning statistics.
- Bounded local input, disabled thinking, limited output, a 45-second inference deadline, explicit retry, cancellation and model unloading. Foreground translation, speech, paper processing and semantic search take priority.
- Compact vocabulary layout with the original sentence, highlighted term, source link and speech controls beside its explanation.
- Database schema 5 adds a separate explanation cache after an automatic consistent backup; version 5 JSON exports include valid cached explanations. Changed contexts, prompts and model signatures invalidate stale results.

### Fixed

- Restore owned speech services independently of a cancelled explanation task, and prevent stopped engine startup from reviving services. Preserve pause requests made while waiting for model cleanup.

Validation: 36 core checks, 29 isolated vocabulary/model-scheduling UI checks and 34 existing review UI checks passed. Three real word/phrase examples took 20.50 / 20.26 / 21.21 seconds with an unloaded model and produced 90 / 90 / 91 characters. Real cancellation and unloading during generation took about 0.39 seconds; real translation after preemption took about 4 seconds including model loading. Owned OmniVoice pause/restore/playback also passed. Synthetic diagnostics are not a general language-quality or hardware-performance guarantee. No new model weights or full offline DMG were generated.

## [0.2.6] - 2026-10-20

### Added

- Highlight the current review word or phrase in its paper context with a pale yellow background and semibold text. Match repeated occurrences without case sensitivity, allow whitespace between phrase terms, and avoid matching inside a longer word.
- Preserve the full selectable source text, original spelling, speech input and existing review layout.

Validation: Release build and the existing 34 native review UI checks passed. Inspected isolated word, phrase and literal-term previews, including uppercase/repeated matches and longer-word exclusions. No database or model changes.

## [0.2.5] - 2026-10-20

### Fixed

- Keep review playback controls in a fixed-size progress row. Generating, playing, pausing, errors and stopping no longer insert bottom space, resize the card or move its scroll position and grading controls.
- Put a prominent green source-sentence speech button beside word pronunciation, before the long context. Saved sentence cards use the same explicit playback label.
- Shorten the review heading to leave more room for the card in small windows. Playback details and full error messages open only when requested.

Validation: 32 core checks, Release build and 34 isolated native review UI checks passed. UI checks compare scroll geometry and grading-region pixels at 860 × 620, 1100 × 800 and 1440 × 900, exercise speech controls with native mouse events and system speech, and inject synthesis states without model inference. Database schema and models are unchanged. The separately distributed full offline DMG remains v0.2.3.

## [0.2.4] - 2026-10-20

### Fixed

- Show complete English selections and translations in independently scrollable popover sections. Keep results visible during wheel/trackpad scrolling, scrollbar dragging, keyboard navigation and window resizing; Escape and explicit dismissal still close them.
- Anchor web selection results to the reading viewport so they remain visible when the text document scrolls.
- Remove review context line limits and make the card scroll within the available window space, keeping reveal and grading controls outside the scroll area.
- Replace the legacy sentence API, which can silently split very long sentences, with adaptive local `NLTokenizer` sentence ranges. Preserve complete contexts without processing an entire ordinary article.
- Recover clipped legacy review contexts from the saved PDF page or web snapshot, using the old fragment to select the right occurrence. Preserve stored lookup and review records when a source is unavailable or ambiguous.

Validation: 32 core checks, Release build and 16 isolated native interface checks passed, including real local translation. Database schema and model weights are unchanged.

## [0.2.3] - 2026-10-16

### Added

- Native selection popovers for PDF and web readers, with translation, speech, slow speech, sentence translation, copy and personal notes. Translations appear beside the selection and work in focus mode.
- Locally built full offline DMG with all research, retrieval, translation and speech models, updated installation instructions and checksum verification. Use LZFSE compression for the macOS 14+ target; the model image is distributed separately from GitHub source archives.

### Changed

- Replace the research library's stacked banners and always-visible filters with a compact search toolbar. Move filters and sorting into a popover, and make summaries the default paper detail.
- Remove the duplicated paper list from library navigation, shorten detail headers, collapse search excerpts and summary metadata, and retain a list/detail switch for narrow windows.
- Show selection actions after mouse release; dismiss them on scrolling, resizing, outside clicks or Escape without moving the document.
- Retain the first-three-page summary pipeline, model weights and database schema 4.

Interaction design and manual verification: [v0.2.3 layout](docs/V0.2.3_LAYOUT.md).

Release validation also passed 26 model-free Python regression checks. The CI workflow remains an opt-in example and is not enabled.

## [0.2.2] - 2026-10-16

### Changed

- Read only the first three physical PDF pages; use a bounded opening excerpt for web documents. Library opening and index rebuilding never scan PDF text.
- Generate motivation, core method and reported results in Chinese with one local Qwen3.6 request and a fixed JSON prompt. Explicitly mark results absent from the supplied opening.
- Build exactly one vector from each current Chinese summary. Exclude original text, titles, manual metadata and personal notes from embedding input; papers without summaries remain available through keyword search.
- Remove the experiment/evidence tab and automatic experiment extraction. Schema 4 backs up the database, then clears retired experiment and full-text caches while preserving papers, notes and learning records.
- Export version 4 JSON and summary-focused Markdown without experiment records.

Implementation scope: [v0.2.2 plan](docs/V0.2.2_PLAN.md).

## [0.2.1] - 2026-10-16

### Added

- Evidence ledger and structured experiment records saved before Chinese overview generation, with source-page links, literal numeric values, independent review status and evidence-based personal notes.
- Streaming experiment extraction with partial JSON recovery, bounded evidence batches, reusable extraction cache and targeted retries.
- Pinned local Qwen3 Reranker 0.6B, with CPU/MPS inference and offline packaging/license support.
- Version 3 JSON export and Markdown exports containing experimental evidence and review state.

### Changed

- Generate an overview from saved records instead of repeated hierarchical merging. A 22-page cold diagnostic took 8m52s and two model calls, compared with the previous approximately 52.6-minute resumed run; timing excludes semantic indexing and is not a general performance guarantee.
- Index each paper once using its AI overview, title, classification and personal notes. Remove page-level vectors and source-text search indexing; keep original sources for reading and evidence verification.
- Fuse keyword/vector candidates and locally rerank papers, reject weak matches, and show title/manual-record fallback when an overview is missing.
- Automatically back up schema upgrades and reclaim retired index storage where SQLite locks permit.
- Atomically replace native executable files while preserving signed bytes; verify normal relaunches after the observed initial installation wait.

Validation scope and limitations are documented in [v0.2.1 verification](docs/VERIFICATION_V0.2.1.md).

## [0.2.0] - 2026-10-15

### Added

- Research library with bibliographic records, categories, tags, favorites, reading states and personal research purpose.
- Independent personal notes for ideas, questions, tasks and reproduction records; selected quotes and source-page links.
- Local structured paper summaries with Qwen3.6 27B Q4, six research topics, matched original quotes and explicit adoption of metadata suggestions.
- CJK keyword search across metadata, notes, summaries and extracted text; multilingual semantic retrieval with Qwen3 Embedding 0.6B.
- Cancellable document processing, resumable map-stage cache, versioned vector indexes and Markdown archive export.
- Evidence-linked partial previews after the first source group, clearly marked until full-document consolidation completes; older complete summaries stay visible during regeneration.
- Transactional v0.1 database upgrade with a consistent pre-upgrade SQLite backup, including committed WAL contents.
- Research model installer with disk preflight, progress reporting, checksum-verified Ollama pulls and interrupted metadata recovery.
- Library and selection-note keyboard shortcuts, compact library navigation and floating processing status while reading.

### Changed

- Open into the research library; retain existing papers, vocabulary, reading positions and reminder preferences.
- Pause owned OmniVoice service during large-model summarization and unload research models after processing.
- Show consolidation layers, source groups and advancing progress while long-document summaries are merged.
- Version offline package names from Info.plist; select required complete models and preflight staging/image space.

### Validation status

- Regression checks: 18 Swift core checks and 23 Python checks passed.
- Isolated native UI: metadata, notes, quote/page capture, unsaved-edit protection, keyword retrieval and Markdown export verified.
- Full 22-page native-app processing completed with 11 matched-source points and one rejected quote; cancellation/resume and manual-record preservation passed.
- Installed self-contained app passed relocated Python/MPS, all model checksums, translation, progressive audio and post-inference signature checks.
- Functional validation does not establish summary accuracy. The long-paper run took about 52.6 minutes after resuming, and detailed experimental comparisons were underrepresented; see [v0.2 verification](docs/VERIFICATION_V0.2.md).

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

[0.2.7]: https://github.com/yuan1615/PaperLingo/releases/tag/v0.2.7
[0.2.6]: https://github.com/yuan1615/PaperLingo/releases/tag/v0.2.6
[0.2.5]: https://github.com/yuan1615/PaperLingo/releases/tag/v0.2.5
[0.2.4]: https://github.com/yuan1615/PaperLingo/releases/tag/v0.2.4
[0.2.3]: https://github.com/yuan1615/PaperLingo/releases/tag/v0.2.3
[0.1.0]: https://github.com/yuan1615/PaperLingo/releases/tag/v0.1.0
