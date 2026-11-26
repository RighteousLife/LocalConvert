import SwiftUI
import AppKit

private enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general = "General"
    case output = "Output"
    case automation = "Automation"
    case shortcuts = "Shortcuts"
    case advanced = "Advanced"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .output: return "folder"
        case .automation: return "bell.badge"
        case .shortcuts: return "keyboard"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var showingLicensesSheet = false
    @State private var showingFormatsSheet = false

    var body: some View {
        TabView(selection: $selectedTab) {
            settingsTabForm {
                GeneralSettingsSection()
                AboutSettingsSection(
                    showingLicensesSheet: $showingLicensesSheet,
                    showingFormatsSheet: $showingFormatsSheet
                )
            }
            .tabItem {
                Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.systemImage)
            }
            .tag(SettingsTab.general)

            settingsTabForm {
                OutputFilesSettingsSection()
                ConversionDefaultsSettingsSection()
            }
            .tabItem {
                Label(SettingsTab.output.rawValue, systemImage: SettingsTab.output.systemImage)
            }
            .tag(SettingsTab.output)

            settingsTabForm {
                NotificationsSettingsSection()
                JobsHistorySettingsSection()
            }
            .tabItem {
                Label(SettingsTab.automation.rawValue, systemImage: SettingsTab.automation.systemImage)
            }
            .tag(SettingsTab.automation)

            settingsTabForm {
                KeyboardShortcutsSettingsSection()
            }
            .tabItem {
                Label(SettingsTab.shortcuts.rawValue, systemImage: SettingsTab.shortcuts.systemImage)
            }
            .tag(SettingsTab.shortcuts)

            settingsTabForm {
                PerformanceSettingsSection()
                UndoEditingHistorySettingsSection()
                PrivacyDiagnosticsSettingsSection()
                ResetDefaultsSettingsSection()
            }
            .tabItem {
                Label(SettingsTab.advanced.rawValue, systemImage: SettingsTab.advanced.systemImage)
            }
            .tag(SettingsTab.advanced)
        }
        .accessibilityIdentifier("settings.tabView")
        .padding(.top, AppTheme.Spacing.md)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.lg)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity, alignment: .top)
        .appWorkspaceSurface()
        .navigationTitle("Settings")
        .sheet(isPresented: $showingLicensesSheet) {
            LicensesSheetView(isPresented: $showingLicensesSheet)
        }
        .sheet(isPresented: $showingFormatsSheet) {
            SupportedFormatsView(isPresented: $showingFormatsSheet)
        }
    }

    @ViewBuilder
    private func settingsTabForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 420, maxWidth: 680, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Modular Settings Sections

private struct GeneralSettingsSection: View {
    @AppStorage("settings.appearanceMode", store: AppStoragePaths.userDefaults)
    private var appearanceModeRaw: String = AppearanceMode.system.rawValue

    @AppStorage("settings.showInDock", store: AppStoragePaths.userDefaults)
    private var showInDock: Bool = true

    @AppStorage("settings.showMenuBarExtra", store: AppStoragePaths.userDefaults)
    private var showMenuBarExtra: Bool = true

    @AppStorage("settings.keepAppOpenAfterConversion", store: AppStoragePaths.userDefaults)
    private var keepAppOpenAfterConversion: Bool = true

    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(
            get: { AppearanceMode(rawValue: appearanceModeRaw) ?? .system },
            set: { AppSettings.shared.appearanceMode = $0 }
        )
    }

    private var visibilityModeBinding: Binding<ApplicationVisibilityMode> {
        Binding(
            get: { ApplicationVisibilityMode(showInDock: showInDock, showInMenuBar: showMenuBarExtra) },
            set: { AppSettings.shared.applicationVisibilityMode = $0 }
        )
    }

    var body: some View {
        Section("General") {
            Picker("Appearance Theme", selection: appearanceModeBinding) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .accessibilityLabel("Appearance Theme")

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ApplicationVisibilitySelector(selection: visibilityModeBinding)

                if visibilityModeBinding.wrappedValue == .neither {
                    AppInfoBanner(
                        style: .info,
                        message: AppLifecycleManager.bothIconsHiddenGuidance,
                        icon: "eye.slash.fill"
                    )
                    .padding(.top, AppTheme.Spacing.xxs)
                    .accessibilityLabel("Both Dock and Menu Bar icons hidden notice. \(AppLifecycleManager.bothIconsHiddenGuidance)")
                }
            }

            Toggle("Keep app running when all windows are closed", isOn: $keepAppOpenAfterConversion)
                .accessibilityLabel("Keep app running when windows closed")

            Toggle(
                "Automatically pause other audio transport when playback starts",
                isOn: Binding(
                    get: { AppSettings.shared.audioAutoPauseArbitration },
                    set: { AppSettings.shared.audioAutoPauseArbitration = $0 }
                )
            )
            .accessibilityLabel("Automatically pause other audio transport when playback starts")
            .accessibilityHint("Pauses the Audio Library Player when Audio Editor plays, and vice versa, without losing queue or edit state")
            .accessibilityIdentifier("audioworkspace.settings.auto_pause_toggle")
        }
    }
}

private struct OutputFilesSettingsSection: View {
    @AppStorage("settings.defaultOutputLocation", store: AppStoragePaths.userDefaults)
    private var defaultOutputLocationRaw: String = DefaultOutputLocation.sameFolder.rawValue

    @AppStorage("settings.customOutputDirectoryPath", store: AppStoragePaths.userDefaults)
    private var customOutputDirectoryPath: String = ""

    @AppStorage("settings.existingFileHandling", store: AppStoragePaths.userDefaults)
    private var existingFileHandlingRaw: String = ExistingFileHandling.createUnique.rawValue

    @AppStorage("settings.afterConversionAction", store: AppStoragePaths.userDefaults)
    private var afterConversionActionRaw: String = AfterConversionAction.revealInFinder.rawValue

    private var defaultOutputLocationBinding: Binding<DefaultOutputLocation> {
        Binding(
            get: { DefaultOutputLocation(rawValue: defaultOutputLocationRaw) ?? .sameFolder },
            set: { newValue in
                AppSettings.shared.defaultOutputLocation = newValue
                let mapped = newValue.outputLocation
                AppState.shared?.outputLocation = mapped
                OutputManager.savePreferences(location: mapped, customDirectory: AppSettings.shared.customOutputDirectory)
            }
        )
    }

    private var existingFileHandlingBinding: Binding<ExistingFileHandling> {
        Binding(
            get: { ExistingFileHandling(rawValue: existingFileHandlingRaw) ?? .createUnique },
            set: { AppSettings.shared.existingFileHandling = $0 }
        )
    }

    private var afterConversionActionBinding: Binding<AfterConversionAction> {
        Binding(
            get: { AfterConversionAction(rawValue: afterConversionActionRaw) ?? .revealInFinder },
            set: { AppSettings.shared.afterConversionAction = $0 }
        )
    }

    var body: some View {
        Section("Output & Files") {
            Picker("Default Output Location", selection: defaultOutputLocationBinding) {
                ForEach(DefaultOutputLocation.allCases, id: \.self) { loc in
                    Text(loc.rawValue).tag(loc)
                }
            }
            .accessibilityLabel("Default Output Location")

            if defaultOutputLocationBinding.wrappedValue == .custom {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(customOutputDirectoryPath.isEmpty ? "No custom folder selected" : customOutputDirectoryPath)
                            .font(.caption)
                            .foregroundStyle(customOutputDirectoryPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Choose Folder...") {
                        chooseCustomFolder()
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Choose custom output folder")
                }
            }

            Picker("Existing File Name Collision", selection: existingFileHandlingBinding) {
                ForEach(ExistingFileHandling.allCases, id: \.self) { handling in
                    Text(handling.rawValue).tag(handling)
                }
            }
            .accessibilityLabel("Existing File Name Collision")

            Picker("After Conversion Action", selection: afterConversionActionBinding) {
                ForEach(AfterConversionAction.allCases, id: \.self) { action in
                    Text(action.rawValue).tag(action)
                }
            }
            .accessibilityLabel("After Conversion Action")
        }
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select default destination folder for converted files"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            let settings = AppSettings.shared
            settings.customOutputDirectory = selectedURL
            settings.defaultOutputLocation = .custom
            AppState.shared?.customOutputDirectory = selectedURL
            AppState.shared?.outputLocation = .customFolder
            OutputManager.savePreferences(location: .customFolder, customDirectory: selectedURL)
        }
    }
}

private struct NotificationsSettingsSection: View {
    @AppStorage("settings.showCompletionNotification", store: AppStoragePaths.userDefaults)
    private var showCompletionNotification: Bool = true

    @AppStorage("settings.notifyOnConversionCompleted", store: AppStoragePaths.userDefaults)
    private var notifyOnConversionCompleted: Bool = true

    @AppStorage("settings.notifyOnConversionFailed", store: AppStoragePaths.userDefaults)
    private var notifyOnConversionFailed: Bool = true

    @AppStorage("settings.notifyOnBatchCompleted", store: AppStoragePaths.userDefaults)
    private var notifyOnBatchCompleted: Bool = true

    @AppStorage("settings.playCompletionSound", store: AppStoragePaths.userDefaults)
    private var playCompletionSound: Bool = false

    var body: some View {
        Section("Notifications") {
            Toggle("Show system notifications on completion", isOn: $showCompletionNotification)
                .accessibilityLabel("Show system notifications on completion")
                .onChange(of: showCompletionNotification) { _, newValue in
                    if newValue {
                        AppNotificationManager.shared.requestAuthorizationIfNeeded()
                    }
                }

            if showCompletionNotification {
                Toggle("Notify on single conversion success", isOn: $notifyOnConversionCompleted)
                    .padding(.leading, 12)
                    .accessibilityLabel("Notify on single conversion success")

                Toggle("Notify on conversion failure", isOn: $notifyOnConversionFailed)
                    .padding(.leading, 12)
                    .accessibilityLabel("Notify on conversion failure")

                Toggle("Notify on batch completion", isOn: $notifyOnBatchCompleted)
                    .padding(.leading, 12)
                    .accessibilityLabel("Notify on batch completion")

                Toggle("Play sound effect on completion", isOn: $playCompletionSound)
                    .padding(.leading, 12)
                    .accessibilityLabel("Play sound effect on completion")
            }
        }
    }
}

private struct ConversionDefaultsSettingsSection: View {
    @AppStorage("settings.defaultImageQuality", store: AppStoragePaths.userDefaults)
    private var defaultImageQuality: Double = 0.90

    @AppStorage("settings.preserveMetadataByDefault", store: AppStoragePaths.userDefaults)
    private var preserveMetadataByDefault: Bool = true

    @AppStorage("settings.defaultPDFDPI", store: AppStoragePaths.userDefaults)
    private var defaultPDFDPI: Double = 150.0

    @AppStorage("settings.rememberLastUsedOptions", store: AppStoragePaths.userDefaults)
    private var rememberLastUsedOptions: Bool = true

    var body: some View {
        Section("Conversion Defaults") {
            VStack(alignment: .leading, spacing: 6) {
                Slider(value: $defaultImageQuality, in: 0.1...1.0, step: 0.05) {
                    Text("Default Image Quality: \(Int((defaultImageQuality * 100).rounded()))%")
                }
                .accessibilityLabel("Default Image Quality")
                .accessibilityValue("\(Int((defaultImageQuality * 100).rounded())) percent")

                Text("Applied when exporting JPEG, WebP, and lossy image formats.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle("Preserve metadata by default (GPS, EXIF, Camera info)", isOn: $preserveMetadataByDefault)
                .accessibilityLabel("Preserve metadata by default")

            HStack {
                Text("Default PDF Rasterization DPI:")
                Spacer()
                TextField("DPI", value: $defaultPDFDPI, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Default PDF Rasterization DPI")
            }

            Toggle("Remember last used options for formats", isOn: $rememberLastUsedOptions)
                .accessibilityLabel("Remember last used options for formats")
        }
    }
}

private struct PerformanceSettingsSection: View {
    @AppStorage("settings.concurrentConversions", store: AppStoragePaths.userDefaults)
    private var concurrentConversionsRaw: String = ConcurrentConversionLimit.automatic.rawValue

    private var concurrentConversionsBinding: Binding<ConcurrentConversionLimit> {
        Binding(
            get: { ConcurrentConversionLimit(rawValue: concurrentConversionsRaw) ?? .automatic },
            set: { AppSettings.shared.concurrentConversions = $0 }
        )
    }

    var body: some View {
        Section("Performance") {
            Picker("Maximum Concurrent Conversions", selection: concurrentConversionsBinding) {
                ForEach(ConcurrentConversionLimit.allCases, id: \.self) { limit in
                    Text(limit.rawValue).tag(limit)
                }
            }
            .accessibilityLabel("Maximum Concurrent Conversions")
        }
    }
}

private struct JobsHistorySettingsSection: View {
    @AppStorage("settings.jobsRetentionPolicy", store: AppStoragePaths.userDefaults)
    private var jobsRetentionPolicyRaw: String = JobsRetentionPolicy.twentyFourHours.rawValue

    @AppStorage("settings.failedJobsRetentionPolicy", store: AppStoragePaths.userDefaults)
    private var failedJobsRetentionPolicyRaw: String = FailedJobsRetentionPolicy.sevenDays.rawValue

    @AppStorage("settings.saveConversionHistory", store: AppStoragePaths.userDefaults)
    private var saveConversionHistory: Bool = true

    @AppStorage("settings.historyAutoRemove", store: AppStoragePaths.userDefaults)
    private var historyAutoRemoveRaw: String = HistoryAutoRemoveDuration.never.rawValue

    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var showingClearHistoryAlert = false

    private var jobsRetentionBinding: Binding<JobsRetentionPolicy> {
        Binding(
            get: { JobsRetentionPolicy(rawValue: jobsRetentionPolicyRaw) ?? .twentyFourHours },
            set: { AppSettings.shared.jobsRetentionPolicy = $0 }
        )
    }

    private var failedJobsRetentionBinding: Binding<FailedJobsRetentionPolicy> {
        Binding(
            get: { FailedJobsRetentionPolicy(rawValue: failedJobsRetentionPolicyRaw) ?? .sevenDays },
            set: { AppSettings.shared.failedJobsRetentionPolicy = $0 }
        )
    }

    private var historyAutoRemoveBinding: Binding<HistoryAutoRemoveDuration> {
        Binding(
            get: { HistoryAutoRemoveDuration(rawValue: historyAutoRemoveRaw) ?? .never },
            set: { newValue in
                AppSettings.shared.historyAutoRemove = newValue
                HistoryManager.shared.applyAutoRemovePolicy()
            }
        )
    }

    var body: some View {
        Section("Jobs & History") {
            Picker("Keep Completed Jobs", selection: jobsRetentionBinding) {
                ForEach(JobsRetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.rawValue).tag(policy)
                }
            }
            .accessibilityLabel("Keep Completed Jobs")

            Picker("Keep Failed Jobs", selection: failedJobsRetentionBinding) {
                ForEach(FailedJobsRetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.rawValue).tag(policy)
                }
            }
            .accessibilityLabel("Keep Failed Jobs")

            Toggle("Save conversion history", isOn: $saveConversionHistory)
                .accessibilityLabel("Save conversion history")

            if saveConversionHistory {
                Picker("Auto-remove History Records", selection: historyAutoRemoveBinding) {
                    ForEach(HistoryAutoRemoveDuration.allCases, id: \.self) { duration in
                        Text(duration.rawValue).tag(duration)
                    }
                }
                .accessibilityLabel("Auto-remove History Records")

                if !historyManager.items.isEmpty {
                    Button("Clear Conversion History") {
                        if historyManager.items.count > 1 {
                            showingClearHistoryAlert = true
                        } else {
                            historyManager.clearHistory()
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Clear Conversion History")
                    .alert("Clear History", isPresented: $showingClearHistoryAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear All", role: .destructive) {
                            historyManager.clearHistory()
                        }
                    } message: {
                        Text("Remove all \(historyManager.items.count) conversion records from history?")
                    }
                }
            }
        }
    }
}

private struct UndoEditingHistorySettingsSection: View {
    @AppStorage("settings.editingHistoryMaxEntries", store: AppStoragePaths.userDefaults)
    private var editingHistoryMaxEntriesRaw: Int = EditingHistoryLimitDefaults.defaultMaxEntries

    @AppStorage("settings.recoveryArtifactStorageLimitMB", store: AppStoragePaths.userDefaults)
    private var recoveryArtifactStorageLimitMBRaw: Int = EditingHistoryLimitDefaults.defaultRecoveryStorageLimitMB

    @ObservedObject private var undoCoordinator = UndoRedoCoordinator.shared
    @State private var recoveryUsageBytes: Int64 = 0

    private var maxEntriesBinding: Binding<Int> {
        Binding(
            get: { EditingHistoryLimitDefaults.clampedEntries(editingHistoryMaxEntriesRaw) },
            set: { AppSettings.shared.editingHistoryMaxEntries = $0 }
        )
    }

    private var storageLimitBinding: Binding<Int> {
        Binding(
            get: { EditingHistoryLimitDefaults.clampedStorageLimitMB(recoveryArtifactStorageLimitMBRaw) },
            set: { AppSettings.shared.recoveryArtifactStorageLimitMB = $0 }
        )
    }

    private var entryOptions: [Int] {
        let current = maxEntriesBinding.wrappedValue
        if EditingHistoryLimitDefaults.entryPresetChoices.contains(current) {
            return EditingHistoryLimitDefaults.entryPresetChoices
        }
        return Array(Set(EditingHistoryLimitDefaults.entryPresetChoices + [current])).sorted()
    }

    private var storageOptions: [Int] {
        let current = storageLimitBinding.wrappedValue
        if EditingHistoryLimitDefaults.storagePresetChoicesMB.contains(current) {
            return EditingHistoryLimitDefaults.storagePresetChoicesMB
        }
        return Array(Set(EditingHistoryLimitDefaults.storagePresetChoicesMB + [current])).sorted()
    }

    var body: some View {
        Section("Undo & Editing History") {
            Picker("Maximum Editing History Entries", selection: maxEntriesBinding) {
                ForEach(entryOptions, id: \.self) { count in
                    Text(count == EditingHistoryLimitDefaults.defaultMaxEntries ? "\(count) entries (Default)" : "\(count) entries")
                        .tag(count)
                }
            }
            .accessibilityLabel("Maximum Editing History Entries")

            Picker("Recovery Artifact Storage Limit", selection: storageLimitBinding) {
                ForEach(storageOptions, id: \.self) { mb in
                    Text(Self.formattedStorageLabel(mb: mb))
                        .tag(mb)
                }
            }
            .accessibilityLabel("Recovery Artifact Storage Limit")

            HStack(spacing: AppTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recovery Storage Usage")
                        .font(AppTheme.Typography.body)
                    Text("\(ByteCountFormatter.string(fromByteCount: recoveryUsageBytes, countStyle: .file)) of \(Self.formattedStorageLabel(mb: storageLimitBinding.wrappedValue))")
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Prune Unused Recovery Data") {
                    Task {
                        await undoCoordinator.pruneUnusedRecoveryArtifacts()
                        recoveryUsageBytes = await undoCoordinator.currentRecoveryUsageBytes()
                    }
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Prune Unused Recovery Data")
                .accessibilityHint("Removes orphaned or archived recovery files while protecting active undo and redo entries.")
            }

            Text("Active undo and redo operations remain protected from automatic cleanup until replaced or evicted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task {
            recoveryUsageBytes = await undoCoordinator.currentRecoveryUsageBytes()
        }
        .onChange(of: undoCoordinator.timelineRevision) {
            Task {
                recoveryUsageBytes = await undoCoordinator.currentRecoveryUsageBytes()
            }
        }
        .onChange(of: editingHistoryMaxEntriesRaw) {
            Task {
                await undoCoordinator.enforcePolicies()
                recoveryUsageBytes = await undoCoordinator.currentRecoveryUsageBytes()
            }
        }
        .onChange(of: recoveryArtifactStorageLimitMBRaw) {
            Task {
                await undoCoordinator.enforcePolicies()
                recoveryUsageBytes = await undoCoordinator.currentRecoveryUsageBytes()
            }
        }
    }

    private static func formattedStorageLabel(mb: Int) -> String {
        if mb >= 1024 && mb % 1024 == 0 {
            let gb = mb / 1024
            return mb == EditingHistoryLimitDefaults.defaultRecoveryStorageLimitMB ? "\(gb) GB (Default)" : "\(gb) GB"
        }
        return mb == EditingHistoryLimitDefaults.defaultRecoveryStorageLimitMB ? "\(mb) MB (Default)" : "\(mb) MB"
    }
}

private struct PrivacyDiagnosticsSettingsSection: View {
    @AppStorage("settings.verboseLogging", store: AppStoragePaths.userDefaults)
    private var verboseLogging: Bool = false

    var body: some View {
        Section("Privacy & Diagnostics") {
            Text("All file processing occurs 100% locally and offline on your Mac. LocalConvert never uploads or transmits your files, telemetry, or metadata to external servers.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Enable Verbose Diagnostic Logging", isOn: $verboseLogging)
                .accessibilityLabel("Enable Verbose Diagnostic Logging")

            HStack(spacing: 12) {
                Button("Open Logs Folder") {
                    DiagnosticLogManager.openLogsFolder()
                }
                .controlSize(.small)
                .accessibilityLabel("Open Logs Folder")

                Button("Clear Diagnostic Logs") {
                    DiagnosticLogManager.clearDiagnosticLogs()
                }
                .controlSize(.small)
                .accessibilityLabel("Clear Diagnostic Logs")
            }
        }
    }
}

private struct KeyboardShortcutsSettingsSection: View {
    var body: some View {
        Section("Keyboard Shortcuts") {
            VStack(spacing: AppTheme.Spacing.xs + 2) {
                ForEach(KeyboardShortcutDescriptor.defaultShortcuts) { shortcut in
                    HStack {
                        Text(shortcut.action)
                            .font(AppTheme.Typography.caption)
                        Spacer()
                        Text(shortcut.shortcut)
                            .font(AppTheme.Typography.badge.monospaced())
                            .padding(.horizontal, AppTheme.Spacing.xs + 2)
                            .padding(.vertical, AppTheme.Spacing.xxs)
                            .background(AppTheme.Colors.neutralTint)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }
}

private struct AboutSettingsSection: View {
    @Binding var showingLicensesSheet: Bool
    @Binding var showingFormatsSheet: Bool

    private static let cachedAppIcon: NSImage = {
        NSImage(named: "AppIcon")
            ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: "LocalConvert")
            ?? NSImage()
    }()

    private static let versionLine: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (Build \(build)) · Apple Silicon (arm64)"
    }()

    var body: some View {
        Section("About") {
            HStack(spacing: AppTheme.Spacing.md + 2) {
                Image(nsImage: Self.cachedAppIcon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("LocalConvert")
                        .font(AppTheme.Typography.sectionTitle)

                    Text("Native macOS File Converter")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)

                    Text(Self.versionLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)

            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "https://github.com/RighteousLife/LocalConvert") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("GitHub", systemImage: "link")
                }
                .controlSize(.small)
                .accessibilityLabel("Open GitHub repository in browser")

                Button {
                    showingLicensesSheet = true
                } label: {
                    Label("Third-Party Licenses", systemImage: "doc.text")
                }
                .controlSize(.small)
                .accessibilityLabel("View Third-Party Licenses")

                Button {
                    showingFormatsSheet = true
                } label: {
                    Label("Supported Formats", systemImage: "square.grid.2x2")
                }
                .controlSize(.small)
                .accessibilityLabel("View Supported Formats Matrix")
            }
        }
    }
}

private struct ResetDefaultsSettingsSection: View {
    @State private var showingResetAlert = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                showingResetAlert = true
            } label: {
                Text("Reset All Settings to Defaults")
            }
            .accessibilityLabel("Reset All Settings to Defaults")
            .alert("Reset Settings", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    AppSettings.shared.resetToDefaults()
                }
            } message: {
                Text("Are you sure you want to reset all settings to their default values? This cannot be undone.")
            }
        }
    }
}

// MARK: - Application Visibility Custom Popover Control

struct ApplicationVisibilitySelector: View {
    @Binding var selection: ApplicationVisibilityMode
    @State private var isPopoverPresented: Bool = false
    @State private var isTriggerHovered: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Application Visibility")
                Text(selection.popoverSubtitle)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button {
                isPopoverPresented.toggle()
            } label: {
                HStack(spacing: AppTheme.Spacing.xs + 2) {
                    Image(systemName: selection.systemImage)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.Colors.accent)
                    Text(selection.displayName)
                        .font(AppTheme.Typography.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, AppTheme.Spacing.sm + 2)
                .padding(.vertical, AppTheme.Spacing.xs + 2)
                .frame(minHeight: 28)
                .background(isTriggerHovered ? AppTheme.Colors.neutralTint : AppTheme.Colors.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isTriggerHovered = hovering
            }
            .accessibilityLabel("Application Visibility")
            .accessibilityValue(selection.displayName)
            .accessibilityHint("Opens visibility mode selector. Current: \(selection.popoverSubtitle)")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                ApplicationVisibilityPopoverContent(
                    selection: $selection,
                    isPresented: $isPopoverPresented
                )
            }
        }
    }
}

struct ApplicationVisibilityPopoverContent: View {
    @Binding var selection: ApplicationVisibilityMode
    @Binding var isPresented: Bool
    @FocusState private var focusedMode: ApplicationVisibilityMode?

    static func applySelection(
        _ mode: ApplicationVisibilityMode,
        selection: Binding<ApplicationVisibilityMode>,
        isPresented: Binding<Bool>
    ) {
        selection.wrappedValue = mode
        isPresented.wrappedValue = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ForEach(ApplicationVisibilityMode.allCases) { mode in
                ApplicationVisibilityOptionRow(
                    mode: mode,
                    isSelected: selection == mode,
                    isKeyboardFocused: focusedMode == mode,
                    onSelect: {
                        Self.applySelection(mode, selection: $selection, isPresented: $isPresented)
                    }
                )
                .focused($focusedMode, equals: mode)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .frame(minWidth: 256, idealWidth: 276, maxWidth: 310)
        .onKeyPress(.upArrow) {
            moveFocus(offset: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocus(offset: 1)
            return .handled
        }
        .onKeyPress(.return) {
            let target = focusedMode ?? selection
            Self.applySelection(target, selection: $selection, isPresented: $isPresented)
            return .handled
        }
        .onKeyPress(.space) {
            let target = focusedMode ?? selection
            Self.applySelection(target, selection: $selection, isPresented: $isPresented)
            return .handled
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private func moveFocus(offset: Int) {
        let all = ApplicationVisibilityMode.allCases
        let currentIndex = focusedMode.flatMap { all.firstIndex(of: $0) } ?? all.firstIndex(of: selection) ?? 0
        let nextIndex = (currentIndex + offset + all.count) % all.count
        focusedMode = all[nextIndex]
    }
}

private struct ApplicationVisibilityOptionRow: View {
    let mode: ApplicationVisibilityMode
    let isSelected: Bool
    var isKeyboardFocused: Bool = false
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppTheme.Spacing.sm + 2) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.Colors.accent : .secondary)
                    .frame(width: 20, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.displayName)
                        .font(AppTheme.Typography.subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(mode.popoverSubtitle)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: AppTheme.Spacing.sm)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.accent)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm + 2)
            .padding(.vertical, AppTheme.Spacing.xs + 3)
            .frame(minHeight: 40, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(mode.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(mode.popoverSubtitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var borderColor: Color {
        if isKeyboardFocused {
            return AppTheme.Colors.accent.opacity(0.55)
        }
        if isSelected {
            return AppTheme.Colors.accent.opacity(0.28)
        }
        return Color.clear
    }

    private var backgroundColor: Color {
        if isSelected {
            return AppTheme.Colors.accentTint
        }
        if isHovered || isKeyboardFocused {
            return AppTheme.Colors.neutralTint
        }
        return Color.clear
    }
}

// MARK: - Licenses Sheet View

struct LicensesSheetView: View {
    @Binding var isPresented: Bool
    @State private var searchText = ""
    
    private var licenseText: String {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        if let resourceDir = Bundle.main.resourceURL,
           let text = try? String(contentsOf: resourceDir.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8) {
            return text
        }
        return """
        LocalConvert Third-Party Notices
        
        1. libwebp & libsharpyuv (v1.6.0 / v0.1.2) — BSD 3-Clause (Google LLC)
        2. libjxl (v0.13.0), brotli & highway — BSD 3-Clause / MIT / Apache-2.0
        3. FFmpeg & ffprobe (v9.0.2) — LGPLv3+ (FFmpeg Project)
        4. LibreOffice Runtime (v26.8.0.3) — MPL 2.0 (The Document Foundation)
        5. Apple macOS Frameworks — Operating System Library Exception
        """
    }
    
    private var filteredText: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return licenseText }
        
        let lines = licenseText.components(separatedBy: .newlines)
        let matching = lines.filter { $0.localizedCaseInsensitiveContains(query) }
        return matching.joined(separator: "\n")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Third-Party Licenses & Notices")
                        .font(.headline)
                    Text("Open-source components bundled with or utilized by LocalConvert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search license text...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear license search")
                }
            }
            .padding(AppTheme.Spacing.xs + 2)
            .background(AppTheme.Colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            
            ScrollView {
                Text(filteredText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(AppTheme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(AppTheme.Colors.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(minWidth: 540, minHeight: 460)
        .appWorkspaceSurface()
        .onExitCommand { isPresented = false }
    }
}
