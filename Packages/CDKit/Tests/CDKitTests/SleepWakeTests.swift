import CDAudioCore
import Foundation
import Testing
@testable import CDKit

@MainActor
final class FakeSleepPrevention: SleepPreventing {
    private(set) var isActive = false
    private(set) var activations = 0

    nonisolated init() {}

    func setActive(_ active: Bool) {
        if active && !isActive { activations += 1 }
        isActive = active
    }
}

/// Delivers sleep and wake as IOKit does, counting how often sleep was allowed.
final class FakePowerMonitor: SystemPowerMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<SystemPowerEvent>.Continuation?
    private var acknowledgements = 0
    private var streamEnded = false

    var acknowledged: Int { lock.withLock { acknowledgements } }
    var ended: Bool { lock.withLock { streamEnded } }

    func events() -> AsyncStream<SystemPowerEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SystemPowerEvent.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?.streamEnded = true } }
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func willSleep() {
        let acknowledge: @Sendable () -> Void = { [weak self] in self?.lock.withLock { self?.acknowledgements += 1 } }
        let continuation = lock.withLock { self.continuation }
        if case .terminated? = continuation?.yield(.willSleep(acknowledge: acknowledge)) { acknowledge() }
    }

    func didWake() {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(.didWake)
    }
}

private enum SleepTestFailure: LocalizedError {
    case recovery
    var errorDescription: String? { "Cannot recover a previously changed output rate." }
}

private final class AllowedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    var ids: [Int] { lock.withLock { recorded } }
    func record(_ id: Int) { lock.withLock { recorded.append(id) } }
}

@MainActor
private struct SleepFixture {
    let player: PlayerModel
    let demo = FakeEngine()
    let playback: FakeEngine
    let opener: FakeDiscOpener
    let service: FakeOpticalService
    let prevention = FakeSleepPrevention()
    let power = FakePowerMonitor()
    let rates = FakeOutputRateControl()
    let table: CDTableOfContents

    init(
        opener: FakeDiscOpener = FakeDiscOpener(), seekDelay: Duration = .milliseconds(300),
        wakeGrace: Duration = .seconds(60), sleepAcknowledgementLimit: Duration = .seconds(10),
        otherDrive: OpticalDrive? = nil
    ) throws {
        table = try CDTableOfContents(data: tocFixture())
        playback = FakeEngine(totalFrames: Disc(tableOfContents: table).totalFrames)
        self.opener = opener
        service = FakeOpticalService([opticalDrive(media: try audioMedia())] + (otherDrive.map { [$0] } ?? []))
        let playback = self.playback
        player = PlayerModel.offline(
            engine: demo, automaticallyMonitor: false, opticalService: service, discOpener: opener,
            seekDelay: seekDelay, makeDiscEngine: { _ in playback }, outputRateControl: rates,
            sleepPrevention: prevention, powerMonitor: power, wakeGrace: wakeGrace,
            sleepAcknowledgementLimit: sleepAcknowledgementLimit
        )
        player.startOpticalMonitoring()
        player.startPowerMonitoring()
    }

    /// Plays to `frame`, then returns once the Mac may sleep.
    func sleep(playingAt frame: UInt64) async throws {
        await player.togglePlayback()
        await playback.setFrame(frame)
        await player.refreshPlayback()
        try await sleep()
    }

    func sleep() async throws {
        let allowed = power.acknowledged
        power.willSleep()
        try await waitUntil { power.acknowledged == allowed + 1 }
    }
}

/// The fixture's drive after macOS reconnected it under new IDs, as a USB drive can on wake.
private func reconnectedDrive(
    id: UInt64 = 5, mediaID: UInt64 = 50, contents: OpticalContents, name: String = "Test Blu-ray drive 1"
) -> OpticalDrive {
    OpticalDrive(
        id: id, name: name,
        media: OpticalMedia(id: mediaID, bsdName: "disk6", contents: contents, isMounted: false, isEjectable: true)
    )
}

@Suite(.serialized)
@MainActor
struct SleepWakeTests {
    @Test func idleSleepIsHeldOffOnlyWhileTheCDPlays() async throws {
        let test = try SleepFixture()
        let player = test.player
        #expect(!test.prevention.isActive)
        await player.togglePlayback()
        #expect(player.state == .playing && test.prevention.isActive)
        await player.scan(.forward)
        #expect(player.pendingSeek != nil && test.prevention.isActive && test.prevention.activations == 1)
        await player.togglePlayback()
        #expect(player.state == .paused && !test.prevention.isActive)
        await player.togglePlayback()
        #expect(test.prevention.isActive && test.prevention.activations == 2)
        await player.stopOrEject()
        #expect(player.state == .ready && !test.prevention.isActive)
        await player.togglePlayback()
        #expect(test.prevention.isActive && test.prevention.activations == 3)
        await test.playback.failSnapshot()
        await player.refreshPlayback()
        #expect(player.state == .failed && !test.prevention.isActive)
        await player.togglePlayback()
        #expect(test.prevention.isActive && test.prevention.activations == 4)
        try await player.shutdown()
        #expect(!test.prevention.isActive)
    }

    @Test func sleepWhilePlayingWaitsForThePauseAndTheClosedDisc() async throws {
        let test = try SleepFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(12 * Disc.sampleRate)
        await player.refreshPlayback()
        let disc = try #require(test.opener.discs.first)
        await test.playback.suspendStop()
        test.power.willSleep()
        try await waitUntil { await test.playback.stopIsWaiting() }
        #expect(player.isPreparingForSleep && !player.controlsEnabled && !player.ejectEnabled)
        #expect(!player.opticalDriveSelectionEnabled && !player.outputRateSwitchEnabled)
        #expect(test.power.acknowledged == 0 && !disc.isClosed)
        await test.playback.resumeStop()
        try await waitUntil { test.power.acknowledged == 1 }
        #expect(player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.trackText == "02" && player.timeText == "00:02")
        #expect(!player.isPreparingForSleep && player.controlsEnabled)
        #expect(player.discSession == nil && disc.isClosed)
        #expect(!test.prevention.isActive)
        #expect(player.sleepPosition == PlayerModel.SleepPosition(
            driveName: "Test Blu-ray drive 1", tableOfContents: test.table, frame: 12 * Disc.sampleRate,
            state: .paused, hasSelectedTrack: true, concealedSectors: 0, isUnverified: false
        ))
        test.power.didWake()
        await player.togglePlayback()
        #expect(player.state == .playing && player.sleepPosition == nil)
        #expect(await test.playback.starts == [0, 12 * Disc.sampleRate])
        #expect(test.opener.opens.count == 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(test.power.acknowledged == 1)
        try await player.shutdown()
    }

    @Test func anOutputRestoreHeldBySleepFinishesAfterWakeBeforePlayWithoutAnError() async throws {
        let test = try SleepFixture()
        let player = test.player
        await test.playback.deferOutputRestoreBeforeSleep()
        try await test.sleep(playingAt: 12 * Disc.sampleRate)
        #expect(await test.playback.sleepStops == 1)
        #expect(player.state == .paused && player.statusText == "CD PAUSED" && player.errorMessage == nil)
        #expect(player.trackText == "02" && player.timeText == "00:02")
        #expect(player.restoresOutputAfterWake && player.sleepPosition?.frame == 12 * Disc.sampleRate)
        #expect(await test.rates.calls.isEmpty)
        await test.rates.holdRecovery()
        test.power.didWake()
        try await waitUntil { await test.rates.recoveryIsHeld() }
        #expect(!player.restoresOutputAfterWake && player.isRecoveringOutputRates && !player.controlsEnabled)
        // Play would otherwise record the output still at the playback format as the one to restore.
        let play = Task { await player.togglePlayback() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await test.playback.starts == [0])
        await test.rates.releaseRecovery()
        await play.value
        #expect(player.state == .playing && player.errorMessage == nil && !player.isRecoveringOutputRates)
        #expect(await test.playback.starts == [0, 12 * Disc.sampleRate])
        #expect(await test.rates.calls == [.recover])
        try await player.shutdown()
    }

    @Test func anOutputRestoreThatStillFailsAfterWakeShowsTheAudioError() async throws {
        let test = try SleepFixture()
        let player = test.player
        await test.playback.deferOutputRestoreBeforeSleep()
        try await test.sleep(playingAt: 12 * Disc.sampleRate)
        #expect(player.state == .paused && player.errorMessage == nil)
        await test.rates.failRecovery(with: SleepTestFailure.recovery)
        test.power.didWake()
        try await waitUntil { player.state == .failed && !player.isRecoveringOutputRates }
        #expect(player.statusText == "[ERR] Audio error")
        #expect(player.errorDetail == "Cannot recover a previously changed output rate.")
        #expect(player.currentFrame == 12 * Disc.sampleRate && !player.restoresOutputAfterWake)
        #expect(await test.rates.calls == [.recover])
        try await player.shutdown()
    }

    @Test func wakeRecoversNoOutputWhenItsRestoreFinishedBeforeSleep() async throws {
        let test = try SleepFixture(wakeGrace: .milliseconds(50))
        let player = test.player
        try await test.sleep(playingAt: 12 * Disc.sampleRate)
        #expect(await test.playback.sleepStops == 1 && !player.restoresOutputAfterWake)
        test.power.didWake()
        try await waitUntil { player.sleepPosition == nil }
        #expect(!player.isRecoveringOutputRates && player.errorMessage == nil)
        #expect(await test.rates.calls.isEmpty)
        try await player.shutdown()
    }

    @Test func aStalledPauseStillAllowsSleepAtTheLimitAndOnlyOnce() async throws {
        let test = try SleepFixture(sleepAcknowledgementLimit: .milliseconds(100))
        let player = test.player
        await player.togglePlayback()
        await test.playback.suspendStop()
        let asked = ContinuousClock.now
        test.power.willSleep()
        try await waitUntil { test.power.acknowledged == 1 }
        #expect(ContinuousClock.now - asked >= .milliseconds(100))
        #expect(player.isPreparingForSleep && player.state == .playing)
        await test.playback.resumeStop()
        try await waitUntil { !player.isPreparingForSleep }
        #expect(player.state == .paused && test.power.acknowledged == 1)
        try await player.shutdown()
    }

    @Test func sleepDuringASeekPausesAtItsTarget() async throws {
        let test = try SleepFixture(seekDelay: .seconds(5))
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(12 * Disc.sampleRate)
        await player.refreshPlayback()
        await player.scan(.forward)
        #expect(player.pendingSeek != nil && player.currentFrame == 22 * Disc.sampleRate)
        try await test.sleep()
        #expect(player.state == .paused && player.pendingSeek == nil)
        #expect(player.currentFrame == 22 * Disc.sampleRate && player.trackText == "03")
        #expect(await test.playback.starts == [0])
        #expect(player.sleepPosition?.frame == 22 * Disc.sampleRate)
        test.power.didWake()
        await player.togglePlayback()
        #expect(await test.playback.starts == [0, 22 * Disc.sampleRate])
        try await player.shutdown()
    }

    @Test func sleepWhilePlayIsOpeningTheDiscKeepsTheChosenTrackAndNeverStarts() async throws {
        let gate = TestGate()
        defer { gate.release() }
        let test = try SleepFixture(opener: FakeDiscOpener(gate: gate))
        let player = test.player
        await player.nextTrack()
        await player.nextTrack()
        #expect(player.trackText == "02" && player.state == .ready)
        let play = Task { await player.togglePlayback() }
        try await waitUntil { gate.hasEntered }
        test.power.willSleep()
        try await waitUntil { player.isPreparingForSleep }
        try await Task.sleep(for: .milliseconds(50))
        #expect(test.power.acknowledged == 0)
        gate.release()
        await play.value
        try await waitUntil { test.power.acknowledged == 1 }
        #expect(await test.playback.starts.isEmpty && player.discSession == nil)
        #expect(test.opener.discs.count == 1 && test.opener.discs.first?.isClosed == true)
        #expect(player.state == .ready && player.trackText == "02" && player.currentFrame == 10 * Disc.sampleRate)
        #expect(player.sleepPosition?.state == .ready && player.sleepPosition?.frame == 10 * Disc.sampleRate)
        #expect(player.controlsEnabled && test.prevention.activations == 0)
        try await player.shutdown()
    }

    @Test func sleepWhilePausedClosesTheOpenDiscAndKeepsThePosition() async throws {
        let test = try SleepFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(12 * Disc.sampleRate)
        await player.refreshPlayback()
        await player.togglePlayback()
        let disc = try #require(test.opener.discs.first)
        #expect(player.state == .paused && player.discSession != nil && !disc.isClosed)
        try await test.sleep()
        #expect(player.state == .paused && player.currentFrame == 12 * Disc.sampleRate)
        #expect(player.discSession == nil && disc.isClosed)
        #expect(player.sleepPosition?.state == .paused && player.sleepPosition?.frame == 12 * Disc.sampleRate)
        test.power.didWake()
        test.service.emit([])
        test.service.emit([reconnectedDrive(contents: .audioCD(test.table))])
        #expect(player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.trackText == "02" && player.timeText == "00:02")
        await player.togglePlayback()
        #expect(await test.playback.starts == [0, 12 * Disc.sampleRate] && test.opener.opens.count == 2)
        try await player.shutdown()
    }

    @Test func sleepWhileBufferingPausesAtThePlayedPosition() async throws {
        let test = try SleepFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.setFrame(12 * Disc.sampleRate)
        await test.playback.setBuffering(true)
        await player.refreshPlayback()
        #expect(player.statusText == "BUFFERING" && test.prevention.isActive)
        try await test.sleep()
        #expect(player.state == .paused && player.statusText == "CD PAUSED" && !player.isBuffering)
        #expect(player.currentFrame == 12 * Disc.sampleRate && player.bufferedFrames == 0)
        #expect(player.sleepPosition?.frame == 12 * Disc.sampleRate && !test.prevention.isActive)
        test.power.didWake()
        await player.togglePlayback()
        #expect(await test.playback.starts == [0, 12 * Disc.sampleRate])
        try await player.shutdown()
    }

    @Test func sleepWhileEjectingKeepsNoPositionAndTheEjectFinishes() async throws {
        let test = try SleepFixture()
        let player = test.player
        await player.nextTrack()
        await player.nextTrack()
        #expect(player.trackText == "02" && player.stopOrEjectLabel == "Eject disc")
        await test.demo.suspendStop()
        let eject = Task { await player.stopOrEject() }
        try await waitUntil { await test.demo.stopIsWaiting() }
        #expect(player.statusText == "EJECTING")
        test.power.willSleep()
        try await waitUntil { await test.demo.stops == 2 }
        #expect(player.isPreparingForSleep && player.sleepPosition == nil && test.power.acknowledged == 0)
        await test.demo.resumeStop()
        await eject.value
        try await waitUntil { test.power.acknowledged == 1 }
        #expect(test.service.ejects.map(\.media) == [10])
        #expect(player.state == .empty && player.statusText == "NO DISC" && player.sleepPosition == nil)
        test.power.didWake()
        test.service.emit([reconnectedDrive(contents: .audioCD(test.table))])
        #expect(player.state == .ready && player.isShowingDiscSummary)
        #expect(test.opener.opens.isEmpty && test.prevention.activations == 0)
        try await player.shutdown()
    }

    @Test func wakeRestoresThePositionWheneverTheReconnectedDriveShowsTheSameDisc() async throws {
        let test = try SleepFixture()
        let player = test.player
        try await test.sleep(playingAt: 12 * Disc.sampleRate)
        test.power.didWake()
        test.service.emit([])
        #expect(player.state == .empty && player.sleepPosition != nil)
        test.service.emit([reconnectedDrive(contents: .reading)])
        #expect(player.state == .empty && player.sleepPosition != nil)
        test.service.emit([reconnectedDrive(contents: .audioCD(test.table))])
        #expect(player.selectedDriveID == 5 && player.state == .paused && player.statusText == "CD PAUSED")
        #expect(player.currentFrame == 12 * Disc.sampleRate && player.trackText == "02" && player.timeText == "00:02")
        #expect(player.controlsEnabled)
        // The drive can reconnect more than once while it wakes.
        test.service.emit([])
        test.service.emit([reconnectedDrive(id: 6, mediaID: 60, contents: .audioCD(test.table))])
        #expect(player.state == .paused && player.currentFrame == 12 * Disc.sampleRate)
        await player.togglePlayback()
        #expect(player.state == .playing && player.sleepPosition == nil)
        #expect(test.opener.opens.last == .init(mediaID: 60, driveID: 6, onMainThread: false))
        #expect(await test.playback.starts == [0, 12 * Disc.sampleRate])
        try await player.shutdown()
    }

    @Test(arguments: [false, true])
    func anotherDiscAfterWakeDiscardsTheKeptPosition(dataDisc: Bool) async throws {
        let test = try SleepFixture()
        let player = test.player
        try await test.sleep(playingAt: 12 * Disc.sampleRate)
        test.power.didWake()
        let other = try CDTableOfContents(data: tocFixture([TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0), TOCTrackFixture(number: 2, sector: 1_500)
        ], leadOut: 3_000)]))
        test.service.emit([reconnectedDrive(contents: dataDisc ? .dataCD : .audioCD(other))])
        #expect(player.sleepPosition == nil && player.state != .paused)
        test.service.emit([reconnectedDrive(id: 6, mediaID: 60, contents: .audioCD(test.table))])
        #expect(player.state == .ready && player.isShowingDiscSummary && player.currentFrame == 0)
        try await player.shutdown()
    }

    @Test func theKeptPositionLastsOnlyForTheGraceThatStartsAtWake() async throws {
        let test = try SleepFixture(wakeGrace: .milliseconds(200))
        let player = test.player
        try await test.sleep(playingAt: 12 * Disc.sampleRate)
        try await Task.sleep(for: .milliseconds(400))
        #expect(player.sleepPosition != nil)
        let woke = ContinuousClock.now
        test.power.didWake()
        try await waitUntil { player.sleepPosition == nil }
        #expect(ContinuousClock.now - woke >= .milliseconds(200))
        test.service.emit([])
        test.service.emit([reconnectedDrive(contents: .audioCD(test.table))])
        #expect(player.state == .ready && player.isShowingDiscSummary)
        try await player.shutdown()
    }

    @Test func anActionAfterWakeEndsTheKeptPosition() async throws {
        let test = try SleepFixture()
        let player = test.player
        try await test.sleep(playingAt: 12 * Disc.sampleRate)
        test.power.didWake()
        await player.nextTrack()
        #expect(player.state == .paused && player.trackText == "03" && player.sleepPosition == nil)
        test.service.emit([reconnectedDrive(contents: .audioCD(test.table))])
        #expect(player.state == .ready && player.isShowingDiscSummary)
        try await player.shutdown()
    }

    @Test func aTrackChosenBeforePlayIsKeptButTheDiscTotalNeedsNothing() async throws {
        let test = try SleepFixture()
        let player = test.player
        try await test.sleep()
        #expect(player.sleepPosition == nil && player.isShowingDiscSummary)
        test.power.didWake()
        for _ in 0..<3 { await player.nextTrack() }
        #expect(player.trackText == "03" && player.state == .ready)
        try await test.sleep()
        #expect(player.sleepPosition?.state == .ready && player.sleepPosition?.frame == 20 * Disc.sampleRate)
        test.power.didWake()
        test.service.emit([])
        test.service.emit([reconnectedDrive(contents: .audioCD(test.table))])
        #expect(player.state == .ready && player.statusText == "CD DETECTED")
        #expect(player.trackText == "03" && player.timeText == "00:00" && !player.isShowingDiscSummary)
        #expect(test.opener.opens.isEmpty && test.prevention.activations == 0)
        try await player.shutdown()
    }

    @Test func theDriveThatSleptIsChosenAgainOverAnotherDrive() async throws {
        let other = opticalDrive(id: 2, media: OpticalMedia(
            id: 20, bsdName: "disk5", contents: .audioCD(try CDTableOfContents(data: tocFixture())),
            isMounted: false, isEjectable: true
        ))
        let test = try SleepFixture(otherDrive: other)
        let player = test.player
        #expect(player.selectedDriveID == 1)
        try await test.sleep(playingAt: 12 * Disc.sampleRate)
        test.power.didWake()
        test.service.emit([other])
        #expect(player.selectedDriveID == 2 && player.isShowingDiscSummary && player.sleepPosition != nil)
        test.service.emit([other, reconnectedDrive(id: 7, mediaID: 70, contents: .audioCD(test.table))])
        #expect(player.selectedDriveID == 7 && player.state == .paused)
        #expect(player.currentFrame == 12 * Disc.sampleRate)
        await player.togglePlayback()
        #expect(test.opener.opens.last == .init(mediaID: 70, driveID: 7, onMainThread: false))
        try await player.shutdown()
    }

    @Test func quittingWhileSleepWaitsStillAllowsSleep() async throws {
        let test = try SleepFixture()
        let player = test.player
        await player.togglePlayback()
        await test.playback.suspendStop()
        test.power.willSleep()
        try await waitUntil { await test.playback.stopIsWaiting() }
        let quit = Task { try await player.shutdown() }
        try await waitUntil { test.power.ended }
        await test.playback.resumeStop()
        try await quit.value
        try await waitUntil { test.power.acknowledged == 1 }
        #expect(!test.prevention.isActive && test.opener.discs.first?.isClosed == true)
        test.power.willSleep()
        #expect(test.power.acknowledged == 2)
    }

    @Test func powerMessagesAllowEverySleepExactlyOnce() async throws {
        let allowed = AllowedSleeps()
        let (stream, continuation) = AsyncStream.makeStream(of: SystemPowerEvent.self, bufferingPolicy: .unbounded)
        let messages = SystemPowerMessages(continuation: continuation) { allowed.record($0) }
        messages.handle(SystemPowerMessages.canSystemSleep, notificationID: 1)
        messages.handle(SystemPowerMessages.systemWillSleep, notificationID: 2)
        messages.handle(0xE000_0320, notificationID: 3)
        messages.handle(SystemPowerMessages.systemHasPoweredOn, notificationID: 4)
        #expect(allowed.ids == [1])
        var events = stream.makeAsyncIterator()
        guard case .willSleep(let acknowledge)? = await events.next() else {
            Issue.record("Expected the sleep to wait for its acknowledgement")
            return
        }
        #expect(allowed.ids == [1])
        acknowledge()
        acknowledge()
        #expect(allowed.ids == [1, 2])
        guard case .didWake? = await events.next() else {
            Issue.record("Expected the wake")
            return
        }
        continuation.finish()
        let end = await events.next()
        #expect(end == nil)
        messages.handle(SystemPowerMessages.systemWillSleep, notificationID: 5)
        #expect(allowed.ids == [1, 2, 5])
        do {
            let (unread, continuation) = AsyncStream.makeStream(of: SystemPowerEvent.self, bufferingPolicy: .unbounded)
            SystemPowerMessages(continuation: continuation) { allowed.record($0) }
                .handle(SystemPowerMessages.systemWillSleep, notificationID: 6)
            _ = unread
        }
        // A sleep that nobody read is allowed once its event is gone.
        #expect(allowed.ids == [1, 2, 5, 6])
    }

    @Test func theSystemMonitorStopsListeningWhenItsListenerEnds() async throws {
        let events = SystemPowerMonitor().events()
        let listener = Task {
            for await event in events {
                if case .willSleep(let acknowledge) = event { acknowledge() }
            }
            return true
        }
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        #expect(await listener.value)
    }
}
