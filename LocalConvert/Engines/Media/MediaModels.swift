import Foundation

// MARK: - Media Stream Type

enum MediaStreamType: String, Sendable, Codable {
    case video
    case audio
    case subtitle
    case other
}

// MARK: - Media Stream Info

struct MediaStreamInfo: Sendable, Codable, Equatable {
    let index: Int
    let streamType: MediaStreamType
    let codecName: String
    let codecLongName: String?
    let bitRate: Int64?
    
    // Video specific
    let width: Int?
    let height: Int?
    let frameRate: Double?
    
    // Audio specific
    let sampleRate: Int?
    let channels: Int?
    
    let duration: Double?
}

// MARK: - Media Info (Probed metadata)

struct MediaInfo: Sendable, Codable, Equatable {
    let url: URL
    let formatName: String
    let duration: Double
    let fileSize: Int64?
    let bitRate: Int64?
    let streams: [MediaStreamInfo]
    
    var videoStreams: [MediaStreamInfo] {
        streams.filter { $0.streamType == .video }
    }
    
    var audioStreams: [MediaStreamInfo] {
        streams.filter { $0.streamType == .audio }
    }
    
    var primaryVideoStream: MediaStreamInfo? {
        videoStreams.first
    }
    
    var primaryAudioStream: MediaStreamInfo? {
        audioStreams.first
    }
    
    var hasVideo: Bool {
        !videoStreams.isEmpty
    }
    
    var hasAudio: Bool {
        !audioStreams.isEmpty
    }
    
    var isVideo: Bool {
        hasVideo
    }
    
    var isAudioOnly: Bool {
        hasAudio && !hasVideo
    }
}

// MARK: - ffprobe JSON Decodable DTOs

struct FFprobeOutputDTO: Codable {
    let streams: [FFprobeStreamDTO]?
    let format: FFprobeFormatDTO?
}

struct FFprobeStreamDTO: Codable {
    let index: Int
    let codec_name: String?
    let codec_long_name: String?
    let codec_type: String?
    let width: Int?
    let height: Int?
    let r_frame_rate: String?
    let avg_frame_rate: String?
    let sample_rate: String?
    let channels: Int?
    let duration: String?
    let bit_rate: String?
}

struct FFprobeFormatDTO: Codable {
    let filename: String?
    let nb_streams: Int?
    let format_name: String?
    let format_long_name: String?
    let duration: String?
    let size: String?
    let bit_rate: String?
}
