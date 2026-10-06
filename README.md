# LocalConvert

<p align="center">
  <img src="LocalConvert/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="LocalConvert icon" width="128" height="128" />
</p>

<p align="center">
  <strong>Native, private, offline file conversion for Apple Silicon Macs.</strong><br />
  Convert, optimize, edit, and organize your files entirely on your Mac.
</p>

<p align="center">
  <a href="https://github.com/RighteousLife/LocalConvert/releases/latest">Latest Release</a> ·
  <a href="https://github.com/RighteousLife/LocalConvert/releases/tag/v1.0.0">v1.0.0</a> ·
  <a href="#features">Features</a> ·
  <a href="#supported-formats">Formats</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#building-from-source">Build</a>
</p>

---

## Why LocalConvert?

LocalConvert is a native macOS application built with **Swift and SwiftUI** for converting and working with images, PDFs, Office documents, audio, and video.

Your files stay on your Mac. LocalConvert does not upload conversion data to a cloud service and does not require Homebrew, Python, or separate command-line tools for the released application.

**LocalConvert 1.0.0 is available as a self-contained Apple Silicon DMG.**

## Download

### LocalConvert 1.0.0

- **[Download the Apple Silicon DMG](https://github.com/RighteousLife/LocalConvert/releases/download/v1.0.0/LocalConvert-1.0.0-arm64.dmg)**
- **[Verify the SHA-256 checksum](https://github.com/RighteousLife/LocalConvert/releases/download/v1.0.0/SHA256SUMS.txt)**
- **[View the full release](https://github.com/RighteousLife/LocalConvert/releases/tag/v1.0.0)**

**Requirements:** Apple Silicon Mac (arm64), macOS 15.0 or later.

> **Distribution note:** The current GitHub release is **ad-hoc signed and not notarized by Apple**. macOS may therefore require manual approval the first time the application is opened. See [Installation](#installation).

## Features

### Image conversion & optimization

- PNG, JPG/JPEG, WebP, HEIC, TIFF, BMP, GIF, AVIF, SVG, ICNS, and RAW/DNG workflows
- Lossy and lossless WebP encoding
- Output-quality controls
- Target file size optimization with achievable-target feedback
- Resize by dimensions, percentage, or edge
- Crop with common aspect ratios or a custom rectangle
- Image-to-PDF conversion
- Batch processing

### PDF Toolbox

- Merge multiple PDFs
- Split pages and ranges
- Split multi-up/slide-style PDF pages
- Extract, delete, reorder, and rotate pages
- Compress PDFs
- PDF ↔ image workflows
- PDF → DOCX, PPTX, and XLSX
- Password-protected PDF handling

### Office & documents

- DOCX, DOC, XLSX, XLS, PPTX, PPT
- ODT, ODS, ODP, RTF
- CSV, TSV, HTML
- Office → PDF through bundled LibreOffice
- PDF → editable Office formats where supported
- Native CSV ↔ TSV conversion

### Audio & video

- Audio: MP3, WAV, FLAC, M4A, AAC, OGG, OPUS, AIFF
- Video: MP4, MOV, MKV, WebM, AVI, WMV, M4V
- Video → GIF
- Audio extraction
- Route-aware soft-subtitle handling on compatible containers
- Apple VideoToolbox acceleration where supported

### Metadata

- View and edit supported image, audio, video, PDF, and Office metadata
- EXIF/IPTC/TIFF/XMP workflows where supported
- ID3, Vorbis/comment, QuickTime, and PDF metadata
- Artwork editing for supported audio formats
- Remove supported metadata for privacy

### Jobs, presets & history

- Multi-file conversion queue
- Configurable concurrency
- Live progress and batch summaries
- Before/after file-size comparison
- Retry and cancellation
- Saved presets
- Searchable conversion history
- Repeat previous conversions
- Technical error details with sensitive-value redaction

### macOS integration

- Finder Quick Actions and Services
- Drag-and-drop files and folders
- Smart folder import for supported files
- Custom `localconvert://` URL handoff
- Native macOS keyboard shortcuts
- Optional menu bar integration
- Light/Dark appearance support
- Accessibility labels and native macOS controls

## Supported Formats

| Category | Input | Output |
|---|---|---|
| **Images** | PNG, JPG/JPEG, WebP, HEIC, TIFF, BMP, GIF, AVIF, SVG, ICNS, DNG/RAW | PNG, JPG/JPEG, WebP, HEIC, TIFF, BMP, GIF, AVIF, PDF, ICNS |
| **PDF** | PDF, PNG, JPG, TIFF, WebP, HEIC | PDF, PNG, JPG, TIFF, DOCX, PPTX, XLSX |
| **Office & documents** | DOCX, DOC, XLSX, XLS, PPTX, PPT, ODT, ODS, ODP, RTF, CSV, TSV, HTML | PDF, DOCX, XLSX, PPTX, CSV, TSV |
| **Audio** | MP3, WAV, FLAC, M4A, AAC, OGG, OPUS, AIFF, CAF, ALAC, AC-3 | MP3, WAV, FLAC, M4A, AAC, OGG, OPUS, AIFF, CAF, ALAC, AC-3 |
| **Video** | MP4, MOV, MKV, WebM, AVI, WMV, M4V, 3GP/3G2, MTS/M2TS | MP4, MOV, MKV, WebM, AVI, GIF, MP3 and supported audio outputs |

> LocalConvert intentionally focuses on **consumer and Apple-ecosystem formats**. Professional/broadcast formats such as ProRes RAW, REDCODE RAW, XAVC/XDCAM, and broadcast MXF are outside the project's scope.

## Installation

1. Download `LocalConvert-1.0.0-arm64.dmg` from [GitHub Releases](https://github.com/RighteousLife/LocalConvert/releases/latest).
2. Open the DMG.
3. Drag **LocalConvert** to **Applications**.
4. Open LocalConvert from Applications or Spotlight.

Because the current release is ad-hoc signed and not notarized, macOS may block the first launch.

If that happens:

1. Right-click (or Control-click) **LocalConvert.app** in Applications.
2. Choose **Open**.
3. Confirm **Open** in the macOS security dialog.

This is expected for the current open-source distribution model. The release should not be interpreted as Apple-notarized or Gatekeeper-approved.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘O` | Add Files |
| `⌘↩` | Start Conversion |
| `Esc` | Cancel Active Conversion |
| `⌘⇧R` | Repeat Last Conversion |
| `⌘1` | Convert |
| `⌘2` | Jobs Center |
| `⌘3` | PDF Toolbox |
| `⌘4` | Metadata Editor |
| `⌘5` | Presets |
| `⌘6` | History |
| `⌘,` | Settings |
| `⌘Q` | Quit |

## Privacy & Security

- Conversion processing is designed to remain on-device.
- The released application has **no Homebrew runtime dependency**.
- FFmpeg/ffprobe, libwebp, and LibreOffice runtimes are bundled with the distribution.
- Office subprocesses use isolated temporary profiles and watchdogs.
- Sensitive values are redacted from technical error details.
- Password-protected PDF credentials are handled ephemerally and are not persisted by the application workflow.
- No telemetry or conversion-data upload service is included.

## Building from Source

### Prerequisites

- macOS 15.0+
- Xcode 16.0+
- Apple Silicon Mac
- XcodeGen

XcodeGen can be installed separately with Homebrew:

```bash
brew install xcodegen
```

### Build & test

```bash
git clone https://github.com/RighteousLife/LocalConvert.git
cd LocalConvert

./scripts/verify-dependencies.sh
xcodegen generate

xcodebuild test \
  -project LocalConvert.xcodeproj \
  -scheme LocalConvert \
  -destination 'platform=macOS,arch=arm64'

xcodebuild -project LocalConvert.xcodeproj \
  -scheme LocalConvert \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
```

The source repository intentionally does **not** track the large LibreOffice runtime. See [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) and [scripts/setup-runtime.sh](scripts/setup-runtime.sh) for the development/runtime setup.

## Architecture

LocalConvert is organized around capability-driven conversion and shared application services:

- `ConversionRegistry` — actual source/target conversion capabilities
- `ConversionManager` / `ConversionQueue` — jobs, progress, cancellation, and concurrency
- `OutputManager` — output destinations and collision handling
- `PresetManager` — saved preset persistence and validation
- `HistoryManager` — conversion history
- `MetadataManager` — metadata providers and capability discovery
- Native ImageIO/CoreGraphics/PDFKit where appropriate
- Bundled FFmpeg/ffprobe for media conversion
- Bundled LibreOffice for Office conversion

For more detail, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Licensing

LocalConvert source code is licensed under the **MIT License**.

Third-party components retain their respective licenses:

- **libwebp / libsharpyuv** — BSD 3-Clause
- **FFmpeg / ffprobe** — LGPLv3+
- **LibreOffice** — MPL 2.0 plus applicable third-party licenses

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for license texts, build information, and attribution details.

## Release Notes

- [LocalConvert 1.0.0](docs/RELEASE_NOTES_1.0.0.md)
