import Combine
import Foundation
import Testing
@testable import CDKit

private enum TestFailure: LocalizedError {
    case start, snapshot, cleanup, restore, inspect
    var errorDescription: String? {
        switch self {
        case .start: return "Exclusive output is unavailable."
        case .snapshot: return "Audio buffer underrun."
        case .cleanup: return "Could not restore the output."
        case .restore: return "Could not restore the original sample rate."
        case .inspect: return "Cannot read the built-in output."
        }
    }
}

private func listedOutput(
    _ uid: String, _ deviceID: UInt32, _ name: String, _ transport: OutputTransport,
    supportsSourceRate: Bool = true, stereo: Bool = true, isDefault: Bool = false, usesSpeakers: Bool = false
) -> AudioOutputDevice {
    AudioOutputDevice(
        uid: uid, deviceID: deviceID, name: name, transport: transport, sampleRate: 48_000, hogOwner: -1,
        supportsSourceRate: supportsSourceRate, hasStereoOutput: stereo, isDefaultOutput: isDefault,
        terminalType: usesSpeakers ? 1 : 0, usesSpeakers: usesSpeakers, restoreRate: 48_000
    )
}

/// Records how many times playback had stopped when quit restored the output sample rates.
private actor OutputRateRestoreSpy {
    private(set) var stopsSeen: [Int] = []
    private var fails = false

    func fail() { fails = true }
    func restore(after engine: FakeEngine) async throws {
        stopsSeen.append(await engine.stops)
        if fails { throw TestFailure.restore }
    }
}

actor FakeEngine: PlaybackEngine {
    private let totalFrames: UInt64
    private var frame: UInt64 = 0
    private var startFails = false
    private var snapshotFails = false
    private var snapshotFailure: (any Error)?
    private var buffering = false
    private var leadIn = false
    private var concealedSectors: UInt64 = 0
    private var unverified = false
    private var hdcdStatus = HDCDPlaybackStatus.notApplicable
    private var hdcdDecoded = false
    private var physicalOutputBits: UInt32 = 0
    private var cleanupFails = false
    private var delayedStart: CheckedContinuation<Void, Never>?
    private var delayStart = false
    private var delayedSnapshot: CheckedContinuation<PlaybackSnapshot, any Error>?
    private var delaySnapshot = false
    private var delayedStops: [CheckedContinuation<Void, Never>] = []
    private var delayStop = false
    private var inspectionFailure: (any Error)?
    private var targetInspectionFailures: [OutputTarget: any Error] = [:]
    private var output = OutputInfo(
        deviceID: 1, name: "Test built-in output", sampleRate: 44_100, hogOwner: -1,
        supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: false
    )
    private var inspectFails = false
    private(set) var starts: [UInt64] = []
    private(set) var startTargets: [OutputTarget] = []
    private(set) var hdcdSettings: [Bool] = []
    private(set) var inspectTargets: [OutputTarget] = []
    private(set) var inspectFormats: [AudioSourceFormat] = []
    /// Each stop and start in order, so a test can check playback stopped before it moved.
    private(set) var calls: [String] = []
    private var targetOutputs: [OutputTarget: OutputInfo] = [:]
    private var startFailure: (any Error)?
    private(set) var stops = 0
    private(set) var sleepStops = 0
    private var defersOutputRestoreBeforeSleep = false

    init(totalFrames: UInt64 = Disc.demo.totalFrames) { self.totalFrames = totalFrames }

    func inspectOutput(on target: OutputTarget, format: AudioSourceFormat) throws -> OutputInfo {
        inspectTargets.append(target)
        inspectFormats.append(format)
        if let failure = targetInspectionFailures[target] { throw failure }
        if let inspectionFailure { throw inspectionFailure }
        if inspectFails { throw TestFailure.inspect }
        return targetOutputs[target] ?? output
    }
    /// Playback always runs the output at the source's 44.1 kHz.
    func start(at frame: UInt64, on target: OutputTarget) async throws -> OutputInfo {
        starts.append(frame)
        startTargets.append(target)
        calls.append("start \(frame) \(target)")
        if delayStart { await withCheckedContinuation { delayedStart = $0 } }
        if let startFailure { throw startFailure }
        if startFails { throw TestFailure.start }
        self.frame = frame
        concealedSectors = 0
        unverified = false
        return (targetOutputs[target] ?? output).at(44_100)
    }
    func start(at frame: UInt64, on target: OutputTarget, decodeHDCD: Bool) async throws -> OutputInfo {
        hdcdSettings.append(decodeHDCD)
        return try await start(at: frame, on: target)
    }
    func snapshot() async throws -> PlaybackSnapshot {
        if let snapshotFailure { throw snapshotFailure }
        if snapshotFails { throw TestFailure.snapshot }
        if delaySnapshot {
            return try await withCheckedThrowingContinuation { delayedSnapshot = $0 }
        }
        return currentSnapshot()
    }
    func stop() async throws -> PlaybackSnapshot {
        stops += 1
        calls.append("stop")
        if delayStop { await withCheckedContinuation { delayedStops.append($0) } }
        if cleanupFails { throw TestFailure.cleanup }
        return currentSnapshot()
    }
    /// Counts as a stop; with `deferOutputRestoreBeforeSleep` the output's restore is left for wake,
    /// as when macOS holds an output change once sleep has begun.
    func stopBeforeSleep() async throws -> PlaybackSnapshot {
        sleepStops += 1
        let snapshot = try await stop()
        guard defersOutputRestoreBeforeSleep else { return snapshot }
        return PlaybackSnapshot(
            currentFrame: snapshot.currentFrame, bufferedFrames: snapshot.bufferedFrames,
            buffering: snapshot.buffering, leadIn: snapshot.leadIn, finished: snapshot.finished,
            concealedSectors: snapshot.concealedSectors, unverified: snapshot.unverified,
            outputRestorePending: true
        )
    }
    func deferOutputRestoreBeforeSleep() { defersOutputRestoreBeforeSleep = true }
    func setFrame(_ frame: UInt64) { self.frame = frame }
    func setOutput(_ output: OutputInfo) { self.output = output }
    func setOutput(_ output: OutputInfo, on target: OutputTarget) { targetOutputs[target] = output }
    func failStart(with error: (any Error)?) { startFailure = error }
    func clearSnapshotFailure() { snapshotFailure = nil }
    func failInspect(_ fail: Bool) { inspectFails = fail }
    func failInspect(with error: any Error) { inspectionFailure = error }
    func failInspect(on target: OutputTarget, with error: any Error) {
        targetInspectionFailures[target] = error
    }
    func setBuffering(_ buffering: Bool) { self.buffering = buffering }
    func setLeadIn(_ leadIn: Bool) { self.leadIn = leadIn }
    func setQuality(concealedSectors: UInt64, unverified: Bool) {
        self.concealedSectors = concealedSectors
        self.unverified = unverified
    }
    func setHDCD(status: HDCDPlaybackStatus, decoded: Bool = false, physicalOutputBits: UInt32 = 0) {
        hdcdStatus = status
        hdcdDecoded = decoded
        self.physicalOutputBits = physicalOutputBits
    }
    func failStart(_ fail: Bool) { startFails = fail }
    func failSnapshot() { snapshotFails = true }
    func failSnapshot(with error: any Error) { snapshotFailure = error }
    func failCleanup() { cleanupFails = true }
    func suspendStart() { delayStart = true }
    func startIsWaiting() -> Bool { delayedStart != nil }
    func resumeStart() {
        delayStart = false
        delayedStart?.resume()
        delayedStart = nil
    }
    func suspendSnapshot() { delaySnapshot = true }
    func suspendStop() { delayStop = true }
    func stopIsWaiting() -> Bool { !delayedStops.isEmpty }
    func resumeStop() {
        delayStop = false
        let waiting = delayedStops
        delayedStops.removeAll()
        for stop in waiting { stop.resume() }
    }
    func snapshotIsWaiting() -> Bool { delayedSnapshot != nil }
    func resumeSnapshot(at frame: UInt64) {
        delayedSnapshot?.resume(returning: PlaybackSnapshot(currentFrame: frame))
        delayedSnapshot = nil
        delaySnapshot = false
    }
    private func currentSnapshot() -> PlaybackSnapshot {
        PlaybackSnapshot(
            currentFrame: frame, bufferedFrames: 100, buffering: buffering, leadIn: leadIn,
            finished: frame == totalFrames,
            concealedSectors: concealedSectors, unverified: unverified,
            hdcdStatus: hdcdStatus, hdcdDecoded: hdcdDecoded, physicalOutputBits: physicalOutputBits
        )
    }
}

@Test @MainActor func initialDisplayAndDemoGeometry() {
    let model = PlayerModel.offline(engine: FakeEngine(), automaticallyMonitor: false)
    #expect(model.state == .ready)
    #expect(!model.showsAudioLevels)
    #expect(!model.audioLevelsAreFullyShown)
    #expect(model.outputChoices == [
        OutputChoice(id: .device(uid: "unavailable"), name: "No wired audio output",
                     connection: "Unavailable", isEnabled: false, disabledReason: "No output is available."),
        OutputChoice(id: .systemDefault, name: "", connection: "", isEnabled: false,
                     disabledReason: "macOS has no default output.")
    ])
    #expect(model.outputChoices[1].menuTitle == "System Default (macOS has no default output.)")
    #expect(model.selectedOutputID == .device(uid: "unavailable"))
    #expect(model.outputSelectorName == "No wired audio output")
    #expect(model.outputSelectorHelp == "No wired audio output — Unavailable")
    #expect(model.outputSelectorAccessibilityValue == "No wired audio output, unavailable")
    #expect(model.outputSelectorEnabled)
    #expect(model.statusAccessibilityLabel == "Demo disc ready")
    #expect(model.trackText == "03")
    #expect(model.timeText == "01:30")
    #expect(model.isShowingDiscSummary)
    #expect(model.displayAccessibilityLabel == "Disc total, 3 audio tracks, total time 01:30")
    #expect(model.controlsEnabled)
    #expect(Disc.demo.tracks.count == 3)
    #expect(Disc.demo.totalFrames == 90 * Disc.sampleRate)
}

@Test @MainActor func outputSelectorUsesInspectedBuiltInNameAndAllowsPlaybackSelection() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, outputRateControl: FakeOutputRateControl(),
        outputSelectionStore: FakeOutputSelectionStore()
    )
    await model.inspectOutput()

    #expect(model.outputSelectorName == "Test built-in output")
    #expect(model.outputSelectorHelp == "Test built-in output — Built-in")
    #expect(model.outputSelectorAccessibilityValue == "Test built-in output, built-in")
    #expect(model.outputChoices.first?.id == model.selectedOutputID)

    await model.togglePlayback()
    #expect(model.outputSelectorEnabled)
    await model.selectOutput(.device(uid: "output-1"))
    #expect(model.state == .playing)
    try await model.shutdown()
}

@Test @MainActor func outputDiscoveryFiltersTransportsAndDisablesUnsupportedDevices() async throws {
    let builtIn = listedOutput("builtin-uid", 1, "MacBook Pro Speakers", .builtIn, usesSpeakers: true)
    let usb = listedOutput("usb-uid", 2, "USB DAC", .usb, isDefault: true)
    let unsupportedRate = listedOutput("hdmi-uid", 3, "HDMI Receiver", .hdmi, supportsSourceRate: false)
    let unsupportedStereo = listedOutput("thunderbolt-uid", 4, "Thunderbolt Mono", .thunderbolt, stereo: false)
    let wireless = listedOutput("airplay-uid", 5, "Living Room", .airPlay)
    let bluetooth = listedOutput("bluetooth-uid", 6, "Wireless Headphones", .bluetooth)
    let aggregate = listedOutput("aggregate-uid", 7, "Multi Output", .aggregate)
    let virtual = listedOutput("virtual-uid", 8, "Virtual Device", .virtual)
    let unknown = listedOutput("other-uid", 9, "Unknown Device", .other(0))
    let control = FakeOutputRateControl(discoveredOutputs: [
        unknown, wireless, unsupportedStereo, aggregate, usb, virtual, bluetooth, unsupportedRate, builtIn
    ])
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false, outputRateControl: control,
                            outputSelectionStore: FakeOutputSelectionStore())

    await model.inspectOutput()

    #expect(model.availableOutputs.count == 9)
    #expect(model.outputChoices.map(\.id) == [
        .device(uid: "builtin-uid"), .device(uid: "usb-uid"), .device(uid: "hdmi-uid"),
        .device(uid: "thunderbolt-uid"), .systemDefault
    ])
    #expect(model.outputChoices.map(\.connection) == ["Built-in", "USB", "HDMI", "Thunderbolt", "USB"])
    #expect(model.outputChoices.map(\.symbol) == [
        "speaker.wave.2", "cable.connector", "tv", "bolt", "cable.connector"
    ])
    #expect(model.outputChoices[4].menuTitle == "System Default — USB DAC (USB), best effort")
    #expect(model.outputChoices[0].isEnabled)
    #expect(model.outputChoices[1].isEnabled)
    #expect(!model.outputChoices[2].isEnabled)
    #expect(model.outputChoices[2].menuTitle.contains("Does not support 44.1 kHz"))
    #expect(!model.outputChoices[3].isEnabled)
    #expect(model.outputChoices[3].menuTitle.contains("No stereo output stream"))
    #expect(model.selectedOutputID == .device(uid: "usb-uid"))
    #expect(model.selectedOutputChoice.title == "USB DAC — USB")
    await model.selectOutput(.device(uid: "hdmi-uid"))
    #expect(model.selectedOutputID == .device(uid: "usb-uid"))
    #expect(await engine.startTargets.isEmpty)
    try await model.shutdown()
}

@Test @MainActor func outputSelectionPersistsUIDWithoutChangingPlaybackRoute() async throws {
    let builtIn = listedOutput("builtin-uid", 1, "MacBook Pro Speakers", .builtIn)
    let usb = listedOutput("usb-uid", 2, "USB DAC", .usb)
    let hdmi = listedOutput("hdmi-uid", 3, "HDMI Receiver", .hdmi)
    let control = FakeOutputRateControl(discoveredOutputs: [builtIn, usb, hdmi])
    let store = FakeOutputSelectionStore(selectedUID: "usb-uid")
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false, outputRateControl: control,
                            outputSelectionStore: store)

    await model.inspectOutput()
    #expect(model.selectedOutputID == .device(uid: "usb-uid"))
    await model.selectOutput(.device(uid: "hdmi-uid"))

    #expect(model.selectedOutputID == .device(uid: "hdmi-uid"))
    #expect(store.selectedID == .device(uid: "hdmi-uid"))
    #expect(store.savedIDs == [.device(uid: "hdmi-uid")])
    #expect(await engine.starts.isEmpty)
    try await model.shutdown()
}

@Test @MainActor func userDefaultsOutputSelectionStorePersistsUIDAcrossInstances() throws {
    let suiteName = "CDPlayer.OutputSelectionTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create an isolated UserDefaults suite.")
        return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = UserDefaultsOutputSelectionStore(defaults: defaults)
    first.save(.device(uid: "usb-stable-uid"))
    let reopened = UserDefaultsOutputSelectionStore(defaults: defaults)
    #expect(reopened.selectedID == .device(uid: "usb-stable-uid"))
    #expect(defaults.string(forKey: UserDefaultsOutputSelectionStore.key) == "usb-stable-uid")
}

@Test @MainActor func userDefaultsOutputSelectionStoreSwitchesBetweenDeviceAndSystemDefault() throws {
    let suiteName = "CDPlayer.OutputSelectionTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create an isolated UserDefaults suite.")
        return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    // A UID saved by M6.2 is still read as the selected device.
    defaults.set("m6-2-uid", forKey: UserDefaultsOutputSelectionStore.key)
    #expect(UserDefaultsOutputSelectionStore(defaults: defaults).selectedID == .device(uid: "m6-2-uid"))

    UserDefaultsOutputSelectionStore(defaults: defaults).save(.systemDefault)
    #expect(UserDefaultsOutputSelectionStore(defaults: defaults).selectedID == .systemDefault)
    #expect(defaults.object(forKey: UserDefaultsOutputSelectionStore.key) == nil)
    #expect(defaults.bool(forKey: UserDefaultsOutputSelectionStore.systemDefaultKey))

    UserDefaultsOutputSelectionStore(defaults: defaults).save(.device(uid: "usb-uid"))
    #expect(UserDefaultsOutputSelectionStore(defaults: defaults).selectedID == .device(uid: "usb-uid"))
    #expect(defaults.object(forKey: UserDefaultsOutputSelectionStore.systemDefaultKey) == nil)
}

@Test @MainActor func userDefaultsOutputSelectionStoreKeepsTheSavedDevicesNameOnly() throws {
    let suiteName = "CDPlayer.OutputSelectionTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create an isolated UserDefaults suite.")
        return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsOutputSelectionStore(defaults: defaults)
    store.saveName("Ignored", for: .device(uid: "usb-uid"))
    #expect(defaults.object(forKey: UserDefaultsOutputSelectionStore.nameKey) == nil)

    store.save(.device(uid: "usb-uid"))
    store.saveName("USB DAC", for: .device(uid: "usb-uid"))
    store.saveName("Other DAC", for: .device(uid: "other-uid"))
    store.saveName("", for: .device(uid: "usb-uid"))
    #expect(UserDefaultsOutputSelectionStore(defaults: defaults).selectedName == "USB DAC")

    store.save(.device(uid: "usb-uid"))
    #expect(UserDefaultsOutputSelectionStore(defaults: defaults).selectedName == "USB DAC")
    store.save(.device(uid: "hdmi-uid"))
    #expect(UserDefaultsOutputSelectionStore(defaults: defaults).selectedName == nil)

    store.saveName("HDMI Receiver", for: .device(uid: "hdmi-uid"))
    store.save(.systemDefault)
    store.saveName("System", for: .systemDefault)
    #expect(UserDefaultsOutputSelectionStore(defaults: defaults).selectedName == nil)
    #expect(defaults.object(forKey: UserDefaultsOutputSelectionStore.nameKey) == nil)
}

@Test @MainActor func unsupportedDefaultFallsBackToSupportedBuiltIn() async throws {
    let builtIn = listedOutput("builtin-uid", 1, "MacBook Pro Speakers", .builtIn)
    let unsupportedDefault = listedOutput(
        "hdmi-uid", 3, "HDMI Receiver", .hdmi, supportsSourceRate: false, isDefault: true
    )
    let model = PlayerModel.offline(
        engine: FakeEngine(), automaticallyMonitor: false,
        outputRateControl: FakeOutputRateControl(discoveredOutputs: [unsupportedDefault, builtIn]),
        outputSelectionStore: FakeOutputSelectionStore()
    )

    await model.inspectOutput()

    #expect(model.outputChoices.contains(where: {
        $0.id == .device(uid: "hdmi-uid") && !$0.isEnabled
    }))
    #expect(model.selectedOutputID == .device(uid: "builtin-uid"))
    try await model.shutdown()
}

@Test @MainActor func builtInSpeakerGuidanceDoesNotApplyToExternalSpeakerTerminal() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, outputRateControl: FakeOutputRateControl(),
        outputSelectionStore: FakeOutputSelectionStore()
    )
    await engine.setOutput(OutputInfo(
        deviceID: 1, name: "MacBook Pro Speakers", sampleRate: 48_000, hogOwner: -1,
        supportsSourceRate: true, isDefaultOutput: true, usesSpeakers: true, uid: "builtin-uid", transport: .builtIn
    ))
    await model.inspectOutput()
    #expect(model.guidanceText.contains("built-in speakers use Apple DSP"))

    await engine.setOutput(OutputInfo(
        deviceID: 2, name: "USB DAC", sampleRate: 48_000, hogOwner: -1,
        supportsSourceRate: true, usesSpeakers: true, uid: "usb-uid", transport: .usb
    ))
    await model.inspectOutput()
    #expect(!model.guidanceText.contains("built-in speakers use Apple DSP"))
    try await model.shutdown()
}

@Test @MainActor func missingRememberedOutputFallsBackThenReconnectsByUID() async throws {
    let savedUID = "reconnected-usb-uid"
    let builtIn = listedOutput("builtin-uid", 1, "MacBook Pro Speakers", .builtIn)
    let defaultUSB = listedOutput("default-usb-uid", 2, "Default USB DAC", .usb, isDefault: true)
    let store = FakeOutputSelectionStore(selectedUID: savedUID)
    let control = FakeOutputRateControl(discoveredOutputs: [builtIn, defaultUSB])
    let model = PlayerModel.offline(engine: FakeEngine(), automaticallyMonitor: false, outputRateControl: control,
                            outputSelectionStore: store)

    await model.inspectOutput()
    #expect(model.selectedOutputID == .device(uid: "default-usb-uid"))
    #expect(store.selectedID == .device(uid: savedUID))
    #expect(store.savedIDs.isEmpty)
    // Nothing named the output before, so the notice uses a generic name.
    #expect(model.statusText == "OUTPUT LOST")
    #expect(model.statusAccessibilityLabel == "Output lost: The saved output")
    #expect(model.outputSelectorHelp.hasSuffix("The saved output is not connected."))

    // Without Play or a choice in between, the saved output returns when its UID is listed again.
    let reconnected = listedOutput(savedUID, 99, "Reconnected USB DAC", .usb)
    await control.setDiscoveredOutputs([builtIn, defaultUSB, reconnected])
    await model.inspectOutput()

    #expect(model.statusText == "DEMO READY")
    #expect(model.selectedOutputID == .device(uid: savedUID))
    #expect(model.selectedOutputChoice.name == "Reconnected USB DAC")
    #expect(model.selectedOutputChoice.connection == "USB")
    #expect(store.selectedID == .device(uid: savedUID))
    #expect(store.savedIDs.isEmpty)
    #expect(store.selectedName == "Reconnected USB DAC")
    try await model.shutdown()
}

@Test @MainActor func outputListUpdatesWhenCoreAudioChangeMonitorFires() async throws {
    let builtIn = listedOutput("builtin-uid", 1, "MacBook Pro Speakers", .builtIn)
    let usb = listedOutput("usb-uid", 2, "USB DAC", .usb)
    let control = FakeOutputRateControl(discoveredOutputs: [builtIn])
    let model = PlayerModel.offline(engine: FakeEngine(), automaticallyMonitor: false, outputRateControl: control,
                            outputSelectionStore: FakeOutputSelectionStore())
    model.startOutputMonitoring()
    await model.inspectOutput()
    #expect(model.outputChoices.map(\.id) == [.device(uid: "builtin-uid"), .systemDefault])

    await control.setDiscoveredOutputs([builtIn, usb])
    control.announceChange()
    for _ in 0..<20 where !model.outputChoices.contains(where: { $0.id == .device(uid: "usb-uid") }) {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(model.outputChoices.map(\.id) == [.device(uid: "builtin-uid"), .device(uid: "usb-uid"), .systemDefault])
    try await model.shutdown()
}

@Test @MainActor func demoPlaybackDoesNotDisplayPhysicalDiscQualityWarnings() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.setQuality(concealedSectors: 4, unverified: true)
    await model.refreshPlayback()
    #expect(model.statusText == "DEMO PLAYING")
    #expect(!model.statusIsError && !model.statusIsWarning)
    #expect(model.statusAccessibilityLabel == "Demo playing")
    try await model.shutdown()
}

@Test @MainActor func playPauseResumeUsesRenderedFrames() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    #expect(model.state == .playing)
    #expect(!model.isShowingDiscSummary)
    #expect(model.trackText == "01")
    #expect(model.timeText == "00:00")
    #expect(model.displayAccessibilityLabel == "Track 1, elapsed 00:00")
    await engine.setFrame(12 * Disc.sampleRate)
    await model.refreshPlayback()
    #expect(model.timeText == "00:12")
    await model.togglePlayback()
    #expect(model.state == .paused)
    #expect(model.trackText == "01")
    #expect(model.timeText == "00:12")
    #expect(!model.isShowingDiscSummary)
    await model.togglePlayback()
    #expect(await engine.starts == [0, 12 * Disc.sampleRate])
    try await model.shutdown()
}

@Test @MainActor func playbackPollsNotifyViewsOnlyWhenTheDisplayChanges() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await model.refreshPlayback()
    // Only the readout observes the clock, so a playing second does not rebuild the panel or menus.
    var notifications = 0
    var ticks = 0
    let subscription = model.objectWillChange.sink { notifications += 1 }
    let clockSubscription = model.clock.objectWillChange.sink { ticks += 1 }
    defer {
        subscription.cancel()
        clockSubscription.cancel()
    }

    for tenth in UInt64(1)...9 {
        await engine.setFrame(tenth * Disc.sampleRate / 10)
        await model.refreshPlayback()
    }
    #expect(notifications == 0 && ticks == 0)
    #expect(model.currentFrame == 9 * Disc.sampleRate / 10)
    #expect(model.bufferedFrames == 100)

    await engine.setFrame(Disc.sampleRate)
    await model.refreshPlayback()
    #expect(notifications == 0 && ticks == 1)
    #expect(model.timeText == "00:01")

    await engine.setBuffering(true)
    await model.refreshPlayback()
    await model.refreshPlayback()
    #expect(notifications == 1 && ticks == 1)
    #expect(model.isBuffering)

    await engine.setFrame(30 * Disc.sampleRate - 1)
    await model.refreshPlayback()
    #expect(notifications == 1 && ticks == 2)
    #expect(model.trackText == "01" && model.timeText == "00:29")
    await engine.setFrame(30 * Disc.sampleRate)
    await model.refreshPlayback()
    #expect(notifications == 1 && ticks == 3)
    #expect(model.trackText == "02" && model.timeText == "00:00")
    try await model.shutdown()
}

@Test @MainActor func outputTextDescribesSharedNativePlaybackWithoutExclusiveMode() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.inspectOutput()
    #expect(model.output?.isDefaultOutput == true)
    #expect(model.outputText == "Test built-in output | Native 44.1 kHz on Play")
    await model.togglePlayback()
    #expect(model.state == .playing)
    #expect(model.outputText == "Test built-in output | Native 44.1 kHz")
    await model.togglePlayback()
    #expect(model.state == .paused)
    #expect(model.outputText == "Test built-in output | Native 44.1 kHz on Play")
    try await model.shutdown()
}

@Test @MainActor func previousTrackUsesThreeSecondRule() async throws {
    let model = PlayerModel.offline(engine: FakeEngine(), automaticallyMonitor: false)
    for _ in 0..<2 { await model.nextTrack() }
    #expect(model.trackText == "02")
    await model.scan(.forward)
    #expect(model.timeText == "00:10")
    await model.previousTrack()
    #expect(model.trackText == "02")
    #expect(model.timeText == "00:00")
    await model.previousTrack()
    #expect(model.trackText == "01")
    await model.previousTrack()
    #expect(model.currentFrame == 0 && model.isShowingDiscSummary)
    try await model.shutdown()
}

@Test @MainActor func previousTrackThresholdIsExactlyThreeSeconds() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.setFrame(33 * Disc.sampleRate)
    await model.refreshPlayback()
    await model.previousTrack()
    #expect(model.currentFrame == 0)
    await engine.setFrame(33 * Disc.sampleRate + 1)
    await model.refreshPlayback()
    await model.previousTrack()
    #expect(model.currentFrame == 30 * Disc.sampleRate)
    try await model.shutdown()
}

@Test @MainActor func seeksCrossBoundariesAndStopShortOfTheDiscEnd() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.scan(.backward)
    #expect(model.currentFrame == 0)
    for _ in 0..<4 { await model.scan(.forward) }
    #expect(model.trackText == "02")
    #expect(model.timeText == "00:10")
    for _ in 0..<20 { await model.scan(.forward) }
    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.currentFrame == 80 * Disc.sampleRate)
    #expect(model.trackText == "03" && model.timeText == "00:20")
    await model.scan(.backward)
    #expect(model.state == .ready)
    #expect(model.trackText == "03")
    #expect(model.timeText == "00:10")
    #expect(await engine.starts.isEmpty)
    #expect(await engine.stops == 0)
    try await model.shutdown()
}

@Test @MainActor func holdingForwardWhilePausedOrPlayingStopsShortOfTheDiscEnd() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await model.togglePlayback()
    for _ in 0..<20 { await model.scan(.forward) }
    #expect(model.state == .paused && model.statusText == "DEMO PAUSED")
    #expect(model.currentFrame == 80 * Disc.sampleRate)
    #expect(model.trackText == "03" && model.timeText == "00:20")
    await model.togglePlayback()
    await engine.setFrame(85 * Disc.sampleRate)
    await model.refreshPlayback()
    await model.scan(.forward)
    #expect(model.state == .playing && model.currentFrame == 85 * Disc.sampleRate)
    #expect(await engine.starts == [0, 80 * Disc.sampleRate])
    #expect(await engine.stops == 1)
    try await model.shutdown()
}

@Test @MainActor func navigationWhilePlayingKeepsPlaybackActive() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await model.nextTrack()
    #expect(model.state == .playing)
    #expect(model.currentFrame == 30 * Disc.sampleRate)
    await model.scan(.forward)
    #expect(await engine.starts == [0, 30 * Disc.sampleRate, 40 * Disc.sampleRate])
    #expect(model.state == .playing)
    try await model.shutdown()
}

@Test @MainActor func trackDisplayFollowsAudioRatherThanAReadAheadCursor() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.setFrame(30 * Disc.sampleRate)
    await model.refreshPlayback()
    #expect(model.trackText == "02")
    #expect(model.timeText == "00:00")
    #expect(model.bufferedFrames == 100)
    try await model.shutdown()
}

@Test @MainActor func discEndShowsTheDiscTotalAndPlayRestartsAtTrackOne() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.setFrame(Disc.demo.totalFrames)
    await model.refreshPlayback()
    #expect(model.state == .ended && model.statusText == "DEMO END")
    #expect(model.isShowingDiscSummary && model.currentFrame == 0)
    #expect(model.trackText == "03" && model.timeText == "01:30")
    #expect(model.displayAccessibilityLabel == "Disc total, 3 audio tracks, total time 01:30")
    #expect(model.stopOrEjectLabel == "Eject demo disc")
    #expect(await engine.stops == 1)
    await model.togglePlayback()
    #expect(model.state == .playing)
    #expect(model.currentFrame == 0 && model.trackText == "01")
    #expect(await engine.starts == [0, 0])
    try await model.shutdown()
}

@Test @MainActor func pausingAsTheDiscFinishesShowsTheDiscEnd() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.setFrame(Disc.demo.totalFrames)
    await model.togglePlayback()
    #expect(model.state == .ended && model.statusText == "DEMO END")
    #expect(model.isShowingDiscSummary && model.timeText == "01:30")
    #expect(model.stopOrEjectLabel == "Eject demo disc")
    await model.togglePlayback()
    #expect(model.state == .playing && model.currentFrame == 0)
    #expect(await engine.starts == [0, 0])
    try await model.shutdown()
}

@Test @MainActor func afterTheDiscEndsTheTrackButtonsBehaveAsAfterStop() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    func playToTheEnd() async {
        await model.togglePlayback()
        await engine.setFrame(Disc.demo.totalFrames)
        await model.refreshPlayback()
        #expect(model.state == .ended && model.isShowingDiscSummary)
    }
    await playToTheEnd()
    await model.previousTrack()
    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.isShowingDiscSummary && model.trackText == "03" && model.timeText == "01:30")

    await playToTheEnd()
    await model.nextTrack()
    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.trackText == "01" && model.timeText == "00:00" && !model.isShowingDiscSummary)

    await playToTheEnd()
    for _ in 0..<5 { await model.nextTrack() }
    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.trackText == "03" && model.timeText == "00:00")

    await playToTheEnd()
    await model.scan(.backward)
    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.trackText == "01" && model.timeText == "00:00" && !model.isShowingDiscSummary)
    #expect(await engine.starts == [0, 0, 0, 60 * Disc.sampleRate])
    #expect(await engine.stops == 4)
    try await model.shutdown()
}

@Test @MainActor func nextOnTheLastTrackNeverEndsTheDisc() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    for _ in 0..<5 { await model.nextTrack() }
    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.trackText == "03" && model.timeText == "00:00")
    #expect(model.currentFrame == 60 * Disc.sampleRate && !model.isShowingDiscSummary)
    #expect(model.stopOrEjectLabel == "Eject demo disc")
    #expect(await engine.starts.isEmpty)
    #expect(await engine.stops == 0)

    await model.togglePlayback()
    await engine.setFrame(75 * Disc.sampleRate)
    await model.refreshPlayback()
    await model.nextTrack()
    #expect(model.state == .playing && model.statusText == "DEMO PLAYING")
    #expect(model.currentFrame == 75 * Disc.sampleRate)
    #expect(await engine.starts == [60 * Disc.sampleRate])
    #expect(await engine.stops == 0)
    try await model.shutdown()
}

@Test @MainActor func pausedNextStopsAtTheLastTrackAndPlayResumesThere() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.setFrame(5 * Disc.sampleRate)
    await model.refreshPlayback()
    await model.togglePlayback()
    for _ in 0..<5 { await model.nextTrack() }
    #expect(model.state == .paused && model.statusText == "DEMO PAUSED")
    #expect(model.trackText == "03" && model.timeText == "00:00")
    #expect(model.currentFrame == 60 * Disc.sampleRate && model.stopOrEjectLabel == "Stop")
    await model.togglePlayback()
    #expect(model.state == .playing && model.currentFrame == 60 * Disc.sampleRate)

    await engine.setFrame(75 * Disc.sampleRate)
    await model.refreshPlayback()
    await model.togglePlayback()
    await model.nextTrack()
    #expect(model.state == .paused && model.statusText == "DEMO PAUSED")
    #expect(model.currentFrame == 75 * Disc.sampleRate && model.timeText == "00:15")
    await model.togglePlayback()
    #expect(model.state == .playing)
    #expect(await engine.starts == [0, 60 * Disc.sampleRate, 75 * Disc.sampleRate])
    #expect(await engine.stops == 2)
    try await model.shutdown()
}

@Test @MainActor func ejectAndReinsertOperateOnlyOnTheDemoDisc() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await model.eject()
    #expect(model.disc == nil)
    #expect(model.state == .empty)
    #expect(model.statusText == "NO DEMO DISC")
    #expect(model.formatText.isEmpty)
    #expect(model.trackText == "00")
    #expect(!model.controlsEnabled)
    await model.togglePlayback()
    #expect(await engine.starts.count == 1)
    await model.insertDemoDisc()
    #expect(model.state == .ready)
    #expect(model.formatText == "44.1 kHz / 16-bit source")
    #expect(model.trackText == "03")
    #expect(model.timeText == "01:30")
    #expect(model.isShowingDiscSummary)
    try await model.shutdown()
}

@Test @MainActor func stopActionRestoresDemoSummaryBeforeEjecting() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    #expect(model.stopOrEjectLabel == "Stop" && model.stopOrEjectSymbol == "stop.fill")
    await engine.setFrame(12 * Disc.sampleRate)
    await model.refreshPlayback()

    await model.stopOrEject()

    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.currentFrame == 0 && model.isShowingDiscSummary)
    #expect(model.trackText == "03" && model.timeText == "01:30")
    #expect(model.stopOrEjectLabel == "Eject demo disc" && model.stopOrEjectSymbol == "eject.fill")

    await model.stopOrEject()
    #expect(model.disc == nil && model.state == .empty)
    #expect(model.statusText == "NO DEMO DISC")
    try await model.shutdown()
}

@Test @MainActor func nextFromTheDiscTotalSelectsTrackOneBeforePlay() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.nextTrack()
    #expect(!model.isShowingDiscSummary)
    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.trackText == "01")
    #expect(model.timeText == "00:00")
    await model.nextTrack()
    #expect(model.trackText == "02")
    await model.previousTrack()
    #expect(model.trackText == "01")
    #expect(model.timeText == "00:00")
    #expect(!model.isShowingDiscSummary)
    #expect(await engine.starts.isEmpty)
    await model.insertDemoDisc()
    #expect(model.trackText == "03")
    #expect(model.timeText == "01:30")
    await model.nextTrack()
    #expect(model.trackText == "01" && model.timeText == "00:00")
    try await model.shutdown()
}

@Test @MainActor func previousOnTrackOneBeforePlayReturnsToTheDiscSummary() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.previousTrack()
    #expect(model.isShowingDiscSummary && model.trackText == "03" && model.timeText == "01:30")
    await model.nextTrack()
    #expect(model.trackText == "01" && model.timeText == "00:00" && !model.isShowingDiscSummary)
    await model.previousTrack()
    #expect(model.state == .ready && model.statusText == "DEMO READY")
    #expect(model.isShowingDiscSummary && model.currentFrame == 0)
    #expect(model.trackText == "03" && model.timeText == "01:30")

    for _ in 0..<2 { await model.scan(.forward) }
    #expect(model.trackText == "01" && model.timeText == "00:20")
    await model.previousTrack()
    #expect(model.timeText == "00:00" && !model.isShowingDiscSummary)
    await model.previousTrack()
    #expect(model.isShowingDiscSummary && model.timeText == "01:30")
    #expect(await engine.starts.isEmpty)
    #expect(await engine.stops == 0)

    await model.togglePlayback()
    await model.togglePlayback()
    await model.previousTrack()
    #expect(model.state == .paused && model.statusText == "DEMO PAUSED")
    #expect(model.trackText == "01" && !model.isShowingDiscSummary)
    try await model.shutdown()
}

@Test @MainActor func startFailureIsVisibleAndRetryable() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await engine.failStart(true)
    await model.togglePlayback()
    #expect(model.state == .failed)
    #expect(model.errorMessage == "Exclusive output is unavailable.")
    await engine.failStart(false)
    await model.togglePlayback()
    #expect(model.state == .playing)
    #expect(model.errorMessage == nil)
    try await model.shutdown()
}

@Test @MainActor func runtimeAndCleanupFailuresAreBothReported() async {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.failSnapshot()
    await engine.failCleanup()
    await model.refreshPlayback()
    #expect(model.state == .failed)
    #expect(model.errorMessage == "Audio buffer underrun. Cleanup failed: Could not restore the output.")
}

@Test @MainActor func bufferingKeepsPauseNavigationAndRenderedTimeAvailable() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    #expect(model.isBuffering && model.statusText == "BUFFERING")
    #expect(model.statusAccessibilityLabel == "Buffering audio")
    #expect(model.state == .playing && model.controlsEnabled)
    await engine.setBuffering(true)
    await model.refreshPlayback()
    #expect(model.currentFrame == 0 && model.isBuffering)
    await engine.setFrame(Disc.sampleRate)
    await engine.setBuffering(false)
    await model.refreshPlayback()
    #expect(model.statusText == "DEMO PLAYING" && !model.isBuffering)
    #expect(model.timeText == "00:01")
    await engine.setBuffering(true)
    await model.refreshPlayback()
    #expect(model.statusText == "BUFFERING" && model.timeText == "00:01")
    await model.togglePlayback()
    #expect(model.state == .paused && !model.isBuffering)
    #expect(model.statusText == "DEMO PAUSED")
    await model.togglePlayback()
    await model.nextTrack()
    #expect(model.state == .playing && model.isBuffering)
    #expect(await engine.starts == [0, Disc.sampleRate, 30 * Disc.sampleRate])
    await engine.setFrame(Disc.demo.totalFrames)
    await model.refreshPlayback()
    #expect(model.state == .ended && !model.isBuffering)
    #expect(model.statusText == "DEMO END")
    try await model.shutdown()
}

@Test @MainActor func aPlaybackFailureIsVisibleBeforeABlockedCleanupFinishes() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.setFrame(Disc.sampleRate)
    await engine.failSnapshot()
    await engine.suspendStop()
    let failing = Task { await model.refreshPlayback() }
    try await waitUntil { await engine.stopIsWaiting() }
    #expect(model.state == .failed && model.isBusy)
    #expect(model.statusText == "[ERR] Audio error")
    #expect(model.errorSummary == "Audio error" && model.errorDetail == "Audio buffer underrun.")
    #expect(!model.isBuffering && !model.controlsEnabled)
    await engine.resumeStop()
    await failing.value
    #expect(!model.isBusy && model.currentFrame == Disc.sampleRate)
    #expect(model.controlsEnabled)
    try await model.shutdown()
}

@Test @MainActor func demoFailuresShowAShortAudioOrEjectError() async {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await engine.failStart(true)
    await model.togglePlayback()
    #expect(model.statusText == "[ERR] Audio error")
    #expect(model.statusIsError && model.statusAccessibilityLabel == "Error: Audio error")
    #expect(model.errorSummary == "Audio error")
    #expect(model.errorDetail == "Exclusive output is unavailable.")
    await engine.failStart(false)
    await engine.failCleanup()
    await model.eject()
    #expect(model.statusText == "[ERR] Eject error")
    #expect(model.statusIsError && model.statusAccessibilityLabel == "Error: Eject error")
    #expect(model.errorDetail == "Could not restore the output. Cleanup failed: Could not restore the output.")
}

@Test @MainActor func staleSnapshotCannotUndoASeek() async throws {
    let engine = FakeEngine()
    let model = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await model.togglePlayback()
    await engine.suspendSnapshot()
    let pending = Task { await model.refreshPlayback() }
    while !(await engine.snapshotIsWaiting()) { await Task.yield() }
    await model.nextTrack()
    await engine.resumeSnapshot(at: Disc.sampleRate)
    await pending.value
    #expect(model.currentFrame == 30 * Disc.sampleRate)
    #expect(model.trackText == "02")
    try await model.shutdown()
}

@Test func invalidPlaybackPositionDoesNotAcquireHardware() async {
    let engine = CoreAudioPlaybackEngine()
    do {
        _ = try await engine.start(at: Disc.demo.totalFrames)
        Issue.record("An out-of-range start should fail.")
    } catch let error as AudioPlaybackError {
        #expect(error.message == "Playback must start within the disc")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test @MainActor func aLateDemoStartCannotRevivePlaybackAfterQuit() async throws {
    for fails in [false, true] {
        let engine = FakeEngine()
        let player = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
        await engine.suspendStart()
        let starting = Task { await player.togglePlayback() }
        try await waitUntil { await engine.startIsWaiting() }
        try await player.shutdown()
        await engine.failStart(fails)
        await engine.resumeStart()
        await starting.value
        #expect(player.state == .ready)
        #expect(player.output == nil)
        #expect(player.errorDetail == nil)
        #expect(!player.isBusy)
        #expect(!player.controlsEnabled)
        #expect(await engine.stops == 1)
    }
}

@Test @MainActor func quitRestoresOutputSampleRatesOnceAfterPlaybackStops() async throws {
    let engine = FakeEngine()
    let restores = OutputRateRestoreSpy()
    let model = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false,
        outputRateControl: FakeOutputRateControl(onRestoreChanged: { try await restores.restore(after: engine) })
    )
    await model.togglePlayback()
    await model.togglePlayback()
    #expect(model.state == .paused)
    #expect(await restores.stopsSeen.isEmpty)
    try await model.shutdown()
    let stops = await engine.stops
    #expect(stops >= 2)
    #expect(await restores.stopsSeen == [stops])
}

@Test @MainActor func quitRestoresOutputSampleRatesEvenAfterAFailedStopAndReportsTheStopFailureFirst() async throws {
    for (stopFails, restoreFails) in [(false, true), (true, false), (true, true)] {
        let engine = FakeEngine()
        let restores = OutputRateRestoreSpy()
        let model = PlayerModel.offline(
            engine: engine, automaticallyMonitor: false,
            outputRateControl: FakeOutputRateControl(onRestoreChanged: { try await restores.restore(after: engine) })
        )
        await model.togglePlayback()
        if stopFails { await engine.failCleanup() }
        if restoreFails { await restores.fail() }
        await #expect(throws: stopFails ? TestFailure.cleanup : TestFailure.restore) {
            try await model.shutdown()
        }
        let stops = await engine.stops
        #expect(await restores.stopsSeen == [stops])
        #expect(!model.controlsEnabled)
    }
}
