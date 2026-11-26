import Testing
@testable import LocalConvert

@Suite("PDF Page Normalization Models")
struct PDFPageNormalizationModelTests {
    private let samplePages = [
        PDFEffectivePageMetrics(pageNumber: 1, widthPoints: 612, heightPoints: 792),
        PDFEffectivePageMetrics(pageNumber: 2, widthPoints: 900, heightPoints: 500),
        PDFEffectivePageMetrics(pageNumber: 3, widthPoints: 600, heightPoints: 750)
    ]

    @Test("Paper catalog contains each requested nominal size with distinct identifiers")
    func catalogRowsAndIdentifiers() throws {
        let expected: [(String, Double, Double, PDFMeasurementUnit)] = [
            ("iso-a0", 841, 1189, .millimeters), ("iso-a1", 594, 841, .millimeters),
            ("iso-a2", 420, 594, .millimeters), ("iso-a3", 297, 420, .millimeters),
            ("iso-a4", 210, 297, .millimeters), ("iso-a5", 148, 210, .millimeters),
            ("iso-a6", 105, 148, .millimeters),
            ("iso-b0", 1000, 1414, .millimeters), ("iso-b1", 707, 1000, .millimeters),
            ("iso-b2", 500, 707, .millimeters), ("iso-b3", 353, 500, .millimeters),
            ("iso-b4", 250, 353, .millimeters), ("iso-b5", 176, 250, .millimeters),
            ("iso-b6", 125, 176, .millimeters),
            ("jis-b0", 1030, 1456, .millimeters), ("jis-b1", 728, 1030, .millimeters),
            ("jis-b2", 515, 728, .millimeters), ("jis-b3", 364, 515, .millimeters),
            ("jis-b4", 257, 364, .millimeters), ("jis-b5", 182, 257, .millimeters),
            ("jis-b6", 128, 182, .millimeters),
            ("us-letter", 8.5, 11, .inches), ("us-legal", 8.5, 14, .inches),
            ("us-tabloid", 11, 17, .inches), ("us-executive", 7.25, 10.5, .inches),
            ("ansi-a", 8.5, 11, .inches), ("ansi-b", 11, 17, .inches),
            ("ansi-c", 17, 22, .inches), ("ansi-d", 22, 34, .inches),
            ("ansi-e", 34, 44, .inches)
        ]

        // The catalog intentionally keeps duplicate physical sizes as separate paper identities.
        #expect(PDFPageSizeCatalogData.all.count == expected.count)
        #expect(Set(PDFPageSizeCatalogData.all.map(\.id)).count == expected.count)

        for (id, width, height, unit) in expected {
            let paper = try #require(PDFPageSizeCatalogData.paperSize(id: id))
            #expect(paper.portraitWidth == width)
            #expect(paper.portraitHeight == height)
            #expect(paper.unit == unit)
        }

        let letter = try #require(PDFPageSizeCatalogData.paperSize(id: "us-letter"))
        let ansiA = try #require(PDFPageSizeCatalogData.paperSize(id: "ansi-a"))
        let tabloid = try #require(PDFPageSizeCatalogData.paperSize(id: "us-tabloid"))
        let ansiB = try #require(PDFPageSizeCatalogData.paperSize(id: "ansi-b"))
        #expect(letter.id != ansiA.id)
        #expect(tabloid.id != ansiB.id)
        #expect(try letter.dimensionsInPoints(orientation: .portrait) == ansiA.dimensionsInPoints(orientation: .portrait))
        #expect(try tabloid.dimensionsInPoints(orientation: .portrait) == ansiB.dimensionsInPoints(orientation: .portrait))
        #expect(PDFPageSizeCatalogData.sizes(in: .isoA).count == 7)
        #expect(PDFPageSizeCatalogData.sizes(in: .isoB).count == 7)
        #expect(PDFPageSizeCatalogData.sizes(in: .jisB).count == 7)
        #expect(PDFPageSizeCatalogData.sizes(in: .northAmerican).count == 9)
        #expect(try PDFPageSizeCatalogData.paperSize(id: "iso-b5")?.dimensionsInPoints(orientation: .portrait)
            != PDFPageSizeCatalogData.paperSize(id: "jis-b5")?.dimensionsInPoints(orientation: .portrait))
    }

    @Test("Unit conversions round-trip common measurements and reject invalid identifiers")
    func unitConversions() throws {
        #expect(try PDFMeasurementUnit.inches.points(from: 1) == 72)
        #expect(abs(try PDFMeasurementUnit.millimeters.points(from: 25.4) - 72) < 1e-12)
        #expect(abs(try PDFMeasurementUnit.centimeters.points(from: 2.54) - 72) < 1e-12)
        for unit in PDFMeasurementUnit.allCases {
            let points = try unit.points(from: 123.456)
            #expect(abs(try unit.value(fromPoints: points) - 123.456) < 1e-10)
            #expect(try PDFMeasurementUnit(identifier: unit.rawValue) == unit)
        }
        #expect(normalizationError { _ = try PDFMeasurementUnit(identifier: "yards") }
            == .unsupportedUnitIdentifier("yards"))
        #expect(normalizationError { _ = try PDFMeasurementUnit.millimeters.points(from: .infinity) }
            == .nonFiniteValue)
        #expect(normalizationError { _ = try PDFMeasurementUnit.inches.points(from: 0) }
            == .nonPositiveValue)
        #expect(normalizationError { _ = try PDFMeasurementUnit.inches.points(from: -2) }
            == .nonPositiveValue)
        #expect(normalizationError { _ = try PDFMeasurementUnit.millimeters.points(from: Double.greatestFiniteMagnitude) }
            == .arithmeticOverflow)
    }

    @Test("First, specific, and largest page targets resolve effective dimensions")
    func pageTargetResolution() throws {
        #expect(try PDFPageSizeResolver.resolve(target: .firstPage(orientation: .reference), pages: samplePages)
            == PDFResolvedPageSize(widthPoints: 612, heightPoints: 792))
        #expect(try PDFPageSizeResolver.resolve(target: .specificPage(pageNumber: 2, orientation: .reference), pages: samplePages)
            == PDFResolvedPageSize(widthPoints: 900, heightPoints: 500))

        let largest = [
            PDFEffectivePageMetrics(pageNumber: 3, widthPoints: 300, heightPoints: 400),
            PDFEffectivePageMetrics(pageNumber: 2, widthPoints: 400, heightPoints: 300),
            PDFEffectivePageMetrics(pageNumber: 1, widthPoints: 900, heightPoints: 100)
        ]
        #expect(try PDFPageSizeResolver.resolve(target: .largestPage(orientation: .reference), pages: largest)
            == PDFResolvedPageSize(widthPoints: 400, heightPoints: 300))
        #expect(try PDFPageSizeResolver.resolve(target: .specificPage(pageNumber: 2, orientation: .landscape), pages: samplePages)
            == PDFResolvedPageSize(widthPoints: 900, heightPoints: 500))
    }

    @Test("Orientation preserves reference and normalizes portrait and landscape")
    func orientationResolution() throws {
        let target = PDFPageSizeTarget.specificPage(pageNumber: 2, orientation: .reference)
        #expect(try PDFPageSizeResolver.resolve(target: target, pages: samplePages)
            == PDFResolvedPageSize(widthPoints: 900, heightPoints: 500))
        #expect(try PDFPageSizeResolver.resolve(
            target: .specificPage(pageNumber: 2, orientation: .portrait), pages: samplePages
        ) == PDFResolvedPageSize(widthPoints: 500, heightPoints: 900))
        #expect(try PDFPageSizeResolver.resolve(
            target: .specificPage(pageNumber: 1, orientation: .landscape), pages: samplePages
        ) == PDFResolvedPageSize(widthPoints: 792, heightPoints: 612))
    }

    @Test("Standard targets use catalog dimensions and reject unknown identifiers")
    func standardTargetResolution() throws {
        let a4Portrait = try PDFPageSizeResolver.resolve(
            target: .standard(paperID: "iso-a4", orientation: .portrait), pages: samplePages
        )
        #expect(abs(a4Portrait.widthPoints - (210 * 72 / 25.4)) < 1e-10)
        #expect(abs(a4Portrait.heightPoints - (297 * 72 / 25.4)) < 1e-10)
        #expect(try PDFPageSizeResolver.resolve(
            target: .standard(paperID: "us-letter", orientation: .landscape), pages: samplePages
        ) == PDFResolvedPageSize(widthPoints: 792, heightPoints: 612))
        #expect(normalizationError {
            _ = try PDFPageSizeResolver.resolve(target: .standard(paperID: "missing", orientation: .portrait), pages: samplePages)
        } == .invalidCatalogSelection("missing"))
        #expect(normalizationError {
            _ = try PDFPageSizeResolver.resolve(target: .standard(paperID: "iso-a4", orientation: .reference), pages: samplePages)
        } == .referenceOrientationNotSupportedForStandard)
    }

    @Test("Custom dimensions preserve input order and accept inclusive point bounds")
    func customDimensionBounds() throws {
        #expect(try PDFPageSizeResolver.resolve(target: .custom(width: 36, height: 14_400, unit: .points), pages: samplePages)
            == PDFResolvedPageSize(widthPoints: 36, heightPoints: 14_400))
        #expect(try PDFPageSizeResolver.resolve(target: .custom(width: 3, height: 2, unit: .inches), pages: samplePages)
            == PDFResolvedPageSize(widthPoints: 216, heightPoints: 144))
        #expect(normalizationError { _ = try PDFPageSizeResolver.resolve(target: .custom(width: 35.999, height: 72, unit: .points), pages: samplePages) }
            == .dimensionOutOfRange)
        #expect(normalizationError { _ = try PDFPageSizeResolver.resolve(target: .custom(width: 14_400.001, height: 72, unit: .points), pages: samplePages) }
            == .dimensionOutOfRange)
        #expect(normalizationError { _ = try PDFPageSizeResolver.resolve(target: .custom(width: .nan, height: 72, unit: .points), pages: samplePages) }
            == .nonFiniteValue)
        #expect(normalizationError { _ = try PDFPageSizeResolver.resolve(target: .custom(width: 0, height: 72, unit: .points), pages: samplePages) }
            == .nonPositiveValue)
    }

    @Test("Resolver rejects empty, missing, invalid, and duplicate page metrics")
    func invalidPageMetrics() throws {
        #expect(normalizationError { _ = try PDFPageSizeResolver.resolve(target: .firstPage(orientation: .reference), pages: []) }
            == .noPagesAvailable)
        #expect(normalizationError {
            _ = try PDFPageSizeResolver.resolve(
                target: .firstPage(orientation: .reference),
                pages: [PDFEffectivePageMetrics(pageNumber: 2, widthPoints: 10, heightPoints: 20)]
            )
        } == .invalidReferencePage(1))
        #expect(normalizationError {
            _ = try PDFPageSizeResolver.resolve(target: .specificPage(pageNumber: 0, orientation: .reference), pages: samplePages)
        } == .invalidReferencePage(0))
        #expect(normalizationError {
            _ = try PDFPageSizeResolver.resolve(target: .specificPage(pageNumber: 8, orientation: .reference), pages: samplePages)
        } == .invalidReferencePage(8))
        #expect(normalizationError {
            _ = try PDFPageSizeResolver.resolve(
                target: .firstPage(orientation: .reference),
                pages: [PDFEffectivePageMetrics(pageNumber: 1, widthPoints: .infinity, heightPoints: 20)]
            )
        } == .invalidPageMetrics(pageNumber: 1))
        #expect(normalizationError {
            _ = try PDFPageSizeResolver.resolve(
                target: .firstPage(orientation: .reference),
                pages: [
                    PDFEffectivePageMetrics(pageNumber: 1, widthPoints: 10, heightPoints: 20),
                    PDFEffectivePageMetrics(pageNumber: 1, widthPoints: 30, heightPoints: 40)
                ]
            )
        } == .invalidPageMetrics(pageNumber: 1))
        #expect(normalizationError {
            _ = try PDFPageSizeResolver.resolve(
                target: .largestPage(orientation: .reference),
                pages: [PDFEffectivePageMetrics(pageNumber: 1, widthPoints: 1e308, heightPoints: 1e308)]
            )
        } == .arithmeticOverflow)
    }

    private func normalizationError(_ operation: () throws -> Void) -> PDFPageNormalizationError? {
        do {
            try operation()
            Issue.record("Expected PDFPageNormalizationError, but the operation succeeded")
            return nil
        } catch let error as PDFPageNormalizationError {
            return error
        } catch {
            Issue.record("Expected PDFPageNormalizationError, received \(error)")
            return nil
        }
    }
}
