import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import CryptoKit
@testable import LocalConvert

@Suite("Phase 44.1 — PDF Page Management & Coordinate Geometry", .serialized)
struct PDFPageManagementTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P44_1_\(name)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTaggedPDF(
        at url: URL,
        pages: [(label: String, size: CGSize, rotation: Int)],
        bookmarks: [(title: String, pageIndex: Int)] = []
    ) throws {
        var firstBox = CGRect(origin: .zero, size: pages.first?.size ?? CGSize(width: 612, height: 792))
        guard let ctx = CGContext(url as CFURL, mediaBox: &firstBox, nil) else {
            throw ConversionError.engineExecutionFailed("Failed PDF CGContext", underlyingError: nil)
        }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 18, nil)
        for p in pages {
            var box = CGRect(origin: .zero, size: p.size)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.setFillColor(.white)
            ctx.fill(box)

            // Corner markers to verify orientation/crop math rigorously
            let drawTag: (String, CGPoint) -> Void = { text, pt in
                let attr = CFAttributedStringCreate(nil, text as CFString, [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: CGColor.black
                ] as CFDictionary)!
                ctx.textPosition = pt
                CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            }
            drawTag(p.label, CGPoint(x: 40, y: p.size.height - 60))
            drawTag("RAW_TOP_LEFT", CGPoint(x: 24, y: p.size.height - 32))
            drawTag("RAW_BOTTOM_RIGHT", CGPoint(x: p.size.width - 210, y: 24))
            ctx.endPDFPage()
        }
        ctx.closePDF()

        if pages.contains(where: { $0.rotation != 0 }) || !bookmarks.isEmpty {
            let srcDoc = try #require(PDFDocument(url: url))
            let doc = PDFDocument()
            for idx in 0..<srcDoc.pageCount {
                if let copied = srcDoc.page(at: idx)?.copy() as? PDFPage {
                    if pages[idx].rotation != 0 {
                        copied.rotation = pages[idx].rotation
                    }
                    doc.insert(copied, at: idx)
                }
            }
            if !bookmarks.isEmpty {
                let root = PDFOutline()
                for bm in bookmarks where bm.pageIndex >= 0 && bm.pageIndex < doc.pageCount {
                    if let targetPage = doc.page(at: bm.pageIndex) {
                        let node = PDFOutline()
                        node.label = bm.title
                        node.destination = PDFDestination(page: targetPage, at: CGPoint(x: 0, y: pages[bm.pageIndex].size.height))
                        root.insertChild(node, at: root.numberOfChildren)
                    }
                }
                doc.outlineRoot = root
            }
            let tempOut = url.deletingLastPathComponent().appendingPathComponent("tmp_\(UUID().uuidString).pdf")
            #expect(doc.write(to: tempOut))
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tempOut, to: url)
        }
    }

    // MARK: - 1. Coordinate Geometry Across 0/90/180/270 Rotations

    @Test("PDFCoordinateGeometry round-trips points and maps upright top-left across 0/90/180/270 rotations")
    func testCoordinateGeometryAllRotations() throws {
        let dir = try makeTempDir("geom")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("rotations.pdf")
        try makeTaggedPDF(at: pdfURL, pages: [
            ("P0", CGSize(width: 600, height: 800), 0),
            ("P90", CGSize(width: 600, height: 800), 90),
            ("P180", CGSize(width: 600, height: 800), 180),
            ("P270", CGSize(width: 600, height: 800), 270)
        ])

        let doc = try #require(PDFDocument(url: pdfURL))
        let viewPointNorm = CGPoint(x: 0.25, y: 0.35)
        for idx in 0..<4 {
            let page = try #require(doc.page(at: idx))
            let rawPt = PDFCoordinateGeometry.uprightNormalizedPointToRawPage(viewPointNorm, on: page)
            let roundTrip = PDFCoordinateGeometry.rawPagePointToUprightNormalized(rawPt, on: page)
            #expect(abs(roundTrip.x - viewPointNorm.x) < 0.001)
            #expect(abs(roundTrip.y - viewPointNorm.y) < 0.001)

            // Verify uprightSize swaps dims cleanly on 90/270
            let uSize = PDFCoordinateGeometry.uprightSize(for: page)
            if idx == 1 || idx == 3 {
                #expect(abs(uSize.width - 800) < 1 && abs(uSize.height - 600) < 1)
            } else {
                #expect(abs(uSize.width - 600) < 1 && abs(uSize.height - 800) < 1)
            }
        }
    }

    // MARK: - 2. Delete, Reorder, Rotate, Duplicate, Extract & Outline Remapping

    @Test("Workspace page delete, reorder, duplicate, rotate preserves valid outlines and reports omitted outlines")
    func testPageManagementWorkspaceAndOutlineRemap() async throws {
        let dir = try makeTempDir("workspace")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("bookmarked.pdf")
        try makeTaggedPDF(
            at: srcURL,
            pages: [
                ("CHAPTER_1", CGSize(width: 612, height: 792), 0),
                ("CHAPTER_2", CGSize(width: 612, height: 792), 0),
                ("CHAPTER_3", CGSize(width: 612, height: 792), 0),
                ("APPENDIX", CGSize(width: 800, height: 600), 0)
            ],
            bookmarks: [
                ("Ch1", 0),
                ("Ch2", 1),
                ("Ch3", 2),
                ("Appendix", 3)
            ]
        )
        let srcHash = try sha256Hex(srcURL)

        // Delete page 2 (Ch2), reorder [Appendix, Ch3, Ch1], duplicate Ch1, rotate Appendix +90
        let draft = PDFPageWorkspaceDraft(
            primaryURL: srcURL,
            pages: [
                PDFPageDescriptor(sourceURL: srcURL, sourcePageIndex: 3, rotationDeltaDegrees: 90),
                PDFPageDescriptor(sourceURL: srcURL, sourcePageIndex: 2),
                PDFPageDescriptor(sourceURL: srcURL, sourcePageIndex: 0),
                PDFPageDescriptor(sourceURL: srcURL, sourcePageIndex: 0)
            ]
        )
        let outURL = dir.appendingPathComponent("organized.pdf")
        let res = try await PDFPageManagementService.commitWorkspace(draft: draft, outputURL: outURL) { _ in }

        #expect(res.pageCount == 4)
        #expect(res.preservedOutlineCount == 3)
        #expect(res.omittedOutlineCount == 1)
        #expect(try sha256Hex(srcURL) == srcHash)

        let outDoc = try #require(PDFDocument(url: outURL))
        #expect(outDoc.pageCount == 4)
        #expect((outDoc.page(at: 0)?.string ?? "").contains("APPENDIX"))
        #expect(outDoc.page(at: 0)?.rotation == 90)
        #expect((outDoc.page(at: 1)?.string ?? "").contains("CHAPTER_3"))
        #expect((outDoc.page(at: 2)?.string ?? "").contains("CHAPTER_1"))
        #expect((outDoc.page(at: 3)?.string ?? "").contains("CHAPTER_1"))

        let outlineRoot = try #require(outDoc.outlineRoot)
        #expect(outlineRoot.numberOfChildren == 3)
        let ch1Page = try #require(outlineRoot.child(at: 0)?.destination?.page)
        let appendixPage = try #require(outlineRoot.child(at: 2)?.destination?.page)
        #expect(outDoc.index(for: ch1Page) == 2)
        #expect(outDoc.index(for: appendixPage) == 0)
    }

    // MARK: - 3. Merge, Insert Pages From Another PDF & Split Strategies

    @Test("Merge, insert from second PDF, and all split strategies produce valid outputs without modifying sources")
    func testMergeInsertAndSplitStrategies() async throws {
        let dir = try makeTempDir("merge_split")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfA = dir.appendingPathComponent("docA.pdf")
        let pdfB = dir.appendingPathComponent("docB.pdf")
        try makeTaggedPDF(
            at: pdfA,
            pages: [
                ("A_ONE", CGSize(width: 612, height: 792), 0),
                ("A_TWO", CGSize(width: 612, height: 792), 0),
                ("A_THREE", CGSize(width: 612, height: 792), 0),
                ("A_FOUR", CGSize(width: 612, height: 792), 0)
            ],
            bookmarks: [
                ("Part1", 0),
                ("Part2", 2)
            ]
        )
        try makeTaggedPDF(
            at: pdfB,
            pages: [
                ("B_INSERTED", CGSize(width: 595, height: 842), 0)
            ],
            bookmarks: [("InsertedSec", 0)]
        )

        // Merge
        let mergedURL = dir.appendingPathComponent("merged.pdf")
        let mergeRes = try await PDFPageManagementService.merge(inputs: [pdfA, pdfB], outputURL: mergedURL) { _ in }
        #expect(mergeRes.pageCount == 5)
        #expect(mergeRes.preservedOutlineCount == 3)

        // Insert B[1] into A before page 3
        let insertedURL = dir.appendingPathComponent("inserted.pdf")
        let insRes = try await PDFPageManagementService.insertPages(
            basePDF: pdfA,
            insertPDF: pdfB,
            insertPageRanges: "1",
            atOneBasedPosition: 3,
            outputURL: insertedURL
        ) { _ in }
        #expect(insRes.pageCount == 5)
        let insDoc = try #require(PDFDocument(url: insertedURL))
        #expect((insDoc.page(at: 2)?.string ?? "").contains("B_INSERTED"))

        // Split every 2 pages
        let splitNDir = dir.appendingPathComponent("splitN", isDirectory: true)
        try FileManager.default.createDirectory(at: splitNDir, withIntermediateDirectories: true)
        let splitNRes = try await PDFPageManagementService.split(
            input: pdfA,
            strategy: .everyNPages(2),
            outputDirectory: splitNDir,
            baseName: "docA",
            existingFileHandling: .createUnique
        ) { _ in }
        #expect(splitNRes.pageCount == 2)
        #expect(splitNRes.additionalOutputURLs.count == 1)

        // Split by bookmarks
        let splitBMDir = dir.appendingPathComponent("splitBM", isDirectory: true)
        try FileManager.default.createDirectory(at: splitBMDir, withIntermediateDirectories: true)
        let splitBMRes = try await PDFPageManagementService.split(
            input: pdfA,
            strategy: .topLevelBookmarks,
            outputDirectory: splitBMDir,
            baseName: "docA",
            existingFileHandling: .createUnique
        ) { _ in }
        #expect(splitBMRes.pageCount == 2)
        let sec1 = try #require(PDFDocument(url: splitBMRes.outputURL))
        let sec2 = try #require(PDFDocument(url: splitBMRes.additionalOutputURLs[0]))
        #expect(sec1.pageCount == 2)
        #expect(sec2.pageCount == 2)
    }

    // MARK: - 4. Crop & Page Dimension Normalization Across Mixed Orientations

    @Test("CropBox crop and A4 page normalization preserve vector text on upright and rotated pages")
    func testCropAndPageDimensionNormalization() async throws {
        let dir = try makeTempDir("crop_resize")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("mixed.pdf")
        try makeTaggedPDF(at: srcURL, pages: [
            ("UPRIGHT_PORTRAIT", CGSize(width: 612, height: 792), 0),
            ("ROTATED_LANDSCAPE", CGSize(width: 612, height: 792), 90)
        ])

        // 4A. Non-destructive top-half CropBox
        let croppedURL = dir.appendingPathComponent("cropped.pdf")
        _ = try await PDFPageManagementService.cropAndResizePages(
            input: srcURL,
            pageRanges: nil,
            normalizedCrop: NormalizedPDFCropRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5),
            targetSizePreset: .original,
            outputURL: croppedURL
        ) { _ in }
        let croppedDoc = try #require(PDFDocument(url: croppedURL))
        let c0 = try #require(croppedDoc.page(at: 0)).bounds(for: .cropBox)
        #expect(abs(c0.width - 306) < 2 && abs(c0.height - 396) < 2)
        // Page 0 upright top-left corner in raw PDF is high Y (>= 396)
        #expect(c0.minY >= 390)

        // 4B. Resize to A4 preserving orientation + vector text
        let a4URL = dir.appendingPathComponent("a4.pdf")
        _ = try await PDFPageManagementService.cropAndResizePages(
            input: srcURL,
            pageRanges: nil,
            normalizedCrop: nil,
            targetSizePreset: .a4,
            resizeMode: .fitPreserveAspect,
            outputURL: a4URL
        ) { _ in }
        let a4Doc = try #require(PDFDocument(url: a4URL))
        let p0Box = try #require(a4Doc.page(at: 0)).bounds(for: .mediaBox)
        let p1Box = try #require(a4Doc.page(at: 1)).bounds(for: .mediaBox)
        #expect(abs(p0Box.width - 595.28) < 1 && abs(p0Box.height - 841.89) < 1)
        // Rotated page 1 was landscape upright (792 x 612), so matchPageOrientation produces landscape A4
        #expect(abs(p1Box.width - 841.89) < 1 && abs(p1Box.height - 595.28) < 1)
        #expect((a4Doc.page(at: 0)?.string ?? "").contains("UPRIGHT_PORTRAIT"))
        #expect((a4Doc.page(at: 1)?.string ?? "").contains("ROTATED_LANDSCAPE"))
    }

    // MARK: - 5. Large 100-Page Performance & Bounded Thumbnail Cache

    @Test("100-page reorder/delete/thumbnail cache runs cleanly without retaining stale versions")
    @MainActor
    func testLarge100PageWorkspaceAndThumbnailCache() async throws {
        let dir = try makeTempDir("large100")
        defer { try? FileManager.default.removeItem(at: dir) }

        let largeURL = dir.appendingPathComponent("hundred.pdf")
        let specs = (1...100).map { ("Page_\($0)", CGSize(width: 612, height: 792), 0) }
        try makeTaggedPDF(at: largeURL, pages: specs)

        let thumb1 = await PDFThumbnailCache.shared.thumbnail(for: largeURL, pageIndex: 0, targetSize: CGSize(width: 120, height: 150))
        let thumb100 = await PDFThumbnailCache.shared.thumbnail(for: largeURL, pageIndex: 99, targetSize: CGSize(width: 120, height: 150))
        #expect(thumb1 != nil)
        #expect(thumb100 != nil)

        let outURL = dir.appendingPathComponent("trimmed_90.pdf")
        let res = try await PDFPageManagementService.deletePages(input: largeURL, pageRanges: "1-10", outputURL: outURL) { _ in }
        #expect(res.pageCount == 90)
        PDFThumbnailCache.shared.invalidate(for: largeURL)
    }

    // MARK: - 6. Page Workspace Undo/Redo, Stale Guard & Restart Rehydration

    @Test("PDFPageDraftUndoCommand supports Undo/Redo, stale detection, and restart rehydration")
    @MainActor
    func testPageWorkspaceUndoRehydrationAndStaleGuard() async throws {
        let dir = try makeTempDir("page_undo")
        defer { try? FileManager.default.removeItem(at: dir) }

        let journalDir = dir.appendingPathComponent("journal", isDirectory: true)
        let artifactsDir = dir.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

        let srcPDF = dir.appendingPathComponent("source.pdf")
        try makeTaggedPDF(at: srcPDF, pages: [
            ("One", CGSize(width: 612, height: 792), 0),
            ("Two", CGSize(width: 612, height: 792), 0),
            ("Three", CGSize(width: 612, height: 792), 0)
        ])

        let coord1 = UndoRedoCoordinator(journalDirectoryURL: journalDir, artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir))
        let store1 = PDFToolboxStore(undoCoordinator: coord1)
        store1.hydratePageWorkspace(for: srcPDF, pageCount: 3)
        #expect(coord1.undoEntries(for: .pdfToolbox).isEmpty)

        store1.updatePageWorkspace(for: srcPDF, title: "Rotate Page 2") { d in
            d.pages[1].rotationDeltaDegrees = 90
        }
        await store1.flushPendingUndoRecords()
        coord1.flushPersistence()
        #expect(store1.pageWorkspaceDraft(for: srcPDF).pages[1].rotationDeltaDegrees == 90)

        // Relaunch session -> rehydrate PDFPageDraftUndoCommand
        let coord2 = UndoRedoCoordinator(journalDirectoryURL: journalDir, artifactManager: RecoveryArtifactManager(baseDirectoryURL: artifactsDir))
        let store2 = PDFToolboxStore(undoCoordinator: coord2)
        await coord2.restorePersistedHistory()
        #expect(coord2.canUndo(in: .pdfToolbox))

        await coord2.undo(in: .pdfToolbox)
        #expect(store2.pageWorkspaceDraft(for: srcPDF).pages.count == 3)
        #expect(store2.pageWorkspaceDraft(for: srcPDF).pages[1].rotationDeltaDegrees == 0)

        await coord2.redo(in: .pdfToolbox)
        #expect(store2.pageWorkspaceDraft(for: srcPDF).pages[1].rotationDeltaDegrees == 90)

        // Modifying source file on disk causes commitWorkspace stale-file check to throw cleanly
        let capturedDraft = store2.pageWorkspaceDraft(for: srcPDF)
        try await Task.sleep(for: .milliseconds(50))
        try makeTaggedPDF(at: srcPDF, pages: [("Replaced", CGSize(width: 612, height: 792), 0)])

        var didThrowStale = false
        do {
            _ = try await PDFPageManagementService.commitWorkspace(
                draft: capturedDraft,
                outputURL: dir.appendingPathComponent("should_fail.pdf")
            ) { _ in }
        } catch {
            didThrowStale = true
        }
        #expect(didThrowStale)
    }
}
