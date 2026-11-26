import SwiftUI

// MARK: - History View

struct HistoryView: View {
    @ObservedObject var historyManager = HistoryManager.shared
    @EnvironmentObject var appState: AppState
    
    @State private var searchText = ""
    @State private var categoryFilter: HistoryCategoryFilter = .all
    @State private var sourceFilter: HistorySourceFilter = .all
    @State private var watchFolderRuleFilterID: UUID? = nil
    @State private var watchFolderRuleFilterName: String? = nil
    @State private var showingClearAllAlert = false
    @State private var showingClearCompletedAlert = false
    @State private var showingClearFailedAlert = false
    
    private var filteredItems: [ConversionHistoryItem] {
        HistoryFilterEngine.filter(
            items: historyManager.items,
            category: categoryFilter,
            source: sourceFilter,
            watchFolderRuleID: watchFolderRuleFilterID,
            searchText: searchText
        )
    }
    
    private var recordCountSummary: String {
        historyManager.items.count == 1
            ? String(localized: "\(filteredItems.count) of 1 record")
            : String(localized: "\(filteredItems.count) of \(historyManager.items.count) records")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar / Action Header
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                        Text(recordCountSummary)
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text("Persistent archive of completed, failed, and cancelled conversions across sessions.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("history.surfaceDescription")

                        Spacer(minLength: AppTheme.Spacing.sm)

                        historyHeaderActionButtons
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Text(recordCountSummary)
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Spacer(minLength: 0)

                            historyHeaderActionButtons
                        }

                        Text("Persistent archive of completed, failed, and cancelled conversions across sessions.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("history.surfaceDescription")
                    }
                }
                
                // Category & Source Filters
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        categoryFilterPicker
                        sourceFilterPicker
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        categoryFilterPicker
                        sourceFilterPicker
                    }
                }

                if watchFolderRuleFilterID != nil {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        AppStatusBadge(
                            text: String(localized: "Rule: \(watchFolderRuleFilterName ?? String(localized: "Watch Folder"))"),
                            tint: AppTheme.Colors.info,
                            style: .rounded
                        )

                        Button("Clear Rule Filter") {
                            watchFolderRuleFilterID = nil
                            watchFolderRuleFilterName = nil
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Clear Watch Folder rule filter")
                        .accessibilityIdentifier("history.clearRuleFilter")

                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("history.ruleFilterChip")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.sm + 2)
            .background(AppTheme.Colors.subtleSurface)
            
            AppDivider()
            
            // Content
            if historyManager.items.isEmpty {
                emptyStateView
            } else if filteredItems.isEmpty {
                filteredEmptyStateView
            } else {
                List(filteredItems) { item in
                    HistoryRowView(item: item)
                        .listRowBackground(AppTheme.Colors.workspaceBackground)
                        .listRowSeparatorTint(AppTheme.Colors.divider)
                }
                .listStyle(.inset)
                .appWorkspaceSurface()
            }
        }
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search filename, format, preset, or source...")
        .onAppear {
            consumePendingNavigationFilters()
        }
        .onChange(of: appState.pendingHistoryNavigationNonce) { _, _ in
            consumePendingNavigationFilters()
        }
        .onChange(of: sourceFilter) { _, newValue in
            if newValue != .watchFolder && watchFolderRuleFilterID != nil {
                watchFolderRuleFilterID = nil
                watchFolderRuleFilterName = nil
            }
        }
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

    private var categoryFilterPicker: some View {
        Picker("Category", selection: $categoryFilter) {
            ForEach(HistoryCategoryFilter.allCases) { cat in
                Text(LocalizedStringKey(cat.rawValue)).tag(cat)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Filter conversion history category")
        .accessibilityIdentifier("history.categoryFilter")
    }

    private var sourceFilterPicker: some View {
        Picker("Source", selection: $sourceFilter) {
            ForEach(HistorySourceFilter.allCases) { source in
                Text(LocalizedStringKey(source.rawValue)).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Filter conversion history source")
        .accessibilityIdentifier("history.sourceFilter")
    }

    @ViewBuilder
    private var historyHeaderActionButtons: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                appState.selectedTab = .jobs
            } label: {
                Label("Jobs Center", systemImage: "list.bullet.rectangle")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help("View live and recent conversion jobs in Jobs Center")
            .accessibilityLabel("Open Jobs Center")
            .accessibilityIdentifier("history.openJobsCenter")

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
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Clear history options")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func consumePendingNavigationFilters() {
        guard let pendingSource = appState.pendingHistorySourceFilter else { return }
        categoryFilter = .all
        sourceFilter = pendingSource
        watchFolderRuleFilterID = appState.pendingHistoryWatchFolderRuleID
        watchFolderRuleFilterName = appState.pendingHistoryWatchFolderRuleName
        appState.pendingHistorySourceFilter = nil
        appState.pendingHistoryWatchFolderRuleID = nil
        appState.pendingHistoryWatchFolderRuleName = nil
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        AppEmptyStateView(
            icon: "clock.arrow.circlepath",
            title: String(localized: "No Conversion History"),
            subtitle: String(localized: "Completed and previous conversion jobs will appear here once you convert files."),
            primaryButtonTitle: String(localized: "Go to Convert"),
            primaryButtonIcon: "arrow.triangle.2.circlepath",
            onPrimaryAction: {
                appState.selectedTab = .convert
            }
        )
    }

    @ViewBuilder
    private var filteredEmptyStateView: some View {
        AppEmptyStateView(
            icon: "magnifyingglass",
            title: String(localized: "No Matching History Items"),
            subtitle: String(localized: "Try adjusting your search query, category, or source filter."),
            primaryButtonTitle: String(localized: "Reset Filters"),
            onPrimaryAction: {
                searchText = ""
                categoryFilter = .all
                sourceFilter = .all
                watchFolderRuleFilterID = nil
                watchFolderRuleFilterName = nil
            }
        )
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

    private var sourceTint: Color {
        switch item.source {
        case .manual: return .secondary
        case .watchFolder: return AppTheme.Colors.info
        case .unknown: return .secondary
        }
    }
    
    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            // Status Icon
            Group {
                switch item.status {
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.success)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.error)
                case .cancelled:
                    Image(systemName: "slash.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            
            // Details
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs + 1) {
                Text(item.inputFilename)
                    .font(AppTheme.Typography.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                let sizeSavings = item.status == .completed
                    ? SizeSavingsFormatter.format(inputBytes: item.inputSizeBytes, outputBytes: item.outputSizeBytes)
                    : nil

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.xs + 2) {
                        historyFormatAndSourceBadges
                        Text("•")
                            .foregroundStyle(.tertiary)
                        historyPresetAndDateMetadata
                        if let sizeSavings {
                            Text("•")
                                .foregroundStyle(.tertiary)
                            SizeSavingsBadge(summary: sizeSavings)
                                .accessibilityIdentifier("history.sizeSavingsBadge")
                        }
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs + 1) {
                        HStack(spacing: AppTheme.Spacing.xs + 2) {
                            historyFormatAndSourceBadges
                        }
                        HStack(spacing: AppTheme.Spacing.xs + 2) {
                            historyPresetAndDateMetadata
                            if let sizeSavings {
                                Text("•")
                                    .foregroundStyle(.tertiary)
                                SizeSavingsBadge(summary: sizeSavings)
                                    .accessibilityIdentifier("history.sizeSavingsBadge")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs + 1) {
                        HStack(spacing: AppTheme.Spacing.xs + 2) {
                            historyFormatAndSourceBadges
                        }
                        HStack(spacing: AppTheme.Spacing.xs + 2) {
                            historyPresetAndDateMetadata
                        }
                        if let sizeSavings {
                            SizeSavingsBadge(summary: sizeSavings)
                                .accessibilityIdentifier("history.sizeSavingsBadge")
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("history.row.\(item.inputFilename)")
            
            Spacer(minLength: AppTheme.Spacing.sm)
            
            // Actions
            HStack(spacing: AppTheme.Spacing.xs + 2) {
                if item.status == .completed, let outputURL = item.outputURL {
                    if hasOutputFile {
                        Button {
                            NSWorkspace.shared.open(outputURL)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                                .font(AppTheme.Typography.subheadline)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        }
                        .buttonStyle(.plain)
                        .help("Open output file")
                        .accessibilityLabel("Open output file")
                        
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                        } label: {
                            Image(systemName: "folder")
                                .font(AppTheme.Typography.subheadline)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                        .accessibilityLabel("Show output in Finder")
                        
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(outputURL.path, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(AppTheme.Typography.caption)
                                .frame(width: 24, height: 24)
                                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                        }
                        .buttonStyle(.plain)
                        .help("Copy output path")
                        .accessibilityLabel("Copy output path")
                    } else {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption2)
                            Text("File Missing")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
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
                            .font(AppTheme.Typography.caption)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Load source file into queue to convert again")
                    .accessibilityLabel(String(localized: "Repeat conversion for \(item.inputFilename)"))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
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
                    Label("Output file is no longer available.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
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

    private var localizedSourceBadgeText: String {
        if item.source == .watchFolder, let ruleName = item.watchFolderRuleName, !ruleName.isEmpty {
            return String(localized: "Watch Folder · \(ruleName)")
        }
        return String(localized: String.LocalizationValue(item.source.displayName))
    }

    @ViewBuilder
    private var historyFormatAndSourceBadges: some View {
        AppStatusBadge(
            text: "\(item.inputFormatName) → \(item.outputFormatName)",
            tint: .secondary,
            style: .rounded
        )

        let sourceDescription = String(localized: String.LocalizationValue(item.source.accessibilityDescription))
        AppStatusBadge(
            text: localizedSourceBadgeText,
            tint: sourceTint,
            style: .rounded
        )
        .help(item.source == .unknown ? String(localized: "Legacy history record created before source provenance was tracked.") : sourceDescription)
        .accessibilityHint(sourceDescription)
        .accessibilityIdentifier("history.sourceBadge.\(item.source.rawValue)")
    }

    @ViewBuilder
    private var historyPresetAndDateMetadata: some View {
        if let preset = item.presetName {
            AppStatusBadge(text: preset, tint: AppTheme.Colors.accent, style: .rounded)
            Text("•")
                .foregroundStyle(.tertiary)
        }

        Text(item.date.formatted(date: .abbreviated, time: .shortened))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
