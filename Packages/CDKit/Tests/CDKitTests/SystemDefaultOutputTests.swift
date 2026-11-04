import CDAudioCore
import Foundation
import Testing
@testable import CDKit

@MainActor
private final class MemoryOutputSelectionStore: OutputSelectionStore {
    private(set) var selectedID: OutputChoice.ID?
    private(set) var selectedName: String?
    private(set) var savedIDs: [OutputChoice.ID] = []

    init(_ selectedID: OutputChoice.ID? = nil, name: String? = nil) {
        self.selectedID = selectedID
        selectedName = name
    }

    func save(_ id: OutputChoice.ID) {
        if id != selectedID || id == .systemDefault { selectedName = nil }
        selectedID = id
        savedIDs.append(id)
    }

    func saveName(_ name: String, for id: OutputChoice.ID) {
        guard case .device = id, id == selectedID else { return }
        selectedName = name
    }
}

private func device(
    _ uid: String, _ deviceID: UInt32, _ name: String, _ transport: OutputTransport,
    isDefault: Bool = false, usesSpeakers: Bool = false, supportsSourceRate: Bool = true, hasVolume: Bool = true
) -> AudioOutputDevice {
    AudioOutputDevice(
        uid: uid, deviceID: deviceID, name: name, transport: transport, sampleRate: 48_000, hogOwner: -1,
        supportsSourceRate: supportsSourceRate, hasStereoOutput: true, isDefaultOutput: isDefault,
        terminalType: 0, usesSpeakers: usesSpeakers, restoreRate: 48_000, hasVolumeControl: hasVolume
    )
}

private func info(
    _ device: AudioOutputDevice, converts: Bool = false, streamLatencySeconds: Double? = nil
) -> OutputInfo {
    OutputInfo(
        deviceID: device.deviceID, name: device.name, sampleRate: device.sampleRate, hogOwner: -1,
        supportsSourceRate: device.supportsSourceRate, isDefaultOutput: device.isDefaultOutput,
        usesSpeakers: device.usesSpeakers, restoreRate: device.restoreRate, uid: device.id,
        transport: device.transport, converts: converts, streamLatencySeconds: streamLatencySeconds,
        hasVolumeControl: device.hasVolumeControl
    )
}

private let speakers = device("builtin-uid", 1, "MacBook Pro Speakers", .builtIn, usesSpeakers: true)
private let proX = device("usb-uid", 2, "PRO X", .usb)

private func asDefault(_ output: AudioOutputDevice) -> AudioOutputDevice {
    device(output.id, output.deviceID, output.name, output.transport, isDefault: true,
           usesSpeakers: output.usesSpeakers, supportsSourceRate: output.supportsSourceRate,
           hasVolume: output.hasVolumeControl)
}

private let defaultOutputChanged = AudioPlaybackError(CDError(
    result: CD_DEFAULT_OUTPUT_CHANGED, message: "macOS changed its default output."
))

/// Passing `store` reuses a previous player's saved choice, as a relaunch does.
@MainActor
private func makePlayer(
    selected: OutputChoice.ID? = nil, savedName: String? = nil, store: MemoryOutputSelectionStore? = nil,
    outputs: [AudioOutputDevice],
    playingOn defaultOutput: AudioOutputDevice, volumeMirror: RecordingVolumeMirror = RecordingVolumeMirror(),
    audioLevelSource: FakeAudioLevelSource = FakeAudioLevelSource()
) async -> (PlayerModel, FakeEngine, FakeOutputRateControl, MemoryOutputSelectionStore) {
    let engine = FakeEngine()
    await engine.setOutput(info(speakers), on: .builtIn)
    await engine.setOutput(info(defaultOutput), on: .systemDefault)
    await engine.setOutput(info(proX), on: .device(uid: proX.id))
    let control = FakeOutputRateControl(discoveredOutputs: outputs)
    let store = store ?? MemoryOutputSelectionStore(selected, name: savedName)
    let player = PlayerModel.offline(
        engine: engine, audioLevelSource: audioLevelSource, automaticallyMonitor: false,
        outputRateControl: control, outputSelectionStore: store, volumeMirror: volumeMirror,
        defaultOutputSettleDelay: .zero
    )
    return (player, engine, control, store)
}

@Test func outputIconsFollowTheOutputType() {
    let expected: [(OutputTransport, Bool, String)] = [
        (.builtIn, true, "speaker.wave.2"), (.builtIn, false, "headphones"),
        (.usb, true, "cable.connector"), (.usb, false, "cable.connector"),
        (.hdmi, false, "tv"), (.displayPort, false, "display"), (.thunderbolt, false, "bolt"),
        (.airPlay, true, "airplayaudio"), (.bluetooth, true, "hifispeaker"), (.bluetooth, false, "headphones"),
        (.bluetoothLE, false, "headphones"), (.aggregate, false, "hifispeaker"), (.virtual, false, "hifispeaker"),
        (.other(0), false, "hifispeaker"),
    ]
    for (transport, usesSpeakers, symbol) in expected {
        #expect(transport.symbol(usesSpeakers: usesSpeakers) == symbol, "\(transport.title)")
    }
    #expect(OutputChoice.systemDefault(asDefault(proX)).symbol == "cable.connector")
    #expect(OutputChoice.systemDefault(nil).symbol == "hifispeaker")
}

@Test func coreAudioOutputInfoCarriesAvailableStreamLatency() {
    var raw = CDDeviceInfo()
    raw.sampleRate = 44_100
    raw.streamLatencyFrames = 88_200
    raw.hasStreamLatency = true
    #expect(OutputInfo(raw).streamLatencySeconds == 2)

    raw.hasStreamLatency = false
    #expect(OutputInfo(raw).streamLatencySeconds == nil)
}

@Test func coreAudioOutputInfoCarriesTheHostVolumeControl() {
    var raw = CDDeviceInfo()
    #expect(!OutputInfo(raw).hasVolumeControl)
    raw.hasVolumeControl = true
    #expect(OutputInfo(raw).hasVolumeControl)
}

/// Decision 15: an output without a host volume says so in its menu entry, tooltip and VoiceOver value,
/// never on the status line.
@Test @MainActor func outputsWithoutHostVolumeSayVolumeOnDeviceOutsideTheStatusLine() async throws {
    let walkman = device("walkman-uid", 5, "WALKMAN", .usb, isDefault: true, hasVolume: false)
    let (player, engine, _, _) = await makePlayer(
        selected: .device(uid: walkman.id), outputs: [speakers, walkman], playingOn: walkman
    )
    await engine.setOutput(info(walkman), on: .device(uid: walkman.id))
    await player.inspectOutput()

    let entry = try #require(player.outputChoices.first { $0.id == .device(uid: walkman.id) })
    #expect(entry.menuTitle == "WALKMAN — USB, volume on device")
    #expect(player.outputChoices.first?.menuTitle == "MacBook Pro Speakers — Built-in")
    #expect(player.outputChoices.last?.menuTitle == "System Default — WALKMAN (USB), best effort, volume on device")
    #expect(player.outputSelectorName == "WALKMAN")
    #expect(player.outputSelectorHelp == "WALKMAN — USB, volume on device")
    #expect(player.outputSelectorAccessibilityValue == "WALKMAN, usb, volume on device")
    #expect(player.statusText == "DEMO READY" && !player.statusIsWarning)

    await player.selectOutput(.systemDefault)
    #expect(player.outputSelectorHelp == "WALKMAN — System Default (USB), best effort, volume on device. "
        + "Choose \"WALKMAN — USB\" for direct 44.1 kHz playback.")
    #expect(player.outputSelectorAccessibilityValue == "WALKMAN, system default, usb, best effort, volume on device")

    let receiver = device("hdmi-uid", 4, "Living Room TV", .hdmi, supportsSourceRate: false, hasVolume: false)
    #expect(receiver.choice.menuTitle == "Living Room TV — HDMI, volume on device (Does not support 44.1 kHz.)")
    try await player.shutdown()
}

/// Decision 16: the volume keys follow the macOS default, so a directly chosen output that is not the
/// default names the output they control.
@Test @MainActor func aDirectOutputThatIsNotTheDefaultNamesWhatTheVolumeKeysControl() async throws {
    let defaultSpeakers = asDefault(speakers)
    let (player, _, control, _) = await makePlayer(
        selected: .device(uid: proX.id), outputs: [defaultSpeakers, proX], playingOn: defaultSpeakers
    )
    await player.inspectOutput()
    #expect(player.outputSelectorHelp
        == "PRO X — USB. While playing, volume keys control PRO X and MacBook Pro Speakers.")

    await player.selectOutput(.device(uid: speakers.id))
    #expect(player.outputSelectorHelp == "MacBook Pro Speakers — Built-in")
    await player.selectOutput(.systemDefault)
    #expect(!player.outputSelectorHelp.contains("Volume keys") && !player.outputSelectorHelp.contains("volume keys"))

    await player.selectOutput(.device(uid: proX.id))
    await control.setDiscoveredOutputs([speakers, asDefault(proX)])
    await player.inspectOutput()
    #expect(player.outputSelectorHelp == "PRO X — USB")

    // Without a host volume on either side nothing is mirrored, so the keys only reach the default.
    let walkman = device("walkman-uid", 5, "WALKMAN", .usb, hasVolume: false)
    await control.setDiscoveredOutputs([defaultSpeakers, proX, walkman])
    await player.inspectOutput()
    await player.selectOutput(.device(uid: walkman.id))
    #expect(player.outputSelectorHelp
        == "WALKMAN — USB, volume on device. Volume keys control MacBook Pro Speakers.")
    let silentDefault = device("hdmi-uid", 4, "Living Room TV", .hdmi, isDefault: true, hasVolume: false)
    await control.setDiscoveredOutputs([speakers, proX, silentDefault])
    await player.inspectOutput()
    await player.selectOutput(.device(uid: proX.id))
    #expect(player.outputSelectorHelp == "PRO X — USB. Volume keys control Living Room TV.")
    try await player.shutdown()
}

/// Decision 19: only while the CD plays on a directly chosen output that is not the default, with a
/// host volume on both.
@Test @MainActor func volumeKeysAreMirroredOntoADirectOutputOnlyWhilePlaying() async throws {
    let mirror = RecordingVolumeMirror()
    let defaultSpeakers = asDefault(speakers)
    let (player, _, control, _) = await makePlayer(
        selected: .device(uid: proX.id), outputs: [defaultSpeakers, proX], playingOn: defaultSpeakers,
        volumeMirror: mirror
    )
    await player.inspectOutput()
    #expect(mirror.pairs.isEmpty)

    let speakersToProX = VolumeMirrorPair(defaultUID: speakers.id, outputUID: proX.id)
    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(mirror.pairs == [speakersToProX])

    await player.togglePlayback()
    #expect(mirror.pairs == [speakersToProX, nil])
    await player.togglePlayback()
    #expect(mirror.pairs == [speakersToProX, nil, speakersToProX])

    // A new default starts a new pair, so it is aligned to the PRO X; the PRO X as default ends it.
    let airPods = device("bt-uid", 3, "AirPods Pro", .bluetooth, isDefault: true)
    await control.setDiscoveredOutputs([speakers, proX, airPods])
    await player.inspectOutput()
    #expect(mirror.pairs.last == VolumeMirrorPair(defaultUID: airPods.id, outputUID: proX.id))
    await control.setDiscoveredOutputs([speakers, asDefault(proX)])
    await player.inspectOutput()
    #expect(mirror.pairs.last == .some(nil))

    await control.setDiscoveredOutputs([defaultSpeakers, proX])
    await player.inspectOutput()
    #expect(mirror.pairs.last == speakersToProX)
    try await player.shutdown()
    #expect(mirror.pairs.last == .some(nil))
    #expect(mirror.pairs.count == 7)
}

@Test @MainActor func nothingIsMirroredOnSystemDefaultOrWithoutHostVolume() async throws {
    let mirror = RecordingVolumeMirror()
    let (player, engine, control, _) = await makePlayer(
        selected: .systemDefault, outputs: [asDefault(speakers), proX], playingOn: asDefault(speakers),
        volumeMirror: mirror
    )
    await player.inspectOutput()
    await player.togglePlayback()
    #expect(player.state == .playing)
    // Playback is still on the speakers while it follows the new default.
    await control.setDiscoveredOutputs([speakers, asDefault(proX)])
    await player.inspectOutput()
    #expect(player.output?.name == speakers.name)

    let walkman = device("walkman-uid", 5, "WALKMAN", .usb, hasVolume: false)
    await engine.setOutput(info(walkman), on: .device(uid: walkman.id))
    await control.setDiscoveredOutputs([asDefault(speakers), proX, walkman])
    await player.inspectOutput()
    await player.selectOutput(.device(uid: walkman.id))
    #expect(player.state == .playing && player.output?.name == "WALKMAN")

    let silentDefault = device("hdmi-uid", 4, "Living Room TV", .hdmi, isDefault: true, hasVolume: false)
    await control.setDiscoveredOutputs([speakers, proX, silentDefault])
    await player.inspectOutput()
    await player.selectOutput(.device(uid: proX.id))
    #expect(player.state == .playing && player.output?.name == "PRO X")
    #expect(mirror.pairs.isEmpty)
    try await player.shutdown()
}

@Test @MainActor func systemDefaultDescribesTheCurrentDefaultAndPlaysOnIt() async throws {
    let bluetooth = device("bt-uid", 3, "AirPods Pro", .bluetooth, isDefault: true)
    let (player, engine, _, _) = await makePlayer(
        selected: .systemDefault, outputs: [speakers, proX, bluetooth], playingOn: bluetooth
    )
    await player.inspectOutput()

    // A wireless default is only reachable through System Default, never as a wired entry.
    #expect(player.outputChoices.map(\.id) == [.device(uid: "builtin-uid"), .device(uid: "usb-uid"), .systemDefault])
    #expect(player.selectedOutputID == .systemDefault)
    #expect(player.outputSelectorName == "AirPods Pro")
    #expect(player.outputSelectorHelp == "AirPods Pro — System Default (Bluetooth), best effort")
    #expect(player.outputSelectorAccessibilityValue == "AirPods Pro, system default, bluetooth, best effort")
    #expect(player.selectedOutputChoice.menuTitle == "System Default — AirPods Pro (Bluetooth), best effort")
    #expect(player.outputRateSymbol == "headphones")
    #expect(await engine.inspectTargets.last == .systemDefault)
    #expect(player.outputText == "AirPods Pro | System Default, best effort | Native 44.1 kHz on Play")

    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(await engine.startTargets == [.systemDefault])
    #expect(player.outputText == "AirPods Pro | System Default, best effort | Native 44.1 kHz")
    try await player.shutdown()
}

@Test @MainActor func wiredSystemDefaultTooltipSuggestsItsDirectRoute() async throws {
    let defaultUSB = asDefault(proX)
    let (player, _, _, _) = await makePlayer(
        selected: .systemDefault, outputs: [speakers, defaultUSB], playingOn: defaultUSB
    )
    await player.inspectOutput()

    #expect(player.outputSelectorHelp ==
        "PRO X — System Default (USB), best effort. Choose \"PRO X — USB\" for direct 44.1 kHz playback.")
    try await player.shutdown()
}

@Test @MainActor func systemDefaultTooltipDoesNotSuggestAnUnavailableDirectRoute() async throws {
    let unsupportedDefault = device(
        "hdmi-uid", 4, "Living Room TV", .hdmi, isDefault: true, supportsSourceRate: false
    )
    let (player, _, _, _) = await makePlayer(
        selected: .systemDefault, outputs: [speakers, unsupportedDefault], playingOn: unsupportedDefault
    )
    await player.inspectOutput()

    #expect(player.outputSelectorHelp == "Living Room TV — System Default (HDMI), best effort")
    try await player.shutdown()
}

@Test @MainActor func convertedSystemDefaultSaysMacOSConvertsTheAudio() async throws {
    let receiver = device("hdmi-uid", 4, "Living Room TV", .hdmi, isDefault: true, supportsSourceRate: false)
    let (player, engine, control, _) = await makePlayer(
        selected: .systemDefault, outputs: [speakers, receiver], playingOn: receiver
    )
    await engine.setOutput(info(receiver, converts: true), on: .systemDefault)
    await player.inspectOutput()

    #expect(player.outputRateSymbol == "tv")
    #expect(player.outputText == "Living Room TV | System Default, best effort | Converted by macOS on Play")
    #expect(player.guidanceText == "System Default, best effort: macOS converts the rate or channels for this output.")
    #expect(player.outputRateLabel ==
        "Living Room TV at 48 kHz, System Default, best effort: macOS converts the audio. It cannot match the 44.1 kHz source.")
    #expect(!player.outputRateSwitchEnabled)
    await player.toggleOutputRate()
    #expect(await control.calls.isEmpty)
    try await player.shutdown()
}

@Test @MainActor func systemDefaultDisplayAccountsForReportedStreamLatency() async throws {
    let receiver = device("airplay-uid", 5, "Living Room", .airPlay, isDefault: true)
    let (player, engine, _, _) = await makePlayer(
        selected: .systemDefault, outputs: [speakers, receiver], playingOn: receiver
    )
    await engine.setOutput(info(receiver, streamLatencySeconds: 2), on: .systemDefault)
    await player.inspectOutput()
    await player.togglePlayback()

    await engine.setFrame(Disc.sampleRate)
    await player.refreshPlayback()
    #expect(player.currentFrame == Disc.sampleRate)
    #expect(player.timeText == "00:00")

    await engine.setFrame(31 * Disc.sampleRate)
    await player.refreshPlayback()
    #expect(player.currentFrame == 31 * Disc.sampleRate)
    #expect(player.trackText == "01")
    #expect(player.timeText == "00:29")

    await engine.setFrame(32 * Disc.sampleRate)
    await player.refreshPlayback()
    #expect(player.currentFrame == 32 * Disc.sampleRate)
    #expect(player.trackText == "02")
    #expect(player.timeText == "00:00")

    await player.togglePlayback()
    #expect(player.state == .paused)
    #expect(player.currentFrame == 32 * Disc.sampleRate)
    #expect(player.timeText == "00:00")

    await player.togglePlayback()
    #expect(await engine.starts == [0, 32 * Disc.sampleRate])
    #expect(player.trackText == "02")
    #expect(player.timeText == "00:00")

    await player.scan(.backward)
    #expect(await engine.starts == [0, 32 * Disc.sampleRate, 20 * Disc.sampleRate])
    #expect(player.currentFrame == 20 * Disc.sampleRate)
    #expect(player.trackText == "01")
    #expect(player.timeText == "00:20")
    await engine.setFrame(22 * Disc.sampleRate)
    await player.refreshPlayback()
    #expect(player.currentFrame == 22 * Disc.sampleRate)
    #expect(player.timeText == "00:20")
    try await player.shutdown()
}

@Test @MainActor func outputRateSwitchChangesTheDefaultOutputWhenSystemDefaultIsChosen() async throws {
    let (player, _, control, _) = await makePlayer(
        selected: .systemDefault, outputs: [speakers, asDefault(proX)], playingOn: asDefault(proX)
    )
    await player.inspectOutput()
    #expect(player.outputRateSwitchEnabled)
    await player.toggleOutputRate()
    #expect(await control.rateTargets == [.systemDefault])

    await player.selectOutput(.device(uid: "builtin-uid"))
    await player.toggleOutputRate()
    #expect(await control.rateTargets.last == .builtIn)
    await player.selectOutput(.device(uid: "usb-uid"))
    await player.toggleOutputRate()
    #expect(await control.rateTargets.last == .device(uid: "usb-uid"))
    try await player.shutdown()
}

@Test @MainActor func selectedWiredOutputIsInspectedPlayedAndRateSwitchedByUID() async throws {
    let usbAt44 = info(proX).at(44_100)
    let control = FakeOutputRateControl(matched: usbAt44, restored: info(proX))
    let engine = FakeEngine()
    await engine.setOutput(info(speakers), on: .builtIn)
    await engine.setOutput(info(proX), on: .device(uid: proX.id))
    let store = MemoryOutputSelectionStore(.device(uid: proX.id))
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, outputRateControl: control, outputSelectionStore: store
    )

    await player.inspectOutput()
    #expect(player.selectedOutputID == .device(uid: proX.id))
    #expect(player.output?.uid == proX.id)
    #expect(await engine.inspectTargets.last == .device(uid: proX.id))

    await player.toggleOutputRate()
    #expect(await control.rateTargets == [.device(uid: proX.id)])
    #expect(player.output?.sampleRate == 44_100)

    await player.toggleOutputRate()
    #expect(await control.rateTargets == [.device(uid: proX.id), .device(uid: proX.id)])
    #expect(player.output?.sampleRate == 48_000)

    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(await engine.startTargets == [.device(uid: proX.id)])
    #expect(player.output?.name == "PRO X")

    await player.togglePlayback()
    #expect(player.state == .paused)
    try await player.shutdown()
}

@Test @MainActor func losingSelectedWiredOutputPausesAtTheCurrentPosition() async throws {
    let (player, engine, control, store) = await makePlayer(
        selected: .device(uid: proX.id), outputs: [speakers, proX], playingOn: proX
    )
    await player.inspectOutput()
    player.startOutputMonitoring()
    await player.togglePlayback()
    let position = 17 * Disc.sampleRate
    await engine.setFrame(position)
    await engine.failInspect(on: .device(uid: proX.id), with: AudioPlaybackError(CDError(
        result: CD_OUTPUT_UNAVAILABLE, message: "The selected wired output is not connected."
    )))
    await control.setDiscoveredOutputs([speakers])
    control.announceChange()
    try await waitUntil {
        player.state == .paused && player.controlsEnabled
            && player.selectedOutputID == .device(uid: speakers.id)
            && player.output?.name == speakers.name && player.statusText == "OUTPUT LOST"
    }

    #expect(player.state == .paused)
    #expect(player.currentFrame == position)
    #expect(player.selectedOutputID == .device(uid: speakers.id))
    #expect(player.output?.name == speakers.name)
    #expect(player.statusText == "OUTPUT LOST")
    #expect(player.outputSelectorHelp.contains("PRO X was disconnected"))
    #expect(await engine.startTargets == [.device(uid: proX.id)])
    #expect(store.savedIDs.isEmpty)

    // Play resumes on the shown fallback and saves it; PRO X returning doesn't take playback back.
    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(await engine.calls.last == "start \(position) builtIn")
    #expect(store.savedIDs == [.device(uid: speakers.id)])
    await player.togglePlayback()
    await control.setDiscoveredOutputs([speakers, proX])
    await player.inspectOutput()
    #expect(player.selectedOutputID == .device(uid: speakers.id))
    #expect(player.statusText == "DEMO PAUSED")
    try await player.shutdown()
}

/// Decision 14: an output that leaves while nothing plays is named until Play, another choice, or its
/// reconnection.
@Test(arguments: [false, true])
@MainActor func aSelectedWiredOutputThatLeavesWhileNotPlayingIsNamed(paused: Bool) async throws {
    let (player, _, control, store) = await makePlayer(
        selected: .device(uid: proX.id), outputs: [speakers, proX], playingOn: speakers
    )
    await player.inspectOutput()
    #expect(store.selectedName == "PRO X")
    if paused {
        await player.togglePlayback()
        await player.togglePlayback()
        #expect(player.state == .paused)
    }

    await control.setDiscoveredOutputs([speakers])
    await player.inspectOutput()

    #expect(player.statusText == "OUTPUT LOST")
    #expect(player.statusIsWarning && !player.statusIsError)
    #expect(player.selectedOutputID == .device(uid: speakers.id))
    #expect(player.statusAccessibilityLabel
        == (paused ? "Output lost: PRO X. Playback paused" : "Output lost: PRO X"))
    #expect(player.outputSelectorHelp.hasSuffix(
        paused ? "PRO X was disconnected; playback paused." : "PRO X is not connected."
    ))
    #expect(store.selectedID == .device(uid: proX.id))

    await control.setDiscoveredOutputs([speakers, proX])
    await player.inspectOutput()
    #expect(player.statusText == (paused ? "DEMO PAUSED" : "DEMO READY"))
    #expect(player.selectedOutputID == .device(uid: proX.id))
    #expect(!player.outputSelectorHelp.contains("connected"))
    try await player.shutdown()
}

/// Unplugging a directly selected output during playback reports CD_OUTPUT_UNAVAILABLE, and so does
/// another app's exclusive use, which leaves the output listed and must not be called lost.
@Test(arguments: [false, true])
@MainActor func anUnavailableWiredOutputIsLostOnlyWhenItLeavesTheList(stillListed: Bool) async throws {
    let levelSource = FakeAudioLevelSource()
    let (player, engine, control, _) = await makePlayer(
        selected: .device(uid: proX.id), outputs: [speakers, proX], playingOn: speakers,
        audioLevelSource: levelSource
    )
    await player.inspectOutput()
    await player.togglePlayback()
    let frame = 21 * Disc.sampleRate
    await engine.setBuffering(false)
    await engine.setFrame(frame)
    await player.refreshPlayback()
    levelSource.set(AudioLevelPeaks(leftPeak: 32_768, rightPeak: 32_768), at: frame)
    player.audioLevelsWindowVisibilityDidChange(true)
    player.toggleAudioLevels()
    player.audioLevelsDidFinishShowing()
    #expect(levelSource.requests.last.map {
        $0.fromFrame / UInt64(CD_LEVEL_SLOT_FRAMES) == frame / UInt64(CD_LEVEL_SLOT_FRAMES)
    } == true)
    #expect(!player.audioLevelReading.isDark)
    if !stillListed { await control.setDiscoveredOutputs([speakers]) }
    await engine.failSnapshot(with: AudioPlaybackError(CDError(
        result: CD_OUTPUT_UNAVAILABLE, message: "The selected wired output stopped."
    )))
    await player.refreshPlayback()
    await engine.clearSnapshotFailure()

    #expect(player.state == .paused)
    #expect(player.audioLevelReading.isDark)
    #expect(player.currentFrame == frame)
    #expect(await engine.calls == ["start 0 device(uid: \"usb-uid\")", "stop"])
    if stillListed {
        #expect(player.statusText == "DEMO PAUSED")
        #expect(player.selectedOutputID == .device(uid: proX.id))
    } else {
        #expect(player.statusText == "OUTPUT LOST")
        #expect(player.statusAccessibilityLabel == "Output lost: PRO X. Playback paused")
        #expect(player.outputSelectorHelp.hasSuffix("PRO X was disconnected; playback paused."))
        #expect(player.selectedOutputID == .device(uid: speakers.id))
    }
    try await player.shutdown()
}

/// The saved name lets a launch name a missing output. Play on the fallback saves the fallback, so a
/// reconnection or a relaunch keeps it and no later launch reports the old output as lost.
@Test @MainActor func playOnTheFallbackForAMissingSavedOutputSavesTheFallback() async throws {
    let (player, engine, control, store) = await makePlayer(
        selected: .device(uid: proX.id), savedName: "PRO X", outputs: [speakers], playingOn: speakers
    )
    await player.inspectOutput()
    #expect(player.selectedOutputID == .device(uid: speakers.id))
    #expect(player.statusText == "OUTPUT LOST")
    #expect(player.statusAccessibilityLabel == "Output lost: PRO X")
    #expect(player.outputSelectorHelp.hasSuffix("PRO X is not connected."))
    #expect(store.savedIDs.isEmpty)

    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(player.statusText == "BUFFERING")
    #expect(store.savedIDs == [.device(uid: speakers.id)])
    #expect(store.selectedName == "MacBook Pro Speakers")
    player.startOutputMonitoring()
    await control.setDiscoveredOutputs([speakers, proX])
    control.announceChange()
    try await waitUntil { player.outputChoices.contains { $0.id == .device(uid: proX.id) && $0.isEnabled } }
    #expect(player.state == .playing)
    #expect(player.selectedOutputID == .device(uid: speakers.id))

    await player.togglePlayback()
    #expect(player.state == .paused)
    #expect(player.selectedOutputID == .device(uid: speakers.id))
    #expect(player.statusText == "DEMO PAUSED")
    #expect(await engine.startTargets == [.builtIn])
    #expect(store.savedIDs == [.device(uid: speakers.id)])
    try await player.shutdown()

    let (relaunched, _, _, _) = await makePlayer(store: store, outputs: [speakers], playingOn: speakers)
    await relaunched.inspectOutput()
    #expect(relaunched.selectedOutputID == .device(uid: speakers.id))
    #expect(relaunched.statusText == "DEMO READY")
    try await relaunched.shutdown()
}

/// The menu ticks the fallback while the saved output is missing; choosing it must still save it.
@Test @MainActor func choosingTheTickedFallbackSavesIt() async throws {
    let (player, engine, _, store) = await makePlayer(
        selected: .device(uid: proX.id), savedName: "PRO X", outputs: [speakers], playingOn: speakers
    )
    await player.inspectOutput()
    #expect(player.selectedOutputID == .device(uid: speakers.id))
    #expect(player.statusText == "OUTPUT LOST")

    await player.selectOutput(.device(uid: speakers.id))
    #expect(player.statusText == "DEMO READY")
    #expect(!player.outputSelectorHelp.contains("connected"))
    #expect(store.selectedID == .device(uid: speakers.id))
    #expect(store.selectedName == "MacBook Pro Speakers")
    await player.selectOutput(.device(uid: speakers.id))
    #expect(store.savedIDs == [.device(uid: speakers.id)])
    #expect(await engine.startTargets.isEmpty)
    try await player.shutdown()

    let (relaunched, _, _, _) = await makePlayer(store: store, outputs: [speakers], playingOn: speakers)
    await relaunched.inspectOutput()
    #expect(relaunched.statusText == "DEMO READY")
    try await relaunched.shutdown()
}

/// A saved output that is listed but can't play, for example one without 44.1 kHz, is not lost:
/// Play uses the fallback for now and keeps the saved choice.
@Test @MainActor func playOnTheFallbackKeepsAListedButUnavailableSavedOutput() async throws {
    let unsupported = device(proX.id, proX.deviceID, proX.name, .usb, supportsSourceRate: false)
    let (player, engine, _, store) = await makePlayer(
        selected: .device(uid: proX.id), savedName: "PRO X", outputs: [speakers, unsupported], playingOn: speakers
    )
    await player.inspectOutput()
    #expect(player.selectedOutputID == .device(uid: speakers.id))
    #expect(player.statusText == "DEMO READY")

    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(await engine.startTargets == [.builtIn])
    #expect(store.savedIDs.isEmpty)
    #expect(store.selectedID == .device(uid: proX.id))
    try await player.shutdown()
}

@Test @MainActor func aFailedPlayOnTheFallbackKeepsTheMissingSavedOutput() async throws {
    let (player, engine, _, store) = await makePlayer(
        selected: .device(uid: proX.id), savedName: "PRO X", outputs: [speakers], playingOn: speakers
    )
    await player.inspectOutput()
    await engine.failStart(true)

    await player.togglePlayback()
    #expect(player.state != .playing)
    #expect(await engine.startTargets == [.builtIn])
    #expect(store.savedIDs.isEmpty)
    #expect(store.selectedID == .device(uid: proX.id))
    #expect(store.selectedName == "PRO X")
    try await player.shutdown()
}

@Test @MainActor func failedWiredMoveKeepsPositionAndRetryUsesTheSelectedUID() async throws {
    let (player, engine, _, _) = await makePlayer(
        selected: .device(uid: "builtin-uid"), outputs: [speakers, proX], playingOn: speakers
    )
    await player.inspectOutput()
    await player.togglePlayback()
    let position = 23 * Disc.sampleRate
    await engine.setFrame(position)
    await engine.failStart(with: AudioPlaybackError(CDError(
        result: CD_OUTPUT_UNAVAILABLE, message: "Cannot start PRO X."
    )))

    await player.selectOutput(.device(uid: proX.id))

    #expect(player.state == .failed)
    #expect(player.currentFrame == position)
    #expect(player.errorDetail?.contains("PRO X") == true)
    #expect(await engine.startTargets == [.builtIn, .device(uid: proX.id)])

    await engine.failStart(with: nil)
    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(await engine.calls.last == "start \(position) device(uid: \"usb-uid\")")
    try await player.shutdown()
}

@Test @MainActor func playOnSelectedWiredOutputReportsExclusiveUseWithoutFallback() async throws {
    let (player, engine, _, _) = await makePlayer(
        selected: .device(uid: proX.id), outputs: [speakers, proX], playingOn: proX
    )
    await player.inspectOutput()
    await engine.failStart(with: AudioPlaybackError(CDError(
        result: CD_OUTPUT_UNAVAILABLE,
        message: "Another app has exclusive use of the selected wired output (PRO X)."
    )))

    await player.togglePlayback()

    #expect(player.state == .failed)
    #expect(player.errorDetail?.contains("exclusive use") == true)
    #expect(player.errorDetail?.contains("PRO X") == true)
    #expect(await engine.startTargets == [.device(uid: proX.id)])
    #expect(player.selectedOutputID == .device(uid: proX.id))
    try await player.shutdown()
}

@Test @MainActor func quittingRequestsRateRestorationForTheSelectedWiredUID() async throws {
    let usbAt44 = info(proX).at(44_100)
    let control = FakeOutputRateControl(matched: usbAt44, restored: info(proX))
    let engine = FakeEngine()
    await engine.setOutput(info(speakers), on: .builtIn)
    await engine.setOutput(info(proX), on: .device(uid: proX.id))
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, outputRateControl: control,
        outputSelectionStore: MemoryOutputSelectionStore(.device(uid: proX.id))
    )
    await player.inspectOutput()
    await player.toggleOutputRate()

    #expect(player.output?.sampleRate == 44_100)
    try await player.shutdown()

    #expect(await control.calls == [.match, .restoreChanged])
    #expect(await control.rateTargets == [.device(uid: proX.id)])
}

@Test @MainActor func choosingAnotherTargetWhilePlayingMovesPlaybackAtTheSameFrame() async throws {
    let (player, engine, _, store) = await makePlayer(
        selected: .device(uid: "builtin-uid"), outputs: [speakers, asDefault(proX)], playingOn: asDefault(proX)
    )
    await player.inspectOutput()
    #expect(player.selectedOutputID == .device(uid: "builtin-uid"))
    await player.togglePlayback()
    let first = 12 * Disc.sampleRate
    await engine.setFrame(first)
    await player.refreshPlayback()

    await player.selectOutput(.systemDefault)
    #expect(player.state == .playing)
    #expect(player.output?.name == "PRO X")
    #expect(player.outputRateSymbol == "cable.connector")
    #expect(await engine.calls == ["start 0 builtIn", "stop", "start \(first) systemDefault"])
    #expect(store.savedIDs == [.systemDefault])

    let second = 20 * Disc.sampleRate
    await engine.setFrame(second)
    await player.selectOutput(.device(uid: "builtin-uid"))
    #expect(player.state == .playing)
    #expect(player.output?.name == "MacBook Pro Speakers")
    #expect(await engine.calls.suffix(2) == ["stop", "start \(second) builtIn"])

    // A selected USB output is routed directly by UID.
    await player.selectOutput(.device(uid: "usb-uid"))
    #expect(player.state == .playing)
    #expect(player.output?.name == "PRO X")
    #expect(await engine.calls.suffix(2) == ["stop", "start \(second) device(uid: \"usb-uid\")"])
    #expect(store.savedIDs == [.systemDefault, .device(uid: "builtin-uid"), .device(uid: "usb-uid")])
    try await player.shutdown()
}

@Test @MainActor func aMoveThatCannotStartReportsTheOutputsError() async throws {
    let (player, engine, _, _) = await makePlayer(
        selected: .device(uid: "builtin-uid"), outputs: [speakers, asDefault(proX)], playingOn: asDefault(proX)
    )
    await player.inspectOutput()
    await player.togglePlayback()
    let position = 15 * Disc.sampleRate
    await engine.setFrame(position)
    await engine.failStart(with: AudioPlaybackError(CDError(
        result: CD_OUTPUT_UNAVAILABLE, message: "Cannot start the default output (PRO X)."
    )))

    await player.selectOutput(.systemDefault)

    #expect(player.state == .failed)
    #expect(player.errorDetail?.contains("default output (PRO X)") == true)
    #expect(player.currentFrame == position)
    #expect(await engine.startTargets == [.builtIn, .systemDefault])

    // Like a failed Play, Play tries the selected output again from the same position.
    await engine.failStart(with: nil)
    await player.togglePlayback()
    #expect(player.state == .playing)
    #expect(await engine.calls.last == "start \(position) systemDefault")
    try await player.shutdown()
}

@Test @MainActor func aDefaultChangeWhileStoppedOnlyUpdatesTheSelector() async throws {
    let (player, engine, control, _) = await makePlayer(
        selected: .systemDefault, outputs: [asDefault(speakers), proX], playingOn: asDefault(speakers)
    )
    player.startOutputMonitoring()
    await player.inspectOutput()
    #expect(player.outputSelectorName == "MacBook Pro Speakers")
    #expect(player.outputRateSymbol == "speaker.wave.2")

    await engine.setOutput(info(asDefault(proX)), on: .systemDefault)
    await control.setDiscoveredOutputs([speakers, asDefault(proX)])
    control.announceChange()
    try await waitUntil { player.outputSelectorName == "PRO X" && player.outputRateSymbol == "cable.connector" }

    #expect(player.selectedOutputID == .systemDefault)
    #expect(player.state == .ready)
    #expect(await engine.starts.isEmpty)
    try await player.shutdown()
}

@Test @MainActor func aDefaultTheUserChoseWhilePlayingIsFollowedAtTheSameFrame() async throws {
    let (player, engine, control, _) = await makePlayer(
        selected: .systemDefault, outputs: [asDefault(speakers), proX], playingOn: asDefault(speakers)
    )
    await player.inspectOutput()
    await player.togglePlayback()
    let frame = 9 * Disc.sampleRate
    await engine.setFrame(frame)
    await player.refreshPlayback()

    // The Sound menu made the PRO X the default; the speakers are still connected.
    await engine.setOutput(info(asDefault(proX), streamLatencySeconds: 2), on: .systemDefault)
    await control.setDiscoveredOutputs([speakers, asDefault(proX)])
    await engine.failSnapshot(with: defaultOutputChanged)
    await player.refreshPlayback()
    await engine.clearSnapshotFailure()

    #expect(player.state == .playing)
    #expect(player.output?.name == "PRO X")
    #expect(player.outputSelectorName == "PRO X")
    #expect(player.statusText != "OUTPUT LOST")
    #expect(await engine.calls == ["start 0 systemDefault", "stop", "start \(frame) systemDefault"])
    await engine.setFrame(frame + Disc.sampleRate)
    await player.refreshPlayback()
    #expect(player.currentFrame == frame + Disc.sampleRate)
    #expect(player.timeText == "00:09")
    try await player.shutdown()
}

@Test @MainActor func aDefaultChangeSeenByTheOutputMonitorWhilePlayingIsAlsoFollowed() async throws {
    let (player, engine, control, _) = await makePlayer(
        selected: .systemDefault, outputs: [asDefault(speakers), proX], playingOn: asDefault(speakers)
    )
    player.startOutputMonitoring()
    await player.inspectOutput()
    await player.togglePlayback()
    let frame = 4 * Disc.sampleRate
    await engine.setFrame(frame)

    await engine.setOutput(info(asDefault(proX)), on: .systemDefault)
    await control.setDiscoveredOutputs([speakers, asDefault(proX)])
    control.announceChange()
    try await waitUntil { await engine.starts.count == 2 && player.output?.name == "PRO X" }

    #expect(player.state == .playing)
    #expect(await engine.calls == ["start 0 systemDefault", "stop", "start \(frame) systemDefault"])
    try await player.shutdown()
}

/// An unplugged default must not move playback to whatever macOS picks next, such as the speakers.
/// Core Audio can remove the device before or after it announces the new default.
@Test(arguments: [false, true])
@MainActor func aDisconnectedDefaultPausesWithOutputLost(deviceLeavesAfterTheDefaultChanges: Bool) async throws {
    let (player, engine, control, store) = await makePlayer(
        selected: .systemDefault, outputs: [speakers, asDefault(proX)], playingOn: asDefault(proX)
    )
    await player.inspectOutput()
    await player.togglePlayback()
    let frame = 15 * Disc.sampleRate
    await engine.setFrame(frame)
    await player.refreshPlayback()

    await engine.setOutput(info(asDefault(speakers)), on: .systemDefault)
    let afterRemoval = [asDefault(speakers)]
    await control.scriptDiscoveries(
        deviceLeavesAfterTheDefaultChanges ? [[asDefault(speakers), proX], afterRemoval] : [afterRemoval]
    )
    await engine.failSnapshot(with: defaultOutputChanged)
    await player.refreshPlayback()
    await engine.clearSnapshotFailure()

    #expect(player.state == .paused)
    #expect(player.currentFrame == frame)
    #expect(await engine.calls == ["start 0 systemDefault", "stop"])
    #expect(player.statusText == "OUTPUT LOST")
    #expect(player.statusIsWarning && !player.statusIsError)
    #expect(player.statusAccessibilityLabel == "Output lost: PRO X. Playback paused")
    #expect(player.outputSelectorHelp == "MacBook Pro Speakers — System Default (Built-in), best effort. "
        + "Choose \"MacBook Pro Speakers — Built-in\" for direct 44.1 kHz playback. "
        + "PRO X was disconnected; playback paused.")
    #expect(player.output?.name == "MacBook Pro Speakers")
    #expect(player.outputSelectorName == "MacBook Pro Speakers")

    if deviceLeavesAfterTheDefaultChanges {
        await player.togglePlayback()
        #expect(player.state == .playing)
        #expect(await engine.calls.last == "start \(frame) systemDefault")
    } else {
        // Moving within the disc keeps the notice; the lost output reconnecting clears it.
        await player.nextTrack()
        #expect(player.state == .paused)
        #expect(player.statusText == "OUTPUT LOST")
        await control.setDiscoveredOutputs([asDefault(speakers), proX])
        await player.inspectOutput()
        #expect(player.state == .paused)
    }
    #expect(player.statusText != "OUTPUT LOST")
    #expect(!player.outputSelectorHelp.contains("disconnected"))
    // System Default follows macOS, so Play never replaces it.
    #expect(store.savedIDs.isEmpty)
    try await player.shutdown()
}

@Test @MainActor func noDefaultOutputDisablesSystemDefault() async throws {
    let (player, _, _, _) = await makePlayer(selected: .systemDefault, outputs: [speakers], playingOn: speakers)
    await player.inspectOutput()
    let entry = try #require(player.outputChoices.last)
    #expect(entry.id == .systemDefault && !entry.isEnabled)
    #expect(entry.menuTitle == "System Default (macOS has no default output.)")
    // The remembered choice returns once macOS has a default again; meanwhile a wired output is shown.
    #expect(player.selectedOutputID == .device(uid: "builtin-uid"))
    await player.selectOutput(.systemDefault)
    #expect(player.selectedOutputID == .device(uid: "builtin-uid"))
    try await player.shutdown()
}
