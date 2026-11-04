# HDCD Roadmap

**Status:** Approved by the owner on 2026-11-03, with every recommendation
under [Decisions](#decisions) accepted. Preparation and read-only disc
analysis are complete. M8.1 producer integration and synthetic offline tests
are implemented, and the developer FFmpeg FATE cross-check matches bit for
bit. The full offline suite passes normally, under Address Sanitizer and under
Thread Sanitizer (now 442 CDKit and 29 AudioCheck tests). All 20 native app tests
pass, and the generated Debug app build succeeds. M8.2 interface, preference
persistence and offline tests are implemented. M8.3 live verification is done
with the owner's first HDCD disc, whose packets switch nothing on: it plays
bit-perfect on a 32-bit output; see
[M8.3](#m83--live-verification-with-hdcd-discs). M8.4 then put HDCD on the
status line and the played bit depth in the source text, so that disc shows
`HDCD PLAYING` and `44.1 kHz / 16-bit HDCD`; see
[M8.4](#m84--hdcd-on-the-status-line-implemented). Neither of the owner's two
HDCD discs switches anything on, so decoding was then verified live on a
CD-RW burned from FFmpeg's HDCD test sample: the engine's decoded output
equals an independent decode bit for bit, including a track whose HDCD
effect starts after the 2-second hold and a mid-track seek. The owner then
listened to that disc in the Release app and checked an ordinary CD as a
control. The listening found a display bug, fixed in the
[M8.4 follow-up](#m84-follow-up--the-depth-follows-the-playing-position-implemented):
the bit depth shown now changes with the audio, not with the producer's
read-ahead. M8.3 is closed with synthetic offline validation and a live
test on a CD-RW burned from a generated Peak Extend signal. The live
capture matched the source, the app's rendered checksum matched an
independent decode, and the owner heard the tone in the app with HDCD shown.
Verification on real-program HDCD whose musical peaks
are lifted by Peak Extend remains follow-up work.
See [M8.3](#m83--live-verification-with-hdcd-discs). M8 is complete.

**Release:** [Version 1.3.0](https://github.com/ylau674/CD-player/releases/tag/v1.3.0),
as milestone M8. The
[audio output selection roadmap](AUDIO_OUTPUT_ROADMAP.md) (M6) was complete
before it, and M8 came before the [MQA-CD roadmap](MQA_CD_ROADMAP.md) (M7).

**Basis:** Web research and a local decoding check on 2026-11-01; see
[Feasibility check on this Mac](#feasibility-check-on-this-mac) and
[Sources](#sources). One real HDCD disc was analysed read-only on
2026-11-03; see [Disc analysis](#disc-analysis).

## Can CD Player decode HDCD?

Yes. Unlike MQA, HDCD can be decoded inside the app:

| Question | Answer |
|---|---|
| Is there a usable decoder? | Yes. libhdcd (Simplified BSD licence) and FFmpeg's `hdcd` filter (a 3-clause BSD-style licence) share one code base. On this Mac their output was bit-identical on FFmpeg's HDCD test samples. |
| Patents | The five Pacific Microsonics patents checked, all with a 1991 priority date, are listed as expired. |
| Licence or fee | None found for decoding. The patents have expired, Microsoft closed its HDCD website in 2005, and no current licensing programme was found. FFmpeg and foobar2000 have shipped decoders for years. |
| Trademark | Microsoft's US registration of the word "HDCD" (No. 2,378,793) was cancelled on 5 November 2021 (USPTO). Other countries were not checked. The app would use the plain word only, never the logo. |
| Output path | The built-in output runs 32-bit float at 44.1 kHz, so 20-bit decoded samples reach Core Audio exactly. |
| CPU | libhdcd decoded about 14,500 times faster than real time here, about 0.007% of one core. |

What decoding costs:

- **It changes the samples on purpose.** For an HDCD disc, the decoded
  output is the intended result, but it is no longer the disc's bits.
- **Decoded discs play about 6 dB quieter.** The decoder keeps the top
  6 dB for peaks it restores. The app would not add gain back, because that
  would clip those peaks.
- **The benefit depends on the disc.** Forum analyses report that many
  HDCD discs switch on neither Peak Extend nor gain adjustment, and that
  about half of the discs using Peak Extend never reach the level where it
  acts. For a disc that uses neither feature, decoding is exactly a 6.02 dB
  level drop, so the app would leave such discs bit-perfect (see
  [Decoding mode](#decoding-mode)). These figures are approximate.

So the open questions are how decoding sits beside the app's bit-perfect
promise, and how it is shown, not whether it can be done.

## How HDCD works

- **A normal CD.** HDCD discs are Red Book 16-bit/44.1 kHz CDs and play on
  any player. Pacific Microsonics released the first in 1995. Microsoft
  bought the company and its intellectual property in 2000. There were over
  5,000 titles by 2001 and about 4,000 still available in 2008. (Wikipedia.)
- **Hidden control codes.** The least significant bits of each channel form
  a slow bitstream that carries short control packets. A decoder recognises
  valid packets and switches its features on or off; without packets it
  changes nothing but the level (see below). (FFmpeg `af_hdcd.c`.)
  - A packet starts with a fixed sync pattern and carries an 8-bit control
    code, either alone (format A) or followed by an inverted copy for
    checking (format B).
  - The code holds the gain adjustment (0 to −7.5 dB in 0.5 dB steps), the
    Peak Extend switch and the Transient Filter flag.
  - If no valid packet arrives for 2 s (the code-detect timer), the decoder
    returns to no gain adjustment and no Peak Extend.
  - FFmpeg reports three states: no packets, packets whose codes all switch
    nothing on ("no effect"), and packets that do switch features on.
- **Peak Extend** is a reversible soft limiter. In the decoder's tables,
  input above −3.1 dBFS is expanded so that the top 3.1 dB of the disc's
  range fills the top 9.1 dB of the decoded range, up to full scale.
  (FFmpeg `af_hdcd.c`.)
- **Low-level range extension** is a reversible gain on quiet passages. The
  decoder applies gain adjustments of 0 to −7.5 dB as the packets signal.
  (libhdcd.)
- **Transient Filter flag:** a hint for a hardware decoder's reconstruction
  filter. FFmpeg detects it but does not apply it, and no software decoder
  found applies it.
- **Output:** 20-bit PCM. (FFmpeg.)
- **Undecoded playback** works on any player. Discs mastered with Peak
  Extend then play with their peaks soft-limited, which is why the
  "compatible" claim is disputed. (Wikipedia.)

## Feasibility check on this Mac

A throw-away check, not part of the app, run on 2026-11-01:

- **Tools:**
  - Homebrew FFmpeg 7.1.1 and its `hdcd` filter.
  - libhdcd at commit `c574f99` (July 2017), compiled from source into a
    small harness.
  - FFmpeg's test-suite (FATE) samples `hdcd-mix.flac` (9 s, HDCD) and
    `hdcd-false-positive.flac` (3 s, not HDCD).
- **Exactness:**
  - FFmpeg's decoded output matched the checksum in FFmpeg's own test
    (`fate-filter-hdcd-mix`).
  - libhdcd's output was bit-identical to FFmpeg's on both samples.
- **Detection:**
  - The HDCD sample was reported as "HDCD detected: yes, peak_extend:
    enabled intermittently, max_gain_adj: -7.0 dB, transient_filter:
    detected, detectable errors: 0".
  - The other sample was reported as "HDCD detected: no".
- **Level:**
  - On the non-HDCD sample, every decoded sample was exactly half the
    input: a lossless one-bit shift, 6.02 dB down.
  - On the HDCD sample, 96.1% of samples were exactly half; the rest carried
    gain adjustment or peak extension. Those values are not on a 20-bit
    grid: libhdcd applies the gain at full 32-bit precision (measured later,
    in [M8.3](#m83--live-verification-with-hdcd-discs); the first version of
    this note said they were). The RMS level fell from −13.3 to −19.3 dBFS.
  - A full-scale test tone decoded to −6.02 dBFS without Peak Extend and to
    0.00 dBFS with it forced on, which confirms the 6 dB of headroom.
- **Timing:** the first valid packet came 1.34 s into the HDCD sample,
  after a near-silent opening (−56 dBFS RMS). Packets then arrived in
  bursts. Windows Media Player is known to miss HDCD on a track whose start
  carries no packet. (Wikipedia.)
- **Speed:** about 14,500 times real time on one core.

Not covered: a real HDCD disc, the provenance of the test samples, and the
Transient Filter.

## Disc analysis

A read-only analysis of the owner's HDCD disc on 2026-11-03, before any
decoding code. CD Player was closed and nothing was played.

The [recorded verification transcript](validation/hdcd-2026-11-03.log)
contains the full-track capture commands and output, sector/frame counts,
WAV checksums, drive-speed restoration, complete FFmpeg results, sample
comparison and cleanup confirmation. This repeat analysis retains text only,
not the disc's audio.

FFmpeg logs an initial empty filter instance as "HDCD detected: no"; the
processed instance's final summary and nonzero packet counters give each
track's result.

- **Method:**
  - `AudioCheck --capture-pcm` (developer-only) copied each audio track,
    read-only, at the slowest speed the drive accepts, into a private
    temporary WAV file. The drive reported 4,233 kB/s before and after; it
    does not honour the 176 kB/s request.
  - FFmpeg 7.1.1's `hdcd` filter analysed each track and the whole disc as
    one continuous stream, as the app plays it. Its decoded output was
    compared sample by sample with the input.
  - The captures were deleted after the analysis. The disc's title was not
    recorded.
- **Disc:** PIONEER BDR-XS07U drive; three audio tracks, 14:13, no
  pre-emphasis. 0 C2-flagged sectors in all reads.
- **Results:**

  | Track | Length | HDCD packets (L+R) | Peak Extend | Gain adjustment | First positive prefix | Errors |
  |---|---|---|---|---|---|---|
  | 1 | 5:38 | 6,726, format B | never | 0.0 dB | 46,807 frames / 1.061383 s | 0 |
  | 2 | 4:19 | 5,176, format B | never | 0.0 dB | 82 frames / 0.001859 s | 0 |
  | 3 | 4:17 | 5,114, format B | never | 0.0 dB | 558 frames / 0.012653 s | 0 |

  - First positive prefix means the shortest original stereo-frame prefix
    for which FFmpeg reports HDCD. `atrim=end_sample=N` runs before `hdcd`;
    both the positive boundary and the negative `N-1` boundary are logged.
    It is not a measurement of the future app's startup latency.
  - Packets arrive about ten times a second per channel, and the 2-second
    code-detect timer never expired.
  - No Transient Filter flag was found.
  - Decoding the whole disc gave exactly the input at half scale for all
    75,301,632 samples, with zero mismatches and the decoded file's end
    verified: a pure 6.02 dB drop. In the integer representations this is
    `decodedInt32 == sourceInt16 * 32768`, not identical integer values.
- **What it means:**
  - This disc is an HDCD disc whose codes switch nothing on. Under the
    approved [decoding mode](#decoding-mode), once M8 is implemented it will
    play undecoded and bit-perfect, and show `44.1 kHz / 16-bit HDCD`
    (`44.1 kHz / HDCD source` before M8.4).
    Decoding it would only make it quieter.
  - The measured prefixes support the proposed 2-second detection window at
    this disc's track starts. Arbitrary seeks and the app's decision timing
    still need the M8.1 tests; they were not exercised by this analysis.
  - It is the undecoded HDCD case for M8.3. Testing actual decoding needed a
    disc that uses Peak Extend or gain adjustment; neither of the owner's
    discs does, so M8.3 used a burned test disc.
- **Second disc (analysed the same way, 2026-11-03):** a different HDCD disc
  of the owner's, to see whether it could test decoding. It cannot.
  - Three audio tracks, 12:38 (33,427,800 frames), no pre-emphasis. Every
    track carries format B packets, 15,088 in all (L+R). FFmpeg reports Peak
    Extend never enabled, a 0.0 dB maximum gain adjustment, no Transient
    Filter and no detectable errors, on each track and on the whole disc as
    one stream.
  - Decoding the whole disc gave exactly the input at half scale for all
    66,855,600 samples, with zero mismatches, and the app's pinned libhdcd
    (`HDCDCheck`) produced the same bytes as FFmpeg.
  - C2 flagged 55 and 71 sectors in tracks 1 and 2 and none in track 3. The
    packet analysis was unaffected.
  - The captures were deleted afterwards and the title was not recorded.

## What decoding needs from the player

1. **Unaltered 16-bit input.** Decoding must come before any other change
   to the samples; CD Player makes none. A concealed sector (`ERR n`,
   13.3 ms of audio) corrupts any packet inside it. Packets carry error
   detection, and the decoder keeps its state until its code-detect timer
   (2 s by default) expires, so a single concealed sector should not change
   the sound. This is inferred, not observed.
2. **Continuity.** The decoder's state follows the audio. libhdcd recommends
   a reset on every seek and, ideally, decoding from a couple of seconds
   before the target.
3. **At least 20 bits to the DAC.** Float32, with its 24-bit mantissa,
   carries 20-bit values exactly. The output device's physical format must
   carry them too:
   - the built-in output: 32-bit float at 44.1 kHz (read-only check,
     2026-11-01);
   - the beyerdynamic PRO X: 32-bit integer (live check for M6);
   - the Pioneer N-50: its manual (p. 18) lists 16-, 24- and 32-bit PCM
     at 44.1 kHz on its USB input, and chosen directly it plays at 32-bit
     integer (live check for M6.5), so it can carry them. Earlier M6
     checks also saw it running at 16-bit integer; in that format Core
     Audio's conversion would drop the lowest 4 bits.
4. **A decision before the audio is heard.** Switching between decoded and
   undecoded output changes the level by 6 dB.

## How it would fit CD Player

| Part | 1.0.0 | With HDCD decoding |
|---|---|---|
| Where | — | In the producer thread, between `DiscPCMSource` reads and the ring. The IOProc stays a plain conversion. |
| Ring | Int16, 1,323,000 frames, about 5.3 MB | Int32, about 10.6 MB. Undecoded samples are stored as the 16-bit value shifted left by 16, so they stay exact. |
| IOProc | Int16 to Float32, factor 2⁻¹⁵ | Int32 to Float32, factor 2⁻³¹. Tests again cover all 65,536 undecoded values. |
| PCM checksum | Disc samples | The samples rendered, decoded or not. |

The source format is already a value that flows from the TOC
(`AudioSourceFormat`, then `CDPCMSource.format` in C) rather than constants.
An HDCD disc is detected as a 44.1 kHz, 16-bit source. Decoding would add a
decoded format after the producer, and `cd_source_format_supported` would
stay the gate for what the pipeline accepts.

### Decoding mode

- **Per disc, decided before the audio enters the ring.** At the first Play
  of a disc, the producer runs the decoder over what it reads and holds that
  audio until it finds a valid packet that switches Peak Extend or a gain
  adjustment on, or a detection window passes. The window is proposed at
  2 s of audio: the decoder's code-detect timer, and the same length as the
  existing 2-second startup buffer, so little or no extra delay is
  expected. The length is tuned on real discs in M8.3.
- **Such packets found:** the disc plays decoded from the first held
  sample, and stays decoded until it is ejected.
- **Packets that switch nothing on:** the disc plays undecoded and
  bit-perfect. Decoding it would give exactly the same samples 6.02 dB
  lower, so it would gain nothing.
- **No packets:** the disc plays undecoded and bit-perfect, as in 1.0.0.
- In both undecoded cases the producer keeps checking. If packets that
  switch a feature on appear later, decoding starts at the next track start
  or seek, never within a track, so the level never changes mid-track.
- The result is kept only while the disc is in the drive. Nothing new is
  stored on disk.

### Seeking, skipping and pausing

- A track change or a 10-second skip resets the decoder. There is no
  pre-roll by default, because reading 2 s before each target would slow
  every skip at the drive's lowest speed.
- Until the next packet after a reset, the decoder applies neither gain
  adjustment nor peak extension, at the decoded level. M8.3 measures how
  long that lasts on real discs; a pre-roll is added only if it is audible.
  On the owner's disc the next packet followed within 102 ms of any reset,
  median 52 ms, except at the start of track 1, which has 1.06 s of audio
  before its first packet.
- Pause keeps the ring and the decoder's state.

### What the display shows

Revised by the owner in M8.4 (2026-11-03): the status line names an HDCD
disc, and the source text names the bit depth it plays at. HDCD is only
known once playback has read the disc's audio, so a disc shows as a CD until
then; the app reads no audio before Play.

| State | Status line | Source text (row 1, left of the power button) |
|---|---|---|
| Not HDCD, or not yet known | `CD DETECTED`, `CD PLAYING`, `CD PAUSED`, `CD END` | `44.1 kHz / 16-bit source` (unchanged) |
| HDCD found, played unchanged | `HDCD DETECTED`, `HDCD PLAYING`, `HDCD PAUSED`, `HDCD END` | `44.1 kHz / 16-bit HDCD` |
| HDCD found and decoded | as above | `44.1 kHz / 20-bit HDCD` |

- An HDCD disc holds 16-bit samples. The extra resolution, up to 20 bits,
  exists only once decoded, so the depth shown is 16 unless this run decodes.
- The depth follows the audio at the playing position, not the producer's
  read-ahead. The producer runs up to 30 s ahead of playback, so a late
  discovery (decoding that starts at a later track) is decoded in the ring
  long before it plays. The engine reports decoded only once playback
  reaches the first decoded frame, to within one output buffer, so the text
  changes when the level does.
- Once found, HDCD stays shown for the disc until it is ejected or changed.
  Stop then shows `HDCD DETECTED`. A later Play, skip or seek keeps the
  status and the depth while that run detects again, so neither drops back
  to CD or 16-bit for a moment; a run with Decode HDCD off shows 16-bit at
  once, since it cannot decode.
- The tooltip and accessibility label explain the state: "HDCD disc using no
  decodable features; its 16-bit audio plays unchanged and bit-perfect.",
  "HDCD disc decoded to 20-bit PCM. It plays about 6 dB quieter; no make-up
  gain is applied." or why an HDCD disc is not decoded, such as "the selected
  output carries only 16 bits". The status line's VoiceOver label reads, for
  example, "HDCD playing" or "HDCD disc detected".
- Both source texts are no longer than `44.1 kHz / 16-bit source`, so they
  fit the row; a longer status line is handled by the existing layout, which
  shortens the output name first. The rate icon does not change.

### Setting

- **Playback › Decode HDCD**, a checkmark item, remembered between launches.
- With it off, every disc plays bit-perfect, as in 1.0.0. That is also the
  setting for an external HDCD decoder (an HDCD DAC or receiver after M6),
  which needs the undecoded stream.
- Changing it applies at the next Play, track start or seek, never within a
  track.

### Outputs (with M6)

- Decode only when the selected output's physical format carries at least
  20 bits: Float32, or a 24- or 32-bit integer format.
- On an output whose physical format is 16-bit, play undecoded and
  bit-perfect, and show "16-bit HDCD". The rule follows the format in use,
  not the device: the N-50 at 32-bit decodes, at 16-bit it does not.
  Adding dither so that the decoder's output fits 16
  bits would be new processing for little gain.
- System Default (AirPlay or Bluetooth) is best effort, so it follows the
  same rule using the format Core Audio reports.

### Level

- No make-up gain. Peak Extend restores peaks up to full scale, so adding
  the 6 dB back would clip them.
- HDCD discs therefore play about 6 dB quieter than other CDs; the volume
  keys adjust it, as for any quiet disc. The app never changes the volume
  to compensate.

## Hardware

Decoding in the app needs no HDCD hardware. It works with any output whose
format carries at least 20 bits, including the Mac's built-in output today.

Outputs already used with CD Player:

| Output | Decodes HDCD itself? | Carries decoded 20-bit audio? |
|---|---|---|
| Built-in output (MacBook Pro speakers and headphone jack) | No. macOS and Apple Music do not decode HDCD (forum reports). | Yes: 32-bit float |
| beyerdynamic PRO X | None found (not checked in detail) | Yes: 32-bit integer |
| Sony Walkman NW-A306 (USB DAC mode) | None found (not checked in detail) | Yes: macOS uses 32-bit integer at 44.1 kHz (checked in M8.3) |
| Pioneer N-50 | No: neither its specifications nor its manual mention HDCD | Yes when at 32-bit integer, the format it uses when chosen directly (M6.5); its manual (p. 18) lists 16-, 24- and 32-bit USB input. No at 16-bit. |

External HDCD decoders:

- HDCD decoding was built into Pacific Microsonics' own chips and, from
  1998, low-cost DAC chips from Burr-Brown and Sanyo; Motorola and C-Cube
  DVD chips included it too. (Wikipedia.)
- Players that decode HDCD include Oppo's universal players, some
  Panasonic DVD players, several Yamaha Blu-ray players and Emotiva CD
  players (Wikipedia). Oppo's players are reported to decode only on their
  analogue outputs. All of these are out of production.
- Few current products decode HDCD; forum reports name only a few
  high-end DACs, and no current AV receiver was found. Not verified.
- Most of these are disc players that decode their own discs. A computer
  can use one only if it is a DAC or receiver that decodes HDCD on its
  digital input. That needs M6 to select it, and "Decode HDCD" off so that
  the undecoded stream reaches it unchanged.

## Discs

- **How many:** over 5,000 titles by 2001 and about 4,000 still available
  in 2008, from many labels. Well-known examples include albums by Neil
  Young, the Beach Boys and the Grateful Dead. (Wikipedia.)
- **Labelling:** many HDCD discs carry the HDCD logo, but some reportedly
  do not, and a logo does not show which features a disc uses. Detection by
  the decoder is the reliable test.
- **Features used:** forum users who analysed their collections report that
  many HDCD discs use neither Peak Extend nor gain adjustment. Hydrogenaudio
  keeps a list of analysed discs and their features. These reports are
  approximate and were not checked here.
- **For M8.3:** the owner's disc covers the HDCD disc whose packets switch
  nothing on (see [Disc analysis](#disc-analysis)). Still needed:
  - one disc that uses Peak Extend and reaches the level where it acts;
  - one disc that uses gain adjustment;
  - an ordinary CD as a control.

## Options considered

1. **Decode in the app, only discs whose HDCD packets switch a feature on:
   recommended.**
   - An existing BSD-licensed decoder, expired patents, negligible CPU.
   - Non-HDCD discs, and HDCD discs that use no feature, stay bit-perfect.
   - Works with the built-in output today, without M6.
   - The simpler variant, decoding every disc with HDCD packets, would make
     discs that use no feature 6 dB quieter for no gain.
2. **Detection only: possible first step, not an end point.**
   - Shows that a disc is HDCD without changing the sound. It is the same code
     without the decoded output, so it is the natural first stage of
     option 1 (M8.1).
3. **Always decode, as FFmpeg's filter does: rejected.**
   - Every disc would play 6 dB quieter and never bit-perfect.
4. **Leave decoding to external hardware only: kept as a setting.**
   - The built-in output has no HDCD decoder. After M6, an HDCD-capable DAC
     or receiver decodes the undecoded stream when "Decode HDCD" is off.
5. **Bundle FFmpeg: rejected.**
   - Much larger than the few libhdcd files needed, for identical output.
6. **Write a new decoder: unnecessary.**
   - libhdcd already matches FFmpeg bit for bit.

### The decoder's provenance

- libhdcd's authors list its lineage: Christopher Key reverse engineered the
  Windows Media Player decoder; Chris Moeller based foobar2000's `foo_hdcd`
  on that work; it was optimised, ported to FFmpeg (in 3.1) and then made a
  stand-alone library.
- Key did not publish his source because HDCD was patented. Those patents
  have now expired, and the BSD-licensed code has shipped in FFmpeg for
  years.
- The risk looks low, but this is not legal advice. Vendoring keeps the
  copyright notices, and the BSD licence requires them to be reproduced in
  the app's documentation or other materials.

## Proposed milestones

### M8.1 — Decoder and detection, offline

- Vendor libhdcd at a pinned commit as a C target beside `CDAudioCore`,
  keeping its licence. Only the decoder, tables and the simple API are
  needed.
- Widen the ring and IOProc to 32-bit samples. Undecoded output must stay
  exact for all 65,536 values.
- Implement the per-disc decision, track-boundary switching and seek reset
  in the producer, with detection results in the engine snapshot.
- Tests:
  - synthetic signals carrying valid packets, built from the decoder's
    packet format, so no test audio of unknown provenance is committed;
  - non-HDCD input passes through bit-exact;
  - input whose packets switch nothing on also passes through bit-exact;
  - the mode never changes within a track;
  - a developer-only cross-check that compares the app's decoder with
    FFmpeg's `hdcd` filter on FFmpeg's test samples, downloaded at check
    time, which must match bit for bit.
- Acceptance: all existing tests pass; Release CPU stays within about one
  percentage point of the 1.7% recorded in the
  [CPU and memory check](DEVELOPMENT_LOG.md#cpu-and-memory-check-2026-10-31).

### M8.2 — Interface and setting (implemented)

- Playback › Decode HDCD, the source-text states, tooltip and VoiceOver
  labels.
- With M6, the output rule (at least 20 bits).
- README: the "Bit-perfect source path" and "What bit-perfect means here"
  sections say that HDCD discs are decoded when the setting is on, and that
  other discs are unaffected. Credit libhdcd's authors.

### M8.3 — Live verification with HDCD discs

- Discs: at least one HDCD disc that uses Peak Extend, one that uses gain
  adjustment, and an ordinary CD as a control.
- A developer-only option in `AudioCheck` captures the PCM the app reads.
  FFmpeg decodes that capture, and its checksum must equal the app's.
- Measure the time to detection at the start of a disc, after a track
  change and after a 10-second skip; the startup delay against 1.0.0; and
  CPU and memory in Release.
- Listen for level jumps within a track (there must be none) and confirm
  the 6 dB level difference.

**Done on 2026-11-03 with the owner's disc** (packets that switch nothing
on), on the Walkman NW-A306 over USB with headphones. The
[transcript](validation/hdcd-m8-3-2026-11-03.log) keeps the text output
only.

- **Bit-perfect:** the silent pipeline check passed with decoding on and
  with `--hdcd-off`. In every segment (start, seek, track boundary, pause,
  resume, end of disc) the checksum matched independent reads of the disc,
  the decoder reported "packets that switch nothing on", nothing was
  decoded, and the physical output was 32-bit.
- **Rendered checksum:** `AudioCheck --observe` now prints the checksum of
  its final playback run with the exact frame range. A capture of the same
  sectors, checksummed independently, matched it (`484330ae62efc292`). An
  effectual disc is checked the same way, decoding the capture with FFmpeg
  or `HDCDCheck` first.
- **Detection after a reset:** `HDCDCheck --seek-gaps` reset the decoder
  every 0.37 s across full-track captures. The next packet came within
  1.7–102 ms (median 52 ms, 95th percentile 97 ms) of every one of 2,306
  reset points, except the start of track 1, which has 1.06 s of audio
  before its first packet. No pre-roll is needed on this evidence.
- **Startup delay:** first audio arrived 780–900 ms after Play at the start,
  and 780–796 ms after a seek, track boundary or resume, with decoding on
  or off. The detection hold is hidden inside the 2-second prefill. A cold
  drive's spin-up made one start take 3.6 s.
- **CPU and memory, Release:**

  | Measurement | 2026-10-31 | M8.3 |
  |---|---|---|
  | Engine alone (`AudioCheck --observe`) | 1.2% | 1.3% |
  | Whole player, meters hidden | 1.7% | 2.1% after the fix below (6.7% before) |
  | Engine footprint | 10–11 MB | 17 MB |
  | Whole player footprint | 28 MB | 41 MB |

  - The first app run used 7.1% CPU. M8.2 assigned three `@Published` HDCD
    values on every 100 ms poll, so SwiftUI rebuilt the window and the menus
    about 30 times a second. They are now assigned only when they change, a
    test covers it, and the player is back within one percentage point.
  - The engine's extra 6 MB is the planned 32-bit ring (10.6 MB instead of
    5.3 MB) and the 2-second HDCD start-up buffers. The earlier whole-player
    figure came from a test harness, before the level meters existed.
- **Listening:** the owner played the disc in the Release app. The source
  text read "44.1 kHz · HDCD source" with the "no decodable features"
  tooltip. Turning Decode HDCD off and on, skipping tracks and 10-second
  skips caused no level jumps, clicks or dropouts.
- **Still open on that disc:** its packets switch nothing on, so it could not
  test live decoding. The owner's second HDCD disc also switches nothing on
  (see [Disc analysis](#disc-analysis)); the test disc below covers decoding.

**Test disc, done on 2026-11-03.** With neither disc able to test decoding,
the owner approved burning one. A CD-RW (the plan assumed a CD-R) holds
seven gapless tracks of FFmpeg's FATE sample `hdcd-mix.flac` (9 s;
"peak_extend: enabled intermittently, max_gain_adj: -7.0 dB"), written
bit-exact from the sample. The sample's licence was not verified, so the disc
is for private testing only, and neither it nor any capture is committed.
Track 5 is 3 s of digital silence followed by the sample, so its first
effect (4.456 s in) comes after the 2-second hold. Every engine run sent
zero-valued samples to the Walkman (silent), with the output rate and drive
speed restored and no volume or mute change. The
[transcript](validation/hdcd-m8-3-test-disc-2026-11-03.log) keeps the text
output only.

- **The disc:** `drutil burn -audio -pregap 0 -speed 4`, 66 s in all. The
  read-back equals the source stream delayed by exactly 667 frames (the
  read offset usually quoted for Pioneer drives), with 0 C2-flagged sectors
  in all seven captures. FFmpeg reports HDCD with intermittent Peak Extend
  and a −7.0 dB maximum gain adjustment on every track, and `HDCDCheck`
  matches FFmpeg byte for byte. Decoding changes 31,147 of 793,800 samples
  (3.9%) per 9 s, and the rest decode to exactly the no-effect level.
- **Bit-perfect plumbing:** the silent pipeline check with `--hdcd-off`
  passed all six segments, each reporting packets with Peak Extend or a gain
  adjustment, not decoded, and a 32-bit output.
- **Decoded output equals an independent decode.** Three
  `AudioCheck --observe` windows on the default single-pass policy or with
  `--retry` each printed a rendered checksum equal to the reference computed
  offline from the FFmpeg decode of the capture:
  - Disc start to 9 s (`--retry`): `08378f171a72e72e`, equal to decoded
    track 1 plus the first 1,436 frames of decoded track 2 (the decoder
    resets at the track boundary). Undecoded playback gives
    `cd384eba3afee62e`.
  - Track 5 to the end of the disc: `7a43ff1d860f5392`. This equals
    track 5 undecoded, then tracks 6 and 7 decoded. Decoding everything
    (`367dae1579c30992`) or nothing (`cde0d26017b6227a`) differs. The effect
    in track 5 appears after the 2-second hold, so the engine plays it
    undecoded and starts decoding at track 6, as the rule for a late
    discovery says.
  - A seek to 2.0 s into track 3 (20–26 s): `9281f049b96aaa49`, equal to a
    fresh decode of that slice, and to continuing the whole-track decode.
    Undecoded gives `9d5aefaba708f766`.
- **One concealment episode.** The first window, on the default policy,
  concealed 22 sectors (CD LBA 2180–2201). They were read ahead, about 2 s
  into track 4 and 23 s ahead of the play position, so the window's own audio
  was unaffected, but the tool prints no checksum for a run with any
  concealed sector, so the window was repeated with `--retry`, which flagged
  nothing. The same sectors were not flagged in the capture of track 4, and
  no other run that evening logged a concealment. The cause is unknown (a
  marginal spot on the CD-RW or a transient read condition); it is not
  related to decoding.
- **What the sample exercises.** Gain adjustment heavily. Peak Extend is
  flagged in its packets but barely changes anything: 7 of the 9,115 samples
  at or above its threshold (|x| ≥ 0x5981) changed, each by under 1%, and
  no decoded sample exceeded the 16-bit range. The changed values are libhdcd's
  full-precision gain results (31,140 of 31,147 have bits set below 2^11, so
  they are not on a 20-bit grid; the feasibility check had said they were).
  The render callback converts the 32-bit ring to Float32, which holds 24
  significant bits, so a result with finer detail is rounded there, far below
  one 20-bit step. `--observe` checksums the ring's integers, not the Float32
  output.
- **Listening, status text and the ordinary-CD control (2026-11-03;
  owner-reported unless stated).** On the test disc, in the Release app on
  the Walkman at the minimum volume, the status line read `CD DETECTED`,
  then `HDCD PLAYING`. The source text read `44.1 kHz / 20-bit HDCD`, and
  `44.1 kHz / 16-bit HDCD` with Decode HDCD off. The decoded audio was
  clearly quieter than the undecoded, and the sound was clean. The listening
  also found that the depth text changed seconds before the level did on a
  run from track 5; that was fixed (see the
  [M8.4 follow-up](#m84-follow-up--the-depth-follows-the-playing-position-implemented))
  and checked again on the disc. With an ordinary commercial CD in the same
  app, the status line read `CD DETECTED` and `CD PLAYING` with `44.1 kHz /
  16-bit source`, and no HDCD or 20-bit text was left over from the test
  disc. `AudioCheck --activate-silent` on that CD (a tool result, not
  owner-reported) passed all six segments: no HDCD packets, nothing decoded,
  and each rendered checksum equal to independent undecoded reads. The
  [development log](DEVELOPMENT_LOG.md#m83-listening-check-and-the-depth-display-fix-2026-11-03)
  has the details, and the
  [transcript](validation/hdcd-m8-3-test-disc-2026-11-03.log) the logs.
- **A click at some track starts.** The owner heard a click at the start of
  track 3 of the test disc (and, in the first listening, of track 5), but
  none at the start of track 1, nor at track 2 of the ordinary CD. It fits
  the drive's read offset, which the app does not correct (left out in M4):
  a run that starts at the beginning of a track begins with the last 667
  frames (15 ms) of the track before it, and on this disc those end abruptly
  at a high level. Continuous play across a boundary is unaffected. On the
  ordinary CD the same 15 ms, measured later with a read-only capture, peak
  at 10.8% of full scale and run straight into the music, which is why its
  track 2 had none. Nothing was changed for it.
- **Ejects during the re-test.** The disc left the drive twice during the
  re-test. The system log ties both ejects, like the owner's final one, to a
  button click in CD Player 26 to 70 ms earlier, with the app's own unmount
  and eject options; the second came from two quick clicks on the shared
  Stop/Eject button.
- **Screen texts on track 5 runs (screenshots).** During the start-up hold
  the status line reads `PREPARING`, then `BUFFERING`, with the previous
  run's source text. On a fresh disc the first audio reads `CD PLAYING`,
  `16-bit source` until the read-ahead producer finds track 5's first
  effect, then `HDCD PLAYING`, `16-bit HDCD`; after an earlier decoded run
  it reads `16-bit HDCD` from the first audio. Both read `20-bit HDCD` only
  from track 6.
- **Synthetic offline and live CD-RW validation (2026-11-03).** The focused
  playback test feeds a five-second, phase-aligned 110 Hz signal near full
  scale with Peak Extend packets every 71 frames. It asserts effectual
  detection, decoded state, a restored peak above 90% FS and no clipping.
  `Tools/check-hdcd-peak-extend.sh` generates a 10-second stereo WAV, decodes
  it with both `HDCDCheck` and FFmpeg, compares the Int32 output byte for byte,
  and verifies that Peak Extend restores a peak above the undecoded
  16-to-32-bit level without clipping. The decoded peak is 92.9% FS versus
  50.0% FS without Peak Extend. The normal, AddressSanitizer and
  ThreadSanitizer package test runs all exited successfully. This closes the
  offline DSP validation gap. The owner then burned the generated WAV to a
  CD-RW. A read-only capture had zero C2-flagged sectors and matched the
  source exactly after the measured 667-frame read offset. On the Walkman
  NW-A306, a silent 9-second `AudioCheck --observe` detected effectual HDCD,
  decoded on the 32-bit output, and rendered checksum
  `f6619b6109a04ec9`; that checksum matched an independent decode of the live
  capture over the same 397,824 frames. There were no underruns or concealed
  sectors, and the original output rate and drive speed were restored.
  The ordinary full-disc check requires 30 seconds and two tracks, so the
  10-second single-track disc was tested with `--observe` instead. In a
  separately approved app check, the owner played the disc through the Walkman
  and reported the tone audible. The app showed `44.1 kHz / 20-bit HDCD` and
  `HDCD PAUSED` after 3.53 s, with no underruns or concealed sectors.
  **Still follow-up:** verify real-program HDCD whose musical peaks are lifted
  by Peak Extend; synthetic CD-RW evidence is not a substitute for that
  listening check.

  The [text transcript](validation/hdcd-peak-extend-cdrw-2026-11-03.log)
  records the live output. The temporary capture was deleted after analysis.

### M8.4 — HDCD on the status line (implemented)

Requested by the owner after M8.3 (2026-11-03):

- The status line names an HDCD disc: `HDCD DETECTED`, `HDCD PLAYING`,
  `HDCD PAUSED` and `HDCD END`, with matching VoiceOver labels.
- The source text names the depth played instead of "HDCD source" or "HDCD
  decoded": `44.1 kHz / 16-bit HDCD` or `44.1 kHz / 20-bit HDCD`.
- HDCD found on a disc stays found until the disc is ejected or changed,
  and a run still detecting keeps the previous run's depth; see
  [What the display shows](#what-the-display-shows).
- Display only: the engine, the decoding rule and the audio are unchanged.
- Tests: the full status-line lifecycle (a new disc is a CD; HDCD found while
  playing; paused; a later run that detects or finds no packets near its
  start; Stop; end of disc; a replaced disc), the held 20-bit depth while a
  new run detects, 16-bit at once with the setting off, and the demo disc.

### M8.4 follow-up — the depth follows the playing position (implemented)

Found in the M8.3 listening check (2026-11-03). Starting at track 5 of the
test disc, which plays undecoded until its late discovery makes track 6
decode, the owner saw `20-bit HDCD` within seconds of Play (about 2 s,
by the owner's reckoning), while the level dropped only at the track 6
boundary, 12 s in.

- **Cause.** The engine's snapshot reported the producer's state. The
  producer reads several times faster than real time into a 30-second
  ring, so it crossed the track 6 boundary and switched to decoding seconds
  after Play, long before that audio played.
- **Fix.** The engine records the first disc frame it writes decoded
  (`hdcdDecodeFrame`): the run's start frame when decoding is decided at
  start-up or carried over from an earlier run on the same disc session, or
  the first frame of the track where a later switch happens. The snapshot
  reports decoded only once the playing position has reached it, so the text
  changes with the audio, to within one output buffer. The render callback,
  the decoding rule and the audio are unchanged. The `AudioCheck` line
  `decoded:` follows the same rule, so a window that stops before the switch
  no longer reports decoded audio it did not play.
- **Test.** A source whose producer is already past a late-effectual track
  boundary while nothing has played: not decoded at frame 0 and one frame
  before the boundary; decoded at the boundary, where the rendered scale
  changes too; then a restart from frame 0 decodes from its first frame.
  Before the fix the first two checks failed, and removing the reset in
  `cd_playback_prepare` fails the last.
- **Checked on the disc (2026-11-03, owner-reported).** In a rebuilt Release
  app, asked when the source text first read 20-bit HDCD on a run from
  track 5, the owner chose "At the level drop when track 6 starts (the fix
  works)". Screenshots of two later runs from track 5 show a 16-bit source
  text until track 6 and the previous run's text during the start-up hold
  (see the M8.3 notes above).

### Possible later work (not planned)

- A pre-roll after seeks, if M8.3 finds the gap audible.
- Remembering HDCD discs between launches, which would store disc IDs.
- Dither for 16-bit outputs.

## Decisions

Approved by the owner on 2026-11-03:

1. **Scope:** decode in the app (option 1), starting with detection
   (M8.1).
2. **Default:** "Decode HDCD" on. Only discs whose HDCD packets switch Peak
   Extend or a gain adjustment on are decoded; every other disc, including
   HDCD discs that use neither, stays bit-perfect.
3. **Level:** no make-up gain; decoded discs play about 6 dB quieter.
4. **Display:** plain text; no logo. The US trademark registration was
   cancelled in 2021; other countries were not checked. As first approved,
   the source text showed "HDCD decoded" or "HDCD source" and the status line
   did not change. Revised by the owner after M8.3 (M8.4): the status line
   reads `HDCD …` once HDCD is found, and the source text shows
   `16-bit HDCD` or `20-bit HDCD`, the depth played.
5. **Outputs:** decode only when the output's physical format carries at
   least 20 bits; on 16-bit formats, play undecoded without dither.
6. **Decoder:** vendor libhdcd at a pinned commit with its BSD notices, and
   credit its authors in the README. This is the one approved exception to
   the project's "no third-party dependencies" rule: source files copied
   into the package, with no package manager and nothing fetched at build
   time.
7. **Order:** M8 comes before M7. M6 is already complete.
8. **Test discs:** the owner has two HDCD discs, and neither switches
   anything on. Before any decoding code, a read-only developer capture
   characterised the first with FFmpeg's `hdcd` filter, and the second was
   analysed the same way later (see [Disc analysis](#disc-analysis)). So
   that M8.3 could test decoding, the owner approved burning a CD-RW from
   FFmpeg's HDCD test sample, for private use and never committed; it
   exercises gain adjustment and, barely, Peak Extend. M8.3 still wants a
   disc where Peak Extend lifts real peaks. The ordinary-CD control and the
   owner's listening check on the test disc are done.

## Out of scope

- The Transient Filter flag; no software decoder applies it.
- HDCD encoding, and decoding to files.
- Make-up gain, ReplayGain, dither or resampling.
- Reading audio before Play to detect HDCD; the app reads audio sectors
  only after Play.
- Bundling FFmpeg.

## Sources

Accessed 2026-11-01 unless stated.

- FFmpeg, `libavfilter/af_hdcd.c`:
  https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/af_hdcd.c
- FFmpeg filter documentation, `hdcd`:
  https://ffmpeg.org/ffmpeg-filters.html#hdcd
- FFmpeg test suite, `tests/fate/filter-audio.mak` (test
  `fate-filter-hdcd-mix`):
  https://github.com/FFmpeg/FFmpeg/blob/master/tests/fate/filter-audio.mak
- FFmpeg test samples:
  - https://fate-suite.ffmpeg.org/filter/hdcd-mix.flac
  - https://fate-suite.ffmpeg.org/filter/hdcd-false-positive.flac
- libhdcd (code, `LICENSE` and `AUTHORS`): https://github.com/bp0/libhdcd
- Wikipedia, "High Definition Compatible Digital":
  https://en.wikipedia.org/wiki/High_Definition_Compatible_Digital
- Google Patents (Pacific Microsonics, all listed as expired):
  - US5479168A: https://patents.google.com/patent/US5479168A/en
  - US5638074A: https://patents.google.com/patent/US5638074A/en
  - US5640161A: https://patents.google.com/patent/US5640161A/en
  - US5808574A: https://patents.google.com/patent/US5808574A/en
  - US5872531A: https://patents.google.com/patent/US5872531A/en
- USPTO TSDR, "HDCD", serial 75622394, registration 2378793:
  https://tsdr.uspto.gov/statusview/sn75622394
- Forum analyses of HDCD feature use (approximate):
  - Audio Science Review, "HDCD in Practice":
    https://www.audiosciencereview.com/forum/index.php?threads/hdcd-in-practice.12760/
  - Hydrogenaudio, topic 70757:
    https://hydrogenaudio.org/index.php/topic,70757.0.html
  - Hydrogenaudio wiki, "List of HDCD-encoded Compact Discs" (blocked to
    automated access, not read):
    https://wiki.hydrogenaud.io/index.php?title=List_of_HDCD-encoded_Compact_Discs
- HDCD on a Mac (forum reports):
  - Steve Hoffman Music Forums, "HDCD decoding on Mac OS X":
    https://forums.stevehoffman.tv/threads/hdcd-decoding-on-mac-os-x.1160919/
  - Audiophile Style, "Ripping HDCD on a Mac":
    https://audiophilestyle.com/forums/topic/38017-ripping-hdcd-on-a-mac/
- Current HDCD hardware (forum reports, unverified): Audio Science Review,
  "HDCD DACs":
  https://www.audiosciencereview.com/forum/index.php?threads/hdcd-dacs.41139/
- Pioneer Elite N-50 specifications, Sound & Vision:
  https://www.soundandvision.com/content/pioneer-elite-n-50-network-audio-player-specs
- Output formats of the PRO X and N-50: the live checks in the
  [audio output selection roadmap](AUDIO_OUTPUT_ROADMAP.md).
