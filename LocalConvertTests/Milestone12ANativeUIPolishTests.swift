import XCTest
import SwiftUI
import AppKit
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Milestone12ANativeUIPolishTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = true
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M12A-UIPolish-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
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

    private func writeTinyPNG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 210, count: 32 * 32 * 4)
        for idx in stride(from: 3, to: pixels.count, by: 4) { pixels[idx] = 255 }
        guard let ctx = CGContext(
            data: &pixels,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 32 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let image = ctx.makeImage(),
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Milestone12ANativeUIPolishTests", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    @discardableResult
    private func hostAndLayout<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: AppTheme.Layout.minWindowWidth, height: AppTheme.Layout.minWindowHeight),
        appState: AppState? = nil,
        contextName: String
    ) -> NSHostingView<V> {
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

        XCTAssertEqual(
            publishCount,
            0,
            "[\(contextName)] Layout pass must not synchronously publish AppState changes"
        )
        let fitting = hosting.fittingSize
        XCTAssertFalse(fitting.width.isNaN || fitting.height.isNaN, "[\(contextName)] fittingSize must be finite")
        return hosting
    }

    private func measureLayout<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: AppTheme.Layout.minWindowWidth, height: AppTheme.Layout.minWindowHeight),
        appState: AppState? = nil,
        contextName: String
    ) -> (hosting: NSHostingView<V>, constrainedSize: CGSize) {
        let hosting = hostAndLayout(
            view,
            size: size,
            appState: appState,
            contextName: contextName
        )
        let controller = NSHostingController(rootView: view)
        let constrained = controller.sizeThatFits(in: size)
        XCTAssertFalse(
            constrained.width.isNaN || constrained.height.isNaN,
            "[\(contextName)] constrained sizeThatFits must be finite"
        )
        return (hosting, constrained)
    }

    private func xcstringsURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LocalConvert", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Localizable.xcstrings", isDirectory: false)
    }

    private func formatPlaceholderCount(in text: String) -> Int {
        let pattern = #"%(?:\d+\$)?(?:lld|@)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    // MARK: - 1. Primary Shell & All 9 Navigation Tabs at LC-019 (820x580)

    func testAllPrimaryNavigationTabsLayoutCleanlyWithin820x580WithoutReentrantStatePublish() throws {
        let appState = makeIsolatedAppState()
        let contentView = ContentView(
            undoCoordinator: appState.undoCoordinator,
            undoMenu: UndoMenuController.shared,
            commandPalette: CommandPaletteController.shared,
            metadataManager: MetadataManager.shared
        ).environmentObject(appState)

        let hosting = hostAndLayout(
            contentView,
            size: CGSize(width: 820, height: 580),
            appState: appState,
            contextName: "ContentView.initial"
        )

        var publishCount = 0
        let cancellable = appState.objectWillChange.sink { _ in
            publishCount += 1
        }
        defer { cancellable.cancel() }

        for tab in AppNavigationTab.allCases {
            appState.selectedTab = tab
            let before = publishCount
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(
                publishCount,
                before,
                "Switching to tab '\(tab.rawValue)' and laying out at 820x580 must not trigger re-entrant AppState.objectWillChange"
            )
            XCTAssertLessThanOrEqual(
                hosting.fittingSize.width,
                820,
                "Tab '\(tab.rawValue)' minimum fitting width (\(hosting.fittingSize.width)) exceeds LC-019 820pt bound"
            )
        }
    }

    func testConvertQueuePopulatedAndEmptyStatesLayoutAt820x580() throws {
        let appState = makeIsolatedAppState()
        let pngURL = sandbox.documentsURL.appendingPathComponent("queue_sample.png")
        try writeTinyPNG(to: pngURL)

        let dropMeasured = measureLayout(
            DropZoneView().environmentObject(appState),
            size: CGSize(width: 820, height: 580),
            appState: appState,
            contextName: "DropZoneView"
        )
        XCTAssertLessThanOrEqual(dropMeasured.constrainedSize.width, 820)
        XCTAssertLessThanOrEqual(dropMeasured.hosting.fittingSize.width, 820)

        let detection = FileDetector().detect(url: pngURL)
        appState.droppedFiles = [DroppedFile(url: pngURL, detectionResult: detection)]

        let fileListMeasured = measureLayout(
            FileListView().environmentObject(appState),
            size: CGSize(width: 820, height: 580),
            appState: appState,
            contextName: "FileListView"
        )
        XCTAssertLessThanOrEqual(fileListMeasured.constrainedSize.width, 820)
        XCTAssertLessThanOrEqual(fileListMeasured.hosting.fittingSize.width, 820)
    }

    // MARK: - 2. Media Viewer Studio (Empty, Photo, Video, Unsupported)

    func testMediaViewerStatesLayoutWithinLC019SheetBoundsWithoutStateWarnings() async throws {
        let appState = makeIsolatedAppState()
        let sheetSize = CGSize(width: 740, height: 500)

        // 1. Empty state
        let emptyMeasured = measureLayout(
            MediaViewerSheetView().environmentObject(appState),
            size: sheetSize,
            appState: appState,
            contextName: "MediaViewerSheetView.empty"
        )
        XCTAssertLessThanOrEqual(emptyMeasured.constrainedSize.width, 820)
        XCTAssertLessThanOrEqual(emptyMeasured.constrainedSize.height, 580)

        // 2. Photo viewer studio
        let photoURL = sandbox.documentsURL.appendingPathComponent("studio_photo.png")
        try writeTinyPNG(to: photoURL)
        appState.openInMediaViewer(photoURL)
        let photoSheetMeasured = measureLayout(
            MediaViewerSheetView().environmentObject(appState),
            size: sheetSize,
            appState: appState,
            contextName: "MediaViewerSheetView.photo"
        )
        XCTAssertLessThanOrEqual(photoSheetMeasured.constrainedSize.width, 820)

        let photoDirectMeasured = measureLayout(
            PhotoViewerEditorView(url: photoURL, onSendToConvertQueue: { _ in }, onDismiss: {}),
            size: sheetSize,
            appState: appState,
            contextName: "PhotoViewerEditorView.direct"
        )
        XCTAssertLessThanOrEqual(photoDirectMeasured.constrainedSize.width, 820)

        // 3. Video viewer studio
        let videoURL = sandbox.documentsURL.appendingPathComponent("studio_clip.mp4")
        _ = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(to: videoURL)
        appState.openInMediaViewer(videoURL)
        let videoSheetMeasured = measureLayout(
            MediaViewerSheetView().environmentObject(appState),
            size: sheetSize,
            appState: appState,
            contextName: "MediaViewerSheetView.video"
        )
        XCTAssertLessThanOrEqual(videoSheetMeasured.constrainedSize.width, 820)

        let videoDirectMeasured = measureLayout(
            VideoViewerEditorView(url: videoURL, onSendToConvertQueue: { _ in }, onDismiss: {}),
            size: sheetSize,
            appState: appState,
            contextName: "VideoViewerEditorView.direct"
        )
        XCTAssertLessThanOrEqual(videoDirectMeasured.constrainedSize.width, 820)

        // 4. Unsupported file state
        let pdfURL = sandbox.documentsURL.appendingPathComponent("unsupported.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdfURL)
        appState.openInMediaViewer(pdfURL)
        let unsupportedMeasured = measureLayout(
            MediaViewerSheetView().environmentObject(appState),
            size: sheetSize,
            appState: appState,
            contextName: "MediaViewerSheetView.unsupported"
        )
        XCTAssertLessThanOrEqual(unsupportedMeasured.constrainedSize.width, 820)
    }

    // MARK: - 3. Auxiliary Sheets, Modals & Popovers

    func testAuxiliarySheetsModalsAndPopoversInstantiateWithin820x580() async throws {
        let appState = makeIsolatedAppState()
        let minSize = CGSize(width: 820, height: 580)

        _ = hostAndLayout(
            SupportedFormatsView(isPresented: .constant(true)),
            size: minSize,
            appState: appState,
            contextName: "SupportedFormatsView"
        )

        _ = hostAndLayout(
            EditingHistoryView(coordinator: appState.undoCoordinator)
                .frame(minWidth: 540, idealWidth: 600, minHeight: 420, idealHeight: 460, maxHeight: 520),
            size: CGSize(width: 600, height: 480),
            appState: appState,
            contextName: "EditingHistoryView"
        )

        let paletteController = CommandPaletteController()
        paletteController.isPresented = true
        _ = hostAndLayout(
            CommandPaletteView(controller: paletteController).environmentObject(appState),
            size: minSize,
            appState: appState,
            contextName: "CommandPaletteView"
        )

        _ = hostAndLayout(
            LicensesSheetView(isPresented: .constant(true)),
            size: CGSize(width: 640, height: 480),
            appState: appState,
            contextName: "LicensesSheetView"
        )

        _ = hostAndLayout(
            FilenameTemplateBuilderView(template: .constant(OutputManager.defaultFilenameTemplate)),
            size: CGSize(width: 560, height: 240),
            appState: appState,
            contextName: "FilenameTemplateBuilderView"
        )

        let dropSession = MenuBarDropSession()
        _ = hostAndLayout(
            MenuBarDropPopoverView(
                session: dropSession,
                onSelectPreset: { _ in },
                onOpenInConvertTab: {},
                onCancel: {}
            ),
            size: CGSize(width: 340, height: 320),
            appState: appState,
            contextName: "MenuBarDropPopoverView"
        )

        _ = hostAndLayout(
            SettingsView().environmentObject(appState),
            size: minSize,
            appState: appState,
            contextName: "SettingsView"
        )

        let pngBefore = sandbox.documentsURL.appendingPathComponent("compare_before.png")
        let pngAfter = sandbox.documentsURL.appendingPathComponent("compare_after.png")
        try writeTinyPNG(to: pngBefore)
        try writeTinyPNG(to: pngAfter)
        let compareItem = BeforeAfterComparisonItem(
            id: UUID(),
            fileName: "compare_before.png",
            inputURL: pngBefore,
            outputURL: pngAfter,
            inputFormat: .png,
            outputFormat: .png,
            inputBytes: 1024,
            outputBytes: 768,
            sizeDelta: nil
        )
        let compareHost = hostAndLayout(
            QuickLookAndCompareView(item: compareItem),
            size: minSize,
            appState: appState,
            contextName: "QuickLookAndCompareView"
        )
        XCTAssertLessThanOrEqual(compareHost.fittingSize.width, 820)

        let videoURL = sandbox.documentsURL.appendingPathComponent("trim_sample.mp4")
        _ = try await SyntheticMP4FixtureWriter.writeSyntheticMP4(to: videoURL)
        let videoDetection = FileDetector().detect(url: videoURL)
        let videoFile = DroppedFile(url: videoURL, detectionResult: videoDetection)
        let trimHost = hostAndLayout(
            VideoTrimSheetView(file: videoFile, onApply: { _, _ in }),
            size: minSize,
            appState: appState,
            contextName: "VideoTrimSheetView"
        )
        XCTAssertLessThanOrEqual(trimHost.fittingSize.width, 820)
    }

    // MARK: - 4. Full-App Localizable.xcstrings JSON & en/tr Completeness

    func testLocalizableCatalogJSONStructureAndFullEnglishTurkishParity() throws {
        let url = xcstringsURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing Localizable.xcstrings at \(url.path)")

        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        let catalog = try XCTUnwrap(raw as? [String: Any])

        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        XCTAssertEqual(catalog["version"] as? String, "1.0")

        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThanOrEqual(strings.count, 740)

        for (key, entry) in strings.sorted(by: { $0.key < $1.key }) {
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for '\(key)'")
            for lang in ["en", "tr"] {
                let langMap = try XCTUnwrap(localizations[lang] as? [String: Any], "Missing '\(lang)' for '\(key)'")
                let unit = try XCTUnwrap(langMap["stringUnit"] as? [String: Any], "Missing stringUnit (\(lang)) for '\(key)'")
                XCTAssertEqual(unit["state"] as? String, "translated", "Expected 'translated' for '\(key)' (\(lang))")
                let value = try XCTUnwrap(unit["value"] as? String, "Missing value (\(lang)) for '\(key)'")
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Empty translation for '\(key)' (\(lang))"
                )
            }

            let enVal = ((localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            let trVal = ((localizations["tr"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
            XCTAssertEqual(
                formatPlaceholderCount(in: enVal),
                formatPlaceholderCount(in: trVal),
                "Placeholder parity mismatch for '\(key)': en='\(enVal)' vs tr='\(trVal)'"
            )
        }

        let milestone12AKeys: [String] = [
            // Worker 1
            "Paste",
            "Nothing to Undo (⌘Z)",
            "Nothing to Redo (⇧⌘Z)",
            "Format",
            "Name & Category",
            "%lld shown",
            "No Matching Formats",
            "Try clearing the search query or switching to All Categories.",
            "All Categories",
            "Clear search",
            "Read-Only",
            "Converts to: %@",
            "Remove from queue",
            "Navigation",
            "Navigate",
            "Dismiss",
            "Clear Search",
            "Command Palette Search",
            "Before: %@",
            "After: %@",
            "Split:",
            "50%",
            "Reset split to 50%",
            "Before and after split position",
            // Worker 2
            "No Matching License Text",
            "Try a different keyword or clear the search field.",
            // Worker 3
            "100% On-Device",
            "On-Device",
            "Photo Markup & Redact",
            "Markup & Redact",
            "Multi-Segment Video Trim",
            "Video Trim",
            "Light & Color",
            "Frame Geometry",
            "100%"
        ]

        for key in milestone12AKeys {
            XCTAssertNotNil(strings[key], "Milestone 12A key '\(key)' missing from Localizable.xcstrings")
        }
    }
}
