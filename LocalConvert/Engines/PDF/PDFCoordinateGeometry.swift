import Foundation
import PDFKit
import CoreGraphics
import AppKit

// MARK: - Shared PDF Page Coordinate Geometry

/// Single source of truth for PDF page geometry accounting for rotation (`0/90/180/270`),
/// `CropBox` / `MediaBox` origins, mixed page dimensions, and SwiftUI view <-> PDF page transforms.
enum PDFCoordinateGeometry {

    /// Effective displayed box in raw unrotated page coordinates (`CropBox` intersected with `MediaBox` when valid).
    static func effectiveDisplayBox(for page: PDFPage) -> CGRect {
        let media = page.bounds(for: .mediaBox)
        let crop = page.bounds(for: .cropBox)
        if !crop.isEmpty && !crop.isInfinite {
            let intersected = crop.intersection(media)
            if !intersected.isNull && intersected.width >= 1 && intersected.height >= 1 {
                return intersected
            }
            return crop
        }
        return media
    }

    /// Returns the visual upright size (points) after applying `page.rotation`.
    static func uprightSize(for page: PDFPage) -> CGSize {
        let box = effectiveDisplayBox(for: page)
        let rot = normalizedRotation(page.rotation)
        if rot == 90 || rot == 270 {
            return CGSize(width: max(1, box.height), height: max(1, box.width))
        }
        return CGSize(width: max(1, box.width), height: max(1, box.height))
    }

    static func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    /// Converts an upright normalized point `(nx, ny)` in `[0,1]x[0,1]` with **top-left** origin (`ny=0` top, `ny=1` bottom)
    /// into raw unrotated PDF page coordinates inside `effectiveDisplayBox(for: page)`.
    static func uprightNormalizedPointToRawPage(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        let nx = max(0.0, min(1.0, point.x))
        let ny = max(0.0, min(1.0, point.y))
        let box = effectiveDisplayBox(for: page)
        let rot = normalizedRotation(page.rotation)

        // PDF /Rotate is clockwise degrees, while raw PDF coordinates have bottom-left origin.
        let rx: CGFloat
        let ry: CGFloat
        switch rot {
        case 90:
            // Clockwise 90°: raw bottom-left (0,0) becomes upright top-left (0,0).
            rx = ny
            ry = nx
        case 180:
            // Clockwise 180°: raw bottom-right (1,0) becomes upright top-left (0,0).
            rx = 1.0 - nx
            ry = ny
        case 270:
            // Clockwise 270°: raw top-right (1,1) becomes upright top-left (0,0).
            rx = 1.0 - ny
            ry = 1.0 - nx
        default: // 0°
            rx = nx
            ry = 1.0 - ny
        }

        return CGPoint(
            x: box.minX + rx * box.width,
            y: box.minY + ry * box.height
        )
    }

    /// Inverse of `uprightNormalizedPointToRawPage`: maps raw PDF page coordinates back to upright normalized top-left `[0,1]`.
    static func rawPagePointToUprightNormalized(_ rawPoint: CGPoint, on page: PDFPage) -> CGPoint {
        let box = effectiveDisplayBox(for: page)
        let rx = (rawPoint.x - box.minX) / max(1.0, box.width)
        let ry = (rawPoint.y - box.minY) / max(1.0, box.height)
        let rot = normalizedRotation(page.rotation)

        let nx: CGFloat
        let ny: CGFloat
        switch rot {
        case 90:
            nx = ry
            ny = rx
        case 180:
            nx = 1.0 - rx
            ny = ry
        case 270:
            nx = 1.0 - ry
            ny = 1.0 - rx
        default:
            nx = rx
            ny = 1.0 - ry
        }
        return CGPoint(x: max(0.0, min(1.0, nx)), y: max(0.0, min(1.0, ny)))
    }

    /// Maps an upright normalized top-left rectangle (`0...1`) into a raw PDF page rectangle suitable for `PDFPage.setBounds(_:for: .cropBox)`.
    static func uprightNormalizedRectToRawPage(_ norm: NormalizedPDFCropRect, on page: PDFPage) -> CGRect {
        let p1 = uprightNormalizedPointToRawPage(CGPoint(x: norm.x, y: norm.y), on: page)
        let p2 = uprightNormalizedPointToRawPage(CGPoint(x: norm.x + norm.width, y: norm.y + norm.height), on: page)
        return CGRect(
            x: min(p1.x, p2.x),
            y: min(p1.y, p2.y),
            width: max(4.0, abs(p2.x - p1.x)),
            height: max(4.0, abs(p2.y - p1.y))
        )
    }

    /// Inverse of `uprightNormalizedRectToRawPage`.
    static func rawPageRectToUprightNormalized(_ rawRect: CGRect, on page: PDFPage) -> NormalizedPDFCropRect {
        let p1 = rawPagePointToUprightNormalized(CGPoint(x: rawRect.minX, y: rawRect.minY), on: page)
        let p2 = rawPagePointToUprightNormalized(CGPoint(x: rawRect.maxX, y: rawRect.maxY), on: page)
        return NormalizedPDFCropRect(
            x: Double(min(p1.x, p2.x)),
            y: Double(min(p1.y, p2.y)),
            width: Double(abs(p2.x - p1.x)),
            height: Double(abs(p2.y - p1.y))
        )
    }

    /// Maps a SwiftUI view point (top-left origin inside `viewSize`) into raw PDF page coordinates.
    static func viewPointToRawPage(_ viewPoint: CGPoint, viewSize: CGSize, on page: PDFPage) -> CGPoint {
        let nx = viewPoint.x / max(1.0, viewSize.width)
        let ny = viewPoint.y / max(1.0, viewSize.height)
        return uprightNormalizedPointToRawPage(CGPoint(x: nx, y: ny), on: page)
    }

    /// Maps a raw PDF page point into SwiftUI view coordinates (top-left origin inside `viewSize`).
    static func rawPagePointToView(_ rawPoint: CGPoint, viewSize: CGSize, on page: PDFPage) -> CGPoint {
        let norm = rawPagePointToUprightNormalized(rawPoint, on: page)
        return CGPoint(x: norm.x * viewSize.width, y: norm.y * viewSize.height)
    }
}

// MARK: - PDF Outline & Bookmark Remapper

enum PDFOutlineRemapper {

    struct RemapKey: Hashable {
        let sourceURL: URL
        let sourcePageIndex: Int

        init(url: URL, pageIndex: Int) {
            self.sourceURL = url.standardizedFileURL
            self.sourcePageIndex = pageIndex
        }
    }

    struct RemapOutcome {
        let outlineRoot: PDFOutline?
        let preservedCount: Int
        let omittedCount: Int
    }

    /// Rebuilds hierarchical `PDFOutline` trees from one or more source documents so bookmarks point to
    /// the copied `PDFPage` instances inside `targetDoc`, accurately counting omitted links whose targets were deleted.
    static func remapOutlines(
        sources: [(url: URL, document: PDFDocument)],
        targetPageLookup: [RemapKey: PDFPage],
        into targetDoc: PDFDocument
    ) -> RemapOutcome {
        let root = PDFOutline()
        var preserved = 0
        var omitted = 0

        func cloneNode(_ sourceNode: PDFOutline, sourceURL: URL, sourceDoc: PDFDocument) -> PDFOutline? {
            var newDest: PDFDestination? = nil
            var hasPageTarget = false
            var targetSurvived = false

            if let dest = sourceNode.destination, let destPage = dest.page {
                hasPageTarget = true
                let srcIdx = sourceDoc.index(for: destPage)
                if srcIdx != NSNotFound,
                   let mappedPage = targetPageLookup[RemapKey(url: sourceURL, pageIndex: srcIdx)] {
                    newDest = PDFDestination(page: mappedPage, at: dest.point)
                    targetSurvived = true
                }
            } else if let actionGoTo = sourceNode.action as? PDFActionGoTo,
                      let destPage = actionGoTo.destination.page {
                hasPageTarget = true
                let srcIdx = sourceDoc.index(for: destPage)
                if srcIdx != NSNotFound,
                   let mappedPage = targetPageLookup[RemapKey(url: sourceURL, pageIndex: srcIdx)] {
                    newDest = PDFDestination(page: mappedPage, at: actionGoTo.destination.point)
                    targetSurvived = true
                }
            }

            var childNodes: [PDFOutline] = []
            for i in 0..<sourceNode.numberOfChildren {
                if let child = sourceNode.child(at: i),
                   let clonedChild = cloneNode(child, sourceURL: sourceURL, sourceDoc: sourceDoc) {
                    childNodes.append(clonedChild)
                }
            }

            // If this node pointed to a page that was deleted and has no surviving children, omit cleanly.
            if hasPageTarget && !targetSurvived && childNodes.isEmpty {
                omitted += 1
                return nil
            }

            let copyNode = PDFOutline()
            copyNode.label = sourceNode.label
            copyNode.isOpen = sourceNode.isOpen

            if let newDest {
                copyNode.destination = newDest
                preserved += 1
            } else if let action = sourceNode.action, !(action is PDFActionGoTo) {
                copyNode.action = action
                preserved += 1
            } else if hasPageTarget && !targetSurvived {
                // Parent container whose own page was removed, kept solely because children survived -> bind to first child destination
                if let firstChildDest = childNodes.first?.destination {
                    copyNode.destination = firstChildDest
                }
                omitted += 1
            }

            for child in childNodes {
                copyNode.insertChild(child, at: copyNode.numberOfChildren)
            }
            return copyNode
        }

        for src in sources {
            guard let srcRoot = src.document.outlineRoot else { continue }
            for i in 0..<srcRoot.numberOfChildren {
                if let child = srcRoot.child(at: i),
                   let cloned = cloneNode(child, sourceURL: src.url, sourceDoc: src.document) {
                    root.insertChild(cloned, at: root.numberOfChildren)
                }
            }
        }

        if root.numberOfChildren > 0 {
            targetDoc.outlineRoot = root
            return RemapOutcome(outlineRoot: root, preservedCount: preserved, omittedCount: omitted)
        }
        return RemapOutcome(outlineRoot: nil, preservedCount: 0, omittedCount: omitted)
    }
}

// MARK: - Bounded Lazy PDF Thumbnail Cache

/// Thread-safe bounded `NSCache` for PDF page thumbnails. Avoids reloading full PDFs on SwiftUI redraws
/// and releases cached bitmaps automatically under memory pressure (`totalCostLimit = 96 MB`).
@MainActor
final class PDFThumbnailCache {
    static let shared = PDFThumbnailCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 96 * 1024 * 1024
        c.countLimit = 400
        return c
    }()

    private init() {}

    func invalidate(for url: URL) {
        // Bump generation or clear all cleanly without keeping stale versions
        cache.removeAllObjects()
    }

    func clearAll() {
        cache.removeAllObjects()
    }

    func thumbnail(
        for url: URL,
        pageIndex: Int,
        targetSize: CGSize,
        rotationDeltaDegrees: Int = 0,
        password: String? = nil
    ) async -> NSImage? {
        let std = url.standardizedFileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: std.path)
        let modTime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let w = Int(targetSize.width.rounded())
        let h = Int(targetSize.height.rounded())
        let key = "\(std.path)|\(fileSize)|\(Int(modTime))|\(pageIndex)|\(w)x\(h)|r\(PDFCoordinateGeometry.normalizedRotation(rotationDeltaDegrees))" as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let pwd = password
        let cgThumb: CGImage? = await Task.detached(priority: .utility) { () -> CGImage? in
            autoreleasepool {
                guard let doc = PDFDocument(url: std) else { return nil }
                if doc.isLocked {
                    guard let pwd, !pwd.isEmpty, doc.unlock(withPassword: pwd) else { return nil }
                }
                guard pageIndex >= 0, pageIndex < doc.pageCount,
                      let page = doc.page(at: pageIndex) else { return nil }

                if rotationDeltaDegrees != 0 {
                    page.rotation = PDFCoordinateGeometry.normalizedRotation(page.rotation + rotationDeltaDegrees)
                }
                let thumb = page.thumbnail(of: targetSize, for: .cropBox)
                var rect = CGRect(origin: .zero, size: thumb.size)
                return thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
        }.value

        guard let cgThumb else { return nil }
        let nsImage = NSImage(cgImage: cgThumb, size: CGSize(width: cgThumb.width, height: cgThumb.height))
        let byteCost = max(1, cgThumb.width * cgThumb.height * 4)
        cache.setObject(nsImage, forKey: key, cost: byteCost)
        return nsImage
    }
}
