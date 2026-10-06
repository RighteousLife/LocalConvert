import SwiftUI
import AppKit

// MARK: - App Delegate for macOS Services & Open With

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var servicesProvider: ServicesProvider?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let provider = ServicesProvider()
        self.servicesProvider = provider
        NSApplication.shared.servicesProvider = provider
        NSUpdateDynamicServices()
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppState.shared?.addFiles(urls: urls)
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }
}

// MARK: - App Scene

@main
struct LocalConvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("settings.showMenuBarExtra") private var showMenuBarExtra: Bool = true
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .frame(minWidth: 640, minHeight: 520)
                .onAppear {
                    MenuBarManager.shared.setup(appState: appState)
                }
                .onOpenURL { url in
                    if url.scheme?.lowercased() == "localconvert" {
                        if case .success(let files) = FinderHandoffHandler.parseSchemeURL(url) {
                            appState.addFiles(urls: files)
                        }
                    } else if url.isFileURL {
                        appState.addFiles(urls: [url])
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 840, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files...") {
                    openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Button("Convert All") {
                    appState.convertAll()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appState.isConverting || appState.droppedFiles.isEmpty)
            }
            
            CommandMenu("Navigate") {
                Button("Convert") {
                    appState.selectedTab = .convert
                }
                .keyboardShortcut("1", modifiers: .command)
                
                Button("Jobs Center") {
                    appState.selectedTab = .jobs
                }
                .keyboardShortcut("2", modifiers: .command)
                
                Button("PDF Toolbox") {
                    appState.selectedTab = .pdfToolbox
                }
                .keyboardShortcut("3", modifiers: .command)
                
                Button("Metadata") {
                    appState.selectedTab = .metadata
                }
                .keyboardShortcut("4", modifiers: .command)
                
                Button("Presets") {
                    appState.selectedTab = .presets
                }
                .keyboardShortcut("5", modifiers: .command)
                
                Button("History") {
                    appState.selectedTab = .history
                }
                .keyboardShortcut("6", modifiers: .command)
                
                Divider()
                
                Button("Settings...") {
                    appState.selectedTab = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
    
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState.addFiles(urls: panel.urls)
            appState.selectedTab = .convert
        }
    }
}
