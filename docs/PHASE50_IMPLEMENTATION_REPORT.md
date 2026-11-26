# LOCALCONVERT — PHASE 50: CORE FEATURE & GLOBAL UNDO/REDO COMPLETENESS — IMPLEMENTATION REPORT

**Date:** 2026-11-21  
**Workspace:** `/Users/cancan/Desktop/LocalConvert/`  
**Repository:** `RighteousLife/LocalConvert`  
**Target Platform:** macOS 15.0+ (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Phase Status:** **COMPLETE** (Automated tests verified; manual GUI interaction checks listed separately)

---

## 1. Executive Summary

Phase 50 closes the four remaining functional and Undo/Redo completeness gaps (`GAP-04`, `GAP-07`, `GAP-08`, and `GAP-09`) identified in the Phase 48 Comprehensive Source Audit while preserving the three-layer architecture, DesignSystem, global `UndoRedoCoordinator`, and all Phase 49 data-safety guarantees:

1. **GAP-04 — Image Toolbox Per-File `targetFormat` & Undo/Redo Integration:**
   - Moved `targetFormat` out of view-local `@State` in `ImageToolboxView` into `ImageToolboxStore.targetFormatByURL` (`[URL: FileFormat]`) and `fallbackTargetFormat`.
   - Added `ImageTargetFormatUndoCommand` (`commandKind = "imageToolbox.targetFormatMutation"`, `operationType = .outputFormatChange`, `context = .imageToolbox`, `survivesRestart = true`) and registered its rehydration in `ImageToolboxUndoRehydrator`.
   - Updated `AppState.executeImageToolbox` so batch execution resolves each file's individual `targetFormatByURL[stdURL] ?? outputFormat` and `configsByURL[stdURL] ?? config`.
2. **GAP-07 — Inactive Application Settings (`rememberLastUsedOptions` & `verboseLogging`):**
   - Activated `AppSettings.rememberLastUsedOptions`: persists sanitized per-format `ConversionOptions` (`rememberedOptionsByFormatJSON`) and sanitized `AudioToolboxFileState` defaults (`rememberedAudioToolboxStateJSON`), stripping `overwriteExisting` and transient/file-specific keys (`allowedRememberedCustomOptionKeys`). Applies remembered options when new files are added in `AppState.addFiles(urls:)` and clears remembered state in `AppSettings.resetToDefaults()`.
   - Activated `AppSettings.verboseLogging` via `DiagnosticLogManager`: `logVerbose` emits to `Logger.debug` and appends sanitized entries (`ErrorDetailsFormatter.sanitize`) to `~/Library/Logs/LocalConvert/localconvert.log` (with 2 MB rotation) only when `verboseLogging == true`; `logError` always logs to `Logger.error` and writes sanitized diagnostic lines to `localconvert.log` when `verboseLogging == true`. Wired into `ConversionManager` job lifecycle (`start`, `completed`, `cancelled`, `failed`).
3. **GAP-08 — Audio Editor Marker Management:**
   - Added `.markerAdd`, `.markerRename`, `.markerMove`, and `.markerDelete` to `UndoOperationType`.
   - Added `AudioEditingService.clampMarkerTime(_:projectDuration:)`, `addMarker`, `renameMarker`, `moveMarker`, and `deleteMarker` keeping `project.markers` sorted chronologically and clamped to `[0, max(0, project.duration)]`.
   - Extended `AudioEditorStore` with `@Published var selectedMarkerID: UUID?`, `addMarker`, `addMarkerAtPlayhead`, `renameMarker`, `moveMarker`, coalesced drag methods (`beginMarkerDrag`, `updateMarkerDrag`, `endMarkerDrag`), `deleteMarker`, `deleteSelectedMarker`, and `selectAndSeekToMarker`.
   - Updated `TimeRulerView` with interactive marker flags (click-to-seek, coalesced drag-to-move in `"AudioTimeRuler"` coordinate space, context menu, and VoiceOver accessibility labels/traits), `AudioEditorRootView` (`"Marker"` toolbar button + `M` keyboard shortcut), and `AudioEditorInspectorView` (`.markers` inspector tab with marker list, seek, inline rename, `-0.1s` / `+0.1s` nudge, and delete controls).
4. **GAP-09 — Audio Toolbox Configuration Persistence, Secondary Undo Integration & Preset Consistency:**
   - Added `AudioToolboxFileState`, `AudioToolboxConfigUndoCommand` (`commandKind = "audioToolbox.stateMutation"`, `context = .audioToolbox`, `survivesRestart = true`), `AudioToolboxUndoRehydrator`, and `@MainActor final class AudioToolboxStore: ObservableObject` owned by `AppState.audioToolboxStore`.
   - Rebound `AudioToolboxView` (`selectedSection`, `selectedFileIds`, `orderedMergeIDs`, `targetFormat`, `config`, `preserveMetadata`, `trimStart`, `trimEnd`) to `appState.audioToolboxStore`, replacing unconditional `trimStart = 0; trimEnd = info.duration` reset in `loadPrimaryDetails()` with one-time `hydrateTrimBoundsIfNeeded(for:duration:)`.
   - Integrated secondary Undo/Redo for `SpotifyCompatibilityView.runNormalizeEligible()` (`OutputCreationUndoCommand` in `.audioToolbox` with `protectedSourceURLs`), `PresetManager.resetToDefaults()` (`PresetStore.replaceAll(_:)` + `.presetReset` in `.presets`), and `ImageDuplicateFinderView.moveSelectedToTrash()` (`IrreversibleAuditUndoCommand` with `operationType = .fileTrash` archived immediately with `irreversibilityReason` plus `AppState.removeFiles(matchingURLs:)`).
   - Unified `ImageOptimizationSectionView.applyModeChange` with `ConversionPreset.maximumQuality` (`imageQuality = 1.0`, `webpLossless = (outputFormat == .webp || outputFormat == nil)`, `preserveMetadata = true`) and `ConversionPreset.smallFile` (`targetFileSizeBytes = 1_000_000`, `imageQuality = 0.50`, `preserveMetadata = false`), and added `AudioEQPreset` (`.flat`, `.vocalClarity`, `.bassBoost`, `.custom`) so manual EQ band slider changes immediately display `"Custom"` in `AudioEffectsView`.

---

## 2. Per-Gap Root Cause & Implementation Details

### 2.1 GAP-04 — Image Toolbox Per-File `targetFormat` & Undo/Redo Integration

- **Root Cause:**
  - `ImageToolboxView` stored `@State private var targetFormat: FileFormat = .jxl` locally in the view struct (`ImageToolboxView.swift:66`), while `ImageToolboxStore` only persisted `configsByURL: [URL: ImageToolboxConfig]`. Switching between queued images in the strip or switching tabs lost per-file output format choices, and changing the output format picker in Image Toolbox did not record an Undo/Redo command.
  - Furthermore, `AppState.executeImageToolbox` applied a single `outputFormat` and `config` parameter to every file in a batch rather than resolving per-file overrides from `ImageToolboxStore`.
- **Implementation:**
  - **`LocalConvert/Core/UndoRedo/ImageToolboxUndoCommands.swift`:**
    - Added `ImageTargetFormatUndoCommand` (`commandKind = "imageToolbox.targetFormatMutation"`, `operationType = .outputFormatChange`, `context = .imageToolbox`, `survivesRestart = true`).
    - Extended `ImageToolboxUndoRehydrator` to decode and rehydrate both `ImageConfigUndoCommand` and `ImageTargetFormatUndoCommand`.
    - Extended `ImageToolboxStore` with `@Published private(set) var targetFormatByURL: [URL: FileFormat] = [:]`, `@Published private var fallbackTargetFormat: FileFormat = .jxl`, `static func defaultTargetFormat(for url: URL?) -> FileFormat` (returns `.png` for `.jxl` inputs and `.jxl` otherwise), `targetFormat(for:fallback:)`, `setTargetFormat(_:for:recordUndo:)` (guards `before != format` to prevent duplicate no-op entries), and `targetFormatBinding(for:fallback:)`.
    - Updated `ImageToolboxStore.migrateURLs(_:)` to migrate both `configsByURL` and `targetFormatByURL` when batch renames are applied, undone, or redone.
  - **`LocalConvert/Features/ImageToolbox/ImageToolboxView.swift`:**
    - Removed `@State private var targetFormat: FileFormat = .jxl` and routed `targetFormat` / `targetFormatBinding` through `appState.imageToolboxStore` for `primaryURL`.
    - Updated `applyLoadedProject` to call `appState.imageToolboxStore.setTargetFormat(doc.targetFormat, for: sourceURL, recordUndo: false)` when loading `.lcimg` project files.
  - **`LocalConvert/App/AppState+ImageToolbox.swift`:**
    - Updated `executeImageToolbox` to look up `let fileTargetFormat = imageToolboxStore.targetFormatByURL[stdURL] ?? outputFormat` and `let fileConfig = imageToolboxStore.configsByURL[stdURL] ?? config` for each input file in single, multi-size, and batch execution paths.

### 2.2 GAP-07 — Inactive Application Settings (`rememberLastUsedOptions` & `verboseLogging`)

- **Root Cause:**
  - `AppSettings.rememberLastUsedOptions` (`@AppStorage("settings.rememberLastUsedOptions")`) and `AppSettings.verboseLogging` (`@AppStorage("settings.verboseLogging")`) were exposed in `SettingsView.swift`, but no production code read either property.
- **Implementation:**
  - **`LocalConvert/Core/Settings/AppSettings.swift`:**
    - Added `rememberedOptionsByFormatJSON`, `rememberedAudioToolboxStateJSON`, `allowedRememberedCustomOptionKeys`, `sanitizeOptionsForRemembering(_:)` (strips `overwriteExisting = false` and filters `customOptions` to safe format-level keys, excluding transient/toolbox payloads), `recordLastUsedOptions(_:for:)`, `rememberedOptions(for:inputFormat:)`, `initialOptionsForNewFile(inputFormat:outputFormat:)`, and `clearRememberedOptions()` (invoked inside `resetToDefaults()`).
    - Extended `DiagnosticLogManager` with `logFileURL`, `logFileURL(in:)`, `clearDiagnosticLogs(in:)`, `isVerboseLoggingEnabled(override:)`, `logVerbose(category:message:isVerboseEnabled:directoryOverride:)`, `logError(category:message:isVerboseEnabled:directoryOverride:)`, `readDiagnosticLogContents(in:)`, and 2 MB log rotation (`localconvert.log.1`). Every message written to `localconvert.log` is sanitized through `ErrorDetailsFormatter.sanitize`.
  - **`LocalConvert/App/AppState.swift`:**
    - Updated `handleDroppedURLs` (`addFiles(urls:)`) to initialize newly added files with `AppSettings.shared.initialOptionsForNewFile(inputFormat: detectedFormat, outputFormat: defaultOutput)`, while keeping `updateOutputFormat` non-destructive for active in-memory files.
    - Updated `updateOptions`, `applyPreset`, and `optionsBinding.set` to persist format options via `AppSettings.shared.recordLastUsedOptions(normalized, for: outFmt)`.
  - **`LocalConvert/Core/Conversion/ConversionManager.swift`:**
    - Wired `DiagnosticLogManager.logVerbose` on conversion job start, completion, and cancellation, and `DiagnosticLogManager.logError` on conversion failure.

### 2.3 GAP-08 — Audio Editor Marker Management

- **Root Cause:**
  - `AudioMarker` (`id`, `time`, `name`, `colorHex`) existed in `AudioEditorProject.markers` and `TimeRulerView` rendered static yellow triangles, but there was no service, store, Undo/Redo command, keyboard shortcut, ruler gesture, or inspector tab to add, rename, move, seek, or delete markers.
- **Implementation:**
  - **`LocalConvert/Core/UndoRedo/OperationContext.swift`:**
    - Added `.markerAdd`, `.markerRename`, `.markerMove`, and `.markerDelete` to `UndoOperationType`.
  - **`LocalConvert/Engines/AudioEditor/AudioEditingService.swift`:**
    - Added `clampMarkerTime(_:projectDuration:)`, `addMarker(_:id:at:name:)`, `renameMarker(_:id:newName:)`, `moveMarker(_:id:to:)`, and `deleteMarker(_:id:)`.
  - **`LocalConvert/Engines/AudioEditor/AudioEditorStore.swift`:**
    - Added `@Published var selectedMarkerID: UUID?`, `selectedMarker`, `addMarker(at:name:id:)`, `addMarkerAtPlayhead(name:)`, `renameMarker(id:newName:)`, `moveMarker(id:to:snapToGrid:)`, `beginMarkerDrag(id:)`, `updateMarkerDrag(id:to:snapToGrid:)`, `endMarkerDrag(id:)`, `deleteMarker(id:)`, `deleteSelectedMarker()`, and `selectAndSeekToMarker(id:)`.
  - **`LocalConvert/Features/AudioEditor/TimeRulerView.swift`:**
    - Added interactive `markerFlagView(marker:pps:)` inside `.coordinateSpace(name: "AudioTimeRuler")` supporting click-to-seek, coalesced drag-to-move with grid snapping when `store.project.gridConfig.snapEnabled` is active, context menu (`Seek Playhead Here`, `Delete Marker`), and VoiceOver accessibility labels/traits.
  - **`LocalConvert/Features/AudioEditor/AudioEditorRootView.swift`:**
    - Added `"Marker"` button (`bookmark.fill`, `.help("Add Marker at Playhead (M)")`) in the editor toolbar and `case 46: // M` in `AudioEditorKeyMonitor`.
  - **`LocalConvert/Features/AudioEditor/AudioEditorInspectorView.swift`:**
    - Added `.markers` case to `AudioEditorInspectorTab` with marker list sorted by time, `"Add at Playhead"` button, click-to-seek timestamp button, inline name `TextField` committing on submit, `-0.1s` / `+0.1s` nudge buttons, and delete action.

### 2.4 GAP-09 — Audio Toolbox Configuration Persistence, Secondary Undo & Preset Consistency

- **Root Cause:**
  - `AudioToolboxView` kept `selectedSection`, `selectedFileIds`, `orderedMergeIDs`, `targetFormat`, `config`, `preserveMetadata`, `trimStart`, and `trimEnd` in view-local `@State` and reset `trimStart = 0; trimEnd = info.duration` inside `loadPrimaryDetails()` on every appearance/selection refresh.
  - `SpotifyCompatibilityView.runNormalizeEligible()`, `PresetManager.resetToDefaults()`, and `ImageDuplicateFinderView.moveSelectedToTrash()` were not connected to `UndoRedoCoordinator`.
  - `ImageOptimizationSectionView.applyModeChange` set `.maximum` to `imageQuality = 0.95` and `.smallFile` to `500 KB / 0.55` instead of matching `ConversionPreset.maximumQuality` (`1.0`) and `ConversionPreset.smallFile` (`1 MB / 0.50 / preserveMetadata = false`), and `AudioEffectsView` had no active EQ preset indicator when individual EQ bands were edited.
- **Implementation:**
  - **`LocalConvert/Core/UndoRedo/AppUndoCommands.swift` & `LocalConvert/App/AppState.swift`:**
    - Added `IrreversibleAuditUndoCommand`, `AudioToolboxFileState`, `AudioToolboxConfigUndoCommand`, `AudioToolboxUndoRehydrator`, and `AudioToolboxStore`.
    - Added `let audioToolboxStore: AudioToolboxStore` and `removeFiles(matchingURLs:recordUndo:)` on `AppState`, plus URL migration in `applyRenamedURLs`.
  - **`LocalConvert/Features/AudioToolbox/AudioToolboxView.swift`:**
    - Bound section, selection, merge order, target format, configuration, metadata flag, and trim bounds to `appState.audioToolboxStore`, and replaced the unconditional trim reset in `loadPrimaryDetails()` with `hydrateTrimBoundsIfNeeded(for: activeURL, duration: dur)`.
  - **`LocalConvert/Engines/AudioToolbox/AudioProcessingModels.swift` & `LocalConvert/Features/AudioToolbox/AudioEffectsView.swift`:**
    - Added `AudioEQPreset` (`.flat`, `.vocalClarity`, `.bassBoost`, `.custom`) and `AudioToolboxConfig.activeEQPreset`, and displayed the active EQ preset status badge and button tint in `AudioEffectsView`.
  - **`LocalConvert/Features/Conversion/ImageOptimizationView.swift`:**
    - Aligned `applyModeChange(.maximum)` and `applyModeChange(.smallFile)` with `ConversionPreset.maximumQuality` and `ConversionPreset.smallFile`.
  - **`LocalConvert/Features/AudioToolbox/SpotifyCompatibilityView.swift`:**
    - Recorded `OutputCreationUndoCommand` (`context: .audioToolbox`, `protectedSourceURLs: candidates.map(\.inputURL)`) for normalized output copies created by `runNormalizeEligible()`.
  - **`LocalConvert/Core/Presets/PresetStore.swift` & `LocalConvert/Core/Presets/PresetManager.swift`:**
    - Added `PresetStore.replaceAll(_:)`, injectable `undoCoordinator` + `flushPendingUndoRecords()` on `PresetManager`, and `.presetReset` undo recording in `PresetManager.resetToDefaults()`.
  - **`LocalConvert/Features/ImageToolbox/ImageConvertUtilitiesViews.swift`:**
    - Updated `ImageDuplicateFinderView.moveSelectedToTrash()` to remove trashed files from `AppState.shared` and record an `IrreversibleAuditUndoCommand` (`operationType: .fileTrash`, `context: .imageToolbox`).

---

## 3. Complete List of Modified & Created Files

### Modified Production Files (16)
1. `LocalConvert/App/AppState+ImageToolbox.swift`
2. `LocalConvert/App/AppState.swift`
3. `LocalConvert/Core/Conversion/ConversionManager.swift`
4. `LocalConvert/Core/Presets/PresetManager.swift`
5. `LocalConvert/Core/Presets/PresetStore.swift`
6. `LocalConvert/Core/Settings/AppSettings.swift`
7. `LocalConvert/Core/UndoRedo/AppUndoCommands.swift`
8. `LocalConvert/Core/UndoRedo/ImageToolboxUndoCommands.swift`
9. `LocalConvert/Core/UndoRedo/OperationContext.swift`
10. `LocalConvert/Engines/AudioEditor/AudioEditingService.swift`
11. `LocalConvert/Engines/AudioEditor/AudioEditorStore.swift`
12. `LocalConvert/Engines/AudioToolbox/AudioProcessingModels.swift`
13. `LocalConvert/Features/AudioEditor/AudioEditorInspectorView.swift`
14. `LocalConvert/Features/AudioEditor/AudioEditorRootView.swift`
15. `LocalConvert/Features/AudioEditor/TimeRulerView.swift`
16. `LocalConvert/Features/AudioToolbox/AudioEffectsView.swift`
17. `LocalConvert/Features/AudioToolbox/AudioToolboxView.swift`
18. `LocalConvert/Features/AudioToolbox/SpotifyCompatibilityView.swift`
19. `LocalConvert/Features/Conversion/ImageOptimizationView.swift`
20. `LocalConvert/Features/ImageToolbox/ImageConvertUtilitiesViews.swift`
21. `LocalConvert/Features/ImageToolbox/ImageToolboxView.swift`

*(21 modified production source files in total)*

### Created Test & Documentation Files (3)
1. `LocalConvertTests/Phase50CoreFeatureUndoTests.swift`
2. `docs/PHASE50_IMPLEMENTATION_REPORT.md`
3. `docs/PHASE50_TEST_REPORT.md`

---

## 4. Verification Summary & Remaining Manual GUI Items

- **Automated Verification:**
  - `Phase50CoreFeatureUndoTests`: **7/7 passed** (`0.165s`).
  - Related 18-suite regression run: **14/14 XCTest methods** + **165/165 Swift Testing tests passed** (`29.137s`).
  - Full `LocalConvertTests` suite: **26/26 XCTest methods passed** (`1.512s`) and **602/603 Swift Testing tests passed** (`261.251s`) in single-process execution; in isolated 2-suite execution (`Phase422ClosureTests` + `Phase46IntegrationAndPerfTests`), `Phase46IntegrationAndPerfTests` passed **6/6** (`3.883s`) and `Phase422ClosureTests` passed **3/4** (with `largeImageMemoryStabilityAndDiagnostics` passing its 50 MP stability check at `406.5 MB -> 419.4 MB` and recording a `100 MP` physical-footprint threshold variance `838.3 MB -> 1121.0 MB` due to `nonVolatileInternal` remaining flat at `78.4 MB -> 80.5 MB` across iterations 2–4).
- **Pending Manual GUI Verification (Not Claimed from Unit Tests):**
  - Live pointer dragging of marker flags along `TimeRulerView` and visual overlap inspection at high marker density.
  - Live VoiceOver navigation and keyboard focus ring inspection across the new Audio Editor `Markers` inspector tab and `TimeRulerView` marker flags.
  - Interactive `NSAlert` confirmation and Finder Trash restoration flow in `ImageDuplicateFinderView`.
