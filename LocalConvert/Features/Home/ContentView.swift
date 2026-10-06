import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
        .navigationTitle(appState.selectedTab.rawValue)
        .alert("Notice", isPresented: $appState.showError) {
            Button("OK") {}
        } message: {
            if let details = appState.errorDetails, !details.isEmpty {
                Text("\(appState.errorMessage)\n\n\(details)")
            } else {
                Text(appState.errorMessage)
            }
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedTab {
        case .convert:
            if appState.droppedFiles.isEmpty {
                DropZoneView()
            } else {
                FileListView()
            }
        case .jobs:
            JobsCenterView()
        case .pdfToolbox:
            PDFToolboxView()
        case .metadata:
            MetadataView()
        case .presets:
            PresetManagerView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    
    private var activeJobCount: Int {
        appState.conversionManager.runningOrWaitingCount
    }
    
    var body: some View {
        List(AppNavigationTab.allCases, id: \.self, selection: Binding(
            get: { appState.selectedTab },
            set: { if let newTab = $0 { appState.selectedTab = newTab } }
        )) { tab in
            Label(tab.rawValue, systemImage: tab.iconName)
                .badge(tab == .jobs && activeJobCount > 0 ? activeJobCount : 0)
                .tag(tab)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
    }
}
