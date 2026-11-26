# LOCALCONVERT — PHASE 63: AUDIO LIBRARY & PLAYBACK SYSTEM IMPLEMENTATION REPORT

**Phase:** Phase 63 — Audio Library & Playback System  
**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Target Platform:** macOS 15.0+ (`MACOSX_DEPLOYMENT_TARGET: "15.0"`), Apple Silicon (`arm64`)  
**Language & Concurrency:** Swift `6.0` (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Project Generator:** XcodeGen (`project.yml` -> `LocalConvert.xcodeproj`, Version `2.48.0`)  
**Host Verification Environment:** macOS `27.2.1` (`Build 26B131`), Apple Swift `6.4.2`, SQLite `3.54.0`, Bundled FFmpeg `9.0.2`  
**Final Classification:** **READY WITH DOCUMENTED LIMITATIONS**

---

## 1. Executive Summary

Phase 63 implements the end-to-end **Audio Library** and **Independent Audio Playback System** within `LocalConvert/AudioWorkspace/`, building directly on the Phase 61/61.1 architectural specifications and the Phase 62 domain/sample-frame foundation without disrupting the existing Conversion Workspace, Audio Toolbox/Editor, Watch Folders, or Metadata workflows.

Key deliverables completed and verified:

1. **Persistent SQLite Audio Library (`AudioLibraryDatabase`)**: Actor-isolated `libsqlite3` persistence with lazy creation under `AppStoragePaths.audioLibraryDatabaseURL`, WAL journaling, strict foreign keys (`ON DELETE CASCADE`), `ON CONFLICT(id) DO UPDATE` upserts that preserve user ratings/favorites/play counts and playlist memberships, explicit write-transaction rollback atomicity, schema versioning (`user_version = 1` + future-version guard), `PRAGMA quick_check`/`integrity_check` with `Quarantine/` recovery, and external-content FTS5 (`assets_fts`) paired with a runtime compile probe and parameterized SQLite `LIKE` fallback.
2. **Incremental Folder Scanner (`AudioLibraryScanner` & `AudioLibraryBookmarkHelper`)**: Security-scoped folder bookmarks with stale-bookmark refresh, iterative DFS traversal excluding hidden/AppleDouble/temporary files, package directories, symlink cycles, and duplicate canonical paths/hardlinks (`fileResourceIdentifierKey`), bounded extraction concurrency (`4`), batched SQLite writes (`25`), clean distinction between unreadable/permission-denied folders and missing tracks, non-destructive root removal, and responsive `CancellationError` handling.
3. **Read-Only Metadata & Artwork Caching (`AudioMetadataExtractor` & `AudioArtworkProvider`)**: Non-mutating technical/tag inspection combining `AVAudioFile`, bundled `ffprobe`, and existing `AudioMetadataProvider`; missing tags stay `nil` rather than synthesized from filenames; partial (`64 KB`) SHA-256 hashing; and sandbox-isolated cover artwork normalization via `ImageIO` (`<= 15 MB` input cap, invalid/corrupt image rejection, `<= 512 px` downscaling, SHA-256 disk deduplication under `AppStoragePaths.audioArtworkCacheDirectory`, and bounded LRU + `NSCache`).
4. **Independent Playback Engine (`AudioLibraryPlayerEngine`, `AudioPlaybackDecoder`, `PlaybackQueueManager`, `PlaybackStatePersistence`, `PlaybackCoordinator`)**: Completely decoupled from `ConversionManager` and `AudioEditorPlaybackEngine`. Supports native streaming decoding (`AVAudioFile`) for exact frame seeking and bounded `FFmpegStreamingPlaybackDecoder` subprocess streaming for non-native formats (`FLAC`/`ALAC`/`MP3`/`WAV`/`AIFF`/`OGG`/`Opus` verified directly in tests), monotonic generation counters to discard stale callbacks after rapid seek/skip/cancel, bounded in-flight PCM scheduling (`maxChunksInFlight = 4`), full queue management (repeat off/one/all, shuffle preserving `originalOrderIDs`, play next, enqueue, move, remove), and persistent session restoration (`player-session.json`) that forces `.paused` / `.stopped` and never auto-plays on relaunch.
5. **Workspace UI & App Navigation Integration**: `AudioWorkspaceCoordinator`, `AudioWorkspaceRootView`, `AudioLibrarySidebarView`, `AudioLibraryTrackListView`, `AudioPlayerBarView`, and `AudioPlaybackQueuePopover`, styled with `AppTheme` / `DesignSystem`, Phase 59-safe local SwiftUI state bindings, and explicit `audioworkspace.*` accessibility identifiers, wired into `AppNavigationTab.audioWorkspace` (`⌘9`) while leaving Conversion Workspace and Undo/Redo contexts untouched (`OperationContext.resolve(.audioWorkspace) -> nil`).

Three defects uncovered during Phase 63 automated testing were diagnosed and resolved prior to final verification:
- Corrected external-content FTS5 `assets_ad` and `assets_au` triggers in `AudioLibraryDatabase.swift` so `'delete'` statements supply all 10 column values (`assets_fts, rowid, filename, title, artist, album, album_artist, genre, composer, comment`).
- Fixed CoreAudio `OSStatus -39` (`eofErr`) in `NativeAVAudioPlaybackDecoder.readNextChunk` by clamping read counts to remaining frames (`file.length - file.framePosition`) and treating `-39` as clean EOF.
- Eliminated an intermittent hang on `FFmpegStreamingPlaybackDecoder.close()` (observed on `opus`/`ogg` pipe termination) by replacing `FileHandle.readabilityHandler` + blocking `waitUntilExit()` with a utility-queue stderr drain, `-nostdin`, closing read-side pipes before `proc.terminate()`, and async `terminationHandler` + 150 ms / 500 ms `SIGKILL` fallbacks.

---

## 2. Architecture & Component Boundaries

Phase 63 preserves LocalConvert's three-layer separation (`UI` -> `Integration/Stores` -> `Domain/Services/Engines`) and establishes clear module ownership inside `LocalConvert/AudioWorkspace/`:

- **Domain (`LocalConvert/AudioWorkspace/Domain/`, Phase 62):** `SampleFrameTime`, `SourceFrameTime`, `AudioAsset`, `AudioMetadata`, `LibraryRootFolder`, `AudioLibrary`, `AudioCollection`, `AudioPlaylist`, `PlaybackQueue`, `PlaybackSession`, `PlaybackTransportState`, and `StructuredDiagnostics`.
- **Library (`LocalConvert/AudioWorkspace/Library/`):**
  - `AudioLibraryDatabase` (`actor`): Sole owner of the SQLite connection (`SQLITE_OPEN_FULLMUTEX` + Swift actor serialization), schema, FTS5/LIKE queries, playlists, collections, and integrity recovery.
  - `AudioArtworkProvider` (`actor`) + `AudioArtworkImageCache` (`@MainActor`): Cover artwork validation, `ImageIO` thumbnailing, SHA-256 disk dedup, and bounded LRU / `NSCache`.
  - `AudioMetadataExtractor` (`actor`) + `AudioLibraryFormatSupport`: Read-only technical stream inspection (`AVAudioFile` + bundled `ffprobe`) and metadata tag extraction via reused `AudioMetadataProvider`.
  - `AudioLibraryScanner` (`actor`) + `AudioLibraryBookmarkHelper`: Security-scoped folder traversal, incremental diffing, missing/inaccessible detection, bounded parallel extraction, and batched DB writes.
  - `AudioLibrarySearchService` (`actor`), `AudioCollectionService` (`actor`), `AudioPlaylistService` (`actor`), `AudioLibraryIndexCoordinator` (`@MainActor`), and `AudioLibraryStore` (`@MainActor`): Coordinated store and query/mutation facades with monotonic `refreshGeneration` cancellation safety.
- **Playback (`LocalConvert/AudioWorkspace/Playback/`):**
  - `AudioPlaybackDecoderProtocol`, `NativeAVAudioPlaybackDecoder` (`actor`), `FFmpegStreamingPlaybackDecoder` (`actor`), `AudioPlaybackDecoderFactory`.
  - `AudioPlaybackTransportProtocol`, `AVAudioEnginePlaybackTransport` (`@MainActor`), and `AudioLibraryPlayerEngine` (`@MainActor`).
  - `PlaybackQueueManager` (`@MainActor`), `PlaybackStatePersistence` (`actor`), and `PlaybackCoordinator` (`@MainActor`).
- **Integration & UI (`LocalConvert/AudioWorkspace/Integration/` & `UI/`):**
  - `AudioWorkspaceCoordinator` (`@MainActor`) connects `AudioLibraryStore` and `PlaybackCoordinator` under lazy ownership by `AppState.audioWorkspace`.
  - Zero coupling to `ConversionManager` (`rg` confirms 0 hits in `LocalConvert/AudioWorkspace/`) and zero code reuse or runtime coupling with `AudioEditorPlaybackEngine`.

---

## 3. Files Created & Modified

### 3.1 New Production Files (20 files, 6,465 lines)

| Layer | File Path | Lines (`wc -l`) |
| --- | --- | ---: |
| Library | `LocalConvert/AudioWorkspace/Library/AudioLibraryDatabase.swift` | 1,652 |
| Library | `LocalConvert/AudioWorkspace/Library/AudioLibraryScanner.swift` | 519 |
| Library | `LocalConvert/AudioWorkspace/Library/AudioLibraryStore.swift` | 376 |
| Library | `LocalConvert/AudioWorkspace/Library/AudioMetadataExtractor.swift` | 342 |
| Library | `LocalConvert/AudioWorkspace/Library/AudioArtworkProvider.swift` | 198 |
| Library | `LocalConvert/AudioWorkspace/Library/AudioPlaylistService.swift` | 99 |
| Library | `LocalConvert/AudioWorkspace/Library/AudioLibraryIndexCoordinator.swift` | 99 |
| Library | `LocalConvert/AudioWorkspace/Library/AudioCollectionService.swift` | 51 |
| Library | `LocalConvert/AudioWorkspace/Library/AudioLibrarySearchService.swift` | 36 |
| Playback | `LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift` | 621 |
| Playback | `LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift` | 609 |
| Playback | `LocalConvert/AudioWorkspace/Playback/PlaybackCoordinator.swift` | 351 |
| Playback | `LocalConvert/AudioWorkspace/Playback/PlaybackQueueManager.swift` | 305 |
| Playback | `LocalConvert/AudioWorkspace/Playback/PlaybackStatePersistence.swift` | 78 |
| Integration | `LocalConvert/AudioWorkspace/Integration/AudioWorkspaceCoordinator.swift` | 76 |
| UI | `LocalConvert/AudioWorkspace/UI/AudioLibraryTrackListView.swift` | 484 |
| UI | `LocalConvert/AudioWorkspace/UI/AudioPlayerBarView.swift` | 236 |
| UI | `LocalConvert/AudioWorkspace/UI/AudioLibrarySidebarView.swift` | 221 |
| UI | `LocalConvert/AudioWorkspace/UI/AudioPlaybackQueuePopover.swift` | 75 |
| UI | `LocalConvert/AudioWorkspace/UI/AudioWorkspaceRootView.swift` | 37 |

### 3.2 New Test & Documentation Files (4 files)

| Category | File Path | Lines (`wc -l`) |
| --- | --- | ---: |
| Unit / Integration Tests | `LocalConvertTests/Phase63AudioLibraryDatabaseTests.swift` | 254 |
| Unit / Integration Tests | `LocalConvertTests/Phase63AudioLibraryScannerAndMetadataTests.swift` | 343 |
| Unit / Integration Tests | `LocalConvertTests/Phase63AudioPlaybackTests.swift` | 477 |
| Phase Report | `docs/PHASE63_IMPLEMENTATION_REPORT.md` | (this file) |

*(New Phase 63 test files total 1,074 lines; total new `.swift` files = 23 files, 7,539 lines.)*

### 3.3 Modified Existing Files (6 files, 2,237 total lines)

*(Note: `AppStoragePaths.swift` and `OperationContext.swift` were untracked files created in prior phases (`??` in `git status`), modified here in the working tree; the remaining four are tracked modifications (`M` in `git status`). `project.yml` already includes `LocalConvert` and `LocalConvertTests` via directory source globs, so `xcodegen generate` incorporated all new `.swift` files cleanly without altering build settings.)*

| File Path | Change Summary | Total Lines (`wc -l`) |
| --- | --- | ---: |
| `LocalConvert/Core/FileManagement/AppStoragePaths.swift` | Added `artworkCacheDirectory: URL` to `AudioWorkspaceStoragePaths`, `resolveAudioWorkspacePaths`, and `static var audioArtworkCacheDirectory` | 332 |
| `LocalConvert/App/AppState.swift` | Added `AppNavigationTab.audioWorkspace` (`"Audio Workspace"`, `"music.note.house"`) and `lazy var audioWorkspace = AudioWorkspaceCoordinator()` | 921 |
| `LocalConvert/App/LocalConvertApp.swift` | Added `CommandMenu("Navigate")` item `"Audio Workspace"` bound to `⌘9` (verified zero shortcut collisions) | 342 |
| `LocalConvert/Features/Home/ContentView.swift` | Routed `case .audioWorkspace:` to `AudioWorkspaceRootView(coordinator: appState.audioWorkspace)` | 165 |
| `LocalConvert/Core/UndoRedo/OperationContext.swift` | Added `case .audioWorkspace: return nil` in `OperationContext.resolve(tab:...)` | 188 |
| `LocalConvertTests/Phase20Tests.swift` | Updated `testAppNavigationTabCases()` expectation from `9` to `10` cases including `.audioWorkspace` | 289 |

---

## 4. Database Schema & Migration Strategy

Implemented in `LocalConvert/AudioWorkspace/Library/AudioLibraryDatabase.swift` using direct C `SQLite3` APIs:

- **Lazy Initialization & Connection Pragmas (`openHandle` / `configureConnectionPragmas`):**
  - Database directory is created only when `AudioLibraryDatabase` first opens a handle (no eager launch-time DB creation unless Audio Workspace initializes or a library call runs).
  - Opens with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`.
  - Configures:
    - `PRAGMA journal_mode = WAL;`
    - `PRAGMA synchronous = NORMAL;`
    - `PRAGMA busy_timeout = 5000;`
    - `PRAGMA foreign_keys = ON;`
- **Schema Versioning & Migration Guard (`bootstrapSchemaAndFTS`):**
  - `currentSchemaVersion = 1`, stored via `PRAGMA user_version`.
  - If `user_version == 0`, executes base table & index DDL inside `BEGIN EXCLUSIVE TRANSACTION` and writes `PRAGMA user_version = 1;` before committing (rolling back cleanly on error).
  - If `foundVersion > currentSchemaVersion`, throws `AudioLibraryDatabaseError.unsupportedSchemaVersion(found:maximumSupported:)`, preventing silent corruption of newer schemas.
- **Tables & Constraints:**
  - `root_folders(id PRIMARY KEY, path UNIQUE, bookmark_data, last_scanned_at, recursive)`
  - `scan_state(root_folder_id PRIMARY KEY REFERENCES root_folders(id) ON DELETE CASCADE, last_started_at, last_completed_at, last_status, discovered_count, indexed_count, error_message)`
  - `assets(id PRIMARY KEY, canonical_path UNIQUE, ..., file_size CHECK (file_size >= 0), sample_rate_hz CHECK (BETWEEN 1 AND 768000), channel_count CHECK (>= 1), frame_count CHECK (>= 0), duration_sec CHECK (>= 0), status CHECK IN ('ok','missing','modified'), rating CHECK (BETWEEN 0 AND 5), ...)` with indexes `idx_assets_content_hash`, `idx_assets_size_partial`, `idx_assets_artist_album`, and `idx_assets_status`.
  - `playlists(id PRIMARY KEY, name, description, created_at, updated_at)`
  - `playlist_items(playlist_id REFERENCES playlists(id) ON DELETE CASCADE, position, asset_id REFERENCES assets(id) ON DELETE CASCADE, PRIMARY KEY (playlist_id, position))`
  - `smart_collections(id PRIMARY KEY, name, icon_name, filter_json, sort_field, sort_ascending, created_at)`
- **Cascade & Incremental Safety:**
  - Asset persistence uses `INSERT INTO assets ... ON CONFLICT(id) DO UPDATE SET ...`, updating metadata/technical columns while intentionally preserving user-owned columns (`play_count`, `last_played_at`, `is_favorite`, `rating`, `added_at`) and avoiding `INSERT OR REPLACE` so incremental re-indexing never fires `ON DELETE CASCADE` on `playlist_items`.
- **Corruption Detection & Quarantine Recovery (`verifyIntegrity`, `recoverFromCorruptionIfNeeded`):**
  - Runs `PRAGMA quick_check;` (or `PRAGMA integrity_check;` when `full == true`), plus external-content `assets_fts` integrity-check (`INSERT INTO assets_fts(assets_fts) VALUES('integrity-check');`). If only the FTS index is inconsistent, rebuilds `assets_fts` non-destructively.
  - On base corruption or `SQLITE_CORRUPT` / `SQLITE_NOTADB`, closes the connection, moves `.sqlite`, `-wal`, and `-shm` files into `<dbDir>/Quarantine/<timestamp>-corrupt.sqlite*`, records a sanitized diagnostics event, and initializes a clean schema.

---

## 5. FTS5 Availability & LIKE Fallback Behavior

- **Runtime Probe (`probeAndSetupFTS5`):**
  - Queries `SELECT sqlite_compileoption_used('ENABLE_FTS5');` on connection bootstrap (overridable via `forceDisableFTS5: true` for fallback verification).
  - Host macOS SQLite `3.54.0` verified `ENABLE_FTS5 == 1`.
- **External-Content FTS5 Setup:**
  - Virtual table `assets_fts USING fts5(filename, title, artist, album, album_artist, genre, composer, comment, content='assets', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2')`.
  - Synchronized via triggers `assets_ai` (AFTER INSERT), `assets_ad` (AFTER DELETE), and `assets_au` (AFTER UPDATE OF those 8 indexed columns).
  - If pre-existing `assets` rows are detected when `assets_fts` is first created, executes `INSERT INTO assets_fts(assets_fts) VALUES('rebuild');`.
- **Tokenization, Escaping & Parameterized `LIKE` Fallback (`searchAssets`, `searchAssetsWithLikeLocked`):**
  - `extractSearchTokens(from:)` splits Unicode alphanumerics and underscores cleanly, neutralising punctuation/FTS operator injection (e.g., quotes, `"or"`, `AND`, `%`, `\`).
  - When FTS5 is enabled, binds `"token"*` prefix query terms against `assets_fts MATCH ?` ordered by `bm25(assets_fts)`.
  - When `fts5Enabled == false`, falls back to bound parameterized `LOWER(COALESCE(col,'')) LIKE ? ESCAPE '\'` clauses across all 8 searchable columns, escaping `\`, `%`, and `_` in each bound pattern.
  - `Phase63AudioLibraryDatabaseTests.testFTS5AndLikeFallbackSearchEquivalenceRebuildAndCollectionFiltering` verified identical result sets across all 7 query patterns (`"Miles"`, `"Miles Kind"`, `"Jazz"`, `"Prelude"`, `"so_what"`, `"%"`, `"quoted'test \"or\" AND"`) as well as FTS rebuild integrity.

---

## 6. Library Scanner Implementation

Implemented in `LocalConvert/AudioWorkspace/Library/AudioLibraryScanner.swift`:

- **Iterative DFS Traversal (`discoverAudioFiles`):**
  - Uses an explicit directory stack instead of deep recursion.
  - `contentsOfDirectory(at:includingPropertiesForKeys:options:[.skipsHiddenFiles, .skipsPackageDescendants])` skips hidden folders and bundle/package internals (`.rtfd`, `.logicx`, `.app`, etc.).
  - Explicitly filters `.isHidden`, `.isPackage`, dot/AppleDouble/tilde filenames (`"."`, `"._"`, `"~"`), symlink directory cycles (`visitedDirectories` keyed by standardized resolved directory path), temporary/incomplete download extensions (`tmp`, `temp`, `part`, `partial`, `crdownload`, `download`, `utpart`, `swp`, `bak`), empty (`size <= 0`) files, duplicate canonical paths (`seenCanonicalFiles`), and hardlinks (`seenFileResourceIDs` via `.fileResourceIdentifierKey`).
- **Missing vs. Permission-Denied Distinction:**
  - If root folder disappears from disk or listing the root fails, marks `scan_state` as `.failed` with clear message (`"Folder is unavailable or does not exist."` vs. `"Permission denied accessing library folder."`) and leaves existing indexed tracks untouched rather than purging user playlists/ratings.
  - If a subfolder throws during enumeration, appends it to `inaccessibleDirectories` and excludes paths inside unreadable folders (and folders where `!fm.isReadableFile(atPath: parentDir)`) from missing-track marking; only files confirmed absent inside readable directories are transitioned to `AssetStatus.missing`.
- **Bounded Concurrency & Batch Persistence:**
  - Concurrent extraction pool bounded to `maxExtractionConcurrency = 4` via `withThrowingTaskGroup`.
  - Flushes extracted records in batches of `databaseBatchSize = 25` inside explicit SQLite write transactions.
  - On `CancellationError`, flushes any buffered batch already extracted cleanly, persists `.cancelled` scan state, and rethrows `CancellationError`.
- **Non-Destructive Removal:**
  - `removeRootFolder(id:removeIndexedAssets:)` only removes database rows and never deletes or modifies source audio files on disk.

---

## 7. Incremental Indexing & File Identity Strategy

- **Identity Preservation:** Assets are keyed by `canonicalPath` (unique constraint) and stable `UUID` `id`. Re-scanning an already indexed path reuses `existingID`, `existingDateAdded`, `existingPlayCount`, `existingLastPlayedAt`, `existingIsFavorite`, `existingRating`, and valid `bookmarkData`.
- **Fast Change Detection:** For each discovered file, `scanRootFolder` compares `status == .ok`, `fileSizeBytes`, and `abs(modificationTime - candidate.modTime) < 0.001`. Unchanged files are counted as `skippedUnchangedCount` without reopening `AVAudioFile` or spawning `ffprobe`.
- **File Fingerprint:** During extraction, `AudioMetadataExtractor.computePartialSHA256` hashes only the first `65_536` bytes (`64 KB`) to produce `partialHashSHA256` without reading entire multi-hundred-megabyte files into memory.
- **Verified Behavior:** `testDiscoveryExclusionsSymlinkCyclesCanonicalDedupAndIncrementalUpdates` proved:
  - Rescan 1 -> 3 indexed, source WAV SHA-256 unchanged.
  - Rescan 2 -> 0 new/updated, 3 skipped.
  - Modifying WAV frame count (changing size) -> 1 updated, 2 skipped, existing asset UUID and `isFavorite = true` preserved.

---

## 8. Metadata Extraction & Actual Format Coverage

Implemented in `LocalConvert/AudioWorkspace/Library/AudioMetadataExtractor.swift`:

- **Format Capability Table (`AudioLibraryFormatSupport`):**
  - `nativePlaybackFormats`: `.wav`, `.aiff`, `.caf`, `.mp3`, `.m4a`, `.m4b`, `.aac`, `.alac`, `.flac` (`9` formats).
  - `ffmpegPlaybackFormats`: `.ogg`, `.opus`, `.wv`, `.wma`, `.mka`, `.ac3`, `.eac3`, `.dts`, `.au`, `.amr`, `.ape` (`11` formats).
  - `losslessAudioFormats`: `.wav`, `.aiff`, `.caf`, `.flac`, `.alac`, `.wv`, `.ape` (plus codec-name check `"alac"` / `"flac"`).
  - `.aif` / `.aifc` extensions resolve to `.aiff`; detection validates `.category == .audio`.
- **Extraction Pipeline:**
  - Probes native headers safely via `AVAudioFile(forReading:)` (no full-file PCM load) and supplements missing `bitDepth`/`bitrateBps`/`codecName` (and `.flac`/`.m4a`/`.alac` container metadata) or non-native formats using bundled `ffprobe` via `AsyncProcessRunner` (`15 s` timeout, `.nullDevice` stdin).
  - Reuses existing `AudioMetadataProvider().readMetadata(from: url)` for unified tag and attached-picture extraction.
  - Trims whitespace and converts empty strings to `nil`; missing tags stay `nil` (never fabricated from filenames).
- **Verified Format Extraction in Phase 63 Tests:**
  - Directly verified metadata & technical extraction against real files: untagged `WAV`, FFmpeg-tagged `FLAC` (with embedded artwork + fraction `3/10` track tags + year + losslessness), tagged `MP3` (ID3v2 + embedded artwork), tagged `OGG` (Vorbis), `AIFF`, and malformed `corrupt.flac` (`AudioMetadataExtractionError` thrown safely). Source file SHA-256 hashes confirmed unchanged before and after extraction.

---

## 9. Artwork Extraction & Caching

Implemented in `LocalConvert/AudioWorkspace/Library/AudioArtworkProvider.swift`:

- **Sandbox Path Isolation:** Defaults to `AppStoragePaths.audioArtworkCacheDirectory` (`.../Caches/AudioArtworkCache` in test sandboxes via `resolveAudioWorkspacePaths`, never host user caches during tests).
- **Validation & Normalization (`normalizeArtworkData` via `ImageIO`):**
  - Rejects empty data and payloads `> 15 MB` (`maxInputByteCount = 15 * 1024 * 1024`).
  - Validates via `CGImageSourceCreateWithData` (`kCGImageSourceShouldCache: false`), image count `> 0`, and non-zero pixel width/height; rejects non-image/corrupt bytes cleanly (`nil`).
  - Preserves already-compact JPEG/PNG covers `<= 512 x 512` px; downscales larger/other image formats with `CGImageSourceCreateThumbnailAtIndex` (`maxThumbnailDimensionPixels = 512`, `kCGImageSourceCreateThumbnailWithTransform: true`) and re-encodes as JPEG (`0.85`).
- **Content-Addressed Deduplication & Bounded Caching:**
  - Keyed by `"art-\(sha256Prefix32)"`; atomic temporary write moved cleanly into `<key>.jpg`.
  - Sanitized key path validation blocks `/` and `..` traversal.
  - Actor in-memory data LRU bounded to `16 MB` default (`memoryByteLimit`), paired with `@MainActor AudioArtworkImageCache` `NSCache` capped at `countLimit = 96` and `totalCostLimit = 32 MB`.
  - Directly verified in `testMetadataAndArtworkExtractionDownscalingDeduplicationAndMalformedRejection` (`900x900` PNG downscaled `<= 512 px`, identical inputs deduplicated to identical key inside test sandbox, invalid payload rejected as `nil`).

---

## 10. Playback Engine Architecture

Implemented in `LocalConvert/AudioWorkspace/Playback/`:

- **Decoupled Transport Abstraction (`AudioPlaybackTransportProtocol`):**
  - `@MainActor` protocol with `volume`, `rate`, `configure(sampleRate:channelCount:)`, `startEngine()`, `playNode()`, `pauseNode()`, `stopAndResetNode()`, `scheduleChunk(_:onRendered:)`, and `currentRenderedFramesSinceReset()`.
  - `AVAudioEnginePlaybackTransport` owns a private `AVAudioEngine` -> `AVAudioPlayerNode` -> `AVAudioUnitTimePitch` -> `mainMixerNode` graph and subscribes to `.AVAudioEngineConfigurationChange` via a weakly stored `Task` cancelled cleanly on `deinit`.
- **Streaming Player Engine (`AudioLibraryPlayerEngine`):**
  - Published state: `activeAssetID`, `activeURL`, `streamInfo`, `playbackState` (`PlaybackTransportState`), `position` (`SourceFrameTime?`), `totalFrames`, `volume`, `isMuted`, `preMuteVolume`, `playbackRate`.
  - Bounded buffer scheduling: reads chunks of `chunkFrameCount = 8_192` frames on the decoder actor, caps active scheduled buffers at `maxChunksInFlight = 4` (`~0.68 s` at 48 kHz), refills strictly from chunk completion callbacks (`.dataPlayedBack`), and emits `onTrackEnded` only when `decoderReachedEOF && inFlightChunkCount == 0`.
  - Cancellation & Stale-Generation Safety: monotonic `generation: UInt64` invalidates any in-flight `load`, `seek`, or chunk-decode callback whose generation does not match; `teardownLock` cancels background tasks and closes any live decoder cleanly in `deinit`.
  - Completely independent from `AudioEditorPlaybackEngine` and `ConversionManager`.

---

## 11. Decoder Paths & Verified Codec Coverage

Implemented in `LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift`:

- **Native Path (`NativeAVAudioPlaybackDecoder`):**
  - Covers `nativePlaybackFormats` (`wav`, `aiff`, `caf`, `mp3`, `m4a`, `m4b`, `aac`, `alac`, `flac`).
  - Streams `AVAudioPCMBuffer` chunks in `AVAudioFile.processingFormat`, clamps requested frame counts to remaining length (`total - currentPos`), maps CoreAudio `OSStatus -39` (`eofErr`) cleanly to EOF (`nil`), and reports `isExactFrameSeekSupported = true`.
- **Bundled FFmpeg Streaming Path (`FFmpegStreamingPlaybackDecoder`):**
  - Covers `ffmpegPlaybackFormats` (`ogg`, `opus`, `wv`, `wma`, `mka`, `ac3`, `eac3`, `dts`, `au`, `amr`, `ape`).
  - Probes stream metadata via bundled `ffprobe` (`15 s` timeout), then spawns bundled `ffmpeg` (`-v error -nostdin [-ss <sec>] -i <path> -vn -sn -dn -f f32le -ac <ch> -ar <sr> pipe:1`) on demand.
  - Safe process teardown (`ProcessStateBox`): drains `stderr` on a background `.utility` queue (bounded `8 KB` tail), closes read-side `stdout` and `stderr` pipes *before* signaling `terminate()` (unblocking child pipe writes immediately via `EPIPE`), waits asynchronously with `terminationHandler`, and falls back to `SIGKILL` after `150 ms` (`terminateAndDetach`) or `500 ms` (`awaitProcessExit`). Deinterleaves `f32le` bytes to non-interleaved `[Float]` channel planes on `ioQueue`.
- **Codec Audit & Runtime Verification:**
  - Bundled `./LocalConvert/Resources/ffmpeg/ffmpeg -decoders` confirmed support for `aac`, `ac3`, `alac`, `amrnb`, `amrwb`, `ape`, `dca`, `eac3`, `flac`, `mp3`, `mp3float`, `opus`, `libopus`, `vorbis`, and `wavpack` alongside macOS CoreAudio support.
  - `Phase63AudioPlaybackTests.testRealDecodersAcrossNativeAndFFmpegFormatsIncludingSeek` executed real decode + chunk read + midpoint seek + clean close across **7 formats** (`wav`, `aiff`, `flac`, `alac`/`.m4a`, `mp3` via `.nativeAVAudioFile`; `ogg`, `opus` via `.bundledFFmpeg`) and verified clean error rejection on `not_audio.txt` (`.unsupportedFormat("txt")`) and `corrupt_play.flac` (`AudioPlaybackError`), additionally passing a 10-iteration consecutive stress run in `2.837 s`.
  - Remaining mapped formats (`caf`, `m4b`, `aac`, `wv`, `wma`, `mka`, `ac3`, `eac3`, `dts`, `au`, `amr`, `ape`) did not have per-container fixtures synthesized in Phase 63 tests; they route through the verified `AVAudioFile` / bundled FFmpeg 9.0.2 backends.

---

## 12. Seeking Precision & Frame/Time Conversion

- **Sample-Frame Domain Conversion:** `AudioLibraryPlayerEngine.seek(to: SourceFrameTime)` converts incoming `SourceFrameTime` across sample rates using `frameTime.raw.converted(to: info.sampleRate)`, clamps strictly to `0...totalFrames`, resets the audio node (`stopAndResetNode()`), seeks the decoder, updates `seekAnchorFrame` and `position` (`SourceFrameTime`), and preserves `.playing` vs. `.paused` transport state (promoting `.stopped` -> `.paused`). Verified cross-rate conversion (`44,100 @ 44.1 kHz` -> `48,000 @ 48 kHz`) and overshoot clamping (`999.0 s` -> `96,000 frames`) in `testPlayerEngineStateMachineSeekingCancellationAndBoundedBuffers`.
- **Progress Tracking:** `AVAudioEnginePlaybackTransport.currentRenderedFramesSinceReset()` offsets `seekAnchorFrame` clamped to `totalFrames`; UI time displays derive seconds via `SampleFrameTime.derivedSeconds`.
- **Backend Precision Boundary:**
  - `NativeAVAudioPlaybackDecoder` assigns `file.framePosition = clamped` directly (`isExactFrameSeekSupported == true`).
  - `FFmpegStreamingPlaybackDecoder` restarts the streaming decode child process using FFmpeg demuxer seek `-ss <seconds>` (`isExactFrameSeekSupported == false`), yielding container packet/keyframe-level precision rather than decoded-PCM frame-exact offsets for compressed non-native formats.

---

## 13. Playback Queue & Session Behavior

Implemented in `PlaybackQueueManager`, `PlaybackStatePersistence`, and `PlaybackCoordinator`:

- **Queue Operations (`PlaybackQueueManager`):**
  - `setQueue`, `playNext`, `enqueue`, `selectTrack`, `move(fromOffsets:toOffset:)`, `remove(at:)`, `clear`.
  - `setShuffleEnabled(_:)` anchors the currently playing track at index `0` while shuffling remaining entries, and restores `originalOrderIDs` aligned to the active track when disabled.
  - `setRepeatMode` supports `.off`, `.one`, and `.all`; `stepPrevious` restarts the current track when elapsed `> 3.0 s` or steps backward (wrapping under `.repeatAll`).
  - `remove(at:)` removing the active track cleanly computes and returns the replacement track ID (or stops if empty).
- **Session Persistence & No Auto-Play Rule (`PlaybackStatePersistence` & `PlaybackCoordinator`):**
  - Debounced (`250 ms`) and explicit (`flushPersistedSession`) atomic JSON writes (`replaceItemAt` via temp file) to `AppStoragePaths.audioPlayerStateURL` (`player-session.json`), storing `schemaVersion = 1`, `PlaybackQueue`, and `PlaybackSession` (track ID, `SourceFrameTime`, volume, mute, pre-mute volume, rate).
  - **Both `save` and `loadRestoredState` coerce `.playing` / `.loading` to `.paused` (when `activeAssetID != nil`) or `.stopped`.** `restoreSavedSessionIfPresent()` loads the saved track (`autoPlay: false`) and restores `position`, volume, mute, rate, and queue without starting the audio node (`XCTAssertFalse(transport2.isNodePlaying)` verified in end-to-end integration test).

---

## 14. Playlist & Collection Persistence

- **Playlists (`AudioPlaylistService` + `playlists` / `playlist_items` tables):**
  - Create, rename, delete, append, remove by position index, remove all occurrences by `assetID`, and drag-reorder (`moveEntries(in:fromOffsets:toOffset:)`).
  - Explicitly allows duplicate track appearances at distinct contiguous `position` integers; deleting an asset row (`ON DELETE CASCADE`) cleans up its `playlist_items` rows and compacts remaining positions cleanly (`testTransactionRollbackAtomicityCascadeAndPlaylistPositionCompaction`).
  - Deleting a playlist or item touches only SQLite rows and never deletes disk audio files (`testEndToEndWorkspaceIntegrationPlaylistPlaySearchAndRestoreWithoutAutoPlay`).
- **Collections (`AudioCollectionService` + `smart_collections` table + `AudioCollectionFilter`):**
  - Persists custom collection filters (`losslessOnly`, `hiResOnly` defined as `> 48 kHz || >= 24-bit`, `favoritesOnly`, `missingOnly`, `minimumRating`, `recentDaysWindow`, `formatFilter`, optional `searchQuery`), sort field (`title`, `artist`, `album`, `duration`, `sampleRate`, `dateAdded`, `lastPlayed`, `playCount`), and sort direction.

---

## 15. UI Integration & Accessibility

- **Design Tokens & Isolation:** All views under `LocalConvert/AudioWorkspace/UI/` consume existing `AppTheme.Colors`, `AppTheme.Typography`, `AppTheme.Spacing`, `AppTheme.Radius`, and `AppEmptyStateView` tokens. SwiftUI controls (`AudioLibrarySidebarView`, `AudioLibraryTrackListView`, `AudioPlayerBarView`) bind to local `@State` mirrors synchronized asynchronously to avoid Phase 59 `"Publishing changes from within view updates"` warnings.
- **Main App Wiring:**
  - `AppNavigationTab.audioWorkspace` added after `.audioToolbox`; `SidebarView` auto-generates `sidebar.tab.audio_workspace`.
  - `CommandMenu("Navigate")` assigns `⌘9` to `"Audio Workspace"` (tabs use `⌘1`–`⌘9`, `⌥⌘Z` for history; zero shortcut collisions).
  - `OperationContext.resolve(tab: .audioWorkspace)` returns `nil`, keeping Conversion / Audio Editor Undo stacks unaffected.
- **Accessibility Identifiers Present:**
  - Sidebar: `audioworkspace.sidebar.all_tracks`, `.artists`, `.albums`, `.genres`, `.favorites`, `.lossless`, `.missing_files`, `.add_playlist`, `.add_folder`, `audioworkspace.playlist.name_field`, `audioworkspace.playlist.create_confirm`.
  - Track List & Toolbar: `audioworkspace.library.search_field`, `.sort_picker`, `.cancel_scan`, `.rescan_all`, `.track_list`.
  - Player Bar & Queue: `audioworkspace.player.shuffle`, `.previous`, `.play_pause`, `.next`, `.repeat`, `.scrubber`, `.mute`, `.volume`, `.queue_button`, `audioworkspace.queue.clear`.

---

## 16. Concurrency & Resource-Management Decisions

- **Strict Swift 6 Isolation (`SWIFT_STRICT_CONCURRENCY: complete`):**
  - Long-running I/O (`AudioLibraryDatabase`, `AudioLibraryScanner`, `AudioMetadataExtractor`, `AudioArtworkProvider`, both decoders, `PlaybackStatePersistence`) runs in `actor` isolation; UI/engine state (`AudioLibraryPlayerEngine`, `AudioLibraryStore`, `PlaybackCoordinator`, `PlaybackQueueManager`, `AudioWorkspaceCoordinator`) stays on `@MainActor`.
  - Built cleanly with zero `@unchecked Sendable` additions on model/store types (narrow `@unchecked Sendable` is confined internally to `SQLiteHandleBox` / `ProcessStateBox` protected by SQLite mutex/locks).
- **Subprocess & File Handle Safety:** `FFmpegStreamingPlaybackDecoder` drains `stderr` continuously via utility queue loops (capped at 8 KB), closes reading pipe ends prior to `terminate()`, and backs termination with bounded timeouts and `SIGKILL` fallback so child processes cannot deadlock actor shutdown or accumulate zombies.
- **Memory & Query Bounds:** `AudioLibraryScanner` caps parallel extraction at `4` tasks and commits in `25`-row batches; `AudioLibraryPlayerEngine` bounds buffered chunks to `maxChunksInFlight = 4`; `AudioMetadataExtractor` hashes only `64 KB` headers; artwork caches bound disk/memory sizes (`<= 512 px`, `16 MB` actor LRU, `96` items / `32 MB` `NSCache`).

---

## 17. Security-Scoped Folder Access & Bookmark Handling

- **`AudioLibraryBookmarkHelper`:** Creates security-scoped bookmarks (`[.withSecurityScope]`) with non-scoped fallback for non-sandboxed paths, and resolves bookmarks with `[.withSecurityScope, .withoutUI]`.
- **Automatic Stale Refresh:** When `scanRootFolder` detects `isStale == true`, it recreates and persists refreshed bookmark data into `root_folders`.
- **Scoped Access Lifetime:**
  - During scanning, `scanRootFolder` calls `startAccessingSecurityScopedResource()` paired immediately with `defer { resolvedURL.stopAccessingSecurityScopedResource() }`.
  - During playback, `PlaybackCoordinator` resolves per-asset bookmarks (falling back to `canonicalPath`), holds the active security-scoped URL inside `scopedURLLock: OSAllocatedUnfairLock<URL?>`, releases previous scope before switching tracks, and revokes any remaining scope on `stop()`, `unload()`, load failure, or `deinit`.

---

## 18. Privacy & Diagnostics

- **Zero Network Activity:** No network requests, telemetry, analytics, or external service calls exist in any Phase 63 component; all indexing, decoding, artwork processing, and search execute offline on device.
- **Non-Destructive Guarantee:** Source audio files are opened strictly read-only across scanning, metadata extraction, FFprobe inspection, artwork extraction, and decoding; playlist, collection, and root removals operate solely on SQLite/cache files.
- **Sanitized Diagnostics:** Diagnostics calls in `AudioLibraryDatabase`, `AudioLibraryScanner`, `AudioLibraryPlayerEngine`, and `PlaybackCoordinator` use `StructuredDiagnostics.recordAudioEvent` with category, severity, stage, extension, and UUID/counts—never file paths, track titles, artists, albums, or user tags. Verified directly in `testAudioCollectionBookmarkStoreBrowsingAndSanitizedDiagnostics` (`XCTAssertFalse(diagSummary.contains("SecretTrackTitle"))`, artist, album, and folder path).

---

## 19. Build Results

All builds executed sequentially on `arm64` after all code edits (`LocalConvert.xcodeproj` regenerated via `xcodegen generate` with exit code `0`):

| Build Step | Command / Log | Outcome | Compiler / `minos` Warnings |
| --- | --- | --- | --- |
| Project Regeneration | `xcodegen generate` | `exit 0` (`LocalConvert.xcodeproj` updated) | 0 |
| Build for Testing (`arm64`) | `xcodebuild build-for-testing -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'` (`/tmp/phase63_build_for_testing.log`) | `** TEST BUILD SUCCEEDED **` (`exit 0`) | 0 Swift/ObjC/`minos` warnings |
| Clean Build (`arm64`) | `xcodebuild clean build -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'` (`/tmp/phase63_final_clean_build.log`) | `** BUILD SUCCEEDED **` (`exit 0`) | 0 Swift/ObjC/`minos` warnings *(1 pre-existing Xcode `appintentsmetadataprocessor` informational notice: no AppIntents.framework dependency)* |
| Incremental Build (`arm64`) | `xcodebuild build -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'` (`/tmp/phase63_final_inc_build.log`) | `** BUILD SUCCEEDED **` (`exit 0`) | `Copy Bundled Binaries` skipped (`COPY_BUNDLED_SKIPPED` verified) |

---

## 20. Test Results

*(All reported final runs occurred strictly after the final source/test edit. During initial Stage 1 and first Stage 3 development prior to the fixes listed in Section 1, three failures/timeouts were encountered—FTS5 trigger arity, CoreAudio `-39` EOF on native seek, and `FFmpegStreamingPlaybackDecoder` hang on `opus` pipe close—and all three were fixed in source before final verification.)*

### 20.1 Summary by Verification Stage

| Suite / Stage | Log File | Executed | Passed | Failed | Skipped | Not Run | Notes |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Stage 1 — Phase 63 Targeted XCTest (`Phase63AudioLibraryDatabaseTests` 4, `ScannerAndMetadata` 3, `Playback` 5) | `/tmp/phase63_stage1_p63.log` | 12 | 12 | 0 | 0 | 0 | Completed in `1.721 s` |
| FFmpeg Close Stress Check (`testRealDecodersAcrossNativeAndFFmpegFormatsIncludingSeek` x 10) | `/tmp/phase63_stress10.log` | 10 | 10 | 0 | 0 | 0 | Ran after decoder fix (`2.837 s`); production code identical to final |
| Stage 3 — Full `LocalConvertTests` (XCTest) | `/tmp/phase63_stage3_full_tests.log` | 93 | 91 | 0 | 2 | 0 | Completed in `15.242 s`; skips are RAW env-var gated (`LOCALCONVERT_RAW_SAMPLES_DIR`) |
| Stage 3 — Full `LocalConvertTests` (Swift Testing) | `/tmp/phase63_stage3_full_tests.log` | 603 | 603 | 0 | 0 | 0 | `77 / 77` suites passed in `256.134 s` (includes `Phase20Tests`, `Phase20BTests`, `AudioExportProTests`, Phase 45 audio suites, Smart Preset suites) |
| Stage 4 — XCUITest (`LocalConvertUITests/Phase57UITests`) | `/tmp/phase63_stage4_p57_ui.log` | 6 | 6 | 0 | 0 | 0 | Completed in `68.299 s`; 0 `Publishing changes`, QoS, or `Thread Performance` warnings |
| New Audio Workspace Interactive XCUITests | — | 0 | 0 | 0 | 0 | N/A | Dedicated UI tests for `AudioWorkspaceRootView` not implemented in Phase 63 |

### 20.2 Stage 3 XCTest Per-Class Breakdown (`/tmp/phase63_stage3_full_tests.log`)

- `Phase49DataSafetyAndUndoTests`: 7 passed, 0 failed, 0 skipped
- `Phase50CoreFeatureUndoTests`: 7 passed, 0 failed, 0 skipped
- `Phase51VideoTrimTests`: 8 passed, 0 failed, 0 skipped
- `Phase52WatchFolderTests`: 10 passed, 0 failed, 0 skipped
- `Phase53VerificationTests`: 4 passed, 0 failed, 1 skipped (`testGenuineCameraRAWSamplesIfProvided` — `LOCALCONVERT_RAW_SAMPLES_DIR` not configured)
- `Phase55VerificationTests`: 5 passed, 0 failed, 0 skipped
- `Phase56RAWAndPipelineTests`: 4 passed, 0 failed, 1 skipped (`testGenuineCameraRAWSamplesMatrixIfProvided` — `LOCALCONVERT_RAW_SAMPLES_DIR` not configured)
- `Phase57DiagnosticsAndSplitTests`: 3 passed, 0 failed, 0 skipped
- `Phase58TestIsolationTests`: 6 passed, 0 failed, 0 skipped
- `Phase58_1UserDefaultsIsolationTests`: 5 passed, 0 failed, 0 skipped
- `Phase59SwiftUIStateUpdateTests`: 3 passed, 0 failed, 0 skipped
- `Phase60QoSSynchronizationTests`: 6 passed, 0 failed, 0 skipped
- `Phase62AudioDomainFoundationTests`: 11 passed, 0 failed, 0 skipped
- `Phase63AudioLibraryDatabaseTests`: 4 passed, 0 failed, 0 skipped
- `Phase63AudioLibraryScannerAndMetadataTests`: 3 passed, 0 failed, 0 skipped
- `Phase63AudioPlaybackTests`: 5 passed, 0 failed, 0 skipped

---

## 21. Performance Observations & Known Limitations

- **Verified Timing:** Full Phase 63 targeted suite (including FFmpeg fixture synthesis, FLAC/MP3/OGG/Opus metadata & decode/seek verification, corrupted DB quarantine recovery, artwork downscaling, and workspace persistence round-trip) runs in `1.721 s`. Full `LocalConvertTests` (93 XCTest + 603 Swift Testing) completed in `273.398 s` total (`15.242 s` XCTest + `256.134 s` Swift Testing), and `Phase57UITests` (`6/6`) in `68.299 s`.
- **Known Limitations:**
  1. **FFmpeg Seeking Granularity:** Non-native formats (`OGG`, `Opus`, etc.) rely on FFmpeg `-ss` demuxer seeking (`isExactFrameSeekSupported = false`) rather than sample-accurate random frame addressing.
  2. **Playback Transport Test Coverage:** `AudioLibraryPlayerEngine` scheduling, seeking, cancellation, and buffer caps were verified against `MockPlaybackTransport`, while `AVAudioEnginePlaybackTransport` underwent construction, graph configuration (`48 kHz / 2 ch`), and volume/rate setup smoke testing without automated speaker output assertion.
  3. **Codec Sample Coverage vs. Format Table:** All 7 tested codecs (`wav`, `aiff`, `flac`, `alac`, `mp3`, `ogg`, `opus`) passed real decode + seek checks and `wav`/`flac`/`mp3`/`ogg` passed metadata extraction checks; the remaining 13 formats declared in `AudioLibraryFormatSupport` (`caf`, `m4b`, `aac`, `wv`, `wma`, `mka`, `ac3`, `eac3`, `dts`, `au`, `amr`, `ape`) were not individually exercised with dedicated test fixtures in Phase 63.
  4. **Audio Workspace XCUITest Coverage:** Existing `Phase57UITests` (`6/6`) verified app stability, while interactive UI driving specifically inside `AudioWorkspaceRootView` remains manual/unautomated until dedicated Phase 64/UI tests are added.
  5. **macOS 15 Runtime Environment:** Verified statically (`MACOSX_DEPLOYMENT_TARGET: "15.0"`, `MinOS: macOS 15.0`); all tests ran on macOS `27.2.1` (`arm64`), not dynamically on a macOS 15 OS image/VM.

---

## 22. Dependency Audit

Executed `./scripts/verify-dependencies.sh` (`/tmp/phase63_verify_deps.log`), exiting `0`:
- XcodeGen `2.48.0` verified.
- `libwebp` & `libsharpyuv` (`arm64`, zero Homebrew linkage, `MinOS: macOS 15.0`) verified.
- `libjxl` v0.13.0 static archives (`arm64`, `MinOS: macOS 15.0`) & headers verified.
- Bundled `ffmpeg` & `ffprobe` (`ffmpeg version 9.0.2`, `arm64`, zero Homebrew linkage, `MinOS: macOS 15.0`) verified.
- Bundled LibreOffice `26.8.0.3` (`arm64`, zero Homebrew linkage, `MinOS: macOS 11.0`, `codesign --verify --deep --strict` pass) verified.
- Third-party notices (`LICENSE`, `LICENSE.webp`, `LICENSE.jxl`, `FFmpeg-LICENSE.txt`, both `THIRD_PARTY_NOTICES.md`) and `AppIcon` metadata verified.
- Zero external libraries or Homebrew dependencies were added by Phase 63 (`libsqlite3` is system-bundled macOS SQLite).

---

## 23. Git & User-Data Preservation Verification

All preservation invariants matched the pre-Phase 63 baseline after all builds and test suites completed:
- **`defaults export com.localconvert.app - | shasum -a 256`:** `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` (exact match to starting baseline).
- **`/Applications/LocalConvert.app` mtime:** `1795224025` (unmodified).
- **Real User Directories vs. `/tmp/phase58_1_userdata_baseline.json`:**
  - `~/Library/Application Support/com.localconvert.app`: `baseline=89`, `current=89`, `added=0`, `removed=0`, `changed=0`
  - `~/Library/Logs/LocalConvert`: `baseline=0`, `current=0`, `added=0`, `removed=0`, `changed=0`
  - `~/Library/Caches/com.localconvert.app`: `baseline=37`, `current=37`, `added=0`, `removed=0`, `changed=0`
- **Git Preservation:** No pre-existing uncommitted work was reverted, committed, stashed, or cleaned (`292` lines total in `git status --short` reflecting the `289`-line starting tree plus the new untracked Phase 63 `AudioWorkspace` subdirectories and tests).

---

## 24. Unresolved Issues

No failing tests, build errors, concurrency warnings, data-loss defects, or sandbox leaks remain open at Phase 63 closure. The only unexecuted runtime checks are the documented coverage gaps listed in Section 21 (dynamic macOS 15.0 OS execution, dedicated `AudioWorkspaceRootView` XCUITests, individual fixtures for the 13 secondary container extensions beyond the 7 tested codecs, and optional hardware `LOCALCONVERT_RAW_SAMPLES_DIR` tests).

---

## 25. Phase 64 Readiness Assessment & Final Classification

All architectural modules, SQLite schema/FTS5/fallback guarantees, security-scoped incremental scanner, read-only metadata/artwork pipeline, independent streaming playback engine, session persistence without unsolicited auto-play, UI integration, and full test regressions are complete and verified. None of the remaining coverage gaps block Phase 64 work; Phase 64 can proceed cleanly to build visual playback/waveform inspection, advanced Audio Workspace features, and interactive UI tests on top of this verified base.

**Final Classification:** **READY WITH DOCUMENTED LIMITATIONS**
