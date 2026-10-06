import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var historyManager = HistoryManager.shared
    
    @State private var showingResetAlert = false
    @State private var showingClearHistoryAlert = false
    @State private var showingLicensesSheet = false
    
    var body: some View {
        Form {
            // MARK: - General
            Section("General") {
                Picker("Appearance Theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .accessibilityLabel("Appearance Theme")
                
                Toggle("Show LocalConvert in macOS Menu Bar", isOn: $settings.showMenuBarExtra)
                    .accessibilityLabel("Show LocalConvert in menu bar")
                
                Toggle("Keep app running when all windows are closed", isOn: $settings.keepAppOpenAfterConversion)
                    .accessibilityLabel("Keep app running when windows closed")
            }
            
            // MARK: - Output & Files
            Section("Output & Files") {
                Picker("Default Output Location", selection: $settings.defaultOutputLocation) {
                    ForEach(DefaultOutputLocation.allCases, id: \.self) { loc in
                        Text(loc.rawValue).tag(loc)
                    }
                }
                .accessibilityLabel("Default Output Location")
                
                if settings.defaultOutputLocation == .custom {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.customOutputDirectoryPath.isEmpty ? "No custom folder selected" : settings.customOutputDirectoryPath)
                                .font(.caption)
                                .foregroundStyle(settings.customOutputDirectoryPath.isEmpty ? .secondary : .primary)
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
                
                Picker("Existing File Name Collision", selection: $settings.existingFileHandling) {
                    ForEach(ExistingFileHandling.allCases, id: \.self) { handling in
                        Text(handling.rawValue).tag(handling)
                    }
                }
                .accessibilityLabel("Existing File Name Collision")
                
                Picker("After Conversion Action", selection: $settings.afterConversionAction) {
                    ForEach(AfterConversionAction.allCases, id: \.self) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
                .accessibilityLabel("After Conversion Action")
            }
            
            // MARK: - Notifications
            Section("Notifications") {
                Toggle("Show system notifications on completion", isOn: $settings.showCompletionNotification)
                    .accessibilityLabel("Show system notifications on completion")
                
                if settings.showCompletionNotification {
                    Toggle("Notify on single conversion success", isOn: $settings.notifyOnConversionCompleted)
                        .padding(.leading, 12)
                        .accessibilityLabel("Notify on single conversion success")
                    
                    Toggle("Notify on conversion failure", isOn: $settings.notifyOnConversionFailed)
                        .padding(.leading, 12)
                        .accessibilityLabel("Notify on conversion failure")
                    
                    Toggle("Notify on batch completion", isOn: $settings.notifyOnBatchCompleted)
                        .padding(.leading, 12)
                        .accessibilityLabel("Notify on batch completion")
                    
                    Toggle("Play sound effect on completion", isOn: $settings.playCompletionSound)
                        .padding(.leading, 12)
                        .accessibilityLabel("Play sound effect on completion")
                }
            }
            
            // MARK: - Conversion Defaults
            Section("Conversion Defaults") {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $settings.defaultImageQuality, in: 0.1...1.0, step: 0.05) {
                        Text("Default Image Quality: \(Int(settings.defaultImageQuality * 100))%")
                    }
                    .accessibilityLabel("Default Image Quality")
                    
                    Text("Applied when exporting JPEG, WebP, and lossy image formats.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Toggle("Preserve metadata by default (GPS, EXIF, Camera info)", isOn: $settings.preserveMetadataByDefault)
                    .accessibilityLabel("Preserve metadata by default")
                
                HStack {
                    Text("Default PDF Rasterization DPI:")
                    Spacer()
                    TextField("DPI", value: $settings.defaultPDFDPI, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Default PDF Rasterization DPI")
                }
                
                Toggle("Remember last used options for formats", isOn: $settings.rememberLastUsedOptions)
                    .accessibilityLabel("Remember last used options for formats")
            }
            
            // MARK: - Performance
            Section("Performance") {
                Picker("Maximum Concurrent Conversions", selection: $settings.concurrentConversions) {
                    ForEach(ConcurrentConversionLimit.allCases, id: \.self) { limit in
                        Text(limit.rawValue).tag(limit)
                    }
                }
                .accessibilityLabel("Maximum Concurrent Conversions")
            }
            
            // MARK: - Jobs & History
            Section("Jobs & History") {
                Picker("Keep Completed Jobs", selection: $settings.jobsRetentionPolicy) {
                    ForEach(JobsRetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .accessibilityLabel("Keep Completed Jobs")
                
                Picker("Keep Failed Jobs", selection: $settings.failedJobsRetentionPolicy) {
                    ForEach(FailedJobsRetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .accessibilityLabel("Keep Failed Jobs")
                
                Toggle("Save conversion history", isOn: $settings.saveConversionHistory)
                    .accessibilityLabel("Save conversion history")
                
                if settings.saveConversionHistory {
                    Picker("Auto-remove History Records", selection: $settings.historyAutoRemove) {
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
            
            // MARK: - Privacy & Diagnostics
            Section("Privacy & Diagnostics") {
                Text("All file processing occurs 100% locally and offline on your Mac. LocalConvert never uploads or transmits your files, telemetry, or metadata to external servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Toggle("Enable Verbose Diagnostic Logging", isOn: $settings.verboseLogging)
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
            
            // MARK: - Keyboard Shortcuts
            Section("Keyboard Shortcuts") {
                VStack(spacing: 6) {
                    ForEach(KeyboardShortcutDescriptor.defaultShortcuts) { shortcut in
                        HStack {
                            Text(shortcut.action)
                                .font(.caption)
                            Spacer()
                            Text(shortcut.shortcut)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            
            // MARK: - About
            Section("About") {
                HStack(spacing: 14) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: "LocalConvert")!)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LocalConvert")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Native macOS File Converter")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                        Text("Version \(version) (Build \(build)) · Apple Silicon (arm64)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                
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
                }
            }
            
            // MARK: - Reset Defaults
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
                        settings.resetToDefaults()
                    }
                } message: {
                    Text("Are you sure you want to reset all settings to their default values? This cannot be undone.")
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(minWidth: 480, maxWidth: 680, minHeight: 520, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Settings")
        .onChange(of: settings.showCompletionNotification) { newValue in
            if newValue {
                AppNotificationManager.shared.requestAuthorizationIfNeeded()
            }
        }
        .sheet(isPresented: $showingLicensesSheet) {
            LicensesSheetView(isPresented: $showingLicensesSheet)
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
            settings.customOutputDirectory = selectedURL
            OutputManager.savePreferences(location: .customFolder, customDirectory: selectedURL)
        }
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
        
        1. libwebp & libsharpyuv — BSD 3-Clause (Google LLC)
        2. FFmpeg & ffprobe — LGPLv3+ (FFmpeg Project)
        3. LibreOffice Runtime — MPL 2.0 (The Document Foundation)
        4. Apple macOS Frameworks — Operating System Library Exception
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
                }
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            
            ScrollView {
                Text(filteredText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 460)
    }
}
