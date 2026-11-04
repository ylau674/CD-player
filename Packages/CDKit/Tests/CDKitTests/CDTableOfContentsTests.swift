import Foundation
import Testing
@testable import CDKit

struct TOCTrackFixture {
    let number: Int
    let sector: UInt64
    var control: UInt8 = 0
}

struct TOCSessionFixture {
    var number = 1
    let tracks: [TOCTrackFixture]
    let leadOut: UInt64
}

func tocFixture(_ sessions: [TOCSessionFixture] = [
    TOCSessionFixture(tracks: [
        TOCTrackFixture(number: 1, sector: 0),
        TOCTrackFixture(number: 2, sector: 750),
        TOCTrackFixture(number: 3, sector: 1_500)
    ], leadOut: 2_250)
]) -> Data {
    var bytes: [UInt8] = [0, 0, UInt8(sessions.first!.number), UInt8(sessions.last!.number)]
    func msf(_ sector: UInt64) -> [UInt8] {
        let absolute = sector + 150
        return [UInt8(absolute / 4_500), UInt8((absolute / 75) % 60), UInt8(absolute % 75)]
    }
    for session in sessions {
        func append(point: UInt8, p: [UInt8], control: UInt8 = 0) {
            bytes += [UInt8(session.number), 0x10 | control, 0, point, 0, 0, 0, 0] + p
        }
        append(point: 0xA0, p: [UInt8(session.tracks.first!.number), 0, 0])
        append(point: 0xA1, p: [UInt8(session.tracks.last!.number), 0, 0])
        append(point: 0xA2, p: msf(session.leadOut))
        for track in session.tracks {
            append(point: UInt8(track.number), p: msf(track.sector), control: track.control)
        }
    }
    bytes[0] = UInt8((bytes.count - 2) >> 8)
    bytes[1] = UInt8((bytes.count - 2) & 0xFF)
    return Data(bytes)
}

private func withUpdatedLength(_ bytes: [UInt8]) -> Data {
    var bytes = bytes
    bytes[0] = UInt8((bytes.count - 2) >> 8)
    bytes[1] = UInt8((bytes.count - 2) & 0xFF)
    return Data(bytes)
}

@Test func parseAudioTracksWithBinaryMSFAndLeadInOffset() throws {
    let table = try CDTableOfContents(data: tocFixture())
    #expect(table.tracks.map(\.number) == [1, 2, 3])
    #expect(table.tracks.map(\.startSector) == [0, 750, 1_500])
    #expect(table.tracks.map(\.sectorCount) == [750, 750, 750])
    #expect(table.tracks.map(\.frameCount) == [441_000, 441_000, 441_000])
    #expect(table.audioTracks.count == 3)
    #expect(table.leadOutSector == 2_250)
    #expect(table.durationSeconds == 30)
}

@Test func identifyDataAndPreEmphasisWithoutTreatingDataAsAudio() throws {
    let table = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0, control: 1),
            TOCTrackFixture(number: 2, sector: 750, control: 5)
        ], leadOut: 1_500)
    ]))
    #expect(table.audioTracks.map(\.number) == [1])
    #expect(table.tracks[0].hasPreEmphasis)
    #expect(!table.tracks[1].isAudio)
    #expect(!table.tracks[1].hasPreEmphasis)
}

@Test func detectRedBookStereoAudioFromTheTrackControlBits() throws {
    let table = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0, control: 1),
            TOCTrackFixture(number: 2, sector: 750, control: 4)
        ], leadOut: 1_500)
    ]))
    #expect(table.tracks[0].format == .compactDisc)
    #expect(table.tracks[1].format == nil)
    #expect(table.tracks.map(\.frameCount) == [441_000, 0])
    let format = try #require(table.audioFormat)
    #expect(format == .compactDisc)
    #expect(format.sampleRate == 44_100 && format.bitsPerChannel == 16 && format.channels == 2)
    #expect(format.framesPerSector == 588 && format.bytesPerFrame == 4)
    #expect(format.isPlayable)
    #expect(format.description == "44.1 kHz / 16-bit")
    let disc = Disc(tableOfContents: table)
    #expect(disc.format == .compactDisc)
    #expect(disc.totalFrames == 441_000)
}

@Test func detectFourChannelAudioAndMarkTheDiscUnplayable() throws {
    let table = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0),
            TOCTrackFixture(number: 2, sector: 750, control: 8),
            TOCTrackFixture(number: 3, sector: 1_500, control: 0x0C)
        ], leadOut: 2_250)
    ]))
    #expect(table.tracks.map(\.isFourChannel) == [false, true, false])
    #expect(table.tracks[1].format == .compactDiscAudio(channels: 4))
    let format = try #require(table.audioFormat)
    #expect(format.channels == 4 && format.framesPerSector == 294)
    #expect(!format.isPlayable)
    #expect(format.description == "44.1 kHz / 16-bit / 4-channel")
    let disc = Disc(tableOfContents: table)
    #expect(disc.format == format)
    #expect(disc.tracks.map(\.framesPerSector) == [294, 294])
    #expect(disc.sectorPosition(at: 300) == Disc.SectorPosition(sector: 1, frame: 6))
}

@Test func aTableWithoutAudioHasNoAudioFormat() throws {
    let table = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0, control: 4)], leadOut: 750)
    ]))
    #expect(table.audioFormat == nil)
    #expect(Disc(tableOfContents: table).tracks.isEmpty)
}

@Test func multisessionDurationsExcludeTheIntersessionGap() throws {
    let table = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 750),
        TOCSessionFixture(number: 2, tracks: [
            TOCTrackFixture(number: 2, sector: 12_000, control: 4)
        ], leadOut: 12_750)
    ]))
    #expect(table.tracks.map(\.session) == [1, 2])
    #expect(table.tracks.map(\.sectorCount) == [750, 750])
    #expect(table.durationSeconds == 20)
    #expect(table.audioTracks.count == 1)
    #expect(table.audioDurationSeconds == 10)
}

@Test func rejectIncompleteOrMalformedTOCLengths() {
    for bytes: [UInt8] in [[], [0], [0, 2, 1], [0, 100, 1, 1], [0, 3, 1, 1, 0]] {
        #expect(throws: TOCError.self) { try CDTableOfContents(data: Data(bytes)) }
    }
    var bytes = tocFixture()
    bytes.removeLast()
    #expect(throws: TOCError.self) { try CDTableOfContents(data: bytes) }
}

@Test func rejectInvalidSessionRangesAndMissingSessions() {
    for pair: [UInt8] in [[0, 1], [2, 1], [1, 100], [1, 2]] {
        var bytes = tocFixture()
        bytes[2] = pair[0]
        bytes[3] = pair[1]
        #expect(throws: TOCError.self) { try CDTableOfContents(data: bytes) }
    }
}

@Test func rejectMissingSessionHeadersTracksAndLeadOut() {
    for descriptor in 0..<6 {
        var bytes = Array(tocFixture())
        bytes.removeSubrange((4 + descriptor * 11)..<(4 + (descriptor + 1) * 11))
        #expect(throws: TOCError.self) { try CDTableOfContents(data: withUpdatedLength(bytes)) }
    }
}

@Test func rejectDuplicatedTracksAndSessionDescriptors() {
    for descriptor in 0..<6 {
        var bytes = Array(tocFixture())
        bytes += bytes[(4 + descriptor * 11)..<(4 + (descriptor + 1) * 11)]
        #expect(throws: TOCError.self) { try CDTableOfContents(data: withUpdatedLength(bytes)) }
    }
}

@Test func rejectInvalidBinaryMSFAndAddressesBeforeLeadIn() {
    for msf: [UInt8] in [[0, 60, 0], [0, 2, 75], [0, 1, 74]] {
        var bytes = Array(tocFixture())
        let position = 4 + 3 * 11 + 8
        bytes.replaceSubrange(position..<(position + 3), with: msf)
        #expect(throws: TOCError.self) { try CDTableOfContents(data: Data(bytes)) }
    }
}

@Test func rejectOverlappingTracksAndInvalidLeadOuts() {
    for starts: [UInt64] in [[750, 0, 1_500], [0, 0, 1_500], [0, 750, 2_250]] {
        let tracks = starts.enumerated().map { TOCTrackFixture(number: $0.offset + 1, sector: $0.element) }
        #expect(throws: TOCError.self) {
            try CDTableOfContents(data: tocFixture([TOCSessionFixture(tracks: tracks, leadOut: 2_250)]))
        }
    }
    #expect(throws: TOCError.self) {
        try CDTableOfContents(data: tocFixture([
            TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 1_000),
            TOCSessionFixture(number: 2, tracks: [TOCTrackFixture(number: 2, sector: 750)], leadOut: 1_500)
        ]))
    }
}

@Test func ignorePaddingAndNonPositionDescriptors() throws {
    var bytes = Array(tocFixture())
    bytes += [1, 0x20, 0, 1, 0, 0, 0, 0, 255, 255, 255]
    var data = withUpdatedLength(bytes)
    data += Data(repeating: 0, count: 32)
    #expect(try CDTableOfContents(data: data).tracks.count == 3)
}

@Test func rejectMissingTrackNumbersBetweenSessions() {
    #expect(throws: TOCError.self) {
        try CDTableOfContents(data: tocFixture([
            TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 750),
            TOCSessionFixture(number: 2, tracks: [TOCTrackFixture(number: 3, sector: 12_000)], leadOut: 12_750)
        ]))
    }
}
