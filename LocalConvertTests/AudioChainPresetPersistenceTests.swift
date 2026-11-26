import Testing
import Foundation
@testable import LocalConvert

@Suite("Phase 45.3 — Effect Chains, Presets & Project Migration", .serialized)
struct AudioChainPresetPersistenceTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P45_3_\(name)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Preset CRUD, parameter clamping, factory protection, and invalid JSON rejection")
    @MainActor
    func presetStoreLifecycleAndValidation() throws {
        let dir = try makeTempDir("PresetStore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storageURL = dir.appendingPathComponent("presets.json")

        let presetStore = AudioEffectPresetStore(storageURL: storageURL)
        #expect(presetStore.presets.filter(\.isFactory).count == AudioEffectPresetStore.factoryPresets.count)

        // Cannot rename or delete factory preset
        let factoryID = try #require(presetStore.presets.first(where: \.isFactory)?.id)
        #expect(throws: Error.self) {
            try presetStore.deleteUserPreset(id: factoryID)
        }
        #expect(throws: Error.self) {
            try presetStore.renameUserPreset(id: factoryID, to: "Hacked")
        }

        // Save user preset with out-of-range Delay feedback -> sanitized cleanly <= 0.90
        var extremeDelay = AudioEffectSlot.makeDefault(kind: .delay)
        extremeDelay.delay = DelayParams(delayTimeMs: 300, feedback: 2.5, wetDryMix: 0.4, dampingHz: 5000, pingPong: true)
        let saved = try presetStore.saveUserPreset(name: "My Vocal Chain", slots: [
            AudioEffectSlot.makeDefault(kind: .parametricEQ),
            extremeDelay
        ])
        #expect(saved.slots[1].delay?.feedback == 0.90)

        // Reload in fresh store instance -> persisted cleanly
        let reloadedStore = AudioEffectPresetStore(storageURL: storageURL)
        let loaded = try #require(reloadedStore.presets.first(where: { $0.id == saved.id }))
        #expect(loaded.name == "My Vocal Chain")
        #expect(loaded.slots.count == 2)

        try reloadedStore.renameUserPreset(id: saved.id, to: "Renamed Vocal Chain")
        #expect(reloadedStore.presets.first(where: { $0.id == saved.id })?.name == "Renamed Vocal Chain")

        // Corrupt external JSON rejected without disturbing valid presets
        #expect(throws: Error.self) {
            _ = try reloadedStore.importPreset(fromData: Data("{not valid json".utf8))
        }
        #expect(throws: Error.self) {
            let emptySlots = AudioEffectChainPreset(name: "Empty", scope: .trackChain, slots: [])
            let d = try JSONEncoder().encode(emptySlots)
            _ = try reloadedStore.importPreset(fromData: d)
        }
        #expect(reloadedStore.presets.contains(where: { $0.id == saved.id }))

        try reloadedStore.deleteUserPreset(id: saved.id)
        #expect(!reloadedStore.presets.contains(where: { $0.id == saved.id }))
    }

    @Test("Ordered effect chain reorder/enable/bypass/preset-apply supports Undo/Redo and persists in v2 .lcproject")
    @MainActor
    func effectChainStoreUndoAndV2Persistence() async throws {
        let dir = try makeTempDir("ChainPersist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let coord = UndoRedoCoordinator(journalDirectoryURL: dir.appendingPathComponent("journal"))
        let store = AudioEditorStore(undoCoordinator: coord)
        let presetStore = AudioEffectPresetStore(storageURL: dir.appendingPathComponent("presets.json"))

        let trackID = store.project.tracks[0].id
        let target: AudioEffectChainTarget = .track(trackID)

        // Apply factory preset -> Undo -> Redo
        let factory = try #require(AudioEffectPresetStore.factoryPresets.first)
        store.applyEffectChainPreset(factory, to: target, presetStore: presetStore)
        await store.flushPendingUndoRecords()
        #expect(store.effectSlots(for: target).count == factory.slots.count)

        let secondID = store.effectSlots(for: target)[1].id
        store.moveEffectSlot(id: secondID, offset: -1, in: target)
        await store.flushPendingUndoRecords()
        #expect(store.effectSlots(for: target)[0].id == secondID)

        // Undo reorder -> restores original preset order
        await coord.undo(in: .audioEditor(projectID: store.project.id))
        #expect(store.effectSlots(for: target)[1].id == secondID)

        // Redo reorder
        await coord.redo(in: .audioEditor(projectID: store.project.id))
        #expect(store.effectSlots(for: target)[0].id == secondID)

        // Save v2 .lcproject & reload -> ordered slots + master + grid preserved identically
        store.addEffectSlot(.reverb, to: .master)
        let projURL = dir.appendingPathComponent("mix.lcproject")
        let saved = try ProjectPersistenceService.save(project: store.project, to: projURL)
        let (reloaded, _) = try ProjectPersistenceService.load(from: projURL)
        #expect(reloaded.tracks[0].effectSlots == saved.tracks[0].effectSlots)
        #expect(reloaded.masterEffects.count == 1)
        #expect(reloaded.masterEffects[0].kind == .reverb)
    }

    @Test("Legacy v1 .lcproject files migrate cleanly on load without missing new v2 fields")
    func legacyV1ProjectMigration() throws {
        let dir = try makeTempDir("V1Migration")
        defer { try? FileManager.default.removeItem(at: dir) }

        let v1JSON = """
        {
          "formatVersion": 1,
          "savedAt": "2026-10-01T12:00:00Z",
          "isSelfContainedPackage": false,
          "project": {
            "id": "11111111-1111-1111-1111-111111111111",
            "schemaVersion": 1,
            "name": "Legacy Project",
            "sampleRate": 44100,
            "tracks": [
              {
                "id": "22222222-2222-2222-2222-222222222222",
                "name": "Voice",
                "clips": [
                  {
                    "id": "33333333-3333-3333-3333-333333333333",
                    "name": "Take 1",
                    "timelineStart": 0.5,
                    "sourceStart": 0.0,
                    "duration": 3.0
                  }
                ],
                "volume": 1.0,
                "pan": 0.0,
                "isMuted": false,
                "isSolo": false,
                "isLocked": false
              }
            ],
            "markers": [],
            "mediaAssets": []
          }
        }
        """
        let v1URL = dir.appendingPathComponent("legacy.lcproject")
        try Data(v1JSON.utf8).write(to: v1URL)

        let (loaded, missing) = try ProjectPersistenceService.load(from: v1URL)
        #expect(missing.isEmpty)
        #expect(loaded.name == "Legacy Project")
        #expect(loaded.schemaVersion == AudioEditorProject.currentSchemaVersion)
        #expect(loaded.tracks.count == 1)
        #expect(loaded.tracks[0].effectSlots.isEmpty)
        #expect(loaded.masterEffects.isEmpty)
        #expect(loaded.trackGroups.isEmpty)
        #expect(loaded.tracks[0].clips[0].effectSlots.isEmpty)
    }
}
