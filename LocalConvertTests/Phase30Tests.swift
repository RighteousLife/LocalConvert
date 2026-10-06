import Testing
import Foundation
import AppKit
@testable import LocalConvert

@Suite("Phase 30 — Final UX & Settings Polish Tests")
struct Phase30Tests {
    
    // MARK: - 1. Output Location & Resolution
    
    @Test("OutputLocation cases and values")
    func testOutputLocationEnum() {
        #expect(OutputLocation.sameFolder.rawValue == "Same folder as original")
        #expect(OutputLocation.lastUsedFolder.rawValue == "Last used folder")
        #expect(OutputLocation.askEveryTime.rawValue == "Ask every time")
        #expect(OutputLocation.customFolder.rawValue == "Choose output folder")
    }
    
    @Test("OutputManager resolves sameFolder location")
    func testOutputManagerSameFolderResolution() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputFile = tempDir.appendingPathComponent("sample.png")
        try? "test".data(using: .utf8)?.write(to: inputFile)
        
        let resolved = OutputManager.resolveOutputDirectory(
            for: inputFile,
            preference: .sameFolder
        )
        #expect(resolved.path == tempDir.path)
    }
    
    @Test("OutputManager resolves lastUsedFolder location")
    func testOutputManagerLastUsedFolderResolution() {
        let tempDir1 = FileManager.default.temporaryDirectory.appendingPathComponent("lastUsed-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir1) }
        
        OutputManager.lastUsedDirectory = tempDir1
        
        let tempDir2 = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir2) }
        let inputFile = tempDir2.appendingPathComponent("sample.jpg")
        try? "test".data(using: .utf8)?.write(to: inputFile)
        
        let resolved = OutputManager.resolveOutputDirectory(
            for: inputFile,
            preference: .lastUsedFolder
        )
        #expect(resolved.path == tempDir1.path)
    }
    
    @Test("OutputManager resolves custom folder location")
    func testOutputManagerCustomFolderResolution() {
        let customDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: customDir) }
        
        let inputDir = FileManager.default.temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: inputDir) }
        let inputFile = inputDir.appendingPathComponent("document.pdf")
        
        let resolved = OutputManager.resolveOutputDirectory(
            for: inputFile,
            preference: .customFolder,
            customDirectory: customDir
        )
        #expect(resolved.path == customDir.path)
    }
    
    // MARK: - 2. Retention Policies
    
    @Test("FailedJobsRetentionPolicy time intervals and raw values")
    func testFailedJobsRetentionPolicy() {
        #expect(FailedJobsRetentionPolicy.oneHour.timeInterval == 3600)
        #expect(FailedJobsRetentionPolicy.twentyFourHours.timeInterval == 86400)
        #expect(FailedJobsRetentionPolicy.sevenDays.timeInterval == 604800)
        #expect(FailedJobsRetentionPolicy.forever.timeInterval == nil)
    }
    
    @Test("JobsRetentionPolicy time intervals and raw values")
    func testJobsRetentionPolicy() {
        #expect(JobsRetentionPolicy.oneHour.timeInterval == 3600)
        #expect(JobsRetentionPolicy.twentyFourHours.timeInterval == 86400)
        #expect(JobsRetentionPolicy.sevenDays.timeInterval == 604800)
        #expect(JobsRetentionPolicy.forever.timeInterval == nil)
    }
    
    @Test("ConversionManager applyRetentionPolicies purges expired jobs")
    @MainActor
    func testConversionManagerRetentionPolicies() {
        let manager = ConversionManager()
        let outDir = FileManager.default.temporaryDirectory
        
        let job1 = ConversionJob(
            id: UUID(),
            inputURLs: [URL(fileURLWithPath: "/tmp/old_completed.png")],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: outDir
        )
        let job2 = ConversionJob(
            id: UUID(),
            inputURLs: [URL(fileURLWithPath: "/tmp/recent_completed.png")],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: outDir
        )
        let job3 = ConversionJob(
            id: UUID(),
            inputURLs: [URL(fileURLWithPath: "/tmp/old_failed.png")],
            inputFormat: .png,
            outputFormat: .webp,
            outputDirectory: outDir
        )
        
        manager.jobs = [job1, job2, job3]
        
        // Mark job1 as completed 2 hours ago
        manager.jobStatuses[job1.id] = .completed(ConversionResult(outputURL: URL(fileURLWithPath: "/tmp/old_completed.webp"), fileSize: 100, duration: 1.0))
        manager.jobCompletedTimes[job1.id] = Date().addingTimeInterval(-7200)
        
        // Mark job2 as completed 10 minutes ago
        manager.jobStatuses[job2.id] = .completed(ConversionResult(outputURL: URL(fileURLWithPath: "/tmp/recent_completed.webp"), fileSize: 100, duration: 1.0))
        manager.jobCompletedTimes[job2.id] = Date().addingTimeInterval(-600)
        
        // Mark job3 as failed 2 hours ago
        manager.jobStatuses[job3.id] = .failed(.engineExecutionFailed("Test failure", underlyingError: nil))
        manager.jobCompletedTimes[job3.id] = Date().addingTimeInterval(-7200)
        
        // Apply 1 hour retention for completed, forever for failed
        manager.applyRetentionPolicies(completedPolicy: .oneHour, failedPolicy: .forever)
        
        // job1 should be pruned, job2 and job3 should remain
        #expect(manager.activeJobs.contains(where: { $0.id == job1.id }) == false)
        #expect(manager.activeJobs.contains(where: { $0.id == job2.id }) == true)
        #expect(manager.activeJobs.contains(where: { $0.id == job3.id }) == true)
        
        // Clear failed jobs
        manager.clearFailedJobs()
        #expect(manager.activeJobs.contains(where: { $0.id == job3.id }) == false)
        #expect(manager.activeJobs.contains(where: { $0.id == job2.id }) == true)
    }
    
    // MARK: - 3. After Conversion Action
    
    @Test("AfterConversionAction enum values and labels")
    func testAfterConversionActionEnum() {
        #expect(AfterConversionAction.doNothing.rawValue == "Do Nothing")
        #expect(AfterConversionAction.revealInFinder.rawValue == "Reveal in Finder")
        #expect(AfterConversionAction.openOutputFile.rawValue == "Open Output File")
        #expect(AfterConversionAction.openOutputFolder.rawValue == "Open Output Folder")
        
        #expect(AfterConversionAction.allCases.count == 4)
    }
    
    // MARK: - 4. Error Sanitization & Technical Formatter
    
    @Test("ErrorDetailsFormatter sanitizes sensitive credentials")
    func testErrorDetailsFormatterSanitization() {
        let input = "Conversion failed for /path/to/file.pdf: password=superSecretPassword123 & token=abc987654 key=SECRET_KEY"
        let sanitized = ErrorDetailsFormatter.sanitize(input)
        
        #expect(!sanitized.contains("superSecretPassword123"))
        #expect(sanitized.contains("password=[REDACTED]"))
        #expect(!sanitized.contains("SECRET_KEY"))
        #expect(sanitized.contains("key=[REDACTED]"))
    }
    
    @Test("ErrorDetailsFormatter formats job error details structure")
    func testErrorDetailsFormatterFormatting() {
        let job = ConversionJob(
            id: UUID(),
            inputURLs: [URL(fileURLWithPath: "/Users/test/Documents/protected.pdf")],
            inputFormat: .pdf,
            outputFormat: .docx,
            outputDirectory: URL(fileURLWithPath: "/Users/test/Documents")
        )
        let error = ConversionError.engineExecutionFailed("Password required", underlyingError: "exit code 1, pwd=mypassword")
        
        let report = ErrorDetailsFormatter.format(job: job, error: error)
        
        #expect(report.contains("--- LocalConvert Error Report ---"))
        #expect(report.contains("Job ID: \(job.id.uuidString)"))
        #expect(report.contains("Input: protected.pdf"))
        #expect(report.contains("Conversion: PDF → Word Document"))
        #expect(report.contains("Password required"))
        #expect(!report.contains("mypassword"))
        #expect(report.contains("pwd=[REDACTED]"))
    }
    
    // MARK: - 5. Diagnostic Log Manager
    
    @Test("DiagnosticLogManager creates valid log directory")
    @MainActor
    func testDiagnosticLogManager() {
        let logDir = DiagnosticLogManager.logDirectoryURL
        #expect(FileManager.default.fileExists(atPath: logDir.path))
        
        // Write a test diagnostic log file
        let testLog = logDir.appendingPathComponent("test-diag.log")
        try? "test log line".data(using: .utf8)?.write(to: testLog)
        #expect(FileManager.default.fileExists(atPath: testLog.path))
        
        // Clear diagnostic logs
        DiagnosticLogManager.clearDiagnosticLogs()
        #expect(!FileManager.default.fileExists(atPath: testLog.path))
    }
    
    // MARK: - 6. Keyboard Shortcuts Integrity
    
    @Test("KeyboardShortcutDescriptor definitions")
    func testKeyboardShortcutDescriptors() {
        let shortcuts = KeyboardShortcutDescriptor.defaultShortcuts
        #expect(!shortcuts.isEmpty)
        
        let actions = shortcuts.map { $0.action }
        #expect(actions.contains("Add Files..."))
        #expect(actions.contains("Start Conversion"))
        #expect(actions.contains("Repeat Last Conversion"))
        #expect(actions.contains("Open Settings"))
        #expect(actions.contains("Switch to Convert Tab"))
        #expect(actions.contains("Switch to Jobs Center"))
        #expect(actions.contains("Switch to PDF Toolbox"))
        #expect(actions.contains("Switch to History"))
    }
    
    // MARK: - 7. Third Party Licenses Resource
    
    @Test("Third party licenses notice file bundled")
    func testThirdPartyNoticesFileAvailability() {
        let bundleURL = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
        // Either in Bundle.main or LocalConvert Resources root
        let directURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LocalConvert/Resources/THIRD_PARTY_NOTICES.md")
        
        let existsInBundle = bundleURL != nil && FileManager.default.fileExists(atPath: bundleURL!.path)
        let existsInSource = FileManager.default.fileExists(atPath: directURL.path)
        
        #expect(existsInBundle || existsInSource)
        
        let targetURL = bundleURL ?? directURL
        if let content = try? String(contentsOf: targetURL, encoding: .utf8) {
            #expect(content.contains("FFmpeg"))
            #expect(content.contains("LibreOffice"))
            #expect(content.contains("LocalConvert"))
        }
    }
}
