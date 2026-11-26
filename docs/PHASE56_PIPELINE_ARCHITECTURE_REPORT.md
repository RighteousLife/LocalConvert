# LocalConvert — Phase 56 Pipeline Architecture Report

**Phase:** Phase 56 — Unified Image & Metadata Pipeline  
**Date:** 2026-11-22  
**Primary New Abstraction:** [`ImageSourcePipeline.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageSourcePipeline.swift)

---

## 1. Pre-Consolidation Architecture Audit (Duplications & Drift Identified)

Inspecting all image conversion, RAW development, preview proxy, and metadata inspection paths before code changes revealed four concrete duplications and subtle behavioral divergences across five files:

1. **Duplicate EXIF / TIFF / IPTC / GPS / DPI Property Parsing:**
   - [`ImageMetadataProvider.populateDocument`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/Providers/ImageMetadataProvider.swift) and [`ImageMetadataInspectorService.extractEntries`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageMetadataInspectorService.swift) independently parsed the exact same `kCGImageProperty{TIFF,Exif,IPTC,GPS}Dictionary` trees with subtle inconsistencies:
     - `ImageMetadataInspectorService` used `NSNumber.doubleValue` for EXIF `FNumber`/`FocalLength` and defaulted missing GPS `LatitudeRef`/`LongitudeRef` to `"N"`/`"E"`, whereas `ImageMetadataProvider` used strict Swift `as? Double` / `as? [Int]` casts that dropped valid bridged `NSNumber` / scalar ISO values.
     - `ImageMetadataInspectorService.inspectDetailed` read unrotated `kCGImagePropertyPixelWidth`/`PixelHeight` in its main path, whereas its fallback called `ImageProcessingService.inspectSourceDimensions` which swapped dimensions for EXIF orientations `5...8`.
2. **Duplicate `CIRAWFilter` + `CIContext` Render Block:**
   - [`ImageConversionEngine`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift) (`decodeStandardOrRAWImage`) and [`ImageProcessingService`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageProcessingService.swift) (`decodeInputImageWithRAW`) both duplicated the Display P3/sRGB `CIContext.createCGImage(..., format: .RGBA16/.RGBA8)` and `>= 16_000_000` pixel cache-clear block around `ImageAdjustmentsEngine.loadWithCIRAWFilter`.
3. **Duplicate TIFF Magic-Byte DNG Hint & Redundant Disk Reads:**
   - Both `ImageConversionEngine` and `ImageProcessingService` duplicated inline 4-byte `FileHandle` TIFF header checks (`49 49 2A 00` / `4D 4D 00 2A`), while `ImageMetadataProvider` and `ImageMetadataInspectorService` lacked TIFF-header DNG hinting when inspecting RAW headers.
   - `ImageProcessingService.processInMemory` called `inspectSourceDimensions(url:)` before calling `decodeInputImageWithRAW`, and `decodeInputImageWithRAW` itself called `inspectSourceDimensions(url:)` even after `resolvedSrcAndImage` had already parsed `CGImageSourceCopyPropertiesAtIndex`.
4. **Duplicate Orientation Normalization & Property Dictionary Copying:**
   - Both `ImageConversionEngine` (`convertImage` + multi-page TIFF conversion) and `ImageProcessingService` read `kCGImagePropertyOrientation` via raw `as? UInt32` (missing `Int`/`NSNumber` or `TIFF.Orientation` values), and `ImageConversionEngine` duplicated the 10-line metadata normalization block (`Orientation = 1`, `TIFF.Orientation = 1`, `PixelWidth`, `PixelHeight`).

---

## 2. Unified Image / Metadata Data-Flow Architecture (After Phase 56)

```
                              ┌───────────────────────────────────────────────┐
                              │            ImageSourcePipeline                │
                              │  • inspectProperties(url:isRAWHint:)          │
                              │  • openImageSource / hasTIFFHeader            │
                              │  • orientation(from:) / orientedDimensions    │
                              │  • normalizedPropertiesAfterOrientation       │
                              │  • renderWithCIRAWFilter (Core Image)         │
                              │  • extractThumbnail (ImageIO proxy only)      │
                              │  • decodeStandardOrRAW (Conversion decode)    │
                              │  • extractStructuredProperties (Canonical)    │
                              └───────┬───────────────────────────┬───────────┘
                                      │                           │
         ┌────────────────────────────▼──────┐        ┌───────────▼──────────────────────────┐
         │      Image Conversion & Edit       │        │       Metadata Inspection & Copy     │
         ├────────────────────────────────────┤        ├──────────────────────────────────────┤
         │ ImageConversionEngine              │        │ ImageMetadataProvider                │
         │  • Standard/RAW -> decodeStandard  │        │  • readMetadata(from:) [TIFF hint]   │
         │  • Shared orientation & dest props │        │  • populateDocument -> Structured    │
         │                                    │        │                                      │
         │ ImageProcessingService             │        │ ImageMetadataInspectorService        │
         │  • inspectSourceDimensions         │        │  • inspectDetailed [TIFF hint +      │
         │  • decodeInputImageWithRAW         │        │    oriented dims]                    │
         │    (ProxyCache + CIRAW + ImageIO)  │        │  • extractEntries -> Structured      │
         │  • processInMemory (no redundant   │        │                                      │
         │    re-open when decoded props ok)  │        │ ImageMetadataService / MetadataMgr   │
         │                                    │        │  • writeMetadata / Save Copy / Undo  │
         │ ImageAdjustmentsEngine             │        │    (public boundaries preserved)     │
         │  • loadWithCIRAWFilter (demosaic)  │        └──────────────────────────────────────┘
         └────────────────────────────────────┘
```

---

## 3. Files Added & Modified (With Architectural Rationale)

| File | Role & Change Summary | Public API Impact |
| :--- | :--- | :--- |
| [`ImageSourcePipeline.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageSourcePipeline.swift) | **Created.** Shared Apple-native (`ImageIO` + `CoreImage` / `CIRAWFilter`) source opening, TIFF-header DNG hinting, `NSNumber`-safe orientation & oriented dimension math, post-orientation destination property normalization, Core Image RAW render helper, thumbnail extraction helper, full-res `decodeStandardOrRAW`, and canonical `ExtractedImageProperties` parser | Additive internal engine helper (`Sendable`, zero unsafe opt-outs) |
| [`ImageConversionEngine.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift) | Removed redundant `orientCGImage` and `decodeStandardOrRAWImage` blocks; delegated decoding to `ImageSourcePipeline.decodeStandardOrRAW`, orientation parsing in multi-page TIFF to `ImageSourcePipeline.orientation(from:)`, and metadata normalization to `ImageSourcePipeline.normalizedPropertiesAfterOrientation` | Preserved (`ConversionEngine` protocol unchanged) |
| [`ImageProcessingService.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageProcessingService.swift) | Consolidated `inspectSourceDimensions(url:)` onto `ImageSourcePipeline.inspectProperties` + `orientedDimensions`; delegated `CIRAWFilter` render, TIFF-header check, thumbnail extraction, and `orientation(from:)` in `decodeInputImageWithRAW`; avoided redundant disk re-open in `processInMemory` when decoded dimensions/properties exist | Preserved (`static let cameraRAWFormats` and all method signatures intact) |
| [`ImageMetadataProvider.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/Providers/ImageMetadataProvider.swift) | Used `ImageSourcePipeline.inspectProperties(..., isRAWHint: format.isRawImage)` in `readMetadata` and delegated EXIF/TIFF/IPTC/GPS/technical mapping in `populateDocument` to `ImageSourcePipeline.extractStructuredProperties` | Preserved (`MetadataProvider` protocol unchanged) |
| [`ImageMetadataInspectorService.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageMetadataInspectorService.swift) | Used `ImageSourcePipeline.inspectProperties(..., isRAWHint: format?.isRawImage == true)` and oriented dimensions in `inspectDetailed`; delegated `extractEntries` tag parsing to `ImageSourcePipeline.extractStructuredProperties` while retaining exact `ImageMetadataTagEntry` IDs and formatting | Preserved (`ImageDetailedMetadataSnapshot` & methods intact) |
| [`Phase56RAWAndPipelineTests.swift`](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase56RAWAndPipelineTests.swift) | **Created.** Added gated genuine-RAW matrix test harness plus automated verification for corrupt/unsupported RAW failure, Provider-vs-Inspector metadata parity, orientation-6 normalization across Conversion vs Toolbox, and `MetadataManager` Save Copy safety | Additive test class |

---

## 4. Boundaries Respected

- `ImageMetadataService`, `MetadataManager`, `ConversionManager`, `SafeMetadataWriter`, `UndoRedoCoordinator`, JXL box parsing (`JPEGXLCodec`), PDF/Audio/Video engines, and Phase 55.1 binaries required no structural rewrites and remain intact.
- Destructive writes remain opt-in; conversion outputs and `Save Copy` paths remain atomic and collision-safe.
