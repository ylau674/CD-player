import CDAudioCore
import CoreAudio
import Foundation
import Testing
@testable import CDKit

func expectedRenderedPCMChecksum(_ samples: [Int16]) -> UInt64 {
    var bytes = Data()
    for sample in samples {
        let bits = UInt32(bitPattern: Int32(sample) * 65_536)
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8((bits >> shift) & 0xFF))
        }
    }
    return PCMChecksum.appending(bytes)
}

private func render(
    _ ring: OpaquePointer, frames: Int, checksumPCM: Bool = false, initialChecksum: UInt64 = 0
) -> (samples: [Float], result: CDRenderResult) {
    var samples = [Float](repeating: .nan, count: frames * 2)
    let result = samples.withUnsafeMutableBufferPointer { buffer in
        var output = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.stride),
                mData: buffer.baseAddress
            )
        )
        return cd_ring_render(ring, &output, checksumPCM, initialChecksum)
    }
    return (samples, result)
}

@Test func everyInt16ValueSurvivesFloat32Conversion() {
    let input = Array(Int16.min...Int16.max)
    var converted = [Float](repeating: .nan, count: input.count)
    input.withUnsafeBufferPointer { source in
        converted.withUnsafeMutableBufferPointer { target in
            cd_pcm16_to_float32(source.baseAddress, target.baseAddress, input.count)
        }
    }
    #expect(converted.allSatisfy { $0.isFinite })
    #expect(zip(input, converted).allSatisfy { Int32($0) == Int32($1 * 32_768) })
    #expect(converted.first == -1)
    #expect(converted.last == Float(Int16.max) / 32_768)
}

@Test func callbackRendererPreservesEverySampleAndStereoOrder() throws {
    let input = Array(Int16.min...Int16.max)
    let ring = try #require(cd_ring_create(input.count / 2))
    defer { cd_ring_destroy(ring) }
    let written = input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, input.count / 2) }
    let output = render(ring, frames: input.count / 2)
    #expect(written == input.count / 2)
    #expect(output.result.validLayout)
    #expect(output.result.consumedFrames == input.count / 2)
    #expect(zip(input, output.samples).allSatisfy { Int32($0) == Int32($1 * 32_768) })
    #expect(cd_ring_available(ring) == 0)
}

@Test func narrowAndWideRingsRenderEveryInt16ValueIdentically() throws {
    let input = Array(Int16.min...Int16.max)
    let frames = input.count / 2
    var outputs: [(samples: [Float], result: CDRenderResult)] = []
    for wide in [true, false] {
        let ring = try #require(cd_ring_create(frames))
        defer { cd_ring_destroy(ring) }
        #expect(cd_ring_configure(ring, wide) && cd_ring_is_wide(ring) == wide)
        #expect(input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, frames) } == frames)
        outputs.append(render(ring, frames: frames, checksumPCM: true, initialChecksum: PCMChecksum.initialValue))
    }
    #expect(outputs[0].samples == outputs[1].samples)
    #expect(outputs[1].result.consumedFrames == frames)
    #expect(outputs[0].result.pcmChecksum == outputs[1].result.pcmChecksum)
    #expect(outputs[1].result.pcmChecksum == expectedRenderedPCMChecksum(input))
    #expect(zip(input, outputs[1].samples).allSatisfy { Int32($0) == Int32($1 * 32_768) })
}

@Test func onlyAWideRingAcceptsDecodedFrames() throws {
    let ring = try #require(cd_ring_create(4))
    defer { cd_ring_destroy(ring) }
    #expect(cd_ring_is_wide(ring))
    let decoded: [Int32] = [1 << 20 | 1, -(1 << 20)]
    #expect(cd_ring_configure(ring, false))
    #expect(decoded.withUnsafeBufferPointer { cd_ring_write_32(ring, $0.baseAddress, 1) } == 0)
    #expect(cd_ring_available(ring) == 0)
    #expect(cd_ring_configure(ring, true))
    #expect(decoded.withUnsafeBufferPointer { cd_ring_write_32(ring, $0.baseAddress, 1) } == 1)
    #expect(render(ring, frames: 1).samples == decoded.map { Float($0) / 2_147_483_648 })
}

@Test func ringClaimsOnlyThePagesItsSampleWidthNeedsAndReturnsThemOnRelease() throws {
    let frames = 44_100
    let ring = try #require(cd_ring_create(frames))
    defer { cd_ring_destroy(ring) }
    let wideBytes = pageRounded(frames * 2 * 4)
    let narrowBytes = pageRounded(frames * 2 * 2)
    var usage = cd_ring_page_usage(ring)
    #expect(usage.mappedBytes == wideBytes && usage.claimedBytes == wideBytes && usage.footprintBytes == 0)

    #expect(cd_ring_configure(ring, false))
    usage = cd_ring_page_usage(ring)
    #expect(usage.claimedBytes == narrowBytes && usage.footprintBytes == 0)
    let samples = (0..<frames * 2).map { Int16(truncatingIfNeeded: $0 * 7) }
    #expect(samples.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, frames) } == frames)
    #expect(cd_ring_page_usage(ring).footprintBytes == narrowBytes)

    cd_ring_release(ring)
    usage = cd_ring_page_usage(ring)
    #expect(usage.claimedBytes == 0 && usage.footprintBytes == 0)
    #expect(cd_ring_available(ring) == frames)
    cd_ring_release(ring)
    #expect(cd_ring_page_usage(ring).claimedBytes == 0)

    #expect(cd_ring_configure(ring, true))
    usage = cd_ring_page_usage(ring)
    #expect(usage.claimedBytes == wideBytes && usage.footprintBytes <= narrowBytes)
    #expect(cd_ring_available(ring) == 0)
    #expect(samples.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, frames) } == frames)
    #expect(cd_ring_page_usage(ring).footprintBytes == wideBytes)
    #expect(render(ring, frames: frames).samples == samples.map { Float($0) / 32_768 })
}

@Test func callbackPCMChecksumUsesInterleavedLittleEndianSampleBytes() throws {
    let input: [Int16] = [0x1234, -0x5678, .min, .max]
    let ring = try #require(cd_ring_create(2))
    defer { cd_ring_destroy(ring) }
    #expect(input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 2) } == 2)

    let output = render(
        ring, frames: 2, checksumPCM: true, initialChecksum: PCMChecksum.initialValue
    )
    #expect(output.result.pcmChecksum == expectedRenderedPCMChecksum(input))
    #expect(output.result.consumedFrames == 2)
}

@Test func undecodedPCM16ChecksumMatchesTheRenderedChecksumForEveryValue() throws {
    let input: [Int16] = [0x1234, -0x5678, .min, .max]
    let ring = try #require(cd_ring_create(2))
    defer { cd_ring_destroy(ring) }
    #expect(input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 2) } == 2)
    let output = render(ring, frames: 2, checksumPCM: true, initialChecksum: PCMChecksum.initialValue)
    #expect(output.result.pcmChecksum == PCMChecksum.appendingUndecodedPCM16(littleEndianBytes(input)))

    let everyValue = (Int(Int16.min)...Int(Int16.max)).map { Int16($0) }
    let bytes = littleEndianBytes(everyValue)
    #expect(PCMChecksum.appendingUndecodedPCM16(bytes) == expectedRenderedPCMChecksum(everyValue))
    let split = bytes.count / 2
    let chained = PCMChecksum.appendingUndecodedPCM16(
        bytes.subdata(in: split..<bytes.count),
        to: PCMChecksum.appendingUndecodedPCM16(bytes.subdata(in: 0..<split))
    )
    #expect(chained == expectedRenderedPCMChecksum(everyValue))
    #expect(PCMChecksum.appendingUndecodedPCM16(bytes[1..<5]) ==
        expectedRenderedPCMChecksum([0x0180, 0x0280]))
}

private func littleEndianBytes(_ samples: [Int16]) -> Data {
    var bytes = Data(capacity: samples.count * 2)
    for sample in samples {
        let bits = UInt16(bitPattern: sample)
        bytes.append(UInt8(bits & 0xFF))
        bytes.append(UInt8(bits >> 8))
    }
    return bytes
}

@Test func ringWraparoundAndBackpressure() throws {
    let ring = try #require(cd_ring_create(8))
    defer { cd_ring_destroy(ring) }
    let first: [Int16] = [1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6]
    #expect(first.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 6) } == 6)
    #expect(render(ring, frames: 4).result.consumedFrames == 4)
    let next: [Int16] = [7, -7, 8, -8, 9, -9, 10, -10, 11, -11, 12, -12, 13, -13]
    #expect(next.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 7) } == 6)
    #expect(cd_ring_writable(ring) == 0)
    let output = render(ring, frames: 8)
    let recovered = output.samples.map { Int16($0 * 32_768) }
    #expect(recovered == [5, -5, 6, -6, 7, -7, 8, -8, 9, -9, 10, -10, 11, -11, 12, -12])
    #expect(cd_ring_available(ring) == 0)
    cd_ring_reset(ring)
    #expect(cd_ring_writable(ring) == 8)
}

@Test func shortReadProducesSilenceWithoutInventingPlayedFrames() throws {
    let ring = try #require(cd_ring_create(4))
    defer { cd_ring_destroy(ring) }
    let input: [Int16] = [-32_768, 32_767, 100, -100]
    #expect(input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 2) } == 2)
    let output = render(ring, frames: 4)
    #expect(output.result.requestedFrames == 4)
    #expect(output.result.consumedFrames == 2)
    #expect(output.samples.suffix(4).allSatisfy { $0 == 0 })
}

@Test(arguments: [true, false])
func planarCallbackRendererPreservesLeftAndRight(wideSamples: Bool) throws {
    let ring = try #require(cd_ring_create(4))
    defer { cd_ring_destroy(ring) }
    #expect(cd_ring_configure(ring, wideSamples))
    let input: [Int16] = [-32_768, 32_767, 100, -100]
    #expect(input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 2) } == 2)
    var left = [Float](repeating: .nan, count: 4)
    var right = left
    let buffers = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(buffers.unsafeMutablePointer) }
    buffers.unsafeMutablePointer.pointee.mNumberBuffers = 2
    let result = left.withUnsafeMutableBufferPointer { left in
        right.withUnsafeMutableBufferPointer { right in
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: left.baseAddress)
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: right.baseAddress)
            return cd_ring_render(ring, buffers.unsafeMutablePointer, false, 0)
        }
    }
    #expect(result.validLayout)
    #expect(result.consumedFrames == 2)
    #expect(left == [-1, Float(100) / 32_768, 0, 0])
    #expect(right == [Float(32_767) / 32_768, Float(-100) / 32_768, 0, 0])
}

@Test(arguments: [UInt32(4), 8], [true, false])
func mappedCallbackRendererUsesPreferredStereoChannelsAndSilencesTheRest(channels: UInt32, wideSamples: Bool) throws {
    let ring = try #require(cd_ring_create(4))
    defer { cd_ring_destroy(ring) }
    #expect(cd_ring_configure(ring, wideSamples))
    let input: [Int16] = [-32_768, 32_767, 100, -100]
    #expect(input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 2) } == 2)
    var samples = [Float](repeating: .nan, count: Int(channels) * 3)
    let result = samples.withUnsafeMutableBufferPointer { samples in
        var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: channels, mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.stride),
            mData: samples.baseAddress
        ))
        return cd_ring_render_mapped(ring, &output, true, PCMChecksum.initialValue, 1, channels - 1)
    }

    #expect(result.validLayout)
    #expect(result.requestedFrames == 3)
    #expect(result.consumedFrames == 2)
    var expected = [Float](repeating: 0, count: samples.count)
    expected[1] = -1
    expected[Int(channels) - 1] = Float(32_767) / 32_768
    expected[Int(channels) + 1] = Float(100) / 32_768
    expected[2 * Int(channels) - 1] = Float(-100) / 32_768
    #expect(samples == expected)
    #expect(result.pcmChecksum == expectedRenderedPCMChecksum(input))
}

@Test func invalidOutputIsSilencedAndDoesNotConsumeSource() throws {
    let ring = try #require(cd_ring_create(4))
    defer { cd_ring_destroy(ring) }
    let input: [Int16] = [1, 2]
    _ = input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 1) }
    var samples: [Float] = [1, 1]
    let result = samples.withUnsafeMutableBufferPointer { buffer in
        var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: 8, mData: buffer.baseAddress
        ))
        return cd_ring_render(ring, &output, false, 0)
    }
    #expect(!result.validLayout)
    #expect(result.consumedFrames == 0)
    #expect(samples == [0, 0])
    #expect(cd_ring_available(ring) == 1)
}

@Test(arguments: [true, false])
func mappedPlanarOutputPreservesPCMAndSilencesUnusedChannels(wideSamples: Bool) throws {
    let ring = try #require(cd_ring_create(4))
    defer { cd_ring_destroy(ring) }
    #expect(cd_ring_configure(ring, wideSamples))
    let input: [Int16] = [-32_768, 32_767, 100, -100]
    #expect(input.withUnsafeBufferPointer { cd_ring_write(ring, $0.baseAddress, 2) } == 2)
    let channels = 8
    let frames = 3
    var samples = [Float](repeating: .nan, count: channels * frames)
    let buffers = AudioBufferList.allocate(maximumBuffers: channels)
    defer { free(buffers.unsafeMutablePointer) }
    buffers.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channels)
    let result = samples.withUnsafeMutableBufferPointer { samples in
        for channel in 0..<channels {
            buffers[channel] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(frames * MemoryLayout<Float>.stride),
                mData: samples.baseAddress!.advanced(by: channel * frames)
            )
        }
        return cd_ring_render_mapped(
            ring, buffers.unsafeMutablePointer, true, PCMChecksum.initialValue, 6, 1
        )
    }
    var expected = [Float](repeating: 0, count: samples.count)
    expected[6 * frames] = -1
    expected[6 * frames + 1] = Float(100) / 32_768
    expected[frames] = Float(32_767) / 32_768
    expected[frames + 1] = Float(-100) / 32_768
    #expect(result.validLayout)
    #expect(result.requestedFrames == 3)
    #expect(result.consumedFrames == 2)
    #expect(samples == expected)
    #expect(result.pcmChecksum == expectedRenderedPCMChecksum(input))
}

@Test func simulatedSourceIsSeekableAndGaplessAcrossTrackBoundaries() {
    let tracks = [
        CDDemoTrack(frameCount: 5, frequency: 220, amplitude: 3_276),
        CDDemoTrack(frameCount: 7, frequency: 440, amplitude: 3_276)
    ]
    var whole = [Int16](repeating: -1, count: 24)
    var split = whole
    tracks.withUnsafeBufferPointer { tracks in
        #expect(cd_demo_total_frames(tracks.baseAddress, tracks.count) == 12)
        whole.withUnsafeMutableBufferPointer {
            #expect(cd_demo_render(tracks.baseAddress, tracks.count, 0, $0.baseAddress, 12) == 12)
        }
        split.withUnsafeMutableBufferPointer {
            #expect(cd_demo_render(tracks.baseAddress, tracks.count, 0, $0.baseAddress, 7) == 7)
            #expect(cd_demo_render(tracks.baseAddress, tracks.count, 7, $0.baseAddress?.advanced(by: 14), 5) == 5)
        }
    }
    #expect(whole == split)
    #expect(whole[10] == 0)
    #expect(stride(from: 0, to: whole.count, by: 2).allSatisfy { whole[$0] == whole[$0 + 1] })
}

@Test func invalidSourceIsRejectedBeforeTouchingHardware() {
    var invalid = CDDemoTrack(frameCount: 44_100, frequency: -1, amplitude: 3_276)
    var error = CDError()
    let playback = cd_playback_create(&invalid, 1, 44_100, &error)
    #expect(playback == nil)
    #expect(error.code == Int32(CD_INVALID_ARGUMENT.rawValue))
    #expect(cd_ring_create(0) == nil)
}

// The C ring permits one writer and one reader; only test results use the lock.
private final class RingStressFixture: @unchecked Sendable {
    let pointer: OpaquePointer
    private let lock = NSLock()
    private var counts = [0, 0]
    private var mismatch = false

    init(pointer: OpaquePointer) { self.pointer = pointer }
    deinit { cd_ring_destroy(pointer) }

    func record(role: Int, count: Int, mismatch: Bool) {
        lock.withLock {
            counts[role] = count
            self.mismatch = self.mismatch || mismatch
        }
    }
    func result() -> (counts: [Int], mismatch: Bool) {
        lock.withLock { (counts, mismatch) }
    }
}

@Test func spscRingPreservesSampleOrderUnderConcurrentLoad() async throws {
    let fixture = RingStressFixture(pointer: try #require(cd_ring_create(257)))
    let totalFrames = 250_000
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    // concurrentPerform may serialize mutually dependent roles under load.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let group = DispatchGroup()
        for role in 0..<2 {
            group.enter()
            Thread {
                var completed = 0
                var mismatch = false
                while completed < totalFrames && ContinuousClock.now < deadline {
                    if role == 0 {
                        let count = min(31, totalFrames - completed)
                        var samples = [Int16]()
                        samples.reserveCapacity(count * 2)
                        for frame in 0..<count {
                            let value = Int16(truncatingIfNeeded: completed + frame)
                            samples.append(value)
                            samples.append(~value)
                        }
                        let written = samples.withUnsafeBufferPointer {
                            cd_ring_write(fixture.pointer, $0.baseAddress, count)
                        }
                        completed += written
                        if written == 0 { Thread.sleep(forTimeInterval: 0.0001) }
                    } else {
                        let output = render(fixture.pointer, frames: min(47, totalFrames - completed))
                        for frame in 0..<output.result.consumedFrames {
                            let value = Int16(truncatingIfNeeded: completed + frame)
                            if output.samples[frame * 2] * 32_768 != Float(value) ||
                                output.samples[frame * 2 + 1] * 32_768 != Float(~value) {
                                mismatch = true
                            }
                        }
                        completed += output.result.consumedFrames
                        if output.result.consumedFrames == 0 { Thread.sleep(forTimeInterval: 0.0001) }
                    }
                }
                fixture.record(role: role, count: completed, mismatch: mismatch)
                group.leave()
            }.start()
        }
        group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
    }
    let result = fixture.result()
    #expect(result.counts == [totalFrames, totalFrames])
    #expect(!result.mismatch)
    #expect(cd_ring_available(fixture.pointer) == 0)
}
