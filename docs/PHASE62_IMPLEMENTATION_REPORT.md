# Phase 62 Implementation Report — Audio Workspace Foundation & Sample-Frame Domain Core

## 1. Executive Summary

Phase 62 implemented the non-UI domain foundation for LocalConvert's native macOS 15+ (`arm64`, Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`) Audio Workspace while preserving existing Conversion Workspace behavior, `UserDefaults` / `AppStoragePaths` isolation (Phase 58 / 58.1), QoS-safe async fixture generation (Phase 60), and SwiftUI state hygiene (Phase 59).

**Final Classification:** `READY FOR PHASE 63`

Key deliverables completed and verified:
- **Sample-frame domain & time math** (`SampleFrameTime.swift`): Explicit `SampleRate` (`1...768_000` Hz), `SampleFrameTime`, signed `FrameDelta`, typed non-negative coordinate domains (`SourceFrameTime`, `TimelineFrameTime`, `RenderFrameTime`), and `SampleFrameRange` backed by exact `Int128` cross-rate rational arithmetic with deterministic round-half-away-from-zero ties and checked `Int64` bounds.
- **Audio Library, Playback, Editing & Export domain models** (`AudioLibraryModels.swift`, `PlaybackModels.swift`): Strictly validated, `Sendable`, `Codable`, `Hashable` value types enforcing domain invariants via custom `init(from:)`.
- **Shared output reservation decoupling** (`OutputReservationCoordinator.swift`, `ConversionManager+OutputReservation.swift`, `AudioExportService.swift`): Extracted thread-safe atomic output reservation, naming, source protection, and cleanup from `ConversionManager` into `OutputReservationCoordinator`, converting `ConversionManager` methods to compatibility forwarding shims and removing all `ConversionManager` dependencies from `LocalConvert/Engines/AudioEditor/`.
- **Storage path isolation & privacy diagnostics** (`AppStoragePaths.swift`, `StructuredDiagnostics.swift`): Added Audio Workspace path resolvers (`library.sqlite`, `AudioWaveformCache`, `player-session.json`, `AudioExportStaging`) with sandbox redirection and privacy-preserving diagnostics (`[REDACTED_AUDIO_FILE].<ext>` + metadata token sanitization).
- **Async QoS-safe fixture writer & Phase 62 test suite** (`SyntheticAudioFixtureWriter.swift`, `Phase62AudioDomainFoundationTests.swift`): Deterministic async fixture generator (`.wav`, `.aiff`, `.alac`, `.flac`; `.ape` `.unsupportedFormat` rejection) and 11 XCTest verification cases passing sequentially and in full regression.

---

## 2. Implemented Files

| File | Role | Lines |
| :--- | :--- | ---: |
| `LocalConvert/AudioWorkspace/Domain/SampleFrameTime.swift` | Sample rates, `SampleFrameTime`, signed `FrameDelta`, domain wrappers (`SourceFrameTime`, `TimelineFrameTime`, `RenderFrameTime`), `SampleFrameRange` | 493 |
| `LocalConvert/AudioWorkspace/Domain/AudioLibraryModels.swift` | Audio Library entities, `AudioMetadata`, collections/playlists, `AudioSelection`, `AudioEditOperation`, `AudioExportConfiguration`, `AudioRecoveryState` | 670 |
| `LocalConvert/AudioWorkspace/Domain/PlaybackModels.swift` | `PlaybackRepeatMode`, `PlaybackTransportState`, `PlaybackQueue`, `PlaybackSession` | 128 |
| `LocalConvert/Core/FileManagement/OutputReservationCoordinator.swift` | Extracted thread-safe atomic output reservation, source-protection guards, file finalization, and stale temp cleanup | 329 |
| `LocalConvert/Core/Conversion/ConversionManager+OutputReservation.swift` | Backward-compatible forwarding shims delegating `ConversionManager` reservation APIs to `OutputReservationCoordinator` | 128 |
| `LocalConvert/Engines/AudioEditor/AudioExportService.swift` | `AudioExportScope` (`Codable, Hashable, Sendable`) and `OutputReservationCoordinator` adoption (zero `ConversionManager` references) | 522 |
| `LocalConvert/Core/FileManagement/AppStoragePaths.swift` | Added `AudioWorkspaceStoragePaths`, `resolveAudioWorkspacePaths`, and sandbox-aware Audio Workspace URL accessors | 324 |
| `LocalConvert/Core/Diagnostics/StructuredDiagnostics.swift` | Added `.audioLibrary`, `.audioPlayer`, `.audioWaveform`, `.audioEditor`, audio filename/metadata redaction, and `recordAudioEvent` | 223 |
| `LocalConvertTestSupport/SyntheticAudioFixtureWriter.swift` | Async `withThrowingTaskGroup` deterministic audio fixture generator (`.wav`, `.aiff`, `.alac`, `.flac`, `.ape` rejection) | 349 |
| `LocalConvertTests/Phase62AudioDomainFoundationTests.swift` | Phase 62 unit & integration XCTest suite (11 tests covering math, `Codable`, reservation, storage, diagnostics, fixtures) | 601 |
| `docs/PHASE62_IMPLEMENTATION_REPORT.md` | Phase 62 engineering closure and Phase 63 readiness report | — |

Project generation (`xcodegen generate`) ran cleanly with exit code `0`, registering all new files into `LocalConvert.xcodeproj`.

---

## 3. `SampleFrameTime` Mathematical Verification

Verified in `SampleFrameTime.swift` and executed in `Phase62AudioDomainFoundationTests`:
- **`SampleRate` validation (`1...768_000` Hz):** `testSampleRateValidationBoundaries` verified boundary rates `1` Hz and `768_000` Hz, static presets (`rate44_1k`, `rate48k`, `rate88_2k` defined, `rate96k`, `rate192k`), and rejection of `0`, `-48_000`, and `768_001` with `SampleFrameError.invalidSampleRate`.
- **Exact `Int128` cross-rate conversion & tie policy:** `SampleFrameTime.convertInt128(_:from:to:)` computes `frame * Int128(targetRate.hz) / Int128(sourceRate.hz)` with deterministic **round-half-away-from-zero** tie breaking (`remainder.magnitude &* 2 >= denominator.magnitude`, adding `+1` for non-negative and `-1` for negative values). `testSampleFrameConversionsAndHalfAwayFromZeroTies` verified exact conversions (`441 @ 44.1k == 480 @ 48k == 960 @ 96k == 1_920 @ 192k -> 441 @ 44.1k`, `48_000 @ 48k == 44_100 @ 44.1k`), positive half-tie (`+1.5 -> +2`), negative delta half-ties (`-1.5 -> -2`, `-2.5 -> -3`), and `TimelineFrameTime.offset(by:)` negative boundary enforcement.
- **Overflow / underflow & negative-frame guards:** `testNegativeNonDeltaFrameRejectionAndOverflowUnderflow` verified rejection of negative frames on `SourceFrameTime`, `TimelineFrameTime`, and `RenderFrameTime` (`SampleFrameError.negativeFrameNotAllowed`), cross-rate `Int64` overflow/underflow detection via `Int64(exactly:)`, `FrameDelta(frames: Int64.min, ...).negated()` overflow check, and `adding(_:)` overflow check via `addingReportingOverflow`.
- **Cross-rate `Equatable`, `Comparable`, and `Hashable` (`gcd` canonicalization):** `testInt128CrossRateComparisonsAndRangeInvariants` verified exact `Int128` cross-multiplication equality/ordering (`441_000_000_000 @ 44.1k == 480_000_000_000 @ 48k`, `1 @ 3 Hz < 3 @ 6 Hz`, `3 @ 6 Hz == 1 @ 2 Hz`) and matching hash values produced by `gcd(frame.magnitude, UInt64(sampleRate.hz))`.
- **`SampleFrameRange` invariants:** Inclusive `startFrame >= 0`, non-negative `frameCount >= 0`, checked `startFrame.addingReportingOverflow(frameCount)`, valid zero-length ranges (`isEmpty == true`), and `validateNonEmptyForExport()` throwing `SampleFrameError.emptyExportRange` when empty.

---

## 4. `Codable` Invariant Safety Verification

All Phase 62 domain models enforce invariants identically across direct initializers and custom `init(from decoder: Decoder)` decoding paths:
- `SampleRate`: rejects values outside `1...768_000` (`SampleFrameError.invalidSampleRate`).
- `SourceFrameTime`, `TimelineFrameTime`, `RenderFrameTime`: reject negative frame indices during decode (`SampleFrameError.negativeFrameNotAllowed`).
- `SampleFrameRange`: validates `startFrame >= 0`, `frameCount >= 0`, and non-overflowing exclusive `endFrame` during decode.
- `AudioLibraryModels`: validates non-empty paths/identifiers (`LibraryRootFolder.path`, `AudioAsset.canonicalPath`), non-negative sizes/frame counts (`AudioAsset`), valid channel/bit-depth/bitrate/play-count/rating (`0...5`) ranges, finite non-negative duration, `AudioExportConfiguration` audio-only format check (`outputFormat.category == .audio`), `bitrateKbps` (`8...10_000`), `channelCount` (`1...16`), `targetLUFS` (`-70.0...0.0`), `truePeakCeilingDBTP` (`-12.0...0.0`), and `AudioRecoveryState.sourceSchemaVersion >= 1` (`AudioDomainValidationError`).
- `PlaybackModels`: `PlaybackQueue` rejects out-of-bounds `currentIndex` against `activeOrderIDs`; `PlaybackSession` validates non-negative `totalFrames`, finite `volume`/`preMuteVolume` (`0.0...1.0`), and finite `playbackRate` (`0.25...4.0`).

`testCodableRoundTripsAndInvariantRejection` verified clean JSON round-trips for valid `SampleFrameRange`, `AudioAsset`, `AudioExportConfiguration`, `PlaybackQueue`, and `PlaybackSession`, plus deterministic decoding failure across 13 malformed/out-of-invariant payloads.

---

## 5. `OutputReservationCoordinator` Extraction

- Created `LocalConvert/Core/FileManagement/OutputReservationCoordinator.swift` containing the synchronized `Registry` lock and static APIs: `validateWritableDirectory`, `outputURL`, `reserveOutputURL`, `reserveUniqueOutputURL`, `reserveMultiPageOutputURL`, `releaseReservedOutputURL`, `clearReservedOutputURLs`, `cleanStaleTemporaryFiles`, `finalizeOutputFile` (both input-URL and directory/baseName overloads), `moveOrReplaceTempFile`, `sanitizedOutputBaseName`, `uniqueOutputURL`, and `multiPageOutputURL`.
- Preserved `ConversionManager+OutputReservation.swift` as a pure compatibility facade delegating to `OutputReservationCoordinator`, avoiding breaking changes to Conversion Workspace call sites and existing tests.
- Updated `LocalConvert/Engines/AudioEditor/AudioExportService.swift` so `AudioExportScope` conforms to `Codable, Hashable, CaseIterable, Identifiable, Sendable` and reservation calls invoke `OutputReservationCoordinator.reserveUniqueOutputURL` / `OutputReservationCoordinator.releaseReservedOutputURL` directly.
- Repository grep confirmed `ZERO_CONVERSION_MANAGER_IN_AUDIO_EDITOR` across `LocalConvert/Engines/AudioEditor/`.
- `Phase62AudioDomainFoundationTests` verified:
  - 12 concurrent reservations for the same basename yielding 12 unique paths, plus base name reacquisition after `releaseReservedOutputURL`.
  - Concurrent `.overwrite` deduplication within an active reservation batch (avoiding mid-flight clobbering).
  - Source non-overwrite protection for trimmed video (`ConversionOptions.videoTrim`), external post-reservation collision rejection under `.createUnique` (`ConversionError.outputFileAlreadyExists`), explicit `.overwrite` atomic commit (`replaceItemAt`), and stale temp artifact cleanup.
  - `AudioExportService` usage of `OutputReservationCoordinator` without overwriting the source audio file.

---

## 6. Conversion Workspace Compatibility Results

Stage 3 compatibility verification executed all XCTest and Swift Testing suites covering output reservation, audio export, video trim, structured diagnostics, and core conversion pipelines:
- `Phase51VideoTrimTests` (XCTest): **8/8 PASS** (`7.378s`)
- `Phase57DiagnosticsAndSplitTests` (XCTest): **3/3 PASS** (`0.073s`)
- `AudioExportProTests` (`Phase 45.4 Audio Export Pro Validation Tests`, Swift Testing): **3/3 PASS** (`1.202s`)
- `Phase40Tests` (`Phase 40 — Distribution, Conversion Integrity & Image Fidelity`, Swift Testing): **12/12 PASS** (`5.759s`)
- `Phase422ClosureTests` (`Phase 42.2 — Large Image Memory Investigation, MP4 Multi-covr Artwork & Mid-Flight Cancellation`, Swift Testing): **4/4 PASS** (`54.673s`)
- `Phase41ValidationAndEfficiencyTests` (`Phase 41 — RC Validation, HDR Pixel Integrity, Resource Efficiency & 16-Workload Benchmarks`, Swift Testing):
  - **In Stage 3 (`/tmp/phase62_stage3_compat.log`):** **4/5 PASS**, 1 transient failure in `"16-Workload benchmark measures RSS, CPU, duration, temp cleanup, and 3-run steady-state stability"` at `Phase41ValidationAndEfficiencyTests.swift:560:13: Expectation failed: abs(drift) < 80.0` (23.312s). Note that all functional and `Atomic reservation handles 20 concurrent identical-name requests with zero collisions` assertions passed in Stage 3.
  - **In Stage 6 (`/tmp/phase62_stage6_full_tests.log`):** **5/5 PASS** (`✔ Suite "Phase 41 — RC Validation, HDR Pixel Integrity, Resource Efficiency & 16-Workload Benchmarks" passed after 22.344 seconds`).

---

## 7. `AppStoragePaths` Isolation

`AppStoragePaths.swift` added `AudioWorkspaceStoragePaths` and `resolveAudioWorkspacePaths(...)` alongside static accessors:
- `audioLibraryDatabaseURL`: `<Application Support>/<bundleID>/AudioLibrary/library.sqlite` (production) or sandbox `ApplicationSupport/AudioLibrary/library.sqlite` (testing)
- `audioWaveformCacheDirectory`: `<Caches>/<bundleID>/AudioWaveformCache` (production) or sandbox `Caches/AudioWaveformCache` (testing)
- `audioPlayerStateURL`: `<Application Support>/<bundleID>/AudioLibrary/player-session.json` (production) or sandbox `ApplicationSupport/AudioLibrary/player-session.json` (testing)
- `audioExportStagingDirectory`: `<Caches>/<bundleID>/AudioExportStaging` (production) or sandbox `Caches/AudioExportStaging` (testing)

`testAppStoragePathsAudioWorkspaceResolutionAndSandboxRedirection` verified production path resolution via pure dependency injection without disk writes to `~/Library`, sandbox path redirection inside `sandbox.rootURL`, idempotent parent directory creation, and absence of any materialized `library.sqlite` database file in Phase 62.

---

## 8. `StructuredDiagnostics` Changes

`StructuredDiagnostics.swift` added:
- Four new `DiagnosticCategory` cases: `.audioLibrary`, `.audioPlayer`, `.audioWaveform`, and `.audioEditor` (plus `isAudioWorkspaceCategory`).
- Audio-specific filename sanitization: audio categories redact full filenames to `[REDACTED_AUDIO_FILE].<ext>` instead of retaining original track titles (`testAudioDiagnosticCategoriesAndPrivacyRedaction` confirmed `.conversion` still preserves `lastPathComponent` e.g. `sample.png`).
- Metadata token & path sanitization (`sanitizeAudioMetadataTokens`): strips sensitive metadata values (`title`, `artist`, `album`, `albumArtist`, `composer`, `lyrics`, `comment`) to `<key>=[REDACTED]` and `/Users/...` / `/Volumes/...` paths to `[PATH_REDACTED]`.
- `recordAudioEvent(...)` convenience helper logging opaque short `assetID` prefixes and `ext.<extension>` hints instead of track names or paths.

---

## 9. `SyntheticAudioFixtureWriter` Results

`LocalConvertTestSupport/SyntheticAudioFixtureWriter.swift` implements structured-concurrency deterministic test audio generation using `withThrowingTaskGroup` and timeout enforcement (zero `DispatchSemaphore.wait()`, zero `Thread.sleep()`, zero `Task.detached`):
- **Verified formats in `Phase62AudioDomainFoundationTests`:**
  - `.wav` (44.1 kHz / 2 ch / 16-bit, `4_410` frames)
  - `.wav` (48 kHz / 2 ch / 24-bit, `4_800` frames)
  - `.aiff` (48 kHz / 2 ch / 16-bit, `4_800` frames)
  - `.alac` (`.m4a`, 48 kHz / 2 ch / 16-bit, `4_800` frames via bundled FFmpeg `-bitexact`)
  - `.flac` (48 kHz / 2 ch / 16-bit, `4_800` frames via bundled FFmpeg `-bitexact`)
- **Verified properties:** Exact sample rate, channel count, and frame length via `AVAudioFile`, cross-run PCM frame determinism within `1e-6`, explicit `.unsupportedFormat("ape")` rejection on `.ape`, and mid-flight task cancellation leaving no orphaned output file.

---

## 10. Build Results

All builds ran sequentially on `macOS` (`arm64`) after final edits:

| Check | Command Scope | Outcome | Warnings / Notes | Log File |
| :--- | :--- | :--- | :--- | :--- |
| `build-for-testing` | `LocalConvert` scheme (`arm64`) | `** TEST BUILD SUCCEEDED **` (exit `0`) | Zero errors or warnings in Phase 62 files (`ZERO_PHASE62_WARNINGS_OR_ERRORS`) | `/tmp/phase62_build_for_testing.log` |
| Final clean build | `xcodebuild clean build` (`arm64`) | `** BUILD SUCCEEDED **` (exit `0`) | Zero Swift/ObjC compiler warnings; zero `minos` linker warnings (only benign `appintentsmetadataprocessor` notice) | `/tmp/phase62_final_clean_build.log` |
| Immediate incremental build | `xcodebuild build` (`arm64`) | `** BUILD SUCCEEDED **` (exit `0`) | `COPY_BUNDLED_SKIPPED` confirmed (no unnecessary runtime recopy) | `/tmp/phase62_final_inc_build.log` |

---

## 11. Test Results

All tests ran sequentially under `-test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`:

| Stage | Target / Suite | Passed | Failed | Skipped | Not Run | Notes & Duration |
| :--- | :--- | ---: | ---: | ---: | ---: | :--- |
| Stage 1 | `LocalConvertTests/Phase62AudioDomainFoundationTests` | 11 | 0 | 0 | 0 | `0.426s` (`/tmp/phase62_stage1_p62.log`) |
| Stage 2 | `LocalConvertTests/Phase58_1UserDefaultsIsolationTests` | 5 | 0 | 0 | 0 | `0.048s` (`/tmp/phase62_stage2_p58_1.log`) |
| Stage 3 | `Phase51VideoTrimTests` + `Phase57DiagnosticsAndSplitTests` (XCTest) | 11 | 0 | 0 | 0 | `7.451s` (`/tmp/phase62_stage3_compat.log`) |
| Stage 3 | `AudioExportProTests` + `Phase40Tests` + `Phase41ValidationAndEfficiencyTests` + `Phase422ClosureTests` (Swift Testing) | 23 | 1 | 0 | 0 | `84.948s`; 1 transient RSS benchmark failure (`Phase41ValidationAndEfficiencyTests.swift:560:13: abs(drift) < 80.0`), passed in Stage 6 |
| Stage 4 | `LocalConvertUITests/Phase57UITests` | 6 | 0 | 0 | 0 | `65.579s`; zero `Publishing changes`, QoS, or `Thread Performance` warnings (`/tmp/phase62_stage4_p57_ui.log`) |
| Stage 5 | `LocalConvertTests/Phase60QoSSynchronizationTests` | 6 | 0 | 0 | 0 | `0.458s` (`/tmp/phase62_stage5_p60.log`) |
| Stage 6 | Full `LocalConvertTests` — XCTest suites | 79 | 0 | 2 | 0 | `81` executed in `13.474s`; 2 skips require `LOCALCONVERT_RAW_SAMPLES_DIR` (`Phase53VerificationTests`, `Phase56RAWAndPipelineTests`) |
| Stage 6 | Full `LocalConvertTests` — Swift Testing (77 suites) | 603 | 0 | 0 | 0 | `255.596s` (`** TEST EXECUTE SUCCEEDED **`, `/tmp/phase62_stage6_full_tests.log`) |
| Other UI Tests | `LocalConvertUITests` suites other than `Phase57UITests` | — | — | — | Remaining UI suites | Out of scope for Phase 62 domain verification |

---

## 12. Dependency Audit

Executed `./scripts/verify-dependencies.sh` (`/tmp/phase62_verify_deps.log`, exit `0`):
- **XcodeGen:** `2.48.0`
- **libwebp & libsharpyuv:** `arm64`, zero Homebrew linkage, `MinOS: macOS 15.0`
- **libjxl v0.13.0:** static `arm64` archives & headers, `MinOS: macOS 15.0`
- **FFmpeg & ffprobe `9.0.2`:** `arm64` static binaries, zero Homebrew linkage, `MinOS: macOS 15.0`
- **LibreOffice `26.8.0.3`:** `arm64`, zero Homebrew linkage, `MinOS: macOS 11.0`, strict deep code signatures verified on `LibreOffice.app` and `LibreOfficePython.framework`
- **Notices & App Icon metadata:** `LICENSE`, `LICENSE.webp`, `LICENSE.jxl`, `FFmpeg-LICENSE.txt`, `THIRD_PARTY_NOTICES.md`, and `CFBundleIconName` / `AppIcon` verified.

---

## 13. Git Preservation Verification

- Existing working-tree modifications and untracked user work were preserved untouched throughout Phase 62 (no `git reset`, `git clean`, `git stash`, `git checkout`, `git revert`, `git commit`, `git tag`, or `git push`).
- `git status --short` progressed only by the expected Phase 62 deliverables (`285` lines at baseline -> `288` lines after adding `LocalConvert/AudioWorkspace/`, `OutputReservationCoordinator.swift`, and `Phase62AudioDomainFoundationTests.swift`).

---

## 14. User Data Preservation Verification

Verified against the pre-Phase-62 baseline after all builds and test stages completed:
- **`UserDefaults` (`com.localconvert.app`):** `defaults export com.localconvert.app - | shasum -a 256` matched the starting checksum `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230`.
- **User Library directories (compared to `/tmp/phase58_1_userdata_baseline.json`):**
  - `~/Library/Application Support/com.localconvert.app`: `89` baseline -> `89` current (`added=0, removed=0, changed=0`)
  - `~/Library/Logs/LocalConvert`: `0` baseline -> `0` current (`added=0, removed=0, changed=0`)
  - `~/Library/Caches/com.localconvert.app`: `37` baseline -> `37` current (`added=0, removed=0, changed=0`)
- **`/Applications/LocalConvert.app`:** mtime remained unchanged at `1795224025`.

---

## 15. Known Limitations

1. **Intentional Phase 62 scope boundary:** SQLite/FTS5 persistence (`library.sqlite`), Library folder scanner, Audio Player AVAudioEngine/CoreAudio backend, Waveform Pyramid / `.lcwave` cache, Audio Workspace UI/navigation, v1/v2 -> v3 editor project migration, and `timeStretch` rational conversion are intentionally excluded from Phase 62 and deferred to Phase 63+.
2. **Environment-gated camera RAW sample tests:** Two pre-existing XCTest cases (`Phase53VerificationTests.testGenuineCameraRAWSamplesIfProvided` and `Phase56RAWAndPipelineTests.testGenuineCameraRAWSamplesMatrixIfProvided`) remain skipped when `LOCALCONVERT_RAW_SAMPLES_DIR` is unset.
3. **RSS benchmark sensitivity under standalone partial runs:** The existing `Phase41` 16-workload steady-state RSS drift assertion (`abs(drift) < 80.0` in `Phase41ValidationAndEfficiencyTests.swift:560`) failed once during Stage 3 partial execution before passing cleanly during the full Stage 6 regression run.

---

## 16. Deferred `timeStretch` Rational Representation Decision

1. **Current `Double` status in Phase 62:**
   Existing editor models in `LocalConvert/Engines/AudioEditor/AudioEditorModels.swift` continue to store `AudioEffectChainConfig.timeStretch: Double = 1.0` (interpreted as playback speed factor clamped in `AudioClip.stretch` to `0.25...4.0`, with UI inspection range `0.5...2.0` in `AudioEditorInspectorView.swift:239`), and `AudioClip` still tracks `timelineStart`, `sourceStart`, `duration`, and `sourceSpan` (`duration * stretch`) as `TimeInterval`. Phase 62 did not alter these editor structures.
2. **Why rational conversion is deferred out of Phase 62:**
   Phase 62 establishes the clean `AudioWorkspace/Domain` sample-frame foundation (`SampleFrameTime`, `SourceFrameTime`, `TimelineFrameTime`, `SampleFrameRange`) without refactoring `Engines/AudioEditor` v1/v2 project schemas, proxy rendering, or DSP time-stretching pipelines. Changing `AudioEffectChainConfig.timeStretch` mid-foundation would couple domain types to unmigrated editor timelines, proxy cache keys, and UI slider bindings before the v3 timeline migration phase.
3. **Proposed rational model (`TimeStretchRatio`):**
   Introduce an exact reduced rational value type backed by integer components—specifically `numerator: Int64` and `denominator: Int64` (strictly positive, `gcd`-canonicalized on initialization and custom `Codable` decode, bounded within `1/4 ... 4/1` to match the existing `0.25...4.0` clamp, with exact `1/1` identity representation and `Int128` cross-multiplication scaling against `SourceFrameTime` / `SampleFrameRange`).
4. **Backward-compatible migration strategy for persisted payloads:**
   Keep `AudioEffectChainConfig` v1/v2 `Codable` compatibility during decoding by reading optional `timeStretchRational` first and falling back to legacy `timeStretch: Double` via bounded rational approximation (e.g., Stern-Brocot / continued-fraction reduction within tolerance `<= 1e-6` or millisecond/percentage UI grid quantization) during v1/v2 -> v3 project upgrade, writing canonical rational state forward only in v3+ projects.
5. **Impact on sample-frame timeline mapping & export DSP:**
   Once migrated, mapping between `TimelineFrameTime` and `SourceFrameTime` for stretched clips will use `Int128` rational multiplication (`timelineFrames * numerator / denominator`) rather than `Double` floating-point multiplication, preventing cumulative sub-sample rounding drift at clip loop/split boundaries while supplying exact ratio targets to offline FFmpeg / `AVAudioUnitTimePitch` DSP renderers.
6. **Target phase gate for implementation:**
   Implement alongside the **Audio Editor v3 Timeline & Non-Destructive Project Migration** phase (post-Phase 63/64 Audio Library & Player core), gated by bit-exact clip split/join round-trip tests and legacy JSON fixture decode tests.

---

## 17. Phase 63 Readiness & Final Classification

All Phase 62 code deliverables compile cleanly on `arm64` under Swift 6 strict concurrency with zero warnings, all Phase 62 foundation tests (`11/11`) and isolation/UI/QoS/regression suites (`79/79` non-RAW-gated XCTests + `603/603` Swift Testing tests) pass, all bundled native dependencies pass audit, and git state plus user data remain intact.

**Final Readiness Classification:** `READY FOR PHASE 63`
