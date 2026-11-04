import CDAudioCore
import Foundation
import Testing
@testable import CDKit

private enum OutputRateTestFailure: LocalizedError {
    case match, recovery
    var errorDescription: String? {
        switch self {
        case .match: "Cannot set native 44.1 kHz on External Headphones."
        case .recovery: "Cannot recover a previously changed output rate."
        }
    }
}

@MainActor
private final class RateTestOutputSelectionStore: OutputSelectionStore {
    var selectedID: OutputChoice.ID?
    func save(_ id: OutputChoice.ID) { selectedID = id }
}

extension OutputInfo {
    static func headphones(
        at sampleRate: Double, restoreRate: Double = 48_000, supportsSourceRate: Bool = true, hogOwner: Int32 = -1
    ) -> OutputInfo {
        OutputInfo(
            deviceID: 7, name: "External Headphones", sampleRate: sampleRate, hogOwner: hogOwner,
            supportsSourceRate: supportsSourceRate, isDefaultOutput: true, usesSpeakers: false, restoreRate: restoreRate
        )
    }
    static let speakers = OutputInfo(
        deviceID: 3, name: "MacBook Pro Speakers", sampleRate: 48_000, hogOwner: -1,
        supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: true, restoreRate: 48_000
    )

    /// The same output at another rate, as playback or the output-rate switch leaves it.
    func at(_ sampleRate: Double) -> OutputInfo {
        OutputInfo(
            deviceID: deviceID, name: name, sampleRate: sampleRate, hogOwner: hogOwner,
            supportsSourceRate: supportsSourceRate, isDefaultOutput: isDefaultOutput, usesSpeakers: usesSpeakers,
            isRunning: isRunning, outputDataSource: outputDataSource, restoreRate: restoreRate,
            uid: uid, transport: transport, outputChannels: outputChannels, terminalType: terminalType,
            converts: converts, streamLatencySeconds: streamLatencySeconds
        )
    }
}

/// Stands in for Core Audio's output-rate control: records each call, returns the configured outputs,
/// can hold a switch open while a test acts, and announces changes the way the HAL listeners do.
actor FakeOutputRateControl: OutputRateControl {
    enum Call: Equatable { case recover, match, restore, restoreChanged }

    private(set) var calls: [Call] = []
    /// The output each match or restore was asked to change.
    private(set) var rateTargets: [OutputTarget] = []
    /// The source format of each match, restore and discovery, in order.
    private(set) var formats: [AudioSourceFormat] = []
    private(set) var discoveries = 0
    private var scriptedDiscoveries: [[AudioOutputDevice]] = []
    private let matched: OutputInfo
    private let restored: OutputInfo
    private let onRestoreChanged: @Sendable () async throws -> Void
    private var discoveredOutputs: [AudioOutputDevice]
    private var discoveryFailure: (any Error)?
    private var failure: (any Error)?
    private var recoveryFailure: (any Error)?
    private var holdsMatch = false
    private var heldMatch: CheckedContinuation<Void, Never>?
    private var holdsRecovery = false
    private var heldRecovery: CheckedContinuation<Void, Never>?
    private let changeStream: AsyncStream<Void>
    private let changeContinuation: AsyncStream<Void>.Continuation

    init(
        matched: OutputInfo = .headphones(at: 44_100), restored: OutputInfo = .headphones(at: 48_000),
        discoveredOutputs: [AudioOutputDevice] = [],
        onRestoreChanged: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.matched = matched
        self.restored = restored
        self.discoveredOutputs = discoveredOutputs
        self.onRestoreChanged = onRestoreChanged
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        changeStream = stream
        changeContinuation = continuation
    }

    func recoverPendingRates() async throws {
        calls.append(.recover)
        if holdsRecovery { await withCheckedContinuation { heldRecovery = $0 } }
        if let recoveryFailure { throw recoveryFailure }
    }

    func matchSourceRate(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo {
        calls.append(.match)
        rateTargets.append(target)
        formats.append(format)
        if holdsMatch { await withCheckedContinuation { heldMatch = $0 } }
        if let failure { throw failure }
        return matched
    }
    func restoreRate(on target: OutputTarget, format: AudioSourceFormat) async throws -> OutputInfo {
        calls.append(.restore)
        rateTargets.append(target)
        formats.append(format)
        if let failure { throw failure }
        return restored
    }
    func restoreChangedRates() async throws {
        calls.append(.restoreChanged)
        try await onRestoreChanged()
    }
    func discoverOutputs(format: AudioSourceFormat) async throws -> [AudioOutputDevice] {
        discoveries += 1
        formats.append(format)
        if let discoveryFailure { throw discoveryFailure }
        if !scriptedDiscoveries.isEmpty { discoveredOutputs = scriptedDiscoveries.removeFirst() }
        return discoveredOutputs
    }
    nonisolated func changes() -> AsyncStream<Void> { changeStream }

    /// A rate, device or default-output change, such as one made in Audio MIDI Setup.
    nonisolated func announceChange() { changeContinuation.yield() }
    func fail(with error: any Error) { failure = error }
    func failDiscovery(with error: any Error) { discoveryFailure = error }
    func setDiscoveredOutputs(_ outputs: [AudioOutputDevice]) { discoveredOutputs = outputs }
    /// Results for the next discoveries in order, as Core Audio reports a device leaving in stages;
    /// the last one stays.
    func scriptDiscoveries(_ outputs: [[AudioOutputDevice]]) { scriptedDiscoveries = outputs }
    func failRecovery(with error: any Error) { recoveryFailure = error }
    func holdRecovery() { holdsRecovery = true }
    func recoveryIsHeld() -> Bool { heldRecovery != nil }
    func releaseRecovery() {
        holdsRecovery = false
        heldRecovery?.resume()
        heldRecovery = nil
    }
    func holdMatch() { holdsMatch = true }
    func matchIsHeld() -> Bool { heldMatch != nil }
    func releaseMatch() {
        holdsMatch = false
        heldMatch?.resume()
        heldMatch = nil
    }
}

@MainActor
private func makePlayer(output: OutputInfo, control: FakeOutputRateControl) async -> (PlayerModel, FakeEngine) {
    let engine = FakeEngine()
    await engine.setOutput(output)
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, outputRateControl: control,
        outputSelectionStore: RateTestOutputSelectionStore()
    )
    return (player, engine)
}

@Test @MainActor func outputRateSwitchMatchesTheSourceThenRestoresTheReplacedRate() async throws {
    let control = FakeOutputRateControl()
    let (player, _) = await makePlayer(output: .headphones(at: 48_000), control: control)
    #expect(!player.showsOutputRateSwitch)
    await player.inspectOutput()
    #expect(player.showsOutputRateSwitch && player.outputRateSymbol == "headphones")
    #expect(!player.outputMatchesSource && player.outputRateSwitchEnabled)
    #expect(player.outputRateLabel == "External Headphones at 48 kHz. Click to match the 44.1 kHz source.")

    await player.toggleOutputRate()
    #expect(player.output == .headphones(at: 44_100))
    #expect(player.outputMatchesSource && player.outputRateSwitchEnabled && !player.isChangingOutputRate)
    #expect(player.outputRateLabel == "External Headphones at 44.1 kHz, matching the source. Click to restore 48 kHz.")

    await player.toggleOutputRate()
    #expect(player.output == .headphones(at: 48_000))
    #expect(!player.outputMatchesSource && player.outputRateSwitchEnabled)
    #expect(await control.calls == [.match, .restore])
    #expect(player.errorDetail == nil && player.state == .ready)
}

@Test @MainActor func outputRateSwitchIsLitAndLockedDuringPlaybackThenFollowsTheRestoredRate() async throws {
    let control = FakeOutputRateControl()
    let (player, _) = await makePlayer(output: .headphones(at: 48_000), control: control)
    player.startOutputMonitoring()
    await player.inspectOutput()
    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(player.outputMatchesSource && !player.outputRateSwitchEnabled)
    #expect(player.outputRateLabel == "External Headphones at 44.1 kHz, matching the source during playback.")
    await player.toggleOutputRate()
    #expect(await control.calls == [.recover])

    // Pause puts back the rate playback replaced; Core Audio announces it and the switch dims.
    await player.togglePlayback()
    #expect(player.state == .paused)
    control.announceChange()
    try await waitUntil { !player.outputMatchesSource }
    #expect(player.outputRateSwitchEnabled)
    try await player.shutdown()
    let calls = await control.calls
    #expect(calls.first == .recover && calls.last == .restoreChanged)
    #expect(calls.filter { $0 == .recover }.count >= 2)
}

@Test @MainActor func outputRateSwitchIsUnavailableWhenItCannotChangeTheRate() async throws {
    let otherApp = ProcessInfo.processInfo.processIdentifier + 1
    let cases: [(output: OutputInfo, lit: Bool, label: String)] = [
        // With no wired output able to play, the selection falls back to System Default.
        (.headphones(at: 48_000, supportsSourceRate: false), false,
         "External Headphones at 48 kHz, System Default, best effort. It cannot match the 44.1 kHz source."),
        (.headphones(at: 48_000, hogOwner: otherApp), false,
         "External Headphones at 48 kHz. Another app has exclusive use of it."),
        (.headphones(at: 44_100, restoreRate: 0), true,
         "External Headphones at 44.1 kHz, matching the source."),
    ]
    for test in cases {
        let control = FakeOutputRateControl()
        let (player, _) = await makePlayer(output: test.output, control: control)
        await player.inspectOutput()
        #expect(player.showsOutputRateSwitch && player.outputMatchesSource == test.lit)
        #expect(!player.outputRateSwitchEnabled)
        #expect(player.outputRateLabel == test.label)
        await player.toggleOutputRate()
        #expect(await control.calls.isEmpty)
    }
}

@Test @MainActor func outputRateSwitchShowsAWaveformForSpeakersAndIgnoresThePlayersOwnExclusiveUse() async throws {
    let ownExclusiveUse = OutputInfo(
        deviceID: 3, name: "MacBook Pro Speakers", sampleRate: 48_000,
        hogOwner: ProcessInfo.processInfo.processIdentifier, supportsSourceRate: true,
        isDefaultOutput: true, usesSpeakers: true, restoreRate: 48_000
    )
    let (player, _) = await makePlayer(output: ownExclusiveUse, control: FakeOutputRateControl())
    await player.inspectOutput()
    #expect(player.outputRateSymbol == "speaker.wave.2")
    #expect(player.outputRateSwitchEnabled)
    #expect(player.outputRateLabel == "MacBook Pro Speakers at 48 kHz. Click to match the 44.1 kHz source.")
}

@Test @MainActor func playWaitsForAnOutputRateSwitchInProgress() async throws {
    let control = FakeOutputRateControl()
    await control.holdMatch()
    let (player, engine) = await makePlayer(output: .headphones(at: 48_000), control: control)
    await player.inspectOutput()
    let switching = Task { await player.toggleOutputRate() }
    try await waitUntil { await control.matchIsHeld() }
    #expect(player.isChangingOutputRate && !player.outputRateSwitchEnabled)

    let play = Task { await player.togglePlayback() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await engine.starts.isEmpty)
    #expect(player.state == .ready)
    await control.releaseMatch()
    await switching.value
    await play.value
    #expect(await engine.starts == [0])
    #expect(player.state == .playing && player.outputMatchesSource && !player.isChangingOutputRate)
    #expect(await control.calls == [.match])
}

@Test @MainActor func playbackWaitsForStartupRateRecovery() async throws {
    let control = FakeOutputRateControl()
    await control.holdRecovery()
    let (player, engine) = await makePlayer(output: .headphones(at: 48_000), control: control)
    player.startOutputMonitoring()
    try await waitUntil { await control.recoveryIsHeld() }
    #expect(player.isRecoveringOutputRates && !player.controlsEnabled)

    let playback = Task { await player.togglePlayback() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await engine.starts.isEmpty)
    #expect(player.state == .ready)

    await control.releaseRecovery()
    await playback.value
    #expect(await engine.starts == [0])
    #expect(player.state == .playing && !player.isRecoveringOutputRates)
    try await player.shutdown()
    #expect(await control.calls.first == .recover)
}

@Test @MainActor func startupRateRecoveryFailureIsVisibleAsAnAudioError() async throws {
    let control = FakeOutputRateControl()
    await control.failRecovery(with: OutputRateTestFailure.recovery)
    let (player, _) = await makePlayer(output: .headphones(at: 48_000), control: control)
    player.startOutputMonitoring()
    await player.inspectOutput()

    #expect(player.state == .failed)
    #expect(player.statusText == "[ERR] Audio error")
    #expect(player.errorDetail == "Cannot recover a previously changed output rate.")
    #expect(!player.isRecoveringOutputRates)
    try await player.shutdown()
}

@Test @MainActor func outputChangesRefreshTheSwitchAndAnUnreadableOutputHidesIt() async throws {
    let control = FakeOutputRateControl()
    let (player, engine) = await makePlayer(output: .headphones(at: 48_000), control: control)
    player.startOutputMonitoring()
    await player.inspectOutput()
    #expect(!player.outputMatchesSource)

    // Another app or Audio MIDI Setup sets 44.1 kHz.
    await engine.setOutput(.headphones(at: 44_100))
    control.announceChange()
    try await waitUntil { player.outputMatchesSource }

    // The headphones are unplugged and the speakers take over.
    await engine.setOutput(.speakers)
    control.announceChange()
    try await waitUntil { player.outputRateSymbol == "speaker.wave.2" }
    #expect(!player.outputMatchesSource)

    await engine.failInspect(true)
    control.announceChange()
    try await waitUntil { !player.showsOutputRateSwitch }
    #expect(player.errorDetail == nil && player.state == .ready && !player.statusIsError)

    await engine.failInspect(false)
    control.announceChange()
    try await waitUntil { player.showsOutputRateSwitch }
    try await player.shutdown()
    let calls = await control.calls
    #expect(calls.first == .recover && calls.last == .restoreChanged)
}

@Test @MainActor func changingTheOutputWhilePlayingPausesAtTheCurrentFrameAndPlayResumesThere() async throws {
    let control = FakeOutputRateControl()
    let (player, engine) = await makePlayer(output: .headphones(at: 48_000), control: control)
    player.startOutputMonitoring()
    await player.inspectOutput()
    await player.togglePlayback()
    let frame = 12 * Disc.sampleRate
    await engine.setFrame(frame)
    await player.refreshPlayback()

    await engine.setOutput(.speakers)
    control.announceChange()
    try await waitUntil { player.state == .paused }
    try await waitUntil { player.controlsEnabled }

    #expect(player.currentFrame == frame)
    #expect(player.output == .speakers)
    #expect(!player.statusIsError && player.errorDetail == nil)

    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(await engine.starts == [0, frame])
    try await player.shutdown()
}

@Test @MainActor func pluggingHeadphonesWhilePlayingThroughSpeakersPausesAtTheCurrentFrame() async throws {
    let control = FakeOutputRateControl()
    let speakers = OutputInfo(
        deviceID: 3, name: "MacBook Pro Audio", sampleRate: 48_000, hogOwner: -1,
        supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: true, outputDataSource: 1
    )
    let headphones = OutputInfo(
        deviceID: 3, name: "MacBook Pro Audio", sampleRate: 44_100, hogOwner: -1,
        supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: true, outputDataSource: 2
    )
    let (player, engine) = await makePlayer(output: speakers, control: control)
    player.startOutputMonitoring()
    await player.inspectOutput()
    await player.togglePlayback()
    let frame = 9 * Disc.sampleRate
    await engine.setFrame(frame)
    await player.refreshPlayback()

    await engine.setOutput(headphones)
    control.announceChange()
    try await waitUntil { player.state == .paused }

    #expect(player.currentFrame == frame)
    #expect(player.output == headphones)
    #expect(!player.statusIsError && player.errorDetail == nil)
    try await player.shutdown()
}

@Test @MainActor func coreAudioRouteChangeErrorPausesWhileUnrelatedAudioErrorsStillFail() async throws {
    let control = FakeOutputRateControl()
    let (player, engine) = await makePlayer(output: .headphones(at: 48_000), control: control)
    await player.togglePlayback()
    let frame = 8 * Disc.sampleRate
    await engine.setFrame(frame)
    await engine.failSnapshot(with: AudioPlaybackError(CDError(
        result: CD_CONFIGURATION_CHANGED, message: "The audio route changed."
    )))

    await player.refreshPlayback()

    #expect(player.state == .paused)
    #expect(player.currentFrame == frame)
    #expect(!player.statusIsError && player.errorDetail == nil)
    try await player.shutdown()

    let (failedPlayer, failedEngine) = await makePlayer(output: .headphones(at: 48_000), control: control)
    await failedPlayer.togglePlayback()
    await failedEngine.failSnapshot()
    await failedPlayer.refreshPlayback()
    #expect(failedPlayer.state == .failed)
    #expect(failedPlayer.statusText == "[ERR] Audio error")
    try await failedPlayer.shutdown()
}

@Test @MainActor func lostBuiltInOutputInspectionPausesInsteadOfReportingAnAudioError() async throws {
    let control = FakeOutputRateControl()
    let (player, engine) = await makePlayer(output: .headphones(at: 48_000), control: control)
    player.startOutputMonitoring()
    await player.inspectOutput()
    await player.togglePlayback()
    let frame = 5 * Disc.sampleRate
    await engine.setFrame(frame)
    await player.refreshPlayback()
    await engine.failInspect(with: AudioPlaybackError(CDError(
        result: CD_NO_BUILT_IN_OUTPUT, message: "No built-in output is available."
    )))

    control.announceChange()
    try await waitUntil { player.state == .paused }

    #expect(player.currentFrame == frame)
    #expect(player.output == nil)
    #expect(!player.statusIsError && player.errorDetail == nil)
    try await player.shutdown()
}

@Test @MainActor func aFailedOutputRateSwitchShowsAnAudioErrorWithoutStoppingThePlayer() async throws {
    let control = FakeOutputRateControl()
    await control.fail(with: OutputRateTestFailure.match)
    let (player, _) = await makePlayer(output: .headphones(at: 48_000), control: control)
    await player.inspectOutput()
    await player.nextTrack()
    let track = player.trackText
    #expect(!player.isShowingDiscSummary)

    await player.toggleOutputRate()
    #expect(player.statusText == "[ERR] Audio error")
    #expect(player.errorDetail == "Cannot set native 44.1 kHz on External Headphones.")
    #expect(player.state == .ready && player.trackText == track && !player.isShowingDiscSummary)
    #expect(!player.outputMatchesSource && player.outputRateSwitchEnabled && !player.isChangingOutputRate)
    #expect(player.controlsEnabled)

    await player.nextTrack()
    #expect(player.errorDetail == nil && !player.statusIsError)
}

@Test @MainActor func quitWaitsForAnOutputRateSwitchThenRestoresTheRatesItChanged() async throws {
    let control = FakeOutputRateControl()
    await control.holdMatch()
    let (player, _) = await makePlayer(output: .headphones(at: 48_000), control: control)
    await player.inspectOutput()
    let switching = Task { await player.toggleOutputRate() }
    try await waitUntil { await control.matchIsHeld() }

    let quit = Task { try await player.shutdown() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await control.calls == [.match])
    await control.releaseMatch()
    try await quit.value
    await switching.value
    #expect(await control.calls == [.match, .restoreChanged])
    #expect(!player.isChangingOutputRate && !player.outputRateSwitchEnabled)
}

@Test @MainActor func outputChecksAndRateSwitchesUseTheDiscSourceFormat() async throws {
    let control = FakeOutputRateControl()
    let (player, engine) = await makePlayer(output: .headphones(at: 48_000), control: control)
    #expect(player.sourceFormat == .compactDisc)
    await player.inspectOutput()
    await player.toggleOutputRate()
    await player.toggleOutputRate()
    let calls = await control.calls
    #expect(calls.contains(.match) && calls.contains(.restore))
    let formats = await control.formats
    #expect(formats.count >= 3 && formats.allSatisfy { $0 == .compactDisc })
    let inspected = await engine.inspectFormats
    #expect(!inspected.isEmpty && inspected.allSatisfy { $0 == .compactDisc })
    try await player.shutdown()
}
