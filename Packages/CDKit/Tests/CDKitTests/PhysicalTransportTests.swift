import CDAudioCore
import Foundation
import Testing
@testable import CDKit

@MainActor
private struct PhysicalPlayerFixture {
    let player: PlayerModel
    let demo = FakeEngine()
    let playback: FakeEngine
    let opener: FakeDiscOpener
    let service: FakeOpticalService
    let disc: Disc
    var totalTimeText: String {
        let seconds = disc.totalFrames / Disc.sampleRate
        return String(format: "%02llu:%02llu", seconds / 60, seconds % 60)
    }

    init(
        data: Data = tocFixture(), seekDelay: Duration = .milliseconds(300),
        opener: FakeDiscOpener? = nil, multipleDrives: Bool = false, mounted: Bool = false,
        restoreOutputRates: @escaping @Sendable () async throws -> Void = {}
    ) throws {
        let table = try CDTableOfContents(data: data)
        disc = Disc(tableOfContents: table)
        playback = FakeEngine(totalFrames: disc.totalFrames)
        self.opener = opener ?? FakeDiscOpener(tableOfContents: data)
        let media = OpticalMedia(
            id: 10, bsdName: "disk4", contents: .audioCD(table), isMounted: mounted, isEjectable: true
        )
        let otherMedia = OpticalMedia(
            id: 20, bsdName: "disk5", contents: .audioCD(table), isMounted: false, isEjectable: true
        )
        service = FakeOpticalService(
            [opticalDrive(media: media)] + (multipleDrives ? [opticalDrive(id: 2, media: otherMedia)] : [])
        )
        let playback = self.playback
        player = PlayerModel.offline(
            engine: demo, automaticallyMonitor: false, opticalService: service,
            discOpener: self.opener, seekDelay: seekDelay, makeDiscEngine: { _ in playback },
            outputRateControl: FakeOutputRateControl(onRestoreChanged: restoreOutputRates)
        )
        player.startOpticalMonitoring()
    }
}

/// What quit had already released when it restored the output sample rates.
private actor QuitRestoreRecord {
    private(set) var discsClosed: [[Bool]] = []
    func record(_ closed: [Bool]) { discsClosed.append(closed) }
}

@Suite(.serialized)
@MainActor
struct PhysicalTransportTests {
    @Test func physicalPlayUsesTheSelectedSessionAndKeepsItAcrossPauseResume() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        #expect(player.controlsEnabled && player.isShowingDiscSummary)
        #expect(player.stopOrEjectLabel == "Eject disc" && player.stopOrEjectSymbol == "eject.fill")
        #expect(test.opener.opens.isEmpty)
        await player.togglePlayback()
        let session = try #require(player.discSession)
        #expect(player.state == .playing && player.isPlayingCD)
        #expect(player.stopOrEjectLabel == "Stop" && player.stopOrEjectSymbol == "stop.fill")
        #expect(player.trackText == "01" && !player.isShowingDiscSummary)
        #expect(await test.playback.starts == [0])
        #expect(await test.demo.starts.isEmpty)
        #expect(test.opener.opens == [.init(mediaID: 10, driveID: 1, onMainThread: false)])
        await test.playback.setFrame(5 * Disc.sampleRate + 17)
        await player.refreshPlayback()
        #expect(player.timeText == "00:05" && player.statusText == "CD PLAYING")
        #expect(player.statusAccessibilityLabel == "CD playing")
        await player.togglePlayback()
        #expect(player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.statusAccessibilityLabel == "CD paused")
        #expect(player.discSession === session)
        #expect(test.opener.discs.first?.isClosed == false)
        await player.togglePlayback()
        await player.refreshPlayback()
        #expect(player.statusAccessibilityLabel == "CD playing")
        #expect(await test.playback.starts == [0, 5 * Disc.sampleRate + 17])
        #expect(test.opener.opens.count == 1 && player.discSession === session)
        try await player.shutdown()
        #expect(test.opener.discs.first?.isClosed == true)
    }

    @Test func quitRestoresOutputSampleRatesOnlyAfterTheDiscCloses() async throws {
        let opener = FakeDiscOpener()
        let record = QuitRestoreRecord()
        let test = try PhysicalPlayerFixture(
            opener: opener, restoreOutputRates: { await record.record(opener.discs.map(\.isClosed)) }
        )
        let player = test.player
        await player.togglePlayback()
        #expect(player.isPlayingCD)
        await player.stopOrEject()
        #expect(player.isShowingDiscSummary && !player.isPlayingCD)
        await player.togglePlayback()
        #expect(player.isPlayingCD)
        #expect(await record.discsClosed.isEmpty)
        try await player.shutdown()
        #expect(await record.discsClosed == [[true, true]])
    }

    @Test func stopActionDuringPlaybackRestoresTheDiscSummaryThenEjectsOnNextPress() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(5 * Disc.sampleRate)
        await player.refreshPlayback()
        #expect(player.isStopAction && player.stopOrEjectEnabled)
        #expect(player.stopOrEjectLabel == "Stop")

        await player.stopOrEject()

        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.currentFrame == 0 && player.isShowingDiscSummary)
        #expect(player.trackText == "03" && player.timeText == test.totalTimeText)
        #expect(player.displayAccessibilityLabel ==
            "Disc total, 3 audio tracks, total time \(test.totalTimeText)")
        #expect(player.stopOrEjectLabel == "Eject disc" && player.stopOrEjectSymbol == "eject.fill")
        #expect(player.discSession == nil && test.opener.discs.first?.isClosed == true)
        #expect(test.service.ejects.isEmpty)

        await player.stopOrEject()
        #expect(test.service.ejects.count == 1)
        #expect(player.statusText == "NO DISC" && player.trackText == "00")
        try await player.shutdown()
    }

    @Test func stopActionWhilePausedRestoresTheDiscSummaryWithoutEjecting() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(5 * Disc.sampleRate)
        await player.refreshPlayback()
        await player.togglePlayback()
        #expect(player.state == .paused && player.stopOrEjectLabel == "Stop")

        await player.stopOrEject()

        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.currentFrame == 0 && player.isShowingDiscSummary)
        #expect(player.trackText == "03" && player.timeText == test.totalTimeText)
        #expect(player.stopOrEjectLabel == "Eject disc" && player.stopOrEjectEnabled)
        #expect(test.service.ejects.isEmpty)
        #expect(player.discSession == nil && test.opener.discs.first?.isClosed == true)
        try await player.shutdown()
    }

    @Test func nextOnTheLastTrackWhileStoppedStaysDetectedWithoutReadingTheDisc() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        let last = try #require(test.disc.tracks.last)
        let lastTrackText = String(format: "%02d", last.number)
        let demoStops = await test.demo.stops
        for _ in 0..<(test.disc.tracks.count + 2) { await player.nextTrack() }
        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.trackText == lastTrackText && player.timeText == "00:00")
        #expect(player.currentFrame == last.startFrame && !player.isShowingDiscSummary)
        #expect(player.stopOrEjectLabel == "Eject disc")
        #expect(test.opener.opens.isEmpty)
        #expect(await test.playback.starts.isEmpty)
        #expect(await test.demo.stops == demoStops)

        await player.togglePlayback()
        #expect(player.state == .playing && player.trackText == lastTrackText)
        #expect(await test.playback.starts == [last.startFrame])
        await player.stopOrEject()
        let playbackStops = await test.playback.stops
        for _ in 0..<(test.disc.tracks.count + 2) { await player.nextTrack() }
        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.trackText == lastTrackText && player.timeText == "00:00")
        #expect(player.currentFrame == last.startFrame && player.stopOrEjectLabel == "Eject disc")
        #expect(test.opener.opens.count == 1 && player.discSession == nil)
        #expect(await test.playback.starts == [last.startFrame])
        #expect(await test.playback.stops == playbackStops)
        try await player.shutdown()
    }

    @Test func pausedNextOnTheLastTrackKeepsThePositionAndPlayResumesThereWithoutEndingTheDisc() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(4 * Disc.sampleRate)
        await player.refreshPlayback()
        await player.togglePlayback()
        for _ in 0..<(test.disc.tracks.count + 2) { await player.nextTrack() }
        #expect(player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.trackText == "03" && player.timeText == "00:00")
        #expect(player.currentFrame == 20 * Disc.sampleRate && player.stopOrEjectLabel == "Stop")
        #expect(player.discSession != nil && test.opener.opens.count == 1)
        await player.togglePlayback()
        #expect(player.state == .playing && player.trackText == "03")
        #expect(await test.playback.starts == [0, 20 * Disc.sampleRate])

        await test.playback.setFrame(25 * Disc.sampleRate)
        await player.refreshPlayback()
        await player.nextTrack()
        #expect(player.state == .playing && player.currentFrame == 25 * Disc.sampleRate)
        await player.togglePlayback()
        await player.nextTrack()
        #expect(player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.trackText == "03" && player.timeText == "00:05")
        await player.togglePlayback()
        #expect(player.state == .playing)
        #expect(await test.playback.starts == [0, 20 * Disc.sampleRate, 25 * Disc.sampleRate])
        #expect(test.opener.opens.count == 1)
        try await player.shutdown()
    }

    @Test func nextFromTheDiscTotalSelectsTrackOneWithoutReadingTheDisc() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        #expect(player.isShowingDiscSummary && player.trackText == "03")
        await player.nextTrack()
        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.trackText == "01" && player.timeText == "00:00" && !player.isShowingDiscSummary)
        #expect(player.currentFrame == 0 && player.stopOrEjectLabel == "Eject disc")
        await player.nextTrack()
        #expect(player.trackText == "02" && player.currentFrame == 10 * Disc.sampleRate)
        #expect(test.opener.opens.isEmpty)
        #expect(await test.playback.starts.isEmpty)

        await player.togglePlayback()
        await test.playback.setFrame(test.disc.totalFrames)
        await player.refreshPlayback()
        #expect(player.state == .ended && player.isShowingDiscSummary)
        await player.nextTrack()
        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.trackText == "01" && player.timeText == "00:00")
        await player.togglePlayback()
        #expect(player.state == .playing && player.trackText == "01")
        #expect(await test.playback.starts == [10 * Disc.sampleRate, 0])
        #expect(test.opener.opens.count == 2)
        try await player.shutdown()
    }

    @Test func previousOnTheFirstTrackWhileStoppedReturnsToTheDiscSummaryWithoutReadingTheDisc() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.nextTrack()
        #expect(player.trackText == "01" && player.timeText == "00:00" && !player.isShowingDiscSummary)
        for _ in 0..<2 {
            await player.previousTrack()
            #expect(player.state == .ready && player.statusText == "CD DETECTED")
            #expect(player.isShowingDiscSummary && player.currentFrame == 0)
            #expect(player.trackText == "03" && player.timeText == test.totalTimeText)
            #expect(player.displayAccessibilityLabel ==
                "Disc total, 3 audio tracks, total time \(test.totalTimeText)")
        }
        #expect(test.opener.opens.isEmpty)
        #expect(await test.playback.starts.isEmpty)

        await player.togglePlayback()
        await player.togglePlayback()
        await player.previousTrack()
        #expect(player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.trackText == "01" && !player.isShowingDiscSummary)
        #expect(player.stopOrEjectLabel == "Stop")

        await player.stopOrEject()
        await player.nextTrack()
        #expect(player.state == .ready && player.trackText == "01" && player.timeText == "00:00")
        await player.previousTrack()
        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.isShowingDiscSummary && player.timeText == test.totalTimeText)
        #expect(test.opener.opens.count == 1 && player.discSession == nil)
        #expect(await test.playback.starts == [0])
        try await player.shutdown()
    }

    @Test func physicalNavigationUsesAudioTrackNumbersAndTheExactThreeSecondRule() async throws {
        let data = tocFixture([
            TOCSessionFixture(tracks: [
                TOCTrackFixture(number: 1, sector: 0, control: 4),
                TOCTrackFixture(number: 2, sector: 750),
                TOCTrackFixture(number: 3, sector: 2_250)
            ], leadOut: 3_750),
            TOCSessionFixture(number: 2, tracks: [
                TOCTrackFixture(number: 4, sector: 5_000, control: 4),
                TOCTrackFixture(number: 5, sector: 5_750)
            ], leadOut: 7_250)
        ])
        let test = try PhysicalPlayerFixture(data: data)
        let player = test.player
        await player.nextTrack()
        #expect(player.trackText == "02" && player.currentFrame == 0 && !player.isShowingDiscSummary)
        await player.nextTrack()
        #expect(player.trackText == "03" && player.currentFrame == 20 * Disc.sampleRate)
        #expect(test.opener.opens.isEmpty)
        await player.previousTrack()
        #expect(player.trackText == "02" && player.currentFrame == 0)
        await player.togglePlayback()
        await test.playback.setFrame(23 * Disc.sampleRate)
        await player.refreshPlayback()
        await player.previousTrack()
        #expect(player.currentFrame == 0)
        await test.playback.setFrame(23 * Disc.sampleRate + 1)
        await player.refreshPlayback()
        await player.previousTrack()
        #expect(player.currentFrame == 20 * Disc.sampleRate && player.trackText == "03")
        await player.nextTrack()
        #expect(player.trackText == "05" && player.currentFrame == 40 * Disc.sampleRate)
        await player.nextTrack()
        #expect(player.state == .playing && player.currentFrame == 40 * Disc.sampleRate)
        await test.playback.setFrame(test.disc.totalFrames)
        await player.refreshPlayback()
        #expect(player.state == .ended && player.statusText == "CD END")
        #expect(player.isShowingDiscSummary && player.trackText == "03" && player.timeText == "01:00")
        await player.togglePlayback()
        #expect(player.currentFrame == 0 && player.state == .playing && player.trackText == "02")
        #expect(test.opener.opens.count == 2)
        try await player.shutdown()
    }

    @Test func physicalDiscEndFollowsRenderedFramesReleasesTheDiscAndShowsItsTotal() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(test.disc.totalFrames - 1)
        await test.playback.setQuality(concealedSectors: 2, unverified: false)
        await player.refreshPlayback()
        #expect(player.state == .playing && player.trackText == "03" && player.timeText == "00:09")
        await test.playback.setFrame(test.disc.totalFrames)
        await player.refreshPlayback()
        #expect(player.state == .ended && player.statusText == "CD END | ERR 2")
        #expect(player.statusAccessibilityLabel == "CD ended. 2 audio sectors concealed")
        #expect(player.isShowingDiscSummary && player.currentFrame == 0)
        #expect(player.trackText == "03" && player.timeText == test.totalTimeText)
        #expect(player.stopOrEjectLabel == "Eject disc" && player.controlsEnabled)
        #expect(player.discSession == nil && test.opener.discs.first?.isClosed == true)
        await player.togglePlayback()
        #expect(player.state == .playing && player.trackText == "01")
        #expect(player.statusText == "BUFFERING")
        #expect(await test.playback.starts == [0, 0])
        #expect(test.opener.opens.count == 2)
        try await player.shutdown()
    }

    @Test func physicalStatusDisplaysReadQualityAndProvidesAnAccessibleExplanation() async throws {
        let test = try PhysicalPlayerFixture()
        await test.player.togglePlayback()
        await test.playback.setQuality(concealedSectors: 0, unverified: true)
        await test.player.refreshPlayback()
        #expect(test.player.statusText == "CD PLAYING | UNVERIFIED")
        #expect(!test.player.statusIsError && test.player.statusIsWarning)
        #expect(test.player.statusAccessibilityLabel ==
            "CD playing. Audio alignment or independent read verification is unverified")
        await test.playback.setQuality(concealedSectors: 3, unverified: true)
        await test.player.refreshPlayback()
        #expect(test.player.statusText == "CD PLAYING | ERR 3 | UNVERIFIED")
        #expect(test.player.statusIsError && !test.player.statusIsWarning)
        #expect(test.player.statusAccessibilityLabel ==
            "CD playing. 3 audio sectors concealed. Audio alignment or independent read verification is unverified")
        #expect(test.player.formatText == "44.1 kHz / 16-bit source")
        await test.player.togglePlayback()
        #expect(test.player.statusText == "CD PAUSED | ERR 3 | UNVERIFIED")
        await test.player.togglePlayback()
        await test.player.refreshPlayback()
        #expect(test.player.statusText == "CD PLAYING")
        #expect(test.player.concealedSectors == 0 && !test.player.isUnverified && !test.player.statusIsError)
        try await test.player.shutdown()
    }

    @Test func heldPhysicalSeeksUpdateImmediatelyAndRestartOnlyAtTheFinalTargetAfterThreeHundredMilliseconds() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.togglePlayback()
        await player.scan(.forward)
        let first = try #require(player.pendingSeek)
        #expect(player.currentFrame == 10 * Disc.sampleRate && player.trackText == "02")
        #expect(player.controlsEnabled && !player.isBusy)
        await player.scan(.forward)
        #expect(first.isCancelled)
        #expect(player.currentFrame == 20 * Disc.sampleRate && player.trackText == "03")
        let lastInput = ContinuousClock.now
        await player.scan(.backward)
        #expect(player.currentFrame == 10 * Disc.sampleRate && player.timeText == "00:00")
        await player.refreshPlayback()
        #expect(player.currentFrame == 10 * Disc.sampleRate)
        #expect(await test.playback.starts == [0])
        try await waitUntil { player.pendingSeek == nil }
        #expect(ContinuousClock.now - lastInput >= .milliseconds(300))
        #expect(await test.playback.starts == [0, 10 * Disc.sampleRate])
        #expect(player.state == .playing && test.opener.opens.count == 1)
        try await player.shutdown()
    }

    @Test func pausingAQueuedPhysicalSeekCancelsItsRestartAndPreservesTheDisplayedTarget() async throws {
        let test = try PhysicalPlayerFixture(seekDelay: .seconds(3_600))
        await test.player.togglePlayback()
        await test.player.scan(.forward)
        let pending = try #require(test.player.pendingSeek)
        await test.player.togglePlayback()
        #expect(pending.isCancelled && test.player.pendingSeek == nil)
        #expect(test.player.state == .paused && test.player.currentFrame == 10 * Disc.sampleRate)
        #expect(await test.playback.starts == [0])
        await test.player.togglePlayback()
        #expect(await test.playback.starts == [0, 10 * Disc.sampleRate])
        #expect(test.opener.opens.count == 1)
        try await test.player.shutdown()
    }

    @Test func physicalSeeksStopShortOfTheDiscEndsInEveryStateWithoutWrapping() async throws {
        let test = try PhysicalPlayerFixture(seekDelay: .seconds(3_600))
        let player = test.player
        await player.scan(.backward)
        #expect(player.currentFrame == 0 && test.opener.opens.isEmpty)
        for _ in 0..<4 { await player.scan(.forward) }
        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.currentFrame == 20 * Disc.sampleRate && test.opener.opens.isEmpty)
        for _ in 0..<3 { await player.scan(.backward) }
        #expect(player.currentFrame == 0)

        await player.togglePlayback()
        for _ in 0..<4 { await player.scan(.forward) }
        let pending = try #require(player.pendingSeek)
        #expect(player.state == .playing && player.statusText == "BUFFERING")
        #expect(player.currentFrame == 20 * Disc.sampleRate && player.trackText == "03")
        await player.togglePlayback()
        #expect(pending.isCancelled && player.state == .paused)
        for _ in 0..<2 { await player.scan(.forward) }
        #expect(player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.currentFrame == 20 * Disc.sampleRate)
        #expect(await test.playback.starts == [0])
        await player.togglePlayback()
        #expect(await test.playback.starts == [0, 20 * Disc.sampleRate])
        #expect(test.opener.opens.count == 1)
        try await player.shutdown()
    }

    @Test func theDriveSelectorMenuAndAPIStayDisabledWhileACDPlaysOrSeeks() async throws {
        let test = try PhysicalPlayerFixture(seekDelay: .seconds(3_600), multipleDrives: true)
        let player = test.player
        await player.togglePlayback()
        #expect(player.showsDriveSelector && !player.driveSelectorEnabled && !player.opticalDriveSelectionEnabled)
        player.selectNextDrive()
        await player.useOpticalDrive(id: 2)
        #expect(player.selectedDriveID == 1 && player.pendingDriveID == nil)
        #expect(player.state == .playing && test.opener.opens.count == 1)
        await player.scan(.forward)
        #expect(!player.driveSelectorEnabled && !player.opticalDriveSelectionEnabled)
        await player.togglePlayback()
        #expect(player.driveSelectorEnabled && player.opticalDriveSelectionEnabled)
        await player.useOpticalDrive(id: 2)
        #expect(test.opener.discs.first?.isClosed == true)
        #expect(player.selectedDriveID == 2 && player.state == .ready)
        #expect(test.opener.opens.count == 1)
        await player.togglePlayback()
        #expect(test.opener.opens.map(\.driveID) == [1, 2])
        try await player.shutdown()
    }

    @Test func ordinaryRegistryRefreshesAndOtherDriveChangesDoNotResetPhysicalPlaybackOrPause() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(12 * Disc.sampleRate)
        await player.refreshPlayback()
        let session = try #require(player.discSession)
        test.service.refresh()
        test.service.emit([opticalDrive(media: try audioMedia(mounted: true)), opticalDrive(id: 2)])
        #expect(player.state == .playing && player.currentFrame == 12 * Disc.sampleRate)
        #expect(player.trackText == "02" && player.timeText == "00:02")
        #expect(player.discSession === session && !player.isShowingDiscSummary)
        await player.togglePlayback()
        test.service.refresh()
        #expect(player.state == .paused && player.currentFrame == 12 * Disc.sampleRate)
        #expect(player.discSession === session && test.opener.opens.count == 1)
        try await player.shutdown()
    }

    @Test func aDiscMacOSMountedPlaysAndEjectsWhileItsVolumeIsUnmountedFirst() async throws {
        let test = try PhysicalPlayerFixture(mounted: true)
        let player = test.player
        let media = try #require(player.selectedDrive?.media)
        #expect(player.statusText == "CD DETECTED" && player.guidanceText.contains("Mounted."))
        await player.togglePlayback()
        await test.playback.setFrame(12 * Disc.sampleRate)
        await player.refreshPlayback()
        #expect(player.state == .playing && player.timeText == "00:02")
        #expect(test.opener.opens == [.init(mediaID: 10, driveID: 1, onMainThread: false)])
        let unmounted = OpticalMedia(
            id: media.id, bsdName: media.bsdName, contents: media.contents, isMounted: false,
            isEjectable: media.isEjectable
        )
        var whileUnmounting: (status: String, error: String?)?
        test.service.onEject = {
            // Disk Arbitration removes the volume path before the media leaves the drive.
            test.service.emit([opticalDrive(media: unmounted)])
            whileUnmounting = (player.statusText, player.errorDetail)
        }

        await player.eject()

        #expect(whileUnmounting?.status == "EJECTING" && whileUnmounting?.error == nil)
        #expect(test.opener.discs.first?.isClosed == true && player.discSession == nil)
        #expect(test.service.ejects.map(\.media) == [10] && player.errorDetail == nil)
        #expect(player.statusText == "NO DISC" && player.trackText == "00")
        try await player.shutdown()
    }

    @Test func multiDrivePlaybackSurvivesOtherDriveHotplugAndKeepsReadFeaturesIsolated() async throws {
        let data = tocFixture()
        let table = try CDTableOfContents(data: data)
        let modelName = "Test optical drive"
        let firstMedia = OpticalMedia(
            id: 10, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true
        )
        let secondMedia = OpticalMedia(
            id: 20, bsdName: "disk5", contents: .audioCD(table), isMounted: false, isEjectable: true
        )
        let rawDrives = [
            OpticalDrive(id: 1, name: modelName, media: firstMedia),
            OpticalDrive(id: 2, name: modelName, media: secondMedia),
        ]
        let namedDrives = OpticalDrive.numberingDuplicateNames(rawDrives)
        let firstDrive = try #require(namedDrives.first)
        let secondDrive = try #require(namedDrives.last)
        let opener = FakeDiscOpener(
            tableOfContents: data,
            driveProfiles: [
                1: .init(readFeatures: CDReadFeatures(cdFeatures: 0x10), supportsErrorFlags: true),
                2: .init(readFeatures: CDReadFeatures(), supportsErrorFlags: false),
            ]
        )
        let service = FakeOpticalService([firstDrive, secondDrive])
        let playback = FakeEngine(totalFrames: Disc(tableOfContents: table).totalFrames)
        let player = PlayerModel.offline(
            engine: FakeEngine(), automaticallyMonitor: false, opticalService: service,
            discOpener: opener, makeDiscEngine: { _ in playback }
        )
        player.startOpticalMonitoring()

        #expect(player.selectedDriveID == 1)
        #expect(player.selectedDrive?.name == "\(modelName) (1)")
        await player.togglePlayback()
        let firstSession = try #require(player.discSession)
        #expect(firstSession.driveID == 1 && firstSession.mediaID == 10)
        #expect(await firstSession.readFeatures.streamAccurate)
        #expect(try await firstSession.probeC2(at: 0).support == .supported)
        #expect(opener.opens == [.init(mediaID: 10, driveID: 1, onMainThread: false)])

        await playback.setFrame(5 * Disc.sampleRate)
        await player.refreshPlayback()
        let session = player.discSession
        let frame = player.currentFrame
        service.emit(OpticalDrive.numberingDuplicateNames([rawDrives[0]]))
        #expect(player.state == .playing && player.currentFrame == frame)
        #expect(player.discSession === session && player.discSession === firstSession)
        #expect(await firstSession.isOpen)
        service.emit(namedDrives)
        #expect(player.state == .playing && player.currentFrame == frame)
        let firstSessionIsOpenAfterReplug = await firstSession.isOpen
        #expect(player.discSession === firstSession && firstSessionIsOpenAfterReplug)
        #expect(opener.opens.count == 1)

        await player.togglePlayback()
        #expect(player.state == .paused && player.discSession === firstSession)
        await player.useOpticalDrive(id: 2)
        #expect(player.selectedDriveID == 2 && player.selectedDrive?.name == "\(modelName) (2)")
        #expect(player.state == .ready && player.discSession == nil)
        #expect(!(await firstSession.isOpen))
        #expect(opener.discs.first?.isClosed == true && opener.opens.count == 1)

        await player.togglePlayback()
        let secondSession = try #require(player.discSession)
        #expect(secondSession.driveID == 2 && secondSession.mediaID == 20)
        #expect(await secondSession.readFeatures.cdFeatures == nil)
        #expect(!(await secondSession.readFeatures.streamAccurate))
        #expect(try await secondSession.probeC2(at: 0).support == .unsupported)
        #expect(await firstSession.readFeatures.streamAccurate)
        #expect(opener.opens.map(\.driveID) == [1, 2])
        #expect(opener.opens.map(\.mediaID) == [10, 20])
        #expect(opener.discs[0].reads == [.init(firstSector: 0, count: 1, errorFlags: true)])
        #expect(opener.discs[1].reads == [
            .init(firstSector: 0, count: 1, errorFlags: true),
            .init(firstSector: 0, count: 1, errorFlags: false),
        ])
        try await player.shutdown()
    }

    @Test(arguments: 0..<5)
    func changedOrUnavailablePhysicalMediaClosesTheOldSessionAndNeverAutoplays(_ change: Int) async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.togglePlayback()
        let old = try #require(test.opener.discs.first)
        let stops = await test.playback.stops
        switch change {
        case 0: test.service.emit([opticalDrive()])
        case 1: test.service.emit([opticalDrive(media: try audioMedia(id: 11))])
        case 2: test.service.emit([opticalDrive(id: 2, media: try audioMedia(id: 20))])
        case 3:
            let table = try CDTableOfContents(data: tocFixture([
                TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 1_000)
            ]))
            test.service.emit([opticalDrive(media: OpticalMedia(
                id: 10, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true
            ))])
        default: test.service.emit(test.service.snapshot.drives, error: "Optical metadata was lost.")
        }
        #expect(player.discSession == nil && !player.isPlayingCD)
        try await waitUntil { old.isClosed }
        #expect(await test.playback.stops > stops)
        #expect(await test.playback.starts == [0])
        #expect(test.opener.opens.count == 1 && player.currentFrame == 0)
        #expect(change == 0 ? player.state == .empty : change == 4 ? player.state == .failed : player.state == .ready)
        try await player.shutdown()
    }

    @Test(arguments: [false, true])
    func aLatePhysicalStartCannotReviveAReplacedDiscOrOverwriteItsStatus(fails: Bool) async throws {
        let test = try PhysicalPlayerFixture()
        await test.playback.suspendStart()
        let starting = Task { await test.player.togglePlayback() }
        try await waitUntil { await test.playback.startIsWaiting() }
        test.service.emit([opticalDrive(media: try audioMedia(id: 11))])
        try await waitUntil { test.opener.discs.first?.isClosed == true }
        await test.playback.failStart(fails)
        await test.playback.resumeStart()
        await starting.value
        #expect(test.player.state == .ready && test.player.statusText == "CD DETECTED")
        #expect(test.player.currentFrame == 0 && test.player.output == nil)
        #expect(test.player.errorDetail == nil && test.player.discSession == nil)
        #expect(test.opener.opens.count == 1)
        try await test.player.shutdown()
    }

    @Test func aLatePhysicalSnapshotCannotReplaceAnEjectedDiscsEmptyState() async throws {
        let test = try PhysicalPlayerFixture()
        await test.player.togglePlayback()
        await test.playback.suspendSnapshot()
        let polling = Task { await test.player.refreshPlayback() }
        try await waitUntil { await test.playback.snapshotIsWaiting() }
        test.service.emit([opticalDrive()])
        await test.playback.resumeSnapshot(at: 15 * Disc.sampleRate)
        await polling.value
        #expect(test.player.state == .empty && test.player.currentFrame == 0)
        #expect(test.player.formatText.isEmpty && test.player.trackText == "00")
        try await test.player.shutdown()
    }

    @Test func cancellingPhysicalPlayWhileOpeningClosesTheLateSessionWithoutStartingAnEngine() async throws {
        let gate = TestGate()
        defer { gate.release() }
        let test = try PhysicalPlayerFixture(opener: FakeDiscOpener(gate: gate))
        let starting = Task { await test.player.togglePlayback() }
        try await waitUntil { gate.hasEntered }
        starting.cancel()
        gate.release()
        await starting.value
        #expect(test.opener.discs.first?.isClosed == true)
        #expect(test.player.state == .ready && test.player.discSession == nil)
        #expect(test.player.errorDetail == nil && !test.player.isBusy)
        #expect(await test.playback.starts.isEmpty)
        try await test.player.shutdown()
    }

    @Test(arguments: [CD_DISC_REFUSED, CD_DISC_GONE, CD_DISC_READ_ERROR, CD_DISC_FAILED, CD_READ_TIMEOUT])
    func physicalPlaybackFailuresKeepShortCategoriesAndCloseTheSession(_ code: CDResult) async throws {
        let test = try PhysicalPlayerFixture()
        await test.player.togglePlayback()
        let failure = AudioPlaybackError(CDError(result: code, message: "The scripted playback failed.", systemStatus: 5))
        await test.playback.failSnapshot(with: failure)
        await test.player.refreshPlayback()
        let summary = code == CD_DISC_REFUSED ? "Access denied"
            : code == CD_DISC_READ_ERROR || code == CD_READ_TIMEOUT ? "Read error"
            : "Disc error"
        #expect(test.player.state == .failed && test.player.statusText == "[ERR] \(summary)")
        #expect(test.player.statusIsError && test.player.statusAccessibilityLabel == "Error: \(summary)")
        #expect(test.player.errorDetail == failure.message)
        // With one drive, only a disc error offers a rescan; Play retries the others.
        #expect(test.player.showsDriveSelector == (summary == "Disc error"))
        #expect(test.player.discSession == nil && test.opener.discs.first?.isClosed == true)
        #expect(test.opener.opens.count == 1)
        try await test.player.shutdown()
    }

    @Test func outputChangeOnALoneDrivePausesForPlayToResumeRatherThanOfferingADriveRescan() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(15 * Disc.sampleRate)
        await player.refreshPlayback()
        await test.playback.failSnapshot(with: AudioPlaybackError(CDError(
            result: CD_CONFIGURATION_CHANGED,
            message: "The audio route, sample rate or availability changed. Press Play to reconnect.", systemStatus: 0
        )))
        await player.refreshPlayback()
        #expect(player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.trackText == "02" && player.timeText == "00:05")
        #expect(!player.showsDriveSelector && !player.driveSelectorEnabled)
        player.selectNextDrive()
        #expect(player.pendingDriveID == nil && test.service.refreshes == 0)
        #expect(player.controlsEnabled && player.stopOrEjectLabel == "Stop")
        #expect(player.discSession != nil && test.opener.discs.first?.isClosed == false)

        await player.togglePlayback()
        #expect(player.state == .playing && player.errorDetail == nil)
        #expect(await test.playback.starts == [0, 15 * Disc.sampleRate])
        #expect(test.opener.opens.count == 1)
        try await player.shutdown()
    }

    @Test func nextAfterAnAudioErrorOnTheLastTrackKeepsThePositionForPlay() async throws {
        let test = try PhysicalPlayerFixture()
        let player = test.player
        for _ in 0..<test.disc.tracks.count { await player.nextTrack() }
        await player.togglePlayback()
        await test.playback.setFrame(25 * Disc.sampleRate)
        await player.refreshPlayback()
        await test.playback.failSnapshot(with: AudioPlaybackError(CDError(
            result: CD_CORE_AUDIO_ERROR,
            message: "The output failed.", systemStatus: 5
        )))
        await player.refreshPlayback()
        #expect(player.state == .failed && player.statusText == "[ERR] Audio error")
        await player.nextTrack()
        #expect(player.state == .paused && player.statusText == "CD PAUSED" && player.errorDetail == nil)
        #expect(player.trackText == "03" && player.timeText == "00:05")
        #expect(player.currentFrame == 25 * Disc.sampleRate && player.discSession == nil)
        await player.togglePlayback()
        #expect(player.state == .playing && player.currentFrame == 25 * Disc.sampleRate)
        #expect(await test.playback.starts == [20 * Disc.sampleRate, 25 * Disc.sampleRate])
        #expect(test.opener.opens.count == 2)
        try await player.shutdown()
    }

    @Test func physicalStartFailureIsRetryableButNeverLeavesItsOldSessionOpen() async throws {
        let test = try PhysicalPlayerFixture()
        await test.playback.failStart(true)
        await test.player.togglePlayback()
        #expect(test.player.state == .failed && test.player.errorSummary == "Audio error")
        #expect(test.player.discSession == nil && test.opener.discs.first?.isClosed == true)
        await test.playback.failStart(false)
        await test.player.togglePlayback()
        #expect(test.player.state == .playing && test.player.errorDetail == nil)
        #expect(test.opener.opens.count == 2 && test.opener.discs.last?.isClosed == false)
        try await test.player.shutdown()
    }

    @Test(arguments: [false, true])
    func cancelledPhysicalTrackChangesStopWithoutReportingAnErrorOrRemainingPlaying(previous: Bool) async throws {
        let test = try PhysicalPlayerFixture()
        await test.player.togglePlayback()
        await test.playback.setFrame(5 * Disc.sampleRate)
        await test.player.refreshPlayback()
        await test.playback.suspendStart()
        let changing = Task {
            if previous { await test.player.previousTrack() }
            else { await test.player.nextTrack() }
        }
        try await waitUntil { await test.playback.startIsWaiting() }
        changing.cancel()
        await test.playback.resumeStart()
        await changing.value
        #expect(test.player.state == .paused && !test.player.isBusy)
        #expect(test.player.currentFrame == (previous ? 0 : 10 * Disc.sampleRate))
        #expect(test.player.errorDetail == nil && test.player.discSession == nil)
        #expect(test.opener.discs.first?.isClosed == true)
        await test.player.togglePlayback()
        #expect(test.player.state == .playing && test.opener.opens.count == 2)
        try await test.player.shutdown()
    }

    @Test(arguments: 0..<7)
    func queuedPhysicalSeeksCannotRestartAfterAnotherTransportActionOrMediaChange(_ action: Int) async throws {
        let test = try PhysicalPlayerFixture(seekDelay: .seconds(3_600))
        await test.player.togglePlayback()
        await test.player.scan(.forward)
        let pending = try #require(test.player.pendingSeek)
        switch action {
        case 0: await test.player.nextTrack()
        case 1: await test.player.previousTrack()
        case 2: await test.player.eject()
        case 3: test.service.emit([opticalDrive()])
        case 4: await test.player.insertDemoDisc()
        case 5: try await test.player.shutdown()
        default: test.service.emit([opticalDrive(media: try audioMedia(id: 11))])
        }
        await pending.value
        #expect(pending.isCancelled && test.player.pendingSeek == nil)
        let starts = await test.playback.starts
        #expect(starts == (action == 0 ? [0, 20 * Disc.sampleRate] : action == 1 ? [0, 0] : [0]))
        #expect(test.player.errorDetail == nil && test.opener.opens.count == 1)
        try await test.player.shutdown()
    }

    @Test func selectingOrSeekingAPausedPhysicalCDNeverOpensOrReadsItUntilPlay() async throws {
        let test = try PhysicalPlayerFixture()
        await test.player.scan(.forward)
        await test.player.nextTrack()
        await test.player.previousTrack()
        #expect(test.player.currentFrame == 10 * Disc.sampleRate)
        #expect(test.opener.opens.isEmpty)
        #expect(await test.playback.starts.isEmpty)
        #expect(await test.demo.starts.isEmpty)
        await test.player.togglePlayback()
        #expect(await test.playback.starts == [10 * Disc.sampleRate])
        #expect(test.opener.opens.count == 1)
        try await test.player.shutdown()
    }
}
