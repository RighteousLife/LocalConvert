# LocalConvert — Phase 48: Comprehensive Source Audit & Historical Reconciliation

**Date:** 2026-11-21  
**Repository:** `/Users/cancan/Desktop/LocalConvert/` (`RighteousLife/LocalConvert`)  
**Target Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6.0 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**App Version:** `1.0.0` (`MARKETING_VERSION: "1.0.0"`, `CURRENT_PROJECT_VERSION: "1"`)  
**Audit Mode:** Strictly Read-Only Static Source, Integration, Test, Runtime & Historical Evidence Audit (No production edits, no build/test execution during Phase 48)

---

## 1. Executive Summary & Answers to the Eight Core Audit Questions

This audit reconciles LocalConvert's live Swift source code (`154` production Swift files across `App/`, `Core/`, `Engines/`, and `Features/`, plus C/C++ bridges for `libwebp` and `libjxl` v0.13.0, and `57` test files containing `77` `@Suite` declarations and `603` `@Test` functions) against historical Phase 13–47 engineering reports.

### Direct Answers to Core Phase 48 Questions

1. **What features does LocalConvert actually possess today?**
   - **9 top-level navigation modules (`AppNavigationTab`, `LocalConvert/App/AppState.swift:92–113`):**
     1. `Convert` (`DropZoneView`, `FileListView`, `FileRowView`, `FileOptionsView`, `ImageOptimizationSectionView`) — multi-engine format conversion across Image (`ImageConversionEngine`), Media (`MediaConversionEngine` / bundled FFmpeg 9.0.2), Office (`OfficeConversionEngine` / bundled LibreOffice 26.8.0.3), PDF (`PDFConversionEngine`), Subtitle (`SubtitleConversionEngine`), Archive (`ArchiveConversionEngine`), and Text (`TextConversionEngine`).
     2. `Jobs` (`JobsCenterView`, `JobsSummaryHeaderView`, `BatchJobGroupView`, `JobRowView`, `ErrorDetailsSheet`) — cost-weighted concurrent `ConversionQueue` (`ConversionQueue.swift:39–56`) with determinate/indeterminate progress and home-path-redacted diagnostics (`ErrorDetailsFormatter`, `ConversionManager.swift:124–278`).
     3. `PDF Toolbox` (`PDFToolboxView` + 19 sidebar operations across `Organize` and `PDF Pro Tools`, including `PDFPageStudioView`, `PDFAnnotationStudioView`, `PDFOCRView`, `PDFArchivalView`, `PDFRedactionView`, `PDFCompareView`, `PDFCompressOptionsView`, `PDFFormsView`, and `PDFInspectorSecurityView`).
     4. `Audio Toolbox` (`AudioToolboxView` + 7 sections: `Convert & Codec`, `Quick Trim & Segments`, `Audio Editor 2.0`, `Merge Audio`, `Adjust & Effects`, `Tags & Cover Art`, and `Spotify Compatibility`).
     5. `Image Toolbox` (`ImageToolboxView` + 14 sections: `Convert & Codec`, `Color & Light`, `Effects & Presets`, `RAW Develop`, `Crop & Geometry`, `Resize`, `Upscale`, `Optimize File Size`, `Compression`, `Metadata & Privacy`, `Watermark`, `Before / After`, `Color Management`, and `Remove Background`, plus embedded utilities `ImageSmartFormatAdvisorView`, `ImageContactSheetView`, `ImageBatchRenameView`, `ImageDuplicateFinderView`, and `ImageSVGOptimizerView`).
     6. `Metadata` (`MetadataView`, `MetadataFieldView`, `ArtworkEditorView`, `MetadataManager`, `SafeMetadataWriter`, and 5 format providers: Audio, Image, Video, PDF, Office).
     7. `Presets` (`PresetManagerView`, `PresetEditView`, `PresetManager`, `PresetStore`, `PresetValidator`, `PresetExecutor`).
     8. `History` (`HistoryView`, `HistoryManager`, plus the global `EditingHistoryView` popover for `UndoRedoCoordinator`).
     9. `Settings` (`SettingsView` decomposed into 11 modular section views backed by `AppSettings`, `AppLifecycleManager`, and `MenuBarManager`).

2. **Which features are complete, partial, UI-only, or unimplemented?**
   - **Complete (Implemented + Integrated + Tested):** Core multi-format conversion engines, Smart Presets (`Custom`, `Web Optimized`, `Maximum Quality`, `Small File`, `Apple Device`, `Maximum Compatibility`, `Audio Only`, `PDF`, `Editable`, `Print / Archive`), Audio Editor 2.0 core multitrack timeline/DSP/export/persistence, PDF Toolbox Pro (Page Studio, 10-subtype Annotations, 4-tier Compression, Vision OCR, PDF/A-1b/2b/3b/4 via LibreOffice, Permanent Pixel+Stream Redaction with residual verification, PDF Compare, AcroForm editing/JSON/flattening, Deep Inspector & Encryption), Image Toolbox Pro (Color/Curves/Levels/3-Way Balance, 9-effect ordered stack, Look Presets, `.lcimg` project persistence, Resize/Upscale/Crop/Perspective/Watermark/DPI/Canvas/Borders/Vision Background Removal, still-image JPEG XL & lossless JPEG↔JXL transcoding), Spotify Local Files Compatibility analyzer & normalizer, and Phase 47 lifecycle/visibility/theme synchronization.
   - **Partially Implemented (`PARTIALLY_IMPLEMENTED`):**
     - **Audio Editor Timeline Markers:** `AudioMarker` (`AudioEditorModels.swift:250`) and `project.markers` (`AudioEditorModels.swift:264`) are rendered on `TimeRulerView` (`TimeRulerView.swift:62`), but no UI controls or `AudioEditorStore`/`AudioEditingService` methods exist to add, rename, move, or delete markers.
     - **Per-File `targetFormat` in Image Toolbox:** `ImageToolboxStore` defines `targetFormatByURL: [URL: FileFormat]` (`ImageToolboxUndoCommands.swift:239, 271–279`), but `ImageToolboxView` binds its format picker to view-local `@State private var targetFormat: FileFormat = .jxl` (`ImageToolboxView.swift:12, 386, 489`), never calls `imageToolboxStore.targetFormat(for:fallback:)`, and records no `UndoableCommand` when `targetFormat` changes.
     - **Animated JPEG XL / GIF / APNG in Image Toolbox Pro:** Multi-frame animation preservation is implemented and integrated in the `Convert` tab (`ImageConversionEngine.convertAnimatedIfApplicable`, `ImageConversionEngine.swift:250–277`), but exporting from `ImageToolboxView` (`options.customOptions["image_toolbox"] == "true"`) routes to `ImageProcessingService.processToFile` (`ImageConversionEngine.swift:146–157`), which decodes only frame 0 (`decodeAllFrames: false`, `ImageProcessingService.swift:199, 249`).
     - **Multi-Output Job Undo (`OutputCreationUndoCommand` in `ConversionQueue`):** `ConversionQueue.handleJobCompletion` (`ConversionQueue.swift:202–203, 265–291`) passes only `[result.outputURL]` instead of `result.allOutputURLs` (`[outputURL] + additionalOutputURLs`), leaving secondary split/segment/sidecar/multi-size files on disk when undone.
     - **Disk-Level Undo & Non-Destructive Copy Option in Top-Level `Metadata` Tab:** `MetadataManager.save()` (`MetadataManager.swift:173–218`) overwrites `activeURL` in place via `SafeMetadataWriter` without staging a pre-write backup in `RecoveryArtifactManager` or recording a disk-level undo command (`UndoOperationType.metadataSaveToDisk` at `OperationContext.swift:164` is unused), unlike `ImageToolboxView.saveMetadataInPlaceOrCopy` (`ImageToolboxView.swift:848–873`).
     - **Camera RAW Hardware Verification:** `CIRAWFilter` integration and ImageIO fallback are implemented (`ImageAdjustmentsEngine.swift`, `ImageProcessingService.swift:113–164`), but `0` real camera RAW files exist in the repository (`ImageRAWDevelopTests.swift` tests a 16-bit TIFF with a `.dng` extension that exercises the fallback path).
   - **UI-Only (`UI_ONLY`):**
     - `Settings → Conversion Defaults → "Remember last used options for formats"` (`AppSettings.swift:570–571`, `SettingsView.swift:286`): Persisted in `UserDefaults`, never read anywhere in conversion or option initialization logic.
     - `Settings → Privacy & Diagnostics → "Enable Verbose Diagnostic Logging"` (`AppSettings.swift:615–616`, `SettingsView.swift:531`): Persisted in `UserDefaults`, never read by any logger or subsystem; `DiagnosticLogManager` (`AppSettings.swift:281–305`) creates/clears `~/Library/Logs/LocalConvert/`, but no subsystem ever writes log files to that directory.
   - **Not Implemented (`NOT_IMPLEMENTED`):**
     - **Video Trim:** Zero video trim UI, models, preview player, or FFmpeg `-ss`/`-to` video trim pipeline exist (only audio trim exists in `AudioToolboxView` and `AudioEditorRootView`).
     - **Watch Folder / Automatic Conversion:** Zero directory watcher (`FSEventStream` / `DispatchSourceFileSystemObject`), file-completion stability detector, watch-folder persistence, or UI exist; only the downstream headless preset runner `PresetExecutor.execute(...)` (`PresetExecutor.swift:31–114`) exists.

3. **Which functions exist in source code but are disconnected from the real runtime workflow?**
   - `ImageToolboxStore.targetFormat(for:fallback:)` (`ImageToolboxUndoCommands.swift:271–274`) is never called; `setTargetFormat(_:for:)` (`ImageToolboxUndoCommands.swift:276–279`) is only written during `.lcimg` project load (`ImageToolboxView.swift:1015`) and never read back.
   - `UndoOperationType.conversionOptionsChange`, `.outputFormatChange`, `.jobRemoval`, `.audioToolboxConfig`, `.audioToolboxSegmentEdit`, `.metadataSaveToDisk`, `.presetReset`, `.fileMove`, `.fileTrash`, and `.externalExport` (`OperationContext.swift:119–177`) are declared in the enum but never instantiated by any `UndoableCommand`.
   - `OperationContext.jobs`, `.history`, and `.fileOperations` (`OperationContext.swift:8, 15, 16`) have no commands recorded into their stacks at runtime (for example, `BatchRenameUndoCommand` defaults its `init` parameter to `.fileOperations` at `AppUndoCommands.swift:236`, but its only production caller at `ImageConvertUtilitiesViews.swift:386` passes `context: .imageToolbox`).
   - `AppSettings.rememberLastUsedOptions` (`AppSettings.swift:571`) and `AppSettings.verboseLogging` (`AppSettings.swift:616`) are bound to toggles in `SettingsView.swift:286, 531` with zero readers.

4. **Which features have automated tests vs. runtime verification vs. manual verification?**
   - All `57` test files (`77` suites, `603` `@Test` functions) are cataloged in Section 3 and in `docs/PHASE48_FEATURE_STATUS_MATRIX.md`.
   - The most recent full test suite run recorded in repository documentation was in Phase 47.1.4 (`602/602` tests across `77` suites). Following Phase 47.1.4, the theme-transition fix (`SystemAppearanceMonitor`, `AppearanceMode.resolvedColorScheme(system:)`, `OpaqueWindowChromeHost.isApplyingChrome`) added a 13th test to `Phase47LifecycleAndUXTests.swift` (`appearanceModeResolvesSystemToExplicitColorScheme`, line 650), bringing the static total to **`603` `@Test` functions across `77` suites**; that post-47.1.4 fix was verified with a focused `21/21` test run and manual user acceptance, while a full `603/603` run has not been executed since.
   - Runtime Accessibility (`System Events`) + `xctrace` verification was performed for Settings, Application Visibility popover, and theme switching (`PHASE47_FINAL_REPORT.md` §24.7), and partial GUI automation was performed for Image Toolbox (`PHASE46_FINAL_REPORT.md` §13.1), while interactive canvas pointer drags (Tone Curves, PDF Page Studio drag-reorder, PDF Annotation 8-handle resize, Audio Editor timeline fade handles), physical audio output monitoring, and live VoiceOver audio remain `UNABLE_TO_DETERMINE` / manual-verification items.

5. **What discrepancies exist between historical phase reports and the current source code?**
   - Detailed in Section 4 below (including Phase 19/21/22 roadmap numbering shifts, `PHASE47_FINAL_REPORT.md` Section 7 vs. Section 20 on `shouldTerminateAfterLastWindowClosed`, `PHASE47_FINAL_REPORT.md` §24.8 cleanup claims vs. untracked `Launch_LocalConvert_2026-11-21_04.29.07_6FBCD59E.trace/` and `debug-deployment/` in the workspace root, and `602` historical tests vs. `603` current `@Test` declarations).

6. **Which technical debts and architectural risks have the highest priority?**
   - Ranked `P0`–`P3` with file/line evidence in Section 5 below. (Zero `P0` data-corruption bugs were found; five `P1` high-priority functional/consistency defects and seven `P2` medium-priority architectural/reliability gaps are documented.)

7. **How should Video Trim be integrated into the existing infrastructure?**
   - Detailed in Section 2.G below: reuse `BundledFFmpegProvider`, `MediaProbe`, `AsyncProcessRunner`, `ConversionManager.reserveOutputURL`/`finalizeOutputFile`, `ConversionQueue`, `OutputCreationUndoCommand`, and `AVPlayer`/`AVAssetImageGenerator` to deliver both **Stream Copy Trim** (keyframe-snapped, zero re-encode) and **Frame-Accurate Re-encode Trim** (`h264_videotoolbox` / `libvpx-vp9` + stream/codec options).

8. **What development phases should follow, and in what order?**
   - Defined in `docs/PHASE48_FINAL_DEVELOPMENT_ROADMAP.md` across **Phases 49–53**.

---

## 2. Module-by-Module Technical Audit (Five-Layer Evidence Analysis)

---

### A. Audio Editor 2.0 & Audio Toolbox Pro

#### 1. Architecture & Source Inventory
- **Models & State (`LocalConvert/Engines/AudioEditor/`):**
  - `AudioEditorModels.swift`: `AudioMediaReference` (lines 5–34, non-destructive fingerprint & `SourceStatus`), `ClipFadeCurve` (lines 38–69: `.linear`, `.equalPower`, `.exponential`, `.logarithmic`, `.sCurve`), `ClipFadeSpec` (lines 71–74), `AudioEditorChannelMode` (lines 76–81), `AudioEffectChainConfig` (lines 84–103, legacy FFmpeg proxy parameters including `pitchSemitones` and `timeStretch`), `AudioClip` (lines 107–197), `AudioTrack` (lines 199–248), `AudioMarker` (lines 250–254), `AudioEditorProject` (lines 256–358, `currentSchemaVersion = 2`), `TimelineState` (lines 360–400, strictly decoupled from project undo/dirty state).
  - `AudioDSPModels.swift`: `ParametricEQParams`, `CompressorParams`, `LimiterParams`, `NoiseGateParams`, `NoiseReductionParams`, `DelayParams`, `ReverbParams`, `AudioEffectKind`, `AudioEffectSlot`, `AudioEditorNormalizeMethod`, `AudioEffectChainPreset`, `TimelineSnapInterval`, `TimelineGridConfig`, `AudioTrackGroup`.
  - `AudioDSPEngine.swift`: Real-time and offline sample processors (`ParametricEQDSP`, `CompressorDSP`, `LimiterDSP`, `NoiseGateDSP`, `SpectralNoiseReductionDSP` using Accelerate `vDSP_DFT_zop`, `DelayDSP`, `ReverbDSP`, `AudioChainProcessor`, `AudioNormalizer`).
  - `AudioEditingService.swift`: Pure value-mutation functions for track add/remove/reorder, clip import/split/splitAtSelection/trim/trimToSelection/delete/rippleDelete/deleteRange/move/nudge/copy/paste/duplicate/insertSilence/consolidate/replaceClip, crossfade placement (`applyCrossfade`, `applyCrossfadeNearClip`), and track grouping (`createTrackGroup`, `assignTrack`, `toggleGroupMute`, `toggleGroupSolo`, `moveGroupClips`).
  - `AudioMixingService.swift`: `AudioGainAutomation` (lines 7–48), `AudioEffectFilterBuilder` (lines 78–123), `ClipProxyCache` actor (lines 127–201, 1.5 GB LRU cache in `~/Library/Caches/<bundleID>/AudioEditorProxies`), `AudioSourceResolver` (lines 212–231), and `AudioMixSession` (lines 235–472) with pre-allocated scratch buffers (`trackScratchL/R`, `clipScratchL/R`) executing `Per-Clip effectSlots -> Clip Fade/Crossfade Gain -> Per-Track effectSlots -> Track Volume/Pan -> Master Bus masterEffects`.
  - `PlaybackEngine.swift`: `AudioRingBuffer` (`OSAllocatedUnfairLock`, capacity `48,000` frames, lines 7–80) + `AudioPlaybackEngine` (`@MainActor`, lines 108–340) driving `AVAudioEngine` and `AVAudioSourceNode` with 60 Hz playhead & L/R peak + gain-reduction (`gainReductionDB`) metering, throttled audible scrubbing (`0.12s` burst at `0.05s` throttle, lines 193–212), loop range playback (`LoopConfigBox`), and live `projectDidChange` session updates.
  - `WaveformRenderingService.swift`: Stereo L/R mipmap `WaveformRenderingService` (64 MB LRU cache, clipping count, RMS/peak range stats) and `SpectrumAnalyzerService` (`vDSP` Hann-windowed FFT).
  - `AudioExportService.swift`: Offline 32-bit float `.caf` mixdown via `AudioMixSession` followed by bundled FFmpeg encoding (`WAV` 16/24-bit with `triangular_hp` dithering, `AIFF`, `FLAC`, `MP3`, `M4A`, `OGG`, `OPUS`) across 5 scopes (`Entire Mix`, `Selected Range`, `Selected Track`, `Selected Clips`, `All Stems`), two-pass EBU R128 `loudnorm` (`-14`, `-16`, `-23` LUFS, `-3.0...-0.5` dBTP), post-encode `MediaProbe` + `AVAudioFile` + EBU R128 verification, batch export (`exportBatch`), and partial-stem cancellation cleanup.
  - `ProjectPersistenceService.swift`: Version 2 `.lcproject` JSON and self-contained `.lcprojpkg` bundle (`Media/` copy), v1→v2 migration, debounced 2-second autosave (`scheduleAutosave`, `AudioEditorStore.swift:657–666`), crash recovery (`latestRecoverableAutosave`), and missing-source detection/relinking (`relinkAsset`).
  - `AudioEditorStore.swift` & `AudioEditorUndoCommands.swift`: Hosted as a long-lived store on `AppState.audioEditorStore` (`AppState.swift:184, 224`), surviving top-level tab switches, with `AudioProjectMutationCommand` (`survivesRestart = true`), `AudioEditorUndoRehydrator`, continuous drag coalescing (`beginContinuousMutation` / `updateContinuousMutation` / `endContinuousMutation`), and `recordExportOutputsUndo` (`OutputCreationUndoCommand`).
- **UI Views (`LocalConvert/Features/AudioEditor/`):**
  - `AudioEditorRootView.swift` (embedded inside `AudioToolboxView.swift:124` when `selectedSection == .audioEditor`), `TransportBarView.swift`, `TimeRulerView.swift`, `MultitrackTimelineView.swift`, `TrackHeaderView.swift`, `StereoWaveformClipView.swift`, `AudioEditorInspectorView.swift`, `AudioEffectChainEditorView.swift`, `AudioEditorExportSheet.swift`.

#### 2. Disconnected / Partially Implemented Elements Found in Audio Editor & Audio Toolbox
1. **Timeline Markers (`PARTIALLY_IMPLEMENTED`):**
   - `AudioMarker` is defined in `LocalConvert/Engines/AudioEditor/AudioEditorModels.swift:250–254`, stored in `AudioEditorProject.markers: [AudioMarker]` (`AudioEditorModels.swift:264`), and rendered as yellow triangles/labels on the timeline ruler in `LocalConvert/Features/AudioEditor/TimeRulerView.swift:62–75`.
   - **Gap:** Neither `AudioEditingService`, `AudioEditorStore`, `AudioEditorRootView`, nor `TimeRulerView` contains any method or UI control to add, rename, move, or delete markers. `project.markers` is always empty unless hand-edited in a `.lcproject` JSON file.
2. **Dual Clip Effects Model (`AudioClip.effects` vs. `AudioClip.effectSlots`):**
   - `AudioClip` carries both `effects: AudioEffectChainConfig` (Phase 43 FFmpeg proxy-based EQ/compressor/limiter/gate/denoise/pitch/time-stretch, `AudioEditorModels.swift:84–103, 126`) and `effectSlots: [AudioEffectSlot]` (Phase 45 real-time/offline native DSP chain, `AudioEditorModels.swift:128`).
   - In `AudioEditorInspectorView.swift:227–250`, the primary UI edits `effectSlots` via `AudioEffectChainEditorView`, while `DisclosureGroup("Clip Timing & Legacy Proxy FX")` exposes only `pitchSemitones`, `timeStretch`, and `"Reset Legacy Clip FX"`. This works cleanly, as `pitchSemitones` and `timeStretch` are the only parameters in `AudioEffectChainConfig` not superseded by `effectSlots`.
3. **Non-AudioEditor Sections of `AudioToolboxView` Lack Draft Undo & Tab-Switch State Persistence (`PARTIALLY_IMPLEMENTED`):**
   - In `LocalConvert/Features/AudioToolbox/AudioToolboxView.swift:49–68`, the settings for `Convert & Codec`, `Quick Trim & Segments`, `Merge Audio`, and `Adjust & Effects` (`@State private var targetFormat: FileFormat = .mp3`, `@State private var config: AudioToolboxConfig = AudioToolboxConfig()`, `@State private var trimStart: Double = 0`, `@State private var trimEnd: Double = 0`, `@State private var orderedMergeIDs: [UUID] = []`) live in view-local `@State`.
   - Unlike `AudioEditorStore`, `ImageToolboxStore`, and `PDFToolboxStore`, there is no `AudioToolboxStore` on `AppState`, and `UndoOperationType.audioToolboxConfig` / `.audioToolboxSegmentEdit` (`OperationContext.swift:145–146`) are never instantiated. Switching away from the `Audio Toolbox` tab and back resets `AudioToolboxView`'s `@State` configuration.
4. **Spotify Compatibility Normalization Undo Integration (`PARTIALLY_IMPLEMENTED`):**
   - `SpotifyCompatibilityView.runNormalizeEligible()` (`LocalConvert/Features/AudioToolbox/SpotifyCompatibilityView.swift:895–954`) creates normalized safe copies on disk (`SpotifyCompatibilityService.normalizeFile`) without recording `OutputCreationUndoCommand` into `UndoRedoCoordinator.shared`.

---

### B. Smart Preset (`Custom`, `Web Optimized`, `Maximum Quality`, `Small File`)

#### 1. End-to-End Chain Verification (`UI → State/Model → Per-File Configuration → Conversion Job → Engine → Output`)
- **Enum & Options (`LocalConvert/Core/Conversion/ConversionEngine.swift:35–58, 131–515`):**
  - `ConversionPreset` defines 10 cases: `.custom`, `.web` (`"Web Optimized"`), `.maximumQuality` (`"Maximum Quality"`), `.smallFile` (`"Small File"`), `.appleDevice`, `.videoMaximumCompatibility`, `.audioOnly`, `.documentPDF`, `.documentEditable`, and `.documentPrintArchive`.
  - `ConversionOptions.effectivePreset` (`ConversionEngine.swift:132–135`) normalizes `.custom` and `nil` to `nil`.
  - `ConversionOptions.applyPreset(_:inputFormat:outputFormat:)` (`ConversionEngine.swift:186–334`) first calls `resetPresetOwnedFields()` (lines 164–177) to clear stale preset-owned fields and hidden keys (`vcodec`, `acodec`, `pix_fmt`, `profile:v`, `audio_only`, `pdf_archive`, `preset_name`, `m4a_lossless`, `audio_codec`, `audio_sample_rate`, `audio_channels`) while preserving user geometry settings (`resizeMode`, `cropMode`), and then applies category-specific parameters:
    - **`Custom` (`.custom` / `nil`):** Clears `preset` and `customOptions["preset_name"]` without overwriting user parameters.
    - **`Web Optimized` (`.web`):** Sets `preserveMetadata = false`; for `.image` sets `imageQuality = 0.75`, `webpLossless = false`, `imageOptimizationMode = .balanced`; for `.audio`/`.video` sets `mediaQuality = .medium`; for `.document` sets `imageQuality = 0.75`.
    - **`Maximum Quality` (`.maximumQuality`):** Sets `preserveMetadata = true`; for `.image` sets `imageQuality = 1.0`, `webpLossless = (outputFormat == .webp)`, `imageOptimizationMode = .quality`; for `.audio`/`.video` sets `mediaQuality = .maximum`; for `.document` sets `pdfDPI = 300.0`, `imageQuality = 1.0`.
    - **`Small File` (`.smallFile`):** Sets `preserveMetadata = false`; for `.audio` sets `mediaQuality = .low` (no artificial MB cap); for `.video` sets `mediaQuality = .low`, `targetFileSizeBytes = 1_000_000` (`1.0 MB`); for `.image` sets `imageQuality = 0.50`, `webpLossless = false`, `imageOptimizationMode = .targetFileSize`, `targetFileSizeBytes = 1_000_000` (`1.0 MB`); for `.document` sets `pdfDPI = 72.0`, `imageQuality = 0.50`.
- **Manual Edit -> `Custom` Transition (`ConversionEngine.swift:353–515`, `FileOptionsView.swift:114–124`):**
  - `FileOptionsView.updateOption` and `ImageOptimizationSectionView.updateOption` invoke `updated.reconcilePresetAfterManualEdit(availablePresets:descriptors:inputFormat:outputFormat:)`.
  - If a manual edit diverges from the active preset, `preset` transitions to `nil` (`Custom`). If manual edits unambiguously match a single available preset, that preset is restored.
- **Per-File Preservation in Batch Conversion (`AppState.swift:909–975`):**
  - Each `DroppedFile` in `AppState.droppedFiles` owns its own independent `options: ConversionOptions` and `selectedOutputFormat: FileFormat?`. `AppState.convertAll()` constructs a `ConversionJob` per file preserving that file's `file.options` and `file.selectedOutputFormat`.
- **Encoder Parameter Translation:**
  - `ImageConversionEngine` / `ImageProcessor`: Maps `effectiveImageQuality`, `webpLossless`, `preserveMetadata`, and `effectiveTargetFileSizeBytes` (6-iteration binary search in `ImageProcessor.optimizeForTargetSize`) into ImageIO, `WebPEncoder`, or `JPEGXLCodec`.
  - `BaseFFmpegProvider` (`BaseFFmpegProvider.swift:228–232, 369–615`): Maps `preserveMetadata` to `-map_metadata 0` / `-map_metadata -1`, `effectiveMediaQuality` (`.low`/`.medium`/`.high`/`.maximum`) to `-q:a` (MP3 VBR `5`/`3`/`2`/`0`), `-b:a` (`128k`–`320k` AAC/M4A, `96k`–`256k` Opus/OGG/M4B), VideoToolbox `-q:v` (`45`/`60`/`75`/`90`), VP9 `-crf` (`36`/`31`/`25`/`18`), and `effectiveTargetFileSizeBytes` to calculated `-b:v`/`-maxrate`/`-bufsize` (lines 471–478).
  - `PDFConversionEngine` / `OfficeConversionEngine`: Maps `effectivePDFDPI` (`72`/`150`/`300`) and `effectivePDFOfficeMode`.
- **Unsupported Format Handling (`ConversionEngine.swift:338–350`, `AppState.swift:669–728`):**
  - `ConversionOptions.unsupportedPresetNotice(for:)` displays an info notice in `FileOptionsView.swift:146–157` when `.smallFile` or `.web` is selected on lossless audio (`.wav`, `.flac`, `.alac`, `.aiff`, `.caf`, `.au`, `.wv`, `.mka`) or lossless image formats (`.png`, `.bmp`, `.tiff`).
  - `AppState.updateOutputFormat(for:format:)` strips incompatible custom keys when switching formats and re-applies or clears the active preset if unsupported on the new route.

#### 2. Subtle Inconsistencies Found in Smart Preset UI
1. **`ConversionPreset` vs. `ImageOptimizationMode` Parameter Divergence (`PARTIALLY_IMPLEMENTED` / UX Nuance):**
   - In `ImageOptimizationSectionView.applyModeChange` (`LocalConvert/Features/Conversion/ImageOptimizationView.swift:399–444`):
     - Picking `Optimization Mode → Maximum Quality` (`ImageOptimizationMode.maximum`) sets `imageQuality = 0.95` and `imageOptimizationMode = .maximum`. Because `ConversionPreset.maximumQuality` expects `imageQuality = 1.0` and `imageOptimizationMode = .quality` (`ConversionEngine.swift:233–235`), `reconcilePresetAfterManualEdit` transitions the top `Smart Preset` picker to `Custom` when the user selects `Optimization Mode → Maximum Quality`!
     - Similarly, picking `Optimization Mode → Small File` (`ImageOptimizationMode.smallFile`) sets `imageQuality = 0.55` and `targetFileSizeBytes = 500_000` (500 KB), whereas `ConversionPreset.smallFile` expects `imageQuality = 0.50`, `imageOptimizationMode = .targetFileSize`, and `targetFileSizeBytes = 1_000_000` (1 MB) (`ConversionEngine.swift:260–264`), so picking `Optimization Mode → Small File` also flips `Smart Preset` to `Custom`.
2. **Per-File Preset/Format/Options Changes in `Convert` Tab Are Not Recorded in `UndoRedoCoordinator`:**
   - Although `UndoOperationType.conversionOptionsChange` and `.outputFormatChange` exist in `LocalConvert/Core/UndoRedo/OperationContext.swift:119–120`, `AppState.updateOutputFormat`, `AppState.updateOptions`, `AppState.applyPreset`, and `AppState.optionsBinding` (`LocalConvert/App/AppState.swift:669–797`) mutate `droppedFiles[index]` directly without recording an `UndoableCommand`.

---

### C. Global Undo/Redo & Editing History

#### 1. Core Infrastructure (`LocalConvert/Core/UndoRedo/`)
- `UndoRedoCoordinator.swift`: `@MainActor` singleton managing per-`OperationContext` `UndoRedoManager` stacks, active context resolution bound to `AppState.$selectedTab` + Audio Editor focus (`OperationContext.resolve`), debounced JSON persistence (`~/Library/Application Support/com.localconvert.app/UndoHistory/journal.json`), corrupt-journal backup (`journal.corrupted.<ts>.json`), and `RecoveryArtifactManager` synchronization.
- `RecoveryArtifactManager.swift`: Actor managing staged recovery blobs under `~/Library/Application Support/com.localconvert.app/UndoHistory/Artifacts/`, enforcing configurable disk budget (`AppSettings.shared.recoveryArtifactStorageLimitBytes`, default 512 MB), orphan cleanup (`reconcileOrphanedBlobs`), and protected-source overwrite guards.
- `UndoMenuController.swift`: KVO + NotificationCenter observer over `NSApp.keyWindow?.firstResponder` (`activeEditableTextResponder`). When an editable `NSText`/`NSTextView` (`TextField`, `SecureField`, `TextEditor`) has focus, `Cmd+Z` and `Shift+Cmd+Z` route exclusively to the text control's `NSUndoManager` and never trigger `UndoRedoCoordinator`.
- `LocalConvertApp.swift:123–143` & `ContentView.swift:27–60`: Native macOS `Edit` menu (`CommandGroup(replacing: .undoRedo)`) and main window toolbar buttons bind directly to `UndoMenuController.shared` (`⌘Z`, `⇧⌘Z`) and `UndoRedoCoordinator.shared.isEditingHistoryPresented` (`⌥⌘Z` -> `EditingHistoryView` popover).

#### 2. Verification of Historical Limitation: Per-File `targetFormat` in Image Toolbox
- **Finding:** **CONFIRMED STILL NOT INTEGRATED (`PARTIALLY_IMPLEMENTED`).**
- **Evidence:**
  1. `ImageToolboxStore` (`LocalConvert/Core/UndoRedo/ImageToolboxUndoCommands.swift:239, 271–279`) defines `@Published var targetFormatByURL: [URL: FileFormat] = [:]`, `func targetFormat(for url: URL?, fallback: FileFormat) -> FileFormat`, and `func setTargetFormat(_ format: FileFormat, for url: URL?)`.
  2. `setTargetFormat(_:for:)` mutates `targetFormatByURL[k] = format` directly without creating or recording any `UndoableCommand`.
  3. `ImageConfigUndoCommand.Payload` (`ImageToolboxUndoCommands.swift:8–12`) serializes only `ImageToolboxConfig`, which does not include `targetFormat`.
  4. `ImageToolboxView` (`LocalConvert/Features/ImageToolbox/ImageToolboxView.swift:12, 386, 489`) still stores `@State private var targetFormat: FileFormat = .jxl` in view-local `@State`, binds both format pickers to `$targetFormat`, never calls `imageToolboxStore.targetFormat(for:fallback:)`, and only calls `setTargetFormat` at line 1015 when loading an `.lcimg` file.

#### 3. Verification of All Undo/Redo Operations & Gaps Discovered
| Module / Operation | Command Type | `survivesRestart` | Status | Evidence & Notes |
|---|---|---|---|---|
| **Convert Queue: Add / Remove / Clear / Reorder Files** | `DroppedFilesUndoCommand` | `false` | `IMPLEMENTED`, `INTEGRATED`, `TESTED` | `AppUndoCommands.swift:103–137`, `AppState.swift:505, 560, 635, 655`. |
| **Convert Queue: Per-file Output Format & Options Edit** | None (`.outputFormatChange` / `.conversionOptionsChange` unused) | N/A | `NOT_IMPLEMENTED` | `OperationContext.swift:119–120` enum cases exist, but `AppState.updateOutputFormat` / `updateOptions` (`AppState.swift:669–797`) record no undo command. |
| **Job Completion Output Creation** | `OutputCreationUndoCommand` | `false` | `PARTIALLY_IMPLEMENTED` | `ConversionQueue.swift:203, 265–291` records only `[result.outputURL]` instead of `result.allOutputURLs`, missing `additionalOutputURLs` on multi-output jobs. |
| **Audio Editor 2.0 Project Mutations & Export** | `AudioProjectMutationCommand`, `OutputCreationUndoCommand` | `true` (project) / `false` (export) | `IMPLEMENTED`, `INTEGRATED`, `TESTED` | `AudioEditorUndoCommands.swift`, `AudioEditorStore.swift:183–260`. Coalesces continuous slider/clip/fade drags and survives restart. |
| **Audio Toolbox (Non-Editor Sections & Spotify)** | None (`.audioToolboxConfig` / `.audioToolboxSegmentEdit` unused) | N/A | `NOT_IMPLEMENTED` | `AudioToolboxView.swift:49–68` uses view-local `@State`; `SpotifyCompatibilityView.swift:895–954` does not record `OutputCreationUndoCommand`. |
| **Image Toolbox Config & Look Presets** | `ImageConfigUndoCommand` | `true` | `IMPLEMENTED`, `INTEGRATED`, `TESTED` | `ImageToolboxUndoCommands.swift:7–129, 292–550`. Per-URL isolation, continuous coalescing, compact journal rehydration. |
| **Image Toolbox In-Place/Copy Metadata Save** | `ImageFileWriteUndoCommand` | `false` | `IMPLEMENTED`, `INTEGRATED`, `TESTED` | `ImageToolboxUndoCommands.swift:134–232`, `ImageToolboxView.swift:848–873`. Stages backup in `RecoveryArtifactManager`. |
| **Image Toolbox Safe Batch Rename** | `BatchRenameUndoCommand` | `false` | `PARTIALLY_IMPLEMENTED` | `ImageConvertUtilitiesViews.swift:378–408`: records `BatchRenameUndoCommand`, but (a) does not update `AppState.droppedFiles` URLs after rename, and (b) inline `"Undo Last Rename"` button (line 401) bypasses `UndoRedoCoordinator`, leaving a stale stack entry. |
| **PDF Toolbox Page Studio & Compression/OCR Config** | `PDFPageDraftUndoCommand`, `PDFOperationConfigUndoCommand` | `true` | `IMPLEMENTED`, `INTEGRATED`, `TESTED` | `PDFToolboxUndoCommands.swift:238–460`. Scrubs passwords before persisting (`cfg.password = nil`). |
| **PDF Toolbox Annotations, Forms & Redaction Drafts** | `PDFAnnotationDraftUndoCommand`, `PDFFormDraftUndoCommand`, `PDFRedactionDraftUndoCommand` | `false` (privacy by design) | `IMPLEMENTED`, `INTEGRATED`, `TESTED` | `PDFToolboxUndoCommands.swift:36–233`. Kept session-only in RAM so PII search terms/notes never hit `journal.json`. |
| **Metadata Tab Field Edits vs. Disk Save** | `MetadataSnapshotUndoCommand` (draft only) | `false` | `PARTIALLY_IMPLEMENTED` | `MetadataManager.swift:74–218`: field edits in RAM are undoable, but `save()` overwrites disk in-place without staging a `RecoveryArtifactManager` backup or recording `.metadataSaveToDisk`. |
| **Presets Save / Delete / Rename / Duplicate vs. Reset** | `PresetStoreUndoCommand` | `false` | `PARTIALLY_IMPLEMENTED` | `PresetManager.swift:33–105` records undo for save/delete/rename/duplicate, but `resetToDefaults()` (`PresetManager.swift:107–111`) does not record `.presetReset`. |

---

### D. Image Toolbox Pro

- **Evaluated Sub-Features (`LocalConvert/Engines/Image/` & `LocalConvert/Features/ImageToolbox/`):**
  - **Resize (`ImageResizeService.swift`, `ImageProcessor.swift`, `ImageToolboxOperationsViews.swift`):** Supports `.none`, `.exactDimensions`, `.percentage`, `.maxWidth`, `.maxHeight`, `.fitInside`, `.fill` (crop-to-fit), 4 resampling algorithms (`.lanczos`, `.bicubic`, `.bilinear`, `.nearestNeighbor`), post-resize sharpening (`0.0...1.0`), and multi-size batch export (`exportMultipleSizes`, `multiSizePresets`). All `IMPLEMENTED`, `INTEGRATED`, and `TESTED` (`Phase36ImageToolboxTests.swift`, `Phase37ImageToolboxCompletionTests.swift`).
  - **Upscale (`ImageUpscaleService.swift`, `ImageUpscaleSectionView.swift`):** `2×`, `3×`, `4×`, custom scale (`1.1...4.0×`), and target dimensions with `Lanczos + Detail Recovery`, `Lanczos 3`, and `Bicubic`, memory-clamped at `16,384 px` edge / `100 MP`. `IMPLEMENTED`, `INTEGRATED`, `TESTED`.
  - **Crop, Rotation, Flip, Straighten & Perspective (`ImageCropService.swift`, `ImagePerspectiveService.swift`, `ImageCropEditorView.swift`, `ImagePerspectiveEditorView.swift`):** 13 aspect ratio presets, custom normalized crop, pixel crop, 9-point crop anchor, 8 geometric crop shapes (`rectangle`, `roundedRectangle`, `circle`, `ellipse`, `triangle`, `diamond`, `hexagon`, `customPolygon`), `0/90/180/270°` rotation, horizontal/vertical flip, continuous `-45°...+45°` straighten with exact inscribed auto-crop (`inscribedDimensions`), `VNDetectHorizonRequest` auto-horizon, and 4-corner projective perspective homography (`CIPerspectiveCorrection` + `VNDetectRectanglesRequest` auto-quad). All preserve 16-bit precision (`ImageAdjustmentsFoundationTests.swift`, `ImageGeometryProTests.swift`).
  - **Color & Light, Curves, Levels & Color Balance (`ImageAdjustmentsEngine.swift`, `ImageColorAdjustmentsView.swift`):** Exposure, brightness, contrast, gamma, highlights, shadows, whites, blacks, temperature/tint, saturation, vibrance, hue, Fritsch-Carlson monotone cubic spline Tone Curves (Master/R/G/B), per-channel Levels, 3-way Shadows/Midtones/Highlights Color Balance (`32³` `CIColorCubeWithColorSpace`), and real RGB/Luminance histogram (`ImageColorAnalysisService.swift`). `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`ImageColorAdjustmentsTests.swift`).
  - **Ordered Effects Stack & Look Presets (`ImageAdjustmentsEngine.swift`, `ImagePresetCatalog.swift`, `ImageEffectsChainView.swift`):** 9 reorderable effect processors, 6 built-in Look Presets (`image_look_only = "true"`), user preset CRUD/rename/batch apply, and `.lcimg` project save/open/relink with path-traversal and source-overwrite guards. `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`ImageEffectsAndPresetsTests.swift`, `Phase46IntegrationAndPerfTests.swift`).
  - **Camera RAW (`ImageAdjustmentsEngine.loadWithCIRAWFilter`, `ImageProcessingService.decodeInputImageWithRAW`, `ImageEffectsChainView.swift`):** `IMPLEMENTED` and `INTEGRATED`, with fallback tested (`ImageRAWDevelopTests.swift`), but real camera sensor RAW files remain `UNABLE_TO_DETERMINE` (no real camera RAW fixtures in repository).
  - **Color Management (`ImageColorManagementService.swift`), Watermark (`ImageWatermarkService.swift`), DPI & Canvas/Borders (`ImageCanvasBorderService.swift`, `ImageCanvasBorderDPISectionView.swift`), Vision Background Removal (`ImageBackgroundRemovalService.swift`), Metadata Inspector/Privacy (`ImageMetadataInspectorService.swift`, `ImageMetadataService.swift`, `ImageMetadataPrivacyView.swift`), Target-Size Search & Size Estimation (`ImageProcessor.optimizeForTargetSize`, `ImageProcessingService.swift`):** All `IMPLEMENTED`, `INTEGRATED`, and `TESTED` (`Phase36ImageToolboxTests.swift`, `Phase37ImageToolboxCompletionTests.swift`, `Phase40Tests.swift`).
  - **JPEG XL (`JPEGXLCodec.swift`, `JXLBridge.cc` over `libjxl` v0.13.0):**
    - Still-image JXL (lossy Butteraugli distance/quality, lossless, 8-bit/16-bit, straight/premultiplied alpha, ICC profiles, EXIF/XMP container boxes, and lossless JPEG ↔ JXL bitstream transcode/reconstruction) is **end-to-end integrated** in both the `Convert` tab and `Image Toolbox Pro`.
    - **Animated JXL frames** are integrated in `ImageConversionEngine.convertAnimatedIfApplicable` (`ImageConversionEngine.swift:250–277` for `Convert` tab jobs), but **not** wired in `ImageProcessingService.processToFile` (`ImageProcessingService.swift:199, 960`) when exporting from `Image Toolbox Pro`.

---

### E. PDF Toolbox Pro

- **Evaluated Sub-Features (`LocalConvert/Engines/PDF/` & `LocalConvert/Features/PDFToolbox/`):**
  - **Organize & Visual Page Studio (`PDFPageManagementService.swift`, `PDFCoordinateGeometry.swift`, `PDFGridPageSplitter.swift`, `PDFPageStudioView.swift`):** Merge, 2×2 grid slide splitter (`separatePages`), split (`everyPage`, `everyNPages`, `pageRanges`, `topLevelBookmarks`), extract, delete, reorder, duplicate, insert from another PDF, rotate (`90°/180°/270°`), non-destructive `CropBox` crop, vector page-size normalization (`A4`, `Letter`, `Legal`, `A3`, `Custom` with `Fit`/`Fill`), outline remapping (`PDFOutlineRemapper`), and 96 MB `PDFThumbnailCache`. `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`Phase24Tests.swift`, `Phase25Tests.swift`, `PDFPageManagementTests.swift`).
  - **10-Subtype Annotations (`PDFAnnotationService.swift`, `PDFAnnotationStudioView.swift`):** `Highlight`, `Underline`, `StrikeOut`, `Sticky Note`, `Text Box`, `Freehand Ink`, `Rectangle`, `Circle`, `Line`, `Arrow` with hit-testing, 8-handle resize, AcroForm `.widget`/`.link`/outline preservation, optional burn-in flattening (`burnInAnnotationsOption`), and explicit non-redaction warning banner. `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`PDFAnnotationTests.swift`).
  - **4-Tier Compression (`PDFCompressionService.swift`, `PDFCompressOptionsView.swift`):** `Lossless Structure Cleanup`, `Quartz Filter (Keep Vector Text)` (`QuartzFilter`), `PDFKit Screen Downsample`, and `Rasterize Pages` (JPEG/JPEG 2000/Lossless Flate + Grayscale toggle) with post-write XMP/Info stripping verification (`metadataStrippedVerified`) and honest disclosure that macOS PDFKit/Quartz does not emit `/Linearized` hint tables or glyph-level font subsetting. `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`Phase34Tests.swift`, `PDFOptimizationAndOCRTests.swift`).
  - **Vision OCR & Searchable PDF (`PDFOCRService.swift`, `PDFOCRView.swift`):** Apple Vision (`VNRecognizeTextRequest` Revision 3), word-level invisible CoreText overlay (`kCGTextInvisible`) with inter-word spaces, script-aware `CTFontCreateForString` fallback, optional scan deskew (`VNDetectHorizonRequest`), page ranges, skip-searchable-pages heuristic, disk-backed `CGContext` streaming (`ocrStreamTempURL`) with `malloc_zone_pressure_relief`, outline/link preservation, cancellation cleanup, and bidi control-character sanitization in `.txt` sidecar output. `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`Phase34Tests.swift`, `PDFOptimizationAndOCRTests.swift`, `FinalHardeningRegressionTests.swift`).
  - **PDF/A Archiving (`PDFArchivalService.swift`, `PDFArchivalView.swift`, `PDFDocumentInspector.validatePDFA`):** Generates `PDF/A-1b`, `PDF/A-2b`, `PDF/A-3b`, and `PDF/A-4` via bundled LibreOffice `draw_pdf_Export` (`SelectPdfVersion=1,2,3,4`), explicitly rejects `PDF/A-2u` generation, and performs structural/XMP `pdfaid`/`/OutputIntents`/font-embedding/encryption/transparency inspection (explicitly disclosed as structural inspection rather than a full veraPDF syntax preflight engine). `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`Phase34Tests.swift`, `PDFToolboxPro2Tests.swift`).
  - **Permanent Redaction vs. Redaction Draft (`PDFRedactionService.swift`, `PDFRedactionView.swift`, `PDFToolboxUndoCommands.swift`):**
    - *Redaction Draft:* `PDFRedactionDraft` in `PDFToolboxStore` holds pending search terms, manual rectangles, and whole-page ranges in RAM only (`PDFRedactionDraftUndoCommand.survivesRestart == false`) and displays red/orange preview overlays in `PDFRedactionView`.
    - *Permanent Execution:* `PDFRedactionService.redact` writes exclusively to a new output file (`inputURL != outputURL`), removes overlapping annotations/form widgets, renders redacted pages into an isolated 300 DPI bitmap, paints solid fill over redacted rectangles *before* `bmpCtx.makeImage()`, re-emits only non-overlapping text spans outside padded redaction boxes, strips document metadata and XMP into a fresh single-revision (`%%EOF == 1`) PDF, and runs an independent post-write residual scanner across `PDFKit` text, annotations, Info dictionary, outlines, raw bytes, and zlib-inflated `FlateDecode` streams (`extractReadableAndFlateText`). `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`Phase34Tests.swift`, `PDFToolboxPro2Tests.swift`).
  - **PDF Comparison (`PDFComparisonService.swift`, `PDFCompareView.swift`):** Contiguous-slot LCS page alignment, line-by-line text diff, layout size/rotation delta, and normalized-DPI pixel diff + red highlight overlay PNG. `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`Phase34Tests.swift`).
  - **AcroForm Editing & XFA Detection (`PDFFormService.swift`, `PDFFormsView.swift`):** Text, checkbox, radio group exclusivity, and choice/dropdown editing, JSON export/import, `Reset Fields`, burn-in flattening (`0` interactive widgets remaining), and read-only `/XFA` detection warning. `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`Phase34Tests.swift`, `PDFToolboxPro2Tests.swift`, `Phase43ImagePDFUndoTests.swift`).
  - **Deep Document Inspector, Encryption, Permissions & Digital Signatures (`PDFDocumentInspector.swift`, `PDFSecurityService.swift`, `PDFInspectorSecurityView.swift`):** Inspects PDF version, page geometry, Info + XMP, `/FontFile*` embedding, image XObjects/color spaces/filters/SMask, `/Group` transparency, `/OutputIntents`, encryption cipher, `CGPDFAccessPermissions`, and digital signature `/ByteRange` + `/Contents` + CMS signer extraction (`extractCMSSignerAndReason`). Encrypts with user/owner passwords and permissions; enforces `permissionsStatus == .owner` before decrypting; warns when re-saving invalidates digital signatures. `IMPLEMENTED`, `INTEGRATED`, `TESTED` (`Phase34Tests.swift`, `PDFToolboxPro2Tests.swift`).

---

### F. Watch Folder / Automatic Conversion

- **Audit Classification:** **Hiç uygulanmamış (`NOT_IMPLEMENTED`) — Only downstream headless preset execution infrastructure (`PresetExecutor`) exists.**
- **Source Code Evidence:**
  - A repository-wide search for `WatchFolder`, `FSEventStream`, `DispatchSource.makeFileSystemObjectSource`, directory monitoring, file stability polling, or launch-at-login automation confirms **zero** Watch Folder files, classes, settings, or UI views exist in `LocalConvert/` or `LocalConvertTests/`.
  - Only `LocalConvert/Core/Presets/PresetExecutor.swift:20–115` (documented in `docs/PRESET_ARCHITECTURE.md:7, 98–116` from Phase 19) exists as a UI-independent batch preset job builder (`PresetExecutor.execute(preset:inputURLs:conversionManager:conversionQueue:...)`).
  - Every Watch Folder sub-feature (directory monitoring, FSEvents/DispatchSource, automatic conversion trigger, duplicate event debouncing, recursive directory watching, in-flight file write completion detection, error quarantine, pause/resume, enable/disable, persistence, lifecycle integration, and tests) is `NOT_IMPLEMENTED`.

---

### G. Video Infrastructure & Video Trim Feasibility Analysis

#### 1. Audit of Existing Video Infrastructure (`LocalConvert/Engines/Media/`)
- **FFmpeg & FFprobe Integration (`BundledFFmpegProvider.swift`, `BaseFFmpegProvider.swift`, `MediaProbe.swift`):**
  - Bundled `arm64` static `ffmpeg` and `ffprobe` (`9.0.2`) in `LocalConvert/Resources/ffmpeg/`.
  - `MediaProbe.probe(url:ffprobePath:)` (`MediaProbe.swift:12–121`) parses container format, duration, bitrate, and per-stream `MediaStreamInfo` (`index`, `streamType`, `codecName`, `width`, `height`, `frameRate`, `sampleRate`, `channels`, `duration`, `isAttachedPic`).
  - `MediaProbe.validate(outputURL:expectedFormat:ffprobePath:)` (`MediaProbe.swift:124–167`) verifies non-zero output size and expected stream presence after every FFmpeg execution.
- **Supported Video Formats & Codecs (`MediaConversionEngine.swift:29–37`, `BaseFFmpegProvider.swift:327–615`):**
  - **Inputs (19):** `.mp4`, `.mov`, `.mkv`, `.webm`, `.avi`, `.wmv`, `.asf`, `.m4v`, `.threeGP`, `.threeG2`, `.mts`, `.m2ts`, `.mpg`, `.ts`, `.flv`, `.f4v`, `.vob`, `.m2v`, `.ogv` (plus `.gif`, `.apng`).
  - **Outputs (17):** `.mp4`, `.mov`, `.mkv`, `.webm`, `.avi`, `.wmv`, `.asf`, `.m4v`, `.threeGP`, `.threeG2`, `.mpg`, `.ts`, `.flv`, `.f4v`, `.vob`, `.m2v` (plus `.gif`, `.apng`, and all 18 audio extraction formats).
  - **Encoders:** Apple Silicon hardware-accelerated `h264_videotoolbox` (`-q:v 45/60/75/90` or target bitrate `-b:v`/`-maxrate`/`-bufsize`, `yuv420p`, even-dimension scale filter `scale=trunc(iw/2)*2:trunc(ih/2)*2`), `libvpx-vp9` (WebM), `mpeg4` (AVI), `flv`, `wmv2` (WMV/ASF), `mpeg2video` (MPG/VOB/M2V).
- **Stream Copy, Multi-Audio & Subtitle Handling (`BaseFFmpegProvider.swift:268–365`):**
  - `canStreamCopy(inputInfo:targetFormat:options:)` automatically selects `-c copy` when container-compatible (MP4/M4V: H.264/HEVC + AAC/MP3; MOV: H.264/HEVC/ProRes + AAC/PCM/ALAC/MP3; MKV: any codec) and no quality/size/preset override is active.
  - `subtitleArguments(for:inputInfo:isStreamCopy:)` (`BaseFFmpegProvider.swift:286–323`) maps `-map 0:v:0? -map 0:a?` (preserving all audio streams) and converts text subtitles to `mov_text` (MP4/MOV/M4V), `webvtt` (WebM), or `-c:s copy` (MKV) while stripping bitmap subtitles (`dvd_subtitle`, `hdmv_pgs_subtitle`) from incompatible containers.
- **Progress, Cancellation, Temp Management & Output Reservation (`BaseFFmpegProvider.swift:103–208`, `ConversionManager.swift:9–122`):**
  - Runs inside isolated temp directory `LocalConvert-Media-<UUID>` with `defer` cleanup.
  - Streams `-progress pipe:1` (`out_time_us=`) via `AsyncProcessRunner.awaitExit(of:)` (`ConversionManager.swift:32–121`), which terminates and `SIGKILL`-escalates child processes on `Task` cancellation.
  - Finalizes output atomically via `ConversionManager.finalizeOutputFile` (`OutputReservationRegistry`).
- **What Does NOT Exist Yet for Video:**
  - Zero video player preview (`AVPlayer` / `AVPlayerView` / `VideoPlayer`), zero video timeline frame strip (`AVAssetImageGenerator`), zero video trim start/end model or UI, and zero `-ss` / `-to` video trim arguments in `BaseFFmpegProvider.buildFFmpegArguments`.

#### 2. Video Trim Technical Feasibility & Method Comparison

| Dimension | Method 1: Stream Copy Trim (`-c copy`) | Method 2: Frame-Accurate Re-encode Trim |
|---|---|---|
| **FFmpeg Mechanism** | `ffmpeg -ss <start> -to <end> -i <in> -map 0:v:0? -map 0:a? ... -c copy -avoid_negative_ts make_zero <out>` | `ffmpeg -ss <start> -to <end> -i <in> -map 0:v:0? -map 0:a? <videoEncodingArgs> <audioEncodingArgs> <out>` |
| **Speed & CPU/GPU Cost** | Near-instantaneous (`~0.1–0.5s` for 100 MB MP4; disk I/O bound). | Hardware-accelerated via `h264_videotoolbox` on Apple Silicon (`~150–250 fps` for 1080p); slower for `libvpx-vp9` (WebM). |
| **Visual Quality** | **100% lossless** (zero generational re-compression). | Lossy re-encode controlled by `QualityPreset` (`-q:v 45..90` or `-crf`). |
| **Cut Precision & Keyframe (GOP) Constraint** | **Snaps to nearest preceding/succeeding I-frame (keyframe).** On typical 2s–10s GOP H.264/HEVC files, cut points can drift by up to the GOP interval or leave leading B/P-frame decode artifacts if not keyframe-aligned. | **Exact frame-level precision** (`±1 frame`, e.g., `16.6 ms` at 60 fps): FFmpeg decodes from the preceding keyframe and encodes starting at the exact target timestamp. |
| **Audio/Video Sync** | Requires `-avoid_negative_ts make_zero` (and for MP4/MOV `-movflags +faststart`); minor A/V packet start offset (`< 1 GOP`) can occur in players that do not honor edit lists (`elst`). | Sample-accurate A/V synchronization; timestamps are regenerated from `0.000s` on both video and audio streams. |
| **Container Compatibility** | Requires source codecs to be compatible with output container (or output format == input format). | Works across all 17 supported video output containers and GIF/APNG. |

#### 3. Recommended First-Release (v1) Video Trim Scope & Architecture
1. **Where Video Trim Should Live (Architectural Justification):**
   - **Recommendation:** Integrate **Video Trim directly into the `Convert` workflow (`FileOptionsView` + an interactive `VideoTrimSheetView` modal launched from `FileRowView` / `FileOptionsView` for `.video` files)** rather than creating a 10th top-level sidebar tab (`Video Toolbox`).
   - **Rationale:**
     1. Unlike Audio Editor 2.0 (multitrack mixing + 7 DSP processors), PDF Toolbox Pro (19 document operations), or Image Toolbox Pro (14 Core Image/Vision studio sections), LocalConvert's video scope is single-file conversion + trimming. Creating a 10th top-level sidebar tab (`Video Toolbox`) for a single operation would fragment the 9-tab navigation (`⌘1`–`⌘8`, `⌘,`) and duplicate `Convert`'s format picker, Smart Presets, Target File Size, and Jobs Center pipeline.
     2. Embedding Video Trim into `ConversionOptions` (`videoTrimStart: Double?`, `videoTrimEnd: Double?`, `videoTrimMode: VideoTrimMode = .frameAccurate | .streamCopy`) + an interactive `VideoTrimSheetView` accessible directly on any queued video row (`FileRowView` scissor badge/button + `FileOptionsView`) allows Video Trim to work seamlessly with **Convert**, **Jobs Center**, **History**, **Presets**, **GIF/APNG clip export**, and **`OutputCreationUndoCommand`** with zero architectural duplication.
2. **Recommended v1 Scope:**
   - Interactive `VideoTrimSheetView` using native macOS `AVPlayer` + `AVAssetImageGenerator` (with `BundledFFmpegProvider` thumbnail fallback for MKV/WebM/AVI containers not natively decoded by `AVFoundation`).
   - Start (`In`) and End (`Out`) time range handles, playhead scrubbing, `±1 frame` / `±0.1s` / `±1.0s` step buttons, numeric `HH:MM:SS.mmm` fields, and `Play Selection` loop preview.
   - Explicit mode selector:
     - **Frame-Accurate (Re-encode)** — default when precision or format conversion/GIF export is needed.
     - **Fast Stream Copy (Lossless, Keyframe-Snapped)** — available when output container supports source codecs (`canStreamCopy` ignoring trim flags), with an explicit UI disclosure banner explaining keyframe snapping (`-avoid_negative_ts make_zero`).
   - Progress reporting in `BaseFFmpegProvider.convert` normalized against **trimmed duration** (`trimDuration = end - start`) rather than full source `inputInfo.duration` so the progress bar reaches `100%` accurately.
3. **Subtitles & Multi-Audio Stream Decision for v1 vs. v2:**
   - **Evidence-Based Decision:** Include **automatic pass-through of existing multi-audio and compatible text subtitle streams in v1** (reusing `BaseFFmpegProvider.subtitleArguments(for:inputInfo:isStreamCopy:)` at `BaseFFmpegProvider.swift:286–323`, which already maps `-map 0:v:0? -map 0:a?` and compatible text subtitles!), while **deferring per-track audio/subtitle stream selection UI and external `.srt` burn-in to v2**.
   - **Why:** `BaseFFmpegProvider.subtitleArguments` already handles `-map 0:v:0? -map 0:a?` and text subtitle transcoding (`mov_text` / `webvtt` / `copy`). Passing `-ss <start> -to <end>` before/after `-i` automatically trims all mapped audio and text subtitle streams in sync without extra complexity.

---

### H. Phase 47 — Product Experience, Lifecycle & UI Polish

#### 1. Source Code Verification of Phase 47 & Post-47.1.4 Theme Synchronization Fix
- **4-Mode Application Visibility & `AppLifecycleManager` (`LocalConvert/App/AppLifecycleManager.swift`, `LocalConvert/Core/Settings/AppSettings.swift:98–168, 324–440`, `LocalConvert/Features/Home/MenuBarView.swift`):**
  - `ApplicationVisibilityMode` (`.both`, `.dockOnly`, `.menuBarOnly`, `.neither`) maps 1-to-1 with `(showInDock, showInMenuBar)`.
  - `AppLifecycleManager.applyVisibilityPreferences` updates `MenuBarManager.shared.updateVisibility(showInMenuBar:)` first, then sets `NSApp.setActivationPolicy` (`.regular` when `showInDock == true`, `.accessory` when `false`, never `.prohibited`).
  - `registerWindow` sets `window.isReleasedWhenClosed = false` (`AppLifecycleManager.swift:120`) so closing the window hides it (`orderOut`) and `restoreOrActivateMainWindow` restores/deminiaturizes it without duplicate windows.
  - `shouldTerminateAfterLastWindowClosed` (`AppLifecycleManager.swift:213–221`) returns `false` when `appState.isConverting || appState.activeJobCount > 0`, and otherwise returns `!settings.keepAppOpenAfterConversion` independently of `ApplicationVisibilityMode`.
- **SettingsView Decomposition & Targeted `@AppStorage` Observation (`LocalConvert/Features/Home/SettingsView.swift:4–37`, `LocalConvertApp.swift:71`, `ContentView.swift:6`):**
  - `SettingsView` is decomposed into 11 isolated private section structs (`GeneralSettingsSection`, `OutputFilesSettingsSection`, `NotificationsSettingsSection`, `ConversionDefaultsSettingsSection`, `PerformanceSettingsSection`, `JobsHistorySettingsSection`, `UndoEditingHistorySettingsSection`, `PrivacyDiagnosticsSettingsSection`, `KeyboardShortcutsSettingsSection`, `AboutSettingsSection`, `ResetDefaultsSettingsSection`), eliminating full-window `AppSettings.shared` invalidation on single-toggle changes.
- **Post-47.1.4 Theme Synchronization Fix (`LocalConvert/Features/Shared/DesignSystem.swift:618–805`, `LocalConvert/Core/Settings/AppSettings.swift:87–93`, `LocalConvertApp.swift:72–79`, `ContentView.swift:7–14`):**
  - **Verified Present in Code:**
    1. `SystemAppearanceMonitor` (`DesignSystem.swift:619–661`) observes `NSApp.effectiveAppearance` via KVO and `AppleInterfaceThemeChangedNotification` via `DistributedNotificationCenter`, publishing `colorScheme: ColorScheme` (`.light` or `.dark`).
    2. `AppearanceMode.resolvedColorScheme(system:)` (`AppSettings.swift:87–93`) resolves `.system` to the concrete system `ColorScheme` (`.light` or `.dark`) rather than `nil`.
    3. `LocalConvertApp` (`LocalConvertApp.swift:76–79, 85`) and `ContentView` (`ContentView.swift:11–14, 24`) pass this non-optional `preferredColorScheme` to `.preferredColorScheme(preferredColorScheme)` and `.appOpaqueWindowChrome(preferredColorScheme: preferredColorScheme)`.
    4. `OpaqueChromeSentinelView.applyOpaqueWindowChrome` (`DesignSystem.swift:699, 746–803`) guards against recursive re-entry via `guard !isApplyingChrome else { return }`, commits cache state `(appliedWindowID, lastAppliedScheme, lastEffectiveAppearanceName)` before mutating `window.appearance`, and batches all window chrome mutations inside `CATransaction` (`CATransaction.setDisableActions(true)`).
  - **Subtle Technical Observation on `OpaqueChromeSentinelView`:** Because `ContentView` now always passes a non-nil `ColorScheme` (`.light` or `.dark`) to `.appOpaqueWindowChrome(preferredColorScheme:)`, `OpaqueChromeSentinelView.preferredColorScheme` is never `nil` in normal app operation (`window.appearance` is always explicitly `.aqua` or `.darkAqua`, matching `SystemAppearanceMonitor.shared.colorScheme`). The `case nil:` branch in `OpaqueChromeSentinelView` (`DesignSystem.swift:727, 738, 782`) is now only exercised by unit test `opaqueWindowChromeHostCachingAndWindowReplacement` (`Phase47LifecycleAndUXTests.swift:524, 559`).

#### 2. Verification Boundary Distinction (Unit Tests vs. Accessibility API vs. Visual/User Verification)
- **Automated Unit Tests (`Phase47LifecycleAndUXTests.swift`):** `13` `@Test` functions verify state machines, preference migration, window retention/restoration, `ApplicationVisibilityPopoverContent.applySelection`, `AccessibilityAnnouncer` deduplication, shortcut uniqueness, `routeOpenFiles`, Drag & Drop feedback, `ErrorDetailsFormatter` home-path redaction, `AppTheme.Layout`, `OpaqueChromeSentinelView` caching, `DroppedFile` caching, and `AppearanceMode.resolvedColorScheme(system:)`.
- **Accessibility API (`System Events`) + `xctrace` Runtime Telemetry (`PHASE47_FINAL_REPORT.md` §24.7):** Verified 65 live process interactions across Settings, Application Visibility popover, and theme switching in Phase 47.1.4.
- **Direct Visual User Verification (`THEME_TRANSITION_FIX.md`):** User manually verified and accepted the post-47.1.4 `Light/Dark → System` theme transition fix.
- **Unverified Live Audio / Screen-Recording Items (`UNABLE_TO_DETERMINE`):** Live VoiceOver spoken output and pixel-level `screencapture` regressions (blocked by macOS Screen Recording TCC permission in headless runs).

---

### I. Architecture, Reliability & Technical Debt Audit

1. **Three-Layer Architecture & State Ownership:**
   - Clean separation across `Features/` (SwiftUI views), `App/` + `Core/` (`@MainActor` coordinators/stores: `AppState`, `ConversionManager`, `ConversionQueue`, `UndoRedoCoordinator`, `MetadataManager`, `PresetManager`, `HistoryManager`, `AppLifecycleManager`), and `Engines/` (stateless or actor-isolated media, image, PDF, audio editor, office, archive, subtitle, and text processors).
   - **State Ownership Inconsistency:** While `AudioEditorStore`, `ImageToolboxStore`, and `PDFToolboxStore` are long-lived `@MainActor` stores on `AppState` (`AppState.swift:184–186`), `AudioToolboxView` (`AudioToolboxView.swift:49–68`) and legacy `PDFToolboxView` page-range/rotation inputs (`PDFToolboxView.swift:7–12`) keep configuration in view-local `@State` that resets across tab switches.
2. **Swift 6 Concurrency & Subprocess Lifecycle:**
   - `SWIFT_VERSION: "6.0"` and `SWIFT_STRICT_CONCURRENCY: complete` are enabled in `project.yml:14, 18`.
   - `AsyncProcessRunner` (`ConversionManager.swift:32–121`) uses `ProcessExecutionBox` (`NSLock`) to coordinate cancellation, `SIGTERM` → 250 ms → `SIGKILL` escalation, and concurrent stdout/stderr pipe draining without `terminationHandler` data races.
   - **Defect Found (`VideoMetadataProvider.swift:96–112`):** `VideoMetadataProvider.readMetadata` spawns `ffprobe -v error -show_format -show_streams -of json` using a raw `Process()` + `Pipe()` and calls `process.waitUntilExit()` (line 110) **before** `pipe.fileHandleForReading.readDataToEndOfFile()` (line 111) on an async path, bypassing `AsyncProcessRunner` and risking a pipe-buffer deadlock on videos with >64 KB of stream/tag JSON metadata.
3. **File Overwrite Safety & Atomic Output Creation:**
   - `OutputReservationRegistry` (`ConversionManager.swift:9–30, 810–906`) atomically reserves unique output paths across concurrent jobs and creates placeholder files (`O_CREAT | O_EXCL`) so parallel workers cannot collide.
   - **Exception Found (`MetadataManager.save()`, `MetadataManager.swift:173–218`):** The top-level `Metadata` tab and `Audio Toolbox → Tags & Cover Art` write metadata **in-place** to the source file (`SafeMetadataWriter.performSafeWrite(on: url)`) without offering a `"Save Copy..."` option (unlike `ImageToolboxView.saveMetadataInPlaceOrCopy` at `ImageToolboxView.swift:848–873`) and without staging a recovery backup in `RecoveryArtifactManager`.
4. **Memory Management & Large File Handling:**
   - `ConversionQueue.jobSlotCost(for:)` (`ConversionQueue.swift:39–56`) assigns cost `2` to video, PDF, Office, and `>= 36 MP` image jobs.
   - `ImageProcessor` disables Core Image intermediate caching (`CIContextOption.cacheIntermediates: false`) and flushes `ctx.clearCaches()` on renders `>= 16 MP`.
   - `PDFOCRService` streams multi-page OCR output directly to a disk-backed `CGPDFContext` (`ocrStreamTempURL`) and invokes `malloc_zone_pressure_relief(nil, 0)` every 4 pages.
   - **Test Stability Debt (`Phase422ClosureTests.swift`):** As documented in `PHASE46_FINAL_REPORT.md` §12.2 and `PHASE47_FINAL_REPORT.md` §16, `Phase422ClosureTests.largeImageMemoryStabilityAndDiagnostics()` asserts on single-category Mach `TASK_VM_INFO` (`nonVolatileInternalMB` and `footprintMB`) deltas (`<= +150 MB`), which are sensitive to macOS kernel purgeable/IOSurface page reclassification when run late inside a 77-suite shared `xctest` process if background GUI processes are active.
5. **Workspace Hygiene & Untracked Root Artifacts:**
   - Repository root (`/Users/cancan/Desktop/LocalConvert/`) currently contains untracked directories `Launch_LocalConvert_2026-11-21_04.29.07_6FBCD59E.trace/`, `debug-deployment/`, `build/`, and `release/`. `.gitignore` ignores `build/`, `release/`, and `*.trace` is **not** in `.gitignore` (let's note that `.trace` bundles in root show up as untracked in `git status`).

---

## 3. Automated Test Architecture & Suite Inventory

A static scan of `LocalConvertTests/*.swift` confirms **`57` test files**, **`77` `@Suite` declarations**, and **`603` `@Test` functions**:

| Test File | `@Test` Count | Primary Coverage Scope |
|---|---:|---|
| `LocalConvertTests.swift` | 162 | Core detectors, registry, output manager, image/media/office/PDF/text/subtitle engines |
| `SmartPresetRegressionTests.swift` | 22 | Smart Preset state transitions, manual edit reconciliation, format switching, VBR polarity |
| `Phase17Tests.swift` | 17 | Format registry & conversion matrix foundations |
| `GlobalUndoRedoTests.swift` | 16 | `UndoRedoManager`, `UndoRedoCoordinator`, `RecoveryArtifactManager`, text-responder isolation |
| `Phase19Tests.swift` | 16 | `SavedPreset`, `PresetStore`, `PresetValidator`, `PresetExecutor` |
| `Phase15Tests.swift` | 14 | Batch queue, multi-output PDF/Image jobs, cancellation |
| `Phase23Tests.swift` | 14 | Image optimization modes, target file size binary search, resize, crop, EXIF orientation |
| `Phase24Tests.swift` | 13 | `PDFGridPageSplitter` 2×2 multi-up slide separation & empty cell detection |
| `Phase30Tests.swift` | 13 | Release readiness, `AppSettings`, `DiagnosticLogManager`, keyboard shortcut descriptors |
| `Phase47LifecycleAndUXTests.swift` | 13 | 4 visibility modes, `AppLifecycleManager`, migration, shortcuts, Drag & Drop, `ErrorDetailsFormatter`, `OpaqueWindowChromeHost`, `AppearanceMode.resolvedColorScheme` |
| `Phase40Tests.swift` | 12 | Output reservation, 16-bit image fidelity, WebP metadata muxing, JXL mmap, ICO/PDF Office |
| `Phase18Tests.swift` | 11 | Expanded format detection & conversion routes |
| `Phase26Tests.swift` | 11 | Jobs Center retention, batch grouping, progress aggregation |
| `Phase28Tests.swift` | 11 | LibreOffice watchdog, locked PDF handling, subtitle mapping |
| `Phase37ImageToolboxCompletionTests.swift` | 11 | Perspective, canvas/border, DPI, histogram/palette, PSNR/SSIM, contact sheet, batch rename, duplicate detection, SVG optimizer |
| `AuditRemediationTests.swift` | 10 | Security & data integrity audit remediations |
| `FinalHardeningRegressionTests.swift` | 10 | Final 1.0 hardening regression checks (WebP, 16-bit/HDR, archive traversal, OCR sidecar) |
| `Phase20Tests.swift` | 10 | Finder Quick Actions, `localconvert://` URL scheme, Services handoff |
| `Phase29Tests.swift` | 10 | AIFF output, folder smart import, RAW thumbnails, target size floor notice |
| `Phase33Tests.swift` | 10 | Audio Toolbox Pro (codecs, filter graph, waveform, silence removal, multi-segment, merge) |
| `Phase43ImagePDFUndoTests.swift` | 10 | Image Toolbox & PDF Toolbox draft/file Undo/Redo & restart rehydration |
| `Phase16Tests.swift` | 9 | Metadata providers (Image, Audio, Video, PDF, Office) & `SafeMetadataWriter` |
| `AudioEditorCoreTests.swift` | 8 | Audio Editor models, editing operations, crossfade math, persistence, relinking, undo/redo |
| `AudioToolboxPro2Tests.swift` | 8 | Two-pass EBU R128 loudness, true-peak limiter, pitch/speed, artwork normalization |
| `PDFToolboxPro2Tests.swift` | 8 | Redaction stream verification, digital signature CMS parsing, PDF/A validator, AcroForm reset |
| `Phase20BTests.swift` | 8 | `MenuBarManager` lifecycle & status item actions |
| `Phase34Tests.swift` | 8 | PDF Toolbox Pro (OCR, PDF/A 1b/2b/3b/4, permanent redaction, compare, compress, forms, security) |
| `Phase35Tests.swift` | 8 | JPEG XL (`libjxl`) & Image Toolbox Pro pipeline |
| `Phase13Tests.swift` | 7 | Core conversion manager & history persistence |
| `Phase25Tests.swift` | 7 | Multi-file PDF workflow & `AppNotificationManager` batch aggregation |
| `Phase32Tests.swift` | 7 | 78-format `FormatCapabilityRegistry` & `ConversionMatrix` |
| `Phase42ContainerAndBitstreamTests.swift` | 7 | MP4/ISOBMFF atom safety, ID3v2.2/2.3/2.4 normalization, audio packet SHA-256 preservation |
| `AudioDSPTests.swift` | 6 | Parametric EQ, Compressor, Limiter, Noise Gate, Spectral NR, Delay/Reverb, Peak/RMS normalize |
| `PDFPageManagementTests.swift` | 6 | `PDFCoordinateGeometry`, `PDFPageManagementService`, outline remapping, 100-page thumbnail cache |
| `Phase26_1Tests.swift` | 6 | Jobs Center UI state & cleanup edge cases |
| `Phase46IntegrationAndPerfTests.swift` | 6 | `.lcimg` project security/relink, undo rehydration, 24 MP proxy latency, 50 MP memory stability |
| `AudioEditorPerformanceTests.swift` | 5 | 100-edit + 25-undo scaling, 64 MB waveform cache budget, batch rename & output undo safety |
| `ImageColorAdjustmentsTests.swift` | 5 | Color & Light, monotone spline Tone Curves, channel Levels, 3-way Color Balance |
| `Phase14Tests.swift` | 5 | Output directory resolution & collision policies |
| `Phase39AuditTests.swift` | 5 | Phase 39 format & metadata edge cases |
| `Phase41SpotifyCompatibilityTests.swift` | 5 | Spotify Local Files classification, DRM blocking, ID3/MP4 normalization, artwork repair |
| `Phase41ValidationAndEfficiencyTests.swift` | 5 | Workload cost scheduling, process runner cleanup, idle efficiency |
| `AudioTimelineTests.swift` | 4 | 5 fade curves, crossfade overlap, fixed/BPM snap-to-grid, track grouping |
| `ImageAdjustmentsFoundationTests.swift` | 4 | 16-bit orientation/shape preservation, `ImagePreviewProxyCache` LRU & invalidation |
| `PDFAnnotationTests.swift` | 4 | 10 annotation subtypes round-trip, burn-in flatten, non-redaction proof, coalesced undo |
| `Phase36ImageToolboxTests.swift` | 4 | Interactive shape crop, upscale, background removal |
| `Phase422ClosureTests.swift` | 4 | 50 MP / 100 MP repeated memory bounds, mid-flight LibreOffice/FFmpeg cancellation, multi-`covr` |
| `Phase45IntegrationTests.swift` | 4 | Audio Editor v2 autosave/relink, reader invalidation, key monitor guards, offline/realtime parity |
| `AudioChainPresetPersistenceTests.swift` | 3 | `AudioEffectPresetStore` CRUD/clamping, ordered effect chain undo, v1→v2 project migration |
| `AudioEditorExportAcceptanceTests.swift` | 3 | Multitrack WAV/MP3/M4A/FLAC/stem export, proxy effects, cancellation cleanup, FFT spectrum |
| `AudioExportProTests.swift` | 3 | Two-pass EBU R128 export, 16-bit dithering, batch collision safety |
| `ImageGeometryProTests.swift` | 3 | Continuous straighten, exact inscribed auto-crop math, Vision horizon detection |
| `Phase42ValidationAndHDRTests.swift` | 3 | Wide-gamut Display P3 / 16-bit HDR preservation & LibreOffice route checks |
| `Phase44UndoRedoTests.swift` | 3 | PDF config/page undo rehydration, password scrubbing, 60-page optimization stability |
| `ImageEffectsAndPresetsTests.swift` | 2 | Ordered 9-effect stack execution, Look Presets CRUD/rename/batch apply |
| `ImageRAWDevelopTests.swift` | 2 | `CIRAWFilter` model/clamping & TIFF-in-DNG fallback verification |
| `PDFOptimizationAndOCRTests.swift` | 2 | 4-tier PDF optimization & word-level Vision OCR + deskew + streaming |
| **Total (`57` files, `77` `@Suite`s)** | **603** | **Static repository total (no test execution performed in Phase 48)** |

---

## 4. Historical Phase Reconciliation (Phases 21–47.1.4+)

| Historical Phase / Claim | Historical Report Reference | Actual Current Source Code Reality | Reconciliation Verdict |
|---|---|---|---|
| **Phase 21 — Video Trim** | Mentioned in `docs/PRESET_ARCHITECTURE.md:7` (Phase 19) as upcoming `"Phase 20 (Video Trim)"`; skipped in actual Phases 20–47 numbering. | Zero video trim code exists (`BaseFFmpegProvider.swift` has no `-ss`/`-to` for video; only audio trim exists in `AudioToolboxView` and `AudioEditor`). | **Never Implemented (`NOT_IMPLEMENTED`)** — Re-added to the development roadmap (Section 2.G & `docs/PHASE48_FINAL_DEVELOPMENT_ROADMAP.md`). |
| **Phase 22 — Watch Folder** | Mentioned in `docs/PRESET_ARCHITECTURE.md:7, 98–116` and `PresetExecutor.swift:28` as upcoming `"Phase 21 (Watch Folder / Automatic Conversion)"`. | Only the headless preset job builder `PresetExecutor.execute(...)` exists. Zero directory watchers (`FSEvents`/`DispatchSource`), stability polling, persistence, or Watch Folder UI exist. | **Never Implemented (`NOT_IMPLEMENTED`)** — Only prerequisite `PresetExecutor` infrastructure exists. |
| **Phase 23 — Image Optimization** | `phase23-report.md`, `docs/IMAGE_OPTIMIZATION.md` (`273/273` tests, `14/14` in `Phase23Tests.swift`). | `ImageOptimizationModels.swift`, `ImageProcessor.swift`, `ImageOptimizationView.swift`, and `Phase23Tests.swift` (`14` tests) are present and expanded by Phases 35–46. Minor parameter mismatch exists between `ImageOptimizationMode.maximum`/`.smallFile` in `ImageOptimizationView.swift:420–429` and `ConversionPreset.maximumQuality`/`.smallFile` in `ConversionEngine.swift:225–265`. | **Implemented & Integrated** (with minor preset reconciliation nuance). |
| **Phase 24 — PDF Grid Splitter vs. OCR** | In actual project history, Phase 24 (`phase24-report.md`, `Phase24Tests.swift` `13` tests) was `PDFGridPageSplitter` (`"Sayfaları Ayır"`), while **OCR** was delivered in Phase 34 (`PDFOCRService.swift`, `Phase34Tests.swift`) and upgraded in Phase 44 (`PDFOptimizationAndOCRTests.swift`). | Both `PDFGridPageSplitter.swift` and `PDFOCRService.swift` (word-level Vision OCR, `CTFontCreateForString`, `VNDetectHorizonRequest` deskew, disk-backed streaming, `.txt` sidecar bidi sanitization) are fully implemented and integrated in `PDFToolboxView`. | **Implemented, Integrated & Tested.** |
| **Phase 25 — Multi-File PDF & Notifications vs. Release** | Phase 25 (`phase25-report.md`, `Phase25Tests.swift` `7` tests) delivered multi-file PDF workflows & `AppNotificationManager`. Release packaging was delivered in Phases 30, 40, 41, 42 (`scripts/package-release.sh`, `scripts/verify-dependencies.sh`, `THIRD_PARTY_NOTICES.md`). | All Phase 25 multi-file PDF workflows, `AppNotificationManager`, `scripts/package-release.sh`, `scripts/verify-dependencies.sh`, and `THIRD_PARTY_NOTICES.md` exist in the repository. Developer ID notarization remains environment-dependent (ad-hoc signed locally). | **Implemented & Integrated** (external Apple Developer ID notarization requires signing credentials). |
| **Phase 34 — PDF Toolbox Pro (`369/369` historical tests)** | `docs/PHASE34_REPORT.md` reported `369/369` tests across `41` suites and 8 Pro capabilities. | All 8 Phase 34 services (`PDFDocumentInspector`, `PDFOCRService`, `PDFArchivalService`, `PDFRedactionService`, `PDFComparisonService`, `PDFCompressionService`, `PDFFormService`, `PDFSecurityService`) and `Phase34Tests.swift` (`8` tests) remain intact and were further expanded in Phase 38 (`PDFToolboxPro2Tests.swift`) and Phase 44 (`PDFPageManagementService`, `PDFAnnotationService`). Historical `369/369` count is superseded by current `603` `@Test` declarations. | **Historical Record Verified & Superseded by Phase 44.** |
| **Phase 43 — Global Undo/Redo** | `docs/AUDIO_EDITOR_2.0_UNDO_REDO_SMART_PRESET_REPORT.md` and `Phase43ImagePDFUndoTests.swift` (`10` tests). | Core Undo/Redo (`UndoRedoCoordinator`, `RecoveryArtifactManager`, `UndoMenuController`) and Audio/Image/PDF stores are present. However: (1) per-file `targetFormat` in `ImageToolboxView` is still view-local `@State` and not undoable; (2) `ConversionQueue` only records `[result.outputURL]` instead of `result.allOutputURLs` in `OutputCreationUndoCommand`; (3) `MetadataManager.save()` has no disk-level undo backup; (4) `ImageBatchRenameView`'s inline `"Undo Last Rename"` button bypasses `UndoRedoCoordinator`. | **Core Implemented; 4 Specific Integration Gaps Remain.** |
| **Phase 47 & 47.1.4 (`602/602` tests, `77` suites, `65` live UI interactions, `0` warnings)** | `docs/PHASE47_FINAL_REPORT.md` & `docs/PHASE47_1_4_AUDIT.md`. | (1) `PHASE47_FINAL_REPORT.md` §7 line 95 still describes the pre-47.1.1 termination rule, whereas actual code (`AppLifecycleManager.swift:213–221`) implements the §20 Phase 47.1.1 rule (`!settings.keepAppOpenAfterConversion` independent of visibility mode). (2) `PHASE47_FINAL_REPORT.md` §24.8 line 606 states temporary `.trace` files were cleaned up, but `Launch_LocalConvert_2026-11-21_04.29.07_6FBCD59E.trace/` and `debug-deployment/` remain untracked in the repository root. (3) The post-47.1.4 theme fix added a 13th test to `Phase47LifecycleAndUXTests.swift`, so the codebase now has **`603` `@Test` declarations across `77` suites** (only a focused `21/21` run was executed after that 13th test was added). | **Code Verified; Historical Report Numbers Must Not Be Cited as Post-Theme-Fix Full Regression.** |
| **Post-47.1.4 Theme Synchronization Fix** | `docs/THEME_TRANSITION_FIX.md` & `docs/PHASE47_FINAL_REPORT.md` §25 (`21/21` focused tests + user manual acceptance). | `SystemAppearanceMonitor` (`DesignSystem.swift:619–661`), `AppearanceMode.resolvedColorScheme(system:)` (`AppSettings.swift:87–93`), `OpaqueChromeSentinelView.isApplyingChrome` (`DesignSystem.swift:699, 747`), and `Phase47LifecycleAndUXTests.appearanceModeResolvesSystemToExplicitColorScheme` (`Phase47LifecycleAndUXTests.swift:650–664`) are all present and match the documentation. | **Verified in Source Code, Focused Tests & Manual User Acceptance.** |

---

## 5. Prioritized Architecture, Reliability & Technical Debt Register (`P0`–`P3`)

### `P0 — Critical`
- **None found.** No active data corruption, arbitrary code execution, or unguarded source-file deletion vulnerability was identified in the current source tree.

### `P1 — High`
1. **`P1-01` (Code-Proven): Multi-Output Conversion Jobs Record Incomplete `OutputCreationUndoCommand` (`LocalConvert/Core/ConversionQueue/ConversionQueue.swift:202–203, 265–291`)**
   - **Evidence:** `handleJobCompletion` passes `outputURL: result.outputURL` (single URL) instead of `result.allOutputURLs` (`[outputURL] + additionalOutputURLs`) to `recordOutputUndoIfSafe` and `batchCompletedOutputURLs`.
   - **Impact:** Pressing `Cmd+Z` after any multi-output job (PDF Split, PDF-to-Images, OCR with `.txt` sidecar, Audio multi-segment extraction, Image multi-size batch export) removes only the first output file and leaves all `additionalOutputURLs` orphaned on disk.
2. **`P1-02` (Code-Proven): Top-Level `Metadata` Tab & `Audio Toolbox → Tags` Overwrite Source Files In-Place Without `"Save Copy..."` or Disk-Level Undo Backup (`LocalConvert/Core/Metadata/MetadataManager.swift:173–218`)**
   - **Evidence:** `MetadataManager.save()` calls `provider.writeMetadata(doc, to: url)` in place on `activeURL` without staging the original file into `RecoveryArtifactManager` or recording a disk-level undo command (`UndoOperationType.metadataSaveToDisk` at `OperationContext.swift:164` is never used).
   - **Impact:** Violates non-destructive source protection and leaves the user unable to undo a disk metadata save via `Cmd+Z` (unlike `ImageToolboxView.saveMetadataInPlaceOrCopy` at `ImageToolboxView.swift:848–873`).
3. **`P1-03` (Code-Proven): `ImageBatchRenameView` Desynchronizes `AppState.droppedFiles` and Its Inline `"Undo Last Rename"` Button Bypasses `UndoRedoCoordinator` (`LocalConvert/Features/ImageToolbox/ImageConvertUtilitiesViews.swift:378–408`)**
   - **Evidence:** Applying batch rename moves files on disk (`move.from -> move.to`) and records `BatchRenameUndoCommand` in `UndoRedoCoordinator`, but (a) never updates `AppState.droppedFiles` or `ImageToolboxStore.configsByURL` keys to the new URLs, leaving loaded images pointing at missing paths, and (b) clicking the inline `"Undo Last Rename"` button calls `ImageBatchRenameService.undo(manifest)` directly without popping `BatchRenameUndoCommand` from `UndoRedoCoordinator`.
4. **`P1-04` (Code-Proven): Image Toolbox Per-File `targetFormat` Is Disconnected from `ImageToolboxStore` and Global Undo/Redo (`LocalConvert/Features/ImageToolbox/ImageToolboxView.swift:12, 386, 489, 624–630`, `LocalConvert/Core/UndoRedo/ImageToolboxUndoCommands.swift:239, 271–279`)**
   - **Evidence:** `ImageToolboxView` binds its output format pickers to view-local `@State private var targetFormat: FileFormat = .jxl` rather than `imageToolboxStore.targetFormatByURL`, overwrites `targetFormat` when switching primary files (`loadPrimaryDetails`), and records no `UndoableCommand` on format change.
5. **`P1-05` (Code-Proven): Exporting Animated GIF / APNG / WebP / JXL from `Image Toolbox Pro` Drops Animation Frames (`LocalConvert/Engines/Image/ImageConversionEngine.swift:146–157`, `LocalConvert/Engines/Image/ImageProcessingService.swift:199, 249, 960`)**
   - **Evidence:** `ImageConversionEngine.convert` delegates `image_toolbox == "true"` jobs to `ImageProcessingService.processToFile` before reaching `convertAnimatedIfApplicable` (`ImageConversionEngine.swift:250–277`), and `ImageProcessingService` decodes only frame 0 (`decodeAllFrames: false`).

### `P2 — Medium`
1. **`P2-01` (Code-Proven): Synchronous `process.waitUntilExit()` Before Pipe Read in `VideoMetadataProvider.readMetadata` (`LocalConvert/Core/Metadata/Providers/VideoMetadataProvider.swift:96–112`)**
   - **Evidence:** Calls `process.waitUntilExit()` (line 110) before `pipe.fileHandleForReading.readDataToEndOfFile()` (line 111) on `ffprobe -show_format -show_streams -of json`, risking a 64 KB pipe-buffer deadlock and bypassing `AsyncProcessRunner` / `MediaProbe.probe`.
2. **`P2-02` (Code-Proven): `UI_ONLY` Settings in `SettingsView` (`rememberLastUsedOptions` and `verboseLogging` / `DiagnosticLogManager`) (`LocalConvert/Core/Settings/AppSettings.swift:281–305, 570–571, 615–616`, `LocalConvert/Features/Home/SettingsView.swift:286, 531–545`)**
   - **Evidence:** Both toggles persist to `UserDefaults` with zero readers in production code, and no logger writes diagnostic files to `~/Library/Logs/LocalConvert/`.
3. **`P2-03` (Code-Proven): Audio Editor `AudioMarker` Model & Ruler Rendering Lack Creation/Editing Controls (`LocalConvert/Engines/AudioEditor/AudioEditorModels.swift:250–254, 264`, `LocalConvert/Features/AudioEditor/TimeRulerView.swift:62–75`)**
   - **Evidence:** `TimeRulerView` renders `store.project.markers`, but no store method or UI exists to add, rename, or delete markers.
4. **`P2-04` (Code-Proven): Non-Editor `AudioToolboxView` Sections Use Ephemeral View-Local `@State` Without Store Persistence or Config Undo (`LocalConvert/Features/AudioToolbox/AudioToolboxView.swift:49–68`)**
   - **Evidence:** Switching tabs away from `Audio Toolbox` resets `Quick Trim`, `Merge Audio`, and `Adjust & Effects` state; `.audioToolboxConfig` and `.audioToolboxSegmentEdit` (`OperationContext.swift:145–146`) are unimplemented.
5. **`P2-05` (Code-Proven): `ImageOptimizationMode` Picker Values for `Maximum Quality` and `Small File` Diverge from `ConversionPreset` (`LocalConvert/Features/Conversion/ImageOptimizationView.swift:399–444` vs. `LocalConvert/Core/Conversion/ConversionEngine.swift:225–265`)**
   - **Evidence:** Selecting `Optimization Mode → Maximum Quality` (`0.95`) or `Small File` (`500 KB`, `0.55`) causes `reconcilePresetAfterManualEdit` to reset `Smart Preset` to `Custom`.
6. **`P2-06` (Code-Proven): Secondary File-Mutating Utilities (`ImageDuplicateFinderView.moveSelectedToTrash`, `SpotifyCompatibilityView.runNormalizeEligible`, `PresetManager.resetToDefaults`, `Convert` Per-File Option Edits) Lack Undo Recording**
   - **Evidence:** `ImageConvertUtilitiesViews.swift:548–554` (trashes files without removing them from `AppState.droppedFiles` or recording `.fileTrash`), `SpotifyCompatibilityView.swift:895–954` (creates normalized files without `OutputCreationUndoCommand`), `PresetManager.swift:107–111` (`resetToDefaults` skips `recordPresetUndo`), and `AppState.swift:669–797` (per-file format/options changes in `Convert` tab skip undo).
7. **`P2-07` (Code-Proven): `Phase422ClosureTests` Shared-Host Mach `TASK_VM_INFO` Sensitivity (`LocalConvertTests/Phase422ClosureTests.swift:250–355`)**
   - **Evidence:** Asserts single-category `nonVolatileInternalMB` and `footprintMB` deltas (`<= +150 MB`) that fluctuate when macOS reclassifies purgeable/IOSurface pages across a 77-suite shared `xctest` process.

### `P3 — Low`
1. **`P3-01` (Code-Proven): Unused `OperationContext` and `UndoOperationType` Enum Cases (`LocalConvert/Core/UndoRedo/OperationContext.swift:8, 15, 16, 119–177`)**
   - **Evidence:** 3 `OperationContext` cases (`.jobs`, `.history`, `.fileOperations`) and 10 `UndoOperationType` cases are declared but have no active command producers.
2. **`P3-02` (Code-Proven): Untracked Root Workspace Artifacts & Stale Section 7 Text in `PHASE47_FINAL_REPORT.md`**
   - **Evidence:** `Launch_LocalConvert_2026-11-21_04.29.07_6FBCD59E.trace/` and `debug-deployment/` are untracked in the repository root (`.gitignore` does not ignore `*.trace` or `debug-deployment/`), and `docs/PHASE47_FINAL_REPORT.md:95` retains pre-47.1.1 termination prose superseded by Section 20.
3. **`P3-03` (Evidence Boundary): Zero Real Camera Sensor RAW Fixtures in Repository (`LocalConvertTests/ImageRAWDevelopTests.swift`)**
   - **Evidence:** `CIRAWFilter` demosaicing is implemented in `ImageAdjustmentsEngine.loadWithCIRAWFilter`, but automated tests only supply a 16-bit TIFF with a `.dng` extension (`usedRAWFallback == true`).
