import Foundation
import AVFoundation
import os.log

final class VideoMetadataProvider: MetadataProvider, @unchecked Sendable {
    
    let providerName = "VideoMetadataProvider"
    private let logger = Logger(subsystem: "com.localconvert.app", category: "VideoMetadataProvider")
    private let ffprobeExecutableOverride: URL?
    
    var supportedFormats: Set<FileFormat> {
        [.mp4, .mov, .mkv, .webm, .avi, .wmv, .m4v, .threeGP, .threeG2, .mts, .m2ts]
    }
    
    init(ffprobeExecutableOverride: URL? = nil) {
        self.ffprobeExecutableOverride = ffprobeExecutableOverride
    }
    
    // MARK: - Capabilities
    
    func capabilities(for format: FileFormat) -> MetadataCapabilities {
        guard supportedFormats.contains(format) else {
            return .unsupported(for: format)
        }
        
        let fields: [MetadataFieldDescriptor] = [
            MetadataFieldDescriptor(id: "title", name: "Title", section: .basic, valueType: .string, placeholder: "Video Title"),
            MetadataFieldDescriptor(id: "artist", name: "Director / Creator", section: .basic, valueType: .string, placeholder: "Director or Author"),
            MetadataFieldDescriptor(id: "description", name: "Description", section: .description, valueType: .string, placeholder: "Synopsis or Description"),
            MetadataFieldDescriptor(id: "genre", name: "Genre", section: .video, valueType: .string, placeholder: "e.g. Action, Documentary"),
            MetadataFieldDescriptor(id: "year", name: "Year / Release Date", section: .basic, valueType: .integer, placeholder: "YYYY"),
            MetadataFieldDescriptor(id: "copyright", name: "Copyright", section: .rights, valueType: .string, placeholder: "© Copyright Notice"),
            MetadataFieldDescriptor(id: "comment", name: "Comment", section: .basic, valueType: .string, placeholder: "Notes / Comments"),
            
            // Technical details (Read-Only)
            MetadataFieldDescriptor(id: "duration", name: "Duration", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "resolution", name: "Resolution", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "fps", name: "Frame Rate", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "videoCodec", name: "Video Codec", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "audioCodec", name: "Audio Codec", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false),
            MetadataFieldDescriptor(id: "bitrate", name: "Bitrate", section: .technical, valueType: .readOnlyTechnical, isWritable: false, isRemovable: false)
        ]
        
        if format == .threeGP || format == .mts || format == .m2ts {
            return MetadataCapabilities.readOnly(for: format, fields: fields)
        }
        
        return MetadataCapabilities(
            format: format,
            canRead: true,
            canWrite: true,
            canRemoveGPS: false,
            canRemoveArtwork: false,
            canRemoveAll: true,
            writeStrategy: .containerRewrite,
            fields: fields
        )
    }
    
    // MARK: - Read
    
    func readMetadata(from url: URL) async throws -> MetadataDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MetadataError.fileNotFound(url)
        }
        
        let format = FileDetector.detectFormat(url: url) ?? .mp4
        var doc = MetadataDocument(format: format, fileURL: url)
        
        // 1. AVAsset Metadata
        let asset = AVURLAsset(url: url)
        do {
            let metadataItems = try await asset.load(.metadata)
            for item in metadataItems {
                let keyStr = item.commonKey?.rawValue ?? (item.key as? String) ?? ""
                if keyStr == AVMetadataKey.commonKeyTitle.rawValue || keyStr.lowercased() == "title" {
                    doc.common.title = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyArtist.rawValue || keyStr.lowercased() == "artist" {
                    doc.common.artist = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyDescription.rawValue || keyStr.lowercased() == "description" {
                    doc.common.description = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyType.rawValue || keyStr.lowercased() == "genre" {
                    doc.common.genre = try? await item.load(.stringValue)
                } else if keyStr == AVMetadataKey.commonKeyCreationDate.rawValue || keyStr.lowercased() == "date" {
                    if let dateStr = try? await item.load(.stringValue) {
                        doc.common.yearString = dateStr
                    }
                } else if keyStr == AVMetadataKey.commonKeyCopyrights.rawValue || keyStr.lowercased() == "copyright" {
                    doc.common.copyright = try? await item.load(.stringValue)
                }
            }
        } catch {
            logger.warning("AVAsset read partial video metadata: \(error.localizedDescription, privacy: .public)")
        }
        
        // 2. FFprobe Technical & Format Tags (via AsyncProcessRunner to avoid 64 KB pipe buffer deadlock)
        let resolvedFFprobePath: String?
        if let overrideURL = ffprobeExecutableOverride {
            resolvedFFprobePath = overrideURL.path
        } else {
            let provider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
            resolvedFFprobePath = await provider.findFFprobePath()
        }
        if let ffprobePath = resolvedFFprobePath {
            try Task.checkCancellation()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = [
                "-v", "error",
                "-show_format",
                "-show_streams",
                "-of", "json",
                url.path
            ]

            do {
                let output = try await AsyncProcessRunner.run(process)
                if output.terminationStatus == 0,
                   let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] {
                    if let formatDict = json["format"] as? [String: Any] {
                        if let durationStr = formatDict["duration"] as? String, let sec = Double(durationStr), sec > 0 {
                            let mins = Int(sec) / 60
                            let secs = Int(sec) % 60
                            doc.technical["duration"] = String(format: "%d:%02d", mins, secs)
                        }
                        if let bitRateStr = formatDict["bit_rate"] as? String, let bps = Int(bitRateStr), bps > 0 {
                            doc.technical["bitrate"] = "\(bps / 1000) kbps"
                        }
                        
                        if let tags = formatDict["tags"] as? [String: Any] {
                            var tagMap: [String: String] = [:]
                            for (k, v) in tags {
                                if let s = v as? String { tagMap[k.lowercased()] = s }
                            }
                            if doc.common.title == nil { doc.common.title = tagMap["title"] }
                            if doc.common.artist == nil { doc.common.artist = tagMap["artist"] ?? tagMap["author"] }
                            if doc.common.description == nil { doc.common.description = tagMap["description"] ?? tagMap["comment"] }
                            if doc.common.genre == nil { doc.common.genre = tagMap["genre"] }
                            if doc.common.comment == nil { doc.common.comment = tagMap["comment"] }
                            if doc.common.copyright == nil { doc.common.copyright = tagMap["copyright"] }
                            if doc.common.yearString == nil { doc.common.yearString = tagMap["date"] ?? tagMap["year"] }
                        }
                    }
                    
                    if let streams = json["streams"] as? [[String: Any]] {
                        if let vStream = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
                            if let w = vStream["width"] as? Int, let h = vStream["height"] as? Int {
                                doc.technical["resolution"] = "\(w) × \(h)"
                            }
                            if let rFrame = vStream["r_frame_rate"] as? String {
                                let parts = rFrame.split(separator: "/")
                                if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                                    doc.technical["fps"] = String(format: "%.2f fps", num / den)
                                }
                            }
                            if let vcodec = vStream["codec_name"] as? String {
                                doc.technical["videoCodec"] = vcodec.uppercased()
                            }
                        }
                        if let aStream = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
                            if let acodec = aStream["codec_name"] as? String {
                                doc.technical["audioCodec"] = acodec.uppercased()
                            }
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("ffprobe metadata read failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        
        return doc
    }
    
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
        let ffmpegProvider = BundledFFmpegProvider(fallbackToSystem: BundledBinarySecurityPolicy.allowsSystemFallback)
        guard let ffmpegPath = await ffmpegProvider.findFFmpegPath() else {
            throw MetadataError.writeFailure("Bundled FFmpeg runtime is required for safe video container metadata updates.")
        }
        
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalConvert-VideoMeta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        let scratchOut = scratchDir.appendingPathComponent("out.\(metadata.format.fileExtension)")
        
        var args = ["-y", "-i", tempURL.path, "-map", "0", "-c", "copy"]
        
        if metadata.isStrippedAll || metadata.isEditableMetadataEmpty {
            args.append(contentsOf: ["-map_metadata", "-1", "-map_chapters", "-1"])
        } else {
            args.append(contentsOf: ["-map_metadata", "0"])
            args.append(contentsOf: ["-metadata", "title=\(metadata.common.title ?? "")"])
            args.append(contentsOf: ["-metadata", "artist=\(metadata.common.artist ?? "")"])
            args.append(contentsOf: ["-metadata", "description=\(metadata.common.description ?? "")"])
            args.append(contentsOf: ["-metadata", "genre=\(metadata.common.genre ?? "")"])
            args.append(contentsOf: ["-metadata", "date=\(metadata.common.year.map(String.init) ?? "")"])
            args.append(contentsOf: ["-metadata", "copyright=\(metadata.common.copyright ?? "")"])
            args.append(contentsOf: ["-metadata", "comment=\(metadata.common.comment ?? "")"])
            if metadata.gps == nil {
                args.append(contentsOf: [
                    "-metadata", "location=",
                    "-metadata", "location-eng=",
                    "-metadata", "com.apple.quicktime.location.ISO6709="
                ])
            }
        }
        
        args.append(scratchOut.path)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        let result = try await AsyncProcessRunner.run(process)
        
        guard result.terminationStatus == 0, FileManager.default.fileExists(atPath: scratchOut.path) else {
            let errStr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetadataError.writeFailure("FFmpeg video tag rewrite failed", underlying: errStr)
        }
        
        try FileManager.default.removeItem(at: tempURL)
        try FileManager.default.moveItem(at: scratchOut, to: tempURL)
    }
}
