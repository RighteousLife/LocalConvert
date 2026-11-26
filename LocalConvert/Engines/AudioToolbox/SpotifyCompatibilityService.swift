import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import os.log

// MARK: - Spotify Format Capability & Result Models

enum SpotifyCompatibilityClassification: String, Codable, Sendable, CaseIterable, Identifiable {
    case officiallyDocumented = "Officially Documented"
    case conditional = "Conditional Compatibility"
    case unsupportedFormat = "Unsupported Format"
    case drmProtected = "DRM Protected"
    case unknownDRM = "Unknown"
    case incompatibleVideoContainer = "Incompatible Video Container"

    var id: String { rawValue }

    var isEligibleForNormalization: Bool {
        switch self {
        case .officiallyDocumented, .conditional:
            return true
        case .unsupportedFormat, .drmProtected, .unknownDRM, .incompatibleVideoContainer:
            return false
        }
    }
}

enum SpotifyDRMStatus: Sendable, Equatable, Codable {
    case notApplicable
    case noneDetected
    case unknown(reason: String)
    case protected(scheme: String, details: String)

    var label: String {
        switch self {
        case .notApplicable: return "None Expected"
        case .noneDetected: return "No DRM Flag Detected"
        case .unknown: return "Unknown"
        case .protected(let scheme, _): return "Protected (\(scheme))"
        }
    }

    var explanation: String? {
        switch self {
        case .notApplicable, .noneDetected:
            return nil
        case .unknown(let reason):
            return reason
        case .protected(_, let details):
            return details
        }
    }

    var blocksModification: Bool {
        switch self {
        case .protected, .unknown:
            return true
        case .notApplicable, .noneDetected:
            return false
        }
    }
}

enum SpotifyNormalizationResultState: String, Sendable, Equatable, Codable {
    case alreadyCompatible = "Already Compatible"
    case fixedSuccessfully = "Fixed Successfully"
    case conditionalCompatibility = "Conditional Compatibility"
    case unsupportedFormat = "Unsupported Format"
    case drmProtected = "DRM Protected"
    case failedValidation = "Failed Validation"
    case processingError = "Processing Error"
}

struct SpotifyArtworkEntry: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let index: Int
    let declaredMime: String?
    let detectedMime: String?
    let pictureType: UInt8?
    let pictureTypeName: String
    let description: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let byteCount: Int
    let isValid: Bool
    let corruptionReason: String?
    let thumbnailPNGData: Data?

    init(
        id: UUID = UUID(),
        index: Int,
        declaredMime: String?,
        detectedMime: String?,
        pictureType: UInt8?,
        pictureTypeName: String,
        description: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        byteCount: Int,
        isValid: Bool,
        corruptionReason: String? = nil,
        thumbnailPNGData: Data? = nil
    ) {
        self.id = id
        self.index = index
        self.declaredMime = declaredMime
        self.detectedMime = detectedMime
        self.pictureType = pictureType
        self.pictureTypeName = pictureTypeName
        self.description = description
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.isValid = isValid
        self.corruptionReason = corruptionReason
        self.thumbnailPNGData = thumbnailPNGData
    }
}

struct SpotifyArtworkAnalysis: Sendable, Equatable, Codable {
    let count: Int
    let frontCoverCount: Int
    let validCount: Int
    let corruptCount: Int
    let entries: [SpotifyArtworkEntry]

    static let empty = SpotifyArtworkAnalysis(count: 0, frontCoverCount: 0, validCount: 0, corruptCount: 0, entries: [])

    var primaryValidThumbnailData: Data? {
        entries.first(where: { $0.isValid && $0.pictureType == 0x03 })?.thumbnailPNGData
            ?? entries.first(where: { $0.isValid })?.thumbnailPNGData
    }

    var summaryText: String {
        if count == 0 { return "No embedded cover art" }
        var parts = ["\(count) image\(count == 1 ? "" : "s")"]
        if validCount > 0 { parts.append("\(validCount) valid") }
        if corruptCount > 0 { parts.append("\(corruptCount) corrupt") }
        if frontCoverCount > 0 { parts.append("\(frontCoverCount) Front Cover") }
        return parts.joined(separator: " · ")
    }
}

struct SpotifyMetadataSummary: Sendable, Equatable, Codable {
    let tagFormat: String
    let id3Version: String?
    let textEncodingSummary: String?
    let presentMP4Atoms: [String]
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let year: String?
    let trackNumber: String?
    let discNumber: String?
    let genre: String?
    let hasLyrics: Bool
    let additionalFramesOrAtoms: [String]
    let unsupportedOrLimitationNotes: [String]
    let isNormalizedProfile: Bool
    let normalizationNeededReasons: [String]

    static let empty = SpotifyMetadataSummary(
        tagFormat: "None",
        id3Version: nil,
        textEncodingSummary: nil,
        presentMP4Atoms: [],
        title: nil,
        artist: nil,
        album: nil,
        albumArtist: nil,
        year: nil,
        trackNumber: nil,
        discNumber: nil,
        genre: nil,
        hasLyrics: false,
        additionalFramesOrAtoms: [],
        unsupportedOrLimitationNotes: [],
        isNormalizedProfile: false,
        normalizationNeededReasons: []
    )
}

struct SpotifyAudioStreamVerification: Sendable, Equatable, Codable, Identifiable {
    var id: Int { streamIndex }
    let streamIndex: Int
    let containerStreamIndex: Int
    let codecName: String
    let codecProfile: String?
    let sampleRate: Int?
    let channels: Int?
    let channelLayout: String?
    let timeBase: String?
    let duration: String?
    let extradataHashSHA256: String?
    let packetCount: Int
    let totalPacketBytes: Int64
    let packetManifestSHA256: String
    let packetPayloadRollingSHA256: String
    let streamHashSHA256: String
}

enum SpotifyNormalizationFailureInjection: Sendable, Equatable {
    case none
    case beforeTempOutputCreation
    case duringMetadataWrite(truncateAfterBytes: Int)
    case duringPacketVerification
    case duringAtomicReplacement
}

struct SpotifyAnalysisReportItem: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let inputURL: URL
    let detectedExtension: String
    let containerFormat: String
    let audioCodec: String?
    let hasAudioStream: Bool
    let hasVideoStream: Bool
    let videoCodec: String?
    let duration: Double
    let bitRate: Int64?
    let sampleRate: Int?
    let channels: Int?
    let drmStatus: SpotifyDRMStatus
    let classification: SpotifyCompatibilityClassification
    let compatibilityReason: String
    var metadataSummary: SpotifyMetadataSummary
    var artworkAnalysis: SpotifyArtworkAnalysis
    var normalizationState: SpotifyNormalizationResultState?
    var normalizationActions: [String]
    var warnings: [String]
    var outputURL: URL?
    var preAudioHashSHA256: String?
    var postAudioHashSHA256: String?
    var audioPayloadVerified: Bool?
    var audioStreamsBefore: [SpotifyAudioStreamVerification] = []
    var audioStreamsAfter: [SpotifyAudioStreamVerification] = []
    var mp3RawSliceSHA256Before: String? = nil
    var mp3RawSliceSHA256After: String? = nil
    var mp3PacketCountBefore: Int? = nil
    var mp3PacketCountAfter: Int? = nil
}

struct SpotifyNormalizationOptions: Sendable, Equatable {
    var outputDirectory: URL
    var existingFileHandling: ExistingFileHandling = .createUnique
    var resizeOversizedArtwork: Bool = false
    var maxArtworkDimension: Int = 1000
    var singleFrontCoverOnly: Bool = false
    var failureInjection: SpotifyNormalizationFailureInjection = .none
}

// MARK: - Dedicated Spotify Format Capability Registry

enum SpotifyCompatibilityRegistry {

    static func classify(
        fileURL: URL,
        containerFormat: String,
        audioCodec: String?,
        hasAudioStream: Bool,
        hasRealVideo: Bool,
        videoCodec: String?,
        ftypMajorBrand: String?,
        drmStatus: SpotifyDRMStatus
    ) -> (classification: SpotifyCompatibilityClassification, reason: String) {
        let ext = fileURL.pathExtension.lowercased()
        let codec = audioCodec?.lowercased() ?? ""
        let container = containerFormat.lowercased()
        let brand = ftypMajorBrand?.uppercased() ?? ""

        if case .protected(_, let details) = drmStatus {
            return (.drmProtected, details)
        }
        if case .unknown(let reason) = drmStatus {
            return (.unknownDRM, reason)
        }

        if hasRealVideo {
            return (
                .incompatibleVideoContainer,
                "Contains an active video stream (\(videoCodec ?? "unknown")). Spotify local files require audio-only media."
            )
        }

        guard hasAudioStream, !codec.isEmpty else {
            return (.unsupportedFormat, "No playable audio stream was detected in this file.")
        }

        if ext == "mp3" {
            let validMP3Container = container.contains("mp3")
            if codec == "mp3" && validMP3Container {
                return (
                    .officiallyDocumented,
                    "Officially documented .mp3 container with MPEG Layer-3 audio stream (no video stream)."
                )
            }
            return (
                .unsupportedFormat,
                "File uses .mp3 extension, but probed content is container '\(containerFormat)' with codec '\(audioCodec ?? "unknown")'."
            )
        }

        if ext == "m4p" || brand == "M4P " {
            return (
                .unknownDRM,
                "M4P is an iTunes FairPlay DRM container format; inability to observe a DRM atom does not prove the stream is unencrypted."
            )
        }

        if ext == "mp4" {
            let isISOBMFF = container.contains("mp4") || container.contains("m4a") || container.contains("mov")
            guard isISOBMFF else {
                return (
                    .unsupportedFormat,
                    "File uses .mp4 extension, but container '\(containerFormat)' is not ISO Base Media / MP4."
                )
            }
            if codec == "alac" {
                return (.unsupportedFormat, "ALAC (Apple Lossless) inside MP4 is unsupported for Spotify local-file playback.")
            }
            if ["aac", "mp3"].contains(codec) {
                return (
                    .officiallyDocumented,
                    "Officially documented audio-only .mp4 container with \(codec.uppercased()) stream (no video track)."
                )
            }
            return (.unsupportedFormat, "Audio codec '\(codec.uppercased())' in .mp4 is not supported for Spotify local files.")
        }

        if ext == "m4a" || ext == "m4b" {
            let isISOBMFF = container.contains("mp4") || container.contains("m4a") || container.contains("mov")
            guard isISOBMFF else {
                return (.unsupportedFormat, "Container '\(containerFormat)' does not match ISO Base Media / M4A.")
            }
            if codec == "alac" {
                return (.unsupportedFormat, "ALAC / iTunes Lossless is unsupported by Spotify local files.")
            }
            if codec == "aac" {
                return (
                    .conditional,
                    "Conditional Compatibility: M4A (AAC) commonly plays via macOS/iOS decoders, but .m4a is not guaranteed on Spotify's officially documented extension list (.mp3, audio-only .mp4, .m4p)."
                )
            }
            return (.unsupportedFormat, "Codec '\(codec.uppercased())' in .\(ext) is unsupported for Spotify local files.")
        }

        return (
            .unsupportedFormat,
            "\(ext.isEmpty ? containerFormat.uppercased() : ext.uppercased()) (\(codec.uppercased())) may be decodable by LocalConvert/FFmpeg, but is not a supported Spotify local-file format."
        )
    }
}

// MARK: - Byte-Level Artwork Validator

enum SpotifyArtworkValidator {

    static func pictureTypeDescription(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "Other"
        case 0x01: return "32×32 File Icon"
        case 0x02: return "Other File Icon"
        case 0x03: return "Cover (front)"
        case 0x04: return "Cover (back)"
        case 0x05: return "Leaflet Page"
        case 0x06: return "Media"
        case 0x07: return "Lead Artist"
        case 0x08: return "Artist / Performer"
        default: return String(format: "Type 0x%02X", code)
        }
    }

    static func detectImageMIME(from data: Data) -> String? {
        guard data.count >= 8 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF {
            return "image/jpeg"
        }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
           b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A {
            return "image/png"
        }
        return nil
    }

    static func inspectArtwork(
        data: Data,
        index: Int,
        declaredMime: String?,
        pictureType: UInt8?,
        description: String?
    ) -> SpotifyArtworkEntry {
        let typeName = pictureType.map(pictureTypeDescription) ?? "Cover (front)"
        guard !data.isEmpty else {
            return SpotifyArtworkEntry(
                index: index, declaredMime: declaredMime, detectedMime: nil,
                pictureType: pictureType, pictureTypeName: typeName, description: description,
                pixelWidth: nil, pixelHeight: nil, byteCount: 0,
                isValid: false, corruptionReason: "Artwork payload is empty."
            )
        }

        let sigMIME = detectImageMIME(from: data)
        guard let verifiedMIME = sigMIME else {
            return SpotifyArtworkEntry(
                index: index, declaredMime: declaredMime, detectedMime: nil,
                pictureType: pictureType, pictureTypeName: typeName, description: description,
                pixelWidth: nil, pixelHeight: nil, byteCount: data.count,
                isValid: false,
                corruptionReason: "Image bytes do not match valid JPEG or PNG header signatures."
            )
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              cgImage.width > 0, cgImage.height > 0 else {
            return SpotifyArtworkEntry(
                index: index, declaredMime: declaredMime, detectedMime: verifiedMIME,
                pictureType: pictureType, pictureTypeName: typeName, description: description,
                pixelWidth: nil, pixelHeight: nil, byteCount: data.count,
                isValid: false,
                corruptionReason: "Artwork signature detected (\(verifiedMIME)), but image data failed decoding (corrupt bitmap)."
            )
        }

        let thumbData = makeThumbnailPNGData(from: source, maxSize: 96)
        return SpotifyArtworkEntry(
            index: index,
            declaredMime: declaredMime,
            detectedMime: verifiedMIME,
            pictureType: pictureType,
            pictureTypeName: typeName,
            description: description,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            byteCount: data.count,
            isValid: true,
            corruptionReason: nil,
            thumbnailPNGData: thumbData
        )
    }

    static func makeThumbnailPNGData(from source: CGImageSource, maxSize: Int = 96) -> Data? {
        guard let thumb = ImageProcessor.createThumbnail(from: source, index: 0, maxPixelSize: CGFloat(maxSize)) else {
            return nil
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, thumb, nil)
        return CGImageDestinationFinalize(dest) ? (data as Data) : nil
    }

    static func resizeIfRequested(
        data: Data,
        mime: String,
        maxDimension: Int
    ) throws -> (data: Data, mime: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw MetadataError.invalidArtwork("Cannot decode cover artwork for resizing.")
        }
        let maxEdge = max(cgImage.width, cgImage.height)
        guard maxEdge > maxDimension else {
            return (data, mime)
        }
        let scale = Double(maxDimension) / Double(maxEdge)
        let targetW = max(1, Int((Double(cgImage.width) * scale).rounded()))
        let targetH = max(1, Int((Double(cgImage.height) * scale).rounded()))
        let resized = try ImageProcessor.resampleCGImage(cgImage, width: targetW, height: targetH, method: .lanczos)
        let format: FileFormat = (mime == "image/png") ? .png : .jpg
        let encoded = try ImageProcessor.encodeToMemory(
            cgImage: resized,
            format: format,
            quality: 0.90,
            lossless: format == .png,
            sourceProperties: nil,
            preserveMetadata: false
        )
        return (encoded, mime)
    }
}

// MARK: - Streaming Binary MP3 ID3v2.3.0 Processor

enum SpotifyID3Processor {

    enum ID3Error: LocalizedError {
        case corruptHeader(String)
        case unrepresentableFrame(String)
        case corruptArtwork(String)

        var errorDescription: String? {
            switch self {
            case .corruptHeader(let msg): return msg
            case .unrepresentableFrame(let msg): return msg
            case .corruptArtwork(let msg): return msg
            }
        }
    }

    struct ParsedAPIC: Sendable {
        var declaredMime: String
        var detectedMime: String?
        var pictureType: UInt8
        var description: String
        var imageData: Data
        var rawWasUTF16OrCleanDescription: Bool
        var validation: SpotifyArtworkEntry
    }

    struct ParsedFrame: Sendable {
        let frameID: String
        let majorVersion: UInt8
        let flags: UInt16
        let payload: Data
    }

    struct ParsedTextEntry: Sendable {
        let lang: String
        let desc: String
        let text: String
        let wasUTF16: Bool
    }

    struct ParsedID3Tag: Sendable {
        let majorVersion: UInt8?
        let minorVersion: UInt8?
        let headerSizeBytes: Int
        let hasID3v1Footer: Bool
        let hasID3v24Footer: Bool
        let hadExtendedHeader: Bool
        let hadUnsynchronisation: Bool
        let audioStartOffset: UInt64
        let audioEndOffset: UInt64
        let title: String?
        let artist: String?
        let album: String?
        let albumArtist: String?
        let year: String?
        let dateDDMM: String?
        let timeHHMM: String?
        let track: String?
        let disc: String?
        let genre: String?
        let lyrics: String?
        let lyricsLang: String
        let lyricsDesc: String
        let comment: String?
        let allComments: [ParsedTextEntry]
        let allLyrics: [ParsedTextEntry]
        let txxxFrames: [(desc: String, value: String, wasUTF16: Bool)]
        let otherTextFrames: [(id: String, value: String, wasUTF16: Bool)]
        let apicFrames: [ParsedAPIC]
        let preservedRawFrames: [ParsedFrame]
        let encodingIssues: [String]
        let limitationNotes: [String]
        let isNormalizedProfile: Bool
        let normalizationNeededReasons: [String]
    }

    private static let v24OnlyFrameIDs: Set<String> = [
        "ASPI", "EQU2", "RVA2", "SEEK", "SIGN",
        "TDEN", "TDOR", "TDRL", "TDTG", "TIPL",
        "TMCL", "TMOO", "TPRO", "TSOA", "TSOP",
        "TSOT", "TSST"
    ]

    private static let v22ToV23FrameMap: [String: String] = [
        "BUF": "RBUF", "CNT": "PCNT", "COM": "COMM", "CRA": "AENC",
        "IPL": "IPLS", "MCI": "MCDI", "PIC": "APIC", "POP": "POPM",
        "TAL": "TALB", "TBP": "TBPM", "TCM": "TCOM", "TCO": "TCON",
        "TCR": "TCOP", "TDA": "TDAT", "TDY": "TDLY", "TEN": "TENC",
        "TFT": "TFLT", "TIM": "TIME", "TKE": "TKEY", "TLA": "TLAN",
        "TLE": "TLEN", "TMT": "TMED", "TOA": "TOPE", "TOF": "TOFN",
        "TOL": "TOLY", "TOR": "TORY", "TOT": "TOAL", "TP1": "TPE1",
        "TP2": "TPE2", "TP3": "TPE3", "TP4": "TPE4", "TPA": "TPOS",
        "TPB": "TPUB", "TRC": "TSRC", "TRD": "TRDA", "TRK": "TRCK",
        "TSI": "TSIZ", "TSS": "TSSE", "TT1": "TIT1", "TT2": "TIT2",
        "TT3": "TIT3", "TXT": "TEXT", "TXX": "TXXX", "TYE": "TYER",
        "UFI": "UFID", "ULT": "USLT", "WAF": "WOAF", "WAR": "WOAR",
        "WAS": "WOAS", "WCM": "WCOM", "WCP": "WCOP", "WPB": "WPUB",
        "WXX": "WXXX"
    ]

    private static func readUInt32BE(_ d: Data, at offset: Int) -> UInt32 {
        (UInt32(d[offset]) << 24) | (UInt32(d[offset + 1]) << 16) | (UInt32(d[offset + 2]) << 8) | UInt32(d[offset + 3])
    }

    private static func readSynchsafe(_ d: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= d.count else { return nil }
        for i in 0..<4 {
            if d[offset + i] & 0x80 != 0 { return nil }
        }
        return (Int(d[offset] & 0x7F) << 21)
            | (Int(d[offset + 1] & 0x7F) << 14)
            | (Int(d[offset + 2] & 0x7F) << 7)
            | Int(d[offset + 3] & 0x7F)
    }

    private static func writeUInt32BE(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func writeSynchsafe(_ v: Int) -> Data {
        Data([
            UInt8((v >> 21) & 0x7F),
            UInt8((v >> 14) & 0x7F),
            UInt8((v >> 7) & 0x7F),
            UInt8(v & 0x7F)
        ])
    }

    static func inspect(url: URL) throws -> ParsedID3Tag {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        let fileSize = (try? fh.seekToEnd()) ?? 0
        try fh.seek(toOffset: 0)

        let head = try fh.read(upToCount: 10) ?? Data()
        var majorVer: UInt8? = nil
        var minorVer: UInt8? = nil
        var headerTotalBytes = 0
        var tagBody = Data()
        var hasID3v24Footer = false
        var hadExtendedHeader = false
        var hadUnsynchronisation = false
        var reasons: [String] = []
        var limitationNotes: [String] = []

        if head.count >= 3 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33 { // "ID3"
            guard head.count == 10 else {
                throw ID3Error.corruptHeader("Truncated ID3v2 header (< 10 bytes).")
            }
            let mv = head[3]
            let rev = head[4]
            let hdrFlags = head[5]
            guard (2...4).contains(mv), rev != 0xFF,
                  let synchSize = readSynchsafe(head, at: 6) else {
                throw ID3Error.corruptHeader("Corrupt ID3v2 header signature or invalid synchsafe size.")
            }
            majorVer = mv
            minorVer = rev

            switch mv {
            case 2:
                if (hdrFlags & ~0xC0) != 0 {
                    throw ID3Error.corruptHeader("Invalid ID3v2.2 header flags: 0x\(String(format: "%02X", hdrFlags)).")
                }
                if (hdrFlags & 0x40) != 0 {
                    throw ID3Error.corruptHeader("ID3v2.2 tag-level compression flag (0x40) is unsupported by the ID3v2.2 specification.")
                }
            case 3:
                if (hdrFlags & ~0xE0) != 0 {
                    throw ID3Error.corruptHeader("Invalid ID3v2.3 header flags: 0x\(String(format: "%02X", hdrFlags)).")
                }
            case 4:
                if (hdrFlags & ~0xF0) != 0 {
                    throw ID3Error.corruptHeader("Invalid ID3v2.4 header flags: 0x\(String(format: "%02X", hdrFlags)).")
                }
            default:
                break
            }

            let footerBytes = (mv == 4 && (hdrFlags & 0x10) != 0) ? 10 : 0
            let (totalSigned, overflow) = UInt64(10).addingReportingOverflow(UInt64(synchSize))
            let (endPos, footerOverflow) = totalSigned.addingReportingOverflow(UInt64(footerBytes))
            guard !overflow, !footerOverflow, endPos <= fileSize else {
                throw ID3Error.corruptHeader("Truncated MP3 file: declared ID3v2 tag size (\(10 + synchSize + footerBytes) bytes) exceeds file size (\(fileSize) bytes).")
            }

            headerTotalBytes = 10 + synchSize + footerBytes
            if synchSize > 0 {
                tagBody = try fh.read(upToCount: synchSize) ?? Data()
                guard tagBody.count == synchSize else {
                    throw ID3Error.corruptHeader("Unable to read full ID3v2 tag payload.")
                }
            }

            if footerBytes == 10 {
                hasID3v24Footer = true
                let footer = try fh.read(upToCount: 10) ?? Data()
                guard footer.count == 10,
                      footer[0] == 0x33, footer[1] == 0x44, footer[2] == 0x49, // "3DI"
                      footer[3] == mv, footer[4] == rev,
                      let footerSize = readSynchsafe(footer, at: 6),
                      footerSize == synchSize else {
                    throw ID3Error.corruptHeader("Corrupt or truncated ID3v2.4 3DI footer.")
                }
                reasons.append("Contains ID3v2.4 3DI footer; strip and normalize to ID3v2.3.0.")
            }

            if (hdrFlags & 0x80) != 0 {
                hadUnsynchronisation = true
                tagBody = removeUnsynchronisation(tagBody)
                reasons.append("Tag uses ID3 unsynchronisation (0x80); normalize to clean ID3v2.3.0.")
            }
        }

        let audioStart = UInt64(headerTotalBytes)
        var audioEnd = fileSize
        var hasID3v1 = false
        var id3v1Title: String?
        var id3v1Artist: String?
        var id3v1Album: String?
        var id3v1Year: String?
        var id3v1Comment: String?
        var id3v1Track: String?

        if fileSize >= audioStart + 128 {
            try fh.seek(toOffset: fileSize - 128)
            if let footer = try fh.read(upToCount: 128),
               footer.count == 128,
               footer[0] == 0x54 && footer[1] == 0x41 && footer[2] == 0x47 { // "TAG"
                hasID3v1 = true
                audioEnd = fileSize - 128
                func trimmedLatin1(_ r: Range<Int>) -> String? {
                    let s = String(data: footer[r], encoding: .isoLatin1)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ").union(.whitespacesAndNewlines))
                    return (s?.isEmpty == false) ? s : nil
                }
                id3v1Title = trimmedLatin1(3..<33)
                id3v1Artist = trimmedLatin1(33..<63)
                id3v1Album = trimmedLatin1(63..<93)
                id3v1Year = trimmedLatin1(93..<97)
                id3v1Comment = trimmedLatin1(97..<125)
                if footer[125] == 0 && footer[126] != 0 {
                    id3v1Track = String(footer[126])
                }
            }
        }

        // Parse ID3v2 frames
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var year: String?
        var dateDDMM: String?
        var timeHHMM: String?
        var track: String?
        var disc: String?
        var genre: String?
        var allLyrics: [ParsedTextEntry] = []
        var allComments: [ParsedTextEntry] = []
        var txxxFrames: [(desc: String, value: String, wasUTF16: Bool)] = []
        var otherTextFrames: [(id: String, value: String, wasUTF16: Bool)] = []
        var apicFrames: [ParsedAPIC] = []
        var preservedRawFrames: [ParsedFrame] = []
        var encodingIssues: [String] = []
        var seenSingleValueFrames: [String: String] = [:]

        if let mv = majorVer {
            if mv == 4 { reasons.append("ID3v2.4 tag present; should convert to ID3v2.3.0") }
            if mv == 2 { reasons.append("Legacy ID3v2.2 tag present; should upgrade to ID3v2.3.0") }

            var pos = 0
            // Strictly validate & skip ID3v2.3/2.4 extended header if flag 0x40 set
            if (mv == 3 || mv == 4) && (head[5] & 0x40) != 0 {
                hadExtendedHeader = true
                if mv == 4 {
                    guard tagBody.count >= 6,
                          let extSize = readSynchsafe(tagBody, at: 0),
                          extSize >= 6,
                          extSize <= tagBody.count else {
                        throw ID3Error.corruptHeader("Truncated or invalid ID3v2.4 extended header.")
                    }
                    pos = extSize
                } else {
                    guard tagBody.count >= 4 else {
                        throw ID3Error.corruptHeader("Truncated ID3v2.3 extended header.")
                    }
                    let extBodySize = Int(readUInt32BE(tagBody, at: 0))
                    guard extBodySize >= 6, 4 + extBodySize <= tagBody.count else {
                        throw ID3Error.corruptHeader("Invalid ID3v2.3 extended header size (\(extBodySize)).")
                    }
                    pos = 4 + extBodySize
                }
                reasons.append("Contains ID3v2.\(mv) extended header; normalize to plain ID3v2.3.0.")
            }

            let minHeaderLen = (mv == 2) ? 6 : 10
            var parsedAPICIdx = 0

            while pos + minHeaderLen <= tagBody.count {
                if tagBody[pos] == 0 {
                    if tagBody[pos..<tagBody.count].contains(where: { $0 != 0 }) {
                        throw ID3Error.corruptHeader("Non-zero trailing garbage detected inside ID3v2 padding at byte offset \(pos + 10).")
                    }
                    pos = tagBody.count
                    break
                }

                let rawID: String
                let frameSize: Int
                let frameFlags: UInt16
                let frameHeaderLen: Int

                if mv == 2 {
                    let idData = tagBody[pos..<(pos + 3)]
                    rawID = String(data: idData, encoding: .ascii) ?? ""
                    frameSize = (Int(tagBody[pos + 3]) << 16) | (Int(tagBody[pos + 4]) << 8) | Int(tagBody[pos + 5])
                    frameFlags = 0
                    frameHeaderLen = 6
                } else {
                    let idData = tagBody[pos..<(pos + 4)]
                    rawID = String(data: idData, encoding: .ascii) ?? ""
                    if mv == 4 {
                        guard let sz = readSynchsafe(tagBody, at: pos + 4) else {
                            throw ID3Error.corruptHeader("Corrupt synchsafe size on ID3v2.4 frame '\(rawID)'.")
                        }
                        frameSize = sz
                    } else {
                        let rawU32 = readUInt32BE(tagBody, at: pos + 4)
                        guard rawU32 <= UInt32(tagBody.count) else {
                            throw ID3Error.corruptHeader("ID3v2.3 frame '\(rawID)' size (\(rawU32)) exceeds tag payload.")
                        }
                        frameSize = Int(rawU32)
                    }
                    frameFlags = (UInt16(tagBody[pos + 8]) << 8) | UInt16(tagBody[pos + 9])
                    frameHeaderLen = 10
                }

                guard isValidFrameID(rawID, version: mv) else {
                    throw ID3Error.corruptHeader("Encountered corrupt or invalid ID3 frame identifier at byte offset \(pos + 10).")
                }
                guard frameSize > 0 else {
                    throw ID3Error.corruptHeader("Encountered invalid zero-length ID3 frame '\(rawID)' at byte offset \(pos + 10).")
                }

                let (payloadStart, startOverflow) = pos.addingReportingOverflow(frameHeaderLen)
                let (payloadEnd, endOverflow) = payloadStart.addingReportingOverflow(frameSize)
                guard !startOverflow, !endOverflow, payloadEnd <= tagBody.count else {
                    throw ID3Error.corruptHeader("Truncated ID3 frame '\(rawID)' (frame size \(frameSize) exceeds remaining tag bytes).")
                }

                var payload = Data(tagBody[payloadStart..<payloadEnd])
                pos = payloadEnd

                if mv == 4 {
                    if (frameFlags & 0x0040) != 0 {
                        limitationNotes.append("Frame '\(rawID)' uses ID3v2.4 grouping identity (0x40), which cannot be losslessly flattened without dropping group metadata.")
                        continue
                    }
                    if (frameFlags & 0x000C) != 0 {
                        limitationNotes.append("Frame '\(rawID)' uses ID3v2.4 compression/encryption unsupported in plain ID3v2.3.0.")
                        continue
                    }
                    if (frameFlags & 0x00B0) != 0 {
                        limitationNotes.append("Frame '\(rawID)' uses unsupported ID3v2.4 frame format flags (0x\(String(format: "%04X", frameFlags))).")
                        continue
                    }
                    var declaredLen: Int? = nil
                    if (frameFlags & 0x0001) != 0 {
                        guard payload.count >= 4, let dli = readSynchsafe(payload, at: 0) else {
                            throw ID3Error.corruptHeader("Corrupt Data Length Indicator on ID3v2.4 frame '\(rawID)'.")
                        }
                        declaredLen = dli
                        payload = Data(payload.dropFirst(4))
                    }
                    if (frameFlags & 0x0002) != 0 {
                        hadUnsynchronisation = true
                        reasons.append("Frame '\(rawID)' uses frame-level unsynchronisation; normalize to clean ID3v2.3.0.")
                        if (head[5] & 0x80) == 0 {
                            payload = removeUnsynchronisation(payload)
                        }
                    }
                    if let declaredLen, payload.count != declaredLen {
                        throw ID3Error.corruptHeader("ID3v2.4 frame '\(rawID)' de-unsynchronised length (\(payload.count)) disagrees with Data Length Indicator (\(declaredLen)).")
                    }
                } else if mv == 3 {
                    if (frameFlags & 0x00E0) != 0 {
                        limitationNotes.append("Frame '\(rawID)' uses ID3v2.3 compression/encryption/grouping flags unsupported for safe re-encoding.")
                        continue
                    }
                }

                let mappedID: String
                if mv == 2 {
                    guard let converted = mapV22FrameID(rawID) else {
                        limitationNotes.append("Unmapped ID3v2.2 frame '\(rawID)' cannot be losslessly converted to ID3v2.3.0.")
                        continue
                    }
                    mappedID = converted
                } else {
                    mappedID = rawID
                }

                if mv == 4 && v24OnlyFrameIDs.contains(mappedID) {
                    limitationNotes.append("ID3v2.4-specific frame '\(mappedID)' has no direct lossless equivalent in strict ID3v2.3.0.")
                    preservedRawFrames.append(ParsedFrame(frameID: mappedID, majorVersion: mv, flags: frameFlags, payload: payload))
                    continue
                }

                func recordSingleTextFrame(_ id: String, value decoded: String) {
                    if let prev = seenSingleValueFrames[id] {
                        let prevTrim = prev.trimmingCharacters(in: .whitespacesAndNewlines)
                        let newTrim = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                        if prevTrim == newTrim || newTrim.isEmpty {
                            reasons.append("Duplicate '\(id)' frame detected; consolidate to canonical single frame.")
                        } else if prevTrim.isEmpty {
                            seenSingleValueFrames[id] = decoded
                            reasons.append("Duplicate '\(id)' frame detected; consolidate empty duplicate.")
                        } else {
                            limitationNotes.append("Conflicting duplicate '\(id)' frames ('\(prevTrim)' vs '\(newTrim)'); refusing to silently drop distinct metadata.")
                        }
                    } else {
                        seenSingleValueFrames[id] = decoded
                    }
                }

                switch mappedID {
                case "TIT2", "TPE1", "TALB", "TPE2", "TCON", "TRCK", "TPOS", "TYER", "TDAT", "TIME", "TDRC":
                    let (decoded, enc) = decodeID3TextPayload(payload)
                    if enc != 0x01 {
                        encodingIssues.append("\(mappedID) uses encoding \(String(format: "0x%02X", enc)) instead of UTF-16 (0x01).")
                    }
                    if mappedID == "TDRC" {
                        reasons.append("Contains ID3v2.4 TDRC frame; normalize date to ID3v2.3 TYER/TDAT.")
                        if let parsedDate = parseTDRCComponents(decoded) {
                            if let prevYear = seenSingleValueFrames["TYER"], !prevYear.isEmpty, prevYear != parsedDate.year {
                                limitationNotes.append("Conflicting ID3v2.4 TDRC year '\(parsedDate.year)' and TYER '\(prevYear)'.")
                            } else {
                                seenSingleValueFrames["TYER"] = parsedDate.year
                                year = parsedDate.year
                            }
                            if let ddmm = parsedDate.ddmm {
                                dateDDMM = dateDDMM ?? ddmm
                            }
                            if let hhmm = parsedDate.hhmm {
                                timeHHMM = timeHHMM ?? hhmm
                            }
                        } else if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            limitationNotes.append("ID3v2.4 TDRC timestamp '\(decoded)' cannot be losslessly converted to ID3v2.3 TYER/TDAT.")
                        }
                    } else {
                        recordSingleTextFrame(mappedID, value: decoded)
                        switch mappedID {
                        case "TIT2": if (title ?? "").isEmpty { title = decoded }
                        case "TPE1": if (artist ?? "").isEmpty { artist = decoded }
                        case "TALB": if (album ?? "").isEmpty { album = decoded }
                        case "TPE2": if (albumArtist ?? "").isEmpty { albumArtist = decoded }
                        case "TCON": if (genre ?? "").isEmpty { genre = decoded }
                        case "TRCK": if (track ?? "").isEmpty { track = decoded }
                        case "TPOS": if (disc ?? "").isEmpty { disc = decoded }
                        case "TYER": if (year ?? "").isEmpty { year = decoded }
                        case "TDAT": if (dateDDMM ?? "").isEmpty { dateDDMM = decoded }
                        case "TIME": if (timeHHMM ?? "").isEmpty { timeHHMM = decoded }
                        default: break
                        }
                    }
                case "TXXX":
                    let (desc, val, enc) = decodeTXXXPayload(payload)
                    if enc != 0x01 {
                        encodingIssues.append("TXXX:\(desc) uses non-UTF-16 encoding.")
                    }
                    if desc.lowercased() == "lyrics" || desc.lowercased() == "uslt" || desc.lowercased().hasPrefix("lyrics-") {
                        if allLyrics.isEmpty && !val.isEmpty {
                            allLyrics.append(ParsedTextEntry(lang: "eng", desc: "", text: val, wasUTF16: enc == 0x01))
                            reasons.append("Lyrics stored in TXXX:\(desc); normalize to native USLT frame.")
                        } else if !val.isEmpty {
                            txxxFrames.append((desc, val, enc == 0x01))
                        }
                    } else {
                        txxxFrames.append((desc, val, enc == 0x01))
                    }
                case "USLT":
                    let (lang, desc, text, enc) = decodeUSLTOrCOMMPayload(payload)
                    allLyrics.append(ParsedTextEntry(lang: lang, desc: desc, text: text, wasUTF16: enc == 0x01))
                    if enc != 0x01 {
                        encodingIssues.append("USLT uses non-UTF-16 encoding.")
                    }
                case "COMM":
                    let (lang, desc, text, enc) = decodeUSLTOrCOMMPayload(payload)
                    allComments.append(ParsedTextEntry(lang: lang, desc: desc, text: text, wasUTF16: enc == 0x01))
                    if enc != 0x01 {
                        encodingIssues.append("COMM uses non-UTF-16 encoding.")
                    }
                case "APIC":
                    let apic = parseAPICFrame(payload: payload, rawVersion: mv, index: parsedAPICIdx)
                    parsedAPICIdx += 1
                    apicFrames.append(apic)
                    if apic.validation.isValid,
                       let det = apic.detectedMime,
                       det.lowercased() != apic.declaredMime.lowercased() {
                        reasons.append("APIC #\(apic.validation.index + 1) MIME mismatch ('\(apic.declaredMime)' vs actual '\(det)').")
                    }
                    if !apic.rawWasUTF16OrCleanDescription {
                        reasons.append("APIC #\(apic.validation.index + 1) description encoding should use UTF-16.")
                    }
                default:
                    if mappedID.hasPrefix("T") && mappedID != "TXX" && payload.count >= 1 {
                        let (decoded, enc) = decodeID3TextPayload(payload)
                        if enc != 0x01 {
                            encodingIssues.append("\(mappedID) uses non-UTF-16 encoding.")
                        }
                        otherTextFrames.append((mappedID, decoded, enc == 0x01))
                    } else {
                        preservedRawFrames.append(ParsedFrame(frameID: mappedID, majorVersion: mv, flags: frameFlags, payload: payload))
                    }
                }
            }

            // Catch truncated/non-zero trailing bytes shorter than minHeaderLen
            if pos < tagBody.count && tagBody[pos..<tagBody.count].contains(where: { $0 != 0 }) {
                throw ID3Error.corruptHeader("Trailing truncated or corrupt bytes at end of ID3v2 tag (offset \(pos + 10)).")
            }
        } else {
            reasons.append("Missing ID3v2.3.0 header.")
        }

        if title == nil { title = id3v1Title }
        if artist == nil { artist = id3v1Artist }
        if album == nil { album = id3v1Album }
        if year == nil { year = id3v1Year }
        if allComments.isEmpty, let c = id3v1Comment {
            allComments.append(ParsedTextEntry(lang: "eng", desc: "", text: c, wasUTF16: false))
        }
        if track == nil { track = id3v1Track }

        if hasID3v1 && majorVer == nil {
            reasons.append("Only legacy ID3v1 tag present; upgrade to ID3v2.3.0.")
        }
        if !encodingIssues.isEmpty {
            reasons.append("Non-UTF-16 ID3 frame encoding detected.")
        }
        if apicFrames.contains(where: { !$0.validation.isValid }) {
            reasons.append("Corrupt embedded APIC artwork detected.")
        }
        if apicFrames.contains(where: { $0.validation.isValid }) && !apicFrames.contains(where: { $0.validation.isValid && $0.pictureType == 0x03 }) {
            reasons.append("Embedded cover art lacks Front Cover (0x03) APIC role.")
        }
        if !limitationNotes.isEmpty {
            reasons.append("Contains ID3 frames with representation limitations.")
        }

        let isAlreadyID3v23Normalized = (majorVer == 3 && reasons.isEmpty)

        return ParsedID3Tag(
            majorVersion: majorVer,
            minorVersion: minorVer,
            headerSizeBytes: headerTotalBytes,
            hasID3v1Footer: hasID3v1,
            hasID3v24Footer: hasID3v24Footer,
            hadExtendedHeader: hadExtendedHeader,
            hadUnsynchronisation: hadUnsynchronisation,
            audioStartOffset: audioStart,
            audioEndOffset: audioEnd,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            year: year,
            dateDDMM: dateDDMM,
            timeHHMM: timeHHMM,
            track: track,
            disc: disc,
            genre: genre,
            lyrics: allLyrics.first(where: { !$0.text.isEmpty })?.text,
            lyricsLang: allLyrics.first(where: { !$0.text.isEmpty })?.lang ?? "eng",
            lyricsDesc: allLyrics.first(where: { !$0.text.isEmpty })?.desc ?? "",
            comment: allComments.first(where: { !$0.text.isEmpty })?.text,
            allComments: allComments,
            allLyrics: allLyrics,
            txxxFrames: txxxFrames,
            otherTextFrames: otherTextFrames,
            apicFrames: apicFrames,
            preservedRawFrames: preservedRawFrames,
            encodingIssues: encodingIssues,
            limitationNotes: limitationNotes,
            isNormalizedProfile: isAlreadyID3v23Normalized,
            normalizationNeededReasons: reasons
        )
    }

    static func computeRawMPEGAudioSHA256(url: URL, parsed: ParsedID3Tag) throws -> String {
        guard parsed.audioEndOffset >= parsed.audioStartOffset else {
            throw ID3Error.corruptHeader("Invalid MPEG audio byte bounds.")
        }
        return try SpotifyAudioHashUtility.sha256FileSlice(
            url: url,
            startOffset: parsed.audioStartOffset,
            endOffset: parsed.audioEndOffset
        )
    }

    static func writeNormalizedID3v23(
        from inputURL: URL,
        to outputTempURL: URL,
        parsed: ParsedID3Tag,
        resizeOversizedArtwork: Bool,
        maxArtworkDimension: Int,
        singleFrontCoverOnly: Bool,
        truncateAfterBytes: Int? = nil
    ) throws -> (actions: [String], warnings: [String]) {
        if let corrupt = parsed.apicFrames.first(where: { !$0.validation.isValid }) {
            throw ID3Error.corruptArtwork(corrupt.validation.corruptionReason ?? "Corrupt APIC artwork.")
        }
        if !parsed.limitationNotes.isEmpty {
            throw ID3Error.unrepresentableFrame(parsed.limitationNotes.joined(separator: " "))
        }

        var actions: [String] = []
        var warnings: [String] = []
        var tagFramesData = Data()

        func appendFrame(id: String, flags: UInt16 = 0, payload: Data) throws {
            guard id.count == 4, let idData = id.data(using: .ascii) else {
                throw ID3Error.unrepresentableFrame("Refused non-4-character ID3v2.3 frame ID '\(id)'.")
            }
            tagFramesData.append(idData)
            tagFramesData.append(writeUInt32BE(UInt32(payload.count)))
            tagFramesData.append(UInt8((flags >> 8) & 0xFF))
            tagFramesData.append(UInt8(flags & 0xFF))
            tagFramesData.append(payload)
        }

        func appendTextFrame(id: String, value: String?) throws {
            guard let val = value, !val.isEmpty else { return }
            try appendFrame(id: id, payload: encodeUTF16TextPayload(val))
        }

        try appendTextFrame(id: "TIT2", value: parsed.title)
        try appendTextFrame(id: "TPE1", value: parsed.artist)
        try appendTextFrame(id: "TALB", value: parsed.album)
        try appendTextFrame(id: "TPE2", value: parsed.albumArtist)
        try appendTextFrame(id: "TYER", value: normalizeYearString(parsed.year))
        try appendTextFrame(id: "TDAT", value: parsed.dateDDMM)
        try appendTextFrame(id: "TIME", value: parsed.timeHHMM)
        try appendTextFrame(id: "TRCK", value: parsed.track)
        try appendTextFrame(id: "TPOS", value: parsed.disc)
        try appendTextFrame(id: "TCON", value: parsed.genre)

        for other in parsed.otherTextFrames where !other.value.isEmpty {
            try appendTextFrame(id: other.id, value: other.value)
        }
        for txxx in parsed.txxxFrames {
            try appendFrame(id: "TXXX", payload: encodeUTF16TXXXPayload(desc: txxx.desc, value: txxx.value))
        }
        for c in parsed.allComments where !c.text.isEmpty {
            try appendFrame(id: "COMM", payload: encodeUTF16LangDescPayload(lang: c.lang, desc: c.desc, text: c.text))
        }
        for l in parsed.allLyrics where !l.text.isEmpty {
            try appendFrame(id: "USLT", payload: encodeUTF16LangDescPayload(lang: l.lang, desc: l.desc, text: l.text))
        }

        let validAPICs = parsed.apicFrames.filter { $0.validation.isValid }
        let hasExistingFront = validAPICs.contains { $0.pictureType == 0x03 }
        var assignedFront = false

        for (idx, apic) in validAPICs.enumerated() {
            if singleFrontCoverOnly && idx > 0 {
                warnings.append("Secondary artwork frame #\(idx + 1) omitted because Single Front Cover mode was enabled.")
                continue
            }
            var finalMime = apic.validation.detectedMime ?? apic.declaredMime
            var finalBytes = apic.imageData
            if resizeOversizedArtwork {
                let res = try SpotifyArtworkValidator.resizeIfRequested(data: finalBytes, mime: finalMime, maxDimension: maxArtworkDimension)
                if res.data.count != finalBytes.count {
                    actions.append("Resized cover art #\(idx + 1) within \(maxArtworkDimension) px.")
                }
                finalBytes = res.data
                finalMime = res.mime
            } else if let w = apic.validation.pixelWidth, let h = apic.validation.pixelHeight,
                      max(w, h) > maxArtworkDimension {
                warnings.append("Artwork #\(idx + 1) (\(w)×\(h) px) exceeds \(maxArtworkDimension) px; preserved untouched because resizing is opt-in.")
            }

            let targetPicType: UInt8
            if apic.pictureType == 0x03 {
                targetPicType = 0x03
                assignedFront = true
            } else if !hasExistingFront && !assignedFront {
                targetPicType = 0x03
                assignedFront = true
                actions.append("Promoted artwork #\(idx + 1) to APIC Front Cover (0x03).")
            } else {
                targetPicType = apic.pictureType
            }

            // Preserve original APIC description verbatim so pass #2 is strictly idempotent
            try appendFrame(
                id: "APIC",
                payload: encodeAPICPayload(mime: finalMime, pictureType: targetPicType, description: apic.description, imageData: finalBytes)
            )
        }

        for raw in parsed.preservedRawFrames {
            try appendFrame(id: raw.frameID, flags: raw.flags, payload: raw.payload)
        }

        // Write clean ID3v2.3.0 header + 1 KB zero padding + streamed MPEG audio frames
        let paddingBytes = Data(repeating: 0, count: 1024)
        let totalTagSize = tagFramesData.count + paddingBytes.count
        var header = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00]) // ID3 v2.3.0
        header.append(writeSynchsafe(totalTagSize))

        if parsed.majorVersion == 4 { actions.append("Converted ID3v2.4 → ID3v2.3.0.") }
        else if parsed.majorVersion == 2 { actions.append("Upgraded ID3v2.2 → ID3v2.3.0.") }
        else if parsed.majorVersion == nil { actions.append("Created ID3v2.3.0 header.") }
        else { actions.append("Re-encoded ID3v2.3.0 metadata with UTF-16 frames.") }
        if parsed.hasID3v24Footer { actions.append("Stripped ID3v2.4 3DI footer.") }
        if parsed.hadUnsynchronisation { actions.append("Removed ID3 unsynchronisation.") }
        if parsed.hadExtendedHeader { actions.append("Removed extended ID3 header.") }

        FileManager.default.createFile(atPath: outputTempURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outputTempURL)
        defer { try? outHandle.close() }
        try outHandle.write(contentsOf: header)
        if let truncateAfterBytes {
            try outHandle.write(contentsOf: tagFramesData.prefix(max(0, min(truncateAfterBytes, tagFramesData.count))))
            throw ID3Error.corruptHeader("Injected failure during ID3 metadata write after \(truncateAfterBytes) bytes.")
        }
        try outHandle.write(contentsOf: tagFramesData)
        try outHandle.write(contentsOf: paddingBytes)

        let inHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inHandle.close() }
        try SpotifyAudioHashUtility.copySlice(
            from: inHandle,
            to: outHandle,
            startOffset: parsed.audioStartOffset,
            endOffset: parsed.audioEndOffset
        )

        return (actions, warnings)
    }

    // MARK: - ID3 Helpers

    private static func isValidFrameID(_ id: String, version: UInt8) -> Bool {
        let expectedLen = (version == 2) ? 3 : 4
        guard id.count == expectedLen else { return false }
        return id.unicodeScalars.allSatisfy { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 48 && $0.value <= 57) }
    }

    private static func mapV22FrameID(_ id: String) -> String? {
        v22ToV23FrameMap[id]
    }

    private static func parseTDRCComponents(_ raw: String) -> (year: String, ddmm: String?, hhmm: String?)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Supported lossless subsets: YYYY, YYYY-MM-DD, YYYY-MM-DD[T ]HH:MM(:SS)?
        let bytes = Array(s.utf8)
        guard bytes.count >= 4 else { return nil }
        let yearStr = String(s.prefix(4))
        guard yearStr.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if s.count == 4 {
            return (yearStr, nil, nil)
        }
        let rest = String(s.dropFirst(4))
        // Must match -MM-DD or -MM-DDTHH:MM(:SS)? or -MM-DD HH:MM(:SS)?
        guard rest.hasPrefix("-") else { return nil }
        let parts = rest.dropFirst().split(whereSeparator: { $0 == "T" || $0 == "t" || $0 == " " })
        guard let datePart = parts.first else { return nil }
        let ymd = datePart.split(separator: "-")
        guard ymd.count == 2,
              ymd[0].count == 2, ymd[1].count == 2,
              let month = Int(ymd[0]), (1...12).contains(month),
              let day = Int(ymd[1]), (1...31).contains(day) else {
            return nil
        }
        let ddmm = String(format: "%02d%02d", day, month)
        if parts.count == 1 {
            return (yearStr, ddmm, nil)
        }
        if parts.count == 2 {
            let timeStr = String(parts[1])
            let hms = timeStr.split(separator: ":")
            guard (2...3).contains(hms.count),
                  hms[0].count == 2, hms[1].count == 2,
                  let hr = Int(hms[0]), (0...23).contains(hr),
                  let min = Int(hms[1]), (0...59).contains(min) else {
                return nil
            }
            return (yearStr, ddmm, String(format: "%02d%02d", hr, min))
        }
        return nil
    }

    private static func removeUnsynchronisation(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF && i + 1 < bytes.count && bytes[i + 1] == 0x00 {
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    private static func normalizeYearString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.prefix(4)
        if digits.count == 4, Int(digits) != nil {
            return String(digits)
        }
        return trimmed
    }

    private static func decodeString(_ slice: Data, encodingByte: UInt8) -> String {
        var raw = slice
        // Strip trailing single or double null terminators cleanly
        if encodingByte == 0x01 || encodingByte == 0x02 {
            while raw.count >= 2 && raw[raw.endIndex - 1] == 0 && raw[raw.endIndex - 2] == 0 {
                raw = raw.dropLast(2)
            }
            if encodingByte == 0x01 {
                return String(data: raw, encoding: .utf16)
                    ?? String(data: raw, encoding: .utf16LittleEndian)
                    ?? ""
            } else {
                return String(data: raw, encoding: .utf16BigEndian) ?? ""
            }
        } else {
            while raw.last == 0 { raw = raw.dropLast() }
            if encodingByte == 0x03 {
                return String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1) ?? ""
            }
            return String(data: raw, encoding: .isoLatin1) ?? String(data: raw, encoding: .utf8) ?? ""
        }
    }

    private static func decodeID3TextPayload(_ payload: Data) -> (String, UInt8) {
        guard !payload.isEmpty else { return ("", 0x00) }
        let enc = payload[payload.startIndex]
        return (decodeString(Data(payload.dropFirst()), encodingByte: enc), enc)
    }

    private static func splitNullTerminatedPrefix(_ data: Data, encodingByte: UInt8) -> (prefix: String, remainder: Data) {
        let bytes = [UInt8](data)
        if encodingByte == 0x01 || encodingByte == 0x02 {
            var i = 0
            while i + 1 < bytes.count {
                if bytes[i] == 0 && bytes[i + 1] == 0 {
                    let prefix = decodeString(Data(bytes[0..<i]), encodingByte: encodingByte)
                    return (prefix, Data(bytes[(i + 2)...]))
                }
                i += 2
            }
            return (decodeString(data, encodingByte: encodingByte), Data())
        } else {
            if let nullIdx = bytes.firstIndex(of: 0) {
                let prefix = decodeString(Data(bytes[0..<nullIdx]), encodingByte: encodingByte)
                return (prefix, Data(bytes[(nullIdx + 1)...]))
            }
            return (decodeString(data, encodingByte: encodingByte), Data())
        }
    }

    private static func decodeTXXXPayload(_ payload: Data) -> (desc: String, value: String, enc: UInt8) {
        guard !payload.isEmpty else { return ("", "", 0x00) }
        let enc = payload[payload.startIndex]
        let (desc, rem) = splitNullTerminatedPrefix(Data(payload.dropFirst()), encodingByte: enc)
        return (desc, decodeString(rem, encodingByte: enc), enc)
    }

    private static func decodeUSLTOrCOMMPayload(_ payload: Data) -> (lang: String, desc: String, text: String, enc: UInt8) {
        guard payload.count >= 4 else { return ("eng", "", "", 0x00) }
        let enc = payload[payload.startIndex]
        let lang = String(data: Data(payload.dropFirst().prefix(3)), encoding: .ascii) ?? "eng"
        let (desc, rem) = splitNullTerminatedPrefix(Data(payload.dropFirst(4)), encodingByte: enc)
        return (lang, desc, decodeString(rem, encodingByte: enc), enc)
    }

    private static func parseAPICFrame(payload: Data, rawVersion: UInt8, index: Int) -> ParsedAPIC {
        guard !payload.isEmpty else {
            return ParsedAPIC(
                declaredMime: "", detectedMime: nil, pictureType: 0x03, description: "", imageData: Data(),
                rawWasUTF16OrCleanDescription: false,
                validation: SpotifyArtworkValidator.inspectArtwork(data: Data(), index: index, declaredMime: "", pictureType: 0x03, description: "")
            )
        }
        let enc = payload[payload.startIndex]
        var cursor = payload.dropFirst()
        let declaredMime: String
        if rawVersion == 2 {
            let fmt = String(data: Data(cursor.prefix(3)), encoding: .ascii)?.uppercased() ?? ""
            declaredMime = (fmt == "PNG") ? "image/png" : "image/jpeg"
            cursor = cursor.dropFirst(3)
        } else {
            let (mime, rem) = splitNullTerminatedPrefix(Data(cursor), encodingByte: 0x00)
            declaredMime = mime
            cursor = rem[...]
        }
        let picType: UInt8 = cursor.first ?? 0x03
        if !cursor.isEmpty { cursor = cursor.dropFirst() }
        let (desc, imgBytes) = splitNullTerminatedPrefix(Data(cursor), encodingByte: enc)
        let entry = SpotifyArtworkValidator.inspectArtwork(
            data: imgBytes, index: index, declaredMime: declaredMime, pictureType: picType, description: desc
        )
        return ParsedAPIC(
            declaredMime: declaredMime,
            detectedMime: entry.detectedMime,
            pictureType: picType,
            description: desc,
            imageData: imgBytes,
            rawWasUTF16OrCleanDescription: (rawVersion != 2 && (enc == 0x01 || (enc == 0x00 && desc.isEmpty))),
            validation: entry
        )
    }

    private static func encodeUTF16LEWithBOM(_ str: String) -> Data {
        var out = Data([0xFF, 0xFE])
        out.append(str.data(using: .utf16LittleEndian) ?? Data())
        return out
    }

    private static func encodeUTF16TextPayload(_ str: String) -> Data {
        var out = Data([0x01])
        out.append(encodeUTF16LEWithBOM(str))
        return out
    }

    private static func encodeUTF16TXXXPayload(desc: String, value: String) -> Data {
        var out = Data([0x01])
        out.append(encodeUTF16LEWithBOM(desc))
        out.append(contentsOf: [0x00, 0x00])
        out.append(encodeUTF16LEWithBOM(value))
        return out
    }

    private static func encodeUTF16LangDescPayload(lang: String, desc: String, text: String) -> Data {
        var out = Data([0x01])
        let paddedLang = (lang.count == 3 ? lang : "eng").data(using: .ascii) ?? Data("eng".utf8)
        out.append(paddedLang.prefix(3))
        out.append(encodeUTF16LEWithBOM(desc))
        out.append(contentsOf: [0x00, 0x00])
        out.append(encodeUTF16LEWithBOM(text))
        return out
    }

    private static func encodeAPICPayload(mime: String, pictureType: UInt8, description: String, imageData: Data) -> Data {
        var out = Data([0x01])
        out.append(mime.data(using: .isoLatin1) ?? Data("image/jpeg".utf8))
        out.append(0x00)
        out.append(pictureType)
        out.append(encodeUTF16LEWithBOM(description))
        out.append(contentsOf: [0x00, 0x00])
        out.append(imageData)
        return out
    }
}

// MARK: - Streaming ISOBMFF MP4 / M4A / M4P Atom Processor

enum SpotifyMP4AtomProcessor {

    enum MP4Error: LocalizedError {
        case malformedContainer(String)
        case fragmentedContainer(String)
        case unsupportedStructure(String)
        case corruptArtwork(String)

        var errorDescription: String? {
            switch self {
            case .malformedContainer(let msg): return msg
            case .fragmentedContainer(let msg): return msg
            case .unsupportedStructure(let msg): return msg
            case .corruptArtwork(let msg): return msg
            }
        }
    }

    private static let maxMoovAllocationBytes: UInt64 = 128 * 1024 * 1024
    private static let fragmentedBoxTypes: Set<String> = ["moof", "traf", "trun", "tfhd", "trex", "mvex", "mfra"]
    private static let knownQuickTimeMetaChildTypes: Set<String> = ["hdlr", "ilst", "keys", "free", "skip"]

    private struct TopBox {
        let type: String
        let offset: UInt64
        let size: UInt64
        let headerSize: UInt64
        var endOffset: UInt64 { offset + size }
    }

    struct ParsedCover: Sendable {
        let dataBoxTypeCode: UInt32
        let imageData: Data
        let validation: SpotifyArtworkEntry
    }

    struct RawAtom: Sendable {
        let fourCC: [UInt8]
        let name: String
        let fullBoxBytes: Data
    }

    struct ParsedMP4Metadata: Sendable {
        let majorBrand: String?
        let drmStatus: SpotifyDRMStatus
        let isFragmented: Bool
        let hasIlst: Bool
        let title: String?
        let artist: String?
        let album: String?
        let albumArtist: String?
        let day: String?
        let trackTuple: (track: Int, total: Int)?
        let discTuple: (disc: Int, total: Int)?
        let genre: String?
        let hasGNREAtom: Bool
        let lyrics: String?
        let covers: [ParsedCover]
        let presentStandardAtoms: [String]
        let preservedOtherAtoms: [RawAtom]
        let limitationNotes: [String]
        let isNormalizedProfile: Bool
        let normalizationNeededReasons: [String]
    }

    private static let id3v1Genres: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop",
        "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game",
        "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial",
        "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave",
        "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz",
        "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"
    ]

    private static func readTopBoxes(url: URL) throws -> (boxes: [TopBox], fileSize: UInt64) {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        var offset: UInt64 = 0
        var boxes: [TopBox] = []

        while offset < fileSize {
            let remaining = fileSize - offset
            guard remaining >= 8 else {
                throw MP4Error.malformedContainer("Truncated MP4 top-level box header (\(remaining) trailing byte(s) at offset \(offset)).")
            }
            try fh.seek(toOffset: offset)
            guard let hdr = try fh.read(upToCount: 8), hdr.count == 8 else {
                throw MP4Error.malformedContainer("Failed to read MP4 top-level box header at offset \(offset).")
            }
            let sz32 = UInt64(readUInt32BE(hdr, 0))
            let typeStr = fourCCString([UInt8](hdr[4..<8]))
            let actualSize: UInt64
            let headerSize: UInt64

            if sz32 == 1 {
                guard remaining >= 16,
                      let ext = try fh.read(upToCount: 8),
                      ext.count == 8 else {
                    throw MP4Error.malformedContainer("Truncated 64-bit largesize box '\(typeStr)' at offset \(offset).")
                }
                actualSize = readUInt64BE(ext, 0)
                headerSize = 16
                guard actualSize >= 16 else {
                    throw MP4Error.malformedContainer("Invalid 64-bit box size (\(actualSize)) on '\(typeStr)' at offset \(offset).")
                }
            } else if sz32 == 0 {
                // ISO 14496-12 §4.2: size 0 extends to end of file (must be terminal box)
                actualSize = remaining
                headerSize = 8
            } else {
                guard sz32 >= 8 else {
                    throw MP4Error.malformedContainer("Invalid box size (\(sz32) < 8) on '\(typeStr)' at offset \(offset).")
                }
                actualSize = sz32
                headerSize = 8
            }

            let (endOffset, overflow) = offset.addingReportingOverflow(actualSize)
            guard !overflow, endOffset <= fileSize else {
                throw MP4Error.malformedContainer("MP4 box '\(typeStr)' at offset \(offset) extends past EOF (size \(actualSize), fileSize \(fileSize)).")
            }
            boxes.append(TopBox(type: typeStr, offset: offset, size: actualSize, headerSize: headerSize))
            offset = endOffset
        }

        let moovCount = boxes.filter { $0.type == "moov" }.count
        if moovCount > 1 {
            throw MP4Error.malformedContainer("Multiple 'moov' boxes (\(moovCount)) detected in MP4 container.")
        }

        return (boxes, fileSize)
    }

    static func inspect(url: URL) throws -> ParsedMP4Metadata {
        let (boxes, _) = try readTopBoxes(url: url)
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var majorBrand: String? = nil
        var compatibleBrands: Set<String> = []
        if let ftyp = boxes.first(where: { $0.type == "ftyp" }), ftyp.size >= ftyp.headerSize + 8 {
            try fh.seek(toOffset: ftyp.offset + ftyp.headerSize)
            let readLen = Int(min(ftyp.size - ftyp.headerSize, 256))
            if let brandData = try fh.read(upToCount: readLen), brandData.count >= 4 {
                majorBrand = String(data: brandData[0..<4], encoding: .isoLatin1)
                if brandData.count >= 8 {
                    var idx = 8
                    while idx + 4 <= brandData.count {
                        if let b = String(data: brandData[idx..<(idx + 4)], encoding: .isoLatin1) {
                            compatibleBrands.insert(b)
                        }
                        idx += 4
                    }
                }
            }
        }

        var foundFragmented = boxes.map(\.type).filter { fragmentedBoxTypes.contains($0) }
        let isM4P = url.pathExtension.lowercased() == "m4p" || majorBrand?.uppercased() == "M4P "
        guard let moovBox = boxes.first(where: { $0.type == "moov" }) else {
            return ParsedMP4Metadata(
                majorBrand: majorBrand,
                drmStatus: isM4P ? .unknown(reason: "M4P missing moov box; cannot confirm DRM absence.") : .noneDetected,
                isFragmented: !foundFragmented.isEmpty,
                hasIlst: false, title: nil, artist: nil, album: nil, albumArtist: nil, day: nil,
                trackTuple: nil, discTuple: nil, genre: nil, hasGNREAtom: false, lyrics: nil,
                covers: [], presentStandardAtoms: [], preservedOtherAtoms: [],
                limitationNotes: foundFragmented.isEmpty ? [] : ["Fragmented MP4/ISOBMFF boxes (\(foundFragmented.joined(separator: ", "))) detected; sample-table offset rewriting unsupported."],
                isNormalizedProfile: false,
                normalizationNeededReasons: ["Missing moov container."]
            )
        }

        guard moovBox.size <= maxMoovAllocationBytes else {
            throw MP4Error.malformedContainer("'moov' container size (\(moovBox.size) bytes) exceeds safety limit (\(maxMoovAllocationBytes) bytes).")
        }

        try fh.seek(toOffset: moovBox.offset)
        let moovBytes = try fh.read(upToCount: Int(moovBox.size)) ?? Data()
        guard moovBytes.count == Int(moovBox.size) else {
            throw MP4Error.malformedContainer("Unable to read full moov atom.")
        }

        // Strict structural scan of moov tree for fragmented boxes (mvex/trex/etc.) & malformed child boxes
        foundFragmented.append(contentsOf: try scanFragmentedBoxes(in: moovBytes, startOffset: Int(moovBox.headerSize)))
        let uniqueFragmented = Array(Set(foundFragmented)).sorted()
        let isFragmented = !uniqueFragmented.isEmpty

        var limitationNotes: [String] = []
        if isFragmented {
            limitationNotes.append("Fragmented MP4/ISOBMFF container detected (boxes: \(uniqueFragmented.joined(separator: ", "))); chunk offset normalization is unsupported without full remuxing.")
        } else if let majorBrand, ["dash", "msdh", "msix", "cmfc", "cmfs"].contains(majorBrand.lowercased()) ||
                    !compatibleBrands.isDisjoint(with: ["dash", "msdh", "msix"]) {
            if !boxes.contains(where: { $0.type == "mdat" }) {
                limitationNotes.append("Segmented/DASH MP4 brand '\(majorBrand)' without local mdat media payload is unsupported.")
            }
        }

        let drm = try detectDRM(inMoov: moovBytes, headerSize: Int(moovBox.headerSize), isM4P: isM4P)

        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var day: String?
        var trackTuple: (Int, Int)?
        var discTuple: (Int, Int)?
        var genre: String?
        var hasGNRE = false
        var lyrics: String?
        var covers: [ParsedCover] = []
        var presentStandard: [String] = []
        var preservedOther: [RawAtom] = []
        var hasIlst = false
        var reasons: [String] = []
        var seenStandardCounts: [String: Int] = [:]

        if let (_, ilstRange) = try findUdtaMetaIlstRanges(inMoov: moovBytes, headerSize: Int(moovBox.headerSize)) {
            hasIlst = true
            let ilstChildren = try parseChildBoxesStrict(moovBytes, range: ilstRange.lowerBound..<ilstRange.upperBound)
            var covrIdx = 0
            for child in ilstChildren {
                let rawAtomBytes = Data(moovBytes[child.range])
                seenStandardCounts[child.type, default: 0] += 1
                switch child.type {
                case "©nam":
                    presentStandard.append("©nam")
                    if title == nil { title = try extractStringFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) }
                case "©ART":
                    presentStandard.append("©ART")
                    if artist == nil { artist = try extractStringFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) }
                case "©alb":
                    presentStandard.append("©alb")
                    if album == nil { album = try extractStringFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) }
                case "aART":
                    presentStandard.append("aART")
                    if albumArtist == nil { albumArtist = try extractStringFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) }
                case "©day":
                    presentStandard.append("©day")
                    if day == nil { day = try extractStringFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) }
                case "trkn":
                    presentStandard.append("trkn")
                    if trackTuple == nil { trackTuple = try extractPairTupleFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) }
                case "disk":
                    presentStandard.append("disk")
                    if discTuple == nil { discTuple = try extractPairTupleFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) }
                case "gnre":
                    presentStandard.append("gnre")
                    hasGNRE = true
                    if let g = try extractGNREFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) {
                        genre = genre ?? g
                    }
                case "©gen":
                    presentStandard.append("©gen")
                    if genre == nil {
                        genre = try extractStringFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize)
                    }
                case "©lyr":
                    presentStandard.append("©lyr")
                    if lyrics == nil { lyrics = try extractStringFromDataSubbox(rawAtomBytes, childHeaderSize: child.headerSize) }
                case "covr":
                    presentStandard.append("covr")
                    for sub in try extractAllDataSubboxes(rawAtomBytes, parentHeaderSize: child.headerSize) {
                        let declaredMime: String? = (sub.typeCode == 13) ? "image/jpeg" : ((sub.typeCode == 14) ? "image/png" : nil)
                        let entry = SpotifyArtworkValidator.inspectArtwork(
                            data: sub.payload, index: covrIdx, declaredMime: declaredMime, pictureType: 0x03, description: "Cover (front)"
                        )
                        covrIdx += 1
                        covers.append(ParsedCover(dataBoxTypeCode: sub.typeCode, imageData: sub.payload, validation: entry))
                        if !entry.isValid {
                            reasons.append("Corrupt covr artwork entry detected.")
                        } else if (sub.typeCode == 13 && entry.detectedMime != "image/jpeg") ||
                                  (sub.typeCode == 14 && entry.detectedMime != "image/png") ||
                                  (sub.typeCode != 13 && sub.typeCode != 14) {
                            reasons.append("covr type flag does not match actual image bytes.")
                        }
                    }
                default:
                    preservedOther.append(RawAtom(fourCC: Array(moovBytes[(child.range.lowerBound + 4)..<(child.range.lowerBound + 8)]), name: child.type, fullBoxBytes: rawAtomBytes))
                }
            }

            let targetedAtoms = ["©nam", "©ART", "©alb", "aART", "©day", "trkn", "disk", "gnre", "©gen", "©lyr", "covr"]
            for atomName in targetedAtoms where (seenStandardCounts[atomName] ?? 0) > 1 {
                reasons.append("Duplicate MP4 metadata atom '\(atomName)' detected; consolidate to canonical single atom.")
            }
        } else {
            reasons.append("Missing moov.udta.meta.ilst atom container.")
        }

        if let g = genre, !g.isEmpty, genreIndexForString(g) != nil && !hasGNRE {
            reasons.append("Standard genre '\(g)' stored only in ©gen without native gnre atom.")
        }
        if !limitationNotes.isEmpty {
            reasons.append(contentsOf: limitationNotes)
        }

        let isAlreadyNormalized = hasIlst && reasons.isEmpty && limitationNotes.isEmpty
        return ParsedMP4Metadata(
            majorBrand: majorBrand,
            drmStatus: drm,
            isFragmented: isFragmented,
            hasIlst: hasIlst,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            day: day,
            trackTuple: trackTuple,
            discTuple: discTuple,
            genre: genre,
            hasGNREAtom: hasGNRE,
            lyrics: lyrics,
            covers: covers,
            presentStandardAtoms: Array(Set(presentStandard)).sorted(),
            preservedOtherAtoms: preservedOther,
            limitationNotes: limitationNotes,
            isNormalizedProfile: isAlreadyNormalized,
            normalizationNeededReasons: reasons
        )
    }

    static func writeNormalizedMP4Atoms(
        from inputURL: URL,
        to outputTempURL: URL,
        parsed: ParsedMP4Metadata,
        resizeOversizedArtwork: Bool,
        maxArtworkDimension: Int,
        singleFrontCoverOnly: Bool,
        truncateAfterBytes: Int? = nil
    ) throws -> (actions: [String], warnings: [String]) {
        if parsed.drmStatus.blocksModification {
            throw MP4Error.malformedContainer(parsed.drmStatus.explanation ?? "Refusing to modify DRM-protected or unknown-DRM file.")
        }
        if parsed.isFragmented {
            throw MP4Error.fragmentedContainer(parsed.limitationNotes.first ?? "Refusing in-place metadata rewrite on fragmented MP4/ISOBMFF container.")
        }
        if !parsed.limitationNotes.isEmpty {
            throw MP4Error.unsupportedStructure(parsed.limitationNotes.joined(separator: " "))
        }
        if let corrupt = parsed.covers.first(where: { !$0.validation.isValid }) {
            throw MP4Error.corruptArtwork(corrupt.validation.corruptionReason ?? "Corrupt MP4 covr artwork.")
        }

        let (topBoxes, _) = try readTopBoxes(url: inputURL)
        guard let moovBox = topBoxes.first(where: { $0.type == "moov" }) else {
            throw MP4Error.malformedContainer("Missing moov atom in MP4 container.")
        }
        guard moovBox.size <= maxMoovAllocationBytes else {
            throw MP4Error.malformedContainer("'moov' atom exceeds maximum allocation bound.")
        }
        let mdatBoxes = topBoxes.filter { $0.type == "mdat" }
        guard mdatBoxes.contains(where: { $0.size > $0.headerSize }) else {
            throw MP4Error.malformedContainer("MP4 container has no non-empty 'mdat' media payload box.")
        }

        let inHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inHandle.close() }
        try inHandle.seek(toOffset: moovBox.offset)
        let oldMoovBytes = try inHandle.read(upToCount: Int(moovBox.size)) ?? Data()
        guard oldMoovBytes.count == Int(moovBox.size) else {
            throw MP4Error.malformedContainer("Failed to read moov atom.")
        }

        var actions: [String] = []
        var warnings: [String] = []

        var newIlstPayload = Data()
        func appendUTF8Atom(_ fourCC: [UInt8], _ value: String?) {
            guard let v = value, !v.isEmpty, let payload = v.data(using: .utf8) else { return }
            newIlstPayload.append(buildDataWrappedAtom(fourCC: fourCC, typeCode: 1, payload: payload))
        }

        appendUTF8Atom([0xA9, 0x6E, 0x61, 0x6D], parsed.title)   // ©nam
        appendUTF8Atom([0xA9, 0x41, 0x52, 0x54], parsed.artist)  // ©ART
        appendUTF8Atom([0xA9, 0x61, 0x6C, 0x62], parsed.album)   // ©alb
        appendUTF8Atom(Array("aART".utf8), parsed.albumArtist)
        appendUTF8Atom([0xA9, 0x64, 0x61, 0x79], parsed.day)     // ©day

        if let trkn = parsed.trackTuple {
            var p = Data([0, 0])
            p.append(writeUInt16BE(UInt16(max(0, trkn.track))))
            p.append(writeUInt16BE(UInt16(max(0, trkn.total))))
            p.append(contentsOf: [0, 0])
            newIlstPayload.append(buildDataWrappedAtom(fourCC: Array("trkn".utf8), typeCode: 0, payload: p))
        }
        if let disk = parsed.discTuple {
            var p = Data([0, 0])
            p.append(writeUInt16BE(UInt16(max(0, disk.disc))))
            p.append(writeUInt16BE(UInt16(max(0, disk.total))))
            newIlstPayload.append(buildDataWrappedAtom(fourCC: Array("disk".utf8), typeCode: 0, payload: p))
        }
        if let genre = parsed.genre, !genre.isEmpty {
            if let gnreIdx = genreIndexForString(genre) {
                newIlstPayload.append(buildDataWrappedAtom(fourCC: Array("gnre".utf8), typeCode: 0, payload: writeUInt16BE(UInt16(gnreIdx))))
                if !parsed.hasGNREAtom { actions.append("Wrote native MP4 gnre atom for '\(genre)'.") }
            }
            appendUTF8Atom([0xA9, 0x67, 0x65, 0x6E], genre) // ©gen preserved for full custom text fidelity
        }
        appendUTF8Atom([0xA9, 0x6C, 0x79, 0x72], parsed.lyrics)  // ©lyr

        let validCovers = parsed.covers.filter { $0.validation.isValid }
        if !validCovers.isEmpty {
            var covrChildren = Data()
            for (idx, cov) in validCovers.enumerated() {
                if singleFrontCoverOnly && idx > 0 {
                    warnings.append("Secondary covr image #\(idx + 1) omitted because Single Front Cover mode was enabled.")
                    continue
                }
                var imgData = cov.imageData
                var mime = cov.validation.detectedMime ?? "image/jpeg"
                if resizeOversizedArtwork {
                    let res = try SpotifyArtworkValidator.resizeIfRequested(data: imgData, mime: mime, maxDimension: maxArtworkDimension)
                    if res.data.count != imgData.count {
                        actions.append("Resized covr artwork #\(idx + 1) within \(maxArtworkDimension) px.")
                    }
                    imgData = res.data
                    mime = res.mime
                }
                let typeCode: UInt32 = (mime == "image/png") ? 14 : 13
                covrChildren.append(buildDataBox(typeCode: typeCode, payload: imgData))
            }
            if !covrChildren.isEmpty {
                newIlstPayload.append(buildBox(fourCC: Array("covr".utf8), payload: covrChildren))
            }
        }

        for extra in parsed.preservedOtherAtoms {
            newIlstPayload.append(extra.fullBoxBytes)
        }

        let newIlstBox = buildBox(fourCC: Array("ilst".utf8), payload: newIlstPayload)
        var newMoovBytes = try rebuildMoovWithIlst(
            oldMoovBytes,
            headerSize: Int(moovBox.headerSize),
            newIlstBox: newIlstBox
        )

        let offsetRes = try updateAndPromoteChunkOffsetsInMoov(
            newMoovBytes,
            oldMoovOffset: moovBox.offset,
            oldMoovSize: moovBox.size
        )
        newMoovBytes = offsetRes.moovData
        if offsetRes.promotedStcoCount > 0 {
            actions.append("Promoted \(offsetRes.promotedStcoCount) 32-bit stco table(s) to 64-bit co64 after chunk offset shift.")
        }

        FileManager.default.createFile(atPath: outputTempURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outputTempURL)
        defer { try? outHandle.close() }

        var writtenTotal = 0
        for box in topBoxes {
            if box.type == "moov" {
                if let truncateAfterBytes, writtenTotal + newMoovBytes.count >= truncateAfterBytes {
                    let keep = max(0, truncateAfterBytes - writtenTotal)
                    try outHandle.write(contentsOf: newMoovBytes.prefix(keep))
                    throw MP4Error.malformedContainer("Injected failure during MP4 metadata write.")
                }
                try outHandle.write(contentsOf: newMoovBytes)
                writtenTotal += newMoovBytes.count
            } else {
                try SpotifyAudioHashUtility.copySlice(
                    from: inHandle,
                    to: outHandle,
                    startOffset: box.offset,
                    endOffset: box.endOffset
                )
                writtenTotal += Int(min(box.size, UInt64(Int.max / 2)))
                if let truncateAfterBytes, writtenTotal >= truncateAfterBytes {
                    throw MP4Error.malformedContainer("Injected failure during MP4 box copy.")
                }
            }
        }

        if actions.isEmpty {
            actions.append("Normalized native MP4 ilst metadata atoms.")
        }
        return (actions, warnings)
    }

    // MARK: - ISOBMFF Low-Level Box Helpers

    private static func fourCCString(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .isoLatin1) ?? "????"
    }

    private static func readUInt32BE(_ d: Data, _ offset: Int) -> UInt32 {
        (UInt32(d[offset]) << 24) | (UInt32(d[offset + 1]) << 16) | (UInt32(d[offset + 2]) << 8) | UInt32(d[offset + 3])
    }

    private static func readUInt64BE(_ d: Data, _ offset: Int) -> UInt64 {
        (UInt64(readUInt32BE(d, offset)) << 32) | UInt64(readUInt32BE(d, offset + 4))
    }

    private static func writeUInt16BE(_ v: UInt16) -> Data {
        Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func writeUInt32BE(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func writeUInt64BE(_ v: UInt64) -> Data {
        Data([
            UInt8((v >> 56) & 0xFF), UInt8((v >> 48) & 0xFF), UInt8((v >> 40) & 0xFF), UInt8((v >> 32) & 0xFF),
            UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)
        ])
    }

    private static func buildBox(fourCC: [UInt8], payload: Data) -> Data {
        let totalLen = UInt64(8 + payload.count)
        if totalLen <= UInt64(UInt32.max) {
            var out = writeUInt32BE(UInt32(totalLen))
            out.append(contentsOf: fourCC.prefix(4))
            out.append(payload)
            return out
        } else {
            var out = writeUInt32BE(1)
            out.append(contentsOf: fourCC.prefix(4))
            out.append(writeUInt64BE(totalLen + 8))
            out.append(payload)
            return out
        }
    }

    private static func buildDataBox(typeCode: UInt32, payload: Data) -> Data {
        var inner = Data()
        inner.append(writeUInt32BE(typeCode))
        inner.append(contentsOf: [0, 0, 0, 0]) // locale
        inner.append(payload)
        return buildBox(fourCC: Array("data".utf8), payload: inner)
    }

    private static func buildDataWrappedAtom(fourCC: [UInt8], typeCode: UInt32, payload: Data) -> Data {
        buildBox(fourCC: fourCC, payload: buildDataBox(typeCode: typeCode, payload: payload))
    }

    private struct ChildBox {
        let type: String
        let range: Range<Int>
        let headerSize: Int
    }

    private static func parseChildBoxesStrict(_ data: Data, range: Range<Int>, allowZeroSizedTerminal: Bool = false) throws -> [ChildBox] {
        var result: [ChildBox] = []
        var pos = range.lowerBound
        while pos < range.upperBound {
            let remaining = range.upperBound - pos
            guard remaining >= 8 else {
                throw MP4Error.malformedContainer("Truncated child box header (\(remaining) trailing byte(s) at offset \(pos)).")
            }
            let sz32 = UInt64(readUInt32BE(data, pos))
            let typ = fourCCString([UInt8](data[(pos + 4)..<(pos + 8)]))
            let actualSize: UInt64
            let hdrSize: Int

            if sz32 == 1 {
                guard remaining >= 16 else {
                    throw MP4Error.malformedContainer("Truncated 64-bit child box '\(typ)' header.")
                }
                actualSize = readUInt64BE(data, pos + 8)
                hdrSize = 16
                guard actualSize >= 16 else {
                    throw MP4Error.malformedContainer("Invalid 64-bit child box size (\(actualSize)) on '\(typ)'.")
                }
            } else if sz32 == 0 {
                guard allowZeroSizedTerminal else {
                    throw MP4Error.malformedContainer("Unexpected size-0 child box '\(typ)' inside structured container.")
                }
                actualSize = UInt64(remaining)
                hdrSize = 8
            } else {
                guard sz32 >= 8 else {
                    throw MP4Error.malformedContainer("Invalid child box size (\(sz32) < 8) on '\(typ)'.")
                }
                actualSize = sz32
                hdrSize = 8
            }

            guard actualSize <= UInt64(Int.max) else {
                throw MP4Error.malformedContainer("Child box '\(typ)' exceeds Int range (\(actualSize)).")
            }
            let szInt = Int(actualSize)
            let (endPos, overflow) = pos.addingReportingOverflow(szInt)
            guard !overflow, endPos <= range.upperBound else {
                throw MP4Error.malformedContainer("Child box '\(typ)' size (\(actualSize)) exceeds parent container boundary.")
            }
            result.append(ChildBox(type: typ, range: pos..<endPos, headerSize: hdrSize))
            pos = endPos
        }
        return result
    }

    private static func scanFragmentedBoxes(in moovBytes: Data, startOffset: Int) throws -> [String] {
        var found: [String] = []
        func recurse(_ range: Range<Int>, boxType: String?) throws {
            let childStart: Int
            if boxType == "stsd" {
                guard range.lowerBound + 8 <= range.upperBound else {
                    throw MP4Error.malformedContainer("Truncated 'stsd' FullBox header.")
                }
                childStart = range.lowerBound + 8
            } else if boxType == "meta" {
                let (_, children) = try parseMetaChildren(in: moovBytes, contentRange: range)
                for c in children {
                    if fragmentedBoxTypes.contains(c.type) { found.append(c.type) }
                }
                return
            } else {
                childStart = range.lowerBound
            }
            for child in try parseChildBoxesStrict(moovBytes, range: childStart..<range.upperBound) {
                if fragmentedBoxTypes.contains(child.type) {
                    found.append(child.type)
                }
                let payloadRange = (child.range.lowerBound + child.headerSize)..<child.range.upperBound
                if ["trak", "mdia", "minf", "stbl", "udta", "meta", "mvex"].contains(child.type), !payloadRange.isEmpty {
                    try recurse(payloadRange, boxType: child.type)
                }
            }
        }
        if moovBytes.count >= startOffset {
            try recurse(startOffset..<moovBytes.count, boxType: "moov")
        }
        return found
    }

    private static func parseMetaChildren(in data: Data, contentRange: Range<Int>) throws -> (isFullBox: Bool, children: [ChildBox]) {
        guard !contentRange.isEmpty else { return (true, []) }
        // Heuristic: QuickTime non-FullBox meta begins immediately with a known child box ('hdlr', 'keys', 'ilst', 'free', 'skip')
        if contentRange.count >= 8 {
            let firstType = fourCCString([UInt8](data[(contentRange.lowerBound + 4)..<(contentRange.lowerBound + 8)]))
            if knownQuickTimeMetaChildTypes.contains(firstType),
               let qtChildren = try? parseChildBoxesStrict(data, range: contentRange),
               !qtChildren.isEmpty {
                return (false, qtChildren)
            }
        }
        guard contentRange.count >= 4 else {
            throw MP4Error.malformedContainer("Truncated 'meta' FullBox header.")
        }
        let version = data[contentRange.lowerBound]
        guard version == 0 else {
            throw MP4Error.unsupportedStructure("Unsupported 'meta' FullBox version \(version) (only version 0 is supported).")
        }
        let children = try parseChildBoxesStrict(data, range: (contentRange.lowerBound + 4)..<contentRange.upperBound)
        return (true, children)
    }

    private static func detectDRM(inMoov moovBytes: Data, headerSize: Int, isM4P: Bool) throws -> SpotifyDRMStatus {
        let drmMarkers = ["drms", "enca", "encv", "sinf", "schm", "fair"]
        func scan(range: Range<Int>) throws -> String? {
            for box in try parseChildBoxesStrict(moovBytes, range: range) {
                if drmMarkers.contains(box.type) {
                    return box.type
                }
                let childPayloadStart = box.range.lowerBound + box.headerSize
                if box.type == "meta" {
                    let (_, metaChildren) = try parseMetaChildren(in: moovBytes, contentRange: childPayloadStart..<box.range.upperBound)
                    for mc in metaChildren where drmMarkers.contains(mc.type) {
                        return mc.type
                    }
                    continue
                }
                let recurseStart: Int
                if box.type == "stsd" && childPayloadStart + 8 <= box.range.upperBound {
                    recurseStart = childPayloadStart + 8
                } else if box.type == "drms" || box.type == "mp4a" || box.type == "enca" {
                    recurseStart = min(box.range.upperBound, childPayloadStart + 28)
                } else {
                    recurseStart = childPayloadStart
                }
                if ["trak", "mdia", "minf", "stbl", "stsd", "mp4a", "sinf", "schi", "udta"].contains(box.type),
                   recurseStart < box.range.upperBound {
                    if let hit = try scan(range: recurseStart..<box.range.upperBound) {
                        return hit
                    }
                }
            }
            return nil
        }

        if moovBytes.count >= headerSize, let hit = try scan(range: headerSize..<moovBytes.count) {
            return .protected(
                scheme: hit == "drms" || hit == "fair" ? "FairPlay DRM" : "Encrypted MP4 (\(hit))",
                details: "Container includes encrypted/DRM box '\(hit)'. LocalConvert never decrypts, strips, or modifies DRM-protected files."
            )
        }
        if isM4P {
            return .unknown(reason: "M4P is a DRM-associated container extension; DRM absence cannot be conclusively verified from container inspection.")
        }
        return .noneDetected
    }

    private static func findUdtaMetaIlstRanges(inMoov moovBytes: Data, headerSize: Int) throws -> (metaPayloadStart: Int, ilstPayload: Range<Int>)? {
        guard moovBytes.count >= headerSize else { return nil }
        let moovChildren = try parseChildBoxesStrict(moovBytes, range: headerSize..<moovBytes.count)
        guard let udta = moovChildren.first(where: { $0.type == "udta" }) else { return nil }
        let udtaChildren = try parseChildBoxesStrict(moovBytes, range: (udta.range.lowerBound + udta.headerSize)..<udta.range.upperBound)
        guard let meta = udtaChildren.first(where: { $0.type == "meta" }) else { return nil }
        let metaContent = (meta.range.lowerBound + meta.headerSize)..<meta.range.upperBound
        let (isFullBox, metaChildren) = try parseMetaChildren(in: moovBytes, contentRange: metaContent)
        guard let ilst = metaChildren.first(where: { $0.type == "ilst" }) else { return nil }
        let payloadStart = metaContent.lowerBound + (isFullBox ? 4 : 0)
        return (payloadStart, (ilst.range.lowerBound + ilst.headerSize)..<ilst.range.upperBound)
    }

    private static func extractStringFromDataSubbox(_ atomBytes: Data, childHeaderSize: Int) throws -> String? {
        for sub in try extractAllDataSubboxes(atomBytes, parentHeaderSize: childHeaderSize) {
            if let s = String(data: sub.payload, encoding: .utf8), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    private static func extractPairTupleFromDataSubbox(_ atomBytes: Data, childHeaderSize: Int) throws -> (Int, Int)? {
        guard let first = try extractAllDataSubboxes(atomBytes, parentHeaderSize: childHeaderSize).first,
              first.payload.count >= 6 else { return nil }
        let p = first.payload
        let base = p.startIndex
        let num = Int((UInt16(p[base + 2]) << 8) | UInt16(p[base + 3]))
        let total = Int((UInt16(p[base + 4]) << 8) | UInt16(p[base + 5]))
        return num > 0 ? (num, total) : nil
    }

    private static func extractGNREFromDataSubbox(_ atomBytes: Data, childHeaderSize: Int) throws -> String? {
        guard let first = try extractAllDataSubboxes(atomBytes, parentHeaderSize: childHeaderSize).first,
              first.payload.count >= 2 else { return nil }
        let idx = Int((UInt16(first.payload[first.payload.startIndex]) << 8) | UInt16(first.payload[first.payload.startIndex + 1]))
        let zeroIdx = idx - 1
        return (zeroIdx >= 0 && zeroIdx < id3v1Genres.count) ? id3v1Genres[zeroIdx] : "Genre \(idx)"
    }

    private static func genreIndexForString(_ genre: String) -> Int? {
        let lower = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let zeroIdx = id3v1Genres.firstIndex(where: { $0.lowercased() == lower }) {
            return zeroIdx + 1
        }
        return nil
    }

    private static func extractAllDataSubboxes(_ atomBytes: Data, parentHeaderSize: Int) throws -> [(typeCode: UInt32, payload: Data)] {
        guard atomBytes.count >= parentHeaderSize else { return [] }
        var out: [(typeCode: UInt32, payload: Data)] = []
        for sub in try parseChildBoxesStrict(atomBytes, range: parentHeaderSize..<atomBytes.count) where sub.type == "data" {
            let pStart = sub.range.lowerBound + sub.headerSize
            guard pStart + 8 <= sub.range.upperBound else { continue }
            let typeCode = readUInt32BE(atomBytes, pStart)
            let payload = Data(atomBytes[(pStart + 8)..<sub.range.upperBound])
            out.append((typeCode, payload))
        }
        return out
    }

    private static func rebuildMoovWithIlst(_ moovBytes: Data, headerSize: Int, newIlstBox: Data) throws -> Data {
        let moovChildren = try parseChildBoxesStrict(moovBytes, range: headerSize..<moovBytes.count)
        var newMoovPayload = Data()
        var handledUdta = false

        for child in moovChildren {
            if child.type != "udta" {
                newMoovPayload.append(moovBytes[child.range])
            } else {
                handledUdta = true
                let udtaChildren = try parseChildBoxesStrict(moovBytes, range: (child.range.lowerBound + child.headerSize)..<child.range.upperBound)
                var newUdtaPayload = Data()
                var handledMeta = false
                for uChild in udtaChildren {
                    if uChild.type != "meta" {
                        newUdtaPayload.append(moovBytes[uChild.range])
                    } else {
                        handledMeta = true
                        let metaContent = (uChild.range.lowerBound + uChild.headerSize)..<uChild.range.upperBound
                        let (_, metaChildren) = try parseMetaChildren(in: moovBytes, contentRange: metaContent)
                        var newMetaPayload = Data([0, 0, 0, 0]) // Normalize to canonical ISO FullBox meta (v0)
                        var handledIlst = false
                        var hasHdlr = false
                        for mChild in metaChildren {
                            if mChild.type == "hdlr" { hasHdlr = true }
                            if mChild.type == "ilst" {
                                handledIlst = true
                                newMetaPayload.append(newIlstBox)
                            } else {
                                newMetaPayload.append(moovBytes[mChild.range])
                            }
                        }
                        if !hasHdlr {
                            newMetaPayload = buildDefaultMetaPrefix() + newMetaPayload.dropFirst(4)
                        }
                        if !handledIlst {
                            newMetaPayload.append(newIlstBox)
                        }
                        newUdtaPayload.append(buildBox(fourCC: Array("meta".utf8), payload: newMetaPayload))
                    }
                }
                if !handledMeta {
                    var newMetaPayload = buildDefaultMetaPrefix()
                    newMetaPayload.append(newIlstBox)
                    newUdtaPayload.append(buildBox(fourCC: Array("meta".utf8), payload: newMetaPayload))
                }
                newMoovPayload.append(buildBox(fourCC: Array("udta".utf8), payload: newUdtaPayload))
            }
        }

        if !handledUdta {
            var newMetaPayload = buildDefaultMetaPrefix()
            newMetaPayload.append(newIlstBox)
            let metaBox = buildBox(fourCC: Array("meta".utf8), payload: newMetaPayload)
            newMoovPayload.append(buildBox(fourCC: Array("udta".utf8), payload: metaBox))
        }

        return buildBox(fourCC: Array("moov".utf8), payload: newMoovPayload)
    }

    private static func buildDefaultMetaPrefix() -> Data {
        var metaPayload = Data([0, 0, 0, 0]) // version + flags
        var hdlrPayload = Data([0, 0, 0, 0]) // fullbox version + flags
        hdlrPayload.append(contentsOf: [0, 0, 0, 0]) // predefined
        hdlrPayload.append(contentsOf: Array("mdir".utf8))
        hdlrPayload.append(contentsOf: Array("appl".utf8))
        hdlrPayload.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0])
        metaPayload.append(buildBox(fourCC: Array("hdlr".utf8), payload: hdlrPayload))
        return metaPayload
    }

    /// Recomputes `stco` / `co64` chunk offsets across arbitrary container layouts (faststart, tail-moov, multiple mdat),
    /// promoting any 32-bit `stco` that overflows `UInt32.max` to 64-bit `co64` using a fixed-point size-convergence solver.
    static func updateAndPromoteChunkOffsetsInMoov(
        _ moovBytes: Data,
        oldMoovOffset: UInt64,
        oldMoovSize: UInt64
    ) throws -> (moovData: Data, promotedStcoCount: Int) {
        let moovHeaderSize = (moovBytes.count >= 16 && readUInt32BE(moovBytes, 0) == 1) ? 16 : 8
        guard moovBytes.count >= moovHeaderSize else {
            throw MP4Error.malformedContainer("Truncated rebuilt moov atom.")
        }

        let oldMoovEnd = oldMoovOffset + oldMoovSize

        // Step 1: Collect every stco / co64 table structurally along `trak -> mdia -> minf -> stbl`
        struct ChunkTableInfo {
            let ordinal: Int
            let isStco: Bool
            let entries: [UInt64]
        }
        var tables: [ChunkTableInfo] = []

        func collectTables(in range: Range<Int>) throws {
            for child in try parseChildBoxesStrict(moovBytes, range: range) {
                if child.type == "stco" || child.type == "co64" {
                    let countOff = child.range.lowerBound + child.headerSize + 4
                    guard countOff + 4 <= child.range.upperBound else {
                        throw MP4Error.malformedContainer("Truncated '\(child.type)' chunk offset box.")
                    }
                    let count = Int(readUInt32BE(moovBytes, countOff))
                    let entryStride = (child.type == "stco") ? 4 : 8
                    let requiredBytes = count * entryStride
                    guard countOff + 4 + requiredBytes <= child.range.upperBound else {
                        throw MP4Error.malformedContainer("Truncated '\(child.type)' chunk table entries (declared count \(count)).")
                    }
                    var vals: [UInt64] = []
                    vals.reserveCapacity(count)
                    for i in 0..<count {
                        let off = countOff + 4 + i * entryStride
                        let v: UInt64 = (child.type == "stco")
                            ? UInt64(readUInt32BE(moovBytes, off))
                            : readUInt64BE(moovBytes, off)
                        if v >= oldMoovOffset && v < oldMoovEnd {
                            throw MP4Error.malformedContainer("Invalid '\(child.type)' chunk offset \(v) points inside original moov container.")
                        }
                        vals.append(v)
                    }
                    tables.append(ChunkTableInfo(ordinal: tables.count, isStco: child.type == "stco", entries: vals))
                } else if ["trak", "mdia", "minf", "stbl"].contains(child.type) {
                    try collectTables(in: (child.range.lowerBound + child.headerSize)..<child.range.upperBound)
                }
            }
        }
        try collectTables(in: moovHeaderSize..<moovBytes.count)

        func applyOffsetDelta(_ v: UInt64, delta: Int64) throws -> UInt64 {
            if delta >= 0 {
                let (res, ov) = v.addingReportingOverflow(UInt64(delta))
                guard !ov else {
                    throw MP4Error.malformedContainer("Chunk offset overflow after delta adjustment.")
                }
                return res
            } else {
                let mag = delta.magnitude
                guard v >= mag else {
                    throw MP4Error.malformedContainer("Chunk offset became negative after delta adjustment.")
                }
                return v - mag
            }
        }

        // Step 2: Fixed-point loop to find which `stco` boxes overflow 32-bit offsets when promoted
        var promotedOrdinals: Set<Int> = []
        var finalDelta: Int64 = Int64(moovBytes.count) - Int64(oldMoovSize)

        for _ in 0..<(tables.count + 2) {
            var promotionExtraBytes: Int64 = 0
            for t in tables where t.isStco && promotedOrdinals.contains(t.ordinal) {
                promotionExtraBytes += Int64(t.entries.count * 4)
            }
            let candidateMoovSize = Int64(moovBytes.count) + promotionExtraBytes
            finalDelta = candidateMoovSize - Int64(oldMoovSize)

            var nextPromoted = promotedOrdinals
            for t in tables {
                for v in t.entries where v >= oldMoovEnd {
                    let shifted = try applyOffsetDelta(v, delta: finalDelta)
                    if t.isStco && shifted > UInt64(UInt32.max) {
                        nextPromoted.insert(t.ordinal)
                    }
                }
            }
            if nextPromoted == promotedOrdinals {
                break
            }
            promotedOrdinals = nextPromoted
        }

        // Fast path if delta == 0 and no promotions occurred
        if finalDelta == 0 && promotedOrdinals.isEmpty {
            return (moovBytes, 0)
        }

        // Step 3: Bottom-up structural rebuild updating stco/co64 entries and parent container sizes
        var nextOrdinal = 0
        func rebuildContainer(_ range: Range<Int>) throws -> Data {
            var payload = Data()
            for child in try parseChildBoxesStrict(moovBytes, range: range) {
                if child.type == "stco" {
                    let tbl = tables[nextOrdinal]
                    nextOrdinal += 1
                    let promote = promotedOrdinals.contains(tbl.ordinal)
                    let vfOff = child.range.lowerBound + child.headerSize
                    let versionFlags = Data(moovBytes[vfOff..<(vfOff + 4)])
                    var tablePayload = versionFlags
                    tablePayload.append(writeUInt32BE(UInt32(tbl.entries.count)))
                    for v in tbl.entries {
                        let newV: UInt64 = (v >= oldMoovEnd) ? try applyOffsetDelta(v, delta: finalDelta) : v
                        if promote {
                            tablePayload.append(writeUInt64BE(newV))
                        } else {
                            tablePayload.append(writeUInt32BE(UInt32(newV)))
                        }
                    }
                    payload.append(buildBox(fourCC: Array((promote ? "co64" : "stco").utf8), payload: tablePayload))
                } else if child.type == "co64" {
                    let tbl = tables[nextOrdinal]
                    nextOrdinal += 1
                    let vfOff = child.range.lowerBound + child.headerSize
                    let versionFlags = Data(moovBytes[vfOff..<(vfOff + 4)])
                    var tablePayload = versionFlags
                    tablePayload.append(writeUInt32BE(UInt32(tbl.entries.count)))
                    for v in tbl.entries {
                        let newV: UInt64 = (v >= oldMoovEnd) ? try applyOffsetDelta(v, delta: finalDelta) : v
                        tablePayload.append(writeUInt64BE(newV))
                    }
                    payload.append(buildBox(fourCC: Array("co64".utf8), payload: tablePayload))
                } else if ["trak", "mdia", "minf", "stbl"].contains(child.type) {
                    let childPayload = try rebuildContainer((child.range.lowerBound + child.headerSize)..<child.range.upperBound)
                    payload.append(buildBox(fourCC: Array(moovBytes[(child.range.lowerBound + 4)..<(child.range.lowerBound + 8)]), payload: childPayload))
                } else {
                    payload.append(moovBytes[child.range])
                }
            }
            return payload
        }

        let rebuiltPayload = try rebuildContainer(moovHeaderSize..<moovBytes.count)
        let rebuiltMoov = buildBox(fourCC: Array("moov".utf8), payload: rebuiltPayload)
        return (rebuiltMoov, promotedOrdinals.count)
    }
}

// MARK: - Streaming Crypto & File IO Utility

enum SpotifyAudioHashUtility {

    static func sha256FileSlice(url: URL, startOffset: UInt64, endOffset: UInt64) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: startOffset)

        var hasher = SHA256()
        var remaining = endOffset - startOffset
        let chunkSize = 256 * 1024

        while remaining > 0 {
            let toRead = Int(min(remaining, UInt64(chunkSize)))
            guard let data = try fh.read(upToCount: toRead), !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= UInt64(data.count)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func copySlice(from inHandle: FileHandle, to outHandle: FileHandle, startOffset: UInt64, endOffset: UInt64) throws {
        try inHandle.seek(toOffset: startOffset)
        var remaining = endOffset - startOffset
        let chunkSize = 256 * 1024
        while remaining > 0 {
            let toRead = Int(min(remaining, UInt64(chunkSize)))
            guard let chunk = try inHandle.read(upToCount: toRead), !chunk.isEmpty else { break }
            try outHandle.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    static func computeFFmpegStreamHash(url: URL, ffmpegPath: String, audioStreamIndex: Int = 0) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-v", "error",
            "-i", url.path,
            "-map", "0:a:\(audioStreamIndex)",
            "-c:a", "copy",
            "-f", "streamhash",
            "-hash", "sha256",
            "-"
        ]
        let out = try await AsyncProcessRunner.run(process)
        guard out.terminationStatus == 0 else {
            let err = String(data: out.stderr, encoding: .utf8) ?? "streamhash failed"
            throw ConversionError.engineExecutionFailed("Failed to compute compressed audio stream hash.", underlyingError: err)
        }
        let stdout = String(data: out.stdout, encoding: .utf8) ?? ""
        for line in stdout.components(separatedBy: .newlines) {
            if let range = line.range(of: "SHA256=") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        throw ConversionError.engineExecutionFailed("Missing SHA256 streamhash output.", underlyingError: stdout)
    }

    static func verifyAllAudioStreams(
        url: URL,
        ffmpegPath: String,
        ffprobePath: String
    ) async throws -> [SpotifyAudioStreamVerification] {
        let probeProc = Process()
        probeProc.executableURL = URL(fileURLWithPath: ffprobePath)
        probeProc.arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_data_hash", "sha256",
            "-show_entries", "stream=index,codec_name,profile,sample_rate,channels,channel_layout,time_base,duration,extradata_hash:packet=stream_index,pts,dts,duration,size,flags,data_hash",
            "-of", "json",
            url.path
        ]
        let probeOut = try await AsyncProcessRunner.run(probeProc)
        guard probeOut.terminationStatus == 0 else {
            let err = String(data: probeOut.stderr, encoding: .utf8) ?? "ffprobe packet inspection failed"
            throw ConversionError.engineExecutionFailed("Failed to inspect audio stream packets with ffprobe.", underlyingError: err)
        }
        guard let jsonObj = try JSONSerialization.jsonObject(with: probeOut.stdout) as? [String: Any] else {
            throw ConversionError.engineExecutionFailed("Malformed JSON returned by ffprobe packet inspection.", underlyingError: nil)
        }

        let streamsRaw = (jsonObj["streams"] as? [[String: Any]]) ?? []
        let packetsRaw = (jsonObj["packets"] as? [[String: Any]]) ?? []

        var packetsByStreamIndex: [Int: [[String: Any]]] = [:]
        for pkt in packetsRaw {
            let sIdx: Int
            if let n = pkt["stream_index"] as? Int {
                sIdx = n
            } else if let s = pkt["stream_index"] as? String, let n = Int(s) {
                sIdx = n
            } else {
                continue
            }
            packetsByStreamIndex[sIdx, default: []].append(pkt)
        }

        func stringify(_ v: Any?) -> String {
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return "N/A"
        }

        func int64Value(_ v: Any?) -> Int64 {
            if let n = v as? Int64 { return n }
            if let n = v as? Int { return Int64(n) }
            if let s = v as? String, let n = Int64(s) { return n }
            return 0
        }

        func cleanHash(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("SHA256:") {
                return String(trimmed.dropFirst(7)).lowercased()
            }
            return trimmed.lowercased()
        }

        func hexDigest(_ hasher: SHA256) -> String {
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        var verifiedStreams: [SpotifyAudioStreamVerification] = []
        verifiedStreams.reserveCapacity(streamsRaw.count)

        for (ordinal, streamDict) in streamsRaw.enumerated() {
            let containerIdx = (streamDict["index"] as? Int) ?? ordinal
            let codecName = (streamDict["codec_name"] as? String) ?? "unknown"
            let codecProfile = streamDict["profile"] as? String
            let sampleRate = (streamDict["sample_rate"] as? String).flatMap(Int.init) ?? (streamDict["sample_rate"] as? Int)
            let channels = streamDict["channels"] as? Int
            let channelLayout = streamDict["channel_layout"] as? String
            let timeBase = streamDict["time_base"] as? String
            let duration = streamDict["duration"] as? String
            let extradataHash = cleanHash(streamDict["extradata_hash"] as? String)

            let streamPackets = packetsByStreamIndex[containerIdx] ?? []
            var totalBytes: Int64 = 0
            var manifestHasher = SHA256()
            var rollingHasher = SHA256()

            for pkt in streamPackets {
                let pts = stringify(pkt["pts"])
                let dts = stringify(pkt["dts"])
                let dur = stringify(pkt["duration"])
                let size = int64Value(pkt["size"])
                let flags = (pkt["flags"] as? String) ?? ""
                let dataHash = cleanHash(pkt["data_hash"] as? String) ?? ""
                totalBytes += size
                manifestHasher.update(data: Data("\(pts)|\(dts)|\(dur)|\(size)|\(flags)|\(dataHash)\n".utf8))
                rollingHasher.update(data: Data("\(dataHash)\n".utf8))
            }

            let streamHash = try await computeFFmpegStreamHash(
                url: url,
                ffmpegPath: ffmpegPath,
                audioStreamIndex: ordinal
            )

            verifiedStreams.append(
                SpotifyAudioStreamVerification(
                    streamIndex: ordinal,
                    containerStreamIndex: containerIdx,
                    codecName: codecName,
                    codecProfile: codecProfile,
                    sampleRate: sampleRate,
                    channels: channels,
                    channelLayout: channelLayout,
                    timeBase: timeBase,
                    duration: duration,
                    extradataHashSHA256: extradataHash,
                    packetCount: streamPackets.count,
                    totalPacketBytes: totalBytes,
                    packetManifestSHA256: hexDigest(manifestHasher),
                    packetPayloadRollingSHA256: hexDigest(rollingHasher),
                    streamHashSHA256: streamHash
                )
            )
        }

        return verifiedStreams
    }

    static func streamsMatchExactly(
        _ before: [SpotifyAudioStreamVerification],
        _ after: [SpotifyAudioStreamVerification]
    ) -> Bool {
        guard !before.isEmpty, before.count == after.count else { return false }
        for (a, b) in zip(before, after) {
            if a.streamIndex != b.streamIndex ||
                a.codecName != b.codecName ||
                a.codecProfile != b.codecProfile ||
                a.sampleRate != b.sampleRate ||
                a.channels != b.channels ||
                a.channelLayout != b.channelLayout ||
                a.timeBase != b.timeBase ||
                a.extradataHashSHA256 != b.extradataHashSHA256 ||
                a.packetCount != b.packetCount ||
                a.totalPacketBytes != b.totalPacketBytes ||
                a.packetManifestSHA256 != b.packetManifestSHA256 ||
                a.packetPayloadRollingSHA256 != b.packetPayloadRollingSHA256 ||
                a.streamHashSHA256 != b.streamHashSHA256 {
                return false
            }
        }
        return true
    }
}

// MARK: - Main Coordinator Service

actor SpotifyCompatibilityService {

    static let shared = SpotifyCompatibilityService()
    private let logger = Logger(subsystem: "com.localconvert.app", category: "SpotifyCompatibility")
    private let provider = BundledFFmpegProvider(fallbackToSystem: false)

    func analyzeFile(url: URL) async -> SpotifyAnalysisReportItem {
        let ext = url.pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return makeErrorItem(url: url, ext: ext, state: .processingError, reason: "Input file does not exist: \(url.lastPathComponent)")
        }
        do {
            try Task.checkCancellation()
            let mediaInfo = try await provider.probe(url: url)
            let audioStream = mediaInfo.primaryAudioStream
            let realVideoStream = mediaInfo.videoStreams.first(where: { !$0.isAttachedPic })
            let hasRealVideo = realVideoStream != nil

            let audioCodec = audioStream?.codecName
            let container = mediaInfo.formatName

            var ftypBrand: String? = nil
            var drmStatus: SpotifyDRMStatus = .notApplicable
            var metadataSummary = SpotifyMetadataSummary.empty
            var artworkAnalysis = SpotifyArtworkAnalysis.empty

            let isISOBMFF = container.lowercased().contains("mp4")
                || container.lowercased().contains("m4a")
                || container.lowercased().contains("mov")
                || ["mp4", "m4a", "m4b", "m4p"].contains(ext)

            if ext == "mp3" || (audioCodec?.lowercased() == "mp3" && container.lowercased().contains("mp3")) {
                do {
                    let id3 = try SpotifyID3Processor.inspect(url: url)
                    let entries = id3.apicFrames.map(\.validation)
                    artworkAnalysis = SpotifyArtworkAnalysis(
                        count: entries.count,
                        frontCoverCount: entries.filter { $0.isValid && $0.pictureType == 0x03 }.count,
                        validCount: entries.filter(\.isValid).count,
                        corruptCount: entries.filter { !$0.isValid }.count,
                        entries: entries
                    )
                    let tagFmt = id3.majorVersion.map { "ID3v2.\($0).\(id3.minorVersion ?? 0)" } ?? (id3.hasID3v1Footer ? "ID3v1" : "None")
                    let encSummary = id3.encodingIssues.isEmpty
                        ? (id3.majorVersion == 3 ? "UTF-16 (ID3v2.3 compatible)" : "Legacy / Mixed")
                        : id3.encodingIssues.joined(separator: "; ")

                    metadataSummary = SpotifyMetadataSummary(
                        tagFormat: tagFmt,
                        id3Version: tagFmt,
                        textEncodingSummary: encSummary,
                        presentMP4Atoms: [],
                        title: id3.title,
                        artist: id3.artist,
                        album: id3.album,
                        albumArtist: id3.albumArtist,
                        year: id3.year,
                        trackNumber: id3.track,
                        discNumber: id3.disc,
                        genre: id3.genre,
                        hasLyrics: !(id3.lyrics ?? "").isEmpty,
                        additionalFramesOrAtoms: id3.txxxFrames.map { "TXXX:\($0.desc)" }
                            + id3.otherTextFrames.map(\.id)
                            + id3.preservedRawFrames.map(\.frameID),
                        unsupportedOrLimitationNotes: id3.limitationNotes,
                        isNormalizedProfile: id3.isNormalizedProfile,
                        normalizationNeededReasons: id3.normalizationNeededReasons
                    )
                    drmStatus = .noneDetected
                } catch {
                    metadataSummary = SpotifyMetadataSummary(
                        tagFormat: "Corrupt ID3 Tag",
                        id3Version: nil,
                        textEncodingSummary: nil,
                        presentMP4Atoms: [],
                        title: nil, artist: nil, album: nil, albumArtist: nil, year: nil, trackNumber: nil, discNumber: nil, genre: nil,
                        hasLyrics: false,
                        additionalFramesOrAtoms: [],
                        unsupportedOrLimitationNotes: [error.localizedDescription],
                        isNormalizedProfile: false,
                        normalizationNeededReasons: [error.localizedDescription]
                    )
                    drmStatus = .noneDetected
                }
            } else if isISOBMFF {
                do {
                    let mp4 = try SpotifyMP4AtomProcessor.inspect(url: url)
                    ftypBrand = mp4.majorBrand
                    drmStatus = mp4.drmStatus
                    let entries = mp4.covers.map(\.validation)
                    artworkAnalysis = SpotifyArtworkAnalysis(
                        count: entries.count,
                        frontCoverCount: entries.filter(\.isValid).count,
                        validCount: entries.filter(\.isValid).count,
                        corruptCount: entries.filter { !$0.isValid }.count,
                        entries: entries
                    )
                    let notes = (mp4.drmStatus.explanation.map { [$0] } ?? []) + mp4.limitationNotes
                    metadataSummary = SpotifyMetadataSummary(
                        tagFormat: mp4.isFragmented ? "Fragmented MP4 (Unsupported)" : (mp4.hasIlst ? "MP4 ilst Atoms" : "Missing ilst"),
                        id3Version: nil,
                        textEncodingSummary: "UTF-8 / Binary Atoms",
                        presentMP4Atoms: mp4.presentStandardAtoms,
                        title: mp4.title,
                        artist: mp4.artist,
                        album: mp4.album,
                        albumArtist: mp4.albumArtist,
                        year: mp4.day,
                        trackNumber: mp4.trackTuple.map { "\($0.track)/\($0.total)" },
                        discNumber: mp4.discTuple.map { "\($0.disc)/\($0.total)" },
                        genre: mp4.genre,
                        hasLyrics: !(mp4.lyrics ?? "").isEmpty,
                        additionalFramesOrAtoms: mp4.preservedOtherAtoms.map(\.name),
                        unsupportedOrLimitationNotes: notes,
                        isNormalizedProfile: mp4.isNormalizedProfile,
                        normalizationNeededReasons: mp4.normalizationNeededReasons
                    )
                } catch {
                    drmStatus = ext == "m4p"
                        ? .unknown(reason: "M4P inspection failed: \(error.localizedDescription)")
                        : .noneDetected
                    metadataSummary = SpotifyMetadataSummary(
                        tagFormat: "Malformed MP4",
                        id3Version: nil, textEncodingSummary: nil, presentMP4Atoms: [],
                        title: nil, artist: nil, album: nil, albumArtist: nil, year: nil, trackNumber: nil, discNumber: nil, genre: nil,
                        hasLyrics: false, additionalFramesOrAtoms: [],
                        unsupportedOrLimitationNotes: [error.localizedDescription],
                        isNormalizedProfile: false,
                        normalizationNeededReasons: [error.localizedDescription]
                    )
                }
            }

            let classification = SpotifyCompatibilityRegistry.classify(
                fileURL: url,
                containerFormat: container,
                audioCodec: audioCodec,
                hasAudioStream: mediaInfo.hasAudio,
                hasRealVideo: hasRealVideo,
                videoCodec: realVideoStream?.codecName,
                ftypMajorBrand: ftypBrand,
                drmStatus: drmStatus
            )

            return SpotifyAnalysisReportItem(
                id: UUID(),
                inputURL: url,
                detectedExtension: ext,
                containerFormat: container,
                audioCodec: audioCodec,
                hasAudioStream: mediaInfo.hasAudio,
                hasVideoStream: hasRealVideo,
                videoCodec: realVideoStream?.codecName,
                duration: mediaInfo.duration,
                bitRate: mediaInfo.bitRate ?? audioStream?.bitRate,
                sampleRate: audioStream?.sampleRate,
                channels: audioStream?.channels,
                drmStatus: drmStatus,
                classification: classification.classification,
                compatibilityReason: classification.reason,
                metadataSummary: metadataSummary,
                artworkAnalysis: artworkAnalysis,
                normalizationState: nil,
                normalizationActions: [],
                warnings: metadataSummary.unsupportedOrLimitationNotes,
                outputURL: nil,
                preAudioHashSHA256: nil,
                postAudioHashSHA256: nil,
                audioPayloadVerified: nil
            )
        } catch is CancellationError {
            return makeErrorItem(url: url, ext: ext, state: .processingError, reason: "Analysis cancelled.")
        } catch {
            return makeErrorItem(url: url, ext: ext, state: .failedValidation, reason: error.localizedDescription)
        }
    }

    func analyzeBatch(
        urls: [URL],
        maxConcurrent: Int = 4,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async -> [SpotifyAnalysisReportItem] {
        guard !urls.isEmpty else { return [] }
        let limit = max(1, min(6, maxConcurrent))
        var results = Array<SpotifyAnalysisReportItem?>(repeating: nil, count: urls.count)
        let total = urls.count
        var nextIndex = 0
        var completed = 0

        await withTaskGroup(of: (Int, SpotifyAnalysisReportItem).self) { group in
            for _ in 0..<min(limit, total) {
                let idx = nextIndex
                nextIndex += 1
                let u = urls[idx]
                group.addTask {
                    let item = await self.analyzeFile(url: u)
                    return (idx, item)
                }
            }

            while let (idx, item) = await group.next() {
                results[idx] = item
                completed += 1
                progress(Double(completed) / Double(total), "Analyzed \(completed) of \(total) tracks...")
                if nextIndex < total && !Task.isCancelled {
                    let nIdx = nextIndex
                    nextIndex += 1
                    let nURL = urls[nIdx]
                    group.addTask {
                        let nextItem = await self.analyzeFile(url: nURL)
                        return (nIdx, nextItem)
                    }
                }
            }
        }

        return results.compactMap { $0 }
    }

    func normalizeFile(
        item: SpotifyAnalysisReportItem,
        options: SpotifyNormalizationOptions
    ) async -> SpotifyAnalysisReportItem {
        var updated = item

        // Enforce strict safety & DRM boundaries before touching anything
        if case .protected(_, let details) = item.drmStatus {
            updated.normalizationState = .drmProtected
            updated.warnings.append(details)
            return updated
        }
        if case .unknown(let reason) = item.drmStatus {
            updated.normalizationState = .drmProtected
            updated.warnings.append(reason)
            return updated
        }

        switch item.classification {
        case .unsupportedFormat, .incompatibleVideoContainer:
            updated.normalizationState = .unsupportedFormat
            return updated
        case .drmProtected, .unknownDRM:
            updated.normalizationState = .drmProtected
            return updated
        case .officiallyDocumented, .conditional:
            break
        }

        // Reject corrupt headers, fragmented containers, or corrupt artwork before normalization
        if item.metadataSummary.tagFormat.contains("Corrupt")
            || item.metadataSummary.tagFormat.contains("Malformed")
            || item.metadataSummary.tagFormat.contains("Fragmented") {
            updated.normalizationState = .failedValidation
            updated.warnings.append(contentsOf: item.metadataSummary.unsupportedOrLimitationNotes)
            return updated
        }
        if item.artworkAnalysis.corruptCount > 0 {
            updated.normalizationState = .failedValidation
            updated.warnings.append("Corrupt embedded artwork detected; refusing to claim clean normalization.")
            return updated
        }
        if !item.metadataSummary.unsupportedOrLimitationNotes.isEmpty {
            updated.normalizationState = .failedValidation
            updated.warnings.append(contentsOf: item.metadataSummary.unsupportedOrLimitationNotes)
            return updated
        }

        // Enforce separate output directory & never overwrite original file even if .overwrite collision mode selected
        let targetDir: URL
        if options.outputDirectory.standardizedFileURL == item.inputURL.deletingLastPathComponent().standardizedFileURL {
            targetDir = item.outputURL == nil
                ? options.outputDirectory.appendingPathComponent("Spotify Normalized", isDirectory: true)
                : options.outputDirectory
        } else {
            targetDir = options.outputDirectory
        }

        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            let baseName = FileFormat.baseNameByStrippingExtension(from: item.inputURL)
            let ext = item.inputURL.pathExtension.isEmpty ? "mp3" : item.inputURL.pathExtension
            let finalURL = try ConversionManager.reserveUniqueOutputURL(
                directory: targetDir,
                baseName: baseName,
                extension: ext,
                sourceURL: item.inputURL,
                policy: options.existingFileHandling
            )
            defer { ConversionManager.releaseReservedOutputURL(finalURL) }

            // Safety double-check: output must NEVER equal input
            guard finalURL.standardizedFileURL != item.inputURL.standardizedFileURL else {
                updated.normalizationState = .processingError
                updated.warnings.append("Refused in-place overwrite of source file.")
                return updated
            }

            if case .beforeTempOutputCreation = options.failureInjection {
                throw ConversionError.engineExecutionFailed("Injected failure before temp output creation.", underlyingError: nil)
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalConvert-Spotify-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            guard let ffmpegPath = await provider.findFFmpegPath(),
                  let ffprobePath = await provider.findFFprobePath() else {
                updated.normalizationState = .processingError
                updated.warnings.append("Bundled FFmpeg/FFprobe is unavailable for multi-stream bitstream verification.")
                return updated
            }

            let streamsBefore = try await SpotifyAudioHashUtility.verifyAllAudioStreams(
                url: item.inputURL,
                ffmpegPath: ffmpegPath,
                ffprobePath: ffprobePath
            )
            guard !streamsBefore.isEmpty else {
                updated.normalizationState = .failedValidation
                updated.warnings.append("No verifiable audio streams returned by FFprobe/FFmpeg.")
                return updated
            }
            updated.audioStreamsBefore = streamsBefore
            updated.preAudioHashSHA256 = streamsBefore.first?.streamHashSHA256

            let writeTruncateBytes: Int? = if case .duringMetadataWrite(let n) = options.failureInjection { n } else { nil }
            let injectPacketFail = (options.failureInjection == .duringPacketVerification)
            let injectAtomicFail = (options.failureInjection == .duringAtomicReplacement)

            if item.detectedExtension == "mp3" || item.audioCodec?.lowercased() == "mp3" {
                let parsed = try SpotifyID3Processor.inspect(url: item.inputURL)
                let rawPreMPEG = try SpotifyID3Processor.computeRawMPEGAudioSHA256(url: item.inputURL, parsed: parsed)
                updated.mp3RawSliceSHA256Before = rawPreMPEG
                updated.mp3PacketCountBefore = streamsBefore.first?.packetCount

                let singleCoverRewriteNeeded = options.singleFrontCoverOnly && parsed.apicFrames.filter(\.validation.isValid).count > 1
                let hasOversizedResize = options.resizeOversizedArtwork && parsed.apicFrames.contains {
                    max($0.validation.pixelWidth ?? 0, $0.validation.pixelHeight ?? 0) > options.maxArtworkDimension
                }

                if parsed.isNormalizedProfile && !hasOversizedResize && !singleCoverRewriteNeeded && writeTruncateBytes == nil {
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: item.inputURL, to: tempURL)

                    let streamsAfter = try await SpotifyAudioHashUtility.verifyAllAudioStreams(
                        url: tempURL,
                        ffmpegPath: ffmpegPath,
                        ffprobePath: ffprobePath
                    )
                    let postParsed = try SpotifyID3Processor.inspect(url: tempURL)
                    let rawPostMPEG = try SpotifyID3Processor.computeRawMPEGAudioSHA256(url: tempURL, parsed: postParsed)
                    updated.audioStreamsAfter = streamsAfter
                    updated.postAudioHashSHA256 = streamsAfter.first?.streamHashSHA256
                    updated.mp3RawSliceSHA256After = rawPostMPEG
                    updated.mp3PacketCountAfter = streamsAfter.first?.packetCount

                    guard !injectPacketFail,
                          rawPostMPEG == rawPreMPEG,
                          SpotifyAudioHashUtility.streamsMatchExactly(streamsBefore, streamsAfter) else {
                        updated.normalizationState = .failedValidation
                        updated.audioPayloadVerified = false
                        updated.warnings.append("Post-copy MP3 multi-stream packet verification mismatch.")
                        return updated
                    }
                    try replaceAtomically(from: tempURL, to: finalURL, policy: options.existingFileHandling, injectFailure: injectAtomicFail)
                    updated.outputURL = finalURL
                    updated.audioPayloadVerified = true
                    updated.normalizationState = .alreadyCompatible
                    updated.normalizationActions = ["Verified ID3v2.3.0 & \(streamsAfter.count) audio stream(s) already compatible; copied cleanly without re-encoding."]
                    return updated
                }

                let result = try SpotifyID3Processor.writeNormalizedID3v23(
                    from: item.inputURL,
                    to: tempURL,
                    parsed: parsed,
                    resizeOversizedArtwork: options.resizeOversizedArtwork,
                    maxArtworkDimension: options.maxArtworkDimension,
                    singleFrontCoverOnly: options.singleFrontCoverOnly,
                    truncateAfterBytes: writeTruncateBytes
                )

                try Task.checkCancellation()

                // Mandatory post-write multi-stream & raw MPEG slice verification
                let postParsed = try SpotifyID3Processor.inspect(url: tempURL)
                let rawPostMPEG = try SpotifyID3Processor.computeRawMPEGAudioSHA256(url: tempURL, parsed: postParsed)
                let streamsAfter = try await SpotifyAudioHashUtility.verifyAllAudioStreams(
                    url: tempURL,
                    ffmpegPath: ffmpegPath,
                    ffprobePath: ffprobePath
                )
                updated.audioStreamsAfter = streamsAfter
                updated.postAudioHashSHA256 = streamsAfter.first?.streamHashSHA256
                updated.mp3RawSliceSHA256After = rawPostMPEG
                updated.mp3PacketCountAfter = streamsAfter.first?.packetCount

                guard !injectPacketFail,
                      rawPostMPEG == rawPreMPEG,
                      SpotifyAudioHashUtility.streamsMatchExactly(streamsBefore, streamsAfter),
                      postParsed.majorVersion == 3,
                      postParsed.apicFrames.allSatisfy(\.validation.isValid) else {
                    updated.normalizationState = .failedValidation
                    updated.audioPayloadVerified = false
                    updated.warnings.append("Post-write MP3 validation or bit-exact MPEG/packet payload proof failed; temp file discarded.")
                    return updated
                }

                try replaceAtomically(from: tempURL, to: finalURL, policy: options.existingFileHandling, injectFailure: injectAtomicFail)
                let reanalyzed = await analyzeFile(url: finalURL)
                updated.outputURL = finalURL
                updated.metadataSummary = reanalyzed.metadataSummary
                updated.artworkAnalysis = reanalyzed.artworkAnalysis
                updated.audioPayloadVerified = true
                updated.normalizationActions = result.actions
                updated.warnings.append(contentsOf: result.warnings)
                updated.normalizationState = .fixedSuccessfully
                return updated
            } else {
                // MP4 / M4A native ilst normalization
                let parsed = try SpotifyMP4AtomProcessor.inspect(url: item.inputURL)
                let singleCoverRewriteNeeded = options.singleFrontCoverOnly && parsed.covers.filter(\.validation.isValid).count > 1
                let hasOversizedResize = options.resizeOversizedArtwork && parsed.covers.contains {
                    max($0.validation.pixelWidth ?? 0, $0.validation.pixelHeight ?? 0) > options.maxArtworkDimension
                }

                if parsed.isNormalizedProfile && !hasOversizedResize && !singleCoverRewriteNeeded && writeTruncateBytes == nil {
                    try? FileManager.default.removeItem(at: tempURL)
                    try FileManager.default.copyItem(at: item.inputURL, to: tempURL)

                    let streamsAfter = try await SpotifyAudioHashUtility.verifyAllAudioStreams(
                        url: tempURL,
                        ffmpegPath: ffmpegPath,
                        ffprobePath: ffprobePath
                    )
                    updated.audioStreamsAfter = streamsAfter
                    updated.postAudioHashSHA256 = streamsAfter.first?.streamHashSHA256

                    guard !injectPacketFail,
                          SpotifyAudioHashUtility.streamsMatchExactly(streamsBefore, streamsAfter) else {
                        updated.normalizationState = .failedValidation
                        updated.audioPayloadVerified = false
                        updated.warnings.append("Post-copy MP4 multi-stream packet verification mismatch.")
                        return updated
                    }
                    try replaceAtomically(from: tempURL, to: finalURL, policy: options.existingFileHandling, injectFailure: injectAtomicFail)
                    updated.outputURL = finalURL
                    updated.audioPayloadVerified = true
                    updated.normalizationState = (item.classification == .conditional) ? .conditionalCompatibility : .alreadyCompatible
                    updated.normalizationActions = ["Verified native MP4 ilst atoms & \(streamsAfter.count) audio stream(s); copied cleanly without re-encoding."]
                    return updated
                }

                let result = try SpotifyMP4AtomProcessor.writeNormalizedMP4Atoms(
                    from: item.inputURL,
                    to: tempURL,
                    parsed: parsed,
                    resizeOversizedArtwork: options.resizeOversizedArtwork,
                    maxArtworkDimension: max(256, options.maxArtworkDimension),
                    singleFrontCoverOnly: options.singleFrontCoverOnly,
                    truncateAfterBytes: writeTruncateBytes
                )

                try Task.checkCancellation()

                let streamsAfter = try await SpotifyAudioHashUtility.verifyAllAudioStreams(
                    url: tempURL,
                    ffmpegPath: ffmpegPath,
                    ffprobePath: ffprobePath
                )
                let postParsed = try SpotifyMP4AtomProcessor.inspect(url: tempURL)
                updated.audioStreamsAfter = streamsAfter
                updated.postAudioHashSHA256 = streamsAfter.first?.streamHashSHA256

                guard !injectPacketFail,
                      SpotifyAudioHashUtility.streamsMatchExactly(streamsBefore, streamsAfter),
                      !postParsed.isFragmented,
                      postParsed.hasIlst,
                      postParsed.covers.allSatisfy(\.validation.isValid) else {
                    updated.normalizationState = .failedValidation
                    updated.audioPayloadVerified = false
                    updated.warnings.append("Post-write MP4 validation or multi-stream packet payload proof failed; temp file discarded.")
                    return updated
                }

                try replaceAtomically(from: tempURL, to: finalURL, policy: options.existingFileHandling, injectFailure: injectAtomicFail)
                let reanalyzed = await analyzeFile(url: finalURL)
                updated.outputURL = finalURL
                updated.metadataSummary = reanalyzed.metadataSummary
                updated.artworkAnalysis = reanalyzed.artworkAnalysis
                updated.audioPayloadVerified = true
                updated.normalizationActions = result.actions
                updated.warnings.append(contentsOf: result.warnings)
                updated.normalizationState = (item.classification == .conditional) ? .conditionalCompatibility : .fixedSuccessfully
                return updated
            }
        } catch is CancellationError {
            updated.normalizationState = .processingError
            updated.warnings.append("Normalization cancelled.")
            return updated
        } catch ConversionError.outputFileAlreadyExists(let existing) {
            updated.normalizationState = .processingError
            updated.warnings.append("Skipped existing output file at \(existing.lastPathComponent).")
            return updated
        } catch {
            updated.normalizationState = .failedValidation
            updated.audioPayloadVerified = false
            updated.warnings.append(error.localizedDescription)
            return updated
        }
    }

    private func replaceAtomically(
        from tempURL: URL,
        to finalURL: URL,
        policy: ExistingFileHandling,
        injectFailure: Bool = false
    ) throws {
        if injectFailure {
            throw ConversionError.engineExecutionFailed("Injected failure during atomic output replacement.", underlyingError: nil)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) {
            guard policy == .overwrite else {
                throw ConversionError.outputFileAlreadyExists(finalURL)
            }
            _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
            return
        }
        try fm.moveItem(at: tempURL, to: finalURL)
    }

    // MARK: - Analysis Report Export

    static func exportReportMarkdown(items: [SpotifyAnalysisReportItem], includeLyricsNotice: Bool = false) -> String {
        var lines: [String] = [
            "# LocalConvert — Spotify Compatibility Analysis Report",
            "",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Total Files: \(items.count)",
            ""
        ]

        for item in items {
            lines.append("## \(item.inputURL.lastPathComponent)")
            lines.append("- **Container / Codec:** \(item.containerFormat) / \(item.audioCodec ?? "none")")
            lines.append("- **Video Stream Present:** \(item.hasVideoStream ? "Yes (\(item.videoCodec ?? "video"))" : "No")")
            lines.append("- **DRM Status:** \(item.drmStatus.label)\(item.drmStatus.explanation.map { " — \($0)" } ?? "")")
            lines.append("- **Spotify Classification:** \(item.classification.rawValue)")
            lines.append("- **Classification Reason:** \(item.compatibilityReason)")
            lines.append("- **Metadata:** Format=\(item.metadataSummary.tagFormat), Title=\(item.metadataSummary.title ?? "—"), Artist=\(item.metadataSummary.artist ?? "—"), Album=\(item.metadataSummary.album ?? "—"), Track=\(item.metadataSummary.trackNumber ?? "—"), LyricsPresent=\(item.metadataSummary.hasLyrics ? "Yes" : "No")")
            lines.append("- **Artwork:** \(item.artworkAnalysis.summaryText)")
            if let norm = item.normalizationState {
                lines.append("- **Normalization Result:** \(norm.rawValue)")
            }
            if let outURL = item.outputURL {
                lines.append("- **Output Path:** \(outURL.path)")
            }
            if let verified = item.audioPayloadVerified {
                lines.append("- **Audio Payload Preservation:** \(verified ? "Verified Multi-Stream SHA-256 Match (\(max(1, item.audioStreamsAfter.count)) stream(s))" : "Mismatch / Unverified")")
            }
            if !item.normalizationActions.isEmpty {
                lines.append("- **Actions:** \(item.normalizationActions.joined(separator: "; "))")
            }
            if !item.warnings.isEmpty {
                lines.append("- **Warnings / Limitations:** \(item.warnings.joined(separator: "; "))")
            }
            if includeLyricsNotice && item.metadataSummary.hasLyrics {
                lines.append("- **Privacy Note:** Lyrics presence noted; full lyrics text intentionally excluded from report.")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func exportReportJSON(items: [SpotifyAnalysisReportItem]) throws -> Data {
        struct ExportEntry: Codable {
            let inputFilename: String
            let container: String
            let audioCodec: String?
            let hasVideoStream: Bool
            let drmStatus: String
            let classification: String
            let classificationReason: String
            let tagFormat: String
            let title: String?
            let artist: String?
            let album: String?
            let hasLyrics: Bool
            let artworkSummary: String
            let normalizationResult: String?
            let outputFilename: String?
            let outputPath: String?
            let audioPayloadVerified: Bool?
            let preAudioHashSHA256: String?
            let postAudioHashSHA256: String?
            let audioStreamsBefore: [SpotifyAudioStreamVerification]
            let audioStreamsAfter: [SpotifyAudioStreamVerification]
            let actions: [String]
            let warnings: [String]
        }

        let payload = items.map { item in
            ExportEntry(
                inputFilename: item.inputURL.lastPathComponent,
                container: item.containerFormat,
                audioCodec: item.audioCodec,
                hasVideoStream: item.hasVideoStream,
                drmStatus: item.drmStatus.label,
                classification: item.classification.rawValue,
                classificationReason: item.compatibilityReason,
                tagFormat: item.metadataSummary.tagFormat,
                title: item.metadataSummary.title,
                artist: item.metadataSummary.artist,
                album: item.metadataSummary.album,
                hasLyrics: item.metadataSummary.hasLyrics,
                artworkSummary: item.artworkAnalysis.summaryText,
                normalizationResult: item.normalizationState?.rawValue,
                outputFilename: item.outputURL?.lastPathComponent,
                outputPath: item.outputURL?.path,
                audioPayloadVerified: item.audioPayloadVerified,
                preAudioHashSHA256: item.preAudioHashSHA256,
                postAudioHashSHA256: item.postAudioHashSHA256,
                audioStreamsBefore: item.audioStreamsBefore,
                audioStreamsAfter: item.audioStreamsAfter,
                actions: item.normalizationActions,
                warnings: item.warnings
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    private func makeErrorItem(url: URL, ext: String, state: SpotifyNormalizationResultState, reason: String) -> SpotifyAnalysisReportItem {
        SpotifyAnalysisReportItem(
            id: UUID(),
            inputURL: url,
            detectedExtension: ext,
            containerFormat: ext.uppercased(),
            audioCodec: nil,
            hasAudioStream: false,
            hasVideoStream: false,
            videoCodec: nil,
            duration: 0,
            bitRate: nil,
            sampleRate: nil,
            channels: nil,
            drmStatus: .notApplicable,
            classification: .unsupportedFormat,
            compatibilityReason: reason,
            metadataSummary: .empty,
            artworkAnalysis: .empty,
            normalizationState: state,
            normalizationActions: [],
            warnings: [reason],
            outputURL: nil,
            preAudioHashSHA256: nil,
            postAudioHashSHA256: nil,
            audioPayloadVerified: nil
        )
    }
}
