import Foundation

// MARK: - Duplicate Detection Models

enum AudioDuplicateMatchKind: String, Codable, Hashable, Sendable {
    case exactBinary
    case normalizedMetadata

    var badgeTitle: String {
        switch self {
        case .exactBinary: return "Exact Binary Match"
        case .normalizedMetadata: return "Metadata Match (±1s)"
        }
    }

    var systemImage: String {
        switch self {
        case .exactBinary: return "equal.square.fill"
        case .normalizedMetadata: return "tag.fill"
        }
    }
}

struct AudioDuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let kind: AudioDuplicateMatchKind
    let matchKey: String
    let records: [AudioLibraryRecord]
    let totalBytes: Int64
    let potentialReclaimableBytes: Int64
}

struct AudioDuplicateReport: Equatable, Sendable {
    let exactBinaryGroups: [AudioDuplicateGroup]
    let normalizedMetadataGroups: [AudioDuplicateGroup]

    static let empty = AudioDuplicateReport(exactBinaryGroups: [], normalizedMetadataGroups: [])

    var totalGroupCount: Int {
        exactBinaryGroups.count + normalizedMetadataGroups.count
    }

    var allGroups: [AudioDuplicateGroup] {
        exactBinaryGroups + normalizedMetadataGroups
    }
}

// MARK: - DuplicateDetector

actor DuplicateDetector {
    static let durationToleranceSeconds: Double = 1.0

    init() {}

    /// Detects both exact binary duplicates (file size + SHA-256) and normalized metadata duplicates
    /// (diacritic/whitespace-normalized Title + Artist with ±1.0s duration tolerance).
    func detectDuplicates(
        in records: [AudioLibraryRecord],
        database: AudioLibraryDatabase? = nil
    ) async -> AudioDuplicateReport {
        let activeRecords = records.filter { $0.asset.status != .missing }
        guard activeRecords.count >= 2 else { return .empty }

        // 1. Exact binary duplicates (size -> partial hash -> full content SHA-256)
        var sizeBuckets: [Int64: [AudioLibraryRecord]] = [:]
        for record in activeRecords {
            sizeBuckets[record.asset.fileSizeBytes, default: []].append(record)
        }

        var fullHashByAssetID: [UUID: String] = [:]
        for (_, bucket) in sizeBuckets where bucket.count >= 2 {
            try? Task.checkCancellation()

            // First group by partial hash to avoid computing full SHA-256 when headers already differ.
            var byPartial: [String: [AudioLibraryRecord]] = [:]
            for rec in bucket {
                let url = URL(fileURLWithPath: rec.asset.canonicalPath)
                let partial = rec.asset.partialHashSHA256 ?? MissingFileReconciler.computePartialSHA256(url: url)
                let key = partial ?? "no-partial-\(rec.asset.id.uuidString)"
                byPartial[key, default: []].append(rec)
            }

            for (_, pBucket) in byPartial where pBucket.count >= 2 {
                for rec in pBucket {
                    if let cachedFull = rec.asset.contentSHA256, !cachedFull.isEmpty {
                        fullHashByAssetID[rec.asset.id] = cachedFull
                    } else {
                        let url = URL(fileURLWithPath: rec.asset.canonicalPath)
                        if let computed = try? MissingFileReconciler.computeFullContentSHA256(url: url) {
                            fullHashByAssetID[rec.asset.id] = computed
                            if let database {
                                let partial = rec.asset.partialHashSHA256 ?? MissingFileReconciler.computePartialSHA256(url: url)
                                try? await database.updateAssetHashes(
                                    id: rec.asset.id,
                                    partialHashSHA256: partial,
                                    contentSHA256: computed
                                )
                            }
                        }
                    }
                }
            }
        }

        var exactMap: [String: [AudioLibraryRecord]] = [:]
        for rec in activeRecords {
            guard let fullHash = fullHashByAssetID[rec.asset.id] else { continue }
            let key = "\(rec.asset.fileSizeBytes)::\(fullHash)"
            exactMap[key, default: []].append(rec)
        }

        var exactGroups: [AudioDuplicateGroup] = []
        var exactGroupSets: [Set<UUID>] = []
        for (key, groupRecords) in exactMap where groupRecords.count >= 2 {
            let sorted = Self.sortGroupRecords(groupRecords)
            let total = sorted.reduce(Int64(0)) { $0 + $1.asset.fileSizeBytes }
            let keepSize = sorted.first?.asset.fileSizeBytes ?? 0
            exactGroups.append(AudioDuplicateGroup(
                id: "exact::\(key)",
                kind: .exactBinary,
                matchKey: key,
                records: sorted,
                totalBytes: total,
                potentialReclaimableBytes: max(0, total - keepSize)
            ))
            exactGroupSets.append(Set(sorted.map(\.asset.id)))
        }
        exactGroups.sort { $0.potentialReclaimableBytes > $1.potentialReclaimableBytes }

        // 2. Normalized metadata duplicates (title + artist + ±1.0s duration tolerance)
        var metadataBuckets: [String: [AudioLibraryRecord]] = [:]
        for rec in activeRecords {
            guard let normTitle = Self.normalizeMetadataToken(rec.metadata.title),
                  let normArtist = Self.normalizeMetadataToken(rec.metadata.artist) else {
                continue
            }
            let key = "\(normArtist)||\(normTitle)"
            metadataBuckets[key, default: []].append(rec)
        }

        var metadataGroups: [AudioDuplicateGroup] = []
        for (key, candidates) in metadataBuckets where candidates.count >= 2 {
            let clusters = Self.clusterByDurationTolerance(
                candidates,
                tolerance: Self.durationToleranceSeconds
            )
            for (clusterIndex, cluster) in clusters.enumerated() where cluster.count >= 2 {
                let clusterIDs = Set(cluster.map(\.asset.id))
                // Skip if the entire cluster is already represented as a single exact binary group.
                if exactGroupSets.contains(where: { clusterIDs.isSubset(of: $0) }) {
                    continue
                }
                let sorted = Self.sortGroupRecords(cluster)
                let total = sorted.reduce(Int64(0)) { $0 + $1.asset.fileSizeBytes }
                let keepSize = sorted.first?.asset.fileSizeBytes ?? 0
                metadataGroups.append(AudioDuplicateGroup(
                    id: "meta::\(key)::\(clusterIndex)",
                    kind: .normalizedMetadata,
                    matchKey: key,
                    records: sorted,
                    totalBytes: total,
                    potentialReclaimableBytes: max(0, total - keepSize)
                ))
            }
        }
        metadataGroups.sort { lhs, rhs in
            if lhs.records.count != rhs.records.count {
                return lhs.records.count > rhs.records.count
            }
            return lhs.id < rhs.id
        }

        return AudioDuplicateReport(
            exactBinaryGroups: exactGroups,
            normalizedMetadataGroups: metadataGroups
        )
    }

    static func normalizeMetadataToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let folded = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty else { return nil }
        let parts = folded.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let collapsed = parts.joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func clusterByDurationTolerance(
        _ records: [AudioLibraryRecord],
        tolerance: Double
    ) -> [[AudioLibraryRecord]] {
        let sortedByDuration = records.sorted { $0.asset.durationSeconds < $1.asset.durationSeconds }
        var clusters: [[AudioLibraryRecord]] = []
        var current: [AudioLibraryRecord] = []

        for item in sortedByDuration {
            if let anchor = current.first {
                if abs(item.asset.durationSeconds - anchor.asset.durationSeconds) <= tolerance {
                    current.append(item)
                } else {
                    if current.count >= 2 {
                        clusters.append(current)
                    }
                    current = [item]
                }
            } else {
                current = [item]
            }
        }
        if current.count >= 2 {
            clusters.append(current)
        }
        return clusters
    }

    private static func sortGroupRecords(_ records: [AudioLibraryRecord]) -> [AudioLibraryRecord] {
        records.sorted { lhs, rhs in
            if lhs.asset.isLosslessCodec != rhs.asset.isLosslessCodec {
                return lhs.asset.isLosslessCodec && !rhs.asset.isLosslessCodec
            }
            if lhs.asset.sampleRate.hz != rhs.asset.sampleRate.hz {
                return lhs.asset.sampleRate.hz > rhs.asset.sampleRate.hz
            }
            if lhs.asset.dateAdded != rhs.asset.dateAdded {
                return lhs.asset.dateAdded < rhs.asset.dateAdded
            }
            return lhs.asset.canonicalPath.localizedStandardCompare(rhs.asset.canonicalPath) == .orderedAscending
        }
    }
}
