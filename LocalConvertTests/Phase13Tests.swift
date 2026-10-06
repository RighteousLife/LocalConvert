import Testing
import Foundation
@testable import LocalConvert

@Suite("Phase 13 Feature Tests")
struct Phase13Tests {

    // MARK: - CSV Parsing Tests (TextConversionEngine)
    @Test("TextConversionEngine parses standard and complex CSV correctly")
    func testCSVParser() async throws {
        let engine = TextConversionEngine()
        
        let csvContent = "Name,Age,Notes\nAlice,30,\"Loves, comma and quotes \"\"yes\"\"\"\nBob,25,Simple note\n\"Charlie\nMultiline\",22,\"Note with\nnewline\""
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = tempDir.appendingPathComponent("test.csv")
        try csvContent.write(to: inputURL, atomically: true, encoding: .utf8)
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .tsv,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        
        let tsvContent = try String(contentsOf: result.outputURL, encoding: .utf8)
        
        let expectedTSV = "Name\tAge\tNotes\nAlice\t30\t\"Loves, comma and quotes \"\"yes\"\"\"\nBob\t25\tSimple note\n\"Charlie\nMultiline\"\t22\t\"Note with\nnewline\""
        
        #expect(tsvContent == expectedTSV)
    }

    // MARK: - AppSettings Persistence Tests
    @Test("AppSettings default to expected values")
    @MainActor func testAppSettingsDefaults() async throws {
        let settings = AppSettings.shared
        settings.resetToDefaults()
        
        #expect(settings.showCompletionNotification == true)
        #expect(settings.defaultImageQuality == 0.90)
        #expect(settings.preserveMetadataByDefault == true)
        #expect(settings.defaultPDFDPI == 150.0)
    }

    // MARK: - Smart Recommendations
    @Test("DroppedFile recommendations are logical and exclude input format")
    @MainActor func testSmartRecommendations() async throws {
        // We use dummy URLs; they don't need to exist for detection via extension.
        // Actually, FileDetector might try to read magic bytes and fail gracefully.
        let detector = FileDetector()
        
        let jpgResult = detector.detect(url: URL(fileURLWithPath: "test.jpg"))
        let jpgFile = DroppedFile(url: URL(fileURLWithPath: "test.jpg"), detectionResult: jpgResult)
        
        let recJpg = jpgFile.recommendedOutputFormats
        #expect(recJpg.contains(.png))
        #expect(recJpg.contains(.webp))
        #expect(!recJpg.contains(.jpg))
        
        let movResult = detector.detect(url: URL(fileURLWithPath: "test.mov"))
        let movFile = DroppedFile(url: URL(fileURLWithPath: "test.mov"), detectionResult: movResult)
        
        let recMov = movFile.recommendedOutputFormats
        #expect(recMov.contains(.mp4))
        #expect(!recMov.contains(.mov))
    }

    // MARK: - File Detector Additions
    @Test("FileDetector detects SVG, AVIF, CSV, TSV, RTF")
    func testFileDetectorPhase13Formats() async {
        let detector = FileDetector()
        
        #expect(detector.detect(url: URL(fileURLWithPath: "test.svg")).bestFormat == .svg)
        #expect(detector.detect(url: URL(fileURLWithPath: "test.avif")).bestFormat == .avif)
        #expect(detector.detect(url: URL(fileURLWithPath: "test.csv")).bestFormat == .csv)
        #expect(detector.detect(url: URL(fileURLWithPath: "test.tsv")).bestFormat == .tsv)
        #expect(detector.detect(url: URL(fileURLWithPath: "test.rtf")).bestFormat == .rtf)
        #expect(detector.detect(url: URL(fileURLWithPath: "test.odt")).bestFormat == .odt)
    }
}

extension Phase13Tests {
    // Helper to run conversions
    private func runConversion(engine: any ConversionEngine, inputURLs: [URL], outputFormat: FileFormat, tempDir: URL) async throws -> URL {
        let result = try await engine.convert(inputs: inputURLs, to: outputFormat, outputDirectory: tempDir, options: .default, progress: { _ in })
        return result.outputURL
    }

    @Test("Phase 13 AVIF Conversions")
    func testAVIFConversions() async throws {
        let engine = ImageConversionEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let avifInput = tempDir.appendingPathComponent("test.avif")
        let pngInput = tempDir.appendingPathComponent("test.png")
        
        // Use swift script to generate a small png using CoreGraphics
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==")!
        try data.write(to: pngInput)
        
        // PNG -> AVIF
        let outAVIF = try await runConversion(engine: engine, inputURLs: [pngInput], outputFormat: .avif, tempDir: tempDir)
        #expect(FileManager.default.fileExists(atPath: outAVIF.path))
        
        // AVIF -> PNG
        let outPNG = try await runConversion(engine: engine, inputURLs: [outAVIF], outputFormat: .png, tempDir: tempDir)
        #expect(FileManager.default.fileExists(atPath: outPNG.path))
    }

    @Test("Phase 13 SVG Conversions")
    func testSVGConversions() async throws {
        let engine = ImageConversionEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let svgInput = tempDir.appendingPathComponent("test.svg")
        let svgString = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><circle cx=\"5\" cy=\"5\" r=\"4\" fill=\"red\"/></svg>"
        try svgString.write(to: svgInput, atomically: true, encoding: .utf8)
        
        // SVG -> PNG
        let outPNG = try await runConversion(engine: engine, inputURLs: [svgInput], outputFormat: .png, tempDir: tempDir)
        #expect(FileManager.default.fileExists(atPath: outPNG.path))
        
        // SVG -> PDF
        let outPDF = try await runConversion(engine: engine, inputURLs: [svgInput], outputFormat: .pdf, tempDir: tempDir)
        #expect(FileManager.default.fileExists(atPath: outPDF.path))
    }
}

extension Phase13Tests {
    @Test("Phase 13 CSV/TSV Conversions")
    func testCSVTSVConversions() async throws {
        let engine = TextConversionEngine()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let csvInput = tempDir.appendingPathComponent("test.csv")
        try "A,B\n1,2".write(to: csvInput, atomically: true, encoding: .utf8)
        
        // CSV -> TSV
        let outTSV = try await runConversion(engine: engine, inputURLs: [csvInput], outputFormat: .tsv, tempDir: tempDir)
        #expect(FileManager.default.fileExists(atPath: outTSV.path))
        
        // TSV -> CSV
        let outCSV = try await runConversion(engine: engine, inputURLs: [outTSV], outputFormat: .csv, tempDir: tempDir)
        #expect(FileManager.default.fileExists(atPath: outCSV.path))
    }
}
