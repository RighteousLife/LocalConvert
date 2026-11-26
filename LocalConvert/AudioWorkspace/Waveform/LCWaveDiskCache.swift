import Foundation
import CryptoKit
import zlib

// MARK: - Binary .lcwave Disk Cache

/// Persistent, bounded-LRU little-endian `.lcwave` binary disk cache for `WaveformPyramid`.
actor LCWaveDiskCache {
    static let fileExtension = "lcwave"
    static let defaultMaxBytes: Int64 = 512 * 1024 * 1024

    private static let magicBytes: [UInt8] = Array("LCWAVE01".utf8)
    private static let formatVersionV1: UInt32 = 1
    private static let formatVersion: UInt32 = 2
    // v1: 8 magic + 4 ver + 4 rate + 4 ch + 8 totalFrames + 4 levels + 4 flags + 32 sha256
    private static let headerSizeV1 = 68
    // v2: 8 magic + 4 ver + 4 rate + 4 ch + 8 totalFrames + 4 levels + 4 flags + 4 payloadCRC32 + 4 headerCRC32
    private static let headerSizeV2 = 44
    private static let madviseThresholdBytes = 1_048_576
    private static let maxSupportedChannels: UInt32 = 64
    private static let maxSupportedLevels: UInt32 = 16

    let directory: URL
    let maxBytes: Int64

    init(
        directory: URL = AppStoragePaths.audioWaveformCacheDirectory,
        maxBytes: Int64 = LCWaveDiskCache.defaultMaxBytes
    ) {
        self.directory = directory
        self.maxBytes = max(0, maxBytes)
    }

    nonisolated static func cacheKey(
        canonicalPath: String,
        fileSize: Int64,
        modificationTime: TimeInterval,
        channelCount: Int
    ) -> String {
        let safeMtime = modificationTime.isFinite ? modificationTime : 0
        let mtimeMillis = Int64((safeMtime * 1000.0).rounded())
        let raw = "\(canonicalPath)|\(fileSize)|\(mtimeMillis)|\(max(1, channelCount))|v1"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func fileURL(forKey cacheKey: String) -> URL {
        let safeName = Self.sanitizedKey(cacheKey)
        return directory.appendingPathComponent("\(safeName).\(Self.fileExtension)", isDirectory: false)
    }

    func load(cacheKey: String, assetID: UUID? = nil) -> WaveformPyramid? {
        let targetURL = fileURL(forKey: cacheKey)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: targetURL, options: [.mappedIfSafe])
            guard let pyramid = Self.decodeBinary(data, cacheKey: cacheKey, assetID: assetID) else {
                try? FileManager.default.removeItem(at: targetURL)
                return nil
            }
            // Touch mtime for LRU tracking without mutating file contents.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: targetURL.path)
            return pyramid
        } catch {
            try? FileManager.default.removeItem(at: targetURL)
            return nil
        }
    }

    func store(_ pyramid: WaveformPyramid, forKey cacheKey: String) throws {
        guard !pyramid.isPartial else { return }
        guard pyramid.sampleRate > 0,
              pyramid.channelCount >= 1,
              pyramid.channelCount <= Int(Self.maxSupportedChannels),
              !pyramid.levels.isEmpty,
              pyramid.levels.count <= Int(Self.maxSupportedLevels) else {
            return
        }

        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let targetURL = fileURL(forKey: cacheKey)
        let encoded = Self.encodeBinary(pyramid)

        let tmpURL = directory.appendingPathComponent(".\(Self.sanitizedKey(cacheKey)).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmpURL) }

        try encoded.write(to: tmpURL, options: .atomic)
        if fm.fileExists(atPath: targetURL.path) {
            _ = try fm.replaceItemAt(targetURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: targetURL)
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: targetURL.path)

        evictIfNeeded(excludingFileName: targetURL.lastPathComponent)
    }

    func remove(cacheKey: String) {
        let targetURL = fileURL(forKey: cacheKey)
        try? FileManager.default.removeItem(at: targetURL)
    }

    func removeAll() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in entries where url.pathExtension.lowercased() == Self.fileExtension {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func currentDiskBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for url in files {
            guard !url.lastPathComponent.hasPrefix("."),
                  url.pathExtension.lowercased() == Self.fileExtension,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func evictIfNeeded(excludingFileName: String? = nil) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else {
            return
        }

        var entries: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for url in files {
            guard !url.lastPathComponent.hasPrefix("."),
                  url.pathExtension.lowercased() == Self.fileExtension,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? .distantPast
            total += size
            entries.append((url, size, mtime))
        }

        guard total > maxBytes else { return }

        entries.sort { lhs, rhs in
            if lhs.mtime != rhs.mtime {
                return lhs.mtime < rhs.mtime
            }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        for entry in entries where total > maxBytes {
            if let excludingFileName, entry.url.lastPathComponent == excludingFileName {
                continue
            }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: - Little-Endian Binary Codec

    private static func sanitizedKey(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned)
        return str.isEmpty ? "empty" : str
    }

    private static func encodeBinary(_ pyramid: WaveformPyramid) -> Data {
        var estimatedPayloadBytes = 0
        for level in pyramid.levels {
            let bucketCount = level.bucketCount
            estimatedPayloadBytes += 8 + (pyramid.channelCount * bucketCount * 16)
        }

        var fileData = Data(count: headerSizeV2 + estimatedPayloadBytes)
        fileData.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }

            magicBytes.withUnsafeBufferPointer { magicBuf in
                if let magicBase = magicBuf.baseAddress {
                    base.copyMemory(from: magicBase, byteCount: magicBuf.count)
                }
            }
            base.storeBytes(of: formatVersion.littleEndian, toByteOffset: 8, as: UInt32.self)
            base.storeBytes(of: UInt32(bitPattern: pyramid.sampleRate).littleEndian, toByteOffset: 12, as: UInt32.self)
            base.storeBytes(of: UInt32(pyramid.channelCount).littleEndian, toByteOffset: 16, as: UInt32.self)
            base.storeBytes(of: UInt64(bitPattern: pyramid.totalFrames).littleEndian, toByteOffset: 20, as: UInt64.self)
            base.storeBytes(of: UInt32(pyramid.levels.count).littleEndian, toByteOffset: 28, as: UInt32.self)
            base.storeBytes(of: UInt32(0).littleEndian, toByteOffset: 32, as: UInt32.self) // flags

            var offset = headerSizeV2
            for level in pyramid.levels {
                let bucketCount = level.bucketCount
                base.storeBytes(of: UInt32(max(1, level.framesPerBucket)).littleEndian, toByteOffset: offset, as: UInt32.self)
                base.storeBytes(of: UInt32(max(0, bucketCount)).littleEndian, toByteOffset: offset + 4, as: UInt32.self)
                offset += 8
                for chIdx in 0..<pyramid.channelCount {
                    let buckets = chIdx < level.channels.count ? level.channels[chIdx].buckets : []
                    let copyCount = min(bucketCount, buckets.count)
                    buckets.withUnsafeBufferPointer { bucketBuf in
                        for bucketIdx in 0..<copyCount {
                            let b = bucketBuf[bucketIdx]
                            base.storeBytes(of: b.minSample.bitPattern.littleEndian, toByteOffset: offset, as: UInt32.self)
                            base.storeBytes(of: b.maxSample.bitPattern.littleEndian, toByteOffset: offset + 4, as: UInt32.self)
                            base.storeBytes(of: b.rms.bitPattern.littleEndian, toByteOffset: offset + 8, as: UInt32.self)
                            base.storeBytes(of: UInt32(b.clipped ? 1 : 0).littleEndian, toByteOffset: offset + 12, as: UInt32.self)
                            offset += 16
                        }
                    }
                    if copyCount < bucketCount {
                        // Data(count:) zero-initializes memory, matching WaveformBucket.zero (0, 0, 0, false).
                        offset += (bucketCount - copyCount) * 16
                    }
                }
            }

            let payloadCRC32 = computeCRC32(base.advanced(by: headerSizeV2), count: estimatedPayloadBytes)
            base.storeBytes(of: payloadCRC32.littleEndian, toByteOffset: 36, as: UInt32.self)

            let headerCRC32 = computeCRC32(base, count: 40)
            base.storeBytes(of: headerCRC32.littleEndian, toByteOffset: 40, as: UInt32.self)
        }
        return fileData
    }

    private static func decodeBinary(_ data: Data, cacheKey: String, assetID: UUID?) -> WaveformPyramid? {
        data.withUnsafeBytes { rawBuf -> WaveformPyramid? in
            let totalCount = rawBuf.count
            guard totalCount >= 12, let basePtr = rawBuf.baseAddress else { return nil }
            guard UnsafeRawBufferPointer(start: basePtr, count: magicBytes.count).elementsEqual(magicBytes) else {
                return nil
            }

            if totalCount >= madviseThresholdBytes {
                _ = madvise(UnsafeMutableRawPointer(mutating: basePtr), totalCount, MADV_SEQUENTIAL)
            }

            let version = loadUInt32LE(basePtr, at: 8)
            let payloadStart: Int
            let sampleRate: Int32
            let channelCount: UInt32
            let totalFrames: Int64
            let levelCount: UInt32

            switch version {
            case formatVersion:
                guard totalCount >= headerSizeV2 else { return nil }
                let expectedHeaderCRC = loadUInt32LE(basePtr, at: 40)
                let actualHeaderCRC = computeCRC32(basePtr, count: 40)
                guard expectedHeaderCRC == actualHeaderCRC else { return nil }

                let flags = loadUInt32LE(basePtr, at: 32)
                guard flags == 0 else { return nil }

                sampleRate = Int32(bitPattern: loadUInt32LE(basePtr, at: 12))
                guard sampleRate > 0 && SampleRate.validRange.contains(sampleRate) else { return nil }

                channelCount = loadUInt32LE(basePtr, at: 16)
                guard channelCount >= 1 && channelCount <= maxSupportedChannels else { return nil }

                totalFrames = Int64(bitPattern: loadUInt64LE(basePtr, at: 20))
                guard totalFrames >= 0 else { return nil }

                levelCount = loadUInt32LE(basePtr, at: 28)
                guard levelCount >= 1 && levelCount <= maxSupportedLevels else { return nil }

                let expectedPayloadCRC = loadUInt32LE(basePtr, at: 36)
                let actualPayloadCRC = computeCRC32(basePtr.advanced(by: headerSizeV2), count: totalCount - headerSizeV2)
                guard expectedPayloadCRC == actualPayloadCRC else { return nil }
                payloadStart = headerSizeV2

            case formatVersionV1:
                guard totalCount >= headerSizeV1 else { return nil }

                sampleRate = Int32(bitPattern: loadUInt32LE(basePtr, at: 12))
                guard sampleRate > 0 && SampleRate.validRange.contains(sampleRate) else { return nil }

                channelCount = loadUInt32LE(basePtr, at: 16)
                guard channelCount >= 1 && channelCount <= maxSupportedChannels else { return nil }

                totalFrames = Int64(bitPattern: loadUInt64LE(basePtr, at: 20))
                guard totalFrames >= 0 else { return nil }

                levelCount = loadUInt32LE(basePtr, at: 28)
                guard levelCount >= 1 && levelCount <= maxSupportedLevels else { return nil }

                let expectedDigest = UnsafeRawBufferPointer(start: basePtr.advanced(by: 36), count: 32)
                var hasher = SHA256()
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: basePtr.advanced(by: headerSizeV1),
                    count: totalCount - headerSizeV1
                ))
                let actualDigest = hasher.finalize()
                let digestMatches = actualDigest.withUnsafeBytes { expectedDigest.elementsEqual($0) }
                guard digestMatches else { return nil }
                payloadStart = headerSizeV1

            default:
                return nil
            }

            var offset = payloadStart
            var levels: [WaveformMipLevel] = []
            levels.reserveCapacity(Int(levelCount))

            for _ in 0..<Int(levelCount) {
                guard offset + 8 <= totalCount else { return nil }
                let framesPerBucket = Int(loadUInt32LE(basePtr, at: offset))
                let bucketCount = Int(loadUInt32LE(basePtr, at: offset + 4))
                offset += 8

                guard framesPerBucket >= 1, bucketCount >= 0 else { return nil }
                let (perChannelBytes, ov1) = bucketCount.multipliedReportingOverflow(by: 16)
                guard !ov1 else { return nil }
                let (allChannelsBytes, ov2) = perChannelBytes.multipliedReportingOverflow(by: Int(channelCount))
                guard !ov2 else { return nil }
                let (nextOffset, ov3) = offset.addingReportingOverflow(allChannelsBytes)
                guard !ov3, nextOffset <= totalCount else { return nil }

                var channelLevels: [WaveformChannelLevel] = []
                channelLevels.reserveCapacity(Int(channelCount))

                for ch in 0..<Int(channelCount) {
                    let buckets: [WaveformBucket]
                    if bucketCount == 0 {
                        buckets = []
                    } else {
                        var channelValid = true
                        buckets = [WaveformBucket](unsafeUninitializedCapacity: bucketCount) { buffer, initializedCount in
                            guard let dst = buffer.baseAddress else {
                                channelValid = false
                                initializedCount = 0
                                return
                            }
                            var cur = basePtr.advanced(by: offset)
                            for i in 0..<bucketCount {
                                let mn = Float(bitPattern: UInt32(littleEndian: cur.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
                                let mx = Float(bitPattern: UInt32(littleEndian: cur.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
                                let rms = Float(bitPattern: UInt32(littleEndian: cur.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
                                let clippedByte = cur.loadUnaligned(fromByteOffset: 12, as: UInt8.self)
                                guard mn.isFinite, mx.isFinite, rms.isFinite, rms >= 0 else {
                                    channelValid = false
                                    initializedCount = i
                                    return
                                }
                                dst.advanced(by: i).initialize(to: WaveformBucket(
                                    minSample: mn,
                                    maxSample: mx,
                                    rms: rms,
                                    clipped: clippedByte != 0
                                ))
                                cur = cur.advanced(by: 16)
                            }
                            initializedCount = bucketCount
                        }
                        guard channelValid else { return nil }
                    }
                    offset += perChannelBytes
                    channelLevels.append(WaveformChannelLevel(channelIndex: ch, buckets: buckets))
                }

                levels.append(WaveformMipLevel(framesPerBucket: framesPerBucket, channels: channelLevels))
            }

            // Ensure trailing garbage is rejected.
            guard offset == totalCount else { return nil }

            let duration = Double(totalFrames) / Double(sampleRate)
            return WaveformPyramid(
                assetID: assetID,
                cacheKey: cacheKey,
                sampleRate: sampleRate,
                channelCount: Int(channelCount),
                totalFrames: totalFrames,
                duration: duration,
                levels: levels,
                isPartial: false,
                completedFrames: totalFrames
            )
        }
    }

    private static func computeCRC32(_ ptr: UnsafeRawPointer, count: Int) -> UInt32 {
        var crc = zlib.crc32(0, nil, 0)
        var remaining = count
        var bytePtr = ptr.assumingMemoryBound(to: Bytef.self)
        let maxChunk = 1 << 30
        while remaining > 0 {
            let chunk = min(remaining, maxChunk)
            crc = zlib.crc32(crc, bytePtr, uInt(chunk))
            bytePtr = bytePtr.advanced(by: chunk)
            remaining -= chunk
        }
        return UInt32(truncatingIfNeeded: crc)
    }

    private static func loadUInt32LE(_ basePtr: UnsafeRawPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: basePtr.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private static func loadUInt64LE(_ basePtr: UnsafeRawPointer, at offset: Int) -> UInt64 {
        UInt64(littleEndian: basePtr.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}
