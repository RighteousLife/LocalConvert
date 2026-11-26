import Testing
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import CryptoKit
import AppKit
@testable import LocalConvert

@Suite("Phase 44.2 — PDF Annotation & Editing", .serialized)
struct PDFAnnotationTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P44_2_\(name)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTextPDFWithFormWidgetAndBookmark(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.engineExecutionFailed("Failed CGContext", underlyingError: nil)
        }
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, 18, nil)
        ctx.beginPDFPage(nil)
        ctx.setFillColor(.white)
        ctx.fill(box)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor.black
        ]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "CONFIDENTIAL_UNDER_ANNOTATION" as CFString, attrs as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 72, y: 680)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()

        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            throw ConversionError.invalidInput("Failed reload")
        }
        let widget = PDFAnnotation(bounds: CGRect(x: 72, y: 500, width: 200, height: 28), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "signerName"
        widget.widgetStringValue = "Alice Example"
        page.addAnnotation(widget)

        let fresh = PDFDocument()
        fresh.insert(page.copy() as! PDFPage, at: 0)
        let root = PDFOutline()
        let bm = PDFOutline()
        bm.label = "Section 1"
        bm.destination = PDFDestination(page: fresh.page(at: 0)!, at: CGPoint(x: 0, y: 792))
        root.insertChild(bm, at: 0)
        fresh.outlineRoot = root
        fresh.write(to: url)
    }

    @Test("Round-trip save & reload of all 10 annotation subtypes plus AcroForm widget and outline preservation")
    func roundTripAllAnnotationSubtypes() async throws {
        let dir = try makeTempDir("RoundTrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputURL = dir.appendingPathComponent("input.pdf")
        let outURL = dir.appendingPathComponent("annotated.pdf")
        try makeTextPDFWithFormWidgetAndBookmark(at: inputURL)
        let inputHashBefore = try sha256Hex(inputURL)

        guard let doc = PDFDocument(url: inputURL), let page = doc.page(at: 0) else {
            Issue.record("Unable to open PDF")
            return
        }
        let selections = doc.findString("CONFIDENTIAL_UNDER_ANNOTATION", withOptions: [])
        let markup = selections.first.flatMap { PDFAnnotationService.buildTextMarkupQuads(from: $0, on: page) }
        #expect(markup != nil)
        let qBounds = markup?.bounds ?? CGRect(x: 72, y: 675, width: 220, height: 22)
        let qLines = markup?.quadLines

        let records: [PDFDraftAnnotationRecord] = [
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .highlight, bounds: qBounds, quadLines: qLines, contents: "HL note"),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .underline, bounds: qBounds, quadLines: qLines),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .strikeOut, bounds: qBounds, quadLines: qLines),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .note, bounds: CGRect(x: 340, y: 650, width: 24, height: 24), contents: "Sticky comment"),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .freeText, bounds: CGRect(x: 72, y: 580, width: 180, height: 34), contents: "Callout label", style: PDFAnnotationStyle(strokeColorHex: "#0A84FF", fontSize: 13)),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .ink, bounds: CGRect(x: 80, y: 360, width: 110, height: 60), inkPaths: [[CGPoint(x: 88, y: 370), CGPoint(x: 140, y: 405), CGPoint(x: 182, y: 380)]]),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .rectangle, bounds: CGRect(x: 72, y: 670, width: 260, height: 36), style: PDFAnnotationStyle(strokeColorHex: "#1C1C1E", fillColorHex: "#1C1C1E", opacity: 1.0)),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .circle, bounds: CGRect(x: 360, y: 540, width: 80, height: 60)),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .line, bounds: CGRect(x: 70, y: 300, width: 150, height: 40), lineStart: CGPoint(x: 80, y: 310), lineEnd: CGPoint(x: 210, y: 330)),
            PDFDraftAnnotationRecord(pageIndex: 0, kind: .arrow, bounds: CGRect(x: 240, y: 300, width: 150, height: 40), lineStart: CGPoint(x: 250, y: 310), lineEnd: CGPoint(x: 380, y: 330))
        ]

        let result = try await PDFAnnotationService.applyAndSave(
            inputURL: inputURL,
            outputURL: outURL,
            options: PDFAnnotationSaveOptions(records: records, flattenAnnotations: false, password: nil)
        ) { _ in }

        #expect(result.savedAnnotationsCount == 10)
        #expect(result.flattened == false)
        #expect(result.preservedWidgetCount == 1)
        #expect(try sha256Hex(inputURL) == inputHashBefore) // non-destructive source preservation

        let reloaded = try PDFAnnotationService.loadExistingAnnotations(from: outURL)
        #expect(reloaded.count == 10)
        let loadedKinds = Set(reloaded.map(\.kind))
        for expectedKind in [PDFAnnotationTool.highlight, .underline, .strikeOut, .note, .freeText, .ink, .rectangle, .circle, .line, .arrow] {
            #expect(loadedKinds.contains(expectedKind))
        }

        // Verify note text, freeText callout, ink vertices, line endpoints, and outline/widget survival
        let loadedNote = reloaded.first(where: { $0.kind == .note })
        #expect(loadedNote?.contents == "Sticky comment")
        let loadedFree = reloaded.first(where: { $0.kind == .freeText })
        #expect(loadedFree?.contents == "Callout label")
        let loadedInk = reloaded.first(where: { $0.kind == .ink })
        #expect((loadedInk?.inkPaths?.first?.count ?? 0) >= 3)
        let loadedArrow = reloaded.first(where: { $0.kind == .arrow })
        #expect(loadedArrow?.lineStart != nil && loadedArrow?.lineEnd != nil)

        let outDoc = try #require(PDFDocument(url: outURL))
        #expect((outDoc.outlineRoot?.numberOfChildren ?? 0) == 1)
        let outWidgets = outDoc.page(at: 0)?.annotations.filter { ($0.type ?? "").contains("Widget") } ?? []
        #expect(outWidgets.count == 1)
        #expect(outWidgets.first?.widgetStringValue == "Alice Example")

        // Non-redaction proof: black filled rectangle annotation over text does NOT purge underlying PDF text
        let extractedText = outDoc.page(at: 0)?.string ?? ""
        #expect(extractedText.contains("CONFIDENTIAL_UNDER_ANNOTATION"))
    }

    @Test("Flattening burns annotations into page graphics and leaves non-widget annotation list empty")
    func flattenBurnInAnnotations() async throws {
        let dir = try makeTempDir("Flatten")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputURL = dir.appendingPathComponent("input.pdf")
        let outURL = dir.appendingPathComponent("flattened.pdf")
        try makeTextPDFWithFormWidgetAndBookmark(at: inputURL)

        let rectRec = PDFDraftAnnotationRecord(
            pageIndex: 0,
            kind: .freeText,
            bounds: CGRect(x: 100, y: 400, width: 160, height: 32),
            contents: "BURNED_TEXT",
            style: PDFAnnotationStyle(strokeColorHex: "#FF453A", fontSize: 14)
        )
        let res = try await PDFAnnotationService.applyAndSave(
            inputURL: inputURL,
            outputURL: outURL,
            options: PDFAnnotationSaveOptions(records: [rectRec], flattenAnnotations: true, password: nil)
        ) { _ in }

        #expect(res.flattened == true)
        let outDoc = try #require(PDFDocument(url: outURL))
        #expect((outDoc.outlineRoot?.numberOfChildren ?? 0) == 1)

        // Editable markup records must now be empty because annotations were burned into graphics
        let remainingEditable = try PDFAnnotationService.loadExistingAnnotations(from: outURL)
        #expect(remainingEditable.isEmpty)
    }

    @Test("Move and resize geometry translate ink points and line endpoints accurately")
    func moveAndResizeGeometry() {
        let arrow = PDFDraftAnnotationRecord(
            pageIndex: 0,
            kind: .arrow,
            bounds: CGRect(x: 100, y: 100, width: 80, height: 40),
            lineStart: CGPoint(x: 110, y: 110),
            lineEnd: CGPoint(x: 170, y: 130)
        )
        let moved = PDFAnnotationService.movedRecord(arrow, dx: 25, dy: -15)
        #expect(abs(moved.bounds.x - 125) < 0.001)
        #expect(abs(moved.bounds.y - 85) < 0.001)
        #expect(abs((moved.lineStart?.x ?? 0) - 135) < 0.001)
        #expect(abs((moved.lineEnd?.y ?? 0) - 115) < 0.001)

        let hit = PDFAnnotationService.hitTest(rawPoint: CGPoint(x: 150, y: 105), pageIndex: 0, in: [moved])
        #expect(hit?.id == moved.id)

        let resized = PDFAnnotationService.resizedRecord(moved, to: CGRect(x: 125, y: 85, width: 160, height: 80))
        #expect(abs(resized.bounds.width - 160) < 0.001)
        #expect(abs((resized.lineEnd?.x ?? 0) - 265) < 0.001)
        #expect(abs(((resized.lineEnd?.x ?? 0) - 125) - ((moved.lineEnd?.x ?? 0) - 125) * 2.0) < 0.001)
    }

    @Test("PDFAnnotationDraftUndoCommand supports Undo/Redo coalescing and stays session-only without leaking comments to journal.json")
    @MainActor
    func annotationUndoCoalescingAndPrivacy() async throws {
        let dir = try makeTempDir("UndoPrivacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdfURL = dir.appendingPathComponent("secret.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: pdfURL)

        let coord = UndoRedoCoordinator(journalDirectoryURL: dir.appendingPathComponent("journal"))
        let store = PDFToolboxStore(undoCoordinator: coord)
        let secretComment = "TOP_SECRET_ANNOTATION_COMMENT_XYZ"

        let rec = PDFDraftAnnotationRecord(
            pageIndex: 0,
            kind: .note,
            bounds: CGRect(x: 50, y: 50, width: 24, height: 24),
            contents: ""
        )
        store.hydrateAnnotations([rec], for: pdfURL)

        // Rapid keystrokes coalesced under same key should fold into ONE Undo step
        store.updateAnnotationDraft(for: pdfURL, title: "Edit Annotation Text", coalesceKey: "text_\(rec.id)") { d in
            d.records[0].contents = "TOP_"
        }
        store.updateAnnotationDraft(for: pdfURL, title: "Edit Annotation Text", coalesceKey: "text_\(rec.id)") { d in
            d.records[0].contents = secretComment
        }
        await store.flushPendingUndoRecords()

        let entries = coord.undoEntries(for: .pdfToolbox)
        #expect(entries.count == 1)
        #expect(store.annotationDraft(for: pdfURL).records.first?.contents == secretComment)

        // Privacy check: session-only command (survivesRestart == false) must NOT persist annotation comments into journal.json
        if FileManager.default.fileExists(atPath: coord.journalFileURL.path) {
            let journalRaw = try String(contentsOf: coord.journalFileURL, encoding: .utf8)
            #expect(!journalRaw.contains(secretComment))
        }

        await coord.undo(in: .pdfToolbox)
        #expect(store.annotationDraft(for: pdfURL).records.first?.contents == "")

        await coord.redo(in: .pdfToolbox)
        #expect(store.annotationDraft(for: pdfURL).records.first?.contents == secretComment)
    }
}
