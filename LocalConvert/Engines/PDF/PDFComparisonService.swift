import Foundation
import PDFKit
import CoreGraphics
import AppKit

// MARK: - PDF Comparison Service (Text Diff + Visual Pixel Diff + Layout Alignment)

enum PDFComparisonService {

    static func compare(
        leftURL: URL,
        rightURL: URL,
        leftPassword: String? = nil,
        rightPassword: String? = nil,
        renderWidthPixels: Int = 560,
        progress: (@Sendable (ConversionProgress) -> Void)? = nil
    ) async throws -> PDFComparisonReport {
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: leftURL.path) else {
            throw ConversionError.inputFileNotFound(leftURL)
        }
        guard FileManager.default.fileExists(atPath: rightURL.path) else {
            throw ConversionError.inputFileNotFound(rightURL)
        }

        guard let leftDoc = PDFDocument(url: leftURL) else {
            throw ConversionError.invalidInput("Unable to open first PDF '\(leftURL.lastPathComponent)'.")
        }
        guard let rightDoc = PDFDocument(url: rightURL) else {
            throw ConversionError.invalidInput("Unable to open second PDF '\(rightURL.lastPathComponent)'.")
        }

        if leftDoc.isLocked {
            guard let p = leftPassword, !p.isEmpty, leftDoc.unlock(withPassword: p) else {
                throw ConversionError.invalidInput("First PDF '\(leftURL.lastPathComponent)' is password-locked.")
            }
        }
        if rightDoc.isLocked {
            guard let p = rightPassword, !p.isEmpty, rightDoc.unlock(withPassword: p) else {
                throw ConversionError.invalidInput("Second PDF '\(rightURL.lastPathComponent)' is password-locked.")
            }
        }

        let leftCount = leftDoc.pageCount
        let rightCount = rightDoc.pageCount

        // Extract per-page normalized signatures for page insertion/deletion alignment
        var leftSigs: [String] = []
        var rightSigs: [String] = []
        for i in 0..<leftCount {
            leftSigs.append(pageSignature(leftDoc.page(at: i)))
        }
        for j in 0..<rightCount {
            rightSigs.append(pageSignature(rightDoc.page(at: j)))
        }

        let alignedPairs = alignPages(leftSignatures: leftSigs, rightSignatures: rightSigs)
        let totalSteps = max(1, alignedPairs.count)

        var diffs: [PDFPageComparisonDiff] = []
        var identicalCount = 0
        var modifiedCount = 0
        var addedCount = 0
        var removedCount = 0
        var totalAddedLines = 0
        var totalRemovedLines = 0
        var totalAnnotationChanges = 0
        var totalFormFieldChanges = 0
        var totalImageChanges = 0

        for (stepIdx, pair) in alignedPairs.enumerated() {
            try Task.checkCancellation()
            progress?(.determinate(
                Double(stepIdx) / Double(totalSteps),
                message: "Comparing page slot \(stepIdx + 1) of \(totalSteps)..."
            ))

            autoreleasepool {
                switch pair {
                case let .matched(li, ri):
                    let lPage = leftDoc.page(at: li)
                    let rPage = rightDoc.page(at: ri)
                    let lSize = lPage.map { PDFRedactionService.uprightSize(for: $0) }
                    let rSize = rPage.map { PDFRedactionService.uprightSize(for: $0) }
                    let lRot = lPage?.rotation
                    let rRot = rPage?.rotation

                    let lLines = normalizedLines(lPage?.string)
                    let rLines = normalizedLines(rPage?.string)
                    let lineDiff = rLines.difference(from: lLines)
                    var added: [String] = []
                    var removed: [String] = []
                    for change in lineDiff {
                        switch change {
                        case .insert(_, let el, _): added.append(el)
                        case .remove(_, let el, _): removed.append(el)
                        }
                    }
                    totalAddedLines += added.count
                    totalRemovedLines += removed.count

                    let (annChanges, formChanges) = diffAnnotationsAndForms(leftPage: lPage, rightPage: rPage)
                    let lImgCount = countPageImages(lPage)
                    let rImgCount = countPageImages(rPage)
                    totalAnnotationChanges += annChanges.count
                    totalFormFieldChanges += formChanges.count
                    if lImgCount != rImgCount { totalImageChanges += 1 }

                    // Normalized scale visual comparison accounting for aspect/size differences & minor 1px anti-aliasing
                    let lThumb = lPage.flatMap { renderNormalizedPNG($0, widthPixels: renderWidthPixels) }
                    let rThumb = rPage.flatMap { renderNormalizedPNG($0, widthPixels: renderWidthPixels) }

                    let (ratio, diffOverlayData) = computeVisualDiff(leftPage: lPage, rightPage: rPage, widthPixels: renderWidthPixels)
                    let hasTextDiff = !added.isEmpty || !removed.isEmpty
                    let hasVisualDiff = (ratio ?? 0) > 0.002 // > 0.2% pixels beyond anti-aliasing tolerance
                    let hasAnnOrFormDiff = !annChanges.isEmpty || !formChanges.isEmpty || lImgCount != rImgCount
                    let hasLayoutDiff: Bool = {
                        guard let ls = lSize, let rs = rSize else { return false }
                        return abs(ls.width - rs.width) > 1.0 || abs(ls.height - rs.height) > 1.0 || lRot != rRot
                    }()

                    let status: PDFPageComparisonDiff.PageDiffStatus
                    if hasTextDiff && hasVisualDiff {
                        status = .modifiedTextAndVisual
                        modifiedCount += 1
                    } else if hasTextDiff {
                        status = .textOnlyModified
                        modifiedCount += 1
                    } else if hasLayoutDiff {
                        status = .layoutChanged
                        modifiedCount += 1
                    } else if hasVisualDiff {
                        status = .visualOnlyModified
                        modifiedCount += 1
                    } else if hasAnnOrFormDiff {
                        status = .annotationsOrFormsChanged
                        modifiedCount += 1
                    } else {
                        status = .identical
                        identicalCount += 1
                    }

                    diffs.append(PDFPageComparisonDiff(
                        pageNumber: stepIdx + 1,
                        status: status,
                        leftDimensions: lSize,
                        rightDimensions: rSize,
                        leftRotation: lRot,
                        rightRotation: rRot,
                        addedLines: added,
                        removedLines: removed,
                        visualDifferenceRatio: ratio,
                        visualDiffImageData: diffOverlayData,
                        leftThumbnailData: lThumb,
                        rightThumbnailData: rThumb,
                        annotationChanges: annChanges,
                        formFieldChanges: formChanges,
                        leftImageCount: lImgCount,
                        rightImageCount: rImgCount
                    ))

                case let .added(ri):
                    addedCount += 1
                    let rPage = rightDoc.page(at: ri)
                    let rLines = normalizedLines(rPage?.string)
                    totalAddedLines += rLines.count
                    diffs.append(PDFPageComparisonDiff(
                        pageNumber: stepIdx + 1,
                        status: .added,
                        leftDimensions: nil,
                        rightDimensions: rPage.map { PDFRedactionService.uprightSize(for: $0) },
                        leftRotation: nil,
                        rightRotation: rPage?.rotation,
                        addedLines: rLines,
                        removedLines: [],
                        visualDifferenceRatio: 1.0,
                        visualDiffImageData: nil,
                        leftThumbnailData: nil,
                        rightThumbnailData: rPage.flatMap { renderNormalizedPNG($0, widthPixels: renderWidthPixels) }
                    ))

                case let .removed(li):
                    removedCount += 1
                    let lPage = leftDoc.page(at: li)
                    let lLines = normalizedLines(lPage?.string)
                    totalRemovedLines += lLines.count
                    diffs.append(PDFPageComparisonDiff(
                        pageNumber: stepIdx + 1,
                        status: .removed,
                        leftDimensions: lPage.map { PDFRedactionService.uprightSize(for: $0) },
                        rightDimensions: nil,
                        leftRotation: lPage?.rotation,
                        rightRotation: nil,
                        addedLines: [],
                        removedLines: lLines,
                        visualDifferenceRatio: 1.0,
                        visualDiffImageData: nil,
                        leftThumbnailData: lPage.flatMap { renderNormalizedPNG($0, widthPixels: renderWidthPixels) },
                        rightThumbnailData: nil
                    ))
                }
            }
        }

        progress?(.determinate(1.0, message: "Comparison Complete"))

        let summary = """
        Pages: \(leftCount) vs \(rightCount) | Identical: \(identicalCount), Modified: \(modifiedCount), Added: \(addedCount), Removed: \(removedCount) | Text Diff: +\(totalAddedLines) / -\(totalRemovedLines) line(s) | Annotations: \(totalAnnotationChanges), Forms: \(totalFormFieldChanges), Images: \(totalImageChanges) delta(s).
        """

        return PDFComparisonReport(
            leftURL: leftURL,
            rightURL: rightURL,
            leftPageCount: leftCount,
            rightPageCount: rightCount,
            identicalPagesCount: identicalCount,
            modifiedPagesCount: modifiedCount,
            addedPagesCount: addedCount,
            removedPagesCount: removedCount,
            totalAddedLines: totalAddedLines,
            totalRemovedLines: totalRemovedLines,
            pageDiffs: diffs,
            summaryText: summary,
            totalAnnotationChanges: totalAnnotationChanges,
            totalFormFieldChanges: totalFormFieldChanges,
            totalImageChanges: totalImageChanges
        )
    }

    private static func countPageImages(_ page: PDFPage?) -> Int {
        guard let pageDict = page?.pageRef?.dictionary else { return 0 }
        var resDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resDict), let resDict else { return 0 }
        var xobjDict: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resDict, "XObject", &xobjDict), let xobjDict else { return 0 }
        return CGPDFDictionaryGetCount(xobjDict)
    }

    private static func diffAnnotationsAndForms(leftPage: PDFPage?, rightPage: PDFPage?) -> ([String], [String]) {
        func summarize(_ page: PDFPage?) -> ([String], [String: String]) {
            guard let page else { return ([], [:]) }
            var nonWidget: [String] = []
            var forms: [String: String] = [:]
            for (idx, ann) in page.annotations.enumerated() {
                let isWidget = (ann.type ?? "").contains("Widget") || ann.fieldName != nil
                if isWidget {
                    let key = ann.fieldName ?? "Widget_\(idx)"
                    let state = ann.widgetFieldType == .button
                        ? (ann.buttonWidgetState == .onState ? "ON" : "OFF")
                        : (ann.widgetStringValue ?? "")
                    forms[key] = state
                } else {
                    let kind = ann.type ?? "Annotation"
                    let body = ann.contents ?? ann.url?.absoluteString ?? ""
                    nonWidget.append("\(kind): \(body) @ (\(Int(ann.bounds.minX)),\(Int(ann.bounds.minY)))")
                }
            }
            return (nonWidget.sorted(), forms)
        }

        let (lAnns, lForms) = summarize(leftPage)
        let (rAnns, rForms) = summarize(rightPage)

        var annDelta: [String] = []
        for change in rAnns.difference(from: lAnns) {
            switch change {
            case .insert(_, let el, _): annDelta.append("+ \(el)")
            case .remove(_, let el, _): annDelta.append("- \(el)")
            }
        }

        var formDelta: [String] = []
        let allKeys = Set(lForms.keys).union(rForms.keys).sorted()
        for key in allKeys {
            let lv = lForms[key]
            let rv = rForms[key]
            if lv != rv {
                formDelta.append("\(key): \"\(lv ?? "∅")\" -> \"\(rv ?? "∅")\"")
            }
        }
        return (annDelta, formDelta)
    }

    // MARK: - Alignment & Visual Rendering

    private enum AlignedSlot {
        case matched(Int, Int)
        case removed(Int)
        case added(Int)
    }

    /// Uses LCS over page content signatures when page counts differ so inserted/deleted pages don't shift every subsequent page.
    private static func alignPages(leftSignatures: [String], rightSignatures: [String]) -> [AlignedSlot] {
        if leftSignatures.count == rightSignatures.count {
            return (0..<leftSignatures.count).map { .matched($0, $0) }
        }

        // LCS when page counts differ
        let diff = rightSignatures.difference(from: leftSignatures)
        var removedLeftIndices = Set<Int>()
        var addedRightIndices = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedLeftIndices.insert(offset)
            case .insert(let offset, _, _): addedRightIndices.insert(offset)
            }
        }

        var slots: [AlignedSlot] = []
        var li = 0
        var ri = 0
        while li < leftSignatures.count || ri < rightSignatures.count {
            var unmatchedLeft: [Int] = []
            while li < leftSignatures.count && removedLeftIndices.contains(li) {
                unmatchedLeft.append(li)
                li += 1
            }
            var unmatchedRight: [Int] = []
            while ri < rightSignatures.count && addedRightIndices.contains(ri) {
                unmatchedRight.append(ri)
                ri += 1
            }

            // Pair contiguous replaced/modified pages between LCS anchors rather than reporting them as separate remove+add slots
            let paired = min(unmatchedLeft.count, unmatchedRight.count)
            for k in 0..<paired {
                slots.append(.matched(unmatchedLeft[k], unmatchedRight[k]))
            }
            if unmatchedLeft.count > paired {
                for lIdx in unmatchedLeft[paired...] {
                    slots.append(.removed(lIdx))
                }
            }
            if unmatchedRight.count > paired {
                for rIdx in unmatchedRight[paired...] {
                    slots.append(.added(rIdx))
                }
            }

            if li < leftSignatures.count && ri < rightSignatures.count {
                slots.append(.matched(li, ri))
                li += 1
                ri += 1
            } else if li < leftSignatures.count {
                slots.append(.removed(li))
                li += 1
            } else if ri < rightSignatures.count {
                slots.append(.added(ri))
                ri += 1
            }
        }
        return slots
    }

    private static func pageSignature(_ page: PDFPage?) -> String {
        guard let page else { return "" }
        let trimmed = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(240))
        }
        let s = PDFRedactionService.uprightSize(for: page)
        return "IMAGE_ONLY_\(Int(s.width))x\(Int(s.height))"
    }

    private static func normalizedLines(_ text: String?) -> [String] {
        (text ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func renderNormalizedRGBABuffer(_ page: PDFPage, width: Int, height: Int) -> [UInt8]? {
        let size = PDFRedactionService.uprightSize(for: page)
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 255, count: bytesPerRow * height)
        let success: Bool = buffer.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let sx = CGFloat(width) / max(1, size.width)
            let sy = CGFloat(height) / max(1, size.height)
            let scale = min(sx, sy)
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            if let cgPage = page.pageRef {
                let targetRect = CGRect(origin: .zero, size: size)
                let transform = cgPage.getDrawingTransform(.mediaBox, rect: targetRect, rotate: 0, preserveAspectRatio: true)
                ctx.concatenate(transform)
                ctx.drawPDFPage(cgPage)
            } else {
                page.draw(with: .mediaBox, to: ctx)
            }
            ctx.restoreGState()
            return true
        }
        return success ? buffer : nil
    }

    private static func renderNormalizedPNG(_ page: PDFPage, widthPixels: Int) -> Data? {
        let size = PDFRedactionService.uprightSize(for: page)
        let h = max(1, Int((CGFloat(widthPixels) * (size.height / max(1, size.width))).rounded()))
        guard let buf = renderNormalizedRGBABuffer(page, width: widthPixels, height: h) else { return nil }
        return encodePNG(rgba: buf, width: widthPixels, height: h)
    }

    private static func computeVisualDiff(
        leftPage: PDFPage?,
        rightPage: PDFPage?,
        widthPixels: Int
    ) -> (Double?, Data?) {
        guard let leftPage, let rightPage else { return (nil, nil) }
        let lSize = PDFRedactionService.uprightSize(for: leftPage)
        let rSize = PDFRedactionService.uprightSize(for: rightPage)
        let aspect = max(lSize.height / max(1, lSize.width), rSize.height / max(1, rSize.width))
        let h = max(1, Int((CGFloat(widthPixels) * aspect).rounded()))

        guard let lBuf = renderNormalizedRGBABuffer(leftPage, width: widthPixels, height: h),
              let rBuf = renderNormalizedRGBABuffer(rightPage, width: widthPixels, height: h) else {
            return (nil, nil)
        }

        let pixelCount = widthPixels * h
        var diffBuf = [UInt8](repeating: 255, count: pixelCount * 4)
        var changedPixels = 0

        for idx in 0..<pixelCount {
            let o = idx * 4
            let dr = abs(Int(lBuf[o]) - Int(rBuf[o]))
            let dg = abs(Int(lBuf[o + 1]) - Int(rBuf[o + 1]))
            let db = abs(Int(lBuf[o + 2]) - Int(rBuf[o + 2]))
            let maxDelta = max(dr, max(dg, db))

            // Account for minor subpixel / anti-aliasing offsets (threshold 18/255)
            if maxDelta > 18 {
                changedPixels += 1
                diffBuf[o] = 230     // Highlight diff in red
                diffBuf[o + 1] = 45
                diffBuf[o + 2] = 60
                diffBuf[o + 3] = 255
            } else {
                // Faded grayscale context so user sees where change happened
                let gray = UInt8((Int(rBuf[o]) + Int(rBuf[o + 1]) + Int(rBuf[o + 2])) / 3)
                let faded = UInt8(min(255, 160 + Int(gray) / 3))
                diffBuf[o] = faded
                diffBuf[o + 1] = faded
                diffBuf[o + 2] = faded
                diffBuf[o + 3] = 255
            }
        }

        let ratio = Double(changedPixels) / Double(max(1, pixelCount))
        let pngData = encodePNG(rgba: diffBuf, width: widthPixels, height: h)
        return (ratio, pngData)
    }

    private static func encodePNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
        var mutable = rgba
        guard let provider = CGDataProvider(data: Data(mutable) as CFData) else { return nil }
        mutable.removeAll(keepingCapacity: false)
        guard let cgImg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        let rep = NSBitmapImageRep(cgImage: cgImg)
        return rep.representation(using: .png, properties: [:])
    }
}
