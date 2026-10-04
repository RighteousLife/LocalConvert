import Foundation
import UniformTypeIdentifiers
import os.log

// MARK: - File Detection Result

struct FileDetectionResult: Sendable {
    let url: URL
    let detectedFormat: FileFormat?
    let extensionFormat: FileFormat?
    let utTypeFormat: FileFormat?
    let magicBytesFormat: FileFormat?
    let confidence: DetectionConfidence
    
    /// The best guess format, preferring magic bytes > UTType > extension
    var bestFormat: FileFormat? {
        magicBytesFormat ?? utTypeFormat ?? extensionFormat ?? detectedFormat
    }
}

enum DetectionConfidence: String, Sendable, Comparable {
    case high
    case medium
    case low
    case unknown
    
    static func < (lhs: DetectionConfidence, rhs: DetectionConfidence) -> Bool {
        let order: [DetectionConfidence] = [.unknown, .low, .medium, .high]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else { return false }
        return lhsIndex < rhsIndex
    }
}

// MARK: - File Detector

struct FileDetector: Sendable {
    
    private static let logger = Logger(subsystem: "com.localconvert.app", category: "FileDetection")
    
    // MARK: - Magic Bytes Signatures
    
    private static let signatures: [(bytes: [UInt8], offset: Int, format: FileFormat)] = [
        // PDF
        ([0x25, 0x50, 0x44, 0x46], 0, .pdf),           // %PDF
        // PNG
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], 0, .png),
        // JPEG
        ([0xFF, 0xD8, 0xFF], 0, .jpg),
        // GIF87a
        ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], 0, .gif),
        // GIF89a
        ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], 0, .gif),
        // TIFF (little-endian)
        ([0x49, 0x49, 0x2A, 0x00], 0, .tiff),
        // TIFF (big-endian)
        ([0x4D, 0x4D, 0x00, 0x2A], 0, .tiff),
        // BMP
        ([0x42, 0x4D], 0, .bmp),
        // WebP (RIFF....WEBP)
        ([0x52, 0x49, 0x46, 0x46], 0, .webp), // Needs secondary check for WEBP at offset 8
        // ZIP (also DOCX, XLSX, PPTX are ZIP-based)
        ([0x50, 0x4B, 0x03, 0x04], 0, .zip),
        // 7z
        ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], 0, .sevenZ),
        // GZip
        ([0x1F, 0x8B], 0, .gz),
        // BZ2
        ([0x42, 0x5A, 0x68], 0, .bz2),
        // XZ
        ([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], 0, .xz),
        // MP3 (ID3)
        ([0x49, 0x44, 0x33], 0, .mp3),
        // MP3 (sync word)
        ([0xFF, 0xFB], 0, .mp3),
        // FLAC
        ([0x66, 0x4C, 0x61, 0x43], 0, .flac),
        // OGG
        ([0x4F, 0x67, 0x67, 0x53], 0, .ogg),
        // WAV (RIFF....WAVE)
        ([0x52, 0x49, 0x46, 0x46], 0, .wav), // Needs secondary check for WAVE at offset 8
        // AIFF
        ([0x46, 0x4F, 0x52, 0x4D], 0, .aiff),
        // MP4/MOV (ftyp)
        ([0x66, 0x74, 0x79, 0x70], 4, .mp4),
        // AVI (RIFF....AVI )
        ([0x52, 0x49, 0x46, 0x46], 0, .avi), // Needs secondary check for AVI  at offset 8
    ]
    
    // MARK: - Public API
    
    func detect(url: URL) -> FileDetectionResult {
        let extensionFormat = detectByExtension(url: url)
        let utTypeFormat = detectByUTType(url: url)
        let magicBytesFormat = detectByMagicBytes(url: url)
        
        // Determine confidence
        let confidence: DetectionConfidence
        let formats = [extensionFormat, utTypeFormat, magicBytesFormat].compactMap { $0 }
        
        if formats.count >= 2 {
            let allSame = formats.allSatisfy { $0 == formats.first }
            confidence = allSame ? .high : .medium
        } else if formats.count == 1 {
            confidence = .medium
        } else {
            confidence = .unknown
        }
        
        let result = FileDetectionResult(
            url: url,
            detectedFormat: formats.first,
            extensionFormat: extensionFormat,
            utTypeFormat: utTypeFormat,
            magicBytesFormat: magicBytesFormat,
            confidence: confidence
        )
        
        Self.logger.info("Detected format: \(result.bestFormat?.rawValue ?? "unknown", privacy: .public) (confidence: \(confidence.rawValue, privacy: .public))")
        
        return result
    }
    
    // MARK: - Detection Methods
    
    private func detectByExtension(url: URL) -> FileFormat? {
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        return FileFormat.from(extension: ext)
    }
    
    private func detectByUTType(url: URL) -> FileFormat? {
        guard let utType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return nil
        }
        return FileFormat.from(utType: utType)
    }
    
    private func detectByMagicBytes(url: URL) -> FileFormat? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }
        
        guard let headerData = try? fileHandle.read(upToCount: 16) else { return nil }
        let bytes = Array(headerData)
        
        // Check RIFF-based formats first (need secondary check)
        if bytes.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            let subType = Array(bytes[8..<12])
            if subType == [0x57, 0x45, 0x42, 0x50] { // WEBP
                return .webp
            } else if subType == [0x57, 0x41, 0x56, 0x45] { // WAVE
                return .wav
            } else if subType == [0x41, 0x56, 0x49, 0x20] { // AVI 
                return .avi
            }
        }
        
        // Check HEIC/HEIF / MP4 / MOV / M4A (ftyp box)
        if bytes.count >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let brand = String(bytes: Array(bytes[8..<12]), encoding: .ascii)?.lowercased() ?? ""
            let ext = url.pathExtension.lowercased()
            if brand.hasPrefix("heic") || brand.hasPrefix("heif") || brand.hasPrefix("mif1") {
                return .heic
            }
            if brand.hasPrefix("m4a") || brand.hasPrefix("m4b") || ext == "m4a" {
                return .m4a
            }
            if brand.hasPrefix("qt") || ext == "mov" {
                return .mov
            }
            if brand.hasPrefix("isom") || brand.hasPrefix("mp4") || ext == "mp4" {
                return .mp4
            }
            // Fallback for general MP4 containers
            if ext == "m4v" { return .m4v }
            return .mp4
        }
        
        // Check EBML header (Matroska / WebM)
        if bytes.count >= 4 && bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
            let ext = url.pathExtension.lowercased()
            if ext == "webm" {
                return .webm
            }
            return .mkv
        }
        
        // Check Ogg container (OGG / Opus)
        if bytes.count >= 4 && bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
            let ext = url.pathExtension.lowercased()
            if ext == "opus" {
                return .opus
            }
            return .ogg
        }
        
        // Check ZIP-based formats (Office documents)
        if bytes.count >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04 {
            // ZIP-based - could be DOCX, XLSX, PPTX, or plain ZIP
            // For accuracy, check file extension for Office formats
            if let extFormat = detectByExtension(url: url),
               [.docx, .xlsx, .pptx, .odt, .ods, .odp].contains(extFormat) {
                return extFormat
            }
            return .zip
        }
        
        // Standard signature matching
        for sig in Self.signatures {
            guard sig.format != .webp && sig.format != .wav && sig.format != .avi else { continue }
            guard sig.format != .zip else { continue }
            if matchesSignature(bytes: bytes, signature: sig.bytes, offset: sig.offset) {
                return sig.format
            }
        }
        
        return nil
    }
    
    private func matchesSignature(bytes: [UInt8], signature: [UInt8], offset: Int) -> Bool {
        guard bytes.count >= offset + signature.count else { return false }
        for i in 0..<signature.count {
            if bytes[offset + i] != signature[i] {
                return false
            }
        }
        return true
    }
}
