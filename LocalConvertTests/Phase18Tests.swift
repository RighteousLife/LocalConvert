import Foundation
import Testing
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AppKit
@testable import LocalConvert

@Suite("Phase 18 Consumer & Apple Ecosystem Format Compatibility Tests")
struct Phase18Tests {
    
    let registry = ConversionRegistry.shared
    let detector = FileDetector()
    
    // MARK: - 1. Format Definitions & UTType Mapping
    
    @Test("FileFormat Definitions and Categorization")
    func testFormatDefinitions() {
        // Image Formats
        #expect(FileFormat.dng.category == .image)
        #expect(FileFormat.dng.group == .images)
        #expect(FileFormat.dng.fileExtension == "dng")
        #expect(FileFormat.dng.displayName == "DNG / Apple ProRAW")
        
        #expect(FileFormat.icns.category == .image)
        #expect(FileFormat.icns.group == .images)
        #expect(FileFormat.icns.fileExtension == "icns")
        #expect(FileFormat.icns.displayName == "Apple Icon")
        
        #expect(FileFormat.psd.category == .image)
        #expect(FileFormat.psd.group == .images)
        #expect(FileFormat.psd.fileExtension == "psd")
        #expect(FileFormat.psd.displayName == "Photoshop Document")
        
        #expect(FileFormat.tga.category == .image)
        #expect(FileFormat.tga.group == .images)
        #expect(FileFormat.tga.fileExtension == "tga")
        #expect(FileFormat.tga.displayName == "TGA Image")
        
        // Audio Formats
        #expect(FileFormat.caf.category == .audio)
        #expect(FileFormat.caf.group == .audio)
        #expect(FileFormat.caf.fileExtension == "caf")
        #expect(FileFormat.caf.displayName == "Core Audio Format")
        
        #expect(FileFormat.alac.category == .audio)
        #expect(FileFormat.alac.group == .audio)
        #expect(FileFormat.alac.fileExtension == "alac")
        #expect(FileFormat.alac.displayName == "Apple Lossless Audio")
        
        #expect(FileFormat.ac3.category == .audio)
        #expect(FileFormat.ac3.group == .audio)
        #expect(FileFormat.ac3.fileExtension == "ac3")
        #expect(FileFormat.ac3.displayName == "Dolby Digital AC-3")
        
        // Video Formats
        #expect(FileFormat.threeGP.category == .video)
        #expect(FileFormat.threeGP.group == .video)
        #expect(FileFormat.threeGP.fileExtension == "3gp")
        #expect(FileFormat.threeGP.displayName == "3GP Video")
        
        #expect(FileFormat.mts.category == .video)
        #expect(FileFormat.mts.group == .video)
        #expect(FileFormat.mts.fileExtension == "mts")
        #expect(FileFormat.mts.displayName == "AVCHD Video (MTS)")
        
        #expect(FileFormat.m2ts.category == .video)
        #expect(FileFormat.m2ts.group == .video)
        #expect(FileFormat.m2ts.fileExtension == "m2ts")
        #expect(FileFormat.m2ts.displayName == "Blu-ray Video (M2TS)")
    }
    
    @Test("Extension Parsing & Aliases")
    func testExtensionParsing() {
        #expect(FileFormat.from(extension: "dng") == .dng)
        #expect(FileFormat.from(extension: "DNG") == .dng)
        #expect(FileFormat.from(extension: "icns") == .icns)
        #expect(FileFormat.from(extension: "psd") == .psd)
        #expect(FileFormat.from(extension: "tga") == .tga)
        #expect(FileFormat.from(extension: "targa") == .tga)
        #expect(FileFormat.from(extension: "caf") == .caf)
        #expect(FileFormat.from(extension: "alac") == .alac)
        #expect(FileFormat.from(extension: "ac3") == .ac3)
        #expect(FileFormat.from(extension: "eac3") == .ac3)
        #expect(FileFormat.from(extension: "3gp") == .threeGP)
        #expect(FileFormat.from(extension: "3gpp") == .threeGP)
        #expect(FileFormat.from(extension: "3g2") == .threeGP)
        #expect(FileFormat.from(extension: "mts") == .mts)
        #expect(FileFormat.from(extension: "m2ts") == .m2ts)
    }
    
    // MARK: - 2. Magic Bytes & Detection Tests
    
    @Test("Magic Bytes Detection: ICNS, PSD, CAF, AC3, ICO")
    func testMagicBytesDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-Test-Detection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // 1. ICNS
        let icnsURL = tempDir.appendingPathComponent("test.icns")
        let icnsHeader = Data([0x69, 0x63, 0x6E, 0x73, 0x00, 0x00, 0x00, 0x08]) // 'icns' + size 8
        try icnsHeader.write(to: icnsURL)
        #expect(detector.detect(url: icnsURL).bestFormat == .icns)
        
        // 2. PSD
        let psdURL = tempDir.appendingPathComponent("test.psd")
        let psdHeader = Data([0x38, 0x42, 0x50, 0x53, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // '8BPS'
        try psdHeader.write(to: psdURL)
        #expect(detector.detect(url: psdURL).bestFormat == .psd)
        
        // 3. CAF
        let cafURL = tempDir.appendingPathComponent("test.caf")
        let cafHeader = Data([0x63, 0x61, 0x66, 0x66, 0x00, 0x01, 0x00, 0x00]) // 'caff'
        try cafHeader.write(to: cafURL)
        #expect(detector.detect(url: cafURL).bestFormat == .caf)
        
        // 4. AC3
        let ac3URL = tempDir.appendingPathComponent("test.ac3")
        let ac3Header = Data([0x0B, 0x77, 0x12, 0x34, 0x56, 0x78]) // 0x0B, 0x77
        try ac3Header.write(to: ac3URL)
        #expect(detector.detect(url: ac3URL).bestFormat == .ac3)
        
        // 5. ICO
        let icoURL = tempDir.appendingPathComponent("test.ico")
        let icoHeader = Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00]) // 00 00 01 00
        try icoHeader.write(to: icoURL)
        #expect(detector.detect(url: icoURL).bestFormat == .ico)
        
        // 6. DNG
        let dngURL = tempDir.appendingPathComponent("test.dng")
        let dngHeader = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]) // Little-endian TIFF/DNG
        try dngHeader.write(to: dngURL)
        #expect(detector.detect(url: dngURL).bestFormat == .dng)
        
        // 7. MTS
        let mtsURL = tempDir.appendingPathComponent("test.mts")
        let mtsHeader = Data([0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D]) // Sync byte 0x47
        try mtsHeader.write(to: mtsURL)
        #expect(detector.detect(url: mtsURL).bestFormat == .mts)
    }
    
    // MARK: - 3. Read-Only Guardrails & Capability Boundary Enforcement
    
    @Test("Strict Read-Only Guardrails for DNG, PSD, 3GP, MTS, M2TS")
    func testReadOnlyGuardrails() {
        let allOutputs = FileFormat.allCases.flatMap { registry.supportedOutputFormats(for: $0) }
        let outputSet = Set(allOutputs)
        
        // Target outputs should NEVER include DNG, PSD, 3GP, MTS, M2TS
        #expect(!outputSet.contains(.dng), "DNG encoding is not standard consumer format and must be strictly read-only")
        #expect(!outputSet.contains(.psd), "PSD encoding is proprietary multi-layer format and must be strictly read-only")
        #expect(!outputSet.contains(.threeGP), "3GP encoding is legacy mobile format and must be strictly read-only")
        #expect(!outputSet.contains(.mts), "MTS encoding is camcorder format and must be strictly read-only")
        #expect(!outputSet.contains(.m2ts), "M2TS encoding is camcorder/Blu-ray format and must be strictly read-only")
        
        // Inputs SHOULD be supported
        #expect(registry.supportedInputFormats.contains(.dng))
        #expect(registry.supportedInputFormats.contains(.psd))
        #expect(registry.supportedInputFormats.contains(.threeGP))
        #expect(registry.supportedInputFormats.contains(.mts))
        #expect(registry.supportedInputFormats.contains(.m2ts))
    }
    
    @Test("Bidirectional Capabilities: ICNS, ICO, TGA, CAF, ALAC, AC3")
    func testBidirectionalCapabilities() {
        // Image bidirection
        #expect(registry.canConvert(from: .png, to: .icns))
        #expect(registry.canConvert(from: .icns, to: .png))
        #expect(registry.canConvert(from: .icns, to: .jpg))
        #expect(registry.canConvert(from: .icns, to: .webp))
        
        #expect(registry.canConvert(from: .png, to: .ico))
        #expect(registry.canConvert(from: .ico, to: .png))
        #expect(registry.canConvert(from: .ico, to: .webp))
        
        #expect(registry.canConvert(from: .png, to: .tga))
        #expect(registry.canConvert(from: .tga, to: .png))
        #expect(registry.canConvert(from: .tga, to: .jpg))
        
        // Audio bidirection
        #expect(registry.canConvert(from: .wav, to: .caf))
        #expect(registry.canConvert(from: .caf, to: .wav))
        #expect(registry.canConvert(from: .caf, to: .mp3))
        #expect(registry.canConvert(from: .caf, to: .m4a))
        
        #expect(registry.canConvert(from: .wav, to: .alac))
        #expect(registry.canConvert(from: .alac, to: .wav))
        #expect(registry.canConvert(from: .alac, to: .flac))
        #expect(registry.canConvert(from: .alac, to: .mp3))
        
        #expect(registry.canConvert(from: .wav, to: .ac3))
        #expect(registry.canConvert(from: .ac3, to: .wav))
        #expect(registry.canConvert(from: .ac3, to: .mp3))
        #expect(registry.canConvert(from: .ac3, to: .aac))
        
        // Video transcode & audio extraction from legacy / consumer containers
        #expect(registry.canConvert(from: .threeGP, to: .mp4))
        #expect(registry.canConvert(from: .threeGP, to: .mov))
        #expect(registry.canConvert(from: .threeGP, to: .mp3))
        
        #expect(registry.canConvert(from: .mts, to: .mp4))
        #expect(registry.canConvert(from: .mts, to: .mov))
        #expect(registry.canConvert(from: .mts, to: .mp3))
        
        #expect(registry.canConvert(from: .m2ts, to: .mp4))
        #expect(registry.canConvert(from: .m2ts, to: .mkv))
        #expect(registry.canConvert(from: .m2ts, to: .wav))
    }
    
    // MARK: - 4. Real Image IO Conversions
    
    @Test("Real Image Conversion: PNG <-> ICNS, ICO, TGA Roundtrips")
    func testRealImageConversions() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-Test-ImageRoundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let engine = ImageConversionEngine()
        
        // Create base source PNG (128x128 solid colored with alpha)
        let sourceURL = tempDir.appendingPathComponent("source.png")
        let width = 128
        let height = 128
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
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1.0, green: 0.3, blue: 0.2, alpha: 0.8)
        context.fillEllipse(in: CGRect(x: 20, y: 20, width: 88, height: 88))
        let cgImage = context.makeImage()!
        
        let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        
        // 1. PNG -> ICNS
        let icnsResult = try await engine.convert(
            inputs: [sourceURL],
            to: .icns,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: icnsResult.outputURL.path))
        #expect(icnsResult.outputFormat == .icns)
        #expect(icnsResult.fileSize > 0)
        
        // Verify ICNS can be read back and converted to PNG
        let backToPngFromIcns = try await engine.convert(
            inputs: [icnsResult.outputURL],
            to: .png,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: backToPngFromIcns.outputURL.path))
        let imgFromIcns = NSImage(contentsOf: backToPngFromIcns.outputURL)
        #expect(imgFromIcns != nil && imgFromIcns!.size.width > 0)
        
        // 2. PNG -> ICO
        let icoResult = try await engine.convert(
            inputs: [sourceURL],
            to: .ico,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: icoResult.outputURL.path))
        #expect(icoResult.outputFormat == .ico)
        #expect(icoResult.fileSize > 0)
        
        // Convert ICO -> WebP
        let webpFromIco = try await engine.convert(
            inputs: [icoResult.outputURL],
            to: .webp,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: webpFromIco.outputURL.path))
        #expect(webpFromIco.outputFormat == .webp)
        
        // 3. PNG -> TGA
        let tgaResult = try await engine.convert(
            inputs: [sourceURL],
            to: .tga,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: tgaResult.outputURL.path))
        #expect(tgaResult.outputFormat == .tga)
        #expect(tgaResult.fileSize > 0)
        
        // Convert TGA -> JPG
        let jpgFromTga = try await engine.convert(
            inputs: [tgaResult.outputURL],
            to: .jpg,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: jpgFromTga.outputURL.path))
        #expect(jpgFromTga.outputFormat == .jpg)
    }
    
    // MARK: - 5. Real Media Conversions: CAF, ALAC, AC3
    
    @Test("Real Audio Transcode: WAV <-> CAF, ALAC, AC3 with stream verification")
    func testRealAudioTranscode() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-Test-AudioRoundtrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard await provider.isAvailable(), let ffmpegPath = await provider.findFFmpegPath(), let ffprobePath = await provider.findFFprobePath() else {
            return
        }
        
        let engine = MediaConversionEngine(provider: provider)
        
        // Create 1-second 440Hz sine wave WAV file
        let sourceWav = tempDir.appendingPathComponent("tone.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = [
            "-y",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=1.0",
            "-c:a", "pcm_s16le",
            sourceWav.path
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        
        // 1. WAV -> CAF
        let cafResult = try await engine.convert(
            inputs: [sourceWav],
            to: .caf,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: cafResult.outputURL.path))
        let cafInfo = try await MediaProbe.probe(url: cafResult.outputURL, ffprobePath: ffprobePath)
        #expect(cafInfo.hasAudio)
        #expect(cafInfo.duration >= 0.9)
        
        // CAF -> MP3
        let mp3FromCaf = try await engine.convert(
            inputs: [cafResult.outputURL],
            to: .mp3,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: mp3FromCaf.outputURL.path))
        let mp3Info = try await MediaProbe.probe(url: mp3FromCaf.outputURL, ffprobePath: ffprobePath)
        #expect(mp3Info.hasAudio)
        
        // 2. WAV -> ALAC
        let alacResult = try await engine.convert(
            inputs: [sourceWav],
            to: .alac,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: alacResult.outputURL.path))
        let alacInfo = try await MediaProbe.probe(url: alacResult.outputURL, ffprobePath: ffprobePath)
        #expect(alacInfo.hasAudio)
        #expect(alacInfo.primaryAudioStream?.codecName == "alac")
        
        // ALAC -> FLAC
        let flacFromAlac = try await engine.convert(
            inputs: [alacResult.outputURL],
            to: .flac,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: flacFromAlac.outputURL.path))
        let flacInfo = try await MediaProbe.probe(url: flacFromAlac.outputURL, ffprobePath: ffprobePath)
        #expect(flacInfo.hasAudio)
        #expect(flacInfo.primaryAudioStream?.codecName == "flac")
        
        // 3. WAV -> AC3
        let ac3Result = try await engine.convert(
            inputs: [sourceWav],
            to: .ac3,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: ac3Result.outputURL.path))
        let ac3Info = try await MediaProbe.probe(url: ac3Result.outputURL, ffprobePath: ffprobePath)
        #expect(ac3Info.hasAudio)
        #expect(ac3Info.primaryAudioStream?.codecName == "ac3")
        
        // AC3 -> M4A
        let m4aFromAc3 = try await engine.convert(
            inputs: [ac3Result.outputURL],
            to: .m4a,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: m4aFromAc3.outputURL.path))
        let m4aInfo = try await MediaProbe.probe(url: m4aFromAc3.outputURL, ffprobePath: ffprobePath)
        #expect(m4aInfo.hasAudio)
    }
    
    // MARK: - 6. Real Video Transcode: 3GP, MTS, M2TS -> MP4 & Audio Extraction
    
    @Test("Real Video Conversion: 3GP & MTS transcode to MP4 and extract MP3")
    func testRealVideoTranscode() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LocalConvert-Test-VideoCompat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard await provider.isAvailable(), let ffmpegPath = await provider.findFFmpegPath(), let ffprobePath = await provider.findFFprobePath() else {
            return
        }
        
        let engine = MediaConversionEngine(provider: provider)
        
        // 1. Create a 1-second 3GP test video file
        let source3gp = tempDir.appendingPathComponent("sample.3gp")
        let p3gp = Process()
        p3gp.executableURL = URL(fileURLWithPath: ffmpegPath)
        p3gp.arguments = [
            "-y",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=176x144:rate=15",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "h263",
            "-c:a", "aac",
            source3gp.path
        ]
        p3gp.standardOutput = FileHandle.nullDevice
        p3gp.standardError = FileHandle.nullDevice
        try p3gp.run()
        p3gp.waitUntilExit()
        #expect(p3gp.terminationStatus == 0)
        
        // Transcode 3GP -> MP4
        let mp4From3gp = try await engine.convert(
            inputs: [source3gp],
            to: .mp4,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: mp4From3gp.outputURL.path))
        let mp4Info = try await MediaProbe.probe(url: mp4From3gp.outputURL, ffprobePath: ffprobePath)
        #expect(mp4Info.hasVideo)
        #expect(mp4Info.hasAudio)
        
        // 2. Create a 1-second MTS / MPEG-TS test video file
        let sourceMts = tempDir.appendingPathComponent("camcorder.mts")
        let pMts = Process()
        pMts.executableURL = URL(fileURLWithPath: ffmpegPath)
        pMts.arguments = [
            "-y",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=1",
            "-c:v", "h264_videotoolbox",
            "-c:a", "ac3",
            "-f", "mpegts",
            sourceMts.path
        ]
        pMts.standardOutput = FileHandle.nullDevice
        pMts.standardError = FileHandle.nullDevice
        try pMts.run()
        pMts.waitUntilExit()
        #expect(pMts.terminationStatus == 0)
        
        // Transcode MTS -> MP4
        let mp4FromMts = try await engine.convert(
            inputs: [sourceMts],
            to: .mp4,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: mp4FromMts.outputURL.path))
        let mtsMp4Info = try await MediaProbe.probe(url: mp4FromMts.outputURL, ffprobePath: ffprobePath)
        #expect(mtsMp4Info.hasVideo)
        
        // Extract Audio: MTS -> MP3
        let mp3FromMts = try await engine.convert(
            inputs: [sourceMts],
            to: .mp3,
            outputDirectory: tempDir,
            options: ConversionOptions(),
            progress: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: mp3FromMts.outputURL.path))
        let mtsMp3Info = try await MediaProbe.probe(url: mp3FromMts.outputURL, ffprobePath: ffprobePath)
        #expect(mtsMp3Info.hasAudio)
        #expect(!mtsMp3Info.hasVideo)
    }
    
    // MARK: - 7. Metadata Capabilities for Phase 18 Formats
    
    @Test("Metadata Capabilities for New Formats")
    func testMetadataCapabilities() {
        let metaRegistry = MetadataRegistry.shared
        
        // Image formats
        let dngCaps = metaRegistry.capabilities(for: .dng)
        #expect(dngCaps.canRead)
        #expect(!dngCaps.canWrite, "DNG metadata should be read-only")
        
        let psdCaps = metaRegistry.capabilities(for: .psd)
        #expect(psdCaps.canRead)
        #expect(!psdCaps.canWrite, "PSD metadata should be read-only")
        
        let icnsCaps = metaRegistry.capabilities(for: .icns)
        #expect(icnsCaps.canRead)
        
        let tgaCaps = metaRegistry.capabilities(for: .tga)
        #expect(tgaCaps.canRead)
        
        // Audio formats
        let cafCaps = metaRegistry.capabilities(for: .caf)
        #expect(cafCaps.canRead)
        
        let alacCaps = metaRegistry.capabilities(for: .alac)
        #expect(alacCaps.canRead)
        #expect(alacCaps.canRemoveArtwork)
        
        let ac3Caps = metaRegistry.capabilities(for: .ac3)
        #expect(ac3Caps.canRead)
        
        // Video formats
        let threeGPCaps = metaRegistry.capabilities(for: .threeGP)
        #expect(threeGPCaps.canRead)
        #expect(!threeGPCaps.canWrite, "3GP metadata should be read-only")
        
        let mtsCaps = metaRegistry.capabilities(for: .mts)
        #expect(mtsCaps.canRead)
        #expect(!mtsCaps.canWrite, "MTS metadata should be read-only")
    }
    
    // MARK: - 8. Smart Recommendations for Phase 18 Formats
    
    @Test("Smart Recommendations for New Formats")
    func testSmartRecommendations() {
        // DNG recommendation should prioritize webp/jpg/png/pdf
        let dngRecs = registry.recommendedOutputFormats(for: .dng)
        #expect(dngRecs.contains(.jpg))
        #expect(dngRecs.contains(.png))
        #expect(dngRecs.contains(.webp))
        #expect(!dngRecs.contains(.dng))
        
        // 3GP recommendation should prioritize mp4/webm/mp3
        let threeGPRecs = registry.recommendedOutputFormats(for: .threeGP)
        #expect(threeGPRecs.contains(.mp4))
        #expect(threeGPRecs.contains(.mp3))
        #expect(!threeGPRecs.contains(.threeGP))
        
        // CAF recommendation should prioritize mp3/m4a/flac/wav
        let cafRecs = registry.recommendedOutputFormats(for: .caf)
        #expect(cafRecs.contains(.mp3))
        #expect(cafRecs.contains(.m4a))
        #expect(!cafRecs.contains(.caf))
    }
    
    // MARK: - 9. Negative Route & Capability Guardrail Tests
    
    @Test("Comprehensive Negative Conversion Route Verification")
    func testComprehensiveNegativeRoutes() {
        // Cross-category invalid conversions
        #expect(!registry.canConvert(from: .png, to: .mp3))
        #expect(!registry.canConvert(from: .mp4, to: .docx))
        #expect(!registry.canConvert(from: .docx, to: .mp3))
        #expect(!registry.canConvert(from: .pdf, to: .svg))
        #expect(!registry.canConvert(from: .csv, to: .mp4))
        #expect(!registry.canConvert(from: .mp3, to: .png))
        #expect(!registry.canConvert(from: .mov, to: .docx))
        #expect(!registry.canConvert(from: .aac, to: .docx))
        
        // Same format conversions (always false)
        #expect(!registry.canConvert(from: .dng, to: .dng))
        #expect(!registry.canConvert(from: .psd, to: .psd))
        #expect(!registry.canConvert(from: .mts, to: .mts))
        #expect(!registry.canConvert(from: .m2ts, to: .m2ts))
        #expect(!registry.canConvert(from: .threeGP, to: .threeGP))
        
        // Read-only input formats must never be generated from other formats
        #expect(!registry.canConvert(from: .png, to: .dng))
        #expect(!registry.canConvert(from: .jpg, to: .psd))
        #expect(!registry.canConvert(from: .mp4, to: .mts))
        #expect(!registry.canConvert(from: .mov, to: .m2ts))
        #expect(!registry.canConvert(from: .mp4, to: .threeGP))
    }
}
