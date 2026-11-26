import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Categorized Image Metadata, DPI & Non-Destructive Sanitizer Service

enum ImageMetadataCategory: String, CaseIterable, Identifiable, Sendable {
    case gps = "GPS Location"
    case exif = "EXIF Camera"
    case iptc = "IPTC Rights & Caption"
    case tiff = "TIFF / Device"
    case xmp = "XMP"
    case technical = "Technical & DPI"

    var id: String { rawValue }
}

struct ImageMetadataTagEntry: Identifiable, Sendable, Equatable {
    let id: String
    let category: ImageMetadataCategory
    let key: String
    let value: String
}

struct ImageDetailedMetadataSnapshot: Sendable, Equatable {
    let format: FileFormat?
    let pixelWidth: Int
    let pixelHeight: Int
    let dpiWidth: Double?
    let dpiHeight: Double?
    let effectiveDPI: Double
    let gpsLatitude: Double?
    let gpsLongitude: Double?
    let gpsAltitude: Double?
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?
    let dateTaken: String?
    let software: String?
    let entries: [ImageMetadataTagEntry]
    let hasXMPData: Bool
    let xmpByteCount: Int
    let supportsLosslessMetadataRewrite: Bool
    let formatLimitationNote: String

    var gpsSummary: String? {
        guard let lat = gpsLatitude, let lon = gpsLongitude else { return nil }
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        let altStr = gpsAltitude.map { String(format: " · %.1f m", $0) } ?? ""
        return String(format: "%.5f° %@, %.5f° %@%@", abs(lat), latDir, abs(lon), lonDir, altStr)
    }

    func physicalWidthInches() -> Double {
        guard pixelWidth > 0, effectiveDPI > 0 else { return 0 }
        return Double(pixelWidth) / effectiveDPI
    }

    func physicalHeightInches() -> Double {
        guard pixelHeight > 0, effectiveDPI > 0 else { return 0 }
        return Double(pixelHeight) / effectiveDPI
    }
}

struct ImageMetadataDiffSummary: Sendable, Equatable {
    let beforeCount: Int
    let afterCount: Int
    let removedEntries: [ImageMetadataTagEntry]
    let retainedEntries: [ImageMetadataTagEntry]
}

enum ImageMetadataInspectorService {

    /// Inspects categorized EXIF, IPTC, TIFF, XMP, GPS, and DPI tags across any ImageIO or JXL file.
    static func inspectDetailed(url: URL) -> ImageDetailedMetadataSnapshot {
        let format = FileDetector.detectFormat(url: url)

        if format == .jxl, let info = try? JPEGXLCodec.inspect(url: url) {
            let boxProps = JPEGXLCodec.parseMetadataBoxes(exifTIFF: info.exifData, xmp: info.xmpData)
            var entries: [ImageMetadataTagEntry] = []
            var dpiW: Double? = nil
            var dpiH: Double? = nil
            var gpsLat: Double? = nil
            var gpsLon: Double? = nil
            var gpsAlt: Double? = nil
            var make: String? = nil
            var model: String? = nil
            var lens: String? = nil
            var dateTaken: String? = nil
            var software: String? = nil

            extractEntries(
                from: boxProps,
                entries: &entries,
                dpiW: &dpiW,
                dpiH: &dpiH,
                gpsLat: &gpsLat,
                gpsLon: &gpsLon,
                gpsAlt: &gpsAlt,
                make: &make,
                model: &model,
                lens: &lens,
                dateTaken: &dateTaken,
                software: &software
            )

            if let xmp = info.xmpData, !xmp.isEmpty {
                entries.append(ImageMetadataTagEntry(id: "xmp-jxl", category: .xmp, key: "XMP Box", value: "\(xmp.count) bytes embedded"))
            }

            entries.append(ImageMetadataTagEntry(id: "tech-dims", category: .technical, key: "Dimensions", value: "\(info.width) × \(info.height) px"))
            entries.append(ImageMetadataTagEntry(id: "tech-depth", category: .technical, key: "Bit Depth", value: "\(info.bitsPerSample) bpc"))

            return ImageDetailedMetadataSnapshot(
                format: format,
                pixelWidth: info.width,
                pixelHeight: info.height,
                dpiWidth: dpiW,
                dpiHeight: dpiH,
                effectiveDPI: dpiW ?? dpiH ?? 72.0,
                gpsLatitude: gpsLat,
                gpsLongitude: gpsLon,
                gpsAltitude: gpsAlt,
                cameraMake: make,
                cameraModel: model,
                lensModel: lens,
                dateTaken: dateTaken,
                software: software,
                entries: entries,
                hasXMPData: (info.xmpData?.isEmpty == false),
                xmpByteCount: info.xmpData?.count ?? 0,
                supportsLosslessMetadataRewrite: false,
                formatLimitationNote: formatLimitationNote(for: format)
            )
        }

        guard let inspected = ImageSourcePipeline.inspectProperties(url: url, isRAWHint: format?.isRawImage == true),
              let props = inspected.properties else {
            let dims = ImageProcessingService.inspectSourceDimensions(url: url)
            return ImageDetailedMetadataSnapshot(
                format: format,
                pixelWidth: dims?.width ?? 0,
                pixelHeight: dims?.height ?? 0,
                dpiWidth: nil,
                dpiHeight: nil,
                effectiveDPI: 72.0,
                gpsLatitude: nil,
                gpsLongitude: nil,
                gpsAltitude: nil,
                cameraMake: nil,
                cameraModel: nil,
                lensModel: nil,
                dateTaken: nil,
                software: nil,
                entries: [],
                hasXMPData: false,
                xmpByteCount: 0,
                supportsLosslessMetadataRewrite: supportsLosslessMetadataCopy(format: format),
                formatLimitationNote: formatLimitationNote(for: format)
            )
        }
        let src = inspected.source

        let extracted = ImageSourcePipeline.extractStructuredProperties(from: props)
        let pw = extracted.orientedWidth ?? extracted.pixelWidth ?? 0
        let ph = extracted.orientedHeight ?? extracted.pixelHeight ?? 0
        var entries: [ImageMetadataTagEntry] = []
        var dpiW = extracted.dpiWidth
        var dpiH = extracted.dpiHeight
        var gpsLat: Double? = nil
        var gpsLon: Double? = nil
        var gpsAlt: Double? = nil
        var make: String? = nil
        var model: String? = nil
        var lens: String? = nil
        var dateTaken: String? = nil
        var software: String? = nil

        extractEntries(
            from: props,
            entries: &entries,
            dpiW: &dpiW,
            dpiH: &dpiH,
            gpsLat: &gpsLat,
            gpsLon: &gpsLon,
            gpsAlt: &gpsAlt,
            make: &make,
            model: &model,
            lens: &lens,
            dateTaken: &dateTaken,
            software: &software
        )

        // Inspect XMP metadata packet cleanly via CGImageSourceCopyMetadataAtIndex
        var hasXMP = false
        var xmpBytes = 0
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
           let xmpData = CGImageMetadataCreateXMPData(meta, nil) as Data? {
            hasXMP = !xmpData.isEmpty
            xmpBytes = xmpData.count
            if let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
                for tag in tags {
                    guard let ns = CGImageMetadataTagCopyNamespace(tag) as String?,
                          let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
                    let valStr: String = {
                        if let raw = CGImageMetadataTagCopyValue(tag) {
                            return String(describing: raw)
                        }
                        return "(present)"
                    }()
                    if ns.contains("xmp") || ns.contains("dc") || ns.contains("photoshop") || ns.contains("tiff") == false {
                        entries.append(ImageMetadataTagEntry(
                            id: "xmp-\(ns)-\(name)",
                            category: .xmp,
                            key: name,
                            value: String(valStr.prefix(120))
                        ))
                    }
                }
            }
        }

        if let dpiW {
            entries.append(ImageMetadataTagEntry(id: "tech-dpiw", category: .technical, key: "DPI Width", value: String(format: "%.0f DPI", dpiW)))
        }
        if let dpiH {
            entries.append(ImageMetadataTagEntry(id: "tech-dpih", category: .technical, key: "DPI Height", value: String(format: "%.0f DPI", dpiH)))
        }
        if pw > 0 && ph > 0 {
            entries.append(ImageMetadataTagEntry(id: "tech-dims", category: .technical, key: "Pixel Size", value: "\(pw) × \(ph) px"))
        }

        return ImageDetailedMetadataSnapshot(
            format: format,
            pixelWidth: pw,
            pixelHeight: ph,
            dpiWidth: dpiW,
            dpiHeight: dpiH,
            effectiveDPI: dpiW ?? dpiH ?? 72.0,
            gpsLatitude: gpsLat,
            gpsLongitude: gpsLon,
            gpsAltitude: gpsAlt,
            cameraMake: make,
            cameraModel: model,
            lensModel: lens,
            dateTaken: dateTaken,
            software: software,
            entries: entries,
            hasXMPData: hasXMP,
            xmpByteCount: xmpBytes,
            supportsLosslessMetadataRewrite: supportsLosslessMetadataCopy(format: format),
            formatLimitationNote: formatLimitationNote(for: format)
        )
    }

    /// Computes a deterministic preview diff of what will be removed vs retained under the current privacy payload.
    static func previewDiff(snapshot: ImageDetailedMetadataSnapshot, payload: ImageMetadataEditPayload) -> ImageMetadataDiffSummary {
        var removed: [ImageMetadataTagEntry] = []
        var retained: [ImageMetadataTagEntry] = []

        for entry in snapshot.entries {
            if entry.category == .technical {
                retained.append(entry)
                continue
            }
            if shouldStrip(entry: entry, payload: payload) {
                removed.append(entry)
            } else {
                retained.append(entry)
            }
        }

        return ImageMetadataDiffSummary(
            beforeCount: snapshot.entries.count,
            afterCount: retained.count,
            removedEntries: removed,
            retainedEntries: retained
        )
    }

    /// Strips or updates metadata NON-DESTRUCTIVELY using `CGImageDestinationCopyImageSource` when supported (zero pixel re-encode),
    /// returning whether pixel recompression was avoided.
    static func writeMetadataAndDPINonDestructively(
        from sourceURL: URL,
        to destinationURL: URL,
        payload: ImageMetadataEditPayload,
        dpi: ImageDPIConfig? = nil
    ) async throws -> (wasLosslessPixelCopy: Bool, formatNote: String) {
        let format = FileDetector.detectFormat(url: sourceURL)
        let parent = destinationURL.deletingLastPathComponent()

        if format == .jxl {
            // JPEG XL container boxes require libjxl decode/re-encode unless lossless JPEG transcoding applies
            let ext = destinationURL.pathExtension.isEmpty ? (sourceURL.pathExtension.isEmpty ? "jxl" : sourceURL.pathExtension) : destinationURL.pathExtension
            let scratch = parent.appendingPathComponent(".lc-meta-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: scratch) }

            try FileManager.default.copyItem(at: sourceURL, to: scratch)
            try await ImageMetadataService.writePrivacyCleaned(url: scratch, payload: payload)
            _ = try OutputReservationCoordinator.moveOrReplaceTempFile(scratch, to: destinationURL, policy: .overwrite)
            return (false, "JPEG XL metadata boxes updated via lossless container rewrite.")
        }

        if let format, supportsLosslessMetadataCopy(format: format),
           let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let typeID = CGImageSourceGetType(src) {
            let scratch = parent.appendingPathComponent(".lc-meta-\(UUID().uuidString).\(destinationURL.pathExtension)")
            defer { try? FileManager.default.removeItem(at: scratch) }

            if let dest = CGImageDestinationCreateWithURL(scratch as CFURL, typeID, 1, nil) {
                var options: [CFString: Any] = [:]
                let existing = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]

                if payload.policy == .stripAll {
                    options[kCGImagePropertyExifDictionary] = kCFNull
                    options[kCGImagePropertyGPSDictionary] = kCFNull
                    options[kCGImagePropertyIPTCDictionary] = kCFNull
                    options[kCGImagePropertyTIFFDictionary] = kCFNull
                    options[kCGImagePropertyExifAuxDictionary] = kCFNull
                    options[kCGImagePropertyMakerAppleDictionary] = kCFNull
                    options[kCGImagePropertyMakerCanonDictionary] = kCFNull
                    options[kCGImagePropertyMakerNikonDictionary] = kCFNull
                    options[kCGImageMetadataShouldExcludeXMP] = true
                    options[kCGImageMetadataShouldExcludeGPS] = true
                } else {
                    if let updated = ImageMetadataService.applyPolicyToProperties(existing: existing, payload: payload) {
                        for (k, v) in updated {
                            options[k as CFString] = v
                        }
                    }
                    if payload.stripGPS || payload.policy == .stripGPSOnly {
                        options[kCGImagePropertyGPSDictionary] = kCFNull
                        options[kCGImageMetadataShouldExcludeGPS] = true
                    }
                    if payload.stripEXIF || payload.stripCamera || payload.policy == .stripCameraInfo {
                        options[kCGImagePropertyExifDictionary] = kCFNull
                    }
                    if payload.stripIPTC || payload.stripRights || payload.policy == .stripAuthorCopyright {
                        options[kCGImagePropertyIPTCDictionary] = kCFNull
                    }
                    if payload.stripXMP {
                        options[kCGImageMetadataShouldExcludeXMP] = true
                    }
                }

                if let dpi, dpi.enabled && !dpi.resamplePixels && dpi.targetDPI > 0 {
                    options[kCGImagePropertyDPIWidth] = dpi.targetDPI
                    options[kCGImagePropertyDPIHeight] = dpi.targetDPI
                }

                var errorRef: Unmanaged<CFError>?
                let ok = CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &errorRef)
                if ok {
                    _ = try OutputReservationCoordinator.moveOrReplaceTempFile(scratch, to: destinationURL, policy: .overwrite)
                    return (true, "Lossless metadata rewrite completed with zero pixel recompression (CGImageDestinationCopyImageSource).")
                }
            }
        }

        // Fallback when container does not support CopyImageSource (e.g., WebP/BMP/TGA)
        let ext = destinationURL.pathExtension.isEmpty ? sourceURL.pathExtension : destinationURL.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let scratch = parent.appendingPathComponent(".lc-meta-\(UUID().uuidString)\(suffix)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try FileManager.default.copyItem(at: sourceURL, to: scratch)
        try await ImageMetadataService.writePrivacyCleaned(url: scratch, payload: payload)
        _ = try OutputReservationCoordinator.moveOrReplaceTempFile(scratch, to: destinationURL, policy: .overwrite)
        return (false, formatLimitationNote(for: format))
    }

    static func supportsLosslessMetadataCopy(format: FileFormat?) -> Bool {
        guard let format else { return false }
        return [.jpg, .png, .tiff, .heic].contains(format)
    }

    static func formatLimitationNote(for format: FileFormat?) -> String {
        switch format {
        case .jpg, .heic, .tiff:
            return "Supports EXIF, IPTC, XMP, GPS, ICC, and DPI tags; supports lossless metadata copy without pixel recompression."
        case .png:
            return "Supports PNG text/eXIf, ICC, and pHYs physical DPI tags via lossless chunk rewrite; some camera MakerNotes are omitted."
        case .jxl:
            return "Stores EXIF/XML(XMP)/ICC in JXL container boxes; editing metadata triggers a container rewrite."
        case .webp:
            return "WebP supports EXIF/XMP/ICC chunks via ImageIO rewrite; physical DPI metadata tags have limited viewer support."
        case .avif:
            return "AVIF stores EXIF/XMP/CICP boxes; pixel re-encoding is used on write when transforming metadata."
        case .svg, .dng, .cr2, .cr3, .nef, .arw, .raf:
            return "Read-only metadata inspection for vector/RAW inputs; export to PNG/TIFF/JXL to write sanitized copies."
        default:
            return "Metadata support depends on the chosen output container format."
        }
    }

    // MARK: - Private Helpers

    private static func shouldStrip(entry: ImageMetadataTagEntry, payload: ImageMetadataEditPayload) -> Bool {
        switch payload.policy {
        case .stripAll:
            return true
        case .stripGPSOnly:
            return entry.category == .gps
        case .stripCameraInfo:
            return entry.category == .exif || (entry.category == .tiff && ["Make", "Model", "Software"].contains(entry.key))
        case .stripAuthorCopyright:
            return entry.category == .iptc || (entry.category == .tiff && ["Artist", "Copyright"].contains(entry.key))
        case .preserveAll, .applyEditedMetadata:
            if entry.category == .gps && payload.stripGPS { return true }
            if entry.category == .exif && (payload.stripEXIF || payload.stripCamera) { return true }
            if entry.category == .iptc && (payload.stripIPTC || payload.stripRights) { return true }
            if entry.category == .xmp && payload.stripXMP { return true }
            if entry.category == .tiff {
                if payload.stripCamera && ["Make", "Model"].contains(entry.key) { return true }
                if payload.stripSoftware && entry.key == "Software" { return true }
                if payload.stripRights && ["Artist", "Copyright"].contains(entry.key) { return true }
            }
            return false
        }
    }

    private static func extractEntries(
        from props: [CFString: Any],
        entries: inout [ImageMetadataTagEntry],
        dpiW: inout Double?,
        dpiH: inout Double?,
        gpsLat: inout Double?,
        gpsLon: inout Double?,
        gpsAlt: inout Double?,
        make: inout String?,
        model: inout String?,
        lens: inout String?,
        dateTaken: inout String?,
        software: inout String?
    ) {
        let extracted = ImageSourcePipeline.extractStructuredProperties(from: props)

        if let v = extracted.make {
            make = v
            entries.append(ImageMetadataTagEntry(id: "tiff-make", category: .tiff, key: "Make", value: v))
        }
        if let v = extracted.model {
            model = v
            entries.append(ImageMetadataTagEntry(id: "tiff-model", category: .tiff, key: "Model", value: v))
        }
        if let v = extracted.software {
            software = v
            entries.append(ImageMetadataTagEntry(id: "tiff-software", category: .tiff, key: "Software", value: v))
        }
        if let v = extracted.artist {
            entries.append(ImageMetadataTagEntry(id: "tiff-artist", category: .tiff, key: "Artist", value: v))
        }
        if let v = extracted.copyright {
            entries.append(ImageMetadataTagEntry(id: "tiff-copy", category: .tiff, key: "Copyright", value: v))
        }
        if dpiW == nil, let xr = extracted.dpiWidth { dpiW = xr }
        if dpiH == nil, let yr = extracted.dpiHeight { dpiH = yr }

        if let v = extracted.lensModel {
            lens = v
            entries.append(ImageMetadataTagEntry(id: "exif-lens", category: .exif, key: "LensModel", value: v))
        }
        if let v = extracted.dateTimeOriginal {
            dateTaken = v
            entries.append(ImageMetadataTagEntry(id: "exif-date", category: .exif, key: "DateTimeOriginal", value: v))
        }
        if let iso = extracted.iso {
            entries.append(ImageMetadataTagEntry(id: "exif-iso", category: .exif, key: "ISO", value: "\(iso)"))
        }
        if let f = extracted.aperture {
            entries.append(ImageMetadataTagEntry(id: "exif-f", category: .exif, key: "Aperture", value: String(format: "f/%.1f", f)))
        }
        if let fl = extracted.focalLength {
            entries.append(ImageMetadataTagEntry(id: "exif-fl", category: .exif, key: "FocalLength", value: String(format: "%.1f mm", fl)))
        }
        if let et = extracted.exposureTime {
            entries.append(ImageMetadataTagEntry(id: "exif-exp", category: .exif, key: "ExposureTime", value: String(format: "1/%.0f s", max(1.0, 1.0 / et))))
        }

        if let v = extracted.headline {
            entries.append(ImageMetadataTagEntry(id: "iptc-headline", category: .iptc, key: "Headline", value: v))
        }
        if let v = extracted.byline {
            entries.append(ImageMetadataTagEntry(id: "iptc-byline", category: .iptc, key: "Byline", value: v))
        }
        if let v = extracted.copyrightNotice {
            entries.append(ImageMetadataTagEntry(id: "iptc-copy", category: .iptc, key: "CopyrightNotice", value: v))
        }
        if let v = extracted.caption {
            entries.append(ImageMetadataTagEntry(id: "iptc-cap", category: .iptc, key: "Caption", value: v))
        }
        if !extracted.keywords.isEmpty {
            entries.append(ImageMetadataTagEntry(id: "iptc-kw", category: .iptc, key: "Keywords", value: extracted.keywords.joined(separator: ", ")))
        }

        if let lat = extracted.gpsLatitude,
           let lon = extracted.gpsLongitude {
            let latRef = extracted.gpsLatitudeRef ?? "N"
            let lonRef = extracted.gpsLongitudeRef ?? "E"
            gpsLat = lat
            gpsLon = lon
            gpsAlt = extracted.gpsAltitude
            entries.append(ImageMetadataTagEntry(id: "gps-lat", category: .gps, key: "Latitude", value: String(format: "%.5f° %@", abs(lat), latRef)))
            entries.append(ImageMetadataTagEntry(id: "gps-lon", category: .gps, key: "Longitude", value: String(format: "%.5f° %@", abs(lon), lonRef)))
            if let gpsAlt {
                entries.append(ImageMetadataTagEntry(id: "gps-alt", category: .gps, key: "Altitude", value: String(format: "%.1f m", gpsAlt)))
            }
        }
    }
}
