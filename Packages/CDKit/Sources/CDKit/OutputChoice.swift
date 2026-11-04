import CoreAudio
import Foundation

public enum OutputTransport: Hashable, Sendable {
    case builtIn
    case usb
    case hdmi
    case displayPort
    case thunderbolt
    case bluetooth
    case bluetoothLE
    case airPlay
    case aggregate
    case virtual
    case other(UInt32)

    public var title: String {
        switch self {
        case .builtIn: "Built-in"
        case .usb: "USB"
        case .hdmi: "HDMI"
        case .displayPort: "DisplayPort"
        case .thunderbolt: "Thunderbolt"
        case .bluetooth: "Bluetooth"
        case .bluetoothLE: "Bluetooth LE"
        case .airPlay: "AirPlay"
        case .aggregate: "Aggregate"
        case .virtual: "Virtual"
        case .other: "Other"
        }
    }

    public var isSelectableWiredOutput: Bool {
        switch self {
        case .builtIn, .usb, .hdmi, .displayPort, .thunderbolt: true
        case .bluetooth, .bluetoothLE, .airPlay, .aggregate, .virtual, .other: false
        }
    }

    /// The SF Symbol for an output of this type. Built-in and Bluetooth outputs are either speakers
    /// or headphones; a USB output is shown by its connection even when it reports a speaker terminal.
    public func symbol(usesSpeakers: Bool) -> String {
        switch self {
        case .builtIn: usesSpeakers ? "speaker.wave.2" : "headphones"
        case .usb: "cable.connector"
        case .hdmi: "tv"
        case .displayPort: "display"
        case .thunderbolt: "bolt"
        case .airPlay: "airplayaudio"
        case .bluetooth, .bluetoothLE: usesSpeakers ? "hifispeaker" : "headphones"
        case .aggregate, .virtual, .other: "hifispeaker"
        }
    }

    var preferenceRank: Int {
        switch self {
        case .builtIn: 0
        case .usb: 1
        case .hdmi: 2
        case .displayPort: 3
        case .thunderbolt: 4
        case .bluetooth, .bluetoothLE, .airPlay, .aggregate, .virtual, .other: 5
        }
    }

    init(coreAudioValue: UInt32) {
        switch coreAudioValue {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        default: self = .other(coreAudioValue)
        }
    }
}

/// An output found in Core Audio. Its UID remains stable when Core Audio recreates the device
/// object after reconnection; the object ID is only for the current hardware session.
public struct AudioOutputDevice: Equatable, Sendable, Identifiable {
    public let id: String
    public let deviceID: UInt32
    public let name: String
    public let transport: OutputTransport
    public let sampleRate: Double
    public let hogOwner: Int32
    public let supportsSourceRate: Bool
    public let hasStereoOutput: Bool
    public let isDefaultOutput: Bool
    public let terminalType: UInt32
    public let usesSpeakers: Bool
    public let restoreRate: Double
    /// The source rate discovery checked the output against.
    public let sourceRate: Double
    /// The output has a host volume control; without one, volume is set on the device itself.
    public let hasVolumeControl: Bool

    public init(
        uid: String, deviceID: UInt32, name: String, transport: OutputTransport, sampleRate: Double,
        hogOwner: Int32, supportsSourceRate: Bool, hasStereoOutput: Bool, isDefaultOutput: Bool,
        terminalType: UInt32, usesSpeakers: Bool, restoreRate: Double,
        sourceRate: Double = Double(AudioSourceFormat.compactDisc.sampleRate), hasVolumeControl: Bool = true
    ) {
        id = uid
        self.deviceID = deviceID
        self.name = name
        self.transport = transport
        self.sampleRate = sampleRate
        self.hogOwner = hogOwner
        self.supportsSourceRate = supportsSourceRate
        self.hasStereoOutput = hasStereoOutput
        self.isDefaultOutput = isDefaultOutput
        self.terminalType = terminalType
        self.usesSpeakers = usesSpeakers
        self.restoreRate = restoreRate
        self.sourceRate = sourceRate
        self.hasVolumeControl = hasVolumeControl
    }

    public var disabledReason: String? {
        if !supportsSourceRate { return "Does not support \(AudioSourceFormat.rateText(sourceRate))." }
        if !hasStereoOutput { return "No stereo output stream." }
        return nil
    }

    public var symbol: String { transport.symbol(usesSpeakers: usesSpeakers) }

    public var choice: OutputChoice {
        OutputChoice(
            id: .device(uid: id), name: name, connection: transport.title, symbol: symbol,
            isEnabled: disabledReason == nil, disabledReason: disabledReason, hasVolumeControl: hasVolumeControl
        )
    }
}

/// An entry in the output selector's menu. Several can be listed; one is selected for playback.
public struct OutputChoice: Identifiable, Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        /// Core Audio UIDs are used instead of object IDs, which change after reconnection.
        case device(uid: String)
        /// Whatever macOS uses as its default output when playback starts, played best effort.
        case systemDefault
    }

    public let id: ID
    /// The device's current name, as the display shows it. For System Default, the current default's.
    public let name: String
    /// How the output is connected, shown after the name in the menu and tooltip.
    public let connection: String
    /// The SF Symbol for the output's type; System Default uses the current default's.
    public let symbol: String
    public let isEnabled: Bool
    public let disabledReason: String?
    /// The output, or System Default's current device, has a host volume control. Without one the menu
    /// entry, tooltip and VoiceOver value say "volume on device"; the status line does not.
    public let hasVolumeControl: Bool

    public init(
        id: ID, name: String, connection: String, symbol: String = "hifispeaker", isEnabled: Bool = true,
        disabledReason: String? = nil, hasVolumeControl: Bool = true
    ) {
        self.id = id
        self.name = name
        self.connection = connection
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.hasVolumeControl = hasVolumeControl
    }

    /// The System Default entry, describing the current default output, or disabled without one.
    public static func systemDefault(_ device: AudioOutputDevice?) -> OutputChoice {
        guard let device else {
            return OutputChoice(
                id: .systemDefault, name: "", connection: "", isEnabled: false,
                disabledReason: "macOS has no default output."
            )
        }
        return OutputChoice(
            id: .systemDefault, name: device.name, connection: device.transport.title, symbol: device.symbol,
            hasVolumeControl: device.hasVolumeControl
        )
    }

    public var isSystemDefault: Bool { id == .systemDefault }

    private var volumeNote: String { hasVolumeControl ? "" : ", volume on device" }

    /// The route alone, for example "MacBook Pro Speakers — Built-in" or
    /// "PRO X — System Default (USB), best effort".
    var routeTitle: String {
        guard isSystemDefault else { return "\(name) — \(connection)" }
        guard !name.isEmpty else { return "System Default" }
        return "\(name) — System Default (\(connection)), best effort"
    }

    /// The tooltip: the route, then "volume on device" when the output has no host volume control.
    public var title: String { routeTitle + volumeNote }

    /// The menu entry. System Default leads with its role, then the device macOS uses now.
    public var menuTitle: String {
        var base = title
        if isSystemDefault {
            base = name.isEmpty
                ? "System Default"
                : "System Default — \(name) (\(connection)), best effort\(volumeNote)"
        }
        guard let disabledReason else { return base }
        return "\(base) (\(disabledReason))"
    }

    /// The selector's VoiceOver value, for example "PRO X, system default, usb, best effort".
    public var accessibilityValue: String {
        guard isSystemDefault else { return "\(name), \(connection.lowercased())\(volumeNote)" }
        guard !name.isEmpty else { return "System default, unavailable" }
        return "\(name), system default, \(connection.lowercased()), best effort\(volumeNote)"
    }
}

@MainActor
public protocol OutputSelectionStore {
    var selectedID: OutputChoice.ID? { get }
    /// The saved device's last known name, so an output missing at launch can be named.
    var selectedName: String? { get }
    func save(_ id: OutputChoice.ID)
    /// Records the name of the saved device; ignored unless `id` is the saved device.
    func saveName(_ name: String, for id: OutputChoice.ID)
}

extension OutputSelectionStore {
    public var selectedName: String? { nil }
    public func saveName(_ name: String, for id: OutputChoice.ID) {}
}

/// Keeps the M6.2 UID key, so a saved device stays selected, and adds a flag for System Default and
/// the saved device's name.
@MainActor
public final class UserDefaultsOutputSelectionStore: OutputSelectionStore {
    public static let key = "SelectedAudioOutputUID"
    public static let systemDefaultKey = "SelectedAudioOutputIsSystemDefault"
    public static let nameKey = "SelectedAudioOutputName"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var selectedID: OutputChoice.ID? {
        if defaults.bool(forKey: Self.systemDefaultKey) { return .systemDefault }
        return defaults.string(forKey: Self.key).map { .device(uid: $0) }
    }

    public var selectedName: String? {
        guard case .device = selectedID else { return nil }
        return defaults.string(forKey: Self.nameKey)
    }

    public func save(_ id: OutputChoice.ID) {
        switch id {
        case .device(let uid):
            if defaults.string(forKey: Self.key) != uid { defaults.removeObject(forKey: Self.nameKey) }
            defaults.set(uid, forKey: Self.key)
            defaults.removeObject(forKey: Self.systemDefaultKey)
        case .systemDefault:
            defaults.set(true, forKey: Self.systemDefaultKey)
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.nameKey)
        }
    }

    public func saveName(_ name: String, for id: OutputChoice.ID) {
        guard case .device = id, id == selectedID, !name.isEmpty else { return }
        defaults.set(name, forKey: Self.nameKey)
    }
}
