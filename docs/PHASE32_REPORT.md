# Phase 32 Report — Universal Format Compatibility & Conversion Expansion

## Overview

Phase 32 audited the actual capabilities of LocalConvert's bundled and system runtimes and expanded `LocalConvert`'s supported formats, conversion routes, capability declarations, security validation, UI surfaces, and automated + live Release verification.

No git commits, tags, pushes, or releases were created, and the `v1.0.0` release remains unmodified.

---

## 1. Empirical Runtime Audit (`docs/PHASE32_FORMAT_AUDIT.md`)

All format support claims were tested directly against the actual runtimes shipped or used by LocalConvert:

- **LibreOffice 26.8.0.3 (bundled headless)**: Verified `ppt ↔ pptx`, `doc ↔ docx`, `xls ↔ xlsx`, `odt ↔ docx`, `ods ↔ xlsx/xls`, `odp ↔ pptx/ppt`, `md ↔ docx/odt/html/pdf/epub`, `docx → epub/dotx`, and identified that `html → docx/doc/rtf/epub/md/txt` requires `--infilter="HTML (StarWriter)"`. Confirmed `xlsb` is import-only.
- **macOS ImageIO**: Verified `jp2`, `psd`, `exr`, `ppm` encode + decode support; confirmed `jxl` and `hdr` destinations are unsupported (`canWrite = false` in ImageIO, with `hdr` write routed via bundled FFmpeg).
- **FFmpeg & ffprobe 9.0.2 (bundled)**: Verified audio encode + decode (`mp3`, `wav`, `flac`, `m4a` AAC/ALAC, `aac`, `ogg`, `opus`, `aiff`, `caf`, `alac`, `ac3`, `eac3`, `dts`, `wma`, `au`, `wv`, `m4b`, `mka`; `amr`/`ape` read-only), video encode + decode (`mov`, `mkv`, `webm`, `avi`, `m4v`, `3gp`, `3g2`, `mpg`, `ts`, `flv`, `f4v`, `vob`, `wmv`, `asf`, `m2v`; `ogv`/`mts`/`m2ts` read-only), raster images (`qoi`, `pcx`, `wbmp`, `hdr`, `apng`; `xpm` read-only), and subtitles (`srt`, `vtt`, `ass`, `ssa`; `sub` read-only, bitmap `.sup`/PGS incompatible with text extraction).
- **macOS Built-in Archive Tools (`/usr/bin/bsdtar`, `/usr/bin/gzip`, `/usr/bin/bzip2`)**: Verified `zip`, `7z`, `tar`, `tar.gz`, `tar.bz2`, `tar.xz`, `gz`, `bz2` read/write and `rar` read-only extraction (excluding encrypted RAR).

---

## 2. Architecture & Implementation Summary

- **Explicit Capability Declarations (`FormatCapabilityRegistry.swift`, `FileFormat.swift`)**:
  - Every `FileFormat` declares `canRead`, `canWrite`, `canDecode`, `canEncode`, `supportsMetadata`, `supportsMultiplePages`, `supportsAnimation`, `supportsTransparency`, and `limitationNote`.
  - Added `.subtitle` (`FormatCategory.subtitle` / `FormatGroup.subtitles`) and expanded `FormatGroup` cleanly while preserving existing group enums and sort order.
  - Added `compoundExtensions` and `FileFormat.baseNameByStrippingExtension(from:)` for compound archives (`.tar.gz`, `.tar.bz2`, `.tar.xz`).
- **Unified Conversion Registry & Matrix (`ConversionRegistry.swift`, `ConversionMatrix.swift`)**:
  - Enforced `FormatCapabilityRegistry` read/write boundaries inside `ConversionRegistry` so read-only formats never appear in `supportedOutputFormats` or presets/recommendations/Quick Actions.
  - Added `ConversionMatrix.snapshot()` and JSON export (`ConversionMatrix.exportJSON()`), plus `routeWarning(from:to:)` for lossy/flattening/macro-stripping notices.
- **Engine Expansions**:
  - **Office (`OfficeConversionEngine.swift`)**: Expanded Writer/Calc/Impress/PDF routes, applied `--infilter=HTML (StarWriter)`, and added post-conversion PDF / OLE2 / ZIP OpenXML-ODF-EPUB verification.
  - **Image (`ImageConversionEngine.swift`, `ImageProcessor.swift`, `ImageMetadataProvider.swift`)**: Added ImageIO (`jp2`, `psd`, `exr`, `ppm`) and FFmpeg raster (`hdr`, `qoi`, `pcx`, `wbmp`, `xpm` RO, animated `gif ↔ apng`) support; ensured FFmpeg-decoded temporary PNGs are loaded into cached memory before temp file cleanup.
  - **Media (`MediaConversionEngine.swift`, `BaseFFmpegProvider.swift`, `MediaModels.swift`, `MediaProbe.swift`)**: Expanded Audio/Video format routes, `m4a_lossless` (ALAC) option, stream validation, and route-aware subtitle handling.
  - **Subtitles (`SubtitleConversionEngine.swift`)**: Added `srt ↔ vtt ↔ ass ↔ ssa`, `.sub` read-only input, video-to-text-subtitle extraction, and bitmap `.sup`/PGS rejection.
  - **Archives (`ArchiveConversionEngine.swift`)**: Added `zip`/`7z`/`tar`/`tar.gz`/`tar.bz2`/`tar.xz`/`gz`/`bz2` conversion and `rar` read-only input, with Zip Slip traversal protection, symlink blocking, 10k entry / 2 GB uncompressed caps, and encrypted ZIP detection.
- **Detection & UI (`FileDetector.swift`, `ConversionManager.swift`, `AppState.swift`, `SupportedFormatsView.swift`, `FileRowView.swift`, `FileListView.swift`, `SettingsView.swift`, `DropZoneView.swift`)**:
  - Updated extension/magic/ZIP-package detection, compound output naming, Read-Only badges, route warning indicators, and searchable Supported Formats & Matrix UI with JSON export.
- **Documentation (`docs/FORMAT_COMPATIBILITY.md`, `README.md`)**:
  - Published the complete compatibility matrix and updated `README.md`.

---

## 3. Verification Results

- **Unit & Integration Test Suite (`xcodegen generate && xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'`)**:
  - **Result**: **351 tests in 39 suites passed** (`0` failures, `TEST SUCCEEDED`, 74.406s).
  - Covers all baseline suites (with `Phase18Tests`, `Phase19Tests`, and `Phase30Tests` updated for Phase 32 writable `psd`/`3gp`, first-class `eac3`/`3g2`, and updated display names) plus 7 comprehensive `Phase32Tests` suites testing real Office (`PPTX ↔ PPT`, `DOCX ↔ DOC ↔ ODT`, `XLSX ↔ XLS ↔ ODS`, `HTML → DOCX`, `MD → DOCX/PDF/HTML`, `DOCX → EPUB`), Image (`JP2`, `PSD`, `EXR`, `PPM`, `HDR`, `QOI`, `PCX`, `WBMP`, animated `GIF ↔ APNG`), Audio/Video (`WMA`, `AU`, `WV`, `M4B`, `MKA`, `EAC3`, `DTS`, `M4A (ALAC)`, `3G2`, `M4V`, `MPG`, `TS`, `FLV`, `F4V`, `VOB`, `WMV`, `M2V`, silent MP4 audio rejection), Subtitles (`SRT ↔ VTT ↔ ASS ↔ SSA`, MKV text subtitle extraction, SUP rejection), Archives (`ZIP ↔ 7Z ↔ TAR ↔ TGZ ↔ TBZ2 ↔ TXZ`, `GZ ↔ BZ2 ↔ ZIP`, symlink/Zip Slip/encrypted-ZIP rejections), compound extensions, and matrix JSON export.
- **Release `arm64` Build, Signing & Dependency Audit**:
  - `xcodebuild ... -configuration Release -destination 'platform=macOS,arch=arm64' build`: **BUILD SUCCEEDED**.
  - `codesign --verify --deep --strict /Applications/LocalConvert.app`: **PASS**.
  - `./scripts/verify-dependencies.sh`: **PASS** (arm64, zero Homebrew dependencies, FFmpeg 9.0.2, LibreOffice 26.8.0.3).
  - `otool -L`: Strictly `@rpath` (`libwebp.dylib`, `libsharpyuv.dylib`) and macOS system frameworks/libraries only; zero hardcoded `/Users/cancan` source paths.
- **Live `/Applications/LocalConvert.app` Release Runtime QA**:
  - Deployed Release app to `/Applications/LocalConvert.app` and verified real binary `sample_deck.ppt` → `sample_deck.pptx` conversion via live UI selection (`PPTX`) and execution (`ppt/presentation.xml` + `ppt/slides/slide1.xml` confirmed in output).
  - Zero crash reports in `~/Library/Logs/DiagnosticReports/*LocalConvert*`.
