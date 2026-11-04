import CDAudioCore
import CDKit
import CoreAudio
import Dispatch
import Foundation

struct OutputStateFormat: Codable, Equatable, Sendable {
    var sampleRate: Double
    var formatID: UInt32
    var flags: UInt32
    var bytesPerPacket: UInt32
    var framesPerPacket: UInt32
    var bytesPerFrame: UInt32
    var channels: UInt32
    var bitsPerChannel: UInt32
    var reserved: UInt32

    init(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        formatID = format.mFormatID
        flags = format.mFormatFlags
        bytesPerPacket = format.mBytesPerPacket
        framesPerPacket = format.mFramesPerPacket
        bytesPerFrame = format.mBytesPerFrame
        channels = format.mChannelsPerFrame
        bitsPerChannel = format.mBitsPerChannel
        reserved = format.mReserved
    }

    var asbd: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: flags,
            mBytesPerPacket: bytesPerPacket, mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel, mReserved: reserved
        )
    }

    var description: String {
        let representation = formatID != kAudioFormatLinearPCM
            ? "non-PCM" : flags & kAudioFormatFlagIsFloat != 0 ? "float" : "integer"
        return "\(sampleRate) Hz, \(channels) ch, \(bitsPerChannel)-bit \(representation), " +
            String(format: "format 0x%08x, flags 0x%x", formatID, flags) +
            ", \(bytesPerFrame) B/frame, \(bytesPerPacket) B/packet, " +
            "\(framesPerPacket) frames/packet, reserved \(reserved)"
    }
}

struct OutputStateRateRange: Codable, Equatable, Sendable {
    var minimum: Double
    var maximum: Double

    func contains(_ rate: Double) -> Bool { minimum <= rate && rate <= maximum }
    var isValid: Bool { minimum.isFinite && maximum.isFinite && minimum > 0 && maximum >= minimum }
}

struct OutputStateFormatRange: Codable, Equatable, Sendable {
    var format: OutputStateFormat
    var rates: OutputStateRateRange

    var rangedDescription: AudioStreamRangedDescription {
        AudioStreamRangedDescription(
            mFormat: format.asbd,
            mSampleRateRange: AudioValueRange(mMinimum: rates.minimum, mMaximum: rates.maximum)
        )
    }
}

enum OutputStateDirection: String, Codable, Sendable {
    case input, output
}

struct OutputStateStream: Codable, Equatable, Sendable {
    var objectID: UInt32
    var direction: OutputStateDirection
    var startingChannel: UInt32
    var virtualFormat: OutputStateFormat
    var physicalFormat: OutputStateFormat
    var virtualSettable: Bool
    var physicalSettable: Bool
    var availableVirtualFormats: [OutputStateFormatRange]?
    var availablePhysicalFormats: [OutputStateFormatRange]?

    var key: String { "\(direction.rawValue):\(startingChannel)" }

    var stereoPair: (virtual: OutputStateFormat, physical: OutputStateFormat)? {
        let virtualFormats = (availableVirtualFormats ?? []).map(\.rangedDescription)
        let physicalFormats = (availablePhysicalFormats ?? []).map(\.rangedDescription)
        var virtual = AudioStreamBasicDescription()
        var physical = AudioStreamBasicDescription()
        let found = virtualFormats.withUnsafeBufferPointer { virtualBuffer in
            physicalFormats.withUnsafeBufferPointer { physicalBuffer in
                cd_audio_choose_stereo_formats(
                    cd_source_format_compact_disc(), virtualBuffer.baseAddress, virtualBuffer.count, physicalBuffer.baseAddress,
                    physicalBuffer.count, &virtual, &physical
                )
            }
        }
        return found ? (OutputStateFormat(virtual), OutputStateFormat(physical)) : nil
    }
}

struct OutputStateDevice: Codable, Equatable, Sendable {
    var objectID: UInt32
    var uid: String
    var name: String
    var transport: UInt32
    var alive: Bool
    var running: Bool
    var nominalRate: Double
    var nominalRateSettable: Bool
    var availableRates: [OutputStateRateRange]?
    var hogOwner: Int32?
    var preferredStereoChannels: [UInt32]?
    var streams: [OutputStateStream]
    var controls: [String: Double]

    static func isWired(_ transport: UInt32) -> Bool {
        [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI,
         kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt].contains(transport)
    }

    var outputs: [OutputStateStream] { streams.filter { $0.direction == .output } }

    var routeDescription: String {
        guard outputs.count == 1, let stream = outputs.first else {
            return "\(outputs.count) output streams; AUHAL mapping requires separate PCM/channel checks"
        }
        if let pair = stream.stereoPair {
            return "advertised stereo preference:\n    virtual: \(pair.virtual.description)\n" +
                "    physical: \(pair.physical.description)"
        }
        return "no advertised compatible stereo pair; retain layout and verify native PCM during playback"
    }
}

struct OutputStateSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var captureID: String
    var capturedAtUnixTime: Double
    var defaultOutputUID: String?
    var defaultSystemOutputUID: String?
    var defaultInputUID: String?
    var devices: [OutputStateDevice]

    func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: captureID) != nil,
              capturedAtUnixTime.isFinite, capturedAtUnixTime > 0 else {
            throw CheckError.failed("Invalid output-state snapshot header or unsupported schema version.")
        }
        guard Set(devices.map(\.uid)).count == devices.count else {
            throw CheckError.failed("Output-state snapshot contains duplicate device UIDs.")
        }
        for device in devices {
            guard !device.uid.isEmpty, device.nominalRate.isFinite, device.nominalRate > 0,
                  device.controls.values.allSatisfy(\.isFinite),
                  (device.availableRates ?? []).allSatisfy(\.isValid),
                  Set(device.streams.map(\.key)).count == device.streams.count else {
                throw CheckError.failed("Invalid or duplicate device/stream data for \(device.name).")
            }
            for stream in device.streams {
                guard stream.startingChannel > 0 else {
                    throw CheckError.failed("Invalid starting channel for \(device.name), \(stream.key).")
                }
                for format in [stream.virtualFormat, stream.physicalFormat] {
                    guard format.sampleRate.isFinite, format.sampleRate > 0,
                          format.formatID != 0, format.channels > 0 else {
                        throw CheckError.failed("Invalid current stream format for \(device.name), \(stream.key).")
                    }
                }
                let available = (stream.availableVirtualFormats ?? []) + (stream.availablePhysicalFormats ?? [])
                guard available.allSatisfy({ $0.rates.isValid && $0.format.sampleRate.isFinite }) else {
                    throw CheckError.failed("Invalid advertised format range for \(device.name), \(stream.key).")
                }
            }
        }
    }

    var summary: String {
        var lines = ["Read-only wired-device snapshot \(captureID).",
                     "System default output UID: \(defaultOutputUID ?? "none")"]
        for device in devices {
            lines.append("\(device.name): UID \(device.uid)")
            lines.append("  \(device.nominalRate) Hz; rate settable \(device.nominalRateSettable); " +
                         "running \(device.running); hog owner \(device.hogOwner.map(String.init) ?? "not exposed")")
            for stream in device.streams {
                lines.append("  \(stream.key) virtual: \(stream.virtualFormat.description)")
                lines.append("  \(stream.key) physical: \(stream.physicalFormat.description)")
                lines.append("  format properties settable: virtual \(stream.virtualSettable), " +
                             "physical \(stream.physicalSettable)")
            }
            if !device.outputs.isEmpty { lines.append("  Plan only: \(device.routeDescription)") }
            for key in device.controls.keys.sorted() {
                if let value = device.controls[key] { lines.append("  \(key): \(value)") }
            }
        }
        lines.append("No playback, disc access, setters or preference recovery. Capabilities do not prove a successful format change.")
        return lines.joined(separator: "\n")
    }
}

enum OutputStatePhase: String, Sendable {
    case before, during, crashed, after

    /// A killed run must leave the target's 44.1 kHz formats behind, otherwise recovery has nothing to prove.
    var expectsChangedTarget: Bool { self == .during || self == .crashed }
}

enum OutputStateVerification {
    static func issues(
        before: OutputStateSnapshot, observed: OutputStateSnapshot?,
        phase: OutputStatePhase, uid: String
    ) throws -> [String] {
        try before.validate()
        guard let target = before.devices.first(where: { $0.uid == uid }) else {
            return ["The requested output UID is absent from the baseline: \(uid)."]
        }
        var issues = readinessIssues(target)
        if phase == .before { return issues }
        guard let observed else { throw CheckError.failed("The \(phase.rawValue) phase needs an observed snapshot.") }
        try observed.validate()
        guard observed.captureID != before.captureID, observed.capturedAtUnixTime > before.capturedAtUnixTime else {
            throw CheckError.failed("The observed snapshot must be a new capture taken after the baseline.")
        }
        if !issues.isEmpty { return issues.map { "Baseline not ready: \($0)" } }
        if before.defaultOutputUID != observed.defaultOutputUID { issues.append("The system default output changed.") }
        if before.defaultSystemOutputUID != observed.defaultSystemOutputUID { issues.append("The system-effects output changed.") }
        if before.defaultInputUID != observed.defaultInputUID { issues.append("The default input changed.") }
        let actualDevices = Dictionary(uniqueKeysWithValues: observed.devices.map { ($0.uid, $0) })
        let originalUIDs = Set(before.devices.map(\.uid))
        for added in Set(actualDevices.keys).subtracting(originalUIDs).sorted() {
            issues.append("A wired device appeared: \(added).")
        }
        for original in before.devices {
            guard let actual = actualDevices[original.uid] else {
                issues.append("A wired device disappeared: \(original.name) (\(original.uid)).")
                continue
            }
            let activeTarget = phase.expectsChangedTarget && original.uid == uid
            if actual.transport != original.transport || actual.alive != original.alive {
                issues.append("\(original.name): transport or alive state changed.")
            }
            if actual.hogOwner != original.hogOwner { issues.append("\(original.name): exclusive ownership changed.") }
            if actual.running != ((activeTarget && phase == .during) || original.running) {
                issues.append("\(original.name): unexpected running/idle state.")
            }
            if actual.nominalRate != (activeTarget ? 44_100 : original.nominalRate) {
                issues.append("\(original.name): expected \(activeTarget ? 44_100 : original.nominalRate) Hz, " +
                              "observed \(actual.nominalRate) Hz.")
            }
            if actual.preferredStereoChannels != original.preferredStereoChannels {
                issues.append("\(original.name): preferred stereo channels changed.")
            }
            for key in Set(original.controls.keys).union(actual.controls.keys).sorted() {
                if original.controls[key] != actual.controls[key] {
                    issues.append("\(original.name): protected control \(key) changed from " +
                                  "\(original.controls[key].map(String.init(describing:)) ?? "not exposed") to " +
                                  "\(actual.controls[key].map(String.init(describing:)) ?? "not exposed").")
                }
            }
            let streams = Dictionary(uniqueKeysWithValues: actual.streams.map { ($0.key, $0) })
            if Set(streams.keys) != Set(original.streams.map(\.key)) {
                issues.append("\(original.name): stream topology changed.")
            }
            for stream in original.streams {
                guard let current = streams[stream.key] else { continue }
                let label = "\(original.name), \(stream.key)"
                if !activeTarget || stream.direction == .input {
                    compareFormats(stream.virtualFormat, stream.physicalFormat, current, label, &issues)
                } else if original.outputs.count == 1, let pair = stream.stereoPair {
                    compareFormats(pair.virtual, pair.physical, current, label, &issues)
                } else {
                    var virtual = current.virtualFormat.asbd
                    var physical = current.physicalFormat.asbd
                    let native = original.outputs.count == 1
                        ? cd_audio_format_supports_native_playback(cd_source_format_compact_disc(), &virtual, &physical, true)
                        : virtual.mSampleRate == 44_100 && physical.mSampleRate == 44_100 &&
                            virtual.mFormatID == kAudioFormatLinearPCM && physical.mFormatID == kAudioFormatLinearPCM &&
                            physical.mBitsPerChannel >= 16
                    if !native { issues.append("\(label): fallback stream is not compatible native 44.1 kHz PCM.") }
                    if current.virtualFormat.channels != stream.virtualFormat.channels ||
                        current.physicalFormat.channels != stream.physicalFormat.channels {
                        issues.append("\(label): fallback must retain the original channel counts.")
                    }
                }
            }
        }
        return issues
    }

    private static func readinessIssues(_ device: OutputStateDevice) -> [String] {
        var issues: [String] = []
        if !OutputStateDevice.isWired(device.transport) { issues.append("The target is not a wired output.") }
        if !device.alive { issues.append("The target is not alive.") }
        if device.running { issues.append("The target is already running; do not start a silent test.") }
        if let owner = device.hogOwner, owner != -1 { issues.append("Another process owns the target exclusively: \(owner).") }
        if !(device.availableRates ?? []).contains(where: { $0.contains(44_100) }) {
            issues.append("The target does not advertise nominal 44.1 kHz support.")
        }
        if device.nominalRate != 44_100 && !device.nominalRateSettable {
            issues.append("The nominal rate needs changing but is read-only.")
        }
        if device.outputs.reduce(UInt64(0), { $0 + UInt64($1.virtualFormat.channels) }) < 2 {
            issues.append("The target has fewer than two output channels.")
        }
        if device.outputs.count == 1, let stream = device.outputs.first, let pair = stream.stereoPair,
           pair.virtual != stream.virtualFormat || pair.physical != stream.physicalFormat {
            if !stream.virtualSettable || !stream.physicalSettable {
                issues.append("The advertised stereo preference needs stream-format properties that are read-only.")
            }
        }
        return issues
    }

    private static func compareFormats(
        _ virtual: OutputStateFormat, _ physical: OutputStateFormat,
        _ actual: OutputStateStream, _ label: String, _ issues: inout [String]
    ) {
        if virtual != actual.virtualFormat {
            issues.append("\(label): virtual format differs. Expected [\(virtual.description)]; " +
                          "observed [\(actual.virtualFormat.description)].")
        }
        if physical != actual.physicalFormat {
            issues.append("\(label): physical format differs. Expected [\(physical.description)]; " +
                          "observed [\(actual.physicalFormat.description)].")
        }
    }
}

enum OutputStateCommand: Equatable, Sendable {
    case capture(path: String)
    case verify(phase: OutputStatePhase, before: String, observed: String?, uid: String)
    case recover

    private static let queue = DispatchQueue(label: "io.github.ylau674.CDPlayer.output-state", qos: .userInitiated)

    static let usage = "AudioCheck --capture-output-state <new.json> | " +
        "--verify-output-state before <before.json> --output-uid <UID> | " +
        "--verify-output-state <during|crashed|after> <before.json> <observed.json> --output-uid <UID> | " +
        "--recover-output-rates"

    static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.contains("--capture-output-state") || arguments.contains("--verify-output-state") ||
              arguments.contains("--recover-output-rates") else {
            return nil
        }
        if arguments == ["--recover-output-rates"] { return .recover }
        func value(_ text: String) -> Bool { !text.isEmpty && !text.hasPrefix("--") }
        if arguments.first == "--capture-output-state", arguments.count == 2, value(arguments[1]) {
            return .capture(path: arguments[1])
        }
        if arguments.first == "--verify-output-state", arguments.count >= 5,
           let phase = OutputStatePhase(rawValue: arguments[1]) {
            let uidIndex = phase == .before ? 3 : 4
            guard arguments.count == uidIndex + 2, arguments[uidIndex] == "--output-uid",
                  arguments[2..<uidIndex].allSatisfy(value), value(arguments[uidIndex + 1]) else {
                throw CheckError.failed(usage)
            }
            return .verify(phase: phase, before: arguments[2],
                           observed: phase == .before ? nil : arguments[3], uid: arguments[uidIndex + 1])
        }
        throw CheckError.failed(usage)
    }

    func run() async throws {
        if self == .recover {
            try await Self.recoverPendingOutputRates()
            return
        }
        let operation: @Sendable () throws -> String = {
            switch self {
            case .capture(let path):
                let snapshot = try CoreAudioOutputState.capture()
                try snapshot.validate()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                return "Saved snapshot to \(path).\n\(snapshot.summary)"
            case .recover:
                preconditionFailure("Recovery is handled before the offline worker.")
            case .verify(let phase, let beforePath, let observedPath, let uid):
                let decoder = JSONDecoder()
                let before = try decoder.decode(OutputStateSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: beforePath)))
                let observed = try observedPath.map {
                    try decoder.decode(OutputStateSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
                }
                let issues = try OutputStateVerification.issues(before: before, observed: observed, phase: phase, uid: uid)
                guard issues.isEmpty else {
                    throw CheckError.failed("\(phase.rawValue) configuration check failed:\n- " + issues.joined(separator: "\n- "))
                }
                return "PASS: \(phase.rawValue) configuration checks for UID \(uid).\n" +
                    "Offline snapshot comparison only; this does not prove PCM delivery, channel placement or crash recovery."
            }
        }
        let output: String = try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try operation() }) }
        }
        print(output)
    }

    /// Runs the app's launch-time crash recovery and fails unless every saved record is resolved.
    private static func recoverPendingOutputRates() async throws {
        let pending = try await onWorker { try RecoveryRecords.read() }
        print(RecoveryRecords.summary("Saved before recovery", pending))
        try await CoreAudioOutputRateControl().recoverPendingRates()
        let remaining = try await onWorker { try RecoveryRecords.read() }
        guard remaining.isEmpty else {
            throw CheckError.failed(RecoveryRecords.summary("Still saved after recovery", remaining))
        }
        print(pending.isEmpty
              ? "PASS: no saved output-rate or stream-format records needed recovery."
              : "PASS: recovery resolved and cleared \(pending.count) saved record(s).")
        print("No volume, mute, default route or drive setting was changed.")
    }

    private static func onWorker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

/// Read-only view of the recovery records `CDAudioCore` saves in the app's preferences.
struct RecoveryRecord: Equatable, Sendable {
    var uid: String
    var originalRate: Double
    var appliedRate: Double
    var hasFormatChange: Bool
}

enum RecoveryRecords {
    static let domain = "io.github.ylau674.CDPlayer"
    static let key = "ChangedOutputRates"

    static func read() throws -> [RecoveryRecord] {
        CFPreferencesAppSynchronize(domain as CFString)
        return try parse(CFPreferencesCopyAppValue(key as CFString, domain as CFString))
    }

    static func parse(_ stored: Any?) throws -> [RecoveryRecord] {
        guard let stored else { return [] }
        guard let array = stored as? [Any] else { throw CheckError.failed("Saved recovery records are malformed.") }
        return try array.map { value in
            guard let record = value as? [String: Any], let uid = record["uid"] as? String, !uid.isEmpty,
                  let original = (record["originalRate"] as? NSNumber)?.doubleValue,
                  let applied = (record["appliedRate"] as? NSNumber)?.doubleValue else {
                throw CheckError.failed("A saved recovery record is malformed.")
            }
            let formatKeys = ["originalVirtualFormat", "appliedVirtualFormat",
                              "originalPhysicalFormat", "appliedPhysicalFormat"]
            return RecoveryRecord(uid: uid, originalRate: original, appliedRate: applied,
                                  hasFormatChange: formatKeys.contains { record[$0] != nil })
        }
    }

    static func summary(_ title: String, _ records: [RecoveryRecord]) -> String {
        guard !records.isEmpty else { return "\(title): none." }
        return "\(title):\n" + records.map {
            "- \($0.uid): original \($0.originalRate) Hz, applied \($0.appliedRate) Hz" +
                ($0.hasFormatChange ? ", with stream formats" : "")
        }.joined(separator: "\n")
    }
}
