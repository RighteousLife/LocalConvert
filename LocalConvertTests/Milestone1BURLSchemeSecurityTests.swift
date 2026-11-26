import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import LocalConvert

final class Milestone1BURLSchemeSecurityTests: XCTestCase {

    // MARK: - Helpers

    private func makeSandbox(suffix: String) throws -> TestSandbox {
        let sandbox = try TestSandbox(runID: "M1B-URLScheme-\(suffix)-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
        return sandbox
    }

    private func cleanupSandbox(_ sandbox: TestSandbox) {
        AppStoragePaths.clearTestOverrides()
        _ = sandbox.cleanup()
    }

    @MainActor
    private func makeIsolatedAppState(sandbox: TestSandbox) -> AppState {
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

    private func writeTinyPNG(to url: URL) throws {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 180, count: 16 * 16 * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 16 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone1BURLSchemeSecurityTests", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func makeSchemeURL(action: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "localconvert"
        components.host = action
        components.queryItems = queryItems
        return components.url!
    }

    // MARK: - 1. Auto-Conversion Disabled & Explicit Confirmation Flow

    @MainActor
    func testConvertURLNeverAutoConvertsAndStagesPendingConfirmation() throws {
        let sandbox = try makeSandbox(suffix: "NoAutoConvert")
        defer { cleanupSandbox(sandbox) }

        let inputFile = sandbox.documentsURL.appendingPathComponent("sample.png")
        try writeTinyPNG(to: inputFile)

        let appState = makeIsolatedAppState(sandbox: sandbox)
        let coordinator = URLSchemeHandoffCoordinator()
        let url = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: inputFile.path)])

        LocalConvertApp.handleIncomingURL(url, appState: appState, coordinator: coordinator)

        // Must NOT add to droppedFiles or start converting before user confirms
        XCTAssertFalse(appState.isConverting)
        XCTAssertEqual(appState.conversionQueue.totalCount, 0)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        XCTAssertFalse(appState.showError)

        // Confirmation prompt must be staged with resolved filename
        XCTAssertTrue(coordinator.isConfirmationPresented)
        let request = try XCTUnwrap(coordinator.pendingConversionRequest)
        XCTAssertEqual(request.resolvedFilenames, ["sample.png"])
        XCTAssertEqual(request.stagedURLs.map(\.standardizedFileURL), [inputFile.standardizedFileURL])

        let message = URLSchemeHandoffCoordinator.confirmationMessage(for: request)
        XCTAssertTrue(message.contains("sample.png"))
    }

    @MainActor
    func testConfirmingPendingURLConversionAddsAndEnqueuesConversion() async throws {
        let sandbox = try makeSandbox(suffix: "ConfirmConvert")
        defer { cleanupSandbox(sandbox) }

        let inputFile = sandbox.documentsURL.appendingPathComponent("confirm_me.png")
        try writeTinyPNG(to: inputFile)

        let appState = makeIsolatedAppState(sandbox: sandbox)
        defer { appState.cancelConversion() }
        let coordinator = URLSchemeHandoffCoordinator()
        let url = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: inputFile.path)])

        LocalConvertApp.handleIncomingURL(url, appState: appState, coordinator: coordinator)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        XCTAssertFalse(appState.isConverting)

        let confirmed = coordinator.confirmPendingConversion(appState: appState)
        XCTAssertTrue(confirmed)
        XCTAssertNil(coordinator.pendingConversionRequest)
        XCTAssertFalse(coordinator.isConfirmationPresented)
        XCTAssertEqual(appState.droppedFiles.count, 1)
        XCTAssertEqual(appState.droppedFiles.first?.fileName, "confirm_me.png")
        XCTAssertGreaterThanOrEqual(appState.conversionQueue.totalCount, 1)

        // Allow any in-flight conversion task to settle cleanly inside sandbox before cleanup
        try? await Task.sleep(nanoseconds: 150_000_000)
        appState.cancelConversion()
    }

    @MainActor
    func testCancellingConfirmationDiscardsStagedFilesCompletely() throws {
        let sandbox = try makeSandbox(suffix: "CancelConvert")
        defer { cleanupSandbox(sandbox) }

        let fileA = sandbox.documentsURL.appendingPathComponent("first.png")
        let fileB = sandbox.documentsURL.appendingPathComponent("second.png")
        try writeTinyPNG(to: fileA)
        try writeTinyPNG(to: fileB)

        let appState = makeIsolatedAppState(sandbox: sandbox)
        let coordinator = URLSchemeHandoffCoordinator()
        let url = makeSchemeURL(
            action: "convert",
            queryItems: [URLQueryItem(name: "files", value: "\(fileA.path),\(fileB.path)")]
        )

        LocalConvertApp.handleIncomingURL(url, appState: appState, coordinator: coordinator)
        XCTAssertEqual(coordinator.pendingConversionRequest?.resolvedFilenames, ["first.png", "second.png"])
        XCTAssertTrue(coordinator.isConfirmationPresented)

        coordinator.cancelPendingConversion()

        XCTAssertNil(coordinator.pendingConversionRequest)
        XCTAssertFalse(coordinator.isConfirmationPresented)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        XCTAssertEqual(appState.conversionQueue.totalCount, 0)
        XCTAssertFalse(appState.isConverting)

        // Also verify external dismissal (e.g. Escape key setting isConfirmationPresented = false) discards staged files
        LocalConvertApp.handleIncomingURL(url, appState: appState, coordinator: coordinator)
        XCTAssertNotNil(coordinator.pendingConversionRequest)
        coordinator.isConfirmationPresented = false
        XCTAssertNil(coordinator.pendingConversionRequest)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
    }

    // MARK: - 2. Scheme, Action, Malformed & Path Traversal Validation

    func testRejectsInvalidSchemesActionsMalformedURLsAndEmptyParameters() throws {
        let sandbox = try makeSandbox(suffix: "InvalidURLs")
        defer { cleanupSandbox(sandbox) }

        let validFile = sandbox.documentsURL.appendingPathComponent("valid.png")
        try writeTinyPNG(to: validFile)

        // Foreign scheme
        let foreign = URL(string: "https://convert?file=\(validFile.path)")!
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(foreign), .failure(.invalidScheme("https")))

        // Unsupported action
        let badAction = makeSchemeURL(action: "delete", queryItems: [URLQueryItem(name: "file", value: validFile.path)])
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(badAction), .failure(.unsupportedAction("delete")))

        // Empty query input
        let empty = URL(string: "localconvert://convert")!
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(empty), .failure(.emptyInput))

        let blankParam = URL(string: "localconvert://convert?file=%20%20")!
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(blankParam), .failure(.emptyInput))

        // Relative path rejected
        let relative = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: "relative/valid.png")])
        if case .failure(.malformedURL) = FinderHandoffHandler.parseSchemeURL(relative) {
            // Expected
        } else {
            XCTFail("Expected malformedURL for relative path")
        }

        // Non-local file:// host rejected
        let remoteFileURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: "file://evil.example/tmp/valid.png")])
        if case .failure(.malformedURL) = FinderHandoffHandler.parseSchemeURL(remoteFileURL) {
            // Expected
        } else {
            XCTFail("Expected malformedURL for remote file:// host")
        }

        // Null byte (%00) rejected
        let nullByteURL = URL(string: "localconvert://convert?file=/tmp/bad%00file.png")!
        if case .failure(.malformedURL) = FinderHandoffHandler.parseSchemeURL(nullByteURL) {
            // Expected
        } else {
            XCTFail("Expected malformedURL for null byte")
        }

        // Userinfo / fragment rejected
        let userinfoURL = URL(string: "localconvert://attacker@convert?file=\(validFile.path)")!
        if case .failure(.malformedURL) = FinderHandoffHandler.parseSchemeURL(userinfoURL) {
            // Expected
        } else {
            XCTFail("Expected malformedURL for userinfo")
        }
    }

    func testRejectsPathTraversalAttempts() throws {
        let sandbox = try makeSandbox(suffix: "Traversal")
        defer { cleanupSandbox(sandbox) }

        let target = sandbox.documentsURL.appendingPathComponent("real.png")
        try writeTinyPNG(to: target)

        let subdir = sandbox.documentsURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        // Direct .. traversal back to real.png
        let literalTraversal = subdir.path + "/../real.png"
        let literalURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: literalTraversal)])
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(literalURL), .failure(.pathTraversalRejected(literalTraversal)))

        // Percent-encoded %2e%2e traversal
        let encodedTraversal = subdir.path + "/%2e%2e/real.png"
        let encodedURL = URL(string: "localconvert://convert?file=\(encodedTraversal)")!
        if case .failure(.pathTraversalRejected) = FinderHandoffHandler.parseSchemeURL(encodedURL) {
            // Expected
        } else {
            XCTFail("Expected pathTraversalRejected for percent-encoded traversal")
        }

        // file:// URL containing traversal
        let fileSchemeTraversal = "file://" + subdir.path + "/../real.png"
        let fileSchemeURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: fileSchemeTraversal)])
        if case .failure(.pathTraversalRejected) = FinderHandoffHandler.parseSchemeURL(fileSchemeURL) {
            // Expected
        } else {
            XCTFail("Expected pathTraversalRejected for file:// traversal")
        }
    }

    // MARK: - 3. Symlink, Directory, Special File & Readability Rejection

    func testRejectsSymlinksOnTargetAndAncestorDirectories() throws {
        let sandbox = try makeSandbox(suffix: "Symlinks")
        defer { cleanupSandbox(sandbox) }

        let realFile = sandbox.documentsURL.appendingPathComponent("real.png")
        try writeTinyPNG(to: realFile)

        // 1. Direct file symlink
        let fileSymlink = sandbox.documentsURL.appendingPathComponent("link_to_real.png")
        try FileManager.default.createSymbolicLink(at: fileSymlink, withDestinationURL: realFile)
        let directSymlinkURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: fileSymlink.path)])
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(directSymlinkURL), .failure(.symlinkRejected(fileSymlink.standardizedFileURL.path)))

        // 2. Dangling symlink
        let missingTarget = sandbox.documentsURL.appendingPathComponent("does_not_exist.png")
        let danglingSymlink = sandbox.documentsURL.appendingPathComponent("dangling.png")
        try FileManager.default.createSymbolicLink(at: danglingSymlink, withDestinationURL: missingTarget)
        let danglingURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: danglingSymlink.path)])
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(danglingURL), .failure(.symlinkRejected(danglingSymlink.standardizedFileURL.path)))

        // 3. Symlinked parent directory
        let realSubdir = sandbox.documentsURL.appendingPathComponent("real_dir", isDirectory: true)
        try FileManager.default.createDirectory(at: realSubdir, withIntermediateDirectories: true)
        let innerFile = realSubdir.appendingPathComponent("inside.png")
        try writeTinyPNG(to: innerFile)

        let symlinkDir = sandbox.documentsURL.appendingPathComponent("linked_dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: realSubdir)
        let viaLinkedDir = symlinkDir.appendingPathComponent("inside.png")
        let ancestorSymlinkURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: viaLinkedDir.path)])
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(ancestorSymlinkURL), .failure(.symlinkRejected(viaLinkedDir.standardizedFileURL.path)))
    }

    func testRejectsDirectoriesSpecialFilesAndUnreadableFiles() throws {
        let sandbox = try makeSandbox(suffix: "TypesAndPerms")
        defer { cleanupSandbox(sandbox) }

        // 1. Directory rejected
        let folder = sandbox.documentsURL.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: folder.path)])
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(folderURL), .failure(.folderRejected(folder.standardizedFileURL.path)))

        // 2. FIFO (non-regular file) rejected
        let fifoPath = sandbox.documentsURL.appendingPathComponent("pipe.png").path
        XCTAssertEqual(Darwin.mkfifo(fifoPath, 0o600), 0)
        let fifoURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: fifoPath)])
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(fifoURL), .failure(.notRegularFile(URL(fileURLWithPath: fifoPath).standardizedFileURL.path)))

        // 3. Unreadable file rejected (when running as non-root)
        if Darwin.geteuid() != 0 {
            let unreadable = sandbox.documentsURL.appendingPathComponent("secret.png")
            try writeTinyPNG(to: unreadable)
            XCTAssertEqual(Darwin.chmod(unreadable.path, 0o000), 0)
            defer { _ = Darwin.chmod(unreadable.path, 0o644) }

            let unreadableURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: unreadable.path)])
            XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(unreadableURL), .failure(.fileNotReadable(unreadable.standardizedFileURL.path)))
        }

        // 4. Non-existent file rejected
        let missing = sandbox.documentsURL.appendingPathComponent("missing.png")
        let missingURL = makeSchemeURL(action: "convert", queryItems: [URLQueryItem(name: "file", value: missing.path)])
        XCTAssertEqual(FinderHandoffHandler.parseSchemeURL(missingURL), .failure(.fileNotFound(missing.standardizedFileURL.path)))
    }

    // MARK: - 4. Mixed Batches & All-Invalid Batches

    @MainActor
    func testMixedBatchStagesOnlyValidFilesAndReportsRejectedPaths() throws {
        let sandbox = try makeSandbox(suffix: "MixedBatch")
        defer { cleanupSandbox(sandbox) }

        let valid1 = sandbox.documentsURL.appendingPathComponent("valid1.png")
        let valid2 = sandbox.documentsURL.appendingPathComponent("valid2.png")
        try writeTinyPNG(to: valid1)
        try writeTinyPNG(to: valid2)

        let symlink = sandbox.documentsURL.appendingPathComponent("evil_link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid1)

        let folder = sandbox.documentsURL.appendingPathComponent("EvilDir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let traversal = sandbox.documentsURL.path + "/../Documents/valid1.png"
        let missing = sandbox.documentsURL.appendingPathComponent("ghost.png")

        let mixedURL = makeSchemeURL(
            action: "convert",
            queryItems: [
                URLQueryItem(name: "files", value: [
                    valid1.path,
                    traversal,
                    symlink.path,
                    folder.path,
                    missing.path,
                    valid2.path
                ].joined(separator: ","))
            ]
        )

        let parseBatch = FinderHandoffHandler.parseAndValidateSchemeURL(mixedURL)
        guard case .success(let batch) = parseBatch else {
            return XCTFail("Expected mixed batch to succeed with valid files, got \(parseBatch)")
        }
        XCTAssertEqual(batch.action, .convert)
        XCTAssertEqual(batch.validURLs.map(\.lastPathComponent), ["valid1.png", "valid2.png"])
        XCTAssertEqual(batch.rejectedEntries.count, 4)

        let appState = makeIsolatedAppState(sandbox: sandbox)
        let coordinator = URLSchemeHandoffCoordinator()
        LocalConvertApp.handleIncomingURL(mixedURL, appState: appState, coordinator: coordinator)

        // Valid files staged for confirmation; invalid files excluded; nothing converted yet
        XCTAssertTrue(coordinator.isConfirmationPresented)
        XCTAssertFalse(appState.isConverting)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        let request = try XCTUnwrap(coordinator.pendingConversionRequest)
        XCTAssertEqual(request.resolvedFilenames, ["valid1.png", "valid2.png"])
        XCTAssertEqual(request.rejectedEntries.count, 4)

        let message = URLSchemeHandoffCoordinator.confirmationMessage(for: request)
        XCTAssertTrue(message.contains("valid1.png"))
        XCTAssertTrue(message.contains("valid2.png"))
        XCTAssertTrue(message.contains("4 invalid or unsafe paths were skipped"))

        coordinator.cancelPendingConversion()
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        XCTAssertNil(coordinator.pendingConversionRequest)
    }

    @MainActor
    func testAllInvalidBatchStagesNothingAndTriggersNoConfirmationPrompt() throws {
        let sandbox = try makeSandbox(suffix: "AllInvalid")
        defer { cleanupSandbox(sandbox) }

        let target = sandbox.documentsURL.appendingPathComponent("real.png")
        try writeTinyPNG(to: target)

        let symlink = sandbox.documentsURL.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let folder = sandbox.documentsURL.appendingPathComponent("Dir", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let traversal = sandbox.documentsURL.path + "/../real.png"
        let allInvalidURL = makeSchemeURL(
            action: "convert",
            queryItems: [URLQueryItem(name: "files", value: "\(traversal),\(symlink.path),\(folder.path)")]
        )

        let appState = makeIsolatedAppState(sandbox: sandbox)
        let coordinator = URLSchemeHandoffCoordinator()
        LocalConvertApp.handleIncomingURL(allInvalidURL, appState: appState, coordinator: coordinator)

        XCTAssertFalse(coordinator.isConfirmationPresented)
        XCTAssertNil(coordinator.pendingConversionRequest)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        XCTAssertFalse(appState.isConverting)
        XCTAssertEqual(appState.conversionQueue.totalCount, 0)
        XCTAssertTrue(appState.showError)
    }

    // MARK: - 5. Open Action Security

    @MainActor
    func testOpenActionValidatesPathsAndAddsWithoutConverting() throws {
        let sandbox = try makeSandbox(suffix: "OpenAction")
        defer { cleanupSandbox(sandbox) }

        let valid = sandbox.documentsURL.appendingPathComponent("open_me.png")
        try writeTinyPNG(to: valid)

        let symlink = sandbox.documentsURL.appendingPathComponent("open_link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: valid)

        let appState = makeIsolatedAppState(sandbox: sandbox)
        let coordinator = URLSchemeHandoffCoordinator()

        // Symlink open must fail cleanly
        let badOpen = makeSchemeURL(action: "open", queryItems: [URLQueryItem(name: "file", value: symlink.path)])
        LocalConvertApp.handleIncomingURL(badOpen, appState: appState, coordinator: coordinator)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        XCTAssertTrue(appState.showError)
        XCTAssertFalse(coordinator.isConfirmationPresented)

        appState.showError = false

        // Valid open adds file without starting conversion or conversion confirmation
        let goodOpen = makeSchemeURL(action: "open", queryItems: [URLQueryItem(name: "file", value: valid.path)])
        LocalConvertApp.handleIncomingURL(goodOpen, appState: appState, coordinator: coordinator)
        XCTAssertEqual(appState.droppedFiles.count, 1)
        XCTAssertEqual(appState.droppedFiles.first?.fileName, "open_me.png")
        XCTAssertFalse(appState.isConverting)
        XCTAssertEqual(appState.conversionQueue.totalCount, 0)
        XCTAssertFalse(coordinator.isConfirmationPresented)
    }
}
