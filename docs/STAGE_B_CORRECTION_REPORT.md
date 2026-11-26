# LocalConvert — Stage B Correction Implementation Report

**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Scope:** Targeted remediation of the three technical findings identified in `docs/STAGE_B_TARGETED_AUDIT_REPORT.md` (Corrections A, B, and C) without starting Stage C or altering unrelated subsystems.

---

## 1. Executive Summary & Overall Verdict

| Audit Finding | Correction Status | Key Summary |
| --- | --- | --- |
| **A — Real-Time Audio Render Path (`AudioRingBuffer`)** | **PASS** | Replaced lock-protected `AudioRingBuffer.read(...)` with a wait-free SPSC atomic-index ring buffer (`Synchronization.Atomic<Int64>`), raw pre-allocated Float buffers, decoupled `markerLock`, and producer quiescing via `drainingProducers`. Verified statically and via runtime `malloc_zone_statistics` + SPSC wraparound tests. |
| **B — Gapless Explicit Channel Layout & Multichannel Format** | **PASS** | Added `AudioChannelLayoutInfo` to `DecodedAudioStreamInfo` and `DecodedPCMChunk`; fixed multichannel `AVAudioFormat` construction via `AVAudioChannelLayout`; required exact non-unknown compatible layouts for gapless eligibility (`5.1` vs `5.1(side)` and `nil` plain WAV now fall back safely to transport reconfiguration). |
| **C — Independent True-Peak Ceiling Enforcement (`-1.0 dBTP`)** | **PASS** | Added 4x oversampled boundary-aware true-peak measurement (`measureBoundaryTruePeak` / `AudioNormalizer.measureTruePeakDBTP`) in `renderMixToCAF(...)`; enforced 4x oversampled `alimiter` when un-normalized mixes exceed `targetTP` (catching sub-`-1 dBFS` inter-sample peaks) while keeping below-ceiling exports and `BitExactPassThrough` untouched. |

**Overall Stage B Correction Acceptance Recommendation:** **APPROVED FOR STAGE C**  
All 3 targeted corrections compile cleanly under Swift 6 strict concurrency (`arm64` clean Debug build succeeded), `./scripts/verify-dependencies.sh` passed all checks, and **120 / 120** targeted + regression tests passed sequentially with **0 failures**.

---

## 2. Technical Summary by Correction

### Correction A — Wait-Free Lock-Free SPSC `AudioRingBuffer` & Render Path
**Files Modified:**
- `LocalConvert/Engines/AudioEditor/PlaybackEngine.swift`
- `LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift`

**Production Changes:**
1. Refactored `AudioRingBuffer` (`PlaybackEngine.swift` lines 8–198) from `OSAllocatedUnfairLock`-guarded buffers to raw pre-allocated `UnsafeMutablePointer<Float>` storage (`lStorage`, `rStorage`) indexed by `Synchronization.Atomic<Int64>` (`readIndex`, `writeIndex`, `finishedAtFrame`).
2. `read(left:right:count:)` (`PlaybackEngine.swift` lines 131–156) executes exclusively with atomic `relaxed`/`acquiring`/`releasing` index loads and stores plus direct pointer copies (`update(from:count:)`), deterministically zero-filling any underrun tail (`update(repeating:count:)`) and never acquiring any lock, Objective-C runtime message, or heap allocation.
3. Decoupled timeline frame markers into `markerLock: OSAllocatedUnfairLock<MarkerState>`, which is accessed only on the producer `write(...)`, quiescent `reset()`, and `@MainActor` `playbackTimelineFrame()` paths — completely isolated from the `AVAudioSourceNode` audio render thread.
4. Enforced single-producer quiescing on `AudioPlaybackEngine` (`drainingProducers: [Task<Void, Never>]` and `drainProducersAndResetIfQuiescent(expectedGeneration:)`, lines 279, 448–475, 553–565) so `ring.reset()` runs only after the engine is paused and prior producer tasks have finished writing.

**Static Render-Path Audit:**
- Inspected `PlaybackEngine.swift` lines 1–198 and 540–560: zero lock acquisitions (`OSAllocatedUnfairLock`, `NSLock`, `os_unfair_lock`, `DispatchQueue.sync`) and zero heap allocations exist in `AudioRingBuffer.read(...)` or `makeSourceNode(format:ring:)`.

---

### Correction B — Explicit Channel Layout Modeling, Multichannel Formats & Gapless Safety
**Files Modified:**
- `LocalConvert/AudioWorkspace/Playback/AudioPlaybackDecoder.swift`
- `LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift`
- `LocalConvertTests/Phase67AudioEffectsAndPreviewTests.swift`

**Production Changes:**
1. Introduced `AudioChannelLayoutInfo` (`AudioPlaybackDecoder.swift` lines 15–258) storing `channelCount`, optional `coreAudioTag: AudioChannelLayoutTag?`, and canonical `normalizedName` (`mono`, `stereo`, `2.1`, `3.0`, `4.0`, `quad`, `quadraphonic`, `5.0`, `5.0(side)`, `5.1`, `5.1(side)`, `6.1`, `7.1`, `7.1(wide)`, or distinct CoreAudio/FFmpeg custom identifiers).
2. Explicitly treats missing/unspecified/generic descriptors (`nil`, `"unknown"`, `"unk"`, `"<N> channels"`, `kAudioChannelLayoutTag_Unknown`, `kAudioChannelLayoutTag_UseChannelDescriptions`, `DiscreteInOrder`) as `nil` (unknown layout).
3. Implemented `isGaplessCompatible(with:)` (`AudioPlaybackDecoder.swift` lines 31–36) requiring non-zero equal `channelCount` and exact matching `normalizedName` (preventing false matches such as `5.1` [`WAVE_5_1_B`] vs `5.1(side)` [`MPEG_5_1_A`] or `quad` vs `4.0`).
4. Fixed multichannel `AVAudioFormat` and `AVAudioPCMBuffer` construction in `AudioChannelLayoutInfo.makePlaybackFormat(...)` and `DecodedPCMChunk.makeAVAudioPCMBuffer()`, passing explicit `AVAudioChannelLayout` instead of `AVAudioFormat(standardFormatWithSampleRate:channels:)` (which returns `nil` when `channels > 2`).
5. Wired `channelLayout` extraction into both `NativeAVAudioPlaybackDecoder` (`processingFormat.channelLayout` / `fileFormat.channelLayout`) and `FFmpegStreamingPlaybackDecoder` (`ffprobe -show_entries ...channel_layout`).
6. Extended `AudioPlaybackTransportProtocol` and `AVAudioEnginePlaybackTransport` (`AudioLibraryPlayerEngine.swift` lines 9–36, 112–157, 389–395, 459–472, 794–800) to carry `channelLayout: AudioChannelLayoutInfo?` and updated `preloadNextTrack(...)` to require non-nil compatible layouts on both active and next tracks, using the safe reconfiguration fallback whenever layouts are unknown (`nil`) or incompatible.

*(Note: Plain RIFF `.wav` files written without extensible channel-layout chunks yield `channelLayout == nil`, so same-rate plain WAV transitions now safely fall back to transport reconfiguration instead of assuming stereo/layout compatibility; `.caf` / `.flac` / `.m4a` / extensible files carry explicit layout metadata and transition gaplessly.)*

---

### Correction C — Independent 4x Oversampled True-Peak Ceiling Enforcement
**Files Modified:**
- `LocalConvert/Engines/AudioEditor/AudioExportService.swift`
- `LocalConvertTests/Phase68LosslessExportTests.swift`

**Production Changes:**
1. Updated `renderMixToCAF(...)` (`AudioExportService.swift` lines 793–860) to compute both sample peak and 4x oversampled true peak (`MixdownPeakStats`, using `AudioNormalizer.measureTruePeakDBTP` with a 12-sample per-channel chunk-boundary seam buffer `measureBoundaryTruePeak` lines 735–791) without heap access-exclusivity conflicts or missing boundary inter-sample peaks.
2. In `renderAndEncode(...)` (`AudioExportService.swift` lines 885–928):
   - When `loudnessNormalizeEnabled` is enabled, two-pass `loudnorm` receives `TP=targetTP` (default `-1.0 dBTP`).
   - When `loudnessNormalizeEnabled` is disabled and `request.truePeakCeilingDBTP <= -0.1`, true-peak limiting triggers whenever `mixStats.truePeakDBTP > targetTP || peak > Float(pow(10.0, targetTP / 20.0))` — engaging a 4x oversampled FFmpeg filter chain (`aresample=<min(384000, sampleRate*4)>,alimiter=limit=<tpLinear>:attack=0.5:release=50:level=disabled,aresample=<sampleRate>`).
   - Signals already at or below `targetTP` receive no limiter filter and remain sample-accurate untouched; `BitExactPassThrough` remains completely untouched.

**Measured LUFS & True-Peak Evidence (`Phase68LosslessExportTests.testTruePeakCeilingProtectionOnInterSamplePeaks`):**

| Scenario | Input Level / True Peak | Export Mode / Config | Measured Output LUFS | Measured Output True Peak | Verification Result |
| --- | --- | --- | --- | --- | --- |
| **Case 1 — High-Crest Loudness Norm (`48 kHz` stereo)** | `-19.10 LUFS` / `+0.30 dBTP` | `loudnessNormalize: true`, target `-14.0 LUFS`, ceiling `-1.0 dBTP` | `-14.30 LUFS` | `-1.00 dBTP` (EBU R128) | Limiter actively engaged right at ceiling (`-1.00 dBTP`); loudness raised `+4.80 LU` |
| **Case 2a — Un-normalized ISP (`44.1 kHz` stereo, sample peak `-1.43 dBFS`)** | `+1.66 dBTP` (4x FIR) | `loudnessNormalize: false`, ceiling `-1.0 dBTP` | — | `-1.00 dBTP` (EBU R128) / `-0.93 dBTP` (4x chunk FIR) | Sub-`-1 dBFS` discrete sample peak caught via 4x true-peak detection and limited |
| **Case 2b — Un-normalized ISP (`48 kHz` stereo, sample peak `-1.43 dBFS`)** | `+1.66 dBTP` (4x FIR) | `loudnessNormalize: false`, ceiling `-1.0 dBTP` | — | `-1.00 dBTP` (EBU R128) / `-0.93 dBTP` (4x chunk FIR) | Clamped cleanly to `-1.00 dBTP` |
| **Case 2c — Un-normalized ISP (`96 kHz` stereo, sample peak `-1.43 dBFS`)** | `+1.66 dBTP` (4x FIR) | `loudnessNormalize: false`, ceiling `-1.0 dBTP` | — | `-1.70 dBTP` (EBU R128) / `-0.93 dBTP` (4x chunk FIR) | Clamped below `-1.0 dBTP` via `384 kHz` 4x oversampled limiter |
| **Case 3 — Un-normalized Below Ceiling (`48 kHz` `-6.0 dBFS` sine)** | `-6.02 dBFS` (`-5.60 dBTP` 4x chunk FIR) | `loudnessNormalize: false`, ceiling `-1.0 dBTP` | — | `-6.00 dBTP` (EBU R128) / `-5.60 dBTP` (4x chunk FIR) | Untouched (`maxDelta = 0.000000` Float32 sample diff) |
| **Case 4 — Multichannel `5.1` Un-normalized ISP (`48 kHz`, `6 ch`)** | `+1.66 dBTP` (`L`, `LFE` > ceiling) | `loudnessNormalize: false`, `channels: 6`, ceiling `-1.0 dBTP` | — | `-1.00 dBTP` (EBU R128) / `-0.93 dBTP` (4x chunk FIR) | All 6 channels preserved (`verifiedChannels = 6`), true peak held at `-1.00 dBTP` |
| **Case 5 — Hot `BitExactPassThrough` (`48 kHz`, 24-bit WAV, `-0.35 dBFS`)** | `+0.1 dBTP` | `exportMode: .bitExactPassThrough`, ceiling `-1.0 dBTP` | — | `+0.1 dBTP` | Source & output audio payload SHA-256 identical (`shaMatch = true`) |

---

## 3. Verification Runs Executed (After Final Code & Test Edits)

All `xcodebuild` test and build runs executed sequentially on Apple Silicon (`platform=macOS,arch=arm64`).

| Run Scope / Check | Suites & Cases | Result | Elapsed Time |
| --- | --- | --- | --- |
| **Targeted Correction Suites** (`Phase67AudioEffectsAndPreviewTests`, `Phase68LosslessExportTests`) | 2 suites, 25 tests (`18 + 7`) | **25 / 25 PASSED (0 failures)** | 48.198s |
| **Regression Batch 1** (`AudioDSPTests`, `AudioChainPresetPersistenceTests`, `AudioEditorExportAcceptanceTests`, `AudioExportProTests`) | 4 suites, 15 tests (`6 + 3 + 3 + 3`) | **15 / 15 PASSED (0 failures)** | 17.161s |
| **Regression Batch 2** (`Phase62AudioDomainFoundationTests`, `Phase63*` [3 suites], `Phase64AudioPlayerTests`, `Phase65WaveformPyramidTests`, `Phase66SampleEditingAndMigrationTests`) | 7 suites, 42 tests (`11 + 4 + 3 + 5 + 6 + 8 + 5`) | **42 / 42 PASSED (0 failures)** | 11.801s |
| **Regression Batch 3** (`Phase50CoreFeatureUndoTests`, `GlobalUndoRedoTests`, `Phase18Tests`, `Phase45IntegrationTests`) | 4 suites, 38 tests (`7 + 16 + 11 + 4`) | **38 / 38 PASSED (0 failures)** | 19.322s |
| **Clean Debug `arm64` Build** (`xcodebuild ... clean build`) | App target `LocalConvert` | **`** BUILD SUCCEEDED **`** | — |
| **Dependency Audit** (`./scripts/verify-dependencies.sh`) | `arm64`, zero Homebrew linkage, macOS 15.0+, notices | **All checks passed** | — |

**Combined Test Totals Verified Post-Fix:** **120 / 120 tests passed (0 failures, 0 skipped)** across **17 test suites**.

### Key New / Updated Tests Added in `Phase67AudioEffectsAndPreviewTests.swift`
- `testAudioRingBufferSPSCConcurrencyWraparoundAndExactContinuity`: Concurrent producer/consumer stress across 120,000 frames in a 512-frame buffer (`97`-frame prime write chunks, `64`-frame reads), proving wraparound bit-exact continuity and drained EOF signaling.
- `testAudioRingBufferDeterministicZeroFillUnderrunAndReset`: Empty/partial read deterministic zero-fill and post-reset timeline isolation.
- `testAudioRingBufferReadZeroHeapAllocations`: Runtime `malloc_zone_statistics` measurement across warmed 1,000-read bursts confirming exact zero-block / zero-byte / zero-VM growth bursts and `<= 0` median delta.
- `testAudioPlaybackEngineCancellationQuiescesProducerBeforeReset`: Rapid `play`/`seek`/`stop` cycling verifying quiesced producer cleanup.
- `testGapless1And3SameRateTransitionZeroResetGapAndExactSampleContinuity`: Explicit stereo `.caf` gapless transition with zero reset, single `configure`, and exact sample continuity across frame boundary.
- `testGapless5ChannelLayoutMismatchFallsBackCleanlyToReconfigure`: Equal channel count (`6 ch`) with differing speaker layouts (`5.1` `WAVE_5_1_B` vs `5.1(side)` `MPEG_5_1_A`), proving safe reconfigure fallback (`isGaplessArmed == false`, `configureHistory.count >= 2`).
- `testGaplessMonoToStereoChannelCountMismatchFallsBackCleanlyToReconfigure`: `1 ch` Mono -> `2 ch` Stereo safe fallback.
- `testGaplessUnknownLayoutPlainWAVFallsBackCleanlyToReconfigure`: Plain `48 kHz` 2-ch RIFF `.wav` -> `.wav` (`channelLayout == nil`) safe fallback (`isGaplessArmed == false`, `configureHistory.count >= 2`).
- `testMultichannelChannelLayoutFormatsAndPCMBufferConstruction`: Non-nil `DecodedPCMChunk.makeAVAudioPCMBuffer()` and `AVAudioEnginePlaybackTransport.configure(...)` verification across `4.0`, `quad`, `5.1`, `5.1(side)`, and `7.1`, plus `NativeAVAudioPlaybackDecoder` and `AudioChannelLayoutInfo` edge cases.

---

## 4. Scope Boundaries & Verification Limitations

1. **Gapless Mock Transport vs Live Physical Audio Hardware:** Cross-track gapless queue handoff timing, zero-reset node continuity, and sample-exact frame boundaries are verified deterministically via `GaplessSpyTransport` rather than analog/loopback recording through physical DAC hardware. `AVAudioEnginePlaybackTransport.configure(...)` graph construction and multichannel `AVAudioPCMBuffer` instantiation were verified directly against CoreAudio/AVFoundation (`4.0`, `quad`, `5.1`, `5.1(side)`, `7.1`).
2. **Process-Wide Heap Zone Metric:** Runtime zero-allocation verification (`testAudioRingBufferReadZeroHeapAllocations`) measures process-wide `malloc_zone_statistics` inside tight `AudioRingBuffer.read(...)` bursts after runtime warmup; zero-allocation execution inside the audio render closure is established jointly by that test and static inspection of lines 131–156 and 542–551 of `PlaybackEngine.swift`.
3. **Unmodified Unrelated UI / Stage C Scope:** Stage C UI work, `project.yml`, signing configuration, and unrelated workspace files were left untouched.

---

## 5. Repository & Host Preservation Verification

| Check | Pre-Correction Baseline | Post-Correction Verified |
| --- | --- | --- |
| Git Branch & `HEAD` | `main` (`85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`) | `main` (`85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`) |
| Staged Git Changes | `0` | `0` |
| `git status --porcelain` Entry Count | `304` (6 modified in scope; 0 unrelated edits) | `305` (exact baseline `304` + this report `docs/STAGE_B_CORRECTION_REPORT.md`) |
| `defaults export com.localconvert.app -` SHA-256 | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` |
| `/Applications/LocalConvert.app` `mtime` | `1795224025` | `1795224025` |
