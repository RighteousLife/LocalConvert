import SwiftUI
import UniformTypeIdentifiers

struct StereoWaveformClipView: View {
    @ObservedObject var store: AudioEditorStore
    let track: AudioTrack
    let trackIndex: Int
    let clip: AudioClip
    let rowHeight: CGFloat
    let pixelsPerSecond: Double
    let viewportWidth: Double

    @State private var pyramid: WaveformPyramid?
    @State private var cachedPlan: WaveformCanvasSamplingPlan?
    @State private var expandMultichannel = false
    @State private var dragBaseStart: TimeInterval?
    @State private var dragLastGroupDelta: TimeInterval = 0
    @State private var trimLeftSnapshot: (start: TimeInterval, end: TimeInterval)?
    @State private var trimRightSnapshot: (start: TimeInterval, end: TimeInterval)?
    @State private var isHovering = false

    private var isSelected: Bool { store.selectedClipIDs.contains(clip.id) }
    private var clipWidth: CGFloat { max(8, CGFloat(clip.duration * pixelsPerSecond)) }
    private var asset: AudioMediaReference? { store.project.asset(clip.sourceAssetID) }

    private struct PlanCacheKey: Equatable {
        let cacheKey: String?
        let bucketCount0: Int
        let completedFrames: Int64
        let sourceStart: Int64
        let sourceSpan: Int64
        let pps: Double
        let viewportWidth: Double
    }

    private var planCacheKey: PlanCacheKey {
        PlanCacheKey(
            cacheKey: pyramid?.cacheKey,
            bucketCount0: pyramid?.levels.first?.bucketCount ?? 0,
            completedFrames: pyramid?.completedFrames ?? 0,
            sourceStart: clip.sourceStartFrame,
            sourceSpan: clip.sourceSpanFrames,
            pps: pixelsPerSecond,
            viewportWidth: viewportWidth
        )
    }

    private func recomputeCachedPlan() {
        guard let pyramid else {
            cachedPlan = nil
            return
        }
        cachedPlan = WaveformCanvasRenderer.makeSamplingPlan(
            pyramid: pyramid,
            clipSourceStartFrame: clip.sourceStartFrame,
            clipSourceSpanFrames: clip.sourceSpanFrames,
            sampleRate: pyramid.sampleRate,
            pixelsPerSecond: pixelsPerSecond,
            viewportWidth: viewportWidth
        )
    }

    var body: some View {
        let plan = cachedPlan
        ZStack(alignment: .topLeading) {
            // Clip background
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                .fill(clip.isMuted ? AppTheme.Colors.neutralTint.opacity(0.6) : (isSelected ? AppTheme.Colors.accent.opacity(0.22) : AppTheme.Colors.info.opacity(0.16)))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .stroke(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder, lineWidth: isSelected ? 2 : 1)
                )

            // Peak-Pyramid Canvas Waveform (Equatable -> immune to 60 Hz playhead motion)
            WaveformClipCanvasView(
                pyramid: pyramid,
                hasSourceAsset: clip.sourceAssetID != nil,
                clipSourceStartFrame: clip.sourceStartFrame,
                clipSourceSpanFrames: clip.sourceSpanFrames,
                clipDurationSeconds: clip.duration,
                isMuted: clip.isMuted,
                isReversed: clip.isReversed,
                expandMultichannel: expandMultichannel,
                fadeIn: clip.fadeIn,
                fadeOut: clip.fadeOut,
                pixelsPerSecond: pixelsPerSecond,
                viewportWidth: viewportWidth,
                precomputedPlan: plan,
                onPlanComputed: nil
            )
            .equatable()
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))

            // Clip Title & Status Badges (color always paired with icon/text)
            HStack(spacing: 4) {
                Text(clip.name)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if clip.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(AppTheme.Colors.warning)
                        .accessibilityLabel("Locked")
                }
                if clip.isReversed {
                    Image(systemName: "arrow.uturn.left")
                        .font(.system(size: 8))
                        .foregroundStyle(AppTheme.Colors.info)
                        .accessibilityLabel("Reversed")
                }
                if !clip.effects.isIdentity || !clip.effectSlots.isEmpty {
                    Image(systemName: "fx")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.accent)
                        .accessibilityLabel("Effects Active")
                }
                if clip.isMuted {
                    Label("MUTED", systemImage: "speaker.slash.fill")
                        .labelStyle(.titleOnly)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.warning)
                }
                if let plan, plan.clippedBucketCount > 0 {
                    Label("CLIP", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.error)
                        .help("Clipped samples detected")
                }
                if let chCount = pyramid?.channelCount, chCount > 2 {
                    Button {
                        expandMultichannel.toggle()
                    } label: {
                        Label("\(chCount)ch", systemImage: expandMultichannel ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.info)
                    }
                    .buttonStyle(.plain)
                    .help(expandMultichannel ? "Collapse multichannel lanes" : "Expand all \(chCount) channels")
                    .accessibilityLabel(expandMultichannel ? "Collapse \(chCount) channel lanes" : "Expand \(chCount) channel lanes")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
            .padding(3)

            // Left Trim Handle
            Rectangle()
                .fill(isHovering || isSelected ? AppTheme.Colors.accent.opacity(0.6) : .clear)
                .frame(width: 6, height: rowHeight - 8)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            guard !clip.isLocked && !track.isLocked else { return }
                            if trimLeftSnapshot == nil {
                                trimLeftSnapshot = (clip.timelineStart, clip.timelineEnd)
                                store.beginContinuousMutation()
                            }
                            guard let snap = trimLeftSnapshot else { return }
                            let deltaT = v.translation.width / pixelsPerSecond
                            let rawStart = min(snap.end - 0.02, max(0, snap.start + deltaT))
                            let newStart = min(snap.end - 0.02, store.snapTimeIfEnabled(rawStart))
                            store.updateContinuousMutation(type: .clipTrim, title: "Trim Clip Start") { p in
                                _ = AudioEditingService.trimEdges(&p, clipID: clip.id, newStart: newStart, newEnd: snap.end, sourceDuration: asset?.duration)
                            }
                        }
                        .onEnded { _ in
                            trimLeftSnapshot = nil
                            store.endContinuousMutation(type: .clipTrim, title: "Trim Clip Start")
                        }
                )

            // Right Trim Handle
            Rectangle()
                .fill(isHovering || isSelected ? AppTheme.Colors.accent.opacity(0.6) : .clear)
                .frame(width: 6, height: rowHeight - 8)
                .offset(x: max(0, clipWidth - 6))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            guard !clip.isLocked && !track.isLocked else { return }
                            if trimRightSnapshot == nil {
                                trimRightSnapshot = (clip.timelineStart, clip.timelineEnd)
                                store.beginContinuousMutation()
                            }
                            guard let snap = trimRightSnapshot else { return }
                            let deltaT = v.translation.width / pixelsPerSecond
                            let rawEnd = max(snap.start + 0.02, snap.end + deltaT)
                            let newEnd = max(snap.start + 0.02, store.snapTimeIfEnabled(rawEnd))
                            store.updateContinuousMutation(type: .clipTrim, title: "Trim Clip End") { p in
                                _ = AudioEditingService.trimEdges(&p, clipID: clip.id, newStart: snap.start, newEnd: newEnd, sourceDuration: asset?.duration)
                            }
                        }
                        .onEnded { _ in
                            trimRightSnapshot = nil
                            store.endContinuousMutation(type: .clipTrim, title: "Trim Clip End")
                        }
                )

            // Interactive Fade-In Handle (Top-Left)
            if isHovering || isSelected || clip.fadeIn != nil {
                let fadeInX = min(max(12, clipWidth - 16), CGFloat((clip.fadeIn?.duration ?? 0) * pixelsPerSecond))
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(AppTheme.Colors.accent, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(x: max(6, fadeInX), y: 6)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                guard !clip.isLocked && !track.isLocked else { return }
                                if trimLeftSnapshot == nil {
                                    trimLeftSnapshot = (clip.timelineStart, clip.timelineEnd)
                                    store.beginContinuousMutation()
                                }
                                let dur = min(clip.duration * 0.9, max(0, v.location.x / pixelsPerSecond))
                                store.updateContinuousMutation(type: .clipFadeChange, title: "Adjust Fade In") { p in
                                    _ = AudioEditingService.mutateClip(&p, clipID: clip.id) { c in
                                        c.fadeIn = dur > 0.01 ? ClipFadeSpec(duration: dur, curve: c.fadeIn?.curve ?? .equalPower) : nil
                                    }
                                }
                            }
                            .onEnded { _ in
                                trimLeftSnapshot = nil
                                store.endContinuousMutation(type: .clipFadeChange, title: "Adjust Fade In")
                            }
                    )
                    .help("Drag to adjust Fade In")
            }

            // Interactive Fade-Out Handle (Top-Right)
            if isHovering || isSelected || clip.fadeOut != nil {
                let fadeOutWidth = CGFloat((clip.fadeOut?.duration ?? 0) * pixelsPerSecond)
                let handleX = max(16, min(clipWidth - 6, clipWidth - fadeOutWidth))
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(AppTheme.Colors.accent, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(x: handleX, y: 6)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                guard !clip.isLocked && !track.isLocked else { return }
                                if trimRightSnapshot == nil {
                                    trimRightSnapshot = (clip.timelineStart, clip.timelineEnd)
                                    store.beginContinuousMutation()
                                }
                                let dur = min(clip.duration * 0.9, max(0, (clipWidth - v.location.x) / pixelsPerSecond))
                                store.updateContinuousMutation(type: .clipFadeChange, title: "Adjust Fade Out") { p in
                                    _ = AudioEditingService.mutateClip(&p, clipID: clip.id) { c in
                                        c.fadeOut = dur > 0.01 ? ClipFadeSpec(duration: dur, curve: c.fadeOut?.curve ?? .equalPower) : nil
                                    }
                                }
                            }
                            .onEnded { _ in
                                trimRightSnapshot = nil
                                store.endContinuousMutation(type: .clipFadeChange, title: "Adjust Fade Out")
                            }
                    )
                    .help("Drag to adjust Fade Out")
            }
        }
        .frame(width: clipWidth, height: rowHeight - 8)
        .offset(x: CGFloat(clip.timelineStart * pixelsPerSecond), y: 4)
        .onHover { hovering in isHovering = hovering }
        .onTapGesture {
            let additive = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
            store.selectClip(clip.id, additive: additive)
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { v in
                    guard !clip.isLocked && !track.isLocked else { return }
                    if dragBaseStart == nil {
                        dragBaseStart = clip.timelineStart
                        dragLastGroupDelta = 0
                        if !isSelected { store.selectClip(clip.id, additive: false) }
                        store.beginContinuousMutation()
                    }
                    guard let base = dragBaseStart else { return }
                    let deltaT = v.translation.width / pixelsPerSecond
                    let targetStart = store.snapTimeIfEnabled(max(0, base + deltaT))
                    if let gid = track.groupID {
                        let cumulativeDelta = targetStart - base
                        let stepDelta = cumulativeDelta - dragLastGroupDelta
                        if abs(stepDelta) > 0.0005 {
                            dragLastGroupDelta = cumulativeDelta
                            store.updateContinuousMutation(type: .clipMove, title: "Move Group Clips") { p in
                                _ = AudioEditingService.moveGroupClips(&p, groupID: gid, by: stepDelta)
                            }
                        }
                    } else {
                        let trackDelta = Int((v.translation.height / rowHeight).rounded())
                        let targetTrackIdx = min(store.project.tracks.count - 1, max(0, trackIndex + trackDelta))
                        let targetTrackID = store.project.tracks[targetTrackIdx].id
                        store.updateContinuousMutation(type: .clipMove, title: "Move Clip") { p in
                            _ = AudioEditingService.moveClip(&p, clipID: clip.id, toStart: targetStart, toTrack: targetTrackID)
                        }
                    }
                }
                .onEnded { _ in
                    dragBaseStart = nil
                    dragLastGroupDelta = 0
                    store.endContinuousMutation(type: .clipMove, title: track.groupID == nil ? "Move Clip" : "Move Group Clips")
                }
        )
        .contextMenu {
            Button("Split at Playhead") {
                store.selectClip(clip.id)
                store.splitAtPlayhead()
            }
            Button("Duplicate") {
                store.selectClip(clip.id)
                store.duplicateSelectedClips()
            }
            Button("Crossfade with Adjacent Clip (0.25s)") {
                store.selectClip(clip.id)
                store.applyCrossfadeNearSelectedClip(duration: 0.25, curve: .equalPower)
            }
            Button(clip.isLocked ? "Unlock Clip" : "Lock Clip") {
                store.performMutation(type: .clipProcessing, title: clip.isLocked ? "Unlock Clip" : "Lock Clip") { p in
                    AudioEditingService.mutateClip(&p, clipID: clip.id, allowWhenLocked: true) { $0.isLocked.toggle() }
                }
            }
            Button(clip.isMuted ? "Unmute Clip" : "Mute Clip") {
                store.performMutation(type: .clipGainPanChange, title: clip.isMuted ? "Unmute Clip" : "Mute Clip") { p in
                    AudioEditingService.mutateClip(&p, clipID: clip.id) { $0.isMuted.toggle() }
                }
            }
            Button(clip.isReversed ? "Un-reverse Clip" : "Reverse Clip") {
                store.performMutation(type: .clipProcessing, title: "Reverse Clip") { p in
                    AudioEditingService.mutateClip(&p, clipID: clip.id) { $0.isReversed.toggle() }
                }
            }
            Button("Replace Source Audio...") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.audio, .movie]
                if panel.runModal() == .OK, let url = panel.url {
                    store.replaceClip(clip.id, with: url)
                }
            }
            .disabled(clip.isLocked || track.isLocked)
            Divider()
            Button("Delete") {
                store.selectClip(clip.id)
                store.deleteSelectionOrClips(ripple: false)
            }
            .disabled(clip.isLocked || track.isLocked)
            Button("Ripple Delete", role: .destructive) {
                store.selectClip(clip.id)
                store.deleteSelectionOrClips(ripple: true)
            }
            .disabled(clip.isLocked || track.isLocked)
        }
        .onAppear {
            recomputeCachedPlan()
        }
        .onChange(of: planCacheKey) { _, _ in
            recomputeCachedPlan()
        }
        .task(id: clip.sourceAssetID) {
            guard let asset else {
                pyramid = nil
                return
            }
            let targetAssetID = asset.id
            let targetURL = asset.url
            do {
                let finalPyramid = try await WaveformPyramidService.shared.pyramid(
                    for: targetURL,
                    assetID: targetAssetID
                ) { progress in
                    Task { @MainActor in
                        if clip.sourceAssetID == targetAssetID {
                            pyramid = progress.pyramid
                        }
                    }
                }
                if !Task.isCancelled && clip.sourceAssetID == targetAssetID {
                    pyramid = finalPyramid
                }
            } catch {
                if !Task.isCancelled && clip.sourceAssetID == targetAssetID {
                    pyramid = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip \(clip.name), starts at \(AudioEditorTime.format(clip.timelineStart)), duration \(AudioEditorTime.format(clip.duration))")
        .accessibilityValue(isSelected ? "Selected" : (clip.isMuted ? "Muted" : "Normal"))
        .accessibilityIdentifier("audioworkspace.editor.clip.\(clip.id.uuidString)")
    }
}
