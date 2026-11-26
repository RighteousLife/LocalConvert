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
    
    /// Groups filtered jobs by batchID in deterministic appearance order when multiple jobs share the same batch
    private var batchGroupedSections: (batches: [BatchGroup], standaloneJobs: [ConversionJob]) {
        var batchDict: [UUID: [ConversionJob]] = [:]
        var orderedBatchIDs: [UUID] = []
        var standalone: [ConversionJob] = []
        
        for job in filteredJobs {
            if let batchID = job.batchID {
                if batchDict[batchID] == nil {
                    orderedBatchIDs.append(batchID)
                }
                batchDict[batchID, default: []].append(job)
            } else {
                standalone.append(job)
            }
        }
        
        var batches: [BatchGroup] = []
        for id in orderedBatchIDs {
            guard let jobs = batchDict[id] else { continue }
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
            
            AppDivider()
            
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
        .onAppear {
            manager.applyRetentionPolicy(AppSettings.shared.jobsRetentionPolicy)
        }
    }
    
    // MARK: - Subviews
    
    private var jobsListView: some View {
        ScrollView {
            LazyVStack(spacing: AppTheme.Spacing.sm) {
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
            .padding(AppTheme.Spacing.lg)
        }
    }
    
    private var emptyStateView: some View {
        AppEmptyStateView(
            icon: "tray",
            title: "No Active or Recent Jobs",
            subtitle: "Live execution state and recent session conversions appear here. Persistent past outcomes are archived in Conversion History.",
            primaryButtonTitle: "Add Files to Convert",
            primaryButtonIcon: "plus",
            onPrimaryAction: openFilePicker
        )
    }

    private var filteredEmptyStateView: some View {
        AppEmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: "No \(filter.rawValue) Jobs",
            subtitle: "Try selecting 'All' to see all conversion jobs.",
            primaryButtonTitle: "Show All Jobs",
            onPrimaryAction: { filter = .all }
        )
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
