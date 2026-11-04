import Foundation

public struct CDTableOfContents: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public let number: Int
        public let session: Int
        public let startSector: UInt64
        public let sectorCount: UInt64
        public let isAudio: Bool
        public let hasPreEmphasis: Bool
        /// Control bit 3 marks four-channel audio; every other audio track is stereo.
        public let isFourChannel: Bool

        /// Red Book audio with the declared channel count; nil for a data track.
        public var format: AudioSourceFormat? {
            isAudio ? .compactDiscAudio(channels: isFourChannel ? 4 : 2) : nil
        }
        /// PCM frames in an audio track; a data track has none.
        public var frameCount: UInt64 { sectorCount * (format?.framesPerSector ?? 0) }
    }

    public let tracks: [Track]
    public let leadOutSector: UInt64
    public var audioTracks: [Track] { tracks.filter(\.isAudio) }
    /// The format playback must carry: four-channel if any audio track declares it, so such a disc is
    /// refused as a whole rather than played wrongly. Nil without audio tracks.
    public var audioFormat: AudioSourceFormat? { audioTracks.compactMap(\.format).max { $0.channels < $1.channels } }
    public var durationSeconds: UInt64 { tracks.reduce(0) { $0 + $1.sectorCount } / 75 }
    public var audioDurationSeconds: UInt64 { audioTracks.reduce(0) { $0 + $1.sectorCount } / 75 }

    public init(data: Data) throws {
        let bytes = Array(data)
        guard bytes.count >= 4 else { throw TOCError("The CD track table header is incomplete.") }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        let end = length + 2
        guard end >= 4, end <= bytes.count, (end - 4).isMultiple(of: 11) else {
            throw TOCError("The CD track table length is invalid or truncated.")
        }
        let firstSession = Int(bytes[2]), lastSession = Int(bytes[3])
        guard (1...99).contains(firstSession), (firstSession...99).contains(lastSession) else {
            throw TOCError("The CD track table has an invalid session range.")
        }

        struct Entry {
            let number: Int
            let session: Int
            let sector: UInt64
            let control: UInt8
        }
        var entries: [Entry] = []
        var firstTracks: [Int: Int] = [:]
        var lastTracks: [Int: Int] = [:]
        var leadOuts: [Int: UInt64] = [:]
        for offset in stride(from: 4, to: end, by: 11) {
            guard bytes[offset + 1] >> 4 == 1 else { continue }
            let session = Int(bytes[offset])
            guard (firstSession...lastSession).contains(session) else {
                throw TOCError("A CD track descriptor refers to an invalid session.")
            }
            let point = Int(bytes[offset + 3])
            switch point {
            case 1...99:
                guard !entries.contains(where: { $0.number == point }) else {
                    throw TOCError("The CD track table contains a duplicate track.")
                }
                entries.append(Entry(
                    number: point, session: session,
                    sector: try Self.sector(bytes, at: offset + 8),
                    control: bytes[offset + 1] & 0x0F
                ))
            case 0xA0, 0xA1:
                let number = Int(bytes[offset + 8])
                guard (1...99).contains(number) else {
                    throw TOCError("A CD session declares an invalid track number.")
                }
                if point == 0xA0 {
                    guard firstTracks.updateValue(number, forKey: session) == nil else {
                        throw TOCError("The CD track table contains a duplicate session header.")
                    }
                } else {
                    guard lastTracks.updateValue(number, forKey: session) == nil else {
                        throw TOCError("The CD track table contains a duplicate session header.")
                    }
                }
            case 0xA2:
                guard leadOuts.updateValue(try Self.sector(bytes, at: offset + 8), forKey: session) == nil else {
                    throw TOCError("The CD track table contains a duplicate lead-out.")
                }
            default:
                continue
            }
        }

        var parsed: [Track] = []
        var previousLeadOut: UInt64 = 0
        var previousTrackNumber = 0
        for session in firstSession...lastSession {
            let sessionEntries = entries.filter { $0.session == session }.sorted { $0.number < $1.number }
            guard let first = firstTracks[session], let last = lastTracks[session],
                  first <= last, let leadOut = leadOuts[session],
                  sessionEntries.map(\.number) == Array(first...last) else {
                throw TOCError("A CD session has missing tracks, headers or a lead-out.")
            }
            for (index, entry) in sessionEntries.enumerated() {
                let nextSector = index + 1 < sessionEntries.count ? sessionEntries[index + 1].sector : leadOut
                guard (previousTrackNumber == 0 || entry.number == previousTrackNumber + 1),
                      entry.sector >= previousLeadOut,
                      nextSector > entry.sector else {
                    throw TOCError("CD track addresses overlap or are out of order.")
                }
                let isAudio = entry.control & 0x04 == 0
                parsed.append(Track(
                    number: entry.number, session: session, startSector: entry.sector,
                    sectorCount: nextSector - entry.sector, isAudio: isAudio,
                    hasPreEmphasis: isAudio && entry.control & 0x01 != 0,
                    isFourChannel: isAudio && entry.control & 0x08 != 0
                ))
                previousTrackNumber = entry.number
            }
            previousLeadOut = leadOut
        }
        tracks = parsed
        leadOutSector = previousLeadOut
    }

    private static func sector(_ bytes: [UInt8], at offset: Int) throws -> UInt64 {
        let minute = UInt64(bytes[offset]), second = UInt64(bytes[offset + 1]), frame = UInt64(bytes[offset + 2])
        let absolute = (minute * 60 + second) * 75 + frame
        guard second < 60, frame < 75, absolute >= 150 else {
            throw TOCError("A CD track address has an invalid minute/second/frame value.")
        }
        return absolute - 150
    }
}

public struct TOCError: LocalizedError, Equatable, Sendable {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
