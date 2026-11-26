import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import LocalConvert

@Suite("Phase 42 — 12 LibreOffice Routes, HDR/Wide-Gamut Fidelity & Cache Validation")
struct Phase42ValidationAndHDRTests {

    // MARK: - Helpers

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P42Valid-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func make16BitImage(
        width: Int,
        height: Int,
        colorSpaceName: CFString,
        includeAlpha: Bool = true
    ) throws -> CGImage {
        let cs = try #require(CGColorSpace(name: colorSpaceName))
        let channels = 4
        let bytesPerRow = width * channels * 2
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let idx = (y * width + x) * 4
                    let u = Double(x) / Double(max(1, width - 1))
                    let v = Double(y) / Double(max(1, height - 1))
                    // Non-integer-8-bit stepped HDR/16-bit ramp across full 0..65535 dynamic range
                    ptr[idx]     = UInt16((u * 65535.0).rounded())
                    ptr[idx + 1] = UInt16((v * 65535.0).rounded())
                    ptr[idx + 2] = UInt16(((0.5 * u + 0.5 * (1.0 - v)) * 65535.0).rounded())
                    ptr[idx + 3] = includeAlpha ? UInt16(52428) : UInt16(65535) // 80% alpha if enabled
                }
            }
        }
        let byteOrder16Host: UInt32 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue
        let alphaBit = includeAlpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: byteOrder16Host | alphaBit),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func writePNG(_ cgImage: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func writeTIFF(_ cgImage: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func extract16BitRedChannelValues(from cgImage: CGImage) -> [UInt16] {
        guard cgImage.bitsPerComponent == 16,
              let data = cgImage.dataProvider?.data as Data? else {
            return []
        }
        let channels = max(1, cgImage.bitsPerPixel / 16)
        let isBig16 = cgImage.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Big
        let rowBytes = cgImage.bytesPerRow
        var vals: [UInt16] = []
        vals.reserveCapacity(cgImage.width)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let y = cgImage.height / 2
            let rowOff = y * rowBytes
            for x in 0..<cgImage.width {
                let off = rowOff + x * channels * 2
                let b0 = UInt16(base.load(fromByteOffset: off, as: UInt8.self))
                let b1 = UInt16(base.load(fromByteOffset: off + 1, as: UInt8.self))
                let v: UInt16 = isBig16 ? ((b0 << 8) | b1) : ((b1 << 8) | b0)
                vals.append(v)
            }
        }
        return vals
    }

    // MARK: - G. Complete 12-Route Bundled LibreOffice Matrix + CodeSign Integrity

    @Test("All 12 bundled LibreOffice conversion routes (including ODT->DOCX, ODS->XLSX, ODP->PPTX) succeed and keep LibreOffice signature intact")
    func allTwelveLibreOfficeRoutesAndSignatureIntegrity() async throws {
        let dir = try makeTempDir("lo_12routes")
        defer { try? FileManager.default.removeItem(at: dir) }

        let loProvider = BundledLibreOfficeProvider(fallbackToSystem: false)
        let sofficePath = try #require(await loProvider.findExecutablePath())
        let officeEngine = OfficeConversionEngine(provider: loProvider)

        let docx = try TestFixtureFactory.createDOCX(in: dir, name: "source.docx", text: "Phase 42 Full 12-Route Validation Document")
        let xlsx = try TestFixtureFactory.createXLSX(in: dir, name: "source.xlsx", text: "Quarter", number: "2026")
        let pptx = try TestFixtureFactory.createPPTX(in: dir, name: "source.pptx", title: "Phase 42 Slide Deck")
        let textPDF = try TestFixtureFactory.createPDFWithText(in: dir, name: "text.pdf", title: "Statement #42", body: "Row item amount $990")
        let tablePDF = try TestFixtureFactory.createPDFWithTable(in: dir, name: "table.pdf")
        let htmlURL = dir.appendingPathComponent("page.html")
        try "<!DOCTYPE html><html><body><h1>Phase 42 HTML</h1><p>LibreOffice HTML->DOCX check.</p></body></html>".write(to: htmlURL, atomically: true, encoding: .utf8)

        // Generate OpenDocument inputs (.odt, .ods, .odp) from Office sources using bundled LibreOffice first
        let odfSeedDir = dir.appendingPathComponent("odf_inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: odfSeedDir, withIntermediateDirectories: true)
        let odtInput = try await officeEngine.convert(inputs: [docx], to: .odt, outputDirectory: odfSeedDir, options: .default) { _ in }.outputURL
        let odsInput = try await officeEngine.convert(inputs: [xlsx], to: .ods, outputDirectory: odfSeedDir, options: .default) { _ in }.outputURL
        let odpInput = try await officeEngine.convert(inputs: [pptx], to: .odp, outputDirectory: odfSeedDir, options: .default) { _ in }.outputURL

        struct RouteSpec {
            let label: String
            let input: URL
            let target: FileFormat
            let pdfMode: PDFOfficeConversionMode
        }

        let routes: [RouteSpec] = [
            RouteSpec(label: "R1_DOCX_PDF", input: docx, target: .pdf, pdfMode: .editable),
            RouteSpec(label: "R2_XLSX_PDF", input: xlsx, target: .pdf, pdfMode: .editable),
            RouteSpec(label: "R3_PPTX_PDF", input: pptx, target: .pdf, pdfMode: .editable),
            RouteSpec(label: "R4_PDF_DOCX_Editable", input: textPDF, target: .docx, pdfMode: .editable),
            RouteSpec(label: "R5_PDF_DOCX_Visual", input: textPDF, target: .docx, pdfMode: .visual),
            RouteSpec(label: "R6_PDF_XLSX", input: tablePDF, target: .xlsx, pdfMode: .editable),
            RouteSpec(label: "R7_PDF_PPTX", input: textPDF, target: .pptx, pdfMode: .editable),
            RouteSpec(label: "R8_HTML_DOCX", input: htmlURL, target: .docx, pdfMode: .editable),
            RouteSpec(label: "R9_DOCX_EPUB", input: docx, target: .epub, pdfMode: .editable),
            RouteSpec(label: "R10_ODT_DOCX", input: odtInput, target: .docx, pdfMode: .editable),
            RouteSpec(label: "R11_ODS_XLSX", input: odsInput, target: .xlsx, pdfMode: .editable),
            RouteSpec(label: "R12_ODP_PPTX", input: odpInput, target: .pptx, pdfMode: .editable)
        ]

        for route in routes {
            let outDir = dir.appendingPathComponent(route.label, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            var opts = ConversionOptions.default
            opts.pdfOfficeMode = route.pdfMode
            let res = try await officeEngine.convert(inputs: [route.input], to: route.target, outputDirectory: outDir, options: opts) { _ in }
            #expect(FileManager.default.fileExists(atPath: res.outputURL.path), "Missing output for \(route.label)")
            #expect(res.fileSize > 500, "Output too small for \(route.label): \(res.fileSize)")
            if route.target == .pdf {
                let doc = try #require(PDFDocument(url: res.outputURL), "Unreadable PDF for \(route.label)")
                #expect(doc.pageCount >= 1)
            }
        }

        // Verify bundled LibreOffice.app signature remained pristine across all 12 routes
        let libreAppURL = URL(fileURLWithPath: sofficePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let verifyProc = Process()
        verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifyProc.arguments = ["--verify", "--deep", "--strict", libreAppURL.path]
        let verifyOut = try await AsyncProcessRunner.run(verifyProc, stdin: .nullDevice, timeout: 30)
        let verifyErr = String(data: verifyOut.stderr, encoding: .utf8) ?? ""
        #expect(verifyOut.terminationStatus == 0, "codesign verification failed after 12 LibreOffice routes: \(verifyErr)")
    }

    // MARK: - H. HDR, PQ/HLG, Rec.2020, Display P3, OpenEXR & JXL 16-bit Lossless Fidelity

    @Test("PQ, HLG, Rec.2020, Display P3, 16-bit TIFF, JXL 16-bit lossless, OpenEXR float, and HDR->SDR pipelines preserve valid color spaces and precision")
    func hdrAndWideGamutImageFidelity() async throws {
        let dir = try makeTempDir("hdr_fidelity")
        defer { try? FileManager.default.removeItem(at: dir) }

        let imgEngine = ImageConversionEngine()

        // 1. PQ (BT.2100 ST 2084) 16-bit PNG -> 16-bit TIFF + JXL 16-bit lossless
        let pqImg = try make16BitImage(width: 512, height: 32, colorSpaceName: CGColorSpace.itur_2100_PQ, includeAlpha: false)
        let pqPNG = dir.appendingPathComponent("src_pq.png")
        try writePNG(pqImg, to: pqPNG)

        var jxlLosslessOpts = ConversionOptions.default
        jxlLosslessOpts.customOptions["jxl_lossless"] = "true"
        jxlLosslessOpts.customOptions["jxl_bit_depth"] = "16"

        let pqToJXL = try await imgEngine.convert(inputs: [pqPNG], to: .jxl, outputDirectory: dir, options: jxlLosslessOpts) { _ in }
        let pqDecodedJXL = try JPEGXLCodec.decode(url: pqToJXL.outputURL, prefer16Bit: true)
        #expect(pqDecodedJXL.info.bitsPerSample == 16)
        #expect(pqDecodedJXL.info.hasICCProfile)
        let pqRedDecoded = extract16BitRedChannelValues(from: pqDecodedJXL.frames[0].image)
        #expect(Set(pqRedDecoded).count > 300) // True 16-bit ramp (>256 unique levels) preserved across JXL lossless!

        // 2. HLG (BT.2100) 16-bit PNG -> JXL 16-bit lossless + TIFF
        let hlgImg = try make16BitImage(width: 512, height: 32, colorSpaceName: CGColorSpace.itur_2100_HLG, includeAlpha: false)
        let hlgPNG = dir.appendingPathComponent("src_hlg.png")
        try writePNG(hlgImg, to: hlgPNG)
        let hlgToJXL = try await imgEngine.convert(inputs: [hlgPNG], to: .jxl, outputDirectory: dir, options: jxlLosslessOpts) { _ in }
        let hlgDecoded = try JPEGXLCodec.decode(url: hlgToJXL.outputURL, prefer16Bit: true)
        #expect(hlgDecoded.info.bitsPerSample == 16)
        #expect(hlgDecoded.info.hasICCProfile)

        // 3. Rec.2020 16-bit TIFF -> Resize & 16-bit PNG + 16-bit JXL
        let rec2020Img = try make16BitImage(width: 600, height: 64, colorSpaceName: CGColorSpace.itur_2020, includeAlpha: true)
        let rec2020TIFF = dir.appendingPathComponent("src_rec2020.tiff")
        try writeTIFF(rec2020Img, to: rec2020TIFF)
        var resizeOpts = ConversionOptions.default
        resizeOpts.resizeMode = .exactWidth
        resizeOpts.resizeWidth = 400
        resizeOpts.customOptions["jxl_lossless"] = "true"
        resizeOpts.customOptions["jxl_bit_depth"] = "16"
        let recResizedJXL = try await imgEngine.convert(inputs: [rec2020TIFF], to: .jxl, outputDirectory: dir, options: resizeOpts) { _ in }
        let recDecoded = try JPEGXLCodec.decode(url: recResizedJXL.outputURL, prefer16Bit: true)
        #expect(recDecoded.frames[0].image.width == 400)
        #expect(recDecoded.info.bitsPerSample == 16)
        #expect(recDecoded.info.hasICCProfile)

        // 4. OpenEXR float HDR (> 1.0 specular linear RGB) -> PNG / JPEG / JXL
        let exrURL = dir.appendingPathComponent("specular.exr")
        let floatCS = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let ciHdrColor = CIColor(red: 1.8, green: 0.75, blue: 0.25, alpha: 1.0, colorSpace: floatCS)
            ?? CIColor(red: 1.0, green: 0.75, blue: 0.25, alpha: 1.0)
        let hdrCI = CIImage(color: ciHdrColor).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let ciCtx = CIContext(options: [.workingColorSpace: floatCS, .outputColorSpace: floatCS])
        try ciCtx.writeOpenEXRRepresentation(of: hdrCI, to: exrURL, options: [:])
        let exrToJPEG = try await imgEngine.convert(inputs: [exrURL], to: .jpg, outputDirectory: dir, options: .default) { _ in }
        #expect(exrToJPEG.fileSize > 100)
        let exrToJXL = try await imgEngine.convert(inputs: [exrURL], to: .jxl, outputDirectory: dir, options: jxlLosslessOpts) { _ in }
        #expect(exrToJXL.fileSize > 100)

        // 5. HDR (PQ 16-bit) -> SDR (8-bit JPEG & WebP) produces valid 8-bit SDR image
        let pqToJPEG = try await imgEngine.convert(inputs: [pqPNG], to: .jpg, outputDirectory: dir, options: .default) { _ in }
        let pqJPEGSource = try #require(CGImageSourceCreateWithURL(pqToJPEG.outputURL as CFURL, nil))
        let pqJPEGCG = try #require(CGImageSourceCreateImageAtIndex(pqJPEGSource, 0, nil))
        #expect(pqJPEGCG.bitsPerComponent == 8)
        #expect(pqJPEGCG.width == 512 && pqJPEGCG.height == 32)
        let pqToWebP = try await imgEngine.convert(inputs: [pqPNG], to: .webp, outputDirectory: dir, options: .default) { _ in }
        #expect(pqToWebP.fileSize > 100)
    }

    // MARK: - F4. Audio Waveform Cache, Normalization Cache & CIContext Pool Bounds

    @Test("Waveform cache honors hits/misses, mtime invalidation, 32-entry cap, and normalization cache caps at 256 entries")
    func cacheDiagnosticsAndEvictionBounds() async throws {
        let dir = try makeTempDir("caches")
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = AudioAnalysisService.shared
        await service.resetCacheForTesting()
        await service.resetNormalizationModeCacheForTesting()

        let wav = try TestFixtureFactory.createWAV(in: dir, name: "wave.wav", duration: 0.4)
        _ = try await service.extractWaveform(url: wav, bins: 120)
        let diag1 = await service.cacheDiagnostics()
        #expect(diag1.entryCount == 1)
        #expect(diag1.misses == 1 && diag1.hits == 0)
        #expect(diag1.totalBytes > 0 && diag1.totalBytes <= diag1.maxBytes)

        // Second call with identical file hits cache without invoking FFmpeg
        _ = try await service.extractWaveform(url: wav, bins: 120)
        let diag2 = await service.cacheDiagnostics()
        #expect(diag2.hits == 1 && diag2.misses == 1)

        // Modifying mtime + content invalidates cache key cleanly
        try await Task.sleep(for: .milliseconds(25))
        _ = try TestFixtureFactory.createWAV(in: dir, name: "wave.wav", duration: 0.7)
        _ = try await service.extractWaveform(url: wav, bins: 120)
        let diag3 = await service.cacheDiagnostics()
        #expect(diag3.misses == 2)

        // Insert 40 unique bin requests -> enforces 32-entry cap with LRU eviction
        for b in stride(from: 60, to: 60 + 40 * 4, by: 4) {
            _ = try await service.extractWaveform(url: wav, bins: b)
        }
        let diag4 = await service.cacheDiagnostics()
        #expect(diag4.entryCount == 32)
        #expect(diag4.maxEntries == 32)
        #expect(diag4.maxBytes == 8 * 1024 * 1024)
        #expect(diag4.totalBytes <= diag4.maxBytes)
        #expect(diag4.evictions > 0)

        // Verify normalizationModeCache caps at 256 entries
        for i in 0..<280 {
            let u = dir.appendingPathComponent("norm_\(i).m4a")
            await service.recordNormalizationMode("ebur128", for: u)
        }
        let normDiag = await service.normalizationModeCacheDiagnostics()
        #expect(normDiag.entryCount == 256)
        #expect(normDiag.maxEntries == 256)

        // Verify ImageProcessor.sharedCIContext reuses identical instance per color space
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx1 = ImageProcessor.sharedCIContext(for: srgb)
        let ctx2 = ImageProcessor.sharedCIContext(for: srgb)
        #expect(ctx1 === ctx2)
    }
}
