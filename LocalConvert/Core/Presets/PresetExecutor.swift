import Foundation
import os.log

// MARK: - Preset Execution Report

struct PresetExecutionReport: Sendable {
    let preset: SavedPreset
    let enqueuedJobs: [ConversionJob]
    let skippedURLs: [(url: URL, reason: String)]
    
    var totalCount: Int { enqueuedJobs.count + skippedURLs.count }
    var successEnqueuedCount: Int { enqueuedJobs.count }
    var skippedCount: Int { skippedURLs.count }
    
    var isCompleteSuccess: Bool { skippedURLs.isEmpty && !enqueuedJobs.isEmpty }
}

// MARK: - Preset Executor (Headless & UI-Independent)

struct PresetExecutor: Sendable {
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "PresetExecutor")
    private let validator = PresetValidator()
    
    init() {}
    
    /// Executes a preset on a list of input URLs, generating and enqueueing ConversionJobs.
    /// This method has zero dependency on SwiftUI and is fully reusable for Watch Folders, CLI, or UI workflows.
    @MainActor
    @discardableResult
    func execute(
        preset: SavedPreset,
        inputURLs: [URL],
        conversionManager: ConversionManager,
        conversionQueue: ConversionQueue,
        destinationOverride: URL? = nil,
        defaultOutputLocation: OutputLocation = .sameFolder,
        customOutputDirectory: URL? = nil,
        fileDetector: FileDetector = FileDetector(),
        registry: ConversionRegistry = .shared
    ) -> PresetExecutionReport {
        let validation = validator.validateBatch(
            preset: preset,
            urls: inputURLs,
            fileDetector: fileDetector,
            registry: registry
        )
        
        var jobs: [ConversionJob] = []
        let batchID = validation.compatibleURLs.count > 1 ? UUID() : nil
        
        for url in validation.compatibleURLs {
            let detection = fileDetector.detect(url: url)
            guard let inputFormat = detection.bestFormat else { continue }
            
            // Resolve output directory
            let outputDir: URL
            if let override = destinationOverride {
                outputDir = override
            } else {
                switch preset.outputDestinationPolicy {
                case .customDirectory(let path):
                    outputDir = URL(fileURLWithPath: path)
                case .sameAsInput:
                    outputDir = url.deletingLastPathComponent()
                case .defaultLocation:
                    outputDir = OutputManager.resolveOutputDirectory(
                        for: url,
                        preference: defaultOutputLocation,
                        customDirectory: customOutputDirectory
                    )
                }
            }
            
            // Ensure output directory exists and is writable
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            
            // Prepare options with preset metadata
            var jobOptions = preset.options
            jobOptions.customOptions["preset_name"] = preset.name
            
            switch preset.outputNamingPolicy {
            case .addSuffix(let suffix):
                jobOptions.customOptions["output_suffix"] = suffix
            case .addPrefix(let prefix):
                jobOptions.customOptions["output_prefix"] = prefix
            case .standard:
                break
            }
            
            let job = ConversionJob(
                inputURLs: [url],
                inputFormat: inputFormat,
                outputFormat: preset.targetFormat,
                outputDirectory: outputDir,
                options: jobOptions,
                batchID: batchID,
                presetName: preset.name
            )
            
            jobs.append(job)
        }
        
        if !jobs.isEmpty {
            conversionQueue.enqueue(jobs: jobs)
            logger.info("Enqueued \(jobs.count, privacy: .public) jobs for preset '\(preset.name, privacy: .public)' (target: \(preset.targetFormat.displayName, privacy: .public))")
        }
        
        return PresetExecutionReport(
            preset: preset,
            enqueuedJobs: jobs,
            skippedURLs: validation.incompatibleURLs
        )
    }
}
