import CDAudioCore
import Foundation

/// The PCM format of a disc's audio. A CD's table of contents marks each track as audio or data and as
/// two- or four-channel; the Red Book standard fixes every audio track at 44.1 kHz and 16 bits, so a
/// detected audio CD is Red Book audio with the channel count it declares. Playback, the output rate it
/// sets and the player's labels all follow this value.
public struct AudioSourceFormat: Hashable, Sendable {
    /// Frames per second.
    public let sampleRate: UInt64
    public let bitsPerChannel: UInt32
    public let channels: UInt32

    init(sampleRate: UInt64, bitsPerChannel: UInt32, channels: UInt32) {
        self.sampleRate = sampleRate
        self.bitsPerChannel = bitsPerChannel
        self.channels = channels
    }

    /// Red Book audio with the channel count a table of contents declares.
    public static func compactDiscAudio(channels: UInt32) -> AudioSourceFormat {
        AudioSourceFormat(
            sampleRate: UInt64(CD_DA_SAMPLE_RATE), bitsPerChannel: CD_DA_BITS_PER_CHANNEL, channels: channels
        )
    }

    /// Two-channel Red Book audio: every standard audio CD, and the demo disc.
    public static let compactDisc = compactDiscAudio(channels: CD_DA_CHANNELS)

    public var bytesPerFrame: UInt64 { UInt64(bitsPerChannel / 8) * UInt64(channels) }
    /// Frames in one 2,352-byte CD sector: 588 for 16-bit stereo.
    public var framesPerSector: UInt64 { bytesPerFrame == 0 ? 0 : UInt64(CD_SECTOR_BYTES) / bytesPerFrame }
    /// Whether playback carries this format unchanged; it takes 16-bit stereo at the CD rate.
    public var isPlayable: Bool { cd_source_format_supported(cValue) }
    /// The rate as the player names it, such as "44.1 kHz".
    public var rateText: String { Self.rateText(Double(sampleRate)) }
    /// "44.1 kHz / 16-bit", naming the channel count only when it is not stereo.
    public var description: String {
        let text = "\(rateText) / \(bitsPerChannel)-bit"
        return channels == 2 ? text : "\(text) / \(channels)-channel"
    }

    var cValue: CDSourceFormat {
        CDSourceFormat(sampleRate: Double(sampleRate), bitsPerChannel: bitsPerChannel, channelsPerFrame: channels)
    }

    static func rateText(_ rate: Double) -> String {
        let kilohertz = rate / 1000
        let text = kilohertz == kilohertz.rounded() ? String(format: "%.0f", kilohertz) : String(format: "%.1f", kilohertz)
        return "\(text) kHz"
    }
}
