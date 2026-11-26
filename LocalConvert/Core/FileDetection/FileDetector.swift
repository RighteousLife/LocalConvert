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
        // JPEG
        ([0xFF, 0xD8, 0xFF], 0, .jpg),
        // GIF87a / GIF89a
        ([0x47, 0x49, 0x46, 0x38, 0x37, 0x61], 0, .gif),
        ([0x47, 0x49, 0x46, 0x38, 0x39, 0x61], 0, .gif),
        // JPEG 2000 (JP2 box & J2K codestream)
        ([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20], 0, .jp2),
        ([0xFF, 0x4F, 0xFF, 0x51], 0, .jp2),
        // JPEG XL codestream
        ([0xFF, 0x0A], 0, .jxl),
        // OpenEXR
        ([0x76, 0x2F, 0x31, 0x01], 0, .exr),
        // QOI
        ([0x71, 0x6F, 0x69, 0x66], 0, .qoi),
        // BMP
        ([0x42, 0x4D], 0, .bmp),
        // ICNS (icns)
        ([0x69, 0x63, 0x6E, 0x73], 0, .icns),
        // PSD (8BPS)
        ([0x38, 0x42, 0x50, 0x53], 0, .psd),
        // ICO (00 00 01 00)
        ([0x00, 0x00, 0x01, 0x00], 0, .ico),
        // SGI RGB (01 DA)
        ([0x01, 0xDA], 0, .sgi),
        // Archives
        ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], 0, .sevenZ),
        ([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], 0, .rar),
        // Audio
        ([0x49, 0x44, 0x33], 0, .mp3),
        ([0xFF, 0xFB], 0, .mp3),
        ([0xFF, 0xF3], 0, .mp3),
        ([0xFF, 0xF2], 0, .mp3),
        ([0x66, 0x4C, 0x61, 0x43], 0, .flac),
        ([0x63, 0x61, 0x66, 0x66], 0, .caf),
        ([0x0B, 0x77], 0, .ac3),
        ([0x2E, 0x73, 0x6E, 0x64], 0, .au),            // .snd
        ([0x77, 0x76, 0x70, 0x6B], 0, .wv),            // wvpk
        ([0x4D, 0x41, 0x43, 0x20], 0, .ape),           // MAC 
        ([0x23, 0x21, 0x41, 0x4D, 0x52], 0, .amr),     // #!AMR
        ([0x7F, 0xFE, 0x80, 0x01], 0, .dts),           // DTS core
        // Video
        ([0x46, 0x4C, 0x56, 0x01], 0, .flv),           // FLV
        ([0x00, 0x00, 0x01, 0xBA], 0, .mpg),           // MPEG-PS / VOB
        // RTF ({\rtf)
        ([0x7B, 0x5C, 0x72, 0x74, 0x66], 0, .rtf),
    ]
    
    // MARK: - Public API
    
    func detect(url: URL) -> FileDetectionResult {
        let extensionFormat = detectByExtension(url: url)
        let utTypeFormat = detectByUTType(url: url)
        let magicBytesFormat = detectByMagicBytes(url: url, extensionHint: extensionFormat)
        
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
    
    static func detectFormat(url: URL) -> FileFormat? {
        FileDetector().detect(url: url).bestFormat
    }

    /// Returns `true` when `url` is a macOS directory-bundle iWork package (`.pages`, `.numbers`, `.key`)
    /// containing expected iWork package entries rather than a plain user folder.
    static func isIWorkPackageBundle(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["pages", "numbers", "key"].contains(ext) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        let markers = [
            "Index/Document.iwa",
            "Index/Slide.iwa",
            "Index/Presentation.iwa",
            "Index/Tables",
            "Metadata/Properties.plist",
            "index.xml"
        ]
        return markers.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }
    
    // MARK: - Detection Methods
    
    private func detectByExtension(url: URL) -> FileFormat? {
        let lowerName = url.lastPathComponent.lowercased()
        for (suffix, format) in FileFormat.compoundExtensions {
            if lowerName.hasSuffix(suffix) {
                return format
            }
        }
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        return FileFormat.from(extension: ext)
    }
    
    private func detectByUTType(url: URL) -> FileFormat? {
        let lowerName = url.lastPathComponent.lowercased()
        for (suffix, format) in FileFormat.compoundExtensions {
            if lowerName.hasSuffix(suffix) {
                return format
            }
        }
        guard let utType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return nil
        }
        return FileFormat.from(utType: utType)
    }
    
    private func detectByMagicBytes(url: URL, extensionHint: FileFormat?) -> FileFormat? {
        if Self.isIWorkPackageBundle(url: url) {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Index/Slide.iwa").path)
                || FileManager.default.fileExists(atPath: url.appendingPathComponent("Index/Presentation.iwa").path) {
                return .key
            }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Index/Tables").path) {
                return .numbers
            }
            if let hint = extensionHint, [.pages, .numbers, .key].contains(hint) {
                return hint
            }
            return .pages
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }
        
        guard let headerData = try? fileHandle.read(upToCount: 4096), !headerData.isEmpty else { return nil }
        let bytes = Array(headerData)
        let ext = url.pathExtension.lowercased()
        
        // 1. PNG vs APNG (check acTL chunk before IDAT)
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            if let acTLRange = headerData.range(of: Data("acTL".utf8)) {
                let idatRange = headerData.range(of: Data("IDAT".utf8))
                if idatRange == nil || acTLRange.lowerBound < idatRange!.lowerBound {
                    return .apng
                }
            }
            return ext == "apng" ? .apng : .png
        }
        
        // 2. RIFF-based formats (WEBP, WAVE, AVI)
        if bytes.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            let subType = Array(bytes[8..<12])
            if subType == [0x57, 0x45, 0x42, 0x50] { return .webp }
            if subType == [0x57, 0x41, 0x56, 0x45] { return .wav }
            if subType == [0x41, 0x56, 0x49, 0x20] { return .avi }
        }
        
        // 3. ISOBMFF containers (`ftyp` or JPEG XL container)
        if bytes.count >= 12 && bytes[0...7] == [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20] {
            return .jxl
        }
        if bytes.count >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            let brand = String(bytes: Array(bytes[8..<12]), encoding: .ascii)?.lowercased() ?? ""
            if brand.hasPrefix("3g2") || ext == "3g2" || ext == "3gp2" {
                return .threeG2
            }
            if brand.hasPrefix("3gp") || brand.hasPrefix("3ge") || brand.hasPrefix("3gg") || ext == "3gp" || ext == "3gpp" {
                return .threeGP
            }
            if brand.hasPrefix("avif") || brand.hasPrefix("avis") {
                return .avif
            }
            if brand.hasPrefix("msf1") || brand.hasPrefix("hevs") {
                return ext == "heifs" ? .heifs : .heics
            }
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("hevc") || brand.hasPrefix("mif1") || brand.hasPrefix("heif") {
                if ext == "heics" { return .heics }
                if ext == "heifs" { return .heifs }
                return .heic
            }
            if brand.hasPrefix("jxl") {
                return .jxl
            }
            if brand.hasPrefix("crx") || ext == "cr3" {
                return .cr3
            }
            if brand.hasPrefix("alac") || ext == "alac" {
                return .alac
            }
            if brand.hasPrefix("m4r") || ext == "m4r" {
                return .m4r
            }
            if brand.hasPrefix("m4b") || ext == "m4b" {
                return .m4b
            }
            if brand.hasPrefix("m4v") || ext == "m4v" {
                return .m4v
            }
            if brand.hasPrefix("m4a") || ext == "m4a" {
                return .m4a
            }
            if brand.hasPrefix("f4v") || ext == "f4v" {
                return .f4v
            }
            if brand.hasPrefix("qt") || ext == "mov" {
                return .mov
            }
            if brand.hasPrefix("isom") || brand.hasPrefix("mp4") || ext == "mp4" {
                return .mp4
            }
            return .mp4
        }
        
        // 4. AIFF (FORM....AIFF / AIFC)
        if bytes.count >= 12 && bytes[0...3] == [0x46, 0x4F, 0x52, 0x4D] {
            return .aiff
        }
        
        // 5. ASF / WMV / WMA
        if bytes.starts(with: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            if ext == "wma" { return .wma }
            if ext == "asf" { return .asf }
            return .wmv
        }
        
        // 6. MPEG-TS (0x47 sync byte)
        if bytes.first == 0x47 {
            if ext == "m2ts" { return .m2ts }
            if ext == "mts" { return .mts }
            if ext == "ts" { return .ts }
        }
        
        // 7. MPEG-PS vs VOB
        if bytes.starts(with: [0x00, 0x00, 0x01, 0xBA]) {
            if ext == "vob" { return .vob }
            return .mpg
        }
        
        // 8. Radiance HDR
        if headerData.starts(with: Data("#?RADIANCE".utf8)) || headerData.starts(with: Data("#?RGBE".utf8)) {
            return .hdr
        }
        
        // 9. Netpbm P1-P6 + whitespace
        if bytes.count >= 3 && bytes[0] == 0x50 && (0x31...0x36).contains(bytes[1]) &&
            [0x0A, 0x0D, 0x20, 0x09].contains(bytes[2]) {
            return .ppm
        }
        
        // 10. TIFF / Camera RAW TIFF-based formats
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) || bytes.starts(with: [0x49, 0x49, 0x52, 0x4F]) {
            if let extFmt = extensionHint, extFmt.isRawImage {
                return extFmt
            }
            return .tiff
        }
        
        // 11. EBML (MKV / WebM / MKA)
        if bytes.count >= 4 && bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
            if headerData.range(of: Data("webm".utf8)) != nil || ext == "webm" {
                return .webm
            }
            if ext == "mka" {
                return .mka
            }
            return .mkv
        }
        
        // 12. Ogg container (OGG / Opus / OGV)
        if bytes.count >= 4 && bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
            if headerData.range(of: Data("OpusHead".utf8)) != nil || ext == "opus" {
                return .opus
            }
            if headerData.range(of: Data("theora".utf8)) != nil || ext == "ogv" {
                return .ogv
            }
            return .ogg
        }
        
        // 13. Compound Archives (tar.gz, tar.bz2, tar.xz) + GZip / BZip2 / XZ / TAR
        if bytes.starts(with: [0x1F, 0x8B]) {
            return extensionHint == .tgz ? .tgz : .gz
        }
        if bytes.starts(with: [0x42, 0x5A, 0x68]) {
            return extensionHint == .tbz2 ? .tbz2 : .bz2
        }
        if bytes.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return extensionHint == .txz ? .txz : .xz
        }
        if bytes.count >= 263 && Array(bytes[257..<262]) == [0x75, 0x73, 0x74, 0x61, 0x72] { // "ustar"
            return .tar
        }
        
        // 14. ZIP & ZIP-based packages (inspect inner OOXML / ODF / EPUB markers before falling back)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return inspectZipContainerFormat(url: url, extensionHint: extensionHint)
        }
        
        // 15. Legacy OLE2 Compound Binary (DOC, XLS, PPT, PPS)
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            if let hint = extensionHint, [.doc, .xls, .ppt, .pps].contains(hint) {
                return hint
            }
        }

        // 15b. Binary Apple Property List (bplist) / Binary .webloc
        if bytes.starts(with: [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74]) {
            if ext == "webloc" || extensionHint == .webloc {
                return .webloc
            }
            return .plist
        }
        
        // 16. Standard fixed-byte signatures
        for sig in Self.signatures {
            if matchesSignature(bytes: bytes, signature: sig.bytes, offset: sig.offset) {
                return sig.format
            }
        }
        
        // 17. SVG / HTML / Text-based Subtitles (WebVTT, ASS/SSA, SRT, MicroDVD)
        if let textPrefix = String(data: headerData.prefix(2048), encoding: .utf8) {
            let trimmed = textPrefix.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            let lower = trimmed.lowercased()
            if lower.hasPrefix("<svg") || (lower.hasPrefix("<?xml") && lower.contains("<svg")) {
                return .svg
            }
            if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") {
                return .html
            }
            if trimmed.hasPrefix("WEBVTT") {
                return .vtt
            }
            if trimmed.contains("[Script Info]") && (trimmed.contains("[V4+ Styles]") || trimmed.contains("[Events]")) {
                return ext == "ssa" ? .ssa : .ass
            }
            if trimmed.range(of: #"^\d+\r?\n\d{2}:\d{2}:\d{2},\d{3}\s*-->"#, options: .regularExpression) != nil {
                return .srt
            }
            if ext == "sub" && trimmed.range(of: #"^\{\d+\}\{\d+\}"#, options: .regularExpression) != nil {
                return .sub
            }
            if trimmed.hasPrefix("BEGIN:VCALENDAR") {
                return .ics
            }
            if trimmed.hasPrefix("BEGIN:VCARD") {
                return .vcf
            }
            if lower.contains("<!doctype plist") || lower.contains("<plist") {
                if ext == "webloc" || extensionHint == .webloc {
                    return .webloc
                }
                return .plist
            }
            if lower.hasPrefix("<?xml") {
                if ext == "webloc" || extensionHint == .webloc {
                    return .webloc
                }
                if ext == "plist" || extensionHint == .plist {
                    return .plist
                }
                return .xml
            }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                if ext == "json" || extensionHint == .json {
                    return .json
                }
                if let jsonData = trimmed.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: jsonData)) != nil {
                    return .json
                }
            }
        }
        
        // 18. HDMV PGS bitmap subtitle (.sup)
        if bytes.count >= 2 && bytes[0] == 0x50 && bytes[1] == 0x47 && ext == "sup" {
            return .sup
        }
        
        return nil
    }
    
    private func inspectZipContainerFormat(url: URL, extensionHint: FileFormat?) -> FileFormat {
        // Read up to 64 KB from start + central directory tail up to 64 KB to inspect package entries
        var probeData = Data()
        if let fh = try? FileHandle(forReadingFrom: url) {
            defer { try? fh.close() }
            if let head = try? fh.read(upToCount: 65_536) {
                probeData.append(head)
            }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value,
               size > 65_536 {
                let tailOffset = size - 65_536
                if (try? fh.seek(toOffset: tailOffset)) != nil,
                   let tail = try? fh.readToEnd() {
                    probeData.append(tail)
                }
            }
        }
        
        // Check ODF mimetype strings first
        if probeData.range(of: Data("application/vnd.oasis.opendocument.text".utf8)) != nil {
            return .odt
        }
        if probeData.range(of: Data("application/vnd.oasis.opendocument.spreadsheet".utf8)) != nil {
            return .ods
        }
        if probeData.range(of: Data("application/vnd.oasis.opendocument.presentation".utf8)) != nil {
            return .odp
        }
        if probeData.range(of: Data("application/epub+zip".utf8)) != nil {
            return .epub
        }
        
        // Check OOXML root folder / content markers while preserving macro/template extension distinctions
        if probeData.range(of: Data("word/".utf8)) != nil {
            if let hint = extensionHint, [.docm, .dotx, .docx].contains(hint) {
                return hint
            }
            return .docx
        }
        if probeData.range(of: Data("xl/".utf8)) != nil {
            if let hint = extensionHint, [.xlsm, .xltx, .xlsx].contains(hint) {
                return hint
            }
            return .xlsx
        }
        if probeData.range(of: Data("ppt/".utf8)) != nil {
            if let hint = extensionHint, [.pptm, .potx, .ppsx, .pptx].contains(hint) {
                return hint
            }
            return .pptx
        }

        // Check Apple iWork ZIP package markers (.key / .numbers / .pages) before falling back to .zip
        if probeData.range(of: Data("Index/Slide.iwa".utf8)) != nil
            || probeData.range(of: Data("Index/Presentation.iwa".utf8)) != nil
            || probeData.range(of: Data("Index/MasterSlide".utf8)) != nil
            || probeData.range(of: Data("http://developer.apple.com/namespaces/keynote2".utf8)) != nil {
            return .key
        }
        if probeData.range(of: Data("Index/Tables/".utf8)) != nil
            || probeData.range(of: Data("Index/CalculationEngine".utf8)) != nil
            || probeData.range(of: Data("http://developer.apple.com/namespaces/ls".utf8)) != nil {
            return .numbers
        }
        if probeData.range(of: Data("Index/Document.iwa".utf8)) != nil
            || probeData.range(of: Data("http://developer.apple.com/namespaces/sl".utf8)) != nil {
            if let hint = extensionHint, [.pages, .numbers, .key].contains(hint) {
                return hint
            }
            return .pages
        }
        if (probeData.range(of: Data("Metadata/Properties.plist".utf8)) != nil
            || probeData.range(of: Data("Index/".utf8)) != nil
            || probeData.range(of: Data("index.xml".utf8)) != nil),
           let hint = extensionHint, [.pages, .numbers, .key].contains(hint) {
            return hint
        }
        
        if let hint = extensionHint,
           [.docx, .docm, .dotx, .xlsx, .xlsm, .xltx, .pptx, .pptm, .potx, .ppsx, .odt, .ods, .odp, .epub, .pages, .numbers, .key].contains(hint) {
            return hint
        }
        return .zip
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
