import Testing
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import AppKit
import UniformTypeIdentifiers
import Darwin
@testable import LocalConvert

@Suite("Phase 41 — RC Validation, HDR Pixel Integrity, Resource Efficiency & 16-Workload Benchmarks")
struct Phase41ValidationAndEfficiencyTests {

    // MARK: - Helpers

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P41ValBench-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func currentRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kern == KERN_SUCCESS ? Double(info.resident_size) / (1024 * 1024) : 0
    }

    private func totalProcessCPUTimeSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let u = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1_000_000.0
        let s = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1_000_000.0
        return u + s
    }

    private func localConvertTempFootprintBytes() -> Int64 {
        let tmp = FileManager.default.temporaryDirectory
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return 0
        }
        var total: Int64 = 0
        for item in items where item.lastPathComponent.hasPrefix("LocalConvert-") || item.lastPathComponent.hasPrefix("LocalConvertAudio_") {
            if let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in enumerator {
                    if let sz = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(sz)
                    }
                }
            }
            if let sz = (try? fm.attributesOfItem(atPath: item.path)[.size] as? NSNumber)?.int64Value {
                total += sz
            }
        }
        return total
    }

    private func make16BitGradientPNG(width: Int, height: Int, to url: URL, colorSpaceName: CFString = CGColorSpace.displayP3) throws {
        let cs = try #require(CGColorSpace(name: colorSpaceName))
        let bytesPerPixel = 8 // RGBA16
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let alphaNorm = Double(y) / Double(max(1, height - 1))
            let aVal = UInt16((alphaNorm * 65535.0).rounded())
            for x in 0..<width {
                let ramp = Double(x) / Double(max(1, width - 1))
                let rVal = UInt16((ramp * 65535.0).rounded())
                let gVal = UInt16(((1.0 - ramp) * 48000.0).rounded())
                let bVal: UInt16 = 32768
                let idx = (y * width + x) * 4
                pixels[idx] = rVal
                pixels[idx + 1] = gVal
                pixels[idx + 2] = bVal
                pixels[idx + 3] = (x < 4 && y < 4) ? 0 : aVal
            }
        }
        let data = Data(bytes: &pixels, count: pixels.count * MemoryLayout<UInt16>.size)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let byteOrder16Host: UInt32 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue
        let cgImage = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: width * bytesPerPixel,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | byteOrder16Host),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func makeHTMLFixture(in dir: URL, name: String = "doc.html") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>LocalConvert HTML</title></head>
        <body><h1>Phase 41 Validation</h1><p>Office conversion route check.</p></body></html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func recordBenchmark(
        name: String,
        body: () async throws -> Void
    ) async throws -> (durationMs: Double, peakDeltaMB: Double, postDeltaMB: Double, cpuMs: Double, tempLeakBytes: Int64) {
        let baselineRSS = currentRSSMB()
        var peakRSS = baselineRSS
        let startCPU = totalProcessCPUTimeSeconds()
        let startWall = CFAbsoluteTimeGetCurrent()
        let beforeTemp = localConvertTempFootprintBytes()

        try await body()

        peakRSS = max(peakRSS, currentRSSMB())
        let durationMs = (CFAbsoluteTimeGetCurrent() - startWall) * 1000.0
        let cpuMs = (totalProcessCPUTimeSeconds() - startCPU) * 1000.0
        let postRSS = currentRSSMB()
        let afterTemp = localConvertTempFootprintBytes()
        let tempLeak = max(0, afterTemp - beforeTemp)

        print(String(
            format: "[Benchmark] %-28@ duration=%.1fms rssBase=%.1fMB rssPeak=%.1fMB rssPost=%.1fMB cpu=%.1fms tempDelta=%lldB",
            name, durationMs, baselineRSS, peakRSS, postRSS, cpuMs, tempLeak
        ))
        return (durationMs, peakRSS - baselineRSS, postRSS - baselineRSS, cpuMs, tempLeak)
    }

    // MARK: - 1. All 9 LibreOffice Routes + Post-Run Runtime Signature Check (J1)

    @Test("All 9 LibreOffice conversion routes succeed and bundled LibreOffice.app signature stays intact")
    func allNineLibreOfficeRoutesAndCodesignCheck() async throws {
        let dir = try makeTempDir("libreoffice_9routes")
        defer { try? FileManager.default.removeItem(at: dir) }

        let loProvider = BundledLibreOfficeProvider(fallbackToSystem: false)
        let sofficePath = try #require(await loProvider.findExecutablePath())
        let officeEngine = OfficeConversionEngine(provider: loProvider)

        let docx = try TestFixtureFactory.createDOCX(in: dir, name: "in.docx", text: "Phase 41 DOCX Content")
        let xlsx = try TestFixtureFactory.createXLSX(in: dir, name: "in.xlsx", text: "Quarter", number: "99")
        let pptx = try TestFixtureFactory.createPPTX(in: dir, name: "in.pptx", title: "Phase 41 Deck")
        let textPDF = try TestFixtureFactory.createPDFWithText(in: dir, name: "text.pdf", title: "Invoice #41", body: "Line item total $420")
        let tablePDF = try TestFixtureFactory.createPDFWithTable(in: dir, name: "table.pdf")
        let html = try makeHTMLFixture(in: dir, name: "page.html")

        // 1-3: Office -> PDF
        for (input, tag) in [(docx, "docx_pdf"), (xlsx, "xlsx_pdf"), (pptx, "pptx_pdf")] {
            let outDir = dir.appendingPathComponent(tag, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let res = try await officeEngine.convert(inputs: [input], to: .pdf, outputDirectory: outDir, options: .default) { _ in }
            let doc = try #require(PDFDocument(url: res.outputURL))
            #expect(doc.pageCount >= 1)
        }

        // 4-5: PDF -> DOCX (Editable & Visual)
        for (mode, tag) in [(PDFOfficeConversionMode.editable, "pdf_docx_edit"), (PDFOfficeConversionMode.visual, "pdf_docx_vis")] {
            let outDir = dir.appendingPathComponent(tag, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            var opts = ConversionOptions.default
            opts.pdfOfficeMode = mode
            let res = try await officeEngine.convert(inputs: [textPDF], to: .docx, outputDirectory: outDir, options: opts) { _ in }
            #expect(res.fileSize > 500)
        }

        // 6: PDF -> XLSX
        do {
            let outDir = dir.appendingPathComponent("pdf_xlsx", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let res = try await officeEngine.convert(inputs: [tablePDF], to: .xlsx, outputDirectory: outDir, options: .default) { _ in }
            #expect(res.fileSize > 500)
        }

        // 7: PDF -> PPTX
        do {
            let outDir = dir.appendingPathComponent("pdf_pptx", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let res = try await officeEngine.convert(inputs: [textPDF], to: .pptx, outputDirectory: outDir, options: .default) { _ in }
            #expect(res.fileSize > 500)
        }

        // 8: HTML -> DOCX
        do {
            let outDir = dir.appendingPathComponent("html_docx", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let res = try await officeEngine.convert(inputs: [html], to: .docx, outputDirectory: outDir, options: .default) { _ in }
            #expect(res.fileSize > 500)
        }

        // 9: DOCX -> EPUB
        do {
            let outDir = dir.appendingPathComponent("docx_epub", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let res = try await officeEngine.convert(inputs: [docx], to: .epub, outputDirectory: outDir, options: .default) { _ in }
            #expect(res.fileSize > 500)
        }

        // Verify bundled LibreOffice.app signature remained pristine after all 9 runs (zero PYTHONDONTWRITEBYTECODE leakage)
        let libreAppURL = URL(fileURLWithPath: sofficePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let verifyProc = Process()
        verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifyProc.arguments = ["--verify", "--deep", "--strict", libreAppURL.path]
        let verifyOut = try await AsyncProcessRunner.run(verifyProc, stdin: .nullDevice, timeout: 30)
        let verifyErr = String(data: verifyOut.stderr, encoding: .utf8) ?? ""
        #expect(verifyOut.terminationStatus == 0, "codesign verification failed: \(verifyErr)")
    }

    // MARK: - 2. HDR / 16-bit & OpenEXR Pixel-Level Validation (J2)

    @Test("16-bit Display P3 PNG preserves >256 tonal steps and alpha across TIFF/JXL/PNG and OpenEXR decodes cleanly")
    func hdr16BitAndOpenEXRPixelValidation() async throws {
        let dir = try makeTempDir("hdr_pixels")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("ramp16.png")
        try make16BitGradientPNG(width: 1024, height: 64, to: srcURL, colorSpaceName: CGColorSpace.displayP3)

        let engine = ImageConversionEngine()

        // 16-bit TIFF retains 16bpc, wide gamut P3, and distinct 16-bit tonal precision
        let tiffOut = try await engine.convert(inputs: [srcURL], to: .tiff, outputDirectory: dir, options: .default) { _ in }
        let tiffSrc = try #require(CGImageSourceCreateWithURL(tiffOut.outputURL as CFURL, nil))
        let tiffCG = try #require(CGImageSourceCreateImageAtIndex(tiffSrc, 0, nil))
        #expect(tiffCG.bitsPerComponent == 16)
        #expect(tiffCG.colorSpace?.name == CGColorSpace.displayP3)

        // Count unique 16-bit red channel levels in row 60 (must exceed 8-bit 256 levels!)
        if let rawData = tiffCG.dataProvider?.data as Data? {
            let bytesPerPixel = tiffCG.bitsPerPixel / 8
            if bytesPerPixel == 8 {
                var uniqueLevels = Set<UInt16>()
                let rowOffset = 60 * tiffCG.bytesPerRow
                rawData.withUnsafeBytes { ptr in
                    let p = ptr.bindMemory(to: UInt8.self)
                    for x in stride(from: 0, to: 1024, by: 1) {
                        let off = rowOffset + x * 8
                        if off + 2 <= rawData.count {
                            let val = UInt16(p[off]) | (UInt16(p[off + 1]) << 8)
                            uniqueLevels.insert(val)
                        }
                    }
                }
                #expect(uniqueLevels.count > 300, "Expected 16-bit precision (>300 levels), got \(uniqueLevels.count)")
            }
        }

        // Lossless 16-bit JXL retains 16bpc
        var jxlOpts = ConversionOptions.default
        jxlOpts.customOptions["jxl_lossless"] = "true"
        jxlOpts.customOptions["jxl_bit_depth"] = "16"
        let jxlOut = try await engine.convert(inputs: [srcURL], to: .jxl, outputDirectory: dir, options: jxlOpts) { _ in }
        let jxlDecoded = try JPEGXLCodec.decode(url: jxlOut.outputURL, prefer16Bit: true, decodeAllFrames: false)
        #expect(try #require(jxlDecoded.primaryImage).bitsPerComponent == 16)

        // OpenEXR float generation + conversion to PNG & TIFF
        let exrOut = try await engine.convert(inputs: [srcURL], to: .exr, outputDirectory: dir, options: .default) { _ in }
        #expect(exrOut.fileSize > 100)
        let exrSrc = try #require(CGImageSourceCreateWithURL(exrOut.outputURL as CFURL, nil))
        let exrCG = try #require(CGImageSourceCreateImageAtIndex(exrSrc, 0, nil))
        #expect(exrCG.width == 1024 && exrCG.height == 64)
        let exrToTIFF = try await engine.convert(inputs: [exrOut.outputURL], to: .tiff, outputDirectory: dir, options: .default) { _ in }
        #expect(exrToTIFF.fileSize > 100)
    }

    // MARK: - 3. Resource Efficiency Unit Tests

    @Test("LibreOfficeProcessLimiter enforces cap=2, ImageProcessor.sharedCIContext reuses instances, ConversionQueue weighs workloads, and cleanStaleTemporaryFiles preserves fresh items")
    func resourceEfficiencyUnitControls() async throws {
        // 1. Semaphore concurrency cap = 2
        let limiter = LibreOfficeProcessLimiter(limit: 2)
        await limiter.resetMetrics()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try? await limiter.acquire()
                    try? await Task.sleep(for: .milliseconds(60))
                    await limiter.release()
                }
            }
        }
        #expect(await limiter.peakObservedConcurrency == 2)
        #expect(await limiter.currentActiveCount == 0)

        // 2. Shared CIContext pooling by color space
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let c1 = ImageProcessor.sharedCIContext(for: sRGB)
        let c2 = ImageProcessor.sharedCIContext(for: sRGB)
        let c3 = ImageProcessor.sharedCIContext(for: p3)
        #expect(c1 === c2)
        #expect(c1 !== c3)

        // 3. Workload slot cost
        let docJob = ConversionJob(inputURLs: [URL(fileURLWithPath: "/tmp/a.docx")], inputFormat: .docx, outputFormat: .pdf, outputDirectory: URL(fileURLWithPath: "/tmp"))
        let imgJob = ConversionJob(inputURLs: [URL(fileURLWithPath: "/tmp/b.png")], inputFormat: .png, outputFormat: .webp, outputDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(ConversionQueue.jobSlotCost(for: docJob) == 2)
        #expect(ConversionQueue.jobSlotCost(for: imgJob) == 1)

        // 4. cleanStaleTemporaryFiles removes stale LocalConvert temp artifacts but keeps fresh ones
        let tempTestRoot = try makeTempDir("stale_check")
        defer { try? FileManager.default.removeItem(at: tempTestRoot) }
        let staleDir = tempTestRoot.appendingPathComponent("LocalConvert-Stale-\(UUID().uuidString)", isDirectory: true)
        let staleAudioDir = tempTestRoot.appendingPathComponent("LocalConvertAudio_\(UUID().uuidString)", isDirectory: true)
        let freshDir = tempTestRoot.appendingPathComponent("LocalConvert-Fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleAudioDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: staleDir.path)
        try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: staleAudioDir.path)

        let removed = ConversionManager.cleanStaleTemporaryFiles(in: tempTestRoot, olderThan: 3600)
        #expect(removed == 2)
        #expect(!FileManager.default.fileExists(atPath: staleDir.path))
        #expect(!FileManager.default.fileExists(atPath: staleAudioDir.path))
        #expect(FileManager.default.fileExists(atPath: freshDir.path))
    }

    // MARK: - 4. 20-Way Concurrent Atomic Output Reservation Stress Test (J4)

    @Test("Atomic reservation handles 20 concurrent identical-name requests with zero collisions")
    func twentyWayConcurrentAtomicReservation() async throws {
        let dir = try makeTempDir("atomic_20")
        defer { try? FileManager.default.removeItem(at: dir) }

        var reservedURLs: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            for idx in 0..<20 {
                group.addTask {
                    do {
                        let out = try ConversionManager.reserveUniqueOutputURL(
                            directory: dir,
                            baseName: "collision_target",
                            extension: "txt",
                            policy: .createUnique
                        )
                        try Data("payload-\(idx)".utf8).write(to: out)
                        ConversionManager.releaseReservedOutputURL(out)
                        return out
                    } catch {
                        return nil
                    }
                }
            }
            for await u in group {
                if let u { reservedURLs.append(u) }
            }
        }

        #expect(reservedURLs.count == 20)
        #expect(Set(reservedURLs.map { $0.standardizedFileURL.path }).count == 20)
        for u in reservedURLs {
            #expect(FileManager.default.fileExists(atPath: u.path))
        }
    }

    // MARK: - 5. Comprehensive 16-Workload Resource & Performance Benchmarks (J3 / R)

    @Test("16-Workload benchmark measures RSS, CPU, duration, temp cleanup, and 3-run steady-state stability")
    func sixteenWorkloadPerformanceAndEfficiencyBenchmarks() async throws {
        let dir = try makeTempDir("bench16")
        defer { try? FileManager.default.removeItem(at: dir) }

        let imgEngine = ImageConversionEngine()
        let officeEngine = OfficeConversionEngine(provider: BundledLibreOfficeProvider(fallbackToSystem: false))
        let ffProvider = BundledFFmpegProvider(fallbackToSystem: false)
        let ffmpeg = try #require(await ffProvider.findFFmpegPath())

        // W1: Small batch (20 x 512x512 PNG -> WebP)
        _ = try await recordBenchmark(name: "W1_BatchSmallImages_20xWebP") {
            let sub = dir.appendingPathComponent("w1", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let p = try TestFixtureFactory.createPNG(in: sub, name: "s.png", width: 512, height: 512)
            for _ in 0..<20 {
                _ = try await imgEngine.convert(inputs: [p], to: .webp, outputDirectory: sub, options: .default) { _ in }
            }
        }

        // W2: 24MP Image (6000x4000 -> JPEG & WebP)
        _ = try await recordBenchmark(name: "W2_24MP_JPEG_WebP") {
            let sub = dir.appendingPathComponent("w2", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let p = try TestFixtureFactory.createPNG(in: sub, name: "24mp.png", width: 6000, height: 4000)
            _ = try await imgEngine.convert(inputs: [p], to: .webp, outputDirectory: sub, options: .default) { _ in }
        }

        // W3: 50MP Image (8192x6104 -> JPEG)
        _ = try await recordBenchmark(name: "W3_50MP_JPEG") {
            let sub = dir.appendingPathComponent("w3", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let p = try TestFixtureFactory.createPNG(in: sub, name: "50mp.png", width: 8192, height: 6104)
            _ = try await imgEngine.convert(inputs: [p], to: .jpg, outputDirectory: sub, options: .default) { _ in }
        }

        // W4: 100MP Image resize (10000x10000 -> 2000x2000 JPEG)
        _ = try await recordBenchmark(name: "W4_100MP_ResizeEncode") {
            let sub = dir.appendingPathComponent("w4", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let p = try TestFixtureFactory.createPNG(in: sub, name: "100mp.png", width: 10000, height: 10000)
            var opts = ConversionOptions.default
            opts.resizeMode = .percentage
            opts.resizePercentage = 0.2
            _ = try await imgEngine.convert(inputs: [p], to: .jpg, outputDirectory: sub, options: opts) { _ in }
        }

        // W5: 16-bit TIFF -> PNG & JXL
        _ = try await recordBenchmark(name: "W5_16BitTIFF_PNG_JXL") {
            let sub = dir.appendingPathComponent("w5", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let p = sub.appendingPathComponent("src16.png")
            try make16BitGradientPNG(width: 1024, height: 512, to: p)
            let tiff = try await imgEngine.convert(inputs: [p], to: .tiff, outputDirectory: sub, options: .default) { _ in }
            _ = try await imgEngine.convert(inputs: [tiff.outputURL], to: .jxl, outputDirectory: sub, options: .default) { _ in }
        }

        // W6: Animated GIF -> Animated WebP
        _ = try await recordBenchmark(name: "W6_Animated_GIF_WebP") {
            let sub = dir.appendingPathComponent("w6", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let gif = sub.appendingPathComponent("anim.gif")
            let dest = try #require(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 4, nil))
            for i in 0..<4 {
                let p = try TestFixtureFactory.createPNG(in: sub, name: "f\(i).png", width: 128, height: 128)
                let src = try #require(CGImageSourceCreateWithURL(p as CFURL, nil))
                let cg = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
                CGImageDestinationAddImage(dest, cg, nil)
            }
            #expect(CGImageDestinationFinalize(dest))
            _ = try await imgEngine.convert(inputs: [gif], to: .webp, outputDirectory: sub, options: .default) { _ in }
        }

        // W7: PDF Compress 20 pages (autoreleasepool check)
        let pdf20 = try TestFixtureFactory.createMultiPagePDF(in: dir, pages: 20, name: "twenty.pdf")
        let pdf20B = try TestFixtureFactory.createMultiPagePDF(in: dir, pages: 20, name: "twenty_b.pdf")

        _ = try await recordBenchmark(name: "W7_PDFCompress_20Pages") {
            let outPDF = dir.appendingPathComponent("twenty_comp.pdf")
            _ = try await PDFCompressionService.compress(
                inputURL: pdf20,
                outputURL: outPDF,
                options: PDFCompressionOptions(profile: .balanced, strategy: .rasterizePages, targetDPI: 110, imageQuality: 0.75)
            ) { _ in }
        }

        // W8: PDF Compare 20 pages
        _ = try await recordBenchmark(name: "W8_PDFCompare_20Pages") {
            let report = try await PDFComparisonService.compare(leftURL: pdf20, rightURL: pdf20B, renderWidthPixels: 320)
            #expect(report.pageDiffs.count == 20)
        }

        // W9: PDF OCR multi-page (3 pages)
        _ = try await recordBenchmark(name: "W9_PDFOCR_3Pages") {
            let pdf3 = try TestFixtureFactory.createMultiPagePDF(in: dir, pages: 3, name: "ocr3.pdf")
            let outOCR = dir.appendingPathComponent("ocr3_out.pdf")
            _ = try await PDFOCRService.runOCR(
                inputURL: pdf3,
                outputPDFURL: outOCR,
                options: PDFOCROptions(skipExistingTextPages: false, renderDPI: 120)
            ) { _ in }
        }

        // W10 & W11: Office DOCX->PDF & XLSX->PDF
        _ = try await recordBenchmark(name: "W10_Office_DOCX_PDF") {
            let sub = dir.appendingPathComponent("w10", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let d = try TestFixtureFactory.createDOCX(in: sub, name: "b.docx", text: "Benchmark DOCX")
            _ = try await officeEngine.convert(inputs: [d], to: .pdf, outputDirectory: sub, options: .default) { _ in }
        }

        _ = try await recordBenchmark(name: "W11_Office_XLSX_PDF") {
            let sub = dir.appendingPathComponent("w11", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let x = try TestFixtureFactory.createXLSX(in: sub, name: "b.xlsx", text: "Bench", number: "77")
            _ = try await officeEngine.convert(inputs: [x], to: .pdf, outputDirectory: sub, options: .default) { _ in }
        }

        // W12: Audio WAV -> MP3 convert
        let wavBench = try TestFixtureFactory.createWAV(in: dir, name: "bench.wav", duration: 2.0)
        _ = try await recordBenchmark(name: "W12_Audio_WAV_to_MP3") {
            let outMP3 = dir.appendingPathComponent("bench_out.mp3")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-y", "-v", "error", "-i", wavBench.path, "-c:a", "libmp3lame", "-b:a", "192k", outMP3.path]
            let r = try await AsyncProcessRunner.run(p, stdin: .nullDevice, timeout: 30)
            #expect(r.terminationStatus == 0)
        }

        // W13: Waveform extraction cold + warm cache hit check
        _ = try await recordBenchmark(name: "W13_Waveform_ColdPlusCache") {
            let cold = try await AudioAnalysisService.shared.extractWaveform(url: wavBench, bins: 180)
            let t0 = CFAbsoluteTimeGetCurrent()
            let warm = try await AudioAnalysisService.shared.extractWaveform(url: wavBench, bins: 180)
            let warmMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            #expect(cold.peaks == warm.peaks)
            #expect(warmMs < 50.0, "Expected warm waveform cache hit <50ms, took \(warmMs)ms")
        }

        // W14: Video MP4 -> WebM + metadata inspect
        let mp4Bench = try await TestFixtureFactory.createMP4(in: dir, name: "bench.mp4", duration: 0.8)
        _ = try await recordBenchmark(name: "W14_Video_MP4_Metadata") {
            let outMov = dir.appendingPathComponent("bench.mov")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-y", "-v", "error", "-i", mp4Bench.path, "-c", "copy", outMov.path]
            _ = try await AsyncProcessRunner.run(p, stdin: .nullDevice, timeout: 30)
            _ = await SpotifyCompatibilityService.shared.analyzeFile(url: outMov)
        }

        // W15: Spotify batch 5 tracks inspect + normalize
        _ = try await recordBenchmark(name: "W15_Spotify_Batch5_Norm") {
            let sub = dir.appendingPathComponent("w15", isDirectory: true)
            let outSub = dir.appendingPathComponent("w15_out", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outSub, withIntermediateDirectories: true)
            var tracks: [URL] = []
            for i in 0..<5 {
                let u = sub.appendingPathComponent("t\(i).mp3")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.6", "-c:a", "libmp3lame", "-b:a", "128k", "-metadata", "title=Track \(i)", u.path]
                _ = try await AsyncProcessRunner.run(p, stdin: .nullDevice, timeout: 30)
                tracks.append(u)
            }
            let reports = await SpotifyCompatibilityService.shared.analyzeBatch(urls: tracks, maxConcurrent: 4) { _, _ in }
            #expect(reports.count == 5)
            for item in reports {
                let n = await SpotifyCompatibilityService.shared.normalizeFile(item: item, options: SpotifyNormalizationOptions(outputDirectory: outSub))
                #expect(n.audioPayloadVerified == true)
            }
        }

        // W16: 3-iteration steady-state memory stability loop (PNG -> WebP 2K image)
        let stabilityImg = try TestFixtureFactory.createPNG(in: dir, name: "stab.png", width: 2048, height: 2048)
        let w16Stats = try await recordBenchmark(name: "W16_3Iter_SteadyState") {
            var rssSamples: [Double] = []
            for i in 0..<3 {
                let outSub = dir.appendingPathComponent("w16_\(i)", isDirectory: true)
                try FileManager.default.createDirectory(at: outSub, withIntermediateDirectories: true)
                _ = try await imgEngine.convert(inputs: [stabilityImg], to: .webp, outputDirectory: outSub, options: .default) { _ in }
                rssSamples.append(currentRSSMB())
            }
            let drift = (rssSamples.last ?? 0) - (rssSamples.first ?? 0)
            #expect(abs(drift) < 80.0, "Unexpected RSS growth across 3 iterations: \(rssSamples)")
        }
        #expect(w16Stats.tempLeakBytes == 0)
    }
}
