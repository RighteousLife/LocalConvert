import Foundation
import Combine

enum PreviousTrackAction: Sendable, Equatable {
    case restartCurrent
    case loadTrack(UUID)
    case stop
}

@MainActor
final class PlaybackQueueManager: ObservableObject {
    @Published private(set) var queue: PlaybackQueue

    init(initialQueue: PlaybackQueue = (try? PlaybackQueue())!) {
        self.queue = initialQueue
    }

    var currentTrackID: UUID? {
        queue.currentTrackID
    }

    var orderedTrackIDs: [UUID] {
        queue.activeOrderIDs
    }

    func restore(queue restoredQueue: PlaybackQueue) {
        self.queue = restoredQueue
    }

    func setQueue(trackIDs: [UUID], startIndex: Int? = nil) {
        let working = trackIDs
        let targetIdx: Int?
        if working.isEmpty {
            targetIdx = nil
        } else if let idx = startIndex, working.indices.contains(idx) {
            targetIdx = idx
        } else {
            targetIdx = 0
        }

        if queue.isShuffleEnabled, !working.isEmpty {
            let currentID = targetIdx.map { working[$0] }
            var remaining = working
            if let targetIdx {
                remaining.remove(at: targetIdx)
            }
            remaining.shuffle()
            let active = currentID.map { [$0] + remaining } ?? remaining
            queue = (try? PlaybackQueue(
                originalOrderIDs: working,
                activeOrderIDs: active,
                currentIndex: active.isEmpty ? nil : 0,
                repeatMode: queue.repeatMode,
                isShuffleEnabled: true
            )) ?? queue
        } else {
            queue = (try? PlaybackQueue(
                originalOrderIDs: working,
                activeOrderIDs: working,
                currentIndex: targetIdx,
                repeatMode: queue.repeatMode,
                isShuffleEnabled: false
            )) ?? queue
        }
    }

    func playNext(_ assetID: UUID) {
        var orig = queue.originalOrderIDs
        var active = queue.activeOrderIDs
        if active.isEmpty {
            setQueue(trackIDs: [assetID], startIndex: 0)
            return
        }
        let insertIdx = min(active.count, (queue.currentIndex ?? -1) + 1)
        active.insert(assetID, at: insertIdx)
        orig.append(assetID)
        queue = (try? PlaybackQueue(
            originalOrderIDs: orig,
            activeOrderIDs: active,
            currentIndex: queue.currentIndex,
            repeatMode: queue.repeatMode,
            isShuffleEnabled: queue.isShuffleEnabled
        )) ?? queue
    }

    func enqueue(_ assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        if queue.activeOrderIDs.isEmpty {
            setQueue(trackIDs: assetIDs, startIndex: 0)
            return
        }
        var orig = queue.originalOrderIDs
        var active = queue.activeOrderIDs
        orig.append(contentsOf: assetIDs)
        active.append(contentsOf: assetIDs)
        queue = (try? PlaybackQueue(
            originalOrderIDs: orig,
            activeOrderIDs: active,
            currentIndex: queue.currentIndex,
            repeatMode: queue.repeatMode,
            isShuffleEnabled: queue.isShuffleEnabled
        )) ?? queue
    }

    func selectTrack(at index: Int) -> UUID? {
        guard queue.activeOrderIDs.indices.contains(index) else { return nil }
        queue = (try? PlaybackQueue(
            originalOrderIDs: queue.originalOrderIDs,
            activeOrderIDs: queue.activeOrderIDs,
            currentIndex: index,
            repeatMode: queue.repeatMode,
            isShuffleEnabled: queue.isShuffleEnabled
        )) ?? queue
        return queue.currentTrackID
    }

    /// Removes the entry at `index` from active order. Returns whether the removed item was the currently active track.
    @discardableResult
    func remove(at index: Int) -> (removedCurrent: Bool, replacementID: UUID?) {
        guard queue.activeOrderIDs.indices.contains(index) else { return (false, nil) }
        var active = queue.activeOrderIDs
        let removedID = active.remove(at: index)
        var orig = queue.originalOrderIDs
        if let origIdx = orig.firstIndex(of: removedID) {
            orig.remove(at: origIdx)
        }

        let currentIdx = queue.currentIndex
        var removedCurrent = false
        let nextIndex: Int?
        if active.isEmpty {
            nextIndex = nil
            removedCurrent = (currentIdx != nil)
        } else if let currentIdx {
            if index < currentIdx {
                nextIndex = currentIdx - 1
            } else if index == currentIdx {
                removedCurrent = true
                nextIndex = min(index, active.count - 1)
            } else {
                nextIndex = currentIdx
            }
        } else {
            nextIndex = nil
        }

        queue = (try? PlaybackQueue(
            originalOrderIDs: orig,
            activeOrderIDs: active,
            currentIndex: nextIndex,
            repeatMode: queue.repeatMode,
            isShuffleEnabled: queue.isShuffleEnabled
        )) ?? queue
        return (removedCurrent, removedCurrent ? queue.currentTrackID : nil)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var active = queue.activeOrderIDs
        let currentTrackedIndex = queue.currentIndex
        var tagged: [(id: UUID, wasCurrent: Bool)] = active.enumerated().map { idx, id in
            (id, idx == currentTrackedIndex)
        }

        let validSource = IndexSet(source.filter { tagged.indices.contains($0) })
        let moving = validSource.map { tagged[$0] }
        for idx in validSource.sorted(by: >) {
            tagged.remove(at: idx)
        }
        let adjustedOffset = destination - validSource.filter { $0 < destination }.count
        let clampedOffset = max(0, min(adjustedOffset, tagged.count))
        tagged.insert(contentsOf: moving, at: clampedOffset)

        active = tagged.map(\.id)
        let newCurrentIdx = tagged.firstIndex(where: \.wasCurrent)
        let newOriginal = queue.isShuffleEnabled ? queue.originalOrderIDs : active

        queue = (try? PlaybackQueue(
            originalOrderIDs: newOriginal,
            activeOrderIDs: active,
            currentIndex: newCurrentIdx,
            repeatMode: queue.repeatMode,
            isShuffleEnabled: queue.isShuffleEnabled
        )) ?? queue
    }

    func clear() {
        queue = (try? PlaybackQueue(
            originalOrderIDs: [],
            activeOrderIDs: [],
            currentIndex: nil,
            repeatMode: queue.repeatMode,
            isShuffleEnabled: queue.isShuffleEnabled
        )) ?? queue
    }

    func setRepeatMode(_ mode: PlaybackRepeatMode) {
        queue.repeatMode = mode
    }

    func cycleRepeatMode() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
    }

    func setShuffleEnabled(_ enabled: Bool) {
        guard enabled != queue.isShuffleEnabled else { return }
        if enabled {
            let currentID = queue.currentTrackID
            var pool = queue.originalOrderIDs
            if let currentIdx = queue.currentIndex,
               queue.activeOrderIDs.indices.contains(currentIdx),
               let firstMatch = pool.firstIndex(of: queue.activeOrderIDs[currentIdx]) {
                pool.remove(at: firstMatch)
                pool.shuffle()
                let newActive = (currentID.map { [$0] } ?? []) + pool
                queue = (try? PlaybackQueue(
                    originalOrderIDs: queue.originalOrderIDs,
                    activeOrderIDs: newActive,
                    currentIndex: newActive.isEmpty ? nil : 0,
                    repeatMode: queue.repeatMode,
                    isShuffleEnabled: true
                )) ?? queue
            } else {
                pool.shuffle()
                queue = (try? PlaybackQueue(
                    originalOrderIDs: queue.originalOrderIDs,
                    activeOrderIDs: pool,
                    currentIndex: pool.isEmpty ? nil : 0,
                    repeatMode: queue.repeatMode,
                    isShuffleEnabled: true
                )) ?? queue
            }
        } else {
            let currentID = queue.currentTrackID
            let restoredIdx = currentID.flatMap { queue.originalOrderIDs.firstIndex(of: $0) }
                ?? (queue.originalOrderIDs.isEmpty ? nil : 0)
            queue = (try? PlaybackQueue(
                originalOrderIDs: queue.originalOrderIDs,
                activeOrderIDs: queue.originalOrderIDs,
                currentIndex: restoredIdx,
                repeatMode: queue.repeatMode,
                isShuffleEnabled: false
            )) ?? queue
        }
    }

    // MARK: - Progression Rules

    func peekNextTrackID() -> UUID? {
        let count = queue.activeOrderIDs.count
        guard count > 0 else { return nil }

        switch queue.repeatMode {
        case .one:
            let idx = queue.currentIndex ?? 0
            return queue.activeOrderIDs[min(idx, count - 1)]
        case .all:
            let nextIdx = ((queue.currentIndex ?? -1) + 1) % count
            return queue.activeOrderIDs[nextIdx]
        case .off:
            guard let cur = queue.currentIndex else { return nil }
            let nextIdx = cur + 1
            guard nextIdx < count else { return nil }
            return queue.activeOrderIDs[nextIdx]
        }
    }

    @discardableResult
    func commitGaplessAdvance(to expectedTrackID: UUID) -> Bool {
        guard peekNextTrackID() == expectedTrackID else { return false }
        return advanceOnTrackEnd() == expectedTrackID
    }

    func advanceOnTrackEnd() -> UUID? {
        let count = queue.activeOrderIDs.count
        guard count > 0 else { return nil }

        switch queue.repeatMode {
        case .one:
            let idx = queue.currentIndex ?? 0
            return selectTrack(at: min(idx, count - 1))
        case .all:
            let nextIdx = ((queue.currentIndex ?? -1) + 1) % count
            return selectTrack(at: nextIdx)
        case .off:
            guard let cur = queue.currentIndex else { return nil }
            let nextIdx = cur + 1
            guard nextIdx < count else {
                return nil
            }
            return selectTrack(at: nextIdx)
        }
    }

    func stepNext() -> UUID? {
        let count = queue.activeOrderIDs.count
        guard count > 0 else { return nil }

        let cur = queue.currentIndex ?? -1
        let nextIdx = cur + 1
        if nextIdx < count {
            return selectTrack(at: nextIdx)
        }
        if queue.repeatMode == .all {
            return selectTrack(at: 0)
        }
        return nil
    }

    func stepPrevious(elapsedSeconds: Double, restartThresholdSeconds: Double = 3.0) -> PreviousTrackAction {
        let count = queue.activeOrderIDs.count
        guard count > 0 else { return .stop }

        if elapsedSeconds > restartThresholdSeconds, queue.currentTrackID != nil {
            return .restartCurrent
        }

        let cur = queue.currentIndex ?? 0
        if cur > 0, let prevID = selectTrack(at: cur - 1) {
            return .loadTrack(prevID)
        }
        if queue.repeatMode == .all, let wrapID = selectTrack(at: count - 1) {
            return .loadTrack(wrapID)
        }
        return .restartCurrent
    }
}
