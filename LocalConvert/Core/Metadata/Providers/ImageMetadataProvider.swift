import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import os.log

final class ImageMetadataProvider: MetadataProvider, @unchecked Sendable {
    
    let providerName = "ImageMetadataProvider"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ImageMetadataProvider")
    
    var supportedFormats: Set<FileFormat> {
        [.jpg, .png, .heic, .webp, .tiff, .bmp, .gif, .avif, .svg, .ico, .icns, .dng, .psd, .tga]
    }
    
    init() {}
    
    // MARK: - Capabilities
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities {
        guard supportedFormats.contains(format) else {
            return .unsupported(for: format)
        }
        
        if format == .svg || format == .dng || format == .psd {
            return MetadataCapabilities.readOnly(
                for: format,
                fields: [
                    MetadataFieldDescriptor(id: "title", name: "Title", section: .basic, valueType: .string),
                    MetadataFieldDescriptor(id: "artist", name: "Creator / Author", section: .basic, valueType: .string),
                    MetadataFieldDescriptor(id: "description", name: "Description", section: .description, valueType: .string),
                    MetadataFieldDescriptor(id: "copyright", name: "Copyright", section: .rights, valueType: .string),
                    MetadataFieldDescriptor(id: "cameraMake", name: "Camera Make", section: .camera, valueType: .string),
                    MetadataFieldDescriptor(id: "cameraModel", name: "Camera Model", section: .camera, valueType: .string),
                    MetadataFieldDescriptor(id: "iso", name: "ISO Speed", section: .camera, valueType: .integer),
                    MetadataFieldDescriptor(id: "dimensions", name: "Dimensions", section: .technical, valueType: .readOnlyTechnical),
                    MetadataFieldDescriptor(id: "colorSpace", name: "Color Space", section: .technical, valueType: .readOnlyTechnical)
                ]
            )
        }
        
        let fields: [MetadataFieldDescriptor] = [
            MetadataFieldDescriptor(id: "title", name: "Title", section: .basic, valueType: .string, placeholder: "Image Title"),
            MetadataFieldDescriptor(id: "artist", name: "Creator / Author", section: .basic, valueType: .string, placeholder: "Photographer / Artist"),
            MetadataFieldDescriptor(id: "description", name: "Description / Caption", section: .description, valueType: .string, placeholder: "Image Description"),
            MetadataFieldDescriptor(id: "copyright", name: "Copyright", section: .rights, valueType: .string, placeholder: "© Copyright Notice"),
            MetadataFieldDescriptor(id: "cameraMake", name: "Camera Make", section: .camera, valueType: .string, placeholder: "e.g. Apple, Sony, Canon"),
            MetadataFieldDescriptor(id: "cameraModel", name: "Camera Model", section: .camera, valueType: .string, placeholder: "e.g. iPhone 15 Pro, A7 IV"),
            MetadataFieldDescriptor(id: "lensModel", name: "Lens Model", section: .camera, valueType: .string, placeholder: "e.g. 24-70mm F2.8"),
            MetadataFieldDescriptor(id: "iso", name: "ISO Speed", section: .camera, valueType: .integer, placeholder: "e.g. 100, 800"),
            MetadataFieldDescriptor(id: "aperture", name: "Aperture (f-stop)", section: .camera, valueType: .decimal, placeholder: "e.g. 2.8"),
            MetadataFieldDescriptor(id: "focalLength", name: "Focal Length (mm)", section: .camera, valueType: .decimal, placeholder: "e.g. 50.0"),
            MetadataFieldDescriptor(id: "gps", name: "GPS Location", section: .location, valueType: .gps, isWritable: true, isRemovable: true),
            
            // Technical metadata (Read-Only)
            MetadataFieldDescriptor(id: "dimensions", name: "Dimensions", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "colorSpace", name: "Color Space", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "bitDepth", name: "Bit Depth", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "hasAlpha", name: "Alpha Channel", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false)
        ]
        
        return MetadataCapabilities(
            format: format,
            canRead: true,
            canWrite: true,
            canRemoveGPS: true,
            canRemoveArtwork: false,
            canRemoveAll: true,
            writeStrategy: .imageIOInPlace,
            fields: fields
        )
    }
    
    // MARK: - Read
    
    func readMetadata(from url: URL) async throws -> MetadataDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url)
        }
        
        let format = FileDetector.detectFormat(url: url) ?? .jpg
        var doc = MetadataDocument(format: format, fileURL: url)
        
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MetadataError.readFailure("Could not initialize CGImageSource from \(url.lastPathComponent)")
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return doc
        }
        
        // 1. Image Technical Details
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            doc.technical["dimensions"] = "\(width) × \(height) px"
        }
        if let colorModel = properties[kCGImagePropertyColorModel] as? String {
            doc.technical["colorSpace"] = colorModel
        }
        if let depth = properties[kCGImagePropertyDepth] as? Int {
            doc.technical["bitDepth"] = "\(depth)-bit"
        }
        if let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool {
            doc.technical["hasAlpha"] = hasAlpha ? "Yes" : "No"
        }
        
        // 2. TIFF Properties
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let artist = tiff[kCGImagePropertyTIFFArtist] as? String { doc.common.artist = artist }
            if let copyright = tiff[kCGImagePropertyTIFFCopyright] as? String { doc.common.copyright = copyright }
            if let desc = tiff[kCGImagePropertyTIFFImageDescription] as? String { doc.common.description = desc }
            if let make = tiff[kCGImagePropertyTIFFMake] as? String { doc.common.cameraMake = make }
            if let model = tiff[kCGImagePropertyTIFFModel] as? String { doc.common.cameraModel = model }
            if let date = tiff[kCGImagePropertyTIFFDateTime] as? String { doc.common.yearString = date }
        }
        
        // 3. EXIF Properties
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let dt = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                doc.common.yearString = String(dt.prefix(4))
            }
            if let lens = exif[kCGImagePropertyExifLensModel] as? String {
                doc.common.lensModel = lens
            }
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
                doc.common.iso = first
            } else if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? Int {
                doc.common.iso = iso
            }
            if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
                doc.common.aperture = fNumber
            }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                doc.common.focalLength = focal
            }
        }
        
        // 4. IPTC Properties
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            if let headline = iptc[kCGImagePropertyIPTCHeadline] as? String { doc.common.title = headline }
            if let caption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String { doc.common.description = caption }
            if let byline = iptc[kCGImagePropertyIPTCByline] as? String { doc.common.artist = byline }
            if let copyright = iptc[kCGImagePropertyIPTCCopyrightNotice] as? String { doc.common.copyright = copyright }
        }
        
        // 5. GPS Properties
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String {
            
            let finalLat = (latRef.uppercased() == "S") ? -lat : lat
            let finalLon = (lonRef.uppercased() == "W") ? -lon : lon
            let alt = gps[kCGImagePropertyGPSAltitude] as? Double
            doc.gps = MetadataGPS(latitude: finalLat, longitude: finalLon, altitude: alt)
        }
        
        return doc
    }
    
    func read(from url: URL, format: FileFormat) async throws -> MetadataDocument {
        try await readMetadata(from: url)
    }
    
    // MARK: - Write
    
    @discardableResult
    func write(_ metadata: MetadataDocument, to url: URL) async throws -> URL {
        let res = try await writeMetadata(metadata, to: url)
        return res.outputURL
    }
    
    func removeGPS(from url: URL) async throws -> URL {
        let res = try await removeMetadata(fields: nil, removeArtwork: false, removeGPS: true, from: url)
        return res.outputURL
    }
    
    func writeMetadata(
        _ metadata: MetadataDocument,
        to url: URL
    ) async throws -> MetadataWriteResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        try await SafeMetadataWriter.performSafeWrite(on: url) { tempURL in
            try self.executeWrite(metadata: metadata, tempURL: tempURL)
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return MetadataWriteResult(outputURL: url, duration: duration)
    }
    
    private func executeWrite(metadata: MetadataDocument, tempURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(tempURL as CFURL, nil) else {
            throw MetadataError.readFailure("Failed to create image source for writing")
        }
        
        guard let utType = UTType(filenameExtension: tempURL.pathExtension) ?? metadata.format.utType else {
            throw MetadataError.unsupportedFormat(metadata.format)
        }
        
        let parent = tempURL.deletingLastPathComponent()
        let scratchOut = parent.appendingPathComponent("scratch-\(UUID().uuidString).\(tempURL.pathExtension)")
        defer { try? FileManager.default.removeItem(at: scratchOut) }
        
        guard let destination = CGImageDestinationCreateWithURL(
            scratchOut as CFURL,
            utType.identifier as CFString,
            CGImageSourceGetCount(source),
            nil
        ) else {
            throw MetadataError.writeFailure("Failed to create CGImageDestination")
        }
        
        // Build metadata dictionaries
        var mutableMetadata: [CFString: Any] = [:]
        
        // Read existing properties to preserve unedited metadata
        if let existing = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            mutableMetadata = existing
        }
        
        // 1. TIFF Dictionary
        var tiffDict = (mutableMetadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        if let artist = metadata.common.artist { tiffDict[kCGImagePropertyTIFFArtist] = artist }
        if let copyright = metadata.common.copyright { tiffDict[kCGImagePropertyTIFFCopyright] = copyright }
        if let desc = metadata.common.description { tiffDict[kCGImagePropertyTIFFImageDescription] = desc }
        if let make = metadata.common.cameraMake { tiffDict[kCGImagePropertyTIFFMake] = make }
        if let model = metadata.common.cameraModel { tiffDict[kCGImagePropertyTIFFModel] = model }
        mutableMetadata[kCGImagePropertyTIFFDictionary] = tiffDict
        
        // 2. IPTC Dictionary
        var iptcDict = (mutableMetadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        if let title = metadata.common.title { iptcDict[kCGImagePropertyIPTCHeadline] = title }
        if let desc = metadata.common.description { iptcDict[kCGImagePropertyIPTCCaptionAbstract] = desc }
        if let artist = metadata.common.artist { iptcDict[kCGImagePropertyIPTCByline] = artist }
        if let copyright = metadata.common.copyright { iptcDict[kCGImagePropertyIPTCCopyrightNotice] = copyright }
        mutableMetadata[kCGImagePropertyIPTCDictionary] = iptcDict
        
        // 3. GPS Dictionary
        if let gps = metadata.gps {
            var gpsDict: [CFString: Any] = [:]
            gpsDict[kCGImagePropertyGPSLatitude] = abs(gps.latitude)
            gpsDict[kCGImagePropertyGPSLatitudeRef] = gps.latitude >= 0 ? "N" : "S"
            gpsDict[kCGImagePropertyGPSLongitude] = abs(gps.longitude)
            gpsDict[kCGImagePropertyGPSLongitudeRef] = gps.longitude >= 0 ? "E" : "W"
            if let alt = gps.altitude {
                gpsDict[kCGImagePropertyGPSAltitude] = abs(alt)
                gpsDict[kCGImagePropertyGPSAltitudeRef] = alt >= 0 ? 0 : 1
            }
            mutableMetadata[kCGImagePropertyGPSDictionary] = gpsDict
        } else {
            mutableMetadata.removeValue(forKey: kCGImagePropertyGPSDictionary)
        }
        
        // Write all source images with preserved pixel buffers and updated metadata
        let count = CGImageSourceGetCount(source)
        for i in 0..<count {
            if let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) {
                CGImageDestinationAddImage(destination, cgImage, mutableMetadata as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(destination, source, i, mutableMetadata as CFDictionary)
            }
        }
        
        guard CGImageDestinationFinalize(destination) else {
            throw MetadataError.writeFailure("Failed to finalize image destination")
        }
        
        // Move scratch into tempURL
        try FileManager.default.removeItem(at: tempURL)
        try FileManager.default.moveItem(at: scratchOut, to: tempURL)
    }
}
