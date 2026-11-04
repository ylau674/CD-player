@testable import AudioCheck
import CoreAudio
import Foundation
import Testing

@Suite struct OutputStateTests {
    private func format(rate: Double, channels: UInt32, floating: Bool = true) -> OutputStateFormat {
        OutputStateFormat(AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        ))
    }

    private func range(_ format: OutputStateFormat) -> OutputStateFormatRange {
        OutputStateFormatRange(format: format, rates: OutputStateRateRange(minimum: 44_100, maximum: 96_000))
    }

    private func baseline(rate: Double = 48_000) -> OutputStateSnapshot {
        let output = OutputStateStream(
            objectID: 10, direction: .output, startingChannel: 1,
            virtualFormat: format(rate: rate, channels: 8),
            physicalFormat: format(rate: rate, channels: 8, floating: false),
            virtualSettable: true, physicalSettable: true,
            availableVirtualFormats: [range(format(rate: 44_100, channels: 2))],
            availablePhysicalFormats: [range(format(rate: 44_100, channels: 2, floating: false))]
        )
        let target = OutputStateDevice(
            objectID: 1, uid: "output-a", name: "Test DAC", transport: kAudioDeviceTransportTypeUSB,
            alive: true, running: false, nominalRate: rate, nominalRateSettable: true,
            availableRates: [OutputStateRateRange(minimum: 44_100, maximum: 96_000)],
            hogOwner: -1, preferredStereoChannels: [1, 2], streams: [output],
            controls: ["output.volumeScalar.0": 0.4375, "output.mute.0": 0, "global.clockSource": 7]
        )
        let input = OutputStateStream(
            objectID: 20, direction: .input, startingChannel: 1,
            virtualFormat: format(rate: 48_000, channels: 1),
            physicalFormat: format(rate: 48_000, channels: 1, floating: false),
            virtualSettable: true, physicalSettable: true, availableVirtualFormats: nil, availablePhysicalFormats: nil
        )
        let microphone = OutputStateDevice(
            objectID: 2, uid: "input-a", name: "Test microphone", transport: kAudioDeviceTransportTypeUSB,
            alive: true, running: false, nominalRate: 48_000, nominalRateSettable: true,
            availableRates: [OutputStateRateRange(minimum: 48_000, maximum: 48_000)],
            hogOwner: nil, preferredStereoChannels: nil, streams: [input], controls: ["input.volumeScalar.0": 0.75]
        )
        return OutputStateSnapshot(
            captureID: UUID().uuidString, capturedAtUnixTime: 1_000,
            defaultOutputUID: target.uid, defaultSystemOutputUID: target.uid, defaultInputUID: microphone.uid,
            devices: [target, microphone]
        )
    }

    private func fresh(_ before: OutputStateSnapshot) -> OutputStateSnapshot {
        var observed = before
        observed.captureID = UUID().uuidString
        observed.capturedAtUnixTime += 1
        return observed
    }

    private func during(_ before: OutputStateSnapshot) -> OutputStateSnapshot {
        var observed = fresh(before)
        observed.devices[0].nominalRate = 44_100
        observed.devices[0].running = true
        for index in observed.devices[0].streams.indices {
            let stream = before.devices[0].streams[index]
            if stream.direction == .input { continue }
            if before.devices[0].outputs.count == 1, let pair = stream.stereoPair {
                observed.devices[0].streams[index].virtualFormat = pair.virtual
                observed.devices[0].streams[index].physicalFormat = pair.physical
            } else {
                observed.devices[0].streams[index].virtualFormat.sampleRate = 44_100
                observed.devices[0].streams[index].physicalFormat.sampleRate = 44_100
            }
        }
        return observed
    }

    private func issues(_ before: OutputStateSnapshot, _ observed: OutputStateSnapshot?,
                        _ phase: OutputStatePhase) throws -> [String] {
        try OutputStateVerification.issues(before: before, observed: observed, phase: phase, uid: "output-a")
    }

    @Test func parsesReadOnlyAndOfflineCommands() throws {
        #expect(try OutputStateCommand.parse(["--capture-output-state", "/tmp/before.json"]) ==
                .capture(path: "/tmp/before.json"))
        #expect(try OutputStateCommand.parse([
            "--verify-output-state", "before", "before.json", "--output-uid", "USB DAC UID"
        ]) == .verify(phase: .before, before: "before.json", observed: nil, uid: "USB DAC UID"))
        for phase in ["during", "crashed", "after"] {
            #expect(try OutputStateCommand.parse([
                "--verify-output-state", phase, "before.json", "observed.json", "--output-uid", "output-a"
            ]) != nil)
        }
        #expect(try OutputStateCommand.parse(["--recover-output-rates"]) == .recover)
        #expect(try OutputStateCommand.parse(["--list-outputs"]) == nil)
    }

    @Test func rejectsActivationAndAmbiguousArgumentsBeforeCapture() {
        let invalid = [
            ["--capture-output-state"],
            ["--capture-output-state", "--activate-silent"],
            ["--capture-output-state", "before.json", "--activate-silent", "--disc", "123"],
            ["--disc", "123", "--capture-output-state", "before.json"],
            ["--capture-output-state", "before.json", "--list-outputs"],
            ["--capture-output-state", "before.json", "--capture-output-state", "second.json"],
            ["--verify-output-state", "after", "before.json", "--output-uid", "output-a"],
            ["--verify-output-state", "before", "before.json", "--output-uid", "--activate-silent"],
            ["--verify-output-state", "before", "before.json", "--output-uid", "output-a", "--retry"],
            ["--verify-output-state", "unknown", "before.json", "--output-uid", "output-a"],
            ["--verify-output-state", "crashed", "before.json", "--output-uid", "output-a"],
            ["--recover-output-rates", "--disc", "123"],
            ["--recover-output-rates", "--recover-output-rates"],
            ["--capture-output-state", "before.json", "--recover-output-rates"]
        ]
        for arguments in invalid {
            #expect(throws: (any Error).self) { try OutputStateCommand.parse(arguments) }
        }
    }

    @Test func snapshotRoundTripPreservesEveryASBDField() throws {
        var before = baseline()
        before.devices[0].streams[0].physicalFormat.reserved = 17
        let data = try JSONEncoder().encode(before)
        let decoded = try JSONDecoder().decode(OutputStateSnapshot.self, from: data)
        #expect(decoded == before)
        try decoded.validate()
    }

    @Test func offlineCommandRunsOnWorkerAndPropagatesFailures() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdplayer-output-state-\(UUID().uuidString).json")
        try JSONEncoder().encode(baseline()).write(to: file, options: .withoutOverwriting)
        defer {
            do { try FileManager.default.removeItem(at: file) }
            catch { Issue.record(error) }
        }

        let before = OutputStateCommand.verify(phase: .before, before: file.path, observed: nil, uid: "output-a")
        try await before.run()
        let reused = OutputStateCommand.verify(phase: .after, before: file.path, observed: file.path, uid: "output-a")
        await #expect(throws: CheckError.self) { try await reused.run() }
        let missing = OutputStateCommand.verify(
            phase: .before, before: file.path + ".missing", observed: nil, uid: "output-a"
        )
        await #expect(throws: (any Error).self) { try await missing.run() }
    }

    @Test func captureRequiresTwoStableReadsAndPropagatesReadErrors() throws {
        let before = baseline()
        let second = fresh(before)
        var reads = 0
        let captured = try CoreAudioOutputState.capture {
            reads += 1
            return reads == 1 ? before : second
        }
        #expect(reads == 2)
        #expect(captured == second)

        reads = 0
        #expect(throws: (any Error).self) {
            try CoreAudioOutputState.capture {
                reads += 1
                var state = reads == 1 ? before : second
                state.devices[0].nominalRate = reads == 1 ? 48_000 : 44_100
                return state
            }
        }
        #expect(reads == 2)
        #expect(throws: (any Error).self) {
            try CoreAudioOutputState.capture { throw CheckError.failed("Injected property-read failure") }
        }
    }

    @Test func checksIdleSharedBaselineAndAdvertisedStereoPair() throws {
        let before = baseline()
        #expect(try issues(before, nil, .before).isEmpty)
        let pair = try #require(before.devices[0].streams[0].stereoPair)
        #expect(pair.virtual.sampleRate == 44_100)
        #expect(pair.virtual.channels == 2)
        #expect(pair.physical.channels == 2)
    }

    @Test func readinessRejectsBusyUnsupportedAndReadOnlyTargets() throws {
        let changes: [(inout OutputStateDevice) -> Void] = [
            { $0.running = true },
            { $0.alive = false },
            { $0.hogOwner = 4321 },
            { $0.availableRates = nil },
            { $0.availableRates = [OutputStateRateRange(minimum: 48_000, maximum: 96_000)] },
            { $0.nominalRateSettable = false },
            { $0.streams[0].physicalSettable = false },
            { $0.streams[0].virtualSettable = false },
            { $0.streams = [] },
            { $0.transport = kAudioDeviceTransportTypeBluetooth }
        ]
        for change in changes {
            var before = baseline()
            change(&before.devices[0])
            #expect(try !issues(before, nil, .before).isEmpty)
        }
        #expect(try !OutputStateVerification.issues(
            before: baseline(), observed: nil, phase: .before, uid: "missing"
        ).isEmpty)
    }

    @Test func checksDuringAdvertisedStereoAndExactRestoration() throws {
        let before = baseline()
        #expect(try issues(before, during(before), .during).isEmpty)
        #expect(try issues(before, fresh(before), .after).isEmpty)
    }

    @Test func duringRejectsWrongRateUnstartedOutputAndWrongFormats() throws {
        let before = baseline()
        let changes: [(inout OutputStateDevice) -> Void] = [
            { $0.nominalRate = 48_000 },
            { $0.running = false },
            { $0.streams[0].virtualFormat.channels = 8 },
            { $0.streams[0].physicalFormat.bitsPerChannel = 16 },
            { $0.streams[0].physicalFormat.flags ^= kAudioFormatFlagIsAlignedHigh },
            { $0.streams[0].virtualFormat.bytesPerPacket += 4 }
        ]
        for change in changes {
            var active = during(before)
            change(&active.devices[0])
            #expect(try !issues(before, active, .during).isEmpty)
        }
    }

    @Test func crashedRequiresIdleTargetLeftInTheAppliedFormat() throws {
        let before = baseline()
        var crashed = during(before)
        crashed.devices[0].running = false
        #expect(try issues(before, crashed, .crashed).isEmpty)
        // Still running means the process was not killed; an original format means nothing remains to recover.
        #expect(try !issues(before, during(before), .crashed).isEmpty)
        #expect(try !issues(before, fresh(before), .crashed).isEmpty)
        var otherChanged = crashed
        otherChanged.defaultOutputUID = "other"
        #expect(try !issues(before, otherChanged, .crashed).isEmpty)
    }

    @Test func parsesSavedRecoveryRecordsWithoutChangingThem() throws {
        #expect(try RecoveryRecords.parse(nil).isEmpty)
        let format = Data(count: MemoryLayout<AudioStreamBasicDescription>.size)
        let records = try RecoveryRecords.parse([
            ["uid": "output-a", "originalRate": 384_000.0, "appliedRate": 44_100.0,
             "originalVirtualFormat": format, "appliedVirtualFormat": format,
             "originalPhysicalFormat": format, "appliedPhysicalFormat": format],
            ["uid": "output-b", "originalRate": 48_000, "appliedRate": 44_100]
        ] as [Any])
        #expect(records == [
            RecoveryRecord(uid: "output-a", originalRate: 384_000, appliedRate: 44_100, hasFormatChange: true),
            RecoveryRecord(uid: "output-b", originalRate: 48_000, appliedRate: 44_100, hasFormatChange: false)
        ])
        #expect(RecoveryRecords.summary("Saved", records).contains("output-a: original 384000.0 Hz"))
        #expect(RecoveryRecords.summary("Saved", []) == "Saved: none.")
        for malformed: Any in ["text", [["uid": "", "originalRate": 1, "appliedRate": 2]],
                               [["uid": "output-a", "originalRate": 48_000]]] {
            #expect(throws: CheckError.self) { try RecoveryRecords.parse(malformed) }
        }
    }

    @Test func restoringOnlyTheRateDoesNotPassTheAfterCheck() throws {
        let before = baseline()
        var after = during(before)
        after.devices[0].nominalRate = before.devices[0].nominalRate
        after.devices[0].running = false
        let failures = try issues(before, after, .after)
        #expect(failures.contains { $0.contains("virtual format differs") })
        #expect(failures.contains { $0.contains("physical format differs") })
    }

    @Test func afterComparesCompleteASBDNotJustRateAndChannels() throws {
        let before = baseline()
        let changes: [(inout OutputStateFormat) -> Void] = [
            { $0.flags ^= kAudioFormatFlagIsNonInterleaved },
            { $0.bitsPerChannel = 24 },
            { $0.bytesPerFrame += 4 },
            { $0.bytesPerPacket += 4 },
            { $0.framesPerPacket += 1 },
            { $0.reserved += 1 }
        ]
        for change in changes {
            var after = fresh(before)
            change(&after.devices[0].streams[0].physicalFormat)
            #expect(try !issues(before, after, .after).isEmpty)
        }
    }

    @Test func protectsControlsDefaultRoutesAndOtherDevices() throws {
        let before = baseline()
        let changes: [(inout OutputStateSnapshot) -> Void] = [
            { $0.devices[0].controls["output.volumeScalar.0"] = 0.5 },
            { $0.devices[0].controls["output.mute.0"] = 1 },
            { $0.devices[0].controls["global.clockSource"] = 8 },
            { $0.devices[0].controls["output.volumeScalar.0"] = nil },
            { $0.devices[0].preferredStereoChannels = [2, 1] },
            { $0.defaultOutputUID = "input-a" },
            { $0.defaultSystemOutputUID = "input-a" },
            { $0.defaultInputUID = nil },
            { $0.devices[1].nominalRate = 44_100 },
            { $0.devices[1].streams[0].physicalFormat.sampleRate = 44_100 },
            { $0.devices[1].running = true },
            { $0.devices.removeLast() }
        ]
        for change in changes {
            var active = during(before)
            change(&active)
            #expect(try !issues(before, active, .during).isEmpty)
        }
    }

    @Test func preservesInputStreamsOnDuplexTarget() throws {
        var before = baseline()
        before.devices[0].streams.append(before.devices[1].streams[0])
        var active = during(before)
        #expect(try issues(before, active, .during).isEmpty)
        active.devices[0].streams[1].virtualFormat.sampleRate = 44_100
        #expect(try !issues(before, active, .during).isEmpty)
    }

    @Test func preservesUserKept44100Hz() throws {
        let before = baseline(rate: 44_100)
        #expect(try issues(before, during(before), .during).isEmpty)
        #expect(try issues(before, fresh(before), .after).isEmpty)
        var wrong = fresh(before)
        wrong.devices[0].nominalRate = 48_000
        #expect(try !issues(before, wrong, .after).isEmpty)
    }

    @Test func fallbackRetainsMultichannelPCMWhenNoStereoPairIsAdvertised() throws {
        var before = baseline()
        before.devices[0].streams[0].availablePhysicalFormats = nil
        #expect(before.devices[0].streams[0].stereoPair == nil)
        let active = during(before)
        #expect(active.devices[0].streams[0].virtualFormat.channels == 8)
        #expect(try issues(before, active, .during).isEmpty)
        var wrong = active
        wrong.devices[0].streams[0].virtualFormat = format(rate: 44_100, channels: 2)
        wrong.devices[0].streams[0].physicalFormat = format(rate: 44_100, channels: 2, floating: false)
        #expect(try !issues(before, wrong, .during).isEmpty)
    }

    @Test func multiStreamRouteDoesNotExpectTheSingleStreamStereoPreference() throws {
        var before = baseline()
        var second = before.devices[0].streams[0]
        second.objectID = 11
        second.startingChannel = 9
        before.devices[0].streams.append(second)
        #expect(try issues(before, during(before), .during).isEmpty)
        var wrong = during(before)
        wrong.devices[0].streams.removeLast()
        #expect(try !issues(before, wrong, .during).isEmpty)
    }

    @Test func matchesUIDAndStreamPositionRatherThanEphemeralObjectIDsOrOrder() throws {
        let before = baseline()
        var after = fresh(before)
        after.devices[0].objectID = 101
        after.devices[0].streams[0].objectID = 110
        after.devices.reverse()
        #expect(try issues(before, after, .after).isEmpty)
    }

    @Test func rejectsInvalidDuplicateAndStaleSnapshots() {
        let before = baseline()
        var invalid = before
        invalid.schemaVersion = 2
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = before
        invalid.devices.append(invalid.devices[0])
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = before
        invalid.devices[0].streams.append(invalid.devices[0].streams[0])
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = before
        invalid.devices[0].nominalRate = .nan
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(throws: (any Error).self) { try issues(before, before, .after) }
        #expect(throws: (any Error).self) { try issues(before, nil, .during) }
        invalid = fresh(before)
        invalid.capturedAtUnixTime = before.capturedAtUnixTime - 1
        #expect(throws: (any Error).self) { try issues(before, invalid, .after) }
    }
}
