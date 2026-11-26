import Foundation
import PDFKit
import CoreGraphics
import Quartz
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Advanced PDF Compression Service

enum PDFCompressionService {

    /// Estimates approximate compressed output size without misleading guarantees.
    static func estimateSizeRange(originalBytes: Int64, options: PDFCompressionOptions) -> ClosedRange<Int64>? {
        guard originalBytes > 0 else { return nil }
        let factorRange: ClosedRange<Double>
        switch options.profile {
        case .maximumQuality:
            factorRange = 0.85...1.02
        case .balanced:
            factorRange = 0.35...0.75
        case .smallFile:
            factorRange = 0.20...0.55
        case .webOptimized:
            factorRange = 0.30...0.70
        case .emailAttachment:
            factorRange = 0.15...0.45
        case .custom:
            if options.imageCodec == .losslessFlate {
                factorRange = 0.80...1.02
            } else {
                let scaleFactor = min(1.0, options.targetDPI / 220.0) * options.imageQuality
                let low = max(0.12, scaleFactor * 0.35)
                let high = min(0.95, scaleFactor * 0.90)
                factorRange = low...max(low + 0.05, high)
            }
        }
        return Int64(Double(originalBytes) * factorRange.lowerBound)...Int64(Double(originalBytes) * factorRange.upperBound)
    }

    static func compress(
        inputURL: URL,
        outputURL: URL,
        options: PDFCompressionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFCompressionResultInfo {
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ConversionError.inputFileNotFound(inputURL)
        }
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw ConversionError.invalidInput("Compression output cannot overwrite the source PDF.")
        }

        let originalSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0

        guard let doc = PDFDocument(url: inputURL) else {
            throw ConversionError.invalidInput("Unable to open PDF '\(inputURL.lastPathComponent)'.")
        }
        if doc.isLocked {
            if let pwd = options.password, !pwd.isEmpty {
                guard doc.unlock(withPassword: pwd) else {
                    throw ConversionError.invalidInput("Incorrect password for protected PDF '\(inputURL.lastPathComponent)'.")
                }
            } else {
                throw ConversionError.invalidInput("The PDF '\(inputURL.lastPathComponent)' is password-protected.")
            }
        }

        let pageCount = doc.pageCount
        guard pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF contains no pages.")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Compress-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let preInspect = try? PDFDocumentInspector.inspect(url: inputURL, password: options.password)
        let preOutlinesCount = countOutlineItems(doc.outlineRoot)

        // Determine effective optimization tier
        enum EffectiveTier {
            case losslessCleanup
            case quartzOptimized
            case structurePreservingScreen
            case rasterizePages
        }

        let effectiveTier: EffectiveTier
        if options.profile == .maximumQuality || options.imageCodec == .losslessFlate || options.strategy == .losslessCleanup {
            effectiveTier = .losslessCleanup
        } else if options.profile == .webOptimized || options.strategy == .structurePreserving {
            effectiveTier = .structurePreservingScreen
        } else if options.strategy == .quartzOptimized {
            effectiveTier = .quartzOptimized
        } else {
            effectiveTier = .rasterizePages
        }

        var extraWarnings: [String] = []
        if effectiveTier == .quartzOptimized || effectiveTier == .rasterizePages {
            if (preInspect?.hasAcroForm ?? false) || (preInspect?.formFieldCount ?? 0) > 0 {
                extraWarnings.append(effectiveTier == .quartzOptimized
                    ? "Quartz vector optimization flattens interactive AcroForm fields; use Structure-Preserving (PDFKit) to retain editable widgets."
                    : "Rasterize Pages flattens interactive AcroForm fields into page pixels.")
            }
            if preInspect?.hasDigitalSignatures == true {
                extraWarnings.append("Source PDF contains digital signatures; rewriting or optimizing invalidates cryptographic signatures.")
            }
        } else if preInspect?.hasDigitalSignatures == true {
            extraWarnings.append("Source PDF contains digital signatures; modifying or rewriting invalidates cryptographic signatures.")
        }

        switch effectiveTier {
        case .losslessCleanup:
            progress(.determinate(0.35, message: "Rewriting PDF streams losslessly..."))
            if options.stripMetadata {
                doc.documentAttributes = [:]
            }
            guard doc.write(to: tempOut) else {
                throw ConversionError.engineExecutionFailed("Failed to write lossless optimized PDF.", underlyingError: nil)
            }

        case .structurePreservingScreen:
            progress(.determinate(0.35, message: "Optimizing embedded images while preserving structure & forms..."))
            if options.stripMetadata {
                doc.documentAttributes = [:]
            }
            let writeOpts: [PDFDocumentWriteOption: Any] = [
                .saveImagesAsJPEGOption: true,
                .optimizeImagesForScreenOption: true
            ]
            guard doc.write(to: tempOut, withOptions: writeOpts) else {
                throw ConversionError.engineExecutionFailed("Failed to write structure-preserving optimized PDF.", underlyingError: nil)
            }

        case .quartzOptimized:
            try performQuartzVectorPreservingPass(
                sourceDoc: doc,
                sourceURL: inputURL,
                tempOut: tempOut,
                options: options,
                progress: progress
            )

        case .rasterizePages:
            let targetDPI = max(72.0, min(300.0, options.targetDPI))
            let quality = max(0.15, min(1.0, options.imageQuality))
            let scale = CGFloat(targetDPI / 72.0)

            var dummyBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            var auxInfo: [CFString: Any] = [:]
            if !options.stripMetadata, let attrs = doc.documentAttributes {
                if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { auxInfo[kCGPDFContextTitle] = t as CFString }
                if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { auxInfo[kCGPDFContextAuthor] = a as CFString }
            }

            guard let pdfCtx = CGContext(tempOut as CFURL, mediaBox: &dummyBox, auxInfo as CFDictionary) else {
                throw ConversionError.engineExecutionFailed("Failed to allocate PDF compression context.", underlyingError: nil)
            }

            let targetColorSpace: CGColorSpace = options.grayscale
                ? CGColorSpaceCreateDeviceGray()
                : CGColorSpaceCreateDeviceRGB()
            let bitmapInfo: UInt32 = options.grayscale
                ? CGImageAlphaInfo.none.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue

            for idx in 0..<pageCount {
                try Task.checkCancellation()
                progress(.determinate(
                    Double(idx) / Double(pageCount),
                    message: "Rasterizing page \(idx + 1) of \(pageCount) at \(Int(targetDPI)) DPI..."
                ))

                autoreleasepool {
                    guard let page = doc.page(at: idx) else { return }
                    let uSize = PDFCoordinateGeometry.uprightSize(for: page)
                    let uBox = CGRect(origin: .zero, size: uSize)
                    var pageMediaBox = uBox
                    let pageInfo: [CFString: Any] = [
                        kCGPDFContextMediaBox: Data(bytes: &pageMediaBox, count: MemoryLayout<CGRect>.size) as CFData
                    ]

                    let pxW = max(1, Int((uSize.width * scale).rounded()))
                    let pxH = max(1, Int((uSize.height * scale).rounded()))
                    guard let bmpCtx = CGContext(
                        data: nil,
                        width: pxW,
                        height: pxH,
                        bitsPerComponent: 8,
                        bytesPerRow: 0,
                        space: targetColorSpace,
                        bitmapInfo: bitmapInfo
                    ) else {
                        return
                    }
                    bmpCtx.setFillColor(.white)
                    bmpCtx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
                    bmpCtx.saveGState()
                    bmpCtx.scaleBy(x: scale, y: scale)
                    page.draw(with: .cropBox, to: bmpCtx)
                    bmpCtx.restoreGState()

                    if let rendered = bmpCtx.makeImage(),
                       let encodedImage = reencodeRaster(rendered, codec: options.imageCodec, quality: quality) {
                        pdfCtx.beginPDFPage(pageInfo as CFDictionary)
                        pdfCtx.draw(encodedImage, in: uBox)
                        pdfCtx.endPDFPage()
                    }
                }
            }

            try Task.checkCancellation()
            pdfCtx.closePDF()
        }

        // Metadata / XMP deep cleanup & verification
        if options.stripMetadata {
            PDFMetadataProvider.stripEmbeddedXMPStreamsPreservingOffsets(at: tempOut)
        }

        // Independent integrity validation before moving to destination
        guard FileManager.default.fileExists(atPath: tempOut.path),
              let verifyDoc = PDFDocument(url: tempOut),
              verifyDoc.pageCount == pageCount else {
            throw ConversionError.engineExecutionFailed("Compressed PDF failed post-write integrity validation.", underlyingError: nil)
        }

        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)

        let postInspect = try? PDFDocumentInspector.inspect(url: outputURL)
        let compressedSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0

        var metadataVerified = false
        var xmpNote: String? = nil
        if options.stripMetadata {
            let userKeys: [PDFDocumentAttribute] = [
                .titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute
            ]
            let remainingUserAttrs: [Any] = userKeys.compactMap { key -> Any? in
                guard let val = verifyDoc.documentAttributes?[key] else { return nil }
                if let arr = val as? [String] {
                    return arr.isEmpty ? nil : arr
                }
                let s = String(describing: val).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            let residualXMP = (postInspect?.xmpSummary != nil)
            if remainingUserAttrs.isEmpty && !residualXMP {
                metadataVerified = true
                xmpNote = "Verified: user document info metadata and catalog XMP metadata stream removed (PDFKit retains generator timestamps/Producer)."
            } else {
                metadataVerified = false
                xmpNote = residualXMP
                    ? "Notice: compressed XMP /ObjStm packet could not be byte-patched by PDFKit; user info attributes cleared."
                    : "Notice: some read-only creator attributes remain after PDFKit write."
            }
        }

        let preservesVectors = (effectiveTier != .rasterizePages)
        var preserved: [String] = []
        var discarded: [String] = []
        if preservesVectors {
            preserved.append("Vector Text & Typography")
            if (postInspect?.annotationCount ?? 0) > 0 { preserved.append("Links & Annotations") }
            if (postInspect?.formFieldCount ?? 0) > 0 { preserved.append("AcroForm Fields") }
            if countOutlineItems(verifyDoc.outlineRoot) > 0 { preserved.append("Bookmarks / Outlines") }
            if preInspect?.hasDigitalSignatures == true && (postInspect?.hasDigitalSignatures == false) {
                discarded.append("Digital Signatures (invalidated by rewrite)")
            }
            if effectiveTier == .quartzOptimized && (preInspect?.formFieldCount ?? 0) > 0 {
                discarded.append("AcroForm Fields (flattened by Quartz pass)")
            }
        } else {
            if !(doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                discarded.append("Selectable Vector Text")
            }
            if (preInspect?.annotationCount ?? 0) > 0 { discarded.append("Links & Annotations (\(preInspect!.annotationCount))") }
            if (preInspect?.formFieldCount ?? 0) > 0 { discarded.append("AcroForm Fields (\(preInspect!.formFieldCount))") }
            if preOutlinesCount > 0 { discarded.append("Bookmarks / Outlines (\(preOutlinesCount))") }
            if preInspect?.hasDigitalSignatures == true { discarded.append("Digital Signatures") }
            if preInspect?.hasStructureTree == true { discarded.append("Accessibility StructTree") }
            if preInspect?.hasEmbeddedFiles == true { discarded.append("Embedded Files") }
        }

        let isLinearized = postInspect?.isLinearized ?? false
        let linNote = isLinearized
            ? "Linearized Fast Web View dictionary detected."
            : "Not byte-range linearized (macOS PDFKit does not write /Linearized hint tables)."

        let tradeOff: String
        switch effectiveTier {
        case .losslessCleanup:
            tradeOff = "Lossless structure rewrite; vector typography, images, and forms preserved without lossy re-encoding."
        case .quartzOptimized:
            tradeOff = "Vector-preserving Quartz optimization (\(Int(options.targetDPI)) DPI, \(Int(options.imageQuality * 100))% JPEG); vector text, outlines, and markup kept."
        case .structurePreservingScreen:
            tradeOff = "Structure-preserving screen image optimization (JPEG); vector typography, links, outlines, and forms kept."
        case .rasterizePages:
            tradeOff = "Rasterized pages at \(Int(options.targetDPI)) DPI (\(options.grayscale ? "Grayscale, " : "")\(options.imageCodec.rawValue), \(Int(options.imageQuality * 100))%). Vector text and interactive layers flattened."
        }

        let fontNote = "Font streams kept intact (\(postInspect?.fonts.count ?? 0) font descriptor(s)); native macOS PDFKit/Quartz does not perform glyph-level font subsetting."

        progress(.determinate(1.0, message: "Optimization Complete"))
        return PDFCompressionResultInfo(
            outputURL: outputURL,
            originalBytes: originalSize,
            compressedBytes: compressedSize,
            wasLossyApplied: (effectiveTier != .losslessCleanup),
            validatedReadable: true,
            pageCount: pageCount,
            tradeOffNote: tradeOff,
            preservedStructures: preserved,
            discardedStructures: discarded,
            isLinearized: isLinearized,
            linearizationNote: linNote,
            metadataStrippedVerified: metadataVerified,
            xmpVerificationNote: xmpNote,
            preImageCount: preInspect?.images.count ?? 0,
            postImageCount: postInspect?.images.count ?? 0,
            fontCount: postInspect?.fonts.count ?? 0,
            fontNote: fontNote,
            warnings: extraWarnings
        )
    }

    private static func performQuartzVectorPreservingPass(
        sourceDoc: PDFDocument,
        sourceURL: URL,
        tempOut: URL,
        options: PDFCompressionOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) throws {
        let intermediateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-QuartzPass-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: intermediateURL) }

        let targetDPI = max(72, min(300, Int(options.targetDPI.rounded())))
        let quality = max(0.15, min(0.98, options.imageQuality))
        let filterProps: [String: Any] = [
            "FilterType": 1,
            "Name": "LocalConvert-PDFOptimize",
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": NSNumber(value: quality),
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": NSNumber(value: targetDPI),
                            "ImageScaleInterpolate": NSNumber(value: 1),
                            "ImageSizeMax": NSNumber(value: 4096),
                            "ImageSizeMin": NSNumber(value: 0)
                        ]
                    ]
                ]
            ]
        ]

        var dummyBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var auxInfo: [CFString: Any] = [:]
        if !options.stripMetadata, let attrs = sourceDoc.documentAttributes {
            if let t = attrs[PDFDocumentAttribute.titleAttribute] as? String { auxInfo[kCGPDFContextTitle] = t as CFString }
            if let a = attrs[PDFDocumentAttribute.authorAttribute] as? String { auxInfo[kCGPDFContextAuthor] = a as CFString }
            if let s = attrs[PDFDocumentAttribute.subjectAttribute] as? String { auxInfo[kCGPDFContextSubject] = s as CFString }
            if let c = attrs[PDFDocumentAttribute.creatorAttribute] as? String { auxInfo[kCGPDFContextCreator] = c as CFString }
        }

        guard let pdfCtx = CGContext(intermediateURL as CFURL, mediaBox: &dummyBox, auxInfo as CFDictionary) else {
            throw ConversionError.engineExecutionFailed("Failed to create Quartz optimization context.", underlyingError: nil)
        }
        if let qFilter = QuartzFilter(properties: filterProps) {
            _ = qFilter.apply(to: pdfCtx)
        }

        let pageCount = sourceDoc.pageCount
        // Snapshot non-widget annotations before drawing clean copies (in case PDFPage.copy shares any state).
        var savedAnnotationsByPage: [[PDFAnnotation]] = Array(repeating: [], count: pageCount)
        for idx in 0..<pageCount {
            guard let page = sourceDoc.page(at: idx) else { continue }
            savedAnnotationsByPage[idx] = page.annotations.filter { ann in
                let rawType = (ann.type ?? "").replacingOccurrences(of: "/", with: "")
                return rawType != "Widget" && rawType != "Popup"
            }
        }

        for idx in 0..<pageCount {
            try Task.checkCancellation()
            progress(.determinate(
                Double(idx) / Double(max(1, pageCount)) * 0.85,
                message: "Optimizing page \(idx + 1) of \(pageCount) at \(targetDPI) DPI..."
            ))

            autoreleasepool {
                guard let page = sourceDoc.page(at: idx) else { return }
                let uSize = PDFCoordinateGeometry.uprightSize(for: page)
                var uBox = CGRect(origin: .zero, size: uSize)
                let pageInfo: [CFString: Any] = [
                    kCGPDFContextMediaBox: Data(bytes: &uBox, count: MemoryLayout<CGRect>.size) as CFData
                ]

                // Draw a copy without non-widget annotations so editable markup/links are restored cleanly without doubling
                pdfCtx.beginPDFPage(pageInfo as CFDictionary)
                if let cleanPage = page.copy() as? PDFPage {
                    for ann in cleanPage.annotations {
                        let rawType = (ann.type ?? "").replacingOccurrences(of: "/", with: "")
                        if rawType != "Widget" {
                            cleanPage.removeAnnotation(ann)
                        }
                    }
                    cleanPage.draw(with: .cropBox, to: pdfCtx)
                } else {
                    page.draw(with: .cropBox, to: pdfCtx)
                }
                pdfCtx.endPDFPage()
            }
        }
        pdfCtx.closePDF()

        try Task.checkCancellation()
        progress(.determinate(0.90, message: "Restoring outlines and interactive links..."))

        guard let quartzDoc = PDFDocument(url: intermediateURL), quartzDoc.pageCount == pageCount else {
            throw ConversionError.engineExecutionFailed("Quartz optimization pass produced an unreadable intermediate PDF.", underlyingError: nil)
        }

        let targetDoc = PDFDocument()
        var targetPageBySourceKey: [PDFOutlineRemapper.RemapKey: PDFPage] = [:]
        var copiedPagesByIndex: [Int: PDFPage] = [:]

        for idx in 0..<pageCount {
            guard let qPage = quartzDoc.page(at: idx),
                  let copied = qPage.copy() as? PDFPage else { continue }
            targetDoc.insert(copied, at: idx)
            let insertedPage = targetDoc.page(at: idx) ?? copied
            targetPageBySourceKey[PDFOutlineRemapper.RemapKey(url: sourceURL, pageIndex: idx)] = insertedPage
            copiedPagesByIndex[idx] = insertedPage
        }

        // Restore non-widget annotations (markup + clickable Link annotations) mapped cleanly to upright coordinates
        for idx in 0..<pageCount {
            guard let srcPage = sourceDoc.page(at: idx),
                  let dstPage = targetDoc.page(at: idx) ?? copiedPagesByIndex[idx] else { continue }
            let dstSize = PDFCoordinateGeometry.uprightSize(for: dstPage)
            for ann in savedAnnotationsByPage[idx] {
                let rawType = (ann.type ?? "").replacingOccurrences(of: "/", with: "")

                var targetBounds = ann.bounds
                if PDFCoordinateGeometry.normalizedRotation(srcPage.rotation) != 0 ||
                    PDFCoordinateGeometry.effectiveDisplayBox(for: srcPage).origin != .zero {
                    let n1 = PDFCoordinateGeometry.rawPagePointToUprightNormalized(CGPoint(x: ann.bounds.minX, y: ann.bounds.minY), on: srcPage)
                    let n2 = PDFCoordinateGeometry.rawPagePointToUprightNormalized(CGPoint(x: ann.bounds.maxX, y: ann.bounds.maxY), on: srcPage)
                    let vx1 = min(n1.x, n2.x) * dstSize.width
                    let vx2 = max(n1.x, n2.x) * dstSize.width
                    let vy1 = (1.0 - max(n1.y, n2.y)) * dstSize.height
                    let vy2 = (1.0 - min(n1.y, n2.y)) * dstSize.height
                    targetBounds = CGRect(x: vx1, y: vy1, width: max(4, vx2 - vx1), height: max(4, vy2 - vy1))
                }

                if rawType == "Link" {
                    let restoredLink = PDFAnnotation(bounds: targetBounds, forType: .link, withProperties: nil)
                    if let url = ann.url {
                        restoredLink.url = url
                    } else if let dest = ann.destination, let destPage = dest.page {
                        let destIdx = sourceDoc.index(for: destPage)
                        if destIdx >= 0, let mappedDestPage = targetDoc.page(at: destIdx) ?? copiedPagesByIndex[destIdx] {
                            restoredLink.destination = PDFDestination(page: mappedDestPage, at: dest.point)
                        }
                    } else if let act = ann.action {
                        restoredLink.action = act
                    }
                    dstPage.addAnnotation(restoredLink)
                } else if let cloned = ann.copy() as? PDFAnnotation {
                    cloned.bounds = targetBounds
                    dstPage.addAnnotation(cloned)
                }
            }
        }

        let outlineRes = PDFOutlineRemapper.remapOutlines(
            sources: [(url: sourceURL, document: sourceDoc)],
            targetPageLookup: targetPageBySourceKey,
            into: targetDoc
        )
        if let root = outlineRes.outlineRoot {
            targetDoc.outlineRoot = root
        }

        if options.stripMetadata {
            targetDoc.documentAttributes = [:]
        } else if let attrs = sourceDoc.documentAttributes {
            targetDoc.documentAttributes = attrs
        }

        guard targetDoc.write(to: tempOut) else {
            throw ConversionError.engineExecutionFailed("Failed to finalize Quartz-optimized PDF.", underlyingError: nil)
        }
    }

    private static func countOutlineItems(_ node: PDFOutline?) -> Int {
        guard let node else { return 0 }
        var total = (node.label?.isEmpty == false) ? 1 : 0
        for i in 0..<node.numberOfChildren {
            total += countOutlineItems(node.child(at: i))
        }
        return total
    }

    private static func reencodeRaster(_ cgImage: CGImage, codec: PDFImageCompressionCodec, quality: Double) -> CGImage? {
        if codec == .losslessFlate {
            return cgImage
        }
        let typeID: CFString = (codec == .jpeg2000)
            ? ("public.jpeg-2000" as CFString)
            : (UTType.jpeg.identifier as CFString)
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, typeID, 1, nil) else {
            return cgImage
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality as CFNumber
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return cgImage
        }
        if codec == .jpeg,
           let provider = CGDataProvider(data: mutableData as CFData),
           let directJPEG = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return directJPEG
        }
        guard let src = CGImageSourceCreateWithData(mutableData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return cgImage
        }
        return decoded
    }
}
