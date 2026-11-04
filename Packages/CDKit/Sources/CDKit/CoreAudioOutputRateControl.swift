import CDAudioCore
import CoreAudio
import Dispatch

public final class CoreAudioOutputRateControl: OutputRateControl {
    /// One call at a time, so a switch never overlaps the quit restore.
    private let queue = DispatchQueue(label: "io.github.ylau674.CDPlayer.output-rate", qos: .userInitiated)

    public init() {}

    public func recoverPendingRates() async throws {
        try await perform {
            var error = CDError()
            guard cd_audio_recover_output_rates(&error) == 0 else {
                throw AudioPlaybackError(error)
            }
        }
    }

    public func matchSourceRate(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo {
        try await perform {
            var info = CDDeviceInfo()
            var error = CDError()
            let result = target.withCoreAudioUID { coreTarget, uid in
                cd_audio_match_source_rate(coreTarget, uid, Double(format.sampleRate), &info, &error)
            }
            guard result == 0 else {
                throw AudioPlaybackError(error)
            }
            return OutputInfo(info)
        }
    }

    public func restoreRate(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo {
        try await perform {
            var info = CDDeviceInfo()
            var error = CDError()
            let result = target.withCoreAudioUID { coreTarget, uid in
                cd_audio_restore_output_rate(coreTarget, uid, Double(format.sampleRate), &info, &error)
            }
            guard result == 0 else {
                throw AudioPlaybackError(error)
            }
            return OutputInfo(info)
        }
    }

    public func restoreChangedRates() async throws {
        try await perform {
            var error = CDError()
            guard cd_audio_restore_output_rates(&error) == 0 else { throw AudioPlaybackError(error) }
        }
    }

    public func discoverOutputs(format: AudioSourceFormat) async throws -> [AudioOutputDevice] {
        try await perform {
            var rawOutputs: UnsafeMutablePointer<CDDeviceInfo>?
            var count = 0
            var error = CDError()
            let sourceRate = Double(format.sampleRate)
            guard cd_audio_copy_output_devices(sourceRate, &rawOutputs, &count, &error) == 0 else {
                throw AudioPlaybackError(error)
            }
            guard let rawOutputs else {
                guard count == 0 else {
                    throw AudioPlaybackError(
                        message: "Core Audio returned an invalid output list.",
                        code: Int32(CD_CORE_AUDIO_ERROR.rawValue), systemStatus: 0
                    )
                }
                return []
            }
            defer { cd_audio_free_output_devices(rawOutputs) }
            return try (0..<count).map { index in
                let info = rawOutputs[index]
                let transport = OutputTransport(coreAudioValue: info.transportType)
                let uid = decodeCString(info.uid)
                guard !uid.isEmpty else {
                    throw AudioPlaybackError(
                        message: "Core Audio returned an output without a UID.",
                        code: Int32(CD_CORE_AUDIO_ERROR.rawValue), systemStatus: 0
                    )
                }
                return AudioOutputDevice(
                    uid: uid, deviceID: info.deviceID, name: decodeCString(info.name), transport: transport,
                    sampleRate: info.sampleRate, hogOwner: info.hogOwner,
                    supportsSourceRate: info.supportsSourceRate,
                    hasStereoOutput: info.outputChannels >= 2, isDefaultOutput: info.isDefaultOutput,
                    terminalType: info.outputTerminalType, usesSpeakers: info.usesSpeakers,
                    restoreRate: info.restoreRate, sourceRate: sourceRate,
                    hasVolumeControl: info.hasVolumeControl
                )
            }
        }
    }

    public func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = OutputChangeMonitor { continuation.yield() }
            continuation.onTermination = { _ in monitor.stop() }
            monitor.start()
        }
    }

    private func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

/// Listens for whatever changes the output Play would use or its rate. Listener blocks run on, and
/// all state belongs to, `queue`; a block must be removed with the instance it was added with.
private final class OutputChangeMonitor: @unchecked Sendable {
    private static let systemProperties = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
    private static let deviceProperties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput),
        (kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal),
        // Older Macs switch one built-in device between speakers and headphones.
        (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
    ]

    private let queue = DispatchQueue(label: "io.github.ylau674.CDPlayer.output-changes")
    private let notify: @Sendable () -> Void
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var watched: [AudioObjectID: [AudioObjectPropertyAddress]] = [:]
    private var stopped = false

    init(notify: @escaping @Sendable () -> Void) {
        self.notify = notify
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            let systemListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.stopped else { return }
                self.watchDevices()
                self.notify()
            }
            let deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, !self.stopped else { return }
                self.notify()
            }
            self.systemListener = systemListener
            self.deviceListener = deviceListener
            for selector in Self.systemProperties {
                var address = Self.address(selector, kAudioObjectPropertyScopeGlobal)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, systemListener)
            }
            watchDevices()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            if let systemListener {
                for selector in Self.systemProperties {
                    var address = Self.address(selector, kAudioObjectPropertyScopeGlobal)
                    AudioObjectRemovePropertyListenerBlock(
                        AudioObjectID(kAudioObjectSystemObject), &address, queue, systemListener
                    )
                }
            }
            for device in Array(watched.keys) { unwatch(device) }
            systemListener = nil
            deviceListener = nil
        }
    }

    private func watchDevices() {
        let devices = Self.devices()
        for device in Array(watched.keys) where !devices.contains(device) { unwatch(device) }
        for device in devices where watched[device] == nil { watch(device) }
    }

    private func watch(_ device: AudioObjectID) {
        guard let deviceListener else { return }
        var added: [AudioObjectPropertyAddress] = []
        for (selector, scope) in Self.deviceProperties {
            var address = Self.address(selector, scope)
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectAddPropertyListenerBlock(device, &address, queue, deviceListener) == noErr else { continue }
            added.append(address)
        }
        watched[device] = added
    }

    private func unwatch(_ device: AudioObjectID) {
        guard let addresses = watched.removeValue(forKey: device), let deviceListener else { return }
        for var address in addresses {
            // A removed device has already dropped its listeners, so a failure here needs no action.
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, deviceListener)
        }
    }

    private static func devices() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return Array(devices.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
