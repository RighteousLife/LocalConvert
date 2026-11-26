# LocalConvert — Phase 54 Final Architecture & Development Roadmap

**Date:** 2026-11-22  
**Audit Scope:** Complete product, architecture, binary, format, UX, and test infrastructure evaluation after Phases 48–53  
**Authorization Status:** Audit-only; **Phase 55+ implementation awaits explicit user authorization.**

---

## 1. Executive Summary & Current Readiness

LocalConvert is an architecturally cohesive, offline-first macOS desktop media & document workstation (`82,703` lines of Swift 6 code across `190` files, `603` Swift Testing tests across `77` suites, and `37` XCTests across `5` classes with `0` active failures and `0` Swift 6 strict-concurrency warnings). Phases 49–53 closed all data-safety undo gaps (`GAP-01`–`GAP-09`), added Video Trim (`GAP-10`) and FSEvents Watch Folders (`GAP-11`), and resolved the long-standing `Phase422ClosureTests` `50 MP / 100 MP` memory-test instability (`GAP-12A`).

However, two critical external/distribution gates keep public `1.0.0` release readiness in **BLOCKED / CONDITIONAL** status:
1. **`P0` macOS `15.0+` Binary Compatibility Defect (`FINDING-ARCH-01`):** Bundled `libwebp.dylib`, `libsharpyuv.dylib`, `ffmpeg` `9.0.2`, and `ffprobe` are compiled with `LC_BUILD_VERSION minos 27.0`, contradicting the app's `MACOSX_DEPLOYMENT_TARGET: 15.0`. While passing on a macOS 27 host, this will break dyld loading / binary execution on actual macOS 15.0 (Sequoia) or macOS 26.x (Tahoe) systems.
2. **`P0/P1` Unverified Genuine Camera RAW Support (`GAP-12B` / `FINDING-PROD-01`):** `SupportedFormatsView` markets `"verified conversion routes"` for 11 Camera RAW formats, yet `0` real camera RAW sample files have ever been tested in the repo (`testGenuineCameraRAWSamplesIfProvided` is `BLOCKED` pending user RAW samples), and `Convert` vs. `ImageToolbox` diverge on `CIRAWFilter` decoding (`FINDING-ARCH-05`).

---

## 2. Prioritized Product & Architecture Improvement Backlog (`P0`–`P3`)

Every item below is directly grounded in Phase 54 audit findings and satisfies all eight Section 10 evaluation criteria.

### Backlog Item 1 (`P0`) — Rebuild Bundled WebP & FFmpeg Binaries for `macOS 15.0` Deployment Target
- **Priority:** `P0` (Critical compatibility / startup crash risk on macOS 15–26)
- **User Problem:** Users on macOS 15.0–26.x risk an immediate `dyld` crash on launch (`libwebp.dylib` / `libsharpyuv.dylib`) or media engine failure (`ffmpeg` / `ffprobe`).
- **Current Limitation:** `otool -l` confirms `LC_BUILD_VERSION minos 27.0` on all four artifacts ([project.yml](file:///Users/cancan/Desktop/LocalConvert/project.yml#L15) targets `15.0`).
- **Expected Value:** Guarantees true `macOS 15.0+` compatibility matching the stated system requirements.
- **Technical Complexity:** `M`
- **Regression Risk:** Low-to-Medium (must verify identical `--enable-videotoolbox --enable-audiotoolbox --enable-neon --enable-libmp3lame --enable-libopus --enable-libvpx` LGPLv3+ flags and WebP 1.6.0 API).
- **Dependencies:** Local C/CMake/FFmpeg arm64 cross/target build environment.
- **Test Requirements:** Automated `otool -l` `minos <= 15.0` check on all bundled executables/dylibs + clean `arm64` build (`0` ld version warnings) + full `Media`, `VideoTrim`, `WebP`, and `SmartPresetRegressionTests`.

### Backlog Item 2 (`P0/P1`) — Camera RAW Genuine-Sample Verification, Pipeline Alignment & Honest Formats UI
- **Priority:** `P0/P1`
- **User Problem:** UI presents `"verified conversion routes"` for 11 RAW types while `0` real RAW files are verified, and `Convert` / `Watch Folders` skip `CIRAWFilter` & TIFF-DNG fallback used in `Image Toolbox`.
- **Current Limitation:** [SupportedFormatsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/SupportedFormatsView.swift#L29) overstates verification; [ImageConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift#L396) lacks [ImageAdjustmentsEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageAdjustmentsEngine.swift#L24) `CIRAWFilter` + TIFF-hint fallback.
- **Technical Approach Comparison (No New External Dependencies Recommended First):**
  - *Option A (Recommended First):* Native Apple `CIRAWFilter` + `CGImageSource` TIFF-hint fallback (zero extra binary size/license burden, hardware Metal/GPU acceleration, preserves macOS camera support). Verify with user-provided genuine RAW files across brands; narrow UI/registry support matrix to tested families or mark OS-dependent RAWs clearly.
  - *Option B (Fallback Only If OS RAW Gaps Fail Product Needs):* Static **LibRaw** (`LGPL 2.1` / `CDDL`). Adds C++ bridge maintenance, ~5–10 MB binary footprint, and lacks Apple Camera RAW lens/highlight/ProRAW profiles — unjustified unless testing exposes fatal ImageIO/`CIRAWFilter` omissions.
- **Expected Value:** Honest capability reporting + consistent RAW demosaicing, EXIF orientation, and color rendering across `Convert`, `Watch Folders`, and `Image Toolbox`.
- **Technical Complexity:** `M`
- **Regression Risk:** Low (isolated to `.isRawImage` inputs).
- **Dependencies:** User-supplied genuine RAW sample directory (`LOCALCONVERT_RAW_SAMPLES_DIR`).
- **Test Requirements:** Run `Phase53VerificationTests/testGenuineCameraRAWSamplesIfProvided` across all obtained real RAW files (`JPG`/`PNG`/`TIFF` decode check, orientation, dimensions, metadata, SHA-256 unchanged) + unit test for honest UI label/capability note.

### Backlog Item 3 (`P1`) — `HistoryManager` Test Isolation & Injectable Storage URL
- **Priority:** `P1`
- **User Problem:** Test suites mutating `ConversionManager` or `MetadataManager` silently append test items into the developer/user's live `~/Library/Application Support/.../history.json`.
- **Current Limitation:** [HistoryManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/History/HistoryManager.swift#L6-L25) hardcodes `private init()` without an injectable `fileURL`.
- **Expected Value:** Clean hermetically isolated tests parity-matched with `PresetStore`, `WatchFolderStore`, and `UndoRedoCoordinator`.
- **Technical Complexity:** `S`
- **Regression Risk:** Low (default `.shared` preserved for production).
- **Dependencies:** Inject optional `HistoryManager` parameter into `ConversionManager` / `MetadataManager`.
- **Test Requirements:** Verify `HistoryManager(fileURL: tempURL)` persistence/corruption backup + confirm full test suite no longer modifies Application Support `history.json`.

### Backlog Item 4 (`P1`) — Image Metadata Lossless Copy & Service Consolidation
- **Priority:** `P1`
- **User Problem:** `Metadata` tab and `Image Toolbox -> Metadata Privacy` expose slightly different naming (`"Save Copy..."` / `_tagged` vs. `"Save Privacy-Cleaned Copy..."` / `_clean`), distinct undo commands (`MetadataFileWriteUndoCommand` vs. `ImageFileWriteUndoCommand`), and separate parsing code (`1,192` lines across 3 files).
- **Current Limitation:** Overlapping tag maps in `ImageMetadataProvider`, `ImageMetadataService`, and `ImageMetadataInspectorService`.
- **Expected Value:** Shared lossless `CGImageDestinationCopyImageSource` rewrite semantics and consistent user mental model.
- **Technical Complexity:** `M`
- **Regression Risk:** Medium (touches both Metadata tab and Image Toolbox Privacy).
- **Dependencies:** Backlog Item 3 (`HistoryManager` injection).
- **Test Requirements:** `Phase49DataSafetyAndUndoTests` (`7/7`), `Phase37ImageToolboxCompletionTests`, lossless JPEG/PNG metadata round-trip preserving pixels.

### Backlog Item 5 (`P2`) — Pre-Existing Compiler Warning, Script Output & History/Jobs UX Hygiene
- **Priority:** `P2`
- **User Problem:** Unnecessary incremental script re-runs during development (`Copy Bundled Binaries and Runtime`), `18` pre-existing Swift/C++ warnings (`onChange` deprecations, unused variables, `-Wshorten-64-to-32`), and mild confusion between `Jobs`, `History`, `Editing History`, and `Watch Folders` activity logs.
- **Current Limitation:** See `DEBT-05`–`DEBT-07` and `FINDING-PROD-02`.
- **Expected Value:** Near-zero build warnings across the entire repo, faster incremental builds, and clearer `History` filtering (e.g., dedicated Watch Folder / Metadata distinction).
- **Technical Complexity:** `S`
- **Regression Risk:** Low.
- **Dependencies:** `project.yml` script output specification + SwiftUI view `onChange(of:) { _, newVal in }` signatures.
- **Test Requirements:** Clean `arm64` build verifying elimination of targeted warnings + `Phase47LifecycleAndUXTests` + full `LocalConvertTests`.

### Backlog Item 6 (`P2`) — Incremental Decomposition of Oversized Service/View Files (`SpotifyCompatibilityService`, `ImageToolbox`)
- **Priority:** `P2`
- **User Problem:** Engineering velocity and code review safety degrade in files exceeding `1,200`–`3,300` lines (`SpotifyCompatibilityService.swift` = `3,329` lines; `ImageToolboxOperationsViews.swift` = `1,365` lines).
- **Current Limitation:** Monolithic single-file layout in AudioToolbox/ImageToolbox helpers.
- **Expected Value:** Faster compilation and cleaner single-responsibility maintenance.
- **Technical Complexity:** `M`
- **Regression Risk:** Low (internal file extraction without behavioral change).
- **Dependencies:** None.
- **Test Requirements:** `Phase41SpotifyCompatibilityTests`, `AudioToolboxPro2Tests`, `Phase36`/`37` tests.

### Backlog Item 7 (`P3`) — Automated XCUITest Smoke Suite & Diagnostic Bundle Export
- **Priority:** `P3`
- **User Problem:** Manual GUI regression walkthroughs (Video Trim sheet, Audio markers canvas drag, Watch Folder setup, Save/Open panels) cannot currently run unattended.
- **Current Limitation:** Zero XCUITest target exists (`FINDING-TEST-02`), and `verboseLogging` writes `localconvert.log` without a one-click UI log viewer/export button.
- **Expected Value:** Automated UI smoke confidence on release candidates + streamlined user bug reporting offline.
- **Technical Complexity:** `L`
- **Regression Risk:** Low (additive test target + optional Settings button).
- **Dependencies:** Clean `15.0` bundled binaries (Item 1).
- **Test Requirements:** New `LocalConvertUITests` smoke suite launching app in isolated test defaults/stores.

---

## 3. Suggested Next Development Phases (Sequenced & Dependency-Ordered)

### Phase 55 — Binary Portability, Test Hygiene & Honest Capability Closure *(Required Pre-Release Gate)*
- **Includes:** Backlog Items **1 (`P0`)**, **3 (`P1`)**, **5 (`P2` build warnings/script outputs)**, plus workspace root hygiene (`debug-deployment/` cleanup/gitignore audit).
- **Complexity:** `M`
- **Acceptance Criteria:**
  1. `otool -l` confirms `minos <= 15.0` on `libwebp.dylib`, `libsharpyuv.dylib`, `ffmpeg`, `ffprobe` with `0` `ld` version warnings in `xcodebuild clean build`.
  2. `HistoryManager` uses isolated temp storage in all tests without touching `~/Library/Application Support/.../history.json`.
  3. All pre-existing `onChange` deprecation and unused-variable warnings resolved cleanly; incremental builds skip redundant binary copy work.
- **Regression Requirements:** Full `LocalConvertTests` (`603+` Swift Testing + `37+` XCTest passing with `0` failures) and `3/3` isolated `Phase422ClosureTests`.

### Phase 56 — Real Camera RAW Verification & Unified Image/Metadata Pipeline
- **Includes:** Backlog Items **2 (`P0/P1`)** and **4 (`P1`)**, executed **once user provides genuine camera RAW fixtures**.
- **Complexity:** `M`
- **Acceptance Criteria:**
  1. Genuine RAW samples across target brands pass `Phase53VerificationTests/testGenuineCameraRAWSamplesIfProvided` (full resolution/expected aspect, EXIF orientation, color accuracy, source integrity).
  2. `ImageConversionEngine` matches `ImageToolbox` RAW capability (`CIRAWFilter` + TIFF-hint fallback) OR `SupportedFormatsView` restricts claims strictly to verified formats and accurate OS notes.
  3. `ImageMetadataProvider` and `ImageMetadataInspectorService` share tag extraction/lossless `CGImageDestinationCopyImageSource` paths cleanly.
- **Regression Requirements:** `Phase53VerificationTests` (0 skips when `LOCALCONVERT_RAW_SAMPLES_DIR` set), `Phase49DataSafetyAndUndoTests`, `Phase36`/`37`/`42` tests, `Phase422ClosureTests`.

### Phase 57 (Optional Post-1.0 / Pre-Distribution Polish) — XCUITest Smoke Automation, Diagnostics & Targeted File Split
- **Includes:** Backlog Items **6 (`P2`)** and **7 (`P3`)**, plus final interactive GUI release sign-off (`VideoTrimSheetView`, Audio markers, Watch Folder Finder drops, Settings/Appearance).
- **Complexity:** `M/L`
- **Acceptance Criteria:** XCUITest smoke target passes core navigation, file drop queue, Preset/Watch Folder panel, and Undo/Redo toolbar checks; `SpotifyCompatibilityService.swift` modularized cleanly.

---

## 4. Explicitly Out-of-Scope Boundaries (Features to Avoid)

Based on core workspace principles and Phase 48/54 evidence, the following must **not** be introduced:
- **Cloud services, telemetry, crash analytics, or network update checkers** (violates LocalConvert's strict offline-first privacy design).
- **Adding a 10th+ top-level sidebar tab** (fragments `⌘1`–`⌘8`/`⌘,` navigation; capabilities belong inside `Convert`, `Presets`, or existing toolboxes).
- **Adding Homebrew / Python / third-party package-manager runtime dependencies** or GPL/nonfree FFmpeg codecs (`libx264`/`libx265`) that violate LGPLv3+ compliance.
- **Broad speculative rewrites ("Audio Editor 3.0", "PDF Workflow 2.0", or full App Sandbox rewrite)** unrelated to verified user defects unless App Store distribution is explicitly chosen as a product strategy change.
- **Re-introducing `LibRaw` or external RAW CLIs** unless Apple `CIRAWFilter` / `ImageIO` fails documented genuine-sample acceptance tests.
