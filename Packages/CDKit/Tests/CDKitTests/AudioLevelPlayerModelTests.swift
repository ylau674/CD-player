import Foundation
import Testing
@testable import CDKit

@Test @MainActor func audioLevelsStartClosedAndFollowTheLatencyAdjustedDisplayPosition() async throws {
    let engine = FakeEngine()
    let source = FakeAudioLevelSource()
    let clock = FakeAudioClock()
    await engine.setOutput(OutputInfo(
        deviceID: 1, name: "Test HDMI", sampleRate: 44_100, hogOwner: -1,
        supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: false,
        transport: .hdmi, streamLatencySeconds: 0.1
    ))
    let model = PlayerModel.offline(
        engine: engine, audioLevelSource: source, audioClock: { clock.now }, automaticallyMonitor: false
    )
    #expect(!model.showsAudioLevels)

    await model.togglePlayback()
    await engine.setFrame(100_000)
    await model.refreshPlayback()
    let displayFrame: UInt64 = 100_000 - 4_410
    source.set(AudioLevelPeaks(leftPeak: 3_277, rightPeak: 1_000), at: displayFrame)
    model.audioLevelsWindowVisibilityDidChange(true)
    model.toggleAudioLevels()
    model.audioLevelsDidFinishShowing()

    #expect(model.showsAudioLevels)
    #expect(source.requests.last == .init(fromFrame: displayFrame, throughFrame: displayFrame))
    #expect(model.audioLevelReading.left.litSegments == 6)
    #expect(model.audioLevelReading.right.litSegments == 3)

    clock.advance(by: .milliseconds(100))
    model.updateAudioLevels()
    #expect(source.requests.last == .init(
        fromFrame: displayFrame, throughFrame: displayFrame + 4_410
    ))

    clock.advance(by: .milliseconds(300))
    model.updateAudioLevels()
    #expect(source.requests.last == .init(
        fromFrame: displayFrame + 4_410, throughFrame: displayFrame + 8_820
    ))

    await model.togglePlayback()
    #expect(model.state == .paused)
    #expect(model.audioLevelReading.isDark)
    let requestCount = source.requests.count
    model.updateAudioLevels()
    #expect(source.requests.count == requestCount)
    model.toggleAudioLevels()
    #expect(!model.showsAudioLevels)
    try await model.shutdown()
}

@Test @MainActor func audioLevelMetersRefreshOnlyWhileFullyShownAndPlaying() async throws {
    let engine = FakeEngine()
    let source = FakeAudioLevelSource()
    let model = PlayerModel.offline(
        engine: engine, audioLevelSource: source, automaticallyMonitor: false
    )
    source.set(AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768), at: 0)
    model.audioLevelsWindowVisibilityDidChange(true)
    #expect(!model.audioLevelsAreLive)
    model.toggleAudioLevels()
    model.audioLevelsDidFinishShowing()
    #expect(!model.audioLevelsAreLive)
    #expect(model.refreshAudioLevels().isDark)

    await model.togglePlayback()
    await engine.setBuffering(false)
    await model.refreshPlayback()
    #expect(model.audioLevelsAreLive)
    let reading = model.refreshAudioLevels()
    #expect(reading.left.litSegments == 20)
    #expect(reading.right.litSegments == 20)
    #expect(reading == model.audioLevelReading)

    await model.togglePlayback()
    #expect(model.state == .paused)
    #expect(!model.audioLevelsAreLive)
    #expect(model.audioLevelReading.isDark)
    #expect(model.refreshAudioLevels().isDark)

    await model.togglePlayback()
    await engine.setBuffering(false)
    await model.refreshPlayback()
    #expect(model.audioLevelsAreLive)
    model.toggleAudioLevels()
    #expect(!model.audioLevelsAreLive)
    try await model.shutdown()
}

/// The window reports the meters fully shown once it has finished extending. Until then, and from the
/// moment they are hidden, the meters stay dark and read nothing from the source.
@Test @MainActor func audioLevelsMeasureOnlyOnceFullyShown() async throws {
    let engine = FakeEngine()
    let source = FakeAudioLevelSource()
    let clock = FakeAudioClock()
    let model = PlayerModel.offline(
        engine: engine, audioLevelSource: source, audioClock: { clock.now }, automaticallyMonitor: false
    )
    source.set(AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768), at: 0)
    model.audioLevelsWindowVisibilityDidChange(true)
    await model.togglePlayback()
    await engine.setBuffering(false)
    await model.refreshPlayback()
    #expect(model.state == .playing)
    model.audioLevelsDidFinishShowing()
    #expect(!model.audioLevelsAreFullyShown)

    model.toggleAudioLevels()
    #expect(model.showsAudioLevels)
    #expect(!model.audioLevelsAreFullyShown)
    #expect(!model.audioLevelsAreLive)
    #expect(model.refreshAudioLevels().isDark)
    model.updateAudioLevels()
    #expect(model.audioLevelReading.isDark)
    #expect(source.requests.isEmpty)

    model.audioLevelsDidFinishShowing()
    #expect(model.audioLevelsAreFullyShown)
    #expect(model.audioLevelsAreLive)
    #expect(source.requests == [.init(fromFrame: 0, throughFrame: 0)])
    #expect(model.audioLevelReading.left.litSegments == 20)
    #expect(model.audioLevelReading.right.litSegments == 20)
    clock.advance(by: .milliseconds(100))
    model.audioLevelsDidFinishShowing()
    #expect(source.requests.count == 1)

    model.toggleAudioLevels()
    #expect(!model.showsAudioLevels)
    #expect(!model.audioLevelsAreFullyShown)
    #expect(!model.audioLevelsAreLive)
    #expect(model.audioLevelReading.isDark)
    #expect(model.refreshAudioLevels().isDark)
    model.updateAudioLevels()
    await model.refreshPlayback()
    #expect(source.requests.count == 1)
    // A shrink cannot report, and a show replaced by this hide is ignored.
    model.audioLevelsDidFinishShowing()
    #expect(!model.audioLevelsAreFullyShown)
    #expect(model.refreshAudioLevels().isDark)
    #expect(source.requests.count == 1)

    model.toggleAudioLevels()
    #expect(!model.audioLevelsAreFullyShown)
    #expect(model.refreshAudioLevels().isDark)
    #expect(source.requests.count == 1)
    model.audioLevelsDidFinishShowing()
    #expect(model.audioLevelsAreLive)
    #expect(source.requests.count == 2)
    #expect(model.audioLevelReading.left.litSegments == 20)
    try await model.shutdown()
}

@Test @MainActor func audioLevelsStopReadingWhenTheWindowIsInvisible() async throws {
    let engine = FakeEngine()
    let source = FakeAudioLevelSource()
    let model = PlayerModel.offline(
        engine: engine, audioLevelSource: source, automaticallyMonitor: false
    )
    source.set(AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768), at: 0)
    await model.togglePlayback()
    await engine.setBuffering(false)
    await model.refreshPlayback()
    model.toggleAudioLevels()
    model.audioLevelsDidFinishShowing()
    #expect(source.requests.isEmpty)

    model.audioLevelsWindowVisibilityDidChange(true)
    #expect(model.audioLevelsAreLive)
    #expect(source.requests.count == 1)
    #expect(!model.audioLevelReading.isDark)

    model.audioLevelsWindowVisibilityDidChange(false)
    #expect(!model.audioLevelsAreLive)
    #expect(model.audioLevelReading.isDark)
    model.refreshAudioLevels()
    model.updateAudioLevels()
    #expect(source.requests.count == 1)

    model.audioLevelsWindowVisibilityDidChange(true)
    #expect(model.audioLevelsAreLive)
    #expect(source.requests.count == 2)
    #expect(!model.audioLevelReading.isDark)
    try await model.shutdown()
}

@Test @MainActor func audioLevelsCanBeShownWithoutADisc() async throws {
    let model = PlayerModel.offline(
        engine: FakeEngine(), automaticallyMonitor: false, opticalService: FakeOpticalService()
    )
    #expect(model.disc == nil)
    #expect(!model.controlsEnabled)
    model.toggleAudioLevels()
    #expect(model.showsAudioLevels)
    model.toggleAudioLevels()
    #expect(!model.showsAudioLevels)
    try await model.shutdown()
}

@Test @MainActor func audioLevelsStayDarkAfterStopAndEject() async throws {
    let engine = FakeEngine()
    let source = FakeAudioLevelSource()
    let model = PlayerModel.offline(
        engine: engine, audioLevelSource: source, automaticallyMonitor: false
    )
    source.set(AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768), at: 0)
    model.audioLevelsWindowVisibilityDidChange(true)
    await model.togglePlayback()
    await engine.setBuffering(false)
    await model.refreshPlayback()
    model.toggleAudioLevels()
    model.audioLevelsDidFinishShowing()
    #expect(!model.audioLevelReading.isDark)
    let readsBeforeStop = source.requests.count

    await model.stopOrEject()
    #expect(model.state == .ready)
    #expect(model.audioLevelReading.isDark)
    model.refreshAudioLevels()
    #expect(source.requests.count == readsBeforeStop)

    await model.togglePlayback()
    await engine.setBuffering(false)
    await model.refreshPlayback()
    model.updateAudioLevels()
    #expect(!model.audioLevelReading.isDark)
    let readsBeforeEject = source.requests.count

    await model.eject()
    #expect(model.state == .empty)
    #expect(model.disc == nil)
    #expect(model.audioLevelReading.isDark)
    model.refreshAudioLevels()
    #expect(source.requests.count == readsBeforeEject)
    try await model.shutdown()
}

@Test @MainActor func audioLevelsStayDarkDuringBufferingAndHDMILeadIn() async throws {
    let engine = FakeEngine()
    let source = FakeAudioLevelSource()
    let model = PlayerModel.offline(
        engine: engine, audioLevelSource: source, automaticallyMonitor: false
    )
    source.set(AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768), at: 0)
    model.audioLevelsWindowVisibilityDidChange(true)
    await engine.setLeadIn(true)

    await model.togglePlayback()
    model.toggleAudioLevels()
    model.audioLevelsDidFinishShowing()
    model.updateAudioLevels()
    #expect(model.audioLevelReading.isDark)
    #expect(source.requests.isEmpty)

    await engine.setBuffering(false)
    await model.refreshPlayback()
    model.updateAudioLevels()
    #expect(model.audioLevelReading.isDark)
    #expect(source.requests.isEmpty)

    await engine.setLeadIn(false)
    await model.refreshPlayback()
    model.updateAudioLevels()
    #expect(!model.audioLevelReading.isDark)
    #expect(source.requests.last == .init(fromFrame: 0, throughFrame: 0))
    try await model.shutdown()
}

@Test @MainActor func audioLevelsResetAtTrackChangesAndSeeks() async throws {
    let engine = FakeEngine()
    let source = FakeAudioLevelSource()
    let clock = FakeAudioClock()
    let model = PlayerModel.offline(
        engine: engine, audioLevelSource: source, audioClock: { clock.now }, automaticallyMonitor: false
    )
    model.audioLevelsWindowVisibilityDidChange(true)
    await model.togglePlayback()
    await engine.setBuffering(false)
    await model.refreshPlayback()
    source.set(AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768), at: 0)
    model.toggleAudioLevels()
    model.audioLevelsDidFinishShowing()
    #expect(model.audioLevelReading.left.litSegments == 20)

    let secondTrack = try #require(Disc.demo.tracks.dropFirst().first)
    await model.nextTrack()
    await engine.setFrame(secondTrack.startFrame)
    await engine.setBuffering(false)
    await model.refreshPlayback()
    source.set(AudioLevelPeaks(leftPeak: 3_277, rightPeak: 3_277), at: secondTrack.startFrame)
    model.updateAudioLevels()
    #expect(source.requests.last == .init(
        fromFrame: secondTrack.startFrame, throughFrame: secondTrack.startFrame
    ))
    #expect(model.audioLevelReading.left.litSegments == 6)

    await model.scan(.forward)
    let seekFrame = secondTrack.startFrame + 10 * Disc.demo.format.sampleRate
    await engine.setFrame(seekFrame)
    await engine.setBuffering(false)
    await model.refreshPlayback()
    source.set(AudioLevelPeaks(leftPeak: 1_000, rightPeak: 1_000), at: seekFrame)
    model.updateAudioLevels()
    #expect(source.requests.last == .init(fromFrame: seekFrame, throughFrame: seekFrame))
    #expect(model.audioLevelReading.left.litSegments == 3)
    try await model.shutdown()
}
