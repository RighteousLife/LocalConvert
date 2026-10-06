import Foundation
import Testing
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import LocalConvert

@Suite("Phase 23 — Image Optimization, Resize & Crop Tests")
struct Phase23Tests {
    
    // MARK: - Helper Functions
    
    private func createTestImage(
        in dir: URL,
        name: String = "sample.png",
        width: Int = 400,
        height: Int = 200,
        color: CGColor = CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
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
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        
        let ext = url.pathExtension.lowercased()
        let uti: String
        switch ext {
        case "jpg", "jpeg": uti = "public.jpeg"
        case "heic": uti = "public.heic"
        case "tiff", "tif": uti = "public.tiff"
        default: uti = "public.png"
        }
        
        let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
    
    private func getImageDimensions(url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        return (width, height)
    }
    
    // MARK: - 1. Resize Tests
    
    @Test("Image Resize: Exact Width scales height proportionally")
    func testResizeExactWidth() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.resizeMode = .exactWidth
        options.resizeWidth = 200
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 200)
        #expect(dims.height == 100)
    }
    
    @Test("Image Resize: Exact Height scales width proportionally")
    func testResizeExactHeight() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.resizeMode = .exactHeight
        options.resizeHeight = 50
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 100)
        #expect(dims.height == 50)
    }
    
    @Test("Image Resize: Exact Dimensions with aspect ratio preservation")
    func testResizeExactDimensionsPreservingAspect() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.resizeMode = .exactDimensions
        options.resizeWidth = 150
        options.resizeHeight = 150
        options.preserveAspectRatio = true
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 150)
        #expect(dims.height == 75)
    }
    
    @Test("Image Resize: Percentage scaling")
    func testResizePercentage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.resizeMode = .percentage
        options.resizePercentage = 0.50
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 200)
        #expect(dims.height == 100)
    }
    
    @Test("Image Resize: Longest Edge constraint")
    func testResizeLongestEdge() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.resizeMode = .longestEdge
        options.resizeWidth = 200 // Max edge 200
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 200)
        #expect(dims.height == 100)
    }
    
    @Test("Image Resize: Shortest Edge constraint")
    func testResizeShortestEdge() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.resizeMode = .shortestEdge
        options.resizeHeight = 50 // Shortest edge to 50
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 100)
        #expect(dims.height == 50)
    }
    
    // MARK: - 2. Crop Tests
    
    @Test("Image Crop: Center Crop 1:1 Square")
    func testCropCenterSquare() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.cropMode = .centerCrop
        options.cropAspectRatio = .square1x1
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 200)
        #expect(dims.height == 200)
    }
    
    @Test("Image Crop: Center Crop 16:9 Widescreen")
    func testCropCenter16x9() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 400)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.cropMode = .centerCrop
        options.cropAspectRatio = .ratio16x9
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 400)
        #expect(dims.height == 225)
    }
    
    @Test("Image Crop: Custom Normalized Rect")
    func testCropCustomRect() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.cropMode = .customRect
        options.cropRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 200)
        #expect(dims.height == 100)
    }
    
    // MARK: - 3. Target File Size Optimization
    
    @Test("Target File Size Optimization: JPEG output fits within target byte budget")
    func testTargetFileSizeJPEG() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 800, height: 600)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.imageOptimizationMode = .targetFileSize
        let targetBytes: Int64 = 25_000 // 25 KB target
        options.targetFileSizeBytes = targetBytes
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .jpg,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let outputSize = try #require(try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? Int64)
        #expect(outputSize > 0)
        #expect(outputSize <= targetBytes)
    }
    
    @Test("Target File Size Optimization: WebP output fits within target budget")
    func testTargetFileSizeWebP() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 800, height: 600)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.imageOptimizationMode = .targetFileSize
        let targetBytes: Int64 = 30_000 // 30 KB target
        options.targetFileSizeBytes = targetBytes
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .webp,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let outputSize = try #require(try? FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? Int64)
        #expect(outputSize > 0)
        #expect(outputSize <= targetBytes)
    }
    
    // MARK: - 4. Lossless & Preset Tests
    
    @Test("Lossless WebP Optimization: Valid bitstream produced")
    func testLosslessWebPOptimization() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 200, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.imageOptimizationMode = .lossless
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .webp,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let data = try Data(contentsOf: result.outputURL)
        #expect(WebPEncoder.validate(data))
    }
    
    @Test("Presets: Web and SmallFile presets configure image optimization properly")
    func testPresetConfiguration() {
        var webOptions = ConversionOptions()
        webOptions.preset = .web
        webOptions.applyPreset()
        #expect(webOptions.effectiveImageQuality == 0.75)
        #expect(!webOptions.preserveMetadata)
        
        var smallOptions = ConversionOptions()
        smallOptions.preset = .smallFile
        smallOptions.applyPreset()
        #expect(smallOptions.effectiveImageQuality == 0.50)
        #expect(smallOptions.effectiveTargetFileSizeBytes == 1_000_000)
        #expect(!smallOptions.preserveMetadata)
        
        var maxOptions = ConversionOptions()
        maxOptions.preset = .maximumQuality
        maxOptions.applyPreset()
        #expect(maxOptions.effectiveImageQuality == 1.0)
        #expect(maxOptions.preserveMetadata)
    }
    
    // MARK: - 5. Batch & Combined Transformations
    
    @Test("Combined Crop and Resize in single conversion")
    func testCombinedCropAndResize() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // 400x200 image -> Crop to 1:1 (200x200) -> Resize to exact width 100 (100x100)
        let inputURL = try createTestImage(in: tempDir, name: "input.png", width: 400, height: 200)
        let engine = ImageConversionEngine()
        
        var options = ConversionOptions()
        options.cropMode = .centerCrop
        options.cropAspectRatio = .square1x1
        options.resizeMode = .exactWidth
        options.resizeWidth = 100
        
        let result = try await engine.convert(
            inputs: [inputURL],
            to: .png,
            outputDirectory: tempDir,
            options: options,
            progress: { _ in }
        )
        
        let dims = try #require(getImageDimensions(url: result.outputURL))
        #expect(dims.width == 100)
        #expect(dims.height == 100)
    }
}
