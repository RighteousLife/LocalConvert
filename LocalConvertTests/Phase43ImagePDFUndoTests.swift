import Testing
import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText
import CryptoKit
@testable import LocalConvert

@Suite("Phase 43 — Image & PDF Toolbox Editing History Expansion", .serialized)
struct Phase43ImagePDFUndoTests {

    private func makeSandbox(prefix: String = "Phase43Tests") throws -> (root: URL, journalDir: URL, artifactsDir: URL, workDir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let journalDir = root.appendingPathComponent("journal", isDirectory: true)
        let artifactsDir = root.appendingPathComponent("artifacts", isDirectory: true)
        let workDir = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        return (root, journalDir, artifactsDir, workDir)
    }

    @MainActor
    private func makeCoordinator(sandbox: (root: URL, journalDir: URL, artifactsDir: URL, workDir: URL)) -> (UndoRedoCoordinator, RecoveryArtifactManager) {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 100 },
            storageBudgetBytesProvider: { 50_000_000 }
        )
        return (coord, artifacts)
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeSamplePDF(to url: URL, lines: [String]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let cgContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "Phase43Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF CGContext"])
        }
        var pBox = mediaBox
        let pData = Data(bytes: &pBox, count: MemoryLayout<CGRect>.size) as CFData
        cgContext.beginPDFPage([kCGPDFContextMediaBox: pData] as CFDictionary)
        cgContext.setFillColor(.white)
        cgContext.fill(mediaBox)
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 14.0, nil)
        var y: CGFloat = 720
        for line in lines {
            let attr = CFAttributedStringCreate(nil, line as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor.black
            ] as CFDictionary)!
            cgContext.textPosition = CGPoint(x: 48, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attr), cgContext)
            y -= 24
        }
        cgContext.endPDFPage()
        cgContext.closePDF()
    }

    // MARK: - 1. Image Resize Undo / Redo

    @Test("Image resize parameters undo and redo cleanly")
    @MainActor
    func testImageResizeUndoRedo() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, _) = makeCoordinator(sandbox: sandbox)
        let store = ImageToolboxStore(undoCoordinator: coord)

        let imgURL = sandbox.workDir.appendingPathComponent("photo.png")
        let initial = store.config(for: imgURL)
        #expect(initial.resizeStrategy == .none)

        store.updateConfig(for: imgURL) { cfg in
            cfg.resizeStrategy = .exactDimensions
            cfg.resizeWidth = 1280
            cfg.resizeHeight = 720
            cfg.preserveAspectRatio = false
        }
        await store.flushPendingUndoRecords()

        let edited = store.config(for: imgURL)
        #expect(edited.resizeStrategy == .exactDimensions)
        #expect(edited.resizeWidth == 1280)
        #expect(edited.resizeHeight == 720)
        #expect(edited.preserveAspectRatio == false)
        #expect(coord.undoTitle(in: .imageToolbox) == "Image Resize")

        await coord.undo(in: .imageToolbox)
        #expect(coord.lastError == nil)
        #expect(store.config(for: imgURL) == initial)
        #expect(coord.redoTitle(in: .imageToolbox) == "Image Resize")

        await coord.redo(in: .imageToolbox)
        #expect(coord.lastError == nil)
        #expect(store.config(for: imgURL) == edited)
    }

    // MARK: - 2. Image Crop, Shape Crop & Rotate/Flip Undo / Redo

    @Test("Image crop, shape crop, and rotation/flip undo and redo cleanly")
    @MainActor
    func testImageCropShapeRotateUndoRedo() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, _) = makeCoordinator(sandbox: sandbox)
        let store = ImageToolboxStore(undoCoordinator: coord)
        let imgURL = sandbox.workDir.appendingPathComponent("portrait.png")

        store.updateConfig(for: imgURL) { cfg in
            cfg.cropTransform.enabled = true
            cfg.cropTransform.cropMode = .customRect
            cfg.cropTransform.ratioPreset = .ratio16x9
        }
        await store.flushPendingUndoRecords()
        #expect(coord.undoTitle(in: .imageToolbox) == "Image Crop")

        store.updateConfig(for: imgURL) { cfg in
            cfg.cropTransform.shape = .roundedRectangle
            cfg.cropTransform.roundedCornerRadiusPercent = 18.0
        }
        await store.flushPendingUndoRecords()
        #expect(coord.undoTitle(in: .imageToolbox) == "Shape Crop")

        store.updateConfig(for: imgURL) { cfg in
            cfg.cropTransform.rotationDegrees = 90
            cfg.cropTransform.flipHorizontal = true
        }
        await store.flushPendingUndoRecords()
        #expect(coord.undoTitle(in: .imageToolbox) == "Image Rotate / Flip")
        #expect(coord.undoEntries(for: .imageToolbox).count == 3)

        // Undo rotate/flip
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: imgURL).cropTransform.rotationDegrees == 0)
        #expect(store.config(for: imgURL).cropTransform.flipHorizontal == false)
        #expect(store.config(for: imgURL).cropTransform.shape == .roundedRectangle)

        // Undo shape crop
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: imgURL).cropTransform.shape == .rectangle)
        #expect(store.config(for: imgURL).cropTransform.enabled == true)

        // Undo crop
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: imgURL).cropTransform.enabled == false)

        // Redo back through all three steps
        await coord.redo(in: .imageToolbox)
        #expect(store.config(for: imgURL).cropTransform.ratioPreset == .ratio16x9)
        await coord.redo(in: .imageToolbox)
        #expect(store.config(for: imgURL).cropTransform.shape == .roundedRectangle)
        await coord.redo(in: .imageToolbox)
        #expect(store.config(for: imgURL).cropTransform.rotationDegrees == 90)
        #expect(store.config(for: imgURL).cropTransform.flipHorizontal == true)
    }

    // MARK: - 3. Real Image Adjustments / Watermark / Sharpen / DPI Undo / Redo

    @Test("Real image quality, sharpening, watermark, and DPI changes undo and redo cleanly")
    @MainActor
    func testImageAdjustmentsUndoRedo() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, _) = makeCoordinator(sandbox: sandbox)
        let store = ImageToolboxStore(undoCoordinator: coord)
        let imgURL = sandbox.workDir.appendingPathComponent("adjust.png")

        store.updateConfig(for: imgURL) { cfg in
            cfg.compressionProfile = .webOptimized
            cfg.quality = 0.78
        }
        await store.flushPendingUndoRecords()

        store.updateConfig(for: imgURL) { cfg in
            cfg.postResizeSharpen = 0.45
        }
        await store.flushPendingUndoRecords()

        store.updateConfig(for: imgURL) { cfg in
            cfg.watermark.enabled = true
            cfg.watermark.text = "PROOF"
            cfg.watermark.opacity = 0.55
        }
        await store.flushPendingUndoRecords()

        store.updateConfig(for: imgURL) { cfg in
            cfg.dpiConfig.enabled = true
            cfg.dpiConfig.targetDPI = 300
        }
        await store.flushPendingUndoRecords()

        #expect(coord.undoEntries(for: .imageToolbox).count == 4)
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: imgURL).dpiConfig.enabled == false)
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: imgURL).watermark.enabled == false)
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: imgURL).postResizeSharpen == 0.0)
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: imgURL).compressionProfile != .webOptimized)

        for _ in 0..<4 {
            await coord.redo(in: .imageToolbox)
        }
        #expect(store.config(for: imgURL).dpiConfig.targetDPI == 300)
        #expect(store.config(for: imgURL).watermark.text == "PROOF")
        #expect(store.config(for: imgURL).postResizeSharpen == 0.45)
        #expect(store.config(for: imgURL).quality == 0.78)
    }

    // MARK: - 4. Continuous Slider Drag Coalescing

    @Test("Continuous slider drags coalesce into one single Undo entry (explicit and rapid auto-coalescing)")
    @MainActor
    func testContinuousSliderDragCoalescesIntoSingleUndo() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, _) = makeCoordinator(sandbox: sandbox)
        let store = ImageToolboxStore(undoCoordinator: coord)
        let imgURL = sandbox.workDir.appendingPathComponent("slider.png")

        let baselineQuality = store.config(for: imgURL).quality

        // Explicit begin/end gesture lifecycle
        store.beginContinuousEdit(for: imgURL)
        for q in stride(from: 0.90, through: 0.40, by: -0.05) {
            store.updateConfig(for: imgURL) { $0.quality = q }
        }
        store.endContinuousEdit(for: imgURL)
        await store.flushPendingUndoRecords()

        #expect(coord.undoEntries(for: .imageToolbox).count == 1)
        #expect(abs(store.config(for: imgURL).quality - 0.40) < 0.001)

        await coord.undo(in: .imageToolbox)
        #expect(abs(store.config(for: imgURL).quality - baselineQuality) < 0.001)
        #expect(!coord.canUndo(in: .imageToolbox))

        // Rapid un-bracketed slider updates also auto-coalesce within the 450ms window
        for s in stride(from: 0.1, through: 0.9, by: 0.1) {
            store.updateConfig(for: imgURL) { $0.postResizeSharpen = s }
        }
        await store.flushPendingUndoRecords()

        #expect(coord.undoEntries(for: .imageToolbox).count == 1)
        #expect(abs(store.config(for: imgURL).postResizeSharpen - 0.9) < 0.001)
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: imgURL).postResizeSharpen == 0.0)
    }

    // MARK: - 5. Per-Image Isolation & Silent Metadata Hydration

    @Test("Two distinct images maintain isolated editing histories and silent initial metadata hydration")
    @MainActor
    func testPerImageHistoryIsolationAndSilentHydration() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, _) = makeCoordinator(sandbox: sandbox)
        let store = ImageToolboxStore(undoCoordinator: coord)

        let urlA = sandbox.workDir.appendingPathComponent("a.png")
        let urlB = sandbox.workDir.appendingPathComponent("b.png")

        var initialMetaA = ImageMetadataEditPayload()
        initialMetaA.author = "Original Camera Owner"
        store.hydrateMetadataDefaults(for: urlA, payload: initialMetaA)
        #expect(coord.undoEntries(for: .imageToolbox).isEmpty)

        store.updateConfig(for: urlA) { $0.resizeWidth = 800; $0.resizeStrategy = .maxWidth }
        store.updateConfig(for: urlB) { $0.watermark.enabled = true; $0.watermark.text = "ONLY_B" }
        await store.flushPendingUndoRecords()

        #expect(coord.undoEntries(for: .imageToolbox).count == 2)
        #expect(store.config(for: urlA).watermark.enabled == false)
        #expect(store.config(for: urlB).resizeStrategy == .none)

        // Undo last (urlB's watermark), leaving urlA untouched
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: urlB).watermark.enabled == false)
        #expect(store.config(for: urlA).resizeWidth == 800)
        #expect(store.config(for: urlA).metadataEdit.author == "Original Camera Owner")

        // Undo urlA's resize
        await coord.undo(in: .imageToolbox)
        #expect(store.config(for: urlA).resizeStrategy == .none)
        #expect(store.config(for: urlA).metadataEdit.author == "Original Camera Owner")
    }

    // MARK: - 6. Image File Write Undo & Rehydration

    @Test("Image metadata file write stages recovery backup, rejects stale external edits, and rehydrates ImageConfigUndoCommand")
    @MainActor
    func testImageFileWriteUndoAndRehydration() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, artifacts) = makeCoordinator(sandbox: sandbox)
        let store = ImageToolboxStore(undoCoordinator: coord)

        // 6A. In-place metadata write backup/restore + stale external modification guard
        let imgURL = sandbox.workDir.appendingPathComponent("exif_target.jpg")
        try Data("ORIGINAL_IMAGE_BYTES".utf8).write(to: imgURL)
        let origHash = try sha256Hex(of: imgURL)

        let stagedPrev = try await artifacts.stageFileByCopying(from: imgURL)
        try Data("MODIFIED_METADATA_BYTES".utf8).write(to: imgURL, options: .atomic)
        let modHash = try sha256Hex(of: imgURL)

        let fileCmd = ImageFileWriteUndoCommand(
            title: "Save Metadata: \(imgURL.lastPathComponent)",
            destinationURL: imgURL,
            protectedSourceURLs: [],
            previousArtifactID: stagedPrev.id,
            artifactManager: artifacts
        )
        store.recordFileWriteCommand(fileCmd)
        await store.flushPendingUndoRecords()

        await coord.undo(in: .imageToolbox)
        #expect(coord.lastError == nil)
        #expect(try sha256Hex(of: imgURL) == origHash)
        await coord.redo(in: .imageToolbox)
        #expect(coord.lastError == nil)
        #expect(try sha256Hex(of: imgURL) == modHash)

        // Simulate external modification: undo must fail cleanly instead of clobbering unknown data
        try Data("EXTERNAL_EDIT_BYTES".utf8).write(to: imgURL, options: .atomic)
        await coord.undo(in: .imageToolbox)
        #expect(coord.lastError != nil)
        #expect(try String(contentsOf: imgURL, encoding: .utf8) == "EXTERNAL_EDIT_BYTES")

        // 6B. Restart rehydration for ImageConfigUndoCommand
        let coord1 = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts
        )
        let store1 = ImageToolboxStore(undoCoordinator: coord1)
        let restartImgURL = sandbox.workDir.appendingPathComponent("rehydrate.png")
        store1.updateConfig(for: restartImgURL) { cfg in
            cfg.resizeStrategy = .percentage
            cfg.resizePercentage = 50.0
        }
        await store1.flushPendingUndoRecords()
        coord1.flushPersistence()

        let coord2 = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts
        )
        let store2 = ImageToolboxStore(undoCoordinator: coord2)
        await coord2.restorePersistedHistory()

        #expect(coord2.canUndo(in: .imageToolbox))
        #expect(coord2.undoTitle(in: .imageToolbox) == "Image Resize")
        await coord2.undo(in: .imageToolbox)
        #expect(store2.config(for: restartImgURL).resizeStrategy == .none)
        await coord2.redo(in: .imageToolbox)
        #expect(store2.config(for: restartImgURL).resizeStrategy == .percentage)
        #expect(store2.config(for: restartImgURL).resizePercentage == 50.0)
    }

    // MARK: - 7. PDF Form Draft Editing Undo / Redo & Isolation

    @Test("PDF form field edits (coalesced typing, checkbox, radio, choice, reset) undo/redo and stay isolated per PDF")
    @MainActor
    func testPDFFormDraftUndoRedoAndIsolation() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, _) = makeCoordinator(sandbox: sandbox)
        let store = PDFToolboxStore(undoCoordinator: coord)

        let pdfA = sandbox.workDir.appendingPathComponent("formA.pdf")
        let pdfB = sandbox.workDir.appendingPathComponent("formB.pdf")

        let fieldsA: [PDFFormFieldItem] = [
            PDFFormFieldItem(id: "0::0::FullName", pageIndex: 0, fieldName: "FullName", kind: .text, stringValue: "", boolValue: false, choices: [], isReadOnly: false, bounds: .zero),
            PDFFormFieldItem(id: "0::1::Agree", pageIndex: 0, fieldName: "Agree", kind: .checkbox, stringValue: "", boolValue: false, choices: [], isReadOnly: false, bounds: .zero),
            PDFFormFieldItem(id: "0::2::Tier", pageIndex: 0, fieldName: "Tier", kind: .radio, stringValue: "Basic", boolValue: true, choices: [], isReadOnly: false, bounds: .zero),
            PDFFormFieldItem(id: "0::3::Tier", pageIndex: 0, fieldName: "Tier", kind: .radio, stringValue: "Pro", boolValue: false, choices: [], isReadOnly: false, bounds: .zero),
            PDFFormFieldItem(id: "0::4::Country", pageIndex: 0, fieldName: "Country", kind: .choice, stringValue: "TR", boolValue: false, choices: ["TR", "US", "DE"], isReadOnly: false, bounds: .zero)
        ]
        let fieldsB: [PDFFormFieldItem] = [
            PDFFormFieldItem(id: "0::0::OtherField", pageIndex: 0, fieldName: "OtherField", kind: .text, stringValue: "KeepB", boolValue: false, choices: [], isReadOnly: false, bounds: .zero)
        ]

        // Silent hydration must NOT push undo steps
        store.hydrateScannedFormFields(fieldsA, for: pdfA)
        store.hydrateScannedFormFields(fieldsB, for: pdfB)
        #expect(coord.undoEntries(for: .pdfToolbox).isEmpty)

        // Keystroke typing into same text field should coalesce into 1 undo step
        for partial in ["A", "Al", "Ali", "Alice"] {
            store.updateFormDraft(for: pdfA, title: "Edit FullName", coalesceKey: "0::0::FullName") { d in
                d.fields[0].stringValue = partial
            }
        }
        await store.flushPendingUndoRecords()
        #expect(coord.undoEntries(for: .pdfToolbox).count == 1)

        // Checkbox toggle
        store.updateFormDraft(for: pdfA, title: "Toggle Agree") { d in
            d.fields[1].boolValue = true
        }
        // Choice dropdown
        store.updateFormDraft(for: pdfA, title: "Select Country") { d in
            d.fields[4].stringValue = "DE"
        }
        // Reset Fields
        store.updateFormDraft(for: pdfA, title: "Reset Form Fields") { d in
            d.fields = PDFFormService.resetFieldsToEmpty(d.fields)
        }
        await store.flushPendingUndoRecords()
        #expect(coord.undoEntries(for: .pdfToolbox).count == 4)
        #expect(store.formDraft(for: pdfA).fields[0].stringValue == "")
        #expect(store.formDraft(for: pdfB).fields[0].stringValue == "KeepB")

        // Undo Reset Fields -> restores Alice / checked / DE
        await coord.undo(in: .pdfToolbox)
        #expect(store.formDraft(for: pdfA).fields[0].stringValue == "Alice")
        #expect(store.formDraft(for: pdfA).fields[1].boolValue == true)
        #expect(store.formDraft(for: pdfA).fields[4].stringValue == "DE")

        // Undo Choice, Checkbox, and Coalesced Typing back to initial scan state
        await coord.undo(in: .pdfToolbox)
        await coord.undo(in: .pdfToolbox)
        await coord.undo(in: .pdfToolbox)
        #expect(store.formDraft(for: pdfA).fields[0].stringValue == "")
        #expect(store.formDraft(for: pdfA).fields[1].boolValue == false)
        #expect(store.formDraft(for: pdfA).fields[4].stringValue == "TR")

        // Redo back to Alice
        await coord.redo(in: .pdfToolbox)
        #expect(store.formDraft(for: pdfA).fields[0].stringValue == "Alice")
        #expect(store.formDraft(for: pdfB).fields[0].stringValue == "KeepB")
    }

    // MARK: - 8. PDF Redaction Draft Undo / Redo, Isolation & No Journal Leak

    @Test("PDF redaction draft edits undo/redo per PDF and sensitive PII search terms are never written to journal.json")
    @MainActor
    func testPDFRedactionDraftUndoRedoAndJournalPrivacy() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, _) = makeCoordinator(sandbox: sandbox)
        let store = PDFToolboxStore(undoCoordinator: coord)

        let pdf1 = sandbox.workDir.appendingPathComponent("secret1.pdf")
        let pdf2 = sandbox.workDir.appendingPathComponent("secret2.pdf")
        let piiSecret = "CONFIDENTIAL-SSN-987-65-4321"

        store.updateRedactionDraft(for: pdf1, title: "Add Redaction Search Term") { d in
            d.searchTerms.append(piiSecret)
        }
        store.updateRedactionDraft(for: pdf1, title: "Add Redaction Region") { d in
            d.manualRegions.append(PDFRedactionRegion(pageIndex: 0, rect: CGRect(x: 40, y: 400, width: 120, height: 24), label: "Area 1"))
        }
        store.updateRedactionDraft(for: pdf2, title: "Add Redaction Region") { d in
            d.manualRegions.append(PDFRedactionRegion(pageIndex: 0, rect: CGRect(x: 10, y: 10, width: 50, height: 20), label: "Other"))
        }
        store.updateRedactionDraft(for: pdf1, title: "Toggle Scrub Metadata") { d in
            d.removeMetadata = false
        }
        await store.flushPendingUndoRecords()
        coord.flushPersistence()

        // Privacy check: journal.json must NOT contain sensitive search terms
        let journalFile = sandbox.journalDir.appendingPathComponent("journal.json")
        if FileManager.default.fileExists(atPath: journalFile.path) {
            let journalText = try String(contentsOf: journalFile, encoding: .utf8)
            #expect(!journalText.contains(piiSecret))
        }

        #expect(store.redactionDraft(for: pdf1).searchTerms == [piiSecret])
        #expect(store.redactionDraft(for: pdf1).manualRegions.count == 1)
        #expect(store.redactionDraft(for: pdf1).removeMetadata == false)
        #expect(store.redactionDraft(for: pdf2).manualRegions.count == 1)

        // Undo removeMetadata toggle, pdf2 region, pdf1 region, pdf1 search term
        await coord.undo(in: .pdfToolbox)
        #expect(store.redactionDraft(for: pdf1).removeMetadata == true)
        await coord.undo(in: .pdfToolbox)
        #expect(store.redactionDraft(for: pdf2).manualRegions.isEmpty)
        #expect(store.redactionDraft(for: pdf1).manualRegions.count == 1)
        await coord.undo(in: .pdfToolbox)
        #expect(store.redactionDraft(for: pdf1).manualRegions.isEmpty)
        await coord.undo(in: .pdfToolbox)
        #expect(store.redactionDraft(for: pdf1).searchTerms.isEmpty)

        // Redo restores term
        await coord.redo(in: .pdfToolbox)
        #expect(store.redactionDraft(for: pdf1).searchTerms == [piiSecret])
    }

    // MARK: - 9. Permanent PDF Redaction + OutputCreationUndoCommand Source Protection

    @Test("Permanent PDF redaction creates new clean output, never modifies source PDF, and pairs with OutputCreationUndoCommand")
    @MainActor
    func testPermanentPDFRedactionAndOutputUndo() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, artifacts) = makeCoordinator(sandbox: sandbox)
        let store = PDFToolboxStore(undoCoordinator: coord)

        let sourcePDF = sandbox.workDir.appendingPathComponent("source_contract.pdf")
        let outputPDF = sandbox.workDir.appendingPathComponent("source_contract_redacted.pdf")
        try writeSamplePDF(to: sourcePDF, lines: [
            "PUBLIC_HEADER_LINE",
            "TOPSECRET_TOKEN_778899"
        ])
        let sourceHashBefore = try sha256Hex(of: sourcePDF)

        store.updateRedactionDraft(for: sourcePDF, title: "Add Redaction Search Term") { d in
            d.searchTerms.append("TOPSECRET_TOKEN_778899")
        }
        await store.flushPendingUndoRecords()

        let options = store.redactionDraft(for: sourcePDF).toRedactionOptions(password: nil)
        let report = try await PDFRedactionService.redact(
            inputURL: sourcePDF,
            outputURL: outputPDF,
            options: options
        ) { _ in }

        #expect(report.isVerifiedClean)
        #expect(FileManager.default.fileExists(atPath: outputPDF.path))
        #expect(try sha256Hex(of: sourcePDF) == sourceHashBefore)

        let redactedDoc = try #require(PDFDocument(url: outputPDF))
        let redactedText = redactedDoc.string ?? ""
        #expect(!redactedText.contains("TOPSECRET_TOKEN_778899"))

        // OutputCreationUndoCommand tracks output creation safely while protecting sourcePDF
        let outputCmd = OutputCreationUndoCommand(
            title: "Permanent Redaction Output",
            context: .pdfToolbox,
            outputURLs: [outputPDF],
            protectedSourceURLs: [sourcePDF],
            artifactManager: artifacts
        )
        await coord.record(outputCmd)

        await coord.undo(in: .pdfToolbox)
        #expect(!FileManager.default.fileExists(atPath: outputPDF.path))
        #expect(try sha256Hex(of: sourcePDF) == sourceHashBefore)

        await coord.redo(in: .pdfToolbox)
        #expect(FileManager.default.fileExists(atPath: outputPDF.path))
        #expect(try sha256Hex(of: sourcePDF) == sourceHashBefore)
    }

    // MARK: - 10. Global Coexistence: Image + PDF + Audio Stores on Shared Coordinator

    @Test("ImageToolboxStore, PDFToolboxStore, and AudioEditorStore share UndoRedoCoordinator without cross-interference")
    @MainActor
    func testGlobalCoexistenceAcrossStores() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coord, _) = makeCoordinator(sandbox: sandbox)

        let imageStore = ImageToolboxStore(undoCoordinator: coord)
        let pdfStore = PDFToolboxStore(undoCoordinator: coord)
        let audioStore = AudioEditorStore(undoCoordinator: coord)

        let imgURL = sandbox.workDir.appendingPathComponent("coexist.png")
        let pdfURL = sandbox.workDir.appendingPathComponent("coexist.pdf")
        let audioContext = OperationContext.audioEditor(projectID: audioStore.project.id)
        let initialAudioTracks = audioStore.project.tracks.count

        imageStore.updateConfig(for: imgURL) { $0.quality = 0.60 }
        await imageStore.flushPendingUndoRecords()

        pdfStore.updateRedactionDraft(for: pdfURL, title: "Toggle Scrub Metadata") { $0.removeMetadata = false }
        await pdfStore.flushPendingUndoRecords()

        audioStore.addTrack()
        await audioStore.flushPendingUndoRecords()

        #expect(coord.undoEntries(for: .imageToolbox).count == 1)
        #expect(coord.undoEntries(for: .pdfToolbox).count == 1)
        #expect(coord.undoEntries(for: audioContext).count == 1)
        #expect(audioStore.project.tracks.count == initialAudioTracks + 1)
        #expect(pdfStore.redactionDraft(for: pdfURL).removeMetadata == false)
        #expect(abs(imageStore.config(for: imgURL).quality - 0.60) < 0.001)

        // Undoing Audio Editor leaves Image & PDF intact
        await coord.undo(in: audioContext)
        #expect(audioStore.project.tracks.count == initialAudioTracks)
        #expect(pdfStore.redactionDraft(for: pdfURL).removeMetadata == false)
        #expect(abs(imageStore.config(for: imgURL).quality - 0.60) < 0.001)

        // Undoing PDF Toolbox leaves Image intact
        await coord.undo(in: .pdfToolbox)
        #expect(pdfStore.redactionDraft(for: pdfURL).removeMetadata == true)
        #expect(abs(imageStore.config(for: imgURL).quality - 0.60) < 0.001)

        // Undoing Image Toolbox restores quality
        await coord.undo(in: .imageToolbox)
        #expect(abs(imageStore.config(for: imgURL).quality - ImageToolboxConfig().quality) < 0.001)
    }
}
