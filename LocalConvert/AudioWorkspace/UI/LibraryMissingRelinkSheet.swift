import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryMissingRelinkSheet: View {
    @ObservedObject var store: AudioLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var missingRecords: [AudioLibraryRecord] = []
    @State private var scannedCandidates: [RelinkCandidate] = []
    @State private var outcomeByAssetID: [UUID: RelinkOutcome] = [:]
    @State private var isScanningFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("Missing Audio Files")
                        .font(AppTheme.Typography.pageTitle)
                }
                Spacer()
                Button {
                    Task {
                        _ = await store.reconcileMissingFiles()
                        reloadMissingList()
                    }
                } label: {
                    Label("Re-check Bookmarks", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("audioworkspace.relink.recheck")

                Button {
                    chooseFolderAndScanCandidates()
                } label: {
                    Label(isScanningFolder ? "Scanning..." : "Scan Folder...", systemImage: "folder.badge.magnifyingglass")
                }
                .disabled(missingRecords.isEmpty || isScanningFolder)
                .accessibilityIdentifier("audioworkspace.relink.scan_folder")
            }

            Text("Missing tracks remain non-destructive: source files on disk are never altered during bookmark or SHA-256 verification.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)

            if missingRecords.isEmpty {
                AppEmptyStateView(
                    icon: "checkmark.seal.fill",
                    title: "All Indexed Files Available",
                    subtitle: "No missing audio files remain in the library."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(missingRecords, id: \.asset.id) { record in
                        missingRow(record)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            if !scannedCandidates.isEmpty {
                Divider()
                Text("Detected Folder Matches (\(scannedCandidates.count))")
                    .font(AppTheme.Typography.cardTitle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(scannedCandidates) { cand in
                            candidateRow(cand)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("audioworkspace.relink.done")
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 620, height: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("audioworkspace.relink.sheet")
        .onAppear {
            reloadMissingList()
        }
        .onChange(of: store.displayedRecords) { _, _ in
            reloadMissingList()
        }
    }

    private func missingRow(_ record: AudioLibraryRecord) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Colors.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(record.metadata.title ?? record.asset.displayFilename)
                        .font(AppTheme.Typography.cardTitle)
                        .lineLimit(1)
                    if let outcome = outcomeByAssetID[record.asset.id] {
                        Label(outcome.confidence.displayLabel, systemImage: outcome.confidence.systemImage)
                            .font(AppTheme.Typography.badge)
                            .foregroundStyle(AppTheme.Colors.success)
                    }
                }
                Text(record.asset.canonicalPath)
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Locate...") {
                chooseReplacementFile(for: record)
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Locate file for \(record.asset.displayFilename)")
            .accessibilityIdentifier("audioworkspace.relink.locate")

            Button("Remove from Library", role: .destructive) {
                Task {
                    await store.removeAssetFromLibrary(id: record.asset.id)
                    reloadMissingList()
                }
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .help("Remove from Library index only (does not delete any files on disk)")
            .accessibilityIdentifier("audioworkspace.relink.remove")
        }
        .padding(.vertical, 2)
    }

    private func candidateRow(_ cand: RelinkCandidate) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Label(cand.confidence.displayLabel, systemImage: cand.confidence.systemImage)
                .font(AppTheme.Typography.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(cand.confidence == .exactContentHash ? AppTheme.Colors.success : AppTheme.Colors.info)

            Text(cand.url.path)
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Apply Relink") {
                Task {
                    if let outcome = await store.relinkMissingAsset(assetID: cand.assetID, to: cand.url) {
                        outcomeByAssetID[cand.assetID] = outcome
                        scannedCandidates.removeAll { $0.assetID == cand.assetID }
                        reloadMissingList()
                    }
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("audioworkspace.relink.apply_candidate")
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, 4)
        .background(AppTheme.Colors.subtleSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
    }

    private func reloadMissingList() {
        Task { @MainActor in
            let filter = try? AudioCollectionFilter(missingOnly: true)
            let items = filter.flatMap { _ in store.displayedRecords.filter { $0.asset.status == .missing } } ?? []
            if !items.isEmpty {
                missingRecords = items
            } else if let allMissing = try? await store.database.fetchAssets(matching: AudioCollectionFilter(missingOnly: true)) {
                missingRecords = allMissing
            } else {
                missingRecords = []
            }
        }
    }

    private func chooseReplacementFile(for record: AudioLibraryRecord) {
        let panel = NSOpenPanel()
        panel.title = "Locate Missing Audio File: \(record.asset.displayFilename)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                if let outcome = await store.relinkMissingAsset(assetID: record.asset.id, to: url) {
                    outcomeByAssetID[record.asset.id] = outcome
                    reloadMissingList()
                }
            }
        }
    }

    private func chooseFolderAndScanCandidates() {
        let env = ProcessInfo.processInfo.environment
        if env["LOCALCONVERT_UITEST"] == "1",
           let overridePath = env["LOCALCONVERT_UITEST_AUDIO_RELINK_FOLDER"],
           !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath, isDirectory: true)
            isScanningFolder = true
            Task {
                scannedCandidates = await store.scanFolderForMissingRelinks(folderURL: url)
                isScanningFolder = false
            }
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Scan Folder for Relink Candidates"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            isScanningFolder = true
            Task {
                scannedCandidates = await store.scanFolderForMissingRelinks(folderURL: url)
                isScanningFolder = false
            }
        }
    }
}
