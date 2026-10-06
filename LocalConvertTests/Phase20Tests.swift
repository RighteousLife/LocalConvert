import Testing
import Foundation
import SwiftUI
@testable import LocalConvert

@Suite("Phase 20 - Jobs Center, Queue UX, Menu Bar & macOS App Shell")
struct Phase20Tests {
    
    // MARK: - 1. Job Lifecycle & Status Properties
    
    @Test("ConversionJob has unique UUID and initial status in ConversionManager")
    @MainActor
    func testJobInitialization() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample.png")
        let job1 = ConversionJob(
            inputURLs: [dummyURL],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            presetName: nil
        )
        let job2 = ConversionJob(
            inputURLs: [dummyURL],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            presetName: nil
        )
        
        #expect(job1.id != job2.id)
        #expect(job1.sourceFormat == .png)
        #expect(job1.outputFormat == .jpg)
        #expect(job1.sourceFilename == "sample.png")
        #expect(job1.batchID == nil)
        #expect(job1.presetName == nil)
        
        let manager = ConversionManager()
        #expect(manager.status(for: job1.id) == .waiting)
        #expect(manager.status(for: job1.id).isActive == true)
        #expect(manager.status(for: job1.id).isTerminal == false)
    }
    
    @Test("ConversionJobStatus helper properties accurately reflect state")
    func testJobStatusHelpers() {
        let waiting = ConversionJobStatus.waiting
        #expect(waiting.isActive == true)
        #expect(waiting.isTerminal == false)
        #expect(waiting.progressFraction == 0.0)
        #expect(waiting.progressMessage == "Queued")
        #expect(waiting.displayTitle == "Queued")
        
        let converting = ConversionJobStatus.converting(.determinate(0.65, message: "Encoding..."))
        #expect(converting.isActive == true)
        #expect(converting.isTerminal == false)
        #expect(converting.progressFraction == 0.65)
        #expect(converting.progressMessage == "Encoding...")
        #expect(converting.displayTitle == "Converting")
        
        let completed = ConversionJobStatus.completed(ConversionResult(outputURL: URL(fileURLWithPath: "/tmp/out.jpg")))
        #expect(completed.isActive == false)
        #expect(completed.isTerminal == true)
        #expect(completed.progressFraction == 1.0)
        #expect(completed.progressMessage == "Completed")
        #expect(completed.displayTitle == "Completed")
        
        let failed = ConversionJobStatus.failed(.engineExecutionFailed("Corrupt file", underlyingError: nil))
        #expect(failed.isActive == false)
        #expect(failed.isTerminal == true)
        #expect(failed.progressFraction == 0.0)
        #expect(failed.progressMessage == "Conversion failed: Corrupt file")
        #expect(failed.displayTitle == "Failed")
        
        let cancelled = ConversionJobStatus.cancelled
        #expect(cancelled.isActive == false)
        #expect(cancelled.isTerminal == true)
        #expect(cancelled.progressFraction == 0.0)
        #expect(cancelled.progressMessage == "Cancelled")
        #expect(cancelled.displayTitle == "Cancelled")
    }
    
    // MARK: - 2. ConversionManager Queue Queries & State
    
    @Test("ConversionManager correctly filters jobs by status")
    @MainActor
    func testConversionManagerQueueQueries() {
        let manager = ConversionManager()
        let dummyURL = URL(fileURLWithPath: "/tmp/test.jpg")
        
        let jobWaiting = ConversionJob(inputURLs: [dummyURL], inputFormat: .jpg, outputFormat: .png, outputDirectory: URL(fileURLWithPath: "/tmp"))
        let jobRunning = ConversionJob(inputURLs: [dummyURL], inputFormat: .jpg, outputFormat: .webp, outputDirectory: URL(fileURLWithPath: "/tmp"))
        let jobDone = ConversionJob(inputURLs: [dummyURL], inputFormat: .jpg, outputFormat: .pdf, outputDirectory: URL(fileURLWithPath: "/tmp"))
        let jobFailed = ConversionJob(inputURLs: [dummyURL], inputFormat: .jpg, outputFormat: .tiff, outputDirectory: URL(fileURLWithPath: "/tmp"))
        let jobCancelled = ConversionJob(inputURLs: [dummyURL], inputFormat: .jpg, outputFormat: .gif, outputDirectory: URL(fileURLWithPath: "/tmp"))
        
        manager.jobs = [jobWaiting, jobRunning, jobDone, jobFailed, jobCancelled]
        manager.jobStatuses[jobWaiting.id] = .waiting
        manager.jobStatuses[jobRunning.id] = .converting(.determinate(0.5, message: "Processing"))
        manager.jobStatuses[jobDone.id] = .completed(ConversionResult(outputURL: URL(fileURLWithPath: "/tmp/test.pdf")))
        manager.jobStatuses[jobFailed.id] = .failed(.engineExecutionFailed("Encoder error", underlyingError: nil))
        manager.jobStatuses[jobCancelled.id] = .cancelled
        
        #expect(manager.queuedJobs.count == 1)
        #expect(manager.queuedJobs.first?.id == jobWaiting.id)
        
        #expect(manager.runningJobs.count == 1)
        #expect(manager.runningJobs.first?.id == jobRunning.id)
        
        #expect(manager.completedJobs.count == 1)
        #expect(manager.completedJobs.first?.id == jobDone.id)
        
        #expect(manager.failedJobs.count == 1)
        #expect(manager.failedJobs.first?.id == jobFailed.id)
        
        #expect(manager.cancelledJobs.count == 1)
        #expect(manager.cancelledJobs.first?.id == jobCancelled.id)
        
        #expect(manager.runningOrWaitingCount == 2)
    }
    
    // MARK: - 3. Job Removal & Retry
    
    @Test("ConversionManager removeJob clears job and associated status/metadata")
    @MainActor
    func testRemoveJob() {
        let manager = ConversionManager()
        let dummyURL = URL(fileURLWithPath: "/tmp/remove-test.jpg")
        let job = ConversionJob(inputURLs: [dummyURL], inputFormat: .jpg, outputFormat: .png, outputDirectory: URL(fileURLWithPath: "/tmp"))
        
        manager.jobs = [job]
        manager.jobStatuses[job.id] = .completed(ConversionResult(outputURL: URL(fileURLWithPath: "/tmp/remove-test.png")))
        manager.jobStartedTimes[job.id] = Date()
        manager.jobCompletedTimes[job.id] = Date()
        manager.jobResults[job.id] = ConversionResult(outputURL: URL(fileURLWithPath: "/tmp/remove-test.png"))
        
        #expect(manager.jobs.count == 1)
        manager.removeJob(id: job.id)
        #expect(manager.jobs.isEmpty)
        #expect(manager.jobStatuses[job.id] == nil)
        #expect(manager.jobStartedTimes[job.id] == nil)
        #expect(manager.jobCompletedTimes[job.id] == nil)
        #expect(manager.jobResults[job.id] == nil)
    }
    
    @Test("ConversionManager retry creates new job with fresh UUID preserving parameters")
    @MainActor
    func testRetryJobSemantics() {
        let manager = ConversionManager()
        let queue = ConversionQueue(conversionManager: manager)
        let dummyURL = URL(fileURLWithPath: "/tmp/retry-input.png")
        var options = ConversionOptions()
        options.imageQuality = 0.85
        let batchID = UUID()
        
        let originalJob = ConversionJob(
            inputURLs: [dummyURL],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            options: options,
            batchID: batchID,
            presetName: "Web Compress"
        )
        
        manager.jobs = [originalJob]
        manager.jobStatuses[originalJob.id] = .failed(.engineExecutionFailed("Network/Disk Error", underlyingError: nil))
        
        let retriedJob = manager.retry(jobId: originalJob.id, using: queue)
        
        #expect(retriedJob != nil)
        guard let newJob = retriedJob else { return }
        
        #expect(newJob.id != originalJob.id)
        #expect(newJob.inputURLs == originalJob.inputURLs)
        #expect(newJob.outputFormat == originalJob.outputFormat)
        #expect(newJob.options.imageQuality == 0.85)
        #expect(newJob.batchID == batchID)
        #expect(newJob.presetName == "Web Compress")
        #expect(newJob.sourceFormat == .png)
        #expect(newJob.sourceFilename == "retry-input.png")
    }
    
    // MARK: - 4. Batch Grouping & Aggregation
    
    @Test("Batch grouping calculates aggregate stats correctly")
    @MainActor
    func testBatchAggregation() {
        let batchID = UUID()
        let file1 = URL(fileURLWithPath: "/tmp/doc1.pdf")
        let file2 = URL(fileURLWithPath: "/tmp/doc2.pdf")
        let file3 = URL(fileURLWithPath: "/tmp/doc3.pdf")
        
        let job1 = ConversionJob(inputURLs: [file1], inputFormat: .pdf, outputFormat: .docx, outputDirectory: URL(fileURLWithPath: "/tmp"), batchID: batchID, presetName: "Docx Export")
        let job2 = ConversionJob(inputURLs: [file2], inputFormat: .pdf, outputFormat: .docx, outputDirectory: URL(fileURLWithPath: "/tmp"), batchID: batchID, presetName: "Docx Export")
        let job3 = ConversionJob(inputURLs: [file3], inputFormat: .pdf, outputFormat: .docx, outputDirectory: URL(fileURLWithPath: "/tmp"), batchID: batchID, presetName: "Docx Export")
        
        let jobs = [job1, job2, job3]
        
        #expect(jobs.allSatisfy { $0.batchID == batchID })
        #expect(jobs.allSatisfy { $0.presetName == "Docx Export" })
        
        let manager = ConversionManager()
        manager.jobs = jobs
        manager.jobStatuses[job1.id] = .completed(ConversionResult(outputURL: URL(fileURLWithPath: "/tmp/doc1.docx")))
        manager.jobStatuses[job2.id] = .failed(.engineExecutionFailed("Format error", underlyingError: nil))
        manager.jobStatuses[job3.id] = .converting(.determinate(0.5, message: "Converting"))
        
        let batch = BatchGroup(id: batchID, jobs: jobs)
        
        #expect(batch.totalCount == 3)
        #expect(batch.completedCount(manager: manager) == 1)
        #expect(batch.failedCount(manager: manager) == 1)
        #expect(batch.runningCount(manager: manager) == 1)
        #expect(batch.isAllCompleted(manager: manager) == false)
    }
    
    // MARK: - 5. AppNavigationTab & AppSettings
    
    @Test("AppNavigationTab covers all 7 primary app sections")
    func testAppNavigationTabCases() {
        let allTabs = AppNavigationTab.allCases
        #expect(allTabs.count == 7)
        #expect(allTabs.contains(.convert))
        #expect(allTabs.contains(.jobs))
        #expect(allTabs.contains(.pdfToolbox))
        #expect(allTabs.contains(.metadata))
        #expect(allTabs.contains(.presets))
        #expect(allTabs.contains(.history))
        #expect(allTabs.contains(.settings))
    }
    
    @Test("AppSettings showMenuBarExtra default is true and resets properly")
    @MainActor
    func testAppSettingsMenuBarExtra() {
        let settings = AppSettings.shared
        settings.showMenuBarExtra = false
        #expect(settings.showMenuBarExtra == false)
        
        settings.resetToDefaults()
        #expect(settings.showMenuBarExtra == true)
    }
    
    // MARK: - 6. macOS Retina AppIcon Audit
    
    @Test("AppIcon.icns exists and has full multi-representation size (> 1MB)")
    func testAppIconIntegrity() {
        let currentFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = currentFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let sourceIconURL = projectRoot.appendingPathComponent("LocalConvert/Resources/AppIcon.icns")
        
        #expect(FileManager.default.fileExists(atPath: sourceIconURL.path))
        
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceIconURL.path),
              let fileSize = attributes[.size] as? Int64 else {
            Issue.record("Could not read AppIcon.icns file size")
            return
        }
        
        // Full 10-representation Retina icns is ~1.56 MB (1,563,338 bytes), significantly larger than minimal 87 KB placeholder
        #expect(fileSize > 1_000_000, "AppIcon.icns must contain full Retina representations, size was \(fileSize) bytes")
    }
    
    @Test("Info.plist contains CFBundleIconFile set to AppIcon")
    func testInfoPlistIconConfiguration() {
        let currentFileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = currentFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let infoPlistURL = projectRoot.appendingPathComponent("LocalConvert/Info.plist")
        
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            Issue.record("Could not read Info.plist")
            return
        }
        
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
    }
}
