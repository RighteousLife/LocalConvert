import Foundation
import AVFoundation
import AppKit
import os.log

final class AudioMetadataProvider: MetadataProvider, @unchecked Sendable {
    
    let providerName = "AudioMetadataProvider"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "AudioMetadataProvider")
    
    var supportedFormats: Set<FileFormat> {
        [.mp3, .m4a, .m4b, .flac, .wav, .aac, .ogg, .opus, .aiff, .caf, .alac, .ac3, .eac3, .dts, .wma, .wv, .mka, .au]
    }
    
    init() {}
    
    // MARK: - Capabilities
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities {
        guard supportedFormats.contains(format) else {
            return .unsupported(for: format)
        }
        
        let supportsFullTags = [.mp3, .m4a, .m4b, .alac, .flac, .ogg, .opus, .aiff, .wma, .wv, .mka].contains(format)
        let supportsLyrics = supportsFullTags
        let supportsArtwork = [.mp3, .m4a, .m4b, .alac, .flac].contains(format)
        
        var fields: [MetadataFieldDescriptor] = [
            MetadataFieldDescriptor(id: "title", name: "Title", section: .basic, valueType: .string, placeholder: "Track Title"),
            MetadataFieldDescriptor(id: "artist", name: "Artist", section: .basic, valueType: .string, placeholder: "Artist Name"),
            MetadataFieldDescriptor(id: "album", name: "Album", section: .basic, valueType: .string, placeholder: "Album Name"),
            MetadataFieldDescriptor(id: "albumArtist", name: "Album Artist", section: .audio, valueType: .string, placeholder: "Album Artist Name"),
            MetadataFieldDescriptor(id: "genre", name: "Genre", section: .audio, valueType: .string, placeholder: "e.g. Rock, Classical"),
            MetadataFieldDescriptor(id: "year", name: "Year / Date", section: .basic, valueType: .integer, placeholder: "YYYY"),
            MetadataFieldDescriptor(id: "trackNumber", name: "Track Number", section: .audio, valueType: .string, placeholder: "e.g. 1 or 1/12"),
            MetadataFieldDescriptor(id: "discNumber", name: "Disc Number", section: .audio, valueType: .string, placeholder: "e.g. 1 or 1/2"),
            MetadataFieldDescriptor(id: "composer", name: "Composer", section: .audio, valueType: .string, placeholder: "Composer"),
            MetadataFieldDescriptor(id: "comment", name: "Comment", section: .basic, valueType: .string, placeholder: "Comment or Note"),
            MetadataFieldDescriptor(id: "lyrics", name: "Lyrics", section: .audio, valueType: .string, isWritable: supportsLyrics, isRemovable: supportsLyrics, placeholder: "Embedded song lyrics..."),
            MetadataFieldDescriptor(id: "copyright", name: "Copyright", section: .rights, valueType: .string, placeholder: "© Copyright"),
            MetadataFieldDescriptor(id: "encoder", name: "Encoder", section: .rights, valueType: .string, isWritable: false)
        ]
        
        if supportsArtwork {
            fields.append(MetadataFieldDescriptor(id: "artwork", name: "Album Artwork", section: .audio, valueType: .artwork))
        }
        
        // Technical fields (Read-Only)
        let techFields = [
            MetadataFieldDescriptor(id: "duration", name: "Duration", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "audioCodec", name: "Audio Codec", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "sampleRate", name: "Sample Rate", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "channels", name: "Channels", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "bitrate", name: "Bitrate", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "metadataNote", name: "Container Support", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false)
        ]
        fields.append(contentsOf: techFields)
        
        return MetadataCapabilities(
            format: format,
            canRead: true,
            canWrite: supportsFullTags || [.wav, .caf].contains(format),
            canRemoveGPS: false,
            canRemoveArtwork: supportsArtwork,
            canRemoveAll: true,
            writeStrategy: supportsFullTags || [.wav, .caf].contains(format) ? .streamCopyInPlace : .readOnly,
            fields: fields
        )
    }
    
    static func containerLimitationNote(for format: FileFormat) -> String {
        switch format {
        case .mp3:
            return "ID3v2.3 tags, lyrics (USLT), and cover artwork supported."
        case .m4a, .m4b, .alac:
            return "MP4/iTunes atoms, lyrics, and cover artwork supported."
        case .flac:
            return "Vorbis comments, lyrics, and cover artwork supported."
        case .ogg, .opus:
            return "Vorbis comments & lyrics supported; cover artwork embedding is skipped by muxer."
        case .aiff:
            return "ID3-in-AIFF tags & lyrics supported; cover artwork embedding not supported."
        case .wav, .caf:
            return "Limited INFO/text chunks supported; lyrics & cover artwork may not persist across players."
        case .wma, .wv, .mka:
            return "Text metadata & lyrics supported; cover artwork is not embedded."
        case .aac, .ac3, .eac3, .dts, .au:
            return "Raw/elementary bitstream container with read-only technical inspection."
        default:
            return "Standard audio container tags."
        }
    }
    
    // MARK: - Read
    
    func readMetadata(from url: URL) async throws -> MetadataDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url)
        }
        
        let format = FileDetector.detectFormat(url: url) ?? .mp3
        var doc = MetadataDocument(format: format, fileURL: url)
        doc.technical["metadataNote"] = Self.containerLimitationNote(for: format)
        
        // 1. Read metadata via AVAsset / AVMetadataItem
        let asset = AVURLAsset(url: url)
        
        do {
            let metadataItems = try await asset.load(.metadata)
            for item in metadataItems {
                let keyStr = item.commonKey?.rawValue ?? (item.key as? String) ?? ""
                let lowered = keyStr.lowercased()
                
                if keyStr == AVMetadataKey.commonKeyTitle.rawValue || lowered == "title" || keyStr == "TIT2" {
                    doc.common.title = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyArtist.rawValue || lowered == "artist" || keyStr == "TPE1" {
                    doc.common.artist = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyAlbumName.rawValue || lowered == "album" || keyStr == "TALB" {
                    doc.common.album = try? await item.load(.stringValue)
                } else if lowered == "album_artist" || lowered == "albumartist" || keyStr == "TPE2" || keyStr == "aART" {
                    doc.common.albumArtist = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyType.rawValue || lowered == "genre" || keyStr == "TCON" || keyStr == "©gen" {
                    doc.common.genre = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyCreationDate.rawValue || lowered == "date" || lowered == "year" || keyStr == "TYER" || keyStr == "TDRC" || keyStr == "©day" {
                    if let dateStr = try? await item.load(.stringValue) {
                        doc.common.yearString = dateStr
                    }
                } else if lowered == "track" || keyStr == "TRCK" || keyStr == "trkn" {
                    doc.common.trackNumber = try? await item.load(.stringValue)
                } else if lowered == "disc" || keyStr == "TPOS" || keyStr == "disk" {
                    doc.common.discNumber = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyAuthor.rawValue || lowered == "composer" || keyStr == "TCOM" || keyStr == "©wrt" {
                    doc.common.composer = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyDescription.rawValue || lowered == "comment" || keyStr == "COMM" || keyStr == "©cmt" {
                    doc.common.comment = try? await item.load(.stringValue)
                } else if lowered == "lyrics" || lowered == "unsyncedlyrics" || keyStr == "USLT" || keyStr == "©lyr" {
                    doc.common.lyrics = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyCopyrights.rawValue || lowered == "copyright" || keyStr == "TCOP" || keyStr == "cprt" {
                    doc.common.copyright = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyArtwork.rawValue || keyStr == "APIC" || keyStr == "covr" {
                    if let data = try? await item.load(.dataValue) {
                        doc.artwork = MetadataArtwork(data: data)
                    }
                }
            }
            
            // 2. Read technical details
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite && seconds > 0 {
                    let mins = Int(seconds) / 60
                    let secs = Int(seconds) % 60
                    doc.technical["duration"] = String(format: "%d:%02d", mins, secs)
                }
            }
            
            let tracks = try? await asset.load(.tracks)
            if let audioTrack = tracks?.first(where: { $0.mediaType == .audio }) {
                let formatDescriptions = try? await audioTrack.load(.formatDescriptions)
                if let desc = formatDescriptions?.first {
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                    if let stream = asbd?.pointee {
                        doc.technical["sampleRate"] = "\(Int(stream.mSampleRate)) Hz"
                        doc.technical["channels"] = stream.mChannelsPerFrame == 1 ? "1 (Mono)" : "\(stream.mChannelsPerFrame) (Stereo)"
                    }
                }
                doc.technical["audioCodec"] = format.displayName
            }
        } catch {
            logger.warning("AVAsset read partial metadata: \(error.localizedDescription, privacy: .public)")
        }
        
        // 3. Fallback/Augment via FFprobe if needed
        await augmentTechnicalInfoViaFFprobe(for: url, doc: &doc)
        
        return doc
    }
    
    // Conveniences for protocol
    func read(from url: URL, format: FileFormat) async throws -> MetadataDocument {
        try await readMetadata(from: url)
    }
    
    // MARK: - Write
    
    @discardableResult
    func write(_ metadata: MetadataDocument, to url: URL) async throws -> URL {
        let res = try await writeMetadata(metadata, to: url)
        return res.outputURL
    }
    
    func writeMetadata(
        _ metadata: MetadataDocument,
        to url: URL
    ) async throws -> MetadataWriteResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        try await SafeMetadataWriter.performSafeWrite(on: url) { tempURL in
            try await self.executeWrite(metadata: metadata, tempURL: tempURL)
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        return MetadataWriteResult(outputURL: url, duration: duration)
    }
    
    private func executeWrite(metadata: MetadataDocument, tempURL: URL) async throws {
        let caps = capabilities(for: metadata.format)
        guard caps.canWrite else {
            throw MetadataError.unsupportedFormat(metadata.format)
        }

        let ffmpegProvider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
        guard let ffmpegPath = await ffmpegProvider.findFFmpegPath() else {
            throw MetadataError.writeFailure("Bundled FFmpeg runtime is required for safe audio container metadata updates.")
        }
        
        let parent = tempURL.deletingLastPathComponent()
        let scratchOut = parent.appendingPathComponent("scratch-\(UUID().uuidString).\(metadata.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: scratchOut) }
        
        var args = ["-y", "-hide_banner", "-i", tempURL.path]
        
        // Artwork validation & staging
        var hasArtworkInput = false
        var artworkTempURL: URL? = nil
        defer {
            if let u = artworkTempURL { try? FileManager.default.removeItem(at: u) }
        }
        
        if let artwork = metadata.artwork, caps.canRemoveArtwork {
            let (validatedData, artExt) = try Self.validateAndNormalizeArtwork(artwork.data)
            let artURL = parent.appendingPathComponent("art-\(UUID().uuidString).\(artExt)")
            try validatedData.write(to: artURL)
            artworkTempURL = artURL
            args.append(contentsOf: ["-i", artURL.path])
            hasArtworkInput = true
        }
        
        // Stream copy - strip all tags cleanly on stripAll, otherwise preserve unrelated custom tags via -map_metadata 0
        if metadata.isStrippedAll {
            args.append(contentsOf: ["-map_metadata", "-1", "-map_chapters", "-1"])
        } else {
            args.append(contentsOf: ["-map_metadata", "0"])
        }
        
        if hasArtworkInput && metadata.format == .mp3 && !metadata.isStrippedAll {
            args.append(contentsOf: [
                "-map", "0:a",
                "-map", "1",
                "-c:a", "copy",
                "-c:v", "copy",
                "-id3v2_version", "3",
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)"
            ])
        } else if hasArtworkInput && [.m4a, .m4b, .alac].contains(metadata.format) && !metadata.isStrippedAll {
            args.append(contentsOf: [
                "-map", "0:a",
                "-map", "1",
                "-c:a", "copy",
                "-c:v", "copy",
                "-disposition:v", "attached_pic"
            ])
        } else if hasArtworkInput && metadata.format == .flac && !metadata.isStrippedAll {
            args.append(contentsOf: [
                "-map", "0:a",
                "-map", "1",
                "-c:a", "copy",
                "-c:v", "copy",
                "-disposition:v", "attached_pic",
                "-metadata:s:v", "title=Album cover"
            ])
        } else {
            args.append(contentsOf: ["-map", "0:a", "-c:a", "copy"])
            if metadata.format == .mp3 {
                args.append(contentsOf: ["-id3v2_version", "3"])
            }
        }
        
        if !metadata.isStrippedAll {
            // Standard metadata tags (explicit empty string clears removed tags without dropping unrelated unknown tags)
            args.append(contentsOf: ["-metadata", "title=\(metadata.common.title ?? "")"])
            let artistVal = metadata.common.artist ?? ""
            args.append(contentsOf: ["-metadata", "artist=\(artistVal)"])
            if metadata.format == .wma {
                args.append(contentsOf: ["-metadata", "author=\(artistVal)"])
            }
            args.append(contentsOf: ["-metadata", "album=\(metadata.common.album ?? "")"])
            args.append(contentsOf: ["-metadata", "album_artist=\(metadata.common.albumArtist ?? "")"])
            args.append(contentsOf: ["-metadata", "genre=\(metadata.common.genre ?? "")"])
            if let year = metadata.common.year {
                args.append(contentsOf: ["-metadata", "date=\(year)"])
            } else {
                args.append(contentsOf: ["-metadata", "date="])
            }
            args.append(contentsOf: ["-metadata", "track=\(metadata.common.trackNumber ?? "")"])
            args.append(contentsOf: ["-metadata", "disc=\(metadata.common.discNumber ?? "")"])
            args.append(contentsOf: ["-metadata", "composer=\(metadata.common.composer ?? "")"])
            args.append(contentsOf: ["-metadata", "comment=\(metadata.common.comment ?? "")"])
            args.append(contentsOf: ["-metadata", "copyright=\(metadata.common.copyright ?? "")"])
            args.append(contentsOf: ["-metadata", "lyrics=\(metadata.common.lyrics ?? "")"])
        }
        
        args.append(contentsOf: AudioFilterGraphBuilder.containerMuxerArguments(for: metadata.format))
        args.append(scratchOut.path)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        let result = try await AsyncProcessRunner.run(process)
        
        guard result.terminationStatus == 0, FileManager.default.fileExists(atPath: scratchOut.path) else {
            let errStr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetadataError.writeFailure("FFmpeg tag rewrite failed (code \(result.terminationStatus))", underlying: errStr)
        }
        
        // Move scratch output into tempURL
        try FileManager.default.removeItem(at: tempURL)
        try FileManager.default.moveItem(at: scratchOut, to: tempURL)
    }

    /// Validates artwork bytes represent a decodable raster image (within 10 MB / 4096px safety caps) and normalizes to JPEG/PNG.
    static func validateAndNormalizeArtwork(_ data: Data) throws -> (Data, String) {
        guard !data.isEmpty else {
            throw MetadataError.invalidArtwork("Artwork image data is empty.")
        }
        guard data.count <= 15 * 1024 * 1024 else {
            throw MetadataError.invalidArtwork("Artwork file exceeds 15 MB limit.")
        }
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0 else {
            throw MetadataError.invalidArtwork("Artwork bytes do not represent a valid image.")
        }

        // Preserve native JPEG/PNG headers cleanly when size <= 4096x4096
        let isPNG = data.count >= 8 && data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let isJPEG = data.count >= 3 && data.prefix(3) == Data([0xFF, 0xD8, 0xFF])
        if (isPNG || isJPEG) && cgImage.width <= 4096 && cgImage.height <= 4096 {
            return (data, isPNG ? "png" : "jpg")
        }

        // Convert HEIC/TIFF/oversized images to clean JPEG for universal ID3/MP4/FLAC compatibility
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw MetadataError.invalidArtwork("Unable to encode artwork as JPEG.")
        }
        return (jpegData, "jpg")
    }
    
    private func augmentTechnicalInfoViaFFprobe(for url: URL, doc: inout MetadataDocument) async {
        let provider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
        guard let ffprobePath = await provider.findFFprobePath() else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_format",
            "-show_streams",
            "-of", "json",
            url.path
        ]

        guard let output = try? await AsyncProcessRunner.run(process, stdin: .nullDevice, timeout: 15),
              output.terminationStatus == 0 else { return }
        let data = output.stdout
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        var mergedTags: [String: String] = [:]
        
        // 1. Format tags
        if let formatDict = json["format"] as? [String: Any] {
            if let durationStr = formatDict["duration"] as? String, let sec = Double(durationStr), sec > 0 {
                let mins = Int(sec) / 60
                let secs = Int(sec) % 60
                if doc.technical["duration"] == nil {
                    doc.technical["duration"] = String(format: "%d:%02d", mins, secs)
                }
            }
            if let bitRateStr = formatDict["bit_rate"] as? String, let bps = Int(bitRateStr), bps > 0 {
                if doc.technical["bitrate"] == nil {
                    doc.technical["bitrate"] = "\(bps / 1000) kbps"
                }
            }
            if let tags = formatDict["tags"] as? [String: Any] {
                for (k, v) in tags {
                    if let s = v as? String {
                        mergedTags[k.lowercased()] = s
                    }
                }
            }
        }
        
        // 2. Stream technical properties + stream-level tags (e.g. Ogg/Opus)
        if let streams = json["streams"] as? [[String: Any]] {
            if let audioStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
                if let codec = audioStream["codec_name"] as? String {
                    doc.technical["audioCodec"] = codec.uppercased()
                }
                if let sampleRate = audioStream["sample_rate"] as? String {
                    doc.technical["sampleRate"] = "\(sampleRate) Hz"
                }
                if let channels = audioStream["channels"] as? Int {
                    doc.technical["channels"] = channels == 1 ? "1 (Mono)" : "\(channels) (Stereo)"
                }
                if let streamTags = audioStream["tags"] as? [String: Any] {
                    for (k, v) in streamTags {
                        if let s = v as? String, mergedTags[k.lowercased()] == nil {
                            mergedTags[k.lowercased()] = s
                        }
                    }
                }
            }

            // Fallback artwork extraction via FFmpeg attached_pic when AVURLAsset skips FLAC/OPUS covers
            if doc.artwork == nil,
               streams.contains(where: { (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1 }),
               let ffmpegPath = await provider.findFFmpegPath() {
                let artProc = Process()
                artProc.executableURL = URL(fileURLWithPath: ffmpegPath)
                artProc.arguments = ["-v", "error", "-i", url.path, "-an", "-vcodec", "copy", "-f", "image2pipe", "-vframes", "1", "pipe:1"]
                if let artOutput = try? await AsyncProcessRunner.run(artProc, stdin: .nullDevice, timeout: 15),
                   artOutput.terminationStatus == 0,
                   !artOutput.stdout.isEmpty,
                   NSImage(data: artOutput.stdout) != nil {
                    doc.artwork = MetadataArtwork(data: artOutput.stdout)
                }
            }
        }
        
        if doc.common.title == nil { doc.common.title = mergedTags["title"] }
        if doc.common.artist == nil { doc.common.artist = mergedTags["artist"] ?? mergedTags["author"] }
        if doc.common.album == nil { doc.common.album = mergedTags["album"] }
        if doc.common.albumArtist == nil { doc.common.albumArtist = mergedTags["album_artist"] ?? mergedTags["albumartist"] ?? mergedTags["aart"] }
        if doc.common.genre == nil { doc.common.genre = mergedTags["genre"] }
        if doc.common.composer == nil { doc.common.composer = mergedTags["composer"] }
        if doc.common.comment == nil { doc.common.comment = mergedTags["comment"] ?? mergedTags["description"] }
        if doc.common.copyright == nil { doc.common.copyright = mergedTags["copyright"] }
        if doc.common.trackNumber == nil { doc.common.trackNumber = mergedTags["track"] }
        if doc.common.discNumber == nil { doc.common.discNumber = mergedTags["disc"] }
        if doc.common.yearString == nil { doc.common.yearString = mergedTags["date"] ?? mergedTags["year"] }
        if doc.common.lyrics == nil {
            doc.common.lyrics = mergedTags["lyrics"]
                ?? mergedTags["unsyncedlyrics"]
                ?? mergedTags["lyrics-eng"]
                ?? mergedTags["©lyr"]
        }
    }
}
