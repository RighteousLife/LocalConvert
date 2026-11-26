import SwiftUI

struct TrackHeaderView: View {
    @ObservedObject var store: AudioEditorStore
    let track: AudioTrack
    let trackIndex: Int
    let totalTracks: Int
    let rowHeight: CGFloat

    private var isSelected: Bool { store.selectedTrackID == track.id }
    @State private var draftName: String = ""
    @FocusState private var isEditingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Track Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(AppTheme.Typography.cardTitle)
                    .focused($isEditingName)
                    .onAppear { draftName = track.name }
                    .onChange(of: track.name) { _, newValue in
                        if !isEditingName { draftName = newValue }
                    }
                    .onSubmit { commitTrackName() }
                    .onChange(of: isEditingName) { _, focused in
                        if !focused { commitTrackName() }
                    }

                if let gid = track.groupID,
                   let grp = store.project.trackGroups.first(where: { $0.id == gid }) {
                    Text(grp.name)
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 64)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(grp.isMuted ? AppTheme.Colors.warningTint : AppTheme.Colors.infoTint, in: Capsule())
                        .foregroundStyle(grp.isMuted ? AppTheme.Colors.warning : AppTheme.Colors.info)
                }

                Spacer(minLength: 2)

                Button {
                    store.toggleTrackMute(track.id)
                } label: {
                    Text("M")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(track.isMuted ? AppTheme.Colors.warning : .secondary)
                .help("Mute Track")
                .accessibilityLabel("Mute \(track.name)")
                .accessibilityValue(track.isMuted ? "Muted" : "Active")
                .accessibilityIdentifier("audioworkspace.editor.track.mute.\(trackIndex)")

                Button {
                    store.toggleTrackSolo(track.id)
                } label: {
                    Text("S")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.bordered)
                .tint(track.isSolo ? AppTheme.Colors.info : .secondary)
                .help("Solo Track")
                .accessibilityLabel("Solo \(track.name)")
                .accessibilityValue(track.isSolo ? "Soloed" : "Off")
                .accessibilityIdentifier("audioworkspace.editor.track.solo.\(trackIndex)")

                Button {
                    store.toggleTrackLock(track.id)
                } label: {
                    Image(systemName: track.isLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(track.isLocked ? AppTheme.Colors.warning : .secondary)
                .help(track.isLocked ? "Unlock Track" : "Lock Track")
                .accessibilityLabel(track.isLocked ? "Unlock \(track.name)" : "Lock \(track.name)")
                .accessibilityValue(track.isLocked ? "Locked" : "Unlocked")
                .accessibilityIdentifier("audioworkspace.editor.track.lock.\(trackIndex)")
            }

            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { track.volume },
                            set: { val in
                                store.updateContinuousMutation(type: .trackMixChange, title: "Track Volume") { p in
                                    if let i = p.tracks.firstIndex(where: { $0.id == track.id }) {
                                        p.tracks[i].volume = val
                                    }
                                }
                            }
                        ),
                        in: 0...1.5,
                        onEditingChanged: { editing in
                            if editing { store.beginContinuousMutation() }
                            else { store.endContinuousMutation(type: .trackMixChange, title: "Track Volume") }
                        }
                    )
                    .controlSize(.mini)
                    .accessibilityLabel("Volume for \(track.name)")
                }

                HStack(spacing: 3) {
                    Text("Pan")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { track.pan },
                            set: { val in
                                store.updateContinuousMutation(type: .trackMixChange, title: "Track Pan") { p in
                                    if let i = p.tracks.firstIndex(where: { $0.id == track.id }) {
                                        p.tracks[i].pan = val
                                    }
                                }
                            }
                        ),
                        in: -1...1,
                        onEditingChanged: { editing in
                            if editing { store.beginContinuousMutation() }
                            else { store.endContinuousMutation(type: .trackMixChange, title: "Track Pan") }
                        }
                    )
                    .controlSize(.mini)
                    .frame(width: 58)
                    .accessibilityLabel("Pan for \(track.name)")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: rowHeight)
        .background(isSelected ? AppTheme.Colors.accentTint : AppTheme.Colors.cardBackground)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AppTheme.Colors.divider),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectTrack(track.id)
        }
        .contextMenu {
            Button("Insert 1s Silence at Playhead") {
                store.selectTrack(track.id)
                store.insertSilence(duration: 1.0)
            }
            Divider()
            Menu("Track Grouping") {
                Button("Create New Group with Track") {
                    store.createTrackGroup(name: "Group \(store.project.trackGroups.count + 1)", trackIDs: [track.id])
                }
                if !store.project.trackGroups.isEmpty {
                    ForEach(store.project.trackGroups) { grp in
                        Button(track.groupID == grp.id ? "✓ \(grp.name)" : "Assign to \(grp.name)") {
                            store.assignTrack(track.id, toGroupID: grp.id)
                        }
                    }
                }
                if let gid = track.groupID {
                    Divider()
                    Button("Select Group Clips") { store.selectClipsInGroup(gid) }
                    Button("Toggle Group Mute") { store.toggleGroupMute(gid) }
                    Button("Toggle Group Solo") { store.toggleGroupSolo(gid) }
                    Button("Remove from Group") { store.assignTrack(track.id, toGroupID: nil) }
                }
            }
            Divider()
            Button("Move Track Up") {
                store.moveTrack(track.id, offset: -1)
            }
            .disabled(trackIndex == 0)
            Button("Move Track Down") {
                store.moveTrack(track.id, offset: 1)
            }
            .disabled(trackIndex >= totalTracks - 1)
            Divider()
            Button("Delete Track", role: .destructive) {
                store.removeTrack(track.id)
            }
            .disabled(totalTracks <= 1 || track.isLocked)
        }
    }

    private func commitTrackName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != track.name else {
            draftName = track.name
            return
        }
        store.performMutation(type: .trackMixChange, title: "Rename Track") { p in
            guard let idx = p.tracks.firstIndex(where: { $0.id == track.id }) else { return false }
            p.tracks[idx].name = trimmed
            return true
        }
    }
}
