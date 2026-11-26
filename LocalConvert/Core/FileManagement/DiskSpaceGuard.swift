import Foundation

// MARK: - Volume Capacity Provider

/// Abstraction for querying available volume capacity so pre-flight checks are deterministically testable.
protocol VolumeCapacityProviding: Sendable {
    func availableCapacityBytes(for url: URL) -> Int64?
}

struct SystemVolumeCapacityProvider: VolumeCapacityProviding {
    func availableCapacityBytes(for url: URL) -> Int64? {
        let fm = FileManager.default
        var probe = url.standardizedFileURL
        let maxDepth = max(probe.pathComponents.count + 2, 16)
        for _ in 0..<maxDepth {
            if fm.fileExists(atPath: probe.path) {
                break
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path {
                break
            }
            probe = parent
        }

        guard let values = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        ) else {
            return nil
        }

        if let importantUsage = values.volumeAvailableCapacityForImportantUsage, importantUsage >= 0 {
            return importantUsage
        }
        if let available = values.volumeAvailableCapacity {
            return Int64(available)
        }
        return nil
    }
}

// MARK: - Disk Space Check Result

struct DiskSpaceCheckResult: Sendable, Equatable {
    let directory: URL
    let availableBytes: Int64?
    let requiredBytes: Int64
    let isSufficient: Bool
}

// MARK: - Shared Disk Space Guard

/// Pre-flight volume free-space guard for staging and destination volumes.
struct DiskSpaceGuard: Sendable {
    static let defaultMinimumFreeBufferBytes: Int64 = 64 * 1024 * 1024

    let capacityProvider: any VolumeCapacityProviding
    let minimumFreeBufferBytes: Int64

    init(
        capacityProvider: any VolumeCapacityProviding = SystemVolumeCapacityProvider(),
        minimumFreeBufferBytes: Int64 = DiskSpaceGuard.defaultMinimumFreeBufferBytes
    ) {
        self.capacityProvider = capacityProvider
        self.minimumFreeBufferBytes = max(0, minimumFreeBufferBytes)
    }

    func estimateRequiredBytes(inputSizes: [Int64], outputFormat: FileFormat) -> Int64 {
        var totalInputBytes: Int64 = 0
        for size in inputSizes where size > 0 {
            let (next, overflow) = totalInputBytes.addingReportingOverflow(size)
            totalInputBytes = overflow ? Int64.max : next
        }

        let multiplier: Double
        if outputFormat == .pdf {
            multiplier = 2.0
        } else {
            switch outputFormat.category {
            case .video, .archive:
                multiplier = 2.0
            case .audio, .document:
                multiplier = 1.5
            case .image, .subtitle:
                multiplier = 1.25
            }
        }

        let scaledDouble = Double(totalInputBytes) * multiplier
        let scaledBytes: Int64 = scaledDouble >= Double(Int64.max) ? Int64.max : Int64(scaledDouble.rounded(.up))
        let (required, overflow) = scaledBytes.addingReportingOverflow(minimumFreeBufferBytes)
        return overflow ? Int64.max : required
    }

    func checkSpace(at directory: URL, requiredBytes: Int64) -> DiskSpaceCheckResult {
        let clampedRequired = max(0, requiredBytes)
        guard let available = capacityProvider.availableCapacityBytes(for: directory) else {
            return DiskSpaceCheckResult(
                directory: directory,
                availableBytes: nil,
                requiredBytes: clampedRequired,
                isSufficient: true
            )
        }
        return DiskSpaceCheckResult(
            directory: directory,
            availableBytes: available,
            requiredBytes: clampedRequired,
            isSufficient: available >= clampedRequired
        )
    }

    func validateSufficientSpace(
        stagingDirectory: URL = FileManager.default.temporaryDirectory,
        outputDirectory: URL,
        inputURLs: [URL],
        outputFormat: FileFormat
    ) throws {
        let fm = FileManager.default
        let inputSizes: [Int64] = inputURLs.compactMap { url in
            (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        let requiredBytes = estimateRequiredBytes(inputSizes: inputSizes, outputFormat: outputFormat)

        let standardizedStaging = stagingDirectory.standardizedFileURL
        let standardizedOutput = outputDirectory.standardizedFileURL
        var checkedDirectories: [URL] = [standardizedStaging]
        if standardizedOutput != standardizedStaging {
            checkedDirectories.append(standardizedOutput)
        }

        for dir in checkedDirectories {
            let result = checkSpace(at: dir, requiredBytes: requiredBytes)
            if !result.isSufficient {
                throw ConversionError.insufficientDiskSpace
            }
        }
    }
}
