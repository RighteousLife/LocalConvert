# LocalConvert — Phase 46.0: Image Toolbox Architecture Audit & Implementation Plan

**Date:** 2026-11-20  
**Scope:** Strictly Read-Only Architectural Audit for **Phase 46 — Image Editor Complete**  
**Repository:** `RighteousLife/LocalConvert` (`/Users/cancan/Desktop/LocalConvert/`)  
**Target Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Current App Version:** `1.0.0` (`MARKETING_VERSION: "1.0.0"`)  
**Status Distinction Tags Used Throughout:** **[Existing]**, **[Partially Implemented]**, **[Proposed]**, **[Verification Required During Implementation]**

---

## 1. Executive Summary

LocalConvert's Image Toolbox already provides a substantial, non-destructive three-layer image processing and format-conversion workbench spanning 11 sidebar sections (`Convert & Codec`, `Resize`, `Upscale`, `Crop & Rotate`, `Optimize File Size`, `Compression`, `Metadata & Privacy`, `Watermark`, `Before / After`, `Color Management`, `Remove Background`), full JPEG XL (`libjxl`) & WebP (`libwebp`) bridges, Vision background segmentation, Vision quad perspective detection, interactive 8-shape cropping, real RGB/Luminance histogram & palette extraction, objective PSNR/SSIM comparison, per-URL Undo/Redo (`ImageToolboxStore` + `ImageConfigUndoCommand` + `ImageFileWriteUndoCommand`), and 50 MP / 100 MP bounded memory handling (`Phase422ClosureTests`).

However, the current Image Toolbox is primarily a **conversion, geometry, optimization, and utility suite** rather than a complete **creative image editor**:
- **Color & Tone Editing:** All creative color/tonal controls (Exposure, Brightness, Contrast, Saturation, Gamma, Temperature/Tint, Highlights/Shadows, Whites/Blacks, Levels, RGB/Master Curves, Hue, Vibrance, Color Balance) are **missing** from `ImageToolboxConfig` and UI.
- **Creative Effects & Ordered Stacks:** Effects are limited to post-resize `CISharpenLuminance`, upscale `CINoiseReduction`/`CIUnsharpMask`, and opaque stage ordering; ordered/toggleable effect chains, Gaussian Blur, Vignette, Grain, Monochrome, Sepia, Film/Color Look filters, and individual adjustment resets do not exist.
- **Geometry & Straightening:** 90°/180°/270° rotation, flips, 8 geometric crop shapes, and 4-corner perspective warp exist, while **arbitrary straightening (`-45°...45°` with auto-inscribed crop & horizon detection)** is absent, and `ImageCropService.transformOrientation` hardcodes 8-bit `CGContext` (truncating 16-bit depth).
- **RAW Support:** RAW extensions (`.dng`, `.cr2`, `.cr3`, `.nef`, `.nrw`, `.arw`, `.raf`, `.rw2`, `.orf`, `.pef`, `.srw`) are **already imported and decoded via macOS ImageIO**, yet expose **no `CIRAWFilter` exposure, white balance, highlight/shadow recovery, boost, or RAW noise controls**, and preview downscaling can hit embedded camera JPEG thumbnails rather than live RAW demosaicing.
- **Interactive Preview Architecture:** `ImageToolboxView` currently re-decodes the source image from disk (`decodeInputImage(maxPixelDimension: 1200)`) and re-encodes the target codec (`ImageProcessor.encodeToMemory`) on every debounced slider edit, and every pipeline stage materializes an intermediate `CGImage`. Adding real-time sliders without proxy caching and fused `CIImage` graph execution would cause excessive I/O and memory churn.

**Core Architectural Verdict:** Phase 46 **can proceed cleanly on top of the existing architecture without a rewrite**. Preserving `ImageToolboxStore`, `ImageToolboxConfig`, `ImageProcessingService`, `UndoRedoCoordinator`, and `AppTheme` requires targeted extensions: (1) adding backward-compatible non-destructive adjustment, ordered effect-stack, straighten, preset, and RAW parameter models into `ImageToolboxConfig`; (2) fusing color/tone/RAW/effect/straighten steps into a **single lazy `CIImage` Core Image DAG** evaluated against a **bounded in-memory proxy cache for interactive scrubbing** and **full-resolution tiled/cleared rendering for export**; and (3) extending explicit continuous-gesture Undo coalescing and batch preset workflows.

---

## 2. Existing Architecture and Actual Data Flow

### 2.1 Three-Layer Ownership
- **UI Layer (`LocalConvert/Features/ImageToolbox/`):**
  - `ImageToolboxView` reads `appState.imageToolboxStore.config(for: primaryURL)` and binds child controls via `appState.imageToolboxStore.binding(for: primaryURL)`.
  - `ImageLivePreviewCanvas` provides reusable Split Slider, Side-by-Side, and Result modes with pan/zoom and checkerboard transparency rendering.
  - Section subviews: `ImageToolboxOperationsViews.swift`, `ImageCropEditorView.swift`, `ImagePerspectiveEditorView.swift`, `ImageUpscaleSectionView.swift`, `ImageCanvasBorderDPISectionView.swift`, `ImageMetadataPrivacyView.swift`, `ImageColorHistogramPaletteViews.swift`, `ImageComparisonView.swift`, `ImageConvertUtilitiesViews.swift`.
- **Application & Undo Layer (`LocalConvert/App/`, `LocalConvert/Core/UndoRedo/`, `LocalConvert/Core/Presets/`):**
  - `AppState` owns `imageToolboxStore: ImageToolboxStore` and `conversionQueue: ConversionQueue`.
  - `ImageToolboxStore` stores per-file `configsByURL: [URL: ImageToolboxConfig]` and `targetFormatByURL: [URL: FileFormat]` and bridges mutations to `UndoRedoCoordinator.shared` under `OperationContext.imageToolbox`.
  - `AppState+ImageToolbox.swift` serializes `ImageToolboxConfig` into `ConversionOptions.customOptions["image_toolbox_config"]` and dispatches single or batch `ConversionJob`s.
- **Engine Layer (`LocalConvert/Engines/Image/`, `Engines/WebP/`, `Engines/JXL/`):**
  - `ImageConversionEngine` registers Image formats (`canConvert`, `availableOutputFormats`) and routes `options.customOptions["image_toolbox"] == "true"` directly into `ImageProcessingService.processToFile(...)`.
  - `ImageProcessingService` owns `decodeInputImage`, `processInMemory`, and `processToFile`.

### 2.2 Actual Data Flow Trace

```
Image Import (AppState.addFiles / onDrop / NSOpenPanel)
   │  └─ FileDetector identifies format (raster, SVG, JXL, WebP, or Camera RAW)
   ▼
Image State (ImageToolboxView.loadPrimaryDetails)
   │  ├─ inspectSourceDimensions(url) via CGImageSource headers (no full bitmap alloc)
   │  ├─ decodeInputImage(maxPixelDimension: 1400) → primaryPreviewImage (NSImage proxy)
   │  ├─ ImageColorManagementService / ImageMetadataService / ImageMetadataInspectorService / JPEGXLCodec.inspect
   │  └─ hydrateMetadataDefaults (silent write into ImageToolboxStore.configsByURL[url])
   ▼
Processing Configuration (ImageToolboxStore.binding(for: primaryURL))
   │  ├─ Mutations go through ImageToolboxStore.updateConfig → rapid 450ms coalescing → ImageConfigUndoCommand
   │  └─ Config mutations trigger ImageToolboxView.onChange(of: config) → scheduleLivePreview (180ms debounce)
   ▼
Preview Rendering (ImageProcessingService.processInMemory(..., previewMaxDimension: 1200))
   │  ├─ Re-decodes source URL at proxy cap (1200px) [Performance Bottleneck Identified]
   │  ├─ Executes enabled stages sequentially, producing intermediate CGImages per stage
   │  ├─ Encodes in-memory bytes (JPG/PNG/HEIC/WebP/JXL/etc.) and re-decodes actualOutputCGImage
   │  └─ Displays before/after + telemetry on ImageLivePreviewCanvas
   ▼
Final Processing & Export (AppState.executeImageToolbox → ConversionQueue → ImageConversionEngine → ImageProcessingService.processToFile)
   │  ├─ Fast paths: lossless JPEG↔JXL bitstream transcode/reconstruct OR zero-reencode metadata/DPI copy
   │  ├─ Full path: processInMemory(previewMaxDimension: nil) across full resolution + multi-size presets
   │  ├─ Collision-safe reservation (ConversionManager.reserveUniqueOutputURL) + atomic write
   │  └─ Source files are never overwritten unless user explicitly checks Overwrite
   ▼
Undo / Redo & Restart Persistence
   ├─ Parameter edits → ImageConfigUndoCommand (survivesRestart: true, JSON in UndoHistory/journal.json)
   ├─ Metadata/in-place file writes → ImageFileWriteUndoCommand (RecoveryArtifactManager backup + SHA-256 identity guard)
   └─ Exported file creation → ConversionQueue → OutputCreationUndoCommand (context: .imageToolbox)
```

### 2.3 Destructive vs Non-Destructive Operations Today
- **Strictly Non-Destructive (Config-only, source immutable):** Crop, Rotate/Flip, 8 Geometric Shapes, Perspective Correction, Resize, Upscale, Target File Size, Compression Profile, Canvas Extension, Borders, DPI, Watermark, Background Removal, Color Profile target conversion, all Queue exports (write new unique destination files unless `Overwrite` is toggled on).
- **Mutates Destination / Potentially In-Place if Chosen:** `ImageToolboxView.saveMetadataInPlaceOrCopy` (allows overwriting original when user chooses in-place save, protected by `RecoveryArtifactManager` + `ImageFileWriteUndoCommand`), `ImageBatchRenameView` (moves filenames on disk, protected by `BatchRenameUndoCommand` + `FileIdentitySnapshot`), and exporting with `overwriteExisting = true`.

---

## 3. Existing Feature Inventory

| Area | Status | Verified Implementation |
|---|---|---|
| **Formats & Codecs** | **[Existing]** | Decode: JPG, PNG, HEIC, WebP (`libwebp`), TIFF, BMP, GIF/APNG, AVIF, JP2, PSD, EXR, PPM, HDR, JXL (`libjxl v0.13.0`), QOI/PCX/WBMP/XPM (FFmpeg), SVG (`NSImage`), 11 Camera RAW types (ImageIO). Encode: JPG, PNG, HEIC, WebP (lossy/lossless), JXL (lossy/Butteraugli/modular lossless/8&16-bit/JPEG transcode), TIFF, BMP, GIF, APNG, AVIF, JP2, PSD, EXR, PPM, HDR, PDF, ICO, ICNS, TGA, QOI/PCX/WBMP. |
| **Geometry & Crop** | **[Existing]** | Rotation `0/90/180/270°`, H/V Flip, Interactive 8-handle Crop Rect + Move interior, 13 Aspect Ratio Presets + Custom Ratio, 3 Overlay Grids (Rule of Thirds, Golden Ratio, 6×6 Grid), 8 Geometric Mask Shapes (Rectangle, Rounded Rect, Circle, Ellipse, Triangle, Diamond, Hexagon, Editable Custom Polygon 3–12 sides), Shape Alpha/Solid Fill (`ImageCropService`, `ImageCropEditorView`). |
| **Perspective** | **[Existing]** | Apple Vision quad detection (`VNDetectRectanglesRequest`), 4-corner manual drag handles, `CIPerspectiveCorrection`, 4 fill modes (`ImagePerspectiveService`, `ImagePerspectiveEditorView`). |
| **Resize & Print** | **[Existing]** | 7 Resize strategies (`none`, `exactDimensions`, `percentage`, `maxWidth`, `maxHeight`, `fitInside`, `fill`), Nearest/Bilinear/Bicubic/Lanczos resampling, post-resize luminance sharpening (`CISharpenLuminance` 0–1), Multi-Size Batch Presets, Upscale 2×–4×/Custom/Target Size (`CINoiseReduction` + multi-step Lanczos + `CIUnsharpMask`), Canvas Extension, Borders/Frames w/ Gradient & Outer Drop Shadow, DPI/PPI metadata or pixel resample (`ImageResizeService`, `ImageUpscaleService`, `ImageCanvasBorderService`). |
| **Color Management & Analysis** | **[Existing]** | ICC profile inspection, non-destructive color space conversion (`preserve`, `sRGB`, `displayP3`), 16-bit preservation (`ImageColorManagementService`), 256-bin R/G/B/Rec.709 Luma Histogram + shadow/highlight clipping %, Dominant Color Palette k-means++ extractor w/ HEX/CSS/JSON/PNG export (`ImageColorAnalysisService`). |
| **Segmentation & Compare** | **[Existing]** | Foreground subject cutout via `VNGenerateForegroundInstanceMaskRequest` + mask blur edge refinement (`ImageBackgroundRemovalService`), Text/Logo tiled watermarks (`ImageWatermarkService`), Full-res Before/After split-slider/side-by-side + MSE/MAE/PSNR/SSIM + 4× Difference Heatmap (`ImageComparisonService`, `ImageQualityMetricsService`). |
| **Metadata & Utilities** | **[Existing]** | Lossless EXIF/IPTC/XMP/GPS/ICC inspect, edit, and sanitize (`ImageMetadataInspectorService`, `ImageMetadataService`), Contact Sheet builder, Batch Rename w/ collision resolution + undo, Exact SHA-256 & perceptual dHash Duplicate Finder, Smart Format Advisor, SVG Optimizer/Sanitizer. |
| **Undo/Redo & Presets** | **[Existing]** | Per-URL `ImageConfigUndoCommand` (`survivesRestart = true`), `ImageToolboxUndoRehydrator`, `ImageFileWriteUndoCommand`, `ConversionQueue` `OutputCreationUndoCommand`, `SavedPreset` save via `AppState.saveImageToolboxPreset` & batch application via `PresetManager.apply(preset:to:)`. |

---

## 4. Missing and Partially Implemented Capabilities

### 4A. Advanced Color Editing
| Capability | Current Status | Non-Destructive? | Recommended Native Mechanism |
|---|---|---|---|
| **Brightness, Contrast, Saturation** | **Missing** | Yes (`ImageToolboxConfig` + `CIImage`) | `CIColorControls` (`inputBrightness`, `inputContrast`, `inputSaturation`) |
| **Exposure** | **Missing** | Yes | `CIExposureAdjust` (`inputEV`, -5.0...+5.0 EV) |
| **Gamma** | **Missing** | Yes | `CIGammaAdjust` (`inputPower`, 0.25...4.0) |
| **Temperature & Tint** | **Missing** | Yes | `CITemperatureAndTint` (`inputNeutral` / `inputTargetNeutral`) |
| **Highlights & Shadows** | **Missing** | Yes | `CIHighlightShadowAdjust` (`inputHighlightAmount`, `inputShadowAmount`) |
| **Whites & Blacks** | **Missing** | Yes | Parametric `CIToneCurve` endpoints / toe & shoulder shaping OR `CIColorMatrix` + soft clip LUT |
| **Levels (In Black/Gamma/White, Out)** | **Missing** | Yes | 1D piecewise remap via `CIColorCurves` / `CIToneCurve` or `vDSP`/`CIColorCubeWithColorSpace` per-channel 1D LUT |
| **Master & RGB Curves (Spline)** | **Missing** | Yes | Monotone cubic / Catmull-Rom 256-entry 1D LUT per channel -> `CIColorCubeWithColorSpace` (3D Identity+1D) or macOS Metal `CIColorKernel` / `CIImage` LUT |
| **Hue Adjustment** | **Missing** | Yes | `CIHueAdjust` (`inputAngle`, -π...+π rad / -180°...+180°) |
| **Vibrance** | **Missing** | Yes | `CIVibrance` (`inputAmount`, -1.0...+1.0) |
| **Color Balance (Shadows/Mids/Highs)** | **Missing** | Yes | Weighted luminance-band tinting via `CIColorKernel` / custom LUT / `CIColorPolynomial` (or 3-band `CIColorMatrix` blend in linear working space) |

### 4B. Image Effects & Filters
| Capability | Current Status | Native Framework & Technical Reason |
|---|---|---|
| **Gaussian Blur** | **[Partially Implemented]** (only internal mask blur in `ImageBackgroundRemovalService`) | **Core Image** (`CIGaussianBlur` on `clampedToExtent().cropped(to:)`) — zero-copy GPU execution inside the unified `CIImage` graph without full bitmap edge halos. |
| **Sharpening** | **[Partially Implemented]** (`postResizeSharpen` only inside `ImageProcessor.resampleCGImage`) | **Core Image** (`CISharpenLuminance`) — standalone toggleable node usable with or without resizing, fused in GPU graph. |
| **Unsharp Mask** | **[Partially Implemented]** (internal only inside `ImageUpscaleService`) | **Core Image** (`CIUnsharpMask`: Radius + Intensity) — fused directly in `CIImage` chain with luminance-preserving GPU convolution. |
| **Noise Reduction** | **[Partially Implemented]** (internal `artifactReduction` only inside `ImageUpscaleService`) | **Core Image** (`CINoiseReduction`: noise level + sharpness) — GPU bilateral/median-class denoising inside `CIImage` graph (+ `CIRAWFilter` chroma/luma denoise for RAW inputs). |
| **Vignette** | **Missing** | **Core Image** (`CIVignetteEffect` / `CIVignette`: center, radius, intensity, falloff) — smooth radial GPU falloff independent of resolution. |
| **Film Grain** | **Missing** | **Core Image + Custom Metal `CIColorKernel` (or `CIRandomGenerator` luma-modulated overlay)** — resolution-independent noise grain weighted by midtone luminance; pure Core Image `CIRandomGenerator` + `CIColorMatrix`/`CIOverlayBlendMode` works without `.metal` shader compilation risk, or Metal `.ci.metallib` if compiled cleanly. |
| **Monochrome** | **Missing** | **Core Image** (`CIColorMonochrome` or channel-mixer `CIColorMatrix` with R/G/B weights) — exact color-managed B&W conversion preserving alpha. |
| **Sepia** | **Missing** | **Core Image** (`CISepiaTone`: intensity 0...1) — hardware-accelerated `CIImage` node. |
| **Color Filters / Looks** | **Missing** | **Core Image** (`CIPhotoEffectChrome`, `Fade`, `Instant`, `Mono`, `Noir`, `Process`, `Tonal`, `Transfer`, `CIColorCrossPolynomial`, `CIColorCubeWithColorSpace` LUTs) — zero external dependencies, GPU-fused. |
| **Custom Ordered Filter Chains** | **Missing** | **`[ImageEffectSlot]` model + `CIImage` sequential evaluator** — lets users add, enable/disable, reorder, adjust intensity, and reset effects flexibly. |

### 4C. Non-Destructive Editing Architecture Gaps
- No unified Color/Light/Effects sidebar section (`ImageToolboxSection` lacks `.adjustments` / `.effects`).
- Adjustments are hardcoded as flat structs rather than an ordered, toggleable, resettable effect list (`ImageEffectSlot`).
- No per-section or per-parameter single-click reset (only global `Reset Pipeline`).
- No quick press-and-hold "Compare Original" button inside adjustment/crop/effect sections (Compare is a separate sidebar tab that encodes full output).
- No standalone `.lcimage` / `.lcedit` project sidecar file export/re-import for sharing or long-term archival re-editing across sessions beyond the rolling `UndoHistory/journal.json` limit.

### 4D. Crop & Geometry Gaps & Coordinate Accuracy Analysis
- **Missing Geometry Tools:** Continuous **Straighten (`-45.0° ... +45.0°`)** with auto-inscribed crop rectangle compensation (preventing blank wedges), plus optional **Auto Horizon Straighten (`VNDetectHorizonRequest`)**.
- **Existing Coordinate Precision Audit (`ImageCropEditorView.swift` + `ImageCropService.swift`):**
  - Top-left normalized coordinates `NormalizedRect(x, y, width, height)` cleanly decouple UI screen rect from pixel space and survive `previewMaxDimension` proxy scaling accurately.
  - **Bug / Gap Found 1:** In `ImageCropService.transformOrientation` (line 309 of `ImageCropService.swift`), `bitsPerComponent: 8` is hardcoded! Any 16-bit TIFF/PNG/JXL/RAW rotated or flipped loses 16-bit tonal precision immediately. Replacing this with `CIImage.oriented(...)` or 16-bit-aware `CGContext` eliminates truncation.
  - **Bug / Gap Found 2:** When `Crop` tab is active (`ImageToolboxView.swift` line 312), `sectionSupportsLivePreview` is `false`; color/effects/perspective edits do not reflect inside the Crop canvas preview, and dragging crop handles or interior box calls `configBinding` directly without explicit `beginContinuousEdit` / `endContinuousEdit` (`activeMoveOrigin` / `activeHandleOrigin` resets cleanly on `.onEnded`, so calling `store.beginContinuousEdit` on drag start & `endContinuousEdit` on `.onEnded` guarantees 1-drag = 1-undo regardless of pause duration during drag!).
  - **Gap Found 3:** If Straightening angle `θ` is added alongside `90°` rotations and perspective warp, their canonical order MUST be fixed cleanly in `CIImage` space: `(RAW Demosaic) → 90°/Flip Orientation → Straighten + Inscribed Auto-Clamp (CIImage transform) → User Normalized Crop → Shape Mask → Perspective → ...` so normalized UI crop handles always align 1:1 with the straightened image frame.

### 4E. Presets & Workflows Gaps
- `ImageToolboxView` supports saving a `SavedPreset` (`PresetManager.shared`) and `PresetManager` supports applying presets to `AppState.droppedFiles`, **but inside `ImageToolboxView` there is no UI to browse, preview, apply, or batch-apply curated/built-in or user presets directly to selected images**.
- `PresetValidator.isFileCompatible` checks `preset.options.customOptions["image_toolbox"] == "true"`, allowing same-format preset application across all `.image` formats cleanly.
- Missing: Built-in Image Studio look presets (e.g., *Vivid Landscape*, *Editorial B&W*, *Warm Film*, *Clean Portrait*, *Web crisp*), look-only preset apply (apply Color/Effects without overwriting target Export Format or Crop dimensions!), and `PresetManager` apply Undo integration for multi-file `ImageToolboxStore` updates.

### 4F. RAW Image Support Gaps
- Currently all 11 RAW types decode through `CGImageSourceCreateImageAtIndex` / `createThumbnail` (`ImageProcessingService.swift` lines 118–143). ImageIO decodes `8-bit` or OS-default camera profile without exposing `CIRAWFilter` controls, and `previewMaxDimension: 1200` uses `createThumbnail`, which for RAW files often extracts the **camera's embedded JPEG preview thumbnail** rather than a true demosaiced RAW frame (meaning embedded camera Picture Style differs from full export, and live RAW sliders have zero effect!).

---

## 5. Proposed Architecture

Phase 46 preserves the three-layer architecture (`Features/ImageToolbox/` → `Core/` + `App/` → `Engines/Image/`) while upgrading the internal Image Toolbox model and rendering core.

### 5.1 Extended Non-Destructive Model (`ImageToolboxConfig` v2)
Extend `ImageToolboxConfig` with backward-compatible `Codable` defaults (matching the existing `decodeIfPresent` pattern in `ImageToolboxModels.swift` lines 714–748):

1. **`rawSettings: ImageRAWDevelopConfig` [Proposed]:**
   - `enabled: Bool` (auto-applicable when input is Camera RAW), `exposureEV: Double` (`-4.0...4.0`), `temperatureKelvin: Double?` (nil = camera neutral), `tint: Double` (`-150...150`), `highlightRecovery: Double` (`0...1`), `shadowRecovery: Double` (`0...1`), `boostAmount: Double` (`0...1`), `lumaNoiseReduction: Double` (`0...1`), `colorNoiseReduction: Double` (`0...1`), `sharpnessAmount: Double` (`0...1`), `gamutMappingEnabled: Bool`.
2. **`colorAdjustments: ImageColorAdjustmentsConfig` [Proposed]:**
   - `isEnabled: Bool` (master toggle for instant Before/After A/B comparison without resetting sliders)
   - Basic Light: `exposureEV`, `brightness`, `contrast`, `highlights`, `shadows`, `whites`, `blacks`, `gamma`
   - Color: `temperatureOffset` (warm/cool relative shift `-100...100`), `tintOffset` (`-100...100`), `vibrance` (`-1...1`), `saturation` (`0...2`), `hueDegrees` (`-180...180`)
   - **Levels:** `ImageLevelsConfig` (`master` + optional `red`/`green`/`blue` `blackPoint`, `gamma`, `whitePoint`, `outBlack`, `outWhite`)
   - **Tone Curves:** `ImageCurvesConfig` (`master: [CurveControlPoint]`, `red`, `green`, `blue`)
   - **Color Balance:** `ImageColorBalanceConfig` (`shadowsRGB`, `midtonesRGB`, `highlightsRGB` relative shifts `-1...1`)
3. **`effectStack: [ImageEffectSlot]` [Proposed]:**
   - Ordered array of uniquely identified (`id: UUID`), toggleable (`isEnabled: Bool`), reorderable slots with typed parameters (`ImageEffectKind`: `.gaussianBlur`, `.sharpen`, `.unsharpMask`, `.noiseReduction`, `.vignette`, `.filmGrain`, `.monochrome`, `.sepia`, `.photoFilter`, `.tintOverlay`), each supporting individual Reset and Bypass.
4. **Geometry Extensions on `ImageCropAndTransformConfig` [Proposed]:**
   - `straightenDegrees: Double = 0.0` (`-45.0 ... +45.0`) + `autoCropOnStraighten: Bool = true`.
5. **Versioned Project Document (Optional Sidecar `.lcimg`):**
   - Lightweight JSON struct `ImageProjectDocument(schemaVersion: 1, sourcePath: String, sourceBookmarkData: Data?, targetFormat: FileFormat, config: ImageToolboxConfig)` — zero embedded pixels, enables reopening any edited session cleanly even after Undo journal rotation.

### 5.2 Unified Lazy Core Image DAG + Hybrid Render Pipeline

Replace separate per-stage `CGImage` allocations across Core Image steps with a composable **`ImageRenderGraph` (`CIImage` DAG)** inside `ImageProcessingService`:

```
Source URL ──► Cached Proxy Provider (Interactive Scrubbing <= 1600px, LRU cache)
           ──► Full-Res Decoder (Export / Full Compare)
                    │
        [If Camera RAW] ──► CIRAWFilter (scaleFactor = proxyScale for scrub, 1.0 for export)
        [Else Raster]   ──► CIImage(cgImage:) + Orientation
                    │
                    ▼   (Contiguous Lazy CIImage Graph — ZERO intermediate GPU/CPU readbacks!)
          1. Orientation (90°/Flip) + Straighten Transform + Auto-Inscribed Clamp
          2. Normalized Rectangular Crop + Rounded/Geometric Shape Mask (CIImage mask if geometric)
          3. Perspective Correction (CIPerspectiveCorrection + Fill Compositor)
          4. Foreground Segmentation Mask (if enabled: Vision mask cached per source+crop+orientation!)
          5. Color Pipeline (RAW Develop -> White Balance -> Exposure/Light -> Whites/Blacks/Levels -> Curves LUT -> Color Balance -> Vibrance/Sat/Hue)
          6. Ordered Effect Stack (effectStack.filter(\.isEnabled) evaluated sequentially as CIImage filters)
          7. ICC Target Color Space Transform (CGColorSpace working vs output conversion)
          8. Lanczos / Bicubic Resampling / Multi-step Upscale / Canvas & Border / Watermark
                    │
        ┌───────────┴────────────────────────────────┐
        ▼                                            ▼
 Interactive Canvas Path                      Full Export / Codec Compare Path
 ciContext.createCGImage(outputCI)            Render full extent → single CGImage (16-bit safe)
 (NO JPG/JXL/WebP re-encode during scrub!)    Apply Metadata/EXIF/DPI → Encode Target Format
```

**Why this matters:**
- During interactive color/effect scrubbing, **encoding bytes to JPEG/WebP/JXL is skipped** unless the user specifically requests `"Preview Output Compression"` (or clicks Export/Compare). Editing sliders update at sub-50ms Core Image Metal speed using the cached proxy `CIImage`.
- All Core Image adjustments compile down into a **single fused Metal kernel pass** inside Core Image (`ciContext.createCGImage(...)` once at the end of the graph), cutting memory traffic and peak VRAM drastically on 50–100 MP exports!

---

## 6. Native Framework Recommendations with Technical Justification

All Phase 46 features can be built 100% with **existing linked Apple system frameworks** (zero new third-party dependencies):

| Domain | Recommended Native Framework / API | Technical Justification |
|---|---|---|
| **Color Adjustments, Curves, Levels, Filters & Effects** | **Core Image (`CoreImage` + built-in `CIFilter`s)** | Lazy DAG node fusion compiles stacked color/tone adjustments into minimal Metal GPU passes; operates in linear/extended floating-point working space (`RGBAh` / extended sRGB / Display P3) avoiding 8-bit banding; zero intermediate bitmap copies; respects `CIContext` color management cleanly; already used in `ImageProcessor` and `ImageUpscaleService`. |
| **LUT / Spline Curves & Color Balance** | **Core Image `CIColorCubeWithColorSpace` + lightweight Swift cubic spline LUT generator (or `Accelerate` `vDSP` LUT interpolation)** | Generating a 64×64×64 (or 1D 256-step × 3 RGB channel) Float32 lookup table takes `< 0.2 ms` on CPU once when a curve point moves, then executes in a **single GPU texture lookup** inside `CIImage` at 60 FPS regardless of curve complexity—far cleaner and less brittle than runtime Metal string compilation. |
| **Film Grain** | **Core Image (`CIRandomGenerator` + `CIGaussianBlur` + `CIColorMatrix` + luma-masked `CIBlendWithMask`)** | Resolution-consistent organic grain in pure Core Image without needing Metal shader library bundle changes in `project.yml`, avoiding `SWIFT_STRICT_CONCURRENCY` or shader archive build risks while still executing 100% on GPU. (Custom Metal `CIColorKernel` `.ci.metal` remains an optional future upgrade if specialized grain/color balance math exceeds built-in filters.) |
| **Straighten / Inscribed Crop / Auto Horizon** | **Core Image (`CGAffineTransform` on `CIImage`) + Apple Vision (`VNDetectHorizonRequest`)** | `VNDetectHorizonRequest` (already proven in repo's PDF OCR Phase 44.4) gives deterministic auto-straighten angle (`angle`), while exact trigonometric inscribed-rectangle calculation (`InscribedRect`) guarantees zero transparent corner wedges when `autoCropOnStraighten == true`. |
| **RAW Demosaicing & Controls** | **Core Image (`CIRAWFilter` on macOS 15+)** | Native macOS Camera RAW framework supporting **917 camera models** (verified against current Xcode SDK) with hardware-accelerated demosaicing, `scaleFactor` proxy rendering, `exposure`, `neutralTemperature`, `neutralTint`, `highlightAmount`, `shadowAmount`, and RAW noise controls. |
| **Histogram & Clipping Telemetry** | **Existing `ImageColorAnalysisService` + `Accelerate` (`vImageHistogramCalculation_ARGB8888`)** | Existing CPU sampler (max `512px` proxy) works cleanly; accelerating live histogram updates after color edits via `vImage` / pre-allocated buffer ensures instant live histogram feedback during slider drags without GC spikes. |
| **Foreground Masking & Rectangles** | **Apple Vision (`VNGenerateForegroundInstanceMaskRequest`, `VNDetectRectanglesRequest`, `VNDetectHorizonRequest`)** | Already integrated; zero network calls, Apple Silicon Neural Engine accelerated. |

---

## 7. Undo/Redo and Persistence Integration

Phase 43's `UndoRedoCoordinator` + `ImageToolboxStore` architecture is **already well-suited for Phase 46** and needs **no replacement**:

1. **Snapshot Size Discipline (Zero Pixel Data in Journal):**
   - `ImageConfigUndoCommand` stores only JSON-encoded `ImageToolboxConfig` (`Payload` in `ImageToolboxUndoCommands.swift` line 8).
   - Adding RAW, Color, Curve control points (capped e.g. `<= 16` points per channel), Levels, Effects stack, and Straighten keeps serialized payloads at roughly **2–6 KB per undo entry**—preserving `survivesRestart = true` and instant journal persistence without ever storing `Data`/`CGImage`/`CIImage` bitmaps.
2. **Slider & Drag Coalescing (Tightening Explicit Lifecycle):**
   - Today `ImageToolboxStore.updateConfig` has explicit `beginContinuousEdit` / `endContinuousEdit` AND a 450 ms `rapidGroupID` debounce fallback.
   - **Required Enhancement:** Wire SwiftUI `Slider(..., onEditingChanged:)` on all new Phase 46 color/effect/RAW/straighten sliders AND `.onChanged`/`.onEnded` in `ImageCropEditorView`, `ImagePerspectiveEditorView`, and Curve handles directly to `store.beginContinuousEdit(for: url)` / `store.endContinuousEdit(for: url, explicitType: ..., explicitTitle: ...)` (matching the verified H2 pattern from Audio Editor). This prevents slow drags (>450 ms pauses while thinking) from splitting a single drag into multiple undo entries.
3. **New `UndoOperationType` Classification:**
   - Extend `ImageToolboxStore.classifyChange(from:to:)` with granular human-readable titles (`"Exposure"`, `"White Balance"`, `"Tone Curves"`, `"Add Effect: Vignette"`, `"Reorder Effects"`, `"RAW Develop"`, `"Straighten"`, `"Apply Preset: ..."`), using existing `.imageConfigEdit`, `.imageCrop`, `.imageRotateFlip`, `.presetApply` (already defined on `UndoOperationType`).
4. **Reset, Reorder, Toggle & Restart Rehydration:**
   - Individual reset (`resetColorSection`, `resetEffectSlot`, `resetAllAdjustments`) mutates `ImageToolboxConfig` through `updateConfig`, making every reset undoable/redoable cleanly.
   - Because `ImageConfigUndoCommand.Payload` decodes `ImageToolboxConfig` with backward-compatible `decodeIfPresent` defaults, existing v1 `UndoHistory/journal.json` files from Phase 43–45 will rehydrate cleanly across app updates without breaking or losing prior history.
5. **Project File Persistence (`.lcimg`) & Multi-Image Presets:**
   - Optional `.lcimg` project save/open uses atomic writes + path-traversal validation + missing-source relinking (mirroring `ProjectPersistenceService` patterns without duplicating assets).
   - Applying an Image Studio preset across `selectedFiles` updates `configsByURL` sequentially or under a grouped `transactionGroupID` per file cleanly.

---

## 8. Performance and Memory Strategy

### 8.1 Baseline Observations
- `Phase422ClosureTests.largeImageMemoryStabilityAndDiagnostics()` establishes the repo's 50 MP (`8192×6104`) and 100 MP (`10000×10000`) stability standard: bounded non-volatile internal VM & total footprint (`<= +150 MB` drift across repeated runs), `autoreleasepool` scoping, `.cacheIntermediates: false` on `CIContext`, and `ciContext.clearCaches()` whenever processed pixel count `>= 16_000_000`.
- Currently missing in `ImageToolboxView` / `ImageProcessingService`:
  - **Proxy Decode Caching:** `scheduleLivePreview` re-decodes `url` from disk every 180 ms via `decodeInputImage(maxPixelDimension: 1200)`.
  - **Vision Mask Re-computation:** If `backgroundRemoval.enabled` is true alongside color sliders, scrubbing Exposure re-runs `VNGenerateForegroundInstanceMaskRequest` on every preview tick!

### 8.2 Phase 46 Optimization Plan
1. **Bounded Decoded Proxy Cache (`ImagePreviewProxyCache` actor, <= 64 MB budget):**
   - Keyed by `(standardizedURL, fileSize, modificationTime, maxDimension, isRAWProxy)`.
   - Caches at most `<= 1600 px` longest-edge `CGImage` / `CIRAWFilter` proxy (<= ~10 MB per 1600×1200 RGBA8/16 buffer, LRU eviction capped at 64 MB, cleared on memory pressure / `ImageToolboxView.onDisappear` or `clear()`).
   - Eliminates repeated disk decode during interactive color/effect/curve/straighten scrubbing.
2. **Vision Cutout Mask Cache:**
   - Cache the computed `CVPixelBuffer` / single-channel mask `CIImage` keyed by `(url, cropTransform, perspective, mtime)` inside `ImagePreviewProxyCache` so color/filter scrubbing never re-runs Vision neural inference unnecessarily.
3. **Two-Mode Preview Rendering (Interactive Visual vs Codec Fidelity):**
   - For Color/Effects/RAW/Crop edits, live preview renders `outputCI -> NSImage` directly via `sharedCIContext` **without** running slow multi-pass JXL/AVIF/WebP compression on every slider tick.
   - Only `Convert`, `Target Size`, `Compression`, and `Compare` (`ImageComparisonService`) encode full target-codec bytes (showing a `"Previewing codec artifacts & byte size"` badge when active).
4. **Full-Resolution Export (`50 MP – 100 MP`) Guardrails:**
   - Single fused `CIImage` graph evaluated inside `autoreleasepool`.
   - Maintain `.cacheIntermediates: false` + `ciContext.clearCaches()` on `width * height >= 16_000_000`.
   - Preserve `16-bit` (`RGBA16` / `RGBAh`) through orientation/straighten/color stages when source is >8-bit (`cgImage.bitsPerComponent > 8` or `CIRAWFilter` or JXL 16-bit), fixing `ImageCropService.transformOrientation`'s 8-bit truncation.
   - Respect `ImageDimensionCalculator.maxEdgePixels` (`16_384`) and `maxTotalPixels` (`100_000_000`).
5. **Task Cancellation & Stale Result Rejection:**
   - Existing `livePreviewTask?.cancel()` + `try Task.checkCancellation()` + `guard self.primaryURL == url` in `ImageToolboxView` is solid; propagate `Task.checkCancellation()` before expensive LUT builds, Vision calls, and `ciContext.createCGImage` calls, and ensure no heavyweight `CIImage` rendering runs on `@MainActor` (`Task.detached(priority: .userInitiated)` or dedicated worker actor).

### 8.3 Measurable Performance & Memory Acceptance Criteria
- **Interactive Preview Scrubbing Latency:** Median preview update `<= 80 ms` (target `< 50 ms`) at 1200–1600 px proxy resolution across a full Color + Curves + 4-Effect stack on Apple Silicon (verified deterministically in test/benchmark harness).
- **12 MP / 24 MP Full-Res Export:** Completes cleanly without exceeding macOS sandbox memory norms or leaving temp files.
- **50 MP & 100 MP Repeated Processing:** Preserves `Phase422ClosureTests` bounds (`nonVolatileInternalMB` and total footprint stay within `+150 MB` across repeats; `0` retained temp directories; `0` leaked bytes).

---

## 9. RAW Support Feasibility and Limitations

### 9.1 Feasibility with Native `CIRAWFilter`
- **Verified SDK Support:** `CIRAWFilter.supportedCameraModels.count == 917` on the workspace macOS 15 Swift 6 SDK (`arm64`), requiring **zero external libraries** (no LibRaw / dcraw compilation or GPL/LGPL licensing concerns).
- **Capabilities Available Natively in `CIRAWFilter`:**
  - Decode from `URL` (`CIRAWFilter(imageURL:)`) or `Data`.
  - Fast proxy rendering via `scaleFactor` (`0.0...1.0`, e.g., `1200 / max(fullW, fullH)` -> genuine demosaiced RAW preview instead of camera JPEG thumbnail!).
  - Non-destructive sensor-referred adjustments before display gamma: `exposure`, `baselineExposure`, `neutralTemperature`, `neutralTint`, `highlightAmount`, `shadowAmount`, `contrastAmount`, `boostAmount`, `boostShadowAmount`, `luminanceNoiseReductionAmount`, `colorNoiseReductionAmount`, `noiseReductionSharpnessAmount`, `isGamutMappingEnabled`.
  - Linear/wide-gamut extended color output directly feeding the downstream `CIImage` color/curves/effects DAG at 16-bit/float precision (`RGBAh` -> 16-bit PNG/TIFF/JXL or tone-mapped 8-bit JPG/HEIC/WebP).

### 9.2 Concrete Limitations & Honest Disclosures (Must Not Overpromise)
- **Format Coverage Scope:** `CIRAWFilter` supports **camera models supported by Apple's macOS Camera RAW framework** (standard Adobe DNG, Canon CR2/CR3, Nikon NEF/NRW, Sony ARW, Fujifilm RAF, Olympus ORF, Panasonic RW2, etc. within Apple's supported list — notably some compressed Fuji/Sony variants, newest unreleased camera bodies, or CinemaDNG/dual-pixel proprietary frames may fail `CIRAWFilter(imageURL:)` or return `nil`).
- **Fallback Behavior:** If `CIRAWFilter(imageURL:)` returns `nil` or produces nil `outputImage`, fall back gracefully to `CGImageSource` decode + explicit user-facing warning banner (`"Extended RAW controls unavailable for this camera profile; decoded via standard ImageIO fallback."`).
- **Memory & Speed:** Full-res 45–100 MP RAW demosaicing (`scaleFactor = 1.0`) takes significantly more CPU/GPU time and unified memory than JPEG decode; therefore proxy `scaleFactor` is essential for UI scrubbing, and full-res demosaic must clear `CIContext` caches immediately on `>= 16 MP`.
- **RAW Container Export:** RAW formats remain **read-only inputs** (non-destructive source); exports target raster formats (`JXL 16-bit`, `TIFF 16-bit`, `PNG 16-bit`, `HEIC`, `AVIF`, `JPG`, `WebP`, etc.).

---

## 10. Test Strategy

Separate tests by scope matching LocalConvert's Swift Testing (`@Suite` / `@Test`) structure:

### 10.1 Unit Tests (Fast, Deterministic, Synthetic `CGImage` / `Data`)
- **Color & Tone Math (`ImageColorAdjustmentsTests`):** Verify Exposure (+1/-1 EV increases/decreases mean luminance), Brightness/Contrast/Gamma monotonicity, Saturation=0 yields grayscale (`R==G==B`), Temperature warm increases R/B ratio, Highlights/Shadows selectively move high/low quantiles, Levels clipping clamps black/white points, Master & RGB Spline Curves preserve endpoints & alpha channel unchanged, Hue 360° ≈ identity, Bypass / `isEnabled == false` yields exact match.
- **Effects Stack (`ImageEffectsChainTests`):** Verify order-dependence (e.g., Sepia vs Blur vs Vignette vs Sharpen permutations produce distinct reproducible outputs matching expected transforms), Blur smoothness (`variance` decrease), Vignette corner luminance < center luminance, Monochrome/Sepia outputs, Noise Reduction & Unsharp Mask bounds, Film Grain reproducibility/luma preservation, individual & global reset.
- **Coordinate & Straighten Math (`ImageGeometryProTests`):** Verify arbitrary straighten angle (`±15°`, `±45°`) inscribed rectangle computation has zero transparent boundary pixels when `autoCropOnStraighten == true`; verify 16-bit bit-depth preservation across `90°/180°/270°` + Flip + Crop (`ImageCropService` fix verification); verify top-left normalized coords -> Core Image bottom-left pixel coords alignment.

### 10.2 Integration Tests (`LocalConvertTests`, End-to-End File I/O & Undo)
- **Undo/Redo & Coalescing:** Extend `Phase43ImagePDFUndoTests` (or add `Phase46ImageStudioUndoTests`) testing Color/Effects/RAW/Straighten slider coalescing (`beginContinuousEdit`/`endContinuousEdit` -> 1 step), stack reorder/toggle/reset Undo/Redo, multi-file preset apply, `.lcimg` project save/reopen + backward-compatible decode of v1 `ImageToolboxConfig`, restart rehydration (`ImageToolboxUndoRehydrator`), and zero large bitmap bloat in `journal.json`.
- **RAW & Color Space / Alpha / Metadata Fidelity:** Verify synthetic 16-bit DNG or ImageIO-supported test DNG (`CIRAWFilter`) when available (gracefully structured with real synthetic DNG/RAW fixture generation or TIFF/EXR fallback + skip-free explicit diagnostic if proprietary body RAW unavailable), Display P3 -> sRGB preservation, alpha preservation across color + blur + vignette + crop, EXIF/GPS privacy policy preserved across full `CIImage` export pipeline.

### 10.3 Performance & Memory Tests
- **Interactive Proxy & Cache Bounds:** Verify `ImagePreviewProxyCache` stays strictly within `<= 64 MB` budget across >10 high-res images and evicts cleanly; verify `processInMemory` interactive adjustment render completes cleanly (`< 150 ms` average on Debug `arm64` per slider tick on 12–24 MP source via cached proxy).
- **Large-Image Parity:** Confirm existing `Phase422ClosureTests` (50 MP / 100 MP bounded memory & zero leaked temp artifacts) passes alongside a new 50 MP Color + Curves + Vignette + Unsharp Mask export check ensuring `CIContext` cache clearing keeps memory flat across repeated passes.

### 10.4 GUI & Accessibility Acceptance Checklist (Manual Verification Scope)
- Split/Side-by-Side/Hold-to-Compare toggle during Color/Effects/Crop editing; Zoom/Pan precision while dragging Crop & Straighten overlay; VoiceOver accessibility labels & values on all sliders, curves, preset cards, and RAW controls; `Cmd+Z` / `Shift+Cmd+Z` respecting active `TextField` focus (`UndoMenuController`).

---

## 11. Dependency Assessment

- **New External Dependencies Required:** **None.**
- Existing bundled binaries (`ffmpeg`/`ffprobe`, `libjxl v0.13.0`, `libwebp`, `libsharpyuv`) and system frameworks (`CoreImage`, `CoreGraphics`, `ImageIO`, `Accelerate`, `Vision`, `UniformTypeIdentifiers`, `AppKit`, `SwiftUI`) cover 100% of proposed Phase 46 requirements cleanly on `macOS 15.0+` `arm64`.
- `project.yml` requires **no new framework linkage or dependency entries**, only `xcodegen generate` when new `.swift` files are added.

---

## 12. Risks and Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **Slider lag from disk re-decode & codec re-encode on every drag** | High (current behavior) | High | Introduce `ImagePreviewProxyCache` (`<= 64 MB`) + separate interactive visual `CIImage` preview path from on-demand codec byte encoding. |
| **16-bit truncation in existing `ImageCropService.transformOrientation`** | Confirmed | Medium | Replace hardcoded `bitsPerComponent: 8` with `CIImage.oriented`/16-bit `CGContext` helper and fuse into unified `CIImage` graph. |
| **Coordinate mismatch when combining Rotation + Straighten + Crop + Perspective** | Medium | High | Enforce single canonical transform order (`Orientation → Straighten + Inscribed Clamp → User Crop → Shape Mask → Perspective`) and compute live crop overlay dims from post-straighten inscribed bounds. |
| **Excess VRAM / IOSurface spikes when running Color + Curves + Blur + Upscale on 50–100 MP images** | Medium | High | Keep `.cacheIntermediates: false`, fuse adjustments in single `CIImage` DAG, render inside `autoreleasepool`, call `ciContext.clearCaches()` at `>= 16 MP`, cache Vision masks. |
| **Camera-specific RAW decode failure in `CIRAWFilter`** | Medium | Medium | Detect nil `CIRAWFilter` cleanly, fall back to ImageIO decoding with explicit warning banner; avoid claiming support beyond Apple's Camera RAW framework. |
| **UI clutter across 11+ sidebar sections & Swift 6 concurrency regressions** | Medium | Medium | Organize new controls cleanly under `.adjustments` ("Color & Light"), `.effects` ("Effects & Looks"), and conditional RAW card / section; enforce `@MainActor` UI vs `Sendable` / actor background processing cleanly under `SWIFT_STRICT_CONCURRENCY: complete`. |

---

## 13. Sequential Implementation Milestones

Ordered to establish core data/rendering foundations first, avoid rework, and validate incrementally:

- **Milestone 46.1 — Non-Destructive Adjustment Model, Proxy Cache & Unified `CIImage` Render Graph** *(Foundation)*
  - Define color, levels, curves LUT, color balance, ordered `ImageEffectSlot`, straighten, and `ImageRAWDevelopConfig` Codable models in `ImageToolboxConfig` (preserving backward-compatible decoding).
  - Fix 16-bit precision in `ImageCropService.transformOrientation`.
  - Build `ImageAdjustmentsEngine` (`CIImage` DAG evaluator + spline curve LUT generator) & `ImagePreviewProxyCache` (`64 MB` LRU proxy + Vision mask cache) inside `ImageProcessingService`, separating fast visual preview from codec byte preview.
  - **Depends on:** Audit only.
- **Milestone 46.2 — Advanced Color Editing UI & Live Histogram Integration**
  - Add `"Color & Light"` sidebar section (`ImageToolboxSection.adjustments`) with Exposure, Brightness, Contrast, Saturation, Gamma, Temperature/Tint, Highlights/Shadows, Whites/Blacks, Hue, Vibrance, Levels sliders, interactive Master/RGB Tone Curve editor, Shadows/Midtones/Highlights Color Balance controls, A/B bypass toggle, per-group reset, and live updated Histogram preview.
  - **Depends on:** 46.1 (`ImageAdjustmentsEngine` + fast proxy render).
- **Milestone 46.3 — Ordered Effects Chain, Creative Filters & Presets Workflow**
  - Add `"Effects & Looks"` section (`ImageToolboxSection.effects`) with ordered `effectStack` UI (add/enable/disable/reorder/remove/reset for Gaussian Blur, Sharpen, Unsharp Mask, Noise Reduction, Vignette, Film Grain, Monochrome, Sepia, Photo Filters/Tint).
  - Build `ImageEffectPresetCatalog` (curated built-in Look Presets + Saved User Presets browser directly inside `ImageToolboxView`) supporting single-click preview, non-destructive apply (preserving or optionally keeping target export format), and multi-image batch apply across `selectedFiles`.
  - **Depends on:** 46.1, 46.2.
- **Milestone 46.4 — Geometry Pro: Continuous Straightening, Auto-Horizon & Unified Live Crop Canvas**
  - Extend `ImageCropAndTransformConfig` and `ImageCropEditorView` with `-45°...+45°` Straighten slider, Vision `VNDetectHorizonRequest` Auto-Straighten button, inscribed auto-crop math (guaranteeing zero transparent corner wedges), and optional preview of active Color/Effect edits inside the Crop viewport + explicit continuous-drag Undo coalescing.
  - **Depends on:** 46.1.
- **Milestone 46.5 — Native Camera RAW (`CIRAWFilter`) Develop Pipeline**
  - Integrate `CIRAWFilter` decoding (`scaleFactor` proxy for interactive preview, full resolution for export) with fallback to `CGImageSource` + warning disclosure, plus conditional `"RAW Develop"` controls card (`Exposure`, `Temp/Tint`, `Highlights/Shadows`, `Boost`, `Luma/Color NR`, `Sharpness`, `Gamut Mapping`) shown cleanly when a RAW input is loaded.
  - **Depends on:** 46.1, 46.2.
- **Milestone 46.6 — Undo/Redo Tightening, `.lcimg` Project Persistence & Large-Image Hardening**
  - Wire explicit `beginContinuousEdit` / `endContinuousEdit` across all sliders/curves/crop drags; extend `ImageToolboxStore.classifyChange` & add `.lcimg` project save/load (with path-safety + missing-source relinking).
  - Verify 12/24/50/100 MP peak memory stability, cancellation, alpha/ICC/EXIF integrity, run focused Phase 46 suites + full `LocalConvertTests` arm64 regression with `0` Swift 6 warnings, and publish final acceptance report.
  - **Depends on:** 46.1 – 46.5.

---

## 14. File-Level Change Plan

### Proposed New Files
| Path | Layer | Responsibility |
|---|---|---|
| `LocalConvert/Engines/Image/ImageAdjustmentModels.swift` | Engine | Codable non-destructive models: `ImageColorAdjustmentsConfig`, `ImageLevelsConfig`, `ImageCurvesConfig`, `ImageColorBalanceConfig`, `ImageEffectKind`/`ImageEffectSlot`, `ImageRAWDevelopConfig`, `ImageLookPreset`, `ImageProjectDocument` (`.lcimg`). |
| `LocalConvert/Engines/Image/ImageAdjustmentsEngine.swift` | Engine | Pure `CIImage` DAG builder (`applyColorAdjustments`, spline 1D/3D `CIColorCube` LUT builder for Levels/Curves/Balance, ordered `effectStack` evaluator, `applyStraightenAndInscribedCrop`, `CIRAWFilter` loader + fallback). |
| `LocalConvert/Engines/Image/ImagePreviewProxyCache.swift` | Engine | Bounded 64 MB LRU `actor` caching decoded preview proxies and Vision cutout masks keyed by URL + mtime + geometry. |
| `LocalConvert/Engines/Image/ImagePresetCatalog.swift` | Engine | Built-in curated Image Editor Look Presets + `.lcimg` atomic persistence & relinking helper. |
| `LocalConvert/Features/ImageToolbox/ImageColorAdjustmentsView.swift` | UI | SwiftUI controls for Exposure/Light, Color, White Balance, Levels, interactive Master/RGB Tone Curves Canvas, Color Balance, bypass/reset, and live Histogram strip. |
| `LocalConvert/Features/ImageToolbox/ImageEffectsChainView.swift` | UI | Ordered effects stack inspector, effect parameter sliders, Look Presets picker/batch apply, and RAW Develop conditional card (`ImageRAWDevelopCardView`). |
| `LocalConvertTests/ImageAdjustmentsAndEffectsTests.swift` | Tests | Unit tests for color math, curves LUTs, levels, effect ordering, geometry/straighten inscribed math, 16-bit orientation fix, and RAW `CIRAWFilter` + fallback. |
| `LocalConvertTests/Phase46ImageEditorIntegrationTests.swift` | Tests | End-to-end tests for non-destructive export (alpha/ICC/EXIF), Undo/Redo slider coalescing, restart rehydration, `.lcimg` roundtrip, proxy cache bounds, and 50 MP memory stability. |

### Existing Files to Modify (Scoped)
| Path | Responsibility of Change |
|---|---|
| `LocalConvert/Engines/Image/ImageToolboxModels.swift` | Add `adjustments`, `effects`, `rawDevelop`, `straightenDegrees` + backward-compatible `Codable` decoding on `ImageToolboxConfig`; update `ImageDimensionCalculator` for straighten inscribed dims; add `.adjustments` and `.effects` cases to `ImageToolboxSection`. |
| `LocalConvert/Engines/Image/ImageCropService.swift` | Preserve 16-bit depth in `transformOrientation`, add `applyStraighten` & inscribed crop helper (`VNDetectHorizonRequest` integration). |
| `LocalConvert/Engines/Image/ImageProcessingService.swift` | Integrate `ImagePreviewProxyCache`, `ImageAdjustmentsEngine` lazy `CIImage` DAG, `CIRAWFilter` input handling, fast visual preview mode vs codec encode mode, and Vision mask caching. |
| `LocalConvert/Core/UndoRedo/ImageToolboxUndoCommands.swift` | Update `ImageToolboxStore.classifyChange` for Phase 46 adjustment/effect/RAW/straighten/preset operations; add helpers for `resetSection`, effect slot CRUD, and batch preset apply with Undo grouping. |
| `LocalConvert/Features/ImageToolbox/ImageToolboxView.swift` | Route `.adjustments` and `.effects` sections; split visual live preview vs codec compression preview mode; add quick `"Hold to Compare Original"` & Preset browser triggers; add `.lcimg` save/open menu. |
| `LocalConvert/Features/ImageToolbox/ImageCropEditorView.swift` | Add Straighten angle slider/dial (`-45°...45°`), `"Auto Horizon"` button, explicit `beginContinuousEdit`/`endContinuousEdit` on drags, and reflect post-straighten dimensions accurately. |
| `LocalConvert/Features/ImageToolbox/ImageLivePreviewCanvas.swift` | Add `"Hold Before"` A/B quick toggle button in toolbar for effortless comparison during color/effect editing. |
| `LocalConvert/Features/ImageToolbox/ImageToolboxOperationsViews.swift` | Wire explicit `beginContinuousEdit`/`endContinuousEdit` on existing quality/sharpen/edge sliders (`onEditingChanged`) for rock-solid Undo coalescing. |

---

## 15. Acceptance Criteria for Completed Phase 46

1. **Feature Completeness:** All target Color Adjustments (Exposure, Brightness, Contrast, Saturation, Gamma, Temperature/Tint, Highlights/Shadows, Whites/Blacks, Levels, Master & RGB Curves, Hue, Vibrance, Color Balance), Effects & Ordered Chains (Blur, Sharpen, Unsharp Mask, NR, Vignette, Grain, Monochrome, Sepia, Photo Filters), Continuous Straightening (`-45°...+45°` w/ auto-inscribe & horizon detect), Native RAW Develop (`CIRAWFilter` + graceful fallback warning), Built-in & User Look Presets (single & multi-image batch apply), and `.lcimg` project save/reopen are implemented and accessible in `ImageToolboxView`.
2. **Strict Non-Destructiveness & Parity:** Source files remain bit-for-bit untouched across editing and export (`Overwrite` defaults off); enabling/disabling/reordering/resetting adjustments works non-destructively; preview appearance matches final full-resolution export across sRGB, Display P3, alpha-transparent images, and metadata policies.
3. **16-bit & Format Fidelity:** 16-bit inputs rotated/adjusted/exported to `PNG`/`TIFF`/`JXL 16-bit` retain `>8-bit` precision cleanly without silent 8-bit truncation in orientation or Core Image steps.
4. **Undo/Redo & Restart Safety:** All parameter sliders and crop/curve drags coalesce cleanly (1 drag = 1 Undo entry); `UndoHistory/journal.json` stays compact (config-only, zero pixel dumps) and rehydrates cleanly across restarts; active `TextField` undo isolation stays intact.
5. **Performance & Memory Safety:** Proxy cache stays bounded (`<= 64 MB`), interactive proxy adjustments render smoothly without disk thrashing, and repeated 50 MP / 100 MP runs stay within `<= +150 MB` footprint drift with `0` temp leaks and `0` Swift 6 compiler warnings.
6. **Full Regression Gate:** `xcodegen generate`, all new Phase 46 unit/integration/performance tests, and the entire `LocalConvertTests` arm64 Debug regression pass with **0 failures** and **0 skipped tests**.
