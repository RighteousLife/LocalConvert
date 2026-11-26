import Foundation
import SwiftUI
import OSLog

extension AppState {
    @discardableResult
    @MainActor
    public func executePDFOperation(
        operation: String,
        files: [DroppedFile],
        ranges: String? = nil,
        rotation: Int? = nil,
        password: String? = nil,
        extraOptions: [String: String] = [:]
    ) -> Bool {
        guard !files.isEmpty else { return false }

        let interactive = resolveInteractiveOutputDirectoryIfNeeded()
        if interactive.cancelled {
            return false
        }

        var options = AppSettings.shared.defaultConversionOptions
        for (key, value) in extraOptions {
            options.customOptions[key] = value
        }
        options.customOptions["pdf_operation"] = operation
        if let ranges = ranges, !ranges.isEmpty {
            options.customOptions["pdf_pages"] = ranges
        }
        if let rotation = rotation {
            options.customOptions["pdf_rotation"] = String(rotation)
        }
        if let password = password, !password.isEmpty {
            options.customOptions["pdf_password"] = password
        }
        
        let targetFormat: FileFormat = operation == "pdfToImages" ? .png : .pdf
        isConverting = true
        
        // Multi-file combined operations: merge and imagesToPDF
        if operation == "merge" || operation == "imagesToPDF" {
            let firstFile = files.first!
            let outputDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
                for: firstFile.url,
                preference: outputLocation,
                customDirectory: customOutputDirectory
            )
            
            let job = ConversionJob(
                inputURLs: files.map { $0.url },
                inputFormat: firstFile.detectedFormat ?? .pdf,
                outputFormat: targetFormat,
                outputDirectory: outputDir,
                options: options
            )
            
            conversionQueue.enqueue(job: job)
        } else if files.count == 1 {
            // Single file operation
            let singleFile = files.first!
            let outputDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
                for: singleFile.url,
                preference: outputLocation,
                customDirectory: customOutputDirectory
            )
            
            let job = ConversionJob(
                inputURLs: [singleFile.url],
                inputFormat: singleFile.detectedFormat ?? .pdf,
                outputFormat: targetFormat,
                outputDirectory: outputDir,
                options: options
            )
            
            conversionQueue.enqueue(job: job)
        } else {
            // Batch processing: each file processed individually under a shared batch ID
            let batchID = UUID()
            var batchJobs: [ConversionJob] = []
            
            for file in files {
                let fileOutputDir = interactive.directory ?? OutputManager.resolveOutputDirectory(
                    for: file.url,
                    preference: outputLocation,
                    customDirectory: customOutputDirectory
                )
                
                let job = ConversionJob(
                    inputURLs: [file.url],
                    inputFormat: file.detectedFormat ?? .pdf,
                    outputFormat: targetFormat,
                    outputDirectory: fileOutputDir,
                    options: options,
                    batchID: batchID
                )
                batchJobs.append(job)
            }
            
            conversionQueue.enqueue(jobs: batchJobs)
        }
        return true
    }
}
