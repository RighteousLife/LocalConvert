# STAGE_B_IMPLEMENTATION_REPORT.md

**Stage:** Stage B — Audio Processing, Preview, Gapless Playback & Export Engine *(Consolidates Original Phases 67 + 68 + Gapless Playback)*  
**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Branch / HEAD:** `main` (`85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`)  
**Target Platform:** macOS 15.0+ (`MACOSX_DEPLOYMENT_TARGET: "15.0"`), Apple Silicon (`arm64`), Swift `6.0` (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Verification Host:** macOS `27.2.1` (`Build 26B131`), Xcode `27.2` (`Build 27B52`), Apple Silicon (`arm64`)  
**Final Classification:** **READY WITH DOCUMENTED LIMITATIONS**

---

## 1. Executive Summary

Stage B hardened and completed both integrated audio processing, preview, gapless playback, and lossless/lossy export tracks in LocalConvert while preserving strict Conversion Workspace isolation and existing Stage A sample-frame contracts:

1. **Track B1 — DSP Engine, Proxy Cache, Sample-Frame Preview & Gapless Playback:**
   - Hardened [AudioDSPEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioDSPEngine.swift) across `44.1 / 48 / 88.2 / 96 / 192 kHz` sample rates and `1 / 2 / 6+` channel layouts with dynamic buffer resizing (`LimiterDSP`, `DelayDSP`, `ReverbDSP`), pre-allocated zero-hop-allocation STFT buffers (`SpectralNoiseReductionDSP`), `NaN`/`Inf` output sanitization guards, `AudioChainProcessor.processMultichannel(...)`, and distinct ITU-R BS.1770-4 K-weighted LUFS + 4x oversampled True-Peak measurement and normalization helpers alongside peak/RMS normalization.
   - Hardened [AudioMixingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioMixingService.swift) `ClipProxyCache` (`proxyVersion = 2`) with `contentSHA256`, sample-frame, rate, channel-count, and `effectSlots` keys, ref-counted in-flight task deduplication, cancellation `.tmp` cleanup, protected LRU eviction, injectable sandbox paths for testing (defaulting to `AppStoragePaths.audioEditorProxiesDirectory`), exact integer `AudioMixSession.mix(startFrame:...)`, and native `mixMultichannel(startFrame:...)`.
   - Refactored [PlaybackEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift) `AudioRingBuffer` and `AudioPlaybackEngine` to use a pre-allocated 128-slot ring marker table, contiguous slice copies with zero heap allocations inside real-time `read(...)` / `nonisolated makeSourceNode(...)`, exact integer `Int64` sample-frame streaming and loop wrap boundaries, and preserved Phase 64 `PlaybackArbitrationCenter` lifecycle integration.
   - Implemented **Gapless Same-Rate, Same-Channel-Layout Playback** across [PlaybackQueueManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackQueueManager.swift), [AudioLibraryPlayerEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift), and [PlaybackCoordinator.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackCoordinator.swift) with bounded 2-chunk pre-decoding, non-resetting `AVAudioPlayerNode` pre-scheduling, exact boundary promotion (`onGaplessTrackTransitioned`), cross-rate / channel-mismatch pause/reconfigure/resume fallback, decode-failure isolation, and queue-replacement/stop cancellation.

2. **Track B2 — Lossless & Lossy Export Pipeline:**
   - Upgraded [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift) to implement the existing `AudioExportMode` (`bitExactPassThrough`, `losslessFormatReRender`, `lossyFormatReRender`) defined in [AudioLibraryModels.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Domain/AudioLibraryModels.swift).
   - Delivered verified WAV (`16/24/32f`), AIFF (`16/24`), ALAC `.m4a` (`16/24`), FLAC (`16/24`), CAF (`24/32f`), MP3, AAC (`.m4a`), Opus (`.opus`), and fixed Ogg Vorbis (`.ogg` via `-c:a vorbis -strict -2`) export, WAV/AIFF payload-level SHA-256 `BitExactPassThrough`, strict TPDF dithering rules, multichannel `1–8` ch export (removing the silent `1...2` clamp), pre-flight `.ape` rejection, app-controlled staging in `AppStoragePaths.audioExportStagingDirectory`, `-1.0 dBTP` true-peak ceiling protection, and extended `ffprobe` validation.

---

## 2. Baseline & Host Preservation Verification

| Check | Pre-Stage B Baseline | Post-Stage B State | Verification |
| --- | --- | --- | --- |
| Git Branch / `HEAD` | `main` (`85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`) | `main` (`85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`) | Identical |
| Staged changes (`git diff --cached`) | `0` | `0` | Unchanged |
| `git status --short` entries | `300` | `303` (`+Phase67`, `+Phase68`, `+STAGE_B_IMPLEMENTATION_REPORT.md`) | Strictly Stage B additions |
| `defaults export com.localconvert.app - \| shasum -a 256` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` | Byte-for-byte identical |
| `/Applications/LocalConvert.app` mtime | `1795224025` | `1795224025` | Untouched |
| Dependency verification (`./scripts/verify-dependencies.sh`) | Passed | Passed | `arm64`, minOS 15.0, zero Homebrew |

---

## 3. Files Modified & Created

### 3.1 Modified Existing Production & Project Files (8 files)

| File | Stage B Responsibility | Line Count |
| --- | --- | ---: |
| [AudioDSPEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioDSPEngine.swift) | Multi-rate buffer resizing (`44.1–192 kHz`), zero-hop-alloc STFT, `NaN`/`Inf` guards, `processMultichannel`, BS.1770 LUFS + True-Peak normalization | 1,428 |
| [AudioMixingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioMixingService.swift) | `ClipProxyCache` v2 hardening (keys, dedup, cancel, LRU, sandbox injection) + `AudioMixSession.mix(startFrame:)` & `mixMultichannel` | 923 |
| [PlaybackEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift) | Fixed-slot zero-alloc `AudioRingBuffer`, `Int64` sample-frame streaming/looping, preserved `nonisolated makeSourceNode` & Phase 64 arbitration | 580 |
| [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift) | `AudioExportMode` support, pass-through SHA-256 verification, fixed Ogg Vorbis (`vorbis -strict -2`), CAF/ALAC/FLAC bit depths, TPDF rules, multichannel export, `.ape` rejection, staging isolation, extended `ffprobe` report | 1,062 |
| [PlaybackQueueManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackQueueManager.swift) | Added `peekNextTrackID()` and `commitGaplessAdvance(to:)` | 330 |
| [AudioLibraryPlayerEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift) | Gapless pre-loading (`preloadNextTrack`, `clearPreloadedNextTrack`, `isGaplessArmed`), non-resetting pre-scheduling, `transportFrameOriginOffset`, decode failure isolation | 1,074 |
| [PlaybackCoordinator.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackCoordinator.swift) | Wired `onGaplessTrackTransitioned`, queue-mutation preload refresh/invalidation, security-scoped URL handoff | 682 |
| `LocalConvert.xcodeproj/project.pbxproj` | Regenerated via `xcodegen generate` (`project.yml` untouched) to register `Phase67` and `Phase68` test suites | — |

### 3.2 Created Files (3 files)

| File | Role | Line Count |
| --- | --- | ---: |
| [Phase67AudioEffectsAndPreviewTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift) | DSP multi-rate/multichannel, Peak vs LUFS, proxy cache, ring buffer frame accuracy, preview/offline parity, and all 7 gapless playback tests | 855 |
| [Phase68LosslessExportTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase68LosslessExportTests.swift) | Complete lossless/lossy format matrix (`ffprobe` validated), `BitExactPassThrough` SHA-256 & rejections, TPDF dithering, `-1.0 dBTP` ceiling, `.ape` rejection, 1/2/6-ch export, cancellation cleanup | 586 |
| [STAGE_B_IMPLEMENTATION_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/STAGE_B_IMPLEMENTATION_REPORT.md) | This Stage B technical completion report | — |

---

## 4. DSP Engine Matrix (`AudioDSPEngine`)

Implemented in [AudioDSPEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioDSPEngine.swift):

- **Parametric EQ (`ParametricEQDSP`):** Double-precision RBJ cookbook biquads with Jury stability checking and input/output finite guards; tested across `44.1 / 48 / 88.2 / 96 / 192 kHz`.
- **Compressor (`CompressorDSP`):** Soft-knee envelope follower with `lastGainReductionDB` metering and `NaN`/`Inf` state/sample guards.
- **Lookahead Limiter (`LimiterDSP`):** Dynamic lookahead buffer capacity sizing (`Int(ceil(sampleRate * 0.015)) + 16`) when sample rate changes up to `192 kHz` + hard sample-peak ceiling guard.
- **Noise Gate (`NoiseGateDSP`):** Hysteresis & hold timer with finite sample sanitization.
- **Spectral Noise Reduction (`SpectralNoiseReductionDSP`):** `1024`-pt `vDSP_DFT` overlap-add (`hop = 256`) using pre-allocated instance scratch arrays (eliminating 10 per-hop array allocations in `processSingleFrame`), O(1) `readyReadIndex` read cursor with bounded periodic compaction, and capture profile support.
- **Delay (`DelayDSP`) & Reverb (`ReverbDSP`):** Dynamic circular buffer capacity resizing up to `2.1s * 192 kHz` (`403,216` samples) in `DelayDSP` and proportional comb/allpass delay scaling in `ReverbDSP`.
- **Multichannel Processing (`AudioChainProcessor.processMultichannel`):** Cleanly handles mono (`1 ch` via isolated scratch channel), stereo (`2 ch`), and `>2 ch` discrete pairs via per-pair synchronized `AudioChainProcessor` clones (`extraPairProcessors`), verified at `1`, `2`, and `6` channels across `silence`, `-90 dBFS`, `+6 dBFS`, and injected `NaN`/`Inf`.

---

## 5. Peak Normalization vs. ITU-R BS.1770 LUFS Normalization

Implemented on `AudioNormalizer` in [AudioDSPEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioDSPEngine.swift#L1065-L1428):

- **Peak & RMS Helpers (Preserved):** `measure(samplesLeft:samplesRight:)` and `normalizationGainDB(measurement:mode:)` preserved intact (`AudioDSPTests` passing).
- **BS.1770-4 K-Weighted LUFS Measurement (`measureIntegratedLUFS`):** Sample-rate-adaptive bilinear-transformed Stage 1 high-shelf pre-filter + Stage 2 RLB high-pass filter, BS.1770 channel weighting (`LFE` excluded on 5.1, `+1.5 dB` surround weighting), `400 ms` blocks at `100 ms` hop with `-70.0 LKFS` absolute gate and `-10.0 LU` relative gate (with short-clip single-block fallback).
- **4x Oversampled True-Peak (`measureTruePeakDBTP`):** 4-phase 12-tap Blackman-windowed sinc polyphase FIR interpolation across phases `+0.25`, `+0.50`, `+0.75`.
- **Apply Helpers:** `applyPeakNormalization(...)` targets sample-peak dBFS directly; `applyLUFSNormalization(..., truePeakCeilingDBTP: -1.0)` caps linear loudness gain so output true peak never exceeds the ceiling, and both return `nil` (zero gain change) on silence or near-silence (`< 1e-6` linear peak / `< -70 LUFS`).

---

## 6. Proxy Cache Architecture (`ClipProxyCache`)

Hardened in [AudioMixingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioMixingService.swift#L149-L315):

- **Storage Root:** Defaults to `AppStoragePaths.audioEditorProxiesDirectory` (macOS `Caches/AudioEditorProxies`, zero `/tmp` writes); injectable initializer allows isolated per-test `TestSandbox` instances.
- **Versioned Cache Key (`proxyVersion = 2`):** `SHA256` digest over `proxyVersion`, asset path, `contentSHA256`, `fileSize`, `modificationTime`, `asset.sampleRate`, `asset.channels`, `clip.sourceStartFrame`, `clip.durationFrames`, `clip.sourceSpanFrames`, `clip.sourceRate.hz`, `clip.projectRate.hz`, `rate`, `channelCount`, `isReversed`, `swapChannels`, `channelMode`, `stretch`, and sorted JSON of both `clip.effects` and `clip.effectSlots`.
- **In-Flight Deduplication & Atomic Write:** Ref-counted `inFlightTasks` + `inFlightWaiters` coalesce concurrent requests for identical keys while ensuring cancelling one sibling leaves other active waiters unaffected, and cancelling the sole waiter aborts FFmpeg and removes `.tmp.caf` inside `defer`.
- **LRU Eviction:** `evictIfNeeded(excluding: destination)` deletes oldest `.caf` entries when cache exceeds `maxBytes` (`1.5 GB` default) while protecting the newly committed file.

---

## 7. Real-Time Render Thread Safety & Zero-Allocation Audit

Audited directly in [PlaybackEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift):

- **`AudioRingBuffer.read(left:right:count:)` ([PlaybackEngine.swift#L108-L138](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L108-L138)):** Acquires `OSAllocatedUnfairLock` (`os_unfair_lock`), copies wrapped/contiguous PCM slices via `UnsafeMutablePointer.update(from:count:)`, zero-fills any shortfall, updates `readIndex`, and releases lock. Performs **0 heap allocations, 0 array resizes, 0 Objective-C/Swift runtime dispatches, 0 file/network I/O, and 0 actor hops**.
- **`AudioPlaybackEngine.makeSourceNode` ([PlaybackEngine.swift#L496-L505](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L496-L505)):** Marked `private nonisolated static`, binding `AVAudioSourceNode` directly to `ring.read(...)` without `@MainActor` isolation or Swift concurrency runtime hops.
- **Sample-Frame Marker Ring:** Replaced growing `[(frame: Int64, time: Double)]` array and `removeFirst()` with a pre-allocated fixed 128-entry `FrameMarker` ring storing integer `timelineFrame: Int64`.

---

## 8. Sample-Frame Synchronization & Loop Boundary Continuity

- `AudioPlaybackEngine` maintains authoritative `playheadFrame: Int64` and `currentTimelinePosition: SampleFrameTime` alongside derived `playheadTime: TimeInterval`.
- `beginStreaming(fromFrame:generation:projectRate:)` ([PlaybackEngine.swift#L507-L561](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift#L507-L561)) advances `posFrame` exclusively in integer frames (`posFrame += Int64(n)`), resolves loop boundaries via `LoopConfigBox.resolvedFrameBounds(for: projectRate)` (`Int64`), and splits loop-end reads at `loopBounds.endFrame` so `ring.playbackTimelineFrame()` matches `startTimelineFrame + readFrames` accurately at `100,000,000+` frame offsets (`Phase67AudioEffectsAndPreviewTests.testAudioRingBufferSampleFrameAccuracyAndLoopContinuity`).
- Phase 64 `PlaybackArbitrationCenter` registration, mutual pause arbitration, and `deinit`/explicit unregistration remain intact (`Phase64AudioPlayerTests` `6/6` passed).

---

## 9. Preview vs. Offline Render Numerical Parity

Tested in `Phase67AudioEffectsAndPreviewTests.testPreviewVsOfflineRenderNumericalParity` comparing `AudioMixSession.mix(startFrame:...)` live preview buffer directly against `AudioExportService.export(...)` offline `32-bit float` WAV output across `ParametricEQ` + `Fades` + `Compressor` and `Reverse` + `Time-Stretch`:

- **Asserted Pass Thresholds:** Signal-to-Noise Ratio `SNR > 90.0 dB` and peak absolute sample difference `< 1e-4` across full rendered duration (`48,000` and `38,400` frames). Both scenarios passed cleanly inside the single shared `AudioSourceResolver` + `AudioMixSession` + `AudioChainProcessor` DSP graph (`Phase67AudioEffectsAndPreviewTests` `11/11` passed; exact per-sample values were validated inside XCTest without failing assertions).

---

## 10. Gapless Same-Rate, Same-Channel-Layout Playback Architecture & Test Verification

Implemented across [PlaybackQueueManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackQueueManager.swift), [AudioLibraryPlayerEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift), and [PlaybackCoordinator.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackCoordinator.swift):

1. **Eligibility:** Preload opens next track via `AudioPlaybackDecoderProtocol` off-MainActor and arms gapless ONLY when `nextInfo.sampleRate == activeInfo.sampleRate` and `nextInfo.channelCount == activeInfo.channelCount`.
2. **Bounded Pre-Scheduling:** Pre-decodes up to `maxPreloadBufferedChunks = 2` chunks (`8,192` frames/chunk max). When active track reaches `decoderReachedEOF`, `startFeedLoopIfNeeded()` schedules preloaded chunks onto the same `AVAudioPlaybackTransportProtocol` without calling `stopAndResetNode()`, tagging callbacks with separate `trackToken`.
3. **Exact Boundary Promotion & Continuous Frame Accounting:** Queue index and `currentTrack` remain on Track A while Track B chunks sit in the FIFO queue. Only when Track A's last chunk completes (`inFlightChunkCount == 0`) does `promotePreloadedTrackIfReady` advance `transportFrameOriginOffset += activeFramesSubmittedSinceOrigin`, promote `decoder`/`streamInfo`, and fire `onGaplessTrackTransitioned?(pre.assetID)`.
4. **7/7 Mandatory Gapless Verification Cases (`GaplessSpyTransport` + `ScriptedPCMDecoder`):**
   - Same-rate, same-channel transition executes with `0` additional `stopAndResetNode()` calls.
   - Queue stays on Track A while Track B chunks are pre-scheduled and advances strictly at Track A's final chunk callback.
   - Total rendered frame count matches `24,000` (`12,000 + 12,000`) with continuous exact sample values (`1.0 ...` -> `100.0 ...`, zero dropped or duplicated samples).
   - Cross-rate (`44.1 kHz -> 48 kHz`) and channel-layout (`1 ch -> 2 ch`) transitions leave `isGaplessArmed == false` and fall back safely through pause/reconfigure/resume.
   - Queue replacement (`enqueueNext`) cancels preloaded Track B so cancelled Track B samples never render; `stop()` resets cleanly.
   - Next-track decode failure leaves active Track A playing uninterrupted and clears preloaded state cleanly.

---

## 11. Lossless & Lossy Export Modes & Pass-Through Verification

Implemented in [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift):

- **`AudioExportMode.bitExactPassThrough`:** Uses `evaluatePassThroughEligibility(project:request:)`, requires single unedited track & clip covering full source asset in WAV/AIFF PCM matching target sample rate, bit depth, and channels with zero gain/fades/effects/stretch/reverse/channel-ops/loudness-normalization/16-bit-dithering. Computes raw audio stream digest via FFmpeg `-map 0:a:0 -c:a copy -f hash -hash sha256 -` before and after `-c:a copy` remux, confirming `sourceAudioPayloadSHA256 == outputAudioPayloadSHA256` and unmodified source file SHA-256 while rejecting all ineligible cases explicitly.
- **`AudioExportMode.losslessFormatReRender`:** Renders Float32 mixdown via `AudioMixSession` to `mixdown.caf`, applies optional 2-pass `loudnorm` (with single-pass fallback when K-weighted input loudness exceeds FFmpeg's `measured_I <= 0.0` limit) and conditional 16-bit TPDF dither, and encodes target lossless format.
- **`AudioExportMode.lossyFormatReRender`:** Same mixdown/loudness pipeline encoding target lossy format (`MP3`, `AAC`, `Opus`, `Ogg Vorbis`) with dithering disabled.

---

## 12. Format, Encoder & Ogg Vorbis Verification Matrix

Verified both via standalone bundled FFmpeg `9.0.2` / `ffprobe` inspection and `Phase68LosslessExportTests.testExportFormatMatrixWithFFprobeVerification`:

| Format | Target Ext | Depth / Bitrate | FFmpeg Arguments | `ffprobe` Verified Codec & Format |
| --- | --- | --- | --- | --- |
| WAV 16/24/32f | `.wav` | `16 / 24 / 32f` | `pcm_s16le / pcm_s24le / pcm_f32le` | `pcm_s16le (16b)`, `pcm_s24le (24b)`, `pcm_f32le (32b)` |
| AIFF 16/24 | `.aiff` | `16 / 24` | `pcm_s16be / pcm_s24be -f aiff` | `pcm_s16be (16b)`, `pcm_s24be (24b)` |
| ALAC 16/24 | `.m4a` | `16 / 24` | `alac -sample_fmt s16p / s32p -bits_per_raw_sample 24 -f ipod -movflags +faststart` | `alac (s16p / s32p, bits_per_raw_sample = 16 / 24)` |
| FLAC 16/24 | `.flac` | `16 / 24` | `flac -sample_fmt s16 / s32 -bits_per_raw_sample 24` | `flac (s16 / s32, bits_per_raw_sample = 16 / 24)` |
| CAF 24/32f | `.caf` | `24 / 32f` | `pcm_s24le / pcm_f32le -f caf` | `pcm_s24le (24b)`, `pcm_f32le (32b)` |
| MP3 | `.mp3` | `192k` (config) | `libmp3lame -b:a <kbps>k` | `mp3` |
| AAC / M4A | `.aac` / `.m4a` | `192k` (config) | `aac -b:a <kbps>k` (`+faststart` for `.m4a`) | `aac` |
| Opus | `.opus` | `192k` (config) | `libopus -b:a <kbps>k` | `opus` |
| Ogg Vorbis *(fixed)* | `.ogg` | `192k` (config) | `vorbis -strict -2 -b:a <kbps>k` | `vorbis` (`fltp`, 2 ch) |

*(Note: `FileFormat.alac.fileExtension` remains `"alac"` because existing Conversion Workspace suite `Phase18Tests` asserts `FileFormat.alac.fileExtension == "alac"`; `AudioExportService.outputFileExtension(for: .alac)` maps Editor export destinations cleanly to `.m4a`.)*

---

## 13. TPDF Dithering & True-Peak Ceiling Verification

- **Strict TPDF Dithering Rules (`AudioExportService.swift` lines 840–849):**
  - Applied `aresample=dither_method=triangular_hp:osf=s16` **only** when `resolvedMode == .losslessFormatReRender`, `bitDepth == 16`, `outputFormat` is `.wav`, `.aiff`, `.flac`, or `.alac`, and `applyDitheringOn16Bit == true`.
  - Verified sample LSB difference between 16-bit dithered (`ditheringApplied == true`) and truncated (`ditheringApplied == false`) WAV outputs, and confirmed `ditheringApplied == false` across 32-bit float WAV, 24-bit WAV/FLAC/ALAC, lossy formats, and `BitExactPassThrough`.
- **True-Peak Ceiling Protection (`-1.0 dBTP`):**
  - Removed legacy hard `±1.0` sample clipping from `renderMixToCAF`, preserving true Float32 headroom for downstream limiting/loudnorm.
  - Added out-of-bounds guard for two-pass `loudnorm` (`measured_I <= 0.0`, `measured_LRA in 0...99`, `measured_TP in -99...99`, `measured_thresh in -99...0`) with automatic single-pass `loudnorm` fallback when hot Float32 signals exceed `0.0 LUFS`, plus `alimiter` ceiling protection when un-normalized Float32 signal peaks exceed `truePeakCeilingDBTP`.
  - Verified on an inter-sample-peak test waveform (`Phase68LosslessExportTests.testTruePeakCeilingProtectionOnInterSamplePeaks`) achieving `measuredTruePeakDBTP <= -0.8 dBTP`.

---

## 14. Multichannel Validation & `.ape` Pre-Flight Rejection

- Removed the silent `max(1, min(2, request.channels))` clamp in both `-ac` arguments and `validateExportedFile`.
- `renderMixToCAF` uses `AVAudioChannelLayout` (`kAudioChannelLayoutTag_MPEG_5_1_A`, `kAudioChannelLayoutTag_MPEG_7_1_A`, or discrete layout) paired with `AudioMixSession.mixMultichannel(...)`.
- Verified `1 ch`, `2 ch`, and `6 ch` (`5.1`) WAV and FLAC export outputs via `ffprobe` (`channels == 1, 2, 6`).
- Validated explicit `ConversionError.invalidInput` rejection for `6 ch` MP3 and non-stereo (`1 ch`, `6 ch`) native Ogg Vorbis.
- Validated explicit pre-flight `.ape` rejection (`ConversionError.unsupportedConversion(from: .wav, to: .ape)`) creating zero output or staging files.

---

## 15. Staging Isolation, Cancellation Cleanup & Conversion Workspace Independence

- Both `AudioExportService.previewMetrics(...)` and `renderAndEncode(...)` / `executeBitExactPassThrough(...)` create temporary per-job folders strictly inside `AppStoragePaths.audioExportStagingDirectory` and remove them inside `defer`.
- Output collision safety uses `OutputReservationCoordinator.reserveUniqueOutputURL` with `defer` release, protected source-asset path verification, and destination cleanup on error/cancel.
- Static scan confirmed `0` occurrences of `/tmp`, `temporaryDirectory`, or `ConversionManager` across all 7 Stage B modified production files.
- Verified mid-export cancellation leaves `0` partial output files and `0` leftover entries inside `AppStoragePaths.audioExportStagingDirectory`.

---

## 16. Deviations & Discovery Log

1. **Reuse of Existing `AudioExportMode` (`AudioLibraryModels.swift`):**
   - `AudioExportMode` already existed in [AudioLibraryModels.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Domain/AudioLibraryModels.swift#L535-L539) with cases `.bitExactPassThrough`, `.losslessFormatReRender`, and `.lossyFormatReRender`. Rather than redeclaring or changing persisted enum cases, `AudioExportRequest.exportMode` was added as `AudioExportMode? = nil` (default `nil` resolves lossless vs lossy re-render based on `outputFormat`).
2. **Bundled FFmpeg 9.0.2 Native `vorbis` Encoder Channel Constraint:**
   - Empirical check on bundled FFmpeg 9.0.2 established that experimental native `vorbis` (`-c:a vorbis -strict -2`) encodes `2`-channel stereo cleanly (`ffprobe` confirms `codec_name=vorbis`, `fltp`) but fails with exit code `255` on mono or multichannel inputs (`Current FFmpeg Vorbis encoder only supports 2 channels`). Pre-flight validation in `AudioExportService` rejects `channels != 2` explicitly for `.ogg` instead of failing mid-export.
3. **Hot Float32 Input Loudness Guard for Two-Pass `loudnorm`:**
   - First `Phase68` test run exposed an FFmpeg exit `222` error when un-clipped hot Float32 input caused pass-1 `loudnorm` to measure `measured_I = +3.65 > 0.0`. Added FFmpeg range guards on pass-1 stats with single-pass `loudnorm` fallback, after which all Stage B suites passed cleanly.
4. **Phase 66 Test Suite Identifier Check:**
   - The Stage A editing test class is named `Phase66SampleEditingAndMigrationTests` (5 tests), not `Phase66SampleAccurateEditingTests`; both `Phase65WaveformPyramidTests` and `Phase66SampleEditingAndMigrationTests` ran and passed cleanly.

---

## 17. Test Execution Results

All test suites ran **sequentially** on `platform=macOS,arch=arm64` after all production source changes were finalized (all sandboxed in `TestSandbox` via `AppStoragePaths.setTestOverrides`):

| Test Suite | Framework | Passed | Failed | Skipped | Notes |
| --- | --- | ---: | ---: | ---: | --- |
| `Phase67AudioEffectsAndPreviewTests` | XCTest | 11 | 0 | 0 | DSP 44.1–192kHz & 1/2/6ch, Peak/LUFS, ProxyCache, RingBuffer/Loop, Preview/Offline parity, 7 Gapless tests |
| `Phase68LosslessExportTests` | XCTest | 7 | 0 | 0 | 15-entry format matrix, PassThrough SHA-256, TPDF dither rules, -1 dBTP ISP test, `.ape` reject, 1/2/6ch, cancel |
| `AudioDSPTests` | Swift Testing | 6 | 0 | 0 | Legacy/existing DSP regression |
| `AudioChainPresetPersistenceTests` | Swift Testing | 3 | 0 | 0 | Preset persistence + Undo/Redo regression |
| `AudioExportProTests` | Swift Testing | 3 | 0 | 0 | Existing pro loudness/format/batch export regression |
| `AudioEditorExportAcceptanceTests` | Swift Testing | 3 | 0 | 0 | Multitrack export, waveform/FFT, cancel cleanup |
| `Phase64AudioPlayerTests` | XCTest | 6 | 0 | 0 | CoreAudio monitor, routing persistence, bidirectional arbitration |
| `Phase65WaveformPyramidTests` | XCTest | 8 | 0 | 0 | Stage A Track A1 waveform pyramid & bounds |
| `Phase66SampleEditingAndMigrationTests` | XCTest | 5 | 0 | 0 | Stage A Track A2 sample-accurate editing & v3 migration |
| `Phase62AudioDomainFoundationTests` | XCTest | 11 | 0 | 0 | Audio domain models, reservation & isolation |
| `Phase63AudioPlaybackTests` | XCTest | 5 | 0 | 0 | Decoder factory, queue manager, state machine |
| `Phase18Tests` | Swift Testing | 11 | 0 | 0 | Format definitions (`FileFormat.alac`), Conversion routes |
| `Phase45IntegrationTests` | Swift Testing | 4 | 0 | 0 | Undo/recovery & real-time vs offline DSP parity |
| **Total Observed** | **XCTest + Swift Testing** | **83** | **0** | **0** | Zero retries/flaky skips on final code |

---

## 18. Build & Dependency Verification Results

- **Clean `arm64` App Build (`xcodebuild ... clean build`):** `** BUILD SUCCEEDED **`, exit code `0`, `0` warnings across all Stage B files (`1` total project-wide asset/signing note outside Stage B Swift sources).
- **XcodeGen Project Integrity (`xcodegen generate`):** Exited `0`, registered new Stage B test files cleanly while keeping `project.yml` untouched.
- **Bundled Dependency & Binary Audit (`./scripts/verify-dependencies.sh`):** Exited `0` — verified `arm64` architecture, macOS `15.0` minimum OS compatibility, zero Homebrew linkage, bundled `FFmpeg 9.0.2`, `libwebp`, `libjxl 0.13.0`, and signed LibreOffice `26.8.0.3`.

---

## 19. Known Limitations & Hardware Runtime Boundaries

1. **Gapless Audio Output Verified via Headless `GaplessSpyTransport` + `ScriptedPCMDecoder`:**
   - All 7 mandatory gapless tests deterministically verified chunk-level scheduling order, exact sample continuity (`24,000` frames with `0` dropped/duplicated samples), `0` node resets between same-rate tracks, delayed queue advancement at boundary callbacks, cross-rate/channel fallbacks, cancellation, and decode error recovery using an injected spy transport (`AudioPlaybackTransportProtocol`). Continuous audible playback across physical DAC hardware on `AVAudioEnginePlaybackTransport` compiles cleanly and shares the identical `AudioLibraryPlayerEngine` scheduler logic, but physical speaker/DAC glitch timing remains unverified in a headless session.
2. **Ogg Vorbis Experimental Encoder & Channel Count Limit:**
   - Bundled FFmpeg `9.0.2` omits `libvorbis` and ships FFmpeg's experimental built-in `vorbis` encoder (`-strict -2`), which only accepts `2`-channel stereo inputs. Mono (`1 ch`) or surround (`>2 ch`) `.ogg` exports are rejected cleanly pre-flight rather than silently downmixed/upmixed unless explicit channel conversion policy is added later.
3. **ALAC Destination Extension Mapping Inside `AudioExportService`:**
   - Editor `.alac` exports write `.m4a` containers (required by Apple players/`AVAudioFile`), while `FileFormat.alac.fileExtension` remains `"alac"` to preserve Conversion Workspace `Phase18Tests` compatibility.

---

## 20. Final Classification & Stage C Readiness Gate

**Classification:** **READY WITH DOCUMENTED LIMITATIONS**

All Stage B requirements across DSP hardening, Peak vs BS.1770 LUFS normalization, proxy cache reliability, zero-allocation sample-frame playback, gapless same-rate scheduling, lossless/lossy/pass-through export modes, TPDF dithering, Ogg Vorbis support, multichannel fidelity, staging isolation, clean `arm64` build, dependency checks, and `83/83` observed automated tests passed after final source edits. Documented boundaries (`GaplessSpyTransport` headless verification vs. interactive DAC auditioning and bundled `vorbis` 2-channel constraint) are explicit and non-blocking for proceeding to Stage C once authorized.

*Stage C and Stage D have NOT been started.*
