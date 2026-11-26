import SwiftUI

// MARK: - Batch Group Model

@MainActor
struct BatchGroup: Identifiable {
    let id: UUID
    let jobs: [ConversionJob]
    
    var totalCount: Int { jobs.count }
    
    func completedCount(manager: ConversionManager) -> Int {
        jobs.filter {
            if case .completed = manager.status(for: $0.id) { return true }
            return false
        }.count
    }
    
    func failedCount(manager: ConversionManager) -> Int {
        jobs.filter {
            if case .failed = manager.status(for: $0.id) { return true }
            return false
        }.count
    }
    
    func runningCount(manager: ConversionManager) -> Int {
        jobs.filter {
            if case .converting = manager.status(for: $0.id) { return true }
            return false
        }.count
    }
    
    func progressFraction(manager: ConversionManager) -> Double {
        guard totalCount > 0 else { return 0.0 }
        let sum = jobs.reduce(0.0) { $0 + manager.status(for: $1.id).progressFraction }
        return sum / Double(totalCount)
    }
    
    func isAllCompleted(manager: ConversionManager) -> Bool {
        jobs.allSatisfy { manager.status(for: $0.id).isTerminal }
    }
}

// MARK: - Batch Job Group View

struct BatchJobGroupView: View {
    let batch: BatchGroup
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true
    
    private var manager: ConversionManager {
        appState.conversionManager
    }
    
    private var completed: Int { batch.completedCount(manager: manager) }
    private var failed: Int { batch.failedCount(manager: manager) }
    private var running: Int { batch.runningCount(manager: manager) }
    private var progress: Double { batch.progressFraction(manager: manager) }
    
    var body: some View {
        AppCard(padding: AppTheme.Spacing.sm) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(batch.jobs) { job in
                        JobRowView(job: job)
                    }
                }
                .padding(.top, AppTheme.Spacing.xs)
            } label: {
                HStack(spacing: AppTheme.Spacing.sm + 2) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(AppTheme.Typography.cardTitle)
                        .foregroundStyle(AppTheme.Colors.accent)
                    
                    Text("Batch — \(batch.totalCount) files")
                        .font(AppTheme.Typography.cardTitle)
                    
                    HStack(spacing: AppTheme.Spacing.xs + 2) {
                        if completed > 0 {
                            Label("\(completed)", systemImage: "checkmark.circle.fill")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.success)
                        }
                        if failed > 0 {
                            Label("\(failed)", systemImage: "exclamationmark.triangle.fill")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.error)
                        }
                        if running > 0 {
                            Label("\(running)", systemImage: "arrow.triangle.2.circlepath")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.Colors.accent)
                        }
                    }
                    
                    Spacer()
                    
                    if batch.isAllCompleted(manager: manager), let summary = manager.batchSummary(for: batch.id) {
                        Text(summary.displayString)
                            .font(AppTheme.Typography.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundStyle(summary.savedBytes > 0 ? AppTheme.Colors.success : .secondary)
                    } else {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                        
                        Text("\(Int(progress * 100))%")
                            .font(AppTheme.Typography.monoCaption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, AppTheme.Spacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Batch of \(batch.totalCount) files, \(completed) completed, \(failed) failed")
    }
}
