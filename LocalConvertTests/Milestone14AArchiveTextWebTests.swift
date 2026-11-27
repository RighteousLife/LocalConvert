import XCTest
import SwiftUI
import AppKit
import PDFKit
@testable import LocalConvert

@MainActor
final class Milestone14AArchiveTextWebTests: XCTestCase {

    private var sandbox: TestSandbox!

    override func setUp() async throws {
        continueAfterFailure = false
        sandbox = try TestSandbox(runID: "M14A-ArchiveTextWeb-\(UUID().uuidString)")
        AppStoragePaths.setTestOverrides(
            sandboxRoot: sandbox.rootURL,
            defaultsSuiteName: sandbox.userDefaultsSuiteName
        )
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

    private struct MockURLToPDFRenderer: URLToPDFRendering {
        let payload: Data
        let shouldThrow: Error?

        init(payload: Data = Data("%PDF-1.4\n%MockPDF\n%%EOF".utf8), shouldThrow: Error? = nil) {
            self.payload = payload
            self.shouldThrow = shouldThrow
        }

        func renderPDFData(for request: URLToPDFRenderRequest) async throws -> Data {
            if let shouldThrow {
                throw shouldThrow
            }
            return payload
        }
    }

    private func runTool(_ executable: String, arguments: [String]) async throws -> ProcessExecutionOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        return try await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 30)
    }

    private func makeTarEntry(name: String, payload: Data = Data()) -> Data {
        var header = Data(count: 512)
        func put(_ str: String, at offset: Int, maxLen: Int) {
            for (idx, byte) in str.utf8.prefix(maxLen).enumerated() {
                header[offset + idx] = byte
            }
        }
        put(name, at: 0, maxLen: 100)
        put("0000644\0", at: 100, maxLen: 8)
        put("0000000\0", at: 108, maxLen: 8)
        put("0000000\0", at: 116, maxLen: 8)
        put(String(format: "%011o\0", payload.count), at: 124, maxLen: 12)
        put("00000000000\0", at: 136, maxLen: 12)
        for idx in 148..<156 { header[idx] = 0x20 }
        header[156] = Character("0").asciiValue!
        put("ustar\0", at: 257, maxLen: 6)
        put("00", at: 263, maxLen: 2)
        put("root", at: 265, maxLen: 32)
        put("wheel", at: 297, maxLen: 32)
        let checksum = header.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o\0 ", checksum), at: 148, maxLen: 8)

        var out = header
        if !payload.isEmpty {
            out.append(payload)
            let rem = payload.count % 512
            if rem != 0 {
                out.append(Data(count: 512 - rem))
            }
        }
        return out
    }

    private func writeTar(named filename: String, entries: [Data]) throws -> URL {
        var data = Data()
        for entry in entries { data.append(entry) }
        data.append(Data(count: 1024))
        let url = sandbox.documentsURL.appendingPathComponent(filename)
        try data.write(to: url)
        return url
    }

    // MARK: - 1. Archive Entry Listing (.zip, .tar, .tgz)

    func testListEntriesSupportsZipTarAndTgzArchives() async throws {
        let sourceDir = sandbox.documentsURL.appendingPathComponent("archive_src", isDirectory: true)
        let nestedDir = sourceDir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

        let fileA = sourceDir.appendingPathComponent("readme.txt")
        let fileB = nestedDir.appendingPathComponent("meeting notes.md")
        try Data("Hello LocalConvert".utf8).write(to: fileA)
        try Data("# Agenda\n- Ship 14A".utf8).write(to: fileB)

        let zipURL = sandbox.documentsURL.appendingPathComponent("bundle.zip")
        let tarURL = sandbox.documentsURL.appendingPathComponent("bundle.tar")
        let tgzURL = sandbox.documentsURL.appendingPathComponent("bundle.tgz")

        let zipRes = try await runTool("/usr/bin/bsdtar", arguments: ["--format=zip", "-cf", zipURL.path, "-C", sourceDir.path, "readme.txt", "docs"])
        XCTAssertEqual(zipRes.terminationStatus, 0)
        let tarRes = try await runTool("/usr/bin/bsdtar", arguments: ["-cf", tarURL.path, "-C", sourceDir.path, "readme.txt", "docs"])
        XCTAssertEqual(tarRes.terminationStatus, 0)
        let tgzRes = try await runTool("/usr/bin/bsdtar", arguments: ["-czf", tgzURL.path, "-C", sourceDir.path, "readme.txt", "docs"])
        XCTAssertEqual(tgzRes.terminationStatus, 0)

        for url in [zipURL, tarURL, tgzURL] {
            let inspection = try await ArchiveInspectorEngine.listEntries(in: url)
            XCTAssertFalse(inspection.hasEncryptedEntries)
            XCTAssertTrue(inspection.entries.contains(where: { $0.path == "readme.txt" && !$0.isDirectory && $0.uncompressedSize == 18 }))
            XCTAssertTrue(inspection.entries.contains(where: { $0.path == "docs/" && $0.isDirectory }))
            XCTAssertTrue(inspection.entries.contains(where: { $0.path == "docs/meeting notes.md" && !$0.isDirectory && $0.uncompressedSize == 19 }))
        }
    }

    // MARK: - 2. Zip-Slip Path Traversal Rejection

    func testValidateEntryPathAndArchiveInspectionRejectZipSlip() async throws {
        let destRoot = sandbox.outputsURL

        let maliciousPaths = [
            "",
            "../escape.txt",
            "/etc/passwd",
            "sub/../../escape.txt",
            "..\\escape.txt",
            "bad\0name.txt",
            "C:\\Windows\\system.ini"
        ]

        for badPath in maliciousPaths {
            XCTAssertThrowsError(try ArchiveInspectorEngine.validateEntryPath(badPath, destinationRoot: destRoot)) { error in
                guard case .invalidInput = error as? ConversionError else {
                    XCTFail("Expected ConversionError.invalidInput for '\(badPath)', got \(error)")
                    return
                }
            }
        }

        let validPath = try ArchiveInspectorEngine.validateEntryPath("folder/notes.txt", destinationRoot: destRoot)
        XCTAssertEqual(validPath.standardizedFileURL, destRoot.appendingPathComponent("folder/notes.txt").standardizedFileURL)

        let evilTar = try writeTar(
            named: "zipslip.tar",
            entries: [makeTarEntry(name: "sub/../../escape.txt", payload: Data("owned".utf8))]
        )

        do {
            _ = try await ArchiveInspectorEngine.listEntries(in: evilTar)
            XCTFail("Expected listEntries to reject Zip-Slip entry")
        } catch {
            guard case .invalidInput = error as? ConversionError else {
                XCTFail("Expected invalidInput, got \(error)")
                return
            }
        }

        do {
            _ = try await ArchiveInspectorEngine.extractEntry("sub/../../escape.txt", from: evilTar, to: destRoot)
            XCTFail("Expected extractEntry to reject Zip-Slip entry")
        } catch {
            guard case .invalidInput = error as? ConversionError else {
                XCTFail("Expected invalidInput, got \(error)")
                return
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.rootURL.appendingPathComponent("escape.txt").path))
    }

    // MARK: - 3. Single-File Extraction with Atomic Collision Handling

    func testExtractSingleEntryAtomicallyAndHandleCollisions() async throws {
        let sourceDir = sandbox.documentsURL.appendingPathComponent("extract_src", isDirectory: true)
        let subDir = sourceDir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let notePayload = Data("Important local note content".utf8)
        try notePayload.write(to: subDir.appendingPathComponent("note.txt"))

        let tgzURL = sandbox.documentsURL.appendingPathComponent("notes.tgz")
        let tarResult = try await runTool("/usr/bin/bsdtar", arguments: ["-czf", tgzURL.path, "-C", sourceDir.path, "nested"])
        XCTAssertEqual(tarResult.terminationStatus, 0)

        let firstURL = try await ArchiveInspectorEngine.extractEntry(
            "nested/note.txt",
            from: tgzURL,
            to: sandbox.outputsURL,
            policy: .createUnique
        )
        XCTAssertEqual(firstURL.lastPathComponent, "note.txt")
        XCTAssertEqual(try Data(contentsOf: firstURL), notePayload)

        let secondURL = try await ArchiveInspectorEngine.extractEntry(
            "nested/note.txt",
            from: tgzURL,
            to: sandbox.outputsURL,
            policy: .createUnique
        )
        XCTAssertEqual(secondURL.lastPathComponent, "note (1).txt")
        XCTAssertEqual(try Data(contentsOf: secondURL), notePayload)

        // Extracting a directory entry must be rejected
        do {
            _ = try await ArchiveInspectorEngine.extractEntry("nested/", from: tgzURL, to: sandbox.outputsURL)
            XCTFail("Extracting directory entry should fail")
        } catch {
            guard case .invalidInput = error as? ConversionError else {
                XCTFail("Expected invalidInput, got \(error)")
                return
            }
        }
    }

    // MARK: - 4. Encrypted ZIP Creation & Verification

    func testCreateEncryptedZipAndVerifyPasswordEnforcement() async throws {
        let docURL = sandbox.documentsURL.appendingPathComponent("secret-report.txt")
        let expectedData = Data("Confidential on-device payload 42".utf8)
        try expectedData.write(to: docURL)

        // Empty password must be rejected
        do {
            _ = try await ArchiveInspectorEngine.createEncryptedZip(
                inputs: [docURL],
                outputDirectory: sandbox.outputsURL,
                archiveBaseName: "EmptyPass",
                password: ""
            )
            XCTFail("Empty password must be rejected")
        } catch {
            guard case .invalidInput = error as? ConversionError else {
                XCTFail("Expected invalidInput, got \(error)")
                return
            }
        }

        let password = "LocalConvert#2026"
        let encryptedZip = try await ArchiveInspectorEngine.createEncryptedZip(
            inputs: [docURL],
            outputDirectory: sandbox.outputsURL,
            archiveBaseName: "VaultBundle",
            password: password
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedZip.path))
        let zipSize = (try FileManager.default.attributesOfItem(atPath: encryptedZip.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(zipSize, 0)
        XCTAssertTrue(ArchiveInspectorEngine.isZipHeaderEncrypted(url: encryptedZip))

        let inspection = try await ArchiveInspectorEngine.listEntries(in: encryptedZip)
        XCTAssertTrue(inspection.hasEncryptedEntries)
        XCTAssertEqual(inspection.entries.first?.path, "secret-report.txt")
        XCTAssertEqual(inspection.entries.first?.isEncrypted, true)

        // Wrong password must fail extraction quickly
        let extractDir = sandbox.outputsURL.appendingPathComponent("extracted_enc", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        do {
            _ = try await ArchiveInspectorEngine.extractEntry(
                "secret-report.txt",
                from: encryptedZip,
                to: extractDir,
                password: "WrongPassword!"
            )
            XCTFail("Extraction with wrong password must fail")
        } catch {
            // Expected
        }

        // Correct password succeeds and matches original payload
        let extracted = try await ArchiveInspectorEngine.extractEntry(
            "secret-report.txt",
            from: encryptedZip,
            to: extractDir,
            password: password
        )
        XCTAssertEqual(try Data(contentsOf: extracted), expectedData)

        // Also verify with system unzip -P
        let unzipOut = try await runTool("/usr/bin/unzip", arguments: ["-P", password, "-p", encryptedZip.path, "secret-report.txt"])
        XCTAssertEqual(unzipOut.terminationStatus, 0)
        XCTAssertEqual(unzipOut.stdout, expectedData)
    }

    // MARK: - 5. Quick Text Tools: Markdown -> HTML / PDF, JSON, Base64

    func testMarkdownToStyledHTMLAndVectorPDF() throws {
        let md = """
        # Release Notes

        > Offline summary

        - **Fast** conversion
        - *Private* processing with `LocalConvert`
        - [Safe Link](https://example.com) and [Blocked](javascript:alert(1))

        ```swift
        let x = 1 < 2
        ```
        """

        let html = QuickTextToolsEngine.markdownToStyledHTML(md, title: "Release Notes")
        XCTAssertTrue(html.contains("<h1>Release Notes</h1>"))
        XCTAssertTrue(html.contains("<blockquote><p>Offline summary</p></blockquote>"))
        XCTAssertTrue(html.contains("<strong>Fast</strong>"))
        XCTAssertTrue(html.contains("<em>Private</em>"))
        XCTAssertTrue(html.contains("<code>LocalConvert</code>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">Safe Link</a>"))
        XCTAssertFalse(html.contains("javascript:alert"))
        XCTAssertTrue(html.contains("let x = 1 &lt; 2"))

        let pdfData = try QuickTextToolsEngine.renderMarkdownToPDFData(md, title: "Release Notes")
        XCTAssertTrue(pdfData.starts(with: Data("%PDF-".utf8)))
        let pdfDoc = try XCTUnwrap(PDFDocument(data: pdfData))
        XCTAssertGreaterThanOrEqual(pdfDoc.pageCount, 1)
        let pageText = pdfDoc.page(at: 0)?.string ?? ""
        XCTAssertTrue(pageText.contains("Release Notes"))
        XCTAssertTrue(pageText.contains("Fast conversion"))
    }

    func testJSONPrettyPrintMinifyAndInvalidError() throws {
        let raw = "{\"z\":2,\"a\":[true,\"ok\"]}"
        let pretty = try QuickTextToolsEngine.formatJSON(raw, prettyPrinted: true)
        XCTAssertTrue(pretty.contains("\n"))
        XCTAssertTrue(pretty.contains("\"a\" : ["))

        let minified = try QuickTextToolsEngine.formatJSON(pretty, prettyPrinted: false)
        XCTAssertFalse(minified.contains("\n"))
        XCTAssertEqual(minified, "{\"a\":[true,\"ok\"],\"z\":2}")

        XCTAssertThrowsError(try QuickTextToolsEngine.formatJSON("{\"broken\": }", prettyPrinted: true)) { error in
            guard case .invalidInput = error as? ConversionError else {
                XCTFail("Expected invalidInput, got \(error)")
                return
            }
        }
        XCTAssertThrowsError(try QuickTextToolsEngine.formatJSON("   ", prettyPrinted: false))
    }

    func testBase64EncodeDecodeAndInvalidInputError() throws {
        let original = "LocalConvert 🔐 Türkçe UTF-8"
        let encoded = QuickTextToolsEngine.encodeBase64(original)
        XCTAssertEqual(try QuickTextToolsEngine.decodeBase64(encoded), original)

        // Whitespace-wrapped Base64 decodes cleanly
        let wrapped = String(encoded.prefix(8)) + "\n" + String(encoded.dropFirst(8))
        XCTAssertEqual(try QuickTextToolsEngine.decodeBase64(wrapped), original)

        // Invalid Base64 throws error
        XCTAssertThrowsError(try QuickTextToolsEngine.decodeBase64("!!!not-valid-base64!!!")) { error in
            guard case .invalidInput = error as? ConversionError else {
                XCTFail("Expected invalidInput, got \(error)")
                return
            }
        }
    }

    // MARK: - 6. URL-to-PDF Scheme Validation & Mock Renderer Output

    func testURLToPDFValidatorRejectsUnsafeSchemesAndUnconfirmedNetwork() throws {
        let rejectedCases = [
            "",
            "   ",
            "javascript:alert(1)",
            "data:text/html,<h1>Hi</h1>",
            "smb://fileserver.local/share/doc.html",
            "ftp://example.com/file.html",
            "https://",
            "file://evil.example/etc/passwd"
        ]

        for raw in rejectedCases {
            XCTAssertThrowsError(try URLToPDFValidator.validateAndNormalize(raw, userInitiated: true), "Expected rejection for \(raw)")
        }

        // Network URL must require explicit user confirmation
        XCTAssertThrowsError(try URLToPDFValidator.validateAndNormalize("https://example.com", userInitiated: false)) { error in
            XCTAssertEqual(error as? URLToPDFValidationError, .userConfirmationRequired)
        }
    }

    func testURLToPDFExportCoordinatorWithMockRenderer() async throws {
        let localHTML = sandbox.documentsURL.appendingPathComponent("local_note.html")
        try Data("<html><body><h1>Offline</h1></body></html>".utf8).write(to: localHTML)

        let mockRenderer = MockURLToPDFRenderer()
        let firstPDF = try await URLToPDFExportCoordinator.exportPDF(
            from: localHTML.absoluteString,
            userInitiated: true,
            outputDirectory: sandbox.outputsURL,
            renderer: mockRenderer
        )
        XCTAssertEqual(firstPDF.lastPathComponent, "local_note.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPDF.path))
        XCTAssertEqual(try Data(contentsOf: firstPDF), mockRenderer.payload)

        // Second export collides safely via OutputReservationCoordinator
        let secondPDF = try await URLToPDFExportCoordinator.exportPDF(
            from: localHTML.absoluteString,
            userInitiated: true,
            outputDirectory: sandbox.outputsURL,
            renderer: mockRenderer
        )
        XCTAssertEqual(secondPDF.lastPathComponent, "local_note (1).pdf")

        // User-initiated https:// URL works with injected mock without touching network
        let webPDF = try await URLToPDFExportCoordinator.exportPDF(
            from: "https://example.com/article",
            userInitiated: true,
            outputDirectory: sandbox.outputsURL,
            renderer: mockRenderer
        )
        XCTAssertEqual(webPDF.lastPathComponent, "example.com.pdf")
    }

    // MARK: - 7. LC-019 Layout Sanity (820x580)

    func testUtilitySheetAndArchiveQuickLookLayoutWithin820x580() throws {
        let utilityController = TextAndArchiveUtilityController(isPresented: true, selectedMode: .textTools)
        let utilityView = TextAndArchiveUtilitySheetView(controller: utilityController)
        let utilityHosting = NSHostingView(rootView: utilityView)
        utilityHosting.frame = NSRect(x: 0, y: 0, width: 820, height: 580)
        utilityHosting.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(utilityHosting.fittingSize.width, 820)
        XCTAssertLessThanOrEqual(utilityHosting.fittingSize.height, 580)

        let dummyArchive = sandbox.documentsURL.appendingPathComponent("preview.zip")
        let archiveQuickLook = QuickLookAndCompareView(archiveURL: dummyArchive)
        let quickLookHosting = NSHostingView(rootView: archiveQuickLook)
        quickLookHosting.frame = NSRect(x: 0, y: 0, width: 820, height: 580)
        quickLookHosting.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(quickLookHosting.fittingSize.width, 820)
        XCTAssertLessThanOrEqual(quickLookHosting.fittingSize.height, 580)
    }
}
