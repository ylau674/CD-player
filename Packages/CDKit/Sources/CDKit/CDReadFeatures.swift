import CDAudioCore
import Foundation

/// A snapshot for one connected drive, not a model-wide assumption.
public struct CDReadFeatures: Equatable, Sendable {
    public let cdFeatures: UInt32?
    public var streamAccurate: Bool { cdFeatures.map { $0 & cd_disc_stream_accurate_mask() != 0 } ?? false }

    /// An established upper bound for the complete read path's cache, or nil when unknown.
    /// The macOS raw reader always uses nil: the public API supplies no such guarantee.
    let cacheCapacitySectors: Int?

    public init(cdFeatures: UInt32? = nil) {
        self.cdFeatures = cdFeatures
        cacheCapacitySectors = nil
    }

    init(cdFeatures: UInt32?, cacheCapacitySectors: Int) {
        precondition(cacheCapacitySectors >= 0)
        self.cdFeatures = cdFeatures
        self.cacheCapacitySectors = cacheCapacitySectors
    }

    static func decode(deviceCharacteristics: [String: Any]) -> CDReadFeatures {
        guard let number = deviceCharacteristics["CD Features"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = UInt32(number.stringValue) else { return CDReadFeatures() }
        return CDReadFeatures(cdFeatures: value)
    }
}

public enum C2Support: Equatable, Sendable {
    case unknown, supported, unsupported
}
