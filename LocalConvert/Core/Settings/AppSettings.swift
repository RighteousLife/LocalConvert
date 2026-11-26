import Foundation
import SwiftUI
import os.log

// MARK: - Output Destination Preference

enum DefaultOutputLocation: String, CaseIterable, Sendable {
    case sameFolder = "Same folder as original"
    case lastUsedFolder = "Last used folder"
    case askEveryTime = "Ask every time"
    case custom = "Choose folder..."

    var outputLocation: OutputLocation {
        switch self {
        case .sameFolder: return .sameFolder
        case .lastUsedFolder: return .lastUsedFolder
        case .askEveryTime: return .askEveryTime
        case .custom: return .customFolder
        }
    }

    init(from outputLocation: OutputLocation) {
        switch outputLocation {
        case .sameFolder: self = .sameFolder
        case .lastUsedFolder: self = .lastUsedFolder
        case .askEveryTime: self = .askEveryTime
        case .customFolder: self = .custom
        }
    }
}

// MARK: - Existing File Handling

enum ExistingFileHandling: String, CaseIterable, Sendable, Codable, Equatable, Hashable {
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

    /// Resolves an explicit `ColorScheme` synchronously for `.system` using the live system appearance,
    /// avoiding a split-frame mismatch between AppKit window chrome and SwiftUI environment propagation.
    func resolvedColorScheme(system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: return system
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Application Visibility Mode

enum ApplicationVisibilityMode: String, CaseIterable, Identifiable, Sendable {
    case both = "both"
    case dockOnly = "dockOnly"
    case menuBarOnly = "menuBarOnly"
    case neither = "neither"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .both: return "Dock + Menu Bar"
        case .dockOnly: return "Dock Only"
        case .menuBarOnly: return "Menu Bar Only"
        case .neither: return "Neither"
        }
    }

    var shortDescription: String {
        switch self {
        case .both: return "Show LocalConvert in both the Dock and Menu Bar"
        case .dockOnly: return "Show in the Dock only and hide the Menu Bar icon"
        case .menuBarOnly: return "Show in the Menu Bar only and hide the Dock icon"
        case .neither: return "Hide both the Dock and Menu Bar icons (reopen via Finder or Spotlight)"
        }
    }

    var popoverSubtitle: String {
        switch self {
        case .both: return "Show in both locations"
        case .dockOnly: return "Show only in the Dock"
        case .menuBarOnly: return "Show only in the Menu Bar"
        case .neither: return "Hide both icons"
        }
    }

    var systemImage: String {
        switch self {
        case .both: return "rectangle.inset.filled.on.rectangle"
        case .dockOnly: return "dock.rectangle"
        case .menuBarOnly: return "menubar.rectangle"
        case .neither: return "eye.slash"
        }
    }

    var menuOptionLabel: String {
        "\(displayName) — \(shortDescription)"
    }

    var showsInDock: Bool {
        switch self {
        case .both, .dockOnly: return true
        case .menuBarOnly, .neither: return false
        }
    }

    var showsInMenuBar: Bool {
        switch self {
        case .both, .menuBarOnly: return true
        case .dockOnly, .neither: return false
        }
    }

    init(showInDock: Bool, showInMenuBar: Bool) {
        switch (showInDock, showInMenuBar) {
        case (true, true): self = .both
        case (true, false): self = .dockOnly
        case (false, true): self = .menuBarOnly
        case (false, false): self = .neither
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

// MARK: - Editing History & Recovery Limits

enum EditingHistoryLimitDefaults {
    static let defaultMaxEntries: Int = 100
    static let minMaxEntries: Int = 10
    static let maxMaxEntries: Int = 1000
    static let entryPresetChoices: [Int] = [25, 50, 100, 250, 500]

    static let defaultRecoveryStorageLimitMB: Int = 512
    static let minRecoveryStorageLimitMB: Int = 64
    static let maxRecoveryStorageLimitMB: Int = 8192
    static let storagePresetChoicesMB: [Int] = [128, 256, 512, 1024, 2048, 4096]

    static func clampedEntries(_ value: Int) -> Int {
        min(max(value, minMaxEntries), maxMaxEntries)
    }

    static func clampedStorageLimitMB(_ value: Int) -> Int {
        min(max(value, minRecoveryStorageLimitMB), maxRecoveryStorageLimitMB)
    }
}

// MARK: - Keyboard Shortcut Descriptor

struct KeyboardShortcutDescriptor: Identifiable, Sendable {
    struct KeySpec: Sendable, Equatable {
        enum Key: Sendable, Equatable {
            case character(Character)
            case `return`
            case escape
        }

        enum Modifier: String, Sendable, Equatable, Hashable {
            case command
            case shift
            case option
        }

        let key: Key
        let modifiers: Set<Modifier>

        init(key: Key, modifiers: Set<Modifier> = []) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    let id: String
    let action: String
    let shortcut: String
    let category: String
    let keySpec: KeySpec?

    init(
        id: String,
        action: String,
        shortcut: String,
        category: String,
        keySpec: KeySpec? = nil
    ) {
        self.id = id
        self.action = action
        self.shortcut = shortcut
        self.category = category
        self.keySpec = keySpec
    }

    var swiftUIKeyboardShortcut: KeyboardShortcut? {
        guard let keySpec else { return nil }
        let equivalent: KeyEquivalent
        switch keySpec.key {
        case .character(let ch):
            equivalent = KeyEquivalent(ch)
        case .return:
            equivalent = .return
        case .escape:
            equivalent = .escape
        }
        var mods: EventModifiers = []
        if keySpec.modifiers.contains(.command) { mods.insert(.command) }
        if keySpec.modifiers.contains(.shift) { mods.insert(.shift) }
        if keySpec.modifiers.contains(.option) { mods.insert(.option) }
        return KeyboardShortcut(equivalent, modifiers: mods)
    }

    static let defaultShortcuts: [KeyboardShortcutDescriptor] = [
        KeyboardShortcutDescriptor(id: "undo", action: "Undo", shortcut: "⌘Z", category: "Edit", keySpec: KeySpec(key: .character("z"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "redo", action: "Redo", shortcut: "⇧⌘Z", category: "Edit", keySpec: KeySpec(key: .character("z"), modifiers: [.command, .shift])),
        KeyboardShortcutDescriptor(id: "editing_history", action: "Editing History", shortcut: "⌥⌘Z", category: "Edit", keySpec: KeySpec(key: .character("z"), modifiers: [.command, .option])),
        KeyboardShortcutDescriptor(id: "add_files", action: "Add Files...", shortcut: "⌘O", category: "File", keySpec: KeySpec(key: .character("o"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "convert_all", action: "Start Conversion", shortcut: "⌘↩", category: "Conversion", keySpec: KeySpec(key: .return, modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "cancel", action: "Cancel Active Conversion", shortcut: "Esc", category: "Conversion", keySpec: KeySpec(key: .escape, modifiers: [])),
        KeyboardShortcutDescriptor(id: "repeat_last", action: "Repeat Last Conversion", shortcut: "⌘⇧R", category: "Conversion", keySpec: KeySpec(key: .character("r"), modifiers: [.command, .shift])),
        KeyboardShortcutDescriptor(id: "nav_convert", action: "Switch to Convert Tab", shortcut: "⌘1", category: "Navigation", keySpec: KeySpec(key: .character("1"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "nav_jobs", action: "Switch to Jobs Center", shortcut: "⌘2", category: "Navigation", keySpec: KeySpec(key: .character("2"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "nav_pdf", action: "Switch to PDF Toolbox", shortcut: "⌘3", category: "Navigation", keySpec: KeySpec(key: .character("3"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "nav_audio_workspace", action: "Switch to Audio Workspace", shortcut: "⌘4", category: "Navigation", keySpec: KeySpec(key: .character("4"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "nav_image", action: "Switch to Image Toolbox", shortcut: "⌘5", category: "Navigation", keySpec: KeySpec(key: .character("5"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "nav_metadata", action: "Switch to Metadata", shortcut: "⌘6", category: "Navigation", keySpec: KeySpec(key: .character("6"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "nav_presets", action: "Switch to Presets", shortcut: "⌘7", category: "Navigation", keySpec: KeySpec(key: .character("7"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "nav_history", action: "Switch to History", shortcut: "⌘8", category: "Navigation", keySpec: KeySpec(key: .character("8"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "nav_settings", action: "Switch to Settings", shortcut: "⌘9", category: "Navigation", keySpec: KeySpec(key: .character("9"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "command_palette", action: "Command Palette...", shortcut: "⌘K", category: "General", keySpec: KeySpec(key: .character("k"), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "settings", action: "Open Settings", shortcut: "⌘,", category: "General", keySpec: KeySpec(key: .character(","), modifiers: [.command])),
        KeyboardShortcutDescriptor(id: "quit", action: "Quit LocalConvert", shortcut: "⌘Q", category: "General", keySpec: KeySpec(key: .character("q"), modifiers: [.command]))
    ]

    static func descriptor(forID id: String) -> KeyboardShortcutDescriptor? {
        defaultShortcuts.first { $0.id == id }
    }

    static func swiftUIShortcut(forID id: String) -> KeyboardShortcut? {
        descriptor(forID: id)?.swiftUIKeyboardShortcut
    }

    static var hasDuplicateShortcuts: Bool {
        let keys = defaultShortcuts.map(\.shortcut)
        return Set(keys).count != keys.count
    }
}

// MARK: - Diagnostic Log Manager

struct DiagnosticLogManager: Sendable {
    private static let fileWriteLock = NSLock()
    private static let maxLogFileSizeBytes: Int64 = 2 * 1024 * 1024

    static var logDirectoryURL: URL {
        let logsDir = AppStoragePaths.logsDirectory
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir
    }

    static var logFileURL: URL {
        logDirectoryURL.appendingPathComponent("localconvert.log")
    }

    static func logFileURL(in directoryOverride: URL?) -> URL {
        let dir = directoryOverride ?? logDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("localconvert.log")
    }
    
    @MainActor
    static func openLogsFolder() {
        let dir = logDirectoryURL
        NSWorkspace.shared.open(dir)
    }
    
    @MainActor
    static func clearDiagnosticLogs(in directoryOverride: URL? = nil) {
        let dir = directoryOverride ?? logDirectoryURL
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func isVerboseLoggingEnabled(override: Bool? = nil) -> Bool {
        if let override { return override }
        return AppStoragePaths.userDefaults.bool(forKey: "settings.verboseLogging")
    }

    /// Emits a privacy-sanitized verbose diagnostic event only when `verboseLogging` is enabled.
    static func logVerbose(
        category: String,
        message: String,
        isVerboseEnabled: Bool? = nil,
        directoryOverride: URL? = nil
    ) {
        guard isVerboseLoggingEnabled(override: isVerboseEnabled) else { return }
        let sanitized = ErrorDetailsFormatter.sanitize(message)
        let osLogger = Logger(subsystem: "com.localconvert.app", category: category)
        osLogger.debug("\(sanitized, privacy: .public)")
        appendEntryToLogFile(level: "VERBOSE", category: category, sanitizedMessage: sanitized, directoryOverride: directoryOverride)
    }

    /// Always emits an error event to unified OSLog (`Logger.error`), and also appends to the diagnostic log file when `verboseLogging` is enabled.
    static func logError(
        category: String,
        message: String,
        isVerboseEnabled: Bool? = nil,
        directoryOverride: URL? = nil
    ) {
        let sanitized = ErrorDetailsFormatter.sanitize(message)
        let osLogger = Logger(subsystem: "com.localconvert.app", category: category)
        osLogger.error("\(sanitized, privacy: .public)")
        guard isVerboseLoggingEnabled(override: isVerboseEnabled) else { return }
        appendEntryToLogFile(level: "ERROR", category: category, sanitizedMessage: sanitized, directoryOverride: directoryOverride)
    }

    static func readDiagnosticLogContents(in directoryOverride: URL? = nil) -> String {
        let fileURL = logFileURL(in: directoryOverride)
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    private static func appendEntryToLogFile(
        level: String,
        category: String,
        sanitizedMessage: String,
        directoryOverride: URL?
    ) {
        fileWriteLock.lock()
        defer { fileWriteLock.unlock() }

        let targetURL = logFileURL(in: directoryOverride)
        let fm = FileManager.default
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] [\(category)] \(sanitizedMessage)\n"
        guard let lineData = line.data(using: .utf8) else { return }

        if fm.fileExists(atPath: targetURL.path) {
            let currentSize = (try? fm.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            if currentSize + Int64(lineData.count) > maxLogFileSizeBytes {
                try? fm.removeItem(at: targetURL)
            }
        }

        if fm.fileExists(atPath: targetURL.path),
           let handle = try? FileHandle(forWritingTo: targetURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: targetURL, options: .atomic)
        }
    }
}

// MARK: - App Settings

/// Central settings model. All properties persist via @AppStorage / UserDefaults.
/// Singleton access via AppSettings.shared.
@MainActor
final class AppSettings: ObservableObject {
    
    static let shared = AppSettings()

    let defaults: UserDefaults

    init(defaults: UserDefaults = AppStoragePaths.userDefaults) {
        self.defaults = defaults
        self._showInDock = AppStorage(wrappedValue: true, "settings.showInDock", store: defaults)
        self._showMenuBarExtra = AppStorage(wrappedValue: true, "settings.showMenuBarExtra", store: defaults)
        self._showCompletionNotification = AppStorage(wrappedValue: true, "settings.showCompletionNotification", store: defaults)
        self._playCompletionSound = AppStorage(wrappedValue: false, "settings.playCompletionSound", store: defaults)
        self._keepAppOpenAfterConversion = AppStorage(wrappedValue: true, "settings.keepAppOpenAfterConversion", store: defaults)
        self._defaultOutputLocationRaw = AppStorage(wrappedValue: DefaultOutputLocation.sameFolder.rawValue, "settings.defaultOutputLocation", store: defaults)
        self._customOutputDirectoryPath = AppStorage(wrappedValue: "", "settings.customOutputDirectoryPath", store: defaults)
        self._afterConversionActionRaw = AppStorage(wrappedValue: AfterConversionAction.revealInFinder.rawValue, "settings.afterConversionAction", store: defaults)
        self._existingFileHandlingRaw = AppStorage(wrappedValue: ExistingFileHandling.createUnique.rawValue, "settings.existingFileHandling", store: defaults)
        self._defaultImageQuality = AppStorage(wrappedValue: 0.90, "settings.defaultImageQuality", store: defaults)
        self._preserveMetadataByDefault = AppStorage(wrappedValue: true, "settings.preserveMetadataByDefault", store: defaults)
        self._defaultPDFDPI = AppStorage(wrappedValue: 150.0, "settings.defaultPDFDPI", store: defaults)
        self._concurrentConversionsRaw = AppStorage(wrappedValue: ConcurrentConversionLimit.automatic.rawValue, "settings.concurrentConversions", store: defaults)
        self._notifyOnConversionCompleted = AppStorage(wrappedValue: true, "settings.notifyOnConversionCompleted", store: defaults)
        self._notifyOnConversionFailed = AppStorage(wrappedValue: true, "settings.notifyOnConversionFailed", store: defaults)
        self._notifyOnBatchCompleted = AppStorage(wrappedValue: true, "settings.notifyOnBatchCompleted", store: defaults)
        self._appearanceModeRaw = AppStorage(wrappedValue: AppearanceMode.system.rawValue, "settings.appearanceMode", store: defaults)
        self._saveConversionHistory = AppStorage(wrappedValue: true, "settings.saveConversionHistory", store: defaults)
        self._historyAutoRemoveRaw = AppStorage(wrappedValue: HistoryAutoRemoveDuration.never.rawValue, "settings.historyAutoRemove", store: defaults)
        self._recentOutputFormatsRaw = AppStorage(wrappedValue: "webp,jpg,png,pdf,mp4,mp3", "settings.recentOutputFormats", store: defaults)
        self._rememberLastUsedOptions = AppStorage(wrappedValue: true, "settings.rememberLastUsedOptions", store: defaults)
        self._rememberedOptionsByFormatJSON = AppStorage(wrappedValue: "", "settings.rememberedOptionsByFormatJSON", store: defaults)
        self._rememberedAudioToolboxStateJSON = AppStorage(wrappedValue: "", "settings.rememberedAudioToolboxStateJSON", store: defaults)
        self._jobsRetentionPolicyRaw = AppStorage(wrappedValue: JobsRetentionPolicy.twentyFourHours.rawValue, "settings.jobsRetentionPolicy", store: defaults)
        self._failedJobsRetentionPolicyRaw = AppStorage(wrappedValue: FailedJobsRetentionPolicy.sevenDays.rawValue, "settings.failedJobsRetentionPolicy", store: defaults)
        self._editingHistoryMaxEntriesRaw = AppStorage(wrappedValue: EditingHistoryLimitDefaults.defaultMaxEntries, "settings.editingHistoryMaxEntries", store: defaults)
        self._recoveryArtifactStorageLimitMBRaw = AppStorage(wrappedValue: EditingHistoryLimitDefaults.defaultRecoveryStorageLimitMB, "settings.recoveryArtifactStorageLimitMB", store: defaults)
        self._audioAutoPauseArbitrationRaw = AppStorage(wrappedValue: true, "settings.audioAutoPauseArbitration", store: defaults)
        self._verboseLogging = AppStorage(wrappedValue: false, "settings.verboseLogging", store: defaults)
        migrateVisibilityPreferencesIfNeeded(defaults: defaults)
        PlaybackArbitrationCenter.shared.setAutoPauseEnabled(_audioAutoPauseArbitrationRaw.wrappedValue)
    }
    
    // MARK: - General & Application Visibility

    private var isUpdatingVisibilityMode: Bool = false

    @AppStorage("settings.showInDock")
    var showInDock: Bool = true {
        didSet {
            guard !isUpdatingVisibilityMode else { return }
            syncVisibilityModeStorage()
            AppLifecycleManager.shared.applyVisibilityPreferences(settings: self)
        }
    }
    
    @AppStorage("settings.showMenuBarExtra")
    var showMenuBarExtra: Bool = true {
        didSet {
            if defaults.bool(forKey: "settings.showInMenuBar") != showMenuBarExtra {
                defaults.set(showMenuBarExtra, forKey: "settings.showInMenuBar")
            }
            guard !isUpdatingVisibilityMode else { return }
            syncVisibilityModeStorage()
            AppLifecycleManager.shared.applyVisibilityPreferences(settings: self)
        }
    }

    /// Unified Menu Bar visibility property synchronized with legacy `showMenuBarExtra`.
    var showInMenuBar: Bool {
        get { showMenuBarExtra }
        set {
            defaults.set(newValue, forKey: "settings.showInMenuBar")
            showMenuBarExtra = newValue
        }
    }

    /// Unified 4-option Application Visibility mode mapped 1-to-1 with `(showInDock, showInMenuBar)` without feedback loops.
    var applicationVisibilityMode: ApplicationVisibilityMode {
        get {
            ApplicationVisibilityMode(showInDock: showInDock, showInMenuBar: showMenuBarExtra)
        }
        set {
            let dockChanged = (showInDock != newValue.showsInDock)
            let menuChanged = (showMenuBarExtra != newValue.showsInMenuBar)
            let targetDefaults = self.defaults

            if targetDefaults.string(forKey: "settings.applicationVisibilityMode") != newValue.rawValue {
                targetDefaults.set(newValue.rawValue, forKey: "settings.applicationVisibilityMode")
            }
            if targetDefaults.object(forKey: "settings.showInDock") == nil || targetDefaults.bool(forKey: "settings.showInDock") != newValue.showsInDock {
                targetDefaults.set(newValue.showsInDock, forKey: "settings.showInDock")
            }
            if targetDefaults.object(forKey: "settings.showMenuBarExtra") == nil || targetDefaults.bool(forKey: "settings.showMenuBarExtra") != newValue.showsInMenuBar {
                targetDefaults.set(newValue.showsInMenuBar, forKey: "settings.showMenuBarExtra")
            }
            if targetDefaults.object(forKey: "settings.showInMenuBar") == nil || targetDefaults.bool(forKey: "settings.showInMenuBar") != newValue.showsInMenuBar {
                targetDefaults.set(newValue.showsInMenuBar, forKey: "settings.showInMenuBar")
            }

            if dockChanged || menuChanged {
                isUpdatingVisibilityMode = true
                if dockChanged {
                    showInDock = newValue.showsInDock
                }
                if menuChanged {
                    showMenuBarExtra = newValue.showsInMenuBar
                }
                isUpdatingVisibilityMode = false
            }

            let targetCombo = AppLifecycleManager.combination(
                showInDock: newValue.showsInDock,
                showInMenuBar: newValue.showsInMenuBar
            )
            if dockChanged || menuChanged || AppLifecycleManager.shared.currentCombination != targetCombo {
                AppLifecycleManager.shared.applyVisibilityPreferences(settings: self)
            }
        }
    }

    private func syncVisibilityModeStorage(defaults: UserDefaults? = nil) {
        let targetDefaults = defaults ?? self.defaults
        let mode = ApplicationVisibilityMode(showInDock: showInDock, showInMenuBar: showMenuBarExtra)
        targetDefaults.set(mode.rawValue, forKey: "settings.applicationVisibilityMode")
    }

    /// Migrates legacy `settings.showMenuBarExtra`, `settings.showInMenuBar`, `settings.showInDock`, and `settings.applicationVisibilityMode` cleanly without losing user state.
    func migrateVisibilityPreferencesIfNeeded(defaults: UserDefaults? = nil) {
        let targetDefaults = defaults ?? self.defaults
        let hasMode = targetDefaults.string(forKey: "settings.applicationVisibilityMode") != nil
        let hasLegacyMenu = targetDefaults.object(forKey: "settings.showMenuBarExtra") != nil
        let hasNewMenu = targetDefaults.object(forKey: "settings.showInMenuBar") != nil
        let hasDock = targetDefaults.object(forKey: "settings.showInDock") != nil

        if !hasDock && !hasLegacyMenu && !hasNewMenu,
           hasMode,
           let rawMode = targetDefaults.string(forKey: "settings.applicationVisibilityMode"),
           let mode = ApplicationVisibilityMode(rawValue: rawMode) {
            targetDefaults.set(mode.showsInDock, forKey: "settings.showInDock")
            targetDefaults.set(mode.showsInMenuBar, forKey: "settings.showMenuBarExtra")
            targetDefaults.set(mode.showsInMenuBar, forKey: "settings.showInMenuBar")
            return
        }

        if hasLegacyMenu && !hasNewMenu {
            let legacyVal = targetDefaults.bool(forKey: "settings.showMenuBarExtra")
            targetDefaults.set(legacyVal, forKey: "settings.showInMenuBar")
        } else if !hasLegacyMenu && hasNewMenu {
            let newVal = targetDefaults.bool(forKey: "settings.showInMenuBar")
            targetDefaults.set(newVal, forKey: "settings.showMenuBarExtra")
            if targetDefaults === self.defaults {
                isUpdatingVisibilityMode = true
                showMenuBarExtra = newVal
                isUpdatingVisibilityMode = false
            }
        }
        if !hasDock {
            targetDefaults.set(true, forKey: "settings.showInDock")
        }

        let resolvedDock = targetDefaults.object(forKey: "settings.showInDock") != nil ? targetDefaults.bool(forKey: "settings.showInDock") : true
        let resolvedMenu = targetDefaults.object(forKey: "settings.showMenuBarExtra") != nil ? targetDefaults.bool(forKey: "settings.showMenuBarExtra") : true
        let resolvedMode = ApplicationVisibilityMode(showInDock: resolvedDock, showInMenuBar: resolvedMenu)
        targetDefaults.set(resolvedMode.rawValue, forKey: "settings.applicationVisibilityMode")
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

    @AppStorage("settings.rememberedOptionsByFormatJSON")
    private var rememberedOptionsByFormatJSON: String = ""

    @AppStorage("settings.rememberedAudioToolboxStateJSON")
    var rememberedAudioToolboxStateJSON: String = ""

    /// Whitelist of format-level custom option keys safe to remember across sessions (excludes transient/toolbox/file keys).
    static let allowedRememberedCustomOptionKeys: Set<String> = [
        "audio_codec",
        "audio_sample_rate",
        "audio_channels",
        "audio_bitrate_kbps",
        "audio_bitrate_mode",
        "audio_vbr_quality",
        "m4a_lossless",
        "jxl_lossless",
        "jxl_effort",
        "jxl_bit_depth",
        "pdf_archive",
        "vcodec",
        "acodec",
        "pix_fmt",
        "profile:v"
    ]

    /// Strips transient, file-specific, or destructive flags before persisting remembered format options.
    static func sanitizeOptionsForRemembering(_ options: ConversionOptions) -> ConversionOptions {
        var copy = options
        if copy.preset == .custom {
            copy.preset = nil
        }
        copy.overwriteExisting = false
        copy.videoTrim = nil
        copy.customOptions = copy.customOptions.filter { key, _ in
            allowedRememberedCustomOptionKeys.contains(key)
        }
        return copy
    }

    func recordLastUsedOptions(_ options: ConversionOptions, for format: FileFormat) {
        guard rememberLastUsedOptions else { return }
        var map = decodeRememberedOptionsMap()
        map[format.rawValue] = Self.sanitizeOptionsForRemembering(options)
        if let encoded = try? JSONEncoder().encode(map),
           let json = String(data: encoded, encoding: .utf8) {
            rememberedOptionsByFormatJSON = json
        }
    }

    func rememberedOptions(for format: FileFormat, inputFormat: FileFormat? = nil) -> ConversionOptions? {
        guard rememberLastUsedOptions else { return nil }
        let map = decodeRememberedOptionsMap()
        guard var saved = map[format.rawValue] else { return nil }

        // Apply current global collision handling preference without persisting destructive overwrite
        saved.overwriteExisting = (existingFileHandling == .overwrite)
        if existingFileHandling == .skip {
            saved.customOptions["existing_file_handling"] = ExistingFileHandling.skip.rawValue
        } else {
            saved.customOptions.removeValue(forKey: "existing_file_handling")
        }

        if let inFmt = inputFormat, let activePreset = saved.effectivePreset {
            let supported = ConversionRegistry.shared.supportedPresets(from: inFmt, to: format)
            if !supported.contains(activePreset) {
                saved.preset = nil
                saved.clearPresetOwnedHiddenOptions()
            }
        }
        return saved
    }

    func initialOptionsForNewFile(inputFormat: FileFormat?, outputFormat: FileFormat?) -> ConversionOptions {
        guard rememberLastUsedOptions,
              let outFmt = outputFormat,
              let remembered = rememberedOptions(for: outFmt, inputFormat: inputFormat) else {
            return defaultConversionOptions
        }
        return remembered
    }

    func clearRememberedOptions() {
        rememberedOptionsByFormatJSON = ""
        rememberedAudioToolboxStateJSON = ""
    }

    private func decodeRememberedOptionsMap() -> [String: ConversionOptions] {
        guard !rememberedOptionsByFormatJSON.isEmpty,
              let data = rememberedOptionsByFormatJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: ConversionOptions].self, from: data) else {
            return [:]
        }
        return decoded
    }
    
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
    
    // MARK: - Undo & Editing History

    @AppStorage("settings.editingHistoryMaxEntries")
    private var editingHistoryMaxEntriesRaw: Int = EditingHistoryLimitDefaults.defaultMaxEntries

    var editingHistoryMaxEntries: Int {
        get { EditingHistoryLimitDefaults.clampedEntries(editingHistoryMaxEntriesRaw) }
        set { editingHistoryMaxEntriesRaw = EditingHistoryLimitDefaults.clampedEntries(newValue) }
    }

    @AppStorage("settings.recoveryArtifactStorageLimitMB")
    private var recoveryArtifactStorageLimitMBRaw: Int = EditingHistoryLimitDefaults.defaultRecoveryStorageLimitMB

    var recoveryArtifactStorageLimitMB: Int {
        get { EditingHistoryLimitDefaults.clampedStorageLimitMB(recoveryArtifactStorageLimitMBRaw) }
        set { recoveryArtifactStorageLimitMBRaw = EditingHistoryLimitDefaults.clampedStorageLimitMB(newValue) }
    }

    var recoveryArtifactStorageLimitBytes: Int64 {
        Int64(recoveryArtifactStorageLimitMB) * 1_024 * 1_024
    }

    // MARK: - Audio Workspace Preferences

    @AppStorage("settings.audioAutoPauseArbitration")
    private var audioAutoPauseArbitrationRaw: Bool = true

    var audioAutoPauseArbitration: Bool {
        get { audioAutoPauseArbitrationRaw }
        set {
            audioAutoPauseArbitrationRaw = newValue
            PlaybackArbitrationCenter.shared.setAutoPauseEnabled(newValue)
            objectWillChange.send()
        }
    }

    // MARK: - Advanced / Diagnostics
    
    @AppStorage("settings.verboseLogging")
    var verboseLogging: Bool = false
    
    // MARK: - Reset to Defaults
    
    /// Resets all settings to factory defaults.
    func resetToDefaults() {
        applicationVisibilityMode = .both
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
        clearRememberedOptions()
        jobsRetentionPolicyRaw = JobsRetentionPolicy.twentyFourHours.rawValue
        failedJobsRetentionPolicyRaw = FailedJobsRetentionPolicy.sevenDays.rawValue
        editingHistoryMaxEntriesRaw = EditingHistoryLimitDefaults.defaultMaxEntries
        recoveryArtifactStorageLimitMBRaw = EditingHistoryLimitDefaults.defaultRecoveryStorageLimitMB
        audioAutoPauseArbitration = true
        verboseLogging = false

        if self === AppSettings.shared || defaults === AppStoragePaths.userDefaults {
            AppState.shared?.syncOutputPreferencesToDefaults()
        }
        OutputManager.resetPreferences(defaults: defaults)
        if self === AppSettings.shared && defaults !== AppStoragePaths.userDefaults {
            OutputManager.resetPreferences(defaults: AppStoragePaths.userDefaults)
        }
    }
    
    // MARK: - Derived ConversionOptions
    
    /// Returns a ConversionOptions pre-filled with the current default settings.
    var defaultConversionOptions: ConversionOptions {
        var custom: [String: String] = [:]
        if existingFileHandling == .skip {
            custom["existing_file_handling"] = ExistingFileHandling.skip.rawValue
        }
        return ConversionOptions(
            preserveMetadata: preserveMetadataByDefault,
            overwriteExisting: existingFileHandling == .overwrite,
            imageQuality: defaultImageQuality,
            pdfDPI: defaultPDFDPI,
            pdfOfficeMode: .automatic,
            webpLossless: false,
            mediaQuality: .high,
            customOptions: custom
        )
    }
}
