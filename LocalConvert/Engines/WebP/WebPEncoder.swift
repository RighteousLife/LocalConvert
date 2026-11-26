import Foundation
import CoreGraphics
import ImageIO
import Darwin
import os.log

// MARK: - WebP Encoding Mode

enum WebPEncodingMode: Sendable {
    case lossy(quality: Float)   // quality 0...100 (libwebp scale)
    case lossless
}

/// Thread-safe cooperative cancellation token checked atomically inside libwebp's progress hook.
final class WebPCancellationToken: @unchecked Sendable {
    private let flagPtr: UnsafeMutablePointer<Int32>

    init() {
        flagPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        flagPtr.initialize(to: 0)
    }

    deinit {
        flagPtr.deallocate()
    }

    var pointer: UnsafePointer<Int32> {
        UnsafePointer(flagPtr)
    }

    func cancel() {
        WebPBridgeSetCancelFlag(flagPtr, 1)
    }
}

// MARK: - WebP Encoder

/// Swift wrapper around the libwebp C bridge for encoding CGImage → WebP.
///
/// Architecture note:
/// - Development: links against Homebrew libwebp at /opt/homebrew/lib/libwebp.dylib
/// - Production (Phase 8+): bundled dylib inside LocalConvert.app/Contents/Frameworks/
///   The wrapper API remains stable; only the library search path changes.
struct WebPEncoder: Sendable {
    
    private let logger = Logger(subsystem: "com.localconvert.app", category: "WebPEncoder")
    
    // MARK: - Availability
    
    /// Returns true when the libwebp C bridge is linked and functional.
    /// This is always true at runtime because we link libwebp statically at build time.
    static var isAvailable: Bool {
        let versionPtr = WebPBridgeEncoderVersion()
        return versionPtr != nil
    }
    
    /// Returns the libwebp version string, e.g. "1.6.0"
    static var version: String {
        guard let ptr = WebPBridgeEncoderVersion() else { return "unknown" }
        return String(cString: ptr)
    }
    
    // MARK: - Encoding
    
    /// Encodes a CGImage to WebP format, returning the raw WebP file bytes.
    ///
    /// - Parameters:
    /// Encodes a CGImage to WebP format, returning the raw WebP file bytes (with optional VP8X ICCP/EXIF/XMP chunks).
    ///
    /// - Parameters:
    ///   - image:      The upright, orientation-corrected CGImage to encode.
    ///   - mode:       `.lossy(quality:)` for lossy compression, `.lossless` for lossless.
    ///   - iccProfile: Optional ICC profile bytes; falls back to the image's RGB color space ICC profile when omitted.
    ///   - exifData:   Optional raw TIFF/EXIF payload for the WebP `EXIF` chunk.
    ///   - xmpData:    Optional XMP XML payload for the WebP `XMP ` chunk.
    /// - Returns:      `Data` containing a valid WebP bitstream.
    func encode(
        image: CGImage,
        mode: WebPEncodingMode,
        iccProfile: Data? = nil,
        exifData: Data? = nil,
        xmpData: Data? = nil,
        cancelFlag: UnsafePointer<Int32>? = nil
    ) throws -> Data {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4  // RGBA
        let (stride, strideOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard width > 0, height > 0,
              !strideOverflow, stride > 0, stride <= Int(Int32.max),
              width <= Int(Int32.max), height <= Int(Int32.max) else {
            throw ConversionError.invalidInput("Image dimensions are invalid or exceed encoder limits.")
        }
        let (totalBytes, bytesOverflow) = stride.multipliedReportingOverflow(by: height)
        guard !bytesOverflow, totalBytes > 0 else {
            throw ConversionError.invalidInput("Image buffer size exceeds encoder limits.")
        }
        
        let colorSpace: CGColorSpace = (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        let isLossless: Int32
        let qualityValue: Float
        switch mode {
        case .lossy(let q):
            isLossless = 0
            qualityValue = q
        case .lossless:
            isLossless = 1
            qualityValue = 100.0
        }

        let pixelCount = width * height
        defer {
            if pixelCount >= 16_000_000 {
                malloc_zone_pressure_relief(nil, 0)
            }
        }

        let rawWebP: Data = try autoreleasepool {
            // Fast zero-context path: encode tight 8-bit RGB/RGBX/RGBA/BGRX/BGRA bitmaps directly
            // without CGContext.draw() materializing DefaultPurgeableMallocZone copies or duplicate RGBA buffers.
            if let direct = Self.detectDirectPixelFormat(for: image),
               let provider = image.dataProvider,
               let providerData = provider.data as Data? {
                let bytesPerPx = image.bitsPerPixel / 8
                let (tailRowOffset, o1) = (height - 1).multipliedReportingOverflow(by: image.bytesPerRow)
                let (tailRowBytes, o2) = width.multipliedReportingOverflow(by: bytesPerPx)
                let (minRequiredBytes, o3) = tailRowOffset.addingReportingOverflow(tailRowBytes)
                if !o1, !o2, !o3, providerData.count >= minRequiredBytes {
                    return try Self.encodePointer(
                        providerData,
                        width: width,
                        height: height,
                        stride: image.bytesPerRow,
                        pixelFormat: direct,
                        lossless: isLossless,
                        quality: qualityValue,
                        cancelFlag: cancelFlag
                    )
                }
            }

            let imageIsOpaque = (image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst)
            let bitmapAlpha: CGImageAlphaInfo = imageIsOpaque ? .noneSkipLast : .premultipliedLast
            let bitmapFlags = bitmapAlpha.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            let pixelFormat: Int32 = imageIsOpaque ? 2 : 1 // 2 = RGBX, 1 = RGBA

            guard let rawPtr = calloc(totalBytes, 1) else {
                throw ConversionError.engineExecutionFailed(
                    "Failed to allocate pixel buffer for WebP encoding.",
                    underlyingError: nil
                )
            }
            var ownsRawPtr = true
            defer {
                if ownsRawPtr {
                    free(rawPtr)
                }
            }

            do {
                guard let context = CGContext(
                    data: rawPtr,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: stride,
                    space: colorSpace,
                    bitmapInfo: bitmapFlags
                ) else {
                    throw ConversionError.engineExecutionFailed(
                        "Failed to create pixel rendering context for WebP encoding.",
                        underlyingError: nil
                    )
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }

            let uint8Ptr = rawPtr.assumingMemoryBound(to: UInt8.self)
            if !imageIsOpaque {
                unpremultiplyAlphaInPlace(rgba: uint8Ptr, width: width, height: height, stride: stride)
            }

            // Transfer ownership to C bridge so rawPtr is freed immediately after libwebp imports
            // pixels into WebPPicture (before WebPEncode allocates internal encoder tables).
            ownsRawPtr = false
            return try Self.encodeBufferPointer(
                uint8Ptr,
                width: width,
                height: height,
                stride: stride,
                pixelFormat: pixelFormat,
                lossless: isLossless,
                quality: qualityValue,
                freePixelsAfterImport: true,
                cancelFlag: cancelFlag
            )
        }

        let effectiveICC: Data? = {
            if let iccProfile, !iccProfile.isEmpty { return iccProfile }
            if let copy = colorSpace.copyICCData() as Data?, !copy.isEmpty { return copy }
            return nil
        }()
        let normalizedEXIF = Self.normalizeEXIFPayload(exifData)
        let normalizedXMP = (xmpData?.isEmpty == false) ? xmpData : nil

        if effectiveICC != nil || normalizedEXIF != nil || normalizedXMP != nil {
            return Self.muxContainerIfNeeded(
                rawWebP: rawWebP,
                width: width,
                height: height,
                hasAlpha: WebPEncoder.hasAlpha(rawWebP),
                iccProfile: effectiveICC,
                exifData: normalizedEXIF,
                xmpData: normalizedXMP
            )
        }
        return rawWebP
    }

    private static func normalizeEXIFPayload(_ data: Data?) -> Data? {
        guard var data, !data.isEmpty else { return nil }
        let exifHeader = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
        if data.count > 6 && data.prefix(6) == exifHeader {
            data = data.dropFirst(6)
        }
        return data.isEmpty ? nil : data
    }

    private static func muxContainerIfNeeded(
        rawWebP: Data,
        width: Int,
        height: Int,
        hasAlpha: Bool,
        iccProfile: Data?,
        exifData: Data?,
        xmpData: Data?
    ) -> Data {
        guard rawWebP.count >= 20,
              rawWebP.prefix(4) == Data("RIFF".utf8),
              rawWebP.subdata(in: 8..<12) == Data("WEBP".utf8) else {
            return rawWebP
        }

        var imageChunks: [(fourCC: Data, payload: Data)] = []
        var detectedAlpha = hasAlpha
        var offset = 12
        let base = rawWebP.startIndex
        let totalCount = rawWebP.count

        while offset + 8 <= totalCount {
            let chunkHeaderStart = base + offset
            let fourCC = rawWebP.subdata(in: chunkHeaderStart..<(chunkHeaderStart + 4))
            let b4 = UInt32(rawWebP[chunkHeaderStart + 4])
            let b5 = UInt32(rawWebP[chunkHeaderStart + 5]) << 8
            let b6 = UInt32(rawWebP[chunkHeaderStart + 6]) << 16
            let b7 = UInt32(rawWebP[chunkHeaderStart + 7]) << 24
            let size = Int(b4 | b5 | b6 | b7)
            let payloadStart = offset + 8
            let (payloadEnd, endOverflow) = payloadStart.addingReportingOverflow(size)
            guard !endOverflow, payloadEnd <= totalCount else { return rawWebP }
            let payload = rawWebP.subdata(in: (base + payloadStart)..<(base + payloadEnd))

            let tag = String(decoding: fourCC, as: UTF8.self)
            switch tag {
            case "VP8X":
                if let firstFlag = payload.first, (firstFlag & 0x10) != 0 {
                    detectedAlpha = true
                }
            case "ICCP", "EXIF", "XMP ":
                break // Replaced below
            case "ALPH":
                detectedAlpha = true
                imageChunks.append((fourCC, payload))
            case "VP8L":
                if payload.count >= 5 && (payload[payload.startIndex + 4] & 0x10) != 0 {
                    detectedAlpha = true
                }
                imageChunks.append((fourCC, payload))
            default:
                imageChunks.append((fourCC, payload))
            }

            offset = payloadEnd + (size & 1)
        }

        guard !imageChunks.isEmpty else { return rawWebP }

        var flags: UInt8 = 0
        if iccProfile != nil { flags |= 0x20 }
        if detectedAlpha { flags |= 0x10 }
        if exifData != nil { flags |= 0x08 }
        if xmpData != nil { flags |= 0x04 }

        let wMinus1 = UInt32(max(0, width - 1))
        let hMinus1 = UInt32(max(0, height - 1))
        var vp8xPayload = Data(capacity: 10)
        vp8xPayload.append(flags)
        vp8xPayload.append(contentsOf: [0, 0, 0])
        vp8xPayload.append(UInt8(wMinus1 & 0xFF))
        vp8xPayload.append(UInt8((wMinus1 >> 8) & 0xFF))
        vp8xPayload.append(UInt8((wMinus1 >> 16) & 0xFF))
        vp8xPayload.append(UInt8(hMinus1 & 0xFF))
        vp8xPayload.append(UInt8((hMinus1 >> 8) & 0xFF))
        vp8xPayload.append(UInt8((hMinus1 >> 16) & 0xFF))

        var body = Data()
        appendRIFFChunk(fourCC: Data("VP8X".utf8), payload: vp8xPayload, to: &body)
        if let iccProfile {
            appendRIFFChunk(fourCC: Data("ICCP".utf8), payload: iccProfile, to: &body)
        }
        for chunk in imageChunks {
            appendRIFFChunk(fourCC: chunk.fourCC, payload: chunk.payload, to: &body)
        }
        if let exifData {
            appendRIFFChunk(fourCC: Data("EXIF".utf8), payload: exifData, to: &body)
        }
        if let xmpData {
            appendRIFFChunk(fourCC: Data("XMP ".utf8), payload: xmpData, to: &body)
        }

        var container = Data("RIFF".utf8)
        let riffPayloadSize = UInt32(4 + body.count)
        container.append(UInt8(riffPayloadSize & 0xFF))
        container.append(UInt8((riffPayloadSize >> 8) & 0xFF))
        container.append(UInt8((riffPayloadSize >> 16) & 0xFF))
        container.append(UInt8((riffPayloadSize >> 24) & 0xFF))
        container.append(contentsOf: "WEBP".utf8)
        container.append(body)
        return container
    }

    private static func appendRIFFChunk(fourCC: Data, payload: Data, to output: inout Data) {
        output.append(fourCC.prefix(4))
        let size = UInt32(payload.count)
        output.append(UInt8(size & 0xFF))
        output.append(UInt8((size >> 8) & 0xFF))
        output.append(UInt8((size >> 16) & 0xFF))
        output.append(UInt8((size >> 24) & 0xFF))
        output.append(payload)
        if payload.count % 2 == 1 {
            output.append(0)
        }
    }
    
    // MARK: - Validation
    
    /// Validates that `data` contains a valid WebP bitstream.
    static func validate(_ data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return WebPBridgeValidate(ptr, rawBuffer.count) != 0
        }
    }
    
    /// Returns the pixel dimensions of a WebP file without full decoding.
    static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        return data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var w: Int32 = 0
            var h: Int32 = 0
            guard WebPBridgeGetInfo(ptr, rawBuffer.count, &w, &h) != 0 else { return nil }
            return (Int(w), Int(h))
        }
    }
    
    /// Returns true if the WebP bitstream contains an alpha channel.
    static func hasAlpha(_ data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            return WebPBridgeHasAlpha(ptr, rawBuffer.count) != 0
        }
    }
    
    // MARK: - Direct Pixel Detection & In-Place Alpha Unpremultiplication

    /// Maps packed 8-bit RGB CGImage pixel layouts directly to libwebp import formats (0=RGB, 1=RGBA, 2=RGBX, 3=BGRX, 4=BGRA).
    private static func detectDirectPixelFormat(for image: CGImage) -> Int32? {
        guard image.colorSpace?.model == .rgb,
              image.bitsPerComponent == 8,
              (image.bitsPerPixel == 24 || image.bitsPerPixel == 32),
              !image.bitmapInfo.contains(.floatComponents),
              image.utType == nil,
              image.decode == nil else {
            return nil
        }
        let bytesPerPixel = image.bitsPerPixel / 8
        let (minStride, strideOverflow) = image.width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !strideOverflow,
              image.bytesPerRow >= minStride,
              image.bytesPerRow <= Int(Int32.max),
              image.width <= Int(Int32.max),
              image.height <= Int(Int32.max) else {
            return nil
        }
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        if bytesPerPixel == 3 && image.alphaInfo == .none &&
            (byteOrder == .byteOrderDefault || byteOrder == .byteOrder32Big) {
            return 0 // RGB
        }
        if bytesPerPixel == 4 {
            if byteOrder == .byteOrderDefault || byteOrder == .byteOrder32Big {
                switch image.alphaInfo {
                case .last: return 1          // Straight RGBA
                case .noneSkipLast: return 2  // Opaque RGBX
                default: return nil
                }
            } else if byteOrder == .byteOrder32Little {
                switch image.alphaInfo {
                case .noneSkipFirst: return 3 // Opaque BGRX
                case .first: return 4         // Straight BGRA
                default: return nil
                }
            }
        }
        return nil
    }

    private static func encodePointer(
        _ data: Data,
        width: Int,
        height: Int,
        stride: Int,
        pixelFormat: Int32,
        lossless: Int32,
        quality: Float,
        cancelFlag: UnsafePointer<Int32>?
    ) throws -> Data {
        try data.withUnsafeBytes { rawBuffer -> Data in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw ConversionError.engineExecutionFailed(
                    "Failed to access pixel data for WebP encoding.",
                    underlyingError: nil
                )
            }
            return try encodeBufferPointer(
                ptr,
                width: width,
                height: height,
                stride: stride,
                pixelFormat: pixelFormat,
                lossless: lossless,
                quality: quality,
                freePixelsAfterImport: false,
                cancelFlag: cancelFlag
            )
        }
    }

    private static func encodeBufferPointer(
        _ ptr: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int,
        pixelFormat: Int32,
        lossless: Int32,
        quality: Float,
        freePixelsAfterImport: Bool,
        cancelFlag: UnsafePointer<Int32>?
    ) throws -> Data {
        var outData: UnsafeMutablePointer<UInt8>? = nil
        var outSize: Int = 0
        var wasCancelled: Int32 = 0
        let success = WebPBridgeEncodePixelsEx(
            ptr,
            Int32(width),
            Int32(height),
            Int32(stride),
            pixelFormat,
            lossless,
            quality,
            freePixelsAfterImport ? 1 : 0,
            cancelFlag,
            &outData,
            &outSize,
            &wasCancelled
        )
        if wasCancelled != 0 {
            if let outData {
                WebPBridgeFreeBuffer(outData)
            }
            throw ConversionError.cancelled
        }
        guard success != 0, let encoded = outData, outSize > 0 else {
            throw ConversionError.engineExecutionFailed(
                "WebP encoding failed. The image could not be compressed.",
                underlyingError: "WebPBridgeEncodePixelsEx returned 0 (libwebp encoding error)"
            )
        }
        defer { WebPBridgeFreeBuffer(encoded) }
        return Data(bytes: encoded, count: outSize)
    }

    /// Converts premultiplied alpha RGBA pixels to straight alpha in-place without allocating a second full-resolution buffer.
    private func unpremultiplyAlphaInPlace(rgba: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) {
        for row in 0..<height {
            let rowBase = row * stride
            for col in 0..<width {
                let offset = rowBase + col * 4
                let a = rgba[offset + 3]
                if a == 255 {
                    continue
                } else if a == 0 {
                    rgba[offset] = 0
                    rgba[offset + 1] = 0
                    rgba[offset + 2] = 0
                } else {
                    let alpha = Int(a)
                    rgba[offset]     = UInt8(min(255, (Int(rgba[offset]) * 255 + alpha / 2) / alpha))
                    rgba[offset + 1] = UInt8(min(255, (Int(rgba[offset + 1]) * 255 + alpha / 2) / alpha))
                    rgba[offset + 2] = UInt8(min(255, (Int(rgba[offset + 2]) * 255 + alpha / 2) / alpha))
                }
            }
        }
    }
}
