import CoreAudio
import Foundation

enum CoreAudioOutputState {
    // This reader intentionally has no playback-engine or preferences dependency.
    static func capture() throws -> OutputStateSnapshot {
        try capture(read: readSnapshot)
    }

    static func capture(read: () throws -> OutputStateSnapshot) throws -> OutputStateSnapshot {
        let first = try read()
        try first.validate()
        let second = try read()
        try second.validate()
        guard first.devices == second.devices, first.defaultOutputUID == second.defaultOutputUID,
              first.defaultSystemOutputUID == second.defaultSystemOutputUID,
              first.defaultInputUID == second.defaultInputUID else {
            throw CheckError.failed("Audio configuration changed while capturing it. No stable snapshot was saved.")
        }
        return second
    }

    private static func readSnapshot() throws -> OutputStateSnapshot {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids: [UInt32] = try array(system, kAudioHardwarePropertyDevices, initial: UInt32(0))
        var devices: [OutputStateDevice] = []
        for id in ids {
            let transport = try value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
            guard OutputStateDevice.isWired(transport) else { continue }
            var streams: [OutputStateStream] = []
            for (direction, scope) in [(OutputStateDirection.input, kAudioObjectPropertyScopeInput),
                                       (.output, kAudioObjectPropertyScopeOutput)] {
                let streamIDs: [UInt32] = try array(id, kAudioDevicePropertyStreams, scope: scope, initial: UInt32(0))
                for streamID in streamIDs {
                    let stream = OutputStateStream(
                        objectID: streamID, direction: direction,
                        startingChannel: try value(streamID, kAudioStreamPropertyStartingChannel, initial: UInt32(0)),
                        virtualFormat: OutputStateFormat(try value(
                            streamID, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())),
                        physicalFormat: OutputStateFormat(try value(
                            streamID, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())),
                        virtualSettable: try settable(streamID, kAudioStreamPropertyVirtualFormat),
                        physicalSettable: try settable(streamID, kAudioStreamPropertyPhysicalFormat),
                        availableVirtualFormats: try formats(streamID, kAudioStreamPropertyAvailableVirtualFormats),
                        availablePhysicalFormats: try formats(streamID, kAudioStreamPropertyAvailablePhysicalFormats)
                    )
                    guard stream.startingChannel > 0, stream.virtualFormat.channels > 0,
                          stream.physicalFormat.channels > 0 else {
                        throw CheckError.failed("Stream \(streamID) returned an invalid channel layout.")
                    }
                    streams.append(stream)
                }
            }
            var controls: [String: Double] = [:]
            for (label, scope, direction) in [("input", kAudioObjectPropertyScopeInput, OutputStateDirection.input),
                                            ("output", kAudioObjectPropertyScopeOutput, .output)] {
                let channels = streams.filter { $0.direction == direction }.reduce(UInt64(0)) {
                    max($0, UInt64($1.startingChannel) + UInt64($1.virtualFormat.channels) - 1)
                }
                guard channels <= 4_096 else {
                    throw CheckError.failed("Device \(id) has too many channels to inspect safely.")
                }
                for element in UInt32(0)...UInt32(channels) {
                    if let volume = try optionalValue(
                        id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element, initial: Float32(0)
                    ) {
                        controls["\(label).volumeScalar.\(element)"] = Double(volume)
                    }
                    if let mute = try optionalValue(
                        id, kAudioDevicePropertyMute, scope: scope, element: element, initial: UInt32(0)
                    ) {
                        controls["\(label).mute.\(element)"] = Double(mute)
                    }
                }
            }
            for (label, scope) in [("global", kAudioObjectPropertyScopeGlobal),
                                   ("input", kAudioObjectPropertyScopeInput),
                                   ("output", kAudioObjectPropertyScopeOutput)] {
                for (name, selector) in [("clockSource", kAudioDevicePropertyClockSource),
                                         ("dataSource", kAudioDevicePropertyDataSource)] {
                    if let control = try optionalValue(id, selector, scope: scope, initial: UInt32(0)) {
                        controls["\(label).\(name)"] = Double(control)
                    }
                }
            }
            if let domain = try optionalValue(id, kAudioDevicePropertyClockDomain, initial: UInt32(0)) {
                controls["global.clockDomain"] = Double(domain)
            }
            let rates = try optionalArray(id, kAudioDevicePropertyAvailableNominalSampleRates, initial: AudioValueRange())
            let preferred: [UInt32]? = try streams.contains(where: { $0.direction == .output })
                ? optionalArray(
                    id, kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput,
                    initial: UInt32(0))
                : nil
            if let preferred, preferred.count != 2 {
                throw CheckError.failed("Device \(id) returned malformed preferred stereo channels.")
            }
            devices.append(OutputStateDevice(
                objectID: id, uid: try string(id, kAudioDevicePropertyDeviceUID),
                name: try string(id, kAudioObjectPropertyName), transport: transport,
                alive: try value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 0,
                running: try value(id, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) != 0,
                nominalRate: try value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)),
                nominalRateSettable: try settable(id, kAudioDevicePropertyNominalSampleRate),
                availableRates: rates?.map { OutputStateRateRange(minimum: $0.mMinimum, maximum: $0.mMaximum) },
                hogOwner: try optionalValue(id, kAudioDevicePropertyHogMode, initial: Int32(-1)),
                preferredStereoChannels: preferred, streams: streams.sorted { $0.key < $1.key }, controls: controls
            ))
        }
        return OutputStateSnapshot(
            captureID: UUID().uuidString, capturedAtUnixTime: Date().timeIntervalSince1970,
            defaultOutputUID: try defaultUID(kAudioHardwarePropertyDefaultOutputDevice),
            defaultSystemOutputUID: try defaultUID(kAudioHardwarePropertyDefaultSystemOutputDevice),
            defaultInputUID: try defaultUID(kAudioHardwarePropertyDefaultInputDevice),
            devices: devices.sorted { $0.uid < $1.uid }
        )
    }

    private static func property(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
        _ element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func check(_ status: OSStatus, _ object: UInt32, _ selector: UInt32) throws {
        guard status == noErr else {
            throw CheckError.failed(String(format: "Core Audio read failed: object %u, property 0x%08x, OSStatus %d.",
                                           object, selector, status))
        }
    }

    private static func value<T: BitwiseCopyable>(
        _ object: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal,
        element: UInt32 = kAudioObjectPropertyElementMain, initial: T
    ) throws -> T {
        var result = initial
        var address = property(selector, scope, element)
        let expected = UInt32(MemoryLayout<T>.size)
        var size = expected
        let status = withUnsafeMutableBytes(of: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, object, selector)
        guard size == expected else {
            throw CheckError.failed("Core Audio returned an unexpected property size for object \(object), property \(selector).")
        }
        return result
    }

    private static func optionalValue<T: BitwiseCopyable>(
        _ object: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal,
        element: UInt32 = kAudioObjectPropertyElementMain, initial: T
    ) throws -> T? {
        var address = property(selector, scope, element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        return try value(object, selector, scope: scope, element: element, initial: initial)
    }

    private static func array<T: BitwiseCopyable>(
        _ object: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal, initial: T
    ) throws -> [T] {
        var address = property(selector, scope, kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), object, selector)
        let stride = MemoryLayout<T>.stride
        guard Int(size) % stride == 0 else {
            throw CheckError.failed("Core Audio returned a malformed array for object \(object), property \(selector).")
        }
        if size == 0 { return [] }
        let capacity = size
        var result = Array(repeating: initial, count: Int(size) / stride)
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, object, selector)
        guard size <= capacity, Int(size) % stride == 0 else {
            throw CheckError.failed("Core Audio changed the array size while inspecting object \(object), property \(selector).")
        }
        return Array(result.prefix(Int(size) / stride))
    }

    private static func optionalArray<T: BitwiseCopyable>(
        _ object: UInt32, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal, initial: T
    ) throws -> [T]? {
        var address = property(selector, scope, kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        return try array(object, selector, scope: scope, initial: initial)
    }

    private static func settable(_ object: UInt32, _ selector: UInt32) throws -> Bool {
        var address = property(selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain)
        var result = DarwinBoolean(false)
        try check(AudioObjectIsPropertySettable(object, &address, &result), object, selector)
        return result.boolValue
    }

    private static func string(_ object: UInt32, _ selector: UInt32) throws -> String {
        var address = property(selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        try check(status, object, selector)
        guard let value else { throw CheckError.failed("Core Audio returned no string for object \(object), property \(selector).") }
        let result = value.takeRetainedValue() as String
        guard size == MemoryLayout<Unmanaged<CFString>?>.size else {
            throw CheckError.failed("Core Audio returned a malformed string property for object \(object).")
        }
        return result
    }

    private static func formats(_ stream: UInt32, _ selector: UInt32) throws -> [OutputStateFormatRange]? {
        try optionalArray(stream, selector, initial: AudioStreamRangedDescription())?.map {
            OutputStateFormatRange(
                format: OutputStateFormat($0.mFormat),
                rates: OutputStateRateRange(minimum: $0.mSampleRateRange.mMinimum, maximum: $0.mSampleRateRange.mMaximum)
            )
        }
    }

    private static func defaultUID(_ selector: UInt32) throws -> String? {
        let device = try value(AudioObjectID(kAudioObjectSystemObject), selector, initial: UInt32(0))
        return device == kAudioObjectUnknown ? nil : try string(device, kAudioDevicePropertyDeviceUID)
    }
}
