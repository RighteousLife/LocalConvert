# LocalConvert — Phase 47 Architecture Audit & Implementation Plan
## Production Quality, macOS Lifecycle & Product Experience

**Date:** 2026-11-21  
**Target Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**App Version:** `1.0.0` (`MARKETING_VERSION: "1.0.0"`)  
**Phase Scope:** Milestones 47.0 – 47.7 (Dock & Menu Bar Visibility, Centralized Lifecycle, Accessibility, Native Menus/Shortcuts, Drag & Drop / Batch UX, Progress/Errors/Empty States, UI Consistency, Full Regression & Acceptance)

---

## 1. Executive Summary & Stock Pink Reference Note

Phase 47 upgrades LocalConvert's macOS lifecycle, Dock/Menu Bar visibility controls, accessibility metadata, native keyboard shortcut routing, batch Drag & Drop feedback, structured error presentation, empty states, and global UI consistency without altering conversion engine internals or breaking existing PDF, Image, Audio, Metadata, Preset, or Global Undo/Redo workflows.

### Stock Pink / SwiftStockMonitor Source Availability (Section 4.2)
A workspace audit (`rg --files /Users/cancan/Desktop/LocalConvert | rg -i "Stock|Monitor"`) confirmed that **no `SwiftStockMonitorApp.swift` or Stock Pink source files are present in this workspace**. In accordance with Section 4.2, we explicitly document that Stock Pink source code is unavailable locally and design the centralized lifecycle manager strictly from LocalConvert's existing architecture (`LocalConvertApp.swift`, `MenuBarView.swift`, `AppSettings.swift`) and the behavioral specification in Section 5.

---

## 2. Existing Architecture Audit (Milestone 47.0 Findings)

### 2.1 Application Lifecycle, Window Management & Menu Bar (`LocalConvertApp.swift`, `MenuBarView.swift`, `AppSettings.swift`)
- **Settings State:** `AppSettings.shared` persists `showMenuBarExtra` (`@AppStorage("settings.showMenuBarExtra") = true`) and `keepAppOpenAfterConversion` (`@AppStorage("settings.keepAppOpenAfterConversion") = true`). There is currently no `showInDock` (`settings.showInDock`) preference and no `Application Visibility` subsection in `SettingsView`.
- **Activation Policy:** Neither `AppDelegate` nor `MenuBarManager` manages `NSApplication.shared.activationPolicy()` (`.regular` vs `.accessory`).
- **Window Reopening & Deduplication:**
  - `AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)` iterates `sender.windows where window.canBecomeMain` and calls `makeKeyAndOrderFront(nil)`, but does not `deminiaturize(nil)` minimized windows or prune duplicate secondary windows created by SwiftUI `WindowGroup`.
  - `MenuBarManager.showMainWindow()` similarly checks `NSApp.windows where window.canBecomeMain` without deminiaturizing or handling the case where the user closed the window (`isVisible == false`) or switched activation policies.
- **Termination Safety:**
  - `AppDelegate.applicationShouldTerminateAfterLastWindowClosed(_:)` returns `!AppSettings.shared.keepAppOpenAfterConversion` unconditionally, without checking if conversions are actively running (`AppState.shared?.isConverting == true`), if the app is running in Menu Bar-only mode (`showInDock == false && showInMenuBar == true`), or if both icons are hidden (`showInDock == false && showInMenuBar == false`).

### 2.2 Accessibility & VoiceOver (`Features/**`)
- Live `System Events` inspection in Phase 46.11 showed that several SwiftUI `Button`s wrapping `Label(...)` inside `LazyVGrid` (`ImageEffectsChainView.swift`, `ImageColorAdjustmentsView.swift`) and icon-only toolbar buttons (`ImageLivePreviewCanvas.swift`) expose `missing value` for `AXTitle`/`AXName` unless `.accessibilityLabel(...)` is explicitly attached.
- `SettingsView.swift` (`Default Image Quality` slider) has an `.accessibilityLabel` but lacks `.accessibilityValue`.
- `FileRowView.swift`, `BatchJobGroupView.swift`, `PDFToolboxView.swift`, and `AudioToolboxView.swift` have minor gaps in slider `.accessibilityValue` and icon button `.accessibilityLabel` coverage.

### 2.3 Keyboard Shortcuts & Native Menus (`LocalConvertApp.swift`, `UndoMenuController.swift`, `AppSettings.swift`)
- `LocalConvertApp.swift` defines native `.commands` for `Settings...` (`⌘,`), `Undo` (`⌘Z`), `Redo` (`⇧⌘Z`), `Editing History...` (`⌥⌘Z`), `Add Files...` (`⌘O`), `Convert All` (`⌘↩`), and `Navigate` (`⌘1`–`⌘8`).
- `UndoMenuController.swift` already isolates editable `NSText`/`NSTextView` first responders so `⌘Z` / `⇧⌘Z` never clobber text editing.
- **Gaps Identified:**
  1. `KeyboardShortcutDescriptor.defaultShortcuts` in `AppSettings.swift` advertises `Repeat Last Conversion` (`⇧⌘R`) and `Cancel Active Conversion` (`Esc`), which only exist as view-local shortcuts inside `FileListView.swift` rather than native menu bar commands (`Conversion` menu or `File` command group).
  2. `Add Files...` (`⌘O`) in `LocalConvertApp.swift` unconditionally switches `appState.selectedTab = .convert`, even if the user invoked `⌘O` while working inside `PDF Toolbox`, `Image Toolbox`, `Audio Toolbox`, or `Metadata`.

### 2.4 Drag & Drop and Batch Conversion UX (`AppState.swift`, `FinderIntegration.swift`, `DropZoneView.swift`, `FileListView.swift`)
- `FinderHandoffHandler.validateAndSanitize` categorizes dropped URLs into `validURLs`, `rejectedFolders`, `inaccessibleURLs`, and `unsupportedURLs`.
- **Gaps Identified:**
  1. `AppState.handleDroppedURLs(_:)` silently ignores `inaccessibleURLs`, does not distinguish duplicate drops from new additions in `dropFeedbackText`, and does not inform the user when unsupported files were dropped.
  2. `AppState.importFilesFromPendingFolders()` performs directory enumeration and `fileDetector.detect(url:)` synchronously on `@MainActor` up to 1,000 files, which can briefly block the main thread on large directories.

### 2.5 Progress, Errors & Empty States (`ConversionManager.swift`, `JobRowView.swift`, `ContentView.swift`, `HistoryView.swift`)
- **Progress:** `ConversionQueue` and `JobRowView` report real determinate progress fractions (`0.0...1.0`) and fall back to indeterminate spinners when needed.
- **Error Presentation:** `ErrorDetailsFormatter` formats technical reports and redacts `password=`/`secret=`/`key=` patterns, but does not provide a structured **Suggested Action** (`suggestedRecoveryAction(for:)`) or redact home-directory username paths (`/Users/<user>/...` → `~/...`) in user-facing diagnostic blocks. `ContentView`'s global `.alert` shows a generic `"Notice"` title rather than a clear error title and recovery guidance.
- **Empty States:** `HistoryView`'s empty state (`"No Conversion History"`) lacks a primary action button (`"Convert Files"` → switches to `.convert`), unlike `JobsCenterView` and `DropZoneView`.

### 2.6 Global UI Consistency (`DesignSystem.swift`, `PDFToolboxView.swift`, `ImageToolboxView.swift`, `AudioToolboxView.swift`)
- All three toolboxes share `AppTheme.Layout.toolboxSidebarMin` (`195`) / `toolboxSidebarMax` (`230`), `AppToolboxSidebarRow`, `AppFileSelectionStrip`, and `AppBottomActionBar`.
- Minor consistency improvements: ensure uniform header/empty-state spacing, accessible filter/search empty states, and consistent Light/Dark semantic tokens (`AppTheme.Colors.*`) across all views.

---

## 3. Centralized Lifecycle & Visibility State Machine Design (Milestone 47.1)

### 3.1 Settings & Migration (`AppSettings.swift`, `SettingsView.swift`)
- Add `@AppStorage("settings.showInDock") var showInDock: Bool = true` (default `true`).
- Add `showInMenuBar: Bool` backed by the existing `@AppStorage("settings.showMenuBarExtra") var showMenuBarExtra: Bool = true` key (plus one-time sync if `settings.showInMenuBar` was ever set), guaranteeing **100% backward compatibility** with existing user defaults and existing unit tests (`Phase20Tests`, `Phase20BTests`).
- Neither `showInDock` nor `showMenuBarExtra`/`showInMenuBar` is recorded in `UndoRedoCoordinator`.
- In `SettingsView.swift` under `Section("General")`, add an **Application Visibility** group containing:
  1. `Toggle("Show in Dock", isOn: $settings.showInDock)`
  2. `Toggle("Show in Menu Bar", isOn: $settings.showInMenuBar)`
  3. Dynamic explanatory footer/banner when `showInDock == false && showInMenuBar == false` explaining how the user can reopen LocalConvert (via Finder, Spotlight, Launchpad, or `open -a LocalConvert`) and that closing the last window while both icons are hidden keeps active conversions safe and keeps the window accessible or cleanly reopenable.

### 3.2 Centralized `AppLifecycleManager` (`LocalConvert/App/AppLifecycleManager.swift`)
All activation policy changes, status item updates, and main window restoration/deduplication will flow through `@MainActor final class AppLifecycleManager: ObservableObject`:

| `showInDock` | `showInMenuBar` | `NSApplication.ActivationPolicy` | `NSStatusItem` (`MenuBarManager`) | Window Close / Reopen Behavior |
|---|---|---|---|---|
| **ON (`true`)** | **ON (`true`)** | `.regular` | Visible (single instance) | Standard macOS app. Closing main window hides/closes window without quitting (`keepAppOpenAfterConversion` or active jobs respected); Dock click or Menu Bar `"Open LocalConvert"` restores/deminiaturizes main window. |
| **ON (`true`)** | **OFF (`false`)** | `.regular` | Removed (`statusItem = nil`) | Dock-only app. Dock click (`applicationShouldHandleReopen`) restores/deminiaturizes main window. |
| **OFF (`false`)** | **ON (`true`)** | `.accessory` | Visible (single instance) | Menu Bar-only utility. Dock icon hidden; closing main window never terminates app while in accessory mode; Menu Bar `"Open LocalConvert"` or `"Settings..."` activates app and orders main window front. |
| **OFF (`false`)** | **OFF (`false`)** | `.accessory` | Removed (`statusItem = nil`) | Both icons hidden. Main window remains open and focused when toggled in Settings; if main window is closed while no conversions are active and both icons are OFF, `ensureAccessibleWindowWhenBothHidden()` or Finder/Spotlight launch (`applicationShouldHandleReopen` / `applicationDidBecomeActive`) immediately restores the main window so the app never becomes a stranded zombie process. Active conversions are never interrupted. |

### 3.3 Window Lifecycle & Termination Guards (`AppDelegate`)
- **Primary Window Retention & Deduplication:** `AppLifecycleManager` retains a weak/managed reference to the primary content `NSWindow`, sets `window.isReleasedWhenClosed = false` on the main window so closing the window (`performClose` / red close button) hides it cleanly and allows instant restoration via `makeKeyAndOrderFront(nil)` without losing SwiftUI state or spawning duplicate windows!
- **Distinguishing Window Operations:**
  - `performClose` (Close button / `⌘W`): hides/closes the window without terminating the app when `keepAppOpenAfterConversion` is true, when `showInMenuBar` is true, or when conversions are running.
  - `performMiniaturize` (Minimize / `⌘M`): preserves window state; reopening from Dock or Menu Bar calls `window.deminiaturize(nil)` before `makeKeyAndOrderFront(nil)`.
  - App Deactivation (switching apps): never closes windows or alters activation policy.
  - App Termination (`⌘Q` / `NSApplication.shared.terminate`): checked via `applicationShouldTerminate(_:)` — if conversions are actively running in an interactive (non-XCTest) session, either cancels cleanly in `applicationWillTerminate` or safeguards file writes (`UndoRedoCoordinator.shared.flushPersistence()`, `OutputManager.cleanupTemporaryFiles`).

---

## 4. Planned File Modifications & New Files

### New Files
1. `docs/PHASE47_ARCHITECTURE_PLAN.md` — This architecture audit and implementation specification.
2. `LocalConvert/App/AppLifecycleManager.swift` — Centralized `@MainActor` coordinator for Dock activation policy (`.regular` / `.accessory`), Menu Bar visibility delegation, primary window retention, deminiaturization, reopening, and termination safety.
3. `LocalConvertTests/Phase47LifecycleAndUXTests.swift` — Comprehensive test suite covering all 4 Dock/Menu Bar combinations, preference migration/persistence, duplicate `NSStatusItem` prevention, window reopen/minimize/close state machine, keyboard shortcut descriptors, Drag & Drop duplicate/unsupported/folder feedback, structured error formatting & path privacy sanitization, and accessibility metadata completeness.
4. `docs/PHASE47_FINAL_REPORT.md` — Final Phase 47 acceptance report (including concise user-facing documentation for Dock & Menu Bar visibility modes).

### Modified Files
1. `LocalConvert/Core/Settings/AppSettings.swift` — Add `showInDock` (`@AppStorage("settings.showInDock") = true`), `showInMenuBar` synchronized with `showMenuBarExtra` (`@AppStorage("settings.showMenuBarExtra") = true`), lifecycle notification hook, and `resetToDefaults()` update.
2. `LocalConvert/App/LocalConvertApp.swift` — Route `AppDelegate` lifecycle callbacks (`applicationDidFinishLaunching`, `applicationShouldHandleReopen`, `applicationShouldTerminateAfterLastWindowClosed`) through `AppLifecycleManager.shared`; make `⌘O` context-aware across tabs; add `Repeat Last Conversion` (`⇧⌘R`) and `Cancel Active Conversion` (`⌘.`) / menu items synchronize with `appState`.
3. `LocalConvert/Features/Home/MenuBarView.swift` — Delegate window activation/restoration to `AppLifecycleManager.shared.openMainWindow(tab:)`, expose testable status-item state on `MenuBarManager`, and ensure clean teardown when disabled.
4. `LocalConvert/Features/Home/SettingsView.swift` — Add `Application Visibility` controls (`Show in Dock`, `Show in Menu Bar`), explanatory banner when both are OFF, and `.accessibilityValue` on `Default Image Quality` slider.
5. `LocalConvert/Features/ImageToolbox/ImageEffectsChainView.swift`, `ImageColorAdjustmentsView.swift`, `ImageLivePreviewCanvas.swift`, `LocalConvert/Features/Conversion/FileRowView.swift`, `LocalConvert/Features/Jobs/BatchJobGroupView.swift` — Add explicit `.accessibilityLabel` and `.accessibilityValue` modifiers identified in the 46.11 & 47.2 audit.
6. `LocalConvert/App/AppState.swift` — Improve `handleDroppedURLs` feedback for duplicates, unsupported files, and inaccessible URLs; move folder enumeration onto a background task (`importFilesFromPendingFolders`) while keeping deterministic completion notification; add structured `errorTitle` and `errorRecoverySuggestion`.
7. `LocalConvert/Core/Conversion/ConversionManager.swift`, `LocalConvert/Features/Jobs/JobRowView.swift`, `LocalConvert/Features/Home/ContentView.swift`, `LocalConvert/Features/History/HistoryView.swift` — Add user-friendly recovery suggestions and home-path privacy redaction (`~/...`) to `ErrorDetailsFormatter`, expandable technical details in error alerts/sheets, and an actionable `"Convert Files"` button on `HistoryView`'s empty state.

---

## 5. Milestone Dependency Order & Test Strategy

1. **Milestone 47.0 (Architecture Audit):** Read-only inspection and creation of `docs/PHASE47_ARCHITECTURE_PLAN.md`.
2. **Milestone 47.1 (Dock & Menu Bar Visibility & Lifecycle):** Implement `AppLifecycleManager.swift`, update `AppSettings.swift`, `MenuBarView.swift`, `LocalConvertApp.swift`, `SettingsView.swift`, and verify with `Phase47LifecycleAndUXTests` + `Phase20Tests` + `Phase20BTests`.
3. **Milestone 47.2 (Accessibility & VoiceOver):** Add missing `.accessibilityLabel` / `.accessibilityValue` / `.accessibilityHint` metadata across Image Toolbox, Conversion queue, Jobs Center, and Settings; verify with automated accessibility tests and live `System Events` query.
4. **Milestone 47.3 (Keyboard Shortcuts & Native Menus):** Context-aware `⌘O`, menu bar command parity (`⇧⌘R` Repeat Last Conversion, `Cancel Active Conversion`), enabled/disabled state sync; verify with `Phase47LifecycleAndUXTests` + `Phase30Tests` + `GlobalUndoRedoTests`.
5. **Milestone 47.4 (Drag & Drop and Batch UX):** Duplicate/unsupported/inaccessible drop feedback and non-blocking folder import; verify with `Phase47LifecycleAndUXTests` + `Phase10Tests` + `Phase19Tests`.
6. **Milestone 47.5 (Progress, Errors & Empty States):** Structured error title, explanation, suggested action, home-path sanitization in `ErrorDetailsFormatter`, expandable details in `ErrorDetailsSheet`/`ContentView`, and actionable `HistoryView` empty state; verify with `Phase47LifecycleAndUXTests` + `Phase28Tests`.
7. **Milestone 47.6 (Global UI Consistency):** Audit and align headers, dividers, empty states, and Light/Dark semantic tokens across PDF Toolbox, Image Toolbox, Audio Toolbox, and main views.
8. **Milestone 47.7 (Integration, Quiescent Full Regression, GUI Acceptance & Final Report):** Run focused suites, execute one quiescent full `LocalConvertTests` regression run, run live macOS GUI verification where permitted, and write `docs/PHASE47_FINAL_REPORT.md`.
