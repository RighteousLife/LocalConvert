import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if appState.droppedFiles.isEmpty {
                DropZoneView()
            } else {
                FileListView()
            }
        }
        .navigationTitle("LocalConvert")
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
}

// MARK: - Sidebar

struct SidebarView: View {
    var body: some View {
        List {
            NavigationLink {
                // Main Convert View
            } label: {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            
            NavigationLink {
                Text("Conversion history will appear here in future updates.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } label: {
                Label("History", systemImage: "clock")
            }
            
            NavigationLink {
                Text("Settings will appear here in future updates.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } label: {
                Label("Settings", systemImage: "gear")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 190)
    }
}
