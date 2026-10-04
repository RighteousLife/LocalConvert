import Foundation
import UniformTypeIdentifiers

// MARK: - Format Category

enum FormatCategory: String, Sendable, CaseIterable, Identifiable {
    case document = "Documents"
    case image = "Images"
    case audio = "Audio"
    case video = "Video"
    case archive = "Archives"
    
    var id: String { rawValue }
    
    var systemImage: String {
        switch self {
        case .document: return "doc.text"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .archive: return "archivebox"
        }
    }
}

// MARK: - Format Group (UI Grouping)

enum FormatGroup: String, Sendable, CaseIterable, Identifiable {
    case images = "Images"
    case documents = "Documents"
    case spreadsheets = "Spreadsheets"
    case presentations = "Presentations"
    case pdf = "PDF"
    case audio = "Audio"
    case video = "Video"
    case archives = "Archives"
    
    var id: String { rawValue }
    
    var sortOrder: Int {
        switch self {
        case .images: return 0
        case .pdf: return 1
        case .documents: return 2
        case .spreadsheets: return 3
        case .presentations: return 4
        case .audio: return 5
        case .video: return 6
        case .archives: return 7
        }
    }
}

// MARK: - File Format

enum FileFormat: String, Sendable, Hashable, CaseIterable, Identifiable {
    // Documents
    case pdf
    case docx
    case xlsx
    case pptx
    case doc
    case xls
    case ppt
    case odt
    case ods
    case odp
    case rtf
    case txt
    case html
    case csv
    
    // Images
    case jpg
    case png
    case heic
    case webp
    case tiff
    case bmp
    case gif
    case svg
    case ico
    case avif
    
    // Audio
    case mp3
    case wav
    case flac
    case aac
    case m4a
    case ogg
    case opus
    case aiff
    
    // Video
    case mp4
    case mov
    case mkv
    case webm
    case avi
    case wmv
    case m4v
    
    // Archives
    case zip
    case tar
    case gz
    case tgz
    case sevenZ
    case bz2
    case xz
    
    var id: String { rawValue }
    
    // MARK: - Category
    
    var category: FormatCategory {
        switch self {
        case .pdf, .docx, .xlsx, .pptx, .doc, .xls, .ppt, .odt, .ods, .odp, .rtf, .txt, .html, .csv:
            return .document
        case .jpg, .png, .heic, .webp, .tiff, .bmp, .gif, .svg, .ico, .avif:
            return .image
        case .mp3, .wav, .flac, .aac, .m4a, .ogg, .opus, .aiff:
            return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v:
            return .video
        case .zip, .tar, .gz, .tgz, .sevenZ, .bz2, .xz:
            return .archive
        }
    }
    
    // MARK: - Format Group (Refined for UI)
    
    var group: FormatGroup {
        switch self {
        case .pdf:
            return .pdf
        case .docx, .doc, .odt, .rtf, .txt, .html:
            return .documents
        case .xlsx, .xls, .ods, .csv:
            return .spreadsheets
        case .pptx, .ppt, .odp:
            return .presentations
        case .jpg, .png, .heic, .webp, .tiff, .bmp, .gif, .svg, .ico, .avif:
            return .images
        case .mp3, .wav, .flac, .aac, .m4a, .ogg, .opus, .aiff:
            return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v:
            return .video
        case .zip, .tar, .gz, .tgz, .sevenZ, .bz2, .xz:
            return .archives
        }
    }
    
    // MARK: - File Extension
    
    var fileExtension: String {
        switch self {
        case .sevenZ: return "7z"
        case .jpg: return "jpg" // Also accepts jpeg
        case .heic: return "heic" // Also accepts heif
        case .tgz: return "tgz" // Also accepts tar.gz
        default: return rawValue
        }
    }
    
    // MARK: - Display Name
    
    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "Word Document"
        case .xlsx: return "Excel Spreadsheet"
        case .pptx: return "PowerPoint Presentation"
        case .doc: return "Word Document (Legacy)"
        case .xls: return "Excel Spreadsheet (Legacy)"
        case .ppt: return "PowerPoint (Legacy)"
        case .odt: return "OpenDocument Text"
        case .ods: return "OpenDocument Spreadsheet"
        case .odp: return "OpenDocument Presentation"
        case .rtf: return "Rich Text Format"
        case .txt: return "Plain Text"
        case .html: return "HTML"
        case .csv: return "CSV"
        case .jpg: return "JPEG Image"
        case .png: return "PNG Image"
        case .heic: return "HEIC Image"
        case .webp: return "WebP Image"
        case .tiff: return "TIFF Image"
        case .bmp: return "BMP Image"
        case .gif: return "GIF Image"
        case .svg: return "SVG Image"
        case .ico: return "Icon"
        case .avif: return "AVIF Image"
        case .mp3: return "MP3 Audio"
        case .wav: return "WAV Audio"
        case .flac: return "FLAC Audio"
        case .aac: return "AAC Audio"
        case .m4a: return "M4A Audio"
        case .ogg: return "OGG Audio"
        case .opus: return "Opus Audio"
        case .aiff: return "AIFF Audio"
        case .mp4: return "MP4 Video"
        case .mov: return "QuickTime Video"
        case .mkv: return "MKV Video"
        case .webm: return "WebM Video"
        case .avi: return "AVI Video"
        case .wmv: return "WMV Video"
        case .m4v: return "M4V Video"
        case .zip: return "ZIP Archive"
        case .tar: return "TAR Archive"
        case .gz: return "GZip Archive"
        case .tgz: return "TGZ Archive"
        case .sevenZ: return "7-Zip Archive"
        case .bz2: return "BZip2 Archive"
        case .xz: return "XZ Archive"
        }
    }
    
    // MARK: - MIME Type
    
    var mimeType: String {
        switch self {
        case .pdf: return "application/pdf"
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .xlsx: return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .pptx: return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .doc: return "application/msword"
        case .xls: return "application/vnd.ms-excel"
        case .ppt: return "application/vnd.ms-powerpoint"
        case .odt: return "application/vnd.oasis.opendocument.text"
        case .ods: return "application/vnd.oasis.opendocument.spreadsheet"
        case .odp: return "application/vnd.oasis.opendocument.presentation"
        case .rtf: return "text/rtf"
        case .txt: return "text/plain"
        case .html: return "text/html"
        case .csv: return "text/csv"
        case .jpg: return "image/jpeg"
        case .png: return "image/png"
        case .heic: return "image/heic"
        case .webp: return "image/webp"
        case .tiff: return "image/tiff"
        case .bmp: return "image/bmp"
        case .gif: return "image/gif"
        case .svg: return "image/svg+xml"
        case .ico: return "image/x-icon"
        case .avif: return "image/avif"
        case .mp3: return "audio/mpeg"
        case .wav: return "audio/wav"
        case .flac: return "audio/flac"
        case .aac: return "audio/aac"
        case .m4a: return "audio/mp4"
        case .ogg: return "audio/ogg"
        case .opus: return "audio/opus"
        case .aiff: return "audio/aiff"
        case .mp4: return "video/mp4"
        case .mov: return "video/quicktime"
        case .mkv: return "video/x-matroska"
        case .webm: return "video/webm"
        case .avi: return "video/x-msvideo"
        case .wmv: return "video/x-ms-wmv"
        case .m4v: return "video/x-m4v"
        case .zip: return "application/zip"
        case .tar: return "application/x-tar"
        case .gz: return "application/gzip"
        case .tgz: return "application/gzip"
        case .sevenZ: return "application/x-7z-compressed"
        case .bz2: return "application/x-bzip2"
        case .xz: return "application/x-xz"
        }
    }
    
    // MARK: - UTType
    
    var utType: UTType? {
        switch self {
        case .pdf: return .pdf
        case .docx: return UTType("org.openxmlformats.wordprocessingml.document")
        case .xlsx: return UTType("org.openxmlformats.spreadsheetml.sheet")
        case .pptx: return UTType("org.openxmlformats.presentationml.presentation")
        case .doc: return UTType("com.microsoft.word.doc")
        case .xls: return UTType("com.microsoft.excel.xls")
        case .ppt: return UTType("com.microsoft.powerpoint.ppt")
        case .odt: return UTType("org.oasis-open.opendocument.text")
        case .ods: return UTType("org.oasis-open.opendocument.spreadsheet")
        case .odp: return UTType("org.oasis-open.opendocument.presentation")
        case .rtf: return .rtf
        case .txt: return .plainText
        case .html: return .html
        case .csv: return .commaSeparatedText
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .webp: return .webP
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .svg: return .svg
        case .ico: return .ico
        case .avif: return UTType("public.avif")
        case .mp3: return .mp3
        case .wav: return .wav
        case .flac: return UTType("org.xiph.flac")
        case .aac: return UTType("public.aac-audio")
        case .m4a: return UTType("com.apple.m4a-audio")
        case .ogg: return UTType("org.xiph.ogg-vorbis")
        case .opus: return UTType("org.xiph.opus")
        case .aiff: return .aiff
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .mkv: return UTType("org.matroska.mkv")
        case .webm: return UTType("org.webmproject.webm")
        case .avi: return .avi
        case .wmv: return UTType("com.microsoft.windows-media-wmv")
        case .m4v: return UTType("com.apple.m4v-video")
        case .zip: return .zip
        case .tar: return UTType("public.tar-archive")
        case .gz: return .gzip
        case .tgz: return UTType("org.gnu.gnu-zip-tar-archive")
        case .sevenZ: return UTType("org.7-zip.7-zip-archive")
        case .bz2: return .bz2
        case .xz: return UTType("org.tukaani.xz-archive")
        }
    }
    
    // MARK: - System Image
    
    var systemImage: String {
        category.systemImage
    }
    
    // MARK: - Init from Extension
    
    static func from(extension ext: String) -> FileFormat? {
        let lowercased = ext.lowercased().trimmingCharacters(in: .punctuationCharacters)
        // Handle aliases
        switch lowercased {
        case "jpeg": return .jpg
        case "heif": return .heic
        case "tar.gz": return .tgz
        case "7z": return .sevenZ
        default:
            return FileFormat(rawValue: lowercased)
        }
    }
    
    // MARK: - Init from UTType
    
    static func from(utType: UTType) -> FileFormat? {
        for format in FileFormat.allCases {
            if let formatUTType = format.utType, utType.conforms(to: formatUTType) {
                return format
            }
        }
        return nil
    }
}
