import Foundation
import AppKit

// MARK: - Artwork Model

struct MetadataArtwork: Sendable, Equatable {
    var data: Data
    var mimeType: String
    var description: String?
    
    init(data: Data, mimeType: String = "image/jpeg", description: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.description = description
    }
    
    var image: NSImage? {
        NSImage(data: data)
    }
}

// MARK: - GPS Location

struct MetadataGPS: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    
    init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
    
    var formattedCoordinate: String {
        let latDirection = latitude >= 0 ? "N" : "S"
        let lonDirection = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f°%@, %.4f°%@", abs(latitude), latDirection, abs(longitude), lonDirection)
    }
}

// MARK: - Generic Metadata Value

enum MetadataValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case decimal(Double)
    case boolean(Bool)
    case date(Date)
    case url(URL)
    case artwork(MetadataArtwork)
    case gps(MetadataGPS)
    case technical(String)
    
    var stringValue: String {
        switch self {
        case .string(let str): return str
        case .integer(let val): return String(val)
        case .decimal(let val): return String(format: "%.2f", val)
        case .boolean(let val): return val ? "Yes" : "No"
        case .date(let date):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        case .url(let url): return url.absoluteString
        case .artwork: return "[Artwork Image]"
        case .gps(let loc): return loc.formattedCoordinate
        case .technical(let tech): return tech
        }
    }
}

// MARK: - Common Normalized Metadata

struct CommonMetadata: Sendable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var yearString: String? {
        get { year.map { String($0) } }
        set {
            if let val = newValue, let intVal = Int(val) {
                year = intVal
            } else if newValue == nil {
                year = nil
            }
        }
    }
    var date: Date?
    var trackNumber: String?
    var discNumber: String?
    var composer: String?
    var comment: String?
    var copyright: String?
    var encoder: String?
    
    // Documents & Office
    var author: String?
    var subject: String?
    var keywords: [String]?
    var creator: String?
    var description: String?
    var revision: String?
    
    // Camera & EXIF
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var aperture: Double?
    var focalLength: Double?
    
    init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        date: Date? = nil,
        trackNumber: String? = nil,
        discNumber: String? = nil,
        composer: String? = nil,
        comment: String? = nil,
        copyright: String? = nil,
        encoder: String? = nil,
        author: String? = nil,
        subject: String? = nil,
        keywords: [String]? = nil,
        creator: String? = nil,
        description: String? = nil,
        revision: String? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        iso: Int? = nil,
        aperture: Double? = nil,
        focalLength: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.date = date
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.composer = composer
        self.comment = comment
        self.copyright = copyright
        self.encoder = encoder
        self.author = author
        self.subject = subject
        self.keywords = keywords
        self.creator = creator
        self.description = description
        self.revision = revision
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.aperture = aperture
        self.focalLength = focalLength
    }
}

// MARK: - Metadata Document

struct MetadataDocument: Sendable, Equatable {
    let format: FileFormat
    var fileURL: URL?
    var common: CommonMetadata
    var customFields: [String: MetadataValue]
    var technical: [String: String]
    var artwork: MetadataArtwork?
    var gps: MetadataGPS?
    var isDirty: Bool = false
    
    init(
        format: FileFormat,
        fileURL: URL? = nil,
        common: CommonMetadata = CommonMetadata(),
        customFields: [String: MetadataValue] = [:],
        technical: [String: String] = [:],
        artwork: MetadataArtwork? = nil,
        gps: MetadataGPS? = nil,
        isDirty: Bool = false
    ) {
        self.format = format
        self.fileURL = fileURL
        self.common = common
        self.customFields = customFields
        self.technical = technical
        self.artwork = artwork
        self.gps = gps
        self.isDirty = isDirty
    }
    
    func value(for fieldId: String) -> MetadataValue? {
        // First check custom fields
        if let custom = customFields[fieldId] {
            return custom
        }
        
        // Then map standard common field IDs
        switch fieldId {
        case "title": return common.title.map { .string($0) }
        case "artist": return common.artist.map { .string($0) }
        case "album": return common.album.map { .string($0) }
        case "albumArtist": return common.albumArtist.map { .string($0) }
        case "genre": return common.genre.map { .string($0) }
        case "year": return common.year.map { .integer($0) }
        case "trackNumber", "track": return common.trackNumber.map { .string($0) }
        case "discNumber", "disc": return common.discNumber.map { .string($0) }
        case "composer": return common.composer.map { .string($0) }
        case "comment": return common.comment.map { .string($0) }
        case "copyright": return common.copyright.map { .string($0) }
        case "encoder": return common.encoder.map { .string($0) }
        case "author": return common.author.map { .string($0) }
        case "subject": return common.subject.map { .string($0) }
        case "creator": return common.creator.map { .string($0) }
        case "description": return common.description.map { .string($0) }
        case "revision": return common.revision.map { .string($0) }
        case "cameraMake": return common.cameraMake.map { .string($0) }
        case "cameraModel": return common.cameraModel.map { .string($0) }
        case "lensModel": return common.lensModel.map { .string($0) }
        case "iso": return common.iso.map { .integer($0) }
        case "aperture": return common.aperture.map { .decimal($0) }
        case "focalLength": return common.focalLength.map { .decimal($0) }
        case "artwork": return artwork.map { .artwork($0) }
        case "gps": return gps.map { .gps($0) }
        default:
            if let tech = technical[fieldId] {
                return .technical(tech)
            }
            return nil
        }
    }
    
    mutating func setValue(_ value: MetadataValue?, for fieldId: String) {
        isDirty = true
        switch fieldId {
        case "title": common.title = value?.stringValue
        case "artist": common.artist = value?.stringValue
        case "album": common.album = value?.stringValue
        case "albumArtist": common.albumArtist = value?.stringValue
        case "genre": common.genre = value?.stringValue
        case "year":
            if let val = value?.stringValue, let intVal = Int(val) {
                common.year = intVal
            } else if case .integer(let intVal) = value {
                common.year = intVal
            } else {
                common.year = nil
            }
        case "trackNumber", "track": common.trackNumber = value?.stringValue
        case "discNumber", "disc": common.discNumber = value?.stringValue
        case "composer": common.composer = value?.stringValue
        case "comment": common.comment = value?.stringValue
        case "copyright": common.copyright = value?.stringValue
        case "encoder": common.encoder = value?.stringValue
        case "author": common.author = value?.stringValue
        case "subject": common.subject = value?.stringValue
        case "creator": common.creator = value?.stringValue
        case "description": common.description = value?.stringValue
        case "revision": common.revision = value?.stringValue
        case "cameraMake": common.cameraMake = value?.stringValue
        case "cameraModel": common.cameraModel = value?.stringValue
        case "lensModel": common.lensModel = value?.stringValue
        case "iso":
            if let val = value?.stringValue, let intVal = Int(val) {
                common.iso = intVal
            } else if case .integer(let intVal) = value {
                common.iso = intVal
            } else {
                common.iso = nil
            }
        case "aperture":
            if let val = value?.stringValue, let dblVal = Double(val) {
                common.aperture = dblVal
            } else if case .decimal(let dblVal) = value {
                common.aperture = dblVal
            } else {
                common.aperture = nil
            }
        case "focalLength":
            if let val = value?.stringValue, let dblVal = Double(val) {
                common.focalLength = dblVal
            } else if case .decimal(let dblVal) = value {
                common.focalLength = dblVal
            } else {
                common.focalLength = nil
            }
        case "artwork":
            if case .artwork(let art) = value {
                artwork = art
            } else if value == nil {
                artwork = nil
            }
        case "gps":
            if case .gps(let loc) = value {
                gps = loc
            } else if value == nil {
                gps = nil
            }
        default:
            if let v = value {
                customFields[fieldId] = v
            } else {
                customFields.removeValue(forKey: fieldId)
            }
        }
    }
}
