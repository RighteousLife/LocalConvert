import Foundation
import AppKit
import Combine
import os.log

// MARK: - Watch Folder Manager

@MainActor
final class WatchFolderManager: ObservableObject {

    static let maxConcurrentStabilityChecks = 8
    static let maxKnownOutputProvenance = 2_000

    private let logger = Logger(subsystem: "com.localconvert.app", category: "WatchFolderManager")

    let store: WatchFolderStore
    private let presetManager: PresetManager
    private let conversionManager: ConversionManager
    private let conversionQueue: ConversionQueue
    private let presetExecutor: PresetExecutor
    var defaultOutputLocationProvider: @MainActor () -> (OutputLocation, URL?)

    @Published private(set) var rules: [WatchFolderRule] = []
    @Published private(set) var records: [WatchFolderFileRecord] = []
    @Published private(set) var scanWarningsByRuleID: [UUID: String] = [:]
    @Published var isGloballyPaused: Bool = false

    private var monitors: [UUID: WatchFolderMonitor] = [:]
    private var securityScopedURLs: [UUID: [URL]] = [:]
    private var stabilityTasks: [String: Task<Void, Never>] = [:]
    private var pendingStabilityQueue: [(ruleID: UUID, url: URL, fileKey: String, recordID: UUID, forceReprocess: Bool)] = []
    private var inFlightFileKeys: Set<String> = []
    private var trackedJobs: [UUID: (ruleID: UUID, recordID: UUID, fileKey: String, canonicalPath: String, fingerprint: WatchFolderFileFingerprint)] = [:]
    private var knownGeneratedOutputPaths: [String] = []
    private var knownGeneratedResourceIDs: [String] = []
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Test / diagnostics override for FSEvents debounce interval.
    var monitorDebounceInterval: TimeInterval = 0.15

    init(
        store: WatchFolderStore = WatchFolderStore(),
        presetManager: PresetManager = .shared,
        conversionManager: ConversionManager,
        conversionQueue: ConversionQueue,
        presetExecutor: PresetExecutor = PresetExecutor(),
        defaultOutputLocationProvider: @escaping @MainActor () -> (OutputLocation, URL?) = {
            (AppSettings.shared.defaultOutputLocation.outputLocation, AppSettings.shared.customOutputDirectory)
        }
    ) {
        self.store = store
        self.presetManager = presetManager
        self.conversionManager = conversionManager
        self.conversionQueue = conversionQueue
        self.presetExecutor = presetExecutor
        self.defaultOutputLocationProvider = defaultOutputLocationProvider

        self.rules = store.snapshot.rules
        self.records = store.snapshot.recentRecords

        observeDependencies()
    }

    // MARK: - Lifecycle & Startup Reconciliation

    func reconcileAndStartEnabledRules() {
        _ = store.reconcileStaleInProgressRecords()
        syncFromStore()

        for rule in rules {
            guard rule.isEnabled else {
                setRuleStatus(ruleID: rule.id, status: .disabled, error: nil)
                continue
            }
            if rule.isPaused || isGloballyPaused {
                setRuleStatus(ruleID: rule.id, status: .paused, error: nil)
                continue
            }
            _ = startMonitoring(ruleID: rule.id)
        }
    }

    func stopAll() {
        for ruleID in Array(monitors.keys) {
            stopMonitorAndReleaseResources(for: ruleID)
        }
        for (_, task) in stabilityTasks {
            task.cancel()
        }
        stabilityTasks.removeAll()
        pendingStabilityQueue.removeAll()
        inFlightFileKeys.removeAll()
        trackedJobs.removeAll()
        store.persist()
    }

    // MARK: - CRUD & Rule Lifecycle

    @discardableResult
    func addRule(_ candidate: WatchFolderRule) -> WatchFolderValidationResult {
        var rule = candidate
        let now = Date()
        rule.createdAt = now
        rule.modifiedAt = now
        let (defaultLoc, customDir) = defaultOutputLocationProvider()

        let validation = WatchFolderValidator.validate(
            rule: rule,
            existingRules: rules,
            availablePresets: presetManager.presets,
            defaultOutputLocation: defaultLoc,
            customAppOutputDirectory: customDir
        )
        guard validation.isValid else {
            return validation
        }

        if rule.inputBookmarkData == nil {
            rule.inputBookmarkData = WatchFolderBookmarkManager.createBookmark(for: rule.inputDirectoryURL)
        }
        if !rule.isEnabled {
            rule.lastStatus = .disabled
        } else if rule.isPaused || isGloballyPaused {
            rule.lastStatus = .paused
        } else {
            rule.lastStatus = .disabled
        }

        store.update { snap in
            snap.rules.append(rule)
        }
        syncFromStore()

        if rule.isEnabled && !rule.isPaused && !isGloballyPaused {
            _ = startMonitoring(ruleID: rule.id)
        }
        return validation
    }

    @discardableResult
    func updateRule(_ updatedCandidate: WatchFolderRule) -> WatchFolderValidationResult {
        var rule = updatedCandidate
        rule.modifiedAt = Date()
        let (defaultLoc, customDir) = defaultOutputLocationProvider()

        let validation = WatchFolderValidator.validate(
            rule: rule,
            existingRules: rules,
            availablePresets: presetManager.presets,
            defaultOutputLocation: defaultLoc,
            customAppOutputDirectory: customDir
        )
        guard validation.isValid else {
            return validation
        }

        stopMonitorAndReleaseResources(for: rule.id)
        cancelPendingWork(for: rule.id)

        if !rule.isEnabled {
            rule.lastStatus = .disabled
            rule.lastErrorMessage = nil
        } else if rule.isPaused || isGloballyPaused {
            rule.lastStatus = .paused
            rule.lastErrorMessage = nil
        } else {
            rule.lastErrorMessage = nil
        }

        store.update { snap in
            if let idx = snap.rules.firstIndex(where: { $0.id == rule.id }) {
                snap.rules[idx] = rule
            }
        }
        syncFromStore()

        if rule.isEnabled && !rule.isPaused && !isGloballyPaused {
            _ = startMonitoring(ruleID: rule.id)
        }
        return validation
    }

    func removeRule(id: UUID) {
        stopMonitorAndReleaseResources(for: id)
        cancelPendingWork(for: id)
        scanWarningsByRuleID.removeValue(forKey: id)

        store.update { snap in
            snap.rules.removeAll { $0.id == id }
            snap.processedFingerprintsByRule.removeValue(forKey: id)
            snap.recentRecords.removeAll { $0.ruleID == id }
        }
        syncFromStore()
    }

    func clearScanWarning(for ruleID: UUID) {
        scanWarningsByRuleID.removeValue(forKey: ruleID)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for ruleID: UUID) -> WatchFolderValidationResult? {
        guard let existing = rules.first(where: { $0.id == ruleID }) else { return nil }
        if !enabled {
            stopMonitorAndReleaseResources(for: ruleID)
            cancelPendingWork(for: ruleID)
            store.update { snap in
                if let idx = snap.rules.firstIndex(where: { $0.id == ruleID }) {
                    snap.rules[idx].isEnabled = false
                    snap.rules[idx].lastStatus = .disabled
                    snap.rules[idx].lastErrorMessage = nil
                    snap.rules[idx].modifiedAt = Date()
                }
            }
            syncFromStore()
            return WatchFolderValidationResult(isValid: true, errorMessage: nil, warningMessage: nil)
        }

        var candidate = existing
        candidate.isEnabled = true
        let (defaultLoc, customDir) = defaultOutputLocationProvider()
        let validation = WatchFolderValidator.validate(
            rule: candidate,
            existingRules: rules,
            availablePresets: presetManager.presets,
            defaultOutputLocation: defaultLoc,
            customAppOutputDirectory: customDir
        )

        guard validation.isValid else {
            setRuleStatus(
                ruleID: ruleID,
                status: .error(validation.errorMessage ?? "Invalid Watch Folder configuration."),
                error: validation.errorMessage
            )
            return validation
        }

        store.update { snap in
            if let idx = snap.rules.firstIndex(where: { $0.id == ruleID }) {
                snap.rules[idx].isEnabled = true
                snap.rules[idx].modifiedAt = Date()
            }
        }
        syncFromStore()

        if !existing.isPaused && !isGloballyPaused {
            _ = startMonitoring(ruleID: ruleID)
        } else {
            setRuleStatus(ruleID: ruleID, status: .paused, error: nil)
        }
        return validation
    }

    func setPaused(_ paused: Bool, for ruleID: UUID) {
        guard let existing = rules.first(where: { $0.id == ruleID }) else { return }
        store.update { snap in
            if let idx = snap.rules.firstIndex(where: { $0.id == ruleID }) {
                snap.rules[idx].isPaused = paused
                snap.rules[idx].modifiedAt = Date()
                if !snap.rules[idx].isEnabled {
                    snap.rules[idx].lastStatus = .disabled
                } else if paused || isGloballyPaused {
                    snap.rules[idx].lastStatus = .paused
                }
            }
        }
        syncFromStore()

        if paused {
            stopMonitorAndReleaseResources(for: ruleID)
            cancelPendingWork(for: ruleID)
        } else if existing.isEnabled && !isGloballyPaused {
            _ = startMonitoring(ruleID: ruleID)
        }
    }

    func pauseAll() {
        guard !isGloballyPaused else { return }
        isGloballyPaused = true
        for rule in rules where rule.isEnabled {
            stopMonitorAndReleaseResources(for: rule.id)
            cancelPendingWork(for: rule.id)
            setRuleStatus(ruleID: rule.id, status: .paused, error: nil)
        }
    }

    func resumeAll() {
        guard isGloballyPaused else { return }
        isGloballyPaused = false
        for rule in rules where rule.isEnabled && !rule.isPaused {
            _ = startMonitoring(ruleID: rule.id)
        }
    }

    // MARK: - Monitoring Execution

    @discardableResult
    func startMonitoring(ruleID: UUID) -> Bool {
        guard let rule = rules.first(where: { $0.id == ruleID }),
              rule.isEnabled,
              !rule.isPaused,
              !isGloballyPaused else {
            return false
        }

        stopMonitorAndReleaseResources(for: ruleID)

        var activeURL = rule.inputDirectoryURL
        var scopedList: [URL] = []

        if let bmData = rule.inputBookmarkData {
            if let resolved = WatchFolderBookmarkManager.resolveBookmark(bmData) {
                activeURL = resolved.url.standardizedFileURL
                if activeURL.startAccessingSecurityScopedResource() {
                    scopedList.append(activeURL)
                }
                if resolved.isStale, let refreshed = WatchFolderBookmarkManager.createBookmark(for: activeURL) {
                    store.update { snap in
                        if let idx = snap.rules.firstIndex(where: { $0.id == ruleID }) {
                            snap.rules[idx].inputDirectoryPath = activeURL.path
                            snap.rules[idx].inputBookmarkData = refreshed
                        }
                    }
                    syncFromStore()
                }
            } else {
                let msg = "Security-scoped access to '\(activeURL.lastPathComponent)' expired or permission was revoked. Re-select the folder."
                setRuleStatus(ruleID: ruleID, status: .error(msg), error: msg)
                return false
            }
        }

        if case .customDirectory(let outPath, let outBookmark?) = rule.outputDestination {
            if let resolvedOut = WatchFolderBookmarkManager.resolveBookmark(outBookmark) {
                let resolvedOutURL = resolvedOut.url.standardizedFileURL
                if resolvedOutURL.startAccessingSecurityScopedResource() {
                    scopedList.append(resolvedOutURL)
                }
                if resolvedOut.isStale {
                    if let refreshedOut = WatchFolderBookmarkManager.createBookmark(for: resolvedOutURL) {
                        store.update { snap in
                            if let idx = snap.rules.firstIndex(where: { $0.id == ruleID }) {
                                snap.rules[idx].outputDestination = .customDirectory(
                                    path: resolvedOutURL.path,
                                    bookmarkData: refreshedOut
                                )
                            }
                        }
                        syncFromStore()
                    } else {
                        for url in scopedList {
                            url.stopAccessingSecurityScopedResource()
                        }
                        let outName = resolvedOutURL.lastPathComponent
                        let msg = "Could not refresh security-scoped access for output folder '\(outName)'. Re-select the output folder."
                        logger.error("Failed to refresh stale output bookmark for rule \(ruleID.uuidString, privacy: .public) at \(resolvedOutURL.path, privacy: .private)")
                        StructuredDiagnostics.record(
                            category: .watchFolder,
                            severity: .validation,
                            stage: "refreshOutputBookmark",
                            operationID: ruleID.uuidString,
                            filename: outName,
                            message: msg
                        )
                        setRuleStatus(ruleID: ruleID, status: .error(msg), error: msg)
                        return false
                    }
                }
            } else {
                for url in scopedList {
                    url.stopAccessingSecurityScopedResource()
                }
                let outName = URL(fileURLWithPath: outPath).lastPathComponent
                let msg = "Security-scoped access to output folder '\(outName)' expired or permission was revoked. Re-select the output folder."
                logger.error("Failed to resolve output bookmark for rule \(ruleID.uuidString, privacy: .public) at \(outPath, privacy: .private)")
                StructuredDiagnostics.record(
                    category: .watchFolder,
                    severity: .validation,
                    stage: "resolveOutputBookmark",
                    operationID: ruleID.uuidString,
                    filename: outName,
                    message: msg
                )
                setRuleStatus(ruleID: ruleID, status: .error(msg), error: msg)
                return false
            }
        }

        if !scopedList.isEmpty {
            securityScopedURLs[ruleID] = scopedList
        }

        guard let refreshedRule = rules.first(where: { $0.id == ruleID }) else { return false }
        let (defaultLoc, customDir) = defaultOutputLocationProvider()
        let validation = WatchFolderValidator.validate(
            rule: refreshedRule,
            existingRules: rules,
            availablePresets: presetManager.presets,
            defaultOutputLocation: defaultLoc,
            customAppOutputDirectory: customDir
        )

        guard validation.isValid else {
            stopMonitorAndReleaseResources(for: ruleID)
            let msg = validation.errorMessage ?? "Invalid Watch Folder configuration."
            setRuleStatus(ruleID: ruleID, status: .error(msg), error: msg)
            return false
        }

        let excludedPrefixes = computeExcludedCanonicalPrefixes(for: refreshedRule)
        let monitor = WatchFolderMonitor(
            directoryURL: activeURL,
            includeSubdirectories: refreshedRule.includeSubdirectories,
            excludedCanonicalPrefixes: excludedPrefixes,
            debounceInterval: monitorDebounceInterval,
            onFilesChanged: { [weak self] changedURLs in
                Task { @MainActor [weak self] in
                    self?.handleDetectedFiles(changedURLs, for: ruleID)
                }
            },
            onError: { [weak self] errMsg in
                Task { @MainActor [weak self] in
                    self?.handleMonitorError(errMsg, for: ruleID)
                }
            },
            onWarning: { [weak self] warningMsg in
                Task { @MainActor [weak self] in
                    self?.scanWarningsByRuleID[ruleID] = warningMsg
                }
            }
        )

        guard monitor.start() else {
            stopMonitorAndReleaseResources(for: ruleID)
            let msg = "Could not start filesystem monitor for '\(activeURL.lastPathComponent)'."
            setRuleStatus(ruleID: ruleID, status: .error(msg), error: msg)
            return false
        }

        monitors[ruleID] = monitor
        setRuleStatus(ruleID: ruleID, status: .active, error: nil)
        logger.info("Started Watch Folder '\(refreshedRule.name, privacy: .public)' on '\(activeURL.lastPathComponent, privacy: .public)'")
        return true
    }

    /// Scans visible eligible files in a rule's directory off the main actor and feeds them through the normal detection pipeline.
    func rescanRule(id ruleID: UUID) {
        performRescan(id: ruleID, maxFiles: 500)
    }

    func performRescan(id ruleID: UUID, maxFiles: Int = 500) {
        guard let rule = rules.first(where: { $0.id == ruleID }),
              rule.isEnabled,
              !rule.isPaused,
              !isGloballyPaused else {
            return
        }

        let excludedPrefixes = computeExcludedCanonicalPrefixes(for: rule)
        let dirURL = rule.inputDirectoryURL
        let includeSubs = rule.includeSubdirectories
        let tempMonitor = WatchFolderMonitor(
            directoryURL: dirURL,
            includeSubdirectories: includeSubs,
            excludedCanonicalPrefixes: excludedPrefixes,
            onFilesChanged: { _ in },
            onError: { _ in }
        )

        Task.detached(priority: .utility) {
            let scanResult = tempMonitor.scanVisibleFilesWithStatus(excludedPrefixes: excludedPrefixes, maxFiles: maxFiles)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let warning = scanResult.warningMessage {
                    self.scanWarningsByRuleID[ruleID] = warning
                    self.logger.warning("Watch Folder rescan truncated for rule \(ruleID.uuidString, privacy: .public): \(warning, privacy: .private)")
                } else {
                    self.scanWarningsByRuleID.removeValue(forKey: ruleID)
                }
                guard !scanResult.urls.isEmpty else { return }
                self.handleDetectedFiles(scanResult.urls, for: ruleID)
            }
        }
    }

    // MARK: - Event Handling, Duplicate Suppression & Execution

    func handleDetectedFiles(_ urls: [URL], for ruleID: UUID, forceReprocess: Bool = false) {
        guard !isGloballyPaused,
              let rule = rules.first(where: { $0.id == ruleID }),
              rule.isEnabled,
              !rule.isPaused else {
            return
        }

        let excludedPrefixes = computeExcludedCanonicalPrefixes(for: rule)

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            guard !WatchFolderPathSafety.isTemporaryOrHiddenFile(url) else { continue }

            let canonical = WatchFolderPathSafety.canonicalPath(for: url)
            if excludedPrefixes.contains(where: { WatchFolderPathSafety.isPath(canonical, equalToOrInside: $0) }) {
                continue
            }

            if !rule.includeSubdirectories {
                let rootCanonical = WatchFolderPathSafety.canonicalPath(for: rule.inputDirectoryURL)
                let parentCanonical = WatchFolderPathSafety.canonicalPath(for: url.deletingLastPathComponent())
                if parentCanonical != rootCanonical {
                    continue
                }
            }

            // Provenance loop guard: never reprocess outputs generated by LocalConvert
            let currentFP = WatchFolderFileFingerprint.capture(for: url)
            if isKnownGeneratedOutput(canonicalPath: canonical, resourceID: currentFP?.resourceIdentifierBase64) {
                upsertRecord(
                    ruleID: ruleID,
                    url: url,
                    state: .ignored,
                    fingerprint: currentFP,
                    reason: "Excluded output file generated by LocalConvert."
                )
                continue
            }

            let fileKey = Self.fileKey(ruleID: ruleID, canonicalPath: canonical)
            if inFlightFileKeys.contains(fileKey) {
                continue
            }

            // Idempotency guard against previously completed unchanged files
            if !forceReprocess,
               let fp = currentFP,
               let prevCompleted = store.snapshot.processedFingerprintsByRule[ruleID]?[canonical],
               prevCompleted.matchesContent(of: fp) {
                continue
            }

            inFlightFileKeys.insert(fileKey)
            let recordID = upsertRecord(
                ruleID: ruleID,
                url: url,
                state: .pending,
                fingerprint: currentFP,
                reason: nil
            )

            pendingStabilityQueue.append((
                ruleID: ruleID,
                url: url,
                fileKey: fileKey,
                recordID: recordID,
                forceReprocess: forceReprocess
            ))
        }

        drainPendingStabilityChecks()
    }

    func retryRecord(id recordID: UUID) {
        guard let record = records.first(where: { $0.id == recordID }), record.canRetry else { return }
        let url = URL(fileURLWithPath: record.filePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            transitionRecord(
                id: recordID,
                to: .failed,
                reason: "Source file no longer exists on disk."
            )
            return
        }
        handleDetectedFiles([url], for: record.ruleID, forceReprocess: true)
    }

    func clearRecords(for ruleID: UUID? = nil) {
        store.update { snap in
            if let ruleID {
                snap.recentRecords.removeAll { $0.ruleID == ruleID }
            } else {
                snap.recentRecords.removeAll()
            }
        }
        syncFromStore()
    }

    // MARK: - Stability Task Pump

    private func drainPendingStabilityChecks() {
        while stabilityTasks.count < Self.maxConcurrentStabilityChecks, !pendingStabilityQueue.isEmpty {
            let item = pendingStabilityQueue.removeFirst()
            guard let rule = rules.first(where: { $0.id == item.ruleID }),
                  rule.isEnabled,
                  !rule.isPaused,
                  !isGloballyPaused else {
                inFlightFileKeys.remove(item.fileKey)
                transitionRecord(
                    id: item.recordID,
                    to: .ignored,
                    reason: "Watch Folder paused or disabled before processing."
                )
                continue
            }

            transitionRecord(id: item.recordID, to: .stabilizing, reason: "Checking file write completion...")

            let detector = FileStabilityDetector(
                settleDelaySeconds: rule.settleDelaySeconds,
                maxWaitSeconds: rule.maxStabilityWaitSeconds,
                requiredStableObservations: 2
            )

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await Task.detached(priority: .utility) {
                    await detector.waitForStability(of: item.url)
                }.value

                self.stabilityTasks.removeValue(forKey: item.fileKey)
                self.handleStabilityResult(
                    outcome: outcome,
                    item: item
                )
                self.drainPendingStabilityChecks()
            }

            stabilityTasks[item.fileKey] = task
        }
    }

    private func handleStabilityResult(
        outcome: FileStabilityOutcome,
        item: (ruleID: UUID, url: URL, fileKey: String, recordID: UUID, forceReprocess: Bool)
    ) {
        switch outcome {
        case .ignored(let reason):
            inFlightFileKeys.remove(item.fileKey)
            transitionRecord(id: item.recordID, to: .ignored, reason: reason)

        case .timedOut(let reason), .unreadable(let reason):
            inFlightFileKeys.remove(item.fileKey)
            transitionRecord(id: item.recordID, to: .failed, reason: ErrorDetailsFormatter.sanitize(reason))

        case .stable(let fingerprint):
            guard let rule = rules.first(where: { $0.id == item.ruleID }),
                  rule.isEnabled,
                  !rule.isPaused,
                  !isGloballyPaused else {
                inFlightFileKeys.remove(item.fileKey)
                transitionRecord(id: item.recordID, to: .ignored, reason: "Watch Folder paused before queueing.")
                return
            }

            let canonical = WatchFolderPathSafety.canonicalPath(for: item.url)
            if isKnownGeneratedOutput(canonicalPath: canonical, resourceID: fingerprint.resourceIdentifierBase64) {
                inFlightFileKeys.remove(item.fileKey)
                transitionRecord(
                    id: item.recordID,
                    to: .ignored,
                    fingerprint: fingerprint,
                    reason: "Excluded output file generated by LocalConvert."
                )
                return
            }

            if !item.forceReprocess,
               let prev = store.snapshot.processedFingerprintsByRule[item.ruleID]?[canonical],
               prev.matchesContent(of: fingerprint) {
                inFlightFileKeys.remove(item.fileKey)
                transitionRecord(
                    id: item.recordID,
                    to: .completed,
                    fingerprint: fingerprint,
                    reason: "Already converted (unchanged)."
                )
                return
            }

            guard let preset = presetManager.presets.first(where: { $0.id == rule.presetID }) else {
                inFlightFileKeys.remove(item.fileKey)
                let msg = "Selected preset was deleted or is unavailable."
                transitionRecord(id: item.recordID, to: .failed, fingerprint: fingerprint, reason: msg)
                pauseRuleOnMissingPreset(ruleID: rule.id, message: msg)
                return
            }

            let (defaultLoc, customDir) = defaultOutputLocationProvider()
            let outputDir = rule.outputDestination.resolvedDirectory(
                for: rule.inputDirectoryURL,
                preset: preset,
                defaultOutputLocation: defaultLoc,
                customAppOutputDirectory: customDir
            )

            // Final runtime loop safety check before invoking PresetExecutor
            let inCanonical = WatchFolderPathSafety.canonicalPath(for: rule.inputDirectoryURL)
            let outCanonical = WatchFolderPathSafety.canonicalPath(for: outputDir)
            guard outCanonical != inCanonical,
                  !WatchFolderPathSafety.isPath(inCanonical, equalToOrInside: outCanonical) else {
                inFlightFileKeys.remove(item.fileKey)
                let msg = "Blocked execution to prevent output directory loop."
                transitionRecord(id: item.recordID, to: .failed, fingerprint: fingerprint, reason: msg)
                stopMonitorAndReleaseResources(for: rule.id)
                setRuleStatus(ruleID: rule.id, status: .error(msg), error: msg)
                return
            }

            let report = presetExecutor.execute(
                preset: preset,
                inputURLs: [item.url],
                conversionManager: conversionManager,
                conversionQueue: conversionQueue,
                destinationOverride: outputDir,
                defaultOutputLocation: defaultLoc,
                customOutputDirectory: customDir,
                collisionPolicyOverride: rule.collisionPolicy,
                source: .watchFolder,
                watchFolderRuleID: rule.id,
                watchFolderRuleName: rule.name
            )

            if let job = report.enqueuedJobs.first {
                trackedJobs[job.id] = (
                    ruleID: rule.id,
                    recordID: item.recordID,
                    fileKey: item.fileKey,
                    canonicalPath: canonical,
                    fingerprint: fingerprint
                )
                transitionRecord(
                    id: item.recordID,
                    to: .queued,
                    fingerprint: fingerprint,
                    jobID: job.id,
                    reason: "Queued with preset '\(preset.name)'"
                )
            } else {
                inFlightFileKeys.remove(item.fileKey)
                let skipReason = report.skippedURLs.first?.reason ?? "File incompatible with preset '\(preset.name)'."
                transitionRecord(
                    id: item.recordID,
                    to: .ignored,
                    fingerprint: fingerprint,
                    reason: ErrorDetailsFormatter.sanitize(skipReason)
                )
            }
        }
    }

    // MARK: - Dependency & System Notifications

    private func observeDependencies() {
        conversionManager.$jobStatuses
            .sink { [weak self] statuses in
                self?.processJobStatusUpdates(statuses)
            }
            .store(in: &cancellables)

        presetManager.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.validateActivePresetsAfterChange()
                }
            }
            .store(in: &cancellables)

        let wsCenter = NSWorkspace.shared.notificationCenter
        let wakeToken = wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWakeOrVolumeChange()
            }
        }
        let mountToken = wsCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWakeOrVolumeChange()
            }
        }
        let unmountToken = wsCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWakeOrVolumeChange()
            }
        }
        workspaceObservers = [wakeToken, mountToken, unmountToken]
    }

    private func processJobStatusUpdates(_ statuses: [UUID: ConversionJobStatus]) {
        for (jobID, meta) in trackedJobs {
            guard let status = statuses[jobID] else { continue }
            switch status {
            case .waiting:
                break
            case .converting:
                transitionRecord(id: meta.recordID, to: .processing)
            case .completed(let result):
                let allOutputs = result.allOutputURLs
                for outURL in allOutputs {
                    recordGeneratedOutputProvenance(outURL)
                }
                inFlightFileKeys.remove(meta.fileKey)
                trackedJobs.removeValue(forKey: jobID)

                store.update { snap in
                    var map = snap.processedFingerprintsByRule[meta.ruleID] ?? [:]
                    map[meta.canonicalPath] = meta.fingerprint
                    snap.processedFingerprintsByRule[meta.ruleID] = map
                    if let rIdx = snap.rules.firstIndex(where: { $0.id == meta.ruleID }) {
                        snap.rules[rIdx].lastExecutionAt = Date()
                    }
                }
                syncFromStore()
                transitionRecord(
                    id: meta.recordID,
                    to: .completed,
                    outputPaths: allOutputs.map(\.path),
                    reason: "Converted -> \(result.outputURL.lastPathComponent)"
                )

            case .failed(let error):
                inFlightFileKeys.remove(meta.fileKey)
                trackedJobs.removeValue(forKey: jobID)
                StructuredDiagnostics.record(
                    category: .watchFolder,
                    severity: StructuredDiagnostics.severity(for: error),
                    stage: "executeRuleJob",
                    operationID: jobID.uuidString,
                    message: error.userFacingMessage
                )
                transitionRecord(
                    id: meta.recordID,
                    to: .failed,
                    reason: ErrorDetailsFormatter.sanitize(error.userFacingMessage)
                )

            case .cancelled:
                inFlightFileKeys.remove(meta.fileKey)
                trackedJobs.removeValue(forKey: jobID)
                transitionRecord(
                    id: meta.recordID,
                    to: .failed,
                    reason: "Conversion was cancelled."
                )
            }
        }
    }

    func validateActivePresetsAfterChange() {
        let validIDs = Set(presetManager.presets.map(\.id))
        for rule in rules where rule.isEnabled && !validIDs.contains(rule.presetID) {
            pauseRuleOnMissingPreset(
                ruleID: rule.id,
                message: "Selected preset was deleted. Edit this Watch Folder to select another preset."
            )
        }
    }

    func handleSystemWakeOrVolumeChange() {
        for rule in rules where rule.isEnabled {
            if !WatchFolderPathSafety.isExistingReadableDirectory(rule.inputDirectoryURL) {
                stopMonitorAndReleaseResources(for: rule.id)
                cancelPendingWork(for: rule.id)
                setRuleStatus(
                    ruleID: rule.id,
                    status: .error("Watched folder or external volume is currently unavailable."),
                    error: "Watched folder or external volume is currently unavailable."
                )
            } else if !rule.isPaused && !isGloballyPaused && monitors[rule.id] == nil {
                _ = startMonitoring(ruleID: rule.id)
            }
        }
    }

    // MARK: - Internal Helpers

    private func pauseRuleOnMissingPreset(ruleID: UUID, message: String) {
        stopMonitorAndReleaseResources(for: ruleID)
        cancelPendingWork(for: ruleID)
        store.update { snap in
            if let idx = snap.rules.firstIndex(where: { $0.id == ruleID }) {
                snap.rules[idx].isPaused = true
                snap.rules[idx].lastStatus = .error(message)
                snap.rules[idx].lastErrorMessage = message
                snap.rules[idx].modifiedAt = Date()
            }
        }
        syncFromStore()
    }

    private func handleMonitorError(_ message: String, for ruleID: UUID) {
        stopMonitorAndReleaseResources(for: ruleID)
        cancelPendingWork(for: ruleID)
        setRuleStatus(ruleID: ruleID, status: .error(message), error: message)
    }

    private func stopMonitorAndReleaseResources(for ruleID: UUID) {
        if let monitor = monitors.removeValue(forKey: ruleID) {
            monitor.stop()
        }
        if let scoped = securityScopedURLs.removeValue(forKey: ruleID) {
            for url in scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func cancelPendingWork(for ruleID: UUID) {
        let prefix = "\(ruleID.uuidString)|"
        for (key, task) in stabilityTasks where key.hasPrefix(prefix) {
            task.cancel()
            stabilityTasks.removeValue(forKey: key)
        }
        pendingStabilityQueue.removeAll { $0.ruleID == ruleID }
        inFlightFileKeys = inFlightFileKeys.filter { !$0.hasPrefix(prefix) }
    }

    private func computeExcludedCanonicalPrefixes(for rule: WatchFolderRule) -> [String] {
        var prefixes: [String] = []
        let (defaultLoc, customDir) = defaultOutputLocationProvider()
        let preset = presetManager.presets.first { $0.id == rule.presetID }
        let outDir = rule.outputDestination.resolvedDirectory(
            for: rule.inputDirectoryURL,
            preset: preset,
            defaultOutputLocation: defaultLoc,
            customAppOutputDirectory: customDir
        )
        let outCanonical = WatchFolderPathSafety.canonicalPath(for: outDir)
        let inCanonical = WatchFolderPathSafety.canonicalPath(for: rule.inputDirectoryURL)
        if outCanonical != inCanonical {
            prefixes.append(outCanonical)
        }

        // Also exclude other enabled Watch Folder roots nested inside this rule to avoid duplicate work
        for other in rules where other.id != rule.id && other.isEnabled {
            let otherCanonical = WatchFolderPathSafety.canonicalPath(for: other.inputDirectoryURL)
            if otherCanonical != inCanonical && WatchFolderPathSafety.isPath(otherCanonical, equalToOrInside: inCanonical) {
                prefixes.append(otherCanonical)
            }
        }
        return prefixes
    }

    private func recordGeneratedOutputProvenance(_ outputURL: URL) {
        let canonical = WatchFolderPathSafety.canonicalPath(for: outputURL)
        if !knownGeneratedOutputPaths.contains(canonical) {
            knownGeneratedOutputPaths.append(canonical)
            if knownGeneratedOutputPaths.count > Self.maxKnownOutputProvenance {
                knownGeneratedOutputPaths.removeFirst(knownGeneratedOutputPaths.count - Self.maxKnownOutputProvenance)
            }
        }
        if let fp = WatchFolderFileFingerprint.capture(for: outputURL),
           let resID = fp.resourceIdentifierBase64,
           !knownGeneratedResourceIDs.contains(resID) {
            knownGeneratedResourceIDs.append(resID)
            if knownGeneratedResourceIDs.count > Self.maxKnownOutputProvenance {
                knownGeneratedResourceIDs.removeFirst(knownGeneratedResourceIDs.count - Self.maxKnownOutputProvenance)
            }
        }
    }

    private func isKnownGeneratedOutput(canonicalPath: String, resourceID: String?) -> Bool {
        if knownGeneratedOutputPaths.contains(canonicalPath) {
            return true
        }
        if let resourceID, knownGeneratedResourceIDs.contains(resourceID) {
            return true
        }
        return false
    }

    private func setRuleStatus(ruleID: UUID, status: WatchFolderMonitoringStatus, error: String?) {
        store.update { snap in
            if let idx = snap.rules.firstIndex(where: { $0.id == ruleID }) {
                snap.rules[idx].lastStatus = status
                snap.rules[idx].lastErrorMessage = error
            }
        }
        syncFromStore()
    }

    @discardableResult
    private func upsertRecord(
        ruleID: UUID,
        url: URL,
        state: WatchFolderFileState,
        fingerprint: WatchFolderFileFingerprint?,
        reason: String?
    ) -> UUID {
        let stdPath = url.standardizedFileURL.path
        let newID = UUID()
        let record = WatchFolderFileRecord(
            id: newID,
            ruleID: ruleID,
            filePath: stdPath,
            fileName: url.lastPathComponent,
            state: state,
            fingerprint: fingerprint,
            reason: reason,
            updatedAt: Date()
        )
        store.update { snap in
            snap.recentRecords.insert(record, at: 0)
        }
        syncFromStore()
        return newID
    }

    private func transitionRecord(
        id: UUID,
        to nextState: WatchFolderFileState,
        fingerprint: WatchFolderFileFingerprint? = nil,
        jobID: UUID? = nil,
        outputPaths: [String]? = nil,
        reason: String? = nil
    ) {
        store.update { snap in
            guard let idx = snap.recentRecords.firstIndex(where: { $0.id == id }) else { return }
            let cur = snap.recentRecords[idx].state
            guard cur.canTransition(to: nextState) else { return }
            snap.recentRecords[idx].state = nextState
            if let fingerprint {
                snap.recentRecords[idx].fingerprint = fingerprint
            }
            if let jobID {
                snap.recentRecords[idx].jobID = jobID
            }
            if let outputPaths {
                snap.recentRecords[idx].outputPaths = outputPaths
            }
            if let reason {
                snap.recentRecords[idx].reason = reason
            }
            snap.recentRecords[idx].updatedAt = Date()
        }
        syncFromStore()
    }

    private func syncFromStore() {
        rules = store.snapshot.rules
        records = store.snapshot.recentRecords
    }

    private static func fileKey(ruleID: UUID, canonicalPath: String) -> String {
        "\(ruleID.uuidString)|\(canonicalPath)"
    }
}
