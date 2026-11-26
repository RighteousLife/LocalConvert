import Foundation
import AppKit
import ImageIO
import os.log

// MARK: - Conversion Queue

/// Manages a queue of conversion jobs with configurable concurrency limits
@MainActor
final class ConversionQueue: ObservableObject {
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ConversionQueue")
    
    /// Maximum number of concurrent conversions
    var maxConcurrent: Int {
        AppSettings.shared.concurrentConversions.count
    }
    
    @Published private(set) var pendingJobs: [ConversionJob] = []
    @Published private(set) var activeJobCount: Int = 0
    @Published private(set) var completedCount: Int = 0
    @Published private(set) var failedCount: Int = 0
    @Published private(set) var cancelledCount: Int = 0
    @Published private(set) var totalCount: Int = 0
    
    /// Optional callback invoked when a batch starts from an idle queue
    var onQueueStarted: (@MainActor () -> Void)?

    /// Optional callback invoked when all jobs in the queue have completed
    var onQueueCompleted: (@MainActor () -> Void)?
    
    private let conversionManager: ConversionManager
    private let undoCoordinator: UndoRedoCoordinator
    private(set) var batchCompletedOutputURLs: [URL] = []
    private(set) var lastBatchCompletedOutputURLs: [URL] = []
    private var inFlightJobIDs: Set<UUID> = []
    private var inFlightJobCosts: [UUID: Int] = [:]
    private var preCancelledInFlightJobIDs: Set<UUID> = []
    private var pendingUndoChain: Task<Void, Never>?
    private(set) var activeWorkloadCost: Int = 0

    nonisolated static func jobSlotCost(for job: ConversionJob) -> Int {
        if job.inputFormat.category == .document
            || job.outputFormat.category == .document
            || job.inputFormat == .pdf
            || job.outputFormat == .pdf
            || job.inputFormat.category == .video
            || job.outputFormat.category == .video {
            return 2
        }
        if job.inputFormat.category == .image || job.outputFormat.category == .image {
            for url in job.inputURLs {
                if let pixels = imagePixelCount(at: url), pixels >= 36_000_000 {
                    return 2
                }
            }
        }
        return 1
    }

    private nonisolated static func imagePixelCount(at url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, noCache),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : pixels
    }
    
    init(
        conversionManager: ConversionManager,
        undoCoordinator: UndoRedoCoordinator = .shared
    ) {
        self.conversionManager = conversionManager
        self.undoCoordinator = undoCoordinator
        self.conversionManager.onPendingCancel = { [weak self] jobId in
            self?.handleExternalCancellation(jobId: jobId)
        }
        self.conversionManager.onActiveRemove = { [weak self] jobId in
            self?.handleExternalRemoval(jobId: jobId)
        }
    }
    
    // MARK: - Queue Management
    
    /// Enqueue multiple jobs for processing
    func enqueue(jobs: [ConversionJob]) {
        guard !jobs.isEmpty else { return }
        if activeJobCount == 0 && pendingJobs.isEmpty {
            completedCount = 0
            failedCount = 0
            cancelledCount = 0
            totalCount = 0
            preCancelledInFlightJobIDs.removeAll()
            batchCompletedOutputURLs.removeAll()
        }
        for job in jobs {
            conversionManager.registerPending(job: job)
        }
        pendingJobs.append(contentsOf: jobs)
        totalCount += jobs.count
        onQueueStarted?()
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
        let activeToCancel = inFlightJobIDs.subtracting(preCancelledInFlightJobIDs)
        preCancelledInFlightJobIDs.formUnion(activeToCancel)
        inFlightJobIDs.removeAll()
        inFlightJobCosts.removeAll()

        cancelledCount += pendingCount + activeToCancel.count
        activeJobCount = 0
        activeWorkloadCost = 0
        batchCompletedOutputURLs.removeAll()
        conversionManager.cancelAll()
        onQueueCompleted?()
        
        logger.info("All jobs cancelled. Total cancelled: \(self.cancelledCount, privacy: .public)")
    }
    
    /// Reset the queue counters
    func reset() {
        pendingJobs.removeAll()
        inFlightJobIDs.removeAll()
        inFlightJobCosts.removeAll()
        preCancelledInFlightJobIDs.removeAll()
        conversionManager.cancelAll()
        activeJobCount = 0
        activeWorkloadCost = 0
        completedCount = 0
        failedCount = 0
        cancelledCount = 0
        totalCount = 0
        batchCompletedOutputURLs.removeAll()
    }
    
    // MARK: - Progress
    
    var progress: Double {
        guard totalCount > 0 else { return 0 }
        let terminal = Double(completedCount + failedCount + cancelledCount)
        let inFlightProgress = inFlightJobIDs.reduce(0.0) { partial, id in
            if case .converting(let value) = conversionManager.status(for: id),
               let fraction = value.fractionCompleted {
                return partial + min(max(fraction, 0.0), 1.0)
            }
            return partial
        }
        return min(max((terminal + inFlightProgress) / Double(totalCount), 0.0), 1.0)
    }
    
    var isProcessing: Bool {
        activeJobCount > 0 || !pendingJobs.isEmpty
    }
    
    // MARK: - Private
    
    private func processNext() {
        while let nextJob = pendingJobs.first {
            let cost = Self.jobSlotCost(for: nextJob)
            let canSchedule = (activeJobCount == 0)
                || (activeWorkloadCost + cost <= maxConcurrent && activeJobCount < maxConcurrent)
            guard canSchedule else { break }

            pendingJobs.removeFirst()
            activeJobCount += 1
            activeWorkloadCost += cost
            inFlightJobIDs.insert(nextJob.id)
            inFlightJobCosts[nextJob.id] = cost

            conversionManager.submit(job: nextJob) { [weak self] status in
                self?.handleJobCompletion(job: nextJob, status: status)
            }
        }
    }
    
    private func handleJobCompletion(job: ConversionJob, status: ConversionJobStatus) {
        if preCancelledInFlightJobIDs.remove(job.id) != nil {
            inFlightJobCosts.removeValue(forKey: job.id)
            return
        }
        guard inFlightJobIDs.remove(job.id) != nil else {
            return
        }
        let cost = inFlightJobCosts.removeValue(forKey: job.id) ?? Self.jobSlotCost(for: job)
        activeJobCount = max(0, activeJobCount - 1)
        activeWorkloadCost = max(0, activeWorkloadCost - cost)
        switch status {
        case .completed(let result):
            completedCount += 1
            let uniqueOutputs = Self.deduplicatedOutputURLs(from: result.allOutputURLs)
            for url in uniqueOutputs where !batchCompletedOutputURLs.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                batchCompletedOutputURLs.append(url)
            }
            recordOutputUndoIfSafe(job: job, outputURLs: uniqueOutputs)
            if totalCount == 1 {
                AppNotificationManager.shared.notifyJobCompleted(job: job, result: result)
            }
        case .failed(let err):
            failedCount += 1
            if totalCount == 1 {
                AppNotificationManager.shared.notifyJobFailed(job: job, error: err)
            }
        case .cancelled:
            cancelledCount += 1
        case .waiting, .converting:
            break
        }
        processNext()
        finalizeQueueIfIdle()
    }

    private func handleExternalCancellation(jobId: UUID) {
        if let pendingIndex = pendingJobs.firstIndex(where: { $0.id == jobId }) {
            pendingJobs.remove(at: pendingIndex)
            cancelledCount += 1
            finalizeQueueIfIdle()
        }
    }

    private func handleExternalRemoval(jobId: UUID) {
        if let pendingIndex = pendingJobs.firstIndex(where: { $0.id == jobId }) {
            pendingJobs.remove(at: pendingIndex)
            cancelledCount += 1
            finalizeQueueIfIdle()
            return
        }
        guard inFlightJobIDs.remove(jobId) != nil else {
            return
        }
        preCancelledInFlightJobIDs.insert(jobId)
        let cost = inFlightJobCosts.removeValue(forKey: jobId) ?? 1
        activeJobCount = max(0, activeJobCount - 1)
        activeWorkloadCost = max(0, activeWorkloadCost - cost)
        cancelledCount += 1
        processNext()
        finalizeQueueIfIdle()
    }

    private func finalizeQueueIfIdle() {
        if activeJobCount == 0 && pendingJobs.isEmpty {
            _ = ConversionManager.cleanStaleTemporaryFiles()
            if totalCount > 1 {
                AppNotificationManager.shared.notifyBatchCompleted(
                    total: totalCount,
                    completed: completedCount,
                    failed: failedCount,
                    cancelled: cancelledCount
                )
            }
            executeAfterConversionAction()
            lastBatchCompletedOutputURLs = batchCompletedOutputURLs
            batchCompletedOutputURLs.removeAll()
            onQueueCompleted?()
        }
    }
    
    func flushPendingUndoRecords() async {
        await pendingUndoChain?.value
    }

    nonisolated static func deduplicatedOutputURLs(from urls: [URL]) -> [URL] {
        var seenResolved = Set<URL>()
        var result: [URL] = []
        for url in urls {
            let std = url.standardizedFileURL
            let resolved = std.resolvingSymlinksInPath()
            guard !seenResolved.contains(resolved) else { continue }
            seenResolved.insert(resolved)
            result.append(std)
        }
        return result
    }

    nonisolated static func safeUndoableOutputURLs(
        outputURLs: [URL],
        protectedSourceURLs: [URL],
        requireExistsOnDisk: Bool = true
    ) -> [URL] {
        let protectedResolved = Set(protectedSourceURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        var seenResolved = Set<URL>()
        var safe: [URL] = []
        for url in outputURLs {
            let std = url.standardizedFileURL
            let resolved = std.resolvingSymlinksInPath()
            guard !protectedResolved.contains(resolved), !seenResolved.contains(resolved) else {
                continue
            }
            if requireExistsOnDisk && !FileManager.default.fileExists(atPath: std.path) {
                continue
            }
            seenResolved.insert(resolved)
            safe.append(std)
        }
        return safe
    }

    private func recordOutputUndoIfSafe(job: ConversionJob, outputURLs: [URL]) {
        guard !job.options.overwriteExisting else { return }
        let safeOutputs = Self.safeUndoableOutputURLs(
            outputURLs: outputURLs,
            protectedSourceURLs: job.inputURLs,
            requireExistsOnDisk: true
        )
        guard !safeOutputs.isEmpty, let primary = safeOutputs.first else { return }

        let context: OperationContext
        if job.options.customOptions["pdf_operation"] != nil {
            context = .pdfToolbox
        } else if job.options.customOptions["audio_operation"] != nil {
            context = .audioToolbox
        } else if job.inputFormat.category == .image && job.options.customOptions["image_toolbox"] != nil {
            context = .imageToolbox
        } else {
            context = .convert
        }

        let title: String
        if safeOutputs.count == 1 {
            title = job.options.hasVideoTrim
                ? "Trim Video \(primary.lastPathComponent)"
                : "Create \(primary.lastPathComponent)"
        } else {
            title = "Create \(safeOutputs.count) Files (\(primary.lastPathComponent))"
        }

        let cmd = OutputCreationUndoCommand(
            title: title,
            context: context,
            outputURLs: safeOutputs,
            protectedSourceURLs: job.inputURLs
        )
        let coordinator = undoCoordinator
        let prev = pendingUndoChain
        pendingUndoChain = Task { @MainActor in
            _ = await prev?.value
            await coordinator.record(cmd)
        }
    }

    private func executeAfterConversionAction() {
        let isAutomatedTest = ProcessInfo.processInfo.environment["LOCALCONVERT_UITEST"] == "1"
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isAutomatedTest else { return }

        let action = AppSettings.shared.afterConversionAction
        guard action != .doNothing else { return }
        
        let outputURLs = batchCompletedOutputURLs
        guard !outputURLs.isEmpty else { return }
        
        switch action {
        case .doNothing:
            break
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
        case .openOutputFile:
            if outputURLs.count == 1, let first = outputURLs.first {
                NSWorkspace.shared.open(first)
            } else if let firstDir = outputURLs.first?.deletingLastPathComponent() {
                NSWorkspace.shared.open(firstDir)
            }
        case .openOutputFolder:
            if let firstDir = outputURLs.first?.deletingLastPathComponent() {
                NSWorkspace.shared.open(firstDir)
            }
        }
    }
}
