import Foundation
import Testing
@testable import CDKit

/// Records the pairs `PlayerModel` asks to mirror, and keeps tests off real output volumes.
final class RecordingVolumeMirror: VolumeMirroring, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [VolumeMirrorPair?] = []

    var pairs: [VolumeMirrorPair?] { lock.withLock { recorded } }

    func mirror(_ pair: VolumeMirrorPair?) {
        lock.withLock { recorded.append(pair) }
    }
}

private final class FakeVolumeControls: OutputVolumeControls {
    enum Write: Equatable {
        case level(String, Float32)
        case mute(String, Bool)
    }

    var volumes: [String: OutputVolume]
    /// Rounds a written level the way a driver with coarse steps would.
    var rounding: [String: (Float32) -> Float32] = [:]
    /// Outputs that apply a level write only when `applyLateWrites()` is called.
    var late: Set<String> = []
    /// Runs once after the next level write, like a change made elsewhere while the mirror writes.
    var duringNextWrite: ((FakeVolumeControls) -> Void)?
    private var pendingLevels: [String: Float32] = [:]
    private(set) var writes: [Write] = []

    init(_ volumes: [String: OutputVolume]) {
        self.volumes = volumes
    }

    func volume(of uid: String) -> OutputVolume? { volumes[uid] }

    func setLevel(_ level: Float32, of uid: String) {
        writes.append(.level(uid, level))
        let applied = rounding[uid]?(level) ?? level
        if late.contains(uid) {
            pendingLevels[uid] = applied
        } else {
            volumes[uid]?.level = applied
        }
        if let change = duringNextWrite {
            duringNextWrite = nil
            change(self)
        }
    }

    func setMuted(_ muted: Bool, of uid: String) {
        writes.append(.mute(uid, muted))
        volumes[uid]?.isMuted = muted
    }

    func applyLateWrites() {
        for (uid, level) in pendingLevels { volumes[uid]?.level = level }
        pendingLevels = [:]
    }

    func clearWrites() { writes = [] }
}

private let speakersAndProX = VolumeMirrorPair(defaultUID: "speakers", outputUID: "prox")

/// The speakers are the macOS default, as in the owner's report; the PRO X is chosen directly.
private func startedMirror(
    speakers: OutputVolume = OutputVolume(level: 0.0625, isMuted: true),
    proX: OutputVolume = OutputVolume(level: 0.25, isMuted: false)
) -> (VolumeMirrorSync, FakeVolumeControls) {
    let controls = FakeVolumeControls(["speakers": speakers, "prox": proX])
    let sync = VolumeMirrorSync(controls: controls)
    sync.setPair(speakersAndProX)
    return (sync, controls)
}

@Test func startingSetsTheDefaultToTheOutputsLevelAndLeavesMuteAlone() {
    let (sync, controls) = startedMirror()

    #expect(controls.writes == [.level("speakers", 0.25)])
    #expect(controls.volumes["speakers"] == OutputVolume(level: 0.25, isMuted: true))
    #expect(controls.volumes["prox"] == OutputVolume(level: 0.25, isMuted: false))

    sync.setPair(speakersAndProX)
    sync.volumesChanged()
    #expect(controls.writes == [.level("speakers", 0.25)])
}

@Test func volumeKeysOnTheDefaultMoveTheOutput() {
    let (sync, controls) = startedMirror()
    controls.clearWrites()

    // Option-Shift gives quarter steps, even straight after the default was aligned.
    controls.volumes["speakers"]?.level = 0.265625
    sync.volumesChanged()
    #expect(controls.writes == [.level("prox", 0.265625)])

    controls.volumes["speakers"]?.level = 0.3125
    sync.volumesChanged()
    #expect(controls.writes.last == .level("prox", 0.3125))
    #expect(controls.volumes["prox"]?.level == 0.3125)

    // The notification for the app's own write changes nothing.
    sync.volumesChanged()
    #expect(controls.writes.count == 2)
}

@Test func aChangeOnTheOutputIsCopiedBackSoTheNextKeyPressDoesNotJump() {
    let (sync, controls) = startedMirror()
    controls.clearWrites()

    // Turned down elsewhere, for example in Audio MIDI Setup.
    controls.volumes["prox"]?.level = 0.125
    sync.volumesChanged()
    #expect(controls.writes == [.level("speakers", 0.125)])

    controls.volumes["speakers"]?.level = 0.1875
    sync.volumesChanged()
    #expect(controls.writes == [.level("speakers", 0.125), .level("prox", 0.1875)])
}

@Test func theDefaultWinsWhenBothChange() {
    let (sync, controls) = startedMirror()
    controls.clearWrites()

    controls.volumes["speakers"]?.level = 0.375
    controls.volumes["prox"]?.level = 0.125
    controls.volumes["speakers"]?.isMuted = false
    controls.volumes["prox"]?.isMuted = true
    sync.volumesChanged()

    #expect(controls.writes == [.level("prox", 0.375), .mute("prox", false)])
    #expect(controls.volumes["prox"] == OutputVolume(level: 0.375, isMuted: false))
}

@Test func muteFollowsEitherSideOnceStarted() {
    let (sync, controls) = startedMirror()
    controls.clearWrites()

    // The speakers were muted at the start, so the first mute-key press only unmutes them.
    controls.volumes["speakers"]?.isMuted = false
    sync.volumesChanged()
    #expect(controls.writes.isEmpty)

    controls.volumes["speakers"]?.isMuted = true
    sync.volumesChanged()
    #expect(controls.writes == [.mute("prox", true)])

    controls.volumes["prox"]?.isMuted = false
    sync.volumesChanged()
    #expect(controls.writes == [.mute("prox", true), .mute("speakers", false)])
}

@Test func muteIsNotMirroredWhenOneSideHasNoMuteControl() {
    let (sync, controls) = startedMirror(proX: OutputVolume(level: 0.25, isMuted: nil))
    controls.clearWrites()

    controls.volumes["speakers"]?.isMuted = false
    sync.volumesChanged()
    controls.volumes["speakers"]?.isMuted = true
    sync.volumesChanged()
    #expect(controls.writes.isEmpty)
    #expect(controls.volumes["prox"]?.isMuted == nil)
}

@Test func driverRoundingDoesNotStartALoop() {
    let (sync, controls) = startedMirror()
    controls.rounding["prox"] = { ($0 * 10).rounded() / 10 }
    controls.clearWrites()

    controls.volumes["speakers"]?.level = 0.3125
    sync.volumesChanged()
    for _ in 1...3 { sync.volumesChanged() }

    #expect(controls.writes == [.level("prox", 0.3125)])
    #expect(controls.volumes["prox"]?.level == 0.3)
    #expect(controls.volumes["speakers"]?.level == 0.3125)
}

@Test func aWriteTheOutputAppliesLateIsNotCopiedBack() {
    let (sync, controls) = startedMirror()
    controls.rounding["prox"] = { ($0 * 10).rounded() / 10 }
    controls.late = ["prox"]
    controls.clearWrites()

    controls.volumes["speakers"]?.level = 0.3125
    sync.volumesChanged()
    #expect(controls.volumes["prox"]?.level == 0.25)
    controls.applyLateWrites()
    sync.volumesChanged()
    #expect(controls.writes == [.level("prox", 0.3125)])
    #expect(controls.volumes["speakers"]?.level == 0.3125)

    // A later change made on the output itself is still copied back.
    controls.volumes["prox"]?.level = 0.125
    sync.volumesChanged()
    #expect(controls.writes == [.level("prox", 0.3125), .level("speakers", 0.125)])
}

/// Found on hardware: at the end of a drag in Audio MIDI Setup, the PRO X's last step was lost.
@Test func aChangeOnTheOtherSideDuringAWriteIsStillCopied() {
    let (sync, controls) = startedMirror(speakers: OutputVolume(level: 0.0625, isMuted: false))
    controls.clearWrites()

    controls.volumes["prox"]?.level = 0.2
    controls.duringNextWrite = { $0.volumes["prox"] = OutputVolume(level: 0.22, isMuted: true) }
    sync.volumesChanged()
    #expect(controls.writes == [.level("speakers", 0.2)])

    // The listener fires again for the change that arrived during the write.
    sync.volumesChanged()
    #expect(controls.writes == [.level("speakers", 0.2), .level("speakers", 0.22), .mute("speakers", true)])
    #expect(controls.volumes["speakers"] == OutputVolume(level: 0.22, isMuted: true))
}

@Test func aLateWriteArrivingWhileTheOtherSideMovesDoesNotUndoThatMove() {
    let (sync, controls) = startedMirror()
    controls.late = ["speakers"]
    controls.clearWrites()

    controls.volumes["prox"]?.level = 0.2
    sync.volumesChanged()
    #expect(controls.writes == [.level("speakers", 0.2)])

    // The speakers apply the write just as the drag moves the PRO X again.
    controls.applyLateWrites()
    controls.volumes["prox"]?.level = 0.22
    sync.volumesChanged()
    #expect(controls.writes == [.level("speakers", 0.2), .level("speakers", 0.22)])
    #expect(controls.volumes["prox"]?.level == 0.22)

    controls.applyLateWrites()
    sync.volumesChanged()
    #expect(controls.writes.count == 2)
    #expect(controls.volumes["speakers"]?.level == 0.22)
}

@Test func nothingIsWrittenUntilBothOutputsHaveAUsableLevel() {
    let controls = FakeVolumeControls(["speakers": OutputVolume(level: 0.0625, isMuted: false)])
    let sync = VolumeMirrorSync(controls: controls)
    sync.setPair(speakersAndProX)
    controls.volumes["speakers"]?.level = 0.5
    sync.volumesChanged()
    #expect(controls.writes.isEmpty)

    // Once both read, the default is aligned to the output, never the reverse.
    controls.volumes["prox"] = OutputVolume(level: 0.25, isMuted: false)
    sync.volumesChanged()
    #expect(controls.writes == [.level("speakers", 0.25)])
}

@Test func stoppingLeavesTheLevelsAndStopsMirroring() {
    let (sync, controls) = startedMirror()
    controls.clearWrites()

    sync.setPair(nil)
    controls.volumes["speakers"]?.level = 0.5
    controls.volumes["speakers"]?.isMuted = false
    sync.volumesChanged()

    #expect(controls.writes.isEmpty)
    #expect(controls.volumes["prox"] == OutputVolume(level: 0.25, isMuted: false))
}

@Test func aNewDefaultIsAlignedToTheOutput() {
    let (sync, controls) = startedMirror()
    controls.volumes["airpods"] = OutputVolume(level: 0.75, isMuted: false)
    controls.clearWrites()

    sync.setPair(VolumeMirrorPair(defaultUID: "airpods", outputUID: "prox"))
    #expect(controls.writes == [.level("airpods", 0.25)])
    #expect(controls.volumes["prox"]?.level == 0.25)
}

@Test func coreAudioControlsIgnoreAnOutputThatIsNotConnected() {
    let controls = CoreAudioVolumeControls()
    #expect(controls.volume(of: "") == nil)
    #expect(controls.volume(of: "io.github.ylau674.CDPlayer.tests.no-such-output") == nil)
    #expect(CoreAudioVolumeControls.device(for: "io.github.ylau674.CDPlayer.tests.no-such-output") == nil)
}
