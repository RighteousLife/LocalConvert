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
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 4) {
                    ForEach(batch.jobs) { job in
                        JobRowView(job: job)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                    
                    Text("Batch — \(batch.totalCount) files")
                        .font(.system(size: 13, weight: .semibold))
                    
                    HStack(spacing: 6) {
                        if completed > 0 {
                            Label("\(completed)", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        }
                        if failed > 0 {
                            Label("\(failed)", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                        if running > 0 {
                            Label("\(running)", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    
                    Spacer()
                    
                    if batch.isAllCompleted(manager: manager), let summary = manager.batchSummary(for: batch.id) {
                        Text(summary.displayString)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(summary.savedBytes > 0 ? .green : .secondary)
                    } else {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                        
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Batch of \(batch.totalCount) files, \(completed) completed, \(failed) failed")
    }
}
