import Foundation
import os.log

// MARK: - Conversion Queue

/// Manages a queue of conversion jobs with configurable concurrency limits
@MainActor
final class ConversionQueue: ObservableObject {
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ConversionQueue")
    
    /// Maximum number of concurrent conversions
    let maxConcurrent: Int
    
    @Published private(set) var pendingJobs: [ConversionJob] = []
    @Published private(set) var activeJobCount: Int = 0
    @Published private(set) var completedCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    @Published private(set) var cancelledCount: Int = 0
    @Published private(set) var totalCount: Int = 0
    
    /// Optional callback invoked when all jobs in the queue have completed
    var onQueueCompleted: (@MainActor () -> Void)?
    
    private let conversionManager: ConversionManager
    
    init(
        maxConcurrent: Int = 3,
        conversionManager: ConversionManager
    ) {
        self.maxConcurrent = maxConcurrent
        self.conversionManager = conversionManager
    }
    
    // MARK: - Queue Management
    
    /// Enqueue multiple jobs for processing
    func enqueue(jobs: [ConversionJob]) {
        pendingJobs.append(contentsOf: jobs)
        totalCount += jobs.count
        processNext()
        
        logger.info("Enqueued \(jobs.count, privacy: .public) jobs. Total: \(self.totalCount, privacy: .public)")
    }
    
    /// Enqueue a single job
    func enqueue(job: ConversionJob) {
        enqueue(jobs: [job])
    }
    
    /// Cancel all pending and active jobs
    func cancelAll() {
        let pendingCount = pendingJobs.count
        pendingJobs.removeAll()
        conversionManager.cancelAll()
        cancelledCount += (pendingCount + activeJobCount)
        activeJobCount = 0
        onQueueCompleted?()
        
        logger.info("All jobs cancelled. Total cancelled: \(self.cancelledCount, privacy: .public)")
    }
    
    /// Reset the queue counters
    func reset() {
        pendingJobs.removeAll()
        conversionManager.cancelAll()
        activeJobCount = 0
        completedCount = 0
        failedCount = 0
        cancelledCount = 0
        totalCount = 0
    }
    
    // MARK: - Progress
    
    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount + failedCount + cancelledCount) / Double(totalCount)
    }
    
    var isProcessing: Bool {
        activeJobCount > 0 || !pendingJobs.isEmpty
    }
    
    // MARK: - Private
    
    private func processNext() {
        while activeJobCount < maxConcurrent && !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            activeJobCount += 1
            
            conversionManager.submit(job: job) { [weak self] status in
                Task { @MainActor in
                    self?.handleJobCompletion(status: status)
                }
            }
        }
    }
    
    private func handleJobCompletion(status: ConversionJobStatus) {
        activeJobCount = max(0, activeJobCount - 1)
        switch status {
        case .completed:
            completedCount += 1
        case .failed:
            failedCount += 1
        case .cancelled:
            cancelledCount += 1
        case .waiting, .converting:
            break
        }
        processNext()
        
        if activeJobCount == 0 && pendingJobs.isEmpty {
            onQueueCompleted?()
        }
    }
}
