import Foundation
import AppKit
import SwiftUI
import os.log

// MARK: - Centralized Application Lifecycle & Visibility Manager

/// Single source of truth for macOS Dock (`NSApplication.ActivationPolicy`),
/// Menu Bar status item visibility (`MenuBarManager`), main window retention/restoration,
/// and safe termination behavior.
@MainActor
final class AppLifecycleManager: ObservableObject {

    static let shared = AppLifecycleManager()

    /// Descriptive state for the 4 Dock / Menu Bar combinations.
    enum VisibilityCombination: String, Equatable, Sendable {
        case dockAndMenuBar = "Dock & Menu Bar"
        case dockOnly = "Dock Only"
        case menuBarOnly = "Menu Bar Only"
        case bothHidden = "Both Hidden"
    }

    private let logger = Logger(subsystem: "com.localconvert.app", category: "AppLifecycle")

    @Published private(set) var appliedActivationPolicy: NSApplication.ActivationPolicy = .regular
    @Published private(set) var currentCombination: VisibilityCombination = .dockAndMenuBar
    @Published private(set) var policyTransitionCount: Int = 0
    @Published private(set) var isMainWindowVisible: Bool = true
    @Published private(set) var isMainWindowMiniaturized: Bool = false
    private(set) var visibilityTransitionGeneration: UInt64 = 0

    private(set) weak var primaryWindow: NSWindow?
    private var windowObserverTokens: [any NSObjectProtocol] = []

    /// Controls whether live `NSApp.setActivationPolicy` is invoked when running under XCTest.
    var applyLiveNSAppPolicyInTests: Bool = false

    private init() {
        installWindowNotifications()
    }

    // MARK: - Visibility & Activation Policy State Machine

    static func combination(showInDock: Bool, showInMenuBar: Bool) -> VisibilityCombination {
        switch (showInDock, showInMenuBar) {
        case (true, true): return .dockAndMenuBar
        case (true, false): return .dockOnly
        case (false, true): return .menuBarOnly
        case (false, false): return .bothHidden
        }
    }

    /// Maps Dock visibility preference to macOS activation policy. Never returns `.prohibited`.
    static func desiredActivationPolicy(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    /// Applies both Dock and Menu Bar visibility settings atomically from `AppSettings`.
    func applyVisibilityPreferences(
        settings: AppSettings = .shared,
        forcePolicyRefresh: Bool = false
    ) {
        visibilityTransitionGeneration &+= 1
        let showDock = settings.showInDock
        let showMenu = settings.showInMenuBar
        let nextCombo = Self.combination(showInDock: showDock, showInMenuBar: showMenu)
        let targetPolicy = Self.desiredActivationPolicy(showInDock: showDock)
        let previousPolicy = appliedActivationPolicy

        if currentCombination != nextCombo {
            currentCombination = nextCombo
        }

        // 1. Update Menu Bar Extra first so transitioning to Menu Bar Only never briefly hides both surfaces.
        MenuBarManager.shared.updateVisibility(showInMenuBar: showMenu)

        // 2. Apply Dock Activation Policy (.regular vs .accessory).
        let policyChanged = (previousPolicy != targetPolicy) || forcePolicyRefresh
        if appliedActivationPolicy != targetPolicy {
            appliedActivationPolicy = targetPolicy
        }
        if policyChanged {
            policyTransitionCount += 1
        }

        let isTesting = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if (!isTesting || applyLiveNSAppPolicyInTests), let app = NSApp {
            if app.activationPolicy() != targetPolicy || forcePolicyRefresh {
                _ = app.setActivationPolicy(targetPolicy)
            }
            // When restoring Dock icon (.accessory -> .regular) or when both icons are hidden,
            // preserve and keep the existing main window accessible.
            if previousPolicy == .accessory && targetPolicy == .regular {
                if let window = resolvePrimaryWindow(), window.isVisible {
                    app.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            } else if nextCombo == .bothHidden {
                // Ensure the user is not left without a visible window when disabling both icons.
                if let window = resolvePrimaryWindow(), !window.isVisible && !window.isMiniaturized {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        refreshWindowStateFlags()
        logger.info("Applied visibility combination: \(nextCombo.rawValue, privacy: .public) (Dock=\(showDock, privacy: .public), MenuBar=\(showMenu, privacy: .public))")
    }

    // MARK: - Window Registration, Deduplication & Reopening

    func registerWindow(_ window: NSWindow?, forcePrimary: Bool = false) {
        guard let window else { return }
        guard Self.isCandidateMainWindow(window) else { return }

        // Prevent AppKit from deallocating the window when the user clicks the red close button,
        // allowing instant reopening from Dock, Menu Bar, Finder, or Spotlight without state loss.
        window.isReleasedWhenClosed = false

        if forcePrimary || primaryWindow == nil || primaryWindow === window {
            primaryWindow = window
        } else if let existing = primaryWindow, existing !== window {
            if existing.contentView == nil {
                primaryWindow = window
            }
        }
        refreshWindowStateFlags()
    }

    func resolvePrimaryWindow() -> NSWindow? {
        if let primaryWindow, primaryWindow.contentView != nil {
            return primaryWindow
        }
        if let visibleCandidate = NSApp?.windows.first(where: { Self.isCandidateMainWindow($0) && $0.isVisible }) {
            visibleCandidate.isReleasedWhenClosed = false
            primaryWindow = visibleCandidate
            return visibleCandidate
        }
        if let found = NSApp?.windows.first(where: { Self.isCandidateMainWindow($0) }) {
            found.isReleasedWhenClosed = false
            primaryWindow = found
            return found
        }
        return nil
    }

    private static func isCandidateMainWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel) else { return false }
        guard window.styleMask.contains(.titled) else { return false }
        return window.canBecomeMain || window.contentView != nil
    }

    /// Restores (deminiaturizes / orders front) and activates the single main window without creating duplicates.
    @discardableResult
    func restoreOrActivateMainWindow(
        selectTab: AppNavigationTab? = nil,
        appState: AppState? = AppState.shared
    ) -> Bool {
        if let tab = selectTab {
            appState?.selectedTab = tab
        }
        NSApp?.activate(ignoringOtherApps: true)

        if let window = resolvePrimaryWindow() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            refreshWindowStateFlags()
            return true
        }
        refreshWindowStateFlags()
        return false
    }

    func handleWindowClose(_ window: NSWindow? = nil) {
        let target = window ?? resolvePrimaryWindow()
        target?.orderOut(nil)
        refreshWindowStateFlags()
    }

    func handleWindowMiniaturize(_ window: NSWindow? = nil) {
        let target = window ?? resolvePrimaryWindow()
        target?.miniaturize(nil)
        refreshWindowStateFlags()
    }

    func refreshWindowStateFlags() {
        let nextMiniaturized: Bool
        let nextVisible: Bool
        if let win = primaryWindow {
            nextMiniaturized = win.isMiniaturized
            nextVisible = win.isVisible && !win.isMiniaturized
        } else {
            nextMiniaturized = false
            nextVisible = false
        }
        if isMainWindowMiniaturized != nextMiniaturized {
            isMainWindowMiniaturized = nextMiniaturized
        }
        if isMainWindowVisible != nextVisible {
            isMainWindowVisible = nextVisible
        }
    }

    // MARK: - Termination Safety

    /// Determines whether closing the last window should terminate the application.
    /// Always protects active conversions; otherwise respects `settings.keepAppOpenAfterConversion`
    /// independently of `ApplicationVisibilityMode`.
    func shouldTerminateAfterLastWindowClosed(
        settings: AppSettings = .shared,
        appState: AppState? = AppState.shared
    ) -> Bool {
        if let appState, appState.isConverting || appState.activeJobCount > 0 {
            return false
        }
        return !settings.keepAppOpenAfterConversion
    }

    /// Invoked on `Cmd+Q` or `NSApplication.shared.terminate`.
    /// Flushes persistent undo/recovery journals and cleans temporary scratch files safely.
    func prepareForTermination(appState: AppState? = AppState.shared) {
        appState?.watchFolderManager.stopAll()
        appState?.conversionQueue.cancelAll()
        UndoRedoCoordinator.shared.flushPersistence()
        OutputManager.cleanupTemporaryFiles(in: FileManager.default.temporaryDirectory)
    }

    // MARK: - User Guidance for Both Icons Hidden

    static let bothIconsHiddenGuidance: String =
        "Both the Dock icon and Menu Bar icon are currently hidden. While LocalConvert stays open in the background, you can reopen its main window at any time by launching LocalConvert from Finder, Spotlight, or Launchpad. Press ⌘Q whenever you want to quit LocalConvert completely."

    // MARK: - Private Notifications

    private func installWindowNotifications() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let win = note.object as? NSWindow
                let noteName = note.name
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if noteName == NSWindow.didBecomeMainNotification, let win {
                        self.registerWindow(win)
                    }
                    self.refreshWindowStateFlags()
                }
            }
            windowObserverTokens.append(token)
        }
    }
}
