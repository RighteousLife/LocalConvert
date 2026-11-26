import Foundation

// MARK: - Format Capability Declaration

struct FormatCapability: Sendable, Equatable, Codable, Identifiable {
    let format: FileFormat
    let category: FormatCategory
    let group: FormatGroup
    let displayName: String
    let fileExtension: String
    let aliases: [String]
    let mimeType: String
    let utTypeIdentifier: String?
    
    let canRead: Bool
    let canWrite: Bool
    let canDecode: Bool
    let canEncode: Bool
    
    let supportsMetadata: Bool
    let supportsMultiplePages: Bool
    let supportsAnimation: Bool
    let supportsTransparency: Bool
    let limitationNote: String?
    
    var id: String { format.rawValue }
    
    var isReadOnly: Bool {
        canRead && !canWrite
    }
    
    var isUnsupportedWrite: Bool {
        !canWrite
    }
}

// MARK: - Format Capability Registry (Single Source of Truth for Format Declarations)

final class FormatCapabilityRegistry: @unchecked Sendable {
    
    static let shared = FormatCapabilityRegistry()
    
    private let capabilitiesMap: [FileFormat: FormatCapability]
    
    private init() {
        var map: [FileFormat: FormatCapability] = [:]
        for format in FileFormat.allCases {
            map[format] = Self.buildCapability(for: format)
        }
        self.capabilitiesMap = map
    }
    
    var allCapabilities: [FormatCapability] {
        FileFormat.allCases.compactMap { capabilitiesMap[$0] }
    }
    
    func capability(for format: FileFormat) -> FormatCapability {
        capabilitiesMap[format] ?? Self.buildCapability(for: format)
    }
    
    func formats(in category: FormatCategory) -> [FileFormat] {
        FileFormat.allCases.filter { $0.category == category }
    }
    
    func readableFormats(in category: FormatCategory? = nil) -> [FileFormat] {
        FileFormat.allCases.filter { fmt in
            let cap = capability(for: fmt)
            return cap.canRead && (category == nil || cap.category == category)
        }
    }
    
    func writableFormats(in category: FormatCategory? = nil) -> [FileFormat] {
        FileFormat.allCases.filter { fmt in
            let cap = capability(for: fmt)
            return cap.canWrite && (category == nil || cap.category == category)
        }
    }
    
    func searchableCapabilities(matching query: String, category: FormatCategory? = nil) -> [FormatCapability] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCapabilities.filter { cap in
            if let category, cap.category != category {
                return false
            }
            guard !trimmed.isEmpty else { return true }
            if cap.displayName.lowercased().contains(trimmed) { return true }
            if cap.fileExtension.lowercased().contains(trimmed) { return true }
            if cap.format.rawValue.lowercased().contains(trimmed) { return true }
            if cap.mimeType.lowercased().contains(trimmed) { return true }
            if cap.aliases.contains(where: { $0.lowercased().contains(trimmed) }) { return true }
            if let note = cap.limitationNote, note.lowercased().contains(trimmed) { return true }
            return false
        }
    }
    
    // MARK: - Explicit Format Specifications
    
    private static func buildCapability(for format: FileFormat) -> FormatCapability {
        let metadataSupportedFormats: Set<FileFormat> = [
            .pdf,
            .docx, .xlsx, .pptx,
            .jpg, .png, .webp, .heic, .tiff, .bmp, .gif, .avif, .jp2, .psd, .exr, .jxl, .svg, .ico, .icns, .tga,
            .dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw,
            .mp3, .wav, .flac, .m4a, .m4b, .aac, .ogg, .opus, .aiff, .caf, .alac, .ac3, .eac3, .dts, .wma, .wv, .mka, .au,
            .mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v, .threeGP, .threeG2, .mts, .m2ts
        ]
        
        let aliases: [String]
        let canRead: Bool
        let canWrite: Bool
        let multiPage: Bool
        let animation: Bool
        let transparency: Bool
        let note: String?
        
        switch format {
        // MARK: Documents / Office
        case .pdf:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = true
            note = "Supports PDF ↔ Image, PDF → DOCX/XLSX/PPTX, and full PDF Toolbox operations."
        case .docx:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = nil
        case .doc:
            aliases = ["dot"]; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = "Legacy binary Word format via bundled LibreOffice."
        case .dotx:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = "Word OOXML template."
        case .docm:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "Read-only input; converting to DOCX/ODT/PDF strips VBA macros."
        case .xlsx:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = nil
        case .xls:
            aliases = ["xlt"]; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = "Legacy binary Excel format via bundled LibreOffice."
        case .xltx:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = "Excel OOXML template."
        case .xlsm:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "Read-only input; converting to XLSX/ODS/CSV/PDF strips VBA macros."
        case .xlsb:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "Read-only binary Excel workbook import via LibreOffice."
        case .pptx:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = nil
        case .ppt:
            aliases = ["pot"]; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = "Legacy binary PowerPoint presentation via bundled LibreOffice."
        case .potx:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = "PowerPoint OOXML template."
        case .pptm:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "Read-only input; converting to PPTX/ODP/PDF strips VBA macros."
        case .ppsx:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "PowerPoint Show read-only input via LibreOffice."
        case .pps:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "Legacy PowerPoint Show read-only input via LibreOffice."
        case .odt:
            aliases = ["fodt"]; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = nil
        case .ods:
            aliases = ["fods"]; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = nil
        case .odp:
            aliases = ["fodp"]; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = nil
        case .rtf:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = false
            note = nil
        case .csv:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Multi-sheet spreadsheets export the active/first sheet to CSV."
        case .tsv:
            aliases = ["tab"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Tab-separated values."
        case .txt:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = nil
        case .md:
            aliases = ["markdown"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Markdown conversion powered by LibreOffice 26.8."
        case .html:
            aliases = ["htm", "xhtml"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Uses Writer import filter for Word/EPUB conversion."
        case .epub:
            aliases = []; canRead = false; canWrite = true; multiPage = true; animation = false; transparency = false
            note = "Export target from Writer/Markdown/HTML documents via LibreOffice."
        case .pages:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "Read-only Apple Pages input; converts to PDF, DOCX, RTF, or TXT via Pages.app."
        case .numbers:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "Read-only Apple Numbers input; converts to PDF, XLSX, or CSV via Numbers.app."
        case .key:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = false; transparency = false
            note = "Read-only Apple Keynote input; converts to PDF or PPTX via Keynote.app."
        case .plist:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Apple Property List (Binary/XML) supporting bidirectional conversion with JSON and XML."
        case .ics:
            aliases = ["ical"]; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only iCalendar input; exports events to JSON, CSV, or TXT."
        case .vcf:
            aliases = ["vcard"]; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only vCard contact input; exports contacts to JSON, CSV, or TXT."
        case .webloc:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only macOS web internet location (.webloc) input; exports URL and metadata to JSON, TXT, Markdown, or CSV."
        case .json:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Structured JSON data format; supports PLIST ↔ JSON and export from ICS/VCF/WEBLOC."
        case .xml:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Structured XML format; supports PLIST ↔ XML conversion."
            
        // MARK: Images
        case .jpg:
            aliases = ["jpeg", "jfif", "jpe"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Lossy format; does not support alpha transparency."
        case .png:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = true
            note = nil
        case .webp:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = true; transparency = true
            note = "Lossy and lossless WebP via bundled libwebp with ICC/EXIF/XMP preservation and animated WebP decode."
        case .heic:
            aliases = ["heif", "hif"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = true
            note = nil
        case .heics, .heifs:
            aliases = []; canRead = true; canWrite = false; multiPage = true; animation = true; transparency = true
            note = "Read-only HEIF image sequence input decoded via macOS ImageIO to still images or animated GIF."
        case .tiff:
            aliases = ["tif"]; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = true
            note = "Supports 8/16-bit precision and multi-page TIFF preservation to TIFF/PDF."
        case .bmp:
            aliases = ["dib"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = nil
        case .gif:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = true; transparency = true
            note = "Supports animated GIF ↔ APNG and video → GIF; static targets flatten frame 0."
        case .apng:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = true; transparency = true
            note = "Animated PNG via bundled FFmpeg; preserves animation from GIF/Video."
        case .avif:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = true
            note = nil
        case .jp2:
            aliases = ["j2k", "jpf", "jpx", "j2c"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = true
            note = "JPEG 2000 via native macOS ImageIO."
        case .psd:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = true
            note = "Flattened Photoshop PSD composite via native ImageIO."
        case .exr:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = true
            note = "OpenEXR HDR image via native ImageIO."
        case .ppm:
            aliases = ["pgm", "pbm", "pnm", "pfm"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Netpbm portable bitmap/graymap/pixmap."
        case .hdr:
            aliases = ["rgbe"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Radiance RGBE HDR image (read via ImageIO, write via bundled FFmpeg)."
        case .jxl:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = true; transparency = true
            note = "Full decode and encode via bundled libjxl v0.13.0 (lossy/lossless, alpha, 8/16-bit, ICC/EXIF/XMP, animated JXL, and lossless JPEG transcoding)."
        case .qoi:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = true
            note = "Quite OK Image via bundled FFmpeg."
        case .pcx:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "PC Paintbrush raster format via bundled FFmpeg."
        case .wbmp:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "1-bit monochrome Wireless Bitmap via bundled FFmpeg."
        case .sgi:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = true
            note = "Read-only SGI RGB image via macOS ImageIO."
        case .xpm:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = true
            note = "Read-only X PixMap input via bundled FFmpeg."
        case .svg:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = true
            note = "Read-only vector input rasterized to bitmap/PDF targets."
        case .ico:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = true
            note = "Windows icon format (automatically scaled proportionally to ≤ 256×256 preserving alpha)."
        case .icns:
            aliases = []; canRead = true; canWrite = true; multiPage = true; animation = false; transparency = true
            note = "macOS multi-size icon set (16px to 512px)."
        case .tga:
            aliases = ["targa"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = true
            note = nil
        case .dng:
            aliases = ["raw", "rwl", "3fr", "fff", "iiq", "dcr", "mrw", "sr2", "srf", "erf", "crw", "mos"]
            canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only camera RAW input decoded via macOS ImageIO / Camera RAW (availability depends on macOS camera support and file variant)."
        case .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only camera RAW input decoded via macOS ImageIO / Camera RAW (availability depends on macOS camera support and file variant)."
            
        // MARK: Audio
        case .mp3, .wav, .flac, .m4a, .m4b, .m4r, .aac, .ogg, .opus, .aiff, .caf, .alac, .ac3, .eac3, .dts, .wma, .au, .wv, .mka:
            switch format {
            case .aiff: aliases = ["aif", "aifc"]
            case .au: aliases = ["snd"]
            default: aliases = []
            }
            canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            if format == .alac {
                note = "Apple Lossless (M4A/iPod-compatible container); M4A also accepts AAC."
            } else if format == .m4r {
                note = "iPhone ringtone (AAC in iPod/MP4 container; trimmed to max 30 seconds by default on export)."
            } else {
                note = nil
            }
        case .amr:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only input: bundled FFmpeg includes AMR-NB/AMR-WB decoders but no AMR encoder."
        case .ape:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only input: Monkey's Audio decoder only."
            
        // MARK: Video
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .asf, .m4v, .threeGP, .threeG2, .mpg, .ts, .flv, .f4v, .vob, .m2v:
            switch format {
            case .threeGP: aliases = ["3gpp"]
            case .threeG2: aliases = ["3gp2"]
            case .mpg: aliases = ["mpeg", "mpe"]
            default: aliases = []
            }
            canRead = true; canWrite = true; multiPage = false; animation = true; transparency = false
            note = format == .m2v ? "Video-only MPEG-2 elementary stream (audio omitted)." : nil
        case .mts, .m2ts:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = true; transparency = false
            note = "Read-only AVCHD/Blu-ray transport input."
        case .ogv:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = true; transparency = false
            note = "Read-only Ogg Theora input (libtheora encoder is not bundled)."
            
        // MARK: Subtitles
        case .srt, .vtt, .ass, .ssa:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Text subtitle format; supports conversion and extraction from video text subtitle tracks."
        case .sub:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only MicroDVD text subtitle input."
        case .sup:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Blu-ray PGS bitmap subtitle; cannot be converted to text subtitles without OCR."
            
        // MARK: Archives
        case .zip:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Standard ZIP container via macOS libarchive."
        case .tar:
            aliases = []; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = nil
        case .tgz:
            aliases = ["tar.gz"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = nil
        case .tbz2:
            aliases = ["tar.bz2", "tbz"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = nil
        case .txz:
            aliases = ["tar.xz"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = nil
        case .sevenZ:
            aliases = ["7zip"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "7-Zip container via macOS libarchive."
        case .gz:
            aliases = ["gzip"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Single-file gzip stream."
        case .bz2:
            aliases = ["bzip2"]; canRead = true; canWrite = true; multiPage = false; animation = false; transparency = false
            note = "Single-file bzip2 stream."
        case .xz:
            aliases = []; canRead = false; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Use .tar.xz for XZ-compressed archives."
        case .rar:
            aliases = []; canRead = true; canWrite = false; multiPage = false; animation = false; transparency = false
            note = "Read-only RAR unpacking via macOS libarchive (encrypted/unsupported solid RARs fail gracefully)."
        }
        
        return FormatCapability(
            format: format,
            category: format.category,
            group: format.group,
            displayName: format.displayName,
            fileExtension: format.fileExtension,
            aliases: aliases,
            mimeType: format.mimeType,
            utTypeIdentifier: format.utType?.identifier,
            canRead: canRead,
            canWrite: canWrite,
            canDecode: canRead,
            canEncode: canWrite,
            supportsMetadata: metadataSupportedFormats.contains(format),
            supportsMultiplePages: multiPage,
            supportsAnimation: animation,
            supportsTransparency: transparency,
            limitationNote: note
        )
    }
}
