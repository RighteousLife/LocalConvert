# LocalConvert — Phase 47.1.4 Audit & Baseline Inventory

**Date:** 2026-11-21  
**Project:** `/Users/cancan/Desktop/LocalConvert/`  
**Repository:** `RighteousLife/LocalConvert`  
**Platform:** macOS 15.0+ (`arm64`), Swift 6.0 Strict Concurrency (`complete`), Xcode 27.2, XcodeGen (`project.yml`), Version `1.0.0` (Build `1`)

---

## 1. Stage 0 — Repository Baseline & Safety Check

### 1.1 Git & Workspace Baseline
- **Current branch:** `main`
- **Modified tracked files (`git status --short`):** 47 tracked files modified across `LocalConvert/App`, `LocalConvert/Core`, `LocalConvert/Engines`, `LocalConvert/Features`, `LocalConvertTests`, `project.yml`, `README.md`, `THIRD_PARTY_NOTICES.md`, and `scripts/verify-dependencies.sh`.
- **Untracked files/directories (`??`):** Phase 43–47 implementation files (`AppLifecycleManager.swift`, `Core/UndoRedo/`, `Engines/AudioEditor/`, `Engines/AudioToolbox/`, `Engines/Image/` services, `Features/AudioEditor/`, `Features/ImageToolbox/`, `Features/PDFToolbox/`, `LocalConvertTests/Phase42*..Phase47*`, `docs/PHASE44*..PHASE47*`, `debug-deployment/`).
- **Existing build locations:**
  - Installed app (DO NOT TOUCH): `/Applications/LocalConvert.app`
  - Existing Release build (DO NOT TOUCH): `/Users/cancan/Desktop/LocalConvert/release/Build/Products/Release/LocalConvert.app`
  - Previous Debug deployment: `/Users/cancan/Desktop/LocalConvert/debug-deployment/LocalConvert.app`
  - Phase 47.1.4 target Debug build output: `/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app` (verified `/Users/cancan/Desktop/LocalConvert/build/` does not exist yet).
- **XcodeGen configuration (`project.yml`):**
  - Target `LocalConvert` (`application`, `macOS 15.0`, `arm64`, `SWIFT_VERSION: 6.0`, `SWIFT_STRICT_CONCURRENCY: complete`, `MARKETING_VERSION: 1.0.0`, `CURRENT_PROJECT_VERSION: 1`).
  - Target `LocalConvertTests` (`bundle.unit-test`).
  - Bundled runtimes: FFmpeg 9.0.2, LibreOffice 26.8.0.3, libjxl v0.13.0, libwebp/libsharpyuv.

---

## 2. Complete Source-Defined UI Inventory

| Area / Component | Primary Files | Audited Aspects |
|---|---|---|
| **App Scene & Commands** | `LocalConvertApp.swift`, `AppLifecycleManager.swift` | WindowGroup, `.preferredColorScheme`, Menu commands (`⌘,`, `⌘Z`, `⇧⌘Z`, `⌥⌘Z`, `⌘O`, `⌘↩`, `⌘⇧R`, `⌘1`–`⌘8`), Dock/Reopen/Termination delegates |
| **Root Window & Sidebar** | `ContentView.swift`, `DesignSystem.swift` | `NavigationSplitView`, `SidebarView`, active job badge, toolbar Undo/Redo/Editing History popover, `OpaqueWindowChromeHost`, alert presentation |
| **Convert — Empty & Drop Zone** | `DropZoneView.swift`, `SupportedFormatsView.swift` | Dashed drop target, folder rejection `AppInfoBanner` with smart import action, Supported Formats sheet, `⌘O` Add Files, drop feedback pill |
| **Convert — Queue & Options** | `FileListView.swift`, `FileRowView.swift`, `FileOptionsView.swift`, `ImageOptimizationView.swift` | Queue header,Preset menu, Quick Actions strip, batch completion banner, `LazyVStack` file rows, thumbnail loader, format picker, popover options, bottom action bar (`ViewThatFits`), progress view |
| **Jobs Center** | `JobsCenterView.swift`, `JobsSummaryHeaderView.swift`, `BatchJobGroupView.swift`, `JobRowView.swift` | Segmented filter (`All`/`Active`/`Completed`/`Failed`), batch grouping (`DisclosureGroup`), live progress, retry/cancel/remove/reveal actions, `ErrorDetailsSheet` |
| **Settings & Popover** | `SettingsView.swift`, `AppSettings.swift` | 10 sections (`General`, `Output & Files`, `Notifications`, `Conversion Defaults`, `Performance`, `Jobs & History`, `Undo & Editing History`, `Privacy & Diagnostics`, `Keyboard Shortcuts`, `About`, `Reset`), custom `ApplicationVisibilitySelector` popover, `LicensesSheetView`, `SupportedFormatsView` |
| **History & Editing History** | `HistoryView.swift`, `EditingHistoryView.swift`, `HistoryManager.swift`, `UndoRedoCoordinator.swift` | Category filter, `.searchable`, clear menu/alerts, `HistoryRowView` context menu & repeat, non-destructive `EditingHistoryView` timeline popover |
| **Presets & Metadata** | `PresetManagerView.swift`, `PresetEditView.swift`, `MetadataView.swift`, `MetadataFieldView.swift`, `ArtworkEditorView.swift` | `HSplitView` sidebar/inspector, queue compatibility banner, create/edit preset sheet, metadata tag editor, GPS/tag removal, unsaved discard alert |
| **Toolboxes (PDF, Audio, Image)** | `PDFToolboxView.swift`, `AudioToolboxView.swift`, `AudioEditorRootView.swift`, `ImageToolboxView.swift` | Secondary sidebars (`AppToolboxSidebarRow`), file selection strips, non-destructive editors, undo/redo integration |
| **Menu Bar & Dock Lifecycle** | `MenuBarView.swift` (`MenuBarManager`), `AppLifecycleManager.swift` | `NSStatusItem` lifecycle, `NSMenu` construction, 4 visibility modes (`both`, `dockOnly`, `menuBarOnly`, `neither`), `keepAppOpenAfterConversion` |

*Note:* This Stage 0 table documents the source-code inventory; actual live GUI / Accessibility inspection is tracked separately in Stage 8.

---

## 3. Identified Issues & Priority Classification (P0–P3)

### P0 — Critical Functional, Visual-Coherence & Window Chrome Defects

- **P0-1: Desynchronized Theme Transition ("Top Bar Black First, Body Later") & Redundant `NSThemeFrame` Tree Walks**
  - *Files:* `LocalConvert/Features/Shared/DesignSystem.swift` (`L618-L684`), `LocalConvert/Features/Home/ContentView.swift` (`L6, L18`), `LocalConvert/App/LocalConvertApp.swift` (`L71, L79`)
  - *Root Cause:* `OpaqueWindowChromeHost.updateNSView` runs on every `ContentView.body` evaluation and unconditionally sets `window.appearance`, `window.backgroundColor`, and recursively walks every subview of `NSThemeFrame` via `neutralizeBehindWindowVibrancy(in:)`. When switching `Light → System` (while macOS is Dark), `window.appearance = nil` immediately flips the AppKit titlebar/toolbar (`NSThemeFrame`) to Dark Aqua in Frame `T`, while SwiftUI's `.preferredColorScheme(nil)` + 10-section `Form` takes `148–391 ms` to commit, causing a visible two-phase flash. Moreover, setting `window.appearance = nil` while SwiftUI `.preferredColorScheme` is still resolving causes temporary AppKit/SwiftUI appearance divergence.

### P1 — Major Usability, Observation, Lifecycle & Reactivity Defects

- **P1-1: Missing `ConversionManager` / `ConversionQueue` Observation in `JobsCenterView`, `JobsSummaryHeaderView`, `JobRowView`, `BatchJobGroupView`, `FileListView`, `FileRowView`, and `SidebarView`**
  - *Files:* `LocalConvert/App/AppState.swift` (`L224-L260`), `LocalConvert/Features/Jobs/JobsCenterView.swift` (`L6-L24`), `LocalConvert/Features/Jobs/JobsSummaryHeaderView.swift` (`L17-L31`), `LocalConvert/Features/Jobs/JobRowView.swift` (`L8-L25`), `LocalConvert/Features/Jobs/BatchJobGroupView.swift` (`L48-L59`), `LocalConvert/Features/Conversion/FileRowView.swift` (`L181-L188`), `LocalConvert/Features/Home/ContentView.swift` (`L100-L104`)
  - *Root Cause:* These views read `@Published` state from `appState.conversionManager` and `appState.conversionQueue` (`activeJobs`, `jobStatuses`, `completedCount`, `failedCount`, `progress`, `runningOrWaitingCount`) while only observing `appState` via `@EnvironmentObject`. Because `AppState` only forwards `imageToolboxStore` and `pdfToolboxStore` (`AppState.swift:233-238`) and does **not** observe `conversionManager` / `conversionQueue` (nor do the Job/File views observe them via `@ObservedObject`), actions like **Remove from Jobs**, **Clear Completed**, **Clear Failed**, **Cancel Job**, **Retry Conversion**, and live per-job progress updates do not reliably invalidate the affected SwiftUI views or update `MenuBarManager.shared.updateStatus()`.
- **P1-2: Duplicate `MenuBarManager` Updates, Triple `objectWillChange`, and Main-Thread Popover Dismissal Stall on Visibility Mode Switch**
  - *Files:* `LocalConvert/Core/Settings/AppSettings.swift` (`L314-L365`), `LocalConvert/Features/Home/SettingsView.swift` (`L374-L376`), `LocalConvert/App/AppLifecycleManager.swift` (`L59-L104`), `LocalConvert/Features/Home/MenuBarView.swift` (`L93-L189`)
  - *Root Cause:* Setting `applicationVisibilityMode` triggers `@AppStorage` `showInDock` and `showMenuBarExtra` setters plus an explicit `objectWillChange.send()`, invokes `AppLifecycleManager.shared.applyVisibilityPreferences` (which calls `MenuBarManager.shared.updateVisibility` and rebuilds `NSMenu`), and then triggers `SettingsView`'s `.onChange(of: settings.showMenuBarExtra)` which calls `MenuBarManager.shared.updateVisibility()` a second time. Furthermore, `MenuBarManager.updateVisibility` unconditionally rebuilds `NSMenu` even when `shouldShow` and status haven't changed.
- **P1-3: Global `AppSettings.shared` Observation Fan-Out Across `LocalConvertApp`, `ContentView`, `SettingsView`, and `EditingHistoryView`**
  - *Files:* `LocalConvert/App/LocalConvertApp.swift` (`L71`), `LocalConvert/Features/Home/ContentView.swift` (`L6`), `LocalConvert/Features/Home/SettingsView.swift` (`L5-L7`), `LocalConvert/Features/History/EditingHistoryView.swift` (`L17`), `LocalConvert/Core/Settings/AppSettings.swift`
  - *Root Cause:* `LocalConvertApp` and `ContentView` observe the entire `AppSettings.shared` singleton even though they only need `appearanceMode`. `EditingHistoryView` observes `AppSettings.shared` even though it only reads `recoveryArtifactStorageLimitMB`. Every toggle/slider/picker edit in Settings invalidates `LocalConvertApp.body`, `ContentView.body`, and all 10 sections of `SettingsView.body` (`7,634` filtered updates for 10 `Keep app running` toggles).

### P2 — UI Consistency, Modularization, Layout & Accessibility Issues

- **P2-1: Monolithic 10-Section `SettingsView` with Root-Level `HistoryManager` & `UndoRedoCoordinator` Observation and Inline Allocations**
  - *Files:* `LocalConvert/Features/Home/SettingsView.swift` (`L4-L437`)
  - *Root Cause:* All 10 sections are inline inside `SettingsView.body`. `SettingsView` observes `HistoryManager.shared` and `UndoRedoCoordinator.shared` at the top level (so any conversion history or undo stack change re-evaluates all 10 sections), calls `NSImage(named: "AppIcon")` and `Set(...).sorted()` inline in `body`, and uses 4 deprecated single-parameter `.onChange(of:perform:)` modifiers (`L369, L374, L377, L382`) generating compiler warnings.
- **P2-2: Non-Deterministic Batch Group Ordering in `JobsCenterView`**
  - *Files:* `LocalConvert/Features/Jobs/JobsCenterView.swift` (`L27-L49`)
  - *Root Cause:* `batchGroupedSections` groups jobs into `var batchDict: [UUID: [ConversionJob]] = [:]` and iterates `for (id, jobs) in batchDict`, which uses randomized Swift `Dictionary` hash order across renders, causing batch cards to jump order randomly.
- **P2-3: Repeated Main-Thread File System `attributesOfItem` & `ByteCountFormatter` in `DroppedFile` / `FileRowView`**
  - *Files:* `LocalConvert/App/AppState.swift` (`L23-L35`), `LocalConvert/Features/Conversion/FileRowView.swift` (`L45, L163-L168`)
  - *Root Cause:* `DroppedFile.fileSize` queries `FileManager.default.attributesOfItem(atPath:)` and `formattedFileSize` formats via `ByteCountFormatter` as computed properties on every `FileRowView.body` evaluation; `availableOutputFormats` also re-queries and sorts on every access.
- **P2-4: Deprecated `.onChange(of:perform:)` Compiler Warnings in `SettingsView` and `PDFCompressOptionsView`**
  - *Files:* `LocalConvert/Features/Home/SettingsView.swift` (`L369, L374, L377, L382`), `LocalConvert/Features/PDFToolbox/PDFCompressOptionsView.swift` (`L92`)
  - *Root Cause:* Uses macOS 14-deprecated 1-parameter `.onChange(of:) { newValue in ... }` closure syntax instead of macOS 15+ zero/two-parameter `.onChange(of:) { _, newValue in ... }`.
- **P2-5: Accessibility Labels on Segmented Filter Pickers (`JobsSummaryHeaderView`, `HistoryView`)**
  - *Files:* `LocalConvert/Features/Jobs/JobsSummaryHeaderView.swift` (`L93-L100`), `LocalConvert/Features/History/HistoryView.swift` (`L109-L116`)
  - *Root Cause:* `.labelsHidden()` is applied to segmented `Picker`s without an explicit `.accessibilityLabel(...)`, reducing clarity for assistive technologies.

### P3 — Visual Polish & Popover Micro-Interactions

- **P3-1: Redundant Nested `.background(.regularMaterial)` & Double Initial Evaluation in `ApplicationVisibilityPopoverContent`**
  - *Files:* `LocalConvert/Features/Home/SettingsView.swift` (`L515-L553`)
  - *Root Cause:* `.background(.regularMaterial)` inside `.popover` adds a second material backdrop layer over `NSPopover`'s native material chrome, and setting `focusedMode = selection` in `.onAppear` triggers an immediate second `ApplicationVisibilityPopoverContent.body` pass on open.
- **P3-2: Hover State & Visual Feedback Consistency on `ApplicationVisibilityOptionRow` & Popover Respecting `accessibilityReduceMotion`**
  - *Files:* `LocalConvert/Features/Home/SettingsView.swift` (`L441-L623`)
  - *Root Cause:* Ensure popover and option rows provide crisp focus/hover/selected states without nested backdrop overhead or focus-loss on keyboard navigation.

---

## 4. Implementation Summary (Stages 1–7)

| Priority & ID | Resolution Implemented | Modified Files | Verification Level |
|---|---|---|---|
| **P0-1** | `OpaqueWindowChromeHost` now tracks `appliedWindowID: ObjectIdentifier?`, `lastAppliedScheme: ColorScheme?`, `lastEffectiveAppearanceName: NSAppearance.Name?`, `hasAppliedInitialChrome: Bool`, `applyCount: Int`, and `vibrancyNeutralizationCount: Int`. Skips redundant `applyOpaqueWindowChrome()` and `neutralizeBehindWindowVibrancy(in:)` tree walks when window identity, `preferredColorScheme`, and effective appearance name are unchanged. Wraps `window.appearance`, `window.isOpaque`, `window.backgroundColor`, `neutralizeBehindWindowVibrancy(in:)`, and `window.contentView?.needsDisplay = true` in `CATransaction.begin(); CATransaction.setDisableActions(true); ... CATransaction.commit()` and overrides `viewDidChangeEffectiveAppearance()` on `OpaqueChromeSentinelView`. | `LocalConvert/Features/Shared/DesignSystem.swift` (`L616-L746`) | **Implemented + Automatically Tested + Live GUI / `xctrace` Verified** |
| **P1-1** | `AppState.setupObservation()` now subscribes to `conversionManager.objectWillChange` and `conversionQueue.objectWillChange`, forwarding changes to `AppState.objectWillChange` and invoking `MenuBarManager.shared.updateStatus()` when `conversionManager.isConverting` is true so `JobsCenterView`, `JobsSummaryHeaderView`, `JobRowView`, `BatchJobGroupView`, `FileListView`, `FileRowView`, `SidebarView`, and the Menu Bar item stay reactive without view-level workarounds. | `LocalConvert/App/AppState.swift` (`L228-L265`) | **Implemented + Automatically Tested** |
| **P1-2** | `AppSettings.applicationVisibilityMode.set` now checks `dockChanged` and `menuChanged` before mutating `@AppStorage` properties, skips redundant `objectWillChange.send()` and redundant `AppLifecycleManager.shared.applyVisibilityPreferences` calls when the mode is already applied. `AppLifecycleManager` guards `@Published` properties (`currentCombination`, `appliedActivationPolicy`, `isMainWindowMiniaturized`, `isMainWindowVisible`) with inequality checks and increments `visibilityTransitionGeneration: UInt64`. `MenuBarManager` tracks `menuRebuildCount`, `lastRenderedStatusSignature`, and `lastAppliedIconIsConverting` to avoid redundant `NSMenu` rebuilds and `button.image` reassignments. Removed duplicate `.onChange(of: settings.showMenuBarExtra)` from `SettingsView`. | `LocalConvert/Core/Settings/AppSettings.swift` (`L344-L392`), `LocalConvert/App/AppLifecycleManager.swift` (`L26-L31`, `L59-L86`, `L190-L207`), `LocalConvert/Features/Home/MenuBarView.swift` (`L74-L185`), `LocalConvert/Features/Home/SettingsView.swift` | **Implemented + Automatically Tested + Live GUI / `xctrace` Verified** |
| **P1-3** | Replaced `@ObservedObject private var settings = AppSettings.shared` in `LocalConvertApp` and `ContentView` with `@AppStorage("settings.appearanceMode") private var appearanceModeRaw: String = AppearanceMode.system.rawValue`. Replaced `@ObservedObject private var settings = AppSettings.shared` in `EditingHistoryView` with `@AppStorage("settings.recoveryArtifactStorageLimitMB")`. Non-appearance settings edits no longer invalidate `LocalConvertApp.body` or `ContentView.body`. | `LocalConvert/App/LocalConvertApp.swift` (`L67-L90`), `LocalConvert/Features/Home/ContentView.swift` (`L4-L24`), `LocalConvert/Features/History/EditingHistoryView.swift` (`L16-L18`, `L164-L170`) | **Implemented + Automatically Tested + Live GUI / `xctrace` Verified** |
| **P2-1** | Split monolithic `SettingsView` into 11 isolated section subviews (`GeneralSettingsSection`, `OutputFilesSettingsSection`, `NotificationsSettingsSection`, `ConversionDefaultsSettingsSection`, `PerformanceSettingsSection`, `JobsHistorySettingsSection`, `UndoEditingHistorySettingsSection`, `PrivacyDiagnosticsSettingsSection`, `KeyboardShortcutsSettingsSection`, `AboutSettingsSection`, `ResetDefaultsSettingsSection`). Scoped `HistoryManager.shared` observation strictly to `JobsHistorySettingsSection` and `UndoRedoCoordinator.shared` observation strictly to `UndoEditingHistorySettingsSection`. Cached `AppIcon` lookup in `AboutSettingsSection`. | `LocalConvert/Features/Home/SettingsView.swift` (`L4-L880`) | **Implemented + Automatically Tested + Live GUI / `xctrace` Verified** |
| **P2-2** | Maintained `var orderedBatchIDs: [UUID] = []` alongside `batchDict` in `JobsCenterView.batchGroupedSections` so batch groups always render in deterministic insertion order. | `LocalConvert/Features/Jobs/JobsCenterView.swift` (`L26-L54`) | **Implemented + Source-Inspected + Full Regression Tested** |
| **P2-3** | Cached `fileSize: Int64`, `formattedFileSize: String`, and `availableOutputFormats: [FileFormat]` as stored `let` properties on `DroppedFile` initialized once in `DroppedFile.init` using a shared static `ByteCountFormatter`, and updated `PDFCompressOptionsView.totalOriginalSize` to sum cached `f.fileSize`. | `LocalConvert/App/AppState.swift` (`L8-L88`), `LocalConvert/Features/PDFToolbox/PDFCompressOptionsView.swift` (`L7-L32`) | **Implemented + Automatically Tested** |
| **P2-4 & Swift 6 Concurrency** | Updated deprecated 1-parameter `.onChange(of:perform:)` modifiers to macOS 15 2-parameter `.onChange(of:) { _, newValue in ... }` in `SettingsView.swift` and `PDFCompressOptionsView.swift`. Resolved the Swift 6 `#ActorIsolatedCall` warning in `AppNotificationManager.requestAuthorizationIfNeeded()` by hopping to `@MainActor` via `Task { @MainActor [weak self] in self?.requestAuthorization() }`. | `LocalConvert/Features/Home/SettingsView.swift`, `LocalConvert/Features/PDFToolbox/PDFCompressOptionsView.swift` (`L65-L110`), `LocalConvert/Core/Notifications/AppNotificationManager.swift` (`L81-L87`) | **Implemented + Build Verified (0 Swift compiler / concurrency warnings)** |
| **P2-5** | Added `.accessibilityLabel("Filter jobs by status")` to `JobsSummaryHeaderView`'s segmented picker and `.accessibilityLabel("Filter history by category")` to `HistoryView`'s segmented picker. | `LocalConvert/Features/Jobs/JobsSummaryHeaderView.swift` (`L92-L102`), `LocalConvert/Features/History/HistoryView.swift` (`L108-L117`) | **Implemented + Source-Inspected + Full Regression Tested** |
| **P3-1 & P3-2** | Removed redundant nested `.background(.regularMaterial)` and `.onAppear { focusedMode = selection }` double body pass from `ApplicationVisibilityPopoverContent`, added `.onKeyPress(.return)` and `.onKeyPress(.space)` keyboard selection handlers, and added `isKeyboardFocused` highlight styling on `ApplicationVisibilityOptionRow` while respecting `@Environment(\.accessibilityReduceMotion)`. | `LocalConvert/Features/Home/SettingsView.swift` (`L520-L710`) | **Implemented + Automatically Tested + Live GUI / `xctrace` Verified** |

---

## 5. Before / After Performance & `xctrace` Re-Validation (Stage 10)

### 5.1 `xctrace` SwiftUI Template Comparison (Phase 47.1.3 Baseline vs. Phase 47.1.4 Optimized)

| Metric | Phase 47.1.3 Baseline | Phase 47.1.4 Optimized | Improvement / Delta |
|---|---|---|---|
| **`keep_running` Total `SwiftUIFilteredUpdates` (View Body + Representable)** | `7,634` (5 reps) / `~1,526.8` per rep | `154` (1 rep: `154` body, `0` representable, `1.224 ms` total SwiftUI CPU) | **`-89.9%` fewer filtered updates per toggle cycle** |
| **`keep_running` `Switch.update` (`Representable Updates`)** | `820` (`67.92 ms` total) | `0` in `Representable Updates` table | **`-100%` redundant `Switch.update` representable evaluations** |
| **`keep_running` `Hitches` / Max Hitch** | `24` hitches (max `189.03 ms`, avg `45.32 ms`) | `3` hitches (max `58.333 ms`, avg `38.89 ms`) | **`-69.1%` max hitch duration (`189.03 ms → 58.333 ms`)** |
| **`keep_running` `Hitches-Updates` Max** | `384` updates (max `76.59 ms`, avg `8.80 ms`) | `189` updates (max `19.055 ms`, avg `1.191 ms`) | **`-75.1%` max update duration (`76.59 ms → 19.055 ms`), `-86.5%` avg (`8.80 ms → 1.191 ms`)** |
| **`theme` Total `SwiftUIFilteredUpdates` (View Body + Representable)** | `15,895` (5 reps) / `~3,179` per rep | `737` (1 rep: `737` body, `0` representable, `5.68 ms` total SwiftUI CPU) | **`-76.8%` fewer filtered updates per theme cycle** |
| **`theme` `Hitches` / Max Hitch** | `52` hitches (max `158.95 ms`, avg `59.42 ms`) | `12` hitches (max `150.00 ms`, avg `52.778 ms`) | **`-11.2%` avg hitch duration; synchronous `CATransaction` chrome update eliminates 2-phase titlebar flash** |
| **Full 10s Session (`Settings` Open + `theme` + `keep_running`) `OpaqueWindowChromeHost` Updates** | Unconditional `NSThemeFrame` walk on every `ContentView.body` pass | `0` `Representable Updates`; `27` internal `PlatformViewChild` checks (`3.858 ms` total); `applyCount`/`vibrancyNeutralizationCount` gated by window ID + scheme + effective appearance name | **Redundant `NSThemeFrame` recursive walks eliminated (`100%` skipped when unchanged)** |

### 5.2 5-Repetition End-to-End Interaction Latency Benchmark (Phase 47.1.3 vs. Phase 47.1.4 Debug & Release)

| Scenario & Metric | Phase 47.1.3 Debug (`avg` / `med` / `p95`) | Phase 47.1.4 Debug (`avg` / `med` / `p95`) | Phase 47.1.4 Release (`avg` / `med` / `p95`) | Delta (Debug Before → After) |
|---|---|---|---|---|
| **1. `theme` (`menuOpenMs`, `n=15`)** | `164.08` / `164.45` / `184.53 ms` | `159.77` / `160.90` / `173.62 ms` | `160.66` / `158.53` / `174.35 ms` | **`-2.6%` avg, `-5.9%` p95** |
| **1. `theme` (`axConfirmWaitMs`, `n=15`)** | `348.59` / `329.75` / `459.46 ms` | `332.29` / `326.00` / `395.37 ms` | `319.47` / `307.34` / `368.15 ms` | **`-4.7%` avg (`-8.4%` Release), `-13.9%` p95 (`-19.9%` Release)** |
| **1. `theme` (`totalAutomationMs`, `n=15`)** | `555.02` / `535.91` / `662.30 ms` | `534.17` / `529.79` / `600.17 ms` | `521.79` / `519.63` / `558.66 ms` | **`-3.8%` avg (`-6.0%` Release), `-9.4%` p95 (`-15.6%` Release)** |
| **2. `popover_open_close` (`openDetectMs`, `n=5`)** | `82.34` / `81.82` / `89.38 ms` | `84.03` / `83.81` / `91.05 ms` | `84.13` / `83.83` / `90.47 ms` | Within `±1.7 ms` `NSPopover` spring baseline |
| **2. `popover_open_close` (`closeDetectMs`, `n=5`)** | `66.15` / `65.94` / `69.08 ms` | `68.34` / `66.34` / `72.83 ms` | `66.29` / `64.25` / `73.04 ms` | Within `±2.1 ms` `NSPopover` dismissal baseline |
| **3. `popover_modes` (`selectConfirmMs`, `n=20`)** | `624.53` / `616.05` / `681.55 ms` | `594.61` / `600.32` / `665.68 ms` | `615.95` / `617.53` / `697.56 ms` | **`-4.8%` (`-29.92 ms`) avg, `-2.3%` (`-15.87 ms`) p95** |
| **3. `popover_modes` (`totalStepMs`, `n=20`)** | `2385.56` / `2385.80` / `2499.04 ms` | `2318.56` / `2330.46` / `2403.97 ms` | `2392.19` / `2420.89` / `2470.72 ms` | **`-2.8%` (`-67.00 ms`) avg, `-3.8%` (`-95.07 ms`) p95** |
| **4. `keep_running` (`confirmMs`, `n=10`)** | `87.35` / `88.78` / `93.31 ms` | `85.56` / `86.87` / `91.47 ms` | `85.24` / `83.95` / `94.96 ms` | **`-2.0%` avg (`-5.4%` Release median: `88.78 → 83.95 ms`)** |
| **4. `keep_running` (`axPressAndConfirmMs`, `n=10`)** | `128.48` / `129.50` / `136.79 ms` | `126.63` / `130.22` / `135.80 ms` | `126.75` / `129.30` / `135.61 ms` | **`-1.4%` avg, `-0.99 ms` p95** |
| **5. `settings_nav` (`totalNavCycleMs`, `n=5`)** | `778.10` / `779.13` / `787.05 ms` | `768.02` / `768.69` / `787.94 ms` | `771.73` / `781.48` / `784.77 ms` | **`-1.3%` (`-10.08 ms`) avg** |
| **Physical Memory Footprint (`phys_footprint_mb` start → end)** | `67.1 MB → 95.3 MB` | `69.3 MB → 94.4 MB` | `70.7 MB → 83.3 MB` | **Bounded (`94.4 MB` Debug, `83.3 MB` Release); `0 MB` unbounded leak across 65 interactions** |

---

## 6. Test, Build & Quality Gate Results (Stages 8, 9, 11, 12)

- **Focused Regression Tests (`Phase47LifecycleAndUXTests`, `Phase20Tests`, `Phase20BTests`):** `30/30` tests in `3` suites passed (`0` failures, `0.336s`).
- **Final Full Regression Test Run (`xcodebuild test -project LocalConvert.xcodeproj -scheme LocalConvert -destination 'platform=macOS,arch=arm64'`):**
  - **`602` tests in `77` suites passed (`0` failures, `0` skipped) in `265.421s` (`** TEST SUCCEEDED **`)**.
  - Includes `Phase422ClosureTests` (`4/4` passed in full-suite run), `Phase46*` Image Editor suites, `Phase47LifecycleAndUXTests` (`26/26` passed including new Stage 1 and Stage 2–7 tests), PDF Toolbox, Audio Editor, Metadata, and Smart Preset suites.
- **Compiler & Swift 6 Concurrency Warnings:** `0` Swift compiler warnings and `0` Swift 6 strict concurrency warnings across `LocalConvert` and `LocalConvertTests`.
- **Phase 47.1.4 Debug Build Deployment:**
  - Path: `/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app`
  - Executable: `/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app/Contents/MacOS/LocalConvert`
  - Bundle ID: `com.localconvert.app` | Version: `1.0.0` | Build: `1` | Architecture: `arm64`
  - Executable Modified: `2026-11-21 04:23:04 +0300` | Size: `40,640 bytes`
  - Executable SHA-256: `65a9c5a03628b571ce7fa71440b7fffecdd5c1b860cf87f74951e0552cb2c69c`
  - Live Process Verification: Relaunched and confirmed active (`PID 9505`, `lsappinfo` bundle path `"/Users/cancan/Desktop/LocalConvert/build/Phase47.1.4/LocalConvert.app"`).
- **Verdict:** **GO**
