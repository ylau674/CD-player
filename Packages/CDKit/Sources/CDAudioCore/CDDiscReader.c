#include "CDAudioCore.h"

#include <IOKit/storage/IOCDMediaBSDClient.h>
#include <IOKit/storage/IOCDTypes.h>
#include <IOKit/scsi/IOSCSIMultimediaCommandsDevice.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int fail(CDError *error, CDResult code, int32_t status, const char *message)
{
    if (error) {
        error->code = code;
        error->systemStatus = status;
        snprintf(error->message, sizeof error->message, "%s", message);
    }
    return code;
}

static int fail_errno(CDError *error, int value, const char *action)
{
    CDResult code = cd_disc_result_for_errno(value);
    if (error) {
        char reason[128];
        if (strerror_r(value, reason, sizeof reason) != 0) snprintf(reason, sizeof reason, "unknown error");
        error->code = code;
        error->systemStatus = value;
        snprintf(error->message, sizeof error->message, "%s: %s (errno %d).", action, reason, value);
    }
    return code;
}

CDResult cd_disc_result_for_errno(int value)
{
    switch (value) {
    case EACCES:
    case EPERM:
        return CD_DISC_REFUSED;
    case ENOENT:
    case ENXIO:
    case ENODEV:
        return CD_DISC_GONE;
    case EIO:
        return CD_DISC_READ_ERROR;
    default:
        return CD_DISC_FAILED;
    }
}

/* Only a whole disc ("disk" and up to four digits) may be opened, never a path or a slice. */
static bool whole_disc_name(const char *name)
{
    if (strncmp(name, "disk", 4) != 0) return false;
    size_t digits = strlen(name + 4);
    if (digits == 0 || digits > 4) return false;
    for (size_t i = 0; i < digits; i++) {
        if (name[4 + i] < '0' || name[4 + i] > '9') return false;
    }
    return true;
}

int cd_disc_open(const char *bsdName, int *descriptor, CDError *error)
{
    if (descriptor) *descriptor = -1;
    if (!bsdName || !descriptor || !whole_disc_name(bsdName))
        return fail(error, CD_INVALID_ARGUMENT, 0, "The optical disc identifier is invalid.");
    char path[32];
    snprintf(path, sizeof path, "/dev/r%s", bsdName);
    int fd;
    do {
        fd = open(path, O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) return fail_errno(error, errno, "Cannot open the optical disc for reading");
    *descriptor = fd;
    return CD_OK;
}

void cd_disc_close(int descriptor)
{
    /* Retrying close after EINTR could close a descriptor reused by another thread. */
    if (descriptor >= 0) close(descriptor);
}

static int control(int descriptor, unsigned long request, void *argument)
{
    int result;
    do {
        result = ioctl(descriptor, request, argument);
    } while (result < 0 && errno == EINTR);
    return result;
}

int cd_disc_read_toc(int descriptor, uint8_t *buffer, size_t capacity, size_t *length, CDError *error)
{
    if (length) *length = 0;
    if (descriptor < 0 || !buffer || !length || capacity < 4)
        return fail(error, CD_INVALID_ARGUMENT, 0, "The track table request is invalid.");
    dk_cd_read_toc_t request;
    memset(&request, 0, sizeof request);
    request.format = kCDTOCFormatTOC;
    request.formatAsTime = 1;
    request.address.session = 1;
    request.buffer = buffer;
    request.bufferLength = (uint16_t)(capacity < UINT16_MAX ? capacity : UINT16_MAX);
    if (control(descriptor, DKIOCCDREADTOC, &request) < 0)
        return fail_errno(error, errno, "Cannot read the optical disc's track table");
    size_t declared = ((size_t)buffer[0] << 8 | buffer[1]) + 2;
    if (request.bufferLength < 4 || declared > request.bufferLength)
        return fail(error, CD_DISC_READ_ERROR, EIO, "The optical disc returned an incomplete track table.");
    *length = declared;
    return CD_OK;
}

int cd_disc_read(int descriptor, uint64_t firstSector, uint32_t sectorCount, bool errorFlags,
                 uint8_t *buffer, size_t capacity, CDError *error)
{
    uint32_t block = CD_SECTOR_BYTES + (errorFlags ? CD_ERROR_FLAG_BYTES : 0);
    if (descriptor < 0 || !buffer || sectorCount == 0 || sectorCount > CD_MAX_READ_SECTORS ||
        capacity < (size_t)sectorCount * block || firstSector > UINT64_MAX / block - sectorCount)
        return fail(error, CD_INVALID_ARGUMENT, 0, "The audio sector request is invalid.");
    dk_cd_read_t request;
    memset(&request, 0, sizeof request);
    /* The offset counts blocks of the requested areas: audio, plus C2 flags when asked for. */
    request.offset = firstSector * block;
    request.sectorArea = kCDSectorAreaUser | (errorFlags ? kCDSectorAreaErrorFlags : 0);
    request.sectorType = kCDSectorTypeCDDA;
    request.buffer = buffer;
    request.bufferLength = sectorCount * block;
    if (control(descriptor, DKIOCCDREAD, &request) < 0)
        return fail_errno(error, errno, "Cannot read audio sectors from the optical disc");
    if (request.bufferLength != sectorCount * block)
        return fail(error, CD_DISC_READ_ERROR, EIO, "The optical disc returned fewer audio bytes than requested.");
    return CD_OK;
}

uint16_t cd_disc_min_speed(void)
{
    return kCDSpeedMin;
}

uint32_t cd_disc_stream_accurate_mask(void)
{
    return kCDFeaturesCDDAStreamAccurateMask;
}

int cd_disc_get_speed(int descriptor, uint16_t *kilobytesPerSecond, CDError *error)
{
    if (descriptor < 0 || !kilobytesPerSecond)
        return fail(error, CD_INVALID_ARGUMENT, 0, "The drive speed request is invalid.");
    uint16_t value = 0;
    if (control(descriptor, DKIOCCDGETSPEED, &value) < 0)
        return fail_errno(error, errno, "Cannot read the optical drive speed");
    *kilobytesPerSecond = value;
    return CD_OK;
}

int cd_disc_set_speed(int descriptor, uint16_t kilobytesPerSecond, CDError *error)
{
    if (descriptor < 0)
        return fail(error, CD_INVALID_ARGUMENT, 0, "The drive speed request is invalid.");
    uint16_t value = kilobytesPerSecond;
    if (control(descriptor, DKIOCCDSETSPEED, &value) < 0)
        return fail_errno(error, errno, "Cannot set the optical drive speed");
    return CD_OK;
}
