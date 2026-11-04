import Foundation

/// The playback timeline shared by the demo and physical discs. Positions are PCM frames in the
/// disc's `format` (44.1 kHz stereo on an audio CD, 588 per sector); data tracks and intersession
/// gaps are left out.
public struct Disc: Equatable, Sendable {
    /// Red Book CD-DA timing, which the demo disc uses; a loaded disc follows its own `format`.
    public static let sampleRate: UInt64 = AudioSourceFormat.compactDisc.sampleRate
    public static let framesPerSector: UInt64 = AudioSourceFormat.compactDisc.framesPerSector
    public static let sectorsPerSecond: UInt64 = 75

    /// The test tone a demo track plays.
    public struct Tone: Equatable, Sendable {
        public let frequency: Double
        public let amplitude: Int16
    }

    public struct Track: Equatable, Sendable {
        public let number: Int
        /// The track's first sector (LBA) on the disc.
        public let firstSector: UInt64
        public let sectorCount: UInt64
        /// Where the track starts in the playback timeline.
        public let startFrame: UInt64
        /// Only demo tracks have a tone; physical tracks are read from the disc.
        public let tone: Tone?
        public let framesPerSector: UInt64

        public var frameCount: UInt64 { sectorCount * framesPerSector }
        public var endFrame: UInt64 { startFrame + frameCount }
    }

    /// A timeline frame's place on the disc: its sector and the frame within that sector (0-587).
    public struct SectorPosition: Equatable, Sendable {
        public let sector: UInt64
        public let frame: UInt64
    }

    /// The PCM format of the disc's audio, from its table of contents.
    public let format: AudioSourceFormat
    public let tracks: [Track]
    public var totalFrames: UInt64 { tracks.last?.endFrame ?? 0 }
    public var sectorCount: UInt64 { tracks.reduce(0) { $0 + $1.sectorCount } }

    /// The audio tracks of a CD, played back to back.
    public init(tableOfContents: CDTableOfContents) {
        // A table without audio tracks gives an empty timeline, so its format is never played.
        let format = tableOfContents.audioFormat ?? .compactDisc
        self.format = format
        var startFrame: UInt64 = 0
        tracks = tableOfContents.audioTracks.map { track in
            let frames = track.sectorCount * format.framesPerSector
            defer { startFrame += frames }
            return Track(
                number: track.number, firstSector: track.startSector, sectorCount: track.sectorCount,
                startFrame: startFrame, tone: nil, framesPerSector: format.framesPerSector
            )
        }
    }

    /// Three tone tracks laid out from sector 0, like a disc.
    private init(secondsPerTrack: UInt64, amplitude: Int16) {
        let format = AudioSourceFormat.compactDisc
        self.format = format
        let sectors = secondsPerTrack * Self.sectorsPerSecond
        tracks = [220.0, 330.0, 440.0].enumerated().map { index, frequency in
            Track(
                number: index + 1, firstSector: UInt64(index) * sectors, sectorCount: sectors,
                startFrame: UInt64(index) * sectors * format.framesPerSector,
                tone: Tone(frequency: frequency, amplitude: amplitude), framesPerSector: format.framesPerSector
            )
        }
    }

    public static let demo = Disc(secondsPerTrack: 30, amplitude: 3_276)
    public static let silentCheck = Disc(secondsPerTrack: 5, amplitude: 0)

    public func track(at frame: UInt64) -> Track? {
        guard let last = tracks.last else { return nil }
        return tracks.first { frame < $0.endFrame } ?? last
    }

    /// Where a timeline frame is on the disc, or nil past the end of the last track.
    public func sectorPosition(at frame: UInt64) -> SectorPosition? {
        guard let track = tracks.first(where: { frame < $0.endFrame }) else { return nil }
        let offset = frame - track.startFrame
        return SectorPosition(
            sector: track.firstSector + offset / format.framesPerSector, frame: offset % format.framesPerSector
        )
    }

    /// The timeline frame where a disc sector begins, or nil for sectors outside the audio tracks.
    public func frame(atSector sector: UInt64) -> UInt64? {
        guard let track = tracks.first(where: {
            sector >= $0.firstSector && sector - $0.firstSector < $0.sectorCount
        }) else { return nil }
        return track.startFrame + (sector - track.firstSector) * format.framesPerSector
    }
}
