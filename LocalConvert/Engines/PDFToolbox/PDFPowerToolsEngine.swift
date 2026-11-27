import Foundation
import PDFKit
import CoreGraphics
import CoreText
import AppKit

// MARK: - PDF Power Tools Models

struct PDFPowerThumbnailItem: Identifiable, Sendable {
    let id: UUID
    let sourcePageIndex: Int
    let cgImage: CGImage
    let uprightSize: CGSize
    let rotationDegrees: Int

    init(
        id: UUID = UUID(),
        sourcePageIndex: Int,
        cgImage: CGImage,
        uprightSize: CGSize,
        rotationDegrees: Int
    ) {
        self.id = id
        self.sourcePageIndex = sourcePageIndex
        self.cgImage = cgImage
        self.uprightSize = uprightSize
        self.rotationDegrees = rotationDegrees
    }
}

struct PDFPowerPageSpec: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourcePageIndex: Int
    var rotationDeltaDegrees: Int

    init(id: UUID = UUID(), sourcePageIndex: Int, rotationDeltaDegrees: Int = 0) {
        self.id = id
        self.sourcePageIndex = sourcePageIndex
        self.rotationDeltaDegrees = PDFCoordinateGeometry.normalizedRotation(rotationDeltaDegrees)
    }
}

enum PDFRedactionCoordinateSpace: Sendable, Equatable {
    /// Normalized `[0, 1]` coordinates with top-left origin (`y = 0` at top of upright page).
    case normalizedTopLeft
    /// Upright PDF points with bottom-left origin (`(0, 0)` at bottom-left of upright page).
    case uprightPDFPoints
}

struct PDFPowerRedactionRegion: Identifiable, Equatable, Sendable {
    let id: UUID
    let pageIndex: Int
    let rect: CGRect
    let coordinateSpace: PDFRedactionCoordinateSpace

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        normalizedTopLeftRect: CGRect
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = normalizedTopLeftRect
        self.coordinateSpace = .normalizedTopLeft
    }

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        uprightPDFRect: CGRect
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = uprightPDFRect
        self.coordinateSpace = .uprightPDFPoints
    }
}

struct PDFSignatureStampRequest: Equatable, Sendable {
    let pageIndex: Int
    /// Target box on the upright page in normalized top-left coordinates `[0, 1]`.
    let normalizedTopLeftRect: CGRect
    /// Normalized `[0, 1]` strokes inside the signature pad (top-left origin).
    let strokes: [[CGPoint]]
    let strokeColorHex: String
    let lineWidth: CGFloat

    init(
        pageIndex: Int,
        normalizedTopLeftRect: CGRect = CGRect(x: 0.62, y: 0.78, width: 0.30, height: 0.12),
        strokes: [[CGPoint]],
        strokeColorHex: String = "#0A2463",
        lineWidth: CGFloat = 2.5
    ) {
        self.pageIndex = pageIndex
        self.normalizedTopLeftRect = normalizedTopLeftRect
        self.strokes = strokes
        self.strokeColorHex = strokeColorHex
        self.lineWidth = max(0.5, min(12.0, lineWidth))
    }
}

enum PDFPageNumberPosition: String, CaseIterable, Identifiable, Codable, Sendable {
    case bottomCenter = "Bottom Center"
    case bottomRight = "Bottom Right"
    case bottomLeft = "Bottom Left"
    case topCenter = "Top Center"
    case topRight = "Top Right"
    case topLeft = "Top Left"

    var id: String { rawValue }
}

enum PDFPageNumberFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case pageOfTotal = "1 / N"
    case pageOnly = "1"

    var id: String { rawValue }
}

struct PDFPageNumberingOptions: Equatable, Sendable {
    var position: PDFPageNumberPosition = .bottomCenter
    var format: PDFPageNumberFormat = .pageOfTotal
    var fontSize: CGFloat = 11.0
    var margin: CGFloat = 24.0
    var startNumber: Int = 1
    var colorHex: String = "#2C2C2E"
}

struct PDFWatermarkOptions: Equatable, Sendable {
    var text: String = "CONFIDENTIAL"
    var opacity: Double = 0.24
    var angleDegrees: Double = -45.0
    var fontSize: CGFloat = 52.0
    var colorHex: String = "#8E8E93"
}

struct PDFPowerOperationSummary: Sendable, Equatable {
    let outputURL: URL
    let pageCount: Int
    let fileSize: Int64
}

struct PDFPowerRedactionSummary: Sendable, Equatable {
    let outputURL: URL
    let pageCount: Int
    let redactedPageIndices: Set<Int>
    let appliedBoxCount: Int
    let fileSize: Int64
}

struct PDFPowerFlattenResult: Sendable, Equatable {
    let outputURL: URL
    let pageCount: Int
    let flattenedAnnotationCount: Int
    let remainingAnnotationCount: Int
    let fileSize: Int64
}

struct PDFPowerSecuritySummary: Sendable, Equatable {
    let outputURL: URL
    let isEncrypted: Bool
    let isLocked: Bool
    let pageCount: Int
    let fileSize: Int64
}

// MARK: - PDF Power Tools Engine

/// Offline PDFKit + CoreGraphics power-tools engine with atomic staging and zero source-file overwrite.
enum PDFPowerToolsEngine {

    // MARK: - 1. Visual Thumbnail Page Organizer

    static func renderThumbnails(
        url: URL,
        maxDimension: CGFloat = 180,
        password: String? = nil
    ) async throws -> [PDFPowerThumbnailItem] {
        try Task.checkCancellation()
        let doc = try openAndUnlock(url: url, password: password)
        let pageCount = doc.pageCount
        let clampedDim = max(48, min(512, maxDimension))

        var items: [PDFPowerThumbnailItem] = []
        items.reserveCapacity(pageCount)

        for idx in 0..<pageCount {
            try Task.checkCancellation()
            let item: PDFPowerThumbnailItem? = autoreleasepool {
                guard let page = doc.page(at: idx) else { return nil }
                let upright = PDFCoordinateGeometry.uprightSize(for: page)
                let scale = min(clampedDim / max(1, upright.width), clampedDim / max(1, upright.height))
                let pxW = max(1, Int((upright.width * scale).rounded()))
                let pxH = max(1, Int((upright.height * scale).rounded()))

                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                guard let ctx = CGContext(
                    data: nil,
                    width: pxW,
                    height: pxH,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    return nil
                }

                ctx.setFillColor(.white)
                ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .cropBox, to: ctx)
                ctx.restoreGState()

                guard let cgImg = ctx.makeImage() else { return nil }
                return PDFPowerThumbnailItem(
                    sourcePageIndex: idx,
                    cgImage: cgImg,
                    uprightSize: upright,
                    rotationDegrees: PDFCoordinateGeometry.normalizedRotation(page.rotation)
                )
            }
            if let item {
                items.append(item)
            }
        }
        return items
    }

    static func organizePages(
        inputURL: URL,
        outputURL: URL,
        specs: [PDFPowerPageSpec],
        password: String? = nil
    ) async throws -> PDFPowerOperationSummary {
        try Task.checkCancellation()
        try validateDistinctNonEmptyDestination(inputURL: inputURL, outputURL: outputURL)
        guard !specs.isEmpty else {
            throw ConversionError.invalidInput("At least one page must remain in the organized PDF.")
        }

        let sourceDoc = try openAndUnlock(url: inputURL, password: password)
        let targetDoc = PDFDocument()
        if let attrs = sourceDoc.documentAttributes {
            targetDoc.documentAttributes = attrs
        }

        for (targetIndex, spec) in specs.enumerated() {
            try Task.checkCancellation()
            guard spec.sourcePageIndex >= 0, spec.sourcePageIndex < sourceDoc.pageCount,
                  let srcPage = sourceDoc.page(at: spec.sourcePageIndex),
                  let copied = srcPage.copy() as? PDFPage else {
                throw ConversionError.invalidInput("Page \(spec.sourcePageIndex + 1) is out of range.")
            }
            if spec.rotationDeltaDegrees != 0 {
                copied.rotation = PDFCoordinateGeometry.normalizedRotation(copied.rotation + spec.rotationDeltaDegrees)
            }
            targetDoc.insert(copied, at: targetIndex)
        }

        return try writeDocumentAtomically(targetDoc, to: outputURL, expectedPageCount: specs.count)
    }

    static func extractPages(
        inputURL: URL,
        zeroBasedIndices: [Int],
        outputURL: URL,
        password: String? = nil
    ) async throws -> PDFPowerOperationSummary {
        guard !zeroBasedIndices.isEmpty else {
            throw ConversionError.invalidInput("Select at least one page to extract.")
        }
        let specs = zeroBasedIndices.map { PDFPowerPageSpec(sourcePageIndex: $0, rotationDeltaDegrees: 0) }
        return try await organizePages(inputURL: inputURL, outputURL: outputURL, specs: specs, password: password)
    }

    // MARK: - 2. True Destructive Redaction (Rasterized Pages + Opaque Bars)

    static func applyTrueDestructiveRedaction(
        inputURL: URL,
        outputURL: URL,
        regions: [PDFPowerRedactionRegion],
        searchTerms: [String] = [],
        renderDPI: Double = 200.0,
        fillColorHex: String = "#000000",
        stripMetadata: Bool = true,
        password: String? = nil
    ) async throws -> PDFPowerRedactionSummary {
        try Task.checkCancellation()
        try validateDistinctNonEmptyDestination(inputURL: inputURL, outputURL: outputURL)

        let doc = try openAndUnlock(url: inputURL, password: password)
        let pageCount = doc.pageCount

        var rectsByPage: [Int: [CGRect]] = [:]
        var boxCount = 0

        for region in regions {
            guard region.pageIndex >= 0, region.pageIndex < pageCount,
                  let page = doc.page(at: region.pageIndex) else {
                continue
            }
            let upright = PDFCoordinateGeometry.uprightSize(for: page)
            let uprightRect: CGRect
            switch region.coordinateSpace {
            case .normalizedTopLeft:
                let nx = max(0.0, min(1.0, region.rect.origin.x))
                let ny = max(0.0, min(1.0, region.rect.origin.y))
                let nw = max(0.0, min(1.0 - nx, region.rect.width))
                let nh = max(0.0, min(1.0 - ny, region.rect.height))
                guard nw > 0.001, nh > 0.001 else { continue }
                let pdfX = nx * upright.width
                let pdfY = (1.0 - (ny + nh)) * upright.height
                uprightRect = CGRect(x: pdfX, y: pdfY, width: nw * upright.width, height: nh * upright.height)
            case .uprightPDFPoints:
                guard region.rect.width > 0.5, region.rect.height > 0.5 else { continue }
                uprightRect = region.rect
            }
            rectsByPage[region.pageIndex, default: []].append(uprightRect)
            boxCount += 1
        }

        let cleanedTerms = searchTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanedTerms.isEmpty {
            let termHits = try PDFRedactionService.findSearchRegions(
                in: inputURL,
                searchTerms: cleanedTerms,
                password: password
            )
            for hit in termHits where hit.pageIndex >= 0 && hit.pageIndex < pageCount {
                rectsByPage[hit.pageIndex, default: []].append(hit.rect.insetBy(dx: -2.0, dy: -2.0))
                boxCount += 1
            }
        }

        guard !rectsByPage.isEmpty else {
            throw ConversionError.invalidInput("No redaction areas or matching terms were provided.")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PowerRedact-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        var dummyBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var auxInfo: [CFString: Any] = [:]
        if stripMetadata {
            auxInfo[kCGPDFContextTitle] = "" as CFString
            auxInfo[kCGPDFContextAuthor] = "" as CFString
            auxInfo[kCGPDFContextSubject] = "" as CFString
            auxInfo[kCGPDFContextKeywords] = "" as CFString
            auxInfo[kCGPDFContextCreator] = "" as CFString
        }

        guard let pdfCtx = CGContext(tempOut as CFURL, mediaBox: &dummyBox, auxInfo as CFDictionary) else {
            throw ConversionError.engineExecutionFailed("Failed to create PDF context for redaction.", underlyingError: nil)
        }

        let clampedDPI = max(120.0, min(300.0, renderDPI))
        let scale = CGFloat(clampedDPI / 72.0)
        let fillCGColor = cgColor(fromHex: fillColorHex, alpha: 1.0)

        for idx in 0..<pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: idx) else { continue }
            let upright = PDFCoordinateGeometry.uprightSize(for: page)
            var pageBox = CGRect(origin: .zero, size: upright)
            let pageInfo: [CFString: Any] = [
                kCGPDFContextMediaBox: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            ]

            if let pageRects = rectsByPage[idx], !pageRects.isEmpty {
                // Remove annotations intersecting redaction boxes before drawing
                let expanded = pageRects.map { $0.insetBy(dx: -2.0, dy: -2.0) }
                for ann in page.annotations {
                    let annUpright = PDFRedactionService.convertPageRectToUpright(ann.bounds, page: page)
                    if expanded.contains(where: { $0.intersects(annUpright) }) {
                        page.removeAnnotation(ann)
                    }
                }

                // Rasterize entire page with opaque redaction bars burned directly into pixel buffer
                // and emit zero text layer on redacted pages so underlying text is unrecoverable.
                try autoreleasepool {
                    let pxW = max(1, Int((upright.width * scale).rounded()))
                    let pxH = max(1, Int((upright.height * scale).rounded()))
                    guard let bmpCtx = CGContext(
                        data: nil,
                        width: pxW,
                        height: pxH,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ) else {
                        throw ConversionError.engineExecutionFailed("Failed to allocate raster buffer for redaction.", underlyingError: nil)
                    }

                    bmpCtx.setFillColor(.white)
                    bmpCtx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                    bmpCtx.saveGState()
                    bmpCtx.scaleBy(x: scale, y: scale)
                    page.draw(with: .cropBox, to: bmpCtx)
                    bmpCtx.setFillColor(fillCGColor)
                    for r in pageRects {
                        bmpCtx.fill(r.insetBy(dx: -1.0, dy: -1.0))
                    }
                    bmpCtx.restoreGState()

                    guard let flattenedRaster = bmpCtx.makeImage() else {
                        throw ConversionError.engineExecutionFailed("Failed to render redacted page bitmap.", underlyingError: nil)
                    }

                    pdfCtx.beginPDFPage(pageInfo as CFDictionary)
                    pdfCtx.draw(flattenedRaster, in: pageBox)
                    pdfCtx.endPDFPage()
                }
            } else {
                pdfCtx.beginPDFPage(pageInfo as CFDictionary)
                pdfCtx.saveGState()
                pdfCtx.setFillColor(.white)
                pdfCtx.fill(pageBox)
                page.draw(with: .cropBox, to: pdfCtx)
                pdfCtx.restoreGState()
                pdfCtx.endPDFPage()
            }
        }

        pdfCtx.closePDF()

        guard FileManager.default.fileExists(atPath: tempOut.path),
              let verifyDoc = PDFDocument(url: tempOut),
              verifyDoc.pageCount == pageCount else {
            throw ConversionError.engineExecutionFailed("Redacted PDF failed integrity validation.", underlyingError: nil)
        }

        if !cleanedTerms.isEmpty {
            let verifyText = verifyDoc.string ?? ""
            for term in cleanedTerms {
                if verifyText.range(of: term, options: [.caseInsensitive]) != nil ||
                    !verifyDoc.findString(term, withOptions: [.caseInsensitive]).isEmpty {
                    throw ConversionError.engineExecutionFailed(
                        "Redaction verification detected residual text matching '\(term)'.",
                        underlyingError: nil
                    )
                }
            }
        }

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)
        let fileSize = fileSizeBytes(at: committedURL)
        return PDFPowerRedactionSummary(
            outputURL: committedURL,
            pageCount: pageCount,
            redactedPageIndices: Set(rectsByPage.keys),
            appliedBoxCount: boxCount,
            fileSize: fileSize
        )
    }

    // MARK: - 3. Trackpad / Mouse Signature Canvas Stamp

    static func stampSignature(
        inputURL: URL,
        outputURL: URL,
        request: PDFSignatureStampRequest,
        password: String? = nil
    ) async throws -> PDFPowerOperationSummary {
        try Task.checkCancellation()
        try validateDistinctNonEmptyDestination(inputURL: inputURL, outputURL: outputURL)

        let nonEmptyStrokes = request.strokes.filter { !$0.isEmpty }
        guard !nonEmptyStrokes.isEmpty else {
            throw ConversionError.invalidInput("Draw a signature before stamping onto the PDF.")
        }

        let doc = try openAndUnlock(url: inputURL, password: password)
        let pageCount = doc.pageCount
        guard request.pageIndex >= 0, request.pageIndex < pageCount else {
            throw ConversionError.invalidInput("Target signature page \(request.pageIndex + 1) is out of range.")
        }

        let strokeColor = cgColor(fromHex: request.strokeColorHex, alpha: 1.0)

        return try renderPagesToNewPDF(
            doc: doc,
            to: outputURL
        ) { pageIndex, uprightSize, pdfCtx in
            guard pageIndex == request.pageIndex else { return }

            let nx = max(0.0, min(1.0, request.normalizedTopLeftRect.origin.x))
            let ny = max(0.0, min(1.0, request.normalizedTopLeftRect.origin.y))
            let nw = max(0.02, min(1.0 - nx, request.normalizedTopLeftRect.width))
            let nh = max(0.02, min(1.0 - ny, request.normalizedTopLeftRect.height))

            let boxOriginX = nx * uprightSize.width
            let boxOriginY = (1.0 - (ny + nh)) * uprightSize.height
            let boxW = nw * uprightSize.width
            let boxH = nh * uprightSize.height

            pdfCtx.saveGState()
            pdfCtx.setStrokeColor(strokeColor)
            pdfCtx.setLineWidth(request.lineWidth)
            pdfCtx.setLineCap(.round)
            pdfCtx.setLineJoin(.round)

            for stroke in nonEmptyStrokes {
                let mappedPoints = stroke.map { pt in
                    CGPoint(
                        x: boxOriginX + max(0.0, min(1.0, pt.x)) * boxW,
                        y: boxOriginY + (1.0 - max(0.0, min(1.0, pt.y))) * boxH
                    )
                }
                guard let first = mappedPoints.first else { continue }
                if mappedPoints.count == 1 {
                    let dotR = max(1.0, request.lineWidth * 0.5)
                    pdfCtx.setFillColor(strokeColor)
                    pdfCtx.fillEllipse(in: CGRect(x: first.x - dotR, y: first.y - dotR, width: dotR * 2, height: dotR * 2))
                    continue
                }

                pdfCtx.beginPath()
                pdfCtx.move(to: first)
                for idx in 1..<mappedPoints.count {
                    let prev = mappedPoints[idx - 1]
                    let curr = mappedPoints[idx]
                    let mid = CGPoint(x: (prev.x + curr.x) * 0.5, y: (prev.y + curr.y) * 0.5)
                    pdfCtx.addQuadCurve(to: mid, control: prev)
                }
                if let last = mappedPoints.last {
                    pdfCtx.addLine(to: last)
                }
                pdfCtx.strokePath()
            }
            pdfCtx.restoreGState()
        }
    }

    // MARK: - 4. Flatten PDF (Bake Annotations & Form Fields Permanently)

    static func flattenPDF(
        inputURL: URL,
        outputURL: URL,
        password: String? = nil
    ) async throws -> PDFPowerFlattenResult {
        try Task.checkCancellation()
        try validateDistinctNonEmptyDestination(inputURL: inputURL, outputURL: outputURL)

        let doc = try openAndUnlock(url: inputURL, password: password)
        let pageCount = doc.pageCount

        var initialAnnotationCount = 0
        for i in 0..<pageCount {
            if let page = doc.page(at: i) {
                page.displaysAnnotations = true
                for ann in page.annotations {
                    ann.shouldDisplay = true
                    initialAnnotationCount += 1
                }
            }
        }

        let burnTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-BurnIn-\(UUID().uuidString).pdf")
        let finalTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Flatten-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: burnTemp)
            try? FileManager.default.removeItem(at: finalTemp)
        }

        let burnedDoc: PDFDocument
        if doc.write(to: burnTemp, withOptions: [.burnInAnnotationsOption: true]),
           let reopened = PDFDocument(url: burnTemp),
           reopened.pageCount == pageCount {
            burnedDoc = reopened
        } else {
            burnedDoc = doc
        }

        let remainingAfterBurnIn = (0..<burnedDoc.pageCount).reduce(0) { sum, idx in
            sum + (burnedDoc.page(at: idx)?.annotations.count ?? 0)
        }

        let sourceForCommitURL: URL
        if remainingAfterBurnIn == 0 && FileManager.default.fileExists(atPath: burnTemp.path) {
            sourceForCommitURL = burnTemp
        } else {
            // Re-render every page with its annotations & widget appearances into a clean static CGContext PDF
            // so zero editable PDFAnnotation / AcroForm widget dictionaries survive.
            var dummyBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            var auxInfo: [CFString: Any] = [:]
            if let attrs = doc.documentAttributes {
                if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { auxInfo[kCGPDFContextTitle] = t as CFString }
                if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { auxInfo[kCGPDFContextAuthor] = a as CFString }
            }

            guard let pdfCtx = CGContext(finalTemp as CFURL, mediaBox: &dummyBox, auxInfo as CFDictionary) else {
                throw ConversionError.engineExecutionFailed("Failed to allocate PDF context for flattening.", underlyingError: nil)
            }

            for idx in 0..<pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: idx) else { continue }
                let upright = PDFCoordinateGeometry.uprightSize(for: page)
                var pageBox = CGRect(origin: .zero, size: upright)
                let pageInfo: [CFString: Any] = [
                    kCGPDFContextMediaBox: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
                ]

                pdfCtx.beginPDFPage(pageInfo as CFDictionary)
                pdfCtx.saveGState()
                pdfCtx.setFillColor(.white)
                pdfCtx.fill(pageBox)

                // Draw static content from burnedDoc if available, else original page with annotations
                let renderPage = burnedDoc.page(at: idx) ?? page
                renderPage.displaysAnnotations = true
                let prevNS = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: pdfCtx, flipped: false)
                renderPage.draw(with: .cropBox, to: pdfCtx)
                NSGraphicsContext.current = prevNS
                pdfCtx.restoreGState()
                pdfCtx.endPDFPage()
            }
            pdfCtx.closePDF()
            sourceForCommitURL = finalTemp
        }

        guard let verifyDoc = PDFDocument(url: sourceForCommitURL),
              verifyDoc.pageCount == pageCount else {
            throw ConversionError.engineExecutionFailed("Flattened PDF failed integrity verification.", underlyingError: nil)
        }

        let remainingFinal = (0..<verifyDoc.pageCount).reduce(0) { sum, idx in
            sum + (verifyDoc.page(at: idx)?.annotations.count ?? 0)
        }

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(sourceForCommitURL, to: outputURL, policy: .overwrite)
        let size = fileSizeBytes(at: committedURL)

        return PDFPowerFlattenResult(
            outputURL: committedURL,
            pageCount: pageCount,
            flattenedAnnotationCount: initialAnnotationCount,
            remainingAnnotationCount: remainingFinal,
            fileSize: size
        )
    }

    // MARK: - 5. Automatic Page Numbering (1 / N)

    static func addPageNumbers(
        inputURL: URL,
        outputURL: URL,
        options: PDFPageNumberingOptions = PDFPageNumberingOptions(),
        password: String? = nil
    ) async throws -> PDFPowerOperationSummary {
        try Task.checkCancellation()
        try validateDistinctNonEmptyDestination(inputURL: inputURL, outputURL: outputURL)

        let doc = try openAndUnlock(url: inputURL, password: password)
        let totalPages = doc.pageCount
        let textColor = cgColor(fromHex: options.colorHex, alpha: 1.0)
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, max(7.0, min(36.0, options.fontSize)), nil)
        let margin = max(8.0, min(96.0, options.margin))

        return try renderPagesToNewPDF(doc: doc, to: outputURL) { pageIndex, uprightSize, pdfCtx in
            let displayNumber = options.startNumber + pageIndex
            let label: String
            switch options.format {
            case .pageOfTotal:
                label = "\(displayNumber) / \(totalPages + options.startNumber - 1)"
            case .pageOnly:
                label = "\(displayNumber)"
            }

            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: textColor
            ]
            guard let attrString = CFAttributedStringCreate(nil, label as CFString, attrs as CFDictionary) else { return }
            let line = CTLineCreateWithAttributedString(attrString)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

            let x: CGFloat
            switch options.position {
            case .bottomLeft, .topLeft:
                x = margin
            case .bottomCenter, .topCenter:
                x = (uprightSize.width - lineWidth) * 0.5
            case .bottomRight, .topRight:
                x = max(margin, uprightSize.width - margin - lineWidth)
            }

            let y: CGFloat
            switch options.position {
            case .bottomLeft, .bottomCenter, .bottomRight:
                y = margin
            case .topLeft, .topCenter, .topRight:
                y = max(margin, uprightSize.height - margin - ascent)
            }

            pdfCtx.saveGState()
            pdfCtx.textMatrix = .identity
            pdfCtx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, pdfCtx)
            pdfCtx.restoreGState()
        }
    }

    // MARK: - 6. Diagonal Translucent Text Watermark

    static func addDiagonalWatermark(
        inputURL: URL,
        outputURL: URL,
        options: PDFWatermarkOptions,
        password: String? = nil
    ) async throws -> PDFPowerOperationSummary {
        try Task.checkCancellation()
        try validateDistinctNonEmptyDestination(inputURL: inputURL, outputURL: outputURL)

        let trimmedText = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw ConversionError.invalidInput("Watermark text cannot be empty.")
        }

        let doc = try openAndUnlock(url: inputURL, password: password)
        let alpha = CGFloat(max(0.05, min(0.95, options.opacity)))
        let watermarkColor = cgColor(fromHex: options.colorHex, alpha: alpha)
        let baseFontSize = max(14.0, min(144.0, options.fontSize))
        let angleRad = CGFloat(options.angleDegrees * .pi / 180.0)

        return try renderPagesToNewPDF(doc: doc, to: outputURL) { _, uprightSize, pdfCtx in
            let maxDiagonal = hypot(uprightSize.width, uprightSize.height) * 0.68
            var fontSize = baseFontSize
            var font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
            var attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: watermarkColor
            ]
            guard var attrStr = CFAttributedStringCreate(nil, trimmedText as CFString, attrs as CFDictionary) else { return }
            var line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))

            if lineWidth > maxDiagonal && lineWidth > 1.0 {
                fontSize = max(12.0, fontSize * (maxDiagonal / lineWidth))
                font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
                attrs[kCTFontAttributeName] = font
                if let scaledAttr = CFAttributedStringCreate(nil, trimmedText as CFString, attrs as CFDictionary) {
                    attrStr = scaledAttr
                    line = CTLineCreateWithAttributedString(attrStr)
                    lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
                }
            }

            let lineHeight = ascent - descent
            pdfCtx.saveGState()
            pdfCtx.setAlpha(alpha)
            pdfCtx.translateBy(x: uprightSize.width * 0.5, y: uprightSize.height * 0.5)
            pdfCtx.rotate(by: angleRad)
            pdfCtx.textMatrix = .identity
            pdfCtx.textPosition = CGPoint(x: -lineWidth * 0.5, y: -lineHeight * 0.35)
            CTLineDraw(line, pdfCtx)
            pdfCtx.restoreGState()
        }
    }

    // MARK: - 7. Password Encryption & Decryption

    static func encryptPDF(
        inputURL: URL,
        outputURL: URL,
        userPassword: String?,
        ownerPassword: String?,
        currentPassword: String? = nil
    ) async throws -> PDFPowerSecuritySummary {
        try Task.checkCancellation()
        try validateDistinctNonEmptyDestination(inputURL: inputURL, outputURL: outputURL)

        let cleanUser = userPassword?.isEmpty == false ? userPassword : nil
        let cleanOwner = (ownerPassword?.isEmpty == false ? ownerPassword : nil) ?? cleanUser
        guard let effectiveOwner = cleanOwner else {
            throw ConversionError.invalidInput("Provide a user password or owner password to encrypt the PDF.")
        }

        let doc = try openAndUnlock(url: inputURL, password: currentPassword)
        let pageCount = doc.pageCount

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PowerEnc-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        var writeOpts: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: effectiveOwner
        ]
        if let cleanUser {
            writeOpts[.userPasswordOption] = cleanUser
        }

        guard doc.write(to: tempOut, withOptions: writeOpts) else {
            throw ConversionError.engineExecutionFailed("Failed to encrypt PDF document.", underlyingError: nil)
        }

        guard let verify = PDFDocument(url: tempOut), verify.isEncrypted else {
            throw ConversionError.engineExecutionFailed("Encrypted PDF failed security verification.", underlyingError: nil)
        }

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)
        return PDFPowerSecuritySummary(
            outputURL: committedURL,
            isEncrypted: verify.isEncrypted,
            isLocked: verify.isLocked,
            pageCount: pageCount,
            fileSize: fileSizeBytes(at: committedURL)
        )
    }

    static func decryptPDF(
        inputURL: URL,
        outputURL: URL,
        password: String
    ) async throws -> PDFPowerSecuritySummary {
        try Task.checkCancellation()
        try validateDistinctNonEmptyDestination(inputURL: inputURL, outputURL: outputURL)

        guard let doc = PDFDocument(url: inputURL) else {
            throw ConversionError.invalidInput("Unable to open PDF '\(inputURL.lastPathComponent)'.")
        }

        if doc.isLocked {
            guard !password.isEmpty, doc.unlock(withPassword: password) else {
                throw ConversionError.invalidInput("Incorrect password for protected PDF '\(inputURL.lastPathComponent)'.")
            }
        } else if doc.isEncrypted && !password.isEmpty {
            _ = doc.unlock(withPassword: password)
        }

        if doc.isEncrypted && doc.permissionsStatus != .owner {
            throw ConversionError.engineExecutionFailed(
                "Password removal requires the owner password when owner permissions are set.",
                underlyingError: nil
            )
        }

        let freshDoc = PDFDocument()
        for idx in 0..<doc.pageCount {
            if let page = doc.page(at: idx)?.copy() as? PDFPage {
                freshDoc.insert(page, at: freshDoc.pageCount)
            } else if let page = doc.page(at: idx) {
                freshDoc.insert(page, at: freshDoc.pageCount)
            }
        }
        if let attrs = doc.documentAttributes {
            freshDoc.documentAttributes = attrs
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PowerDec-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        guard freshDoc.write(to: tempOut) else {
            throw ConversionError.engineExecutionFailed("Failed to write decrypted PDF.", underlyingError: nil)
        }

        guard let verify = PDFDocument(url: tempOut),
              !verify.isEncrypted,
              !verify.isLocked,
              verify.pageCount == doc.pageCount else {
            throw ConversionError.engineExecutionFailed("Decrypted PDF still reports encryption or page mismatch.", underlyingError: nil)
        }

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)
        return PDFPowerSecuritySummary(
            outputURL: committedURL,
            isEncrypted: false,
            isLocked: false,
            pageCount: verify.pageCount,
            fileSize: fileSizeBytes(at: committedURL)
        )
    }

    // MARK: - Private Helpers

    private static func openAndUnlock(url: URL, password: String?) throws -> PDFDocument {
        try PDFPageManagementService.openAndUnlock(url: url, password: password)
    }

    private static func validateDistinctNonEmptyDestination(inputURL: URL, outputURL: URL) throws {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        let inResolved = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        let outResolved = outputURL.standardizedFileURL.resolvingSymlinksInPath()
        guard inResolved != outResolved else {
            throw ConversionError.invalidInput("PDF Power Tools never overwrite the source PDF directly.")
        }
    }

    private static func renderPagesToNewPDF(
        doc: PDFDocument,
        to outputURL: URL,
        overlayPerPage: (_ pageIndex: Int, _ uprightSize: CGSize, _ context: CGContext) -> Void
    ) throws -> PDFPowerOperationSummary {
        let pageCount = doc.pageCount
        guard pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF contains no pages.")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-PowerPDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        var dummyBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var auxInfo: [CFString: Any] = [:]
        if let attrs = doc.documentAttributes {
            if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { auxInfo[kCGPDFContextTitle] = t as CFString }
            if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { auxInfo[kCGPDFContextAuthor] = a as CFString }
        }

        guard let pdfCtx = CGContext(tempOut as CFURL, mediaBox: &dummyBox, auxInfo as CFDictionary) else {
            throw ConversionError.engineExecutionFailed("Failed to create PDF output context.", underlyingError: nil)
        }

        for idx in 0..<pageCount {
            try Task.checkCancellation()
            autoreleasepool {
                guard let page = doc.page(at: idx) else { return }
                let upright = PDFCoordinateGeometry.uprightSize(for: page)
                var pageBox = CGRect(origin: .zero, size: upright)
                let pageInfo: [CFString: Any] = [
                    kCGPDFContextMediaBox: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
                ]

                pdfCtx.beginPDFPage(pageInfo as CFDictionary)
                pdfCtx.saveGState()
                pdfCtx.setFillColor(.white)
                pdfCtx.fill(pageBox)
                page.draw(with: .cropBox, to: pdfCtx)
                pdfCtx.restoreGState()

                overlayPerPage(idx, upright, pdfCtx)
                pdfCtx.endPDFPage()
            }
        }

        pdfCtx.closePDF()

        guard FileManager.default.fileExists(atPath: tempOut.path),
              let verify = PDFDocument(url: tempOut),
              verify.pageCount == pageCount else {
            throw ConversionError.engineExecutionFailed("Output PDF failed structural verification.", underlyingError: nil)
        }

        let committedURL = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)
        return PDFPowerOperationSummary(
            outputURL: committedURL,
            pageCount: pageCount,
            fileSize: fileSizeBytes(at: committedURL)
        )
    }

    private static func writeDocumentAtomically(
        _ doc: PDFDocument,
        to outputURL: URL,
        expectedPageCount: Int
    ) throws -> PDFPowerOperationSummary {
        try PDFPageManagementService.writeAtomicallyAndVerify(
            document: doc,
            to: outputURL,
            expectedPageCount: expectedPageCount
        )
        return PDFPowerOperationSummary(
            outputURL: outputURL,
            pageCount: expectedPageCount,
            fileSize: fileSizeBytes(at: outputURL)
        )
    }

    private static func cgColor(fromHex hex: String, alpha: CGFloat) -> CGColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return CGColor(red: 0, green: 0, blue: 0, alpha: alpha)
        }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func fileSizeBytes(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
