import SwiftUI

struct TimeRulerView: View {
    @ObservedObject var store: AudioEditorStore
    let timelineWidth: Double

    @State private var isDraggingPlayhead = false
    @State private var draggingSelEdge: SelectionEdge? = nil
    @State private var draggingMarkerID: UUID? = nil

    private enum SelectionEdge { case start, end }

    private var majorInterval: TimeInterval {
        let pps = store.timeline.pixelsPerSecond
        let candidates: [TimeInterval] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first { $0 * pps >= 75 } ?? 300
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                // Background
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(AppTheme.Colors.subtleSurface))

                let pps = store.timeline.pixelsPerSecond
                let step = majorInterval
                let minorStep = step / 5.0
                let maxT = timelineWidth / pps

                // Selection highlight in ruler
                if let sel = store.timeline.selectionRange {
                    let sx = sel.lowerBound * pps
                    let ex = sel.upperBound * pps
                    let rect = CGRect(x: sx, y: 0, width: max(2, ex - sx), height: size.height)
                    ctx.fill(Path(rect), with: .color(AppTheme.Colors.accent.opacity(0.22)))
                }

                // Ticks & labels
                var t = 0.0
                var idx = 0
                while t <= maxT {
                    let x = t * pps
                    let isMajor = idx % 5 == 0
                    let tickH: CGFloat = isMajor ? 12 : 6
                    var tickPath = Path()
                    tickPath.move(to: CGPoint(x: x, y: size.height - tickH))
                    tickPath.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(tickPath, with: .color(.secondary.opacity(isMajor ? 0.65 : 0.3)), lineWidth: 1)

                    if isMajor {
                        let label = formatTick(t, step: step)
                        ctx.draw(
                            Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary),
                            at: CGPoint(x: x + 4, y: 8),
                            anchor: .topLeading
                        )
                    }
                    idx += 1
                    t = Double(idx) * minorStep
                }

                // Marker vertical guide lines
                for marker in store.project.markers {
                    let mx = marker.time * pps
                    let isSelected = store.selectedMarkerID == marker.id
                    var line = Path()
                    line.move(to: CGPoint(x: mx, y: 0))
                    line.addLine(to: CGPoint(x: mx, y: size.height))
                    ctx.stroke(
                        line,
                        with: .color(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.warning.opacity(0.85)),
                        lineWidth: isSelected ? 1.5 : 1.0
                    )
                }
            }
            .frame(width: timelineWidth, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = max(0, value.location.x / store.timeline.pixelsPerSecond)
                        isDraggingPlayhead = true
                        store.scrub(to: t)
                    }
                    .onEnded { value in
                        let t = max(0, value.location.x / store.timeline.pixelsPerSecond)
                        isDraggingPlayhead = false
                        store.seek(to: t)
                    }
            )

            // Interactive Marker Flags (isolated from playhead drag)
            let pps = store.timeline.pixelsPerSecond
            ForEach(store.project.markers) { marker in
                markerFlagView(marker: marker, pps: pps)
            }

            // Independent Selection Handles (never move playhead)
            if let sel = store.timeline.selectionRange {
                let pps = store.timeline.pixelsPerSecond
                selectionHandle(x: sel.lowerBound * pps, isStart: true)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let t = max(0, v.location.x / pps)
                                store.timeline.setSelection(from: min(t, sel.upperBound - 0.005), to: sel.upperBound)
                            }
                    )

                selectionHandle(x: sel.upperBound * pps, isStart: false)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let t = max(0, v.location.x / pps)
                                store.timeline.setSelection(from: sel.lowerBound, to: max(t, sel.lowerBound + 0.005))
                            }
                    )
            }

            // Playhead cap (isolated layer so 60 Hz motion does not re-rasterize ruler ticks)
            RulerPlayheadCapLayer(
                playheadState: store.playheadState,
                pixelsPerSecond: store.timeline.pixelsPerSecond
            )
        }
        .coordinateSpace(name: "AudioTimeRuler")
        .frame(width: timelineWidth, height: 28)
    }

    @ViewBuilder
    private func markerFlagView(marker: AudioMarker, pps: Double) -> some View {
        let isSelected = store.selectedMarkerID == marker.id
        let mx = marker.time * pps
        HStack(spacing: 2) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 8, weight: .bold))
            Text(marker.name)
                .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .foregroundStyle(isSelected ? Color.white : Color.black)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.warning)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0.35), lineWidth: isSelected ? 1.2 : 0.5)
        )
        .offset(x: max(0, mx), y: 1)
        .help("\(marker.name) (\(AudioEditorTime.format(marker.time))) — Click to seek, drag to move")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Marker \(marker.name) at \(AudioEditorTime.format(marker.time))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .onTapGesture {
            store.selectAndSeekToMarker(id: marker.id)
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("AudioTimeRuler"))
                .onChanged { value in
                    if draggingMarkerID != marker.id {
                        draggingMarkerID = marker.id
                        store.beginMarkerDrag(id: marker.id)
                    }
                    let rawTime = max(0, value.location.x / pps)
                    store.updateMarkerDrag(id: marker.id, to: rawTime, snapToGrid: store.project.gridConfig.snapEnabled)
                }
                .onEnded { _ in
                    if draggingMarkerID == marker.id {
                        store.endMarkerDrag(id: marker.id)
                        draggingMarkerID = nil
                    }
                }
        )
        .contextMenu {
            Button("Seek Playhead Here") {
                store.selectAndSeekToMarker(id: marker.id)
            }
            Divider()
            Button("Delete Marker", role: .destructive) {
                store.deleteMarker(id: marker.id)
            }
        }
    }

    private func selectionHandle(x: Double, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(AppTheme.Colors.accent)
            .frame(width: 8, height: 14)
            .overlay(
                Image(systemName: isStart ? "chevron.right" : "chevron.left")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            )
            .offset(x: x - 4, y: 0)
            .help(isStart ? "Drag Selection Start" : "Drag Selection End")
    }

    private func formatTick(_ t: TimeInterval, step: TimeInterval) -> String {
        if step < 1.0 {
            return String(format: "%.2fs", t)
        }
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct RulerPlayheadCapLayer: View {
    @ObservedObject var playheadState: AudioPlayheadState
    let pixelsPerSecond: Double

    var body: some View {
        let px = playheadState.playheadTime * pixelsPerSecond
        PlayheadCap()
            .fill(AppTheme.Colors.error)
            .frame(width: 12, height: 14)
            .offset(x: px - 6, y: 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
