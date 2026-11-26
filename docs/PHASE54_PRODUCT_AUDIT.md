# LocalConvert — Phase 54 Product Audit

**Date:** 2026-11-22  
**Auditor Role:** Senior Software Architect & Product Auditor (Audit-Only Phase)  
**Repository:** `/Users/cancan/Desktop/LocalConvert/` (`RighteousLife/LocalConvert`)  
**Target Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  

---

## 1. Historical Reconciliation: Phase 48–53 Gaps (`GAP-01` through `GAP-12`)

Every Phase 48 gap was cross-checked directly against current source code and automated test evidence collected in Phases 49–53 rather than trusting summary claims.

| Gap ID | Original Gap (Phase 48) | Current Status | Automated Evidence | Manual / Remaining Conditions |
| :--- | :--- | :---: | :--- | :--- |
| **GAP-01** | Multi-output `OutputCreationUndoCommand` | **COMPLETE** | Verified `OutputCreationUndoCommand` deduplication + `protectedSourceURLs` exclusion (`AppUndoCommands.swift:143–200`), `ConversionQueue.recordOutputUndoIfSafe`, and `Phase49DataSafetyAndUndoTests` (`7/7` pass). | Interactive Finder verification optional; API/disk semantics verified. |
| **GAP-02** | Non-destructive Metadata `"Save Copy..."` & disk undo | **PARTIALLY COMPLETE** | Top-level [MetadataView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Metadata/MetadataView.swift#L191-L231) and [AudioToolboxView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/AudioToolbox/AudioToolboxView.swift#L641-L668) use `MetadataManager.saveInPlace` / `saveCopy` + `MetadataFileWriteUndoCommand` (`Phase49` `7/7` pass). | Interactive `NSSavePanel` GUI sheet unverified via XCUITest; Image Toolbox uses a separate metadata write pipeline (`FINDING-PROD-03`). |
| **GAP-03** | Batch Image Rename state & undo sync | **COMPLETE** | `ImageConvertUtilitiesViews.swift:300–413`, `AppState.applyRenamedURLs`, and `Phase49DataSafetyAndUndoTests` (`7/7` pass). | Visual UI interaction only manual. |
| **GAP-04** | Image Toolbox per-file `targetFormat` undo & store | **COMPLETE** | `ImageToolboxStore`, `ImageTargetFormatUndoCommand`, and `Phase50CoreFeatureUndoTests` (`7/7` pass). | Interactive UI selection unverified via XCUITest. |
| **GAP-05** | Animated GIF/APNG/WebP/JXL frame preservation in Image Toolbox | **COMPLETE** | [ImageConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift#L250-L331) and `Phase49` animated tests pass. | None. |
| **GAP-06** | `VideoMetadataProvider` subprocess pipe deadlock | **COMPLETE** | `Phase49DataSafetyAndUndoTests.testVideoMetadataProviderAsyncProcessRunnerHandlesLargeStdoutAndRealMP4WithoutDeadlock` passes (`7/7`). | None. |
| **GAP-07** | Inactive settings (`rememberLastUsedOptions`, `verboseLogging`) | **COMPLETE** | `AppSettings.sanitizeOptionsForRemembering(_:)` ([AppSettings.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Settings/AppSettings.swift#L684-L715)), `Phase50CoreFeatureUndoTests`, and `Phase53VerificationTests` pass. | Interactive Settings toggle smoke test manual. |
| **GAP-08** | Audio Editor timeline markers | **PARTIALLY COMPLETE** | Store/service/Undo logic verified in `Phase50CoreFeatureUndoTests` (`7/7` pass). | Canvas ruler dragging/keyboard shortcut `M` verified only at store level; interactive GUI walkthrough unexecuted. |
| **GAP-09** | AudioToolbox config persistence & secondary Undo | **COMPLETE** | `AudioToolboxStore`, EQ/optimization preset alignment, `Phase50CoreFeatureUndoTests`, and `SmartPresetRegressionTests` pass. | Interactive UI walkthrough manual. |
| **GAP-10** | Video Trim integration (Phase 51) | **PARTIALLY COMPLETE** | [VideoTrimModels.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Media/VideoTrimModels.swift), FFmpeg stream-copy/frame-accurate tests, and `Phase51VideoTrimTests` (`8/8` pass). | Interactive `AVPlayerView` scrubber / filmstrip sheet playback in live GUI unexecuted in XCUITest. |
| **GAP-11** | Watch Folder automation (Phase 52) | **PARTIALLY COMPLETE** | `LocalConvert/Core/WatchFolder/*.swift`, [WatchFoldersSectionView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Presets/WatchFoldersSectionView.swift), [MenuBarView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/MenuBarView.swift), and `Phase52WatchFolderTests` (`10/10` pass, real FSEvents). | Real Finder drag/drop into watched folder, macOS reboot/sleep-wake, and external volume unmount require manual hardware walkthrough. |
| **GAP-12A** | Memory test stability (`Phase422ClosureTests`) | **COMPLETE** | Fixed `vmInfo.internal - volatile` clamping defect & added warmup pass in [Phase422ClosureTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase422ClosureTests.swift#L38-L355); passed `3/3` isolated + `603/603` full suite. | Strict `150 MB` leak threshold intact. |
| **GAP-12B** | Genuine Camera RAW verification | **BLOCKED** | Format registration, host ImageIO UTI check (11/11), and corrupt rejection pass (`Phase53VerificationTests`: `4/5` pass, `1` skipped). | **0 genuine camera RAW sample files** exist in repo (`LOCALCONVERT_RAW_SAMPLES_DIR` not supplied). |

---

## 2. Product Feature Inventory & Completeness Matrix

Evaluated directly against the navigation shell in [ContentView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/ContentView.swift#L16-L120) and [AppState.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState.swift#L98-L124) (`9` primary tabs, toolbar Undo/Redo/Editing History, and `MenuBarView`/`MenuBarManager`).

| Subsystem / Feature Area | UI Entry Point | Key Implementation Files | Classification | Notes & Evidence |
| :--- | :--- | :--- | :---: | :--- |
| **Core Batch Conversion (`Convert`)** | `Convert` tab (`DropZoneView`, `FileListView`, `FileRowView`, `FileOptionsView`) | `AppState.swift`, `ConversionManager.swift`, `ConversionQueue.swift`, `ConversionRegistry.swift` | **COMPLETE** | Supports multi-file queueing, Smart Presets, collision policies, `OutputReservationRegistry`, `OutputCreationUndoCommand`. |
| **Video Trim** | `FileRowView` (`Trim`), `FileOptionsView`, `VideoTrimSheetView` | `VideoTrimModels.swift`, `VideoPreviewService.swift`, `BaseFFmpegProvider.swift` | **PARTIALLY COMPLETE** | Core trim/progress/undo/stream-copy verified (`8/8`); GUI scrubber walkthrough manual. Bundled `ffmpeg`/`ffprobe` target macOS `27.0` (`FINDING-ARCH-01`). |
| **Image Conversion (WebP / JXL / ImageIO / FFmpeg raster)** | `Convert` tab | `ImageConversionEngine.swift`, `WebPEncoder.swift`, `JPEGXLCodec.swift`, `ImageProcessor.swift` | **FRAGILE** | ImageIO/JXL/WebP conversion passes tests, **but** `libwebp.dylib` & `libsharpyuv.dylib` link targeting `minos 27.0` (`FINDING-ARCH-01`), and `Convert` decodes RAW without `CIRAWFilter` (`FINDING-PROD-01`). |
| **Camera RAW Conversion** | `Convert` tab, `Image Toolbox` (`CIRAWFilter` sliders), `Metadata` | `FileFormat.swift:122-132`, `FormatCapabilityRegistry.swift:270-276`, `ImageAdjustmentsEngine.swift:24-90` | **BLOCKED** | 11 RAW types advertised as read-only inputs and UI calls routes "verified" ([SupportedFormatsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/SupportedFormatsView.swift#L29)), yet 0 real camera RAW samples are tested. |
| **PDF Workflows (`PDF Toolbox`)** | `PDF Toolbox` tab | `PDFToolboxEngine.swift`, `PDFConversionEngine.swift`, `PDF*Service.swift` | **COMPLETE** | Page studio, merge/split, compression, OCR, redaction, annotations, forms, archival PDF/A, comparison verified across PDF suites. |
| **Office & Document Workflows** | `Convert` tab | [OfficeConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Office/OfficeConversionEngine.swift#L1052-L1125) | **COMPLETE** | LibreOffice headless (`soffice` `minos 11.0`) + CSV/TSV native `TextConversionEngine`. Runtime download/external packaging needed for public LibreOffice bundle. |
| **Audio Toolbox Pro** | `Audio Toolbox` tab | `AudioToolboxView.swift`, `BaseFFmpegProvider+AudioToolbox.swift`, `SpotifyCompatibilityService.swift` | **COMPLETE** | Trim, waveform, normalize, Spotify compatibility (`3,329`-line service), metadata, `AudioToolboxStore` undo/persistence verified. |
| **Multitrack Audio Editor** | `Audio Toolbox` -> Editor mode | `AudioEditorRootView.swift`, `AudioEditorStore.swift`, `AudioDSPEngine.swift`, `PlaybackEngine.swift` | **PARTIALLY COMPLETE** | DSP/export/markers/undo verified in unit tests; live canvas drag & audio playback hardware UX requires manual verification. |
| **Image Toolbox Pro** | `Image Toolbox` tab | `ImageToolboxView.swift`, `ImageProcessingService.swift`, `ImageToolboxModels.swift` | **PARTIALLY COMPLETE** | Crop, perspective, adjustments, background removal, watermark, DPI/metadata privacy, resize, batch rename, duplicate finder, contact sheet verified; live preview canvas manual. |
| **Metadata Inspector & Editor** | `Metadata` tab | `MetadataView.swift`, `MetadataManager.swift`, `*MetadataProvider.swift` | **PARTIALLY COMPLETE** | Supports Save Copy / Save In-Place + disk undo (`Phase49`), read-only RAW metadata, artwork editor; GUI save panel manual. |
| **Presets & Watch Folders** | `Presets` tab (`Presets` \| `Watch Folders`) | `PresetManager.swift`, `PresetExecutor.swift`, `WatchFolderManager.swift`, `WatchFoldersSectionView.swift` | **PARTIALLY COMPLETE** | CRUD, corruption recovery, FSEvents debouncing, stability checks, loop guards, provenance, and Menu Bar Pause/Resume verified (`10/10`); Finder live workflow manual. |
| **Jobs Center & Queue** | `Jobs` tab | `JobsCenterView.swift`, `ConversionManager.swift`, `ConversionQueue.swift` | **COMPLETE** | Session job batching, progress, cancellation, retry/clear. |
| **History & Editing History** | `History` tab + Toolbar `Editing History` popover | `HistoryManager.swift`, `HistoryView.swift`, `UndoRedoCoordinator.swift`, `EditingHistoryView.swift` | **FRAGILE** | `HistoryManager.shared` cannot be isolated during unit tests (`FINDING-ARCH-04`), and users face three overlapping activity/history surfaces (`FINDING-PROD-02`). |
| **Settings & Theme** | `Settings` tab + Menu Bar | `SettingsView.swift`, `AppSettings.swift`, `DesignSystem.swift` | **COMPLETE** | System/Light/Dark transition sync, `rememberLastUsedOptions`, `verboseLogging`, Dock/MenuBar modes verified. |
| **Archives & Subtitles** | `Convert` tab | `ArchiveConversionEngine.swift`, `SubtitleConversionEngine.swift` | **FRAGILE** | Archives use `/usr/bin/bsdtar`/`gzip`/`bzip2`; `.rar` listed as input ([ArchiveConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Archive/ArchiveConversionEngine.swift#L17)) depending on host `libarchive` RAR support. |

---

## 3. Evidence-Based Format Capability & Verification Matrix

This matrix separates **Extension/Magic Detection**, **Encoding/Decoding Code Path**, **Metadata Handling**, and **Real Test Verification Evidence**.

| Format Family | Registered Cases | Detection | Read Code Path | Write Code Path | Metadata Write | Genuine Sample Test Evidence |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Raster Standard** | `.jpg`, `.png`, `.heic`, `.tiff`, `.bmp`, `.gif`, `.apng`, `.avif`, `.jp2`, `.psd`, `.exr`, `.tga`, `.ico`, `.icns`, `.sgi`, `.ppm`, `.hdr` | Magic bytes + UTI | ImageIO / NSImage / `CGImageSource` | ImageIO / `CGImageDestination` / FFmpeg (`.apng`, `.hdr`, etc.) | Read/Write for JPEG/PNG/TIFF/HEIC (`ImageMetadataProvider.swift`); AVIF pixel rewrite | **VERIFIED** (synthetic/generated binary fixtures across `Phase23`–`Phase52`, `Phase422` 50/100 MP) |
| **WebP** | `.webp` | RIFF/`WEBP` header | `CGImageSource` | Bundled `libwebp.dylib` (`WebPEncoder.swift`) | Chunk rewrite via ImageIO / limited viewer DPI | **PARTIALLY VERIFIED** (`Phase422` & `Phase52` pass on `macOS 26/27` host, **but** `libwebp.dylib` built for `minos 27.0`) |
| **JPEG XL** | `.jxl` | `JXL` codestream / container box | Bundled static `libjxl.a` (`JPEGXLCodec.swift`) | Static `libjxl.a` (`minos 15.0`); lossless JPEG transcode | Container box rewrite (`Exif`, `xml`) | **VERIFIED** (native `arm64` `minos 15.0`, EXIF/XMP/ICC & JPEG transcode tested in `Phase49` / JXL suites) |
| **Specialized FFmpeg Raster** | `.qoi`, `.pcx`, `.wbmp`, `.xpm` | Extension / headers | Bundled `ffmpeg` -> temp PNG (`ImageConversionEngine.swift:360-377`) | Bundled `ffmpeg` (except `.xpm` read-only) | Limited / omitted | **PARTIALLY VERIFIED** (tested synthetically; gated on `ffmpeg` `minos 27.0` issue) |
| **Vector** | `.svg` | XML/SVG tag | `NSImage` rasterization (`ImageConversionEngine.swift:337-359`) | Read-only (raster targets / PDF) | Read-only basic | **VERIFIED** (`ImageSVGOptimizerService`, SVG rasterization tests) |
| **Camera RAW** | `.dng`, `.cr2`, `.cr3`, `.nef`, `.nrw`, `.arw`, `.raf`, `.rw2`, `.orf`, `.pef`, `.srw` (+12 `.dng` aliases) | `crx` ISOBMFF for `.cr3`; TIFF/ORF magic + ext hint for others (`FileDetector.swift:206-274`) | Dual path: **plain `CGImageSource`** in `ImageConversionEngine.swift:396`; **`CIRAWFilter` + ImageIO fallback** in `ImageAdjustmentsEngine.swift` / `ImageProcessingService.swift` | Read-only (`canWrite = false`) | Read-only (`ImageMetadataProvider.swift:29-43`) | **BLOCKED** — Host UTI registered (11/11), corrupt inputs fail cleanly (11/11), **0 real sensor RAW files tested** |
| **Audio (Writable)** | `.mp3`, `.wav`, `.flac`, `.m4a`, `.m4b`, `.aac`, `.ogg`, `.opus`, `.aiff`, `.caf`, `.alac`, `.ac3`, `.eac3`, `.dts`, `.wma`, `.au`, `.wv`, `.mka` | Magic/RIFF/ISOBMFF/EBML | Bundled `ffmpeg 9.0.2` / `AVFoundation` | Bundled `ffmpeg` (`--enable-videotoolbox --enable-audiotoolbox --enable-libmp3lame --enable-libopus --enable-libvpx`) | `AudioMetadataProvider` (via FFmpeg / MP4 atoms) | **PARTIALLY VERIFIED** (`MediaConversionEngine`, `SmartPresetRegressionTests`, `AudioToolbox` pass on host; `ffmpeg` `minos 27.0` risk on macOS 15) |
| **Audio (Read-Only)** | `.amr`, `.ape` | Extension/header | Bundled `ffmpeg` | Read-only | Limited | Code inspection; not primary regression targets |
| **Video (Writable)** | `.mp4`, `.mov`, `.mkv`, `.webm`, `.avi`, `.wmv`, `.asf`, `.m4v`, `.3gp`, `.3g2`, `.mpg`, `.ts`, `.flv`, `.f4v`, `.vob`, `.m2v` | ISOBMFF/EBML/ASF/MPEG | Bundled `ffmpeg` | Bundled `ffmpeg` + VideoToolbox / libvpx | `VideoMetadataProvider` | **PARTIALLY VERIFIED** (`Phase51VideoTrimTests`, `Phase422` covr pass; `ffmpeg` `minos 27.0` risk on macOS 15) |
| **Video (Read-Only)** | `.mts`, `.m2ts`, `.ogv` | Sync byte / Ogg | Bundled `ffmpeg` | Read-only | Read-only | Code inspection |
| **Subtitles** | `.srt`, `.vtt`, `.ass`, `.ssa` (+ `.sub` input, `.sup` listed in enum) | Text / extension | Text/FFmpeg (`SubtitleConversionEngine.swift:12-27`) | Bundled `ffmpeg` (`srt`, `vtt`, `ass`, `ssa`; excludes `.sub` write & `.sup`) | N/A | Code inspection + `ConversionRegistry` |
| **PDF & Documents** | `.pdf`, `.docx`, `.doc`, `.dotx`, `.docm`, `.xlsx`, `.xls`, `.xltx`, `.xlsm`, `.xlsb`, `.pptx`, `.ppt`, `.potx`, `.pptm`, `.ppsx`, `.pps`, `.odt`, `.ods`, `.odp`, `.rtf`, `.csv`, `.tsv`, `.txt`, `.md`, `.html`, `.epub` | PDF/ZIP/OLE/text | `PDFKit`, `OfficeConversionEngine` (LibreOffice 26.8), `TextConversionEngine` (CSV/TSV) | `PDFKit`, LibreOffice headless, `TextConversionEngine` | `PDFMetadataProvider`, `OfficeMetadataProvider` | **VERIFIED** (`Phase32` Office routes, `PDF*` suites, `Phase49` PDF Undo) |
| **Archives** | `.zip`, `.tar`, `.gz`, `.tgz`, `.tbz2`, `.txz`, `.7z`, `.bz2`, **`.rar` (read-only)** | GZip/BZip2/XZ/`ustar`/ZIP | `/usr/bin/bsdtar`, `gzip`, `bzip2` (`maxArchiveEntries=10_000`, `2 GB` limit) | Same except `.rar` excluded from outputs | N/A | Traversal/symlink tests in hardening phase; `.rar` host `libarchive` coverage unverified |

---

## 4. Key Product, UX & Accessibility Findings

### `FINDING-PROD-01` (`P1` — Misleading RAW "Verified Routes" Copy & `Convert` vs. `ImageToolbox` RAW Path Divergence)
- **Affected Subsystem:** Format Matrix UI (`SupportedFormatsView`), RAW Conversion (`ImageConversionEngine`, `ImageProcessingService`)
- **Evidence (Verified Facts):**
  1. [SupportedFormatsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/SupportedFormatsView.swift#L29) displays `"\(FileFormat.allCases.count) formats registered · \(ConversionMatrix.snapshot().totalRoutes) verified conversion routes"`, counting all 11 declared `.isRawImage` types (`× 23` image targets = `253` theoretical routes) despite **0 genuine camera RAW sample files** verified ([Phase53VerificationTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase53VerificationTests.swift#L168-L172)).
  2. [ImageConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift#L396-L420) decodes RAW files in `Convert` / Presets / Watch Folders solely through plain `CGImageSourceCreateWithURL` (`kCGImageSourceShouldCache: false`), whereas [ImageProcessingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageProcessingService.swift#L112-L164) and [ImageAdjustmentsEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageAdjustmentsEngine.swift#L24-L90) use `CIRAWFilter` plus explicit TIFF-hint fallback (`ImageProcessingService.swift:253-264`).
- **Actual Impact:** Users converting Camera RAW in `Convert` or `Watch Folders` receive different decoding/color behavior than in `Image Toolbox` (no `CIRAWFilter` demosaicing or TIFF-wrapped DNG retry), and the Formats sheet overstates verification certainty.
- **Recommended Action:** Relabel `"verified conversion routes"` to `"supported conversion routes"` with an explicit `"macOS ImageIO (depends on OS RAW support)"` note on RAW entries, and align `Convert` RAW decoding with `CIRAWFilter` fallback or gate RAW claims strictly on verified camera formats.
- **Dependencies:** User-provided genuine RAW fixtures (`LOCALCONVERT_RAW_SAMPLES_DIR`).
- **Confidence Level:** High (100% observed in code).

### `FINDING-PROD-02` (`P2` — Fragmented Three-Way Activity / Jobs / Editing History Mental Model)
- **Affected Subsystem:** `Jobs`, `History`, Toolbar `Editing History`, `Presets -> Watch Folders`
- **Evidence (Verified Facts):**
  1. `Jobs` ([JobsCenterView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Jobs/JobsCenterView.swift#L13-L24)) displays in-memory session active/completed/failed `ConversionJob`s (`ConversionManager`).
  2. `History` ([HistoryView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/History/HistoryView.swift#L27-L44)) displays persisted 500-entry `history.json` (`HistoryManager.shared`), grouping Watch Folder runs under `.presets` because `PresetExecutor` sets `job.presetName`.
  3. Toolbar `Editing History` ([ContentView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/ContentView.swift#L48-L59)) displays `UndoRedoCoordinator`'s Undo/Redo stack (`EditingHistoryView.swift`).
  4. `Presets -> Watch Folders` ([WatchFoldersSectionView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Presets/WatchFoldersSectionView.swift#L382-L420)) maintains a fourth per-rule `Recent File Activity` feed (`watch_folders.json`).
- **Actual Impact:** Users must look in different places depending on whether they want live progress (`Jobs`), past Watch Folder runs (`Watch Folders` vs. `History -> Presets`), or reverting file writes (`Editing History` popover instead of `History` tab).
- **Recommended Action:** Keep storage separated cleanly, but clarify labels/filtering (`History` can expose a dedicated Watch Folder filter or deep link to Undo where applicable) without adding new top-level tabs.
- **Dependencies:** None.
- **Confidence Level:** High (observed across views).

### `FINDING-PROD-03` (`P2` — Divergent Metadata Copy/Undo UX Between `Metadata` Tab and `Image Toolbox`)
- **Affected Subsystem:** `MetadataView` / `AudioToolboxView` vs. `ImageToolbox` Privacy Cleaner
- **Evidence (Verified Facts):**
  - Top-level `MetadataView` ([MetadataView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Metadata/MetadataView.swift#L191-L231)) and `AudioToolboxView` route through `MetadataManager.saveCopy(...)` (defaulting to `<name>_tagged.<ext>`) and `MetadataManager.saveInPlace(...)` backed by `MetadataFileWriteUndoCommand` in `.metadata`.
  - `ImageMetadataPrivacyView` ([ImageMetadataPrivacyView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImageMetadataPrivacyView.swift#L207-L229)) routes through `ImageToolboxView.saveMetadataInPlaceOrCopy` -> `ImageMetadataInspectorService.writeMetadataAndDPINonDestructively` (`CGImageDestinationCopyImageSource` lossless path + `ImageMetadataService.writePrivacyCleaned` fallback), recording `ImageFileWriteUndoCommand` in `.imageToolbox`.
- **Inference:** While both paths are safe (both stage pre-write bytes into `RecoveryArtifactManager` before in-place overwrite and default/encourage non-destructive Save Copy), their UX naming (`"Save Privacy-Cleaned Copy..."` / `"_clean"` vs. `"Save Copy..."` / `"_tagged"`), underlying `UndoOperationType`, and DPI/lossless CopyImageSource capabilities differ.
- **Recommended Action:** Unify UX copy conventions and share the `CGImageDestinationCopyImageSource` lossless helper where appropriate (`GAP` follow-up P1/P2).
- **Confidence Level:** High.

### `FINDING-PROD-04` (`P2` — Unverified Interactive GUI & OS Hardware Flows Across Phases 49–52)
- **Affected Subsystem:** `LocalConvertTests` (XCUITest absence)
- **Evidence (Verified Facts):** Repository contains `5` XCTest unit/integration classes and `77` Swift Testing suites (`603` tests), `0` XCUITest suites. Accessibility inspection shows `280` `.accessibilityLabel`/`.accessibilityHint` annotations across `LocalConvert/Features/` and `DesignSystem`/`AppTheme` tokens applied cleanly.
- **Actual Impact:** Store/engine/view-model logic is well-tested, but SwiftUI gesture sheets (`VideoTrimSheetView` AVPlayer scrubbing, Audio Editor marker dragging, Finder Watch Folder drops, `NSOpenPanel`/`NSSavePanel` sheet flows, Light/Dark/System live transition visually) depend on manual verification.
- **Recommended Action:** Add a minimal, non-flaky XCUITest UI smoke target or formal release manual checklist sign-off before shipping `1.0.0`.
- **Confidence Level:** High.

---

## 5. Product Strengths & Weaknesses Summary

- **Strengths:** Completely offline-first architecture; rich native macOS toolset (Video Trim with stream-copy/frame-accurate toggle, Image Toolbox Pro with `CIRAWFilter` + lossless JXL/WebP, PDF Pro Suite with OCR/Redaction/Archival/Forms, Audio Toolbox + Multitrack DSP Editor, automated FSEvents Watch Folders); pervasive data-safety guardrails (atomic writes, source preservation, `OutputReservationRegistry`, `RecoveryArtifactManager` global Undo/Redo); consistent `AppTheme`/`DesignSystem` and strong VoiceOver instrumentation (`280` accessibility markers).
- **Weaknesses:** Bundled binary deployment target mismatch (`minos 27.0` on `libwebp`/`libsharpyuv`/`ffmpeg`/`ffprobe` — P0 portability issue covered in Architecture Audit); unverified real-camera RAW matrix presented as "verified" in UI; fragmented Image Metadata / History UX; manual GUI smoke checks unautomated.
