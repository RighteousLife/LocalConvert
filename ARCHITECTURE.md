# LocalConvert — Architecture Documentation

This document describes the software architecture, design patterns, threading model, and implementation details of **LocalConvert**.

---

## 1. Architectural Philosophy

LocalConvert is built on four core principles:

1. **Zero Network Trust**: The application contains no networking code, analytics, or remote calls. All data processing remains strictly on the host Mac.
2. **Modular Engine Abstraction**: The core UI and queue orchestration know nothing about FFmpeg, LibreOffice, or libwebp. All conversions interact through the unified `ConversionEngine` protocol.
3. **Strict Process & Sandbox Isolation**: External engines run in isolated child processes with ephemeral per-job sandboxes. One failing or crashed process cannot corrupt another job's state or the parent application.
4. **Self-Contained Portability**: Every required binary and library is bundled within `LocalConvert.app`. The application runs portably without requiring package managers or system dependencies.

---

## 2. High-Level System Architecture

```text
┌────────────────────────────────────────────────────────────────────────┐
│                        macOS System Interfaces                         │
│   • Drag & Drop               • Finder Services (NSServices)           │
│   • Open With Association     • Custom URL Scheme (localconvert://)    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│                       Presentation Layer (SwiftUI)                     │
│   • ContentView              • DropZoneView                            │
│   • FileRowView              • FormatPickerView                        │
│   • BatchProgressBar         • Settings / OutputLocationBar            │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│                     Orchestration & State Management                   │
│   • AppState (@MainActor, ObservableObject)                            │
│   • ConversionQueue (Bounded Concurrency, Task Cancellation)          │
│   • ConversionManager (Job Lifecycle, Progress & Status Publishing)    │
│   • OutputManager (Output Path Resolution, User Preferences)          │
│   • FileDetector (Magic Bytes + Uniform Type Identifiers)              │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼────────────────────────────────────┐
│                          Conversion Registry                           │
│   • ConversionRegistry (Route Discovery, Capabilities, Options)        │
│   • ConversionEngine Protocol                                          │
└───────┬──────────────┬──────────────────────────┬──────────────────────┘
        │              │                          │                      │
┌───────▼──────┐┌──────▼───────────────────┐┌─────▼──────────────┐┌──────▼──────┐
│ ImageEngine  ││       OfficeEngine       ││     PDFEngine      ││ MediaEngine │
│ • ImageIO    ││ • Bundled LibreOffice    ││ • Apple PDFKit     ││ • Bundled   │
│ • CoreGraph. ││   (Headless Subprocess)  ││ • CoreGraphics     ││   FFmpeg    │
│ • libwebp    ││ • Sandboxed User Profile ││ • DPI Resampling   ││ • ffprobe   │
│   (C Bridge) ││ • OpenXML Validation     ││ • Multi-page Render││ • VideoToolb│
└──────────────┘└──────────────────────────┘└────────────────────┘└─────────────┘
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
- **Native Pipeline**: Utilizes Apple `ImageIO` (`CGImageSource`, `CGImageDestination`) and `CoreGraphics` for zero-overhead raster operations.
- **WebP Integration**:
  - macOS `ImageIO` cannot write WebP files. LocalConvert bundles Google's official `libwebp.dylib` (`v1.6.0`) and `libsharpyuv.dylib`.
  - Communicates via a minimal, non-blocking C bridge (`WebPBridge.h` / `WebPBridge.c`).
  - Converts CoreGraphics premultiplied alpha into straight alpha before calling `WebPEncodeRGBA` to prevent dark edge artifacts.
  - Supports lossy compression (quality 0–100) and lossless encoding.

### 4.2 Office Conversion Engine (`OfficeConversionEngine.swift`)
- **Headless LibreOffice**: Invokes bundled `soffice` directly as an unprivileged child process using `Process()`.
- **Ephemeral Sandbox Profile**:
  - Every job creates `/tmp/LocalConvert-Office-<UUID>/profile` passed via `-env:UserInstallation=file://...`.
  - Prevents single-instance lockups, allows fully concurrent document processing, and guarantees clean teardown without touching the user's personal configuration.
- **Bidirectional Office & PDF Pipelines**:
  - **Office → PDF**: Direct `--headless --convert-to pdf` filter execution.
  - **PDF → DOCX**: `--infilter=writer_pdf_import --convert-to docx`.
  - **PDF → PPTX**: `--infilter=impress_pdf_import --convert-to pptx`.
  - **PDF → XLSX**: Two-stage extraction: PDF layout conversion via Writer followed by tabular workbook reconstruction in Calc.
- **Structural Integrity Verification**: Validates generated OpenXML output archives using `unzip -l` for required XML entries (`word/document.xml`, `xl/workbook.xml`, `ppt/presentation.xml`).

### 4.3 PDF Engine (`PDFConversionEngine.swift`)
- **Native PDFKit & CoreGraphics**: Renders PDF pages directly into vector and raster representations.
- **DPI Resampling**: Computes exact target pixel dimensions based on chosen DPI presets (72, 96, 150, 200, 300, 600 DPI) for archival or print reproduction.

### 4.4 Media Engine (`MediaConversionEngine.swift`)
- **Bundled Static FFmpeg & ffprobe**: Self-contained static arm64 binaries compiled with LGPLv3+ and VideoToolbox.
- **Hardware Acceleration**: Video encoding defaults to Apple VideoToolbox (`h264_videotoolbox`, `hevc_videotoolbox`) for maximum throughput and minimal battery drain.
- **Stream Copy Pass-Through**: When source and target containers use identical compatible codecs (e.g., MP4 ↔ MOV containing H.264 / AAC), uses `-c copy` for instant, lossless conversion without re-encoding.
- **Real-Time Progress**: Parses machine-readable `-progress pipe:1` outputs, extracting `out_time_us` against probed duration to compute exact fractional completion.

---

## 5. Platform Integration

### 5.1 Finder Quick Actions & Services
Configured in `Info.plist` and `project.yml`:
- `NSServices`: Registers `Convert with LocalConvert` under Finder services for `public.item`.
- Handled in `AppDelegate` via `ServicesProvider.handleServicesConvert(_:userData:error:)`.

### 5.2 Document Types & Drag-and-Drop
- Registers `CFBundleDocumentTypes` for `public.item` with `LSHandlerRank: Alternate`.
- Implements `NSApplicationDelegate.application(_:open:)` for seamless Dock drop and "Open With" file routing.

### 5.3 URL Scheme (`localconvert://`)
- Registered under `CFBundleURLTypes`.
- Supports parameter payloads: `localconvert://convert?files=<percent-encoded-paths>`.
- Enables external automation from Shortcuts, Raycast, Alfred, and CLI scripts.

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

LocalConvert enforces test-driven quality across 21 test suites comprising **162 unit and integration tests**:

1. **Unit Tests**: Formats, registry lookups, option descriptors, file detection, magic bytes, UI state transitions.
2. **Integration Tests**: Real conversions for PNG, JPG, WebP, PDF, DOCX, XLSX, PPTX, MP3, WAV, MP4, MOV, WEBM.
3. **Concurrency & Resilience Tests**: Batch queues with simultaneous jobs, cancellation under active load, corrupt inputs, password-protected PDF rejection.
4. **Packaging & Security Tests**: App bundle integrity, dynamic library linkage (`otool -L`), code signature validation (`codesign`), and quarantine attributes.
