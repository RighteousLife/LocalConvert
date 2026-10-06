# LocalConvert — Phase 18: Consumer & Apple Ecosystem Format Compatibility

## 1. Executive Summary & Philosophy

LocalConvert is a **privacy-first, offline, native macOS universal file converter** designed for everyday users, creative professionals, and general computing tasks. 

Phase 18 systematically expands LocalConvert's compatibility with high-value consumer and Apple ecosystem formats, bridging gaps in photo, audio, and video conversion workflows without compromising the application's clean architecture or expanding into complex broadcast/cinema video production scopes.

---

## 2. Format Evaluation & Scope Decisions

### 2.1 Included Consumer & Apple Formats

| Format | Category | Decode / Read | Encode / Write | Engine Pipeline | Consumer / Apple Workflow | Scope Decision |
|---|---|---|---|---|---|---|
| **DNG** (Apple ProRAW / Adobe DNG) | Image | Native `ImageIO` / `CoreImage` | N/A *(Read-Only)* | `ImageEngine` | iPhone ProRAW & camera RAW photos → JPG/PNG/WebP/PDF | **Input / Read-Only** |
| **ICNS** (Apple Icon Image) | Image | Native `ImageIO` / `AppKit` | Native `ImageIO` (`com.apple.icns`) | `ImageEngine` | macOS app & folder icons <-> PNG/JPG/WebP | **Bidirectional** |
| **ICO** (Windows Icon) | Image | Native `ImageIO` | Native `ImageIO` (`com.microsoft.ico`) | `ImageEngine` | Web favicons & multi-resolution icons <-> PNG/WebP | **Bidirectional** |
| **PSD** (Adobe Photoshop) | Image | Native `ImageIO` (Flattened composite raster) | N/A *(Read-Only)* | `ImageEngine` | Opening & rasterizing PSD graphics → PNG/JPG/PDF | **Input / Read-Only** |
| **TGA** (Truevision Targa) | Image | Native `ImageIO` | Native `ImageIO` (`com.truevision.tga-image`) | `ImageEngine` | Legacy gaming textures & graphics <-> PNG/JPG | **Bidirectional** |
| **CAF** (Core Audio Format) | Audio | Bundled FFmpeg / AudioToolbox | Bundled FFmpeg (`-c:a pcm_s16le`) | `MediaEngine` | Apple Voice Memos & GarageBand audio <-> WAV/MP3/M4A | **Bidirectional** |
| **ALAC** (Apple Lossless Audio) | Audio | Bundled FFmpeg (`alac`) | Bundled FFmpeg (`-c:a alac -f ipod`) | `MediaEngine` | Apple Music & iTunes lossless audio archiving <-> FLAC/WAV | **Bidirectional** |
| **AC-3** (Dolby Digital Audio) | Audio | Bundled FFmpeg (`ac3`) | Bundled FFmpeg (`-c:a ac3`) | `MediaEngine` | Surround sound & consumer TV/video tracks <-> WAV/AAC/MP3 | **Bidirectional** |
| **3GP / 3G2** (3GPP Mobile Video) | Video | Bundled FFmpeg (`3gp` / `h263`) | N/A *(Read-Only)* | `MediaEngine` | Rescuing legacy mobile phone video archives → MP4/MOV/MP3 | **Input / Read-Only** |
| **MTS / M2TS** (AVCHD / Blu-ray) | Video | Bundled FFmpeg (MPEG-TS demuxer) | N/A *(Read-Only)* | `MediaEngine` | Consumer camcorder footage (Sony/Panasonic) → MP4/MOV/MP3 | **Input / Read-Only** |

---

### 2.2 Explicitly Out-of-Scope Formats (Boundary Guardrails)

To prevent bloat and preserve application responsiveness, the following cinema and broadcast workflows are explicitly excluded:

- **Cinema Camera RAW:** ProRes RAW, ProRes RAW HQ, REDCODE RAW (.r3d), Blackmagic RAW (.braw), ARRI RAW (.ari).
- **Broadcast Production:** Sony XAVC-Intra, Sony XDCAM, Panasonic AVC-Intra, broadcast MXF multi-channel delivery.
- **Experimental Codecs:** JPEG XL (.jxl) deferred until system-wide macOS framework support matures.

---

## 3. Architecture & Engine Integration

### 3.1 Format Detection (`FileDetector.swift`)
- **Magic Byte Signatures:**
  - `ICNS`: `[0x69, 0x63, 0x6E, 0x73]` (`icns` at offset 0).
  - `PSD`: `[0x38, 0x42, 0x50, 0x53]` (`8BPS` at offset 0).
  - `CAF`: `[0x63, 0x61, 0x66, 0x66]` (`caff` at offset 0).
  - `AC3`: `[0x0B, 0x77]` sync word at offset 0.
  - `ICO`: `[0x00, 0x00, 0x01, 0x00]` at offset 0.
  - `3GP`: `ftyp` brand detection (`3gp`, `3g2`, `3ge`, `3gg`).
  - `MTS / M2TS`: MPEG-TS transport stream sync byte (`0x47`).
  - `DNG`: TIFF header (`0x49, 0x49, 0x2A, 0x00` / `0x4D, 0x4D, 0x00, 0x2A`) combined with `.dng` extension and RAW UTType resolution.

### 3.2 Image Conversion Engine (`ImageConversionEngine.swift`)
- Decodes DNG ProRAW, PSD flattened raster, ICNS, ICO, and TGA natively via Apple `ImageIO` and `CoreGraphics`.
- Encodes to `.icns`, `.ico`, `.tga`, `.png`, `.jpg`, `.webp`, `.heic`, `.pdf`, `.avif`.
- Strictly enforces read-only guardrails: `.dng` and `.psd` are present in `supportedInputFormats` but omitted from `supportedOutputFormats`.

### 3.3 Media Conversion Engine (`MediaConversionEngine.swift` & `BaseFFmpegProvider.swift`)
- Decodes and transcodes `.caf`, `.alac`, `.ac3`, `.threeGP`, `.mts`, `.m2ts`.
- Encodes bidirectional audio:
  - CAF: PCM 16-bit audio in Core Audio container.
  - ALAC: Apple Lossless Audio Codec (`-c:a alac -f ipod`).
  - AC3: Dolby Digital multi-bitrate encoder (`-c:a ac3`).
- Transcodes legacy 3GP and camcorder MTS/M2TS videos directly to modern MP4/MOV containers with hardware-accelerated H.264 (`h264_videotoolbox`) and AAC audio, or extracts audio directly to MP3/WAV/M4A.

### 3.4 Metadata Engine Integration (`MetadataRegistry.swift`)
- **Image Metadata Provider:** Inspects EXIF, TIFF, and camera metadata for DNG, PSD, ICNS, TGA. Returns read-only capability descriptors for DNG and PSD to protect RAW/layer structure.
- **Audio Metadata Provider:** Manages metadata and artwork for CAF, ALAC, AC3.
- **Video Metadata Provider:** Probes stream information and technical metrics for 3GP, MTS, M2TS.

---

## 4. Verification & Test Metrics

- **Unit & Integration Tests:** `224 / 224 tests passing` across 27 test suites.
- **Phase 18 Test Suite:** `Phase18Tests.swift` (10 tests) verifying format categorization, magic byte detection, read-only guardrails, bidirectional roundtrips, real audio transcodes, real video conversions, and metadata reading.
- **Release Build Audit:** Built clean native `arm64` Release executable (`LocalConvert.app`).
- **Dependencies Audit:** Zero Homebrew runtime dependencies verified via `./scripts/verify-dependencies.sh`.
