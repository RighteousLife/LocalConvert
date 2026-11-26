import Foundation
import AppKit
import CoreGraphics

// MARK: - Before / After Comparison Model & Service

struct ImageComparisonSnapshot: Sendable {
    let beforeImage: NSImage
    let afterImage: NSImage
    let beforeFormat: String
    let afterFormat: String
    let telemetry: ImageProcessingTelemetry
    let qualityReport: ImageComparisonQualityReport?
}

enum ImageComparisonService {

    /// Generates an authentic, non-destructive Before/After comparison by running the actual Image Toolbox
    /// pipeline in memory (using actual encoded output bytes for the "After" view) plus objective quality metrics.
    static func buildComparison(
        sourceURL: URL,
        outputFormat: FileFormat,
        config: ImageToolboxConfig
    ) async throws -> ImageComparisonSnapshot {
        let decodedBefore = try await ImageProcessingService.decodeInputImage(url: sourceURL)
        let beforeNS = NSImage(
            cgImage: decodedBefore.cgImage,
            size: NSSize(width: decodedBefore.cgImage.width, height: decodedBefore.cgImage.height)
        )

        let afterResult = try await ImageProcessingService.processInMemory(
            url: sourceURL,
            outputFormat: outputFormat,
            config: config,
            previewMaxDimension: nil
        )
        let afterNS = NSImage(
            cgImage: afterResult.previewCGImage,
            size: NSSize(width: afterResult.previewCGImage.width, height: afterResult.previewCGImage.height)
        )

        let qualityReport = ImageQualityMetricsService.analyze(
            reference: decodedBefore.cgImage,
            candidate: afterResult.previewCGImage
        )

        return ImageComparisonSnapshot(
            beforeImage: beforeNS,
            afterImage: afterNS,
            beforeFormat: decodedBefore.format?.shortExtensionLabel ?? sourceURL.pathExtension.uppercased(),
            afterFormat: outputFormat.shortExtensionLabel,
            telemetry: afterResult.telemetry,
            qualityReport: qualityReport
        )
    }
}
