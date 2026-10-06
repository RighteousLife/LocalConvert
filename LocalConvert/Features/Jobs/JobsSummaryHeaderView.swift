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
        VStack(alignment: .leading, spacing: 12) {
            // Row 1: Action Buttons (only visible when there are active or completed jobs)
            if hasActiveJobs || hasCompletedJobs {
                HStack(alignment: .center) {
                    Spacer()
                    
                    HStack(spacing: 8) {
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
                }
            }
            
            // Row 2: Segmented Filter (Dedicated row)
            Picker("Filter", selection: $filter) {
                ForEach(JobsFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            
            // Row 3: Status Metrics (Dedicated row — no horizontal competition)
            HStack(spacing: 16) {
                summaryItem(
                    title: "Active",
                    count: totalActiveCount,
                    color: totalActiveCount > 0 ? Color.accentColor : .secondary
                )
                
                Text("·")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                
                summaryItem(
                    title: "Completed",
                    count: completedCount,
                    color: completedCount > 0 ? .green : .secondary
                )
                
                Text("·")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                
                summaryItem(
                    title: "Failed",
                    count: failedCount,
                    color: failedCount > 0 ? .red : .secondary
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
    
    private func summaryItem(title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }
}
