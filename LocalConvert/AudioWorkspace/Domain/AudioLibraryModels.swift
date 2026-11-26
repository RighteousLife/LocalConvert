import Foundation

// MARK: - Domain Validation Errors

enum AudioDomainValidationError: Error, LocalizedError, Equatable, Sendable {
    case emptyIdentifierOrPath(String)
    case negativeValue(field: String, value: Int64)
    case outOfBoundsInt(field: String, value: Int, rangeDescription: String)
    case outOfBoundsDouble(field: String, value: Double, rangeDescription: String)
    case unsupportedAudioFormat(String)
    case invalidIndex(index: Int, count: Int)
    case invalidSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .emptyIdentifierOrPath(let field):
            return "Audio domain field '\(field)' must not be empty."
        case .negativeValue(let field, let value):
            return "Audio domain field '\(field)' cannot be negative (\(value))."
        case .outOfBoundsInt(let field, let value, let rangeDesc):
            return "Audio domain field '\(field)' value \(value) is outside allowed range \(rangeDesc)."
        case .outOfBoundsDouble(let field, let value, let rangeDesc):
            return "Audio domain field '\(field)' value \(value) is outside allowed range \(rangeDesc)."
        case .unsupportedAudioFormat(let raw):
            return "Format '\(raw)' is not a valid audio export format."
        case .invalidIndex(let index, let count):
            return "Index \(index) is out of bounds for collection of count \(count)."
        case .invalidSchemaVersion(let version):
            return "Invalid schema version \(version); expected >= 1."
        }
    }
}

// MARK: - Asset Availability & Metadata Origin

enum AssetAvailabilityStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case ok
    case missing
    case modified
}

enum MetadataOrigin: String, Codable, Hashable, CaseIterable, Sendable {
    case embeddedAndIndexed
    case libraryOnlyOverride
    case readOnlyTechnical
}

struct LibraryRootFolder: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var path: String
    var bookmarkData: Data?
    var lastScannedAt: Date?
    var recursive: Bool

    init(
        id: UUID = UUID(),
        path: String,
        bookmarkData: Data? = nil,
        lastScannedAt: Date? = nil,
        recursive: Bool = true
    ) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AudioDomainValidationError.emptyIdentifierOrPath("LibraryRootFolder.path")
        }
        self.id = id
        self.path = trimmed
        self.bookmarkData = bookmarkData
        self.lastScannedAt = lastScannedAt
        self.recursive = recursive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let path = try c.decode(String.self, forKey: .path)
        let bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmarkData)
        let lastScanned = try c.decodeIfPresent(Date.self, forKey: .lastScannedAt)
        let recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? true
        try self.init(id: id, path: path, bookmarkData: bookmark, lastScannedAt: lastScanned, recursive: recursive)
    }
}

// MARK: - AudioAsset

struct AudioAsset: Codable, Hashable, Identifiable, Sendable {
    static let validRatingRange = 0...5

    let id: UUID
    var canonicalPath: String
    var bookmarkData: Data?
    var displayFilename: String
    var fileExtension: String
    var formatRawValue: String
    var fileSizeBytes: Int64
    var modificationTime: TimeInterval
    var partialHashSHA256: String?
    var contentSHA256: String?
    var sampleRate: SampleRate
    var channelCount: Int
    var bitDepth: Int?
    var bitrateBps: Int?
    var frameCount: Int64
    /// Derived display/sort duration helper in seconds (non-authoritative for edits).
    var durationSeconds: Double
    var isLosslessCodec: Bool
    var codecName: String
    var status: AssetAvailabilityStatus
    var dateAdded: Date
    var dateModified: Date
    var playCount: Int
    var lastPlayedAt: Date?
    var isFavorite: Bool
    var rating: Int

    init(
        id: UUID = UUID(),
        canonicalPath: String,
        bookmarkData: Data? = nil,
        displayFilename: String,
        fileExtension: String,
        formatRawValue: String,
        fileSizeBytes: Int64,
        modificationTime: TimeInterval,
        partialHashSHA256: String? = nil,
        contentSHA256: String? = nil,
        sampleRate: SampleRate,
        channelCount: Int,
        bitDepth: Int? = nil,
        bitrateBps: Int? = nil,
        frameCount: Int64,
        durationSeconds: Double? = nil,
        isLosslessCodec: Bool,
        codecName: String,
        status: AssetAvailabilityStatus = .ok,
        dateAdded: Date = Date(),
        dateModified: Date = Date(),
        playCount: Int = 0,
        lastPlayedAt: Date? = nil,
        isFavorite: Bool = false,
        rating: Int = 0
    ) throws {
        let trimmedPath = canonicalPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw AudioDomainValidationError.emptyIdentifierOrPath("AudioAsset.canonicalPath")
        }
        guard fileSizeBytes >= 0 else {
            throw AudioDomainValidationError.negativeValue(field: "AudioAsset.fileSizeBytes", value: fileSizeBytes)
        }
        guard channelCount >= 1 else {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioAsset.channelCount", value: channelCount, rangeDescription: ">= 1")
        }
        if let bitDepth, bitDepth < 1 {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioAsset.bitDepth", value: bitDepth, rangeDescription: ">= 1")
        }
        if let bitrateBps, bitrateBps < 0 {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioAsset.bitrateBps", value: bitrateBps, rangeDescription: ">= 0")
        }
        guard frameCount >= 0 else {
            throw AudioDomainValidationError.negativeValue(field: "AudioAsset.frameCount", value: frameCount)
        }
        guard playCount >= 0 else {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioAsset.playCount", value: playCount, rangeDescription: ">= 0")
        }
        guard Self.validRatingRange.contains(rating) else {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioAsset.rating", value: rating, rangeDescription: "0...5")
        }
        let derived = durationSeconds ?? (Double(frameCount) / Double(sampleRate.hz))
        guard derived.isFinite && derived >= 0 else {
            throw AudioDomainValidationError.outOfBoundsDouble(field: "AudioAsset.durationSeconds", value: derived, rangeDescription: ">= 0 and finite")
        }

        self.id = id
        self.canonicalPath = trimmedPath
        self.bookmarkData = bookmarkData
        self.displayFilename = displayFilename
        self.fileExtension = fileExtension
        self.formatRawValue = formatRawValue
        self.fileSizeBytes = fileSizeBytes
        self.modificationTime = modificationTime
        self.partialHashSHA256 = partialHashSHA256
        self.contentSHA256 = contentSHA256
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.bitrateBps = bitrateBps
        self.frameCount = frameCount
        self.durationSeconds = derived
        self.isLosslessCodec = isLosslessCodec
        self.codecName = codecName
        self.status = status
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
        self.isFavorite = isFavorite
        self.rating = rating
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try c.decode(UUID.self, forKey: .id),
            canonicalPath: try c.decode(String.self, forKey: .canonicalPath),
            bookmarkData: try c.decodeIfPresent(Data.self, forKey: .bookmarkData),
            displayFilename: try c.decode(String.self, forKey: .displayFilename),
            fileExtension: try c.decode(String.self, forKey: .fileExtension),
            formatRawValue: try c.decode(String.self, forKey: .formatRawValue),
            fileSizeBytes: try c.decode(Int64.self, forKey: .fileSizeBytes),
            modificationTime: try c.decode(TimeInterval.self, forKey: .modificationTime),
            partialHashSHA256: try c.decodeIfPresent(String.self, forKey: .partialHashSHA256),
            contentSHA256: try c.decodeIfPresent(String.self, forKey: .contentSHA256),
            sampleRate: try c.decode(SampleRate.self, forKey: .sampleRate),
            channelCount: try c.decode(Int.self, forKey: .channelCount),
            bitDepth: try c.decodeIfPresent(Int.self, forKey: .bitDepth),
            bitrateBps: try c.decodeIfPresent(Int.self, forKey: .bitrateBps),
            frameCount: try c.decode(Int64.self, forKey: .frameCount),
            durationSeconds: try c.decodeIfPresent(Double.self, forKey: .durationSeconds),
            isLosslessCodec: try c.decode(Bool.self, forKey: .isLosslessCodec),
            codecName: try c.decode(String.self, forKey: .codecName),
            status: try c.decodeIfPresent(AssetAvailabilityStatus.self, forKey: .status) ?? .ok,
            dateAdded: try c.decode(Date.self, forKey: .dateAdded),
            dateModified: try c.decode(Date.self, forKey: .dateModified),
            playCount: try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0,
            lastPlayedAt: try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt),
            isFavorite: try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            rating: try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        )
    }

    var fileFormat: FileFormat? {
        FileFormat(rawValue: formatRawValue)
    }

    var durationFrameTime: SampleFrameTime {
        SampleFrameTime(frame: frameCount, sampleRate: sampleRate)
    }
}

// MARK: - AudioMetadata

struct AudioMetadata: Codable, Hashable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var composer: String?
    var comment: String?
    var lyrics: String?
    var copyright: String?
    var encoder: String?
    var hasEmbeddedArtwork: Bool
    var artworkCacheKey: String?
    var metadataOrigin: MetadataOrigin

    init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        composer: String? = nil,
        comment: String? = nil,
        lyrics: String? = nil,
        copyright: String? = nil,
        encoder: String? = nil,
        hasEmbeddedArtwork: Bool = false,
        artworkCacheKey: String? = nil,
        metadataOrigin: MetadataOrigin = .embeddedAndIndexed
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.composer = composer
        self.comment = comment
        self.lyrics = lyrics
        self.copyright = copyright
        self.encoder = encoder
        self.hasEmbeddedArtwork = hasEmbeddedArtwork
        self.artworkCacheKey = artworkCacheKey
        self.metadataOrigin = metadataOrigin
    }
}

// MARK: - Library, Smart Collections & Playlists

struct AudioLibrary: Codable, Hashable, Equatable, Sendable {
    var totalAssetCount: Int
    var totalDurationSeconds: Double
    var totalBytes: Int64
    var watchedRootFolders: [LibraryRootFolder]
    var schemaVersion: Int
    var fts5Available: Bool

    init(
        totalAssetCount: Int = 0,
        totalDurationSeconds: Double = 0,
        totalBytes: Int64 = 0,
        watchedRootFolders: [LibraryRootFolder] = [],
        schemaVersion: Int = 1,
        fts5Available: Bool = true
    ) throws {
        guard totalAssetCount >= 0 else {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioLibrary.totalAssetCount", value: totalAssetCount, rangeDescription: ">= 0")
        }
        guard totalDurationSeconds.isFinite && totalDurationSeconds >= 0 else {
            throw AudioDomainValidationError.outOfBoundsDouble(field: "AudioLibrary.totalDurationSeconds", value: totalDurationSeconds, rangeDescription: ">= 0 and finite")
        }
        guard totalBytes >= 0 else {
            throw AudioDomainValidationError.negativeValue(field: "AudioLibrary.totalBytes", value: totalBytes)
        }
        guard schemaVersion >= 1 else {
            throw AudioDomainValidationError.invalidSchemaVersion(schemaVersion)
        }
        self.totalAssetCount = totalAssetCount
        self.totalDurationSeconds = totalDurationSeconds
        self.totalBytes = totalBytes
        self.watchedRootFolders = watchedRootFolders
        self.schemaVersion = schemaVersion
        self.fts5Available = fts5Available
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            totalAssetCount: try c.decode(Int.self, forKey: .totalAssetCount),
            totalDurationSeconds: try c.decode(Double.self, forKey: .totalDurationSeconds),
            totalBytes: try c.decode(Int64.self, forKey: .totalBytes),
            watchedRootFolders: try c.decode([LibraryRootFolder].self, forKey: .watchedRootFolders),
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            fts5Available: try c.decode(Bool.self, forKey: .fts5Available)
        )
    }
}

enum AudioCollectionSortField: String, Codable, Hashable, CaseIterable, Sendable {
    case title
    case artist
    case album
    case duration
    case sampleRate
    case dateAdded
    case lastPlayed
    case playCount
}

struct AudioCollectionFilter: Codable, Hashable, Equatable, Sendable {
    var searchQuery: String?
    var losslessOnly: Bool
    var hiResOnly: Bool
    var missingOnly: Bool
    var favoritesOnly: Bool
    var minimumRating: Int
    var recentDaysWindow: Int?
    var formatFilter: String?

    init(
        searchQuery: String? = nil,
        losslessOnly: Bool = false,
        hiResOnly: Bool = false,
        missingOnly: Bool = false,
        favoritesOnly: Bool = false,
        minimumRating: Int = 0,
        recentDaysWindow: Int? = nil,
        formatFilter: String? = nil
    ) throws {
        guard AudioAsset.validRatingRange.contains(minimumRating) else {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioCollectionFilter.minimumRating", value: minimumRating, rangeDescription: "0...5")
        }
        if let recentDaysWindow, recentDaysWindow < 1 {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioCollectionFilter.recentDaysWindow", value: recentDaysWindow, rangeDescription: ">= 1")
        }
        self.searchQuery = searchQuery
        self.losslessOnly = losslessOnly
        self.hiResOnly = hiResOnly
        self.missingOnly = missingOnly
        self.favoritesOnly = favoritesOnly
        self.minimumRating = minimumRating
        self.recentDaysWindow = recentDaysWindow
        self.formatFilter = formatFilter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            searchQuery: try c.decodeIfPresent(String.self, forKey: .searchQuery),
            losslessOnly: try c.decodeIfPresent(Bool.self, forKey: .losslessOnly) ?? false,
            hiResOnly: try c.decodeIfPresent(Bool.self, forKey: .hiResOnly) ?? false,
            missingOnly: try c.decodeIfPresent(Bool.self, forKey: .missingOnly) ?? false,
            favoritesOnly: try c.decodeIfPresent(Bool.self, forKey: .favoritesOnly) ?? false,
            minimumRating: try c.decodeIfPresent(Int.self, forKey: .minimumRating) ?? 0,
            recentDaysWindow: try c.decodeIfPresent(Int.self, forKey: .recentDaysWindow),
            formatFilter: try c.decodeIfPresent(String.self, forKey: .formatFilter)
        )
    }
}

/// Smart Collection rule evaluated dynamically against the SQLite library index.
struct AudioCollection: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var iconName: String
    var filterSpec: AudioCollectionFilter
    var sortField: AudioCollectionSortField
    var sortAscending: Bool

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "music.note.list",
        filterSpec: AudioCollectionFilter,
        sortField: AudioCollectionSortField = .dateAdded,
        sortAscending: Bool = false
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AudioDomainValidationError.emptyIdentifierOrPath("AudioCollection.name")
        }
        self.id = id
        self.name = trimmed
        self.iconName = iconName
        self.filterSpec = filterSpec
        self.sortField = sortField
        self.sortAscending = sortAscending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            iconName: try c.decodeIfPresent(String.self, forKey: .iconName) ?? "music.note.list",
            filterSpec: try c.decode(AudioCollectionFilter.self, forKey: .filterSpec),
            sortField: try c.decodeIfPresent(AudioCollectionSortField.self, forKey: .sortField) ?? .dateAdded,
            sortAscending: try c.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? false
        )
    }
}

struct AudioPlaylist: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var description: String?
    var createdAt: Date
    var updatedAt: Date
    var orderedAssetIDs: [UUID]

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        orderedAssetIDs: [UUID] = []
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AudioDomainValidationError.emptyIdentifierOrPath("AudioPlaylist.name")
        }
        self.id = id
        self.name = trimmed
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.orderedAssetIDs = orderedAssetIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            createdAt: try c.decode(Date.self, forKey: .createdAt),
            updatedAt: try c.decode(Date.self, forKey: .updatedAt),
            orderedAssetIDs: try c.decodeIfPresent([UUID].self, forKey: .orderedAssetIDs) ?? []
        )
    }
}

// MARK: - Editing Selection, Operations, Export & Recovery State Models

struct AudioSelection: Codable, Hashable, Equatable, Sendable {
    var trackIDs: Set<UUID>
    var range: SampleFrameRange?
    var selectedClipIDs: Set<UUID>

    init(
        trackIDs: Set<UUID> = [],
        range: SampleFrameRange? = nil,
        selectedClipIDs: Set<UUID> = []
    ) {
        self.trackIDs = trackIDs
        self.range = range
        self.selectedClipIDs = selectedClipIDs
    }
}

enum AudioEditOperation: String, Codable, Hashable, CaseIterable, Sendable {
    case split
    case trim
    case cut
    case copy
    case paste
    case delete
    case rippleDelete
    case join
    case insertSilence
    case setGain
    case setFade
    case normalize
    case applyEffect
    case channelTransform
    case reorderTrack
}

enum AudioExportMode: String, Codable, Hashable, CaseIterable, Sendable {
    case bitExactPassThrough
    case losslessFormatReRender
    case lossyFormatReRender
}

enum AudioExportBitDepth: Int, Codable, Hashable, CaseIterable, Sendable {
    case int16 = 16
    case int24 = 24
    case float32 = 32
}

enum AudioExportDitheringPolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case autoTPDFWhenDownquantizing
    case disabled
}

struct AudioExportConfiguration: Codable, Hashable, Equatable, Sendable {
    var exportMode: AudioExportMode
    var scope: AudioExportScope
    var outputFormat: FileFormat
    var sampleRate: SampleRate
    var bitDepth: AudioExportBitDepth
    var bitrateKbps: Int
    var channelCount: Int
    var preserveMetadata: Bool
    var loudnessNormalizeEnabled: Bool
    var targetLUFS: Double
    var truePeakCeilingDBTP: Double
    var ditheringPolicy: AudioExportDitheringPolicy
    var validateOutput: Bool

    init(
        exportMode: AudioExportMode = .losslessFormatReRender,
        scope: AudioExportScope = .entireProject,
        outputFormat: FileFormat = .wav,
        sampleRate: SampleRate = .rate48k,
        bitDepth: AudioExportBitDepth = .int24,
        bitrateKbps: Int = 320,
        channelCount: Int = 2,
        preserveMetadata: Bool = true,
        loudnessNormalizeEnabled: Bool = false,
        targetLUFS: Double = -14.0,
        truePeakCeilingDBTP: Double = -1.0,
        ditheringPolicy: AudioExportDitheringPolicy = .autoTPDFWhenDownquantizing,
        validateOutput: Bool = true
    ) throws {
        guard outputFormat.category == .audio else {
            throw AudioDomainValidationError.unsupportedAudioFormat(outputFormat.rawValue)
        }
        guard bitrateKbps >= 8 && bitrateKbps <= 10_000 else {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioExportConfiguration.bitrateKbps", value: bitrateKbps, rangeDescription: "8...10000")
        }
        guard channelCount >= 1 && channelCount <= 16 else {
            throw AudioDomainValidationError.outOfBoundsInt(field: "AudioExportConfiguration.channelCount", value: channelCount, rangeDescription: "1...16")
        }
        guard targetLUFS.isFinite && targetLUFS >= -70.0 && targetLUFS <= 0.0 else {
            throw AudioDomainValidationError.outOfBoundsDouble(field: "AudioExportConfiguration.targetLUFS", value: targetLUFS, rangeDescription: "-70.0...0.0")
        }
        guard truePeakCeilingDBTP.isFinite && truePeakCeilingDBTP >= -12.0 && truePeakCeilingDBTP <= 0.0 else {
            throw AudioDomainValidationError.outOfBoundsDouble(field: "AudioExportConfiguration.truePeakCeilingDBTP", value: truePeakCeilingDBTP, rangeDescription: "-12.0...0.0")
        }
        self.exportMode = exportMode
        self.scope = scope
        self.outputFormat = outputFormat
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrateKbps = bitrateKbps
        self.channelCount = channelCount
        self.preserveMetadata = preserveMetadata
        self.loudnessNormalizeEnabled = loudnessNormalizeEnabled
        self.targetLUFS = targetLUFS
        self.truePeakCeilingDBTP = truePeakCeilingDBTP
        self.ditheringPolicy = ditheringPolicy
        self.validateOutput = validateOutput
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            exportMode: try c.decode(AudioExportMode.self, forKey: .exportMode),
            scope: try c.decode(AudioExportScope.self, forKey: .scope),
            outputFormat: try c.decode(FileFormat.self, forKey: .outputFormat),
            sampleRate: try c.decode(SampleRate.self, forKey: .sampleRate),
            bitDepth: try c.decode(AudioExportBitDepth.self, forKey: .bitDepth),
            bitrateKbps: try c.decode(Int.self, forKey: .bitrateKbps),
            channelCount: try c.decode(Int.self, forKey: .channelCount),
            preserveMetadata: try c.decode(Bool.self, forKey: .preserveMetadata),
            loudnessNormalizeEnabled: try c.decode(Bool.self, forKey: .loudnessNormalizeEnabled),
            targetLUFS: try c.decode(Double.self, forKey: .targetLUFS),
            truePeakCeilingDBTP: try c.decode(Double.self, forKey: .truePeakCeilingDBTP),
            ditheringPolicy: try c.decode(AudioExportDitheringPolicy.self, forKey: .ditheringPolicy),
            validateOutput: try c.decode(Bool.self, forKey: .validateOutput)
        )
    }
}

struct AudioRecoveryState: Codable, Hashable, Equatable, Sendable {
    let projectID: UUID
    let savedAt: Date
    let projectFileURLPath: String?
    let sourceSchemaVersion: Int
    let projectName: String
    let uncommittedUndoJournalID: UUID?

    init(
        projectID: UUID,
        savedAt: Date,
        projectFileURLPath: String? = nil,
        sourceSchemaVersion: Int,
        projectName: String,
        uncommittedUndoJournalID: UUID? = nil
    ) throws {
        guard sourceSchemaVersion >= 1 else {
            throw AudioDomainValidationError.invalidSchemaVersion(sourceSchemaVersion)
        }
        self.projectID = projectID
        self.savedAt = savedAt
        self.projectFileURLPath = projectFileURLPath
        self.sourceSchemaVersion = sourceSchemaVersion
        self.projectName = projectName
        self.uncommittedUndoJournalID = uncommittedUndoJournalID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: try c.decode(UUID.self, forKey: .projectID),
            savedAt: try c.decode(Date.self, forKey: .savedAt),
            projectFileURLPath: try c.decodeIfPresent(String.self, forKey: .projectFileURLPath),
            sourceSchemaVersion: try c.decode(Int.self, forKey: .sourceSchemaVersion),
            projectName: try c.decode(String.self, forKey: .projectName),
            uncommittedUndoJournalID: try c.decodeIfPresent(UUID.self, forKey: .uncommittedUndoJournalID)
        )
    }
}
