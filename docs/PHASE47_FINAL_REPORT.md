# LocalConvert — Phase 47 Final Acceptance Report
## Production Quality, macOS Lifecycle & Product Experience

**Date:** 2026-11-21  
**Target Platform:** macOS 15.0+, Apple Silicon (`arm64`), Swift 6 (`SWIFT_STRICT_CONCURRENCY: complete`)  
**App Version:** `1.0.0` (`MARKETING_VERSION: "1.0.0"`)  
**Architecture Plan:** `docs/PHASE47_ARCHITECTURE_PLAN.md`  
**Scope:** Milestones 47.0 – 47.7 (Dock & Menu Bar Visibility, Centralized Lifecycle, Accessibility, Native Menus/Shortcuts, Drag & Drop / Batch UX, Progress/Errors/Empty States, Global UI Consistency, Quiescent Full Regression & Acceptance)

---

## 1. Executive Summary

Phase 47 delivered a controlled macOS application-lifecycle, accessibility, native shortcut, batch Drag & Drop, error-presentation, empty-state, and UI-consistency upgrade across LocalConvert while preserving all existing conversion engines, PDF/Image/Audio toolboxes, `DesignSystem`/`AppTheme` tokens, Global Undo/Redo, and data integrity:

- **Full Quiescent Regression (`LocalConvertTests`, `arm64`, Swift 6):** **598 / 598 tests passed across 77 / 77 suites** (`0` failures, `0` skipped tests, `0` Swift 6 compiler warnings).
- **Dock & Menu Bar Visibility (`47.1`):** Added `Settings → General → Application Visibility` (`Show in Dock`, `Show in Menu Bar`, defaults `true` / `true`), centralized all activation policy (`.regular` / `.accessory`, never `.prohibited`), status-item, window-restoration, and termination-protection rules in `AppLifecycleManager`, and migrated `settings.showMenuBarExtra` bidirectionally without losing user preferences or polluting Global Undo/Redo.
- **Accessibility & VoiceOver (`47.2`):** Added missing `.accessibilityLabel` and `.accessibilityValue` metadata across Image Toolbox (`ImageEffectsChainView`, `ImageColorAdjustmentsView`, `ImageLivePreviewCanvas`), `SettingsView`, `DesignSystem` (`AppFileSelectionStrip`), and `JobRowView`, and added consecutive-duplicate suppression (`1.2s` window) in `AccessibilityAnnouncer`.
- **Keyboard Shortcuts & Native Menus (`47.3`):** Added context-aware `⌘O` routing (`AppState.routeOpenFiles`), synchronized `Convert All` (`⌘↩`) with `canStartBatchConversion`, added `Repeat Last Conversion` (`⇧⌘R`) and `Cancel Active Conversion` to native menu commands, added window restoration on `⌘,` / `⌘1`–`⌘8`, and verified zero duplicate shortcut bindings.
- **Drag & Drop & Batch UX (`47.4`):** Added explicit duplicate-drop and unsupported-file feedback in `AppState.handleDroppedURLs` and undoable queue reordering (`AppState.moveFiles(fromOffsets:toOffset:)`).
- **Progress, Structured Errors & Empty States (`47.5`):** Separated determinate (`fractionCompleted != nil`) vs. indeterminate progress in `JobRowView` so indeterminate jobs never display a fabricated `50%` label; added user-friendly error titles, corrective recovery suggestions, and macOS username home-path redaction (`/Users/<user>` → `~`) in `ErrorDetailsFormatter`, `ErrorDetailsSheet`, and `AppState.showError`; and added actionable primary buttons to `HistoryView` and `PresetManagerView` empty states.
- **Global UI Consistency (`47.6`):** Unified header dividers on `AppDivider()` across `PresetManagerView`, `JobsCenterView`, `MetadataView`, and `FileListView`, and verified `AppTheme.Layout` and Light/Dark opaque surface tokens.

---

## 2. Milestone-by-Milestone Implementation Results

| Milestone | Scope | Verification Suite(s) | Result | Status |
|---|---|---|---|---|
| **47.0** | Read-only architecture audit & `docs/PHASE47_ARCHITECTURE_PLAN.md` (documented that Stock Pink / `SwiftStockMonitorApp.swift` is not present in workspace) | Static inspection | `docs/PHASE47_ARCHITECTURE_PLAN.md` created; 0 production edits | **PASS** |
| **47.1** | Dock & Menu Bar visibility (`Show in Dock`, `Show in Menu Bar`), `AppLifecycleManager`, `MenuBarManager` deduplication, window close/minimize/reopen, active-conversion termination guard | `Phase47LifecycleAndUXTests`, `Phase20Tests`, `Phase20BTests` | 21 / 21 tests passed | **PASS** |
| **47.2** | Accessibility labels/values across Image Toolbox, Settings, preview canvas, file strip, and `AccessibilityAnnouncer` deduplication | `Phase47LifecycleAndUXTests` | 4 / 4 tests passed (metadata verified; live VoiceOver audio **MANUAL REQUIRED**) | **CONDITIONAL PASS** |
| **47.3** | Context-aware `⌘O`, native menu parity (`⇧⌘R`, `⌘↩`, `Cancel Active Conversion`), window restoration on menu navigation, duplicate-shortcut check | `Phase47LifecycleAndUXTests`, `Phase30Tests` | 18 / 18 tests passed | **PASS** |
| **47.4** | Single/multi-file drop, duplicate & unsupported drop feedback, folder smart import, and undoable queue reordering (`moveFiles`) | `Phase47LifecycleAndUXTests`, `Phase19Tests`, `Phase29Tests` | 32 / 32 tests passed | **PASS** |
| **47.5** | Real determinate vs. indeterminate progress in `JobRowView`, structured error title/suggestion/home-path sanitization in `ErrorDetailsFormatter`, expandable `ErrorDetailsSheet`, actionable empty states | `Phase47LifecycleAndUXTests`, `Phase30Tests` | 20 / 20 tests passed | **PASS** |
| **47.6** | `AppDivider()` header consistency, `PresetManagerView` empty state CTA, `AppTheme.Layout` & Light/Dark token verification | `Phase47LifecycleAndUXTests` | 8 / 8 tests passed | **PASS** |
| **47.7** | Quiescent full `LocalConvertTests` (`arm64`, Swift 6) regression & live GUI acceptance check | Full `LocalConvertTests` (`77` suites) | **598 / 598 tests passed**, **77 / 77 suites passed**, `0` warnings | **PASS** |

---

## 3. Architecture Decisions

1. **Centralized `@MainActor` Lifecycle Coordinator (`AppLifecycleManager`):** Rather than scattering `NSApp.setActivationPolicy` calls across SwiftUI views and `AppDelegate`, `AppLifecycleManager.shared` owns all activation policy transitions, delegates status-item lifecycle to `MenuBarManager.shared`, retains the primary content `NSWindow` with `isReleasedWhenClosed = false`, and centralizes `shouldTerminateAfterLastWindowClosed`.
2. **Non-Destructive Window Retention (`isReleasedWhenClosed = false`):** Closing the main window (`performClose` / red close button) hides (`orderOut`) the retained window rather than deallocating the SwiftUI view hierarchy, allowing instant reopening from the Dock, Menu Bar, Finder, Spotlight, or menu shortcuts (`⌘,`, `⌘1`–`⌘8`) without spawning duplicate windows or losing active conversion/editing state.
3. **Stock Pink Reference Handling:** As verified in Milestone 47.0, no `SwiftStockMonitorApp.swift` or Stock Pink files exist in `/Users/cancan/Desktop/LocalConvert/`. All lifecycle transitions were engineered directly from Section 5's state-machine specification.

---

## 4. Modified Files

1. `LocalConvert/Core/Settings/AppSettings.swift` — Added `showInDock`, `showInMenuBar` (synchronized with legacy `showMenuBarExtra`), `migrateVisibilityPreferencesIfNeeded(defaults:)`, `resetToDefaults()` updates, and `KeyboardShortcutDescriptor.hasDuplicateShortcuts`.
2. `LocalConvert/App/LocalConvertApp.swift` — Routed `AppDelegate` callbacks through `AppLifecycleManager.shared`, added window restoration on `⌘,` and `⌘1`–`⌘8`, added `Repeat Last Conversion` (`⇧⌘R`) and `Cancel Active Conversion` menu commands, and routed `⌘O` through `appState.routeOpenFiles`.
3. `LocalConvert/Features/Home/MenuBarView.swift` — Delegated window reopening to `AppLifecycleManager.shared.restoreOrActivateMainWindow`, added `isMenuBarExtraActive` / `hasLiveStatusItem` tracking, and ensured clean `NSStatusItem` teardown without duplicates.
4. `LocalConvert/Features/Home/SettingsView.swift` — Added `Application Visibility` (`Show in Dock`, `Show in Menu Bar`), explanatory info banner when both icons are disabled, and `.accessibilityValue` on the `Default Image Quality` slider.
5. `LocalConvert/Features/Shared/DesignSystem.swift` — Registered main window with `AppLifecycleManager.shared` in `OpaqueChromeSentinelView.viewDidMoveToWindow()` and added `.accessibilityLabel` / `.accessibilityValue` on `AppFileSelectionStrip` items.
6. `LocalConvert/Features/ImageToolbox/ImageEffectsChainView.swift` — Added explicit `.accessibilityLabel` / `.accessibilityValue` modifiers on sub-tabs, effect add buttons, stack reset, per-slot enable toggles, move/reset/remove buttons, and RAW sliders.
7. `LocalConvert/Features/ImageToolbox/ImageColorAdjustmentsView.swift` — Added `.accessibilityLabel` / `.accessibilityValue` on sub-tabs and `Reset Color & Light`.
8. `LocalConvert/Features/ImageToolbox/ImageLivePreviewCanvas.swift` — Added explicit `.accessibilityLabel` modifiers on `Fit`, `100%`, `Zoom out`, `Zoom in`, and zoom readout.
9. `LocalConvert/Core/Notifications/AppNotificationManager.swift` — Added consecutive-duplicate announcement suppression (`1.2s` window) and `resetRecentAnnouncements()` in `AccessibilityAnnouncer`.
10. `LocalConvert/App/AppState.swift` — Added `routeOpenFiles(_:)`, `canStartBatchConversion`, duplicate & unsupported drop feedback in `handleDroppedURLs(_:)`, undoable `moveFiles(fromOffsets:toOffset:)`, and structured `errorTitle` / `errorSuggestion` in `showError(...)`.
11. `LocalConvert/Core/Conversion/ConversionManager.swift` — Added `ErrorDetailsFormatter.title(for:)`, `suggestedAction(for:)`, `token=` redaction, and macOS `/Users/<username>` → `~` home-path privacy redaction.
12. `LocalConvert/Features/Jobs/JobRowView.swift` — Separated determinate vs. indeterminate progress rendering (eliminating fabricated `50%` on indeterminate jobs) and upgraded `ErrorDetailsSheet` with structured title, suggested action banner, and expandable `DisclosureGroup("Technical Details")`.
13. `LocalConvert/Features/Home/ContentView.swift` — Updated global error alert to display `appState.errorTitle`, `errorMessage`, `errorSuggestion`, and sanitized `errorDetails`.
14. `LocalConvert/Features/History/HistoryView.swift` — Added `"Go to Convert"` primary action button to the empty state.
15. `LocalConvert/Features/Presets/PresetManagerView.swift` — Added `"Create New Preset..."` primary action button to the empty state and unified header separator on `AppDivider()`.
16. `LocalConvert/Features/Jobs/JobsCenterView.swift`, `LocalConvert/Features/Metadata/MetadataView.swift`, `LocalConvert/Features/Conversion/FileListView.swift` — Unified structural separators on `AppDivider()`.

---

## 5. New Files

1. `docs/PHASE47_ARCHITECTURE_PLAN.md` — Milestone 47.0 architecture audit and design plan.
2. `LocalConvert/App/AppLifecycleManager.swift` — Centralized `@MainActor` lifecycle, activation policy, window retention/restoration, and termination-protection manager.
3. `LocalConvertTests/Phase47LifecycleAndUXTests.swift` — 8 focused automated tests covering Milestones 47.1–47.6.
4. `docs/PHASE47_FINAL_REPORT.md` — This final Phase 47 acceptance report and user guide.

---

## 6. Dock & Menu Bar Four-Combination Results

| Combination | `showInDock` | `showInMenuBar` | Activation Policy | `MenuBarManager.isMenuBarExtraActive` | Verified Behavior |
|---|---|---|---|---|---|
| **A. Dock ON / Menu Bar ON** | `true` | `true` | `.regular` | `true` | Default standard macOS mode; both icons active; closing window retains app; Dock or Menu Bar reopens main window. |
| **B. Dock ON / Menu Bar OFF** | `true` | `false` | `.regular` | `false` (`statusItem` removed) | Dock-only mode; status item cleanly removed; Dock reopens main window. |
| **C. Dock OFF / Menu Bar ON** | `false` | `true` | `.accessory` | `true` | Menu Bar-only mode; Dock icon hidden; closing window never quits app; Menu Bar actions (`Open LocalConvert`, `Add Files to Convert...`, `Settings...`, `Quit LocalConvert`) restore/activate main window. |
| **D. Dock OFF / Menu Bar OFF** | `false` | `false` | `.accessory` | `false` (`statusItem` removed) | Both icons hidden; `SettingsView` displays `AppLifecycleManager.bothIconsHiddenGuidance`; main window stays accessible; closing window does not terminate app; Finder/Spotlight launch (`applicationShouldHandleReopen`) restores main window; `⌘Q` quits cleanly. |

---

## 7. Application Lifecycle Behavior

- **Window Close (`performClose`) vs. Minimize (`performMiniaturize`) vs. Termination (`⌘Q`):**
  - `registerWindow` sets `window.isReleasedWhenClosed = false`.
  - Closing the window hides it (`orderOut`) without deallocating SwiftUI state; `restoreOrActivateMainWindow()` calls `deminiaturize(nil)` if minimized and `makeKeyAndOrderFront(nil)`.
  - `shouldTerminateAfterLastWindowClosed` returns `false` whenever `appState.isConverting || appState.activeJobCount > 0`, whenever `keepAppOpenAfterConversion == true`, whenever `showInMenuBar == true`, or whenever both icons are hidden (`!showInDock && !showInMenuBar`).
  - `prepareForTermination` (`applicationWillTerminate`) cancels queued subprocesses, flushes `UndoRedoCoordinator.shared.flushPersistence()`, and cleans temporary files.

---

## 8. Settings Migration

- `AppSettings.migrateVisibilityPreferencesIfNeeded(defaults:)` preserves existing `settings.showMenuBarExtra` values by syncing them into `settings.showInMenuBar` on upgrade and initializing `settings.showInDock = true` when unset.
- Modifying `showInDock` or `showInMenuBar` updates `UserDefaults` and `AppLifecycleManager.shared` immediately and never records entries in `UndoRedoCoordinator` (`timelineRevision` remains unchanged).

---

## 9. Accessibility Results

- Added explicit `.accessibilityLabel` and `.accessibilityValue` metadata across `ImageEffectsChainView`, `ImageColorAdjustmentsView`, `ImageLivePreviewCanvas` (replacing tooltip-only zoom buttons with accessibility labels), `SettingsView`, `DesignSystem` (`AppFileSelectionStrip`), and `JobRowView`.
- `AccessibilityAnnouncer` suppresses duplicate consecutive announcements within `1.2s` and ignores whitespace-only strings (`47.2` test passed).
- **Manual Boundary:** Actual spoken VoiceOver navigation and focus-ring visual inspection across modal sheets remain **MANUAL REQUIRED**.

---

## 10. Keyboard Shortcut Results

- Verified zero duplicate shortcut bindings (`KeyboardShortcutDescriptor.hasDuplicateShortcuts == false`).
- `⌘O` (`routeOpenFiles`), `⌘,` (`Settings...`), `⌘Q` (`Quit`), `⌘Z` (`Undo`), `⇧⌘Z` (`Redo`), `⌥⌘Z` (`Editing History...`), `⌘↩` (`Convert All`), `⇧⌘R` (`Repeat Last Conversion`), `Esc` (sheet dismissal / active conversion cancel), and `⌘1`–`⌘8` tab navigation are wired and state-synchronized.
- Editable `NSText`/`NSTextView` focus isolation remains verified via `UndoMenuController`.

---

## 11. Drag & Drop and Batch Results

- Single-file, multi-file, and folder drops validate paths via `FinderHandoffHandler.validateAndSanitize` (`resolvingSymlinksInPath().standardizedFileURL`).
- Duplicate drops no longer show misleading `"1 file added"` messages; instead they display `"File is already in the queue"` or `"(N duplicate skipped)"`.
- Unsupported files display `"N unsupported file(s) added"`.
- Added undoable `AppState.moveFiles(fromOffsets:toOffset:)` for queue reordering (`47.4` test passed).

---

## 12. Progress, Error UX & Empty State Results

- **Progress:** `JobRowView` inspects `progress.fractionCompleted`: determinate jobs render a `0–100%` linear bar and percentage text, while indeterminate jobs (`fractionCompleted == nil`) render an indeterminate linear `ProgressView()` with no fabricated percentage.
- **Errors:** `ErrorDetailsFormatter` provides `title(for:)`, `suggestedAction(for:)`, credential redaction (`password=`, `pwd=`, `secret=`, `token=`, `key=`), and home-directory username redaction (`/Users/<username>` → `~`). `ErrorDetailsSheet` presents the title, explanation, suggested action banner, and expandable `DisclosureGroup("Technical Details")`.
- **Empty States:** All empty states (`DropZoneView`, `JobsCenterView`, `HistoryView`, `PresetManagerView`, `MetadataView`, `PDFToolboxView`, `AudioToolboxView`, `ImageToolboxView`) use `AppEmptyStateView` and communicate the next useful action.

---

## 13. Global UI Consistency Results

- Verified consistent sidebar width ranges (`mainSidebarMin = 165`, `toolboxSidebarMin = 195`, `toolboxSidebarMax = 230`), window minimum/default dimensions (`820×580` / `1080×740`), opaque Light/Dark window chrome (`OpaqueWindowChromeHost`), and `AppDivider()` header separators across all workspaces.

---

## 14. Build Results

- `xcodegen generate` succeeded cleanly (`project.yml` remains the source of truth; `MARKETING_VERSION: "1.0.0"`, `ARCHS: "arm64"`, `SWIFT_VERSION: "6.0"`, `MACOSX_DEPLOYMENT_TARGET: "15.0"`, `SWIFT_STRICT_CONCURRENCY: complete`).
- `xcodebuild test` compiled both `LocalConvert` and `LocalConvertTests` for `platform=macOS,arch=arm64` with **0 build errors** and **0 Swift 6 compiler warnings** (`ZERO_SWIFT_WARNINGS` verified in `/tmp/lc_phase47_full.log`).

---

## 15. Test Counts & Failures

- **Final Quiescent Full Regression (`task-2452`, `/tmp/lc_phase47_full.log`):**
  - **Total Suites:** **77 / 77 passed** (`0` failed)
  - **Total Tests:** **598 / 598 passed** (`0` failed, `0` skipped)
  - **Duration:** `281.955 seconds`
  - **New Phase 47 Suite (`Phase47LifecycleAndUXTests`):** **8 / 8 tests passed** (`0.226 seconds`)

---

## 16. Memory-Test Findings (`Phase422ClosureTests`)

- Under the quiescent full-regression environment (`QUIESCENT_HOST` verified via `pgrep` with no background `LocalConvert.app` GUI process running), `Phase422ClosureTests.largeImageMemoryStabilityAndDiagnostics()` **passed cleanly inside the full 77-suite run** (`57.448 seconds`):
  - **50 MP (`8192×6104`) 4 iterations:** `footprintMB` went `535.6 → 537.3 → 508.4 → 509.3 MB` (`-26.3 MB` delta vs. `+150.0 MB` threshold); `nonVolatileInternalMB` stayed `0.0 MB` across all 4 iterations.
  - **100 MP (`10000×10000`) 4 iterations:** `footprintMB` went `1534.1 → 1184.6 → 1184.3 → 1185.3 MB` (`-348.8 MB` delta); `nonVolatileInternalMB` went `426.4 → 79.8 → 79.5 → 81.5 MB` (`-344.9 MB` delta).
- No thresholds in `Phase422ClosureTests.swift` were modified or weakened.

---

## 17. GUI Verification Boundaries

- **Observed in Live Running GUI (`LocalConvert.app` Debug `arm64`):**
  - Initial testing exposed a window-visibility check bug in `AppLifecycleManager.registerWindow` when launching `LocalConvert.app` with an external file argument (`window.orderOut(nil)` hid the newly opened window while the initial window was not visible). We fixed `registerWindow` and `resolvePrimaryWindow` so non-visible windows never suppress visible windows and `primaryWindow` is preserved across close/reopen.
  - Subsequent live `System Events` GUI run (`task-2448`) confirmed `LocalConvert.app` launches cleanly, navigates between `Convert`, `Settings`, and `Image Toolbox` (`Effects & Presets`), and terminates cleanly via `quit` (`CLEANLY_TERMINATED`).
- **Remaining Manual Desktop Verification (`MANUAL REQUIRED`):**
  - Visual Dock icon appearance/disappearance and Menu Bar status item popover clicking across all 4 `Show in Dock` / `Show in Menu Bar` combinations (headless `screencapture` lacks Screen Recording permission).
  - Live spoken VoiceOver cursor traversal and Light/Dark visual contrast inspection.
  - Real camera sensor RAW file smoke testing from at least two camera vendors (carried over from Phase 46.11).

---

## 18. User-Facing Documentation — Application Visibility (Dock & Menu Bar)

### How Dock Visibility Works (`Show in Dock`)
- Located in **Settings → General → Application Visibility → Show in Dock** (enabled by default).
- When **ON**, LocalConvert appears in the macOS Dock, the `⌘Tab` Application Switcher, and the main macOS menu bar (`LocalConvert`, `File`, `Edit`, `Navigate`). Clicking the Dock icon reopens or unminimizes the main LocalConvert window.
- When **OFF**, LocalConvert runs in macOS accessory mode (`.accessory`), hiding its Dock and `⌘Tab` icon so it stays out of your way while you work.

### How Menu Bar Visibility Works (`Show in Menu Bar`)
- Located in **Settings → General → Application Visibility → Show in Menu Bar** (enabled by default).
- When **ON**, LocalConvert displays a quick-access icon (`arrow.triangle.2.circlepath`) in the right side of the macOS Menu Bar showing live conversion progress and providing one-click access to **Open LocalConvert**, **Add Files to Convert...**, **Open Jobs Center**, **Open Presets**, **Settings...** (`⌘,`), and **Quit LocalConvert** (`⌘Q`).
- When **OFF**, the Menu Bar icon is removed immediately.

### What Happens When Both Are Disabled (`Show in Dock: OFF` & `Show in Menu Bar: OFF`)
- Both the Dock icon and the Menu Bar icon are hidden, and Settings displays an informational notice reminding you how to access the app.
- The currently open LocalConvert window remains active and usable, and any running conversions continue safely without interruption.
- Closing the window while both icons are hidden does **not** terminate active conversions or corrupt files.

### How to Reopen or Quit LocalConvert
- **When Dock is ON:** Click the LocalConvert icon in the Dock.
- **When Menu Bar is ON:** Click the LocalConvert icon in the macOS Menu Bar and choose **Open LocalConvert** or **Settings...**.
- **When Both Dock and Menu Bar are OFF:** Launch **LocalConvert** from **Finder** (`/Applications/LocalConvert.app`), **Spotlight** (`⌘Space` → type `LocalConvert`), or **Launchpad** — macOS immediately brings the existing LocalConvert window back to the front.
- **To Quit Completely at Any Time:** Bring LocalConvert to the front and press **`⌘Q`** (or choose **Quit LocalConvert** from the Menu Bar icon when enabled).

---

## 19. Final Acceptance Recommendation

**Verdict: CONDITIONAL GO**

- **Why Core Engineering Qualifies for GO:** All milestones (`47.0`–`47.7`) are complete; the final quiescent full regression passed **598 / 598 tests across 77 / 77 suites** (including all 8 new `Phase47LifecycleAndUXTests` and `Phase422ClosureTests`) with **0 Swift 6 compiler warnings**; all four Dock/Menu Bar combinations, preference migration, window close/minimize/reopen, active-conversion termination guards, shortcut routing, Drag & Drop feedback, determinate/indeterminate progress, and privacy-sanitized structured errors are implemented and verified.
- **Why Verdict is CONDITIONAL GO (Per Section 14 Criteria):** Because headless terminal execution lacks Screen Recording permission and interactive VoiceOver audio output, final visual confirmation of the 4 Dock/Menu Bar icon combinations on the macOS desktop and live VoiceOver focus traversal remain **MANUAL REQUIRED** prior to public release.


---

## 20. Phase 47.1.1 Addendum — Application Visibility UX Correction (2026-11-21)

### 20.1 Unified 4-Option Application Visibility Control & Model
- **Enum Model (`ApplicationVisibilityMode` in `AppSettings.swift`):**
  - Cases: `.both` (`"Dock + Menu Bar"`), `.dockOnly` (`"Dock Only"`), `.menuBarOnly` (`"Menu Bar Only"`), `.neither` (`"Neither"`).
  - Mapped 1-to-1 with `(showInDock, showInMenuBar)` / `showMenuBarExtra` using an internal `isUpdatingVisibilityMode` guard so changing `applicationVisibilityMode`, `showInDock`, or `showInMenuBar` never creates a recursive feedback loop and triggers `AppLifecycleManager.shared.applyVisibilityPreferences(settings: self)` once.
  - Legacy `settings.showMenuBarExtra` and `settings.showInDock` preferences migrate automatically into `settings.applicationVisibilityMode` on startup.
- **Native macOS Settings Design (`SettingsView.swift`):**
  - Placed a single `Picker("Application Visibility", selection: $settings.applicationVisibilityMode)` in `Section("General")` directly below `Appearance Theme`, displaying all 4 options with concise descriptions (`menuOptionLabel` + active `shortDescription` caption below, plus the Finder/Spotlight reopening `AppInfoBanner` when `.neither` is selected).
  - Verified in the live running macOS GUI via `System Events` (`task-2481`): the pop-up button renders with default `"Dock + Menu Bar"` and exposes all four options (`Dock + Menu Bar — Show LocalConvert in both the Dock and Menu Bar`, `Dock Only — Show in the Dock only and hide the Menu Bar icon`, `Menu Bar Only — Show in the Menu Bar only and hide the Dock icon`, `Neither — Hide both the Dock and Menu Bar icons (reopen via Finder or Spotlight)`).

### 20.2 Activation Policy, Menu Bar & Keep Running Independence
- **Activation Policy & Menu Bar Mapping:**
  - `.both`: `.regular` activation policy + `MenuBarManager` active (`showInDock = true`, `showInMenuBar = true`).
  - `.dockOnly`: `.regular` activation policy + `NSStatusItem` removed (`showInDock = true`, `showInMenuBar = false`).
  - `.menuBarOnly`: `.accessory` activation policy + `MenuBarManager` active (`showInDock = false`, `showInMenuBar = true`).
  - `.neither`: `.accessory` activation policy + `NSStatusItem` removed (`showInDock = false`, `showInMenuBar = false`).
- **`Keep app running when all windows are closed` Independence (`AppLifecycleManager.shouldTerminateAfterLastWindowClosed`):**
  - `keepAppOpenAfterConversion` remains completely independent of `ApplicationVisibilityMode`. Changing `applicationVisibilityMode` never mutates `keepAppOpenAfterConversion`.
  - When conversions are actively running (`appState.isConverting || appState.activeJobCount > 0`), `shouldTerminateAfterLastWindowClosed` always returns `false` across all modes. When idle, it returns `!settings.keepAppOpenAfterConversion` across all four visibility modes.

### 20.3 Verification & Manual Desktop Boundaries
- **Focused Automated Tests (`task-2477`):** `Phase47LifecycleAndUXTests` (`9 / 9` tests, including new test `47.1.1 ApplicationVisibilityMode enum mapping, persistence, Keep Running independence, close/minimize separation, and active conversion safety`), `Phase20Tests`, and `Phase20BTests` passed **27 / 27 tests across 3 suites** in `0.313s` with `0` compiler warnings.
- **Live GUI Verification (`task-2481`):** Launched `LocalConvert.app`, navigated to `Settings`, opened the `Application Visibility` pop-up button via `System Events`, verified all 4 option titles and descriptions and the independent `Keep app running when all windows are closed` toggle, and quit cleanly.
- **Manual Desktop Requirement:** Visual confirmation of the physical macOS Dock tile and right-hand Menu Bar icon appearing/disappearing across the 4 picker selections remains a quick desktop visual check (headless `screencapture` lacks Screen Recording permission).


---

## 21. Debug Build Deployment (2026-11-21)

- **Build Result:** `xcodegen generate && xcodebuild build -project LocalConvert.xcodeproj -scheme LocalConvert -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lc_debug_deploy_dd CONFIGURATION_BUILD_DIR=/Users/cancan/Desktop/LocalConvert/debug-deployment` → **BUILD SUCCEEDED** (`0` errors; `/Applications/LocalConvert.app` and `release/Build/Products/Release/LocalConvert.app` untouched).
- **Created App Path:** `/Users/cancan/Desktop/LocalConvert/debug-deployment/LocalConvert.app`
- **Bundle Identifier:** `com.localconvert.app`
- **Version / Build:** `1.0.0` (`CFBundleShortVersionString = 1.0.0`, `CFBundleVersion = 1`)
- **Architecture:** `arm64`
- **Build Configuration:** `Debug` (macOS 15.0+ deployment target, Swift 6 strict concurrency)
- **Executable Modification Date:** `2026-11-21 01:55:48`
- **Executable SHA-256:** `9c962c9203326832384f98f8ee8c06ce41b3eec7021ec85c7684dd7742a63596`
- **Running Process Verification (`lsappinfo info -app LocalConvert`):**
  - `pid = 21316`
  - `bundleID = "com.localconvert.app"`
  - `bundle path = "/Users/cancan/Desktop/LocalConvert/debug-deployment/LocalConvert.app"`
  - `executable path = "/Users/cancan/Desktop/LocalConvert/debug-deployment/LocalConvert.app/Contents/MacOS/LocalConvert"`
- **Phase 47.1.1 Settings UI Verification (Live App):**
  - `Settings → General → Application Visibility` (`Dock + Menu Bar` default) renders all four options with descriptions (`Dock + Menu Bar`, `Dock Only`, `Menu Bar Only`, `Neither`), and `Keep app running when all windows are closed` is visible and independent.

---

## 22. Application Visibility Popover Redesign (Phase 47.1.2, 2026-11-21)

- **Modified Files:**
  - `LocalConvert/Core/Settings/AppSettings.swift`: Added `popoverSubtitle` and `systemImage` on `ApplicationVisibilityMode` for the four visibility options (`Dock + Menu Bar` / `Show in both locations`, `Dock Only` / `Show only in the Dock`, `Menu Bar Only` / `Show only in the Menu Bar`, `Neither` / `Hide both icons`).
  - `LocalConvert/Features/Home/SettingsView.swift`: Replaced the native SwiftUI `Picker` dropdown with `ApplicationVisibilitySelector`, `ApplicationVisibilityPopoverContent`, and `ApplicationVisibilityOptionRow` (compact bordered trigger button with SF Symbol, current mode label, and `chevron.up.chevron.down`; `.regularMaterial` popover with 4 vertical option rows, active `checkmark`, hover/selected `AppTheme.Colors` highlights, Up/Down keyboard navigation, `Escape`/`.onExitCommand` dismiss, auto-dismiss on selection, and native `AXButton` `AXPress` accessibility support).
  - `LocalConvertTests/Phase47LifecycleAndUXTests.swift`: Added `47.1.2 ApplicationVisibilityMode popover metadata, SF Symbols, selection auto-dismiss, and theme compatibility`.
- **Focused Test Verification (After Final Edit):**
  - `xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lc_phase4712_dd -only-testing:LocalConvertTests/Phase47LifecycleAndUXTests -only-testing:LocalConvertTests/Phase20Tests -only-testing:LocalConvertTests/Phase20BTests`: **28/28 tests in 3 suites passed** (`0.438s`, `** TEST SUCCEEDED **`).
- **Fresh Debug Build & Deployment:**
  - Built into `/Users/cancan/Desktop/LocalConvert/debug-deployment/LocalConvert.app` (`CFBundleShortVersionString = 1.0.0`, `CFBundleVersion = 1`, `arm64`, executable size `40640` bytes, SHA-256 `b3811a9629bb590f58a290bb93c41274cf8bc2cc47592f8141463cb9985955d3`, `** BUILD SUCCEEDED **`).
  - Confirmed `/Applications/LocalConvert.app` and `release/Build/Products/Release/LocalConvert.app` untouched.
- **Live App & Accessibility Verification (`System Events` on `debug-deployment/LocalConvert.app`):**
  - Launched `debug-deployment/LocalConvert.app` and verified via `lsappinfo info -app LocalConvert` (`bundle path="/Users/cancan/Desktop/LocalConvert/debug-deployment/LocalConvert.app"`).
  - Opened `Settings` and triggered `Application Visibility` via `AXPress`: verified `AXPopover` opens with 4 `AXButton` rows (`260×42`), subtitles (`Show in both locations`, `Show only in the Dock`, `Show only in the Menu Bar`, `Hide both icons`), and `Selected` / `Not selected` accessibility values.
  - Selected `Dock Only`, confirmed popover auto-dismisses and closed trigger button updates to `Dock Only`, then restored `Dock + Menu Bar`.
  - Toggled `Appearance Theme` across `Dark` and `Light` (returning to `System`), confirming the popover opens with all 4 option buttons in both themes. (Visual screenshot capture was not used in this headless session; UI structure and state transitions were verified via Accessibility / `System Events`.)

---

## 23. Settings Interaction Latency & SwiftUI Performance Audit (Phase 47.1.3, 2026-11-21)

### 23.1 Executive Summary

An evidence-based performance audit was performed across `SettingsView`, `AppSettings`, `AppLifecycleManager`, `ContentView`, `LocalConvertApp`, `MenuBarView`, and `DesignSystem` using Apple `xctrace` (`SwiftUI` template: `SwiftUIFilteredUpdates`, `Hitches`, `hitches-updates`, `hitches-renders`, `ProcessCPUUsage`, `time-sample`), `/usr/bin/sample` (1 ms callstacks), `vmmap`/`ps`, and a 5-repetition `System Events` automation suite across both **Debug** (`debug-deployment/LocalConvert.app`) and an isolated **Release** (`-O` build in `/tmp/lc_release_audit/LocalConvert.app`) without altering any production code.

Key findings:
1. **Why Light → System (when macOS is Dark) turns the top bar black first and the body later ("önce üst bar siyah oluyor sonra devamı"):** Two uncoordinated appearance pathways fire in separate commit phases. `OpaqueWindowChromeHost.applyOpaqueWindowChrome()` (`DesignSystem.swift:665-682`) synchronously sets `window.appearance = nil` (immediately repainting the AppKit `NSThemeFrame`/titlebar/toolbar in System Dark), while `.preferredColorScheme(settings.appearanceMode.colorScheme)` (`LocalConvertApp.swift:79`) plus `AppTheme.Colors.*` dynamic `NSColor` closures and a monolithic 10-section grouped `Form` (`SettingsView.swift:16-363`) trigger an `AttributeGraph` + `FormCell`/`Switch` cascade (**8,401** filtered updates, **`148.07 ms`** max `hitches-updates` frame commit, **`391.67 ms`** CoreAnimation hitch), delaying the detail body repaint behind the titlebar.
2. **Every setting change globally invalidates the app root:** `AppSettings.shared` is observed via `@ObservedObject` simultaneously by `LocalConvertApp` (`LocalConvertApp.swift:71`), `ContentView` (`ContentView.swift:6`), and `SettingsView` (`SettingsView.swift:5`). Toggling `Keep app running when all windows are closed` 10 times triggers **12** full `SettingsView.body` evaluations and **438** `SwiftUI::Switch.update` updates, while unconditionally calling `OpaqueWindowChromeHost.neutralizeBehindWindowVibrancy(in: themeFrame)` (`DesignSystem.swift:632-640`), walking the entire `NSWindow` AppKit view tree on every update.
3. **Application Visibility switching (`popover_modes`) triggers triple `objectWillChange`, duplicate `NSMenu` rebuilds, and synchronous Dock IPC:** `AppSettings.applicationVisibilityMode` setter emits up to 3 `objectWillChange` notifications, calls `MenuBarManager.updateVisibility` **twice** per toggle (`AppLifecycleManager.swift:72` + `SettingsView.swift:375`), and runs synchronous `NSApp.setActivationPolicy` / `NSApp.activate` IPC (`__mac_syscall`: 81–92 samples), causing **`645.05 ms`** max `hitches-updates` commit and **`308.33 ms`** max CoreAnimation hitch.
4. **GPU blur/material rendering is NOT the bottleneck:** Across all `xctrace` traces, `hitches-renders` averaged **1.78–2.41 ms** (`max 9.67 ms`). Slowness comes from **Main Thread SwiftUI AttributeGraph / Preference traversal (`find(_:key:filter:)` + `AG::Graph::UpdateStack::update()`) and AppKit `Form`/window/policy work**, even in `-O` **Release** builds.

### 23.2 Examined Components

- [LocalConvertApp.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/LocalConvertApp.swift) (`L71-L79`, `@ObservedObject private var settings = AppSettings.shared`, `.preferredColorScheme`)
- [ContentView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/ContentView.swift) (`L6-L18` `@ObservedObject`s, `.appOpaqueWindowChrome`, `L69-L94` `detailView`, `L99-L123` `SidebarView`)
- [DesignSystem.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Shared/DesignSystem.swift) (`L4-L55` `AppTheme.Colors`, `L618-L684` `OpaqueWindowChromeHost`, `L632-L640` `neutralizeBehindWindowVibrancy`, `L665-L682` `applyOpaqueWindowChrome`)
- [SettingsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/SettingsView.swift) (`L5-L7`, `L16-L363`, `L204`/`L213`, `L225`, `L295`, `L374-L384`, `L441-L623` popover controls)
- [AppSettings.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Settings/AppSettings.swift) (`L301-L418`, `L496-L502`)
- [AppLifecycleManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppLifecycleManager.swift) (`L59-L104`, `L184-L192`, `L224-L246`)
- [MenuBarView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/MenuBarView.swift) (`L93-L189`)
- [HistoryManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/History/HistoryManager.swift) (`L22-L25`, `L66-L80`)
- [UndoRedoCoordinator.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/UndoRedo/UndoRedoCoordinator.swift) (`L13-L32`, `L409-L411`)

### 23.3 Theme Switching Performance (`System → Light → Dark → System`)

- **Re-evaluated Views:** Changing `settings.appearanceMode` invalidates `LocalConvertApp.body` (entire `WindowGroup` + `.commands`), `ContentView.body` (`NavigationSplitView` + `SidebarView` + `detailView` + `toolbar`), `OpaqueWindowChromeHost.updateNSView`, and `SettingsView.body` (**9** evaluations in Debug `theme` trace, `max 4.899 ms`), triggering **8,401** SwiftUI filtered updates (**7,565** View Body Updates + **836** Representable Updates, including **760** `SwiftUI::Switch.update` calls across all 10 sections).
- **Exact Mechanism of the Two-Phase Visual Tear ("önce üst bar siyah oluyor sonra devamı"):**
  1. `OpaqueWindowChromeHost.applyOpaqueWindowChrome()` (`DesignSystem.swift:665-678`) sets `window.appearance = nil` (`System`) and `window.backgroundColor = AppTheme.Colors.workspaceNSColor` (`DesignSystem.swift:52-54`), plus `neutralizeBehindWindowVibrancy(in: themeFrame)`. AppKit's `NSThemeFrame` and `.windowToolbar` immediately adopt Dark Aqua and repaint the titlebar/toolbar black in Frame `T`.
  2. Simultaneously, `LocalConvertApp.swift:79` applies `.preferredColorScheme(settings.appearanceMode.colorScheme)` (`Light` → `nil`), invalidating SwiftUI's `EnvironmentValues.colorScheme` down through the 10-section grouped `Form` (`FormCell`, `Switch`, `PopUpButton`, `DesignLibrarySlider`, `PlatformTextFieldAdaptor`), whose AppKit/SwiftUI cells execute on the Main Thread via `AG::Graph::UpdateStack::update()` and `find(_:key:filter:)`, producing `hitches-updates` up to **`148.07 ms`** and CoreAnimation `hitches` up to **`391.67 ms`** (`avg 70.96 ms`). Thus the titlebar snaps Dark first while the Settings form content lags behind by one or more dropped frames.
- **No explicit `.animation(...)` / `withAnimation` conflict:** A codebase search confirmed `SettingsView`, `ContentView`, and `DesignSystem` define zero `.animation` or `withAnimation` modifiers on theme switching; the phased transition is purely desynchronized AppKit `window.appearance` vs SwiftUI `.preferredColorScheme` + heavy grouped `Form` commit latency.

### 23.4 Application Visibility Popover Performance

- **Open/Close Latency & Invalidations:** Opening/closing the popover 5 times produced only **2** `SettingsView.body` evaluations (`1.685 ms` total) — the popover itself does **not** trigger full Settings form rebuilds while opening/closing. However, `ApplicationVisibilityPopoverContent.body` ran **18** times across 5 open/close cycles (`~3.6` evaluations per cycle) because `.onAppear { focusedMode = selection }` (`SettingsView.swift:531-533`) triggers an extra focus-state pass immediately after open. `ApplicationVisibilityOptionRow.body` ran **40** times (`2.284 ms` total).
- **Material/Blur Cost vs CPU Commit Cost:** In `popover_open_close`, GPU render duration (`hitches-renders`) remained low at **`avg 1.775 ms` (`max 9.674 ms`)**, indicating `.regularMaterial` inside macOS `.popover` (even though `.popover` already supplies `NSPopover` material backdrop) is GPU-cheap on Apple Silicon `arm64`, though removing the redundant nested `.background(.regularMaterial)` (`SettingsView.swift:530`) avoids double backdrop compositing. In `popover_modes` (switching across the 4 modes), hitches rose sharply (`29` hitches, `max 308.33 ms`, `hitches-updates max 645.05 ms`) due to mode-change side effects rather than popover blur.
- **Keyboard Navigation & Accessibility Note:** In Release `popover_open_close`, 2/5 `Escape` key dismissals timed out because SwiftUI's `.onExitCommand` / `.onKeyPress` inside a `.buttonStyle(.plain)` popover relies on `_NSPopoverWindow` first-responder focus settling after open. In `popover_modes`, selecting `Dock Only` vs `Menu Bar Only` vs `Neither` vs `Dock + Menu Bar` triggered **42** `ApplicationVisibilitySelector.body`, **60** `ApplicationVisibilityPopoverContent.body`, **116** `ApplicationVisibilityOptionRow.body`, and **15** `SettingsView.body` updates (`12,968` total filtered updates).

### 23.5 Main Thread & Lifecycle Analysis

- **Redundant `AppLifecycleManager` / `MenuBarManager` invocations:** Changing `applicationVisibilityMode` (`AppSettings.swift:349-364`) mutates `@AppStorage` `showInDock` and `@AppStorage` `showMenuBarExtra`, calls explicit `objectWillChange.send()` (`L362`), and synchronously calls `AppLifecycleManager.shared.applyVisibilityPreferences(settings: self)` (`L363`), which calls `MenuBarManager.shared.updateVisibility(showInMenuBar:)` (`AppLifecycleManager.swift:72`) and rebuilds `NSMenu` (`MenuBarView.swift:138-189`). On the next SwiftUI render pass, `SettingsView.swift:374-376` `.onChange(of: settings.showMenuBarExtra)` fires and calls `MenuBarManager.shared.updateVisibility()` a **second** time, needlessly rebuilding `NSMenu` again. Notice `AppSettings.showInDock.didSet` and `showMenuBarExtra.didSet` already guard with `isUpdatingVisibilityMode`, so only the `SettingsView` `.onChange` is redundant when `applicationVisibilityMode` changes.
- **Blocking IPC on Dock Policy Changes:** `NSApp.setActivationPolicy(.regular <-> .accessory)` (`AppLifecycleManager.swift:85`) and `app.activate(ignoringOtherApps: true)` / `window.makeKeyAndOrderFront(nil)` (`L91-L92`) execute synchronous LaunchServices/WindowServer IPC on the Main Thread (`/usr/bin/sample`: `__mac_syscall` 92 samples Debug / 81 samples Release in `popover_modes`), driving `selectConfirm` latency to **`583.1–703.2 ms`** in Debug and **`hitches-updates` max `645.05 ms`**.
- **Unconditional `NSThemeFrame` Walk & Main-Thread Allocations:** `OpaqueWindowChromeHost.updateNSView` (`DesignSystem.swift:625-630`) runs on every `ContentView.body` update and unconditionally calls `neutralizeBehindWindowVibrancy(in: themeFrame)` (`L632-L640`), recursively visiting every `NSView` in the window even when neither `preferredColorScheme` nor the window changed. Additionally, `SettingsView.body` performs `NSImage(named: "AppIcon")` (`L295`), `ByteCountFormatter.string(...)` (`L225`), and inline `Set/sorted()` allocations (`L204`, `L213`) on every evaluation; `HistoryManager.init()` (`HistoryManager.swift:22-25, 66-80`) reads/decodes `history.json` synchronously on `@MainActor` upon first access. (Meanwhile, `UndoRedoCoordinator.currentRecoveryUsageBytes()` (`UndoRedoCoordinator.swift:409`) safely runs `await` off MainActor via `RecoveryArtifactManager` actor.)

### 23.6 SwiftUI View Invalidation Analysis

- **Three Root `@ObservedObject var settings = AppSettings.shared` Subscribers:** Because `LocalConvertApp` (`L71`), `ContentView` (`L6`), and `SettingsView` (`L5`) all observe the monolithic `AppSettings.shared` `ObservableObject` directly, mutating **any** setting (e.g., `keepAppOpenAfterConversion`) emits `objectWillChange` to all three levels.
- **`SettingsView` Monolithic 10-Section `Form`:** All 10 sections (`General`, `Output & Files`, `Notifications`, `Conversion Defaults`, `Performance`, `Jobs & History`, `Undo & Editing History`, `Privacy & Diagnostics`, `Keyboard Shortcuts`, `About`, `Reset Defaults`) live inside one `SettingsView.body` (`SettingsView.swift:16-363`). Combined with `@ObservedObject var settings`, `@ObservedObject var historyManager`, and `@ObservedObject private var undoCoordinator` at the top (`L5-L7`), toggling `Keep app running` 10 times caused **12** `SettingsView.body` evaluations and **7,634** filtered updates (**438** `Switch.update`, **120** `PopUpButton.body`, **120** `Picker.body`), even though only 1 `Toggle` row changed.
- **`sample` Main-Thread CPU Proof (Debug & Release):** In both unoptimized Debug and `-O` Release, the top non-idle Main Thread frames during `theme` switching were **`SwiftUICore find(_:key:filter:)`** (Debug: `174+66 = 240` samples; Release: `151+70 = 221` samples) and **`AG::Graph::UpdateStack::update()` + `propagate_dirty`** (Debug: `198` samples; Release: `174` samples), proving compiler `-O` does not eliminate the SwiftUI AttributeGraph / preference-lookup overhead of the monolithic tree.

### 23.7 Separation of GUI Automation Overhead vs Application Latency

| Layer | Measured Overhead (n=5) | Role in Benchmark |
|---|---|---|
| Naive recursive AX walk (`findFirst` depth 8–9) | `1,583.0–1,911.1 ms` per search | **Pure System Events bottleneck** (eliminated in final O(1) script) |
| Cold `zsh + osascript -l JavaScript` spawn | `avg 130.25 ms` (`124.21–140.48 ms`) | Automation process startup outside app |
| O(1) direct AX path read inside active JXA session | `10.32–15.17 ms` | Multi-step AppleEvent bridge cost |
| Single cached `AXButton.value()` IPC read | `1.76–2.08 ms` | Per-poll AX confirmation overhead |
| App Main-Thread / CoreAnimation commit (`hitches-updates`) | `max 148.07 ms` (theme), `143.73 ms` (popover), `159.44 ms` (keep), `645.05 ms` (modes) | **Actual in-process app UI latency** (from `xctrace`) |
| App CoreAnimation Display Hitch (`hitches`) | `max 391.67 ms` (theme), `350.00 ms` (popover/keep), `308.33 ms` (modes) | **Actual dropped-frame visual stutter in app** (from `xctrace`) |

*Agent tool overhead* (shell task dispatch, stdout capture, trace XML streaming export) runs out-of-process and is completely excluded from both the `xctrace` in-app timings and the JXA internal `CFAbsoluteTime` timings.

### 23.8 Performance Measurement Results (5 Repetitions)

#### A. End-to-End Interactive Response (Direct O(1) AX Timing, Excluding App Startup & Naive Tree Walks)

| Scenario | Metric | Debug (`debug-deployment/LocalConvert.app`) | Release (`/tmp/lc_release_audit/LocalConvert.app`) | Memory (`phys_footprint`) |
|---|---|---|---|---|
| **1. Theme (`System→Light→Dark→System`, n=15)** | Light `axConfirm` avg (max) | `280.7 ms` (`298.1 ms`) | `420.8 ms` (`923.4 ms`)* | Debug: `83.3 → 91.3 MB` |
| | Dark `axConfirm` avg (max) | `311.9 ms` (`340.7 ms`) | `624.3 ms` (`1,877.4 ms`)* | Release: `83.4 → 91.2 MB` |
| | System `axConfirm` avg (max) | `265.2 ms` (`273.9 ms`) | `257.7 ms` (`273.9 ms`)* | (`ps %CPU`: `56.2%` Dbg / `46.9%` Rel) |
| **2. Popover Open / Close (n=5)** | Open detect avg (max) | `94.9 ms` (`100.5 ms`) | `max 87.3 ms` (2/5 `Esc` timeouts) | Debug: `91.2 → 116.8 MB` (clean1: `89.7→101.5`) |
| | Close (`Esc`) detect avg (max) | `75.5 ms` (`80.1 ms`) | `max 98.8 ms` (focus/Esc race) | Release: `90.1 → 94.7 MB` |
| **3. Popover 4 Modes (`n=5×4=20`)** | `Dock Only` `selectConfirm` avg (max) | `589.0 ms` (`676.7 ms`)* | *Incomplete (AX child readiness race)* | Debug: `93.9 → 96.9 MB` |
| | `Menu Bar Only` `selectConfirm` avg (max) | `583.1 ms` (`616.6 ms`)* | *Incomplete (AX child readiness race)* | Release: `97.5 → 109.8 MB` |
| | `Neither` `selectConfirm` avg (max) | `658.6 ms` (`666.6 ms`)* | — | (`ps %CPU`: `39.2%`–`76.4%`) |
| | `Dock + Menu Bar` `selectConfirm` avg (max) | `703.2 ms` (`725.5 ms`)* | — | — |
| **4. Keep App Running Toggle (n=10)** | Confirm avg (max) | `103.9 ms` (`188.9 ms`) | `85.5 ms` (`93.4 ms`) | Debug: `96.2 → 96.4 MB` (`+0.2 MB`) |
| | Total AX press+confirm avg | `149.0 ms` | `125.9 ms` | Release: `97.4 → 97.3 MB` (`-0.1 MB`) |
| **5. Settings Scroll & Tab Nav (n=5)** | Scroll cycle (incl. 240 ms script wait) | `297.5 ms` | `293.3 ms` | Debug: `96.3 → 95.9 MB` |
| | `Settings → Convert` avg (max) | `133.8 ms` (`145.1 ms`) | `113.7 ms` (`124.2 ms`) | Release: `97.3 → 97.8 MB` |
| | `Convert → Settings` avg (max) | `216.6 ms` (`226.7 ms`) | `210.9 ms` (`304.6 ms`) | (`ps %CPU`: `48.6%` Dbg / `51.7%` Rel) |

*\*Note: Rows marked `*` (`Release theme` and `Debug popover_modes`) were recorded in the run with concurrent 8s `/usr/bin/sample` (`task_suspend` sampling); in the `--no-sample` run, `Debug theme` completed 15/15 without perturbation (`avg 285.9 ms`, `max 340.7 ms`), whereas `Release theme` and `Debug popover_modes` hit 1 iteration JXA menu/AX-attribute readiness error.*

#### B. `xctrace` (`SwiftUI` Template) Internal Metrics — Debug Build

| Scenario | Filtered SwiftUI Updates | View Body / Representable | Top LocalConvert Bodies | `hitches` Count / Max (Avg) | `hitches-updates` Max (Avg) | `hitches-renders` Max (Avg) | CPU Avg / Peak |
|---|---|---|---|---|---|---|---|
| `theme` (5×3) | `8,401` (`151.17 ms`) | `7,565` / `836` | `SettingsView` (`9`, `max 4.90 ms`), `ApplicationVisibilitySelector` (`2`) | `33` / **`391.67 ms`** (`70.96 ms`) | **`148.07 ms`** (`29.31 ms`) | `8.92 ms` (`2.30 ms`) | `51.45%` / `199.0%` |
| `popover_open_close` (5×) | `82,854` total (`363.73 ms`) | `2,980` Body (`0` Rep in filtered) | `SettingsView` (`2`), `PopoverContent` (`18`), `OptionRow` (`40`), `Selector` (`8`) | `4` / `350.00 ms` (`120.83 ms`) | `143.73 ms` (`49.03 ms`) | `9.67 ms` (`1.78 ms`) | `46.31%` / `137.0%` |
| `popover_modes` (5×4) | `12,968` (`187.26 ms`) | `12,002` / `966` | `SettingsView` (`15`), `Selector` (`42`), `PopoverContent` (`60`), `OptionRow` (`116`), `AppInfoBanner` (`5`) | `29` / **`308.33 ms`** (`62.64 ms`) | **`645.05 ms`** (`78.49 ms`) | `8.67 ms` (`2.24 ms`) | `61.20%` / `141.0%` |
| `keep_running` (5×2) | `7,634` (`96.37 ms`) | `3,437` / `579` | `SettingsView` (`12`, `max 0.89 ms`), `DropZoneView` (`1`), `Selector` (`1`) | `2` / `133.33 ms` | **`159.44 ms`** | `6.73 ms` (`2.41 ms`) | `49.32%` / `148.0%` |

- **Debug vs Release Comparison:** Release (`-O`) slightly improves simple leaf toggles (`Keep app running`: `103.9 → 85.5 ms`; `Settings → Convert`: `133.8 → 113.7 ms`), **but does not fix `Convert → Settings` (`216.6 ms` Debug vs `210.9 ms` Release), `theme` (`285.9 ms` Debug vs `257.7–624.3 ms` Release), or Main Thread `AttributeGraph` + `find(_:key:filter:)` stalls** (`240` samples Debug vs `221` samples Release). Memory footprint stayed bounded (`~82–117 MB`, `< +16 MB` peak delta, returning to `~95–98 MB`) with no sustained leak across 5 repetitions.

### 23.9 Root Cause Summary

1. **Desynchronized Appearance Pipeline (Cause of "Top Bar Black First, Rest Later"):** `OpaqueWindowChromeHost.applyOpaqueWindowChrome()` sets `window.appearance` immediately inside `updateNSView`, repainting AppKit titlebar/toolbar chrome before SwiftUI's `.preferredColorScheme` + dynamic `AppTheme.Colors` + 10-section `Form` finishes its `AttributeGraph` commit (`hitches-updates` up to `148 ms`, `hitches` up to `391 ms`).
2. **Global `@ObservedObject var settings = AppSettings.shared` Fan-Out + Unconditional Window Tree Walk:** Observing `AppSettings.shared` at `LocalConvertApp`, `ContentView`, and `SettingsView` invalidates the entire app scene and calls `neutralizeBehindWindowVibrancy(in: themeFrame)` across all window `NSView`s on **every** unrelated setting change.
3. **Triple `objectWillChange` + Double `MenuBarManager.updateVisibility` + Synchronous Dock IPC on Visibility Changes:** `AppSettings.applicationVisibilityMode` setter fires multiple `objectWillChange` pulses and re-triggers `MenuBarManager.updateVisibility` via both `AppLifecycleManager` and `SettingsView.onChange(of: settings.showMenuBarExtra)`.
4. **Monolithic 10-Section `SettingsView.body`:** Observing `AppSettings.shared`, `HistoryManager.shared`, and `UndoRedoCoordinator.shared` on a single 40+ control grouped `Form` forces `760–870` `Switch.update` and hundreds of `FormCell`/`PopUpButton`/`Picker` evaluations on small mutations.
5. **Minor Popover Focus/Backdrop Overhead:** `.onAppear { focusedMode = selection }` adds an extra popover evaluation cycle, `.background(.regularMaterial)` duplicates `NSPopover`'s native material, and `ApplicationVisibilityPopoverContent` focus doesn't reliably accept `Escape` on first frame in Release unless clicked/focused.

### 23.10 Prioritized Fix Strategy (Proposed — Awaiting Approval)

#### P0 (Critical Blocking / Visual Desync)
- **P0-1 — Synchronize Appearance Switching & Cache `OpaqueWindowChromeHost` Work**
  - *Location:* `LocalConvert/Features/Shared/DesignSystem.swift` (`L618-L684`), `LocalConvert/Features/Home/ContentView.swift` (`L6, L18`), `LocalConvert/App/LocalConvertApp.swift` (`L71, L79`)
  - *Root Cause:* `OpaqueWindowChromeHost.updateNSView` unconditionally mutates `window.appearance`, `window.backgroundColor`, and walks every `NSView` in `NSThemeFrame` on every `ContentView.body` evaluation; meanwhile `LocalConvertApp.preferredColorScheme` and `NSWindow.appearance` update asynchronously across frames, turning the titlebar Dark before the `Form` body.
  - *Evidence:* User reproduction ("light → system dark: önce üst bar siyah oluyor sonra devamı"); `theme` trace `33` hitches (`max 391.67 ms`), `hitches-updates max 148.07 ms`, `240` `find(_:key:filter:)` samples.
  - *User Impact:* Visible two-phase flash/tear and frame stutter when switching themes.
  - *Proposed Fix:* (1) Track last applied `preferredColorScheme` + `window` identity in `OpaqueChromeSentinelView` so `applyOpaqueWindowChrome()` is skipped completely unless appearance or window changed; neutralize vibrancy once per window/theme transition rather than every SwiftUI update. (2) Keep `.preferredColorScheme` only at the root OR drive `NSApp.appearance` / `window.appearance` atomically inside a coalesced `CATransaction` / single root appearance wrapper (`AppearanceStore` observing only `appearanceMode`) without triggering `LocalConvertApp` and `ContentView` full-tree rebuilds.
  - *Regression Risk:* Low (pure chrome/appearance state scoping; verify `.aqua` / `.darkAqua` / `nil` window appearance and opaque background tests).
  - *Expected Benefit:* Eliminates two-frame titlebar/content color tear and stops `neutralizeBehindWindowVibrancy` tree walks on non-theme updates.

#### P1 (Significant & Reproducible UI Latency)
- **P1-1 — Split `AppSettings` Observation / Isolate Sub-Observable Stores (`Appearance`, `Visibility`, `Notifications`, `Undo`)**
  - *Location:* `LocalConvert/App/LocalConvertApp.swift` (`L71`), `LocalConvert/Features/Home/ContentView.swift` (`L6`), `LocalConvert/Features/Home/SettingsView.swift` (`L5-L7`), `LocalConvert/Core/Settings/AppSettings.swift` (`L301-L637`)
  - *Root Cause:* Three top-level views observe all 28 `@AppStorage` properties of `AppSettings.shared`; any mutation invalidates `LocalConvertApp`, `ContentView`, `SidebarView`, and all 10 sections of `SettingsView`.
  - *Evidence:* `keep_running` trace: 10 checkbox clicks → `12` `SettingsView.body`, `438` `Switch.update`, `7,634` filtered updates (`103.9 ms` Dbg / `85.5 ms` Rel).
  - *User Impact:* Sluggish toggles, sliders, and pickers across the entire Settings screen.
  - *Proposed Fix:* Introduce lightweight focused slice observables or `@Observable`/fine-grained selectors (e.g., `ContentView` and `LocalConvertApp` observe only `appearanceMode`, not all of `AppSettings`; break `SettingsView` sections into isolated child `View` structs, each taking only its own relevant binding/sub-model).
  - *Regression Risk:* Low–Medium (must preserve existing `AppSettings.shared` API used by tests and engines).
  - *Expected Benefit:* Cuts unrelated `SettingsView` / `ContentView` / `Switch` invalidations by ~80–90% on toggles and visibility changes.

- **P1-2 — Coalesce `applicationVisibilityMode` Notifications & Remove Duplicate `MenuBarManager` Update**
  - *Location:* `LocalConvert/Core/Settings/AppSettings.swift` (`L314-L365`), `LocalConvert/Features/Home/SettingsView.swift` (`L374-L376`), `LocalConvert/App/AppLifecycleManager.swift` (`L59-L104`)
  - *Root Cause:* `applicationVisibilityMode.set` emits multiple `objectWillChange` pulses and invokes `AppLifecycleManager.applyVisibilityPreferences` (calling `MenuBarManager.updateVisibility`), after which `SettingsView.onChange(of: settings.showMenuBarExtra)` calls `MenuBarManager.updateVisibility()` a second time, rebuilding `NSMenu`. Also `NSApp.setActivationPolicy` runs synchronously on the Main Thread inside `applyVisibilityPreferences`.
  - *Evidence:* `popover_modes` trace: `12,968` filtered updates, `29` hitches (`max 308.33 ms`), `hitches-updates` `max 645.05 ms`, `selectConfirm 583–703 ms`, `__mac_syscall` 81–92 samples.
  - *User Impact:* Noticeable ~0.6s stall when switching visibility modes, especially `Dock + Menu Bar` / `Menu Bar Only`.
  - *Proposed Fix:* Remove the redundant `.onChange(of: settings.showMenuBarExtra)` in `SettingsView.swift:374-376` (since `AppSettings` `didSet` and `applicationVisibilityMode.set` already call `AppLifecycleManager.applyVisibilityPreferences`); ensure `applicationVisibilityMode.set` fires `objectWillChange.send()` only once after setting underlying defaults; schedule `NSApp.setActivationPolicy` on next runloop turn after popover dismissal animation begins so popover closes crisply before Dock IPC.
  - *Regression Risk:* Low (verify all Phase 47 lifecycle & menu bar tests pass).
  - *Expected Benefit:* Eliminates duplicate `NSMenu` rebuilds, cuts visibility-switch `objectWillChange` fan-out to 1, and lets the popover dismiss smoothly before Dock IPC.

#### P2 (Unnecessary View Invalidation & Render Cost)
- **P2-1 — Modularize Monolithic `SettingsView` Sections into Dedicated Child Views**
  - *Location:* `LocalConvert/Features/Home/SettingsView.swift` (`L16-L363`, `L204`, `L213`, `L225`, `L295`)
  - *Root Cause:* All 10 `Section`s plus `NSImage(named: "AppIcon")`, `ByteCountFormatter.string`, and inline `Set/sorted()` live inside `SettingsView.body`, with `historyManager` and `undoCoordinator` observed at root scope.
  - *Evidence:* `To Settings` navigation takes `~211–217 ms` (`max 304.6 ms` Release); every unrelated setting change re-evaluates `SettingsView.body` (`9–15` times in short traces) and `760–870` `Switch.update`s.
  - *User Impact:* Delayed tab switch into Settings and heavy `Form` diffing on any edit.
  - *Proposed Fix:* Extract per-section child views (`GeneralSettingsSection`, `JobsHistorySettingsSection` owning `@ObservedObject historyManager`, `UndoSettingsSection` owning `undoCoordinator`, `AboutSettingsSection` with static/cached `AppIcon` `NSImage` and precomputed preset arrays).
  - *Regression Risk:* Low (pure SwiftUI view decomposition; preserve accessibility labels).
  - *Expected Benefit:* Prevents `HistoryManager` or `UndoRedoCoordinator` updates from invalidating `General` / `Conversion` / `About` sections, and avoids repeated AppIcon/formatter work.

#### P3 (Visual Polish & Minor Popover Optimization)
- **P3-1 — Remove Redundant `.regularMaterial` Inside `.popover` & Clean Up Initial Popover Focus**
  - *Location:* `LocalConvert/Features/Home/SettingsView.swift` (`L516-L553`)
  - *Root Cause:* `.background(.regularMaterial)` (`L530`) layers a second `CABackdropLayer` inside macOS's native `NSPopover` material background; `.onAppear { focusedMode = selection }` (`L531-L533`) causes a second immediate `ApplicationVisibilityPopoverContent.body` pass on every open (`18` evaluations in 5 open/close cycles), and `Escape` occasionally misses focus in Release.
  - *Evidence:* `popover_open_close` trace: `18` `ApplicationVisibilityPopoverContent.body` evaluations for 5 opens; 2/5 `Escape` misses in Release `popover_open_close`.
  - *User Impact:* Minor double evaluation on popover open and occasional `Escape` key miss without prior click/focus.
  - *Proposed Fix:* Remove `.background(.regularMaterial)` (relying on native `.popover` chrome) and evaluate whether `focusedMode` should only activate on keyboard navigation or be initialized cleanly without double pass; verify `Escape` handling across Dark/Light/System.
  - *Regression Risk:* Low.
  - *Expected Benefit:* Halves `ApplicationVisibilityPopoverContent.body` passes per open and removes nested backdrop blur compositing.

### 23.11 Focused Test Verification

- Ran `xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lc_phase4713_test_dd -only-testing:LocalConvertTests/Phase47LifecycleAndUXTests`:
  - **10/10 tests in 1 suite passed** (`0.236s`, `** TEST SUCCEEDED **`).
- Verified `com.localconvert.app` `UserDefaults` restored cleanly to defaults (`appearanceMode = System`, `applicationVisibilityMode = both`, `keepAppOpenAfterConversion = 1`).

### 23.12 Code Modification Status

- **Zero production or test source files were modified** in Phase 47.1.3 (only this audit report section `§23` was appended to `docs/PHASE47_FINAL_REPORT.md`, plus out-of-repo scratch scripts/traces in `/tmp` and agent scratch storage). Ready for owner review and approval before implementing P0–P3 fixes.

---

## 24. Phase 47.1.4 — Comprehensive UI/UX & SwiftUI/AppKit Optimization

### 24.1 Executive Summary

Phase 47.1.4 autonomously executed Stages 0 through 12 to resolve all P0–P3 performance, visual-coherence, observation, lifecycle, accessibility, and code-quality findings identified during the Phase 47.1.3 `xctrace` audit and the Stage 0 full-application UI inventory (`docs/PHASE47_1_4_AUDIT.md`).

Key outcomes:
- **P0 Theme Transition Synchronization & Window Chrome Caching:** Eliminated redundant `NSThemeFrame` tree scans and two-phase (`Light → System (Dark)`) titlebar-first flashing in `OpaqueWindowChromeHost` (`DesignSystem.swift`) via window-identity/scheme/appearance change gating, `CATransaction.setDisableActions(true)`, and `viewDidChangeEffectiveAppearance()`.
- **P1 Lifecycle, MenuBar & Observation Isolation:** Coalesced `AppSettings.applicationVisibilityMode` mutations, added monotonic `visibilityTransitionGeneration` and `@Published` equality guards in `AppLifecycleManager`, added status-signature/icon caching (`menuRebuildCount`, `lastRenderedStatusSignature`, `lastAppliedIconIsConverting`) in `MenuBarManager`, removed `@ObservedObject private var settings = AppSettings.shared` from `LocalConvertApp`, `ContentView`, and `EditingHistoryView` in favor of targeted `@AppStorage` bindings, and forwarded `conversionManager.objectWillChange` + `conversionQueue.objectWillChange` through `AppState`.
- **P2 `SettingsView` Modularization, Caching & Accessibility:** Refactored the monolithic 10-section `SettingsView` into 11 isolated section views (`GeneralSettingsSection` through `ResetDefaultsSettingsSection`), scoping `HistoryManager.shared` to `JobsHistorySettingsSection` and `UndoRedoCoordinator.shared` to `UndoEditingHistorySettingsSection`, caching `DroppedFile` filesystem metadata (`fileSize`, `formattedFileSize`, `availableOutputFormats`), stabilizing `JobsCenterView` batch order (`orderedBatchIDs`), adding accessibility labels to segmented filter pickers, and resolving all deprecated `.onChange` and Swift 6 `#ActorIsolatedCall` warnings (`0` warnings in build).
- **P3 Custom Popover Micro-Interactions:** Removed redundant nested `.background(.regularMaterial)` and `.onAppear` double evaluation from `ApplicationVisibilityPopoverContent`, and added `.return`/`.space` key press activation and `isKeyboardFocused` visual feedback on `ApplicationVisibilityOptionRow`.
- **Measured `xctrace` & Full Regression Proof:** Reduced `keep_running` `SwiftUIFilteredUpdates` per toggle cycle by **`89.9%`** (`~1,526.8 → 154` body updates, `0` representable updates), eliminated redundant `Switch.update` representable evaluations (`820 → 0`), cut `keep_running` max hitch duration by **`69.1%`** (`189.03 ms → 58.333 ms`) and max update duration by **`75.1%`** (`76.59 ms → 19.055 ms`), reduced `theme` filtered updates per cycle by **`76.8%`** (`~3,179 → 737`), and passed **`602/602` tests across `77` suites (`0` failures, `0` skipped)**.

---

### 24.2 Complete UI Surface Inventory

| Surface / Feature Area | Primary Source Files | Verification Level |
|---|---|---|
| **App Scene & Menu Commands** | `LocalConvert/App/LocalConvertApp.swift`, `LocalConvert/App/AppLifecycleManager.swift` | Implemented + Automatically Tested + Live GUI Verified |
| **Root Window, Sidebar & Chrome** | `LocalConvert/Features/Home/ContentView.swift`, `LocalConvert/Features/Shared/DesignSystem.swift` | Implemented + Automatically Tested + Live GUI / `xctrace` Verified |
| **Convert — Empty State & Drop Zone** | `LocalConvert/Features/Conversion/DropZoneView.swift`, `LocalConvert/Features/Home/SupportedFormatsView.swift` | Source-Inspected + Live GUI / Full Regression Tested |
| **Convert — Queue, Rows & Options** | `LocalConvert/Features/Conversion/FileListView.swift`, `LocalConvert/Features/Conversion/FileRowView.swift`, `LocalConvert/Features/Conversion/FileOptionsView.swift`, `LocalConvert/Features/Conversion/ImageOptimizationView.swift`, `LocalConvert/App/AppState.swift` | Implemented + Automatically Tested |
| **Jobs Center & Error Details** | `LocalConvert/Features/Jobs/JobsCenterView.swift`, `LocalConvert/Features/Jobs/JobsSummaryHeaderView.swift`, `LocalConvert/Features/Jobs/BatchJobGroupView.swift`, `LocalConvert/Features/Jobs/JobRowView.swift`, `LocalConvert/Features/Jobs/ErrorDetailsSheet.swift` | Implemented + Automatically Tested |
| **Settings & Custom Visibility Popover** | `LocalConvert/Features/Home/SettingsView.swift`, `LocalConvert/Core/Settings/AppSettings.swift`, `LocalConvert/Features/Home/LicensesSheetView.swift` | Implemented + Automatically Tested + Live GUI / `xctrace` Verified |
| **History & Non-Destructive Editing History** | `LocalConvert/Features/History/HistoryView.swift`, `LocalConvert/Features/History/EditingHistoryView.swift`, `LocalConvert/Core/History/HistoryManager.swift`, `LocalConvert/Core/UndoRedo/UndoRedoCoordinator.swift` | Implemented + Full Regression Tested |
| **Presets & Metadata Inspector** | `LocalConvert/Features/Presets/PresetManagerView.swift`, `LocalConvert/Features/Presets/PresetEditView.swift`, `LocalConvert/Features/Metadata/MetadataView.swift`, `LocalConvert/Features/Metadata/MetadataFieldView.swift`, `LocalConvert/Features/Metadata/ArtworkEditorView.swift` | Source-Inspected + Full Regression Tested |
| **PDF, Audio & Image Toolboxes** | `LocalConvert/Features/PDFToolbox/PDFToolboxView.swift`, `LocalConvert/Features/PDFToolbox/PDFCompressOptionsView.swift`, `LocalConvert/Features/AudioToolbox/AudioToolboxView.swift`, `LocalConvert/Features/AudioEditor/AudioEditorRootView.swift`, `LocalConvert/Features/ImageToolbox/ImageToolboxView.swift` | Implemented + Full Regression Tested |
| **Menu Bar Extra & Notifications** | `LocalConvert/Features/Home/MenuBarView.swift`, `LocalConvert/Core/Notifications/AppNotificationManager.swift` | Implemented + Automatically Tested + Live GUI Verified |

---

### 24.3 Prioritized Issue List (P0 / P1 / P2 / P3) & Root Causes

1. **P0-1 (`DesignSystem.swift`):** `OpaqueWindowChromeHost.updateNSView` ran on every `ContentView.body` evaluation without caching window identity, `preferredColorScheme`, or effective `NSAppearance.Name`, recursively walking `NSThemeFrame` via `neutralizeBehindWindowVibrancy(in:)` and mutating `window.appearance` without disabling Core Animation actions (`CATransaction.setDisableActions(true)`). Switching `Light → System` when macOS was Dark flipped the AppKit titlebar (`NSThemeFrame`) immediately while SwiftUI's form took `148–391 ms` to commit.
2. **P1-1 (`AppState.swift`):** `AppState.setupObservation()` forwarded `imageToolboxStore` and `pdfToolboxStore` changes to `AppState.objectWillChange`, but did not forward `conversionManager.objectWillChange` or `conversionQueue.objectWillChange`, leaving views that only observe `@EnvironmentObject var appState: AppState` (`JobsCenterView`, `JobsSummaryHeaderView`, `JobRowView`, `BatchJobGroupView`, `FileListView`, `FileRowView`, `SidebarView`) and `MenuBarManager.shared.updateStatus()` without automatic invalidation on job progress/removal mutations.
3. **P1-2 (`AppSettings.swift`, `AppLifecycleManager.swift`, `MenuBarView.swift`, `SettingsView.swift`):** `AppSettings.applicationVisibilityMode.set` unconditionally mutated both `@AppStorage` properties, called `objectWillChange.send()`, and invoked `AppLifecycleManager.shared.applyVisibilityPreferences`, while `SettingsView` also had a duplicate `.onChange(of: settings.showMenuBarExtra)` calling `MenuBarManager.shared.updateVisibility()`, and `MenuBarManager` rebuilt its entire `NSMenu` even when status and visibility were unchanged.
4. **P1-3 (`LocalConvertApp.swift`, `ContentView.swift`, `EditingHistoryView.swift`):** Observed the global `AppSettings.shared` `ObservableObject` even though `LocalConvertApp` and `ContentView` only read `appearanceMode` and `EditingHistoryView` only reads `recoveryArtifactStorageLimitMB`, causing every non-appearance toggle/picker edit in Settings to invalidate the root scene and main window hierarchy.
5. **P2-1 (`SettingsView.swift`):** All 10 Settings sections lived inside a single monolithic `SettingsView.body` that observed `AppSettings.shared`, `HistoryManager.shared`, and `UndoRedoCoordinator.shared` at the top level and loaded `NSImage(named: "AppIcon")` inline.
6. **P2-2 (`JobsCenterView.swift`):** `batchGroupedSections` iterated over `batchDict: [UUID: [ConversionJob]]` directly, yielding non-deterministic hash iteration order across view renders.
7. **P2-3 (`AppState.swift`, `PDFCompressOptionsView.swift`):** `DroppedFile.fileSize`, `formattedFileSize`, and `availableOutputFormats` were computed properties executing `FileManager.default.attributesOfItem(atPath:)`, `ByteCountFormatter`, and array sorting on every `FileRowView.body` evaluation.
8. **P2-4 (`SettingsView.swift`, `PDFCompressOptionsView.swift`, `AppNotificationManager.swift`):** Used deprecated 1-parameter `.onChange(of:perform:)` closures in `SettingsView.swift` (4 call sites) and `PDFCompressOptionsView.swift` (7 call sites), and called `@MainActor`-isolated `self?.requestAuthorization()` from a non-isolated `UNUserNotificationCenter.getNotificationSettings` completion handler in `AppNotificationManager.swift:83` (`[#ActorIsolatedCall]`).
9. **P2-5 (`JobsSummaryHeaderView.swift`, `HistoryView.swift`):** Segmented filter `Picker` controls used `.labelsHidden()` without explicit `.accessibilityLabel(...)` modifiers.
10. **P3-1 & P3-2 (`SettingsView.swift`):** `ApplicationVisibilityPopoverContent` applied a redundant nested `.background(.regularMaterial)` inside `NSPopover` and mutated `focusedMode = selection` inside `.onAppear` (triggering an immediate second body evaluation on open), and lacked `.return`/`.space` key press activation and keyboard-focus highlight on `ApplicationVisibilityOptionRow`.

---

### 24.4 Architectural & File-by-File Changes Implemented

- **[DesignSystem.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Shared/DesignSystem.swift) (`L616-L746`):**
  - Made `OpaqueWindowChromeHost` and `OpaqueChromeSentinelView` `internal` so their caching invariants are directly unit-testable.
  - Added state tracking on `OpaqueChromeSentinelView`: `appliedWindowID: ObjectIdentifier?`, `lastAppliedScheme: ColorScheme?`, `lastEffectiveAppearanceName: NSAppearance.Name?`, `hasAppliedInitialChrome: Bool`, `applyCount: Int`, and `vibrancyNeutralizationCount: Int`.
  - Short-circuited `applyOpaqueWindowChrome()` when `hasAppliedInitialChrome && !force && appliedWindowID == windowID && lastAppliedScheme == preferredColorScheme && lastEffectiveAppearanceName == effectiveName`.
  - Wrapped `window.appearance`, `window.isOpaque = true`, `window.backgroundColor = targetBackgroundColor(...)`, `neutralizeBehindWindowVibrancy(in:)`, and `window.contentView?.needsDisplay = true` in `CATransaction.begin(); CATransaction.setDisableActions(true); ... CATransaction.commit()`.
  - Overrode `viewDidChangeEffectiveAppearance()` to synchronize chrome when macOS switches system appearance while `preferredColorScheme == nil`.
- **[AppSettings.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Settings/AppSettings.swift) (`L344-L392`):**
  - Updated `applicationVisibilityMode.set` to compute `dockChanged` and `menuChanged`, mutate `@AppStorage` properties only when their boolean values actually change, emit `objectWillChange.send()` only if neither `@AppStorage` property already emitted it, and skip `AppLifecycleManager.shared.applyVisibilityPreferences` when the combination is already active.
- **[AppLifecycleManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppLifecycleManager.swift) (`L26-L31`, `L59-L86`, `L190-L207`):**
  - Added `private(set) var visibilityTransitionGeneration: UInt64 = 0`.
  - Guarded `@Published` property assignments (`currentCombination`, `appliedActivationPolicy`, `isMainWindowMiniaturized`, `isMainWindowVisible`) with `!=` checks to eliminate redundant `objectWillChange` notifications.
- **[MenuBarView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/MenuBarView.swift) (`L74-L185`):**
  - Added `private(set) var menuRebuildCount: Int = 0`, `lastRenderedStatusSignature: String?`, and `lastAppliedIconIsConverting: Bool?` on `MenuBarManager` so `updateVisibility()` and `updateStatus()` only rebuild the `NSMenu` or update the `NSStatusBarButton` image when visibility or conversion status signature actually changes.
- **[LocalConvertApp.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/LocalConvertApp.swift) (`L67-L90`), [ContentView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/ContentView.swift) (`L4-L24`), [EditingHistoryView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/History/EditingHistoryView.swift) (`L16-L18`, `L164-L170`):**
  - Replaced `@ObservedObject private var settings = AppSettings.shared` with `@AppStorage("settings.appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue` in `LocalConvertApp` and `ContentView`, and `@AppStorage("settings.recoveryArtifactStorageLimitMB")` in `EditingHistoryView`.
- **[SettingsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Home/SettingsView.swift) (`L4-L880`):**
  - Modularized `SettingsView` into 11 independent section views: `GeneralSettingsSection`, `OutputFilesSettingsSection`, `NotificationsSettingsSection`, `ConversionDefaultsSettingsSection`, `PerformanceSettingsSection`, `JobsHistorySettingsSection`, `UndoEditingHistorySettingsSection`, `PrivacyDiagnosticsSettingsSection`, `KeyboardShortcutsSettingsSection`, `AboutSettingsSection`, and `ResetDefaultsSettingsSection`.
  - Scoped `@ObservedObject private var historyManager = HistoryManager.shared` to `JobsHistorySettingsSection` and `@ObservedObject private var undoCoordinator = UndoRedoCoordinator.shared` to `UndoEditingHistorySettingsSection`.
  - Cached `private static let cachedAppIcon: NSImage? = NSImage(named: "AppIcon")` in `AboutSettingsSection`.
  - Removed the duplicate `.onChange(of: settings.showMenuBarExtra)` modifier and updated the remaining `.onChange` modifiers to macOS 15 2-parameter closures.
  - Optimized `ApplicationVisibilityPopoverContent` and `ApplicationVisibilityOptionRow`: removed nested `.background(.regularMaterial)` and `.onAppear` double mutation, added `.onKeyPress(.return)` / `.onKeyPress(.space)`, and added `isKeyboardFocused` border/fill styling.
- **[AppState.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/App/AppState.swift) (`L8-L88`, `L228-L265`):**
  - Converted `DroppedFile.fileSize`, `formattedFileSize`, and `availableOutputFormats` into cached `let` properties computed once in `DroppedFile.init` via a static `ByteCountFormatter`.
  - Subscribed `AppState.setupObservation()` to `conversionManager.objectWillChange` and `conversionQueue.objectWillChange`, forwarding to `self.objectWillChange.send()` and calling `MenuBarManager.shared.updateStatus()` when `conversionManager.isConverting` is true.
- **[JobsCenterView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Jobs/JobsCenterView.swift) (`L26-L54`), [JobsSummaryHeaderView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/Jobs/JobsSummaryHeaderView.swift) (`L92-L102`), [HistoryView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/History/HistoryView.swift) (`L108-L117`), [PDFCompressOptionsView.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Features/PDFToolbox/PDFCompressOptionsView.swift) (`L7-L110`), [AppNotificationManager.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvert/Core/Notifications/AppNotificationManager.swift) (`L81-L87`):**
  - Preserved deterministic batch insertion order via `orderedBatchIDs` in `JobsCenterView`.
  - Added `.accessibilityLabel("Filter jobs by status")` in `JobsSummaryHeaderView` and `.accessibilityLabel("Filter history by category")` in `HistoryView`.
  - Used cached `f.fileSize` and updated 7 `.onChange` modifiers to 2-parameter syntax in `PDFCompressOptionsView`.
  - Wrapped `self?.requestAuthorization()` in `Task { @MainActor [weak self] in self?.requestAuthorization() }` in `AppNotificationManager`.
- **[Phase47LifecycleAndUXTests.swift](file:///Users/cancan/Desktop/LocalConvert/LocalConvertTests/Phase47LifecycleAndUXTests.swift) (`L507-L645`):**
  - Added 2 comprehensive regression tests covering Stage 1 (`OpaqueWindowChromeHost` window identity/appearance caching and vibrancy scan skipping) and Stages 2–7 (rapid visibility mode cycling, idempotent `MenuBarManager` rebuild count, `DroppedFile` cached properties, and `AppState` forwarding of `ConversionManager` mutations).

---

### 24.5 Detailed Analysis of Theme Transition Behavior (`OpaqueWindowChromeHost`), `AppSettings` Observation, `SettingsView` Restructuring, Application Visibility Lifecycle & Custom Popover

1. **Theme Transition Behavior (`OpaqueWindowChromeHost`):**
   - Previously, `OpaqueWindowChromeHost.updateNSView` ran on every `ContentView` update and mutated `window.appearance` and walked `NSThemeFrame` without transaction synchronization.
   - In Phase 47.1.4, `OpaqueChromeSentinelView.applyOpaqueWindowChrome(preferredColorScheme:force:)` checks `(appliedWindowID, lastAppliedScheme, lastEffectiveAppearanceName)`. When unchanged, `applyCount` and `vibrancyNeutralizationCount` do not increment (`0` redundant `NSThemeFrame` walks). When a theme transition occurs (`System → Light → Dark → System`), all AppKit window chrome mutations (`window.appearance`, `window.isOpaque`, `window.backgroundColor`, `neutralizeBehindWindowVibrancy(in:)`, `contentView.needsDisplay`) execute inside a single `CATransaction` with `CATransaction.setDisableActions(true)`, synchronizing the titlebar/toolbar background with the SwiftUI content update.
2. **`AppSettings` Observation Isolation & `SettingsView` Restructuring:**
   - By moving `LocalConvertApp` and `ContentView` from `@ObservedObject private var settings = AppSettings.shared` to `@AppStorage("settings.appearanceMode")`, toggling non-appearance settings (such as `Keep app running when all windows are closed`) no longer invalidates the app root or main window.
   - By splitting `SettingsView` into 11 isolated section structs, toggling `Keep app running when all windows are closed` inside `GeneralSettingsSection` reduced total `SwiftUIFilteredUpdates` per toggle cycle from **`~1,526.8` (`7,634` over 5 reps)** down to **`154` (`1.224 ms` total SwiftUI CPU, `-89.9%`)**, and reduced `Switch.update` representable updates from **`820` (`67.92 ms`)** down to **`0` (`-100%`)**.
3. **Application Visibility & MenuBar Lifecycle + Custom Popover:**
   - Removing the duplicate `.onChange(of: settings.showMenuBarExtra)` in `SettingsView`, guarding `AppSettings.applicationVisibilityMode.set` against no-op writes, and caching `lastRenderedStatusSignature` in `MenuBarManager` ensure each visibility transition updates `NSApp.setActivationPolicy` and `NSStatusItem` exactly once.
   - Removing the nested `.background(.regularMaterial)` and `.onAppear { focusedMode = selection }` from `ApplicationVisibilityPopoverContent` eliminated the double-body pass on popover presentation and reduced 4-mode cycling (`selectConfirmMs`) from `624.53 ms` avg (`681.55 ms` p95) to `594.61 ms` avg (`665.68 ms` p95).

---

### 24.6 Before / After Performance Comparison Table (`xctrace` & 5-Repetition Benchmarks)

| Scenario / Metric | Phase 47.1.3 Baseline | Phase 47.1.4 Debug | Phase 47.1.4 Release | Measured Improvement |
|---|---|---|---|---|
| **`keep_running` `SwiftUIFilteredUpdates` / rep** | `~1,526.8` (`7,634` / 5 reps) | `154` (`1.224 ms` total) | N/A (`xctrace` on Debug) | **`-89.9%` view updates** |
| **`keep_running` `Switch.update` (`Representable Updates`)** | `820` (`67.92 ms`) | `0` (`0.000 ms`) | N/A | **`-100%` redundant `Switch.update` calls** |
| **`keep_running` Max Hitch / Max Update Duration** | `189.03 ms` / `76.59 ms` | `58.333 ms` / `19.055 ms` | N/A | **`-69.1%` max hitch, `-75.1%` max update** |
| **`theme` `SwiftUIFilteredUpdates` / rep** | `~3,179.0` (`15,895` / 5 reps) | `737` (`5.680 ms` total) | N/A | **`-76.8%` view updates** |
| **`theme` `axConfirmWaitMs` (`avg` / `med` / `p95`, `n=15`)** | `348.59` / `329.75` / `459.46 ms` | `332.29` / `326.00` / `395.37 ms` | `319.47` / `307.34` / `368.15 ms` | **`-13.9%` Debug p95, `-19.9%` Release p95** |
| **`theme` `totalAutomationMs` (`avg` / `med` / `p95`, `n=15`)** | `555.02` / `535.91` / `662.30 ms` | `534.17` / `529.79` / `600.17 ms` | `521.79` / `519.63` / `558.66 ms` | **`-9.4%` Debug p95, `-15.6%` Release p95** |
| **`popover_open_close` `openDetectMs` (`avg` / `med` / `p95`, `n=5`)** | `82.34` / `81.82` / `89.38 ms` | `84.03` / `83.81` / `91.05 ms` | `84.13` / `83.83` / `90.47 ms` | Native `NSPopover` spring baseline (`~84 ms`) |
| **`popover_open_close` `closeDetectMs` (`avg` / `med` / `p95`, `n=5`)** | `66.15` / `65.94` / `69.08 ms` | `68.34` / `66.34` / `72.83 ms` | `66.29` / `64.25` / `73.04 ms` | Native `NSPopover` dismiss baseline (`~66 ms`) |
| **`popover_modes` `selectConfirmMs` (`avg` / `med` / `p95`, `n=20`)** | `624.53` / `616.05` / `681.55 ms` | `594.61` / `600.32` / `665.68 ms` | `615.95` / `617.53` / `697.56 ms` | **`-4.8%` (`-29.92 ms`) Debug avg** |
| **`popover_modes` `totalStepMs` (`avg` / `med` / `p95`, `n=20`)** | `2385.56` / `2385.80` / `2499.04 ms` | `2318.56` / `2330.46` / `2403.97 ms` | `2392.19` / `2420.89` / `2470.72 ms` | **`-67.00 ms` avg, `-95.07 ms` p95** |
| **`keep_running` `confirmMs` (`avg` / `med` / `p95`, `n=10`)** | `87.35` / `88.78` / `93.31 ms` | `85.56` / `86.87` / `91.47 ms` | `85.24` / `83.95` / `94.96 ms` | **`-2.0%` avg (`-5.4%` Release median)** |
| **`settings_nav` `totalNavCycleMs` (`avg` / `med` / `p95`, `n=5`)** | `778.10` / `779.13` / `787.05 ms` | `768.02` / `768.69` / `787.94 ms` | `771.73` / `781.48` / `784.77 ms` | **`-1.3%` (`-10.08 ms`) avg** |
| **Memory Footprint (`phys_footprint_mb` start → end)** | `67.1 MB → 95.3 MB` | `69.3 MB → 94.4 MB` | `70.7 MB → 83.3 MB` | **Bounded (`83.3 MB` Release, `94.4 MB` Debug); `0` leaks** |

---

### 24.7 Automated Test Results, Live GUI Verification & Build Deployment

1. **Automated Test Execution:**
   - **Focused Suite Run:** `xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lc_phase4713_test_dd -only-testing:LocalConvertTests/Phase47LifecycleAndUXTests -only-testing:LocalConvertTests/Phase20Tests -only-testing:LocalConvertTests/Phase20BTests` → **`30/30` tests passed in `3` suites (`0` failures, `0.336s`)**.
   - **Final Full Regression Run:** `xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/lc_phase4713_test_dd` → **`602/602` tests passed in `77` suites (`0` failures, `0` skipped) in `265.421s` (`** TEST SUCCEEDED **`)**.
   - **Compiler & Concurrency Warnings:** `0` Swift compiler warnings and `0` Swift 6 strict concurrency warnings.
2. **Live GUI & Accessibility Verification (vs. Unperformed Pixel Screenshots):**
   - **Verified Live via macOS Accessibility (`System Events`) + `xctrace` on Running Process:** Exercised 65 live UI interactions across 5 scenarios (`theme`: `System → Light → Dark → System` × 5; `popover_open_close` × 5; `popover_modes`: `Dock Only → Menu Bar Only → Neither → Dock + Menu Bar` × 5; `keep_running` × 10 toggles; `settings_nav`: `Settings ↔ Convert` + scroll cycles × 5) on both Debug (`/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app`) and isolated Release (`/tmp/lc_release_4714/LocalConvert.app`).
   - **Distinction Note:** Pixel-buffer screen-recording capture (`screencapture`) was not used; all runtime UI verification was performed via live AppKit window hierarchy inspection, `System Events` Accessibility hierarchy queries, and Instruments `xctrace` SwiftUI/Hitches telemetry.
3. **Updated Local Debug Build Deployment (Stage 11):**
   - **App Bundle Path:** `/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app`
   - **Executable Path:** `/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app/Contents/MacOS/LocalConvert`
   - **Bundle Identifier:** `com.localconvert.app`
   - **Version / Build:** `1.0.0` (Build `1`)
   - **Architecture:** `arm64`
   - **Executable Modification Timestamp & Size:** `2026-11-21 04:23:04 +0300` (`40,640 bytes`)
   - **Executable SHA-256:** `65a9c5a03628b571ce7fa71440b7fffecdd5c1b860cf87f74951e0552cb2c69c`
   - **Active Running Process:** Relaunched and verified running at PID `9505` (`lsappinfo info -only bundlepath -app 9505` → `"/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app"`) with default settings restored (`appearanceMode = System`, `applicationVisibilityMode = both`, `keepAppOpenAfterConversion = true`).
   - **Safety Verification:** `/Applications/LocalConvert.app` and `release/Build/Products/Release/LocalConvert.app` were untouched.

---

### 24.8 Quality Gates & Final Recommendation

| Quality Gate | Status | Evidence |
|---|---|---|
| All P0 and P1 issues resolved and verified | **PASS** | P0-1 (`OpaqueWindowChromeHost`) and P1-1..P1-3 implemented, unit-tested, and `xctrace`-verified |
| All safe P2 and P3 improvements implemented | **PASS** | P2-1..P2-5 and P3-1..P3-2 implemented in `SettingsView`, `AppState`, `JobsCenterView`, `JobsSummaryHeaderView`, `HistoryView`, `PDFCompressOptionsView`, `AppNotificationManager` |
| Theme transitions (`System ↔ Light ↔ Dark`) coherent without two-phase chrome lag | **PASS** | `CATransaction.setDisableActions(true)` + appearance caching in `OpaqueWindowChromeHost`; `-76.8%` `SwiftUIFilteredUpdates`, `-19.9%` Release p95 latency |
| Application Visibility popover and all four modes work reliably | **PASS** | 20 live mode transitions in Debug + 20 in Release + automated lifecycle tests (`Phase47LifecycleAndUXTests`) |
| `SettingsView` scrolling and interactions smooth without full-tree invalidation | **PASS** | 11 isolated section views; `keep_running` filtered updates reduced by `-89.9%` (`~1,526.8 → 154`), `Switch.update` `-100%` (`820 → 0`), max hitch `-69.1%` |
| No Swift 6 concurrency errors or new compiler warnings | **PASS** | `0` Swift/concurrency warnings across `LocalConvert` and `LocalConvertTests` |
| Full test suite passes with zero regressions | **PASS** | **`602/602` tests in `77` suites passed (`0` failures, `0` skipped)** |
| Separate Debug build created and verified running | **PASS** | `/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app` running at PID `9505` |
| `/Applications/LocalConvert.app` and existing Release build untouched | **PASS** | Untouched; temporary `/tmp/lc_release_4714` and `/tmp/*.trace` cleaned up |

**Final Phase 47.1.4 Recommendation:** **GO**

---

## 25. Phase 47 Final Closure & Theme-Transition Bug Resolution

### 25.1 Historical Baseline vs. Post-47.1.4 Theme-Transition Fix

- **Phase 47.1.4 Historical Regression Baseline:** The Phase 47.1.4 milestone completed with **`602 / 602` tests passed across `77` suites (`0` failures, `0` skipped, `0` warnings)**. That full regression run predates the post-47.1.4 theme-transition fix documented below and is preserved as the historical Phase 47.1.4 baseline.
- **Post-47.1.4 Theme-Transition Bug:** Following Phase 47.1.4, a visual mismatch was identified when switching from an explicit `Light` or `Dark` appearance back to `System`.

### 25.2 Root Cause & Implementation Summary

- **Root Cause:** When switching from an explicit `Light` or `Dark` appearance to `System`, SwiftUI received `.preferredColorScheme(nil)` and relinquished its explicit appearance override. AppKit immediately changed `NSWindow.appearance` to the system appearance, while SwiftUI's content appearance updated later, causing a temporary mismatch between window chrome and application content.
- **Implementation (see `docs/THEME_TRANSITION_FIX.md` for full details):**
  - Added `SystemAppearanceMonitor` to observe the macOS effective appearance.
  - Added `AppearanceMode.resolvedColorScheme(system:)`.
  - `System` mode now resolves to the current macOS `Light` or `Dark` color scheme and passes that explicit value to `.preferredColorScheme(...)` so AppKit and SwiftUI update together.
  - Added `isApplyingChrome` re-entrancy guard in `OpaqueWindowChromeHost`.
- **System Appearance Option Retained:** The `System` appearance option remains enabled and fully supported in Settings.

### 25.3 Verification & Formal Closure

- **Focused Verification:** **`21 / 21` focused tests passed** for the theme-transition fix (distinct from the earlier `602 / 602` Phase 47.1.4 full regression run).
- **User Acceptance:** Verified and accepted by the user.
- **Status:** **Phase 47 is formally CLOSED.**




