import XCTest
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import LocalConvert

@MainActor
final class MenuBarDropToConvertTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUp() async throws {
        continueAfterFailure = false
        ConversionManager.clearReservedOutputURLs()
        sandbox = try TestSandbox(runID: "MenuBarDrop-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
        MenuBarManager.shared.cancelStagedDrop()
        ConversionManager.clearReservedOutputURLs()
        AppStoragePaths.clearTestOverrides()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
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

    @discardableResult
    private func writeTinyPNG(to url: URL, width: Int = 16, height: Int = 16) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 180, count: width * height * 4)
        for idx in stride(from: 3, to: pixels.count, by: 4) {
            pixels[idx] = 255
        }
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let cg = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "MenuBarDropToConvertTests", code: 1)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    @discardableResult
    private func writeTinyJPEG(to url: URL, width: Int = 16, height: Int = 16) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 120, count: width * height * 4)
        for idx in stride(from: 3, to: pixels.count, by: 4) {
            pixels[idx] = 255
        }
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ),
        let cg = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "MenuBarDropToConvertTests", code: 2)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    @discardableResult
    private func writeTinyPDF(to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "MenuBarDropToConvertTests", code: 3)
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(.white)
        ctx.fill(box)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    // MARK: - 1. Dropped-File Validation

    func testValidateDroppedURLsAcceptsValidFilesAndDeduplicates() throws {
        _ = makeIsolatedAppState()

        let png1 = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("photo1.png"))
        let png2 = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("photo2.png"))
        let pdf = try writeTinyPDF(to: sandbox.documentsURL.appendingPathComponent("doc.pdf"))

        let result = MenuBarDropSession.validateDroppedURLs([png1, png1, png2, pdf])

        XCTAssertEqual(
            result.validURLs.map(\.standardizedFileURL),
            [png1.standardizedFileURL, png2.standardizedFileURL, pdf.standardizedFileURL]
        )
        XCTAssertTrue(result.rejectedEntries.isEmpty)
        XCTAssertTrue(result.hasValidFiles)
        XCTAssertFalse(result.hasRejectedFiles)
    }

    func testValidateDroppedURLsRejectsDirectoriesSymlinksSpecialFilesUnreadableAndUnsupported() throws {
        _ = makeIsolatedAppState()

        let validPNG = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("valid.png"))

        // Directory
        let folder = sandbox.documentsURL.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Direct symlink
        let directSymlink = sandbox.documentsURL.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: directSymlink, withDestinationURL: validPNG)

        // Dangling symlink
        let danglingSymlink = sandbox.documentsURL.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(
            at: danglingSymlink,
            withDestinationURL: sandbox.documentsURL.appendingPathComponent("nonexistent.png")
        )

        // Ancestor symlink
        let realSubdir = sandbox.documentsURL.appendingPathComponent("real_subdir", isDirectory: true)
        let insideFile = try writeTinyPNG(to: realSubdir.appendingPathComponent("inside.png"))
        let linkedSubdir = sandbox.documentsURL.appendingPathComponent("linked_subdir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedSubdir, withDestinationURL: realSubdir)
        let viaLinkedDir = linkedSubdir.appendingPathComponent(insideFile.lastPathComponent)

        // FIFO special file (non-regular)
        let fifoURL = sandbox.documentsURL.appendingPathComponent("pipe.png")
        XCTAssertEqual(Darwin.mkfifo(fifoURL.path, 0o600), 0)

        // Missing file
        let missingURL = sandbox.documentsURL.appendingPathComponent("missing.png")

        // Unsupported file format
        let unsupportedURL = sandbox.documentsURL.appendingPathComponent("mystery.unknownbin")
        try Data([0x00, 0xFF, 0x13, 0x37]).write(to: unsupportedURL)

        // Non-file URL
        let webURL = URL(string: "https://example.com/photo.png")!

        var candidates: [URL] = [
            validPNG,
            folder,
            directSymlink,
            danglingSymlink,
            viaLinkedDir,
            fifoURL,
            missingURL,
            unsupportedURL,
            webURL
        ]

        // Unreadable file (when running as non-root)
        let unreadableURL = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("secret.png"))
        let checkUnreadable = Darwin.geteuid() != 0
        if checkUnreadable {
            XCTAssertEqual(Darwin.chmod(unreadableURL.path, 0o000), 0)
            candidates.append(unreadableURL)
        }
        defer {
            if checkUnreadable {
                _ = Darwin.chmod(unreadableURL.path, 0o644)
            }
        }

        let result = MenuBarDropSession.validateDroppedURLs(candidates)

        XCTAssertEqual(result.validURLs.map(\.standardizedFileURL), [validPNG.standardizedFileURL])
        let expectedRejectedCount = checkUnreadable ? 9 : 8
        XCTAssertEqual(result.rejectedEntries.count, expectedRejectedCount)
        XCTAssertFalse(result.validURLs.contains(folder.standardizedFileURL))
        XCTAssertFalse(result.validURLs.contains(directSymlink.standardizedFileURL))
        XCTAssertFalse(result.validURLs.contains(danglingSymlink.standardizedFileURL))
        XCTAssertFalse(result.validURLs.contains(viaLinkedDir.standardizedFileURL))
        XCTAssertFalse(result.validURLs.contains(fifoURL.standardizedFileURL))
        XCTAssertFalse(result.validURLs.contains(missingURL.standardizedFileURL))
        XCTAssertFalse(result.validURLs.contains(unsupportedURL.standardizedFileURL))
        if checkUnreadable {
            XCTAssertFalse(result.validURLs.contains(unreadableURL.standardizedFileURL))
        }
    }

    func testAllInvalidDropStagesEmptyFilesAndPopulatesRejectedEntries() throws {
        _ = makeIsolatedAppState()

        let folder = sandbox.documentsURL.appendingPathComponent("OnlyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let session = MenuBarDropSession()
        let result = session.stageDroppedURLs([folder], presets: SavedPreset.defaultTemplates)

        XCTAssertFalse(result.hasValidFiles)
        XCTAssertTrue(result.hasRejectedFiles)
        XCTAssertTrue(session.stagedFileURLs.isEmpty)
        XCTAssertFalse(session.hasStagedFiles)
        XCTAssertTrue(session.compatiblePresets.isEmpty)
        XCTAssertEqual(session.rejectedEntries.count, 1)
    }

    // MARK: - 2. Compatible Preset Filtering

    func testFilterCompatiblePresetsForSingleAndMixedBatches() throws {
        _ = makeIsolatedAppState()
        let presets = SavedPreset.defaultTemplates

        let png = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("sample.png"))
        let jpg = try writeTinyJPEG(to: sandbox.documentsURL.appendingPathComponent("photo.jpg"))
        let pdf = try writeTinyPDF(to: sandbox.documentsURL.appendingPathComponent("document.pdf"))

        // Single PNG: image presets + Document to PDF; excludes video/audio/PDF-only presets.
        let pngMatches = MenuBarDropSession.filterCompatiblePresets(for: [png], presets: presets)
        let pngPresetNames = Set(pngMatches.map(\.preset.name))
        XCTAssertTrue(pngPresetNames.contains("Web-Optimized WebP"))
        XCTAssertTrue(pngPresetNames.contains("High-Quality JPEG"))
        XCTAssertTrue(pngPresetNames.contains("Document to PDF"))
        XCTAssertFalse(pngPresetNames.contains("Universal MP4 Video"))
        XCTAssertFalse(pngPresetNames.contains("Extract MP3 Audio"))
        XCTAssertFalse(pngPresetNames.contains("PDF to Word (DOCX)"))
        XCTAssertTrue(pngMatches.allSatisfy(\.isFullyCompatible))

        // Single PDF: PDF to Word (DOCX) only; excludes Document to PDF (same format) and image/video presets.
        let pdfMatches = MenuBarDropSession.filterCompatiblePresets(for: [pdf], presets: presets)
        let pdfPresetNames = Set(pdfMatches.map(\.preset.name))
        XCTAssertTrue(pdfPresetNames.contains("PDF to Word (DOCX)"))
        XCTAssertFalse(pdfPresetNames.contains("Document to PDF"))
        XCTAssertFalse(pdfPresetNames.contains("Web-Optimized WebP"))
        XCTAssertFalse(pdfPresetNames.contains("Universal MP4 Video"))

        // Multiple images [png, jpg]: fully compatible presets sort ahead of partial presets (High-Quality JPEG skips jpg->jpg).
        let multiImageMatches = MenuBarDropSession.filterCompatiblePresets(for: [png, jpg], presets: presets)
        let webpMatch = try XCTUnwrap(multiImageMatches.first { $0.preset.name == "Web-Optimized WebP" })
        let jpegMatch = try XCTUnwrap(multiImageMatches.first { $0.preset.name == "High-Quality JPEG" })
        XCTAssertTrue(webpMatch.isFullyCompatible)
        XCTAssertEqual(webpMatch.compatibleCount, 2)
        XCTAssertFalse(jpegMatch.isFullyCompatible)
        XCTAssertEqual(jpegMatch.compatibleCount, 1)
        let webpIdx = try XCTUnwrap(multiImageMatches.firstIndex { $0.preset.name == "Web-Optimized WebP" })
        let jpegIdx = try XCTUnwrap(multiImageMatches.firstIndex { $0.preset.name == "High-Quality JPEG" })
        XCTAssertLessThan(webpIdx, jpegIdx)

        // Mixed [png, pdf]: partial matches included, video/audio presets excluded.
        let mixedMatches = MenuBarDropSession.filterCompatiblePresets(for: [png, pdf], presets: presets)
        let mixedNames = Set(mixedMatches.map(\.preset.name))
        XCTAssertTrue(mixedNames.contains("Web-Optimized WebP"))
        XCTAssertTrue(mixedNames.contains("Document to PDF"))
        XCTAssertTrue(mixedNames.contains("PDF to Word (DOCX)"))
        XCTAssertFalse(mixedNames.contains("Universal MP4 Video"))
        XCTAssertTrue(mixedMatches.allSatisfy { $0.compatibleCount == 1 && $0.totalCount == 2 && !$0.isFullyCompatible })
    }

    // MARK: - 3. Preset Execution, Convert Tab Routing & Cancel Cleanup

    func testExecutePresetEnqueuesJobAndClearsStagedDrop() async throws {
        let appState = makeIsolatedAppState()
        defer { appState.cancelConversion() }

        let png = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("convert_via_preset.png"))
        let webpPreset = try XCTUnwrap(SavedPreset.defaultTemplates.first { $0.name == "Web-Optimized WebP" })

        let session = MenuBarDropSession()
        session.stageDroppedURLs([png], presets: SavedPreset.defaultTemplates)
        XCTAssertTrue(session.hasStagedFiles)
        XCTAssertTrue(session.isPopoverPresented)
        XCTAssertEqual(session.stagedFilenames, ["convert_via_preset.png"])

        let report = try XCTUnwrap(session.executePreset(webpPreset, appState: appState))
        XCTAssertEqual(report.enqueuedJobs.count, 1)
        let job = try XCTUnwrap(report.enqueuedJobs.first)
        XCTAssertEqual(job.outputFormat, .webp)
        XCTAssertEqual(job.presetName, webpPreset.name)
        XCTAssertEqual(job.source, .manual)
        XCTAssertEqual(job.inputURLs.map(\.standardizedFileURL), [png.standardizedFileURL])

        // Staging state must be cleared immediately after execution.
        XCTAssertTrue(session.stagedFileURLs.isEmpty)
        XCTAssertTrue(session.compatiblePresets.isEmpty)
        XCTAssertFalse(session.isPopoverPresented)

        // Allow any in-flight conversion task and undo persistence to settle inside sandbox before cleanup.
        try? await Task.sleep(nanoseconds: 150_000_000)
        appState.cancelConversion()
        await appState.conversionQueue.flushPendingUndoRecords()
    }

    func testOpenInConvertTabRoutesFilesAndClearsStagedDrop() throws {
        let appState = makeIsolatedAppState()
        appState.selectedTab = .settings

        let png = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("open_in_convert.png"))
        let session = MenuBarDropSession()
        session.stageDroppedURLs([png], presets: SavedPreset.defaultTemplates)
        XCTAssertTrue(session.hasStagedFiles)

        session.openInConvertTab(appState: appState, activateWindow: false)

        XCTAssertEqual(appState.selectedTab, .convert)
        XCTAssertEqual(appState.droppedFiles.count, 1)
        XCTAssertEqual(appState.droppedFiles.first?.url.standardizedFileURL, png.standardizedFileURL)
        XCTAssertTrue(session.stagedFileURLs.isEmpty)
        XCTAssertTrue(session.compatiblePresets.isEmpty)
        XCTAssertFalse(session.isPopoverPresented)
    }

    func testCancelAndDismissClearStagedDroppedFiles() throws {
        _ = makeIsolatedAppState()

        let png = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("staged.png"))
        let folder = sandbox.documentsURL.appendingPathComponent("SkippedDir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let session = MenuBarDropSession()
        session.stageDroppedURLs([png, folder], presets: SavedPreset.defaultTemplates)
        XCTAssertEqual(session.stagedFileURLs.count, 1)
        XCTAssertEqual(session.rejectedEntries.count, 1)
        XCTAssertFalse(session.compatiblePresets.isEmpty)
        XCTAssertTrue(session.isPopoverPresented)

        session.cancel()

        XCTAssertTrue(session.stagedFileURLs.isEmpty)
        XCTAssertTrue(session.rejectedEntries.isEmpty)
        XCTAssertTrue(session.compatiblePresets.isEmpty)
        XCTAssertFalse(session.isPopoverPresented)

        // Also verify MenuBarManager shared drop lifecycle cleanup.
        let manager = MenuBarManager.shared
        manager.handleDroppedFileURLs([png], presets: SavedPreset.defaultTemplates)
        XCTAssertEqual(manager.dropSession.stagedFileURLs.count, 1)
        manager.cancelStagedDrop()
        XCTAssertTrue(manager.dropSession.stagedFileURLs.isEmpty)
        XCTAssertTrue(manager.dropSession.compatiblePresets.isEmpty)
        XCTAssertFalse(manager.dropSession.isPopoverPresented)
    }

    // MARK: - 4. NSStatusItem Drop Target Registration

    func testStatusItemRegistersFileURLDragTypesAndDropTargetFiltersPasteboard() throws {
        _ = makeIsolatedAppState()
        let manager = MenuBarManager.shared
        let origAllow = manager.allowSystemStatusItemInTests
        let origShowInMenuBar = AppSettings.shared.showInMenuBar
        defer {
            manager.allowSystemStatusItemInTests = origAllow
            manager.updateVisibility(showInMenuBar: origShowInMenuBar)
        }

        manager.allowSystemStatusItemInTests = true
        manager.updateVisibility(showInMenuBar: true)
        XCTAssertTrue(manager.hasLiveStatusItem)
        XCTAssertTrue(manager.registeredDragTypes.contains(.fileURL))

        let png = try writeTinyPNG(to: sandbox.documentsURL.appendingPathComponent("drag_pboard.png"))
        let pboard = NSPasteboard.withUniqueName()
        defer { pboard.releaseGlobally() }

        pboard.clearContents()
        pboard.writeObjects([png as NSURL])
        XCTAssertTrue(StatusItemDropTargetView.canAcceptDrag(pboard))
        XCTAssertEqual(
            FinderHandoffHandler.extractPasteboardURLs(pboard).map(\.standardizedFileURL),
            [png.standardizedFileURL]
        )

        pboard.clearContents()
        pboard.setString("plain text", forType: .string)
        XCTAssertFalse(StatusItemDropTargetView.canAcceptDrag(pboard))

        manager.updateVisibility(showInMenuBar: false)
        XCTAssertFalse(manager.hasLiveStatusItem)
        XCTAssertTrue(manager.registeredDragTypes.isEmpty)
    }
}
