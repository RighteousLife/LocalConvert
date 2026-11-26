import Foundation
import CoreGraphics
import CoreText
import ImageIO

// MARK: - Contact Sheet Generator Service (Streaming Bounded Thumbnail Architecture)

enum ImageContactSheetSort: String, CaseIterable, Identifiable, Sendable {
    case filename = "Filename"
    case dateModified = "Date Modified"
    case dimensions = "Pixel Area"

    var id: String { rawValue }
}

enum ImageContactSheetFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG"
    case jpg = "JPEG"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpg: return "jpg"
        }
    }
}

struct ImageContactSheetOptions: Sendable, Equatable {
    var columns: Int = 4
    var rows: Int = 0                 // 0 = Auto-fit from count/columns
    var thumbnailMaxSize: Int = 240   // 96 ... 640 px
    var spacing: Int = 18
    var padding: Int = 28
    var showFilenames: Bool = true
    var backgroundColor: CodableRGBAColor = CodableRGBAColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1.0)
    var sortBy: ImageContactSheetSort = .filename
    var outputFormat: ImageContactSheetFormat = .png
    var jpegQuality: Double = 0.90
}

struct ImageContactSheetResult: Sendable {
    let encodedData: Data
    let previewCGImage: CGImage
    let width: Int
    let height: Int
    let itemCount: Int
    let columns: Int
    let rows: Int
}

enum ImageContactSheetService {

    /// Pure deterministic grid calculator for UI previews and tests.
    static func computeGridLayout(
        itemCount: Int,
        options: ImageContactSheetOptions
    ) -> (columns: Int, rows: Int, width: Int, height: Int, labelHeight: Int) {
        let cols = max(1, min(12, options.columns))
        let count = max(1, itemCount)
        let autoRows = Int(ceil(Double(count) / Double(cols)))
        let rows = (options.rows > 0) ? max(1, options.rows) : autoRows
        let thumb = max(64, min(640, options.thumbnailMaxSize))
        let labelH = options.showFilenames ? 24 : 0
        let cellH = thumb + labelH
        let pad = max(0, options.padding)
        let sp = max(0, options.spacing)

        let totalW = pad * 2 + cols * thumb + max(0, cols - 1) * sp
        let totalH = pad * 2 + rows * cellH + max(0, rows - 1) * sp

        // Clamp against 16,384 px canvas edge guard
        return (cols, rows, min(ImageDimensionCalculator.maxEdgePixels, totalW), min(ImageDimensionCalculator.maxEdgePixels, totalH), labelH)
    }

    static func sortURLs(_ urls: [URL], by sort: ImageContactSheetSort) -> [URL] {
        switch sort {
        case .filename:
            return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        case .dateModified:
            return urls.sorted {
                let d1 = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
                let d2 = (try? FileManager.default.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
                return d1 < d2
            }
        case .dimensions:
            return urls.sorted {
                let a1 = ImageProcessingService.inspectSourceDimensions(url: $0)
                let a2 = ImageProcessingService.inspectSourceDimensions(url: $1)
                let px1 = (a1?.width ?? 0) * (a1?.height ?? 0)
                let px2 = (a2?.width ?? 0) * (a2?.height ?? 0)
                return px1 > px2
            }
        }
    }

    /// Generates a contact sheet by decoding ONE bounded thumbnail at a time to keep RAM strictly bounded.
    static func generate(
        urls: [URL],
        options: ImageContactSheetOptions,
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> ImageContactSheetResult {
        guard !urls.isEmpty else {
            throw ConversionError.invalidInput("Select at least one image to build a contact sheet.")
        }

        let sorted = sortURLs(urls, by: options.sortBy)
        let layout = computeGridLayout(itemCount: sorted.count, options: options)
        let maxCapacity = layout.columns * layout.rows
        let activeURLs = Array(sorted.prefix(maxCapacity))

        let totalPixels = Int64(layout.width) * Int64(layout.height)
        guard totalPixels <= ImageDimensionCalculator.maxTotalPixels else {
            throw ConversionError.invalidInput("Contact sheet exceeds 100 MP ceiling (\(layout.width)×\(layout.height)). Reduce columns or thumbnail size.")
        }

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: layout.width,
            height: layout.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed("Failed to allocate contact sheet buffer.", underlyingError: nil)
        }

        ctx.setFillColor(
            red: options.backgroundColor.red,
            green: options.backgroundColor.green,
            blue: options.backgroundColor.blue,
            alpha: 1.0
        )
        ctx.fill(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))

        let thumbSize = max(64, min(640, options.thumbnailMaxSize))
        let cellH = thumbSize + layout.labelHeight
        let sp = max(0, options.spacing)
        let pad = max(0, options.padding)

        let bgLuma = 0.2126 * options.backgroundColor.red + 0.7152 * options.backgroundColor.green + 0.0722 * options.backgroundColor.blue
        let textColor = (bgLuma < 0.5)
            ? CGColor(red: 0.92, green: 0.93, blue: 0.96, alpha: 1.0)
            : CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)
        let tileBgColor = (bgLuma < 0.5)
            ? CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)
            : CGColor(red: 0.88, green: 0.89, blue: 0.92, alpha: 1.0)

        for (index, url) in activeURLs.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(1, activeURLs.count)), "Rendering \(url.lastPathComponent)...")

            let row = index / layout.columns
            let col = index % layout.columns

            // Top-down row -> CGContext bottom-up Y coordinate
            let cellX = CGFloat(pad + col * (thumbSize + sp))
            let topY = CGFloat(pad + row * (cellH + sp))
            let cellBottomY = CGFloat(layout.height) - topY - CGFloat(cellH)

            let imageRect = CGRect(
                x: cellX,
                y: cellBottomY + CGFloat(layout.labelHeight),
                width: CGFloat(thumbSize),
                height: CGFloat(thumbSize)
            )

            ctx.setFillColor(tileBgColor)
            ctx.fill(imageRect)

            // Decode strictly one bounded thumbnail per iteration
            if let decoded = try? await ImageProcessingService.decodeInputImage(url: url, maxPixelDimension: thumbSize) {
                let cg = decoded.cgImage
                let aspect = CGFloat(cg.width) / CGFloat(max(1, cg.height))
                let drawRect: CGRect
                if aspect >= 1.0 {
                    let h = imageRect.width / aspect
                    drawRect = CGRect(x: imageRect.minX, y: imageRect.minY + (imageRect.height - h) / 2.0, width: imageRect.width, height: h)
                } else {
                    let w = imageRect.height * aspect
                    drawRect = CGRect(x: imageRect.minX + (imageRect.width - w) / 2.0, y: imageRect.minY, width: w, height: imageRect.height)
                }
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: drawRect)
            }

            if options.showFilenames {
                let labelRect = CGRect(x: cellX, y: cellBottomY + 2, width: CGFloat(thumbSize), height: CGFloat(layout.labelHeight - 4))
                drawTruncatedFilename(url.lastPathComponent, in: labelRect, context: ctx, color: textColor)
            }
        }

        try Task.checkCancellation()
        progress(0.92, "Encoding contact sheet...")

        guard let outImage = ctx.makeImage() else {
            throw ConversionError.engineExecutionFailed("Failed to build final contact sheet image.", underlyingError: nil)
        }

        let fileFormat: FileFormat = (options.outputFormat == .png) ? .png : .jpg
        let data = try ImageProcessor.encodeToMemory(
            cgImage: outImage,
            format: fileFormat,
            quality: options.jpegQuality,
            lossless: (fileFormat == .png),
            sourceProperties: nil,
            preserveMetadata: false
        )

        progress(1.0, "Contact sheet ready")
        return ImageContactSheetResult(
            encodedData: data,
            previewCGImage: outImage,
            width: layout.width,
            height: layout.height,
            itemCount: activeURLs.count,
            columns: layout.columns,
            rows: layout.rows
        )
    }

    private static func drawTruncatedFilename(_ text: String, in rect: CGRect, context: CGContext, color: CGColor) {
        let truncated = text.count > 26 ? (String(text.prefix(23)) + "…") : text
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 11.0, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        guard let attrStr = CFAttributedStringCreate(nil, truncated as CFString, attrs as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        context.saveGState()
        context.textMatrix = .identity
        let x = rect.minX + max(0, (rect.width - bounds.width) / 2.0)
        let y = rect.minY + 5.0
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
