import SwiftUI
import AppKit

// MARK: - Keyboard Shortcuts Sheet Controller

@MainActor
final class KeyboardShortcutsSheetController: ObservableObject {
    static let shared = KeyboardShortcutsSheetController()

    @Published var isPresented: Bool = false

    init(isPresented: Bool = false) {
        self.isPresented = isPresented
    }

    func open() {
        isPresented = true
    }

    func dismiss() {
        isPresented = false
    }

    func toggle() {
        isPresented.toggle()
    }
}

// MARK: - Cheatsheet Catalog

struct AppShortcutEntry: Identifiable, Equatable, Sendable {
    let id: String
    let action: String
    let shortcut: String
    let category: String
}

enum KeyboardShortcutsCatalog: Sendable {

    static let categoryOrder: [String] = [
        "General",
        "File",
        "Edit",
        "Conversion",
        "Navigation",
        "Media Viewer",
        "Audio Workspace"
    ]

    static var allEntries: [AppShortcutEntry] {
        var entries: [AppShortcutEntry] = KeyboardShortcutDescriptor.defaultShortcuts.map {
            AppShortcutEntry(
                id: $0.id,
                action: $0.action,
                shortcut: $0.shortcut,
                category: $0.category
            )
        }

        let extras: [AppShortcutEntry] = [
            AppShortcutEntry(id: "keyboard_shortcuts", action: "Keyboard Shortcuts", shortcut: "⌘/", category: "General"),
            AppShortcutEntry(id: "paste_to_convert", action: "Paste to Convert", shortcut: "⌘V", category: "Edit"),
            AppShortcutEntry(id: "mv_copy", action: "Copy Image to Clipboard", shortcut: "⌘C", category: "Media Viewer"),
            AppShortcutEntry(id: "mv_export", action: "Export Edited Media", shortcut: "⌘S", category: "Media Viewer"),
            AppShortcutEntry(id: "mv_play_pause", action: "Play / Pause Video", shortcut: "Space", category: "Media Viewer"),
            AppShortcutEntry(id: "mv_shuttle", action: "Shuttle Reverse / Pause / Forward", shortcut: "J / K / L", category: "Media Viewer"),
            AppShortcutEntry(id: "mv_trim_in_out", action: "Set Trim In / Out Point", shortcut: "I / O", category: "Media Viewer"),
            AppShortcutEntry(id: "mv_split_marker", action: "Split Segment / Add Marker", shortcut: "⌘B / ⌘M", category: "Media Viewer"),
            AppShortcutEntry(id: "mv_sibling_nav", action: "Previous / Next Photo", shortcut: "← / →", category: "Media Viewer"),
            AppShortcutEntry(id: "mv_reset_zoom", action: "Reset Zoom", shortcut: "0", category: "Media Viewer"),
            AppShortcutEntry(id: "aw_play_pause", action: "Play / Pause Audio", shortcut: "Space", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_step_playhead", action: "Step Playhead Left / Right", shortcut: "← / →", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_nudge_selection", action: "Nudge Selection Left / Right", shortcut: "⇧← / ⇧→", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_track_nav", action: "Previous / Next Track", shortcut: "⌘← / ⌘→", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_split", action: "Split at Playhead", shortcut: "B / S / ⌘E", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_trim", action: "Trim to Selection", shortcut: "⌘T", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_delete", action: "Delete / Ripple Delete Selection", shortcut: "⌫ / ⌥⌫", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_loop", action: "Toggle Loop", shortcut: "L", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_marker", action: "Add Marker", shortcut: "M", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_zoom", action: "Zoom In / Out / Fit", shortcut: "⌘+ / ⌘- / ⌘0", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_inspector", action: "Toggle Inspector", shortcut: "⌘I", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_search", action: "Focus Library Search", shortcut: "⌘F", category: "Audio Workspace"),
            AppShortcutEntry(id: "aw_beginning", action: "Return to Beginning", shortcut: "Home", category: "Audio Workspace")
        ]

        let existingIDs = Set(entries.map(\.id))
        for extra in extras where !existingIDs.contains(extra.id) {
            entries.append(extra)
        }
        return entries
    }

    static func groupedEntries(matching query: String = "") -> [(category: String, entries: [AppShortcutEntry])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [AppShortcutEntry]
        if trimmed.isEmpty {
            filtered = allEntries
        } else {
            filtered = allEntries.filter { entry in
                entry.action.localizedCaseInsensitiveContains(trimmed)
                    || entry.shortcut.localizedCaseInsensitiveContains(trimmed)
                    || entry.category.localizedCaseInsensitiveContains(trimmed)
            }
        }

        return categoryOrder.compactMap { category in
            let items = filtered.filter { $0.category == category }
            return items.isEmpty ? nil : (category: category, entries: items)
        }
    }
}

// MARK: - Keyboard Shortcuts Sheet View

struct KeyboardShortcutsSheetView: View {
    @ObservedObject var controller: KeyboardShortcutsSheetController
    @State private var searchText: String = ""

    init(controller: KeyboardShortcutsSheetController = .shared) {
        self.controller = controller
    }

    private var groups: [(category: String, entries: [AppShortcutEntry])] {
        KeyboardShortcutsCatalog.groupedEntries(matching: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            AppDivider()
            searchBar
            AppDivider()
            contentBody
            AppDivider()
            footerBar
        }
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 680, minHeight: 420, idealHeight: 480, maxHeight: 530)
        .appWorkspaceSurface()
        .onExitCommand {
            controller.dismiss()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keyboardShortcuts.sheet")
    }

    private var headerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Colors.accentTint)
                    .frame(width: 32, height: 32)
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Keyboard Shortcuts")
                    .font(AppTheme.Typography.pageTitle)
                    .foregroundStyle(.primary)

                Text("Quick reference for navigation, conversion, editing, and Media Viewer")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: AppTheme.Spacing.sm)

            Button("Done") {
                controller.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("keyboardShortcuts.doneButton")
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(AppTheme.Colors.subtleSurface)
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter shortcuts...", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("keyboardShortcuts.searchField")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs + 3)
        .background(AppTheme.Colors.cardBackground)
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }

    @ViewBuilder
    private var contentBody: some View {
        if groups.isEmpty {
            AppEmptyStateView(
                icon: "keyboard",
                title: String(localized: "No Matching Shortcuts"),
                subtitle: String(localized: "Try a different keyword or clear the search field.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: AppTheme.Spacing.md, alignment: .top)],
                    alignment: .leading,
                    spacing: AppTheme.Spacing.md
                ) {
                    ForEach(groups, id: \.category) { group in
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                            Text(LocalizedStringKey(group.category))
                                .font(AppTheme.Typography.sidebarHeader)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 {
                                        AppDivider()
                                    }
                                    HStack(spacing: AppTheme.Spacing.sm) {
                                        Text(LocalizedStringKey(entry.action))
                                            .font(AppTheme.Typography.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)

                                        Spacer(minLength: AppTheme.Spacing.xs)

                                        Text(verbatim: entry.shortcut)
                                            .font(AppTheme.Typography.badge.monospaced())
                                            .foregroundStyle(.primary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(AppTheme.Colors.neutralTint)
                                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                                            )
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .padding(.vertical, AppTheme.Spacing.xs + 2)
                                }
                            }
                            .padding(.horizontal, AppTheme.Spacing.md)
                            .padding(.vertical, AppTheme.Spacing.xs)
                            .background(AppTheme.Colors.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                                    .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(AppTheme.Spacing.xl)
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Label("Press ⌘/ anytime to toggle this cheatsheet", systemImage: "command")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Text("\(KeyboardShortcutsCatalog.allEntries.count) shortcuts")
                .font(AppTheme.Typography.monoCaption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Colors.subtleSurface)
    }
}
