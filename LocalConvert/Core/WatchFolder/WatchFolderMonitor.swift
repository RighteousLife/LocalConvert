import Foundation
import CoreServices

// MARK: - FSEvents Directory Monitor

struct WatchFolderScanResult: Sendable, Equatable {
    let urls: [URL]
    let wasTruncated: Bool
    let maxFiles: Int
    let warningMessage: String?
}

final class WatchFolderMonitor: @unchecked Sendable {

    private struct MutableState {
        var stream: FSEventStreamRef?
        var isRunning: Bool = false
        var pendingURLs: Set<URL> = []
        var debounceWorkItem: DispatchWorkItem?
        var excludedPrefixes: [String]
    }

    let directoryURL: URL
    let includeSubdirectories: Bool
    private let rootCanonicalPath: String
    private let debounceInterval: TimeInterval
    private let onFilesChanged: @Sendable ([URL]) -> Void
    private let onError: @Sendable (String) -> Void
    private let onWarning: (@Sendable (String) -> Void)?
    private let eventQueue: DispatchQueue
    private let lock = NSLock()
    private var state: MutableState

    init(
        directoryURL: URL,
        includeSubdirectories: Bool,
        excludedCanonicalPrefixes: [String] = [],
        debounceInterval: TimeInterval = 0.15,
        onFilesChanged: @escaping @Sendable ([URL]) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onWarning: (@Sendable (String) -> Void)? = nil
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.includeSubdirectories = includeSubdirectories
        self.rootCanonicalPath = WatchFolderPathSafety.canonicalPath(for: directoryURL)
        self.debounceInterval = min(max(debounceInterval, 0.02), 2.0)
        self.onFilesChanged = onFilesChanged
        self.onError = onError
        self.onWarning = onWarning
        self.eventQueue = DispatchQueue(
            label: "com.localconvert.watchfolder.fsevents.\(UUID().uuidString)",
            qos: .utility
        )
        self.state = MutableState(excludedPrefixes: excludedCanonicalPrefixes)
    }

    deinit {
        stop()
    }

    func updateExcludedPrefixes(_ prefixes: [String]) {
        lock.withLock {
            state.excludedPrefixes = prefixes
        }
    }

    @discardableResult
    func start() -> Bool {
        let alreadyRunning = lock.withLock { state.isRunning }
        guard !alreadyRunning else { return true }

        guard WatchFolderPathSafety.isExistingReadableDirectory(directoryURL) else {
            onError("Watched directory '\(directoryURL.lastPathComponent)' is missing or unreadable.")
            return false
        }

        let pathsToWatch = [rootCanonicalPath] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { ptr in
                guard let ptr else { return nil }
                _ = Unmanaged<AnyObject>.fromOpaque(ptr).retain()
                return ptr
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<AnyObject>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )

        let latency = min(debounceInterval, 0.25)
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.streamCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            onError("Failed to create FSEvents monitor for '\(directoryURL.lastPathComponent)'.")
            return false
        }

        FSEventStreamSetDispatchQueue(createdStream, eventQueue)
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            onError("Failed to start FSEvents stream for '\(directoryURL.lastPathComponent)'.")
            return false
        }

        lock.withLock {
            state.stream = createdStream
            state.isRunning = true
        }
        return true
    }

    func stop() {
        let streamToStop: FSEventStreamRef? = lock.withLock {
            state.debounceWorkItem?.cancel()
            state.debounceWorkItem = nil
            state.pendingURLs.removeAll()
            state.isRunning = false
            let existing = state.stream
            state.stream = nil
            return existing
        }

        if let streamToStop {
            FSEventStreamStop(streamToStop)
            FSEventStreamInvalidate(streamToStop)
            FSEventStreamRelease(streamToStop)
        }
    }

    var isRunning: Bool {
        lock.withLock { state.isRunning }
    }

    // MARK: - FSEvents C Callback

    private static let streamCallback: FSEventStreamCallback = { (
        _: ConstFSEventStreamRef,
        clientCallBackInfo: UnsafeMutableRawPointer?,
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        _: UnsafePointer<FSEventStreamEventId>
    ) in
        guard let clientCallBackInfo else { return }
        let monitor = Unmanaged<WatchFolderMonitor>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
        let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self)
        var rawEvents: [(path: String, flags: FSEventStreamEventFlags)] = []
        rawEvents.reserveCapacity(numEvents)
        for idx in 0..<numEvents {
            if let path = pathsArray[idx] as? String {
                rawEvents.append((path: path, flags: eventFlags[idx]))
            }
        }
        monitor.processRawEvents(rawEvents)
    }

    private func processRawEvents(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        let excludedPrefixes: [String]? = lock.withLock {
            guard state.isRunning else { return nil }
            return state.excludedPrefixes
        }
        guard let excludedPrefixes else { return }

        var batchURLs: [URL] = []

        for event in events {
            let flags = event.flags
            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0
                || (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)) != 0 {
                if !WatchFolderPathSafety.isExistingReadableDirectory(directoryURL) {
                    onError("Watched folder '\(directoryURL.lastPathComponent)' was moved, deleted, or unmounted.")
                    return
                }
            }

            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) != 0 {
                batchURLs.append(contentsOf: scanVisibleFiles(excludedPrefixes: excludedPrefixes))
                continue
            }

            // Ignore pure directory-creation events unless a regular file resides at the path
            if (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0 {
                continue
            }

            let rawURL = URL(fileURLWithPath: event.path).standardizedFileURL
            guard !WatchFolderPathSafety.isTemporaryOrHiddenFile(rawURL) else { continue }

            let canonical = WatchFolderPathSafety.canonicalPath(for: rawURL)
            if excludedPrefixes.contains(where: { WatchFolderPathSafety.isPath(canonical, equalToOrInside: $0) }) {
                continue
            }

            if !includeSubdirectories {
                let parentCanonical = WatchFolderPathSafety.canonicalPath(for: rawURL.deletingLastPathComponent())
                guard parentCanonical == rootCanonicalPath else { continue }
            }

            guard FileManager.default.fileExists(atPath: rawURL.path) else { continue }
            batchURLs.append(rawURL)
        }

        guard !batchURLs.isEmpty else { return }

        let scheduledWork: DispatchWorkItem? = lock.withLock {
            guard state.isRunning else { return nil }
            state.pendingURLs.formUnion(batchURLs)
            state.debounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.flushPendingBatch()
            }
            state.debounceWorkItem = work
            return work
        }

        if let scheduledWork {
            eventQueue.asyncAfter(deadline: .now() + debounceInterval, execute: scheduledWork)
        }
    }

    private func flushPendingBatch() {
        let collected: [URL] = lock.withLock {
            state.debounceWorkItem = nil
            guard state.isRunning, !state.pendingURLs.isEmpty else {
                state.pendingURLs.removeAll()
                return []
            }
            let urls = Array(state.pendingURLs).sorted { $0.path < $1.path }
            state.pendingURLs.removeAll()
            return urls
        }
        if !collected.isEmpty {
            onFilesChanged(collected)
        }
    }

    func scanVisibleFiles(excludedPrefixes: [String], maxFiles: Int = 500) -> [URL] {
        scanVisibleFilesWithStatus(excludedPrefixes: excludedPrefixes, maxFiles: maxFiles).urls
    }

    func scanVisibleFilesWithStatus(excludedPrefixes: [String], maxFiles: Int = 500) -> WatchFolderScanResult {
        guard maxFiles > 0 else {
            return WatchFolderScanResult(urls: [], wasTruncated: false, maxFiles: maxFiles, warningMessage: nil)
        }
        guard WatchFolderPathSafety.isExistingReadableDirectory(directoryURL) else {
            return WatchFolderScanResult(urls: [], wasTruncated: false, maxFiles: maxFiles, warningMessage: nil)
        }
        let fm = FileManager.default
        var results: [URL] = []
        var wasTruncated = false

        if includeSubdirectories {
            guard let enumerator = fm.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return WatchFolderScanResult(urls: [], wasTruncated: false, maxFiles: maxFiles, warningMessage: nil)
            }
            for case let fileURL as URL in enumerator {
                let canonical = WatchFolderPathSafety.canonicalPath(for: fileURL)
                if excludedPrefixes.contains(where: { WatchFolderPathSafety.isPath(canonical, equalToOrInside: $0) }) {
                    enumerator.skipDescendants()
                    continue
                }
                guard !WatchFolderPathSafety.isTemporaryOrHiddenFile(fileURL) else { continue }
                let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if vals?.isRegularFile == true && vals?.isSymbolicLink != true {
                    if results.count >= maxFiles {
                        wasTruncated = true
                        break
                    }
                    results.append(fileURL.standardizedFileURL)
                }
            }
        } else {
            guard let children = try? fm.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return WatchFolderScanResult(urls: [], wasTruncated: false, maxFiles: maxFiles, warningMessage: nil)
            }
            for child in children {
                let canonical = WatchFolderPathSafety.canonicalPath(for: child)
                if excludedPrefixes.contains(where: { WatchFolderPathSafety.isPath(canonical, equalToOrInside: $0) }) {
                    continue
                }
                guard !WatchFolderPathSafety.isTemporaryOrHiddenFile(child) else { continue }
                let vals = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if vals?.isRegularFile == true && vals?.isSymbolicLink != true {
                    if results.count >= maxFiles {
                        wasTruncated = true
                        break
                    }
                    results.append(child.standardizedFileURL)
                }
            }
        }

        let sorted = results.sorted { $0.path < $1.path }
        let warning: String?
        if wasTruncated {
            let msg = "Watch Folder scan for '\(directoryURL.lastPathComponent)' reached the \(maxFiles)-file limit; remaining files were not queued."
            warning = msg
            StructuredDiagnostics.record(
                category: .watchFolder,
                severity: .validation,
                stage: "scanVisibleFiles",
                filename: directoryURL.lastPathComponent,
                message: msg
            )
            onWarning?(msg)
        } else {
            warning = nil
        }

        return WatchFolderScanResult(
            urls: sorted,
            wasTruncated: wasTruncated,
            maxFiles: maxFiles,
            warningMessage: warning
        )
    }
}
