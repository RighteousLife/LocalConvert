import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Duplicate Finder Sheet Controller

@MainActor
final class DuplicateFinderSheetController: ObservableObject {
    static let shared = DuplicateFinderSheetController()

    @Published var isPresented: Bool = false
    @Published var initialDirectoryURL: URL?

    init(isPresented: Bool = false, initialDirectoryURL: URL? = nil) {
        self.isPresented = isPresented
        self.initialDirectoryURL = initialDirectoryURL
    }

    func open(directoryURL: URL? = nil) {
        if let directoryURL {
            initialDirectoryURL = directoryURL
        }
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}

// MARK: - Duplicate Finder Sheet View

struct DuplicateFinderSheetView: View {
    @ObservedObject var controller: DuplicateFinderSheetController

    private let directoryPicker: (@MainActor () -> URL?)?
    private let trashHandler: DuplicateFileScannerEngine.TrashHandler
    private let onRemoveTrashedURLs: ((Set<URL>) -> Void)?

    @State private var selectedDirectoryURL: URL? = nil
    @State private var includeSubdirectories: Bool = true
    @State private var keepPolicy: DuplicateKeepPolicy = .newest
    @State private var isScanning: Bool = false
    @State private var scanProgress: DuplicateScanProgress? = nil
    @State private var scanResult: DuplicateScanResult? = nil
    @State private var selectedToTrash: Set<URL> = []
    @State private var statusBanner: String? = nil
    @State private var errorMessage: String? = nil
    @State private var isDropTargeted: Bool = false
    @State private var scanTask: Task<Void, Never>? = nil

    init(
        controller: DuplicateFinderSheetController = .shared,
        directoryPicker: (@MainActor () -> URL?)? = nil,
        trashHandler: @escaping DuplicateFileScannerEngine.TrashHandler = DuplicateFileScannerEngine.liveTrashHandler,
        onRemoveTrashedURLs: ((Set<URL>) -> Void)? = nil
    ) {
        self.controller = controller
        self.directoryPicker = directoryPicker
        self.trashHandler = trashHandler
        self.onRemoveTrashedURLs = onRemoveTrashedURLs
        _selectedDirectoryURL = State(initialValue: controller.initialDirectoryURL)
    }

    private var groups: [DuplicateGroup] {
        scanResult?.groups ?? []
    }

    private var selectedReclaimableBytes: Int64 {
        var total: Int64 = 0
        for group in groups {
            for entry in group.entries where selectedToTrash.contains(entry.url.standardizedFileURL) {
                total += entry.fileSize
            }
        }
        return total
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            AppDivider()
            controlsBar
            AppDivider()

            mainContentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleFolderDrop(providers: providers)
                    return true
                }

            if let errorMessage {
                AppInfoBanner(
                    style: .error,
                    message: errorMessage,
                    onDismiss: { self.errorMessage = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.sm)
            } else if let statusBanner {
                AppInfoBanner(
                    style: .success,
                    message: statusBanner,
                    onDismiss: { self.statusBanner = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.sm)
            }

            AppDivider()
            footerBar
        }
        .frame(minWidth: 660, idealWidth: 760, maxWidth: 800, minHeight: 440, idealHeight: 520, maxHeight: 560)
        .appWorkspaceSurface()
        .onChange(of: controller.initialDirectoryURL) { _, newURL in
            if let newURL {
                selectedDirectoryURL = newURL
            }
        }
        .onChange(of: keepPolicy) { _, newPolicy in
            selectedToTrash = DuplicateFileScannerEngine.selectDuplicatesToTrash(in: groups, policy: newPolicy)
        }
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
        }
        .onExitCommand {
            controller.dismiss()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duplicateFinder.sheet")
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Colors.accentTint)
                    .frame(width: 32, height: 32)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate File Finder")
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)

                Text("Find exact byte-identical files using SHA-256 and move duplicates safely to Trash")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button("Done") {
                controller.dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("duplicateFinder.doneButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Controls Bar

    private var controlsBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                chooseFolder()
            } label: {
                Label(
                    selectedDirectoryURL?.lastPathComponent ?? String(localized: "Choose Folder..."),
                    systemImage: "folder"
                )
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: 210, alignment: .leading)
            .help(selectedDirectoryURL?.path ?? String(localized: "Choose a folder to scan for duplicate files"))
            .accessibilityIdentifier("duplicateFinder.chooseFolderButton")

            Toggle("Subfolders", isOn: $includeSubdirectories)
                .toggleStyle(.checkbox)
                .font(AppTheme.Typography.caption)
                .disabled(isScanning)

            Spacer(minLength: AppTheme.Spacing.xs)

            Picker("Keep:", selection: $keepPolicy) {
                ForEach(DuplicateKeepPolicy.allCases) { policy in
                    Text(LocalizedStringKey(policy.rawValue)).tag(policy)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 210)
            .accessibilityIdentifier("duplicateFinder.policyPicker")

            Button {
                startScan()
            } label: {
                Label(
                    isScanning ? String(localized: "Scanning...") : String(localized: "Scan"),
                    systemImage: "magnifyingglass"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedDirectoryURL == nil || isScanning)
            .accessibilityIdentifier("duplicateFinder.scanButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentArea: some View {
        if isScanning {
            VStack(spacing: AppTheme.Spacing.md) {
                ProgressView()
                    .controlSize(.large)
                Text("Scanning files and computing SHA-256 hashes...")
                    .font(AppTheme.Typography.subheadline)
                    .foregroundStyle(.secondary)
                if let progress = scanProgress, progress.candidateFilesToHash > 0 {
                    Text(String(localized: "Hashed \(progress.hashedFiles) of \(progress.candidateFilesToHash) candidate files"))
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = scanResult {
            if result.groups.isEmpty {
                let scannedCount = result.scannedFileCount
                AppEmptyStateView(
                    icon: "checkmark.seal",
                    title: String(localized: "No Duplicate Files Found"),
                    subtitle: scannedCount == 1
                        ? String(localized: "Scanned 1 file in this folder. All files have unique contents.")
                        : String(localized: "Scanned \(scannedCount) files in this folder. All files have unique contents.")
                )
            } else {
                resultsList(result: result)
            }
        } else {
            AppEmptyStateView(
                icon: "folder.badge.questionmark",
                title: String(localized: "Select a Folder to Scan"),
                subtitle: String(localized: "Choose or drop a folder here to detect exact SHA-256 duplicate files."),
                isDropTargeted: isDropTargeted,
                primaryButtonTitle: selectedDirectoryURL == nil
                    ? String(localized: "Choose Folder...")
                    : String(localized: "Scan Selected Folder"),
                primaryButtonIcon: selectedDirectoryURL == nil ? "folder" : "magnifyingglass",
                onPrimaryAction: {
                    if selectedDirectoryURL == nil {
                        chooseFolder()
                    } else {
                        startScan()
                    }
                }
            )
        }
    }

    private func resultsList(result: DuplicateScanResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.md) {
                let groupCount = result.groups.count
                Text(
                    groupCount == 1
                        ? String(localized: "1 duplicate group")
                        : String(localized: "\(groupCount) duplicate groups")
                )
                .font(AppTheme.Typography.cardTitle)

                let totalReclaimable = ByteCountFormatter.string(fromByteCount: result.totalReclaimableBytes, countStyle: .file)
                AppStatusBadge(
                    text: String(localized: "Reclaimable: \(totalReclaimable)"),
                    tint: AppTheme.Colors.accent,
                    style: .capsule
                )

                Spacer()

                Text(
                    result.scannedFileCount == 1
                        ? String(localized: "1 file scanned")
                        : String(localized: "\(result.scannedFileCount) files scanned")
                )
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.sm)

            ScrollView {
                LazyVStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(result.groups) { group in
                        duplicateGroupCard(group)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.md)
            }
            .accessibilityIdentifier("duplicateFinder.groupsList")
        }
    }

    private func duplicateGroupCard(_ group: DuplicateGroup) -> some View {
        let sizeText = ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file)
        let reclaimText = ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file)
        let shortHash = String(group.sha256Hex.prefix(12))

        return AppCard(padding: AppTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    AppStatusBadge(
                        text: String(localized: "\(group.entries.count) copies"),
                        tint: AppTheme.Colors.warning,
                        style: .rounded
                    )
                    Text(sizeText)
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.secondary)
                    Text("SHA-256: \(shortHash)…")
                        .font(AppTheme.Typography.monoCaption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(String(localized: "Save \(reclaimText)"))
                        .font(AppTheme.Typography.caption.weight(.medium))
                        .foregroundStyle(AppTheme.Colors.success)
                }

                AppDivider()

                ForEach(group.entries) { entry in
                    duplicateEntryRow(entry, in: group)
                }
            }
        }
    }

    private func duplicateEntryRow(_ entry: DuplicateFileEntry, in group: DuplicateGroup) -> some View {
        let stdURL = entry.url.standardizedFileURL
        let isMarkedForTrash = selectedToTrash.contains(stdURL)
        let keptCount = group.entries.filter { !selectedToTrash.contains($0.url.standardizedFileURL) }.count
        let isLastKeptCopy = !isMarkedForTrash && keptCount <= 1

        return HStack(spacing: AppTheme.Spacing.sm) {
            Toggle(isOn: Binding(
                get: { isMarkedForTrash },
                set: { shouldTrash in
                    toggleSelection(for: entry, in: group, shouldTrash: shouldTrash)
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isLastKeptCopy)
            .help(isLastKeptCopy ? String(localized: "At least one copy must remain kept") : String(localized: "Select duplicate to move to Trash"))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.fileName)
                    .font(AppTheme.Typography.caption.weight(.medium))
                    .foregroundStyle(isMarkedForTrash ? .secondary : .primary)
                    .strikethrough(isMarkedForTrash)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: AppTheme.Spacing.xs)

            if !isMarkedForTrash {
                AppStatusBadge(text: String(localized: "Keep"), tint: AppTheme.Colors.success, style: .rounded)
            } else {
                AppStatusBadge(text: String(localized: "Trash"), tint: AppTheme.Colors.error, style: .rounded)
            }

            Text(entry.modificationDate, style: .date)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            let selectedCount = selectedToTrash.count
            let formattedSelected = ByteCountFormatter.string(fromByteCount: selectedReclaimableBytes, countStyle: .file)
            Text(
                selectedCount == 0
                    ? String(localized: "No duplicates selected")
                    : (selectedCount == 1
                        ? String(localized: "1 duplicate selected (\(formattedSelected))")
                        : String(localized: "\(selectedCount) duplicates selected (\(formattedSelected))"))
            )
            .font(AppTheme.Typography.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer()

            Button {
                trashSelectedDuplicates()
            } label: {
                Label("Move Duplicates to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.Colors.error)
            .controlSize(.regular)
            .disabled(selectedToTrash.isEmpty || isScanning)
            .accessibilityIdentifier("duplicateFinder.trashButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Actions

    private func chooseFolder() {
        if let directoryPicker {
            if let picked = directoryPicker() {
                selectedDirectoryURL = picked
                errorMessage = nil
                statusBanner = nil
            }
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Select Folder")
        if let current = selectedDirectoryURL {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            selectedDirectoryURL = url
            errorMessage = nil
            statusBanner = nil
        }
    }

    private func startScan() {
        guard let directory = selectedDirectoryURL else { return }
        scanTask?.cancel()
        errorMessage = nil
        statusBanner = nil
        isScanning = true
        scanProgress = nil
        let options = DuplicateScanOptions(includeSubdirectories: includeSubdirectories)
        let currentPolicy = keepPolicy

        scanTask = Task {
            do {
                let result = try await DuplicateFileScannerEngine.scan(
                    directoryURL: directory,
                    options: options
                ) { progress in
                    Task { @MainActor in
                        scanProgress = progress
                    }
                }
                guard !Task.isCancelled else { return }
                scanResult = result
                selectedToTrash = DuplicateFileScannerEngine.selectDuplicatesToTrash(
                    in: result.groups,
                    policy: currentPolicy
                )
                isScanning = false
            } catch is CancellationError {
                isScanning = false
            } catch {
                errorMessage = error.localizedDescription
                isScanning = false
            }
        }
    }

    private func toggleSelection(for entry: DuplicateFileEntry, in group: DuplicateGroup, shouldTrash: Bool) {
        let stdURL = entry.url.standardizedFileURL
        if shouldTrash {
            let remainingKept = group.entries.filter {
                $0.url.standardizedFileURL != stdURL && !selectedToTrash.contains($0.url.standardizedFileURL)
            }
            guard !remainingKept.isEmpty else {
                errorMessage = DuplicateScannerError.cannotTrashAllCopiesInGroup(group.sha256Hex).localizedDescription
                return
            }
            selectedToTrash.insert(stdURL)
        } else {
            selectedToTrash.remove(stdURL)
        }
    }

    private func trashSelectedDuplicates() {
        guard let result = scanResult else { return }
        errorMessage = nil
        statusBanner = nil

        do {
            let trashResult = try DuplicateFileScannerEngine.trashDuplicates(
                in: result.groups,
                selectedURLs: selectedToTrash,
                trashHandler: trashHandler
            )

            let trashedSet = Set(trashResult.trashedURLs.map(\.standardizedFileURL))
            selectedToTrash.subtract(trashedSet)

            let updatedGroups: [DuplicateGroup] = result.groups.compactMap { group in
                let remaining = group.entries.filter { !trashedSet.contains($0.url.standardizedFileURL) }
                guard remaining.count >= 2 else { return nil }
                return DuplicateGroup(fileSize: group.fileSize, sha256Hex: group.sha256Hex, entries: remaining)
            }

            scanResult = DuplicateScanResult(
                rootDirectory: result.rootDirectory,
                scannedFileCount: max(0, result.scannedFileCount - trashedSet.count),
                hashedFileCount: result.hashedFileCount,
                groups: updatedGroups
            )

            if !trashedSet.isEmpty {
                if let onRemoveTrashedURLs {
                    onRemoveTrashedURLs(trashedSet)
                } else {
                    AppState.shared?.removeFiles(matchingURLs: trashedSet, recordUndo: false)
                }
            }

            if !trashResult.failures.isEmpty {
                errorMessage = trashResult.failures.map { "\($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
            }

            let trashedCount = trashResult.trashedURLs.count
            if trashedCount > 0 {
                let formatted = ByteCountFormatter.string(fromByteCount: trashResult.reclaimedBytes, countStyle: .file)
                statusBanner = trashedCount == 1
                    ? String(localized: "Moved 1 duplicate file to Trash (\(formatted) reclaimed).")
                    : String(localized: "Moved \(trashedCount) duplicate files to Trash (\(formatted) reclaimed).")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFolderDrop(providers: [NSItemProvider]) {
        Task {
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    var targetURL: URL?
                    if let url = item as? URL {
                        targetURL = url
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        targetURL = url
                    }
                    if let url = targetURL {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            await MainActor.run {
                                selectedDirectoryURL = url
                                errorMessage = nil
                                statusBanner = nil
                            }
                            return
                        }
                    }
                }
            }
        }
    }
}
