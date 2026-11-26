# LocalConvert — Phase 54 Architecture Audit

**Date:** 2026-11-22  
**Auditor Role:** Senior Software Architect & Product Auditor (Audit-Only Phase)  
**Repository:** `/Users/cancan/Desktop/LocalConvert/` (`RighteousLife/LocalConvert`)  
**Target (`project.yml`):** macOS `15.0+`, `arm64`, Swift `6.0`, `SWIFT_STRICT_CONCURRENCY: complete`  

---

## 1. Architecture Overview & Codebase Scale

Verified direct repository measurements:
- **Production Swift files (`LocalConvert/`):** `190` files (`82,703` total lines).
- **Test Swift files (`LocalConvertTests/`):** `62` files (`5` `XCTestCase` classes with `37` tests; `77` Swift Testing `@Suite` declarations with `603` `@Test` functions).
- **Three-Layer Modular Layout:**
  1. **Presentation (`LocalConvert/Features/` + `DesignSystem.swift`):** SwiftUI views organized across 11 feature folders (`Conversion`, `Jobs`, `PDFToolbox`, `AudioToolbox`, `AudioEditor`, `ImageToolbox`, `Metadata`, `Presets`, `History`, `Home`, `Shared`).
  2. **Application & Core Coordination (`LocalConvert/App/` + `LocalConvert/Core/`):** `AppState` (hub coordinator split across `AppState.swift` + 3 extensions), `AppLifecycleManager`, `ConversionManager`, `ConversionQueue`, `ConversionRegistry`, `FileDetector`, `FormatCapabilityRegistry`, `OutputManager`, `PresetManager`, `PresetExecutor`, `WatchFolderManager`, `MetadataManager`, `UndoRedoCoordinator`, `HistoryManager`, `AppSettings`.
  3. **Domain Engines & Infrastructure (`LocalConvert/Engines/` + `Frameworks/` + `Resources/`):** `ImageConversionEngine`, `MediaConversionEngine`, `OfficeConversionEngine`, `PDFConversionEngine`, `PDFToolboxEngine`, `ArchiveConversionEngine`, `SubtitleConversionEngine`, `TextConversionEngine`, plus Audio Editor DSP/playback/export services, WebP/JXL native bridges, and bundled `ffmpeg` / `ffprobe` / `LibreOffice`.

**Coherence Verdict:** The overall architecture is **cohesive**. Additions in Phases 49–52 properly extended existing abstractions (`PresetExecutor`, `ConversionQueue`, `OutputReservationRegistry`, `UndoRedoCoordinator`, `RecoveryArtifactManager`) rather than duplicating parallel pipelines. However, audit inspection uncovered **one P0 binary distribution defect**, several **singleton/test-isolation gaps**, **god-file scaling pressure**, and **localized image-metadata duplication**.

---

## 2. Critical & Significant Architectural Findings

### `FINDING-ARCH-01` (`P0` — Bundled Binary Deployment Target Mismatch: `minos 27.0` vs. App Target `15.0`)
- **Affected Subsystem:** Bundled Codecs & Media Subprocesses (`Frameworks/libwebp.dylib`, `Frameworks/libsharpyuv.dylib`, `Resources/ffmpeg/ffmpeg`, `Resources/ffmpeg/ffprobe`)
- **Evidence (Verified Facts):**
  - [project.yml](file:///Users/cancan/Desktop/LocalConvert/project.yml#L4-L16) sets `deploymentTarget.macOS: "15.0"` and `MACOSX_DEPLOYMENT_TARGET: "15.0"`.
  - Clean `arm64` `xcodebuild` output emits linker warnings:
    `ld: warning: building for macOS-15.0, but linking with dylib '@rpath/libwebp.dylib' which was built for newer version 27.0` (and likewise for `@rpath/libsharpyuv.dylib`).
  - `otool -l` inspection directly confirms `LC_BUILD_VERSION` minimum OS (`minos`):
    - `LocalConvert/Frameworks/libwebp.dylib`: `arm64`, **`minos 27.0`**
    - `LocalConvert/Frameworks/libsharpyuv.dylib`: `arm64`, **`minos 27.0`**
    - `LocalConvert/Resources/ffmpeg/ffmpeg` (`ffmpeg 9.0.2`): `arm64`, **`minos 27.0`**
    - `LocalConvert/Resources/ffmpeg/ffprobe` (`9.0.2`): `arm64`, **`minos 27.0`**
    - By contrast, `LocalConvert/Frameworks/libjxl.a` has **`minos 15.0`**, and `LocalConvert/Resources/LibreOffice/Contents/MacOS/soffice` has **`minos 11.0`**.
- **Actual Impact:** While these binaries execute on the current macOS 27.x development host, dyld (`LC_BUILD_VERSION minos 27.0`) and AppKit/dyld dynamic linking on actual **macOS 15.0 (Sequoia)** or **macOS 26.x (Tahoe)** user machines can refuse to load `libwebp.dylib`/`libsharpyuv.dylib` at app launch (causing immediate `dyld` crash on launch!) or fail to execute `ffmpeg`/`ffprobe` (`posix_spawn` / minimum OS check failure).
- **Recommended Action:** Rebuild `libwebp.dylib`, `libsharpyuv.dylib`, `ffmpeg`, and `ffprobe` for `arm64-apple-macos15.0` (`-mmacosx-version-min=15.0` / `MACOSX_DEPLOYMENT_TARGET=15.0`) and add an automated `otool -l` `minos <= 15.0` assertion into release packaging/verification scripts before any public 1.0.0 release.
- **Dependencies:** Upstream static/dylib build toolchain for `libwebp` 1.6.0 and `ffmpeg` 9.0.2 (without altering licensing — keeping LGPLv3+ / BSD-3-Clause boundaries).
- **Confidence Level:** High (`100%` verified via `otool -l` and `ld` output).

---

### `FINDING-ARCH-02` (`P1` — Overlapping Image Metadata Inspection/Sanitization Implementations)
- **Affected Subsystem:** Image Metadata & Privacy Pipelines
- **Evidence (Verified Facts):**
  Three separate image metadata modules coexist (`1,192` lines combined):
  1. [ImageMetadataProvider.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/Providers/ImageMetadataProvider.swift#L7-L120) (`422` lines) — implements `MetadataProvider` for `MetadataManager` (used by `MetadataView`).
  2. [ImageMetadataService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageMetadataService.swift#L23-L150) (`254` lines) — provides `inspect(url:)`, `writePrivacyCleaned(url:payload:)`, and `applyPolicyToProperties` delegating back to a private `ImageMetadataProvider()`.
  3. [ImageMetadataInspectorService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageMetadataInspectorService.swift#L256-L380) (`516` lines) — implements detailed tag inspection, `previewDiff`, `writeMetadataAndDPINonDestructively` (using `CGImageDestinationCopyImageSource` for lossless JPEG/PNG/TIFF/HEIC or fallback to `ImageMetadataService.writePrivacyCleaned` for JXL/WebP/others).
- **Actual Impact:** Duplicate tag parsing dictionaries and separate metadata-write undo paths (`MetadataFileWriteUndoCommand` vs. `ImageFileWriteUndoCommand`) raise maintenance cost whenever adding format-specific EXIF/XMP/ICC edge cases. (Note: Both paths properly use `RecoveryArtifactManager` staging when called from UI.)
- **Recommended Action:** Consolidate shared tag extraction and reuse `CGImageDestinationCopyImageSource` lossless helper across both `ImageMetadataProvider` and `ImageMetadataInspectorService`.
- **Dependencies:** `Phase49` metadata tests (`Phase49DataSafetyAndUndoTests`), `Phase37ImageToolboxCompletionTests`.
- **Confidence Level:** High.

---

### `FINDING-ARCH-03` (`P2` — Entitlements vs. Security-Scoped Bookmark Posture)
- **Affected Subsystem:** Sandboxing, Bookmarks (`WatchFolderBookmarkManager`), Distribution
- **Evidence (Verified Facts):**
  - [LocalConvert.entitlements](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/LocalConvert.entitlements) contains only `<key>com.apple.security.cs.disable-library-validation</key><true/>` (`app-sandbox` is **not** enabled).
  - [WatchFolderStore.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/WatchFolder/WatchFolderStore.swift#L15-L52) attempts `url.bookmarkData(options: [.withSecurityScope])` with fallback to `options: []` because security-scoped bookmarks require entitlements / App Sandbox guarantees that vary by signing configuration.
- **Inference & Impact:** For direct DMG / Developer ID distribution (non-App-Store), direct POSIX access works alongside `bookmarkData(options: [])` fallback, while `disable-library-validation` is present for bundled dylib/LibreOffice loading. However, if Mac App Store distribution were ever targeted, every subprocess (`ffmpeg`, `ffprobe`, headless `LibreOffice`, `/usr/bin/bsdtar`) and Watch Folder would require full `app-sandbox` entitlement re-architecture.
- **Recommended Action:** Document direct Developer ID notarized DMG as the supported distribution channel unless App Sandbox migration is explicitly planned; confirm hardened-runtime `disable-library-validation` necessity vs. Team-ID re-signing of all bundled Mach-O dylibs.
- **Dependencies:** Release signing scripts (`scripts/package-release.sh`).
- **Confidence Level:** High.

---

### `FINDING-ARCH-04` (`P1` — Singleton Proliferation & `HistoryManager.shared` Test Isolation Gap)
- **Affected Subsystem:** Application Persistence & Testing Isolation (`HistoryManager`, `23` `static let shared` singletons)
- **Evidence (Verified Facts):**
  - Static scan counts `23` `static let shared` singletons across `LocalConvert/`.
  - While newer stores cleanly support dependency injection (`PresetStore(fileURL:)`, `WatchFolderStore(fileURL:)`, `UndoRedoCoordinator(journalDirectoryURL:artifactManager:...)`, `RecoveryArtifactManager(baseDirectoryURL:)`, and `AppState(undoCoordinator:watchFolderStoreURL:)`), [HistoryManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/History/HistoryManager.swift#L6-L25) declares `private init()` hardcoded to `applicationSupportDirectory/<bundleID>/history.json`.
  - [ConversionManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Conversion/ConversionManager.swift#L896) and [MetadataManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/MetadataManager.swift#L269,L404) call `HistoryManager.shared.addEntry(historyItem)` unconditionally during normal and test executions.
- **Actual Impact:** Running unit/integration tests that instantiate `ConversionManager` or `MetadataManager` (including `Phase49`, `Phase51`, `Phase52`, `SmartPresetRegressionTests`) mutates the real user's Application Support `history.json` on disk.
- **Recommended Action:** Refactor `HistoryManager` to expose `init(fileURL: URL? = nil)` (just like `PresetStore` and `WatchFolderStore`), inject `HistoryManager` into `ConversionManager`/`MetadataManager` with `.shared` default, and redirect test harnesses to temp sandboxes.
- **Dependencies:** `ConversionManager`, `MetadataManager`, test helpers.
- **Confidence Level:** High (`100%` verified).

---

### `FINDING-ARCH-05` (`P1` — Dual Camera RAW Decoding Pipeline Between `Convert` and `Image Toolbox`)
- **Affected Subsystem:** `ImageConversionEngine` vs. `ImageProcessingService` / `ImageAdjustmentsEngine`
- **Evidence (Verified Facts):**
  - `ImageConversionEngine.swift:396-420` decodes all RAW formats (`dng`, `cr2`, `cr3`, `nef`, `nrw`, `arw`, `raf`, `rw2`, `orf`, `pef`, `srw`) via plain `CGImageSourceCreateWithURL` (`kCGImageSourceShouldCache: false`) unless routed from `Image Toolbox` (`options.customOptions["image_toolbox"] == "true"`, line 146).
  - `ImageProcessingService.swift:112-164, 253-264` attempts `ImageAdjustmentsEngine.loadWithCIRAWFilter(url:config:scaleFactor:)` first, then falls back to `CGImageSource`, plus retries TIFF-wrapped DNGs with `kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier` when ImageIO's RAW plugin fails.
- **Actual Impact:** Batch/Watch Folder/Preset RAW conversions lack `CIRAWFilter` demosaicing and TIFF-wrapped DNG fallback available in Image Toolbox.
- **Recommended Action:** Evaluate with genuine camera RAW samples (`LOCALCONVERT_RAW_SAMPLES_DIR`) whether `ImageConversionEngine` should share `ImageProcessingService` / `ImageAdjustmentsEngine.loadWithCIRAWFilter` (with `CGImageSource` + TIFF-hint fallback).
- **Dependencies:** `GAP-12B` genuine RAW sample testing.
- **Confidence Level:** High.

---

### `FINDING-ARCH-06` (`P2` — Extreme File Size / Complexity Hotspots ("God Files"))
- **Affected Subsystem:** Image, AudioToolbox, PDF, Office, Core Coordination
- **Evidence (Verified Facts — `wc -l`):**
  - `LocalConvert/Engines/AudioToolbox/SpotifyCompatibilityService.swift`: **3,329 lines**
  - `LocalConvert/Features/ImageToolbox/ImageToolboxOperationsViews.swift`: **1,365 lines**
  - `LocalConvert/Features/PDFToolbox/PDFAnnotationStudioView.swift`: **1,208 lines**
  - `LocalConvert/Engines/Image/ImageProcessingService.swift`: **1,200 lines**
  - `LocalConvert/Features/ImageToolbox/ImageCropEditorView.swift`: **1,198 lines**
  - `LocalConvert/Engines/Office/OfficeConversionEngine.swift`: **1,194 lines**
  - `LocalConvert/Engines/PDF/PDFDocumentInspector.swift`: **1,188 lines**
  - `LocalConvert/App/AppState.swift`: **1,163 lines**
  - `LocalConvert/Core/Conversion/ConversionManager.swift`: **1,159 lines**
- **Actual Impact:** Increases merge-conflict surface, compile times, and review difficulty when changing Audio/Image/PDF features; does not immediately break runtime behavior today.
- **Recommended Action:** Decompose only incrementally when editing those files (avoid broad speculative refactoring); start with splitting `SpotifyCompatibilityService.swift` (3,329 lines) into dedicated analyzer/normalizer/preset files only if AudioToolbox undergoes future changes.
- **Confidence Level:** High.

---

## 3. Concurrency, Lifecycle & File-System Safety Assessment

- **Swift 6 Concurrency:** `SWIFT_STRICT_CONCURRENCY: complete` builds cleanly with **0 concurrency warnings** across all `190` app files and `62` test files.
- **Unsafe / Escape-Hatch Inventory:** `46` `@unchecked Sendable` types (primarily engine singletons/providers wrapping immutable config or locking internals, `WatchFolderMonitor` wrapping non-Sendable `FSEventStreamRef` under `NSLock`), `26` `Task.detached` call sites (bounded for heavy decoding/scanning/stability polling), and `6` `DispatchQueue` usages (`WatchFolderMonitor` private serial FSEvents queue, etc.).
- **Lifecycle Boundaries:** `AppLifecycleManager.prepareForTermination(appState:)` stops Watch Folder monitors (`stopAll()`), cancels `conversionQueue`, flushes `UndoRedoCoordinator`, and removes `FileManager.default.temporaryDirectory` app scratch entries (`AppLifecycleManager.swift:225-232`). Sleep/wake and mount/unmount notifications trigger `WatchFolderManager.handleSystemWakeOrVolumeChange()`.
- **File-System Safety:**
  - Non-destructive collision reservation via `ConversionManager.OutputReservationRegistry` (`ConversionManager.swift:538`), atomic writes, and sibling `_copy` / `_tagged` / `_trimmed` / `Converted/` defaults prevent overwriting sources.
  - Archive extraction/repacking enforces `10,000` entry limit, `2 GB` bomb guard, and symlink/traversal checks (`ArchiveConversionEngine.swift:12-14`).
  - Watch Folders enforce `WatchFolderValidator` loop rejection, `<Watched>/<Subfolder>` prefix exclusion, and `knownGeneratedOutputPaths` / `knownGeneratedResourceIDs` provenance guards (`WatchFolderManager.swift`).

---

## 4. Bundled Third-Party Codecs, Tools & Licensing Assessment

| Component | Version & Location | Arch / MinOS | License (`THIRD_PARTY_NOTICES.md`) | Risk / Observation |
| :--- | :--- | :--- | :--- | :--- |
| `libwebp.dylib` & `libsharpyuv.dylib` | 1.6.0 / 0.1.2 (`LocalConvert/Frameworks/`) | `arm64`, **`minos 27.0`** | BSD 3-Clause (`LICENSE.webp`) | **P0:** Must be rebuilt for `minos 15.0` to run on macOS 15/26. |
| `libjxl.a` (+ `hwy`, `brotli`, `cms`, `threads`) | 0.13.0 (`LocalConvert/Frameworks/`) | `arm64`, `minos 15.0` | BSD 3-Clause / MIT / Apache-2.0 (`LICENSE.jxl`) | Properly matched to `15.0` deployment target. |
| `ffmpeg` & `ffprobe` | 9.0.2 (`LocalConvert/Resources/ffmpeg/`) | `arm64`, **`minos 27.0`** | **LGPLv3+** (`--enable-version3`, no GPL/nonfree; `FFmpeg-LICENSE.txt`) | **P0:** Built for `minos 27.0`; must rebuild for `minos 15.0`. Licensing cleanly avoids GPL (`libx264`/`x265` disabled). |
| LibreOffice Headless | 26.8.0.3 (`LocalConvert/Resources/LibreOffice/`) | `arm64`, `minos 11.0` | **MPL 2.0** (separate process `soffice`, notices + Python PSF + Poppler GPLv2 cited) | Clean process isolation (`OfficeConversionEngine`); ~720 MB footprint distributed separately for releases. |

---

## 5. Test Infrastructure Assessment (`FINDING-TEST-01`, `FINDING-TEST-02`)

### Positive Strengths
- `603/603` Swift Testing tests across `77` suites and `36/36` non-blocked XCTests across `5` XCTest classes (`1` explicit `BLOCKED` skip for genuine RAW samples) pass reliably after Phase 53 hardening.
- Isolated temp directories (`UUID`-scoped folders in `FileManager.default.temporaryDirectory`) used consistently in Phases 49–53, along with isolated `PresetStore`, `WatchFolderStore`, `RecoveryArtifactManager`, and `UndoRedoCoordinator`.
- Phase 53 fix to [Phase422ClosureTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase422ClosureTests.swift#L38-L355) preserves strict `<= +150.0 MB` regression detection on `phys_footprint` and `graphicsMB` after warmup while eliminating false `VM_PURGEABLE_VOLATILE` failures across 3/3 isolated runs and full 77-suite execution.

### Test Infrastructure Gaps
- **`FINDING-TEST-01` (`P1` — `HistoryManager.shared` Pollution During Tests):** Tests exercising `ConversionManager` / `MetadataManager` implicitly append entries to `~/Library/Application Support/<bundleID>/history.json` because `HistoryManager` lacks an injectable `fileURL` (`HistoryManager.swift:14-25`).
- **`FINDING-TEST-02` (`P2` — Zero Automated UI / XCUITest Coverage):** SwiftUI dialogs, accessibility focus, drag-and-drop visual state transitions, Video Trim player scrubbing, and Audio Editor ruler dragging have no XCUITest smoke target.
- **Unverified RAW Fixtures:** Only 1 intentional skip condition (`testGenuineCameraRAWSamplesIfProvided`) exists across all test files (plus FFmpeg-availability defensive skip in `Phase51VideoTrimTests.swift:37` which did not trigger because `ffmpeg` is bundled).

---

## 6. Technical Debt & Pre-Existing Compiler Warning Register

| ID | Sev | Location & Evidence | Category | Impact & Recommended Disposition |
| :--- | :---: | :--- | :--- | :--- |
| `DEBT-01` | **P0** | `Frameworks/libwebp.dylib`, `libsharpyuv.dylib`, `Resources/ffmpeg/{ffmpeg,ffprobe}` (`otool -l` -> `minos 27.0`) | Binary Deployment Target | Fails/risks dyld/exec rejection on macOS 15–26. Rebuild targeting `15.0`. |
| `DEBT-02` | **P1** | `HistoryManager.swift:6-25`, `ConversionManager.swift:896`, `MetadataManager.swift:269,404` | Test Isolation / Singleton | Pollutes user `history.json` during tests. Inject `fileURL`. |
| `DEBT-03` | **P1** | `ImageMetadataProvider.swift`, `ImageMetadataService.swift`, `ImageMetadataInspectorService.swift` | Duplicate Logic | Three overlapping image metadata modules; consolidate shared inspection & lossless CopyImageSource. |
| `DEBT-04` | **P1** | `ImageConversionEngine.swift:396` vs `ImageProcessingService.swift:112`, `SupportedFormatsView.swift:29` | RAW Pipeline & UI Accuracy | Align `CIRAWFilter` usage or relabel UI until genuine RAW samples pass. |
| `DEBT-05` | **P2** | `PDFRedactionView.swift:296,305,313`, `PDFToolboxView.swift:199,202`, `PDFFormsView.swift:163`, `PDFInspectorSecurityView.swift:83,86`, `PDFAnnotationStudioView.swift:103,108`, `PDFCompareView.swift:209` (`onChange(of:perform:)`); `JPEGXLCodec.swift:856` (`init(cString:)`) | Deprecation Warnings (`12` total) | Clean pre-existing macOS 14/Swift 6 deprecations when touching views/codecs. |
| `DEBT-06` | **P2** | `PDFInspectorSecurityView.swift:292`, `AudioAnalysisService.swift:253`, `ImageMetadataService.swift:127`, `ImageProcessingService.swift:639`, `ImageProcessor.swift:325`, `JXLBridge.mm:45` | Unused Variables / Precision (`6` warnings) | Low-risk compiler warning cleanup. |
| `DEBT-07` | **P2** | `project.yml:140-186` (`Copy Bundled Binaries and Runtime` phase lacks `outputFileListPaths`/outputs) | Build Performance | Forces Xcode script re-run on every incremental build. |
| `DEBT-08` | **P2** | `SpotifyCompatibilityService.swift` (`3,329` lines) + 8 other files `> 1,050` lines; `debug-deployment/` untracked dir | Code Scale & Repo Hygiene | Split monotonically on future edits; clean/ignore scratch root artifacts. |
