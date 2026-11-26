import Foundation
import Combine
import CoreAudio
import os

// MARK: - Domain Model

/// Persistent-UID-keyed CoreAudio output device snapshot.
/// Note: `deviceID` is transient across reboots/reconnects; always persist `uid`.
struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let nominalSampleRateHz: Double
    let outputChannelCount: Int
    let isDefault: Bool

    var id: String { uid }
}

struct CoreAudioListenerToken: Hashable, Sendable {
    let id: UUID
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
}

// MARK: - CoreAudio HAL Abstraction

/// Hardware abstraction allowing deterministic tests without physical hot-unplugging.
protocol CoreAudioHALBackend: Sendable {
    func allDeviceIDs() -> [AudioDeviceID]
    func defaultOutputDeviceID() -> AudioDeviceID?
    func outputChannelCount(for deviceID: AudioDeviceID) -> Int
    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool
    func deviceUID(for deviceID: AudioDeviceID) -> String?
    func deviceName(for deviceID: AudioDeviceID) -> String?
    func nominalSampleRate(for deviceID: AudioDeviceID) -> Double?

    func addPropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken?

    func removePropertyListener(_ token: CoreAudioListenerToken)
}

/// Production CoreAudio HAL backend using non-deprecated macOS 15+ property selectors.
final class SystemCoreAudioHALBackend: CoreAudioHALBackend, Sendable {
    private struct ListenerEntry {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
    }

    /// Synchronization invariant: `entries` is read and mutated exclusively inside
    /// `lock` so CoreAudio listener block registration and removal remain thread-safe under Swift 6.
    /// (`AudioObjectPropertyListenerBlock` is imported from C without `@Sendable`; the wrapped Swift closure is `@Sendable`.)
    private final class ListenerRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [UUID: ListenerEntry] = [:]

        func insert(id: UUID, entry: ListenerEntry) {
            lock.lock()
            entries[id] = entry
            lock.unlock()
        }

        func remove(id: UUID) -> ListenerEntry? {
            lock.lock()
            defer { lock.unlock() }
            return entries.removeValue(forKey: id)
        }

        func drainAll() -> [ListenerEntry] {
            lock.lock()
            let all = Array(entries.values)
            entries.removeAll()
            lock.unlock()
            return all
        }

        deinit {
            for entry in drainAll() {
                var addr = entry.address
                AudioObjectRemovePropertyListenerBlock(entry.objectID, &addr, entry.queue, entry.block)
            }
        }
    }

    private let registry = ListenerRegistry()

    func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        var actualSize = size
        let status = ids.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let ptr = rawBuffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &actualSize,
                ptr
            )
        }
        guard status == noErr else { return [] }
        let filledCount = min(count, Int(actualSize) / MemoryLayout<AudioDeviceID>.stride)
        return ids.prefix(filledCount).filter { $0 != AudioDeviceID(kAudioObjectUnknown) && $0 != 0 }
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown), deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown), deviceID != 0 else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }
        rawPtr.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))

        var actualSize = size
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &actualSize, rawPtr) == noErr else {
            return 0
        }

        let bufferList = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels = 0
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return max(0, channels)
    }

    func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown), deviceID != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    func deviceUID(for deviceID: AudioDeviceID) -> String? {
        readCFStringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    func deviceName(for deviceID: AudioDeviceID) -> String? {
        readCFStringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown), deviceID != 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> CoreAudioListenerToken? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        guard status == noErr else { return nil }

        let token = CoreAudioListenerToken(
            id: UUID(),
            objectID: objectID,
            selector: selector,
            scope: scope
        )
        registry.insert(
            id: token.id,
            entry: ListenerEntry(
                objectID: objectID,
                address: address,
                queue: queue,
                block: block
            )
        )
        return token
    }

    func removePropertyListener(_ token: CoreAudioListenerToken) {
        guard let entry = registry.remove(id: token.id) else { return }
        var address = entry.address
        AudioObjectRemovePropertyListenerBlock(entry.objectID, &address, entry.queue, entry.block)
    }

    private func readCFStringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown), deviceID != 0 else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanagedString)
        guard status == noErr, let cfString = unmanagedString?.takeRetainedValue() else {
            return nil
        }
        let trimmed = (cfString as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - MainActor Device Monitor

@MainActor
final class CoreAudioOutputDeviceMonitor: ObservableObject {
    @Published private(set) var availableDevices: [AudioOutputDevice] = []
    @Published private(set) var defaultDevice: AudioOutputDevice?
    /// Persistent CoreAudio UID of the user-selected device, or `nil` for System Default.
    @Published private(set) var selectedDeviceUID: String? = nil
    @Published private(set) var isMonitoring: Bool = false

    var activeOutputDevice: AudioOutputDevice? {
        if let uid = selectedDeviceUID {
            return availableDevices.first { $0.uid == uid }
        }
        return defaultDevice ?? availableDevices.first
    }

    var onActiveDeviceDisconnected: (@MainActor (_ disconnectedUID: String, _ fallbackDevice: AudioOutputDevice?) -> Void)?
    var onDefaultDeviceChanged: (@MainActor (_ newDefault: AudioOutputDevice?) -> Void)?
    var onActiveDeviceSampleRateChanged: (@MainActor (_ device: AudioOutputDevice) -> Void)?

    private let backend: any CoreAudioHALBackend
    private let halQueue = DispatchQueue(
        label: "com.localconvert.audioworkspace.coreaudio.monitor",
        qos: .utility
    )

    private var systemListenerTokens: [CoreAudioListenerToken] = []
    private var deviceListenerTokens: [CoreAudioListenerToken] = []
    private var watchedDeviceID: AudioDeviceID?
    private var observedActiveSampleRate: Double?

    private let cleanupLock: OSAllocatedUnfairLock<(backend: any CoreAudioHALBackend, tokens: [CoreAudioListenerToken])>

    init(backend: any CoreAudioHALBackend = SystemCoreAudioHALBackend()) {
        self.backend = backend
        self.cleanupLock = OSAllocatedUnfairLock(initialState: (backend: backend, tokens: []))
        refreshDevices()
    }

    deinit {
        let pending = cleanupLock.withLock { state -> (backend: any CoreAudioHALBackend, tokens: [CoreAudioListenerToken]) in
            let copy = state
            state.tokens.removeAll()
            return copy
        }
        for token in pending.tokens {
            pending.backend.removePropertyListener(token)
        }
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        registerSystemListeners()
        refreshDevices()
    }

    func stopMonitoring() {
        isMonitoring = false
        removeDeviceListeners()
        removeSystemListeners()
        syncCleanupTokens()
    }

    /// Re-enumerates live output devices, filters out input-only or invalid devices,
    /// detects disconnect fallback and default/sample-rate updates.
    func refreshDevices() {
        let previousDefaultUID = defaultDevice?.uid
        let previousSelectedUID = selectedDeviceUID
        let previousRate = observedActiveSampleRate
        let previousActiveUID = activeOutputDevice?.uid

        let rawIDs = backend.allDeviceIDs()
        let defaultID = backend.defaultOutputDeviceID()

        var seenUIDs = Set<String>()
        var filtered: [AudioOutputDevice] = []

        for devID in rawIDs {
            guard devID != AudioDeviceID(kAudioObjectUnknown), devID != 0 else { continue }
            guard backend.isDeviceAlive(devID) else { continue }
            let channelCount = backend.outputChannelCount(for: devID)
            guard channelCount > 0 else { continue }
            guard let uid = backend.deviceUID(for: devID),
                  seenUIDs.insert(uid).inserted else { continue }
            guard let sampleRate = backend.nominalSampleRate(for: devID),
                  sampleRate.isFinite, sampleRate > 0 else { continue }
            let name = backend.deviceName(for: devID) ?? "Output Device"

            filtered.append(AudioOutputDevice(
                deviceID: devID,
                uid: uid,
                name: name,
                nominalSampleRateHz: sampleRate,
                outputChannelCount: channelCount,
                isDefault: devID == defaultID
            ))
        }

        filtered.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        availableDevices = filtered
        defaultDevice = filtered.first(where: \.isDefault) ?? filtered.first

        var disconnectedUID: String?
        if let selectedUID = previousSelectedUID,
           !filtered.contains(where: { $0.uid == selectedUID }) {
            selectedDeviceUID = nil
            disconnectedUID = selectedUID
        }

        let currentActive = activeOutputDevice
        observedActiveSampleRate = currentActive?.nominalSampleRateHz

        if isMonitoring {
            updateWatchedDeviceListenersIfNeeded(for: currentActive?.deviceID)
        }

        if let disconnectedUID {
            StructuredDiagnostics.recordAudioEvent(
                category: .audioPlayer,
                severity: .validation,
                stage: "output_device_disconnected",
                message: "Selected output device disconnected; falling back to system default."
            )
            onActiveDeviceDisconnected?(disconnectedUID, defaultDevice)
        }

        if previousDefaultUID != defaultDevice?.uid {
            onDefaultDeviceChanged?(defaultDevice)
        }

        if disconnectedUID == nil,
           let currentActive,
           previousActiveUID == currentActive.uid,
           let previousRate,
           abs(previousRate - currentActive.nominalSampleRateHz) > 0.5 {
            onActiveDeviceSampleRateChanged?(currentActive)
        }
    }

    /// Selects a persistent output device UID, or `nil` for System Default.
    @discardableResult
    func selectDevice(uid: String?) -> Bool {
        if let uid {
            if !availableDevices.contains(where: { $0.uid == uid }) {
                refreshDevices()
            }
            guard let matched = availableDevices.first(where: { $0.uid == uid }) else {
                return false
            }
            selectedDeviceUID = matched.uid
            observedActiveSampleRate = matched.nominalSampleRateHz
        } else {
            selectedDeviceUID = nil
            observedActiveSampleRate = defaultDevice?.nominalSampleRateHz
        }

        if isMonitoring {
            updateWatchedDeviceListenersIfNeeded(for: activeOutputDevice?.deviceID)
        }
        return true
    }

    func resolveDevice(forUID uid: String?) -> AudioOutputDevice? {
        guard let uid else { return defaultDevice }
        if let hit = availableDevices.first(where: { $0.uid == uid }) {
            return hit
        }
        refreshDevices()
        return availableDevices.first(where: { $0.uid == uid })
    }

    // MARK: - Private Listener Plumbing

    private func registerSystemListeners() {
        removeSystemListeners()
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice
        ]

        for selector in selectors {
            if let token = backend.addPropertyListener(
                objectID: systemID,
                selector: selector,
                scope: kAudioObjectPropertyScopeGlobal,
                queue: halQueue,
                handler: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.refreshDevices()
                    }
                }
            ) {
                systemListenerTokens.append(token)
            }
        }
        syncCleanupTokens()
    }

    private func removeSystemListeners() {
        for token in systemListenerTokens {
            backend.removePropertyListener(token)
        }
        systemListenerTokens.removeAll()
    }

    private func updateWatchedDeviceListenersIfNeeded(for deviceID: AudioDeviceID?) {
        guard deviceID != watchedDeviceID else { return }
        removeDeviceListeners()
        watchedDeviceID = deviceID

        guard let deviceID,
              deviceID != AudioDeviceID(kAudioObjectUnknown),
              deviceID != 0 else {
            syncCleanupTokens()
            return
        }

        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyDeviceIsAlive,
            kAudioDevicePropertyNominalSampleRate
        ]

        for selector in selectors {
            if let token = backend.addPropertyListener(
                objectID: deviceID,
                selector: selector,
                scope: kAudioObjectPropertyScopeGlobal,
                queue: halQueue,
                handler: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.refreshDevices()
                    }
                }
            ) {
                deviceListenerTokens.append(token)
            }
        }
        syncCleanupTokens()
    }

    private func removeDeviceListeners() {
        for token in deviceListenerTokens {
            backend.removePropertyListener(token)
        }
        deviceListenerTokens.removeAll()
        watchedDeviceID = nil
    }

    private func syncCleanupTokens() {
        let all = systemListenerTokens + deviceListenerTokens
        cleanupLock.withLock { state in
            state.tokens = all
        }
    }
}
