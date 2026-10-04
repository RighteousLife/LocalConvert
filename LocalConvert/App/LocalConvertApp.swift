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
}

// MARK: - App Scene

@main
struct LocalConvertApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 640, minHeight: 520)
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
            CommandGroup(replacing: .newItem) {}
        }
    }
}
