# Phase 35 Report — Image Toolbox Pro & Universal JPEG XL Integration

## Summary

Phase 35 upgrades LocalConvert with native, offline **Universal JPEG XL (`libjxl 0.13.0`)** encoding/decoding support and a dedicated **Image Toolbox Pro (`⌘8`)** workspace built natively in Swift and SwiftUI on macOS 15.0+ (`arm64`, Swift 6 strict concurrency).

Zero Homebrew runtime dependencies were introduced. All `libjxl`, `brotli`, `highway`, and `skcms` libraries are statically linked inside the signed `LocalConvert.app` executable.

---

## 1. Universal JPEG XL (`libjxl 0.13.0`) Architecture

### Static Bundling & Binary Audit
- **Version integrated:** Upstream `libjxl v0.13.0` (with bundled `brotli v1.2.1`, `highway v1.2.0`, and `skcms`).
- **Build configuration:** Apple Silicon `arm64`, `CMAKE_OSX_DEPLOYMENT_TARGET=15.0`, static archives (`BUILD_SHARED_LIBS=OFF`), `JPEGXL_ENABLE_SKCMS=ON`, `JPEGXL_ENABLE_TRANSCODE_JPEG=ON`, `JPEGXL_ENABLE_BOXES=ON`.
- **Static archives bundled under `LocalConvert/Frameworks/`:**
  - `libjxl.a`
  - `libjxl_threads.a`
  - `libjxl_cms.a`
  - `libhwy.a`
  - `libbrotlienc.a`
  - `libbrotlidec.a`
  - `libbrotlicommon.a`
  - C headers under `LocalConvert/Frameworks/include/jxl/`
- **Legal attribution:** `LocalConvert/Frameworks/LICENSE.jxl` and `LocalConvert/Resources/THIRD_PARTY_NOTICES.md` updated.

### Codec Bridge & Application Wiring
- **ObjC++/C Bridge:** `LocalConvert/Engines/JXL/Bridge/JXLBridge.h` and `JXLBridge.mm` (bridged via `LocalConvert/LocalConvert-Bridging-Header.h`).
- **Swift Codec:** `LocalConvert/Engines/JXL/JPEGXLCodec.swift` providing:
  - Signature validation, inspection (`JXLImageMetadataInfo`), multi-frame decode (8-bit and 16-bit), straight/premultiplied alpha handling.
  - Single-frame and multi-frame animated JXL encoding (`lossy`, `lossless`, compression `effort` `1..9`, explicit Butteraugli `distance`, `8`/`16`-bit channel precision).
  - Lossless `JPEG -> JXL` bitstream transcoding (`JxlEncoderAddJPEGFrame`) and bit-exact `JXL -> JPEG` bitstream reconstruction (`isJPEGReconstructable` verification).
  - ISO BMFF container `Exif` (with 4-byte TIFF offset box header) and `xml ` (XMP) box read/write and embedded ICC color profile round-tripping.
- **Registries & Metadata:**
  - `FormatCapabilityRegistry`: `.jxl` upgraded from read-only to `canRead = true`, `canWrite = true`, `multiPage = true`, `animation = true`, `transparency = true`.
  - `ConversionRegistry`: `image_toolbox == "true"` enables non-destructive same-format Image Toolbox processing routes (`X -> X`), while preserving standard duplicate-route safety in default conversion mode.
  - `ImageMetadataProvider`: Reads/writes JXL `Exif`/`xml ` container boxes losslessly via `SafeMetadataWriter` container rewrite without re-encoding image pixels, and deletes cleared metadata keys on privacy scrubs.
  - `ImageConversionEngine` & `ImageProcessor`: Supports `* <-> JXL`, `JPEG <-> JXL` lossless transcode/reconstruct, `GIF/APNG <-> Animated JXL`, JXL quality search in target file size optimization, and JXL size estimation.

---

## 2. Image Toolbox Pro (`⌘8`) Subsystems

Modular backend services (`LocalConvert/Engines/Image/`):
1. `ImageToolboxModels.swift`: Configuration, telemetry, compression profiles, privacy policies, watermark, crop, and Vision background removal specs (`Sendable`, `Codable`, round-tripping via `ConversionOptions` and `SavedPreset`).
2. `ImageProcessingService.swift`: Unified non-destructive pipeline (in-memory preview benchmarking & file/multi-size export).
3. `ImageResizeService.swift`: Exact dimensions, percentage, max width/height, fit-inside, fill (crop-to-fit), resampling modes (`Nearest`, `Bilinear`, `Bicubic` via `CIBicubicScaleTransform`, `Lanczos` via `CILanczosScaleTransform`), post-resize `CISharpenLuminance`, and multi-size preset batch export.
4. `ImageCropService.swift`: Aspect ratio crop, normalized custom rectangle crop, custom pixel dimensions, 9-anchor positioning, `90°`/`180°`/`270°` rotation, horizontal/vertical mirror.
5. `ImageColorManagementService.swift`: Live ICC inspection (profile name, model, bit depth, alpha, byte size, wide-gamut detection) plus `sRGB IEC61966-2.1` and `Display P3` conversion.
6. `ImageWatermarkService.swift`: 9-anchor positioned and tiled grid overlays for both styled text and logo images (`PNG`/`SVG`/`JXL`/raster) with opacity, scale, margin, and rotation.
7. `ImageMetadataService.swift`: Privacy audit + 1-click GPS/camera/author/full metadata scrub and inline editor across both ImageIO formats and JXL containers.
8. `ImageBackgroundRemovalService.swift`: Apple `Vision` (`VNGenerateForegroundInstanceMaskRequest`) foreground segmentation with feathered edge refinement, transparent or solid color replacement, and automatic alpha-strip warnings when targeting non-alpha containers.
9. `ImageComparisonService.swift`: Encodes the actual configured output in memory for authentic Before/After telemetry and pixel inspection.

Native SwiftUI Views (`LocalConvert/Features/ImageToolbox/`):
- `ImageToolboxView.swift` (`⌘8`, sidebar section router with configured badges, multi-file queue selector, live inspection header, preset popover, batch `ConversionQueue` export).
- `ImageToolboxOperationsViews.swift` (Convert & JXL Codec, Resize & Multi-Size, Crop & Rotate, Optimize File Size, Compression Profiles, Watermark, Color Management, Background Removal).
- `ImageComparisonView.swift` (Split-slider draggable curtain & side-by-side mode, `50%..400%` zoom & pan, encoded telemetry banner).
- `ImageMetadataPrivacyView.swift` (Privacy audit badges, 1-click scrub actions, field editor, save copy or in-place apply).
- `AppState+ImageToolbox.swift` (`executeImageToolbox` & `saveImageToolboxPreset`).

---

## 3. Verification Results

- **Dependency audit (`./scripts/verify-dependencies.sh`):** Passed (`libjxl v0.13.0` static archives & headers, `libwebp`, `libsharpyuv`, `FFmpeg 9.0.2`, `LibreOffice 26.8.0.3`, AppIcon metadata).
- **Automated Test Suite (`xcodebuild test`, arm64):**
  - **377 tests across 42 suites passed (0 failures)** after the final code edit (`Phase35Tests` + updated JXL read/write & tab-count assertions in `Phase18Tests`, `Phase19Tests`, `Phase20Tests`, `Phase32Tests`).
- **Release `arm64` Build & Binary Audit (`/Applications/LocalConvert.app`):**
  - `codesign --verify --deep --strict`: `valid on disk`, `satisfies its Designated Requirement`.
  - `otool -L` scan across executable, frameworks, and bundled binaries: **Zero Homebrew runtime dependencies**.
- **Live `/Applications/LocalConvert.app` UI QA:**
  - Launched app with synthetic Display P3 PNG input, opened Image Toolbox Pro via `⌘8`, verified live header inspection telemetry (`160×120 · 8bpc · Display P3`), triggered `Export Image` via UI, and confirmed valid JXL container output on disk (ISO BMFF signature `0000000c4a584c200d0a870a`).

---

## 4. Compatibility Matrix Summary (Phase 35)

| Feature Area | Status | Notes |
|---|---|---|
| JPEG XL Read / Write (`* ↔ JXL`) | **Full** | Lossy, lossless, effort `1..9`, `8`/`16`-bit, alpha, ICC |
| JPEG ↔ JXL Lossless Bitstream Transcode / Reconstruct | **Full** | Byte-identical JPEG restoration when embedded JPEG box exists |
| Animated `GIF / APNG ↔ JXL` | **Full** | Multi-frame decode & encode with frame durations |
| JXL Metadata (`Exif` & XMP `xml ` boxes) | **Full** | Container-level rewrite without re-encoding pixels |
| Batch Resize, Resampling, Multi-Size & Sharpen | **Full** | Nearest / Bilinear / Bicubic / Lanczos + `CISharpenLuminance` |
| Crop, Rotate, Flip & 9-Anchor Framing | **Full** | Fixed ratios, custom rect, pixel dimensions, orientation transforms |
| Target File Size & Compression Profiles | **Full** | Binary/iterative search + honest quality-floor reporting |
| Metadata Privacy Scrub & Edit | **Full** | GPS / Camera / Author / All removal + editing across ImageIO & JXL |
| Text & Logo Image Watermark (Anchored / Tiled) | **Full** | Works across writable raster & JXL outputs |
| Color Management (`Preserve / sRGB / Display P3`) | **Full** | ICC inspection + `CGColorSpace` gamut conversion |
| On-Device Subject Background Removal | **Full** | Apple Vision foreground instance mask (`macOS 15+` Apple Silicon) |
| Interactive Before / After Inspector | **Full** | Uses actual encoded bytes in split-slider & side-by-side zoom modes |
| Raw Camera Output (`.dng`, `.cr2`, `.nef`, `.arw`, etc.) | **Not Supported (Read-Only)** | Intentionally read-only source inputs |
