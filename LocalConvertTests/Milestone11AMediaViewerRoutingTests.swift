import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Milestone11AMediaViewerRoutingTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?
    private var isolatedPasteboards: [NSPasteboard] = []

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M11A-Routing-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
        for pboard in isolatedPasteboards {
            pboard.clearContents()
            pboard.releaseGlobally()
        }
        isolatedPasteboards.removeAll()

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

    private func makeIsolatedPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("com.localconvert.tests.mediaviewer.\(UUID().uuidString)")
        let pboard = NSPasteboard(name: name)
        pboard.clearContents()
        isolatedPasteboards.append(pboard)
        return pboard
    }

    private func writeTinyPNG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 200, count: 16 * 16 * 4)
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
            throw NSError(domain: "Milestone11AMediaViewerRoutingTests", code: 1)
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

    // MARK: - 1. Media Type Classification

    func testMediaViewerRouterClassifiesPhotoVideoAndUnsupportedExtensionsAndUTTypes() throws {
        let photoExts = [
            "png", "jpg", "jpeg", "heic", "heif", "webp", "jxl",
            "tiff", "tif", "bmp", "gif", "avif", "dng", "PNG", "HEIC"
        ]
        for ext in photoExts {
            let url = sandbox.documentsURL.appendingPathComponent("sample.\(ext)")
            XCTAssertEqual(
                MediaViewerRouter.routeKind(for: url),
                .photo,
                "Expected .photo for extension .\(ext)"
            )
        }

        let videoExts = [
            "mp4", "mov", "m4v", "mkv", "webm", "avi", "ts",
            "flv", "wmv", "mpg", "mpeg", "MOV", "MP4"
        ]
        for ext in videoExts {
            let url = sandbox.documentsURL.appendingPathComponent("clip.\(ext)")
            XCTAssertEqual(
                MediaViewerRouter.routeKind(for: url),
                .video,
                "Expected .video for extension .\(ext)"
            )
        }

        let unsupportedExts = ["pdf", "txt", "docx", "mp3", "wav", "m4a", "flac", "srt", "zip", "unknownext"]
        for ext in unsupportedExts {
            let url = sandbox.documentsURL.appendingPathComponent("file.\(ext)")
            XCTAssertEqual(
                MediaViewerRouter.routeKind(for: url),
                .unsupported,
                "Expected .unsupported for extension .\(ext)"
            )
        }

        // Directory & non-file URLs must be unsupported
        let folderURL = sandbox.documentsURL.appendingPathComponent("Folder.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: folderURL), .unsupported)

        XCTAssertEqual(MediaViewerRouter.routeKind(for: URL(string: "https://example.com/photo.png")!), .unsupported)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: URL(string: "localconvert://open?file=/tmp/photo.png")!), .unsupported)

        // UTType overload checks
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .png), .photo)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .jpeg), .photo)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .heic), .photo)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .webP), .photo)
        if let jxlType = UTType("public.jpeg-xl") {
            XCTAssertEqual(MediaViewerRouter.routeKind(for: jxlType), .photo)
        }
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .mpeg4Movie), .video)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .quickTimeMovie), .video)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .pdf), .unsupported)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .mp3), .unsupported)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: .plainText), .unsupported)

        // Extensionless real PNG on disk falls back to magic-bytes detection
        let extensionlessPNG = sandbox.documentsURL.appendingPathComponent("extensionless_image")
        try writeTinyPNG(to: extensionlessPNG)
        XCTAssertEqual(MediaViewerRouter.routeKind(for: extensionlessPNG), .photo)
    }

    // MARK: - 2. Finder Single-File Media Routing vs Queue Fallback

    func testFinderSingleMediaFileRoutesToMediaViewerWhileMultiFileAndNonMediaQueueToConvert() async throws {
        let photoURL = sandbox.documentsURL.appendingPathComponent("single_photo.png")
        try writeTinyPNG(to: photoURL)

        let videoURL = sandbox.documentsURL.appendingPathComponent("single_clip.mp4")
        _ = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(to: videoURL)

        let pdfURL = sandbox.documentsURL.appendingPathComponent("document.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdfURL)

        let audioURL = sandbox.documentsURL.appendingPathComponent("track.mp3")
        try Data([0x49, 0x44, 0x33, 0x03, 0x00]).write(to: audioURL)

        // Pure predicate checks
        XCTAssertTrue(MediaViewerRouter.shouldRouteSingleOpenedFileToMediaViewer(urls: [photoURL]))
        XCTAssertTrue(MediaViewerRouter.shouldRouteSingleOpenedFileToMediaViewer(urls: [videoURL]))
        XCTAssertFalse(MediaViewerRouter.shouldRouteSingleOpenedFileToMediaViewer(urls: [photoURL, videoURL]))
        XCTAssertFalse(MediaViewerRouter.shouldRouteSingleOpenedFileToMediaViewer(urls: [pdfURL]))
        XCTAssertFalse(MediaViewerRouter.shouldRouteSingleOpenedFileToMediaViewer(urls: [audioURL]))
        XCTAssertFalse(MediaViewerRouter.shouldRouteSingleOpenedFileToMediaViewer(urls: []))

        // 1. Single image -> opens Media Viewer without adding to Convert queue
        let state1 = makeIsolatedAppState()
        state1.handleOpenedFileURLs([photoURL])
        XCTAssertTrue(state1.isMediaViewerPresented)
        XCTAssertEqual(state1.activeMediaViewerURL?.standardizedFileURL, photoURL.standardizedFileURL)
        XCTAssertTrue(state1.droppedFiles.isEmpty)

        // 2. Single video -> opens Media Viewer without adding to Convert queue
        let state2 = makeIsolatedAppState()
        state2.handleOpenedFileURLs([videoURL])
        XCTAssertTrue(state2.isMediaViewerPresented)
        XCTAssertEqual(state2.activeMediaViewerURL?.standardizedFileURL, videoURL.standardizedFileURL)
        XCTAssertTrue(state2.droppedFiles.isEmpty)

        // 3. Multiple files -> falls back to Convert queue
        let state3 = makeIsolatedAppState()
        state3.handleOpenedFileURLs([photoURL, videoURL])
        XCTAssertFalse(state3.isMediaViewerPresented)
        XCTAssertNil(state3.activeMediaViewerURL)
        XCTAssertEqual(state3.droppedFiles.count, 2)

        // 4. Single non-media file (PDF / MP3) -> falls back to Convert queue
        let state4 = makeIsolatedAppState()
        state4.handleOpenedFileURLs([pdfURL])
        XCTAssertFalse(state4.isMediaViewerPresented)
        XCTAssertNil(state4.activeMediaViewerURL)
        XCTAssertEqual(state4.droppedFiles.count, 1)
        XCTAssertEqual(state4.droppedFiles.first?.fileName, "document.pdf")

        // 5. Symlink to valid image -> rejected safely, never opened in Media Viewer
        let symlinkURL = sandbox.documentsURL.appendingPathComponent("evil_link.png")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: photoURL)
        let state5 = makeIsolatedAppState()
        state5.handleOpenedFileURLs([symlinkURL])
        XCTAssertFalse(state5.isMediaViewerPresented)
        XCTAssertNil(state5.activeMediaViewerURL)
        XCTAssertTrue(state5.droppedFiles.isEmpty)
    }

    // MARK: - 3. AppState Media Viewer Lifecycle & Send to Convert Queue

    func testAppStateMediaViewerEmptyStateDismissAndSendToConvertQueue() throws {
        let appState = makeIsolatedAppState()
        appState.selectedTab = .history

        appState.openMediaViewerEmpty()
        XCTAssertTrue(appState.isMediaViewerPresented)
        XCTAssertNil(appState.activeMediaViewerURL)

        let photoURL = sandbox.documentsURL.appendingPathComponent("edited.png")
        try writeTinyPNG(to: photoURL)

        appState.openInMediaViewer(photoURL)
        XCTAssertTrue(appState.isMediaViewerPresented)
        XCTAssertEqual(appState.activeMediaViewerURL, photoURL)

        appState.sendToConvertQueue(fromMediaViewer: photoURL)
        XCTAssertFalse(appState.isMediaViewerPresented)
        XCTAssertNil(appState.activeMediaViewerURL)
        XCTAssertEqual(appState.selectedTab, .convert)
        XCTAssertEqual(appState.droppedFiles.count, 1)
        XCTAssertEqual(appState.droppedFiles.first?.url.standardizedFileURL, photoURL.standardizedFileURL)

        // Setting isMediaViewerPresented = false directly clears activeMediaViewerURL
        appState.openInMediaViewer(photoURL)
        XCTAssertNotNil(appState.activeMediaViewerURL)
        appState.isMediaViewerPresented = false
        XCTAssertNil(appState.activeMediaViewerURL)
    }

    // MARK: - 4. Command Palette Entry & LC-016 Parity

    func testCommandPaletteIncludesMediaViewerEntryAndPreservesLC016Parity() throws {
        XCTAssertFalse(KeyboardShortcutDescriptor.hasDuplicateShortcuts)
        let navShortcuts = KeyboardShortcutDescriptor.defaultShortcuts
            .filter { $0.category == "Navigation" }
            .map(\.shortcut)
        XCTAssertEqual(navShortcuts, (1...9).map { "⌘\($0)" })

        let appState = makeIsolatedAppState()
        let presetStore = PresetStore(fileURL: sandbox.rootURL.appendingPathComponent("presets.json"))
        let presetManager = PresetManager(store: presetStore, undoCoordinator: appState.undoCoordinator)

        let items = CommandPaletteCatalog.buildItems(presets: presetManager.presets)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertEqual(
            items.prefix(AppNavigationTab.allCases.count).map(\.category),
            Array(repeating: .navigation, count: AppNavigationTab.allCases.count)
        )

        let mediaViewerItem = try XCTUnwrap(items.first { $0.action == .openMediaViewer })
        XCTAssertEqual(mediaViewerItem.title, "Open Media Viewer (Photo, Markup & Video Editor)")

        let searchResults = CommandPaletteSearchEngine.search(query: "Media Viewer", in: items)
        XCTAssertEqual(searchResults.first?.action, .openMediaViewer)

        CommandPaletteRouter.execute(mediaViewerItem, appState: appState, presetManager: presetManager)
        XCTAssertTrue(appState.isMediaViewerPresented)
        XCTAssertNil(appState.activeMediaViewerURL)
    }

    // MARK: - 5. LC-002 URL Scheme Security Isolation

    func testLC002URLSchemeNeverBypassesConfirmationOrRoutesToMediaViewer() throws {
        let photoURL = sandbox.documentsURL.appendingPathComponent("scheme_photo.png")
        try writeTinyPNG(to: photoURL)

        let appState = makeIsolatedAppState()
        let coordinator = URLSchemeHandoffCoordinator()

        // 1. localconvert://convert?file=... must stage LC-002 confirmation and NOT open Media Viewer
        let convertScheme = makeSchemeURL(
            action: "convert",
            queryItems: [URLQueryItem(name: "file", value: photoURL.path)]
        )
        LocalConvertApp.handleIncomingURL(convertScheme, appState: appState, coordinator: coordinator)

        XCTAssertTrue(coordinator.isConfirmationPresented)
        XCTAssertNotNil(coordinator.pendingConversionRequest)
        XCTAssertFalse(appState.isMediaViewerPresented)
        XCTAssertNil(appState.activeMediaViewerURL)
        XCTAssertFalse(appState.isConverting)
        XCTAssertTrue(appState.droppedFiles.isEmpty)

        coordinator.cancelPendingConversion()

        // 2. localconvert://open?file=... adds to droppedFiles via URLSchemeHandoffCoordinator (not Media Viewer)
        let openScheme = makeSchemeURL(
            action: "open",
            queryItems: [URLQueryItem(name: "file", value: photoURL.path)]
        )
        LocalConvertApp.handleIncomingURL(openScheme, appState: appState, coordinator: coordinator)
        XCTAssertFalse(coordinator.isConfirmationPresented)
        XCTAssertFalse(appState.isMediaViewerPresented)
        XCTAssertEqual(appState.droppedFiles.count, 1)

        // 3. Direct Finder file:// URL routes to Media Viewer without touching URLSchemeHandoffCoordinator
        let appState2 = makeIsolatedAppState()
        let coordinator2 = URLSchemeHandoffCoordinator()
        LocalConvertApp.handleIncomingURL(photoURL, appState: appState2, coordinator: coordinator2)
        XCTAssertFalse(coordinator2.isConfirmationPresented)
        XCTAssertNil(coordinator2.pendingConversionRequest)
        XCTAssertTrue(appState2.isMediaViewerPresented)
        XCTAssertEqual(appState2.activeMediaViewerURL?.standardizedFileURL, photoURL.standardizedFileURL)
        XCTAssertTrue(appState2.droppedFiles.isEmpty)

        // 4. Mixed batch of file:// + localconvert://convert keeps both paths isolated
        let appState3 = makeIsolatedAppState()
        let coordinator3 = URLSchemeHandoffCoordinator()
        LocalConvertApp.handleIncomingURLs([photoURL, convertScheme], appState: appState3, coordinator: coordinator3)
        XCTAssertTrue(appState3.isMediaViewerPresented)
        XCTAssertEqual(appState3.activeMediaViewerURL?.standardizedFileURL, photoURL.standardizedFileURL)
        XCTAssertTrue(coordinator3.isConfirmationPresented)
        XCTAssertNotNil(coordinator3.pendingConversionRequest)
        XCTAssertFalse(appState3.isConverting)
        coordinator3.cancelPendingConversion()
    }

    // MARK: - 6. Clipboard Image Staging for Empty Media Viewer

    func testMediaViewerClipboardHelperStagesImageAndRejectsPlainText() async throws {
        let stagingDir = sandbox.temporaryURL.appendingPathComponent("MediaViewerClipboard", isDirectory: true)

        let pngURL = sandbox.documentsURL.appendingPathComponent("clipboard_source.png")
        try writeTinyPNG(to: pngURL)
        let pngData = try Data(contentsOf: pngURL)

        let imageBoard = makeIsolatedPasteboard()
        imageBoard.setData(pngData, forType: .png)

        let imageResult = await MediaViewerClipboardHelper.stageMedia(from: imageBoard, stagingDirectory: stagingDir)
        switch imageResult {
        case .success(let stagedURL):
            XCTAssertEqual(MediaViewerRouter.routeKind(for: stagedURL), .photo)
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        case .failure(let error):
            XCTFail("Expected image clipboard paste to succeed, got \(error)")
        }

        let textBoard = makeIsolatedPasteboard()
        textBoard.setString("Not an image", forType: .string)
        let textResult = await MediaViewerClipboardHelper.stageMedia(from: textBoard, stagingDirectory: stagingDir)
        XCTAssertEqual(textResult, .failure(.noMediaOnClipboard))
    }
}
