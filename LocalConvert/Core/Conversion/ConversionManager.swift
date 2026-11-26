import Foundation
import os.log

// MARK: - Conversion Job

struct ConversionJob: Identifiable, Sendable {
    let id: UUID
    let inputURLs: [URL]
    let inputFormat: FileFormat
    let outputFormat: FileFormat
    let outputDirectory: URL
    let options: ConversionOptions
    let createdAt: Date
    let batchID: UUID?
    let presetName: String?
    let source: ConversionSource
    let watchFolderRuleID: UUID?
    let watchFolderRuleName: String?
    
    init(
        id: UUID = UUID(),
        inputURLs: [URL],
        inputFormat: FileFormat,
        outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions = .default,
        createdAt: Date = Date(),
        batchID: UUID? = nil,
        presetName: String? = nil,
        source: ConversionSource = .manual,
        watchFolderRuleID: UUID? = nil,
        watchFolderRuleName: String? = nil
    ) {
        self.id = id
        self.inputURLs = inputURLs
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.outputDirectory = outputDirectory
        self.options = options
        self.createdAt = createdAt
        self.batchID = batchID
        self.presetName = presetName ?? options.customOptions["preset_name"] ?? options.effectivePreset?.rawValue
        self.source = source
        self.watchFolderRuleID = watchFolderRuleID
        self.watchFolderRuleName = watchFolderRuleName
    }
    
    var inputURL: URL? {
        inputURLs.first
    }
    
    var sourceFilename: String {
        inputURLs.first?.lastPathComponent ?? "Unknown"
    }
    
    var inputFilename: String {
        sourceFilename
    }
    
    var sourceFormat: FileFormat {
        inputFormat
    }
    
    var targetFormat: FileFormat {
        outputFormat
    }
}

// MARK: - Conversion Job Status

enum ConversionJobStatus: Sendable, Equatable {
    case waiting
    case converting(ConversionProgress)
    case completed(ConversionResult)
    case failed(ConversionError)
    case cancelled
    
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .waiting, .converting: return false
        }
    }
    
    var isActive: Bool {
        switch self {
        case .waiting, .converting: return true
        case .completed, .failed, .cancelled: return false
        }
    }
    
    var progressFraction: Double {
        switch self {
        case .waiting: return 0.0
        case .converting(let progress):
            return progress.fractionCompleted ?? 0.5
        case .completed: return 1.0
        case .failed, .cancelled: return 0.0
        }
    }
    
    var progressMessage: String? {
        switch self {
        case .waiting: return "Queued"
        case .converting(let progress):
            return progress.statusMessage
        case .completed: return "Completed"
        case .failed(let err): return err.errorDescription ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }
    
    var displayTitle: String {
        switch self {
        case .waiting: return "Queued"
        case .converting: return "Converting"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Conversion Manager

@MainActor
final class ConversionManager: ObservableObject {
    
    typealias TrashItemHandler = @Sendable (URL) throws -> URL?

    enum TrashOriginalEligibility: Sendable, Equatable {
        case eligible([URL])
        case skipped(String)
    }

    private let logger = Logger(subsystem: "com.localconvert.app", category: "ConversionManager")
    private let registry: ConversionRegistry
    private let historyManager: HistoryManager
    private let diskSpaceGuard: DiskSpaceGuard
    private let settings: AppSettings
    private let queueStore: PersistentQueueStore
    private let trashHandler: TrashItemHandler
    
    @Published var jobStatuses: [UUID: ConversionJobStatus] = [:]
    @Published var activeJobs: [ConversionJob] = []
    @Published var jobStartedTimes: [UUID: Date] = [:]
    @Published var jobCompletedTimes: [UUID: Date] = [:]
    @Published var jobResults: [UUID: ConversionResult] = [:]
    @Published var jobErrors: [UUID: ConversionError] = [:]
    @Published private(set) var restoredQueueCount: Int = 0
    @Published private(set) var restoredUnfinishedJobs: [ConversionJob] = []
    @Published private(set) var restoredSkippedMissingCount: Int = 0
    @Published private(set) var lastTrashedInputURLs: [URL] = []
    
    var jobs: [ConversionJob] {
        get { activeJobs }
        set { activeJobs = newValue }
    }

    var hasRestoredQueueBanner: Bool {
        restoredQueueCount > 0
    }
    
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var onPendingCancel: (@MainActor (UUID) -> Void)?
    var onActiveRemove: (@MainActor (UUID) -> Void)?
    
    init(
        registry: ConversionRegistry = .shared,
        historyManager: HistoryManager = .shared,
        diskSpaceGuard: DiskSpaceGuard = DiskSpaceGuard(),
        settings: AppSettings = .shared,
        queueStore: PersistentQueueStore = PersistentQueueStore(),
        trashHandler: @escaping TrashItemHandler = { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return resultingURL as URL?
        },
        restoreQueueOnInit: Bool = true
    ) {
        self.registry = registry
        self.historyManager = historyManager
        self.diskSpaceGuard = diskSpaceGuard
        self.settings = settings
        self.queueStore = queueStore
        self.trashHandler = trashHandler
        _ = Self.cleanStaleTemporaryFiles()
        if restoreQueueOnInit {
            restoreUnfinishedQueueIfEnabled()
        }
    }
    
    // MARK: - Status Queries
    
    var queuedJobs: [ConversionJob] {
        activeJobs.filter { jobStatuses[$0.id] == .waiting }
    }
    
    var runningJobs: [ConversionJob] {
        activeJobs.filter {
            if let status = jobStatuses[$0.id], case .converting = status { return true }
            return false
        }
    }
    
    var completedJobs: [ConversionJob] {
        activeJobs.filter {
            if let status = jobStatuses[$0.id], case .completed = status { return true }
            return false
        }
    }
    
    var failedJobs: [ConversionJob] {
        activeJobs.filter {
            if let status = jobStatuses[$0.id], case .failed = status { return true }
            return false
        }
    }
    
    var cancelledJobs: [ConversionJob] {
        activeJobs.filter { jobStatuses[$0.id] == .cancelled }
    }
    
    var runningOrWaitingCount: Int {
        queuedJobs.count + runningJobs.count
    }
    
    func status(for jobId: UUID) -> ConversionJobStatus {
        jobStatuses[jobId] ?? .waiting
    }
    
    func result(for jobId: UUID) -> ConversionResult? {
        jobResults[jobId]
    }
    
    func error(for jobId: UUID) -> ConversionError? {
        jobErrors[jobId]
    }
    
    func startedTime(for jobId: UUID) -> Date? {
        jobStartedTimes[jobId]
    }
    
    func completedTime(for jobId: UUID) -> Date? {
        jobCompletedTimes[jobId]
    }
    
    func duration(for jobId: UUID) -> TimeInterval? {
        if let result = jobResults[jobId] {
            return result.duration
        }
        guard let start = jobStartedTimes[jobId] else { return nil }
        let end = jobCompletedTimes[jobId] ?? Date()
        return end.timeIntervalSince(start)
    }
    
    // MARK: - Job Management

    func registerPending(job: ConversionJob) {
        var didMutate = false
        if !activeJobs.contains(where: { $0.id == job.id }) {
            activeJobs.append(job)
            didMutate = true
        }
        if jobStatuses[job.id] == nil {
            jobStatuses[job.id] = .waiting
            didMutate = true
        }
        if didMutate {
            persistActiveQueueSnapshot()
        }
    }
    
    func submit(job: ConversionJob, onComplete: (@MainActor @Sendable (ConversionJobStatus) -> Void)? = nil) {
        if !activeJobs.contains(where: { $0.id == job.id }) {
            activeJobs.append(job)
        }
        jobStatuses[job.id] = .waiting
        persistActiveQueueSnapshot()
        
        let task = Task {
            await executeJob(job, onComplete: onComplete)
        }
        tasks[job.id] = task
    }
    
    func cancel(jobId: UUID) {
        tasks[jobId]?.cancel()
        tasks[jobId] = nil
        jobStatuses[jobId] = .cancelled
        jobCompletedTimes[jobId] = Date()
        onPendingCancel?(jobId)
        persistActiveQueueSnapshot()
        logger.info("Job \(jobId) cancelled")
    }
    
    func cancelAll() {
        for (id, task) in tasks {
            task.cancel()
            jobStatuses[id] = .cancelled
            jobCompletedTimes[id] = Date()
        }
        tasks.removeAll()
        for job in activeJobs where (jobStatuses[job.id]?.isActive ?? true) {
            jobStatuses[job.id] = .cancelled
            jobCompletedTimes[job.id] = Date()
        }
        persistActiveQueueSnapshot()
    }
    
    func removeJob(id: UUID) {
        cancel(jobId: id)
        onActiveRemove?(id)
        activeJobs.removeAll { $0.id == id }
        jobStatuses.removeValue(forKey: id)
        jobStartedTimes.removeValue(forKey: id)
        jobCompletedTimes.removeValue(forKey: id)
        jobResults.removeValue(forKey: id)
        jobErrors.removeValue(forKey: id)
        persistActiveQueueSnapshot()
    }

    // MARK: - Persistent Queue Recovery

    func restoreUnfinishedQueueIfEnabled() {
        guard settings.restoreUnfinishedQueueOnLaunch else { return }
        let result = queueStore.load()
        guard !result.recoveredJobs.isEmpty else {
            if result.droppedMissingOrInvalidCount > 0 || result.wasCorrupted {
                persistActiveQueueSnapshot()
            }
            return
        }

        var addedJobs: [ConversionJob] = []
        for job in result.recoveredJobs {
            if !activeJobs.contains(where: { $0.id == job.id }) {
                activeJobs.append(job)
            }
            if jobStatuses[job.id] == nil {
                jobStatuses[job.id] = .waiting
            }
            addedJobs.append(job)
        }

        restoredUnfinishedJobs = addedJobs
        restoredQueueCount = addedJobs.count
        restoredSkippedMissingCount = result.droppedMissingOrInvalidCount

        if result.droppedMissingOrInvalidCount > 0 || result.droppedDuplicateCount > 0 {
            persistActiveQueueSnapshot()
        }
        logger.info("Restored \(addedJobs.count, privacy: .public) unfinished job(s) from persistent queue")
    }

    func dismissRestoredQueueBanner(clearRestoredJobs: Bool = true) {
        let restoredIDs = Set(restoredUnfinishedJobs.map(\.id))
        restoredQueueCount = 0
        restoredSkippedMissingCount = 0
        restoredUnfinishedJobs = []
        guard clearRestoredJobs, !restoredIDs.isEmpty else { return }

        let removableIDs = Set(restoredIDs.filter { id in
            jobStatuses[id] == .waiting && tasks[id] == nil
        })
        if !removableIDs.isEmpty {
            for id in removableIDs {
                jobStatuses.removeValue(forKey: id)
                jobStartedTimes.removeValue(forKey: id)
                jobCompletedTimes.removeValue(forKey: id)
                jobResults.removeValue(forKey: id)
                jobErrors.removeValue(forKey: id)
            }
            activeJobs.removeAll { removableIDs.contains($0.id) }
            persistActiveQueueSnapshot()
        }
    }

    @discardableResult
    func consumeRestoredJobsForConvertTab() -> [ConversionJob] {
        let eligible = restoredUnfinishedJobs.filter { job in
            jobStatuses[job.id] == .waiting
                && tasks[job.id] == nil
                && job.inputURLs.allSatisfy { PersistentQueueStore.isValidRecoverableSourceFile($0) }
        }
        dismissRestoredQueueBanner(clearRestoredJobs: true)
        return eligible
    }

    func persistActiveQueueSnapshot() {
        let unfinished = activeJobs.filter { status(for: $0.id).isActive }
        queueStore.save(jobs: unfinished)
    }
    
    func clearCompleted() {
        activeJobs.removeAll { job in
            switch jobStatuses[job.id] {
            case .completed:
                let id = job.id
                jobStatuses.removeValue(forKey: id)
                jobStartedTimes.removeValue(forKey: id)
                jobCompletedTimes.removeValue(forKey: id)
                jobResults.removeValue(forKey: id)
                jobErrors.removeValue(forKey: id)
                return true
            default:
                return false
            }
        }
    }
    
    func clearCompletedJobs() {
        clearCompleted()
    }
    
    func clearFailedJobs() {
        activeJobs.removeAll { job in
            switch jobStatuses[job.id] {
            case .failed, .cancelled:
                let id = job.id
                jobStatuses.removeValue(forKey: id)
                jobStartedTimes.removeValue(forKey: id)
                jobCompletedTimes.removeValue(forKey: id)
                jobResults.removeValue(forKey: id)
                jobErrors.removeValue(forKey: id)
                return true
            default:
                return false
            }
        }
    }
    
    func applyRetentionPolicies(
        completedPolicy: JobsRetentionPolicy = AppSettings.shared.jobsRetentionPolicy,
        failedPolicy: FailedJobsRetentionPolicy = AppSettings.shared.failedJobsRetentionPolicy
    ) {
        let now = Date()
        let completedCutoff = completedPolicy.timeInterval.map { now.addingTimeInterval(-$0) }
        let failedCutoff = failedPolicy.timeInterval.map { now.addingTimeInterval(-$0) }
        
        guard !activeJobs.isEmpty else { return }

        var idsToRemove = Set<UUID>()
        for job in activeJobs {
            guard let completedDate = jobCompletedTimes[job.id] else { continue }
            let status = jobStatuses[job.id]

            switch status {
            case .completed:
                if let cutoff = completedCutoff, completedDate < cutoff {
                    idsToRemove.insert(job.id)
                }
            case .failed, .cancelled:
                if let cutoff = failedCutoff, completedDate < cutoff {
                    idsToRemove.insert(job.id)
                }
            default:
                break
            }
        }

        guard !idsToRemove.isEmpty else { return }

        for id in idsToRemove {
            jobStatuses.removeValue(forKey: id)
            jobStartedTimes.removeValue(forKey: id)
            jobCompletedTimes.removeValue(forKey: id)
            jobResults.removeValue(forKey: id)
            jobErrors.removeValue(forKey: id)
        }
        activeJobs.removeAll { idsToRemove.contains($0.id) }
    }
    
    func applyRetentionPolicy(_ policy: JobsRetentionPolicy) {
        applyRetentionPolicies(completedPolicy: policy)
    }
    
    func sizeComparison(for jobId: UUID) -> ConversionSizeComparison? {
        guard let job = activeJobs.first(where: { $0.id == jobId }),
              let inputURL = job.inputURL,
              let result = jobResults[jobId] else { return nil }
        
        let inputBytes = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        
        guard inputBytes > 0, outputBytes > 0 else { return nil }
        return ConversionSizeComparison(inputBytes: inputBytes, outputBytes: outputBytes)
    }
    
    func batchSummary(for batchID: UUID) -> BatchResultSummary? {
        let batchJobs = activeJobs.filter { $0.batchID == batchID }
        guard !batchJobs.isEmpty else { return nil }
        
        var completed = 0
        var failed = 0
        var cancelled = 0
        var totalIn: Int64 = 0
        var totalOut: Int64 = 0
        
        for job in batchJobs {
            let st = status(for: job.id)
            switch st {
            case .completed(let res):
                completed += 1
                let inB = job.inputURL.flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value
                } ?? 0
                let outB = (try? FileManager.default.attributesOfItem(atPath: res.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                totalIn += inB
                totalOut += outB
            case .failed:
                failed += 1
            case .cancelled:
                cancelled += 1
            default:
                break
            }
        }
        
        return BatchResultSummary(
            totalFiles: batchJobs.count,
            completedCount: completed,
            failedCount: failed,
            cancelledCount: cancelled,
            totalInputBytes: totalIn,
            totalOutputBytes: totalOut
        )
    }
    
    /// Retries a job by creating a brand-new ConversionJob with a fresh UUID and preserving its source, targets, options, and preset.
    @discardableResult
    func retry(jobId: UUID, using queue: ConversionQueue) -> ConversionJob? {
        guard let oldJob = activeJobs.first(where: { $0.id == jobId }) else { return nil }
        
        let newJob = ConversionJob(
            id: UUID(),
            inputURLs: oldJob.inputURLs,
            inputFormat: oldJob.inputFormat,
            outputFormat: oldJob.outputFormat,
            outputDirectory: oldJob.outputDirectory,
            options: oldJob.options,
            batchID: oldJob.batchID,
            presetName: oldJob.presetName,
            source: oldJob.source,
            watchFolderRuleID: oldJob.watchFolderRuleID,
            watchFolderRuleName: oldJob.watchFolderRuleName
        )
        
        // Clean up old job record
        removeJob(id: jobId)
        // Enqueue the new job through the existing queue
        queue.enqueue(job: newJob)
        return newJob
    }
    
    // MARK: - Private
    
    private func executeJob(
        _ job: ConversionJob,
        onComplete: (@MainActor @Sendable (ConversionJobStatus) -> Void)? = nil
    ) async {
        defer {
            if let status = jobStatuses[job.id] {
                // Record history only if enabled
                if settings.saveConversionHistory {
                    let historyStatus: HistoryStatus
                    var outputSizeBytes: Int64? = nil
                    var outputURLPath: String? = nil
                    var additionalOutputURLPaths: [String]? = nil
                    var duration: TimeInterval? = nil
                    var errorMsg: String? = nil
                    
                    switch status {
                    case .completed(let result):
                        historyStatus = .completed
                        outputSizeBytes = result.fileSize
                        outputURLPath = result.outputURL.path
                        let extraPaths = result.additionalOutputURLs.map(\.path)
                        additionalOutputURLPaths = extraPaths.isEmpty ? nil : extraPaths
                        duration = result.duration
                    case .failed(let err):
                        historyStatus = .failed
                        errorMsg = ErrorDetailsFormatter.sanitize(err.localizedDescription)
                    case .cancelled:
                        historyStatus = .cancelled
                    default:
                        historyStatus = .failed // Fallback if interrupted
                    }
                    
                    let primaryInput = job.inputURLs.first
                    let inputSize = primaryInput.flatMap {
                        (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value
                    }
                    let inputFilename = primaryInput?.lastPathComponent ?? "Unknown"
                    let fallbackStem = primaryInput?.deletingPathExtension().lastPathComponent ?? "output"
                    let resolvedOutputFilename = outputURLPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                        ?? "\(fallbackStem).\(job.outputFormat.fileExtension)"
                    
                    let historyItem = ConversionHistoryItem(
                        id: UUID(),
                        inputFilename: inputFilename,
                        inputFormatName: job.inputFormat.displayName,
                        outputFilename: resolvedOutputFilename,
                        outputFormatName: job.outputFormat.displayName,
                        date: Date(),
                        status: historyStatus,
                        inputSizeBytes: inputSize,
                        outputSizeBytes: outputSizeBytes,
                        presetName: job.presetName ?? job.options.customOptions["preset_name"] ?? job.options.effectivePreset?.rawValue,
                        outputURLPath: outputURLPath,
                        inputURLPath: primaryInput?.path,
                        duration: duration,
                        errorMessage: errorMsg,
                        source: job.source,
                        watchFolderRuleID: job.watchFolderRuleID,
                        watchFolderRuleName: job.watchFolderRuleName,
                        additionalOutputURLPaths: additionalOutputURLPaths
                    )
                    
                    historyManager.addEntry(historyItem)
                }
                trashOriginalInputsIfEligible(for: job, status: status)
                persistActiveQueueSnapshot()
                onComplete?(status)
            } else {
                persistActiveQueueSnapshot()
            }
        }
        
        guard !Task.isCancelled else {
            jobCompletedTimes[job.id] = Date()
            jobStatuses[job.id] = .cancelled
            return
        }

        guard let primaryInputURL = job.inputURLs.first else {
            let err = ConversionError.invalidInput("No input files specified for conversion job.")
            jobCompletedTimes[job.id] = Date()
            jobErrors[job.id] = err
            jobStatuses[job.id] = .failed(err)
            StructuredDiagnostics.record(
                category: .conversion,
                severity: .validation,
                stage: "inputCheck",
                operationID: job.id.uuidString,
                filename: nil,
                message: "Conversion job submitted with empty inputURLs (\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue))"
            )
            return
        }
        
        // Find engine
        guard let engine = registry.findEngine(from: job.inputFormat, to: job.outputFormat, options: job.options) else {
            let err = ConversionError.unsupportedConversion(from: job.inputFormat, to: job.outputFormat)
            jobCompletedTimes[job.id] = Date()
            jobErrors[job.id] = err
            jobStatuses[job.id] = .failed(err)
            StructuredDiagnostics.record(
                category: .conversion,
                severity: .validation,
                stage: "findEngine",
                operationID: job.id.uuidString,
                filename: primaryInputURL.lastPathComponent,
                message: "No conversion engine registered for \(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue)"
            )
            return
        }
        
        // Check engine availability
        guard await engine.isAvailable() else {
            let err = ConversionError.engineNotAvailable(engine.name)
            jobCompletedTimes[job.id] = Date()
            jobErrors[job.id] = err
            jobStatuses[job.id] = .failed(err)
            StructuredDiagnostics.record(
                category: .bundledTool,
                severity: .internalError,
                stage: "engineAvailable",
                operationID: job.id.uuidString,
                filename: primaryInputURL.lastPathComponent,
                message: "Engine '\(engine.name)' unavailable (\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue))"
            )
            return
        }
        
        // Check input file exists
        guard FileManager.default.fileExists(atPath: primaryInputURL.path) else {
            let err = ConversionError.inputFileNotFound(primaryInputURL)
            jobCompletedTimes[job.id] = Date()
            jobErrors[job.id] = err
            jobStatuses[job.id] = .failed(err)
            StructuredDiagnostics.record(
                category: .fileAccess,
                severity: .validation,
                stage: "inputCheck",
                operationID: job.id.uuidString,
                filename: primaryInputURL.lastPathComponent,
                message: "Input file missing (\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue))"
            )
            return
        }
        
        // Pre-flight disk space guard on staging and destination volumes
        do {
            try diskSpaceGuard.validateSufficientSpace(
                outputDirectory: job.outputDirectory,
                inputURLs: job.inputURLs,
                outputFormat: job.outputFormat
            )
        } catch let err as ConversionError {
            jobCompletedTimes[job.id] = Date()
            jobErrors[job.id] = err
            jobStatuses[job.id] = .failed(err)
            StructuredDiagnostics.record(
                category: .fileAccess,
                severity: StructuredDiagnostics.severity(for: err),
                stage: "diskSpaceCheck",
                operationID: job.id.uuidString,
                filename: job.inputURLs.first?.lastPathComponent,
                message: err.localizedDescription
            )
            return
        } catch {
            let err = ConversionError.unknown(error.localizedDescription)
            jobCompletedTimes[job.id] = Date()
            jobErrors[job.id] = err
            jobStatuses[job.id] = .failed(err)
            return
        }
        
        // Start conversion
        jobStartedTimes[job.id] = Date()
        jobStatuses[job.id] = .converting(.indeterminate)
        logger.info("Conversion started - Engine: \(engine.name, privacy: .public) Input: \(job.inputFormat.rawValue, privacy: .public) Output: \(job.outputFormat.rawValue, privacy: .public)")
        StructuredDiagnostics.record(
            category: .conversion,
            severity: .info,
            stage: "started",
            operationID: job.id.uuidString,
            filename: job.inputURLs.first?.lastPathComponent,
            message: "\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue) via \(engine.name)"
        )
        
        do {
            let result = try await engine.convert(
                inputs: job.inputURLs,
                to: job.outputFormat,
                outputDirectory: job.outputDirectory,
                options: job.options,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, case .converting = self.jobStatuses[job.id] else { return }
                        self.jobStatuses[job.id] = .converting(progress)
                    }
                }
            )
            
            guard activeJobs.contains(where: { $0.id == job.id }) else {
                cleanupLateCancelledOutputs(for: job, urls: result.allOutputURLs)
                return
            }
            jobCompletedTimes[job.id] = Date()
            
            guard !Task.isCancelled else {
                jobStatuses[job.id] = .cancelled
                cleanupLateCancelledOutputs(for: job, urls: result.allOutputURLs)
                StructuredDiagnostics.record(
                    category: .conversion,
                    severity: .info,
                    stage: "cancelled",
                    operationID: job.id.uuidString,
                    filename: job.inputURLs.first?.lastPathComponent,
                    message: "Cancelled after execution (\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue))"
                )
                return
            }
            
            // Save last used directory
            OutputManager.lastUsedDirectory = result.outputURL.deletingLastPathComponent()
            
            jobResults[job.id] = result
            jobStatuses[job.id] = .completed(result)
            logger.info("Conversion completed - Duration: \(result.duration, privacy: .public)s")
            StructuredDiagnostics.record(
                category: .conversion,
                severity: .info,
                stage: "completed",
                operationID: job.id.uuidString,
                filename: job.inputURLs.first?.lastPathComponent,
                message: "\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue) (\(result.allOutputURLs.count) output(s), \(result.fileSize) bytes, \(String(format: "%.3f", result.duration))s)"
            )
        } catch is CancellationError {
            guard activeJobs.contains(where: { $0.id == job.id }) else { return }
            jobCompletedTimes[job.id] = Date()
            jobStatuses[job.id] = .cancelled
            StructuredDiagnostics.record(
                category: .conversion,
                severity: .info,
                stage: "cancelled",
                operationID: job.id.uuidString,
                filename: job.inputURLs.first?.lastPathComponent,
                message: "Cancelled (\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue))"
            )
        } catch let error as ConversionError {
            guard activeJobs.contains(where: { $0.id == job.id }) else { return }
            jobCompletedTimes[job.id] = Date()
            if case .cancelled = error {
                jobStatuses[job.id] = .cancelled
                StructuredDiagnostics.record(
                    category: .conversion,
                    severity: .info,
                    stage: "cancelled",
                    operationID: job.id.uuidString,
                    filename: job.inputURLs.first?.lastPathComponent,
                    message: "Cancelled (\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue))"
                )
            } else {
                jobErrors[job.id] = error
                jobStatuses[job.id] = .failed(error)
                logger.error("Conversion failed: \(error.localizedDescription, privacy: .public)")
                let category: DiagnosticCategory = job.inputFormat.isRawImage
                    ? .rawProcessing
                    : (job.inputFormat.category == .video ? .videoProcessing : (job.inputFormat.category == .image ? .imageDecode : .conversion))
                StructuredDiagnostics.record(
                    category: category,
                    severity: StructuredDiagnostics.severity(for: error),
                    stage: "convert",
                    operationID: job.id.uuidString,
                    filename: job.inputURLs.first?.lastPathComponent,
                    message: "(\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue)): \(error.localizedDescription)"
                )
            }
        } catch {
            guard activeJobs.contains(where: { $0.id == job.id }) else { return }
            jobCompletedTimes[job.id] = Date()
            let convError = ConversionError.unknown(error.localizedDescription)
            jobErrors[job.id] = convError
            jobStatuses[job.id] = .failed(convError)
            logger.error("Conversion failed with unexpected error: \(error.localizedDescription, privacy: .public)")
            StructuredDiagnostics.record(
                category: .conversion,
                severity: .internalError,
                stage: "convertUnexpected",
                operationID: job.id.uuidString,
                filename: job.inputURLs.first?.lastPathComponent,
                message: "(\(job.inputFormat.rawValue) -> \(job.outputFormat.rawValue)): \(error.localizedDescription)"
            )
        }
    }

    func cleanupLateCancelledOutputs(for job: ConversionJob, urls: [URL]) {
        guard job.options.resolvedExistingFileHandling != .overwrite else { return }
        let removable = ConversionQueue.safeUndoableOutputURLs(
            outputURLs: urls,
            protectedSourceURLs: job.inputURLs,
            requireExistsOnDisk: false
        )
        for url in removable {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Safe Move-Originals-to-Trash

    nonisolated static func evaluateTrashEligibility(
        job: ConversionJob,
        status: ConversionJobStatus,
        moveOriginalsToTrashEnabled: Bool,
        isCancelled: Bool = false
    ) -> TrashOriginalEligibility {
        guard moveOriginalsToTrashEnabled else {
            return .skipped("moveOriginalsToTrashAfterSuccess is disabled")
        }
        guard !isCancelled else {
            return .skipped("Job was cancelled")
        }
        guard case .completed(let result) = status else {
            return .skipped("Job did not complete successfully")
        }

        let outputs = result.allOutputURLs
        guard !outputs.isEmpty else {
            return .skipped("No output URLs produced")
        }

        let fm = FileManager.default
        var protectedOutputPaths = Set<String>()
        for outURL in outputs {
            let stdOut = outURL.standardizedFileURL
            let resolvedOut = stdOut.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: stdOut.path, isDirectory: &isDir), !isDir.boolValue else {
                return .skipped("Output file missing or is a directory: \(stdOut.lastPathComponent)")
            }
            let fileSize = (try? fm.attributesOfItem(atPath: stdOut.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else {
                return .skipped("Output file is empty (0 bytes): \(stdOut.lastPathComponent)")
            }
            protectedOutputPaths.insert(stdOut.path)
            protectedOutputPaths.insert(resolvedOut.path)
        }

        var eligibleInputs: [URL] = []
        var seenResolvedInputs = Set<String>()

        for inputURL in job.inputURLs {
            let stdInput = inputURL.standardizedFileURL
            let resolvedInput = stdInput.resolvingSymlinksInPath()
            guard !protectedOutputPaths.contains(stdInput.path),
                  !protectedOutputPaths.contains(resolvedInput.path) else {
                continue
            }
            guard fm.fileExists(atPath: stdInput.path) else {
                continue
            }
            guard seenResolvedInputs.insert(resolvedInput.path).inserted else {
                continue
            }
            eligibleInputs.append(stdInput)
        }

        guard !eligibleInputs.isEmpty else {
            return .skipped("No eligible distinct original input files to trash")
        }
        return .eligible(eligibleInputs)
    }

    private func trashOriginalInputsIfEligible(for job: ConversionJob, status: ConversionJobStatus) {
        let eligibility = Self.evaluateTrashEligibility(
            job: job,
            status: status,
            moveOriginalsToTrashEnabled: settings.moveOriginalsToTrashAfterSuccess,
            isCancelled: Task.isCancelled
        )
        guard case .eligible(let inputURLs) = eligibility else {
            return
        }

        for inputURL in inputURLs {
            do {
                _ = try trashHandler(inputURL)
                lastTrashedInputURLs.append(inputURL)
                logger.info("Moved original input file to Trash: \(inputURL.lastPathComponent, privacy: .private)")
                StructuredDiagnostics.record(
                    category: .fileAccess,
                    severity: .info,
                    stage: "trashOriginal",
                    operationID: job.id.uuidString,
                    filename: inputURL.lastPathComponent,
                    message: "Moved original input file to macOS Trash after verified conversion success"
                )
            } catch {
                let sanitized = ErrorDetailsFormatter.sanitize(error.localizedDescription)
                logger.warning("Failed to move original input file to Trash (\(inputURL.lastPathComponent, privacy: .private)): \(sanitized, privacy: .private)")
                StructuredDiagnostics.record(
                    category: .fileAccess,
                    severity: .validation,
                    stage: "trashOriginal",
                    operationID: job.id.uuidString,
                    filename: inputURL.lastPathComponent,
                    message: "Failed to move original to Trash (left intact): \(sanitized)"
                )
            }
        }
    }
}

