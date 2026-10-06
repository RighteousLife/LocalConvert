# LocalConvert — Preset & Workflow Architecture (Phase 19)

## Overview

LocalConvert Phase 19 introduces a production-grade preset and workflow automation architecture. The subsystem decouples preset definitions, persistence, capability validation, and headless execution from the SwiftUI presentation layer.

This design guarantees that future phases—including **Phase 20 (Video Trim)**, **Phase 21 (Watch Folder / Automatic Conversion)**, and **Phase 22 (Image Resize & Crop)**—can directly reuse `PresetExecutor` and `PresetValidator` without architectural modification or SwiftUI dependencies.

---

## Core Architecture & Components

```
┌─────────────────────────────────────────────────────────────┐
│                       SwiftUI Layer                         │
│  ContentView  •  DropZoneView  •  FileListView  •  PresetUI │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                     PresetManager                           │
│  @MainActor ObservableObject coordinating store & workflows │
└──────────────┬───────────────────────────────┬──────────────┘
               │                               │
               ▼                               ▼
┌──────────────────────────────┐ ┌────────────────────────────┐
│         PresetStore          │ │      PresetValidator       │
│  Application Support JSON    │ │  ConversionRegistry SOT    │
│  Atomic write, safe fallback │ │  Positive/negative checks  │
└──────────────────────────────┘ └─────────────┬──────────────┘
                                               │
                                               ▼
┌─────────────────────────────────────────────────────────────┐
│               PresetExecutor (Headless Engine)               │
│  Zero SwiftUI dependency • Batch resolution • Job builder   │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 Core Conversion Subsystem                   │
│  ConversionJob  •  ConversionManager  •  ConversionQueue    │
└─────────────────────────────────────────────────────────────┘
```

---

## Data Models

### `SavedPreset`
Represents a user-configured or factory default preset with strict schema versioning:

- **`id: UUID`**: Unique preset identifier.
- **`name: String`**: Human-readable display name.
- **`description: String?`**: Optional contextual description.
- **`createdAt: Date` / `modifiedAt: Date`**: Lifecycle timestamps.
- **`targetFormat: FileFormat`**: The target conversion output format.
- **`sourceConstraint: FileFormat?`**: Optional specific source format restriction (e.g. only apply to `.pdf` or `.heic`).
- **`sourceCategoryConstraint: FormatCategory?`**: Optional category constraint (e.g. `.image`, `.video`, `.audio`, `.document`).
- **`options: ConversionOptions`**: Full conversion parameter payload (quality, DPI, webp lossless, video codecs, custom tags).
- **`outputDestinationPolicy: OutputDestinationPolicy`**:
  - `.defaultLocation`: Resolves based on user preferences in `AppSettings`.
  - `.sameAsInput`: Saves output directly next to the source file.
  - `.customDirectory(path: String)`: Saves to a dedicated preset folder.
- **`outputNamingPolicy: OutputNamingPolicy`**:
  - `.standard`: Retains base filename (`photo.webp`).
  - `.addSuffix(suffix: String)`: Appends custom suffix (`photo_optimized.webp`).
  - `.addPrefix(prefix: String)`: Prepends custom prefix (`web_photo.webp`).
- **`schemaVersion: Int`**: Version integer (default `1`) for future migration support.
- **`isBuiltIn: Bool`**: Distinguishes factory templates from user custom presets.

---

## Persistence & Corruption Recovery

- **Location**: `~/Library/Application Support/com.localconvert.app/presets.json`
- **Encoding**: ISO8601 timestamps, sorted keys, pretty-printed JSON.
- **Atomic Writes**: Written with `Data.WritingOptions.atomic` to eliminate partial-write corruptions during sudden app terminations or power losses.
- **Corruption Recovery**: If `presets.json` contains malformed JSON or unreadable schema:
  1. An error is logged via `os.Logger`.
  2. The corrupted file is safely backed up to `presets.corrupted.<timestamp>.json`.
  3. The store automatically restores default factory templates, ensuring the application never crashes on startup.

---

## Single Source of Truth Validation

`PresetValidator` strictly queries `ConversionRegistry.shared` to determine conversion routes:
1. Target format must be supported by an active conversion engine.
2. If `sourceConstraint` is set, `registry.canConvert(from: source, to: target)` must return `true`.
3. If a batch contains mixed compatible and incompatible items (e.g., trying to apply an Image preset to a mixed folder containing PNGs and videos), `validateBatch()` partitions the input into:
   - `compatibleURLs: [URL]`
   - `incompatibleURLs: [(url: URL, reason: String)]`

This allows the UI or background executor to proceed with all valid conversions while clearly reporting skipped items without failing the entire batch.

---

## Headless Execution & Watch Folder Readiness

`PresetExecutor` has **zero dependency on AppKit / SwiftUI views**:

```swift
func execute(
    preset: SavedPreset,
    inputURLs: [URL],
    conversionManager: ConversionManager,
    conversionQueue: ConversionQueue,
    destinationOverride: URL? = nil,
    defaultOutputLocation: OutputLocation = .sameFolder,
    customOutputDirectory: URL? = nil,
    fileDetector: FileDetector = FileDetector(),
    registry: ConversionRegistry = .shared
) -> PresetExecutionReport
```

This method can be directly invoked by CLI tools, unit tests, or the upcoming **Phase 21 Watch Folder daemon**.

---

## History Integration

When jobs are dispatched via presets, `options.customOptions["preset_name"]` is populated with the preset's display name. Upon job completion, `ConversionManager` persists the preset name into `ConversionHistoryItem.presetName`, providing complete workflow provenance in the History view.
