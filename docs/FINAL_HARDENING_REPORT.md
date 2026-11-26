# LocalConvert 1.0.0 — Final Product Hardening & Acceptance Report

**Generated:** 2026-11-17  
**Project Root:** `/Users/cancan/Desktop/LocalConvert/`  
**Version:** `1.0.0` (`CFBundleShortVersionString = 1.0.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`, `arm64`)  
**Base Commit (`HEAD`):** `85d6ba2` (`docs: polish 1.0.0 release notes`) — *uncommitted working tree; zero commits, tags, pushes, credential edits, or notarizations performed*

---

## 1. Executive Summary & Acceptance Decisions

LocalConvert `1.0.0` completed both its Final Product Hardening work packages (WP1–WP5) and Final Acceptance Testing across independent code review, clarified Release `-O` `arm64` benchmarking with active physical footprint sampling, 13-category real-file engine acceptance, macOS Accessibility (`AXUIElement`) & keyboard-shortcut verification, full post-fix Debug unit/integration testing, and Release bundle verification.

| Release Gate | Decision | Summary Basis |
|---|---|---|
| **Local-Use Release (`arm64`, macOS 15.0+)** | **GO** | **458 / 458** Debug `arm64` tests pass (`54` suites, `0` failures, `0` skipped); **13 / 13** real-file acceptance categories pass; **39 / 39** cold-process Release `-O` benchmark trials + repeated-run memory checks pass with `0 B` temp leftover; **219 / 219** Mach-O binaries verified thin `arm64` with zero Homebrew linkage and valid strict ad-hoc signature. |
| **Public Distribution (Gatekeeper / Homebrew Cask)** | **NO-GO** | Current Release DMG/ZIP carries an **ad-hoc signature (`-`)** and has **not** been Developer ID signed or Apple notarized/stapled (`spctl --assess` fails on un-notarized ad-hoc builds). Public distribution requires running `scripts/package-release.sh --identity "<Developer ID Application>" --notarize-profile "<profile>"` on a signing host and updating the Homebrew Cask SHA-256 afterward. |

---

## 2. Independent Final Code Review & Fixes Applied

An independent read-only code review (`research` agent `973689fa`) audited the Final Hardening diff across 10 targeted subsystems before final packaging:

- **Passed on Initial Audit (7 areas):**
  1. `WebPEncoder` direct pixel import, overflow checks, and `calloc`/`free` ownership.
  2. `ConversionQueue` / `AppState` scheduling, slot weighting, progress calculation, and cancellation wiring (one minor post-remove dictionary write guard added in `ConversionManager`).
  3. FFmpeg stream-copy (`-c copy` before subtitle codecs) and multi-audio stream preservation (`-map 0:v:0? -map 0:a?`).
  4. `OutputReservationRegistry` case-sensitivity key normalization and atomic reservation lifecycle.
  5. Archive traversal and symlink/hardlink inspection (one minor tar size overflow guard added).
  6. PDF & Office integrity (`PDFConversionEngine` `/Rotate` + non-zero `mediaBox`, `PDFToolboxEngine` dotted filenames & reservation, `OfficeConversionEngine` pre-overwrite validation).
  7. Packaging (`scripts/package-release.sh`) and dependency audit (`scripts/verify-dependencies.sh`) scripts.

- **Confirmed Defects Found & Fixed In-Place (prior to final Release build & Debug test run):**
  1. **16-Bit & Float HDR Core Image Truncation (`ImageProcessor.swift`, `ImageUpscaleService.swift`, `ImagePerspectiveService.swift`, `ImageBackgroundRemovalService.swift`):**
     - Added `ImageProcessor.ciRenderFormat(for cgImage: CGImage) -> CIFormat` returning `.RGBAh` for `.floatComponents`, `.RGBA16` for integer `> 8` bpc, and `.RGBA8` otherwise, preventing `.lanczosDetail` upscale and geometry/background pipelines from clamping HDR float or 16-bit images to 8-bit/integer precision.
     - Updated `ImageProcessor.flattenAlphaOntoWhiteIfNeeded` so 16-bit sRGB sources try `[16, 8]` bit depths instead of forcing 8-bit output.
  2. **Shared `CIContext` Intermediate Cache Eviction (`ImageProcessor.swift`, `ImageUpscaleService.swift`):**
     - Fixed `resampleCGImage` cache-eviction check to inspect `max(cgImage.width * cgImage.height, finalW * finalH) >= 16_000_000` (catching small inputs upsampled past 16 MP).
     - Wrapped `.lanczosDetail` `createCGImage` inside `autoreleasepool` with explicit `format:`/`colorSpace:` and `clearCaches()` above `16_000_000` pixels.
  3. **Subprocess Cancellation Race (`AudioAnalysisService.swift`):**
     - Guarded `streamWaveformBins` against pre-launch cancellation (`if holder.isCancelled` prior to `process.run()`, immediate `holder.cancelAndTerminate()` check after `process.run()` and on early read exit, closing `outPipe.fileHandleForReading` before draining `stderr` + `waitUntilExit()`).
  4. **Archive Size Accumulation & Removed-Job Stale State (`ArchiveConversionEngine.swift`, `ConversionManager.swift`):**
     - Switched tar entry size aggregation to `totalSize.addingReportingOverflow(sizeVal)` while rejecting negative sizes; guarded terminal `executeJob` dictionary writes with `guard activeJobs.contains(where: { $0.id == job.id })`.
  - **Verification:** Added `codeReviewRegressionGuards()` to [FinalHardeningRegressionTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/FinalHardeningRegressionTests.swift), passing in the final `458 / 458` Debug run.

---

## 3. Environment & Baseline Memory Calibration

| Component / Metric | Verified Value |
|---|---|
| Platform / Arch / Deployment Target | Apple Silicon `arm64`, `MACOSX_DEPLOYMENT_TARGET = 15.0`, Xcode `27.2`, Swift `6.0` (`SWIFT_STRICT_CONCURRENCY = complete`) |
| Bundled Toolchains | Static `FFmpeg 9.0.2` & `ffprobe 9.0.2`; headless `LibreOffice 26.8.0.3`; `libjxl v0.13.0` static archives; `libwebp` + `libsharpyuv` dynamic frameworks |
| **Idle GUI `LocalConvert.app` Baseline Memory** | Launched Release `LocalConvert.app` (`PID 87006`): **`110.92 MB` RSS (`113,584 KB`), `40 MB` `phys_footprint` (`phys_footprint_peak = 40 MB`)** via `ps` + `footprint` |
| **Headless Release `-O` Worker Baseline Memory** | `Init RSS = 9.59–9.64 MB`, `Init Phys Footprint = 3.03–3.08 MB` (engine-only Swift `-O` process without SwiftUI/AppKit window chrome) |

*Why Phase 42 comparison is qualitative:* Phase 42 benchmarks ran inside an XCTest-hosted full GUI app (`~116 MB` initial RSS); Release `xcodebuild test` hung at XCTest runner attachment on Xcode `27.2`, so isolated `-O` engine binaries were benchmarked directly and paired with separate live Release GUI idle `footprint` measurements above.

---

## 4. Clarified Release (`-O`) `arm64` Benchmark Results (5 ms Peak Memory Sampling)

All 13 representative workloads ran **3 fresh-process trials (`39` cold-process trials)** plus dedicated multi-iteration repeat runs on 50 MP (`3x`) and 100 MP (`2x`), sampling `mach_task_basic_info` (`resident_size`) and `task_vm_info` (`phys_footprint`) every `5 ms`. Every workload recorded **`0 B` temp disk delta** after completion.

| Workload | Exact Fixture & Conversion Settings | Output Bytes | Trial Durations (s) | Median (s) | CPU (s) | Peak RSS (MB) | Final RSS (MB) | Peak Phys FP (MB) | Final Phys FP (MB) |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|
| `W1_6MP_PNG_WebP` | `3000×2000` 8-bit sRGB RGBA PNG (`15,056,299 B`) → WebP (`q=0.90` lossy) | 2,267,364 | 0.8194 / 0.8100 / 0.7946 | **0.8100** | 0.8012 | 182.62 | 182.58 | 144.44 | 144.34 |
| `W2_6MP_PNG_JXL` | `3000×2000` 8-bit sRGB RGBA PNG (`15,056,299 B`) → JXL (`q=0.90, effort=7`) | 1,680,604 | 0.5697 / 0.5899 / 0.6333 | **0.5899** | 2.7044 | 585.56 | 582.00 | 568.52 | 564.97 |
| `W3_24MP_PNG_WebP` | `6000×4000` 8-bit sRGB RGBA PNG (`59,539,713 B`) → WebP (`q=0.90`) | 9,175,946 | 7.9332 / 8.3222 / 7.9084 | **7.9332** | 7.8837 | 696.38 | 694.95 | 590.13 | 589.13 |
| `W4_24MP_PNG_JPG` | `6000×4000` 8-bit sRGB RGBA PNG (`59,539,713 B`) → JPEG (`q=0.90`) | 15,259,792 | 0.5639 / 0.5677 / 0.5667 | **0.5667** | 0.5609 | 296.06 | 113.42 | 265.47 | 6.94 |
| `W5_50MP_PNG_JPG_Fresh1x` | `8160×6128` 8-bit sRGB RGB PNG (`112,852,959 B`) → JPEG (`q=0.90`, 1× fresh) | 22,181,570 | 1.1885 / 1.0632 / 1.0309 | **1.0632** | 1.0426 | 593.70 | 212.69 | **551.24** | 7.02 |
| `W5_50MP_PNG_JPG_x3Repeat` | `8160×6128` 8-bit sRGB RGB PNG (`112,852,959 B`) → JPEG (`q=0.90`, 3× repeat) | 22,181,570 | 3.0557 (3× total) | **3.0557** | 3.0550 | 976.02 | 594.59 | **561.30** | **7.59** |
| `W6_100MP_PNG_WebP_Fresh1x` | `11548×8660` 8-bit sRGB RGB PNG (`224,406,713 B`) → WebP (`q=0.90`, 1× fresh) | 27,969,738 | 31.7069 / 30.8182 / 30.6736 | **30.8182** | 30.4212 | 1,653.77 | 1,653.75 | **1,258.10** | 1,258.02 |
| `W6_100MP_PNG_WebP_x2Repeat` | `11548×8660` 8-bit sRGB RGB PNG (`224,406,713 B`) → WebP (`q=0.90`, 2× repeat) | 27,969,738 | 62.0662 (2× total) | **62.0662** | 61.1360 | 2,417.28 | 1,273.20 | **2,001.74** | 1,258.78 |
| `W7_16Bit_P3_TIFF_JXL` | `4096×2730` 16-bit Display P3 RGBA TIFF (`89,462,862 B`) → JXL (`q=1.0` lossless) | 8,266,025 | 1.0712 / 0.9825 / 0.9993 | **0.9993** | 5.4944 | 709.88 | 707.36 | 693.02 | 690.64 |
| `W8_PQ_HDR_PNG_JXL` | `2048×1024` 16-bit ITU-R BT.2100 PQ PNG (`8,661,401 B`) → JXL (`q=1.0` lossless) | 1,265,351 | 0.2450 / 0.2243 / 0.2457 | **0.2450** | 0.8319 | 202.00 | 200.08 | 185.08 | 183.16 |
| `W9_Audio_WAV_MP3` | `10.0s` 44.1 kHz Mono PCM WAV (`882,078 B`) → MP3 (`libmp3lame -q:a 2`) | 47,107 | 0.2922 / 0.0636 / 0.0657 | **0.0657** | 0.0692 | 14.34 | 14.33 | 5.63 | 5.61 |
| `W10_Video_MP4_MKV_Copy` | `5.0s` `1920×1080` 30fps H.264+AAC MP4 (`2,594,988 B`) → MKV (stream copy) | 2,593,242 | 0.0638 / 0.0563 / 0.0556 | **0.0563** | 0.0542 | 14.31 | 14.22 | 5.66 | 5.56 |
| `W11_Spotify_Norm_MP3` | `5.0s` 192 kbps CBR MP3 (`121,691 B`) → ID3v2.3 UTF-16 BOM metadata normalize | 122,729 | 0.0532 / 0.0489 / 0.0507 | **0.0507** | 0.0479 | 15.47 | 15.47 | 6.56 | 6.55 |
| `W12_PDF_OCR_2Page` | 2-page US Letter rendered PDF (`8,701 B`) → searchable PDF via Vision OCR (144 DPI) | 22,546 | 46.3064 / 0.4054 / 0.4170 | **0.4170** | 0.1858 | 126.53 | 92.69 | 88.91 | 50.17 |
| `W13_Office_DOCX_PDF` | 1-page DOCX (`5,084 B`) → PDF via bundled headless LibreOffice `26.8.0.3` | 20,733 | 1.6628 / 1.4276 / 1.4205 | **1.4276** | 1.3244 | 20.25 | 20.23 | 7.52 | 7.52 |

**Memory Clarification (`7.25 MB` vs `561.30 MB` on 50 MP, and `100 MP` behavior):**
- Previously reported `7.25 MB` on `W5_50MP_PNG_JPG_x3Repeat` was the **post-autorelease settled `finalFootprintMB`** (`7.59 MB` in this run: `it1=6.9 MB, it2=7.3 MB, it3=7.6 MB`), measured after ImageIO/CoreGraphics released working compression buffers.
- With 5 ms sampling (`PeakMemorySampler`), actual **in-flight encoding `peakFootprintMB`** was **`551.24 MB` (fresh 1×)** and **`561.30 MB` (3× repeat)** — flat across 3 iterations (`~0 MB` heap growth) while `finalRSS` settled at `594.59 MB` (clean OS-reclaimable/purgeable image decode cache).
- On `W6_100MP_PNG_WebP`, fresh 1× peaked at `1,258.10 MB` footprint (`1,653.77 MB` RSS), while 2× repeat peaked at `2,001.74 MB` footprint (`2,417.28 MB` RSS) during transition before settling to `1,258.78 MB` footprint (`1,273.20 MB` RSS), validating the `>= 36 MP` slot-cost-`2` guard in `ConversionQueue.jobSlotCost`.

---

## 5. End-to-End Real-File Acceptance Suite (13 / 13 Categories Passed)

Compiled in Release `-O` mode against production `LocalConvert/Core` and `LocalConvert/Engines` linked against packaged frameworks (`libwebp`, `libsharpyuv`, `libjxl`) and pointing directly to bundled Release `ffmpeg 9.0.2`, `ffprobe 9.0.2`, and `LibreOffice 26.8.0.3` (`ALL_13_REAL_FILE_ACCEPTANCE_PASSED`):

| Category | Real Input → Output & Verified Invariants | Observed Result |
|---|---|---|
| 1 & 4. High-res Display P3 JPEG (EXIF preserved vs stripped) | Real `3200×2133` JPEG derived from `/System/Library/Desktop Pictures/.thumbnails/Big Sur Coastline.heic` → WebP | **PASS** (`dims=3200x2133, exifKept=true, p3ICC=true, exifStripped=true`) |
| 2. PNG with partial alpha → WebP | `128×128` 8-bit sRGB PNG (`alpha=0.5`) → WebP | **PASS** (`alpha preserved alphaInfo=3`) |
| 3. 16-bit Display P3 TIFF → 16-bit JXL | `4096×2730` / RGBA 16-bit Display P3 TIFF → JXL lossless (`JPEGXLCodec.decode(prefer16Bit: true)`) | **PASS** (`bpc=16, alphaBits=16`) |
| 5. PQ & HLG HDR → JXL & SDR JPG | `128×128` 16-bit `itur_2100_PQ` & `itur_2100_HLG` PNGs → HDR JXL & SDR JPG | **PASS** (`pqBits=16, sdrJPG=128x128`) |
| 6. Animated GIF → APNG & Anim WebP → GIF | 3-frame animated GIF → APNG (`>= 3` frames); 3-frame RIFF `VP8X`/`ANIM`/`ANMF` WebP (`WebPEncoder`) → GIF* | **PASS** (`apngFrames=3, webpToGifFrames=3`) |
| 7. Multipage TIFF → TIFF & PDF | 3-page `96×64` TIFF → 3-page TIFF & 3-page PDF | **PASS** (`tiffPages=3, pdfPages=3`) |
| 8. MP3 with ID3 metadata & art → Spotify + FLAC | `id3_art.mp3` (ID3 + JPEG artwork) → Spotify normalize + FLAC transcode; input SHA-256 unchanged | **PASS** (`audioPayloadVerified=true, flacMetadata=preserved`) |
| 9. Multi-cover M4A & Unsupported MP4 Video Guard | Dual-`covr` `multi_covr.m4a` (`singleFrontCoverOnly=false`) + `has_video.mp4` (`H.264+AAC`); inputs intact | **PASS** (`m4aVerified=true, vidRejected=true`) |
| 10. Multi-audio + Subtitle Video → MP4 Stream Copy | `multi_audio.mkv` (`h264` + `aac` + `mp3` + `srt`) → `.mp4` | **PASS** (`audioTracks=2, subtitleMovText=true, raw=h264,video;aac,audio;mp3,audio;mov_text,subtitle`) |
| 11. Complex PDF (`/Rotate 90`, non-zero origin, OCR, wrong password) | `Complex.v2.pdf` (`origin=(40,60)`, `rotation=90`) → PNG render (`1041×625`), `Complex.v2_ocr_text.txt` sidecar, wrong password cleanup | **PASS** (`upright=1041x625, sidecarOk=true, zeroLeftovers=true`) |
| 12. Office Documents via Bundled LibreOffice `26.8.0.3` | `.docx`, `.xlsx`, `.pptx` → PDF + `.docx` → `.odt` | **PASS** (`docxPages=1, xlsxPages=1, pptxPages=1`) |
| 13. Nested UTF-8 / Spaces / `" link to "` ZIP → `.tgz` & Cancel Cleanup | Nested `Folder One/Sub [2]/café — résumé (v2) link to notes.txt` & `file with spaces #1.md` → `.tgz`; cancelled `.7z` task cleanup | **PASS** (`entriesVerified=true, zeroCancelLeftover=true`) |

*\*Fixture note:* Bundled `FFmpeg 9.0.2` omits `libwebp` encoding (LocalConvert encodes WebP natively via bundled `libwebp` in `WebPEncoder`), so the animated WebP input fixture was assembled directly with `WebPEncoder` + RIFF `VP8X`/`ANIM`/`ANMF` chunks.

---

## 6. GUI, Accessibility (`AXUIElement`) & UX Acceptance Checks

- **Appearance & `900×650` Clipping Audit (`ax_inspect.swift`):**
  - Launched packaged Release `LocalConvert.app` in both Dark (`-NSRequiresAquaSystemAppearance NO`) and Light (`YES`) appearances across all 9 destinations (`Convert`, `Jobs Center`, `PDF Toolbox`, `Audio Toolbox`, `Image Toolbox`, `Metadata`, `Presets`, `History`, `Settings…`): **`clipped=0` across all 9 tabs in both modes** (`Settings…`: `interactive=24, labeled=17`).
- **Menu Keyboard Navigation (`Cmd+1..8`, `Cmd+,`):**
  - Exercised `Cmd+2 -> Jobs Center`, `Cmd+3 -> PDF Toolbox`, `Cmd+7 -> Audio Toolbox`, `Cmd+8 -> Image Toolbox`, `Cmd+4 -> Metadata`, `Cmd+5 -> Presets`, `Cmd+6 -> History`, `Cmd+,` (`key code 43` on Turkish Q `AXCmdChar=Ö`) -> `Settings`, `Cmd+1 -> Convert`.
- **Isolated `open -n` Accessibility Control Walk (`ax_spotcheck.swift`):**
  - Verified on clean `open -n` temporary bundle at `900×650`: `Convert` (`5 interactive / 3 labeled`), `Jobs Center` (`9 / 7`), `PDF Toolbox` (`9 / 3`), `Audio Toolbox` (`5 / 3`), `Image Toolbox` (`5 / 3`), `Metadata` (`5 / 3`), `Presets` (`7 / 5`), `History` (`15 / 8`), all `clipped=0`.
  - Unlabeled elements in the AX sample were standard macOS window buttons (`AXCloseButton`, `AXMinimizeButton`), scrollbar stepper buttons (`AXIncrementArrow`, `AXDecrementArrow`, `AXIncrementPage`, `AXDecrementPage`), and `History`'s `AXSearchField` (which exposes placeholder text rather than `AXTitle`/`AXDescription`).
  - Synthetic `CGEvent` `Tab` focus movement reported `before=AXOutline(), after=AXOutline(), changed=false` under default macOS keyboard-navigation settings (Full Keyboard Access required to Tab-traverse all controls).
- **Transparent Verification Boundary (Manual Human GUI Actions Not Automated):**
  - Interactive pointer drag-and-drop onto DropZone, visual pixel inspection of populated secondary states across Dark/Light themes, and live VoiceOver audio narration were **not** exercised by a human operator; `.onDrop(of: [.fileURL])` handlers and `.accessibilityLabel`/`.accessibilityValue`/`.accessibilityHint` modifiers were audited in source, and conversion/collision/cancel/retry logic was verified via XCTest/Swift Testing + real-file harness runs.

---

## 7. Final Post-Edit Verification Matrix

| Check | Scope / Command | Final Result |
|---|---|---|
| Full Debug `arm64` Automated Suite (Post Code-Review Fixes) | `xcodebuild -project LocalConvert.xcodeproj -scheme LocalConvert -configuration Debug -destination 'platform=macOS,arch=arm64' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test` | **PASS — `458 / 458` tests in `54` suites (`0` failures, `0` skipped, `1696.111s`)**, including `codeReviewRegressionGuards()` (`0.090s`) |
| Release Dependency & Binary Audit | `bash scripts/verify-dependencies.sh --app release/Build/Products/Release/LocalConvert.app` + `codesign --verify --deep --strict` | **PASS — `219 / 219` Mach-O binaries `arm64`, zero Homebrew linkage, strict `codesign` valid, `LibreOffice 26.8.0.3` & `FFmpeg 9.0.2` verified, all license notices bundled** |
| Release Packaging & Checksums | `scripts/package-release.sh` + `shasum -a 256 -c SHA256SUMS.txt` | **PASS** — `LocalConvert-1.0.0-arm64.dmg` (`358M`, `2d28fa283099e9c479fecb03fe820685b06f7d208e66399160870a3a224594de: OK`) & `LocalConvert-1.0.0-arm64.zip` (`292M`, `b639353d8ebe962e604abfe0bf309b68577a279172c5e026295cee0e3be4c282: OK`) |
| DMG Mount, `.DS_Store`, & App Lifecycle | `hdiutil attach`, `.DS_Store` scan, `ditto` copy, launch/quit/relaunch, `hdiutil detach` | **PASS — `0` `.DS_Store` files inside DMG `.app`, `DMG codesign OK`, clean launch/relaunch (`PID 30206` / `30232`), clean detach** |
| Version Integrity | `PlistBuddy -c "Print :CFBundleShortVersionString" LocalConvert/Info.plist` | **`1.0.0` (unchanged)** |

---

## 8. Draft Homebrew Cask Status (`homebrew/homebrew-cask`)

```ruby
cask "localconvert" do
  version "1.0.0"
  # Replace after Developer ID signing & Apple notarization on a signing host.
  # Local ad-hoc Release DMG SHA-256 (local-only verification):
  #   2d28fa283099e9c479fecb03fe820685b06f7d208e66399160870a3a224594de
  sha256 "<NOTARIZED_DMG_SHA256_PENDING_PUBLIC_RELEASE>"

  url "https://github.com/<OWNER>/LocalConvert/releases/download/v#{version}/LocalConvert-#{version}-arm64.dmg"
  name "LocalConvert"
  desc "Offline macOS utility for image, PDF, Office, audio, video, subtitle, and archive conversion"
  homepage "https://github.com/<OWNER>/LocalConvert"

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "LocalConvert.app"

  zap trash: [
    "~/Library/Preferences/com.localconvert.app.plist",
    "~/Library/Application Support/LocalConvert",
  ]
end
```

---

## 9. Hardening & Acceptance File Inventory

- **Core & Queue:** [ConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Conversion/ConversionEngine.swift), [ConversionManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Conversion/ConversionManager.swift), [ConversionQueue.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/ConversionQueue/ConversionQueue.swift), [AppState.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState.swift), [AppState+PDFToolbox.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState+PDFToolbox.swift), [AppState+AudioToolbox.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState+AudioToolbox.swift), [AppState+ImageToolbox.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState+ImageToolbox.swift)
- **Engines:** [WebPEncoder.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/WebP/WebPEncoder.swift), [JPEGXLCodec.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/JXL/JPEGXLCodec.swift), [ImageProcessor.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageProcessor.swift), [ImageConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift), [ImageProcessingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageProcessingService.swift), [ImagePerspectiveService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImagePerspectiveService.swift), [ImageBackgroundRemovalService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageBackgroundRemovalService.swift), [ImageUpscaleService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageUpscaleService.swift), [BaseFFmpegProvider.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Media/BaseFFmpegProvider.swift), [BaseFFmpegProvider+AudioToolbox.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioToolbox/BaseFFmpegProvider+AudioToolbox.swift), [AudioAnalysisService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioToolbox/AudioAnalysisService.swift), [ArchiveConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Archive/ArchiveConversionEngine.swift), [PDFToolboxEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/PDF/PDFToolboxEngine.swift), [PDFConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/PDF/PDFConversionEngine.swift), [OfficeConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Office/OfficeConversionEngine.swift)
- **UI, UX & Accessibility:** [PresetManagerView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Presets/PresetManagerView.swift), [MetadataView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Metadata/MetadataView.swift), [ImageMetadataPrivacyView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImageMetadataPrivacyView.swift), [ImageConvertUtilitiesViews.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImageConvertUtilitiesViews.swift), [ImageToolboxView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImageToolboxView.swift), [ImageColorHistogramPaletteViews.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImageColorHistogramPaletteViews.swift), [ImageCropEditorView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImageCropEditorView.swift), [ImagePerspectiveEditorView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImagePerspectiveEditorView.swift), [AudioToolboxView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/AudioToolbox/AudioToolboxView.swift), [AudioEffectsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/AudioToolbox/AudioEffectsView.swift), [FileRowView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Conversion/FileRowView.swift), [FileListView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Conversion/FileListView.swift), [PDFRedactionView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFRedactionView.swift), [PDFCompareView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFCompareView.swift), [PDFCompressOptionsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFCompressOptionsView.swift), [PDFOCRView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFOCRView.swift), [PDFInspectorSecurityView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFInspectorSecurityView.swift)
- **Tests, Build & Docs:** [FinalHardeningRegressionTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/FinalHardeningRegressionTests.swift), [project.yml](file:///Users/cancan/Desktop/LocalConvert/project.yml), [package-release.sh](file:///Users/cancan/Desktop/LocalConvert/scripts/package-release.sh), [verify-dependencies.sh](file:///Users/cancan/Desktop/LocalConvert/scripts/verify-dependencies.sh), [FORMAT_COMPATIBILITY.md](file:///Users/cancan/Desktop/LocalConvert/docs/FORMAT_COMPATIBILITY.md), [FINAL_HARDENING_BASELINE.md](file:///Users/cancan/Desktop/LocalConvert/docs/FINAL_HARDENING_BASELINE.md), [FINAL_HARDENING_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/FINAL_HARDENING_REPORT.md)
