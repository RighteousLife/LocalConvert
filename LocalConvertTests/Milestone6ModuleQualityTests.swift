import XCTest
import Foundation
import AppKit
import PDFKit
import CoreGraphics
@testable import LocalConvert

final class Milestone6ModuleQualityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConversionManager.clearReservedOutputURLs()
    }

    override func tearDown() {
        ConversionManager.clearReservedOutputURLs()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String = "M6") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePDF(at url: URL, password: String? = nil, pageText: String = "Milestone 6 Test Page") throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var auxInfo: [CFString: Any]?
        if let password {
            auxInfo = [
                kCGPDFContextUserPassword: password as CFString,
                kCGPDFContextOwnerPassword: password as CFString
            ]
        }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, auxInfo as CFDictionary?) else {
            throw NSError(domain: "M6Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }

        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor.white)
        ctx.fill(box)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ]
        let attrStr = NSAttributedString(string: pageText, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)

        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func makeExecutableScript(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
    }

    private func makeVideoMediaInfo(
        url: URL = URL(fileURLWithPath: "/tmp/sample.mkv"),
        duration: Double = 10.0,
        hasAudio: Bool = true,
        audioBitrate: Int64? = 192_000,
        subtitleStreams: [MediaStreamInfo] = []
    ) -> MediaInfo {
        var streams: [MediaStreamInfo] = [
            MediaStreamInfo(
                index: 0,
                streamType: .video,
                codecName: "h264",
                codecLongName: "H.264 / AVC",
                bitRate: 2_000_000,
                width: 1280,
                height: 720,
                frameRate: 30.0,
                sampleRate: nil,
                channels: nil,
                duration: duration
            )
        ]
        if hasAudio {
            streams.append(
                MediaStreamInfo(
                    index: 1,
                    streamType: .audio,
                    codecName: "aac",
                    codecLongName: "AAC",
                    bitRate: audioBitrate,
                    width: nil,
                    height: nil,
                    frameRate: nil,
                    sampleRate: 48000,
                    channels: 2,
                    duration: duration
                )
            )
        }
        streams.append(contentsOf: subtitleStreams)
        return MediaInfo(
            url: url,
            formatName: "matroska,webm",
            duration: duration,
            fileSize: 2_500_000,
            bitRate: 2_200_000,
            streams: streams
        )
    }

    // MARK: - 1. LC-010: OfficeConversionEngine URL Encoding & Password-Protected PDF Editable Flow

    func testLibreOfficeUserInstallationArgumentPercentEncodesSpacesAndSpecialChars() {
        let profileURL = URL(
            fileURLWithPath: "/tmp/LocalConvert Temp #1/Office Profile (Test)/profile",
            isDirectory: true
        )
        let arg = BaseLibreOfficeProvider.userInstallationArgument(for: profileURL)

        XCTAssertTrue(arg.hasPrefix("-env:UserInstallation=file:///"))
        XCTAssertEqual(arg, "-env:UserInstallation=\(profileURL.absoluteString)")
        XCTAssertFalse(arg.contains(" "), "UserInstallation file:// URI must percent-encode spaces")
        XCTAssertTrue(arg.contains("%20"))
        XCTAssertTrue(arg.contains("%23"))
    }

    func testPrepareUnlockedEditablePDFCreatesUnlockedCopyInTempRootAndRejectsBadPassword() throws {
        let dir = try makeTempDir(prefix: "M6-OfficeUnlock")
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockedPDF = dir.appendingPathComponent("confidential report.pdf")
        let unlockedInputPDF = dir.appendingPathComponent("plain report.pdf")
        let tempRoot = dir.appendingPathComponent("tempRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        try writePDF(at: lockedPDF, password: "Secret!Password#1")
        try writePDF(at: unlockedInputPDF, password: nil)

        // Missing password throws invalidInput without creating temp unlocked files
        XCTAssertThrowsError(
            try BaseLibreOfficeProvider.prepareUnlockedEditablePDF(
                at: lockedPDF,
                options: .default,
                in: tempRoot
            )
        ) { error in
            guard case ConversionError.invalidInput(let msg) = error else {
                return XCTFail("Expected ConversionError.invalidInput, got \(error)")
            }
            XCTAssertTrue(msg.contains("password-protected"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path), [])

        // Wrong password throws invalidInput without leaking temp files
        var wrongOpts = ConversionOptions.default
        wrongOpts.customOptions["pdf_password"] = "WrongPassword"
        XCTAssertThrowsError(
            try BaseLibreOfficeProvider.prepareUnlockedEditablePDF(
                at: lockedPDF,
                options: wrongOpts,
                in: tempRoot
            )
        ) { error in
            guard case ConversionError.invalidInput(let msg) = error else {
                return XCTFail("Expected ConversionError.invalidInput, got \(error)")
            }
            XCTAssertTrue(msg.contains("Incorrect password"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempRoot.path), [])

        // Correct password writes an unencrypted temporary PDF inside tempRoot preserving base filename
        var goodOpts = ConversionOptions.default
        goodOpts.customOptions["pdf_password"] = "Secret!Password#1"
        let prepared = try BaseLibreOfficeProvider.prepareUnlockedEditablePDF(
            at: lockedPDF,
            options: goodOpts,
            in: tempRoot
        )
        XCTAssertNotEqual(prepared.sourceURL.standardizedFileURL, lockedPDF.standardizedFileURL)
        XCTAssertEqual(prepared.sourceURL.lastPathComponent, lockedPDF.lastPathComponent)
        XCTAssertTrue(prepared.sourceURL.path.hasPrefix(tempRoot.path))
        let cleanupDir = try XCTUnwrap(prepared.cleanupDirectory)
        XCTAssertTrue(cleanupDir.path.hasPrefix(tempRoot.path))

        let opened = try XCTUnwrap(PDFDocument(url: prepared.sourceURL))
        XCTAssertFalse(opened.isLocked)
        XCTAssertFalse(opened.isEncrypted)
        XCTAssertEqual(opened.pageCount, 1)

        try FileManager.default.removeItem(at: cleanupDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.sourceURL.path))

        // Unencrypted input passes through directly with no extra temp copy
        let plainPrepared = try BaseLibreOfficeProvider.prepareUnlockedEditablePDF(
            at: unlockedInputPDF,
            options: .default,
            in: tempRoot
        )
        XCTAssertEqual(plainPrepared.sourceURL.standardizedFileURL, unlockedInputPDF.standardizedFileURL)
        XCTAssertNil(plainPrepared.cleanupDirectory)
    }

    func testOfficeConversionEngineEditableDocxAndPptxUseUnlockedTempPDFAndCleanTempRoot() async throws {
        let dir = try makeTempDir(prefix: "M6-OfficeFlow")
        defer { try? FileManager.default.removeItem(at: dir) }

        let lockedPDF = dir.appendingPathComponent("Protected Doc.pdf")
        try writePDF(at: lockedPDF, password: "OpenSesame42")

        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let argsLog = dir.appendingPathComponent("soffice_args.log")
        let capturedInputCopy = dir.appendingPathComponent("captured_input.pdf")
        let payloadDir = dir.appendingPathComponent("zip_payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDir.appendingPathComponent("word"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadDir.appendingPathComponent("ppt/slides"), withIntermediateDirectories: true)
        try "<w:document/>".write(to: payloadDir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try "<p:presentation/>".write(to: payloadDir.appendingPathComponent("ppt/presentation.xml"), atomically: true, encoding: .utf8)
        try "<p:sld/>".write(to: payloadDir.appendingPathComponent("ppt/slides/slide1.xml"), atomically: true, encoding: .utf8)

        let dummySoffice = dir.appendingPathComponent("dummy-soffice")
        let script = """
        #!/bin/sh
        set -e
        printf '%s\\n' "$@" >> "\(argsLog.path)"
        outdir=""
        convert_to=""
        prev=""
        last=""
        for arg in "$@"; do
            if [ "$prev" = "--outdir" ]; then
                outdir="$arg"
            elif [ "$prev" = "--convert-to" ]; then
                convert_to="$arg"
            fi
            prev="$arg"
            last="$arg"
        done
        cp "$last" "\(capturedInputCopy.path)"
        base="$(basename "$last" .pdf)"
        cd "\(payloadDir.path)"
        if [ "$convert_to" = "docx" ]; then
            /usr/bin/zip -q -r "$outdir/$base.docx" word
        elif [ "$convert_to" = "pptx" ]; then
            /usr/bin/zip -q -r "$outdir/$base.pptx" ppt
        fi
        exit 0
        """
        try makeExecutableScript(at: dummySoffice, contents: script)

        let provider = BundledLibreOfficeProvider(
            fallbackToSystem: false,
            enforceBundledOnly: false,
            environment: ["LOCALCONVERT_SOFFICE_PATH": dummySoffice.path],
            bundleCandidatesOverride: []
        )
        let engine = OfficeConversionEngine(provider: provider)

        // 1. Wrong password must fail before invoking soffice
        var wrongOpts = ConversionOptions.default
        wrongOpts.pdfOfficeMode = .editable
        wrongOpts.customOptions["pdf_password"] = "BadPwd"
        do {
            _ = try await engine.convert(inputs: [lockedPDF], to: .docx, outputDirectory: outDir, options: wrongOpts) { _ in }
            XCTFail("Expected wrong password to throw")
        } catch let err as ConversionError {
            guard case .invalidInput = err else {
                return XCTFail("Expected invalidInput, got \(err)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: argsLog.path), "soffice must not run when password is wrong")

        // 2. Correct password for PDF -> DOCX (.editable)
        var opts = ConversionOptions.default
        opts.pdfOfficeMode = .editable
        opts.customOptions["pdf_password"] = "OpenSesame42"

        let docxResult = try await engine.convert(inputs: [lockedPDF], to: .docx, outputDirectory: outDir, options: opts) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: docxResult.outputURL.path))
        XCTAssertEqual(docxResult.outputFormat, .docx)

        let loggedArgs = try String(contentsOf: argsLog, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }
        let userInstallArg = try XCTUnwrap(loggedArgs.first { $0.hasPrefix("-env:UserInstallation=") })
        XCTAssertTrue(userInstallArg.hasPrefix("-env:UserInstallation=file:///"))
        XCTAssertFalse(userInstallArg.contains(" "))
        XCTAssertTrue(loggedArgs.contains("--infilter=writer_pdf_import"))
        XCTAssertFalse(loggedArgs.contains(lockedPDF.path), "Original locked PDF must NOT be passed directly to soffice")

        let capturedDocxInput = try XCTUnwrap(PDFDocument(url: capturedInputCopy))
        XCTAssertFalse(capturedDocxInput.isLocked)
        XCTAssertFalse(capturedDocxInput.isEncrypted)

        // Verify temp unlocked PDF directory was cleaned up after convert returned
        if let passedPDFPath = loggedArgs.last(where: { $0.hasSuffix(".pdf") }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: passedPDFPath), "Temporary unlocked PDF must be deleted in defer")
            let passedURL = URL(fileURLWithPath: passedPDFPath)
            let tempRootDir = passedURL.deletingLastPathComponent().deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempRootDir.path), "tempRoot must be deleted in defer")
        }

        // 3. Correct password for PDF -> PPTX (.editable)
        try? FileManager.default.removeItem(at: argsLog)
        try? FileManager.default.removeItem(at: capturedInputCopy)
        let pptxResult = try await engine.convert(inputs: [lockedPDF], to: .pptx, outputDirectory: outDir, options: opts) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pptxResult.outputURL.path))
        XCTAssertEqual(pptxResult.outputFormat, .pptx)

        let pptxArgs = try String(contentsOf: argsLog, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertTrue(pptxArgs.contains("--infilter=impress_pdf_import"))
        XCTAssertFalse(pptxArgs.contains(lockedPDF.path))
        let capturedPptxInput = try XCTUnwrap(PDFDocument(url: capturedInputCopy))
        XCTAssertFalse(capturedPptxInput.isLocked)
        XCTAssertFalse(capturedPptxInput.isEncrypted)

        // 4. Preserve LC-004 enforceBundledOnly
        let releaseProvider = BundledLibreOfficeProvider(fallbackToSystem: true, enforceBundledOnly: true)
        XCTAssertTrue(releaseProvider.enforceBundledOnly)
        XCTAssertFalse(releaseProvider.fallbackToSystem)
    }

    // MARK: - 2. LC-010: PDFToolboxEngine Empty Inputs Safety Guard

    func testPDFToolboxEngineRejectsEmptyInputsWithoutCrashing() async throws {
        let dir = try makeTempDir(prefix: "M6-PDFToolboxEmpty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = PDFToolboxEngine()
        let operations: [(String, FileFormat)] = [
            ("pdfToImages", .png),
            ("imagesToPDF", .pdf),
            ("merge", .pdf),
            ("rotate", .pdf),
            ("normalizePageSizes", .pdf),
            ("unknown", .pdf)
        ]

        for (op, format) in operations {
            var opts = ConversionOptions.default
            opts.customOptions["pdf_operation"] = op
            do {
                _ = try await engine.convert(inputs: [], to: format, outputDirectory: dir, options: opts) { _ in }
                XCTFail("Expected empty inputs for operation '\(op)' to throw ConversionError.invalidInput")
            } catch let error as ConversionError {
                guard case .invalidInput = error else {
                    XCTFail("Expected ConversionError.invalidInput for '\(op)', got \(error)")
                    continue
                }
            }
        }
    }

    // MARK: - 3. LC-012: Target-File-Size Video Bitrate Using Actual Selected Audio Bitrate

    private func extractArgValue(_ flag: String, from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    func testTargetFileSizeVideoBitrateUsesActualSelectedAudioBitrate() {
        let provider = BaseFFmpegProvider()
        var opts = ConversionOptions.default
        opts.targetFileSizeBytes = 1_000_000 // 8,000,000 bits over 10s = 800,000 bps total budget

        // MP4 defaults to 192k AAC -> 800,000 - 192,000 = 608,000 bps (NOT 672,000 from hardcoded 128k)
        let mp4Args = provider.videoEncodingArguments(for: .mp4, options: opts, duration: 10.0)
        XCTAssertEqual(extractArgValue("-b:v", from: mp4Args), "608000")

        // WebM defaults to 128k Opus -> 800,000 - 128,000 = 672,000 bps
        let webmArgs = provider.videoEncodingArguments(for: .webm, options: opts, duration: 10.0)
        XCTAssertEqual(extractArgValue("-b:v", from: webmArgs), "672000")

        // M2V disables audio (-an = 0 bps) -> 800,000 bps
        let m2vArgs = provider.videoEncodingArguments(for: .m2v, options: opts, duration: 10.0)
        XCTAssertEqual(extractArgValue("-b:v", from: m2vArgs), "800000")

        // Custom 64k audio bitrate -> 800,000 - 64,000 = 736,000 bps
        var opts64 = opts
        opts64.customOptions["audio_bitrate_kbps"] = "64"
        let audio64 = provider.audioEncodingArgumentsForVideo(targetFormat: .mp4, options: opts64)
        XCTAssertEqual(extractArgValue("-b:a", from: audio64), "64k")
        let video64 = provider.videoEncodingArguments(for: .mp4, options: opts64, duration: 10.0)
        XCTAssertEqual(extractArgValue("-b:v", from: video64), "736000")

        // Custom 320k audio bitrate -> 800,000 - 320,000 = 480,000 bps
        var opts320 = opts
        opts320.customOptions["audio_bitrate_kbps"] = "320"
        let audio320 = provider.audioEncodingArgumentsForVideo(targetFormat: .mp4, options: opts320)
        XCTAssertEqual(extractArgValue("-b:a", from: audio320), "320k")
        let video320 = provider.videoEncodingArguments(for: .mp4, options: opts320, duration: 10.0)
        XCTAssertEqual(extractArgValue("-b:v", from: video320), "480000")

        // Audio disabled via acodec = "none" -> 0 bps audio -> 800,000 bps video
        var optsNoAudio = opts
        optsNoAudio.customOptions["acodec"] = "none"
        XCTAssertEqual(provider.audioEncodingArgumentsForVideo(targetFormat: .mp4, options: optsNoAudio), ["-an"])
        let videoNoAudio = provider.videoEncodingArguments(for: .mp4, options: optsNoAudio, duration: 10.0)
        XCTAssertEqual(extractArgValue("-b:v", from: videoNoAudio), "800000")

        // Source video with NO audio stream -> 0 bps audio -> 800,000 bps video
        let silentSource = makeVideoMediaInfo(duration: 10.0, hasAudio: false)
        let silentFullArgs = provider.buildFFmpegArguments(
            inputURL: silentSource.url,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            inputInfo: silentSource,
            outputFormat: .mp4,
            options: opts
        )
        XCTAssertEqual(extractArgValue("-b:v", from: silentFullArgs), "800000")

        // Audio stream copy uses source audio bitrate (256 kbps -> 544,000 bps video) and omits -b:a
        var optsCopy = opts
        optsCopy.customOptions["acodec"] = "copy"
        let copyAudioArgs = provider.audioEncodingArgumentsForVideo(targetFormat: .mp4, options: optsCopy)
        XCTAssertEqual(copyAudioArgs, ["-c:a", "copy"])
        let source256k = makeVideoMediaInfo(duration: 10.0, hasAudio: true, audioBitrate: 256_000)
        let copyFullArgs = provider.buildFFmpegArguments(
            inputURL: source256k.url,
            outputURL: URL(fileURLWithPath: "/tmp/out_copy.mp4"),
            inputInfo: source256k,
            outputFormat: .mp4,
            options: optsCopy
        )
        XCTAssertEqual(extractArgValue("-b:v", from: copyFullArgs), "544000")

        // Minimum video bitrate floor (100 kbps) when target size is smaller than audio budget
        var tinyOpts = ConversionOptions.default
        tinyOpts.targetFileSizeBytes = 50_000 // 40 kbps total over 10s
        let flooredArgs = provider.videoEncodingArguments(for: .mp4, options: tinyOpts, duration: 10.0)
        XCTAssertEqual(extractArgValue("-b:v", from: flooredArgs), "100000")
    }

    // MARK: - 4. LC-012: Bitmap Subtitle (PGS / DVD) Non-Fatal Warning

    func testDroppedBitmapSubtitlesSurfaceStructuredNonFatalWarning() {
        StructuredDiagnostics.clearRecentEvents()
        let provider = BaseFFmpegProvider()

        let pgsStream = MediaStreamInfo(
            index: 2,
            streamType: .subtitle,
            codecName: "hdmv_pgs_subtitle",
            codecLongName: "HDMV Presentation Graphic Stream subtitles",
            bitRate: nil, width: nil, height: nil, frameRate: nil, sampleRate: nil, channels: nil, duration: 10.0
        )
        let dvdStream = MediaStreamInfo(
            index: 3,
            streamType: .subtitle,
            codecName: "dvd_subtitle",
            codecLongName: "DVD subtitles",
            bitRate: nil, width: nil, height: nil, frameRate: nil, sampleRate: nil, channels: nil, duration: 10.0
        )
        let srtStream = MediaStreamInfo(
            index: 4,
            streamType: .subtitle,
            codecName: "subrip",
            codecLongName: "SubRip subtitle",
            bitRate: nil, width: nil, height: nil, frameRate: nil, sampleRate: nil, channels: nil, duration: 10.0
        )

        let bitmapOnlyInfo = makeVideoMediaInfo(
            url: URL(fileURLWithPath: "/tmp/bluray_sample.mkv"),
            subtitleStreams: [pgsStream, dvdStream]
        )

        // MKV preserves bitmap subtitles -> no warning
        XCTAssertNil(BaseFFmpegProvider.droppedBitmapSubtitleWarning(inputInfo: bitmapOnlyInfo, outputFormat: .mkv))
        _ = provider.buildFFmpegArguments(
            inputURL: bitmapOnlyInfo.url,
            outputURL: URL(fileURLWithPath: "/tmp/out.mkv"),
            inputInfo: bitmapOnlyInfo,
            outputFormat: .mkv,
            options: .default
        )
        XCTAssertTrue(
            StructuredDiagnostics.recentEvents(category: .videoProcessing).filter { $0.stage == "bitmapSubtitleDropped" }.isEmpty
        )

        // Text-only subtitle to MP4 -> no warning
        let textOnlyInfo = makeVideoMediaInfo(
            url: URL(fileURLWithPath: "/tmp/text_sub.mkv"),
            subtitleStreams: [srtStream]
        )
        XCTAssertNil(BaseFFmpegProvider.droppedBitmapSubtitleWarning(inputInfo: textOnlyInfo, outputFormat: .mp4))

        // Bitmap PGS/DVD subtitles to MP4 -> non-fatal warning + diagnostic event, drops bitmap tracks cleanly
        let warning = BaseFFmpegProvider.droppedBitmapSubtitleWarning(inputInfo: bitmapOnlyInfo, outputFormat: .mp4)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("HDMV_PGS_SUBTITLE") == true)
        XCTAssertTrue(warning?.contains("DVD_SUBTITLE") == true)

        let mp4Args = provider.buildFFmpegArguments(
            inputURL: bitmapOnlyInfo.url,
            outputURL: URL(fileURLWithPath: "/tmp/out.mp4"),
            inputInfo: bitmapOnlyInfo,
            outputFormat: .mp4,
            options: .default
        )
        XCTAssertTrue(mp4Args.contains("-sn"))

        let events = StructuredDiagnostics.recentEvents(category: .videoProcessing, severity: .validation)
            .filter { $0.stage == "bitmapSubtitleDropped" && $0.sanitizedFilename == "bluray_sample.mkv" }
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.first?.message.contains("Dropped 2 bitmap subtitle stream(s)") == true)
    }

    // MARK: - 5. LC-012: h264_videotoolbox Failure Diagnostics & Software (libx264) Fallback

    func testVideoToolboxFailureDetectionDiagnosticsAndSoftwareFallbackArguments() {
        let vtArgs = [
            "-y", "-i", "/tmp/in.mov", "-c:v", "h264_videotoolbox",
            "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-q:v", "75", "-c:a", "aac", "-b:a", "192k", "/tmp/out.mp4"
        ]
        let vp9Args = ["-y", "-i", "/tmp/in.mov", "-c:v", "libvpx-vp9", "/tmp/out.webm"]

        let vtStderr = """
        [h264_videotoolbox @ 0x1400] Error: cannot create compression session: -12908
        Error while opening encoder for output stream #0:0 - maybe incorrect parameters such as bit_rate, rate, width or height
        """
        XCTAssertTrue(BaseFFmpegProvider.isVideoToolboxHardwareFailure(stderr: vtStderr, arguments: vtArgs))
        XCTAssertFalse(BaseFFmpegProvider.isVideoToolboxHardwareFailure(stderr: vtStderr, arguments: vp9Args))
        XCTAssertFalse(BaseFFmpegProvider.isVideoToolboxHardwareFailure(stderr: "Invalid data found when processing input", arguments: vtArgs))

        let summary = BaseFFmpegProvider.videoToolboxDiagnosticSummary(from: "Error in /Users/alice/Movies/clip.mov: VTCompressionSessionCreate failed")
        XCTAssertFalse(summary.contains("/Users/alice"))
        XCTAssertTrue(summary.contains("VTCompressionSessionCreate"))

        var highOpts = ConversionOptions.default
        highOpts.mediaQuality = .high
        let fallbackArgs = BaseFFmpegProvider.softwareH264FallbackArguments(from: vtArgs, options: highOpts)
        XCTAssertEqual(extractArgValue("-c:v", from: fallbackArgs ?? []), "libx264")
        XCTAssertEqual(extractArgValue("-crf", from: fallbackArgs ?? []), "20")
        XCTAssertNil(fallbackArgs?.firstIndex(of: "-q:v"))

        // Target-size bitrate args stay intact during libx264 fallback
        let bitrateArgs = [
            "-y", "-i", "/tmp/in.mov", "-c:v", "h264_videotoolbox",
            "-b:v", "608000", "-maxrate", "608000", "-bufsize", "1216000", "/tmp/out.mp4"
        ]
        let fallbackBitrateArgs = BaseFFmpegProvider.softwareH264FallbackArguments(from: bitrateArgs, options: highOpts)
        XCTAssertEqual(extractArgValue("-c:v", from: fallbackBitrateArgs ?? []), "libx264")
        XCTAssertEqual(extractArgValue("-b:v", from: fallbackBitrateArgs ?? []), "608000")
        XCTAssertNil(BaseFFmpegProvider.softwareH264FallbackArguments(from: vp9Args, options: highOpts))

        // LC-006 timeout constant preserved
        XCTAssertEqual(BaseFFmpegProvider.defaultConversionTimeoutSeconds, 1800.0)
    }

    func testBaseFFmpegProviderRetriesWithLibx264WhenHardwareInitFailsAndLibx264Available() async throws {
        StructuredDiagnostics.clearRecentEvents()
        let dir = try makeTempDir(prefix: "M6-VTFallback")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcFile = dir.appendingPathComponent("input_clip.mov")
        try Data("DUMMY_MOV".utf8).write(to: srcFile)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let invocationLog = dir.appendingPathComponent("ffmpeg_calls.log")
        let dummyFFprobe = dir.appendingPathComponent("ffprobe")
        let dummyFFmpeg = dir.appendingPathComponent("ffmpeg")

        try makeExecutableScript(
            at: dummyFFprobe,
            contents: """
            #!/bin/sh
            cat <<'JSON'
            {"format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"2.0","size":"1024"},"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":320,"height":240,"r_frame_rate":"30/1","duration":"2.0"},{"index":1,"codec_type":"audio","codec_name":"aac","sample_rate":"48000","channels":2,"duration":"2.0"}]}
            JSON
            exit 0
            """
        )

        try makeExecutableScript(
            at: dummyFFmpeg,
            contents: """
            #!/bin/sh
            if [ "$1" = "-hide_banner" ] && [ "$2" = "-encoders" ]; then
                echo " V....D h264_videotoolbox    VideoToolbox H.264 Encoder"
                echo " V..... libx264              libx264 H.264 / AVC"
                exit 0
            fi
            printf '%s\\n' "$*" >> "\(invocationLog.path)"
            last=""
            for arg in "$@"; do
                last="$arg"
            done
            case "$*" in
                *"h264_videotoolbox"*)
                    echo "[h264_videotoolbox @ 0x100] Cannot create compression session: -12908" >&2
                    exit 1
                    ;;
                *"libx264"*)
                    printf 'FAKE_MP4_DATA' > "$last"
                    echo "out_time_us=2000000"
                    echo "progress=end"
                    exit 0
                    ;;
            esac
            exit 1
            """
        )

        let provider = BundledFFmpegProvider(
            fallbackToSystem: false,
            enforceBundledOnly: false,
            environment: [
                "LOCALCONVERT_FFMPEG_PATH": dummyFFmpeg.path,
                "LOCALCONVERT_FFPROBE_PATH": dummyFFprobe.path
            ],
            bundleCandidatesOverride: []
        )

        var opts = ConversionOptions.default
        opts.mediaQuality = .medium // Forces re-encode (disables stream copy)

        let outputURL = try await provider.convert(
            input: srcFile,
            to: .mp4,
            outputDirectory: outDir,
            options: opts
        ) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let calls = try String(contentsOf: invocationLog, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].contains("h264_videotoolbox"))
        XCTAssertTrue(calls[1].contains("libx264"))

        let fallbackEvents = StructuredDiagnostics.recentEvents(category: .videoProcessing)
            .filter { $0.stage == "h264VideoToolboxFallback" }
        XCTAssertFalse(fallbackEvents.isEmpty)
    }

    func testBaseFFmpegProviderReportsVideoToolboxDiagnosticsWhenLibx264Unavailable() async throws {
        StructuredDiagnostics.clearRecentEvents()
        let dir = try makeTempDir(prefix: "M6-VTNoFallback")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcFile = dir.appendingPathComponent("input_clip.mov")
        try Data("DUMMY_MOV".utf8).write(to: srcFile)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dummyFFprobe = dir.appendingPathComponent("ffprobe")
        let dummyFFmpeg = dir.appendingPathComponent("ffmpeg")

        try makeExecutableScript(
            at: dummyFFprobe,
            contents: """
            #!/bin/sh
            cat <<'JSON'
            {"format":{"format_name":"mov","duration":"2.0","size":"1024"},"streams":[{"index":0,"codec_type":"video","codec_name":"prores","width":320,"height":240,"r_frame_rate":"30/1","duration":"2.0"}]}
            JSON
            exit 0
            """
        )

        try makeExecutableScript(
            at: dummyFFmpeg,
            contents: """
            #!/bin/sh
            if [ "$1" = "-hide_banner" ] && [ "$2" = "-encoders" ]; then
                echo " V....D h264_videotoolbox    VideoToolbox H.264 Encoder"
                exit 0
            fi
            echo "[h264_videotoolbox @ 0x100] VTCompressionSessionCreate failed (-12908)" >&2
            exit 1
            """
        )

        let provider = BundledFFmpegProvider(
            fallbackToSystem: false,
            enforceBundledOnly: false,
            environment: [
                "LOCALCONVERT_FFMPEG_PATH": dummyFFmpeg.path,
                "LOCALCONVERT_FFPROBE_PATH": dummyFFprobe.path
            ],
            bundleCandidatesOverride: []
        )

        do {
            _ = try await provider.convert(input: srcFile, to: .mp4, outputDirectory: outDir, options: .default) { _ in }
            XCTFail("Expected ConversionError.engineExecutionFailed when VideoToolbox fails without libx264")
        } catch let error as ConversionError {
            guard case .engineExecutionFailed(let message, let underlying) = error else {
                return XCTFail("Expected engineExecutionFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("h264_videotoolbox"))
            XCTAssertTrue(message.contains("VTCompressionSessionCreate"))
            XCTAssertTrue(underlying?.contains("-12908") == true)
        }

        let failedEvents = StructuredDiagnostics.recentEvents(category: .videoProcessing, severity: .internalError)
            .filter { $0.stage == "h264VideoToolboxFailed" }
        XCTAssertFalse(failedEvents.isEmpty)
    }
}
