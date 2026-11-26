import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import os.log

final class ImageMetadataProvider: MetadataProvider, @unchecked Sendable {
    
    let providerName = "ImageMetadataProvider"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "ImageMetadataProvider")
    
    var supportedFormats: Set<FileFormat> {
        [
            .jpg, .png, .heic, .webp, .tiff, .bmp, .gif, .avif, .jp2, .psd, .exr, .jxl,
            .svg, .ico, .icns, .tga,
            .dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw
        ]
    }
    
    init() {}
    
    // MARK: - Capabilities
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities {
        guard supportedFormats.contains(format) else {
            return .unsupported(for: format)
        }
        
        if format == .svg || format == .psd || format.isRawImage {
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
            writeStrategy: (format == .jxl) ? .containerRewrite : .imageIOInPlace,
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

        if format == .jxl {
            let info = try JPEGXLCodec.inspect(url: url)
            doc.technical["dimensions"] = "\(info.width) × \(info.height) px"
            doc.technical["bitDepth"] = "\(info.bitsPerSample)-bit"
            doc.technical["hasAlpha"] = info.hasAlpha ? "Yes" : "No"
            doc.technical["frames"] = info.isAnimated ? "\(info.frameCount) animated" : "\(info.frameCount)"
            if info.isJPEGReconstructable {
                doc.technical["jpegReconstruction"] = "Available (Lossless JPEG Transcode)"
            }
            if let icc = info.iccData, let cs = CGColorSpace(iccData: icc as CFData), let csName = cs.name as String? {
                doc.technical["colorSpace"] = csName
            } else if info.hasICCProfile {
                doc.technical["colorSpace"] = "Embedded ICC"
            }

            let boxProps = JPEGXLCodec.parseMetadataBoxes(exifTIFF: info.exifData, xmp: info.xmpData)
            if !boxProps.isEmpty {
                populateDocument(&doc, from: boxProps)
                return doc
            }
            // Fallback to ImageIO if no explicit JXL container boxes (e.g. codestream-only)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                populateDocument(&doc, from: properties)
            }
            return doc
        }
        
        guard let inspected = ImageSourcePipeline.inspectProperties(url: url, isRAWHint: format.isRawImage) else {
            throw MetadataError.readFailure("Could not initialize CGImageSource from \(url.lastPathComponent)")
        }

        guard let properties = inspected.properties else {
            return doc
        }

        populateDocument(&doc, from: properties)
        return doc
    }

    private func populateDocument(_ doc: inout MetadataDocument, from properties: [CFString: Any]) {
        let extracted = ImageSourcePipeline.extractStructuredProperties(from: properties)

        // 1. Image Technical Details
        if let width = extracted.orientedWidth ?? extracted.pixelWidth,
           let height = extracted.orientedHeight ?? extracted.pixelHeight {
            doc.technical["dimensions"] = "\(width) × \(height) px"
        }
        if let colorModel = extracted.colorModel {
            doc.technical["colorSpace"] = colorModel
        }
        if let depth = extracted.bitDepth {
            doc.technical["bitDepth"] = "\(depth)-bit"
        }
        if let hasAlpha = extracted.hasAlpha {
            doc.technical["hasAlpha"] = hasAlpha ? "Yes" : "No"
        }

        // 2. TIFF Properties
        if let artist = extracted.artist { doc.common.artist = artist }
        if let copyright = extracted.copyright { doc.common.copyright = copyright }
        if let desc = extracted.imageDescription { doc.common.description = desc }
        if let make = extracted.make { doc.common.cameraMake = make }
        if let model = extracted.model { doc.common.cameraModel = model }
        if let date = extracted.dateTime { doc.common.yearString = date }

        // 3. EXIF Properties
        if let dt = extracted.dateTimeOriginal {
            doc.common.yearString = String(dt.prefix(4))
        }
        if let lens = extracted.lensModel {
            doc.common.lensModel = lens
        }
        if let iso = extracted.iso {
            doc.common.iso = iso
        }
        if let fNumber = extracted.aperture {
            doc.common.aperture = fNumber
        }
        if let focal = extracted.focalLength {
            doc.common.focalLength = focal
        }

        // 4. IPTC Properties
        if let headline = extracted.headline { doc.common.title = headline }
        if let caption = extracted.caption { doc.common.description = caption }
        if let byline = extracted.byline { doc.common.artist = byline }
        if let copyrightNotice = extracted.copyrightNotice { doc.common.copyright = copyrightNotice }

        // 5. GPS Properties
        if let finalLat = extracted.gpsLatitude,
           let finalLon = extracted.gpsLongitude {
            doc.gps = MetadataGPS(
                latitude: finalLat,
                longitude: finalLon,
                altitude: extracted.gpsAltitude
            )
        }
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
        if metadata.format == .jxl || tempURL.pathExtension.lowercased() == "jxl" {
            let decoded = try JPEGXLCodec.decode(url: tempURL, prefer16Bit: true, decodeAllFrames: true)
            let existing = JPEGXLCodec.parseMetadataBoxes(exifTIFF: decoded.info.exifData, xmp: decoded.info.xmpData)
            let updatedProps = updatedProperties(from: existing, metadata: metadata)

            let hasMetadataPayload = (updatedProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?.isEmpty == false
                || (updatedProps[kCGImagePropertyExifDictionary] as? [CFString: Any])?.isEmpty == false
                || (updatedProps[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?.isEmpty == false
                || (updatedProps[kCGImagePropertyGPSDictionary] as? [CFString: Any])?.isEmpty == false

            let serialized = hasMetadataPayload
                ? JPEGXLCodec.serializeMetadataBoxes(from: updatedProps)
                : (exifTIFF: nil, xmp: nil)

            let encodeFrames = decoded.frames.map { JXLEncodeFrame(image: $0.image, duration: $0.duration) }
            let options = JXLEncodeOptions(
                lossless: true,
                quality: 1.0,
                effort: 7,
                bitDepth: decoded.info.bitsPerSample > 8 ? 16 : 8,
                preserveAlpha: decoded.info.hasAlpha,
                useContainer: true,
                numLoops: decoded.info.numLoops,
                iccProfileData: decoded.info.iccData,
                exifData: serialized.exifTIFF,
                xmpData: serialized.xmp
            )
            let jxlOut = try JPEGXLCodec.encode(frames: encodeFrames, options: options)
            try jxlOut.write(to: tempURL, options: .atomic)
            return
        }

        guard let source = CGImageSourceCreateWithURL(tempURL as CFURL, nil) else {
            throw MetadataError.readFailure("Failed to create image source for writing")
        }
        
        guard let utType = UTType(filenameExtension: tempURL.pathExtension) ?? metadata.format.utType else {
            throw MetadataError.unsupportedFormat(metadata.format)
        }
        
        let parent = tempURL.deletingLastPathComponent()
        let scratchOut = parent.appendingPathComponent("scratch-\(UUID().uuidString).\(tempURL.pathExtension)")
        defer { try? FileManager.default.removeItem(at: scratchOut) }

        if metadata.isStrippedAll {
            if let stripDest = CGImageDestinationCreateWithURL(
                scratchOut as CFURL,
                utType.identifier as CFString,
                CGImageSourceGetCount(source),
                nil
            ) {
                let stripOptions: [CFString: Any] = [
                    kCGImageMetadataShouldExcludeXMP: true,
                    kCGImageMetadataShouldExcludeGPS: true,
                    kCGImagePropertyExifDictionary: kCFNull!,
                    kCGImagePropertyTIFFDictionary: kCFNull!,
                    kCGImagePropertyGPSDictionary: kCFNull!,
                    kCGImagePropertyIPTCDictionary: kCFNull!,
                    kCGImagePropertyExifAuxDictionary: kCFNull!,
                    kCGImagePropertyMakerAppleDictionary: kCFNull!,
                    kCGImagePropertyMakerCanonDictionary: kCFNull!,
                    kCGImagePropertyMakerNikonDictionary: kCFNull!
                ]
                if CGImageDestinationCopyImageSource(stripDest, source, stripOptions as CFDictionary, nil) {
                    try FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.moveItem(at: scratchOut, to: tempURL)
                    return
                }
            }
        }
        
        guard let destination = CGImageDestinationCreateWithURL(
            scratchOut as CFURL,
            utType.identifier as CFString,
            CGImageSourceGetCount(source),
            nil
        ) else {
            throw MetadataError.writeFailure("Failed to create CGImageDestination")
        }
        
        let existing = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let mutableMetadata: [CFString: Any]
        if metadata.isStrippedAll {
            mutableMetadata = [
                kCGImageMetadataShouldExcludeXMP: true,
                kCGImageMetadataShouldExcludeGPS: true
            ]
        } else {
            mutableMetadata = updatedProperties(from: existing, metadata: metadata)
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

    private func updatedProperties(from existing: [CFString: Any], metadata: MetadataDocument) -> [CFString: Any] {
        var mutableMetadata = existing

        func setOrRemove(_ value: Any?, key: CFString, in dict: inout [CFString: Any]) {
            if let value {
                if let str = value as? String, str.isEmpty {
                    dict.removeValue(forKey: key)
                } else {
                    dict[key] = value
                }
            } else {
                dict.removeValue(forKey: key)
            }
        }

        // 1. TIFF Dictionary
        var tiffDict = (mutableMetadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        setOrRemove(metadata.common.artist, key: kCGImagePropertyTIFFArtist, in: &tiffDict)
        setOrRemove(metadata.common.copyright, key: kCGImagePropertyTIFFCopyright, in: &tiffDict)
        setOrRemove(metadata.common.description, key: kCGImagePropertyTIFFImageDescription, in: &tiffDict)
        setOrRemove(metadata.common.cameraMake, key: kCGImagePropertyTIFFMake, in: &tiffDict)
        setOrRemove(metadata.common.cameraModel, key: kCGImagePropertyTIFFModel, in: &tiffDict)
        if tiffDict.isEmpty {
            mutableMetadata.removeValue(forKey: kCGImagePropertyTIFFDictionary)
        } else {
            mutableMetadata[kCGImagePropertyTIFFDictionary] = tiffDict
        }

        // 2. EXIF Dictionary
        var exifDict = (mutableMetadata[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        setOrRemove(metadata.common.lensModel, key: kCGImagePropertyExifLensModel, in: &exifDict)
        if let iso = metadata.common.iso {
            exifDict[kCGImagePropertyExifISOSpeedRatings] = [iso]
        } else {
            exifDict.removeValue(forKey: kCGImagePropertyExifISOSpeedRatings)
        }
        setOrRemove(metadata.common.aperture, key: kCGImagePropertyExifFNumber, in: &exifDict)
        setOrRemove(metadata.common.focalLength, key: kCGImagePropertyExifFocalLength, in: &exifDict)
        if exifDict.isEmpty {
            mutableMetadata.removeValue(forKey: kCGImagePropertyExifDictionary)
        } else {
            mutableMetadata[kCGImagePropertyExifDictionary] = exifDict
        }

        // 3. IPTC Dictionary
        var iptcDict = (mutableMetadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
        setOrRemove(metadata.common.title, key: kCGImagePropertyIPTCHeadline, in: &iptcDict)
        setOrRemove(metadata.common.description, key: kCGImagePropertyIPTCCaptionAbstract, in: &iptcDict)
        setOrRemove(metadata.common.artist, key: kCGImagePropertyIPTCByline, in: &iptcDict)
        setOrRemove(metadata.common.copyright, key: kCGImagePropertyIPTCCopyrightNotice, in: &iptcDict)
        if let kw = metadata.common.keywords, !kw.isEmpty {
            iptcDict[kCGImagePropertyIPTCKeywords] = kw
        } else {
            iptcDict.removeValue(forKey: kCGImagePropertyIPTCKeywords)
        }
        if iptcDict.isEmpty {
            mutableMetadata.removeValue(forKey: kCGImagePropertyIPTCDictionary)
        } else {
            mutableMetadata[kCGImagePropertyIPTCDictionary] = iptcDict
        }

        // 4. GPS Dictionary
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

        return mutableMetadata
    }
}
