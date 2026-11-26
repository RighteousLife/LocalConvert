import Foundation

// MARK: - File Stability Outcome

enum FileStabilityOutcome: Sendable, Equatable {
    case stable(WatchFolderFileFingerprint)
    case ignored(reason: String)
    case timedOut(reason: String)
    case unreadable(reason: String)
}

// MARK: - Deterministic File Write-Completion & Stability Detector

struct FileStabilityDetector: Sendable {
    let settleDelaySeconds: TimeInterval
    let maxWaitSeconds: TimeInterval
    let requiredStableObservations: Int

    init(
        settleDelaySeconds: TimeInterval = 1.5,
        maxWaitSeconds: TimeInterval = 30.0,
        requiredStableObservations: Int = 2
    ) {
        self.settleDelaySeconds = min(max(settleDelaySeconds, 0.03), 30.0)
        self.maxWaitSeconds = min(max(maxWaitSeconds, 0.15), 300.0)
        self.requiredStableObservations = max(requiredStableObservations, 2)
    }

    func waitForStability(of url: URL) async -> FileStabilityOutcome {
        let std = url.standardizedFileURL

        if WatchFolderPathSafety.isTemporaryOrHiddenFile(std) {
            return .ignored(reason: "Excluded temporary or hidden file")
        }

        let startClock = CFAbsoluteTimeGetCurrent()
        var previousFingerprint: WatchFolderFileFingerprint?
        var consecutiveMatches = 0
        var lastUnreadableReason: String?

        while true {
            if Task.isCancelled {
                return .ignored(reason: "Cancelled before stability check completed")
            }

            let fm = FileManager.default
            guard fm.fileExists(atPath: std.path) else {
                return .ignored(reason: "File no longer exists on disk")
            }

            let resourceKeys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isDirectoryKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]

            guard let values = try? std.resourceValues(forKeys: resourceKeys) else {
                lastUnreadableReason = "Could not inspect file metadata for '\(std.lastPathComponent)'."
                if hasExceededBudget(since: startClock) {
                    return .unreadable(reason: lastUnreadableReason ?? "File unreadable.")
                }
                await sleepOneInterval(since: startClock)
                continue
            }

            if values.isDirectory == true || values.isSymbolicLink == true || values.isRegularFile != true {
                return .ignored(reason: "Skipped non-regular file or symbolic link")
            }

            guard let current = WatchFolderFileFingerprint.capture(for: std) else {
                lastUnreadableReason = "File metadata unavailable for '\(std.lastPathComponent)'."
                if hasExceededBudget(since: startClock) {
                    return .unreadable(reason: lastUnreadableReason!)
                }
                await sleepOneInterval(since: startClock)
                continue
            }

            if current.fileSize <= 0 {
                // Zero-byte files are treated as still being created/written until timeout.
                previousFingerprint = nil
                consecutiveMatches = 0
                if hasExceededBudget(since: startClock) {
                    return .timedOut(reason: "File remained empty (0 bytes) past stability timeout.")
                }
                await sleepOneInterval(since: startClock)
                continue
            }

            if let prev = previousFingerprint, prev.matchesContent(of: current) {
                consecutiveMatches += 1
            } else {
                previousFingerprint = current
                consecutiveMatches = 1
            }

            if consecutiveMatches >= requiredStableObservations {
                // Confirm the file can actually be opened for reading before handoff.
                do {
                    let handle = try FileHandle(forReadingFrom: std)
                    try? handle.close()
                    return .stable(current)
                } catch {
                    lastUnreadableReason = "File '\(std.lastPathComponent)' could not be opened for reading: \(error.localizedDescription)"
                    if hasExceededBudget(since: startClock) {
                        return .unreadable(reason: lastUnreadableReason!)
                    }
                    // Reset stable streak so next check re-confirms unchanged size/mtime after lock clears.
                    consecutiveMatches = 1
                }
            }

            if hasExceededBudget(since: startClock) {
                if let lastUnreadableReason {
                    return .unreadable(reason: lastUnreadableReason)
                }
                return .timedOut(
                    reason: "File '\(std.lastPathComponent)' continued changing beyond the \(String(format: "%.1f", maxWaitSeconds))s stability window."
                )
            }

            await sleepOneInterval(since: startClock)
        }
    }

    private func hasExceededBudget(since startClock: CFAbsoluteTime) -> Bool {
        (CFAbsoluteTimeGetCurrent() - startClock) >= maxWaitSeconds
    }

    private func sleepOneInterval(since startClock: CFAbsoluteTime) async {
        let elapsed = CFAbsoluteTimeGetCurrent() - startClock
        let remaining = max(0.01, maxWaitSeconds - elapsed)
        let delay = min(settleDelaySeconds, remaining)
        let ns = UInt64((delay * 1_000_000_000.0).rounded())
        try? await Task.sleep(nanoseconds: max(ns, 10_000_000))
    }
}
