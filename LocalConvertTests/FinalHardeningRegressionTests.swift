import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import AppKit
@testable import LocalConvert

@Suite("Final Hardening — Stage 2 Regression Tests")
struct FinalHardeningRegressionTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinalHardening-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func decodeFirstRGBA(_ data: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = img.width
        let h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, buf)
    }

    // MARK: - 1. WebP Pixel Layouts & Guards

    @Test("WebPEncoder handles RGB24 padded stride, premultiplied & straight alpha, Grayscale, and Display P3")
    func webpPixelLayoutRoundTrips() throws {
        let encoder = WebPEncoder()
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))

        // 1A. RGB24 with non-default bytesPerRow padding (e.g., 16x16 * 3 = 48 bytes -> padded to 64 bytes/row)
        let w = 16
        let h = 16
        let paddedStride = 64
        var rgb24 = [UInt8](repeating: 0xAA, count: paddedStride * h)
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * paddedStride + x * 3
                rgb24[offset + 0] = 42
                rgb24[offset + 1] = 155
                rgb24[offset + 2] = 210
            }
        }
        let rgb24Data = Data(rgb24)
        let provider24 = try #require(CGDataProvider(data: rgb24Data as CFData))
        let img24 = try #require(CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: paddedStride,
            space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider24,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let webp24 = try encoder.encode(image: img24, mode: .lossless)
        let dec24 = try decodeFirstRGBA(webp24)
        #expect(dec24.width == w && dec24.height == h)
        #expect(dec24.rgba[0] == 42 && dec24.rgba[1] == 155 && dec24.rgba[2] == 210 && dec24.rgba[3] == 255)

        // 1B. Premultiplied RGBA32 partial alpha (R=50, G=80, B=20 premultiplied at A=128)
        var rgbaPremul = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: rgbaPremul.count, by: 4) {
            rgbaPremul[i + 0] = 50
            rgbaPremul[i + 1] = 80
            rgbaPremul[i + 2] = 20
            rgbaPremul[i + 3] = 128
        }
        let provPremul = try #require(CGDataProvider(data: Data(rgbaPremul) as CFData))
        let imgPremul = try #require(CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provPremul,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let webpPremul = try encoder.encode(image: imgPremul, mode: .lossless)
        let decPremul = try decodeFirstRGBA(webpPremul)
        // ImageIO draws back premultiplied RGBA; allow <= 2 LSB for unpremul/repremul rounding
        #expect(abs(Int(decPremul.rgba[0]) - 50) <= 2)
        #expect(abs(Int(decPremul.rgba[1]) - 80) <= 2)
        #expect(abs(Int(decPremul.rgba[2]) - 20) <= 2)
        #expect(decPremul.rgba[3] == 128)

        // 1C. Straight (non-premultiplied) RGBA32 partial alpha (R=100, G=160, B=40, A=128)
        var rgbaStraight = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: rgbaStraight.count, by: 4) {
            rgbaStraight[i + 0] = 100
            rgbaStraight[i + 1] = 160
            rgbaStraight[i + 2] = 40
            rgbaStraight[i + 3] = 128
        }
        let provStraight = try #require(CGDataProvider(data: Data(rgbaStraight) as CFData))
        let imgStraight = try #require(CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provStraight,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let webpStraight = try encoder.encode(image: imgStraight, mode: .lossless)
        let decStraight = try decodeFirstRGBA(webpStraight)
        #expect(abs(Int(decStraight.rgba[0]) - 50) <= 2)
        #expect(abs(Int(decStraight.rgba[1]) - 80) <= 2)
        #expect(abs(Int(decStraight.rgba[2]) - 20) <= 2)
        #expect(decStraight.rgba[3] == 128)

        // 1D. Grayscale 8-bit fallback conversion
        let graySpace = CGColorSpaceCreateDeviceGray()
        let grayCtx = try #require(CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        grayCtx.setFillColor(gray: 0.5, alpha: 1.0)
        grayCtx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let grayImg = try #require(grayCtx.makeImage())
        let webpGray = try encoder.encode(image: grayImg, mode: .lossless)
        let decGray = try decodeFirstRGBA(webpGray)
        #expect(abs(Int(decGray.rgba[0]) - Int(decGray.rgba[1])) <= 2)
        #expect(abs(Int(decGray.rgba[1]) - Int(decGray.rgba[2])) <= 2)
        #expect(decGray.rgba[3] == 255)

        // 1E. Display P3 ICC muxing
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let p3ICC = try #require(p3.copyICCData() as Data?)
        let webpP3 = try encoder.encode(image: img24, mode: .lossless, iccProfile: p3ICC)
        #expect(WebPEncoder.validate(webpP3))
        let p3Src = try #require(CGImageSourceCreateWithData(webpP3 as CFData, nil))
        let p3Img = try #require(CGImageSourceCreateImageAtIndex(p3Src, 0, nil))
        #expect((p3Img.colorSpace?.copyICCData() as Data?) == p3ICC)
    }

    // MARK: - 2. JPEG XL Custom ICC Color Space Guard

    @Test("JPEGXLCodec handles custom ICC CGColorSpace (name == nil) without color space misidentification")
    func jpegXLCustomICCProfileRoundTrip() throws {
        var wp: [CGFloat] = [0.95047, 1.0, 1.08883]
        var bp: [CGFloat] = [0, 0, 0]
        var gamma: [CGFloat] = [2.2, 2.2, 2.2]
        var matrix: [CGFloat] = [
            0.4124, 0.2126, 0.0193,
            0.3576, 0.7152, 0.1192,
            0.1805, 0.0722, 0.9505
        ]
        let customSpace = try #require(CGColorSpace(
            calibratedRGBWhitePoint: &wp,
            blackPoint: &bp,
            gamma: &gamma,
            matrix: &matrix
        ))
        #expect(customSpace.name == nil)

        let w = 24
        let h = 24
        let ctx = try #require(CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: customSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        ctx.setFillColor(red: 0.9, green: 0.25, blue: 0.15, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = try #require(ctx.makeImage())

        let jxlData = try JPEGXLCodec.encode(
            image: img,
            options: JXLEncodeOptions(lossless: true, useContainer: false)
        )
        let dir = try makeTempDir("jxl_custom_icc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("custom.jxl")
        try jxlData.write(to: outURL)

        let decoded = try JPEGXLCodec.decode(url: outURL, prefer16Bit: false, decodeAllFrames: false)
        let firstFrame = try #require(decoded.frames.first)
        #expect(firstFrame.image.width == w && firstFrame.image.height == h)
    }

    // MARK: - 3. ConversionQueue Pending Visibility, Cancellation & Pixel Slot Cost

    @MainActor
    @Test("ConversionQueue exposes pending jobs, cancels queued jobs cleanly, and weights >=36MP images")
    func queuePendingCancelAndSlotCost() async throws {
        let dir = try makeTempDir("queue_lifecycle")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Large >= 36 MP image file header check (7200 x 5400 = 38.88 MP)
        let bigURL = dir.appendingPathComponent("big_39mp.png")
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bigCtx = try #require(CGContext(
            data: nil,
            width: 7200,
            height: 5400,
            bitsPerComponent: 8,
            bytesPerRow: 7200 * 4,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bigImg = try #require(bigCtx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(bigURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, bigImg, nil)
        #expect(CGImageDestinationFinalize(dest))

        let bigJob = ConversionJob(inputURLs: [bigURL], inputFormat: .png, outputFormat: .jpg, outputDirectory: dir)
        #expect(ConversionQueue.jobSlotCost(for: bigJob) == 2)

        // Pending job visibility & individual pending cancellation
        let smallImgURL = try TestFixtureFactory.createPNG(in: dir, name: "small.png", width: 256, height: 256)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let previousConcurrency = AppSettings.shared.concurrentConversions
        AppSettings.shared.concurrentConversions = .one
        defer { AppSettings.shared.concurrentConversions = previousConcurrency }

        let manager = ConversionManager(registry: .shared)
        let queue = ConversionQueue(conversionManager: manager)

        var startedCount = 0
        var completedCountCallbacks = 0
        queue.onQueueStarted = { startedCount += 1 }
        queue.onQueueCompleted = { completedCountCallbacks += 1 }

        let pdfSrc = dir.appendingPathComponent("src.pdf")
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        #expect(pdfDoc.write(to: pdfSrc))

        let j1 = ConversionJob(inputURLs: [pdfSrc], inputFormat: .pdf, outputFormat: .png, outputDirectory: outDir)
        let j2 = ConversionJob(inputURLs: [smallImgURL], inputFormat: .png, outputFormat: .jpg, outputDirectory: outDir)
        let j3 = ConversionJob(inputURLs: [smallImgURL], inputFormat: .png, outputFormat: .webp, outputDirectory: outDir)

        queue.enqueue(jobs: [j1, j2, j3])
        #expect(startedCount == 1)
        // Overflow jobs j2 & j3 must be immediately registered in manager.activeJobs
        #expect(manager.activeJobs.contains(where: { $0.id == j2.id }))
        #expect(manager.activeJobs.contains(where: { $0.id == j3.id }))

        if queue.pendingJobs.contains(where: { $0.id == j3.id }) {
            manager.cancel(jobId: j3.id)
            #expect(!queue.pendingJobs.contains(where: { $0.id == j3.id }))
            #expect(manager.status(for: j3.id) == .cancelled)
        }

        var polls = 0
        while queue.isProcessing && polls < 120 {
            try await Task.sleep(for: .milliseconds(50))
            polls += 1
        }

        #expect(completedCountCallbacks == 1)
        #expect(queue.completedCount + queue.cancelledCount + queue.failedCount == 3)
        #expect(queue.failedCount == 0)

        // Pre-cancelled AsyncProcessRunner throws ConversionError.cancelled (not failed)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let cancelTask = Task {
            try await AsyncProcessRunner.run(proc, timeout: 10)
        }
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
        } catch let convErr as ConversionError {
            #expect(convErr == .cancelled)
        } catch is CancellationError {
            // Acceptable if Task cancellation happened before entering AsyncProcessRunner
        }
    }

    // MARK: - 4. Archive >64 KB Encrypted ZIP Detection & Traversal Guards

    @Test("ArchiveConversionEngine detects encrypted ZIP headers past 64 KB")
    func archiveDetectsEncryptedZipBeyond64KB() async throws {
        let dir = try makeTempDir("zip_64kb_enc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let largeURL = dir.appendingPathComponent("payload.bin")
        let encSourceURL = dir.appendingPathComponent("secret.txt")
        let randomData = Data((0..<80_000).map { UInt8($0 & 0xFF) })
        try randomData.write(to: largeURL)
        try Data("Secret".utf8).write(to: encSourceURL)

        let zipURL = dir.appendingPathComponent("large_mixed.zip")
        // Build unencrypted >80KB stored zip first via bsdtar, then patch GP flag on final local/CD entry if needed
        let tarProc = Process()
        tarProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        tarProc.arguments = ["-0", zipURL.path, largeURL.lastPathComponent]
        tarProc.currentDirectoryURL = dir
        let r1 = try await AsyncProcessRunner.run(tarProc, stdin: .nullDevice, timeout: 30)
        #expect(r1.terminationStatus == 0)

        // Append encrypted entry (>64KB into file)
        let zipEncProc = Process()
        zipEncProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipEncProc.arguments = ["-P", "testpass123", zipURL.path, encSourceURL.lastPathComponent]
        zipEncProc.currentDirectoryURL = dir
        let r2 = try await AsyncProcessRunner.run(zipEncProc, stdin: .nullDevice, timeout: 30)
        #expect(r2.terminationStatus == 0)

        let engine = ArchiveConversionEngine()
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        do {
            _ = try await engine.convert(inputs: [zipURL], to: .tar, outputDirectory: outDir, options: .default) { _ in }
            Issue.record("Expected encrypted >64KB ZIP conversion to fail with invalidInput")
        } catch let error as ConversionError {
            guard case .invalidInput(let message) = error else {
                Issue.record("Expected ConversionError.invalidInput, got \(error)")
                return
            }
            #expect(message.lowercased().contains("encrypted") || message.lowercased().contains("password"))
        }
    }

    // MARK: - 5. PDF OCR Sidecar, Negative Rotation, Upright MediaBox Rendering, and Office Overwrite Safety

    @Test("PDFToolboxEngine preserves dotted filename on OCR sidecar and normalizes negative rotations")
    func pdfDottedOCRAndNegativeRotation() async throws {
        let dir = try makeTempDir("pdf_hardening")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("Report.v2.pdf")
        let pageSize = CGRect(x: 0, y: 0, width: 300, height: 200)
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
            Issue.record("Failed to create CGDataConsumer")
            return
        }
        var mediaBox = pageSize
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            Issue.record("Failed to create PDF context")
            return
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(.white)
        ctx.fill(pageSize)
        ctx.setFillColor(.black)
        let attr = NSAttributedString(
            string: "INVOICE 90210",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.black]
        )
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        attr.draw(at: NSPoint(x: 30, y: 90))
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        try (pdfData as Data).write(to: pdfURL)

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let engine = PDFToolboxEngine()
        // Negative rotation normalization
        var rotOpts = ConversionOptions.default
        rotOpts.customOptions["pdf_operation"] = "rotate"
        rotOpts.customOptions["pdf_rotation"] = "-90"
        let rotRes = try await engine.convert(inputs: [pdfURL], to: .pdf, outputDirectory: outDir, options: rotOpts) { _ in }
        let rotatedDoc = try #require(PDFDocument(url: rotRes.outputURL))
        let pageRot = try #require(rotatedDoc.page(at: 0)?.rotation)
        #expect(pageRot == 270)

        // Dotted OCR sidecar filename
        let ocrConfig = PDFOCROptions(skipExistingTextPages: false, renderDPI: 144, exportExtractedTextSidecar: true)
        let jsonData = try JSONEncoder().encode(ocrConfig)
        var ocrOpts = ConversionOptions.default
        ocrOpts.customOptions["pdf_operation"] = "ocr"
        ocrOpts.customOptions["pdf_ocr_config"] = String(data: jsonData, encoding: .utf8) ?? ""
        let ocrRes = try await engine.convert(inputs: [pdfURL], to: .pdf, outputDirectory: outDir, options: ocrOpts) { _ in }
        let sidecar = try #require(ocrRes.additionalOutputURLs.first)
        #expect(sidecar.lastPathComponent == "Report.v2_ocr_text.txt")
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("PDFConversionEngine renders rotated non-zero origin mediaBox pages upright with content")
    func pdfRotatedNonZeroOriginRender() async throws {
        let dir = try makeTempDir("pdf_nonzero_origin")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("offset_rot.pdf")
        var mediaBox = CGRect(x: 50, y: 80, width: 200, height: 400)
        let pdfData = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: pdfData as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 0.1, green: 0.2, blue: 0.85, alpha: 1.0)
        ctx.fill(mediaBox)
        ctx.endPDFPage()
        ctx.closePDF()
        try (pdfData as Data).write(to: pdfURL)

        let doc = try #require(PDFDocument(url: pdfURL))
        doc.page(at: 0)?.rotation = 90
        let rotatedURL = dir.appendingPathComponent("offset_rot90.pdf")
        #expect(doc.write(to: rotatedURL))

        let engine = PDFConversionEngine()
        var opts = ConversionOptions.default
        opts.pdfDPI = 72
        let res = try await engine.convert(inputs: [rotatedURL], to: .png, outputDirectory: dir, options: opts) { _ in }
        let imgSrc = try #require(CGImageSourceCreateWithURL(res.outputURL as CFURL, nil))
        let rendered = try #require(CGImageSourceCreateImageAtIndex(imgSrc, 0, nil))
        // After 90-degree rotation, 200x400 becomes 400x200 landscape upright
        #expect(rendered.width > rendered.height)
        #expect(rendered.width == 400 && rendered.height == 200)

        let dec = try decodeFirstRGBA(try Data(contentsOf: res.outputURL))
        #expect(dec.rgba[2] > 180) // Blue fill must actually land inside viewport despite non-zero origin
    }

    @Test("OfficeConversionEngine does not overwrite existing output when validation fails")
    func officeOverwritePreservesExistingOnFailure() async throws {
        let dir = try makeTempDir("office_overwrite_guard")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Existing valid output file at destination
        let existingOut = dir.appendingPathComponent("corrupt.xlsx")
        let sentinelBytes = Data("SENTINEL-DO-NOT-DELETE".utf8)
        try sentinelBytes.write(to: existingOut)

        // Corrupt ZIP/OOXML bytes disguised as .docx converting to .xlsx
        let badInput = dir.appendingPathComponent("corrupt.docx")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]).write(to: badInput)

        var opts = ConversionOptions.default
        opts.overwriteExisting = true
        let officeEngine = OfficeConversionEngine()
        var didThrow = false
        do {
            _ = try await officeEngine.convert(inputs: [badInput], to: .xlsx, outputDirectory: dir, options: opts) { _ in }
        } catch {
            didThrow = true
        }
        #expect(didThrow)

        #expect(FileManager.default.fileExists(atPath: existingOut.path))
        #expect((try Data(contentsOf: existingOut)) == sentinelBytes)
    }

    // MARK: - 6. FFmpeg Multi-Audio Stream Copy & Subtitle Order

    @Test("BaseFFmpegProvider validates all audio streams for stream copy and orders -c copy before -c:s mov_text")
    func ffmpegMultiAudioAndSubtitleOrdering() {
        let provider = BaseFFmpegProvider()
        let vStream = MediaStreamInfo(
            index: 0, streamType: .video, codecName: "h264", codecLongName: nil, bitRate: nil,
            width: 1920, height: 1080, frameRate: 30, sampleRate: nil, channels: nil, duration: 5.0
        )
        let aacStream = MediaStreamInfo(
            index: 1, streamType: .audio, codecName: "aac", codecLongName: nil, bitRate: nil,
            width: nil, height: nil, frameRate: nil, sampleRate: 48000, channels: 2, duration: 5.0
        )
        let dtsStream = MediaStreamInfo(
            index: 2, streamType: .audio, codecName: "dts", codecLongName: nil, bitRate: nil,
            width: nil, height: nil, frameRate: nil, sampleRate: 48000, channels: 6, duration: 5.0
        )
        let mp3Stream = MediaStreamInfo(
            index: 2, streamType: .audio, codecName: "mp3", codecLongName: nil, bitRate: nil,
            width: nil, height: nil, frameRate: nil, sampleRate: 44100, channels: 2, duration: 5.0
        )
        let srtStream = MediaStreamInfo(
            index: 3, streamType: .subtitle, codecName: "subrip", codecLongName: nil, bitRate: nil,
            width: nil, height: nil, frameRate: nil, sampleRate: nil, channels: nil, duration: 5.0
        )

        let dummyIn = URL(fileURLWithPath: "/tmp/in.mkv")
        let dummyOut = URL(fileURLWithPath: "/tmp/out.mp4")

        // Mixed AAC + DTS cannot stream copy cleanly into MP4
        let incompatibleMultiAudio = MediaInfo(
            url: dummyIn, formatName: "matroska", duration: 5.0, fileSize: nil, bitRate: nil,
            streams: [vStream, aacStream, dtsStream]
        )
        #expect(provider.canStreamCopy(inputInfo: incompatibleMultiAudio, targetFormat: .mp4) == false)

        // Compatible AAC + MP3 + SRT can stream copy into MP4 with mov_text subtitle transcode AFTER -c copy
        let compatibleMultiAudio = MediaInfo(
            url: dummyIn, formatName: "matroska", duration: 5.0, fileSize: nil, bitRate: nil,
            streams: [vStream, aacStream, mp3Stream, srtStream]
        )
        #expect(provider.canStreamCopy(inputInfo: compatibleMultiAudio, targetFormat: .mp4) == true)

        let args = provider.buildFFmpegArguments(
            inputURL: dummyIn,
            outputURL: dummyOut,
            inputInfo: compatibleMultiAudio,
            outputFormat: .mp4,
            options: .default
        )

        let copyIdx = args.firstIndex(of: "-c")
        let subCodecIdx = args.firstIndex(of: "-c:s")
        #expect(copyIdx != nil && subCodecIdx != nil)
        if let copyIdx, let subCodecIdx {
            #expect(copyIdx < subCodecIdx)
            #expect(args[subCodecIdx + 1] == "mov_text")
        }
        // Must explicitly map all audio streams (0:a?)
        #expect(args.contains("0:a?"))
        #expect(args.contains("0:\(srtStream.index)"))
    }

    // MARK: - 7. Code-Review Hardening: 16-bit/Float CIFormat, 16-bit sRGB Alpha Flatten, Waveform Pre-Cancel

    @Test("16-bit sRGB alpha flatten, lanczosDetail 16-bit upscale, float HDR CIFormat, and cancelled waveform extraction behave safely")
    func codeReviewRegressionGuards() async throws {
        // 7A. 16-bit sRGB alpha flattening preserves 16-bit depth
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let byteOrder16 = CGBitmapInfo.byteOrder16Little.rawValue
        let ctx16 = try #require(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 16, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | byteOrder16
        ))
        ctx16.setFillColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 0.5)
        ctx16.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let img16 = try #require(ctx16.makeImage())
        let flattened = ImageProcessor.flattenAlphaOntoWhiteIfNeeded(img16, for: .jpg)
        #expect(flattened.bitsPerComponent == 16)

        // 7B. ImageUpscaleService lanczosDetail preserves 16-bit depth
        var upscaleCfg = ImageUpscaleConfig()
        upscaleCfg.enabled = true
        upscaleCfg.scaleFactor = 2.0
        upscaleCfg.method = .lanczosDetail
        upscaleCfg.detailEnhancement = 0.5
        let upOut = try ImageUpscaleService.upscale(cgImage: img16, config: upscaleCfg)
        #expect(upOut.cgImage.width == 64 && upOut.cgImage.height == 64)
        #expect(upOut.cgImage.bitsPerComponent == 16)

        // 7C. Float HDR CGImage selects .RGBAh (preserves values > 1.0 instead of clamping to .RGBA16)
        let extLinear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let floatCtx = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 32, bytesPerRow: 0,
            space: extLinear, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        let floatImg = try #require(floatCtx.makeImage())
        #expect(ImageProcessor.ciRenderFormat(for: floatImg) == .RGBAh)

        // 7D. Cancelled AudioAnalysisService waveform extraction returns promptly without hanging
        let dir = try makeTempDir("wave_cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wavURL = try TestFixtureFactory.createWAV(in: dir, name: "cancel.wav", duration: 1.0)
        let waveTask = Task {
            try await AudioAnalysisService.shared.extractWaveform(url: wavURL, bins: 64)
        }
        waveTask.cancel()
        do {
            _ = try await waveTask.value
        } catch {
            // Cancelled or error cleanly returned without hang
        }
    }

    // MARK: - 8. WebP Cooperative Cancel Hook, Owned-Buffer Release Parity & VoiceOver Announcements

    @Test("WebP encoding cancels mid-flight via progress hook without leftovers, preserves alpha/ICC parity, and AccessibilityAnnouncer records error/batch events")
    @MainActor
    func webpCancelParityAndAccessibilityAnnouncements() async throws {
        let dir = try makeTempDir("webp_cancel_parity")
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 8A. Alpha + Display P3 parity after freePixelsAfterImport transfer
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let srcURL = dir.appendingPathComponent("alpha_p3.png")
        let ctx = try #require(CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        ctx.setFillColor(CGColor(colorSpace: p3, components: [0.85, 0.25, 0.15, 0.65])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let img = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(srcURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))

        let engine = ImageConversionEngine()
        let res = try await engine.convert(inputs: [srcURL], to: .webp, outputDirectory: outDir, options: .default) { _ in }
        let outData = try Data(contentsOf: res.outputURL)
        #expect(WebPEncoder.validate(outData))
        #expect(WebPEncoder.hasAlpha(outData))

        // 8B. Cooperative mid-encode WebP progress_hook cancellation leaves zero output files
        let bigURL = dir.appendingPathComponent("large_cancel.png")
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let bigCtx = try #require(CGContext(
            data: nil, width: 3200, height: 2400, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        if let rawPtr = bigCtx.data {
            let bytes = bigCtx.bytesPerRow * 2400
            let u = rawPtr.assumingMemoryBound(to: UInt8.self)
            for idx in stride(from: 0, to: bytes, by: 4) {
                u[idx] = UInt8((idx * 31) & 0xFF)
                u[idx + 1] = UInt8((idx * 17) & 0xFF)
                u[idx + 2] = UInt8((idx * 13) & 0xFF)
                u[idx + 3] = 255
            }
        }
        let bigImg = try #require(bigCtx.makeImage())
        let bigDest = try #require(CGImageDestinationCreateWithURL(bigURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(bigDest, bigImg, nil)
        #expect(CGImageDestinationFinalize(bigDest))

        let cancelSubDir = dir.appendingPathComponent("cancel_out", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelSubDir, withIntermediateDirectories: true)
        let webpCancelTask = Task {
            try await engine.convert(inputs: [bigURL], to: .webp, outputDirectory: cancelSubDir, options: .default) { _ in }
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        webpCancelTask.cancel()
        do {
            _ = try await webpCancelTask.value
        } catch let convErr as ConversionError {
            #expect(convErr == .cancelled)
        } catch is CancellationError {
            // Expected cancellation path
        }
        let leftovers = try FileManager.default.contentsOfDirectory(at: cancelSubDir, includingPropertiesForKeys: nil)
        #expect(leftovers.isEmpty)

        // 8C. AccessibilityAnnouncer records error & batch completion messages
        let state = AppState()
        state.showError(message: "Disk full", details: nil)
        #expect(AccessibilityAnnouncer.recentAnnouncements.contains(where: { $0.contains("Error: Disk full") }))
        AppNotificationManager.shared.notifyBatchCompleted(total: 3, completed: 2, failed: 1, cancelled: 0)
        #expect(AccessibilityAnnouncer.recentAnnouncements.contains(where: { $0.contains("2 succeeded, 1 failed") }))
    }
}
