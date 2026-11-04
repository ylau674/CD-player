import AudioToolbox
import CoreAudio
import Foundation
import os

/// The two outputs whose volume and mute are kept together while the CD plays (roadmap decision 19):
/// the macOS default, which the volume keys change, and the directly chosen output that is playing.
public struct VolumeMirrorPair: Hashable, Sendable {
    public let defaultUID: String
    public let outputUID: String

    public init(defaultUID: String, outputUID: String) {
        self.defaultUID = defaultUID
        self.outputUID = outputUID
    }
}

/// Mirrors a pair's volume and mute until given another pair or nil. Calls return at once.
public protocol VolumeMirroring: AnyObject, Sendable {
    func mirror(_ pair: VolumeMirrorPair?)
}

struct OutputVolume: Equatable, Sendable {
    var level: Float32
    /// Nil when the output has no mute control.
    var isMuted: Bool?
}

/// Host volume by output UID. `volume(of:)` is nil when the output has no usable level control.
protocol OutputVolumeControls: AnyObject {
    func volume(of uid: String) -> OutputVolume?
    func setLevel(_ level: Float32, of uid: String)
    func setMuted(_ muted: Bool, of uid: String)
}

/// Decision 19's rules without Core Audio. Not thread-safe: its owner calls it from one queue.
final class VolumeMirrorSync {
    /// Smaller than the finest volume-key step (1/64), larger than float noise.
    static let tolerance: Float32 = 0.0005

    private struct Reading {
        var defaultOutput: OutputVolume
        var output: OutputVolume

        func level(_ side: Side) -> Float32 { side == .output ? output.level : defaultOutput.level }
    }
    private enum Side { case defaultOutput, output }
    /// A level write the read-back did not show yet, from a device that applies writes late.
    private struct PendingLevel {
        let side: Side
        let level: Float32
        let before: Float32
    }

    private let controls: any OutputVolumeControls
    private(set) var pair: VolumeMirrorPair?
    private var last: Reading?
    private var pendingLevel: PendingLevel?

    init(controls: any OutputVolumeControls) {
        self.controls = controls
    }

    /// Starting sets the default's level to the output's, so the output that is playing never jumps;
    /// mute is left as it is on both.
    func setPair(_ pair: VolumeMirrorPair?) {
        guard pair != self.pair else { return }
        self.pair = pair
        last = nil
        pendingLevel = nil
        align()
    }

    /// Copies a change on one side to the other; the default wins when both changed, unless the
    /// default's change is the mirror's own late write.
    func volumesChanged() {
        guard let pair else { return }
        guard let last else {
            align()
            return
        }
        guard let current = read(pair) else { return }
        let defaultMoved = differs(current.defaultOutput.level, last.defaultOutput.level)
        let outputMoved = differs(current.output.level, last.output.level)
        let lateWrite = lateWriteArrived(in: current, defaultMoved: defaultMoved, outputMoved: outputMoved)
        var written: Set<Side> = []
        if defaultMoved && lateWrite != .defaultOutput {
            if write(current.defaultOutput.level, to: .output, over: current.output.level) { written.insert(.output) }
        } else if outputMoved && lateWrite != .output {
            if write(current.output.level, to: .defaultOutput, over: current.defaultOutput.level) {
                written.insert(.defaultOutput)
            }
        }
        if let muted = current.defaultOutput.isMuted, muted != last.defaultOutput.isMuted,
           let outputMuted = current.output.isMuted {
            if outputMuted != muted {
                controls.setMuted(muted, of: pair.outputUID)
                written.insert(.output)
            }
        } else if let muted = current.output.isMuted, muted != last.output.isMuted,
                  let defaultMuted = current.defaultOutput.isMuted {
            if defaultMuted != muted {
                controls.setMuted(muted, of: pair.defaultUID)
                written.insert(.defaultOutput)
            }
        }
        record(current, rereading: written)
    }

    private func align() {
        guard let pair, let current = read(pair) else { return }
        let wrote = write(current.output.level, to: .defaultOutput, over: current.defaultOutput.level)
        record(current, rereading: wrote ? [.defaultOutput] : [])
    }

    @discardableResult
    private func write(_ level: Float32, to side: Side, over current: Float32) -> Bool {
        guard let pair, differs(level, current) else { return false }
        controls.setLevel(level, of: side == .output ? pair.outputUID : pair.defaultUID)
        pendingLevel = PendingLevel(side: side, level: level, before: current)
        return true
    }

    /// A written side is read back, so driver rounding cannot start a loop. The other side keeps the
    /// value this pass acted on: a change that arrived meanwhile is copied by its own listener call.
    private func record(_ current: Reading, rereading written: Set<Side>) {
        var reading = current
        if !written.isEmpty, let pair, let after = read(pair) {
            if written.contains(.defaultOutput) { reading.defaultOutput = after.defaultOutput }
            if written.contains(.output) { reading.output = after.output }
        }
        last = reading
        if let pending = pendingLevel, differs(reading.level(pending.side), pending.before) { pendingLevel = nil }
    }

    /// The side whose change is a pending write arriving: that side moved toward the level written.
    /// Rounding by the device does not matter, and a change on the other side is still copied.
    private func lateWriteArrived(in current: Reading, defaultMoved: Bool, outputMoved: Bool) -> Side? {
        guard let pending = pendingLevel, pending.side == .output ? outputMoved : defaultMoved else { return nil }
        pendingLevel = nil
        let closer = abs(current.level(pending.side) - pending.level) < abs(pending.before - pending.level)
        return closer ? pending.side : nil
    }

    private func read(_ pair: VolumeMirrorPair) -> Reading? {
        guard let defaultOutput = controls.volume(of: pair.defaultUID),
              let output = controls.volume(of: pair.outputUID) else { return nil }
        return Reading(defaultOutput: defaultOutput, output: output)
    }

    private func differs(_ left: Float32, _ right: Float32) -> Bool {
        abs(left - right) > Self.tolerance
    }
}

/// Mirrors through Core Audio. The listener block and all state belong to `queue`.
public final class CoreAudioVolumeMirror: VolumeMirroring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.ylau674.CDPlayer.volume-mirror")
    private let sync = VolumeMirrorSync(controls: CoreAudioVolumeControls())
    private var listener: AudioObjectPropertyListenerBlock?
    private var watched: [(device: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Volume")

    public init() {}

    public func mirror(_ pair: VolumeMirrorPair?) {
        queue.async { [self] in
            guard pair != sync.pair else { return }
            unwatch()
            // Listen before aligning so a change in between is not missed.
            if let pair { watch(pair) }
            sync.setPair(pair)
            if let pair {
                logger.info("Mirroring the volume of \(pair.defaultUID, privacy: .public) to \(pair.outputUID, privacy: .public)")
            } else {
                logger.info("Volume mirroring stopped")
            }
        }
    }

    private func watch(_ pair: VolumeMirrorPair) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.sync.volumesChanged()
        }
        self.listener = listener
        for uid in [pair.defaultUID, pair.outputUID] {
            guard let device = CoreAudioVolumeControls.device(for: uid) else { continue }
            for var address in CoreAudioVolumeControls.watchedAddresses where AudioObjectHasProperty(device, &address) {
                guard AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr else { continue }
                watched.append((device, address))
            }
        }
    }

    private func unwatch() {
        guard let listener else { return }
        for (device, address) in watched {
            var address = address
            // A removed device has already dropped its listeners, so a failure here needs no action.
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
        }
        watched = []
        self.listener = nil
    }
}

/// Reads and writes the level the volume keys move, and mute on the main element or else on the
/// first two channels. Every call resolves the UID, so a reconnected device is found again.
final class CoreAudioVolumeControls: OutputVolumeControls {
    private static let channels: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
    static let watchedAddresses: [AudioObjectPropertyAddress] =
        [address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)]
        + channels.map { address(kAudioDevicePropertyVolumeScalar, $0) }
        + channels.map { address(kAudioDevicePropertyMute, $0) }
    private let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Volume")

    func volume(of uid: String) -> OutputVolume? {
        guard let device = Self.device(for: uid) else { return nil }
        var levelAddress = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard Self.isSettable(device, &levelAddress) else { return nil }
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &levelAddress, 0, nil, &size, &level) == noErr,
              level >= 0, level <= 1 else { return nil }
        return OutputVolume(level: level, isMuted: Self.isMuted(device))
    }

    func setLevel(_ level: Float32, of uid: String) {
        guard let device = Self.device(for: uid) else { return }
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var level = min(max(level, 0), 1)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
        logger.debug("Set volume \(level, format: .fixed(precision: 4)) on \(uid, privacy: .public): \(status)")
    }

    func setMuted(_ muted: Bool, of uid: String) {
        guard let device = Self.device(for: uid) else { return }
        var value: UInt32 = muted ? 1 : 0
        for var address in Self.muteAddresses(device) {
            let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            logger.debug("Set mute \(muted) on \(uid, privacy: .public) element \(address.mElement): \(status)")
        }
    }

    /// Muted when every mute control it has is on.
    private static func isMuted(_ device: AudioObjectID) -> Bool? {
        let addresses = muteAddresses(device)
        guard !addresses.isEmpty else { return nil }
        for var address in addresses {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
            if value == 0 { return false }
        }
        return true
    }

    private static func muteAddresses(_ device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        var main = address(kAudioDevicePropertyMute)
        if isSettable(device, &main) { return [main] }
        return channels.dropFirst().compactMap { channel in
            var candidate = address(kAudioDevicePropertyMute, channel)
            return isSettable(device, &candidate) ? candidate : nil
        }
    }

    static func device(for uid: String) -> AudioObjectID? {
        guard !uid.isEmpty else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), qualifier,
                &size, &device
            )
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isSettable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }
}
