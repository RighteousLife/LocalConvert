import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import CryptoKit
@testable import LocalConvert

@Suite("Phase 44.5 & 44.6 — Global Undo/Redo, Integration, Performance & Security", .serialized)
struct Phase44UndoRedoTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P44_5_6_\(name)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeSamplePDF(at url: URL, pageCount: Int = 2, labelPrefix: String = "Page") throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.engineExecutionFailed("Failed PDF ctx", underlyingError: nil)
        }
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 16, nil)
        for i in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(.white)
            ctx.fill(box)
            let attr = CFAttributedStringCreate(nil, "\(labelPrefix) \(i + 1)" as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor.black
            ] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    @Test("44.5 PDFOperationConfigUndoCommand supports per-document isolation, coalescing, password scrubbing, and restart rehydration")
    @MainActor
    func configUndoIsolationCoalescingPasswordScrubbingAndRehydration() async throws {
        let dir = try makeTempDir("ConfigUndo")
        defer { try? FileManager.default.removeItem(at: dir) }

        let journalDir = dir.appendingPathComponent("journal")
        let artifactsDir = dir.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let pdfA = dir.appendingPathComponent("docA.pdf")
        let pdfB = dir.appendingPathComponent("docB.pdf")
        try makeSamplePDF(at: pdfA, pageCount: 2, labelPrefix: "DocA")
        try makeSamplePDF(at: pdfB, pageCount: 2, labelPrefix: "DocB")

        let coord1 = UndoRedoCoordinator(journalDirectoryURL: journalDir, artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir))
        let pdfStore1 = PDFToolboxStore(undoCoordinator: coord1)

        let keyA = PDFToolboxStore.configKey(for: [pdfA])
        let keyB = PDFToolboxStore.configKey(for: [pdfB])

        // Coalesce rapid DPI slider drags on DocA + test secret password scrubbing
        pdfStore1.updateCompressionConfig(for: keyA, affectedURLs: [pdfA], title: "Change PDF Optimization Settings", coalesceKey: "comp_dpi") { cfg in
            cfg.profile = .custom
            cfg.targetDPI = 120
            cfg.password = "SUPER_SECRET_PASSWORD_SHOULD_NOT_PERSIST"
        }
        pdfStore1.updateCompressionConfig(for: keyA, affectedURLs: [pdfA], title: "Change PDF Optimization Settings", coalesceKey: "comp_dpi") { cfg in
            cfg.profile = .custom
            cfg.targetDPI = 96
            cfg.grayscale = true
            cfg.password = "SUPER_SECRET_PASSWORD_SHOULD_NOT_PERSIST"
        }

        // Separate OCR config change on DocB
        pdfStore1.updateOCRConfig(for: keyB, affectedURLs: [pdfB], title: "Toggle OCR Deskew") { cfg in
            cfg.deskewPages = true
            cfg.languageCodes = ["en-US", "tr-TR"]
            cfg.password = "SECRET_OCR_PWD"
        }

        // Session-only annotation/form/redaction edits must NOT persist into journal.json
        pdfStore1.updateAnnotationDraft(for: pdfA, title: "Add Note") { d in
            d.records.append(PDFDraftAnnotationRecord(pageIndex: 0, kind: .note, bounds: CGRect(x: 40, y: 40, width: 24, height: 24), contents: "PRIVATE_SESSION_NOTE"))
        }
        pdfStore1.updateRedactionDraft(for: pdfA, title: "Add Secret Term") { d in
            d.searchTerms.append("SSN_123_45_6789")
        }

        await pdfStore1.flushPendingUndoRecords()
        coord1.flushPersistence()

        // Exactly 2 config undo commands (DocA coalesced compression + DocB OCR) + 2 session-only commands in memory
        #expect(coord1.undoEntries(for: .pdfToolbox).count == 4)
        #expect(pdfStore1.compressionConfig(for: keyA).targetDPI == 96)
        #expect(pdfStore1.compressionConfig(for: keyB).targetDPI == 150) // DocB untouched

        // Inspect journal.json directly: NO passwords, NO private note text, NO redaction terms!
        let journalRaw = try String(contentsOf: coord1.journalFileURL, encoding: .utf8)
        #expect(!journalRaw.contains("SUPER_SECRET_PASSWORD_SHOULD_NOT_PERSIST"))
        #expect(!journalRaw.contains("SECRET_OCR_PWD"))
        #expect(!journalRaw.contains("PRIVATE_SESSION_NOTE"))
        #expect(!journalRaw.contains("SSN_123_45_6789"))

        // Simulated restart -> rehydrates only restart-survivable commands (DocA compression & DocB OCR)
        let coord2 = UndoRedoCoordinator(journalDirectoryURL: journalDir, artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir))
        let pdfStore2 = PDFToolboxStore(undoCoordinator: coord2)
        await coord2.restorePersistedHistory()

        let restoredEntries = coord2.undoEntries(for: .pdfToolbox)
        #expect(restoredEntries.count == 2)

        // Undo DocB OCR config
        await coord2.undo(in: .pdfToolbox)
        #expect(pdfStore2.ocrConfig(for: keyB).deskewPages == false)

        // Undo DocA Compression config
        await coord2.undo(in: .pdfToolbox)
        #expect(pdfStore2.compressionConfig(for: keyA).targetDPI == 150)

        // Redo both
        await coord2.redo(in: .pdfToolbox)
        #expect(pdfStore2.compressionConfig(for: keyA).targetDPI == 96)
        await coord2.redo(in: .pdfToolbox)
        #expect(pdfStore2.ocrConfig(for: keyB).deskewPages == true)
    }

    @Test("44.5 OutputCreationUndoCommand rolls back PDF output while protecting immutable source PDF and keeping contexts isolated")
    @MainActor
    func outputRollbackSourceProtectionAndContextIsolation() async throws {
        let dir = try makeTempDir("OutputRollback")
        defer { try? FileManager.default.removeItem(at: dir) }

        let journalDir = dir.appendingPathComponent("journal")
        let artifactsDir = dir.appendingPathComponent("artifacts")
        let artifactMgr = RecoveryArtifactManager(baseDirectoryURL: artifactsDir)
        let coord = UndoRedoCoordinator(journalDirectoryURL: journalDir, artifactManager: artifactMgr)
        let pdfStore = PDFToolboxStore(undoCoordinator: coord)
        let imageStore = ImageToolboxStore(undoCoordinator: coord)

        let srcPDF = dir.appendingPathComponent("source.pdf")
        let outPDF = dir.appendingPathComponent("compressed.pdf")
        try makeSamplePDF(at: srcPDF, pageCount: 2, labelPrefix: "Immutable")
        let srcHashBefore = try sha256Hex(srcPDF)

        _ = try await PDFCompressionService.compress(
            inputURL: srcPDF,
            outputURL: outPDF,
            options: .forProfile(.maximumQuality)
        ) { _ in }
        #expect(FileManager.default.fileExists(atPath: outPDF.path))

        await coord.record(OutputCreationUndoCommand(
            title: "Compress PDF",
            context: .pdfToolbox,
            outputURLs: [outPDF],
            protectedSourceURLs: [srcPDF],
            artifactManager: artifactMgr
        ))

        // Unrelated ImageToolbox edit in parallel context must stay completely separate from pdfToolbox stack
        let dummyImg = dir.appendingPathComponent("pic.png")
        try Data("PNG".utf8).write(to: dummyImg)
        imageStore.updateConfig(for: dummyImg) { cfg in
            cfg.resizeStrategy = .exactDimensions
            cfg.resizeWidth = 1280
        }
        await imageStore.flushPendingUndoRecords()

        #expect(coord.undoEntries(for: .pdfToolbox).count == 1)
        #expect(coord.undoEntries(for: .imageToolbox).count == 1)

        // Undo PDF output creation -> output removed, source untouched, ImageToolbox still present
        await coord.undo(in: .pdfToolbox)
        #expect(!FileManager.default.fileExists(atPath: outPDF.path))
        #expect(try sha256Hex(srcPDF) == srcHashBefore)
        #expect(coord.undoEntries(for: .imageToolbox).count == 1)

        // Redo restores output cleanly
        await coord.redo(in: .pdfToolbox)
        #expect(FileManager.default.fileExists(atPath: outPDF.path))

        // Also keep pdfStore reference valid so PDFToolboxStore lifecycle stays clean
        #expect(pdfStore.pageWorkspacesByURL.isEmpty)
    }

    @Test("44.6 Security & resilience: corrupt inputs, password locks, non-overwrite guard, and 60-page optimization scale cleanly")
    func securityEdgeCasesAndLargePDFResilience() async throws {
        let dir = try makeTempDir("SecurityScale")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Corrupt PDF rejected safely across services
        let corruptURL = dir.appendingPathComponent("corrupt.pdf")
        try Data("NOT A REAL PDF %%%%".utf8).write(to: corruptURL)
        await #expect(throws: Error.self) {
            _ = try await PDFAnnotationService.applyAndSave(
                inputURL: corruptURL,
                outputURL: dir.appendingPathComponent("c_annot.pdf"),
                options: PDFAnnotationSaveOptions()
            ) { _ in }
        }
        await #expect(throws: Error.self) {
            _ = try await PDFOCRService.runOCR(
                inputURL: corruptURL,
                outputPDFURL: dir.appendingPathComponent("c_ocr.pdf"),
                options: .default
            ) { _ in }
        }

        // 2. Password-locked PDF requires valid password and rejects wrong/empty password
        let plainURL = dir.appendingPathComponent("plain.pdf")
        let lockedURL = dir.appendingPathComponent("locked.pdf")
        try makeSamplePDF(at: plainURL, pageCount: 2, labelPrefix: "Classified")
        _ = try await PDFSecurityService.applySecurity(
            inputURL: plainURL,
            outputURL: lockedURL,
            options: PDFSecurityOptions(userPassword: "open123", ownerPassword: "owner456")
        )

        await #expect(throws: Error.self) {
            _ = try await PDFPageManagementService.rotatePages(
                input: lockedURL,
                rotationDelta: 90,
                pageRanges: "1",
                outputURL: dir.appendingPathComponent("l_out.pdf"),
                password: "wrong"
            ) { _ in }
        }

        // Valid unlock succeeds without modifying lockedURL
        let lockedHash = try sha256Hex(lockedURL)
        let unlockedRot = dir.appendingPathComponent("unlocked_rot.pdf")
        let rotRes = try await PDFPageManagementService.rotatePages(
            input: lockedURL,
            rotationDelta: 90,
            pageRanges: "1",
            outputURL: unlockedRot,
            password: "open123"
        ) { _ in }
        #expect(rotRes.pageCount == 2)
        #expect(try sha256Hex(lockedURL) == lockedHash)

        // 3. Same-path overwrite rejected across services
        await #expect(throws: ConversionError.self) {
            _ = try await PDFAnnotationService.applyAndSave(
                inputURL: plainURL,
                outputURL: plainURL,
                options: PDFAnnotationSaveOptions()
            ) { _ in }
        }
        await #expect(throws: ConversionError.self) {
            _ = try await PDFCompressionService.compress(
                inputURL: plainURL,
                outputURL: plainURL,
                options: .forProfile(.balanced)
            ) { _ in }
        }

        // 4. 60-page multi-page Quartz optimization stability
        let largeURL = dir.appendingPathComponent("large_60p.pdf")
        try makeSamplePDF(at: largeURL, pageCount: 60, labelPrefix: "Archive")
        let largeOut = dir.appendingPathComponent("large_60p_opt.pdf")
        var optCfg = PDFCompressionOptions.forProfile(.balanced)
        optCfg.targetDPI = 120
        let largeRes = try await PDFCompressionService.compress(
            inputURL: largeURL,
            outputURL: largeOut,
            options: optCfg
        ) { _ in }
        #expect(largeRes.pageCount == 60)
        #expect(largeRes.validatedReadable)
        #expect(PDFDocument(url: largeOut)?.pageCount == 60)
    }
}
