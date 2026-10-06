import Foundation
import AVFoundation
import AppKit
import os.log

final class AudioMetadataProvider: MetadataProvider, @unchecked Sendable {
    
    let providerName = "AudioMetadataProvider"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "AudioMetadataProvider")
    
    var supportedFormats: Set<FileFormat> {
        [.mp3, .m4a, .flac, .wav, .aac, .ogg, .opus, .aiff, .caf, .alac, .ac3]
    }
    
    init() {}
    
    // MARK: - Capabilities
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities {
        guard supportedFormats.contains(format) else {
            return .unsupported(for: format)
        }
        
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
            MetadataFieldDescriptor(id: "copyright", name: "Copyright", section: .rights, valueType: .string, placeholder: "© Copyright"),
            MetadataFieldDescriptor(id: "encoder", name: "Encoder", section: .rights, valueType: .string, isWritable: false)
        ]
        
        // Artwork is fully supported on MP3, M4A, FLAC, ALAC
        let supportsArtwork = [.mp3, .m4a, .flac, .alac].contains(format)
        if supportsArtwork {
            fields.append(MetadataFieldDescriptor(id: "artwork", name: "Album Artwork", section: .audio, valueType: .artwork))
        }
        
        // Technical fields (Read-Only)
        let techFields = [
            MetadataFieldDescriptor(id: "duration", name: "Duration", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "audioCodec", name: "Audio Codec", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "sampleRate", name: "Sample Rate", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "channels", name: "Channels", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "bitrate", name: "Bitrate", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false)
        ]
        fields.append(contentsOf: techFields)
        
        return MetadataCapabilities(
            format: format,
            canRead: true,
            canWrite: true,
            canRemoveGPS: false,
            canRemoveArtwork: supportsArtwork,
            canRemoveAll: true,
            writeStrategy: .streamCopyInPlace,
            fields: fields
        )
    }
    
    // MARK: - Read
    
    func readMetadata(from url: URL) async throws -> MetadataDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url)
        }
        
        let format = FileDetector.detectFormat(url: url) ?? .mp3
        var doc = MetadataDocument(format: format, fileURL: url)
        
        // 1. Read metadata via AVAsset / AVMetadataItem
        let asset = AVURLAsset(url: url)
        
        do {
            let metadataItems = try await asset.load(.metadata)
            for item in metadataItems {
                let keyStr = item.commonKey?.rawValue ?? (item.key as? String) ?? ""
                
                if keyStr == AVMetadataKey.commonKeyTitle.rawValue || keyStr.lowercased() == "title" || keyStr == "TIT2" {
                    doc.common.title = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyArtist.rawValue || keyStr.lowercased() == "artist" || keyStr == "TPE1" {
                    doc.common.artist = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyAlbumName.rawValue || keyStr.lowercased() == "album" || keyStr == "TALB" {
                    doc.common.album = try? await item.load(.stringValue)
                } else if keyStr.lowercased() == "album_artist" || keyStr.lowercased() == "albumartist" || keyStr == "TPE2" || keyStr == "aART" {
                    doc.common.albumArtist = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyType.rawValue || keyStr.lowercased() == "genre" || keyStr == "TCON" || keyStr == "©gen" {
                    doc.common.genre = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyCreationDate.rawValue || keyStr.lowercased() == "date" || keyStr.lowercased() == "year" || keyStr == "TYER" || keyStr == "TDRC" || keyStr == "©day" {
                    if let dateStr = try? await item.load(.stringValue) {
                        doc.common.yearString = dateStr
                    }
                } else if keyStr.lowercased() == "track" || keyStr == "TRCK" || keyStr == "trkn" {
                    doc.common.trackNumber = try? await item.load(.stringValue)
                } else if keyStr.lowercased() == "disc" || keyStr == "TPOS" || keyStr == "disk" {
                    doc.common.discNumber = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyAuthor.rawValue || keyStr.lowercased() == "composer" || keyStr == "TCOM" || keyStr == "©wrt" {
                    doc.common.composer = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyDescription.rawValue || keyStr.lowercased() == "comment" || keyStr == "COMM" || keyStr == "©cmt" {
                    doc.common.comment = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyCopyrights.rawValue || keyStr.lowercased() == "copyright" || keyStr == "TCOP" || keyStr == "cprt" {
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
        let ffmpegProvider = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffmpegPath = await ffmpegProvider.findFFmpegPath() else {
            throw MetadataError.writeFailure("Bundled FFmpeg runtime is required for safe audio container metadata updates.")
        }
        
        let parent = tempURL.deletingLastPathComponent()
        let scratchOut = parent.appendingPathComponent("scratch-\(UUID().uuidString).\(metadata.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: scratchOut) }
        
        var args = ["-y", "-i", tempURL.path]
        
        // If artwork needs to be attached or removed
        var hasArtworkInput = false
        var artworkTempURL: URL? = nil
        defer {
            if let u = artworkTempURL { try? FileManager.default.removeItem(at: u) }
        }
        
        if let artwork = metadata.artwork {
            let artURL = parent.appendingPathComponent("art-\(UUID().uuidString).jpg")
            if (try? artwork.data.write(to: artURL)) != nil {
                artworkTempURL = artURL
                args.append(contentsOf: ["-i", artURL.path])
                hasArtworkInput = true
            }
        }
        
        // Stream copy - DO NOT RE-ENCODE AUDIO
        if hasArtworkInput && metadata.format == .mp3 {
            args.append(contentsOf: [
                "-map", "0:a",
                "-map", "1",
                "-c:a", "copy",
                "-c:v", "copy",
                "-id3v2_version", "3",
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)"
            ])
        } else if hasArtworkInput && metadata.format == .m4a {
            args.append(contentsOf: [
                "-map", "0:a",
                "-map", "1",
                "-c:a", "copy",
                "-c:v", "copy",
                "-disposition:v", "attached_pic"
            ])
        } else if hasArtworkInput && metadata.format == .flac {
            args.append(contentsOf: [
                "-map", "0:a",
                "-map", "1",
                "-c:a", "copy",
                "-c:v", "copy",
                "-metadata:s:v", "title=Album cover"
            ])
        } else {
            args.append(contentsOf: ["-map", "0:a", "-c:a", "copy"])
        }
        
        // Standard metadata tags
        if let title = metadata.common.title { args.append(contentsOf: ["-metadata", "title=\(title)"]) }
        if let artist = metadata.common.artist {
            args.append(contentsOf: ["-metadata", "artist=\(artist)"])
            args.append(contentsOf: ["-metadata", "author=\(artist)"])
        }
        if let album = metadata.common.album { args.append(contentsOf: ["-metadata", "album=\(album)"]) }
        if let albumArtist = metadata.common.albumArtist {
            args.append(contentsOf: ["-metadata", "album_artist=\(albumArtist)"])
            args.append(contentsOf: ["-metadata", "aART=\(albumArtist)"])
        }
        if let genre = metadata.common.genre { args.append(contentsOf: ["-metadata", "genre=\(genre)"]) }
        if let year = metadata.common.year {
            args.append(contentsOf: ["-metadata", "date=\(year)"])
            args.append(contentsOf: ["-metadata", "year=\(year)"])
        }
        if let track = metadata.common.trackNumber { args.append(contentsOf: ["-metadata", "track=\(track)"]) }
        if let disc = metadata.common.discNumber { args.append(contentsOf: ["-metadata", "disc=\(disc)"]) }
        if let composer = metadata.common.composer { args.append(contentsOf: ["-metadata", "composer=\(composer)"]) }
        if let comment = metadata.common.comment { args.append(contentsOf: ["-metadata", "comment=\(comment)"]) }
        if let copyright = metadata.common.copyright { args.append(contentsOf: ["-metadata", "copyright=\(copyright)"]) }
        
        args.append(scratchOut.path)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: scratchOut.path) else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetadataError.writeFailure("FFmpeg tag rewrite failed (code \(process.terminationStatus))", underlying: errStr)
        }
        
        // Move scratch output into tempURL
        try FileManager.default.removeItem(at: tempURL)
        try FileManager.default.moveItem(at: scratchOut, to: tempURL)
    }
    
    private func augmentTechnicalInfoViaFFprobe(for url: URL, doc: inout MetadataDocument) async {
        let provider = BundledFFmpegProvider(fallbackToSystem: true)
        guard let ffprobePath = await provider.findFFprobePath() else { return }
        
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_format",
            "-show_streams",
            "-of", "json",
            url.path
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
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
                var tagMap: [String: String] = [:]
                for (k, v) in tags {
                    if let s = v as? String {
                        tagMap[k.lowercased()] = s
                    }
                }
                
                if doc.common.title == nil { doc.common.title = tagMap["title"] }
                if doc.common.artist == nil { doc.common.artist = tagMap["artist"] ?? tagMap["author"] }
                if doc.common.album == nil { doc.common.album = tagMap["album"] }
                if doc.common.albumArtist == nil { doc.common.albumArtist = tagMap["album_artist"] ?? tagMap["albumartist"] ?? tagMap["aart"] }
                if doc.common.genre == nil { doc.common.genre = tagMap["genre"] }
                if doc.common.composer == nil { doc.common.composer = tagMap["composer"] }
                if doc.common.comment == nil { doc.common.comment = tagMap["comment"] ?? tagMap["description"] }
                if doc.common.copyright == nil { doc.common.copyright = tagMap["copyright"] }
                if doc.common.trackNumber == nil { doc.common.trackNumber = tagMap["track"] }
                if doc.common.discNumber == nil { doc.common.discNumber = tagMap["disc"] }
                if doc.common.yearString == nil { doc.common.yearString = tagMap["date"] ?? tagMap["year"] }
            }
        }
        
        // 2. Stream technical properties
        if let streams = json["streams"] as? [[String: Any]],
           let audioStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
            if let codec = audioStream["codec_name"] as? String {
                doc.technical["audioCodec"] = codec.uppercased()
            }
            if let sampleRate = audioStream["sample_rate"] as? String {
                doc.technical["sampleRate"] = "\(sampleRate) Hz"
            }
            if let channels = audioStream["channels"] as? Int {
                doc.technical["channels"] = channels == 1 ? "1 (Mono)" : "\(channels) (Stereo)"
            }
        }
    }
}
