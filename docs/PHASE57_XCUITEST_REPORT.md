# LocalConvert — Phase 57: XCUITest Infrastructure & Stabilization Report

**Date:** 2026-11-22  
**Target & Scheme:** `LocalConvertUITests` (`com.localconvert.uitests`) testing `LocalConvert` (`com.localconvert.app`) via `LocalConvert.xcodeproj`  
**Platform:** macOS 15.0+ Deployment Target (`arm64`), tested on macOS `27.2.1` (`26B131`), Xcode `27.2` (`27B52`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)

---

## 1. XCUITest Architecture & Isolation Harness

Prior to Phase 57, `LocalConvert` had no `LocalConvertUITests` target and only minimal accessibility identifiers. Phase 57 established an isolated UI test target generated via `project.yml` and `xcodegen generate`:

- **Target Definition (`project.yml`):** Added `LocalConvertUITests` (`type: bundle.ui-testing`, `platform: macOS`, `TEST_TARGET_NAME: LocalConvert`) and registered it in `schemes.LocalConvert.test.targets`.
- **Isolated `--uitesting` / `LOCALCONVERT_UITEST` Launch Harness (`LocalConvert/App/LocalConvertApp.swift`, `AppState.swift`, `ContentView.swift`, `MetadataView.swift`):**
  - Switched configuration passing from bare filesystem path arguments in `launchArguments` (which AppKit/SwiftUI interpreted as Finder document-open requests, suppressing `WindowGroup` window creation) to `launchEnvironment` (`LOCALCONVERT_UITEST="1"`, `LOCALCONVERT_UITEST_SANDBOX`, `LOCALCONVERT_UITEST_OUTPUT`, `LOCALCONVERT_UITEST_INPUTS`, `LOCALCONVERT_UITEST_METADATA`, `LOCALCONVERT_UITEST_TAB`) alongside `-ApplePersistenceIgnoreState YES`.
  - Injects per-session temporary instances of `RecoveryArtifactManager`, `UndoRedoCoordinator`, `UndoMenuController`, `HistoryManager`, `WatchFolderStore`, `MetadataManager`, and locked `uitestingOutputDirectory` inside the test runner's temporary sandbox, preventing any mutation of `~/Library/Application Support/com.localconvert.app/presets.json`, `history.json`, or `UserDefaults` output folder preferences.
- **Automated Post-Conversion Shell Guard (`LocalConvert/Core/ConversionQueue/ConversionQueue.swift:357`):**
  - `executeAfterConversionAction()` skips Finder reveal / external app launch (`NSWorkspace.shared.activateFileViewerSelecting` / `NSWorkspace.shared.open`) when running under `LOCALCONVERT_UITEST == "1"`, `NSClassFromString("XCTestCase") != nil`, or `XCTestConfigurationFilePath`. This prevents batch completion in UI tests from popping Finder windows in front of the app under test.
- **Stable Accessibility Identifiers (`21` call sites across `9` view files):**
  - `ContentView.swift`: `toolbar.undo`, `toolbar.redo`, `toolbar.editingHistory`, `error.alert.ok`, `sidebar.list`, `sidebar.tab.<rawValue_lowercased_underscored>`.
  - `DropZoneView.swift`: `dropzone.addFiles`, `dropzone.supportedFormats`.
  - `FileListView.swift`: `filelist.countLabel`, `filelist.clearAll`, `filelist.batchBannerTitle`, `filelist.convertAll`.
  - `FileRowView.swift`: `filerow.trimButton`.
  - `VideoTrimSheetView.swift`: `videotrim.cancelButton`, `videotrim.applyButton`.
  - `ImageToolboxView.swift`: `imagetoolbox.exportButton`.
  - `MetadataView.swift`: `metadata.activeFilename`.
  - `PresetManagerView.swift`: `presets.sectionPicker`.
  - `WatchFoldersSectionView.swift`: `watchfolders.emptyState`, `watchfolders.sheet.cancel`, `watchfolders.sheet.save`.

---

## 2. XCUITest Coverage (`LocalConvertUITests/Phase57UITests.swift`)

Six deterministic end-to-end UI smoke tests execute under Xcode 27.2's timeout flags (`-test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`):

1. `testLaunchAndPrimaryNavigationSmoke()` — Confirms initial `DropZoneView`, cycles across `jobs`, `image_toolbox`, `metadata`, `presets`, `history`, `settings`, and returns to `convert` (`dropzone.addFiles` visible).
2. `testImageConversionSuccessAndUndoUI()` — Synthesizes a 32×24 PNG, runs `filelist.convertAll`, verifies `"Batch Conversion Complete"`, invokes `toolbar.undo`, clears the queue (`filelist.clearAll`), and verifies return to `dropzone.addFiles`.
3. `testCorruptImageFailsSafelyWithoutOutputs()` — Feeds corrupt bytes named `corrupt_uitest.png`, triggers conversion, verifies `"Batch Finished with Issues"`, and confirms `outputDir` remains completely empty (zero partial output files).
4. `testImageToolboxExportAndMetadataInspectionSmoke()` — Launches directly on `Image Toolbox` with a 48×32 PNG, triggers `imagetoolbox.exportButton`, switches to `sidebar.tab.metadata`, and verifies `metadata.activeFilename`.
5. `testVideoTrimSheetOpensAndClosesSafely()` — Synthesizes a playable 15-frame 64×64 H.264 `.mp4` (`clip_uitest.mp4`) off the main thread (`DispatchQueue` + `DispatchSemaphore` + `OSAllocatedUnfairLock` + `AVURLAsset.load(.isPlayable)`), verifies `app.activate()` + `waitUntilHittable(...)`, clicks `filerow.trimButton`, confirms `videotrim.cancelButton` appears and is hittable, dismisses safely, and verifies queue continuity.
6. `testWatchFoldersUIAndAddSheetOpenSafely()` — Launches on `Presets`, selects `"Watch Folders"` in `presets.sectionPicker`, clicks `"Add Watch Folder..."`, verifies `watchfolders.sheet.cancel`, and closes cleanly without modifying user Watch Folder storage.

---

## 3. Defects Caught & Stabilized Across Phase 57 → Phase 57.1

Running XCUITest uncovered and fixed three concrete defects:

1. **AppKit Argument Interpretation (`WindowGroup` Suppression):** Passing filesystem paths via `launchArguments` suppressed initial SwiftUI window creation; resolved by moving path/config delivery to `launchEnvironment`.
2. **Real SwiftUI Accessibility `SIGSEGV` Crash (`LocalConvert/Features/Metadata/MetadataFieldView.swift`):**
   - Navigating to `MetadataView` with a loaded `.png` crashed `LocalConvert` (`EXC_BAD_ACCESS` stack guard overflow at `0x000000016ee33f80`) inside `AXUIElementCopyHierarchy`: `SwiftUI: AccessibilityNode.accessibilityLabel()` → `labelsToResolve` → `labelExposedAs` → `resolvedRole(forPlatformElement:)` → `PlatformAccessibilityElementProtocol.valueForAttribute` infinite recursion.
   - Resolved by extracting `writableTextField` directly with per-field `.accessibilityLabel` (removing the `Group` wrapper around `TextField`) and removing the conflicting `.accessibilityLabel` on the read-only `.textSelection(.enabled)` `Text` (aligning with `SettingsView`, `FileRowView`, `JobRowView`, `WatchFoldersSectionView`, and `PDFInspectorSecurityView`).
3. **Phase 57.1 XCTest `@MainActor` + `async tearDown()` Deadlock & Video Trim Hit-Testing:**
   - Removed class-level `@MainActor` and `async setUp()`/`async tearDown()`, restoring synchronous nonisolated `setUpWithError()`/`tearDownWithError()` with `@MainActor` restricted to synchronous UI helpers and `@MainActor func test*()` methods, converting `writeSyntheticMP4` to a synchronous background `DispatchQueue` helper, and adding bounded `waitUntilHittable` guards. (Detailed in `docs/PHASE57_1_XCUITEST_STABILITY_REPORT.md`.)

---

## 4. Test Verification Summary & Remaining Runtime Notices

- **XCUITest Execution Status (Verified in Phase 57.1; not re-run unnecessarily in Phase 57.2):**
  - Final Phase 57.1 run (`-test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 60`): **6/6 PASSED**, `0` failures, `0` timeouts in `65.331s` suite (`70.459s` elapsed session):
    - `testCorruptImageFailsSafelyWithoutOutputs`: `7.030s`
    - `testImageConversionSuccessAndUndoUI`: `11.446s`
    - `testImageToolboxExportAndMetadataInspectionSmoke`: `9.101s`
    - `testLaunchAndPrimaryNavigationSmoke`: `18.768s`
    - `testVideoTrimSheetOpensAndClosesSafely`: `9.900s`
    - `testWatchFoldersUIAndAddSheetOpenSafely`: `9.086s`
- **Full Unit/Integration Regression Context (Verified freshly in Phase 57.2):**
  - Full `LocalConvertTests` run under 60s timeout guard: **`651` passed, `2` env-gated genuine RAW skips (`Phase53` / `Phase56` without `LOCALCONVERT_RAW_SAMPLES_DIR`), `0` failures, `0` timeouts** in `266.749s`.
- **Documented Runtime Warnings (Observed in Phase 57.1 XCUITest logs; intentionally unedited during Phase 57.1/57.2 freeze):**
  1. `Phase57UITests.swift:182` Thread Performance Checker warning (`User-interactive` thread waiting on `Default` QoS `Task.detached` for `playableDone.wait`). Functional accuracy is unaffected; easily eliminable later by replacing `Task.detached` semaphore wait with synchronous MP4 container atom verification or `DispatchQueue`.
  2. SwiftUI runtime console warning `<unknown>:0: ... Publishing changes from within view updates is not allowed` observed during tab transitions in `testLaunchAndPrimaryNavigationSmoke` and `testImageToolboxExportAndMetadataInspectionSmoke`. Caused by pre-existing view-state observation/selection updates in production SwiftUI views; did not cause test failures or crashes after the `MetadataFieldView` fix, and warrants a separate focused SwiftUI state-update cleanup task.

---

## 5. Unverified / Manual UI Scenarios

The automated XCUITest smoke suite does **not** exercise and does **not** claim verification for:
- Real OS drag-and-drop gestures from Finder into the Drop Zone, Metadata, or Image Toolbox panes.
- Interactive `NSOpenPanel` / `NSSavePanel` modal file/folder selection flows.
- Multi-monitor window restoration / DPI scaling transitions.
- Real audio-track Video Trim AVPlayer playback and scrubbing with audio output devices.
- Live filesystem Watch Folder events (`FSEvents` / polling stability) triggered by external Finder/desktop file copies.
- Physical or virtualized macOS 15.x runtime execution (static macOS 15 deployment compatibility policy applies per Phase 55.1).
