import SwiftUI
import AppKit

// MARK: - Batch Renamer Sheet Controller

@MainActor
final class BatchRenamerSheetController: ObservableObject {
    static let shared = BatchRenamerSheetController()

    @Published var isPresented: Bool = false

    init(isPresented: Bool = false) {
        self.isPresented = isPresented
    }

    func open() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }
}

// MARK: - Batch Renamer Sheet View

struct BatchRenamerSheetView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: BatchRenamerSheetController

    @State private var rules: BatchRenameRules = .default
    @State private var previewReferenceDate: Date = Date()
    @State private var lastUndoJournal: BatchRenameUndoJournal? = nil
    @State private var statusBanner: String? = nil
    @State private var errorMessage: String? = nil

    init(controller: BatchRenamerSheetController = .shared) {
        self.controller = controller
    }

    private var previewPlan: BatchRenamePreviewPlan {
        BatchFileRenamerEngine.preview(
            urls: appState.droppedFiles.map(\.url),
            rules: rules,
            referenceDate: previewReferenceDate
        )
    }

    var body: some View {
        let plan = previewPlan
        VStack(spacing: 0) {
            headerBar
            AppDivider()

            if appState.droppedFiles.isEmpty {
                AppEmptyStateView(
                    icon: "character.cursor.ibeam",
                    title: String(localized: "No Files in Queue"),
                    subtitle: String(localized: "Add files to the conversion queue to preview and apply batch filename rules.")
                )
            } else {
                HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                    rulesColumn
                        .frame(width: 268)

                    previewColumn(plan: plan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(AppTheme.Spacing.lg)
            }

            if let errorMessage {
                AppInfoBanner(
                    style: .error,
                    message: errorMessage,
                    onDismiss: { self.errorMessage = nil }
                )
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.sm)
            } else if plan.hasConflicts {
                let count = plan.conflictCount
                AppInfoBanner(
                    style: .warning,
                    message: count == 1
                        ? String(localized: "1 filename conflict detected. Resolve conflicts before applying.")
                        : String(localized: "\(count) filename conflicts detected. Resolve conflicts before applying.")
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
            footerBar(plan: plan)
        }
        .frame(minWidth: 660, idealWidth: 760, maxWidth: 800, minHeight: 440, idealHeight: 520, maxHeight: 560)
        .appWorkspaceSurface()
        .onExitCommand {
            controller.dismiss()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("batchRenamer.sheet")
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Colors.accentTint)
                    .frame(width: 32, height: 32)
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Batch Rename Files")
                    .font(AppTheme.Typography.sectionTitle)
                    .lineLimit(1)

                Text(
                    appState.droppedFiles.count == 1
                        ? String(localized: "1 file in queue")
                        : String(localized: "\(appState.droppedFiles.count) files in queue")
                )
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button("Reset Rules") {
                rules = .default
                previewReferenceDate = Date()
                errorMessage = nil
                statusBanner = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(rules == .default)
            .accessibilityIdentifier("batchRenamer.resetButton")

            Button("Done") {
                controller.dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("batchRenamer.doneButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Rules Column

    private var rulesColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                AppCard(title: String(localized: "Find & Replace"), icon: "magnifyingglass", padding: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        TextField("Find text", text: $rules.findText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)

                        TextField("Replace with", text: $rules.replaceText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)

                        Toggle("Case sensitive", isOn: $rules.isCaseSensitive)
                            .font(AppTheme.Typography.caption)
                            .toggleStyle(.checkbox)
                    }
                }

                AppCard(title: String(localized: "Prefix & Suffix"), icon: "text.insert", padding: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        TextField("Prefix", text: $rules.prefix)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)

                        TextField("Suffix", text: $rules.suffix)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }
                }

                AppCard(title: String(localized: "Numbering & Date"), icon: "number", padding: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Toggle("Add sequential numbering", isOn: $rules.includeNumbering)
                            .font(AppTheme.Typography.caption)
                            .toggleStyle(.checkbox)

                        if rules.includeNumbering {
                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text("Start:")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                TextField("", value: $rules.startIndex, format: .number, prompt: Text(verbatim: "1"))
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .frame(width: 52)
                                Spacer(minLength: 4)
                                Stepper("Digits: \(rules.paddingDigits)", value: $rules.paddingDigits, in: 1...6)
                                    .font(AppTheme.Typography.caption)
                            }

                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text("Separator:")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                TextField("", text: $rules.numberingSeparator, prompt: Text(verbatim: "_"))
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .frame(width: 52)
                            }
                        }

                        AppDivider()
                            .padding(.vertical, 2)

                        Picker("Date Stamp:", selection: $rules.dateSource) {
                            ForEach(BatchRenameDateSource.allCases) { source in
                                Text(LocalizedStringKey(source.rawValue)).tag(source)
                            }
                        }
                        .controlSize(.small)

                        if rules.dateSource != .none {
                            Picker("Placement:", selection: $rules.datePlacement) {
                                ForEach(BatchRenameDatePlacement.allCases) { placement in
                                    Text(LocalizedStringKey(placement.rawValue)).tag(placement)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)

                            HStack(spacing: AppTheme.Spacing.xs) {
                                Text("Format:")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                TextField("", text: $rules.dateFormat, prompt: Text(verbatim: "yyyy-MM-dd"))
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                AppCard(title: String(localized: "Case & Extension"), icon: "textformat", padding: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Picker("Case:", selection: $rules.caseTransform) {
                            ForEach(BatchRenameCaseTransform.allCases) { transform in
                                Text(LocalizedStringKey(transform.rawValue)).tag(transform)
                            }
                        }
                        .controlSize(.small)

                        Toggle("Preserve file extension", isOn: $rules.preserveExtension)
                            .font(AppTheme.Typography.caption)
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .padding(.trailing, 2)
        }
    }

    // MARK: - Live Preview Column

    private func previewColumn(plan: BatchRenamePreviewPlan) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Before")
                    .font(AppTheme.Typography.badge)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text("After")
                    .font(AppTheme.Typography.badge)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Status")
                    .font(AppTheme.Typography.badge)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs + 2)
            .background(AppTheme.Colors.subtleSurface)

            AppDivider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plan.rows) { row in
                        previewRowView(row)
                        AppDivider()
                    }
                }
            }
            .background(AppTheme.Colors.cardBackground)
            .accessibilityIdentifier("batchRenamer.previewList")
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    private func previewRowView(_ row: BatchRenamePreviewRow) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(row.beforeName)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.beforeName)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(row.afterName.isEmpty ? "—" : row.afterName)
                .font(AppTheme.Typography.caption.weight(row.status == .ready ? .medium : .regular))
                .foregroundStyle(afterColor(for: row.status))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.afterName)

            statusBadge(for: row.status)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs + 2)
    }

    private func afterColor(for status: BatchRenameRowStatus) -> Color {
        switch status {
        case .ready:
            return AppTheme.Colors.accent
        case .unchanged:
            return .secondary
        case .conflict:
            return AppTheme.Colors.error
        }
    }

    @ViewBuilder
    private func statusBadge(for status: BatchRenameRowStatus) -> some View {
        switch status {
        case .ready:
            AppStatusBadge(text: String(localized: "Ready"), tint: AppTheme.Colors.success, style: .rounded)
        case .unchanged:
            AppStatusBadge(text: String(localized: "Same"), tint: .secondary, style: .rounded)
        case .conflict(let reason):
            AppStatusBadge(text: String(localized: "Conflict"), tint: AppTheme.Colors.error, style: .rounded)
                .help(reason.localizedDescription)
        }
    }

    // MARK: - Footer

    private func footerBar(plan: BatchRenamePreviewPlan) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            let readyCount = plan.readyCount
            Text(
                readyCount == 1
                    ? String(localized: "1 file will be renamed")
                    : String(localized: "\(readyCount) files will be renamed")
            )
            .font(AppTheme.Typography.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: AppTheme.Spacing.sm)

            if lastUndoJournal != nil {
                Button {
                    undoLastRename()
                } label: {
                    Label("Undo Last Rename", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(appState.isConverting)
                .accessibilityIdentifier("batchRenamer.undoButton")
            }

            Button {
                applyRenames(plan: plan)
            } label: {
                Label("Apply Rename", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!plan.hasChanges || plan.hasConflicts || appState.isConverting)
            .accessibilityIdentifier("batchRenamer.applyButton")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Actions

    private func applyRenames(plan: BatchRenamePreviewPlan) {
        errorMessage = nil
        statusBanner = nil
        do {
            let journal = try BatchFileRenamerEngine.apply(plan: plan)
            let moves = journal.appliedMoves.map { (from: $0.from, to: $0.to) }
            appState.applyRenamedURLs(moves)
            lastUndoJournal = journal
            let count = moves.count
            statusBanner = count == 1
                ? String(localized: "Renamed 1 file.")
                : String(localized: "Renamed \(count) files.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func undoLastRename() {
        guard let journal = lastUndoJournal else { return }
        errorMessage = nil
        statusBanner = nil
        do {
            let reverted = try journal.undo()
            let moves = reverted.map { (from: $0.from, to: $0.to) }
            appState.applyRenamedURLs(moves)
            lastUndoJournal = nil
            let count = moves.count
            statusBanner = count == 1
                ? String(localized: "Reverted 1 file rename.")
                : String(localized: "Reverted \(count) file renames.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
