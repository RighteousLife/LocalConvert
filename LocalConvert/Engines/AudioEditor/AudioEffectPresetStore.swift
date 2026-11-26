import Foundation

// MARK: - Audio Effect Chain Target & Preset Persistence Store

enum AudioEffectChainTarget: Equatable, Sendable {
    case clip(UUID)
    case track(UUID)
    case master
}

@MainActor
final class AudioEffectPresetStore: ObservableObject {
    @Published private(set) var presets: [AudioEffectChainPreset] = []

    private let storageURL: URL

    static let shared = AudioEffectPresetStore()

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            self.storageURL = AppStoragePaths.audioEditorPresetsFileURL
        }
        reload()
    }

    static var factoryPresets: [AudioEffectChainPreset] {
        [
            AudioEffectChainPreset(
                id: UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!,
                name: "Podcast Voice Chain",
                scope: .trackChain,
                slots: [
                    AudioEffectSlot(kind: .noiseGate, noiseGate: NoiseGateParams(thresholdDB: -46, attackMs: 2, holdMs: 110, releaseMs: 180, rangeDB: -45, hysteresisDB: 4)),
                    AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams(bands: ParametricEQParams.presets[1].bands)),
                    AudioEffectSlot(kind: .compressor, compressor: CompressorParams(thresholdDB: -20, ratio: 3.5, attackMs: 8, releaseMs: 140, kneeDB: 6, makeupGainDB: 3.0)),
                    AudioEffectSlot(kind: .limiter, limiter: LimiterParams(ceilingDB: -1.0, lookaheadMs: 4.0, releaseMs: 80.0))
                ],
                isFactory: true
            ),
            AudioEffectChainPreset(
                id: UUID(uuidString: "A1000000-0000-0000-0000-000000000002")!,
                name: "Broadcast Mastering Polish",
                scope: .trackChain,
                slots: [
                    AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams(bands: ParametricEQParams.presets[3].bands)),
                    AudioEffectSlot(kind: .compressor, compressor: CompressorParams(thresholdDB: -14, ratio: 2.2, attackMs: 15, releaseMs: 220, kneeDB: 8, makeupGainDB: 1.5)),
                    AudioEffectSlot(kind: .limiter, limiter: LimiterParams(ceilingDB: -1.0, lookaheadMs: 5.0, releaseMs: 90.0))
                ],
                isFactory: true
            ),
            AudioEffectChainPreset(
                id: UUID(uuidString: "A1000000-0000-0000-0000-000000000003")!,
                name: "Warm Acoustic Room",
                scope: .trackChain,
                slots: [
                    AudioEffectSlot(kind: .parametricEQ, eq: ParametricEQParams(bands: ParametricEQParams.presets[2].bands)),
                    AudioEffectSlot(kind: .reverb, reverb: ReverbParams(roomPreset: .plate, decaySeconds: 1.8, preDelayMs: 20, damping: 0.45, stereoWidth: 0.85, wetDryMix: 0.24))
                ],
                isFactory: true
            ),
            AudioEffectChainPreset(
                id: UUID(uuidString: "A1000000-0000-0000-0000-000000000004")!,
                name: "Stereo Ambient Echo",
                scope: .trackChain,
                slots: [
                    AudioEffectSlot(kind: .delay, delay: DelayParams(delayTimeMs: 320, feedback: 0.38, wetDryMix: 0.28, dampingHz: 5500, pingPong: true)),
                    AudioEffectSlot(kind: .reverb, reverb: ReverbParams(roomPreset: .largeHall, decaySeconds: 2.8, preDelayMs: 28, damping: 0.5, stereoWidth: 0.95, wetDryMix: 0.30))
                ],
                isFactory: true
            )
        ]
    }

    func reload() {
        var combined = Self.factoryPresets
        if let data = try? Data(contentsOf: storageURL),
           let saved = try? decoder().decode([AudioEffectChainPreset].self, from: data) {
            let validUser = saved.filter { !$0.isFactory }.map { Self.sanitized($0) }
            combined.append(contentsOf: validUser)
        }
        presets = combined
    }

    @discardableResult
    func saveUserPreset(name: String, scope: AudioPresetScope = .trackChain, slots: [AudioEffectSlot]) throws -> AudioEffectChainPreset {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ConversionError.invalidInput("Preset name cannot be empty.")
        }
        guard !slots.isEmpty else {
            throw ConversionError.invalidInput("Add at least one effect before saving a preset.")
        }
        let clonedSlots = slots.map { slot -> AudioEffectSlot in
            var copy = slot
            copy.id = UUID()
            return copy
        }
        let preset = Self.sanitized(AudioEffectChainPreset(name: cleaned, scope: scope, slots: clonedSlots, isFactory: false))
        presets.append(preset)
        try persistUserPresets()
        return preset
    }

    func renameUserPreset(id: UUID, to newName: String) throws {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ConversionError.invalidInput("Preset name cannot be empty.")
        }
        guard let idx = presets.firstIndex(where: { $0.id == id && !$0.isFactory }) else {
            throw ConversionError.invalidInput("Factory presets cannot be renamed or preset not found.")
        }
        presets[idx].name = cleaned
        try persistUserPresets()
    }

    func deleteUserPreset(id: UUID) throws {
        guard let idx = presets.firstIndex(where: { $0.id == id && !$0.isFactory }) else {
            throw ConversionError.invalidInput("Factory presets cannot be deleted or preset not found.")
        }
        presets.remove(at: idx)
        try persistUserPresets()
    }

    /// Validates and decodes an external preset JSON payload without replacing existing presets on failure.
    @discardableResult
    func importPreset(fromData data: Data) throws -> AudioEffectChainPreset {
        let decoded = try decoder().decode(AudioEffectChainPreset.self, from: data)
        let cleanedName = decoded.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty, !decoded.slots.isEmpty else {
            throw ConversionError.invalidInput("Preset contains empty name or no effects.")
        }
        var imported = Self.sanitized(decoded)
        imported.id = UUID()
        imported.isFactory = false
        imported.name = cleanedName
        presets.append(imported)
        try persistUserPresets()
        return imported
    }

    func instantiatedSlots(for preset: AudioEffectChainPreset) -> [AudioEffectSlot] {
        Self.sanitized(preset).slots.map { slot in
            var s = slot
            s.id = UUID()
            return s
        }
    }

    static func sanitized(_ preset: AudioEffectChainPreset) -> AudioEffectChainPreset {
        var copy = preset
        copy.slots = copy.slots.map { slot in
            var s = slot
            if var eq = s.eq {
                eq.bands = eq.bands.map { b in
                    var bc = b; bc.clamped(); return bc
                }
                s.eq = eq
            }
            s.compressor?.clamped()
            s.limiter?.clamped()
            s.noiseGate?.clamped()
            s.noiseReduction?.clamped()
            s.delay?.clamped()
            s.reverb?.clamped()
            return s
        }
        return copy
    }

    private func persistUserPresets() throws {
        let userOnly = presets.filter { !$0.isFactory }
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder().encode(userOnly)
        let tmp = dir.appendingPathComponent(".\(storageURL.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: storageURL.path) {
            _ = try FileManager.default.replaceItemAt(storageURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: storageURL)
        }
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
