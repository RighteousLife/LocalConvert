# LocalConvert

<p align="center">
  <img src="LocalConvert/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="LocalConvert Icon" width="128" height="128" />
</p>

<p align="center">
  <strong>Native macOS application for local file conversion.</strong><br />
  Conversions are performed locally on-device and the application does not implement network APIs for conversion processing.
</p>

<p align="center">
  <a href="#supported-formats">Formats</a> •
  <a href="#key-characteristics">Architecture & Capabilities</a> •
  <a href="#finder-integration">Finder Integration</a> •
  <a href="#building-from-source">Build & Test</a> •
  <a href="#distribution-model">Distribution Model</a> •
  <a href="#licensing">Licensing</a>
</p>

---

## Overview

**LocalConvert** is a native macOS application written in Swift and SwiftUI for converting files across images, office documents, spreadsheets, presentations, PDFs, audio, and video.

Conversions are performed entirely on the local machine. The application code does not implement network clients, cloud upload endpoints, or telemetry services for conversion workflows.

All necessary conversion runtimes and libraries—including **libwebp**, static **FFmpeg & ffprobe**, and headless **LibreOffice**—are bundled within the application distribution. End users do not need Homebrew, Python, or external command-line utilities installed on their system.

---

## Supported Formats

LocalConvert inspects files using both binary magic bytes and Uniform Type Identifiers (UTI) to route operations to dedicated engines:

### 1. Images
Utilizes Apple `ImageIO`, `CoreGraphics`, and bundled Google `libwebp` (`v1.6.0`):
- **Inputs**: PNG, JPG / JPEG, HEIC, WEBP, TIFF, BMP, GIF
- **Outputs**: PNG, JPG / JPEG, HEIC, WEBP (lossy or lossless), TIFF, BMP, GIF, PDF
- **Capabilities**: Configurable quality presets, straight alpha conversion for WebP, DPI scaling, and format-specific metadata handling.

### 2. Office Documents & Spreadsheets
Utilizes bundled headless `LibreOffice` executed in ephemeral sandboxed user profiles:
- **Office → PDF**:
  - Documents: `DOCX`, `DOC`, `ODT`, `RTF` → `PDF`
  - Spreadsheets: `XLSX`, `XLS`, `ODS`, `CSV` → `PDF`
  - Presentations: `PPTX`, `PPT`, `ODP` → `PDF`
- **PDF → Office Documents**:
  - `PDF` → `DOCX` (via `--infilter=writer_pdf_import`)
  - `PDF` → `PPTX` (via `--infilter=impress_pdf_import`)
  - `PDF` → `XLSX` (via two-stage tabular extraction and spreadsheet reconstruction)
- **Validation**: OpenXML structure validation (`word/document.xml`, `xl/workbook.xml`, `ppt/presentation.xml`) and page verification.

### 3. PDF Rendering
Utilizes native macOS `PDFKit`:
- **PDF → Images**: `PDF` → `PNG`, `JPG`, `TIFF`
- **Capabilities**: Resolution presets (72, 96, 150, 200, 300, 600 DPI), multi-page rendering, and compression quality settings.

### 4. Audio & Video
Utilizes bundled static `FFmpeg 9.0.2` & `ffprobe 9.0.2` (compiled with LGPLv3+ and Apple VideoToolbox):
- **Audio ↔ Audio**: `MP3`, `WAV`, `FLAC`, `M4A`, `AAC`, `OGG`, `OPUS`, `AIFF`
- **Video ↔ Video**: `MP4`, `MOV`, `MKV`, `WEBM`, `AVI`, `WMV`, `M4V`
- **Audio Extraction**: Any supported video container → `MP3`, `WAV`, `FLAC`, `M4A`, `AAC`, `OGG`, `OPUS`
- **Capabilities**:
  - **Hardware Acceleration**: Apple VideoToolbox (`h264_videotoolbox`, `hevc_videotoolbox`) on Apple Silicon.
  - **Stream Copy Pass-Through**: Re-packaging without re-encoding (`-c copy`) when containers share compatible codecs.
  - **Progress Monitoring**: Real-time progress updates via `-progress pipe:1`.

---

## Key Characteristics

- **Local Execution**: All conversions take place locally. The application contains no network client code for conversion operations.
- **Self-Contained Bundle**: Does not depend on Homebrew or user-installed CLI tools at runtime.
- **Native macOS Interface**: SwiftUI interface supporting Light and Dark modes.
- **Concurrent Processing**: Batch processing queue supporting up to 3 concurrent conversions with cancellation support.
- **Configurable Output Directory**: Saves files alongside the source file or to a user-selected destination directory.
- **Process Sandboxing**: Subprocess executions take place within isolated temporary directories (`/tmp/LocalConvert-*`) that are cleaned up upon completion or cancellation.

---

## Finder Integration

LocalConvert integrates with standard macOS workflows:

1. **macOS Services / Context Menu**:
   - Right-click any supported file in Finder → **Services** (or Quick Actions) → **Convert with LocalConvert**.
2. **Document Association**:
   - Supports Drag & Drop onto the application window or Dock icon, and "Open With" file associations (`CFBundleDocumentTypes`).
3. **URL Scheme**:
   - Supports `localconvert://` handoffs (e.g. `localconvert://convert?files=/path/to/file` or `localconvert:///path/to/file`) for automation with Shortcuts, Raycast, or terminal scripts.

---

## Distribution Model

- **Source Repository**: Contains the Swift application source code, unit/integration test suites, configuration, scripts, documentation, and smaller bundled dependencies. The large LibreOffice runtime is intentionally excluded from Git history.
- **Large Runtime Binaries**: The full headless LibreOffice runtime (~720 MB total, containing `libmergedlo.dylib` at ~137 MB) exceeds GitHub's standard per-file size limits. It is distributed via GitHub Release assets rather than tracked in standard Git history.
- **Application Distribution**: Pre-built, codesigned application bundles and disk images (`LocalConvert.dmg`) including all bundled runtimes are published on GitHub Releases.

---

## System Requirements

- **Operating System**: macOS 15.0 (Sequoia) or later
- **Architecture**: Apple Silicon (`arm64`)
- **Xcode**: Xcode 16.0+ (for building from source)

---

## Building from Source

### 1. Prerequisites

- [Xcode 16](https://developer.apple.com/xcode/) or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen):
  ```bash
  brew install xcodegen
  ```

### 2. Clone the Repository

```bash
git clone https://github.com/your-username/LocalConvert.git
cd LocalConvert
```

### 3. Verify Dependencies

```bash
# Verify local environment and bundled assets
./scripts/verify-dependencies.sh

# If building in a fresh checkout without bundled LibreOffice:
./scripts/setup-runtime.sh
```

### 4. Generate Project and Run Tests

```bash
# Generate the Xcode project from project.yml
xcodegen generate

# Run the automated test suite
xcodebuild -scheme LocalConvert -destination 'platform=macOS' test
```

Current test status: **162 / 162 tests passing across 21 test suites.**

---

## Licensing & Third-Party Notices

### LocalConvert Source Code
The original source code of LocalConvert is licensed under the **[MIT License](LICENSE)**:

> Copyright (c) 2026 Can

### Bundled Third-Party Components
The MIT License applies strictly to LocalConvert's original application code. Bundled third-party runtimes and libraries remain subject to their respective open-source licenses:

| Component | Version | License | Distribution & Role |
| :--- | :--- | :--- | :--- |
| **FFmpeg & ffprobe** | 9.0.2 | GNU LGPLv3+ | Bundled static binary (Subprocess) |
| **libmp3lame** | 3.100 / 4.0 | GNU LGPLv2+ | Statically linked into FFmpeg |
| **libmpg123** | 1.33.7 | GNU LGPLv2.1 | Statically linked into FFmpeg |
| **libopus** | 1.6.1 | BSD 3-Clause | Statically linked into FFmpeg |
| **libvpx** | 1.17.0 | BSD 3-Clause | Statically linked into FFmpeg |
| **libwebp** | 1.6.0 | BSD 3-Clause | Bundled dynamic library (`@rpath`) |
| **libsharpyuv** | 0.1.2 | BSD 3-Clause | Bundled dynamic library (`@rpath`) |
| **LibreOffice Runtime** | 26.8.0.3 | MPL 2.0 / Various | Bundled runtime directory (Subprocess) |

For complete licensing statements, build configurations, and attribution notices, please refer to:
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)
