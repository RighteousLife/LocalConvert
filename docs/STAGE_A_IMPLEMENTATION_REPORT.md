# STAGE_A_IMPLEMENTATION_REPORT.md

**Stage:** Stage A — Audio Foundation & Sample-Accurate Editing Core *(Consolidates Original Phases 65 + 66)*  
**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Branch / HEAD:** `main` (`85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`)  
**Target Platform:** macOS 15.0+ (`MACOSX_DEPLOYMENT_TARGET: "15.0"`), Apple Silicon (`arm64`), Swift `6.0` (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Verification Host:** macOS `27.2.1` (`Build 26B131`), Xcode `27.2` (`Build 27B52`), Apple Silicon (`arm64`)  
**Final Classification:** **READY WITH DOCUMENTED LIMITATIONS**

---

## 1. Executive Summary

Stage A delivered both required foundational tracks cleanly inside LocalConvert without altering existing Conversion Workspace behavior or performing premature UI redesigns:

1. **Track A1 — Multi-Resolution Peak Pyramid Waveform Engine (Original Phase 65):**
   - Implemented [WaveformPyramid.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Domain/WaveformPyramid.swift) defining pure `Sendable` domain models for 5-tier mipmaps (`64 / 256 / 1024 / 4096 / 16,384` frames/bucket), per-channel `[minSample, maxSample, rms, clipped]`, safe `bestLevel(forSamplesPerPixel:)`, memory estimation, and empty pyramids.
   - Implemented [LCWaveDiskCache.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Waveform/LCWaveDiskCache.swift) under `AppStoragePaths.audioWaveformCacheDirectory` with a 68-byte little-endian `.lcwave` binary format, SHA-256 cache keys and payload verification, unaligned-safe decoding, integer-overflow guards, atomic `.tmp` + `replaceItemAt` writes, automatic deletion/recovery on corrupt files, and `512 MB` LRU disk eviction.
   - Implemented [WaveformPyramidService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Waveform/WaveformPyramidService.swift) combining `Accelerate`/`vDSP`, native `AVAudioFile` streaming, bundled FFmpeg streaming pipes, a `64 MB` RAM LRU cache, ref-counted in-flight deduplication, cooperative cancellation, and `PCMChunkLimitPolicy` enforcing both `<= 65,536` frames AND `<= 256 KiB` (`262,144` bytes) aggregate decoded PCM payload per processing chunk.
   - Preserved [WaveformRenderingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/WaveformRenderingService.swift) (`StereoWaveformData` API) while adding a non-breaking `pyramid(for:)` compatibility bridge.

2. **Track A2 — Sample-Accurate Non-Destructive Editing & Project Schema v3 (Original Phase 66):**
   - Upgraded [AudioEditorModels.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditorModels.swift) to `schemaVersion = 3` storing authoritative integer frame coordinates (`timelineStartFrame`, `sourceStartFrame`, `durationFrames`, `projectRate`, `sourceRate`, `ClipFadeSpecFrames`, `AudioMarker.frame`), `AudioMediaReference.contentSHA256` / `relativePath` / `durationFrames`, `linkedLibraryAssetMap`, and backward-compatible derived `TimeInterval` accessors.
   - Added deterministic `v1/v2 -> v3` decode migration (`SampleFrameMigration`) using `Decimal` half-away-from-zero rounding (`.plain`), rejecting `NaN`, `±Inf`, negative coordinates/durations, invalid sample rates, unsupported schema versions, and `Int64` overflows while leaving legacy `.lcproject` files untouched on disk during load.
   - Refactored [AudioEditingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditingService.swift) and [AudioMixingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioMixingService.swift) (`AudioGainAutomation.clipGain(track:clip:atFrame:)`) to compute Split, Trim, Cut, Copy, Paste, Delete, Ripple Delete, Move, Nudge, Insert Silence, Join/Consolidate (sample-adjacent heal), Gain, Fades, Channel Ops, Crossfades, and Markers in checked `Int64` sample frames with zero-length `SampleFrameRange` safe no-ops.
   - Updated [ProjectPersistenceService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/ProjectPersistenceService.swift) (`formatVersion = 3`) and [AudioEditorStore.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditorStore.swift) (`buildMediaReference`) with non-destructive load, `.lcprojpkg` traversal/symlink security preserved, relative-path + bookmark + sibling-folder + `contentSHA256` cross-Mac relinking, and restart undo journal preservation via [AudioEditorUndoCommands.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditorUndoCommands.swift).

---

## 2. Original Baseline & Preservation Status

All pre-existing repository work, user preferences, bundled app binary, `project.yml`, and host user directories were preserved completely untouched:

| Preservation Check | Pre-Stage A Baseline | Final Post-Stage A State | Delta / Verification |
| --- | --- | --- | --- |
| Branch / `HEAD` | `main` / `85d6ba2cd4a6ffb5cf41700c3d288947f2945d99` | `main` / `85d6ba2cd4a6ffb5cf41700c3d288947f2945d99` | Identical (no commits/resets/stashes) |
| Staged changes (`git diff --cached`) | `0` | `0` | Clean |
| Tracked modified files (`git diff --name-only`) | `78` | `78` | Only `LocalConvert.xcodeproj/project.pbxproj` (already in the `78`) updated via `xcodegen generate` |
| `project.yml` | Modified in pre-existing baseline (`Nov 22 14:01`) | `Nov 22 14:01` (`12,886` bytes) | Zero edits during Stage A |
| `git status --short` line count | `297` | `299` (prior to report) / `300` (with report) | `+1` new folder (`LocalConvert/AudioWorkspace/Waveform/`), `+2` test files, `+1` report (`WaveformPyramid.swift` in already-untracked `Domain/`) |
| `defaults export com.localconvert.app - \| shasum -a 256` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` | Identical (`0` preference writes) |
| `/Applications/LocalConvert.app` mtime | `1795224025` | `1795224025` | Identical |
| User dirs (`Application Support=89`, `Caches=37`, `Logs=0`) | Recorded in `/tmp/phase58_1_userdata_baseline.json` | `app_support=89`, `caches=37`, `logs=0` | `added=0, removed=0, changed=0` across all 3 trees |

---

## 3. Files Created and Modified

### 3.1 Created Files (6 files)

| File Path | Role | Line Count (`wc -l`) |
| --- | --- | ---: |
| [WaveformPyramid.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Domain/WaveformPyramid.swift) | 5-tier mipmap pyramid, buckets, channel levels, progress model, zoom selector | 157 |
| [LCWaveDiskCache.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Waveform/LCWaveDiskCache.swift) | Atomic `.lcwave` little-endian disk cache actor with SHA-256 verification & 512 MB LRU eviction | 342 |
| [WaveformPyramidService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Waveform/WaveformPyramidService.swift) | Dual-bounded `vDSP` streaming pyramid builder (`AVAudioFile` + bundled FFmpeg pipes), 64 MB RAM LRU, dedup & cancellation | 1,216 |
| [Phase65WaveformPyramidTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase65WaveformPyramidTests.swift) | Track A1 XCTest suite (mip accuracy, chunk boundaries, FFmpeg pipe, disk/RAM LRU, corruption recovery, dedup, cancel, 5m stress) | 485 |
| [Phase66SampleEditingAndMigrationTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase66SampleEditingAndMigrationTests.swift) | Track A2 XCTest suite (v1/v2->v3 migration, validation, non-destructive load, sample-frame edit ops, 1,000 split/join cycles, cross-Mac SHA-256 relink, undo rehydration) | 485 |
| `docs/STAGE_A_IMPLEMENTATION_REPORT.md` | Stage A technical completion report | — |

### 3.2 Modified Files (8 existing untracked files + `project.pbxproj`)

| File Path | Summary of Changes | Line Count (`wc -l`) |
| --- | --- | ---: |
| [WaveformRenderingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/WaveformRenderingService.swift) | Preserved `StereoWaveformData` API; added `pyramid(for:)` bridge to `WaveformPyramidService.shared` | 260 |
| [AudioEditorModels.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditorModels.swift) | Upgraded to `schemaVersion = 3`, integer frame storage on `AudioClip`/`AudioMarker`/`AudioEditorProject`, `ClipFadeSpecFrames`, `SampleFrameMigration`, `AudioMediaReference.contentSHA256`/`relativePath`/`durationFrames` | 1,079 |
| [AudioEditingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditingService.swift) | Checked `Int64` sample-frame editing (`split`, `trim`, `cut`, `copy`, `paste`, `delete`, `rippleDelete`, `nudge`, `insertSilence`, `join`/`consolidate`, `setGain`, `setFadeIn/Out`, `setChannelMode`, `markers`) + `TimeInterval` wrappers | 1,079 |
| [AudioMixingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioMixingService.swift) | Migrated `AudioGainAutomation` (`clipGain(track:clip:atFrame:)`), mixer interpolation, and `AudioSourceResolver` direct base frames to sample frames | 494 |
| [ProjectPersistenceService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/ProjectPersistenceService.swift) | Bumped `formatVersion = 3`; kept load strictly non-destructive; added relative-path/bookmark/sibling/SHA-256 cross-Mac relinking (`relinkByContentHash`) | 513 |
| [AudioEditorStore.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditorStore.swift) | Updated `buildMediaReference(for:)` to populate `durationFrames` and streaming `contentSHA256` | 1,087 |
| [Phase45IntegrationTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase45IntegrationTests.swift) | Updated line 225 hardcoded `schemaVersion == 2` assertion to `AudioEditorProject.currentSchemaVersion` (`3`) | 424 |
| `LocalConvert.xcodeproj/project.pbxproj` | Regenerated via `xcodegen generate` (`project.yml` untouched) to register Stage A files | — |

*(Verified unchanged companion file: [AudioEditorUndoCommands.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditorUndoCommands.swift), `125` lines, already encodes/rehydrates `AudioEditorProject` v3 frames cleanly.)*

---

## 4. Track A1 Architecture — Multi-Resolution Peak Pyramid Model

Defined in [WaveformPyramid.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Domain/WaveformPyramid.swift) with zero UI framework imports:

- **Hierarchy (`WaveformPyramid.standardBucketSizes`):** `[64, 256, 1024, 4096, 16_384]` frames/bucket (5 levels, factor `4` between consecutive levels).
- **Channel & Bucket Fidelity (`WaveformBucket`, `WaveformChannelLevel`, `WaveformMipLevel`):** Stores per-channel `[minSample, maxSample, rms, clipped]` where `clipped` captures peak magnitudes `abs(sample) >= 1.0`.
- **Zoom Selection (`bestLevel(forSamplesPerPixel:)`):** Returns the coarsest level whose `framesPerBucket <= samplesPerPixel` to avoid undersampling, returning the finest (`64`) level for `<= 0` or `NaN`, coarsest (`16,384`) for `+Inf`, and `nil` when `levels` is empty.
- **Empty & Partial Safety:** `WaveformPyramid.empty(...)` constructs 5 valid 0-bucket levels; `WaveformBuildProgress` reports `completedFrames`, `totalFrames`, `isComplete`, and partial `pyramid` snapshots during streaming.

---

## 5. Track A1 Disk Cache Architecture (`.lcwave`)

Implemented in [LCWaveDiskCache.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Waveform/LCWaveDiskCache.swift) using `AppStoragePaths.audioWaveformCacheDirectory`:

- **Cache Key (`cacheKey(canonicalPath:fileSize:modificationTime:channelCount:)`):** Lowercase hex `CryptoKit.SHA256` over `canonicalPath|fileSize|Int64((mtime*1000).rounded())|channelCount|v1`.
- **Binary Layout:** Little-endian `68`-byte header (`"LCWAVE01"` magic, `UInt32` version `1`, `Int32` sampleRate, `UInt32` channelCount `1...64`, `Int64` totalFrames `>= 0`, `UInt32` levelCount `1...16`, `UInt32` flags `0`, `32`-byte SHA-256 payload digest) followed by per-level `(framesPerBucket, bucketCount)` and `16`-byte bucket records (`Float32` LE min/max/rms, `UInt8` clipped, `3` reserved zero bytes).
- **Safety & Recovery:** Uses unaligned-safe byte decoding, checked integer multiplication before allocation, finite/non-negative sample assertions, exact length check (`offset == data.count`), atomic `.<key>.<uuid>.tmp` + `replaceItemAt` writes, automatic deletion of corrupt/truncated/mismatching files on load returning `nil`, and `512 MB` default LRU disk eviction by modification date.

---

## 6. Track A1 Streaming Decode, Dual PCM Chunk Policy & Concurrency

Implemented in [WaveformPyramidService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Waveform/WaveformPyramidService.swift):

- **Dual PCM Input Chunk Bounds (`PCMChunkLimitPolicy`):**
  - `maxFramesPerChunk = 65_536` frames
  - `maxInputPayloadBytes = 262_144` bytes (`256 KiB`) aggregate across all channels/planes
  - Formula: `maxFrames(channelCount, bytesPerSample) = min(65_536, floor(262_144 / (channelCount * bytesPerSample)))`.
  - Validated on every decoded chunk across native `AVAudioFile` and FFmpeg streaming pipes.
- **Native Path (`AVAudioFile` + `Accelerate`/`vDSP`):** Allocates a single reusable `AVAudioPCMBuffer` sized to `maxFrames`, clamps reads to remaining frames (treating CoreAudio `-39` `eofErr` as clean EOF), computes `vDSP_minv`, `vDSP_maxv`, `vDSP_svesq` into a `Double`-precision RMS accumulator (`PyramidAccumulator`), and folds `4:1` hierarchies with exact sample-count weighting.
- **Bundled FFmpeg Streaming Pipe Fallback:** Probes with `BundledFFmpegProvider(fallbackToSystem: false)`, streams `f32le` from `ffmpeg -nostdin ... pipe:1` in bounded `<= 262,144`-byte chunks using an alignment-safe carry-over buffer and unaligned LE reader, drains `stderr` asynchronously on `.utility`, closes read-side pipes before `terminate()` (`200 ms` `SIGKILL` fallback) on cancellation/error, and awaits clean process exit.
- **Memory & Task Deduplication:** Maintains a `64 MB` RAM LRU cache and ref-counted `inFlightBuilds` table so concurrent requests share one decode, partial cancellation does not abort live siblings, and cancelling all waiters cancels the underlying decode cleanly without leaks.

---

## 7. Track A2 Project Schema v3 & Legacy v1/v2 Migration

Implemented in [AudioEditorModels.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditorModels.swift):

- **Canonical Integer Coordinates:**
  - `AudioClip`: `timelineStartFrame`, `sourceStartFrame`, `durationFrames`, `projectRate`, `sourceRate`, `fadeInFrames: ClipFadeSpecFrames?`, `fadeOutFrames: ClipFadeSpecFrames?`, `timelineEndFrame`, `timelineRange`, `sourceSpanFrames`.
  - `AudioMarker`: `frame: Int64`, `sampleRate: SampleRate`.
  - `AudioMediaReference`: added `contentSHA256`, `relativePath`, `durationFrames`, and streaming 64 KiB `sha256Hex(of:)`.
  - `AudioEditorProject`: bumped `currentSchemaVersion = 3`, added `projectSampleRate: SampleRate`, `linkedLibraryAssetMap: [UUID: UUID]`, `lastExportConfiguration: AudioExportConfiguration?`, `durationFrames`.
- **Legacy v1/v2 Decode Migration:** `AudioEditorProject.init(from:)` validates `schemaVersion` (`1...3`) and `sampleRate` (`1...768_000` finite), decodes legacy v1/v2 structures using the project's decoded sample rate and `Decimal` half-away-from-zero rounding (`.plain`), rejects `NaN`, `±Inf`, negative coordinates/durations/fades, and `Int64` overflows (`AudioProjectMigrationError`), and upgrades the returned in-memory struct to `schemaVersion = 3` without modifying the source file on disk.

---

## 8. Track A2 Sample-Accurate Editing Core & Mixing

- **[AudioEditingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioEditingService.swift):**
  - Re-implemented `split`, `splitAll`, `splitAtSelection`, `trimClip`, `trimEdges`, `trimToSelection`, `deleteClips`, `deleteRange`, `cut`, `copy`, `paste`, `moveClip`, `nudge`, `duplicate`, `insertSilence`, `join` (with `consolidate` delegating to `join`), `addClip`, `replaceClip`, `setGain`, `setFadeIn`, `setFadeOut`, `setChannelMode`, `applyCrossfade`, `moveGroupClips`, and marker mutations using checked `Int64` sample-frame arithmetic (`addingReportingOverflow`).
  - Enforced safe zero-length `SampleFrameRange` / `<= 0`-frame no-op semantics (`changed == false`, empty cut).
  - Enforced exact sample-adjacent `join` healing (`a.timelineEndFrame == b.timelineStartFrame` and exact contiguous source frames `a.sourceStartFrame + a.sourceSpanFrames == b.sourceStartFrame`, or reverse symmetric condition).
- **[AudioMixingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioMixingService.swift):**
  - Added `AudioGainAutomation.clipGain(track:clip:atFrame:)` evaluating fades (`ClipFadeSpecFrames`) and true same-track crossfades in integer frame space, updated `AudioMixSession.mixClip` interpolation to call `atFrame:`, and updated `AudioSourceResolver` to use `clip.sourceStartFrame` directly when source and project rates match.

---

## 9. Track A2 Persistence, Cross-Mac Relinking & Undo Integration

- **[ProjectPersistenceService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/ProjectPersistenceService.swift):**
  - Bumped `AudioProjectDocument.currentFormatVersion = 3` and upgraded projects on `save`/`saveReturningURL` and `writeAutosave`.
  - Populated `contentSHA256`, `relativePath`, and `.minimalBookmark` data on save; preserved strict `.lcprojpkg` `Media/` path traversal and symlink-escape rejection (`AuditRemediationTests.testM5` passing).
  - Guaranteed non-destructive `load(from:)`: never mutates the loaded file on disk while resolving missing assets in order: `relativePath` (verified inside project subtree or by SHA-256), `bookmarkData`, `relinkByContentHash` (size pre-filter + streaming SHA-256 scan across moved/renamed files), and legacy filename fallback.
- **Undo/Redo Journal Preservation:** Confirmed `AudioProjectMutationCommand` and `AudioEditorUndoRehydrator` serialize and restore `v3` integer coordinates cleanly across `.audioEditor(projectID:)` isolation and restart recovery (`Phase66` + `Phase45` + `AuditRemediationTests` `H1`).

---

## 10. Deviation Log vs. Roadmap & Plan

1. **Test Alignment in `Phase45IntegrationTests.swift:225` (Requires Explicit Note):**
   - `Phase45IntegrationTests.autosaveRecoveryAndRelinkingV2` previously hardcoded `#expect(recovered.schemaVersion == 2)`, which failed (`3 != 2`) once Stage A upgraded `AudioEditorProject.currentSchemaVersion` to `3` and `writeAutosave` persisted v3.
   - Aligned line 225 to `#expect(recovered.schemaVersion == AudioEditorProject.currentSchemaVersion)` (matching the pattern already used by `AudioChainPresetPersistenceTests.swift:154`).
2. **Test Adjustments During First Stage A Verification Run (`Phase65` & `Phase66`):**
   - `Phase65WaveformPyramidTests.testLCWaveDiskCacheRoundTrip...`: Initial test used `maxBytes = 12_000`, which was smaller than a single `40,000`-frame stereo `.lcwave` file (`26,828` bytes), so `LCWaveDiskCache.evictIfNeeded(excludingFileName:)` retained the latest `26,828`-byte file. Raised the test cap to `60_000` bytes so 2 newest entries fit and 3 older entries are evicted under cap.
   - `Phase66SampleEditingAndMigrationTests.testOneThousandSplitJoinCycles...`: Initial loop asserted unchanged `4,410`-frame `fadeInFrames` even when prime split offsets landed inside `[1, 4409]` (where `split()` legitimately clamps `left.fadeInFrames` to `leftDurFrames`). Split the 1,000 cycles into `500` fade-preserving exterior splits + `500` arbitrary edge splits, asserting `0` frames sample drift across all `1,000` cycles at both `48,000 Hz` and `44,100 Hz`.

---

## 11. Dual PCM Chunk Boundary Matrix (Verified)

Tested in `Phase65WaveformPyramidTests.testDualPCMChunkLimitExactBoundariesAndRejections` across BOTH `isPlanar = false` (interleaved) and `isPlanar = true` (planar), proving `maxFrames` acceptance and `maxFrames + 1` rejection:

| Format / Width | Channels | `maxFrames` Accepted | Aggregate Payload at Boundary | `maxFrames + 1` Rejected |
| --- | ---: | ---: | ---: | --- |
| Mono Float32 (`4 B`) | 1 | `65,536` | `262,144` bytes (`256 KiB`) | `65,537` (`Frame` cap exceeded) |
| Stereo Float32 (`4 B`) | 2 | `32,768` | `262,144` bytes (`256 KiB`) | `32,769` (`256 KiB` cap exceeded) |
| 5.1 Surround Float32 (`4 B`) | 6 | `10,922` | `262,128` bytes (`255.98 KiB`) | `10,923` (`256 KiB` cap exceeded) |
| 8-ch Surround Float32 (`4 B`) | 8 | `8,192` | `262,144` bytes (`256 KiB`) | `8,193` (`256 KiB` cap exceeded) |
| Mono Int16 (`2 B`) | 1 | `65,536` | `131,072` bytes (`128 KiB`) | `65,537` (`Frame` cap exceeded) |
| Stereo Int16 (`2 B`) | 2 | `65,536` | `262,144` bytes (`256 KiB`) | `65,537` (`256 KiB` + `Frame` cap) |
| 6-ch Int16 (`2 B`) | 6 | `21,845` | `262,140` bytes | `21,846` (`256 KiB` cap exceeded) |
| 8-ch Int16 (`2 B`) | 8 | `16,384` | `262,144` bytes (`256 KiB`) | `16,385` (`256 KiB` cap exceeded) |
| Mono Float64 (`8 B`) | 1 | `32,768` | `262,144` bytes (`256 KiB`) | `32,769` (`256 KiB` cap exceeded) |
| Stereo Float64 (`8 B`) | 2 | `16,384` | `262,144` bytes (`256 KiB`) | `16,385` (`256 KiB` cap exceeded) |

Runtime streaming verification in `testMultichannelWAVStreamingRespectsRuntimeChunkLimits` and `testFFmpegStreamingFallbackMatchesNative...` confirmed observed chunk frames `<= maxFrames` (`1ch/2ch/6ch/8ch`) and observed PCM payload `<= 262,144` bytes across both native `AVAudioFile` and bundled FFmpeg pipe backends.

---

## 12. Sample Conservation & Migration Proof

- **1,000-Cycle Split/Join Proof (`Phase66`):** Verified across `1,000` sequential `split` + `join` cycles at `48,000 Hz` AND `1,000` sequential cycles at `44,100 Hz` starting from `timelineStartFrame = 12_345`, `sourceStartFrame = 67_890`, `durationFrames = 960_001`: **0 frames drift** in `timelineStartFrame`, `durationFrames`, `sourceStartFrame`, or `timelineEndFrame`; `1`-frame gap clips cleanly refused `join` (`0` merges).
- **Rounding & Rejection (`Phase66`):** Verified `Decimal` `.plain` half-away-from-zero ties (`0.125s @ 44.1kHz -> 5,513`, `0.375s @ 44.1kHz -> 16,538`, `0.0000625s @ 40kHz -> 3`), valid `v1 -> v3` and `v2 -> v3` upgrade, clean rejection of `NaN`, `+Inf`, `-Inf`, negative clip/fade/marker values, invalid sample rates (`0`, `900,000`), future schema (`99`), and `Int64` overflows (`1e16`).
- **Non-Destructive Load Proof (`Phase66`):** Verified raw on-disk byte digest (`diskBytesBefore == diskBytesAfter`) and file modification timestamp (`diskMtimeBefore == diskMtimeAfter`) of legacy `v2` `.lcproject` files remain unchanged after `ProjectPersistenceService.load(from:)`.

---

## 13. Build, Dependency & Test Verification Summary

All builds and test runs executed sequentially after the final source edits:

### 13.1 Build & Dependency Audits

| Check | Command | Outcome | Notes |
| --- | --- | --- | --- |
| Clean `arm64` App Build | `xcodebuild clean build -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'` | **PASS** (`exit 0`) | `** BUILD SUCCEEDED **`; **0** Swift compiler warnings in app target |
| Incremental `arm64` App Build | `xcodebuild build -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'` | **PASS** (`exit 0`) | `** BUILD SUCCEEDED **` |
| Test Targets Build + Isolation | `xcodebuild test ... Phase58–60 & Phase65–66` | **PASS** (`exit 0`) | **0** warnings in any Stage A source or Stage A test file |
| Dependency Verification | `./scripts/verify-dependencies.sh` | **PASS** (`exit 0`) | Verified `arm64`, minOS `<= 15.0`, zero Homebrew linkage (`libwebp`, `libjxl 0.13.0`, `ffmpeg/ffprobe 9.0.2`, `LibreOffice 26.8.0.3`, notices, AppIcon) |

### 13.2 Executed Test Suites (Post-Final Edit)

| Suite Run Log | Suites Included | Passed | Failed | Skipped | Elapsed |
| --- | --- | ---: | ---: | ---: | ---: |
| `/tmp/stage_a_final_verify.log` | `Phase58TestIsolationTests` (`6`), `Phase58_1UserDefaultsIsolationTests` (`5`), `Phase59SwiftUIStateUpdateTests` (`3`), `Phase60QoSSynchronizationTests` (`6`), `Phase65WaveformPyramidTests` (`8`), `Phase66SampleEditingAndMigrationTests` (`5`) | **33** | **0** | **0** | `10.094s` |
| `/tmp/stage_a_post_edit_regressions.log` (XCTest) | `Phase62AudioDomainFoundationTests` (`11`), `Phase63AudioLibraryDatabaseTests` (`4`), `Phase63AudioLibraryScannerAndMetadataTests` (`3`), `Phase63AudioPlaybackTests` (`5`), `Phase64AudioPlayerTests` (`6`) | **29** | **0** | **0** | `2.789s` |
| `/tmp/stage_a_post_edit_regressions.log` (Swift Testing) | `AudioEditorCoreTests`, `AudioTimelineTests`, `AudioEditorPerformanceTests`, `AudioEditorExportAcceptanceTests`, `AudioChainPresetPersistenceTests`, `AudioDSPTests`, `AudioExportProTests`, `Phase45IntegrationTests`, `AuditRemediationTests` (9 suites total) | **46** | **0** | **0** | `18.664s` |
| **Combined Post-Final-Edit Verification Total** | **20 suites (11 XCTest + 9 Swift Testing)** | **108** | **0** | **0** | `~31.5s` |

*(Unverified in Stage A: non-Audio Workspace legacy suites covering Image/PDF/Office/Video/WatchFolder/Subtitle/App-wide general tests were not re-run in this stage, nor was `LocalConvertUITests`, which is deferred alongside UI cutover to Stage D per roadmap.)*

---

## 14. Observed Performance & Memory Metrics

- **5-Minute Stereo Pyramid Build Stress (`Phase65.testBoundedMemoryLongAudioStressPerformance`):**
  - Fixture: `48,000 Hz`, 2-channel WAV, `14,400,000` frames (~`115.2 MB` raw uncompressed Float32 PCM).
  - Observed Build Time (Debug `-Onone`, Swift 6 complete concurrency checks active): **`7.6966s`** (`7.5706s`–`7.7615s` across verification runs).
  - Runtime Bounded Chunk Telemetry (`metricsForTesting()`): max frames/chunk = **`32,768`**, max PCM chunk input payload = **`262,144` bytes** (`256 KiB`), single reusable `AVAudioPCMBuffer`.
- **6-Stage Multitrack DSP Offline Throughput (`Phase45_Bench_6StageDSP`):**
  - Simulated `60.0s` `48,000 Hz` stereo render elapsed **`12.802s`** (`4.7x` realtime speedup).
- **1,000 Split/Join Conservation Loop (`Phase66` at `48 kHz` + `44.1 kHz` = `2,000` split+join operations):**
  - Completed in **`0.015s`**.

---

## 15. Environment & Scope Limitations

1. **Deployment OS Runtime Validation:** Static deployment compatibility (`MACOSX_DEPLOYMENT_TARGET = 15.0` and `MinOS <= 15.0` on bundled binaries via `vtool`/`otool` in `./scripts/verify-dependencies.sh`) passed; live execution occurred on `macOS 27.2.1` (`Build 26B131`, Xcode `27.2`), so runtime execution on physical/VM `macOS 15.x` was not directly exercised here.
2. **Deferred Non-Audio & UI Test Coverage:** Unrelated `LocalConvertTests` (Image, PDF, Office, WatchFolder, Subtitle) and `LocalConvertUITests` were outside Stage A's targeted suite runs (full app/UI closure belongs to Stage D).
3. **Debug Configuration Only:** Builds and benchmarks ran in `Debug` (`-Onone`), not a signed/notarized `Release` archive.
4. **Stage Scope Strictly Maintained:** Zero UI Canvas changes (Stage C), zero DSP/3-mode export pipeline redesign (Stage B), and zero XCUITest additions (Stage D) were performed in Stage A.

---

## 16. Handoff Readiness & Final Classification

- **Stage A Track A1 & Track A2 Acceptance Gates:** **Met** (`13/13` new Stage A tests passing; `95/95` targeted isolation, audio domain/library/player, audio editor, DSP, export, and undo regression tests passing post-final-edit; `0` Swift compiler warnings in app target and Stage A files; `0` host state mutations).
- **Next Unblocked Stage:** **Stage B — Audio Processing & Export Engine *(Original Phases 67 + 68 + Gapless Evaluation)*** can now build directly upon Stage A's `SampleFrameTime`-accurate editor graph, `ClipFadeSpecFrames`, and `WaveformPyramidService`.
- **Final Classification:** **READY WITH DOCUMENTED LIMITATIONS** *(all Stage A technical criteria verified; limitations strictly reflect untested physical macOS 15.x runtime, Debug-configuration benchmarking, and deferred non-Audio/XCUITest coverage)*.
