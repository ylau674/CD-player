import DiskArbitration
import Foundation
import Testing
@testable import CDKit

@MainActor
final class FakeOpticalService: OpticalDriveService {
    var snapshot: OpticalSnapshot
    var startFailure: OpticalDriveError?
    var ejectFailure: OpticalDriveError?
    /// Runs when an eject reaches the service, before anything else happens.
    var onEject: (() -> Void)?
    private(set) var ejects: [(drive: UInt64, media: UInt64)] = []
    private(set) var starts = 0
    private(set) var refreshes = 0
    private(set) var stopped = false
    private var onChange: (@MainActor (OpticalSnapshot) -> Void)?

    init(_ drives: [OpticalDrive] = []) { snapshot = OpticalSnapshot(drives: drives) }
    func start(onChange: @escaping @MainActor (OpticalSnapshot) -> Void) throws {
        starts += 1
        if let startFailure { throw startFailure }
        self.onChange = onChange
        onChange(snapshot)
    }
    func refresh() {
        refreshes += 1
        onChange?(snapshot)
    }
    func stop() { stopped = true }
    func emit(_ drives: [OpticalDrive], error: String? = nil) {
        snapshot = OpticalSnapshot(drives: drives, errorMessage: error)
        onChange?(snapshot)
    }
    func eject(media: OpticalMedia, from driveID: UInt64) async throws {
        onEject?()
        ejects.append((driveID, media.id))
        guard snapshot.drives.contains(where: { $0.id == driveID && $0.media?.id == media.id }) else {
            throw OpticalDriveError("The selected disc was replaced. Eject was cancelled.")
        }
        if let ejectFailure { throw ejectFailure }
        emit(snapshot.drives.map {
            $0.id == driveID ? OpticalDrive(id: $0.id, name: $0.name, media: nil) : $0
        })
    }
}

func audioMedia(id: UInt64 = 10, mounted: Bool = false) throws -> OpticalMedia {
    OpticalMedia(
        id: id, bsdName: "disk4", contents: .audioCD(try CDTableOfContents(data: tocFixture())),
        isMounted: mounted, isEjectable: true
    )
}

func opticalDrive(id: UInt64 = 1, media: OpticalMedia? = nil) -> OpticalDrive {
    OpticalDrive(id: id, name: "Test Blu-ray drive \(id)", media: media)
}

private let driveIssue = "Cannot inspect media in the optical drive (IOKit status -536870208)."

private func faultyDrive(id: UInt64 = 1) -> OpticalDrive {
    OpticalDrive(id: id, name: "Test Blu-ray drive \(id)", media: nil, issue: driveIssue)
}

@Test @MainActor func physicalModeDiscoversAudioMetadataWithoutStartingDemoAudio() async throws {
    let engine = FakeEngine()
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(
        engine: engine, automaticallyMonitor: false, opticalService: service, discOpener: opener
    )
    #expect(player.statusText == "CHECKING DRIVE")
    player.startOpticalMonitoring()
    #expect(player.source == .opticalDrive)
    #expect(player.state == .ready)
    #expect(player.statusText == "CD DETECTED")
    #expect(player.statusAccessibilityLabel == "Audio CD detected")
    #expect(player.trackText == "03")
    #expect(player.timeText == "00:30")
    #expect(player.isShowingDiscSummary)
    #expect(player.displayAccessibilityLabel == "Disc total, 3 audio tracks, total time 00:30")
    #expect(player.sourceText.contains("3 audio tracks | 00:30"))
    #expect(player.guidanceText.contains("Not mounted."))
    #expect(player.errorDetail == nil)
    #expect(player.controlsEnabled)
    #expect(player.ejectEnabled)
    #expect(player.disc == Disc(tableOfContents: try CDTableOfContents(data: tocFixture())))
    #expect(opener.opens.isEmpty)
    #expect(await engine.starts.isEmpty)
    #expect(player.currentFrame == 0)
    try await player.shutdown()
}

@Test @MainActor func handleDriveArrivalDiscInsertionRemovalAndUnplug() throws {
    let service = FakeOpticalService()
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    #expect(player.statusText == "CHECKING DRIVE")
    #expect(player.formatText.isEmpty)
    player.startOpticalMonitoring()
    #expect(player.statusText == "NO DRIVE")
    #expect(player.statusAccessibilityLabel == "No optical drive")
    #expect(player.formatText.isEmpty)
    service.emit([opticalDrive()])
    #expect(player.statusText == "NO DISC")
    #expect(player.statusAccessibilityLabel == "No disc")
    #expect(player.formatText.isEmpty)
    service.emit([opticalDrive(media: OpticalMedia(
        id: 10, bsdName: nil, contents: .reading, isMounted: nil, isEjectable: true
    ))])
    #expect(player.statusText == "READING")
    #expect(player.statusAccessibilityLabel == "Reading disc metadata")
    #expect(player.formatText == "Optical media")
    #expect(player.trackText == "00")
    #expect(player.timeText == "00:00")
    #expect(!player.isShowingDiscSummary)
    #expect(!player.ejectEnabled)
    service.emit([opticalDrive(media: try audioMedia())])
    #expect(player.statusText == "CD DETECTED")
    #expect(player.statusAccessibilityLabel == "Audio CD detected")
    #expect(player.formatText == "44.1 kHz / 16-bit source")
    #expect(player.trackText == "03")
    #expect(player.timeText == "00:30")
    service.emit([opticalDrive()])
    #expect(player.statusText == "NO DISC")
    #expect(player.formatText.isEmpty)
    #expect(player.trackText == "00")
    #expect(player.timeText == "00:00")
    #expect(!player.isShowingDiscSummary)
    service.emit([])
    #expect(player.statusText == "NO DRIVE")
    #expect(player.statusAccessibilityLabel == "No optical drive")
    #expect(player.formatText.isEmpty)
    #expect(player.selectedDriveID == nil)
}

@Test @MainActor func dataDiscsAndOtherMediaNeverEnablePlayback() {
    let service = FakeOpticalService()
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    service.emit([opticalDrive(media: OpticalMedia(
        id: 10, bsdName: "disk4", contents: .dataCD, isMounted: true, isEjectable: true
    ))])
    #expect(player.statusText == "DATA DISC")
    #expect(player.statusAccessibilityLabel == "Data disc detected")
    #expect(player.formatText == "Optical media")
    #expect(player.trackText == "00")
    #expect(!player.controlsEnabled)
    #expect(player.ejectEnabled)
    service.emit([opticalDrive(media: OpticalMedia(
        id: 11, bsdName: "disk4", contents: .other("BD-ROM"), isMounted: false, isEjectable: true
    ))])
    #expect(player.statusText == "NOT AUDIO CD")
    #expect(player.statusAccessibilityLabel == "Disc is not an audio CD")
    #expect(player.formatText == "Optical media")
    #expect(player.sourceText.contains("BD-ROM"))
    #expect(!player.controlsEnabled)
}

@Test @MainActor func invalidTOCAndDiscoveryFailuresAreVisible() {
    let service = FakeOpticalService()
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    service.emit([opticalDrive(media: OpticalMedia(
        id: 10, bsdName: "disk4", contents: .unreadable("Malformed track table."),
        isMounted: false, isEjectable: true
    ))])
    #expect(player.state == .failed)
    #expect(player.statusText == "[ERR] Disc error")
    #expect(player.errorDetail == "Malformed track table.")
    service.emit([], error: "Cannot inspect optical metadata.")
    #expect(player.errorDetail == "Cannot inspect optical metadata.")
    #expect(!player.ejectEnabled)
}

@Test @MainActor func mixedModeSummaryCountsAndTimesOnlyAudioTracks() throws {
    let table = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [
            TOCTrackFixture(number: 1, sector: 0, control: 4),
            TOCTrackFixture(number: 2, sector: 750)
        ], leadOut: 1_500)
    ]))
    let service = FakeOpticalService([opticalDrive(media: OpticalMedia(
        id: 10, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true
    ))])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    #expect(player.trackText == "01")
    #expect(player.timeText == "00:10")
    #expect(player.displayAccessibilityLabel == "Disc total, 1 audio track, total time 00:10")
    #expect(player.sourceText.contains("1 audio track | 00:10"))
}

@Test @MainActor func tenTrackDiscSummaryShowsTotalMinutesAndSeconds() throws {
    let table = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: (0..<10).map {
            TOCTrackFixture(number: $0 + 1, sector: UInt64($0) * 26_000)
        }, leadOut: 265_467)
    ]))
    let service = FakeOpticalService([opticalDrive(media: OpticalMedia(
        id: 10, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true
    ))])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    #expect(player.trackText == "10")
    #expect(player.timeText == "58:59")
    #expect(player.displayAccessibilityLabel == "Disc total, 10 audio tracks, total time 58:59")
}

@Test @MainActor func summarySumsAudioDurationInsteadOfCountingIntersessionGaps() throws {
    let table = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 750),
        TOCSessionFixture(number: 2, tracks: [
            TOCTrackFixture(number: 2, sector: 12_000)
        ], leadOut: 12_750)
    ]))
    let service = FakeOpticalService([opticalDrive(media: OpticalMedia(
        id: 10, bsdName: "disk4", contents: .audioCD(table), isMounted: false, isEjectable: true
    ))])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    #expect(player.trackText == "02")
    #expect(player.timeText == "00:20")
}

@Test @MainActor func physicalEjectTargetsTheSelectedWholeDisc() async throws {
    let first = opticalDrive(media: try audioMedia())
    let second = opticalDrive(id: 2, media: try audioMedia(id: 20))
    let service = FakeOpticalService([first, second])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    await player.useOpticalDrive(id: 2)
    #expect(player.formatText == "44.1 kHz / 16-bit source")
    await player.eject()
    #expect(service.ejects.count == 1)
    #expect(service.ejects.first?.drive == 2)
    #expect(service.ejects.first?.media == 20)
    #expect(player.statusText == "NO DISC")
    #expect(player.formatText.isEmpty)
    #expect(player.trackText == "00")
    #expect(player.selectedDriveID == 2)
    #expect(service.snapshot.drives.first?.media == first.media)
    try await player.shutdown()
}

@Test @MainActor func refusedEjectKeepsTheDiscAndReportsTheFailure() async throws {
    let drive = opticalDrive(media: try audioMedia())
    let service = FakeOpticalService([drive])
    service.ejectFailure = OpticalDriveError("macOS denied eject under removable-media policy.")
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    await player.eject()
    #expect(player.errorDetail == service.ejectFailure?.message)
    #expect(player.selectedDrive?.media == drive.media)
    #expect(service.ejects.count == 1)
    service.refresh()
    #expect(player.errorDetail == service.ejectFailure?.message)
    service.ejectFailure = nil
    await player.eject()
    #expect(player.errorDetail == nil)
    #expect(player.statusText == "NO DISC")
    try await player.shutdown()
}

@Test @MainActor func replacingADiscDuringAudioCleanupDoesNotEjectTheNewDisc() async throws {
    let old = try audioMedia()
    let new = try audioMedia(id: 11)
    let service = FakeOpticalService([opticalDrive(media: old)])
    let engine = FakeEngine()
    let player = PlayerModel.offline(engine: engine, opticalService: service)
    player.startOpticalMonitoring()
    await engine.suspendStop()
    let pending = Task { await player.eject() }
    while !(await engine.stopIsWaiting()) { await Task.yield() }
    service.emit([opticalDrive(media: new)])
    await engine.resumeStop()
    await pending.value
    #expect(service.ejects.count == 1)
    #expect(service.ejects.first?.media == old.id)
    #expect(player.selectedDrive?.media == new)
    #expect(player.errorDetail == "The selected disc was replaced. Eject was cancelled.")
    try await player.shutdown()
}

@Test @MainActor func driveSelectionIsStableUntilTheUserChangesItOrUnplugs() async throws {
    let empty = opticalDrive()
    let audio = opticalDrive(id: 2, media: try audioMedia(id: 20))
    let service = FakeOpticalService([empty, audio])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    #expect(player.selectedDriveID == 2)
    service.emit([empty, audio, opticalDrive(id: 3, media: try audioMedia(id: 30))])
    #expect(player.selectedDriveID == 2)
    await player.useOpticalDrive(id: 1)
    #expect(player.statusText == "NO DISC")
    service.emit([empty, audio])
    #expect(player.selectedDriveID == 1)
    service.emit([audio])
    #expect(player.selectedDriveID == 2)
    #expect(player.statusText == "CD DETECTED")
    try await player.shutdown()
}

@Test @MainActor func driveSelectorAppearsOnlyWithSeveralDrivesInPhysicalMode() async throws {
    let first = opticalDrive(media: try audioMedia())
    let service = FakeOpticalService()
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    #expect(!player.showsDriveSelector)
    service.emit([first])
    #expect(!player.showsDriveSelector)
    player.selectNextDrive()
    #expect(player.pendingDriveID == nil)
    service.emit([first, opticalDrive(id: 2)])
    #expect(player.showsDriveSelector)
    #expect(player.driveSelectorEnabled)
    await player.insertDemoDisc()
    #expect(!player.showsDriveSelector)
    player.selectNextDrive()
    #expect(player.pendingDriveID == nil)
    await player.useOpticalDrive()
    #expect(player.showsDriveSelector)
    service.emit([first])
    #expect(!player.showsDriveSelector)
    try await player.shutdown()
}

@Test @MainActor func driveSelectorCyclesInConnectionOrderWithoutRescanning() async throws {
    let service = FakeOpticalService([
        opticalDrive(media: try audioMedia()), opticalDrive(id: 2), opticalDrive(id: 3, media: try audioMedia(id: 30))
    ])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    #expect(player.selectedDriveID == 1)
    player.selectNextDrive()
    #expect(player.pendingDriveID == 2)
    #expect(player.selectedDriveID == 1)
    #expect(player.displayedDrive?.id == 2)
    #expect(player.statusText == "DRIVE 2 OF 3")
    #expect(player.statusAccessibilityLabel == "Selecting optical drive 2 of 3")
    #expect(player.trackText == "00")
    #expect(player.timeText == "00:00")
    #expect(player.formatText.isEmpty)
    #expect(!player.isShowingDiscSummary)
    #expect(player.displayAccessibilityLabel == "Selecting optical drive 2 of 3")
    #expect(!player.ejectEnabled)
    #expect(!player.controlsEnabled)
    player.selectNextDrive()
    #expect(player.statusText == "DRIVE 3 OF 3")
    player.selectNextDrive()
    #expect(player.pendingDriveID == 1)
    #expect(player.statusText == "DRIVE 1 OF 3")
    player.selectNextDrive()
    #expect(player.pendingDriveID == 2)
    #expect(service.refreshes == 0)
    #expect(player.selectedDriveID == 1)
    try await player.shutdown()
}

@Test @MainActor func committingTheChosenDriveSelectsAndRescansIt() async throws {
    let service = FakeOpticalService([opticalDrive(media: try audioMedia()), opticalDrive(id: 2, media: try audioMedia(id: 20))])
    let engine = FakeEngine()
    let player = PlayerModel.offline(engine: engine, opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    player.selectNextDrive()
    let stopsBefore = await engine.stops
    await player.commitDriveSelection()
    #expect(player.selectedDriveID == 2)
    #expect(player.pendingDriveID == nil)
    #expect(player.driveSelection == nil)
    #expect(service.refreshes == 1)
    #expect(await engine.stops == stopsBefore + 1)
    #expect(player.statusText == "CD DETECTED")
    #expect(player.trackText == "03")
    #expect(player.timeText == "00:30")
    #expect(player.displayedDrive?.id == 2)
    await player.eject()
    #expect(service.ejects.first?.drive == 2)
    #expect(service.ejects.first?.media == 20)
    try await player.shutdown()
}

@Test @MainActor func theChosenDriveIsAppliedAfterTheDwellDelay() async throws {
    let service = FakeOpticalService([opticalDrive(media: try audioMedia()), opticalDrive(id: 2)])
    let player = PlayerModel.offline(
        engine: FakeEngine(), opticalService: service, driveSelectionDelay: .milliseconds(20)
    )
    player.startOpticalMonitoring()
    player.selectNextDrive()
    #expect(player.statusText == "DRIVE 2 OF 2")
    let deadline = ContinuousClock.now + .seconds(10)
    while player.isSelectingDrive, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(player.selectedDriveID == 2)
    #expect(!player.isSelectingDrive)
    #expect(service.refreshes == 1)
    #expect(player.statusText == "NO DISC")
    try await player.shutdown()
}

@Test @MainActor func eachClickRestartsTheDwellDelay() async throws {
    let service = FakeOpticalService([opticalDrive(), opticalDrive(id: 2), opticalDrive(id: 3)])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    player.selectNextDrive()
    let first = try #require(player.driveSelection)
    player.selectNextDrive()
    #expect(first.isCancelled)
    #expect(player.driveSelection?.isCancelled == false)
    #expect(player.pendingDriveID == 3)
    try await player.shutdown()
}

@Test @MainActor func unpluggingTheChosenDriveOrLeavingOneDriveCancelsTheChoice() async throws {
    let first = opticalDrive(media: try audioMedia())
    let second = opticalDrive(id: 2)
    let third = opticalDrive(id: 3)
    let service = FakeOpticalService([first, second, third])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    player.selectNextDrive()
    service.emit([first, second, opticalDrive(id: 3, media: try audioMedia(id: 30))])
    #expect(player.pendingDriveID == 2)
    #expect(player.statusText == "DRIVE 2 OF 3")
    var task = try #require(player.driveSelection)
    service.emit([first, third])
    #expect(task.isCancelled)
    #expect(player.pendingDriveID == nil)
    #expect(player.selectedDriveID == 1)
    #expect(player.statusText == "CD DETECTED")
    player.selectNextDrive()
    #expect(player.pendingDriveID == 3)
    task = try #require(player.driveSelection)
    service.emit([first])
    #expect(task.isCancelled)
    #expect(player.pendingDriveID == nil)
    #expect(!player.showsDriveSelector)
    #expect(player.selectedDriveID == 1)
    #expect(player.trackText == "03")
    #expect(service.refreshes == 0)
    try await player.shutdown()
}

@Test @MainActor func demoModeMenuSelectionAndQuitCancelTheChoice() async throws {
    let service = FakeOpticalService([opticalDrive(media: try audioMedia()), opticalDrive(id: 2), opticalDrive(id: 3)])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    player.selectNextDrive()
    var task = try #require(player.driveSelection)
    await player.insertDemoDisc()
    #expect(task.isCancelled)
    #expect(player.pendingDriveID == nil)
    #expect(player.source == .demo)
    await player.useOpticalDrive()
    player.selectNextDrive()
    task = try #require(player.driveSelection)
    await player.useOpticalDrive(id: 3)
    #expect(task.isCancelled)
    #expect(player.pendingDriveID == nil)
    #expect(player.selectedDriveID == 3)
    player.selectNextDrive()
    #expect(player.pendingDriveID == 1)
    task = try #require(player.driveSelection)
    try await player.shutdown()
    #expect(task.isCancelled)
    #expect(player.pendingDriveID == nil)
    #expect(!player.driveSelectorEnabled)
    player.selectNextDrive()
    #expect(player.pendingDriveID == nil)
}

@Test @MainActor func driveSelectorIsDisabledWhileBusyAndADroppedChoiceIsNotLeftOnScreen() async throws {
    let service = FakeOpticalService([opticalDrive(media: try audioMedia()), opticalDrive(id: 2), opticalDrive(id: 3)])
    let engine = FakeEngine()
    let player = PlayerModel.offline(engine: engine, opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    await engine.suspendStop()
    let ejecting = Task { await player.eject() }
    while !(await engine.stopIsWaiting()) { await Task.yield() }
    #expect(player.showsDriveSelector)
    #expect(!player.driveSelectorEnabled)
    player.selectNextDrive()
    #expect(player.pendingDriveID == nil)
    await engine.resumeStop()
    await ejecting.value
    #expect(player.driveSelectorEnabled)

    player.selectNextDrive()
    #expect(player.pendingDriveID == 2)
    await engine.suspendStop()
    let choosing = Task { await player.useOpticalDrive(id: 3) }
    while !(await engine.stopIsWaiting()) { await Task.yield() }
    await player.commitDriveSelection()
    #expect(player.pendingDriveID == nil)
    #expect(player.statusText == "PREPARING")
    await engine.resumeStop()
    await choosing.value
    #expect(player.selectedDriveID == 3)
    try await player.shutdown()
}

@Test func identicalDriveNamesAreNumberedInConnectionOrder() throws {
    let model = "PIONEER BD-RW BDR-XS07U"
    let media = try audioMedia()
    let named = OpticalDrive.numberingDuplicateNames([
        OpticalDrive(id: 1, name: model, media: nil),
        OpticalDrive(id: 2, name: "HL-DT-ST DVDRW GX50N", media: nil),
        OpticalDrive(id: 3, name: model, media: media),
        OpticalDrive(id: 4, name: model, media: nil)
    ])
    #expect(named.map(\.name) == ["\(model) (1)", "HL-DT-ST DVDRW GX50N", "\(model) (2)", "\(model) (3)"])
    #expect(named.map(\.id) == [1, 2, 3, 4])
    #expect(named[2].media == media)
    #expect(OpticalDrive.numberingDuplicateNames([OpticalDrive(id: 1, name: model, media: nil)]).first?.name == model)
}

@Test func aDriveThatCannotBeInspectedIsListedWithItsOwnError() throws {
    let model = "PIONEER BD-RW BDR-XS07U"
    let media = try audioMedia()
    let failed = OpticalDrive.inspecting(id: 7, name: nil) { throw OpticalDriveError(driveIssue) }
    #expect(failed == OpticalDrive(id: 7, name: "Optical drive 7", media: nil, issue: driveIssue))
    let healthy = OpticalDrive.inspecting(id: 8, name: model) { media }
    #expect(healthy == OpticalDrive(id: 8, name: model, media: media))
    let listed = OpticalDrive.numberingDuplicateNames([
        OpticalDrive.inspecting(id: 1, name: model) { throw OpticalDriveError(driveIssue) }, healthy
    ])
    #expect(listed.map(\.name) == ["\(model) (1)", "\(model) (2)"])
    #expect(listed.map(\.issue) == [driveIssue, nil])
    #expect(listed[1].media == media)
}

@Test @MainActor func oneFaultyDriveDoesNotHideTheOthers() async throws {
    let service = FakeOpticalService([faultyDrive(), opticalDrive(id: 2, media: try audioMedia(id: 20))])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    #expect(player.selectedDriveID == 2)
    #expect(player.statusText == "CD DETECTED")
    #expect(player.trackText == "03")
    #expect(player.errorDetail == nil)
    #expect(player.ejectEnabled)
    #expect(player.showsDriveSelector)
    #expect(player.driveSelectorLabel == "Switch to next optical drive")
    await player.useOpticalDrive(id: 1)
    #expect(player.statusText == "[ERR] Drive error")
    #expect(player.formatText.isEmpty)
    #expect(player.errorDetail == driveIssue)
    #expect(player.state == .failed)
    #expect(player.trackText == "00")
    #expect(player.timeText == "00:00")
    #expect(!player.isShowingDiscSummary)
    #expect(!player.ejectEnabled)
    #expect(!player.controlsEnabled)
    #expect(player.driveSelectorEnabled)
    try await player.shutdown()
}

@Test @MainActor func cyclingBackToAFaultyDriveRefreshesIt() async throws {
    let other = opticalDrive(id: 2)
    let service = FakeOpticalService([faultyDrive(), other])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    #expect(player.selectedDriveID == 1)
    #expect(player.statusText == "[ERR] Drive error")
    player.selectNextDrive()
    #expect(player.statusText == "DRIVE 2 OF 2")
    player.selectNextDrive()
    #expect(player.statusText == "DRIVE 1 OF 2")
    service.snapshot = OpticalSnapshot(drives: [opticalDrive(media: try audioMedia()), other])
    await player.commitDriveSelection()
    #expect(service.refreshes == 1)
    #expect(player.selectedDriveID == 1)
    #expect(player.statusText == "CD DETECTED")
    #expect(player.trackText == "03")
    #expect(player.errorDetail == nil)
    try await player.shutdown()
}

@Test @MainActor func aLoneDriveShowsTheRefreshIconOnlyForDriveDiscAndEjectErrors() async throws {
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    #expect(!player.showsDriveSelector)
    service.emit([faultyDrive()])
    #expect(player.statusText == "[ERR] Drive error")
    #expect(player.showsDriveSelector)
    #expect(player.driveSelectorEnabled)
    #expect(player.driveSelectorLabel == "Refresh optical drive")
    service.emit([opticalDrive(media: OpticalMedia(
        id: 11, bsdName: "disk4", contents: .unreadable("Malformed track table."), isMounted: false, isEjectable: true
    ))])
    #expect(player.statusText == "[ERR] Disc error")
    #expect(player.showsDriveSelector)
    service.emit([opticalDrive()])
    #expect(player.statusText == "NO DISC")
    #expect(!player.showsDriveSelector)

    service.emit([opticalDrive(media: try audioMedia())])
    service.ejectFailure = OpticalDriveError("The disc is in use.")
    await player.eject()
    #expect(player.errorDetail == "The disc is in use.")
    #expect(player.showsDriveSelector)
    player.selectNextDrive()
    await player.commitDriveSelection()
    #expect(player.errorDetail == nil)
    #expect(player.statusText == "CD DETECTED")
    #expect(!player.showsDriveSelector)
    try await player.shutdown()
}

@Test @MainActor func refreshingALoneDriveShowsDriveOneOfOneThenRescansIt() async throws {
    let service = FakeOpticalService([faultyDrive()])
    let player = PlayerModel.offline(
        engine: FakeEngine(), opticalService: service, driveSelectionDelay: .milliseconds(20)
    )
    player.startOpticalMonitoring()
    player.selectNextDrive()
    #expect(player.pendingDriveID == 1)
    #expect(player.statusText == "DRIVE 1 OF 1")
    #expect(player.trackText == "00")
    #expect(player.timeText == "00:00")
    #expect(player.displayAccessibilityLabel == "Selecting optical drive 1 of 1")
    #expect(player.showsDriveSelector)
    #expect(service.refreshes == 0)
    let deadline = ContinuousClock.now + .seconds(10)
    while player.isSelectingDrive, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(service.refreshes == 1)
    #expect(player.statusText == "[ERR] Drive error")
    #expect(player.showsDriveSelector)

    service.snapshot = OpticalSnapshot(drives: [opticalDrive(media: try audioMedia())])
    player.selectNextDrive()
    while player.isSelectingDrive, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(service.refreshes == 2)
    #expect(player.statusText == "CD DETECTED")
    #expect(player.trackText == "03")
    #expect(!player.showsDriveSelector)
    try await player.shutdown()
}

@Test @MainActor func aLoneDriveThatRecoversWhileWaitingIsNotRescannedAgain() async throws {
    let service = FakeOpticalService([faultyDrive()])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    player.selectNextDrive()
    let task = try #require(player.driveSelection)
    service.emit([opticalDrive(media: try audioMedia())])
    #expect(task.isCancelled)
    #expect(player.pendingDriveID == nil)
    #expect(!player.showsDriveSelector)
    #expect(player.statusText == "CD DETECTED")
    #expect(service.refreshes == 0)
    try await player.shutdown()
}

@Test @MainActor func leavingOneDriveKeepsTheChoiceOnlyWhenThatDriveShowsAnError() async throws {
    let working = opticalDrive(media: try audioMedia())
    let service = FakeOpticalService([working, faultyDrive(id: 2)])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    player.selectNextDrive()
    #expect(player.pendingDriveID == 2)
    service.emit([faultyDrive(id: 2)])
    #expect(player.pendingDriveID == 2)
    #expect(player.selectedDriveID == 2)
    #expect(player.statusText == "DRIVE 1 OF 1")

    service.emit([faultyDrive(), opticalDrive(id: 2)])
    #expect(player.statusText == "DRIVE 2 OF 2")
    service.emit([opticalDrive(id: 2)])
    #expect(player.pendingDriveID == nil)
    #expect(!player.showsDriveSelector)
    #expect(player.statusText == "NO DISC")
    #expect(service.refreshes == 0)
    try await player.shutdown()
}

@Test @MainActor func errorsShowOnlyAShortMessageOnTheStatusLine() async throws {
    let service = FakeOpticalService([faultyDrive()])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, driveSelectionDelay: .seconds(3600))
    player.startOpticalMonitoring()
    #expect(player.statusText == "[ERR] Drive error")
    #expect(player.errorSummary == "Drive error")
    #expect(player.errorDetail == driveIssue)
    player.selectNextDrive()
    #expect(player.statusText == "DRIVE 1 OF 1")
    #expect(player.errorSummary == nil)
    #expect(player.errorDetail == driveIssue)
    await player.commitDriveSelection()
    #expect(player.statusText == "[ERR] Drive error")

    service.emit([opticalDrive(media: OpticalMedia(
        id: 11, bsdName: "disk4", contents: .unreadable("Malformed track table."), isMounted: false, isEjectable: true
    ))])
    #expect(player.statusText == "[ERR] Disc error")
    service.emit([], error: "Cannot enumerate optical drives (IOKit status -536870211).")
    #expect(player.statusText == "[ERR] Drive error")
    service.emit([opticalDrive(media: try audioMedia())])
    #expect(player.statusText == "CD DETECTED")
    #expect(player.errorSummary == nil)

    service.ejectFailure = OpticalDriveError("The disc is in use.")
    await player.eject()
    #expect(player.statusText == "[ERR] Eject error")
    #expect(player.errorDetail == "The disc is in use.")
    await player.useOpticalDrive(id: 99)
    #expect(player.statusText == "[ERR] Drive error")
    #expect(player.errorDetail == "The selected optical drive was disconnected.")
    try await player.shutdown()
}

@MainActor
func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(try await condition()) {
        try #require(ContinuousClock.now < deadline, "The offline test condition did not become true before its deadline.")
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Test @MainActor func playOpensTheAudioCDOnceAndKeepsItWhilePaused() async throws {
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    let session = try #require(await player.openDiscSession())
    #expect(session.driveID == 1 && session.mediaID == 10)
    #expect(await player.openDiscSession() === session)
    #expect(opener.opens == [.init(mediaID: 10, driveID: 1, onMainThread: false)])
    #expect(player.statusText == "CD DETECTED")
    #expect(!player.isBusy)
    try await player.shutdown()
    #expect(opener.discs.first?.isClosed == true)
    #expect(player.discSession == nil)
}

@Test @MainActor func onlyTheSelectedAudioCDIsEverOpened() async throws {
    let opener = FakeDiscOpener()
    let service = FakeOpticalService()
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    #expect(await player.openDiscSession() == nil)
    service.emit([opticalDrive()])
    #expect(await player.openDiscSession() == nil)
    service.emit([opticalDrive(media: OpticalMedia(
        id: 10, bsdName: "disk4", contents: .dataCD, isMounted: true, isEjectable: true
    ))])
    #expect(await player.openDiscSession() == nil)
    service.emit([opticalDrive(media: try audioMedia())])
    await player.insertDemoDisc()
    #expect(await player.openDiscSession() == nil)
    #expect(opener.opens.isEmpty)
    try await player.shutdown()
}

@Test @MainActor func aRefusedDiscShowsAccessDeniedAndIsNotRetried() async throws {
    let refusal = CDReadError(
        .refused, "Cannot open the optical disc for reading: Operation not permitted (errno 1).", systemError: EPERM
    )
    let opener = FakeDiscOpener(failure: refusal)
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    #expect(await player.openDiscSession() == nil)
    #expect(player.statusText == "[ERR] Access denied")
    #expect(player.errorSummary == "Access denied")
    #expect(player.errorDetail == refusal.message)
    #expect(player.discSession == nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(opener.opens.count == 1)
    try await player.shutdown()
}

@Test @MainActor func aDifferentOrVanishedDiscShowsDiscError() async throws {
    let other = tocFixture([TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0)], leadOut: 1_000)])
    let mismatched = FakeDiscOpener(tableOfContents: other)
    let player = PlayerModel.offline(
        engine: FakeEngine(), opticalService: FakeOpticalService([opticalDrive(media: try audioMedia())]),
        discOpener: mismatched
    )
    player.startOpticalMonitoring()
    #expect(await player.openDiscSession() == nil)
    #expect(player.statusText == "[ERR] Disc error")
    #expect(mismatched.discs.first?.isClosed == true)

    let vanished = FakeDiscOpener(failure: CDReadError(.gone, "The selected disc was removed or replaced before it could be read."))
    let second = PlayerModel.offline(
        engine: FakeEngine(), opticalService: FakeOpticalService([opticalDrive(media: try audioMedia())]),
        discOpener: vanished
    )
    second.startOpticalMonitoring()
    #expect(await second.openDiscSession() == nil)
    #expect(second.statusText == "[ERR] Disc error")
    try await player.shutdown()
    try await second.shutdown()
}

@Test @MainActor func theDiscIsClosedBeforeItIsEjected() async throws {
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    try #require(await player.openDiscSession() != nil)
    var closedBeforeEject: Bool?
    service.onEject = { closedBeforeEject = opener.discs.first?.isClosed }
    await player.eject()
    #expect(closedBeforeEject == true)
    #expect(service.ejects.count == 1)
    #expect(player.discSession == nil)
    try await player.shutdown()
}

@Test @MainActor func removingOrReplacingTheDiscClosesItsSession() async throws {
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    try #require(await player.openDiscSession() != nil)
    service.emit([opticalDrive(media: try audioMedia(id: 11))])
    #expect(player.discSession == nil)
    try await waitUntil { opener.discs.first?.isClosed == true }
    #expect(opener.discs.first?.isClosed == true)
    let replacement = try #require(await player.openDiscSession())
    #expect(replacement.mediaID == 11)
    service.emit([opticalDrive()])
    #expect(player.discSession == nil)
    try await waitUntil { opener.discs.last?.isClosed == true }
    #expect(opener.discs.map(\.isClosed) == [true, true])
    try await player.shutdown()
}

@Test @MainActor func changingDriveOrSourceOrQuittingClosesTheSession() async throws {
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([
        opticalDrive(media: try audioMedia()), opticalDrive(id: 2, media: try audioMedia(id: 20))
    ])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    try #require(await player.openDiscSession()?.driveID == 1)
    await player.useOpticalDrive(id: 2)
    #expect(opener.discs[0].isClosed)
    try #require(await player.openDiscSession()?.driveID == 2)
    await player.insertDemoDisc()
    #expect(opener.discs[1].isClosed)
    #expect(player.discSession == nil)
    await player.useOpticalDrive()
    try #require(await player.openDiscSession()?.driveID == 2)
    try await player.shutdown()
    #expect(opener.discs[2].isClosed)
    #expect(opener.opens.map(\.driveID) == [1, 2, 2])
}

@Test @MainActor func aDiscReplacedOrQuitWhileOpeningIsClosedAndNotKept() async throws {
    let opener = FakeDiscOpener(delay: .milliseconds(300))
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    let opening = Task { await player.openDiscSession() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(player.statusText == "PREPARING")
    #expect(!player.ejectEnabled)
    service.emit([opticalDrive(media: try audioMedia(id: 11))])
    #expect(await opening.value == nil)
    #expect(player.discSession == nil)
    #expect(opener.discs.first?.isClosed == true)
    #expect(!player.isBusy)
    try await player.shutdown()

    let slow = FakeDiscOpener(delay: .milliseconds(300))
    let quitting = PlayerModel.offline(
        engine: FakeEngine(), opticalService: FakeOpticalService([opticalDrive(media: try audioMedia())]),
        discOpener: slow
    )
    quitting.startOpticalMonitoring()
    let pending = Task { await quitting.openDiscSession() }
    try await Task.sleep(for: .milliseconds(50))
    try await quitting.shutdown()
    #expect(slow.discs.first?.isClosed == true)
    #expect(await pending.value == nil)
}

@Test @MainActor func shutdownWaitsForAPendingDiscOpenWithoutRelyingOnItsCaller() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let opener = FakeDiscOpener(gate: gate)
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    let opening = Task { await player.openDiscSession() }
    try await waitUntil { gate.hasEntered }
    var returned = false
    let shutdown = Task {
        try await player.shutdown()
        #expect(opener.discs.first?.isClosed == true)
        returned = true
    }
    try await waitUntil { service.stopped }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!returned)
    #expect(opener.discs.isEmpty)
    gate.release()
    try await shutdown.value
    #expect(player.discSession == nil)
    #expect(await opening.value == nil)
}

@Test @MainActor func shutdownWaitsForDiscRemovalCleanupThatAlreadyStarted() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    try #require(await player.openDiscSession() != nil)
    let source = try #require(opener.discs.first)
    source.closeGate = gate
    service.emit([opticalDrive()])
    try await waitUntil { gate.hasEntered }
    #expect(player.discSession == nil)
    var returned = false
    let shutdown = Task {
        try await player.shutdown()
        #expect(source.isClosed)
        returned = true
    }
    try await waitUntil { service.stopped }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!returned)
    #expect(!source.isClosed)
    gate.release()
    try await shutdown.value
}

@Test @MainActor func ejectWaitsForThePreviousDiscsPendingClose() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let engine = FakeEngine()
    let player = PlayerModel.offline(engine: engine, opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    try #require(await player.openDiscSession() != nil)
    let source = try #require(opener.discs.first)
    source.closeGate = gate
    service.emit([opticalDrive(media: try audioMedia(id: 11))])
    try await waitUntil { gate.hasEntered }
    service.onEject = { #expect(source.isClosed) }
    let ejecting = Task { await player.eject() }
    try await waitUntil { player.isBusy }
    try await Task.sleep(for: .milliseconds(30))
    #expect(service.ejects.isEmpty)
    gate.release()
    await ejecting.value
    #expect(service.ejects.map(\.media) == [11])
    try await player.shutdown()
}

@Test @MainActor func aQueuedDiscOpenRevalidatesItsSelectionAfterThePreviousClose() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    try #require(await player.openDiscSession() != nil)
    let source = try #require(opener.discs.first)
    source.closeGate = gate
    service.emit([opticalDrive(media: try audioMedia(id: 11))])
    try await waitUntil { gate.hasEntered }
    let opening = Task { await player.openDiscSession() }
    try await waitUntil { player.isBusy }
    #expect(opener.opens.map(\.mediaID) == [10])
    service.emit([opticalDrive(media: try audioMedia(id: 12))])
    gate.release()
    #expect(await opening.value == nil)
    #expect(opener.opens.map(\.mediaID) == [10])
    #expect(await player.openDiscSession()?.mediaID == 12)
    #expect(opener.opens.map(\.mediaID) == [10, 12])
    try await player.shutdown()
}

@Test @MainActor func aFailedLateDiscOpenCannotOverwriteTheReplacementDiscsStatus() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let opener = FakeDiscOpener(failure: CDReadError(.gone, "The old disc was removed."), gate: gate)
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    let opening = Task { await player.openDiscSession() }
    try await waitUntil { gate.hasEntered }
    service.emit([opticalDrive(media: try audioMedia(id: 11))])
    gate.release()
    #expect(await opening.value == nil)
    #expect(player.statusText == "CD DETECTED")
    #expect(player.errorDetail == nil)
    #expect(player.discSession == nil)
    #expect(opener.opens.count == 1)
    try await player.shutdown()
}

@Test @MainActor func aDiscFailureCannotOverwriteAReplacementWhileAudioCleanupWaits() async throws {
    let opener = FakeDiscOpener(failure: CDReadError(.gone, "The old disc was removed."))
    let engine = FakeEngine()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: engine, opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    await engine.suspendStop()
    let opening = Task { await player.openDiscSession() }
    try await waitUntil { await engine.stopIsWaiting() }
    service.emit([opticalDrive(media: try audioMedia(id: 11))])
    await engine.resumeStop()
    #expect(await opening.value == nil)
    #expect(player.statusText == "CD DETECTED")
    #expect(player.errorDetail == nil)
    try await player.shutdown()
}

@Test @MainActor func cancellingADiscOpenClosesItsLateSessionWithoutRetrying() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let opener = FakeDiscOpener(gate: gate)
    let player = PlayerModel.offline(
        engine: FakeEngine(), opticalService: FakeOpticalService([opticalDrive(media: try audioMedia())]),
        discOpener: opener
    )
    player.startOpticalMonitoring()
    let opening = Task { await player.openDiscSession() }
    try await waitUntil { gate.hasEntered }
    opening.cancel()
    gate.release()
    #expect(await opening.value == nil)
    #expect(opener.discs.first?.isClosed == true)
    #expect(player.discSession == nil)
    #expect(player.errorDetail == nil)
    #expect(opener.opens.count == 1)
    try await player.shutdown()
}

@Test @MainActor func shutdownWaitsForADiscReadBeforeClosingItsSession() async throws {
    let gate = TestGate()
    defer { gate.release() }
    let opener = FakeDiscOpener()
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service, discOpener: opener)
    player.startOpticalMonitoring()
    let session = try #require(await player.openDiscSession())
    let source = try #require(opener.discs.first)
    source.readGate = gate
    let reading = Task { try await session.read(from: 0, count: 1, errorFlags: false) }
    try await waitUntil { gate.hasEntered }
    var returned = false
    let shutdown = Task {
        try await player.shutdown()
        #expect(source.isClosed)
        returned = true
    }
    try await waitUntil { service.stopped }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!returned)
    #expect(!source.isClosed)
    gate.release()
    #expect(try await reading.value.sectorCount == 1)
    try await shutdown.value
}

@Test @MainActor func opticalNotificationsDoNotInterruptDemoPlayback() async throws {
    let service = FakeOpticalService()
    let engine = FakeEngine()
    let player = PlayerModel.offline(engine: engine, automaticallyMonitor: false, opticalService: service)
    player.startOpticalMonitoring()
    await player.insertDemoDisc()
    await player.togglePlayback()
    await engine.setFrame(15 * Disc.sampleRate)
    await player.refreshPlayback()
    service.emit([opticalDrive(media: try audioMedia())])
    #expect(player.source == .demo)
    #expect(player.state == .playing)
    #expect(player.currentFrame == 15 * Disc.sampleRate)
    service.emit([], error: "Optical metadata unavailable.")
    #expect(player.state == .playing)
    #expect(player.errorDetail == nil)
    await player.eject()
    #expect(service.ejects.isEmpty)
    #expect(player.statusText == "NO DEMO DISC")
    try await player.shutdown()
}

@Test @MainActor func switchingToPhysicalModeStopsDemoAndRestoresAudioSession() async throws {
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let engine = FakeEngine()
    let player = PlayerModel.offline(engine: engine, automaticallyMonitor: false, opticalService: service)
    player.startOpticalMonitoring()
    await player.insertDemoDisc()
    await player.togglePlayback()
    let stopsBefore = await engine.stops
    await player.useOpticalDrive()
    #expect(await engine.stops == stopsBefore + 1)
    #expect(player.disc == Disc(tableOfContents: try CDTableOfContents(data: tocFixture())))
    #expect(player.statusText == "CD DETECTED")
    #expect(player.controlsEnabled)
    try await player.shutdown()
}

@Test @MainActor func staleDemoSnapshotCannotReplacePhysicalState() async throws {
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let engine = FakeEngine()
    let player = PlayerModel.offline(engine: engine, automaticallyMonitor: false, opticalService: service)
    player.startOpticalMonitoring()
    await player.insertDemoDisc()
    await player.togglePlayback()
    await engine.suspendSnapshot()
    let pending = Task { await player.refreshPlayback() }
    while !(await engine.snapshotIsWaiting()) { await Task.yield() }
    await player.useOpticalDrive()
    await engine.resumeSnapshot(at: 35 * Disc.sampleRate)
    await pending.value
    #expect(player.source == .opticalDrive)
    #expect(player.currentFrame == 0)
    #expect(player.trackText == "03")
    #expect(player.timeText == "00:30")
    try await player.shutdown()
}

@Test @MainActor func monitoringCanRetryStartupAndStopsOnShutdown() async throws {
    let service = FakeOpticalService()
    service.startFailure = OpticalDriveError("Cannot create notifications.")
    let player = PlayerModel.offline(engine: FakeEngine(), opticalService: service)
    player.startOpticalMonitoring()
    #expect(player.errorDetail == "Cannot create notifications.")
    #expect(player.statusText == "[ERR] Drive error")
    #expect(player.formatText.isEmpty)
    service.startFailure = nil
    player.refreshOpticalDrives()
    #expect(service.starts == 2)
    #expect(player.statusText == "NO DRIVE")
    try await player.shutdown()
    #expect(service.stopped)
    service.emit([opticalDrive(media: try audioMedia())])
    #expect(player.selectedDriveID == nil)
    #expect(!player.ejectEnabled)
}

@Test @MainActor func onlySuccessOrNotMountedAllowsEjectAfterUnmount() {
    #expect(DiskEjectRequest.mayEjectAfterUnmount(status: DAReturn(kDAReturnSuccess)))
    #expect(DiskEjectRequest.mayEjectAfterUnmount(status: DAReturn(truncatingIfNeeded: kDAReturnNotMounted)))
    for refusal in [
        kDAReturnBusy, kDAReturnNotPermitted, kDAReturnNotPrivileged, kDAReturnExclusiveAccess,
        kDAReturnNotFound, kDAReturnUnsupported, kDAReturnError
    ] {
        #expect(!DiskEjectRequest.mayEjectAfterUnmount(status: DAReturn(truncatingIfNeeded: refusal)))
    }
}

@Test @MainActor func nativeEjectRejectsUnreadyMediaBeforeContactingDiskArbitration() async {
    let service = MacOpticalDriveService()
    let media = OpticalMedia(id: 1, bsdName: nil, contents: .reading, isMounted: nil, isEjectable: true)
    do {
        try await service.eject(media: media, from: 1)
        Issue.record("Media without a device identifier must not be sent to Disk Arbitration.")
    } catch {
        #expect(error.localizedDescription == "The selected optical disc is not ready for ejection.")
    }
}

@Test @MainActor func theFormatLabelFollowsTheDetectedDiscFormat() async throws {
    let fourChannel = try CDTableOfContents(data: tocFixture([
        TOCSessionFixture(tracks: [TOCTrackFixture(number: 1, sector: 0, control: 8)], leadOut: 750)
    ]))
    let service = FakeOpticalService([opticalDrive(media: try audioMedia())])
    let player = PlayerModel.offline(engine: FakeEngine(), automaticallyMonitor: false, opticalService: service)
    player.startOpticalMonitoring()
    #expect(player.sourceFormat == .compactDisc)
    #expect(player.formatText == "44.1 kHz / 16-bit source")
    service.emit([opticalDrive(media: OpticalMedia(
        id: 11, bsdName: "disk4", contents: .audioCD(fourChannel), isMounted: false, isEjectable: true
    ))])
    #expect(player.sourceFormat == .compactDiscAudio(channels: 4))
    #expect(player.formatText == "44.1 kHz / 16-bit / 4-channel source")
    try await player.shutdown()
}
