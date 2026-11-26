import XCTest
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import CryptoKit
@testable import LocalConvert

@MainActor
final class Phase49DataSafetyAndUndoTests: XCTestCase {

    // MARK: - Sandbox & Fixture Helpers

    private struct TestSandbox {
        let root: URL
        let journalDir: URL
        let artifactsDir: URL
        let workDir: URL
    }

    private func makeSandbox(prefix: String = "Phase49") throws -> TestSandbox {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let journalDir = root.appendingPathComponent("journal", isDirectory: true)
        let artifactsDir = root.appendingPathComponent("artifacts", isDirectory: true)
        let workDir = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        return TestSandbox(root: root, journalDir: journalDir, artifactsDir: artifactsDir, workDir: workDir)
    }

    private func makeCoordinator(sandbox: TestSandbox) -> (UndoRedoCoordinator, RecoveryArtifactManager) {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.artifactsDir)
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.journalDir,
            artifactManager: artifacts,
            maxUndoStepsProvider: { 100 },
            storageBudgetBytesProvider: { 64_000_000 }
        )
        return (coordinator, artifacts)
    }

    private func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeSolidCGImage(width: Int = 48, height: Int = 48, red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            pixels[idx] = red
            pixels[idx + 1] = green
            pixels[idx + 2] = blue
            pixels[idx + 3] = 255
        }
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else {
            throw NSError(domain: "Phase49Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to build solid CGImage"])
        }
        return cgImage
    }

    private func writePNG(to url: URL, width: Int = 48, height: Int = 48, red: UInt8 = 40, green: UInt8 = 120, blue: UInt8 = 220) throws {
        let img = try makeSolidCGImage(width: width, height: height, red: red, green: green, blue: blue)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Phase49Tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed PNG destination"])
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Phase49Tests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed PNG finalize"])
        }
    }

    private func writeAnimatedGIF(to url: URL, frameColors: [(UInt8, UInt8, UInt8)], frameDelay: Double = 0.08) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.gif.identifier as CFString,
            frameColors.count,
            nil
        ) else {
            throw NSError(domain: "Phase49Tests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed GIF destination"])
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        for color in frameColors {
            let img = try makeSolidCGImage(width: 32, height: 32, red: color.0, green: color.1, blue: color.2)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay]
            ]
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Phase49Tests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed GIF finalize"])
        }
    }

    private func writeSamplePDF(to url: URL, pageCount: Int = 2, labelPrefix: String = "Phase49Page") throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "Phase49Tests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed PDF context"])
        }
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 16, nil)
        for idx in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            ctx.fill(box)
            let attr = CFAttributedStringCreate(nil, "\(labelPrefix) \(idx + 1)" as CFString, [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 0.0, alpha: 1.0)
            ] as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func registerAllProvidersAndEngines() {
        let metaRegistry = MetadataRegistry.shared
        metaRegistry.register(provider: AudioMetadataProvider())
        metaRegistry.register(provider: ImageMetadataProvider())
        metaRegistry.register(provider: VideoMetadataProvider())
        metaRegistry.register(provider: PDFMetadataProvider())
        metaRegistry.register(provider: OfficeMetadataProvider())

        let convRegistry = ConversionRegistry.shared
        if convRegistry.registeredEngines.isEmpty {
            convRegistry.register(engine: ImageConversionEngine())
            convRegistry.register(engine: OfficeConversionEngine())
            convRegistry.register(engine: PDFConversionEngine())
            convRegistry.register(engine: MediaConversionEngine())
            convRegistry.register(engine: SubtitleConversionEngine())
            convRegistry.register(engine: ArchiveConversionEngine())
            convRegistry.register(engine: TextConversionEngine())
            convRegistry.register(engine: PDFToolboxEngine())
        }
    }

    // MARK: - 5.A Multi-Output Undo/Redo Tests (GAP-01)

    func testMultiOutputUndoRedoStagesAndRestoresAllOutputsWhileProtectingSource() async throws {
        let sandbox = try makeSandbox(prefix: "P49_GAP01_Command")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coordinator, artifacts) = makeCoordinator(sandbox: sandbox)

        let sourceURL = sandbox.workDir.appendingPathComponent("source_master.pdf")
        let out1 = sandbox.workDir.appendingPathComponent("page_01.pdf")
        let out2 = sandbox.workDir.appendingPathComponent("page_02.pdf")
        let out3 = sandbox.workDir.appendingPathComponent("page_03.pdf")

        let sourceBytes = Data("ORIGINAL_SOURCE_PDF_BYTES_DO_NOT_TOUCH".utf8)
        let out1Bytes = Data("SPLIT_OUTPUT_PAGE_1".utf8)
        let out2Bytes = Data("SPLIT_OUTPUT_PAGE_2".utf8)
        let out3Bytes = Data("SPLIT_OUTPUT_PAGE_3".utf8)

        try sourceBytes.write(to: sourceURL)
        try out1Bytes.write(to: out1)
        try out2Bytes.write(to: out2)
        try out3Bytes.write(to: out3)

        let result = ConversionResult(
            outputURL: out1,
            additionalOutputURLs: [out2, out3, out1], // includes duplicate to verify deduplication
            outputFormat: .pdf,
            fileSize: Int64(out1Bytes.count + out2Bytes.count + out3Bytes.count),
            duration: 0.05,
            engineName: "PDFToolboxEngine"
        )

        let safeOutputs = ConversionQueue.safeUndoableOutputURLs(
            outputURLs: result.allOutputURLs + [sourceURL],
            protectedSourceURLs: [sourceURL]
        )
        XCTAssertEqual(safeOutputs.count, 3, "Expected exactly 3 deduplicated output URLs excluding protected source")
        XCTAssertEqual(safeOutputs, [out1, out2, out3])

        let cmd = OutputCreationUndoCommand(
            title: "Create 3 Outputs (page_01.pdf +2 more)",
            context: .pdfToolbox,
            outputURLs: result.allOutputURLs + [sourceURL],
            protectedSourceURLs: [sourceURL],
            artifactManager: artifacts
        )
        XCTAssertEqual(cmd.affectedURLs, [out1, out2, out3])

        await coordinator.record(cmd)

        // Undo must remove all 3 generated outputs and keep source intact
        await coordinator.undo(in: .pdfToolbox)
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out3.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)

        // Redo must restore all 3 generated outputs with identical bytes
        await coordinator.redo(in: .pdfToolbox)
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out3.path))
        XCTAssertEqual(try Data(contentsOf: out1), out1Bytes)
        XCTAssertEqual(try Data(contentsOf: out2), out2Bytes)
        XCTAssertEqual(try Data(contentsOf: out3), out3Bytes)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
    }

    func testConversionQueueMultiSizeImageJobRecordsAllOutputsInUndoCommand() async throws {
        registerAllProvidersAndEngines()
        let sandbox = try makeSandbox(prefix: "P49_GAP01_Queue")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coordinator, _) = makeCoordinator(sandbox: sandbox)

        let sourceURL = sandbox.workDir.appendingPathComponent("photo_master.png")
        try writePNG(to: sourceURL, width: 96, height: 96, red: 30, green: 140, blue: 210)
        let sourceHashBefore = try sha256Hex(of: sourceURL)

        let outDir = sandbox.workDir.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var multiConfig = ImageToolboxConfig()
        multiConfig.exportMultipleSizes = true
        multiConfig.multiSizePresets = [
            ImageBatchSizePreset(label: "Icon32", width: 32, height: 32),
            ImageBatchSizePreset(label: "Thumb64", width: 64, height: 64)
        ]

        let options = multiConfig.applying(to: .default, outputFormat: .jxl)

        let job = ConversionJob(
            inputURLs: [sourceURL],
            inputFormat: .png,
            outputFormat: .jxl,
            outputDirectory: outDir,
            options: options
        )

        let manager = ConversionManager(registry: ConversionRegistry.shared)
        let queue = ConversionQueue(conversionManager: manager, undoCoordinator: coordinator)
        queue.enqueue(job: job)

        let deadline = Date().addingTimeInterval(15.0)
        while queue.isProcessing && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await queue.flushPendingUndoRecords()

        XCTAssertEqual(queue.completedCount, 1)
        XCTAssertEqual(queue.lastBatchCompletedOutputURLs.count, 2, "lastBatchCompletedOutputURLs must include primary and additional outputs")

        let generatedOutputs = queue.lastBatchCompletedOutputURLs
        for url in generatedOutputs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Expected output file \(url.lastPathComponent) on disk")
        }

        let undoEntries = coordinator.undoEntries(for: .imageToolbox)
        XCTAssertEqual(undoEntries.count, 1)
        XCTAssertEqual(Set(undoEntries[0].affectedURLs.map(\.standardizedFileURL)), Set(generatedOutputs.map(\.standardizedFileURL)))

        // Undo through coordinator removes all multi-size outputs while keeping source intact
        await coordinator.undo(in: .imageToolbox)
        XCTAssertNil(coordinator.lastError)
        for url in generatedOutputs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Undo must remove \(url.lastPathComponent)")
        }
        XCTAssertEqual(try sha256Hex(of: sourceURL), sourceHashBefore)

        // Redo through coordinator restores all multi-size outputs
        await coordinator.redo(in: .imageToolbox)
        XCTAssertNil(coordinator.lastError)
        for url in generatedOutputs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Redo must restore \(url.lastPathComponent)")
        }
        XCTAssertEqual(try sha256Hex(of: sourceURL), sourceHashBefore)
    }

    // MARK: - 5.B Metadata Save Copy & Disk-Level Undo Tests (GAP-02)

    func testMetadataSaveCopyAndInPlaceUndoRedoForImagePNG() async throws {
        registerAllProvidersAndEngines()
        let sandbox = try makeSandbox(prefix: "P49_GAP02_PNG")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coordinator, artifacts) = makeCoordinator(sandbox: sandbox)

        let sourceURL = sandbox.workDir.appendingPathComponent("artwork.png")
        try writePNG(to: sourceURL, width: 64, height: 64, red: 180, green: 60, blue: 90)
        let originalBytes = try Data(contentsOf: sourceURL)

        let manager = MetadataManager(undoCoordinator: coordinator, artifactManager: artifacts)
        await manager.load(url: sourceURL)
        XCTAssertNotNil(manager.document)

        manager.updateField(id: "title", value: .string("Phase 49 Safe Copy Title"))
        manager.updateField(id: "author", value: .string("Phase 49 Author"))
        await manager.flushPendingUndoRecords()

        // Refuses overwriting sourceURL via saveCopy
        let refusedCopy = await manager.saveCopy(to: sourceURL, context: .metadata)
        XCTAssertNil(refusedCopy, "saveCopy must refuse overwriting the source file")
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)

        // 1. Save Copy (collision-safe default)
        guard let copyURL = await manager.saveCopy(context: .metadata) else {
            XCTFail("Expected saveCopy to return a collision-safe copy URL")
            return
        }
        XCTAssertNotEqual(copyURL.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes, "Save Copy must leave original source bytes 100% unmodified")

        let copyDoc = try await ImageMetadataProvider().readMetadata(from: copyURL)
        XCTAssertEqual(copyDoc.common.title, "Phase 49 Safe Copy Title")

        // Undo Save Copy removes the copy and protects source
        await coordinator.undo(in: .metadata)
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path), "Undoing Save Copy must remove the created copy")
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)

        // Redo Save Copy restores the copy
        await coordinator.redo(in: .metadata)
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path), "Redoing Save Copy must restore the copy")
        let restoredCopyDoc = try await ImageMetadataProvider().readMetadata(from: copyURL)
        XCTAssertEqual(restoredCopyDoc.common.title, "Phase 49 Safe Copy Title")

        // 2. Save In-Place + Disk-Level Undo/Redo
        let didSaveInPlace = await manager.saveInPlace(context: .metadata)
        XCTAssertTrue(didSaveInPlace)
        let savedInPlaceBytes = try Data(contentsOf: sourceURL)
        XCTAssertNotEqual(savedInPlaceBytes, originalBytes)
        let savedInPlaceDoc = try await ImageMetadataProvider().readMetadata(from: sourceURL)
        XCTAssertEqual(savedInPlaceDoc.common.title, "Phase 49 Safe Copy Title")

        // Undo In-Place Save restores exact original file bytes
        await coordinator.undo(in: .metadata)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes, "Undoing in-place metadata save must restore exact original file bytes")

        // Redo In-Place Save restores exact saved metadata file bytes
        await coordinator.redo(in: .metadata)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(try Data(contentsOf: sourceURL), savedInPlaceBytes, "Redoing in-place metadata save must restore exact saved file bytes")
    }

    func testMetadataSaveCopyAndInPlaceUndoRedoForPDFDocument() async throws {
        registerAllProvidersAndEngines()
        let sandbox = try makeSandbox(prefix: "P49_GAP02_PDF")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coordinator, artifacts) = makeCoordinator(sandbox: sandbox)

        let sourceURL = sandbox.workDir.appendingPathComponent("contract.pdf")
        try writeSamplePDF(to: sourceURL, pageCount: 2, labelPrefix: "ContractPage")
        let originalBytes = try Data(contentsOf: sourceURL)

        let manager = MetadataManager(undoCoordinator: coordinator, artifactManager: artifacts)
        await manager.load(url: sourceURL)
        XCTAssertNotNil(manager.document)

        manager.updateField(id: "title", value: .string("Phase 49 Audited PDF"))
        manager.updateField(id: "author", value: .string("LocalConvert Security Team"))
        await manager.flushPendingUndoRecords()

        // 1. Save Copy
        guard let copyURL = await manager.saveCopy(context: .metadata) else {
            XCTFail("Expected PDF saveCopy to succeed")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes, "PDF Save Copy must not alter source PDF bytes")
        let copyRead = try await PDFMetadataProvider().readMetadata(from: copyURL)
        XCTAssertEqual(copyRead.common.title, "Phase 49 Audited PDF")
        XCTAssertEqual(copyRead.common.author, "LocalConvert Security Team")

        // Undo & Redo Save Copy
        await coordinator.undo(in: .metadata)
        XCTAssertNil(coordinator.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)

        await coordinator.redo(in: .metadata)
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))

        // 2. Save In-Place + Undo/Redo exact bytes
        let didSaveInPlace = await manager.saveInPlace(context: .metadata)
        XCTAssertTrue(didSaveInPlace)
        let savedInPlaceBytes = try Data(contentsOf: sourceURL)
        let inPlaceRead = try await PDFMetadataProvider().readMetadata(from: sourceURL)
        XCTAssertEqual(inPlaceRead.common.title, "Phase 49 Audited PDF")

        await coordinator.undo(in: .metadata)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes, "Undoing in-place PDF metadata save must restore exact original PDF bytes")

        await coordinator.redo(in: .metadata)
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(try Data(contentsOf: sourceURL), savedInPlaceBytes)
    }

    // MARK: - 5.C Image Batch Rename Synchronization Tests (GAP-03)

    func testBatchRenameSynchronizesAppStateDroppedFilesSelectionAndImageToolboxStoreAcrossUndoRedo() async throws {
        registerAllProvidersAndEngines()
        let sandbox = try makeSandbox(prefix: "P49_GAP03_Rename")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let (coordinator, _) = makeCoordinator(sandbox: sandbox)

        let previousSharedAppState = AppState.shared
        defer { AppState.shared = previousSharedAppState }

        let appState = AppState(undoCoordinator: coordinator)
        let urlA = sandbox.workDir.appendingPathComponent("IMG_001.png")
        let urlB = sandbox.workDir.appendingPathComponent("IMG_002.png")
        try writePNG(to: urlA, red: 200, green: 50, blue: 50)
        try writePNG(to: urlB, red: 50, green: 200, blue: 50)

        appState.addFiles(urls: [urlA, urlB])
        XCTAssertEqual(appState.droppedFiles.count, 2)
        let idA = appState.droppedFiles[0].id
        let idB = appState.droppedFiles[1].id

        // Customize ImageToolboxStore config and targetFormat for urlA and urlB
        appState.imageToolboxStore.updateConfig(for: urlA, explicitTitle: "Set Custom Quality A") { cfg in
            cfg.quality = 0.77
            cfg.jxlLossless = true
        }
        appState.imageToolboxStore.setTargetFormat(.webp, for: urlA)
        appState.imageToolboxStore.updateConfig(for: urlB, explicitTitle: "Set Custom Quality B") { cfg in
            cfg.quality = 0.64
        }
        appState.imageToolboxStore.setTargetFormat(.avif, for: urlB)
        await appState.imageToolboxStore.flushPendingUndoRecords()

        var renameOptions = ImageBatchRenameOptions()
        renameOptions.findText = "IMG_"
        renameOptions.replaceText = "Studio_"
        let plan = ImageBatchRenameService.buildPlan(urls: [urlA, urlB], options: renameOptions)
        let manifest = try ImageBatchRenameService.executePlan(plan)
        XCTAssertEqual(manifest.appliedMoves.count, 2)

        let renamedA = sandbox.workDir.appendingPathComponent("Studio_001.png")
        let renamedB = sandbox.workDir.appendingPathComponent("Studio_002.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedB.path))

        appState.applyRenamedURLs(manifest.appliedMoves)
        let renameCmd = BatchRenameUndoCommand(
            title: "Batch Rename 2 File(s)",
            context: .imageToolbox,
            manifest: manifest,
            onURLsMoved: { [weak appState] moves in
                appState?.applyRenamedURLs(moves)
            }
        )
        await coordinator.record(renameCmd)

        // Verify AppState.droppedFiles IDs (selection) and URLs are synchronized
        XCTAssertEqual(appState.droppedFiles.map(\.id), [idA, idB], "DroppedFile IDs must remain identical so active selection is preserved")
        XCTAssertEqual(appState.droppedFiles[0].url.standardizedFileURL, renamedA.standardizedFileURL)
        XCTAssertEqual(appState.droppedFiles[1].url.standardizedFileURL, renamedB.standardizedFileURL)

        // Verify ImageToolboxStore migrated configsByURL and targetFormatByURL to new URLs
        XCTAssertNil(appState.imageToolboxStore.configsByURL[urlA.standardizedFileURL])
        XCTAssertEqual(appState.imageToolboxStore.config(for: renamedA).quality, 0.77, accuracy: 0.0001)
        XCTAssertTrue(appState.imageToolboxStore.config(for: renamedA).jxlLossless)
        XCTAssertEqual(appState.imageToolboxStore.targetFormat(for: renamedA, fallback: .jxl), .webp)
        XCTAssertEqual(appState.imageToolboxStore.config(for: renamedB).quality, 0.64, accuracy: 0.0001)
        XCTAssertEqual(appState.imageToolboxStore.targetFormat(for: renamedB, fallback: .jxl), .avif)

        // Undo through UndoRedoCoordinator moves files back and synchronizes AppState & ImageToolboxStore
        await coordinator.undo(in: .imageToolbox)
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedB.path))

        XCTAssertEqual(appState.droppedFiles.map(\.id), [idA, idB])
        XCTAssertEqual(appState.droppedFiles[0].url.standardizedFileURL, urlA.standardizedFileURL)
        XCTAssertEqual(appState.droppedFiles[1].url.standardizedFileURL, urlB.standardizedFileURL)
        XCTAssertEqual(appState.imageToolboxStore.config(for: urlA).quality, 0.77, accuracy: 0.0001)
        XCTAssertEqual(appState.imageToolboxStore.targetFormat(for: urlA, fallback: .jxl), .webp)
        XCTAssertNil(appState.imageToolboxStore.configsByURL[renamedA.standardizedFileURL])

        // Redo through UndoRedoCoordinator re-applies rename on disk and in state
        await coordinator.redo(in: .imageToolbox)
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedB.path))
        XCTAssertEqual(appState.droppedFiles.map(\.id), [idA, idB])
        XCTAssertEqual(appState.droppedFiles[0].url.standardizedFileURL, renamedA.standardizedFileURL)
        XCTAssertEqual(appState.droppedFiles[1].url.standardizedFileURL, renamedB.standardizedFileURL)
        XCTAssertEqual(appState.imageToolboxStore.config(for: renamedA).quality, 0.77, accuracy: 0.0001)
        XCTAssertEqual(appState.imageToolboxStore.targetFormat(for: renamedA, fallback: .jxl), .webp)
    }

    // MARK: - 5.D Animated Image Preservation Tests (GAP-05)

    func testAnimatedGIFAndJXLPreservationInImageToolboxProcessToFileAndFlatteningWarning() async throws {
        registerAllProvidersAndEngines()
        let sandbox = try makeSandbox(prefix: "P49_GAP05_Anim")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let gifURL = sandbox.workDir.appendingPathComponent("spinner_3frame.gif")
        try writeAnimatedGIF(
            to: gifURL,
            frameColors: [(240, 40, 40), (40, 220, 60), (40, 90, 240)],
            frameDelay: 0.08
        )
        XCTAssertEqual(ImageProcessingService.inspectAnimationFrameCount(url: gifURL), 3)

        let outDir = sandbox.workDir.appendingPathComponent("anim_out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let defaultConfig = ImageToolboxConfig()
        XCTAssertTrue(ImageProcessingService.canPreserveAnimation(inputFormat: .gif, outputFormat: .jxl, config: defaultConfig))
        XCTAssertNil(ImageProcessingService.animationFlatteningWarning(frameCount: 3, inputFormat: .gif, outputFormat: .jxl, config: defaultConfig))

        // 1. Export animated GIF -> animated JXL via ImageProcessingService.processToFile
        let jxlResult = try await ImageProcessingService.processToFile(
            inputURL: gifURL,
            outputFormat: .jxl,
            outputDirectory: outDir,
            config: defaultConfig
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: jxlResult.outputURL.path))
        let jxlInfo = try JPEGXLCodec.inspect(url: jxlResult.outputURL)
        XCTAssertTrue(jxlInfo.isAnimated, "Exported JXL from 3-frame GIF must preserve animation")
        XCTAssertEqual(jxlInfo.frameCount, 3, "Exported JXL must preserve all 3 frames")

        // 2. Export animated JXL -> animated GIF via ImageProcessingService.processToFile
        let roundtripGIFResult = try await ImageProcessingService.processToFile(
            inputURL: jxlResult.outputURL,
            outputFormat: .gif,
            outputDirectory: outDir,
            config: defaultConfig
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: roundtripGIFResult.outputURL.path))
        XCTAssertEqual(ImageProcessingService.inspectAnimationFrameCount(url: roundtripGIFResult.outputURL, format: .gif), 3)

        // 3. Verify explicit flattening warning when exporting animated input to static format (.png) or with active pixel edits
        let staticWarning = ImageProcessingService.animationFlatteningWarning(
            frameCount: 3,
            inputFormat: .gif,
            outputFormat: .png,
            config: defaultConfig
        )
        XCTAssertNotNil(staticWarning)
        XCTAssertTrue(staticWarning?.contains("flattened") == true)

        var resizedConfig = ImageToolboxConfig()
        resizedConfig.resizeStrategy = .exactDimensions
        resizedConfig.resizeWidth = 24
        resizedConfig.resizeHeight = 24
        let editWarning = ImageProcessingService.animationFlatteningWarning(
            frameCount: 3,
            inputFormat: .gif,
            outputFormat: .jxl,
            config: resizedConfig
        )
        XCTAssertNotNil(editWarning)
        XCTAssertTrue(editWarning?.contains("flattened") == true)

        let inMemoryStatic = try await ImageProcessingService.processInMemory(
            url: gifURL,
            outputFormat: .png,
            config: defaultConfig
        )
        XCTAssertTrue(
            inMemoryStatic.telemetry.warnings.contains(where: { $0.contains("flattened") }),
            "processInMemory telemetry must surface an explicit animation-flattening warning"
        )
    }

    // MARK: - 5.E VideoMetadataProvider Process Execution Tests (GAP-06)

    func testVideoMetadataProviderAsyncProcessRunnerHandlesLargeStdoutAndRealMP4WithoutDeadlock() async throws {
        let sandbox = try makeSandbox(prefix: "P49_GAP06_VideoMeta")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        // 1. Create a mock ffprobe script emitting >180 KB of valid JSON stdout (nearly 3x the 64 KB macOS pipe buffer)
        let mockScriptURL = sandbox.workDir.appendingPathComponent("mock_ffprobe_large.sh")
        var paddingTags: [String] = []
        paddingTags.reserveCapacity(1500)
        for i in 0..<1500 {
            paddingTags.append("\"custom_padding_tag_\(i)\": \"\(String(repeating: "X", count: 110))\"")
        }
        let jsonBody = """
        {
          "format": {
            "duration": "125.4",
            "bit_rate": "4200000",
            "tags": {
              "title": "Large Pipe Metadata Video",
              "artist": "Phase 49 Pipe Verification",
              "genre": "Engineering",
              "comment": "Over 180KB JSON payload",
              \(paddingTags.joined(separator: ",\n      "))
            }
          },
          "streams": [
            {
              "codec_type": "video",
              "codec_name": "h264",
              "width": 1920,
              "height": 1080,
              "r_frame_rate": "30000/1001"
            },
            {
              "codec_type": "audio",
              "codec_name": "aac"
            }
          ]
        }
        """
        let payloadFile = sandbox.workDir.appendingPathComponent("large_ffprobe.json")
        try Data(jsonBody.utf8).write(to: payloadFile)
        XCTAssertGreaterThan((try Data(contentsOf: payloadFile)).count, 160_000, "JSON payload must exceed 64 KB pipe capacity")

        let scriptContent = """
        #!/bin/sh
        cat "\(payloadFile.path)"
        """
        try Data(scriptContent.utf8).write(to: mockScriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScriptURL.path)

        let dummyVideoURL = sandbox.workDir.appendingPathComponent("sample.mp4")
        try Data("not_a_real_mp4_for_avasset_fallback_to_ffprobe".utf8).write(to: dummyVideoURL)

        let largeOutputProvider = VideoMetadataProvider(ffprobeExecutableOverride: mockScriptURL)
        let doc = try await largeOutputProvider.readMetadata(from: dummyVideoURL)
        XCTAssertEqual(doc.common.title, "Large Pipe Metadata Video")
        XCTAssertEqual(doc.common.artist, "Phase 49 Pipe Verification")
        XCTAssertEqual(doc.common.genre, "Engineering")
        XCTAssertEqual(doc.technical["duration"], "2:05")
        XCTAssertEqual(doc.technical["bitrate"], "4200 kbps")
        XCTAssertEqual(doc.technical["resolution"], "1920 × 1080")
        XCTAssertEqual(doc.technical["videoCodec"], "H264")
        XCTAssertEqual(doc.technical["audioCodec"], "AAC")

        // 2. Verify real MP4 container read/write via bundled FFmpeg & FFprobe if present
        if let ffmpegPath = await BundledFFmpegProvider(fallbackToSystem: true).findFFmpegPath() {
            let realMP4URL = sandbox.workDir.appendingPathComponent("real_clip.mp4")
            let genProc = Process()
            genProc.executableURL = URL(fileURLWithPath: ffmpegPath)
            genProc.arguments = [
                "-y",
                "-f", "lavfi", "-i", "color=c=blue:s=64x64:d=0.4",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=0.4",
                "-c:v", "mpeg4",
                "-c:a", "aac",
                "-metadata", "title=Real MP4 Fixture",
                "-metadata", "artist=LocalConvert Phase 49",
                realMP4URL.path
            ]
            let genOut = try await AsyncProcessRunner.run(genProc)
            XCTAssertEqual(genOut.terminationStatus, 0)

            let realProvider = VideoMetadataProvider()
            let realDoc = try await realProvider.readMetadata(from: realMP4URL)
            XCTAssertEqual(realDoc.common.title, "Real MP4 Fixture")
            XCTAssertEqual(realDoc.technical["resolution"], "64 × 64")
        }
    }
}
