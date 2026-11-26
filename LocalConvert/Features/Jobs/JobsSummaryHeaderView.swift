import SwiftUI

// MARK: - Jobs Filter

enum JobsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case completed = "Completed"
    case failed = "Failed"
    
    var id: String { rawValue }
}

// MARK: - Jobs Summary Header View

struct JobsSummaryHeaderView: View {
    @EnvironmentObject var appState: AppState
    @Binding var filter: JobsFilter
    
    private var manager: ConversionManager {
        appState.conversionManager
    }
    
    private var runningCount: Int { manager.runningJobs.count }
    private var queuedCount: Int { manager.queuedJobs.count }
    private var completedCount: Int { manager.completedJobs.count }
    private var failedCount: Int { manager.failedJobs.count }
    private var totalActiveCount: Int { runningCount + queuedCount }
    private var hasActiveJobs: Bool { totalActiveCount > 0 }
    private var hasCompletedJobs: Bool { completedCount + failedCount + manager.cancelledJobs.count > 0 }
    
    @State private var showingClearCompletedAlert = false
    @State private var showingClearFailedAlert = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if hasActiveJobs || hasCompletedJobs {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                        filterPicker
                        Spacer(minLength: AppTheme.Spacing.md)
                        headerActionButtons
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        filterPicker
                        HStack {
                            headerActionButtons
                            Spacer(minLength: 0)
                        }
                    }
                }
            } else {
                filterPicker
            }

            // Status Metrics & Scope Clarification
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.lg) {
                    statusMetricsRow
                    Spacer(minLength: AppTheme.Spacing.md)
                    historyScopeNoteAndLink
                }

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    statusMetricsRow
                    historyScopeNoteAndLink
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var statusMetricsRow: some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            summaryItem(
                title: "Active",
                count: totalActiveCount,
                color: totalActiveCount > 0 ? AppTheme.Colors.accent : .secondary
            )

            Text("·")
                .foregroundStyle(.tertiary)
                .font(AppTheme.Typography.caption)

            summaryItem(
                title: "Completed",
                count: completedCount,
                color: completedCount > 0 ? AppTheme.Colors.success : .secondary
            )

            Text("·")
                .foregroundStyle(.tertiary)
                .font(AppTheme.Typography.caption)

            summaryItem(
                title: "Failed",
                count: failedCount,
                color: failedCount > 0 ? AppTheme.Colors.error : .secondary
            )
        }
    }

    private var historyScopeNoteAndLink: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Live execution queue and recent session jobs. Persistent records live in Conversion History.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("jobs.surfaceDescription")

            Spacer(minLength: AppTheme.Spacing.xs)

            Button {
                appState.openConversionHistory()
            } label: {
                Label("Conversion History", systemImage: "clock")
                    .lineLimit(1)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help("Open persistent Conversion History archive")
            .accessibilityLabel("Open Conversion History")
            .accessibilityIdentifier("jobs.openHistory")
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(JobsFilter.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Filter conversion jobs")
    }

    @ViewBuilder
    private var headerActionButtons: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if completedCount > 0, let firstOutput = manager.completedJobs.compactMap({ manager.result(for: $0.id)?.outputURL }).first {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([firstOutput.deletingLastPathComponent()])
                } label: {
                    Label("Open Output Folder", systemImage: "folder")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Open directory containing completed files")
                .accessibilityLabel("Open output folder")
            }

            if hasActiveJobs {
                Button(role: .destructive) {
                    appState.cancelConversion()
                } label: {
                    Label("Cancel All", systemImage: "xmark.circle")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Cancel all active conversions")
                .accessibilityLabel("Cancel all active conversions")
            }

            if completedCount > 0 {
                Button {
                    if completedCount > 1 {
                        showingClearCompletedAlert = true
                    } else {
                        appState.conversionManager.clearCompletedJobs()
                    }
                } label: {
                    Label("Clear Completed", systemImage: "checkmark.circle")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Clear completed jobs from list")
                .accessibilityLabel("Clear completed jobs")
                .alert("Clear Completed Jobs", isPresented: $showingClearCompletedAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear All", role: .destructive) {
                        appState.conversionManager.clearCompletedJobs()
                    }
                } message: {
                    Text("Remove \(completedCount) completed jobs from the list?")
                }
            }

            if failedCount > 0 {
                Button {
                    if failedCount > 1 {
                        showingClearFailedAlert = true
                    } else {
                        appState.conversionManager.clearFailedJobs()
                    }
                } label: {
                    Label("Clear Failed", systemImage: "xmark.circle")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Clear failed and cancelled jobs from list")
                .accessibilityLabel("Clear failed jobs")
                .alert("Clear Failed Jobs", isPresented: $showingClearFailedAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear All", role: .destructive) {
                        appState.conversionManager.clearFailedJobs()
                    }
                } message: {
                    Text("Remove \(failedCount) failed jobs from the list?")
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    
    private func summaryItem(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(AppTheme.Typography.subheadline)
                .foregroundStyle(.secondary)
            
            Text("\(count)")
                .font(AppTheme.Typography.subheadline)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
