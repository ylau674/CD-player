import CDKit
import Darwin
import Foundation

@main
struct OpticalCheck {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            fflush(stdout)
            FileHandle.standardError.write(Data("OpticalCheck: \(error.localizedDescription)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run() async throws {
        var watchSeconds = 0.0
        var ejectDrive: UInt64?
        var readCheckDrive: UInt64?
        var watchWasSpecified = false
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let option = arguments.removeFirst()
            guard !arguments.isEmpty else { throw usage }
            let value = arguments.removeFirst()
            switch option {
            case "--watch":
                guard let seconds = Double(value), seconds.isFinite, (0...3_600).contains(seconds) else {
                    throw usage
                }
                watchSeconds = seconds
                watchWasSpecified = true
            case "--eject":
                guard let id = UInt64(value) else { throw usage }
                ejectDrive = id
            case "--read-check":
                guard let id = UInt64(value), readCheckDrive == nil else { throw usage }
                readCheckDrive = id
            default:
                throw usage
            }
        }
        guard readCheckDrive == nil || (!watchWasSpecified && ejectDrive == nil) else { throw usage }

        let service = MacOpticalDriveService()
        var latest = OpticalSnapshot()
        try service.start { snapshot in
            latest = snapshot
            printSnapshot(snapshot)
        }
        defer { service.stop() }
        if let readCheckDrive {
            try await runReadCheck(driveID: readCheckDrive, snapshot: latest)
            return
        }
        if let ejectDrive {
            guard let drive = latest.drives.first(where: { $0.id == ejectDrive }), let media = drive.media else {
                throw OpticalDriveError("That optical drive has no media available for eject.")
            }
            try await service.eject(media: media, from: drive.id)
            print("Optical disc eject completed.")
        }
        if watchSeconds > 0 { try await Task.sleep(for: .seconds(watchSeconds)) }
        if let error = latest.errorMessage { throw OpticalDriveError(error) }
        if let drive = latest.drives.first(where: { $0.issue != nil }), let issue = drive.issue {
            throw OpticalDriveError("Drive \(drive.id): \(issue)")
        }
    }

    private static var usage: OpticalDriveError {
        OpticalDriveError(
            "Usage: OpticalCheck [--watch <0...3600 seconds>] [--eject <drive registry ID>] | " +
            "OpticalCheck --read-check <drive registry ID>"
        )
    }

    @MainActor
    private static func runReadCheck(driveID: UInt64, snapshot: OpticalSnapshot) async throws {
        if let error = snapshot.errorMessage { throw OpticalDriveError(error) }
        guard let drive = snapshot.drives.first(where: { $0.id == driveID }) else {
            throw OpticalDriveError("No optical drive with registry ID \(driveID) is available.")
        }
        if let issue = drive.issue {
            throw OpticalDriveError("Drive \(driveID) is unavailable: \(issue)")
        }
        guard let media = drive.media, let table = media.contents.tableOfContents else {
            throw OpticalDriveError("Drive \(driveID) does not contain a readable audio CD.")
        }
        guard let bsdName = media.bsdName else {
            throw OpticalDriveError("Drive \(driveID) does not have a whole-disc device identifier.")
        }

        print("Drive \(drive.id): \(drive.name), media \(media.id), \(bsdName)")
        let session = try await DiscSession.open(
            media, driveID: driveID, tableOfContents: table, opener: RawDiscOpener()
        )
        var checkError: (any Error)?
        do {
            try await performReadCheck(session: session, table: table, drive: drive, media: media)
        } catch {
            checkError = error
        }

        let closeReport = await session.close()
        if closeReport.speedChangeAttempted {
            if closeReport.speedRestored, let restored = closeReport.restoredSpeed {
                print("PASS: drive speed restored and verified at \(restored) kB/s.")
            } else {
                print("FAIL: drive speed restoration could not be verified: " +
                      (closeReport.speedRestoreError ?? "unknown restoration error"))
                if checkError == nil {
                    checkError = OpticalDriveError(
                        closeReport.speedRestoreError ?? "The original drive speed was not restored."
                    )
                }
            }
        } else {
            print("Drive speed unchanged; no restoration was needed.")
        }
        if let checkError { throw checkError }
    }

    private static func performReadCheck(
        session: DiscSession, table: CDTableOfContents, drive: OpticalDrive, media: OpticalMedia
    ) async throws {
        print("PASS: drive \(drive.id) and whole-disc media \(media.id) identity revalidated.")
        print("PASS: device TOC matches the registry TOC (\(table.audioTracks.count) audio / " +
              "\(table.tracks.count) total tracks).")

        let features = await session.readFeatures
        if let value = features.cdFeatures {
            print(String(
                format: "CD features: 0x%08x; stream-accurate reads: %@",
                value, features.streamAccurate ? "yes" : "no"
            ))
        } else {
            print("CD features unavailable; stream-accurate reads: unknown.")
        }

        guard let track = table.audioTracks.max(by: { $0.sectorCount < $1.sectorCount }),
              track.sectorCount > 0 else {
            throw OpticalDriveError("The audio CD has no readable audio track.")
        }
        let blockCount = Int(min(UInt64(16), track.sectorCount))
        let readStart = track.startSector + min(UInt64(8), track.sectorCount - UInt64(blockCount))

        let c2Probe = try await session.probeC2(at: readStart)
        var c2Counts = C2Counts()
        c2Counts.record(c2Probe)
        let usesC2 = c2Probe.support == .supported
        switch c2Probe.support {
        case .supported:
            print("PASS: C2 probe supported; \(c2Probe.flaggedAudioBytes) flagged audio bytes in " +
                  "\(c2Probe.flaggedSectors) probe sectors.")
        case .unsupported:
            print("C2 probe unsupported; the identical plain read succeeded.")
        case .unknown:
            throw OpticalDriveError("The C2 probe did not determine whether C2 reads are supported.")
        }

        do {
            let original = try await session.speed()
            guard original > 0 else {
                throw CDReadError(.failed, "The drive reported an unknown speed; no speed change was made.")
            }
            let request = RawCDReader.minimumSpeed
            try await session.setSpeed(request)
            let reported = try await session.speed()
            print("Speed: original \(original) kB/s; requested \(request) kB/s; " +
                  "reported \(reported) kB/s. Readback is not measured throughput.")
        } catch let error as CDReadError where error.kind == .failed || error.kind == .mediaError {
            print("Speed request/readback unavailable: \(error.message); continuing with read checks.")
        }

        let repeated = try await session.read(from: readStart, count: blockCount, errorFlags: usesC2)
        try c2Counts.record(repeated)
        let repeatedAgain = try await session.read(from: readStart, count: blockCount, errorFlags: usesC2)
        try c2Counts.record(repeatedAgain)
        let firstChecksum = PCMChecksum.appending(repeated.audio)
        let repeatChecksum = PCMChecksum.appending(repeatedAgain.audio)
        guard firstChecksum == repeatChecksum, repeated.audio == repeatedAgain.audio else {
            throw OpticalDriveError("Repeated audio reads differ: \(PCMChecksum.hexadecimal(firstChecksum)) vs " +
                                    "\(PCMChecksum.hexadecimal(repeatChecksum)).")
        }
        print("PASS: repeated \(blockCount)-sector reads match, checksum \(PCMChecksum.hexadecimal(firstChecksum)).")
        print("CD-DA little-endian stereo decode: \(try sampleDescription(repeated.audio)).")

        let overlapOffset = blockCount / 2
        let overlapStart = readStart + UInt64(overlapOffset)
        let overlapCount = Int(min(UInt64(blockCount), track.startSector + track.sectorCount - overlapStart))
        let overlapping = try await session.read(from: overlapStart, count: overlapCount, errorFlags: usesC2)
        try c2Counts.record(overlapping)
        let overlapSectors = min(blockCount - overlapOffset, overlapCount)
        let overlapBytes = overlapSectors * CDSectorBlock.audioBytes
        let firstRange = (overlapOffset * CDSectorBlock.audioBytes)..<(overlapOffset * CDSectorBlock.audioBytes + overlapBytes)
        let firstOverlap = repeated.audio.subdata(in: firstRange)
        let secondOverlap = overlapping.audio.prefix(overlapBytes)
        let firstOverlapChecksum = PCMChecksum.appending(firstOverlap)
        let secondOverlapChecksum = PCMChecksum.appending(Data(secondOverlap))
        guard firstOverlapChecksum == secondOverlapChecksum, firstOverlap == Data(secondOverlap) else {
            throw OpticalDriveError("Overlapping reads differ: \(PCMChecksum.hexadecimal(firstOverlapChecksum)) vs " +
                                    "\(PCMChecksum.hexadecimal(secondOverlapChecksum)).")
        }
        print("PASS: \(overlapSectors)-sector overlapping reads match, checksum " +
              "\(PCMChecksum.hexadecimal(firstOverlapChecksum)).")

        let sustainedTracks = table.audioTracks.sorted { $0.startSector < $1.startSector }
        let maximumSustainedSectors: UInt64 = 75_000
        let before = await session.readStatistics
        var sustainedTrackIndex = 0
        var nextSector = sustainedTracks[0].startSector
        var sustainedSectors: UInt64 = 0
        var after = before
        while after.readDuration - before.readDuration < .seconds(5),
              sustainedSectors < maximumSustainedSectors {
            let sustainedTrack = sustainedTracks[sustainedTrackIndex]
            let trackEnd = sustainedTrack.startSector + sustainedTrack.sectorCount
            if nextSector >= trackEnd {
                sustainedTrackIndex += 1
                guard sustainedTrackIndex < sustainedTracks.count else { break }
                nextSector = sustainedTracks[sustainedTrackIndex].startSector
                continue
            }
            let remaining = trackEnd - nextSector
            let count = Int(min(UInt64(37), min(remaining, maximumSustainedSectors - sustainedSectors)))
            let block = try await session.read(from: nextSector, count: count, errorFlags: usesC2)
            try c2Counts.record(block)
            nextSector += UInt64(count)
            sustainedSectors += UInt64(count)
            after = await session.readStatistics
        }
        let measuredBytes = after.audioBytes - before.audioBytes
        let measuredDuration = after.readDuration - before.readDuration
        let seconds = durationSeconds(measuredDuration)
        guard seconds >= 5 else {
            throw OpticalDriveError(
                "The audio tracks ended or the \(maximumSustainedSectors)-sector limit was reached before " +
                "five seconds of sustained raw reads."
            )
        }
        print(String(
            format: "PASS: sustained raw reads: %llu sectors, %llu audio bytes in %.3f s; %.1f kB/s.",
            sustainedSectors, measuredBytes, seconds,
            Double(measuredBytes) / 1_000 / seconds
        ))
        if usesC2 {
            print("C2 totals: \(c2Counts.flaggedAudioByteObservations) flagged audio-byte observations across " +
                  "\(c2Counts.flaggedSectorObservations) flagged sector observations.")
        } else {
            print("C2 counts unavailable: the drive does not support C2 reads.")
        }
    }

    private static func sampleDescription(_ audio: Data) throws -> String {
        guard audio.count >= 4 else {
            throw OpticalDriveError("The audio read was too short to inspect a stereo sample.")
        }
        let left = Int16(bitPattern: UInt16(audio[0]) | UInt16(audio[1]) << 8)
        let right = Int16(bitPattern: UInt16(audio[2]) | UInt16(audio[3]) << 8)
        return String(
            format: "bytes %02x %02x %02x %02x => L=%d, R=%d",
            audio[0], audio[1], audio[2], audio[3], Int(left), Int(right)
        )
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private struct C2Counts {
        var flaggedAudioByteObservations: UInt64 = 0
        var flaggedSectorObservations: UInt64 = 0

        mutating func record(_ probe: C2ProbeResult) {
            flaggedAudioByteObservations += probe.flaggedAudioBytes
            flaggedSectorObservations += probe.flaggedSectors
        }

        mutating func record(_ block: CDSectorBlock) throws {
            guard let flags = block.errorFlags else { return }
            guard flags.count == block.sectorCount * CDSectorBlock.errorFlagBytes else {
                throw OpticalDriveError("The drive returned an incomplete C2 flag block.")
            }
            flaggedAudioByteObservations += UInt64(flags.reduce(0) { $0 + $1.nonzeroBitCount })
            for offset in stride(from: flags.startIndex, to: flags.endIndex, by: CDSectorBlock.errorFlagBytes) {
                let end = offset + CDSectorBlock.errorFlagBytes
                if flags[offset..<end].contains(where: { $0 != 0 }) { flaggedSectorObservations += 1 }
            }
        }
    }

    private static func printSnapshot(_ snapshot: OpticalSnapshot) {
        if let error = snapshot.errorMessage { print("ERROR: \(error)") }
        if snapshot.drives.isEmpty { print("No optical drive detected.") }
        for drive in snapshot.drives {
            print("Drive \(drive.id): \(drive.name)")
            if let issue = drive.issue {
                print("  Drive error: \(issue)")
                continue
            }
            guard let media = drive.media else {
                print("  No disc.")
                continue
            }
            let mount = media.isMounted.map { $0 ? "mounted" : "not mounted" } ?? "mount state unknown"
            print("  Media \(media.id): \(media.bsdName ?? "device pending"), \(mount), ejectable=\(media.isEjectable)")
            switch media.contents {
            case .reading: print("  Reading disc metadata.")
            case .audioCD(let table):
                print("  Audio CD: \(table.audioTracks.count) audio / \(table.tracks.count) total tracks, lead-out \(table.leadOutSector)")
                let timeline = Disc(tableOfContents: table)
                let seconds = timeline.totalFrames / Disc.sampleRate
                print("  Playback timeline: \(timeline.tracks.count) tracks, \(timeline.sectorCount) sectors, " +
                      "\(timeline.totalFrames) frames (\(String(format: "%02llu:%02llu", seconds / 60, seconds % 60)))")
                for track in table.tracks {
                    print("    Track \(track.number), session \(track.session), \(track.isAudio ? "audio" : "DATA"), " +
                          "LBA \(track.startSector), \(track.sectorCount) sectors, pre-emphasis=\(track.hasPreEmphasis)")
                }
            case .dataCD: print("  Data-only CD.")
            case .other(let type): print("  Non-audio media: \(type)")
            case .unreadable(let error): print("  Unreadable track metadata: \(error)")
            }
        }
    }
}
