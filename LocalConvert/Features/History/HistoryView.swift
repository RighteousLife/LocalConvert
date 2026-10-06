import SwiftUI

// MARK: - History Category Filter

enum HistoryCategoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case conversions = "Conversions"
    case pdfTools = "PDF Tools"
    case presets = "Presets"
    case failed = "Failed"
    
    var id: String { rawValue }
}

// MARK: - History View

struct HistoryView: View {
    @ObservedObject var historyManager = HistoryManager.shared
    @EnvironmentObject var appState: AppState
    
    @State private var searchText = ""
    @State private var categoryFilter: HistoryCategoryFilter = .all
    @State private var showingClearAllAlert = false
    @State private var showingClearCompletedAlert = false
    @State private var showingClearFailedAlert = false
    
    private var filteredItems: [ConversionHistoryItem] {
        historyManager.items.filter { item in
            // Category filter
            let matchesCategory: Bool
            switch categoryFilter {
            case .all:
                matchesCategory = true
            case .conversions:
                matchesCategory = item.presetName == nil && !(item.inputFormatName.lowercased() == "pdf" && item.outputFormatName.lowercased() == "pdf")
            case .pdfTools:
                matchesCategory = (item.inputFormatName.lowercased() == "pdf" && item.outputFormatName.lowercased() == "pdf") || (item.presetName?.lowercased().contains("pdf") ?? false)
            case .presets:
                matchesCategory = item.presetName != nil
            case .failed:
                matchesCategory = item.status == .failed || item.status == .cancelled
            }
            guard matchesCategory else { return false }
            
            // Search filter
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty { return true }
            
            return item.inputFilename.localizedCaseInsensitiveContains(query)
                || item.outputFilename.localizedCaseInsensitiveContains(query)
                || item.inputFormatName.localizedCaseInsensitiveContains(query)
                || item.outputFormatName.localizedCaseInsensitiveContains(query)
                || (item.presetName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar / Action Header
            VStack(spacing: 8) {
                HStack {
                    Text("\(filteredItems.count) of \(historyManager.items.count) record\(historyManager.items.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    if !historyManager.items.isEmpty {
                        Menu {
                            Button(role: .destructive, action: {
                                let count = historyManager.items.filter { $0.status == .failed || $0.status == .cancelled }.count
                                if count > 1 {
                                    showingClearFailedAlert = true
                                } else {
                                    historyManager.clearFailed()
                                }
                            }) {
                                Label("Clear Failed", systemImage: "xmark.circle")
                            }
                            Button(role: .destructive, action: {
                                let count = historyManager.items.filter { $0.status == .completed }.count
                                if count > 1 {
                                    showingClearCompletedAlert = true
                                } else {
                                    historyManager.clearCompleted()
                                }
                            }) {
                                Label("Clear Completed", systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button(role: .destructive, action: {
                                if historyManager.items.count > 1 {
                                    showingClearAllAlert = true
                                } else {
                                    historyManager.clearHistory()
                                }
                            }) {
                                Label("Clear All History", systemImage: "trash")
                            }
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Clear history options")
                    }
                }
                
                // Category Filter Tabs
                Picker("Category", selection: $categoryFilter) {
                    ForEach(HistoryCategoryFilter.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            
            Divider()
            
            // Content
            if historyManager.items.isEmpty {
                emptyStateView
            } else if filteredItems.isEmpty {
                filteredEmptyStateView
            } else {
                List(filteredItems) { item in
                    HistoryRowView(item: item)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search filename, format, or preset...")
        .frame(minWidth: 500, minHeight: 400)
        .alert("Clear All History", isPresented: $showingClearAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                historyManager.clearHistory()
            }
        } message: {
            Text("Remove all \(historyManager.items.count) items from conversion history?")
        }
        .alert("Clear Completed History", isPresented: $showingClearCompletedAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                historyManager.clearCompleted()
            }
        } message: {
            let count = historyManager.items.filter { $0.status == .completed }.count
            Text("Remove \(count) completed items from conversion history?")
        }
        .alert("Clear Failed History", isPresented: $showingClearFailedAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                historyManager.clearFailed()
            }
        } message: {
            let count = historyManager.items.filter { $0.status == .failed || $0.status == .cancelled }.count
            Text("Remove \(count) failed items from conversion history?")
        }
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 4) {
                Text("No Conversion History")
                    .font(.headline)
                Text("Completed and previous conversion jobs will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
    
    @ViewBuilder
    private var filteredEmptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 4) {
                Text("No Matching History Items")
                    .font(.headline)
                Text("Try adjusting your search query or category filter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Button("Reset Filters") {
                searchText = ""
                categoryFilter = .all
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - History Row View

struct HistoryRowView: View {
    let item: ConversionHistoryItem
    @EnvironmentObject var appState: AppState
    
    private var hasOutputFile: Bool {
        guard let url = item.outputURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    private var hasInputFile: Bool {
        guard let url = item.inputURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Status Icon
            Group {
                switch item.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .cancelled:
                    Image(systemName: "slash.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            
            // Details
            VStack(alignment: .leading, spacing: 3) {
                Text(item.inputFilename)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack(spacing: 6) {
                    Text("\(item.inputFormatName) → \(item.outputFormatName)")
                        .fontWeight(.medium)
                    
                    Text("•")
                        .foregroundStyle(.tertiary)
                    
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    
                    if let preset = item.presetName {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text(preset)
                    }
                    
                    if let inBytes = item.inputSizeBytes, let outBytes = item.outputSizeBytes, inBytes > 0, outBytes > 0 {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        let inFormatted = ByteCountFormatter.string(fromByteCount: inBytes, countStyle: .file)
                        let outFormatted = ByteCountFormatter.string(fromByteCount: outBytes, countStyle: .file)
                        let diff = inBytes - outBytes
                        if diff > 0 {
                            let reduction = Int(round(Double(diff) / Double(inBytes) * 100.0))
                            Text("\(inFormatted) → \(outFormatted) (-\(reduction)%)")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(inFormatted) → \(outFormatted)")
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 6) {
                if item.status == .completed, let outputURL = item.outputURL {
                    if hasOutputFile {
                        Button {
                            NSWorkspace.shared.open(outputURL)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .help("Open output file")
                        .accessibilityLabel("Open output file")
                        
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                        .accessibilityLabel("Show output in Finder")
                        
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(outputURL.path, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help("Copy output path")
                        .accessibilityLabel("Copy output path")
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption2)
                            Text("File Missing")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .help("Output file is no longer available.")
                    }
                }
                
                // Repeat action if source file exists
                if hasInputFile, let inputURL = item.inputURL {
                    Button {
                        appState.handleDroppedURLs([inputURL])
                        appState.selectedTab = .convert
                    } label: {
                        Label("Repeat", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Load source file into queue to convert again")
                    .accessibilityLabel("Repeat conversion for \(item.inputFilename)")
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if item.status == .completed, let url = item.outputURL {
                if hasOutputFile {
                    Button("Open Output File") {
                        NSWorkspace.shared.open(url)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Copy Output Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.path, forType: .string)
                    }
                } else {
                    Button("Output file is no longer available.") { }
                        .disabled(true)
                }
            }
            if item.status == .failed {
                Button("Copy Error Details") {
                    let details = [
                        "--- LocalConvert History Error ---",
                        "File: \(item.inputFilename)",
                        "Format: \(item.inputFormatName) → \(item.outputFormatName)",
                        "Date: \(item.date.formatted(date: .abbreviated, time: .standard))",
                        "Error: \(item.errorMessage ?? "Conversion failed")",
                        "----------------------------------"
                    ].joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ErrorDetailsFormatter.sanitize(details), forType: .string)
                }
            }
            if let inURL = item.inputURL, hasInputFile {
                Button("Reveal Source in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([inURL])
                }
                Button("Copy Source Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(inURL.path, forType: .string)
                }
                Divider()
                Button("Repeat Conversion") {
                    appState.handleDroppedURLs([inURL])
                    appState.selectedTab = .convert
                }
            }
        }
    }
}
