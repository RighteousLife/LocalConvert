import Foundation
import os.log

// MARK: - Conversion Job

struct ConversionJob: Identifiable, Sendable {
    let id: UUID
    let inputURL: URL
    let inputFormat: FileFormat
    let outputFormat: FileFormat
    let outputDirectory: URL
    let options: ConversionOptions
    let createdAt: Date
    
    init(
        inputURL: URL,
        inputFormat: FileFormat,
        outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions = .default
    ) {
        self.id = UUID()
        self.inputURL = inputURL
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.outputDirectory = outputDirectory
        self.options = options
        self.createdAt = Date()
    }
}

// MARK: - Conversion Job Status

enum ConversionJobStatus: Sendable {
    case waiting
    case converting(ConversionProgress)
    case completed(ConversionResult)
    case failed(ConversionError)
    case cancelled
}

// MARK: - Conversion Manager

@MainActor
final class ConversionManager: ObservableObject {
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ConversionManager")
    private let registry: ConversionRegistry
    
    @Published private(set) var jobStatuses: [UUID: ConversionJobStatus] = [:]
    @Published private(set) var activeJobs: [ConversionJob] = []
    
    private var tasks: [UUID: Task<Void, Never>] = [:]
    
    init(registry: ConversionRegistry = .shared) {
        self.registry = registry
    }
    
    // MARK: - Job Management
    
    func submit(job: ConversionJob, onComplete: (@Sendable (ConversionJobStatus) -> Void)? = nil) {
        activeJobs.append(job)
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
        logger.info("Job cancelled")
    }
    
    func cancelAll() {
        for (id, task) in tasks {
            task.cancel()
            jobStatuses[id] = .cancelled
        }
        tasks.removeAll()
    }
    
    func clearCompleted() {
        activeJobs.removeAll { job in
            switch jobStatuses[job.id] {
            case .completed, .failed, .cancelled:
                jobStatuses.removeValue(forKey: job.id)
                return true
            default:
                return false
            }
        }
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
        onComplete: (@Sendable (ConversionJobStatus) -> Void)? = nil
    ) async {
        defer {
            if let status = jobStatuses[job.id] {
                onComplete?(status)
            }
        }
        
        guard !Task.isCancelled else {
            jobStatuses[job.id] = .cancelled
            return
        }
        
        // Find engine
        guard let engine = registry.findEngine(from: job.inputFormat, to: job.outputFormat) else {
            jobStatuses[job.id] = .failed(.unsupportedConversion(from: job.inputFormat, to: job.outputFormat))
            return
        }
        
        // Check engine availability
        guard await engine.isAvailable() else {
            jobStatuses[job.id] = .failed(.engineNotAvailable(engine.name))
            return
        }
        
        // Check input file exists
        guard FileManager.default.fileExists(atPath: job.inputURL.path) else {
            jobStatuses[job.id] = .failed(.inputFileNotFound(job.inputURL))
            return
        }
        
        // Start conversion
        jobStatuses[job.id] = .converting(.indeterminate)
        logger.info("Conversion started - Engine: \(engine.name, privacy: .public) Input: \(job.inputFormat.rawValue, privacy: .public) Output: \(job.outputFormat.rawValue, privacy: .public)")
        
        do {
            let result = try await engine.convert(
                input: job.inputURL,
                to: job.outputFormat,
                outputDirectory: job.outputDirectory,
                options: job.options,
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.jobStatuses[job.id] = .converting(progress)
                    }
                }
            )
            
            guard !Task.isCancelled else {
                jobStatuses[job.id] = .cancelled
                // Clean up partial output files
                for url in result.allOutputURLs {
                    try? FileManager.default.removeItem(at: url)
                }
                return
            }
            
            jobStatuses[job.id] = .completed(result)
            logger.info("Conversion completed - Duration: \(result.duration, privacy: .public)s")
        } catch is CancellationError {
            jobStatuses[job.id] = .cancelled
        } catch let error as ConversionError {
            jobStatuses[job.id] = .failed(error)
            logger.error("Conversion failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            jobStatuses[job.id] = .failed(.unknown(error.localizedDescription))
            logger.error("Conversion failed with unexpected error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
