# Universal Metadata Architecture

## 1. Overview & Architectural Philosophy

LocalConvert's Metadata Architecture provides a capability-driven, universal system for reading, editing, and stripping metadata across audio, image, video, PDF, and Office document formats on macOS.

### Core Principles
1. **Dynamic Capability-Driven UI**: The User Interface (`MetadataView`, `MetadataFieldView`, `ArtworkEditorView`) and the management layer (`MetadataManager`) are completely decoupled from concrete file formats. The UI renders fields, input types, artwork zones, and capabilities dynamically from `MetadataCapabilities` provided by registered engines.
2. **Stream Preservation (Zero Re-encoding)**: Metadata operations **never** re-encode audio or video streams. Media containers are updated via container stream copying (`-c copy` with FFmpeg), images via native Image I/O dictionary updates, PDFs via native `PDFKit` document attribute serialization, and Office OpenXML files via zip archive `docProps/core.xml` manipulation.
3. **Atomic Safe-Write Guarantee**: File updates always follow the `SafeMetadataWriter` pattern. The provider writes modifications to an isolated temporary scratch file, validates the result, and atomically replaces the original file via `FileManager.default.replaceItemAt(...)`. If an error occurs or the operation is cancelled, the scratch file is cleaned up and the original file remains byte-for-byte untouched.
4. **Open Extensibility**: Adding support for a new format (e.g., `DNG`, `ProRes`, `CAF`, `EPUB`) requires **zero** changes to `MetadataView`, `MetadataManager`, or `HistoryManager`. Only a new `MetadataProvider` needs to be implemented and registered with `MetadataRegistry`.

---

## 2. Component Structure & Data Flow

```
┌────────────────────────────────────────────────────────┐
│                      MetadataView                      │
│       (Dynamic UI generated from MetadataCapabilities) │
└───────────────────────────┬────────────────────────────┘
                            │ observes / dispatches
                            ▼
┌────────────────────────────────────────────────────────┐
│                    MetadataManager                     │
│         (State, Dirty Tracking, History Logging)       │
└───────────────────────────┬────────────────────────────┘
                            │ queries & delegates
                            ▼
┌────────────────────────────────────────────────────────┐
│                   MetadataRegistry                     │
│   (Thread-Safe Provider Registry & Discovery Engine)   │
└─────────┬──────────────┬──────────────┬──────────────┬─┘
          │              │              │              │
          ▼              ▼              ▼              ▼
    ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐
    │   Audio   │  │   Image   │  │   Video   │  │  PDF &    │
    │ Metadata  │  │ Metadata  │  │ Metadata  │  │  Office   │
    │ Provider  │  │ Provider  │  │ Provider  │  │ Providers │
    └─────┬─────┘  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘
          │              │              │              │
          └──────────────┴──────┬───────┴──────────────┘
                                │ executes atomic writes
                                ▼
                   ┌────────────────────────┐
                   │   SafeMetadataWriter   │
                   │ (Atomic File Swapping) │
                   └────────────────────────┘
```

### Core Types & Protocols

- **`MetadataProvider`** (`Core/Metadata/MetadataProvider.swift`):
  Protocol implemented by format engines. Exposes:
  - `providerIdentifier: String`
  - `supportedFormats: Set<FileFormat>`
  - `capabilities(for: FileFormat) -> MetadataCapabilities`
  - `read(from: URL, format: FileFormat) async throws -> MetadataDocument`
  - `write(_: MetadataDocument, to: URL) async throws -> URL`
  - `removeMetadata(from: URL, fields: Set<String>) async throws -> URL`
  - `removeGPS(from: URL) async throws -> URL`

- **`MetadataCapabilities`** (`Core/Metadata/MetadataCapabilities.swift`):
  Describes supported read/write capabilities, stripping support, write strategy (e.g. In-Place Stream Copy, Image I/O In-Place, OpenXML Core XML), and the collection of `MetadataFieldDescriptor`s with their section assignments and value types (`string`, `number`, `date`, `rating`, `gps`, `readOnlyTechnical`).

- **`MetadataDocument`** (`Core/Metadata/MetadataDocument.swift`):
  Normalized value type storing strongly typed fields (title, artist, album, genre, year, copyright, comment, description, keywords, camera make/model, ISO, aperture, focal length, GPS coordinate, PDF author/subject, Office creator/revision) and custom string tags or embedded artwork.

- **`MetadataRegistry`** (`Core/Metadata/MetadataRegistry.swift`):
  Thread-safe singleton managing registered providers and finding the optimal provider for any given file or format.

- **`SafeMetadataWriter`** (`Core/Metadata/SafeMetadataWriter.swift`):
  Executes isolated mutations in temporary directories and performs atomic replacement on success.

---

## 3. Registered Concrete Providers

| Provider | Supported Formats | Write Strategy | Key Metadata Handled |
| :--- | :--- | :--- | :--- |
| **`AudioMetadataProvider`** | MP3, M4A, AAC, FLAC, WAV, OGG, OPUS | Stream-Copy (FFmpeg) | ID3v2, MP4 Atoms, Vorbis Comments, RIFF Tags, Embedded Album Artwork |
| **`ImageMetadataProvider`** | JPEG, PNG, TIFF, HEIC, WebP, GIF | Native Image I/O | EXIF, IPTC, TIFF, GPS Coordinates, GPS Removal |
| **`VideoMetadataProvider`** | MP4, MOV, MKV, WEBM, AVI | Stream-Copy (FFmpeg) | Title, Comment, Copyright, Year, Technical Codec Info |
| **`PDFMetadataProvider`** | PDF | Native PDFKit | Title, Author, Subject, Keywords, Creator, Producer |
| **`OfficeMetadataProvider`** | DOCX, XLSX, PPTX | OpenXML Core XML Zip Edit | Title, Subject, Creator, Description, Revision, Created/Modified Dates |

---

## 4. How to Add a New Format (Extensibility Guide)

To add support for a new format (e.g., `DNG` or `ProRes`):

### Step 1: Ensure FileFormat and FileDetector know the format
Ensure the format exists in `FileFormat.swift` and detection exists in `FileDetector.swift`.

### Step 2: Implement `MetadataProvider`
Create a provider (or extend an existing one if the underlying engine handles it):

```swift
import Foundation

public final class DNGMetadataProvider: MetadataProvider, @unchecked Sendable {
    public let providerIdentifier = "com.localconvert.metadata.dng"
    public let supportedFormats: Set<FileFormat> = [.dng] // example
    
    public func capabilities(for format: FileFormat) -> MetadataCapabilities {
        MetadataCapabilities(
            format: format,
            canRead: true,
            canWrite: true,
            canRemoveAll: false,
            canRemoveGPS: true,
            writeStrategy: .imageIOInPlace,
            fields: [
                MetadataFieldDescriptor(id: "title", displayName: "Title", section: .basic, valueType: .string, isWritable: true),
                MetadataFieldDescriptor(id: "cameraMake", displayName: "Camera Make", section: .camera, valueType: .string, isWritable: false),
                MetadataFieldDescriptor(id: "cameraModel", displayName: "Camera Model", section: .camera, valueType: .string, isWritable: false),
                MetadataFieldDescriptor(id: "gps", displayName: "GPS Coordinates", section: .location, valueType: .gps, isWritable: true)
            ]
        )
    }
    
    public func read(from url: URL, format: FileFormat) async throws -> MetadataDocument {
        // Read metadata using CGImageSource or tool...
        var doc = MetadataDocument(format: format, originalURL: url)
        // Populate doc...
        return doc
    }
    
    public func write(_ document: MetadataDocument, to url: URL) async throws -> URL {
        return try await SafeMetadataWriter.performSafeWrite(on: url, outputExtension: "dng") { tempURL in
            // Mutate tempURL...
        }
    }
    
    public func removeMetadata(from url: URL, fields: Set<String>) async throws -> URL {
        // Implementation
        return url
    }
    
    public func removeGPS(from url: URL) async throws -> URL {
        // Implementation
        return url
    }
}
```

### Step 3: Register the Provider in `AppState.init()`
In `LocalConvert/App/AppState.swift`:
```swift
MetadataRegistry.shared.register(DNGMetadataProvider())
```

### Verification
- `MetadataView` will automatically render the new format, fields, and actions.
- `MetadataManager` will manage dirty states, saving, and history logging without a single modification.
