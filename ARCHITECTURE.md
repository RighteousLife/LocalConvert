# LocalConvert — Architecture Documentation

This document describes the software architecture, design patterns, threading model, and implementation details of **LocalConvert**.

---

## 1. Architectural Philosophy

LocalConvert (`v2.0.0`) is built on four core principles:

1. **Offline-First Processing & Opt-In-Only Network Boundary**: All file conversion, OCR, on-device speech transcription, redaction, and metadata operations run strictly offline on the host Mac with zero background network calls, telemetry, or analytics. The only network paths in the application are strictly user-initiated opt-in actions: `UpdateCheckService` (when the user explicitly clicks Check for Updates against GitHub Releases) and `URL-to-PDF` (`LiveWebKitURLToPDFRenderer` when the user explicitly confirms rendering an `http`/`https` URL).
2. **Modular Engine Abstraction**: The core UI and queue orchestration know nothing about FFmpeg, LibreOffice, `libwebp`, or `libjxl`. All conversions interact through the unified `ConversionEngine` protocol and capability-driven `ConversionRegistry`.
3. **Strict Process & Sandbox Isolation**: External engines run in isolated child processes with ephemeral per-job sandboxes, timeouts, and cancellation watchdogs; the Finder Quick Actions extension (`LocalConvertQuickActions.appex`) runs in its own App Sandbox with strict `LC-002` path/symlink validation.
4. **Self-Contained Portability**: Required runtimes and codecs (`FFmpeg 9.0.2`, `LibreOffice 26.8.0.3`, `libwebp 1.6.0`, `libjxl 0.13.0`) are bundled within `LocalConvert.app` for Apple Silicon (`arm64`) with zero Homebrew runtime dependencies.

---

## 2. High-Level System Architecture

```text
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             macOS System Interfaces                              │
│  • Drag & Drop / Clipboard (`⌘V`)    • Finder Quick Actions (.appex) & Services  │
│  • AppIntents / Siri & Shortcuts     • Custom URL Scheme (`localconvert://`)     │
└─────────────────────────────────────────┬────────────────────────────────────────┘
                                          │
┌─────────────────────────────────────────▼────────────────────────────────────────┐
│                           Presentation Layer (SwiftUI)                           │
│  • ContentView (`⌘1`–`⌘9`, `⌘K`, `⌘/`)  • ContextualSmartBarView & QuickLook     │
│  • MediaViewer/ (Photo & Video Editors)  • AudioWorkspace/ (Library & Timeline)  │
│  • PDFToolbox / ImageToolbox / Settings  • Text & Archive / Renamer / Duplicates │
└─────────────────────────────────────────┬────────────────────────────────────────┘
                                          │
┌─────────────────────────────────────────▼────────────────────────────────────────┐
│                        Orchestration & Core Services                             │
│  • AppState (@MainActor)                 • ConversionQueue & ConversionManager   │
│  • OutputManager & Atomic Reservation    • FileDetector (Magic Bytes + UTI)      │
│  • UndoRedoCoordinator & Presets/History • BatchFileRenamer / DuplicateScanner   │
│  • DiagnosticBundleExporter / UpdateCheckService (opt-in) / Localization (en/tr) │
└─────────────────────────────────────────┬────────────────────────────────────────┘
                                          │
┌─────────────────────────────────────────▼────────────────────────────────────────┐
│                        Conversion Registry & Engines                             │
│  • ImageEngine (ImageIO, libwebp 1.6.0, libjxl 0.13.0)                           │
│  • OfficeEngine (LibreOffice 26.8.0.3 + IWorkConversionBridge)                   │
│  • PDFEngine & PDFToolboxEngine (PDFKit, CoreGraphics, Vision OCR, PDFPowerTools)│
│  • MediaEngine (FFmpeg/ffprobe, VideoToolbox, QuickVideoCutter, Speech-to-Text)  │
│  • TextEngine (CSV/TSV/PLIST/JSON/XML/WEBLOC/ICS/VCF) & SubtitleEngine           │
│  • ArchiveConversionEngine & ArchiveInspectorEngine (ZIP/7Z/TAR/TGZ/TBZ2/TXZ)    │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Core Subsystems

### 3.1 Presentation & State Management

- **`AppState` (`App/AppState.swift`)**:
  - The central `@MainActor` state store bound to SwiftUI views.
  - Manages `droppedFiles: [DroppedFile]`, active conversion statuses, batch metrics, and alert presentations.
  - Exposes a thread-safe weak singleton (`AppState.shared`) allowing macOS system delegates and Finder handoff handlers to route incoming files into the active UI session.
- **`ConversionQueue` (`Core/ConversionQueue/ConversionQueue.swift`)**:
  - Manages concurrent job execution with a configurable concurrency limit (default: 3 concurrent jobs).
  - Maintains deterministic job ordering, prevents CPU exhaustion, and coordinates aggregate progress calculations across batch operations.
- **`ConversionManager` (`Core/Conversion/ConversionManager.swift`)**:
  - Encapsulates individual job lifecycle management (`waiting` → `converting` → `completed` / `failed` / `cancelled`).
  - Publishes progress streams (`ConversionProgress`) to the UI.
  - Dispatches tasks with full Swift Structured Concurrency cancellation propagation.

### 3.2 Format Detection & Registry

- **`FileDetector` (`Core/FileDetection/FileDetector.swift`)**:
  - Uses a two-tier classification pipeline:
    1. **Magic Bytes Analysis**: Reads the file header to identify true binary formats (e.g., `RIFF....WEBP`, `%PDF-`, `PK\x03\x04`, `\xFF\xD8\xFF`, `\x89PNG\r\n\x1a\n`, `ftyp`).
    2. **Uniform Type Identifier (UTI)**: Fallback classification using macOS system metadata.
  - Defends against extension spoofing (e.g., renaming a `.exe` to `.png`).
- **`ConversionRegistry` (`Core/ConversionRegistry/ConversionRegistry.swift`)**:
  - Thread-safe registry (`NSLock`) storing all registered `ConversionEngine` implementations.
  - Resolves available target formats for a given input format.
  - Queries option descriptors (e.g., DPI presets for PDF, compression quality for JPEG/WebP) applicable to specific routes.

---

## 4. Conversion Engine Architecture

Every conversion backend conforms to the unified `ConversionEngine` protocol:

```swift
protocol ConversionEngine: Sendable {
    var name: String { get }
    var supportedInputFormats: Set<FileFormat> { get }
    var supportedOutputFormats: Set<FileFormat> { get }
    func canConvert(from input: FileFormat, to output: FileFormat) -> Bool
    func availableOutputFormats(for input: FileFormat) -> Set<FileFormat>
    func optionDescriptors(from input: FileFormat, to output: FileFormat) -> [ConversionOptionDescriptor]
    func isAvailable() async -> Bool
    func convert(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> URL
}
```

### 4.1 Image Conversion Engine (`ImageConversionEngine.swift`)
- **Native Pipeline**: Utilizes Apple `ImageIO` (`CGImageSource`, `CGImageDestination`), `CoreGraphics`, and `Vision` (`VNGenerateForegroundInstanceMaskRequest`) for raster operations, subject cutout, and ICC color management.
- **WebP Integration**:
  - macOS `ImageIO` cannot write WebP files. LocalConvert bundles Google's official `libwebp.dylib` (`v1.6.0`) and `libsharpyuv.dylib`.
  - Communicates via a minimal, non-blocking C bridge (`WebPBridge.h` / `WebPBridge.c`), converting CoreGraphics premultiplied alpha into straight alpha before encoding.
  - Supports lossy compression (quality 0–100) and lossless encoding.
- **JPEG XL (`libjxl 0.13.0`) Integration (`Engines/JXL/`)**:
  - Statically links upstream `libjxl` (`0.13.0`), `highway`, and `brotli` via an Objective-C++/C bridge for full `* ↔ JXL` read/write, effort `1–9`, 8/16-bit depth, alpha, animated JXL, ICC/EXIF/XMP container boxes, and lossless JPEG bitstream transcoding/reconstruction.

### 4.2 Office, iWork & Apple Data Engines
- **Headless LibreOffice (`OfficeConversionEngine.swift`)**: Invokes bundled `soffice` (`26.8.0.3`) directly as an unprivileged child process with isolated per-job `-env:UserInstallation=file:///tmp/...` profiles, supporting Office ↔ PDF, PDF → DOCX/PPTX/XLSX, and OpenXML archive validation.
- **iWork Bridge (`IWorkConversionBridge.swift`)**: Converts `.pages`, `.numbers`, and `.key` documents when Apple Pages/Numbers/Keynote are installed (and extracts embedded PDF previews when available).
- **Apple Data & Structured Formats (`TextConversionEngine.swift` / `AppleDataFormatConverter.swift`)**: Native offline conversion across `CSV`/`TSV`, `PLIST` (Binary/XML) ↔ `JSON`/`XML`, and read-only extraction from `.webloc`, `.ics`, and `.vcf`.

### 4.3 PDF Engine & PDF Toolbox Pro (`PDFConversionEngine.swift`, `PDFToolboxEngine.swift`, `PDFPowerToolsEngine.swift`)
- **Native PDFKit & CoreGraphics**: Renders PDF pages into vector and raster representations with exact DPI resampling (`72–600` DPI).
- **Pro Workflows**: Vision `VNRecognizeTextRequest` searchable OCR, LibreOffice `PDF/A-1b/2b/3b/4` archival export, permanent rasterized redaction with verification, LCS/pixel PDF Compare, 6-profile compression, AcroForm editing/flattening, page normalization, and encryption/decryption.
- **Opt-In URL to PDF (`URLToPDFExportCoordinator`)**: Renders `http`/`https` URLs via `WebKit` only upon explicit user confirmation (local `file://` HTML supported offline).

### 4.4 Media Engine, Audio Workspace & Speech-to-Text (`MediaConversionEngine.swift`, `AudioWorkspace/`, `OfflineSpeechTranscriptionEngine.swift`)
- **Bundled Static FFmpeg & ffprobe (`9.0.2`)**: Self-contained arm64 binaries compiled with LGPLv3+ and Apple `VideoToolbox`/`AudioToolbox`. Supports hardware-accelerated H.264/HEVC encoding, stream copy pass-through, real-time `-progress pipe:1` tracking, `QuickVideoCutterEngine` trim/subtitle overlay, and `.m4r` ringtone export.
- **Audio Workspace (`LocalConvert/AudioWorkspace/` & `Engines/AudioEditor/`)**: Unified SQLite FTS5 audio library, waveform pyramid & `.lcwave` disk cache (`WaveformPyramidService`, `LCWaveDiskCache`), non-destructive multitrack/waveform editor, DSP chain, and Spotify Local Files compatibility inspector/safe normalizer.
- **Offline Speech-to-Text (`OfflineSpeechTranscriptionEngine.swift`)**: On-device `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`) exporting `TXT` and `SRT` (with `SubtitleConversionEngine` conversion to `VTT`/`ASS`/`SSA`).

### 4.5 Media Viewer & Capture (`Features/MediaViewer/`, `ScreenCaptureService`)
- **Media Viewer (`MediaViewer/`)**: Dedicated modal and pinned-window media inspection and quick editing (`PhotoViewerEditorView`, `VideoViewerEditorView`, `PinnedImageWindowController`) supporting clipboard paste (`⌘V`), screen capture (`instant`/`3s`/`5s`), and direct handoff back to the conversion queue.

### 4.6 Archive Inspector & Core File Utilities (`Engines/Archive/`, `Core/FileManagement/`)
- **Archives**: `ArchiveConversionEngine` and `ArchiveInspectorEngine` support `ZIP`, `7Z`, `TAR`, `TAR.GZ`, `TAR.BZ2`, `TAR.XZ`, `GZ`, `BZ2`, and read-only `RAR` with strict Zip-Slip traversal validation and passphrase-protected ZIP extraction.
- **Utilities**: `BatchFileRenamerEngine`, `DuplicateFileScannerEngine`, `QuickTextToolsEngine` (Markdown/JSON/Base64), Quick QR Generator, and `DiagnosticBundleExporter`.

---

## 5. Platform Integration

### 5.1 Finder Quick Actions Extension & Services
- **Finder Quick Actions (`LocalConvertQuickActions/`)**: Sandboxed `.appex` extension (`com.localconvert.app.quickactions`) enforcing strict `LC-002` file URL validation (rejecting non-file URLs, path traversal, symlinks, folders, and non-regular files) before handing off valid files to the main app. Release builds disable `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` so `get-task-allow` is never embedded.
- **Finder Services (`NSServices`)**: Registers context-menu actions (`Convert with LocalConvert`, `Convert to PDF`, `Convert to WebP`, `Convert to MP4`, `Extract Audio`, `Merge PDFs`, `Extract PDF Pages`, `Compress PDF`) handled by `AppDelegate`.

### 5.2 Document Types, Clipboard & Drag-and-Drop
- Registers `CFBundleDocumentTypes` for `public.item` (`LSHandlerRank: Alternate`) and implements `NSApplicationDelegate.application(_:open:)` for Dock drops and "Open With" routing, plus `⌘V` clipboard staging.

### 5.3 AppIntents, Shortcuts & URL Scheme (`localconvert://`)
- **AppIntents (`LocalConvertAppIntents.swift`)**: Exposes `ConvertFilesIntent`, `RunSavedPresetIntent`, and `LocalConvertShortcuts` (`AppShortcutsProvider`) for Apple Shortcuts and Siri automation.
- **URL Scheme**: Registered under `CFBundleURLTypes` (`localconvert://convert?files=...`) for Raycast, Alfred, and CLI workflows.
- **Localization**: Full `en` / `tr` localization via `LocalConvert/Resources/Localizable.xcstrings`.

---

## 6. Process Cancellation & Safety Guarantees

```text
User Clicks Cancel
       │
       ▼
Task.cancel() in Swift Concurrency
       │
       ▼
withTaskCancellationHandler
       │
       ├─► onCancel Closure Executes:
       │     1. process.terminate() / kill -9
       │     2. FileHandle / Pipes closed
       │     3. Ephemeral /tmp directory removed
       │
       ▼
ConversionManager marks status as .cancelled
UI updates without orphaned artifacts
```

- **No Zombie Processes**: Child processes are tracked by PID and killed if the parent task cancels or terminates unexpectedly.
- **Deterministic File Cleanup**: All intermediate files reside in job-specific `/tmp` directories scheduled for removal via `defer` blocks and cancellation handlers.

---

## 7. Testing Strategy

LocalConvert enforces test-driven quality across **120 unit/integration test files (`120+` test suites)** in `LocalConvertTests/` and **4 UI test suites** in `LocalConvertUITests/` (`AudioWorkspaceUITests`, `ConversionActivityProvenanceUITests`, `EnglishTextLayoutAuditUITests`, `Phase57UITests`):

1. **Unit & Contract Tests**: Format capabilities, registry lookups, option descriptors, file detection, magic bytes, Apple data/iWork converters, AppIntents, localization coverage, security validators (`LC-001`–`LC-021`), and UI state transitions.
2. **Integration Tests**: Real on-device conversions for images (including WebP & JPEG XL `libjxl 0.13.0`), PDFs (OCR, PDF/A, redaction, compression, compare), Office documents, audio/video/subtitles, archives (`ArchiveInspectorEngine`), and speech transcription.
3. **Concurrency & Resilience Tests**: Batch queues with bounded concurrency, cancellation under active load, corrupt/hostile inputs, Zip-Slip path traversal rejection, and password-protected PDF/ZIP handling.
4. **UI, Packaging & Security Tests**: XCUITest responsive layout (`820×580` / `820×632`) and accessibility audits, app bundle integrity, dynamic library linkage (`otool -L`), deep code signature & `.appex` Release entitlement validation (`codesign`), and SHA-256 verification.
