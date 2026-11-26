import SwiftUI
import UniformTypeIdentifiers

struct MultitrackTimelineView: View {
    @ObservedObject var store: AudioEditorStore
    @Binding var viewportWidth: Double

    private let headerWidth: CGFloat = 186
    private let rowHeight: CGFloat = 86

    @State private var isDropTargeted = false
    @State private var dragSelectOriginTime: TimeInterval?

    private var timelineWidth: Double {
        let minDur = max(store.project.duration + 15.0, (viewportWidth / store.timeline.pixelsPerSecond))
        return max(800, minDur * store.timeline.pixelsPerSecond)
    }

    var body: some View {
        GeometryReader { geo in
            let laneAreaWidth = max(200.0, Double(geo.size.width - headerWidth))
            HStack(spacing: 0) {
                // Left Fixed Track Headers Column
                VStack(spacing: 0) {
                    // Ruler spacer
                    HStack {
                        Text("Tracks (\(store.project.tracks.count))")
                            .font(AppTheme.Typography.sidebarHeader)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            store.addTrack()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("Add Track")
                        .accessibilityLabel("Add Track")
                        .accessibilityIdentifier("audioworkspace.editor.add_track")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(AppTheme.Colors.subtleSurface)
                    .overlay(Rectangle().frame(height: 1).foregroundStyle(AppTheme.Colors.divider), alignment: .bottom)

                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(Array(store.project.tracks.enumerated()), id: \.element.id) { idx, track in
                                TrackHeaderView(
                                    store: store,
                                    track: track,
                                    trackIndex: idx,
                                    totalTracks: store.project.tracks.count,
                                    rowHeight: rowHeight
                                )
                            }
                        }
                    }
                }
                .frame(width: headerWidth)
                .background(AppTheme.Colors.secondarySidebarBackground)
                .overlay(Rectangle().frame(width: 1).foregroundStyle(AppTheme.Colors.divider), alignment: .trailing)

                // Right Scrollable Timeline Area
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        TimeRulerView(store: store, timelineWidth: timelineWidth)
                            .overlay(Rectangle().frame(height: 1).foregroundStyle(AppTheme.Colors.divider), alignment: .bottom)

                        ZStack(alignment: .topLeading) {
                            if store.project.gridConfig.snapEnabled {
                                gridLinesOverlay
                            }

                            VStack(spacing: 0) {
                                ForEach(Array(store.project.tracks.enumerated()), id: \.element.id) { idx, track in
                                    trackLane(track: track, index: idx)
                                }
                            }
                            .frame(width: timelineWidth)

                            // Selection Range Overlay across all tracks
                            if let sel = store.timeline.selectionRange {
                                let sx = sel.lowerBound * store.timeline.pixelsPerSecond
                                let sw = max(2, (sel.upperBound - sel.lowerBound) * store.timeline.pixelsPerSecond)
                                Rectangle()
                                    .fill(AppTheme.Colors.accent.opacity(0.12))
                                    .overlay(
                                        Rectangle()
                                            .stroke(AppTheme.Colors.accent.opacity(0.45), lineWidth: 1)
                                    )
                                    .frame(width: sw, height: max(rowHeight, CGFloat(store.project.tracks.count) * rowHeight))
                                    .offset(x: sx)
                                    .allowsHitTesting(false)
                            }

                            // Independent lightweight 60 Hz playhead layer (never invalidates static waveform Canvas)
                            TimelinePlayheadLayer(
                                playheadState: store.playheadState,
                                pixelsPerSecond: store.timeline.pixelsPerSecond,
                                height: max(rowHeight, CGFloat(store.project.tracks.count) * rowHeight)
                            )
                        }
                    }
                    .frame(width: timelineWidth, alignment: .topLeading)
                }
                .background(AppTheme.Colors.workspaceBackground)
                .accessibilityIdentifier("audioworkspace.editor.timeline")
            }
            .onAppear { viewportWidth = laneAreaWidth }
            .onChange(of: geo.size.width) { _, _ in viewportWidth = laneAreaWidth }
        }
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .stroke(isDropTargeted ? AppTheme.Colors.accent : .clear, lineWidth: 2)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private func trackLane(track: AudioTrack, index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(store.selectedTrackID == track.id ? AppTheme.Colors.subtleSurface : AppTheme.Colors.workspaceBackground)
                .frame(width: timelineWidth, height: rowHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            let t0 = max(0, v.startLocation.x / store.timeline.pixelsPerSecond)
                            let t1 = max(0, v.location.x / store.timeline.pixelsPerSecond)
                            dragSelectOriginTime = t0
                            store.timeline.setSelection(from: t0, to: t1)
                        }
                        .onEnded { v in
                            if abs(v.translation.width) < 3 {
                                let t = max(0, v.location.x / store.timeline.pixelsPerSecond)
                                store.seek(to: t)
                                store.selectTrack(track.id)
                                store.clearClipSelection()
                            } else {
                                store.refreshSpectrumAndStats()
                            }
                            dragSelectOriginTime = nil
                        }
                )
                .overlay(Rectangle().frame(height: 1).foregroundStyle(AppTheme.Colors.divider), alignment: .bottom)

            ForEach(track.clips) { clip in
                StereoWaveformClipView(
                    store: store,
                    track: track,
                    trackIndex: index,
                    clip: clip,
                    rowHeight: rowHeight,
                    pixelsPerSecond: store.timeline.pixelsPerSecond,
                    viewportWidth: viewportWidth
                )
            }

            // Visual crossfade overlap indicators on this track
            crossfadeOverlays(for: track)
        }
        .frame(width: timelineWidth, height: rowHeight)
    }

    @ViewBuilder
    private var gridLinesOverlay: some View {
        let step = max(0.05, store.project.gridConfig.stepSeconds)
        let pps = store.timeline.pixelsPerSecond
        let height = max(rowHeight, CGFloat(store.project.tracks.count) * rowHeight)
        Canvas { ctx, _ in
            guard step * pps >= 6 else { return }
            var t = step
            let maxT = timelineWidth / pps
            while t < maxT {
                let x = t * pps
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: height))
                ctx.stroke(p, with: .color(.secondary.opacity(0.14)), lineWidth: 0.75)
                t += step
            }
        }
        .frame(width: timelineWidth, height: height)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func crossfadeOverlays(for track: AudioTrack) -> some View {
        let sorted = track.clips.filter { !$0.isMuted }.sorted { $0.timelineStart < $1.timelineStart }
        if sorted.count >= 2 {
            ForEach(0..<(sorted.count - 1), id: \.self) { idx in
                let a = sorted[idx]
                let b = sorted[idx + 1]
                let overlapStart = max(a.timelineStart, b.timelineStart)
                let overlapEnd = min(a.timelineEnd, b.timelineEnd)
                if overlapEnd - overlapStart > 0.005,
                   (a.timelineStart < b.timelineStart && a.timelineEnd < b.timelineEnd) {
                    let x = CGFloat(overlapStart * store.timeline.pixelsPerSecond)
                    let w = max(4, CGFloat((overlapEnd - overlapStart) * store.timeline.pixelsPerSecond))
                    let curve = b.crossfadeCurve
                    Canvas { ctx, size in
                        var pOut = Path()
                        var pIn = Path()
                        let steps = 14
                        for s in 0...steps {
                            let u = Double(s) / Double(steps)
                            let px = CGFloat(u) * size.width
                            let yOut = (1.0 - CGFloat(curve.fadeOut(u))) * size.height
                            let yIn = (1.0 - CGFloat(curve.fadeIn(u))) * size.height
                            if s == 0 {
                                pOut.move(to: CGPoint(x: px, y: yOut))
                                pIn.move(to: CGPoint(x: px, y: yIn))
                            } else {
                                pOut.addLine(to: CGPoint(x: px, y: yOut))
                                pIn.addLine(to: CGPoint(x: px, y: yIn))
                            }
                        }
                        ctx.stroke(pOut, with: .color(AppTheme.Colors.warning), lineWidth: 1.5)
                        ctx.stroke(pIn, with: .color(AppTheme.Colors.success), lineWidth: 1.5)
                    }
                    .frame(width: w, height: rowHeight - 10)
                    .offset(x: x, y: 5)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    if let url = item as? URL {
                        urls.append(url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
            }
            if !urls.isEmpty {
                await MainActor.run {
                    store.importAudioFiles(urls: urls)
                }
            }
        }
        return true
    }
}

private struct TimelinePlayheadLayer: View {
    @ObservedObject var playheadState: AudioPlayheadState
    let pixelsPerSecond: Double
    let height: CGFloat

    var body: some View {
        let px = playheadState.playheadTime * pixelsPerSecond
        Rectangle()
            .fill(AppTheme.Colors.error)
            .frame(width: 1.5, height: height)
            .offset(x: px)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
