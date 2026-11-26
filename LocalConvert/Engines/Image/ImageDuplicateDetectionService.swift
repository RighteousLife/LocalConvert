import Foundation
import CryptoKit
import CoreGraphics

// MARK: - Duplicate Image Detection Service (Exact SHA-256 + Perceptual dHash)

enum ImageDuplicateMatchKind: String, Sendable {
    case exactHash = "Exact Byte Duplicate (SHA-256)"
    case perceptualSimilar = "Visually Similar (Perceptual dHash)"
}

struct ImageDuplicateItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let url: URL
    let filename: String
    let fileSizeBytes: Int64
    let width: Int
    let height: Int
    let sha256: String
    let dHash: UInt64?
    let hammingDistanceFromAnchor: Int
}

struct ImageDuplicateGroup: Identifiable, Sendable, Equatable {
    let id: UUID
    let matchKind: ImageDuplicateMatchKind
    let similarityPercent: Double
    let items: [ImageDuplicateItem]
}

struct ImageDuplicateScanResult: Sendable {
    let exactGroups: [ImageDuplicateGroup]
    let similarGroups: [ImageDuplicateGroup]
    let scannedCount: Int
    let unhashableCount: Int
}

enum ImageDuplicateDetectionService {

    /// Scans URLs for exact byte duplicates (SHA-256) and perceptual similarity (64-bit dHash).
    /// `similarityThresholdPercent` (50...100): e.g. 90% permits up to 6 differing bits out of 64.
    static func scan(
        urls: [URL],
        similarityThresholdPercent: Double = 90.0,
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> ImageDuplicateScanResult {
        guard !urls.isEmpty else {
            return ImageDuplicateScanResult(exactGroups: [], similarGroups: [], scannedCount: 0, unhashableCount: 0)
        }

        let clampedSim = max(50.0, min(100.0, similarityThresholdPercent))
        let maxHamming = Int(((100.0 - clampedSim) / 100.0 * 64.0).rounded())

        struct IndexedEntry {
            let url: URL
            let filename: String
            let fileSizeBytes: Int64
            let width: Int
            let height: Int
            let sha256: String
            let dHash: UInt64?
        }

        var entries: [IndexedEntry] = []
        entries.reserveCapacity(urls.count)
        var unhashable = 0

        for (idx, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress(Double(idx) / Double(max(1, urls.count)) * 0.85, "Hashing \(url.lastPathComponent)...")

            guard let sha = try? computeStreamingSHA256(url: url) else {
                unhashable += 1
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let dims = ImageProcessingService.inspectSourceDimensions(url: url)
            let dHash = try? await computePerceptualDHash(url: url)
            let resolvedW = dims?.width ?? 0
            let resolvedH = dims?.height ?? 0

            entries.append(IndexedEntry(
                url: url,
                filename: url.lastPathComponent,
                fileSizeBytes: size,
                width: resolvedW,
                height: resolvedH,
                sha256: sha,
                dHash: dHash
            ))
        }

        try Task.checkCancellation()
        progress(0.9, "Clustering exact and visually similar images...")

        // 1. Group Exact SHA-256 Duplicates
        var bySHA: [String: [IndexedEntry]] = [:]
        for entry in entries {
            bySHA[entry.sha256, default: []].append(entry)
        }

        var exactGroups: [ImageDuplicateGroup] = []
        var exactConsumedPaths: Set<String> = []
        for (_, group) in bySHA where group.count > 1 {
            let items = group.map { e in
                exactConsumedPaths.insert(e.url.path)
                return ImageDuplicateItem(
                    id: UUID(),
                    url: e.url,
                    filename: e.filename,
                    fileSizeBytes: e.fileSizeBytes,
                    width: e.width,
                    height: e.height,
                    sha256: e.sha256,
                    dHash: e.dHash,
                    hammingDistanceFromAnchor: 0
                )
            }
            exactGroups.append(ImageDuplicateGroup(
                id: UUID(),
                matchKind: .exactHash,
                similarityPercent: 100.0,
                items: items
            ))
        }

        // Keep one representative from each exact group for perceptual comparison across non-identical files
        var perceptualPool: [IndexedEntry] = []
        var seenExactSHA: Set<String> = []
        for entry in entries {
            if exactConsumedPaths.contains(entry.url.path) {
                if !seenExactSHA.contains(entry.sha256) {
                    seenExactSHA.insert(entry.sha256)
                    perceptualPool.append(entry)
                }
            } else {
                perceptualPool.append(entry)
            }
        }

        // 2. Perceptual dHash clustering on remaining unique-byte images
        var visited = [Bool](repeating: false, count: perceptualPool.count)
        var similarGroups: [ImageDuplicateGroup] = []

        for i in 0..<perceptualPool.count {
            try Task.checkCancellation()
            guard !visited[i], let anchorHash = perceptualPool[i].dHash else { continue }
            visited[i] = true

            var cluster: [(entry: IndexedEntry, dist: Int)] = [(perceptualPool[i], 0)]
            for j in (i + 1)..<perceptualPool.count {
                guard !visited[j], let otherHash = perceptualPool[j].dHash else { continue }
                let dist = hammingDistance(anchorHash, otherHash)
                if dist <= maxHamming {
                    visited[j] = true
                    cluster.append((perceptualPool[j], dist))
                }
            }

            if cluster.count > 1 {
                let maxDist = cluster.map(\.dist).max() ?? 0
                let simPct = max(0.0, 100.0 - (Double(maxDist) / 64.0) * 100.0)
                let items = cluster.map { pair in
                    ImageDuplicateItem(
                        id: UUID(),
                        url: pair.entry.url,
                        filename: pair.entry.filename,
                        fileSizeBytes: pair.entry.fileSizeBytes,
                        width: pair.entry.width,
                        height: pair.entry.height,
                        sha256: pair.entry.sha256,
                        dHash: pair.entry.dHash,
                        hammingDistanceFromAnchor: pair.dist
                    )
                }
                similarGroups.append(ImageDuplicateGroup(
                    id: UUID(),
                    matchKind: .perceptualSimilar,
                    similarityPercent: simPct,
                    items: items
                ))
            }
        }

        progress(1.0, "Duplicate scan complete")
        return ImageDuplicateScanResult(
            exactGroups: exactGroups,
            similarGroups: similarGroups,
            scannedCount: entries.count,
            unhashableCount: unhashable
        )
    }

    /// Computes streaming SHA-256 using bounded 256 KB chunks so huge image collections stay memory-safe.
    static func computeStreamingSHA256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 256 * 1024)
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes a 64-bit difference hash (dHash) over a 9×8 grayscale downsample.
    static func computePerceptualDHash(cgImage: CGImage) -> UInt64? {
        let w = 9
        let h = 8
        var gray = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = gray.withUnsafeMutableBytes { ptr in
            guard let cs = CGColorSpace(name: CGColorSpace.linearGray),
                  let ctx = CGContext(
                    data: ptr.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                let left = gray[y * w + x]
                let right = gray[y * w + x + 1]
                if left > right {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }
        return hash
    }

    static func computePerceptualDHash(url: URL) async throws -> UInt64? {
        let decoded = try await ImageProcessingService.decodeInputImage(url: url, maxPixelDimension: 128)
        return computePerceptualDHash(cgImage: decoded.cgImage)
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
