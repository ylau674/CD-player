import CDAudioCore
import CoreAudio
import Testing

@Suite struct OutputFormatTests {
    private let cd = cd_source_format_compact_disc()

    private func virtualFormat(channels: UInt32, planar: Bool) -> AudioStreamBasicDescription {
        let bytes = UInt32(MemoryLayout<Float>.stride) * (planar ? 1 : channels)
        return AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
    }

    private func physicalFormat(channels: UInt32, bits: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0
        )
    }

    private func ranged(_ format: AudioStreamBasicDescription, minimum: Double = 44_100,
                        maximum: Double = 44_100) -> AudioStreamRangedDescription {
        AudioStreamRangedDescription(
            mFormat: format,
            mSampleRateRange: AudioValueRange(mMinimum: minimum, mMaximum: maximum)
        )
    }

    @Test(arguments: [false, true], [UInt32(16), 24, 32])
    func stereoRemainsSupported(planar: Bool, bits: UInt32) {
        var virtual = virtualFormat(channels: 2, planar: planar)
        var physical = physicalFormat(channels: 2, bits: bits)
        #expect(cd_audio_format_supports_native_playback(cd, &virtual, &physical, false))
        #expect(cd_audio_format_supports_native_playback(cd, &virtual, &physical, true))
    }

    @Test(arguments: [false, true])
    func eightChannelPCMRequiresMappedPlayback(planar: Bool) {
        var virtual = virtualFormat(channels: 8, planar: planar)
        var physical = physicalFormat(channels: 8, bits: 24)
        #expect(cd_audio_format_supports_native_playback(cd, &virtual, &physical, true))
        #expect(!cd_audio_format_supports_native_playback(cd, &virtual, &physical, false))
    }

    @Test func rejectsIncompatibleVirtualFormats() {
        let valid = virtualFormat(channels: 8, planar: false)
        var physical = physicalFormat(channels: 8, bits: 24)
        let changes: [(inout AudioStreamBasicDescription) -> Void] = [
            { $0.mSampleRate = 48_000 },
            { $0.mChannelsPerFrame = 1 },
            { $0.mFormatID = kAudioFormatAC3 },
            { $0.mFormatFlags = kAudioFormatFlagIsSignedInteger },
            { $0.mFormatFlags |= kAudioFormatFlagIsBigEndian },
            { $0.mBitsPerChannel = 64 },
            { $0.mBytesPerFrame = 8 },
            { $0.mFramesPerPacket = 2 }
        ]
        for change in changes {
            var virtual = valid
            change(&virtual)
            #expect(!cd_audio_format_supports_native_playback(cd, &virtual, &physical, true))
        }
    }

    @Test func rejectsIncompatiblePhysicalFormats() {
        var virtual = virtualFormat(channels: 8, planar: false)
        let valid = physicalFormat(channels: 8, bits: 24)
        let changes: [(inout AudioStreamBasicDescription) -> Void] = [
            { $0.mSampleRate = 48_000 },
            { $0.mChannelsPerFrame = 2 },
            { $0.mFormatID = kAudioFormatAC3 },
            { $0.mBitsPerChannel = 8 }
        ]
        for change in changes {
            var physical = valid
            change(&physical)
            #expect(!cd_audio_format_supports_native_playback(cd, &virtual, &physical, true))
        }
        #expect(!cd_audio_format_supports_native_playback(cd, nil, &virtual, true))
        #expect(!cd_audio_format_supports_native_playback(cd, &virtual, nil, true))
    }

    @Test func selectsAdvertisedStereoFormatsSupporting44100Hz() {
        var virtualFormats = [
            ranged(virtualFormat(channels: 8, planar: false)),
            ranged(virtualFormat(channels: 2, planar: true), minimum: 48_000, maximum: 96_000),
            ranged(virtualFormat(channels: 2, planar: false), minimum: 44_100, maximum: 96_000)
        ]
        var physicalFormats = [
            ranged(physicalFormat(channels: 8, bits: 24)),
            ranged(physicalFormat(channels: 2, bits: 24), minimum: 44_100, maximum: 96_000)
        ]
        var virtual = AudioStreamBasicDescription()
        var physical = AudioStreamBasicDescription()
        #expect(cd_audio_choose_stereo_formats(
            cd, &virtualFormats, virtualFormats.count, &physicalFormats, physicalFormats.count, &virtual, &physical
        ))
        #expect(virtual.mChannelsPerFrame == 2)
        #expect(virtual.mSampleRate == 44_100)
        #expect(virtual.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        #expect(physical.mChannelsPerFrame == 2)
        #expect(physical.mSampleRate == 44_100)
        #expect(physical.mBitsPerChannel == 24)
    }

    @Test func declinesStereoFormatsWithoutMatchingAdvertisedPairs() {
        var virtualFormats = [ranged(virtualFormat(channels: 8, planar: false))]
        var physicalFormats = [ranged(physicalFormat(channels: 2, bits: 24))]
        var virtual = AudioStreamBasicDescription()
        var physical = AudioStreamBasicDescription()
        #expect(!cd_audio_choose_stereo_formats(
            cd, &virtualFormats, virtualFormats.count, &physicalFormats, physicalFormats.count, &virtual, &physical
        ))
        virtualFormats = [ranged(virtualFormat(channels: 2, planar: false))]
        physicalFormats = [ranged(physicalFormat(channels: 2, bits: 8))]
        #expect(!cd_audio_choose_stereo_formats(
            cd, &virtualFormats, virtualFormats.count, &physicalFormats, physicalFormats.count, &virtual, &physical
        ))
    }

    @Test func distinguishesSingleMultipleAndFailedStreamQueries() {
        let streamSize = MemoryLayout<AudioStreamID>.size
        #expect(cd_audio_classify_output_stream_query(0, streamSize) == CD_STREAM_TOPOLOGY_SINGLE)
        #expect(cd_audio_classify_output_stream_query(0, streamSize * 2) == CD_STREAM_TOPOLOGY_MULTIPLE)
        #expect(cd_audio_classify_output_stream_query(-50, streamSize) == CD_STREAM_TOPOLOGY_QUERY_ERROR)
        #expect(cd_audio_classify_output_stream_query(0, 0) == CD_STREAM_TOPOLOGY_QUERY_ERROR)
        #expect(cd_audio_classify_output_stream_query(0, streamSize + 1) == CD_STREAM_TOPOLOGY_QUERY_ERROR)
    }

    @Test func describesRedBookAudioAsTheSupportedSource() {
        #expect(cd.sampleRate == 44_100 && cd.bitsPerChannel == 16 && cd.channelsPerFrame == 2)
        #expect(cd_source_format_supported(cd))
        for unsupported in [
            CDSourceFormat(sampleRate: 48_000, bitsPerChannel: 16, channelsPerFrame: 2),
            CDSourceFormat(sampleRate: 44_100, bitsPerChannel: 24, channelsPerFrame: 2),
            CDSourceFormat(sampleRate: 44_100, bitsPerChannel: 16, channelsPerFrame: 4)
        ] {
            #expect(!cd_source_format_supported(unsupported))
        }
    }

    @Test func declinesOutputFormatsForASourceItCannotCarry() {
        let fourChannel = CDSourceFormat(sampleRate: 44_100, bitsPerChannel: 16, channelsPerFrame: 4)
        var virtual = virtualFormat(channels: 2, planar: false)
        var physical = physicalFormat(channels: 2, bits: 24)
        #expect(!cd_audio_format_supports_native_playback(fourChannel, &virtual, &physical, false))
        var virtualFormats = [ranged(virtualFormat(channels: 2, planar: false))]
        var physicalFormats = [ranged(physicalFormat(channels: 2, bits: 24))]
        var chosenVirtual = AudioStreamBasicDescription()
        var chosenPhysical = AudioStreamBasicDescription()
        #expect(!cd_audio_choose_stereo_formats(
            fourChannel, &virtualFormats, virtualFormats.count, &physicalFormats, physicalFormats.count,
            &chosenVirtual, &chosenPhysical
        ))
    }

    @Test func followsTheSourceRateWhenMatchingOutputFormats() {
        var virtual = virtualFormat(channels: 2, planar: false)
        var physical = physicalFormat(channels: 2, bits: 24)
        virtual.mSampleRate = 48_000
        physical.mSampleRate = 48_000
        #expect(!cd_audio_format_supports_native_playback(cd, &virtual, &physical, false))
    }
}
