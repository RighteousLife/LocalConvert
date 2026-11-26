import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Milestone10AClipboardPasteTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?
    private var isolatedPasteboards: [NSPasteboard] = []

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M10AClipboard-\(UUID().uuidString)")
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

    private func makeIsolatedPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("com.localconvert.tests.clipboard.\(UUID().uuidString)")
        let pboard = NSPasteboard(name: name)
        pboard.clearContents()
        isolatedPasteboards.append(pboard)
        return pboard
    }

    private var stagingDir: URL {
        sandbox.temporaryURL.appendingPathComponent("ClipboardIntake", isDirectory: true)
    }

    private func makeIsolatedAppState() -> AppState {
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        return AppState(
            undoCoordinator: coordinator,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history,
            uitestingOutputDirectory: sandbox.outputsURL
        )
    }

    private func makePNGData(width: Int = 24, height: Int = 18) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 40
            pixels[i + 1] = 140
            pixels[i + 2] = 220
            pixels[i + 3] = 255
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
        let cgImage = ctx.makeImage() else {
            throw NSError(domain: "Milestone10AClipboardPasteTests", code: 1)
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "Milestone10AClipboardPasteTests", code: 2)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return mutableData as Data
    }

    private func makeTIFFData(width: Int = 20, height: Int = 16) throws -> Data {
        let pngData = try makePNGData(width: width, height: height)
        guard let image = NSImage(data: pngData),
              let tiff = image.tiffRepresentation else {
            throw NSError(domain: "Milestone10AClipboardPasteTests", code: 3)
        }
        return tiff
    }

    // MARK: - 1. File URL Extraction & Safety Filtering

    func testFileURLExtractionTakesPrecedenceOverFinderTextAndValidatesRegularFiles() async throws {
        let pboard = makeIsolatedPasteboard()
        let validFile = sandbox.documentsURL.appendingPathComponent("sample_photo.png")
        try makePNGData().write(to: validFile)

        // Mimic Finder copy: file URL + filename string + icon TIFF
        pboard.declareTypes([.fileURL, .string, .tiff], owner: nil)
        XCTAssertTrue(pboard.writeObjects([validFile as NSURL]))
        pboard.setString("sample_photo.png", forType: .string)

        let result = try await ClipboardIntakeService.intake(from: pboard, stagingDirectory: stagingDir)
        XCTAssertEqual(result.sourceKind, .fileURLs)
        XCTAssertEqual(result.stagedURLs.map(\.standardizedFileURL), [validFile.standardizedFileURL])
        XCTAssertTrue(result.rejectedEntries.isEmpty)
        XCTAssertTrue(result.createdTempFiles.isEmpty)
    }

    func testFileURLFilteringRejectsDirectoriesSymlinksAndMissingFiles() async throws {
        let pboard = makeIsolatedPasteboard()

        let validFile = sandbox.documentsURL.appendingPathComponent("valid.png")
        try makePNGData().write(to: validFile)

        let directoryURL = sandbox.documentsURL.appendingPathComponent("SubFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let symlinkURL = sandbox.documentsURL.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: validFile)

        let missingURL = sandbox.documentsURL.appendingPathComponent("does_not_exist.png")

        XCTAssertTrue(pboard.writeObjects([
            validFile as NSURL,
            directoryURL as NSURL,
            symlinkURL as NSURL,
            missingURL as NSURL
        ]))

        let result = try await ClipboardIntakeService.intake(from: pboard, stagingDirectory: stagingDir)
        XCTAssertEqual(result.sourceKind, .fileURLs)
        XCTAssertEqual(result.stagedURLs.map(\.standardizedFileURL), [validFile.standardizedFileURL])
        XCTAssertEqual(result.rejectedEntries.count, 3)

        let rejectedErrors = result.rejectedEntries.map(\.error)
        XCTAssertTrue(rejectedErrors.contains {
            if case .folderRejected = $0 { return true }
            return false
        })
        XCTAssertTrue(rejectedErrors.contains {
            if case .symlinkRejected = $0 { return true }
            return false
        })
        XCTAssertTrue(rejectedErrors.contains {
            if case .fileNotFound = $0 { return true }
            return false
        })
    }

    func testAllInvalidFileURLsThrowAllFileURLsRejectedError() async throws {
        let pboard = makeIsolatedPasteboard()
        let folderURL = sandbox.documentsURL.appendingPathComponent("OnlyFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        XCTAssertTrue(pboard.writeObjects([folderURL as NSURL]))

        do {
            _ = try await ClipboardIntakeService.intake(from: pboard, stagingDirectory: stagingDir)
            XCTFail("Expected ClipboardIntakeError.allFileURLsRejected")
        } catch let error as ClipboardIntakeError {
            guard case .allFileURLsRejected(let rejected) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(rejected.count, 1)
        }
    }

    // MARK: - 2. Image Data Staging (.png / .tiff / NSImage)

    func testPNGDataStagesToPNGFile() async throws {
        let pboard = makeIsolatedPasteboard()
        let pngData = try makePNGData(width: 32, height: 24)
        pboard.setData(pngData, forType: .png)

        let result = try await ClipboardIntakeService.intake(from: pboard, stagingDirectory: stagingDir)
        XCTAssertEqual(result.sourceKind, .image)
        XCTAssertEqual(result.stagedURLs.count, 1)
        XCTAssertEqual(result.createdTempFiles, result.stagedURLs)

        let stagedURL = try XCTUnwrap(result.stagedURLs.first)
        XCTAssertEqual(stagedURL.pathExtension.lowercased(), "png")
        XCTAssertTrue(stagedURL.path.hasPrefix(stagingDir.standardizedFileURL.path))
        XCTAssertEqual(FileDetector().detect(url: stagedURL).bestFormat, .png)

        let written = try Data(contentsOf: stagedURL)
        XCTAssertTrue(written.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    func testTIFFDataConvertsAndStagesToPNGFile() async throws {
        let pboard = makeIsolatedPasteboard()
        let tiffData = try makeTIFFData(width: 28, height: 20)
        pboard.setData(tiffData, forType: .tiff)

        let result = try await ClipboardIntakeService.intake(from: pboard, stagingDirectory: stagingDir)
        XCTAssertEqual(result.sourceKind, .image)
        let stagedURL = try XCTUnwrap(result.stagedURLs.first)
        XCTAssertEqual(stagedURL.pathExtension.lowercased(), "png")
        XCTAssertEqual(FileDetector().detect(url: stagedURL).bestFormat, .png)

        let written = try Data(contentsOf: stagedURL)
        XCTAssertTrue(written.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let decoded = NSImage(contentsOf: stagedURL)
        XCTAssertNotNil(decoded)
    }

    func testNSImageObjectStagesToPNGFile() async throws {
        let pboard = makeIsolatedPasteboard()
        let pngData = try makePNGData(width: 18, height: 14)
        let nsImage = try XCTUnwrap(NSImage(data: pngData))
        XCTAssertTrue(pboard.writeObjects([nsImage]))

        let result = try await ClipboardIntakeService.intake(from: pboard, stagingDirectory: stagingDir)
        XCTAssertEqual(result.sourceKind, .image)
        let stagedURL = try XCTUnwrap(result.stagedURLs.first)
        XCTAssertEqual(stagedURL.pathExtension.lowercased(), "png")
        XCTAssertEqual(FileDetector().detect(url: stagedURL).bestFormat, .png)
    }

    func testCorruptPNGDataWithoutValidFallbackThrowsInvalidImageData() async throws {
        let pboard = makeIsolatedPasteboard()
        pboard.setData(Data([0x00, 0x01, 0x02, 0x03]), forType: .png)

        do {
            _ = try await ClipboardIntakeService.intake(from: pboard, stagingDirectory: stagingDir)
            XCTFail("Expected ClipboardIntakeError.invalidImageData")
        } catch let error as ClipboardIntakeError {
            XCTAssertEqual(error, .invalidImageData)
        }
    }

    // MARK: - 3. Raw Text, JSON, and XML Detection

    func testJSONObjectAndArrayStageAsJSON() async throws {
        let jsonObject = "  { \"app\": \"LocalConvert\", \"milestone\": 10, \"items\": [1, 2] } \n"
        XCTAssertEqual(ClipboardIntakeService.classifyText(jsonObject), .json)

        let pboard1 = makeIsolatedPasteboard()
        pboard1.setString(jsonObject, forType: .string)
        let res1 = try await ClipboardIntakeService.intake(from: pboard1, stagingDirectory: stagingDir)
        XCTAssertEqual(res1.sourceKind, .json)
        let url1 = try XCTUnwrap(res1.stagedURLs.first)
        XCTAssertEqual(url1.pathExtension.lowercased(), "json")
        XCTAssertEqual(FileDetector().detect(url: url1).bestFormat, .json)
        XCTAssertEqual(try String(contentsOf: url1, encoding: .utf8), jsonObject)

        let jsonArray = "[{\"id\": 1}, {\"id\": 2}]"
        XCTAssertEqual(ClipboardIntakeService.classifyText(jsonArray), .json)
        let pboard2 = makeIsolatedPasteboard()
        pboard2.setString(jsonArray, forType: .string)
        let res2 = try await ClipboardIntakeService.intake(from: pboard2, stagingDirectory: stagingDir)
        XCTAssertEqual(res2.sourceKind, .json)
        XCTAssertEqual(res2.stagedURLs.first?.pathExtension.lowercased(), "json")
    }

    func testXMLDeclarationAndTagsStageAsXML() async throws {
        let xmlWithDeclaration = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config><mode>offline</mode></config>
        """
        XCTAssertEqual(ClipboardIntakeService.classifyText(xmlWithDeclaration), .xml)

        let pboard1 = makeIsolatedPasteboard()
        pboard1.setString(xmlWithDeclaration, forType: .string)
        let res1 = try await ClipboardIntakeService.intake(from: pboard1, stagingDirectory: stagingDir)
        XCTAssertEqual(res1.sourceKind, .xml)
        let url1 = try XCTUnwrap(res1.stagedURLs.first)
        XCTAssertEqual(url1.pathExtension.lowercased(), "xml")
        XCTAssertEqual(FileDetector().detect(url: url1).bestFormat, .xml)

        let xmlWithoutDeclaration = "<catalog><item id=\"1\">Sample</item></catalog>"
        XCTAssertEqual(ClipboardIntakeService.classifyText(xmlWithoutDeclaration), .xml)

        let pboard2 = makeIsolatedPasteboard()
        pboard2.setString(xmlWithoutDeclaration, forType: .string)
        let res2 = try await ClipboardIntakeService.intake(from: pboard2, stagingDirectory: stagingDir)
        XCTAssertEqual(res2.sourceKind, .xml)
        XCTAssertEqual(res2.stagedURLs.first?.pathExtension.lowercased(), "xml")
    }

    func testPlainTextAndMalformedStructuredTextFallBackToTXT() async throws {
        let candidates = [
            "Hello from LocalConvert clipboard!",
            "42",
            "\"quoted string\"",
            "{\"broken\": ",
            "<unclosed>not valid xml",
            "2 < 3 and 5 > 4"
        ]

        for sample in candidates {
            XCTAssertEqual(ClipboardIntakeService.classifyText(sample), .plainText, "Expected .plainText for: \(sample)")
        }

        let pboard = makeIsolatedPasteboard()
        pboard.setString("Hello from LocalConvert clipboard!", forType: .string)
        let result = try await ClipboardIntakeService.intake(from: pboard, stagingDirectory: stagingDir)
        XCTAssertEqual(result.sourceKind, .plainText)
        let stagedURL = try XCTUnwrap(result.stagedURLs.first)
        XCTAssertEqual(stagedURL.pathExtension.lowercased(), "txt")
        XCTAssertEqual(FileDetector().detect(url: stagedURL).bestFormat, .txt)
    }

    // MARK: - 4. Empty / Whitespace / Unsupported Pasteboard Handling

    func testEmptyWhitespaceAndUnsupportedPasteboardsAreRejected() async throws {
        let emptyBoard = makeIsolatedPasteboard()
        do {
            _ = try await ClipboardIntakeService.intake(from: emptyBoard, stagingDirectory: stagingDir)
            XCTFail("Expected ClipboardIntakeError.emptyPasteboard")
        } catch let error as ClipboardIntakeError {
            XCTAssertEqual(error, .emptyPasteboard)
        }

        for whitespace in ["", "   \n\t  ", "\u{FEFF} \n"] {
            XCTAssertNil(ClipboardIntakeService.classifyText(whitespace))
            let wsBoard = makeIsolatedPasteboard()
            wsBoard.setString(whitespace, forType: .string)
            do {
                _ = try await ClipboardIntakeService.intake(from: wsBoard, stagingDirectory: stagingDir)
                XCTFail("Expected ClipboardIntakeError.emptyPasteboard for whitespace")
            } catch let error as ClipboardIntakeError {
                XCTAssertEqual(error, .emptyPasteboard)
            }
        }

        let unsupportedBoard = makeIsolatedPasteboard()
        let customType = NSPasteboard.PasteboardType("com.localconvert.test.unsupported")
        unsupportedBoard.declareTypes([customType], owner: nil)
        unsupportedBoard.setData(Data([0xAA, 0xBB]), forType: customType)
        do {
            _ = try await ClipboardIntakeService.intake(from: unsupportedBoard, stagingDirectory: stagingDir)
            XCTFail("Expected ClipboardIntakeError.unsupportedPasteboardContent")
        } catch let error as ClipboardIntakeError {
            XCTAssertEqual(error, .unsupportedPasteboardContent)
        }
    }

    // MARK: - 5. AppState Integration & Text-Input Paste Guard

    func testPasteCommandStagesItemsAndNavigatesToConvertTab() async throws {
        let appState = makeIsolatedAppState()
        appState.selectedTab = .history
        XCTAssertTrue(appState.droppedFiles.isEmpty)

        let pboard = makeIsolatedPasteboard()
        pboard.setString("{\"hello\":\"world\"}", forType: .string)

        let handled = await LocalConvertApp.handlePasteToConvertCommand(
            appState: appState,
            firstResponder: nil,
            pasteboard: pboard,
            stagingDirectory: stagingDir
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(appState.selectedTab, .convert)
        XCTAssertEqual(appState.droppedFiles.count, 1)
        XCTAssertEqual(appState.droppedFiles.first?.detectedFormat, .json)
        XCTAssertFalse(appState.showError)
    }

    func testPasteCommandYieldsWhenEditableTextResponderIsFocused() async throws {
        let appState = makeIsolatedAppState()
        appState.selectedTab = .settings

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        textView.isEditable = true

        XCTAssertFalse(
            LocalConvertApp.shouldAllowPasteToConvertShortcut(
                isConverting: false,
                isEscapeBlocked: false,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false,
                isCommandPalettePresented: false,
                firstResponder: textView
            )
        )

        XCTAssertFalse(
            LocalConvertApp.shouldAllowPasteToConvertShortcut(
                isConverting: false,
                isEscapeBlocked: false,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false,
                isCommandPalettePresented: true,
                firstResponder: nil
            )
        )

        XCTAssertTrue(
            LocalConvertApp.shouldAllowPasteToConvertShortcut(
                isConverting: false,
                isEscapeBlocked: false,
                isTextInputActive: false,
                isEditingHistoryPresented: false,
                isURLConfirmationPresented: false,
                isErrorAlertPresented: false,
                isCommandPalettePresented: false,
                firstResponder: nil
            )
        )

        let pboard = makeIsolatedPasteboard()
        pboard.setString("Should not be staged as file", forType: .string)

        let handled = await LocalConvertApp.handlePasteToConvertCommand(
            appState: appState,
            firstResponder: textView,
            pasteboard: pboard,
            stagingDirectory: stagingDir
        )

        XCTAssertFalse(handled)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        XCTAssertEqual(appState.selectedTab, .settings)
    }

    func testEmptyPasteboardReportsFriendlyNoticeWithoutTabSwitch() async {
        let appState = makeIsolatedAppState()
        appState.selectedTab = .presets
        let emptyBoard = makeIsolatedPasteboard()

        let result = await ClipboardIntakeService.pasteToConvert(
            into: appState,
            from: emptyBoard,
            stagingDirectory: stagingDir
        )

        XCTAssertNil(result)
        XCTAssertTrue(appState.droppedFiles.isEmpty)
        XCTAssertEqual(appState.selectedTab, .presets)
        XCTAssertTrue(appState.showError)
        XCTAssertEqual(appState.errorTitle, "Nothing to Paste")
    }
}
