# SACD Roadmap (Draft)

**Status:** Scope and the main design choices confirmed by the owner on
2026-11-04; the feasibility spike passed. Further work is being evaluated
privately; no release is planned.

**Target:** Not scheduled (working label M10).

**Basis:** Read-only analysis of the owner's burned SACD ISO disc, a
feasibility spike on 2026-11-04, and a survey of open-source SACD code; see
[Sources](#sources). Plain DSD decoding is proven against an independent
decoder. DST decoding is untested because no DST disc is available yet.

## Can CD Player play SACD?

Only SACD images burned to a recordable DVD or Blu-ray disc. Pressed SACDs
can't be read by any computer drive.

| Disc | Possible? | Why |
|---|---|---|
| Pressed SACD, high-resolution layer | No | Only SACD players' pickups and chips detect the disc's Pit Signal Processing watermark and decrypt the audio. Modified players and PS3 firmware get around this; that is circumvention and out of scope. |
| Hybrid SACD, CD layer | Usually, today | It is an ordinary Red Book CD. Not yet tried with CD Player. |
| SACD ISO burned to DVD±R or BD-R, plain DSD | Yes | An unencrypted data disc. The spike decoded one with in-house code that matches FFmpeg. |
| SACD ISO with DST compression | Yes, with a DST decoder | Lossless compression used by many SACD images. It needs an in-house decoder or a vendored open-source one (M10.5). |
| DVD-Audio, DVD-Video, Blu-ray audio | Not in M10 | Outside the owner's chosen scope. |

So "SACD support" for CD Player means:

- reading the stereo area of an SACD image burned to DVD or BD;
- converting its DSD to 24-bit PCM at 88.2 kHz with the app's own filter;
- playing that PCM with the same transport, display and output rules as a
  CD.

## How SACD works

- **DSD.** SACD stores each channel as a 1-bit stream at 2.8224 MHz, 64
  times 44.1 kHz ("DSD64"). Noise shaping pushes the quantization noise above
  the audio band, where it rises steeply (see the
  [spike results](#feasibility-spike-2026-11-04)). A DAC can't play DSD as
  PCM. A player either sends DSD natively or as DoP to a DSD-capable DAC, or
  converts it to PCM with a low-pass decimation filter.
- **Levels.** The SACD 0 dB reference is 50% modulation, and peaks may go
  about 3 dB higher. Full modulation, all ones, is the PCM equivalent of
  +6 dB SACD.
- **Disc layout.** The disc uses 2,048-byte sectors:
  - The Master TOC is at sector 510, with copies at 520 and 530.
  - It points to a stereo area TOC and a multichannel area TOC, each with a
    backup.
  - Each area TOC holds the frame format, channel count, total time, track
    list (`SACDTRL1` sector positions, `SACDTRL2` times) and optional text.
  - Audio is grouped in frames of 1/75 s, the same timing as CD sectors.
- **Frame formats.**
  - Plain DSD "3-in-14": three frames in 14 sectors; a stereo frame is
    9,408 bytes.
  - Plain DSD "3-in-16".
  - DST: lossless compression with variable-size frames.
- **Audio sectors.** The spike confirmed this layout on the owner's disc:

  | Part | Size | Fields |
  |---|---|---|
  | Header | 1 byte | From the most significant bit: packet count (3 bits), frame-info count (3), reserved (1), DST flag (1) |
  | Packet info | 2 bytes per packet, big-endian | Frame start (1 bit), reserved (1), data type (3: 2 audio, 3 supplementary, 7 padding), length (11) |
  | Frame info | 3 bytes per frame starting in the sector (4 with DST) | Binary minutes, seconds and frames from the area start |
  | Packets | rest of the sector | In order. Audio packets of one frame join into byte-interleaved channels, oldest sample in the most significant bit. |

- **SACD ISO.** An ISO is an image of the high-resolution layer's data. Its
  ISO 9660 and UDF bridge lists the TOCs and audio areas as files, but the
  Scarlet Book structures at fixed sectors are what a player reads.

## What CD Player does today

Detection uses only the IOKit registry. Any media that isn't `IOCDMedia` is
classified as `.other`, so the owner's disc shows `NOT AUDIO CD` and
`PIONEER BD-RW BDR-XS07U | DVD-ROM`. The app never opens it. The C pipeline
accepts only 44.1 kHz, 16-bit stereo sources (`cd_source_format_supported`).

These parts assume CD audio and would need to change:

- the CD reader (`DKIOCCDREAD`, C2 flags and CD speed);
- the source's Int16 sample interface;
- the timeline's 588 frames per sector;
- the ring and level-slot sizes, both expressed at 44.1 kHz;
- output selection, which requires a 44.1 kHz-capable output.

The output rate switch, `ChangedOutputRates` recovery and the format choice
already follow the source rate.

## Disc analysis

The owner's disc, read on 2026-11-03 and 2026-11-04 with approval, read-only
and unmounted:

- **Disc:** DVD+R (media ID SONY D21), 897,568 sectors, `/dev/rdisk4`
  readable by the logged-in user.
- **Volume:** ISO 9660 and UDF volume `DISC1`, created 2003-10-22, holding
  `MASTER1-3.TOC` and `2C_AUDIO/` with the area TOCs, `2C_TAREA.2CH` and
  `TRACK001-010.2CH`.
- **Master TOC:** version 1.20, with identical copies. The hybrid flag is
  set. Disc date 2001-11-26. No text, catalogue number, ISRCs or genres.
- **Stereo area:** sectors 544–548, with an identical backup at 897534.
  - Plain DSD 3-in-14 at 2.8224 MHz, two channels.
  - 10 tracks, 42:42.61 in all.
  - Audio sectors 549–897533. The 896,985 sectors are exactly 192,211 frames
    × 14/3, so the image is complete.
- **Multichannel area:** none.
- **Album:** not identified. MusicBrainz's fuzzy TOC match was a false
  positive, with track lengths differing by up to 85 s, and the disc carries
  no text.

## Feasibility spike (2026-11-04)

The owner approved one read-only capture. It read 10 s (750 frames) of
track 1, starting 30 s in: sectors 11735–15234 from `/dev/rdisk4`, with CD
Player and the check tools not running. The tools are scratch scripts outside
the repository. The captures were deleted after comparison; only the text
results are kept.

### Disc reading

- **Layout:** all 750 frames were complete (9,408 bytes each). Their
  timecodes started at frame 2397, the requested start, and rose by exactly
  one. The DST flag was 0. Supplementary packets added 91,250 bytes, about
  1.3%.
- **Read rate:** stereo plain DSD needs 350 sectors a second, 700 KiB/s, which
  is also the area's declared maximum byte rate. Reads in 112-sector requests
  ran at 1,189 KiB/s (1.70× real time). After `DKIOCDVDSETSPEED` requested
  the DVD minimum (1,350 KiB/s), they ran at 777 KiB/s (1.11×). The request
  succeeded, but `DKIOCDVDGETSPEED` still reported 11,080 KiB/s, so the
  reported value can't confirm the speed. 1.11× is too little margin for
  steady playback (decision 10).

### DSD to PCM

The in-house prototype is plain C with no third-party code. Its
Kaiser-windowed sinc filters are designed at start-up:

| Stage | Rates | Filter | Purpose |
|---|---|---|---|
| 1 | 2.8224 MHz → 352.8 kHz | 96 taps, applied as 12 byte lookup tables | Flat to 30 kHz; 130 dB rejection wherever noise would alias below 44.1 kHz |
| 2 | 352.8 kHz → 88.2 kHz | 216 taps, ÷4 | Flat to 30 kHz, −3 dB at 36.0 kHz, 129 dB rejection from 44.1 kHz |

The combined passband is flat to within ±0.00001 dB up to 30 kHz. The delay
is 321.5 µs. Full modulation gives exactly 1.0, that is 0 dBFS, so the SACD
0 dB reference plays at −6.02 dBFS.

Results on the captured audio:

- **Accuracy against FFmpeg 7.1.1** (DSDIFF demuxer and `dsd_msbf` decoder,
  resampled to 88.2 kHz with both swr and soxr):
  - The levels were identical to 0.000 dB, so FFmpeg uses the same level
    mapping.
  - The residual from 20 Hz to 20 kHz was −93.0 dB (left) and −87.8 dB
    (right) relative to the music. In every band it was 75–85 dB below the
    music and at most −117 dBFS: the two filters differ only slightly in
    passband shape.
  - Stage 1 alone agreed with FFmpeg's DSD-to-PCM output to −120 dB.
- **Noise:** band power of the decoded signal, left channel, from FFmpeg's
  352.8 kHz output. Above 20 kHz it is mostly DSD noise. The music measured
  −31.6 dB from 20 Hz to 20 kHz.

  | Band | 20–30 kHz | 30–40 kHz | 40–44.1 kHz | 44.1–60 kHz | 60–100 kHz | 100–176.4 kHz |
  |---|---|---|---|---|---|---|
  | Power | −73.6 dB | −64.3 dB | −63.7 dB | −52.0 dB | −39.3 dB | −34.5 dB |

  At 88.2 kHz the prototype left −99.5 dB at 40–44.1 kHz, where FFmpeg's
  resampler left −67.8 dB.
- **Level:** the peak was −14.51 dBFS and the RMS −32.66 dBFS. No samples
  clipped.
- **Word length:** rounding to 24 bits added −149.3 dBFS RMS of error, far
  below DSD's own noise, so no dither is needed.
- **CPU:** 1.58% of one core on an Apple M4 Pro (63× real time). This is
  unoptimized scalar C in double precision.

**Conclusion:** detection, parsing and decoding of plain DSD SACD images can
be done entirely in-house. No open-source decoder is needed for plain DSD.

## How it would fit CD Player

### Detection and the table of contents

- **On insertion:** the registry classifies DVD and BD media, `IODVDMedia`
  and `IOBDMedia`, that isn't blank as a possible SACD. The status reads
  `DVD` or `BD`, and Play is available. The app still doesn't open the disc
  until Play (decision 4).
- **On Play:** a new read-only disc session opens `/dev/rdiskN` and reads
  the Master TOC.
  - It uses a copy when the first is unreadable or inconsistent.
  - It then reads the stereo area TOC, falling back to its backup.
  - A disc without `SACDMTOC` stops with `NOT SACD`. A disc with only a
    multichannel area stops with `STEREO AREA NEEDED`. Neither is read
    further.
- **After Play:** the track count and times stay with the loaded disc until
  it is ejected or changed, as the HDCD state does.
- **Pressed hybrid SACDs:** these reach the app as CDs and keep today's CD
  path.

### Reading

- **Reads:** plain 2,048-byte reads on the disc session's executor, in whole
  sectors. There's no `DKIOCCDREAD`, C2 or SCSI pass-through, and the app
  never mounts the disc. DVD and BD sectors carry their own error
  correction, so a read either returns correct data or fails.
- **Read errors:** a failed read is retried once in `.retry` and not in
  `.singlePass`. The affected frames are muted, and the muted frames are
  counted like concealed CD sectors (`ERR`).
- **Speed:** set with `DKIOCDVDSETSPEED` or `DKIOCBDSETSPEED`, and restored
  on close like the CD speed. Because of the spike's 1.11× result, M10.1
  measures the read rate at the inner, middle and outer areas of the disc
  before the speed policy is fixed (decision 10).
- **Pacing:** the existing paced producer and its 30-second ring keep the
  drive quiet between bursts.

### Parsing

The Scarlet Book parser is in Swift. It reads:

- the Master TOC and both area TOCs;
- the track lists;
- the frame-format and channel fields.

It checks every offset and size against the TOC length and the disc size, so
a damaged or truncated image fails with a short error instead of a crash. The
sector demultiplexer runs on the producer thread and rebuilds frames from
audio packets. It ignores supplementary and padding packets and checks frame
timecodes against the expected position.

### DSD to PCM

- **Code:** the spike's two-stage converter becomes a C module beside the
  producer. Its tables are built once, before playback starts.
- **Rates:** stage 2 has a ÷8 variant for 44.1 kHz output, flat to 20 kHz
  with full rejection from 22.05 kHz (decision 2).
- **Level:** unity gain; full modulation is 0 dBFS. Results are rounded to
  24 bits without dither. In-spec programme peaks no higher than about
  −3 dBFS. Filter overshoot on out-of-spec modulation is clamped and logged.
- **Determinism:** the same frames always give the same PCM, so PCM
  checksums and offline tests work as they do for CDs.
- **Seeking:** decoding starts one frame (13.3 ms) before the target and
  discards that frame's output. The frame is longer than both filters, so
  playback starts with settled filter state.
- **Where it runs:** on the producer thread, never in the HAL callback. The
  ring stays Int32, holding 24-bit samples in its most significant bits.

### DST

DST is part of MPEG-4 Audio (ISO/IEC 14496-3, subpart 10). Many SACD images
use it, so a release without it plays only some images.

- **In-house first.** Write the decoder from the standard.
- **Verification.** Use DST discs with known content:
  - Decode each with the app and with FFmpeg's `dst` decoder, called from a
    developer-only check tool.
  - Compare the PCM; stage 1 already matches FFmpeg's DSD conversion to
    −120 dB, so any bit error shows up clearly.
  - FFmpeg is never linked into the app.
- **If in-house really isn't possible:** vendor FFmpeg's `dstdec.c` and the
  few headers it needs as a second vendored-code exception. Its licence,
  LGPL-2.1-or-later, needs the owner's approval (decision 9).
- **Never used:** the Philips/ISO reference DST code, which sacd-ripper
  bundles. Its notice grants use only in MPEG-4-conforming products. GPL
  code (sacd-ripper, the Kodi add-on) is also excluded.
- **Seeking with DST:** frames vary in size, so seeking uses the sector
  headers' frame timecodes, or the area's access list where present.

### Timeline, display and controls

- **Timeline:**
  - SACD time uses 75 frames a second, like CD.
  - Track starts and lengths come from `SACDTRL2`.
  - One SACD frame is 1,176 PCM frames at 88.2 kHz, or 588 at 44.1 kHz,
    exactly one CD sector's worth.
  - Track 1 starts after the area's lead-in (1.72 s on the owner's disc),
    as CD track 1 does after its pregap.
- **Controls:** previous, next, fast forward, rewind, pause and eject work
  as for CDs.
- **Display:** the status line shows `SACD`. The source text names DSD64 and
  the PCM played, for example `SACD DSD64 → 88.2 kHz / 24-bit`; the exact
  wording is settled in M10.3. Album and track text aren't shown, matching
  CDs, which show no CD-Text.

### Output

- **Rate:** 88.2 kHz when the selected wired output supports it. Otherwise
  the converter produces 44.1 kHz itself rather than leaving the
  conversion to macOS (decision 2). System Default outputs that already
  convert (`CDDeviceInfo.converts`), such as AirPlay and Bluetooth, behave as
  they do for CDs.
- **Word length:** 24-bit samples need an output whose physical format
  carries at least 24 bits (decision 8).
- **Ring:** sizes become per-source. 30 s at 88.2 kHz is 2,646,000 frames,
  about 21 MB.
- **Meters:** measure the converted PCM. Their slots stay 10 ms long
  (882 frames at 88.2 kHz). The SACD 0 dB reference reads −6 dB on the
  meters.
- **HDCD:** never applies to SACD sources.

### The bit-perfect rule

CD audio stays bit-exact, with no resampling, EQ, dither or gain. SACD audio
has no PCM to keep unchanged, so M10 adds one documented exception:

- the stereo area's DSD is converted once, by the in-house filter, at unity
  gain and without dither;
- the converted PCM goes to the output unchanged, with no further resampling
  on wired outputs;
- the conversion is deterministic.

The README, architecture and project rules get this wording when M10 is
approved (decision 7).

## Options considered

1. **In-house parser and converter (chosen).** Proven by the spike. No
   licence questions; the filter is designed for 88.2 kHz output; it is
   small, testable code.
2. **FFmpeg libraries (LGPL).** They have a complete DSD and DST pipeline,
   but they are a large third-party dependency, which the project rules
   forbid. Only `dstdec.c` remains a fallback, for DST alone.
3. **dsd2pcm (BSD-2-Clause).** A permissive 96-tap DSD-to-PCM converter;
   FFmpeg's DSD conversion derives from it. It isn't needed: the in-house
   stage 1 performs the same job and the full chain is designed for
   88.2 kHz.
4. **Kodi `audiodecoder.sacd` and foo_input_sacd's `libdsdpcm`.** These are
   GPL-2.0-or-later and LGPL-2.1-or-later. They need the Kodi SDK or
   foobar2000 on Windows, and they read image files, not discs.
5. **sacd-ripper.** GPL-2.0-or-later, and its DST decoder is the restricted
   Philips/ISO reference code. Used here only as documentation of the
   format's field layout; no code is copied.
6. **Native DSD or DoP output.** This sends the DSD unchanged to a
   DSD-capable DAC and avoids the filter. It suits a later milestone: it
   needs DAC detection, and none of the tested outputs is known to accept
   DoP.
7. **Reading pressed SACDs.** Not possible with computer drives; the
   workarounds are circumvention.

## Proposed milestones

### M10.1: Scarlet Book parsing, detection and reading

- **Parser:** Swift, with offline tests built on synthetic images:
  - valid and damaged Master and area TOCs;
  - backup-copy fallback;
  - a multichannel-only disc and a non-SACD DVD;
  - truncated images;
  - frame formats 2, 3 and DST (the last refused until M10.5).
- **Registry:** classification of DVD and BD media.
- **Session:** a DVD/BD disc session behind a fake, covering open, speed
  set and restore, read errors and cancellation.
- **Demultiplexer:** tests with synthetic sectors, checking every packet
  and frame-info combination seen on the owner's disc.
- **Read-rate check:** a developer-only, read-only `OpticalCheck` option.
  It records the read rate at the disc's inner, middle and outer areas at
  minimum and default speeds. It runs live only with the owner's approval.

**Acceptance:**

- The parser reproduces the owner's disc's TOC from saved TOC sectors.
- The read-rate measurements are recorded and the speed policy is decided.

### M10.2: DSD-to-PCM converter

- **Converter:** a C module with 88.2 kHz and 44.1 kHz outputs. Offline
  tests cover:
  - unity DC gain and the measured passband and stopband;
  - identical output whether frames are converted together or one at a
    time;
  - seek pre-roll;
  - 24-bit rounding and clamping;
  - deterministic checksums.
- **`SACDCheck`:** a developer-only tool, like `HDCDCheck`. It converts a
  DSDIFF file for comparison with FFmpeg.

**Acceptance:** levels match FFmpeg to 0.01 dB, and the 20 Hz–20 kHz
residual stays at least 80 dB below the music on a recorded test excerpt.

### M10.3: player integration

- **Pipeline:** generalize the source format and ring sizes. Add a 24-bit
  source path, choose the output rate (88.2 or 44.1 kHz), and size the
  level slots per source.
- **Interface:** SACD timeline and transport, plus the status line and
  source text.
- **Tests:** offline with the existing fakes; read-policy tests run under
  both `.singlePass` and `.retry`.
- **Checks:** the app build and UI tests pass, and CD behaviour is
  unchanged.

**Acceptance:**

- The CDKit, AudioCheck and UI tests pass normally, with AddressSanitizer
  and with ThreadSanitizer.
- An offline SACD disc plays through the fake output with the expected
  checksum.

### M10.4: live verification on the owner's disc

Every step needs the owner's approval. On the built-in output and a USB DAC:

- Play from stopped, and switch to 88.2 kHz, and back at Pause, Stop and
  quit.
- Use every transport button across tracks.
- Measure the ring's fill and the drive's noise at the chosen speed.
- Measure CPU with the meters shown and hidden.
- Eject.
- On an output without 88.2 kHz, confirm the 44.1 kHz path.
- The owner does a listening check.

**Acceptance:** the whole disc plays without underruns or `ERR`, and the
captured output matches an offline conversion of the same frames.

### M10.5: DST decoding

- **Prerequisite:** a DST-encoded SACD image burned to disc.
- **Decoder:** in-house, from the standard, verified against FFmpeg's `dst`
  decoder through `SACDCheck`.
- **Fallback:** only if in-house is really impossible, and only with the
  owner's approval, vendor FFmpeg's `dstdec.c` (decision 9).

**Acceptance:** whole-disc decodes match the reference, and CPU stays
within the meter-off budget.

### M10.6: documentation and release

- Update the README, architecture, development guide and log, and the
  changelog.
- Package the release.

Whether plain DSD ships before DST is decision 9.

## Decisions

Confirmed by the owner on 2026-11-04:

1. **Scope:** SACD images burned to DVD±R or BD-R, stereo area only.
   Pressed SACDs are impossible; their CD layer stays a CD.
2. **Output:** 24-bit PCM at 88.2 kHz, falling back to 44.1 kHz from the
   app's own converter when the output can't take 88.2 kHz.
3. **Level:** full modulation is 0 dBFS. The SACD reference plays at about
   −6 dBFS, with no make-up gain and no clipping.
4. **Reading the TOC:** only on Play. The rule that the disc isn't touched
   before Play stays.
5. **Approach:** in-house first. Open-source code only where in-house is
   really impossible.

Open, recommendation first:

6. **Approve M10** for implementation, and its order relative to M7.
7. **Bit-perfect exception:** approve the wording in
   [The bit-perfect rule](#the-bit-perfect-rule).
8. **Outputs below 24 bits:** refuse SACD with a short message. The
   alternative is 16-bit with dither, which would add a second exception.
9. **DST:**
   - in-house from the purchased standard; FFmpeg's LGPL `dstdec.c` only as
     an approved fallback;
   - ship plain DSD first (1.4.0) and show `DST NOT SUPPORTED` until M10.5.
10. **Read speed:** use the lowest speed that keeps at least 1.5× real time
    across the disc, rather than the absolute minimum, measured in M10.1.
11. **Multichannel-only images:** refuse for now. A stereo downmix could
    follow later.

## Out of scope

- Reading or decrypting pressed SACDs' high-resolution layer, and
  modified-drive or console workarounds.
- Playing ISO or DSF/DFF files from storage, ripping, or saving audio.
- Multichannel playback and downmixing, for now.
- Native DSD or DoP output, for now.
- DVD-Audio, DVD-Video and Blu-ray audio.
- User-selectable filters, upsampling, and output rates other than 88.2 and
  44.1 kHz.
- Album identification or text display.

## Sources

Accessed on 2026-11-04. Repository contents were read for facts only; no
code is copied.

- sacd-ripper, `libs/libsacd/scarletbook.h` (Scarlet Book structures,
  GPL-2.0-or-later) and `libs/libdstdec/unpack_dst.c` (the MPEG-4
  reference-code notice). <https://github.com/sacd-ripper/sacd-ripper>
- dsd2pcm by Sebastian Gesemann (BSD-2-Clause).
  <https://github.com/qrb7xc/dsd2pcm>
- FFmpeg `libavcodec/dstdec.c` (Peter Ross, LGPL-2.1-or-later), and the DSD
  conversion in `libavcodec/dsd.c` and `libswresample/dsd2pcm.c`.
  <https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/dstdec.c>,
  <https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/dsd.c>,
  <https://github.com/FFmpeg/FFmpeg/blob/master/libswresample/dsd2pcm.c>
- Kodi `audiodecoder.sacd` (GPL-2.0-or-later).
  <https://github.com/xbmc/audiodecoder.sacd>
- foo_input_sacd and `libdsdpcm` (LGPL-2.1-or-later).
  <https://sourceforge.net/projects/sacddecoder/>
- Wikipedia, "Super Audio CD": the disc layers and Pit Signal Processing.
  <https://en.wikipedia.org/wiki/Super_Audio_CD>
- RibShark/OmniDrive issue 22: raw dumps of pressed SACDs stay encrypted.
  <https://github.com/RibShark/OmniDrive/issues/22>
- DSDIFF 1.5 specification: the DSD byte order and the container used for
  the FFmpeg comparison.
  <https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf>
- DoP open standard 1.1. <https://dsd-guide.com/dop-open-standard>
- ISO/IEC 14496-3, MPEG-4 Audio, subpart 10: DST (the standard is not freely
  available).
- Apple IOKit headers `IODVDMediaBSDClient.h`, `IODVDTypes.h` and
  `IOBDTypes.h` (macOS SDK): DVD and BD speed controls and minimum speeds.
