import SwiftUI

struct AudioEffectChainEditorView: View {
    @ObservedObject var store: AudioEditorStore
    @ObservedObject private var presetStore = AudioEffectPresetStore.shared

    enum ScopeSelection: String, CaseIterable, Identifiable {
        case clip = "Clip"
        case track = "Track"
        case master = "Master"
        var id: String { rawValue }
    }

    @State private var scope: ScopeSelection = .track
    @State private var presetNameDraft: String = ""
    @State private var showSavePresetField: Bool = false

    private var activeTarget: AudioEffectChainTarget? {
        switch scope {
        case .clip:
            return store.primarySelectedClip.map { .clip($0.id) }
        case .track:
            return store.primarySelectedTrack.map { .track($0.id) }
        case .master:
            return .master
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Picker("FX Target", selection: $scope) {
                ForEach(ScopeSelection.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if let target = activeTarget {
                let slots = store.effectSlots(for: target)

                // Preset Menu & Save Bar
                HStack(spacing: 6) {
                    Menu("Presets") {
                        Section("Factory Presets") {
                            ForEach(presetStore.presets.filter(\.isFactory)) { preset in
                                Button(preset.name) {
                                    store.applyEffectChainPreset(preset, to: target, presetStore: presetStore)
                                }
                            }
                        }
                        let userPresets = presetStore.presets.filter { !$0.isFactory }
                        if !userPresets.isEmpty {
                            Section("User Presets") {
                                ForEach(userPresets) { preset in
                                    Button(preset.name) {
                                        store.applyEffectChainPreset(preset, to: target, presetStore: presetStore)
                                    }
                                }
                            }
                        }
                    }
                    .controlSize(.small)

                    Button("Save...") {
                        presetNameDraft = ""
                        showSavePresetField.toggle()
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(slots.isEmpty)

                    Spacer()

                    Menu("Add FX") {
                        ForEach(AudioEffectKind.allCases) { kind in
                            Button {
                                store.addEffectSlot(kind, to: target)
                            } label: {
                                Label(kind.rawValue, systemImage: kind.systemImage)
                            }
                        }
                    }
                    .controlSize(.small)
                }

                if showSavePresetField {
                    HStack(spacing: 6) {
                        TextField("Preset name", text: $presetNameDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            if (try? presetStore.saveUserPreset(name: presetNameDraft, slots: slots)) != nil {
                                showSavePresetField = false
                            }
                        }
                        .controlSize(.small)
                        .disabled(presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if slots.isEmpty {
                    Text("No live effects on this \(scope.rawValue.lowercased()). Use '+ Add FX' or load a preset.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { idx, slot in
                        effectSlotCard(slot: slot, index: idx, total: slots.count, target: target)
                    }
                }
            } else {
                Text("Select a \(scope.rawValue.lowercased()) to configure its real-time effect chain.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func effectSlotCard(slot: AudioEffectSlot, index: Int, total: Int, target: AudioEffectChainTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    store.updateEffectSlot(id: slot.id, in: target, title: "Toggle \(slot.kind.rawValue)") { s in
                        s.isEnabled.toggle()
                    }
                } label: {
                    Image(systemName: slot.isEnabled ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(slot.isEnabled && !slot.isBypassed ? AppTheme.Colors.accent : .secondary)
                }
                .buttonStyle(.plain)

                Text(slot.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button("Bypass") {
                    store.updateEffectSlot(id: slot.id, in: target, title: "Bypass \(slot.kind.rawValue)") { s in
                        s.isBypassed.toggle()
                    }
                }
                .controlSize(.mini)
                .fixedSize(horizontal: true, vertical: false)
                .tint(slot.isBypassed ? AppTheme.Colors.warning : .secondary)

                Button {
                    store.moveEffectSlot(id: slot.id, offset: -1, in: target)
                } label: { Image(systemName: "chevron.up").font(.caption2) }
                    .buttonStyle(.plain)
                    .disabled(index == 0)

                Button {
                    store.moveEffectSlot(id: slot.id, offset: 1, in: target)
                } label: { Image(systemName: "chevron.down").font(.caption2) }
                    .buttonStyle(.plain)
                    .disabled(index >= total - 1)

                Button(role: .destructive) {
                    store.removeEffectSlot(id: slot.id, from: target)
                } label: { Image(systemName: "trash").font(.caption2) }
                    .buttonStyle(.plain)
            }

            if slot.isEnabled {
                slotParametersBody(slot: slot, target: target)
            }
        }
        .padding(8)
        .background(AppTheme.Colors.subtleSurface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private func slotParametersBody(slot: AudioEffectSlot, target: AudioEffectChainTarget) -> some View {
        switch slot.kind {
        case .parametricEQ:
            parametricEQControls(slot: slot, target: target)
        case .compressor:
            compressorControls(slot: slot, target: target)
        case .limiter:
            limiterControls(slot: slot, target: target)
        case .noiseGate:
            noiseGateControls(slot: slot, target: target)
        case .noiseReduction:
            noiseReductionControls(slot: slot, target: target)
        case .delay:
            delayControls(slot: slot, target: target)
        case .reverb:
            reverbControls(slot: slot, target: target)
        }
    }

    // MARK: - Per-Effect Controls

    @ViewBuilder
    private func parametricEQControls(slot: AudioEffectSlot, target: AudioEffectChainTarget) -> some View {
        let eq = slot.eq ?? ParametricEQParams()
        EQFrequencyResponseCurveView(eq: eq, sampleRate: store.project.sampleRate)
            .frame(height: 68)

        HStack {
            Menu("EQ Preset") {
                ForEach(ParametricEQParams.presets, id: \.name) { preset in
                    Button(preset.name) {
                        store.updateEffectSlot(id: slot.id, in: target, title: "EQ Preset: \(preset.name)") { s in
                            var p = s.eq ?? ParametricEQParams()
                            p.bands = preset.bands
                            s.eq = p
                        }
                    }
                }
            }
            .controlSize(.mini)

            Button("Reset") {
                store.updateEffectSlot(id: slot.id, in: target, title: "Reset Parametric EQ") { s in
                    s.eq = ParametricEQParams()
                }
            }
            .controlSize(.mini)
            Spacer()
        }

        ForEach(Array(eq.bands.enumerated()), id: \.element.id) { bIdx, band in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Toggle("", isOn: Binding(
                        get: { band.isEnabled },
                        set: { v in
                            store.updateEffectSlot(id: slot.id, in: target, title: "Toggle EQ Band") { s in
                                var p = s.eq ?? ParametricEQParams()
                                if p.bands.indices.contains(bIdx) { p.bands[bIdx].isEnabled = v }
                                s.eq = p
                            }
                        }
                    ))
                    .labelsHidden()
                    .controlSize(.mini)

                    Picker("", selection: Binding(
                        get: { band.type },
                        set: { t in
                            store.updateEffectSlot(id: slot.id, in: target, title: "EQ Filter Type") { s in
                                var p = s.eq ?? ParametricEQParams()
                                if p.bands.indices.contains(bIdx) { p.bands[bIdx].type = t }
                                s.eq = p
                            }
                        }
                    )) {
                        ForEach(EQFilterType.allCases) { ft in Text(ft.rawValue).tag(ft) }
                    }
                    .labelsHidden()
                    .controlSize(.mini)

                    Spacer()
                    Text("\(Int(band.frequencyHz)) Hz")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                slotSlider("Freq", value: Binding(
                    get: { log10(max(20, band.frequencyHz)) },
                    set: { logF in
                        store.updateEffectSlot(id: slot.id, in: target, continuous: true, title: "EQ Frequency") { s in
                            var p = s.eq ?? ParametricEQParams()
                            if p.bands.indices.contains(bIdx) {
                                p.bands[bIdx].frequencyHz = pow(10, logF)
                                p.bands[bIdx].clamped(sampleRate: store.project.sampleRate)
                            }
                            s.eq = p
                        }
                    }
                ), range: log10(20.0)...log10(20_000.0), format: { "\(Int(pow(10, $0))) Hz" }, title: "EQ Frequency")

                if band.type.supportsGain {
                    slotSlider("Gain", value: Binding(
                        get: { band.gainDB },
                        set: { g in
                            store.updateEffectSlot(id: slot.id, in: target, continuous: true, title: "EQ Gain") { s in
                                var p = s.eq ?? ParametricEQParams()
                                if p.bands.indices.contains(bIdx) { p.bands[bIdx].gainDB = g }
                                s.eq = p
                            }
                        }
                    ), range: -18...18, format: { String(format: "%+.1f dB", $0) }, title: "EQ Gain")
                }

                slotSlider("Q", value: Binding(
                    get: { band.q },
                    set: { qv in
                        store.updateEffectSlot(id: slot.id, in: target, continuous: true, title: "EQ Q") { s in
                            var p = s.eq ?? ParametricEQParams()
                            if p.bands.indices.contains(bIdx) { p.bands[bIdx].q = qv }
                            s.eq = p
                        }
                    }
                ), range: 0.3...10.0, format: { String(format: "%.2f", $0) }, title: "EQ Q")
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func compressorControls(slot: AudioEffectSlot, target: AudioEffectChainTarget) -> some View {
        if store.playbackEngine.gainReductionDB < -0.1 {
            Text(String(format: "Gain Reduction: %.1f dB", store.playbackEngine.gainReductionDB))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppTheme.Colors.warning)
        }
        slotSlider("Threshold", value: compBinding(slot.id, target, \.thresholdDB, "Compressor Threshold"), range: -50...0, format: { String(format: "%.1f dB", $0) }, title: "Compressor Threshold")
        slotSlider("Ratio", value: compBinding(slot.id, target, \.ratio, "Compressor Ratio"), range: 1...20, format: { String(format: "%.1f:1", $0) }, title: "Compressor Ratio")
        slotSlider("Attack", value: compBinding(slot.id, target, \.attackMs, "Compressor Attack"), range: 0.5...100, format: { String(format: "%.1f ms", $0) }, title: "Compressor Attack")
        slotSlider("Release", value: compBinding(slot.id, target, \.releaseMs, "Compressor Release"), range: 20...1000, format: { "\(Int($0)) ms" }, title: "Compressor Release")
        slotSlider("Knee", value: compBinding(slot.id, target, \.kneeDB, "Compressor Knee"), range: 0...18, format: { String(format: "%.1f dB", $0) }, title: "Compressor Knee")
        slotSlider("Makeup", value: compBinding(slot.id, target, \.makeupGainDB, "Compressor Makeup"), range: -6...18, format: { String(format: "%+.1f dB", $0) }, title: "Compressor Makeup")
    }

    @ViewBuilder
    private func limiterControls(slot: AudioEffectSlot, target: AudioEffectChainTarget) -> some View {
        slotSlider("Ceiling (Sample Peak)", value: limBinding(slot.id, target, \.ceilingDB, "Limiter Ceiling"), range: -12...(-0.1), format: { String(format: "%.1f dBFS", $0) }, title: "Limiter Ceiling")
        slotSlider("Lookahead", value: limBinding(slot.id, target, \.lookaheadMs, "Limiter Lookahead"), range: 0...10, format: { String(format: "%.1f ms", $0) }, title: "Limiter Lookahead")
        slotSlider("Release", value: limBinding(slot.id, target, \.releaseMs, "Limiter Release"), range: 10...400, format: { "\(Int($0)) ms" }, title: "Limiter Release")
        Text("Enforces sample-peak ceiling in real time; export validates True Peak (dBTP).")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func noiseGateControls(slot: AudioEffectSlot, target: AudioEffectChainTarget) -> some View {
        slotSlider("Threshold", value: gateBinding(slot.id, target, \.thresholdDB, "Gate Threshold"), range: -75...(-10), format: { String(format: "%.1f dB", $0) }, title: "Gate Threshold")
        slotSlider("Attack", value: gateBinding(slot.id, target, \.attackMs, "Gate Attack"), range: 0.5...50, format: { String(format: "%.1f ms", $0) }, title: "Gate Attack")
        slotSlider("Hold", value: gateBinding(slot.id, target, \.holdMs, "Gate Hold"), range: 0...500, format: { "\(Int($0)) ms" }, title: "Gate Hold")
        slotSlider("Release", value: gateBinding(slot.id, target, \.releaseMs, "Gate Release"), range: 20...1000, format: { "\(Int($0)) ms" }, title: "Gate Release")
        slotSlider("Range", value: gateBinding(slot.id, target, \.rangeDB, "Gate Range"), range: -80...0, format: { String(format: "%.0f dB", $0) }, title: "Gate Range")
        slotSlider("Hysteresis", value: gateBinding(slot.id, target, \.hysteresisDB, "Gate Hysteresis"), range: 0...12, format: { String(format: "%.1f dB", $0) }, title: "Gate Hysteresis")
    }

    @ViewBuilder
    private func noiseReductionControls(slot: AudioEffectSlot, target: AudioEffectChainTarget) -> some View {
        let nr = slot.noiseReduction ?? NoiseReductionParams()
        slotSlider("Reduction", value: nrBinding(slot.id, target, \.reductionAmount, "NR Amount"), range: 0...100, format: { "\(Int($0))%" }, title: "NR Amount")
        slotSlider("Smoothing", value: nrBinding(slot.id, target, \.smoothing, "NR Smoothing"), range: 0...0.9, format: { String(format: "%.2f", $0) }, title: "NR Smoothing")
        slotSlider("Floor Threshold", value: nrBinding(slot.id, target, \.noiseFloorDB, "NR Floor"), range: -80...(-15), format: { String(format: "%.0f dBFS", $0) }, title: "NR Floor")

        HStack {
            Button("Capture Noise Profile") {
                store.captureNoiseProfileForSlot(id: slot.id, in: target)
            }
            .controlSize(.mini)
            if nr.noiseProfile != nil {
                Text("Profile Ready")
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.Colors.success)
            }
        }
    }

    @ViewBuilder
    private func delayControls(slot: AudioEffectSlot, target: AudioEffectChainTarget) -> some View {
        let dly = slot.delay ?? DelayParams()
        slotSlider("Time", value: delayBinding(slot.id, target, \.delayTimeMs, "Delay Time"), range: 10...1500, format: { "\(Int($0)) ms" }, title: "Delay Time")
        slotSlider("Feedback", value: delayBinding(slot.id, target, \.feedback, "Delay Feedback"), range: 0...0.90, format: { "\(Int($0 * 100))%" }, title: "Delay Feedback")
        slotSlider("Wet / Dry", value: delayBinding(slot.id, target, \.wetDryMix, "Delay Mix"), range: 0...1, format: { "\(Int($0 * 100))%" }, title: "Delay Mix")
        slotSlider("Damping", value: delayBinding(slot.id, target, \.dampingHz, "Delay Damping"), range: 500...18_000, format: { "\(Int($0)) Hz" }, title: "Delay Damping")
        Toggle("Ping-Pong Stereo", isOn: Binding(
            get: { dly.pingPong },
            set: { v in
                store.updateEffectSlot(id: slot.id, in: target, title: "Delay Ping-Pong") { s in
                    var d = s.delay ?? DelayParams()
                    d.pingPong = v
                    s.delay = d
                }
            }
        ))
        .font(.caption)
    }

    @ViewBuilder
    private func reverbControls(slot: AudioEffectSlot, target: AudioEffectChainTarget) -> some View {
        let rev = slot.reverb ?? ReverbParams()
        Picker("Room", selection: Binding(
            get: { rev.roomPreset },
            set: { r in
                store.updateEffectSlot(id: slot.id, in: target, title: "Reverb Room") { s in
                    var p = s.reverb ?? ReverbParams()
                    p.roomPreset = r
                    s.reverb = p
                }
            }
        )) {
            ForEach(ReverbRoomPreset.allCases) { r in Text(r.rawValue).tag(r) }
        }
        .controlSize(.mini)

        slotSlider("Decay", value: reverbBinding(slot.id, target, \.decaySeconds, "Reverb Decay"), range: 0.2...6.0, format: { String(format: "%.1f s", $0) }, title: "Reverb Decay")
        slotSlider("Pre-Delay", value: reverbBinding(slot.id, target, \.preDelayMs, "Reverb Pre-Delay"), range: 0...120, format: { "\(Int($0)) ms" }, title: "Reverb Pre-Delay")
        slotSlider("Damping", value: reverbBinding(slot.id, target, \.damping, "Reverb Damping"), range: 0.05...0.95, format: { "\(Int($0 * 100))%" }, title: "Reverb Damping")
        slotSlider("Width", value: reverbBinding(slot.id, target, \.stereoWidth, "Reverb Width"), range: 0...1, format: { "\(Int($0 * 100))%" }, title: "Reverb Width")
        slotSlider("Wet / Dry", value: reverbBinding(slot.id, target, \.wetDryMix, "Reverb Mix"), range: 0...1, format: { "\(Int($0 * 100))%" }, title: "Reverb Mix")
    }

    // MARK: - Binding Helpers

    private func compBinding(_ id: UUID, _ target: AudioEffectChainTarget, _ kp: WritableKeyPath<CompressorParams, Double>, _ title: String) -> Binding<Double> {
        Binding(
            get: { (store.effectSlots(for: target).first(where: { $0.id == id })?.compressor ?? CompressorParams())[keyPath: kp] },
            set: { v in
                store.updateEffectSlot(id: id, in: target, continuous: true, title: title) { s in
                    var c = s.compressor ?? CompressorParams(); c[keyPath: kp] = v; c.clamped(); s.compressor = c
                }
            }
        )
    }

    private func limBinding(_ id: UUID, _ target: AudioEffectChainTarget, _ kp: WritableKeyPath<LimiterParams, Double>, _ title: String) -> Binding<Double> {
        Binding(
            get: { (store.effectSlots(for: target).first(where: { $0.id == id })?.limiter ?? LimiterParams())[keyPath: kp] },
            set: { v in
                store.updateEffectSlot(id: id, in: target, continuous: true, title: title) { s in
                    var l = s.limiter ?? LimiterParams(); l[keyPath: kp] = v; l.clamped(); s.limiter = l
                }
            }
        )
    }

    private func gateBinding(_ id: UUID, _ target: AudioEffectChainTarget, _ kp: WritableKeyPath<NoiseGateParams, Double>, _ title: String) -> Binding<Double> {
        Binding(
            get: { (store.effectSlots(for: target).first(where: { $0.id == id })?.noiseGate ?? NoiseGateParams())[keyPath: kp] },
            set: { v in
                store.updateEffectSlot(id: id, in: target, continuous: true, title: title) { s in
                    var g = s.noiseGate ?? NoiseGateParams(); g[keyPath: kp] = v; g.clamped(); s.noiseGate = g
                }
            }
        )
    }

    private func nrBinding(_ id: UUID, _ target: AudioEffectChainTarget, _ kp: WritableKeyPath<NoiseReductionParams, Double>, _ title: String) -> Binding<Double> {
        Binding(
            get: { (store.effectSlots(for: target).first(where: { $0.id == id })?.noiseReduction ?? NoiseReductionParams())[keyPath: kp] },
            set: { v in
                store.updateEffectSlot(id: id, in: target, continuous: true, title: title) { s in
                    var n = s.noiseReduction ?? NoiseReductionParams(); n[keyPath: kp] = v; n.clamped(); s.noiseReduction = n
                }
            }
        )
    }

    private func delayBinding(_ id: UUID, _ target: AudioEffectChainTarget, _ kp: WritableKeyPath<DelayParams, Double>, _ title: String) -> Binding<Double> {
        Binding(
            get: { (store.effectSlots(for: target).first(where: { $0.id == id })?.delay ?? DelayParams())[keyPath: kp] },
            set: { v in
                store.updateEffectSlot(id: id, in: target, continuous: true, title: title) { s in
                    var d = s.delay ?? DelayParams(); d[keyPath: kp] = v; d.clamped(); s.delay = d
                }
            }
        )
    }

    private func reverbBinding(_ id: UUID, _ target: AudioEffectChainTarget, _ kp: WritableKeyPath<ReverbParams, Double>, _ title: String) -> Binding<Double> {
        Binding(
            get: { (store.effectSlots(for: target).first(where: { $0.id == id })?.reverb ?? ReverbParams())[keyPath: kp] },
            set: { v in
                store.updateEffectSlot(id: id, in: target, continuous: true, title: title) { s in
                    var r = s.reverb ?? ReverbParams(); r[keyPath: kp] = v; r.clamped(); s.reverb = r
                }
            }
        )
    }

    private func slotSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: (Double) -> String,
        title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.system(size: 10))
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: value,
                in: range,
                onEditingChanged: { editing in
                    if editing { store.beginContinuousMutation() }
                    else { store.endContinuousMutation(type: .clipEffectChange, title: title) }
                }
            )
            .controlSize(.mini)
        }
    }
}

private struct EQFrequencyResponseCurveView: View {
    let eq: ParametricEQParams
    let sampleRate: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(AppTheme.Colors.workspaceBackground))

            // 0 dB center line
            let midY = size.height * 0.5
            var zeroLine = Path()
            zeroLine.move(to: CGPoint(x: 0, y: midY))
            zeroLine.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(zeroLine, with: .color(.secondary.opacity(0.3)), lineWidth: 0.75)

            let steps = 64
            let minF = log10(20.0)
            let maxF = log10(20_000.0)
            let freqs = (0...steps).map { idx in
                pow(10.0, minF + (maxF - minF) * (Double(idx) / Double(steps)))
            }
            let mags = ParametricEQDSP.frequencyResponseDB(params: eq, sampleRate: sampleRate, frequencies: freqs)

            var curve = Path()
            for (i, db) in mags.enumerated() {
                let x = CGFloat(Double(i) / Double(steps)) * size.width
                let clampedDB = min(20.0, max(-20.0, db))
                let y = midY - CGFloat(clampedDB / 20.0) * (size.height * 0.44)
                if i == 0 { curve.move(to: CGPoint(x: x, y: y)) }
                else { curve.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(curve, with: .color(AppTheme.Colors.accent), lineWidth: 1.75)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                .strokeBorder(AppTheme.Colors.cardBorder, lineWidth: 0.75)
        )
    }
}
