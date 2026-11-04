import Combine
import Foundation
import Testing
@testable import CDKit

@Test @MainActor func hdcdDecodePreferenceDefaultsOnAndPersists() throws {
    let suite = "CDKitTests.HDCD.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = UserDefaultsHDCDDecodePreferenceStore(defaults: defaults)
    #expect(store.isEnabled)
    store.save(isEnabled: false)
    #expect(UserDefaultsHDCDDecodePreferenceStore(defaults: defaults).isEnabled == false)
}

@Test @MainActor func hdcdPreferenceAppliesOnPlayAndNextTrack() async throws {
    let store = FakeHDCDDecodePreferenceStore()
    let engine = FakeEngine()
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, hdcdDecodePreferenceStore: store
    )
    #expect(player.isHDCDDecodingEnabled)
    player.setHDCDDecodingEnabled(false)
    #expect(!player.isHDCDDecodingEnabled)
    #expect(store.savedValues == [false])

    await player.togglePlayback()
    #expect(await engine.hdcdSettings == [false])

    player.setHDCDDecodingEnabled(true)
    #expect(await engine.hdcdSettings == [false])
    await player.nextTrack()
    #expect(await engine.hdcdSettings == [false, true])
    try await player.shutdown()
}

@Test @MainActor func outputMoveKeepsCurrentHDCDSettingUntilNextTrack() async throws {
    let builtIn = AudioOutputDevice(
        uid: "test-built-in", deviceID: 1, name: "Built-in", transport: .builtIn,
        sampleRate: 44_100, hogOwner: -1, supportsSourceRate: true, hasStereoOutput: true,
        isDefaultOutput: false, terminalType: 1, usesSpeakers: true, restoreRate: 48_000
    )
    let usb = AudioOutputDevice(
        uid: "test-usb", deviceID: 2, name: "USB", transport: .usb,
        sampleRate: 44_100, hogOwner: -1, supportsSourceRate: true, hasStereoOutput: true,
        isDefaultOutput: true, terminalType: 0, usesSpeakers: false, restoreRate: 48_000
    )
    let engine = FakeEngine()
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false,
        outputRateControl: FakeOutputRateControl(discoveredOutputs: [builtIn, usb])
    )
    await player.inspectOutput()
    await player.togglePlayback()
    player.setHDCDDecodingEnabled(false)
    await player.selectOutput(.systemDefault)
    #expect(await engine.hdcdSettings == [true, true])
    await player.nextTrack()
    #expect(await engine.hdcdSettings == [true, true, false])
    try await player.shutdown()
}

@Test @MainActor func hdcdPreferenceAppliesToOpticalSeek() async throws {
    let engine = FakeEngine()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, opticalService: service, seekDelay: .zero,
        makeDiscEngine: { _ in engine }
    )
    player.startOpticalMonitoring()
    await player.togglePlayback()
    player.setHDCDDecodingEnabled(false)
    await player.scan(.forward)
    try await waitUntil { await engine.hdcdSettings.count == 2 }
    #expect(await engine.hdcdSettings == [true, false])
    try await player.shutdown()
}

@Test @MainActor func hdcdSourceTextAndAccessibilityExplainPlaybackState() async throws {
    let engine = FakeEngine()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, opticalService: service,
        makeDiscEngine: { _ in engine }
    )
    player.startOpticalMonitoring()
    await player.togglePlayback()

    await engine.setHDCD(status: .noEffect)
    await player.refreshPlayback()
    #expect(player.formatText == "44.1 kHz / 16-bit HDCD")
    #expect(player.formatHelp?.contains("no decodable features; its 16-bit audio plays unchanged") == true)
    #expect(player.formatHelp.map { player.formatAccessibilityLabel == "\(player.formatText). \($0)" } == true)

    await engine.setHDCD(status: .effectual, decoded: true, physicalOutputBits: 24)
    await player.refreshPlayback()
    #expect(player.formatText == "44.1 kHz / 20-bit HDCD")
    #expect(player.formatHelp?.contains("decoded to 20-bit PCM") == true)
    #expect(player.formatHelp?.contains("6 dB quieter") == true)

    await engine.setHDCD(status: .effectual, physicalOutputBits: 16)
    await player.refreshPlayback()
    #expect(player.formatText == "44.1 kHz / 16-bit HDCD")
    #expect(player.formatHelp?.contains("carries only 16 bits") == true)
    try await player.shutdown()
}

@Test @MainActor func unchangedHDCDStateDoesNotNotifyViewsOnEachPoll() async throws {
    let engine = FakeEngine()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, opticalService: service,
        makeDiscEngine: { _ in engine }
    )
    player.startOpticalMonitoring()
    await player.togglePlayback()
    await engine.setHDCD(status: .noEffect, physicalOutputBits: 32)
    await player.refreshPlayback()
    var notifications = 0
    let subscription = player.objectWillChange.sink { notifications += 1 }
    defer { subscription.cancel() }

    for _ in 1...5 { await player.refreshPlayback() }
    #expect(notifications == 0)
    #expect(player.formatText == "44.1 kHz / 16-bit HDCD")

    await engine.setHDCD(status: .effectual, decoded: true, physicalOutputBits: 32)
    await player.refreshPlayback()
    #expect(notifications == 2)
    for _ in 1...5 { await player.refreshPlayback() }
    #expect(notifications == 2)
    #expect(player.formatText == "44.1 kHz / 20-bit HDCD")
    try await player.shutdown()
}

@Test @MainActor func statusLineNamesAnHDCDDiscOncePlaybackFindsItUntilTheDiscChanges() async throws {
    let disc = Disc(tableOfContents: try CDTableOfContents(data: tocFixture()))
    let engine = FakeEngine(totalFrames: disc.totalFrames)
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, opticalService: service,
        makeDiscEngine: { _ in engine }
    )
    player.startOpticalMonitoring()
    // No audio is read before Play, so a new disc cannot yet be known as HDCD.
    #expect(player.statusText == "CD DETECTED")
    #expect(player.formatText == "44.1 kHz / 16-bit source")

    await player.togglePlayback()
    await engine.setHDCD(status: .detecting)
    await player.refreshPlayback()
    #expect(player.statusText == "CD PLAYING")
    await engine.setHDCD(status: .noEffect, physicalOutputBits: 32)
    await player.refreshPlayback()
    #expect(player.statusText == "HDCD PLAYING")
    #expect(player.statusAccessibilityLabel == "HDCD playing")
    #expect(player.formatText == "44.1 kHz / 16-bit HDCD")

    await player.togglePlayback()
    #expect(player.statusText == "HDCD PAUSED")
    #expect(player.statusAccessibilityLabel == "HDCD paused")

    // Later runs detect again, and may start where no packets are near; the disc stays HDCD.
    await engine.setHDCD(status: .detecting)
    await player.togglePlayback()
    await player.refreshPlayback()
    #expect(player.statusText == "HDCD PLAYING")
    await engine.setHDCD(status: .none, physicalOutputBits: 32)
    await player.refreshPlayback()
    #expect(player.statusText == "HDCD PLAYING")
    #expect(player.formatText == "44.1 kHz / 16-bit HDCD")

    await player.stopOrEject()
    #expect(player.state == .ready && player.statusText == "HDCD DETECTED")
    #expect(player.statusAccessibilityLabel == "HDCD disc detected")
    #expect(player.formatText == "44.1 kHz / 16-bit HDCD")

    await player.togglePlayback()
    await engine.setFrame(disc.totalFrames)
    await player.refreshPlayback()
    #expect(player.state == .ended && player.statusText == "HDCD END")
    #expect(player.statusAccessibilityLabel == "HDCD ended")

    service.emit([opticalDrive(media: try audioMedia(id: 11))])
    #expect(player.statusText == "CD DETECTED")
    #expect(player.statusAccessibilityLabel == "Audio CD detected")
    #expect(player.formatText == "44.1 kHz / 16-bit source")
    #expect(player.formatHelp == nil)
    try await player.shutdown()
}

@Test @MainActor func decodedHDCDTextHoldsUntilANewRunDecides() async throws {
    let engine = FakeEngine()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, opticalService: service,
        makeDiscEngine: { _ in engine }
    )
    player.startOpticalMonitoring()
    await player.togglePlayback()
    await engine.setHDCD(status: .effectual, decoded: true, physicalOutputBits: 32)
    await player.refreshPlayback()
    #expect(player.formatText == "44.1 kHz / 20-bit HDCD")
    await player.stopOrEject()
    #expect(player.statusText == "HDCD DETECTED")
    #expect(player.formatText == "44.1 kHz / 20-bit HDCD")

    // A new disc session detects again before it decides; the text keeps 20-bit meanwhile.
    await engine.setHDCD(status: .detecting, physicalOutputBits: 32)
    await player.togglePlayback()
    await player.refreshPlayback()
    #expect(player.statusText == "HDCD PLAYING")
    #expect(player.formatText == "44.1 kHz / 20-bit HDCD")
    await engine.setHDCD(status: .effectual, decoded: true, physicalOutputBits: 32)
    await player.refreshPlayback()
    #expect(player.formatText == "44.1 kHz / 20-bit HDCD")

    // With the setting off the next run cannot decode, so the text changes before the engine reports.
    player.setHDCDDecodingEnabled(false)
    await engine.setHDCD(status: .detecting, physicalOutputBits: 32)
    await player.nextTrack()
    #expect(player.formatText == "44.1 kHz / 16-bit HDCD")
    await engine.setHDCD(status: .effectual, physicalOutputBits: 32)
    await player.refreshPlayback()
    #expect(player.statusText == "HDCD PLAYING")
    #expect(player.formatText == "44.1 kHz / 16-bit HDCD")
    #expect(player.formatHelp?.contains("decoding was off for this playback run") == true)
    try await player.shutdown()
}

@Test @MainActor func demoDiscNeverShowsHDCD() async throws {
    let engine = FakeEngine()
    let player = PlayerModel.offline(engine: engine, automaticallyMonitor: false)
    await player.togglePlayback()
    await engine.setHDCD(status: .noEffect, physicalOutputBits: 32)
    await player.refreshPlayback()
    #expect(player.statusText == "DEMO PLAYING")
    #expect(player.formatText == "44.1 kHz / 16-bit source")
    #expect(player.formatHelp == nil)
    try await player.shutdown()
}
