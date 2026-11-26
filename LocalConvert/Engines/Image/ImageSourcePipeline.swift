import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Shared Apple-native (`ImageIO` + `CoreImage` / `CIRAWFilter`) image source, orientation,
/// RAW fallback, and structured image property extraction pipeline.
///
/// Consolidates common decoding, TIFF-header DNG hinting, orientation normalization, and
/// EXIF/IPTC/TIFF/GPS/DPI property parsing without altering caller-specific policies
/// (e.g. Image Toolbox preview proxy caching vs conversion-time full-res RAW development)
/// or adding external dependencies.
enum ImageSourcePipeline {

    // MARK: - Canonical Extracted Image Properties

    struct ExtractedImageProperties: Sendable, Equatable {
        // Technical
        var pixelWidth: Int?
        var pixelHeight: Int?
        var orientedWidth: Int?
        var orientedHeight: Int?
        var orientation: CGImagePropertyOrientation = .up
        var colorModel: String?
        var bitDepth: Int?
        var hasAlpha: Bool?
        var dpiWidth: Double?
        var dpiHeight: Double?

        // TIFF / Device
        var make: String?
        var model: String?
        var software: String?
        var artist: String?
        var copyright: String?
        var imageDescription: String?
        var dateTime: String?

        // EXIF Camera
        var dateTimeOriginal: String?
        var lensModel: String?
        var iso: Int?
        var aperture: Double?
        var focalLength: Double?
        var exposureTime: Double?

        // IPTC Rights & Caption
        var headline: String?
        var caption: String?
        var byline: String?
        var copyrightNotice: String?
        var keywords: [String] = []

        // GPS Location (signed coordinates)
        var gpsLatitude: Double?
        var gpsLongitude: Double?
        var gpsLatitudeRef: String?
        var gpsLongitudeRef: String?
        var gpsAltitude: Double?
    }

    struct RAWRenderResult {
        let cgImage: CGImage
        let properties: [String: Any]?
        let nativeWidth: Int?
        let nativeHeight: Int?
    }

    // MARK: - Format & Header Helpers

    static func isRAWInput(detectedFormat: FileFormat?, url: URL) -> Bool {
        if detectedFormat?.isRawImage == true { return true }
        return FileFormat.from(extension: url.pathExtension)?.isRawImage == true
    }

    static func hasTIFFHeader(url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let hdr = try? fh.read(upToCount: 4), hdr.count == 4 else { return false }
        return hdr == Data([0x49, 0x49, 0x2A, 0x00]) || hdr == Data([0x4D, 0x4D, 0x00, 0x2A])
    }

    // MARK: - Source Opening & Inspection (Zero Redundant Disk Reads)

    /// Opens an ImageIO `CGImageSource`, retrying with an explicit `public.tiff` hint only
    /// for RAW inputs whose file header starts with TIFF magic bytes (`II*\0` or `MM\0*`).
    static func openImageSource(url: URL, isRAWHint: Bool) -> CGImageSource? {
        if let primary = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(primary) > 0 {
            return primary
        }
        if isRAWHint && hasTIFFHeader(url: url),
           let tiffSource = CGImageSourceCreateWithURL(
               url as CFURL,
               [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary
           ),
           CGImageSourceGetCount(tiffSource) > 0 {
            return tiffSource
        }
        return nil
    }

    /// Opens `url` once and reads index-0 properties, falling back to `public.tiff` hint for
    /// TIFF-wrapped RAW inputs when the primary RAW plugin yields no properties.
    static func inspectProperties(
        url: URL,
        isRAWHint: Bool
    ) -> (source: CGImageSource, properties: [CFString: Any]?)? {
        if let primary = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(primary) > 0 {
            if let props = CGImageSourceCopyPropertiesAtIndex(primary, 0, nil) as? [CFString: Any] {
                return (primary, props)
            }
            if isRAWHint && hasTIFFHeader(url: url),
               let tiffSource = CGImageSourceCreateWithURL(
                   url as CFURL,
                   [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary
               ),
               CGImageSourceGetCount(tiffSource) > 0,
               let tiffProps = CGImageSourceCopyPropertiesAtIndex(tiffSource, 0, nil) as? [CFString: Any] {
                return (tiffSource, tiffProps)
            }
            return (primary, nil)
        }

        if isRAWHint && hasTIFFHeader(url: url),
           let tiffSource = CGImageSourceCreateWithURL(
               url as CFURL,
               [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary
           ),
           CGImageSourceGetCount(tiffSource) > 0 {
            let tiffProps = CGImageSourceCopyPropertiesAtIndex(tiffSource, 0, nil) as? [CFString: Any]
            return (tiffSource, tiffProps)
        }

        return nil
    }

    // MARK: - Orientation & Dimensions

    static func orientation(from properties: [CFString: Any]?) -> CGImagePropertyOrientation {
        orientation(fromAny: properties)
    }

    static func orientation(from properties: [String: Any]?) -> CGImagePropertyOrientation {
        orientation(fromAny: properties)
    }

    private static func orientation(fromAny properties: [AnyHashable: Any]?) -> CGImagePropertyOrientation {
        guard let properties else { return .up }
        if let raw = uint32Value(properties[kCGImagePropertyOrientation]) ?? uint32Value(properties[kCGImagePropertyOrientation as String]),
           let parsed = CGImagePropertyOrientation(rawValue: raw) {
            return parsed
        }
        if let tiff = (properties[kCGImagePropertyTIFFDictionary] ?? properties[kCGImagePropertyTIFFDictionary as String]) as? [AnyHashable: Any],
           let raw = uint32Value(tiff[kCGImagePropertyTIFFOrientation]) ?? uint32Value(tiff[kCGImagePropertyTIFFOrientation as String]),
           let parsed = CGImagePropertyOrientation(rawValue: raw) {
            return parsed
        }
        return .up
    }

    static func orientedDimensions(from properties: [CFString: Any]?) -> (width: Int, height: Int)? {
        orientedDimensions(fromAny: properties)
    }

    static func orientedDimensions(from properties: [String: Any]?) -> (width: Int, height: Int)? {
        orientedDimensions(fromAny: properties)
    }

    private static func orientedDimensions(fromAny properties: [AnyHashable: Any]?) -> (width: Int, height: Int)? {
        guard let properties,
              let w = intValue(properties[kCGImagePropertyPixelWidth] ?? properties[kCGImagePropertyPixelWidth as String]),
              let h = intValue(properties[kCGImagePropertyPixelHeight] ?? properties[kCGImagePropertyPixelHeight as String]),
              w > 0, h > 0 else {
            return nil
        }
        let orient = orientation(fromAny: properties)
        if (5...8).contains(orient.rawValue) {
            return (h, w)
        }
        return (w, h)
    }

    /// Produces destination ImageIO properties after pixels have already been rotated upright.
    static func normalizedPropertiesAfterOrientation(
        from sourceProperties: [String: Any]?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> [String: Any] {
        var destProps: [String: Any] = [:]
        if let sourceProperties {
            for (key, value) in sourceProperties {
                destProps[key] = value
            }
        }
        destProps[kCGImagePropertyOrientation as String] = 1
        if var tiffDict = destProps[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiffDict[kCGImagePropertyTIFFOrientation as String] = 1
            destProps[kCGImagePropertyTIFFDictionary as String] = tiffDict
        }
        destProps[kCGImagePropertyPixelWidth as String] = pixelWidth
        destProps[kCGImagePropertyPixelHeight as String] = pixelHeight
        return destProps
    }

    // MARK: - Thumbnail & Core Image CIRAWFilter Rendering

    /// Extracts an embedded or ImageIO-generated thumbnail distinct from full-resolution RAW development.
    static func extractThumbnail(
        from source: CGImageSource,
        index: Int = 0,
        maxPixelSize: CGFloat
    ) -> CGImage? {
        ImageProcessor.createThumbnail(from: source, index: index, maxPixelSize: maxPixelSize)
    }

    /// Renders a RAW URL via macOS native `CIRAWFilter` + shared `CIContext` with bounded memory cleanup.
    static func renderWithCIRAWFilter(
        url: URL,
        config: ImageRAWDevelopConfig = ImageRAWDevelopConfig(),
        scaleFactor: Double = 1.0,
        prefer16Bit: Bool = true
    ) -> RAWRenderResult? {
        autoreleasepool {
            guard let rawOut = ImageAdjustmentsEngine.loadWithCIRAWFilter(
                url: url,
                config: config,
                scaleFactor: scaleFactor
            ) else {
                return nil
            }
            let outSpace = CGColorSpace(name: CGColorSpace.displayP3)
                ?? CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB()
            let extent = rawOut.ciImage.extent.integral
            let ciFormat: CIFormat = prefer16Bit ? .RGBA16 : .RGBA8
            let ctx = ImageProcessor.sharedCIContext(for: outSpace)
            guard let rendered = ctx.createCGImage(rawOut.ciImage, from: extent, format: ciFormat, colorSpace: outSpace) else {
                return nil
            }
            if Int(extent.width) * Int(extent.height) >= 16_000_000 {
                ctx.clearCaches()
            }
            return RAWRenderResult(
                cgImage: rendered,
                properties: rawOut.properties,
                nativeWidth: rawOut.nativeWidth,
                nativeHeight: rawOut.nativeHeight
            )
        }
    }

    // MARK: - Canonical Full-Resolution Standard / Camera RAW Conversion Decode

    /// Decodes standard raster formats via ImageIO primary path, falling back for Camera RAW inputs
    /// through native `CIRAWFilter` and TIFF-header DNG hinting without external dependencies.
    static func decodeStandardOrRAW(
        url: URL,
        detectedFormat: FileFormat?
    ) throws -> (CGImage, [String: Any]?) {
        let isRAW = isRAWInput(detectedFormat: detectedFormat, url: url)
        let decodeOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

        // 1. Primary ImageIO / CGImageSource path
        if let primaryResult: (CGImage, [String: Any]?) = try autoreleasepool(invoking: {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                if !isRAW {
                    throw ConversionError.invalidInput("The file could not be read as an image.")
                }
                return nil
            }
            let count = CGImageSourceGetCount(imageSource)
            guard count > 0 else {
                if !isRAW {
                    throw ConversionError.invalidInput("The image file does not contain any image data.")
                }
                return nil
            }
            if var img = CGImageSourceCreateImageAtIndex(imageSource, 0, decodeOptions as CFDictionary) {
                let loadedProps = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
                let orient = orientation(from: loadedProps)
                if orient != .up {
                    img = ImageProcessor.orientCGImage(img, orientation: orient)
                }
                return (img, loadedProps)
            }
            return nil
        }) {
            return primaryResult
        }

        // 2. Native Camera RAW fallbacks (CIRAWFilter -> TIFF-wrapped DNG hint)
        if isRAW {
            if let rawRendered = renderWithCIRAWFilter(url: url, config: ImageRAWDevelopConfig(), scaleFactor: 1.0, prefer16Bit: true) {
                return (rawRendered.cgImage, rawRendered.properties)
            }

            if let tiffResult: (CGImage, [String: Any]?) = autoreleasepool(invoking: {
                guard hasTIFFHeader(url: url),
                      let tiffSrc = CGImageSourceCreateWithURL(
                          url as CFURL,
                          [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary
                      ),
                      CGImageSourceGetCount(tiffSrc) > 0,
                      var tiffImg = CGImageSourceCreateImageAtIndex(tiffSrc, 0, decodeOptions as CFDictionary) else {
                    return nil
                }
                let loadedProps = CGImageSourceCopyPropertiesAtIndex(tiffSrc, 0, nil) as? [String: Any]
                let orient = orientation(from: loadedProps)
                if orient != .up {
                    tiffImg = ImageProcessor.orientCGImage(tiffImg, orientation: orient)
                }
                return (tiffImg, loadedProps)
            }) {
                return tiffResult
            }

            throw ConversionError.invalidInput(
                "This Camera RAW file (\(url.lastPathComponent)) could not be decoded by macOS ImageIO or Camera RAW. Its camera sensor variant may be unsupported on this macOS version or the file may be corrupted."
            )
        }

        throw ConversionError.invalidInput("The image file could not be decoded. It may be corrupted or unsupported.")
    }

    // MARK: - Unified Structured Property Extraction

    static func extractStructuredProperties(from props: [CFString: Any]) -> ExtractedImageProperties {
        var result = ExtractedImageProperties()

        result.pixelWidth = intValue(props[kCGImagePropertyPixelWidth])
        result.pixelHeight = intValue(props[kCGImagePropertyPixelHeight])
        let orient = orientation(from: props)
        result.orientation = orient
        if let dims = orientedDimensions(from: props) {
            result.orientedWidth = dims.width
            result.orientedHeight = dims.height
        }
        result.colorModel = props[kCGImagePropertyColorModel] as? String
        result.bitDepth = intValue(props[kCGImagePropertyDepth])
        result.hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool
        result.dpiWidth = positiveDouble(props[kCGImagePropertyDPIWidth])
        result.dpiHeight = positiveDouble(props[kCGImagePropertyDPIHeight])

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            result.make = tiff[kCGImagePropertyTIFFMake] as? String
            result.model = tiff[kCGImagePropertyTIFFModel] as? String
            result.software = tiff[kCGImagePropertyTIFFSoftware] as? String
            result.artist = tiff[kCGImagePropertyTIFFArtist] as? String
            result.copyright = tiff[kCGImagePropertyTIFFCopyright] as? String
            result.imageDescription = tiff[kCGImagePropertyTIFFImageDescription] as? String
            result.dateTime = tiff[kCGImagePropertyTIFFDateTime] as? String
            if result.dpiWidth == nil {
                result.dpiWidth = positiveDouble(tiff[kCGImagePropertyTIFFXResolution])
            }
            if result.dpiHeight == nil {
                result.dpiHeight = positiveDouble(tiff[kCGImagePropertyTIFFYResolution])
            }
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            result.dateTimeOriginal = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            result.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArr.first {
                result.iso = first
            } else if let isoArrNum = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoArrNum.first {
                result.iso = first.intValue
            } else {
                result.iso = intValue(exif[kCGImagePropertyExifISOSpeedRatings])
            }
            result.aperture = doubleValue(exif[kCGImagePropertyExifFNumber])
            result.focalLength = doubleValue(exif[kCGImagePropertyExifFocalLength])
            if let exp = doubleValue(exif[kCGImagePropertyExifExposureTime]), exp > 0 {
                result.exposureTime = exp
            }
        }

        if let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            result.headline = iptc[kCGImagePropertyIPTCHeadline] as? String
            result.caption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String
            result.byline = iptc[kCGImagePropertyIPTCByline] as? String
            result.copyrightNotice = iptc[kCGImagePropertyIPTCCopyrightNotice] as? String
            if let kw = iptc[kCGImagePropertyIPTCKeywords] as? [String], !kw.isEmpty {
                result.keywords = kw
            }
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = doubleValue(gps[kCGImagePropertyGPSLatitude]),
           let lon = doubleValue(gps[kCGImagePropertyGPSLongitude]) {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            result.gpsLatitudeRef = latRef
            result.gpsLongitudeRef = lonRef
            result.gpsLatitude = (latRef.uppercased() == "S") ? -abs(lat) : lat
            result.gpsLongitude = (lonRef.uppercased() == "W") ? -abs(lon) : lon
            result.gpsAltitude = doubleValue(gps[kCGImagePropertyGPSAltitude])
        }

        return result
    }

    // MARK: - Private Numeric Coercions

    private static func uint32Value(_ value: Any?) -> UInt32? {
        if let n = value as? NSNumber { return n.uint32Value }
        if let u = value as? UInt32 { return u }
        if let i = value as? Int { return UInt32(exactly: i) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func positiveDouble(_ value: Any?) -> Double? {
        guard let v = doubleValue(value), v > 0 else { return nil }
        return v
    }
}
