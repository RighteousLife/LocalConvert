import XCTest
import Foundation
import CoreGraphics
@testable import LocalConvert

@MainActor
final class Milestone5WorkspaceReliabilityTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUp() async throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "M5Reliability-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        AppSettings.shared.saveConversionHistory = true
        AppSettings.shared.historyAutoRemove = .never
        StructuredDiagnostics.clearRecentEvents()
        OutputReservationCoordinator.clearReservedOutputURLs()
    }

    override func tearDown() async throws {
        OutputReservationCoordinator.clearReservedOutputURLs()
        AppStoragePaths.clearTestOverrides()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    // MARK: - Helpers

    private func ensureEnginesRegistered() -> ConversionRegistry {
        let registry = ConversionRegistry.shared
        if registry.registeredEngines.isEmpty {
            registry.register(engine: ImageConversionEngine())
            registry.register(engine: TextConversionEngine())
            registry.register(engine: PDFConversionEngine())
            registry.register(engine: MediaConversionEngine())
            registry.register(engine: SubtitleConversionEngine())
            registry.register(engine: ArchiveConversionEngine())
            registry.register(engine: OfficeConversionEngine())
            registry.register(engine: PDFToolboxEngine())
        }
        return registry
    }

    private func makeTwoPagePDF(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 120, height: 120)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "M5Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF CGContext"])
        }
        for _ in 0..<2 {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0))
            ctx.fill(box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval = 8.0,
        pollIntervalNs: UInt64 = 25_000_000,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        return condition()
    }

    private final class WarningBox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func append(_ msg: String) {
            lock.withLock {
                messages.append(msg)
            }
        }

        func snapshot() -> [String] {
            lock.withLock { messages }
        }
    }

    // MARK: - LC-011: HistoryManager Quarantine & Non-Fatal Persistence Errors

    func testHistoryManagerQuarantinesCorruptFileWithTimestampedNamesWithoutOverwriting() throws {
        let historyFile = sandbox.historyFileURL
        let parentDir = historyFile.deletingLastPathComponent()
        let firstPayload = Data("{corrupt-first-payload".utf8)
        try firstPayload.write(to: historyFile)

        let mgr1 = HistoryManager(fileURL: historyFile)
        XCTAssertTrue(mgr1.items.isEmpty)
        XCTAssertNotNil(mgr1.lastPersistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFile.path), "Corrupt history.json must be quarantined out of primary path")

        let firstQuarantined = try FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.corrupted.") && $0.pathExtension == "json" }
        XCTAssertEqual(firstQuarantined.count, 1)
        XCTAssertEqual(try Data(contentsOf: firstQuarantined[0]), firstPayload)

        // Second corruption within the same second must create a distinct timestamped quarantine file instead of overwriting
        let secondPayload = Data("{corrupt-second-payload".utf8)
        try secondPayload.write(to: historyFile)

        let mgr2 = HistoryManager(fileURL: historyFile)
        XCTAssertTrue(mgr2.items.isEmpty)
        XCTAssertNotNil(mgr2.lastPersistenceError)

        let allQuarantined = try FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.corrupted.") && $0.pathExtension == "json" }
        XCTAssertEqual(allQuarantined.count, 2)
        let payloads = Set(try allQuarantined.map { try Data(contentsOf: $0) })
        XCTAssertEqual(payloads, Set([firstPayload, secondPayload]))

        let diagEvents = StructuredDiagnostics.recentEvents(category: .fileAccess, severity: .internalError)
        XCTAssertTrue(diagEvents.contains { $0.stage == "loadHistory" })
    }

    func testHistoryManagerSurfacesNonFatalWriteErrorAndClearsOnRecovery() throws {
        // Place a regular file where the parent directory would be so directory/file write deterministically fails
        let blockerFile = sandbox.temporaryURL.appendingPathComponent("not_a_directory")
        try Data("blocker".utf8).write(to: blockerFile)
        let unwritableHistoryURL = blockerFile.appendingPathComponent("history.json")

        let failingMgr = HistoryManager(fileURL: unwritableHistoryURL)
        XCTAssertNil(failingMgr.lastPersistenceError)

        failingMgr.addEntry(ConversionHistoryItem(
            inputFilename: "sample.png",
            inputFormatName: "PNG",
            outputFilename: "sample.jpg",
            outputFormatName: "JPEG",
            status: .completed
        ))

        XCTAssertEqual(failingMgr.items.count, 1)
        XCTAssertNotNil(failingMgr.lastPersistenceError)
        XCTAssertTrue(StructuredDiagnostics.recentEvents(category: .fileAccess, severity: .internalError).contains { $0.stage == "saveHistory" })

        failingMgr.clearPersistenceError()
        XCTAssertNil(failingMgr.lastPersistenceError)

        // Valid store clears any prior error on successful write
        let validMgr = HistoryManager(fileURL: sandbox.historyFileURL)
        validMgr.addEntry(ConversionHistoryItem(
            inputFilename: "ok.png",
            inputFormatName: "PNG",
            outputFilename: "ok.jpg",
            outputFormatName: "JPEG",
            status: .completed
        ))
        XCTAssertNil(validMgr.lastPersistenceError)
    }

    // MARK: - LC-011: ConversionHistoryItem Backward Compatibility & Multi-Output

    func testConversionHistoryItemDecodesLegacyJSONAndRoundTripsAdditionalOutputPaths() throws {
        let legacyID = UUID()
        let legacyJSON: [String: Any] = [
            "id": legacyID.uuidString,
            "inputFilename": "legacy.pdf",
            "inputFormatName": "PDF",
            "outputFilename": "legacy.png",
            "outputFormatName": "PNG",
            "date": Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate,
            "status": "completed",
            "outputURLPath": "/tmp/legacy.png"
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decodedLegacy = try JSONDecoder().decode(ConversionHistoryItem.self, from: legacyData)

        XCTAssertEqual(decodedLegacy.id, legacyID)
        XCTAssertNil(decodedLegacy.additionalOutputURLPaths)
        XCTAssertTrue(decodedLegacy.additionalOutputURLs.isEmpty)
        XCTAssertEqual(decodedLegacy.allOutputURLs.map(\.path), ["/tmp/legacy.png"])

        let multiItem = ConversionHistoryItem(
            inputFilename: "doc.pdf",
            inputFormatName: "PDF",
            outputFilename: "doc-1.png",
            outputFormatName: "PNG",
            status: .completed,
            outputURLPath: "/tmp/doc-1.png",
            additionalOutputURLPaths: ["/tmp/doc-2.png", "/tmp/doc-3.png"]
        )
        let encoded = try JSONEncoder().encode(multiItem)
        let decodedMulti = try JSONDecoder().decode(ConversionHistoryItem.self, from: encoded)

        XCTAssertEqual(decodedMulti.additionalOutputURLPaths, ["/tmp/doc-2.png", "/tmp/doc-3.png"])
        XCTAssertEqual(
            decodedMulti.allOutputURLs.map(\.path),
            ["/tmp/doc-1.png", "/tmp/doc-2.png", "/tmp/doc-3.png"]
        )
    }

    // MARK: - LC-011: PresetStore Non-Fatal Write Error Surfacing

    func testPresetStoreSurfacesNonFatalWriteErrorWithoutCrashing() throws {
        let blockerFile = sandbox.temporaryURL.appendingPathComponent("presets_blocker")
        try Data("blocker".utf8).write(to: blockerFile)
        let unwritablePresetsURL = blockerFile.appendingPathComponent("presets.json")

        let store = PresetStore(fileURL: unwritablePresetsURL)
        XCTAssertFalse(store.userPresets.isEmpty, "Defaults should still load in memory when initial write fails")
        XCTAssertNotNil(store.lastPersistenceError)

        store.clearPersistenceError()
        XCTAssertNil(store.lastPersistenceError)

        let custom = SavedPreset(name: "Custom Fail Test", targetFormat: .webp)
        store.save(custom)
        XCTAssertNotNil(store.lastPersistenceError)
        XCTAssertFalse(store.persist())
        XCTAssertTrue(StructuredDiagnostics.recentEvents(category: .fileAccess, severity: .internalError).contains { $0.stage == "persistPresets" })

        let validStore = PresetStore(fileURL: sandbox.presetsFileURL)
        XCTAssertNil(validStore.lastPersistenceError)
        XCTAssertTrue(validStore.persist())
        XCTAssertNil(validStore.lastPersistenceError)
    }

    // MARK: - LC-010 & LC-011: ConversionManager Empty Input Guard & Multi-Output History Wiring

    func testConversionManagerGuardsEmptyInputURLsWithoutCrash() async {
        let registry = ensureEnginesRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let manager = ConversionManager(registry: registry, historyManager: history)

        let emptyJob = ConversionJob(
            inputURLs: [],
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: sandbox.outputsURL
        )
        XCTAssertNil(emptyJob.inputURL)
        XCTAssertEqual(emptyJob.sourceFilename, "Unknown")

        let status: ConversionJobStatus = await withCheckedContinuation { continuation in
            manager.submit(job: emptyJob) { finalStatus in
                continuation.resume(returning: finalStatus)
            }
        }

        if case .failed(let error) = status, case .invalidInput = error {
            // expected clean validation failure
        } else {
            XCTFail("Expected .failed(.invalidInput) for empty inputURLs, got \(status)")
        }

        XCTAssertNil(manager.sizeComparison(for: emptyJob.id))
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.items.first?.status, .failed)
        XCTAssertEqual(history.items.first?.inputFilename, "Unknown")
    }

    func testConversionManagerWiresMultiOutputPathsIntoHistoryItem() async throws {
        let registry = ensureEnginesRegistered()
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        let manager = ConversionManager(registry: registry, historyManager: history)

        let pdfURL = sandbox.documentsURL.appendingPathComponent("two_pages.pdf")
        try makeTwoPagePDF(at: pdfURL)

        let job = ConversionJob(
            inputURLs: [pdfURL],
            inputFormat: .pdf,
            outputFormat: .png,
            outputDirectory: sandbox.outputsURL
        )

        let status: ConversionJobStatus = await withCheckedContinuation { continuation in
            manager.submit(job: job) { finalStatus in
                continuation.resume(returning: finalStatus)
            }
        }

        guard case .completed(let result) = status else {
            return XCTFail("Expected multi-page PDF->PNG job to complete, got \(status)")
        }
        XCTAssertEqual(result.additionalOutputURLs.count, 1)

        let historyEntry = try XCTUnwrap(history.items.first)
        XCTAssertEqual(historyEntry.outputURLPath, result.outputURL.path)
        XCTAssertEqual(historyEntry.additionalOutputURLPaths, result.additionalOutputURLs.map(\.path))
        XCTAssertEqual(historyEntry.allOutputURLs.count, 2)
    }

    // MARK: - LC-017: WatchFolderMonitor Truncation Warning

    func testWatchFolderMonitorSurfacesTruncationWarningAtMaxFilesLimit() async throws {
        let inboxDir = sandbox.documentsURL.appendingPathComponent("TruncateInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        for idx in 0..<502 {
            let fileURL = inboxDir.appendingPathComponent(String(format: "item_%03d.txt", idx))
            try Data("x".utf8).write(to: fileURL)
        }

        let warnings = WarningBox()
        let monitor = WatchFolderMonitor(
            directoryURL: inboxDir,
            includeSubdirectories: false,
            onFilesChanged: { _ in },
            onError: { _ in },
            onWarning: { msg in warnings.append(msg) }
        )

        let truncatedScan = monitor.scanVisibleFilesWithStatus(excludedPrefixes: [], maxFiles: 500)
        XCTAssertEqual(truncatedScan.urls.count, 500)
        XCTAssertTrue(truncatedScan.wasTruncated)
        XCTAssertNotNil(truncatedScan.warningMessage)
        XCTAssertEqual(warnings.snapshot().count, 1)

        let fullScan = monitor.scanVisibleFilesWithStatus(excludedPrefixes: [], maxFiles: 505)
        XCTAssertEqual(fullScan.urls.count, 502)
        XCTAssertFalse(fullScan.wasTruncated)
        XCTAssertNil(fullScan.warningMessage)

        // Verify WatchFolderManager surfaces & clears scan warning via performRescan
        let registry = ensureEnginesRegistered()
        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let presetStore = PresetStore(fileURL: sandbox.presetsFileURL)
        let presetMgr = PresetManager(store: presetStore, undoCoordinator: undoCoord)
        let txtPreset = SavedPreset(
            name: "Watch Truncation Test",
            targetFormat: .pdf,
            sourceCategoryConstraint: .document
        )
        presetMgr.save(preset: txtPreset)

        let wfStore = WatchFolderStore(fileURL: sandbox.watchFoldersFileURL)
        let convMgr = ConversionManager(registry: registry, historyManager: HistoryManager(fileURL: sandbox.historyFileURL))
        let convQueue = ConversionQueue(conversionManager: convMgr, undoCoordinator: undoCoord)
        let wfManager = WatchFolderManager(
            store: wfStore,
            presetManager: presetMgr,
            conversionManager: convMgr,
            conversionQueue: convQueue,
            defaultOutputLocationProvider: { (.sameFolder, nil) }
        )
        defer { wfManager.stopAll() }

        let rule = WatchFolderRule(
            name: "Truncate Rule",
            inputDirectoryPath: inboxDir.path,
            presetID: txtPreset.id,
            isEnabled: true,
            isPaused: false,
            outputDestination: .defaultSubfolder
        )
        XCTAssertTrue(wfManager.addRule(rule).isValid)

        wfManager.performRescan(id: rule.id, maxFiles: 10)
        let gotWarning = await waitUntil {
            wfManager.scanWarningsByRuleID[rule.id] != nil
        }
        XCTAssertTrue(gotWarning)
        wfManager.clearScanWarning(for: rule.id)
        XCTAssertNil(wfManager.scanWarningsByRuleID[rule.id])
    }

    // MARK: - LC-017: WatchFolderManager Failed Output Bookmark Flagging

    func testWatchFolderManagerFlagsFailedOutputBookmarkAndAcceptsValidBookmark() throws {
        let registry = ensureEnginesRegistered()
        let inboxDir = sandbox.documentsURL.appendingPathComponent("BMInbox", isDirectory: true)
        let customOutDir = sandbox.outputsURL.appendingPathComponent("BMOutput", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customOutDir, withIntermediateDirectories: true)

        let undoCoord = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let presetStore = PresetStore(fileURL: sandbox.presetsFileURL)
        let presetMgr = PresetManager(store: presetStore, undoCoordinator: undoCoord)
        let preset = SavedPreset(name: "BM JPG", targetFormat: .jpg, sourceCategoryConstraint: .image)
        presetMgr.save(preset: preset)

        let wfStore = WatchFolderStore(fileURL: sandbox.watchFoldersFileURL)
        let convMgr = ConversionManager(registry: registry, historyManager: HistoryManager(fileURL: sandbox.historyFileURL))
        let convQueue = ConversionQueue(conversionManager: convMgr, undoCoordinator: undoCoord)
        let wfManager = WatchFolderManager(
            store: wfStore,
            presetManager: presetMgr,
            conversionManager: convMgr,
            conversionQueue: convQueue,
            defaultOutputLocationProvider: { (.sameFolder, nil) }
        )
        defer { wfManager.stopAll() }

        let badBookmarkRule = WatchFolderRule(
            name: "Bad Output Bookmark",
            inputDirectoryPath: inboxDir.path,
            presetID: preset.id,
            isEnabled: true,
            outputDestination: .customDirectory(
                path: customOutDir.path,
                bookmarkData: Data("invalid-bookmark-payload".utf8)
            )
        )
        XCTAssertTrue(wfManager.addRule(badBookmarkRule).isValid)

        let flaggedRule = try XCTUnwrap(wfManager.rules.first { $0.id == badBookmarkRule.id })
        XCTAssertTrue(flaggedRule.lastStatus.isError, "Failed output bookmark resolution must flag the rule with an error status")
        XCTAssertTrue(flaggedRule.lastErrorMessage?.contains(customOutDir.lastPathComponent) ?? false)

        if let validBookmark = WatchFolderBookmarkManager.createBookmark(for: customOutDir) {
            var repaired = flaggedRule
            repaired.outputDestination = .customDirectory(path: customOutDir.path, bookmarkData: validBookmark)
            XCTAssertTrue(wfManager.updateRule(repaired).isValid)

            let updatedRule = try XCTUnwrap(wfManager.rules.first { $0.id == badBookmarkRule.id })
            XCTAssertEqual(updatedRule.lastStatus, .active)
            XCTAssertNil(updatedRule.lastErrorMessage)
        }
    }

    // MARK: - LC-017: OutputReservationCoordinator 240 UTF-8 Byte Clamping

    func testOutputReservationCoordinatorClampsFilenamesTo240UTF8BytesPreservingExtensionAndCounter() throws {
        let outDir = sandbox.outputsURL.appendingPathComponent("ClampOut", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 1. Long ASCII base name + collision counter
        let longASCIIBase = String(repeating: "a", count: 310)
        let firstURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: outDir,
            baseName: longASCIIBase,
            extension: "png",
            policy: .createUnique
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(firstURL) }

        XCTAssertLessThanOrEqual(firstURL.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(firstURL.pathExtension, "png")

        let secondURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: outDir,
            baseName: longASCIIBase,
            extension: "png",
            policy: .createUnique
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(secondURL) }

        XCTAssertLessThanOrEqual(secondURL.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(secondURL.pathExtension, "png")
        XCTAssertTrue(secondURL.deletingPathExtension().lastPathComponent.hasSuffix(" (1)"))
        XCTAssertNotEqual(firstURL.lastPathComponent, secondURL.lastPathComponent)

        // 2. Multi-byte UTF-8 characters (4-byte emoji + 3-byte CJK) preserve valid UTF-8, extension, page suffix, and counter
        let multiByteBase = String(repeating: "😀漢", count: 60) // 60 * 7 = 420 UTF-8 bytes
        let inputURL = sandbox.documentsURL.appendingPathComponent("\(multiByteBase).pdf")

        let page2URL = try OutputReservationCoordinator.reserveMultiPageOutputURL(
            for: inputURL,
            pageIndex: 1,
            totalPages: 5,
            format: .png,
            in: outDir
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(page2URL) }

        XCTAssertLessThanOrEqual(page2URL.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(page2URL.pathExtension, "png")
        XCTAssertTrue(page2URL.deletingPathExtension().lastPathComponent.hasSuffix("-2"))

        // 3. uniqueOutputURL with pre-existing collision file on disk
        let emojiUnique1 = OutputReservationCoordinator.uniqueOutputURL(
            directory: outDir,
            baseName: multiByteBase,
            extension: "jpg"
        )
        XCTAssertLessThanOrEqual(emojiUnique1.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(emojiUnique1.pathExtension, "jpg")
        try Data("existing".utf8).write(to: emojiUnique1)

        let emojiUnique2 = OutputReservationCoordinator.uniqueOutputURL(
            directory: outDir,
            baseName: multiByteBase,
            extension: "jpg"
        )
        XCTAssertLessThanOrEqual(emojiUnique2.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(emojiUnique2.pathExtension, "jpg")
        XCTAssertTrue(emojiUnique2.deletingPathExtension().lastPathComponent.hasSuffix(" (1)"))

        // 4. Atomic moveOrReplaceTempFile succeeds even when destination filename is at the 240-byte limit
        let tempSrc = sandbox.temporaryURL.appendingPathComponent("stage_src.jpg")
        try Data("new-payload".utf8).write(to: tempSrc)
        let published = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempSrc,
            to: emojiUnique1,
            policy: .overwrite
        )
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "new-payload")

        // Also verify sibling .stage- path succeeds when forced off same-volume fast path
        let tempSrc2 = sandbox.temporaryURL.appendingPathComponent("stage_src2.jpg")
        try Data("cross-volume-payload".utf8).write(to: tempSrc2)
        let liveOps = OutputReservationCoordinator.AtomicPublishFileOperations.live
        let crossVolumeOps = OutputReservationCoordinator.AtomicPublishFileOperations(
            fileExists: liveOps.fileExists,
            isSameVolume: { _, _ in false },
            copyItem: liveOps.copyItem,
            moveItem: liveOps.moveItem,
            replaceItemAt: liveOps.replaceItemAt,
            removeItem: liveOps.removeItem
        )
        let publishedCross = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempSrc2,
            to: emojiUnique1,
            policy: .overwrite,
            operations: crossVolumeOps
        )
        XCTAssertEqual(try String(contentsOf: publishedCross, encoding: .utf8), "cross-volume-payload")
    }
}
