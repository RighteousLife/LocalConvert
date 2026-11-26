# LocalConvert — Phase 57: Structured Diagnostics & Privacy Report

**Date:** 2026-11-22  
**Primary Files:**
- `LocalConvert/Core/Diagnostics/StructuredDiagnostics.swift` (`155` lines)
- `LocalConvert/Core/Conversion/ConversionErrorFormatter.swift` (`ErrorDetailsFormatter.sanitize(_:)`, lines `220–247`)
- `LocalConvert/Core/Settings/AppSettings.swift` (`DiagnosticLogManager`, lines `285–390`)
- **Integration Points:** `ConversionManager.swift`, `MetadataManager.swift`, `WatchFolderManager.swift`, `BundledFFmpegProvider.swift`

---

## 1. Architecture Overview

Phase 57 adds an in-process, structured local diagnostics layer (`StructuredDiagnostics`) built directly on top of the existing `DiagnosticLogManager` subsystem (`com.localconvert.app`) without adding network libraries, analytics SDKs, or duplicate logging backends:

- **Typed Taxonomy (`DiagnosticCategory`):** `conversion`, `imageDecode`, `rawProcessing`, `metadata`, `videoProcessing`, `watchFolder`, `bundledTool`, `fileAccess`, `uiLifecycle`.
- **Severity Discrimination (`DiagnosticSeverity`):**
  - `.info` (`"INFO"`): Lifecycle milestones (`started`, `completed`, `cancelled`).
  - `.validation` (`"VALIDATION"`): Expected user/input/route validation failures.
  - `.internalError` (`"INTERNAL_ERROR"`): Unexpected internal, engine, metadata, or bundled binary resolution errors.
- **Exhaustive `ConversionError` Classification (`StructuredDiagnostics.severity(for:)`):**
  - Maps `.inputFileNotFound`, `.outputDirectoryNotWritable`, `.outputFileAlreadyExists`, `.insufficientDiskSpace`, `.unsupportedConversion`, `.invalidInput`, `.cancelled` → `.validation`.
  - Maps `.engineNotAvailable`, `.engineExecutionFailed`, `.unknown` → `.internalError`.
- **Event Schema (`DiagnosticEvent`):** Immutable `Identifiable, Sendable, Equatable` record containing `id`, `timestamp`, `category`, `severity`, sanitized `stage`, optional `operationID`, optional `sanitizedFilename` (`lastPathComponent` only), and sanitized `message`, formatted as:
  `[Category][SEVERITY][stage] [op:...] [file:...] message`

---

## 2. Local-Only Guarantees & Network / Telemetry Absence

Inspected `StructuredDiagnostics.swift` and `AppSettings.swift` (`DiagnosticLogManager`):
- **Zero Network or Telemetry:** Neither `StructuredDiagnostics` nor `DiagnosticLogManager` opens URL sessions, sockets, crash-upload endpoints, or analytics exporters.
- **OSLog + Opt-In File Storage:**
  - `.info` events call `DiagnosticLogManager.logVerbose(...)`, which immediately returns unless `verboseLogging` (`UserDefaults` key `settings.verboseLogging`, or explicit test override) is `true`. When enabled, logs go strictly to unified OSLog (`com.localconvert.app`) and `~/Library/Logs/LocalConvert/localconvert.log` (or `directoryOverride` in tests), rotated at `maxLogFileSizeBytes`.
  - `.validation` and `.internalError` events call `DiagnosticLogManager.logError(...)`, which emits sanitized text to OSLog `Logger.error` and appends to `localconvert.log` only when `verboseLogging` is enabled.

---

## 3. Redaction & Privacy Controls

Privacy sanitization runs on **both** `ErrorDetailsFormatter.format(...)` user-facing error reports and `StructuredDiagnostics.record(...)` / `DiagnosticLogManager` log emission (`ErrorDetailsFormatter.sanitize(_:)` in `ConversionErrorFormatter.swift:222–246`):

1. **Filename Stripping (`StructuredDiagnostics.record`):** Converts any raw `filename` argument via `URL(fileURLWithPath: raw).lastPathComponent` and sanitizes it before storing in `DiagnosticEvent.sanitizedFilename`, preventing parent directory username leakage.
2. **Regex Redaction (`ErrorDetailsFormatter.sanitize(_:)`):** Case-insensitive replacements in order:
   - `Bearer\s+[A-Za-z0-9\-._~+/]+=*` → `Bearer [REDACTED]`
   - `password=[^\s&]+`, `pwd=[^\s&]+`, `secret=[^\s&]+`, `token=[^\s&]+`, `key=[^\s&]+` → `<key>=[REDACTED]`
   - `(?:latitude|longitude|lat|lon)\s*[:=]\s*[-+]?\d+(?:\.\d+)?` → `[GPS_REDACTED]`
   - `\b\d{1,3}\.\d{3,}°\s*[NSEW]\b` → `[GPS_REDACTED]`
   - `/Users/[^/\s:]+` → `~`

**Honest Privacy Boundaries (Do Not Overclaim):**
- Unit test `testStructuredDiagnosticsAndFormatterRedactSecretsPathsAndGPSCoordinates` verifies the explicit redaction patterns above on synthetic messages and temporary `directoryOverride` log files.
- **Scope limitation:** Passing that unit test does **not** constitute a blanket guarantee for every third-party error string across the entire application. Arbitrary free-text metadata strings, email addresses, usernames not following `/Users/<name>`, or legacy `os.Logger` statements with `privacy: .public` that exist directly inside `ConversionManager.swift` (e.g., lines `535`, `587`, `624`, `643`), `MetadataManager.swift` (lines `97`, `303`, `448`), or `Media`/`PDF`/`Office` engines outside `StructuredDiagnostics` are **not** routed through `ErrorDetailsFormatter.sanitize(_:)`.

---

## 4. Bounded Ring Buffer & Non-Blocking Behavior

- **Bounded Memory (`maxEvents = 200`):** Protected by `NSLock` (`buffer.removeFirst(buffer.count - maxEvents)` when exceeding `200`). `recentEvents(category:severity:)`, `clearRecentEvents()`, and `exportSanitizedSummary(limit:)` take thread-safe snapshots under `lock`.
- **Concurrency Note:** `StructuredDiagnostics.buffer` uses `nonisolated(unsafe)` paired consistently with `NSLock` inside all read/write methods; no lock is held across `DiagnosticLogManager` calls (snapshot/append unlocks before calling `DiagnosticLogManager`).
- **Conversion / UI Blocking Assessment:**
  - Recording `.info` events when `verboseLogging` is disabled performs only an in-memory `NSLock` array append (microseconds) and returns cleanly without disk I/O.
  - Recording errors (or `.info` when `verboseLogging == true`) calls `DiagnosticLogManager`, which performs synchronous `FileHandle` append under `fileWriteLock`. Because `BundledFFmpegProvider`, `WatchFolderManager`, `ConversionManager`, and `MetadataManager` invoke `StructuredDiagnostics.record` infrequently (on failure, start/completion milestones, or missing executable paths rather than per-frame or per-byte loops), this does not meaningfully block conversion or UI flows; however, high-frequency per-frame loops should never call `record(...)` while `verboseLogging` is enabled.

---

## 5. Audited Integration Points & Test Evidence

Inspected directly in source:
- **`ConversionManager.swift` (`487–652`):** Emits `.validation` (`findEngine`, `inputCheck`, `ConversionError` mapped via `severity(for:)` across `.rawProcessing`/`.videoProcessing`/`.imageDecode`/`.conversion`), `.internalError` (`engineAvailable`, unexpected `catch`), and `.info` (`started`, `completed`, `cancelled`).
- **`MetadataManager.swift` (`62–105`, `304–310`, `449–455`):** Emits `.metadata` `.validation` for format-detection / missing-provider errors in `load(url:)`, and `.internalError` in `load`, `saveInPlace`, and `saveCopy` failure handlers.
- **`WatchFolderManager.swift` (`760–766`):** Emits `.watchFolder` with `StructuredDiagnostics.severity(for: error)` in `case .failed(let error)` and sanitizes the persisted reason via `ErrorDetailsFormatter.sanitize(error.userFacingMessage)`.
- **`BundledFFmpegProvider.swift` (`29–35`, `46–52`):** Emits `.bundledTool` `.internalError` (`locateBinary`) when `ffmpeg` or `ffprobe` cannot be resolved.

**Automated Verification:**
- `LocalConvertTests/Phase57DiagnosticsAndSplitTests`:
  - `testStructuredDiagnosticsClassifiesValidationVsInternalErrorAndBoundsBuffer`: Verified `.validation` vs `.internalError` mapping and `200`-event cap (`215` inserted → `200` retained, `batch-15`..`batch-214`).
  - `testStructuredDiagnosticsAndFormatterRedactSecretsPathsAndGPSCoordinates`: Verified redaction of `/Users/secretuser/...`, `password=TopSecret123`, `Bearer abc.def.ghi`, `latitude=-33.86880`, `longitude=151.20930`, `33.86880° S`, and isolated file logging in a temp `directoryOverride`.
  - Passed **3/3** in both Phase 57.1 (`0.075s`) and Phase 57.2 full regression (`0.076s`).
