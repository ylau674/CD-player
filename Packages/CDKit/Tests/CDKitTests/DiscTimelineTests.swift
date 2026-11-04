import Foundation
import Testing
@testable import CDKit

/// Track starts of the 10-track CD first used with the Pioneer drive, recorded from its registry track table.
private let firstDiscStarts: [UInt64] = [0, 46_125, 65_300, 84_967, 111_992, 131_222, 154_802, 173_937, 199_115, 241_995]
/// Track starts of the 17-track CD in the drive when M4.1 was built.
private let currentDiscStarts: [UInt64] = [
    0, 2_825, 19_570, 52_792, 80_232, 96_342, 117_852, 131_972, 151_165,
    173_982, 185_605, 197_575, 232_762, 251_430, 266_562, 291_542, 313_190
]

private func audioCD(_ starts: [UInt64], leadOut: UInt64) throws -> Disc {
    let tracks = starts.enumerated().map { TOCTrackFixture(number: $0.offset + 1, sector: $0.element) }
    let data = tocFixture([TOCSessionFixture(tracks: tracks, leadOut: leadOut)])
    return Disc(tableOfContents: try CDTableOfContents(data: data))
}

private func position(_ sector: UInt64, _ frame: UInt64) -> Disc.SectorPosition {
    Disc.SectorPosition(sector: sector, frame: frame)
}

@Test func recordedTenTrackDiscMapsToItsFullTimeline() throws {
    let disc = try audioCD(firstDiscStarts, leadOut: 265_467)
    #expect(disc.tracks.map(\.number) == Array(1...10))
    #expect(disc.tracks.map(\.firstSector) == firstDiscStarts)
    #expect(disc.tracks.map(\.sectorCount) == [
        46_125, 19_175, 19_667, 27_025, 19_230, 23_580, 19_135, 25_178, 42_880, 23_472
    ])
    #expect(disc.tracks.map(\.startFrame) == firstDiscStarts.map { $0 * Disc.framesPerSector })
    #expect(disc.sectorCount == 265_467)
    #expect(disc.totalFrames == 156_094_596)
    #expect(disc.totalFrames / Disc.sampleRate == 58 * 60 + 59)
    #expect(disc.tracks.allSatisfy { $0.tone == nil })
}

@Test func currentSeventeenTrackDiscMapsToItsFullTimeline() throws {
    let disc = try audioCD(currentDiscStarts, leadOut: 332_380)
    #expect(disc.tracks.count == 17)
    #expect(disc.tracks.first?.sectorCount == 2_825)
    #expect(disc.tracks.last?.sectorCount == 19_190)
    #expect(disc.sectorCount == 332_380)
    #expect(disc.totalFrames == 195_439_440)
    #expect(disc.totalFrames / Disc.sampleRate == 73 * 60 + 51)
}

@Test func framesAndSectorsMapExactlyAtTrackAndDiscBoundaries() throws {
    let disc = try audioCD(firstDiscStarts, leadOut: 265_467)
    let secondTrack = 46_125 * Disc.framesPerSector
    #expect(disc.sectorPosition(at: 0) == position(0, 0))
    #expect(disc.sectorPosition(at: 587) == position(0, 587))
    #expect(disc.sectorPosition(at: 588) == position(1, 0))
    #expect(disc.sectorPosition(at: secondTrack - 1) == position(46_124, 587))
    #expect(disc.sectorPosition(at: secondTrack) == position(46_125, 0))
    #expect(disc.track(at: secondTrack - 1)?.number == 1)
    #expect(disc.track(at: secondTrack)?.number == 2)
    #expect(disc.sectorPosition(at: disc.totalFrames - 1) == position(265_466, 587))
    #expect(disc.sectorPosition(at: disc.totalFrames) == nil)
    #expect(disc.track(at: disc.totalFrames)?.number == 10)

    #expect(disc.frame(atSector: 0) == 0)
    #expect(disc.frame(atSector: 46_124) == secondTrack - 588)
    #expect(disc.frame(atSector: 46_125) == secondTrack)
    #expect(disc.frame(atSector: 265_466) == disc.totalFrames - 588)
    #expect(disc.frame(atSector: 265_467) == nil)
    for frame in stride(from: UInt64(0), to: disc.totalFrames, by: 7_777_777) {
        let place = try #require(disc.sectorPosition(at: frame))
        #expect(disc.frame(atSector: place.sector).map { $0 + place.frame } == frame)
    }
}

@Test func dataTracksAndIntersessionGapsAreLeftOutOfTheTimeline() throws {
    let enhanced = Disc(tableOfContents: try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0), TOCTrackFixture(number: 2, sector: 750)
        ], leadOut: 1_500),
        TOCSessionFixture(number: 2, tracks: [TOCTrackFixture(number: 3, sector: 12_900, control: 4)], leadOut: 20_000)
    ])))
    #expect(enhanced.tracks.map(\.number) == [1, 2])
    #expect(enhanced.totalFrames == 1_500 * Disc.framesPerSector)
    #expect(enhanced.frame(atSector: 12_900) == nil)

    let mixedMode = Disc(tableOfContents: try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0, control: 4),
            TOCTrackFixture(number: 2, sector: 3_000),
            TOCTrackFixture(number: 3, sector: 3_750)
        ], leadOut: 4_500)
    ])))
    #expect(mixedMode.tracks.map(\.number) == [2, 3])
    #expect(mixedMode.tracks.map(\.startFrame) == [0, 750 * Disc.framesPerSector])
    #expect(mixedMode.sectorPosition(at: 0) == position(3_000, 0))
    #expect(mixedMode.frame(atSector: 2_999) == nil)
    #expect(mixedMode.frame(atSector: 3_000) == 0)

    let twoSessions = Disc(tableOfContents: try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 1_500),
        TOCSessionFixture(number: 2, tracks: [TOCTrackFixture(number: 2, sector: 12_900)], leadOut: 14_400)
    ])))
    let boundary = 1_500 * Disc.framesPerSector
    #expect(twoSessions.totalFrames == 3_000 * Disc.framesPerSector)
    #expect(twoSessions.sectorPosition(at: boundary - 1) == position(1_499, 587))
    #expect(twoSessions.sectorPosition(at: boundary) == position(12_900, 0))
    #expect(twoSessions.frame(atSector: 5_000) == nil)
}

@Test func demoDiscKeepsItsTonesOnTheSharedTimeline() {
    #expect(Disc.demo.tracks.map(\.firstSector) == [0, 2_250, 4_500])
    #expect(Disc.demo.tracks.map(\.startFrame) == [0, 1_323_000, 2_646_000])
    #expect(Disc.demo.tracks.map { $0.tone?.frequency } == [220, 330, 440])
    #expect(Disc.demo.tracks.allSatisfy { $0.tone?.amplitude == 3_276 })
    #expect(Disc.demo.totalFrames == 90 * Disc.sampleRate)
    #expect(Disc.demo.sectorPosition(at: 1_323_000) == position(2_250, 0))
    #expect(Disc.silentCheck.totalFrames == 15 * Disc.sampleRate)
    #expect(Disc.silentCheck.tracks.allSatisfy { $0.tone?.amplitude == 0 })
}
