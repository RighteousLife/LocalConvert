import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Menu Bar Drop-to-Convert Models & Session

struct MenuBarRejectedDropEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let reason: String

    init(
        id: UUID = UUID(),
        url: URL,
        filename: String? = nil,
        reason: String
    ) {
        self.id = id
        self.url = url
        let candidate = filename ?? url.lastPathComponent
        self.filename = candidate.isEmpty ? url.path : candidate
        self.reason = reason
    }
}

struct MenuBarDropValidationResult: Equatable, Sendable {
    let validURLs: [URL]
    let rejectedEntries: [MenuBarRejectedDropEntry]

    init(
        validURLs: [URL] = [],
        rejectedEntries: [MenuBarRejectedDropEntry] = []
    ) {
        self.validURLs = validURLs
        self.rejectedEntries = rejectedEntries
    }

    var hasValidFiles: Bool { !validURLs.isEmpty }
    var hasRejectedFiles: Bool { !rejectedEntries.isEmpty }
}

struct MenuBarCompatiblePreset: Identifiable, Sendable {
    let preset: SavedPreset
    let validation: PresetBatchValidationResult

    var id: UUID { preset.id }
    var isFullyCompatible: Bool { validation.isFullyCompatible }
    var compatibleCount: Int { validation.compatibleCount }
    var totalCount: Int { validation.totalCount }
}

@MainActor
final class MenuBarDropSession: ObservableObject {

    @Published private(set) var stagedFileURLs: [URL] = []
    @Published private(set) var rejectedEntries: [MenuBarRejectedDropEntry] = []
    @Published private(set) var compatiblePresets: [MenuBarCompatiblePreset] = []
    @Published private(set) var isPopoverPresented: Bool = false

    var stagedFilenames: [String] {
        stagedFileURLs.map(\.lastPathComponent)
    }

    var hasStagedFiles: Bool {
        !stagedFileURLs.isEmpty
    }

    nonisolated static func validateDroppedURLs(
        _ urls: [URL],
        registry: ConversionRegistry = .shared,
        fileDetector: FileDetector = FileDetector()
    ) -> MenuBarDropValidationResult {
        var validURLs: [URL] = []
        var rejectedEntries: [MenuBarRejectedDropEntry] = []
        var seenStandardizedPaths = Set<String>()

        for rawURL in urls {
            guard rawURL.isFileURL else {
                rejectedEntries.append(
                    MenuBarRejectedDropEntry(
                        url: rawURL,
                        filename: rawURL.absoluteString,
                        reason: String(localized: "Only local files can be dropped.")
                    )
                )
                continue
            }

            let nsURL = rawURL as NSURL
            let pathURL = nsURL.isFileReferenceURL() ? (nsURL.filePathURL ?? rawURL) : rawURL

            // Enforce FinderIntegration regular-file, symlink, directory, traversal, and readability checks.
            switch FinderHandoffHandler.validateSchemeFilePath(pathURL.path) {
            case .failure(let error):
                rejectedEntries.append(
                    MenuBarRejectedDropEntry(
                        url: pathURL,
                        reason: error.localizedDescription
                    )
                )
            case .success(let safeURL):
                let dedupKey = safeURL.standardizedFileURL.path
                guard seenStandardizedPaths.insert(dedupKey).inserted else {
                    continue
                }

                let sanitized = FinderHandoffHandler.validateAndSanitize(
                    urls: [safeURL],
                    registry: registry,
                    fileDetector: fileDetector
                )
                if let validURL = sanitized.validURLs.first {
                    validURLs.append(validURL)
                } else if !sanitized.rejectedFolders.isEmpty {
                    rejectedEntries.append(
                        MenuBarRejectedDropEntry(
                            url: safeURL,
                            reason: String(localized: "Folder input is not supported: \(safeURL.lastPathComponent)")
                        )
                    )
                } else if !sanitized.inaccessibleURLs.isEmpty {
                    rejectedEntries.append(
                        MenuBarRejectedDropEntry(
                            url: safeURL,
                            reason: String(localized: "File is not readable: \(safeURL.lastPathComponent)")
                        )
                    )
                } else {
                    rejectedEntries.append(
                        MenuBarRejectedDropEntry(
                            url: safeURL,
                            reason: String(localized: "Unsupported or unrecognized file format: \(safeURL.lastPathComponent)")
                        )
                    )
                }
            }
        }

        return MenuBarDropValidationResult(
            validURLs: validURLs,
            rejectedEntries: rejectedEntries
        )
    }

    nonisolated static func filterCompatiblePresets(
        for fileURLs: [URL],
        presets: [SavedPreset],
        validator: PresetValidator = PresetValidator(),
        fileDetector: FileDetector = FileDetector(),
        registry: ConversionRegistry = .shared
    ) -> [MenuBarCompatiblePreset] {
        guard !fileURLs.isEmpty else { return [] }

        var indexedMatches: [(index: Int, item: MenuBarCompatiblePreset)] = []
        for (index, preset) in presets.enumerated() {
            guard validator.isPresetValid(preset, registry: registry).isValid else {
                continue
            }
            let validation = validator.validateBatch(
                preset: preset,
                urls: fileURLs,
                fileDetector: fileDetector,
                registry: registry
            )
            guard validation.hasCompatibleFiles else {
                continue
            }
            indexedMatches.append(
                (index, MenuBarCompatiblePreset(preset: preset, validation: validation))
            )
        }

        indexedMatches.sort { lhs, rhs in
            if lhs.item.isFullyCompatible != rhs.item.isFullyCompatible {
                return lhs.item.isFullyCompatible && !rhs.item.isFullyCompatible
            }
            return lhs.index < rhs.index
        }

        return indexedMatches.map(\.item)
    }

    @discardableResult
    func stageDroppedURLs(
        _ urls: [URL],
        presets: [SavedPreset],
        validator: PresetValidator = PresetValidator(),
        registry: ConversionRegistry = .shared,
        fileDetector: FileDetector = FileDetector()
    ) -> MenuBarDropValidationResult {
        let result = Self.validateDroppedURLs(
            urls,
            registry: registry,
            fileDetector: fileDetector
        )
        stagedFileURLs = result.validURLs
        rejectedEntries = result.rejectedEntries
        compatiblePresets = Self.filterCompatiblePresets(
            for: result.validURLs,
            presets: presets,
            validator: validator,
            fileDetector: fileDetector,
            registry: registry
        )
        isPopoverPresented = result.hasValidFiles || result.hasRejectedFiles
        return result
    }

    @discardableResult
    func executePreset(
        _ preset: SavedPreset,
        appState: AppState,
        presetExecutor: PresetExecutor = PresetExecutor(),
        fileDetector: FileDetector = FileDetector(),
        registry: ConversionRegistry = .shared
    ) -> PresetExecutionReport? {
        guard !stagedFileURLs.isEmpty else {
            clearStagedDrop()
            return nil
        }

        let recheck = Self.validateDroppedURLs(
            stagedFileURLs,
            registry: registry,
            fileDetector: fileDetector
        )
        guard !recheck.validURLs.isEmpty else {
            clearStagedDrop()
            return nil
        }

        let report = presetExecutor.execute(
            preset: preset,
            inputURLs: recheck.validURLs,
            conversionManager: appState.conversionManager,
            conversionQueue: appState.conversionQueue,
            destinationOverride: nil,
            defaultOutputLocation: appState.outputLocation,
            customOutputDirectory: appState.customOutputDirectory,
            source: .manual,
            fileDetector: fileDetector,
            registry: registry
        )

        clearStagedDrop()
        return report
    }

    func openInConvertTab(appState: AppState, activateWindow: Bool = true) {
        let urls = stagedFileURLs
        clearStagedDrop()
        guard !urls.isEmpty else { return }

        appState.handleDroppedURLs(urls)
        appState.selectedTab = .convert
        if activateWindow {
            AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .convert, appState: appState)
        }
    }

    func cancel() {
        clearStagedDrop()
    }

    func clearStagedDrop() {
        stagedFileURLs = []
        rejectedEntries = []
        compatiblePresets = []
        isPopoverPresented = false
    }
}

// MARK: - Menu Bar Drop Popover View

struct MenuBarDropPopoverView: View {
    @ObservedObject var session: MenuBarDropSession
    let onSelectPreset: (SavedPreset) -> Void
    let onOpenInConvertTab: () -> Void
    let onCancel: () -> Void

    private let fileDetector = FileDetector()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(session.hasStagedFiles ? AppTheme.Colors.accentTint : AppTheme.Colors.warningTint)
                        .frame(width: 28, height: 28)

                    Image(systemName: session.hasStagedFiles ? "arrow.down.doc.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(session.hasStagedFiles ? AppTheme.Colors.accent : AppTheme.Colors.warning)
                }
                .accessibilityHidden(true)

                Text(session.hasStagedFiles ? String(localized: "Drop to Convert") : String(localized: "Drop Rejected"))
                    .font(AppTheme.Typography.sectionTitle)

                if session.hasStagedFiles {
                    let countText = session.stagedFileURLs.count == 1
                        ? String(localized: "1 file")
                        : String(localized: "\(session.stagedFileURLs.count) files")
                    AppStatusBadge(
                        text: countText,
                        tint: AppTheme.Colors.accent
                    )
                }

                Spacer()

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss and clear staged files")
                .accessibilityLabel("Dismiss dropped files")
                .accessibilityIdentifier("menubar.drop.dismiss")
            }

            if session.hasStagedFiles {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        ForEach(session.stagedFileURLs, id: \.standardizedFileURL) { url in
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Image(systemName: "doc.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(url.lastPathComponent)
                                    .font(AppTheme.Typography.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: AppTheme.Spacing.xs)

                                if let format = fileDetector.detect(url: url).bestFormat {
                                    AppStatusBadge(text: format.displayName, tint: .secondary, style: .rounded)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 110)
                .padding(AppTheme.Spacing.sm)
                .background(AppTheme.Colors.cardBackground.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                )
            }

            if !session.rejectedEntries.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(session.rejectedEntries.count == 1
                        ? String(localized: "1 item skipped")
                        : String(localized: "\(session.rejectedEntries.count) items skipped"))
                        .font(AppTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.warning)

                    ForEach(session.rejectedEntries.prefix(3)) { entry in
                        Text(verbatim: "• \(entry.filename): \(entry.reason)")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if session.rejectedEntries.count > 3 {
                        Text("…and \(session.rejectedEntries.count - 3) more")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(AppTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Colors.warningTint)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Colors.warning.opacity(0.28), lineWidth: 1)
                )
            }

            if session.hasStagedFiles {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                    Text("Quick Presets")
                        .font(AppTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if session.compatiblePresets.isEmpty {
                        Text("No saved presets match these files. Open in Convert Tab to pick an output format.")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ScrollView {
                            VStack(spacing: AppTheme.Spacing.xs) {
                                ForEach(session.compatiblePresets) { item in
                                    MenuBarPresetRowButton(
                                        item: item,
                                        onSelect: { onSelectPreset(item.preset) }
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: 165)
                    }
                }
            }

            AppDivider()

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("menubar.drop.cancel")

                Spacer()

                if session.hasStagedFiles {
                    Button {
                        onOpenInConvertTab()
                    } label: {
                        Label("Open in Convert Tab", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("menubar.drop.openInConvert")
                }
            }
        }
        .padding(AppTheme.Spacing.md + 2)
        .frame(width: 332)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar.drop.popover")
    }
}

private struct MenuBarPresetRowButton: View {
    let item: MenuBarCompatiblePreset
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.accent)

                Text(item.preset.name)
                    .font(AppTheme.Typography.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: AppTheme.Spacing.xs)

                if !item.isFullyCompatible {
                    Text(verbatim: "\(item.compatibleCount)/\(item.totalCount)")
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                }

                AppStatusBadge(
                    text: "→ \(item.preset.targetFormat.displayName)",
                    tint: AppTheme.Colors.accent,
                    style: .rounded
                )
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered
                    ? AppTheme.Colors.accentTint.opacity(0.65)
                    : AppTheme.Colors.cardBackground.opacity(0.85)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isHovered ? AppTheme.Colors.accent.opacity(0.45) : AppTheme.Colors.cardBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(String(localized: "Run preset \(item.preset.name)"))
        .accessibilityIdentifier("menubar.drop.preset.\(item.preset.id.uuidString)")
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var dropSession: MenuBarDropSession

    init(
        appState: AppState,
        dropSession: MenuBarDropSession = MenuBarManager.shared.dropSession
    ) {
        self.appState = appState
        self.dropSession = dropSession
    }
    
    var body: some View {
        Group {
            Text("LocalConvert")
            
            if appState.isConverting {
                let progressPercent = Int(appState.batchProgress * 100)
                Text("\(appState.activeJobCount) conversions running · \(progressPercent)%")
            } else if appState.isBatchCompleted {
                Text("All conversions completed")
            } else {
                Text("Ready")
            }

            if !appState.watchFolderManager.rules.isEmpty {
                Text(MenuBarManager.watchFolderStatusSummary(for: appState))
            }

            if dropSession.hasStagedFiles || !dropSession.rejectedEntries.isEmpty {
                Divider()

                Section(String(localized: "Dropped Files (\(dropSession.stagedFileURLs.count))")) {
                    ForEach(dropSession.stagedFileURLs, id: \.standardizedFileURL) { url in
                        Text(url.lastPathComponent)
                    }

                    ForEach(dropSession.compatiblePresets) { item in
                        Button(String(localized: "Convert with \(item.preset.name) (→ \(item.preset.targetFormat.displayName))")) {
                            _ = dropSession.executePreset(item.preset, appState: appState)
                        }
                    }

                    if dropSession.hasStagedFiles {
                        Button("Open in Convert Tab") {
                            dropSession.openInConvertTab(appState: appState)
                        }
                    }

                    Button("Cancel Dropped Files") {
                        dropSession.cancel()
                    }
                }
            }
            
            Divider()
            
            Button("Open LocalConvert") {
                activateAppAndShowTab(.convert)
            }
            
            Button("Add Files to Convert...") {
                openFilePicker()
            }

            Menu("Capture Screen to Markup") {
                Button("Instant") {
                    triggerScreenCapture(delay: .instant)
                }
                Button("3s Timer") {
                    triggerScreenCapture(delay: .threeSeconds)
                }
                Button("5s Timer") {
                    triggerScreenCapture(delay: .fiveSeconds)
                }
            }

            Button("Quick QR Generator...") {
                AppLifecycleManager.shared.restoreOrActivateMainWindow(appState: appState)
                QuickQRGeneratorController.shared.open()
            }

            Button("Keyboard Shortcuts...") {
                AppLifecycleManager.shared.restoreOrActivateMainWindow(appState: appState)
                KeyboardShortcutsSheetController.shared.open()
            }
            .keyboardShortcut("/", modifiers: .command)
            
            Divider()
            
            Button("Open Jobs Center") {
                activateAppAndShowTab(.jobs)
            }
            
            Button("Open Presets") {
                activateAppAndShowTab(.presets)
            }

            if !appState.watchFolderManager.rules.isEmpty {
                Button(appState.watchFolderManager.isGloballyPaused ? String(localized: "Resume Watch Folders") : String(localized: "Pause Watch Folders")) {
                    if appState.watchFolderManager.isGloballyPaused {
                        appState.watchFolderManager.resumeAll()
                    } else {
                        appState.watchFolderManager.pauseAll()
                    }
                }
            }
            
            Button("Settings...") {
                activateAppAndShowTab(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
            
            Divider()
            
            Button("Quit LocalConvert") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
    
    private func activateAppAndShowTab(_ tab: AppNavigationTab) {
        AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: tab, appState: appState)
    }

    private func triggerScreenCapture(delay: ScreenCaptureDelay) {
        AppLifecycleManager.shared.restoreOrActivateMainWindow(appState: appState)
        Task { @MainActor in
            do {
                _ = try await ScreenCaptureService.shared.captureToMediaViewer(delay: delay, appState: appState)
            } catch {
                appState.showError(
                    title: String(localized: "Screen Capture Failed"),
                    message: error.localizedDescription
                )
            }
        }
    }
    
    private func openFilePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState.addFiles(urls: panel.urls)
            AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: .convert, appState: appState)
        }
    }
}

// MARK: - Status Item Drop Target View

@MainActor
final class StatusItemDropTargetView: NSView {
    var onHighlightChanged: (@MainActor (Bool) -> Void)?
    var onFilesDropped: (@MainActor ([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        superview?.otherMouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard Self.canAcceptDrag(sender.draggingPasteboard) else {
            onHighlightChanged?(false)
            return []
        }
        onHighlightChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.canAcceptDrag(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHighlightChanged?(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onHighlightChanged?(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.canAcceptDrag(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onHighlightChanged?(false)
        let urls = FinderHandoffHandler.extractPasteboardURLs(sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    static func canAcceptDrag(_ pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: options) {
            return true
        }
        return pasteboard.types?.contains(.fileURL) == true
    }
}

// MARK: - Native Menu Bar Status Item Manager

@MainActor
final class MenuBarManager: NSObject, NSPopoverDelegate {
    static let shared = MenuBarManager()
    
    private var statusItem: NSStatusItem?
    private weak var appState: AppState?
    let dropSession = MenuBarDropSession()
    private var dropTargetView: StatusItemDropTargetView?
    private var dropPopover: NSPopover?
    private var isReplacingDropPopover: Bool = false

    private(set) var isMenuBarExtraActive: Bool = true
    private(set) var statusItemCreationCount: Int = 0
    private(set) var menuRebuildCount: Int = 0
    private var lastRenderedStatusSignature: String?
    private var lastAppliedIconIsConverting: Bool?
    var allowSystemStatusItemInTests: Bool = false

    var hasLiveStatusItem: Bool {
        statusItem != nil
    }

    var registeredDragTypes: [NSPasteboard.PasteboardType] {
        dropTargetView?.registeredDraggedTypes ?? []
    }

    var isDropPopoverShown: Bool {
        dropPopover?.isShown ?? false
    }
    
    func setup(appState: AppState) {
        self.appState = appState
        updateVisibility(showInMenuBar: AppSettings.shared.showInMenuBar)
    }

    static func watchFolderStatusSummary(for appState: AppState) -> String {
        let manager = appState.watchFolderManager
        if manager.isGloballyPaused {
            return String(localized: "Watch Folders: Paused (\(manager.rules.count))")
        }
        let activeCount = manager.rules.filter { $0.isEnabled && !$0.isPaused && !$0.lastStatus.isError }.count
        let errorCount = manager.rules.filter { $0.lastStatus.isError }.count
        if errorCount > 0 {
            return String(localized: "Watch Folders: \(activeCount) active · \(errorCount) attention")
        }
        return String(localized: "Watch Folders: \(activeCount) active")
    }

    private func computeStatusString(for appState: AppState) -> String {
        if appState.isConverting {
            let progressPercent = Int(appState.batchProgress * 100)
            return String(localized: "\(appState.activeJobCount) conversions running · \(progressPercent)%")
        } else if appState.isBatchCompleted {
            return String(localized: "All conversions completed")
        } else {
            return String(localized: "Ready")
        }
    }
    
    func updateVisibility(showInMenuBar: Bool? = nil) {
        let shouldShow = showInMenuBar ?? AppSettings.shared.showInMenuBar
        isMenuBarExtraActive = shouldShow

        let isTesting = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isTesting || allowSystemStatusItemInTests else {
            if !shouldShow {
                teardownStatusItem()
            }
            return
        }
        
        if shouldShow {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem = item
                statusItemCreationCount += 1
                lastAppliedIconIsConverting = nil
                configureDropTarget(for: item)
                updateButtonImageIfNeeded()
                rebuildMenu(force: true)
            } else {
                if let item = statusItem, dropTargetView == nil {
                    configureDropTarget(for: item)
                }
                updateButtonImageIfNeeded()
                rebuildMenu(force: false)
            }
        } else {
            teardownStatusItem()
        }
    }

    private func teardownStatusItem() {
        dismissDropPopover(clearSession: true)
        dropTargetView?.removeFromSuperview()
        dropTargetView = nil
        if let item = statusItem {
            item.menu = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            lastRenderedStatusSignature = nil
            lastAppliedIconIsConverting = nil
        }
    }

    private func configureDropTarget(for item: NSStatusItem) {
        guard let button = item.button else { return }
        button.registerForDraggedTypes([.fileURL])

        dropTargetView?.removeFromSuperview()
        let target = StatusItemDropTargetView(frame: button.bounds)
        target.autoresizingMask = [.width, .height]
        target.onHighlightChanged = { [weak button] isHighlighted in
            button?.highlight(isHighlighted)
        }
        target.onFilesDropped = { [weak self] urls in
            self?.handleDroppedFileURLs(urls)
        }
        button.addSubview(target)
        dropTargetView = target
    }
    
    func updateStatus() {
        guard statusItem != nil else { return }
        updateButtonImageIfNeeded()
        rebuildMenu(force: false)
    }

    @discardableResult
    func handleDroppedFileURLs(
        _ urls: [URL],
        presets: [SavedPreset]? = nil,
        registry: ConversionRegistry = .shared,
        fileDetector: FileDetector = FileDetector()
    ) -> MenuBarDropValidationResult {
        let availablePresets = presets ?? PresetManager.shared.presets
        let result = dropSession.stageDroppedURLs(
            urls,
            presets: availablePresets,
            registry: registry,
            fileDetector: fileDetector
        )
        if dropSession.isPopoverPresented {
            presentDropPopover()
        } else {
            dismissDropPopover(clearSession: false)
        }
        return result
    }

    @discardableResult
    func executeStagedPreset(_ preset: SavedPreset) -> PresetExecutionReport? {
        guard let appState else {
            cancelStagedDrop()
            return nil
        }
        let report = dropSession.executePreset(preset, appState: appState)
        dismissDropPopover(clearSession: false)
        updateStatus()
        return report
    }

    func openStagedFilesInConvertTab(activateWindow: Bool = true) {
        guard let appState else {
            cancelStagedDrop()
            return
        }
        dropSession.openInConvertTab(appState: appState, activateWindow: activateWindow)
        dismissDropPopover(clearSession: false)
    }

    func cancelStagedDrop() {
        dismissDropPopover(clearSession: true)
    }

    private func presentDropPopover() {
        guard let button = statusItem?.button, button.window != nil else { return }

        if let existing = dropPopover, existing.isShown {
            isReplacingDropPopover = true
            existing.performClose(nil)
            isReplacingDropPopover = false
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let rootView = MenuBarDropPopoverView(
            session: dropSession,
            onSelectPreset: { [weak self] preset in
                _ = self?.executeStagedPreset(preset)
            },
            onOpenInConvertTab: { [weak self] in
                self?.openStagedFilesInConvertTab()
            },
            onCancel: { [weak self] in
                self?.cancelStagedDrop()
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        popover.contentViewController = hostingController
        dropPopover = popover

        NSApp?.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func dismissDropPopover(clearSession: Bool) {
        if clearSession {
            dropSession.clearStagedDrop()
        }
        if let popover = dropPopover {
            isReplacingDropPopover = !clearSession
            popover.performClose(nil)
            isReplacingDropPopover = false
            dropPopover = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard !isReplacingDropPopover else { return }
        guard (notification.object as? NSPopover) === dropPopover else { return }
        dropPopover = nil
        dropSession.clearStagedDrop()
    }

    private func updateButtonImageIfNeeded() {
        guard let item = statusItem, let button = item.button else { return }
        let converting = appState?.isConverting ?? false
        guard lastAppliedIconIsConverting != converting || button.image == nil else { return }
        if converting {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: String(localized: "LocalConvert - Converting"))
        } else {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "LocalConvert")
        }
        lastAppliedIconIsConverting = converting
    }
    
    private func rebuildMenu(force: Bool = false) {
        guard let item = statusItem, let appState = appState else { return }
        let statusString = computeStatusString(for: appState)
        let watchRules = appState.watchFolderManager.rules
        let watchSummary = watchRules.isEmpty ? nil : Self.watchFolderStatusSummary(for: appState)
        let isWatchPaused = appState.watchFolderManager.isGloballyPaused
        let signature = "\(statusString)|\(watchSummary ?? "")|\(isWatchPaused)"
        if !force, item.menu != nil, lastRenderedStatusSignature == signature {
            return
        }
        lastRenderedStatusSignature = signature
        menuRebuildCount += 1

        let menu = NSMenu()
        
        let titleItem = NSMenuItem(title: "LocalConvert", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        let statusMenuItem = NSMenuItem(title: statusString, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        if let watchSummary {
            let watchStatusItem = NSMenuItem(title: watchSummary, action: nil, keyEquivalent: "")
            watchStatusItem.isEnabled = false
            menu.addItem(watchStatusItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        let openItem = NSMenuItem(title: String(localized: "Open LocalConvert"), action: #selector(openMainApp), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        
        let addFilesItem = NSMenuItem(title: String(localized: "Add Files to Convert..."), action: #selector(openFilePicker), keyEquivalent: "")
        addFilesItem.target = self
        menu.addItem(addFilesItem)

        let captureParentItem = NSMenuItem(title: String(localized: "Capture Screen to Markup"), action: nil, keyEquivalent: "")
        let captureSubmenu = NSMenu()
        let captureInstant = NSMenuItem(title: String(localized: "Instant"), action: #selector(captureScreenInstant), keyEquivalent: "")
        captureInstant.target = self
        captureSubmenu.addItem(captureInstant)
        let captureThree = NSMenuItem(title: String(localized: "3s Timer"), action: #selector(captureScreenThreeSeconds), keyEquivalent: "")
        captureThree.target = self
        captureSubmenu.addItem(captureThree)
        let captureFive = NSMenuItem(title: String(localized: "5s Timer"), action: #selector(captureScreenFiveSeconds), keyEquivalent: "")
        captureFive.target = self
        captureSubmenu.addItem(captureFive)
        captureParentItem.submenu = captureSubmenu
        menu.addItem(captureParentItem)

        let quickQRItem = NSMenuItem(title: String(localized: "Quick QR Generator..."), action: #selector(openQuickQRGenerator), keyEquivalent: "")
        quickQRItem.target = self
        menu.addItem(quickQRItem)

        let shortcutsItem = NSMenuItem(title: String(localized: "Keyboard Shortcuts..."), action: #selector(openKeyboardShortcuts), keyEquivalent: "/")
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let jobsItem = NSMenuItem(title: String(localized: "Open Jobs Center"), action: #selector(openJobsCenter), keyEquivalent: "")
        jobsItem.target = self
        menu.addItem(jobsItem)
        
        let presetsItem = NSMenuItem(title: String(localized: "Open Presets"), action: #selector(openPresets), keyEquivalent: "")
        presetsItem.target = self
        menu.addItem(presetsItem)

        if !watchRules.isEmpty {
            let watchToggleTitle = isWatchPaused
                ? String(localized: "Resume Watch Folders")
                : String(localized: "Pause Watch Folders")
            let watchToggleItem = NSMenuItem(title: watchToggleTitle, action: #selector(togglePauseWatchFolders), keyEquivalent: "")
            watchToggleItem.target = self
            menu.addItem(watchToggleItem)
        }
        
        let settingsItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: String(localized: "Quit LocalConvert"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        item.menu = menu
    }
    
    @objc private func openMainApp() {
        activateAppAndShowTab(.convert)
    }

    @objc private func captureScreenInstant() {
        triggerScreenCapture(delay: .instant)
    }

    @objc private func captureScreenThreeSeconds() {
        triggerScreenCapture(delay: .threeSeconds)
    }

    @objc private func captureScreenFiveSeconds() {
        triggerScreenCapture(delay: .fiveSeconds)
    }

    @objc private func openQuickQRGenerator() {
        showMainWindow()
        QuickQRGeneratorController.shared.open()
    }

    @objc private func openKeyboardShortcuts() {
        showMainWindow()
        KeyboardShortcutsSheetController.shared.open()
    }

    private func triggerScreenCapture(delay: ScreenCaptureDelay) {
        guard let appState else { return }
        showMainWindow()
        Task { @MainActor in
            do {
                _ = try await ScreenCaptureService.shared.captureToMediaViewer(delay: delay, appState: appState)
            } catch {
                appState.showError(
                    title: String(localized: "Screen Capture Failed"),
                    message: error.localizedDescription
                )
            }
        }
    }
    
    @objc private func openFilePicker() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState?.addFiles(urls: panel.urls)
            appState?.selectedTab = .convert
            showMainWindow()
        }
    }
    
    @objc private func openJobsCenter() {
        activateAppAndShowTab(.jobs)
    }
    
    @objc private func openPresets() {
        activateAppAndShowTab(.presets)
    }

    @objc private func togglePauseWatchFolders() {
        guard let manager = appState?.watchFolderManager else { return }
        if manager.isGloballyPaused {
            manager.resumeAll()
        } else {
            manager.pauseAll()
        }
        updateStatus()
    }
    
    @objc private func openSettings() {
        activateAppAndShowTab(.settings)
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func activateAppAndShowTab(_ tab: AppNavigationTab) {
        AppLifecycleManager.shared.restoreOrActivateMainWindow(selectTab: tab, appState: appState)
    }
    
    private func showMainWindow() {
        AppLifecycleManager.shared.restoreOrActivateMainWindow(appState: appState)
    }
}
