# Image Optimization, Resize & Crop Architecture

## 1. Overview

LocalConvert provides native, high-performance image optimization, resizing, cropping, and format conversion directly on macOS Apple Silicon without cloud dependencies or external command-line tools.

Image processing in LocalConvert combines:
1. **CoreGraphics & ImageIO** for hardware-accelerated image decoding, orientation normalization, geometric transformations, and standard encoding (JPEG, PNG, HEIC, TIFF, BMP, GIF, AVIF).
2. **Bundled `libwebp` C Bridge** for high-efficiency WebP lossy and lossless encoding.
3. **Bounded Iterative Optimization** for target file size targets without padding.
4. **EXIF-Aware Geometric Transforms** ensuring crop and resize operations occur in true upright orientation.

---

## 2. Core Architecture

```
                                  ┌───────────────────────────────┐
                                  │      ConversionOptions        │
                                  │ (Quality, Size, Resize, Crop) │
                                  └───────────────┬───────────────┘
                                                  │
                                                  ▼
┌───────────────────┐               ┌───────────────────────────┐
│ Input Image File  │ ────────────> │   ImageConversionEngine   │
└───────────────────┘               └─────────────┬─────────────┘
                                                  │
                                                  ▼
                                    ┌───────────────────────────┐
                                    │      ImageProcessor       │
                                    └─────────────┬─────────────┘
                                                  │
                    ┌─────────────────────────────┼─────────────────────────────┐
                    ▼                             ▼                             ▼
         ┌────────────────────┐        ┌────────────────────┐        ┌────────────────────┐
         │     applyCrop      │        │    applyResize     │        │  optimizeForTarget │
         │ (Center/Rect/Aspect│───────>│ (Width/Height/Pct/ │───────>│ (Binary Search     │
         │  Ratio Calculation)│        │  Edge Constraints) │        │  In-Memory Encode) │
         └────────────────────┘        └────────────────────┘        └──────────┬─────────┘
                                                                                │
                                                                                ▼
                                                                     ┌────────────────────┐
                                                                     │ Final Encoded Data │
                                                                     │ (ImageIO / WebP)   │
                                                                     └────────────────────┘
```

---

## 3. Image Optimization Modes

| Optimization Mode | Target Quality | Metadata | Use Case |
| :--- | :--- | :--- | :--- |
| **Balanced** | 80% (0.80) | Preserved / Optional | Default for web & digital sharing |
| **High Quality** | 90% (0.90) | Preserved | High-fidelity photo storage |
| **Maximum Quality** | 95% (0.95) | Preserved | Professional archiving & print prep |
| **Small File** | 55% (0.55) | Stripped | Email attachments, messaging limits |
| **Lossless** | 100% (1.00) | Preserved | PNG, Lossless WebP, TIFF |
| **Target File Size** | Dynamically Fitted | Configurable | Exact byte-budget limits (e.g., ≤ 500 KB) |
| **Custom** | User-defined (0–100%) | Configurable | Manual granular control |

---

## 4. Bounded Target File Size Algorithm

When a user specifies a target file size (e.g. `targetFileSizeBytes = 500_000` for 500 KB), LocalConvert uses an **in-memory bounded binary search** on compression quality:

1. **Upper Bound Check**: The image is first encoded at maximum quality ($Q = 0.95$). If the resulting data is already $\le$ target size, it is returned immediately without artificial padding.
2. **Lower Bound Check**: The image is tested at minimum acceptable quality ($Q = 0.10$). If even $Q = 0.10$ exceeds the target size, the engine honestly returns the lowest quality encoding without throwing a fatal error.
3. **Iterative Convergence**:
   - The search space $[Q_{\min}, Q_{\max}]$ is iteratively bisected ($Q_{\text{mid}} = (Q_{\text{low}} + Q_{\text{high}}) / 2$).
   - A maximum of **6 iterations** is enforced to guarantee bounded execution time ($\approx O(1)$ bounded iterations).
   - If a candidate size is $\le \text{target}$ and within $5\%$ tolerance or if $\Delta Q < 0.03$, search terminates.
   - All intermediate trials are executed purely in RAM via memory destinations without disk I/O churn.

---

## 5. Resize Modes & Interpolation

All resize operations are executed using CoreGraphics high-interpolation bitmap contexts (`interpolationQuality = .high` / Lanczos-bicubic filter):

| Resize Mode | Description | Aspect Ratio Handling |
| :--- | :--- | :--- |
| **None** | Original dimensions preserved | Unaltered |
| **Exact Width** | Scales width to exact pixels | Height scaled proportionally |
| **Exact Height** | Scales height to exact pixels | Width scaled proportionally |
| **Exact Dimensions** | Scales to explicit width $\times$ height | Respects `preserveAspectRatio` flag |
| **Percentage** | Scales dimensions by factor ($0.01 \dots 10.0$) | Proportional |
| **Longest Edge** | Fits image so $\max(W, H) = \text{limit}$ | Proportional |
| **Shortest Edge** | Scales image so $\min(W, H) = \text{limit}$ | Proportional |

**Safety Guard**: Pixel dimensions are strictly clamped between $1\text{px}$ and $16,384\text{px}$ to prevent memory exhaustion and arithmetic overflow.

---

## 6. Crop Operations & Aspect Ratios

Cropping is performed before resizing to allow composition framing:

1. **Center Crop**:
   - Computes target aspect ratio rectangle centered within source dimensions.
   - Retains maximum possible area while conforming to the requested ratio.
2. **Custom Normalized Rect**:
   - Normalized coordinates $(x, y, w, h) \in [0.0, 1.0]$.
   - Safely clamped to image bounds.
3. **Supported Aspect Ratios**:
   - `1:1` Square (Instagram, avatars)
   - `4:3` & `3:4` Standard Photography / Tablets
   - `3:2` & `2:3` 35mm Film / DSLR Photography
   - `16:9` & `9:16` Widescreen Video / Stories / Shorts
   - `Original` & `Freeform`

---

## 7. EXIF Orientation & Metadata Handling

- **Decoding Normalization**: Images with EXIF orientation tags ($2 \dots 8$) are upright-normalized into standard bitmap orientation ($1$).
- **Output Metadata Tagging**: Output dictionary sets `kCGImagePropertyOrientation = 1` and `kCGImagePropertyTIFFOrientation = 1` so downstream viewers do not re-apply rotation.
- **Privacy Stripping**: When `preserveMetadata = false`, all EXIF, GPS, camera serials, and IPTC dictionaries are excluded from output encoding.

---

## 8. Presets & Integration

- **Presets Integration**: Presets like `.web`, `.maximumQuality`, and `.smallFile` automatically configure optimal quality, lossless mode, and metadata preservation settings.
- **History Tracking**: The `HistoryManager` and `HistoryRowView` record `inputSizeBytes` and `outputSizeBytes` and display real-time size reduction percentages (e.g. `2.4 MB → 680 KB (-72%)`).
- **Batch Processing**: Compatible with `ConversionQueue` multi-job dispatch across arbitrary image batches.
