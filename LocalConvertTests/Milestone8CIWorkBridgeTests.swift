import XCTest
import AppKit
import CoreGraphics
import PDFKit
@testable import LocalConvert

final class Milestone8CIWorkBridgeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConversionManager.clearReservedOutputURLs()
    }

    override func tearDown() {
        ConversionManager.clearReservedOutputURLs()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String = "M8C-iWork") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeDummyInput(in directory: URL, filename: String) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        try Data("iwork-test-fixture".utf8).write(to: url)
        return url
    }

    private static func writeValidPDF(at url: URL, text: String = "Milestone 8C iWork Test") throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw NSError(domain: "M8CIWorkTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor.white)
        ctx.fill(box)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func countIWorkTempDirsInSystemTemp() -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("LocalConvert-iWork-") }.count
    }

    // MARK: - 1. Supported Format & Output Matrix

    func testSupportedFormatMatrixForPagesNumbersAndKeynote() {
        let engine = OfficeConversionEngine()

        XCTAssertTrue(engine.provider is BundledLibreOfficeProvider)
        XCTAssertTrue(engine.supportedInputFormats.contains(.pages))
        XCTAssertTrue(engine.supportedInputFormats.contains(.numbers))
        XCTAssertTrue(engine.supportedInputFormats.contains(.key))

        XCTAssertEqual(engine.availableOutputFormats(for: .pages), [.pdf, .docx, .rtf, .txt])
        XCTAssertEqual(engine.availableOutputFormats(for: .numbers), [.pdf, .xlsx, .csv])
        XCTAssertEqual(engine.availableOutputFormats(for: .key), [.pdf, .pptx])

        XCTAssertTrue(engine.canConvert(from: .pages, to: .pdf))
        XCTAssertTrue(engine.canConvert(from: .pages, to: .docx))
        XCTAssertTrue(engine.canConvert(from: .pages, to: .rtf))
        XCTAssertTrue(engine.canConvert(from: .pages, to: .txt))
        XCTAssertFalse(engine.canConvert(from: .pages, to: .xlsx))
        XCTAssertFalse(engine.canConvert(from: .pages, to: .pptx))

        XCTAssertTrue(engine.canConvert(from: .numbers, to: .pdf))
        XCTAssertTrue(engine.canConvert(from: .numbers, to: .xlsx))
        XCTAssertTrue(engine.canConvert(from: .numbers, to: .csv))
        XCTAssertFalse(engine.canConvert(from: .numbers, to: .docx))

        XCTAssertTrue(engine.canConvert(from: .key, to: .pdf))
        XCTAssertTrue(engine.canConvert(from: .key, to: .pptx))
        XCTAssertFalse(engine.canConvert(from: .key, to: .docx))
        XCTAssertFalse(engine.canConvert(from: .key, to: .csv))

        XCTAssertTrue(engine.optionDescriptors(from: .pages, to: .pdf).isEmpty)
        XCTAssertTrue(engine.optionDescriptors(from: .numbers, to: .csv).isEmpty)
        XCTAssertTrue(engine.optionDescriptors(from: .key, to: .pptx).isEmpty)
    }

    // MARK: - 2. App-Availability Detection

    func testAppAvailabilityDetectionChecksCandidateDirectoriesAndBundleIDFallback() throws {
        let dir = try makeTempDir(prefix: "M8C-Locate")
        defer { try? FileManager.default.removeItem(at: dir) }

        let appsDir = dir.appendingPathComponent("Applications", isDirectory: true)
        let sysAppsDir = dir.appendingPathComponent("SystemApplications", isDirectory: true)
        let fallbackDir = dir.appendingPathComponent("Relocated", isDirectory: true)
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sysAppsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)

        let pagesBundle = appsDir.appendingPathComponent("Pages.app", isDirectory: true)
        let numbersRegularFile = appsDir.appendingPathComponent("Numbers.app")
        let numbersRealBundle = sysAppsDir.appendingPathComponent("Numbers.app", isDirectory: true)
        let keynoteRelocated = fallbackDir.appendingPathComponent("Keynote.app", isDirectory: true)

        try FileManager.default.createDirectory(at: pagesBundle, withIntermediateDirectories: true)
        try Data("not-a-bundle".utf8).write(to: numbersRegularFile)
        try FileManager.default.createDirectory(at: numbersRealBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keynoteRelocated, withIntermediateDirectories: true)

        let locatedPages = IWorkConversionBridge.defaultLocateApplication(
            .pages,
            candidateDirectories: [appsDir, sysAppsDir],
            bundleIdentifierLookup: { _ in nil }
        )
        XCTAssertEqual(locatedPages?.standardizedFileURL, pagesBundle.standardizedFileURL)

        // Regular file named Numbers.app in /Applications must not pass directory bundle check; falls through to /System/Applications.
        let locatedNumbers = IWorkConversionBridge.defaultLocateApplication(
            .numbers,
            candidateDirectories: [appsDir, sysAppsDir],
            bundleIdentifierLookup: { _ in nil }
        )
        XCTAssertEqual(locatedNumbers?.standardizedFileURL, numbersRealBundle.standardizedFileURL)

        // Keynote located via bundle identifier fallback when absent from candidate directories.
        let locatedKeynote = IWorkConversionBridge.defaultLocateApplication(
            .keynote,
            candidateDirectories: [appsDir, sysAppsDir],
            bundleIdentifierLookup: { bundleID in
                bundleID == "com.apple.Keynote" ? keynoteRelocated : nil
            }
        )
        XCTAssertEqual(locatedKeynote?.standardizedFileURL, keynoteRelocated.standardizedFileURL)
    }

    func testBridgeAvailabilityReflectsInjectedEnvironment() {
        let installedURL = URL(fileURLWithPath: "/Applications/Pages.app", isDirectory: true)
        let bridge = IWorkConversionBridge(
            environment: IWorkBridgeEnvironment(
                locateApplication: { $0 == .pages ? installedURL : nil },
                runProcess: { _, _, _ in
                    XCTFail("Availability check must not launch subprocesses")
                    return ProcessExecutionOutput(terminationStatus: 0, stdout: Data(), stderr: Data())
                }
            )
        )

        XCTAssertTrue(bridge.isApplicationInstalled(.pages))
        XCTAssertFalse(bridge.isApplicationInstalled(.numbers))
        XCTAssertFalse(bridge.isApplicationInstalled(.keynote))
        XCTAssertTrue(bridge.isAvailable(for: .pages))
        XCTAssertFalse(bridge.isAvailable(for: .numbers))
        XCTAssertFalse(bridge.isAvailable(for: .key))
        XCTAssertTrue(bridge.isAnyAppAvailable())
    }

    // MARK: - 3. osascript Argument Construction (Zero Path Interpolation)

    func testOsascriptArgumentsUseExplicitArgvAndZeroPathInterpolation() throws {
        let nastyInput = URL(fileURLWithPath: "/tmp/user \"doc\" $(touch pwn) `id` 'single' #1 日本語.pages")
        let nastyOutput = URL(fileURLWithPath: "/tmp/out dir \"x\" $(rm -rf) #2.docx")

        let args = try IWorkConversionBridge.osascriptArguments(
            for: .pages,
            outputFormat: .docx,
            inputURL: nastyInput,
            outputURL: nastyOutput,
            resolvedBundleIdentifier: "com.apple.iWork.Pages"
        )

        XCTAssertEqual(args.count, 5)
        XCTAssertEqual(args[0], "-e")

        let script = args[1]
        XCTAssertTrue(script.contains("on run argv"))
        XCTAssertTrue(script.contains("item 1 of argv"))
        XCTAssertTrue(script.contains("item 2 of argv"))
        XCTAssertTrue(script.contains("item 3 of argv"))
        XCTAssertTrue(script.contains("tell application id \"com.apple.iWork.Pages\""))
        XCTAssertFalse(script.contains(nastyInput.path), "Input path must never be interpolated into AppleScript source")
        XCTAssertFalse(script.contains(nastyOutput.path), "Output path must never be interpolated into AppleScript source")
        XCTAssertFalse(script.contains("$(touch"), "User/path fragments must never appear in AppleScript source")
        XCTAssertFalse(script.contains("$(rm"), "User/path fragments must never appear in AppleScript source")

        XCTAssertEqual(args[2], nastyInput.path)
        XCTAssertEqual(args[3], nastyOutput.path)
        XCTAssertEqual(args[4], "Microsoft Word")

        let modernNumbersArgs = try IWorkConversionBridge.osascriptArguments(
            for: .numbers,
            outputFormat: .csv,
            inputURL: URL(fileURLWithPath: "/tmp/sheet.numbers"),
            outputURL: URL(fileURLWithPath: "/tmp/sheet.csv"),
            resolvedBundleIdentifier: "com.apple.Numbers"
        )
        XCTAssertTrue(modernNumbersArgs[1].contains("tell application id \"com.apple.Numbers\""))
        XCTAssertEqual(modernNumbersArgs[4], "CSV")

        let keynoteArgs = try IWorkConversionBridge.osascriptArguments(
            for: .key,
            outputFormat: .pptx,
            inputURL: URL(fileURLWithPath: "/tmp/deck.key"),
            outputURL: URL(fileURLWithPath: "/tmp/deck.pptx"),
            resolvedBundleIdentifier: "com.apple.iWork.Keynote"
        )
        XCTAssertTrue(keynoteArgs[1].contains("tell application id \"com.apple.iWork.Keynote\""))
        XCTAssertEqual(keynoteArgs[4], "Microsoft PowerPoint")
    }

    // MARK: - 4. Missing Apps & Automation Permission Denied (-1743) Error Handling

    func testMissingRequiredIWorkAppThrowsActionableEngineNotAvailableWithoutRunningOsascript() async throws {
        let dir = try makeTempDir(prefix: "M8C-MissingApp")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = try writeDummyInput(in: dir, filename: "report.pages")
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        final class FlagBox: @unchecked Sendable {
            var processInvoked = false
        }
        let flagBox = FlagBox()

        let bridge = IWorkConversionBridge(
            environment: IWorkBridgeEnvironment(
                locateApplication: { _ in nil },
                runProcess: { _, _, _ in
                    flagBox.processInvoked = true
                    return ProcessExecutionOutput(terminationStatus: 0, stdout: Data(), stderr: Data())
                }
            )
        )
        let engine = OfficeConversionEngine(iWorkBridge: bridge)

        do {
            _ = try await engine.convert(
                inputs: [input],
                to: .pdf,
                outputDirectory: outDir,
                options: .default,
                progress: { _ in }
            )
            XCTFail("Expected ConversionError.engineNotAvailable when Pages.app is missing")
        } catch let error as ConversionError {
            guard case .engineNotAvailable(let message) = error else {
                return XCTFail("Expected .engineNotAvailable, got \(error)")
            }
            XCTAssertTrue(message.contains("Pages.app"))
            XCTAssertFalse(flagBox.processInvoked, "Pre-flight app check must fail before launching osascript")
        }
    }

    func testAutomationPermissionDeniedMinus1743ThrowsActionableErrorAndCleansTempDir() async throws {
        let dir = try makeTempDir(prefix: "M8C-PermDenied")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = try writeDummyInput(in: dir, filename: "slides.key")
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let baselineTempCount = countIWorkTempDirsInSystemTemp()

        let bridge = IWorkConversionBridge(
            environment: IWorkBridgeEnvironment(
                locateApplication: { $0 == .keynote ? URL(fileURLWithPath: "/Applications/Keynote.app", isDirectory: true) : nil },
                readBundleIdentifier: { _ in "com.apple.iWork.Keynote" },
                runProcess: { executablePath, _, _ in
                    XCTAssertEqual(executablePath, IWorkConversionBridge.osascriptExecutablePath)
                    return ProcessExecutionOutput(
                        terminationStatus: 1,
                        stdout: Data(),
                        stderr: Data("execution error: Not authorized to send Apple events to Keynote. (-1743)\n".utf8)
                    )
                }
            )
        )
        let engine = OfficeConversionEngine(iWorkBridge: bridge)

        do {
            _ = try await engine.convert(
                inputs: [input],
                to: .pptx,
                outputDirectory: outDir,
                options: .default,
                progress: { _ in }
            )
            XCTFail("Expected Automation permission error")
        } catch let error as ConversionError {
            guard case .engineExecutionFailed(let message, let underlying) = error else {
                return XCTFail("Expected .engineExecutionFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("Automation"))
            XCTAssertTrue(message.contains("Keynote.app"))
            XCTAssertTrue(message.contains("Privacy & Security"))
            XCTAssertEqual(underlying?.contains("-1743"), true)
        }

        XCTAssertEqual(countIWorkTempDirsInSystemTemp(), baselineTempCount)
    }

    func testOsascriptTimeoutThrowsBoundedTimeoutErrorAndCleansTempDir() async throws {
        let dir = try makeTempDir(prefix: "M8C-Timeout")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = try writeDummyInput(in: dir, filename: "budget.numbers")
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let baselineTempCount = countIWorkTempDirsInSystemTemp()

        let bridge = IWorkConversionBridge(
            environment: IWorkBridgeEnvironment(
                locateApplication: { $0 == .numbers ? URL(fileURLWithPath: "/Applications/Numbers.app", isDirectory: true) : nil },
                readBundleIdentifier: { _ in "com.apple.iWork.Numbers" },
                runProcess: { _, _, timeout in
                    XCTAssertEqual(timeout, 5.0)
                    throw ProcessTimeoutError(timeoutSeconds: timeout)
                },
                timeoutSeconds: 5.0
            )
        )

        do {
            _ = try await bridge.convert(
                input: input,
                to: .xlsx,
                outputDirectory: outDir
            )
            XCTFail("Expected timeout error")
        } catch let error as ConversionError {
            guard case .engineExecutionFailed(let message, _) = error else {
                return XCTFail("Expected .engineExecutionFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("timed out"))
            XCTAssertTrue(message.contains("Numbers"))
        }

        XCTAssertEqual(countIWorkTempDirsInSystemTemp(), baselineTempCount)
    }

    // MARK: - 5. Atomic Publish & Numbers Multi-Sheet CSV Directory Handling

    func testPagesPDFExportPublishesAtomicallyAndRespectsCollisionPolicy() async throws {
        let dir = try makeTempDir(prefix: "M8C-PagesPDF")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = try writeDummyInput(in: dir, filename: "proposal.pages")
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let existingDest = outDir.appendingPathComponent("proposal.pdf")
        try Data("existing-user-pdf".utf8).write(to: existingDest)

        let bridge = IWorkConversionBridge(
            environment: IWorkBridgeEnvironment(
                locateApplication: { $0 == .pages ? URL(fileURLWithPath: "/Applications/Pages.app", isDirectory: true) : nil },
                readBundleIdentifier: { _ in "com.apple.iWork.Pages" },
                runProcess: { executablePath, arguments, _ in
                    XCTAssertEqual(executablePath, IWorkConversionBridge.osascriptExecutablePath)
                    let stagedOutputURL = URL(fileURLWithPath: arguments[3])
                    try Self.writeValidPDF(at: stagedOutputURL, text: "Exported from Pages")
                    return ProcessExecutionOutput(terminationStatus: 0, stdout: Data(), stderr: Data())
                }
            )
        )
        let engine = OfficeConversionEngine(iWorkBridge: bridge)

        // Default policy (.createUnique) must preserve existing proposal.pdf and publish proposal (1).pdf
        let uniqueResult = try await engine.convert(
            inputs: [input],
            to: .pdf,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )

        XCTAssertEqual(uniqueResult.outputURL.lastPathComponent, "proposal (1).pdf")
        XCTAssertTrue(uniqueResult.additionalOutputURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: existingDest), Data("existing-user-pdf".utf8))
        XCTAssertNotNil(PDFDocument(url: uniqueResult.outputURL))

        // Overwrite policy atomically replaces proposal.pdf
        var overwriteOptions = ConversionOptions.default
        overwriteOptions.overwriteExisting = true
        let overwriteResult = try await engine.convert(
            inputs: [input],
            to: .pdf,
            outputDirectory: outDir,
            options: overwriteOptions,
            progress: { _ in }
        )

        XCTAssertEqual(overwriteResult.outputURL.standardizedFileURL, existingDest.standardizedFileURL)
        XCTAssertNotNil(PDFDocument(url: existingDest))
    }

    func testNumbersMultiSheetCSVDirectoryExportPublishesAllSheetsAtomically() async throws {
        let dir = try makeTempDir(prefix: "M8C-NumbersCSV")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = try writeDummyInput(in: dir, filename: "quarterly.numbers")
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let baselineTempCount = countIWorkTempDirsInSystemTemp()

        let bridge = IWorkConversionBridge(
            environment: IWorkBridgeEnvironment(
                locateApplication: { $0 == .numbers ? URL(fileURLWithPath: "/Applications/Numbers.app", isDirectory: true) : nil },
                readBundleIdentifier: { _ in "com.apple.iWork.Numbers" },
                runProcess: { _, arguments, _ in
                    // Simulate Numbers creating a directory at outputPath containing per-sheet CSV files.
                    let folderAtTarget = URL(fileURLWithPath: arguments[3], isDirectory: true)
                    try FileManager.default.createDirectory(at: folderAtTarget, withIntermediateDirectories: true)
                    try Data("Month,Revenue\nJan,100\n".utf8)
                        .write(to: folderAtTarget.appendingPathComponent("Summary-Table 1.csv"))
                    try Data("Item,Cost\nCloud,42\n".utf8)
                        .write(to: folderAtTarget.appendingPathComponent("Expenses-Table 1.csv"))
                    return ProcessExecutionOutput(terminationStatus: 0, stdout: Data(), stderr: Data())
                }
            )
        )
        let engine = OfficeConversionEngine(iWorkBridge: bridge)

        let result = try await engine.convert(
            inputs: [input],
            to: .csv,
            outputDirectory: outDir,
            options: .default,
            progress: { _ in }
        )

        XCTAssertEqual(result.outputFormat, .csv)
        XCTAssertEqual(result.allOutputURLs.count, 2)
        XCTAssertEqual(result.additionalOutputURLs.count, 1)

        let producedNames = result.allOutputURLs.map(\.lastPathComponent).sorted()
        XCTAssertEqual(producedNames, [
            "quarterly-Expenses-Table 1.csv",
            "quarterly-Summary-Table 1.csv"
        ])
        for url in result.allOutputURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertGreaterThan(result.fileSize, 0)
        XCTAssertEqual(countIWorkTempDirsInSystemTemp(), baselineTempCount)
    }

    func testInvalidExportedPDFPreservesExistingDestinationFile() async throws {
        let dir = try makeTempDir(prefix: "M8C-InvalidPDF")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = try writeDummyInput(in: dir, filename: "corrupt.pages")
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let existingDest = outDir.appendingPathComponent("corrupt.pdf")
        try Data("precious-existing-pdf".utf8).write(to: existingDest)

        let bridge = IWorkConversionBridge(
            environment: IWorkBridgeEnvironment(
                locateApplication: { $0 == .pages ? URL(fileURLWithPath: "/Applications/Pages.app", isDirectory: true) : nil },
                readBundleIdentifier: { _ in "com.apple.iWork.Pages" },
                runProcess: { _, arguments, _ in
                    try Data("not-a-valid-pdf".utf8).write(to: URL(fileURLWithPath: arguments[3]))
                    return ProcessExecutionOutput(terminationStatus: 0, stdout: Data(), stderr: Data())
                }
            )
        )

        var options = ConversionOptions.default
        options.overwriteExisting = true

        do {
            _ = try await bridge.convert(
                input: input,
                to: .pdf,
                outputDirectory: outDir,
                options: options
            )
            XCTFail("Expected invalid PDF validation failure")
        } catch let error as ConversionError {
            guard case .engineExecutionFailed = error else {
                return XCTFail("Expected .engineExecutionFailed, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: existingDest), Data("precious-existing-pdf".utf8))
    }

    // MARK: - 6. Conditional Live Verification (Skips Cleanly When iWork Unavailable)

    func testLiveIWorkExportSkipsCleanlyWhenAppsAreNotInstalled() async throws {
        let bridge = IWorkConversionBridge()
        guard let installedApp = IWorkApplication.allCases.first(where: { bridge.isApplicationInstalled($0) }) else {
            throw XCTSkip("Pages.app, Numbers.app, and Keynote.app are not installed on this host; skipping live iWork Automation smoke test.")
        }

        // Verify at minimum that osascript can compile the static AppleScript for the installed app without error
        // (and if Automation consent is denied in a headless test runner, skip cleanly rather than failing).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        let tmpScript = try makeTempDir(prefix: "M8C-LiveCompile")
        defer { try? FileManager.default.removeItem(at: tmpScript) }

        let installedURL = bridge.applicationURL(for: installedApp)
        let bundleID = installedURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let scriptText = IWorkConversionBridge.appleScriptSource(for: installedApp, resolvedBundleIdentifier: bundleID)
        let scptOut = tmpScript.appendingPathComponent("check.scpt")
        process.arguments = ["-e", scriptText, "-o", scptOut.path]

        let output = try await AsyncProcessRunner.run(process, timeout: 15.0)
        if output.terminationStatus != 0 {
            let err = String(data: output.stderr, encoding: .utf8) ?? ""
            if err.contains("-1743") || err.lowercased().contains("not authorized") {
                throw XCTSkip("macOS Automation permission not granted for \(installedApp.appName) in test runner.")
            }
            XCTFail("osacompile failed for installed \(installedApp.appName): \(err)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: scptOut.path))
    }
}
