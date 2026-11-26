# LocalConvert — Phase 57: Targeted Code Splitting & Architecture Report

**Date:** 2026-11-22  
**Scope:** Strictly scoped extraction of separable responsibilities from two large core files (`ConversionManager.swift` and `AppState.swift`). Zero changes to protected Phase 55.1, Phase 56, or Phase 56.1 pipelines (`ImageSourcePipeline.swift`, `ImageConversionEngine.swift`, `ImageProcessingService.swift`, `ImageMetadataProvider.swift`, `ImageMetadataInspectorService.swift`, `HistoryManager.swift`, `UndoRedoCoordinator.swift`).

---

## 1. Split Files & Line-Count Summary

| Area | Primary File (After) | Extracted File(s) | Extracted Responsibility |
|---|---|---|---|
| **Conversion Manager** | `LocalConvert/Core/Conversion/ConversionManager.swift` (`655` lines; previously `1,161` lines) | `LocalConvert/Core/Conversion/ConversionErrorFormatter.swift` (`247` lines) | `ConversionSizeComparison`, `BatchResultSummary`, and `ErrorDetailsFormatter` (title, suggested action, formatted error report, secret/GPS/home-path sanitization). |
|  |  | `LocalConvert/Core/Conversion/ConversionManager+OutputReservation.swift` (`315` lines) | `OutputReservationRegistry` (`NSLock`-synchronized thread-safe atomic path reservation), collision-safe naming (`reserveOutputURL`, `reserveUniqueOutputURL`, `reserveMultiPageOutputURL`), `finalizeOutputFile`, `cleanStaleTemporaryFiles`, and path sanitization (`sanitizeAffix`). |
| **App State** | `LocalConvert/App/AppState.swift` (`918` lines) | `LocalConvert/App/AppState+FolderImport.swift` (`263` lines) | Folder smart import (`importFilesFromPendingFolders` bounded at 1,000 files, skipping hidden/package entries) and per-file queue option/format/trim/preset management (`removeFile`, `removeAllFiles`, `file(for:)`, `updateOutputFormat`, `updateOptions`, `updateVideoTrim`, `applyPreset`, `optionsBinding`). |

Note: Earlier extensions (`AppState+ImageToolbox.swift`, etc.) remained untouched. No new frameworks, packages, or wrapper abstraction layers were added.

---

## 2. Architecture, API & Concurrency Audit

### Public / Internal API Preservation
- `ConversionSizeComparison`, `BatchResultSummary`, and `ErrorDetailsFormatter` keep their exact module-level type names, properties (`formattedSummary`, `displayString`, `formattedSavingsSummary`, etc.), and static method signatures (`ErrorDetailsFormatter.title(for:)`, `suggestedAction(for:)`, `format(...)`, `sanitize(_:)`).
- `ConversionManager` extension methods (`reserveOutputURL`, `releaseReservedOutputURL`, `clearReservedOutputURLs`, `cleanStaleTemporaryFiles`, `finalizeOutputFile`, `uniqueOutputURL`, `multiPageOutputURL`, `outputURL`) preserve exact names, parameter defaults, and `nonisolated` isolation.
- `AppState` keeps `public func importFilesFromPendingFolders()`, `removeFile(_:)`, `removeAllFiles()`, `file(for:)`, `updateOutputFormat(for:format:)`, `updateOptions(for:options:)`, `updateVideoTrim(for:trim:preferredOutputFormat:)`, `applyPreset(_:for:)`, and `optionsBinding(for:)`. `fileDetector` and `undoCoordinator` on `AppState` became `internal` (from `private`) solely to allow same-module extension access in `AppState+FolderImport.swift`.

### Separation of Concerns & Dependency Discipline
- **Improved cohesion:** Error report formatting and byte-size comparison structs (`Sendable`, pure value types) no longer sit inside `@MainActor final class ConversionManager`. Similarly, `nonisolated` filesystem reservation (`OutputReservationRegistry`) is clearly separated from `@MainActor` job queue scheduling in `ConversionManager.swift`.
- **Zero new dependencies or over-abstraction:** Plain Swift extensions and existing value types were moved cleanly into focused files (`ConversionManager+OutputReservation.swift`, `ConversionErrorFormatter.swift`, `AppState+FolderImport.swift`) registered automatically by XcodeGen (`sources: - path: LocalConvert`).

### Swift 6 Strict Concurrency & Isolation
- `ConversionManager.swift` and `AppState.swift` (plus `AppState+FolderImport.swift` via extension on `@MainActor final class AppState`) remain cleanly `@MainActor`-isolated for mutable ObservableObject/UI state (`@Published`).
- Every static reservation and cleanup helper in `ConversionManager+OutputReservation.swift` is explicitly `nonisolated` so background conversion tasks and engines can reserve/release/finalize paths without hopping onto the `@MainActor`, synchronized internally via `OutputReservationRegistry.lock` (`NSLock`).
- Both Clean (`arm64`) and Incremental builds in Phase 57.1 and Phase 57.2 compile with `SWIFT_STRICT_CONCURRENCY: complete` at **0 Swift compiler errors and 0 Swift compiler warnings**.

### Output Reservation & Error Formatting Integrity
- Collision-safe atomic reservation (`caseSensitive` volume lookup, `.createUnique`, `.skip`, `.overwrite` batch-collision guard, and `hasVideoTrim` self-overwrite protection in `finalizeOutputFile`) is preserved verbatim.
- Undo integration in `removeFile(_:)` / `removeAllFiles()` (`DroppedFilesUndoCommand` recorded via `undoCoordinator`) is preserved verbatim.

---

## 3. Verification Evidence

- **`Phase57DiagnosticsAndSplitTests.testConversionManagerSplitHelpersPreserveReservationAndErrorFormatting`:** Verified `ConversionManager.reserveOutputURL` collision numbering (`pre_sample.jpg`, `pre_sample (1).jpg`), `releaseReservedOutputURL`, `ErrorDetailsFormatter.title(for:)`, `ErrorDetailsFormatter.format(...)` suggested action & `/Users/alice` home-path masking, and `ConversionSizeComparison.formattedSummary` (`"60% smaller"`).
- **Full `LocalConvertTests` Regression (Phase 57.2):** Existing output reservation, smart preset format-switching (`AppState+FolderImport.updateOutputFormat`), video trim protection, and error-formatting suites all passed (`651` passed, `2` env-gated genuine RAW skips, `0` failures).
- **XCUITests (Phase 57.1):** `testImageConversionSuccessAndUndoUI` and `testLaunchAndPrimaryNavigationSmoke` exercised `AppState` UI workflows end-to-end (`6/6` passed).

---

## 4. Remaining Architectural Debt (Out of Phase 57 Scope)

- `AppState.swift` remains `918` lines even after extracting `AppState+FolderImport.swift` (`263` lines); remaining responsibilities (e.g., batch execution coordination, watch folder wiring, settings bindings) were intentionally left in place to respect the minimal-change rule rather than performing opportunistic wide refactoring.
- `OutputReservationRegistry` continues to use `@unchecked Sendable` with `NSLock` (pre-existing pattern carried over unchanged during extraction; could adopt `OSAllocatedUnfairLock` in a future Swift 6 cleanup if desired).
- Protected prior-phase files (`HistoryManager.swift`, `ImageConversionEngine.swift`, `ImageSourcePipeline.swift`, etc.) were not modified.
