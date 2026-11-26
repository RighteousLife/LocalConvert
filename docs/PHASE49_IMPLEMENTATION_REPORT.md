# LocalConvert — Phase 49 Implementation Report: Data Safety, File-Write Undo & Multi-Output Integrity

**Date:** 2026-11-21  
**Repository:** `RighteousLife/LocalConvert` (`/Users/cancan/Desktop/LocalConvert/`)  
**Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**Phase Status:** Complete (5/5 audited data-safety & reliability gaps closed)

---

## 1. Executive Summary

Phase 49 resolves the five file-safety, undo/redo, state-synchronization, and subprocess-deadlock defects identified in the Phase 48 Comprehensive Source Audit (`GAP-01`, `GAP-02`, `GAP-03`, `GAP-05`, and `GAP-06`) without introducing out-of-scope features or modifying Phase 48 audit records:

| Gap ID | Defect Title | Resolution Status | Primary Production Files Modified |
| :--- | :--- | :--- | :--- |
| **GAP-01** | Multi-Output `OutputCreationUndoCommand` | **Closed** | `ConversionQueue.swift`, `AppUndoCommands.swift` |
| **GAP-02** | Metadata Save Copy & Disk-Level Undo | **Closed** | `MetadataManager.swift`, `AppUndoCommands.swift`, `MetadataView.swift`, `AudioToolboxView.swift` |
| **GAP-03** | Image Batch Rename State & Undo Synchronization | **Closed** | `AppState.swift`, `ImageToolboxUndoCommands.swift`, `AppUndoCommands.swift`, `ImageConvertUtilitiesViews.swift` |
| **GAP-05** | Animated Image Preservation in Image Toolbox Pro | **Closed** | `ImageConversionEngine.swift`, `ImageProcessingService.swift`, `ImageToolboxView.swift` |
| **GAP-06** | `VideoMetadataProvider` Subprocess Pipe Deadlock | **Closed** | `VideoMetadataProvider.swift` |

---

## 2. Detailed Implementation by Gap

### 2.1 GAP-01 — Multi-Output `OutputCreationUndoCommand`

#### Root Cause
In `ConversionQueue.swift`, `handleJobCompletion` passed only `result.outputURL` (the primary output file) into `recordOutputUndoIfSafe(job:outputURL:)` and appended only `result.outputURL` to `batchCompletedOutputURLs`. Multi-output operations (PDF Split, Multi-Page PDF-to-Images, Image Toolbox Multi-Size Export, Audio Split by Silence, and Audio Stem Extraction) populate `result.additionalOutputURLs` (`result.allOutputURLs`), leaving secondary output files untracked by `OutputCreationUndoCommand`. Additionally, `OutputCreationUndoCommand.redo()` iterated over an unordered `Dictionary` (`stagedByURL`), making multi-file restoration order non-deterministic.

#### Code Changes
- **[ConversionQueue.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/ConversionQueue/ConversionQueue.swift)**:
  - Added `nonisolated static func deduplicatedOutputURLs(from urls: [URL]) -> [URL]` and `nonisolated static func safeUndoableOutputURLs(outputURLs:protectedSourceURLs:requireExistsOnDisk:) -> [URL]` to deduplicate paths by `standardizedFileURL.resolvingSymlinksInPath()`, filter out any URL matching `job.inputURLs`, and verify existence on disk.
  - Updated `handleJobCompletion` to append all deduplicated URLs from `result.allOutputURLs` into `batchCompletedOutputURLs` (and snapshot them into `lastBatchCompletedOutputURLs` upon batch completion) and pass `uniqueOutputs` to `recordOutputUndoIfSafe(job:outputURLs:)`.
  - Added `pendingUndoChain: Task<Void, Never>?` and `func flushPendingUndoRecords() async`, plus injectable `undoCoordinator: UndoRedoCoordinator = .shared` in `ConversionQueue.init`.
- **[AppUndoCommands.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/UndoRedo/AppUndoCommands.swift)**:
  - Updated `OutputCreationUndoCommand.init` to sanitize and deduplicate `outputURLs` while excluding any path in `protectedSourceURLs`.
  - Updated `OutputCreationUndoCommand.redo()` to iterate deterministically over `for url in outputURLs` when restoring staged recovery artifacts via `RecoveryArtifactManager`.

---

### 2.2 GAP-02 — Metadata Save Copy & Disk-Level Undo

#### Root Cause
`MetadataManager.save()` previously overwrote the active source file in-place via `provider.writeMetadata(doc, to: url)` without offering a non-destructive **Save Copy** workflow and without staging the pre-save file bytes in `RecoveryArtifactManager` or recording an `UndoOperationType.metadataSaveToDisk` command in `UndoRedoCoordinator`.

#### Code Changes
- **[AppUndoCommands.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/UndoRedo/AppUndoCommands.swift)**:
  - Added `MetadataFileWriteUndoCommand` (`operationType = .metadataSaveToDisk`, dynamic `context: OperationContext`, `destinationURL: URL`, `protectedSourceURLs: [URL]`, `previousArtifactID: UUID?`, `artifactManager: RecoveryArtifactManager`, `onDidMutateDisk: (@MainActor (URL, Bool) async -> Void)?`).
  - On `undo()`: validates `expectedCurrentIdentity.validateMatchesDisk() == .valid`, stages the current file on disk via `artifactManager.stageFileByMoving(from: destinationURL)` for redo, and either restores `previousArtifactID` (for in-place save or overwritten target) or leaves the newly created copy removed (when `previousArtifactID == nil`).
  - On `redo()`: validates disk state and restores `redoArtifactID` to `destinationURL` while protecting `protectedSourceURLs` when `previousArtifactID == nil`.
- **[MetadataManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/MetadataManager.swift)**:
  - Added `artifactManager: RecoveryArtifactManager`, `pendingUndoChain: Task<Void, Never>?`, `lastSavedCopyURL: URL?`, `func flushPendingUndoRecords() async`, and `func suggestedSaveCopyURL(for:) -> URL?`.
  - Implemented `func saveInPlace(context: OperationContext = .metadata) async -> Bool` (with `func save(context: OperationContext = .metadata) async -> Bool` forwarding to `saveInPlace(context:)` for backward compatibility):
    - Stages pre-save file bytes via `artifactManager.stageFileByCopying(from: url)` before `provider.writeMetadata(doc, to: url)`.
    - Records `MetadataFileWriteUndoCommand` with `previousArtifactID: stagedOriginal.id` and reloads `MetadataManager` from disk upon undo/redo when `activeURL` matches the mutated file.
    - Releases the staged artifact if `provider.writeMetadata` throws.
  - Implemented `@discardableResult func saveCopy(to destinationURL: URL? = nil, context: OperationContext = .metadata) async -> URL?`:
    - Refuses any `destinationURL` that resolves to `activeURL`.
    - Reserves a collision-safe `<name>_tagged.<ext>` sibling path via `ConversionManager.reserveUniqueOutputURL` when `destinationURL == nil`.
    - Copies the source file to a temporary sibling file `.localconvert_metacopy_<UUID>.<ext>`, writes updated metadata to that temporary copy via `provider.writeMetadata`, atomically moves/replaces it into `targetURL`, and records `MetadataFileWriteUndoCommand` while leaving `activeURL` 100% unmodified.
- **[MetadataView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Metadata/MetadataView.swift)** and **[AudioToolboxView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/AudioToolbox/AudioToolboxView.swift)**:
  - Added primary **Save Copy...** (`.borderedProminent`, presenting `NSSavePanel` pre-filled with `metadataManager.suggestedSaveCopyURL()`) alongside explicit **Save In-Place** (`.bordered`).

---

### 2.3 GAP-03 — Image Batch Rename State & Undo Synchronization

#### Root Cause
In `ImageBatchRenameView` (`ImageConvertUtilitiesViews.swift`), clicking `"Apply Safe Rename"` moved files on disk via `ImageBatchRenameService.executePlan(plan)` and recorded a `BatchRenameUndoCommand`, but never updated `AppState.droppedFiles` or `AppState.imageToolboxStore` (`configsByURL`, `targetFormatByURL`). Furthermore, clicking `"Undo Last Rename"` called `ImageBatchRenameService.undo(manifest)` directly instead of routing through `UndoRedoCoordinator.shared.undo(in: .imageToolbox)`, leaving a stale `BatchRenameUndoCommand` on the coordinator's undo stack.

#### Code Changes
- **[AppState.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState.swift)**:
  - Changed `DroppedFile.url` from `let` to `var` so updating a queued file's URL preserves its `DroppedFile.id` (keeping `ImageToolboxView.selectedFileIds` intact).
  - Added `public func applyRenamedURLs(_ moves: [(from: URL, to: URL)])` to update `droppedFiles` URLs in a single pass and invoke `imageToolboxStore.migrateURLs(moves)`.
  - Passed `undoCoordinator: undoCoordinator` when initializing `ConversionQueue(conversionManager: manager, undoCoordinator: undoCoordinator)`.
- **[ImageToolboxUndoCommands.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/UndoRedo/ImageToolboxUndoCommands.swift)**:
  - Added `func migrateURLs(_ moves: [(from: URL, to: URL)])` on `ImageToolboxStore` using a two-phase snapshot migration so `configsByURL`, `targetFormatByURL`, and `activeContinuousURL` migrate cleanly even across chained or overlapping renames.
- **[AppUndoCommands.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/UndoRedo/AppUndoCommands.swift)**:
  - Updated `BatchRenameUndoCommand` to accept `onURLsMoved: (@MainActor ([(from: URL, to: URL)]) -> Void)? = nil` and invoke `onURLsMoved?(undone)` after `undo()` and `onURLsMoved?(redone)` after `redo()`.
- **[ImageConvertUtilitiesViews.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImageConvertUtilitiesViews.swift)**:
  - Updated `ImageBatchRenameView` to call `AppState.shared?.applyRenamedURLs(manifest.appliedMoves)` immediately after `ImageBatchRenameService.executePlan(plan)`, pass `onURLsMoved: { moves in AppState.shared?.applyRenamedURLs(moves) }` into `BatchRenameUndoCommand`, and route `"Undo Last Rename"` through `await undoCoordinator.undo(in: .imageToolbox)`.

---

### 2.4 GAP-05 — Animated Image Preservation in Image Toolbox Pro

#### Root Cause
While `ImageConversionEngine.convertAnimatedIfApplicable` supported multi-frame animated conversions between `.gif`, `.apng`, `.webp`, and `.jxl`, `ImageProcessingService.processToFile` (used by Image Toolbox Pro) always routed single-file exports through `processInMemory`, which decoded only frame `0` and silently flattened animated inputs without warning.

#### Code Changes
- **[ImageConversionEngine.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageConversionEngine.swift)**:
  - Made `convertAnimatedIfApplicable` (and its internal helpers `encodeAnimatedGIF`, `encodeAnimatedAPNG`, `runFFmpegImageCommandStatic`) `static` on `ImageConversionEngine` so both `ImageConversionEngine` and `ImageProcessingService` share the same multi-frame conversion pipeline.
- **[ImageProcessingService.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Engines/Image/ImageProcessingService.swift)**:
  - Added `static func inspectAnimationFrameCount(url: URL, format: FileFormat? = nil) -> Int`.
  - Added `static func canPreserveAnimation(inputFormat: FileFormat?, outputFormat: FileFormat, config: ImageToolboxConfig) -> Bool` (true when `config.preserveAnimation` is enabled, input is `.gif`/`.apng`/`.webp`/`.jxl`, output is `.gif`/`.apng`/`.jxl`, and `!config.hasPixelEdits && !config.exportMultipleSizes && !config.targetFileSizeEnabled`).
  - Added `static func animationFlatteningWarning(frameCount: Int, inputFormat: FileFormat?, outputFormat: FileFormat, config: ImageToolboxConfig) -> String?` and appended the warning to `processInMemory` telemetry (`telemetry.warnings`) whenever a multi-frame input (`frameCount > 1`) is flattened.
  - Updated `ImageProcessingService.processToFile` to route eligible animated exports (`animFrameCount > 1 && canPreserveAnimation(...)`) through `ImageConversionEngine.convertAnimatedIfApplicable`, preserving frame count, frame durations, loop counts, and alpha.
- **[ImageToolboxView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/ImageToolbox/ImageToolboxView.swift)**:
  - Added `@State private var primaryFrameCount: Int = 1` populated in `loadPrimaryDetails()`.
  - Added an `AppInfoBanner` in `workspaceContent` when `primaryFrameCount > 1` displaying either an explicit warning when active edits/target format flatten the animation to frame 1 or an informational banner confirming all frames will be preserved.

---

### 2.5 GAP-06 — `VideoMetadataProvider` Subprocess Pipe Deadlock

#### Root Cause
In `VideoMetadataProvider.readMetadata(from:)`, `ffprobe` was launched with `process.standardOutput = pipe`, followed by synchronous `process.waitUntilExit()` before `pipe.fileHandleForReading.readDataToEndOfFile()`. On macOS, when `ffprobe` outputs more than the 64 KB kernel pipe buffer (such as containers with many streams, chapters, or large embedded tags), the child process blocks waiting for the parent to drain stdout while the parent blocks in `waitUntilExit()`, causing a deadlock.

#### Code Changes
- **[VideoMetadataProvider.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Metadata/Providers/VideoMetadataProvider.swift)**:
  - Replaced manual `Pipe()` + `process.run()` + `process.waitUntilExit()` + `readDataToEndOfFile()` with `let output = try await AsyncProcessRunner.run(process)`, which drains `stdout` and `stderr` asynchronously and terminates the child process cleanly if the parent Swift concurrency task is cancelled.
  - Added optional `ffprobeExecutableOverride: URL? = nil` initializer parameter (`init(ffprobeExecutableOverride: URL? = nil)`) to support deterministic large-stdout pipe testing alongside real bundled `ffprobe` execution.
