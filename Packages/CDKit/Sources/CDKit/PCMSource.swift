import CDAudioCore
import Foundation

/// Blocking reads run only on the PCM producer, never the main, cooperative or HAL threads.
/// The read variant must match `format.bitsPerChannel`; stereo samples are interleaved left/right pairs.
protocol PCMSource: Sendable {
    var format: AudioSourceFormat { get }
    var frameCount: UInt64 { get }
    var readPacing: CDReadPacing { get }
    var hdcdEligible: Bool { get }
    func read(at frame: UInt64, maxFrames: Int) throws -> [Int16]
    func read(at frame: UInt64, maxFrames: Int, context: PCMReadContext) throws -> PCMReadResult
    func read24(at frame: UInt64, maxFrames: Int, context: PCMReadContext) throws -> PCM24ReadResult
}

extension PCMSource {
    var readPacing: CDReadPacing { CD_READ_UNPACED }
    var hdcdEligible: Bool { false }
    func read(at frame: UInt64, maxFrames: Int) throws -> [Int16] {
        throw CDReadError(.failed, "The PCM source does not provide 16-bit samples.")
    }
    func read24(at frame: UInt64, maxFrames: Int, context: PCMReadContext) throws -> PCM24ReadResult {
        throw CDReadError(.failed, "The PCM source does not provide 24-bit samples.")
    }
    func read(at frame: UInt64, maxFrames: Int, context: PCMReadContext) throws -> PCMReadResult {
        PCMReadResult(samples: try read(at: frame, maxFrames: maxFrames))
    }
}

struct PCMReadContext: Sendable {
    var bufferedFrames = 0
    var buffering = true
    var beginsPlayback = false
    var isCancelled: @Sendable () -> Bool = { false }

    func checkCancellation() throws {
        if isCancelled() { throw CancellationError() }
    }
}

struct PCMReadResult: Sendable {
    let samples: [Int16]
    var trackNumber: UInt32 = 0
    var concealedSectors: UInt64 = 0
    var unverified = false
}

struct PCM24ReadResult: Sendable {
    let samples: [Int32]
    var trackNumber: UInt32 = 0
    var concealedSectors: UInt64 = 0
    var unverified = false
}

struct DiscPCMSource: PCMSource {
    // Leave room for overlap and alignment guards within the 37-sector raw-read cap.
    static let maxSectorsPerRead = 33
    let session: DiscSession
    let readPacing: CDReadPacing

    init(session: DiscSession, readPacing: DiscReadPacingPolicy = .steady) {
        self.session = session
        self.readPacing = readPacing.cValue
    }

    var format: AudioSourceFormat { session.disc.format }
    var frameCount: UInt64 { session.disc.totalFrames }
    var hdcdEligible: Bool { true }

    func read(at frame: UInt64, maxFrames: Int) throws -> [Int16] {
        try read(at: frame, maxFrames: maxFrames, context: PCMReadContext()).samples
    }

    func read(at frame: UInt64, maxFrames: Int, context: PCMReadContext) throws -> PCMReadResult {
        guard maxFrames > 0, frame <= frameCount else {
            throw CDReadError(.failed, "The PCM frame request is outside the disc.")
        }
        if frame == frameCount { return PCMReadResult(samples: []) }
        guard let track = session.disc.track(at: frame),
              let position = session.disc.sectorPosition(at: frame) else {
            throw CDReadError(.failed, "The PCM frame has no audio sector.")
        }
        let offset = Int(position.frame)
        let framesPerSector = Int(track.framesPerSector)
        let channels = Int(format.channels)
        let limit = min(maxFrames, Self.maxSectorsPerRead * framesPerSector - offset)
        let frames = Int(min(UInt64(limit), track.endFrame - frame))
        let sectors = (offset + frames + framesPerSector - 1) / framesPerSector
        let block = try session.readForProducer(
            from: position.sector, count: sectors, track: track, context: context
        )
        return PCMReadResult(
            samples: Array(block.samples[offset * channels..<(offset + frames) * channels]),
            trackNumber: UInt32(track.number),
            concealedSectors: block.concealedSectors, unverified: block.unverified
        )
    }
}

private extension DiscReadPacingPolicy {
    var cValue: CDReadPacing {
        switch self {
        case .steady: CD_READ_STEADY
        case .burst: CD_READ_BURST
        }
    }
}

private final class PCMSourceContext: Sendable {
    let source: any PCMSource
    init(_ source: any PCMSource) { self.source = source }
}

/// C owns the retained source only after construction succeeds, and releases it after joining
/// the producer. On cleanup failure C intentionally retains both callback and source storage.
/// C refuses a source format it cannot carry unchanged.
func makePCMPlayback(
    source: any PCMSource, bufferFrames: Int, silentOutput: Bool = false,
    levelSource: CoreAudioLevelSource? = nil
) throws -> OpaquePointer {
    let levelTable = try levelSource?.playbackTable()
    let context = Unmanaged.passRetained(PCMSourceContext(source))
    let wideSource = source.format.bitsPerChannel == 24
    let descriptor = CDPCMSource(
        frameCount: source.frameCount, context: context.toOpaque(),
        read: wideSource ? nil : readPCMSource, readWide: wideSource ? readWidePCMSource : nil,
        destroy: releasePCMSource, readPacing: source.readPacing,
        format: source.format.cValue, hdcdEligible: source.hdcdEligible
    )
    var error = CDError()
    let createdPlayback: OpaquePointer?
    if let levelTable {
        createdPlayback = cd_playback_create_source_with_levels(
            descriptor, bufferFrames, silentOutput, levelTable, &error
        )
    } else {
        createdPlayback = cd_playback_create_source(descriptor, bufferFrames, silentOutput, &error)
    }
    guard let playback = createdPlayback else {
        context.release()
        throw AudioPlaybackError(error)
    }
    return playback
}

private func readWidePCMSource(
    _ context: UnsafeMutableRawPointer?, _ frame: UInt64, _ stereo: UnsafeMutablePointer<Int32>?,
    _ capacity: Int, _ request: UnsafePointer<CDPCMReadContext>?,
    _ reply: UnsafeMutablePointer<CDPCMReadResult>?, _ error: UnsafeMutablePointer<CDError>?
) -> Int32 {
    reply?.pointee = CDPCMReadResult()
    guard let context, let stereo, let request, let reply, let playback = request.pointee.playback,
          capacity > 0, capacity <= Int.max / 2 else {
        let failure = CDError(result: CD_INVALID_ARGUMENT, message: "The PCM producer supplied an invalid read request.")
        error?.pointee = failure
        return failure.code
    }
    return autoreleasepool {
        let source = Unmanaged<PCMSourceContext>.fromOpaque(context).takeUnretainedValue().source
        let token = PCMReadToken(pointer: playback)
        let readContext = PCMReadContext(
            bufferedFrames: request.pointee.bufferedFrames, buffering: request.pointee.buffering,
            beginsPlayback: request.pointee.beginsPlayback,
            isCancelled: { cd_playback_read_cancelled(token.pointer) }
        )
        do {
            let result = try source.read24(at: frame, maxFrames: capacity, context: readContext)
            let samples = result.samples
            guard samples.count.isMultiple(of: 2), samples.count / 2 <= capacity else {
                let failure = CDError(result: CD_PRODUCER_ERROR, message: "The PCM source returned an invalid stereo buffer.")
                error?.pointee = failure
                return failure.code
            }
            samples.withUnsafeBufferPointer {
                if let base = $0.baseAddress { stereo.update(from: base, count: samples.count) }
            }
            reply.pointee = CDPCMReadResult(
                framesRead: samples.count / 2, trackNumber: result.trackNumber,
                concealedSectors: result.concealedSectors,
                unverified: result.unverified
            )
            return Int32(CD_OK.rawValue)
        } catch let failure {
            let failure = CDError(sourceError: failure)
            error?.pointee = failure
            return failure.code
        }
    }
}

private func readPCMSource(
    _ context: UnsafeMutableRawPointer?, _ frame: UInt64, _ stereo: UnsafeMutablePointer<Int16>?,
    _ capacity: Int, _ request: UnsafePointer<CDPCMReadContext>?,
    _ reply: UnsafeMutablePointer<CDPCMReadResult>?, _ error: UnsafeMutablePointer<CDError>?
) -> Int32 {
    reply?.pointee = CDPCMReadResult()
    guard let context, let stereo, let request, let reply, let playback = request.pointee.playback,
          capacity > 0, capacity <= Int.max / 2 else {
        let failure = CDError(result: CD_INVALID_ARGUMENT, message: "The PCM producer supplied an invalid read request.")
        error?.pointee = failure
        return failure.code
    }
    return autoreleasepool {
        let source = Unmanaged<PCMSourceContext>.fromOpaque(context).takeUnretainedValue().source
        let token = PCMReadToken(pointer: playback)
        let readContext = PCMReadContext(
            bufferedFrames: request.pointee.bufferedFrames, buffering: request.pointee.buffering,
            beginsPlayback: request.pointee.beginsPlayback,
            isCancelled: { cd_playback_read_cancelled(token.pointer) }
        )
        do {
            let result = try source.read(at: frame, maxFrames: capacity, context: readContext)
            let samples = result.samples
            guard samples.count.isMultiple(of: 2), samples.count / 2 <= capacity else {
                let failure = CDError(result: CD_PRODUCER_ERROR, message: "The PCM source returned an invalid stereo buffer.")
                error?.pointee = failure
                return failure.code
            }
            samples.withUnsafeBufferPointer {
                if let base = $0.baseAddress { stereo.update(from: base, count: samples.count) }
            }
            reply.pointee = CDPCMReadResult(
                framesRead: samples.count / 2, trackNumber: result.trackNumber,
                concealedSectors: result.concealedSectors,
                unverified: result.unverified
            )
            return Int32(CD_OK.rawValue)
        } catch let failure {
            let failure = CDError(sourceError: failure)
            error?.pointee = failure
            return failure.code
        }
    }
}

/// Borrowed only inside a synchronous C source read; the owner cannot destroy playback
/// until that producer returns. Only the atomic cancellation query uses this pointer.
private struct PCMReadToken: @unchecked Sendable {
    let pointer: OpaquePointer
}

private func releasePCMSource(_ context: UnsafeMutableRawPointer?) {
    guard let context else { preconditionFailure("A retained PCM source must have a context.") }
    Unmanaged<PCMSourceContext>.fromOpaque(context).release()
}

extension CDError {
    init(result: CDResult, message: String, systemStatus: Int32 = 0) {
        self.init()
        code = Int32(result.rawValue)
        self.systemStatus = systemStatus
        withUnsafeMutableBytes(of: &self.message) { bytes in
            for (index, byte) in message.utf8.prefix(bytes.count - 1).enumerated() {
                bytes[index] = byte
            }
        }
    }

    init(sourceError error: any Error) {
        guard let error = error as? CDReadError else {
            self.init(result: CD_PRODUCER_ERROR, message: error.localizedDescription)
            return
        }
        let result: CDResult
        switch error.kind {
        case .refused: result = CD_DISC_REFUSED
        case .gone: result = CD_DISC_GONE
        case .mediaError: result = CD_DISC_READ_ERROR
        case .failed: result = CD_DISC_FAILED
        }
        self.init(result: result, message: error.message, systemStatus: error.systemError)
    }
}
