import SwiftUI

// MARK: - Editing History View

/// Unified Editing History timeline UI strictly separate from conversion History (`HistoryView` / `HistoryManager`).
/// Surfaces active undo/redo chains, current state marker, branch warnings, irreversibility & persistence scopes,
/// archived branches, and pre-validated Jump-to-State actions.
struct EditingHistoryView: View {
    enum ScopeMode: String, CaseIterable, Identifiable {
        case activeContext = "Active Context"
        case allContexts = "All Contexts"

        var id: String { rawValue }
    }

    @ObservedObject var coordinator: UndoRedoCoordinator
    @AppStorage("settings.recoveryArtifactStorageLimitMB", store: AppStoragePaths.userDefaults)
    private var recoveryArtifactStorageLimitMBRaw: Int = EditingHistoryLimitDefaults.defaultRecoveryStorageLimitMB

    @State private var scopeMode: ScopeMode = .activeContext
    @State private var selectedFilterContext: OperationContext? = nil
    @State private var isArchivedExpanded: Bool = false
    @State private var recoveryUsageBytes: Int64 = 0

    init(coordinator: UndoRedoCoordinator = .shared) {
        self.coordinator = coordinator
    }

    private var displayedContext: OperationContext? {
        selectedFilterContext ?? coordinator.activeContext
    }

    private var activeUndoEntriesDescending: [UndoHistoryEntry] {
        guard let ctx = displayedContext else { return [] }
        return Array(coordinator.undoEntries(for: ctx).reversed())
    }

    private var activeRedoEntriesDescending: [UndoHistoryEntry] {
        guard let ctx = displayedContext else { return [] }
        // Redo entries ordered furthest-undone at top -> next-to-redo right above Current State marker
        return Array(coordinator.redoEntries(for: ctx).reversed())
    }

    private var archivedEntriesForCurrentScope: [UndoHistoryEntry] {
        switch scopeMode {
        case .activeContext:
            guard let ctx = displayedContext else { return [] }
            return Array(coordinator.archivedTimeline(for: ctx).reversed())
        case .allContexts:
            let contexts = selectedFilterContext.map { [$0] } ?? coordinator.allKnownContexts()
            return contexts
                .flatMap { coordinator.archivedTimeline(for: $0) }
                .sorted { ($0.archivedAt ?? $0.timestamp) > ($1.archivedAt ?? $1.timestamp) }
        }
    }

    private var allContextsActiveEntriesDescending: [UndoHistoryEntry] {
        let contexts = selectedFilterContext.map { [$0] } ?? coordinator.allKnownContexts()
        return contexts
            .flatMap { coordinator.activeTimeline(for: $0) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var activeRedoWarningCount: Int {
        switch scopeMode {
        case .activeContext:
            guard let ctx = displayedContext else { return 0 }
            return coordinator.redoCount(in: ctx)
        case .allContexts:
            if let filter = selectedFilterContext {
                return coordinator.redoCount(in: filter)
            }
            return coordinator.totalRedoCountAllContexts()
        }
    }

    private var currentCanUndo: Bool {
        if scopeMode == .activeContext, let ctx = displayedContext {
            return coordinator.canUndo(in: ctx)
        }
        return coordinator.canUndo
    }

    private var currentCanRedo: Bool {
        if scopeMode == .activeContext, let ctx = displayedContext {
            return coordinator.canRedo(in: ctx)
        }
        return coordinator.canRedo
    }

    private var currentUndoButtonTitle: String {
        if scopeMode == .activeContext, let ctx = displayedContext, let title = coordinator.undoTitle(in: ctx) {
            return "Undo \(title)"
        }
        return coordinator.undoMenuLabel
    }

    private var currentRedoButtonTitle: String {
        if scopeMode == .activeContext, let ctx = displayedContext, let title = coordinator.redoTitle(in: ctx) {
            return "Redo \(title)"
        }
        return coordinator.redoMenuLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            AppDivider()
            controlsBar
            AppDivider()
            bannersSection
            timelineContent
        }
        .background(AppTheme.Colors.workspaceBackground)
        .task {
            coordinator.validateStaleness()
            recoveryUsageBytes = await coordinator.currentRecoveryUsageBytes()
        }
        .onChange(of: coordinator.timelineRevision) {
            Task {
                recoveryUsageBytes = await coordinator.currentRecoveryUsageBytes()
            }
        }
    }

    // MARK: - Header & Controls

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            AppToolboxHeader(
                title: "Editing History",
                subtitle: "Reversible Undo/Redo editing operations stored separately from Conversion History.",
                metadataText: storageSummaryText
            ) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Button("Prune Unpinned") {
                        Task {
                            await coordinator.pruneUnusedRecoveryArtifacts()
                            recoveryUsageBytes = await coordinator.currentRecoveryUsageBytes()
                            AccessibilityAnnouncer.announce("Pruned unused recovery artifacts.", priority: .low)
                        }
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Prune unused recovery artifacts")
                    .accessibilityHint("Removes orphaned or archived recovery files while keeping active undo and redo entries safe")

                    if !allTimelineIsEmpty {
                        Button("Clear") {
                            Task {
                                let target: OperationContext? = (scopeMode == .activeContext) ? displayedContext : selectedFilterContext
                                await coordinator.clearHistory(for: target, includeArchived: true)
                                recoveryUsageBytes = await coordinator.currentRecoveryUsageBytes()
                                AccessibilityAnnouncer.announce("Cleared editing history.", priority: .medium)
                            }
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Clear editing history")
                        .accessibilityHint("Clears active and archived entries in the displayed editing history scope")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editingHistory.surfaceDescription")
        .background(AppTheme.Colors.subtleSurface)
    }

    private var storageSummaryText: String {
        let used = ByteCountFormatter.string(fromByteCount: recoveryUsageBytes, countStyle: .file)
        let limitMB = EditingHistoryLimitDefaults.clampedStorageLimitMB(recoveryArtifactStorageLimitMBRaw)
        let limitBytes = Int64(limitMB) * 1_024 * 1_024
        let limit = ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .file)
        return "\(used) / \(limit)"
    }

    private var allTimelineIsEmpty: Bool {
        activeUndoEntriesDescending.isEmpty
            && activeRedoEntriesDescending.isEmpty
            && allContextsActiveEntriesDescending.isEmpty
            && archivedEntriesForCurrentScope.isEmpty
    }

    private var controlsBar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Picker("History Scope", selection: $scopeMode) {
                    ForEach(ScopeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minWidth: 180, maxWidth: 240)
                .accessibilityLabel("Editing history scope")
                .accessibilityHint("Switch between the active editing context and all contexts")

                if !coordinator.allKnownContexts().isEmpty {
                    Picker("Context Filter", selection: $selectedFilterContext) {
                        Text(scopeMode == .activeContext ? "Focused (\(coordinator.activeContext?.displayName ?? "None"))" : "All Modules")
                            .tag(Optional<OperationContext>.none)
                        ForEach(coordinator.allKnownContexts()) { ctx in
                            Label(ctx.displayName, systemImage: ctx.iconName)
                                .tag(Optional(ctx))
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 140, maxWidth: 210)
                    .accessibilityLabel("Filter by editing module")
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    performUndoAction()
                } label: {
                    Label(currentUndoButtonTitle, systemImage: "arrow.uturn.backward")
                        .lineLimit(1)
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!currentCanUndo || coordinator.isExecutingUndoRedo)
                .accessibilityLabel(currentUndoButtonTitle)
                .accessibilityHint("Reverses the most recent reversible edit")

                Button {
                    performRedoAction()
                } label: {
                    Label(currentRedoButtonTitle, systemImage: "arrow.uturn.forward")
                        .lineLimit(1)
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!currentCanRedo || coordinator.isExecutingUndoRedo)
                .accessibilityLabel(currentRedoButtonTitle)
                .accessibilityHint("Reapplies the most recently undone edit")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    @ViewBuilder
    private var bannersSection: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            if let error = coordinator.lastError {
                AppInfoBanner(
                    style: .error,
                    message: error.localizedDescription,
                    onDismiss: {
                        coordinator.lastError = nil
                    }
                )
            }

            if activeRedoWarningCount > 0 {
                AppInfoBanner(
                    style: .warning,
                    message: "\(activeRedoWarningCount) undone operation\(activeRedoWarningCount == 1 ? "" : "s") will move to Archived Branch if you perform a new edit."
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.top, (coordinator.lastError != nil || activeRedoWarningCount > 0) ? AppTheme.Spacing.sm : 0)
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineContent: some View {
        if scopeMode == .activeContext {
            activeContextTimeline
        } else {
            allContextsTimeline
        }
    }

    @ViewBuilder
    private var activeContextTimeline: some View {
        let context = displayedContext
        let redoList = activeRedoEntriesDescending
        let undoList = activeUndoEntriesDescending
        let archivedList = archivedEntriesForCurrentScope

        if context == nil && archivedList.isEmpty {
            AppEmptyStateView(
                icon: "gearshape",
                title: "No Active Editing Stack",
                subtitle: "Application Settings preferences are not modified by global Undo/Redo. Switch to an editor or toolbox, or choose All Contexts."
            )
        } else if redoList.isEmpty && undoList.isEmpty && archivedList.isEmpty {
            AppEmptyStateView(
                icon: "clock.arrow.2.circlepath",
                title: "No Editing Operations Yet",
                subtitle: "Edits made in \(context?.displayName ?? "this module") will appear here with undo, redo, and jump-to-state support."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    if !redoList.isEmpty {
                        sectionLabel("Undone (Redoable)", systemImage: "arrow.uturn.forward.circle")
                        ForEach(redoList) { entry in
                            historyRow(entry: entry, isCurrentHead: false, showJumpButton: true)
                        }
                    }

                    currentStateMarker

                    if !undoList.isEmpty {
                        sectionLabel("Completed (Undoable)", systemImage: "checkmark.circle")
                        let topID = undoList.first?.id
                        ForEach(undoList) { entry in
                            historyRow(entry: entry, isCurrentHead: entry.id == topID, showJumpButton: entry.id != topID)
                        }

                        if let ctx = context {
                            initialStateRow(for: ctx)
                        }
                    }

                    if !archivedList.isEmpty {
                        archivedBranchDisclosure(entries: archivedList)
                    }
                }
                .padding(AppTheme.Spacing.xl)
            }
        }
    }

    @ViewBuilder
    private var allContextsTimeline: some View {
        let activeEntries = allContextsActiveEntriesDescending
        let archivedList = archivedEntriesForCurrentScope

        if activeEntries.isEmpty && archivedList.isEmpty {
            AppEmptyStateView(
                icon: "clock.arrow.2.circlepath",
                title: "No Editing History Recorded",
                subtitle: "Operations across Audio Editor, Convert, Image Toolbox, PDF Toolbox, Metadata, Presets, and File Operations will appear here."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    if !activeEntries.isEmpty {
                        sectionLabel("Active Timeline Across Modules", systemImage: "clock")
                        ForEach(activeEntries) { entry in
                            let isCurrentHead = (coordinator.currentAppliedEntryID(for: entry.context) == entry.id)
                            historyRow(entry: entry, isCurrentHead: isCurrentHead, showJumpButton: !isCurrentHead)
                        }
                    }

                    if !archivedList.isEmpty {
                        archivedBranchDisclosure(entries: archivedList)
                    }
                }
                .padding(AppTheme.Spacing.xl)
            }
        }
    }

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: systemImage)
                .font(AppTheme.Typography.badge)
                .foregroundStyle(.secondary)
            Text(title)
                .font(AppTheme.Typography.sidebarHeader)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .padding(.top, AppTheme.Spacing.xs)
    }

    private var currentStateMarker: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Rectangle()
                .fill(AppTheme.Colors.accent.opacity(0.65))
                .frame(height: 1.5)

            AppHeaderPill(
                text: "Current State",
                systemImage: "arrowtriangle.right.fill",
                tint: AppTheme.Colors.accent
            )

            Rectangle()
                .fill(AppTheme.Colors.accent.opacity(0.65))
                .frame(height: 1.5)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current editing state marker")
    }

    private func initialStateRow(for context: OperationContext) -> some View {
        let validation = coordinator.validateJump(to: nil, in: context)
        let helpText: String = {
            if case .blocked(let blocker, let reason) = validation.direction {
                return "Cannot jump past '\(blocker.title)': \(reason)"
            }
            return "Undo all edits in \(context.displayName) back to initial state"
        }()

        return HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "arrow.counterclockwise.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Initial State (Before Edits)")
                    .font(AppTheme.Typography.cardTitle)
                Text("Baseline state before recorded operations in \(context.displayName)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Jump Here") {
                Task {
                    await coordinator.jumpTo(entryID: nil, in: context)
                    AccessibilityAnnouncer.announce("Jumped to initial state in \(context.displayName).", priority: .medium)
                }
            }
            .controlSize(.small)
            .disabled(!validation.isSafe || coordinator.isExecutingUndoRedo)
            .help(helpText)
            .accessibilityLabel("Jump to initial state")
            .accessibilityHint(helpText)
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    private func archivedBranchDisclosure(entries: [UndoHistoryEntry]) -> some View {
        AppCard(padding: AppTheme.Spacing.md) {
            DisclosureGroup(isExpanded: $isArchivedExpanded) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Branched off, evicted, or irreversible records — preserved for inspection only and not auto-replayed.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, AppTheme.Spacing.xs)

                    ForEach(entries) { entry in
                        historyRow(entry: entry, isCurrentHead: false, showJumpButton: false)
                    }
                }
                .padding(.top, AppTheme.Spacing.xs)
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                    Text("Archived Branch History (\(entries.count))")
                        .font(AppTheme.Typography.cardTitle)
                    Spacer()
                    AppStatusBadge(text: "Read-Only", tint: .secondary, style: .rounded)
                }
            }
            .accessibilityLabel("Archived branch history, \(entries.count) items")
            .accessibilityHint("Expands or collapses archived operations that are no longer on the active undo or redo chain")
        }
        .padding(.top, AppTheme.Spacing.sm)
    }

    @ViewBuilder
    private func historyRow(
        entry: UndoHistoryEntry,
        isCurrentHead: Bool,
        showJumpButton: Bool
    ) -> some View {
        let isUndone = entry.state == .undone
        let isArchived = entry.state == .archived || entry.state == .stale
        let jumpValidation: JumpValidationResult? = showJumpButton ? coordinator.validateJump(to: entry.id, in: entry.context) : nil

        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                rowLeadingIcon(entry: entry, isCurrentHead: isCurrentHead)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(entry.title)
                            .font(AppTheme.Typography.cardTitle)
                            .foregroundStyle(isArchived ? .secondary : .primary)

                        if isCurrentHead {
                            AppStatusBadge(text: "Active", tint: AppTheme.Colors.accent)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            AppStatusBadge(text: entry.context.displayName, tint: AppTheme.Colors.accent, style: .rounded)
                            AppStatusBadge(text: entry.operationType.rawValue, tint: .secondary, style: .rounded)

                            if isUndone {
                                AppStatusBadge(text: "Undone · Branchable", tint: AppTheme.Colors.warning)
                                    .help("Undone — will be archived if a new edit branches from here.")
                            } else if entry.state == .stale {
                                AppStatusBadge(text: "Stale", tint: AppTheme.Colors.error)
                            } else if !entry.isReversible {
                                AppStatusBadge(text: "Irreversible", tint: AppTheme.Colors.error)
                            } else if entry.state == .archived {
                                AppStatusBadge(text: "Archived", tint: .secondary)
                            }

                            AppStatusBadge(
                                text: entry.survivesRestart ? "Persistent" : "Session-Only",
                                tint: entry.survivesRestart ? AppTheme.Colors.info : .secondary,
                                style: .rounded
                            )
                        }
                    }

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Label(entry.affectedSummary, systemImage: "doc")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("•")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(.tertiary)

                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(AppTheme.Typography.monoCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    if let reason = entry.irreversibilityReason ?? entry.archiveReason?.rawValue,
                       !entry.isReversible || isArchived {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(entry.isReversible ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppTheme.Colors.error))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                if showJumpButton, let jumpValidation {
                    let isAlreadyTarget: Bool = {
                        if case .alreadyAtTarget = jumpValidation.direction { return true }
                        return false
                    }()
                    let disabled = !jumpValidation.isSafe || isAlreadyTarget || coordinator.isExecutingUndoRedo
                    let helpMessage: String = {
                        if case .blocked(let blocker, let reason) = jumpValidation.direction {
                            return "Cannot jump past '\(blocker.title)': \(reason)"
                        }
                        return isUndone ? "Redo up to '\(entry.title)'" : "Undo back to '\(entry.title)'"
                    }()

                    Button("Jump Here") {
                        Task {
                            await coordinator.jumpTo(entryID: entry.id, in: entry.context)
                            AccessibilityAnnouncer.announce("Jumped to \(entry.title).", priority: .medium)
                        }
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(disabled)
                    .help(helpMessage)
                    .accessibilityLabel("Jump to \(entry.title)")
                    .accessibilityHint(helpMessage)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(isArchived ? AppTheme.Colors.elevatedSurface : AppTheme.Colors.cardBackground)
        .opacity(isUndone ? 0.72 : (isArchived ? 0.82 : 1.0))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay {
            if isUndone {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(
                        AppTheme.Colors.warning.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            } else {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(
                        isCurrentHead ? AppTheme.Colors.accent.opacity(0.55) : AppTheme.Colors.cardBorder,
                        lineWidth: isCurrentHead ? 1.5 : 1
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(entry: entry, isCurrentHead: isCurrentHead))
    }

    @ViewBuilder
    private func rowLeadingIcon(entry: UndoHistoryEntry, isCurrentHead: Bool) -> some View {
        if !entry.isReversible || entry.state == .stale {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(AppTheme.Colors.error)
                .font(.subheadline)
        } else if entry.state == .undone {
            Image(systemName: "arrow.uturn.forward.circle")
                .foregroundStyle(AppTheme.Colors.warning)
                .font(.subheadline)
        } else if entry.state == .archived {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        } else {
            Image(systemName: isCurrentHead ? "checkmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(isCurrentHead ? AppTheme.Colors.accent : AppTheme.Colors.success)
                .font(.subheadline)
        }
    }

    private func rowAccessibilityLabel(entry: UndoHistoryEntry, isCurrentHead: Bool) -> String {
        let stateLabel: String = {
            if isCurrentHead { return "Current active state" }
            switch entry.state {
            case .applied: return "Completed"
            case .undone: return "Undone"
            case .archived: return "Archived"
            case .stale: return "Stale"
            }
        }()
        let reversibilityLabel = entry.isReversible ? "Reversible" : "Irreversible"
        let persistenceLabel = entry.survivesRestart ? "Persistent" : "Session-Only"
        let timeLabel = entry.timestamp.formatted(date: .abbreviated, time: .shortened)
        return "\(entry.title), \(entry.context.displayName), \(stateLabel), \(reversibilityLabel), \(persistenceLabel), \(entry.affectedSummary), \(timeLabel)"
    }

    // MARK: - Actions

    private func performUndoAction() {
        let target: OperationContext? = (scopeMode == .activeContext) ? displayedContext : nil
        Task {
            let label = currentUndoButtonTitle
            await coordinator.undo(in: target)
            AccessibilityAnnouncer.announce("Performed \(label).", priority: .medium)
        }
    }

    private func performRedoAction() {
        let target: OperationContext? = (scopeMode == .activeContext) ? displayedContext : nil
        Task {
            let label = currentRedoButtonTitle
            await coordinator.redo(in: target)
            AccessibilityAnnouncer.announce("Performed \(label).", priority: .medium)
        }
    }
}
