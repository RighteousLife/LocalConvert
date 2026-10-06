import SwiftUI

// MARK: - Jobs Center View

struct JobsCenterView: View {
    @EnvironmentObject var appState: AppState
    @State private var filter: JobsFilter = .all
    
    private var manager: ConversionManager {
        appState.conversionManager
    }
    
    private var filteredJobs: [ConversionJob] {
        switch filter {
        case .all:
            return manager.activeJobs
        case .active:
            return manager.activeJobs.filter { manager.status(for: $0.id).isActive }
        case .completed:
            return manager.completedJobs
        case .failed:
            return manager.failedJobs
        }
    }
    
    /// Groups filtered jobs by batchID when multiple jobs share the same batch
    private var batchGroupedSections: (batches: [BatchGroup], standaloneJobs: [ConversionJob]) {
        var batchDict: [UUID: [ConversionJob]] = [:]
        var standalone: [ConversionJob] = []
        
        for job in filteredJobs {
            if let batchID = job.batchID {
                batchDict[batchID, default: []].append(job)
            } else {
                standalone.append(job)
            }
        }
        
        var batches: [BatchGroup] = []
        for (id, jobs) in batchDict {
            if jobs.count > 1 {
                batches.append(BatchGroup(id: id, jobs: jobs))
            } else {
                standalone.append(contentsOf: jobs)
            }
        }
        
        return (batches, standalone)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Summary & Filters
            JobsSummaryHeaderView(filter: $filter)
            
            Divider()
            
            // Content Area
            if manager.activeJobs.isEmpty {
                emptyStateView
            } else if filteredJobs.isEmpty {
                filteredEmptyStateView
            } else {
                jobsListView
            }
        }
        .navigationTitle("Jobs Center")
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            manager.applyRetentionPolicy(AppSettings.shared.jobsRetentionPolicy)
        }
    }
    
    // MARK: - Subviews
    
    private var jobsListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                let sections = batchGroupedSections
                
                // Batches
                ForEach(sections.batches) { batch in
                    BatchJobGroupView(batch: batch)
                }
                
                // Standalone Jobs
                ForEach(sections.standaloneJobs) { job in
                    JobRowView(job: job)
                }
            }
            .padding(16)
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 4) {
                Text("No Active or Recent Jobs")
                    .font(.headline)
                Text("Conversions you initiate will appear here in real-time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Button("Add Files to Convert") {
                openFilePicker()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
    
    private var filteredEmptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            
            Text("No \(filter.rawValue) Jobs")
                .font(.headline)
            Text("Try selecting 'All' to see all conversion jobs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Button("Show All Jobs") {
                filter = .all
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
    
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            appState.addFiles(urls: panel.urls)
            appState.selectedTab = .convert
        }
    }
}
