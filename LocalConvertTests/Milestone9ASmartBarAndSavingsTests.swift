import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

@MainActor
final class Milestone9ASmartBarAndSavingsTests: XCTestCase {

    private var sandbox: TestSandbox!
    private var previousAppState: AppState?

    override func setUp() async throws {
        continueAfterFailure = false
        previousAppState = AppState.shared
        sandbox = try TestSandbox(runID: "M9ASmartBar-\(UUID().uuidString)")
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
        let coordinator = UndoRedoCoordinator(
            journalDirectoryURL: sandbox.undoHistoryURL,
            artifactManager: RecoveryArtifactManager(baseDirectoryURL: sandbox.recoveryArtifactsURL)
        )
        let history = HistoryManager(fileURL: sandbox.historyFileURL)
        return AppState(
            undoCoordinator: coordinator,
            watchFolderStoreURL: sandbox.watchFoldersFileURL,
            historyManager: history
        )
    }

    private func writeSyntheticPNG(to url: URL) throws {
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
            throw NSError(domain: "Milestone9ASmartBarAndSavingsTests", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Milestone9ASmartBarAndSavingsTests", code: 2)
        }
    }

    private func makeDroppedFile(format: FileFormat?, name: String) -> DroppedFile {
        let url = sandbox.rootURL.appendingPathComponent(name)
        let result = FileDetectionResult(
            url: url,
            detectedFormat: format,
            extensionFormat: format,
            utTypeFormat: format,
            magicBytesFormat: format,
            confidence: format == nil ? .unknown : .high
        )
        return DroppedFile(url: url, detectionResult: result)
    }

    // MARK: - SmartSuggestionEngine Category Tests

    func testEmptyQueueProducesNoSuggestions() {
        let plan = SmartSuggestionEngine.suggest(for: [FileFormat?]())
        XCTAssertEqual(plan.category, .empty)
        XCTAssertTrue(plan.actions.isEmpty)
    }

    func testPDFOnlyQueueRecommendsPDFActions() {
        let plan = SmartSuggestionEngine.suggest(for: [.pdf, .pdf])
        XCTAssertEqual(plan.category, .pdf)
        XCTAssertEqual(
            plan.actions.map(\.title),
            ["Compress PDF", "Convert to DOCX", "PDF → Images", "OCR"]
        )
        XCTAssertEqual(
            plan.actions.map(\.id),
            [.compressPDF, .convertToDOCX, .pdfToImages, .ocrPDF]
        )
        XCTAssertTrue(plan.actions.allSatisfy(\.isEnabled))
    }

    func testImageOnlyQueueRecommendsImageActions() {
        let plan = SmartSuggestionEngine.suggest(for: [.png, .jpg, .heic, .dng])
        XCTAssertEqual(plan.category, .image)
        XCTAssertEqual(
            plan.actions.map(\.title),
            ["WebP Optimize", "Remove Background", "Strip Metadata/GPS", "Resize"]
        )
        XCTAssertEqual(
            plan.actions.map(\.id),
            [.webpOptimize, .removeBackground, .stripMetadata, .resizeImages]
        )
        XCTAssertTrue(plan.actions.allSatisfy(\.isEnabled))
    }

    func testAudioVideoQueueWithVideoEnablesAllFourMediaActions() {
        let plan = SmartSuggestionEngine.suggest(for: [.mov, .wav])
        XCTAssertEqual(plan.category, .audioVideo)
        XCTAssertEqual(
            plan.actions.map(\.title),
            ["Extract MP3", "Compact MP4", "iPhone Ringtone (.m4r)", "Trim"]
        )
        XCTAssertEqual(
            plan.actions.map(\.id),
            [.extractMP3, .compactMP4, .iphoneRingtoneM4R, .trimMedia]
        )
        XCTAssertTrue(plan.actions.allSatisfy(\.isEnabled))
    }

    func testAudioOnlyQueueDisablesCompactMP4() {
        let wavPlan = SmartSuggestionEngine.suggest(for: [.wav, .flac])
        XCTAssertEqual(wavPlan.category, .audioVideo)
        XCTAssertEqual(wavPlan.actions.first(where: { $0.id == .extractMP3 })?.isEnabled, true)
        XCTAssertEqual(wavPlan.actions.first(where: { $0.id == .compactMP4 })?.isEnabled, false)
        XCTAssertEqual(wavPlan.actions.first(where: { $0.id == .iphoneRingtoneM4R })?.isEnabled, true)
        XCTAssertEqual(wavPlan.actions.first(where: { $0.id == .trimMedia })?.isEnabled, true)

        let mp3OnlyPlan = SmartSuggestionEngine.suggest(for: [.mp3])
        XCTAssertEqual(mp3OnlyPlan.category, .audioVideo)
        XCTAssertEqual(mp3OnlyPlan.actions.first(where: { $0.id == .extractMP3 })?.isEnabled, false)
        XCTAssertEqual(mp3OnlyPlan.actions.first(where: { $0.id == .compactMP4 })?.isEnabled, false)
        XCTAssertEqual(mp3OnlyPlan.actions.first(where: { $0.id == .iphoneRingtoneM4R })?.isEnabled, true)
    }

    func testMixedBatchRecommendsPresetAndConvertAll() {
        let plan = SmartSuggestionEngine.suggest(for: [.pdf, .png])
        XCTAssertEqual(plan.category, .mixed)
        XCTAssertEqual(plan.actions.map(\.title), ["Apply Saved Preset...", "Convert All"])
        XCTAssertEqual(plan.actions.map(\.id), [.applySavedPreset, .convertAll])
        XCTAssertEqual(plan.actions.first(where: { $0.id == .applySavedPreset })?.isEnabled, true)
        XCTAssertEqual(plan.actions.first(where: { $0.id == .convertAll })?.isEnabled, true)
    }

    func testNonPDFDocumentFallsBackToMixedBatchActions() {
        let plan = SmartSuggestionEngine.suggest(for: [.docx, .xlsx])
        XCTAssertEqual(plan.category, .mixed)
        XCTAssertEqual(plan.actions.map(\.id), [.applySavedPreset, .convertAll])
    }

    func testUnknownOnlyDroppedFilesDisableConvertAllInMixedPlan() {
        let unknownFile = makeDroppedFile(format: nil, name: "mystery.bin")
        let plan = SmartSuggestionEngine.suggest(for: [unknownFile])
        XCTAssertEqual(plan.category, .mixed)
        XCTAssertEqual(plan.actions.first(where: { $0.id == .applySavedPreset })?.isEnabled, true)
        XCTAssertEqual(plan.actions.first(where: { $0.id == .convertAll })?.isEnabled, false)
    }

    // MARK: - SmartBarActionExecutor Wiring Tests

    func testSmartBarResizeOptionsUpdateQueuedImages() throws {
        let appState = makeIsolatedAppState()
        let imgURL = sandbox.rootURL.appendingPathComponent("sample.png")
        try writeSyntheticPNG(to: imgURL)
        appState.handleDroppedURLs([imgURL])
        XCTAssertEqual(appState.droppedFiles.count, 1)

        SmartBarActionExecutor.applyResize(.scale50, appState: appState, startConversion: false)
        XCTAssertEqual(appState.droppedFiles[0].options.resizeMode, .percentage)
        XCTAssertEqual(appState.droppedFiles[0].options.resizePercentage, 0.50)

        SmartBarActionExecutor.applyResize(.maxWidth1920, appState: appState, startConversion: false)
        XCTAssertEqual(appState.droppedFiles[0].options.resizeMode, .exactWidth)
        XCTAssertEqual(appState.droppedFiles[0].options.resizeWidth, 1920)
        XCTAssertTrue(appState.droppedFiles[0].options.preserveAspectRatio)
    }

    func testSmartBarTrimOnAudioOnlyNavigatesToAudioToolsTrim() {
        let appState = makeIsolatedAppState()
        let audioFile = makeDroppedFile(format: .wav, name: "voice.wav")
        appState.droppedFiles = [audioFile]

        var openedVideoSheet = false
        SmartBarActionExecutor.runTrim(appState: appState) { _ in
            openedVideoSheet = true
        }

        XCTAssertFalse(openedVideoSheet)
        XCTAssertEqual(appState.selectedTab, .audioWorkspace)
        XCTAssertEqual(appState.audioWorkspace.activeMode, .audioTools)
        XCTAssertEqual(appState.audioToolboxStore.selectedSection, .trim)
        XCTAssertEqual(appState.audioToolboxStore.selectedFileIds, [audioFile.id])
    }

    // MARK: - SizeSavingsFormatter Tests

    func testSizeSavingsFormatterSmallerOutput() throws {
        let summary = try XCTUnwrap(SizeSavingsFormatter.format(inputBytes: 10_000_000, outputBytes: 1_300_000))
        XCTAssertEqual(summary.direction, .smaller(percent: 87))
        XCTAssertEqual(summary.deltaText, "87% smaller")
        XCTAssertTrue(summary.direction.isSavings)

        let expectedBefore = ByteCountFormatter.string(fromByteCount: 10_000_000, countStyle: .file)
        let expectedAfter = ByteCountFormatter.string(fromByteCount: 1_300_000, countStyle: .file)
        XCTAssertEqual(summary.beforeFormatted, expectedBefore)
        XCTAssertEqual(summary.afterFormatted, expectedAfter)
        XCTAssertEqual(summary.badgeText, "\(expectedBefore) → \(expectedAfter) · 87% smaller")
    }

    func testSizeSavingsFormatterSubOnePercentSmallerOutput() throws {
        let summary = try XCTUnwrap(SizeSavingsFormatter.format(inputBytes: 10_000_000, outputBytes: 9_990_000))
        XCTAssertEqual(summary.direction, .smaller(percent: 0))
        XCTAssertEqual(summary.deltaText, "<1% smaller")
        XCTAssertTrue(summary.direction.isSavings)
    }

    func testSizeSavingsFormatterLargerOutput() throws {
        let summary = try XCTUnwrap(SizeSavingsFormatter.format(inputBytes: 1_000_000, outputBytes: 1_120_000))
        XCTAssertEqual(summary.direction, .larger(percent: 12))
        XCTAssertEqual(summary.deltaText, "+12% larger")
        XCTAssertFalse(summary.direction.isSavings)
        XCTAssertTrue(summary.badgeText.hasSuffix("· +12% larger"))
    }

    func testSizeSavingsFormatterSubOnePercentLargerOutput() throws {
        let summary = try XCTUnwrap(SizeSavingsFormatter.format(inputBytes: 10_000_000, outputBytes: 10_010_000))
        XCTAssertEqual(summary.direction, .larger(percent: 0))
        XCTAssertEqual(summary.deltaText, "+<1% larger")
        XCTAssertFalse(summary.direction.isSavings)
    }

    func testSizeSavingsFormatterEqualOutput() throws {
        let summary = try XCTUnwrap(SizeSavingsFormatter.format(inputBytes: 5_000_000, outputBytes: 5_000_000))
        XCTAssertEqual(summary.direction, .same)
        XCTAssertEqual(summary.deltaText, "0% same")
        XCTAssertFalse(summary.direction.isSavings)
        XCTAssertTrue(summary.badgeText.hasSuffix("· 0% same"))
    }

    func testSizeSavingsFormatterReturnsNilForMissingOrNonPositiveSizes() {
        XCTAssertNil(SizeSavingsFormatter.format(inputBytes: nil, outputBytes: 1_024))
        XCTAssertNil(SizeSavingsFormatter.format(inputBytes: 1_024, outputBytes: nil))
        XCTAssertNil(SizeSavingsFormatter.format(inputBytes: nil, outputBytes: nil))
        XCTAssertNil(SizeSavingsFormatter.format(inputBytes: 0, outputBytes: 1_024))
        XCTAssertNil(SizeSavingsFormatter.format(inputBytes: 1_024, outputBytes: 0))
        XCTAssertNil(SizeSavingsFormatter.format(inputBytes: -100, outputBytes: 1_024))
        XCTAssertNil(SizeSavingsFormatter.format(inputBytes: 1_024, outputBytes: -1))
    }
}
