import XCTest
import Foundation
@testable import LocalConvert

@MainActor
final class Phase57DiagnosticsAndSplitTests: XCTestCase {

    func testStructuredDiagnosticsClassifiesValidationVsInternalErrorAndBoundsBuffer() {
        StructuredDiagnostics.clearRecentEvents()

        XCTAssertEqual(StructuredDiagnostics.severity(for: .invalidInput("Bad header")), .validation)
        XCTAssertEqual(
            StructuredDiagnostics.severity(for: .inputFileNotFound(URL(fileURLWithPath: "/tmp/missing.png"))),
            .validation
        )
        XCTAssertEqual(
            StructuredDiagnostics.severity(for: .unsupportedConversion(from: .txt, to: .mp4)),
            .validation
        )
        XCTAssertEqual(StructuredDiagnostics.severity(for: .engineNotAvailable("FFmpeg")), .internalError)
        XCTAssertEqual(
            StructuredDiagnostics.severity(for: .engineExecutionFailed("Encode failed", underlyingError: "exit 1")),
            .internalError
        )

        for idx in 0..<215 {
            StructuredDiagnostics.record(
                category: .conversion,
                severity: idx % 2 == 0 ? .validation : .internalError,
                stage: "batch-\(idx)",
                operationID: "op-\(idx)",
                filename: "/Users/alice/Documents/file-\(idx).png",
                message: "Event \(idx)",
                isVerboseEnabled: false
            )
        }

        let events = StructuredDiagnostics.recentEvents()
        XCTAssertEqual(events.count, 200, "Diagnostic buffer should remain bounded at 200 events")
        XCTAssertEqual(events.first?.stage, "batch-15")
        XCTAssertEqual(events.last?.stage, "batch-214")
        XCTAssertEqual(events.last?.sanitizedFilename, "file-214.png")
    }

    func testStructuredDiagnosticsAndFormatterRedactSecretsPathsAndGPSCoordinates() {
        StructuredDiagnostics.clearRecentEvents()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P57Diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rawMessage = "Failed at /Users/secretuser/Desktop/photo.jpg with password=TopSecret123 Bearer abc.def.ghi latitude=-33.86880 longitude=151.20930 coords 33.86880° S"
        let event = StructuredDiagnostics.record(
            category: .metadata,
            severity: .validation,
            stage: "saveCopy",
            operationID: "op-privacy",
            filename: "/Users/secretuser/Desktop/photo.jpg",
            message: rawMessage,
            isVerboseEnabled: true,
            directoryOverride: dir
        )

        XCTAssertEqual(event.sanitizedFilename, "photo.jpg")
        XCTAssertFalse(event.message.contains("secretuser"))
        XCTAssertFalse(event.message.contains("TopSecret123"))
        XCTAssertFalse(event.message.contains("abc.def.ghi"))
        XCTAssertFalse(event.message.contains("33.86880"))
        XCTAssertFalse(event.message.contains("151.20930"))
        XCTAssertTrue(event.message.contains("[REDACTED]"))
        XCTAssertTrue(event.message.contains("[GPS_REDACTED]"))

        let fileContents = DiagnosticLogManager.readDiagnosticLogContents(in: dir)
        XCTAssertTrue(fileContents.contains("[Metadata][VALIDATION][saveCopy]"))
        XCTAssertFalse(fileContents.contains("secretuser"))
        XCTAssertFalse(fileContents.contains("TopSecret123"))
    }

    func testConversionManagerSplitHelpersPreserveReservationAndErrorFormatting() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("P57Split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let input = sandbox.appendingPathComponent("sample.png")
        try Data("png".utf8).write(to: input)

        var opts = ConversionOptions.default
        opts.customOptions["output_prefix"] = "pre_"
        let reserved1 = try ConversionManager.reserveOutputURL(for: input, format: .jpg, in: sandbox, options: opts)
        let reserved2 = try ConversionManager.reserveOutputURL(for: input, format: .jpg, in: sandbox, options: opts)
        XCTAssertEqual(reserved1.lastPathComponent, "pre_sample.jpg")
        XCTAssertEqual(reserved2.lastPathComponent, "pre_sample (1).jpg")
        ConversionManager.releaseReservedOutputURL(reserved1)
        ConversionManager.releaseReservedOutputURL(reserved2)

        let err = ConversionError.invalidInput("Corrupted at /Users/alice/Downloads/sample.png")
        XCTAssertEqual(ErrorDetailsFormatter.title(for: err), "Invalid or Protected Input File")

        let report = ErrorDetailsFormatter.format(
            inputFilename: "sample.png",
            inputFormat: "PNG",
            outputFormat: "JPEG",
            error: err,
            jobID: UUID()
        )
        XCTAssertTrue(report.contains("Suggested Action:"))
        XCTAssertTrue(report.contains("~/Downloads/sample.png"))
        XCTAssertFalse(report.contains("/Users/alice"))

        let cmp = ConversionSizeComparison(inputBytes: 1000, outputBytes: 400)
        XCTAssertEqual(cmp.formattedSummary, "60% smaller")
    }
}
