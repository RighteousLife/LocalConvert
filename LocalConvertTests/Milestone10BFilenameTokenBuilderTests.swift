import XCTest
import Foundation
@testable import LocalConvert

@MainActor
final class Milestone10BFilenameTokenBuilderTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUp() async throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "M10BFilenameTokens-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
    }

    override func tearDown() async throws {
        AppStoragePaths.clearTestOverrides()
        if let sandbox {
            if case .failure(let error) = sandbox.cleanup() {
                XCTFail("TestSandbox cleanup failed: \(error.localizedDescription)")
            }
        }
        sandbox = nil
    }

    private func fixedDate() -> Date {
        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        comps.year = 2026
        comps.month = 11
        comps.day = 26
        comps.hour = 15
        comps.minute = 8
        comps.second = 37
        return comps.date ?? Date(timeIntervalSince1970: 1_795_705_717)
    }

    private var utcTimeZone: TimeZone {
        TimeZone(secondsFromGMT: 0)!
    }

    // MARK: - 1. Rich Token Expansion

    func testAllRichTokensExpandCleanly() {
        let inputURL = sandbox.documentsURL.appendingPathComponent("presentation.pptx")
        let date = fixedDate()

        let expanded = OutputManager.expandFilenameTemplate(
            "{name}_{ext}_{format}_{date}_{time}_{resolution}_{width}x{height}_{preset}_{index}",
            inputURL: inputURL,
            outputFormat: .pdf,
            date: date,
            timeZone: utcTimeZone,
            width: 1920,
            height: 1080,
            presetName: "Web Optimized",
            index: 4
        )

        XCTAssertEqual(
            expanded,
            "presentation_pdf_pdf_2026-11-26_15-08-37_1920x1080_1920x1080_Web Optimized_4.pdf"
        )
        XCTAssertFalse(expanded.contains(":"))
        XCTAssertFalse(expanded.contains("/"))
    }

    func testTrailingDotExtTokenDoesNotDuplicateExtension() {
        let inputURL = sandbox.documentsURL.appendingPathComponent("presentation.pptx")
        let date = fixedDate()

        let standard = OutputManager.expandFilenameTemplate(
            "{name}_{date}",
            inputURL: inputURL,
            outputFormat: .pdf,
            date: date,
            timeZone: utcTimeZone
        )
        let explicitExt = OutputManager.expandFilenameTemplate(
            "{name}_{date}.{ext}",
            inputURL: inputURL,
            outputFormat: .pdf,
            date: date,
            timeZone: utcTimeZone
        )

        XCTAssertEqual(standard, "presentation_2026-11-26.pdf")
        XCTAssertEqual(explicitExt, "presentation_2026-11-26.pdf")

        let preview = OutputManager.previewFilename(
            for: "{name}_{date}",
            date: date,
            timeZone: utcTimeZone
        )
        XCTAssertEqual(preview, "presentation_2026-11-26.pdf")
    }

    func testMissingOptionalTokensCollapseWithoutDanglingSeparatorsOrStrayX() {
        let inputURL = sandbox.documentsURL.appendingPathComponent("my__notes.txt")
        let date = fixedDate()

        let noDimensions = OutputManager.expandFilenameTemplate(
            "{name}_{width}x{height}_{resolution}_{preset}_{date}",
            inputURL: inputURL,
            outputFormat: .pdf,
            date: date,
            timeZone: utcTimeZone,
            width: nil,
            height: nil,
            presetName: nil,
            index: nil
        )
        XCTAssertEqual(noDimensions, "my__notes_2026-11-26.pdf")

        let trailingEmpty = OutputManager.expandFilenameTemplate(
            "{name}_{resolution}",
            inputURL: inputURL,
            outputFormat: .pdf,
            date: date,
            timeZone: utcTimeZone,
            width: nil,
            height: nil
        )
        XCTAssertEqual(trailingEmpty, "my__notes.pdf")

        let leadingEmpty = OutputManager.expandFilenameTemplate(
            "{preset}_{name}",
            inputURL: inputURL,
            outputFormat: .pdf,
            date: date,
            timeZone: utcTimeZone,
            presetName: nil
        )
        XCTAssertEqual(leadingEmpty, "my__notes.pdf")

        let partialWidthOnly = OutputManager.expandFilenameTemplate(
            "{name}_{width}x{height}",
            inputURL: inputURL,
            outputFormat: .pdf,
            width: 1280,
            height: nil
        )
        XCTAssertEqual(partialWidthOnly, "my__notes.pdf")
    }

    func testResizeOptionsAndPresetOptionsFallbackIntoTokens() {
        let inputURL = sandbox.documentsURL.appendingPathComponent("Quarterly.Report.v2.png")
        var options = ConversionOptions.default
        options.preset = .maximumQuality
        options.resizeMode = .exactDimensions
        options.resizeWidth = 1600
        options.resizeHeight = 900

        let expanded = OutputManager.expandFilenameTemplate(
            "{name}_{resolution}_{preset}_{counter}",
            inputURL: inputURL,
            outputFormat: .webp,
            options: options,
            index: 2
        )

        XCTAssertEqual(expanded, "Quarterly.Report.v2_1600x900_Maximum Quality_002.webp")
    }

    func testAllImageResizeModesResolveResolutionAndWidthHeightCleanly() {
        let inputURL = sandbox.documentsURL.appendingPathComponent("photo.png")

        // .none ignores stale resizeWidth / resizeHeight
        var noneOptions = ConversionOptions.default
        noneOptions.resizeMode = .none
        noneOptions.resizeWidth = 1600
        noneOptions.resizeHeight = 900
        XCTAssertEqual(
            OutputManager.expandFilenameTemplate("{name}_{resolution}_{width}x{height}", inputURL: inputURL, outputFormat: .webp, options: noneOptions),
            "photo.webp"
        )

        // .exactWidth uses resizeWidth only, ignores stale resizeHeight
        var widthOptions = ConversionOptions.default
        widthOptions.resizeMode = .exactWidth
        widthOptions.resizeWidth = 1920
        widthOptions.resizeHeight = 900
        XCTAssertEqual(
            OutputManager.expandFilenameTemplate("{name}_{resolution}_{width}x{height}", inputURL: inputURL, outputFormat: .webp, options: widthOptions),
            "photo_1920w.webp"
        )

        // .exactHeight uses resizeHeight only, ignores stale resizeWidth
        var heightOptions = ConversionOptions.default
        heightOptions.resizeMode = .exactHeight
        heightOptions.resizeWidth = 1920
        heightOptions.resizeHeight = 1080
        XCTAssertEqual(
            OutputManager.expandFilenameTemplate("{name}_{resolution}_{width}x{height}", inputURL: inputURL, outputFormat: .webp, options: heightOptions),
            "photo_1080h.webp"
        )

        // .exactDimensions resolves both {resolution} and {width}x{height}
        var exactOptions = ConversionOptions.default
        exactOptions.resizeMode = .exactDimensions
        exactOptions.resizeWidth = 1280
        exactOptions.resizeHeight = 720
        XCTAssertEqual(
            OutputManager.expandFilenameTemplate("{name}_{resolution}_{width}x{height}", inputURL: inputURL, outputFormat: .webp, options: exactOptions),
            "photo_1280x720_1280x720.webp"
        )

        // .percentage uses resizePercentage and collapses {width}x{height}
        var pctOptions = ConversionOptions.default
        pctOptions.resizeMode = .percentage
        pctOptions.resizePercentage = 0.5
        pctOptions.resizeWidth = 1280
        pctOptions.resizeHeight = 720
        XCTAssertEqual(
            OutputManager.expandFilenameTemplate("{name}_{resolution}_{width}x{height}", inputURL: inputURL, outputFormat: .webp, options: pctOptions),
            "photo_50pct.webp"
        )

        // .longestEdge resolves max edge for {resolution} and collapses {width}x{height}
        var longestOptions = ConversionOptions.default
        longestOptions.resizeMode = .longestEdge
        longestOptions.resizeWidth = 2048
        XCTAssertEqual(
            OutputManager.expandFilenameTemplate("{name}_{resolution}_{width}x{height}", inputURL: inputURL, outputFormat: .webp, options: longestOptions),
            "photo_2048max.webp"
        )

        // .shortestEdge resolves min edge for {resolution} and collapses {width}x{height}
        var shortestOptions = ConversionOptions.default
        shortestOptions.resizeMode = .shortestEdge
        shortestOptions.resizeHeight = 1080
        XCTAssertEqual(
            OutputManager.expandFilenameTemplate("{name}_{resolution}_{width}x{height}", inputURL: inputURL, outputFormat: .webp, options: shortestOptions),
            "photo_1080min.webp"
        )
    }

    // MARK: - 2. Existing Naming Templates & Collision Compatibility

    func testExistingNamingPoliciesAndPrefixSuffixPreserved() throws {
        let outDir = sandbox.outputsURL
        let inputURL = sandbox.documentsURL.appendingPathComponent("Quarterly.Report.v2.pdf")

        var options = ConversionOptions.default
        options.customOptions["output_prefix"] = "pre_"
        options.customOptions["output_suffix"] = "_audio"

        let expected = ConversionManager.outputURL(
            for: inputURL,
            format: .mp3,
            in: outDir,
            options: options
        )
        let templated = OutputManager.safeOutputURL(
            for: inputURL,
            format: .mp3,
            in: outDir,
            template: OutputManager.defaultFilenameTemplate,
            options: options
        )
        XCTAssertEqual(templated.lastPathComponent, expected.lastPathComponent)
        XCTAssertEqual(templated.lastPathComponent, "pre_Quarterly.Report.v2_audio.mp3")

        // Compound archive extension stripping preserved
        let archiveURL = sandbox.documentsURL.appendingPathComponent("bundle.tar.gz")
        let expandedArchive = OutputManager.expandFilenameTemplate(
            "{name}_{format}.{ext}",
            inputURL: archiveURL,
            outputFormat: .zip
        )
        XCTAssertEqual(expandedArchive, "bundle_zip.zip")

        // Existing 3-arg OutputManager.safeOutputURL collision behavior preserved
        let simpleInput = sandbox.documentsURL.appendingPathComponent("report.pdf")
        let first = OutputManager.safeOutputURL(for: simpleInput, format: .pdf, in: outDir)
        try Data("1".utf8).write(to: first)
        let second = OutputManager.safeOutputURL(for: simpleInput, format: .pdf, in: outDir)
        XCTAssertEqual(first.lastPathComponent, "report.pdf")
        XCTAssertEqual(second.lastPathComponent, "report (1).pdf")
    }

    // MARK: - 3. Path-Traversal, Separator, Control Char & Token Injection Sanitization

    func testSanitizesPathSeparatorsTraversalAndNullBytesInTemplateAndTokens() {
        let outDir = sandbox.outputsURL
        let inputURL = sandbox.documentsURL.appendingPathComponent("foo:bar..baz\0.png")

        var options = ConversionOptions.default
        options.customOptions["output_prefix"] = "../pre/"
        options.customOptions["output_suffix"] = ":suf\\.."

        let dangerousTemplate = "../../etc/{name}/sub:dir\\{preset}\0"
        let safeURL = OutputManager.safeOutputURL(
            for: inputURL,
            format: .jpg,
            in: outDir,
            template: dangerousTemplate,
            options: options,
            presetName: "Print / Archive:..\\evil\0"
        )

        XCTAssertEqual(safeURL.deletingLastPathComponent().standardizedFileURL, outDir.standardizedFileURL)
        let filename = safeURL.lastPathComponent
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(":"))
        XCTAssertFalse(filename.contains("\\"))
        XCTAssertFalse(filename.contains(".."))
        XCTAssertFalse(filename.contains("\0"))
        XCTAssertEqual(safeURL.pathExtension, "jpg")

        // Token injection in filename must not expand {date} or {preset}
        let injectionInput = sandbox.documentsURL.appendingPathComponent("evil_{date}_{preset}.png")
        let injectedExpanded = OutputManager.expandFilenameTemplate(
            "{name}",
            inputURL: injectionInput,
            outputFormat: .png,
            date: fixedDate(),
            timeZone: utcTimeZone,
            presetName: "Web"
        )
        XCTAssertEqual(injectedExpanded, "evil_{date}_{preset}.png")

        // Pure dot traversal input/template falls back cleanly to non-traversal filename
        let dotResult = OutputManager.expandFilenameTemplate(
            ".{preset}.",
            inputURL: sandbox.documentsURL.appendingPathComponent("..png"),
            outputFormat: .pdf,
            presetName: nil
        )
        XCTAssertFalse(dotResult.isEmpty)
        XCTAssertFalse(dotResult.hasPrefix("."))
        XCTAssertFalse(dotResult.contains(".."))
        XCTAssertTrue(dotResult.hasSuffix(".pdf"))
    }

    // MARK: - 4. 240 UTF-8 Byte Clamping (ASCII + Multi-Byte Turkish / Emoji / Combining)

    func testClampsFilenamesTo240UTF8BytesPreservingExtensionAndValidUTF8() {
        let outDir = sandbox.outputsURL

        // 1. Long ASCII stem
        let longASCIIURL = sandbox.documentsURL.appendingPathComponent(String(repeating: "a", count: 320) + ".png")
        let clampedASCII = OutputManager.expandFilenameTemplate(
            "{name}_{date}",
            inputURL: longASCIIURL,
            outputFormat: .webp,
            date: fixedDate(),
            timeZone: utcTimeZone
        )
        XCTAssertLessThanOrEqual(clampedASCII.utf8.count, 240)
        XCTAssertTrue(clampedASCII.hasSuffix(".webp"))

        // 2. Multi-byte Turkish characters (2 bytes each in UTF-8)
        let turkishStem = String(repeating: "şğüıöçŞĞÜİÖÇ", count: 25) // 300 chars = 600 UTF-8 bytes
        let turkishURL = sandbox.documentsURL.appendingPathComponent("\(turkishStem).docx")
        let clampedTurkish = OutputManager.expandFilenameTemplate(
            "{name}_{date}",
            inputURL: turkishURL,
            outputFormat: .pdf,
            date: fixedDate(),
            timeZone: utcTimeZone
        )
        XCTAssertLessThanOrEqual(clampedTurkish.utf8.count, 240)
        XCTAssertTrue(clampedTurkish.hasSuffix(".pdf"))
        XCTAssertEqual(String(data: Data(clampedTurkish.utf8), encoding: .utf8), clampedTurkish)
        XCTAssertFalse(clampedTurkish.contains("\u{FFFD}"))

        // 3. 4-byte emoji + combining grapheme clusters
        let emojiStem = String(repeating: "🚀e\u{0301}漢", count: 50) // 50 * 10 = 500 UTF-8 bytes
        let emojiURL = sandbox.documentsURL.appendingPathComponent("\(emojiStem).png")
        let clampedEmojiURL = OutputManager.safeOutputURL(
            for: emojiURL,
            format: .tgz,
            in: outDir,
            template: "{name}_{preset}",
            presetName: "Web"
        )
        let emojiName = clampedEmojiURL.lastPathComponent
        XCTAssertLessThanOrEqual(emojiName.utf8.count, 240)
        XCTAssertTrue(emojiName.hasSuffix(".tar.gz"))
        XCTAssertEqual(String(data: Data(emojiName.utf8), encoding: .utf8), emojiName)
        XCTAssertFalse(emojiName.contains("\u{FFFD}"))
    }

    // MARK: - 5. Persistence & Chip Insertion Helpers (UserDefaults Isolated)

    func testTemplatePersistenceAndChipInsertionHelpersAreIsolated() {
        let isolatedDefaults = sandbox.makeUserDefaults()
        let stdBefore = UserDefaults.standard.string(forKey: OutputManager.filenameTemplateKey)

        XCTAssertEqual(OutputManager.filenameTemplate(defaults: isolatedDefaults), "{name}")

        var template = OutputManager.filenameTemplate(defaults: isolatedDefaults)
        template = OutputManager.appendingToken(.date, to: template)
        XCTAssertEqual(template, "{name}_{date}")

        template = OutputManager.appendingToken(.resolution, to: template)
        XCTAssertEqual(template, "{name}_{date}_{resolution}")

        OutputManager.setFilenameTemplate(template, defaults: isolatedDefaults)
        XCTAssertEqual(OutputManager.filenameTemplate(defaults: isolatedDefaults), "{name}_{date}_{resolution}")

        // All 9 documented UI chips exist
        XCTAssertEqual(
            FilenameTemplateToken.allCases.map(\.rawValue),
            ["{name}", "{ext}", "{format}", "{date}", "{time}", "{resolution}", "{width}x{height}", "{preset}", "{index}"]
        )

        OutputManager.resetPreferences(defaults: isolatedDefaults)
        XCTAssertEqual(OutputManager.filenameTemplate(defaults: isolatedDefaults), "{name}")

        // Host UserDefaults.standard must remain untouched
        XCTAssertEqual(UserDefaults.standard.string(forKey: OutputManager.filenameTemplateKey), stdBefore)
    }
}
