#ifndef CD_AUDIO_CORE_TEST_SUPPORT_H
#define CD_AUDIO_CORE_TEST_SUPPORT_H

#include "CDAudioCore.h"

typedef struct CDRateTestBackend CDRateTestBackend;

CDRateTestBackend *cd_rate_test_backend_create(void);
void cd_rate_test_backend_destroy(CDRateTestBackend *backend);
int cd_rate_test_add_device(CDRateTestBackend *backend, const char *uid, AudioDeviceID device,
                            double rate, int32_t owner);
void cd_rate_test_remove_device(CDRateTestBackend *backend, const char *uid);
void cd_rate_test_set_device_rate(CDRateTestBackend *backend, const char *uid, double rate);
void cd_rate_test_set_device_owner(CDRateTestBackend *backend, const char *uid, int32_t owner);
void cd_rate_test_set_stream_formats(CDRateTestBackend *backend, const char *uid,
                                     const AudioStreamBasicDescription *virtualFormat,
                                     const AudioStreamBasicDescription *physicalFormat);
void cd_rate_test_fail_set(CDRateTestBackend *backend, OSStatus status);
/* Models the HAL seen on a USB DAC: a physical-format write carries the virtual format's rate, while a
   virtual-format or rate write re-picks the physical format at the preferred bit depth. 0 turns it off. */
void cd_rate_test_couple_formats(CDRateTestBackend *backend, UInt32 preferredPhysicalBits);
void cd_rate_test_fail_set_format(CDRateTestBackend *backend, bool physical, OSStatus status);
void cd_rate_test_fail_wait(CDRateTestBackend *backend, bool fail);
void cd_rate_test_fail_wait_format(CDRateTestBackend *backend, bool physical, bool fail);
int cd_rate_test_add_record(CDRateTestBackend *backend, const char *uid, double originalRate,
                            double appliedRate, bool recoveryPending);
int cd_rate_test_add_format_record(CDRateTestBackend *backend, const char *uid,
                                   double originalRate, double appliedRate,
                                   const AudioStreamBasicDescription *originalVirtualFormat,
                                   const AudioStreamBasicDescription *appliedVirtualFormat,
                                   const AudioStreamBasicDescription *originalPhysicalFormat,
                                   const AudioStreamBasicDescription *appliedPhysicalFormat,
                                   bool recoveryPending);
int cd_rate_test_remember_formats(CDRateTestBackend *backend, const char *uid,
                                  double originalRate, double appliedRate,
                                  const AudioStreamBasicDescription *originalVirtualFormat,
                                  const AudioStreamBasicDescription *appliedVirtualFormat,
                                  const AudioStreamBasicDescription *originalPhysicalFormat,
                                  const AudioStreamBasicDescription *appliedPhysicalFormat,
                                  CDError *error);
int cd_rate_test_apply_formats(CDRateTestBackend *backend, const char *uid, double originalRate,
                               double appliedRate,
                               const AudioStreamBasicDescription *originalVirtualFormat,
                               const AudioStreamBasicDescription *appliedVirtualFormat,
                               const AudioStreamBasicDescription *originalPhysicalFormat,
                               const AudioStreamBasicDescription *appliedPhysicalFormat,
                               CDError *error);
int cd_rate_test_apply(CDRateTestBackend *backend, const char *uid, double appliedRate, CDError *error);
int cd_rate_test_restore_uid(CDRateTestBackend *backend, const char *uid, CDError *error);
int cd_rate_test_restore_formats_uid(CDRateTestBackend *backend, const char *uid, CDError *error);
int cd_rate_test_restore_records(CDRateTestBackend *backend, bool recoveryOnly, CDError *error);
double cd_rate_test_current_rate(const CDRateTestBackend *backend, const char *uid);
bool cd_rate_test_has_record(const CDRateTestBackend *backend, const char *uid);
bool cd_rate_test_has_format_record(const CDRateTestBackend *backend, const char *uid);
bool cd_rate_test_get_stream_formats(const CDRateTestBackend *backend, const char *uid,
                                     AudioStreamBasicDescription *virtualFormat,
                                     AudioStreamBasicDescription *physicalFormat);
unsigned cd_rate_test_set_calls(const CDRateTestBackend *backend);
unsigned cd_rate_test_wait_calls(const CDRateTestBackend *backend);
unsigned cd_rate_test_virtual_format_set_calls(const CDRateTestBackend *backend);

#endif
