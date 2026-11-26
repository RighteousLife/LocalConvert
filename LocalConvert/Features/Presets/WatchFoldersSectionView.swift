import SwiftUI
import AppKit

// MARK: - Watch Folders Section View

struct WatchFoldersSectionView: View {
    @ObservedObject var manager: WatchFolderManager
    @ObservedObject var presetManager: PresetManager = .shared
    @EnvironmentObject var appState: AppState

    @State private var selectedRuleID: UUID?
    @State private var isShowingAddSheet = false
    @State private var ruleToEdit: WatchFolderRule?
    @State private var ruleToDelete: WatchFolderRule?
    @State private var showDeleteConfirmation = false
    @State private var actionFeedbackMessage: String?

    private var selectedRule: WatchFolderRule? {
        guard let selectedRuleID else { return manager.rules.first }
        return manager.rules.first { $0.id == selectedRuleID } ?? manager.rules.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if manager.isGloballyPaused && !manager.rules.isEmpty {
                AppInfoBanner(
                    style: .warning,
                    message: "All Watch Folders are paused globally. New files will not be processed until resumed.",
                    actionTitle: "Resume All",
                    onAction: { manager.resumeAll() }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.sm)
                AppDivider()
            }

            if manager.rules.isEmpty {
                    AppEmptyStateView(
                        icon: "folder.badge.gearshape",
                        title: "No Watch Folders Configured",
                        subtitle: "Monitor local folders and automatically convert newly added files using any saved preset.",
                        primaryButtonTitle: "Add Watch Folder...",
                        primaryButtonIcon: "plus",
                        onPrimaryAction: { isShowingAddSheet = true }
                    )
                    .accessibilityIdentifier("watchfolders.emptyState")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .appWorkspaceSurface()
            } else {
                HSplitView {
                    ruleListColumn
                        .frame(
                            minWidth: AppTheme.Layout.toolboxSidebarMin,
                            idealWidth: AppTheme.Layout.toolboxSidebarIdeal,
                            maxWidth: AppTheme.Layout.toolboxSidebarMax
                        )
                        .appSecondarySidebarSurface()

                    Group {
                        if let rule = selectedRule {
                            ruleDetailView(rule)
                        } else {
                            AppEmptyStateView(
                                icon: "folder.badge.gearshape",
                                title: "Select a Watch Folder",
                                subtitle: "Choose a Watch Folder rule on the left to inspect its settings and recent file activity."
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .appWorkspaceSurface()
                }
            }
        }
        .onAppear {
            if selectedRuleID == nil {
                selectedRuleID = manager.rules.first?.id
            }
        }
        .onChange(of: manager.rules) { _, newRules in
            if let id = selectedRuleID, !newRules.contains(where: { $0.id == id }) {
                selectedRuleID = newRules.first?.id
            } else if selectedRuleID == nil {
                selectedRuleID = newRules.first?.id
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            WatchFolderEditSheetView(
                existingRule: nil,
                manager: manager,
                presetManager: presetManager,
                defaultOutputLocation: appState.outputLocation,
                customAppOutputDirectory: appState.customOutputDirectory
            ) { savedRule in
                selectedRuleID = savedRule.id
            }
        }
        .sheet(item: $ruleToEdit) { editingRule in
            WatchFolderEditSheetView(
                existingRule: editingRule,
                manager: manager,
                presetManager: presetManager,
                defaultOutputLocation: appState.outputLocation,
                customAppOutputDirectory: appState.customOutputDirectory
            ) { savedRule in
                selectedRuleID = savedRule.id
            }
        }
        .confirmationDialog(
            "Delete Watch Folder Rule?",
            isPresented: $showDeleteConfirmation,
            presenting: ruleToDelete
        ) { rule in
            Button("Remove '\(rule.name)'", role: .destructive) {
                manager.removeRule(id: rule.id)
                if selectedRuleID == rule.id {
                    selectedRuleID = manager.rules.first?.id
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { rule in
            Text("Removing this rule stops monitoring '\(rule.inputDirectoryURL.lastPathComponent)'. Your existing files on disk will not be modified.")
        }
    }


    // MARK: - Rule List Column

    private var ruleListColumn: some View {
        VStack(spacing: 0) {
            List(selection: $selectedRuleID) {
                Section("Watch Folders (\(manager.rules.count))") {
                    ForEach(manager.rules) { rule in
                        WatchFolderRuleRow(
                            rule: rule,
                            presetName: presetName(for: rule.presetID),
                            isGloballyPaused: manager.isGloballyPaused
                        )
                        .tag(rule.id)
                        .contextMenu {
                            Button(rule.isEnabled ? "Disable" : "Enable") {
                                _ = manager.setEnabled(!rule.isEnabled, for: rule.id)
                            }
                            if rule.isEnabled {
                                Button(rule.isPaused ? "Resume" : "Pause") {
                                    manager.setPaused(!rule.isPaused, for: rule.id)
                                }
                                Button("Scan Now") {
                                    manager.rescanRule(id: rule.id)
                                }
                            }
                            Button("Edit...") {
                                ruleToEdit = rule
                            }
                            Divider()
                            Button("Remove", role: .destructive) {
                                ruleToDelete = rule
                                showDeleteConfirmation = true
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .appSecondarySidebarSurface()

            AppDivider()

            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: { isShowingAddSheet = true }) {
                    Label("Add Watch Folder", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Add Watch Folder")

                Spacer()

                Button(action: {
                    if manager.isGloballyPaused {
                        manager.resumeAll()
                    } else {
                        manager.pauseAll()
                    }
                }) {
                    Image(systemName: manager.isGloballyPaused ? "play.circle" : "pause.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(manager.isGloballyPaused ? "Resume all watch folders" : "Pause all watch folders")
                .accessibilityLabel(manager.isGloballyPaused ? "Resume all watch folders" : "Pause all watch folders")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }


    // MARK: - Rule Detail View

    private func ruleDetailView(_ rule: WatchFolderRule) -> some View {
        let ruleRecords = manager.records.filter { $0.ruleID == rule.id }
        let liveValidation = WatchFolderValidator.validate(
            rule: rule,
            existingRules: manager.rules,
            availablePresets: presetManager.presets,
            defaultOutputLocation: appState.outputLocation,
            customAppOutputDirectory: appState.customOutputDirectory
        )

        return VStack(spacing: 0) {
            detailHeader(rule: rule)
            AppDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    if let errorMsg = rule.lastStatus.errorMessage ?? rule.lastErrorMessage {
                        AppInfoBanner(style: .error, message: errorMsg)
                    } else if let warning = liveValidation.warningMessage {
                        AppInfoBanner(style: .warning, message: warning)
                    }

                    if let feedback = actionFeedbackMessage {
                        AppInfoBanner(
                            style: .info,
                            message: feedback,
                            onDismiss: { actionFeedbackMessage = nil }
                        )
                    }

                    configurationCard(rule: rule)
                    activitySection(rule: rule, records: ruleRecords)
                }
                .padding(AppTheme.Spacing.xl)
            }
        }
    }


    private func detailHeader(rule: WatchFolderRule) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                detailHeaderTitleBlock(rule: rule)
                Spacer(minLength: AppTheme.Spacing.sm)
                detailHeaderActions(rule: rule)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                    Text(rule.name)
                        .font(AppTheme.Typography.pageTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    statusBadge(for: rule)

                    Spacer(minLength: 0)
                }

                HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                    Text(rule.inputDirectoryPath)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: AppTheme.Spacing.sm)

                    detailHeaderActions(rule: rule)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.sm + 2)
        .background(AppTheme.Colors.subtleSurface)
    }

    @ViewBuilder
    private func detailHeaderTitleBlock(rule: WatchFolderRule) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                Text(rule.name)
                    .font(AppTheme.Typography.pageTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                statusBadge(for: rule)
            }

            Text(rule.inputDirectoryPath)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }


    @ViewBuilder
    private func detailHeaderActions(rule: WatchFolderRule) -> some View {
        HStack(spacing: 6) {
            Toggle("Enabled", isOn: Binding(
                get: { rule.isEnabled },
                set: { newValue in
                    if let result = manager.setEnabled(newValue, for: rule.id), !result.isValid {
                        actionFeedbackMessage = result.errorMessage
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(rule.isEnabled ? "Disable Watch Folder" : "Enable Watch Folder")
            .accessibilityLabel("Enable watch folder \(rule.name)")

            if rule.isEnabled {
                Button(rule.isPaused ? "Resume" : "Pause") {
                    manager.setPaused(!rule.isPaused, for: rule.id)
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(manager.isGloballyPaused)
                .accessibilityLabel(rule.isPaused ? "Resume watch folder \(rule.name)" : "Pause watch folder \(rule.name)")

                Button("Scan Now") {
                    manager.rescanRule(id: rule.id)
                    actionFeedbackMessage = "Scanning '\(rule.inputDirectoryURL.lastPathComponent)' for convertible files..."
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(manager.isGloballyPaused || rule.isPaused)
                .accessibilityLabel("Scan \(rule.name) now")
            }

            Button("Edit...") {
                ruleToEdit = rule
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)

            Button(role: .destructive) {
                ruleToDelete = rule
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Delete watch folder \(rule.name)")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func configurationCard(rule: WatchFolderRule) -> some View {
        let preset = presetManager.presets.first { $0.id == rule.presetID }
        let resolvedOutput = rule.outputDestination.resolvedDirectory(
            for: rule.inputDirectoryURL,
            preset: preset,
            defaultOutputLocation: appState.outputLocation,
            customAppOutputDirectory: appState.customOutputDirectory
        )

        return AppCard(title: "Rule Configuration", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                configRow(label: "Watched Folder", value: rule.inputDirectoryPath) {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([rule.inputDirectoryURL])
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                }

                configRow(
                    label: "Preset",
                    value: preset.map { "\($0.name) (\($0.targetFormat.displayName))" } ?? "Missing Preset"
                )

                configRow(
                    label: "Output Folder",
                    value: "\(rule.outputDestination.displayName) — \(resolvedOutput.path)"
                )

                configRow(label: "Collision Policy", value: rule.collisionPolicy.rawValue)

                configRow(
                    label: "Subdirectories",
                    value: rule.includeSubdirectories ? "Included recursively" : "Top-level folder only"
                )

                configRow(
                    label: "Write Settle Delay",
                    value: String(format: "%.1f s", rule.settleDelaySeconds)
                )

                if let lastExec = rule.lastExecutionAt {
                    configRow(
                        label: "Last Processed",
                        value: lastExec.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
        }
    }


    private func configRow<Trailing: View>(
        label: String,
        value: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.md) {
            Text(label)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(AppTheme.Typography.body)
                .textSelection(.enabled)
                .lineLimit(2)

            Spacer(minLength: 0)

            trailing()
        }
    }


    // MARK: - Activity Section

    private func activitySection(rule: WatchFolderRule, records: [WatchFolderFileRecord]) -> some View {
        AppCard(title: "Folder Monitoring Activity (\(records.count))", icon: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                        Text("Tracks file detection, write stability checks, and queueing for this rule. Conversion outcomes are saved separately in Conversion History.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("watchfolders.activityDescription")

                        Spacer(minLength: AppTheme.Spacing.sm)

                        activitySectionActions(rule: rule, records: records)
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                        Text("Tracks file detection, write stability checks, and queueing for this rule. Conversion outcomes are saved separately in Conversion History.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("watchfolders.activityDescription")

                        HStack(spacing: AppTheme.Spacing.sm) {
                            activitySectionActions(rule: rule, records: records)
                            Spacer(minLength: 0)
                        }
                    }
                }

                if records.isEmpty {
                    Text("No files detected for this rule yet. Drop a supported file into '\(rule.inputDirectoryURL.lastPathComponent)' or click Scan Now.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, AppTheme.Spacing.sm)
                } else {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(records.prefix(50)) { record in
                            WatchFolderActivityRow(
                                record: record,
                                onRetry: { manager.retryRecord(id: record.id) },
                                onOpenHistory: record.jobID != nil && (record.state == .completed || record.state == .failed) ? {
                                    appState.openConversionHistory(
                                        sourceFilter: .watchFolder,
                                        watchFolderRuleID: rule.id,
                                        watchFolderRuleName: rule.name
                                    )
                                } : nil
                            )
                            if record.id != records.prefix(50).last?.id {
                                AppDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activitySectionActions(rule: WatchFolderRule, records: [WatchFolderFileRecord]) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                appState.openConversionHistory(
                    sourceFilter: .watchFolder,
                    watchFolderRuleID: rule.id,
                    watchFolderRuleName: rule.name
                )
            } label: {
                Label("View in Conversion History", systemImage: "clock")
                    .lineLimit(1)
            }
            .controlSize(.mini)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help("View Watch Folder conversion records for '\(rule.name)' in Conversion History")
            .accessibilityLabel("View conversion history for \(rule.name)")
            .accessibilityIdentifier("watchfolders.viewConversionHistory")

            if !records.isEmpty {
                Button("Clear Activity") {
                    manager.clearRecords(for: rule.id)
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Clear monitoring activity for \(rule.name)")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }


    // MARK: - Status Helpers

    private func statusBadge(for rule: WatchFolderRule) -> some View {
        let effectiveStatus: WatchFolderMonitoringStatus = {
            if !rule.isEnabled { return .disabled }
            if manager.isGloballyPaused || rule.isPaused { return .paused }
            return rule.lastStatus
        }()

        let tint: Color = {
            switch effectiveStatus {
            case .active: return AppTheme.Colors.success
            case .paused: return AppTheme.Colors.warning
            case .disabled: return .secondary
            case .error: return AppTheme.Colors.error
            }
        }()

        return AppStatusBadge(text: effectiveStatus.displayLabel, tint: tint)
    }

    private func presetName(for presetID: UUID) -> String {
        presetManager.presets.first { $0.id == presetID }?.name ?? "Missing Preset"
    }
}

// MARK: - Rule Sidebar Row

private struct WatchFolderRuleRow: View {
    let rule: WatchFolderRule
    let presetName: String
    let isGloballyPaused: Bool

    @Environment(\.backgroundProminence) private var backgroundProminence

    private var effectiveBadgeText: String {
        if !rule.isEnabled { return "Disabled" }
        if isGloballyPaused || rule.isPaused { return "Paused" }
        return rule.lastStatus.shortBadgeText
    }

    private var effectiveTint: Color {
        if !rule.isEnabled { return .secondary }
        if isGloballyPaused || rule.isPaused { return AppTheme.Colors.warning }
        switch rule.lastStatus {
        case .active: return AppTheme.Colors.success
        case .paused: return AppTheme.Colors.warning
        case .disabled: return .secondary
        case .error: return AppTheme.Colors.error
        }
    }


    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(backgroundProminence == .increased ? Color.white : effectiveTint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(rule.name)
                        .font(.body)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    AppStatusBadge(
                        text: effectiveBadgeText,
                        tint: backgroundProminence == .increased ? .white : effectiveTint
                    )
                }

                Text("\(rule.inputDirectoryURL.lastPathComponent) · \(presetName)")
                    .font(.caption2)
                    .foregroundStyle(backgroundProminence == .increased ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rule.name), \(effectiveBadgeText), preset \(presetName)")
    }
}

// MARK: - Activity Row

private struct WatchFolderActivityRow: View {
    let record: WatchFolderFileRecord
    let onRetry: () -> Void
    var onOpenHistory: (() -> Void)? = nil

    private var stateTint: Color {
        switch record.state {
        case .pending, .stabilizing, .queued: return .secondary
        case .processing: return AppTheme.Colors.accent
        case .completed: return AppTheme.Colors.success
        case .failed: return AppTheme.Colors.error
        case .ignored: return AppTheme.Colors.warning
        }
    }


    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(record.fileName)
                        .font(AppTheme.Typography.body)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    AppStatusBadge(text: record.state.rawValue, tint: stateTint)
                }

                if let reason = record.reason, !reason.isEmpty {
                    Text(reason)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !record.outputPaths.isEmpty {
                    Text("Output: \(record.outputPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text(record.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if let onOpenHistory {
                Button("History") {
                    onOpenHistory()
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .help("Open Watch Folder conversion records in Conversion History")
                .accessibilityLabel("Open conversion history for \(record.fileName)")
                .accessibilityIdentifier("watchfolders.row.openHistory")
            }

            if record.canRetry {
                Button("Retry") {
                    onRetry()
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Retry \(record.fileName)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Add / Edit Rule Sheet

struct WatchFolderEditSheetView: View {
    enum OutputMode: String, CaseIterable, Identifiable {
        case subfolder = "Subfolder inside Watched Folder"
        case customDirectory = "Custom Output Folder"
        case presetDefault = "Preset / App Default"

        var id: String { rawValue }
    }

    let existingRule: WatchFolderRule?
    @ObservedObject var manager: WatchFolderManager
    @ObservedObject var presetManager: PresetManager
    let defaultOutputLocation: OutputLocation
    let customAppOutputDirectory: URL?
    let onSaved: (WatchFolderRule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var inputDirectoryPath: String = ""
    @State private var inputBookmarkData: Data?
    @State private var selectedPresetID: UUID = UUID()
    @State private var outputMode: OutputMode = .subfolder
    @State private var subfolderName: String = "Converted"
    @State private var customOutputPath: String = ""
    @State private var customOutputBookmarkData: Data?
    @State private var collisionPolicy: ExistingFileHandling = .createUnique
    @State private var includeSubdirectories: Bool = false
    @State private var settleDelaySeconds: TimeInterval = 1.5
    @State private var isEnabled: Bool = true
    @State private var saveErrorMessage: String?

    init(
        existingRule: WatchFolderRule?,
        manager: WatchFolderManager,
        presetManager: PresetManager,
        defaultOutputLocation: OutputLocation,
        customAppOutputDirectory: URL?,
        onSaved: @escaping (WatchFolderRule) -> Void
    ) {
        self.existingRule = existingRule
        self.manager = manager
        self.presetManager = presetManager
        self.defaultOutputLocation = defaultOutputLocation
        self.customAppOutputDirectory = customAppOutputDirectory
        self.onSaved = onSaved

        let initialPresetID = existingRule?.presetID ?? presetManager.presets.first?.id ?? UUID()
        _name = State(initialValue: existingRule?.name ?? "")
        _inputDirectoryPath = State(initialValue: existingRule?.inputDirectoryPath ?? "")
        _inputBookmarkData = State(initialValue: existingRule?.inputBookmarkData)
        _selectedPresetID = State(initialValue: initialPresetID)
        _collisionPolicy = State(initialValue: existingRule?.collisionPolicy ?? .createUnique)
        _includeSubdirectories = State(initialValue: existingRule?.includeSubdirectories ?? false)
        _settleDelaySeconds = State(initialValue: existingRule?.settleDelaySeconds ?? 1.5)
        _isEnabled = State(initialValue: existingRule?.isEnabled ?? true)

        switch existingRule?.outputDestination ?? .defaultSubfolder {
        case .subfolder(let folderName):
            _outputMode = State(initialValue: .subfolder)
            _subfolderName = State(initialValue: folderName)
        case .customDirectory(let path, let bookmark):
            _outputMode = State(initialValue: .customDirectory)
            _customOutputPath = State(initialValue: path)
            _customOutputBookmarkData = State(initialValue: bookmark)
        case .presetDefault:
            _outputMode = State(initialValue: .presetDefault)
        }
    }


    private var candidateRule: WatchFolderRule {
        let resolvedDestination: WatchFolderOutputDestination = {
            switch outputMode {
            case .subfolder:
                return .subfolder(name: subfolderName)
            case .customDirectory:
                return .customDirectory(path: customOutputPath, bookmarkData: customOutputBookmarkData)
            case .presetDefault:
                return .presetDefault
            }
        }()

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = inputDirectoryPath.isEmpty
            ? "New Watch Folder"
            : URL(fileURLWithPath: inputDirectoryPath).lastPathComponent

        return WatchFolderRule(
            id: existingRule?.id ?? UUID(),
            name: trimmedName.isEmpty ? fallbackName : trimmedName,
            inputDirectoryPath: inputDirectoryPath,
            inputBookmarkData: inputBookmarkData,
            presetID: selectedPresetID,
            isEnabled: isEnabled,
            isPaused: existingRule?.isPaused ?? false,
            includeSubdirectories: includeSubdirectories,
            outputDestination: resolvedDestination,
            collisionPolicy: collisionPolicy,
            settleDelaySeconds: settleDelaySeconds,
            maxStabilityWaitSeconds: existingRule?.maxStabilityWaitSeconds ?? 30.0,
            createdAt: existingRule?.createdAt ?? Date(),
            modifiedAt: Date(),
            lastExecutionAt: existingRule?.lastExecutionAt,
            lastStatus: existingRule?.lastStatus ?? .disabled,
            lastErrorMessage: nil
        )
    }

    private var validationResult: WatchFolderValidationResult {
        WatchFolderValidator.validate(
            rule: candidateRule,
            existingRules: manager.rules,
            availablePresets: presetManager.presets,
            defaultOutputLocation: defaultOutputLocation,
            customAppOutputDirectory: customAppOutputDirectory
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingRule == nil ? "New Watch Folder" : "Edit Watch Folder")
                    .font(AppTheme.Typography.pageTitle)
                Spacer()
            }
            .padding(AppTheme.Spacing.lg)

            AppDivider()

            Form {
                Section("Rule & Source Folder") {
                    TextField("Rule Name", text: $name)
                        .accessibilityLabel("Watch folder rule name")

                    HStack {
                        Text(inputDirectoryPath.isEmpty ? "No folder selected" : inputDirectoryPath)
                            .foregroundStyle(inputDirectoryPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Choose Folder...") {
                            chooseInputDirectory()
                        }
                        .accessibilityLabel("Choose watched input folder")
                    }

                    Toggle("Include subdirectories recursively", isOn: $includeSubdirectories)
                    Toggle("Enable rule immediately", isOn: $isEnabled)
                }

                Section("Preset & Output") {
                    Picker("Preset", selection: $selectedPresetID) {
                        ForEach(presetManager.presets) { preset in
                            Text("\(preset.name) (\(preset.targetFormat.displayName))")
                                .tag(preset.id)
                        }
                    }

                    Picker("Output Destination", selection: $outputMode) {
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    if outputMode == .subfolder {
                        TextField("Subfolder Name", text: $subfolderName)
                            .accessibilityLabel("Output subfolder name")
                    } else if outputMode == .customDirectory {
                        HStack {
                            Text(customOutputPath.isEmpty ? "No output folder selected" : customOutputPath)
                                .foregroundStyle(customOutputPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button("Choose Output...") {
                                chooseCustomOutputDirectory()
                            }
                            .accessibilityLabel("Choose custom output folder")
                        }
                    }

                    Picker("If Output Exists", selection: $collisionPolicy) {
                        ForEach(ExistingFileHandling.allCases, id: \.self) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                }

                Section("Write Stability") {
                    Picker("Wait After Last Write", selection: $settleDelaySeconds) {
                        Text("0.5 seconds (fast local copy)").tag(0.5 as TimeInterval)
                        Text("1.5 seconds (Recommended)").tag(1.5 as TimeInterval)
                        Text("3.0 seconds (large media exports)").tag(3.0 as TimeInterval)
                        Text("5.0 seconds (slow / synced folders)").tag(5.0 as TimeInterval)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMsg = saveErrorMessage ?? (!inputDirectoryPath.isEmpty ? validationResult.errorMessage : nil) {
                AppInfoBanner(style: .error, message: errorMsg)
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.bottom, AppTheme.Spacing.sm)
            } else if let warning = validationResult.warningMessage, !inputDirectoryPath.isEmpty {
                AppInfoBanner(style: .warning, message: warning)
                    .padding(.horizontal, AppTheme.Spacing.lg)
                    .padding(.bottom, AppTheme.Spacing.sm)
            }

            AppDivider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("watchfolders.sheet.cancel")

                Button(existingRule == nil ? "Add Watch Folder" : "Save Changes") {
                    saveRule()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(inputDirectoryPath.isEmpty || !validationResult.isValid)
                .accessibilityIdentifier("watchfolders.sheet.save")
            }
            .padding(AppTheme.Spacing.lg)
        }
        .frame(width: 560, height: 520)
    }

    private func chooseInputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Watch Folder"
        if panel.runModal() == .OK, let url = panel.url {
            inputDirectoryPath = url.standardizedFileURL.path
            inputBookmarkData = WatchFolderBookmarkManager.createBookmark(for: url)
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = url.lastPathComponent
            }
            saveErrorMessage = nil
        }
    }


    private func chooseCustomOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Output Folder"
        if panel.runModal() == .OK, let url = panel.url {
            customOutputPath = url.standardizedFileURL.path
            customOutputBookmarkData = WatchFolderBookmarkManager.createBookmark(for: url)
            saveErrorMessage = nil
        }
    }


    private func saveRule() {
        let rule = candidateRule
        let result = existingRule == nil
            ? manager.addRule(rule)
            : manager.updateRule(rule)

        if result.isValid {
            onSaved(rule)
            dismiss()
        } else {
            saveErrorMessage = result.errorMessage ?? "Unable to save Watch Folder rule."
        }
    }

}
