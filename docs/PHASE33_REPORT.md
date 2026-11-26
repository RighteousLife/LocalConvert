# Phase 33 Report — Audio Toolbox (Advanced Audio Conversion, Editing, Processing & Metadata)

## Overview

Phase 33 transforms LocalConvert's audio support into a full FFmpeg 9.0.2-backed **Audio Toolbox** integrated cleanly into the existing Swift/SwiftUI architecture (`ConversionRegistry`, `ConversionManager`, `ConversionQueue`, `PresetManager`, `HistoryManager`, `MetadataManager`, and `FormatCapabilityRegistry`).

No git commits, tags, pushes, or releases were created, and the `v1.0.0` release remains unmodified.

---

## 1. Bundled FFmpeg 9.0.2 Empirical Findings

All filters and codecs were verified directly against the bundled `ffmpeg 9.0.2` binary (`zero` Homebrew runtime dependencies):

- **FLAC 24-bit**: Requires `-sample_fmt s32 -bits_per_raw_sample 24`; defaults to `-sample_fmt s16` when float filter graphs precede FLAC encoding so FFmpeg does not trigger experimental 32-bit FLAC mode.
- **Vorbis**: Uses `-strict -2` for bundled native `vorbis` with both CBR (`-b:a`) and VBR (`-q:a`).
- **EBU R128 (`loudnorm`) frame-size guard**: Because `loudnorm` upsamples internally to `192 kHz` and can emit oversized buffers that fail encoders like FLAC (`invalid block size: 88184`), `AudioFilterGraphBuilder` appends `aresample=<targetOrSourceRate>` and `asetnsamples=n=4096:p=0` right after `loudnorm`.
- **AIFF ID3 metadata**: Bundled FFmpeg requires `-write_id3v2 1` alongside `-f aiff` so `artist` and full ID3v2 tags persist alongside `NAME`/`title`.
- **Excluded filter**: `anlmdn` segfaults (`exit 139`) in bundled FFmpeg 9.0.2 and is permanently excluded; noise reduction uses verified FFT denoising (`afftdn`) and optional `adeclick`.

---

## 2. Core Architecture Implemented

- **Codec Registry & Capabilities (`LocalConvert/Engines/AudioToolbox/AudioCodecCapability.swift`)**:
  - `AudioCodecID`, `AudioCodecSpec`, and `AudioCodecRegistry` declare explicit per-container codec compatibility, CBR/VBR bitrate bounds, VBR quality scales, allowed sample rates, bit depths (`16`/`24`/`32f`), channel limits, and stream-copy safety (`aac`, `aac_at`, `alac`, `libmp3lame`, `flac`, `pcm_s16le`/`s24le`/`s32le`/`f32le`/`s16be`/`s24be`/`s32be`, `libopus`, `vorbis`, `ac3`, `eac3`, `dca`, `wmav2`, `wavpack`, `copy`).
- **Configuration & Pre-Flight Validation (`LocalConvert/Engines/AudioToolbox/AudioProcessingModels.swift`)**:
  - `AudioToolboxConfig` round-trips cleanly through `ConversionOptions.customOptions` and `SavedPreset`.
  - `AudioConversionValidator` rejects invalid combinations pre-flight (e.g., `streamCopy` combined with DSP/trim filters, unsupported sample rates or channel layouts for MP3/AAC/Opus/AC-3/DTS).
- **Deterministic Filter Graph Builder (`LocalConvert/Engines/AudioToolbox/AudioFilterGraphBuilder.swift`)**:
  - Ordered `-af` pipeline: `atrim`/`asetpts`, `adeclick`, `afftdn`, `highpass`/`lowpass`, 5-band parametric `equalizer`, pitch shift (`asetrate` + `aresample`) + chained `atempo` (`0.25×..4.0×`), `silenceremove`, `areverse`, `acompressor`, `alimiter`, `pan` channel swap, `stereotools` width/balance, `volume`, `afade`, and `loudnorm` / peak measurement normalization.
- **Real Audio Analysis (`LocalConvert/Engines/AudioToolbox/AudioAnalysisService.swift`)**:
  - Actor using bundled `ffmpeg` for real `f32le` 8 kHz mono PCM waveform peak/RMS extraction (`extractWaveform`), `silencedetect` interval parsing, and `volumedetect` + `ebur128` loudness measurement (`measureLoudness`).
- **Execution Engine (`LocalConvert/Engines/AudioToolbox/BaseFFmpegProvider+AudioToolbox.swift`)**:
  - Implements single-track conversion/DSP/trim/silence-removal, non-destructive multi-segment extraction (`additionalOutputURLs`), and heterogeneous multi-file `concat` merging (`aresample=async=1` + `aformat`).
  - Wraps subprocess lifecycle in `@unchecked Sendable` `AudioProcessHolder` for Swift 6 strict-concurrency cancellation termination, validates outputs via `MediaProbe.validate`, and cleans up temporary workspaces (`LocalConvertAudio_*`).
- **Registry, Options & Presets Integration**:
  - Updated `FFmpegProvider.swift`, `MediaConversionEngine.swift`, `ConversionEngine.swift` (`.picker` option descriptor), `FileOptionsView.swift`, `ConversionRegistry.swift`, and `PresetValidator.swift` so same-format Audio Toolbox routes and Audio Toolbox presets work seamlessly without polluting default same-format menus.
- **Metadata & Tag Editor Expansion**:
  - Added `lyrics` to `CommonMetadata` (`MetadataDocument.swift`) and vertical multiline UI editing (`MetadataFieldView.swift`).
  - Expanded `FormatCapabilityRegistry.metadataSupportedFormats` (`.eac3`, `.dts`, `.wma`, `.wv`, `.mka`, `.au`) and `AudioMetadataProvider.swift` (`18` audio formats, `stream_tags` parsing for Opus/Ogg, `attached_pic` fallback extraction, container capability notes, `.m4b`/`.alac`/`.mp3`/`.flac` cover art embedding, and `validateAndNormalizeArtwork` wired into `MetadataManager.swift`).
- **Audio Toolbox UI & App Shell**:
  - Added `AppNavigationTab.audioToolbox` (`⌘7`), `AppState+AudioToolbox.swift`, `AudioToolboxView.swift`, `AudioWaveformView.swift`, `AudioCodecOptionsView.swift`, `AudioEffectsView.swift`, and `AVAudioPlayer` preview controller, integrated with `ConversionQueue` and `PresetManager`.

---

## 3. Verification Results

- **Phase 33 Comprehensive Suite (`LocalConvertTests/Phase33Tests.swift`)**:
  - `10 / 10` tests passed covering codec registry & validator rules, `AudioToolboxConfig` + `SavedPreset` serialization, FLAC 24-bit / Opus / AAC-AT VBR / AIFF 24-bit LE-BE / mono-stereo / `streamCopy` conversions, real PCM waveform envelope accuracy, single trim & multi-segment extraction, heterogeneous concat merge, speed/pitch/fades/reverse/silence removal, combined EQ+HPF+LPF+compressor+limiter+`afftdn`+declick+stereo width+EBU R128/peak normalization, MP3/M4A/FLAC/OPUS metadata+lyrics+artwork round-trip & invalid artwork rejection, malformed input rejection, and cancellation temp-dir cleanup.
- **Full Automated Test Suite (`xcodegen generate && xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'`)**:
  - **Result**: **361 tests in 40 suites passed** (`0` failures, `TEST SUCCEEDED`, 73.260s).
- **Release Build, Code Signing & Dependency Audit**:
  - `xcodebuild -project LocalConvert.xcodeproj -scheme LocalConvert -configuration Release -destination 'platform=macOS,arch=arm64' build`: **BUILD SUCCEEDED**.
  - `codesign --verify --deep --strict /Applications/LocalConvert.app`: **PASS**.
  - `./scripts/verify-dependencies.sh`: **PASS** (`arm64` verified, zero Homebrew runtime dependencies; FFmpeg 9.0.2, LibreOffice 26.8.0.3, `libwebp` + `libsharpyuv` via `@rpath`).
- **Live `/Applications/LocalConvert.app` Runtime QA**:
  - Launched `/Applications/LocalConvert.app`, switched to Audio Toolbox via `⌘7`, inspected live Accessibility hierarchy (`Convert & Codec`, `Trim & Segments`, `Merge Audio`, `Adjust & Effects`, `Tags & Cover Art`), opened real audio input, verified bundled 24-bit/48 kHz FLAC DSP/EBU-R128 output via bundled `ffprobe`, confirmed zero `LocalConvertAudio_*` temporary directory leaks, and confirmed zero crash reports in `~/Library/Logs/DiagnosticReports/`.
