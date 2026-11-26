# LocalConvert — Phase 61.1: Audio Workspace Technical Specification Correction Report

**Document ID:** LC-AW-CORR-009  
**Date:** 2026-11-22  
**Target Platform:** macOS 15.0+ (`arm64`), Swift 6.0 (`SWIFT_STRICT_CONCURRENCY: complete`), Xcode `27.x`, XcodeGen (`project.yml`)  
**Phase Type:** Strictly Documentation-Only Technical Specification Audit & Correction  
**Final Classification:** **`READY FOR PHASE 62`**

---

## 1. Execution & Non-Implementation Attestation

- **No implementation was performed.** Zero `.swift` files, `project.yml`, `LocalConvert.xcodeproj`, tests, scripts, binaries, dependencies, or application resources were modified or created.
- **No builds or test suites were executed** during Phase 61 or Phase 61.1 (nothing is claimed as compiled or passing for proposed Audio Workspace features).
- All technical findings and corrections below are grounded strictly in read-only inspection of the repository source files and bundled dependencies listed in each correction section.

---

## 2. Detailed Corrections Applied (Corrections A–E)

### Correction A — Sample-Frame Mathematics & Coordinate Model
- **Original Issue:** `AUDIO_WORKSPACE_DATA_MODEL.md` stated integer/rational arithmetic in prose while showing `Double(frame) * Double(targetRateHz) / Double(sourceRateHz)` in code (`Int64(num.rounded())`), left cross-rate comparison, signedness across contexts (`Timeline` vs `Source` vs `Delta`), `Int64` checked overflow/underflow, zero-length ranges, exact tie rounding, invalid sample rates, and legacy v1/v2 invalid float rejection underspecified.
- **Corrected Specification:**
  - Defined validated positive `SampleRate` (`Int32`, `1...768_000` Hz) and typed frame domains: non-negative `SourceFrameTime`, `TimelineFrameTime`, `RenderFrameTime` (`frame >= 0`) vs signed `FrameDelta` (`Int64`), backed by `SampleFrameTime`.
  - Replaced `Double` cross-rate math with exact `Int128` rational arithmetic (`Int128(frame) * Int128(targetRate) / Int128(sourceRate)`), deterministic **round-half-away-from-zero** tie policy (`2 * abs(remainder) >= denominator`), and checked `Int64(exactly:)` validation throwing `SampleFrameError.integerOverflow` / `.integerUnderflow` (never wrapping or saturating).
  - Defined exact cross-rate ordering (`Int128(lhs.frame) * Int128(rhs.sampleRate.hz)` vs `Int128(rhs.frame) * Int128(lhs.sampleRate.hz)` — max ~83 bits, well within `Int128` headroom).
  - Defined `SampleFrameRange` invariants: inclusive `startFrame >= 0`, `frameCount >= 0`, checked exclusive `endFrame` (`addingReportingOverflow`), explicit zero-length (`isEmpty`) behavior (valid cursor/empty selection; editing no-op; export validation failure).
  - Defined `v1/v2 -> v3` migration using exact `Decimal` half-away-from-zero scaling with explicit rejection of `NaN`, `+Inf`/`-Inf`, negative positions/durations, and out-of-range frames.
- **Documents Updated:** `AUDIO_WORKSPACE_DATA_MODEL.md`, `AUDIO_WORKSPACE_PRODUCT_SPECIFICATION.md`, `AUDIO_WORKSPACE_ARCHITECTURE.md`, `AUDIO_WORKSPACE_TEST_STRATEGY.md`, `AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md`.
- **Source Evidence Inspected:** [AudioEditorModels.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditorModels.swift) (`TimeInterval` fields, `currentSchemaVersion = 2`), [AudioEditingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditingService.swift) (`eps = 0.0005`), [ProjectPersistenceService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/ProjectPersistenceService.swift).
- **Remaining Uncertainty:** Exact `timeStretch` rational numerator/denominator representation (`Double` stretch factor `0.25...4.0` vs quantized fractional numerator) remains an implementation detail inside Phase 66/67 where `sourceSpan` converts to decoded proxy duration.

### Correction B — SQLite / Option A External-Content FTS5 Schema
- **Original Issue:** `AUDIO_WORKSPACE_DATA_MODEL.md` defined `assets_fts(..., content='assets', content_rowid='rowid')` with a spurious `asset_id UNINDEXED` column that did not exist in the `assets` table, and omitted FTS sync triggers, rebuild protocol, WAL/transaction rules, runtime FTS5 capability check + fallback, migration rollback, corruption recovery, and cascade consistency.
- **Corrected Specification:**
  - Explicitly selected and justified **Option A (External-Content FTS5)** to prevent duplicating string metadata across 25k–100k+ tracks.
  - Removed bogus `asset_id` column so FTS5 columns (`filename, title, artist, album, album_artist, genre, composer, comment`) match `assets` 1:1 (`JOIN assets ON assets.rowid = assets_fts.rowid`).
  - Specified `assets_ai` (`AFTER INSERT`), `assets_ad` (`AFTER DELETE` using FTS5 `'delete'`), and `assets_au` (`AFTER UPDATE OF ...`) triggers, plus `INSERT INTO assets_fts(assets_fts) VALUES('rebuild')`.
  - Specified mandatory per-connection pragmas (`WAL`, `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`), `BEGIN IMMEDIATE` write transactions, strictly parameterized SQL (`sqlite3_prepare_v2` + `sqlite3_bind_*`), runtime `SELECT sqlite_compileoption_used('ENABLE_FTS5')` probe + tokenized `LIKE ? ESCAPE '\'` fallback, atomic `PRAGMA user_version` migrations with rollback, `quick_check`/`integrity_check` quarantine-and-rebuild recovery, and `ON DELETE CASCADE` playlist cleanup with `position` compaction.
- **Documents Updated:** `AUDIO_WORKSPACE_DATA_MODEL.md`, `AUDIO_WORKSPACE_ARCHITECTURE.md`, `AUDIO_WORKSPACE_TECHNOLOGY_EVALUATION.md`, `AUDIO_WORKSPACE_TEST_STRATEGY.md`, `AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md`.
- **Source Evidence Inspected:** Existing project search confirming zero `SQLite3`/`CoreData`/`SwiftData` imports currently in `LocalConvert/`.
- **Remaining Uncertainty:** Runtime `ENABLE_FTS5` status of macOS 15+ system `/usr/lib/libsqlite3.dylib` inside hardened-runtime sandbox will be asserted empirically on the very first Phase 63 unit test (`testFTS5CapabilityDetection`).

### Correction C — Lossless Terminology & Export Semantics
- **Original Issue:** Some roadmap/spec phrasing risked conflating "non-destructive editing" and "lossless containers (FLAC/ALAC/WAV)" with bit-identical audio output after gain/DSP processing, and left UI terminology vs 16-bit dither/validation boundaries underspecified.
- **Corrected Specification:**
  - Enforced strict 3-way classification across specs, `AudioExportMode`, and `AudioEditorExportSheet` UI:
    1. **Lossless Codec / Container** vs **Bit-Exact Pass-Through** (*Original audio copied without signal modification* — payload SHA-256 identity only; container/metadata rewrites excluded from whole-file binary identity claims) vs **Lossless-Format Re-Render** (*Edited audio rendered to a lossless format*) vs **Lossy-Format Re-Render** (*Edited audio rendered to a lossy format*).
  - Clarified Float32 mixdown vs 16/24-bit integer vs 32-float WAV, mandatory vs forbidden TPDF dithering rules (applied when quantizing `Float32`/`24-bit -> 16-bit`; **forbidden** on `32-bit float` and `BitExactPassThrough`), SRC, channel layout clamping/upmix, true-peak reporting, overwrite prevention, and post-export validation of codec, **bit depth**, sample rate, channel count, and duration.
- **Documents Updated:** `AUDIO_WORKSPACE_PRODUCT_SPECIFICATION.md`, `AUDIO_WORKSPACE_ARCHITECTURE.md`, `AUDIO_WORKSPACE_TECHNOLOGY_EVALUATION.md`, `AUDIO_WORKSPACE_DATA_MODEL.md`, `AUDIO_WORKSPACE_UX_SPECIFICATION.md`, `AUDIO_WORKSPACE_TEST_STRATEGY.md`, `AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md`.
- **Source Evidence Inspected:** [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift) (`renderMixToCAF`, `renderAndEncode`, `validateExportedFile`, `codecArguments`), [AudioExportProTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/AudioExportProTests.swift).
- **Remaining Uncertainty:** `AudioExportService` does not yet verify `bit_depth` in `validateExportedFile` nor expose `BitExactPassThrough`; both are deferred cleanly to Phase 68.

### Correction D — Codec Capability Matrix & Performance Evidence Separation
- **Original Issue:** Codec routing mixed FFmpeg capabilities (`vorbis` vs `libvorbis`) with verified app export paths, and SQLite/UI summaries contained informal latency numbers (`~1-2s`, `< 15 ms`, `60 fps`) without labeling them clearly as unmeasured hypotheses.
- **Corrected Specification:**
  - Built an explicit 11-column **Codec Capability & Verification Matrix** in `AUDIO_WORKSPACE_TECHNOLOGY_EVALUATION.md` using strictly the 5 required verification tags (`VERIFIED IN REPOSITORY`, `NATIVE PLATFORM CAPABILITY — APP PATH UNVERIFIED`, `FFMPEG CAPABILITY — APP PATH UNVERIFIED`, `NOT VERIFIED`, `UNSUPPORTED`).
  - Documented verified repository findings:
    - `VERIFIED IN REPOSITORY`: `.wav` (16/24-bit), `.aiff` (16-bit), `.flac` (24-bit), `.mp3` (`libmp3lame`), `.m4a` (`aac`).
    - Discrepancy caught: `AudioExportService.swift:502` passes `-c:a libvorbis` for `.ogg`, whereas bundled FFmpeg 9.0.2 (`ffmpeg -codecs`) exposes native `vorbis` (`DEAIL. vorbis`), not `libvorbis`; `.alac` omits 16-bit TPDF dither at line 391; `-ac` clamps channels to `1...2` at line 407; `.ape` is decode-only (`D.AI.S`) in FFmpeg (`UNSUPPORTED` for encode).
  - Updated `AUDIO_WORKSPACE_TEST_STRATEGY.md` Section 1 table to separate `Proposed Target`, `Measured Baseline`, `Actual Benchmark Result` (`*Not yet measured*`), `Hardware/OS/Conditions`, and `Subsystem Exists Yet?`, and removed unmeasured latency claims from technology/roadmap docs.
- **Documents Updated:** `AUDIO_WORKSPACE_TECHNOLOGY_EVALUATION.md`, `AUDIO_WORKSPACE_PRODUCT_SPECIFICATION.md`, `AUDIO_WORKSPACE_UX_SPECIFICATION.md`, `AUDIO_WORKSPACE_TEST_STRATEGY.md`, `AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md`.
- **Source Evidence Inspected:** `LocalConvert/Resources/ffmpeg/ffmpeg -codecs`, `ffmpeg -formats`, `LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt`, [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift), [AudioExportProTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/AudioExportProTests.swift), [AudioMetadataProvider.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/Providers/AudioMetadataProvider.swift).
- **Remaining Uncertainty:** Exact bit-depth/channel support of native `vorbis` encoder in bundled FFmpeg 9.0.2 and native `ExtAudioFile` `kAudioFormatAppleLossless` across `16/24-bit` rates will be verified in Phase 68 tests.

### Correction E — `OutputReservationCoordinator` Extraction Compatibility Contract
- **Original Issue:** Previous docs named `OutputReservationCoordinator` in some sections (`OutputReservationStore` in one place) without specifying how extracting reservation logic from `ConversionManager+OutputReservation.swift` preserves every subtle Conversion Workspace rule.
- **Corrected Specification:**
  - Unified naming strictly on **`OutputReservationCoordinator`** everywhere.
  - Documented the complete **12-point Compatibility Contract** in `AUDIO_WORKSPACE_ARCHITECTURE.md` covering: unique filename generation (volume case-sensitivity), concurrent lock reservation (including `.overwrite` same-batch deduplication), ownership/`defer` release, successful `moveOrReplaceTempFile` commit, failure cleanup, cancellation stem cleanup, post-reservation on-disk collision refusal under `.createUnique`/`.skip`, destination writability + source-overwrite/`hasVideoTrim` guards, atomic `replaceItemAt` overwrite commit, stale temp artifact cleanup (`LocalConvert-*` / `LocalConvertAudio_*` + `audioExportStagingDirectory`), zero `ConversionManager` dependency from `AudioWorkspace`, and unchanged `ConversionManager` forwarding shims / UI semantics.
  - Added mandatory Conversion + Audio Workspace regression test items to `AUDIO_WORKSPACE_TEST_STRATEGY.md` and Phase 62 of `AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md`.
- **Documents Updated:** `AUDIO_WORKSPACE_ARCHITECTURE.md`, `AUDIO_WORKSPACE_PRODUCT_SPECIFICATION.md`, `AUDIO_WORKSPACE_TEST_STRATEGY.md`, `AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md`.
- **Source Evidence Inspected:** [ConversionManager+OutputReservation.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Conversion/ConversionManager+OutputReservation.swift) (full lines 1–315), [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift) (`lines 155–210`).
- **Remaining Uncertainty:** None at specification level; full behavioral parity will be validated by Phase 62 dual-workspace unit/concurrency tests.

---

## 3. Cross-Document Consistency Audit

Reviewed all 9 documentation artifacts together after editing:
- **Terminology & Type Names:** `SampleRate`, `SampleFrameTime`, `SourceFrameTime`, `TimelineFrameTime`, `RenderFrameTime`, `FrameDelta`, `SampleFrameRange`, `SampleFrameError`, `OutputReservationCoordinator`, `AudioExportMode`, `assets_fts` (Option A), and `AppStoragePaths` keys match identically across every document.
- **No Unresolved Contradictions:** Removed stale `OutputReservationStore` naming, removed stale `Double` cross-rate conversion snippet, removed bogus `asset_id` FTS column, replaced stale `.ogg libvorbis` assumption with verified FFmpeg `vorbis` finding, and aligned all readiness documents on Phase 62 scope and `READY FOR PHASE 62`.

---

## 4. Workspace & User Data Preservation Verification

- **Starting Git Status Snapshot:** `284` lines (`SHA-256: 4274022def62fafb193047764c7a7d8c751e0da2d28a8bf709ab31ac1c83ec15`).
- **Final Git Status Snapshot:** `285` lines (`+1` expected untracked doc: `docs/PHASE61_1_TECHNICAL_CORRECTION_REPORT.md`), zero non-documentation files touched since Phase 61 start.
- **Preservation Verification:** `/Applications/LocalConvert.app` mtime remained `1795224025`; `defaults export com.localconvert.app -` SHA-256 remained `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230`; no builds or tests were run during this documentation-only phase.

---

## 5. Final Readiness Classification

**Classification:** **`READY FOR PHASE 62`**

All five specification correction areas (A–E) are mathematically/technically sound, grounded in repository source inspection, and consistent across all nine deliverables. Phase 61.1 stops here pending explicit authorization to implement Phase 62.
