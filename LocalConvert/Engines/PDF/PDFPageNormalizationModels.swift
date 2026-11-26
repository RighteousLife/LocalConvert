import Foundation

enum PDFPageNormalizationError: Error, Equatable {
    case noPagesAvailable
    case invalidReferencePage(Int)
    case invalidCatalogSelection(String)
    case unsupportedUnitIdentifier(String)
    case nonFiniteValue
    case nonPositiveValue
    case arithmeticOverflow
    case dimensionOutOfRange
    case invalidPageMetrics(pageNumber: Int)
    case referenceOrientationNotSupportedForStandard
}

enum PDFMeasurementUnit: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case millimeters = "mm"
    case centimeters = "cm"
    case inches = "in"
    case points = "pt"

    var id: String { rawValue }

    init(identifier: String) throws {
        guard let unit = Self(rawValue: identifier) else {
            throw PDFPageNormalizationError.unsupportedUnitIdentifier(identifier)
        }
        self = unit
    }

    func points(from value: Double) throws -> Double {
        try Self.validatePositiveFinite(value)
        let points: Double
        switch self {
        case .millimeters: points = value * (72.0 / 25.4)
        case .centimeters: points = value * (720.0 / 25.4)
        case .inches: points = value * 72.0
        case .points: points = value
        }
        guard points.isFinite else { throw PDFPageNormalizationError.arithmeticOverflow }
        guard points > 0 else { throw PDFPageNormalizationError.nonPositiveValue }
        return points
    }

    func value(fromPoints points: Double) throws -> Double {
        try Self.validatePositiveFinite(points)
        let value: Double
        switch self {
        case .millimeters: value = points * (25.4 / 72.0)
        case .centimeters: value = points * (25.4 / 720.0)
        case .inches: value = points / 72.0
        case .points: value = points
        }
        guard value.isFinite else { throw PDFPageNormalizationError.arithmeticOverflow }
        guard value > 0 else { throw PDFPageNormalizationError.nonPositiveValue }
        return value
    }

    private static func validatePositiveFinite(_ value: Double) throws {
        guard value.isFinite else { throw PDFPageNormalizationError.nonFiniteValue }
        guard value > 0 else { throw PDFPageNormalizationError.nonPositiveValue }
    }
}

enum PDFPageSizeCatalog: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case isoA
    case isoB
    case jisB
    case northAmerican

    var id: String { rawValue }
}

enum PDFPageTargetOrientation: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case reference
    case portrait
    case landscape

    var id: String { rawValue }
}

struct PDFStandardPaperSize: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let catalog: PDFPageSizeCatalog
    let name: String
    let portraitWidth: Double
    let portraitHeight: Double
    let unit: PDFMeasurementUnit

    func dimensionsInPoints(orientation: PDFPageTargetOrientation) throws -> PDFResolvedPageSize {
        guard orientation != .reference else {
            throw PDFPageNormalizationError.referenceOrientationNotSupportedForStandard
        }
        let width = try unit.points(from: portraitWidth)
        let height = try unit.points(from: portraitHeight)
        return orientation == .portrait
            ? try PDFResolvedPageSize(widthPoints: width, heightPoints: height)
            : try PDFResolvedPageSize(widthPoints: height, heightPoints: width)
    }
}

enum PDFPageSizeCatalogData {
    static let all: [PDFStandardPaperSize] = [
        paper("iso-a0", .isoA, "A0", 841, 1189, .millimeters),
        paper("iso-a1", .isoA, "A1", 594, 841, .millimeters),
        paper("iso-a2", .isoA, "A2", 420, 594, .millimeters),
        paper("iso-a3", .isoA, "A3", 297, 420, .millimeters),
        paper("iso-a4", .isoA, "A4", 210, 297, .millimeters),
        paper("iso-a5", .isoA, "A5", 148, 210, .millimeters),
        paper("iso-a6", .isoA, "A6", 105, 148, .millimeters),

        paper("iso-b0", .isoB, "B0", 1000, 1414, .millimeters),
        paper("iso-b1", .isoB, "B1", 707, 1000, .millimeters),
        paper("iso-b2", .isoB, "B2", 500, 707, .millimeters),
        paper("iso-b3", .isoB, "B3", 353, 500, .millimeters),
        paper("iso-b4", .isoB, "B4", 250, 353, .millimeters),
        paper("iso-b5", .isoB, "B5", 176, 250, .millimeters),
        paper("iso-b6", .isoB, "B6", 125, 176, .millimeters),

        paper("jis-b0", .jisB, "B0", 1030, 1456, .millimeters),
        paper("jis-b1", .jisB, "B1", 728, 1030, .millimeters),
        paper("jis-b2", .jisB, "B2", 515, 728, .millimeters),
        paper("jis-b3", .jisB, "B3", 364, 515, .millimeters),
        paper("jis-b4", .jisB, "B4", 257, 364, .millimeters),
        paper("jis-b5", .jisB, "B5", 182, 257, .millimeters),
        paper("jis-b6", .jisB, "B6", 128, 182, .millimeters),

        paper("us-letter", .northAmerican, "Letter", 8.5, 11, .inches),
        paper("us-legal", .northAmerican, "Legal", 8.5, 14, .inches),
        paper("us-tabloid", .northAmerican, "Tabloid", 11, 17, .inches),
        paper("us-executive", .northAmerican, "Executive", 7.25, 10.5, .inches),
        paper("ansi-a", .northAmerican, "ANSI A", 8.5, 11, .inches),
        paper("ansi-b", .northAmerican, "ANSI B", 11, 17, .inches),
        paper("ansi-c", .northAmerican, "ANSI C", 17, 22, .inches),
        paper("ansi-d", .northAmerican, "ANSI D", 22, 34, .inches),
        paper("ansi-e", .northAmerican, "ANSI E", 34, 44, .inches)
    ]

    static func paperSize(id: String) -> PDFStandardPaperSize? {
        all.first { $0.id == id }
    }

    static func sizes(in catalog: PDFPageSizeCatalog) -> [PDFStandardPaperSize] {
        all.filter { $0.catalog == catalog }
    }

    private static func paper(
        _ id: String,
        _ catalog: PDFPageSizeCatalog,
        _ name: String,
        _ width: Double,
        _ height: Double,
        _ unit: PDFMeasurementUnit
    ) -> PDFStandardPaperSize {
        PDFStandardPaperSize(
            id: id,
            catalog: catalog,
            name: name,
            portraitWidth: width,
            portraitHeight: height,
            unit: unit
        )
    }
}

/// Effective visible page dimensions in points, already resolved by the caller.
/// This value does not inspect PDF boxes, rotation, or `/UserUnit`.
struct PDFEffectivePageMetrics: Codable, Equatable, Hashable, Sendable {
    let pageNumber: Int
    let widthPoints: Double
    let heightPoints: Double

    init(pageNumber: Int, widthPoints: Double, heightPoints: Double) {
        self.pageNumber = pageNumber
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
    }
}

enum PDFPageSizeTarget: Codable, Equatable, Sendable {
    case firstPage(orientation: PDFPageTargetOrientation)
    case specificPage(pageNumber: Int, orientation: PDFPageTargetOrientation)
    case largestPage(orientation: PDFPageTargetOrientation)
    case standard(paperID: String, orientation: PDFPageTargetOrientation)
    case custom(width: Double, height: Double, unit: PDFMeasurementUnit)
}

struct PDFResolvedPageSize: Codable, Equatable, Hashable, Sendable {
    let widthPoints: Double
    let heightPoints: Double

    init(widthPoints: Double, heightPoints: Double) throws {
        guard widthPoints.isFinite, heightPoints.isFinite else {
            throw PDFPageNormalizationError.nonFiniteValue
        }
        guard widthPoints > 0, heightPoints > 0 else {
            throw PDFPageNormalizationError.nonPositiveValue
        }
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
    }
}

enum PDFPageSizeResolver {
    static let minimumCustomDimensionPoints = 36.0
    static let maximumCustomDimensionPoints = 14_400.0

    static func resolve(
        target: PDFPageSizeTarget,
        pages: [PDFEffectivePageMetrics]
    ) throws -> PDFResolvedPageSize {
        try validatePages(pages)

        switch target {
        case .firstPage(let orientation):
            guard let first = pages.first(where: { $0.pageNumber == 1 }) else {
                throw PDFPageNormalizationError.invalidReferencePage(1)
            }
            return try orient(width: first.widthPoints, height: first.heightPoints, as: orientation)

        case .specificPage(let pageNumber, let orientation):
            guard pageNumber > 0,
                  let page = pages.first(where: { $0.pageNumber == pageNumber }) else {
                throw PDFPageNormalizationError.invalidReferencePage(pageNumber)
            }
            return try orient(width: page.widthPoints, height: page.heightPoints, as: orientation)

        case .largestPage(let orientation):
            guard let largest = try largestPage(in: pages) else {
                throw PDFPageNormalizationError.noPagesAvailable
            }
            return try orient(width: largest.widthPoints, height: largest.heightPoints, as: orientation)

        case .standard(let paperID, let orientation):
            guard let paper = PDFPageSizeCatalogData.paperSize(id: paperID) else {
                throw PDFPageNormalizationError.invalidCatalogSelection(paperID)
            }
            return try paper.dimensionsInPoints(orientation: orientation)

        case .custom(let width, let height, let unit):
            let widthPoints = try unit.points(from: width)
            let heightPoints = try unit.points(from: height)
            guard (minimumCustomDimensionPoints...maximumCustomDimensionPoints).contains(widthPoints),
                  (minimumCustomDimensionPoints...maximumCustomDimensionPoints).contains(heightPoints) else {
                throw PDFPageNormalizationError.dimensionOutOfRange
            }
            return try PDFResolvedPageSize(widthPoints: widthPoints, heightPoints: heightPoints)
        }
    }

    private static func validatePages(_ pages: [PDFEffectivePageMetrics]) throws {
        guard !pages.isEmpty else { throw PDFPageNormalizationError.noPagesAvailable }
        var seenPageNumbers = Set<Int>()
        for page in pages {
            guard page.pageNumber > 0,
                  page.widthPoints.isFinite,
                  page.heightPoints.isFinite,
                  page.widthPoints > 0,
                  page.heightPoints > 0,
                  seenPageNumbers.insert(page.pageNumber).inserted else {
                throw PDFPageNormalizationError.invalidPageMetrics(pageNumber: page.pageNumber)
            }
        }
    }

    private static func largestPage(in pages: [PDFEffectivePageMetrics]) throws -> PDFEffectivePageMetrics? {
        var winner: PDFEffectivePageMetrics?
        var largestArea = -Double.infinity
        for page in pages {
            let area = page.widthPoints * page.heightPoints
            guard area.isFinite else { throw PDFPageNormalizationError.arithmeticOverflow }
            if area > largestArea || (area == largestArea && page.pageNumber < (winner?.pageNumber ?? Int.max)) {
                largestArea = area
                winner = page
            }
        }
        return winner
    }

    private static func orient(
        width: Double,
        height: Double,
        as orientation: PDFPageTargetOrientation
    ) throws -> PDFResolvedPageSize {
        switch orientation {
        case .reference:
            return try PDFResolvedPageSize(widthPoints: width, heightPoints: height)
        case .portrait:
            return try PDFResolvedPageSize(widthPoints: min(width, height), heightPoints: max(width, height))
        case .landscape:
            return try PDFResolvedPageSize(widthPoints: max(width, height), heightPoints: min(width, height))
        }
    }
}
