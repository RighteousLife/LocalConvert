# LocalConvert — Phase 52 Implementation Report: Watch Folder & Automated Preset Execution

**Date:** 2026-11-22  
**Target Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Workspace:** `/Users/cancan/Desktop/LocalConvert/`  

---

## 1. Objective & Architectural Integration

Phase 52 delivers offline Watch Folder monitoring and automated preset execution as a cohesive extension of LocalConvert's existing preset, queue, output-reservation, undo, and lifecycle subsystems—without introducing a parallel conversion engine, extra top-level sidebar tab, or secondary application window.

### Execution & Integration Pipeline

1. **Monitoring (`WatchFolderMonitor`)**: Wraps macOS `FSEventStream` (`kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer`) on a private `.utility` `DispatchQueue`, protected by `NSLock` under Swift 6 strict concurrency. Supports non-recursive vs. recursive directory watching, excluded output directory prefixes, debounced batch coalescing, and clean teardown via `stop()`.
2. **Stability & Write-Completion (`FileStabilityDetector`)**: Requires at least two consistent content fingerprint captures (`fileSize`, `contentModificationDate`, `fileResourceIdentifier`) separated by `settleDelaySeconds`, verifies open readability before handoff, rejects zero-byte/locked files past `maxWaitSeconds` as `.timedOut`/`.unreadable`, and skips hidden/temporary/symlink/system items via `WatchFolderPathSafety.isTemporaryOrHiddenFile(_:)`.
3. **Validation & Loop Prevention (`WatchFolderValidator`, `WatchFolderManager`)**:
   - Rejects empty names, missing/unreadable directories or unavailable volumes, missing presets, duplicate folder rules, overlapping recursive rules, `input == output`, `input inside output`, and file targets specified as output directories.
   - Prevents infinite loops by excluding `<Watched>/<Subfolder>` prefixes from both FSEvents and directory rescans, enforcing runtime path checks before queueing, and maintaining bounded provenance records (`knownGeneratedOutputPaths`, `knownGeneratedResourceIDs`) from completed `ConversionResult.allOutputURLs` so generated outputs copied back into a watched directory are ignored.
4. **Preset Execution & Global Undo (`PresetExecutor` + `ConversionQueue`)**:
   - Extended `PresetExecutor.execute(...)` with `collisionPolicyOverride: ExistingFileHandling? = nil` so per-rule collision policies (`.createUnique`, `.overwrite`, `.skip`) pass straight through the standard preset pipeline.
   - `WatchFolderManager` enqueues jobs via `PresetExecutor.execute(...)` -> `ConversionManager` -> `ConversionQueue`, inheriting `OutputReservationRegistry`, concurrency limits, error sanitization, and `OutputCreationUndoCommand` undo tracking automatically.
5. **Persistence, Bookmarks & Unclean-Shutdown Reconciliation (`WatchFolderStore`, `WatchFolderBookmarkManager`)**:
   - Atomic JSON persistence (`watch_folders.json`) with corrupt-file backup (`watch_folders.corrupted.<timestamp>.json`), bounded per-rule fingerprints and activity history, and `reconcileStaleInProgressRecords()` on startup to transition interrupted `.pending`/`.stabilizing`/`.queued`/`.processing` items to retryable `.failed` state.
   - Security-scoped bookmark creation and stale-bookmark refresh via `WatchFolderBookmarkManager` with balanced `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
6. **App Lifecycle, Menu Bar & UI (`AppState`, `LocalConvertApp`, `AppLifecycleManager`, `MenuBarView`, `PresetManagerView`, `WatchFoldersSectionView`)**:
   - `AppState` owns `watchFolderManager` with an injectable `watchFolderStoreURL` for isolated testing and forwards `objectWillChange` to views and `MenuBarManager`.
   - `LocalConvertApp` triggers `reconcileAndStartEnabledRules()` when launching outside `XCTestCase`; `AppLifecycleManager.prepareForTermination(appState:)` stops all Watch Folder monitors cleanly before cancelling queued jobs and flushing undo persistence; `WatchFolderManager` observes `NSWorkspace` wake, mount, and unmount notifications as well as `PresetManager` updates.
   - `MenuBarView` and `MenuBarManager` display Watch Folder status and a Pause/Resume toggle whenever Watch Folder rules exist (keeping empty-rule signatures unchanged).
   - `PresetManagerView` hosts a top `Presets` | `Watch Folders` segmented switcher (`PresetSection`) alongside `WatchFoldersSectionView` and `WatchFolderEditSheetView` built with `AppTheme`, `AppCard`, `AppStatusBadge`, `AppInfoBanner`, `AppEmptyStateView`, `NSOpenPanel`, live inline validation, activity list with Retry support, and VoiceOver labels.

---

## 2. File Inventory

### New Files
- `LocalConvert/Core/WatchFolder/WatchFolderModels.swift` — Data models (`WatchFolderOutputDestination`, `WatchFolderMonitoringStatus`, `WatchFolderFileState`, `WatchFolderFileFingerprint`, `WatchFolderFileRecord`, `WatchFolderRule`), `WatchFolderPathSafety`, and `WatchFolderValidator`.
- `LocalConvert/Core/WatchFolder/FileStabilityDetector.swift` — Asynchronous multi-observation write-completion and readability verifier (`FileStabilityOutcome`, `FileStabilityDetector`).
- `LocalConvert/Core/WatchFolder/WatchFolderMonitor.swift` — Swift 6-compliant `FSEventStream` wrapper (`@unchecked Sendable` + `NSLock`).
- `LocalConvert/Core/WatchFolder/WatchFolderStore.swift` — Atomic JSON store, corrupt-file backup recovery, bounded state pruning, stale record reconciliation, and `WatchFolderBookmarkManager`.
- `LocalConvert/Core/WatchFolder/WatchFolderManager.swift` — `@MainActor` coordinator integrating monitoring, stability checking, idempotency suppression, provenance loop exclusion, `PresetExecutor`, `ConversionManager`, `ConversionQueue`, wake/volume events, and retry handling.
- `LocalConvert/Features/Presets/WatchFoldersSectionView.swift` — Watch Folders split view, rule inspector, recent file activity log, Retry controls, and `WatchFolderEditSheetView`.
- `LocalConvertTests/Phase52WatchFolderTests.swift` — Phase 52 XCTest verification suite (10 end-to-end and unit test methods).
- `docs/PHASE52_IMPLEMENTATION_REPORT.md` — This implementation report.
- `docs/PHASE52_TEST_REPORT.md` — Verification and test report.

### Modified Files
- `LocalConvert/Core/Settings/AppSettings.swift` — Added `Codable, Equatable, Hashable` conformances to `ExistingFileHandling`.
- `LocalConvert/Core/Presets/PresetExecutor.swift` — Added `collisionPolicyOverride: ExistingFileHandling? = nil` to `execute(...)`.
- `LocalConvert/App/AppState.swift` — Added `watchFolderManager: WatchFolderManager`, `watchFolderStoreURL: URL? = nil` init parameter, live output-location provider wiring without strong retain cycle, and `MenuBarManager.shared.updateStatus()` forwarding.
- `LocalConvert/App/LocalConvertApp.swift` — Added startup call to `appState.watchFolderManager.reconcileAndStartEnabledRules()` when `!isTesting`.
- `LocalConvert/App/AppLifecycleManager.swift` — Called `appState?.watchFolderManager.stopAll()` inside `prepareForTermination(appState:)`.
- `LocalConvert/Features/Home/MenuBarView.swift` — Added shared `MenuBarManager.watchFolderStatusSummary(for:)` status text and Pause/Resume Watch Folders controls in both `MenuBarView` and `MenuBarManager`.
- `LocalConvert/Features/Presets/PresetManagerView.swift` — Added `Presets` | `Watch Folders` segmented section bar embedding `WatchFoldersSectionView`.
