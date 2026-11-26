import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioPlayheadState: ObservableObject {
    @Published var playheadTime: TimeInterval = 0
}

@MainActor
final class AudioEditorStore: ObservableObject {

    @Published var project: AudioEditorProject
    let playheadState = AudioPlayheadState()
    private var _timelineStorage = TimelineState()
    private var lastPlayheadUIEmitTime: CFAbsoluteTime = 0

    var timeline: TimelineState {
        get { _timelineStorage }
        set {
            let old = _timelineStorage
            var oldStructural = old
            var newStructural = newValue
            oldStructural.playheadTime = 0
            newStructural.playheadTime = 0
            _timelineStorage = newValue

            if oldStructural != newStructural {
                objectWillChange.send()
            }
            if abs(old.playheadTime - newValue.playheadTime) > 0.0001 || newValue.playheadTime == 0 {
                let now = CFAbsoluteTimeGetCurrent()
                if !playbackEngine.isPlaying || (now - lastPlayheadUIEmitTime) >= (1.0 / 60.0) || newValue.playheadTime == 0 {
                    lastPlayheadUIEmitTime = now
                    playheadState.playheadTime = newValue.playheadTime
                }
            }
        }
    }
    @Published var selectedTrackID: UUID?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var selectedMarkerID: UUID?
    @Published var clipboard: [AudioClipboardItem] = []
    @Published var nudgeIncrement: TimeInterval = 0.05
    @Published var isDirty = false
    @Published var currentProjectURL: URL?
    @Published var recoverableAutosave: AudioAutosaveSnapshot?
    @Published var missingAssets: [AudioMediaReference] = []
    @Published var showMissingRelinkSheet = false
    @Published var showExportSheet = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isImporting = false

    // Analysis & Spectrum
    @Published var selectionStats: AudioRangeStats?
    @Published var spectrumBins: [Float] = []

    let playbackEngine = AudioPlaybackEngine()
    private let undoCoordinator: UndoRedoCoordinator
    private var autosaveTask: Task<Void, Never>?
    private var activeContinuousGroupID: UUID?
    private var continuousSnapshotBefore: AudioEditorProject?
    private var pendingUndoChain: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(undoCoordinator: UndoRedoCoordinator = .shared) {
        self.undoCoordinator = undoCoordinator
        var initial = AudioEditorProject()
        initial.tracks = [AudioTrack(name: "Track 1")]
        self.project = initial
        self.selectedTrackID = initial.tracks.first?.id

        // Register undo rehydrator for restart survival
        let rehydrator = AudioEditorUndoRehydrator { [weak self] restored in
            self?.applyRestoredProject(restored)
        }
        undoCoordinator.registerRehydrator(rehydrator)

        // Sync playhead updates from playback engine
        playbackEngine.onPlayheadChanged = { [weak self] time in
            guard let self else { return }
            self.timeline.setPlayhead(time)
        }

        // Mirror playbackEngine published properties except high-frequency playhead ticks
        playbackEngine.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.playheadState.playheadTime = self._timelineStorage.playheadTime
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Check for recoverable autosave
        self.recoverableAutosave = ProjectPersistenceService.latestRecoverableAutosave()
    }

    // MARK: - Focus & Context

    func setEditorFocused(_ focused: Bool) {
        undoCoordinator.setAudioEditorFocus(isActive: focused, projectID: project.id)
        if !focused {
            playbackEngine.pause()
        }
    }

    // MARK: - Selection Helpers

    var primarySelectedClip: AudioClip? {
        guard let firstID = selectedClipIDs.first else { return nil }
        return project.clip(firstID)
    }

    var primarySelectedTrack: AudioTrack? {
        if let tid = selectedTrackID, let t = project.tracks.first(where: { $0.id == tid }) {
            return t
        }
        return project.tracks.first
    }

    func selectTrack(_ trackID: UUID?) {
        selectedTrackID = trackID
    }

    func selectClip(_ clipID: UUID, additive: Bool = false) {
        if additive {
            if selectedClipIDs.contains(clipID) { selectedClipIDs.remove(clipID) }
            else { selectedClipIDs.insert(clipID) }
        } else {
            selectedClipIDs = [clipID]
        }
        if let ti = project.trackIndex(containingClip: clipID) {
            selectedTrackID = project.tracks[ti].id
        }
        refreshSpectrumAndStats()
    }

    func clearClipSelection() {
        selectedClipIDs.removeAll()
    }

    // MARK: - Transport Controls

    func togglePlayPause() {
        if playbackEngine.isPlaying || playbackEngine.isPreparing {
            playbackEngine.pause()
        } else if playbackEngine.isPaused {
            let restartFromZero = timeline.playheadTime >= project.duration && project.duration > 0
            playbackEngine.setLoop(range: timeline.loopRange ?? timeline.selectionRange, enabled: timeline.isLoopEnabled)
            if restartFromZero {
                playbackEngine.play(from: 0, project: project)
            } else {
                playbackEngine.resume(project: project)
            }
        } else {
            playFromCurrentPosition()
        }
    }

    func playFromCurrentPosition() {
        let start = timeline.playheadTime >= project.duration && project.duration > 0 ? 0 : timeline.playheadTime
        playbackEngine.setLoop(range: timeline.loopRange ?? timeline.selectionRange, enabled: timeline.isLoopEnabled)
        playbackEngine.play(from: start, project: project)
    }

    func playFromSelection() {
        let start = timeline.selectionRange?.lowerBound ?? timeline.playheadTime
        timeline.setPlayhead(start, maxTime: project.duration)
        playbackEngine.setLoop(range: timeline.loopRange ?? timeline.selectionRange, enabled: timeline.isLoopEnabled)
        playbackEngine.play(from: start, project: project)
    }

    func stopPlayback() {
        playbackEngine.stop()
    }

    func returnToBeginning() {
        seek(to: 0)
    }

    func skip(by delta: TimeInterval) {
        seek(to: max(0, min(project.duration, timeline.playheadTime + delta)))
    }

    func seek(to time: TimeInterval) {
        timeline.setPlayhead(time, maxTime: max(project.duration, time))
        playbackEngine.seek(to: timeline.playheadTime, project: project)
        refreshSpectrumAndStats()
    }

    func scrub(to time: TimeInterval) {
        timeline.setPlayhead(time, maxTime: max(project.duration, time))
        playbackEngine.scrub(to: timeline.playheadTime, project: project)
    }

    func toggleLoopSelection() {
        timeline.isLoopEnabled.toggle()
        if timeline.isLoopEnabled && timeline.loopRange == nil {
            timeline.loopRange = timeline.selectionRange
        }
        playbackEngine.setLoop(range: timeline.loopRange ?? timeline.selectionRange, enabled: timeline.isLoopEnabled)
    }

    func zoomIn(viewportWidth: Double) {
        timeline.zoom(by: 1.35, anchorTime: timeline.playheadTime)
        timeline.scroll(toKeep: timeline.playheadTime, viewportWidth: viewportWidth)
    }

    func zoomOut(viewportWidth: Double) {
        timeline.zoom(by: 1.0 / 1.35, anchorTime: timeline.playheadTime)
    }

    func fitProjectToWindow(viewportWidth: Double) {
        let dur = max(1.0, project.duration)
        timeline.fit(range: 0...dur, viewportWidth: max(200, viewportWidth))
    }

    func fitSelectionToWindow(viewportWidth: Double) {
        guard let sel = timeline.selectionRange else { return }
        timeline.fit(range: sel, viewportWidth: max(200, viewportWidth))
    }

    // MARK: - Undoable Mutation Engine

    func performMutation(
        type: UndoOperationType,
        title: String,
        transactionGroupID: UUID? = nil,
        _ mutate: (inout AudioEditorProject) -> Bool
    ) {
        let before = project
        var next = project
        guard mutate(&next), next != before else { return }
        applyAndRecord(before: before, after: next, type: type, title: title, groupID: transactionGroupID)
    }

    /// Starts a coalesced continuous gesture (slider drag / clip drag).
    func beginContinuousMutation() {
        if activeContinuousGroupID == nil {
            activeContinuousGroupID = UUID()
            continuousSnapshotBefore = project
        }
    }

    func updateContinuousMutation(
        type: UndoOperationType,
        title: String,
        _ mutate: (inout AudioEditorProject) -> Void
    ) {
        if activeContinuousGroupID == nil { beginContinuousMutation() }
        var next = project
        mutate(&next)
        guard next != project else { return }
        project = next
        isDirty = true
        playbackEngine.projectDidChange(next)
    }

    func endContinuousMutation(type: UndoOperationType, title: String) {
        guard let groupID = activeContinuousGroupID,
              let before = continuousSnapshotBefore else {
            activeContinuousGroupID = nil
            continuousSnapshotBefore = nil
            return
        }
        let after = project
        activeContinuousGroupID = nil
        continuousSnapshotBefore = nil
        guard after != before else { return }
        let cmd = AudioProjectMutationCommand(
            operationType: type,
            title: title,
            projectID: after.id,
            before: before,
            after: after,
            transactionGroupID: groupID,
            applyProject: { [weak self] restored in self?.applyRestoredProject(restored) }
        )
        enqueueUndoRecord(cmd)
        scheduleAutosave()
    }

    private func enqueueUndoRecord(_ cmd: any UndoableCommand) {
        let prev = pendingUndoChain
        let coordinator = undoCoordinator
        pendingUndoChain = Task { @MainActor in
            _ = await prev?.value
            await coordinator.record(cmd)
        }
    }

    func recordExportOutputsUndo(_ outputURLs: [URL], title: String = "Export Audio Mix") {
        guard !outputURLs.isEmpty else { return }
        let cmd = OutputCreationUndoCommand(
            title: title,
            context: .audioEditor(projectID: project.id),
            outputURLs: outputURLs,
            protectedSourceURLs: project.mediaAssets.map(\.url)
        )
        enqueueUndoRecord(cmd)
    }

    func flushPendingUndoRecords() async {
        await pendingUndoChain?.value
    }

    private func applyAndRecord(
        before: AudioEditorProject,
        after: AudioEditorProject,
        type: UndoOperationType,
        title: String,
        groupID: UUID?
    ) {
        project = after
        isDirty = true
        playbackEngine.projectDidChange(after)
        if let tid = selectedTrackID, !after.tracks.contains(where: { $0.id == tid }) {
            selectedTrackID = after.tracks.first?.id
        }
        let validClips = Set(after.tracks.flatMap(\.clips).map(\.id))
        selectedClipIDs = selectedClipIDs.intersection(validClips)

        let cmd = AudioProjectMutationCommand(
            operationType: type,
            title: title,
            projectID: after.id,
            before: before,
            after: after,
            transactionGroupID: groupID,
            applyProject: { [weak self] restored in self?.applyRestoredProject(restored) }
        )
        enqueueUndoRecord(cmd)
        scheduleAutosave()
        refreshSpectrumAndStats()
    }

    private func applyRestoredProject(_ restored: AudioEditorProject) {
        project = restored
        isDirty = true
        playbackEngine.projectDidChange(restored)
        if let tid = selectedTrackID, !restored.tracks.contains(where: { $0.id == tid }) {
            selectedTrackID = restored.tracks.first?.id
        }
        let validClips = Set(restored.tracks.flatMap(\.clips).map(\.id))
        selectedClipIDs = selectedClipIDs.intersection(validClips)
        missingAssets = ProjectPersistenceService.missingAssets(in: restored)
        scheduleAutosave()
        refreshSpectrumAndStats()
    }

    // MARK: - Media Import (Non-Destructive)

    func importAudioFiles(urls: [URL], targetTrackID: UUID? = nil, at startTime: TimeInterval? = nil) {
        let validURLs = urls.filter { url in
            guard let fmt = FileDetector.detectFormat(url: url) else { return false }
            return fmt.category == .audio || fmt.category == .video
        }
        guard !validURLs.isEmpty else {
            errorMessage = "No supported audio or video files found in selection."
            return
        }
        isImporting = true
        Task {
            var assets: [AudioMediaReference] = []
            for url in validURLs {
                if let asset = await Self.buildMediaReference(for: url) {
                    assets.append(asset)
                }
            }
            await MainActor.run {
                self.isImporting = false
                guard !assets.isEmpty else {
                    self.errorMessage = "Could not inspect selected audio file(s)."
                    return
                }
                self.performMutation(type: .clipImport, title: "Import \(assets.count) Audio File(s)") { p in
                    if p.tracks.isEmpty {
                        _ = AudioEditingService.addTrack(&p, name: "Track 1")
                    }
                    let trackID = targetTrackID ?? self.selectedTrackID ?? p.tracks[0].id
                    var cursor = startTime ?? p.tracks.first(where: { $0.id == trackID })?.clips.map(\.timelineEnd).max() ?? 0
                    var lastClipID: UUID?
                    for asset in assets {
                        if let cid = AudioEditingService.addClip(&p, asset: asset, trackID: trackID, at: cursor) {
                            cursor += asset.duration
                            lastClipID = cid
                        }
                    }
                    if let cid = lastClipID {
                        self.selectedClipIDs = [cid]
                        self.selectedTrackID = trackID
                    }
                    return true
                }
                self.statusMessage = "Imported \(assets.count) file(s)"
            }
        }
    }

    static func buildMediaReference(for url: URL) async -> AudioMediaReference? {
        let fp = AudioMediaReference.fingerprint(of: url)
        let sha = try? AudioMediaReference.sha256Hex(of: url)
        if let ffprobe = await BundledFFmpegProvider().findFFprobePath(),
           let info = try? await MediaProbe.probe(url: url, ffprobePath: ffprobe),
           let audio = info.primaryAudioStream {
            let srDouble = Double(audio.sampleRate ?? 48_000)
            let rate = (try? SampleFrameMigration.validatedSampleRate(srDouble)) ?? .rate48k
            let exactFrames = (try? AVAudioFile(forReading: url).length)
                ?? (try? SampleFrameMigration.secondsToFrames(max(0.01, info.duration), sampleRate: rate, field: "asset.duration"))
            return AudioMediaReference(
                id: UUID(),
                path: url.path,
                displayName: url.lastPathComponent,
                fileSize: fp.size,
                modificationTime: fp.mtime,
                duration: max(0.01, info.duration),
                sampleRate: srDouble,
                channels: max(1, audio.channels ?? 2),
                bookmarkData: nil,
                contentSHA256: sha,
                relativePath: nil,
                durationFrames: exactFrames
            )
        }
        if let af = try? AVAudioFile(forReading: url) {
            let sr = af.processingFormat.sampleRate
            let dur = sr > 0 ? Double(af.length) / sr : 0.01
            return AudioMediaReference(
                id: UUID(),
                path: url.path,
                displayName: url.lastPathComponent,
                fileSize: fp.size,
                modificationTime: fp.mtime,
                duration: max(0.01, dur),
                sampleRate: sr > 0 ? sr : 48_000,
                channels: Int(af.processingFormat.channelCount),
                bookmarkData: nil,
                contentSHA256: sha,
                relativePath: nil,
                durationFrames: af.length
            )
        }
        return nil
    }

    // MARK: - Track & Clip Editing Actions

    func addTrack() {
        performMutation(type: .trackAdd, title: "Add Track") { p in
            let tid = AudioEditingService.addTrack(&p)
            self.selectedTrackID = tid
            return true
        }
    }

    func removeTrack(_ trackID: UUID) {
        performMutation(type: .trackDelete, title: "Delete Track") { p in
            AudioEditingService.removeTrack(&p, trackID: trackID)
        }
    }

    func moveTrack(_ trackID: UUID, offset: Int) {
        guard let idx = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let dest = idx + offset
        performMutation(type: .trackReorder, title: "Reorder Track") { p in
            AudioEditingService.moveTrack(&p, from: idx, to: dest)
        }
    }

    func toggleTrackMute(_ trackID: UUID) {
        performMutation(type: .trackMixChange, title: "Toggle Track Mute") { p in
            guard let i = p.tracks.firstIndex(where: { $0.id == trackID }) else { return false }
            p.tracks[i].isMuted.toggle()
            return true
        }
    }

    func toggleTrackSolo(_ trackID: UUID) {
        performMutation(type: .trackMixChange, title: "Toggle Track Solo") { p in
            guard let i = p.tracks.firstIndex(where: { $0.id == trackID }) else { return false }
            p.tracks[i].isSolo.toggle()
            return true
        }
    }

    func toggleTrackLock(_ trackID: UUID) {
        performMutation(type: .trackMixChange, title: "Toggle Track Lock") { p in
            guard let i = p.tracks.firstIndex(where: { $0.id == trackID }) else { return false }
            p.tracks[i].isLocked.toggle()
            return true
        }
    }

    func splitAtPlayhead() {
        let t = timeline.playheadTime
        let targetTracks = selectedClipIDs.isEmpty ? nil : Set(project.tracks.filter { $0.clips.contains { selectedClipIDs.contains($0.id) } }.map(\.id))
        performMutation(type: .clipSplit, title: "Split at Playhead") { p in
            AudioEditingService.splitAll(&p, at: t, trackIDs: targetTracks)
        }
    }

    func splitAtSelection() {
        guard let range = timeline.selectionRange else { return }
        let targetTracks = selectedTrackID.map { Set([$0]) }
        performMutation(type: .clipSplit, title: "Split at Selection") { p in
            AudioEditingService.splitAtSelection(&p, range: range, trackIDs: targetTracks)
        }
    }

    func trimToSelection() {
        guard let range = timeline.selectionRange else { return }
        performMutation(type: .clipTrim, title: "Trim to Selection") { p in
            AudioEditingService.trimToSelection(&p, range: range)
        }
    }

    func deleteSelectionOrClips(ripple: Bool) {
        if !selectedClipIDs.isEmpty {
            let ids = selectedClipIDs
            performMutation(type: ripple ? .clipRippleDelete : .clipDelete,
                            title: ripple ? "Ripple Delete Clips" : "Delete Clips") { p in
                AudioEditingService.deleteClips(&p, ids: ids, ripple: ripple)
            }
        } else if let range = timeline.selectionRange {
            performMutation(type: ripple ? .clipRippleDelete : .clipDelete,
                            title: ripple ? "Ripple Delete Range" : "Delete Range") { p in
                AudioEditingService.deleteRange(&p, range: range, trackIDs: nil, ripple: ripple)
            }
            timeline.selectionRange = nil
        } else if let markerID = selectedMarkerID {
            deleteMarker(id: markerID)
        }
    }

    func copySelectedClips() {
        guard !selectedClipIDs.isEmpty else { return }
        clipboard = AudioEditingService.copy(project, ids: selectedClipIDs)
        statusMessage = "Copied \(clipboard.count) clip(s)"
    }

    func cutSelectedClips() {
        guard !selectedClipIDs.isEmpty else { return }
        clipboard = AudioEditingService.copy(project, ids: selectedClipIDs)
        let ids = selectedClipIDs
        performMutation(type: .clipDelete, title: "Cut Clips") { p in
            AudioEditingService.deleteClips(&p, ids: ids, ripple: false)
        }
    }

    func pasteAtPlayhead() {
        guard !clipboard.isEmpty else { return }
        let startTrack = selectedTrackID.flatMap { tid in project.tracks.firstIndex(where: { $0.id == tid }) } ?? 0
        let t = timeline.playheadTime
        let items = clipboard
        performMutation(type: .clipImport, title: "Paste Clips") { p in
            let pasted = AudioEditingService.paste(&p, items: items, at: t, startTrackIndex: startTrack)
            if !pasted.isEmpty { self.selectedClipIDs = Set(pasted) }
            return !pasted.isEmpty
        }
    }

    func duplicateSelectedClips() {
        guard !selectedClipIDs.isEmpty else { return }
        let ids = selectedClipIDs
        performMutation(type: .clipDuplicate, title: "Duplicate Clips") { p in
            let added = AudioEditingService.duplicate(&p, ids: ids)
            if !added.isEmpty { self.selectedClipIDs = Set(added) }
            return !added.isEmpty
        }
    }

    func consolidateSelectedClips() {
        guard selectedClipIDs.count >= 2 else { return }
        let ids = selectedClipIDs
        performMutation(type: .clipConsolidate, title: "Consolidate Clips") { p in
            AudioEditingService.consolidate(&p, ids: ids) > 0
        }
    }

    func insertSilence(duration: TimeInterval = 1.0) {
        guard let tid = primarySelectedTrack?.id else { return }
        let t = timeline.playheadTime
        performMutation(type: .clipImport, title: "Insert Silence") { p in
            guard let cid = AudioEditingService.insertSilence(&p, trackID: tid, at: t, duration: duration) else { return false }
            self.selectedClipIDs = [cid]
            return true
        }
    }

    func nudgeSelectedClips(direction: Double) {
        guard !selectedClipIDs.isEmpty else { return }
        let ids = selectedClipIDs
        let delta = direction * nudgeIncrement
        performMutation(type: .clipMove, title: delta >= 0 ? "Nudge Right" : "Nudge Left") { p in
            AudioEditingService.nudge(&p, ids: ids, by: delta)
        }
    }

    func replaceClip(_ clipID: UUID, with url: URL) {
        Task {
            guard let asset = await Self.buildMediaReference(for: url) else {
                await MainActor.run { self.errorMessage = "Could not load replacement audio file." }
                return
            }
            await MainActor.run {
                self.performMutation(type: .clipReplace, title: "Replace Clip") { p in
                    AudioEditingService.replaceClip(&p, clipID: clipID, with: asset)
                }
            }
        }
    }

    // MARK: - Timeline Marker Management

    var selectedMarker: AudioMarker? {
        guard let id = selectedMarkerID else { return nil }
        return project.markers.first(where: { $0.id == id })
    }

    @discardableResult
    func addMarker(at time: TimeInterval? = nil, name: String? = nil, id: UUID = UUID()) -> AudioMarker? {
        let targetTime = time ?? timeline.playheadTime
        var created: AudioMarker?
        performMutation(type: .markerAdd, title: "Add Marker") { p in
            let marker = AudioEditingService.addMarker(&p, id: id, at: targetTime, name: name)
            created = marker
            return true
        }
        if let created {
            selectedMarkerID = created.id
        }
        return created
    }

    @discardableResult
    func addMarkerAtPlayhead(name: String? = nil) -> AudioMarker? {
        addMarker(at: timeline.playheadTime, name: name)
    }

    func renameMarker(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        performMutation(type: .markerRename, title: "Rename Marker to \"\(trimmed)\"") { p in
            AudioEditingService.renameMarker(&p, id: id, newName: trimmed)
        }
    }

    func moveMarker(id: UUID, to newTime: TimeInterval, snapToGrid: Bool = false) {
        let targetTime = snapToGrid ? snapTimeIfEnabled(newTime) : newTime
        performMutation(type: .markerMove, title: "Move Marker") { p in
            AudioEditingService.moveMarker(&p, id: id, to: targetTime)
        }
    }

    func beginMarkerDrag(id: UUID) {
        selectedMarkerID = id
        beginContinuousMutation()
    }

    func updateMarkerDrag(id: UUID, to rawTime: TimeInterval, snapToGrid: Bool = false) {
        let targetTime = snapToGrid ? snapTimeIfEnabled(rawTime) : rawTime
        updateContinuousMutation(type: .markerMove, title: "Move Marker") { p in
            _ = AudioEditingService.moveMarker(&p, id: id, to: targetTime)
        }
    }

    func endMarkerDrag(id: UUID) {
        _ = id
        endContinuousMutation(type: .markerMove, title: "Move Marker")
    }

    func deleteMarker(id: UUID) {
        let markerName = project.markers.first(where: { $0.id == id })?.name
        performMutation(
            type: .markerDelete,
            title: markerName.map { "Delete Marker \"\($0)\"" } ?? "Delete Marker"
        ) { p in
            AudioEditingService.deleteMarker(&p, id: id)
        }
        if selectedMarkerID == id {
            selectedMarkerID = nil
        }
    }

    func deleteSelectedMarker() {
        guard let id = selectedMarkerID else { return }
        deleteMarker(id: id)
    }

    func selectAndSeekToMarker(id: UUID) {
        guard let marker = project.markers.first(where: { $0.id == id }) else { return }
        selectedMarkerID = marker.id
        seek(to: marker.time)
    }

    // MARK: - Project Persistence & Recovery

    func newProject() {
        playbackEngine.stop()
        var fresh = AudioEditorProject()
        fresh.tracks = [AudioTrack(name: "Track 1")]
        project = fresh
        timeline = TimelineState()
        selectedTrackID = fresh.tracks.first?.id
        selectedClipIDs.removeAll()
        currentProjectURL = nil
        isDirty = false
        missingAssets = []
        statusMessage = nil
        errorMessage = nil
        undoCoordinator.setAudioEditorFocus(isActive: true, projectID: fresh.id)
    }

    func saveProject(to url: URL, selfContainedPackage: Bool = false) {
        do {
            let (saved, canonicalURL) = try ProjectPersistenceService.saveReturningURL(
                project: project,
                to: url,
                selfContainedPackage: selfContainedPackage
            )
            project = saved
            currentProjectURL = canonicalURL
            isDirty = false
            ProjectPersistenceService.clearAutosave(for: project.id)
            recoverableAutosave = nil
            statusMessage = "Saved \(canonicalURL.lastPathComponent)"
        } catch {
            errorMessage = "Failed to save project: \(error.localizedDescription)"
        }
    }

    func openProject(from url: URL) {
        playbackEngine.stop()
        statusMessage = nil
        errorMessage = nil
        do {
            let (loaded, missing) = try ProjectPersistenceService.load(from: url)
            project = loaded
            timeline = TimelineState()
            selectedTrackID = loaded.tracks.first?.id
            selectedClipIDs.removeAll()
            currentProjectURL = url
            isDirty = false
            missingAssets = missing
            showMissingRelinkSheet = !missing.isEmpty
            undoCoordinator.setAudioEditorFocus(isActive: true, projectID: loaded.id)
            statusMessage = "Opened \(url.lastPathComponent)"
        } catch {
            errorMessage = "Failed to open project: \(error.localizedDescription)"
        }
    }

    func restoreRecoverableAutosave() {
        guard let snap = recoverableAutosave else { return }
        playbackEngine.stop()
        project = snap.project
        currentProjectURL = snap.projectFileURLPath.map { URL(fileURLWithPath: $0) }
        selectedTrackID = snap.project.tracks.first?.id
        selectedClipIDs.removeAll()
        isDirty = true
        missingAssets = ProjectPersistenceService.missingAssets(in: snap.project)
        showMissingRelinkSheet = !missingAssets.isEmpty
        recoverableAutosave = nil
        undoCoordinator.setAudioEditorFocus(isActive: true, projectID: snap.project.id)
        statusMessage = "Recovered unsaved project session"
    }

    func discardRecoverableAutosave() {
        if let snap = recoverableAutosave {
            ProjectPersistenceService.clearAutosave(for: snap.projectID)
        }
        recoverableAutosave = nil
    }

    func relinkMissingAsset(assetID: UUID, newURL: URL) {
        Task {
            await relinkMissingAssetAsync(assetID: assetID, newURL: newURL)
        }
    }

    func relinkMissingAssetAsync(assetID: UUID, newURL: URL) async {
        let probed = await Self.buildMediaReference(for: newURL)
        performMutation(type: .clipReplace, title: "Relink Source Media") { p in
            ProjectPersistenceService.relinkAsset(
                in: &p,
                assetID: assetID,
                newURL: newURL,
                duration: probed?.duration,
                sampleRate: probed?.sampleRate,
                channels: probed?.channels
            )
        }
        missingAssets = ProjectPersistenceService.missingAssets(in: project)
        if missingAssets.isEmpty { showMissingRelinkSheet = false }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let snapshot = project
        let fileURL = currentProjectURL
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            try? ProjectPersistenceService.writeAutosave(project: snapshot, projectFileURL: fileURL)
        }
    }

    // MARK: - Analysis & Spectrum

    func refreshSpectrumAndStats() {
        guard let clip = primarySelectedClip ?? project.tracks.flatMap(\.clips).first,
              let asset = project.asset(clip.sourceAssetID) else {
            spectrumBins = []
            selectionStats = nil
            return
        }
        let localTime = max(0, min(clip.sourceSpan, (timeline.playheadTime - clip.timelineStart) * clip.stretch + clip.sourceStart))
        let sel = timeline.selectionRange
        Task {
            let bins = await SpectrumAnalyzerService.spectrum(asset: asset, at: localTime)
            let stats: AudioRangeStats?
            if let sel {
                let dur = sel.upperBound - sel.lowerBound
                let start = max(0, (sel.lowerBound - clip.timelineStart) * clip.stretch + clip.sourceStart)
                stats = try? await WaveformRenderingService.shared.measure(asset: asset, from: start, duration: min(dur, clip.sourceSpan))
            } else {
                stats = try? await WaveformRenderingService.shared.measure(asset: asset, from: clip.sourceStart, duration: clip.sourceSpan)
            }
            await MainActor.run {
                self.spectrumBins = bins
                self.selectionStats = stats
            }
        }
    }

    // MARK: - Grid Snapping, Crossfades, Track Grouping & Normalization (Phase 45.1 / 45.2)

    func toggleGridSnap() {
        performMutation(type: .clipMove, title: project.gridConfig.snapEnabled ? "Disable Grid Snap" : "Enable Grid Snap") { p in
            p.gridConfig.snapEnabled.toggle()
            return true
        }
    }

    func setGridInterval(_ interval: TimelineSnapInterval) {
        performMutation(type: .clipMove, title: "Grid Interval \(interval.rawValue)") { p in
            guard p.gridConfig.interval != interval else { return false }
            p.gridConfig.interval = interval
            return true
        }
    }

    func setGridBPM(_ bpm: Double) {
        let clamped = min(300.0, max(30.0, bpm))
        performMutation(type: .clipMove, title: "Set Tempo \(Int(clamped)) BPM") { p in
            guard abs(p.gridConfig.bpm - clamped) > 0.01 else { return false }
            p.gridConfig.bpm = clamped
            return true
        }
    }

    func snapTimeIfEnabled(_ time: TimeInterval) -> TimeInterval {
        project.gridConfig.snap(time)
    }

    func applyCrossfadeNearSelectedClip(duration: TimeInterval = 0.25, curve: ClipFadeCurve = .equalPower) {
        guard let cid = primarySelectedClip?.id else { return }
        performMutation(type: .clipFadeChange, title: "Apply Crossfade") { p in
            AudioEditingService.applyCrossfadeNearClip(&p, clipID: cid, duration: duration, curve: curve)
        }
    }

    func applyCrossfade(leftClipID: UUID, rightClipID: UUID, duration: TimeInterval = 0.25, curve: ClipFadeCurve = .equalPower) {
        performMutation(type: .clipFadeChange, title: "Apply Crossfade") { p in
            AudioEditingService.applyCrossfade(&p, leftClipID: leftClipID, rightClipID: rightClipID, duration: duration, curve: curve)
        }
    }

    func createTrackGroup(name: String, trackIDs: [UUID]) {
        performMutation(type: .trackMixChange, title: "Create Track Group") { p in
            AudioEditingService.createTrackGroup(&p, name: name, trackIDs: trackIDs) != nil
        }
    }

    func assignTrack(_ trackID: UUID, toGroupID groupID: UUID?) {
        performMutation(type: .trackMixChange, title: groupID == nil ? "Ungroup Track" : "Assign Track to Group") { p in
            AudioEditingService.assignTrack(&p, trackID: trackID, toGroupID: groupID)
        }
    }

    func toggleGroupMute(_ groupID: UUID) {
        performMutation(type: .trackMixChange, title: "Toggle Group Mute") { p in
            AudioEditingService.toggleGroupMute(&p, groupID: groupID)
        }
    }

    func toggleGroupSolo(_ groupID: UUID) {
        performMutation(type: .trackMixChange, title: "Toggle Group Solo") { p in
            AudioEditingService.toggleGroupSolo(&p, groupID: groupID)
        }
    }

    func selectClipsInGroup(_ groupID: UUID) {
        let ids = project.tracks.filter { $0.groupID == groupID }.flatMap { $0.clips.map(\.id) }
        selectedClipIDs = Set(ids)
    }

    func moveGroupClips(groupID: UUID, by delta: TimeInterval) {
        performMutation(type: .clipMove, title: "Move Track Group") { p in
            AudioEditingService.moveGroupClips(&p, groupID: groupID, by: delta)
        }
    }

    func normalizeSelectedClip(mode: AudioEditorNormalizeMethod) {
        guard let clip = primarySelectedClip,
              project.asset(clip.sourceAssetID) != nil else { return }
        let snapProj = project
        Task {
            do {
                let sources = try await AudioSourceResolver.resolve(project: snapProj, onlyClips: [clip.id])
                guard let src = sources[clip.id] else { return }
                let gainDB: Double? = try await Task.detached(priority: .userInitiated) {
                    let file = try AVAudioFile(forReading: src.url)
                    let sr = file.processingFormat.sampleRate
                    let totalFrames = AVAudioFrameCount(max(1, Int((clip.duration * sr).rounded())))
                    file.framePosition = src.baseFrame
                    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return nil }
                    var leftAll: [Float] = []
                    var rightAll: [Float] = []
                    leftAll.reserveCapacity(Int(totalFrames))
                    rightAll.reserveCapacity(Int(totalFrames))
                    var readSoFar: AVAudioFrameCount = 0
                    while readSoFar < totalFrames {
                        let chunk = min(8192, totalFrames - readSoFar)
                        buf.frameLength = 0
                        try file.read(into: buf, frameCount: chunk)
                        guard buf.frameLength > 0, let data = buf.floatChannelData else { break }
                        let got = Int(buf.frameLength)
                        let ch = Int(file.processingFormat.channelCount)
                        leftAll.append(contentsOf: UnsafeBufferPointer(start: data[0], count: got))
                        rightAll.append(contentsOf: UnsafeBufferPointer(start: ch > 1 ? data[1] : data[0], count: got))
                        readSoFar += AVAudioFrameCount(got)
                    }
                    // Include active native clip effect slots identically to playback/export
                    if clip.effectSlots.contains(where: \.isActive), !leftAll.isEmpty {
                        let proc = AudioChainProcessor(slots: clip.effectSlots, sampleRate: sr)
                        leftAll.withUnsafeMutableBufferPointer { lb in
                            rightAll.withUnsafeMutableBufferPointer { rb in
                                if let lp = lb.baseAddress, let rp = rb.baseAddress {
                                    proc.process(slots: clip.effectSlots, left: lp, right: rp, frameCount: lb.count)
                                }
                            }
                        }
                    }
                    let m = AudioNormalizer.measure(samplesLeft: leftAll, samplesRight: rightAll)
                    return AudioNormalizer.normalizationGainDB(measurement: m, mode: mode)
                }.value

                await MainActor.run {
                    guard let gainDB else {
                        self.statusMessage = "Clip is silent; normalize skipped."
                        return
                    }
                    let label = {
                        switch mode {
                        case .peak(let t): return String(format: "Peak Normalize (%.1f dBFS)", t)
                        case .rms(let t): return String(format: "RMS Normalize (%.1f dBFS)", t)
                        }
                    }()
                    self.performMutation(type: .clipGainPanChange, title: label) { p in
                        AudioEditingService.mutateClip(&p, clipID: clip.id) { $0.gainDB = min(24.0, max(-36.0, gainDB)) }
                    }
                }
            } catch {
                await MainActor.run { self.errorMessage = "Normalize failed: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Ordered Effect Chains & Presets (Phase 45.3)

    func effectSlots(for target: AudioEffectChainTarget) -> [AudioEffectSlot] {
        switch target {
        case .clip(let cid):
            return project.clip(cid)?.effectSlots ?? []
        case .track(let tid):
            return project.tracks.first(where: { $0.id == tid })?.effectSlots ?? []
        case .master:
            return project.masterEffects
        }
    }

    private func mutateSlots(in p: inout AudioEditorProject, target: AudioEffectChainTarget, _ body: (inout [AudioEffectSlot]) -> Bool) -> Bool {
        switch target {
        case .clip(let cid):
            return AudioEditingService.mutateClip(&p, clipID: cid) { clip in
                _ = body(&clip.effectSlots)
            }
        case .track(let tid):
            guard let idx = p.tracks.firstIndex(where: { $0.id == tid }), !p.tracks[idx].isLocked else { return false }
            return body(&p.tracks[idx].effectSlots)
        case .master:
            return body(&p.masterEffects)
        }
    }

    func addEffectSlot(_ kind: AudioEffectKind, to target: AudioEffectChainTarget) {
        let slot = AudioEffectSlot.makeDefault(kind: kind)
        performMutation(type: .clipEffectChange, title: "Add \(kind.rawValue)") { p in
            mutateSlots(in: &p, target: target) { slots in
                slots.append(slot)
                return true
            }
        }
    }

    func removeEffectSlot(id: UUID, from target: AudioEffectChainTarget) {
        performMutation(type: .clipEffectChange, title: "Remove Effect") { p in
            mutateSlots(in: &p, target: target) { slots in
                let before = slots.count
                slots.removeAll { $0.id == id }
                return slots.count != before
            }
        }
    }

    func moveEffectSlot(id: UUID, offset: Int, in target: AudioEffectChainTarget) {
        performMutation(type: .clipEffectChange, title: "Reorder Effects") { p in
            mutateSlots(in: &p, target: target) { slots in
                guard let idx = slots.firstIndex(where: { $0.id == id }) else { return false }
                let dest = idx + offset
                guard slots.indices.contains(dest) else { return false }
                slots.swapAt(idx, dest)
                return true
            }
        }
    }

    func updateEffectSlot(
        id: UUID,
        in target: AudioEffectChainTarget,
        continuous: Bool = false,
        title: String = "Update Effect",
        _ body: (inout AudioEffectSlot) -> Void
    ) {
        if continuous {
            updateContinuousMutation(type: .clipEffectChange, title: title) { p in
                _ = mutateSlots(in: &p, target: target) { slots in
                    guard let i = slots.firstIndex(where: { $0.id == id }) else { return false }
                    body(&slots[i])
                    return true
                }
            }
        } else {
            performMutation(type: .clipEffectChange, title: title) { p in
                mutateSlots(in: &p, target: target) { slots in
                    guard let i = slots.firstIndex(where: { $0.id == id }) else { return false }
                    body(&slots[i])
                    return true
                }
            }
        }
    }

    func applyEffectChainPreset(
        _ preset: AudioEffectChainPreset,
        to target: AudioEffectChainTarget,
        presetStore: AudioEffectPresetStore = .shared
    ) {
        let newSlots = presetStore.instantiatedSlots(for: preset)
        performMutation(type: .presetApply, title: "Apply Preset: \(preset.name)") { p in
            mutateSlots(in: &p, target: target) { slots in
                slots = newSlots
                return true
            }
        }
    }

    func captureNoiseProfileForSlot(id: UUID, in target: AudioEffectChainTarget) {
        guard let clip = primarySelectedClip,
              project.asset(clip.sourceAssetID) != nil else {
            errorMessage = "Select an audio clip first to capture a noise profile."
            return
        }
        let sampleRange = timeline.selectionRange ?? (clip.timelineStart...(min(clip.timelineEnd, clip.timelineStart + 0.6)))
        let snapProj = project
        Task {
            do {
                let sources = try await AudioSourceResolver.resolve(project: snapProj, onlyClips: [clip.id])
                guard let src = sources[clip.id] else { return }
                let profile: [Float] = try await Task.detached(priority: .userInitiated) {
                    let file = try AVAudioFile(forReading: src.url)
                    let sr = file.processingFormat.sampleRate
                    let relStart = max(0, sampleRange.lowerBound - clip.timelineStart)
                    let dur = max(0.05, min(2.0, sampleRange.upperBound - sampleRange.lowerBound))
                    let startFrame = src.baseFrame + Int64((relStart * sr).rounded())
                    let maxSamples = max(1024, Int((sr * 2.0).rounded()))
                    let rawSamples = max(1024, Int((dur * sr).rounded()))
                    let reqFrames = AVAudioFrameCount(min(maxSamples, rawSamples))
                    guard startFrame < file.length,
                          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: reqFrames) else {
                        return []
                    }
                    file.framePosition = startFrame
                    try file.read(into: buf, frameCount: reqFrames)
                    guard buf.frameLength > 0, let data = buf.floatChannelData else { return [] }
                    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buf.frameLength)))
                    return SpectralNoiseReductionDSP.captureNoiseProfile(fromMonoSamples: samples)
                }.value

                await MainActor.run {
                    guard !profile.isEmpty else {
                        self.errorMessage = "Selected range too short for spectral noise profile capture."
                        return
                    }
                    self.updateEffectSlot(id: id, in: target, continuous: false, title: "Capture Noise Profile") { slot in
                        var nr = slot.noiseReduction ?? NoiseReductionParams()
                        nr.noiseProfile = profile
                        slot.noiseReduction = nr
                    }
                    self.statusMessage = "Captured spectral noise profile (\(profile.count) bins)."
                }
            } catch {
                await MainActor.run { self.errorMessage = "Noise profile capture failed: \(error.localizedDescription)" }
            }
        }
    }
}
