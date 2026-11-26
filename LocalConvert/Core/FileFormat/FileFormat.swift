import Foundation
import UniformTypeIdentifiers

// MARK: - Format Category

enum FormatCategory: String, CaseIterable, Codable, Sendable {
    case image = "image"
    case document = "document"
    case audio = "audio"
    case video = "video"
    case subtitle = "subtitle"
    case archive = "archive"
    
    var displayName: String {
        switch self {
        case .image: return "Image"
        case .document: return "Document"
        case .audio: return "Audio"
        case .video: return "Video"
        case .subtitle: return "Subtitle"
        case .archive: return "Archive"
        }
    }
    
    var systemImage: String {
        switch self {
        case .document: return "doc.text"
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        }
    }
}

// MARK: - Format Group (UI Subsections)

enum FormatGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case images = "Images"
    case pdf = "PDF"
    case documents = "Documents"
    case spreadsheets = "Spreadsheets"
    case presentations = "Presentations"
    case audio = "Audio"
    case video = "Video"
    case subtitles = "Subtitles"
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
        case .subtitles: return 7
        case .archives: return 8
        }
    }
}

// MARK: - File Format

enum FileFormat: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    // Document / Office
    case pdf
    case docx
    case doc
    case dotx
    case docm
    case xlsx
    case xls
    case xltx
    case xlsm
    case xlsb
    case pptx
    case ppt
    case potx
    case pptm
    case ppsx
    case pps
    case odt
    case ods
    case odp
    case rtf
    case csv
    case tsv
    case txt
    case md
    case html
    case epub
    
    // Image & Camera RAW
    case jpg
    case png
    case webp
    case heic
    case tiff
    case bmp
    case gif
    case apng
    case avif
    case jp2
    case psd
    case exr
    case ppm
    case hdr
    case jxl
    case qoi
    case pcx
    case wbmp
    case sgi
    case xpm
    case svg
    case ico
    case icns
    case dng
    case cr2
    case cr3
    case nef
    case nrw
    case arw
    case raf
    case rw2
    case orf
    case pef
    case srw
    case tga
    
    // Audio
    case mp3
    case wav
    case flac
    case m4a
    case m4b
    case aac
    case ogg
    case opus
    case aiff
    case caf
    case alac
    case ac3
    case eac3
    case dts
    case wma
    case au
    case wv
    case mka
    case amr
    case ape
    
    // Video
    case mp4
    case mov
    case mkv
    case webm
    case avi
    case wmv
    case asf
    case m4v
    case threeGP = "3gp"
    case threeG2 = "3g2"
    case mts
    case m2ts
    case mpg
    case ts
    case flv
    case f4v
    case vob
    case m2v
    case ogv
    
    // Subtitles
    case srt
    case vtt
    case ass
    case ssa
    case sub
    case sup
    
    // Archive
    case zip
    case tar
    case gz
    case tgz
    case tbz2
    case txz
    case sevenZ = "7z"
    case bz2
    case xz
    case rar
    
    var id: String { rawValue }
    
    // MARK: - Extensions & Properties
    
    var fileExtension: String {
        switch self {
        case .tgz: return "tar.gz"
        case .tbz2: return "tar.bz2"
        case .txz: return "tar.xz"
        default: return rawValue
        }
    }
    
    /// Short extension badge label (uppercased in UI pickers)
    var shortExtensionLabel: String {
        switch self {
        case .tgz: return "TAR.GZ"
        case .tbz2: return "TAR.BZ2"
        case .txz: return "TAR.XZ"
        default: return rawValue.uppercased()
        }
    }
    
    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .docx: return "DOCX (Word)"
        case .doc: return "DOC (Legacy Word)"
        case .dotx: return "DOTX (Word Template)"
        case .docm: return "DOCM (Word Macro)"
        case .xlsx: return "XLSX (Excel)"
        case .xls: return "XLS (Legacy Excel)"
        case .xltx: return "XLTX (Excel Template)"
        case .xlsm: return "XLSM (Excel Macro)"
        case .xlsb: return "XLSB (Excel Binary)"
        case .pptx: return "PPTX (PowerPoint)"
        case .ppt: return "PPT (Legacy PowerPoint)"
        case .potx: return "POTX (PowerPoint Template)"
        case .pptm: return "PPTM (PowerPoint Macro)"
        case .ppsx: return "PPSX (PowerPoint Show)"
        case .pps: return "PPS (Legacy Show)"
        case .odt: return "ODT (OpenDocument Text)"
        case .ods: return "ODS (OpenDocument Sheet)"
        case .odp: return "ODP (OpenDocument Slides)"
        case .rtf: return "RTF (Rich Text)"
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .txt: return "TXT (Plain Text)"
        case .md: return "Markdown (MD)"
        case .html: return "HTML"
        case .epub: return "EPUB (eBook)"
        case .jpg: return "JPEG"
        case .png: return "PNG"
        case .webp: return "WebP"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .bmp: return "BMP"
        case .gif: return "GIF"
        case .apng: return "APNG (Animated PNG)"
        case .avif: return "AVIF"
        case .jp2: return "JPEG 2000 (JP2)"
        case .psd: return "PSD (Photoshop)"
        case .exr: return "OpenEXR (EXR)"
        case .ppm: return "PPM / Netpbm"
        case .hdr: return "Radiance HDR"
        case .jxl: return "JPEG XL (JXL)"
        case .qoi: return "QOI (Quite OK Image)"
        case .pcx: return "PCX"
        case .wbmp: return "WBMP"
        case .sgi: return "SGI"
        case .xpm: return "XPM"
        case .svg: return "SVG"
        case .ico: return "ICO"
        case .icns: return "ICNS (macOS Icon)"
        case .dng: return "DNG (RAW)"
        case .cr2: return "CR2 (Canon RAW)"
        case .cr3: return "CR3 (Canon RAW)"
        case .nef: return "NEF (Nikon RAW)"
        case .nrw: return "NRW (Nikon RAW)"
        case .arw: return "ARW (Sony RAW)"
        case .raf: return "RAF (Fujifilm RAW)"
        case .rw2: return "RW2 (Panasonic RAW)"
        case .orf: return "ORF (Olympus RAW)"
        case .pef: return "PEF (Pentax RAW)"
        case .srw: return "SRW (Samsung RAW)"
        case .tga: return "TGA (Targa)"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        case .m4a: return "M4A (AAC)"
        case .m4b: return "M4B (Audiobook)"
        case .aac: return "AAC"
        case .ogg: return "OGG"
        case .opus: return "Opus"
        case .aiff: return "AIFF"
        case .caf: return "CAF (Core Audio)"
        case .alac: return "ALAC (Apple Lossless)"
        case .ac3: return "AC-3 (Dolby Digital)"
        case .eac3: return "E-AC-3 (Dolby Digital+)"
        case .dts: return "DTS"
        case .wma: return "WMA (Windows Media)"
        case .au: return "AU (Sun Audio)"
        case .wv: return "WavPack (WV)"
        case .mka: return "MKA (Matroska Audio)"
        case .amr: return "AMR"
        case .ape: return "APE (Monkey's Audio)"
        case .mp4: return "MP4"
        case .mov: return "MOV (QuickTime)"
        case .mkv: return "MKV (Matroska)"
        case .webm: return "WebM"
        case .avi: return "AVI"
        case .wmv: return "WMV"
        case .asf: return "ASF"
        case .m4v: return "M4V"
        case .threeGP: return "3GP"
        case .threeG2: return "3G2"
        case .mts: return "MTS (AVCHD)"
        case .m2ts: return "M2TS (Blu-ray)"
        case .mpg: return "MPG (MPEG-2)"
        case .ts: return "TS (MPEG-TS)"
        case .flv: return "FLV (Flash Video)"
        case .f4v: return "F4V"
        case .vob: return "VOB (DVD Video)"
        case .m2v: return "M2V (MPEG-2 Video)"
        case .ogv: return "OGV (Ogg Theora)"
        case .srt: return "SRT (SubRip)"
        case .vtt: return "VTT (WebVTT)"
        case .ass: return "ASS (SubStation)"
        case .ssa: return "SSA (SubStation)"
        case .sub: return "SUB (MicroDVD)"
        case .sup: return "SUP (PGS Bitmap)"
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .gz: return "GZ (Gzip)"
        case .tgz: return "TAR.GZ"
        case .tbz2: return "TAR.BZ2"
        case .txz: return "TAR.XZ"
        case .sevenZ: return "7Z"
        case .bz2: return "BZ2 (Bzip2)"
        case .xz: return "XZ"
        case .rar: return "RAR"
        }
    }
    
    var category: FormatCategory {
        switch self {
        case .pdf, .docx, .doc, .dotx, .docm,
             .xlsx, .xls, .xltx, .xlsm, .xlsb,
             .pptx, .ppt, .potx, .pptm, .ppsx, .pps,
             .odt, .ods, .odp, .rtf, .csv, .tsv, .txt, .md, .html, .epub:
            return .document
        case .jpg, .png, .webp, .heic, .tiff, .bmp, .gif, .apng, .avif,
             .jp2, .psd, .exr, .ppm, .hdr, .jxl, .qoi, .pcx, .wbmp, .sgi, .xpm,
             .svg, .ico, .icns, .tga,
             .dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw:
            return .image
        case .mp3, .wav, .flac, .m4a, .m4b, .aac, .ogg, .opus, .aiff, .caf, .alac,
             .ac3, .eac3, .dts, .wma, .au, .wv, .mka, .amr, .ape:
            return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .asf, .m4v, .threeGP, .threeG2,
             .mts, .m2ts, .mpg, .ts, .flv, .f4v, .vob, .m2v, .ogv:
            return .video
        case .srt, .vtt, .ass, .ssa, .sub, .sup:
            return .subtitle
        case .zip, .tar, .gz, .tgz, .tbz2, .txz, .sevenZ, .bz2, .xz, .rar:
            return .archive
        }
    }
    
    var group: FormatGroup {
        switch self {
        case .pdf:
            return .pdf
        case .docx, .doc, .dotx, .docm, .odt, .rtf, .txt, .md, .html, .epub:
            return .documents
        case .xlsx, .xls, .xltx, .xlsm, .xlsb, .ods, .csv, .tsv:
            return .spreadsheets
        case .pptx, .ppt, .potx, .pptm, .ppsx, .pps, .odp:
            return .presentations
        case .jpg, .png, .webp, .heic, .tiff, .bmp, .gif, .apng, .avif,
             .jp2, .psd, .exr, .ppm, .hdr, .jxl, .qoi, .pcx, .wbmp, .sgi, .xpm,
             .svg, .ico, .icns, .tga,
             .dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw:
            return .images
        case .mp3, .wav, .flac, .m4a, .m4b, .aac, .ogg, .opus, .aiff, .caf, .alac,
             .ac3, .eac3, .dts, .wma, .au, .wv, .mka, .amr, .ape:
            return .audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv, .asf, .m4v, .threeGP, .threeG2,
             .mts, .m2ts, .mpg, .ts, .flv, .f4v, .vob, .m2v, .ogv:
            return .video
        case .srt, .vtt, .ass, .ssa, .sub, .sup:
            return .subtitles
        case .zip, .tar, .gz, .tgz, .tbz2, .txz, .sevenZ, .bz2, .xz, .rar:
            return .archives
        }
    }
    
    var mimeType: String {
        switch self {
        case .pdf: return "application/pdf"
        case .docx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .doc: return "application/msword"
        case .dotx: return "application/vnd.openxmlformats-officedocument.wordprocessingml.template"
        case .docm: return "application/vnd.ms-word.document.macroEnabled.12"
        case .xlsx: return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case .xls: return "application/vnd.ms-excel"
        case .xltx: return "application/vnd.openxmlformats-officedocument.spreadsheetml.template"
        case .xlsm: return "application/vnd.ms-excel.sheet.macroEnabled.12"
        case .xlsb: return "application/vnd.ms-excel.sheet.binary.macroEnabled.12"
        case .pptx: return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case .ppt: return "application/vnd.ms-powerpoint"
        case .potx: return "application/vnd.openxmlformats-officedocument.presentationml.template"
        case .pptm: return "application/vnd.ms-powerpoint.presentation.macroEnabled.12"
        case .ppsx: return "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
        case .pps: return "application/vnd.ms-powerpoint"
        case .odt: return "application/vnd.oasis.opendocument.text"
        case .ods: return "application/vnd.oasis.opendocument.spreadsheet"
        case .odp: return "application/vnd.oasis.opendocument.presentation"
        case .rtf: return "application/rtf"
        case .csv: return "text/csv"
        case .tsv: return "text/tab-separated-values"
        case .txt: return "text/plain"
        case .md: return "text/markdown"
        case .html: return "text/html"
        case .epub: return "application/epub+zip"
        case .jpg: return "image/jpeg"
        case .png: return "image/png"
        case .webp: return "image/webp"
        case .heic: return "image/heic"
        case .tiff: return "image/tiff"
        case .bmp: return "image/bmp"
        case .gif: return "image/gif"
        case .apng: return "image/apng"
        case .avif: return "image/avif"
        case .jp2: return "image/jp2"
        case .psd: return "image/vnd.adobe.photoshop"
        case .exr: return "image/x-exr"
        case .ppm: return "image/x-portable-pixmap"
        case .hdr: return "image/vnd.radiance"
        case .jxl: return "image/jxl"
        case .qoi: return "image/qoi"
        case .pcx: return "image/x-pcx"
        case .wbmp: return "image/vnd.wap.wbmp"
        case .sgi: return "image/x-sgi"
        case .xpm: return "image/x-xpixmap"
        case .svg: return "image/svg+xml"
        case .ico: return "image/x-icon"
        case .icns: return "image/icns"
        case .dng: return "image/x-adobe-dng"
        case .cr2, .cr3: return "image/x-canon-cr2"
        case .nef, .nrw: return "image/x-nikon-nef"
        case .arw: return "image/x-sony-arw"
        case .raf: return "image/x-fuji-raf"
        case .rw2: return "image/x-panasonic-rw2"
        case .orf: return "image/x-olympus-orf"
        case .pef: return "image/x-pentax-pef"
        case .srw: return "image/x-samsung-srw"
        case .tga: return "image/x-tga"
        case .mp3: return "audio/mpeg"
        case .wav: return "audio/wav"
        case .flac: return "audio/flac"
        case .m4a: return "audio/mp4"
        case .m4b: return "audio/mp4"
        case .aac: return "audio/aac"
        case .ogg: return "audio/ogg"
        case .opus: return "audio/opus"
        case .aiff: return "audio/aiff"
        case .caf: return "audio/x-caf"
        case .alac: return "audio/alac"
        case .ac3: return "audio/ac3"
        case .eac3: return "audio/eac3"
        case .dts: return "audio/vnd.dts"
        case .wma: return "audio/x-ms-wma"
        case .au: return "audio/basic"
        case .wv: return "audio/x-wavpack"
        case .mka: return "audio/x-matroska"
        case .amr: return "audio/amr"
        case .ape: return "audio/x-ape"
        case .mp4: return "video/mp4"
        case .mov: return "video/quicktime"
        case .mkv: return "video/x-matroska"
        case .webm: return "video/webm"
        case .avi: return "video/x-msvideo"
        case .wmv: return "video/x-ms-wmv"
        case .asf: return "video/x-ms-asf"
        case .m4v: return "video/x-m4v"
        case .threeGP: return "video/3gpp"
        case .threeG2: return "video/3gpp2"
        case .mts, .m2ts: return "video/mp2t"
        case .mpg: return "video/mpeg"
        case .ts: return "video/mp2t"
        case .flv: return "video/x-flv"
        case .f4v: return "video/x-f4v"
        case .vob: return "video/dvd"
        case .m2v: return "video/mpeg"
        case .ogv: return "video/ogg"
        case .srt: return "application/x-subrip"
        case .vtt: return "text/vtt"
        case .ass: return "text/x-ass"
        case .ssa: return "text/x-ssa"
        case .sub: return "text/x-microdvd"
        case .sup: return "application/x-pgs"
        case .zip: return "application/zip"
        case .tar: return "application/x-tar"
        case .gz: return "application/gzip"
        case .tgz: return "application/x-gtar"
        case .tbz2: return "application/x-bzip2"
        case .txz: return "application/x-xz"
        case .sevenZ: return "application/x-7z-compressed"
        case .bz2: return "application/x-bzip2"
        case .xz: return "application/x-xz"
        case .rar: return "application/vnd.rar"
        }
    }
    
    var utType: UTType? {
        switch self {
        case .pdf: return .pdf
        case .rtf: return .rtf
        case .csv: return .commaSeparatedText
        case .tsv: return .tabSeparatedText
        case .txt: return .plainText
        case .html: return .html
        case .epub: return .epub
        case .jpg: return .jpeg
        case .png, .apng: return .png
        case .webp: return .webP
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .gif: return .gif
        case .avif: return UTType("public.avif")
        case .jp2: return UTType("public.jpeg-2000")
        case .psd: return UTType("com.adobe.photoshop-image")
        case .exr: return UTType("com.ilm.openexr-image")
        case .ppm: return UTType("public.pbm")
        case .hdr: return UTType("public.radiance")
        case .jxl: return UTType("public.jpeg-xl")
        case .sgi: return UTType("com.sgi.sgi-image")
        case .svg: return .svg
        case .ico: return .ico
        case .icns: return .icns
        case .dng: return UTType("com.adobe.raw-image")
        case .cr2: return UTType("com.canon.cr2-raw-image")
        case .cr3: return UTType("com.canon.cr3-raw-image")
        case .nef: return UTType("com.nikon.raw-image")
        case .nrw: return UTType("com.nikon.nrw-raw-image")
        case .arw: return UTType("com.sony.arw-raw-image")
        case .raf: return UTType("com.fuji.raw-image")
        case .rw2: return UTType("com.panasonic.rw2-raw-image")
        case .orf: return UTType("com.olympus.or-raw-image")
        case .pef: return UTType("com.pentax.raw-image")
        case .srw: return UTType("com.samsung.raw-image")
        case .tga: return UTType("com.truevision.tga-image")
        case .mp3: return .mp3
        case .wav: return .wav
        case .aiff: return .aiff
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .avi: return .avi
        case .mpg: return .mpeg
        case .ts: return .mpeg2TransportStream
        case .zip: return .zip
        case .gz: return .gzip
        case .bz2: return .bz2
        default:
            return UTType(filenameExtension: fileExtension)
        }
    }
    
    var systemImage: String {
        category.systemImage
    }
    
    var isRawImage: Bool {
        switch self {
        case .dng, .cr2, .cr3, .nef, .nrw, .arw, .raf, .rw2, .orf, .pef, .srw:
            return true
        default:
            return false
        }
    }
    
    var isReadOnly: Bool {
        FormatCapabilityRegistry.shared.capability(for: self).isReadOnly
    }
    
    var capability: FormatCapability {
        FormatCapabilityRegistry.shared.capability(for: self)
    }
    
    // MARK: - Lookup Helpers
    
    /// Compound archive extensions recognized before `pathExtension`
    static let compoundExtensions: [(suffix: String, format: FileFormat)] = [
        (".tar.gz", .tgz),
        (".tar.bz2", .tbz2),
        (".tar.xz", .txz),
    ]
    
    /// Strips compound extensions such as `.tar.gz` before falling back to single-extension removal.
    static func baseNameByStrippingExtension(from url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for (suffix, _) in compoundExtensions {
            if lower.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
    
    static func from(extension ext: String) -> FileFormat? {
        let cleaned = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        switch cleaned {
        case "jpeg", "jfif", "jpe": return .jpg
        case "tif": return .tiff
        case "heif", "hif": return .heic
        case "dib": return .bmp
        case "j2k", "jpf", "jpx", "j2c": return .jp2
        case "pgm", "pbm", "pnm", "pfm": return .ppm
        case "rgbe": return .hdr
        case "targa": return .tga
        case "raw", "rwl", "3fr", "fff", "iiq", "dcr", "mrw", "sr2", "srf", "erf", "crw", "mos":
            return .dng
        case "markdown": return .md
        case "htm", "xhtml": return .html
        case "fodt": return .odt
        case "fods": return .ods
        case "fodp": return .odp
        case "dot": return .doc
        case "xlt": return .xls
        case "pot": return .ppt
        case "tab": return .tsv
        case "snd": return .au
        case "aif", "aifc": return .aiff
        case "3gp", "3gpp": return .threeGP
        case "3g2", "3gp2": return .threeG2
        case "mpeg", "mpe": return .mpg
        case "tar.gz": return .tgz
        case "tar.bz2", "tbz": return .tbz2
        case "tar.xz": return .txz
        case "gzip": return .gz
        case "bzip2": return .bz2
        case "7z", "7zip": return .sevenZ
        default:
            return FileFormat(rawValue: cleaned)
        }
    }
    
    static func from(utType: UTType) -> FileFormat? {
        for format in FileFormat.allCases {
            if let formatUTType = format.utType, utType.conforms(to: formatUTType) {
                return format
            }
        }
        if let ext = utType.preferredFilenameExtension {
            return from(extension: ext)
        }
        return nil
    }
}
