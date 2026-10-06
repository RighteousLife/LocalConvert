import SwiftUI
import AppKit

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        Group {
            Text("LocalConvert")
            
            if appState.isConverting {
                Text("\(appState.activeJobCount) conversions running · \(Int(appState.batchProgress * 100))%")
            } else if appState.isBatchCompleted {
                Text("All conversions completed")
            } else {
                Text("Ready")
            }
            
            Divider()
            
            Button("Open LocalConvert") {
                activateAppAndShowTab(.convert)
            }
            
            Button("Add Files to Convert...") {
                openFilePicker()
            }
            
            Divider()
            
            Button("Open Jobs Center") {
                activateAppAndShowTab(.jobs)
            }
            
            Button("Open Presets") {
                activateAppAndShowTab(.presets)
            }
            
            Button("Settings...") {
                activateAppAndShowTab(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
            
            Divider()
            
            Button("Quit LocalConvert") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
    
    private func activateAppAndShowTab(_ tab: AppNavigationTab) {
        NSApp.activate(ignoringOtherApps: true)
        appState.selectedTab = tab
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    private func openFilePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState.addFiles(urls: panel.urls)
            appState.selectedTab = .convert
            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - Native Menu Bar Status Item Manager

@MainActor
final class MenuBarManager: NSObject {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    private weak var appState: AppState?
    
    func setup(appState: AppState) {
        self.appState = appState
        
        let isTesting = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isTesting else { return }
        
        updateVisibility()
    }
    
    func updateVisibility() {
        let isTesting = NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isTesting else { return }
        
        if AppSettings.shared.showMenuBarExtra {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = statusItem?.button {
                    button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "LocalConvert")
                }
                rebuildMenu()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }
    
    func updateStatus() {
        guard let item = statusItem, let button = item.button, let appState = appState else { return }
        if appState.isConverting {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: "LocalConvert - Converting")
        } else {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "LocalConvert")
        }
        rebuildMenu()
    }
    
    private func rebuildMenu() {
        guard let item = statusItem, let appState = appState else { return }
        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "LocalConvert", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        let statusString: String
        if appState.isConverting {
            statusString = "\(appState.activeJobCount) conversions running · \(Int(appState.batchProgress * 100))%"
        } else if appState.isBatchCompleted {
            statusString = "All conversions completed"
        } else {
            statusString = "Ready"
        }
        let statusMenuItem = NSMenuItem(title: statusString, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let openItem = NSMenuItem(title: "Open LocalConvert", action: #selector(openMainApp), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        
        let addFilesItem = NSMenuItem(title: "Add Files to Convert...", action: #selector(openFilePicker), keyEquivalent: "")
        addFilesItem.target = self
        menu.addItem(addFilesItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let jobsItem = NSMenuItem(title: "Open Jobs Center", action: #selector(openJobsCenter), keyEquivalent: "")
        jobsItem.target = self
        menu.addItem(jobsItem)
        
        let presetsItem = NSMenuItem(title: "Open Presets", action: #selector(openPresets), keyEquivalent: "")
        presetsItem.target = self
        menu.addItem(presetsItem)
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit LocalConvert", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
    }
    
    @objc private func openMainApp() {
        activateAppAndShowTab(.convert)
    }
    
    @objc private func openFilePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState?.addFiles(urls: panel.urls)
            appState?.selectedTab = .convert
            showMainWindow()
        }
    }
    
    @objc private func openJobsCenter() {
        activateAppAndShowTab(.jobs)
    }
    
    @objc private func openPresets() {
        activateAppAndShowTab(.presets)
    }
    
    @objc private func openSettings() {
        activateAppAndShowTab(.settings)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func activateAppAndShowTab(_ tab: AppNavigationTab) {
        NSApp.activate(ignoringOtherApps: true)
        appState?.selectedTab = tab
        showMainWindow()
    }
    
    private func showMainWindow() {
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
