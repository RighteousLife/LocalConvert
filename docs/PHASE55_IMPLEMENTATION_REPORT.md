# LocalConvert — Phase 55 Implementation Report

**Phase:** Phase 55 — Binary Portability, Test Isolation & Sustainable RAW Capability  
**Workspace:** `/Users/cancan/Desktop/LocalConvert/` (`RighteousLife/LocalConvert`)  
**Target Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`), XcodeGen `2.48.0`  
**Build Host Environment:** macOS 27.2.1 (`26B131`), Xcode 27.2 (`27B52`)

---

## 1. Executive Summary

Phase 55 resolved the highest-priority test-isolation, build-determinism, warning-hygiene, and RAW capability honesty items from the Phase 54 audit while strictly enforcing and exposing macOS 15.0 binary deployment-target compatibility checks:

- **P0 — Binary Portability & macOS 15 Compatibility Audit + Enforcement Gate:** Verified Mach-O `LC_BUILD_VERSION minos` across all bundled native binaries and added an automated `check_minos` (`<= 15`) gate to [`scripts/verify-dependencies.sh`](file:///Users/cancan/Desktop/LocalConvert/scripts/verify-dependencies.sh). Confirmed why local rebuild of `libwebp.dylib`, `libsharpyuv.dylib`, `ffmpeg`, and `ffprobe` (`minos 27.0`) could not be authentically performed without installing external tools or upstream source tarballs (and without faking Mach-O headers), leaving those four binaries transparently flagged as a macOS 15 compatibility blocker.
- **P1 — `HistoryManager` Test Isolation:** Added injectable `fileURL: URL?` and automatic `XCTest` detection in [`HistoryManager.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/History/HistoryManager.swift) so `HistoryManager.shared` never reads or writes `~/Library/Application Support/com.localconvert.app/history.json` during automated tests, and wired injection through [`ConversionManager.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Conversion/ConversionManager.swift), [`MetadataManager.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/MetadataManager.swift), and [`AppState.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState.swift).
- **P1 — Sustainable Apple-Native RAW Handling Policy & Honest Claims:** Consolidated Apple-native RAW decoding fallback (`CGImageSource` -> `ImageAdjustmentsEngine.loadWithCIRAWFilter` -> TIFF magic-byte `UTType.tiff` hint -> actionable `ConversionError.invalidInput`) in [`ImageConversionEngine.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift), without introducing LibRaw or other heavy native dependencies, and updated capability/route wording in [`FormatCapabilityRegistry.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/FileFormat/FormatCapabilityRegistry.swift) and [`SupportedFormatsView.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/SupportedFormatsView.swift).
- **P2 — Targeted Compiler Warning Cleanup & Incremental Build Script Reliability:** Eliminated Swift/Objective-C++ compiler warnings across 12 engine/UI source files and added `basedOnDependencyAnalysis: true`, explicit `inputFiles`, and explicit `outputFiles` (including `bundled-runtime-copied.stamp`) to [`project.yml`](file:///Users/cancan/Desktop/LocalConvert/project.yml), regenerating `LocalConvert.xcodeproj`.

---

## 2. Detailed Implementation by Priority

### 2.1 P0 — Binary Portability & macOS 15 Compatibility (`LC_BUILD_VERSION minos`)

#### Mach-O Inspection Findings
Inspecting the repository dependencies and built `.app` bundle via `otool -l`, `otool -L`, and [`scripts/verify-dependencies.sh`](file:///Users/cancan/Desktop/LocalConvert/scripts/verify-dependencies.sh) established exact deployment targets:

| Binary / Archive | Location in Repo / Bundle | Architecture | Homebrew Linkage | `LC_BUILD_VERSION minos` | Target (`<= 15.0`) Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `LocalConvert` | `Contents/MacOS/LocalConvert` | `arm64` | Zero Homebrew | `15.0` (`sdk 27.2`) | Pass |
| `libjxl.a` (+ 6 static `.a` libs) | `LocalConvert/Frameworks/` | `arm64` | N/A (static) | `15.0` | Pass |
| `soffice` (`LibreOffice 26.8.0.3`) | `LocalConvert/Resources/LibreOffice/Contents/MacOS/soffice` | `arm64` | Zero Homebrew | `11.0` | Pass |
| `libwebp.dylib` | `LocalConvert/Frameworks/` & `Contents/Frameworks/` | `arm64` | Zero Homebrew | **`27.0`** (`sdk 27.0`) | **BLOCKED (`> 15.0`)** |
| `libsharpyuv.dylib` | `LocalConvert/Frameworks/` & `Contents/Frameworks/` | `arm64` | Zero Homebrew | **`27.0`** (`sdk 27.0`) | **BLOCKED (`> 15.0`)** |
| `ffmpeg` (`9.0.2`) | `LocalConvert/Resources/ffmpeg/` & `Contents/Resources/ffmpeg/` | `arm64` | Zero Homebrew | **`27.0`** (`sdk 27.0`) | **BLOCKED (`> 15.0`)** |
| `ffprobe` (`9.0.2`) | `LocalConvert/Resources/ffmpeg/` & `Contents/Resources/ffmpeg/` | `arm64` | Zero Homebrew | **`27.0`** (`sdk 27.0`) | **BLOCKED (`> 15.0`)** |

#### Why a Clean Local Rebuild Could Not Be Performed
1. Pre-existing static archives on the host (`/opt/homebrew/lib/libmp3lame.a`, `libmpg123.a`, `libopus.a`, `libvpx.a`, `libwebp.a`) also carry `LC_BUILD_VERSION minos 27.0`, so relinking against them cannot produce a `minos 15.0` binary.
2. Required assemblers (`nasm`, `yasm`) are not installed locally, and no upstream source tarballs (`libwebp`, `ffmpeg`, `lame`, `mpg123`, `opus`, `libvpx`) exist on disk in `/tmp`.
3. Per Phase 55 non-negotiable rules, no Homebrew/Python packages were installed, no network fetches were added to the build, and no `LC_BUILD_VERSION` metadata was manually rewritten (`vtool`/binary patching without recompiling against macOS 15 SDK headers is prohibited).

#### Automated Enforcement Added
Updated [`scripts/verify-dependencies.sh`](file:///Users/cancan/Desktop/LocalConvert/scripts/verify-dependencies.sh) with `check_minos()` (lines 54–73) invoked for:
- `LocalConvert/Frameworks/libwebp.dylib` (max major `15`)
- `LocalConvert/Frameworks/libsharpyuv.dylib` (max major `15`)
- `LocalConvert/Frameworks/libjxl.a` (max major `15`)
- `LocalConvert/Resources/ffmpeg/ffmpeg` (max major `15`)
- `LocalConvert/Resources/ffmpeg/ffprobe` (max major `15`)
- `LocalConvert/Resources/LibreOffice/Contents/MacOS/soffice` (max major `15`)

When any bundled binary targets a macOS major version above `15`, `verify-dependencies.sh` prints an explicit error and exits with status `1`.

#### Exact Upstream Rebuild Path Required to Unblock macOS 15 Distribution
Per [`LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Resources/ffmpeg/FFmpeg-BUILDCONF.txt), all four artifacts must be rebuilt from verified upstream sources (either on a macOS 15 runner or with explicit `MACOSX_DEPLOYMENT_TARGET=15.0` and `-mmacosx-version-min=15.0`):
1. Build `libwebp` + `libsharpyuv` from upstream source with CMake (`-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64`) producing `@rpath/libwebp.dylib` and `@rpath/libsharpyuv.dylib` (`install_name_tool` verified, zero `/opt/homebrew` linkage).
2. Build static archives (`libmp3lame.a`, `libmpg123.a`, `libopus.a`, `libvpx.a`) from upstream sources into `/tmp/static-libs` with `MACOSX_DEPLOYMENT_TARGET=15.0` (`-arch arm64 -mmacosx-version-min=15.0`).
3. Configure and build `ffmpeg` `9.0.2` (`ffmpeg` & `ffprobe`) against `/tmp/static-libs` with `--extra-cflags="-mmacosx-version-min=15.0 ..."` and `--extra-ldflags="-mmacosx-version-min=15.0 -L/tmp/static-libs ..."` preserving the LGPLv3+ flags in `FFmpeg-BUILDCONF.txt`, then re-run `./scripts/verify-dependencies.sh` (expect exit `0`) and smoke-test the resulting `.app` on macOS 15 hardware.

---

### 2.2 P1 — `HistoryManager` Test Isolation & Store Injection

Modified files:
- [`LocalConvert/Core/History/HistoryManager.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/History/HistoryManager.swift#L6-L45)
  - Added `static var isRunningUnderXCTest: Bool` (`NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil`).
  - Added `static func productionStoreFileURL() -> URL` returning `~/Library/Application Support/<bundleID>/history.json` unchanged for production app launches.
  - Added `let fileURL: URL` and `init(fileURL: URL? = nil)`. When `fileURL` is `nil` under `XCTest`, `defaultStoreFileURL()` routes `HistoryManager.shared` to `FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-XCTest-History-\(pid).json")`.
  - Preserved exact `[ConversionHistoryItem]` JSON persistence format and `.json.corrupted` corrupt-file backup recovery.
- [`LocalConvert/Core/Conversion/ConversionManager.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Conversion/ConversionManager.swift#L240-L261)
  - Injected `private let historyManager: HistoryManager` via `init(registry: ConversionRegistry = .shared, historyManager: HistoryManager = .shared)` and routed `executeJob` history persistence through `historyManager.addEntry(historyItem)` (line 898).
- [`LocalConvert/Core/Metadata/MetadataManager.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/MetadataManager.swift#L29-L39)
  - Injected `private let historyManager: HistoryManager` via `init(..., historyManager: HistoryManager = .shared)` and replaced both `HistoryManager.shared.addEntry` call sites in `saveInPlace` (line 272) and `saveCopy` (line 407) with `historyManager.addEntry`.
- [`LocalConvert/App/AppState.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState.swift#L208-L237)
  - Added `historyManager: HistoryManager = .shared` to `AppState.init` and passed it to `ConversionManager(registry: registry, historyManager: historyManager)`.

---

### 2.3 P1 — Sustainable Apple-Native RAW Handling Policy & UI Honesty

- [`LocalConvert/Engines/Image/ImageConversionEngine.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift#L491-L587)
  - Added `decodeStandardOrRAWImage(from:detectedFormat:)` invoked at line 398 during conversion:
    1. Primary `CGImageSourceCreateWithURL` + `CGImageSourceCreateImageAtIndex` path with orientation normalization (`kCGImageSourceShouldCache: false`).
    2. For `isRAWInput` files where primary decoding fails, falls back to Core Image native `ImageAdjustmentsEngine.loadWithCIRAWFilter(url: input, config: ImageRAWDevelopConfig(), scaleFactor: 1.0)` rendered via `ImageProcessor.sharedCIContext` in Display P3 / sRGB with bounded cache clearing for `>= 16_000_000` pixel renders.
    3. If `CIRAWFilter` returns `nil`, inspects the first 4 magic bytes and retries `CGImageSourceCreateWithURL` with `[kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier]` for TIFF-wrapped DNG/RAW files.
    4. Throws an explicit `ConversionError.invalidInput` explaining that macOS ImageIO / Camera RAW could not decode the file (`"Its camera sensor variant may be unsupported on this macOS version or the file may be corrupted."`).
  - No LibRaw or third-party RAW library was added.
- [`LocalConvert/Core/FileFormat/FormatCapabilityRegistry.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/FileFormat/FormatCapabilityRegistry.swift#L270-L277)
  - Updated `.dng` and `.cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw` `limitationNote` to:
    `"Read-only camera RAW input decoded via macOS ImageIO / Camera RAW (availability depends on macOS camera support and file variant)."`
- [`LocalConvert/Features/Home/SupportedFormatsView.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/SupportedFormatsView.swift#L29)
  - Replaced `"verified conversion routes"` with `"supported conversion routes"` so the subtitle accurately describes registered matrix routes without overclaiming empirical test verification for every matrix pair or external camera RAW variant.

---

### 2.4 P2 — Warning Cleanup & Incremental Build Script Determinism

#### Compiler Warning Cleanup (Zero Swift/ObjC Warnings Observed in Clean Build)
Cleaned warnings across 12 source files without broad concurrency/warning suppressions:
- [`LocalConvert/Engines/JXL/Bridge/JXLBridge.mm`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/JXL/Bridge/JXLBridge.mm#L45) — clamped `size_t` to `1...8` before returning `static_cast<uint32_t>(n)` to eliminate implicit 64-to-32 integer precision loss warning.
- [`LocalConvert/Engines/JXL/JPEGXLCodec.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/JXL/JPEGXLCodec.swift#L856) — mapped `CChar` via `UInt8(bitPattern:)` for UTF-8 decoding in `stringFromErrBuf`.
- [`LocalConvert/Engines/Image/ImageMetadataService.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageMetadataService.swift#L127) — handled unused async result explicitly (`_ = try await provider.writeMetadata(doc, to: url)`).
- [`LocalConvert/Engines/Image/ImageProcessingService.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageProcessingService.swift#L639-L666) — removed unused variable bindings in `canvasExtension` and `borderFrame` proportional scaling blocks.
- [`LocalConvert/Engines/Image/ImageProcessor.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageProcessor.swift#L325) — resolved `CFByteOrderLittleEndian.rawValue` directly (`Int(CFByteOrderLittleEndian.rawValue)`).
- [`LocalConvert/Engines/AudioToolbox/AudioAnalysisService.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioToolbox/AudioAnalysisService.swift#L253) — removed unused binding in chunked PCM reader loop.
- Updated deprecated two-parameter `onChange(of:perform:)` modifiers to macOS 14+ zero/two-parameter closures (`{ _, _ in }` / `{ _, newTerms in }`) and cleaned local capture/unused warnings across all 6 PDF Toolbox views:
  - [`LocalConvert/Features/PDFToolbox/PDFInspectorSecurityView.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFInspectorSecurityView.swift)
  - [`LocalConvert/Features/PDFToolbox/PDFRedactionView.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFRedactionView.swift)
  - [`LocalConvert/Features/PDFToolbox/PDFToolboxView.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFToolboxView.swift)
  - [`LocalConvert/Features/PDFToolbox/PDFFormsView.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFFormsView.swift)
  - [`LocalConvert/Features/PDFToolbox/PDFAnnotationStudioView.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFAnnotationStudioView.swift)
  - [`LocalConvert/Features/PDFToolbox/PDFCompareView.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFCompareView.swift)

#### Incremental Build Script Dependency Analysis (`project.yml` -> `LocalConvert.xcodeproj`)
- [`project.yml`](file:///Users/cancan/Desktop/LocalConvert/project.yml#L114-L136): Configured `Copy Bundled Binaries and Runtime` with `basedOnDependencyAnalysis: true`, 9 explicit `inputFiles`, and 10 `outputFiles` including `$(DERIVED_FILE_DIR)/bundled-runtime-copied.stamp` touched at script completion (line 210). Regenerated `LocalConvert.xcodeproj` via `xcodegen generate`.

---

## 3. New Automated Verification Added

- [`LocalConvertTests/Phase55VerificationTests.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase55VerificationTests.swift) (5 XCTest methods):
  1. `testHistoryManagerSharedUsesTemporaryStorageUnderXCTestNeverUserAppSupport`
  2. `testHistoryManagerInjectedStorePersistsAndPreservesBackwardCompatibleJSONFormat`
  3. `testHistoryManagerCorruptFileBacksUpSafely`
  4. `testConversionManagerAndMetadataManagerUseInjectedHistoryWithoutPollutingProductionStore`
  5. `testRAWCapabilityNotesDoNotClaimUnconditionalVerificationAndUnsupportedRAWFailsSafelyInWatchFolder`

---

## 4. Workspace & Safety Compliance

- Diffed `git status --short` against the pre-Phase-55 baseline captured at `/tmp/localconvert_phase55_initial_git_status.txt` (`235` entries): all pre-existing user changes and untracked files (including `debug-deployment/` and `docs/`) were preserved untouched.
- Only the scoped Phase 55 files plus the regenerated `LocalConvert.xcodeproj` and three `docs/PHASE55_*.md` deliverables changed.
- `/Applications/LocalConvert.app` was not modified; `~/Library/Application Support/com.localconvert.app/` contains no test-created `history.json`.
