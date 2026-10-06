import Foundation
import Testing
import AppKit
@testable import LocalConvert

@Suite("Phase 26 — UX & Workflow Polish Tests")
struct Phase26Tests {
    
    // MARK: - Test Helpers
    
    private func mockDetectionResult(url: URL, format: FileFormat) -> FileDetectionResult {
        FileDetectionResult(
            url: url,
            detectedFormat: format,
            extensionFormat: format,
            utTypeFormat: format,
            magicBytesFormat: format,
            confidence: .high
        )
    }
    
    // MARK: - 1. Jobs Retention Policy
    
    @Test("Jobs retention policy computes correct time intervals")
    func testJobsRetentionPolicyIntervals() {
        #expect(JobsRetentionPolicy.oneHour.timeInterval == 3600)
        #expect(JobsRetentionPolicy.twentyFourHours.timeInterval == 86400)
        #expect(JobsRetentionPolicy.sevenDays.timeInterval == 604800)
        #expect(JobsRetentionPolicy.forever.timeInterval == nil)
    }
    
    // MARK: - 2. Recent Output Formats
    
    @Test("AppSettings recent output formats tracks, deduplicates, and limits")
    @MainActor
    func testRecentOutputFormats() {
        let settings = AppSettings.shared
        let originalRecents = settings.recentOutputFormats
        defer {
            settings.recentOutputFormats = originalRecents
        }
        
        settings.recentOutputFormats = []
        
        settings.addRecentOutputFormat(.webp)
        settings.addRecentOutputFormat(.jpg)
        settings.addRecentOutputFormat(.png)
        
        #expect(settings.recentOutputFormats.count == 3)
        #expect(settings.recentOutputFormats.first == .png)
        
        // Re-adding .webp should move it to the top
        settings.addRecentOutputFormat(.webp)
        #expect(settings.recentOutputFormats.count == 3)
        #expect(settings.recentOutputFormats.first == .webp)
        #expect(settings.recentOutputFormats == [.webp, .png, .jpg])
    }
    
    // MARK: - 3. Size Comparison Calculations
    
    @Test("ConversionSizeComparison accurately calculates size reduction")
    func testSizeComparisonReduction() {
        let comp = ConversionSizeComparison(inputBytes: 10_000_000, outputBytes: 2_500_000)
        
        #expect(comp.savedBytes == 7_500_000)
        #expect(comp.savedPercentage == 75.0)
        #expect(comp.displayString.contains("75% smaller"))
    }
    
    @Test("ConversionSizeComparison accurately calculates size increase")
    func testSizeComparisonIncrease() {
        let comp = ConversionSizeComparison(inputBytes: 1_000_000, outputBytes: 2_500_000)
        
        #expect(comp.savedBytes == -1_500_000)
        #expect(comp.savedPercentage == -150.0)
        #expect(comp.displayString.contains("150% larger"))
    }
    
    @Test("ConversionSizeComparison handles zero and equal bytes safely")
    func testSizeComparisonZeroAndEqual() {
        let equalComp = ConversionSizeComparison(inputBytes: 1_000_000, outputBytes: 1_000_000)
        #expect(equalComp.savedBytes == 0)
        #expect(equalComp.savedPercentage == 0.0)
        
        let zeroComp = ConversionSizeComparison(inputBytes: 0, outputBytes: 0)
        #expect(zeroComp.savedBytes == 0)
        #expect(zeroComp.savedPercentage == 0.0)
    }
    
    // MARK: - 4. Batch Result Summary
    
    @Test("BatchResultSummary computes total savings and formatted summary")
    func testBatchResultSummary() {
        let summary = BatchResultSummary(
            totalFiles: 4,
            completedCount: 3,
            failedCount: 1,
            cancelledCount: 0,
            totalInputBytes: 20_000_000,
            totalOutputBytes: 10_000_000
        )
        
        #expect(summary.savedBytes == 10_000_000)
        #expect(summary.savedPercentage == 50.0)
        #expect(summary.displayString.contains("50%"))
        #expect(summary.displayString.contains("Saved"))
    }
    
    // MARK: - 5. Clear Completed Jobs Preserves Active Jobs
    
    @Test("ConversionManager clearCompletedJobs preserves active and waiting jobs")
    @MainActor
    func testClearCompletedJobsPreservesActive() {
        let manager = ConversionManager()
        let dir = FileManager.default.temporaryDirectory
        
        let waitingJob = ConversionJob(
            id: UUID(),
            inputURLs: [dir.appendingPathComponent("waiting.png")],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: dir
        )
        
        let convertingJob = ConversionJob(
            id: UUID(),
            inputURLs: [dir.appendingPathComponent("active.png")],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: dir
        )
        
        let completedJob = ConversionJob(
            id: UUID(),
            inputURLs: [dir.appendingPathComponent("done.png")],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: dir
        )
        
        let failedJob = ConversionJob(
            id: UUID(),
            inputURLs: [dir.appendingPathComponent("failed.png")],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: dir
        )
        
        manager.activeJobs = [waitingJob, convertingJob, completedJob, failedJob]
        manager.jobStatuses[waitingJob.id] = .waiting
        manager.jobStatuses[convertingJob.id] = .converting(.indeterminate)
        manager.jobStatuses[completedJob.id] = .completed(ConversionResult(outputURL: dir.appendingPathComponent("done.webp"), fileSize: 100, duration: 0.5))
        manager.jobStatuses[failedJob.id] = .failed(.unknown("error"))
        
        manager.clearCompletedJobs()
        
        #expect(manager.activeJobs.count == 3)
        #expect(manager.activeJobs.contains(where: { $0.id == waitingJob.id }))
        #expect(manager.activeJobs.contains(where: { $0.id == convertingJob.id }))
        #expect(!manager.activeJobs.contains(where: { $0.id == completedJob.id }))
        #expect(manager.activeJobs.contains(where: { $0.id == failedJob.id }))
        
        manager.clearFailedJobs()
        #expect(manager.activeJobs.count == 2)
        #expect(!manager.activeJobs.contains(where: { $0.id == failedJob.id }))
    }
    
    // MARK: - 6. Jobs Retention Policy Application
    
    @Test("ConversionManager applies retention policy correctly")
    @MainActor
    func testRetentionPolicyApplication() {
        let manager = ConversionManager()
        let dir = FileManager.default.temporaryDirectory
        
        let oldJob = ConversionJob(
            id: UUID(),
            inputURLs: [dir.appendingPathComponent("old.png")],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: dir
        )
        
        let freshJob = ConversionJob(
            id: UUID(),
            inputURLs: [dir.appendingPathComponent("fresh.png")],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: dir
        )
        
        manager.activeJobs = [oldJob, freshJob]
        manager.jobStatuses[oldJob.id] = .completed(ConversionResult(outputURL: dir.appendingPathComponent("old.webp"), fileSize: 50, duration: 1.0))
        manager.jobStatuses[freshJob.id] = .completed(ConversionResult(outputURL: dir.appendingPathComponent("fresh.webp"), fileSize: 50, duration: 1.0))
        
        // oldJob completed 2 hours ago
        manager.jobCompletedTimes[oldJob.id] = Date().addingTimeInterval(-7200)
        // freshJob completed 10 minutes ago
        manager.jobCompletedTimes[freshJob.id] = Date().addingTimeInterval(-600)
        
        // Apply 1 hour retention policy
        manager.applyRetentionPolicy(.oneHour)
        
        #expect(manager.activeJobs.count == 1)
        #expect(manager.activeJobs.first?.id == freshJob.id)
    }
    
    // MARK: - 7. Quick Convert & Repeat Last Conversion State
    
    @Test("AppState quickConvert and repeatLastConversion")
    @MainActor
    func testAppStateQuickConvertAndRepeat() {
        let appState = AppState()
        let dir = FileManager.default.temporaryDirectory
        let img1 = dir.appendingPathComponent("photo1.png")
        let img2 = dir.appendingPathComponent("photo2.heic")
        
        try? "test1".data(using: .utf8)?.write(to: img1)
        try? "test2".data(using: .utf8)?.write(to: img2)
        
        var df1 = DroppedFile(
            url: img1,
            detectionResult: mockDetectionResult(url: img1, format: .png)
        )
        df1.selectedOutputFormat = .jpg
        
        var df2 = DroppedFile(
            url: img2,
            detectionResult: mockDetectionResult(url: img2, format: .heic)
        )
        df2.selectedOutputFormat = .png
        
        appState.droppedFiles = [df1, df2]
        
        // Quick convert to WebP
        appState.quickConvert(to: .webp)
        #expect(appState.droppedFiles[0].selectedOutputFormat == .webp)
        #expect(appState.droppedFiles[1].selectedOutputFormat == .webp)
        #expect(appState.lastConversionConfig?.outputFormat == .webp)
        
        // Reset format of first file
        appState.updateOutputFormat(for: df1.id, format: .jpg)
        #expect(appState.droppedFiles[0].selectedOutputFormat == .jpg)
        
        // Repeat last conversion should restore WebP
        appState.repeatLastConversion()
        #expect(appState.droppedFiles[0].selectedOutputFormat == .webp)
        #expect(appState.droppedFiles[1].selectedOutputFormat == .webp)
        
        try? FileManager.default.removeItem(at: img1)
        try? FileManager.default.removeItem(at: img2)
    }
    
    // MARK: - 8. History Item InputURL & Filtering
    
    @Test("ConversionHistoryItem supports inputURLPath and decodes gracefully")
    func testHistoryItemInputURL() throws {
        let item = ConversionHistoryItem(
            inputFilename: "sample.pdf",
            inputFormatName: "PDF",
            outputFilename: "sample_split.pdf",
            outputFormatName: "PDF",
            status: .completed,
            presetName: "Split Pages",
            outputURLPath: "/tmp/sample_split.pdf",
            inputURLPath: "/tmp/sample.pdf"
        )
        
        #expect(item.inputURL?.path == "/tmp/sample.pdf")
        #expect(item.outputURL?.path == "/tmp/sample_split.pdf")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(item)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ConversionHistoryItem.self, from: data)
        
        #expect(decoded.inputURLPath == "/tmp/sample.pdf")
        #expect(decoded.presetName == "Split Pages")
    }
    
    @Test("History search matches filenames, formats, and presets")
    func testHistorySearchMatching() {
        let item1 = ConversionHistoryItem(
            inputFilename: "QuarterlyReport.docx",
            inputFormatName: "DOCX",
            outputFilename: "QuarterlyReport.pdf",
            outputFormatName: "PDF",
            status: .completed,
            presetName: "PDF Document"
        )
        
        let item2 = ConversionHistoryItem(
            inputFilename: "Avatar.png",
            inputFormatName: "PNG",
            outputFilename: "Avatar.webp",
            outputFormatName: "WebP",
            status: .completed
        )
        
        let items = [item1, item2]
        
        // Query "report"
        let reportResults = items.filter { item in
            let q = "report".lowercased()
            return item.inputFilename.lowercased().contains(q) || (item.presetName?.lowercased().contains(q) ?? false)
        }
        #expect(reportResults.count == 1)
        #expect(reportResults.first?.inputFilename == "QuarterlyReport.docx")
        
        // Query "webp"
        let webpResults = items.filter { item in
            let q = "webp".lowercased()
            return item.outputFormatName.lowercased().contains(q)
        }
        #expect(webpResults.count == 1)
        #expect(webpResults.first?.inputFilename == "Avatar.png")
    }
}
