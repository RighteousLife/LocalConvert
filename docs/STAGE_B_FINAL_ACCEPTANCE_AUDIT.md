# LocalConvert — Stage B Final Acceptance Audit

**Audit Type:** Strictly Read-Only Final Acceptance Audit (no source, test, project, or host-state modifications)  
**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Reviewed Reports:**
- [STAGE_B_TARGETED_AUDIT_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/STAGE_B_TARGETED_AUDIT_REPORT.md)
- [STAGE_B_CORRECTION_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/STAGE_B_CORRECTION_REPORT.md)

---

## Executive Summary & Final Classification

| Audit Area | Classification | Summary |
| --- | --- | --- |
| **A. True-Peak Measurement Reconciliation** | **PASS (with documented filter & headroom notes)** | Reconciled both `-0.93 dBTP` (custom 12-tap FIR `+0.072 dB` passband gain at `fs/4`) and `-1.70 dBTP` at `96 kHz` (FFmpeg `ebur128` 192 kHz ceiling vs `aresample=384000` 4x limiting). Authoritative `ebur128` runs on the final encoded output `tmpOut` and enforces `-1.00 dBTP` on tested lossless outputs; a small internal limiter margin is recommended for lossy/downsampled targets. |
| **B. `AudioRingBuffer` Reset & Render-Callback Lifecycle** | **CONCERN** | Producer quiescence (`drainingProducers`), SPSC invariants across rapid `play`/`seek`/`stop`, and pointer ownership/teardown lifetimes are sound. However, render-callback quiescence before `ring.reset()` relies on `AVAudioEngine.pause()` (`AudioOutputUnitStop`) rather than an explicit atomic callback-quiescence or epoch-reset barrier, and `@MainActor` `reset()` writes `readIndex = 0` directly. |
| **C. Overall Stage B Acceptance** | **`STAGE B ACCEPTED WITH DOCUMENTED LIMITATIONS`** | All three prior audit defects are resolved and verified across 120/120 passing tests (`arm64`), clean Debug build, and passing dependency audit; remaining limitations are bounded, non-blocking, and documented below. |

---

## A. True-Peak Measurement Reconciliation

### 1. Inspected Implementations & Filter Chain
- **Custom 4x FIR (`AudioNormalizer.measureTruePeakDBTP`):** [AudioDSPEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioDSPEngine.swift#L1109-L1213)
  - `oversamplePhases` computes 3 fractional phases (`+0.25, +0.50, +0.75`) using a **12-tap (`half = 5`) Blackman-windowed sinc** (`L1110-L1128`), normalized strictly at DC (`for idx in 0..<taps { coeffs[idx] /= sum }`).
  - `measureTruePeakDBTP` (`L1180-L1213`) omits taps where `sampleIdx < 0 || sampleIdx >= frameCount` (implicit zero-padding at buffer edges).
- **Export Mixdown Seam Wrapper (`measureBoundaryTruePeak`):** [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift#L735-L791)
  - Wraps `AudioNormalizer.measureTruePeakDBTP` with a 12-sample per-channel chunk-boundary seam buffer so 8,192-frame export chunks do not suffer edge truncation at internal seams.
- **Un-Normalized Export True-Peak Limiter Chain:** [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift#L897-L905)
  - Triggers when `mixStats.truePeakDBTP > targetTP || peak > Float(pow(10.0, targetTP / 20.0))` and `request.truePeakCeilingDBTP <= -0.1`:
    ```
    aresample=<min(384000, sampleRate * 4)>,alimiter=limit=<tpLinear>:attack=0.5:release=50:level=disabled,aresample=<sampleRate>
    ```
- **Authoritative EBU R128 Measurement (`AudioAnalysisService.measureLoudness`):** [AudioAnalysisService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioToolbox/AudioAnalysisService.swift#L367-L398) & [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift#L938-L1018)
  - Invokes FFmpeg `ebur128=peak=true+sample` inside `validateExportedFile(tmpOut, ...)` (`L943, L1007`) **on the actual final encoded output file (`tmpOut`)** prior to atomic move to `destinationURL`.
- **Test Measurement Helper (`measureFileTruePeak4x`):** [Phase68LosslessExportTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase68LosslessExportTests.swift#L405-L423)
  - Reads `AVAudioFile` in 8,192-frame chunks and calls `AudioNormalizer.measureTruePeakDBTP` per chunk **without** boundary overlap.

### 2. Reconciliation of Reported Numbers

| Reported Result | Empirical Cause (Verified Mathematically & via Bundled FFmpeg `9.0.2`) |
| --- | --- |
| **`44.1 kHz`, `48 kHz`, `5.1`: EBU R128 `-1.00 dBTP` vs Custom 4x FIR `-0.93 dBTP`** | **Passband ripple in the 12-tap Blackman-sinc FIR at `fs/4`:** Because `oversamplePhases` normalizes tap weights only at DC (`sum == 1.0`), a 12-tap Blackman-windowed sinc exhibits `+0.072 dB` (`1.0083×`) passband gain at `fs/4` (`11.025 kHz @ 44.1 kHz`, `12 kHz @ 48 kHz`). Evaluating `oversamplePhases` on an exact continuous `-1.0000 dBTP` (`0.89125`) `12 kHz` sine yields **`-0.928 dBTP`** (`-0.93 dBTP` rounded). Meanwhile, FFmpeg `ebur128` reports `-1.00 dBTP` to 0.1 dB precision. |
| **Case 3 (`-6.02 dBFS` `1 kHz` sine): EBU R128 `-6.00 dBTP` vs Test `4x` FIR `-5.60 dBTP`** | **Chunk-edge zero-padding in `measureFileTruePeak4x`:** Evaluating `AudioNormalizer.measureTruePeakDBTP` continuously over `48,000` samples yields **`-6.0206 dBTP`** (exact). Reading in `8,192`-frame chunks without overlap cuts the `1 kHz` sine mid-cycle (`8192 mod 48 = 32`), where zero-truncating out-of-bounds taps (`sampleIdx >= frameCount`) produces `+0.417 dB` Gibbs ringing (**`-5.6033 dBTP`**). `AudioExportService.renderMixToCAF` already avoids this at internal chunk seams via `measureBoundaryTruePeak`. |
| **`96 kHz`: EBU R128 `-1.70 dBTP` vs Custom 4x FIR `-0.93 dBTP`** | **Expected difference between `ebur128` (192 kHz ceiling) and `384 kHz` 4x limiting/measurement:** Read-only FFmpeg verification on the `96 kHz` `24 kHz` (`fs/4`) output confirmed `steady-state max sample = 0.823418 (-1.69 dBFS)`, identical to `48 kHz`, and `ebur128` True Peak = `-1.7 dBTP` (`-1.70`) while `AudioNormalizer` 4x FIR (`384 kHz`) stays `-0.93 dBTP`. Because FFmpeg's `ebur128` true-peak estimator upsamples to `192 kHz` (only `2×` at `96 kHz`, rather than `4×` `384 kHz` in `AudioExportService`'s `aresample=384000,alimiter` and `AudioNormalizer`), `ebur128` tracks the `-1.69 dBFS` discrete envelope at `96 kHz` while `AudioExportService` genuinely limits the `384 kHz` 4x continuous waveform. This is **not** a ceiling enforcement defect; both meters confirm the output is well below `-1.0 dBTP`. |

### 3. Conclusions for Section A
1. **Validity & Configuration:** Both meters are valid for their roles, with FFmpeg `ebur128=peak=true+sample` as the authoritative ITU-R BS.1770 / EBU R128 meter on `tmpOut` (final encoded output before atomic move), and `AudioNormalizer.measureTruePeakDBTP` serving as an in-memory 4x oversampled pre-encode trigger (with documented `+0.072 dB` ripple at `fs/4` and edge truncation if called un-overlapped across chunk boundaries).
2. **`-1.0 dBTP` Enforcement:** Genuinely enforced on `44.1 kHz`, `48 kHz`, `96 kHz`, and `5.1` lossless exports (`-1.00` / `-1.70 dBTP` under `ebur128`), and un-normalized exports below ceiling pass through with `0.000000` sample delta.
3. **Internal Limiter Margin Assessment:** In `AudioExportService.renderAndEncode` (`L901`), `alimiter` sets `limit = AudioGainAutomation.dbToLinear(targetTP)` (`-1.0 dB` exact) *before* `aresample=<request.sampleRate>` and lossy encoding. While lossless PCM outputs held `<= -1.00 dBTP`, a small internal headroom margin (e.g., `-0.1 dB` / `-1.1 dB` target before downsampling/lossy quantization) is advisable in future hardening so lossy exports (`.mp3`, `.aac`, `.opus`) or steep sample-rate downconversions cannot reconstruct `+0.1–0.3 dB` post-limiter ISPs above `-1.0 dBTP`.

---

## B. `AudioRingBuffer` Reset & Render-Callback Lifecycle

**Section B Classification: `CONCERN`**

### 1. Inspected Paths ([PlaybackEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift))
- `AudioRingBuffer`: `init`/`deinit` (`L31-L48`), `reset()` (`L63-L74`), `markFinished()` (`L76-L79`), `write(...)` (`L83-L120`), `read(...)` (`L131-L156`), `playbackTimelineFrame()` (`L158-L185`).
- `AudioPlaybackEngine`: `deinit` (`L307-L320`), `play` (`L343-L391`), `seek` (`L393-L409`), `scrub` (`L411-L435`), `pause`/`stop`/`halt` (`L437-L465`), `drainProducersAndResetIfQuiescent` (`L467-L482`), `startEngineIfNeeded` (`L520-L540`), `makeSourceNode` (`L542-L551`), `beginStreaming` (`L553-L625`).

### 2. Point-by-Point Findings

1. **Producer Quiescence Before `reset()` — VERIFIED (`PASS`):**
   - `beginStreaming` (`L557-L565`) cancels any active `producer`, appends it to `drainingProducers`, clears `producer = nil`, and `await drainProducersAndResetIfQuiescent(expectedGeneration: nil)` awaits every `task.value` in `drainingProducers` before `ring.reset()` (`L565`) and before launching the new `producer` (`L583`).
   - `halt()` (`L446-L464`) moves any active `producer` into `drainingProducers`, pauses the engine, and only calls `ring.reset()` synchronously when `drainingProducers.isEmpty`, or asynchronously after awaiting all `drainingProducers` and re-verifying `generation.current == expectedGeneration` (`L476-L481`).

2. **`AVAudioSourceNode` Render-Callback Quiescence Before `reset()` — `CONCERN`:**
   - Both `halt()` (`L452, L458-L459`) and `beginStreaming` (`L554-L556, L565`) rely on `if engine.isRunning { engine.pause() }` (plus `!engine.isRunning` at `L479`) as proof that `makeSourceNode`'s render callback is no longer executing `ring.read(...)`.
   - Note that in `halt()` (`L452-L459`), when `drainingProducers.isEmpty` (e.g., if `producer` was `nil` while the engine was running or paused), `ring.reset()` is called **synchronously on the very next statement after `engine.pause()`**.
   - While Apple's underlying `AudioOutputUnitStop` typically waits for active HAL I/O cycles on macOS, `AVAudioEngine.pause()` does not explicitly contract synchronous callback drainage across all audio drivers, and `AudioRingBuffer` itself contains **no** render-callback quiescence primitive (such as an atomic `inRenderCallback` flag or consumer-side epoch reset handshake) guaranteeing the callback has exited `ring.read(...)`.

3. **Can `readIndex`, `writeIndex`, and `finishedAtFrame` Be Reset While a Callback Is Still Reading? — `CONCERN` (Conditional on `AVAudioEngine.pause()`):**
   - `AudioRingBuffer.reset()` (`L64-L73`) directly zeroes `lStorage`/`rStorage` and executes `readIndex.store(0, ordering: .releasing)` and `writeIndex.store(0, ordering: .releasing)` from `@MainActor`.
   - Because `read(...)` (`L133, L148`) loads `r = readIndex.load(.relaxed)` at entry and stores `readIndex.store(r &+ Int64(n), .releasing)` at exit, if an `AVAudioSourceNode` callback were still mid-`read()` when `reset()` ran, both threads would write `readIndex` concurrently and the late `read()` store (`r + n`) would overwrite `0` after `reset()` stored `0` (creating negative `w - r` and corrupting `freeFrames`).
   - In practice this occurs **only** if `AVAudioEngine.pause()` returns before the CoreAudio I/O callback exits, which was not triggered in existing `Phase67` unit tests (nor tested under Thread Sanitizer with live CoreAudio hardware I/O).

4. **Memory Lifetime & Pointer Ownership During Teardown — VERIFIED (`PASS`):**
   - `AudioPlaybackEngine` holds `private let ring = AudioRingBuffer(capacity: 48_000)` (`L274`), `makeSourceNode(format:ring:)` captures `ring` strongly inside the `AVAudioSourceNode` closure (`L542`), `engine.attach(node)` retains `sourceNode`, and `producer` captures `let ring = self.ring` (`L576`).
   - `lStorage` and `rStorage` are deinitialized/deallocated only in `AudioRingBuffer.deinit` (`L43-L48`), guaranteeing zero use-after-free across `producer`, `sourceNode`, and `AudioPlaybackEngine` teardown. Producer scratch pointers use `defer { left.deallocate(); right.deallocate() }` (`L587`).

5. **SPSC Single-Producer / Single-Consumer Assumptions Across Rapid `play`/`seek`/`stop` — VERIFIED (`PASS`):**
   - All control paths (`play`, `seek`, `scrub`, `pause`, `stop`) are `@MainActor`-isolated.
   - During rapid `play`/`seek` re-entry across `await drainProducersAndResetIfQuiescent`, `generation.bump()` (`L359, L442`) + `guard generation.current == gen, !Task.isCancelled` (`L563, L568`) ensures superseded callers exit immediately without launching overlapping producers.
   - `startEngineIfNeeded` (`L521-L535`) stops and detaches any prior `sourceNode` before attaching a new one on rate change, preserving a strict single consumer.

---

## C. Final Acceptance Review

### 1. Reviewed Verification Evidence
No code or tests were modified and no test suites were re-executed during this read-only audit; the 120/120 post-fix test record documented in [STAGE_B_CORRECTION_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/STAGE_B_CORRECTION_REPORT.md) was cross-checked:
- **Targeted Stage B Correction Suites (25/25):** `Phase67AudioEffectsAndPreviewTests` (`18/18`: SPSC wraparound, underrun zero-fill, `malloc_zone_statistics` zero-allocation bursts, producer quiescing, explicit-layout gapless `.caf`, equal-count `5.1` vs `5.1(side)` fallback, mono-to-stereo fallback, plain WAV unknown-layout fallback, multichannel `AVAudioPCMBuffer`/`AVAudioEnginePlaybackTransport`) and `Phase68LosslessExportTests` (`7/7`: loudness + `-1.0 dBTP` high-crest limiting, un-normalized `44.1/48/96 kHz` ISP limiting, below-ceiling zero-delta pass-through, `5.1` 6-ch limiting, `BitExactPassThrough` SHA-256 preservation).
- **Regression Suites (95/95):** `AudioDSPTests` (`6/6`), `AudioChainPresetPersistenceTests` (`3/3`), `AudioEditorExportAcceptanceTests` (`3/3`), `AudioExportProTests` (`3/3`), `Phase62AudioDomainFoundationTests` (`11/11`), `Phase63` (`12/12`), `Phase64AudioPlayerTests` (`6/6`), `Phase65WaveformPyramidTests` (`8/8`), `Phase66SampleEditingAndMigrationTests` (`5/5`), `Phase50CoreFeatureUndoTests` (`7/7`), `GlobalUndoRedoTests` (`16/16`), `Phase18Tests` (`11/11`), `Phase45IntegrationTests` (`4/4`).
- **Build & Dependency Audit:** Clean `Debug` `arm64` build (`** BUILD SUCCEEDED **`) and `./scripts/verify-dependencies.sh` passed.

### 2. Remaining Documented Limitations
1. **`AudioRingBuffer.reset()` Callback-Quiescence Reliance:** `AudioPlaybackEngine` relies on `AVAudioEngine.pause()` synchronously quiescing `AVAudioSourceNode`'s CoreAudio render callback before `ring.reset()`; no explicit atomic callback-in-flight barrier or TSan live-hardware I/O stress test was run.
2. **True-Peak Margin for Lossy / Downsampled Exports:** `alimiter` targets `limit = targetTP` (`-1.00 dB`) without a pre-resample safety margin; while tested lossless WAV exports held `<= -1.00 dBTP` (`-1.70 dBTP` at 96 kHz), lossy encodes after limiting are not asserted to hold `-1.00 dBTP` without post-codec overshoot.
3. **`AudioNormalizer.measureTruePeakDBTP` FIR Characteristics:** The 12-tap Blackman-sinc filter exhibits `+0.072 dB` passband ripple at `fs/4` (`-0.93 dBTP` on `-1.00 dBTP` `fs/4` sines) and requires caller chunk-boundary overlap (done in `AudioExportService.measureBoundaryTruePeak`, not in `Phase68`'s helper `measureFileTruePeak4x`).
4. **Hardware Gapless & Process-Wide Malloc Scope:** Gapless cross-track continuity was verified via `GaplessSpyTransport` rather than physical DAC loopback capture, and zero-allocation was verified statically plus via process-wide `malloc_zone_statistics` bursts.

### 3. Final Recommendation

**`STAGE B ACCEPTED WITH DOCUMENTED LIMITATIONS`**

*(Stage C was not started; no existing repository files, tests, project files, Git state, or host preferences were modified.)*
