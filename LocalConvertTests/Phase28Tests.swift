import Foundation
import Testing
import AppKit
import PDFKit
@testable import LocalConvert

@Suite("Phase 28 — Reliability, Security & Media Robustness Tests")
struct Phase28Tests {
    
    // MARK: - Helpers
    
    /// Creates a password-protected PDF in the temporary directory
    private func createProtectedPDF(password: String) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Test-Protected-\(UUID().uuidString).pdf")
        
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        var mediaBox = pageRect
        
        let auxInfo: [CFString: Any] = [
            kCGPDFContextUserPassword: password as CFString,
            kCGPDFContextOwnerPassword: password as CFString
        ]
        
        guard let context = CGContext(tempURL as CFURL, mediaBox: &mediaBox, auxInfo as CFDictionary) else {
            throw NSError(domain: "PDFTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        
        context.beginPDFPage(nil)
        context.setFillColor(CGColor.white)
        context.fill(pageRect)
        context.endPDFPage()
        context.closePDF()
        
        return tempURL
    }
    
    /// Creates a standard unprotected PDF in the temporary directory
    private func createSamplePDF(pageCount: Int = 2) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Test-Sample-\(UUID().uuidString).pdf")
        
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        var mediaBox = pageRect
        
        guard let context = CGContext(tempURL as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }
        
        for i in 1...pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor.white)
            context.fill(pageRect)
            
            // Draw dummy text
            let str = "Page \(i)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor.black
            ]
            let attrStr = NSAttributedString(string: str as String, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            context.textPosition = CGPoint(x: 50, y: 700)
            CTLineDraw(line, context)
            
            context.endPDFPage()
        }
        context.closePDF()
        
        return tempURL
    }
    
    // MARK: - 1. LibreOffice Subprocess Watchdog & Timeout
    
    @Test("BaseLibreOfficeProvider executes process with watchdog timeout cleanly on hang")
    func testLibreOfficeWatchdogTimeoutTrigger() async throws {
        let provider = SystemLibreOfficeProvider()
        
        // Execute /bin/sleep with a 5 second duration but a 0.1 second watchdog timeout
        let startTime = CFAbsoluteTimeGetCurrent()
        
        var caughtTimeout = false
        do {
            _ = try await provider.executeProcessWithWatchdog(
                executablePath: "/bin/sleep",
                arguments: ["5"],
                timeout: 0.1
            )
        } catch let error as ConversionError {
            if case .engineExecutionFailed(let message, let underlying) = error {
                caughtTimeout = true
                #expect(message.contains("timed out"))
                #expect(underlying?.contains("Watchdog timeout exceeded") == true)
            }
        } catch {
            // Unexpected error type
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        #expect(caughtTimeout, "Watchdog must throw a timeout ConversionError")
        #expect(elapsed < 2.0, "Watchdog must terminate process promptly within timeout window")
    }
    
    @Test("BaseLibreOfficeProvider completes normally for fast processes within watchdog window")
    func testLibreOfficeWatchdogNormalCompletion() async throws {
        let provider = SystemLibreOfficeProvider()
        
        let result = try await provider.executeProcessWithWatchdog(
            executablePath: "/bin/echo",
            arguments: ["LocalConvert Watchdog OK"],
            timeout: 5.0
        )
        
        let stdoutStr = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stdoutStr == "LocalConvert Watchdog OK")
    }
    
    // MARK: - 2. Password-Protected PDF Handling
    
    @Test("PDFConversionEngine detects locked PDF and throws error when no password provided")
    func testLockedPDFWithoutPasswordFailsGracefully() async throws {
        let password = "SecretPassword123"
        let lockedPDF = try createProtectedPDF(password: password)
        defer { try? FileManager.default.removeItem(at: lockedPDF) }
        
        let engine = PDFConversionEngine()
        let outDir = FileManager.default.temporaryDirectory
        
        var caughtError = false
        do {
            _ = try await engine.convert(
                inputs: [lockedPDF],
                to: .png,
                outputDirectory: outDir,
                options: .default,
                progress: { _ in }
            )
        } catch let error as ConversionError {
            if case .invalidInput(let msg) = error {
                caughtError = true
                #expect(msg.contains("password-protected"))
            }
        }
        #expect(caughtError, "Locked PDF without password must throw invalidInput error")
    }
    
    @Test("PDFConversionEngine detects incorrect password and throws clear error")
    func testLockedPDFWithWrongPasswordFailsGracefully() async throws {
        let password = "CorrectPassword123"
        let lockedPDF = try createProtectedPDF(password: password)
        defer { try? FileManager.default.removeItem(at: lockedPDF) }
        
        let engine = PDFConversionEngine()
        let outDir = FileManager.default.temporaryDirectory
        
        var options = ConversionOptions.default
        options.customOptions["pdf_password"] = "WrongPassword999"
        
        var caughtError = false
        do {
            _ = try await engine.convert(
                inputs: [lockedPDF],
                to: .png,
                outputDirectory: outDir,
                options: options,
                progress: { _ in }
            )
        } catch let error as ConversionError {
            if case .invalidInput(let msg) = error {
                caughtError = true
                #expect(msg.contains("Incorrect password"))
            }
        }
        #expect(caughtError, "Locked PDF with incorrect password must throw invalidInput error")
    }
    
    @Test("PDFConversionEngine successfully unlocks and converts protected PDF with correct password")
    func testLockedPDFWithCorrectPasswordSucceeds() async throws {
        let password = "ValidPassword456"
        let lockedPDF = try createProtectedPDF(password: password)
        defer { try? FileManager.default.removeItem(at: lockedPDF) }
        
        let engine = PDFConversionEngine()
        let outDir = FileManager.default.temporaryDirectory
        
        var options = ConversionOptions.default
        options.customOptions["pdf_password"] = password
        
        let result = try await engine.convert(
            inputs: [lockedPDF],
            to: .png,
            outputDirectory: outDir,
            options: options,
            progress: { _ in }
        )
        
        defer {
            for url in result.allOutputURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(result.fileSize > 0)
    }
    
    @Test("PDFToolboxEngine unlocks protected PDF and performs operations")
    func testPDFToolboxProtectedPDFOperations() async throws {
        let password = "ToolboxPassword789"
        let lockedPDF = try createProtectedPDF(password: password)
        defer { try? FileManager.default.removeItem(at: lockedPDF) }
        
        let engine = PDFToolboxEngine()
        let outDir = FileManager.default.temporaryDirectory
        
        var options = ConversionOptions.default
        options.customOptions["pdf_operation"] = "splitEveryPage"
        options.customOptions["pdf_password"] = password
        
        let result = try await engine.convert(
            inputs: [lockedPDF],
            to: .pdf,
            outputDirectory: outDir,
            options: options,
            progress: { _ in }
        )
        
        defer {
            for url in result.allOutputURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
    }
    
    // MARK: - 3. FFmpeg Subtitle Stream Preservation (Route-Aware)
    
    @Test("BaseFFmpegProvider preserves subtitles for MKV (VP9) to MP4 video transcode with mov_text")
    func testFFmpegSubtitlePreservationMP4() {
        let provider = BaseFFmpegProvider()
        
        let inputURL = URL(fileURLWithPath: "/tmp/movie.mkv")
        let outputURL = URL(fileURLWithPath: "/tmp/movie.mp4")
        
        let videoStream = MediaStreamInfo(
            index: 0,
            streamType: .video,
            codecName: "vp9",
            codecLongName: "Google VP9",
            bitRate: 2_000_000,
            width: 1920,
            height: 1080,
            frameRate: 24.0,
            sampleRate: nil,
            channels: nil,
            duration: 120.0
        )
        let audioStream = MediaStreamInfo(
            index: 1,
            streamType: .audio,
            codecName: "opus",
            codecLongName: "Opus Audio",
            bitRate: 128_000,
            width: nil,
            height: nil,
            frameRate: nil,
            sampleRate: 48000,
            channels: 2,
            duration: 120.0
        )
        let subtitleStream = MediaStreamInfo(
            index: 2,
            streamType: .subtitle,
            codecName: "subrip",
            codecLongName: "SubRip subtitle",
            bitRate: nil,
            width: nil,
            height: nil,
            frameRate: nil,
            sampleRate: nil,
            channels: nil,
            duration: 120.0
        )
        
        let info = MediaInfo(
            url: inputURL,
            formatName: "matroska,webm",
            duration: 120.0,
            fileSize: 30_000_000,
            bitRate: 2_000_000,
            streams: [videoStream, audioStream, subtitleStream]
        )
        
        #expect(info.hasSubtitles)
        #expect(info.subtitleStreams.count == 1)
        
        let args = provider.buildFFmpegArguments(
            inputURL: inputURL,
            outputURL: outputURL,
            inputInfo: info,
            outputFormat: .mp4,
            options: .default
        )
        
        // MP4 transcode should preserve subtitle using mov_text codec
        #expect(args.contains("-c:s"))
        if let idx = args.firstIndex(of: "-c:s") {
            #expect(args[idx + 1] == "mov_text")
        }
    }
    
    @Test("BaseFFmpegProvider strips subtitles and video for audio extraction")
    func testFFmpegAudioExtractionStripsSubtitles() {
        let provider = BaseFFmpegProvider()
        
        let inputURL = URL(fileURLWithPath: "/tmp/movie.mkv")
        let outputURL = URL(fileURLWithPath: "/tmp/movie.mp3")
        
        let videoStream = MediaStreamInfo(
            index: 0,
            streamType: .video,
            codecName: "h264",
            codecLongName: "H.264 / AVC",
            bitRate: 2_000_000,
            width: 1920,
            height: 1080,
            frameRate: 24.0,
            sampleRate: nil,
            channels: nil,
            duration: 60.0
        )
        let audioStream = MediaStreamInfo(
            index: 1,
            streamType: .audio,
            codecName: "aac",
            codecLongName: "AAC",
            bitRate: 192_000,
            width: nil,
            height: nil,
            frameRate: nil,
            sampleRate: 48000,
            channels: 2,
            duration: 60.0
        )
        let subtitleStream = MediaStreamInfo(
            index: 2,
            streamType: .subtitle,
            codecName: "subrip",
            codecLongName: "SubRip subtitle",
            bitRate: nil,
            width: nil,
            height: nil,
            frameRate: nil,
            sampleRate: nil,
            channels: nil,
            duration: 60.0
        )
        
        let info = MediaInfo(
            url: inputURL,
            formatName: "matroska",
            duration: 60.0,
            fileSize: 15_000_000,
            bitRate: 2_000_000,
            streams: [videoStream, audioStream, subtitleStream]
        )
        
        let args = provider.buildFFmpegArguments(
            inputURL: inputURL,
            outputURL: outputURL,
            inputInfo: info,
            outputFormat: .mp3,
            options: .default
        )
        
        #expect(args.contains("-vn"), "Audio output must strip video stream")
        #expect(args.contains("-sn"), "Audio output must strip subtitle streams")
    }
    
    // MARK: - 4. Malformed Input Robustness
    
    @Test("ImageConversionEngine rejects zero-byte corrupted files without crash")
    func testCorruptedZeroByteImageRejection() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupted-zero-byte-\(UUID().uuidString).png")
        FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let engine = ImageConversionEngine()
        let outDir = FileManager.default.temporaryDirectory
        
        var caught = false
        do {
            _ = try await engine.convert(
                inputs: [tempURL],
                to: .webp,
                outputDirectory: outDir,
                options: .default,
                progress: { _ in }
            )
        } catch let error as ConversionError {
            caught = true
            #expect(error.errorDescription != nil)
        }
        #expect(caught, "Zero-byte corrupted image must throw a ConversionError")
    }
    
    @Test("PDFConversionEngine rejects random garbage bytes without crash")
    func testCorruptedPDFGarbageRejection() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).pdf")
        let randomGarbage = Data((0..<1024).map { _ in UInt8.random(in: 0...255) })
        try randomGarbage.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let engine = PDFConversionEngine()
        let outDir = FileManager.default.temporaryDirectory
        
        var caught = false
        do {
            _ = try await engine.convert(
                inputs: [tempURL],
                to: .png,
                outputDirectory: outDir,
                options: .default,
                progress: { _ in }
            )
        } catch let error as ConversionError {
            caught = true
            #expect(error.errorDescription != nil)
        }
        #expect(caught, "Corrupted PDF with random bytes must throw a ConversionError")
    }
    
    // MARK: - 5. Malicious Filename & Path Traversal Safety
    
    @Test("ConversionManager and OutputManager handle special characters, unicode, and spaces safely")
    func testSpecialCharacterFilenameSafety() {
        let outDir = FileManager.default.temporaryDirectory
        
        let trickyNames = [
            "Dosya Türkçe Karakterler (şğüıöç).png",
            "emoji_test_🚀_🎉_fire.jpg",
            "file with spaces and (parentheses) [brackets].pdf",
            "single'quote_double\"quote.docx",
            "--leading-hyphen-option-injection.mp4"
        ]
        
        for name in trickyNames {
            let inputURL = URL(fileURLWithPath: "/some/path/\(name)")
            let outURL = ConversionManager.outputURL(for: inputURL, format: .webp, in: outDir)
            
            #expect(outURL.path.hasPrefix(outDir.path), "Output URL must remain strictly within output directory")
            #expect(outURL.pathExtension == "webp")
        }
    }
}
