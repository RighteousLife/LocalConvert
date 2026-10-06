# LocalConvert 1.0.0

LocalConvert is a native, offline file conversion powerhouse for macOS built with Swift and SwiftUI. It enables fast, local file conversions across images, PDFs, office documents, spreadsheets, presentations, audio, and video without uploading your data to any external server.

---

## Key Highlights

- **100% Offline & Private**: All conversions, optimizations, and metadata manipulations run strictly on your Mac. No network calls, no cloud servers, and no telemetry.
- **Standalone Distribution**: Bundles static `FFmpeg 9.0.2`, `ffprobe 9.0.2`, Google `libwebp 1.6.0`, and headless `LibreOffice 26.8.0.3` runtime. Zero Homebrew, Python, or command-line dependencies required.
- **Apple Silicon Optimized**: Native `arm64` architecture with Apple VideoToolbox hardware acceleration (`h264_videotoolbox`, `hevc_videotoolbox`) and multi-core batch processing.

---

## Features & Capabilities

### 1. Image Conversion & Optimization
- **Wide Format Support**: PNG, JPG/JPEG, WebP, HEIC, TIFF, BMP, GIF, AVIF, SVG, ICNS, and RAW/DNG formats.
- **WebP & Compression**: High-efficiency lossy and lossless WebP encoding with RGB-to-YUV sharp color sampling.
- **Optimization Modes**: Preset quality levels, target file size constraints (e.g. Discord 25MB, web 500KB), DPI scaling, resizing, and cropping.
- **Apple ICNS**: Multi-representation icon package creation with standard Apple sizes (16x16 to 1024x1024).

### 2. PDF Toolbox
- **PDF Manipulation**: Merge multiple PDFs, Split into individual pages or custom page ranges, Extract specific pages, Delete pages, Reorder pages, and Rotate pages.
- **Images to PDF**: Combine multiple images into a single formatted PDF document.
- **PDF ↔ Office Roundtrip**: Convert PDFs to DOCX, PPTX, and XLSX, or render PDFs to high-resolution PNG, JPG, or TIFF.
- **Password-Protected PDFs**: Secure, in-memory unlocking UX with zero credential leakage to history or logs.

### 3. Office Documents & Spreadsheets
- **Office to PDF**: Convert DOCX, DOC, XLSX, XLS, PPTX, PPT, ODT, ODS, ODP, RTF, CSV, and HTML to high-fidelity PDF documents using isolated LibreOffice sandboxes.
- **Tabular Data**: Lightning-fast native CSV ↔ TSV parsing and conversion.

### 4. Audio & Video Conversion
- **Audio Formats**: MP3, WAV, FLAC, M4A, AAC, OGG, OPUS, and AIFF.
- **Video Formats**: MP4, MOV, MKV, WebM, AVI, WMV, M4V, and Video-to-GIF palette generation.
- **Audio Extraction**: One-click extraction from video containers to lossless or compressed audio.
- **Route-Aware Subtitles**: Preserves soft subtitle tracks (`mov_text`, `srt`, `vtt`) across compatible container streams.

### 5. Metadata Editor
- View, edit, and strip EXIF, IPTC, TIFF, QuickTime, ID3v2, Vorbis, and PDF metadata tags.
- One-click privacy stripping for social media and web uploads.

### 6. Jobs Center & Conversion History
- Multi-file queue with concurrent conversion limits (Automatic, 1 to 6 parallel jobs).
- Real-time progress bars, before/after size comparisons, and batch result summaries.
- Searchable conversion history with category filters, repeat conversions, and missing output indicators.
- Technical error details formatting with automated credential/password redaction.

### 7. macOS System Integration
- **Finder Quick Actions & Services**: Right-click any file in Finder to convert immediately.
- **Smart Folder Import**: Drag and drop directories to automatically discover and enqueue supported files.
- **Custom URL Scheme**: `localconvert://` handoff protocol for Shortcuts and Raycast automation.
- **Keyboard Shortcuts**: Complete macOS shortcut support (`⌘O`, `⌘↩`, `⌘1`..`⌘6`, `⌘,`, `⌘Q`).

---

## Reliability & Security

- **Process Watchdogs**: Subprocess monitors that cleanly terminate orphaned or hanging conversion tasks.
- **Credential Redaction**: Regex sanitization prevents passwords, tokens, or private paths from appearing in logs or error reports.
- **Isolated User Profiles**: Sandboxed execution roots preventing state collisions or temp file clutter.

---

## System Requirements

- **Mac**: Apple Silicon Mac (M1, M2, M3, M4 or later)
- **Architecture**: `arm64`
- **macOS Version**: macOS 15.0 (Sequoia) or later
- **Dependencies**: None (self-contained DMG)

---

## Distribution Assets

- `LocalConvert-1.0.0-arm64.dmg`
- `SHA256SUMS.txt`
