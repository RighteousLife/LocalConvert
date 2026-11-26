import XCTest
import Foundation
import AppKit
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LocalConvert

final class Milestone3MemoryCapsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConversionManager.clearReservedOutputURLs()
    }

    override func tearDown() {
        ConversionManager.clearReservedOutputURLs()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String = "M3Caps") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeVectorPDF(at url: URL, pageSizes: [CGSize]) throws {
        precondition(!pageSizes.isEmpty)
        var initialBox = CGRect(origin: .zero, size: pageSizes[0])
        guard let ctx = CGContext(url as CFURL, mediaBox: &initialBox, nil) else {
            throw NSError(domain: "Milestone3MemoryCapsTests", code: 1)
        }
        for size in pageSizes {
            var pageBox = CGRect(origin: .zero, size: size)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.setFillColor(.white)
            ctx.fill(pageBox)
            ctx.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1.0))
            ctx.fill(CGRect(x: 10, y: 10, width: min(40, size.width * 0.5), height: min(40, size.height * 0.5)))
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private func makeSolidImage(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) throws -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Milestone3MemoryCapsTests", code: 2)
        }
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            throw NSError(domain: "Milestone3MemoryCapsTests", code: 3)
        }
        return image
    }

    private func writeAnimatedGIF(to url: URL, width: Int = 32, height: Int = 32, frameCount: Int = 3) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw NSError(domain: "Milestone3MemoryCapsTests", code: 4)
        }
        CGImageDestinationSetProperties(
            dest,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        )
        let palette: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
        for i in 0..<frameCount {
            let color = palette[i % palette.count]
            let frame = try makeSolidImage(width: width, height: height, r: color.0, g: color.1, b: color.2)
            CGImageDestinationAddImage(
                dest,
                frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08]] as CFDictionary
            )
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func makeAnimatedWebPData(width: Int = 32, height: Int = 32) throws -> Data {
        let frame1 = try makeSolidImage(width: width, height: height, r: 1, g: 0, b: 0)
        let frame2 = try makeSolidImage(width: width, height: height, r: 0, g: 0, b: 1)
        let enc = WebPEncoder()
        let raw1 = try enc.encode(image: frame1, mode: .lossless)
        let raw2 = try enc.encode(image: frame2, mode: .lossless)

        func extractBitstreamChunk(from webp: Data) -> Data? {
            let bytes = [UInt8](webp)
            var off = 12
            while off + 8 <= bytes.count {
                let tag = String(decoding: bytes[off..<(off + 4)], as: UTF8.self)
                let len = Int(
                    UInt32(bytes[off + 4]) |
                    (UInt32(bytes[off + 5]) << 8) |
                    (UInt32(bytes[off + 6]) << 16) |
                    (UInt32(bytes[off + 7]) << 24)
                )
                let end = off + 8 + len
                guard end <= bytes.count else { return nil }
                if tag == "VP8 " || tag == "VP8L" {
                    var chunk = Data(bytes[off..<end])
                    if len % 2 == 1 { chunk.append(0) }
                    return chunk
                }
                off = end + (len & 1)
            }
            return nil
        }

        func appendLE16(_ v: UInt16, to d: inout Data) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        }
        func appendLE24(_ v: UInt32, to d: inout Data) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
        }
        func appendLE32(_ v: UInt32, to d: inout Data) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        }
        func appendChunk(_ fourCC: String, payload: Data, to d: inout Data) {
            d.append(contentsOf: fourCC.utf8.prefix(4))
            appendLE32(UInt32(payload.count), to: &d)
            d.append(payload)
            if payload.count % 2 == 1 { d.append(0) }
        }
        func buildANMF(frameChunk: Data, durationMs: UInt32) -> Data {
            var p = Data()
            appendLE24(0, to: &p)
            appendLE24(0, to: &p)
            appendLE24(UInt32(width - 1), to: &p)
            appendLE24(UInt32(height - 1), to: &p)
            appendLE24(durationMs, to: &p)
            p.append(0x02)
            p.append(frameChunk)
            return p
        }

        let chunk1 = try XCTUnwrap(extractBitstreamChunk(from: raw1))
        let chunk2 = try XCTUnwrap(extractBitstreamChunk(from: raw2))

        var body = Data()
        var vp8x = Data([0x02, 0, 0, 0])
        appendLE24(UInt32(width - 1), to: &vp8x)
        appendLE24(UInt32(height - 1), to: &vp8x)
        appendChunk("VP8X", payload: vp8x, to: &body)

        var anim = Data([0, 0, 0, 0])
        appendLE16(0, to: &anim)
        appendChunk("ANIM", payload: anim, to: &body)

        appendChunk("ANMF", payload: buildANMF(frameChunk: chunk1, durationMs: 80), to: &body)
        appendChunk("ANMF", payload: buildANMF(frameChunk: chunk2, durationMs: 80), to: &body)

        var out = Data("RIFF".utf8)
        appendLE32(UInt32(4 + body.count), to: &out)
        out.append(contentsOf: "WEBP".utf8)
        out.append(body)
        return out
    }

    private func writeOversizedHeaderAnimatedGIF(to url: URL, canvasWidth: UInt16 = 8000, canvasHeight: UInt16 = 8000) throws {
        // Build a valid 3-frame 1x1 GIF via ImageIO, then patch Logical Screen Descriptor dimensions.
        let temp1x1 = url.deletingLastPathComponent().appendingPathComponent("seed_1x1_\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: temp1x1) }
        try writeAnimatedGIF(to: temp1x1, width: 1, height: 1, frameCount: 3)

        var bytes = [UInt8](try Data(contentsOf: temp1x1))
        XCTAssertGreaterThan(bytes.count, 10)
        bytes[6] = UInt8(canvasWidth & 0xFF)
        bytes[7] = UInt8((canvasWidth >> 8) & 0xFF)
        bytes[8] = UInt8(canvasHeight & 0xFF)
        bytes[9] = UInt8((canvasHeight >> 8) & 0xFF)
        try Data(bytes).write(to: url)
    }

    // MARK: - LC-015: PDF Page Pixel Budget Tests

    func testPDFConversionEngineRejectsOversizedArchitecturalPageAt600DPIWithoutOOM() async throws {
        let dir = try makeTempDir(prefix: "M3-PDFCap")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 36" x 48" architectural E-size sheet (2592 x 3456 pt). At 600 DPI -> 21,600 x 28,800 = 622 MP > 100 MP cap.
        let archPDF = dir.appendingPathComponent("architectural_e_size.pdf")
        try writeVectorPDF(at: archPDF, pageSizes: [CGSize(width: 2592, height: 3456)])

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let engine = PDFConversionEngine()
        var highDPIOpts = ConversionOptions.default
        highDPIOpts.pdfDPI = 600.0

        do {
            _ = try await engine.convert(
                inputs: [archPDF],
                to: .png,
                outputDirectory: outDir,
                options: highDPIOpts,
                progress: { _ in }
            )
            XCTFail("Expected oversized 600 DPI architectural PDF page to fail pixel budget check")
        } catch let error as ConversionError {
            guard case .invalidInput(let message) = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("100 MP") || message.contains("pixel") || message.contains("DPI"), "Unexpected message: \(message)")
        }

        let remainingOutputs = try FileManager.default.contentsOfDirectory(atPath: outDir.path)
        XCTAssertTrue(remainingOutputs.isEmpty, "Rejected PDF conversion must not leave output files behind")
    }

    func testPDFConversionEngineMultiPagePreflightRejectsBeforeWritingPartialPagesAndAllowsNormalPages() async throws {
        let dir = try makeTempDir(prefix: "M3-PDFMulti")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Page 1 is US Letter (612x792), Page 2 is a 12,000x12,000 pt poster (144 MP even at 72 DPI)
        let mixedPDF = dir.appendingPathComponent("mixed.pdf")
        try writeVectorPDF(at: mixedPDF, pageSizes: [
            CGSize(width: 612, height: 792),
            CGSize(width: 12_000, height: 12_000)
        ])

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let engine = PDFConversionEngine()
        var opts72 = ConversionOptions.default
        opts72.pdfDPI = 72.0

        do {
            _ = try await engine.convert(
                inputs: [mixedPDF],
                to: .png,
                outputDirectory: outDir,
                options: opts72,
                progress: { _ in }
            )
            XCTFail("Expected multi-page PDF with oversized page 2 to fail before committing page 1")
        } catch let error as ConversionError {
            guard case .invalidInput(let msg) = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("page 2"), "Error should identify offending page 2: \(msg)")
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outDir.path).isEmpty)

        // Normal single-page US Letter PDF at 72 DPI succeeds cleanly
        let normalPDF = dir.appendingPathComponent("letter.pdf")
        try writeVectorPDF(at: normalPDF, pageSizes: [CGSize(width: 612, height: 792)])
        let result = try await engine.convert(
            inputs: [normalPDF],
            to: .png,
            outputDirectory: outDir,
            options: opts72,
            progress: { _ in }
        )
        let imgSrc = try XCTUnwrap(CGImageSourceCreateWithURL(result.outputURL as CFURL, nil))
        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imgSrc, 0, nil))
        XCTAssertEqual(rendered.width, 612)
        XCTAssertEqual(rendered.height, 792)
    }

    func testPDFConversionEngineValidatedRenderPixelSizeGuardsOverflowAndInvalidDPI() throws {
        let dir = try makeTempDir(prefix: "M3-PDFOverflow")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("letter.pdf")
        try writeVectorPDF(at: pdfURL, pageSizes: [CGSize(width: 612, height: 792)])
        let doc = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(doc.page(at: 0))

        // Valid DPI
        let valid = try PDFConversionEngine.validatedRenderPixelSize(for: page, dpi: 150.0, pageNumber: 1)
        XCTAssertEqual(valid.width, 1275)
        XCTAssertEqual(valid.height, 1650)

        // Invalid / non-finite / overflow-inducing DPI values must throw cleanly without trapping
        for badDPI in [0.0, -72.0, Double.nan, Double.infinity, 1e30] {
            XCTAssertThrowsError(
                try PDFConversionEngine.validatedRenderPixelSize(for: page, dpi: badDPI, pageNumber: 1)
            ) { error in
                guard case ConversionError.invalidInput = error else {
                    XCTFail("Expected ConversionError.invalidInput for DPI \(badDPI), got \(error)")
                    return
                }
            }
        }

        // Custom small budget triggers deterministic error without large allocations
        XCTAssertThrowsError(
            try PDFConversionEngine.validatedRenderPixelSize(for: page, dpi: 72.0, pageNumber: 1, maxPagePixels: 100_000)
        ) { error in
            guard case ConversionError.invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
        }
    }

    // MARK: - LC-015: Animated Image Memory Budget & No Duplicate Frame-0 Decode

    func testAnimatedMemoryBudgetRejectsIntegerOverflowAndOversizedAnimations() throws {
        // Integer overflow checks
        XCTAssertThrowsError(
            try ImageConversionEngine.validateAnimatedMemoryBudget(width: Int.max, height: Int.max, frameCount: 2)
        ) { error in
            guard case ConversionError.invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput on width*height overflow, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(
            try ImageConversionEngine.validateAnimatedMemoryBudget(width: 10_000, height: 10_000, frameCount: Int.max)
        ) { error in
            guard case ConversionError.invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput on frameCount overflow, got \(error)")
                return
            }
        }

        // Exceeds per-frame 100 MP limit
        XCTAssertThrowsError(
            try ImageConversionEngine.validateAnimatedMemoryBudget(width: 12_000, height: 12_000, frameCount: 2)
        )

        // Within per-frame limit (64 MP), exceeds 512 MiB total uncompressed frame budget (3 * 256 MB = 768 MB)
        XCTAssertThrowsError(
            try ImageConversionEngine.validateAnimatedMemoryBudget(width: 8_000, height: 8_000, frameCount: 3, bytesPerPixel: 4)
        )

        // Zero/invalid inputs
        XCTAssertThrowsError(
            try ImageConversionEngine.validateAnimatedMemoryBudget(width: 0, height: 100, frameCount: 2)
        )

        // Normal small animation passes
        XCTAssertNoThrow(
            try ImageConversionEngine.validateAnimatedMemoryBudget(width: 64, height: 64, frameCount: 4, bytesPerPixel: 4)
        )
    }

    func testOversizedCanvasAnimatedGIFFailsCleanlyViaEngineConvertWithoutAllocatingFrames() async throws {
        let dir = try makeTempDir(prefix: "M3-AnimHeaderCap")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 114-byte valid 3-frame GIF whose Logical Screen Descriptor is 8000x8000 (768 MB uncompressed > 512 MiB cap)
        let oversizedGIF = dir.appendingPathComponent("oversized_canvas.gif")
        try writeOversizedHeaderAnimatedGIF(to: oversizedGIF, canvasWidth: 8000, canvasHeight: 8000)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let engine = ImageConversionEngine()
        do {
            _ = try await engine.convert(
                inputs: [oversizedGIF],
                to: .jxl,
                outputDirectory: outDir,
                options: .default,
                progress: { _ in }
            )
            XCTFail("Expected oversized-canvas animated GIF conversion to fail memory budget")
        } catch let error as ConversionError {
            guard case .invalidInput(let msg) = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("memory budget") || msg.contains("limit"), "Unexpected message: \(msg)")
        }

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outDir.path).isEmpty)
    }

    func testAnimatedGIFToJXLEliminatesDuplicateFrame0DecodeAndEnforcesCap() async throws {
        final class DecodedFrameTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var indices: [Int] = []

            func record(_ index: Int) {
                lock.lock()
                indices.append(index)
                lock.unlock()
            }

            func snapshot() -> [Int] {
                lock.lock()
                defer { lock.unlock() }
                return indices
            }
        }

        let dir = try makeTempDir(prefix: "M3-AnimGIF")
        defer { try? FileManager.default.removeItem(at: dir) }

        let gifURL = dir.appendingPathComponent("small_anim.gif")
        try writeAnimatedGIF(to: gifURL, width: 32, height: 32, frameCount: 3)

        let jxlOut = dir.appendingPathComponent("small_anim.jxl")
        let tracker = DecodedFrameTracker()

        let didConvert = try await ImageConversionEngine.convertAnimatedIfApplicable(
            input: gifURL,
            inputFormat: .gif,
            outputFormat: .jxl,
            outputURL: jxlOut,
            options: .default,
            onFrameDecoded: { index in tracker.record(index) },
            progress: { _ in }
        )

        XCTAssertTrue(didConvert)
        XCTAssertEqual(tracker.snapshot(), [0, 1, 2], "Each frame including frame 0 must be decoded exactly once")
        let jxlInfo = try JPEGXLCodec.inspect(url: jxlOut)
        XCTAssertTrue(jxlInfo.isAnimated)
        XCTAssertEqual(jxlInfo.frameCount, 3)

        // Tight budget rejects 32x32x4x3 = 12,288 bytes before decoding any frame
        let cappedOut = dir.appendingPathComponent("capped_out.jxl")
        let cappedTracker = DecodedFrameTracker()
        do {
            _ = try await ImageConversionEngine.convertAnimatedIfApplicable(
                input: gifURL,
                inputFormat: .gif,
                outputFormat: .jxl,
                outputURL: cappedOut,
                options: .default,
                maxUncompressedMemoryBytes: 1024,
                onFrameDecoded: { index in cappedTracker.record(index) },
                progress: { _ in }
            )
            XCTFail("Expected tight animated memory cap to reject 32x32 3-frame GIF")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
        }
        XCTAssertTrue(cappedTracker.snapshot().isEmpty, "Oversized animated GIF must be rejected before decoding any frames")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cappedOut.path))

        // Animated JXL -> Animated GIF succeeds under normal budget and rejects under tight budget
        let gifRoundtripOut = dir.appendingPathComponent("roundtrip.gif")
        let jxlToGIF = try await ImageConversionEngine.convertAnimatedIfApplicable(
            input: jxlOut,
            inputFormat: .jxl,
            outputFormat: .gif,
            outputURL: gifRoundtripOut,
            options: .default,
            progress: { _ in }
        )
        XCTAssertTrue(jxlToGIF)
        let roundtripSrc = try XCTUnwrap(CGImageSourceCreateWithURL(gifRoundtripOut as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(roundtripSrc), 3)

        let cappedJXLOut = dir.appendingPathComponent("capped_jxl_roundtrip.gif")
        do {
            _ = try await ImageConversionEngine.convertAnimatedIfApplicable(
                input: jxlOut,
                inputFormat: .jxl,
                outputFormat: .gif,
                outputURL: cappedJXLOut,
                options: .default,
                maxUncompressedMemoryBytes: 1024,
                progress: { _ in }
            )
            XCTFail("Expected tight animated memory cap to reject 32x32 3-frame JXL")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cappedJXLOut.path))
    }

    func testAnimatedWebPToGIFEliminatesDuplicateFrame0DecodeAndRespectsCap() async throws {
        final class DecodedFrameTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var indices: [Int] = []

            func record(_ index: Int) {
                lock.lock()
                indices.append(index)
                lock.unlock()
            }

            func snapshot() -> [Int] {
                lock.lock()
                defer { lock.unlock() }
                return indices
            }
        }

        let dir = try makeTempDir(prefix: "M3-AnimWebP")
        defer { try? FileManager.default.removeItem(at: dir) }

        let webpURL = dir.appendingPathComponent("small_anim.webp")
        try makeAnimatedWebPData(width: 32, height: 32).write(to: webpURL)

        let gifOut = dir.appendingPathComponent("from_webp.gif")
        let tracker = DecodedFrameTracker()
        let ok = try await ImageConversionEngine.convertAnimatedIfApplicable(
            input: webpURL,
            inputFormat: .webp,
            outputFormat: .gif,
            outputURL: gifOut,
            options: .default,
            onFrameDecoded: { index in tracker.record(index) },
            progress: { _ in }
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(tracker.snapshot(), [0, 1], "Animated WebP frame 0 must be decoded exactly once")
        let gifSrc = try XCTUnwrap(CGImageSourceCreateWithURL(gifOut as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gifSrc), 2)

        let cappedGIFOut = dir.appendingPathComponent("capped_from_webp.gif")
        do {
            _ = try await ImageConversionEngine.convertAnimatedIfApplicable(
                input: webpURL,
                inputFormat: .webp,
                outputFormat: .gif,
                outputURL: cappedGIFOut,
                options: .default,
                maxUncompressedMemoryBytes: 1024,
                progress: { _ in }
            )
            XCTFail("Expected tight animated memory cap to reject 32x32 2-frame WebP")
        } catch let error as ConversionError {
            guard case .invalidInput = error else {
                XCTFail("Expected ConversionError.invalidInput, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cappedGIFOut.path))
    }
}
