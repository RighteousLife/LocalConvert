import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import LocalConvert

@Suite("PDF Page Normalization Workflow", .serialized)
struct PDFPageNormalizationWorkflowTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFNormalizationWorkflow_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Normalization request round-trips through the queue option")
    func requestOptionRoundTrip() throws {
        let request = PDFPageNormalizationRequest(target: .custom(width: 21, height: 29.7, unit: .centimeters))
        let encoded = try request.encodedOption()
        let decoded = try PDFPageNormalizationRequest.decode(from: [PDFPageNormalizationRequest.optionKey: encoded])

        #expect(decoded == request)
        #expect(throws: ConversionError.self) {
            try PDFPageNormalizationRequest.decode(from: [PDFPageNormalizationRequest.optionKey: "not-json"])
        }
    }

    @Test("Queue gate requires explicit confirmation only when inspection found structures")
    func confirmationGate() {
        let clear = PDFNormalizationPreflight(detectedFeatures: [])
        let flagged = PDFNormalizationPreflight(detectedFeatures: [
            PDFNormalizationDetectedFeature(id: "links", title: "Links", detail: "May not remain interactive.")
        ])

        #expect(!clear.requiresConfirmation)
        #expect(clear.permitsSubmission(afterExplicitConfirmation: false))
        #expect(flagged.requiresConfirmation)
        #expect(!flagged.permitsSubmission(afterExplicitConfirmation: false))
        #expect(flagged.permitsSubmission(afterExplicitConfirmation: true))

        var didEnqueue = false
        let cancelled = flagged.submit(afterExplicitConfirmation: false) { didEnqueue = true }
        #expect(!cancelled)
        #expect(!didEnqueue)
        let continued = flagged.submit(afterExplicitConfirmation: true) { didEnqueue = true }
        #expect(continued)
        #expect(didEnqueue)
    }

    @Test("PDF link annotations are surfaced in preflight findings")
    func linkAnnotationPreflight() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("linked.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
        guard let context = CGContext(source as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("Could not create link preflight PDF")
            return
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()

        let document = try #require(PDFDocument(url: source))
        let page = try #require(document.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 20), forType: .link, withProperties: nil))
        #expect(document.write(to: source))

        let inspection = try PDFDocumentInspector.inspect(url: source)
        let preflight = PDFNormalizationPreflight.assess(inspection)
        #expect(preflight.detectedFeatures.contains(where: { $0.id == "links" }))
        #expect(preflight.requiresConfirmation)
    }
}
