import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum PDFPageNormalizationServiceError: Error, Equatable {
    case sourceAndOutputAreSameFile
    case outputAlreadyExists
    case sourcePageUnavailable(pageNumber: Int)
    case invalidPageGeometry(pageNumber: Int, reason: String)
    case unsafeDrawingGeometry(pageNumber: Int)
    case cannotCreatePDFContext(pageNumber: Int)
    case cannotCreateOutputPage(pageNumber: Int)
    case outputValidationFailed(String)
}

/// Creates a source-ordered, visually normalized PDF. Interactive PDF structures are not preserved.
enum PDFPageNormalizationService {
    private struct SourceGeometry {
        let visibleBox: CGRect
        let rotation: Int
        let userUnit: CGFloat
        let uprightWidthPoints: CGFloat
        let uprightHeightPoints: CGFloat

        init(pageNumber: Int, page: CGPDFPage) throws {
            let mediaBox = page.getBoxRect(.mediaBox)
            let cropBox = page.getBoxRect(.cropBox)
            guard Self.isFinitePositiveRect(mediaBox) else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "MediaBox is missing, non-finite, or has non-positive dimensions."
                )
            }
            guard Self.isFinitePositiveRect(cropBox) else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "CropBox is missing, non-finite, or has non-positive dimensions."
                )
            }

            let intersection = cropBox.intersection(mediaBox)
            guard Self.isFinitePositiveRect(intersection) else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "CropBox and MediaBox do not have a positive finite intersection."
                )
            }

            let rawRotation = Int(page.rotationAngle)
            guard rawRotation.isMultiple(of: 90) else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "Rotate must be a multiple of 90 degrees."
                )
            }
            let rotation = PDFCoordinateGeometry.normalizedRotation(rawRotation)
            guard [0, 90, 180, 270].contains(rotation) else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "Rotate is outside the supported right-angle values."
                )
            }

            let userUnit = try Self.readUserUnit(from: page, pageNumber: pageNumber)
            let unrotatedWidth = intersection.width * userUnit
            let unrotatedHeight = intersection.height * userUnit
            let uprightWidth = (rotation == 90 || rotation == 270) ? unrotatedHeight : unrotatedWidth
            let uprightHeight = (rotation == 90 || rotation == 270) ? unrotatedWidth : unrotatedHeight
            guard uprightWidth.isFinite, uprightHeight.isFinite,
                  uprightWidth > 0, uprightHeight > 0 else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "Effective physical page dimensions overflow or are non-positive."
                )
            }

            self.visibleBox = intersection
            self.rotation = rotation
            self.userUnit = userUnit
            self.uprightWidthPoints = uprightWidth
            self.uprightHeightPoints = uprightHeight
        }

        private static func readUserUnit(from page: CGPDFPage, pageNumber: Int) throws -> CGFloat {
            guard let dictionary = page.dictionary else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "Page dictionary is unavailable."
                )
            }

            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dictionary, "UserUnit", &object) else {
                return 1
            }

            var value: CGPDFReal = 0
            guard CGPDFDictionaryGetNumber(dictionary, "UserUnit", &value),
                  value.isFinite, value > 0 else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "UserUnit must be a finite positive PDF number."
                )
            }
            return value
        }

        private static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isInfinite
                && rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width > 0 && rect.height > 0
                && rect.maxX.isFinite && rect.maxY.isFinite
        }
    }

    private struct BookmarkRemapCounts {
        var preserved = 0
        var omitted = 0
        var hadOutOfBoundsDestination = false
    }

    private struct SourceDocumentSnapshot {
        let document: PDFDocument
        let pages: [PDFPage]
        let geometries: [SourceGeometry]
        let metrics: [PDFEffectivePageMetrics]
    }

    static func resolveTargetSize(
        sourceURL: URL,
        target: PDFPageSizeTarget,
        password: String? = nil
    ) throws -> PDFResolvedPageSize {
        let snapshot = try inspectSourceDocument(at: sourceURL, password: password)
        return try PDFPageSizeResolver.resolve(target: target, pages: snapshot.metrics)
    }

    static func normalize(
        sourceURL: URL,
        target: PDFPageSizeTarget,
        outputURL: URL,
        password: String? = nil,
        progress: @Sendable (ConversionProgress) -> Void = { _ in }
    ) async throws -> PDFPageOperationResult {
        try Task.checkCancellation()

        let sourceResolved = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let outputResolved = outputURL.standardizedFileURL.resolvingSymlinksInPath()
        guard sourceResolved != outputResolved else {
            throw PDFPageNormalizationServiceError.sourceAndOutputAreSameFile
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PDFPageNormalizationServiceError.outputAlreadyExists
        }

        let snapshot = try inspectSourceDocument(at: sourceURL, password: password)
        let sourceDocument = snapshot.document
        let sourcePages = snapshot.pages
        let geometries = snapshot.geometries
        let targetSize = try PDFPageSizeResolver.resolve(target: target, pages: snapshot.metrics)
        let targetWidth = CGFloat(targetSize.widthPoints)
        let targetHeight = CGFloat(targetSize.heightPoints)
        guard targetWidth.isFinite, targetHeight.isFinite,
              targetWidth > 0, targetHeight > 0 else {
            throw PDFPageNormalizationServiceError.outputValidationFailed("Resolved target dimensions cannot be represented by Core Graphics.")
        }

        var warnings: [String] = []
        if let inspection = try? PDFDocumentInspector.inspect(url: sourceURL, password: password),
           inspection.hasDigitalSignatures {
            warnings.append("The source contains digital signatures; rewriting creates an unsigned PDF.")
        }

        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let temporaryURL = outputDirectory.appendingPathComponent(
            ".\(outputURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).stage2.pdf"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let outputDocument = PDFDocument()

        var outputPages: [PDFPage] = []
        outputPages.reserveCapacity(sourcePages.count)
        var bookmarkCounts = BookmarkRemapCounts()

        for index in sourcePages.indices {
            try Task.checkCancellation()
            let pageNumber = index + 1
            progress(.determinate(Double(index) / Double(sourcePages.count), message: "Normalizing page \(pageNumber) of \(sourcePages.count)…"))
            let outputPage = try autoreleasepool {
                try renderPage(
                    sourcePage: sourcePages[index],
                    geometry: geometries[index],
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    pageNumber: pageNumber
                )
            }
            outputDocument.insert(outputPage, at: index)
            guard let insertedPage = outputDocument.page(at: index) else {
                throw PDFPageNormalizationServiceError.cannotCreateOutputPage(pageNumber: pageNumber)
            }
            outputPages.append(insertedPage)
        }

        remapOutlines(
            from: sourceDocument,
            sourceGeometries: geometries,
            outputPages: outputPages,
            into: outputDocument,
            counts: &bookmarkCounts
        )
        if bookmarkCounts.omitted > 0 {
            warnings.append("\(bookmarkCounts.omitted) bookmark destination(s) could not be mapped to an output page and were omitted.")
        }
        if bookmarkCounts.hadOutOfBoundsDestination {
            warnings.append("Bookmark destination(s) outside the visible source page were moved to the corresponding output page center.")
        }

        // Page insertion can reset PDFKit's document attributes, so apply them after the page tree is complete.
        if let attributes = sourceDocument.documentAttributes {
            outputDocument.documentAttributes = attributes
        }

        try Task.checkCancellation()
        progress(.determinate(0.92, message: "Writing and verifying normalized PDF…"))
        guard outputDocument.write(to: temporaryURL) else {
            throw ConversionError.engineExecutionFailed("Failed to write the normalized PDF staging file.", underlyingError: nil)
        }
        try validateOutput(at: temporaryURL, pageCount: sourceDocument.pageCount, targetWidth: targetWidth, targetHeight: targetHeight)
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PDFPageNormalizationServiceError.outputAlreadyExists
        }
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        progress(.determinate(1, message: "Complete"))

        let outlineNote: String? = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        return PDFPageOperationResult(
            outputURL: outputURL,
            additionalOutputURLs: [],
            pageCount: sourceDocument.pageCount,
            preservedOutlineCount: bookmarkCounts.preserved,
            omittedOutlineCount: bookmarkCounts.omitted,
            outlineLimitationNote: outlineNote,
            warnings: warnings
        )
    }

    private static func inspectSourceDocument(at sourceURL: URL, password: String?) throws -> SourceDocumentSnapshot {
        let sourceDocument = try PDFPageManagementService.openAndUnlock(url: sourceURL, password: password)
        guard sourceDocument.pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF contains no pages.")
        }

        var sourcePages: [PDFPage] = []
        var geometries: [SourceGeometry] = []
        var metrics: [PDFEffectivePageMetrics] = []
        sourcePages.reserveCapacity(sourceDocument.pageCount)
        geometries.reserveCapacity(sourceDocument.pageCount)
        metrics.reserveCapacity(sourceDocument.pageCount)

        // Preview and processing share this exact geometry inspection and resolver input.
        for index in 0..<sourceDocument.pageCount {
            try Task.checkCancellation()
            let pageNumber = index + 1
            guard let page = sourceDocument.page(at: index), let pageRef = page.pageRef else {
                throw PDFPageNormalizationServiceError.sourcePageUnavailable(pageNumber: pageNumber)
            }
            let geometry = try SourceGeometry(pageNumber: pageNumber, page: pageRef)
            guard page.rotation.isMultiple(of: 90),
                  PDFCoordinateGeometry.normalizedRotation(page.rotation) == geometry.rotation else {
                throw PDFPageNormalizationServiceError.invalidPageGeometry(
                    pageNumber: pageNumber,
                    reason: "PDFKit and Core Graphics report inconsistent page rotation."
                )
            }

            sourcePages.append(page)
            geometries.append(geometry)
            metrics.append(PDFEffectivePageMetrics(
                pageNumber: pageNumber,
                widthPoints: Double(geometry.uprightWidthPoints),
                heightPoints: Double(geometry.uprightHeightPoints)
            ))
        }

        return SourceDocumentSnapshot(
            document: sourceDocument,
            pages: sourcePages,
            geometries: geometries,
            metrics: metrics
        )
    }

    private static func renderPage(
        sourcePage: PDFPage,
        geometry: SourceGeometry,
        targetWidth: CGFloat,
        targetHeight: CGFloat,
        pageNumber: Int
    ) throws -> PDFPage {
        guard let drawPage = sourcePage.copy() as? PDFPage else {
            throw PDFPageNormalizationServiceError.sourcePageUnavailable(pageNumber: pageNumber)
        }
        drawPage.setBounds(geometry.visibleBox, for: .cropBox)
        // Draw in unrotated crop-box coordinates, then apply the validated clockwise /Rotate transform explicitly.
        drawPage.rotation = 0
        drawPage.displaysAnnotations = true

        let sourceWidth = geometry.uprightWidthPoints
        let sourceHeight = geometry.uprightHeightPoints
        let fitScale = min(targetWidth / sourceWidth, targetHeight / sourceHeight)
        let renderedWidth = sourceWidth * fitScale
        let renderedHeight = sourceHeight * fitScale
        let drawingScale = fitScale * geometry.userUnit
        guard fitScale.isFinite, fitScale > 0,
              renderedWidth.isFinite, renderedHeight.isFinite,
              drawingScale.isFinite, drawingScale > 0 else {
            throw PDFPageNormalizationServiceError.unsafeDrawingGeometry(pageNumber: pageNumber)
        }

        let targetBox = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let originX = (targetWidth - renderedWidth) * 0.5
        let originY = (targetHeight - renderedHeight) * 0.5
        guard originX.isFinite, originY.isFinite else {
            throw PDFPageNormalizationServiceError.unsafeDrawingGeometry(pageNumber: pageNumber)
        }

        var mediaBox = targetBox
        let pageData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pageData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFPageNormalizationServiceError.cannotCreatePDFContext(pageNumber: pageNumber)
        }

        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: rectData(targetBox),
            kCGPDFContextCropBox: rectData(targetBox),
            kCGPDFContextBleedBox: rectData(targetBox),
            kCGPDFContextTrimBox: rectData(targetBox),
            kCGPDFContextArtBox: rectData(targetBox)
        ]
        context.beginPDFPage(pageInfo as CFDictionary)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(targetBox)
        context.saveGState()
        context.clip(to: targetBox)
        context.translateBy(x: originX, y: originY)
        context.scaleBy(x: drawingScale, y: drawingScale)
        switch geometry.rotation {
        case 90:
            context.translateBy(x: 0, y: geometry.visibleBox.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: geometry.visibleBox.width, y: geometry.visibleBox.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: geometry.visibleBox.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        drawPage.draw(with: .cropBox, to: context)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()

        guard let pageDocument = PDFDocument(data: pageData as Data),
              let outputPage = pageDocument.page(at: 0) else {
            throw PDFPageNormalizationServiceError.cannotCreateOutputPage(pageNumber: pageNumber)
        }
        outputPage.setBounds(targetBox, for: .mediaBox)
        outputPage.setBounds(targetBox, for: .cropBox)
        outputPage.setBounds(targetBox, for: .bleedBox)
        outputPage.setBounds(targetBox, for: .trimBox)
        outputPage.setBounds(targetBox, for: .artBox)
        outputPage.rotation = 0
        return outputPage
    }

    private static func rectData(_ rect: CGRect) -> CFData {
        var value = rect
        return Data(bytes: &value, count: MemoryLayout<CGRect>.size) as CFData
    }

    private static func validateOutput(
        at url: URL,
        pageCount: Int,
        targetWidth: CGFloat,
        targetHeight: CGFloat
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let document = PDFDocument(url: url),
              document.pageCount == pageCount else {
            throw PDFPageNormalizationServiceError.outputValidationFailed("Written PDF could not be reopened or its page count changed.")
        }

        let expected = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        let boxes: [PDFDisplayBox] = [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), page.rotation == 0 else {
                throw PDFPageNormalizationServiceError.outputValidationFailed("Output page \(index + 1) is missing or rotated.")
            }
            for box in boxes {
                let actual = page.bounds(for: box)
                guard approximatelyEqual(actual, expected) else {
                    throw PDFPageNormalizationServiceError.outputValidationFailed("Output page \(index + 1) has a non-normalized \(box) box.")
                }
            }
        }
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.02
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func remapOutlines(
        from source: PDFDocument,
        sourceGeometries: [SourceGeometry],
        outputPages: [PDFPage],
        into output: PDFDocument,
        counts: inout BookmarkRemapCounts
    ) {
        guard let sourceRoot = source.outlineRoot else { return }
        let targetRoot = PDFOutline()

        func transformedDestination(pageIndex: Int, point: CGPoint) -> PDFDestination? {
            guard sourceGeometries.indices.contains(pageIndex), outputPages.indices.contains(pageIndex) else {
                return nil
            }
            let geometry = sourceGeometries[pageIndex]
            let box = geometry.visibleBox
            let isInside = point.x.isFinite && point.y.isFinite
                && point.x >= box.minX && point.x <= box.maxX
                && point.y >= box.minY && point.y <= box.maxY
            let sourcePoint = isInside
                ? point
                : CGPoint(x: box.midX, y: box.midY)
            if !isInside { counts.hadOutOfBoundsDestination = true }

            let rx = (sourcePoint.x - box.minX) / box.width
            let ry = (sourcePoint.y - box.minY) / box.height
            let uprightX: CGFloat
            let uprightY: CGFloat
            switch geometry.rotation {
            case 90:
                uprightX = ry * box.height
                uprightY = (1 - rx) * box.width
            case 180:
                uprightX = (1 - rx) * box.width
                uprightY = (1 - ry) * box.height
            case 270:
                uprightX = (1 - ry) * box.height
                uprightY = rx * box.width
            default:
                uprightX = rx * box.width
                uprightY = ry * box.height
            }

            let scale = min(
                CGFloat(outputPages[pageIndex].bounds(for: .mediaBox).width) / geometry.uprightWidthPoints,
                CGFloat(outputPages[pageIndex].bounds(for: .mediaBox).height) / geometry.uprightHeightPoints
            )
            let contentWidth = geometry.uprightWidthPoints * scale
            let contentHeight = geometry.uprightHeightPoints * scale
            let xOffset = (outputPages[pageIndex].bounds(for: .mediaBox).width - contentWidth) * 0.5
            let yOffset = (outputPages[pageIndex].bounds(for: .mediaBox).height - contentHeight) * 0.5
            let destinationPoint = CGPoint(
                x: xOffset + uprightX * geometry.userUnit * scale,
                y: yOffset + uprightY * geometry.userUnit * scale
            )
            guard destinationPoint.x.isFinite, destinationPoint.y.isFinite else {
                return nil
            }
            return PDFDestination(page: outputPages[pageIndex], at: destinationPoint)
        }

        func clone(_ node: PDFOutline) -> PDFOutline? {
            var targetDestination: PDFDestination?
            var hasPageTarget = false
            var pageTargetCouldNotMap = false

            if let destination = node.destination, let page = destination.page {
                hasPageTarget = true
                let index = source.index(for: page)
                if index != NSNotFound {
                    targetDestination = transformedDestination(pageIndex: index, point: destination.point)
                }
                pageTargetCouldNotMap = targetDestination == nil
            } else if let action = node.action as? PDFActionGoTo, let page = action.destination.page {
                hasPageTarget = true
                let index = source.index(for: page)
                if index != NSNotFound {
                    targetDestination = transformedDestination(pageIndex: index, point: action.destination.point)
                }
                pageTargetCouldNotMap = targetDestination == nil
            }

            var children: [PDFOutline] = []
            if node.numberOfChildren > 0 {
                for index in 0..<node.numberOfChildren {
                    if let child = node.child(at: index), let copy = clone(child) {
                        children.append(copy)
                    }
                }
            }
            if hasPageTarget && pageTargetCouldNotMap && children.isEmpty {
                counts.omitted += 1
                return nil
            }

            let copy = PDFOutline()
            copy.label = node.label
            copy.isOpen = node.isOpen
            if let targetDestination {
                copy.destination = targetDestination
                counts.preserved += 1
            } else if let action = node.action, !(action is PDFActionGoTo) {
                copy.action = action
                counts.preserved += 1
            } else if hasPageTarget && pageTargetCouldNotMap {
                copy.destination = children.first?.destination
                counts.omitted += 1
            }
            for child in children { copy.insertChild(child, at: copy.numberOfChildren) }
            return copy
        }

        if sourceRoot.numberOfChildren > 0 {
            for index in 0..<sourceRoot.numberOfChildren {
                if let child = sourceRoot.child(at: index), let copy = clone(child) {
                    targetRoot.insertChild(copy, at: targetRoot.numberOfChildren)
                }
            }
        }
        if targetRoot.numberOfChildren > 0 { output.outlineRoot = targetRoot }
    }
}
