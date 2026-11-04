import CDKit
import Darwin
import Foundation

enum CheckError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let reason): reason
        }
    }
}

@main
struct AudioCheck {
    /// The checks verify the Red Book CD-DA path: 44.1 kHz, 16-bit stereo.
    private static let sourceFormat = AudioSourceFormat.compactDisc
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            fflush(stdout)
            FileHandle.standardError.write(Data("AudioCheck: \(error.localizedDescription)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        if let command = try PCMCaptureCommand.parse(Array(CommandLine.arguments.dropFirst())) {
            try await command.run()
            return
        }
        if let command = try OutputStateCommand.parse(Array(CommandLine.arguments.dropFirst())) {
            try await command.run()
            return
        }
        var discID: UInt64?
        var outputUID: String?
        var listOutputs = false
        var inspectSystemDefault = false
        var activateSilent = false
        var comparePacing = false
        var observation: ObservationWindow?
        var retryPolicy: DiscRetryPolicy?
        var decodeHDCD = true
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let option = arguments.removeFirst()
            switch option {
            case "--output-uid":
                guard !arguments.isEmpty, outputUID == nil else { throw usage }
                let uid = arguments.removeFirst()
                guard !uid.isEmpty, !uid.hasPrefix("--") else { throw usage }
                outputUID = uid
            case "--list-outputs":
                guard !listOutputs else { throw usage }
                listOutputs = true
            case "--system-default":
                guard !inspectSystemDefault else { throw usage }
                inspectSystemDefault = true
            case "--disc":
                guard !arguments.isEmpty, discID == nil, let id = UInt64(arguments.removeFirst()) else {
                    throw usage
                }
                discID = id
            case "--activate-silent":
                guard !activateSilent else { throw usage }
                activateSilent = true
            case "--compare-pacing":
                guard !comparePacing else { throw usage }
                comparePacing = true
            case "--observe":
                guard observation == nil, arguments.count >= 2,
                      let start = Double(arguments.removeFirst()), let length = Double(arguments.removeFirst()),
                      start.isFinite, start >= 0, length.isFinite, (1...900).contains(length) else {
                    throw usage
                }
                observation = ObservationWindow(startSeconds: start, seconds: length)
            case "--retry":
                guard retryPolicy == nil else { throw usage }
                retryPolicy = .retry
            case "--hdcd-off":
                guard decodeHDCD else { throw usage }
                decodeHDCD = false
            default:
                throw usage
            }
        }
        guard observation == nil || (activateSilent && !comparePacing) else { throw usage }
        guard retryPolicy == nil || observation != nil else { throw usage }
        guard decodeHDCD || activateSilent else { throw usage }
        if listOutputs {
            guard outputUID == nil, !inspectSystemDefault, discID == nil, !activateSilent,
                  !comparePacing, observation == nil else {
                throw usage
            }
            for output in try await CoreAudioOutputRateControl().discoverOutputs(format: sourceFormat) {
                print("\(output.name) (\(output.transport.title))\(output.isDefaultOutput ? " [system default]" : "")")
                print("  UID: \(output.id)")
                print("  \(output.sampleRate) Hz; native 44.1 kHz: \(output.supportsSourceRate); " +
                      "stereo: \(output.hasStereoOutput); hog owner: \(output.hogOwner); " +
                      "host volume: \(output.hasVolumeControl)")
                if let reason = output.disabledReason { print("  Unavailable: \(reason)") }
            }
            print("Read-only output discovery; no audio or disc access.")
            return
        }
        guard !inspectSystemDefault || (
            outputUID == nil && discID == nil && !activateSilent && !comparePacing &&
            observation == nil && retryPolicy == nil
        ) else { throw usage }
        let target: OutputTarget = inspectSystemDefault
            ? .systemDefault
            : outputUID.map { .device(uid: $0) } ?? .builtIn

        guard activateSilent else {
            guard discID == nil, !comparePacing else { throw usage }
            let engine = CoreAudioPlaybackEngine(disc: .silentCheck)
            let info = try await engine.inspectOutput(on: target, format: sourceFormat)
            let targetName: String
            switch target {
            case .builtIn: targetName = "Built-in"
            case .systemDefault: targetName = "System Default"
            case .device: targetName = "Selected"
            }
            print("\(targetName) output: \(info.name)")
            print("UID: \(info.uid), \(info.outputChannels) output channels")
            print("Sample rate: \(info.sampleRate) Hz, hog owner \(info.hogOwner)")
            print("Already running: \(info.isRunning)")
            print("Native 44.1 kHz: \(info.supportsSourceRate), default output (volume keys): \(info.isDefaultOutput)")
            if let latency = info.streamLatencySeconds {
                let frames = String(format: "%.0f", latency * info.sampleRate)
                let rate = String(format: "%.0f", info.sampleRate)
                let seconds = String(format: "%.3f", latency)
                print("Output stream latency: \(frames) frames at \(rate) Hz (\(seconds) s)")
            } else {
                print("Output stream latency: unavailable")
            }
            print("Read-only inspection; no audio or disc access.")
            return
        }
        guard let discID else { throw usage }
        try await runSilentDiscCheck(
            driveID: discID, target: target, comparePacing: comparePacing,
            observation: observation, retryPolicy: retryPolicy, decodeHDCD: decodeHDCD
        )
    }

    private static var usage: CheckError {
        .failed(
            "Usage: AudioCheck --list-outputs | [--system-default | --output-uid <wired output UID>] " +
            "[--disc <drive registry ID> --activate-silent [--hdcd-off] " +
            "[--compare-pacing | --observe <start seconds> <1...900 seconds> [--retry]]]\n" +
            OutputStateCommand.usage + "\n" + PCMCaptureCommand.usage
        )
    }

    @MainActor
    private static func runSilentDiscCheck(
        driveID: UInt64, target: OutputTarget, comparePacing: Bool,
        observation: ObservationWindow?, retryPolicy: DiscRetryPolicy?, decodeHDCD: Bool
    ) async throws {
        let service = MacOpticalDriveService()
        var latest = OpticalSnapshot()
        try service.start { snapshot in latest = snapshot }
        defer { service.stop() }
        if let message = latest.errorMessage { throw OpticalDriveError(message) }
        guard let drive = latest.drives.first(where: { $0.id == driveID }) else {
            throw OpticalDriveError("No optical drive with registry ID \(driveID) is available.")
        }
        if let issue = drive.issue {
            throw OpticalDriveError("Drive \(driveID) is unavailable: \(issue)")
        }
        guard let media = drive.media, let table = media.contents.tableOfContents else {
            throw OpticalDriveError("Drive \(driveID) does not contain a readable audio CD.")
        }

        let session = try await DiscSession.open(
            media, driveID: driveID, tableOfContents: table, opener: RawDiscOpener()
        )
        var checkError: (any Error)?
        print(decodeHDCD
            ? "HDCD decoding: on, the app's default (effectual HDCD is decoded on outputs of 20 bits or more)."
            : "HDCD decoding: off (--hdcd-off); HDCD is still detected and every sample passes through.")
        do {
            if let observation {
                // Without --retry, keep the session's default policy: the one the app plays with.
                if let retryPolicy { await session.setRetryPolicy(retryPolicy) }
                try await observePlayback(
                    session: session, target: target, window: observation, decodeHDCD: decodeHDCD
                )
            } else {
                try await performSilentCheck(
                    session: session, target: target, table: table, comparePacing: comparePacing,
                    decodeHDCD: decodeHDCD
                )
            }
        } catch {
            checkError = error
        }

        let closeReport = await session.close()
        if closeReport.speedChangeAttempted {
            if closeReport.speedRestored, let restored = closeReport.restoredSpeed {
                print("PASS: original drive speed restored and verified at \(restored) kB/s.")
            } else {
                let message = closeReport.speedRestoreError ?? "The original drive speed was not restored."
                print("FAIL: drive speed restoration could not be verified: \(message)")
                if checkError == nil { checkError = CheckError.failed(message) }
            }
        } else if checkError == nil {
            let message = "Playback did not request a drive speed, so restoration was not exercised."
            print("FAIL: \(message)")
            checkError = CheckError.failed(message)
        }
        if let checkError { throw checkError }
    }

    private static func performSilentCheck(
        session: DiscSession, target: OutputTarget, table: CDTableOfContents, comparePacing: Bool,
        decodeHDCD: Bool
    ) async throws {
        let disc = session.disc
        let minimumSeconds = comparePacing ? 50 : 30
        let requiredFrames = UInt64(minimumSeconds) * Disc.sampleRate
        guard disc.totalFrames >= requiredFrames, disc.tracks.count >= 2 else {
            throw CheckError.failed(
                "The disc needs at least \(minimumSeconds) seconds and two audio tracks for this check."
            )
        }

        let originalDriveSpeed = try await session.speed()
        guard originalDriveSpeed > 0 else {
            throw CheckError.failed("The drive reported an unknown speed; no silent audio test was started.")
        }
        print("Drive: \(session.driveID), media: \(session.mediaID), " +
              "\(table.audioTracks.count) audio tracks; original reported speed \(originalDriveSpeed) kB/s.")
        print("Device TOC matched the registry TOC before playback.")

        var totalConsumedFrames: UInt64 = 0
        let policies: [DiscReadPacingPolicy] = comparePacing ? [.steady, .burst] : [.steady]
        for policy in policies {
            totalConsumedFrames += try await runPacingCheck(
                session: session, target: target, policy: policy, sustainedPacing: comparePacing,
                decodeHDCD: decodeHDCD
            )
        }

        print(String(
            format: "PASS: silent callback consumed %.2f seconds of real disc PCM; output samples were zero.",
            Double(totalConsumedFrames) / Double(Disc.sampleRate)
        ))
        print("No system volume or mute setting was changed.")
    }

    private static func runPacingCheck(
        session: DiscSession, target: OutputTarget, policy: DiscReadPacingPolicy, sustainedPacing: Bool,
        decodeHDCD: Bool
    ) async throws -> UInt64 {
        let engine = CoreAudioPlaybackEngine(session: session, silentOutput: true, readPacing: policy)
        print("Pacing: \(policy.rawValue)")
        let statisticsBefore = await session.readStatistics
        let consumedFrames = try await withSilentOutput(engine, target: target) {
            try await runPlaybackChecks(
                engine: engine, target: target, session: session, sustainedPacing: sustainedPacing,
                decodeHDCD: decodeHDCD
            )
        }

        let statisticsAfter = await session.readStatistics
        let readCount = statisticsAfter.readCount - statisticsBefore.readCount
        let audioBytes = statisticsAfter.audioBytes - statisticsBefore.audioBytes
        let readDuration = statisticsAfter.readDuration - statisticsBefore.readDuration
        let seconds = durationSeconds(readDuration)
        guard readCount > 0, audioBytes > 0, seconds > 0 else {
            throw CheckError.failed("The \(policy.rawValue) pacing check did not produce measurable raw-read statistics.")
        }
        print(String(
            format: "PASS: %@ pacing raw reads (including checksum references): %llu reads, %llu bytes in %.3f s; %.1f kB/s.",
            policy.rawValue, readCount, audioBytes, seconds, Double(audioBytes) / 1_000 / seconds
        ))
        return consumedFrames
    }

    private static func runPlaybackChecks(
        engine: CoreAudioPlaybackEngine, target: OutputTarget, session: DiscSession, sustainedPacing: Bool,
        decodeHDCD: Bool
    ) async throws -> UInt64 {
        let disc = session.disc
        let first = disc.tracks[0]
        let second = disc.tracks[1]
        let twoSeconds = 2 * Disc.sampleRate
        let framesBeforeBoundary = min(twoSeconds, first.frameCount / 2)
        let framesAfterBoundary = min(twoSeconds, second.frameCount / 2)
        guard framesBeforeBoundary > 0, framesAfterBoundary > 0 else {
            throw CheckError.failed("The first audio-track boundary is too short to verify.")
        }
        let boundaryFrames = framesBeforeBoundary + framesAfterBoundary
        let initialFrames = 10 * Disc.sampleRate - boundaryFrames
        let seekFrames = 5 * Disc.sampleRate
        let pauseFrames = 5 * Disc.sampleRate
        let endFrames = 5 * Disc.sampleRate
        let seekStart = 12 * Disc.sampleRate
        let pauseStart = min(30 * Disc.sampleRate, disc.totalFrames - 2 * pauseFrames)
        let endStart = disc.totalFrames - endFrames
        var consumed: UInt64 = 0

        let start = try await playSegment(
            sustainedPacing ? "start and pacing refill" : "start",
            engine: engine, target: target, session: session, decodeHDCD: decodeHDCD, startFrame: 0,
            frameCount: sustainedPacing ? 25 * Disc.sampleRate : initialFrames
        )
        consumed += start.currentFrame

        let seek = try await playSegment(
            "seek", engine: engine, target: target, session: session, decodeHDCD: decodeHDCD,
            startFrame: seekStart, frameCount: seekFrames
        )
        consumed += seek.currentFrame - seekStart

        let boundaryStart = first.endFrame - framesBeforeBoundary
        let boundary = try await playSegment(
            "track boundary", engine: engine, target: target, session: session, decodeHDCD: decodeHDCD,
            startFrame: boundaryStart, frameCount: boundaryFrames
        )
        guard boundary.currentFrame >= first.endFrame else {
            throw CheckError.failed("Playback did not cross the selected audio-track boundary.")
        }
        consumed += boundary.currentFrame - boundaryStart

        let paused = try await playSegment(
            "pause", engine: engine, target: target, session: session, decodeHDCD: decodeHDCD,
            startFrame: pauseStart, frameCount: pauseFrames
        )
        consumed += paused.currentFrame - pauseStart

        let idleOutput = try await engine.inspectOutput(on: target, format: sourceFormat)
        guard !idleOutput.isRunning, idleOutput.hogOwner == -1 else {
            throw CheckError.failed("The paused output did not return to an idle, unowned state.")
        }
        try await Task.sleep(for: .milliseconds(500))
        let held = try await engine.snapshot()
        guard held.currentFrame == paused.currentFrame, held.pcmChecksum == paused.pcmChecksum,
              held.underrunFrames == 0, !held.finished else {
            throw CheckError.failed("The paused playback position or checksum changed before resume.")
        }
        print("PASS: pause held at frame \(held.currentFrame) for 0.5 s with the output idle.")

        let resumed = try await playSegment(
            "resume", engine: engine, target: target, session: session, decodeHDCD: decodeHDCD,
            startFrame: paused.currentFrame, frameCount: pauseFrames
        )
        consumed += resumed.currentFrame - paused.currentFrame

        let end = try await playSegment(
            "end of disc", engine: engine, target: target, session: session, decodeHDCD: decodeHDCD,
            startFrame: endStart, frameCount: endFrames
        )
        guard end.finished, end.currentFrame == disc.totalFrames else {
            throw CheckError.failed("Playback did not reach the exact end of the audio-disc timeline.")
        }
        consumed += end.currentFrame - endStart
        return consumed
    }

    private static func playSegment(
        _ name: String, engine: CoreAudioPlaybackEngine, target: OutputTarget, session: DiscSession,
        decodeHDCD: Bool, startFrame: UInt64, frameCount: UInt64
    ) async throws -> PlaybackSnapshot {
        let totalFrames = session.disc.totalFrames
        guard startFrame < totalFrames, frameCount > 0, frameCount <= totalFrames - startFrame else {
            throw CheckError.failed("The \(name) segment is outside the audio-disc timeline.")
        }
        let before = try await engine.inspectOutput(on: target, format: sourceFormat)
        guard !before.isRunning, before.hogOwner == -1 else {
            throw CheckError.failed("The output is in use. The silent check will not interrupt existing audio.")
        }
        let requested = ContinuousClock.now
        let active = try await engine.start(at: startFrame, on: target, decodeHDCD: decodeHDCD)
        guard active.uid == before.uid, active.sampleRate == 44_100, active.hogOwner == -1 else {
            throw CheckError.failed("The selected output is not shared native 44.1 kHz.")
        }
        print("Active: \(active.name), UID \(active.uid), \(active.sampleRate) Hz, " +
              "\(active.outputChannels) channels; \(name), zero output samples.")
        let targetFrame = startFrame + frameCount
        let timeoutSeconds = Int64(frameCount / Disc.sampleRate) + 10
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        var observed = try await engine.snapshot()
        var firstAudio: Duration?
        while observed.currentFrame < targetFrame && !observed.finished {
            if firstAudio == nil, observed.currentFrame > startFrame { firstAudio = ContinuousClock.now - requested }
            guard observed.underrunFrames == 0 else {
                throw CheckError.failed("The \(name) segment had \(observed.underrunFrames) underrun frames.")
            }
            guard ContinuousClock.now < deadline else {
                throw CheckError.failed("The \(name) segment did not consume its target PCM before the timeout.")
            }
            try await Task.sleep(for: .milliseconds(50))
            observed = try await engine.snapshot()
        }
        if firstAudio == nil, observed.currentFrame > startFrame { firstAudio = ContinuousClock.now - requested }
        guard observed.underrunFrames == 0 else {
            throw CheckError.failed("The \(name) segment had \(observed.underrunFrames) underrun frames.")
        }
        let stopped = try await engine.stop()
        let restored = try await engine.inspectOutput(on: target, format: sourceFormat)
        guard restored.uid == before.uid, restored.sampleRate == before.sampleRate,
              restored.outputChannels == before.outputChannels, !restored.isRunning,
              restored.hogOwner == before.hogOwner else {
            throw CheckError.failed("The \(name) segment did not restore the selected output's configuration.")
        }
        guard stopped.currentFrame >= targetFrame, stopped.currentFrame <= totalFrames,
              stopped.underrunFrames == 0, stopped.concealedSectors == 0 else {
            throw CheckError.failed(
                "The \(name) segment ended at frame \(stopped.currentFrame), with " +
                "\(stopped.underrunFrames) underrun frames and \(stopped.concealedSectors) concealed sectors."
            )
        }

        let consumedFrames = stopped.currentFrame - startFrame
        print("HDCD: \(hdcdText(stopped.hdcdStatus)); decoded: \(stopped.hdcdDecoded ? "yes" : "no"); " +
              "physical output \(bitsText(stopped.physicalOutputBits)); first audio after " +
              "\(milliseconds(firstAudio)) (polled every 50 ms).")
        guard !stopped.hdcdDecoded else {
            throw CheckError.failed(
                "The \(name) segment rendered decoded HDCD, which undecoded reference reads cannot verify. " +
                "Rerun with --hdcd-off for the bit-perfect check."
            )
        }
        let reference = try await independentPCM(
            session: session, startFrame: startFrame, frameCount: consumedFrames
        )
        let expected = PCMChecksum.appendingUndecodedPCM16(reference)
        guard stopped.pcmChecksum == expected else {
            throw CheckError.failed(
                "\(name) PCM checksum mismatch: callback \(PCMChecksum.hexadecimal(stopped.pcmChecksum)), " +
                "independent reads \(PCMChecksum.hexadecimal(expected))."
            )
        }
        let warning = stopped.unverified ? " (alignment/read independence remains unverified)" : ""
        print("PASS: \(name), \(consumedFrames) frames, checksum " +
              "\(PCMChecksum.hexadecimal(expected)); restored \(restored.sampleRate) Hz\(warning).")
        return stopped
    }

    private static func independentPCM(
        session: DiscSession, startFrame: UInt64, frameCount: UInt64
    ) async throws -> Data {
        guard frameCount <= UInt64(Int.max / 4), startFrame <= session.disc.totalFrames,
              frameCount <= session.disc.totalFrames - startFrame else {
            throw CheckError.failed("The independent checksum range is invalid.")
        }
        var bytes = Data(capacity: Int(frameCount) * 4)
        let endFrame = startFrame + frameCount
        var cursor = startFrame
        while cursor < endFrame {
            guard let track = session.disc.track(at: cursor),
                  let position = session.disc.sectorPosition(at: cursor) else {
                throw CheckError.failed("The PCM frame has no audio-track sector.")
            }
            let framesInTrack = min(endFrame - cursor, track.endFrame - cursor)
            let sectorsInTrack = track.sectorCount - (position.sector - track.firstSector)
            let sectorsNeeded = (position.frame + framesInTrack + Disc.framesPerSector - 1) /
                Disc.framesPerSector
            let sectorCount = Int(min(UInt64(37), min(sectorsNeeded, sectorsInTrack)))
            guard sectorCount > 0 else {
                throw CheckError.failed("The independent sector read would cross an audio-track boundary.")
            }
            let block = try await session.read(from: position.sector, count: sectorCount, errorFlags: false)
            guard block.firstSector == position.sector,
                  block.audio.count == sectorCount * CDSectorBlock.audioBytes else {
                throw CheckError.failed("The independent read returned an incomplete audio block.")
            }
            let capacityFrames = UInt64(sectorCount) * Disc.framesPerSector - position.frame
            let appendedFrames = min(framesInTrack, capacityFrames)
            let startByte = Int(position.frame) * 4
            let byteCount = Int(appendedFrames) * 4
            bytes.append(block.audio.subdata(in: startByte..<(startByte + byteCount)))
            cursor += appendedFrames
        }
        return bytes
    }

    private static func durationSeconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Runs `body` with a silent engine on an idle, shared output, then stops the engine and
    /// verifies the output's original rate, ownership and idle state, even if `body` failed.
    private static func withSilentOutput<T>(
        _ engine: CoreAudioPlaybackEngine, target: OutputTarget, _ body: () async throws -> T
    ) async throws -> T {
        let before = try await engine.inspectOutput(on: target, format: sourceFormat)
        print("\(target == .builtIn ? "Built-in" : "Selected") output: \(before.name), UID \(before.uid)")
        if case .device(let uid) = target, before.uid != uid {
            throw CheckError.failed("Inspection resolved a different output UID than the requested target.")
        }
        print("Before: \(before.sampleRate) Hz, hog owner \(before.hogOwner), running \(before.isRunning)")
        guard !before.isRunning, before.hogOwner == -1 else {
            throw CheckError.failed("The output is in use. The silent check will not interrupt existing audio.")
        }
        guard before.supportsSourceRate else {
            throw CheckError.failed("The selected output cannot provide native 44.1 kHz playback.")
        }

        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await body())
        } catch {
            outcome = .failure(error)
        }
        var failure: (any Error)?
        if case .failure(let error) = outcome { failure = error }

        do {
            _ = try await engine.stop()
        } catch {
            if failure == nil { failure = error }
            else {
                FileHandle.standardError.write(
                    Data("Audio cleanup failed: \(error.localizedDescription)\n".utf8)
                )
            }
        }

        do {
            let after = try await engine.inspectOutput(on: target, format: sourceFormat)
            guard after.uid == before.uid, after.deviceID == before.deviceID, after.sampleRate == before.sampleRate,
                  after.hogOwner == before.hogOwner, !after.isRunning else {
                throw CheckError.failed("The original output rate, ownership or idle state was not restored.")
            }
            print("PASS: output rate \(after.sampleRate) Hz, ownership \(after.hogOwner), and idle state restored.")
        } catch {
            if failure == nil { failure = error }
            else {
                FileHandle.standardError.write(
                    Data("Audio output restoration could not be verified: \(error.localizedDescription)\n".utf8)
                )
            }
        }

        if let failure { throw failure }
        return try outcome.get()
    }

    struct ObservationWindow {
        let startSeconds: Double
        let seconds: Double
    }

    /// Filled while observing, so a read error still reports what happened before it.
    private final class ObservationLog {
        var finalFrame: UInt64
        var underrunFrames: UInt64 = 0
        var concealedSectors: UInt64 = 0
        var unverified = false
        var recoveryEpisodes = 0
        var recoveryTime = Duration.zero
        var longestRecovery = Duration.zero
        var pauseLatency: Duration?
        var resumeLatency: Duration?
        var stopLatency: Duration?
        var reachedTarget = false

        init(startFrame: UInt64) { finalFrame = startFrame }

        func add(_ run: PlaybackSnapshot) {
            finalFrame = run.currentFrame
            underrunFrames += run.underrunFrames
            concealedSectors += run.concealedSectors
            unverified = unverified || run.unverified
        }

        func endRecovery(after lasted: Duration) {
            recoveryTime += lasted
            longestRecovery = max(longestRecovery, lasted)
        }
    }

    /// For damaged discs: plays one window silently through the production pipeline and
    /// reports buffering, underruns, concealment and control latency instead of failing on
    /// them. Damaged PCM is not compared with reference reads.
    private static func observePlayback(
        session: DiscSession, target: OutputTarget, window: ObservationWindow, decodeHDCD: Bool
    ) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let disc = session.disc
        let startFrame = UInt64(window.startSeconds * Double(Disc.sampleRate))
        guard startFrame < disc.totalFrames else {
            throw CheckError.failed("The observation window starts after the end of the disc.")
        }
        let targetFrame = min(disc.totalFrames, startFrame + UInt64(window.seconds * Double(Disc.sampleRate)))
        let originalSpeed = try await session.speed()
        print("Drive: \(session.driveID), media: \(session.mediaID); original reported speed \(originalSpeed) kB/s.")
        print("Observing \(discTime(startFrame, disc)) to \(discTime(targetFrame, disc)) with steady pacing; " +
              "output samples are zero.")
        print(await session.retryPolicy == .singlePass
            ? "Retry policy: single pass, the app's default (each block read once; C2-flagged samples interpolated)."
            : "Retry policy: retry (C2-flagged blocks re-read with spare buffer time; none while BUFFERING).")

        let engine = CoreAudioPlaybackEngine(session: session, silentOutput: true, readPacing: .steady)
        let statisticsBefore = await session.readStatistics
        let clearedBefore = await session.sectorsClearedByRetry
        let clock = ContinuousClock()
        let began = clock.now
        let log = ObservationLog(startFrame: startFrame)
        var failure: (any Error)?
        do {
            try await withSilentOutput(engine, target: target) {
                try await observeWindow(
                    engine: engine, target: target, disc: disc, from: startFrame, to: targetFrame,
                    decodeHDCD: decodeHDCD, wallLimit: .seconds(window.seconds * 4 + 60), began: began, log: log
                )
            }
        } catch {
            failure = error
            print("[\(elapsed(clock.now - began))] Playback stopped by an error: \(error.localizedDescription)")
        }

        let wall = durationSeconds(clock.now - began)
        let played = Double(log.finalFrame - min(log.finalFrame, startFrame)) / Double(Disc.sampleRate)
        print(String(
            format: "Summary: %@ to %@ (%.2f s of audio) in %.2f s wall time; %@.",
            discTime(startFrame, disc), discTime(log.finalFrame, disc), played, wall,
            log.reachedTarget ? "window completed" : "window NOT completed"
        ))
        print(String(
            format: "Recovery BUFFERING: %d episodes, %.2f s total, longest %.2f s; underrun frames %llu (%.2f s).",
            log.recoveryEpisodes, durationSeconds(log.recoveryTime), durationSeconds(log.longestRecovery),
            log.underrunFrames, Double(log.underrunFrames) / Double(Disc.sampleRate)
        ))
        let cleared = await session.sectorsClearedByRetry - clearedBefore
        print("Concealed sectors (summed per playback run): \(log.concealedSectors); " +
              "unverified: \(log.unverified ? "yes" : "no"); " +
              "C2-flagged sectors cleared by retries: \(cleared).")
        print("Control latency: pause during BUFFERING \(milliseconds(log.pauseLatency)), " +
              "resume \(milliseconds(log.resumeLatency)), final stop \(milliseconds(log.stopLatency)).")
        let statistics = await session.readStatistics
        let reads = statistics.readCount - statisticsBefore.readCount
        let bytes = statistics.audioBytes - statisticsBefore.audioBytes
        let readSeconds = durationSeconds(statistics.readDuration - statisticsBefore.readDuration)
        if reads > 0, readSeconds > 0 {
            print(String(
                format: "Raw reads: %llu reads, %llu audio bytes, %.2f s inside reads; %.1f kB/s " +
                "(1x is 176.4 kB/s; reads of 0.5 s or more are logged by CDKit).",
                reads, bytes, readSeconds, Double(bytes) / 1_000 / readSeconds
            ))
        }
        if let failure { throw failure }
    }

    private static func observeWindow(
        engine: CoreAudioPlaybackEngine, target: OutputTarget, disc: Disc,
        from startFrame: UInt64, to targetFrame: UInt64, decodeHDCD: Bool,
        wallLimit: Duration, began: ContinuousClock.Instant, log: ObservationLog
    ) async throws {
        let clock = ContinuousClock()
        func stamp() -> String { "[\(elapsed(clock.now - began))]" }
        func start(at frame: UInt64) async throws -> Duration {
            let requested = clock.now
            let output = try await engine.start(at: frame, on: target, decodeHDCD: decodeHDCD)
            guard output.sampleRate == 44_100, output.hogOwner == -1 else {
                throw CheckError.failed("The active output is not shared native 44.1 kHz.")
            }
            return clock.now - requested
        }

        _ = try await start(at: startFrame)
        var runStartFrame = startFrame
        var buffering = true
        var startup = true
        var bufferingSince = clock.now
        var runConcealed: UInt64 = 0
        while true {
            try await Task.sleep(for: .milliseconds(50))
            let snapshot = try await engine.snapshot()
            let now = clock.now
            if snapshot.concealedSectors > runConcealed {
                print("\(stamp()) concealed sectors in this run: \(snapshot.concealedSectors) " +
                      "(playing \(discTime(snapshot.currentFrame, disc)))")
                runConcealed = snapshot.concealedSectors
            }
            if snapshot.buffering != buffering {
                if snapshot.buffering {
                    log.recoveryEpisodes += 1
                    print("\(stamp()) BUFFERING at \(discTime(snapshot.currentFrame, disc)); " +
                          "\(log.underrunFrames + snapshot.underrunFrames) underrun frames so far")
                } else {
                    let lasted = now - bufferingSince
                    if !startup { log.endRecovery(after: lasted) }
                    print("\(stamp()) \(startup ? "First audio" : "Playing again") at " +
                          "\(discTime(snapshot.currentFrame, disc)) after \(milliseconds(lasted))")
                    startup = false
                }
                buffering = snapshot.buffering
                bufferingSince = now
            }
            if snapshot.finished || snapshot.currentFrame >= targetFrame {
                log.reachedTarget = true
                break
            }
            if now - began > wallLimit {
                print("\(stamp()) Wall-clock limit reached; stopping.")
                break
            }
            if log.pauseLatency == nil, buffering, now - bufferingSince >= .milliseconds(1_500) {
                let requested = clock.now
                let paused = try await engine.stop()
                let latency = clock.now - requested
                log.pauseLatency = latency
                if !startup { log.endRecovery(after: clock.now - bufferingSince) }
                log.add(paused)
                print("\(stamp()) Pause during \(startup ? "start-up" : "recovery") BUFFERING returned in " +
                      "\(milliseconds(latency)) at \(discTime(paused.currentFrame, disc)); resuming in 1 s")
                try await Task.sleep(for: .seconds(1))
                let resumeLatency = try await start(at: paused.currentFrame)
                runStartFrame = paused.currentFrame
                log.resumeLatency = resumeLatency
                print("\(stamp()) Play returned in \(milliseconds(resumeLatency))")
                buffering = true
                startup = true
                bufferingSince = clock.now
                runConcealed = 0
            }
        }

        let requested = clock.now
        let stopped = try await engine.stop()
        log.stopLatency = clock.now - requested
        if buffering, !startup { log.endRecovery(after: clock.now - bufferingSince) }
        log.add(stopped)
        print("\(stamp()) Stop returned in \(milliseconds(log.stopLatency)) at \(discTime(stopped.currentFrame, disc))")
        print("HDCD: \(hdcdText(stopped.hdcdStatus)); decoded: \(stopped.hdcdDecoded ? "yes" : "no"); " +
              "physical output \(bitsText(stopped.physicalOutputBits)).")
        // Each start resets the checksum, the run counters and the HDCD decoder, so an undamaged final run
        // is comparable with an external decode that starts at the same frame.
        if stopped.concealedSectors == 0, stopped.underrunFrames == 0, stopped.currentFrame > runStartFrame {
            print("Rendered PCM checksum \(PCMChecksum.hexadecimal(stopped.pcmChecksum)) for frames " +
                  "\(runStartFrame)..<\(stopped.currentFrame) (\(stopped.currentFrame - runStartFrame) frames, " +
                  "32-bit little-endian samples) of the final run.")
        } else {
            print("No rendered PCM checksum: the final run was concealed, underran or played nothing.")
        }
    }

    private static func hdcdText(_ status: HDCDPlaybackStatus) -> String {
        switch status {
        case .notApplicable: "not applicable to this source"
        case .detecting: "still detecting"
        case .none: "no HDCD packets"
        case .noEffect: "HDCD packets that switch nothing on"
        case .effectual: "HDCD packets with Peak Extend or a gain adjustment"
        }
    }

    private static func bitsText(_ bits: UInt32) -> String {
        bits == 0 ? "depth unavailable" : "\(bits)-bit"
    }

    /// Disc time, track and the LBA being played, to match CDKit's concealment logs.
    private static func discTime(_ frame: UInt64, _ disc: Disc) -> String {
        let seconds = Double(frame) / Double(Disc.sampleRate)
        var text = String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
        if let track = disc.track(at: frame), let position = disc.sectorPosition(at: frame) {
            text += " (track \(track.number), LBA \(position.sector))"
        }
        return text
    }

    private static func elapsed(_ duration: Duration) -> String {
        String(format: "+%.2f s", durationSeconds(duration))
    }

    private static func milliseconds(_ duration: Duration?) -> String {
        guard let duration else { return "not measured" }
        return String(format: "%.0f ms", durationSeconds(duration) * 1_000)
    }
}
