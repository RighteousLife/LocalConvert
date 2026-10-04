import Foundation
import CoreGraphics
import ImageIO
import os.log

// MARK: - WebP Encoding Mode

enum WebPEncodingMode: Sendable {
    case lossy(quality: Float)   // quality 0...100 (libwebp scale)
    case lossless
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
    ///   - image:  The upright, orientation-corrected CGImage to encode.
    ///   - mode:   `.lossy(quality:)` for lossy compression, `.lossless` for lossless.
    /// - Returns:  `Data` containing a valid WebP bitstream.
    func encode(image: CGImage, mode: WebPEncodingMode) throws -> Data {
        // Extract RGBA pixel buffer from CGImage
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4  // RGBA
        let stride = width * bytesPerPixel
        
        guard width > 0, height > 0 else {
            throw ConversionError.invalidInput("Image has zero dimensions.")
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ConversionError.engineExecutionFailed(
                "Failed to create pixel rendering context for WebP encoding.",
                underlyingError: nil
            )
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let pixelData = context.data else {
            throw ConversionError.engineExecutionFailed(
                "Failed to access pixel buffer for WebP encoding.",
                underlyingError: nil
            )
        }
        
        let rgbaPtr = pixelData.assumingMemoryBound(to: UInt8.self)
        
        // Unpremultiply alpha before encoding (libwebp expects straight alpha)
        let unpremultiplied = unpremultiplyAlpha(rgba: rgbaPtr, width: width, height: height, stride: stride)
        
        return try unpremultiplied.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw ConversionError.engineExecutionFailed(
                    "Failed to access unpremultiplied pixel buffer.",
                    underlyingError: nil
                )
            }
            
            var outData: UnsafeMutablePointer<UInt8>? = nil
            var outSize: Int = 0
            
            let success: Int32
            
            switch mode {
            case .lossy(let quality):
                success = WebPBridgeEncodeLossy(ptr, Int32(width), Int32(height), Int32(stride), quality, &outData, &outSize)
                
            case .lossless:
                success = WebPBridgeEncodeLossless(ptr, Int32(width), Int32(height), Int32(stride), &outData, &outSize)
            }
            
            guard success != 0, let data = outData, outSize > 0 else {
                throw ConversionError.engineExecutionFailed(
                    "WebP encoding failed. The image could not be compressed.",
                    underlyingError: "WebPBridgeEncode returned 0 (libwebp encoding error)"
                )
            }
            
            defer { WebPBridgeFreeBuffer(data) }
            return Data(bytes: data, count: outSize)
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
    
    // MARK: - Alpha Unpremultiplication
    
    /// Converts premultiplied alpha RGBA data (CGContext output) to straight alpha
    /// expected by libwebp's WebPEncodeRGBA function.
    private func unpremultiplyAlpha(rgba: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) -> Data {
        let totalBytes = height * stride
        var result = Data(count: totalBytes)
        
        result.withUnsafeMutableBytes { destBuffer in
            let dest = destBuffer.bindMemory(to: UInt8.self).baseAddress!
            
            for row in 0..<height {
                let rowBase = row * stride
                for col in 0..<width {
                    let offset = rowBase + col * 4
                    let r = rgba[offset]
                    let g = rgba[offset + 1]
                    let b = rgba[offset + 2]
                    let a = rgba[offset + 3]
                    
                    if a == 0 {
                        dest[offset]     = 0
                        dest[offset + 1] = 0
                        dest[offset + 2] = 0
                        dest[offset + 3] = 0
                    } else if a == 255 {
                        dest[offset]     = r
                        dest[offset + 1] = g
                        dest[offset + 2] = b
                        dest[offset + 3] = 255
                    } else {
                        // Unpremultiply: straight = (premult * 255 + alpha/2) / alpha
                        let alpha = Int(a)
                        dest[offset]     = UInt8(min(255, (Int(r) * 255 + alpha / 2) / alpha))
                        dest[offset + 1] = UInt8(min(255, (Int(g) * 255 + alpha / 2) / alpha))
                        dest[offset + 2] = UInt8(min(255, (Int(b) * 255 + alpha / 2) / alpha))
                        dest[offset + 3] = a
                    }
                }
            }
        }
        
        return result
    }
}
