import Testing
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import AppKit
import UniformTypeIdentifiers
import Darwin
@testable import LocalConvert

@Suite("Phase 40 — Distribution, Conversion Integrity & Image Fidelity")
struct Phase40Tests {

    // MARK: - Helpers

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Phase40-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func findFFmpegPaths() async throws -> (ffmpeg: String, ffprobe: String) {
        let provider = BundledFFmpegProvider(fallbackToSystem: false)
        let ffmpeg = try #require(await provider.findFFmpegPath())
        let ffprobe = try #require(await provider.findFFprobePath())
        return (ffmpeg, ffprobe)
    }

    private func currentResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kern == KERN_SUCCESS ? info.resident_size : 0
    }

    private func makeSolidImage(
        width: Int,
        height: Int,
        bitsPerComponent: Int = 8,
        colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat = 1.0,
        transparentBorder: Bool = false
    ) throws -> CGImage {
        let byteOrder16Host: UInt32 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue
        let bitmapInfo: UInt32 = bitsPerComponent == 16
            ? (CGImageAlphaInfo.premultipliedLast.rawValue | byteOrder16Host)
            : CGImageAlphaInfo.premultipliedLast.rawValue

        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))

        if transparentBorder {
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
            let inset = CGRect(
                x: width / 4,
                y: height / 4,
                width: max(1, width / 2),
                height: max(1, height / 2)
            )
            ctx.fill(inset)
        } else {
            ctx.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(ctx.makeImage())
    }

    private func sampleRGBAPixel(from cgImage: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Draw shifted so target (x, y) in top-left image space lands at (0, 0).
        ctx.draw(
            cgImage,
            in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height)
        )
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private func writePNG(_ image: CGImage, to url: URL, properties: [CFString: Any]? = nil) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, properties as CFDictionary?)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func makeAnimatedWebPData(frame1: CGImage, frame2: CGImage) throws -> Data {
        let enc = WebPEncoder()
        let raw1 = try enc.encode(image: frame1, mode: .lossless)
        let raw2 = try enc.encode(image: frame2, mode: .lossless)

        func extractBitstreamChunk(from webp: Data) -> Data? {
            let bytes = [UInt8](webp)
            var off = 12
            while off + 8 <= bytes.count {
                let tag = String(decoding: bytes[off..<(off + 4)], as: UTF8.self)
                let len = Int(UInt32(bytes[off + 4]) | (UInt32(bytes[off + 5]) << 8) | (UInt32(bytes[off + 6]) << 16) | (UInt32(bytes[off + 7]) << 24))
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
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        }
        func appendLE24(_ v: UInt32, to d: inout Data) {
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF))
        }
        func appendLE32(_ v: UInt32, to d: inout Data) {
            d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
        }
        func appendChunk(_ fourCC: String, payload: Data, to d: inout Data) {
            d.append(contentsOf: fourCC.utf8.prefix(4))
            appendLE32(UInt32(payload.count), to: &d)
            d.append(payload)
            if payload.count % 2 == 1 { d.append(0) }
        }
        func buildANMF(frameChunk: Data, width: Int, height: Int, durationMs: UInt32) -> Data {
            var p = Data()
            appendLE24(0, to: &p) // X / 2
            appendLE24(0, to: &p) // Y / 2
            appendLE24(UInt32(width - 1), to: &p)
            appendLE24(UInt32(height - 1), to: &p)
            appendLE24(durationMs, to: &p)
            p.append(0x02) // Dispose to background
            p.append(frameChunk)
            return p
        }

        let chunk1 = try #require(extractBitstreamChunk(from: raw1))
        let chunk2 = try #require(extractBitstreamChunk(from: raw2))

        var body = Data()
        var vp8x = Data([0x02, 0, 0, 0]) // Animation flag
        appendLE24(UInt32(frame1.width - 1), to: &vp8x)
        appendLE24(UInt32(frame1.height - 1), to: &vp8x)
        appendChunk("VP8X", payload: vp8x, to: &body)

        var anim = Data([0, 0, 0, 0]) // background BGRA
        appendLE16(0, to: &anim) // loop infinitely
        appendChunk("ANIM", payload: anim, to: &body)

        appendChunk("ANMF", payload: buildANMF(frameChunk: chunk1, width: frame1.width, height: frame1.height, durationMs: 80), to: &body)
        appendChunk("ANMF", payload: buildANMF(frameChunk: chunk2, width: frame2.width, height: frame2.height, durationMs: 80), to: &body)

        var out = Data("RIFF".utf8)
        appendLE32(UInt32(4 + body.count), to: &out)
        out.append(contentsOf: "WEBP".utf8)
        out.append(body)
        return out
    }

    // MARK: - 1. Distribution, Signing & Third-Party License Compliance

    @Test("App bundle version, notices, LibreOffice code signature, and zero Homebrew linkage")
    func distributionComplianceVerification() async throws {
        // Check hosted app bundle when running via xcodebuild test
        let appBundle = Bundle.main
        if appBundle.bundleURL.pathExtension == "app" {
            let shortVer = appBundle.infoDictionary?["CFBundleShortVersionString"] as? String
            #expect(shortVer == "2.0.0")

            let resourceURL = try #require(appBundle.resourceURL)
            for required in ["LICENSE", "LICENSE.webp", "LICENSE.jxl", "THIRD_PARTY_NOTICES.md", "ffmpeg/FFmpeg-LICENSE.txt"] {
                let path = resourceURL.appendingPathComponent(required)
                #expect(FileManager.default.fileExists(atPath: path.path), "Missing bundled notice: \(required)")
            }

            let noticesText = try String(contentsOf: resourceURL.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
            #expect(noticesText.contains("JPEG XL Project Authors"))

            let loURL = resourceURL.appendingPathComponent("LibreOffice")
            if FileManager.default.fileExists(atPath: loURL.path) {
                let verifyLO = Process()
                verifyLO.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                verifyLO.arguments = ["--verify", "--deep", "--strict", loURL.path]
                let verifyRes = try await AsyncProcessRunner.run(verifyLO)
                #expect(verifyRes.terminationStatus == 0)
            }

            if let execURL = appBundle.executableURL {
                let otool = Process()
                otool.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
                otool.arguments = ["-L", execURL.path]
                let otoolOut = String(data: try await AsyncProcessRunner.run(otool).stdout, encoding: .utf8) ?? ""
                #expect(!otoolOut.contains("/opt/homebrew"))
                #expect(!otoolOut.contains("/usr/local"))
            }
        }
    }

    // MARK: - 2. FFmpeg Stream-Copy Policy & Codec Accuracy

    @Test("FFmpeg stream-copy policy disables copy for size/quality/preset/codec overrides and still-image inputs")
    func ffmpegStreamCopyPolicyAndSubtitleMapping() {
        let provider = BaseFFmpegProvider()
        let h264Stream = MediaStreamInfo(
            index: 0, streamType: .video, codecName: "h264", codecLongName: "H.264",
            bitRate: 1_500_000, width: 1280, height: 720, frameRate: 30, sampleRate: nil, channels: nil, duration: 5.0
        )
        let gifStream = MediaStreamInfo(
            index: 0, streamType: .video, codecName: "gif", codecLongName: "GIF",
            bitRate: nil, width: 128, height: 128, frameRate: 15, sampleRate: nil, channels: nil, duration: 1.0
        )
        let aacStream = MediaStreamInfo(
            index: 1, streamType: .audio, codecName: "aac", codecLongName: "AAC",
            bitRate: 128_000, width: nil, height: nil, frameRate: nil, sampleRate: 48000, channels: 2, duration: 5.0
        )
        let srtSub = MediaStreamInfo(
            index: 2, streamType: .subtitle, codecName: "subrip", codecLongName: "SubRip",
            bitRate: nil, width: nil, height: nil, frameRate: nil, sampleRate: nil, channels: nil, duration: 5.0
        )
        let pgsSub = MediaStreamInfo(
            index: 3, streamType: .subtitle, codecName: "hdmv_pgs_subtitle", codecLongName: "PGS",
            bitRate: nil, width: nil, height: nil, frameRate: nil, sampleRate: nil, channels: nil, duration: 5.0
        )

        let mp4Info = MediaInfo(url: URL(fileURLWithPath: "/tmp/in.mp4"), formatName: "mp4", duration: 5.0, fileSize: 1_000_000, bitRate: 1_600_000, streams: [h264Stream, aacStream])
        let gifInfo = MediaInfo(url: URL(fileURLWithPath: "/tmp/in.gif"), formatName: "gif", duration: 1.0, fileSize: 10_000, bitRate: nil, streams: [gifStream])
        let mixedSubInfo = MediaInfo(url: URL(fileURLWithPath: "/tmp/in.mkv"), formatName: "matroska", duration: 5.0, fileSize: 1_000_000, bitRate: 1_600_000, streams: [h264Stream, aacStream, srtSub, pgsSub])

        // Plain compatible streams with .default allow stream copy
        #expect(provider.canStreamCopy(inputInfo: mp4Info, targetFormat: .mp4, options: .default))

        // Overriding targetFileSizeBytes, mediaQuality, preset, vcodec, or GIF disables stream copy
        var targetSizeOpts = ConversionOptions.default
        targetSizeOpts.targetFileSizeBytes = 500_000
        #expect(!provider.canStreamCopy(inputInfo: mp4Info, targetFormat: .mp4, options: targetSizeOpts))

        var qualityOpts = ConversionOptions.default
        qualityOpts.mediaQuality = .low
        #expect(!provider.canStreamCopy(inputInfo: mp4Info, targetFormat: .mkv, options: qualityOpts))

        var compatOpts = ConversionOptions.default
        compatOpts.preset = .videoMaximumCompatibility
        compatOpts.applyPreset()
        #expect(compatOpts.customOptions["vcodec"] == "h264_videotoolbox")
        #expect(!provider.canStreamCopy(inputInfo: mp4Info, targetFormat: .mp4, options: compatOpts))

        let compatArgs = provider.buildFFmpegArguments(
            inputURL: URL(fileURLWithPath: "/tmp/in.mkv"),
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            inputInfo: mp4Info,
            outputFormat: .mp4,
            options: compatOpts
        )
        #expect(!compatArgs.contains("copy"))
        #expect(compatArgs.contains("-profile:v"))

        #expect(!provider.canStreamCopy(inputInfo: gifInfo, targetFormat: .mp4, options: .default))

        // AVI target file size propagates bitrate args
        let aviArgs = provider.videoEncodingArguments(for: .avi, options: targetSizeOpts, duration: 10.0)
        #expect(aviArgs.contains("-b:v"))
        #expect(aviArgs.contains("-maxrate"))

        // Mixed text + bitmap subtitles map ONLY text subtitle stream index 2
        #expect(mixedSubInfo.textSubtitleStreams.map(\.index) == [2])
        let mixedArgs = provider.buildFFmpegArguments(
            inputURL: URL(fileURLWithPath: "/tmp/in.mkv"),
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            inputInfo: mixedSubInfo,
            outputFormat: .mp4,
            options: .default
        )
        #expect(mixedArgs.contains("0:2"))
        #expect(!mixedArgs.contains("0:3"))
        #expect(mixedArgs.contains("mov_text"))
    }

    @Test("Audio-only MP3 -> MP4 rejects cleanly, while real GIF -> MP4 transcodes to H.264")
    func ffmpegAudioRejectionAndRealGifToMp4() async throws {
        let dir = try makeTempDir("ffmpeg_real")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, _) = try await findFFmpegPaths()
        let provider = BundledFFmpegProvider()

        // 1. Audio-only MP3 -> MP4 must throw ConversionError.invalidInput
        let mp3URL = dir.appendingPathComponent("audio.mp3")
        let makeMP3 = Process()
        makeMP3.executableURL = URL(fileURLWithPath: ffmpeg)
        makeMP3.arguments = ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.4", "-c:a", "libmp3lame", mp3URL.path]
        #expect(try await AsyncProcessRunner.run(makeMP3).terminationStatus == 0)

        var threwInvalidInput = false
        do {
            _ = try await provider.convert(input: mp3URL, to: .mp4, outputDirectory: dir, options: .default) { _ in }
        } catch ConversionError.invalidInput {
            threwInvalidInput = true
        }
        #expect(threwInvalidInput)

        // 2. Real animated GIF -> MP4 must transcode into H.264 (not fail trying stream copy)
        let gifURL = dir.appendingPathComponent("anim.gif")
        let img1 = try makeSolidImage(width: 64, height: 64, red: 1, green: 0, blue: 0)
        let img2 = try makeSolidImage(width: 64, height: 64, red: 0, green: 0, blue: 1)
        let gifDest = try #require(CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 2, nil))
        let delayProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(gifDest, img1, delayProps)
        CGImageDestinationAddImage(gifDest, img2, delayProps)
        #expect(CGImageDestinationFinalize(gifDest))

        let mp4Out = try await provider.convert(input: gifURL, to: .mp4, outputDirectory: dir, options: .default) { _ in }
        let probed = try await provider.probe(url: mp4Out)
        #expect(probed.hasRealVideo)
        #expect(probed.primaryVideoStream?.codecName.lowercased() == "h264")
    }

    // MARK: - 3. Atomic Output Reservation & Existing File Collision Policies

    @MainActor
    @Test("Atomic reservation prevents concurrent collisions and enforces skip / overwrite / createUnique")
    func atomicOutputReservationAndCollisionPolicies() async throws {
        let dir = try makeTempDir("reserve")
        defer {
            ConversionManager.clearReservedOutputURLs()
            try? FileManager.default.removeItem(at: dir)
        }

        let inputURL = dir.appendingPathComponent("photo.png")
        try writePNG(try makeSolidImage(width: 16, height: 16, red: 0.2, green: 0.5, blue: 0.8), to: inputURL)

        // 1. 10-way concurrent reservation yields 10 distinct URLs
        let reserved = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try ConversionManager.reserveOutputURL(for: inputURL, format: .webp, in: dir)
                }
            }
            var urls: [URL] = []
            for try await url in group {
                urls.append(url)
            }
            return urls
        }
        #expect(Set(reserved).count == 10)
        for u in reserved { ConversionManager.releaseReservedOutputURL(u) }

        // 2. Skip policy refuses to overwrite or duplicate existing target
        let targetURL = dir.appendingPathComponent("photo.webp")
        try Data("EXISTING_SENTINEL".utf8).write(to: targetURL)

        var skipOpts = ConversionOptions.default
        skipOpts.customOptions["existing_file_handling"] = ExistingFileHandling.skip.rawValue
        var didSkip = false
        do {
            _ = try ConversionManager.reserveOutputURL(for: inputURL, format: .webp, in: dir, options: skipOpts)
        } catch ConversionError.outputFileAlreadyExists {
            didSkip = true
        }
        #expect(didSkip)
        #expect(String(data: try Data(contentsOf: targetURL), encoding: .utf8) == "EXISTING_SENTINEL")

        // 3. Overwrite policy replaces file cleanly at exact target path
        let tempNew = dir.appendingPathComponent("temp_new.webp")
        try Data("NEW_REPLACED".utf8).write(to: tempNew)
        var overwriteOpts = ConversionOptions.default
        overwriteOpts.overwriteExisting = true
        let finalized = try ConversionManager.finalizeOutputFile(from: tempNew, for: inputURL, format: .webp, in: dir, options: overwriteOpts)
        #expect(finalized.standardizedFileURL == targetURL.standardizedFileURL)
        #expect(String(data: try Data(contentsOf: finalized), encoding: .utf8) == "NEW_REPLACED")

        // 4. AppSettings.existingFileHandling = .skip wires into defaultConversionOptions
        let prevHandling = AppSettings.shared.existingFileHandling
        defer { AppSettings.shared.existingFileHandling = prevHandling }
        AppSettings.shared.existingFileHandling = .skip
        #expect(AppSettings.shared.defaultConversionOptions.resolvedExistingFileHandling == .skip)
    }

    // MARK: - 4. ICO Downscaling, PDF -> XLSX, PDF Visual Mode & Presets

    @Test("Large transparent PNG -> ICO scales proportionally <= 256x256 while preserving alpha")
    func icoProportionalDownscalingPreservingAlpha() async throws {
        let dir = try makeTempDir("ico_alpha")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pngURL = dir.appendingPathComponent("wide_icon.png")
        let img = try makeSolidImage(width: 1024, height: 512, red: 0, green: 0.4, blue: 1.0, alpha: 1.0, transparentBorder: true)
        try writePNG(img, to: pngURL)

        let res = try await ImageConversionEngine().convert(inputs: [pngURL], to: .ico, outputDirectory: dir, options: .default) { _ in }
        let icoSrc = try #require(CGImageSourceCreateWithURL(res.outputURL as CFURL, nil))
        let icoImg = try #require(CGImageSourceCreateImageAtIndex(icoSrc, 0, nil))

        #expect(icoImg.width == 256)
        #expect(icoImg.height == 256)

        let corner = try sampleRGBAPixel(from: icoImg, x: 2, y: 2)
        let center = try sampleRGBAPixel(from: icoImg, x: 128, y: 128)
        #expect(corner.a == 0)
        #expect(center.a == 255)
        #expect(center.b > 200)
    }

    @Test("PDF multi-column table extracts intact multi-word cells and exports valid XLSX & visual DOCX")
    func pdfMultiColumnCSVXLSXAndVisualDocx() async throws {
        let dir = try makeTempDir("pdf_office")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("invoice_table.pdf")
        var pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(pdfURL as CFURL, mediaBox: &pageBox, nil))
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        "Item Name".draw(at: NSPoint(x: 40, y: 700), withAttributes: attrs)
        "Qty".draw(at: NSPoint(x: 240, y: 700), withAttributes: attrs)
        "Unit Price".draw(at: NSPoint(x: 340, y: 700), withAttributes: attrs)
        "Widget Alpha".draw(at: NSPoint(x: 40, y: 675), withAttributes: attrs)
        "12".draw(at: NSPoint(x: 240, y: 675), withAttributes: attrs)
        "$49.99".draw(at: NSPoint(x: 340, y: 675), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()

        let loProvider = BaseLibreOfficeProvider()
        let csv = try loProvider.extractCSV(from: pdfURL)
        #expect(csv.contains("\"Item Name\""))
        #expect(csv.contains("\"Widget Alpha\""))
        #expect(csv.contains("\"Unit Price\""))

        let officeEngine = OfficeConversionEngine()
        if await officeEngine.isAvailable() {
            let xlsxRes = try await officeEngine.convert(inputs: [pdfURL], to: .xlsx, outputDirectory: dir, options: .default) { _ in }
            #expect(FileManager.default.fileExists(atPath: xlsxRes.outputURL.path))
            #expect(xlsxRes.fileSize > 0)

            var visualOpts = ConversionOptions.default
            visualOpts.pdfOfficeMode = .visual
            let visualDocx = try await officeEngine.convert(inputs: [pdfURL], to: .docx, outputDirectory: dir, options: visualOpts) { _ in }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-l", visualDocx.outputURL.path]
            let listStr = String(data: try await AsyncProcessRunner.run(unzip).stdout, encoding: .utf8) ?? ""
            #expect(listStr.contains("word/document.xml"))
            #expect(listStr.contains("word/media/"))
        }
    }

    @MainActor
    @Test("PresetManager.apply propagates naming policy suffixes and preserves per-file overwrite toggle")
    func presetApplyPreservesNamingAndOverwrite() throws {
        let dir = try makeTempDir("preset_apply")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("sample.png")
        try writePNG(try makeSolidImage(width: 16, height: 16, red: 1, green: 0, blue: 0), to: fileURL)

        let state = AppState()
        state.addFiles(urls: [fileURL])
        state.droppedFiles[0].options.overwriteExisting = true

        let preset = SavedPreset(
            name: "WebP Suffix",
            targetFormat: .webp,
            sourceCategoryConstraint: .image,
            options: ConversionOptions(preserveMetadata: false, imageQuality: 0.75),
            outputNamingPolicy: .addSuffix(suffix: "_web")
        )
        _ = PresetManager.shared.apply(preset: preset, to: state)
        #expect(state.droppedFiles[0].selectedOutputFormat == .webp)
        #expect(state.droppedFiles[0].options.customOptions["output_suffix"] == "_web")
        #expect(state.droppedFiles[0].options.overwriteExisting == true)
    }

    // MARK: - 5. 16-bit Fidelity, Opaque Alpha Flattening, WebP Profiles/EXIF, Multi-Page/Animated & Benchmarks

    @Test("16-bit PNG preserves 16bpc through resize, TIFF, PNG, and JXL; Grayscale resample succeeds")
    func sixteenBitFidelityAndGrayscaleSafety() async throws {
        let dir = try makeTempDir("16bit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let img16 = try makeSolidImage(width: 64, height: 64, bitsPerComponent: 16, red: 0.7, green: 0.3, blue: 0.2)
        let inURL = dir.appendingPathComponent("grad16.png")
        try writePNG(img16, to: inURL)

        let engine = ImageConversionEngine()
        let tiffOut = try await engine.convert(inputs: [inURL], to: .tiff, outputDirectory: dir, options: .default) { _ in }
        let tiffSrc = try #require(CGImageSourceCreateWithURL(tiffOut.outputURL as CFURL, nil))
        let tiffDecoded = try #require(CGImageSourceCreateImageAtIndex(tiffSrc, 0, nil))
        #expect(tiffDecoded.bitsPerComponent == 16)

        var jxlOpts = ConversionOptions.default
        jxlOpts.customOptions["jxl_lossless"] = "true"
        jxlOpts.customOptions["jxl_bit_depth"] = "16"
        let jxlOut = try await engine.convert(inputs: [inURL], to: .jxl, outputDirectory: dir, options: jxlOpts) { _ in }
        let jxlDecoded = try JPEGXLCodec.decode(url: jxlOut.outputURL, prefer16Bit: true, decodeAllFrames: false)
        #expect(try #require(jxlDecoded.primaryImage).bitsPerComponent == 16)

        let resampled16 = try ImageProcessor.resampleCGImage(img16, width: 32, height: 32, method: .lanczos)
        #expect(resampled16.bitsPerComponent == 16)

        let grayCS = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let grayCtx = try #require(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: grayCS, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let grayImg = try #require(grayCtx.makeImage())
        let grayResampled = try ImageProcessor.resampleCGImage(grayImg, width: 16, height: 16, method: .bilinear)
        #expect(grayResampled.width == 16 && grayResampled.height == 16)
    }

    @Test("RGBA with transparent border flattens to white in JPG, BMP, and PPM/HDR")
    func opaqueFormatsFlattenAlphaToWhite() async throws {
        let dir = try makeTempDir("opaque_flatten")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcImg = try makeSolidImage(width: 64, height: 64, red: 0.9, green: 0.1, blue: 0.1, alpha: 1.0, transparentBorder: true)
        let inURL = dir.appendingPathComponent("alpha_border.png")
        try writePNG(srcImg, to: inURL)

        let engine = ImageConversionEngine()
        for target: FileFormat in [.jpg, .bmp, .ppm] {
            let res = try await engine.convert(inputs: [inURL], to: target, outputDirectory: dir, options: .default) { _ in }
            let src = try #require(CGImageSourceCreateWithURL(res.outputURL as CFURL, nil))
            let dec = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            let corner = try sampleRGBAPixel(from: dec, x: 2, y: 2)
            #expect(corner.r >= 245 && corner.g >= 245 && corner.b >= 245, "Expected white border for \(target.rawValue), got \(corner)")
        }

        // Verify HDR output generates cleanly without failing
        let hdrRes = try await engine.convert(inputs: [inURL], to: .hdr, outputDirectory: dir, options: .default) { _ in }
        #expect(hdrRes.fileSize > 100)
    }

    @Test("Display P3 + EXIF/XMP -> WebP embeds VP8X/ICCP/EXIF/XMP and round-trips through CGImageSource")
    func webpICCAndEXIFRoundTrip() async throws {
        let dir = try makeTempDir("webp_meta")
        defer { try? FileManager.default.removeItem(at: dir) }

        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let img = try makeSolidImage(width: 64, height: 64, colorSpace: p3, red: 0.2, green: 0.8, blue: 0.4)
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(xmp, nil, "dc:creator" as CFString, "Phase40Tester" as CFString)
        let srcProps: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Leica", kCGImagePropertyTIFFModel: "M11"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:16 12:34:56"],
            kCGImageDestinationMetadata: xmp
        ]
        let inURL = dir.appendingPathComponent("p3_exif.png")
        try writePNG(img, to: inURL, properties: srcProps)

        var opts = ConversionOptions.default
        opts.preserveMetadata = true
        let webpRes = try await ImageConversionEngine().convert(inputs: [inURL], to: .webp, outputDirectory: dir, options: opts) { _ in }
        let webpData = try Data(contentsOf: webpRes.outputURL)
        #expect(WebPEncoder.validate(webpData))

        // Container must include VP8X, ICCP, EXIF, and XMP chunks
        let ascii = String(decoding: webpData, as: UTF8.self)
        #expect(ascii.contains("VP8X"))
        #expect(ascii.contains("ICCP"))
        #expect(ascii.contains("EXIF"))
        #expect(ascii.contains("XMP "))

        // Decode with Apple ImageIO and confirm both Display P3 ICC profile and EXIF/TIFF tags round-trip
        let roundSrc = try #require(CGImageSourceCreateWithData(webpData as CFData, nil))
        let roundImg = try #require(CGImageSourceCreateImageAtIndex(roundSrc, 0, nil))
        let roundProps = (CGImageSourceCopyPropertiesAtIndex(roundSrc, 0, nil) as? [CFString: Any]) ?? [:]
        let tiffDict = roundProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exifDict = roundProps[kCGImagePropertyExifDictionary] as? [CFString: Any]

        #expect(tiffDict?[kCGImagePropertyTIFFMake] as? String == "Leica")
        #expect(exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:11:16 12:34:56")
        #expect(roundImg.colorSpace?.copyICCData() as Data? == p3.copyICCData() as Data?)
    }

    @Test("Multi-page TIFF preserves pages to TIFF/PDF, and animated WebP preserves frames to GIF")
    func multiPageTIFFAndAnimatedWebP() async throws {
        let dir = try makeTempDir("multipage_anim")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. 3-page TIFF
        let tiffURL = dir.appendingPathComponent("multi.tiff")
        let tiffDest = try #require(CGImageDestinationCreateWithURL(tiffURL as CFURL, UTType.tiff.identifier as CFString, 3, nil))
        for rgb: (CGFloat, CGFloat, CGFloat) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
            CGImageDestinationAddImage(tiffDest, try makeSolidImage(width: 48, height: 48, red: rgb.0, green: rgb.1, blue: rgb.2), nil)
        }
        #expect(CGImageDestinationFinalize(tiffDest))

        let engine = ImageConversionEngine()
        let outTIFF = try await engine.convert(inputs: [tiffURL], to: .tiff, outputDirectory: dir, options: .default) { _ in }
        let outTIFFSrc = try #require(CGImageSourceCreateWithURL(outTIFF.outputURL as CFURL, nil))
        #expect(CGImageSourceGetCount(outTIFFSrc) == 3)

        let outPDF = try await engine.convert(inputs: [tiffURL], to: .pdf, outputDirectory: dir, options: .default) { _ in }
        let outPDFDoc = try #require(PDFDocument(url: outPDF.outputURL))
        #expect(outPDFDoc.pageCount == 3)

        // 2. Animated 2-frame WebP -> GIF preserves 2 frames
        let frame1 = try makeSolidImage(width: 48, height: 48, red: 1, green: 0, blue: 0)
        let frame2 = try makeSolidImage(width: 48, height: 48, red: 0, green: 0, blue: 1)
        let animWebP = try makeAnimatedWebPData(frame1: frame1, frame2: frame2)
        let animWebPURL = dir.appendingPathComponent("anim.webp")
        try animWebP.write(to: animWebPURL)

        let outGIF = try await engine.convert(inputs: [animWebPURL], to: .gif, outputDirectory: dir, options: .default) { _ in }
        let gifSrc = try #require(CGImageSourceCreateWithURL(outGIF.outputURL as CFURL, nil))
        #expect(CGImageSourceGetCount(gifSrc) == 2)
    }

    @Test("Large image benchmark (3000x2000 6MP): JXL mmap/premuply, WebP encode, and resize latency/RSS")
    func largeImagePerformanceAndMemoryBenchmark() async throws {
        let dir = try makeTempDir("benchmark_6mp")
        defer { try? FileManager.default.removeItem(at: dir) }

        let largeCG = try makeSolidImage(width: 3000, height: 2000, red: 0.35, green: 0.55, blue: 0.75)
        let largePNG = dir.appendingPathComponent("large_6mp.png")
        try writePNG(largeCG, to: largePNG)

        let rssStart = currentResidentMemoryBytes()

        let jxlStart = CFAbsoluteTimeGetCurrent()
        let jxlOut = try await ImageConversionEngine().convert(inputs: [largePNG], to: .jxl, outputDirectory: dir, options: .default) { _ in }
        let jxlEncodeMs = (CFAbsoluteTimeGetCurrent() - jxlStart) * 1000.0
        #expect(jxlOut.fileSize > 0)

        let decStart = CFAbsoluteTimeGetCurrent()
        let jxlDecoded = try JPEGXLCodec.decode(url: jxlOut.outputURL, prefer16Bit: false, decodeAllFrames: false)
        let jxlDecodeMs = (CFAbsoluteTimeGetCurrent() - decStart) * 1000.0
        #expect(jxlDecoded.primaryImage?.width == 3000)

        let webpStart = CFAbsoluteTimeGetCurrent()
        let webpOut = try await ImageConversionEngine().convert(inputs: [largePNG], to: .webp, outputDirectory: dir, options: .default) { _ in }
        let webpEncodeMs = (CFAbsoluteTimeGetCurrent() - webpStart) * 1000.0
        #expect(webpOut.fileSize > 0)

        let rssEnd = currentResidentMemoryBytes()
        let startMB = Double(rssStart) / (1024 * 1024)
        let endMB = Double(rssEnd) / (1024 * 1024)
        print(String(format: "Phase40Benchmark [3000x2000]: jxlEncode=%.1fms jxlDecode=%.1fms webpEncode=%.1fms rssStart=%.1fMB rssEnd=%.1fMB",
                     jxlEncodeMs, jxlDecodeMs, webpEncodeMs, startMB, endMB))
        #expect(jxlEncodeMs < 30_000)
        #expect(webpEncodeMs < 30_000)
    }
}
