// cdprobe: unprivileged, read-only probe of an audio CD through its raw device node.
// It stops at the first permission failure and never tries another way in.
//
//   xcrun clang -std=c11 -O2 -Wall -Wextra -o cdprobe cdprobe.c
//   ./cdprobe /dev/rdisk4

#include <IOKit/storage/IOCDMediaBSDClient.h>
#include <IOKit/storage/IOCDTypes.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#define SECTOR_BYTES ((uint32_t)kCDSectorSizeCDDA)
#define C2_BYTES 294u
#define CHUNK_SECTORS 16u
#define FRAMES_PER_SECTOR 588u
#define SECTORS_PER_SECOND 75u
#define MAX_TRACKS 99

typedef struct {
    int number;
    uint32_t lba;
    int is_audio;
} track_t;

static double now_seconds(void)
{
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static int read_area(int fd, uint32_t lba, uint32_t count, uint8_t area, uint32_t block, uint8_t *buf)
{
    dk_cd_read_t r;
    memset(&r, 0, sizeof r);
    r.offset = (uint64_t)lba * block;
    r.sectorArea = area;
    r.sectorType = kCDSectorTypeCDDA;
    r.buffer = buf;
    r.bufferLength = count * block;
    if (ioctl(fd, DKIOCCDREAD, &r) < 0) return -1;
    if (r.bufferLength != count * block) {
        errno = EIO;
        return -1;
    }
    return 0;
}

static int read_sectors(int fd, uint32_t lba, uint32_t count, uint8_t *buf)
{
    return read_area(fd, lba, count, kCDSectorAreaUser, SECTOR_BYTES, buf);
}

static int timed_read(int fd, uint32_t lba, uint32_t sectors, uint8_t *buf, double *elapsed)
{
    double t0 = now_seconds();
    for (uint32_t done = 0; done < sectors; done += CHUNK_SECTORS) {
        uint32_t n = sectors - done < CHUNK_SECTORS ? sectors - done : CHUNK_SECTORS;
        if (read_sectors(fd, lba + done, n, buf) < 0) return -1;
    }
    *elapsed = now_seconds() - t0;
    return 0;
}

static void pcm_stats(const uint8_t *buf, uint32_t sectors, int *peak, double *rms_db, uint32_t *nonzero)
{
    uint32_t samples = sectors * FRAMES_PER_SECTOR * 2;
    double acc = 0;
    int pk = 0;
    uint32_t nz = 0;
    for (uint32_t i = 0; i < samples; i++) {
        int16_t s;
        memcpy(&s, buf + (size_t)i * 2, 2);
        int a = s < 0 ? -(int)s : s;
        if (a > pk) pk = a;
        if (s != 0) nz++;
        acc += (double)s * s;
    }
    *peak = pk;
    *nonzero = nz;
    double rms = sqrt(acc / samples);
    *rms_db = rms > 0 ? 20.0 * log10(rms / 32768.0) : -INFINITY;
}

static int parse_toc(const uint8_t *raw, track_t *tracks, uint32_t *leadout)
{
    const CDTOC *toc = (const CDTOC *)raw;
    uint32_t n = CDTOCGetDescriptorCount((CDTOC *)toc);
    int count = 0;
    *leadout = 0;
    for (uint32_t i = 0; i < n; i++) {
        const CDTOCDescriptor *d = &toc->descriptors[i];
        if (d->adr != 1) continue;
        if (d->point >= 1 && d->point <= MAX_TRACKS && count < MAX_TRACKS) {
            tracks[count].number = d->point;
            tracks[count].lba = CDConvertMSFToLBA(d->p);
            tracks[count].is_audio = (d->control & 0x4) == 0;
            count++;
        } else if (d->point == 0xA2) {
            *leadout = CDConvertMSFToLBA(d->p);
        }
    }
    return count;
}

static int get_speed(int fd, uint16_t *kbps)
{
    return ioctl(fd, DKIOCCDGETSPEED, kbps);
}

static void set_and_report_speed(int fd, uint16_t want, const char *label)
{
    uint16_t v = want;
    if (ioctl(fd, DKIOCCDSETSPEED, &v) < 0) {
        printf("  SETSPEED(%s=%u): FAILED - %s\n", label, want, strerror(errno));
        return;
    }
    uint16_t got = 0;
    if (get_speed(fd, &got) == 0)
        printf("  SETSPEED(%s=%u) ok; drive now reports %u kB/s (%.2fx)\n", label, want, got, got / 176.4);
    else
        printf("  SETSPEED(%s=%u) ok; GETSPEED: %s\n", label, want, strerror(errno));
}

static void throughput_test(int fd, uint32_t lba, uint8_t *buf, const char *label)
{
    const uint32_t sectors = 150;
    double elapsed = 0;
    if (timed_read(fd, lba, sectors, buf, &elapsed) < 0) {
        printf("  read test (%s): FAILED at LBA %u - %s\n", label, lba, strerror(errno));
        return;
    }
    printf("  read test (%s): %u sectors in %.2f s = %.2fx (%.0f kB/s)\n", label, sectors, elapsed,
           sectors / elapsed / SECTORS_PER_SECOND, sectors * SECTOR_BYTES / elapsed / 1000.0);
}

// Sustained throughput from a cold position, so the drive's cache cannot hide its real read rate.
static void speed_test(int fd, uint32_t start, uint32_t end, const char *mode, double seconds)
{
    const uint32_t chunk = 32;
    uint8_t *buf = malloc(chunk * SECTOR_BYTES);
    if (!buf) return;

    uint16_t original = 0;
    int have_speed = get_speed(fd, &original) == 0;
    if (strcmp(mode, "min") == 0)
        set_and_report_speed(fd, kCDSpeedMin, "kCDSpeedMin");
    else if (strcmp(mode, "max") == 0)
        set_and_report_speed(fd, kCDSpeedMax, "kCDSpeedMax");
    else
        printf("  speed left as the drive has it (%u kB/s)\n", have_speed ? original : 0);

    printf("  cold start at LBA %u, mode=%s, up to %.0f s\n", start, mode, seconds);
    uint32_t total = 0, marked = 0;
    double t0 = now_seconds(), marked_at = 0, next = 1.0;
    while (now_seconds() - t0 < seconds && start + total + chunk <= end) {
        if (read_sectors(fd, start + total, chunk, buf) < 0) {
            printf("  read FAILED after %u sectors: %s\n", total, strerror(errno));
            break;
        }
        total += chunk;
        double el = now_seconds() - t0;
        if (el >= next) {
            printf("  t=%5.1fs  %5u sectors  cumulative %5.2fx  last interval %5.2fx\n", el, total, total / el / SECTORS_PER_SECOND,
                   (total - marked) / (el - marked_at) / SECTORS_PER_SECOND);
            marked = total;
            marked_at = el;
            next = floor(el) + 1.0;
        }
    }
    double el = now_seconds() - t0;
    printf("  result: %u sectors in %.2f s = %.2fx\n", total, el, total / el / SECTORS_PER_SECOND);

    if (have_speed) {
        uint16_t v = original;
        ioctl(fd, DKIOCCDSETSPEED, &v);
    }
    free(buf);
}

int main(int argc, char **argv)
{
    if (argc != 2 && !(argc == 6 && strcmp(argv[2], "speedtest") == 0)) {
        fprintf(stderr, "usage: %s /dev/rdiskN [speedtest <none|min|max> <seconds> <track>]\n", argv[0]);
        return 64;
    }
    const char *path = argv[1];

    struct stat st;
    if (stat(path, &st) != 0) {
        printf("stat %s: %s\n", path, strerror(errno));
        return 2;
    }
    printf("device node %s: mode=%04o owner uid=%u (running as uid=%u)\n", path, st.st_mode & 07777, st.st_uid, getuid());

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("open(O_RDONLY): FAILED - %s (errno %d). Stopping; no other access method will be tried.\n", strerror(errno), errno);
        return 2;
    }
    printf("open(O_RDONLY): OK\n");

    _Alignas(8) uint8_t tocbuf[2048];
    track_t tracks[MAX_TRACKS];
    int ntracks = 0;
    uint32_t leadout = 0;
    dk_cd_read_toc_t t;
    memset(&t, 0, sizeof t);
    t.format = kCDTOCFormatTOC;
    t.formatAsTime = 1;
    t.address.session = 1;
    t.buffer = tocbuf;
    t.bufferLength = sizeof tocbuf;
    if (ioctl(fd, DKIOCCDREADTOC, &t) < 0) {
        printf("DKIOCCDREADTOC: FAILED - %s\n", strerror(errno));
    } else {
        ntracks = parse_toc(tocbuf, tracks, &leadout);
        printf("DKIOCCDREADTOC: OK, %d tracks, lead-out LBA %u (%.1f min)\n", ntracks, leadout,
               leadout / (double)SECTORS_PER_SECOND / 60.0);
        for (int i = 0; i < ntracks; i++) {
            uint32_t end = i + 1 < ntracks ? tracks[i + 1].lba : leadout;
            printf("  track %2d  %s  start LBA %6u  length %5.1f s\n", tracks[i].number,
                   tracks[i].is_audio ? "audio" : "DATA ", tracks[i].lba,
                   (end - tracks[i].lba) / (double)SECTORS_PER_SECOND);
        }
    }

    if (ntracks == 0 || !tracks[0].is_audio) {
        printf("No audio track found; stopping before any audio read.\n");
        close(fd);
        return 4;
    }

    if (argc == 6) {
        int wanted = atoi(argv[5]);
        for (int i = 0; i < ntracks; i++) {
            if (tracks[i].number != wanted || !tracks[i].is_audio) continue;
            uint32_t end = i + 1 < ntracks ? tracks[i + 1].lba : leadout;
            speed_test(fd, tracks[i].lba, end, argv[3], atof(argv[4]));
        }
        close(fd);
        return 0;
    }

    uint8_t *buf = malloc(CHUNK_SECTORS * SECTOR_BYTES * 2);
    if (!buf) return 1;

    uint16_t original_speed = 0;
    int have_speed = get_speed(fd, &original_speed) == 0;
    if (have_speed)
        printf("GETSPEED: %u kB/s (%.2fx)\n", original_speed, original_speed / 176.4);
    else
        printf("GETSPEED: FAILED - %s\n", strerror(errno));

    uint32_t probe_lba = tracks[0].lba + 10 * SECTORS_PER_SECOND;
    if (read_sectors(fd, probe_lba, CHUNK_SECTORS, buf) < 0) {
        int e = errno;
        printf("DKIOCCDREAD (first read, LBA %u): FAILED - %s (errno %d)\n", probe_lba, strerror(e), e);
        if (e == EPERM || e == EACCES) printf("Permission denied. Stopping; no other access method will be tried.\n");
        free(buf);
        close(fd);
        return 3;
    }
    int peak;
    double rms_db;
    uint32_t nonzero;
    pcm_stats(buf, CHUNK_SECTORS, &peak, &rms_db, &nonzero);
    printf("DKIOCCDREAD (first read, LBA %u, %u sectors): OK  peak=%d rms=%.1f dBFS non-zero samples=%u/%u\n", probe_lba,
           CHUNK_SECTORS, peak, rms_db, nonzero, CHUNK_SECTORS * FRAMES_PER_SECTOR * 2);

    int second = ntracks > 1 ? 1 : 0;
    uint32_t min_lba = tracks[0].lba + 20 * SECTORS_PER_SECOND;
    uint32_t max_lba = tracks[second].lba + 30 * SECTORS_PER_SECOND;

    printf("Speed control:\n");
    set_and_report_speed(fd, kCDSpeedMin, "kCDSpeedMin");
    throughput_test(fd, min_lba, buf, "min speed");

    printf("Cold seeks at min speed (1 sector each):\n");
    int picks[3] = {0, ntracks / 2, ntracks - 1};
    for (int i = 0; i < 3; i++) {
        uint32_t lba = tracks[picks[i]].lba + 5 * SECTORS_PER_SECOND;
        double t0 = now_seconds();
        if (read_sectors(fd, lba, 1, buf) < 0)
            printf("  seek to track %d: FAILED - %s\n", tracks[picks[i]].number, strerror(errno));
        else
            printf("  seek to track %2d (LBA %6u): %.0f ms\n", tracks[picks[i]].number, lba, (now_seconds() - t0) * 1000.0);
    }

    set_and_report_speed(fd, kCDSpeedMax, "kCDSpeedMax");
    throughput_test(fd, max_lba, buf, "max speed");

    printf("C2 error pointers:\n");
    if (read_area(fd, probe_lba + 100, 1, kCDSectorAreaUser | kCDSectorAreaErrorFlags, SECTOR_BYTES + C2_BYTES, buf) < 0)
        printf("  read with ErrorFlags area: not available (%s)\n", strerror(errno));
    else
        printf("  read with ErrorFlags area: OK (drive returns C2 pointers)\n");

    if (have_speed) {
        uint16_t v = original_speed;
        if (ioctl(fd, DKIOCCDSETSPEED, &v) == 0) printf("Restored drive speed to %u kB/s\n", original_speed);
    }

    free(buf);
    close(fd);
    return 0;
}
