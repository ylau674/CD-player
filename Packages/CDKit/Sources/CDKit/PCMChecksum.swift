import Foundation

/// FNV-1a over interleaved little-endian PCM bytes; diagnostic comparison only, not a cryptographic hash.
public enum PCMChecksum {
    public static let initialValue: UInt64 = 14_695_981_039_346_656_037
    private static let prime: UInt64 = 1_099_511_628_211

    public static func appending(_ bytes: Data, to checksum: UInt64 = initialValue) -> UInt64 {
        bytes.reduce(checksum) { ($0 ^ UInt64($1)) &* prime }
    }

    /// The checksum the engine reports for undecoded little-endian 16-bit PCM. The ring carries each
    /// sample as a 32-bit value shifted left by 16, so every sample contributes two zero bytes first.
    public static func appendingUndecodedPCM16(_ bytes: Data, to checksum: UInt64 = initialValue) -> UInt64 {
        precondition(bytes.count.isMultiple(of: 2), "16-bit PCM must contain whole samples")
        var result = checksum
        var index = bytes.startIndex
        while index < bytes.endIndex {
            result = (result ^ 0) &* prime
            result = (result ^ 0) &* prime
            result = (result ^ UInt64(bytes[index])) &* prime
            result = (result ^ UInt64(bytes[index + 1])) &* prime
            index += 2
        }
        return result
    }

    public static func hexadecimal(_ checksum: UInt64) -> String {
        String(format: "%016llx", checksum)
    }
}
