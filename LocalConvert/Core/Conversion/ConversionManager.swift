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
    
    init(
        id: UUID = UUID(),
        inputURLs: [URL],
        inputFormat: FileFormat,
        outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions = .default,
        createdAt: Date = Date(),
        batchID: UUID? = nil,
        presetName: String? = nil
    ) {
        self.id = id
        self.inputURLs = inputURLs
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.outputDirectory = outputDirectory
        self.options = options
        self.createdAt = createdAt
        self.batchID = batchID
        self.presetName = presetName ?? options.customOptions["preset_name"] ?? options.preset?.rawValue
    }
    
    var inputURL: URL {
        inputURLs.first!
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

// MARK: - Conversion Size Comparison

struct ConversionSizeComparison: Sendable, Equatable {
    let inputBytes: Int64
    let outputBytes: Int64
    
    var formattedInput: String {
        ByteCountFormatter.string(fromByteCount: inputBytes, countStyle: .file)
    }
    
    var formattedOutput: String {
        ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)
    }
    
    var differenceBytes: Int64 {
        outputBytes - inputBytes
    }
    
    var percentChange: Double {
        guard inputBytes > 0 else { return 0 }
        return (Double(outputBytes) - Double(inputBytes)) / Double(inputBytes) * 100.0
    }
    
    var isSmaller: Bool {
        outputBytes < inputBytes
    }
    
    var isLarger: Bool {
        outputBytes > inputBytes
    }
    
    var formattedSummary: String {
        guard inputBytes > 0 && outputBytes > 0 else { return "" }
        let pct = abs(Int(round(percentChange)))
        if isSmaller {
            return "\(pct)% smaller"
        } else if isLarger {
            return "\(pct)% larger"
        } else {
            return "Same size"
        }
    }
    
    var savedBytes: Int64 {
        inputBytes - outputBytes
    }
    
    var savedPercentage: Double {
        guard inputBytes > 0 else { return 0.0 }
        return (Double(inputBytes - outputBytes) / Double(inputBytes)) * 100.0
    }
    
    var displayString: String {
        formattedFullComparison
    }
    
    var formattedFullComparison: String {
        guard inputBytes > 0 && outputBytes > 0 else { return "" }
        return "\(formattedInput) → \(formattedOutput) (\(formattedSummary))"
    }
}

// MARK: - Batch Result Summary

struct BatchResultSummary: Sendable, Equatable {
    let totalFiles: Int
    let completedCount: Int
    let failedCount: Int
    let cancelledCount: Int
    let totalInputBytes: Int64
    let totalOutputBytes: Int64
    
    var formattedTotalInput: String {
        ByteCountFormatter.string(fromByteCount: totalInputBytes, countStyle: .file)
    }
    
    var formattedTotalOutput: String {
        ByteCountFormatter.string(fromByteCount: totalOutputBytes, countStyle: .file)
    }
    
    var totalSavedBytes: Int64 {
        max(0, totalInputBytes - totalOutputBytes)
    }
    
    var savedBytes: Int64 {
        totalInputBytes - totalOutputBytes
    }
    
    var savedPercentage: Double {
        guard totalInputBytes > 0 else { return 0.0 }
        return (Double(totalInputBytes - totalOutputBytes) / Double(totalInputBytes)) * 100.0
    }
    
    var formattedTotalSaved: String {
        ByteCountFormatter.string(fromByteCount: totalSavedBytes, countStyle: .file)
    }
    
    var savingsPercentage: Int {
        guard totalInputBytes > 0, totalSavedBytes > 0 else { return 0 }
        return Int(round(Double(totalSavedBytes) / Double(totalInputBytes) * 100.0))
    }
    
    var formattedSavingsSummary: String {
        if totalSavedBytes > 0 {
            return "Saved: \(formattedTotalSaved) (\(savingsPercentage)%)"
        } else if totalOutputBytes > totalInputBytes {
            let diff = totalOutputBytes - totalInputBytes
            return "\(ByteCountFormatter.string(fromByteCount: diff, countStyle: .file)) larger"
        } else {
            return "Same size"
        }
    }
    
    var displayString: String {
        formattedSavingsSummary
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
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ConversionManager")
    private let registry: ConversionRegistry
    
    @Published var jobStatuses: [UUID: ConversionJobStatus] = [:]
    @Published var activeJobs: [ConversionJob] = []
    @Published var jobStartedTimes: [UUID: Date] = [:]
    @Published var jobCompletedTimes: [UUID: Date] = [:]
    @Published var jobResults: [UUID: ConversionResult] = [:]
    @Published var jobErrors: [UUID: ConversionError] = [:]
    
    var jobs: [ConversionJob] {
        get { activeJobs }
        set { activeJobs = newValue }
    }
    
    private var tasks: [UUID: Task<Void, Never>] = [:]
    
    init(registry: ConversionRegistry = .shared) {
        self.registry = registry
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
    
    func submit(job: ConversionJob, onComplete: (@MainActor @Sendable (ConversionJobStatus) -> Void)? = nil) {
        if !activeJobs.contains(where: { $0.id == job.id }) {
            activeJobs.append(job)
        }
        jobStatuses[job.id] = .waiting
        
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
        logger.info("Job \(jobId) cancelled")
    }
    
    func cancelAll() {
        for (id, task) in tasks {
            task.cancel()
            jobStatuses[id] = .cancelled
            jobCompletedTimes[id] = Date()
        }
        tasks.removeAll()
    }
    
    func removeJob(id: UUID) {
        cancel(jobId: id)
        activeJobs.removeAll { $0.id == id }
        jobStatuses.removeValue(forKey: id)
        jobStartedTimes.removeValue(forKey: id)
        jobCompletedTimes.removeValue(forKey: id)
        jobResults.removeValue(forKey: id)
        jobErrors.removeValue(forKey: id)
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
        
        activeJobs.removeAll { job in
            guard let completedDate = jobCompletedTimes[job.id] else { return false }
            let status = jobStatuses[job.id]
            
            let shouldRemove: Bool
            switch status {
            case .completed:
                if let cutoff = completedCutoff, completedDate < cutoff {
                    shouldRemove = true
                } else {
                    shouldRemove = false
                }
            case .failed, .cancelled:
                if let cutoff = failedCutoff, completedDate < cutoff {
                    shouldRemove = true
                } else {
                    shouldRemove = false
                }
            default:
                shouldRemove = false
            }
            
            if shouldRemove {
                let id = job.id
                jobStatuses.removeValue(forKey: id)
                jobStartedTimes.removeValue(forKey: id)
                jobCompletedTimes.removeValue(forKey: id)
                jobResults.removeValue(forKey: id)
                jobErrors.removeValue(forKey: id)
                return true
            }
            return false
        }
    }
    
    func applyRetentionPolicy(_ policy: JobsRetentionPolicy) {
        applyRetentionPolicies(completedPolicy: policy)
    }
    
    func sizeComparison(for jobId: UUID) -> ConversionSizeComparison? {
        guard let job = activeJobs.first(where: { $0.id == jobId }) else { return nil }
        guard let result = jobResults[jobId] else { return nil }
        
        let inputBytes = (try? FileManager.default.attributesOfItem(atPath: job.inputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
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
                let inB = (try? FileManager.default.attributesOfItem(atPath: job.inputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
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
            presetName: oldJob.presetName
        )
        
        // Clean up old job record
        removeJob(id: jobId)
        // Enqueue the new job through the existing queue
        queue.enqueue(job: newJob)
        return newJob
    }
    
    // MARK: - Output File Naming
    
    nonisolated static func outputURL(for inputURL: URL, format: FileFormat, in directory: URL) -> URL {
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let ext = format.fileExtension
        var outputURL = directory.appendingPathComponent("\(baseName).\(ext)")
        
        // Safe collision handling
        var counter = 1
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: outputURL.path) {
            outputURL = directory.appendingPathComponent("\(baseName) (\(counter)).\(ext)")
            counter += 1
        }
        
        return outputURL
    }
    
    nonisolated static func multiPageOutputURL(
        for inputURL: URL,
        pageIndex: Int,
        totalPages: Int,
        format: FileFormat,
        in directory: URL
    ) -> URL {
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let ext = format.fileExtension
        let pageSuffix = totalPages > 1 ? "-\(pageIndex + 1)" : ""
        var outputURL = directory.appendingPathComponent("\(baseName)\(pageSuffix).\(ext)")
        
        var counter = 1
        let fileManager = FileManager.default
        while fileManager.fileExists(atPath: outputURL.path) {
            outputURL = directory.appendingPathComponent("\(baseName)\(pageSuffix) (\(counter)).\(ext)")
            counter += 1
        }
        
        return outputURL
    }
    
    // MARK: - Private
    
    private func executeJob(
        _ job: ConversionJob,
        onComplete: (@MainActor @Sendable (ConversionJobStatus) -> Void)? = nil
    ) async {
        defer {
            if let status = jobStatuses[job.id] {
                // Record history only if enabled
                if AppSettings.shared.saveConversionHistory {
                    let historyStatus: HistoryStatus
                    var outputSizeBytes: Int64? = nil
                    var outputURLPath: String? = nil
                    var duration: TimeInterval? = nil
                    var errorMsg: String? = nil
                    
                    switch status {
                    case .completed(let result):
                        historyStatus = .completed
                        outputSizeBytes = result.fileSize
                        outputURLPath = result.outputURL.path
                        duration = result.duration
                    case .failed(let err):
                        historyStatus = .failed
                        errorMsg = ErrorDetailsFormatter.sanitize(err.localizedDescription)
                    case .cancelled:
                        historyStatus = .cancelled
                    default:
                        historyStatus = .failed // Fallback if interrupted
                    }
                    
                    let inputSize = (try? FileManager.default.attributesOfItem(atPath: job.inputURLs.first!.path)[.size] as? NSNumber)?.int64Value
                    
                    let historyItem = ConversionHistoryItem(
                        id: UUID(),
                        inputFilename: job.inputURLs.first!.lastPathComponent,
                        inputFormatName: job.inputFormat.displayName,
                        outputFilename: outputURLPath != nil ? URL(fileURLWithPath: outputURLPath!).lastPathComponent : "\(job.inputURLs.first!.deletingPathExtension().lastPathComponent).\(job.outputFormat.fileExtension)",
                        outputFormatName: job.outputFormat.displayName,
                        date: Date(),
                        status: historyStatus,
                        inputSizeBytes: inputSize,
                        outputSizeBytes: outputSizeBytes,
                        presetName: job.options.customOptions["preset_name"] ?? job.options.preset?.rawValue,
                        outputURLPath: outputURLPath,
                        inputURLPath: job.inputURLs.first?.path,
                        duration: duration,
                        errorMessage: errorMsg
                    )
                    
                    HistoryManager.shared.addEntry(historyItem)
                }
                onComplete?(status)
            }
        }
        
        guard !Task.isCancelled else {
            jobStatuses[job.id] = .cancelled
            return
        }
        
        // Find engine
        guard let engine = registry.findEngine(from: job.inputFormat, to: job.outputFormat, options: job.options) else {
            jobStatuses[job.id] = .failed(.unsupportedConversion(from: job.inputFormat, to: job.outputFormat))
            return
        }
        
        // Check engine availability
        guard await engine.isAvailable() else {
            jobStatuses[job.id] = .failed(.engineNotAvailable(engine.name))
            return
        }
        
        // Check input file exists
        guard FileManager.default.fileExists(atPath: job.inputURLs.first!.path) else {
            jobStatuses[job.id] = .failed(.inputFileNotFound(job.inputURLs.first!))
            return
        }
        
        // Start conversion
        jobStartedTimes[job.id] = Date()
        jobStatuses[job.id] = .converting(.indeterminate)
        logger.info("Conversion started - Engine: \(engine.name, privacy: .public) Input: \(job.inputFormat.rawValue, privacy: .public) Output: \(job.outputFormat.rawValue, privacy: .public)")
        
        do {
            let result = try await engine.convert(
                inputs: job.inputURLs,
                to: job.outputFormat,
                outputDirectory: job.outputDirectory,
                options: job.options,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.jobStatuses[job.id] = .converting(progress)
                    }
                }
            )
            
            jobCompletedTimes[job.id] = Date()
            
            guard !Task.isCancelled else {
                jobStatuses[job.id] = .cancelled
                // Clean up partial output files
                for url in result.allOutputURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                return
            }
            
            // Save last used directory
            OutputManager.lastUsedDirectory = result.outputURL.deletingLastPathComponent()
            
            jobResults[job.id] = result
            jobStatuses[job.id] = .completed(result)
            logger.info("Conversion completed - Duration: \(result.duration, privacy: .public)s")
        } catch is CancellationError {
            jobCompletedTimes[job.id] = Date()
            jobStatuses[job.id] = .cancelled
        } catch let error as ConversionError {
            jobCompletedTimes[job.id] = Date()
            jobErrors[job.id] = error
            jobStatuses[job.id] = .failed(error)
            logger.error("Conversion failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            jobCompletedTimes[job.id] = Date()
            let convError = ConversionError.unknown(error.localizedDescription)
            jobErrors[job.id] = convError
            jobStatuses[job.id] = .failed(convError)
            logger.error("Conversion failed with unexpected error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Error Details Formatter

struct ErrorDetailsFormatter: Sendable {
    static func format(
        job: ConversionJob,
        error: ConversionError
    ) -> String {
        format(
            inputFilename: job.inputFilename,
            inputFormat: job.inputFormat.displayName,
            outputFormat: job.outputFormat.displayName,
            error: error,
            jobID: job.id
        )
    }
    
    static func format(
        inputFilename: String,
        inputFormat: String,
        outputFormat: String,
        error: ConversionError,
        jobID: UUID? = nil
    ) -> String {
        let userMessage = sanitize(error.errorDescription ?? error.localizedDescription)
        let technicalDetails: String
        
        switch error {
        case .engineExecutionFailed(_, let underlyingError):
            technicalDetails = sanitize(underlyingError ?? "None")
        case .unsupportedConversion(let from, let to):
            technicalDetails = "No conversion engine registered for route \(from.rawValue) → \(to.rawValue)"
        case .engineNotAvailable(let engine):
            technicalDetails = "Engine '\(engine)' is not installed or available on this system."
        case .inputFileNotFound(let url):
            technicalDetails = "Input file path: \(url.path)"
        case .outputDirectoryNotWritable(let dir):
            technicalDetails = "Output directory not writable: \(dir.path)"
        default:
            technicalDetails = "None"
        }
        
        let lines = [
            "--- LocalConvert Error Report ---",
            jobID != nil ? "Job ID: \(jobID!.uuidString)" : nil,
            "Input: \(inputFilename)",
            "Conversion: \(inputFormat) → \(outputFormat)",
            "Status: Failed",
            "Error: \(userMessage)",
            "Technical Details: \(technicalDetails)",
            "----------------------------------"
        ].compactMap { $0 }
        
        return lines.joined(separator: "\n")
    }
    
    /// Sanitizes secret strings like passwords or credentials from error logs
    static func sanitize(_ text: String) -> String {
        var result = text
        let patterns = [
            ("password=[^\\s&]+", "password=[REDACTED]"),
            ("pwd=[^\\s&]+", "pwd=[REDACTED]"),
            ("secret=[^\\s&]+", "secret=[REDACTED]"),
            ("key=[^\\s&]+", "key=[REDACTED]")
        ]
        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(location: 0, length: result.utf16.count),
                    withTemplate: template
                )
            }
        }
        return result
    }
}

