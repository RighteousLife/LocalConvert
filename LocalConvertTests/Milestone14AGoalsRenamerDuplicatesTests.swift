import XCTest
import SwiftUI
import AppKit
import Combine
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@testable import LocalConvert

@MainActor
final class Milestone14AGoalsRenamerDuplicatesTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M14A-W1-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
        BatchRenamerSheetController.shared.dismiss()
        DuplicateFinderSheetController.shared.dismiss()
        AppStoragePaths.clearTestOverrides()
        AppState.shared = previousAppState
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
        previousAppState = nil
    }

    // MARK: - Helpers

    private func makeIsolatedAppState() -> AppState {
        let artifacts = RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        let undo = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: artifacts
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        return AppState(
            undoCoordinator: undo,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history,
            uitestingOutputDirectory: sandbox.outputsURL
        )
    }

    private func writeTextFile(_ name: String, content: String, in directory: URL? = nil, modificationDate: Date? = nil) throws -> URL {
        let dir = directory ?? sandbox.documentsURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        if let modificationDate {
            try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
        return url
    }

    private func writeTinyPNG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 180, count: 16 * 16 * 4)
        for idx in stride(from: 3, to: pixels.count, by: 4) { pixels[idx] = 255 }
        guard let ctx = CGContext(
            data: &pixels,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone14AGoalsRenamerDuplicatesTests", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func makeDroppedFile(url: URL, format: FileFormat?) -> DroppedFile {
        let det = FileDetectionResult(
            url: url,
            detectedFormat: format,
            extensionFormat: format,
            utTypeFormat: format,
            magicBytesFormat: format,
            confidence: format == nil ? .unknown : .high
        )
        return DroppedFile(url: url, detectionResult: det)
    }

    private func hostAndMeasure<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 820, height: 580),
        appState: AppState? = nil,
        contextName: String
    ) -> CGSize {
        var publishCount = 0
        var cancellable: AnyCancellable?
        if let appState {
            cancellable = appState.objectWillChange.sink { _ in
                publishCount += 1
            }
        }
        defer { cancellable?.cancel() }

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(publishCount, 0, "[\(contextName)] Layout must not publish AppState mutations")

        let controller = NSHostingController(rootView: view)
        let fitted = controller.sizeThatFits(in: size)
        XCTAssertFalse(fitted.width.isNaN || fitted.height.isNaN, "[\(contextName)] sizeThatFits must be finite")
        return fitted
    }

    // MARK: - 1. BatchFileRenamerEngine Tests

    func testBatchRenamerFindReplacePrefixSuffixNumberingAndDateStamp() throws {
        let fixedDate = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00:00 UTC
        let u1 = try writeTextFile("My Draft Photo.PNG", content: "1", modificationDate: fixedDate)
        let u2 = try writeTextFile("My draft Note.txt", content: "2", modificationDate: fixedDate)

        var rules = BatchRenameRules.default
        rules.findText = "draft"
        rules.replaceText = "final"
        rules.isCaseSensitive = false
        rules.prefix = "proj_"
        rules.suffix = "_v2"
        rules.includeNumbering = true
        rules.startIndex = 10
        rules.step = 5
        rules.paddingDigits = 3
        rules.numberingSeparator = "-"
        rules.dateSource = .currentDate
        rules.datePlacement = .prefix
        rules.dateFormat = "yyyyMMdd"
        rules.preserveExtension = true

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        let expectedStamp = formatter.string(from: fixedDate)

        let plan = BatchFileRenamerEngine.preview(urls: [u1, u2], rules: rules, referenceDate: fixedDate)
        XCTAssertFalse(plan.hasConflicts)
        XCTAssertTrue(plan.hasChanges)
        XCTAssertEqual(plan.rows.count, 2)
        XCTAssertEqual(plan.rows[0].afterName, "\(expectedStamp)_proj_My final Photo_v2-010.PNG")
        XCTAssertEqual(plan.rows[1].afterName, "\(expectedStamp)_proj_My final Note_v2-015.txt")

        // Case-sensitive find should only match lowercase "draft"
        rules.isCaseSensitive = true
        let sensitivePlan = BatchFileRenamerEngine.preview(urls: [u1, u2], rules: rules, referenceDate: fixedDate)
        XCTAssertEqual(sensitivePlan.rows[0].afterName, "\(expectedStamp)_proj_My Draft Photo_v2-010.PNG")
        XCTAssertEqual(sensitivePlan.rows[1].afterName, "\(expectedStamp)_proj_My final Note_v2-015.txt")
    }

    func testBatchRenamerCaseTransformsAndExtensionPreservation() throws {
        let u1 = try writeTextFile("vacationPhoto_Summer2025.JPG", content: "img")

        let cases: [(BatchRenameCaseTransform, Bool, String)] = [
            (.lowercase, true, "vacationphoto_summer2025.JPG"),
            (.uppercase, true, "VACATIONPHOTO_SUMMER2025.JPG"),
            (.titleCase, true, "Vacation Photo Summer2025.JPG"),
            (.kebabCase, true, "vacation-photo-summer2025.JPG"),
            (.snakeCase, true, "vacation_photo_summer2025.JPG"),
            (.lowercase, false, "vacationphoto_summer2025.jpg")
        ]

        for (transform, preserveExt, expected) in cases {
            var rules = BatchRenameRules.default
            rules.caseTransform = transform
            rules.preserveExtension = preserveExt
            let plan = BatchFileRenamerEngine.preview(urls: [u1], rules: rules)
            XCTAssertEqual(plan.rows[0].afterName, expected, "Failed for \(transform.rawValue), preserveExt=\(preserveExt)")
        }
    }

    func testBatchRenamerSanitizesSlashesAndGuardsEmptyNamesAndCollisions() throws {
        let u1 = try writeTextFile("alpha.txt", content: "a")
        let u2 = try writeTextFile("beta.txt", content: "b")
        let existing = try writeTextFile("taken.txt", content: "existing")
        _ = existing

        // 1. Path traversal / slash sanitization
        var slashRules = BatchRenameRules.default
        slashRules.prefix = "../sub/"
        let slashPlan = BatchFileRenamerEngine.preview(urls: [u1], rules: slashRules)
        XCTAssertEqual(slashPlan.rows[0].afterName, "..-sub-alpha.txt")
        XCTAssertEqual(slashPlan.rows[0].status, .ready)

        // 2. Empty filename guard
        var emptyRules = BatchRenameRules.default
        emptyRules.findText = "alpha"
        emptyRules.replaceText = "   "
        let emptyPlan = BatchFileRenamerEngine.preview(urls: [u1], rules: emptyRules)
        XCTAssertTrue(emptyPlan.hasConflicts)
        XCTAssertEqual(emptyPlan.rows[0].status, .conflict(.emptyFilename))
        XCTAssertThrowsError(try BatchFileRenamerEngine.apply(plan: emptyPlan))

        // 3. Batch duplicate collision (case-insensitive)
        var dupRules = BatchRenameRules.default
        dupRules.findText = "alpha"
        dupRules.replaceText = "BETA"
        let dupPlan = BatchFileRenamerEngine.preview(urls: [u1, u2], rules: dupRules)
        XCTAssertTrue(dupPlan.hasConflicts)
        XCTAssertEqual(dupPlan.conflictCount, 2)
        XCTAssertThrowsError(try BatchFileRenamerEngine.apply(plan: dupPlan))

        // 4. Existing on-disk file collision
        var diskRules = BatchRenameRules.default
        diskRules.findText = "alpha"
        diskRules.replaceText = "taken"
        let diskPlan = BatchFileRenamerEngine.preview(urls: [u1], rules: diskRules)
        XCTAssertTrue(diskPlan.hasConflicts)
        XCTAssertEqual(diskPlan.rows[0].status, .conflict(.existingFileOnDisk("taken.txt")))
    }

    func testBatchRenamerSwapCycleSafetyUndoAndAppStateSync() throws {
        let aURL = try writeTextFile("a.txt", content: "ALPHA")
        let bURL = try writeTextFile("b.txt", content: "BETA")

        // Swap cycle: a.txt -> b.txt and b.txt -> a.txt simultaneously
        let swapMoves = [
            BatchRenameMove(from: aURL, to: bURL),
            BatchRenameMove(from: bURL, to: aURL)
        ]
        let executed = try BatchFileRenamerEngine.executeMoves(swapMoves)
        XCTAssertEqual(executed.count, 2)
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), "ALPHA")
        XCTAssertEqual(try String(contentsOf: aURL, encoding: .utf8), "BETA")

        let journal = BatchRenameUndoJournal(appliedMoves: executed, createdAt: Date())
        let reverted = try journal.undo()
        XCTAssertEqual(reverted.count, 2)
        XCTAssertEqual(try String(contentsOf: aURL, encoding: .utf8), "ALPHA")
        XCTAssertEqual(try String(contentsOf: bURL, encoding: .utf8), "BETA")

        // End-to-end preview + apply + AppState.applyRenamedURLs + undo
        let appState = makeIsolatedAppState()
        appState.droppedFiles = [makeDroppedFile(url: aURL, format: .txt)]

        var rules = BatchRenameRules.default
        rules.prefix = "renamed_"
        let plan = BatchFileRenamerEngine.preview(urls: appState.droppedFiles.map(\.url), rules: rules)
        let applyJournal = try BatchFileRenamerEngine.apply(plan: plan)
        appState.applyRenamedURLs(applyJournal.appliedMoves.map { (from: $0.from, to: $0.to) })

        let renamedURL = aURL.deletingLastPathComponent().appendingPathComponent("renamed_a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aURL.path))
        XCTAssertEqual(appState.droppedFiles.first?.url.lastPathComponent, "renamed_a.txt")

        let undoMoves = try applyJournal.undo()
        appState.applyRenamedURLs(undoMoves.map { (from: $0.from, to: $0.to) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: aURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedURL.path))
        XCTAssertEqual(appState.droppedFiles.first?.url.lastPathComponent, "a.txt")
    }

    // MARK: - 2. Real-World Goal Presets & SmartSuggestionEngine Tests

    func testSmartSuggestionEngineSurfacesGoalChipsAcrossAllCategories() throws {
        let pdfURL = try writeTextFile("doc.pdf", content: "%PDF-1.4\n%%EOF")
        let pngURL = sandbox.documentsURL.appendingPathComponent("pic.png")
        try writeTinyPNG(to: pngURL)
        let mp4URL = try writeTextFile("clip.mp4", content: "mp4")
        let docxURL = try writeTextFile("letter.docx", content: "docx")

        let pdfFile = makeDroppedFile(url: pdfURL, format: .pdf)
        let pngFile = makeDroppedFile(url: pngURL, format: .png)
        let mp4File = makeDroppedFile(url: mp4URL, format: .mp4)
        let docxFile = makeDroppedFile(url: docxURL, format: .docx)

        let pdfPlan = SmartSuggestionEngine.suggest(for: [pdfFile])
        XCTAssertEqual(pdfPlan.category, .pdf)
        XCTAssertTrue(pdfPlan.actions.contains(where: { $0.id == .goalWhatsAppDiscord10MB && $0.title == "WhatsApp / Discord (<10 MB)" && $0.isEnabled }))
        XCTAssertTrue(pdfPlan.actions.contains(where: { $0.id == .goalOfficialDocumentPDF5MB && $0.title == "Official Document PDF (<5 MB)" && $0.isEnabled }))
        XCTAssertTrue(pdfPlan.actions.contains(where: { $0.id == .goalStripPrivacyMetadata && $0.title == "Strip Privacy Metadata" && $0.isEnabled }))
        XCTAssertTrue(pdfPlan.actions.contains(where: { $0.id == .batchRename && $0.title == "Batch Rename..." && $0.isEnabled }))

        let imgPlan = SmartSuggestionEngine.suggest(for: [pngFile])
        XCTAssertEqual(imgPlan.category, .image)
        XCTAssertTrue(imgPlan.actions.contains(where: { $0.id == .goalWhatsAppDiscord10MB && $0.isEnabled }))
        XCTAssertTrue(imgPlan.actions.contains(where: { $0.id == .goalOfficialDocumentPDF5MB && $0.isEnabled }))
        XCTAssertTrue(imgPlan.actions.contains(where: { $0.id == .goalStripPrivacyMetadata && $0.isEnabled }))
        XCTAssertTrue(imgPlan.actions.contains(where: { $0.id == .batchRename && $0.isEnabled }))

        let avPlan = SmartSuggestionEngine.suggest(for: [mp4File])
        XCTAssertEqual(avPlan.category, .audioVideo)
        XCTAssertTrue(avPlan.actions.contains(where: { $0.id == .goalWhatsAppDiscord10MB && $0.isEnabled }))
        XCTAssertTrue(avPlan.actions.contains(where: { $0.id == .goalStripPrivacyMetadata && $0.isEnabled }))
        XCTAssertTrue(avPlan.actions.contains(where: { $0.id == .batchRename && $0.isEnabled }))

        let mixedPlan = SmartSuggestionEngine.suggest(for: [docxFile, pngFile])
        XCTAssertEqual(mixedPlan.category, .mixed)
        XCTAssertTrue(mixedPlan.actions.contains(where: { $0.id == .goalWhatsAppDiscord10MB && $0.isEnabled }))
        XCTAssertTrue(mixedPlan.actions.contains(where: { $0.id == .goalOfficialDocumentPDF5MB && $0.isEnabled }))
        XCTAssertTrue(mixedPlan.actions.contains(where: { $0.id == .goalStripPrivacyMetadata && $0.isEnabled }))
        XCTAssertTrue(mixedPlan.actions.contains(where: { $0.id == .batchRename && $0.isEnabled }))
        XCTAssertEqual(mixedPlan.actions.last?.id, .convertAll)
    }

    func testGoalPresetPreparationMapsOfficialPDFAndPrivacyStripOptions() throws {
        let appState = makeIsolatedAppState()
        let pngURL = sandbox.documentsURL.appendingPathComponent("scan.png")
        try writeTinyPNG(to: pngURL)
        let pdfURL = try writeTextFile("form.pdf", content: "%PDF-1.4\n%%EOF")

        let pngFile = makeDroppedFile(url: pngURL, format: .png)
        let pdfFile = makeDroppedFile(url: pdfURL, format: .pdf)
        appState.droppedFiles = [pngFile, pdfFile]

        let prepared = SmartBarActionExecutor.prepareOfficialDocumentPDF5MB(appState: appState)
        XCTAssertEqual(prepared.convertedToPDFCount, 1)
        XCTAssertEqual(prepared.pdfCompressionCount, 1)
        XCTAssertEqual(appState.droppedFiles[0].selectedOutputFormat, .pdf)
        XCTAssertEqual(appState.droppedFiles[0].options.targetFileSizeBytes, TargetSizeQuickPreset.mb5.targetBytes)
        XCTAssertEqual(appState.droppedFiles[1].options.targetFileSizeBytes, TargetSizeQuickPreset.mb5.targetBytes)

        let didPreparePrivacy = SmartBarActionExecutor.prepareStripPrivacyMetadataOptions(appState: appState)
        XCTAssertTrue(didPreparePrivacy)
        XCTAssertFalse(appState.droppedFiles[0].options.preserveMetadata)
        XCTAssertFalse(appState.droppedFiles[1].options.preserveMetadata)

        BatchRenamerSheetController.shared.open()
        XCTAssertTrue(BatchRenamerSheetController.shared.isPresented)
        BatchRenamerSheetController.shared.dismiss()
        XCTAssertFalse(BatchRenamerSheetController.shared.isPresented)
    }

    // MARK: - 3. DuplicateFileScannerEngine Tests

    func testDuplicateScannerGroupsBySHA256CalculatesReclaimableAndRespectsKeepPolicy() async throws {
        let scanRoot = sandbox.documentsURL.appendingPathComponent("DupScan", isDirectory: true)
        let subDir = scanRoot.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let middleDate = Date(timeIntervalSince1970: 1_710_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_720_000_000)

        let payloadA = String(repeating: "DUPLICATE-PAYLOAD-A-", count: 2000) // ~40 KB multi-chunk
        let payloadB = String(repeating: "DIFFERENT-PAYLOAD-B-", count: 2000) // same byte length, different content!
        XCTAssertEqual(payloadA.utf8.count, payloadB.utf8.count)

        let f1 = try writeTextFile("copy_old.txt", content: payloadA, in: scanRoot, modificationDate: olderDate)
        let f2 = try writeTextFile("copy_mid.txt", content: payloadA, in: subDir, modificationDate: middleDate)
        let f3 = try writeTextFile("copy_new.txt", content: payloadA, in: scanRoot, modificationDate: newerDate)
        let uniqueSameSize = try writeTextFile("unique_same_size.txt", content: payloadB, in: scanRoot, modificationDate: newerDate)
        _ = try writeTextFile(".DS_Store", content: payloadA, in: scanRoot)
        _ = try writeTextFile(".hidden_copy.txt", content: payloadA, in: scanRoot)

        let result = try await DuplicateFileScannerEngine.scan(
            directoryURL: scanRoot,
            options: DuplicateScanOptions(includeSubdirectories: true, skipHiddenFiles: true, minimumFileSizeBytes: 1, chunkSize: 4096)
        )

        XCTAssertEqual(result.groups.count, 1)
        let group = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(group.entries.count, 3)
        XCTAssertFalse(group.entries.contains(where: { $0.url == uniqueSameSize }))

        let expectedBytes = Int64(payloadA.utf8.count)
        let expectedSHA = SHA256.hash(data: Data(payloadA.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(group.fileSize, expectedBytes)
        XCTAssertEqual(group.sha256Hex, expectedSHA)
        XCTAssertEqual(group.reclaimableBytes, expectedBytes * 2)
        XCTAssertEqual(result.totalDuplicateFiles, 2)
        XCTAssertEqual(result.totalReclaimableBytes, expectedBytes * 2)

        // Keep Newest vs Keep Oldest
        XCTAssertEqual(group.keeperEntry(policy: .newest)?.url.standardizedFileURL, f3.standardizedFileURL)
        XCTAssertEqual(group.keeperEntry(policy: .oldest)?.url.standardizedFileURL, f1.standardizedFileURL)

        let trashNewestSet = DuplicateFileScannerEngine.selectDuplicatesToTrash(in: result.groups, policy: .newest)
        XCTAssertEqual(trashNewestSet, Set([f1.standardizedFileURL, f2.standardizedFileURL]))

        // Non-recursive scan skips Nested/
        let topOnly = try await DuplicateFileScannerEngine.scan(
            directoryURL: scanRoot,
            options: DuplicateScanOptions(includeSubdirectories: false)
        )
        XCTAssertEqual(topOnly.groups.first?.entries.count, 2)
    }

    func testDuplicateScannerRefusesToTrashLastCopyAndTrashesSafely() async throws {
        let scanRoot = sandbox.documentsURL.appendingPathComponent("TrashSafety", isDirectory: true)
        let fakeTrashDir = sandbox.rootURL.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrashDir, withIntermediateDirectories: true)

        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_720_000_000)
        let copy1 = try writeTextFile("one.bin", content: "SAME-BYTES-12345", in: scanRoot, modificationDate: oldDate)
        let copy2 = try writeTextFile("two.bin", content: "SAME-BYTES-12345", in: scanRoot, modificationDate: newDate)

        let scanResult = try await DuplicateFileScannerEngine.scan(directoryURL: scanRoot)
        XCTAssertEqual(scanResult.groups.count, 1)

        // Attempt to trash ALL copies in the group -> must throw and invoke handler 0 times
        let handlerCallCount = OSAllocatedUnfairLock(initialState: 0)
        XCTAssertThrowsError(
            try DuplicateFileScannerEngine.trashDuplicates(
                in: scanResult.groups,
                selectedURLs: Set([copy1, copy2]),
                trashHandler: { url in
                    handlerCallCount.withLock { $0 += 1 }
                    return url
                }
            )
        ) { error in
            XCTAssertEqual(error as? DuplicateScannerError, .cannotTrashAllCopiesInGroup(scanResult.groups[0].sha256Hex))
        }
        XCTAssertEqual(handlerCallCount.withLock { $0 }, 0)

        // Safe trash of policy-selected duplicates (keeps newest copy2, trashes copy1)
        let toTrash = DuplicateFileScannerEngine.selectDuplicatesToTrash(in: scanResult.groups, policy: .newest)
        let appState = makeIsolatedAppState()
        appState.droppedFiles = [
            makeDroppedFile(url: copy1, format: .txt),
            makeDroppedFile(url: copy2, format: .txt)
        ]

        let trashResult = try DuplicateFileScannerEngine.trashDuplicates(
            in: scanResult.groups,
            selectedURLs: toTrash,
            trashHandler: { url in
                let dest = fakeTrashDir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        )

        XCTAssertEqual(trashResult.trashedURLs.map(\.standardizedFileURL), [copy1.standardizedFileURL])
        XCTAssertEqual(trashResult.reclaimedBytes, Int64("SAME-BYTES-12345".utf8.count))
        XCTAssertTrue(trashResult.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy2.path))

        appState.removeFiles(matchingURLs: Set(trashResult.trashedURLs), recordUndo: false)
        XCTAssertEqual(appState.droppedFiles.map(\.url.standardizedFileURL), [copy2.standardizedFileURL])
    }

    // MARK: - 4. LC-019 (820x580) Layout & Re-Entrant State Invariants

    func testNewSheetsAndFileListLayoutCleanlyWithin820x580() throws {
        let appState = makeIsolatedAppState()
        let zipURL = try writeTextFile("bundle.zip", content: "PK\u{03}\u{04}stub")
        let pngURL = sandbox.documentsURL.appendingPathComponent("sample.png")
        try writeTinyPNG(to: pngURL)
        appState.droppedFiles = [
            makeDroppedFile(url: pngURL, format: .png),
            makeDroppedFile(url: zipURL, format: .zip)
        ]

        let batchController = BatchRenamerSheetController(isPresented: true)
        let batchFitted = hostAndMeasure(
            BatchRenamerSheetView(controller: batchController).environmentObject(appState),
            size: CGSize(width: 760, height: 520),
            appState: appState,
            contextName: "BatchRenamerSheetView"
        )
        XCTAssertLessThanOrEqual(batchFitted.width, 820)
        XCTAssertLessThanOrEqual(batchFitted.height, 580)

        // DuplicateFinderSheetView MUST instantiate cleanly without @EnvironmentObject
        let dupController = DuplicateFinderSheetController(isPresented: true, initialDirectoryURL: sandbox.documentsURL)
        let dupFitted = hostAndMeasure(
            DuplicateFinderSheetView(controller: dupController),
            size: CGSize(width: 760, height: 520),
            appState: appState,
            contextName: "DuplicateFinderSheetView"
        )
        XCTAssertLessThanOrEqual(dupFitted.width, 820)
        XCTAssertLessThanOrEqual(dupFitted.height, 580)

        let fileListFitted = hostAndMeasure(
            FileListView().environmentObject(appState),
            size: CGSize(width: 820, height: 580),
            appState: appState,
            contextName: "FileListView.M14A"
        )
        XCTAssertLessThanOrEqual(fileListFitted.width, 820)
    }
}
