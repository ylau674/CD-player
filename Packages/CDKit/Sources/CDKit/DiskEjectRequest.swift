import DiskArbitration
import Foundation
import IOKit

@MainActor
final class DiskEjectRequest {
    private let session: DASession
    private let disk: DADisk
    private let expectedMedia: OpticalMedia
    private let driveID: UInt64
    private let continuation: CheckedContinuation<Void, any Error>

    private init(
        session: DASession, disk: DADisk, media: OpticalMedia, driveID: UInt64,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        self.session = session
        self.disk = disk
        expectedMedia = media
        self.driveID = driveID
        self.continuation = continuation
    }

    static func run(media: OpticalMedia, driveID: UInt64) async throws {
        let entry = try OpticalRegistry.validatedMedia(media, driveID: driveID)
        defer { IOObjectRelease(entry) }
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, entry) else {
            throw OpticalDriveError("macOS could not create an eject request for the selected optical disc.")
        }
        DASessionSetDispatchQueue(session, .main)
        try await withCheckedThrowingContinuation { continuation in
            let request = DiskEjectRequest(
                session: session, disk: disk, media: media, driveID: driveID, continuation: continuation
            )
            DADiskUnmount(
                disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole),
                opticalUnmountFinished, Unmanaged.passRetained(request).toOpaque()
            )
        }
    }

    fileprivate func unmountFinished(status: DAReturn?, error: OpticalDriveError?) {
        if let status, !Self.mayEjectAfterUnmount(status: status) {
            finish(error: error)
            return
        }
        do {
            let current = try OpticalRegistry.validatedMedia(expectedMedia, driveID: driveID)
            IOObjectRelease(current)
        } catch {
            finish(error: error)
            return
        }
        DADiskEject(
            disk, DADiskEjectOptions(kDADiskEjectOptionDefault),
            opticalEjectFinished, Unmanaged.passRetained(self).toOpaque()
        )
    }

    fileprivate func ejectFinished(error: OpticalDriveError?) {
        finish(error: error)
    }

    private func finish(error: (any Error)?) {
        DASessionSetDispatchQueue(session, nil)
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    static func mayEjectAfterUnmount(status: DAReturn) -> Bool {
        status == DAReturn(kDAReturnSuccess) || status == DAReturn(truncatingIfNeeded: kDAReturnNotMounted)
    }

}

private func opticalUnmountFinished(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let request = Unmanaged<DiskEjectRequest>.fromOpaque(context).takeRetainedValue()
    let status = dissenter.map { DADissenterGetStatus($0) }
    let error = opticalOperationError(dissenter, operation: "unmount")
    MainActor.assumeIsolated {
        request.unmountFinished(status: status, error: error)
    }
}

private func opticalEjectFinished(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let request = Unmanaged<DiskEjectRequest>.fromOpaque(context).takeRetainedValue()
    let error = opticalOperationError(dissenter, operation: "eject")
    MainActor.assumeIsolated {
        request.ejectFinished(error: error)
    }
}

private func opticalOperationError(_ dissenter: DADissenter?, operation: String) -> OpticalDriveError? {
    guard let dissenter else { return nil }
    let status = DADissenterGetStatus(dissenter)
    let detail = (DADissenterGetStatusString(dissenter) as String?) ?? "The disc is busy, restricted or unavailable."
    return OpticalDriveError(
        "macOS refused to \(operation) the optical disc: \(detail) " +
        "(status \(String(format: "0x%08X", status))). No forced eject or policy override was attempted."
    )
}
