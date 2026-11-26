import Foundation
import CoreGraphics
import ImageIO

// MARK: - Immutable Property Snapshot Container

struct SendableImageProperties: @unchecked Sendable {
    let raw: [String: Any]
}

// MARK: - Bounded LRU Proxy & Vision Mask Cache (~64 MB Budget)

actor ImagePreviewProxyCache {
    static let shared = ImagePreviewProxyCache(maxMemoryBytes: 64 * 1024 * 1024)

    let maxMemoryBytes: Int

    struct ProxyKey: Hashable, Sendable {
        let path: String
        let fileSize: Int64
        let mtimeInterval: TimeInterval
        let maxPixelDimension: Int
        let rawSignature: String?
    }

    struct MaskKey: Hashable, Sendable {
        let path: String
        let fileSize: Int64
        let mtimeInterval: TimeInterval
        let maxPixelDimension: Int
        let geometrySignature: String
    }

    struct CachedProxy: Sendable {
        let cgImage: CGImage
        let properties: SendableImageProperties?
        let format: FileFormat?
        let fileSizeBytes: Int64
        let fullWidth: Int
        let fullHeight: Int
        let isRAWFallbackUsed: Bool
        let rawStatusNote: String?
        let byteCost: Int
    }

    private struct EntryBox {
        let key: AnyHashable
        let cost: Int
        let value: Any
    }

    private var proxyEntries: [ProxyKey: CachedProxy] = [:]
    private var maskEntries: [MaskKey: (cgImage: CGImage, cost: Int)] = [:]
    private var lruOrder: [AnyHashable] = []
    private(set) var currentMemoryBytes: Int = 0

    init(maxMemoryBytes: Int = 64 * 1024 * 1024) {
        self.maxMemoryBytes = max(1 * 1024 * 1024, maxMemoryBytes)
    }

    static func fileIdentity(for url: URL) -> (path: String, fileSize: Int64, mtime: TimeInterval) {
        let stdPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: stdPath)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (stdPath, size, mtime)
    }

    static func estimateByteCost(of cgImage: CGImage) -> Int {
        max(4096, cgImage.bytesPerRow * cgImage.height)
    }

    func proxy(for key: ProxyKey) -> CachedProxy? {
        guard let item = proxyEntries[key] else { return nil }
        touchLRU(AnyHashable(key))
        return item
    }

    func storeProxy(_ value: CachedProxy, for key: ProxyKey) {
        let staleKeys = proxyEntries.keys.filter {
            $0.path == key.path && ($0.fileSize != key.fileSize || $0.mtimeInterval != key.mtimeInterval)
        }
        for stale in staleKeys { removeEntry(forHashKey: AnyHashable(stale)) }
        let hashKey = AnyHashable(key)
        removeEntry(forHashKey: hashKey)
        guard value.byteCost <= maxMemoryBytes else { return }
        proxyEntries[key] = value
        lruOrder.append(hashKey)
        currentMemoryBytes += value.byteCost
        evictIfNeeded()
    }

    func mask(for key: MaskKey) -> CGImage? {
        guard let item = maskEntries[key] else { return nil }
        touchLRU(AnyHashable(key))
        return item.cgImage
    }

    func storeMask(_ maskCG: CGImage, for key: MaskKey) {
        let staleKeys = maskEntries.keys.filter {
            $0.path == key.path && ($0.fileSize != key.fileSize || $0.mtimeInterval != key.mtimeInterval)
        }
        for stale in staleKeys { removeEntry(forHashKey: AnyHashable(stale)) }
        let cost = Self.estimateByteCost(of: maskCG)
        let hashKey = AnyHashable(key)
        removeEntry(forHashKey: hashKey)
        guard cost <= maxMemoryBytes else { return }
        maskEntries[key] = (maskCG, cost)
        lruOrder.append(hashKey)
        currentMemoryBytes += cost
        evictIfNeeded()
    }

    func invalidate(url: URL) {
        let stdPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let matchingProxies = proxyEntries.keys.filter { $0.path == stdPath }
        for k in matchingProxies { removeEntry(forHashKey: AnyHashable(k)) }
        let matchingMasks = maskEntries.keys.filter { $0.path == stdPath }
        for k in matchingMasks { removeEntry(forHashKey: AnyHashable(k)) }
    }

    func clear() {
        proxyEntries.removeAll()
        maskEntries.removeAll()
        lruOrder.removeAll()
        currentMemoryBytes = 0
    }

    func stats() -> (proxyCount: Int, maskCount: Int, bytesUsed: Int, budgetBytes: Int) {
        (proxyEntries.count, maskEntries.count, currentMemoryBytes, maxMemoryBytes)
    }

    private func touchLRU(_ hashKey: AnyHashable) {
        if let idx = lruOrder.firstIndex(of: hashKey) {
            lruOrder.remove(at: idx)
            lruOrder.append(hashKey)
        }
    }

    private func removeEntry(forHashKey hashKey: AnyHashable) {
        if let pk = hashKey.base as? ProxyKey, let existing = proxyEntries.removeValue(forKey: pk) {
            currentMemoryBytes = max(0, currentMemoryBytes - existing.byteCost)
        } else if let mk = hashKey.base as? MaskKey, let existing = maskEntries.removeValue(forKey: mk) {
            currentMemoryBytes = max(0, currentMemoryBytes - existing.cost)
        }
        if let idx = lruOrder.firstIndex(of: hashKey) {
            lruOrder.remove(at: idx)
        }
    }

    private func evictIfNeeded() {
        while currentMemoryBytes > maxMemoryBytes, !lruOrder.isEmpty {
            let oldest = lruOrder.removeFirst()
            if let pk = oldest as? ProxyKey, let removed = proxyEntries.removeValue(forKey: pk) {
                currentMemoryBytes = max(0, currentMemoryBytes - removed.byteCost)
            } else if let mk = oldest as? MaskKey, let removed = maskEntries.removeValue(forKey: mk) {
                currentMemoryBytes = max(0, currentMemoryBytes - removed.cost)
            }
        }
    }
}
