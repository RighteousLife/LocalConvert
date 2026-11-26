import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Validates, downscales, content-hashes, and caches embedded audio cover artwork off the MainActor.
/// Uses `ImageIO` exclusively in actor isolation so UI-bound `NSImage` objects never cross actor boundaries.
actor AudioArtworkProvider {
    static let maxInputByteCount = 15 * 1024 * 1024
    static let maxThumbnailDimensionPixels = 512

    private let customCacheDirectory: URL?
    private let memoryByteLimit: Int
    private var memoryDataCache: [String: Data] = [:]
    private var memoryAccessOrder: [String] = []
    private var currentMemoryBytes = 0

    init(cacheDirectory: URL? = nil, memoryByteLimit: Int = 16 * 1024 * 1024) {
        self.customCacheDirectory = cacheDirectory
        self.memoryByteLimit = max(512 * 1024, memoryByteLimit)
    }

    var cacheDirectoryURL: URL {
        customCacheDirectory ?? AppStoragePaths.audioArtworkCacheDirectory
    }

    /// Validates raw image bytes, normalizes/downscales oversized covers, stores deduplicated bytes
    /// on disk under `cacheDirectoryURL`, and returns a stable content-addressed key (or `nil` if invalid).
    func storeArtwork(data rawData: Data) -> String? {
        guard let normalizedData = Self.normalizeArtworkData(rawData) else {
            return nil
        }

        let digest = SHA256.hash(data: normalizedData)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        let key = "art-\(hex.prefix(32))"

        let fileURL = cachedFileURL(forKey: key)
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            do {
                try fm.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
                let tmpURL = cacheDirectoryURL.appendingPathComponent(".\(key)-\(UUID().uuidString).tmp")
                try normalizedData.write(to: tmpURL, options: .atomic)
                if fm.fileExists(atPath: fileURL.path) {
                    try? fm.removeItem(at: tmpURL)
                } else {
                    try fm.moveItem(at: tmpURL, to: fileURL)
                }
            } catch {
                return nil
            }
        }

        cacheInMemory(key: key, data: normalizedData)
        return key
    }

    func artworkData(forKey key: String) -> Data? {
        guard Self.isValidCacheKey(key) else { return nil }
        if let cached = memoryDataCache[key] {
            touchLRU(key: key)
            return cached
        }

        let url = cachedFileURL(forKey: key)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        cacheInMemory(key: key, data: data)
        return data
    }

    func cachedFileURL(forKey key: String) -> URL {
        let sanitized = key.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        let safeKey = sanitized.isEmpty ? "invalid" : sanitized
        return cacheDirectoryURL.appendingPathComponent("\(safeKey).jpg", isDirectory: false)
    }

    func clearMemoryCache() {
        memoryDataCache.removeAll()
        memoryAccessOrder.removeAll()
        currentMemoryBytes = 0
    }

    // MARK: - Private Normalization & Bounded LRU

    nonisolated static func normalizeArtworkData(_ rawData: Data) -> Data? {
        guard !rawData.isEmpty, rawData.count <= maxInputByteCount else {
            return nil
        }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(rawData as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }

        // Preserve compact native JPEG/PNG when already within 512px bounds; otherwise thumbnail cleanly.
        let isPNG = rawData.count >= 8 && rawData.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let isJPEG = rawData.count >= 3 && rawData.prefix(3) == Data([0xFF, 0xD8, 0xFF])
        if (isPNG || isJPEG) && pixelWidth <= maxThumbnailDimensionPixels && pixelHeight <= maxThumbnailDimensionPixels {
            return rawData
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxThumbnailDimensionPixels,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ]
        CGImageDestinationAddImage(destination, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination), mutableData.length > 0 else {
            return nil
        }
        return mutableData as Data
    }

    private static func isValidCacheKey(_ key: String) -> Bool {
        !key.isEmpty && !key.contains("/") && !key.contains("..")
    }

    private func cacheInMemory(key: String, data: Data) {
        if let existing = memoryDataCache[key] {
            currentMemoryBytes -= existing.count
        }
        memoryDataCache[key] = data
        currentMemoryBytes += data.count
        touchLRU(key: key)

        while currentMemoryBytes > memoryByteLimit, let oldest = memoryAccessOrder.first {
            memoryAccessOrder.removeFirst()
            if let removed = memoryDataCache.removeValue(forKey: oldest) {
                currentMemoryBytes = max(0, currentMemoryBytes - removed.count)
            }
        }
    }

    private func touchLRU(key: String) {
        if let idx = memoryAccessOrder.firstIndex(of: key) {
            memoryAccessOrder.remove(at: idx)
        }
        memoryAccessOrder.append(key)
    }
}

/// MainActor UI helper cache decoding cached artwork bytes into bounded `NSImage` instances.
@MainActor
final class AudioArtworkImageCache {
    static let shared = AudioArtworkImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 96
        c.totalCostLimit = 32 * 1024 * 1024
        return c
    }()

    func image(forKey key: String, provider: AudioArtworkProvider) async -> NSImage? {
        let nsKey = key as NSString
        if let hit = cache.object(forKey: nsKey) {
            return hit
        }
        guard let data = await provider.artworkData(forKey: key),
              let image = NSImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: nsKey, cost: data.count)
        return image
    }

    func invalidateAll() {
        cache.removeAllObjects()
    }
}
