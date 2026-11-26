import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import LocalConvert

@Suite("PDF Page Normalization Geometry and Service", .serialized)
struct PDFPageNormalizationServiceTests {
    private struct PageSpec {
        var mediaBox: String? = "[0 0 100 60]"
        var cropBox: String? = nil
        var rotation: Int? = nil
        var userUnit: String? = nil
        var contents: String = ""
    }

    private struct PixelPlane {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        func centroid(_ color: MarkerColor) -> CGPoint? {
            var sumX = 0.0
            var sumY = 0.0
            var count = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let red = rgba[offset]
                    let green = rgba[offset + 1]
                    let blue = rgba[offset + 2]
                    let matches: Bool
                    switch color {
                    case .red: matches = red > 180 && green < 100 && blue < 100
                    case .green: matches = green > 150 && red < 100 && blue < 100
                    case .blue: matches = blue > 150 && red < 100 && green < 100
                    case .yellow: matches = red > 180 && green > 150 && blue < 100
                    }
                    if matches {
                        sumX += Double(x) + 0.5
                        sumY += Double(y) + 0.5
                        count += 1
                    }
                }
            }
            guard count > 0 else { return nil }
            return CGPoint(x: sumX / count / Double(width), y: sumY / count / Double(height))
        }

        func coloredPixelCount(_ color: MarkerColor) -> Int {
            var count = 0
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let red = rgba[offset]
                    let green = rgba[offset + 1]
                    let blue = rgba[offset + 2]
                    switch color {
                    case .red where red > 180 && green < 100 && blue < 100: count += 1
                    case .green where green > 150 && red < 100 && blue < 100: count += 1
                    case .blue where blue > 150 && red < 100 && green < 100: count += 1
                    case .yellow where red > 180 && green > 150 && blue < 100: count += 1
                    default: break
                    }
                }
            }
            return count
        }
    }

    private enum MarkerColor {
        case red
        case green
        case blue
        case yellow
    }

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFNormStage2_\(name)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePDF(
        _ pages: [PageSpec],
        inheritedMediaBox: String? = nil,
        inheritedCropBox: String? = nil,
        inheritedRotation: Int? = nil,
        outline: (pageIndex: Int, point: CGPoint, title: String)? = nil,
        metadata: [String: String] = [:]
    ) -> Data {
        var objects: [Data] = []
        objects.append(Data())
        let kids = pages.indices.map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        var pageTree = "<< /Type /Pages /Kids [\(kids)] /Count \(pages.count)"
        if let inheritedMediaBox { pageTree += " /MediaBox \(inheritedMediaBox)" }
        if let inheritedCropBox { pageTree += " /CropBox \(inheritedCropBox)" }
        if let inheritedRotation { pageTree += " /Rotate \(inheritedRotation)" }
        pageTree += " >>"
        objects.append(Data(pageTree.utf8))

        for (index, page) in pages.enumerated() {
            let contentObject = 4 + index * 2
            var entries = "<< /Type /Page /Parent 2 0 R /Resources << >> /Contents \(contentObject) 0 R"
            if let mediaBox = page.mediaBox { entries += " /MediaBox \(mediaBox)" }
            if let cropBox = page.cropBox { entries += " /CropBox \(cropBox)" }
            if let rotation = page.rotation { entries += " /Rotate \(rotation)" }
            if let userUnit = page.userUnit { entries += " /UserUnit \(userUnit)" }
            entries += " >>"
            objects.append(Data(entries.utf8))
            let stream = Data(page.contents.utf8)
            var streamObject = Data("<< /Length \(stream.count) >>\nstream\n".utf8)
            streamObject.append(stream)
            streamObject.append(Data("\nendstream".utf8))
            objects.append(streamObject)
        }

        var outlineRootObject: Int?
        if let outline, pages.indices.contains(outline.pageIndex) {
            let rootObject = objects.count + 1
            let itemObject = rootObject + 1
            let pageObject = 3 + outline.pageIndex * 2
            objects.append(Data("<< /Type /Outlines /First \(itemObject) 0 R /Last \(itemObject) 0 R /Count 1 >>".utf8))
            objects.append(Data(
                "<< /Title (\(pdfLiteral(outline.title))) /Parent \(rootObject) 0 R /Dest [\(pageObject) 0 R /XYZ \(outline.point.x) \(outline.point.y) null] >>".utf8
            ))
            outlineRootObject = rootObject
        }

        var infoObject: Int?
        if !metadata.isEmpty {
            let values = metadata.keys.sorted().map { key in
                "/\(key) (\(pdfLiteral(metadata[key] ?? "")))"
            }.joined(separator: " ")
            infoObject = objects.count + 1
            objects.append(Data("<< \(values) >>".utf8))
        }

        let outlinesEntry = outlineRootObject.map { " /Outlines \($0) 0 R" } ?? ""
        objects[0] = Data("<< /Type /Catalog /Pages 2 0 R\(outlinesEntry) >>".utf8)

        var pdf = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n".utf8))
            pdf.append(object)
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xrefOffset = pdf.count
        pdf.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        let infoEntry = infoObject.map { " /Info \($0) 0 R" } ?? ""
        pdf.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R\(infoEntry) >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return pdf
    }

    private func pdfLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    private func cornerMarkers(box: CGRect, centerColor: String? = nil) -> String {
        let marker = min(8, min(box.width, box.height) * 0.12)
        let inset = marker * 0.7
        var commands = ""
        commands += "1 0 0 rg \(box.minX + inset) \(box.maxY - inset - marker) \(marker) \(marker) re f\n"
        commands += "0 1 0 rg \(box.maxX - inset - marker) \(box.maxY - inset - marker) \(marker) \(marker) re f\n"
        commands += "0 0 1 rg \(box.minX + inset) \(box.minY + inset) \(marker) \(marker) re f\n"
        commands += "1 1 0 rg \(box.maxX - inset - marker) \(box.minY + inset) \(marker) \(marker) re f\n"
        if let centerColor {
            commands += "\(centerColor) \(box.midX - marker) \(box.midY - marker) \(marker * 2) \(marker * 2) re f\n"
        }
        return commands
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func openDocument(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw PDFPageNormalizationServiceError.outputValidationFailed("Test fixture did not open as a PDF.")
        }
        return document
    }

    private func render(_ page: PDFPage) throws -> PixelPlane {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(360 / bounds.width, 360 / bounds.height)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        let rowBytes = width * 4
        var pixels = [UInt8](repeating: 255, count: height * rowBytes)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: rowBytes,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard success else {
            throw PDFPageNormalizationServiceError.outputValidationFailed("Test bitmap context could not be created.")
        }
        return PixelPlane(width: width, height: height, rgba: pixels)
    }

    private func normalizedPosition(_ color: MarkerColor, on plane: PixelPlane) throws -> CGPoint {
        try #require(plane.centroid(color))
    }

    private func assertBoxes(_ page: PDFPage, width: CGFloat, height: CGFloat) {
        let expected = CGRect(x: 0, y: 0, width: width, height: height)
        for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            let actual = page.bounds(for: box)
            #expect(abs(actual.minX - expected.minX) < 0.02)
            #expect(abs(actual.minY - expected.minY) < 0.02)
            #expect(abs(actual.width - expected.width) < 0.02)
            #expect(abs(actual.height - expected.height) < 0.02)
        }
    }

    private func run(_ source: URL, target: PDFPageSizeTarget, output: URL) async throws -> PDFPageOperationResult {
        try await PDFPageNormalizationService.normalize(sourceURL: source, target: target, outputURL: output)
    }

    @Test("Source pages remain in their original order and every output box is normalized")
    func preservesSourceOrderAndNormalizesBoxes() async throws {
        let directory = try makeTempDir("order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf")
        let output = directory.appendingPathComponent("normalized.pdf")
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pages = ["1 0 0 rg", "0 1 0 rg", "0 0 1 rg"].map { color in
            PageSpec(mediaBox: "[0 0 100 100]", contents: "\(color) 42 42 16 16 re f")
        }
        try write(makePDF(pages), to: input)

        let result = try await run(input, target: .firstPage(orientation: .reference), output: output)
        let document = try openDocument(output)
        #expect(result.pageCount == 3)
        #expect(document.pageCount == 3)
        for index in 0..<document.pageCount {
            assertBoxes(try #require(document.page(at: index)), width: box.width, height: box.height)
        }
        let firstPlane = try render(#require(document.page(at: 0)))
        let secondPlane = try render(#require(document.page(at: 1)))
        let thirdPlane = try render(#require(document.page(at: 2)))
        #expect(firstPlane.coloredPixelCount(.red) > 0)
        #expect(firstPlane.coloredPixelCount(.green) == 0)
        #expect(secondPlane.coloredPixelCount(.green) > 0)
        #expect(secondPlane.coloredPixelCount(.red) == 0)
        #expect(thirdPlane.coloredPixelCount(.blue) > 0)
        #expect(thirdPlane.coloredPixelCount(.red) == 0)
    }

    @Test("Effective geometry intersects non-zero CropBox and MediaBox origins")
    func intersectsOffsetPageBoxes() async throws {
        let directory = try makeTempDir("intersection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("offset.pdf")
        let output = directory.appendingPathComponent("normalized.pdf")
        let media = CGRect(x: -20, y: -10, width: 300, height: 200)
        let crop = CGRect(x: -40, y: 20, width: 200, height: 220)
        let intersection = media.intersection(crop)
        let spec = PageSpec(
            mediaBox: "[-20 -10 280 190]",
            cropBox: "[-40 20 160 240]",
            contents: cornerMarkers(box: intersection)
        )
        try write(makePDF([spec]), to: input)

        _ = try await run(input, target: .firstPage(orientation: .reference), output: output)
        let page = try #require(openDocument(output).page(at: 0))
        #expect(intersection == CGRect(x: -20, y: 20, width: 180, height: 170))
        assertBoxes(page, width: intersection.width, height: intersection.height)
        let plane = try render(page)
        #expect(plane.centroid(.red) != nil)
        #expect(plane.centroid(.green) != nil)
        #expect(plane.centroid(.blue) != nil)
        #expect(plane.centroid(.yellow) != nil)
    }

    @Test("Missing and equal CropBoxes resolve to the MediaBox")
    func cropBoxDefaultsAndEqualsMedia() async throws {
        let directory = try makeTempDir("crop-default")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("boxes.pdf")
        let outputA = directory.appendingPathComponent("missing.pdf")
        let outputB = directory.appendingPathComponent("equal.pdf")
        let content = cornerMarkers(box: CGRect(x: 0, y: 0, width: 100, height: 60))
        try write(makePDF([
            PageSpec(mediaBox: "[0 0 100 60]", contents: content),
            PageSpec(mediaBox: "[0 0 100 60]", cropBox: "[0 0 100 60]", contents: content)
        ]), to: input)

        _ = try await run(input, target: .specificPage(pageNumber: 1, orientation: .reference), output: outputA)
        _ = try await run(input, target: .specificPage(pageNumber: 2, orientation: .reference), output: outputB)
        assertBoxes(try #require(openDocument(outputA).page(at: 0)), width: 100, height: 60)
        assertBoxes(try #require(openDocument(outputB).page(at: 0)), width: 100, height: 60)
    }

    @Test("Inherited MediaBox, CropBox, and rotation are resolved from the page tree")
    func resolvesInheritedPageAttributes() async throws {
        let directory = try makeTempDir("inherited")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("inherited.pdf")
        let output = directory.appendingPathComponent("normalized.pdf")
        let media = CGRect(x: 0, y: 0, width: 120, height: 70)
        let content = cornerMarkers(box: media)
        try write(
            makePDF(
                [PageSpec(mediaBox: nil, contents: content)],
                inheritedMediaBox: "[0 0 120 70]",
                inheritedCropBox: "[0 0 120 70]",
                inheritedRotation: 90
            ),
            to: input
        )

        _ = try await run(input, target: .firstPage(orientation: .reference), output: output)
        let page = try #require(openDocument(output).page(at: 0))
        assertBoxes(page, width: 70, height: 120)
        let plane = try render(page)
        #expect(plane.centroid(.red) != nil)
        #expect(plane.centroid(.green) != nil)
        #expect(plane.centroid(.blue) != nil)
        #expect(plane.centroid(.yellow) != nil)
    }

    @Test("All right-angle rotations produce upright source-order pages and rotate corner markers correctly")
    func rightAngleRotationsPreserveVisibleOrder() async throws {
        let directory = try makeTempDir("rotations")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("rotated.pdf")
        let pageBox = CGRect(x: 0, y: 0, width: 120, height: 70)
        let pages = [0, 90, 180, 270].map { angle in
            PageSpec(
                mediaBox: "[0 0 120 70]",
                rotation: angle,
                contents: cornerMarkers(box: pageBox)
            )
        }
        try write(makePDF(pages), to: input)

        for angle in [0, 90, 180, 270] {
            let output = directory.appendingPathComponent("rotated-\(angle).pdf")
            _ = try await run(input, target: .specificPage(pageNumber: angle / 90 + 1, orientation: .reference), output: output)
            let document = try openDocument(output)
            let page = try #require(document.page(at: 0))
            let rotated = angle == 90 || angle == 270
            let expectedSize = rotated ? CGSize(width: 70, height: 120) : CGSize(width: 120, height: 70)
            assertBoxes(page, width: expectedSize.width, height: expectedSize.height)
            let plane = try render(try #require(document.page(at: angle / 90)))
            let red = try normalizedPosition(.red, on: plane)
            let expectedRed: CGPoint
            switch angle {
            case 90: expectedRed = CGPoint(x: 0.94, y: 0.06)
            case 180: expectedRed = CGPoint(x: 0.94, y: 0.94)
            case 270: expectedRed = CGPoint(x: 0.06, y: 0.94)
            default: expectedRed = CGPoint(x: 0.06, y: 0.06)
            }
            #expect(abs(red.x - expectedRed.x) < 0.08, "angle \(angle) normalized red marker: \(red)")
            #expect(abs(red.y - expectedRed.y) < 0.08, "angle \(angle) normalized red marker: \(red)")
            #expect(plane.centroid(.green) != nil)
            #expect(plane.centroid(.blue) != nil)
            #expect(plane.centroid(.yellow) != nil)
        }
    }

    @Test("Non-default UserUnit is included in resolved physical dimensions and drawing scale")
    func userUnitPhysicalGeometryAndDrawing() async throws {
        let directory = try makeTempDir("userunit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("units.pdf")
        let content = "0 0 1 rg 10 20 20 30 re f"
        try write(makePDF([
            PageSpec(mediaBox: "[0 0 100 200]", contents: content),
            PageSpec(mediaBox: "[0 0 100 200]", userUnit: "1", contents: content),
            PageSpec(mediaBox: "[0 0 100 200]", userUnit: "2", contents: content)
        ]), to: input)

        for (index, expectedDimension) in [(0, 100.0), (1, 100.0), (2, 200.0)] {
            let output = directory.appendingPathComponent("unit-\(index).pdf")
            _ = try await run(input, target: .specificPage(pageNumber: index + 1, orientation: .reference), output: output)
            let page = try #require(openDocument(output).page(at: 0))
            #expect(abs(page.bounds(for: .mediaBox).width - expectedDimension) < 0.02)
            let plane = try render(page)
            let blue = try normalizedPosition(.blue, on: plane)
            #expect(abs(blue.x - 0.20) < 0.04)
            #expect(abs(blue.y - 0.825) < 0.04)
        }
    }

    @Test("PDFKit ignores UserUnit in bounds and draw; service compensates using fixture-verified scaling")
    func userUnitPDFKitBehaviorFixture() throws {
        let directory = try makeTempDir("userunit-api")
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, value) in [("absent", nil as String?), ("one", "1"), ("two", "2")] {
            let url = directory.appendingPathComponent("\(name).pdf")
            try write(makePDF([PageSpec(mediaBox: "[0 0 100 200]", userUnit: value, contents: "0 0 1 rg 10 20 20 30 re f")]), to: url)
            let page = try #require(openDocument(url).page(at: 0))
            #expect(page.bounds(for: .mediaBox).width == 100)
            #expect(page.bounds(for: .mediaBox).height == 200)
            let plane = try render(page)
            #expect(plane.coloredPixelCount(.blue) > 0)
            #expect(plane.coloredPixelCount(.blue) > 0)
        }
    }

    @Test("Malformed boxes, rotation, and UserUnit fail before output is created")
    func rejectsMalformedGeometry() async throws {
        let directory = try makeTempDir("malformed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, PageSpec)] = [
            ("zero-media", PageSpec(mediaBox: "[0 0 0 100]")),
            ("empty-intersection", PageSpec(mediaBox: "[0 0 100 100]", cropBox: "[110 110 120 120]")),
            ("bad-rotation", PageSpec(mediaBox: "[0 0 100 100]", rotation: 45)),
            ("zero-userunit", PageSpec(mediaBox: "[0 0 100 100]", userUnit: "0")),
            ("typed-userunit", PageSpec(mediaBox: "[0 0 100 100]", userUnit: "/WrongType"))
        ]
        for (name, page) in cases {
            let input = directory.appendingPathComponent("\(name).pdf")
            let output = directory.appendingPathComponent("\(name)-out.pdf")
            try write(makePDF([page]), to: input)
            await #expect(throws: Error.self) {
                try await run(input, target: .firstPage(orientation: .reference), output: output)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test("First, specific, largest, standard, and custom targets resolve through Stage 1")
    func resolvesAllStageOneTargets() async throws {
        let directory = try makeTempDir("targets")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("targets.pdf")
        let pages = [
            PageSpec(mediaBox: "[0 0 80 100]", contents: "1 0 0 rg 30 45 20 10 re f"),
            PageSpec(mediaBox: "[0 0 160 60]", contents: "0 1 0 rg 70 25 20 10 re f"),
            PageSpec(mediaBox: "[0 0 120 90]", contents: "0 0 1 rg 50 40 20 10 re f")
        ]
        try write(makePDF(pages), to: input)
        let requests: [(String, PDFPageSizeTarget, CGSize)] = [
            ("first", .firstPage(orientation: .reference), CGSize(width: 80, height: 100)),
            ("specific", .specificPage(pageNumber: 2, orientation: .portrait), CGSize(width: 60, height: 160)),
            ("largest", .largestPage(orientation: .reference), CGSize(width: 120, height: 90)),
            ("standard", .standard(paperID: "us-letter", orientation: .landscape), CGSize(width: 792, height: 612)),
            ("custom", .custom(width: 10, height: 8, unit: .inches), CGSize(width: 720, height: 576))
        ]
        for (name, target, expected) in requests {
            let output = directory.appendingPathComponent("\(name).pdf")
            _ = try await run(input, target: target, output: output)
            let document = try openDocument(output)
            #expect(document.pageCount == 3)
            assertBoxes(try #require(document.page(at: 0)), width: expected.width, height: expected.height)
        }
    }

    @Test("Contain layout centers content on white canvas without cropping or stretching")
    func fitCenterWhiteCanvasAndAspectRatio() async throws {
        let directory = try makeTempDir("fit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("wide.pdf")
        let output = directory.appendingPathComponent("portrait.pdf")
        let sourceBox = CGRect(x: 0, y: 0, width: 200, height: 80)
        try write(makePDF([PageSpec(mediaBox: "[0 0 200 80]", contents: cornerMarkers(box: sourceBox))]), to: input)

        _ = try await run(input, target: .custom(width: 100, height: 200, unit: .points), output: output)
        let page = try #require(openDocument(output).page(at: 0))
        let plane = try render(page)
        let red = try normalizedPosition(.red, on: plane)
        let green = try normalizedPosition(.green, on: plane)
        #expect(abs(red.x - 0.08) < 0.05)
        #expect(abs(green.x - 0.92) < 0.05)
        #expect(abs(red.y - green.y) < 0.03)
        #expect(plane.rgba[4] > 220 && plane.rgba[5] > 220 && plane.rgba[6] > 220)
    }

    @Test("Document metadata and bookmark page destinations survive with points transformed")
    func preservesMetadataAndTransformsBookmarkPoints() async throws {
        let directory = try makeTempDir("metadata-bookmarks")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source-with-outline.pdf")
        let output = directory.appendingPathComponent("normalized.pdf")
        try write(makePDF(
            [PageSpec(mediaBox: "[0 0 100 200]", rotation: 90, contents: "0 0 1 rg 40 90 20 20 re f")],
            outline: (0, CGPoint(x: 25, y: 50), "Transformed point"),
            metadata: ["Title": "Normalization fixture", "Author": "LocalConvert tests"]
        ), to: input)
        let reopenedSource = try #require(PDFDocument(url: input))
        #expect(reopenedSource.outlineRoot?.numberOfChildren == 1)

        let result = try await run(input, target: .firstPage(orientation: .reference), output: output)
        let normalized = try openDocument(output)
        let title = normalized.documentAttributes?.first { String(describing: $0.key) == "Title" }?.value as? String
        #expect(title == "Normalization fixture")
        let outputBookmark = try #require(normalized.outlineRoot?.child(at: 0))
        let destination = try #require(outputBookmark.destination)
        if let targetPage = destination.page {
            #expect(normalized.index(for: targetPage) == 0)
        } else {
            Issue.record("Bookmark destination has no output page")
        }
        #expect(abs(destination.point.x - 50) < 0.1)
        #expect(abs(destination.point.y - 75) < 0.1)
        #expect(result.preservedOutlineCount == 1)
        #expect(result.omittedOutlineCount == 0)
    }

    @Test("Bookmark destinations outside the visible source box use the output center with a warning")
    func outOfBoundsBookmarkUsesCenterAndWarns() async throws {
        let directory = try makeTempDir("bookmark-fallback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("outlined.pdf")
        let output = directory.appendingPathComponent("normalized.pdf")
        try write(makePDF(
            [PageSpec(mediaBox: "[0 0 100 100]", cropBox: "[20 20 80 80]")],
            outline: (0, CGPoint(x: 10, y: 10), "Out of bounds")
        ), to: input)
        let sourceDocument = try openDocument(input)
        #expect(sourceDocument.outlineRoot?.child(at: 0)?.destination?.page != nil)

        let result = try await run(input, target: .custom(width: 100, height: 100, unit: .points), output: output)
        #expect(result.preservedOutlineCount == 1)
        let normalized = try openDocument(output)
        let outputDestination = try #require(normalized.outlineRoot?.child(at: 0)?.destination)
        #expect(abs(outputDestination.point.x - 50) < 0.1)
        #expect(abs(outputDestination.point.y - 50) < 0.1)
        #expect(result.warnings.contains { $0.contains("outside the visible source page") })
    }

    @Test("Visible annotations are rendered into output pages")
    func rendersVisibleAnnotations() async throws {
        let directory = try makeTempDir("annotations")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bare = directory.appendingPathComponent("bare.pdf")
        let input = directory.appendingPathComponent("annotated.pdf")
        let output = directory.appendingPathComponent("normalized.pdf")
        try write(makePDF([PageSpec(mediaBox: "[0 0 100 100]")]), to: bare)
        let source = try openDocument(bare)
        let page = try #require(source.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 30), forType: .square, withProperties: nil)
        annotation.color = .red
        annotation.interiorColor = .red
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        page.addAnnotation(annotation)
        #expect(source.write(to: input))

        _ = try await run(input, target: .firstPage(orientation: .reference), output: output)
        let outputPage = try #require(openDocument(output).page(at: 0))
        let plane = try render(outputPage)
        #expect(plane.coloredPixelCount(.red) > 0)
    }

    @Test("A generated embedded-image page remains visibly rendered")
    func rendersEmbeddedImage() async throws {
        let directory = try makeTempDir("image")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("image-page.pdf")
        let output = directory.appendingPathComponent("normalized.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        guard let context = CGContext(input as CFURL, mediaBox: &mediaBox, nil) else {
            Issue.record("Could not create image fixture PDF")
            return
        }
        let pixelData: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255]
        let provider = CGDataProvider(data: Data(pixelData) as CFData)!
        let image = CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 20, y: 20, width: 60, height: 60))
        context.endPDFPage()
        context.closePDF()

        _ = try await run(input, target: .firstPage(orientation: .reference), output: output)
        let plane = try render(#require(openDocument(output).page(at: 0)))
        #expect(plane.coloredPixelCount(.red) > 0)
        #expect(plane.coloredPixelCount(.green) > 0)
        #expect(plane.coloredPixelCount(.blue) > 0)
    }

    @Test("Source remains unchanged and existing output is never overwritten")
    func sourceImmutabilityAndCollision() async throws {
        let directory = try makeTempDir("safety")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        let output = directory.appendingPathComponent("output.pdf")
        try write(makePDF([PageSpec(contents: "0 0 1 rg 40 20 20 20 re f")]), to: source)
        let sourceHash = try Data(contentsOf: source)

        _ = try await PDFPageNormalizationService.normalize(sourceURL: source, target: .firstPage(orientation: .reference), outputURL: output)
        #expect(try Data(contentsOf: source) == sourceHash)

        let existingData = Data("keep-existing-output".utf8)
        try existingData.write(to: output)
        await #expect(throws: PDFPageNormalizationServiceError.outputAlreadyExists) {
            try await run(source, target: .firstPage(orientation: .reference), output: output)
        }
        #expect(try Data(contentsOf: output) == existingData)

        await #expect(throws: PDFPageNormalizationServiceError.sourceAndOutputAreSameFile) {
            try await run(source, target: .firstPage(orientation: .reference), output: source)
        }
    }

    @Test("Cancellation during sequential processing leaves no partial output or staging file")
    func cancellationCleansStagingFile() async throws {
        let directory = try makeTempDir("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("many-pages.pdf")
        let output = directory.appendingPathComponent("cancelled.pdf")
        let pages = (0..<12).map { _ in PageSpec(contents: "0 0 1 rg 40 20 20 20 re f") }
        try write(makePDF(pages), to: source)

        let operation = Task {
            try await PDFPageNormalizationService.normalize(
                sourceURL: source,
                target: .firstPage(orientation: .reference),
                outputURL: output,
                progress: { progress in
                    if (progress.fractionCompleted ?? 0) > 0.1 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }
        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let remainingPDFs = (try FileManager.default.contentsOfDirectory(atPath: directory.path))
            .filter { $0.hasSuffix(".stage2.pdf") }
        #expect(remainingPDFs.isEmpty)
    }

    @Test("PDF Toolbox dispatch uses the original source, normalized suffix, and collision-safe output")
    func toolboxEngineDispatchesNormalizationWithoutOverwriting() async throws {
        let directory = try makeTempDir("engine-dispatch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.pdf")
        let expectedOutput = directory.appendingPathComponent("source_normalized.pdf")
        let sourceData = makePDF([
            PageSpec(mediaBox: "[0 0 120 80]", contents: "0 0 1 rg 10 10 30 30 re f"),
            PageSpec(mediaBox: "[0 0 80 120]", contents: "1 0 0 rg 10 10 20 40 re f")
        ])
        try write(sourceData, to: input)
        let originalBytes = try Data(contentsOf: input)
        let existingBytes = Data("existing output must survive".utf8)
        try existingBytes.write(to: expectedOutput)

        let request = PDFPageNormalizationRequest(target: .standard(paperID: "iso-a4", orientation: .portrait))
        let options = ConversionOptions(customOptions: [
            "pdf_operation": "normalizePageSizes",
            PDFPageNormalizationRequest.optionKey: try request.encodedOption()
        ])
        let result = try await PDFToolboxEngine().convert(
            inputs: [input],
            to: .pdf,
            outputDirectory: directory,
            options: options,
            progress: { _ in }
        )

        #expect(result.outputURL != expectedOutput)
        #expect(result.outputURL.lastPathComponent.hasPrefix("source_normalized"))
        #expect(FileManager.default.fileExists(atPath: result.outputURL.path))
        #expect(try Data(contentsOf: expectedOutput) == existingBytes)
        #expect(try Data(contentsOf: input) == originalBytes)
        let normalized = try #require(PDFDocument(url: result.outputURL))
        #expect(normalized.pageCount == 2)
        #expect(normalized.page(at: 0)?.bounds(for: .mediaBox).width == normalized.page(at: 1)?.bounds(for: .mediaBox).width)
        #expect(normalized.page(at: 0)?.bounds(for: .mediaBox).height == normalized.page(at: 1)?.bounds(for: .mediaBox).height)
    }

    @Test("Target-size preview uses the same effective geometry for specific and largest pages")
    func targetSizePreviewUsesNormalizationResolver() throws {
        let directory = try makeTempDir("preview-resolver")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("mixed-sizes.pdf")
        try write(makePDF([
            PageSpec(mediaBox: "[0 0 80 120]"),
            PageSpec(mediaBox: "[0 0 140 60]")
        ]), to: source)

        let specific = try PDFPageNormalizationService.resolveTargetSize(
            sourceURL: source,
            target: .specificPage(pageNumber: 2, orientation: .landscape)
        )
        let largest = try PDFPageNormalizationService.resolveTargetSize(
            sourceURL: source,
            target: .largestPage(orientation: .reference)
        )
        let expected = try PDFResolvedPageSize(widthPoints: 140, heightPoints: 60)
        let expectedLargest = try PDFResolvedPageSize(widthPoints: 80, heightPoints: 120)

        #expect(specific == expected)
        #expect(largest == expectedLargest)
    }
}
