# PHASE64_IMPLEMENTATION_REPORT.md

**Phase:** Phase 64 Remediation — CoreAudio Output Device Routing & Bidirectional Playback Arbitration  
**Repository:** `/Users/cancan/Desktop/LocalConvert/`  
**Branch:** `main` (`HEAD`: `85d6ba2cd4a6ffb5cf41700c3d288947f2945d99`)  
**Target Platform:** macOS 15.0+ (`MACOSX_DEPLOYMENT_TARGET: "15.0"`), Apple Silicon (`arm64`), Swift `6.0` (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Host Verification Environment:** macOS `27.2.1` (`Build 26B131`), Apple Swift `6.4.2`  
**Final Classification:** **READY WITH DOCUMENTED LIMITATIONS**

---

## 1. Executive Summary

Phase 64 Remediation closed the two remaining P1 subsystems identified by the Phase 64 Read-Only Gap Audit on top of Phase 63's verified SQLite Audio Library, Queue Manager, Streaming Decoders, and Player Engine:

1. **CoreAudio Output Device Monitoring & `AVAudioEngine` Routing (`CoreAudioOutputDeviceMonitor`, `AudioLibraryPlayerEngine`, `PlaybackCoordinator`, `AudioWorkspaceCoordinator`):**
   - Added persistent-UID device modeling (`AudioOutputDevice`), testable `CoreAudioHALBackend` abstraction + non-deprecated `SystemCoreAudioHALBackend`, dedicated serial HAL property listeners (`kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyDefaultOutputDevice`, `kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyNominalSampleRate`), and deterministic listener teardown (`stopMonitoring()` / `deinit`).
   - Extended `AudioPlaybackTransportProtocol` and `AVAudioEnginePlaybackTransport` with `setOutputDevice(deviceID: AudioDeviceID?)` using `engine.outputNode.auAudioUnit.setDeviceID(_:)`, added safe pause/reconfigure/seek/resume graph handling in `AudioLibraryPlayerEngine.setOutputDevice(deviceID:)`, wired real `outputDeviceUID` / `outputDeviceName` session persistence and UID-based launch restoration with System Default fallback (never auto-playing), and handled active-device hot-unplug fallbacks.
2. **Bidirectional Non-Destructive Playback Arbitration (`PlaybackArbitrationCenter`, `PlaybackCoordinator`, `AudioPlaybackEngine`):**
   - Added `@MainActor PlaybackArbitrationCenter` under `LocalConvert/Core/Audio/` with weak lifecycle-safe pause callbacks, re-entrancy protection (`isDispatching`), toggleable `isAutoPauseEnabled` (default `true`), and async load arbitration guarding (`supersededByArbitrationDuringLoad`).
   - Wired bidirectional pause notifications between `PlaybackCoordinator` (`.audioLibraryPlayer`) and `AudioPlaybackEngine` (`.audioEditor`) with zero circular dependency (`LocalConvert/Engines/AudioEditor/` holds zero references to `LocalConvert/AudioWorkspace/`).
3. **Pre-Existing Swift 6 Audio-Thread Bug Diagnosed & Fixed (`AudioPlaybackEngine.makeSourceNode`):**
   - Real Audio Editor playback tests caught a pre-existing Swift 6 `SIGTRAP` crash (`_dispatch_assert_queue_fail` on `com.apple.audio.IOThread.client`) caused by creating `AVAudioSourceNode` (`NS_SWIFT_NONSENDABLE` render block) directly inside `@MainActor func startEngineIfNeeded(rate:)` in [PlaybackEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift). Extracted a `private nonisolated static func makeSourceNode(format:ring:)` factory so the real-time render block carries no actor isolation assertion.

---

## 2. Original Git Baseline and Final Git Status

All pre-existing uncommitted work, staged index state (`0` staged files), `project.yml`, host `UserDefaults`, user data directories, and `/Applications/LocalConvert.app` were preserved intact:

| Check | Original Baseline (Pre-Phase 64) | Final State (Post-Phase 64 + Report) | Delta Explained |
| --- | --- | --- | --- |
| Branch / `HEAD` | `main` / `85d6ba2cd4a6ffb5cf41700c3d288947f2945d99` | `main` / `85d6ba2cd4a6ffb5cf41700c3d288947f2945d99` | Unchanged (zero commits) |
| Staged files | `0` | `0` | Clean |
| Modified tracked files | `78` (`12,258 ins, 3,920 del`) | `78` (`12,278 ins, 3,920 del`) | `+20 ins` solely in `LocalConvert.xcodeproj/project.pbxproj` via `xcodegen generate` |
| Untracked `git status --short` entries | `216` | `218` (`296` total status lines) | `+1` dir (`LocalConvert/Core/Audio/`), `+1` report (`docs/PHASE64_IMPLEMENTATION_REPORT.md`); `CoreAudioOutputDeviceMonitor.swift` & `Phase64AudioPlayerTests.swift` sit inside existing untracked directories |
| `defaults export com.localconvert.app - \| shasum -a 256` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` | `b49b25d4c4cdcfc548a051ac5ecedd8641c6f975f5c748137e0c818f9f5ca230` | Identical (`0` preference mutations) |
| `/Applications/LocalConvert.app` mtime | `1795224025` | `1795224025` | Untouched |
| User dirs vs `/tmp/phase58_1_userdata_baseline.json` | `app_support: 89`, `logs: 0`, `caches: 37` | `added=0, removed=0, changed=0` across all 3 dirs | Zero host user-data pollution |

---

## 3. Files Created and Modified

### 3.1 Created Files (4 files)

| Path | Responsibility | Lines (`wc -l`) |
| --- | --- | ---: |
| `LocalConvert/AudioWorkspace/Playback/CoreAudioOutputDeviceMonitor.swift` | `AudioOutputDevice`, `CoreAudioHALBackend`, `SystemCoreAudioHALBackend`, and `@MainActor CoreAudioOutputDeviceMonitor` | 561 |
| `LocalConvert/Core/Audio/PlaybackArbitrationCenter.swift` | `@MainActor PlaybackArbitrationCenter`, `PlaybackClientID`, and token lifecycle | 66 |
| `LocalConvertTests/Phase64AudioPlayerTests.swift` | Dedicated Phase 64 unit & integration tests (CoreAudio monitor, routing, persistence/fallback, arbitration, live read-only smoke check) | 722 |
| `docs/PHASE64_IMPLEMENTATION_REPORT.md` | This completion report | — |

### 3.2 Modified Files (7 files)

| Path | Modification Summary | Total Lines (`wc -l`) |
| --- | --- | ---: |
| `LocalConvert/AudioWorkspace/Domain/PlaybackModels.swift` | Added non-trapping `PlaybackSession.systemDefault` factory | 143 |
| `LocalConvert/AudioWorkspace/Playback/AudioLibraryPlayerEngine.swift` | Added `CoreAudio` routing (`setOutputDevice(deviceID:)` on transport + engine) and replaced `try! PlaybackSession()` fallback with `.systemDefault` | 721 |
| `LocalConvert/AudioWorkspace/Playback/PlaybackCoordinator.swift` | Integrated `CoreAudioOutputDeviceMonitor`, device selection/default/disconnect/sample-rate handling, UID session persistence/restore, and `.audioLibraryPlayer` arbitration hooks | 557 |
| `LocalConvert/AudioWorkspace/Integration/AudioWorkspaceCoordinator.swift` | Injected optional `outputDeviceMonitor` and `arbitrationCenter`, started monitor on `ensureInitialized()` | 86 |
| `LocalConvert/Engines/AudioEditor/PlaybackEngine.swift` | Wired `.audioEditor` arbitration hooks (`play`, `pause`, `deinit` unregistration) and extracted `nonisolated static func makeSourceNode(...)` | 378 |
| `LocalConvertTests/Phase63AudioPlaybackTests.swift` | Added `setOutputDevice(deviceID:)` conformance on `MockPlaybackTransport` (zero assertion changes) | 485 |
| `LocalConvert.xcodeproj/project.pbxproj` | Regenerated via `xcodegen generate` (`project.yml` untouched) to register the 3 new Swift files | — |

---

## 4. CoreAudio Architecture

Implemented in `LocalConvert/AudioWorkspace/Playback/CoreAudioOutputDeviceMonitor.swift`:

- **Stable Device Identity (`AudioOutputDevice`):** Captures `deviceID: AudioDeviceID`, persistent `uid: String`, `name: String`, `nominalSampleRateHz: Double`, `outputChannelCount: Int`, and `isDefault: Bool`, using `uid` (`var id: String { uid }`) for persistence rather than transient `AudioDeviceID` integers.
- **HAL Protocol Abstraction (`CoreAudioHALBackend`):** Decouples CoreAudio HAL queries and listener registration so `Phase64AudioPlayerTests` exercises enumeration, sample-rate updates, default switching, disconnect detection, and listener symmetry without physical USB audio device hot-unplugging.
- **Production HAL Implementation (`SystemCoreAudioHALBackend`):**
  - Uses non-deprecated macOS 15+ property scopes (`kAudioObjectPropertyScopeGlobal`, `kAudioObjectPropertyScopeOutput`, `kAudioObjectPropertyElementMain`).
  - Enumerates `kAudioHardwarePropertyDevices`, resolves `kAudioHardwarePropertyDefaultOutputDevice`, inspects output stream layouts via `kAudioDevicePropertyStreamConfiguration` (summing `mNumberChannels` across an aligned `AudioBufferList` buffer), validates `kAudioDevicePropertyDeviceIsAlive`, and queries `kAudioDevicePropertyNominalSampleRate`.
  - Reads CFString properties (`kAudioDevicePropertyDeviceUID`, `kAudioObjectPropertyName`) via `Unmanaged<CFString>?.takeRetainedValue()` to prevent CF over-release bugs.
- **Listener Lifecycle:** Registers system listeners (`kAudioHardwarePropertyDevices`, `kAudioHardwarePropertyDefaultOutputDevice`) and per-active-device listeners (`kAudioDevicePropertyDeviceIsAlive`, `kAudioDevicePropertyNominalSampleRate`) onto serial `halQueue` (`qos: .utility`), forwarding updates to `@MainActor` with `[weak self]`. Tokens are stored inside lock-protected `ListenerRegistry` (`SystemCoreAudioHALBackend`) and `cleanupLock` (`CoreAudioOutputDeviceMonitor`) so `stopMonitoring()` and `deinit` deterministically invoke `AudioObjectRemovePropertyListenerBlock`.

---

## 5. Output Device Routing Behavior

Implemented across `AudioPlaybackTransportProtocol`, `AVAudioEnginePlaybackTransport`, `AudioLibraryPlayerEngine`, and `PlaybackCoordinator`:

- **Production Graph Routing (`AVAudioEnginePlaybackTransport.setOutputDevice(deviceID:)`):**
  - Resolves `nil` to `SystemCoreAudioHALBackend().defaultOutputDeviceID()` (throws `.engineStartFailed` if no system default exists).
  - Halts `playerNode` and `engine` (if running), disconnects `playerNode` and `timePitch` (`isGraphConnected = false`), assigns `try engine.outputNode.auAudioUnit.setDeviceID(targetID)`, reconnects `playerNode -> timePitch -> mainMixerNode` if `configuredFormat` is present, and prepares the engine.
- **Engine State Preservation (`AudioLibraryPlayerEngine.setOutputDevice(deviceID:)`):**
  - Captures `wasPlaying`, `savedFrame = position?.frame ?? seekAnchorFrame`, and `streamInfo`.
  - Increments monotonic `generation`, cancels feed/progress loops, resets the node (`inFlightChunkCount = 0`, `decoderReachedEOF = false`), switches the transport device, reconfigures sample rate & channel layout, seeks `decoder` back to `savedFrame`, and restarts engine + streaming loops **only** if `wasPlaying` was true and all reconfiguration steps succeeded.
  - On any thrown reconfiguration error, sets `playbackState = .error(error.localizedDescription)` (never falsely leaving `.playing`) and records a redacted `[AudioPlayer][INTERNAL_ERROR][output_device_switch]` event via `StructuredDiagnostics.recordAudioEvent`.
- **Coordinator Selection:** `PlaybackCoordinator.selectOutputDevice(uid:)` accepts `nil` (System Default) or a valid persistent UID (refreshes monitor if needed, routes resolved `deviceID`, and schedules persisted session save). Unknown/unavailable UIDs return `false` safely.

---

## 6. Device Disconnection and Fallback Behavior

- **Active Device Disconnection:** When `CoreAudioOutputDeviceMonitor.refreshDevices()` detects `selectedDeviceUID` is missing, dead, or zero-output, it resets `selectedDeviceUID = nil`, rebinds per-device listeners to the new `defaultDevice`, logs a redacted validation diagnostic event (`output_device_disconnected`), and invokes `onActiveDeviceDisconnected`. `PlaybackCoordinator.handleActiveOutputDeviceDisconnected()` immediately routes `engine.setOutputDevice(deviceID: nil)` when a fallback default device exists (or stops cleanly if none exists) and persists `"System Default"` (`outputDeviceUID = nil`).
- **System Default Switching:** When `selectedDeviceUID == nil` (System Default mode) and CoreAudio changes the default device (`onDefaultDeviceChanged`), `PlaybackCoordinator` cleanly re-routes `engine.setOutputDevice(deviceID: nil)`.
- **Nominal Sample Rate Changes:** `onActiveDeviceSampleRateChanged` reconfigures active loaded streams smoothly through `engine.setOutputDevice(deviceID:)`.

---

## 7. Playback Session Persistence Behavior

Preserved the existing `PlaybackSession` (`schemaVersion = 1`) `Codable` JSON layout at `AppStoragePaths.audioPlayerStateURL` (`player-session.json`) without any SQLite schema change:

- `PlaybackCoordinator.currentSessionSnapshot()` populates real `outputDeviceUID` (`nil` for System Default or active UID) and `outputDeviceName` (`"System Default"` or resolved device name) on both debounced `schedulePersistSession()` and `flushPersistedSession()`.
- `restoreSavedSessionIfPresent()` refreshes `outputDeviceMonitor`:
  - If `restored.session.outputDeviceUID` resolves to an available device, `PlaybackCoordinator` selects it and routes `engine.setOutputDevice(deviceID: device.deviceID)`.
  - If the saved UID is unavailable on relaunch, it falls back to System Default (`nil`), routes to System Default if available, and re-saves the fallback session cleanly.
- All restored tracks load with `autoPlay: false` and `PlaybackStatePersistence` coerces `.playing`/`.loading` to `.paused`/`.stopped`, guaranteeing zero unsolicited autoplay on relaunch.

---

## 8. Playback Arbitration Architecture

Implemented in `LocalConvert/Core/Audio/PlaybackArbitrationCenter.swift`:

- Placed in `Core/Audio/` so both `AudioWorkspace` (`.audioLibraryPlayer`) and `Engines/AudioEditor/` (`.audioEditor`) depend inward cleanly with zero cross-workspace circularity (`rg` verified zero `AudioWorkspace`/`CoreAudioOutputDeviceMonitor` references in `LocalConvert/Engines/AudioEditor/`).
- Uses value-type `PlaybackClientID` and opaque `PlaybackArbitrationRegistrationToken`.
- `@MainActor` synchronous pause dispatch with `isDispatching` re-entrancy guard prevents infinite loops under rapid alternating play transitions.
- **Bidirectional Entrypoints:**
  - `.audioEditor` ([PlaybackEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift)): notifies `.audioEditor` at the start of `play(from:project:autoStopAfter:)` (covering Play, Scrub, and active-Seek), pausing via existing non-destructive `pause()` (`halt()`).
  - `.audioLibraryPlayer` ([PlaybackCoordinator.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/AudioWorkspace/Playback/PlaybackCoordinator.swift)): notifies `.audioLibraryPlayer` on `loadTrack(..., autoPlay: true)`, `togglePlayPause()` when starting/resuming, and `previous()` resume. An async `supersededByArbitrationDuringLoad` flag prevents an awaiting async `loadTrack` from starting `.playing` if `.audioEditor` intervened mid-load.
- Both `PlaybackCoordinator` and `AudioPlaybackEngine` unregister deterministically in `deinit` and explicit `unregisterFromArbitration()`, with `[weak self]` closures ensuring deallocated clients never receive callbacks.

---

## 9. Audio Editor Non-Destructive Preservation Evidence

Verified in `testBidirectionalArbitrationPreservesEditorStateAndLibraryQueue` ([Phase64AudioPlayerTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase64AudioPlayerTests.swift)) against real `AudioEditorStore`, `UndoRedoCoordinator`, and `AVAudioEngine`-backed `AudioPlaybackEngine`:

- With an imported clip, playhead positioned at `0.75 s`, flushed `UndoHistory` (`1` entry), and `isDirty == false`:
  1. Starting Editor playback paused the active Library player cleanly without clearing Library queue order (`orderedTrackIDs`) or losing seek position (`0.5 s`).
  2. Resuming Library playback paused active `AudioPlaybackEngine` (`isPlaying == false`, `isPreparing == false`) synchronously via `PlaybackArbitrationCenter`.
  3. Post-arbitration checks verified `editorStore.project`, `clips`, `timeline.playheadTime`, `undoCoordinator.undoEntries(for: editorContext)`, and `editorStore.isDirty` remained **100% identical**.

---

## 10. Swift 6 Concurrency Analysis

- Built with `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, `ARCHS: "arm64"`, and `MACOSX_DEPLOYMENT_TARGET: "15.0"` with **0 compiler or concurrency warnings**.
- **Pre-Existing Bug Resolved:** Fixed `AudioPlaybackEngine.startEngineIfNeeded(rate:)` in [PlaybackEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/AudioEditor/PlaybackEngine.swift), where `AVAudioSourceNode(format:)` (`NS_SWIFT_NONSENDABLE` render block) inherited `@MainActor` isolation and trapped (`SIGTRAP`) on `com.apple.audio.IOThread.client`. Extracting `private nonisolated static func makeSourceNode` eliminated the runtime isolation trap cleanly.
- **Minimal `@unchecked Sendable` Scope:** The only `@unchecked Sendable` introduced in Phase 64 production code is `SystemCoreAudioHALBackend.ListenerRegistry`, whose exact invariant (`entries` accessed exclusively inside `NSLock` because C `AudioObjectPropertyListenerBlock` lacks `@Sendable` in SDK headers) is documented inline and paired with `deinit` listener removal. `CoreAudioOutputDeviceMonitor`, `PlaybackCoordinator`, `PlaybackArbitrationCenter`, and `AVAudioEnginePlaybackTransport` use `@MainActor`, `Sendable`, and `OSAllocatedUnfairLock` without `nonisolated(unsafe)`, `Task.detached`, or `DispatchSemaphore.wait()`.

---

## 11. Test Results

All final test runs executed sequentially **after** all code edits (`LocalConvertTests/Phase64AudioPlayerTests.swift` + targeted/full suites):

| Test Run | Log | Executed | Passed | Failed | Skipped | Duration |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Stage 1** (`Phase64AudioPlayerTests` CoreAudio monitor) | `/tmp/phase64_stage1_test.log` | 2 | 2 | 0 | 0 | `0.294 s` |
| **Stage 2** (`Phase64AudioPlayerTests` 4 + `Phase63AudioPlaybackTests` 5) | `/tmp/phase64_stage2_test.log` | 9 | 9 | 0 | 0 | `1.324 s` |
| **Stage 3 Re-run** (`Phase64AudioPlayerTests` 6 + `Phase63AudioPlaybackTests` 5) | `/tmp/phase64_stage3_test.log` | 11 | 11 | 0 | 0 | `1.716 s` |
| **Full `LocalConvertTests` — XCTest (all 17 classes)** | `/tmp/phase64_full_tests.log` | 99 | 97 | 0 | 2 | `16.232 s` |
| **Full `LocalConvertTests` — Swift Testing (all 77 suites)** | `/tmp/phase64_full_tests.log` | 603 | 603 | 0 | 0 | `258.048 s` |
| **UI Regression (`LocalConvertUITests/Phase57UITests`)** | `/tmp/phase64_p57_ui.log` | 6 | 6 | 0 | 0 | `70.660 s` |

*(Pre-existing XCTest skips in Full Run: `Phase53VerificationTests.testGenuineCameraRAWSamplesIfProvided` and `Phase56RAWAndPipelineTests.testGenuineCameraRAWSamplesMatrixIfProvided` — both `LOCALCONVERT_RAW_SAMPLES_DIR` not configured. UI log verified `ZERO_UI_WARNINGS`: no `Publishing changes`, QoS, or `Thread Performance` warnings.)*

### Phase 64 New Test Cases (`Phase64AudioPlayerTests`, 6/6 PASS in `0.881 s` in Full Run)
1. `testCoreAudioMonitorFilteringEnumerationDefaultDisconnectAndListenerLifecycle`
2. `testLiveHostCoreAudioReadOnlyEnumerationSmoke` *(strictly read-only host HAL check)*
3. `testOutputDeviceSelectionSystemDefaultPersistenceRestorationAndFallback` *(mock HAL + mock routing transport + real SQLite/persistence)*
4. `testOutputDeviceDisconnectFallbackAndFailedReconfigurationNeverFalsePlaying` *(mock HAL + mock routing transport)*
5. `testBidirectionalArbitrationPreservesEditorStateAndLibraryQueue` *(real `AudioEditorStore`, `UndoRedoCoordinator`, real `AVAudioEngine`-backed `AudioPlaybackEngine`, real `PlaybackArbitrationCenter.shared` + `PlaybackCoordinator`)*
6. `testArbitrationRapidAlternatingDisabledAutoPauseAndUnregistrationLifecycle` *(isolated center, rapid alternating starts, `setAutoPauseEnabled(false)`, unregistration + `AudioPlaybackEngine` `deinit` cleanup)*

---

## 12. Existing Regression Test Results

Verified within Targeted Run (`/tmp/phase64_targeted_reg.log`, `29/29` XCTest + `32/32` Swift Testing in 7 Audio Editor suites) and Full Run (`/tmp/phase64_full_tests.log`):
- `Phase62AudioDomainFoundationTests`: `11/11` PASS (`0.393 s`)
- `Phase63AudioLibraryDatabaseTests`: `4/4` PASS (`0.047 s`)
- `Phase63AudioLibraryScannerAndMetadataTests`: `3/3` PASS (`0.693 s`)
- `Phase63AudioPlaybackTests`: `5/5` PASS (`0.750 s`)
- Audio Editor Swift Testing (`AudioEditorCoreTests`, `AudioTimelineTests`, `AudioEditorExportAcceptanceTests`, `AudioExportProTests`, `AudioDSPTests`, `AudioChainPresetPersistenceTests`, `AudioEditorPerformanceTests`): `32/32` PASS (`3.772 s`)
- All remaining XCTest & Swift Testing suites (`Phase49–Phase60`, `Phase20/20B`, Smart Presets, Conversion, Image, PDF, Metadata): `0` failures (`700/702` passed across `LocalConvertTests`, `2` RAW skips; `6/6` `Phase57UITests` passed).

---

## 13. Dependency Audit

- Executed `./scripts/verify-dependencies.sh` (`/tmp/phase64_verify_deps.log`) -> exited `0` (`🎉 All checked dependencies and binary requirements passed audit!`).
- **Build Checks:**
  - `build-for-testing` (`/tmp/phase64_build_for_testing.log`): `** TEST BUILD SUCCEEDED **`, `ZERO_COMPILER_OR_MINOS_WARNINGS`.
  - Clean `arm64` build (`/tmp/phase64_clean_build.log`): `** BUILD SUCCEEDED **`, `ZERO_CLEAN_BUILD_WARNINGS`.
  - Incremental `arm64` build (`/tmp/phase64_inc_build.log`): `** BUILD SUCCEEDED **`, `COPY_BUNDLED_SKIPPED` verified.
- Zero external libraries, zero CocoaPods/SPM additions, and zero Homebrew linkage introduced (`CoreAudio` and `AVFAudio` are standard macOS system frameworks).

---

## 14. macOS 15 Compatibility Assessment

- **Static Compatibility (Verified):** Project builds cleanly with `MACOSX_DEPLOYMENT_TARGET: "15.0"`, `ARCHS: "arm64"`, non-deprecated CoreAudio selectors (`kAudioObjectPropertyScopeOutput`, `kAudioObjectPropertyScopeGlobal`, `kAudioObjectPropertyElementMain` from macOS 12.0+), and `AUAudioUnit.setDeviceID(_:)` (macOS 10.11+). `verify-dependencies.sh` confirmed `MinOS: macOS 15.0` (and `11.0` for LibreOffice).
- **Dynamic Runtime Gap:** All test executions ran on the local host macOS `27.2.1` (`Build 26B131`); runtime execution on a macOS `15.0` OS image/VM has not yet been performed.

---

## 15. Remaining Limitations

1. **Simulated CoreAudio Device Hot-Unplug & Switching:** Hot-unplug disconnect fallback, sample-rate changes, and `setOutputDevice(deviceID:)` failure transitions were verified deterministically using `MockCoreAudioHALBackend` and `MockRoutingPlaybackTransport`; live `AVAudioEngine.outputNode.auAudioUnit.setDeviceID(_:)` switching across physical multi-DAC hardware and physical USB unplugging were not executed.
2. **Deferred Roadmap / Polish Items:**
   - **Output Device Picker UI & Auto-Pause Toggle in `Settings`:** Phase 64 focused on headless backend/engine/coordinator routing and arbitration per roadmap; exposing the output device picker popover in `AudioPlayerBarView` and user preference toggle for `isAutoPauseEnabled` belongs cleanly to UI integration (Phase 69) if not requested earlier.
   - **Gapless Same-Rate Track Handoff:** `AudioLibraryPlayerEngine` advances tracks cleanly on `onTrackEnded` (~few ms reload gap) rather than pre-scheduling next-track PCM chunks onto the same active queue before EOF.
   - **Audio Workspace XCUITests:** Automated UI driving of `AudioWorkspaceRootView` remains for Phase 71 per roadmap.
3. **macOS 15 Runtime:** Verified statically (`MinOS: macOS 15.0`), not dynamically on a macOS 15 OS host.

---

## 16. Known Risks

- **Multi-Device Hardware Quirks During Live Switching:** Certain Bluetooth/HDMI/AirPlay aggregate output devices on macOS may temporarily pause or alter sample rates during `setDeviceID(_:)`, triggering `.AVAudioEngineConfigurationChange` right after manual routing; `handleEngineConfigChange()` safely pauses playback cleanly if triggered while playing rather than crashing.
- **CoreAudio HAL Listener Bursting:** Rapid Bluetooth/dock reconnections can enqueue multiple HAL callbacks on `halQueue`; dispatching `refreshDevices()` on `@MainActor` serializes refreshes coherently while comparing state against previous snapshots.

---

## 17. Phase 65 Readiness Assessment & Final Classification

All Phase 64 P1 gaps identified in the gap audit (`CoreAudioOutputDeviceMonitor`, `AVAudioEngine` output device routing + disconnect fallback + `PlaybackSession` UID persistence/restore, and bidirectional non-destructive `PlaybackArbitrationCenter`) are implemented, registered in XcodeGen (`project.pbxproj`), isolated from Conversion Workspace and user data, and verified with `700/702` passing `LocalConvertTests` (`2` RAW env-gated skips), `6/6` `Phase57UITests`, clean/incremental `arm64` builds, and dependency audit. No blockers prevent starting Phase 65 (Multi-Resolution Peak Pyramid Waveform Engine).

**Final Classification:** **READY WITH DOCUMENTED LIMITATIONS**

*(Report complete. No staging or commits performed. Stopping before Phase 65 as instructed.)*
