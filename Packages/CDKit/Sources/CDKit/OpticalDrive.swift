import Foundation

public enum OpticalContents: Equatable, Sendable {
    case reading
    case audioCD(CDTableOfContents)
    case dataCD
    case other(String)
    case unreadable(String)

    public var tableOfContents: CDTableOfContents? {
        if case .audioCD(let table) = self { return table }
        return nil
    }
}

public struct OpticalMedia: Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let bsdName: String?
    public let contents: OpticalContents
    public let isMounted: Bool?
    public let isEjectable: Bool
}

public struct OpticalDrive: Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let name: String
    public let media: OpticalMedia?
    /// Why macOS could not report this drive's media; other drives are unaffected.
    public let issue: String?

    init(id: UInt64, name: String, media: OpticalMedia?, issue: String? = nil) {
        self.id = id
        self.name = name
        self.media = media
        self.issue = issue
    }

    /// Lists one drive. A failure while inspecting its media is kept on this drive so it cannot hide the others.
    static func inspecting(id: UInt64, name: String?, media: () throws -> OpticalMedia?) -> OpticalDrive {
        let name = name ?? "Optical drive \(id)"
        do {
            return OpticalDrive(id: id, name: name, media: try media())
        } catch {
            return OpticalDrive(id: id, name: name, media: nil, issue: error.localizedDescription)
        }
    }

    /// Drives of the same model report identical names; number them in the given (connection) order.
    static func numberingDuplicateNames(_ drives: [OpticalDrive]) -> [OpticalDrive] {
        let totals = Dictionary(drives.map { ($0.name, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        return drives.map { drive in
            guard totals[drive.name, default: 0] > 1 else { return drive }
            let number = seen[drive.name, default: 0] + 1
            seen[drive.name] = number
            return OpticalDrive(id: drive.id, name: "\(drive.name) (\(number))", media: drive.media, issue: drive.issue)
        }
    }
}

public struct OpticalSnapshot: Equatable, Sendable {
    public let drives: [OpticalDrive]
    public let errorMessage: String?

    public init(drives: [OpticalDrive] = [], errorMessage: String? = nil) {
        self.drives = drives
        self.errorMessage = errorMessage
    }
}

public struct OpticalDriveError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor
public protocol OpticalDriveService: AnyObject {
    func start(onChange: @escaping @MainActor (OpticalSnapshot) -> Void) throws
    func refresh()
    func stop()
    func eject(media: OpticalMedia, from driveID: UInt64) async throws
}
