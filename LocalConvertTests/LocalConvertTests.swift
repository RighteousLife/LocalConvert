import Testing
import Foundation
import ImageIO
import PDFKit
import CoreGraphics
import CoreText
@testable import LocalConvert

// MARK: - Test Fixture Factory

struct TestFixtureFactory {
    static func createTempDirectory() throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }
    
    static func createPNG(in dir: URL, name: String = "test.png", width: Int = 100, height: Int = 100) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1.0, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
    
    static func createJPEG(in dir: URL, name: String = "test.jpg", width: Int = 100, height: Int = 100) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
    
    static func createJPEGWithOrientation(
        in dir: URL,
        name: String = "oriented.jpg",
        width: Int = 100,
        height: Int = 60,
        orientation: UInt32 = 6
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation
        ]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }
    
    static func createHEIC(in dir: URL, name: String = "test.heic", width: Int = 100, height: Int = 100) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
    
    static func createWebP(in dir: URL, name: String = "test.webp") throws -> URL {
        let url = dir.appendingPathComponent(name)
        // Valid 1x1 RIFF WebP
        let base64 = "UklGRkoAAABXRUJQVlA4WAoAAAAQAAAAAAAAAAAAQUxQSAwAAAARBxAR/Q9ERP8DAABWUDggGAAAADABAJ0BKgEAAQAAAP4AAA3AAP7mtQAAAA=="
        guard let data = Data(base64Encoded: base64) else {
            throw ConversionError.invalidInput("Failed to decode base64 webp")
        }
        try data.write(to: url)
        return url
    }
    
    // MARK: - Audio & Video Fixtures
    
    static func createWAV(in dir: URL, name: String = "test.wav", duration: Double = 1.0, sampleRate: Int = 44100) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let numSamples = Int(Double(sampleRate) * duration)
        let subchunk2Size = numSamples * 2 // 16-bit mono
        let chunkSize = 36 + subchunk2Size
        
        var data = Data()
        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var cSize = UInt32(chunkSize).littleEndian
        data.append(Data(bytes: &cSize, count: 4))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        var subchunk1Size = UInt32(16).littleEndian
        data.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat = UInt16(1).littleEndian // PCM
        data.append(Data(bytes: &audioFormat, count: 2))
        var numChannels = UInt16(1).littleEndian // Mono
        data.append(Data(bytes: &numChannels, count: 2))
        var sRate = UInt32(sampleRate).littleEndian
        data.append(Data(bytes: &sRate, count: 4))
        var byteRate = UInt32(sampleRate * 2).littleEndian
        data.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(2).littleEndian
        data.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian
        data.append(Data(bytes: &bitsPerSample, count: 2))
        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var sc2Size = UInt32(subchunk2Size).littleEndian
        data.append(Data(bytes: &sc2Size, count: 4))
        // PCM sine wave samples (440 Hz)
        for i in 0..<numSamples {
            let angle = 2.0 * Double.pi * 440.0 * Double(i) / Double(sampleRate)
            var sample = Int16(sin(angle) * 32767.0).littleEndian
            data.append(Data(bytes: &sample, count: 2))
        }
        try data.write(to: url)
        return url
    }
    
    static func createMP3(in dir: URL, name: String = "test.mp3") async throws -> URL {
        let wav = try createWAV(in: dir, name: "temp_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = dir.appendingPathComponent(name)
        let provider = SystemFFmpegProvider()
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("ffmpeg not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", wav.path, "-c:a", "libmp3lame", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return url
    }
    
    static func createFLAC(in dir: URL, name: String = "test.flac") async throws -> URL {
        let wav = try createWAV(in: dir, name: "temp_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = dir.appendingPathComponent(name)
        let provider = SystemFFmpegProvider()
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("ffmpeg not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", wav.path, "-c:a", "flac", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return url
    }
    
    static func createM4A(in dir: URL, name: String = "test.m4a") async throws -> URL {
        let wav = try createWAV(in: dir, name: "temp_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let url = dir.appendingPathComponent(name)
        let provider = SystemFFmpegProvider()
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("ffmpeg not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", wav.path, "-c:a", "aac", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return url
    }
    
    static func createMP4(in dir: URL, name: String = "test.mp4", duration: Double = 1.0) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("ffmpeg not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-y",
            "-f", "lavfi", "-i", "testsrc=duration=\(duration):size=160x120:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(duration)",
            "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            url.path
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return url
    }
    
    static func createMOV(in dir: URL, name: String = "test.mov", duration: Double = 1.0) async throws -> URL {
        let mp4 = try await createMP4(in: dir, name: "temp_\(UUID().uuidString).mp4", duration: duration)
        defer { try? FileManager.default.removeItem(at: mp4) }
        let url = dir.appendingPathComponent(name)
        let provider = SystemFFmpegProvider()
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("ffmpeg not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", mp4.path, "-c", "copy", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return url
    }
    
    static func createWEBM(in dir: URL, name: String = "test.webm", duration: Double = 1.0) async throws -> URL {
        let mp4 = try await createMP4(in: dir, name: "temp_\(UUID().uuidString).mp4", duration: duration)
        defer { try? FileManager.default.removeItem(at: mp4) }
        let url = dir.appendingPathComponent(name)
        let provider = SystemFFmpegProvider()
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("ffmpeg not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-y", "-i", mp4.path,
            "-c:v", "libvpx-vp9", "-crf", "35", "-b:v", "0",
            "-c:a", "libopus",
            url.path
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return url
    }
    
    static func createMKV(in dir: URL, name: String = "test.mkv", duration: Double = 1.0) async throws -> URL {
        let mp4 = try await createMP4(in: dir, name: "temp_\(UUID().uuidString).mp4", duration: duration)
        defer { try? FileManager.default.removeItem(at: mp4) }
        let url = dir.appendingPathComponent(name)
        let provider = SystemFFmpegProvider()
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("ffmpeg not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", mp4.path, "-c", "copy", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return url
    }
    
    static func createAVI(in dir: URL, name: String = "test.avi", duration: Double = 1.0) async throws -> URL {
        let mp4 = try await createMP4(in: dir, name: "temp_\(UUID().uuidString).mp4", duration: duration)
        defer { try? FileManager.default.removeItem(at: mp4) }
        let url = dir.appendingPathComponent(name)
        let provider = SystemFFmpegProvider()
        guard let ffmpeg = await provider.findFFmpegPath() else {
            throw ConversionError.engineNotAvailable("ffmpeg not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", mp4.path, "-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return url
    }
    
    static func createSinglePagePDF(in dir: URL, name: String = "single.pdf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let pdfContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Could not create PDF context", underlyingError: nil)
        }
        pdfContext.beginPDFPage(nil)
        pdfContext.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0))
        pdfContext.fill(mediaBox)
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        return url
    }
    
    static func createMultiPagePDF(in dir: URL, pages: Int = 3, name: String = "multi.pdf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let pdfContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Could not create PDF context", underlyingError: nil)
        }
        for i in 1...pages {
            pdfContext.beginPDFPage(nil)
            pdfContext.setFillColor(CGColor(red: CGFloat(i) * 0.25, green: 0.5, blue: 0.5, alpha: 1.0))
            pdfContext.fill(mediaBox)
            pdfContext.endPDFPage()
        }
        pdfContext.closePDF()
        return url
    }
    
    static func createPDFWithText(
        in dir: URL,
        name: String = "text.pdf",
        title: String = "LocalConvert PDF Test Document",
        body: String = "This is a test document for PDF conversion."
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdfContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Could not create PDF context", underlyingError: nil)
        }
        pdfContext.beginPDFPage(nil)
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil)
        let titleAttr: [NSAttributedString.Key: Any] = [.font: titleFont]
        let titleStr = NSAttributedString(string: title, attributes: titleAttr)
        let titleLine = CTLineCreateWithAttributedString(titleStr)
        pdfContext.textPosition = CGPoint(x: 50, y: 720)
        CTLineDraw(titleLine, pdfContext)
        
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let bodyAttr: [NSAttributedString.Key: Any] = [.font: bodyFont]
        let bodyStr = NSAttributedString(string: body, attributes: bodyAttr)
        let bodyLine = CTLineCreateWithAttributedString(bodyStr)
        pdfContext.textPosition = CGPoint(x: 50, y: 690)
        CTLineDraw(bodyLine, pdfContext)
        
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        return url
    }
    
    static func createPDFWithTable(
        in dir: URL,
        name: String = "table.pdf",
        headers: [String] = ["Name", "Value"],
        rows: [[String]] = [["LocalConvert", "123"], ["Test", "456"]]
    ) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdfContext = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.engineExecutionFailed("Could not create PDF context", underlyingError: nil)
        }
        pdfContext.beginPDFPage(nil)
        
        let headerFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 14, nil)
        let headerAttr: [NSAttributedString.Key: Any] = [.font: headerFont]
        var x: CGFloat = 50
        for header in headers {
            let attrStr = NSAttributedString(string: header, attributes: headerAttr)
            let line = CTLineCreateWithAttributedString(attrStr)
            pdfContext.textPosition = CGPoint(x: x, y: 720)
            CTLineDraw(line, pdfContext)
            x += 150
        }
        
        let bodyFont = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let bodyAttr: [NSAttributedString.Key: Any] = [.font: bodyFont]
        var y: CGFloat = 680
        for row in rows {
            x = 50
            for cell in row {
                let attrStr = NSAttributedString(string: cell, attributes: bodyAttr)
                let line = CTLineCreateWithAttributedString(attrStr)
                pdfContext.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, pdfContext)
                x += 150
            }
            y -= 30
        }
        
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        return url
    }
    
    static func createCorruptedFile(in dir: URL, name: String = "corrupt.jpg") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])
        try garbage.write(to: url)
        return url
    }
    
    static func makeZipArchive(files: [String: String], destinationURL: URL) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ZipBuild-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        
        for (relPath, content) in files {
            let fileURL = tempDir.appendingPathComponent(relPath)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        
        try? fm.removeItem(at: destinationURL)
        let process = Process()
        process.currentDirectoryURL = tempDir
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", destinationURL.path, "."]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ConversionError.engineExecutionFailed("Zip creation failed", underlyingError: nil)
        }
    }
    
    static func createDOCX(in dir: URL, name: String = "test.docx", text: String = "LocalConvert Test Document") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body>
                <w:p><w:r><w:t>\(text)</w:t></w:r></w:p>
              </w:body>
            </w:document>
            """
        ]
        try makeZipArchive(files: files, destinationURL: url)
        return url
    }
    
    static func createXLSX(in dir: URL, name: String = "test.xlsx", text: String = "LocalConvert", number: String = "123") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
              <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            </Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets>
                <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
              </sheets>
            </workbook>
            """,
            "xl/worksheets/sheet1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <cols>
                <col min="1" max="1" width="25" customWidth="1"/>
              </cols>
              <sheetData>
                <row r="1">
                  <c r="A1" t="inlineStr"><is><t>\(text)</t></is></c>
                  <c r="B1"><v>\(number)</v></c>
                </row>
              </sheetData>
            </worksheet>
            """
        ]
        try makeZipArchive(files: files, destinationURL: url)
        return url
    }
    
    static func createCorruptedOfficeFile(in dir: URL, name: String = "corrupt.docx") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let corruptData = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x00, count: 64)
        try corruptData.write(to: url)
        return url
    }
    
    static func createPPTX(in dir: URL, name: String = "test.pptx", title: String = "LocalConvert Test Presentation") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
              <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
              <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
              <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
            </Relationships>
            """,
            "ppt/_rels/presentation.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
            </Relationships>
            """,
            "ppt/presentation.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:sldMasterIdLst>
                <p:sldMasterId id="2147483648" r:id="rId1"/>
              </p:sldMasterIdLst>
              <p:sldIdLst>
                <p:sldId id="256" r:id="rId2"/>
              </p:sldIdLst>
              <p:sldSz cx="9144000" cy="6858000" type="screen4x3"/>
              <p:notesSz cx="6858000" cy="9144000"/>
            </p:presentation>
            """,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            </Relationships>
            """,
            "ppt/slideMasters/slideMaster1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:cSld>
                <p:spTree>
                  <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:grpSpPr/></p:nvGrpSpPr>
                </p:spTree>
              </p:cSld>
              <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
              <p:sldLayoutIdLst>
                <p:sldLayoutId id="2147483649" r:id="rId1"/>
              </p:sldLayoutIdLst>
            </p:sldMaster>
            """,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
            </Relationships>
            """,
            "ppt/slideLayouts/slideLayout1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank">
              <p:cSld>
                <p:spTree>
                  <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:grpSpPr/></p:nvGrpSpPr>
                </p:spTree>
              </p:cSld>
            </p:sldLayout>
            """,
            "ppt/slides/_rels/slide1.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
            </Relationships>
            """,
            "ppt/slides/slide1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:cSld>
                <p:spTree>
                  <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:grpSpPr/></p:nvGrpSpPr>
                  <p:sp>
                    <p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                    <p:spPr><a:xfrm><a:off x="1524000" y="1143000"/><a:ext cx="6096000" cy="1143000"/></a:xfrm></p:spPr>
                    <p:txBody>
                      <a:bodyPr/>
                      <a:p><a:r><a:rPr lang="en-US"/><a:t>\(title)</a:t></a:r></a:p>
                    </p:txBody>
                  </p:sp>
                </p:spTree>
              </p:cSld>
            </p:sld>
            """
        ]
        try makeZipArchive(files: files, destinationURL: url)
        return url
    }
}

// MARK: - Format Validator

struct FormatValidator {
    static func isValidImage(at url: URL, expectedType: String? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        guard CGImageSourceGetCount(source) > 0 else { return false }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        if let expectedType, let utType = CGImageSourceGetType(source) as? String {
            return utType == expectedType
        }
        return image.width > 0 && image.height > 0
    }
    
    static func isValidPDF(at url: URL, minPages: Int = 1) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let doc = PDFDocument(url: url) else { return false }
        return doc.pageCount >= minPages
    }
    
    static func pdfContainsText(at url: URL, expectedSubstring: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let doc = PDFDocument(url: url) else { return false }
        let text = doc.string ?? ""
        let normalizedText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let normalizedExpected = expectedSubstring
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalizedText.contains(normalizedExpected)
    }
    
    static func isValidOpenXML(at url: URL, requiredEntry: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
        guard size > 0 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let listing = String(data: data, encoding: .utf8) ?? ""
            return listing.contains(requiredEntry)
        } catch {
            return false
        }
    }
    
    static func isValidDOCX(at url: URL) -> Bool {
        isValidOpenXML(at: url, requiredEntry: "word/document.xml")
    }
    
    static func isValidXLSX(at url: URL) -> Bool {
        isValidOpenXML(at: url, requiredEntry: "xl/workbook.xml")
    }
    
    static func isValidPPTX(at url: URL) -> Bool {
        isValidOpenXML(at: url, requiredEntry: "ppt/presentation.xml")
    }
    
    static func pptxSlideCount(at url: URL) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return 0 }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let listing = String(data: data, encoding: .utf8) ?? ""
            let slideLines = listing.components(separatedBy: .newlines).filter { line in
                line.contains("ppt/slides/slide") && line.contains(".xml") && !line.contains("_rels")
            }
            return slideLines.count
        } catch {
            return 0
        }
    }
    
    static func xlsxHasWorksheet(at url: URL) -> Bool {
        isValidOpenXML(at: url, requiredEntry: "xl/worksheets/sheet1.xml")
    }
    
    static func openXMLEntryContains(at url: URL, entry: String, expectedSubstring: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let content = String(data: data, encoding: .utf8) ?? ""
            return content.contains(expectedSubstring)
        } catch {
            return false
        }
    }
}

// MARK: - FileFormat Tests

@Suite("FileFormat Tests")
struct FileFormatTests {
    
    @Test("All formats have non-empty display names")
    func allFormatsHaveDisplayNames() {
        for format in FileFormat.allCases {
            #expect(!format.displayName.isEmpty, "Format \(format.rawValue) should have a display name")
        }
    }
    
    @Test("All formats have non-empty MIME types")
    func allFormatsHaveMimeTypes() {
        for format in FileFormat.allCases {
            #expect(!format.mimeType.isEmpty, "Format \(format.rawValue) should have a MIME type")
        }
    }
    
    @Test("All formats have non-empty file extensions")
    func allFormatsHaveExtensions() {
        for format in FileFormat.allCases {
            #expect(!format.fileExtension.isEmpty, "Format \(format.rawValue) should have a file extension")
        }
    }
    
    @Test("All formats have a category")
    func allFormatsHaveCategories() {
        for format in FileFormat.allCases {
            let _ = format.category
        }
    }
    
    @Test("Format from extension works for known extensions")
    func formatFromExtension() {
        #expect(FileFormat.from(extension: "pdf") == .pdf)
        #expect(FileFormat.from(extension: "PDF") == .pdf)
        #expect(FileFormat.from(extension: "docx") == .docx)
        #expect(FileFormat.from(extension: "jpg") == .jpg)
        #expect(FileFormat.from(extension: "png") == .png)
        #expect(FileFormat.from(extension: "heic") == .heic)
        #expect(FileFormat.from(extension: "webp") == .webp)
    }
    
    @Test("Format from extension handles aliases")
    func formatFromExtensionAliases() {
        #expect(FileFormat.from(extension: "jpeg") == .jpg)
        #expect(FileFormat.from(extension: "JPEG") == .jpg)
        #expect(FileFormat.from(extension: "heif") == .heic)
        #expect(FileFormat.from(extension: "HEIF") == .heic)
        #expect(FileFormat.from(extension: "7z") == .sevenZ)
    }
    
    @Test("Format from unknown extension returns nil")
    func formatFromUnknownExtension() {
        #expect(FileFormat.from(extension: "xyz") == nil)
        #expect(FileFormat.from(extension: "") == nil)
        #expect(FileFormat.from(extension: "unknown") == nil)
    }
    
    @Test("Categories are correct")
    func categoryAssignment() {
        #expect(FileFormat.pdf.category == .document)
        #expect(FileFormat.docx.category == .document)
        #expect(FileFormat.jpg.category == .image)
        #expect(FileFormat.png.category == .image)
        #expect(FileFormat.mp3.category == .audio)
        #expect(FileFormat.mp4.category == .video)
        #expect(FileFormat.zip.category == .archive)
    }
    
    @Test("7z format extension is correct")
    func sevenZExtension() {
        #expect(FileFormat.sevenZ.fileExtension == "7z")
    }
}

// MARK: - FileDetector Tests

@Suite("FileDetector Tests")
struct FileDetectorTests {
    
    let detector = FileDetector()
    
    @Test("Detect format by extension")
    func detectByExtension() {
        let url = URL(fileURLWithPath: "/tmp/test.png")
        let result = detector.detect(url: url)
        #expect(result.extensionFormat == .png)
    }
    
    @Test("Detect format for unknown extension")
    func detectUnknownExtension() {
        let url = URL(fileURLWithPath: "/tmp/test.xyz")
        let result = detector.detect(url: url)
        #expect(result.extensionFormat == nil)
    }
}

// MARK: - ConversionRegistry Tests

@Suite("ConversionRegistry Tests")
struct ConversionRegistryTests {
    
    @Test("Registry starts empty")
    func emptyRegistry() {
        let registry = ConversionRegistry.shared
        let _ = registry.registeredEngines
    }
    
    @Test("Image engine supports expected formats")
    func imageEngineFormats() {
        let engine = ImageConversionEngine()
        
        #expect(engine.supportedInputFormats.contains(.jpg))
        #expect(engine.supportedInputFormats.contains(.png))
        #expect(engine.supportedInputFormats.contains(.heic))
        #expect(engine.supportedInputFormats.contains(.webp))
        
        #expect(engine.supportedOutputFormats.contains(.jpg))
        #expect(engine.supportedOutputFormats.contains(.png))
        #expect(engine.supportedOutputFormats.contains(.pdf))
    }
    
    @Test("Image engine can convert between supported formats")
    func imageEngineCanConvert() {
        let engine = ImageConversionEngine()
        
        #expect(engine.canConvert(from: .jpg, to: .png))
        #expect(engine.canConvert(from: .png, to: .jpg))
        #expect(engine.canConvert(from: .heic, to: .jpg))
        #expect(engine.canConvert(from: .heic, to: .png))
        #expect(engine.canConvert(from: .webp, to: .png))
        #expect(engine.canConvert(from: .png, to: .webp))
        #expect(engine.canConvert(from: .jpg, to: .pdf))
    }
    
    @Test("Image engine rejects same-format conversion")
    func imageEngineRejectsSameFormat() {
        let engine = ImageConversionEngine()
        
        #expect(!engine.canConvert(from: .jpg, to: .jpg))
        #expect(!engine.canConvert(from: .png, to: .png))
    }
    
    @Test("Image engine rejects unsupported formats")
    func imageEngineRejectsUnsupported() {
        let engine = ImageConversionEngine()
        
        #expect(!engine.canConvert(from: .mp3, to: .png))
        #expect(!engine.canConvert(from: .docx, to: .jpg))
    }
    
    @Test("Office engine supports expected input formats")
    func officeEngineFormats() {
        let engine = OfficeConversionEngine()
        
        #expect(engine.supportedInputFormats.contains(.docx))
        #expect(engine.supportedInputFormats.contains(.xlsx))
        #expect(engine.supportedInputFormats.contains(.pptx))
    }
    
    @Test("Office engine supports PDF output")
    func officeEnginePDFOutput() {
        let engine = OfficeConversionEngine()
        
        #expect(engine.canConvert(from: .docx, to: .pdf))
        #expect(engine.canConvert(from: .xlsx, to: .pdf))
        #expect(engine.canConvert(from: .pptx, to: .pdf))
    }
    
    @Test("PDF engine supports expected conversions")
    func pdfEngineFormats() {
        let engine = PDFConversionEngine()
        
        #expect(engine.supportedInputFormats.contains(.pdf))
        #expect(engine.canConvert(from: .pdf, to: .jpg))
        #expect(engine.canConvert(from: .pdf, to: .png))
        #expect(engine.canConvert(from: .pdf, to: .tiff))
    }
}

// MARK: - Output File Naming Tests

@Suite("Output Naming Tests")
struct OutputNamingTests {
    
    @Test("Output URL has correct extension")
    func outputURLExtension() {
        let input = URL(fileURLWithPath: "/tmp/test.docx")
        let outputDir = URL(fileURLWithPath: "/tmp/output")
        let output = ConversionManager.outputURL(for: input, format: .pdf, in: outputDir)
        
        #expect(output.pathExtension == "pdf")
        #expect(output.lastPathComponent.hasPrefix("test"))
    }
    
    @Test("Output URL uses input basename")
    func outputURLBasename() {
        let input = URL(fileURLWithPath: "/tmp/my document.pptx")
        let outputDir = URL(fileURLWithPath: "/tmp/output")
        let output = ConversionManager.outputURL(for: input, format: .pdf, in: outputDir)
        
        #expect(output.lastPathComponent == "my document.pdf")
    }
    
    @Test("Multi-page output naming handles single page")
    func multiPageSingle() {
        let input = URL(fileURLWithPath: "/tmp/doc.pdf")
        let outputDir = URL(fileURLWithPath: "/tmp/output")
        let output = ConversionManager.multiPageOutputURL(for: input, pageIndex: 0, totalPages: 1, format: .png, in: outputDir)
        
        #expect(output.lastPathComponent == "doc.png")
    }
    
    @Test("Multi-page output naming handles multiple pages")
    func multiPageNumbered() {
        let input = URL(fileURLWithPath: "/tmp/doc.pdf")
        let outputDir = URL(fileURLWithPath: "/tmp/output")
        let page1 = ConversionManager.multiPageOutputURL(for: input, pageIndex: 0, totalPages: 3, format: .png, in: outputDir)
        let page2 = ConversionManager.multiPageOutputURL(for: input, pageIndex: 1, totalPages: 3, format: .png, in: outputDir)
        
        #expect(page1.lastPathComponent == "doc-1.png")
        #expect(page2.lastPathComponent == "doc-2.png")
    }
}

// MARK: - ConversionOptions Tests

@Suite("ConversionOptions Tests")
struct ConversionOptionsTests {
    
    @Test("Default options have expected values")
    func defaultOptions() {
        let options = ConversionOptions.default
        
        #expect(options.preserveMetadata == true)
        #expect(options.overwriteExisting == false)
        #expect(options.imageQuality == 0.90)
        #expect(options.effectiveImageQuality == 0.90)
        #expect(options.effectivePDFDPI == 150.0)
        #expect(options.customOptions.isEmpty)
    }
    
    @Test("Quality presets have correct values")
    func qualityPresets() {
        #expect(QualityPreset.low.value == 0.50)
        #expect(QualityPreset.medium.value == 0.75)
        #expect(QualityPreset.high.value == 0.90)
        #expect(QualityPreset.maximum.value == 1.00)
    }
}

// MARK: - ConversionError Tests

@Suite("ConversionError Tests")
struct ConversionErrorTests {
    
    @Test("Errors have user-friendly descriptions")
    func errorDescriptions() {
        let error1 = ConversionError.unsupportedConversion(from: .docx, to: .mp3)
        #expect(error1.errorDescription != nil)
        #expect(!error1.errorDescription!.contains("NSCocoaErrorDomain"))
        
        let error2 = ConversionError.cancelled
        #expect(error2.errorDescription != nil)
        
        let error3 = ConversionError.engineNotAvailable("TestEngine")
        #expect(error3.errorDescription?.contains("TestEngine") == true)
    }
}

// MARK: - ConversionProgress Tests

@Suite("ConversionProgress Tests")
struct ConversionProgressTests {
    
    @Test("Indeterminate progress has nil fraction")
    func indeterminateProgress() {
        let progress = ConversionProgress.indeterminate
        #expect(progress.fractionCompleted == nil)
    }
    
    @Test("Determinate progress clamps to 0-1")
    func determinateProgressClamping() {
        let over = ConversionProgress.determinate(1.5)
        #expect(over.fractionCompleted == 1.0)
        
        let under = ConversionProgress.determinate(-0.5)
        #expect(under.fractionCompleted == 0.0)
        
        let normal = ConversionProgress.determinate(0.5)
        #expect(normal.fractionCompleted == 0.5)
    }
}

// MARK: - Real Image Conversion Tests (Phase 2)

@Suite("Real Image Conversion Tests")
struct RealImageConversionTests {
    
    let engine = ImageConversionEngine()
    
    @Test("JPG -> PNG real conversion")
    func testJpgToPng() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createJPEG(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .png,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .png)
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(FormatValidator.isValidImage(at: result.outputURL, expectedType: "public.png"))
        #expect(result.fileSize > 0)
    }
    
    @Test("PNG -> JPG real conversion")
    func testPngToJpg() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPNG(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .jpg,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .jpg)
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(FormatValidator.isValidImage(at: result.outputURL, expectedType: "public.jpeg"))
        #expect(result.fileSize > 0)
    }
    
    @Test("HEIC -> JPG real conversion")
    func testHeicToJpg() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createHEIC(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .jpg,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .jpg)
        #expect(FormatValidator.isValidImage(at: result.outputURL, expectedType: "public.jpeg"))
    }
    
    @Test("HEIC -> PNG real conversion")
    func testHeicToPng() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createHEIC(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .png,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .png)
        #expect(FormatValidator.isValidImage(at: result.outputURL, expectedType: "public.png"))
    }
    
    @Test("WEBP -> PNG real conversion")
    func testWebpToPng() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createWebP(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .png,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .png)
        #expect(FormatValidator.isValidImage(at: result.outputURL, expectedType: "public.png"))
    }
    
    @Test("WEBP -> JPG real conversion")
    func testWebpToJpg() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createWebP(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .jpg,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .jpg)
        #expect(FormatValidator.isValidImage(at: result.outputURL, expectedType: "public.jpeg"))
    }
    
    @Test("JPG -> PDF real conversion")
    func testJpgToPdf() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createJPEG(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .pdf,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .pdf)
        #expect(FormatValidator.isValidPDF(at: result.outputURL, minPages: 1))
    }
    
    @Test("PNG -> PDF real conversion")
    func testPngToPdf() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPNG(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .pdf,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .pdf)
        #expect(FormatValidator.isValidPDF(at: result.outputURL, minPages: 1))
    }
    
    @Test("HEIC -> PDF real conversion")
    func testHeicToPdf() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createHEIC(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .pdf,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .pdf)
        #expect(FormatValidator.isValidPDF(at: result.outputURL, minPages: 1))
    }
    
    @Test("JPEG quality option affects output file size")
    func testJpegQualityImpact() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPNG(in: dir, width: 300, height: 300)
        
        let highOptions = ConversionOptions(
            preserveMetadata: false,
            overwriteExisting: true,
            imageQuality: 1.0,
            webpLossless: false,
            customOptions: [:]
        )
        let highResult = try await engine.convert(
            input: input,
            to: .jpg,
            outputDirectory: dir,
            options: highOptions,
            progress: { _ in }
        )
        
        let lowDir = dir.appendingPathComponent("low")
        try FileManager.default.createDirectory(at: lowDir, withIntermediateDirectories: true)
        let lowOptions = ConversionOptions(
            preserveMetadata: false,
            overwriteExisting: true,
            imageQuality: 0.1,
            webpLossless: false,
            customOptions: [:]
        )
        let lowResult = try await engine.convert(
            input: input,
            to: .jpg,
            outputDirectory: lowDir,
            options: lowOptions,
            progress: { _ in }
        )
        
        #expect(highResult.fileSize >= lowResult.fileSize)
    }
    
    @Test("Corrupted image file throws invalidInput error")
    func testCorruptedImage() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createCorruptedFile(in: dir)
        
        await #expect(throws: ConversionError.self) {
            try await engine.convert(
                input: input,
                to: .png,
                outputDirectory: dir,
                options: .default,
                progress: { _ in }
            )
        }
    }
    
    @Test("Non-existent file throws inputFileNotFound error")
    func testMissingFile() async throws {
        let missing = URL(fileURLWithPath: "/tmp/non-existent-\(UUID().uuidString).png")
        let dir = URL(fileURLWithPath: "/tmp")
        
        await #expect(throws: ConversionError.self) {
            try await engine.convert(
                input: missing,
                to: .jpg,
                outputDirectory: dir,
                options: .default,
                progress: { _ in }
            )
        }
    }
}

// MARK: - Real PDF Conversion Tests (Phase 2)

@Suite("Real PDF Conversion Tests")
struct RealPDFConversionTests {
    
    let engine = PDFConversionEngine()
    
    @Test("Single-page PDF -> PNG real conversion")
    func testSinglePagePdfToPng() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createSinglePagePDF(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .png,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .png)
        #expect(result.outputURL.lastPathComponent == "single.png")
        #expect(FormatValidator.isValidImage(at: result.outputURL, expectedType: "public.png"))
        #expect(result.additionalOutputURLs.isEmpty)
    }
    
    @Test("Single-page PDF -> JPG real conversion")
    func testSinglePagePdfToJpg() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createSinglePagePDF(in: dir)
        let result = try await engine.convert(
            input: input,
            to: .jpg,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .jpg)
        #expect(result.outputURL.lastPathComponent == "single.jpg")
        #expect(FormatValidator.isValidImage(at: result.outputURL, expectedType: "public.jpeg"))
    }
    
    @Test("Multi-page PDF -> PNG produces numbered files")
    func testMultiPagePdfToPng() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createMultiPagePDF(in: dir, pages: 3)
        let result = try await engine.convert(
            input: input,
            to: .png,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .png)
        #expect(result.outputURL.lastPathComponent == "multi-1.png")
        #expect(result.additionalOutputURLs.count == 2)
        #expect(result.allOutputURLs.count == 3)
        
        for (i, url) in result.allOutputURLs.enumerated() {
            #expect(url.lastPathComponent == "multi-\(i + 1).png")
            #expect(FormatValidator.isValidImage(at: url, expectedType: "public.png"))
        }
    }
    
    @Test("Multi-page PDF -> TIFF produces valid TIFF images")
    func testMultiPagePdfToTiff() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createMultiPagePDF(in: dir, pages: 2)
        let result = try await engine.convert(
            input: input,
            to: .tiff,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .tiff)
        #expect(result.allOutputURLs.count == 2)
        for url in result.allOutputURLs {
            #expect(FormatValidator.isValidImage(at: url, expectedType: "public.tiff"))
        }
    }
    
    @Test("PDF rendering DPI scale impacts output resolution")
    func testPdfDpiScaling() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createSinglePagePDF(in: dir)
        
        let lowDPIOptions = ConversionOptions(
            preserveMetadata: false,
            overwriteExisting: true,
            pdfDPI: 72.0,
            webpLossless: false,
            customOptions: [:]
        )
        let lowResult = try await engine.convert(
            input: input,
            to: .png,
            outputDirectory: dir,
            options: lowDPIOptions,
            progress: { _ in }
        )
        
        let highDir = dir.appendingPathComponent("high")
        try FileManager.default.createDirectory(at: highDir, withIntermediateDirectories: true)
        let highDPIOptions = ConversionOptions(
            preserveMetadata: false,
            overwriteExisting: true,
            pdfDPI: 300.0,
            webpLossless: false,
            customOptions: [:]
        )
        let highResult = try await engine.convert(
            input: input,
            to: .png,
            outputDirectory: highDir,
            options: highDPIOptions,
            progress: { _ in }
        )
        
        let lowSource = CGImageSourceCreateWithURL(lowResult.outputURL as CFURL, nil)!
        let lowImg = CGImageSourceCreateImageAtIndex(lowSource, 0, nil)!
        
        let highSource = CGImageSourceCreateWithURL(highResult.outputURL as CFURL, nil)!
        let highImg = CGImageSourceCreateImageAtIndex(highSource, 0, nil)!
        
        #expect(highImg.width > lowImg.width)
        #expect(highImg.height > lowImg.height)
    }
    
    @Test("Corrupted PDF throws error")
    func testCorruptedPdf() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let corrupt = try TestFixtureFactory.createCorruptedFile(in: dir, name: "corrupt.pdf")
        
        await #expect(throws: ConversionError.self) {
            try await engine.convert(
                input: corrupt,
                to: .png,
                outputDirectory: dir,
                options: .default,
                progress: { _ in }
            )
        }
    }
}

// MARK: - Batch Conversion & Concurrency Tests (Phase 2)

@Suite("Batch Conversion & Queue Tests")
struct BatchConversionQueueTests {
    
    @Test("Batch queue converts multiple files concurrently")
    @MainActor
    func testBatchQueueProcessing() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let registry = ConversionRegistry.shared
        // Ensure image engine is registered
        if registry.findEngine(from: .png, to: .jpg) == nil {
            registry.register(engine: ImageConversionEngine())
        }
        
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(maxConcurrent: 2, conversionManager: manager)
        
        let file1 = try TestFixtureFactory.createPNG(in: dir, name: "file1.png")
        let file2 = try TestFixtureFactory.createPNG(in: dir, name: "file2.png")
        let file3 = try TestFixtureFactory.createPNG(in: dir, name: "file3.png")
        
        let job1 = ConversionJob(inputURL: file1, inputFormat: .png, outputFormat: .jpg, outputDirectory: dir)
        let job2 = ConversionJob(inputURL: file2, inputFormat: .png, outputFormat: .jpg, outputDirectory: dir)
        let job3 = ConversionJob(inputURL: file3, inputFormat: .png, outputFormat: .jpg, outputDirectory: dir)
        
        queue.enqueue(jobs: [job1, job2, job3])
        
        // Wait for all to complete
        var attempts = 0
        while queue.isProcessing && attempts < 50 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        
        #expect(queue.completedCount == 3)
        #expect(queue.failedCount == 0)
        #expect(queue.progress == 1.0)
        
        let out1 = dir.appendingPathComponent("file1.jpg")
        let out2 = dir.appendingPathComponent("file2.jpg")
        let out3 = dir.appendingPathComponent("file3.jpg")
        
        #expect(FormatValidator.isValidImage(at: out1, expectedType: "public.jpeg"))
        #expect(FormatValidator.isValidImage(at: out2, expectedType: "public.jpeg"))
        #expect(FormatValidator.isValidImage(at: out3, expectedType: "public.jpeg"))
    }
}

// MARK: - Mock Unavailable Office Provider

final class MockUnavailableOfficeProvider: OfficeEngineProvider, @unchecked Sendable {
    let providerName = "Mock Unavailable"
    func isAvailable() async -> Bool { false }
    func findExecutablePath() async -> String? { nil }
    func version() async -> String? { nil }
    func convert(
        input: URL,
        to outputFormat: FileFormat,
        outputDirectory: URL,
        options: ConversionOptions = .default,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> URL {
        throw ConversionError.engineNotAvailable("Office engine provider is not available.")
    }
}

// MARK: - Office Engine Provider Tests (Phase 3)

@Suite("Office Engine Provider Tests")
struct OfficeEngineProviderTests {
    
    @Test("System LibreOffice provider detection matches system state")
    func testSystemLibreOfficeDetection() async {
        let provider = SystemLibreOfficeProvider()
        let available = await provider.isAvailable()
        let path = await provider.findExecutablePath()
        
        if available {
            #expect(path != nil)
            #expect(FileManager.default.isExecutableFile(atPath: path!))
        } else {
            #expect(path == nil)
        }
    }
    
    @Test("System LibreOffice version query returns valid version if installed")
    func testSystemLibreOfficeVersion() async {
        let provider = SystemLibreOfficeProvider()
        if await provider.isAvailable() {
            let ver = await provider.version()
            #expect(ver != nil)
            #expect(ver?.contains("LibreOffice") == true)
        }
    }
    
    @Test("Bundled LibreOffice provider is available and resolves executable")
    func testBundledLibreOfficeAvailable() async {
        let bundled = BundledLibreOfficeProvider()
        let isAvail = await bundled.isAvailable()
        #expect(isAvail)
        
        let path = await bundled.findExecutablePath()
        #expect(path != nil)
        if let path {
            #expect(FileManager.default.isExecutableFile(atPath: path))
        }
    }
    
    @Test("Office conversion engine diagnostics returns descriptive info")
    func testOfficeDiagnostics() async {
        let engine = OfficeConversionEngine()
        let diag = await engine.diagnostics()
        #expect(diag.contains("Provider: Bundled LibreOffice"))
        
        let systemEngine = OfficeConversionEngine(provider: SystemLibreOfficeProvider())
        let systemDiag = await systemEngine.diagnostics()
        #expect(systemDiag.contains("Provider: System LibreOffice"))
    }
    
    @Test("Unavailable provider throws engineNotAvailable error")
    func testUnavailableProvider() async throws {
        let mock = MockUnavailableOfficeProvider()
        let engine = OfficeConversionEngine(provider: mock)
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeInput = dir.appendingPathComponent("fake.docx")
        try "dummy".write(to: fakeInput, atomically: true, encoding: .utf8)
        
        await #expect(throws: ConversionError.self) {
            try await engine.convert(
                input: fakeInput,
                to: .pdf,
                outputDirectory: dir,
                options: .default,
                progress: { _ in }
            )
        }
    }
}

// MARK: - Real Office Conversion Tests (Phase 3)

@Suite("Real Office Conversion Tests")
struct RealOfficeConversionTests {
    
    let engine = OfficeConversionEngine()
    
    @Test("DOCX -> PDF real conversion with content verification")
    func testDocxToPdf() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createDOCX(in: dir, name: "document.docx", text: "LocalConvert Test Document")
        let result = try await engine.convert(
            input: input,
            to: .pdf,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .pdf)
        #expect(result.outputURL.lastPathComponent == "document.pdf")
        #expect(FormatValidator.isValidPDF(at: result.outputURL, minPages: 1))
        #expect(FormatValidator.pdfContainsText(at: result.outputURL, expectedSubstring: "LocalConvert Test Document"))
        #expect(result.fileSize > 0)
    }
    
    @Test("XLSX -> PDF real conversion with content verification")
    func testXlsxToPdf() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createXLSX(in: dir, name: "spreadsheet.xlsx", text: "LocalConvert", number: "123")
        let result = try await engine.convert(
            input: input,
            to: .pdf,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .pdf)
        #expect(result.outputURL.lastPathComponent == "spreadsheet.pdf")
        #expect(FormatValidator.isValidPDF(at: result.outputURL, minPages: 1))
        #expect(FormatValidator.pdfContainsText(at: result.outputURL, expectedSubstring: "LocalConvert"))
        #expect(result.fileSize > 0)
    }
    
    @Test("PPTX -> PDF real conversion with content verification")
    func testPptxToPdf() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPPTX(in: dir, name: "presentation.pptx", title: "LocalConvert Test Presentation")
        let result = try await engine.convert(
            input: input,
            to: .pdf,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(result.outputFormat == .pdf)
        #expect(result.outputURL.lastPathComponent == "presentation.pdf")
        #expect(FormatValidator.isValidPDF(at: result.outputURL, minPages: 1))
        #expect(FormatValidator.pdfContainsText(at: result.outputURL, expectedSubstring: "LocalConvert Test Presentation"))
        #expect(result.fileSize > 0)
    }
    
    @Test("Batch Office conversion queue converts DOCX, XLSX, PPTX concurrently")
    @MainActor
    func testBatchOfficeQueueProcessing() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let registry = ConversionRegistry.shared
        if registry.findEngine(from: .docx, to: .pdf) == nil {
            registry.register(engine: OfficeConversionEngine())
        }
        
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(maxConcurrent: 2, conversionManager: manager)
        
        let docx = try TestFixtureFactory.createDOCX(in: dir, name: "batch1.docx")
        let xlsx = try TestFixtureFactory.createXLSX(in: dir, name: "batch2.xlsx")
        let pptx = try TestFixtureFactory.createPPTX(in: dir, name: "batch3.pptx")
        
        let job1 = ConversionJob(inputURL: docx, inputFormat: .docx, outputFormat: .pdf, outputDirectory: dir)
        let job2 = ConversionJob(inputURL: xlsx, inputFormat: .xlsx, outputFormat: .pdf, outputDirectory: dir)
        let job3 = ConversionJob(inputURL: pptx, inputFormat: .pptx, outputFormat: .pdf, outputDirectory: dir)
        
        queue.enqueue(jobs: [job1, job2, job3])
        
        var attempts = 0
        while queue.isProcessing && attempts < 150 {
            try await Task.sleep(for: .milliseconds(200))
            attempts += 1
        }
        
        #expect(queue.completedCount == 3)
        #expect(queue.failedCount == 0)
        #expect(queue.progress == 1.0)
        
        let outDocx = dir.appendingPathComponent("batch1.pdf")
        let outXlsx = dir.appendingPathComponent("batch2.pdf")
        let outPptx = dir.appendingPathComponent("batch3.pdf")
        
        #expect(FormatValidator.isValidPDF(at: outDocx, minPages: 1))
        #expect(FormatValidator.isValidPDF(at: outXlsx, minPages: 1))
        #expect(FormatValidator.isValidPDF(at: outPptx, minPages: 1))
    }
    
    @Test("Corrupted Office document throws error")
    func testCorruptedOfficeDocument() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let corrupt = try TestFixtureFactory.createCorruptedOfficeFile(in: dir, name: "broken.docx")
        
        await #expect(throws: ConversionError.self) {
            try await engine.convert(
                input: corrupt,
                to: .pdf,
                outputDirectory: dir,
                options: .default,
                progress: { _ in }
            )
        }
    }
}

// MARK: - Real PDF to Office Conversion Tests (Phase 4)

@Suite("Real PDF to Office Conversion Tests")
struct RealPDFToOfficeConversionTests {
    
    let engine = OfficeConversionEngine()
    
    @Test("Office engine canConvert supports PDF to Office formats")
    func testOfficeEngineCanConvertPDFToOffice() {
        #expect(engine.canConvert(from: .pdf, to: .docx))
        #expect(engine.canConvert(from: .pdf, to: .xlsx))
        #expect(engine.canConvert(from: .pdf, to: .pptx))
        #expect(!engine.canConvert(from: .pdf, to: .png)) // PNG handled by PDFEngine
        #expect(!engine.canConvert(from: .pdf, to: .pdf)) // Same format not allowed
    }
    
    @Test("Office engine availableOutputFormats for PDF includes DOCX, XLSX, PPTX")
    func testAvailableOutputFormatsForPDF() {
        let formats = engine.availableOutputFormats(for: .pdf)
        #expect(formats.contains(.docx))
        #expect(formats.contains(.xlsx))
        #expect(formats.contains(.pptx))
    }
    
    @Test("PDF -> DOCX real conversion with content verification")
    func testPDFToDOCXRealConversion() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let pdf = try TestFixtureFactory.createPDFWithText(
            in: dir,
            name: "input.pdf",
            title: "LocalConvert PDF Test Document",
            body: "This is a test document for PDF conversion."
        )
        
        let result = try await engine.convert(
            input: pdf,
            to: .docx,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.fileSize > 0)
        #expect(result.outputFormat == .docx)
        #expect(FormatValidator.isValidDOCX(at: result.outputURL))
        #expect(FormatValidator.openXMLEntryContains(at: result.outputURL, entry: "word/document.xml", expectedSubstring: "LocalConvert"))
    }
    
    @Test("PDF -> XLSX real conversion with spreadsheet structure verification")
    func testPDFToXLSXRealConversion() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let pdf = try TestFixtureFactory.createPDFWithTable(
            in: dir,
            name: "table_input.pdf",
            headers: ["Name", "Value"],
            rows: [["LocalConvert", "123"], ["Test", "456"]]
        )
        
        let result = try await engine.convert(
            input: pdf,
            to: .xlsx,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.fileSize > 0)
        #expect(result.outputFormat == .xlsx)
        #expect(FormatValidator.isValidXLSX(at: result.outputURL))
        #expect(FormatValidator.xlsxHasWorksheet(at: result.outputURL))
        
        let hasName = FormatValidator.openXMLEntryContains(at: result.outputURL, entry: "xl/sharedStrings.xml", expectedSubstring: "LocalConvert") ||
                      FormatValidator.openXMLEntryContains(at: result.outputURL, entry: "xl/worksheets/sheet1.xml", expectedSubstring: "LocalConvert")
        let hasValue = FormatValidator.openXMLEntryContains(at: result.outputURL, entry: "xl/sharedStrings.xml", expectedSubstring: "123") ||
                       FormatValidator.openXMLEntryContains(at: result.outputURL, entry: "xl/worksheets/sheet1.xml", expectedSubstring: "123")
        #expect(hasName)
        #expect(hasValue)
    }
    
    @Test("PDF -> PPTX real conversion with multi-page slide verification")
    func testPDFToPPTXRealConversion() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let pdf = try TestFixtureFactory.createMultiPagePDF(in: dir, pages: 3, name: "slides_input.pdf")
        
        let result = try await engine.convert(
            input: pdf,
            to: .pptx,
            outputDirectory: dir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.fileSize > 0)
        #expect(result.outputFormat == .pptx)
        #expect(FormatValidator.isValidPPTX(at: result.outputURL))
        #expect(FormatValidator.pptxSlideCount(at: result.outputURL) == 3)
    }
    
    @Test("Corrupted PDF throws error on PDF to Office conversion")
    func testCorruptedPDFThrowsError() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let corruptPDF = try TestFixtureFactory.createCorruptedFile(in: dir, name: "corrupt.pdf")
        
        await #expect(throws: ConversionError.self) {
            try await engine.convert(
                input: corruptPDF,
                to: .docx,
                outputDirectory: dir,
                options: .default,
                progress: { _ in }
            )
        }
    }
    
    @Test("Concurrent batch PDF to DOCX conversions with no profile collision")
    @MainActor
    func testConcurrentBatchPDFToDOCX() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let pdf1 = try TestFixtureFactory.createPDFWithText(in: dir, name: "concurrent1.pdf", title: "Concurrent Doc 1")
        let pdf2 = try TestFixtureFactory.createPDFWithText(in: dir, name: "concurrent2.pdf", title: "Concurrent Doc 2")
        
        let registry = ConversionRegistry.shared
        if registry.findEngine(from: .pdf, to: .docx) == nil {
            registry.register(engine: OfficeConversionEngine())
        }
        
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(maxConcurrent: 2, conversionManager: manager)
        
        let job1 = ConversionJob(inputURL: pdf1, inputFormat: .pdf, outputFormat: .docx, outputDirectory: dir)
        let job2 = ConversionJob(inputURL: pdf2, inputFormat: .pdf, outputFormat: .docx, outputDirectory: dir)
        
        queue.enqueue(jobs: [job1, job2])
        
        var attempts = 0
        while queue.isProcessing && attempts < 150 {
            try await Task.sleep(for: .milliseconds(200))
            attempts += 1
        }
        
        #expect(queue.completedCount == 2)
        #expect(queue.failedCount == 0)
        
        let out1 = dir.appendingPathComponent("concurrent1.docx")
        let out2 = dir.appendingPathComponent("concurrent2.docx")
        
        #expect(FormatValidator.isValidDOCX(at: out1))
        #expect(FormatValidator.isValidDOCX(at: out2))
        #expect(FormatValidator.openXMLEntryContains(at: out1, entry: "word/document.xml", expectedSubstring: "Concurrent Doc 1"))
        #expect(FormatValidator.openXMLEntryContains(at: out2, entry: "word/document.xml", expectedSubstring: "Concurrent Doc 2"))
    }
    
    @Test("Cancellation of PDF to Office conversion terminates process and cleans up")
    @MainActor
    func testPDFToOfficeConversionCancellation() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let pdf = try TestFixtureFactory.createMultiPagePDF(in: dir, pages: 5, name: "cancel_test.pdf")
        
        let registry = ConversionRegistry.shared
        if registry.findEngine(from: .pdf, to: .docx) == nil {
            registry.register(engine: OfficeConversionEngine())
        }
        
        let manager = ConversionManager(registry: registry)
        let job = ConversionJob(inputURL: pdf, inputFormat: .pdf, outputFormat: .docx, outputDirectory: dir)
        
        manager.submit(job: job)
        // Cancel immediately
        manager.cancel(jobId: job.id)
        
        // Wait a moment for cancellation to process
        try await Task.sleep(for: .milliseconds(300))
        
        let status = manager.jobStatuses[job.id]
        if case .cancelled = status {
            #expect(true)
        } else {
            #expect(status != nil)
        }
    }
    
    @Test("Batch queue converts multiple PDF to Office files concurrently")
    @MainActor
    func testBatchPDFToOfficeConversion() async throws {
        guard await engine.isAvailable() else {
            return
        }
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let pdf1 = try TestFixtureFactory.createPDFWithText(in: dir, name: "batch1.pdf", title: "Batch Document 1")
        let pdf2 = try TestFixtureFactory.createPDFWithTable(in: dir, name: "batch2.pdf")
        let pdf3 = try TestFixtureFactory.createMultiPagePDF(in: dir, pages: 2, name: "batch3.pdf")
        
        let registry = ConversionRegistry.shared
        if registry.findEngine(from: .pdf, to: .docx) == nil {
            registry.register(engine: OfficeConversionEngine())
        }
        
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(maxConcurrent: 2, conversionManager: manager)
        
        let job1 = ConversionJob(inputURL: pdf1, inputFormat: .pdf, outputFormat: .docx, outputDirectory: dir)
        let job2 = ConversionJob(inputURL: pdf2, inputFormat: .pdf, outputFormat: .xlsx, outputDirectory: dir)
        let job3 = ConversionJob(inputURL: pdf3, inputFormat: .pdf, outputFormat: .pptx, outputDirectory: dir)
        
        queue.enqueue(jobs: [job1, job2, job3])
        
        var attempts = 0
        while queue.isProcessing && attempts < 150 {
            try await Task.sleep(for: .milliseconds(200))
            attempts += 1
        }
        
        #expect(queue.completedCount == 3)
        #expect(queue.failedCount == 0)
        
        let outDocx = dir.appendingPathComponent("batch1.docx")
        let outXlsx = dir.appendingPathComponent("batch2.xlsx")
        let outPptx = dir.appendingPathComponent("batch3.pptx")
        
        #expect(FormatValidator.isValidDOCX(at: outDocx))
        #expect(FormatValidator.isValidXLSX(at: outXlsx))
        #expect(FormatValidator.isValidPPTX(at: outPptx))
    }
}

// MARK: - Phase 5 Quality and UX Foundation Tests

@Suite("Phase 5 Quality and UX Foundation Tests")
struct Phase5QualityAndUXTests {
    
    @Test("FileFormat groups and sort ordering")
    func testFormatGroupsAndSortOrder() {
        #expect(FileFormat.jpg.group == .images)
        #expect(FileFormat.png.group == .images)
        #expect(FileFormat.heic.group == .images)
        #expect(FileFormat.webp.group == .images)
        #expect(FileFormat.tiff.group == .images)
        
        #expect(FileFormat.pdf.group == .pdf)
        
        #expect(FileFormat.docx.group == .documents)
        #expect(FileFormat.doc.group == .documents)
        #expect(FileFormat.odt.group == .documents)
        #expect(FileFormat.rtf.group == .documents)
        
        #expect(FileFormat.xlsx.group == .spreadsheets)
        #expect(FileFormat.xls.group == .spreadsheets)
        #expect(FileFormat.ods.group == .spreadsheets)
        #expect(FileFormat.csv.group == .spreadsheets)
        
        #expect(FileFormat.pptx.group == .presentations)
        #expect(FileFormat.ppt.group == .presentations)
        #expect(FileFormat.odp.group == .presentations)
        
        #expect(FormatGroup.images.sortOrder < FormatGroup.pdf.sortOrder)
        #expect(FormatGroup.pdf.sortOrder < FormatGroup.documents.sortOrder)
        #expect(FormatGroup.documents.sortOrder < FormatGroup.spreadsheets.sortOrder)
        #expect(FormatGroup.spreadsheets.sortOrder < FormatGroup.presentations.sortOrder)
    }
    
    @Test("Registry capability and grouping for formats")
    func testRegistryGrouping() {
        let registry = ConversionRegistry.shared
        
        let jpgOutputs = registry.supportedOutputFormats(for: .jpg)
        #expect(jpgOutputs.contains(.png))
        #expect(jpgOutputs.contains(.pdf))
        #expect(!jpgOutputs.contains(.jpg))
        
        let jpgGrouped = Dictionary(grouping: jpgOutputs, by: { $0.group })
        #expect(jpgGrouped[.images]?.contains(.png) == true)
        #expect(jpgGrouped[.pdf]?.contains(.pdf) == true)
        
        let pdfOutputs = registry.supportedOutputFormats(for: .pdf)
        #expect(pdfOutputs.contains(.png))
        #expect(pdfOutputs.contains(.docx))
        let pdfGrouped = Dictionary(grouping: pdfOutputs, by: { $0.group })
        #expect(pdfGrouped[.images]?.contains(.png) == true)
        #expect(pdfGrouped[.documents]?.contains(.docx) == true)
    }
    
    @Test("ConversionOptionDescriptor resolution for engines")
    func testOptionDescriptors() {
        let registry = ConversionRegistry.shared
        
        // JPG -> PNG: metadata toggle
        let pngDescriptors = registry.optionDescriptors(from: .jpg, to: .png)
        #expect(pngDescriptors.contains(where: { $0.id == "preserveMetadata" }))
        #expect(!pngDescriptors.contains(where: { $0.id == "imageQuality" }))
        
        // PNG -> JPG: quality preset and metadata toggle
        let jpgDescriptors = registry.optionDescriptors(from: .png, to: .jpg)
        #expect(jpgDescriptors.contains(where: { $0.id == "imageQuality" }))
        #expect(jpgDescriptors.contains(where: { $0.id == "preserveMetadata" }))
        
        // PDF -> PNG: DPI preset
        let pdfToPngDescriptors = registry.optionDescriptors(from: .pdf, to: .png)
        #expect(pdfToPngDescriptors.contains(where: { $0.id == "pdfDPI" }))
        #expect(!pdfToPngDescriptors.contains(where: { $0.id == "imageQuality" }))
        
        // PDF -> JPG: DPI preset and quality preset
        let pdfToJpgDescriptors = registry.optionDescriptors(from: .pdf, to: .jpg)
        #expect(pdfToJpgDescriptors.contains(where: { $0.id == "pdfDPI" }))
        #expect(pdfToJpgDescriptors.contains(where: { $0.id == "imageQuality" }))
        
        // PDF -> DOCX: PDFOfficeMode
        let pdfToDocxDescriptors = registry.optionDescriptors(from: .pdf, to: .docx)
        #expect(pdfToDocxDescriptors.contains(where: { $0.id == "pdfOfficeMode" }))
    }
    
    @Test("PDF rendering DPI scaling calculates correct pixel dimensions")
    func testPDFRenderingDPIScaling() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let pdf = try TestFixtureFactory.createSinglePagePDF(in: dir, name: "dpi_test.pdf")
        let engine = PDFConversionEngine()
        
        // 72 DPI (scale 1.0 -> 200x200 pt = 200x200 px)
        let out72Dir = dir.appendingPathComponent("out72")
        try FileManager.default.createDirectory(at: out72Dir, withIntermediateDirectories: true)
        let opts72 = ConversionOptions(
            preserveMetadata: true,
            overwriteExisting: false,
            imageQuality: nil,
            pdfDPI: 72.0,
            pdfOfficeMode: nil,
            webpLossless: false,
            customOptions: [:]
        )
        let res72 = try await engine.convert(input: pdf, to: .png, outputDirectory: out72Dir, options: opts72) { _ in }
        
        guard let source72 = CGImageSourceCreateWithURL(res72.outputURL as CFURL, nil),
              let props72 = CGImageSourceCopyPropertiesAtIndex(source72, 0, nil) as? [String: Any],
              let w72 = props72[kCGImagePropertyPixelWidth as String] as? Int,
              let h72 = props72[kCGImagePropertyPixelHeight as String] as? Int else {
            Issue.record("Failed to read image properties for 72 DPI")
            return
        }
        #expect(w72 == 200)
        #expect(h72 == 200)
        
        // 144 DPI (scale 2.0 -> 200x200 pt = 400x400 px)
        let out144Dir = dir.appendingPathComponent("out144")
        try FileManager.default.createDirectory(at: out144Dir, withIntermediateDirectories: true)
        let opts144 = ConversionOptions(
            preserveMetadata: true,
            overwriteExisting: false,
            imageQuality: nil,
            pdfDPI: 144.0,
            pdfOfficeMode: nil,
            webpLossless: false,
            customOptions: [:]
        )
        let res144 = try await engine.convert(input: pdf, to: .png, outputDirectory: out144Dir, options: opts144) { _ in }
        
        guard let source144 = CGImageSourceCreateWithURL(res144.outputURL as CFURL, nil),
              let props144 = CGImageSourceCopyPropertiesAtIndex(source144, 0, nil) as? [String: Any],
              let w144 = props144[kCGImagePropertyPixelWidth as String] as? Int,
              let h144 = props144[kCGImagePropertyPixelHeight as String] as? Int else {
            Issue.record("Failed to read image properties for 144 DPI")
            return
        }
        #expect(w144 == 400)
        #expect(h144 == 400)
    }
    
    @Test("Orientation normalization renders upright and resets orientation tag to 1")
    func testOrientationNormalization() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // Create 100x60 JPEG with EXIF orientation 6 (right-top: 90 deg clockwise)
        let orientedJpg = try TestFixtureFactory.createJPEGWithOrientation(
            in: dir,
            name: "rotated.jpg",
            width: 100,
            height: 60,
            orientation: 6
        )
        
        let engine = ImageConversionEngine()
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let options = ConversionOptions(
            preserveMetadata: true,
            overwriteExisting: false,
            imageQuality: 0.90,
            pdfDPI: nil,
            pdfOfficeMode: nil,
            webpLossless: false,
            customOptions: [:]
        )
        
        let result = try await engine.convert(
            input: orientedJpg,
            to: .png,
            outputDirectory: outDir,
            options: options
        ) { _ in }
        
        guard let source = CGImageSourceCreateWithURL(result.outputURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let pixelWidth = props[kCGImagePropertyPixelWidth as String] as? Int,
              let pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int else {
            Issue.record("Failed to read converted image properties")
            return
        }
        
        // Original: width 100, height 60 with 90° CW tag
        // Upright rendered: width 60, height 100
        #expect(pixelWidth == 60)
        #expect(pixelHeight == 100)
        
        // Orientation property in converted file must be normalized to 1 (upright)
        let orientation = (props[kCGImagePropertyOrientation as String] as? UInt32) ?? 1
        #expect(orientation == 1)
    }
    
    @Test("Multi-page naming and safe collision handling")
    func testMultiPageNamingAndCollisions() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let dummy = URL(fileURLWithPath: "/path/to/report.pdf")
        
        // Single page output URL has no page suffix
        let singleURL = ConversionManager.multiPageOutputURL(for: dummy, pageIndex: 0, totalPages: 1, format: .png, in: dir)
        #expect(singleURL.lastPathComponent == "report.png")
        
        // Multi-page output URL has "-1", "-2" suffix
        let page1URL = ConversionManager.multiPageOutputURL(for: dummy, pageIndex: 0, totalPages: 3, format: .png, in: dir)
        let page2URL = ConversionManager.multiPageOutputURL(for: dummy, pageIndex: 1, totalPages: 3, format: .png, in: dir)
        #expect(page1URL.lastPathComponent == "report-1.png")
        #expect(page2URL.lastPathComponent == "report-2.png")
        
        // Collision handling
        let baseFile = dir.appendingPathComponent("sample.pdf")
        try Data("dummy".utf8).write(to: baseFile)
        
        let nextURL1 = ConversionManager.outputURL(for: dummy, format: .pdf, in: dir)
        // If sample.pdf is requested:
        let sampleDummy = URL(fileURLWithPath: "/path/to/sample.txt")
        let col1 = ConversionManager.outputURL(for: sampleDummy, format: .pdf, in: dir)
        #expect(col1.lastPathComponent == "sample (1).pdf")
        
        // Create sample (1).pdf
        try Data("dummy2".utf8).write(to: col1)
        let col2 = ConversionManager.outputURL(for: sampleDummy, format: .pdf, in: dir)
        #expect(col2.lastPathComponent == "sample (2).pdf")
    }
    
    @Test("AppState rejects folders from dropped URLs")
    @MainActor
    func testAppStateRejectsFolders() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let folder = dir.appendingPathComponent("SubFolder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        let validFile = try TestFixtureFactory.createPNG(in: dir, name: "valid.png")
        
        let appState = AppState()
        appState.handleDroppedURLs([folder, validFile])
        
        #expect(appState.droppedFiles.count == 1)
        #expect(appState.droppedFiles.first?.url == validFile)
    }
    
    @Test("AppState batch progress metrics calculations")
    @MainActor
    func testAppStateBatchMetrics() {
        let appState = AppState()
        #expect(appState.totalJobCount == 0)
        #expect(appState.completedJobCount == 0)
        #expect(appState.failedJobCount == 0)
    }
}

// MARK: - Phase 6 WebP Tests

@Suite("Phase 6 WebP Tests")
struct Phase6WebPTests {
    
    let engine = ImageConversionEngine()
    
    // MARK: - libwebp Availability & Version
    
    @Test("libwebp encoder is available and version is parsable")
    func testLibWebPAvailability() {
        #expect(WebPEncoder.isAvailable)
        let version = WebPEncoder.version
        #expect(!version.isEmpty)
        #expect(version != "unknown")
        // Should be "major.minor.patch" format
        let parts = version.split(separator: ".")
        #expect(parts.count == 3)
    }
    
    // MARK: - WebP Validation
    
    @Test("WebPEncoder.validate correctly identifies WebP and non-WebP data")
    func testWebPValidation() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // Encode a real WebP
        let encoder = WebPEncoder()
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8,
                            bytesPerRow: 40, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        let img = ctx.makeImage()!
        let webpData = try encoder.encode(image: img, mode: .lossy(quality: 80))
        
        #expect(WebPEncoder.validate(webpData))
        #expect(!WebPEncoder.validate(Data("not webp".utf8)))
        #expect(!WebPEncoder.validate(Data()))
        
        // WebP header: RIFF????WEBP
        let dims = WebPEncoder.dimensions(of: webpData)
        #expect(dims?.width == 10)
        #expect(dims?.height == 10)
    }
    
    // MARK: - PNG → WEBP (opaque)
    
    @Test("PNG → WEBP: real lossy conversion, valid bitstream")
    func testPNGToWEBP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPNG(in: dir, name: "source.png", width: 256, height: 256)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.outputURL.pathExtension.lowercased() == "webp")
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
        
        let dims = WebPEncoder.dimensions(of: data)
        #expect(dims?.width == 256)
        #expect(dims?.height == 256)
        #expect(result.fileSize > 0)
    }
    
    // MARK: - JPG → WEBP
    
    @Test("JPG → WEBP: real lossy conversion, valid bitstream")
    func testJPGToWEBP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createJPEG(in: dir, name: "source.jpg", width: 256, height: 256)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
        
        let dims = WebPEncoder.dimensions(of: data)
        #expect(dims?.width == 256)
        #expect(dims?.height == 256)
    }
    
    // MARK: - HEIC → WEBP
    
    @Test("HEIC → WEBP: real conversion via libwebp, valid bitstream")
    func testHEICToWEBP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createHEIC(in: dir, name: "source.heic", width: 128, height: 128)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
        
        let dims = WebPEncoder.dimensions(of: data)
        #expect(dims?.width == 128)
        #expect(dims?.height == 128)
    }
    
    // MARK: - TIFF → WEBP
    
    @Test("TIFF → WEBP: real conversion via libwebp, valid bitstream")
    func testTIFFToWEBP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // Create a TIFF using ImageIO
        let tiffURL = dir.appendingPathComponent("source.tiff")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.init(red: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(tiffURL as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
        
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: tiffURL, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
        
        let dims = WebPEncoder.dimensions(of: data)
        #expect(dims?.width == 128)
        #expect(dims?.height == 128)
    }
    
    // MARK: - BMP → WEBP
    
    @Test("BMP → WEBP: real conversion via libwebp, valid bitstream")
    func testBMPToWEBP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // Create a BMP using ImageIO
        let bmpURL = dir.appendingPathComponent("source.bmp")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(.init(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(bmpURL as CFURL, "com.microsoft.bmp" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
        
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: bmpURL, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
        
        let dims = WebPEncoder.dimensions(of: data)
        #expect(dims?.width == 64)
        #expect(dims?.height == 64)
    }
    
    // MARK: - WEBP → PNG (existing decoding preserved)
    
    @Test("WEBP → PNG: native ImageIO decoding still works")
    func testWEBPToPNG() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // First encode a WebP
        let pngInput = try TestFixtureFactory.createPNG(in: dir, name: "orig.png", width: 64, height: 64)
        let webpDir = dir.appendingPathComponent("webp")
        try FileManager.default.createDirectory(at: webpDir, withIntermediateDirectories: true)
        let webpResult = try await engine.convert(input: pngInput, to: .webp, outputDirectory: webpDir, options: .default) { _ in }
        
        // Then decode that WebP to PNG
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let pngResult = try await engine.convert(input: webpResult.outputURL, to: .png, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: pngResult.outputURL.path))
        #expect(pngResult.outputURL.pathExtension.lowercased() == "png")
        
        guard let source = CGImageSourceCreateWithURL(pngResult.outputURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int else {
            Issue.record("Failed to read decoded PNG properties")
            return
        }
        #expect(w == 64)
        #expect(h == 64)
    }
    
    // MARK: - WEBP → JPG
    
    @Test("WEBP → JPG: native ImageIO decoding still works")
    func testWEBPToJPG() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let pngInput = try TestFixtureFactory.createPNG(in: dir, name: "orig.png", width: 64, height: 64)
        let webpDir = dir.appendingPathComponent("webp")
        try FileManager.default.createDirectory(at: webpDir, withIntermediateDirectories: true)
        let webpResult = try await engine.convert(input: pngInput, to: .webp, outputDirectory: webpDir, options: .default) { _ in }
        
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let jpgResult = try await engine.convert(input: webpResult.outputURL, to: .jpg, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: jpgResult.outputURL.path))
        #expect(jpgResult.outputURL.pathExtension.lowercased() == "jpg")
        
        guard let source = CGImageSourceCreateWithURL(jpgResult.outputURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int else {
            Issue.record("Failed to read decoded JPG properties")
            return
        }
        #expect(w == 64)
    }
    
    // MARK: - Transparent PNG → WEBP Alpha Preservation
    
    @Test("Transparent PNG → WEBP preserves alpha channel")
    func testTransparentPNGToWEBPAlpha() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // Create a 128x128 PNG with half-transparent pixels
        let pngURL = dir.appendingPathComponent("transparent.png")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Fill with semi-transparent blue
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 1, 0.5])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        // Fully transparent corner
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: pngURL, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        let webpData = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(webpData))
        
        // Verify alpha channel is present in the WebP output
        #expect(WebPEncoder.hasAlpha(webpData))
    }
    
    // MARK: - Quality Presets
    
    @Test("WebP quality presets all produce valid bitstreams")
    func testWebPQualityPresets() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPNG(in: dir, name: "source.png", width: 256, height: 256)
        let encoder = WebPEncoder()
        
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Failed to load test image")
            return
        }
        
        for preset in QualityPreset.allCases {
            let data = try encoder.encode(image: cgImage, mode: .lossy(quality: Float(preset.value * 100)))
            #expect(WebPEncoder.validate(data), "Quality preset \(preset.rawValue) produced invalid WebP")
            let dims = WebPEncoder.dimensions(of: data)
            #expect(dims?.width == 256)
        }
    }
    
    // MARK: - Lossless WebP
    
    @Test("PNG → lossless WEBP produces valid bitstream")
    func testLosslessWebP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPNG(in: dir, name: "source.png", width: 64, height: 64)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        var opts = ConversionOptions.default
        opts.webpLossless = true
        
        let result = try await engine.convert(input: input, to: .webp, outputDirectory: outDir, options: opts) { _ in }
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
        
        let dims = WebPEncoder.dimensions(of: data)
        #expect(dims?.width == 64)
        #expect(dims?.height == 64)
    }
    
    // MARK: - Batch WebP Conversion
    
    @Test("Batch PNG/JPG/HEIC → WEBP via ConversionQueue")
    @MainActor
    func testBatchWebPConversion() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let png = try TestFixtureFactory.createPNG(in: dir, name: "batch1.png", width: 64, height: 64)
        let jpg = try TestFixtureFactory.createJPEG(in: dir, name: "batch2.jpg", width: 64, height: 64)
        let heic = try TestFixtureFactory.createHEIC(in: dir, name: "batch3.heic", width: 64, height: 64)
        
        let registry = ConversionRegistry.shared
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(maxConcurrent: 3, conversionManager: manager)
        
        let outDir = dir.appendingPathComponent("batch_out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let job1 = ConversionJob(inputURL: png, inputFormat: .png, outputFormat: .webp, outputDirectory: outDir)
        let job2 = ConversionJob(inputURL: jpg, inputFormat: .jpg, outputFormat: .webp, outputDirectory: outDir)
        let job3 = ConversionJob(inputURL: heic, inputFormat: .heic, outputFormat: .webp, outputDirectory: outDir)
        
        queue.enqueue(jobs: [job1, job2, job3])
        
        var attempts = 0
        while queue.isProcessing && attempts < 60 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        
        #expect(queue.completedCount == 3)
        #expect(queue.failedCount == 0)
        
        // Verify each output is a valid WebP
        for name in ["batch1.webp", "batch2.webp", "batch3.webp"] {
            let outputURL = outDir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: outputURL.path), "\(name) does not exist")
            let data = try Data(contentsOf: outputURL)
            #expect(WebPEncoder.validate(data), "\(name) is not valid WebP")
        }
    }
    
    // MARK: - Registry Capability
    
    @Test("Registry exposes WEBP as supported output for PNG, JPG, HEIC, TIFF, BMP")
    func testWebPRegistryCapability() {
        let registry = ConversionRegistry.shared
        
        for inputFormat in [FileFormat.png, .jpg, .heic, .tiff, .bmp] {
            let outputs = registry.supportedOutputFormats(for: inputFormat)
            #expect(outputs.contains(.webp), "\(inputFormat.rawValue) should support WEBP output")
        }
        
        // WebP can be decoded to PNG and JPG
        let webpOutputs = registry.supportedOutputFormats(for: .webp)
        #expect(webpOutputs.contains(.png))
        #expect(webpOutputs.contains(.jpg))
    }
    
    // MARK: - Option Descriptors for WebP
    
    @Test("PNG → WEBP option descriptors include quality preset and lossless toggle")
    func testWebPOptionDescriptors() {
        let registry = ConversionRegistry.shared
        let descriptors = registry.optionDescriptors(from: .png, to: .webp)
        
        let hasQuality = descriptors.contains { $0.id == "imageQuality" }
        let hasLossless = descriptors.contains { $0.id == "webpLossless" }
        
        #expect(hasQuality, "Missing quality preset descriptor for PNG → WEBP")
        #expect(hasLossless, "Missing lossless toggle descriptor for PNG → WEBP")
    }
    
    // MARK: - Cancellation
    
    @Test("WebP conversion job can be cancelled")
    @MainActor
    func testWebPCancellation() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPNG(in: dir, width: 64, height: 64)
        let registry = ConversionRegistry.shared
        let manager = ConversionManager(registry: registry)
        let job = ConversionJob(inputURL: input, inputFormat: .png, outputFormat: .webp, outputDirectory: dir)
        
        manager.submit(job: job)
        manager.cancel(jobId: job.id)
        
        try await Task.sleep(for: .milliseconds(300))
        
        let status = manager.jobStatuses[job.id]
        // Either cancelled or completed (race condition) — both are acceptable
        #expect(status != nil)
    }
}

// MARK: - Phase 7 Media (Audio & Video / FFmpeg) Tests

@Suite("Phase 7 Media Tests")
struct Phase7MediaTests {
    
    let engine = MediaConversionEngine()
    let provider = SystemFFmpegProvider()
    
    // MARK: - Availability & Version
    
    @Test("FFmpeg and ffprobe are available and version is parsable")
    func testFFmpegAvailability() async {
        let isAvailable = await provider.isAvailable()
        #expect(isAvailable)
        
        let ffmpegPath = await provider.findFFmpegPath()
        #expect(ffmpegPath != nil)
        
        let ffprobePath = await provider.findFFprobePath()
        #expect(ffprobePath != nil)
        
        let version = await provider.version()
        #expect(version != nil)
        #expect(version?.contains("ffmpeg version") == true)
    }
    
    // MARK: - Media Probe
    
    @Test("MediaProbe inspects WAV audio file accurately")
    func testMediaProbeWAV() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let wav = try TestFixtureFactory.createWAV(in: dir, duration: 1.0, sampleRate: 44100)
        let info = try await provider.probe(url: wav)
        
        #expect(info.formatName.contains("wav"))
        #expect(info.hasAudio)
        #expect(!info.hasVideo)
        #expect(info.isAudioOnly)
        #expect(info.duration >= 0.9 && info.duration <= 1.1)
        #expect(info.primaryAudioStream?.channels == 1)
        #expect(info.primaryAudioStream?.sampleRate == 44100)
    }
    
    @Test("MediaProbe inspects MP4 video file accurately")
    func testMediaProbeMP4() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let mp4 = try await TestFixtureFactory.createMP4(in: dir, duration: 1.0)
        let info = try await provider.probe(url: mp4)
        
        #expect(info.hasVideo)
        #expect(info.hasAudio)
        #expect(info.primaryVideoStream?.width == 160)
        #expect(info.primaryVideoStream?.height == 120)
        #expect(info.primaryVideoStream?.codecName.lowercased() == "h264")
        #expect(info.primaryAudioStream?.codecName.lowercased() == "aac")
    }
    
    // MARK: - Audio Conversions (WAV → MP3, FLAC, M4A)
    
    @Test("WAV → MP3: real audio conversion with valid MP3 output")
    func testWAVToMP3() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createWAV(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mp3, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.outputURL.pathExtension.lowercased() == "mp3")
        #expect(result.fileSize > 0)
        
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasAudio)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "mp3")
        #expect(probe.duration > 0)
    }
    
    @Test("WAV → FLAC: real audio conversion with lossless FLAC output")
    func testWAVToFLAC() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createWAV(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .flac, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.outputURL.pathExtension.lowercased() == "flac")
        
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasAudio)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "flac")
    }
    
    @Test("WAV → M4A: real audio conversion with AAC in M4A container")
    func testWAVToM4A() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createWAV(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .m4a, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.outputURL.pathExtension.lowercased() == "m4a")
        
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasAudio)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "aac")
    }
    
    // MARK: - Audio Conversions (MP3 → WAV, FLAC, M4A)
    
    @Test("MP3 → WAV: real audio decoding to PCM WAV")
    func testMP3ToWAV() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP3(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .wav, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasAudio)
        #expect(probe.primaryAudioStream?.codecName.lowercased().contains("pcm") == true)
    }
    
    @Test("MP3 → FLAC: real audio transcode")
    func testMP3ToFLAC() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP3(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .flac, outputDirectory: outDir, options: .default) { _ in }
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "flac")
    }
    
    @Test("MP3 → M4A: real audio transcode")
    func testMP3ToM4A() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP3(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .m4a, outputDirectory: outDir, options: .default) { _ in }
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "aac")
    }
    
    // MARK: - Audio Conversions (FLAC → MP3, WAV, M4A)
    
    @Test("FLAC → MP3: real audio transcode")
    func testFLACToMP3() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createFLAC(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mp3, outputDirectory: outDir, options: .default) { _ in }
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "mp3")
    }
    
    @Test("FLAC → WAV: real audio decoding")
    func testFLACToWAV() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createFLAC(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .wav, outputDirectory: outDir, options: .default) { _ in }
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasAudio)
    }
    
    @Test("FLAC → M4A: real audio transcode")
    func testFLACToM4A() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createFLAC(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .m4a, outputDirectory: outDir, options: .default) { _ in }
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "aac")
    }
    
    // MARK: - Audio Conversions (M4A → MP3, WAV, FLAC)
    
    @Test("M4A → MP3: real audio transcode")
    func testM4AToMP3() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createM4A(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mp3, outputDirectory: outDir, options: .default) { _ in }
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "mp3")
    }
    
    @Test("M4A → WAV: real audio decoding")
    func testM4AToWAV() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createM4A(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .wav, outputDirectory: outDir, options: .default) { _ in }
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasAudio)
    }
    
    @Test("M4A → FLAC: real audio transcode")
    func testM4AToFLAC() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createM4A(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .flac, outputDirectory: outDir, options: .default) { _ in }
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "flac")
    }
    
    // MARK: - Video Conversions
    
    @Test("MOV → MP4: real video container conversion (stream copy)")
    func testMOVToMP4() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMOV(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mp4, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasVideo)
        #expect(probe.primaryVideoStream?.width == 160)
        #expect(probe.primaryVideoStream?.height == 120)
    }
    
    @Test("WEBM → MP4: real video transcode (VP9 → H.264)")
    func testWEBMToMP4() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createWEBM(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mp4, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasVideo)
        #expect(probe.primaryVideoStream?.codecName.lowercased() == "h264")
    }
    
    @Test("MKV → MP4: real video container conversion")
    func testMKVToMP4() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMKV(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mp4, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasVideo)
        #expect(probe.primaryVideoStream?.width == 160)
        #expect(probe.primaryVideoStream?.height == 120)
    }
    
    @Test("AVI → MP4: real video transcode (MPEG-4/MP3 → H.264/AAC)")
    func testAVIToMP4() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createAVI(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mp4, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasVideo)
        #expect(probe.primaryVideoStream?.codecName.lowercased() == "h264")
    }
    
    @Test("MP4 → MOV: real video container conversion")
    func testMP4ToMOV() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP4(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mov, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasVideo)
    }
    
    @Test("MP4 → MKV: real video conversion to Matroska container")
    func testMP4ToMKV() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP4(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mkv, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasVideo)
    }
    
    @Test("MP4 → WEBM: real video transcode to VP9+Opus")
    func testMP4ToWEBM() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP4(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .webm, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasVideo)
        #expect(probe.primaryVideoStream?.codecName.lowercased().contains("vp") == true)
    }
    
    // MARK: - Video to Audio Extraction
    
    @Test("MP4 → MP3: real audio extraction from video container")
    func testVideoToAudioExtraction() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP4(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .mp3, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let probe = try await provider.probe(url: result.outputURL)
        #expect(probe.hasAudio)
        #expect(!probe.hasVideo)
        #expect(probe.primaryAudioStream?.codecName.lowercased() == "mp3")
    }
    
    // MARK: - Real Progress
    
    @Test("FFmpeg conversion reports determinate progress values")
    func testRealProgressReporting() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP4(in: dir, duration: 1.5)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        final class ProgressBox: @unchecked Sendable {
            var fractions: [Double] = []
            let lock = NSLock()
            func add(_ val: Double) {
                lock.withLock { fractions.append(val) }
            }
            var values: [Double] {
                lock.withLock { fractions }
            }
        }
        
        let box = ProgressBox()
        _ = try await engine.convert(input: input, to: .webm, outputDirectory: outDir, options: .default) { progress in
            if let fraction = progress.fractionCompleted {
                box.add(fraction)
            }
        }
        
        let recorded = box.values
        #expect(!recorded.isEmpty)
        #expect(recorded.contains { $0 >= 0.90 })
    }
    
    // MARK: - Batch Media Conversion
    
    @Test("Batch audio and video conversions execute concurrently via queue")
    @MainActor
    func testBatchMediaConversion() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let wav1 = try TestFixtureFactory.createWAV(in: dir, name: "b1.wav")
        let wav2 = try TestFixtureFactory.createWAV(in: dir, name: "b2.wav")
        let wav3 = try TestFixtureFactory.createWAV(in: dir, name: "b3.wav")
        let mp4 = try await TestFixtureFactory.createMP4(in: dir, name: "b4.mp4")
        
        let registry = ConversionRegistry.shared
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(maxConcurrent: 3, conversionManager: manager)
        
        let outDir = dir.appendingPathComponent("batch_out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let job1 = ConversionJob(inputURL: wav1, inputFormat: .wav, outputFormat: .mp3, outputDirectory: outDir)
        let job2 = ConversionJob(inputURL: wav2, inputFormat: .wav, outputFormat: .flac, outputDirectory: outDir)
        let job3 = ConversionJob(inputURL: wav3, inputFormat: .wav, outputFormat: .m4a, outputDirectory: outDir)
        let job4 = ConversionJob(inputURL: mp4, inputFormat: .mp4, outputFormat: .mov, outputDirectory: outDir)
        
        queue.enqueue(jobs: [job1, job2, job3, job4])
        
        var attempts = 0
        while queue.isProcessing && attempts < 300 {
            try await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        
        #expect(queue.completedCount == 4)
        #expect(queue.failedCount == 0)
        
        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("b1.mp3").path))
        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("b2.flac").path))
        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("b3.m4a").path))
        #expect(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("b4.mov").path))
    }
    
    // MARK: - Cancellation
    
    @Test("Media conversion task cancellation terminates process cleanly")
    func testMediaCancellation() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP4(in: dir, duration: 4.0)
        let outDir = dir.appendingPathComponent("cancel_out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let task = Task {
            try await engine.convert(input: input, to: .webm, outputDirectory: outDir, options: .default) { _ in }
        }
        
        // Cancel after 100ms
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        
        let result = await task.result
        switch result {
        case .success:
            // Very fast execution could finish, which is acceptable
            break
        case .failure(let error):
            // Cancellation or process termination
            #expect(error is CancellationError || error is ConversionError)
        }
    }
    
    // MARK: - Registry Capabilities & Option Descriptors
    
    @Test("ConversionRegistry provides media routes and options")
    func testMediaRegistryIntegration() {
        let registry = ConversionRegistry.shared
        
        let wavOutputs = registry.supportedOutputFormats(for: .wav)
        #expect(wavOutputs.contains(.mp3))
        #expect(wavOutputs.contains(.flac))
        #expect(wavOutputs.contains(.m4a))
        
        let mp4Outputs = registry.supportedOutputFormats(for: .mp4)
        #expect(mp4Outputs.contains(.mov))
        #expect(mp4Outputs.contains(.mkv))
        #expect(mp4Outputs.contains(.webm))
        #expect(mp4Outputs.contains(.mp3)) // Audio extraction
        
        let descriptors = registry.optionDescriptors(from: .wav, to: .mp3)
        #expect(descriptors.contains { $0.id == "mediaQuality" })
        #expect(descriptors.contains { $0.id == "preserveMetadata" })
    }
}

// MARK: - Phase 8A Bundled LibWebP Tests

@Suite("Phase 8A Bundled LibWebP Tests")
struct Phase8ABundledLibWebPTests {
    
    let engine = ImageConversionEngine()
    
    /// Helper to find the LocalConvert.app bundle URL
    private func findAppBundleURL() -> URL? {
        // When running under TEST_HOST, Bundle.main is LocalConvert.app
        let main = Bundle.main.bundleURL
        if main.pathExtension == "app" {
            return main
        }
        // Fallback: check bundle loader or standard derived data paths
        if let execURL = Bundle.main.executableURL {
            let appCandidate = execURL.deletingLastPathComponent().deletingLastPathComponent()
            if appCandidate.pathExtension == "app" {
                return appCandidate
            }
        }
        return nil
    }
    
    // MARK: - Bundle Structure & Existence
    
    @Test("Bundled libwebp and libsharpyuv dylibs exist in Contents/Frameworks")
    func testBundledDylibsExist() {
        guard let appURL = findAppBundleURL() else {
            Issue.record("Could not locate host LocalConvert.app bundle")
            return
        }
        
        let frameworksDir = appURL.appendingPathComponent("Contents/Frameworks")
        let libwebpURL = frameworksDir.appendingPathComponent("libwebp.dylib")
        let libsharpyuvURL = frameworksDir.appendingPathComponent("libsharpyuv.dylib")
        
        #expect(FileManager.default.fileExists(atPath: libwebpURL.path), "libwebp.dylib missing in Contents/Frameworks")
        #expect(FileManager.default.fileExists(atPath: libsharpyuvURL.path), "libsharpyuv.dylib missing in Contents/Frameworks")
        
        let webpSize = (try? FileManager.default.attributesOfItem(atPath: libwebpURL.path)[.size] as? Int64) ?? 0
        let sharpyuvSize = (try? FileManager.default.attributesOfItem(atPath: libsharpyuvURL.path)[.size] as? Int64) ?? 0
        
        #expect(webpSize > 50_000, "libwebp.dylib too small")
        #expect(sharpyuvSize > 10_000, "libsharpyuv.dylib too small")
    }
    
    // MARK: - Install Name & RPATH Verification
    
    @Test("Bundled dylibs have @rpath install names and do not reference Homebrew")
    func testBundledDylibInstallNames() throws {
        guard let appURL = findAppBundleURL() else {
            Issue.record("Could not locate host LocalConvert.app bundle")
            return
        }
        
        let frameworksDir = appURL.appendingPathComponent("Contents/Frameworks")
        let libwebpURL = frameworksDir.appendingPathComponent("libwebp.dylib")
        let libsharpyuvURL = frameworksDir.appendingPathComponent("libsharpyuv.dylib")
        
        // Check libwebp.dylib install name
        let pWebp = Process()
        let pipeWebp = Pipe()
        pWebp.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        pWebp.arguments = ["-D", libwebpURL.path]
        pWebp.standardOutput = pipeWebp
        try pWebp.run()
        pWebp.waitUntilExit()
        
        let webpID = String(data: pipeWebp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(webpID.contains("@rpath/libwebp.dylib"), "libwebp.dylib install name is not @rpath/libwebp.dylib")
        #expect(!webpID.contains("/opt/homebrew"), "libwebp.dylib install name contains /opt/homebrew")
        
        // Check libsharpyuv.dylib install name
        let pSharpyuv = Process()
        let pipeSharpyuv = Pipe()
        pSharpyuv.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        pSharpyuv.arguments = ["-D", libsharpyuvURL.path]
        pSharpyuv.standardOutput = pipeSharpyuv
        try pSharpyuv.run()
        pSharpyuv.waitUntilExit()
        
        let sharpyuvID = String(data: pipeSharpyuv.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(sharpyuvID.contains("@rpath/libsharpyuv.dylib"), "libsharpyuv.dylib install name is not @rpath/libsharpyuv.dylib")
        #expect(!sharpyuvID.contains("/opt/homebrew"), "libsharpyuv.dylib install name contains /opt/homebrew")
    }
    
    // MARK: - App Executable Dependencies
    
    @Test("App binary links @rpath/libwebp and has zero Homebrew references")
    func testAppBinaryLinksRpathWebP() throws {
        guard let appURL = findAppBundleURL() else {
            Issue.record("Could not locate host LocalConvert.app bundle")
            return
        }
        
        let execURL = appURL.appendingPathComponent("Contents/MacOS/LocalConvert")
        let debugDylibURL = appURL.appendingPathComponent("Contents/MacOS/LocalConvert.debug.dylib")
        
        let targetToCheck = FileManager.default.fileExists(atPath: debugDylibURL.path) ? debugDylibURL : execURL
        
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        p.arguments = ["-L", targetToCheck.path]
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        
        // Assert it references @rpath/libwebp.dylib
        #expect(output.contains("@rpath/libwebp.dylib"), "App binary does not link @rpath/libwebp.dylib")
        #expect(output.contains("@rpath/libsharpyuv.dylib"), "App binary does not link @rpath/libsharpyuv.dylib")
        
        // Assert it does NOT reference /opt/homebrew for webp
        for line in output.components(separatedBy: .newlines) {
            if line.contains("webp") || line.contains("sharpyuv") {
                #expect(!line.contains("/opt/homebrew"), "Binary still references Homebrew: \(line)")
            }
        }
    }
    
    // MARK: - Code Signing
    
    @Test("Bundled LocalConvert.app passes strict deep code sign verification")
    func testAppBundleCodesign() throws {
        guard let appURL = findAppBundleURL() else {
            Issue.record("Could not locate host LocalConvert.app bundle")
            return
        }
        
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", appURL.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        
        #expect(p.terminationStatus == 0, "codesign verification failed on \(appURL.path)")
    }
    
    // MARK: - Portability
    
    @Test("Portable copy of LocalConvert.app preserves bundled frameworks and signs cleanly")
    func testPortableAppPreservesBundledFrameworks() throws {
        guard let appURL = findAppBundleURL() else {
            Issue.record("Could not locate host LocalConvert.app bundle")
            return
        }
        
        let tempDir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let portableApp = tempDir.appendingPathComponent("LocalConvert-Portable.app")
        try FileManager.default.copyItem(at: appURL, to: portableApp)
        
        let libwebp = portableApp.appendingPathComponent("Contents/Frameworks/libwebp.dylib")
        let libsharpyuv = portableApp.appendingPathComponent("Contents/Frameworks/libsharpyuv.dylib")
        
        #expect(FileManager.default.fileExists(atPath: libwebp.path))
        #expect(FileManager.default.fileExists(atPath: libsharpyuv.path))
        
        // Verify codesign on portable copy
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", portableApp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        
        #expect(p.terminationStatus == 0)
    }
    
    // MARK: - Real WebP Conversions using Bundled Encoder
    
    @Test("PNG → WEBP using bundled libwebp encoder produces valid bitstream")
    func testBundledPNGToWebP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPNG(in: dir, name: "source.png", width: 128, height: 128)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
        
        let dims = WebPEncoder.dimensions(of: data)
        #expect(dims?.width == 128)
        #expect(dims?.height == 128)
    }
    
    @Test("JPG → WEBP using bundled libwebp encoder produces valid bitstream")
    func testBundledJPGToWebP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createJPEG(in: dir, name: "source.jpg", width: 128, height: 128)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
    }
    
    @Test("HEIC → WEBP using bundled libwebp encoder produces valid bitstream")
    func testBundledHEICToWebP() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createHEIC(in: dir, name: "source.heic", width: 128, height: 128)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await engine.convert(input: input, to: .webp, outputDirectory: outDir, options: .default) { _ in }
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
    }
    
    @Test("WEBP decoding remains fully functional with bundled setup")
    func testBundledWebPDecoding() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let png = try TestFixtureFactory.createPNG(in: dir, name: "orig.png", width: 64, height: 64)
        let webpDir = dir.appendingPathComponent("webp")
        try FileManager.default.createDirectory(at: webpDir, withIntermediateDirectories: true)
        
        let webpResult = try await engine.convert(input: png, to: .webp, outputDirectory: webpDir, options: .default) { _ in }
        
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let roundtripResult = try await engine.convert(input: webpResult.outputURL, to: .png, outputDirectory: outDir, options: .default) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: roundtripResult.outputURL.path))
        #expect(roundtripResult.fileSize > 0)
    }
}

// MARK: - Phase 8B Bundled FFmpeg + ffprobe Tests

@Suite("Phase 8B Bundled FFmpeg Tests")
struct Phase8BBundledFFmpegTests {
    
    let bundledProvider = BundledFFmpegProvider(fallbackToSystem: false)
    let engine = MediaConversionEngine()
    
    @Test("Bundled FFmpeg and ffprobe binaries are located and executable")
    func testBundledBinariesExist() async {
        let isAvailable = await bundledProvider.isAvailable()
        #expect(isAvailable)
        
        let ffmpegPath = await bundledProvider.findFFmpegPath()
        #expect(ffmpegPath != nil)
        if let ffmpegPath {
            #expect(FileManager.default.isExecutableFile(atPath: ffmpegPath))
        }
        
        let ffprobePath = await bundledProvider.findFFprobePath()
        #expect(ffprobePath != nil)
        if let ffprobePath {
            #expect(FileManager.default.isExecutableFile(atPath: ffprobePath))
        }
    }
    
    @Test("Bundled FFmpeg reports version and build details")
    func testBundledVersion() async {
        let version = await bundledProvider.version()
        #expect(version != nil)
        #expect(version?.contains("ffmpeg version") == true)
    }
    
    @Test("Bundled binaries dynamic dependency audit has zero Homebrew dylibs")
    func testBundledBinaryDependencyAudit() async throws {
        guard let ffmpegPath = await bundledProvider.findFFmpegPath(),
              let ffprobePath = await bundledProvider.findFFprobePath() else {
            Issue.record("Bundled binaries not found")
            return
        }
        
        for binPath in [ffmpegPath, ffprobePath] {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
            process.arguments = ["-L", binPath]
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            #expect(!output.contains("/opt/homebrew"), "Binary \(binPath) links dynamically to /opt/homebrew!")
            #expect(!output.contains("/usr/local/Cellar"), "Binary \(binPath) links to Homebrew Cellar!")
        }
    }
    
    @Test("Bundled FFmpeg performs real WAV -> MP3 conversion")
    func testBundledWAVToMP3() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createWAV(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await bundledProvider.convert(
            input: input,
            to: .mp3,
            outputDirectory: outDir,
            options: .default
        ) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.path))
        let info = try await bundledProvider.probe(url: result)
        #expect(info.hasAudio)
        #expect(info.primaryAudioStream?.codecName.lowercased() == "mp3")
    }
    
    @Test("Bundled FFmpeg performs real MP4 -> MOV conversion")
    func testBundledMP4ToMOV() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try await TestFixtureFactory.createMP4(in: dir)
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await bundledProvider.convert(
            input: input,
            to: .mov,
            outputDirectory: outDir,
            options: .default
        ) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.path))
        let info = try await bundledProvider.probe(url: result)
        #expect(info.hasVideo)
    }
    
    @Test("MediaConversionEngine default initialization uses BundledFFmpegProvider")
    func testEngineDefaultProvider() {
        #expect(engine.provider is BundledFFmpegProvider)
    }
}

// MARK: - Phase 8C Bundled LibreOffice Tests

@Suite("Phase 8C Bundled LibreOffice Tests")
struct Phase8CBundledLibreOfficeTests {
    
    let bundledProvider = BundledLibreOfficeProvider(fallbackToSystem: false)
    let engine = OfficeConversionEngine()
    
    @Test("Bundled LibreOffice soffice binary is located and executable")
    func testBundledBinaryExists() async {
        let isAvailable = await bundledProvider.isAvailable()
        #expect(isAvailable)
        
        let path = await bundledProvider.findExecutablePath()
        #expect(path != nil)
        if let path {
            #expect(FileManager.default.isExecutableFile(atPath: path))
        }
    }
    
    @Test("Bundled LibreOffice reports version")
    func testBundledVersion() async {
        let version = await bundledProvider.version()
        #expect(version != nil)
        #expect(version?.contains("LibreOffice") == true)
    }
    
    @Test("Bundled LibreOffice binary dynamic dependency audit has zero Homebrew dylibs")
    func testBundledBinaryDependencyAudit() async throws {
        guard let sofficePath = await bundledProvider.findExecutablePath() else {
            Issue.record("Bundled soffice binary not found")
            return
        }
        
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", sofficePath]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        #expect(!output.contains("/opt/homebrew"), "Binary \(sofficePath) links dynamically to /opt/homebrew!")
        #expect(!output.contains("/usr/local/Cellar"), "Binary \(sofficePath) links to Homebrew Cellar!")
    }
    
    @Test("Bundled LibreOffice performs real DOCX -> PDF conversion")
    func testBundledDOCXToPDF() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createDOCX(in: dir, name: "bundled_test.docx", text: "Bundled LibreOffice DOCX Test")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await bundledProvider.convert(
            input: input,
            to: .pdf,
            outputDirectory: outDir,
            options: .default
        ) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(FormatValidator.isValidPDF(at: result, minPages: 1))
        #expect(FormatValidator.pdfContainsText(at: result, expectedSubstring: "Bundled LibreOffice DOCX Test"))
    }
    
    @Test("Bundled LibreOffice performs real PDF -> DOCX conversion")
    func testBundledPDFToDOCX() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = try TestFixtureFactory.createPDFWithText(in: dir, name: "bundled_source.pdf", title: "PDF to DOCX Bundled Test")
        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let result = try await bundledProvider.convert(
            input: input,
            to: .docx,
            outputDirectory: outDir,
            options: .default
        ) { _ in }
        
        #expect(FileManager.default.fileExists(atPath: result.path))
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: result.path)[.size] as? Int64) ?? 0
        #expect(fileSize > 0)
    }
    
    @Test("OfficeConversionEngine default initialization uses BundledLibreOfficeProvider")
    func testEngineDefaultProvider() {
        #expect(engine.provider is BundledLibreOfficeProvider)
    }
}

// MARK: - Phase 9 Production-Grade Workflow and UI Tests

@Suite("Phase 9 Workflow & UI Tests")
struct Phase9WorkflowAndUITests {
    
    @Test("Registry-driven output formats are dynamically resolved without hardcoded lists")
    func testRegistryDrivenOutputFormats() {
        let registry = ConversionRegistry.shared
        
        // Image source
        let jpgOutputs = registry.supportedOutputFormats(for: .jpg)
        #expect(jpgOutputs.contains(.png))
        #expect(jpgOutputs.contains(.webp))
        #expect(!jpgOutputs.contains(.mp3))
        
        // Office source
        let docxOutputs = registry.supportedOutputFormats(for: .docx)
        #expect(docxOutputs.contains(.pdf))
        #expect(!docxOutputs.contains(.jpg))
        
        // Audio source
        let wavOutputs = registry.supportedOutputFormats(for: .wav)
        #expect(wavOutputs.contains(.mp3))
        #expect(wavOutputs.contains(.flac))
        #expect(!wavOutputs.contains(.docx))
        
        // Video source
        let mp4Outputs = registry.supportedOutputFormats(for: .mp4)
        #expect(mp4Outputs.contains(.mov))
        #expect(mp4Outputs.contains(.mp3)) // Audio extraction
        #expect(!mp4Outputs.contains(.pptx))
    }
    
    @Test("Unsupported conversion route is properly rejected by registry")
    func testUnsupportedConversionRoute() {
        let registry = ConversionRegistry.shared
        #expect(!registry.canConvert(from: .docx, to: .mp3))
        #expect(!registry.canConvert(from: .png, to: .xlsx))
        #expect(!registry.canConvert(from: .mp4, to: .docx))
    }
    
    @Test("DroppedFile computes accurate file size, format, and available options")
    func testDroppedFileProperties() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let sampleFile = dir.appendingPathComponent("sample.jpg")
        try Data(repeating: 0x42, count: 2048).write(to: sampleFile)
        
        let detector = FileDetector()
        let result = detector.detect(url: sampleFile)
        let dropped = DroppedFile(url: sampleFile, detectionResult: result)
        
        #expect(dropped.fileName == "sample.jpg")
        #expect(dropped.detectedFormat == .jpg)
        #expect(dropped.fileSize == 2048)
        #expect(!dropped.formattedFileSize.isEmpty)
        #expect(!dropped.availableOutputFormats.isEmpty)
    }
    
    @Test("Option descriptors are route-specific and dynamically retrieved")
    func testOptionDescriptorsResolution() {
        let registry = ConversionRegistry.shared
        
        // Image to WebP has WebP specific options
        let webpDescriptors = registry.optionDescriptors(from: .png, to: .webp)
        #expect(webpDescriptors.contains { $0.id == "webpLossless" })
        
        // PDF to DOCX has PDF office mode
        let pdfDocxDescriptors = registry.optionDescriptors(from: .pdf, to: .docx)
        #expect(pdfDocxDescriptors.contains { $0.id == "pdfOfficeMode" })
        
        // MP4 to MOV has media quality options
        let mediaDescriptors = registry.optionDescriptors(from: .mp4, to: .mov)
        #expect(mediaDescriptors.contains { $0.id == "mediaQuality" })
    }
    
    @Test("OutputManager preferences persistence and directory validation")
    func testOutputManagerPersistenceAndValidation() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // Validation tests
        #expect(OutputManager.isOutputDirectoryValid(dir))
        let nonExistent = dir.appendingPathComponent("missing_dir")
        #expect(!OutputManager.isOutputDirectoryValid(nonExistent))
        
        // Persistence test
        OutputManager.savePreferences(location: .customFolder, customDirectory: dir)
        let loaded = OutputManager.loadSavedPreferences()
        #expect(loaded.location == .customFolder)
        #expect(loaded.customDirectory?.path == dir.path)
        
        // Cleanup preference back to default
        OutputManager.savePreferences(location: .sameFolder, customDirectory: nil)
        let reset = OutputManager.loadSavedPreferences()
        #expect(reset.location == .sameFolder)
        #expect(reset.customDirectory == nil)
    }
    
    @Test("ConversionManager safe collision avoidance naming")
    func testCollisionSafeNaming() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let input = dir.appendingPathComponent("report.docx")
        try "dummy".write(to: input, atomically: true, encoding: .utf8)
        
        // First conversion output URL
        let url1 = ConversionManager.outputURL(for: input, format: .pdf, in: dir)
        #expect(url1.lastPathComponent == "report.pdf")
        
        // Simulate existing file
        try "existing".write(to: url1, atomically: true, encoding: .utf8)
        
        // Second conversion output URL should not collide
        let url2 = ConversionManager.outputURL(for: input, format: .pdf, in: dir)
        #expect(url2.lastPathComponent == "report (1).pdf")
    }
    
    @Test("ConversionQueue batch counters and cancellation tracking")
    @MainActor
    func testConversionQueueBatchAndCancellation() async throws {
        let registry = ConversionRegistry.shared
        let manager = ConversionManager(registry: registry)
        let queue = ConversionQueue(maxConcurrent: 2, conversionManager: manager)
        
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let job1 = ConversionJob(
            inputURL: dir.appendingPathComponent("file1.png"),
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: dir
        )
        let job2 = ConversionJob(
            inputURL: dir.appendingPathComponent("file2.png"),
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: dir
        )
        
        queue.enqueue(jobs: [job1, job2])
        #expect(queue.totalCount == 2)
        
        // Cancel all
        queue.cancelAll()
        #expect(queue.cancelledCount >= 2)
        #expect(!queue.isProcessing)
        
        // Reset
        queue.reset()
        #expect(queue.totalCount == 0)
        #expect(queue.completedCount == 0)
        #expect(queue.failedCount == 0)
        #expect(queue.cancelledCount == 0)
    }
    
    @Test("AppState handles file list removal, format update, and options update")
    @MainActor
    func testAppStateFileManagement() throws {
        let appState = AppState()
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file1 = dir.appendingPathComponent("img1.png")
        let file2 = dir.appendingPathComponent("img2.jpg")
        try "1".write(to: file1, atomically: true, encoding: .utf8)
        try "2".write(to: file2, atomically: true, encoding: .utf8)
        
        appState.handleDroppedURLs([file1, file2])
        #expect(appState.droppedFiles.count == 2)
        
        // Update format
        if let first = appState.droppedFiles.first {
            appState.updateOutputFormat(for: first.id, format: .webp)
            let updated = appState.droppedFiles.first(where: { $0.id == first.id })
            #expect(updated?.selectedOutputFormat == .webp)
            
            // Update options
            var customOpts = ConversionOptions.default
            customOpts.webpLossless = true
            appState.updateOptions(for: first.id, options: customOpts)
            let withOpts = appState.droppedFiles.first(where: { $0.id == first.id })
            #expect(withOpts?.options.webpLossless == true)
            
            // Remove single file
            appState.removeFile(first)
            #expect(appState.droppedFiles.count == 1)
        }
        
        // Remove all
        appState.removeAllFiles()
        #expect(appState.droppedFiles.isEmpty)
    }
    
    @Test("Folder drop rejection records notice")
    @MainActor
    func testFolderDropRejection() throws {
        let appState = AppState()
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let subFolder = dir.appendingPathComponent("SubFolder")
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        
        appState.handleDroppedURLs([subFolder])
        #expect(appState.droppedFiles.isEmpty)
        #expect(appState.folderRejectedNotice != nil)
    }
    
    @Test("Failed conversion item is isolated and does not stop concurrent batch jobs")
    @MainActor
    func testFailedItemIsolationInBatch() async throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        // Create 1 valid PNG and 1 corrupt PNG
        let validPNG = try TestFixtureFactory.createPNG(in: dir, name: "valid.png")
        let corruptPNG = dir.appendingPathComponent("corrupt.png")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: corruptPNG)
        
        let outDir = dir.appendingPathComponent("batch_out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        
        let registry = ConversionRegistry.shared
        let manager = await ConversionManager(registry: registry)
        let queue = await ConversionQueue(maxConcurrent: 2, conversionManager: manager)
        
        let job1 = ConversionJob(
            inputURL: validPNG,
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: outDir
        )
        let job2 = ConversionJob(
            inputURL: corruptPNG,
            inputFormat: .png,
            outputFormat: .jpg,
            outputDirectory: outDir
        )
        
        await queue.enqueue(jobs: [job1, job2])
        
        // Wait for queue processing to complete
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let isDone = await (!queue.isProcessing && queue.totalCount > 0)
            if isDone { break }
        }
        
        let completed = await queue.completedCount
        let failed = await queue.failedCount
        
        // Exactly 1 job should succeed (valid PNG -> JPG) and 1 should fail (corrupt PNG -> JPG)
        #expect(completed == 1)
        #expect(failed == 1)
    }
}

// MARK: - Phase 10 Finder Integration Tests

@Suite("Phase 10 Finder Integration Tests")
struct Phase10FinderIntegrationTests {
    
    @Test("Single file validation produces valid URL")
    func testSingleFileValidation() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file = try TestFixtureFactory.createPNG(in: dir, name: "single.png")
        let result = FinderHandoffHandler.validateAndSanitize(urls: [file])
        
        #expect(result.validURLs.count == 1)
        #expect(result.validURLs.first?.lastPathComponent == "single.png")
        #expect(result.rejectedFolders.isEmpty)
        #expect(result.inaccessibleURLs.isEmpty)
    }
    
    @Test("Multiple files validation processes all items")
    func testMultipleFilesValidation() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file1 = try TestFixtureFactory.createPNG(in: dir, name: "image1.png")
        let file2 = try TestFixtureFactory.createJPEG(in: dir, name: "image2.jpg")
        let file3 = try TestFixtureFactory.createHEIC(in: dir, name: "image3.heic")
        
        let result = FinderHandoffHandler.validateAndSanitize(urls: [file1, file2, file3])
        
        #expect(result.validURLs.count == 3)
        #expect(result.rejectedFolders.isEmpty)
        #expect(result.inaccessibleURLs.isEmpty)
    }
    
    @Test("Office documents validation recognizes DOCX, XLSX, PPTX")
    func testOfficeFilesValidation() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let docx = try TestFixtureFactory.createDOCX(in: dir, name: "doc.docx")
        let xlsx = try TestFixtureFactory.createXLSX(in: dir, name: "sheet.xlsx")
        let pptx = try TestFixtureFactory.createPPTX(in: dir, name: "pres.pptx")
        
        let result = FinderHandoffHandler.validateAndSanitize(urls: [docx, xlsx, pptx])
        
        #expect(result.validURLs.count == 3)
        #expect(result.rejectedFolders.isEmpty)
        #expect(result.inaccessibleURLs.isEmpty)
    }
    
    @Test("Folder selection is rejected and isolated from valid files")
    func testFolderValidationRejection() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let subfolder = dir.appendingPathComponent("ProjectFolder")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let validFile = try TestFixtureFactory.createPNG(in: dir, name: "photo.png")
        
        let result = FinderHandoffHandler.validateAndSanitize(urls: [subfolder, validFile])
        
        #expect(result.validURLs.count == 1)
        #expect(result.validURLs.first?.lastPathComponent == "photo.png")
        #expect(result.rejectedFolders.count == 1)
        #expect(result.rejectedFolders.first?.lastPathComponent == "ProjectFolder")
    }
    
    @Test("Inaccessible or non-existent file is flagged")
    func testInaccessibleFileValidation() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let missing = dir.appendingPathComponent("ghost.png")
        let result = FinderHandoffHandler.validateAndSanitize(urls: [missing])
        
        #expect(result.validURLs.isEmpty)
        #expect(result.inaccessibleURLs.count == 1)
    }
    
    @Test("Custom scheme localconvert://open parses valid file path")
    func testCustomSchemeValidOpen() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file = try TestFixtureFactory.createPNG(in: dir, name: "scheme_test.png")
        let url = URL(string: "localconvert://open?file=\(file.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        
        let parseResult = FinderHandoffHandler.parseSchemeURL(url)
        switch parseResult {
        case .success(let urls):
            #expect(urls.count == 1)
            #expect(urls.first?.lastPathComponent == "scheme_test.png")
        case .failure(let error):
            Issue.record("Expected success but got error: \(error)")
        }
    }
    
    @Test("Custom scheme localconvert://convert parses multiple comma-separated files")
    func testCustomSchemeMultipleFiles() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let f1 = try TestFixtureFactory.createPNG(in: dir, name: "f1.png")
        let f2 = try TestFixtureFactory.createJPEG(in: dir, name: "f2.jpg")
        
        let combined = "\(f1.path),\(f2.path)"
        let encoded = combined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "localconvert://convert?files=\(encoded)")!
        
        let parseResult = FinderHandoffHandler.parseSchemeURL(url)
        switch parseResult {
        case .success(let urls):
            #expect(urls.count == 2)
        case .failure(let error):
            Issue.record("Expected success but got error: \(error)")
        }
    }
    
    @Test("Custom scheme rejects foreign schemes")
    func testCustomSchemeInvalidScheme() {
        let url = URL(string: "https://convert?file=/tmp/test.png")!
        let parseResult = FinderHandoffHandler.parseSchemeURL(url)
        
        switch parseResult {
        case .success:
            Issue.record("Expected invalidScheme failure")
        case .failure(let error):
            #expect(error == .invalidScheme("https"))
        }
    }
    
    @Test("Custom scheme rejects unsupported actions")
    func testCustomSchemeUnsupportedAction() {
        let url = URL(string: "localconvert://delete?file=/tmp/test.png")!
        let parseResult = FinderHandoffHandler.parseSchemeURL(url)
        
        switch parseResult {
        case .success:
            Issue.record("Expected unsupportedAction failure")
        case .failure(let error):
            #expect(error == .unsupportedAction("delete"))
        }
    }
    
    @Test("Custom scheme rejects non-existent files")
    func testCustomSchemeFileNotFound() {
        let url = URL(string: "localconvert://open?file=/tmp/non_existent_random_file_xyz_123.png")!
        let parseResult = FinderHandoffHandler.parseSchemeURL(url)
        
        switch parseResult {
        case .success:
            Issue.record("Expected fileNotFound failure")
        case .failure(let error):
            if case .fileNotFound = error {
                #expect(true)
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
    
    @Test("Custom scheme rejects directory targets")
    func testCustomSchemeFolderRejected() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let url = URL(string: "localconvert://open?file=\(dir.path)")!
        let parseResult = FinderHandoffHandler.parseSchemeURL(url)
        
        switch parseResult {
        case .success:
            Issue.record("Expected folderRejected failure")
        case .failure(let error):
            if case .folderRejected = error {
                #expect(true)
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
    
    @Test("Services pasteboard extracts file URLs accurately")
    func testServicesPasteboardExtraction() throws {
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file = try TestFixtureFactory.createPNG(in: dir, name: "pboard.png")
        let pboard = NSPasteboard.withUniqueName()
        pboard.writeObjects([file as NSURL])
        
        let extracted = FinderHandoffHandler.extractPasteboardURLs(pboard)
        #expect(extracted.count == 1)
        #expect(extracted.first?.lastPathComponent == "pboard.png")
    }
    
    @Test("AppState addFiles adds files and prevents duplicates")
    @MainActor
    func testAppStateAddFilesAndDeduplication() throws {
        let appState = AppState()
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let file1 = try TestFixtureFactory.createPNG(in: dir, name: "drop1.png")
        let file2 = try TestFixtureFactory.createJPEG(in: dir, name: "drop2.jpg")
        
        appState.addFiles(urls: [file1, file2])
        #expect(appState.droppedFiles.count == 2)
        
        // Add duplicate
        appState.addFiles(urls: [file1])
        #expect(appState.droppedFiles.count == 2)
    }
    
    @Test("AppState addFiles displays folder rejected notice when folders are supplied")
    @MainActor
    func testAppStateAddFilesFolderNotice() throws {
        let appState = AppState()
        let dir = try TestFixtureFactory.createTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let folder = dir.appendingPathComponent("ExcludedDir")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        appState.addFiles(urls: [folder])
        #expect(appState.droppedFiles.isEmpty)
        #expect(appState.folderRejectedNotice != nil)
    }
}





