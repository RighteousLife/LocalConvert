# LocalConvert — Stage B Formal Closure Report (Milestone 2)

**Date:** 2026-11-26  
**Scope:** Milestone 2 — Stage B Formal Closure (`LC-007`), `AudioExportService.swift` Atomic Commit Migration (`LC-001`), and Bounded FFmpeg Watchdog Timeouts (`LC-006`).  
**Repository State:** `main` (`HEAD = 85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`, uncommitted pre-existing user & Milestone 1A/1B changes preserved).  
**Historical Reports Preserved Untouched:**
- [STAGE_B_FINAL_ACCEPTANCE_AUDIT.md](file:///Users/cancan/Desktop/LocalConvert/docs/STAGE_B_FINAL_ACCEPTANCE_AUDIT.md)
- [STAGE_B1_CALLBACK_QUIESCENCE_REPORT.md](file:///Users/cancan/Desktop/LocalConvert/docs/STAGE_B1_CALLBACK_QUIESCENCE_REPORT.md)

---

## 1. Stage B.1 Closure Evidence (Real-Time Playback & Callback Quiescence)

- **Architecture & Synchronization:**
  - `LocalConvert/Engines/AudioEditor/PlaybackEngine.swift` isolates every `.sourceNodeFallback` playback run in a distinct immutable `AudioRenderGeneration` with a permanent sequentially-consistent `AudioRenderCallbackGate` (eliminating mutable ring resets across play/seek/stop races).
  - Default `.playerNodePool` playback uses bounded `EditorPCMBufferPool` (8 × 2,048-frame slots + 1 transfer buffer), serialized `actor EditorPCMProducer`, and `@MainActor EditorPCMPlaybackScheduler`.
- **Current Milestone 2 Verification (`2026-11-26`):**
  - `Phase67AudioEffectsAndPreviewTests`: **20/20 passed, 0 failed** (`0` compiler/Swift 6 warnings in Milestone 2 files).
  - Covers `testAudioRingBufferSPSCConcurrencyWraparoundAndExactContinuity`, `testAudioRenderGenerationRetirementDuringInFlightReadIsolatedFromNextGeneration`, `testAudioRenderCallbackGateCloseRaceRejectsLateEntryWithoutWaiting`, `testAudioPlaybackEngineCancellationQuiescesProducerBeforeGenerationReplacement`, `testAudioRingBufferReadZeroHeapAllocations`, and all gapless/DSP/parity cases.
- **Thread Sanitizer (TSan) Status:**
  - Isolated `-enableThreadSanitizer YES` verification run on `2026-11-26` exited early at compile time (`code 65`) in an unrelated Milestone 1B test file outside Milestone 2 scope:
    - `/tmp/LocalConvert-M2-Generated/LocalConvertTests/Milestone1BPDFImageSafetyTests.swift:766:29: error: sending value of non-Sendable type '() async throws -> ConversionResult' risks causing data races [#RegionIsolation::SendingRisksDataRace]`
  - Historical TSan runs on unchanged `PlaybackEngine.swift` and `Phase67AudioEffectsAndPreviewTests.swift` prior to Milestone 1B passed with zero data-race reports (`4/4` + `1/1` in `docs/STAGE_B1_CALLBACK_QUIESCENCE_REPORT.md` on `2026-11-23`; `33/33` in `docs/AGENT_HANDOFF.md` on `2026-11-24`).

---

## 2. Stage B.2 & Export Hardening Evidence (`LC-001`, `LC-006`, `LC-007`)

### Modified Files
- [AudioMixingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioMixingService.swift)
  - Updated `AudioEditorFFmpeg.run(arguments:timeout:)` to default `timeout` to `BaseFFmpegProvider.defaultConversionTimeoutSeconds` (`1800.0` seconds) and forward it to `AsyncProcessRunner.run(..., timeout: timeout)`.
- [AudioExportService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/AudioExportService.swift)
  - **LC-001 (Atomic Publish):** Added `AudioExportService.publishExportedFile(_:to:operations:)` backed by `OutputReservationCoordinator.moveOrReplaceTempFile(..., policy: .overwrite)`. Replaced delete-before-move calls in `executeBitExactPassThrough` and `renderAndEncode`, and removed the redundant catch-block `removeItem(at: destURL)` in `export(...)`. Static check confirms **0** `removeItem(at: destinationURL` occurrences.
  - **LC-006 (Bounded Watchdog Timeouts):** Applied `ffmpegExportTimeoutSeconds` (`BaseFFmpegProvider.defaultConversionTimeoutSeconds`, `1800.0s`) to FFmpeg/FFprobe calls in `executeBitExactPassThrough`, `computeRawAudioPayloadSHA256`, `renderAndEncode`, and `probeDetailedAudioStream`.
  - **LC-007 (Stage B.2 Lossy True-Peak Enforcement):**
    - Lossy true-peak compliance gate (`isLossyTarget && request.truePeakCeilingDBTP <= -0.1`) now runs unconditionally regardless of `request.validateOutput`.
    - Keeps `-0.5 dB` pre-encode limiter headroom margin and executes up to 2 corrective re-encode passes using post-codec EBU R128 measurement (`AudioAnalysisService.shared.measureLoudness`).
    - If post-codec EBU R128 true peak is unmeasurable (`nil`) or still exceeds `requestedTargetTP + 0.05` after the 2 corrective passes, cleans up `tmpOut` (with `defer` removing `stageDir`) and throws `ConversionError.engineExecutionFailed` explicitly instead of silently succeeding or publishing non-compliant output.
    - Preserves `BitExactPassThrough` and un-normalized exports already below the true-peak ceiling (`0.000000` sample delta).
- [Phase68LosslessExportTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase68LosslessExportTests.swift)
  - Expanded `testStageB2LossyPostCodecTruePeakComplianceAndCompatibleMeasurement` to test `.mp3`, `.m4a` (AAC), `.opus`, and `.ogg` (Vorbis, unnormalized and `-14.0 LUFS` normalized) against `<= -1.00 dBTP` via independent FFmpeg EBU R128 measurement.
  - Added `testStageB2LossyTruePeakComplianceEnforcedWhenValidateOutputDisabled` (verifies `<= -1.00 dBTP` compliance across MP3/AAC/Opus/Ogg even with `validateOutput: false`).
  - Added `testStageB2UnresolvableLossyTruePeakOvershootFailsExplicitlyAndCleansStaging` (verifies 3 measurements = initial + 2 retries, explicit `ConversionError.engineExecutionFailed`, no published output file, and empty staging directory).
  - Added `testAtomicExportPublishPreservesExistingDestinationOnFailure` (verifies pre-existing destination bytes are preserved when atomic publish throws and cleanly replaced on `.live` publish).

---

## 3. Observed Verification Commands & Results (`2026-11-26`)

All commands ran against isolated temporary XcodeGen output in `/tmp/LocalConvert-M2-Generated` (`project.yml` and repository `LocalConvert.xcodeproj` untouched). All `/tmp/LocalConvert-M2-*` directories were deleted and verified absent afterward.

1. **Targeted Stage B Unit/Integration Tests (Isolated `/tmp` XcodeGen Build):**
```bash
xcodebuild test -project /tmp/LocalConvert-M2-Generated/LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/LocalConvert-M2-DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:LocalConvertTests/Phase67AudioEffectsAndPreviewTests -only-testing:LocalConvertTests/Phase68LosslessExportTests
```
- **Result:** `** TEST SUCCEEDED **` (exit `0`) — **31 executed, 0 failures** (`62.762s` test duration):
  - `Phase67AudioEffectsAndPreviewTests`: **20/20 passed**
  - `Phase68LosslessExportTests`: **11/11 passed**
- **Compiler Warnings:** `0` warnings emitted in `AudioExportService.swift`, `AudioMixingService.swift`, or `Phase68LosslessExportTests.swift`.

2. **Thread Sanitizer (TSan) Callback-Gate Subset Attempt:**
```bash
xcodebuild test -project /tmp/LocalConvert-M2-Generated/LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/LocalConvert-M2-TSan-DerivedData -enableThreadSanitizer YES CODE_SIGNING_ALLOWED=NO -only-testing:LocalConvertTests/Phase67AudioEffectsAndPreviewTests/testAudioRingBufferSPSCConcurrencyWraparoundAndExactContinuity -only-testing:LocalConvertTests/Phase67AudioEffectsAndPreviewTests/testAudioRenderGenerationRetirementDuringInFlightReadIsolatedFromNextGeneration -only-testing:LocalConvertTests/Phase67AudioEffectsAndPreviewTests/testAudioRenderCallbackGateCloseRaceRejectsLateEntryWithoutWaiting -only-testing:LocalConvertTests/Phase67AudioEffectsAndPreviewTests/testAudioPlaybackEngineCancellationQuiescesProducerBeforeGenerationReplacement
```
- **Result:** `** TEST FAILED **` (exit `65`, build cancelled before test execution) due to a compile error in unrelated Milestone 1B file `LocalConvertTests/Milestone1BPDFImageSafetyTests.swift:766:29` (`#RegionIsolation::SendingRisksDataRace`) outside Milestone 2 ownership.

---

## 4. Hardware & External Validation Status

- **Physical USB / Bluetooth DAC Hardware & Live CoreAudio Loopback Tests:** **`BLOCKED — EXTERNAL VALIDATION REQUIRED`**
  - Software synchronization invariants (`AudioRenderCallbackGate`, per-generation ring ownership, `EditorPCMBufferPool`, and gapless transport handoff) are validated in automated tests.
  - Physical USB/Bluetooth DAC attach/detach stress, driver-specific CoreAudio HAL I/O callback jitter, and physical hardware analog/digital loopback capture cannot be executed in this headless sandbox environment and require manual hardware QA on physical audio interfaces.

---

## 5. Final Classification

- **Stage B Formal Closure (Software & Automated Test Scope):** **CLOSED (`PASSED`)**
- **Hardware Loopback / Physical USB & BT DAC Stress:** **`BLOCKED — EXTERNAL VALIDATION REQUIRED`**
