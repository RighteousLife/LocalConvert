import Foundation
import Testing
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import LocalConvert

@Suite("Phase 32 — Universal Format Compatibility & Conversion Expansion Tests")
struct Phase32Tests {
    
    let registry = ConversionRegistry.shared
    let capabilityRegistry = FormatCapabilityRegistry.shared
    let detector = FileDetector()
    
    private func createTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Phase32-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func zipContainsEntry(_ archiveURL: URL, pathFragment: String) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", archiveURL.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return listing.components(separatedBy: .newlines).contains { $0 == pathFragment || $0.contains(pathFragment) }
    }
    
    private func runTool(_ executable: String, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, stdout, stderr)
    }
    
    // MARK: - 1. FormatCapabilityRegistry & ConversionMatrix Completeness
    
    @Test("FormatCapabilityRegistry covers all FileFormat cases and enforces read-only invariants")
    @MainActor
    func testRegistryAndMatrixCompleteness() throws {
        let allFormats = FileFormat.allCases
        #expect(capabilityRegistry.allCapabilities.count == allFormats.count)
        
        for format in allFormats {
            let cap = capabilityRegistry.capability(for: format)
            #expect(cap.format == format)
            #expect(!cap.displayName.isEmpty)
            #expect(!cap.fileExtension.isEmpty)
            #expect(!cap.mimeType.isEmpty)
            #expect(cap.canRead == format.capability.canRead)
            #expect(cap.canWrite == format.capability.canWrite)
            
            let outputs = registry.supportedOutputFormats(for: format)
            #expect(!outputs.contains(format), "Self-conversion must never be exposed for \(format.rawValue)")
            for out in outputs {
                #expect(capabilityRegistry.capability(for: out).canWrite,
                        "Read-only format \(out.rawValue) was exposed as output for \(format.rawValue)")
            }
        }
        
        // Strictly read-only formats never appear as targets anywhere
        let readOnlyFormats: [FileFormat] = [
            .xlsb, .docm, .xlsm, .pptm, .ppsx, .pps,
            .sgi, .xpm, .svg,
            .dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw,
            .amr, .ape,
            .mts, .m2ts, .ogv,
            .sub, .sup,
            .rar
        ]
        let allExposedOutputs = Set(allFormats.flatMap { registry.supportedOutputFormats(for: $0) })
        for ro in readOnlyFormats {
            #expect(!allExposedOutputs.contains(ro), "Read-only format \(ro.rawValue) must not appear as output target")
        }
        
        // Matrix snapshot & JSON export
        let snapshot = ConversionMatrix.snapshot(registry: registry)
        #expect(snapshot.capabilities.count == allFormats.count)
        #expect(snapshot.totalFormats == allFormats.count)
        #expect(!snapshot.routes.isEmpty)
        for route in snapshot.routes {
            #expect(route.source != route.target)
            if let targetFmt = FileFormat.from(extension: route.target) {
                #expect(capabilityRegistry.capability(for: targetFmt).canWrite)
            } else {
                Issue.record("Unrecognized target format in matrix route: \(route.target)")
            }
        }
        
        let jsonData = try ConversionMatrix.exportJSON(registry: registry)
        let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        #expect(parsed != nil)
        #expect((parsed?["routes"] as? [[String: Any]])?.count == snapshot.routes.count)
        
        // Compound extension stripping
        #expect(FileFormat.baseNameByStrippingExtension(from: URL(fileURLWithPath: "/tmp/backup.tar.gz")) == "backup")
        #expect(FileFormat.baseNameByStrippingExtension(from: URL(fileURLWithPath: "/tmp/backup.TAR.BZ2")) == "backup")
        #expect(FileFormat.baseNameByStrippingExtension(from: URL(fileURLWithPath: "/tmp/archive.tar.xz")) == "archive")
        #expect(FileFormat.baseNameByStrippingExtension(from: URL(fileURLWithPath: "/tmp/slides.pptx")) == "slides")
    }
    
    // MARK: - 2. Detection, Compound Extensions & Magic Bytes
    
    @Test("FileDetector handles compound archives, OpenXML-in-ZIP, and Phase 32 magic bytes")
    func testDetectionAndCompoundExtensions() throws {
        let dir = try createTempDir("Detect")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // Compound tar archive extensions
        let tgzURL = dir.appendingPathComponent("bundle.tar.gz")
        let tbz2URL = dir.appendingPathComponent("bundle.tar.bz2")
        let txzURL = dir.appendingPathComponent("bundle.tar.xz")
        let sample = dir.appendingPathComponent("hello.txt")
        try Data("hello world\n".utf8).write(to: sample)
        #expect(try runTool("/usr/bin/bsdtar", arguments: ["-czf", tgzURL.path, "-C", dir.path, "hello.txt"]).status == 0)
        #expect(try runTool("/usr/bin/bsdtar", arguments: ["-cjf", tbz2URL.path, "-C", dir.path, "hello.txt"]).status == 0)
        #expect(try runTool("/usr/bin/bsdtar", arguments: ["-cJf", txzURL.path, "-C", dir.path, "hello.txt"]).status == 0)
        
        #expect(detector.detect(url: tgzURL).bestFormat == .tgz)
        #expect(detector.detect(url: tbz2URL).bestFormat == .tbz2)
        #expect(detector.detect(url: txzURL).bestFormat == .txz)
        
        // Real DOCX/XLSX/PPTX renamed to .zip -> ZIP package inspection still identifies document type
        let docx = try TestFixtureFactory.createDOCX(in: dir, name: "doc.docx")
        let xlsx = try TestFixtureFactory.createXLSX(in: dir, name: "sheet.xlsx")
        let pptx = try TestFixtureFactory.createPPTX(in: dir, name: "deck.pptx")
        let docxAsZip = dir.appendingPathComponent("disguised_doc.zip")
        let xlsxAsZip = dir.appendingPathComponent("disguised_sheet.zip")
        let pptxAsZip = dir.appendingPathComponent("disguised_deck.zip")
        try FileManager.default.copyItem(at: docx, to: docxAsZip)
        try FileManager.default.copyItem(at: xlsx, to: xlsxAsZip)
        try FileManager.default.copyItem(at: pptx, to: pptxAsZip)
        #expect(detector.detect(url: docxAsZip).bestFormat == .docx)
        #expect(detector.detect(url: xlsxAsZip).bestFormat == .xlsx)
        #expect(detector.detect(url: pptxAsZip).bestFormat == .pptx)
        
        // Phase 32 image/subtitle/archive magic headers
        let qoiURL = dir.appendingPathComponent("magic.qoi")
        try Data([0x71, 0x6F, 0x69, 0x66, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x00]).write(to: qoiURL)
        #expect(detector.detect(url: qoiURL).bestFormat == .qoi)
        
        let rarURL = dir.appendingPathComponent("magic.rar")
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]).write(to: rarURL)
        #expect(detector.detect(url: rarURL).bestFormat == .rar)
        
        let vttURL = dir.appendingPathComponent("subs.vtt")
        try Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n".utf8).write(to: vttURL)
        #expect(detector.detect(url: vttURL).bestFormat == .vtt)
    }
    
    // MARK: - 3. Office & Document Universal Routes
    
    @Test("Office conversions cover legacy Binary <-> OpenXML <-> ODF <-> EPUB <-> MD <-> HTML (StarWriter)")
    func testOfficeUniversalRoutes() async throws {
        let dir = try createTempDir("Office")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let officeEngine = OfficeConversionEngine()
        guard await officeEngine.isAvailable() else {
            return
        }
        
        // 1. PPTX -> PPT -> PPTX
        let srcPptx = try TestFixtureFactory.createPPTX(in: dir, name: "deck.pptx", title: "Phase 32 Slide")
        let pptRes = try await officeEngine.convert(inputs: [srcPptx], to: .ppt, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(pptRes.outputURL.pathExtension == "ppt")
        let pptHeader = try Data(contentsOf: pptRes.outputURL).prefix(4)
        #expect(Array(pptHeader) == [0xD0, 0xCF, 0x11, 0xE0], "PPT must be valid OLE2 binary")
        
        let odpRes = try await officeEngine.convert(inputs: [srcPptx], to: .odp, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(odpRes.outputURL, pathFragment: "content.xml"))
        let pptxFromOdp = try await officeEngine.convert(inputs: [odpRes.outputURL], to: .pptx, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(pptxFromOdp.outputURL, pathFragment: "ppt/presentation.xml"))
        
        let roundtripPptx = try await officeEngine.convert(inputs: [pptRes.outputURL], to: .pptx, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(roundtripPptx.outputURL, pathFragment: "ppt/presentation.xml"))
        
        // 2. DOCX -> DOC -> DOCX + ODT + EPUB
        let srcDocx = try TestFixtureFactory.createDOCX(in: dir, name: "letter.docx", text: "Phase 32 Writer Test")
        let docRes = try await officeEngine.convert(inputs: [srcDocx], to: .doc, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(Array(try Data(contentsOf: docRes.outputURL).prefix(4)) == [0xD0, 0xCF, 0x11, 0xE0])
        let rtDocx = try await officeEngine.convert(inputs: [docRes.outputURL], to: .docx, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(rtDocx.outputURL, pathFragment: "word/document.xml"))
        
        let odtRes = try await officeEngine.convert(inputs: [srcDocx], to: .odt, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(odtRes.outputURL, pathFragment: "content.xml"))
        let docxFromOdt = try await officeEngine.convert(inputs: [odtRes.outputURL], to: .docx, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(docxFromOdt.outputURL, pathFragment: "word/document.xml"))
        
        let epubRes = try await officeEngine.convert(inputs: [srcDocx], to: .epub, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(epubRes.outputURL, pathFragment: "mimetype"))
        
        // 3. XLSX -> XLS -> XLSX + ODS
        let srcXlsx = try TestFixtureFactory.createXLSX(in: dir, name: "sheet.xlsx", text: "Budget", number: "42")
        let xlsRes = try await officeEngine.convert(inputs: [srcXlsx], to: .xls, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(Array(try Data(contentsOf: xlsRes.outputURL).prefix(4)) == [0xD0, 0xCF, 0x11, 0xE0])
        let rtXlsx = try await officeEngine.convert(inputs: [xlsRes.outputURL], to: .xlsx, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(rtXlsx.outputURL, pathFragment: "xl/workbook.xml"))
        
        let odsRes = try await officeEngine.convert(inputs: [srcXlsx], to: .ods, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(odsRes.outputURL, pathFragment: "content.xml"))
        let xlsxFromOds = try await officeEngine.convert(inputs: [odsRes.outputURL], to: .xlsx, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(xlsxFromOds.outputURL, pathFragment: "xl/workbook.xml"))
        
        // 4. HTML -> DOCX (requires --infilter="HTML (StarWriter)") & Markdown -> DOCX/PDF/HTML
        let htmlURL = dir.appendingPathComponent("page.html")
        try Data("<!DOCTYPE html><html><body><h1>Phase 32 HTML</h1><p>Hello Writer</p></body></html>".utf8).write(to: htmlURL)
        let docxFromHtml = try await officeEngine.convert(inputs: [htmlURL], to: .docx, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(docxFromHtml.outputURL, pathFragment: "word/document.xml"))
        
        let mdURL = dir.appendingPathComponent("notes.md")
        try Data("# Phase 32 Markdown\n\nParagraph with **bold** text.\n".utf8).write(to: mdURL)
        let docxFromMd = try await officeEngine.convert(inputs: [mdURL], to: .docx, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(docxFromMd.outputURL, pathFragment: "word/document.xml"))
        let pdfFromMd = try await officeEngine.convert(inputs: [mdURL], to: .pdf, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect((try Data(contentsOf: pdfFromMd.outputURL).prefix(4)) == Data("%PDF".utf8))
        let htmlFromMd = try await officeEngine.convert(inputs: [mdURL], to: .html, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect((try String(contentsOf: htmlFromMd.outputURL, encoding: .utf8)).lowercased().contains("<html"))
    }
    
    // MARK: - 4. Image & Animated Image Universal Routes
    
    @Test("Image engine supports ImageIO + FFmpeg raster codecs and animated GIF <-> APNG")
    func testImageUniversalRoutes() async throws {
        let dir = try createTempDir("Image")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let imageEngine = ImageConversionEngine()
        let srcPng = try TestFixtureFactory.createPNG(in: dir, name: "source.png", width: 64, height: 64)
        
        // New ImageIO & FFmpeg raster targets
        let targets: [FileFormat] = [.jp2, .psd, .exr, .ppm, .hdr, .qoi, .pcx, .wbmp]
        for fmt in targets {
            #expect(registry.canConvert(from: .png, to: fmt), "Expected PNG -> \(fmt.rawValue) route")
            let res = try await imageEngine.convert(inputs: [srcPng], to: fmt, outputDirectory: dir, options: ConversionOptions()) { _ in }
            #expect(FileManager.default.fileExists(atPath: res.outputURL.path))
            #expect(res.fileSize > 0)
            
            // Roundtrip decode back to PNG
            let backPng = try await imageEngine.convert(inputs: [res.outputURL], to: .png, outputDirectory: dir, options: ConversionOptions()) { _ in }
            let backSrc = CGImageSourceCreateWithURL(backPng.outputURL as CFURL, nil)
            #expect(backSrc != nil, "Roundtrip \(fmt.rawValue) -> PNG must produce readable PNG")
        }
        
        // Animated multi-frame GIF -> APNG -> GIF
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        if await provider.isAvailable(), let ffmpegPath = await provider.findFFmpegPath(), let ffprobePath = await provider.findFFprobePath() {
            let animGif = dir.appendingPathComponent("anim.gif")
            let gen = try runTool(ffmpegPath, arguments: [
                "-y", "-f", "lavfi", "-i", "testsrc=duration=0.6:size=64x64:rate=10", "-loop", "0", animGif.path
            ])
            #expect(gen.status == 0)
            
            let apngRes = try await imageEngine.convert(inputs: [animGif], to: .apng, outputDirectory: dir, options: ConversionOptions()) { _ in }
            let apngSrc = CGImageSourceCreateWithURL(apngRes.outputURL as CFURL, nil)
            #expect((apngSrc.map { CGImageSourceGetCount($0) } ?? 0) > 1, "Animated GIF -> APNG must keep multiple frames")
            
            let backGif = try await imageEngine.convert(inputs: [apngRes.outputURL], to: .gif, outputDirectory: dir, options: ConversionOptions()) { _ in }
            let probe = try runTool(ffprobePath, arguments: [
                "-v", "error", "-count_frames", "-select_streams", "v:0",
                "-show_entries", "stream=nb_read_frames", "-of", "default=nw=1:nk=1", backGif.outputURL.path
            ])
            #expect((Int(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 1)
        }
        
        // Negative read-only check & verified JXL support
        #expect(registry.canConvert(from: .png, to: .jxl))
        #expect(!registry.canConvert(from: .png, to: .sgi))
        #expect(!registry.canConvert(from: .png, to: .xpm))
    }
    
    // MARK: - 5. Audio & Video Universal Routes
    
    @Test("Media engine supports expanded Audio/Video targets and rejects video-only audio extraction")
    func testMediaUniversalRoutes() async throws {
        let dir = try createTempDir("Media")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard await provider.isAvailable(), let ffmpegPath = await provider.findFFmpegPath(), let ffprobePath = await provider.findFFprobePath() else {
            return
        }
        let engine = MediaConversionEngine(provider: provider)
        
        // Audio routes
        let wav = try TestFixtureFactory.createWAV(in: dir, name: "tone.wav", duration: 0.8)
        let audioTargets: [FileFormat] = [.wma, .au, .wv, .m4b, .mka, .eac3, .dts]
        for fmt in audioTargets {
            let res = try await engine.convert(inputs: [wav], to: fmt, outputDirectory: dir, options: ConversionOptions()) { _ in }
            let info = try await MediaProbe.probe(url: res.outputURL, ffprobePath: ffprobePath)
            #expect(info.hasAudio, "Output audio \(fmt.rawValue) must have audio stream")
        }
        
        // M4A ALAC lossless option
        var alacOptions = ConversionOptions()
        alacOptions.customOptions["m4a_lossless"] = "true"
        let alacM4a = try await engine.convert(inputs: [wav], to: .m4a, outputDirectory: dir, options: alacOptions) { _ in }
        let alacInfo = try await MediaProbe.probe(url: alacM4a.outputURL, ffprobePath: ffprobePath)
        #expect(alacInfo.primaryAudioStream?.codecName == "alac")
        
        // Video routes
        let mp4 = try await TestFixtureFactory.createMP4(in: dir, name: "clip.mp4", duration: 0.6)
        let videoTargets: [FileFormat] = [.threeG2, .m4v, .mpg, .ts, .flv, .f4v, .vob, .wmv, .m2v]
        for fmt in videoTargets {
            let res = try await engine.convert(inputs: [mp4], to: fmt, outputDirectory: dir, options: ConversionOptions()) { _ in }
            let info = try await MediaProbe.probe(url: res.outputURL, ffprobePath: ffprobePath)
            #expect(info.hasVideo, "Output video \(fmt.rawValue) must contain video stream")
        }
        
        // Video without audio track -> MP3 fails cleanly
        let videoOnly = dir.appendingPathComponent("silent.mp4")
        let genSilent = try runTool(ffmpegPath, arguments: [
            "-y", "-f", "lavfi", "-i", "testsrc=duration=0.5:size=160x120:rate=15", "-an", videoOnly.path
        ])
        #expect(genSilent.status == 0)
        do {
            _ = try await engine.convert(inputs: [videoOnly], to: .mp3, outputDirectory: dir, options: ConversionOptions()) { _ in }
            Issue.record("Expected video without audio stream to fail MP3 extraction")
        } catch {
            // Expected failure
        }
        
        // Negative read-only media checks
        #expect(!registry.canConvert(from: .wav, to: .amr))
        #expect(!registry.canConvert(from: .wav, to: .ape))
        #expect(!registry.canConvert(from: .mp4, to: .ogv))
    }
    
    // MARK: - 6. Subtitle Engine & Extraction
    
    @Test("Subtitle engine converts SRT/VTT/ASS/SSA, extracts text subs from MKV, and rejects SUP")
    func testSubtitleUniversalRoutes() async throws {
        let dir = try createTempDir("Subtitles")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let subEngine = SubtitleConversionEngine()
        guard await subEngine.isAvailable() else { return }
        
        let srtURL = dir.appendingPathComponent("sample.srt")
        let srtContent = """
        1
        00:00:00,500 --> 00:00:02,000
        LocalConvert Phase 32 Subtitle
        
        """
        try Data(srtContent.utf8).write(to: srtURL)
        
        let vttRes = try await subEngine.convert(inputs: [srtURL], to: .vtt, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect((try String(contentsOf: vttRes.outputURL, encoding: .utf8)).contains("WEBVTT"))
        
        let assRes = try await subEngine.convert(inputs: [vttRes.outputURL], to: .ass, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect((try String(contentsOf: assRes.outputURL, encoding: .utf8)).contains("[Script Info]"))
        
        let ssaRes = try await subEngine.convert(inputs: [assRes.outputURL], to: .ssa, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect((try String(contentsOf: ssaRes.outputURL, encoding: .utf8)).contains("LocalConvert Phase 32 Subtitle"))
        
        let srtBack = try await subEngine.convert(inputs: [ssaRes.outputURL], to: .srt, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect((try String(contentsOf: srtBack.outputURL, encoding: .utf8)).contains("LocalConvert Phase 32 Subtitle"))
        
        // Video with muxed text subtitle stream -> SRT
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        if let ffmpegPath = await provider.findFFmpegPath() {
            let mkvWithSubs = dir.appendingPathComponent("with_subs.mkv")
            let mkvGen = try runTool(ffmpegPath, arguments: [
                "-y", "-f", "lavfi", "-i", "testsrc=duration=2:size=160x120:rate=10",
                "-i", srtURL.path, "-c:v", "h264_videotoolbox", "-c:s", "srt", mkvWithSubs.path
            ])
            #expect(mkvGen.status == 0)
            
            let extracted = try await subEngine.convert(inputs: [mkvWithSubs], to: .srt, outputDirectory: dir, options: ConversionOptions()) { _ in }
            #expect((try String(contentsOf: extracted.outputURL, encoding: .utf8)).contains("LocalConvert Phase 32 Subtitle"))
        }
        
        // Negative: PGS .sup is never convertible
        #expect(!registry.canConvert(from: .sup, to: .srt))
        #expect(!subEngine.canConvert(from: .sup, to: .srt))
    }
    
    // MARK: - 7. Archive Engine & Security Guards
    
    @Test("Archive engine repacks multi-format containers, single-file streams, and blocks Zip Slip & symlinks")
    func testArchiveUniversalRoutesAndSecurity() async throws {
        let dir = try createTempDir("Archive")
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let archiveEngine = ArchiveConversionEngine()
        guard await archiveEngine.isAvailable() else { return }
        
        let payloadDir = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        let docFile = payloadDir.appendingPathComponent("readme.txt")
        let expectedText = "LocalConvert Archive Payload 32\n"
        try Data(expectedText.utf8).write(to: docFile)
        
        // Container chain: ZIP -> 7Z -> TAR -> TGZ (.tar.gz) -> TBZ2 (.tar.bz2) -> TXZ (.tar.xz) -> ZIP
        let srcZip = dir.appendingPathComponent("bundle.zip")
        #expect(try runTool("/usr/bin/bsdtar", arguments: ["-acf", srcZip.path, "-C", payloadDir.path, "readme.txt"]).status == 0)
        
        var current = srcZip
        let chain: [FileFormat] = [.sevenZ, .tar, .tgz, .tbz2, .txz, .zip]
        for nextFormat in chain {
            let res = try await archiveEngine.convert(inputs: [current], to: nextFormat, outputDirectory: dir, options: ConversionOptions()) { _ in }
            #expect(FileManager.default.fileExists(atPath: res.outputURL.path))
            #expect(res.fileSize > 0)
            current = res.outputURL
        }
        
        let verifyDir = dir.appendingPathComponent("verify")
        try FileManager.default.createDirectory(at: verifyDir, withIntermediateDirectories: true)
        #expect(try runTool("/usr/bin/bsdtar", arguments: ["-xf", current.path, "-C", verifyDir.path]).status == 0)
        let extractedText = try String(contentsOf: verifyDir.appendingPathComponent("readme.txt"), encoding: .utf8)
        #expect(extractedText == expectedText)
        
        // Single-file compression stream: GZ -> BZ2 -> ZIP
        let plainFile = dir.appendingPathComponent("notes.txt")
        try Data(expectedText.utf8).write(to: plainFile)
        #expect(try runTool("/usr/bin/gzip", arguments: ["-k", plainFile.path]).status == 0)
        let gzURL = dir.appendingPathComponent("notes.txt.gz")
        let bz2Res = try await archiveEngine.convert(inputs: [gzURL], to: .bz2, outputDirectory: dir, options: ConversionOptions()) { _ in }
        let zipFromBz2 = try await archiveEngine.convert(inputs: [bz2Res.outputURL], to: .zip, outputDirectory: dir, options: ConversionOptions()) { _ in }
        #expect(try zipContainsEntry(zipFromBz2.outputURL, pathFragment: "notes.txt"))
        
        // Security: symlink entry inside TAR must be blocked
        let symSource = dir.appendingPathComponent("sym_stage")
        try FileManager.default.createDirectory(at: symSource, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symSource.appendingPathComponent("escape_link").path, withDestinationPath: "/etc/hosts")
        let symTar = dir.appendingPathComponent("symlink.tar")
        #expect(try runTool("/usr/bin/bsdtar", arguments: ["-cf", symTar.path, "-C", symSource.path, "escape_link"]).status == 0)
        do {
            _ = try await archiveEngine.convert(inputs: [symTar], to: .zip, outputDirectory: dir, options: ConversionOptions()) { _ in }
            Issue.record("Expected archive containing symlink to be rejected")
        } catch {
            // Expected security rejection
        }
        
        // Security: Zip Slip path traversal entry inside TAR/ZIP must be blocked
        let traversalTar = dir.appendingPathComponent("traversal.tar")
        let pyZipSlip = """
        import tarfile, io
        data = b"pwned"
        info = tarfile.TarInfo(name="../evil.txt")
        info.size = len(data)
        with tarfile.open("\(traversalTar.path)", "w") as tf:
            tf.addfile(info, io.BytesIO(data))
        """
        #expect(try runTool("/usr/bin/python3", arguments: ["-c", pyZipSlip]).status == 0)
        do {
            _ = try await archiveEngine.convert(inputs: [traversalTar], to: .zip, outputDirectory: dir, options: ConversionOptions()) { _ in }
            Issue.record("Expected archive containing '../evil.txt' Zip Slip entry to be rejected")
        } catch {
            // Expected security rejection
        }
        
        // Security: Encrypted ZIP must be rejected without hanging
        let encZip = dir.appendingPathComponent("encrypted.zip")
        #expect(try runTool("/usr/bin/zip", arguments: ["-P", "secret123", "-j", encZip.path, docFile.path]).status == 0)
        do {
            _ = try await archiveEngine.convert(inputs: [encZip], to: .tar, outputDirectory: dir, options: ConversionOptions()) { _ in }
            Issue.record("Expected password-protected ZIP to be rejected")
        } catch {
            // Expected encryption rejection
        }
    }
}
