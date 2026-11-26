import Foundation
import PDFKit
import AppKit
import CoreGraphics

// MARK: - PDF Annotation & Editing Service

enum PDFAnnotationService {

    /// Loads all editable non-widget markup annotations from a PDF into raw page-space `PDFDraftAnnotationRecord`s.
    /// Leaves `.widget` (AcroForm / signatures), `.link`, and `.popup` annotations managed separately.
    static func loadExistingAnnotations(from url: URL, password: String? = nil) throws -> [PDFDraftAnnotationRecord] {
        let doc = try PDFPageManagementService.openAndUnlock(url: url, password: password)
        var records: [PDFDraftAnnotationRecord] = []

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }
            for ann in page.annotations {
                if let rec = convertToRecord(ann, pageIndex: pageIndex) {
                    records.append(rec)
                }
            }
        }
        return records
    }

    static func convertToRecord(_ ann: PDFAnnotation, pageIndex: Int) -> PDFDraftAnnotationRecord? {
        let rawType = (ann.type ?? "").replacingOccurrences(of: "/", with: "")
        // Preserve AcroForm widgets, signatures, links, and popups cleanly
        if rawType == "Widget" || rawType == "Link" || rawType == "Popup" {
            return nil
        }

        let tool: PDFAnnotationTool
        switch rawType {
        case "Highlight": tool = .highlight
        case "Underline": tool = .underline
        case "StrikeOut": tool = .strikeOut
        case "Text": tool = .note
        case "FreeText": tool = .freeText
        case "Ink": tool = .ink
        case "Square": tool = .rectangle
        case "Circle": tool = .circle
        case "Line":
            tool = (ann.endLineStyle != .none || ann.startLineStyle != .none) ? .arrow : .line
        default:
            return nil
        }

        let nsColor = ann.color.usingColorSpace(.sRGB) ?? ann.color
        var style = PDFAnnotationStyle()
        style.strokeColorHex = hexString(from: nsColor)
        style.opacity = Double(max(0.1, min(1.0, nsColor.alphaComponent)))
        if let interior = ann.interiorColor?.usingColorSpace(.sRGB), interior.alphaComponent > 0.01 {
            style.fillColorHex = hexString(from: interior)
        }
        if let border = ann.border {
            style.lineWidth = Double(max(1.0, border.lineWidth))
        }
        if let font = ann.font {
            style.fontSize = Double(font.pointSize)
            style.fontName = font.fontName
        }
        if let user = ann.userName, !user.isEmpty {
            style.author = user
        }

        let origin = ann.bounds.origin
        var quadLines: [[CGPoint]]? = nil
        if let quads = ann.quadrilateralPoints, quads.count >= 4 {
            var groups: [[CGPoint]] = []
            var idx = 0
            while idx + 3 < quads.count {
                let g = (0..<4).map { offset -> CGPoint in
                    let p = quads[idx + offset].pointValue
                    return CGPoint(x: p.x + origin.x, y: p.y + origin.y)
                }
                groups.append(g)
                idx += 4
            }
            if !groups.isEmpty { quadLines = groups }
        }

        var inkPaths: [[CGPoint]]? = nil
        if tool == .ink, let paths = ann.paths, !paths.isEmpty {
            inkPaths = paths.compactMap { path in
                var pts: [CGPoint] = []
                for elemIdx in 0..<path.elementCount {
                    var points = [NSPoint](repeating: .zero, count: 3)
                    let kind = path.element(at: elemIdx, associatedPoints: &points)
                    switch kind {
                    case .moveTo, .lineTo:
                        pts.append(CGPoint(x: points[0].x + origin.x, y: points[0].y + origin.y))
                    case .curveTo, .cubicCurveTo:
                        pts.append(CGPoint(x: points[2].x + origin.x, y: points[2].y + origin.y))
                    case .quadraticCurveTo:
                        pts.append(CGPoint(x: points[1].x + origin.x, y: points[1].y + origin.y))
                    case .closePath:
                        break
                    @unknown default:
                        break
                    }
                }
                return pts.isEmpty ? nil : pts
            }
        }

        let lineStart: CGPoint? = (tool == .line || tool == .arrow)
            ? CGPoint(x: ann.startPoint.x + origin.x, y: ann.startPoint.y + origin.y)
            : nil
        let lineEnd: CGPoint? = (tool == .line || tool == .arrow)
            ? CGPoint(x: ann.endPoint.x + origin.x, y: ann.endPoint.y + origin.y)
            : nil

        return PDFDraftAnnotationRecord(
            pageIndex: pageIndex,
            kind: tool,
            bounds: ann.bounds,
            quadLines: quadLines,
            inkPaths: inkPaths,
            lineStart: lineStart,
            lineEnd: lineEnd,
            contents: ann.contents ?? "",
            style: style
        )
    }

    /// Materializes a draft record as a native `PDFAnnotation` bound to `page`.
    static func materializeAnnotation(_ record: PDFDraftAnnotationRecord) -> PDFAnnotation {
        let subtype: PDFAnnotationSubtype
        switch record.kind {
        case .select, .rectangle: subtype = .square
        case .highlight: subtype = .highlight
        case .underline: subtype = .underline
        case .strikeOut: subtype = .strikeOut
        case .note: subtype = .text
        case .freeText: subtype = .freeText
        case .ink: subtype = .ink
        case .circle: subtype = .circle
        case .line, .arrow: subtype = .line
        }

        let bounds = record.bounds.cgRect
        let ann = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        let strokeColor = color(fromHex: record.style.strokeColorHex, alpha: record.style.opacity)
        ann.color = strokeColor
        ann.contents = record.contents.isEmpty ? nil : record.contents
        ann.userName = record.style.author
        ann.modificationDate = Date()
        ann.shouldDisplay = true
        ann.shouldPrint = true

        if let fillHex = record.style.fillColorHex, !fillHex.isEmpty {
            ann.interiorColor = color(fromHex: fillHex, alpha: max(0.1, min(1.0, record.style.opacity * 0.45)))
        }

        if !record.kind.isTextMarkup && record.kind != .note {
            let border = PDFBorder()
            border.lineWidth = CGFloat(max(1.0, min(20.0, record.style.lineWidth)))
            border.style = .solid
            ann.border = border
        }

        if record.kind == .freeText {
            ann.font = NSFont(name: record.style.fontName, size: CGFloat(record.style.fontSize))
                ?? NSFont.systemFont(ofSize: CGFloat(record.style.fontSize))
            ann.fontColor = strokeColor
            if record.style.fillColorHex == nil {
                ann.color = NSColor.white.withAlphaComponent(0.92)
                ann.fontColor = strokeColor
            }
        }

        if record.kind == .note {
            ann.iconType = .comment
        }

        if record.kind.isTextMarkup {
            let origin = bounds.origin
            let quads = record.quadLines ?? [[
                PDFPointRecord(CGPoint(x: bounds.minX, y: bounds.maxY)),
                PDFPointRecord(CGPoint(x: bounds.maxX, y: bounds.maxY)),
                PDFPointRecord(CGPoint(x: bounds.minX, y: bounds.minY)),
                PDFPointRecord(CGPoint(x: bounds.maxX, y: bounds.minY))
            ]]
            var values: [NSValue] = []
            for group in quads where group.count >= 4 {
                for pt in group.prefix(4) {
                    values.append(NSValue(point: NSPoint(x: pt.x - origin.x, y: pt.y - origin.y)))
                }
            }
            ann.quadrilateralPoints = values
        }

        if record.kind == .ink, let strokes = record.inkPaths {
            let origin = bounds.origin
            for stroke in strokes where stroke.count >= 2 {
                let path = NSBezierPath()
                path.lineWidth = CGFloat(max(1.0, record.style.lineWidth))
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: NSPoint(x: stroke[0].x - origin.x, y: stroke[0].y - origin.y))
                for pt in stroke.dropFirst() {
                    path.line(to: NSPoint(x: pt.x - origin.x, y: pt.y - origin.y))
                }
                ann.add(path)
            }
        }

        if record.kind == .line || record.kind == .arrow {
            let origin = bounds.origin
            let s = record.lineStart?.cgPoint ?? CGPoint(x: bounds.minX, y: bounds.minY)
            let e = record.lineEnd?.cgPoint ?? CGPoint(x: bounds.maxX, y: bounds.maxY)
            ann.startPoint = NSPoint(x: s.x - origin.x, y: s.y - origin.y)
            ann.endPoint = NSPoint(x: e.x - origin.x, y: e.y - origin.y)
            ann.startLineStyle = .none
            ann.endLineStyle = (record.kind == .arrow) ? .closedArrow : .none
        }

        return ann
    }

    /// Saves draft annotations into a new PDF (native editable or explicitly flattened via burn-in),
    /// preserving source file immutability, bookmarks, links, and AcroForm widgets.
    static func applyAndSave(
        inputURL: URL,
        outputURL: URL,
        options: PDFAnnotationSaveOptions,
        progress: @Sendable (ConversionProgress) -> Void
    ) async throws -> PDFAnnotationSaveResult {
        try Task.checkCancellation()

        let inResolved = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        let outResolved = outputURL.standardizedFileURL.resolvingSymlinksInPath()
        guard inResolved != outResolved else {
            throw ConversionError.invalidInput("Annotation save never overwrites the source PDF directly.")
        }

        progress(.determinate(0.15, message: "Loading PDF structure..."))
        let srcDoc = try PDFPageManagementService.openAndUnlock(url: inputURL, password: options.password)
        let targetDoc = PDFDocument()
        if let attrs = srcDoc.documentAttributes {
            targetDoc.documentAttributes = attrs
        }

        var pageLookup: [PDFOutlineRemapper.RemapKey: PDFPage] = [:]
        var widgetCount = 0
        var warnings: [String] = []

        if let preInspect = try? PDFDocumentInspector.inspect(url: inputURL, password: options.password),
           preInspect.hasDigitalSignatures {
            warnings.append("Source PDF carried digital signature(s); saving annotations creates a new unsigned copy.")
        }

        let recordsByPage = Dictionary(grouping: options.records, by: \.pageIndex)

        for idx in 0..<srcDoc.pageCount {
            try Task.checkCancellation()
            progress(.determinate(0.15 + 0.65 * (Double(idx) / Double(max(1, srcDoc.pageCount))),
                                  message: "Applying annotations to page \(idx + 1)..."))

            guard let srcPage = srcDoc.page(at: idx),
                  let copied = srcPage.copy() as? PDFPage else {
                continue
            }

            // Remove existing editable markup annotations (preserving .Widget forms/sigs and .Link)
            let removable = copied.annotations.filter { ann in
                let t = (ann.type ?? "").replacingOccurrences(of: "/", with: "")
                if t == "Widget" {
                    widgetCount += 1
                    return false
                }
                return t != "Link"
            }
            for old in removable {
                copied.removeAnnotation(old)
            }

            for record in recordsByPage[idx] ?? [] {
                let nativeAnn = materializeAnnotation(record)
                copied.addAnnotation(nativeAnn)
            }

            targetDoc.insert(copied, at: idx)
            pageLookup[PDFOutlineRemapper.RemapKey(url: inputURL, pageIndex: idx)] = copied
        }

        _ = PDFOutlineRemapper.remapOutlines(
            sources: [(url: inputURL.standardizedFileURL, document: srcDoc)],
            targetPageLookup: pageLookup,
            into: targetDoc
        )

        progress(.determinate(0.88, message: options.flattenAnnotations ? "Flattening annotations..." : "Writing PDF..."))
        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-Annot-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let writeOK: Bool
        if options.flattenAnnotations {
            writeOK = targetDoc.write(to: tempOut, withOptions: [.burnInAnnotationsOption: true])
        } else {
            writeOK = targetDoc.write(to: tempOut)
        }

        guard writeOK,
              FileManager.default.fileExists(atPath: tempOut.path),
              let verifyDoc = PDFDocument(url: tempOut),
              verifyDoc.pageCount == srcDoc.pageCount else {
            throw ConversionError.engineExecutionFailed("Failed to save or validate annotated PDF.", underlyingError: nil)
        }

        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(tempOut, to: outputURL, policy: .overwrite)

        progress(.determinate(1.0, message: "Complete"))
        return PDFAnnotationSaveResult(
            outputURL: outputURL,
            savedAnnotationsCount: options.records.count,
            flattened: options.flattenAnnotations,
            preservedWidgetCount: widgetCount,
            warnings: warnings
        )
    }

    // MARK: - Selection, Movement & Resize Geometry Helpers

    static func hitTest(rawPoint: CGPoint, pageIndex: Int, in records: [PDFDraftAnnotationRecord]) -> PDFDraftAnnotationRecord? {
        for rec in records.reversed() where rec.pageIndex == pageIndex {
            let box = rec.bounds.cgRect.insetBy(dx: -6, dy: -6)
            if box.contains(rawPoint) {
                return rec
            }
        }
        return nil
    }

    static func movedRecord(_ rec: PDFDraftAnnotationRecord, dx: Double, dy: Double) -> PDFDraftAnnotationRecord {
        var copy = rec
        copy.bounds = PDFRectRecord(rec.bounds.cgRect.offsetBy(dx: dx, dy: dy))
        if let lines = rec.quadLines {
            copy.quadLines = lines.map { grp in grp.map { PDFPointRecord(CGPoint(x: $0.x + dx, y: $0.y + dy)) } }
        }
        if let ink = rec.inkPaths {
            copy.inkPaths = ink.map { stroke in stroke.map { PDFPointRecord(CGPoint(x: $0.x + dx, y: $0.y + dy)) } }
        }
        if let s = rec.lineStart { copy.lineStart = PDFPointRecord(CGPoint(x: s.x + dx, y: s.y + dy)) }
        if let e = rec.lineEnd { copy.lineEnd = PDFPointRecord(CGPoint(x: e.x + dx, y: e.y + dy)) }
        return copy
    }

    static func resizedRecord(_ rec: PDFDraftAnnotationRecord, to newBounds: CGRect) -> PDFDraftAnnotationRecord {
        let clamped = CGRect(
            x: newBounds.minX,
            y: newBounds.minY,
            width: max(12.0, newBounds.width),
            height: max(12.0, newBounds.height)
        )
        let old = rec.bounds.cgRect
        let sx = clamped.width / max(1.0, old.width)
        let sy = clamped.height / max(1.0, old.height)

        func remap(_ p: PDFPointRecord) -> PDFPointRecord {
            PDFPointRecord(CGPoint(
                x: clamped.minX + (CGFloat(p.x) - old.minX) * sx,
                y: clamped.minY + (CGFloat(p.y) - old.minY) * sy
            ))
        }

        var copy = rec
        copy.bounds = PDFRectRecord(clamped)
        copy.quadLines = rec.quadLines?.map { $0.map(remap) }
        copy.inkPaths = rec.inkPaths?.map { $0.map(remap) }
        copy.lineStart = rec.lineStart.map(remap)
        copy.lineEnd = rec.lineEnd.map(remap)
        return copy
    }

    static func buildTextMarkupQuads(from selection: PDFSelection, on page: PDFPage) -> (bounds: CGRect, quadLines: [[CGPoint]])? {
        var lines: [[CGPoint]] = []
        var unionRect = CGRect.null
        for lineSel in selection.selectionsByLine() {
            guard lineSel.pages.contains(page) else { continue }
            let r = lineSel.bounds(for: page)
            guard !r.isEmpty && r.width > 1 && r.height > 1 else { continue }
            unionRect = unionRect.isNull ? r : unionRect.union(r)
            lines.append([
                CGPoint(x: r.minX, y: r.maxY),
                CGPoint(x: r.maxX, y: r.maxY),
                CGPoint(x: r.minX, y: r.minY),
                CGPoint(x: r.maxX, y: r.minY)
            ])
        }
        guard !unionRect.isNull, !lines.isEmpty else { return nil }
        return (unionRect, lines)
    }

    // MARK: - Color Helpers

    static func color(fromHex hex: String, alpha: Double = 1.0) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: CGFloat(max(0.05, min(1.0, alpha))))
    }

    static func hexString(from color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((max(0, min(1, srgb.redComponent)) * 255.0).rounded())
        let g = Int((max(0, min(1, srgb.greenComponent)) * 255.0).rounded())
        let b = Int((max(0, min(1, srgb.blueComponent)) * 255.0).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
