import DiskArbitration
import Foundation
import IOKit
import OSLog

@MainActor
public final class MacOpticalDriveService: OpticalDriveService {
    private var observation: OpticalObservation?
    private var onChange: (@MainActor (OpticalSnapshot) -> Void)?
    private var pendingRefresh: Task<Void, Never>?
    private var loadingSince: [UInt64: ContinuousClock.Instant] = [:]
    private var lastSnapshot: OpticalSnapshot?
    private let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Optical")

    public init() {}

    public func start(onChange: @escaping @MainActor (OpticalSnapshot) -> Void) throws {
        guard observation == nil else {
            throw OpticalDriveError("Optical-drive monitoring is already running.")
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw OpticalDriveError("Cannot create the optical-drive notification port.")
        }
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            IONotificationPortDestroy(port)
            throw OpticalDriveError("Cannot connect to Disk Arbitration.")
        }
        let context = OpticalNotificationContext(owner: self)
        let resources = OpticalObservation(port: port, session: session, context: context)
        observation = resources
        self.onChange = onChange
        do {
            for className in ["IOCDBlockStorageDevice", "IOMedia"] {
                for event in [kIOMatchedNotification, kIOTerminatedNotification] {
                    var iterator: io_iterator_t = 0
                    guard let matching = IOServiceMatching(className) else {
                        throw OpticalDriveError("Cannot create the optical-device matching dictionary.")
                    }
                    let result = IOServiceAddMatchingNotification(
                        port, event, matching, opticalRegistryChanged,
                        Unmanaged.passUnretained(context).toOpaque(), &iterator
                    )
                    guard result == KERN_SUCCESS else {
                        throw OpticalRegistry.error("Cannot register optical-device notifications", result)
                    }
                    resources.iterators.append(iterator)
                    drain(iterator)
                }
            }
            IONotificationPortSetDispatchQueue(port, .main)
            let pointer = Unmanaged.passUnretained(context).toOpaque()
            DARegisterDiskAppearedCallback(session, nil, opticalDiskChanged, pointer)
            DARegisterDiskDisappearedCallback(session, nil, opticalDiskChanged, pointer)
            DARegisterDiskDescriptionChangedCallback(
                session, nil, [kDADiskDescriptionVolumePathKey] as CFArray, opticalDiskDescriptionChanged, pointer
            )
            DASessionSetDispatchQueue(session, .main)
            refresh()
        } catch {
            stop()
            throw error
        }
    }

    public func refresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard let observation else { return }
        let snapshot: OpticalSnapshot
        do {
            let drives = try scan(session: observation.session)
            let present = Set(drives.compactMap { $0.media?.id })
            loadingSince = loadingSince.filter { present.contains($0.key) }
            snapshot = OpticalSnapshot(drives: drives)
        } catch {
            logger.error("\(error.localizedDescription, privacy: .public)")
            snapshot = OpticalSnapshot(errorMessage: error.localizedDescription)
        }
        if snapshot != lastSnapshot {
            lastSnapshot = snapshot
            onChange?(snapshot)
        }
        if snapshot.drives.contains(where: { $0.media?.contents == .reading }) {
            scheduleRefresh(after: .milliseconds(250))
        }
    }

    public func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        observation?.close()
        observation = nil
        onChange = nil
        lastSnapshot = nil
        loadingSince.removeAll()
    }

    public func eject(media: OpticalMedia, from driveID: UInt64) async throws {
        try await DiskEjectRequest.run(media: media, driveID: driveID)
        refresh()
    }

    fileprivate func scheduleRefresh(after delay: Duration = .milliseconds(100)) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error("Optical refresh failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func scan(session: DASession) throws -> [OpticalDrive] {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOCDBlockStorageDevice"), &iterator
        )
        guard status == KERN_SUCCESS else { throw OpticalRegistry.error("Cannot enumerate optical drives", status) }
        defer { IOObjectRelease(iterator) }
        var drives: [OpticalDrive] = []
        while let drive = next(iterator) {
            defer { IOObjectRelease(drive) }
            let id: UInt64
            do {
                id = try OpticalRegistry.id(of: drive)
            } catch {
                // Without a registry ID the drive cannot be selected; it is normally being disconnected.
                logger.error("Skipping an optical drive: \(error.localizedDescription, privacy: .public)")
                continue
            }
            let listed = OpticalDrive.inspecting(id: id, name: OpticalRegistry.modelName(of: drive)) {
                try inspectMedia(in: drive, session: session)
            }
            if let issue = listed.issue {
                logger.error("Cannot inspect optical drive \(id): \(issue, privacy: .public)")
            }
            drives.append(listed)
        }
        return OpticalDrive.numberingDuplicateNames(drives.sorted { $0.id < $1.id })
    }

    private func inspectMedia(in drive: io_registry_entry_t, session: DASession) throws -> OpticalMedia? {
        var children: io_iterator_t = 0
        let result = IORegistryEntryCreateIterator(
            drive, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children
        )
        guard result == KERN_SUCCESS else {
            throw OpticalRegistry.error("Cannot inspect media in the optical drive", result)
        }
        defer { IOObjectRelease(children) }
        var media: OpticalMedia?
        var mounted = false
        var mountKnown = false
        while let child = next(children) {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOMedia") != 0 else { continue }
            if let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, child),
               let description = DADiskCopyDescription(disk) as? [String: Any] {
                mountKnown = true
                mounted = mounted || description[kDADiskDescriptionVolumePathKey as String] != nil
            }
            let values = try OpticalRegistry.properties(of: child)
            guard values["Whole"] as? Bool == true else { continue }
            guard media == nil else {
                throw OpticalDriveError("The optical drive reported more than one whole-disc media object.")
            }
            let mediaID = try OpticalRegistry.id(of: child)
            let bsdName = values["BSD Name"] as? String
            let contents = classify(
                child, id: mediaID, bsdName: bsdName, properties: values
            )
            media = OpticalMedia(
                id: mediaID, bsdName: bsdName, contents: contents, isMounted: nil,
                isEjectable: values["Ejectable"] as? Bool == true
            )
        }
        guard let found = media else { return nil }
        return OpticalMedia(
            id: found.id, bsdName: found.bsdName, contents: found.contents,
            isMounted: mountKnown ? mounted : nil, isEjectable: found.isEjectable
        )
    }

    private func classify(
        _ entry: io_registry_entry_t, id: UInt64, bsdName: String?, properties: [String: Any]
    ) -> OpticalContents {
        let firstSeen = loadingSince[id, default: .now]
        loadingSince[id] = firstSeen
        let isLoading = ContinuousClock.now - firstSeen < .seconds(5)
        guard bsdName != nil else {
            return isLoading ? .reading : unreadable("macOS did not provide an optical-disc device identifier.")
        }
        guard IOObjectConformsTo(entry, "IOCDMedia") != 0 else {
            return .other(properties["Type"] as? String ?? "DVD / Blu-ray / non-CD media")
        }
        if (properties["Size"] as? NSNumber)?.uint64Value == 0 { return .other("Blank CD") }
        guard let data = properties["TOC"] as? Data else {
            return isLoading ? .reading : unreadable("macOS did not provide the CD track table.")
        }
        do {
            let table = try CDTableOfContents(data: data)
            return table.audioTracks.isEmpty ? .dataCD : .audioCD(table)
        } catch {
            return unreadable(error.localizedDescription)
        }
    }

    /// The display shows only "Disc error", so the reason is logged.
    private func unreadable(_ message: String) -> OpticalContents {
        logger.error("Cannot use optical-disc metadata: \(message, privacy: .public)")
        return .unreadable(message)
    }
}

private func next(_ iterator: io_iterator_t) -> io_object_t? {
    let value = IOIteratorNext(iterator)
    return value == 0 ? nil : value
}

private func drain(_ iterator: io_iterator_t) {
    while let object = next(iterator) { IOObjectRelease(object) }
}

@MainActor
private final class OpticalNotificationContext {
    weak var owner: MacOpticalDriveService?
    init(owner: MacOpticalDriveService) { self.owner = owner }
}

// These callbacks are scheduled exclusively on DispatchQueue.main.
private func opticalRegistryChanged(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    drain(iterator)
    opticalChanged(context)
}

private func opticalDiskChanged(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    opticalChanged(context)
}

private func opticalDiskDescriptionChanged(_ disk: DADisk, _ keys: CFArray, _ context: UnsafeMutableRawPointer?) {
    opticalChanged(context)
}

private func opticalChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let notification = Unmanaged<OpticalNotificationContext>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        notification.owner?.scheduleRefresh()
    }
}

private final class OpticalObservation {
    let port: IONotificationPortRef
    let session: DASession
    let context: OpticalNotificationContext
    var iterators: [io_iterator_t] = []
    private var closed = false

    init(port: IONotificationPortRef, session: DASession, context: OpticalNotificationContext) {
        self.port = port
        self.session = session
        self.context = context
    }

    func close() {
        guard !closed else { return }
        closed = true
        DASessionSetDispatchQueue(session, nil)
        IONotificationPortSetDispatchQueue(port, nil)
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators.removeAll()
        IONotificationPortDestroy(port)
    }

    deinit { close() }
}

enum OpticalRegistry {
    // The returned IOKit reference is owned by the caller.
    static func validatedMedia(_ media: OpticalMedia, driveID: UInt64) throws -> io_service_t {
        guard media.isEjectable, let bsdName = media.bsdName,
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            throw OpticalDriveError("The selected optical disc is not ready for ejection.")
        }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else {
            throw OpticalDriveError("The selected disc was removed or replaced before eject.")
        }
        do {
            let values = try properties(of: entry)
            guard try id(of: entry) == media.id, IOObjectConformsTo(entry, "IOMedia") != 0,
                  values["Whole"] as? Bool == true, values["Ejectable"] as? Bool == true,
                  try owningDrive(of: entry) == driveID else {
                throw OpticalDriveError("The selected disc was removed or replaced. Eject was cancelled.")
            }
            return entry
        } catch {
            IOObjectRelease(entry)
            throw error
        }
    }

    /// Re-checks, just before reading, that the BSD name still names this whole CD in this drive.
    static func verifyReadable(_ media: OpticalMedia, driveID: UInt64) throws -> CDReadFeatures {
        guard let bsdName = media.bsdName, let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            throw CDReadError(.failed, "The selected optical disc is not ready for reading.")
        }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else {
            throw CDReadError(.gone, "The selected disc was removed or replaced before it could be read.")
        }
        defer { IOObjectRelease(entry) }
        let values = try properties(of: entry)
        guard try id(of: entry) == media.id, IOObjectConformsTo(entry, "IOCDMedia") != 0,
              values["Whole"] as? Bool == true, try owningDrive(of: entry) == driveID else {
            throw CDReadError(.gone, "The selected disc was removed or replaced before it could be read.")
        }
        guard let matchingDrive = IORegistryEntryIDMatching(driveID) else {
            throw CDReadError(.gone, "The selected optical drive was disconnected.")
        }
        let drive = IOServiceGetMatchingService(kIOMainPortDefault, matchingDrive)
        guard drive != 0 else { throw CDReadError(.gone, "The selected optical drive was disconnected.") }
        defer { IOObjectRelease(drive) }
        let characteristics = try properties(of: drive)["Device Characteristics"] as? [String: Any] ?? [:]
        return CDReadFeatures.decode(deviceCharacteristics: characteristics)
    }

    static func properties(of entry: io_registry_entry_t) throws -> [String: Any] {
        var value: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(entry, &value, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let properties = value?.takeRetainedValue() as? [String: Any] else {
            throw error("Cannot read optical-device registry metadata", result)
        }
        return properties
    }

    /// The drive's vendor and product names, or nil when macOS does not report them.
    static func modelName(of drive: io_registry_entry_t) -> String? {
        let characteristics = IORegistryEntryCreateCFProperty(
            drive, "Device Characteristics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
        let name = ["Vendor Name", "Product Name"].compactMap {
            (characteristics?[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    static func id(of entry: io_registry_entry_t) throws -> UInt64 {
        var id: UInt64 = 0
        let result = IORegistryEntryGetRegistryEntryID(entry, &id)
        guard result == KERN_SUCCESS else { throw error("Cannot identify the optical device", result) }
        return id
    }

    static func owningDrive(of entry: io_registry_entry_t) throws -> UInt64? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        while IOObjectConformsTo(current, "IOCDBlockStorageDevice") == 0 {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            guard result == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return try id(of: current)
    }

    static func error(_ message: String, _ status: kern_return_t) -> OpticalDriveError {
        OpticalDriveError("\(message) (IOKit status \(status)).")
    }
}
