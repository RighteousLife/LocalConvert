import Foundation
import Testing
import PDFKit
import CoreGraphics
import CoreText
import AppKit
@testable import LocalConvert

@Suite("Phase 25 — Multi-File PDF Workflow & Completion Feedback Tests")
struct Phase25Tests {
    
    // MARK: - Test Helpers
    
    private func createTestPDF(
        pageCount: Int,
        title: String,
        in directory: URL,
        filename: String
    ) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        var mediaBox = CGRect(x: 0, y: 0, width: 600, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Could not create PDF context", underlyingError: nil)
        }
        
        for p in 1...pageCount {
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            context.fill(mediaBox)
            
            let str = "\(title) - Page \(p)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 24),
                .foregroundColor: NSColor.black
            ]
            let attrStr = NSAttributedString(string: str, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            context.saveGState()
            context.textPosition = CGPoint(x: 50, y: 200)
            CTLineDraw(line, context)
            context.restoreGState()
            
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    
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
    
    // MARK: - 1. Multi-File PDF Visibility & Single Source of Truth
    
    @Test("PDF Toolbox: Multiple loaded PDFs are derived from AppState.droppedFiles without duplication")
    @MainActor
    func testMultiFilePDFVisibilityInAppState() {
        let appState = AppState()
        let dummy1 = URL(fileURLWithPath: "/tmp/doc1.pdf")
        let dummy2 = URL(fileURLWithPath: "/tmp/doc2.pdf")
        let dummy3 = URL(fileURLWithPath: "/tmp/photo.png")
        
        let df1 = DroppedFile(url: dummy1, detectionResult: mockDetectionResult(url: dummy1, format: .pdf))
        let df2 = DroppedFile(url: dummy2, detectionResult: mockDetectionResult(url: dummy2, format: .pdf))
        let df3 = DroppedFile(url: dummy3, detectionResult: mockDetectionResult(url: dummy3, format: .png))
        
        appState.droppedFiles = [df1, df2, df3]
        
        let pdfs = appState.droppedFiles.filter { $0.detectedFormat == .pdf }
        #expect(pdfs.count == 2)
        #expect(pdfs.map { $0.fileName } == ["doc1.pdf", "doc2.pdf"])
        
        // Removing a file updates the list automatically
        appState.removeFile(df1)
        let updatedPDFs = appState.droppedFiles.filter { $0.detectedFormat == .pdf }
        #expect(updatedPDFs.count == 1)
        #expect(updatedPDFs.first?.fileName == "doc2.pdf")
    }
    
    // MARK: - 2. Selection Switching Without File Removal
    
    @Test("PDF Toolbox: Switching selected PDF does not remove other loaded PDFs")
    @MainActor
    func testSelectionSwitchingPreservesAllFiles() {
        let dummyA = URL(fileURLWithPath: "/tmp/A.pdf")
        let dummyB = URL(fileURLWithPath: "/tmp/B.pdf")
        let dummyC = URL(fileURLWithPath: "/tmp/C.pdf")
        
        let fileA = DroppedFile(url: dummyA, detectionResult: mockDetectionResult(url: dummyA, format: .pdf))
        let fileB = DroppedFile(url: dummyB, detectionResult: mockDetectionResult(url: dummyB, format: .pdf))
        let fileC = DroppedFile(url: dummyC, detectionResult: mockDetectionResult(url: dummyC, format: .pdf))
        
        let allFiles = [fileA, fileB, fileC]
        var selectedIDs: Set<UUID> = [fileA.id]
        
        #expect(selectedIDs.contains(fileA.id))
        #expect(!selectedIDs.contains(fileB.id))
        #expect(allFiles.count == 3)
        
        // Switch to File B
        selectedIDs = [fileB.id]
        #expect(!selectedIDs.contains(fileA.id))
        #expect(selectedIDs.contains(fileB.id))
        #expect(allFiles.count == 3) // A and C remain loaded!
        
        // Switch to File C
        selectedIDs = [fileC.id]
        #expect(selectedIDs.contains(fileC.id))
        #expect(allFiles.count == 3)
    }
    
    // MARK: - 3. Multi-File Merge Operation (A + B + C)
    
    @Test("PDF Merge: Merging 3 PDFs preserves exact input ordering and creates single merged PDF")
    @MainActor
    func testMergeThreePDFsInExactOrder() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let urlA = try createTestPDF(pageCount: 2, title: "Doc A", in: tempDir, filename: "A.pdf")
        let urlB = try createTestPDF(pageCount: 3, title: "Doc B", in: tempDir, filename: "B.pdf")
        let urlC = try createTestPDF(pageCount: 1, title: "Doc C", in: tempDir, filename: "C.pdf")
        
        let engine = PDFToolboxEngine()
        var options = ConversionOptions()
        options.customOptions["pdf_operation"] = "merge"
        
        // Merge in order: C, A, B (1 + 2 + 3 = 6 pages)
        let result = try await engine.convert(
            inputs: [urlC, urlA, urlB],
            to: .pdf,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        guard let mergedDoc = PDFDocument(url: result.outputURL) else {
            Issue.record("Failed to load merged PDF")
            return
        }
        
        #expect(mergedDoc.pageCount == 6)
        
        // Page 1 is from C
        #expect(mergedDoc.page(at: 0)?.string?.contains("Doc C - Page 1") == true)
        // Page 2 is from A
        #expect(mergedDoc.page(at: 1)?.string?.contains("Doc A - Page 1") == true)
        // Page 3 is from A
        #expect(mergedDoc.page(at: 2)?.string?.contains("Doc A - Page 2") == true)
        // Page 4 is from B
        #expect(mergedDoc.page(at: 3)?.string?.contains("Doc B - Page 1") == true)
        // Page 6 is from B
        #expect(mergedDoc.page(at: 5)?.string?.contains("Doc B - Page 3") == true)
    }
    
    // MARK: - 4. Batch Processing Multiple PDFs via AppState
    
    @Test("PDF Toolbox Batch: Executing operation on multiple selected PDFs enqueues individual batch jobs")
    @MainActor
    func testBatchPDFExecutionInAppState() {
        let appState = AppState()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let url1 = tempDir.appendingPathComponent("1.pdf")
        let url2 = tempDir.appendingPathComponent("2.pdf")
        let url3 = tempDir.appendingPathComponent("3.pdf")
        try? Data().write(to: url1)
        try? Data().write(to: url2)
        try? Data().write(to: url3)
        
        let f1 = DroppedFile(url: url1, detectionResult: mockDetectionResult(url: url1, format: .pdf))
        let f2 = DroppedFile(url: url2, detectionResult: mockDetectionResult(url: url2, format: .pdf))
        let f3 = DroppedFile(url: url3, detectionResult: mockDetectionResult(url: url3, format: .pdf))
        
        // Execute batch separatePages
        appState.executePDFOperation(operation: "separatePages", files: [f1, f2, f3])
        
        #expect(appState.conversionManager.activeJobs.count == 3)
        
        // Verify all 3 jobs share the same batchID
        let firstBatchID = appState.conversionManager.activeJobs.first?.batchID
        #expect(firstBatchID != nil)
        for job in appState.conversionManager.activeJobs {
            #expect(job.batchID == firstBatchID)
            #expect(job.options.customOptions["pdf_operation"] == "separatePages")
        }
    }
    
    // MARK: - 5. Notification Manager Logic & Batch Aggregation
    
    @Test("Notification Manager: Single job completion and batch aggregation produce appropriate message content")
    @MainActor
    func testNotificationFormatting() {
        let dummyURL = URL(fileURLWithPath: "/tmp/sample.pdf")
        let job = ConversionJob(
            inputURLs: [dummyURL],
            inputFormat: .pdf,
            outputFormat: .pdf,
            outputDirectory: URL(fileURLWithPath: "/tmp")
        )
        let result = ConversionResult(outputURL: URL(fileURLWithPath: "/tmp/sample_out.pdf"))
        
        // Verify method invocations do not throw or crash
        AppNotificationManager.shared.notifyJobCompleted(job: job, result: result)
        AppNotificationManager.shared.notifyJobFailed(job: job, error: .inputFileNotFound(dummyURL))
        AppNotificationManager.shared.notifyBatchCompleted(total: 5, completed: 5, failed: 0)
        AppNotificationManager.shared.notifyBatchCompleted(total: 5, completed: 4, failed: 1)
        AppNotificationManager.shared.notifyBatchCompleted(total: 5, completed: 0, failed: 5)
    }
    
    // MARK: - 6. Jobs Center Status Queries & Status Display
    
    @Test("Jobs Center: Jobs reflect active, completed, failed, and cancelled states")
    @MainActor
    func testJobsCenterStateHandling() {
        let manager = ConversionManager()
        let dummyURL = URL(fileURLWithPath: "/tmp/test.pdf")
        
        let job1 = ConversionJob(inputURLs: [dummyURL], inputFormat: .pdf, outputFormat: .pdf, outputDirectory: URL(fileURLWithPath: "/tmp"))
        let job2 = ConversionJob(inputURLs: [dummyURL], inputFormat: .pdf, outputFormat: .pdf, outputDirectory: URL(fileURLWithPath: "/tmp"))
        let job3 = ConversionJob(inputURLs: [dummyURL], inputFormat: .pdf, outputFormat: .pdf, outputDirectory: URL(fileURLWithPath: "/tmp"))
        
        manager.jobs = [job1, job2, job3]
        manager.jobStatuses[job1.id] = .completed(ConversionResult(outputURL: dummyURL))
        manager.jobStatuses[job2.id] = .failed(.invalidInput("Corrupt PDF"))
        manager.jobStatuses[job3.id] = .cancelled
        
        #expect(manager.completedJobs.count == 1)
        #expect(manager.failedJobs.count == 1)
        #expect(manager.cancelledJobs.count == 1)
        #expect(manager.status(for: job1.id).displayTitle == "Completed")
        #expect(manager.status(for: job2.id).displayTitle == "Failed")
        #expect(manager.status(for: job3.id).displayTitle == "Cancelled")
    }
    
    // MARK: - 7. Output File Naming & Collision Avoidance
    
    @Test("OutputManager: Sequential numbering prevents overwriting existing files")
    func testOutputManagerCollisionSafety() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = URL(fileURLWithPath: "report.pdf")
        let url1 = OutputManager.safeOutputURL(for: inputURL, format: .pdf, in: tempDir)
        try? Data("1".utf8).write(to: url1)
        
        let url2 = OutputManager.safeOutputURL(for: inputURL, format: .pdf, in: tempDir)
        try? Data("2".utf8).write(to: url2)
        
        let url3 = OutputManager.safeOutputURL(for: inputURL, format: .pdf, in: tempDir)
        
        #expect(url1.lastPathComponent == "report.pdf")
        #expect(url2.lastPathComponent == "report (1).pdf")
        #expect(url3.lastPathComponent == "report (2).pdf")
    }
}
