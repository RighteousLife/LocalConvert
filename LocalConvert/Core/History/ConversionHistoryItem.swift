import Foundation

enum HistoryStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

/// Truthful execution provenance for a conversion job or persistent history record.
enum ConversionSource: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case manual
    case watchFolder
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ConversionSource(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .watchFolder: return "Watch Folder"
        case .unknown: return "Not Recorded"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .manual: return "Source: Manual conversion"
        case .watchFolder: return "Source: Watch Folder automation"
        case .unknown: return "Source: Not recorded (legacy history record)"
        }
    }

    var iconName: String {
        switch self {
        case .manual: return "hand.tap"
        case .watchFolder: return "folder.badge.gearshape"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum HistoryCategoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case conversions = "Conversions"
    case pdfTools = "PDF Tools"
    case presets = "Presets"
    case failed = "Failed"

    var id: String { rawValue }
}

enum HistorySourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Sources"
    case manual = "Manual"
    case watchFolder = "Watch Folder"
    case unknown = "Not Recorded"

    var id: String { rawValue }

    func matches(_ source: ConversionSource) -> Bool {
        switch self {
        case .all: return true
        case .manual: return source == .manual
        case .watchFolder: return source == .watchFolder
        case .unknown: return source == .unknown
        }
    }
}

enum HistoryFilterEngine: Sendable {
    static func filter(
        items: [ConversionHistoryItem],
        category: HistoryCategoryFilter = .all,
        source: HistorySourceFilter = .all,
        watchFolderRuleID: UUID? = nil,
        searchText: String = ""
    ) -> [ConversionHistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return items.filter { item in
            let matchesCategory: Bool
            switch category {
            case .all:
                matchesCategory = true
            case .conversions:
                matchesCategory = item.presetName == nil
                    && !(item.inputFormatName.lowercased() == "pdf" && item.outputFormatName.lowercased() == "pdf")
            case .pdfTools:
                matchesCategory = (item.inputFormatName.lowercased() == "pdf" && item.outputFormatName.lowercased() == "pdf")
                    || (item.presetName?.lowercased().contains("pdf") ?? false)
            case .presets:
                matchesCategory = item.presetName != nil
            case .failed:
                matchesCategory = item.status == .failed || item.status == .cancelled
            }
            guard matchesCategory else { return false }
            guard source.matches(item.source) else { return false }

            if let watchFolderRuleID {
                guard item.source == .watchFolder && item.watchFolderRuleID == watchFolderRuleID else {
                    return false
                }
            }

            if query.isEmpty { return true }

            return item.inputFilename.localizedCaseInsensitiveContains(query)
                || item.outputFilename.localizedCaseInsensitiveContains(query)
                || item.inputFormatName.localizedCaseInsensitiveContains(query)
                || item.outputFormatName.localizedCaseInsensitiveContains(query)
                || (item.presetName?.localizedCaseInsensitiveContains(query) ?? false)
                || item.source.displayName.localizedCaseInsensitiveContains(query)
                || (item.watchFolderRuleName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

struct ConversionHistoryItem: Identifiable, Codable, Sendable {
    let id: UUID
    let inputFilename: String
    let inputFormatName: String
    let outputFilename: String
    let outputFormatName: String
    let date: Date
    let status: HistoryStatus
    let inputSizeBytes: Int64?
    let outputSizeBytes: Int64?
    let presetName: String?
    let outputURLPath: String? // Store path as string to easily reveal, ignore if missing
    let additionalOutputURLPaths: [String]?
    let inputURLPath: String?
    let duration: TimeInterval?
    let errorMessage: String?
    let source: ConversionSource
    let watchFolderRuleID: UUID?
    let watchFolderRuleName: String?
    
    var outputURL: URL? {
        guard let path = outputURLPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var additionalOutputURLs: [URL] {
        (additionalOutputURLPaths ?? []).map { URL(fileURLWithPath: $0) }
    }

    var allOutputURLs: [URL] {
        (outputURL.map { [$0] } ?? []) + additionalOutputURLs
    }
    
    var inputURL: URL? {
        guard let path = inputURLPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var sourceDisplayLabel: String {
        if source == .watchFolder, let ruleName = watchFolderRuleName, !ruleName.isEmpty {
            return "Watch Folder · \(ruleName)"
        }
        return source.displayName
    }
    
    init(
        id: UUID = UUID(),
        inputFilename: String,
        inputFormatName: String,
        outputFilename: String,
        outputFormatName: String,
        date: Date = Date(),
        status: HistoryStatus,
        inputSizeBytes: Int64? = nil,
        outputSizeBytes: Int64? = nil,
        presetName: String? = nil,
        outputURLPath: String? = nil,
        inputURLPath: String? = nil,
        duration: TimeInterval? = nil,
        errorMessage: String? = nil,
        source: ConversionSource = .unknown,
        watchFolderRuleID: UUID? = nil,
        watchFolderRuleName: String? = nil,
        additionalOutputURLPaths: [String]? = nil
    ) {
        self.id = id
        self.inputFilename = inputFilename
        self.inputFormatName = inputFormatName
        self.outputFilename = outputFilename
        self.outputFormatName = outputFormatName
        self.date = date
        self.status = status
        self.inputSizeBytes = inputSizeBytes
        self.outputSizeBytes = outputSizeBytes
        self.presetName = presetName
        self.outputURLPath = outputURLPath
        self.additionalOutputURLPaths = additionalOutputURLPaths
        self.inputURLPath = inputURLPath
        self.duration = duration
        self.errorMessage = errorMessage
        self.source = source
        self.watchFolderRuleID = watchFolderRuleID
        self.watchFolderRuleName = watchFolderRuleName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case inputFilename
        case inputFormatName
        case outputFilename
        case outputFormatName
        case date
        case status
        case inputSizeBytes
        case outputSizeBytes
        case presetName
        case outputURLPath
        case additionalOutputURLPaths
        case inputURLPath
        case duration
        case errorMessage
        case source
        case watchFolderRuleID
        case watchFolderRuleName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.inputFilename = try c.decode(String.self, forKey: .inputFilename)
        self.inputFormatName = try c.decode(String.self, forKey: .inputFormatName)
        self.outputFilename = try c.decode(String.self, forKey: .outputFilename)
        self.outputFormatName = try c.decode(String.self, forKey: .outputFormatName)
        self.date = try c.decode(Date.self, forKey: .date)
        self.status = try c.decode(HistoryStatus.self, forKey: .status)
        self.inputSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .inputSizeBytes)
        self.outputSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .outputSizeBytes)
        self.presetName = try c.decodeIfPresent(String.self, forKey: .presetName)
        self.outputURLPath = try c.decodeIfPresent(String.self, forKey: .outputURLPath)
        self.additionalOutputURLPaths = try c.decodeIfPresent([String].self, forKey: .additionalOutputURLPaths)
        self.inputURLPath = try c.decodeIfPresent(String.self, forKey: .inputURLPath)
        self.duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        // Legacy records written before source tracking decode deterministically as `.unknown` without fabrication.
        self.source = try c.decodeIfPresent(ConversionSource.self, forKey: .source) ?? .unknown
        self.watchFolderRuleID = try c.decodeIfPresent(UUID.self, forKey: .watchFolderRuleID)
        self.watchFolderRuleName = try c.decodeIfPresent(String.self, forKey: .watchFolderRuleName)
    }
}
