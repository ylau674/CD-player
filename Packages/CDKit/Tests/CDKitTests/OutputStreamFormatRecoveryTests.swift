import CDAudioCore
import CDAudioCoreTestSupport
import CoreAudio
import Testing

@Suite struct OutputStreamFormatRecoveryTests {
    private func makeBackend() -> OpaquePointer {
        cd_rate_test_backend_create()!
    }

    private func streamFormat(rate: Double, channels: UInt32, bits: UInt32, floating: Bool)
        -> AudioStreamBasicDescription {
        let bytes = (bits / 8) * channels
        let flags: AudioFormatFlags = floating
            ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        return AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0
        )
    }

    private func setFormats(
        _ backend: OpaquePointer, virtualFormat: AudioStreamBasicDescription,
        physicalFormat: AudioStreamBasicDescription
    ) {
        var virtualFormat = virtualFormat
        var physicalFormat = physicalFormat
        cd_rate_test_set_stream_formats(backend, "output-a", &virtualFormat, &physicalFormat)
    }

    private func addFormatRecord(
        _ backend: OpaquePointer, uid: String = "output-a", originalRate: Double, appliedRate: Double,
        originalVirtual: AudioStreamBasicDescription, appliedVirtual: AudioStreamBasicDescription,
        originalPhysical: AudioStreamBasicDescription, appliedPhysical: AudioStreamBasicDescription,
        recoveryPending: Bool
    ) -> Int32 {
        var originalVirtual = originalVirtual
        var appliedVirtual = appliedVirtual
        var originalPhysical = originalPhysical
        var appliedPhysical = appliedPhysical
        return cd_rate_test_add_format_record(
            backend, uid, originalRate, appliedRate,
            &originalVirtual, &appliedVirtual, &originalPhysical, &appliedPhysical, recoveryPending
        )
    }

    private func rememberFormats(
        _ backend: OpaquePointer, originalRate: Double, appliedRate: Double,
        originalVirtual: AudioStreamBasicDescription, appliedVirtual: AudioStreamBasicDescription,
        originalPhysical: AudioStreamBasicDescription, appliedPhysical: AudioStreamBasicDescription,
        error: inout CDError
    ) -> Int32 {
        var originalVirtual = originalVirtual
        var appliedVirtual = appliedVirtual
        var originalPhysical = originalPhysical
        var appliedPhysical = appliedPhysical
        return cd_rate_test_remember_formats(
            backend, "output-a", originalRate, appliedRate,
            &originalVirtual, &appliedVirtual, &originalPhysical, &appliedPhysical, &error
        )
    }

    private func applyFormats(
        _ backend: OpaquePointer, uid: String = "output-a", originalRate: Double, appliedRate: Double,
        originalVirtual: AudioStreamBasicDescription, appliedVirtual: AudioStreamBasicDescription,
        originalPhysical: AudioStreamBasicDescription, appliedPhysical: AudioStreamBasicDescription,
        error: inout CDError
    ) -> Int32 {
        var originalVirtual = originalVirtual
        var appliedVirtual = appliedVirtual
        var originalPhysical = originalPhysical
        var appliedPhysical = appliedPhysical
        return cd_rate_test_apply_formats(
            backend, uid, originalRate, appliedRate,
            &originalVirtual, &appliedVirtual, &originalPhysical, &appliedPhysical, &error
        )
    }

    private func formatsEqual(_ left: AudioStreamBasicDescription, _ right: AudioStreamBasicDescription) -> Bool {
        var left = left
        var right = right
        return cd_audio_stream_formats_equal(&left, &right)
    }

    @Test func formatApplyPersistsBeforeChangingAndRestoreReturnsBothFormatsAndRate() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)
        let originalVirtual = streamFormat(rate: 48_000, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 48_000, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        setFormats(backend, virtualFormat: originalVirtual, physicalFormat: originalPhysical)
        var error = CDError()
        #expect(cd_rate_test_apply(backend, "output-a", 44_100, &error) == 0)

        #expect(applyFormats(
            backend, originalRate: 48_000, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ) == 0)
        #expect(cd_rate_test_has_format_record(backend, "output-a"))
        var currentVirtual = AudioStreamBasicDescription()
        var currentPhysical = AudioStreamBasicDescription()
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        #expect(formatsEqual(currentVirtual, appliedVirtual))
        #expect(formatsEqual(currentPhysical, appliedPhysical))

        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        #expect(formatsEqual(currentVirtual, originalVirtual))
        #expect(formatsEqual(currentPhysical, originalPhysical))
    }

    /// Replays playback start as `cd_playback_start` does: record both formats, switch the rate, then apply
    /// the stream formats.
    private func startPlayback(
        _ backend: OpaquePointer, originalVirtual: AudioStreamBasicDescription,
        appliedVirtual: AudioStreamBasicDescription, originalPhysical: AudioStreamBasicDescription,
        appliedPhysical: AudioStreamBasicDescription, error: inout CDError
    ) -> Bool {
        rememberFormats(
            backend, originalRate: originalPhysical.mSampleRate, appliedRate: appliedPhysical.mSampleRate,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ) == 0 && cd_rate_test_apply(backend, "output-a", appliedPhysical.mSampleRate, &error) == 0 &&
            applyFormats(
                backend, originalRate: originalPhysical.mSampleRate, appliedRate: appliedPhysical.mSampleRate,
                originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
                originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
            ) == 0
    }

    private func currentFormats(_ backend: OpaquePointer)
        -> (virtual: AudioStreamBasicDescription, physical: AudioStreamBasicDescription) {
        var currentVirtual = AudioStreamBasicDescription()
        var currentPhysical = AudioStreamBasicDescription()
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        return (currentVirtual, currentPhysical)
    }

    @Test func restoreKeepsTheOriginalBitDepthWhenAVirtualWriteWouldRepickIt() {
        // The Pioneer N-50 over USB rests at 48 kHz 16-bit and plays at 44.1 kHz 32-bit. After the physical
        // restore the virtual format is already original; writing it anyway made the HAL pick 32-bit.
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)
        cd_rate_test_couple_formats(backend, 32)
        let originalVirtual = streamFormat(rate: 48_000, channels: 2, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 48_000, channels: 2, bits: 16, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: false)
        setFormats(backend, virtualFormat: originalVirtual, physicalFormat: originalPhysical)
        var error = CDError()
        #expect(startPlayback(
            backend, originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ))
        let playing = currentFormats(backend)
        #expect(formatsEqual(playing.virtual, appliedVirtual))
        #expect(formatsEqual(playing.physical, appliedPhysical))

        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        let restored = currentFormats(backend)
        #expect(formatsEqual(restored.virtual, originalVirtual))
        #expect(formatsEqual(restored.physical, originalPhysical))
        #expect(cd_rate_test_virtual_format_set_calls(backend) == 0)
    }

    @Test func applyKeepsTheChosenPhysicalFormatWhenTheHALPrefersAnother() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)
        cd_rate_test_couple_formats(backend, 32)
        let originalVirtual = streamFormat(rate: 48_000, channels: 2, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 48_000, channels: 2, bits: 32, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        setFormats(backend, virtualFormat: originalVirtual, physicalFormat: originalPhysical)
        var error = CDError()
        #expect(startPlayback(
            backend, originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ))
        let playing = currentFormats(backend)
        #expect(formatsEqual(playing.virtual, appliedVirtual))
        #expect(formatsEqual(playing.physical, appliedPhysical))

        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        let restored = currentFormats(backend)
        #expect(formatsEqual(restored.virtual, originalVirtual))
        #expect(formatsEqual(restored.physical, originalPhysical))
    }

    @Test func aNeededVirtualWriteDoesNotLeaveThePhysicalFormatTheHALPicked() {
        // Eight channels down to stereo: the physical write leaves the virtual format's channel count, so the
        // virtual format is still written, and the physical format it displaced is written back.
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)
        cd_rate_test_couple_formats(backend, 32)
        let originalVirtual = streamFormat(rate: 48_000, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 48_000, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        setFormats(backend, virtualFormat: originalVirtual, physicalFormat: originalPhysical)
        var error = CDError()
        #expect(startPlayback(
            backend, originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ))
        let playing = currentFormats(backend)
        #expect(formatsEqual(playing.virtual, appliedVirtual))
        #expect(formatsEqual(playing.physical, appliedPhysical))

        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        let restored = currentFormats(backend)
        #expect(formatsEqual(restored.virtual, originalVirtual))
        #expect(formatsEqual(restored.physical, originalPhysical))
        #expect(cd_rate_test_virtual_format_set_calls(backend) == 2)
    }

    @Test func preRecordedFormatSnapshotSurvivesRateSwitchAndRestores() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)
        let originalVirtual = streamFormat(rate: 48_000, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 48_000, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        setFormats(backend, virtualFormat: originalVirtual, physicalFormat: originalPhysical)
        var error = CDError()
        #expect(rememberFormats(
            backend, originalRate: 48_000, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ) == 0)
        #expect(cd_rate_test_apply(backend, "output-a", 44_100, &error) == 0)
        #expect(cd_rate_test_has_format_record(backend, "output-a"))
        #expect(applyFormats(
            backend, originalRate: 48_000, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ) == 0)
        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        var currentVirtual = AudioStreamBasicDescription()
        var currentPhysical = AudioStreamBasicDescription()
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        #expect(formatsEqual(currentVirtual, originalVirtual))
        #expect(formatsEqual(currentPhysical, originalPhysical))
    }

    @Test func formatOnlyRecordIsRestoredAndRemovedWhenRateWasUnchanged() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        let originalVirtual = streamFormat(rate: 44_100, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 44_100, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        setFormats(backend, virtualFormat: appliedVirtual, physicalFormat: appliedPhysical)
        #expect(addFormatRecord(
            backend, originalRate: 44_100, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, recoveryPending: true
        ) == 0)
        var error = CDError()

        #expect(cd_rate_test_restore_records(backend, true, &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 44_100)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        var currentVirtual = AudioStreamBasicDescription()
        var currentPhysical = AudioStreamBasicDescription()
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        #expect(formatsEqual(currentVirtual, originalVirtual))
        #expect(formatsEqual(currentPhysical, originalPhysical))
    }

    @Test func absentFormatDeviceIsRetainedAndRestoredAfterReconnect() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        let originalVirtual = streamFormat(rate: 48_000, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 48_000, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        #expect(addFormatRecord(
            backend, originalRate: 48_000, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, recoveryPending: true
        ) == 0)
        var error = CDError()

        #expect(cd_rate_test_restore_records(backend, true, &error) == 0)
        #expect(cd_rate_test_has_format_record(backend, "output-a"))
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        setFormats(backend, virtualFormat: appliedVirtual, physicalFormat: appliedPhysical)
        #expect(cd_rate_test_restore_records(backend, true, &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
    }

    @Test func externalFormatIsPreservedWhileTheOtherAppAppliedFormatIsRestored() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        let originalVirtual = streamFormat(rate: 48_000, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 48_000, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        let externalPhysical = streamFormat(rate: 44_100, channels: 6, bits: 24, floating: false)
        setFormats(backend, virtualFormat: appliedVirtual, physicalFormat: externalPhysical)
        #expect(addFormatRecord(
            backend, originalRate: 48_000, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, recoveryPending: false
        ) == 0)
        var error = CDError()

        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        var currentVirtual = AudioStreamBasicDescription()
        var currentPhysical = AudioStreamBasicDescription()
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        #expect(formatsEqual(currentVirtual, originalVirtual))
        #expect(formatsEqual(currentPhysical, externalPhysical))
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
    }

    @Test func formatSetAndVerificationFailuresKeepEnoughStateForRetry() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        let originalVirtual = streamFormat(rate: 48_000, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 48_000, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        setFormats(backend, virtualFormat: originalVirtual, physicalFormat: originalPhysical)
        var error = CDError()

        cd_rate_test_fail_set_format(backend, false, -50)
        #expect(applyFormats(
            backend, originalRate: 48_000, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ) != 0)
        #expect(cd_rate_test_has_record(backend, "output-a"))
        #expect(cd_rate_test_has_format_record(backend, "output-a"))

        cd_rate_test_fail_set_format(backend, false, 0)
        #expect(applyFormats(
            backend, originalRate: 48_000, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ) == 0)
        cd_rate_test_fail_wait_format(backend, true, true)
        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) != 0)
        #expect(cd_rate_test_has_format_record(backend, "output-a"))

        cd_rate_test_fail_wait_format(backend, true, false)
        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        var currentVirtual = AudioStreamBasicDescription()
        var currentPhysical = AudioStreamBasicDescription()
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        #expect(formatsEqual(currentVirtual, originalVirtual))
        #expect(formatsEqual(currentPhysical, originalPhysical))
    }

    @Test func restoreSetFailureRetainsRecordForRetry() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        let originalVirtual = streamFormat(rate: 44_100, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 44_100, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        setFormats(backend, virtualFormat: originalVirtual, physicalFormat: originalPhysical)
        var error = CDError()
        #expect(applyFormats(
            backend, originalRate: 44_100, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ) == 0)

        cd_rate_test_fail_set_format(backend, false, -50)
        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) != 0)
        #expect(cd_rate_test_has_format_record(backend, "output-a"))

        cd_rate_test_fail_set_format(backend, false, 0)
        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        var currentVirtual = AudioStreamBasicDescription()
        var currentPhysical = AudioStreamBasicDescription()
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        #expect(formatsEqual(currentVirtual, originalVirtual))
        #expect(formatsEqual(currentPhysical, originalPhysical))
    }

    @Test func playbackFormatRestoreKeepsPreviouslyRetainedSourceRate() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        #expect(cd_rate_test_add_record(backend, "output-a", 48_000, 44_100, false) == 0)
        let originalVirtual = streamFormat(rate: 44_100, channels: 8, bits: 32, floating: true)
        let appliedVirtual = streamFormat(rate: 44_100, channels: 2, bits: 32, floating: true)
        let originalPhysical = streamFormat(rate: 44_100, channels: 8, bits: 24, floating: false)
        let appliedPhysical = streamFormat(rate: 44_100, channels: 2, bits: 24, floating: false)
        setFormats(backend, virtualFormat: originalVirtual, physicalFormat: originalPhysical)
        var error = CDError()
        #expect(applyFormats(
            backend, originalRate: 44_100, appliedRate: 44_100,
            originalVirtual: originalVirtual, appliedVirtual: appliedVirtual,
            originalPhysical: originalPhysical, appliedPhysical: appliedPhysical, error: &error
        ) == 0)

        #expect(cd_rate_test_restore_formats_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 44_100)
        #expect(cd_rate_test_has_record(backend, "output-a"))
        #expect(!cd_rate_test_has_format_record(backend, "output-a"))
        var currentVirtual = AudioStreamBasicDescription()
        var currentPhysical = AudioStreamBasicDescription()
        #expect(cd_rate_test_get_stream_formats(backend, "output-a", &currentVirtual, &currentPhysical))
        #expect(formatsEqual(currentVirtual, originalVirtual))
        #expect(formatsEqual(currentPhysical, originalPhysical))

        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
    }
}
