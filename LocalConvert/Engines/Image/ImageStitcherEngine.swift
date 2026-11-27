import Foundation
import CoreGraphics
import ImageIO
import AppKit
import UniformTypeIdentifiers

// MARK: - Multi-Image Stitcher Models

enum ImageStitchDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case vertical = "Vertical"
    case horizontal = "Horizontal"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .vertical: return String(localized: "Vertical")
        case .horizontal: return String(localized: "Horizontal")
        }
    }
}

enum ImageStitchAlignment: String, CaseIterable, Identifiable, Codable, Sendable {
    case leading = "Leading"
    case center = "Center"
    case trailing = "Trailing"

    var id: String { rawValue }
}

struct ImageStitchOptions: Sendable, Equatable {
    var direction: ImageStitchDirection = .vertical
    var spacing: Int = 0
    var alignment: ImageStitchAlignment = .center
    var backgroundColor: CodableRGBAColor = CodableRGBAColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    var outputFormat: FileFormat = .png
    var quality: Double = 0.92
    var existingFileHandling: ExistingFileHandling = .createUnique

    init(
        direction: ImageStitchDirection = .vertical,
        spacing: Int = 0,
        alignment: ImageStitchAlignment = .center,
        backgroundColor: CodableRGBAColor = CodableRGBAColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        outputFormat: FileFormat = .png,
        quality: Double = 0.92,
        existingFileHandling: ExistingFileHandling = .createUnique
    ) {
        self.direction = direction
        self.spacing = max(0, spacing)
        self.alignment = alignment
        self.backgroundColor = backgroundColor
        self.outputFormat = outputFormat
        self.quality = quality
        self.existingFileHandling = existingFileHandling
    }

    init(
        direction: ImageStitchDirection = .vertical,
        spacing: Int = 0,
        alignment: ImageStitchAlignment = .center,
        nsBackgroundColor: NSColor,
        outputFormat: FileFormat = .png,
        quality: Double = 0.92,
        existingFileHandling: ExistingFileHandling = .createUnique
    ) {
        let converted = nsBackgroundColor.usingColorSpace(.sRGB) ?? nsBackgroundColor
        let rgba = CodableRGBAColor(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
        self.init(
            direction: direction,
            spacing: spacing,
            alignment: alignment,
            backgroundColor: rgba,
            outputFormat: outputFormat,
            quality: quality,
            existingFileHandling: existingFileHandling
        )
    }
}

struct ImageStitchResult: Sendable, Equatable {
    let outputURL: URL
    let width: Int
    let height: Int
    let stitchedCount: Int
    let direction: ImageStitchDirection
    let fileSize: Int64
}

// MARK: - Pure CoreGraphics Multi-Image Stitcher Engine

enum ImageStitcherEngine {

    static let maxCanvasEdgePixels = ImageDimensionCalculator.maxEdgePixels
    static let maxCanvasTotalPixels = ImageDimensionCalculator.maxTotalPixels

    /// Pure geometry helper computing final canvas dimensions for vertical/horizontal stitching.
    static func computeCanvasSize(
        imageSizes: [CGSize],
        direction: ImageStitchDirection,
        spacing: Int
    ) throws -> CGSize {
        guard imageSizes.count >= 2 else {
            throw ConversionError.invalidInput("Select at least 2 images to stitch.")
        }
        let gap = max(0, spacing)
        let totalGap = CGFloat(gap) * CGFloat(imageSizes.count - 1)

        var totalW: CGFloat = 0
        var totalH: CGFloat = 0

        for size in imageSizes {
            guard size.width > 0, size.height > 0 else {
                throw ConversionError.invalidInput("Cannot stitch an image with zero dimensions.")
            }
            switch direction {
            case .vertical:
                totalW = max(totalW, size.width)
                totalH += size.height
            case .horizontal:
                totalW += size.width
                totalH = max(totalH, size.height)
            }
        }

        switch direction {
        case .vertical:
            totalH += totalGap
        case .horizontal:
            totalW += totalGap
        }

        let wInt = Int(totalW.rounded())
        let hInt = Int(totalH.rounded())
        guard wInt > 0, hInt > 0,
              wInt <= maxCanvasEdgePixels, hInt <= maxCanvasEdgePixels else {
            throw ConversionError.invalidInput(
                "Stitched canvas dimensions (\(wInt)×\(hInt)) exceed the \(maxCanvasEdgePixels)px edge limit."
            )
        }
        let (totalPixels, overflow) = Int64(wInt).multipliedReportingOverflow(by: Int64(hInt))
        guard !overflow, totalPixels <= maxCanvasTotalPixels else {
            throw ConversionError.invalidInput(
                "Stitched canvas (\(wInt)×\(hInt)) exceeds the 100 MP memory safety limit."
            )
        }

        return CGSize(width: wInt, height: hInt)
    }

    /// Stitches multiple images vertically or horizontally using pure CoreGraphics and commits output atomically.
    static func stitch(
        inputURLs: [URL],
        outputDirectory: URL,
        options: ImageStitchOptions = ImageStitchOptions(),
        baseNameOverride: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> ImageStitchResult {
        try Task.checkCancellation()

        guard inputURLs.count >= 2 else {
            throw ConversionError.invalidInput("Select at least 2 images to stitch together.")
        }
        try OutputReservationCoordinator.validateWritableDirectory(outputDirectory)

        for url in inputURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConversionError.inputFileNotFound(url)
            }
        }

        progress(.determinate(0.05, message: String(localized: "Inspecting image dimensions...")))

        var inspectedSizes: [CGSize] = []
        inspectedSizes.reserveCapacity(inputURLs.count)

        for url in inputURLs {
            try Task.checkCancellation()
            if let dims = ImageProcessingService.inspectSourceDimensions(url: url),
               dims.width > 0, dims.height > 0 {
                inspectedSizes.append(CGSize(width: dims.width, height: dims.height))
            } else {
                let decoded = try await ImageProcessingService.decodeInputImage(url: url)
                inspectedSizes.append(CGSize(width: decoded.cgImage.width, height: decoded.cgImage.height))
            }
        }

        let gap = max(0, options.spacing)
        let canvasSize = try computeCanvasSize(
            imageSizes: inspectedSizes,
            direction: options.direction,
            spacing: gap
        )
        let canvasW = Int(canvasSize.width)
        let canvasH = Int(canvasSize.height)

        let supportsAlpha = FormatCapabilityRegistry.shared.capability(for: options.outputFormat).supportsTransparency
        let effectiveAlpha = supportsAlpha ? CGFloat(max(0.0, min(1.0, options.backgroundColor.alpha))) : 1.0
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = (supportsAlpha && effectiveAlpha < 0.999)
            ? (CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            : (CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        guard let context = CGContext(
            data: nil,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate CoreGraphics canvas for image stitching.", underlyingError: nil)
        }

        let bgCGColor = CGColor(
            colorSpace: colorSpace,
            components: [
                CGFloat(max(0.0, min(1.0, options.backgroundColor.red))),
                CGFloat(max(0.0, min(1.0, options.backgroundColor.green))),
                CGFloat(max(0.0, min(1.0, options.backgroundColor.blue))),
                effectiveAlpha
            ]
        ) ?? CGColor.white

        if effectiveAlpha <= 0.001 && supportsAlpha {
            context.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        } else {
            context.setFillColor(bgCGColor)
            context.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        }

        // Draw images sequentially (one decoded CGImage in memory at a time)
        var cursorOffset: CGFloat = 0
        for (index, url) in inputURLs.enumerated() {
            try Task.checkCancellation()
            progress(.determinate(
                0.1 + (Double(index) / Double(inputURLs.count)) * 0.75,
                message: String(localized: "Stitching image \(index + 1) of \(inputURLs.count)...")
            ))

            let decoded = try await ImageProcessingService.decodeInputImage(url: url)
            autoreleasepool {
                let cgImage = decoded.cgImage
                let imgW = CGFloat(cgImage.width)
                let imgH = CGFloat(cgImage.height)

                let drawRect: CGRect
                switch options.direction {
                case .vertical:
                    // First image goes at top (CoreGraphics origin is bottom-left)
                    let originY = CGFloat(canvasH) - cursorOffset - imgH
                    let originX: CGFloat
                    switch options.alignment {
                    case .leading:
                        originX = 0
                    case .center:
                        originX = (CGFloat(canvasW) - imgW) * 0.5
                    case .trailing:
                        originX = CGFloat(canvasW) - imgW
                    }
                    drawRect = CGRect(x: originX.rounded(), y: originY.rounded(), width: imgW, height: imgH)
                    cursorOffset += imgH + CGFloat(gap)

                case .horizontal:
                    let originX = cursorOffset
                    let originY: CGFloat
                    switch options.alignment {
                    case .leading:
                        originY = CGFloat(canvasH) - imgH
                    case .center:
                        originY = (CGFloat(canvasH) - imgH) * 0.5
                    case .trailing:
                        originY = 0
                    }
                    drawRect = CGRect(x: originX.rounded(), y: originY.rounded(), width: imgW, height: imgH)
                    cursorOffset += imgW + CGFloat(gap)
                }

                context.interpolationQuality = .high
                context.draw(cgImage, in: drawRect)
            }
        }

        try Task.checkCancellation()
        progress(.determinate(0.90, message: String(localized: "Encoding stitched image...")))

        guard let stitchedCGImage = context.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to finalize stitched CoreGraphics image.", underlyingError: nil)
        }

        let targetFormat: FileFormat = FormatCapabilityRegistry.shared.capability(for: options.outputFormat).canWrite
            ? options.outputFormat
            : .png

        let encodedData = try ImageProcessor.encodeToMemory(
            cgImage: stitchedCGImage,
            format: targetFormat,
            quality: options.quality,
            lossless: (targetFormat == .png),
            sourceProperties: nil,
            preserveMetadata: false
        )

        let baseStem: String
        if let customBase = baseNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !customBase.isEmpty {
            baseStem = customBase
        } else {
            let firstStem = FileFormat.baseNameByStrippingExtension(from: inputURLs[0])
            let dirToken = options.direction == .vertical ? "vertical" : "horizontal"
            baseStem = "\(firstStem)_stitched_\(dirToken)"
        }

        let reservedOutputURL = try OutputReservationCoordinator.reserveUniqueOutputURL(
            directory: outputDirectory,
            baseName: baseStem,
            extension: targetFormat.fileExtension,
            sourceURL: inputURLs[0],
            policy: options.existingFileHandling == .overwrite ? .createUnique : options.existingFileHandling
        )
        defer { OutputReservationCoordinator.releaseReservedOutputURL(reservedOutputURL) }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Stitch-\(UUID().uuidString).\(targetFormat.fileExtension)")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        try encodedData.write(to: tempOut, options: .atomic)
        let finalURL = try OutputReservationCoordinator.moveOrReplaceTempFile(
            tempOut,
            to: reservedOutputURL,
            policy: options.existingFileHandling == .overwrite ? .createUnique : options.existingFileHandling
        )

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? Int64(encodedData.count)
        progress(.determinate(1.0, message: String(localized: "Complete")))

        return ImageStitchResult(
            outputURL: finalURL,
            width: canvasW,
            height: canvasH,
            stitchedCount: inputURLs.count,
            direction: options.direction,
            fileSize: fileSize
        )
    }
}
