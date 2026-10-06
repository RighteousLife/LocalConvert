import Foundation
import SwiftUI

// MARK: - Output Destination Preference

enum DefaultOutputLocation: String, CaseIterable, Sendable {
    case sameFolder = "Same folder as original"
    case lastUsedFolder = "Last used folder"
    case askEveryTime = "Ask every time"
    case custom = "Choose folder..."
}

// MARK: - Existing File Handling

enum ExistingFileHandling: String, CaseIterable, Sendable {
    case createUnique = "Create Unique Filename"
    case overwrite = "Replace Existing File"
    case skip = "Skip"
}

// MARK: - After Conversion Action

enum AfterConversionAction: String, CaseIterable, Sendable {
    case doNothing = "Do Nothing"
    case revealInFinder = "Reveal in Finder"
    case openOutputFile = "Open Output File"
    case openOutputFolder = "Open Output Folder"
}

// MARK: - Concurrent Conversions

enum ConcurrentConversionLimit: String, CaseIterable, Sendable {
    case automatic = "Automatic"
    case one = "1"
    case two = "2"
    case three = "3"
    case four = "4"
    case six = "6"
    
    var count: Int {
        switch self {
        case .automatic: return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .six: return 6
        }
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - History Auto-Remove Duration

enum HistoryAutoRemoveDuration: String, CaseIterable, Sendable {
    case never = "Never"
    case sevenDays = "After 7 Days"
    case thirtyDays = "After 30 Days"
    case ninetyDays = "After 90 Days"
    
    var days: Int? {
        switch self {
        case .never: return nil
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .ninetyDays: return 90
        }
    }
}

// MARK: - Jobs Retention Policy

enum JobsRetentionPolicy: String, CaseIterable, Sendable {
    case oneHour = "1 hour"
    case twentyFourHours = "24 hours"
    case sevenDays = "7 days"
    case forever = "Forever"
    
    var timeInterval: TimeInterval? {
        switch self {
        case .oneHour: return 3600
        case .twentyFourHours: return 86400
        case .sevenDays: return 86400 * 7
        case .forever: return nil
        }
    }
}

// MARK: - Failed Jobs Retention Policy

enum FailedJobsRetentionPolicy: String, CaseIterable, Sendable {
    case oneHour = "1 hour"
    case twentyFourHours = "24 hours"
    case sevenDays = "7 days"
    case forever = "Forever"
    
    var timeInterval: TimeInterval? {
        switch self {
        case .oneHour: return 3600
        case .twentyFourHours: return 86400
        case .sevenDays: return 86400 * 7
        case .forever: return nil
        }
    }
}

// MARK: - Keyboard Shortcut Descriptor

struct KeyboardShortcutDescriptor: Identifiable, Sendable {
    let id: String
    let action: String
    let shortcut: String
    let category: String
    
    static let defaultShortcuts: [KeyboardShortcutDescriptor] = [
        KeyboardShortcutDescriptor(id: "add_files", action: "Add Files...", shortcut: "⌘O", category: "File"),
        KeyboardShortcutDescriptor(id: "convert_all", action: "Start Conversion", shortcut: "⌘↩", category: "Conversion"),
        KeyboardShortcutDescriptor(id: "cancel", action: "Cancel Active Conversion", shortcut: "Esc", category: "Conversion"),
        KeyboardShortcutDescriptor(id: "repeat_last", action: "Repeat Last Conversion", shortcut: "⌘⇧R", category: "Conversion"),
        KeyboardShortcutDescriptor(id: "quick_webp", action: "Quick Convert to WebP", shortcut: "⌘1", category: "Navigation / Shortcuts"),
        KeyboardShortcutDescriptor(id: "nav_convert", action: "Switch to Convert Tab", shortcut: "⌘1", category: "Navigation"),
        KeyboardShortcutDescriptor(id: "nav_jobs", action: "Switch to Jobs Center", shortcut: "⌘2", category: "Navigation"),
        KeyboardShortcutDescriptor(id: "nav_pdf", action: "Switch to PDF Toolbox", shortcut: "⌘3", category: "Navigation"),
        KeyboardShortcutDescriptor(id: "nav_metadata", action: "Switch to Metadata", shortcut: "⌘4", category: "Navigation"),
        KeyboardShortcutDescriptor(id: "nav_presets", action: "Switch to Presets", shortcut: "⌘5", category: "Navigation"),
        KeyboardShortcutDescriptor(id: "nav_history", action: "Switch to History", shortcut: "⌘6", category: "Navigation"),
        KeyboardShortcutDescriptor(id: "settings", action: "Open Settings", shortcut: "⌘,", category: "General"),
        KeyboardShortcutDescriptor(id: "quit", action: "Quit LocalConvert", shortcut: "⌘Q", category: "General")
    ]
}

// MARK: - Diagnostic Log Manager

struct DiagnosticLogManager: Sendable {
    static var logDirectoryURL: URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("LocalConvert")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir
    }
    
    @MainActor
    static func openLogsFolder() {
        let dir = logDirectoryURL
        NSWorkspace.shared.open(dir)
    }
    
    @MainActor
    static func clearDiagnosticLogs() {
        let dir = logDirectoryURL
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - App Settings

/// Central settings model. All properties persist via @AppStorage / UserDefaults.
/// Singleton access via AppSettings.shared.
@MainActor
final class AppSettings: ObservableObject {
    
    static let shared = AppSettings()
    
    // MARK: - General
    
    @AppStorage("settings.showMenuBarExtra")
    var showMenuBarExtra: Bool = true {
        didSet {
            MenuBarManager.shared.updateVisibility()
        }
    }
    
    @AppStorage("settings.showCompletionNotification")
    var showCompletionNotification: Bool = true
    
    @AppStorage("settings.playCompletionSound")
    var playCompletionSound: Bool = false
    
    @AppStorage("settings.keepAppOpenAfterConversion")
    var keepAppOpenAfterConversion: Bool = true
    
    // MARK: - Output & Files
    
    @AppStorage("settings.defaultOutputLocation")
    private var defaultOutputLocationRaw: String = DefaultOutputLocation.sameFolder.rawValue
    
    var defaultOutputLocation: DefaultOutputLocation {
        get { DefaultOutputLocation(rawValue: defaultOutputLocationRaw) ?? .sameFolder }
        set { defaultOutputLocationRaw = newValue.rawValue }
    }
    
    @AppStorage("settings.customOutputDirectoryPath")
    var customOutputDirectoryPath: String = ""
    
    var customOutputDirectory: URL? {
        get {
            guard !customOutputDirectoryPath.isEmpty else { return nil }
            return URL(fileURLWithPath: customOutputDirectoryPath)
        }
        set {
            customOutputDirectoryPath = newValue?.path ?? ""
        }
    }
    
    @AppStorage("settings.afterConversionAction")
    private var afterConversionActionRaw: String = AfterConversionAction.revealInFinder.rawValue
    
    var afterConversionAction: AfterConversionAction {
        get { AfterConversionAction(rawValue: afterConversionActionRaw) ?? .revealInFinder }
        set { afterConversionActionRaw = newValue.rawValue }
    }
    
    @AppStorage("settings.existingFileHandling")
    private var existingFileHandlingRaw: String = ExistingFileHandling.createUnique.rawValue
    
    var existingFileHandling: ExistingFileHandling {
        get { ExistingFileHandling(rawValue: existingFileHandlingRaw) ?? .createUnique }
        set { existingFileHandlingRaw = newValue.rawValue }
    }
    
    // MARK: - Conversion
    
    /// Default image quality (0.0...1.0)
    @AppStorage("settings.defaultImageQuality")
    var defaultImageQuality: Double = 0.90
    
    /// Preserve metadata by default
    @AppStorage("settings.preserveMetadataByDefault")
    var preserveMetadataByDefault: Bool = true
    
    /// Default PDF rendering DPI
    @AppStorage("settings.defaultPDFDPI")
    var defaultPDFDPI: Double = 150.0
    
    // MARK: - Performance
    
    @AppStorage("settings.concurrentConversions")
    private var concurrentConversionsRaw: String = ConcurrentConversionLimit.automatic.rawValue
    
    var concurrentConversions: ConcurrentConversionLimit {
        get { ConcurrentConversionLimit(rawValue: concurrentConversionsRaw) ?? .automatic }
        set { concurrentConversionsRaw = newValue.rawValue }
    }
    
    // MARK: - Notifications
    
    @AppStorage("settings.notifyOnConversionCompleted")
    var notifyOnConversionCompleted: Bool = true
    
    @AppStorage("settings.notifyOnConversionFailed")
    var notifyOnConversionFailed: Bool = true
    
    @AppStorage("settings.notifyOnBatchCompleted")
    var notifyOnBatchCompleted: Bool = true
    
    // MARK: - Appearance
    
    @AppStorage("settings.appearanceMode")
    private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    
    var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .system }
        set { appearanceModeRaw = newValue.rawValue }
    }
    
    // MARK: - History
    
    @AppStorage("settings.saveConversionHistory")
    var saveConversionHistory: Bool = true
    
    @AppStorage("settings.historyAutoRemove")
    private var historyAutoRemoveRaw: String = HistoryAutoRemoveDuration.never.rawValue
    
    var historyAutoRemove: HistoryAutoRemoveDuration {
        get { HistoryAutoRemoveDuration(rawValue: historyAutoRemoveRaw) ?? .never }
        set { historyAutoRemoveRaw = newValue.rawValue }
    }
    
    // MARK: - Recent Formats & Smart Defaults
    
    @AppStorage("settings.recentOutputFormats")
    private var recentOutputFormatsRaw: String = "webp,jpg,png,pdf,mp4,mp3"
    
    var recentOutputFormats: [FileFormat] {
        get {
            let keys = recentOutputFormatsRaw.split(separator: ",").map { String($0) }
            return keys.compactMap { FileFormat(rawValue: $0) }
        }
        set {
            let keys = newValue.prefix(5).map { $0.rawValue }
            recentOutputFormatsRaw = keys.joined(separator: ",")
        }
    }
    
    func addRecentOutputFormat(_ format: FileFormat) {
        var current = recentOutputFormats.filter { $0 != format }
        current.insert(format, at: 0)
        recentOutputFormats = Array(current.prefix(5))
    }
    
    @AppStorage("settings.rememberLastUsedOptions")
    var rememberLastUsedOptions: Bool = true
    
    // MARK: - Jobs Center Retention
    
    @AppStorage("settings.jobsRetentionPolicy")
    private var jobsRetentionPolicyRaw: String = JobsRetentionPolicy.twentyFourHours.rawValue
    
    var jobsRetentionPolicy: JobsRetentionPolicy {
        get { JobsRetentionPolicy(rawValue: jobsRetentionPolicyRaw) ?? .twentyFourHours }
        set { jobsRetentionPolicyRaw = newValue.rawValue }
    }
    
    @AppStorage("settings.failedJobsRetentionPolicy")
    private var failedJobsRetentionPolicyRaw: String = FailedJobsRetentionPolicy.sevenDays.rawValue
    
    var failedJobsRetentionPolicy: FailedJobsRetentionPolicy {
        get { FailedJobsRetentionPolicy(rawValue: failedJobsRetentionPolicyRaw) ?? .sevenDays }
        set { failedJobsRetentionPolicyRaw = newValue.rawValue }
    }
    
    // MARK: - Advanced / Diagnostics
    
    @AppStorage("settings.verboseLogging")
    var verboseLogging: Bool = false
    
    // MARK: - Reset to Defaults
    
    /// Resets all settings to factory defaults.
    func resetToDefaults() {
        showMenuBarExtra = true
        showCompletionNotification = true
        playCompletionSound = false
        keepAppOpenAfterConversion = true
        defaultOutputLocationRaw = DefaultOutputLocation.sameFolder.rawValue
        customOutputDirectoryPath = ""
        afterConversionActionRaw = AfterConversionAction.revealInFinder.rawValue
        existingFileHandlingRaw = ExistingFileHandling.createUnique.rawValue
        defaultImageQuality = 0.90
        preserveMetadataByDefault = true
        defaultPDFDPI = 150.0
        concurrentConversionsRaw = ConcurrentConversionLimit.automatic.rawValue
        notifyOnConversionCompleted = true
        notifyOnConversionFailed = true
        notifyOnBatchCompleted = true
        appearanceModeRaw = AppearanceMode.system.rawValue
        saveConversionHistory = true
        historyAutoRemoveRaw = HistoryAutoRemoveDuration.never.rawValue
        recentOutputFormatsRaw = "webp,jpg,png,pdf,mp4,mp3"
        rememberLastUsedOptions = true
        jobsRetentionPolicyRaw = JobsRetentionPolicy.twentyFourHours.rawValue
        failedJobsRetentionPolicyRaw = FailedJobsRetentionPolicy.sevenDays.rawValue
        verboseLogging = false
    }
    
    // MARK: - Derived ConversionOptions
    
    /// Returns a ConversionOptions pre-filled with the current default settings.
    var defaultConversionOptions: ConversionOptions {
        ConversionOptions(
            preserveMetadata: preserveMetadataByDefault,
            overwriteExisting: existingFileHandling == .overwrite,
            imageQuality: defaultImageQuality,
            pdfDPI: defaultPDFDPI,
            pdfOfficeMode: .automatic,
            webpLossless: false,
            mediaQuality: .high
        )
    }
}
