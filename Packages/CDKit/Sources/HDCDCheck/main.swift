import Foundation
import HDCD

@main
enum HDCDCheck {
    private static let usage = """
        Usage: HDCDCheck input.s16le output.s32le
               HDCDCheck --seek-gaps input.s16le [step seconds, default 0.37]
        """

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--seek-gaps" {
            guard (2...3).contains(arguments.count) else { exitWithUsage() }
            var step = 0.37
            if arguments.count == 3 {
                guard let value = Double(arguments[2]), value.isFinite, value >= 0.01 else { exitWithUsage() }
                step = value
            }
            try measureSeekGaps(samples: readS16LE(arguments[1]), stepSeconds: step)
            return
        }
        guard arguments.count == 2 else { exitWithUsage() }
        try decode(samples: readS16LE(arguments[0]), to: arguments[1])
    }

    private static func exitWithUsage() -> Never {
        fputs(usage + "\n", stderr)
        exit(64)
    }

    private static func readS16LE(_ path: String) throws -> [Int32] {
        let inputData = try Data(contentsOf: URL(fileURLWithPath: path))
        guard inputData.count.isMultiple(of: 4) else {
            throw CheckError("Input must contain interleaved stereo S16LE frames.")
        }
        let bytes = [UInt8](inputData)
        var samples = [Int32]()
        samples.reserveCapacity(bytes.count / 2)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            samples.append(Int32(Int16(bitPattern: bits)))
        }
        return samples
    }

    private static func makeDecoder() throws -> OpaquePointer {
        guard let decoder = hdcd_new() else {
            throw CheckError("Cannot create the libhdcd decoder.")
        }
        hdcd_logger_detach(decoder)
        return decoder
    }

    private static func decode(samples input: [Int32], to path: String) throws {
        var samples = input
        let decoder = try makeDecoder()
        defer { hdcd_free(decoder) }

        let frameCount = samples.count / 2
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < frameCount {
                let count = min(4_096, frameCount - offset)
                hdcd_process(decoder, base.advanced(by: offset * 2), Int32(count))
                offset += count
            }
        }

        var output = Data(capacity: samples.count * MemoryLayout<Int32>.size)
        for sample in samples {
            let bits = UInt32(bitPattern: sample)
            for shift in stride(from: 0, to: 32, by: 8) {
                output.append(UInt8((bits >> shift) & 0xFF))
            }
        }
        try output.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Resets the decoder at evenly spaced points, as a seek or track change does in the app, and
    /// reports how much audio passes before the next HDCD packet. Until then a decoded disc plays
    /// without Peak Extend or gain adjustment.
    private static func measureSeekGaps(samples: [Int32], stepSeconds: Double) throws {
        let sampleRate = 44_100
        let frameCount = samples.count / 2
        let stepFrames = max(1, Int(stepSeconds * Double(sampleRate)))
        let limitFrames = 5 * sampleRate
        let decoder = try makeDecoder()
        defer { hdcd_free(decoder) }

        var gaps = [Int]()
        var misses = 0
        var pair: [Int32] = [0, 0]
        for start in stride(from: 0, to: frameCount, by: stepFrames) {
            hdcd_reset(decoder)
            let end = min(frameCount, start + limitFrames)
            var found: Int?
            for frame in start..<end {
                pair[0] = samples[frame * 2]
                pair[1] = samples[frame * 2 + 1]
                hdcd_process(decoder, &pair, 1)
                if hdcd_detected(decoder) != Int32(HDCD_NONE.rawValue) {
                    found = frame + 1 - start
                    break
                }
            }
            if let found {
                gaps.append(found)
            } else if start + limitFrames <= frameCount {
                misses += 1
            }
        }

        func milliseconds(_ frames: Int) -> String {
            String(format: "%.1f ms", Double(frames) * 1_000 / Double(sampleRate))
        }
        let audioSeconds = String(format: "%.2f", Double(frameCount) / Double(sampleRate))
        print("Reset points: \(gaps.count + misses) measured, every \(stepFrames) frames over \(audioSeconds) s.")
        guard !gaps.isEmpty else {
            print("No HDCD packet followed any reset within 5 s; \(misses) reset points measured.")
            return
        }
        if let first = gaps.first, frameCount > 0 {
            print("First packet after the reset at the start of the input: \(milliseconds(first)).")
        }
        let sorted = gaps.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        print("Audio before the next packet: min \(milliseconds(sorted[0])), median \(milliseconds(median)), " +
              "95th percentile \(milliseconds(p95)), max \(milliseconds(sorted[sorted.count - 1])).")
        print("Reset points with no packet within 5 s: \(misses).")
    }
}

private struct CheckError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
