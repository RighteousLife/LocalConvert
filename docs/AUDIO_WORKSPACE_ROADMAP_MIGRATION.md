# Audio Workspace — Roadmap Consolidation & Migration Record

**Document ID:** LC-AW-MIG-008  
**Canonical Target Roadmap:** [AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md](file:///Users/cancan/Desktop/LocalConvert/docs/AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md)  
**Baseline History Preserved:** Phases 62–64 Completed (Unrenumbered)  
**Consolidated Forward Stages:** Stage A, Stage B, Stage C, Stage D

---

## 1. Consolidation Rationale

Originally authored during Phase 61 / 61.1, the Audio Workspace plan split post-player work across seven narrow sequential phases (`Phase 65` – `Phase 71`). During execution of Phases 62–64:
1. Phase 63 pulled core Player (`AudioLibraryPlayerEngine`, `PlaybackQueueManager`, decoders, session persistence) and the initial Library/Player SwiftUI shell (`AudioWorkspaceRootView`, `AudioLibrarySidebarView`, `AudioLibraryTrackListView`, `AudioPlayerBarView`, `AudioPlaybackQueuePopover`, `AppNavigationTab.audioWorkspace` / `⌘9`) forward to deliver a working vertical slice early.
2. Phase 64 closed the remaining CoreAudio HAL device-routing (`CoreAudioOutputDeviceMonitor`) and bidirectional arbitration (`PlaybackArbitrationCenter`) gaps.
3. The remaining work naturally groups into **four tightly coupled engineering boundaries** that reduce partial integration churn while keeping backend vs. UI vs. QA gates cleanly separated:
   - **Stage A (Phases 65 + 66):** Shared data/domain core infrastructure for Editor + Timeline (`WaveformPyramid`/`.lcwave` cache + `SampleFrameTime` editing & project `v3` migration). Neither requires UI changes, yet both underpin Stage B processing/export and Stage C Canvas/UI integration.
   - **Stage B (Phases 67 + 68 + Gapless Evaluation):** Shared signal-processing & rendering pipeline (`AudioDSPEngine` preview parity + `AudioExportService` 3-mode hardening + gapless same-rate player evaluation), strictly backend-only.
   - **Stage C (Phases 69 + 70 + Phase 63/64 Deferred UI/Hygiene):** Cohesive native macOS UI integration uniting Library hygiene (`MissingFileReconciler`, `DuplicateDetector`, Inspector origin separation), Persistent Player & CoreAudio Device Picker, Canvas peak-pyramid waveform rendering, keyboard shortcuts, 3-mode export sheet, and accessibility.
   - **Stage D (Phase 71):** Dedicated independent end-to-end XCUITest, large-scale/RAM/FPS benchmarking against unchanged Phase 61.1 hypotheses, OS/hardware checks, full regression, and readiness sign-off.

Keeping **Phases 62–64** untouched as historical completed labels and adopting **`Stage A`–`Stage D`** avoids renumbering confusion across existing phase reports (`PHASE62_*`, `PHASE63_*`, `PHASE64_*`).

---

## 2. Old-to-New Mapping Table

| Original Phase | Original Title | New Status / Stage | Notes |
| --- | --- | --- | --- |
| **Phase 62** | Foundation, Paths, Domain & Diagnostics | **Completed (Phase 62)** | Unchanged ([PHASE62_IMPLEMENTATION_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/PHASE62_IMPLEMENTATION_REPORT.md)). |
| **Phase 63** | SQLite Audio Library, Scanner & Player Foundation | **Completed (Phase 63)** | Delivered Library/Scanner/Player base + initial UI shell ([PHASE63_IMPLEMENTATION_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/PHASE63_IMPLEMENTATION_REPORT.md)); relink/duplicate hygiene carried to Stage C. |
| **Phase 64** | Independent Audio Player, Queue, CoreAudio Routing & Arbitration | **Completed (Phase 64)** | Delivered CoreAudio routing & `PlaybackArbitrationCenter` ([PHASE64_IMPLEMENTATION_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/PHASE64_IMPLEMENTATION_REPORT.md)); gapless same-rate playback tracked to Stage B; device-picker UI & toggle carried to Stage C. |
| **Phase 65** | Multi-Resolution Peak Pyramid Waveform Engine & Progressive `.lcwave` Cache | **Stage A (Track A1)** | Unified with Phase 66 as Audio Foundation & Editing Core. |
| **Phase 66** | Sample-Accurate Non-Destructive Editing Model & v3 Project Migration | **Stage A (Track A2)** | Unified with Phase 65; no Canvas UI changes yet. |
| **Phase 67** | Effects, Processing Integration & Preview Pipeline Hardening | **Stage B (Track B1)** | Includes gapless same-rate player evaluation from Phase 64 report. |
| **Phase 68** | Lossless Export Pipeline Hardening | **Stage B (Track B2)** | Coupled via preview/offline parity & shared `AudioMixingService`. |
| **Phase 69** | Audio Workspace Native macOS UI Integration | **Stage C (Track C1)** | Incorporates `MissingFileReconciler`, `DuplicateDetector`, `AudioOutputDevicePicker`, auto-pause toggle, and `AudioEditorRootView` shell host. |
| **Phase 70** | Waveform Editor UI Upgrade, Shortcuts & Accessibility | **Stage C (Track C2)** | Canvas `.lcwave` cutover, shortcuts, 3-mode Export sheet, VoiceOver/`audioworkspace.*` IDs. |
| **Phase 71** | Full XCUITest, Performance & Release Readiness | **Stage D (Final Gate)** | Preserved 1:1 as independent quality/benchmark/readiness gate. |

---

## 3. Requirements-Preservation Audit

Audit against original `AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md` (LC-AW-ROAD-007), `AUDIO_WORKSPACE_DATA_MODEL.md`, `AUDIO_WORKSPACE_TEST_STRATEGY.md`, `AUDIO_WORKSPACE_UX_SPECIFICATION.md`, and `PHASE64_IMPLEMENTATION_REPORT.md` confirms **zero dropped requirements**:

| Requirement Category | Preserved Exact Bounds / Specifications | Destination |
| --- | --- | --- |
| **Waveform Bounds** | 5 mip levels (`64`, `256`, `1024`, `4096`, `16384`), dual-bounded streaming PCM input chunks (`<= 65,536` frames AND `<= 256 KiB` / `262,144` bytes aggregate decoded PCM input payload computed from actual `channelCount * bytesPerSample`, summing all planes in planar layouts; e.g. Float32: Mono `65,536` / `256 KiB`, Stereo `<= 32,768` / `<= 256 KiB`, 5.1 `10,922` / `255.98 KiB`, 8-ch `8,192` / `256 KiB`; bounds PCM input chunk only—not output buckets, `64 MB` RAM LRU, decoder internals, or total process memory), `64 MB` RAM LRU, `512 MB` `.lcwave` disk eviction, atomic `.tmp` write, `SHA256(path\|size\|mtime_ms\|channels\|v1)` key, `vDSP_minv`/`maxv`/`rmsqv`, mono/stereo/multichannel, `WaveformRenderingService` bridge | **Stage A** |
| **Sample-Frame Editing & Migration** | `Int64` `SampleFrameTime`, `SampleFrameRange`, `ClipFadeSpecFrames`, schema `v3`, deterministic `Decimal` half-away-from-zero `v1/v2 -> v3` decode without overwriting legacy files on read, Cut/Copy/Paste/Delete/Ripple Delete/Trim/Split/Join/Silence/Gain/Fade/Channel ops, zero-length no-ops, `AudioGainAutomation` frames, cross-Mac `.lcprojpkg` + relative path + `contentSHA256` relink, `1,000`-cycle proof | **Stage A** |
| **DSP & Playback Preview** | `AudioDSPEngine` multi-rate/multichannel, peak/LUFS normalize apply helpers, `ClipProxyCache` under `audioEditorProxiesDirectory`, `PlaybackEngine.swift` timeline/seek in `SampleFrameTime`, zero audio-thread allocations, `AudioEffectPresetStore`, preview vs. offline parity, gapless same-rate player evaluation | **Stage B** |
| **Export Pipeline & Phase 61.1 Fixes** | `BitExactPassThrough` (WAV/AIFF payload SHA-256 parity), `LosslessFormatReRender`, `LossyFormatReRender`; `OutputReservationCoordinator` + `audioExportStagingDirectory` (zero `ConversionManager`); `.ogg` `vorbis` fix; 16-bit TPDF dither on PCM/FLAC/`ALAC`, strictly forbidden on `32f`/Pass-Through; `.ape` reject; `validateExportedFile` bit-depth + codec verification; source SHA-256 unchanged; cancellation cleanup | **Stage B** |
| **Workspace, Library & Player UI** | `[Library \| Waveform Editor \| Audio Tools]` shell reusing `AudioEditorRootView` without duplication; Conversion Workspace untouched; `Phase 59` state hygiene; `MissingFileReconciler` + `LibraryMissingRelinkSheet`; `DuplicateDetector`; `AudioLibraryInspectorView` (`Embedded Tags` vs `Library DB Only` + `MetadataManager` split); `AudioOutputDevicePicker`; `PlaybackArbitrationCenter` Settings toggle; modular small view files | **Stage C** |
| **Canvas UI, Shortcuts & a11y** | SwiftUI `Canvas` mipmap selection (`<= viewportWidth * 2` buckets), multichannel lanes, clipping/fades, isolated 60 Hz playhead layer, smooth scroll/zoom; first-responder-safe `Space`, `⌘E`/`B`, `⌘T`, `Delete`/`⌥Delete`, `⌘+`/`⌘-`/`⌘0`, `⌘F`, `⌘I`, `⌘→`/`⌘←`, `←`/`→`, `⌘Z`/`⇧⌘Z`; 3-mode Export Sheet copy + pickers; complete `audioworkspace.*` IDs & VoiceOver labels | **Stage C** |
| **QA, Scale Benchmarks & Closure** | `AudioWorkspaceUITests` (`Phase 57.1`/`58`/`60` compliant), `Phase71AudioWorkspacePerformanceTests` measured against unrelaxed Phase 61.1 targets (`10,000`-row index `<= 15s`, `25,000`-row FTS5 `<= 25ms`, latency `<= 100ms`/`400ms`/`30ms`, 2-hr `96 kHz` WAV RAM delta `<= 120 MB` / `64 MB` LRU, `>= 60 fps`, `>= 10x`/`4x` export), full `LocalConvertTests` + `Phase57UITests`, clean/incremental `arm64` builds, `verify-dependencies.sh`, `UserDefaults`/user-data `0/0/0` diff, macOS 15 & hardware checks (where available), final report | **Stage D** |

---

## 4. Execution Order Changes & Parallelization Model

### Changes vs. Original Roadmap
- **UI integration consolidated:** Phase 69 (Library/Player shell + Inspector + Device Picker) and Phase 70 (Waveform Canvas + Shortcuts + Export Sheet + a11y) now sit inside Stage C **after** both Stage A (`WaveformPyramidService`) and Stage B (`AudioDSPEngine` / `AudioExportService` 3-mode APIs), avoiding throwaway pre-pyramid Canvas work or intermediate Export Sheet bindings between phases.
- **No UI churn inside Stages A–B:** Stage A maintains a `WaveformRenderingService` shim and Stage B requires zero UI edits.
- **Completed Phases 63–64 deferred items anchored cleanly:** Missing-file bookmark/SHA-256 reconciliation and duplicate detection (from Phase 63 roadmap) are explicitly placed into Stage C alongside relink UI; gapless same-rate player transition (from Phase 64) is placed into Stage B for backend evaluation before Stage C UI completion.

### Safe Parallelization & Collision Guidance Within Each Stage
- **Stage A:** Track A1 (`Waveform/` + `WaveformPyramid.swift`) and Track A2 (`AudioEditor/` v3 migration + `AudioEditingService`) can run in parallel, converging only at a serialized `xcodegen generate` / `AudioEditorModels.swift` + `WaveformRenderingService.swift` bridge checkpoint.
- **Stage B:** Gapless same-rate evaluation in `AudioWorkspace/Playback/` can run independently of `Engines/AudioEditor/` work. Inside `Engines/AudioEditor/`, freeze filter/configuration interfaces before splitting `AudioDSPEngine`/`PlaybackEngine` (Track B1) from `AudioExportService` (Track B2), and assign `AudioMixingService.swift` strictly to one stream at a time.
- **Stage C:** Track C1 (Library hygiene + Inspector + Device Picker views) and Track C2 (`Features/AudioEditor/` Canvas + Export Sheet + Shortcuts) live in distinct directories and can build in parallel, followed by serialized wiring into shared `AudioWorkspaceRootView.swift`, `AudioToolboxView.swift`, `AppState.swift`, and `AppSettings.swift`.
- **Stage D:** Sequential verification gate only (never run concurrent `xcodebuild` commands against the same `DerivedData` `XCBuildData/build.db`).

---

## 5. Historical Discrepancies & Open Ambiguities

1. **Completed Phase 63 Naming / Scope Drift:** Repository contains `AudioLibraryDatabase.swift`, `AudioLibraryScanner.swift`, and `PlaybackQueueManager.swift` instead of original roadmap names `SQLiteLibraryDatabase.swift`, `LibraryFolderScanner.swift`, and `PlaybackQueueController.swift`; Phase 63 also created early `AudioWorkspace/UI/` views ahead of Phase 69, while omitting `MissingFileReconciler` and `DuplicateDetector` (explicitly carried into Stage C). **Resolution:** Preserve actual Phase 63 filenames (`PHASE63_IMPLEMENTATION_REPORT.md` is authoritative) and do not perform speculative file renames.
2. **FFmpeg Decoder Proxy vs. Pipe Streaming:** Original Phase 64 roadmap referenced `ClipProxyCache` for unreadable formats in `AudioLibraryPlayerEngine`, whereas Phase 63 implemented real-time bounded subprocess streaming (`FFmpegStreamingPlaybackDecoder`, supporting packet-level `-ss` seek) while reserving `ClipProxyCache` for timeline editing in `AudioMixingService.swift`. **Resolution:** Document this separation accurately; retain live `FFmpegStreamingPlaybackDecoder` for low-latency library streaming and harden `ClipProxyCache` for timeline DSP in Stage B.
3. **Hardware & macOS 15.0 Verification Environment Gap (From Phase 63 & Phase 64 Reports):** All tests to date executed on host macOS `27.2.1` (`arm64`) using deterministic HAL/transport mocks plus read-only CoreAudio enumeration; macOS `15.0` runtime execution, live `setDeviceID(_:)` multi-DAC hot-unplug, and the remaining 13 declared audio formats await appropriate runtime hardware/fixtures during Stage B / Stage D.
4. **Canonical Reference Verification:** Checked repository files referencing `AUDIO_WORKSPACE_IMPLEMENTATION_ROADMAP.md` (`PHASE61_FINAL_READINESS_REPORT.md` and `PHASE61_1_TECHNICAL_CORRECTION_REPORT.md`, both historical snapshot reports left untouched; `README.md` holds no roadmap links).
