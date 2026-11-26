import SwiftUI

struct AudioPlaybackQueuePopover: View {
    var coordinator: AudioWorkspaceCoordinator? = nil
    @ObservedObject var playback: PlaybackCoordinator

    @State private var showSavePlaylistPrompt = false
    @State private var playlistNameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Up Next Queue")
                    .font(AppTheme.Typography.sectionTitle)
                Spacer()
                if coordinator != nil {
                    Button("Save Playlist...") {
                        playlistNameDraft = "Queue \(Date().formatted(date: .abbreviated, time: .shortened))"
                        showSavePlaylistPrompt = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(playback.queueRecords.isEmpty)
                    .accessibilityIdentifier("audioworkspace.queue.save_playlist")
                }
                Button("Clear") {
                    Task { await playback.clearQueue() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(playback.queueRecords.isEmpty)
                .accessibilityIdentifier("audioworkspace.queue.clear")
            }
            .padding(AppTheme.Spacing.md)

            if showSavePlaylistPrompt, let coordinator {
                Divider()
                HStack(spacing: AppTheme.Spacing.xs) {
                    TextField("Playlist Name", text: $playlistNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("audioworkspace.queue.playlist_name_field")
                    Button("Save") {
                        let name = playlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        showSavePlaylistPrompt = false
                        Task { _ = await coordinator.saveQueueAsPlaylist(name: name) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(playlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { showSavePlaylistPrompt = false }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.xs)
            }

            Divider()

            if playback.queueRecords.isEmpty {
                AppEmptyStateView(
                    icon: "music.note.list",
                    title: "Queue Is Empty",
                    subtitle: "Play or queue tracks from your Audio Library."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(playback.queueRecords.enumerated()), id: \.offset) { index, record in
                        let isCurrent = playback.queueManager.queue.currentIndex == index
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "line.3.horizontal")
                                .font(.caption)
                                .foregroundStyle(isCurrent ? AppTheme.Colors.accent : .secondary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.metadata.title ?? record.asset.displayFilename)
                                    .font(AppTheme.Typography.subheadline)
                                    .fontWeight(isCurrent ? .semibold : .regular)
                                    .lineLimit(1)
                                Text(record.metadata.artist ?? "Unknown Artist")
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                Task { await playback.removeQueueEntry(at: index) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(record.metadata.title ?? record.asset.displayFilename) from queue")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            Task { await playback.selectQueueIndex(index) }
                        }
                    }
                    .onMove { source, destination in
                        Task { await playback.moveQueueEntries(fromOffsets: source, toOffset: destination) }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("audioworkspace.queue.list")
            }
        }
    }
}
