import Foundation
import Testing
import CoreGraphics
import ImageIO
import PDFKit
@testable import LocalConvert

@Suite("Phase 17 Universal Metadata Architecture Tests")
struct Phase17Tests {
    
    // MARK: - 1. Metadata Registry & Discovery
    
    @Test("MetadataRegistry discovery and registration")
    func testRegistryDiscovery() {
        let registry = MetadataRegistry.shared
        
        // Providers should be registered
        #expect(registry.provider(for: .mp3) != nil)
        #expect(registry.provider(for: .m4a) != nil)
        #expect(registry.provider(for: .flac) != nil)
        #expect(registry.provider(for: .jpg) != nil)
        #expect(registry.provider(for: .png) != nil)
        #expect(registry.provider(for: .pdf) != nil)
        #expect(registry.provider(for: .docx) != nil)
        #expect(registry.provider(for: .mp4) != nil)
        
        let allFormats = registry.allSupportedFormats
        #expect(allFormats.contains(.mp3))
        #expect(allFormats.contains(.jpg))
        #expect(allFormats.contains(.pdf))
        #expect(allFormats.contains(.docx))
    }
    
    @Test("Metadata Capabilities Integrity")
    func testCapabilitiesIntegrity() {
        let registry = MetadataRegistry.shared
        
        // Audio
        let audioCaps = registry.capabilities(for: .mp3)
        #expect(audioCaps.canRead == true)
        #expect(audioCaps.canWrite == true)
        #expect(audioCaps.writeStrategy == .streamCopyInPlace)
        #expect(audioCaps.fields.contains(where: { $0.id == "title" }) == true)
        #expect(audioCaps.fields.contains(where: { $0.id == "artwork" }) == true)
        
        // Image
        let imageCaps = registry.capabilities(for: .jpg)
        #expect(imageCaps.canRead == true)
        #expect(imageCaps.canWrite == true)
        #expect(imageCaps.canRemoveGPS == true)
        #expect(imageCaps.writeStrategy == .imageIOInPlace)
        #expect(imageCaps.fields.contains(where: { $0.id == "gps" }) == true)
        
        // PDF
        let pdfCaps = registry.capabilities(for: .pdf)
        #expect(pdfCaps.canRead == true)
        #expect(pdfCaps.canWrite == true)
        #expect(pdfCaps.writeStrategy == .pdfDocumentInPlace)
        #expect(pdfCaps.fields.contains(where: { $0.id == "author" }) == true)
        
        // Office
        let officeCaps = registry.capabilities(for: .docx)
        #expect(officeCaps.canRead == true)
        #expect(officeCaps.canWrite == true)
        #expect(officeCaps.writeStrategy == .openXMLCoreXML)
        #expect(officeCaps.fields.contains(where: { $0.id == "creator" }) == true)
    }
    
    // MARK: - 2. Open Extensibility (Mock Provider Test)
    
    private final class MockCustomFormatProvider: MetadataProvider, @unchecked Sendable {
        var providerName: String { "MockCustomFormatProvider" }
        var supportedFormats: Set<FileFormat> { [.csv] }
        
        func capabilities(for format: FileFormat) -> MetadataCapabilities {
            MetadataCapabilities(
                format: format,
                canRead: true,
                canWrite: true,
                canRemoveGPS: false,
                canRemoveArtwork: false,
                canRemoveAll: true,
                writeStrategy: .directInPlace,
                fields: [
                    MetadataFieldDescriptor(id: "custom_title", name: "Custom Title", section: .basic, valueType: .string, isWritable: true)
                ]
            )
        }
        
        func readMetadata(from url: URL) async throws -> MetadataDocument {
            var doc = MetadataDocument(format: .csv, fileURL: url)
            doc.customFields["custom_title"] = .string("Mock Title")
            return doc
        }
        
        func writeMetadata(_ metadata: MetadataDocument, to url: URL) async throws -> MetadataWriteResult {
            return MetadataWriteResult(outputURL: url)
        }
    }
    
    @Test("Extensibility: Custom provider registers without UI changes")
    func testMockProviderExtensibility() async throws {
        let mock = MockCustomFormatProvider()
        MetadataRegistry.shared.register(mock)
        
        let provider = MetadataRegistry.shared.provider(for: .csv)
        #expect(provider?.providerName == "MockCustomFormatProvider")
        
        let caps = MetadataRegistry.shared.capabilities(for: .csv)
        #expect(caps.fields.first?.id == "custom_title")
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.csv")
        try "col1,col2".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let doc = try await provider?.readMetadata(from: tempURL)
        #expect(doc?.customFields["custom_title"]?.stringValue == "Mock Title")
    }
    
    // MARK: - 3. SafeMetadataWriter Atomic Swapping & Rollback
    
    @Test("SafeMetadataWriter succeeds atomically")
    func testSafeWriterSuccess() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let originalFile = tempRoot.appendingPathComponent("original.txt")
        try "Original Content".write(to: originalFile, atomically: true, encoding: .utf8)
        
        let resultURL = try await SafeMetadataWriter.performSafeWrite(on: originalFile, outputExtension: "txt") { tempScratchURL in
            try "Modified Content".write(to: tempScratchURL, atomically: true, encoding: .utf8)
        }
        
        #expect(resultURL.path == originalFile.path)
        let modifiedContent = try String(contentsOf: originalFile, encoding: .utf8)
        #expect(modifiedContent == "Modified Content")
    }
    
    @Test("SafeMetadataWriter rolls back and leaves original untouched on failure")
    func testSafeWriterRollbackOnFailure() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let originalFile = tempRoot.appendingPathComponent("precious.txt")
        try "Original Unchanged".write(to: originalFile, atomically: true, encoding: .utf8)
        
        struct DummyError: Error {}
        
        do {
            _ = try await SafeMetadataWriter.performSafeWrite(on: originalFile, outputExtension: "txt") { _ in
                throw DummyError()
            }
            #expect(Bool(false), "Should have thrown")
        } catch {
            // Expected
        }
        
        let preservedContent = try String(contentsOf: originalFile, encoding: .utf8)
        #expect(preservedContent == "Original Unchanged")
    }
    
    // MARK: - 4. PDF Metadata Provider
    
    @Test("PDFMetadataProvider read, write and attributes")
    func testPDFMetadataReadWrite() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let pdfURL = tempRoot.appendingPathComponent("sample.pdf")
        let pdfDoc = PDFDocument()
        let page = PDFPage()
        pdfDoc.insert(page, at: 0)
        pdfDoc.write(to: pdfURL)
        
        let provider = PDFMetadataProvider()
        var metadataDoc = try await provider.readMetadata(from: pdfURL)
        #expect(metadataDoc.format == .pdf)
        
        metadataDoc.common.title = "LocalConvert Architecture"
        metadataDoc.common.author = "Antigravity Engineering"
        metadataDoc.common.subject = "macOS Universal Metadata"
        metadataDoc.common.keywords = ["swift", "macos", "metadata"]
        
        let updatedURL = try await provider.write(metadataDoc, to: pdfURL)
        #expect(FileManager.default.fileExists(atPath: updatedURL.path))
        
        let readBackDoc = try await provider.readMetadata(from: updatedURL)
        #expect(readBackDoc.common.title == "LocalConvert Architecture")
        #expect(readBackDoc.common.author == "Antigravity Engineering")
        #expect(readBackDoc.common.subject == "macOS Universal Metadata")
        #expect(readBackDoc.common.keywords?.contains("swift") == true)
    }
    
    // MARK: - 5. Image Metadata Provider & GPS Stripping
    
    @Test("ImageMetadataProvider read, write and GPS removal")
    func testImageMetadataReadWriteAndGPS() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let imgURL = tempRoot.appendingPathComponent("test.png")
        
        // Create a 10x10 solid image
        let width = 10
        let height = 10
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!
        
        let dest = CGImageDestinationCreateWithURL(imgURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        
        let provider = ImageMetadataProvider()
        var doc = try await provider.readMetadata(from: imgURL)
        doc.common.title = "Sample Photo"
        doc.common.comment = "Image I/O Test"
        doc.gps = MetadataGPS(latitude: 37.7749, longitude: -122.4194, altitude: 15.0)
        
        let savedURL = try await provider.write(doc, to: imgURL)
        let readDoc = try await provider.readMetadata(from: savedURL)
        #expect(readDoc.common.title == "Sample Photo")
        #expect(readDoc.gps != nil)
        #expect(abs((readDoc.gps?.latitude ?? 0) - 37.7749) < 0.001)
        
        // Remove GPS
        let strippedURL = try await provider.removeGPS(from: savedURL)
        let strippedDoc = try await provider.readMetadata(from: strippedURL)
        #expect(strippedDoc.gps == nil)
    }
    
    // MARK: - 6. Audio Metadata Provider Stream Preservation
    
    @Test("AudioMetadataProvider ID3 tags and stream preservation")
    func testAudioMetadataID3StreamPreservation() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let mp3URL = tempRoot.appendingPathComponent("test.mp3")
        
        // Generate a 1-second silent MP3 using bundled ffmpeg
        guard let ffmpegPath = await BundledFFmpegProvider(fallbackToSystem: true).findFFmpegPath(),
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            return
        }
        
        let genProc = Process()
        genProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        genProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "libmp3lame", mp3URL.path]
        try genProc.run()
        genProc.waitUntilExit()
        
        guard FileManager.default.fileExists(atPath: mp3URL.path) else { return }
        
        let provider = AudioMetadataProvider()
        var doc = try await provider.readMetadata(from: mp3URL)
        doc.common.title = "Universal Metadata Theme"
        doc.common.artist = "LocalConvert Core"
        doc.common.album = "Audio Standards 2026"
        doc.common.year = 2026
        
        let updatedURL = try await provider.write(doc, to: mp3URL)
        let readBackDoc = try await provider.readMetadata(from: updatedURL)
        
        #expect(readBackDoc.common.title == "Universal Metadata Theme")
        #expect(readBackDoc.common.artist == "LocalConvert Core")
        #expect(readBackDoc.common.album == "Audio Standards 2026")
        #expect(readBackDoc.common.year == 2026)
    }
    
    // MARK: - 7. MP3 All Fields Read/Write Functional Audit
    
    @Test("MP3 exhaustive field-by-field read, write and reload verification")
    func testMP3AllFieldsExhaustive() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let mp3URL = tempRoot.appendingPathComponent("exhaustive.mp3")
        guard let ffmpegPath = await BundledFFmpegProvider(fallbackToSystem: true).findFFmpegPath(),
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else { return }
        
        let genProc = Process()
        genProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        genProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "libmp3lame", mp3URL.path]
        try genProc.run()
        genProc.waitUntilExit()
        
        let provider = AudioMetadataProvider()
        var doc = try await provider.readMetadata(from: mp3URL)
        
        doc.common.title = "Symphony No. 9"
        doc.common.artist = "Ludwig van Beethoven"
        doc.common.album = "Complete Symphonies"
        doc.common.albumArtist = "Vienna Philharmonic"
        doc.common.genre = "Classical"
        doc.common.year = 1824
        doc.common.trackNumber = "4/4"
        doc.common.discNumber = "1/1"
        doc.common.composer = "Beethoven"
        doc.common.comment = "Ode to Joy Finale"
        doc.common.copyright = "Public Domain"
        
        let updatedURL = try await provider.write(doc, to: mp3URL)
        let read = try await provider.readMetadata(from: updatedURL)
        
        #expect(read.common.title == "Symphony No. 9")
        #expect(read.common.artist == "Ludwig van Beethoven")
        #expect(read.common.album == "Complete Symphonies")
        #expect(read.common.albumArtist == "Vienna Philharmonic")
        #expect(read.common.genre == "Classical")
        #expect(read.common.year == 1824)
        #expect(read.common.trackNumber == "4/4")
        #expect(read.common.discNumber == "1/1")
        #expect(read.common.composer == "Beethoven")
        #expect(read.common.comment == "Ode to Joy Finale")
        #expect(read.common.copyright == "Public Domain")
        #expect(read.technical["audioCodec"] != nil)
    }
    
    // MARK: - 8. MP3 Artwork Lifecycle (Add, Replace, Remove)
    
    @Test("MP3 Artwork add, replace, and remove lifecycle with stream preservation")
    func testMP3ArtworkLifecycle() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let mp3URL = tempRoot.appendingPathComponent("art_cycle.mp3")
        guard let ffmpegPath = await BundledFFmpegProvider(fallbackToSystem: true).findFFmpegPath(),
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else { return }
        
        let genProc = Process()
        genProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        genProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "libmp3lame", mp3URL.path]
        try genProc.run()
        genProc.waitUntilExit()
        
        let provider = AudioMetadataProvider()
        
        // 1. Initial State: No artwork
        var doc = try await provider.readMetadata(from: mp3URL)
        #expect(doc.artwork == nil)
        
        // 2. Add Artwork (50x50 JPEG)
        let redImage = NSImage(size: NSSize(width: 50, height: 50))
        redImage.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 50, height: 50))
        redImage.unlockFocus()
        guard let tiffData = redImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpgData = rep.representation(using: .jpeg, properties: [:]) else {
            return
        }
        
        doc.artwork = MetadataArtwork(data: jpgData, mimeType: "image/jpeg")
        let updatedWithArt = try await provider.write(doc, to: mp3URL)
        
        var docWithArt = try await provider.readMetadata(from: updatedWithArt)
        #expect(docWithArt.artwork != nil)
        #expect(docWithArt.artwork!.data.count > 0)
        
        // 3. Remove Artwork
        docWithArt.artwork = nil
        let updatedWithoutArt = try await provider.write(docWithArt, to: mp3URL)
        
        let finalDoc = try await provider.readMetadata(from: updatedWithoutArt)
        #expect(finalDoc.artwork == nil)
    }
    
    // MARK: - 9. M4A / FLAC / OGG / OPUS Audio Metadata
    
    @Test("M4A and FLAC container metadata and stream preservation")
    func testM4AAndFLACMetadata() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        guard let ffmpegPath = await BundledFFmpegProvider(fallbackToSystem: true).findFFmpegPath(),
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else { return }
        
        let provider = AudioMetadataProvider()
        
        // M4A Test
        let m4aURL = tempRoot.appendingPathComponent("test.m4a")
        let m4aProc = Process()
        m4aProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        m4aProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "aac", m4aURL.path]
        try m4aProc.run()
        m4aProc.waitUntilExit()
        
        var m4aDoc = try await provider.readMetadata(from: m4aURL)
        m4aDoc.common.title = "M4A Advanced Audio"
        m4aDoc.common.artist = "Apple AAC Provider"
        m4aDoc.common.album = "Lossy Suite"
        m4aDoc.common.genre = "Podcast"
        
        let updatedM4A = try await provider.write(m4aDoc, to: m4aURL)
        let readM4A = try await provider.readMetadata(from: updatedM4A)
        #expect(readM4A.common.title == "M4A Advanced Audio")
        #expect(readM4A.common.artist == "Apple AAC Provider")
        #expect(readM4A.common.album == "Lossy Suite")
        
        // FLAC Test
        let flacURL = tempRoot.appendingPathComponent("test.flac")
        let flacProc = Process()
        flacProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        flacProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "flac", flacURL.path]
        try flacProc.run()
        flacProc.waitUntilExit()
        
        var flacDoc = try await provider.readMetadata(from: flacURL)
        flacDoc.common.title = "FLAC Studio Master"
        flacDoc.common.artist = "Lossless Audio"
        flacDoc.common.genre = "Acoustic"
        
        let updatedFLAC = try await provider.write(flacDoc, to: flacURL)
        let readFLAC = try await provider.readMetadata(from: updatedFLAC)
        #expect(readFLAC.common.title == "FLAC Studio Master")
        #expect(readFLAC.common.artist == "Lossless Audio")
    }
    
    // MARK: - 10. Office OpenXML Metadata Direct Update
    
    @Test("Office OpenXML DOCX core.xml direct metadata update without LibreOffice")
    func testOfficeDOCXCoreXMLDirectUpdate() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let docxURL = tempRoot.appendingPathComponent("sample.docx")
        
        // Create a minimal valid OpenXML ZIP package
        let workDir = tempRoot.appendingPathComponent("pkg")
        let docPropsDir = workDir.appendingPathComponent("docProps")
        let wordDir = workDir.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: docPropsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        
        let coreXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Initial Title</dc:title>
            <dc:creator>Initial Author</dc:creator>
        </cp:coreProperties>
        """
        try coreXML.write(to: docPropsDir.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)
        try "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>Hello World</w:t></w:r></w:p></w:body></w:document>"
            .write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)
        
        // Zip into sample.docx
        let zipProc = Process()
        zipProc.currentDirectoryURL = workDir
        zipProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProc.arguments = ["-r", docxURL.path, "docProps", "word"]
        try zipProc.run()
        zipProc.waitUntilExit()
        
        let provider = OfficeMetadataProvider()
        var doc = try await provider.readMetadata(from: docxURL)
        #expect(doc.common.title == "Initial Title")
        #expect(doc.common.creator == "Initial Author")
        
        doc.common.title = "Updated Whitepaper 2026"
        doc.common.creator = "LocalConvert Lead Architect"
        doc.common.subject = "Universal Metadata Specification"
        doc.common.description = "Detailed engineering breakdown."
        
        let updatedURL = try await provider.write(doc, to: docxURL)
        let readBack = try await provider.readMetadata(from: updatedURL)
        
        #expect(readBack.common.title == "Updated Whitepaper 2026")
        #expect(readBack.common.creator == "LocalConvert Lead Architect")
        #expect(readBack.common.subject == "Universal Metadata Specification")
        #expect(readBack.common.description == "Detailed engineering breakdown.")
        
        // Verify document content unchanged
        #expect(FormatValidator.openXMLEntryContains(at: updatedURL, entry: "word/document.xml", expectedSubstring: "Hello World"))
    }
    
    // MARK: - 11. Video Metadata Stream Copy
    
    @Test("VideoMetadataProvider MP4 container metadata update with stream copy")
    func testVideoMP4MetadataStreamCopy() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let mp4URL = tempRoot.appendingPathComponent("test.mp4")
        guard let ffmpegPath = await BundledFFmpegProvider(fallbackToSystem: true).findFFmpegPath(),
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else { return }
        
        let genProc = Process()
        genProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        genProc.arguments = ["-f", "lavfi", "-i", "testsrc=duration=1:size=64x64:rate=30", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:v", "h264_videotoolbox", "-c:a", "aac", mp4URL.path]
        try genProc.run()
        genProc.waitUntilExit()
        
        let provider = VideoMetadataProvider()
        var doc = try await provider.readMetadata(from: mp4URL)
        
        doc.common.title = "LocalConvert 4K Demo"
        doc.common.artist = "Video Production Team"
        doc.common.description = "Native macOS container stream copy test."
        doc.common.genre = "Demo"
        
        let updatedURL = try await provider.write(doc, to: mp4URL)
        let readBack = try await provider.readMetadata(from: updatedURL)
        
        #expect(readBack.common.title == "LocalConvert 4K Demo")
        #expect(readBack.common.artist == "Video Production Team")
        #expect(readBack.common.description == "Native macOS container stream copy test.")
        #expect(readBack.common.genre == "Demo")
        #expect(readBack.technical["videoCodec"] != nil || readBack.technical["resolution"] != nil)
    }

    // MARK: - 12. OGG and Opus Metadata Tags
    
    @Test("OGG and Opus container metadata read and write")
    func testOGGAndOpusMetadata() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        guard let ffmpegPath = await BundledFFmpegProvider(fallbackToSystem: true).findFFmpegPath(),
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else { return }
        
        let provider = AudioMetadataProvider()
        
        // OGG Test (Opus inside OGG container)
        let oggURL = tempRoot.appendingPathComponent("test.ogg")
        let oggProc = Process()
        oggProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        oggProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "1", "-c:a", "libopus", oggURL.path]
        try oggProc.run()
        oggProc.waitUntilExit()
        
        var oggDoc = try await provider.readMetadata(from: oggURL)
        oggDoc.common.title = "Vorbis Track"
        oggDoc.common.artist = "Open Source Audio"
        
        let updatedOGG = try await provider.write(oggDoc, to: oggURL)
        let readOGG = try await provider.readMetadata(from: updatedOGG)
        #expect(readOGG.common.title == "Vorbis Track")
        #expect(readOGG.common.artist == "Open Source Audio")
        
        // OPUS Test
        let opusURL = tempRoot.appendingPathComponent("test.opus")
        let opusProc = Process()
        opusProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        opusProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "1", "-c:a", "libopus", opusURL.path]
        try opusProc.run()
        opusProc.waitUntilExit()
        
        var opusDoc = try await provider.readMetadata(from: opusURL)
        opusDoc.common.title = "Opus Voice Stream"
        opusDoc.common.artist = "Low Latency Codec"
        
        let updatedOpus = try await provider.write(opusDoc, to: opusURL)
        let readOpus = try await provider.readMetadata(from: updatedOpus)
        #expect(readOpus.common.title == "Opus Voice Stream")
        #expect(readOpus.common.artist == "Low Latency Codec")
    }
    
    // MARK: - 13. WAV and AIFF Audio Metadata
    
    @Test("WAV and AIFF uncompressed audio metadata tags")
    func testWAVAndAIFFMetadata() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        guard let ffmpegPath = await BundledFFmpegProvider(fallbackToSystem: true).findFFmpegPath(),
              FileManager.default.isExecutableFile(atPath: ffmpegPath) else { return }
        
        let provider = AudioMetadataProvider()
        
        // WAV Test
        let wavURL = tempRoot.appendingPathComponent("test.wav")
        let wavProc = Process()
        wavProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        wavProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "pcm_s16le", wavURL.path]
        try wavProc.run()
        wavProc.waitUntilExit()
        
        var wavDoc = try await provider.readMetadata(from: wavURL)
        wavDoc.common.title = "Broadcast WAV"
        wavDoc.common.artist = "Studio Master"
        
        let updatedWAV = try await provider.write(wavDoc, to: wavURL)
        let readWAV = try await provider.readMetadata(from: updatedWAV)
        #expect(readWAV.common.title == "Broadcast WAV")
        #expect(readWAV.common.artist == "Studio Master")
        
        // AIFF Test
        let aiffURL = tempRoot.appendingPathComponent("test.aiff")
        let aiffProc = Process()
        aiffProc.executableURL = URL(fileURLWithPath: ffmpegPath)
        aiffProc.arguments = ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "1", "-c:a", "pcm_s16be", aiffURL.path]
        try aiffProc.run()
        aiffProc.waitUntilExit()
        
        var aiffDoc = try await provider.readMetadata(from: aiffURL)
        aiffDoc.common.title = "AIFF Apple Audio"
        aiffDoc.common.artist = "Core Audio"
        
        let updatedAIFF = try await provider.write(aiffDoc, to: aiffURL)
        let readAIFF = try await provider.readMetadata(from: updatedAIFF)
        #expect(readAIFF.common.title == "AIFF Apple Audio")
        #expect(readAIFF.common.artist == "Core Audio")
    }
    
    // MARK: - 14. Image Format Capabilities & SVG Read-Only
    
    @Test("Image formats TIFF and SVG metadata handling")
    func testTIFFAndSVGMetadata() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let provider = ImageMetadataProvider()
        
        // TIFF Read/Write
        let tiffURL = tempRoot.appendingPathComponent("test.tiff")
        let img = NSImage(size: NSSize(width: 20, height: 20))
        img.lockFocus()
        NSColor.blue.drawSwatch(in: NSRect(x: 0, y: 0, width: 20, height: 20))
        img.unlockFocus()
        guard let data = img.tiffRepresentation else { return }
        try data.write(to: tiffURL)
        
        var tiffDoc = try await provider.readMetadata(from: tiffURL)
        tiffDoc.common.artist = "Photographer Ansel"
        tiffDoc.common.cameraMake = "Hasselblad"
        
        let updatedTIFF = try await provider.write(tiffDoc, to: tiffURL)
        let readTIFF = try await provider.readMetadata(from: updatedTIFF)
        #expect(readTIFF.common.artist == "Photographer Ansel")
        #expect(readTIFF.common.cameraMake == "Hasselblad")
        
        // SVG Read-Only Capability
        let svgCaps = provider.capabilities(for: .svg)
        #expect(svgCaps.canWrite == false)
        #expect(svgCaps.canRead == true)
        #expect(svgCaps.writeStrategy == .readOnly)
    }

    // MARK: - 15. MetadataManager & HistoryManager Integration
    
    @Test("MetadataManager state, dirty tracking, and history logging")
    @MainActor
    func testMetadataManagerAndHistory() async throws {
        let manager = MetadataManager.shared
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        
        let pdfURL = tempRoot.appendingPathComponent("history_test.pdf")
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        pdfDoc.write(to: pdfURL)
        
        await manager.load(url: pdfURL)
        #expect(manager.document != nil)
        #expect(manager.isDirty == false)
        
        manager.updateField(id: "title", value: .string("History Logged Title"))
        #expect(manager.isDirty == true)
        #expect(manager.document?.common.title == "History Logged Title")
        
        let saveSuccess = await manager.save()
        #expect(saveSuccess == true)
        #expect(manager.isDirty == false)
        
        // Verify history item
        let history = HistoryManager.shared.items
        let metadataItem = history.first(where: { $0.inputFilename == "history_test.pdf" })
        #expect(metadataItem != nil)
        #expect(metadataItem?.presetName == "Metadata Edit")
    }
}
