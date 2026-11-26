import SwiftUI

struct AudioEditorInspectorView: View {
    @ObservedObject var store: AudioEditorStore
    @State private var selectedTab: InspectorTab = .clip

    enum InspectorTab: String, CaseIterable, Identifiable {
        case clip = "Clip"
        case effects = "Effects"
        case markers = "Markers"
        case analysis = "Analysis"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $selectedTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(AppTheme.Spacing.sm)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    switch selectedTab {
                    case .clip:
                        clipSection
                    case .effects:
                        effectsSection
                    case .markers:
                        markersSection
                    case .analysis:
                        analysisSection
                    }
                }
                .padding(AppTheme.Spacing.md)
            }
        }
        .frame(minWidth: 230, idealWidth: 260, maxWidth: 290)
        .background(AppTheme.Colors.secondarySidebarBackground)
    }

    @ViewBuilder
    private var clipSection: some View {
        if let clip = store.primarySelectedClip {
            Text(clip.name)
                .font(AppTheme.Typography.cardTitle)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Start: \(AudioEditorTime.format(clip.timelineStart))")
                    .font(AppTheme.Typography.monoCaption)
                Text("Duration: \(AudioEditorTime.format(clip.duration))")
                    .font(AppTheme.Typography.monoCaption)
            }
            .foregroundStyle(.secondary)

            Divider()

            // Clip Gain + Normalize
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Clip Gain")
                    Spacer()
                    Text(String(format: "%+.1f dB", clip.gainDB))
                        .font(AppTheme.Typography.monoCaption)
                }
                Slider(
                    value: Binding(
                        get: { clip.gainDB },
                        set: { v in
                            store.updateContinuousMutation(type: .clipGainPanChange, title: "Clip Gain") { p in
                                _ = AudioEditingService.mutateClip(&p, clipID: clip.id) { $0.gainDB = v }
                            }
                        }
                    ),
                    in: -24...18,
                    onEditingChanged: { editing in
                        if editing { store.beginContinuousMutation() }
                        else { store.endContinuousMutation(type: .clipGainPanChange, title: "Clip Gain") }
                    }
                )
                HStack(spacing: 6) {
                    Button("Normalize Peak") {
                        store.normalizeSelectedClip(mode: .peak(targetDBFS: -1.0))
                    }
                    .controlSize(.mini)
                    Button("Normalize RMS") {
                        store.normalizeSelectedClip(mode: .rms(targetDBFS: -14.0))
                    }
                    .controlSize(.mini)
                }
            }

            // Fade In + Curve
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Fade In")
                    Spacer()
                    Text(String(format: "%.2fs", clip.fadeIn?.duration ?? 0))
                        .font(AppTheme.Typography.monoCaption)
                }
                Slider(
                    value: Binding(
                        get: { clip.fadeIn?.duration ?? 0 },
                        set: { d in
                            store.updateContinuousMutation(type: .clipFadeChange, title: "Fade In") { p in
                                _ = AudioEditingService.mutateClip(&p, clipID: clip.id) { c in
                                    c.fadeIn = d > 0.01 ? ClipFadeSpec(duration: min(d, c.duration), curve: c.fadeIn?.curve ?? .equalPower) : nil
                                }
                            }
                        }
                    ),
                    in: 0...min(10.0, clip.duration),
                    onEditingChanged: { editing in
                        if editing { store.beginContinuousMutation() }
                        else { store.endContinuousMutation(type: .clipFadeChange, title: "Fade In") }
                    }
                )
                if let fi = clip.fadeIn {
                    Picker("In Curve", selection: Binding(
                        get: { fi.curve },
                        set: { curve in
                            store.performMutation(type: .clipFadeChange, title: "Fade In Curve") { p in
                                AudioEditingService.mutateClip(&p, clipID: clip.id) { c in
                                    if var f = c.fadeIn { f.curve = curve; c.fadeIn = f }
                                }
                            }
                        }
                    )) {
                        ForEach(ClipFadeCurve.allCases) { c in Text(c.rawValue).tag(c) }
                    }
                    .controlSize(.mini)
                }
            }

            // Fade Out + Curve
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Fade Out")
                    Spacer()
                    Text(String(format: "%.2fs", clip.fadeOut?.duration ?? 0))
                        .font(AppTheme.Typography.monoCaption)
                }
                Slider(
                    value: Binding(
                        get: { clip.fadeOut?.duration ?? 0 },
                        set: { d in
                            store.updateContinuousMutation(type: .clipFadeChange, title: "Fade Out") { p in
                                _ = AudioEditingService.mutateClip(&p, clipID: clip.id) { c in
                                    c.fadeOut = d > 0.01 ? ClipFadeSpec(duration: min(d, c.duration), curve: c.fadeOut?.curve ?? .equalPower) : nil
                                }
                            }
                        }
                    ),
                    in: 0...min(10.0, clip.duration),
                    onEditingChanged: { editing in
                        if editing { store.beginContinuousMutation() }
                        else { store.endContinuousMutation(type: .clipFadeChange, title: "Fade Out") }
                    }
                )
                if let fo = clip.fadeOut {
                    Picker("Out Curve", selection: Binding(
                        get: { fo.curve },
                        set: { curve in
                            store.performMutation(type: .clipFadeChange, title: "Fade Out Curve") { p in
                                AudioEditingService.mutateClip(&p, clipID: clip.id) { c in
                                    if var f = c.fadeOut { f.curve = curve; c.fadeOut = f }
                                }
                            }
                        }
                    )) {
                        ForEach(ClipFadeCurve.allCases) { c in Text(c.rawValue).tag(c) }
                    }
                    .controlSize(.mini)
                }
            }

            Picker("Crossfade Curve", selection: Binding(
                get: { clip.crossfadeCurve },
                set: { curve in
                    store.performMutation(type: .clipFadeChange, title: "Crossfade Curve") { p in
                        AudioEditingService.mutateClip(&p, clipID: clip.id) { $0.crossfadeCurve = curve }
                    }
                }
            )) {
                ForEach(ClipFadeCurve.allCases) { c in Text(c.rawValue).tag(c) }
            }

            Picker("Channels", selection: Binding(
                get: { clip.channelMode },
                set: { mode in
                    store.performMutation(type: .clipProcessing, title: "Channel Mode") { p in
                        AudioEditingService.mutateClip(&p, clipID: clip.id) { $0.channelMode = mode }
                    }
                }
            )) {
                ForEach(AudioEditorChannelMode.allCases) { m in Text(m.rawValue).tag(m) }
            }

            Toggle("Swap L/R Channels", isOn: Binding(
                get: { clip.swapChannels },
                set: { val in
                    store.performMutation(type: .clipProcessing, title: "Swap Channels") { p in
                        AudioEditingService.mutateClip(&p, clipID: clip.id) { $0.swapChannels = val }
                    }
                }
            ))

            Toggle("Reverse Audio", isOn: Binding(
                get: { clip.isReversed },
                set: { val in
                    store.performMutation(type: .clipProcessing, title: "Reverse Audio") { p in
                        AudioEditingService.mutateClip(&p, clipID: clip.id) { $0.isReversed = val }
                    }
                }
            ))
        } else {
            Text("Select a clip on the timeline to inspect and edit its gain, fades, channels, and effects.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var effectsSection: some View {
        AudioEffectChainEditorView(store: store)

        if let clip = store.primarySelectedClip {
            Divider()

            DisclosureGroup("Clip Timing & Legacy Proxy FX") {
                VStack(alignment: .leading, spacing: 8) {
                    effectSlider("Pitch Shift", undoTitle: "Pitch Shift", value: continuousEffectBinding(clip.id, \.pitchSemitones, "Pitch Shift"), range: -12...12, unit: "st")
                    effectSlider("Time Stretch", undoTitle: "Time Stretch", value: continuousEffectBinding(clip.id, \.timeStretch, "Time Stretch"), range: 0.5...2.0, unit: "x")

                    let e = clip.effects
                    if !e.isIdentity {
                        Button("Reset Legacy Clip FX") {
                            updateEffect(clip.id, title: "Reset Effects") { $0 = AudioEffectChainConfig() }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
            .font(AppTheme.Typography.caption)
        }
    }

    @ViewBuilder
    private var analysisSection: some View {
        Button("Refresh Analysis") {
            store.refreshSpectrumAndStats()
        }
        .controlSize(.small)

        if let stats = store.selectionStats {
            VStack(alignment: .leading, spacing: 4) {
                Text("Peak: \(String(format: "%.1f dBFS", stats.peakDB))")
                Text("RMS: \(String(format: "%.1f dBFS", stats.rmsDB))")
                Text("Duration: \(AudioEditorTime.format(stats.duration))")
                if stats.clippedSamples > 0 {
                    Text("Clipping: \(stats.clippedSamples) samples")
                        .foregroundStyle(AppTheme.Colors.error)
                } else {
                    Text("No Clipping Detected")
                        .foregroundStyle(AppTheme.Colors.success)
                }
            }
            .font(AppTheme.Typography.monoCaption)
        }

        Divider()

        Text("Frequency Spectrum")
            .font(AppTheme.Typography.cardTitle)

        if store.spectrumBins.isEmpty {
            Text("Play or select a clip to inspect spectrum.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
        } else {
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(Array(store.spectrumBins.enumerated()), id: \.offset) { _, db in
                        let norm = CGFloat(max(0.02, min(1.0, (db + 90.0) / 90.0)))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AppTheme.Colors.accent)
                            .frame(height: max(2, geo.size.height * norm))
                    }
                }
            }
            .frame(height: 90)
            .padding(6)
            .background(AppTheme.Colors.subtleSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        }
    }

    // MARK: - Markers Section

    @ViewBuilder
    private var markersSection: some View {
        HStack {
            Text("Timeline Markers (\(store.project.markers.count))")
                .font(AppTheme.Typography.cardTitle)
            Spacer()
            Button {
                _ = store.addMarkerAtPlayhead()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .controlSize(.small)
            .help("Add Marker at Playhead (M)")
            .accessibilityLabel("Add Marker at Playhead")
        }

        if store.project.markers.isEmpty {
            Text("No markers placed yet. Press M or click Add to place a marker at the playhead.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs + 2) {
                ForEach(store.project.markers) { marker in
                    let isSelected = store.selectedMarkerID == marker.id
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Button {
                                store.selectAndSeekToMarker(id: marker.id)
                            } label: {
                                Image(systemName: isSelected ? "bookmark.fill" : "bookmark")
                                    .foregroundStyle(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.warning)
                            }
                            .buttonStyle(.plain)
                            .help("Select and seek playhead to marker")
                            .accessibilityLabel("Seek to marker \(marker.name)")

                            TextField(
                                "Marker Name",
                                text: Binding(
                                    get: { marker.name },
                                    set: { newName in
                                        store.renameMarker(id: marker.id, newName: newName)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(AppTheme.Typography.caption)
                            .accessibilityLabel("Marker name for \(marker.name)")

                            Button(role: .destructive) {
                                store.deleteMarker(id: marker.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Delete Marker")
                            .accessibilityLabel("Delete marker \(marker.name)")
                        }

                        HStack(spacing: 6) {
                            Text(AudioEditorTime.format(marker.time))
                                .font(AppTheme.Typography.monoCaption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("-0.1s") {
                                store.moveMarker(id: marker.id, to: marker.time - 0.1)
                            }
                            .controlSize(.mini)
                            .accessibilityLabel("Move marker \(marker.name) earlier by 0.1 seconds")
                            Button("+0.1s") {
                                store.moveMarker(id: marker.id, to: marker.time + 0.1)
                            }
                            .controlSize(.mini)
                            .accessibilityLabel("Move marker \(marker.name) later by 0.1 seconds")
                        }
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(isSelected ? AppTheme.Colors.accent.opacity(0.14) : AppTheme.Colors.subtleSurface)
                    )
                }
            }
        }
    }

    // MARK: - Effect Binding Helpers

    private func updateEffect(_ clipID: UUID, title: String, _ mutate: (inout AudioEffectChainConfig) -> Void) {
        store.performMutation(type: .clipEffectChange, title: title) { p in
            AudioEditingService.mutateClip(&p, clipID: clipID) { mutate(&$0.effects) }
        }
    }

    private func updateEffectContinuous(_ clipID: UUID, title: String, _ mutate: (inout AudioEffectChainConfig) -> Void) {
        store.updateContinuousMutation(type: .clipEffectChange, title: title) { p in
            _ = AudioEditingService.mutateClip(&p, clipID: clipID) { mutate(&$0.effects) }
        }
    }

    private func continuousEffectBinding<T>(
        _ clipID: UUID,
        _ kp: WritableKeyPath<AudioEffectChainConfig, T>,
        _ title: String
    ) -> Binding<T> {
        Binding(
            get: { store.project.clip(clipID)?.effects[keyPath: kp] ?? AudioEffectChainConfig()[keyPath: kp] },
            set: { val in
                updateEffectContinuous(clipID, title: title) { $0[keyPath: kp] = val }
            }
        )
    }

    private func effectSlider(_ title: String, undoTitle: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(AppTheme.Typography.caption)
                Spacer()
                Text(String(format: "%.1f %@", value.wrappedValue, unit))
                    .font(AppTheme.Typography.monoCaption)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: value,
                in: range,
                onEditingChanged: { editing in
                    if editing {
                        store.beginContinuousMutation()
                    } else {
                        store.endContinuousMutation(type: .clipEffectChange, title: undoTitle)
                    }
                }
            )
            .controlSize(.mini)
        }
    }
}
