import Testing
import Foundation
import CoreGraphics
import ImageIO
import AppKit
@testable import LocalConvert

@Suite("Phase 29 — Format & UX Polish Tests")
struct Phase29Tests {
    
    // MARK: - Helpers
    
    /// Creates a 100% valid synthetic 44.1kHz 16-bit stereo PCM WAV file
    private func createSyntheticWAV(duration: Double = 1.0) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Test-Audio-\(UUID().uuidString).wav")
        let sampleRate: Int32 = 44100
        let channels: Int16 = 2
        let bitsPerSample: Int16 = 16
        let byteRate: Int32 = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign: Int16 = channels * (bitsPerSample / 8)
        let totalSamples = Int(Double(sampleRate) * duration)
        let dataSize = Int32(totalSamples * Int(blockAlign))
        let chunkSize = 36 + dataSize
        
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(withUnsafeBytes(of: Int32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: Int16(1).littleEndian) { Data($0) }) // PCM
        data.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        data.append(contentsOf: "data".utf8)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        
        // Generate 440 Hz sine wave
        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            let sample = Int16(sin(2.0 * .pi * 440.0 * t) * 16000.0)
            data.append(withUnsafeBytes(of: sample.littleEndian) { Data($0) }) // L
            data.append(withUnsafeBytes(of: sample.littleEndian) { Data($0) }) // R
        }
        
        try data.write(to: tempURL)
        return tempURL
    }
    
    /// Creates a test CGImage with pattern and colors
    private func createTestPatternImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        
        for x in stride(from: 0, to: width, by: 20) {
            for y in stride(from: 0, to: height, by: 20) {
                let isEven = ((x / 20) + (y / 20)) % 2 == 0
                ctx.setFillColor(isEven ? NSColor.systemTeal.cgColor : NSColor.systemOrange.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 20, height: 20))
            }
        }
        
        return ctx.makeImage()!
    }
    
    /// Writes a CGImage to a PNG file URL
    private func writePNG(image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG"])
        }
    }
    
    // MARK: - 1. AIFF Output Route & Capabilities
    
    @Test("MediaConversionEngine and ConversionRegistry expose AIFF output routes")
    func testAIFFOutputRouteExposure() async throws {
        let mediaEngine = MediaConversionEngine()
        
        // Supported formats check
        #expect(mediaEngine.supportedOutputFormats.contains(.aiff))
        #expect(mediaEngine.supportedInputFormats.contains(.aiff))
        
        // Audio to AIFF
        #expect(mediaEngine.canConvert(from: .wav, to: .aiff))
        #expect(mediaEngine.canConvert(from: .flac, to: .aiff))
        #expect(mediaEngine.canConvert(from: .mp3, to: .aiff))
        #expect(mediaEngine.canConvert(from: .m4a, to: .aiff))
        #expect(mediaEngine.canConvert(from: .aac, to: .aiff))
        
        // AIFF to Audio
        #expect(mediaEngine.canConvert(from: .aiff, to: .wav))
        #expect(mediaEngine.canConvert(from: .aiff, to: .flac))
        #expect(mediaEngine.canConvert(from: .aiff, to: .mp3))
        
        // Video to AIFF (audio extraction)
        #expect(mediaEngine.canConvert(from: .mp4, to: .aiff))
        #expect(mediaEngine.canConvert(from: .mov, to: .aiff))
        #expect(mediaEngine.canConvert(from: .mkv, to: .aiff))
        
        // Available output formats check
        let wavOutputs = mediaEngine.availableOutputFormats(for: .wav)
        #expect(wavOutputs.contains(.aiff))
        
        let mp4Outputs = mediaEngine.availableOutputFormats(for: .mp4)
        #expect(mp4Outputs.contains(.aiff))
        
        // File extension aliases
        #expect(FileFormat.from(extension: "aif") == .aiff)
        #expect(FileFormat.from(extension: "aifc") == .aiff)
        #expect(FileFormat.from(extension: "aiff") == .aiff)
        
        // ConversionRegistry integration
        let registry = ConversionRegistry.shared
        #expect(registry.canConvert(from: .wav, to: .aiff))
        #expect(registry.canConvert(from: .flac, to: .aiff))
        #expect(registry.canConvert(from: .aiff, to: .wav))
        #expect(registry.canConvert(from: .aiff, to: .flac))
    }
    
    @Test("FFmpeg Provider correctly constructs arguments for AIFF output")
    func testFFmpegAIFFArguments() async throws {
        let provider = BundledFFmpegProvider()
        let inputURL = URL(fileURLWithPath: "/tmp/sample.wav")
        let outputURL = URL(fileURLWithPath: "/tmp/sample.aiff")
        let inputInfo = MediaInfo(
            url: inputURL,
            formatName: "wav",
            duration: 5.0,
            fileSize: 882000,
            bitRate: 1411200,
            streams: [
                MediaStreamInfo(
                    index: 0,
                    streamType: .audio,
                    codecName: "pcm_s16le",
                    codecLongName: "PCM signed 16-bit little-endian",
                    bitRate: 1411200,
                    width: nil,
                    height: nil,
                    frameRate: nil,
                    sampleRate: 44100,
                    channels: 2,
                    duration: 5.0
                )
            ]
        )
        
        let args = provider.buildFFmpegArguments(
            inputURL: inputURL,
            outputURL: outputURL,
            inputInfo: inputInfo,
            outputFormat: .aiff,
            options: .default
        )
        
        #expect(args.contains("-c:a"))
        #expect(args.contains("pcm_s16be"))
        #expect(args.contains("-sn")) // Strips subtitle streams from audio
    }
    
    @Test("MediaConversionEngine converts WAV to AIFF and roundtrips AIFF to WAV / FLAC")
    func testAIFFEndToEndConversion() async throws {
        let engine = MediaConversionEngine()
        guard await engine.provider.isAvailable() else {
            // Skip execution if FFmpeg binary is not reachable in test sandbox
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-AIFF-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // 1. Create synthetic WAV (1.5 seconds)
        let wavURL = try createSyntheticWAV(duration: 1.5)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        
        // 2. Convert WAV -> AIFF via MediaConversionEngine
        let aiffResult = try await engine.convert(
            inputs: [wavURL],
            to: .aiff,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        
        #expect(FileManager.default.fileExists(atPath: aiffResult.outputURL.path))
        #expect(aiffResult.outputFormat == .aiff)
        #expect(aiffResult.fileSize > 0)
        
        // 3. Probe the generated AIFF file
        let aiffInfo = try await engine.provider.probe(url: aiffResult.outputURL)
        #expect(aiffInfo.formatName.lowercased().contains("aiff"))
        #expect(abs(aiffInfo.duration - 1.5) < 0.2)
        #expect(aiffInfo.audioStreams.first?.codecName == "pcm_s16be")
        #expect(aiffInfo.audioStreams.first?.sampleRate == 44100)
        #expect(aiffInfo.audioStreams.first?.channels == 2)
        
        // 4. Convert AIFF -> WAV via MediaConversionEngine
        let wavRoundtrip = try await engine.convert(
            inputs: [aiffResult.outputURL],
            to: .wav,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: wavRoundtrip.outputURL.path))
        let wavInfo = try await engine.provider.probe(url: wavRoundtrip.outputURL)
        #expect(wavInfo.formatName.lowercased().contains("wav"))
        
        // 5. Convert AIFF -> FLAC via MediaConversionEngine
        let flacResult = try await engine.convert(
            inputs: [aiffResult.outputURL],
            to: .flac,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: flacResult.outputURL.path))
        let flacInfo = try await engine.provider.probe(url: flacResult.outputURL)
        #expect(flacInfo.formatName.lowercased().contains("flac"))
        
        // 6. Convert FLAC -> AIFF via MediaConversionEngine
        let flacToAiff = try await engine.convert(
            inputs: [flacResult.outputURL],
            to: .aiff,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: flacToAiff.outputURL.path))
        let flacToAiffInfo = try await engine.provider.probe(url: flacToAiff.outputURL)
        #expect(flacToAiffInfo.formatName.lowercased().contains("aiff"))
    }
    
    // MARK: - 2. Target File Size Floor Feedback & Semantics
    
    @Test("ImageProcessor target size optimization reports reached status for achievable targets")
    func testTargetSizeAchievable() throws {
        // Create 200x200 test image
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = ctx.makeImage()!
        
        // Large target (1 MB) -> easily achievable
        let result = try ImageProcessor.optimizeForTargetSize(
            cgImage: image,
            format: .jpg,
            targetBytes: 1_000_000,
            sourceProperties: nil,
            preserveMetadata: false
        )
        
        #expect(result.targetReached)
        #expect(result.note == nil)
        #expect(Int64(result.data.count) <= 1_000_000)
    }
    
    @Test("ImageProcessor target size optimization reports minimum floor note when target is unachievable")
    func testTargetSizeUnachievableFloorFeedback() throws {
        // Create 400x400 test image with complex pattern
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        for x in stride(from: 0, to: 400, by: 10) {
            for y in stride(from: 0, to: 400, by: 10) {
                ctx.setFillColor((x + y) % 20 == 0 ? NSColor.systemBlue.cgColor : NSColor.systemYellow.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 10, height: 10))
            }
        }
        let image = ctx.makeImage()!
        
        // Impossible target: 50 bytes
        let result = try ImageProcessor.optimizeForTargetSize(
            cgImage: image,
            format: .jpg,
            targetBytes: 50,
            sourceProperties: nil,
            preserveMetadata: false
        )
        
        #expect(!result.targetReached)
        #expect(result.note == "Target size could not be reached without exceeding the minimum quality.")
        #expect(result.finalQuality == 0.05)
        #expect(!result.data.isEmpty)
        
        // Verify the resulting data is still a valid readable JPEG image
        guard let source = CGImageSourceCreateWithData(result.data as CFData, nil),
              let _ = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("Resulting JPEG data at quality floor must remain valid and readable")
            return
        }
    }
    
    @Test("ImageProcessor target size optimization reports lossless notice when target cannot be reached in lossless mode")
    func testTargetSizeLosslessFeedback() throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        ctx.setFillColor(NSColor.systemGreen.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = ctx.makeImage()!
        
        // Impossible target for lossless PNG: 10 bytes
        let result = try ImageProcessor.optimizeForTargetSize(
            cgImage: image,
            format: .png,
            targetBytes: 10,
            sourceProperties: nil,
            preserveMetadata: false,
            lossless: true
        )
        
        #expect(!result.targetReached)
        #expect(result.note == "Target size cannot be reached with lossless compression.")
    }
    
    @Test("ImageProcessor target size optimization handles target size larger than original safely")
    func testTargetSizeLargerThanInput() throws {
        let image = createTestPatternImage(width: 300, height: 300)
        
        // Target 20 MB (far larger than required)
        let result = try ImageProcessor.optimizeForTargetSize(
            cgImage: image,
            format: .jpg,
            targetBytes: 20_000_000,
            sourceProperties: nil,
            preserveMetadata: false
        )
        
        #expect(result.targetReached)
        #expect(result.note == nil)
        #expect(result.finalQuality >= 0.95)
        #expect(Int64(result.data.count) < 20_000_000)
    }
    
    // MARK: - 3. Folder Smart Import
    
    @Test("AppState importFilesFromPendingFolders scans directory recursively and filters supported files")
    @MainActor
    func testFolderSmartImport() throws {
        let appState = AppState()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Test-Folder-\(UUID().uuidString)")
        let subDir = tempDir.appendingPathComponent("nested")
        let deepDir = subDir.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // 1. Create root files
        let img1 = tempDir.appendingPathComponent("file1.png")
        try Data(repeating: 0x89, count: 64).write(to: img1)
        
        let img2 = tempDir.appendingPathComponent("file2.jpg")
        try Data(repeating: 0xFF, count: 64).write(to: img2)
        
        // 2. Create nested files
        let aud1 = subDir.appendingPathComponent("track1.wav")
        try Data(repeating: 0x52, count: 64).write(to: aud1)
        
        let doc1 = subDir.appendingPathComponent("doc1.pdf")
        try Data(repeating: 0x25, count: 64).write(to: doc1)
        
        // 3. Create deep nested file
        let deepImg = deepDir.appendingPathComponent("image3.webp")
        try Data(repeating: 0x52, count: 64).write(to: deepImg)
        
        // 4. Create unsupported file
        let unsup = tempDir.appendingPathComponent("unsupported.xyz")
        try Data(repeating: 0x00, count: 32).write(to: unsup)
        
        // 5. Create hidden file
        let hidden = tempDir.appendingPathComponent(".hidden_file.png")
        try Data(repeating: 0x89, count: 64).write(to: hidden)
        
        // Set pending folder
        appState.pendingFolderURLs = [tempDir]
        appState.folderRejectedNotice = "Folders can't be converted directly."
        
        // Run import
        appState.importFilesFromPendingFolders()
        
        #expect(appState.folderRejectedNotice == nil)
        #expect(appState.pendingFolderURLs.isEmpty)
        
        let importedNames = appState.droppedFiles.map { $0.fileName }
        #expect(importedNames.count == 5)
        #expect(importedNames.contains("file1.png"))
        #expect(importedNames.contains("file2.jpg"))
        #expect(importedNames.contains("track1.wav"))
        #expect(importedNames.contains("doc1.pdf"))
        #expect(importedNames.contains("image3.webp"))
        #expect(!importedNames.contains("unsupported.xyz"))
        #expect(!importedNames.contains(".hidden_file.png"))
        
        for item in appState.droppedFiles {
            #expect(item.detectedFormat != nil, "Each imported file must have a recognized format")
        }
    }
    
    // MARK: - 4. RAW / DNG Thumbnail Optimization
    
    @Test("ImageProcessor createThumbnail produces bounded pixel dimensions without full-resolution decoding")
    func testThumbnailMaxPixelSize() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb_test_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        // Create high-res 2400x1600 image file
        let cgImage = createTestPatternImage(width: 2400, height: 1600)
        try writePNG(image: cgImage, to: tempURL)
        
        // Request thumbnail bounded to 120px
        let thumbnail = ImageProcessor.createThumbnail(from: tempURL, maxPixelSize: 120)
        #expect(thumbnail != nil)
        
        if let thumb = thumbnail {
            #expect(thumb.width <= 120)
            #expect(thumb.height <= 120)
            #expect(thumb.width > 0 && thumb.height > 0)
            // Aspect ratio check: 2400/1600 = 1.5, so 120x80
            #expect(thumb.width == 120)
            #expect(thumb.height == 80)
        }
        
        #expect(ImageProcessor.standardThumbnailMaxPixelSize == 240.0)
    }
    
    // MARK: - 5. ICNS Standard-Size Resampling
    
    @Test("ImageConversionEngine exports ICNS with standard Apple icon size representations and supports roundtrips")
    func testICNSExportStandardSizesAndRoundtrip() async throws {
        let engine = ImageConversionEngine()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-ICNS-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Case A: 100x100 Small PNG -> ICNS
        let smallURL = tempDir.appendingPathComponent("small_100.png")
        let smallImg = createTestPatternImage(width: 100, height: 100)
        try writePNG(image: smallImg, to: smallURL)
        
        let smallICNS = try await engine.convert(
            inputs: [smallURL],
            to: .icns,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: smallICNS.outputURL.path))
        #expect(smallICNS.outputFormat == .icns)
        
        // Case B: 300x500 Non-Square PNG -> ICNS (verify aspect-fit square representations)
        let nonSquareURL = tempDir.appendingPathComponent("non_square_300x500.png")
        let nonSquareImg = createTestPatternImage(width: 300, height: 500)
        try writePNG(image: nonSquareImg, to: nonSquareURL)
        
        let nonSquareICNS = try await engine.convert(
            inputs: [nonSquareURL],
            to: .icns,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: nonSquareICNS.outputURL.path))
        
        guard let source = CGImageSourceCreateWithURL(nonSquareICNS.outputURL as CFURL, nil) else {
            Issue.record("Generated ICNS could not be read by CGImageSource")
            return
        }
        
        let count = CGImageSourceGetCount(source)
        #expect(count >= 3, "ICNS should contain multiple standard icon representations")
        
        for i in 0..<count {
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let w = props[kCGImagePropertyPixelWidth] as? Int,
               let h = props[kCGImagePropertyPixelHeight] as? Int {
                #expect(w == h, "ICNS representations must be square: found \(w)x\(h)")
                #expect([16, 32, 64, 128, 256, 512, 1024].contains(w), "Dimension \(w) should be standard Apple icon size")
            }
        }
        
        // Case C: 1024x1024 Large PNG -> ICNS
        let largeURL = tempDir.appendingPathComponent("large_1024.png")
        let largeImg = createTestPatternImage(width: 1024, height: 1024)
        try writePNG(image: largeImg, to: largeURL)
        
        let largeICNS = try await engine.convert(
            inputs: [largeURL],
            to: .icns,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: largeICNS.outputURL.path))
        
        // Case D: Roundtrip ICNS -> PNG
        let icnsToPng = try await engine.convert(
            inputs: [nonSquareICNS.outputURL],
            to: .png,
            outputDirectory: tempDir,
            options: .default,
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: icnsToPng.outputURL.path))
        #expect(icnsToPng.outputFormat == .png)
        #expect(icnsToPng.fileSize > 0)
        
        // Verify output PNG is readable
        guard let roundtripSource = CGImageSourceCreateWithURL(icnsToPng.outputURL as CFURL, nil),
              let roundtripImg = CGImageSourceCreateImageAtIndex(roundtripSource, 0, nil) else {
            Issue.record("Roundtrip PNG from ICNS must be valid and readable")
            return
        }
        #expect(roundtripImg.width > 0 && roundtripImg.height > 0)
    }
}
