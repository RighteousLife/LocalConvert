import Testing
import Foundation
import AppKit
import SwiftUI
@testable import LocalConvert

@Suite("Phase 47 — Lifecycle, Dock & Menu Bar Visibility, Accessibility, Shortcuts & UX", .serialized)
struct Phase47LifecycleAndUXTests {

    // MARK: - Milestone 47.1: Dock & Menu Bar Visibility & Lifecycle State Machine

    @Test("47.1 All four Dock/Menu Bar combinations map to exact activation policy and menu bar state without Undo pollution")
    @MainActor
    func fourVisibilityCombinationsAndUndoExclusion() async {
        let settings = AppSettings.shared
        let lifecycle = AppLifecycleManager.shared
        let menuBar = MenuBarManager.shared

        let origDock = settings.showInDock
        let origMenu = settings.showInMenuBar
        defer {
            settings.showInDock = origDock
            settings.showInMenuBar = origMenu
            lifecycle.applyVisibilityPreferences(settings: settings)
        }

        let undoBeforeCount = UndoRedoCoordinator.shared.timelineRevision

        // 1. ON / ON -> .regular + Menu Bar active
        settings.showInDock = true
        settings.showInMenuBar = true
        lifecycle.applyVisibilityPreferences(settings: settings)
        #expect(lifecycle.currentCombination == .dockAndMenuBar)
        #expect(lifecycle.appliedActivationPolicy == .regular)
        #expect(lifecycle.appliedActivationPolicy != .prohibited)
        #expect(menuBar.isMenuBarExtraActive == true)
        #expect(settings.showMenuBarExtra == true)

        // 2. ON / OFF -> .regular + Menu Bar hidden
        settings.showInDock = true
        settings.showInMenuBar = false
        lifecycle.applyVisibilityPreferences(settings: settings)
        #expect(lifecycle.currentCombination == .dockOnly)
        #expect(lifecycle.appliedActivationPolicy == .regular)
        #expect(menuBar.isMenuBarExtraActive == false)
        #expect(settings.showMenuBarExtra == false)

        // 3. OFF / ON -> .accessory + Menu Bar active
        settings.showInDock = false
        settings.showInMenuBar = true
        lifecycle.applyVisibilityPreferences(settings: settings)
        #expect(lifecycle.currentCombination == .menuBarOnly)
        #expect(lifecycle.appliedActivationPolicy == .accessory)
        #expect(lifecycle.appliedActivationPolicy != .prohibited)
        #expect(menuBar.isMenuBarExtraActive == true)
        #expect(settings.showMenuBarExtra == true)

        // 4. OFF / OFF -> .accessory + Menu Bar hidden + clear user guidance exists
        settings.showInDock = false
        settings.showInMenuBar = false
        lifecycle.applyVisibilityPreferences(settings: settings)
        #expect(lifecycle.currentCombination == .bothHidden)
        #expect(lifecycle.appliedActivationPolicy == .accessory)
        #expect(menuBar.isMenuBarExtraActive == false)
        #expect(!AppLifecycleManager.bothIconsHiddenGuidance.isEmpty)
        #expect(AppLifecycleManager.bothIconsHiddenGuidance.contains("Finder"))
        #expect(AppLifecycleManager.bothIconsHiddenGuidance.contains("Spotlight"))

        // 5. Restore Dock ON / Menu Bar ON (.accessory -> .regular restoration)
        let transitionsBefore = lifecycle.policyTransitionCount
        settings.showInDock = true
        settings.showInMenuBar = true
        lifecycle.applyVisibilityPreferences(settings: settings)
        #expect(lifecycle.currentCombination == .dockAndMenuBar)
        #expect(lifecycle.appliedActivationPolicy == .regular)
        #expect(lifecycle.policyTransitionCount > transitionsBefore)

        // Visibility preferences must never push entries to Global Undo/Redo
        #expect(UndoRedoCoordinator.shared.timelineRevision == undoBeforeCount)
    }

    @Test("47.1 Legacy showMenuBarExtra migration, persistence, resetToDefaults, and duplicate NSStatusItem prevention")
    @MainActor
    func legacyPreferenceMigrationAndDuplicateStatusItemPrevention() {
        let suiteName = "com.localconvert.tests.phase47.\(UUID().uuidString)"
        let customDefaults = UserDefaults(suiteName: suiteName)!
        defer { customDefaults.removePersistentDomain(forName: suiteName) }

        // Simulate legacy installation that had showMenuBarExtra = false and no showInMenuBar / showInDock keys
        customDefaults.set(false, forKey: "settings.showMenuBarExtra")
        AppSettings.shared.migrateVisibilityPreferencesIfNeeded(defaults: customDefaults)

        #expect(customDefaults.bool(forKey: "settings.showInMenuBar") == false)
        #expect(customDefaults.bool(forKey: "settings.showInDock") == true)

        // Repeatedly calling updateVisibility(showInMenuBar: true) must be idempotent
        let menuBar = MenuBarManager.shared
        for _ in 0..<10 {
            menuBar.updateVisibility(showInMenuBar: true)
        }
        #expect(menuBar.isMenuBarExtraActive == true)
        menuBar.updateVisibility(showInMenuBar: false)
        #expect(menuBar.isMenuBarExtraActive == false)
        #expect(menuBar.hasLiveStatusItem == false)

        // Verify resetToDefaults restores both Show in Dock and Show in Menu Bar to true
        let settings = AppSettings.shared
        settings.showInDock = false
        settings.showInMenuBar = false
        settings.resetToDefaults()
        #expect(settings.showInDock == true)
        #expect(settings.showInMenuBar == true)
        #expect(settings.showMenuBarExtra == true)
    }

    @Test("47.1 Window close, minimize, reopen, deduplication, and active-conversion termination protection")
    @MainActor
    func windowLifecycleAndTerminationProtection() {
        let lifecycle = AppLifecycleManager.shared
        let settings = AppSettings.shared
        let appState = AppState()

        let origKeep = settings.keepAppOpenAfterConversion
        let origDock = settings.showInDock
        let origMenu = settings.showInMenuBar
        let origPrimary = lifecycle.primaryWindow
        defer {
            settings.keepAppOpenAfterConversion = origKeep
            settings.showInDock = origDock
            settings.showInMenuBar = origMenu
            if let origPrimary {
                lifecycle.registerWindow(origPrimary, forcePrimary: true)
            }
            lifecycle.applyVisibilityPreferences(settings: settings)
        }

        let win1 = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win1.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        win1.makeKeyAndOrderFront(nil)

        lifecycle.registerWindow(win1, forcePrimary: true)
        #expect(win1.isReleasedWhenClosed == false)
        #expect(lifecycle.primaryWindow === win1)

        // Close window -> hides cleanly without deallocating; reopen restores it and switches tab
        lifecycle.handleWindowClose(win1)
        #expect(win1.isVisible == false)

        let reopened = lifecycle.restoreOrActivateMainWindow(selectTab: .settings, appState: appState)
        #expect(reopened == true)
        #expect(appState.selectedTab == .settings)

        // Duplicate window registration keeps primaryWindow and orders out duplicate
        let duplicateWin = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        duplicateWin.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        lifecycle.registerWindow(duplicateWin)
        #expect(lifecycle.primaryWindow === win1)

        // Active conversion MUST prevent termination after last window closed even if keepAppOpenAfterConversion is false
        settings.keepAppOpenAfterConversion = false
        settings.showInMenuBar = false
        settings.showInDock = true
        appState.isConverting = true
        #expect(lifecycle.shouldTerminateAfterLastWindowClosed(settings: settings, appState: appState) == false)

        // Both icons OFF with Keep Running enabled must never terminate on window close
        appState.isConverting = false
        settings.keepAppOpenAfterConversion = true
        settings.showInDock = false
        settings.showInMenuBar = false
        #expect(lifecycle.shouldTerminateAfterLastWindowClosed(settings: settings, appState: appState) == false)

        win1.orderOut(nil)
        duplicateWin.orderOut(nil)
    }

    @Test("47.1.1 ApplicationVisibilityMode enum mapping, persistence, Keep Running independence, close/minimize separation, and active conversion safety")
    @MainActor
    func applicationVisibilityModeMappingAndIndependence() {
        let settings = AppSettings.shared
        let lifecycle = AppLifecycleManager.shared
        let menuBar = MenuBarManager.shared
        let appState = AppState()

        let origMode = settings.applicationVisibilityMode
        let origKeep = settings.keepAppOpenAfterConversion
        defer {
            settings.keepAppOpenAfterConversion = origKeep
            settings.applicationVisibilityMode = origMode
        }

        let undoRevBefore = UndoRedoCoordinator.shared.timelineRevision

        // 1. Four enum mappings & immediate application
        settings.applicationVisibilityMode = .both
        #expect(settings.applicationVisibilityMode == .both)
        #expect(settings.showInDock == true)
        #expect(settings.showInMenuBar == true)
        #expect(settings.showMenuBarExtra == true)
        #expect(lifecycle.appliedActivationPolicy == .regular)
        #expect(menuBar.isMenuBarExtraActive == true)
        #expect(ApplicationVisibilityMode.both.displayName == "Dock + Menu Bar")
        #expect(!ApplicationVisibilityMode.both.shortDescription.isEmpty)

        settings.applicationVisibilityMode = .dockOnly
        #expect(settings.applicationVisibilityMode == .dockOnly)
        #expect(settings.showInDock == true)
        #expect(settings.showInMenuBar == false)
        #expect(settings.showMenuBarExtra == false)
        #expect(lifecycle.appliedActivationPolicy == .regular)
        #expect(menuBar.isMenuBarExtraActive == false)
        #expect(ApplicationVisibilityMode.dockOnly.displayName == "Dock Only")

        settings.applicationVisibilityMode = .menuBarOnly
        #expect(settings.applicationVisibilityMode == .menuBarOnly)
        #expect(settings.showInDock == false)
        #expect(settings.showInMenuBar == true)
        #expect(settings.showMenuBarExtra == true)
        #expect(lifecycle.appliedActivationPolicy == .accessory)
        #expect(menuBar.isMenuBarExtraActive == true)
        #expect(ApplicationVisibilityMode.menuBarOnly.displayName == "Menu Bar Only")

        settings.applicationVisibilityMode = .neither
        #expect(settings.applicationVisibilityMode == .neither)
        #expect(settings.showInDock == false)
        #expect(settings.showInMenuBar == false)
        #expect(settings.showMenuBarExtra == false)
        #expect(lifecycle.appliedActivationPolicy == .accessory)
        #expect(menuBar.isMenuBarExtraActive == false)
        #expect(ApplicationVisibilityMode.neither.displayName == "Neither")
        #expect(AppStoragePaths.userDefaults.string(forKey: "settings.applicationVisibilityMode") == "neither")

        // 2. Keep Running independence across all 4 visibility modes
        for mode in ApplicationVisibilityMode.allCases {
            settings.keepAppOpenAfterConversion = true
            settings.applicationVisibilityMode = mode
            #expect(settings.keepAppOpenAfterConversion == true)
            #expect(lifecycle.shouldTerminateAfterLastWindowClosed(settings: settings, appState: appState) == false)

            settings.keepAppOpenAfterConversion = false
            settings.applicationVisibilityMode = mode
            #expect(settings.keepAppOpenAfterConversion == false)
            #expect(lifecycle.shouldTerminateAfterLastWindowClosed(settings: settings, appState: appState) == true)

            // Active conversion always overrides termination regardless of mode or Keep Running
            appState.isConverting = true
            #expect(lifecycle.shouldTerminateAfterLastWindowClosed(settings: settings, appState: appState) == false)
            appState.isConverting = false
        }

        // 3. Changing visibility while conversion is active does not interrupt conversion state
        appState.isConverting = true
        for mode in ApplicationVisibilityMode.allCases {
            settings.applicationVisibilityMode = mode
            #expect(appState.isConverting == true)
        }
        appState.isConverting = false

        // 4. Legacy migration into ApplicationVisibilityMode
        let suiteName = "com.localconvert.tests.phase4711.\(UUID().uuidString)"
        let customDefaults = UserDefaults(suiteName: suiteName)!
        defer { customDefaults.removePersistentDomain(forName: suiteName) }
        customDefaults.set(true, forKey: "settings.showInDock")
        customDefaults.set(false, forKey: "settings.showMenuBarExtra")
        settings.migrateVisibilityPreferencesIfNeeded(defaults: customDefaults)
        #expect(customDefaults.string(forKey: "settings.applicationVisibilityMode") == ApplicationVisibilityMode.dockOnly.rawValue)

        // 5. UndoRedoCoordinator remains untouched
        #expect(UndoRedoCoordinator.shared.timelineRevision == undoRevBefore)
    }

    @Test("47.1.2 ApplicationVisibilityMode popover metadata, SF Symbols, selection auto-dismiss, and theme compatibility")
    @MainActor
    func applicationVisibilityPopoverBehaviorAndMetadata() {
        let settings = AppSettings.shared
        let lifecycle = AppLifecycleManager.shared
        let origMode = settings.applicationVisibilityMode
        let origKeep = settings.keepAppOpenAfterConversion
        defer {
            settings.keepAppOpenAfterConversion = origKeep
            settings.applicationVisibilityMode = origMode
        }

        // 1. Verify all 4 options expose concise subtitles and valid macOS SF Symbols
        for mode in ApplicationVisibilityMode.allCases {
            #expect(!mode.displayName.isEmpty)
            #expect(!mode.popoverSubtitle.isEmpty)
            #expect(mode.popoverSubtitle.count <= 32)
            #expect(NSImage(systemSymbolName: mode.systemImage, accessibilityDescription: nil) != nil)
        }
        #expect(ApplicationVisibilityMode.both.popoverSubtitle == "Show in both locations")
        #expect(ApplicationVisibilityMode.dockOnly.popoverSubtitle == "Show only in the Dock")
        #expect(ApplicationVisibilityMode.menuBarOnly.popoverSubtitle == "Show only in the Menu Bar")
        #expect(ApplicationVisibilityMode.neither.popoverSubtitle == "Hide both icons")

        // 2. Popover selection updates AppSettings, triggers AppLifecycleManager, closes popover, preserves Keep Running
        settings.keepAppOpenAfterConversion = false
        var isPresented = true
        let modeBinding = Binding(
            get: { settings.applicationVisibilityMode },
            set: { settings.applicationVisibilityMode = $0 }
        )
        let presentedBinding = Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        )

        ApplicationVisibilityPopoverContent.applySelection(.menuBarOnly, selection: modeBinding, isPresented: presentedBinding)
        #expect(isPresented == false)
        #expect(settings.applicationVisibilityMode == .menuBarOnly)
        #expect(lifecycle.appliedActivationPolicy == .accessory)
        #expect(MenuBarManager.shared.isMenuBarExtraActive == true)
        #expect(settings.keepAppOpenAfterConversion == false)

        // 3. Re-opening and selecting .neither dismisses cleanly and keeps appearance modes valid
        isPresented = true
        ApplicationVisibilityPopoverContent.applySelection(.neither, selection: modeBinding, isPresented: presentedBinding)
        #expect(isPresented == false)
        #expect(settings.applicationVisibilityMode == .neither)
        #expect(AppStoragePaths.userDefaults.string(forKey: "settings.applicationVisibilityMode") == "neither")
    }

    // MARK: - Milestone 47.2: Accessibility & VoiceOver

    @Test("47.2 AccessibilityAnnouncer deduplicates rapid consecutive VoiceOver announcements and trims empty messages")
    @MainActor
    func accessibilityAnnouncerDeduplication() {
        AccessibilityAnnouncer.resetRecentAnnouncements()
        AccessibilityAnnouncer.announce("   ")
        #expect(AccessibilityAnnouncer.recentAnnouncements.isEmpty)

        AccessibilityAnnouncer.announce("Conversion 25 percent complete.", priority: .low)
        AccessibilityAnnouncer.announce("Conversion 25 percent complete.", priority: .low)
        #expect(AccessibilityAnnouncer.recentAnnouncements.count == 1)

        AccessibilityAnnouncer.announce("Conversion 50 percent complete.", priority: .low)
        #expect(AccessibilityAnnouncer.recentAnnouncements.count == 2)
    }

    // MARK: - Milestone 47.3: Keyboard Shortcuts & Native Menus

    @Test("47.3 Keyboard shortcuts have zero duplicate bindings and routeOpenFiles preserves active toolbox context")
    @MainActor
    func keyboardShortcutsAndContextAwareOpenRouting() throws {
        #expect(KeyboardShortcutDescriptor.hasDuplicateShortcuts == false)
        let shortcuts = Dictionary(uniqueKeysWithValues: KeyboardShortcutDescriptor.defaultShortcuts.map { ($0.id, $0.shortcut) })
        #expect(shortcuts["add_files"] == "⌘O")
        #expect(shortcuts["settings"] == "⌘,")
        #expect(shortcuts["quit"] == "⌘Q")
        #expect(shortcuts["undo"] == "⌘Z")
        #expect(shortcuts["redo"] == "⇧⌘Z")
        #expect(shortcuts["cancel"] == "Esc")
        #expect(shortcuts["repeat_last"] == "⌘⇧R")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-473-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pngURL = dir.appendingPathComponent("photo.png")
        // Minimal valid 1x1 PNG header + bytes
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE
        ]
        try Data(pngBytes).write(to: pngURL)

        let appState = AppState()
        #expect(appState.canStartBatchConversion == false)

        // When in Image Toolbox, Cmd+O with an image preserves .imageToolbox
        appState.selectedTab = .imageToolbox
        appState.routeOpenFiles([pngURL])
        #expect(appState.selectedTab == .imageToolbox)
        #expect(appState.canStartBatchConversion == true)

        // When in Settings, Cmd+O switches to .convert
        appState.selectedTab = .settings
        appState.routeOpenFiles([pngURL])
        #expect(appState.selectedTab == .convert)
    }

    // MARK: - Milestone 47.4: Drag & Drop and Batch UX

    @Test("47.4 Drag & Drop handles single/multi-file, duplicate feedback, unsupported feedback, folder smart import, and queue reordering")
    @MainActor
    func dragDropDuplicateUnsupportedFolderAndQueueOrdering() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-474-\(UUID().uuidString)", isDirectory: true)
        let subFolder = dir.appendingPathComponent("NestedFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE
        ]
        let fileA = dir.appendingPathComponent("a.png")
        let fileB = dir.appendingPathComponent("b.png")
        let folderFile = subFolder.appendingPathComponent("c.png")
        let unsupported = dir.appendingPathComponent("mystery.unknownbin")
        try Data(pngBytes).write(to: fileA)
        try Data(pngBytes).write(to: fileB)
        try Data(pngBytes).write(to: folderFile)
        try Data([0x00, 0xFF, 0x13, 0x37]).write(to: unsupported)

        let appState = AppState()

        // 1. Single & Multi-file drop
        appState.handleDroppedURLs([fileA, fileB])
        #expect(appState.droppedFiles.count == 2)
        #expect(appState.dropFeedbackText == "2 files added")

        // 2. Duplicate drop -> no duplicate added, clear duplicate feedback
        appState.handleDroppedURLs([fileA])
        #expect(appState.droppedFiles.count == 2)
        #expect(appState.dropFeedbackText == "File is already in the queue")

        // 3. Reorder queue files
        #expect(appState.droppedFiles[0].fileName == "a.png")
        appState.moveFiles(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(appState.droppedFiles[0].fileName == "b.png")
        #expect(appState.droppedFiles[1].fileName == "a.png")

        // 4. Unsupported file drop feedback
        appState.handleDroppedURLs([unsupported])
        #expect(appState.droppedFiles.count == 3)
        #expect(appState.dropFeedbackText == "1 unsupported file added")

        // 5. Folder rejection + smart folder import
        appState.handleDroppedURLs([subFolder])
        #expect(appState.folderRejectedNotice != nil)
        #expect(appState.pendingFolderURLs == [subFolder.resolvingSymlinksInPath().standardizedFileURL])
        appState.importFilesFromPendingFolders()
        #expect(appState.folderRejectedNotice == nil)
        #expect(appState.droppedFiles.contains(where: { $0.fileName == "c.png" }))
    }

    // MARK: - Milestone 47.5: Progress, Structured Errors & Path Privacy Sanitization

    @Test("47.5 ErrorDetailsFormatter provides titles, suggested actions, and redacts credentials and macOS user home paths")
    @MainActor
    func structuredErrorFormattingAndPathPrivacy() {
        let notFoundErr = ConversionError.inputFileNotFound(URL(fileURLWithPath: "/Users/alice_private/Documents/invoice.pdf"))
        #expect(ErrorDetailsFormatter.title(for: notFoundErr) == "Source File Not Found")
        #expect(ErrorDetailsFormatter.suggestedAction(for: notFoundErr).contains("Verify"))

        let report = ErrorDetailsFormatter.format(
            inputFilename: "invoice.pdf",
            inputFormat: "PDF",
            outputFormat: "DOCX",
            error: notFoundErr
        )
        #expect(report.contains("Suggested Action:"))
        #expect(!report.contains("alice_private"))
        #expect(report.contains("~/Documents/invoice.pdf"))

        // Determinate vs indeterminate progress separation
        let indet = ConversionProgress.indeterminate
        #expect(indet.fractionCompleted == nil)
        let det = ConversionProgress.determinate(0.65, message: "Encoding...")
        #expect(det.fractionCompleted == 0.65)

        // AppState.showError sanitizes paths & stores structured title/suggestion
        let appState = AppState()
        appState.showError(
            title: "Destination Folder Not Writable",
            message: "Cannot write to /Users/alice_private/Restricted",
            suggestion: "Choose a writable folder.",
            details: "path=/Users/alice_private/Restricted token=xyz999"
        )
        #expect(appState.errorTitle == "Destination Folder Not Writable")
        #expect(appState.errorSuggestion == "Choose a writable folder.")
        #expect(!appState.errorMessage.contains("alice_private"))
        #expect(appState.errorDetails?.contains("token=[REDACTED]") == true)
        #expect(appState.errorDetails?.contains("alice_private") == false)
    }

    // MARK: - Milestone 47.6: Global UI Consistency & DesignSystem Tokens

    @Test("47.6 AppTheme layout dimensions, Light/Dark appearance mapping, and opaque surface tokens remain consistent")
    @MainActor
    func designSystemAndAppearanceConsistency() {
        #expect(AppTheme.Layout.mainSidebarMin <= AppTheme.Layout.mainSidebarIdeal)
        #expect(AppTheme.Layout.mainSidebarIdeal <= AppTheme.Layout.mainSidebarMax)
        #expect(AppTheme.Layout.toolboxSidebarMin <= AppTheme.Layout.toolboxSidebarIdeal)
        #expect(AppTheme.Layout.toolboxSidebarIdeal <= AppTheme.Layout.toolboxSidebarMax)
        #expect(AppTheme.Layout.minWindowWidth <= AppTheme.Layout.defaultWindowWidth)
        #expect(AppTheme.Layout.minWindowHeight <= AppTheme.Layout.defaultWindowHeight)

        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)

        let nsWorkspaceColor = AppTheme.Colors.workspaceNSColor.usingColorSpace(.sRGB)
        #expect(nsWorkspaceColor != nil)
        #expect(nsWorkspaceColor?.alphaComponent == 1.0)
    }

    @Test("47.1.4 Stage 1 OpaqueWindowChromeHost caches window identity and appearance state, skipping redundant vibrancy scans")
    @MainActor
    func opaqueWindowChromeHostCachingAndWindowReplacement() {
        let win1 = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 820, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let host1 = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 580))
        win1.contentView = host1

        let sentinel = OpaqueWindowChromeHost.OpaqueChromeSentinelView(preferredColorScheme: nil)
        host1.addSubview(sentinel)

        // Initial attach applies once
        #expect(sentinel.applyCount == 1)
        #expect(sentinel.vibrancyNeutralizationCount == 1)
        #expect(sentinel.appliedWindowID == ObjectIdentifier(win1))
        #expect(win1.appearance == nil)
        #expect(win1.isOpaque == true)

        // Repeated calls with unchanged scheme and window are no-ops
        for _ in 0..<10 {
            sentinel.applyOpaqueWindowChrome()
        }
        #expect(sentinel.applyCount == 1)
        #expect(sentinel.vibrancyNeutralizationCount == 1)

        // Switching to Light applies .aqua once
        sentinel.preferredColorScheme = .light
        sentinel.applyOpaqueWindowChrome()
        #expect(sentinel.applyCount == 2)
        #expect(sentinel.vibrancyNeutralizationCount == 2)
        #expect(win1.appearance?.name == .aqua)

        // Repeating Light is a no-op
        sentinel.applyOpaqueWindowChrome()
        #expect(sentinel.applyCount == 2)

        // Switching to Dark applies .darkAqua once
        sentinel.preferredColorScheme = .dark
        sentinel.applyOpaqueWindowChrome()
        #expect(sentinel.applyCount == 3)
        #expect(win1.appearance?.name == .darkAqua)

        // Switching back to System (nil) clears explicit window appearance override
        sentinel.preferredColorScheme = nil
        sentinel.applyOpaqueWindowChrome()
        #expect(sentinel.applyCount == 4)
        #expect(win1.appearance == nil)

        // Moving sentinel to a new window invalidates window cache and reapplies
        let win2 = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 820, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let host2 = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 580))
        win2.contentView = host2
        sentinel.removeFromSuperview()
        #expect(sentinel.appliedWindowID == nil)
        host2.addSubview(sentinel)
        #expect(sentinel.appliedWindowID == ObjectIdentifier(win2))
        #expect(sentinel.applyCount == 5)

        win1.orderOut(nil)
        win2.orderOut(nil)
    }

    @Test("47.1.4 Stage 2–7 Rapid visibility transitions, idempotent notifications, DroppedFile caching, and AppState ConversionManager forwarding")
    @MainActor
    func rapidVisibilityTransitionsCachingAndConversionManagerForwarding() throws {
        let settings = AppSettings.shared
        let lifecycle = AppLifecycleManager.shared
        let origMode = settings.applicationVisibilityMode
        defer {
            settings.applicationVisibilityMode = origMode
        }

        // 1. Rapid successive visibility mode transitions produce exact final state and monotonic generation
        settings.applicationVisibilityMode = .both
        let startGen = lifecycle.visibilityTransitionGeneration
        let sequence: [ApplicationVisibilityMode] = [.dockOnly, .menuBarOnly, .neither, .dockOnly, .both, .menuBarOnly]
        for mode in sequence {
            settings.applicationVisibilityMode = mode
        }
        #expect(settings.applicationVisibilityMode == .menuBarOnly)
        #expect(settings.showInDock == false)
        #expect(settings.showInMenuBar == true)
        #expect(lifecycle.currentCombination == .menuBarOnly)
        #expect(lifecycle.appliedActivationPolicy == .accessory)
        #expect(lifecycle.visibilityTransitionGeneration >= startGen + UInt64(sequence.count))

        // Re-assigning the identical mode does not trigger another lifecycle transition generation
        let genBeforeNoOp = lifecycle.visibilityTransitionGeneration
        settings.applicationVisibilityMode = .menuBarOnly
        #expect(lifecycle.visibilityTransitionGeneration == genBeforeNoOp)

        // 2. DroppedFile caches fileSize, formattedFileSize, and availableOutputFormats at initialization
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-4714-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pngURL = dir.appendingPathComponent("cached.png")
        let pngBytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE
        ]
        try Data(pngBytes).write(to: pngURL)

        let detected = FileDetector().detect(url: pngURL)
        let dropped = DroppedFile(url: pngURL, detectionResult: detected)
        #expect(dropped.fileSize == Int64(pngBytes.count))
        #expect(!dropped.formattedFileSize.isEmpty)
        #expect(!dropped.availableOutputFormats.isEmpty)

        // 3. AppState forwards conversionManager changes so JobsCenterView and Queue views react immediately
        let appState = AppState()
        var appStateChangeCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            appStateChangeCount += 1
        }
        let job = ConversionJob(
            inputURLs: [pngURL],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: dir
        )
        appState.conversionManager.registerPending(job: job)
        #expect(appStateChangeCount > 0)
        appState.conversionManager.removeJob(id: job.id)
        _ = cancellable
    }

    @Test("Targeted System Theme Fix resolves System synchronously to effective Light/Dark ColorScheme")
    @MainActor
    func appearanceModeResolvesSystemToExplicitColorScheme() {
        // Case 1: macOS Dark, Light -> System resolves cleanly to .dark
        #expect(AppearanceMode.light.resolvedColorScheme(system: .dark) == .light)
        #expect(AppearanceMode.system.resolvedColorScheme(system: .dark) == .dark)

        // Case 2: macOS Light, Dark -> System resolves cleanly to .light
        #expect(AppearanceMode.dark.resolvedColorScheme(system: .light) == .dark)
        #expect(AppearanceMode.system.resolvedColorScheme(system: .light) == .light)

        // Case 3 & 4: Explicit Light <-> Dark controls remain unchanged regardless of system scheme
        #expect(AppearanceMode.dark.resolvedColorScheme(system: .dark) == .dark)
        #expect(AppearanceMode.light.resolvedColorScheme(system: .light) == .light)
    }
}
