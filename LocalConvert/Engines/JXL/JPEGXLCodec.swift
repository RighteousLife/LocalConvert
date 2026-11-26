import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - Errors

enum JPEGXLError: LocalizedError, Sendable {
    case invalidInput(String)
    case decodeFailed(String)
    case encodeFailed(String)
    case unsupportedJPEGTranscode(String)
    case notJPEGReconstructable(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return msg
        case .decodeFailed(let msg): return msg
        case .encodeFailed(let msg): return msg
        case .unsupportedJPEGTranscode(let msg): return msg
        case .notJPEGReconstructable(let msg): return msg
        }
    }
}

// MARK: - Models

struct JXLImageMetadataInfo: Sendable, Equatable {
    let width: Int
    let height: Int
    let bitsPerSample: Int
    let alphaBits: Int
    let numColorChannels: Int
    let frameCount: Int
    let isAnimated: Bool
    let numLoops: Int
    let isJPEGReconstructable: Bool
    let isContainer: Bool
    let hasICCProfile: Bool
    let hasExif: Bool
    let hasXMP: Bool
    let iccData: Data?
    let exifData: Data?
    let xmpData: Data?

    var hasAlpha: Bool { alphaBits > 0 }
}

struct JXLDecodedFrame: Sendable {
    let image: CGImage
    let duration: TimeInterval
}

struct JXLDecodedImage: Sendable {
    let info: JXLImageMetadataInfo
    let frames: [JXLDecodedFrame]

    var primaryImage: CGImage? { frames.first?.image }
}

struct JXLEncodeFrame: Sendable {
    let image: CGImage
    let duration: TimeInterval

    init(image: CGImage, duration: TimeInterval = 0.1) {
        self.image = image
        self.duration = duration
    }
}

struct JXLEncodeOptions: Sendable, Equatable {
    var lossless: Bool
    var quality: Double          // 0.0 ... 1.0 (maps via JxlEncoderDistanceFromQuality)
    var distance: Double?        // Optional explicit Butteraugli distance (0.0 ... 25.0); overrides quality when set
    var effort: Int              // 1 ... 9 (default 7)
    var bitDepth: Int            // 8 or 16
    var preserveAlpha: Bool
    var useContainer: Bool
    var numLoops: Int            // 0 = infinite
    var iccProfileData: Data?
    var exifData: Data?
    var xmpData: Data?

    init(
        lossless: Bool = false,
        quality: Double = 0.90,
        distance: Double? = nil,
        effort: Int = 7,
        bitDepth: Int = 8,
        preserveAlpha: Bool = true,
        useContainer: Bool = true,
        numLoops: Int = 0,
        iccProfileData: Data? = nil,
        exifData: Data? = nil,
        xmpData: Data? = nil
    ) {
        self.lossless = lossless
        self.quality = quality
        self.distance = distance
        self.effort = effort
        self.bitDepth = bitDepth
        self.preserveAlpha = preserveAlpha
        self.useContainer = useContainer
        self.numLoops = numLoops
        self.iccProfileData = iccProfileData
        self.exifData = exifData
        self.xmpData = xmpData
    }
}

// MARK: - Codec

/// High-level Swift wrapper over official libjxl v0.13.0 (via JXLBridge).
enum JPEGXLCodec {

    private static let logger = Logger(subsystem: "com.localconvert.app", category: "JPEGXLCodec")

    static var libraryVersion: String {
        String(cString: JXLBridgeVersion())
    }

    static func validateSignature(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return JXLBridgeValidate(base, ptr.count) != 0
        }
    }

    // MARK: - Inspect & Decode

    static func inspect(data: Data) throws -> JXLImageMetadataInfo {
        guard !data.isEmpty else {
            throw JPEGXLError.invalidInput("JPEG XL data is empty.")
        }
        var result = JXLBridgeDecodedResult()
        defer { JXLBridgeFreeDecodedResult(&result) }
        var errBuf = [CChar](repeating: 0, count: 512)

        let ok = data.withUnsafeBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return JXLBridgeInspect(base, ptr.count, &result, &errBuf, errBuf.count)
        }
        guard ok != 0 else {
            throw JPEGXLError.decodeFailed(stringFromErrBuf(errBuf, fallback: "Failed to inspect JPEG XL file."))
        }
        return makeInfo(from: result)
    }

    static func inspect(url: URL) throws -> JXLImageMetadataInfo {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try inspect(data: data)
    }

    static func decode(
        data: Data,
        prefer16Bit: Bool = true,
        decodeAllFrames: Bool = true
    ) throws -> JXLDecodedImage {
        guard !data.isEmpty else {
            throw JPEGXLError.invalidInput("JPEG XL data is empty.")
        }
        var result = JXLBridgeDecodedResult()
        defer { JXLBridgeFreeDecodedResult(&result) }
        var errBuf = [CChar](repeating: 0, count: 512)

        let ok = data.withUnsafeBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return JXLBridgeDecode(
                base,
                ptr.count,
                prefer16Bit ? 1 : 0,
                decodeAllFrames ? 1 : 0,
                &result,
                &errBuf,
                errBuf.count
            )
        }
        guard ok != 0 else {
            throw JPEGXLError.decodeFailed(stringFromErrBuf(errBuf, fallback: "Failed to decode JPEG XL data."))
        }

        let info = makeInfo(from: result)
        let colorSpace: CGColorSpace = {
            if let icc = info.iccData, let cs = CGColorSpace(iccData: icc as CFData) {
                return cs
            }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()

        var frames: [JXLDecodedFrame] = []
        if let rawFrames = result.frames {
            for i in 0..<result.frame_count {
                let raw = rawFrames[i]
                guard let pixelPtr = raw.pixel_data, raw.pixel_size > 0 else { continue }
                var rawData = Data(bytes: pixelPtr, count: raw.pixel_size)
                guard let cgImage = buildCGImage(
                    fromStraightRGBA: &rawData,
                    width: Int(raw.width),
                    height: Int(raw.height),
                    bitsPerSample: Int(raw.bits_per_sample),
                    hasAlpha: info.hasAlpha,
                    colorSpace: colorSpace
                ) else {
                    throw JPEGXLError.decodeFailed("Failed to construct CGImage from decoded JPEG XL buffer.")
                }
                let duration = raw.duration_ms > 0 ? TimeInterval(raw.duration_ms) / 1000.0 : 0.1
                frames.append(JXLDecodedFrame(image: cgImage, duration: duration))
            }
        }

        guard !frames.isEmpty else {
            throw JPEGXLError.decodeFailed("Decoded JPEG XL contained zero image frames.")
        }

        return JXLDecodedImage(info: info, frames: frames)
    }

    static func decode(
        url: URL,
        prefer16Bit: Bool = true,
        decodeAllFrames: Bool = true
    ) throws -> JXLDecodedImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(data: data, prefer16Bit: prefer16Bit, decodeAllFrames: decodeAllFrames)
    }

    // MARK: - Encode Static & Animated

    static func encode(image: CGImage, options: JXLEncodeOptions = JXLEncodeOptions()) throws -> Data {
        try encode(frames: [JXLEncodeFrame(image: image, duration: 0)], options: options)
    }

    static func encode(frames: [JXLEncodeFrame], options: JXLEncodeOptions = JXLEncodeOptions()) throws -> Data {
        guard !frames.isEmpty else {
            throw JPEGXLError.encodeFailed("Cannot encode zero frames to JPEG XL.")
        }

        let targetBits = options.bitDepth >= 16 ? 16 : 8
        let shouldEncodeAlpha = options.preserveAlpha && frames.contains(where: { imageHasAlpha($0.image) })

        var frameBuffers: [Data] = []
        var bridgeFrames: [JXLBridgeEncodeFrameInput] = []
        frameBuffers.reserveCapacity(frames.count)

        let targetColorSpace: CGColorSpace? = options.iccProfileData.flatMap { CGColorSpace(iccData: $0 as CFData) }
            ?? frames[0].image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)

        let effectiveICCData: Data? = {
            if let explicit = options.iccProfileData, !explicit.isEmpty {
                return explicit
            }
            if let cs = targetColorSpace, let icc = cs.copyICCData() as Data? {
                return icc
            }
            return nil
        }()

        for frame in frames {
            let buffer = try extractPixels(
                from: frame.image,
                bitsPerSample: targetBits,
                includeAlpha: shouldEncodeAlpha,
                colorSpace: targetColorSpace
            )
            frameBuffers.append(buffer)
        }

        for i in 0..<frames.count {
            let durationMs = UInt32(max(1, Int((frames[i].duration * 1000.0).rounded())))
            bridgeFrames.append(JXLBridgeEncodeFrameInput(
                pixel_data: nil,
                pixel_size: frameBuffers[i].count,
                width: UInt32(frames[i].image.width),
                height: UInt32(frames[i].image.height),
                duration_ms: frames.count > 1 ? durationMs : 0
            ))
        }

        var outPtr: UnsafeMutablePointer<UInt8>?
        var outSize: Int = 0
        var errBuf = [CChar](repeating: 0, count: 512)

        let quality0to100 = Float(max(0.0, min(1.0, options.quality)) * 100.0)
        let distanceArg = Float(options.distance ?? -1.0)

        let ok: Int32 = withPinnedFrameBuffers(frameBuffers, baseInputs: bridgeFrames) { pinnedInputs in
            withOptionalBytes(effectiveICCData) { iccPtr, iccLen in
                withOptionalBytes(options.exifData) { exifPtr, exifLen in
                    withOptionalBytes(options.xmpData) { xmpPtr, xmpLen in
                        JXLBridgeEncode(
                            pinnedInputs,
                            pinnedInputs.count,
                            options.lossless ? 1 : 0,
                            distanceArg,
                            quality0to100,
                            Int32(max(1, min(9, options.effort))),
                            Int32(targetBits),
                            shouldEncodeAlpha ? 1 : 0,
                            options.useContainer ? 1 : 0,
                            iccPtr,
                            iccLen,
                            exifPtr,
                            exifLen,
                            xmpPtr,
                            xmpLen,
                            UInt32(max(0, options.numLoops)),
                            1000,
                            1,
                            &outPtr,
                            &outSize,
                            &errBuf,
                            errBuf.count
                        )
                    }
                }
            }
        }

        defer {
            if let ptr = outPtr {
                JXLBridgeFreeBuffer(ptr)
            }
        }

        guard ok != 0, let validPtr = outPtr, outSize > 0 else {
            throw JPEGXLError.encodeFailed(stringFromErrBuf(errBuf, fallback: "Failed to encode JPEG XL output."))
        }

        return Data(bytes: validPtr, count: outSize)
    }

    // MARK: - Lossless JPEG Transcoding & Reconstruction

    static func transcodeJPEG(jpegData: Data, effort: Int = 7, storeJPEGMetadata: Bool = true) throws -> Data {
        guard !jpegData.isEmpty else {
            throw JPEGXLError.invalidInput("JPEG data is empty.")
        }
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outSize: Int = 0
        var errBuf = [CChar](repeating: 0, count: 512)

        let ok = jpegData.withUnsafeBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return JXLBridgeTranscodeJPEG(
                base,
                ptr.count,
                Int32(max(1, min(9, effort))),
                storeJPEGMetadata ? 1 : 0,
                &outPtr,
                &outSize,
                &errBuf,
                errBuf.count
            )
        }

        defer {
            if let ptr = outPtr {
                JXLBridgeFreeBuffer(ptr)
            }
        }

        guard ok != 0, let validPtr = outPtr, outSize > 0 else {
            throw JPEGXLError.unsupportedJPEGTranscode(
                stringFromErrBuf(errBuf, fallback: "Could not losslessly transcode JPEG to JPEG XL.")
            )
        }
        return Data(bytes: validPtr, count: outSize)
    }

    static func reconstructJPEG(jxlData: Data) throws -> Data {
        guard !jxlData.isEmpty else {
            throw JPEGXLError.invalidInput("JPEG XL data is empty.")
        }
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outSize: Int = 0
        var errBuf = [CChar](repeating: 0, count: 512)

        let ok = jxlData.withUnsafeBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return JXLBridgeReconstructJPEG(base, ptr.count, &outPtr, &outSize, &errBuf, errBuf.count)
        }

        defer {
            if let ptr = outPtr {
                JXLBridgeFreeBuffer(ptr)
            }
        }

        guard ok != 0, let validPtr = outPtr, outSize > 0 else {
            throw JPEGXLError.notJPEGReconstructable(
                stringFromErrBuf(errBuf, fallback: "JPEG XL file does not support lossless JPEG reconstruction.")
            )
        }
        return Data(bytes: validPtr, count: outSize)
    }

    // MARK: - Container Metadata Serialization Helpers (ImageIO <-> JXL Exif/XMP Boxes)

    /// Serializes macOS CGImageProperties dictionary (TIFF/EXIF/IPTC/GPS) into raw EXIF TIFF bytes (for JXL Exif box) and XMP Data (for JXL xml box).
    static func serializeMetadataBoxes(from properties: [CFString: Any]) -> (exifTIFF: Data?, xmp: Data?) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let tinyImg = ctx.makeImage() else {
            return (nil, nil)
        }

        let jpegOut = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(jpegOut, UTType.jpeg.identifier as CFString, 1, nil) else {
            return (nil, nil)
        }
        CGImageDestinationAddImage(dest, tinyImg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return (nil, nil)
        }

        let jpegData = jpegOut as Data
        let exifTIFF = extractExifTIFFFromJPEG(jpegData)

        var xmpData: Data?
        if let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
           let cgMeta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            xmpData = CGImageMetadataCreateXMPData(cgMeta, nil) as Data?
        }

        return (exifTIFF, xmpData)
    }

    /// Parses JXL Exif TIFF box bytes and/or XMP XML bytes back into a standard ImageIO properties dictionary.
    static func parseMetadataBoxes(exifTIFF: Data?, xmp: Data?) -> [CFString: Any] {
        var result: [CFString: Any] = [:]

        if let exifTIFF, !exifTIFF.isEmpty, let wrappedJPEG = wrapExifTIFFInDummyJPEG(exifTIFF),
           let src = CGImageSourceCreateWithData(wrappedJPEG as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for (k, v) in props {
                if k != kCGImagePropertyPixelWidth && k != kCGImagePropertyPixelHeight
                    && k != kCGImagePropertyJFIFDictionary {
                    result[k] = v
                }
            }
        }

        if let xmp, !xmp.isEmpty,
           let cgMeta = CGImageMetadataCreateFromXMPData(xmp as CFData),
           let tags = CGImageMetadataCopyTags(cgMeta) as? [CGImageMetadataTag] {
            var iptc = (result[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            var tiff = (result[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]

            for tag in tags {
                let ns = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
                let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
                let value = CGImageMetadataTagCopyValue(tag)

                if ns == "http://purl.org/dc/elements/1.1/" {
                    if name == "title", let str = extractXMPString(value), iptc[kCGImagePropertyIPTCHeadline] == nil {
                        iptc[kCGImagePropertyIPTCHeadline] = str
                    } else if name == "description", let str = extractXMPString(value), tiff[kCGImagePropertyTIFFImageDescription] == nil {
                        tiff[kCGImagePropertyTIFFImageDescription] = str
                    } else if name == "creator", let str = extractXMPString(value), tiff[kCGImagePropertyTIFFArtist] == nil {
                        tiff[kCGImagePropertyTIFFArtist] = str
                    } else if name == "rights", let str = extractXMPString(value), tiff[kCGImagePropertyTIFFCopyright] == nil {
                        tiff[kCGImagePropertyTIFFCopyright] = str
                    } else if name == "subject", let list = extractXMPStringArray(value), !list.isEmpty {
                        iptc[kCGImagePropertyIPTCKeywords] = list
                    }
                } else if ns == "http://ns.adobe.com/photoshop/1.0/" {
                    if name == "Headline", let str = extractXMPString(value) {
                        iptc[kCGImagePropertyIPTCHeadline] = str
                    }
                }
            }

            if !iptc.isEmpty { result[kCGImagePropertyIPTCDictionary] = iptc }
            if !tiff.isEmpty { result[kCGImagePropertyTIFFDictionary] = tiff }
        }

        return result
    }

    // MARK: - Pixel Conversion Helpers

    private static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return false
        }
    }

    private static func extractDirectIntegerPixels(
        from image: CGImage,
        targetColorSpace: CGColorSpace,
        bitsPerSample: Int,
        includeAlpha: Bool
    ) -> Data? {
        guard !image.bitmapInfo.contains(.floatComponents),
              image.bitsPerComponent == bitsPerSample,
              (bitsPerSample == 8 || bitsPerSample == 16),
              image.colorSpace?.model == .rgb,
              (image.colorSpace?.name != nil && image.colorSpace?.name == targetColorSpace.name) ||
                (image.colorSpace?.copyICCData() as Data?) == (targetColorSpace.copyICCData() as Data?) else {
            return nil
        }

        let channelsPerPixel = image.bitsPerPixel / bitsPerSample
        guard channelsPerPixel == 3 || channelsPerPixel == 4,
              let cfData = image.dataProvider?.data else {
            return nil
        }
        let srcData = cfData as Data
        let width = image.width
        let height = image.height
        let srcBytesPerRow = image.bytesPerRow
        guard srcData.count >= (height - 1) * srcBytesPerRow + width * channelsPerPixel * (bitsPerSample / 8) else {
            return nil
        }

        let outChannels = includeAlpha ? 4 : 3
        let alphaInfo = image.alphaInfo
        let isAlphaFirst = (alphaInfo == .first || alphaInfo == .premultipliedFirst || alphaInfo == .noneSkipFirst)
        let isPremul = (alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast)
        let hasValidAlpha = !(alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast)
        let isBig16 = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Big
        let isLittle16 = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little

        var out = Data(count: width * height * outChannels * (bitsPerSample / 8))
        srcData.withUnsafeBytes { srcRaw in
            out.withUnsafeMutableBytes { dstRaw in
                guard let srcBase = srcRaw.baseAddress, let dstBase = dstRaw.baseAddress else { return }
                if bitsPerSample == 8 {
                    let sPtr = srcBase.assumingMemoryBound(to: UInt8.self)
                    let dPtr = dstBase.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<height {
                        let rowBase = y * srcBytesPerRow
                        for x in 0..<width {
                            let sOff = rowBase + x * channelsPerPixel
                            var r: UInt8; var g: UInt8; var b: UInt8; var a: UInt8 = 255
                            if channelsPerPixel == 3 {
                                r = sPtr[sOff]; g = sPtr[sOff + 1]; b = sPtr[sOff + 2]
                            } else if isAlphaFirst {
                                a = hasValidAlpha ? sPtr[sOff] : 255
                                r = sPtr[sOff + 1]; g = sPtr[sOff + 2]; b = sPtr[sOff + 3]
                            } else {
                                r = sPtr[sOff]; g = sPtr[sOff + 1]; b = sPtr[sOff + 2]
                                a = hasValidAlpha ? sPtr[sOff + 3] : 255
                            }
                            if isPremul && a > 0 && a < 255 {
                                r = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                                g = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                                b = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
                            }
                            let dOff = (y * width + x) * outChannels
                            dPtr[dOff] = r; dPtr[dOff + 1] = g; dPtr[dOff + 2] = b
                            if includeAlpha { dPtr[dOff + 3] = a }
                        }
                    }
                } else {
                    let dPtr = dstBase.assumingMemoryBound(to: UInt16.self)
                    func readU16(_ byteOffset: Int) -> UInt16 {
                        let lo = UInt16(srcBase.load(fromByteOffset: byteOffset, as: UInt8.self))
                        let hi = UInt16(srcBase.load(fromByteOffset: byteOffset + 1, as: UInt8.self))
                        if isBig16 { return (lo << 8) | hi }
                        if isLittle16 { return (hi << 8) | lo }
                        return srcBase.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self)
                    }
                    for y in 0..<height {
                        let rowBase = y * srcBytesPerRow
                        for x in 0..<width {
                            let sOff = rowBase + x * channelsPerPixel * 2
                            var r: UInt16; var g: UInt16; var b: UInt16; var a: UInt16 = 65535
                            if channelsPerPixel == 3 {
                                r = readU16(sOff); g = readU16(sOff + 2); b = readU16(sOff + 4)
                            } else if isAlphaFirst {
                                a = hasValidAlpha ? readU16(sOff) : 65535
                                r = readU16(sOff + 2); g = readU16(sOff + 4); b = readU16(sOff + 6)
                            } else {
                                r = readU16(sOff); g = readU16(sOff + 2); b = readU16(sOff + 4)
                                a = hasValidAlpha ? readU16(sOff + 6) : 65535
                            }
                            if isPremul && a > 0 && a < 65535 {
                                r = UInt16(min(65535, (UInt32(r) * 65535 + UInt32(a) / 2) / UInt32(a)))
                                g = UInt16(min(65535, (UInt32(g) * 65535 + UInt32(a) / 2) / UInt32(a)))
                                b = UInt16(min(65535, (UInt32(b) * 65535 + UInt32(a) / 2) / UInt32(a)))
                            }
                            let dOff = (y * width + x) * outChannels
                            dPtr[dOff] = r; dPtr[dOff + 1] = g; dPtr[dOff + 2] = b
                            if includeAlpha { dPtr[dOff + 3] = a }
                        }
                    }
                }
            }
        }
        return out
    }

    private static func extractPixels(
        from image: CGImage,
        bitsPerSample: Int,
        includeAlpha: Bool,
        colorSpace: CGColorSpace?
    ) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw JPEGXLError.encodeFailed("Image has invalid dimensions (\(width)x\(height)).")
        }

        let targetCS: CGColorSpace = {
            if let cs = colorSpace, cs.model == .rgb {
                return cs
            }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()

        if let direct = extractDirectIntegerPixels(
            from: image,
            targetColorSpace: targetCS,
            bitsPerSample: bitsPerSample,
            includeAlpha: includeAlpha
        ) {
            return direct
        }

        // Draw into premultiplied RGBA (8-bit or 16-bit native endian)
        let bytesPerComponent = bitsPerSample == 16 ? 2 : 1
        let bytesPerPixel4 = 4 * bytesPerComponent
        let bytesPerRow = width * bytesPerPixel4
        var rgba = Data(count: bytesPerRow * height)

        let byteOrder16Host: UInt32 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue
        let bitmapInfo: UInt32 = if bitsPerSample == 16 {
            byteOrder16Host | CGImageAlphaInfo.premultipliedLast.rawValue
        } else {
            CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        }

        let candidateColorSpaces: [CGColorSpace] = [
            targetCS,
            CGColorSpace(name: CGColorSpace.itur_2020),
            CGColorSpace(name: CGColorSpace.displayP3),
            CGColorSpace(name: CGColorSpace.sRGB)
        ].compactMap { $0 }

        let drawn = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            for cs in candidateColorSpaces {
                if let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: bitsPerSample,
                    bytesPerRow: bytesPerRow,
                    space: cs,
                    bitmapInfo: bitmapInfo
                ) {
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    return true
                }
            }
            return false
        }

        guard drawn else {
            throw JPEGXLError.encodeFailed("Failed to rasterize image for JPEG XL encoding.")
        }

        let pixelCount = width * height
        if bitsPerSample == 8 {
            if includeAlpha {
                // Unpremultiply RGBA8 into straight alpha expected by libjxl
                rgba.withUnsafeMutableBytes { ptr in
                    guard let p = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for idx in 0..<pixelCount {
                        let o = idx * 4
                        let a = p[o + 3]
                        if a > 0 && a < 255 {
                            p[o]     = UInt8(min(255, (Int(p[o]) * 255 + Int(a) / 2) / Int(a)))
                            p[o + 1] = UInt8(min(255, (Int(p[o + 1]) * 255 + Int(a) / 2) / Int(a)))
                            p[o + 2] = UInt8(min(255, (Int(p[o + 2]) * 255 + Int(a) / 2) / Int(a)))
                        }
                    }
                }
                return rgba
            } else {
                // Pack tightly to RGB8 (3 channels)
                var rgb = Data(count: pixelCount * 3)
                rgba.withUnsafeBytes { srcPtr in
                    rgb.withUnsafeMutableBytes { dstPtr in
                        guard let src = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                              let dst = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                        for idx in 0..<pixelCount {
                            dst[idx * 3]     = src[idx * 4]
                            dst[idx * 3 + 1] = src[idx * 4 + 1]
                            dst[idx * 3 + 2] = src[idx * 4 + 2]
                        }
                    }
                }
                return rgb
            }
        } else {
            if includeAlpha {
                rgba.withUnsafeMutableBytes { ptr in
                    guard let p = ptr.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
                    for idx in 0..<pixelCount {
                        let o = idx * 4
                        let a = p[o + 3]
                        if a > 0 && a < 65535 {
                            p[o]     = UInt16(min(65535, (UInt32(p[o]) * 65535 + UInt32(a) / 2) / UInt32(a)))
                            p[o + 1] = UInt16(min(65535, (UInt32(p[o + 1]) * 65535 + UInt32(a) / 2) / UInt32(a)))
                            p[o + 2] = UInt16(min(65535, (UInt32(p[o + 2]) * 65535 + UInt32(a) / 2) / UInt32(a)))
                        }
                    }
                }
                return rgba
            } else {
                var rgb = Data(count: pixelCount * 3 * 2)
                rgba.withUnsafeBytes { srcPtr in
                    rgb.withUnsafeMutableBytes { dstPtr in
                        guard let src = srcPtr.baseAddress?.assumingMemoryBound(to: UInt16.self),
                              let dst = dstPtr.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
                        for idx in 0..<pixelCount {
                            dst[idx * 3]     = src[idx * 4]
                            dst[idx * 3 + 1] = src[idx * 4 + 1]
                            dst[idx * 3 + 2] = src[idx * 4 + 2]
                        }
                    }
                }
                return rgb
            }
        }
    }

    private static func buildCGImage(
        fromStraightRGBA mutable: inout Data,
        width: Int,
        height: Int,
        bitsPerSample: Int,
        hasAlpha: Bool,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let pixelCount = width * height

        if hasAlpha {
            if bitsPerSample == 16 {
                mutable.withUnsafeMutableBytes { ptr in
                    guard let p = ptr.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
                    for idx in 0..<pixelCount {
                        let o = idx * 4
                        let a = p[o + 3]
                        if a == 0 {
                            p[o] = 0; p[o + 1] = 0; p[o + 2] = 0
                        } else if a < 65535 {
                            p[o]     = UInt16((UInt32(p[o]) * UInt32(a) + 32767) / 65535)
                            p[o + 1] = UInt16((UInt32(p[o + 1]) * UInt32(a) + 32767) / 65535)
                            p[o + 2] = UInt16((UInt32(p[o + 2]) * UInt32(a) + 32767) / 65535)
                        }
                    }
                }
            } else {
                mutable.withUnsafeMutableBytes { ptr in
                    guard let p = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    for idx in 0..<pixelCount {
                        let o = idx * 4
                        let a = p[o + 3]
                        if a == 0 {
                            p[o] = 0; p[o + 1] = 0; p[o + 2] = 0
                        } else if a < 255 {
                            p[o]     = UInt8((Int(p[o]) * Int(a) + 127) / 255)
                            p[o + 1] = UInt8((Int(p[o + 1]) * Int(a) + 127) / 255)
                            p[o + 2] = UInt8((Int(p[o + 2]) * Int(a) + 127) / 255)
                        }
                    }
                }
            }
        }

        let targetCS: CGColorSpace = colorSpace.model == .rgb
            ? colorSpace
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())

        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        let byteOrder16Host: UInt32 = (CFByteOrderGetCurrent() == Int(CFByteOrderLittleEndian.rawValue))
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder16Big.rawValue
        let bitmapInfo: CGBitmapInfo = if bitsPerSample == 16 {
            CGBitmapInfo(rawValue: byteOrder16Host | alphaInfo.rawValue)
        } else {
            CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | alphaInfo.rawValue)
        }

        let bytesPerRow = width * 4 * (bitsPerSample == 16 ? 2 : 1)
        guard let provider = CGDataProvider(data: mutable as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerSample,
            bitsPerPixel: 4 * bitsPerSample,
            bytesPerRow: bytesPerRow,
            space: targetCS,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - Private Utilities

    private static func makeInfo(from result: JXLBridgeDecodedResult) -> JXLImageMetadataInfo {
        let icc = (result.icc_data != nil && result.icc_size > 0)
            ? Data(bytes: result.icc_data, count: result.icc_size) : nil
        let exif = (result.exif_data != nil && result.exif_size > 0)
            ? Data(bytes: result.exif_data, count: result.exif_size) : nil
        let xmp = (result.xmp_data != nil && result.xmp_size > 0)
            ? Data(bytes: result.xmp_data, count: result.xmp_size) : nil

        return JXLImageMetadataInfo(
            width: Int(result.info.width),
            height: Int(result.info.height),
            bitsPerSample: Int(result.info.bits_per_sample),
            alphaBits: Int(result.info.alpha_bits),
            numColorChannels: Int(result.info.num_color_channels),
            frameCount: Int(result.info.frame_count),
            isAnimated: result.info.have_animation != 0,
            numLoops: Int(result.info.num_loops),
            isJPEGReconstructable: result.info.is_jpeg_reconstructable != 0,
            isContainer: result.info.is_container != 0,
            hasICCProfile: result.info.has_icc != 0,
            hasExif: result.info.has_exif != 0,
            hasXMP: result.info.has_xmp != 0,
            iccData: icc,
            exifData: exif,
            xmpData: xmp
        )
    }

    private static func stringFromErrBuf(_ buf: [CChar], fallback: String) -> String {
        let utf8Bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let trimmed = String(decoding: utf8Bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func withOptionalBytes<T>(
        _ data: Data?,
        _ body: (UnsafePointer<UInt8>?, Int) -> T
    ) -> T {
        guard let data, !data.isEmpty else {
            return body(nil, 0)
        }
        return data.withUnsafeBytes { ptr in
            body(ptr.baseAddress?.assumingMemoryBound(to: UInt8.self), ptr.count)
        }
    }

    private static func withPinnedFrameBuffers<T>(
        _ buffers: [Data],
        baseInputs: [JXLBridgeEncodeFrameInput],
        _ body: ([JXLBridgeEncodeFrameInput]) -> T
    ) -> T {
        var inputs = baseInputs
        func recurse(_ index: Int) -> T {
            if index >= buffers.count {
                return body(inputs)
            }
            return buffers[index].withUnsafeBytes { ptr in
                inputs[index].pixel_data = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                inputs[index].pixel_size = ptr.count
                return recurse(index + 1)
            }
        }
        return recurse(0)
    }

    private static func extractExifTIFFFromJPEG(_ jpegData: Data) -> Data? {
        let bytes = [UInt8](jpegData)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 < bytes.count {
            guard bytes[i] == 0xFF else { i += 1; continue }
            let marker = bytes[i + 1]
            if marker == 0xDA || marker == 0xD9 { break }
            if marker == 0x00 || (marker >= 0xD0 && marker <= 0xD8) { i += 2; continue }
            let segLen = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard segLen >= 2, i + 2 + segLen <= bytes.count else { break }
            if marker == 0xE1 && segLen > 8 {
                let header = Array(bytes[(i + 4)..<(i + 10)])
                if header == [0x45, 0x78, 0x69, 0x66, 0x00, 0x00] {
                    return Data(bytes[(i + 10)..<(i + 2 + segLen)])
                }
            }
            i += 2 + segLen
        }
        return nil
    }

    private static func wrapExifTIFFInDummyJPEG(_ exifTIFF: Data) -> Data? {
        guard exifTIFF.count >= 4, exifTIFF.count + 8 <= Int(UInt16.max) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let tinyImg = ctx.makeImage() else { return nil }

        let baseData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(baseData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, tinyImg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let baseBytes = baseData as Data
        guard baseBytes.count > 2 else { return nil }

        var wrapped = Data([0xFF, 0xD8, 0xFF, 0xE1])
        let segLen = UInt16(2 + 6 + exifTIFF.count)
        wrapped.append(UInt8(segLen >> 8))
        wrapped.append(UInt8(segLen & 0xFF))
        wrapped.append(contentsOf: [0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
        wrapped.append(exifTIFF)
        wrapped.append(baseBytes.dropFirst(2))
        return wrapped
    }

    private static func extractXMPString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let str = value as? String { return str }
        if let arr = value as? [Any], let first = arr.first {
            if let str = first as? String { return str }
            if CFGetTypeID(first as CFTypeRef) == CGImageMetadataTagGetTypeID() {
                let tag = first as! CGImageMetadataTag
                return CGImageMetadataTagCopyValue(tag) as? String
            }
        }
        return nil
    }

    private static func extractXMPStringArray(_ value: CFTypeRef?) -> [String]? {
        guard let arr = value as? [Any] else { return nil }
        var out: [String] = []
        for item in arr {
            if let str = item as? String {
                out.append(str)
            } else if CFGetTypeID(item as CFTypeRef) == CGImageMetadataTagGetTypeID() {
                let tag = item as! CGImageMetadataTag
                if let str = CGImageMetadataTagCopyValue(tag) as? String {
                    out.append(str)
                }
            }
        }
        return out
    }
}
