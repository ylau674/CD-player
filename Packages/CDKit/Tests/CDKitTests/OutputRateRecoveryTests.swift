import CDAudioCore
import CDAudioCoreTestSupport
import Testing

@Suite struct OutputRateRecoveryTests {
    private func makeBackend() -> OpaquePointer {
        cd_rate_test_backend_create()!
    }

    @Test func appliesAndRestoresRateThroughTheInjectedBackend() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)

        var error = CDError()
        #expect(cd_rate_test_apply(backend, "output-a", 44_100, &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 44_100)
        #expect(cd_rate_test_has_record(backend, "output-a"))

        cd_rate_test_set_device_owner(backend, "output-a", 4242)
        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        #expect(cd_rate_test_set_calls(backend) == 2)
        #expect(cd_rate_test_wait_calls(backend) == 2)
    }

    @Test func preservesAnExternalRateChangeAndForgetsItsStaleRecord() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)
        var error = CDError()
        #expect(cd_rate_test_apply(backend, "output-a", 44_100, &error) == 0)
        cd_rate_test_set_device_rate(backend, "output-a", 96_000)

        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 96_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        #expect(cd_rate_test_set_calls(backend) == 1)
    }

    @Test func refusesExternalHogOwnerAndKeepsTheRecoveryRecord() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)
        var error = CDError()
        #expect(cd_rate_test_apply(backend, "output-a", 44_100, &error) == 0)
        cd_rate_test_set_device_owner(backend, "output-a", 9001)

        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) != 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 44_100)
        #expect(cd_rate_test_has_record(backend, "output-a"))
        #expect(cd_rate_test_set_calls(backend) == 1)
    }

    @Test func retainsAbsentOutputRecordAndRestoresItAfterReconnect() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_record(backend, "output-a", 384_000, 44_100, true) == 0)
        var error = CDError()

        #expect(cd_rate_test_restore_records(backend, true, &error) == 0)
        #expect(cd_rate_test_has_record(backend, "output-a"))
        #expect(cd_rate_test_set_calls(backend) == 0)

        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        #expect(cd_rate_test_restore_records(backend, true, &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 384_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
    }

    @Test func recoveryOnlySkipsActiveRecordsButRestoreAllProcessesThem() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        #expect(cd_rate_test_add_record(backend, "output-a", 48_000, 44_100, false) == 0)
        var error = CDError()

        #expect(cd_rate_test_restore_records(backend, true, &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 44_100)
        #expect(cd_rate_test_has_record(backend, "output-a"))

        #expect(cd_rate_test_restore_records(backend, false, &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
    }

    @Test func restoringMultipleRecordsUsesAStableSnapshot() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 44_100, -1) == 0)
        #expect(cd_rate_test_add_device(backend, "output-b", 12, 44_100, -1) == 0)
        #expect(cd_rate_test_add_record(backend, "output-a", 48_000, 44_100, true) == 0)
        #expect(cd_rate_test_add_record(backend, "output-b", 384_000, 44_100, true) == 0)
        var error = CDError()

        #expect(cd_rate_test_restore_records(backend, true, &error) == 0)
        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(cd_rate_test_current_rate(backend, "output-b") == 384_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        #expect(!cd_rate_test_has_record(backend, "output-b"))
    }

    @Test func failedRateSetCleansUpItsRecordAndFailedVerificationRetainsIt() {
        let failedSetBackend = makeBackend()
        defer { cd_rate_test_backend_destroy(failedSetBackend) }
        #expect(cd_rate_test_add_device(failedSetBackend, "output-a", 11, 48_000, -1) == 0)
        cd_rate_test_fail_set(failedSetBackend, -50)
        var error = CDError()
        #expect(cd_rate_test_apply(failedSetBackend, "output-a", 44_100, &error) != 0)
        #expect(!cd_rate_test_has_record(failedSetBackend, "output-a"))
        #expect(cd_rate_test_current_rate(failedSetBackend, "output-a") == 48_000)

        let failedWaitBackend = makeBackend()
        defer { cd_rate_test_backend_destroy(failedWaitBackend) }
        #expect(cd_rate_test_add_device(failedWaitBackend, "output-b", 12, 384_000, -1) == 0)
        cd_rate_test_fail_wait(failedWaitBackend, true)
        #expect(cd_rate_test_apply(failedWaitBackend, "output-b", 44_100, &error) != 0)
        #expect(cd_rate_test_has_record(failedWaitBackend, "output-b"))

        cd_rate_test_fail_wait(failedWaitBackend, false)
        #expect(cd_rate_test_restore_uid(failedWaitBackend, "output-b", &error) == 0)
        #expect(cd_rate_test_current_rate(failedWaitBackend, "output-b") == 384_000)
        #expect(!cd_rate_test_has_record(failedWaitBackend, "output-b"))
    }

    @Test func restoreSetAndVerificationFailuresPreserveRecoveryData() {
        let failedSetBackend = makeBackend()
        defer { cd_rate_test_backend_destroy(failedSetBackend) }
        #expect(cd_rate_test_add_device(failedSetBackend, "output-a", 11, 48_000, -1) == 0)
        var error = CDError()
        #expect(cd_rate_test_apply(failedSetBackend, "output-a", 44_100, &error) == 0)

        cd_rate_test_fail_set(failedSetBackend, -50)
        #expect(cd_rate_test_restore_uid(failedSetBackend, "output-a", &error) != 0)
        #expect(cd_rate_test_has_record(failedSetBackend, "output-a"))
        #expect(cd_rate_test_current_rate(failedSetBackend, "output-a") == 44_100)

        cd_rate_test_fail_set(failedSetBackend, 0)
        cd_rate_test_fail_wait(failedSetBackend, true)
        #expect(cd_rate_test_restore_uid(failedSetBackend, "output-a", &error) != 0)
        #expect(cd_rate_test_has_record(failedSetBackend, "output-a"))
        #expect(cd_rate_test_current_rate(failedSetBackend, "output-a") == 48_000)

        cd_rate_test_fail_wait(failedSetBackend, false)
        #expect(cd_rate_test_restore_uid(failedSetBackend, "output-a", &error) == 0)
        #expect(!cd_rate_test_has_record(failedSetBackend, "output-a"))
    }

    @Test func switchingOutputsRestoresThePreviousAndNewOutputRates() {
        let backend = makeBackend()
        defer { cd_rate_test_backend_destroy(backend) }
        #expect(cd_rate_test_add_device(backend, "output-a", 11, 48_000, -1) == 0)
        #expect(cd_rate_test_add_device(backend, "output-b", 12, 384_000, -1) == 0)
        var error = CDError()

        #expect(cd_rate_test_apply(backend, "output-a", 44_100, &error) == 0)
        #expect(cd_rate_test_restore_uid(backend, "output-a", &error) == 0)
        #expect(cd_rate_test_apply(backend, "output-b", 44_100, &error) == 0)
        #expect(cd_rate_test_restore_uid(backend, "output-b", &error) == 0)

        #expect(cd_rate_test_current_rate(backend, "output-a") == 48_000)
        #expect(cd_rate_test_current_rate(backend, "output-b") == 384_000)
        #expect(!cd_rate_test_has_record(backend, "output-a"))
        #expect(!cd_rate_test_has_record(backend, "output-b"))
    }
}
