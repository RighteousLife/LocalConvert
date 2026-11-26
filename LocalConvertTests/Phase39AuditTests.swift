import Testing
import Foundation
import ImageIO
import PDFKit
@testable import LocalConvert

@Suite("Phase 39 — Product-Wide Audit Regression Tests")
struct Phase39AuditTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Phase39-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func findFFmpegPaths() async throws -> (ffmpeg: String, ffprobe: String) {
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        let ffmpeg = try #require(await provider.findFFmpegPath())
        let ffprobe = try #require(await provider.findFFprobePath())
        return (ffmpeg, ffprobe)
    }

    // MARK: - 1. Canon .cr3 Detection

    @Test("FileDetector identifies Canon CR3 ISOBMFF brand instead of misclassifying as MP4")
    func canonCR3NotMisdetectedAsMP4() throws {
        let dir = try makeTempDir("cr3")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cr3URL = dir.appendingPathComponent("IMG_0001.CR3")
        var header = Data([0x00, 0x00, 0x00, 0x18])
        header.append(Data("ftypcrx ".utf8))
        header.append(Data([0x00, 0x00, 0x00, 0x00]))
        header.append(Data("crx isom".utf8))
        try header.write(to: cr3URL)

        let detected = FileDetector().detect(url: cr3URL)
        #expect(detected.bestFormat == .cr3)
    }

    // MARK: - 2. AsyncProcessRunner Deadlock, TOCTOU & Cancellation

    @Test("AsyncProcessRunner handles fast exits, large stdout >64KB, and immediate cancellation safely")
    func asyncProcessRunnerStability() async throws {
        // Fast-exiting loop (checks TOCTOU terminationHandler)
        for _ in 0..<10 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            let out = try await AsyncProcessRunner.run(p)
            #expect(out.terminationStatus == 0)
        }

        // >200KB stdout exceeding 64KB kernel pipe buffer
        let bigProc = Process()
        bigProc.executableURL = URL(fileURLWithPath: "/bin/sh")
        bigProc.arguments = ["-c", "head -c 220000 /dev/zero | tr '\\0' 'A'"]
        let bigOut = try await AsyncProcessRunner.run(bigProc)
        #expect(bigOut.terminationStatus == 0)
        #expect(bigOut.stdout.count == 220_000)

        // Immediate cancellation must not crash with pre-launch terminate() exception
        let cancelTask = Task {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sleep")
            p.arguments = ["5"]
            return try await AsyncProcessRunner.run(p)
        }
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
            Issue.record("Cancelled sleep process should have thrown")
        } catch {
            // Expected CancellationError
        }
    }

    // MARK: - 3. Queue Cancellation Count, Preset Wedge Guard & Output Naming

    @MainActor
    @Test("ConversionQueue.cancelAll avoids double-counting, PresetManager.execute unwedges empty batches, and output affixes sanitize")
    func queueCancelPresetAndNaming() async throws {
        let dir = try makeTempDir("queue_preset")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("Report.v2.pdf")
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        pdfDoc.write(to: pdfURL)

        let manager = ConversionManager(registry: .shared)
        let queue = ConversionQueue(conversionManager: manager)

        let j1 = ConversionJob(inputURLs: [pdfURL], inputFormat: .pdf, outputFormat: .png, outputDirectory: dir)
        let j2 = ConversionJob(inputURLs: [pdfURL], inputFormat: .pdf, outputFormat: .png, outputDirectory: dir)
        queue.enqueue(jobs: [j1, j2])
        queue.cancelAll()
        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(queue.cancelledCount == 2)
        #expect(queue.activeJobCount == 0)

        // PresetManager.execute on incompatible files must not wedge appState.isConverting
        let state = AppState()
        state.addFiles(urls: [pdfURL])
        let audioOnlyPreset = SavedPreset(
            name: "Audio Only Test",
            targetFormat: .mp3,
            sourceCategoryConstraint: .audio,
            options: .default
        )
        let report = PresetManager.shared.execute(preset: audioOnlyPreset, on: state)
        #expect(report.enqueuedJobs.isEmpty)
        #expect(state.isConverting == false)

        // Prefix & suffix naming with path-traversal sanitization
        var opts = ConversionOptions.default
        opts.customOptions["output_prefix"] = "../pre/"
        opts.customOptions["output_suffix"] = "_audio"
        let namedURL = ConversionManager.outputURL(for: pdfURL, format: .mp3, in: dir, options: opts)
        #expect(namedURL.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(namedURL.lastPathComponent.contains("Report.v2_audio"))
        #expect(namedURL.pathExtension == "mp3")
    }

    // MARK: - 4. PDFToolboxEngine Dotted Filename Preservation

    @Test("PDFToolboxEngine preserves dotted filenames when creating extract outputs")
    func pdfToolboxDottedFilenamePreserved() async throws {
        let dir = try makeTempDir("pdf_dots")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("Quarterly.Report.v2.pdf")
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        doc.insert(PDFPage(), at: 1)
        #expect(doc.write(to: pdfURL))

        var opts = ConversionOptions.default
        opts.customOptions["pdf_operation"] = "extract"
        opts.customOptions["pdf_pages"] = "1"
        let res = try await PDFToolboxEngine().convert(inputs: [pdfURL], to: .pdf, outputDirectory: dir, options: opts) { _ in }
        #expect(res.outputURL.lastPathComponent == "Quarterly.Report.v2_extract.pdf")
    }

    // MARK: - 5. Metadata Privacy Strip Truthfulness Across All Providers

    @Test("Metadata Clear All / Strip All genuinely removes EXIF/XMP/GPS/ID3/QuickTime/Office/PDF tags on disk")
    func fullMetadataStripVerification() async throws {
        let dir = try makeTempDir("meta_strip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (ffmpeg, ffprobe) = try await findFFmpegPaths()

        // 5A. Image (JPEG with EXIF DateTimeOriginal, Software, ExifAux, GPS, XMP)
        let jpgURL = dir.appendingPathComponent("photo.jpg")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let cg = try #require(ctx.makeImage())
        let imgDest = try #require(CGImageDestinationCreateWithURL(jpgURL as CFURL, "public.jpeg" as CFString, 1, nil))
        let xmp = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(xmp, nil, "dc:creator" as CFString, "SecretAuthor" as CFString)
        let imgProps: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "SecretSoft", kCGImagePropertyTIFFMake: "Canon"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00", kCGImagePropertyExifUserComment: "HiddenComment"],
            kCGImagePropertyExifAuxDictionary: [kCGImagePropertyExifAuxSerialNumber: "SN999"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImageDestinationMetadata: xmp
        ]
        CGImageDestinationAddImage(imgDest, cg, imgProps as CFDictionary)
        #expect(CGImageDestinationFinalize(imgDest))

        var stripPayload = ImageMetadataEditPayload()
        stripPayload.policy = .stripAll
        try await ImageMetadataService.writePrivacyCleaned(url: jpgURL, payload: stripPayload)
        let checkSrc = try #require(CGImageSourceCreateWithURL(jpgURL as CFURL, nil))
        let checkProps = (CGImageSourceCopyPropertiesAtIndex(checkSrc, 0, nil) as? [String: Any]) ?? [:]
        #expect(checkProps[kCGImagePropertyExifDictionary as String] == nil)
        #expect(checkProps[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(checkProps[kCGImagePropertyTIFFDictionary as String] == nil)
        #expect(checkProps[kCGImagePropertyExifAuxDictionary as String] == nil)
        let checkXMP = CGImageSourceCopyMetadataAtIndex(checkSrc, 0, nil)
        let xmpTags = checkXMP.flatMap { CGImageMetadataCopyTags($0) as? [Any] } ?? []
        #expect(xmpTags.isEmpty)

        // 5B. Audio (MP3 with ID3, custom TXXX, and artwork -> stripped completely)
        let mp3URL = dir.appendingPathComponent("track.mp3")
        let artURL = dir.appendingPathComponent("art.png")
        let artDest = try #require(CGImageDestinationCreateWithURL(artURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(artDest, cg, nil)
        #expect(CGImageDestinationFinalize(artDest))

        let makeMP3 = Process()
        makeMP3.executableURL = URL(fileURLWithPath: ffmpeg)
        makeMP3.arguments = [
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.4",
            "-i", artURL.path,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "libmp3lame", "-c:v", "png", "-disposition:v", "attached_pic",
            "-metadata", "title=TopSecret", "-metadata", "TXXX=CustomSecret",
            mp3URL.path
        ]
        let mp3CreateOut = try await AsyncProcessRunner.run(makeMP3)
        #expect(mp3CreateOut.terminationStatus == 0)

        let audioProvider = AudioMetadataProvider()
        var cleanAudioDoc = MetadataDocument(format: .mp3, fileURL: mp3URL)
        cleanAudioDoc.isStrippedAll = true
        _ = try await audioProvider.writeMetadata(cleanAudioDoc, to: mp3URL)

        let probeMP3 = Process()
        probeMP3.executableURL = URL(fileURLWithPath: ffprobe)
        probeMP3.arguments = ["-v", "quiet", "-show_format", "-show_streams", "-print_format", "json", mp3URL.path]
        let mp3ProbeStr = String(data: try await AsyncProcessRunner.run(probeMP3).stdout, encoding: .utf8) ?? ""
        #expect(!mp3ProbeStr.contains("CustomSecret"))
        #expect(!mp3ProbeStr.contains("TopSecret"))
        #expect(!mp3ProbeStr.contains("\"codec_type\": \"video\""))

        // 5C. Video (MP4 with QuickTime location & title -> stripped completely)
        let mp4URL = dir.appendingPathComponent("clip.mp4")
        let makeMP4 = Process()
        makeMP4.executableURL = URL(fileURLWithPath: ffmpeg)
        makeMP4.arguments = [
            "-y", "-f", "lavfi", "-i", "color=c=blue:s=64x64:d=0.3",
            "-c:v", "mpeg4",
            "-metadata", "title=SecretClip",
            "-metadata", "com.apple.quicktime.location.ISO6709=+41.0000+029.0000/",
            mp4URL.path
        ]
        let mp4Out = try await AsyncProcessRunner.run(makeMP4)
        #expect(mp4Out.terminationStatus == 0)

        let videoProvider = VideoMetadataProvider()
        var cleanVideoDoc = MetadataDocument(format: .mp4, fileURL: mp4URL)
        cleanVideoDoc.isStrippedAll = true
        _ = try await videoProvider.writeMetadata(cleanVideoDoc, to: mp4URL)

        let probeMP4 = Process()
        probeMP4.executableURL = URL(fileURLWithPath: ffprobe)
        probeMP4.arguments = ["-v", "quiet", "-show_format", "-print_format", "json", mp4URL.path]
        let mp4ProbeStr = String(data: try await AsyncProcessRunner.run(probeMP4).stdout, encoding: .utf8) ?? ""
        #expect(!mp4ProbeStr.contains("SecretClip"))
        #expect(!mp4ProbeStr.contains("+41.0000"))

        // 5D. Office (.docx with XML attribute, escaped entity, app.xml Company, custom.xml Secret)
        let docxStage = dir.appendingPathComponent("docx_stage", isDirectory: true)
        let docProps = docxStage.appendingPathComponent("docProps", isDirectory: true)
        try FileManager.default.createDirectory(at: docProps, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title xml:lang="en">Alpha &amp; Omega</dc:title>
            <dc:creator>Jane Doe</dc:creator>
        </cp:coreProperties>
        """.write(to: docProps.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)
        try "<Properties><Company>SecretCorp</Company></Properties>".write(to: docProps.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)
        try "<Properties><property name=\"Internal\"/></Properties>".write(to: docProps.appendingPathComponent("custom.xml"), atomically: true, encoding: .utf8)

        let docxURL = dir.appendingPathComponent("doc.docx")
        let zipMake = Process()
        zipMake.currentDirectoryURL = docxStage
        zipMake.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipMake.arguments = ["-r", docxURL.path, "docProps"]
        #expect(try await AsyncProcessRunner.run(zipMake).terminationStatus == 0)

        let officeProvider = OfficeMetadataProvider()
        let readOffice = try await officeProvider.readMetadata(from: docxURL)
        #expect(readOffice.common.title == "Alpha & Omega")

        var stripOffice = MetadataDocument(format: .docx, fileURL: docxURL)
        stripOffice.isStrippedAll = true
        _ = try await officeProvider.writeMetadata(stripOffice, to: docxURL)

        let coreRead = Process()
        coreRead.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        coreRead.arguments = ["-p", docxURL.path, "docProps/core.xml"]
        let coreStr = String(data: try await AsyncProcessRunner.run(coreRead).stdout, encoding: .utf8) ?? ""
        #expect(!coreStr.contains("LocalConvert"))
        #expect(!coreStr.contains("Jane Doe"))

        let appRead = Process()
        appRead.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        appRead.arguments = ["-p", docxURL.path, "docProps/app.xml"]
        let appStr = String(data: try await AsyncProcessRunner.run(appRead).stdout, encoding: .utf8) ?? ""
        #expect(!appStr.contains("SecretCorp"))

        // 5E. PDF (Info attributes + embedded XMP packet stripped cleanly)
        let pdfMetaURL = dir.appendingPathComponent("secret.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let pdfInfo: [CFString: Any] = [kCGPDFContextTitle: "ConfidentialPDF", kCGPDFContextAuthor: "SecretAuthor"]
        let pdfCtx = try #require(CGContext(pdfMetaURL as CFURL, mediaBox: &box, pdfInfo as CFDictionary))
        pdfCtx.beginPDFPage(nil); pdfCtx.endPDFPage(); pdfCtx.closePDF()

        let pdfProvider = PDFMetadataProvider()
        var stripPDF = MetadataDocument(format: .pdf, fileURL: pdfMetaURL)
        stripPDF.isStrippedAll = true
        _ = try await pdfProvider.writeMetadata(stripPDF, to: pdfMetaURL)

        let verifiedPDF = try #require(PDFDocument(url: pdfMetaURL))
        #expect((verifiedPDF.documentAttributes ?? [:]).isEmpty)
        let pdfBytesStr = String(data: try Data(contentsOf: pdfMetaURL), encoding: .isoLatin1) ?? ""
        #expect(!pdfBytesStr.contains("SecretAuthor"))
        #expect(!pdfBytesStr.contains("ConfidentialPDF"))
    }
}
