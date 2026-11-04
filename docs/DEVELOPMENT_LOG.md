# Behaviour specification and development log

This was the project README during development of version 1.0.0
(milestones M1–M5.8). It is kept unchanged except for this note and its
relative links. It is the detailed specification of every behaviour that was
agreed, with the offline and live verification evidence for each milestone. Dates
and results describe the original development Mac: a MacBook Pro with a
Pioneer BDR-XS07U USB drive, on which macOS did not mount the audio discs.

Before publication, device serial numbers, hardware addresses, device UIDs and
the names of computers and network devices were replaced with descriptions or
`<redacted>`, here and in [validation](validation/). Commit hashes cited in
this log and the validation logs refer to the private history before the first
public commit; they do not exist in the public repository.

For a shorter overview, see the [README](../README.md),
[architecture](ARCHITECTURE.md) and [development guide](DEVELOPMENT.md). When
behaviour changes, update the relevant section here as well as the shorter
documents.

---

A minimal native SwiftUI CD player. **M3 detects physical optical
drives/discs, displays CD track metadata, and ejects discs. M4.1–M4.8 connect
all transport controls to selected-CD reading, buffered playback, best-effort speed
control, conservative read recovery, and playback status/quality display,
verified offline.** M4.8 and M4.9 are accepted offline; M4.10 live verification
is complete. The optical, silent-pipeline, audible playback, and eject/quit
checks passed, as did final offline acceptance. The drive did not confirm the
requested minimum speed; speed selection remains best-effort.
Version 1.0.0 has completed M1–M5 acceptance for this Mac; see
[final acceptance](#m58-final-acceptance-2026-10-31) and the
[milestone history](#next-milestones). The app keeps the Mac awake while a CD
plays and pauses it before the Mac sleeps ([Sleep and wake](#sleep-and-wake)).
The app opens in optical-drive mode and never starts audio automatically. The
M1/M2 simulated disc remains available in the File menu.

## Run

Requires macOS 14 or newer, Xcode with the macOS SDK, and XcodeGen.

```sh
xcodegen generate
xcodebuild -project CDPlayer.xcodeproj -scheme CDPlayer \
  -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/CDPlayer.app
```

Alternatively, open the generated project in Xcode and run the CDPlayer scheme.
XcodeGen is installed with `brew install xcodegen` if necessary. There are no
third-party runtime or Swift package dependencies.

To build the local Release package, run `./Tools/package-release.sh`. It
generates the Xcode project, builds the universal app with the hardened runtime,
verifies its ad-hoc signature and version, and creates
`build/packages/CDPlayer-1.0.0-macOS.zip`. This package is for this Mac only:
it is not notarized and will not pass Gatekeeper on another Mac.

## M1: interface and simulated disc

The window contains exactly four transport buttons, in this order:

1. Previous track. After more than 3 seconds, restart the current track instead.
   Before Play, after Stop or after the disc ends, Previous on the first track
   returns to the disc total (track count and total time). Hold to go back
   10 seconds.
2. Play / Pause.
3. Next track. From the disc total, Next selects track 1 (`TRK 01`, `00:00`),
   so the totals act as the position before the first track. Next never ends
   the disc: on the last track it stays at that track's start (`00:00`, still
   `CD DETECTED`) before Play or after Stop, keeps the current position while
   paused (Play continues from there), and does nothing while playing. Hold to
   go forward 10 seconds.
4. Eject the selected source: the physical CD in optical-drive mode, or the
   simulated disc in demo mode. While playing or paused, this button becomes
   **Stop**; pressing it stops playback without ejecting, resets the display to
   the total track count and duration, and restores the Eject button.

A click shorter than half a second changes track. Holding Previous or Next for
half a second switches its symbol to back/forward and skips 10 seconds, then
again every quarter second until release; releasing after a hold does not also
change track. Forward skips stop at the last 10-second step that still lies
inside the disc, so only playing through the last track ends the disc.
VoiceOver offers the 10-second skips as actions on these two
buttons, and the Playback menu keeps Back/Forward 10 Seconds.

The selected optical drive's name appears inside the display above the status
line, using the same 10-point monospaced font. With more than one optical drive
attached, a small drive icon to the left of the name switches drives; a lone
drive shows it only to rescan after a drive, disc or eject error (see M3).
All four transport buttons sit
inside the display directly below the track/time row. They share the available
width equally, with 26-point height, slim outlines, and function symbols.
There is no separate control area or text
footer beneath the display. An error replaces the status in red with a short
message such as `[ERR] Drive error`, never overlapping the media information on
the right; the technical detail goes only to the system log.

A small headphones icon (a waveform for the built-in speakers) sits at the far
right of the status line. It is lit while the output runs at the CD's own
44.1 kHz and dimmed otherwise; clicking it switches the output between 44.1 kHz
and its usual rate (see [Output-rate switch](#output-rate-switch)).

The display fills the window, with a thin white outline and no visible title
bar or traffic-light controls. Drag any part of the display other than a button
to move the window; this works on the first click even while another app is
active.
A small neon-red power icon in the top-right corner quits normally, allowing
audio cleanup and output restoration to finish. Command-Q and the application
menu remain available. A native borderless window hosts the SwiftUI display
without reserving hidden title-bar space, while retaining keyboard focus and
macOS 14 support.

After insertion, the display shows the total track count and combined playing
time (`TRK 03`, `01:30` for the demo). Starting playback or selecting/seeking a
track switches it to the current track number and elapsed track time. Pausing
keeps that track/time display. Stop, reloading the disc, or Previous on the
first track before Play restores the totals. When the disc plays through to its
end, the display also returns to the totals, with `CD END` (`DEMO END` in demo
mode) in the status until the next action. The disc is released as after Stop,
and Play starts again from track 1.
Three 30-second PCM tracks contain quiet 220, 330, and 440 Hz test tones. The low
amplitude is part of the source data, not playback gain. They transition without resetting
the audio device. Use **File > Insert Demo Disc** (Command-O) to enter demo
mode or reload after simulated ejection. Space toggles demo playback;
in optical-drive mode it toggles physical Play/Pause.
Command-Left/Right changes tracks; Option-Left/Right seeks; Command-E stops
playback, or ejects the selected source when stopped.

The earlier, separate [disc probe](../Tools/cdprobe/cdprobe.c) is unchanged.

## M2: audio path

- Select a built-in audio output: the current system output (the device the
  volume keys control) when it is built in, otherwise wired headphones before
  speakers. Never silently route to Bluetooth, HDMI, a dock, or a virtual
  meeting-audio device.
- Share that output rather than taking Core Audio hog (exclusive) mode, so the
  volume keys keep working during playback. Refuse playback only while another
  app holds exclusive use of it (see "Shared output and system volume" below).
- Request 44,100 Hz and verify both physical and virtual stream rates.
- A 30-second preallocated single-producer/single-consumer PCM buffer
  (1,323,000 stereo Int16 frames; about 5.3 MB) separates the worker thread
  from the C HAL callback. The producer fills it asynchronously; startup
  renders silence until two seconds (88,200 frames), or all remaining audio
  on a shorter tail, is buffered and the start request is still current.
  The ring became 32-bit in M8.1 and 15 seconds in the playback memory
  change; see [Playback memory](#playback-memory-2026-11-04).
- Demo tones and session-backed disc PCM share this producer. The disc source
  is connected to physical Play from M4.7 and tested with fake drives and the
  real worker/producer offline. Discovery alone never opens or reads a CD.
- Immediately before the first disc PCM read, save the original reported
  drive speed, request the SDK minimum (176 kB/s), and read it back. A drive
  can ignore that request. Restore and verify the saved setting before
  closing the session, not on Pause; all speed calls stay on the disc queue.
- Disc reads provisionally use steady refill pacing: fill towards 30 s,
  then replenish after 4,096 frames have been consumed. An internal burst
  policy instead refills at a 10 s low watermark. Neither adds a fixed delay
  during refill or recovery; the existing 2 s gate still starts playback
  before the whole ring fills. See M4.5 below for the comparison and limits.
- Blocking Core Audio setup, status checks, worker joins and handle destruction
  run on a dedicated serial queue, not the main or Swift cooperative threads.
  Releasing an engine hands its last driver reference to that queue, so
  destruction never falls back to the releasing thread.
- Convert signed 16-bit stereo PCM to Float32 using the exact factor 2^-15.
  The clean-PCM path applies no EQ, gain, dither, or sample-rate conversion.
  M4.6 may interpolate or silence damaged source samples before buffering.
- The callback performs no allocations, locks, logging, Swift calls, or disk IO.
  An underrun silences the missing frames and enters `BUFFERING`, without
  stopping transport. Recovery waits for the same two-second threshold (or
  the remaining EOF tail), then resumes automatically without losing source
  frames. Time does not advance through startup/recovery silence. End-of-disc
  silence is not counted as an underrun.
- The 100 ms status poll monitors read progress using monotonic time, outside
  the callback. Ten seconds without progress while waiting for PCM latches
  an error and atomically mutes/stops production. Successful PCM writes reset
  the wait deadline; muted playback, an already sufficient buffer and normal
  EOF do not time out. The short error is shown before cleanup waits for any
  blocked drive read; that wait stays off the main/cooperative threads.
- Display time follows frames submitted by the callback, not source read-ahead.
  It is not a measurement of acoustic latency.
- Pause, eject, end-of-disc, normal window close, and quit stop the producer,
  detach the callback, restore any rate Play changed, and release the output.
  Stop first closes an atomic output gate, so the next callback is silent
  without waiting for a blocked worker. Already submitted hardware samples
  cannot be retracted. Cancelled or superseded starts cannot reopen that gate.
  Immediate track changes retain the audio session. Coalesced physical-CD
  seeks mute/stop it, join the old producer, and restart at the final target
  after 300 ms without input; the disc session and speed setting are retained.
  External configuration changes are checked before resuming the callback.
- **The app never changes system volume or mute.** The volume keys and
  menu-bar slider control the CD level during playback. Listen at a safe level.

### What "bit-perfect" does and does not mean here

The app's Int16-to-Float32 mapping preserves every source value exactly;
44.1 kHz is not resampled by the app. The tests verify all 65,536 signed
16-bit values through both conversion and the callback's buffer renderer.
This does **not** prove bit-identical output at the analog DAC: macOS volume,
driver/hardware processing, and the analog stage remain outside that guarantee.
Built-in speakers use Apple DSP. Use wired headphones or a wired amplifier
connected to the headphone jack for the intended built-in DAC path.

Damage concealment is not bit-perfect reconstruction. C2 flags, matching
cached reads and a stream-accurate capability bit cannot prove accurate
extraction; see the M4.6 cache and alignment limits below.

The app does not change the sample rate on an ordinary launch. If a previous
run ended before cleanup, it restores a recorded rate when the output is
available and still at the rate the app applied. If the output is unplugged,
the record stays pending and is retried when the device returns. A rate changed
since by the user or another app is never overwritten.

### Output-rate switch

The icon at the far right of the status line shows and sets the sample rate of
the built-in output that Play uses: headphones, or a waveform for the built-in
speakers. Hover over it for the device name and its current rate.

- **Lit:** the output runs at 44.1 kHz, the CD's own rate. **Dimmed:** it runs
  at another rate, usually the macOS default of 48 kHz.
- Click the dimmed icon to set 44.1 kHz now. Play then finds the output already
  at the CD's rate, and Pause, Stop and the end of the disc leave it there.
- Click the lit icon to restore the rate it replaced. If no earlier rate is
  known, it restores 48 kHz. After an interrupted run, a saved original rate is
  restored automatically at launch or when its output reconnects.
- Left dimmed, nothing changes: Play still sets 44.1 kHz, and Pause, Stop, the
  end of the disc and quit restore the earlier rate.
- Quit restores a rate the switch set, as it does after playback.
- The icon is lit during playback, which always runs at 44.1 kHz, and cannot be
  clicked until playback pauses or stops. It also cannot be clicked while
  another app has exclusive use of the output, or if the output does not
  support 44.1 kHz.
- It follows changes made elsewhere, such as in Audio MIDI Setup or another
  app, or by plugging in or removing headphones.
- If the change fails, the status shows `[ERR] Audio error`. The disc and
  position are kept, and the next action clears the error.

### Shared output and system volume

Earlier builds took Core Audio hog (exclusive) mode on Play. macOS then moved
the default output, and with it the volume keys, to another device (for
example from `External Headphones` to `MacBook Pro Speakers`). Core Audio also
rejected volume changes to the hogged output from every other process, so the
CD level stayed locked until Pause or Stop released the device.

Playback now shares the output:

- The volume keys and menu-bar slider change the CD level while it plays.
- The output is chosen when Play is pressed. Pick it in the menu bar or
  System Settings › Sound beforehand.
- The app still sets 44.1 kHz (unless the output-rate switch already has),
  verifies the stream format, and restores the original rate on Pause, Stop,
  end of disc and quit.
- Playback pauses at the current frame and shows `CD PAUSED` if the active
  output changes or disappears, including headphone plug/unplug. Press Play to
  continue on the current system output. Other audio failures still show
  `[ERR] Audio error`.
- If an output is disconnected before its rate can be restored, the saved
  original rate is retried when that device reconnects. A newer rate chosen by
  the user or another app is kept.
- Choosing a non-built-in system output (Bluetooth, HDMI or a dock) keeps the
  CD on its built-in device. The volume keys then control the other device.
- Other apps can play at the same time, and their sound mixes into the CD
  output. With only the CD sounding, the samples sent to the driver are the
  same as in exclusive mode.
- To keep alert sounds off the headphones, set **Play sound effects through**
  to `MacBook Pro Speakers` in System Settings › Sound. Turning off **Play
  feedback when volume is changed** also stops the volume-key click.

### Sleep and wake

- While a CD plays, including `BUFFERING`, the Mac does not go to sleep when
  idle; the display still can. Pause, Stop, the end of the disc, an error and
  quit allow idle sleep again. `pmset -g assertions` lists the hold as
  `PreventUserIdleSystemSleep` named `Playing an audio CD`.
- Closing the lid, Apple menu › Sleep and a low battery still put the Mac to
  sleep. The app first pauses the CD as Pause does, then closes the disc so the
  drive returns to its normal speed. The buttons are disabled meanwhile, and
  sleep waits at most 10 seconds for this.
- After wake the display shows `CD PAUSED` at the same track and time; press
  Play to continue. A CD that was already paused, or a track chosen before
  Play, is kept the same way.
- Once sleep begins, macOS can hold a change to the output until wake, so
  the pause may not finish putting the output's rate or format back. That
  shows no error: the output is marked for recovery, and after wake it is
  restored under the same rules as at launch. The buttons wait for it, and a
  failure then shows the short audio error.
- macOS may reconnect the drive after wake, sometimes more than once. The
  position comes back whenever a drive with the same name shows the same disc
  within 60 seconds of wake. A different disc, or no disc in that time, is
  shown as a newly inserted disc would be.
- A button pressed after wake acts on what the display shows, and the position
  is no longer kept. A sleep during Eject keeps nothing; the eject finishes.

## M3: physical drive and disc status

- Discover CD/DVD/Blu-ray drives through IOKit, including empty drives.
- Register IOKit arrival/removal notifications and Disk Arbitration media/mount
  description notifications. Detection does not depend on a mounted volume.
- Read the full CD track table from the media's **registry metadata**, not raw
  device nodes. Validate declared lengths, binary MSF addresses, session headers,
  unique/sequential track numbers, track extents and lead-outs. Mixed-mode and
  multisession data tracks are never marked as audio; audio durations exclude
  intersession gaps and data tracks.
- Display `NO DRIVE`, `NO DISC`, `READING`, `CD DETECTED`, `DATA DISC` or
  `NOT AUDIO CD`. M4.7 adds `CD PLAYING`, `CD PAUSED`, `CD END` and `BUFFERING`.
  M8.4 shows `HDCD DETECTED`, `HDCD PLAYING`, `HDCD PAUSED` and `HDCD END`
  instead once playback has found HDCD on the disc, until it is ejected or
  changed (see [M8.4](#m84-hdcd-on-the-status-line-2026-11-03)).
  Errors show in red as `[ERR] Drive error` (macOS could not
  report the drive, or list drives at all), `[ERR] Disc error` (unusable disc
  metadata), `[ERR] Eject error` or `[ERR] Audio error`. The technical reason
  is written to the system log (subsystem `io.github.ylau674.CDPlayer`), not
  shown.
  The right side of the status line names the disc: `44.1 kHz / 16-bit source`
  for an audio CD (or the demo disc), `44.1 kHz / 16-bit HDCD` or
  `44.1 kHz / 20-bit HDCD` for an HDCD disc played unchanged or decoded (M8.4),
  `Optical media` for a disc that is still
  being read or is not an audio CD, and nothing when there is no disc to
  describe (an empty or ejected drive, an ejected demo disc, no drive, or a
  drive that cannot report its disc). The output-rate icon follows it whenever
  the built-in output can be read (see [Output-rate switch](#output-rate-switch)).
  Once scanning completes, `TRK` shows the total audio-track count and the
  time field shows their combined duration in minutes:seconds (for example,
  `TRK 10` and `58:59`). Data tracks and intersession gaps are excluded. While
  scanning or with no audio disc, the fields remain `TRK 00` and `00:00`.
- Briefly retry incomplete insertion metadata, then display an explicit error
  rather than remaining in `READING` indefinitely.
- From M4.7, physical **Play, Previous, Next and seek** are enabled for a
  healthy selected audio CD with a whole-disc BSD name. Play opens its
  validated read-only session; insertion, track selection and paused seeking
  never start reads or audio. Eject also works for non-audio media.
  No tones or demo data can accidentally play in physical mode.
- Use **File > Use Optical Drive** (Shift-Command-O) to leave demo mode.
  **Refresh Optical Drives** retries discovery.
- The player uses one selected drive at a time. With several drives attached,
  click the drive icon left of the drive name to cycle through them in
  connection order (drive 1 > 2 > 3 > 1). While choosing, the display names
  that drive and shows `DRIVE n OF m` (in place of any error), `TRK 00` and
  `00:00`; Eject and transport stay disabled. One second after the last click,
  the drive is selected and scanned again; each click restarts that second,
  and cycling back to the current drive refreshes it.
  Unplugging the drive being chosen, leaving one drive without an error,
  switching to demo mode or quitting cancels the choice. With only one drive,
  the icon appears only while the display shows a drive, disc or eject error,
  which a rescan may clear; a click shows `DRIVE 1 OF 1` for one second, then
  scans that drive again. Audio, read and access errors do not show it, because
  the drive is not the problem: press Play to retry from where playback
  stopped. The icon is dimmed and unclickable while a CD plays, buffers or
  has a queued playback seek, or the player is busy (for example, ejecting).
  **File > Select Optical Drive** selects a drive directly; it and
  **Use Optical Drive** are disabled under the same conditions. The model
  enforces this rule for direct calls too. Pause permits changing drives.
  A selection stays stable until that drive is disconnected.
- A drive whose media macOS cannot report stays listed and shows
  `[ERR] Drive error` when selected, so other drives remain usable; only a
  failure to list drives at all affects every drive. A drive without a
  registry ID (normally one being unplugged) is skipped until the next scan.
- Identical drive models are numbered in connection order, for example
  `PIONEER BD-RW BDR-XS07U (1)` and `(2)`; a lone drive keeps its plain name.
  Connection order follows the IOKit registry ID, so a replugged drive moves to
  the end and the numbers can change.
- A normal physical eject first unmounts the whole optical disc without force,
  then asks macOS to eject it. Both phases verify the original registry media
  identity and optical-drive ancestry; a replaced/reused disk identifier is
  rejected. Busy/permission/policy refusals remain visible without alternate
  access methods, forced eject or elevation.

An unmounted CD may still expose its track metadata. **Detection is not proof
that policy permits reading audio.** M3 discovery does not mount a volume,
read audio sectors or set drive speed. From M4.7, explicit Play starts the
read/speed path; neither discovery nor playback modifies removable-media policy.

On a Mac without a mount restriction, macOS mounts an audio CD as a read-only
`Audio CD` volume shortly after insertion. The player works the same either
way:

- Detection, the track table and `CD DETECTED` come from the drive's registry
  metadata, not the volume. The mount only changes the tooltip from
  `Not mounted.` to `Mounted.`; a volume appearing or disappearing never resets
  the display, the position, playback or the open disc.
- Play reads the raw device `/dev/rdiskN` read-only, which macOS allows while
  the volume is mounted; the block device `/dev/diskN` is refused (`EBUSY`)
  while mounted, so it is never used. The volume and its AIFF files are not
  read, and the app never mounts a disc.
- Eject unmounts the volume first, without force. If another app is using it,
  for example Music importing or a Finder preview playing a track, macOS
  refuses, the display shows `[ERR] Eject error` with the reason in the system
  log, and the disc stays in the drive. Close the other app and eject again.
  Ejecting from Finder while the player has the disc open (playing or paused)
  unmounts the volume, but macOS keeps the disc in the drive and reports it
  busy; playback continues.
- Another app reading the same disc competes for the drive (`BUFFERING`,
  slower reads), as two players would. On that Mac, set **System Settings >
  CDs & DVDs > When you insert a music CD** to **Ignore** so that Music does
  not open and read the disc.

The mounted case is covered by unit tests (a mount during playback and pause;
an unmount during Eject while playing) and by a check that a mounted read-only
disk image's raw device still reads while its block device is busy. It has not
yet been played live, because this Mac's policy blocks mounting optical
discs.

## Validate

The default test suite uses no audio hardware and makes no sound:

```sh
swift test --package-path Packages/CDKit
```

Tests create players with `PlayerModel.offline(…)`, so they never list the
Mac's outputs, read the saved output, or restore rates recorded by the
installed app.

Read-only built-in output inspection (does not activate audio):

```sh
swift run --package-path Packages/CDKit AudioCheck
```

List optical-drive metadata without reading audio sectors:

```sh
swift run --package-path Packages/CDKit OpticalCheck
```

Read-only optical-drive metadata and notification check:

```sh
swift run --package-path Packages/CDKit OpticalCheck --watch 10
```

The M4.9 optical read check reads real CD sectors, probes C2, and temporarily
requests the drive's minimum speed before restoring and verifying the original
setting. It does not activate audio or eject the disc:

```sh
swift run --package-path Packages/CDKit OpticalCheck --read-check <drive-id>
```

The separate M4.9 silent pipeline check reads real CD PCM, temporarily uses
the built-in output at 44.1 kHz, and sends only zero-valued samples
to the output (it is not a muted audio stream). It checks real callback PCM
against separate sector reads and verifies output and drive cleanup:

```sh
swift run --package-path Packages/CDKit AudioCheck --disc <drive-id> --activate-silent
```

To compare both supported producer pacing policies through the same silent
pipeline checks:

```sh
swift run --package-path Packages/CDKit AudioCheck --disc <drive-id> --activate-silent --compare-pacing
```

This runs the full check once with steady pacing and once with burst pacing
(about 100 seconds of callback playback total; the disc needs at least 50
seconds). Each pass includes a continuous 25-second start segment so the burst
policy reaches its refill watermark. It reports per-policy read statistics
and underrun/checksum results; it does not measure drive noise. Although the
output samples are zero, the optical drive itself may be audible.

To observe a damaged disc through the same silent pipeline, give a start time
and a length in seconds (1–900):

```sh
swift run --package-path Packages/CDKit AudioCheck --disc <drive-id> --activate-silent --observe <start-seconds> <seconds> [--retry]
```

Instead of failing on damage, it prints each `BUFFERING` episode, concealed
sector counts and the disc position (track and LBA). If any buffering lasts
1.5 seconds, it pauses once and resumes after a second, timing both. It then
reports how long the final stop took, the totals, the raw-read rate and how
many C2-flagged sectors a retry cleared. It uses the app's policy (single
pass: each block read once, like a hardware CD player) and prints it; `--retry`
re-reads flagged blocks when the buffer has time to spare, for comparison.
Damaged PCM is not
compared with reference reads. CDKit logs each raw read that takes
0.5 seconds or more, or fails. Output and drive-speed restoration are checked
as in the other silent checks.

**Both M4.9 commands perform hardware operations and require explicit approval
before running.** The optical check reads disc sectors and requests a drive
speed change; the audio check also activates the Core Audio output. The audio
check refuses to start while the output is already running or exclusively
owned by another app. It does not change system volume or mute. Avoid running
it during calls or other audio work because it temporarily sets the output to
44.1 kHz.

To deliberately eject a disc, pass the **drive registry ID** printed by an
`OpticalCheck` listing:

```sh
swift run --package-path Packages/CDKit OpticalCheck --eject <drive-id> --watch 2
```

The second command physically ejects the selected optical disc; only run it
when that action is intended. It never uses forced eject or bypasses a refusal.

### Local verification

- The M3 baseline of 49 offline tests passed with AddressSanitizer and ThreadSanitizer;
  neither reported an error. Coverage includes exhaustive Int16 conversion,
  interleaved/planar stereo rendering, wraparound/backpressure, 250,000 frames
  under concurrent producer/consumer load, transport states, exact previous-track
  threshold, and stale asynchronous snapshots.
- On the MacBook Pro's built-in speakers, the silent hardware check consumed
  441,344 frames before seeking, exceeding the eight-second prefill. Both
  sessions ran exclusively at 44.1 kHz without underruns and restored the
  original 48 kHz rate and unowned state.
- The Debug app builds, passes signature verification, opens a native window,
  quits normally and relaunches. Launch alone leaves the audio output idle at
  its original rate.
- Automated native button clicking was not run: Accessibility permission was
  unavailable, and no privacy settings were changed. Transport behavior is
  covered by the model tests. A wired-headphone hardware check remains to be
  performed when that output is connected.
- M3's metadata-only live scan found the Pioneer BDR-XS07U and its 10-track
  58:59 audio CD while the disc was **not mounted**. With explicit user approval,
  a single normal physical eject succeeded and the live monitor changed to
  `No disc`. No audio-sector reads, volume mounts or policy changes were made.
  Reinsertion was then confirmed in the running GUI as `CD DETECTED`;
  a separate metadata scan verified a new media identity and the same 10 tracks.
- M3 adds offline coverage for malformed/mixed-mode/multisession track tables,
  drive/disc arrival and removal, source isolation, drive selection, eject
  refusal/recovery, disc replacement during asynchronous cleanup, and stale
  demo snapshots.
- The disc-summary display update passes all 32 focused player/optical tests,
  including totals, scan/removal clearing, track selection, mixed-mode discs,
  intersession gaps, and VoiceOver labels. A metadata-only check of the live
  player model confirmed `CD DETECTED | TRK 10 | 58:59`. The updated Debug app
  passed build/signature checks and was normally quit and reopened with a
  visible window; no playback, eject, or mount was needed for this update.
- The multi-drive selector adds 9 offline tests (61 total, also passing with
  ThreadSanitizer). They cover visibility, wrap-around, no rescans while
  cycling, a single rescan on commit, the real dwell timer, restarting it on
  every click, cancellation (unplug, one drive left, demo, menu, quit),
  disabling while busy, and duplicate-name numbering. A temporary harness
  drove the real display with three simulated drives. Clicks cycled drives
  without moving the window, and the selection committed 1.01 s after the last
  click. The disabled icon rendered at half brightness, the previous drive's
  error was hidden while choosing, and the window stayed 426×164. Only one
  physical drive was available, so a real multi-drive check remains. The
  playing-state rule can only be exercised once M4 adds physical playback.
- Per-drive scan errors and the short error message add 9 offline tests (70
  total, also passing with ThreadSanitizer). They cover a failed drive keeping
  its own error and number, a faulty drive not hiding a working one,
  refreshing by cycling back, the lone-drive icon appearing only with a drive,
  disc or eject error, `DRIVE 1 OF 1` followed by a single rescan, recovery
  during the wait cancelling it, which choices survive unplugging down to one
  drive, and the short message for each error kind (drive, disc, eject,
  audio) while the detail is kept for the log. Temporary harnesses drove the
  real display with simulated drives (33 and 26 checks). Each refresh ran
  about 1.02 s after the click, and the icon disappeared once the drive
  recovered. Every error appeared in red on the status line, at least 137 pt
  clear of the media information, and the window stayed 426×164 throughout,
  including during `DRIVE 1 OF 1`. On real hardware, a read-only scan still
  lists the Pioneer without an error. The live model shows
  `CD DETECTED | TRK 17 | 73:51` for the disc now inserted, with no icon. A
  real drive failure could not be produced, so that path is covered offline
  only.
- M4.1 and M4.2 add 17 offline tests (87 total, passing under both
  AddressSanitizer and ThreadSanitizer). They cover:
  - timeline layouts and frame/sector mapping at track, session and disc
    boundaries, including data tracks and session gaps;
  - the unchanged demo disc;
  - opening whole discs only, and mapping errors to their causes;
  - request validation and splitting C2 reads into audio and flags;
  - every behavior of the fake drive.
- With explicit approval, a temporary read-only check (reproducible later as
  M4.9's `OpticalCheck --read-check`) opened the current CD as the logged-in
  user. It did not mount, eject, change speed or output audio. Results:
  - the disc's own track table matched the registry's;
  - 3 s of audio read back as real music (peak 22,474, RMS −18.2 dBFS) in
    little-endian sample order, and a repeat read was identical;
  - a C2 read returned 294 clean flag bytes with the same audio;
  - the drive reported 24× and was left unchanged.
  Read-only raw access works without mounting the disc.
- Launching with no optical drive was checked on the real display with a
  simulated drive-free Mac. It shows `NO DRIVE` (not an error), with no
  drive name or icon, a blank right side of the status line, all six buttons
  disabled and the usual 426×164 window.
  A drive with a CD plugged in afterwards was picked up automatically
  (`CD DETECTED`, `TRK 10`, `58:59`). Unplugging it returned to `NO DRIVE`,
  and demo mode works without any drive. A real unplug and replug has not
  been tried yet.
- M4.3 adds 13 offline tests (100 total, passing under ThreadSanitizer). They
  cover:
  - opening off the main thread, and only for the selected audio CD;
  - keeping one session while paused, and that closing waits for a read in
    progress;
  - closing before eject, on removal or replacement, on a drive or source
    change, and on quit;
  - `[ERR] Access denied` with exactly one attempt, and `[ERR] Disc error`
    for a different or vanished disc;
  - not keeping a disc that is replaced, or whose app quits, while it is
    being opened.
- On the real drive, registry-only checks refused a stale disc identity and
  the wrong drive before anything was opened. With explicit approval, the
  player then opened the CD read-only through the new session in 0.09 s. The
  device and registry track tables matched (17 tracks, 195,439,440 frames),
  the status stayed `CD DETECTED`, a second open reused the session, and quit
  closed it. No audio was read.
- M4.4's lifecycle foundation (step 1) adds 17 offline regressions. All 117
  tests pass normally, under AddressSanitizer and under ThreadSanitizer; the
  macOS arm64 app build and strict code-signature verification also pass.
  The new checks cover:
  - blocked audio setup and handle construction, cancellation, superseded
    starts, immediate mute before blocked teardown, and serialized restarts;
  - keeping inspection, setup, cleanup and destruction off the main thread;
  - reporting both the original failure and a cleanup failure;
  - the actual C producer and renderer in memory: asynchronous prefill, muted
    output without advancing time, disc-end draining and bit-exact buffer reuse;
  - quit waiting for pending disc opens, reads and removal-triggered closes,
    and eject waiting for earlier cleanup before reaching the fake service;
  - re-checking the selected disc after a pending close, closing a cancelled
    open's late session, and not applying stale success or failure to a
    replacement disc or after quit.
  These checks do not read a real CD, change drive speed, eject a physical
  disc or activate an audio device. The app was built but not relaunched.
- M4.4's shared PCM sources (step 2) add 17 offline regressions. All 134 tests
  pass normally, under AddressSanitizer and under ThreadSanitizer; the macOS
  arm64 app build and strict code-signature verification also pass.
  The new checks cover:
  - exact little-endian stereo samples from fake disc sessions, including
    partial-sector starts, track/session boundaries, skipped data and gaps,
    and the final frame;
  - a then-37-sector maximum per source read, short reads, repeated ring-buffer
    wraps, exact EOF draining and unchanged demo output;
  - malformed sector blocks, invalid stereo/frame counts and premature EOF;
  - preserving read-error categories, system errors and diagnostics, including
    a read failure after playback starts that silences remaining buffered audio;
  - muting during a blocked read, discarding cancelled results, restarting at
    a new frame, and retaining/releasing source storage through safe teardown;
  - rejecting closed sessions and physical timelines passed as demo sources.
  These checks use fake sources and the actual producer/renderer in memory.
  No real drive reads, speed changes, physical ejects, audio-device activation
  or app relaunch were performed. At this step the buffer was still eight
  seconds with full initial prefill; step 3 replaces that policy.
- M4.4's buffering policy (step 3) adds 7 offline regressions. All 141 tests
  pass normally, under AddressSanitizer and under ThreadSanitizer; the macOS
  arm64 app build and strict code-signature verification also pass.
  The new checks cover:
  - exactly 1,323,000 frames of ring capacity and startup at 88,200 frames,
    while 88,199 remains silent without advancing time;
  - an underrun followed by automatic recovery at the same exact threshold,
    preserving every source frame and keeping the transport active;
  - draining a remaining tail shorter than two seconds, with EOF padding
    excluded from the underrun count;
  - a real-time watchdog test: one partial read resets the deadline, then
    ten seconds without progress mutes output despite the still-blocked read;
  - no false timeout while muted, with a sufficient buffer, or when a new
    recovery wait follows a long full-buffer idle;
  - discarding the timed-out read when it eventually returns, retaining the
    failure until restart, and starting again with a clean buffer;
  - `BUFFERING` on the existing status line, working Pause/navigation, and
    immediate error visibility while cleanup is still blocked.
  The callback reads no clocks and waits for nothing; the watchdog runs in
  the existing status poll. The full suite takes about 16.5 s because it
  verifies the real ten-second rule rather than substituting a shorter test
  timeout. All sources are fake/in-memory: no real drive operations, audio
  activation or app relaunch were performed.
- M4.4's broader fault acceptance (step 4) adds 9 regressions and expands the
  watchdog test to cover both startup and recovery after audio has played.
  All 150 tests pass normally, under AddressSanitizer and under
  ThreadSanitizer; the macOS arm64 app build and strict code-signature
  verification also pass. The expanded checks cover:
  - repeated two-second refills with short/bursty reads, 127/512/1,024-frame
    callbacks and non-power-of-two ring wraps, preserving every stereo sample;
  - startup taking at least 12 real seconds while partial reads continue
    making progress, without a false ten-second timeout;
  - planar stereo startup/recovery, short EOF tails and padding, plus an
    unsupported callback layout failing without consuming audio and clearing
    on restart;
  - permission, missing-disc, media-read and other errors after playback
    starts, preserving diagnostics and muting buffered audio without retries;
  - disc removal or session close during read-ahead, and a cancelled read
    failing late while Stop and session close are waiting;
  - the actual audio worker, C producer and player model together through an
    offline driver: Pause, demo Eject and Quit mute blocked reads before and
    after playback starts, and ignore their late failures;
  - a producer failure reaching the short player error status without
    advancing into the remaining read-ahead.
  The existing session-close ordering test now uses an explicit blocked-read
  gate instead of scheduling-dependent sleeps. No production behavior was
  changed in this step. All rendering uses memory buffers; the offline driver
  never acquires an audio device. No real-drive operation, audio activation
  or app relaunch was performed, and physical Play remained disabled at this
  stage, pending M4.7.

### M4.4 final acceptance (2026-10-30)

**Complete: disc-fed producer and buffering foundation.** Step 5 reviewed the
implementation against the acceptance criteria and reran final verification;
no additional production changes were required.

| Acceptance criterion | Verified evidence |
| --- | --- |
| One producer for demo and disc PCM, preserving exact stereo samples and the audio-only timeline | [PCM source tests](../Packages/CDKit/Tests/CDKitTests/PCMSourceTests.swift), including partial sectors, track/session gaps, malformed input and unchanged demo output |
| 30 s ring and 2 s startup/recovery threshold, with short EOF tails draining correctly | [Buffering tests](../Packages/CDKit/Tests/CDKitTests/PlaybackBufferingTests.swift): exactly 1,323,000-frame capacity and 88,200-frame threshold; repeated short reads, ring wraps and both stereo layouts |
| Underruns recover without losing source frames or advancing elapsed time through silence | [Buffering tests](../Packages/CDKit/Tests/CDKitTests/PlaybackBufferingTests.swift) and [player tests](../Packages/CDKit/Tests/CDKitTests/PlayerModelTests.swift) |
| Ten seconds without progress while waiting stops output; ongoing partial progress does not | [Real-time watchdog tests](../Packages/CDKit/Tests/CDKitTests/PlaybackBufferingTests.swift), at startup and after playback, including late-read discard and clean restart |
| Blocking reads/setup/teardown stay off the main/cooperative threads; stop mutes before waiting | [Lifecycle tests](../Packages/CDKit/Tests/CDKitTests/PlaybackLifecycleTests.swift) and [session-close ordering](../Packages/CDKit/Tests/CDKitTests/DiscSessionTests.swift), with blocked reads, cancellation and superseded starts |
| Failures remain explicit, with short UI errors and safe source lifetime | [PCM source tests](../Packages/CDKit/Tests/CDKitTests/PCMSourceTests.swift) and [worker/producer/player acceptance](../Packages/CDKit/Tests/CDKitTests/PlaybackLifecycleTests.swift) |

Final checks: all **150 offline tests** pass normally (16.523 s), under
AddressSanitizer (16.528 s) and ThreadSanitizer (17.307 s), without compiler,
runtime or sanitizer diagnostics. Non-sanitized SwiftPM products were
restored; the Debug macOS arm64 app build and strict local code-signature
verification pass. This is not a release/notarization or real-hardware sign-off.

Remaining limits are intentional:

- The watchdog runs in regularly polled snapshots (100 ms in the player), not
  in the real-time callback. A stalled raw ioctl cannot be safely interrupted;
  output is muted and the error displayed before cleanup waits for it.
- At this M4.4 sign-off the disc adapter requested plain audio and failed
  explicitly on a read error. M4.6 below now adds C2, cache-aware comparisons,
  bounded re-reads and damage concealment.
- At M4.4 sign-off, the session-backed engine was not yet connected to physical
  transport controls; M4.7 below completes that wiring. Remaining playback UI
  and hardware checks follow in M4.8–M4.10. M4 as a whole is not complete.
- No real-disc operation, drive-speed change, physical eject, audio activation
  or app relaunch was performed for this sign-off. Future hardware validation
  remains explicitly approval-gated.

### M4.5 speed control and quiet pacing (2026-10-30)

**Implemented and accepted offline.** The default pacing policy is provisional:
no new real-drive speed or acoustic comparison has been performed.

Speed control belongs to `DiscSession` and runs once, just before its first
PCM producer read. Discovery, session open/TOC validation and direct raw
diagnostic reads still do not change speed. A successful change saves the
original setting; repeated Play/Pause/seek does not request it again.
Explicit session speed changes also preserve the original, not an intermediate
setting. Close waits for reads, requests the saved speed, verifies the reported
value, logs any failure or mismatch, and closes exactly once even after removal.

If the original speed is unknown/zero or cannot be obtained, it is not changed.
Unsupported/rejected optional speed controls log a warning without preventing
reads; access refusal or drive disappearance instead latches the original
error and prevents PCM reads without retrying. Unknown or ignored readback is
logged, never described as verified 1×. A successful setting is still restored
when its readback fails.

Both pacing policies operate only in the C producer, with the same 30 s ring
and 2 s startup/recovery gate (the ring is 15 s since the
[playback memory](#playback-memory-2026-11-04) change, so burst now refills
when 5 s remain):

| Policy | Refill trigger after a full standard ring | Refill behavior |
| --- | --- | --- |
| Steady (provisional default) | 4,096 source frames consumed, about 93 ms of playback | Read towards full again, keeping reads regular rather than deliberately creating long idle gaps |
| Burst (internal comparison) | 10 s remain: 882,000 frames / 20 s consumed | Refill towards 30 s, then idle again |

Pacing follows buffer consumption, not a fixed wall-clock sleep added to every
read. Startup/refill reads remain eager, so a slow drive gets no extra
throttling; playback can start or recover at 2 s without waiting for 30 s.
Short reads, partial sectors, track boundaries and EOF still preserve every
emitted frame. For smaller test rings, the low watermark never falls below
the recovery gate. Demo sources remain unpaced. Idle polling checks Stop
every 5 ms; an already-blocked ioctl still cannot be interrupted safely.

`DiscReadStatistics` measures audio bytes over time inside raw read attempts,
including failed-read time, but excluding queue waits, speed calls, decoding,
producer idle and C2 flag bytes. The handoff from the blocking producer is
explicitly synchronized; close logs an immutable snapshot. Cached/overlapping
reads affect this measurement, so it is **raw-read throughput, not spindle
speed or proof of 1× operation**.

Acceptance evidence:

- [Session tests](../Packages/CDKit/Tests/CDKitTests/DiscSessionTests.swift)
  cover lazy/off-main setup, ignored/unknown reports, optional/fatal failures,
  original/minimum/maximum settings, restoration failure/removal, blocked
  reads and speed setup during Stop/close, and throughput accounting. A
  20-iteration successful/failed cancellation test checks the statistics handoff.
- [Pacing tests](../Packages/CDKit/Tests/CDKitTests/ReadPacingTests.swift)
  compare the exact steady/burst thresholds, short reads across ring wraps,
  callback sizes 127/1,024, EOF/restart, recovery, failed refills and small rings.
  Twelve real seconds of burst-idle playback pass without a false watchdog
  timeout or another source read. These tests run without acquiring a DAC.
- All **171 offline tests** pass normally (16.418 s), under AddressSanitizer
  (16.336 s) and ThreadSanitizer (17.909 s), with no compiler/runtime/sanitizer
  diagnostics. Plain SwiftPM products were restored; the Debug macOS arm64
  app build and strict local code-signature verification pass. The native
  build has only the known nonfatal Xcode host-tool messages.
- Verification caught and fixed the new statistics handoff race. Large
  offline render tests run off the main actor so lifecycle checks keep their
  original deadlines; no deadline was increased to obtain a pass.

The comparison establishes sample correctness, refill cadence and recovery,
**not which mode is acoustically quieter on a physical drive**. Steady is the
conservative starting policy, not a measured acoustic winner. Approval-gated
live checks in M4.10 must compare both on the connected drive before choosing
the quieter underrun-free mode. No drive operation, speed change, eject, audio
activation or app relaunch occurred for M4.5. Physical Play remained disabled
at this stage, pending M4.7; C2/recovery is recorded under M4.6 below.

### M4.6 per-drive read checks and damage recovery (2026-10-30)

**Implemented and accepted offline, with the approved conservative cache
policy.** No new real-drive operation or audio output was performed.

Each opened session snapshots the selected drive's own `CD Features` from
`Device Characteristics`. Stream accuracy uses the public SDK mask `0x10`,
not a Pioneer/model assumption; missing or malformed metadata is conservative.
C2 is negotiated lazily on the first PCM read. Only a failed initial flag
request followed by a successful identical plain read marks C2 unavailable
for that session. Refusal/removal never triggers that fallback. Malformed
audio/flag data and other unrecoverable device failures remain explicit errors.
Discovery and session metadata checks still perform no PCM read or speed change.

The [recovery reader](../Packages/CDKit/Sources/CDKit/DiscReadRecovery.swift):

- Reuses partial sectors without duplicate PCM or damage counts. Payloads are
  capped at 33 sectors, leaving room for overlap/guards inside the 37-sector
  raw-read cap. Reads and displacement stay in audio tracks, never data tracks,
  session gaps or outside the disc.
- Verifies the preceding sector at the exact position on stream-accurate
  drives. Other/unknown drives search up to ±588 stereo frames, requiring at
  least 256 matching unflagged sample values. Ambiguous silent/periodic matches
  are accepted only if every possible alignment emits identical PCM and flags;
  otherwise they are retried or concealed.
- Cannot establish an absolute position at startup or a seek without an
  overlap anchor on a non-stream-accurate drive: that bootstrap remains
  `UNVERIFIED`. Relative overlap alignment is not drive-offset correction.
- Accepts initially C2-clean PCM without changing samples. By default each
  block is read once, like a hardware CD player: flagged samples are
  interpolated, and a block that fails outright or cannot be aligned is split
  into single-sector reads to find the bad sector. The optional `.retry`
  policy re-reads flagged blocks only when the buffer has time to spare, never
  while `BUFFERING` (start, seek, underrun). Matching clean sector pairs are
  preferred during its recovery. Without C2, its optional double-checks
  require measured positive throughput and sufficient buffer headroom; skipped
  checks remain `UNVERIFIED`, including startup, and single-pass PCM without C2
  is always `UNVERIFIED`. Failed attempts alone are not mistaken for a measured
  zero-speed drive that would prevent all recovery.
- Under `.retry`, makes at most three additional retry rounds per
  window/sector (none while `BUFFERING`), sharing a 96-raw-operation cap
  across retries, probes, read-away and sector subdivision. Additional work
  has a two-second recovery window, reduced to buffered headroom above the
  two-second recovery gate outside buffering; sector subdivision has the same
  limits under single pass. The first read and its one C2 negotiation are required
  for ordinary playback. Cancellation and the budget are checked between raw
  calls; an already blocked ioctl cannot be interrupted or given a new hard
  timeout.
- Interpolates only flagged/disputed samples, independently per channel,
  preserving other samples. Sectors without a usable candidate, including
  unresolved alignment or exhausted recovery, become silence. Partial C2
  damage does not erase the whole readable sector merely because only one
  clean retry fits. Newly concealed physical LBAs are logged and counted once
  per producer run, even across partial requests.

**Cache independence is deliberately not claimed.** Under `.retry`, before
comparisons, the reader attempts bounded read-away/re-read (at most 74 other
audio sectors),
excluding the target and its guards. The public macOS raw-CD API supplies no
documented cache-size or cache-bypass guarantee. Matching results can still
come from the same cached corruption, so comparisons that need independence
remain `UNVERIFIED` on the production reader. Independently established cache
bounds exist only in the deterministic fake-source tests; no real bound is
inferred from a model name, reported speed or throughput. There is no SCSI
pass-through, privilege escalation or alternate access route.

The controlled C/Swift source bridge forwards buffer headroom and an atomic,
borrowed cancellation query. It returns concealment deltas and uncertainty;
the producer commits quality only with successful PCM and discards late
cancelled results. `PlaybackSnapshot.concealedSectors` and `.unverified` reset
on a new producer run; C2 capability stays with the open session. Counts
describe produced read-ahead, not necessarily damage already heard.
Closed sessions cannot return cached PCM. Explicit locks synchronize session
state, recovery metadata and statistics across the blocking producer bridge
and actor jobs; no work or locks were added to the HAL callback.

Acceptance evidence:

- [Recovery tests](../Packages/CDKit/Tests/CDKitTests/DiscReadRecoveryTests.swift)
  cover every stream-accuracy/C2 combination, known/unknown/insufficient cache
  displacement, actual fake-cache eviction and repeated cached corruption,
  ±frame shifts, ambiguous overlaps, C2 byte/channel mapping, silent mismatches,
  partial sectors, unreadable neighbours, operation/time/headroom limits,
  closed-cache rejection, quality resets and cancellation during read-away.
- The real offline producer recovers readable neighbours after its very first
  failed read, with no throughput history, and forwards exact concealed PCM
  and quality. Repeated successful/refused speed-setup cancellation and close
  cover the state-handoff race found by TSan. The ring stress test uses truly
  independent reader/writer threads; scripted recovery cases are serial to
  avoid sanitizer allocation contention. No synchronization deadline was raised.
- All **202 offline tests** pass normally (16.319 s), under AddressSanitizer
  (16.400 s) and ThreadSanitizer (18.850 s), with no source/runtime/sanitizer
  diagnostics. Plain SwiftPM products were restored; the Debug macOS arm64 app
  build and strict local signature pass. Only the known nonfatal Xcode
  host-tool messages remain.

At M4.6 sign-off, physical Play remained disabled pending M4.7 below. M4.8 renders
`ERR n`/`UNVERIFIED` without changing the compact layout. Real-drive reading,
speed/acoustic comparison, silent/audible output, eject and app relaunch still
require explicit approval in the later hardware checks. C2 and these offline
tests do not establish secure/bit-perfect extraction from damaged media.

### M4.7 selected-disc player integration (offline acceptance)

All six controls now use the selected audio CD's session-backed playback
engine, not the demo engine. The metadata-derived audio-only timeline retains
physical track numbers and excludes data tracks and intersession gaps.

- **Explicit Play only:** discovery shows totals without opening the disc.
  Play validates/opens the selected session and starts the asynchronous
  producer. Pause stops audio but keeps that session and the requested speed;
  resume starts at the last rendered frame. Read/start failures close the old
  session, and only another explicit Play attempts a fresh open.
- **Navigation:** Previous restarts the current track only after more than
  three seconds; at exactly three seconds it selects the previous audio track.
  Next and rendered EOF stop at the disc end, never wrap. Play from the end
  explicitly restarts at the beginning.
- **Held seeks:** each input updates track/time immediately. Native button
  repeat delay/interval are 250 ms, below the 300 ms quiet period. Only the
  final target restarts the producer, after both the quiet period and the old
  worker's join; a slow join adds no second debounce delay. Inputs remain
  responsive while a raw read is blocked. Pause, track changes, eject,
  media/source changes and quit cancel stale queued restarts. Seeking to the
  end and immediately back cannot leave the old output playing.
- **Lifetime/order:** app eject, external disc removal/replacement, drive
  disconnect, drive/source change and quit mute first, join the producer,
  then restore speed/close the session. App eject waits for close before
  reaching the eject service. A blocked raw ioctl still has to return, but
  waits stay off the main/cooperative threads and late data/errors cannot
  revive the old disc. Changed TOC, BSD identity or discovery failures also
  invalidate playback; ordinary refresh/mount/other-drive changes preserve it.
  A newly selected or replacement disc never autoplays.
- **Selection and errors:** the drive icon, selection menus and direct model
  selection calls are disabled during physical playback, including buffering
  and queued seeks. Basic playback statuses and short access/disc/audio
  errors use the existing status line. Detailed errors remain logged;
  `ERR n`/`UNVERIFIED` rendering and final control/accessibility polish remain
  M4.8 work.

Verification:

| Area | Offline evidence |
|---|---|
| Selected session, exact Previous threshold, mixed-mode navigation, rendered EOF, selector gating, 300 ms seek minimum and stale-result rejection | [Physical transport tests](../Packages/CDKit/Tests/CDKitTests/PhysicalTransportTests.swift) |
| Exact fake-disc PCM through the real worker/producer, track change and Pause/resume; mute-before-join and stop-before-close during blocked reads before/after audio starts | [Playback lifecycle tests](../Packages/CDKit/Tests/CDKitTests/PlaybackLifecycleTests.swift) |
| Eject ordering, removal/replacement/disconnect/source/quit cleanup, cancelled starts and seeks, read refusal/failure and the actual ten-second watchdog | [Playback lifecycle tests](../Packages/CDKit/Tests/CDKitTests/PlaybackLifecycleTests.swift) and [physical transport tests](../Packages/CDKit/Tests/CDKitTests/PhysicalTransportTests.swift) |
| Existing demo transport, metadata-only discovery, no-drive/no-disc displays and session lifecycle | [Player model tests](../Packages/CDKit/Tests/CDKitTests/PlayerModelTests.swift) and [optical player tests](../Packages/CDKit/Tests/CDKitTests/OpticalPlayerTests.swift) |

All **226 offline tests** pass normally (16.469 s), under AddressSanitizer
(16.584 s) and ThreadSanitizer (20.146 s), without source/runtime/sanitizer
diagnostics. Plain SwiftPM products were restored; the Debug macOS arm64 app
build and strict local signature pass. Only the known nonfatal Xcode
CoreDevice/CoreSimulator/AppIntents host-tool messages remain.

No real optical reads, physical speed changes or ejects, audio-device
activation, app launch or relaunch occurred for M4.7. This accepts the wiring
and offline lifecycle, not live-drive sound quality, acoustic quietness or
secure extraction. M4.8 below completes the display/accessibility work offline;
live-drive checks still require fresh explicit approval.

### M4.8 display and quality status (offline acceptance)

**Accepted offline.** The status line reports `BUFFERING`, `CD PLAYING`,
`CD PAUSED` or `CD END`. Short read/access/disc errors are red and keep
technical details in the log. During physical playback, `ERR n` reports
concealed audio sectors and `UNVERIFIED` reports uncertain alignment or
independent read verification; concealed-sector errors are red and an
unverified-only warning is orange. These quality indicators do not appear in
demo playback. VoiceOver receives natural-language status and quality
descriptions. The status remains on one line without overlapping the media
information, and the window geometry is unchanged.

All **229 offline tests** pass normally (16.245 s), under AddressSanitizer
(16.225 s) and ThreadSanitizer (20.088 s). `swift build`, the native macOS
arm64 app build and strict local code-signature verification pass. No physical
disc reads, speed changes or ejects, audio-device activation, app launch or
relaunch were performed; this is not live-drive or audio-quality acceptance.

### M4.9 hardware-check tools (offline acceptance)

**Accepted offline.** `OpticalCheck --read-check` validates drive/media identity
and TOC, reports stream-accurate and C2 capability, requests and reads back
minimum speed when available, compares repeated and overlapping sector reads,
reports byte interpretation and C2 flagged-byte/sector observations, and
measures a bounded five-second sustained-read sample across audio tracks (up to
75,000 sectors). It verifies speed restoration when a change is attempted. Its
C2 fallback retries only the identical sector without C2 after a failed C2
request; refusal and removal are not retried.

`AudioCheck --disc <drive-id> --activate-silent` runs about 30 seconds of real
disc PCM through the producer, buffer and Core Audio callback while the
callback writes zeros to the output. It compares callback and separate-read
checksums at start, seek, track boundary, pause/resume and disc end. The pause
check verifies that the frame and checksum remain fixed for 0.5 s while the
output is idle. Both tools report cleanup and restoration failures explicitly;
the audio check also verifies restoration of the output sample rate, ownership
and idle state.

The FNV-1a PCM checksum is a diagnostic comparison fingerprint, not a
cryptographic hash or proof of secure extraction or bit-perfect playback.
Repeated and separate reads may be affected by drive caching; no independent
cache verification is claimed.

All **235 offline tests** pass normally (16.317 s), with AddressSanitizer
(16.335 s) and ThreadSanitizer (20.259 s). `swift build`, the native macOS
arm64 app build and strict local code-signature verification pass. Xcode emits
the existing nonfatal CoreDevice/CoreSimulator host-tool messages and skips
App Intents metadata because the app has no AppIntents dependency. No physical
disc reads, speed changes or ejects, audio-device activation, app launch or
relaunch were performed. M4.9 is accepted offline only; live-drive and audio
validation still require explicit approval.

### M4.10 live verification (complete; minimum drive speed unconfirmed)

With explicit approval, the first optical read check ran against the
PIONEER BD-RW BDR-XS07U (`disk4`); the disc was not mounted. Drive/media
identity and TOC matched. C2 reads were supported, and no flagged bytes or
sectors were reported. Repeated and overlapping reads matched. The five-second
sustained sample read 1,554 sectors (3,655,008 audio bytes) in 5.026 s,
measuring 727.2 kB/s. The drive reported 4,233 kB/s originally; the minimum
request was 176 kB/s, but readback remained 4,233 kB/s, so no speed reduction
was confirmed. Closing restored and verified the reported 4,233 kB/s setting.
No audio output or eject occurred during this check.

The `--compare-pacing` silent pipeline mode now runs both steady and burst
producer pacing with PCM checksums and underrun checks, and verifies output
restoration after each pass. It does not measure acoustic noise; any comparison
of drive noise is observational. The first approved attempt stopped at the
safety gate because the selected output (`External Headphones`) was running at
48 kHz (hog owner `-1`); that attempt did not activate Core Audio, read audio
sectors, or change drive speed. A later read-only inspection confirmed that
the output was idle, unowned, and supports exclusive 44.1 kHz.

The approved comparison ran with zero-valued output samples. On the first run,
the steady pass completed start/refill, seek, track-boundary, pause/resume, and
end-of-disc checks with zero underruns and concealed sectors. Its raw reads
(including checksum references) totaled 1,777 reads and 43,860,096 bytes in
32.627 s (1,344.3 kB/s). The burst pass passed start/refill, seek,
track-boundary, and pause/resume checks, but its end-of-disc segment reached
frame 195,439,440 with zero underruns and six concealed sectors. The checker
rejected the concealed sectors, so that run exited with failure and did not
verify the end-segment checksum.

One approved repeat passed every segment in both pacing modes, with no
underruns or concealed sectors. The end-of-disc checksum was
`8ae8263122830690` for both modes. Steady raw reads totaled 1,779 reads and
43,876,560 bytes in 33.018 s (1,328.9 kB/s); burst totaled 1,597 reads and
40,061,616 bytes in 28.976 s (1,382.6 kB/s). The six concealed sectors from
the first run did not recur in the repeat. Both runs restored the output to
48 kHz, unowned and idle; closing each session restored and verified the
drive's reported 4,233 kB/s speed. The repeat consumed 98.29 seconds of real
disc PCM with zero-valued output samples. No audible music was sent to the
output, though the optical drive itself may be audible. In a separate app test,
the user confirmed CD audio was audible through `External Headphones` after
unmuting the headphones; a later read-only check reported the output idle.
During the separately approved eject/quit test, the user started playback and
pressed Eject. Playback stopped, the app showed `NO DISC`, and Cmd+Q closed the
app. Follow-up read-only checks confirmed that the Pioneer reported no disc,
the output was idle at 48 kHz and unowned, and the app process had exited.

Final offline verification after the live checks passed: all 235 tests passed
normally (16.227 s), under AddressSanitizer (16.201 s), and under
ThreadSanitizer (20.496 s). `swift build`, the native macOS arm64 app build,
and strict local code-signature verification passed. Xcode reported the
existing nonfatal CoreDevice/CoreSimulator host-tool issues; the app build
succeeded.

## Next milestones

### M4: physical CD playback (complete)

Goal: play the selected audio CD through the existing native 44.1 kHz output
with all six controls, a best-effort slowest drive speed, C2-aware re-reads
(with fallbacks for drives that lack C2 or stream-accurate reads) and a large
buffer. Audio is read only after Play is pressed, by opening the disc's
raw device node read-only as the logged-in user. M4 never mounts the disc, asks
for administrator rights, uses SCSI pass-through, or tries another route after
macOS or managed policy refuses access.

Agreed behavior for hard-to-read discs (known-clean PCM stays bit-exact):

- **Unrecoverable sectors** (flagged, unreadable or misaligned, or unavailable
  within the recovery budget): interpolate only the flagged samples, silence
  sectors that cannot be read, and count both on the display (`ERR n`), like a
  hardware CD player. Each block is read once, without re-reads or read-away
  seeks, so damage neither delays playback nor makes the drive seek; a block
  that fails outright is split into single-sector reads to find the bad sector
  (see [single pass by default](#single-pass-by-default-2026-10-31)).
- **Buffer underrun:** output silence, show `BUFFERING`, and resume
  automatically; stop with an error only if reads make no progress for 10 s.

Subtasks in build order (prerequisites in brackets):

1. **M4.1 Playback timeline from the TOC** [none] — **done**. One track
   timeline (`Disc`) for demo and physical discs: number, first LBA, sector
   count and start frame (588 frames per sector), so Previous/Next/±10
   s/elapsed logic stays shared. Data tracks and intersession gaps are
   skipped; only demo tracks carry a test tone. Mapping tests pass at track,
   session and disc boundaries. The first disc's recorded layout maps to 10
   tracks, 265,467 sectors and 156,094,596 frames (58:59). The 17-track CD now
   in the drive maps to 332,380 sectors and 195,439,440 frames (73:51), both
   from the registry and from its own track table. `OpticalCheck` prints this
   timeline.
2. **M4.2 Raw CD reader** [none] — **done**. A C shim
   ([CDDiscReader.c](../Packages/CDKit/Sources/CDAudioCore/CDDiscReader.c)),
   because Swift cannot import the `DKIOCCD*` ioctls. It provides:
   - read-only open of a whole disc only (`diskN`; paths and slices are
     rejected);
   - `DKIOCCDREAD` of 1–75 2,352-byte CD-DA sectors, with optional C2 flags
     (294 extra bytes);
   - `DKIOCCDREADTOC`, `DKIOCCDGETSPEED`/`DKIOCCDSETSPEED`, and close.

   `RawCDReader` and a fake sector source share the `CDSectorSource`
   interface. The fake scripts delays, errors, C2 flags, silently damaged
   bytes, removal, and drives that reject C2 requests or shift read starts (no
   stream-accurate reads), so every higher layer is testable offline. Errors
   map to policy/permission refusal, disc or drive gone, media read error, or
   other failure.
3. **M4.3 Disc access session** [M4.2] — **done**. Open only on Play for an
   audio CD (`PlayerModel.openDiscSession`, called by Play from M4.7).
   - **Before opening:** re-check in the registry that the BSD name still
     names the same whole CD in the same drive.
   - **After opening:** the device TOC must equal the registry TOC;
     otherwise the disc is closed and `[ERR] Disc error` is shown.
   - **Lifetime:** a `DiscSession` actor runs all drive calls on its own
     serial queue, never the main thread or Swift's shared threads. It is
     kept while paused and closed, after any read in progress, before eject,
     on disc removal or replacement, on a drive or source change, and on
     quit. A disc replaced, or a quit, while opening is closed and not kept.
   - **Refusal:** shows `[ERR] Access denied` and is not retried.
4. **M4.4 Disc-fed producer and buffering** [M4.1, M4.2, M4.3] —
   **done; all five steps accepted offline**.
   - **Lifecycle foundation (step 1, done):** asynchronous production, a
     dedicated audio lifecycle queue and atomic output muting before any worker
     wait. A cancelled or superseded start is cleaned up without enabling
     output. Producer results are checked for cancellation before entering the
     buffer, and the previous worker is joined before the buffer is reused.
     Disc-session opens and closes, including removal-triggered cleanup, are
     tracked; eject and quit wait for them. Late completions cannot revive
     playback or overwrite a replacement disc's state. The callback remains
     free of IO, locks and allocation.
   - **Shared PCM sources (step 2, done):** the same C producer accepts demo
     tones or a session-backed disc source through a blocking, seekable
     44.1 kHz stereo Int16 contract.
     [PCMSource.swift](../Packages/CDKit/Sources/CDKit/PCMSource.swift) maps exact
     timeline frames to little-endian audio sectors, including partial-sector
     starts, while excluding data tracks and session gaps. Each read stays
     within one audio track; M4.6 caps payloads at 33 sectors, with overlap and
     guards inside the 37-sector raw-read cap. Reads serialize with close and
     speed operations on the disc-session queue.
     Specific read errors survive the Swift/C bridge; malformed output and
     premature EOF fail explicitly. Source storage stays alive until the
     producer is joined and the callback detached. M4.6 below now adds C2 checks
     and bounded recovery to this shared source contract.
   - **Buffering (step 3, done):** a 30 s ring (about 5.3 MB), with a 2 s
     startup/recovery gate or the complete remaining EOF tail, whichever is
     smaller. Play does not wait for prefill. An underrun enters `BUFFERING`
     and resumes automatically after refill without advancing time through
     silence. Reads remain capped below about 0.5 s. The existing status poll
     detects 10 s without read progress while waiting, then latches an error
     and atomically mutes/stops production. Progress resets the deadline;
     intentional full-buffer idle and muted playback do not count.
     Errors appear immediately, even while a blocked raw ioctl finishes.
     That read cannot be safely interrupted (this drive lists a 30 s timeout
     and 20 retries), so cleanup still waits off the main/cooperative threads.
     Late results are discarded; restart resets the buffer and timeout state.
   - **Broader fault acceptance (step 4, done):** repeated refill/ring-wrap
     cycles, sustained slow partial progress, planar callbacks, layout faults,
     session read failures/removal/close and late cancelled errors are covered
     offline. The real worker/producer/player path also passes Pause, demo
     Eject and Quit with a blocked read, both before and after audio starts.
     All 150 tests pass normally and under AddressSanitizer and ThreadSanitizer;
     app build/signature checks pass.
   - **Final acceptance (step 5, done):** implementation/coverage reviewed and
     all 150 tests rerun normally and under both sanitizers, followed by a
     plain build, macOS arm64 app build and strict signature verification.
     The acceptance record above documents the remaining limits. Physical
     Play remained disabled at this stage, pending player integration in M4.7.
5. **M4.5 Best-effort slowest speed and quiet pacing** [M4.3, M4.4] —
   **done offline; live acoustic selection pending**. The first PCM read
   saves speed, requests `kCDSpeedMin` (176 kB/s), and reads it back; close
   restores/verifies the saved setting. Optional control failures warn, but
   refusal/removal stops reads without retry. Measured raw-read throughput is
   logged separately from reported settings. Steady and 10 s/30 s burst
   watermarks pass offline comparison; steady is the provisional default.
   The earlier approved probe saw this drive accept the request yet report
   24× and read at about 5–7×, so neither the code nor this sign-off claims
   1× or a quieter acoustic result. See the acceptance record above; approved
   real-drive comparison remains M4.10.
6. **M4.6 Per-drive read checks and recovery** [M4.2, M4.4] —
   **done offline; conservative unknown-cache policy**. Each session snapshots
   its own drive's stream-accurate bit and lazily negotiates C2. Exact overlap
   checks or bounded relative alignment, headroom-aware read-away/comparisons,
   re-reads, sector subdivision and concealment pass the feature/fault tests.
   Unknown cache independence, missing absolute anchors and skipped optional
   verification stay `UNVERIFIED`; matching cached reads are never proof.
   Per-run concealment/uncertainty snapshots are ready for M4.8. All 202 tests,
   both sanitizers, native build and signature pass; see acceptance above.
7. **M4.7 Player model integration** [M4.1, M4.3, M4.4] —
   **done offline**. Play/Pause, Previous (restart only after more than 3 s),
   Next and held ±10 s use the selected audio CD's timeline and engine.
   Held seeks update the display immediately and restart reads at the final
   target after 300 ms without input and the old worker's join. Eject
   (app or drive button), removal/replacement, drive disconnect, drive/source
   change and quit stop/join before session close. The selector icon, menus
   and direct model selection calls are disabled throughout physical
   playback/seeking. Demo/M3 behavior is preserved. All 226 tests, both
   sanitizers, native build and signature pass; see acceptance above.
8. **M4.8 Display and controls** [M4.7]. Status `CD PLAYING`, `CD PAUSED`,
   `CD END` or `BUFFERING` — **done offline**. Errors use the short red form,
   such as `[ERR] Access denied` or `[ERR] Read error`, with details only in
   the log. `ERR n` after concealment and `UNVERIFIED` when alignment or
   independent checking is uncertain follow the status without overlapping
   the media information. Totals after insertion; current track and elapsed
   time while playing. The window layout is unchanged; buttons are enabled
   only when usable, and VoiceOver labels follow the new states.
9. **M4.9 Hardware check tools** [M4.5, M4.6] — **done offline**. The
   approval-gated `OpticalCheck --read-check <drive-id>` exercises raw reads
   and speed restoration without audio output. `AudioCheck --disc <drive-id>
   --activate-silent` checks real-disc PCM through the output callback while
   writing zeros, including start, seek, track boundary, held pause/resume and
   disc end, with drive-speed and Core Audio restoration. The tools' offline
   acceptance and their live M4.10 results are recorded above.
10. **M4.10 Live verification and documentation** [M4.7, M4.8, M4.9] —
    **done**. The optical read check and silent pacing comparison are
    recorded above. The requested minimum speed was not confirmed by readback.
    The first comparison had six concealed sectors at the burst end-of-disc
    segment; one approved repeat passed all segments in both modes without
    underruns or concealed sectors. Audible CD playback was confirmed through
    `External Headphones` after the user unmuted them. The approved physical
    eject-during-playback test stopped audio, showed `NO DISC`, and was
    followed by a normal Cmd+Q quit; read-only checks confirmed no disc, idle
    output and an exited app process. All 235 offline tests pass normally and
    under AddressSanitizer and ThreadSanitizer; package/app builds and strict
    signature verification pass. Only this Pioneer is available, so fallbacks
    for drives without C2 or stream-accurate reads remain verified offline
    until M5.

Not in M4: de-emphasis for pre-emphasised discs (played unmodified; this disc
has none), audio hidden before track 1, pregap/index display, drive read-offset
correction, AccurateRip comparison (no network lookups), and CD-Text.

A drive accepting a speed command does not prove that it obeys it; C2
availability alone does not prove trustworthy error detection. Neither is
claimed by this prototype.

### M5: hardening (complete)

Goal: keep playback safe and predictable across sleep, unplugging and crashes,
then package the app for this Mac. Decisions agreed before starting
(2026-10-30):

- **Sleep:** keep the Mac awake while a CD is playing; the display may still
  sleep. If the Mac sleeps anyway (lid closed, Apple menu > Sleep, low
  battery), pause first and keep the position.
- **Output changes:** pause instead of showing `[ERR] Audio error` when the
  active output changes or disappears, including plugging in or unplugging
  headphones while playing.
- **Rate recovery:** restore output sample rates at the next launch after a
  force quit or crash.
- **Drives:** only the Pioneer is available, so multi-drive and no-C2 checks
  stay offline and are documented as unverified on real hardware.
- **Endurance:** play a whole, shorter disc supplied by the user.
- **Packaging:** this Mac only. Release build with an app icon, ad-hoc signed
  and installed in Applications. No Developer ID certificate is installed, so
  other Macs would show Gatekeeper warnings; notarization is out of scope.

Subtasks in build order (prerequisites in brackets). Each ends with the full
offline suite passing normally and under AddressSanitizer and ThreadSanitizer.
Live steps need explicit approval, and the user performs the physical actions.

1. **M5.1 Sleep and wake** [none] (done and verified live; see
   [M5.1 result](#m51-result-2026-10-30)). Hold a system activity that prevents idle
   sleep and App Nap only while playing, including `BUFFERING`. Before a forced
   sleep, pause through the normal path: stop output, keep the position, and
   close the disc session so the drive speed is restored. Acknowledge the sleep
   only afterwards, within a bounded wait. A paused position also survives
   sleep. After wake, keep `CD PAUSED` at the same position if a drive with the
   same name reports the same TOC, even if macOS reconnects it under new IDs or
   it is briefly absent within a bounded window. A different disc, or no disc,
   resets as today. Offline: injected power events while playing, paused,
   buffering, opening, seeking, ejecting and quitting. Live: Play, Apple menu >
   Sleep, wake, Play.
2. **M5.2 Pause on output changes** [none] (implementation, offline tests and
   live verification complete; live results recorded under
   [M5.4](#m54-result-2026-10-31)). When the playing output
   changes or disappears, stop at the current frame and show `CD PAUSED`; Play
   continues on the current default output. This includes plugging in
   headphones while playing through speakers. Other audio failures still show
   `[ERR] Audio error`. Live: unplug and replug headphones while playing and
   paused.
3. **M5.3 Rate recovery after a crash** [none] (done and verified live; see
   [M5.3 result](#m53-result-2026-10-31)). Persist each recorded original rate
   (device UID, original and applied rates) before changing it, and clear the
   record once restored or superseded by a newer rate. At launch,
   or when a recorded device reappears, restore it only if it is still at the
   rate the app applied; otherwise drop the record. Live: Force Quit during
   playback, relaunch, and confirm the restore in the coreaudiod log.
4. **M5.4 Hot-unplug stress** [M5.1, M5.2] (seeded offline stress and the
   normal, AddressSanitizer and ThreadSanitizer suites complete; live
   verification complete; see [M5.4 result](#m54-result-2026-10-31)).
   Seeded, time-bounded offline runs through the real worker and producer
   interleave drive disconnect/reconnect, disc
   removal/replacement, output loss and sleep/wake with opening, buffering,
   seeking, pausing, ejecting and quitting. Every run must finish without a
   hang or main-thread blocking, with a consistent display, closed sessions
   and drive speed restored. Live checklist: unplug the Pioneer while playing,
   while paused, right after Play, during a held seek and during eject, then
   replug; unplug the headphones while playing and while paused.
5. **M5.5 Multi-drive coverage (offline)** [M5.4] (offline regression coverage
   complete; other-drive hardware behavior remains unverified; see
   [M5.5 result](#m55-result-2026-10-31)). Two fake drives with different read
   features: play one while the other is unplugged or replugged, switch drives
   while paused, and number identical names. Record what remains unverified on
   real hardware: other drives' C2 and stream-accurate fallbacks, and their
   speed control.
6. **M5.6 Endurance** [M5.1, M5.2] (complete; see
   [M5.6 result](#m56-result-2026-10-31)). Play a whole shorter disc to
   `CD END` without interaction. Record underruns and concealed sectors, sample
   memory and CPU over time, and confirm the sleep activity is held. Afterwards,
   confirm the drive speed and output rate are restored. The player logs final
   underrun-frame and concealed-sector totals at `CD END`.
7. **M5.6b Damaged-disc handling** [M5.6] (complete;
   see [M5.6b result](#m56b-result-2026-10-31),
   [retry policy](#m56b-retry-policy-2026-10-31) and
   [single pass by default](#single-pass-by-default-2026-10-31)). Play a user-supplied disc
   that read badly before, and record start-up time, `BUFFERING` episodes,
   underruns, concealed sectors, slow raw reads and control latency during a
   bad patch. Pass: no hang or crash, Pause responds promptly, playback
   resumes, and the output rate and drive speed are restored. The player and
   CDKit log slow or failed raw reads, `BUFFERING` changes, and per-run totals
   whenever playback stops: pause, stop, eject, sleep, output change, error and
   `CD END`.
8. **M5.7 Packaging for this Mac** [M5.1–M5.6] (complete; see
   [M5.7 result](#m57-result-2026-10-31)).
   App icon (options shown for approval first), version 1.0.0, Release build
   with the hardened runtime and an ad-hoc signature, a packaging script,
   install/update/uninstall notes, and installation in Applications (approval
   first).
9. **M5.8 Final acceptance** [M5.1–M5.7] (complete with user acceptance; see
   [M5.8 result](#m58-final-acceptance-2026-10-31)). Offline suites, Release
   build and signature checks, live results and README updates.

#### M5.1 result (2026-10-30)

[SystemPower.swift](../Packages/CDKit/Sources/CDKit/SystemPower.swift) holds the
process activity (no idle sleep or App Nap) and turns IOKit system-power
messages into sleep and wake events. The app delegate starts listening at
launch. [PlayerModel.swift](../Packages/CDKit/Sources/CDKit/PlayerModel.swift)
holds the activity while the state is playing. Before sleep it:

- disables the controls and cancels a pending seek, drive choice or opening
  Play;
- stops the output and closes the disc session, which restores the drive
  speed, then shows `CD PAUSED`;
- allows the sleep exactly once: when the pause finishes, after at most 10
  seconds (timed off the main thread), at once if nothing is listening, or
  when an undelivered notification is dropped;
- keeps the drive name, table of contents, frame, chosen track and read
  quality.

The 60-second grace starts at wake, so a long sleep does not use it up. A
same-named drive with the same disc gets the position back each time it
reconnects during the grace.

Known limits: two drives with the same name are not told apart. A Pause or
Stop pressed just as sleep starts gives way to the sleep, and the CD pauses at
the last displayed position.

Offline: [sleep and wake tests](../Packages/CDKit/Tests/CDKitTests/SleepWakeTests.swift)
(17) inject power events in several states: idle with the disc total, a chosen
track, playing, paused, buffering, seeking, opening the disc, ejecting and
quitting. They also cover a pause that stalls past the limit, reconnection
under new IDs, a different or data disc, the grace, actions after wake, a
second drive and exactly-once acknowledgement. One smoke test registers with
IOKit for real. A real worker/producer test in
[playback lifecycle tests](../Packages/CDKit/Tests/CDKitTests/PlaybackLifecycleTests.swift)
checks three things. Sleep stops the output. The disc closes with its speed
restored. Play after wake renders the same PCM from the same frame. All 282
tests passed three times normally (48.7 s), under AddressSanitizer (16.3 s) and
under ThreadSanitizer (21.3 s), and the 18 sleep tests passed 25 repetitions.
The Debug app builds without Swift warnings, and its ad-hoc signature verifies.

Live (Pioneer BDR-XS07U, a 2-track disc, MacBook Pro Speakers):

- While the CD played, `pmset -g assertions` listed
  `PreventUserIdleSystemSleep` named `Playing an audio CD`. It went away
  before sleep and when playback stopped.
- Apple menu › Sleep:
  - The app paused, closed the disc (drive speed restored to the reported
    4,233 kB/s) and allowed sleep after 362 ms.
  - A trackpad touch 3.6 s later made macOS cancel the sleep.
  - The display still showed `CD PAUSED` at the same track and time, and
    Play continued from there.
- Closing the lid:
  - The app allowed sleep after 405 ms, and `pmset -g log` recorded
    `Clamshell Sleep` 5 s later.
  - A dark wake followed 2 s later, then a full wake 30 s later when the lid
    opened.
  - The display showed `CD PAUSED` at the same track and time, and Play
    continued from there.
  - Afterwards the output was idle at 48 kHz.
- The Pioneer kept its drive and media IDs across this sleep. The path that
  restores the position after the drive reconnects under new IDs is therefore
  verified offline only.

#### M5.3 result (2026-10-31)

All 288 tests passed normally, under AddressSanitizer and under ThreadSanitizer.
The Debug macOS arm64 app build and strict ad-hoc signature verification passed.

Live (Pioneer BDR-XS07U, a 2-track disc, External Headphones; local times):

- At 10:22:16, the app opened the disc for playback and `coreaudiod` recorded
  the headphone output changing from its original 48 kHz to 44.1 kHz.
- The user Force Quit the app during playback. Before relaunch at 10:23:51,
  the app process was absent and the output was still at 44.1 kHz.
  `ChangedOutputRates` in the app's preferences domain (then
  `dev.cdplayer.CDPlayer`, now `io.github.ylau674.CDPlayer`)
  retained the device UID `BuiltInHeadphoneOutputDevice`, original rate
  `48000` and applied rate `44100`.
- Relaunch at 10:24:00 automatically restored 48 kHz. At 10:24:00.873,
  `coreaudiod` logged `Setting BuiltInHeadphoneOutputDSPDevice sample rate to
  48000.000000`; System Information independently reported 48 kHz.
  The saved `ChangedOutputRates` key was removed after restoration.
- The app returned to `CD DETECTED`, showing the disc totals (2 tracks,
  11:29) and a dimmed output-rate icon. Playback did not restart automatically,
  and there were no app recovery-error messages.

This verifies Force Quit recovery on the built-in headphone output.
Disconnected/reconnected outputs and a newer externally selected rate were
not exercised in this live check.

#### M5.4 result (2026-10-31)

The seeded physical-worker stress test runs seeds 1–6. Each run first fills and
drains the real PCM ring until the producer is blocked during buffering, then
interleaves a seeded order of forward/backward seeking, pausing, drive
disconnect/reconnect, disc removal/replacement, output loss, sleep/wake and
eject/reinsert, and finishes by shutting down during playback. The six seeds
also cover pausing, ejecting, removal, replacement, disconnect and sleep while
the producer is blocked. Each wait is capped at 5 seconds and each complete
seeded run at 25 seconds.

The test checks immediate output mute during interrupted reads, display/model
consistency after each event, no main-thread disc or worker operations, closed
sessions, and restoration of every fake drive's speed. All 289 tests passed
normally, under AddressSanitizer and under ThreadSanitizer.

Live (Pioneer BDR-XS07U, 2-track disc, External Headphones; local times):

- **Unplug while playing and while paused: verified.**
  Playback resumed at 10:53:31.059. On removal, the in-flight read reported
  `Device not configured (errno 6)` at 10:53:34.466. The app released its
  playback sleep assertion, restored the headphone output to 48 kHz at
  10:53:34.512, and logged the disc session closed at 10:53:34.525.
  Inspection confirmed no external disk or app-held optical-device file
  descriptor, and the same app process remained running. Its window showed
  `NO DRIVE`, track `00`, time `00:00`, and disabled transport controls.
- After replug, inspection at 10:56:20 confirmed automatic detection in the
  same app process: the Pioneer name, `CD DETECTED`, disc totals of 2 tracks
  and 11:29, and re-enabled transport controls. Playback did not restart:
  output remained at 48 kHz, with no app-held raw-disc descriptor or playback
  sleep assertion.
- Replay began at 10:57:03. The app opened the disc, requested the minimum
  176 kB/s drive speed and changed headphones from 48 kHz to 44.1 kHz.
  At 10:57:11, Pause stopped playback, restored 48 kHz and released the
  playback sleep assertion. At 10:58:29, the display showed `CD PAUSED`,
  track 01 at 00:05; the disc handle remained open, as expected while paused.
- Unplug while paused: at 11:00:36.501 the app logged the disc session closed
  without an in-flight read error because the producer was idle. Inspection
  at 11:00:49 confirmed no external disk or app-held optical-device file
  descriptor, headphones still at 48 kHz, and the same app process running.
  The window showed `NO DRIVE`, track `00`, time `00:00`, and disabled
  transport controls.
- Reconnected at 11:03:22: the same app process showed `PIONEER BD-RW
  BDR-XS07U`, `CD DETECTED`, 2 tracks and 11:29, with transport controls
  enabled. The output remained at 48 kHz, playback stayed stopped, and no
  app-held raw-disc descriptor was open.
- Unplug just after Play: at 11:04:25, the app changed output from 48 kHz to
  44.1 kHz and requested the minimum 176 kB/s drive speed. At 11:04:33.651,
  the read failed with `Device not configured (errno 6)`; the app released its
  playback sleep assertion, restored the headphone output to 48 kHz, and
  closed the disc session at 11:04:33.722. At 11:04:46, no external disk or
  app-held optical-device descriptor remained, and the same app process was
  running. The window showed `NO DRIVE`, track `00`, time `00:00`, and disabled
  transport controls.
- Replug after the just-after-Play test: inspection at 11:07:08 confirmed
  the CD present as `/dev/disk4`, the same app process running, headphones
  still at 48 kHz, and no app-held raw-disc descriptor. The window again
  showed the Pioneer name, `CD DETECTED`, 2 tracks and 11:29, with transport
  controls enabled. Playback did not restart.
- Unplug during held seek: the user held Next through fast-forward and
  unplugged the drive. The app opened the disc at 11:08:13.643, changed the
  output to 44.1 kHz and requested the minimum drive speed. It switched back
  to 48 kHz at 11:08:19.796, released its playback sleep assertion at
  11:08:21.123, and closed the disc session at 11:08:21.129. No read error
  was logged during this cancellation/close sequence. Inspection at 11:08:36
  confirmed no external disk or app-held optical descriptor, while the same
  app process remained alive. The window showed `NO DRIVE`, track `00`,
  time `00:00`, and disabled transport controls.
- Replug after the held-seek test: inspection at 11:10:52 confirmed the CD
  present as `/dev/disk4`, the same app process running, headphones still at
  48 kHz, and no app-held raw-disc descriptor. The window showed the Pioneer
  name, `CD DETECTED`, 2 tracks and 11:29, with transport controls enabled.
  Playback did not restart.
- Eject/unplug attempt: macOS logged the disk-eject request at 11:11:55.148
  and success at 11:11:57.398. The Image Capture service logged the Pioneer
  USB device removed at 11:11:58.702, about 1.3 seconds after eject success.
  At 11:12:15, no external disk or app-held optical descriptor remained;
  the app process was alive, headphones remained at 48 kHz, and the window
  showed `NO DRIVE` with disabled controls. This verifies eject followed by
  unplug, but the system event order does not verify a disconnect during the
  active eject.
- Replug after eject: inspection from 11:14:24 confirmed the Pioneer
  registered on USB and the same app process showing its name and `NO DISC`,
  track `00`, time `00:00`, and disabled transport controls. No CD was
  detected, no app-held raw-disc descriptor was open, and headphones remained
  at 48 kHz. Empty-drive redetection passed.
- Reinserted the CD at 11:15:19: the same app process showed the Pioneer name,
  `CD DETECTED`, 2 tracks and 11:29, with transport controls enabled.
  Playback remained stopped, headphones stayed at 48 kHz, and no app-held
  raw-disc descriptor was open.
- Eject/unplug race: macOS logged the eject request at 11:16:06.540 and
  `ongoing` at 11:16:06.546. The Image Capture service logged the Pioneer USB
  device removed at 11:16:07.234; Disk Arbitration logged eject success at
  11:16:07.235, one millisecond later. This confirms USB removal during the
  active eject. At 11:16:22, no external disk or app-held optical descriptor
  remained; the app process was alive, headphones remained at 48 kHz, and the
  window showed `NO DRIVE` with disabled controls.
- Replug after the eject race: inspection at 11:17:49 confirmed the CD
  present as `/dev/disk4`, the same app process running, headphones at 48 kHz,
  and no app-held raw-disc descriptor. The window showed the Pioneer name,
  `CD DETECTED`, 2 tracks and 11:29, with transport controls enabled.
  Playback did not restart.
- Headphone unplug while playing: playback started at 11:18:45 and switched
  the output to 44.1 kHz. After the headphone route changed, the app logged
  `Audio output changed; CD playback paused.` and released its playback sleep
  assertion at 11:18:56.475. At 11:19:10, macOS showed MacBook Pro Speakers
  as the default output at 48 kHz; `/dev/disk4` remained open, as expected
  while paused. The window showed `CD PAUSED`, track 01 at 00:09, and the
  waveform icon.
- Headphone reconnected while paused: at 11:20:28, macOS showed External
  Headphones as the default output at 48 kHz; the output-rate change was
  logged at 11:20:11.038. The app remained `CD PAUSED`, track 01 at 00:09,
  with the disc session open. Reconnection did not resume playback.
- Headphone-unplug-while-paused attempt: at 11:21:53, MacBook Pro Speakers
  were the default output at 48 kHz and the app showed `CD PAUSED`, track 01
  at 00:19, with the disc session still open. However, logs show the playback
  sleep assertion held at 11:21:16.255 and released at 11:21:29.279, with
  output-rate changes to 44.1 kHz and back to 48 kHz in between. No
  `Audio output changed; CD playback paused.` message was logged. This attempt
  does not establish that the headphone route was removed while already
  paused; the controlled retest below verifies that case.
- Headphone reconnected after that attempt: at 11:23:48, External Headphones
  were again the default output at 48 kHz. The app still showed `CD PAUSED`,
  track 01 at 00:19, with the disc session open; playback did not resume.
- Headphone unplug while paused (controlled retest): the cable was removed
  without pressing any transport button. At 11:24:38, MacBook Pro Speakers
  were the default output at 48 kHz, and the window still showed `CD PAUSED`,
  track 01 at 00:19, with `/dev/rdisk4` open. No playback or output-rate
  change was logged after 11:23:48. This confirms the route change while
  paused did not restart playback.
- Headphone reconnected after the paused retest: at 11:25:33, External
  Headphones were again the default output at 48 kHz. The app remained
  `CD PAUSED`, track 01 at 00:19, with the disc session open; playback did not
  resume.
- On the earlier unplugs with an open disc session, drive-speed restoration
  was attempted but could not reach the disconnected device (`errno 6`).
  This is a physical unplug limitation, not a successful speed restore.
- Normal stop/close with Pioneer connected: playback started at 11:26:57.092,
  switched output to 44.1 kHz, and held the playback sleep assertion. Stop
  returned output to 48 kHz at 11:27:04.900. At 11:27:04.941, the app logged
  `Restored reported drive speed to 4233 kB/s`, closed the disc session, and
  released the sleep assertion. Inspection at 11:27:17 confirmed `/dev/disk4`
  still present, no app-held raw-disc descriptor, External Headphones at
  48 kHz, and the same app process showing `CD DETECTED`, 2 tracks and 11:29.
  Normal connected-drive speed restoration passed.

All planned M5.4 live checks are complete.

#### M5.5 result (2026-10-31)

Added per-drive read profiles to the fake disc opener and an integrated
`PhysicalTransportTests` case with two same-named drives: one reports
stream-accurate reads and supports C2; the other reports neither. The test
plays the selected drive while the other is removed and re-added, confirming
the active session, frame and playback state are unaffected. It then pauses,
switches to the second drive, and verifies that the first session closes and
the second opens only after explicit Play. Stream-accuracy metadata and C2
probe results stay independent between the two sessions.

Existing tests also cover duplicate-name numbering in connection order and
the C2/stream-accuracy recovery combinations. The full CDKit suite passed all
290 tests; the focused physical transport suite passed all 28 tests.

Only the Pioneer BDR-XS07U is available for live testing. Other drive models'
C2 support, stream-accurate reporting/fallback behavior, and speed control
remain unverified on hardware.

#### M5.6 result (2026-10-31)

Played the two-track, 11:29 audio CD through `CD END` without interaction on
the Pioneer BDR-XS07U. Playback ended at 12:08:33.134 with **0 underrun frames
and 0 concealed sectors**. No concealed-sector events were logged.

The `Playing an audio CD` sleep assertion was present at every sample from
11:57:27 through 12:08:23, and was absent after playback ended. CPU and memory
were sampled about every 33 seconds: RSS stayed between 87,984 and 89,952 KB
(about 86–88 MiB); `top` reported about 20–22% CPU during steady playback,
falling to 6.5% near the end and 0% after completion. Its memory column stayed
at 28 MB. These were Debug-build figures; a Release build plays at about 1.7%
(see [CPU and memory check](#cpu-and-memory-check-2026-10-31)).

After playback, `AudioCheck` found External Headphones at 48,000 Hz, idle and
unowned. `OpticalCheck` read the drive's current reported speed as 4,233 kB/s.
Its check requested 176 kB/s, still read back 4,233 kB/s, and verified its own
close restored the reported speed to 4,233 kB/s. The playback log also showed
4,233 kB/s after the app requested 176 kB/s, so the drive did not honor the
minimum-speed request and its reported speed remained unchanged. No app-held
raw-disc descriptor remained after the natural end.

The app is locally/ad-hoc signed, non-sandboxed, and not notarized. Do not use
raw access or a privileged helper to circumvent managed removable-media policy.

#### M5.6b result (2026-10-31)

Tested the two-track, 11:09 disc (lead-out 50232) that read badly on
2026-10-30, in the Pioneer BDR-XS07U. Nobody was available to press Play, so
the disc was played with `AudioCheck --observe`. It uses the same path as the
app (C producer, recovery reader, raw reads and output callback) but sends
zero-valued samples to External Headphones. There were two runs: the first
40 seconds, then the whole disc. The drive again reported 4,233 kB/s after the
176 kB/s request, so it read at about 24× throughout.

| | First 40 s | Whole disc (11:09) |
|---|---|---|
| Start-up to first audio (from 0:00) | 12.7 s | 17.4 s |
| `BUFFERING` after start-up | 0 episodes | 0 episodes |
| Underrun frames | 0 | 0 |
| Concealed sectors | 406 of 3,000 | 911 of 50,195 (1.8%) |
| Raw reads of 0.5 s or more / failed | 7 / 0 | 8 / 0 |
| Pause during start-up `BUFFERING` | 430 ms | 183 ms |
| Resume / final stop | 108 ms / 60 ms | 104 ms / 65 ms |
| Wall time | 55.96 s | 689.80 s |

**The damage is physical and repeatable.** On both runs and on 2026-10-30,
the same LBAs were concealed, for example 37, 45, 54, 62, 78/79 and 87/88 at
the start of track 1, and 23654, 23733 and 23743 in track 2. Near the start,
the most common gap is 8–9 sectors, about one disc revolution at the inner
radius, which points to a radial scratch or defect crossed on every turn. It is
concentrated near the centre:

| Disc time | Concealed sectors |
|---|---|
| 0:00–0:30 | 318 |
| 0:30–1:00 | 205 |
| 1:00–2:00 | 159 |
| 2:00–3:30 | 182 |
| 3:30–5:30 | 34 |
| 5:30–11:09 | 13 |

Track 2 had 17 concealed sectors in total.

**Reads succeeded, but C2 flags stayed set after retries**, so only the
flagged samples were interpolated. No sector became silence because a read
failed. The whole-disc run read 214,220,160 audio bytes (about 1.8 times the
disc, counting retries, cache read-away and overlap) at 674.8 kB/s on average
inside reads. The audio was silent, so how audible the interpolation is was
not assessed.

**Start-up from 0:00 is the visible problem.** Audio starts only once 2 seconds
are buffered (about five producer reads). While buffering, each read may spend
up to 2 seconds retrying, and every retry first reads 74 sectors near the end
of the disc to displace the cache. Retries do not clear a physical defect at
about 24×, so the first 2 seconds of track 1 took 12.7–17.4 seconds to
prepare. In the app this shows as `BUFFERING` at 0:00 for that long, which
explains why the disc seemed unreadable on 2026-10-30. After start-up, the
buffer stays ahead and recovery time is limited to the headroom, so the rest of
the disc played continuously with interpolation. In the app, `ERR n` would
count up to 911.

Pass criteria: no hang or crash, Pause and Stop responded within 0.5 seconds
(the slowest was 430 ms while one raw read was in progress), playback resumed,
and every count matched the CDKit log. After each run, External Headphones
returned to 48,000 Hz, unowned and idle. The drive speed was restored and
verified at 4,233 kB/s, and no process held the disc. The idle app stayed at
0% CPU with no sleep assertion.

Instrumentation added for this test, at notice/warning level so it persists in
the unified log:

- CDKit logs each raw read that takes 0.5 seconds or more, or fails, with LBA,
  sector count, C2 use and duration.
- The player logs `BUFFERING` start and end with the playing time.
- The player logs per-run underrun and concealment totals whenever playback
  stops: pause, stop, eject, sleep, output change, error and `CD END`.

The full suite passed 290 tests normally, under AddressSanitizer and under
ThreadSanitizer.

The silent run did not cover the app itself with this disc or how the
interpolation sounds; the disc was played and listened to in the app after the
retry-policy change (see the next section). The planned artificial damage
steps (smudge, marker line) were not needed, since this disc already has a real
defect.

The slow start led to a change in the retry policy; see the next section.

#### M5.6b retry policy (2026-10-31)

A hardware CD player plays this disc without trouble, so the question was what
happens if the player never retries and simply reads on. A CD player reads
once at 1×. Its decoder corrects what it can and conceals the rest by
interpolation. This app already interpolated the same C2-flagged samples; the
only difference was the re-reads. `AudioCheck --observe ... --no-retry` was
added to read each block once (single pass has since become the default and
the option is now `--retry`; see
[single pass by default](#single-pass-by-default-2026-10-31)), and the whole
disc was played under three policies (same disc and drive, about 24×
throughout):

| | Retry always (before) | Single pass (default from 2026-10-31) | Hybrid (`.retry`) |
|---|---|---|---|
| Resume to first audio at 0:00 | 17.4 s | 323 ms | 321 ms |
| Wall time to first audio (includes a 1 s pause test) | 20.5 s | 3.5 s | 3.5 s |
| `BUFFERING` after start-up / underrun frames | 0 / 0 | 0 / 0 | 0 / 0 |
| Concealed sectors (whole disc / track 2) | 911 / 17 | 1,010 / 21 | 859 / 9 |
| Flagged sectors cleared by a retry | not counted | 0 | 37 |
| Raw reads / audio read (times the disc) | 8,142 / 1.81× | 7,229 / 1.28× | 8,095 / 1.79× |
| Time inside raw reads | 317 s | 60 s | 279 s |
| Raw reads of 0.5 s or more / failed | 8 / 0 | 1 / 0 | 11 / 0 |
| Pause / resume / final stop | 183 / 104 / 65 ms | 347 / 90 / 76 ms | 395 / 95 / 77 ms |
| Wall time for 11:09 of audio | 689.8 s | 672.9 s | 672.9 s |

In every run the first read at LBA 37 took about 1.9 seconds. That is the
drive's own internal re-reading, which no policy controls.

**Retries cost the start, not the steady state.** With retries, the start-up
reads at 0:00 spent up to 2 seconds each on re-reads that seldom cleared
anything. Without them, the first 2 seconds were buffered at once. After
start-up, all three policies played the whole disc without `BUFFERING`.

**Retries change little on this disc.** Single pass concealed about 10–15%
more sectors than the retry runs. The hybrid run cleared 37 flagged sectors by
re-reading, about 4%. Part of the damage is marginal and varies between any two
runs: 672 LBAs were concealed in all three runs, and two single-pass runs of
the first 40 seconds shared only 565 of their 641 and 657. So the differences
between the policies are about the same size as the run-to-run variation. The
hybrid run had the fewest concealed sectors, partly by chance.

Why a CD player copes: it uses the single-pass strategy, at 1× and with a
better read signal than this drive at about 24×. The drive ignores the
176 kB/s request, so this app cannot read at 1×.

**First decision: hybrid by default** (superseded after the listening test
below; see [single pass by default](#single-pass-by-default-2026-10-31)).
CDKit retried flagged blocks only when the buffer had time to spare (normal
playback, with the 30-second ring ahead), never while `BUFFERING` (start, seek
or after an underrun). While buffering, each block was read once and its
flagged samples were interpolated. This kept the start and seeks fast on
damaged discs and kept the re-reads that cost nothing in steady playback. The
cost was unchanged drive work (about 1.8 times the disc, with read-away seeks)
on a damaged disc. On a clean disc no retries happen at all.

Retried matches on this drive cannot prove cache independence, so the retry
and hybrid runs ended `UNVERIFIED` in the CDKit log; the app does not display
this. Samples are bit-exact wherever C2 reports no error, under every policy.

After each run, External Headphones returned to 48,000 Hz, unowned and idle,
and the drive speed was restored and verified at 4,233 kB/s. The full suite
passed 293 tests normally, under AddressSanitizer and under ThreadSanitizer.

**Listening test in the app (2026-10-31, hybrid policy).** The user played the
damaged disc and then two good discs in the rebuilt app, through the Pioneer
drive, with audible output. The damaged disc played without skipping. During
steady playback the drive's seeks were audible: each retry first reads about
74 sectors near the end of the disc, then returns. On the good discs there
were no retries or read-away seeks, only short sequential reads, and drive
noise was minimal. From the app's log:

| Session | Start → stop | Play to audio | Underrun frames | Concealed | Read rate |
|---|---|---|---|---|---|
| Damaged disc, from 0:00 | 0:00 → 0:34 | about 2.6 s | 0 | 349 | – |
| Damaged disc, from 0:00 | 0:00 → 0:25 | about 1.2 s | 0 | 295 | 466 kB/s |
| Damaged disc, track 2 | 5:10 → 5:14 | about 0.8 s | 0 | 3 | 644 kB/s |
| Good disc A, three skips | 0:00 → 18:54 (paused) | about 1.0 s | 0 | 0 | 1,749 kB/s |
| Good disc B, two skips | 0:00 → 51:28 | about 2.8 s | 0 | 0 | 1,684 kB/s |

"Play to audio" runs from the drive-speed request to the end of `BUFFERING`.
The first damaged-disc session includes the drive's own 1.96-second read at
LBA 37. Good disc B started with two spin-up reads of 0.9 seconds each. The
read rate is the average inside raw reads; the first session's figure was not
kept. The good discs read at about 1.7 MB/s, so the drive is busy only about a
tenth of the time. The drive still reported 4,233 kB/s after every 176 kB/s
request, and the speed was restored after each session. M5.6b is complete.

#### CPU and memory check (2026-10-31)

Checked again before M5.7 because M5.6 showed 20–22% CPU. Nobody was available
to press Play, so a temporary harness (not in the repository) ran the app's own
views, `PlayerModel`, engine and drive service. It pressed Play itself and quit
through `PlayerModel.shutdown()`. Each run played the damaged disc's track 2
from 5:10 for 60 seconds with the window visible. The engine was also measured
alone with `AudioCheck --observe` on the clean 6:00–7:00 stretch. CPU is
cumulative process time over 40–53 seconds of steady playback, as a percentage
of one core:

| Measurement | Before | After |
|---|---|---|
| Engine alone, Debug build | 16.5% | unchanged |
| Engine alone, Release build | 1.2% | unchanged |
| App views and model, Release, with a clock instead of the engine | 5.8% | 0.67% |
| Whole player on the disc, Release | 6.8% | 1.7% |
| Physical footprint while playing (whole player) | 28 MB | 28 MB |

So M5.6's figure came from the Debug build. Unoptimized sector decoding cost
about 16%, mostly Swift generic-metadata lookups, and the display cost about
6%. Two display costs were fixed:

- `TransportButton` replaced both symbol images and reset the tint, tooltip,
  accessibility label and enabled state on every SwiftUI update. Each new
  image made AppKit resolve the SF Symbol again and lay out the window. Now it
  applies only what changed.
- `PlayerModel` published five values on every 100 ms poll, even unchanged
  ones, because `@Published` notifies on every assignment. `currentFrame` now
  notifies views only when the displayed track or whole second changes.
  `bufferedFrames`, which nothing displays, is no longer published. The
  buffering and quality values are assigned only when they change. The window
  now updates about once a second instead of ten times, and screenshots taken
  two seconds apart still showed the clock advancing every second.

Memory stayed flat in every run. The physical footprint, which Activity
Monitor and `top` show, was 28 MB while playing and 29 MB for the idle Debug
app. The engine alone used 10–11 MB. RSS of about 93–98 MB is mostly shared
system frameworks. The full CDKit suite passes all 294 tests, including under
Address Sanitizer and Thread Sanitizer.

An earlier Debug `--observe` run from 0:00 overlapped with playback in the app,
so two processes read the drive at once. Both saw repeated `BUFFERING` and raw
reads of about 0.5 seconds; the app paused when `AudioCheck` restored the
output rate. That was contention, not the disc: runs on their own had none.
Don't run `AudioCheck` or `OpticalCheck` on a disc the app is playing.

#### Single pass by default (2026-10-31)

After the listening test, the user chose stand-alone CD-player behaviour: no
re-reads and less drive noise, at the cost of slightly more patched sectors.
`DiscRetryPolicy.singlePass` is now the default for every `DiscSession`, and
the app uses it:

- Each block is read once. C2-flagged samples are interpolated and counted on
  the display (`ERR n`). There are no retry rounds and no read-away seeks to
  the end of the disc, the seeks that were audible in the listening test.
- A block that fails outright, or whose overlap cannot be aligned, is still
  split into single-sector reads within the 2-second budget. Otherwise one bad
  sector would silence up to 33 (about 0.45 seconds); a hardware CD player
  also patches only the damaged frames. No measured run had a failed read.
- Without C2 (not this drive), PCM read once cannot be checked and stays
  `UNVERIFIED`. The app does not display this.
- On the damaged disc, single pass patched about 15% more sectors than the
  hybrid over the whole disc (1,010 against 859), read 1.28 times the disc
  instead of 1.79, and spent 60 seconds inside raw reads instead of 279 (see
  the table above). The difference in patched sectors is about the size of the
  run-to-run variation. Clean discs are unaffected; they never needed re-reads.

The hybrid remains available as `DiscRetryPolicy.retry`
(`DiscSession.setRetryPolicy(.retry)` or `AudioCheck --observe ... --retry`);
the app has no setting for it. Without `--retry`, `AudioCheck --observe`
keeps the session's default, so it measures what the app plays, and it prints
the policy the session reports.

Verified live with the default policy on the damaged disc, 0:00–0:40, silent
output through the MacBook Pro speakers:

| | Earlier `--no-retry` run | Default policy now |
|---|---|---|
| Policy reported by the session | single pass (forced) | single pass (default) |
| Pause during start-up `BUFFERING` | 2.09 s after start | 2.41 s after start |
| `BUFFERING` after start-up / underrun frames | 0 / 0 | 0 / 0 |
| Concealed sectors | 641 | 548 |
| Flagged sectors cleared by a retry | 0 | 0 |
| Raw reads / audio bytes | 755 / 15,452,640 | 756 / 15,534,960 |
| Slow raw reads (0.5 s or more) | 1 (LBA 37, 1,926 ms, drive's own) | 1 (LBA 37, 1,878 ms, drive's own) |

The raw-read counts match, so no re-reads or read-away happened. The lower
concealed count is run-to-run variation in the disc's marginal sectors. The
output returned to 48,000 Hz, unowned and idle, and the drive speed was
restored and verified at 4,233 kB/s.

Tests that exercise re-reads, read-away and the 96-operation cap now opt into
`.retry`. Tests whose outcome depends on the policy run under both: a drive
without C2, a transient read error, a failed C2 probe and a misaligned
overlap. A session test checks the single-pass default and the opt-in. The
suite passes all 294 tests, including under Address Sanitizer and Thread
Sanitizer.

CPU and memory were measured on the damaged disc with
`/usr/bin/time -l AudioCheck --observe 0 670 [--retry]`, one process at a time,
with the app idle. Every run played the whole disc (669.27 seconds of audio)
with no `BUFFERING` after start-up and no underruns. CPU is user plus system
time as a percentage of one core:

| Whole disc | Single pass, Release | Retry, Release | Single pass, Debug | Retry, Debug |
|---|---|---|---|---|
| CPU time | 8.8 s (1.3%) | 8.5 s (1.3%) | 125.3 s (18.6%) | 112.5 s (16.8%) |
| Instructions retired | 22.5 G | 23.5 G | 1,739 G | 1,851 G |
| Cycles | 17.5 G | 17.2 G | 267 G | 284 G |
| Peak physical footprint | 10.9 MB | 11.6 MB | 11.0 MB | 11.5 MB |
| Raw reads / audio bytes read | 7,218 / 151.5 MB | 8,376 / 230.2 MB | 7,233 / 151.5 MB | 8,067 / 210.4 MB |
| Time inside raw reads | 64 s | 308 s | 60 s | 306 s |
| Concealed sectors | 793 | 852 | 907 | 973 |

- CPU is unchanged. Single pass executes 4–6% fewer instructions. Its Debug
  run used more CPU seconds despite fewer cycles because it ran at a lower
  average clock (2.1 against 2.5 GHz). In Release, which M5.7 ships,
  60-second windows on a damaged stretch (0:00) and a clean one (6:00) both
  cost 1.6%, including the read-ahead fill.
- Memory is about 0.5–0.75 MB lower, because no retry candidates are kept.
  The policy affects only the engine, so the whole player's figures above
  (1.7% and 28 MB in Release) still apply.
- Compare whole discs, not short windows. In a 60-second window single pass
  fills the 30-second read-ahead immediately and decodes about 90 seconds of
  audio, while retry is still seeking, so single pass looked 30–45% more
  expensive.
- The drive does far less work: it reads 1.28 times the disc's audio instead
  of 1.78–1.95 times, and spends about a fifth of the time inside reads.
- Concealed sectors overlap between policies (single pass 793–1,010, retry
  852–973, over three whole-disc runs each), so run-to-run variation outweighs
  the policy.

#### M5.7 result (2026-10-31)

The app icon uses the user-provided iridescent optical-disc image, scaled into
the standard macOS icon sizes with transparency preserved. The app is version
1.0.0 (build 1). `Tools/package-release.sh` generates the Xcode project, builds
the universal Release app, checks its version and signature, and creates
`build/packages/CDPlayer-1.0.0-macOS.zip`.

The verified Release app contains both `arm64` and `x86_64` architectures,
uses the hardened runtime, and has an ad-hoc signature. The ZIP passes its
integrity check. The package is for this Mac only; it is not Developer ID
signed or notarized and is not suitable for distribution to other Macs.

After approval, install by opening the ZIP in Finder and dragging
`CDPlayer.app` to `/Applications`. To update, quit CD Player normally, drag the
new app into `/Applications`, and choose **Replace**. To uninstall, quit
normally, then move `/Applications/CDPlayer.app` to the Trash. A normal quit
closes the disc session and restores any output sample-rate change before
removal; do not remove the app while a recovery is pending. No installer is
required; Finder may ask you to authorize copying it into `/Applications`.

After approval, the Release app was copied to `/Applications/CDPlayer.app`.
Its installed signature, 1.0.0 version and icon metadata were verified. The
install verification did not launch the app. Subsequent playback acceptance
is recorded under M5.8 below.

#### M5.8 final acceptance (2026-10-31)

Offline acceptance on 2026-10-31: all 295 tests passed normally, under
AddressSanitizer and under ThreadSanitizer. The Release packaging script
rebuilt the universal app and ZIP. The app is version 1.0.0, has the hardened
runtime and an ad-hoc signature; strict signature verification passed for
both the Release build and `/Applications/CDPlayer.app`. The ZIP passed its
integrity check. Xcode emitted non-fatal CoreDevice/CoreSimulator host-tool
warnings, but the build succeeded.

Live first-launch evidence from the installed Release app: the app read and
played the damaged CD. At 17:03, its log showed playback
paused at 326.28 seconds, with 0 underrun frames and 3 concealed sectors.
This confirms the installed app can access and play the disc.

At 17:11 on 2026-10-31, the user confirmed they had played the CD and that
the behavior was accepted and as expected. This user sign-off closes M5.8
and the local version 1.0.0 scope. It is an overall acceptance, not a new
item-by-item report of track/seek, resume, stop, Eject and quit; the earlier
milestone results remain the detailed evidence for those controls.

The documented hardware limits remain: mounted-CD playback has not been
tested live on an unrestricted Mac; additional drives and their read-feature
fallbacks have only offline coverage; and the Pioneer's exact minimum read
speed is unconfirmed. Developer ID signing and notarization for distribution
to other Macs remain outside this release's scope.

#### M6.1 layout and built-in selector (2026-11-01)

Implemented the first stage of the audio output roadmap, without changing
the audio engine or built-in device selection:

- The source format moves beside the power button. Long drive names
  truncate in the middle first, including with the drive selector visible.
- Row 2 shows status and a checked Built-in output menu; the rate icon is
  separate and stationary. The selector remains available during playback.
- Overflow uses a Core Animation marquee: a two-second pause, 24 pt/s,
  a loop gap, and no per-frame app timer. Status changes preserve its phase.
- Reduce Motion replaces scrolling with middle truncation of the name.
  The full name/connection remain in help and accessibility. Status and
  selector have separate accessibility elements and a working menu action.
- Animation is removed when the line fits or its window becomes occluded.

Validation:

- 302 package tests pass normally, with AddressSanitizer and with
  ThreadSanitizer. Both Debug and Release app builds pass.
- Five native AppKit tests compile the actual app views, using fake engines
  and drives with no hardware access. They check exact window/row widths,
  demo and empty states, long drive names with one and two drives, actual
  font fitting, Reduce Motion, phase continuity, moving-name hit testing,
  window visibility, the selected menu tick/action and opening the menu
  through its accessibility action while scrolling.
- Fixture screenshots confirm the source format stays intact and the drive
  name truncates first at 426 pt. Test result bundles retain those images.
- macOS denied System Events keystroke automation earlier. Tests use their
  own views and menu methods; that restriction was not changed or bypassed.
  VoiceOver-facing roles, labels, help and actions were checked in-process;
  this was not a manual spoken VoiceOver listening test.

The owner reconnected the Pioneer BDR-XS07U, with an 11-track, 49:07 CD,
and requested completion of the remaining checks. A session-local Release
harness compiled the actual `PlayerView`, `OutputStatusLine` and transport
controls against the Release CDKit library. It used `PlayerModel` with real
drive monitoring, the real disc session and `silentOutput: true`. No other
process read the disc. It sent zero-valued output, never changed volume or
ejected the disc.

To force overflow while keeping M6.1 built-in-only, the harness changed
only the displayed output name to "Pioneer USB Audio Device" and supplied
display-only `ERR 12` / `UNVERIFIED` flags. The real device remained
MacBook Pro Speakers; no USB routing or artificial audio corruption was
involved. Real playback had zero concealed sectors and no unverified flag.

CPU was measured as process user-plus-system time divided by wall time
(one core = 100%), after a 15-second playback warm-up and three seconds to
settle each display mode:

| Full Release UI, silent CD playback | Sample | CPU |
|---|---|---|
| Stationary status/output line | 60 s | 1.79% |
| Scrolling status/output line | 90 s | 1.81% |
| Window hidden, no animation | 30 s | 1.79% |

- Scrolling is below the approximately 2.7% acceptance target, and about
  0.02 percentage points above the same-run stationary measurement.
- The rate icon's frame stayed identical in every mode. Playback frames
  advanced throughout, with zero underruns and a changing real PCM checksum.
- Pause restored 48 kHz; Play resumed from the paused position at 44.1 kHz.
  Next/Previous worked, and Stop returned the disc summary.
- The rate icon kept 44.1 kHz while stopped and restored the original rate.
  Shutdown restored the requested drive speed and left the output idle at
  48 kHz, with no exclusive owner or pending rate record. This does not
  establish that the drive physically obeys its minimum-speed request.

M6.1 software acceptance is complete. No release, installation, commit or
M6.2 output-routing change was made.

#### Name-only scrolling (2026-11-01)

The owner refined row 2: the status on the left, the menu indicator ("▾")
and the rate icon on the right must not scroll; only the output name does.

- `OutputLineLayout` now places the status at the left edge and the
  indicator just left of the rate icon, both fixed. The name gets the space
  between them (at least the 12 pt gap after the status). It scrolls within
  that space when it overflows, or truncates in the middle with Reduce
  Motion. One pass moves the name by its own width plus the 60 pt loop gap,
  with the same two-second pause and 24 pt/s speed.
- The status is never scrolled. It is cut short with "…" only if it would
  leave room for fewer than seven name characters, which no current status
  does in the 368 pt line; its tooltip and VoiceOver label stay complete.
- `OutputStatusLine` draws the status and indicator as fixed layers on the
  view, and the two name copies in a scroller inside a clipping layer. The
  click target and the accessibility selector frame are the fixed name
  space plus the indicator, so hit testing no longer reads the presentation
  layer. A status change only moves the start of the name space and keeps
  the pass; a different name starts a new pass.

Validation:

- 303 package tests pass normally, with AddressSanitizer and with
  ThreadSanitizer, including new tests for the fixed indicator, the
  status-only update, a renamed output and the status giving way.
- The five native AppKit tests pass. One now checks, while the name
  scrolls, that the status and indicator are not inside the moving layer,
  carry no animation and keep identical on-screen frames, and that the name
  space ends exactly at the indicator.
- A hardware-free Release harness showed the real `PlayerView` in demo mode
  with a long fixture output name and captured the window on screen three
  times, 2.8 seconds apart. The status pixels and the indicator and
  rate-icon pixels were identical in every capture; the name pixels changed.
- In that harness, with no playback, the app process used 0.007% CPU over
  30 seconds while the name scrolled and 0.002% with a name that fits. The
  earlier 1.81% full-playback figure was measured with whole-line scrolling;
  the drive was not used again for this revision.
- Debug and Release app builds pass.

The owner then limited the output name to half of the whole second line.

- `PlayerView` passes half of the full 390 pt row, 195 pt, as the name's
  maximum width. The row width includes the rate icon, so the limit stays
  the same when the icon is hidden. The indicator is not counted in it.
- A name wider than that scrolls (or, with Reduce Motion, truncates) within
  195 pt, right-aligned against the indicator, even when the status is
  short. Shorter names are unaffected: "Pioneer USB Audio Device" and
  "MacBook Pro Speakers" still fit and keep still. A long status still
  narrows the space further, as before.
- 304 package tests pass normally, with AddressSanitizer and with
  ThreadSanitizer, including a new test for the limit, exact-limit and
  Reduce Motion boundaries, and a long status narrowing the space further.
- Six native AppKit tests pass. The new one shows the real `PlayerView`
  with a long fixture output name and checks the 195 pt name space, the
  fixed indicator and status, and the selector frame.
- The hardware-free harness captured the window three times while a
  49-character fixture name scrolled. The name space measured 195 pt, and
  the status, indicator and rate-icon pixels did not change. App-process
  CPU over 30 seconds was 0.14% scrolling and 0.002% with a fitting name.
- Debug and Release app builds pass. No drive or audio output was used.

#### M6.2 wired output discovery and selection (2026-11-01)

Implemented the wired-output discovery and saved-selection milestone without
changing the playback route. M6.3 still owns native-rate playback on a selected
external output and moving playback between outputs.

- `CDAudioCore` can now inspect every live Core Audio device with a readable
  transport and at least one output stream. It records the Core Audio UID,
  transport, current rate, available 44.1 kHz rate, hog owner, terminal,
  output channels, default status and any UID-keyed restore rate. It does not
  set rates or start audio. Multi-stream devices are discovered; playback
  format/channel mapping remains for M6.3.
- `PlayerModel` lists only Built-in, USB, HDMI, DisplayPort and Thunderbolt.
  Bluetooth, AirPlay, aggregate, virtual, other and unknown-transport
  devices are filtered out. Unsupported 44.1 kHz or fewer-than-stereo-channel
  outputs remain visible but disabled with the reason in the menu title.
- Menu identity uses the Core Audio UID, not the transient object ID; the
  transport appears in the menu. `UserDefaultsOutputSelectionStore` saves
  only the selected UID.
- With no saved UID, selection prefers the supported wired macOS default,
  then Built-in, then the first supported wired output. If a saved UID is
  missing, it stays saved while the next-best output is selected. When the
  device reconnects with a new object ID, its UID matches and the saved
  choice is restored while stopped or paused. Since 2026-11-04, Play on the
  next-best output saves it instead, so only a reconnection before any Play
  restores the saved choice. A user selection is persisted
  but does not yet reroute playback.
- The existing Core Audio monitor now also observes stream, supported-rate
  and transport changes and refreshes the output list on device-list or
  default-output notifications. The built-in speaker guidance is restricted
  to a Built-in output, not an external device whose terminal is labelled
  "Speaker".

Validation:

- 311 package tests pass normally, with AddressSanitizer and with
  ThreadSanitizer. They cover transport filtering, order, enabled/disabled
  reasons, persistent UID storage, default and Built-in fallback, missing
  saved outputs, reconnection with a changed object ID, and monitor-driven
  list updates.
- Six native AppKit tests pass, including the disabled menu item and its
  reason. Debug and Release app builds pass.
- No playback or sample-rate changes, and no optical-drive reads, were
  performed. Output selection is a saved preference only; the app continues
  using the built-in playback route until M6.3.

Live classification check (read-only, 2026-11-01), using CDKit's own
`discoverOutputs()` and the running Release app:

| Device | Core Audio transport | Listed as | Notes |
| --- | --- | --- | --- |
| beyerdynamic PRO X | USB | "beyerdynamic PRO X — USB", enabled | macOS default; 384 kHz at the time; 44.1 kHz offered; stereo; terminal "Speaker"; input-only half not listed |
| MacBook Pro Speakers | Built-in | "MacBook Pro Speakers — Built-in", enabled | terminal 0x301 |
| Microsoft Teams Audio | Virtual | not listed | |
| ZoomAudioDevice | Virtual | not listed | |

- With no saved choice, the running app showed "beyerdynamic PRO X ▾" in
  row 2, because it was the supported macOS default.
- The rate icon still describes the built-in playback route (MacBook Pro
  Speakers) until M6.3 routes playback to the selected output.
- The PRO X reports a "Speaker" terminal although it is a headset. The
  speaker guidance correctly stays limited to built-in outputs, but the M6.3
  rate-icon rule (headphone only for headphone or headset terminals) would
  show a waveform for it.
- HDMI, DisplayPort and Thunderbolt outputs were not connected, so they
  remain unvalidated live.

#### M6.3a System Default and device icons (2026-11-01)

The user asked for System Default first, because it is quicker, then the
wired outputs, and for the output icons to match the device type. The
roadmap's M6.3 is now in two parts: M6.3a (this entry) and M6.3b, native
44.1 kHz on a selected USB, HDMI, DisplayPort or Thunderbolt output. The
former M6.4 became M6.3a, and the later milestones moved up one number.

- **C core:** `cd_audio_inspect` and `cd_playback_start` take a
  `CDOutputTarget`: the 1.0.0 built-in rule, or the macOS default output.
  - For the default output, Play records, switches and verifies 44.1 kHz
    where the device offers it, as on the built-in output. It writes to the
    device directly only when the device then accepts 44.1 kHz stereo on a
    single output stream.
  - Otherwise, or without a 44.1 kHz rate, it plays through Apple's HAL
    output unit (AUHAL) without changing the rate, and macOS converts rate
    and channels. The unit takes 44.1 kHz Float32 stereo, converted from the
    CD's samples with the same 2⁻¹⁵ factor, and is created on each start
    and disposed on stop. `CDDeviceInfo.converts` reports which path is
    used. `CDAudioCore` now links AudioToolbox.
  - While System Default plays, a change of the default device returns
    `CD_DEFAULT_OUTPUT_CHANGED` from the status check. Rate and format
    changes on a converting output are left to macOS.
- **Swift engine:** `OutputTarget` (`.builtIn`, `.systemDefault`) is passed
  to `inspectOutput(on:)`, `start(at:on:)`, `matchSourceRate(on:)` and
  `restoreRate(on:)`. `OutputInfo.converts` carries the path.
- **Selector:**
  - The menu ends with a separator and "System Default — PRO X (USB), best
    effort"; the entry is disabled when macOS has no default output.
  - The choice is saved as `SelectedAudioOutputIsSystemDefault`, beside the
    M6.2 UID key, so an M6.2 saved device stays selected.
  - System Default is also the last-resort automatic fallback, after the
    wired outputs.
- **Device icons:** `OutputTransport.symbol(usesSpeakers:)` gives every
  menu entry and the rate icon a symbol for the output type:
  `speaker.wave.2` or `headphones` (built-in), `cable.connector` (USB),
  `tv` (HDMI), `display` (DisplayPort), `bolt` (Thunderbolt),
  `airplayaudio` (AirPlay), `headphones` or `hifispeaker` (Bluetooth) and
  `hifispeaker` (anything else). System Default uses its device's symbol.
  This replaces the 1.0.0 waveform for built-in speakers, and the PRO X now
  shows the USB symbol although it reports a "Speaker" terminal.
- **Moving playback:** choosing System Default or a built-in entry while
  playing stops and restarts at the same frame on the new target, and
  restores any rate Play changed on the previous output. If the new output
  cannot start, playback stops at that position with its error, as a failed
  Play does, and Play tries again from there. Choosing another wired entry
  while playing changes nothing yet, because it still plays through the
  built-in rule until M6.3b.
- **Default changes during playback:**
  - The output monitor or the status check notices the change, whichever
    comes first.
  - After a 500 ms settling delay, because macOS can announce the new
    default before removing the old device, the player checks whether the
    previous default still exists.
  - If it does, the user chose the new default, and playback moves to it.
  - If not, playback pauses with "OUTPUT LOST" and the lost device's name in
    the tooltip, whichever notification arrives first.
  - While stopped or paused, the selector only updates.
- **Labels:** the output line says "System Default, best effort", with
  "Native 44.1 kHz" or "Converted by macOS". The rate icon's label and the
  guidance say when macOS converts. Nothing says "bit-perfect" for System
  Default. VoiceOver reads, for example, "PRO X, system default, usb, best
  effort".

Validation:

- 323 package tests pass normally (twice), with AddressSanitizer and with
  ThreadSanitizer. Eleven new System Default tests cover the icons,
  resolving the default (a Bluetooth default included), the conversion
  labels, the rate-switch target, moving between targets while playing, a
  move that cannot start (position kept, Play retries), a default change
  while stopped, a chosen default change through both notification paths,
  a disconnect with the notifications in either order, and no default
  output. Existing fakes now record the target of every start, inspection
  and rate change.
- Six native AppKit tests pass. The menu test now checks the separator, the
  System Default entry, every entry's image, and that choosing it selects
  System Default. The UI tests use their own selection store, so the app's
  saved choice cannot affect them.
- Debug and Release app builds pass with no warnings from the changed code.
- All icon symbols were checked to exist on this Mac; they date from macOS
  11, below the macOS 14 deployment target.
- No playback, sample-rate change or drive access was performed. The PRO X
  stayed the macOS default at 384 kHz throughout.

Still to check live: Bluetooth headphones and the N-50's AirPlay output
(playback, the rate and the conversion label shown, and the delay between
the time display and what is heard); moving between them from the Sound
menu; switching the headphones off, or unplugging the PRO X as the default,
during playback; and an HDMI or multichannel default output through the
conversion path, which plays only to the first two channels.

#### M6.3b Selected wired output routing (2026-11-01)

M6.3b routes selected USB, HDMI, DisplayPort and Thunderbolt outputs using
their persistent Core Audio UIDs. The existing Built-in route remains
unchanged, and System Default retains its separate best-effort behavior.

- **C Core Audio target:** inspection, rate control and playback now accept a
  selected-device target. The target is resolved and checked again by UID;
  playback requires a live wired output with stereo channels and native
  44.1 kHz support. It does not take hog mode. Wired-output failures include
  the device name when Core Audio has made it available.
- **Rate handling:** the selected UID is used to match and restore the
  output rate. Playback records a changed rate for recovery, and stopping or
  moving away from an output restores its prior rate under the existing
  per-UID rules.
- **Rendering:** a multistream wired device uses AUHAL at 44.1 kHz, with a
  channel map that sends stereo to the device's preferred output channels
  and silences the rest. The IOProc path has the same mapping
  (`cd_ring_render_mapped`), but it is not reached yet (see "Open items"
  below). System Default's separate conversion path remains unchanged.
- **Player behavior:** selecting another wired output while playing moves
  playback at the same frame. A failed move keeps that position and reports
  the error; a retry uses the selected UID. If a selected wired output
  disappears, playback pauses at its current position and the selector
  falls back without automatically resuming.

Validation:

- All 327 package tests pass normally, with AddressSanitizer, and with
  ThreadSanitizer. Coverage includes UID-based inspection and rate
  selection, same-position routing and retry, output-loss fallback, and the
  mapped PCM renderer. The route-change tests wait until the pause/fallback
  transition is complete before acting on or asserting the controls.
- All six native AppKit UI tests pass.
- XcodeGen project generation and Debug and Release app builds pass.
- `git diff --check` passes.
- No disc was read, no audio was played, and no hardware output rate was
  changed. Real device routing, preferred-channel indexing, and AUHAL layout
  remain unverified and are deferred to M6.5 hardware validation.

Open items, found in a review the same day: M6.3b is not complete. The
roadmap's acceptance list had been narrowed to match the tests written,
without agreement; the agreed list is restored there.

- `validate_format` requires a 2-channel stream on the IOProc path, so a
  single-stream output with more than two channels (as HDMI often has) is
  refused at Play, and the IOProc channel mapping is not reached.
- The 2-channel 44.1 kHz format preference is not implemented.
- The System Default tooltip does not yet suggest choosing a listed wired
  entry directly.
- No tests for a non-built-in output cover: restoration on every exit path;
  refusal when another app has exclusive use; crash recovery with the device
  absent and present; an output without 44.1 kHz; and, on a move, the
  previous output's rate restored and the new rate verified.

#### M6.3b Silent CD checks on USB and HDMI (2026-11-01)

The owner connected the PRO X, Sony WALKMAN and Samsung HDMI, inserted an
audio CD and confirmed that all devices were ready to check. The tests used
the production disc/PCM/output pipeline with zero-valued output samples.
No app was running and no other process held the disc device at preflight.
The PIONEER BDR-XS07U reported an unmounted three-track audio CD, 64,032
sectors and 37,650,816 frames (14:13), with no pre-emphasis flags.

Preparation:

- Added `AudioCheck --list-outputs` for read-only UID discovery and
  `--output-uid` for inspection and all silent check modes. The default
  remains the built-in output. Each check verifies the selected UID and
  restores the output's rate and idle state; each normal segment now verifies
  restoration immediately after stopping.
- Reproduced the single-stream 8-channel format rejection with offline
  regression tests before fixing it. The direct wired path now accepts
  interleaved or planar Float32 with at least two channels and compatible
  physical PCM at 44.1 kHz. It rejects non-PCM physical formats and physical
  formats below 16 bits or with too few channels. No physical channel-count
  setting or clock source is changed.
- Added 8-channel mapped-render checks for exact PCM and checksums, silent
  unused channels and silent EOF tails, including planar output.

Each device passed engine-level start, seek, crossing a track boundary,
pause held at the same frame for 0.5 seconds, resume, and the exact disc end.
All six segments per device matched checksums from separate reference reads,
with zero underrun frames and zero concealed sectors.

| Selected output | Before and restored rate | Physical PCM observed while active | Silent PCM consumed |
|---|---|---|---|
| beyerdynamic PRO X (USB) | 384 kHz | 44.1 kHz, 32-bit, 2 channels | 30.15 s |
| Sony WALKMAN (USB) | 384 kHz | 44.1 kHz, 32-bit, 2 channels | 30.10 s |
| SAMSUNG (HDMI) | 48 kHz | 44.1 kHz, 24-bit, 8 channels | 30.15 s |

An independent read-only Core Audio probe observed each active physical and
virtual format. HDMI used the existing 8-channel stream and reported preferred
stereo channels 1 and 2. Full before/after probe output matched for all three
devices, including the system default (Samsung), ownership, formats and
exposed controls. PRO X output volume stayed at 0.4375 and mute stayed off;
its separate microphone was idle at 48 kHz before, during the sampled USB
playback observation, and after the tests. Neither WALKMAN nor Samsung exposed
host volume. The drive's original reported speed, 4,233 kB/s, was restored
and verified after every run. No rate-recovery record or open disc handle
remained after the checks.

Offline validation: all 332 package tests pass; the eight focused format and
PCM tests also pass under AddressSanitizer and ThreadSanitizer. Eight invalid
CLI combinations reject before activation or disc access. Read-only discovery
and the existing default built-in inspection pass. The Release app builds.

Scope limits: no audible playback, acoustic channel-placement check,
device-display rate confirmation, receiver lock-time measurement,
disconnect/reconnect, exclusive-use takeover, crash-recovery or inter-device
move was tested in this run. The callback checksums establish the app's
consumed CD PCM, not end-to-end bit-perfect output. The physical 2-channel
format preference, System Default tooltip and remaining M6.3b acceptance
tests stay open. Nothing was ejected, installed or committed.

#### M6.3b Offline acceptance-test follow-up (2026-11-01)

Added two targeted policy tests and strengthened the unsupported-output test:

- A selected wired output's exclusive-use error remains attached to that UID,
  is reported to the user, and does not trigger a fallback start.
- Quit requests output-rate cleanup while the wired UID is selected; the
  recorded target is that UID.
- An output that does not support 44.1 kHz remains listed as disabled and
  cannot be selected for playback.

These are model/policy tests using fake engines and rate controls. They do
not prove that Core Audio detected a real external hog owner or that its C
rate-record logic restored hardware during quit. Existing live silent runs
did exercise repeated start/stop restoration on each output. Crash recovery
with a missing and returning device, all C restoration exit paths and
two-output native-rate restoration still need an injectable Core Audio/rate
record backend or controlled live tests.

The focused output/player suites pass (69 tests). The complete package suite
passes (334 tests); the selected output-format and renderer tests pass under
ASan and TSan; and the Release application build succeeds. No hardware was
activated during this follow-up.

#### M6.3b Offline sample-rate recovery backend

Extracted the sample-rate apply, restore and recovery coordinator into shared
C logic with injected device, rate, ownership, wait and record-store
operations. Production still supplies Core Audio and CFPreferences adapters;
the new test-support target supplies an isolated fake backend. The tests do
not access live devices or the app's preferences domain.

The shared C paths now have offline coverage for rate apply and verified
restore, clearing stale records without overwriting a user's later rate,
refusing an external hog owner while retaining recovery data, keeping records
for absent outputs and restoring them after reconnect, recovery-only record
filtering, two-output rate restoration, and set/wait error handling with
record retention or cleanup as appropriate. The tests also confirm that the
current process's own hog ownership is not mistaken for another app.

This tests the common production state machine, not the Core Audio and
CFPreferences adapters themselves. Real HAL hog refusal and process-restart
preference persistence remain hardware/integration checks.

Verification: all nine focused recovery tests pass under normal, Address
Sanitizer and Thread Sanitizer runs; the complete package suite passes (343
tests); the Release package build succeeds; and `git diff --check` is clean.
No live hardware or application preferences were touched.

#### M6.3b System Default direct-route guidance

When System Default points to an enabled wired output that also appears in
the selector, its tooltip and VoiceOver help now recommend selecting that
entry for direct 44.1 kHz playback. No recommendation is shown for wireless
defaults or wired outputs disabled for native playback. Focused System Default
tests cover the matching enabled and unsupported cases. The focused output
suite (18 tests) and complete package suite (345 tests) pass; `git diff
--check` is clean.

#### M6.3b Stream-topology error handling

Stream enumeration now classifies a valid single stream, a valid multi-stream
device, and failed or malformed property queries separately. A multi-stream
result selects the AUHAL route where supported; actual query failures are
reported rather than silently treated as multistream. System Default only
falls back when direct-format validation reports an unsupported format;
Core Audio property-read errors are returned to the caller. Offline tests
cover zero, one, multiple, malformed and failed stream-count queries.
Verification: focused format tests pass normally and under Address and Thread
Sanitizers; the full package suite passes (346 tests), the Release build
succeeds, and `git diff --check` is clean.

#### M6.3b Stereo-format preference and durable recovery

Single-stream wired playback now prefers a device-advertised 44.1 kHz,
two-channel Float32 virtual format paired with a two-channel integer PCM
physical format. The app persists the original and selected virtual and
physical ASBDs in the existing per-UID recovery record before changing the
nominal rate or either stream format. Devices that do not advertise a
compatible pair retain the existing multichannel mapping path; built-in and
System Default routing are unchanged.

Recovery handles format-only changes and changes combined with the sample
rate. On stop, it restores formats without undoing a rate the user explicitly
kept at 44.1 kHz. During recovery, it restores only values still matching the
app-applied ASBDs, preserves externally changed formats or rates, and retains
the durable record if a setter or verification fails. Existing rate-only
preferences remain loadable.

Offline tests cover advertised-format selection, rate-only record behavior,
pre-recording before the sample-rate switch, apply/restore, partial changes,
setter and verification failure retries, absent/reconnected devices, external
format changes, and preserving a previously retained source rate. The tests
use the fake backend and do not touch Core Audio devices or the app's
preferences domain. The production HAL setter, actual device format lists and
CFPreferences recovery across process restart remain hardware/integration
checks.

Verification: all 356 package tests pass; the 24 focused format/rate tests
pass under AddressSanitizer and ThreadSanitizer; the Release package build
passes. No live hardware or application preferences were touched.

#### M6.3b Configuration checks and initial read-only preflight (2026-11-01)

Prepared an isolated `AudioCheck --capture-output-state` reader and
`--verify-output-state before|during|after` offline comparator. Captures use
Core Audio getters and settable-property queries only, require two stable
reads, and save versioned JSON without overwriting earlier snapshots.
HAL and file I/O run on a dedicated serial worker queue, not the main actor
or Swift cooperative executor.
They include full virtual and physical ASBDs, available formats/rates, input
streams, ownership, idle state, exposed volume/mute/clock/data-source controls,
and default route UIDs. They do not instantiate a playback engine, access a
disc, use setters, or access recovery preferences. Comparisons use the shared
pure stereo selector and match devices by UID and streams by
direction/starting channel.

Eighteen new offline tests cover parser isolation, serialization, stable
capture/read errors, idle/shared prerequisites, exact active stereo formats,
multichannel fallback, full restoration, user-kept 44.1 kHz, protected controls,
input streams, default routes, topology, stale/malformed captures and worker
error propagation. All 18 tests plus the seven existing format tests pass normally and under
AddressSanitizer and ThreadSanitizer. The Release `AudioCheck` product builds.

The initial read-only preflight found no running player/check process.
Both the HAL snapshot and independent macOS audio inventory showed the
following:

| Requested output | Initial preflight result |
|---|---|
| beyerdynamic PRO X | Not currently exposed to macOS |
| Sony USB DAC / WALKMAN | Not currently exposed to macOS |
| Samsung HDMI | Not currently exposed to macOS |

The captured wired devices were the built-in speakers (48 kHz, stereo
Float32 virtual and physical PCM) and microphone (48 kHz, mono Float32).
Both were idle and unowned; the speakers were the default output and system
output. The two saved snapshots matched in rates, both formats, ownership,
idle state, all exposed controls and default routes. The offline after
comparison passed. Supplying these idle 48 kHz samples to the during
comparison was correctly rejected; no actual during-playback sample was
taken.

This confirms unchanged state after read-only inspection, not playback
restoration or crash recovery. No CD access, audio activation, output setting,
clock selection, volume/mute change, recovery or application installation was
performed. The owner will connect PRO X, Sony and HDMI one by one before
continuing the read-only preflight. The new HAL format setter and persistent
recovery tests remain unrun.

#### M6.3b PRO X read-only preflight (2026-11-01)

The owner connected PRO X and selected MacBook Pro Speakers as the macOS
output. No player or check process was running. Fresh HAL snapshots and the
independent macOS audio inventory agreed on the connected device and default
routes:

| Check | Observed baseline |
|---|---|
| PRO X output | USB, alive, idle, unowned, one stereo output stream |
| Nominal rate | 384,000 Hz |
| Virtual format | Stereo Float32 PCM, flags `0x9`, 8 bytes/frame |
| Physical format | Stereo signed Int32 PCM, flags `0xc`, 8 bytes/frame |
| Advertised 44.1 kHz pair | Stereo Float32 virtual and Int32 physical, with the same layout as the baseline |
| Writability | Nominal rate and both stream-format properties report writable |
| PRO X input, separate UID | Idle, 48 kHz mono, Float32 virtual and Int16 physical PCM |
| Default output and system output | MacBook Pro Speakers, 48 kHz |
| Default input | MacBook Pro Microphone, 48 kHz |

The offline before-readiness check passed. A second read-only capture passed
the strict after comparison: both complete output ASBDs, rates, ownership,
running state, preferred channels, exposed volume/mute/clock/data-source
controls, input devices and default routes matched the new baseline. Each
capture also passed its internal two-read stability check.

No output activation, device setter, disc access, preference recovery or
volume/mute change occurred. This verifies readiness and unchanged state
after inspection, not successful playback, live format restoration or
restart recovery.

With this baseline, a separately approved normal restoration test would need
to restore 384 kHz and both original ASBDs, not assume an original 48 kHz rate.
Re-capture after reconnecting and before actual activation; restoration must
match that fresh baseline if the configuration has changed in the meantime.
The advertised pair differs from the current formats only in sample rate;
this device configuration alone would not exercise a channel-count or PCM
representation change. Sony USB DAC and HDMI still need their individual
read-only preflights, with MacBook Pro Speakers retained as the system output.

#### M6.3b Sony USB DAC read-only preflight (2026-11-01)

The owner connected the Sony USB DAC, enumerated by macOS as WALKMAN.
No player or check process was running. PRO X was no longer enumerated;
Sony was the only external wired output in the fresh snapshots. The HAL
reader and independent macOS audio inventory agreed:

| Check | Observed baseline |
|---|---|
| Sony WALKMAN output | USB, alive, idle, unowned, one stereo output stream |
| Nominal rate | 384,000 Hz |
| Virtual format | Stereo Float32 PCM, flags `0x9`, 8 bytes/frame |
| Physical format | Stereo signed Int32 PCM, flags `0xc`, 8 bytes/frame |
| Advertised 44.1 kHz pair | Stereo Float32 virtual and Int32 physical, with the same layout as the baseline |
| Writability | Nominal rate and both stream-format properties report writable |
| Exposed clock metadata | Domain `0`; source ID `690487296` on global, input and output scopes |
| Default output and system output | MacBook Pro Speakers, 48 kHz |
| Default input | MacBook Pro Microphone, 48 kHz |

Both captures passed their internal two-read stability checks. The offline
before-readiness check and strict after comparison passed: full ASBDs, rates,
ownership, running state, preferred channels, exposed clock/data-source
controls, built-in input/output volume and mute, and default routes matched.
Sony exposes no volume/mute properties to this reader; these snapshots cannot
verify its independent hardware volume setting.

A second capture pair three minutes later reproduced the same values and
passed both checks for UID `AppleUSBAudioEngine:Sony:WALKMAN:<redacted>:1`.
The first baseline also matched the later sample. Supplying idle samples to
the during comparison failed as expected: Sony was not running and remained
at 384 kHz, not 44.1 kHz.

No playback, setters, disc access, preference recovery or volume/mute changes
were performed. This is readiness and unchanged-state evidence only, not
verification of actual format setters, PCM delivery or restart recovery.
As with PRO X, this 384 kHz baseline already has the preferred stereo PCM
representations; the advertised pair changes only the sample rate. Any later
approved activation needs a fresh baseline, and normal restoration must match
that baseline rather than assuming 48 kHz.

PRO X and Sony read-only preflights have now passed. HDMI is the remaining
one-device preflight, with MacBook Pro Speakers kept as the system output.

#### M6.3b Samsung HDMI read-only preflight (2026-11-01)

The owner connected the Samsung HDMI output, with MacBook Pro Speakers still
the system output. No player or check process was running. The HAL snapshot
and the independent macOS audio inventory agreed:

| Check | Observed baseline |
|---|---|
| SAMSUNG output | HDMI, UID `<redacted>`, alive, idle, unowned, one 8-channel output stream |
| Nominal rate | 48,000 Hz |
| Virtual format | 8-channel Float32 PCM, flags `0x9`, 32 bytes/frame |
| Physical format | 8-channel 24-bit signed integer PCM in 4-byte containers, flags `0x4`, 32 bytes/frame |
| Advertised 44.1 kHz pair | Stereo Float32 virtual and stereo 24-bit integer physical, 8 bytes/frame |
| Writability | Nominal rate and both stream-format properties report writable |
| Exposed controls | Clock domain `1835100526` only; no volume or mute properties |
| Default output and system output | MacBook Pro Speakers, 48 kHz |
| Default input | MacBook Pro Microphone, 48 kHz |

Both captures passed their two-read stability checks. The offline
before-readiness check and strict after comparison passed: full ASBDs,
rates, ownership, running state, preferred channels, exposed controls,
built-in devices and default routes matched. Supplying the idle samples to
the during comparison failed as expected: not running, 48 kHz, and 8-channel
formats instead of the predicted stereo pair.

Unlike PRO X and Sony, HDMI's advertised pair changes the channel count
(8 to 2) and frame size as well as the rate. The earlier silent CD check on
this television used the 8-channel mapped path, before the stereo
preference existed. Selected-UID playback would now choose the stereo pair,
so a later approved test must confirm that the setters succeed, that the
television locks to 2-channel 44.1 kHz PCM, and that the original
8-channel 48 kHz formats are fully restored. The television exposes no
volume/mute properties, so its own volume is outside these snapshots.

No playback, setters, disc access, preference recovery or volume/mute changes
were performed. This is readiness and unchanged-state evidence only.

All three requested outputs (PRO X, Sony USB DAC and Samsung HDMI) have now
passed read-only preflight.

#### M6.3b Samsung HDMI silent format test (2026-11-01)

After the owner connected the Pioneer BDR-XS07U and inserted an audio CD,
the registry reported three audio tracks (14:13 total). No player or
diagnostic process was running. A fresh HDMI baseline passed the before
check: SAMSUNG was idle/unowned at 48 kHz, with its original 8-channel
Float32 virtual and 24-bit integer physical formats; MacBook Pro Speakers
remained the system output.

Ran the existing selected-UID `AudioCheck --activate-silent` path on the
SAMSUNG HDMI UID. A read-only capture during an active segment showed the
selected output running at 44.1 kHz in stereo, with the advertised
Float32-virtual / 24-bit-integer-physical pair. The offline during check
passed, including unchanged default routes, other wired-device state and
exposed controls.

All six playback segments passed: start, seek, track boundary, pause,
resume and end of disc. Each consumed the expected real disc PCM, produced
the expected independent-read checksum, reported zero underrun and
concealment, and restored the output to 48 kHz after stopping. The callback
sent zero-valued output samples. In total it consumed 30.10 seconds of PCM;
the pacing check recorded 1,886 raw reads (including checksum reference
reads), 43,603,728 bytes over 28.298 seconds. At the end, output rate,
ownership and idle state passed the engine check, and the drive reported its
original 4,233 kB/s speed restored and verified.

A final full-state capture passed the strict after check: both 8-channel
ASBDs, 48 kHz rate, ownership, idle state, preferred channels, default
routes, other captured devices and all exposed controls matched the fresh
baseline. No volume/mute or recovery preference was changed. The HDMI
device exposes no volume/mute properties, so its independent hardware
volume is outside this check.

This verifies the selected HDMI route's 8-to-2 channel format transition,
44.1 kHz configuration during actual silent CD PCM consumption, callback
checksum, and restoration to the captured 8-channel 48 kHz state. It does
not verify audible output, physical TV speaker mapping or receiver lock;
the samples sent to the output were deliberately zero. Restart recovery
and equivalent format-changing tests on PRO X and Sony remain untested.

#### M6.3b PRO X silent format test (2026-11-01)

With the same drive and three-track CD, the owner connected PRO X; MacBook
Pro Speakers remained the system output. A fresh baseline passed the before
check: PRO X idle/unowned at 384 kHz, stereo Float32 virtual and Int32
physical PCM, volume scalar `0.4374728500843048`, mute 0.

The selected-UID `AudioCheck --activate-silent` run passed all six segments
(start, seek, track boundary, pause, resume, end of disc) with matching
independent-read checksums and no underruns or concealment. It consumed
30.14 seconds of real disc PCM; output samples were zero. A read-only
capture during an active segment passed the during check: running at
44.1 kHz with the advertised stereo Float32/Int32 pair, and unchanged
volume, mute, PRO X input device, default routes and built-in devices.
Every segment restored 384 kHz, and the drive's original 4,233 kB/s speed
was restored and verified.

The final capture passed the strict after check: both ASBDs, the 384 kHz
rate, ownership, idle state, volume, mute, the PRO X input device and
default routes matched the baseline.

For PRO X the advertised pair differs only in sample rate, so this run
exercises the rate switch and restoration of a non-48 kHz original rate,
not a channel-count change. Audible output, restart recovery and the
Sony live test remain open.

#### M6.3b Sony silent format test (2026-11-01)

With the same drive and three-track CD, the owner connected the Sony USB
DAC (WALKMAN); MacBook Pro Speakers remained the system output. A fresh
baseline passed the before check: WALKMAN idle/unowned at 384 kHz, stereo
Float32 virtual and Int32 physical PCM. The device exposes no volume or
mute properties.

The selected-UID `AudioCheck --activate-silent` run passed all six segments
(start, seek, track boundary, pause, resume, end of disc) with matching
independent-read checksums and no underruns or concealment. It consumed
30.12 seconds of real disc PCM; output samples were zero. A read-only
capture during an active segment passed the during check: running at
44.1 kHz with the advertised stereo Float32/Int32 pair, with default routes
and other devices unchanged. Every segment restored 384 kHz, and the
drive's original 4,233 kB/s speed was restored and verified.

The final capture passed the strict after check: both ASBDs, the 384 kHz
rate, ownership, idle state, clock source and default routes matched the
baseline.

HDMI, PRO X and Sony have now all passed the live stereo-format test.
Audible output, receiver lock and restart/crash recovery remain open.

#### M6.3b crash-recovery tooling (2026-11-01)

Added the tooling for the remaining M6.3b restart/crash-recovery test.
`AudioCheck --verify-output-state crashed` checks that a killed silent run
left the target idle but still in the applied 44.1 kHz formats, with all
other captured state unchanged. This proves recovery has something to
restore. `AudioCheck --recover-output-rates` lists the saved
`ChangedOutputRates` records and runs the app's launch-time recovery
(`CoreAudioOutputRateControl.recoverPendingRates`). It fails if any record
remains. Two new hardware-free tests cover the phase and record parsing, and
all 20 AudioCheckTests pass. With no devices connected, a live run found no
saved records and changed nothing.

Drive read speed has no saved recovery record, so a killed run may leave the
drive at its minimum speed until the drive resets. The live crash test, with
the drive and one output reconnected, is next.

#### Source format from the disc (2026-11-01)

44.1 kHz and 16-bit are no longer fixed in code. They come from the
detected disc. A CD has no sample-rate or bit-depth field: the TOC control
bits only mark each track as audio or data, two- or four-channel, and with
or without pre-emphasis. The Red Book fixes audio at 44.1 kHz and 16 bits.
`CDTableOfContents` now exposes each track's `format` and the disc's
`audioFormat`, which is Red Book audio with the declared channel count.

- `AudioSourceFormat` (new) holds the rate, bits and channels, with
  `framesPerSector` and the display text. `Disc.format`, `DiscPCMSource` and
  `PlayerModel.sourceFormat` carry it. `Disc.sampleRate` and
  `Disc.framesPerSector` remain as the Red Book CD-DA values.
- C: `CD_SAMPLE_RATE`/`CD_CHANNELS` became `CD_DA_SAMPLE_RATE`,
  `CD_DA_BITS_PER_CHANNEL`, `CD_DA_CHANNELS` and the ring layout
  `CD_PCM_CHANNELS`. `CDSourceFormat` is new, and `CDPCMSource.format` carries
  it into C. The source rate now comes from that format, not a constant, in:
  - `cd_audio_inspect`, `cd_audio_copy_output_devices`,
    `cd_audio_match_source_rate` and `cd_audio_restore_output_rate`;
  - the pure format predicates;
  - stream format selection and the AUHAL ASBD.

  `CDDeviceInfo.supports44100` became `supportsSourceRate`. Error and
  label text is generated from the rate, so it reads exactly as before for
  44.1 kHz.
- `cd_source_format_supported` declares what the pipeline carries
  unchanged, which is 44.1 kHz, 16-bit stereo. `cd_playback_create_source`
  refuses any other format with `CD_FORMAT_UNAVAILABLE` before opening an
  output.
- Swift interfaces: `PlaybackEngine.inspectOutput(on:format:)`,
  `OutputRateControl.matchSourceRate/restoreRate(on:format:)` and
  `discoverOutputs(format:)` take the source format.
  `AudioOutputDevice.disabledReason` names the source rate. `AudioCheck`
  still verifies the CD-DA path explicitly (`AudioSourceFormat.compactDisc`).

Behaviour for audio CDs and the demo disc is unchanged, and all existing
label and message assertions pass without edits. The only intended
difference is that a disc declaring four-channel audio is refused with an
explanation instead of being played wrongly as stereo; such discs were
specified but never made. HDCD and MQA-CD are Red Book containers, so they
are still detected as 44.1 kHz, 16-bit; their roadmaps are unchanged.

New hardware-free tests cover:
- stereo, four-channel and data-only TOC detection;
- the C refusal;
- format predicates for unsupported sources;
- the format label;
- the model passing its format to inspection, discovery and the rate switch.

All 365 CDKit tests and 20 AudioCheckTests pass.

#### M6.3b crash-recovery live test (2026-11-01)

With the Pioneer drive and the same three-track CD connected, the owner
connected the Samsung HDMI output; MacBook Pro Speakers remained the system
output. The read-only preflight found no CDPlayer, AudioCheck or OpticalCheck
process and no `ChangedOutputRates` key. It found the drive, media and TOC
as before, and HDMI idle and unowned at 48 kHz with one 8-channel stream
(Float32 virtual, 24-bit integer physical). A fresh baseline passed the
before check.

A selected-UID `AudioCheck --activate-silent` run started its first segment
at 44.1 kHz stereo. While it was active, the saved record held the HDMI UID,
`originalRate` 48000, `appliedRate` 44100, and the original and applied
virtual and physical formats. The run was then killed with `kill -9`
(SIGKILL), so no stop, restore or close code ran. The record was still in
the preferences domain after the kill.

- **Crashed check: passed.** HDMI was idle and unowned, but still at
  44.1 kHz in the applied stereo pair (Float32 virtual, 24-bit integer
  physical). Default routes, the speakers' volume and mute, and the other
  devices were unchanged. Recovery therefore had a real change to undo.
- **`AudioCheck --recover-output-rates`: passed.** It listed the one HDMI
  record (original 48 kHz, applied 44.1 kHz, with stream formats), resolved
  it and cleared it. This is `CoreAudioOutputRateControl.recoverPendingRates`,
  the call `PlayerModel` makes at launch. No volume, mute, default route or
  drive setting was changed.
- **Strict after check: passed.** HDMI was back at 48 kHz with its original
  8-channel Float32 virtual and 24-bit integer physical formats. Ownership,
  idle state, clock domain, default routes and the speakers' volume and mute
  matched the baseline. The `ChangedOutputRates` key was gone and no test
  process remained.

This confirms on real hardware that the record survives a killed process
through CFPreferences and is read by a new process. It also confirms that
launch recovery restores both the rate and the stream formats, including the
2-to-8 channel change, on an output that is present.

Drive speed: the killed run had requested the minimum speed and could not
restore it. A later `OpticalCheck --read-check` reported 4,233 kB/s, the
same as before the run, and its read checks passed. As recorded in M4.10,
this drive's readback stays at 4,233 kB/s even after a 176 kB/s request, so
readback cannot show whether the slowdown persisted. The gap remains for
drives that honour the request; reconnecting the drive resets it.

Still open for M6.3b:
- the GUI app's own launch;
- audible output, receiver lock and physical channel checks.

#### M6.3b absent-output and reconnect recovery (2026-11-01)

After the owner reconnected HDMI, a fresh baseline passed: HDMI was idle at
48 kHz with the original 8-channel Float32 virtual and 24-bit integer
physical formats. A silent run was killed with SIGKILL during the seek
segment, after the start segment had completed and restored its rate. The
saved record named the HDMI UID and preserved the original 48 kHz / 8-channel
formats and applied 44.1 kHz / stereo formats. The crashed check passed.

The owner then disconnected HDMI and left it disconnected during the
recovery attempt:

- The read-only snapshot confirmed HDMI was absent; the default output
  remained MacBook Pro Speakers at 48 kHz.
- `AudioCheck --recover-output-rates` reported the missing HDMI record as
  unresolved and exited with failure, as expected. The complete saved record
  was unchanged byte-for-byte. The strict comparison of the other devices,
  defaults, exposed volume and mute passed; comparing to the original
  baseline identified only the expected HDMI disappearance.
- After the owner reconnected HDMI, it reappeared at the still-applied
  44.1 kHz stereo formats. A new read-only capture and the crashed-phase
  check passed before recovery.
- Running recovery again resolved and cleared the record. The strict after
  check passed: HDMI returned to 48 kHz and its original 8-channel formats;
  the rest of the baseline also matched. No volume, mute, default route or
  drive setting was changed. No app or test process remains.

This verifies the production recovery path keeps records for a physically
absent output and restores them after that same output reconnects. The
GUI app's own launch and audible/receiver checks remain.

#### M6.3b GUI launch recovery (2026-11-01)

Rebuilt the Release `CDPlayer.app` from the current source, then took a fresh
baseline with HDMI idle at 48 kHz and its original 8-channel Float32 virtual
and 24-bit integer physical formats. A selected-UID silent run changed HDMI
to the advertised 44.1 kHz stereo pair; the run was killed with SIGKILL while
the recovery record was present. The crashed-state check passed.

Launched the Release GUI app itself with `open -n`, without pressing Play.
`PlayerAppDelegate.applicationDidFinishLaunching` starts output monitoring,
which starts `PlayerModel`'s pending-rate recovery. No `AudioCheck
--recover-output-rates` command was run in this phase. While the app remained
open, the recovery record disappeared and the read-only snapshot showed HDMI
back at 48 kHz with the original 8-channel formats. The strict after check
passed, including the other devices, default routes and exposed controls. No
playback was started, and no recovery record remains.

This confirms recovery through the GUI app's own launch path, in addition to
the absent-output/reconnect coverage above. Still open: audible output,
receiver lock and physical channel checks.

#### Built-in output inspection during HDMI test setup (2026-11-01)

The first GUI launch showed `[ERR] Audio error` while the selected output was
MacBook Pro Speakers. The unified log identified
`Cannot inspect a built-in output's stream topology` (`!siz`, status
561211770). Built-in device discovery had tried to enumerate output streams
on the input-only built-in microphone, and treated its HAL response as a
fatal topology error.

`choose_built_in_device` now skips built-in devices reporting fewer than two
output channels before querying their output-stream topology. The focused
`OutputFormatTests` suite passed (10 tests), and the Release app rebuilt
successfully. A fresh GUI launch on this Mac then showed `CD DETECTED` with
MacBook Pro Speakers and no audio error; the matching startup error was
absent from the unified log. HDMI remained idle at 48 kHz and no volume,
mute or default route changed. No audible playback has been started.

#### M6.3b first audible HDMI playback (2026-11-01)

With the rebuilt Release app, `SelectedAudioOutputUID` set to Samsung HDMI
and no pending `ChangedOutputRates` record, the owner pressed Play and heard
the CD from the receiver. The app log shows buffering ended at 0.10 s, a
seek to about 338 s, and the pause at 340.38 s with 0 underrun frames and 0
concealed sectors. The drive again reported 4,233 kB/s after the
minimum-speed request.

The read-only capture was taken just after the pause, so it shows the
restored state rather than the 44.1 kHz stereo state during playback: HDMI
idle at 48 kHz with its 8-channel virtual/physical formats, and no record
left. A strict after check against the GUI-recovery baseline differed only
because MacBook Pro Speakers were running. Core Audio's process list showed
those speakers in use by `com.apple.WebKit.GPU` and `systemsoundserverd`,
not CDPlayer. No volume, mute or default-output change was made.

Still open: the receiver's reported input format (44.1 kHz PCM lock), a
during-playback capture, and physical left/right channel placement.

#### M6.3b live HDMI format capture (2026-11-01)

During a second audible playback, a read-only Core Audio snapshot showed the
selected Samsung HDMI output running at 44,100 Hz with a 2-channel
32-bit-float virtual format and a 2-channel 24-bit-integer physical format.
The output was marked running; the MacBook Pro speakers were idle. The strict
during-state comparison against the GUI-recovery baseline passed. No
playback, output, volume, mute or default-route setting was changed by the
capture.

This confirms the Mac's active HDMI configuration during playback, not the
receiver's displayed input format or physical left/right channel placement.
Those checks remain open.

#### M6.3b Yamaha receiver input format confirmed (2026-11-01)

During playback, the owner checked the Yamaha HTR-3066's Signal Info menu
and reported PCM, 44.1 kHz and 2 channels. This matches the earlier live
Core Audio capture for the output identified as Samsung HDMI and completes
the receiver-side input-format check.

This observation confirms the received format, not bit-for-bit sample
identity or the receiver's internal processing. Physical left/right speaker
placement remains unverified. No playback or device settings were changed
to record this result.

#### M6.3b HDMI physical channel check (2026-11-01)

The owner played the CD through Samsung HDMI and listened on the Yamaha
HTR-3066's speakers and on its headphone output. Two distinct channels were
heard, one on the left and one on the right, on both. Together with the
44.1 kHz stereo Core Audio capture and the receiver's PCM, 44.1 kHz,
2-channel Signal Info, this completes the audible HDMI verification.

The check used ordinary programme material rather than a labelled
left/right identification track, so it confirms stereo separation on both
outputs but does not formally exclude a left/right swap. The agent changed
no playback, volume, mute or output setting during the check.

#### M6.3b PRO X audible check and volume keys (2026-11-01)

With the PRO X connected and a strict before check passing (idle at
384 kHz), the owner selected the PRO X in the app and pressed Play. They
heard distinct left and right channels. A read-only capture during playback
showed the PRO X running at 44,100 Hz with a 2-channel 32-bit-float virtual
and a 2-channel 32-bit-integer physical format, its host volume and mute
unchanged.

The owner reported that volume could not be changed. The strict during
check flagged MacBook Pro Speakers: mute changed from 0 to 1 and volume
from 0.375 to 0. The unified log shows Control Center handling the built-in
keyboard's `volumeDown` hot key and setting volume and mute on
`BuiltInSpeakerDevice`, the system default output. The app's only Core
Audio setters are the nominal sample rate and the stream virtual/physical
formats; it never sets volume, mute or the default output. The volume keys
therefore adjusted the speakers rather than the PRO X, as M6.4's volume
guidance anticipated. The agent changed no volume or mute and left the
speakers as the owner set them.

After the owner paused, the read-only capture showed the PRO X idle at
384,000 Hz with its original 2-channel virtual and physical formats, and no
pending `ChangedOutputRates` record. The strict after comparison did not
pass: it found the PRO X host volume at 0.2783 instead of its 0.4375
baseline, and MacBook Pro Speakers at 0.0625 instead of 0.3750. Control
Center logs show volume-control writes to the PRO X
around 20:43:08 and the speakers around 20:41:44–20:41:47; the source of the
PRO X adjustment was not established. The system default remained
`BuiltInSpeakerDevice` in the before, during and after snapshots. CDPlayer
does not set volume or mute. No levels were restored by the agent.

#### M6.3b Sony playback observed after pause (2026-11-01)

The owner reported playing and then pausing. The app's selected output was
Sony WALKMAN, and its log recorded a pause at 36.05 s with 0 underrun frames
and 0 concealed sectors. A read-only snapshot after the pause showed the
WALKMAN idle at 384 kHz, stereo Float32 virtual / Int32 physical, with no
pending `ChangedOutputRates` record.

No before or during snapshot was taken for this playback, so it does not
establish its active format or restoration to a measured pre-play state.
The paused snapshot passed the before-state checks and is saved as the
baseline for the next run. A during-playback capture, matching after check
and owner confirmation of audible left/right channels remain open. The
agent did not start playback or change volume, mute or output settings.

#### M6.3b Sony live-format capture (2026-11-01)

On the next Sony WALKMAN playback, a read-only capture showed the output
running at 44,100 Hz with 2-channel 32-bit-float virtual and 2-channel
32-bit-integer physical formats. The strict during-state comparison against
the preceding paused baseline passed. The app log showed buffering ended at
36.11 s with 0 underrun frames.

A subsequent read-only capture still showed the WALKMAN running at 44.1 kHz;
the strict after-state check therefore failed as expected because playback
had not yet been paused. No pause log was present. A matching after-state
check and owner report of audible left/right channels remained open at that
time. The agent did not stop playback or change volume, mute or output
settings.

After the owner paused at 138.63 s, the app logged 0 underrun frames and 0
concealed sectors. The read-only paused capture showed the WALKMAN idle at
384,000 Hz with its original 2-channel Float32 virtual and Int32 physical
formats. The strict after-state comparison against the paused baseline passed,
and no pending `ChangedOutputRates` record remained.

The owner subsequently confirmed hearing both left and right channels.
This completes the Sony format, restoration and two-channel audibility
checks. The listening report does not establish labelled left/right channel
identity or bit-for-bit sample integrity.

#### CDKit regression suite and Thread Sanitizer (2026-11-01)

Ran the complete package test command in normal and Thread Sanitizer modes:

```sh
swift test --package-path Packages/CDKit
swift test --package-path Packages/CDKit --sanitize=thread
```

Both runs passed: 365 CDKit tests in 7 suites and 20 AudioCheck tests in 1
suite. No Thread Sanitizer race report occurred.

#### M6.3a WH-1000XM3 System Default live attempt (2026-11-01)

The read-only setup showed the app's saved selection as System Default and
macOS's default output as the WH-1000XM3 Bluetooth endpoint (UID
`<redacted>:output`, from its Bluetooth address), with 2 output channels at
44.1 kHz. During the
owner-started run the app window showed `CD PLAYING` and `WH-1000XM3`;
`system_profiler` and read-only output discovery still identified that
headphone as macOS's default at 44.1 kHz stereo. The player log recorded
buffering complete at 4.14 s with 0 underrun frames. No output-change error
was logged. The read-only snapshots, discovery, log and window capture are
in the session's `m63a-default-live-20261101-2110` files directory.

This confirms the selected/default identities and live output format, but
not sound reaching the headphones. The owner was unavailable when asked to
confirm audibility and switch the Mac default to another safe output while
playback continued. Consequently, dynamic following, audible output and
Bluetooth delay remain unverified. This endpoint advertises 44.1 kHz stereo,
so this run also does not exercise System Default's macOS conversion fallback
or conversion label. No default, volume or mute setting was changed by the
agent.

#### M6.3a System Default live following verified (2026-11-01)

The owner later resumed playback and reported hearing WH-1000XM3. While it
continued, the owner used the macOS Sound menu to switch the output to the
MacBook Pro Speakers, then back to WH-1000XM3, and reported hearing the audio
in every case. The agent did not change any default, volume or mute setting.

The player log shows each change being followed through the System Default
path, without an output-change pause:

| Time | Log |
| --- | --- |
| 21:21:08.698 | Playback moved to the new default output at 166.01 s: 0 underrun frames; 0 concealed sectors |
| 21:21:09.164 | Default output changed; CD playback moved to the new default output |
| 21:21:09.595 | Buffering ended at 166.10 s; 0 underrun frames so far |
| 21:21:15.529 | Playback moved to the new default output at 171.21 s: 0 underrun frames; 0 concealed sectors |
| 21:21:15.690 | Default output changed; CD playback moved to the new default output |
| 21:21:16.119 | Buffering ended at 171.22 s; 0 underrun frames so far |
| 21:21:19.827 | Playback paused at 174.92 s: 0 underrun frames; 0 concealed sectors |

The final pause used the ordinary Play/Pause path. Pauses caused by an
output change or a disappeared output log different messages. The window then
showed `CD PAUSED`, track 01 at 02:54 and `WH-1000XM3`.

After the pause, a read-only wired-device snapshot matched the setup snapshot
for every device, including the MacBook Pro Speakers at 48 kHz with volume
0.25 and mute off. The only difference was the system-default UID, now
`<redacted>:output`. The strict `after` check against the setup
snapshot therefore failed only on the owner's intentional default-output,
system-effects output and default-input changes. macOS also made the
headset microphone the default input at 16 kHz, while WH-1000XM3 output
remained at 44.1 kHz stereo. `ChangedOutputRates` was absent, so no
rate-recovery record remained. The speakers' rate during their brief use was
not captured.

This verifies audible System Default playback over Bluetooth and dynamic
following of an owner-chosen default change in both directions, keeping the
playback position. It does not verify Bluetooth delay, disconnect handling,
AirPlay, the conversion fallback or bit-for-bit delivery.

#### M6.3a Bluetooth disconnect verified (2026-11-01)

With System Default still selected, the owner resumed playback on
WH-1000XM3 and then turned the headphones off. The owner reported that the
app displayed "OUTPUT LOST". The agent did not change any default, volume or
mute setting.

| Time | Log |
| --- | --- |
| 21:30:32.312 | Holding off idle sleep while the CD plays |
| 21:30:35.982 | Buffering ended at 175.02 s; 0 underrun frames so far |
| 21:30:43.064 | Cannot inspect the audio output: macOS has no default audio output |
| 21:30:43.142 | Playback paused because the output disappeared at 182.04 s: 0 underrun frames; 0 concealed sectors |
| 21:30:43.142 | Idle sleep allowed again |
| 21:30:43.142 | Default output disappeared; CD playback paused |

The pause came from the disappeared-output branch of the default-following
path. No "moved to the new default output" message appeared, so the app did
not resume on the speakers that macOS chose next. The inspection error is
logged by the background `refreshOutput()` during the brief interval when
macOS had no default output; it is not shown to the user, and a later
inspection found the speakers. The window then showed `OUTPUT LOST`, track
01 at 03:02 and `MacBook Pro Speakers`.

Afterwards, macOS's default output was again the MacBook Pro Speakers, as
it was at setup. A read-only wired snapshot matched the setup snapshot
exactly, and the strict check passed:

```text
AudioCheck --verify-output-state after wired-before-setup.json wired-after-disconnect.json --output-uid BuiltInSpeakerDevice
PASS: after configuration checks for UID BuiltInSpeakerDevice.
```

`ChangedOutputRates` was absent, so no rate-recovery record remained, and the
saved selection was still System Default. This verifies the Bluetooth
disconnect case. The live wired-default disconnect is recorded below.

#### Live move from PRO X to System Default (2026-11-01)

To prepare the wired-default unplug test, the owner chose the PRO X in
CDPlayer's selector. Before playback, a read-only inspection showed the PRO
X at 384 kHz stereo, not running, with no exclusive-use owner, and
`SelectedAudioOutputUID` set to it. macOS's default output remained the
MacBook Pro Speakers. The owner played the CD on the PRO X and then chose
System Default in CDPlayer's selector, reporting that the audio continued.
The agent did not change any default, volume or mute setting.

| Time | Log |
| --- | --- |
| 21:34:24.759 | Holding off idle sleep while the CD plays |
| 21:34:27.497 | Buffering ended at 182.09 s; 0 underrun frames so far |
| 21:35:09.326 | Playback moved to another output at 223.69 s: 0 underrun frames; 0 concealed sectors |
| 21:35:10.209 | Buffering ended at 223.78 s; 0 underrun frames so far |
| 21:35:11.985 | Playback paused at 225.29 s: 0 underrun frames; 0 concealed sectors |

This was the user-selected move path, not the default-following path. The
saved selection changed to `SelectedAudioOutputIsSystemDefault = 1`, and the
window showed `CD PAUSED`, track 01 at 03:45 and `MacBook Pro Speakers`.
After the pause, a read-only wired snapshot matched the setup snapshot
exactly. The strict `after` checks passed for both the PRO X and the MacBook
Pro Speakers. `ChangedOutputRates` was absent.

This verifies a live move from a selected wired output to System Default,
with the PRO X's rate restored. No during-state capture was taken, so neither
the PRO X's 44.1 kHz rate before the move nor the speakers' rate after it was
recorded for this run. Because macOS's default was still the speakers, this
was not the wired-default unplug setup.

#### PRO X as System Default, before the unplug (2026-11-01)

The owner then chose the PRO X in the macOS Sound menu, left CDPlayer on
System Default and started playback at 225.34 s with 0 underrun frames. A
read-only capture during playback showed the PRO X as macOS's default
output, running at 44.1 kHz stereo, with 32-bit float virtual and 32-bit
integer physical formats, and no exclusive-use owner. The strict `during`
check failed only on the owner's intentional system-default and
system-effects output changes. A text diff with the setup snapshot showed
only the default UID and the PRO X's rate, formats and running state; PRO X
volume (0.2783) and mute were unchanged. As expected during playback,
`ChangedOutputRates` held one PRO X record: applied 44.1 kHz, original
384 kHz.

The owner was unavailable for the unplug step at first.

#### PRO X wired-default unplug verified (2026-11-01)

The owner then unplugged the PRO X's USB cable during playback, reporting
that the audio stopped and CDPlayer stayed on System Default. The agent did
not change any default, volume or mute setting.

| Time | Log |
| --- | --- |
| 21:40:51.753 | Cannot inspect the audio output: macOS has no default audio output |
| 21:40:51.784 | Playback paused because the output disappeared at 343.24 s: 0 underrun frames; 0 concealed sectors |
| 21:40:51.784 | Idle sleep allowed again |
| 21:40:51.784 | Default output disappeared; CD playback paused |

As with the Bluetooth disconnect, the pause came from the disappeared-output
branch and the app did not resume on the speakers, which macOS chose as the
new default. The window showed `OUTPUT LOST`, track 02 at 00:05 and `MacBook
Pro Speakers`, and the saved selection remained System Default.

With the PRO X absent, `ChangedOutputRates` retained its record (applied
44.1 kHz, original 384 kHz), as required for later restoration. A read-only
wired snapshot differed from the setup snapshot only by the absence of the
PRO X's output and input devices; the speakers, WALKMAN, microphone and
system default (speakers) matched it exactly.

#### PRO X reconnect while paused (2026-11-01)

The owner plugged the PRO X back in and left CDPlayer paused, without
changing the Sound menu, volume or mute. macOS made the PRO X its default
output again on its own. CDPlayer did not resume: no player messages were
logged after the pause, and the window still showed `OUTPUT LOST`, track 02
at 00:05, now with `beyerdynamic PRO X` in the selector. The saved selection
remained System Default.

`ChangedOutputRates` was gone. A read-only wired snapshot matched the setup
snapshot exactly apart from the system default UID: the PRO X was idle at
its original 384 kHz virtual and physical formats, with volume 0.2783 and
mute off, and its input device and every other device were unchanged. The
strict `after` checks for the PRO X and speakers failed only on the
system-default and system-effects output change that macOS made on
reconnection.

The app clears the record only after its recovery finds the original rate
restored, so the reconnected PRO X's rate was recovered. Successful recovery
is not logged, so this run cannot tell whether CDPlayer set 384 kHz or macOS
had already reset the reconnected device to it. Either way, the M6.4
expectation was met: pause, keep the record while the device is absent,
restore it on reconnection, and do not resume automatically.

#### Live wired output handoff: PRO X and WALKMAN (2026-11-01)

For the handoff check, a fresh read-only snapshot showed both wired outputs
idle at 384 kHz. macOS's default output was the PRO X. The owner started
playback audibly on the PRO X. Although the owner was asked to select PRO X
directly in CDPlayer, the persisted selection remained
`SelectedAudioOutputIsSystemDefault = 1`; the first handoff therefore began
on the System Default route, which was physically the PRO X. The owner then
selected WALKMAN in CDPlayer and reported that playback continued audibly.

| Time | Log |
| --- | --- |
| 21:47:39.296 | Buffering ended at 343.26 s; 0 underrun frames so far |
| 21:49:09.283 | Playback moved to another output at 433.11 s: 0 underrun frames; 0 concealed sectors |
| 21:49:10.128 | Buffering ended at 433.22 s; 0 underrun frames so far |
| 21:50:45.338 | Playback moved to another output at 528.37 s: 0 underrun frames; 0 concealed sectors |
| 21:50:46.753 | Buffering ended at 528.47 s; 0 underrun frames so far |
| 21:51:19.059 | Playback paused at 560.53 s: 0 underrun frames; 0 concealed sectors |

After confirming playback on WALKMAN, the owner selected the PRO X directly
in CDPlayer and reported audible playback there. The second handoff was from
the selected WALKMAN UID to the selected PRO X UID. It returned at the same
playback position, with no underruns or concealed sectors. Read-only captures
showed each active device running at 44.1 kHz stereo, while the inactive
device returned to 384 kHz.

After the owner paused, a wired snapshot matched the pre-test snapshot for
all listed devices, formats, volume and mute controls. Both devices were
idle at their original 384 kHz. `ChangedOutputRates` was absent and
`SelectedAudioOutputUID` was the PRO X. The strict per-device `after` checks
reported only that the default input had changed; macOS had selected the PRO
X microphone along with its output. No input or volume setting was changed
by the agent.

This verifies audible playback handoff between the two wired outputs,
including an explicit selected WALKMAN-to-PRO-X move. The first leg began
from System Default (physically the PRO X), rather than from an explicitly
selected PRO X UID.

#### Subjective WH-1000XM3 delay check (2026-11-01)

The owner powered on WH-1000XM3, selected it as macOS's default output, left
CDPlayer on System Default and started playback. Read-only output discovery
and `system_profiler` showed WH-1000XM3 as the default at 44.1 kHz stereo;
the app showed `CD PLAYING` and WH-1000XM3. The playback log reported
buffering complete with 0 underrun frames.

The owner reported no noticeable offset between the elapsed-time display and
the sound, and no sound continuing after the display changed to `CD PAUSED`.
The pause log recorded 622.65 s, with 0 underrun frames and 0 concealed
sectors. No output, volume or mute settings were changed by the agent.

This is a subjective listening check only; it does not quantify Bluetooth
latency. The endpoint advertised 44.1 kHz stereo, so this run did not test
the conversion path or its label.

#### N-50 AirPlay preflight (2026-11-01)

While CDPlayer was paused with System Default selected, read-only discovery
identified `N-50 (AirPlay)` as macOS's default output at 44.1 kHz stereo.
The owner then reported that the Sound menu kept loading and they could not
select N-50. The player log nevertheless recorded playback beginning at
643.39 s with 0 underrun frames, followed by a default-output change:

| Time | Log |
| --- | --- |
| 22:49:28.357 | Buffering ended at 643.39 s; 0 underrun frames so far |
| 22:50:32.167 | Playback moved to the new default output at 703.57 s: 0 underrun frames; 0 concealed sectors |
| 22:50:32.321 | Default output changed; CD playback moved to the new default output |
| 22:50:32.741 | Buffering ended at 703.66 s; 0 underrun frames so far |
| 22:50:42.625 | Playback paused at 713.52 s: 0 underrun frames; 0 concealed sectors |

Afterward, read-only discovery still found N-50 at 44.1 kHz, but macOS's
default output was WH-1000XM3. The app remained on System Default and was
paused at track 03, 01:56. The wired snapshot differed only in the system
default UID. No user confirmation established that audio was heard from the
N-50, so this is not an audible AirPlay pass. Stable selection, audibility,
the app's displayed rate/label and AirPlay delay remain unverified. The agent
did not change output, volume or mute settings.

#### AirPlay to another Mac (2026-11-01)

From the paused N-50 attempt, the owner chose another Mac on the network as
the AirPlay receiver and started playback with CDPlayer on System Default.
The owner heard the CD on that Mac. Read-only discovery and
`system_profiler` showed:

- macOS's default output was an AirPlay device named `AirPlay`, UID
  `<redacted>-Audio`, at 44.1 kHz
  stereo, with native 44.1 kHz support and no hog owner;
- the system-effects output was MacBook Pro Speakers, and the default input
  was MacBook Pro Microphone;
- N-50's AirPlay output was still listed, at 44.1 kHz.

During playback the window showed `CD PLAYING`, `44.1 kHz / 16-bit source`,
and `AirPlay` in the selector, with no conversion label. The app's
preferences kept `SelectedAudioOutputIsSystemDefault = 1` and held no
`ChangedOutputRates` record.

| Time | Log |
| --- | --- |
| 22:55:54.122 | Holding off idle sleep while the CD plays |
| 22:55:56.920 | Raw read at LBA 53514 x8, C2 true, succeeded after 3178 ms |
| 22:55:57.390 | Buffering ended at 713.62 s; 0 underrun frames so far |
| 22:56:04.526 | Raw read at LBA 56153 x9, C2 true, succeeded after 697 ms |
| 22:58:05.216 | Playback paused at 841.39 s: 0 underrun frames; 0 concealed sectors |

The two slow raw reads were absorbed by the buffer. The owner reported no
noticeable offset between the elapsed-time display and the sound, and no
sound continuing after the display changed to `CD PAUSED` (track 03, 04:04).

After pause, a wired snapshot was compared with the N-50 baseline. The strict
`after` check cannot use the AirPlay UID, because the wired snapshot excludes
it. Using the Pioneer UID, the check failed only on the system default
output, system-effects output and default input. The owner changed all three
through macOS. Every wired device in the snapshot (Pioneer USB, MacBook Pro
Speakers, MacBook Pro Microphone) otherwise matched, ignoring CoreAudio
object and stream IDs: rate, formats, volume and mute were unchanged. The
Pioneer's object ID had changed, showing it was re-enumerated between the
captures. No rate-recovery record remained.

This verifies audible AirPlay playback through System Default to a Mac
receiver. The local AirPlay device's 44.1 kHz rate does not describe the
network stream or the receiving Mac's output, so this is not evidence of
bit-perfect delivery. Latency was not measured, and the endpoint advertised
44.1 kHz stereo, so the conversion path and its label were not tested. The
agent did not change output, volume or mute settings.

#### AirPlay receiver sleep during playback (2026-11-01)

The owner selected the other Mac as the AirPlay receiver, started CD playback
on System Default, confirmed audio, and then put the receiving Mac to sleep.
The owner reported that CDPlayer continued playing but the audio stopped.
CDPlayer did not show `OUTPUT LOST` and did not switch to another output.

The post-test read-only capture still found the local AirPlay output as the
system default at 44.1 kHz stereo, and `system_profiler` still listed it as
the default AirPlay output. The app preferences remained on System Default
and contained no `ChangedOutputRates` record. The player log recorded no
output-change or disappeared-output event. Relevant log entries:

| Time | Log |
| --- | --- |
| 23:18:10.530 | Buffering ended at 841.49 s; 0 underrun frames so far |
| 23:18:22.940 | Playback ended at 853.76 s: 0 underrun frames; 0 concealed sectors |
| 23:18:33.796 | Buffering ended at 0.09 s; 0 underrun frames so far |
| 23:20:24.645 | Playback paused at 110.90 s: 0 underrun frames; 0 concealed sectors |

After the receiver became silent, the AirPlay route remained present to
CoreAudio, so the app had no observed route disappearance on which to trigger
its existing output-loss pause. The owner later paused CDPlayer manually.
This test therefore does not establish that the receiver sent a disconnect
notification; it shows that sleeping the receiver can leave playback running
silently while macOS still reports its AirPlay output as default. This is a
failure of the desired user-visible behavior for this scenario, unlike the
verified Bluetooth and wired disconnect tests. Leaving the network or
turning AirPlay off on the receiver remains untested. The agent did not
change output, volume or mute settings.

#### AirPlay acceptance and the stale N-50 entry (2026-11-01)

The owner turned the N-50 off, but "N-50" stayed in macOS's Sound menu.
Read-only checks at 23:02, before any network change, found:

- Bonjour still listed `<redacted>@N-50` under `_raop._tcp`, but resolving
  it got no reply within 8 seconds;
- the N-50's LAN address did not answer ping;
- CoreAudio still had `N-50 (AirPlay)` at 44.1 kHz.

The owner then disconnected and reconnected Wi-Fi. At 23:09:

- Bonjour no longer listed the N-50, and its ARP entry was gone;
- CoreAudio and `system_profiler` still listed `N-50 (AirPlay)` at
  44.1 kHz.

The stale entry is held by macOS's audio system, not the network or
CDPlayer. A restart or an audio-service restart is expected to clear it. The
agent did neither.

In both browses the N-50 advertised only `_raop._tcp`, the service for the
original AirPlay. The receiving Mac advertised both `_raop._tcp` and
`_airplay._tcp`.

The owner chose to accept the AirPlay-to-Mac result in place of the N-50.
On System Default, CDPlayer writes to the local macOS AirPlay output and
never talks to the receiver. The Mac test therefore covered the app's
AirPlay path: route following, the 44.1 kHz stereo local format, no
conversion label, clean pause, untouched wired devices and no rate record.
Retrying the N-50 is optional. It would add a receiver that supports only the
original AirPlay, its front-panel input rate and wake from network standby.
Still untested: measured AirPlay latency.

#### AirPlay receiver Wi-Fi disconnected during playback (2026-11-01)

The owner restored audible AirPlay playback to the other Mac on System
Default, then turned off Wi-Fi on the receiving Mac. A read-only monitor
sampled AudioCheck output discovery while playback continued. It showed
AirPlay as macOS's default at 23:24:08 and subsequent samples through
23:25:21. At 23:25:25, the default was MacBook Pro Speakers and the AirPlay
route was no longer listed. The N-50's stale AirPlay entry remained listed.

The player log recorded:

| Time | Log |
| --- | --- |
| 23:23:18.288 | Buffering ended at 110.94 s; 0 underrun frames so far |
| 23:25:24.200 | Playback paused because the output disappeared at 236.76 s: 0 underrun frames; 0 concealed sectors |
| 23:25:24.200 | Default output disappeared; CD playback paused. |

The owner reported `OUTPUT LOST`. The captured window showed the status and
MacBook Pro Speakers in the selector. CDPlayer stayed paused and did not
resume on the new default. The preferences remained on System Default and no
`ChangedOutputRates` record was present. macOS took roughly a minute after
the Wi-Fi disconnect before dropping the AirPlay route; the app paused as
soon as the route disappeared. This verifies the receiver-disconnect path
when the AirPlay endpoint is removed, in contrast to the sleep test where
macOS kept the remote endpoint listed and playback continued silently.
The agent did not change output, volume or mute settings.

After Wi-Fi was restored, the owner initially reported that the receiver had
not returned to the Sound menu. A Bonjour browse at 23:31:45 showed the
receiving Mac advertising both `_raop._tcp` and `_airplay._tcp` under a name
other than the local computer's, confirming it was the other Mac. The owner
then confirmed the receiver was visible in the Sound menu and selected it.
AudioCheck showed the AirPlay output as the system
default at 44.1 kHz stereo. The player preferences remained on System
Default, and the player log recorded no new playback transition. The owner
reported that CDPlayer remained paused with `OUTPUT LOST`; the captured
window confirmed the status, the AirPlay selector and the Play button.
Restoring and selecting the AirPlay route did not auto-resume playback. The
owner then pressed Play manually and reported audible sound on the receiving
Mac.
AudioCheck still showed AirPlay as the system default at 44.1 kHz stereo;
the app remained on System Default with no `ChangedOutputRates` record. The
window showed `CD PLAYING`, `AirPlay` and no `OUTPUT LOST`. The player log
recorded buffering complete at 236.79 s with 0 underrun frames.

#### System Default conversion through Samsung HDMI (2026-11-01)

With CDPlayer paused on System Default, the owner selected Samsung HDMI as
macOS's default output. Read-only preflight showed the output idle at 48 kHz
with one 8-channel stream. It advertises a 44.1 kHz stereo pair, but its
active default stream was 8-channel, which requires macOS to convert the
stereo CD channel layout for this route.

The owner pressed Play and reported audible audio from the receiver and the
best-effort/macOS-conversion indication. During playback, AudioCheck found
the Samsung output running as the system default at 44.1 kHz, 8 channels,
Float32 virtual and 24-bit integer physical. The app remained on System
Default. `ChangedOutputRates` recorded the temporary rate change from 48 kHz
to 44.1 kHz. The player log recorded buffering complete at 295.40 s with
0 underrun frames.

The owner paused at 366.67 s, with 0 underrun frames and 0 concealed sectors.
AudioCheck confirmed restoration to the original 48 kHz, 8-channel virtual
Float32 and physical 24-bit integer formats. The strict `after` comparison
against the preflight snapshot passed; the recovery record was cleared.
This verifies audible playback through System Default with macOS converting
the stereo CD layout to the 8-channel HDMI route, plus rate restoration. It
does not establish bit-perfect delivery or channel placement. The agent did
not change output, volume or mute settings.

#### AirPlay display-clock latency support

The owner reported that AirPlay sound trailed the displayed time by about
two seconds. A Core Audio check found stream ID 121 reporting 88,200 frames
of `kAudioStreamPropertyLatency` at 44.1 kHz, equivalent to 2.0 seconds.
Device-level latency and safety-offset properties were unavailable. This
driver-reported value corroborates the listening observation but is not a
direct acoustic measurement.

CDDeviceInfo and OutputInfo now carry stream latency when Core Audio provides
it. The player subtracts that latency from the displayed track/time and
clamps the display at the playback or seek start, while retaining the
unadjusted source-frame cursor for playback and resume. Pause/resume, seeking,
and output restarts preserve or re-anchor the display clock without changing
that cursor. A focused System Default test verifies the 2-second offset,
startup clamping, pause/resume stability, and unchanged cursor. Live
confirmation on 2026-11-02: after launching the rebuilt app, the owner
confirmed that the displayed time tracked the receiving Mac's audio and
remained stable after Pause. This confirms the user-visible result
qualitatively; it
does not turn Core Audio's reported latency into an acoustic measurement.

#### WH-1000XM3 Bluetooth display check

The owner reported audible playback through WH-1000XM3 with the headphones
selected as macOS's System Default output. The owner confirmed that the
display aligned with the audio and stayed stable after Pause.

`AudioCheck --system-default`, a new read-only inspection that prints the
default output's stream latency, reported 0 frames at 44.1 kHz during the
audible check. It also reported `Already running: false`, so the latency
reading is inconclusive rather than evidence of zero acoustic latency. The
tool made no audio or disc access and changed no settings.

#### PRO X crash/restart recovery (2026-11-02)

The owner approved a PRO X crash/restart test and accepted the known
drive-speed caveat. The Pioneer BDR-XS07U had an unmounted audio CD in its
tray. CDPlayer was quit normally before a fresh output-state capture. The
baseline passed for the PRO X at 384 kHz, stereo Float32 virtual / 32-bit
integer physical, idle and unowned; no `ChangedOutputRates` record existed.

`AudioCheck --output-uid "<PRO X UID>" --disc 4295222174 --activate-silent
--observe 0 120` began a silent observation. An active snapshot showed the
PRO X at 44.1 kHz stereo, running and unowned, and the during-state comparison
passed. The saved record contained the original 384 kHz formats and applied
44.1 kHz formats. The exact AudioCheck process was then killed with SIGKILL.
The crashed-state capture passed: the PRO X was idle at 44.1 kHz stereo, the
record remained present, and the comparator found no unrelated changes.

The rebuilt GUI app was launched fresh. It restored the PRO X to 384 kHz,
cleared the record, and left the device idle. The strict after-state
comparison passed, including the original formats and exposed volume/mute.
The kill bypassed drive-session cleanup; as approved, no post-test drive-speed
check or physical reconnect was performed, so restoration of the drive's
requested minimum speed remains unverified.

#### Sony WALKMAN crash/restart recovery (2026-11-02)

The owner approved repeating the crash/restart test on the connected Sony
WALKMAN. The Pioneer BDR-XS07U and the same audio CD were present. CDPlayer
was quit normally; the fresh baseline passed with the WALKMAN idle at 384 kHz,
stereo Float32 virtual / 32-bit integer physical, and no recovery record.
The advertised stereo pair was 44.1 kHz in both streams.

`AudioCheck --output-uid "<Sony WALKMAN UID>" --disc 4295222174
--activate-silent --observe 0 120` started. It reported the drive and media
IDs, began at track 1 / LBA 0, and produced its first zero-valued audio at
0:00.05. The active snapshot passed at 44.1 kHz stereo, with Float32 virtual
and 32-bit integer physical formats; the saved record retained the original
384 kHz formats. After confirming the record, the exact AudioCheck process
was killed with SIGKILL.

The crashed-state snapshot passed: the WALKMAN was idle at 44.1 kHz stereo,
the record remained present, and no unrelated captured state changed. On
fresh GUI app launch, recovery restored the WALKMAN to 384 kHz, cleared the
record, and left it idle. The strict after-state comparison passed against
the fresh baseline. The kill bypassed drive-session cleanup; post-test drive
speed was not checked, so restoration of the requested minimum speed remains
unverified.

#### M6.4 decisions and gap analysis (2026-11-02)

The owner confirmed the M6.4 decisions (roadmap decisions 14–18):

- **Lost-output notice:** `OUTPUT LOST` on the status line in the warning
  colour, with the output named in the selector's tooltip, whenever the
  saved output is missing at launch or disappears while stopped, paused or
  playing. Play, another output choice or reconnection clears it. The
  output's name is now saved with its UID so a launch can name it.
  Amended on 2026-11-04: Play on the fallback, or choosing it, saves it; see
  "Output lost at every launch".
- **Volume:** "volume on device" in the menu entry and tooltip only, with
  no status-line warning. This replaces the earlier first-selection status
  warning. The app never changes volume or mute.
- **Volume-keys hint:** when a directly selected output is not the macOS
  default, the tooltip names the output the volume keys control. This
  follows the PRO X observation that the volume keys changed MacBook Pro
  Speakers.
- **HDMI/DisplayPort lead-in:** always, on every start, at least 1 second
  of silence before the first CD sample. It overlaps start-up buffering and
  is excluded from underruns, the clock and the PCM checksum.
- **Order:** code and offline tests first, hardware tests after.

The gap analysis found one behavioural bug. When a directly selected wired
output disappears during playback, the 10 Hz snapshot poll receives
`CD_OUTPUT_UNAVAILABLE` and pauses through the output-change path without
recording the lost output. The status therefore showed `CD PAUSED` rather
than `OUTPUT LOST`. Only the System Default path and the device-list path
set the notice. Exclusive use by another app reports the same error code but
leaves the device connected, so the fix checks connectivity before naming an
output as lost.

#### M6.4 code and offline tests (2026-11-02)

Implemented in the agreed order, code and offline tests before any hardware
step.

- **Lost-output notice (decision 14).** The selected device's name is saved
  with its UID, replaced when another device is chosen and cleared for
  System Default.
  `OUTPUT LOST` appears when the saved output is missing at launch, leaves the
  output list while stopped or paused, or fails during playback while no
  longer listed. A failed output that is still listed, such as one taken for
  exclusive use by another app, stays a plain pause. The notice outranks the
  disc statuses because the user must act on it; only an error outranks it.
  Play, another output choice or the output's return clears it, and after
  Play on the fallback it is not raised again. Since 2026-11-04, that Play
  also saves the fallback, so later launches don't raise it either. An
  output without a UID, as in the physical-drive fixtures, is never named
  as lost. This fixes the gap
  found in the analysis: a selected wired output unplugged during playback
  now shows `OUTPUT LOST`, not `CD PAUSED`.
- **Volume guidance (decisions 15 and 16).** The C core reports
  `hasVolumeControl` when an output has a settable volume on its main or
  first two channels. Outputs without one say "volume on device" in the menu
  entry, tooltip and accessibility value, never on the status line. When a
  directly selected output is not the macOS default, the tooltip names the
  output that the volume keys control. The tooltip is now built from
  sentences, which also removed a doubled full stop. `AudioCheck
  --list-outputs` prints the host-volume flag. A read-only run listed AirPlay
  to another Mac, the N-50's AirPlay output, MacBook Pro Speakers and two
  conferencing virtual devices, all with host volume; the WALKMAN and PRO X
  were not connected.
- **HDMI and DisplayPort lead-in (decision 17).** `cd_output_lead_in_frames`
  gives 1 second of frames (`CD_PLAYBACK_LEAD_IN_MILLISECONDS`) for HDMI and
  DisplayPort and none for other transports. Start sets it for the output it
  chooses, and every prepare (Play, resume, seek, track change or a move)
  restarts it. The callback writes zeros and counts down only once output is
  enabled, rounded up to whole callback buffers. It ends start-up buffering
  when the ring is ready, but does not read the ring, advance the clock,
  count an underrun or change the PCM checksum. A mutation check, with the
  prepare reset disabled, made the new render test fail.
- **App tests.** `Tests/AppTests/OutputStatusLineTests.swift` still used the
  pre-refactor `supports44100` and format-less protocol methods and no
  longer compiled; its fixtures were updated to the current API.

Validation:

- `swift test --package-path Packages/CDKit`: 377 CDKit tests in 7 suites and
  20 AudioCheck tests passed, normally and under Thread Sanitizer.
- `xcodebuild … build-for-testing` succeeded, and `test-without-building` ran
  the six app view tests with no failures.
- `git diff --check` was clean.

The hardware tests are listed in the
[development guide](DEVELOPMENT.md#external-outputs-and-receivers).

#### Volume keys for a directly chosen output: decision 19 (2026-11-02)

With the PRO X chosen directly and MacBook Pro Speakers as the macOS
default, the volume keys changed the speakers, not the headphones. The owner
asked for the system volume to match the device. Three options were offered:
make the PRO X the macOS default (no code), mirror the default's volume onto
the chosen output, or capture the volume keys with an event tap. The owner
chose the mirror, including mute, without restoring the default's level
afterwards. This is roadmap decision 19, and it replaces "the app never
changes volume or mute" from decision 15.

- **When:** only while the CD plays on a directly chosen output that is not
  the macOS default and both outputs have a host volume control. Not on
  System Default, not while stopped or paused, and not for an output whose
  volume is on the device.
- **Start:** the default's level is set to the chosen output's level, never
  the reverse, so the headphones do not jump when Play is pressed. Mute is
  not aligned, so starting never mutes or unmutes anything.
- **While playing:** a change on either side is copied to the other, and the
  default wins when both change at once. Copying back from the chosen output
  keeps the next key press from jumping when its level was changed
  elsewhere, for example in Audio MIDI Setup. Both sides are read back after
  each write, so driver rounding cannot start a loop.
- **Level property:** `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`
  through `AudioObjectGetPropertyData`, the control the volume keys move. The
  `AudioHardwareService…` functions are deprecated, but the HAL serves the
  property directly. A read-only probe found it settable on the PRO X
  (0.278), MacBook Pro Speakers (0.0625, muted) and two conferencing virtual
  devices. The N-50's AirPlay output reported −32.3, outside 0–1, so a level
  outside that range counts as no control.
- **Known effect:** if the default was muted when mirroring started, the
  first mute-key press only unmutes it; the next press mutes both.

#### Volume-key mirror code and offline tests (2026-11-02)

- **Pair:** `PlayerModel` sends a `VolumeMirrorPair` (default UID, output
  UID), or nil, to a `VolumeMirroring` dependency whenever the state, the
  output, the output list or the playback target changes, and nil at
  shutdown. A pair needs the CD playing on a direct target, an output with a
  non-empty UID that is listed with host volume, and a listed default with
  host volume that is a different device. The System Default guard matters:
  while playback follows a new default, `output` briefly still names the old
  one.
- **Rules:** `VolumeMirrorSync` holds them without Core Audio. Setting a pair
  writes the output's level to the default and leaves mute alone. After
  that, a level or mute change on one side is copied to the other, with the
  default winning when both changed. Mute is copied only when both sides
  have a mute control. Each pass reads both sides back, so driver rounding
  cannot start a loop. A write that a driver applies late is recognised as
  its own echo only when that side alone moved towards the pending level, so
  a quarter-step key press straight after alignment is still copied.
- **Core Audio:** `CoreAudioVolumeMirror` works on a private serial queue. It
  listens for the virtual main volume, the element 0–2 volume scalars and
  mute on both devices. `CoreAudioVolumeControls` resolves each UID on every
  call, so an unplugged device reads as nil and nothing is written. Levels
  outside 0–1 count as no control, and a device counts as muted only when
  all its mute controls are on.
- **Tooltip:** when the chosen direct output is not the default and both
  have host volume, the output selector says "While playing, volume keys
  control <output> and <default>".
- **Tests:** 12 `VolumeMirrorTests` use fake controls with rounding and late
  writes, covering: the alignment direction; key presses, including a quarter
  step right after alignment; copying back; the default winning; mute in
  both directions; a side without mute; rounding; late writes; unusable
  levels; stopping; a new default; and unknown UIDs. Two `PlayerModel` tests
  record the pairs through play, pause, resume, a default change to AirPods,
  the PRO X becoming the default, a return to the speakers and shutdown, and
  check that nothing is mirrored on System Default or without host volume.
  Turning off the pending-write clear failed four rules tests, and removing
  the System Default guard failed the `PlayerModel` test; both were restored.

Validation:

- `swift test --package-path Packages/CDKit`: 391 CDKit tests and
  20 AudioCheck tests passed, normally and under Thread Sanitizer, with no
  sanitizer warnings.
- `xcodebuild … build-for-testing` succeeded, and `test-without-building` ran
  the six app view tests with no failures.

The hardware check is item 7 in the
[development guide](DEVELOPMENT.md#external-outputs-and-receivers).

#### Volume-key mirror on hardware: check 7 and a race fix (2026-11-02)

Setup: Pioneer BDR-XS07U with the 3-track CD, beyerdynamic PRO X chosen
directly, MacBook Pro Speakers as the macOS default, WALKMAN also connected.
A read-only monitor polled both outputs' virtual main volume and mute every
50 ms. `AudioCheck --list-outputs` reported host volume on the PRO X and none
on the WALKMAN (check 4).

First run:

- **Play:** the PRO X stayed at 0.2783 and the speakers moved from 0.0625 to
  0.2783.
- **Volume keys:** each key press on the speakers reached the PRO X within
  about 60 ms. The PRO X rounds to its own steps, for example 0.25 to 0.2540
  and 0.375 to 0.3772, and nothing was copied back.
- **Mute:** pressing mute twice muted, then unmuted, both outputs.
- **Pause:** a volume-key press changed only the speakers.
- **Fault:** after a fast drag in Audio MIDI Setup, the speakers stayed at
  0.2158 while the PRO X ended at 0.2232.

Cause: after each write, `VolumeMirrorSync` re-read both outputs and recorded
them. A PRO X step that arrived between the pass's first read and that
re-read was recorded as already seen, so it was never copied. A second,
related case was also fixed: if the mirror's own late write landed on one
output while the user moved the other, "the default wins" copied the echo
back over the user's change. Now:

- Only the side that was written is read back.
- The mirror's late write is recognised even when the other side moved at
  the same time.

Two tests reproduce the two cases; each fails if its fix is reverted.

Rerun with the fix:

- Play aligned the speakers to the PRO X at 0.2232 and then at 0.2540.
- Option-Shift quarter steps moved the speakers by 1/64, and the PRO X
  followed within about 15 ms.
- A 20-second drag of the PRO X's Primary slider, through zero and up to
  0.57, made 133 writes. Every time the slider came to rest, both outputs
  matched, ending at 0.5362. No write followed the end of the drag.
- At zero the PRO X reported mute; the speakers followed and were unmuted
  again as the slider rose.

Validation: 393 CDKit tests and 20 AudioCheck tests passed, normally and
under Thread Sanitizer, with no sanitizer warnings. The app built and its
six view tests passed. `CoreAudioVolumeControls` now logs each write at
debug level in the "Volume" category.

#### M6.4 hardware checks 1–4 and the WALKMAN volume case (2026-11-02)

Same setup as check 7, with the volume monitor and the app's log running.

- **WALKMAN (no host volume):** chosen directly, the menu and tooltip said
  "volume on device" and "Volume keys control MacBook Pro Speakers". Play
  started no mirroring. Ten volume-up and ten volume-down presses moved only
  the speakers (0.19 to 0.75 to 0.125); the PRO X stayed at 0.5362 and the
  WALKMAN's loudness did not change.
- **Check 1, unplugging the PRO X:** four unplugs during playback each
  paused within about 40 ms ("Playback paused by an output change") with
  0 underrun frames, showed `OUTPUT LOST` on MacBook Pro Speakers, and the
  tooltip read "beyerdynamic PRO X was disconnected, playback paused."
  Mirroring stopped each time and the speakers' level was not touched.
  Plugging the PRO X back in while paused returned the selector to it with
  `CD PAUSED`; unplugging while paused showed the notice again.
- **Check 2, missing at launch:** with the PRO X unplugged before launch,
  the app showed `OUTPUT LOST` on MacBook Pro Speakers and the tooltip read
  "beyerdynamic PRO X is not connected." Play cleared the notice and played
  on the speakers; reconnecting while paused returned the selector to the
  PRO X.
- **Check 3, reconnecting while playing on the fallback:** playback on the
  speakers continued without a pause. Choosing the PRO X then moved
  playback from 32.91 s to 33.02 s with 0 underrun frames, and mirroring
  started with the speakers aligned to the PRO X (0.0625 to 0.0635).
- **Check 4:** `AudioCheck --list-outputs` reported host volume on the PRO X
  and none on the WALKMAN.

Checks 5 and 6 need HDMI to the receiver and are still to come.

#### M6.4 hardware checks 5 and 6 on Samsung HDMI (2026-11-02)

Setup: Pioneer BDR-XS07U with the 3-track CD and the Samsung TV over HDMI
(no host volume), with MacBook Pro Speakers as the macOS default. The app's
log and a read-only poll of the output list ran throughout.

- **Check 5, lead-in:** with the 1-second lead-in, the owner heard the
  complete start of track 1 after Play, after a 10-second skip, at the start
  of track 2 and after resuming from Pause. Every start had 0 underrun
  frames. `CD_PLAYBACK_LEAD_IN_MILLISECONDS` stays at 1000. Nothing was
  mirrored, because the Samsung has no host volume.
- **Check 6, TV input change:** switching the TV to another input for about
  15 seconds and back left the SAMSUNG output listed. Playback continued
  with 0 underrun frames, and sound returned on the Mac's input.
- **Check 6, display sleep:** Lock Screen alone did not turn the display
  off, so `pmset displaysleepnow` was run once with the owner's approval.
  The display was off from 18:09:32 to 18:09:44. The TV went silent and came
  back on wake. macOS kept the SAMSUNG output listed throughout and CDPlayer
  played on with no pause and no underrun, so about 12 seconds of the CD were
  not heard. As with a sleeping AirPlay receiver, the app has no signal to
  act on. The development guide tells the user to pause before the display
  sleeps. Pausing on display sleep would be a behaviour change and needs its
  own decision.

All M6.4 hardware checks are done.

#### M6.5 checks A–C and the N-50 bit-depth restore (2026-11-02)

Setup: Pioneer BDR-XS07U with the 3-track CD. Connected outputs: External
Headphones (the macOS default, host volume), the Pioneer N-50 over USB
("Pioneer USB Audio Device", no host volume), the Samsung over HDMI and the
PRO X. The app's log and a read-only rate poll (once a second) ran
throughout. `before.json` was captured at 18:18, before the PRO X was
plugged in.

- **A, wired headphones:** the built-in entry read "External Headphones".
  Play switched it from 48 kHz to 44.1 kHz and the owner heard clear audio.
  Stop at 10.41 s restored 48 kHz, with 0 underrun frames.
- **C, switching while stopped and paused:** choosing the N-50 while
  stopped only changed the selector. Play then started on the N-50, which
  went to 44.1 kHz, and Pause at 41.15 s returned it to 48 kHz. Choosing
  External Headphones while paused, then Play, resumed there at 41.24 s.
  Choosing the N-50 while paused at 50.58 s left `CD PAUSED` at the same
  time, and nothing played.
- **B, the N-50 over USB:** with the N-50 on its USB-DAC input, Play resumed
  at 50.64 s with clear audio, and the front panel showed 44.1 kHz. The
  tooltip named the USB connection and volume on the device, and said the
  volume keys control External Headphones. The name fitted beside
  `CD PLAYING` and the status stayed readable. Eject while playing stopped
  at 183.97 s with 0 underrun frames and 0 concealed sectors.
- **Bit depth not restored:** after the Stop,
  `AudioCheck --verify-output-state after` reported the N-50's physical
  format as 48 kHz 32-bit integer instead of the 48 kHz 16-bit captured
  before. Every earlier snapshot of the N-50 had 16-bit. The rate was right;
  only the bit depth was wrong. The check also listed the PRO X as a new
  device, because it was plugged in after `before.json`. This was the first
  direct playback to an output whose resting bit depth differs from the
  playback format.
- **Cause:** confirmed with the owner's approval by a session-only probe
  that set formats on the idle N-50, with no audio. The app plays the N-50
  at 44.1 kHz 32-bit. Restore wrote the original physical format (48 kHz
  16-bit), which already returned the virtual format to 48 kHz Float32.
  Restore then wrote the virtual format anyway, because it had read it
  before the physical write, and macOS re-picked the 32-bit physical format.
  Re-reading the virtual format after the physical write and skipping the
  write left 48 kHz 16-bit. The probe finished with the N-50 back at 48 kHz
  16-bit.
- **Fix:** `write_virtual_format_keeping_physical` in `OutputRateRecovery.c`
  is used by both apply and restore. It writes the virtual format only when
  it is not already the target. If that write changes the physical format,
  it writes back the physical format from just before. Apply used the same
  order, and is safe today only because the format it picks (the first one
  advertised) is also the one macOS prefers.
- **Tests:** the rate-recovery fake gains an opt-in coupled mode that models
  this: a physical write carries the virtual rate, and a virtual or rate
  write re-picks a preferred bit depth. The test restore helpers now pass a
  copy of the record, as production does. Three new tests cover:
  - the N-50 restore, which must make no virtual write at all;
  - an apply whose chosen bit depth is not the preferred one;
  - an 8-to-2-channel change, where the virtual write is still needed.

  All three fail against the old code. Without the write-back, the
  channel-change test fails; without the skip, the N-50 test fails.

#### M6.5 check D: Stop, Eject and Quit on the N-50 (2026-11-02)

A new Debug build with the bit-depth fix, after all three suites passed.
The connections had changed since checks A–C: the PRO X and the headphones
were unplugged, so the MacBook Pro Speakers were the default. A new baseline
captured the N-50 resting at 48 kHz 16-bit.

- Launch was quiet: no recovery and no rate change.
- **Stop:** Play started at 0.08 s with clear audio, and the N-50 went to
  44.1 kHz. While playing, the last button shows Stop, not Eject. Stop at
  75.41 s (0 underrun frames, 0 concealed sectors) returned the N-50 to
  48 kHz **16-bit**, and `--verify-output-state after` passed. Before the
  fix, this same step left it at 32-bit.
- **Eject while stopped:** the drive ejected the disc (18:45:00–18:45:04),
  and the owner reinserted it. No output setting changed; the check passed.
- **Quit while playing:** Play, then Cmd-Q after a few seconds. The app
  stopped, restored the drive speed and closed the disc. The N-50 went from
  44.1 kHz back to 48 kHz 16-bit, and the check passed. The relaunch logged no
  recovery, because quit leaves no rate record behind.

#### M6.5 check E, part 1: sleep on the N-50 and the held restore (2026-11-02)

The N-50 stood in for the PRO X, which was unplugged. The same Debug build
as check D.

- The owner played the CD, chose Apple menu › Sleep, then woke the Mac and
  logged in. The display showed `CD PAUSED` at track 1, 00:16, as specified,
  but also `[ERR] Audio error`.
- The app log: "Preparing for system sleep" at 18:47:41.886; at 18:47:43.243
  "The output did not switch to the requested stream format", and playback
  stopped by an error at 16.88 s. Sleep was allowed after 1390 ms.
- **Cause, from the `coreaudiod` log:** 12 ms after the app's sleep notice,
  coreaudiod left FullWake for `DarkWakeSilenceBuffers`. The app's
  physical-format restore reached the USB driver at 18:47:41.903
  (`RequestConfigChange`), but the driver returned only at 18:48:11.917,
  just after FullWake. macOS holds output configuration changes from the
  start of sleep until wake, so the app's 1-second wait for the format ran
  out. The held change landed at wake, and the N-50 ended at 48 kHz 16-bit
  (`--verify-output-state after` passed). Its record stayed in the
  preferences without being marked for recovery, so nothing would have
  retried it before the next launch.
- This is the first, physical write, so the bug predates the bit-depth fix.
  M5.1 slept on the built-in speakers, whose driver restored the rate in
  time.
- Play after wake resumed at 16.94 s with 0 underrun frames and cleared the
  error. Pause then restored the N-50 and dropped the record.
- **Fix (decision 22):**
  - `cd_playback_stop_before_sleep` stops as `cd_playback_stop` does. When
    the rate or format restore fails and the output still has a record, it
    marks the record for recovery and reports success, with
    `outputRestorePending` set in the snapshot. Without a record the failure
    stands.
  - `PlayerModel.prepareForSleep` uses it through
    `PlaybackEngine.stopBeforeSleep()` and logs "The output did not finish
    restoring before sleep; restoring it after wake".
  - At wake, `systemDidWake` starts the same recovery as at launch. The
    buttons are disabled until it finishes, and Play waits for it, so Play
    cannot record an output still at the playback format as the one to
    restore. A failure shows the short audio error.
  - In this test, the app's wake notice came 6 ms after coreaudiod's
    FullWake and before the held change landed. Recovery then either finds
    the original format and drops the record, or writes it again and its
    wait succeeds.
- **Tests:** `FakeEngine` can defer the restore at sleep. Three new sleep
  tests cover:
  - a held restore: no error, the position kept, recovery only after wake,
    and Play waiting for it;
  - a recovery still failing after wake, which shows the audio error;
  - a sleep whose restore finished, which recovers nothing at wake.
- **Re-run with the fix (19:12–19:14):** a new Debug build, after all three
  suites passed. Play started at 0.08 s with clear audio. Sleep came at
  19:12:56.321; coreaudiod entered `DarkWakeSilenceBuffers` 14 ms later
  and held the N-50's format change. At 19:12:57.672 the app logged "The
  output did not finish restoring before sleep; restoring it after wake",
  paused at 17.96 s (0 underrun frames) and allowed sleep after 1371 ms.
  After wake the display showed `CD PAUSED`, track 1, 00:17, with no error.
  The app's wake notice came at 19:13:28.981, 23 ms after FullWake, and it
  started the recovery. The held change landed at 19:13:29.025. The record
  was gone, and `--verify-output-state after` passed with the N-50 at
  48 kHz 16-bit.
- Play and Stop after wake are still to be repeated with the fix. The owner
  disconnected the hub before pressing Play, and the N-50 came back on
  another USB port, with a new UID ending `2100000:1`. The run before the
  fix had already resumed after wake with 0 underrun frames.
- The owner then paused testing because the devices were unavailable.
  Check E remains incomplete. After reconnection, capture a fresh baseline
  and repeat the entire Play, Sleep, Wake, Play and Stop sequence on the
  N-50, then HDMI, verifying the original output state after each run.
- **Pre-commit validation:** 399 CDKit tests and 20 AudioCheck tests passed
  normally and under Address Sanitizer and Thread Sanitizer, with no
  sanitizer findings. Regenerating the Xcode project and building for
  testing succeeded; all six app view tests passed. No live hardware step
  was run during this validation.

#### M6.5 check E completed: N-50 and HDMI sleep/wake, resume and Stop (2026-11-02)

The owner reconnected the N-50 over USB, Samsung HDMI and the Pioneer
BDR-XS07U with the 3-track CD. With approval, playback was stopped, a fresh
baseline was captured and the tested Debug build from `b474128` was
restarted. MacBook Pro Speakers stayed the macOS default. The owner
performed Play, Apple menu > Sleep, wake, Play and Stop on each directly
selected output; no connections changed during either run.

- **N-50 baseline:** UID ending `2110000:1`, 48 kHz, stereo Float32 virtual
  format and 16-bit integer physical format. The owner heard audio before
  sleep and saw 44.1 kHz on the N-50.
- **N-50 sleep and wake:** sleep began at 23:12:14.214. The output restore
  was deferred, the disc closed, and playback paused at 18.53 s with
  0 underrun frames and 0 concealed sectors. Sleep was acknowledged after
  1544 ms. Wake at 23:12:44.269 started recovery; the owner saw `CD PAUSED`,
  track 1, 00:18, Pioneer USB Audio Device, with no error. The after-wake
  snapshot matched the baseline.
- **N-50 resume and Stop:** the first playback progress after Play was
  18.58 s. The owner heard normal audio and saw 44.1 kHz. Stop at 32.55 s
  had 0 underrun frames and 0 concealed sectors. The final snapshot matched
  the original 48 kHz 16-bit configuration, and `ChangedOutputRates` was
  absent.
- **HDMI baseline:** captured again while stopped, immediately before the
  HDMI run. Samsung was at 48 kHz with eight-channel Float32 virtual and
  24-bit integer physical formats.
- **HDMI sleep and wake:** the owner heard audio before sleep. Sleep began
  at 23:20:19.341; restoration finished before sleep, which was acknowledged
  after 112 ms. Playback paused at 13.76 s with 0 underrun frames and
  0 concealed sectors. After wake at 23:20:49.365, the owner saw `CD PAUSED`,
  track 1, 00:13, SAMSUNG, with no error. The after-wake snapshot matched
  the baseline; no deferred recovery was needed.
- **HDMI resume and Stop:** the first playback progress after Play was
  13.84 s, with audible sound and no error. Stop at 23.43 s had 0 underrun
  frames and 0 concealed sectors. The original 48 kHz eight-channel
  configuration, including 24-bit physical PCM, was restored, and
  `ChangedOutputRates` was absent. The owner's initial "1:13" report was
  confirmed as a typo for 00:13.

All four `--verify-output-state after` comparisons passed: after wake and
after Stop on each output. These compare the complete saved configuration
and exposed controls, not end-to-end DAC samples. Captures were taken only
while playback was paused or stopped; no check tool read the disc. Evidence
is in the session's `m65-e-20261102-2308` files. Logging was stopped at the
end, and CDPlayer was left stopped on SAMSUNG.

Check E is complete without further code changes. Check F (PRO X microphone
and sidetone) and release preparation remain.

#### M6.5 check F completed: PRO X microphone and sidetone (2026-11-02)

The owner connected the beyerdynamic PRO X, confirmed CDPlayer was stopped
with no other app using the device, and approved fresh read-only snapshots
and logging. The same tested Debug build from `b474128` remained open.
The owner selected the PRO X directly, operated Play and Stop, and reported
normal CD audio, no audible sidetone while stopped or playing, and no error
after Stop.

- **Baseline:** PRO X output UID (it ends in the USB serial), idle and
  unowned at 384 kHz, stereo Float32 virtual and 32-bit integer physical
  PCM. Output volume was `0.06348812580108643`, with mute off. Its separate
  input UID was idle at 48 kHz, mono Float32 virtual and 16-bit
  integer physical PCM, input volume 1 and mute off. MacBook Pro Speakers
  remained the default output and system output; the built-in microphone
  remained the default input. The offline baseline check passed.
- **During playback:** with separate approval, a getter-only Core Audio
  probe resolved the input by UID and sampled its running state, rate,
  complete stream formats, volume, mute and the previously identified
  driver sidetone properties. Its output matched the idle baseline exactly:
  the microphone remained idle at 48 kHz, and the sidetone-enabled flag
  (`STen`) remained 1 with gain (`sqgd`) at 0 dB. This flag was already set
  before Play; it does not establish that sidetone is audible.
- **Stop:** the log recorded 72.54 s played, 0 underrun frames and
  0 concealed sectors at 23:37:43.932. The drive closed and its reported
  speed was restored. The after-Stop microphone/sidetone sample again
  matched the baseline exactly. The output returned to its original
  384 kHz formats, idle and unowned, with no `ChangedOutputRates` record.
- **Volume-mirror exception:** the strict full-snapshot `after` comparison
  reported exactly one difference: the default speakers' volume changed
  from `0.0625` to `0.06348812580108643`. The log confirms the approved
  Play-time alignment to the selected PRO X (decision 19); this level is
  intentionally not restored at Stop. A separate offline comparison of
  every saved device and default-route field passed with only that expected
  change allowed. The PRO X's output volume and all input controls matched.
- **Drive observations:** the known minimum-speed refusal was logged
  (176 kB/s requested, 4233 kB/s reported), as was an initial successful
  2991 ms read. Neither caused underruns or concealed sectors in this run.

The standard configuration snapshots were captured only while stopped.
The during-playback probe used Core Audio getters only: no disc access,
audio activation, microphone recording or property setters. Its source and
before/during/after results, the snapshots, comparisons and application log
are retained in the session's `m65-f-20261102-2331` evidence directory.
Logging was stopped, and CDPlayer was left open and stopped on the PRO X.

Check F and all available M6.5 hardware checks A–F are complete. No production
code changes were needed. DisplayPort/Thunderbolt playback remains untested
because suitable hardware was unavailable; release preparation remains.

## M9: audio-level meters

The confirmed behavior and design are in the
[audio levels roadmap](AUDIO_LEVELS_ROADMAP.md). M9.1–M9.3 are complete;
M9.4's approved live checks and release work remain.

### M9.1 source peak capture and level table (2026-11-03)

Added `CDLevelTable` in `CDAudioCore/AudioLevels.c`. It holds 4,096 atomic
10 ms slots, records per-channel absolute Int16 peaks, identifies source
positions and playback runs, and safely rejects overwritten or stale slots.
The playback producer records a block only after the PCM ring accepts it.
Failed or cancelled reads do not publish levels. The callback and ring render
path are unchanged. Existing C playback constructors remain compatible;
level-aware constructors accept a borrowed table pointer, whose owner keeps it
alive through playback and UI reads.

Eight new offline tests cover full-scale input, channel isolation, slot
boundaries and merges, position and run-tag wraparound, the demo tone's
−20 dBFS peak, failed and cancelled reads, and concurrent writer/reader access.
The complete 407-test CDKit suite and 20 AudioCheck tests pass normally and
under AddressSanitizer and ThreadSanitizer. Existing tests were not changed.

### M9.2 meter model and player state (2026-11-03)

Added a process-wide `CoreAudioLevelSource` that reads only the current run's
atomic slots, and a pure Swift `AudioLevelMeter` for the documented dBFS
thresholds, 1.5-second peak hold, and 20 dB-per-1.7-second fall. `PlayerModel`
keeps the meters hidden by default, samples peaks at its latency-adjusted
display position, and advances between snapshots by at most 0.2 seconds while
playing. Its meter clears while paused, buffering, during intentional HDMI or
DisplayPort lead-in silence, after an output loss, and across seeks or track
changes. Playback snapshots now expose that lead-in state. The render callback
and PCM output remain unchanged.

Offline tests cover thresholds, full scale, rise/fall/hold timing, display
latency and interpolation, idle and lead-in states, output loss, seeks, track
changes, and the disc producer under both `.singlePass` and `.retry`.

### M9.3 drawer, menu and shortcut (2026-11-03)

Added the compact L/R LED drawer below the existing display, using the
latency-aware meter readings, same mint tint, faint unlit segments, and dB
labels. It animates into view with a slide and opacity, or opacity alone with
Reduce Motion enabled. The borderless window grows downward from its fixed top
edge, moves up when necessary to stay within the screen's visible frame, and
does not move back when the drawer closes. **View › Show/Hide Audio Levels**
toggles the drawer and uses ⌘L. Its accessibility label is "Audio levels".

The app's native UI suite now has nine tests, including open/closed window
dimensions, top-edge anchoring, bottom-edge correction, and menu title and
shortcut configuration. All 417 CDKit tests and 20 AudioCheck tests pass
normally, under AddressSanitizer, and under ThreadSanitizer; all nine UI tests
pass and the Debug app builds. The demo-playback visual check and README
screenshot remain for an owner-approved app run. No app playback or hardware
was accessed.

#### Drawer close and meter refresh fix (2026-11-03)

The owner's first run of the Debug app found a problem when ⌘L closed the
drawer: the top and bottom of the display were clipped and the window moved
up.

- **Cause:** two things resized the window. `NSHostingView` fitted the window
  to the SwiftUI content, and `PlayerWindow` animated the frame. During the
  drawer's removal transition the content kept its open height, so it was
  centred and clipped in the shrinking window. The size constraints then
  resized the window again from its new origin, so the window moved up. The
  frame change was also relative, so a second toggle mid-animation compounded
  it.
- **Fix:**
  - The hosting view now reports only a minimum size. `PlayerWindow` alone
    sets the height, using absolute closed and open heights with the top edge
    fixed.
  - The display is pinned to the top. The drawer sits at the bottom of a
    clipped slot whose ideal height is zero, so it slides out from behind the
    display as the window grows, and the closed size never changes.
  - With Reduce Motion, opening sets the frame at once and fades the drawer
    in. Closing fades it out and shrinks the window 0.25 s later. Reopening
    within that time cancels the shrink.

Reviewing the fix also showed that the drawer never refreshed its meters: the
10 Hz poll does not read levels, and the drawer's timeline paused once the
reading was dark. The drawer now calls `PlayerModel.refreshAudioLevels()` on
every frame. Its timeline runs only while `audioLevelsAreLive` is true, that
is, while the drawer is open and the player is playing. At other times the
meter is already dark.

The M9.3 window test had missed the bug because of how it waited. An `async`
XCTest runs inside a main-queue callout, where `RunLoop.main.run(until:)` never
drains the main queue, so `PlayerWindow`'s own resize ran only after the test.
The test passed only because the hosting view resized the window itself. The
drawer tests now wait with `Task.sleep`.

The UI suite now has 12 tests: one drawer test was rewritten and three are new.
There is also one new CDKit test. Together they check that:

- the display's top border stays at the top of the window on every sample
  through both animations, the window animates, and the frame settles back to
  its closed position;
- toggling mid-animation settles at the exact closed or open frame;
- with Reduce Motion, the window shrinks only after the fade, and reopening
  cancels the pending shrink;
- with a fake source, the drawer lights while playing and darkens when
  paused;
- in CDKit, the meter refreshes only while the drawer is open and the player
  is playing.

The tests were checked against the bugs. Restoring the old layout failed the
display test, with the display pushed down 81–312 pixels. Restoring the old
timeline failed the meter test.

#### Meters moved into the main window (2026-11-03)

After running the fixed build, the owner simplified the design: no drawer.
⌘L or the View menu now extends the main window at the bottom, with
animation, to show the meters below the transport buttons. The same command
shrinks the window back to its original size.

- **Layout:** `PlayerView` now draws the panel's background and white border
  around both the player rows and an audio-level slot below them. The slot
  is a clipped area with an ideal height of zero and no maximum, so it takes
  whatever height the window adds. The meters are anchored to its top after
  a 10 pt gap. Showing them adds 52 pt (`audioLevelsAddedHeight`: the gap and
  42 pt of meters), and the 18 pt bottom padding stays the same, so the meters
  are uncovered in place as the bottom edge moves down.
- **Look:** the meters have no box of their own. They use the display's
  tint, with 10 pt L and R legends and an 8 pt scale. Each row is a 10 pt
  legend column followed by 20 equal cells, and the scale uses the same
  cells. Each label is now centred under the segment whose lower edge it
  names. The M9.3 scale spread its labels evenly, so −10 sat near the eighth
  segment instead of the eleventh. "dB" moved into the legend column.
- **Window:** the behaviour of the fix is unchanged: `PlayerWindow` alone sets
  absolute heights with the top edge fixed, moves up to stay on screen, and
  with Reduce Motion shrinks only after the fade. A subscription to
  `NSWindow.didResizeNotification` now recomputes the shadow after every
  resize step, replacing the two explicit calls, so the borderless window's
  shadow follows the animation. That cannot be checked offline.
- **Size authority:** because the slot's ideal height is always zero, the
  content's ideal height no longer changes when the meters are shown.
  Removing `sizingOptions = [.minSize]` on its own therefore no longer
  reproduces the close bug, which a mutation run confirmed. The option stays,
  so the window remains the only size authority.

The UI suite now has 13 tests. At every sample through both animations, the
window tests check that the display's white border is on the top pixel row
and that every row above the last is opaque, so the panel fills the window.
Once settled, the panel's border must be on the bottom row. A new test checks
the scale labels against the segment thresholds, and the CDKit refresh test
was renamed for the meters. Mutation runs confirmed the checks:

- Fixing the slot at zero height failed the meter test: 47 lit pixels, where
  more than 1,047 were required.
- Also removing the panel's flexible frame failed the top-border, gap and
  bottom-border checks, during and after both animations.

The Debug app builds, and all 13 UI tests pass. All 418 CDKit tests and 20
AudioCheck tests pass normally, under AddressSanitizer and under
ThreadSanitizer. Screenshots exported from the test results confirm the
layout. No app playback or hardware was accessed; the owner's visual check
remains.

#### Red peak hold (2026-11-03)

At the owner's request, the peak-hold segment is now red, the same red as the
power icon. `PlayerView` keeps that colour in one constant, `powerTint`, which
the power button and the meters' peak hold share. Lit bar segments stay mint.

- **At a new peak** the hold is the bar's top segment, so the top of the bar
  is red. As the bar falls, the red segment stays in place for 1.5 s, then
  drops to the bar.
- **Never inside the bar:** when a hold expires during music, the next hold
  starts from the current block's peak, which can be below a bar still
  falling from an earlier peak. That was invisible while every lit segment
  was mint. `AudioLevelMeter` now reports `peakHoldSegment` only at or above
  the bar's top segment, so such a hold stays hidden until the bar falls to
  it. The hold's timing is unchanged.

A new CDKit test checks the rule with the injected clock. At −6 dBFS the hold
is the bar's 13th and top segment. After it expires, a −30 dBFS block starts
a hold below the 5-segment bar; it is not reported until the bar falls to it,
and then it stays above the bar. A new UI test plays −6 dBFS from the fake
level source and checks that:

- the red is one segment wide and caps the mint bar;
- its most common pixel colour is exactly the power icon's;
- it stays in place, above unlit segments, while the bar falls;
- it is gone after 1.5 s while the bar is still lit.

Mutation runs confirmed the checks:

- Drawing the hold in mint failed with no red hold at a new peak.
- A slightly different red, (1, 0.2, 0.2), failed the colour check: device
  RGB (241, 96, 80) against the power icon's (241, 81, 74).
- Colouring the bar's top segment instead of the hold failed the checks that
  the hold stays in place above unlit segments and then drops.
- Restoring the old hold rule failed the CDKit test at the hidden restarted
  hold.

The Debug app builds, and all 14 UI tests pass. All 419 CDKit tests and 20
AudioCheck tests pass normally, under AddressSanitizer and under
ThreadSanitizer. No app playback or hardware was accessed; the owner's visual
check remains.

#### Meters measure only when fully shown (2026-11-03)

At the owner's request, the meters measure only when the window is fully
extended: not while it extends or shrinks, and not while they are hidden.
The owner kept source recording always on, so only the meters' reads are
gated; the C producer still records every block it reads.

- **Model:** `PlayerModel` has a published `audioLevelsAreFullyShown`.
  `toggleAudioLevels()` clears it and darkens the meter, and no longer takes
  a first reading. The new `audioLevelsDidFinishShowing()` sets it, only
  while the meters are shown, and takes the first reading.
  `updateAudioLevels()` reads nothing until it is set, and
  `audioLevelsAreLive`, which runs the meters' timeline, now needs it too.
- **Window:** `PlayerWindow` reports the end of each show. With motion, the
  report comes from the resize animation group's completion handler; with
  Reduce Motion, from the end of the 0.25 s fade-in. Each toggle takes a new
  generation, and only the latest one can report, and only while the meters
  are shown. An earlier toggle's animation, cut short by a later one,
  therefore cannot start the meters early. AppKit does not document which
  thread runs the completion handler, so the report hops to the main queue.
- **Hiding:** hidden meters used to go dark gradually. The
  `.animation(_:value:)` modifier for the Reduce Motion fade also animated the
  segments' colours, which are cleared in the same update, so lit segments
  faded out over 0.25 s while the window shrank. The modifier now uses the
  body form, `.animation(_:body:)`, around the opacity alone, so only the
  fade animates and hidden meters go dark at once.

A new CDKit test drives the gating with the injected clock: a report before
the meters are shown, or after they are hidden, is ignored; nothing is read
between showing them and the report; the report takes one reading; and
showing them again waits for a new report. The existing meter tests now
report the end of the show. Three new UI tests use a fake level source that
counts reads, and sample the window and meters every 10 to 20 ms:

- With motion, nothing is read and no bar pixel is lit until the window is
  fully extended; then the bars light. After hiding, nothing is read and no
  pixel is lit while the window shrinks or once it is closed.
- After quick toggles, only the last show reports, once its animation ends,
  with exactly one read.
- With Reduce Motion, after showing the meters again during their fade-out,
  nothing is read or lit until the new fade-in ends. After hiding, they are
  dark before the window shrinks, and nothing is read.

While the suite ran, the red peak-hold test failed when its window opened on
a 1× external display. There, the thin power symbol has few fully covered
pixels, so its most common colour was an anti-aliased blend, (199, 58, 52)
against the hold's (255, 72, 63). The meter and window tests now open their
player window at the centre of the display with the highest backing scale
factor, rather than on whichever display is in use.

Mutation runs confirmed the checks:

- Reporting at the start of the animation failed both motion tests.
- Reading whenever the meters are shown failed the CDKit test and all three
  UI tests.
- Not clearing the flag on hide failed the CDKit test and the hide checks.
- Ignoring the generation failed the quick-toggle test in 3 of 3 runs: an
  earlier toggle's animation reported while the last show was extending.
- Restoring the old animation modifier failed both hide pixel checks.

The Debug app builds, and all 17 UI tests pass; the eight window and meter
tests passed 5 runs each. All 420 CDKit tests and 20 AudioCheck tests pass
normally, under AddressSanitizer and under ThreadSanitizer. No app playback
or hardware was accessed; the owner's visual check remains.

#### Meter reads only while the window is visible (2026-11-03)

The meters now measure only when they are fully shown and the player window
is visible. They go dark and stop reading when the window is hidden,
miniaturized, fully occluded or off-screen, then take a fresh reading when it
becomes visible again. Source-level recording remains always on. Visibility
updates come from AppKit's occlusion, movement, screen, miniaturization,
ordering and app hide/unhide events. The window's VoiceOver element is
explicitly hidden until the meters are shown.

`PlayerModel` combines the fully-shown and window-visible states before it
starts meter reads or its display timeline; hiding clears the current reading.
The View command remains available without a disc. Offline tests cover
visibility changes, no-disc toggling, Stop/Eject clearing and VoiceOver
exposure. The UI test host does not reliably model WindowServer occlusion or
miniaturization, so the notification test injects the visibility predicate
and verifies the state-change path; native occlusion and minimization remain
for the owner's GUI verification.

The three focused UI tests for visibility, VoiceOver and the no-disc command
pass. An earlier full-suite attempt failed because the test host reported
`NSApplication.isActive == false`, preventing AppKit window animations and
related window/layer assertions. On 2026-11-03, the full suite passed on a
subsequent run: 19 tests, zero failures.

The roadmap now records visibility gating and marks the View menu checklist
complete. No disc, output, playback, system volume, or installation was
accessed.

#### M9.4 live checks and the 15 Hz meter refresh (2026-11-03)

With the owner's approval, a Debug build played the inserted audio CD (3
tracks, 14:13) from the PIONEER BD-RW BDR-XS07U. The owner performed the
physical actions. Read-only `OpticalCheck` and `AudioCheck --list-outputs`
preflights ran only while playback was stopped. No system volume, mute or
installation was changed.

- **Built-in speakers:** passed. Playback was audible, the meters followed the
  music, and they stayed dark while the window extended.
- **USB DAC (Sony WALKMAN, 384 kHz current rate):** passed. Playback was
  audible and the meters followed the music. The meters follow the clock's
  latency-adjusted position rather than being sample-accurate (decision 11),
  so no millisecond limit applies; the owner judged the alignment acceptable.
- **AirPlay (another receiver, 44.1 kHz, via System Default):** passed.
  The N-50 AirPlay receiver could not be connected and no HDMI output was
  present, so the owner connected another AirPlay receiver, which a read-only
  `AudioCheck --list-outputs` confirmed as the system default. Playback was
  audible, the meters followed the music and stayed dark while the window
  extended, and the owner judged their alignment with the buffered AirPlay
  sound acceptable.

CPU use came from `top -l 16 -s 1` on the app process, ignoring each run's
first sample, which `top` always reports as 0.0. It includes disc reads and
decoding, and readings were noisy. At 30 Hz it was about 25% hidden and
39–40% shown. The owner chose to lower the meter `TimelineView` to 15 Hz; the
rebuilt app then measured about 31–33% hidden and 40% shown. The gap
narrowed, but the shown figure did not drop because the hidden baseline varied
between runs. The owner found 15 Hz smooth enough. These are Debug-build
figures; a Release build and an Intel Mac have not been measured.

The focused and full UI test suites pass on the 15 Hz build. Owner verification
of native occlusion and minimize behavior, the window shadow check and the
README screenshot remain.

#### Native Minimize command for the borderless player (2026-11-03)

The owner passed window size/position/shadow, app hide/restore and fully
covering/uncovering the player. These visual checks confirm native window
behavior and resumed meter updates, not the absence of reads while invisible.
Window > Minimize was disabled and Command-M did nothing; the owner requested
a fix before release.

The native `performMiniaturize` action expects a title-bar button, which this
borderless window does not have. An offline regression reproduced the action
doing nothing. `PlayerWindow` now validates the Minimize menu item for its
visible, miniaturizable, non-minimized window and routes the action directly to
`miniaturize`. Other menu validation is unchanged. The native Dock transition
and visibility notifications still handle the actual minimize/restore cycle.

The regression invokes the native menu action with fake playback and verifies
that the window really minimizes, menu validation changes, meters clear and
stop reading, playback stays playing, and restoration resumes reads. The full
UI suite now passes all 20 tests. The 423 CDKit tests and 20 AudioCheck tests
also pass normally, with AddressSanitizer and with ThreadSanitizer.

The owner then passed both Window > Minimize and Command-M followed by Dock
restoration in the rebuilt app: audio continued and the meters resumed
normally. The README screenshot was captured with the owner's window
selection. It shows a detected three-track CD and the extended meter panel,
dark while stopped. No system volume was changed and no app was installed.

#### M9.4 acceptance and version 1.2.0 (2026-11-03)

The owner approved publishing version 1.2.0 after the remaining checks passed.
Built-in speakers, the Sony WALKMAN USB DAC and AirPlay live checks, native
window/shadow checks, the corrected Minimize command, and the README
screenshot are complete. All 20 UI tests pass; the 423 CDKit and 20 AudioCheck
tests pass normally and under both AddressSanitizer and ThreadSanitizer.
Live checks used Debug builds; Release-build and Intel CPU performance remain
unmeasured.

Version 1.2.0 (build 3) is packaged as `CDPlayer-1.2.0-macOS.zip`. The extracted
app was checked for its version, macOS 14 minimum, both `arm64` and `x86_64`
architectures, valid ad-hoc signature and hardened runtime. Archive integrity
also passed. The package SHA-256 is:

```text
97f2c8f665e287b03d94098d3b186efb6a09bc5319156f2966d59e93e3302429
```

The [1.2.0 release](https://github.com/ylau674/CD-player/releases/tag/v1.2.0)
ships the accepted M9 work. The repository remains private, and the package
is not Developer ID signed or notarized. It was not installed into
`/Applications`.

#### Meter CPU: bars drawn outside SwiftUI (2026-11-03, after 1.3.0)

The owner saw the installed Release 1.3.0 use about 2% CPU while playing and
about 10% with the meters shown, and asked for ways to reduce it. They chose
to profile first. With their approval, they played the LUNA SEA HDCD disc in
the installed app and toggled the meters; nothing else touched playback,
volume or the drive. `top -l 17 -s 1` on the app process, ignoring the first
sample, measured 2.2% hidden (1.5–2.7%) and 12.5% shown (9.4–16.0%).
WindowServer stayed at about 47% either way, set by other on-screen
activity.

An 8-second `sample` with the meters shown put almost no time in the meter
code: about a dozen samples in the `TimelineView` closure and the model's
read. The main thread's busy time went to SwiftUI updating the whole player
view on each meter frame: AttributeGraph dirty propagation from the
timeline's new time, `NSHostingView.layout` re-rendering the view graph,
`updateConstraints`, and the display list. The read itself is cheap, and the
meter tick changes no `@Published` value. The window shadow is recomputed
only on resize. So redrawing the meters through SwiftUI cost a whole-view
update on every frame.

The bars are now drawn by `AudioLevelBarsView`, an AppKit view in an
`NSViewRepresentable`, with `draw(_:)` filling the 40 rounded segments. Core
Animation sublayers would have avoided the backing store too, but the UI
tests' pixel checks capture with `cacheDisplay`, which renders only
`draw(_:)`. (That assumption was wrong; the segments became layers on
2026-11-04, see "Meter segments as layers".) `AudioLevelMeterDriver` in CDKit reads on a plain
main-run-loop timer every 1/15 s, in common modes with 10% tolerance, and
only while `audioLevelsAreLive` is true. It hands a reading to the view only
when a lit or held segment changes: the exact dB level changes on almost
every read while a bar falls. Any other player change still reads once,
draws if needed and stops the timer when the meters are no longer live. A
timer outliving its driver stops itself. The legends and the dB scale stay
in SwiftUI and no longer rebuild per read. `ChannelReading.state(ofSegment:)`
now holds the lit, unlit and peak-hold rule the view used to inline. The
look, ballistics, 15 Hz rate, peak-hold colour and dark, hidden and
visibility rules are unchanged.

New CDKit tests cover the segment states, the drawing comparison, the
driver's timer lifecycle and change-only drawing with a fake timer, a
released driver's timer, and the real main-run-loop timer stopping itself. A
new UI test checks that the bars read on their own timer, that a steady
full-scale level draws nothing new, that a falling bar redraws, and that
hidden meters run no timer and are dark. The existing pixel tests for lit
and dark bars, the red peak hold and the scale alignment pass unchanged. The
448 CDKit and 29 AudioCheck tests pass normally and under both
AddressSanitizer and ThreadSanitizer, and all 21 UI tests pass.

With the owner's approval, a Release build of the change ran from the build
folder in place of the installed app, which the owner quit first; it was not
installed. On the same disc it measured 2.2% hidden (1.4–2.6%) and 4.2% shown
(1.9–4.7%), so the meters' own cost fell from about 10.3 to about 2.0
points. A new profile shows most of the remainder is AppKit redrawing and
committing the bars' backing store about 15 times a second.

## M8: HDCD

The approved behavior and design are in the [HDCD roadmap](HDCD_ROADMAP.md).

### M8 approvals and HDCD disc analysis (2026-11-03)

The owner approved every recommendation in the roadmap: decode in the app
with "Decode HDCD" on by default, but only for discs whose codes switch Peak
Extend or a gain adjustment on; no make-up gain; plain-text "HDCD decoded" and
"HDCD source"; decode only when the output's physical format carries at least
20 bits; and M8 before M7. The owner also approved vendoring libhdcd (BSD) at
a pinned commit as the one exception to the no-third-party-dependencies rule.
At approval time, decoder implementation had not yet begun.

The owner's N-50 manual (p. 18) lists 16-, 24- and 32-bit PCM at 44.1 kHz on
its USB input. The roadmap's claim that the N-50 cannot carry decoded audio
was wrong: chosen directly it already plays at 32-bit (M6.5). The output rule
follows the physical format in use, not the device.

Added the developer-only `AudioCheck --capture-pcm <drive> <track> <start>
<seconds> <new.wav>`. It opens a read-only `DiscSession`, requests the minimum
speed, probes C2, reads at most 600 s of one stereo track in 33-sector plain
reads and writes a canonical 16-bit WAV. The file is created exclusively with
mode 0600, its I/O runs on a dedicated queue, failed captures are removed
(or a cleanup failure is reported), and close restores and verifies the drive
speed. Nine offline tests cover argument parsing, the 75-sectors-per-second
range and clipping at the track end, the WAV header and file lifecycle.

With CD Player quit and the owner's approval, the tool first read the first
60 s of each track of the owner's HDCD disc, then, approved separately, all
three tracks in full. A repeat full-disc verification retained the actual
[capture and analysis output](validation/hdcd-2026-11-03.log): 853.76 s of
audio, captured between 04:11:05 and 04:12:24 UTC. Every read had zero
C2-flagged sectors, and the drive's reported 4,233 kB/s was restored and
verified after each track. FFmpeg 7.1.1's `hdcd` filter found format-B HDCD
packets throughout: 6,726, 5,176 and 5,114 for tracks 1–3, about ten a second
per channel, with zero errors, the code-detect timer never expiring, Peak
Extend never enabled, a maximum gain adjustment of 0.0 dB and no Transient
Filter. Sample-precise input-prefix tests first reported HDCD after 46,807,
82 and 558 stereo frames on tracks 1–3 (1.061383, 0.001859 and 0.012653 s).
The transcript retains both positive and immediately preceding negative
boundaries. Decoding the continuous disc gave exactly the input at half
scale for all 75,301,632 samples, with zero mismatches and no extra decoded
samples. The captures and decoded PCM were deleted; only text is retained.

Once M8 is implemented, this disc will stay bit-perfect under the approved
rule and show "HDCD source"; it is the M8.3 control for that state. A disc
using Peak Extend or gain adjustment is still needed to verify decoding live
(a burned test disc later covered gain adjustment; see the M8.3 follow-up
below).
The 423 CDKit and 29 AudioCheck tests pass normally and under both AddressSanitizer and
ThreadSanitizer.

The capture-file review also moved file creation onto its existing worker
queue, rejected zero-progress writes, and made close/removal failures
explicit instead of silently reporting successful cleanup. Three additional
offline tests cover private file permissions, no overwrite, partial-file
removal and reporting a failed removal.

### M8.1: producer-side decoder integration (2026-11-03)

Vendored the approved libhdcd revision
`c574f998fc030a575b9fd9ff0b3ad05f571ee9c1` as the `HDCD` C target, retaining
its `LICENSE` and `AUTHORS`. The producer now detects and processes eligible
disc PCM before the Int32 ring; the render callback remains allocation-free
and only converts Int32 to Float32. Undecoded Int16 samples are shifted left
16 bits, preserving every source value exactly. The startup decision holds up
to two seconds only when the output reports at least 20 physical bits; a
narrower or unknown route continues detection while passing PCM through
bit-perfectly. Later effectual packets activate decoding only at a track
boundary, and preparation resets decoder state while retaining known disc
status.

The playback snapshot now carries HDCD detection, decoded state and reported
physical output depth. Offline tests generate valid HDCD packet bits and cover
effectual decoding, no-effect and non-HDCD bit-perfect bypass, all 65,536
Int16 values, output-depth gating, seek reuse and track-boundary activation.
The developer-only `Tools/check-hdcd-ffmpeg.sh` cross-check downloads the
FFmpeg FATE HDCD sample to a temporary directory and compares libhdcd output
against FFmpeg's `hdcd` filter byte for byte; it passed, and the sample and
intermediate PCM files are removed on exit. All 458 package tests pass
normally, under Address Sanitizer and under Thread Sanitizer. The generated
Debug app build succeeds. No disc reads or live output checks were performed
in this implementation step.

### M8.2: interface and setting (2026-11-03)

Added Playback > Decode HDCD, enabled by default and stored in
`UserDefaults`. The setting is supplied with each new playback run; changing
it never changes the level mid-track. It applies at the next Play, track
start or seek, while output moves retain the active run's setting. With
decoding disabled, the producer still detects HDCD but passes
the original Int16 samples through exactly and skips the startup hold.

The source display now distinguishes `HDCD source` from `HDCD decoded`.
Its tooltip and VoiceOver label explain no-effect HDCD, decoded 20-bit PCM
and its roughly 6 dB lower level, or why decoding is unavailable on the
selected output. The 20-bit output gate remains enforced by the producer.
README and architecture documentation now describe the preference and credit
libhdcd's authors.

Offline tests cover the default and persisted preference, applying the
setting at Play and the next track, preserving it during an output move,
the source text and accessibility explanations, and bit-perfect pass-through
when decoding is disabled. No live disc or audio output was used; that
verification remains M8.3. All 435 CDKit and 29 AudioCheck tests pass
normally and with AddressSanitizer and ThreadSanitizer; all 20 native app
tests pass, and the generated Debug app build succeeds.

### M8.3: live verification with the owner's HDCD disc (2026-11-03)

The owner connected the Sony Walkman NW-A306 over USB, with headphones, and
left the HDCD disc analysed above in the drive. Its packets switch nothing on,
so this run covers the "HDCD source" case only. The text output is kept in the
[M8.3 transcript](validation/hdcd-m8-3-2026-11-03.log); the captures were
written to a private temporary folder and deleted.

- **AudioCheck fix.** Since M8.1 the engine checksums the 32-bit samples it
  renders, but the silent check still checksummed the raw 16-bit reads, so it
  would have failed on correct playback. `PCMChecksum.appendingUndecodedPCM16`
  now widens each sample the way the ring does. A test checks it against the
  ring for all 65,536 values.
- **New diagnostics.** The silent check takes `--hdcd-off` and reports each
  segment's HDCD state, physical output depth and time to first audio. It
  fails a segment that was decoded, because a decoded checksum cannot match
  the disc. `--observe` prints the HDCD state and, when the final playback run
  was undamaged, its rendered checksum and exact frame range. It keys this on
  the final run, because each start resets the checksum, counters and decoder,
  and the observer usually pauses once during start-up buffering.
  `HDCDCheck --seek-gaps` resets the decoder at fixed steps through raw 16-bit
  PCM and reports the audio before the next packet. Run on FFmpeg's FATE
  sample, the next packet followed every reset within 99 ms.
- **Bit-perfect.** The Walkman's physical format at 44.1 kHz is 32-bit
  integer. The silent check passed with decoding on and with `--hdcd-off`:
  every segment's checksum matched independent reads, the decoder reported
  "packets that switch nothing on", and nothing was decoded. A 20-second
  `--observe` checksum, `484330ae62efc292`, matched an independent FNV-1a over
  a capture of the same sectors.
- **Detection after a reset.** On full-track captures the next packet came
  within 102 ms (median 52 ms) of every one of 2,306 resets, except the start
  of track 1, which has 1.06 s of audio before its first packet. No pre-roll
  is needed on this evidence.
- **Startup.** First audio arrived 780–900 ms after Play, and 780–796 ms
  after a seek, track boundary or resume, with decoding on or off. The
  detection hold is hidden inside the 2-second prefill. One start took 3.6 s
  while a cold drive spun up.
- **CPU regression found and fixed.** The engine alone used 1.3% in Release
  (1.2% on 2026-10-31). The Release app used 7.1% with the meters shown and
  6.7% with them hidden. A `sample` profile showed SwiftUI rebuilding
  `PlayerView` and `PlayerCommands` on the main thread.
  `updatePlaybackQuality(from:)` reassigned the three `@Published` HDCD values
  on every 100 ms poll: the same mistake fixed in the 2026-10-31 check, brought
  back by M8.2. They are now assigned only when they change. A new test fails
  on the old code. The fixed app used 2.1% with the meters hidden, within the
  one-point M8.1 budget. The owner kept the meters closed for the second
  sample, so the meters-shown figure after the fix was not measured.
- **Memory.** The engine's footprint was 17 MB (10–11 MB before). The extra is
  the planned 32-bit ring (10.6 MB instead of 5.3 MB) and the 2-second HDCD
  start-up buffers. The whole app was at 41 MB. The 28 MB baseline came from a
  test harness before the level meters existed, so it is not directly
  comparable.
- **Listening.** In the Release app the source text read "44.1 kHz · HDCD
  source" with the "no decodable features" tooltip. The owner turned Decode
  HDCD off and on, skipped tracks and made 10-second skips: no level jumps,
  clicks or dropouts. The Walkman's state matched its baseline after the check
  tools and after the app.

Still open: live decoding, its checksum against FFmpeg and the 6 dB level
difference need a disc that uses Peak Extend or gain adjustment, plus an
ordinary CD as a control. A burned test disc later covered the decoding and
the checksum; see the M8.3 follow-up below. All 437 CDKit and 29 AudioCheck
tests pass normally and with AddressSanitizer and ThreadSanitizer.

### M8.4: HDCD on the status line (2026-11-03)

After M8.3 the owner found the display misleading: an HDCD disc showed
`CD PLAYING`, and asked whether `16-bit` should follow the HDCD bit depth.
The owner chose the recommended texts.

- **Status line.** Once playback finds HDCD on the disc, `CD DETECTED`,
  `CD PLAYING`, `CD PAUSED` and `CD END` read `HDCD DETECTED`, `HDCD PLAYING`,
  `HDCD PAUSED` and `HDCD END`. VoiceOver reads "HDCD disc detected", "HDCD
  playing" and so on. HDCD lives in the audio samples, not the table of
  contents, and the app reads no audio before Play, so a new disc shows
  `CD DETECTED` until its first Play finds HDCD.
- **Source text.** An HDCD disc holds 16-bit samples; its extra resolution,
  up to 20 bits, exists only once decoded. The text now names the depth
  played: `44.1 kHz / 16-bit HDCD` unchanged, `44.1 kHz / 20-bit HDCD`
  decoded, replacing "HDCD source" and "HDCD decoded". Ordinary CDs keep
  `44.1 kHz / 16-bit source`. The tooltips name the depth too.
- **Per disc.** `PlayerModel` keeps a disc-level HDCD status: found HDCD stays
  found, and effectual outranks no effect, as in the engine, until the disc
  is ejected or changed or the drive changes. Before, every Play, skip or seek
  reset it to "detecting", and Stop followed by Play built a new engine that
  detected again. The status would have dropped back to `CD` for a moment, or
  until detection, for a run starting where no packets are near. A run still
  detecting now keeps the previous run's decoded state and output depth; a run
  with Decode HDCD off shows 16-bit at once, since it cannot decode.
- Display only: the engine, the decoding rule, the poll guards and the audio
  are unchanged. The demo disc never shows HDCD.
- **Tests.** Three new tests and two updated ones cover the status-line
  lifecycle (a new disc is a CD; found while playing; paused; a later run that
  detects or finds no packets near its start; Stop; end of disc; a replaced
  disc), the held 20-bit depth while a new run detects, 16-bit at once with
  the setting off, and the demo disc. Removing the hold makes the held-depth
  test fail. All 440 CDKit and 29 AudioCheck tests pass normally and with
  AddressSanitizer and ThreadSanitizer.

### M8.3 follow-up: live decoding on a burned test disc (2026-11-03)

Neither of the owner's HDCD discs switches Peak Extend or a gain adjustment
on, so at the owner's request a test disc was burned from FFmpeg's FATE
sample `hdcd-mix.flac`: 9 s of HDCD with gain adjustment, and Peak Extend
flagged. Its licence was not verified, so the disc, the captures and the
decodes are private test material, kept in a temporary folder and deleted.
Only text is retained, in the
[test-disc transcript](validation/hdcd-m8-3-test-disc-2026-11-03.log), which
labels each block that was re-run offline or written from notes. No code
changed.

- **Disc.** The owner inserted a CD-RW (4x), not the CD-R planned. It holds
  seven gapless tracks: the sample on tracks 1–4, 6 and 7, and, on track 5,
  3 s of digital silence followed by the sample, so that its first effect
  comes after the 2-second hold.
- **Burning.** `drutil burn -test` on the CD-RW ejected the disc despite
  `-mount` and left an empty reserved track, so the owner approved a quick
  erase (`drutil status` then reported no media for about 25 s). The real
  burn was `drutil burn -audio -pregap 0 -speed 4 -noverify -mount`; the
  `-pregap 0` keeps the tracks gapless, and reading the disc back took the
  place of drutil's verification. `drutil` did not keep the order of the
  files: the 12 s file became track 5, not track 6.
- **Read-back.** None of the seven captures (`AudioCheck --capture-pcm`) had
  a C2-flagged sector. Joined in track order they equal the burned stream
  delayed by exactly 667 frames, and the first 667 captured frames are zero.
  That is the drive's read offset, and it matches the figure usually quoted
  for Pioneer drives (not looked up for the BDR-XS07U). The engine and the
  captures read the same disc through the same drive, so the delay is common
  to both and does not affect the comparisons below.
- **External decode.** FFmpeg's `hdcd` filter and `HDCDCheck` agree byte for
  byte on all seven captures: HDCD detected, Peak Extend enabled
  intermittently, a −7.0 dB maximum gain adjustment, Transient Filter
  detected and no detectable errors. Decoding changes 31,147 of the 793,800
  samples of a 9 s track (3.92%); the others become exactly `sample × 32768`,
  the level of a decode with no effect. The first change comes at 1.456 s,
  inside the engine's hold, on the six sample tracks, and at 4.456 s, after
  it, on track 5.
- **`--hdcd-off`.** On the Walkman, the silent check passed all six segments
  (start, seek, track boundary, pause, resume, end of disc): HDCD detected,
  nothing decoded, a 32-bit physical output and checksums equal to
  independent reads. First audio took 787–791 ms, except 2,199 ms for the
  first start. The default run, with decoding on, fails by design on a disc
  that decodes, so it was not repeated.
- **Decoding.** Three silent `AudioCheck --observe` windows with decoding on,
  the app's default, each printed a rendered checksum equal to the reference
  computed offline from the FFmpeg decode of the captures:
  - **A** (`0 9`, with `--retry`): track 1 and the first 1,436 frames of
    track 2. `08378f171a72e72e` equals the external decode, and a decode
    reset at the track boundary and one continuous decode give the same
    result here. Undecoded playback would give `cd384eba3afee62e`.
  - **B** (`36 30`): track 5 to the end of the disc. Track 5 played
    undecoded, because its first effect (4.456 s) came after the hold, and
    decoding began at the track 6 boundary. `7a43ff1d860f5392` equals track 5
    undecoded followed by tracks 6 and 7, each decoded from its start.
    Decoding all three would give `367dae1579c30992`, none
    `cde0d26017b6227a`. This is the late-discovery rule, confirmed on real
    hardware.
  - **C** (`20 6`): a seek 2.0 s into track 3. `9281f049b96aaa49` equals a
    fresh decode from the window start and the continuation of the
    whole-track decode. Undecoded playback would give `9d5aefaba708f766`.
- **Intermittent concealment.** The first, single-pass run of window A
  concealed 22 sectors (LBA 2180–2201, about 2 s into track 4 and 23 s ahead
  of the play position), so `--observe` withheld its checksum, as designed.
  The window's own audio was not affected. The same sectors were not flagged
  when track 4 was captured, and the repeat with `--retry`, whose checksum
  is the one above, found nothing to retry. The unified log shows no other
  concealment between 18:00 and 19:05. The cause was not found (a marginal
  spot on the CD-RW or a transient read condition); the event happens at
  the read, before the decoder.
- **What the sample exercises.** Gain adjustment heavily, Peak Extend
  barely: of 9,115 samples at or above the Peak Extend threshold
  (|x| ≥ 0x5981), 7 changed, by at most 0.8% (25206 became 25404.27 in
  16-bit units), and no decoded sample exceeded the 16-bit range. A real
  Peak Extend disc remains the gap in the live evidence.
- **A claim corrected.** The feasibility check had said that every decoded
  value lies on a 20-bit grid. On this sample 31,140 of the 31,147 changed
  values have a bit set below 2^11, and 15,417 also have bit 0 set: libhdcd
  applies its gain at full precision. The ring holds them exactly. The
  render callback's Int32 to Float32 conversion, exact in its factor 2⁻³¹,
  rounds a value with more than 24 significant bits to Float32's 24-bit
  significand, an error far below one 20-bit step. Undecoded and no-effect
  samples have at most 16 significant bits and convert exactly. `--observe`
  checksums the ring's 32-bit values, not the Float32 output. The 20-bit
  output rule is unchanged. The roadmap and the architecture notes now say
  this.
- **Output state.** The snapshots of the Walkman, the MacBook's microphone
  and its speakers, taken before the first run and after the last, differ
  only in their capture ID and time: no rate, volume, mute, ownership or
  default device changed.

Still open: Peak Extend lifting real peaks; an ordinary CD as a control; the
Release app's status line and source text on an effectual disc; and
listening, including the roughly 6 dB lower level of decoded audio and any
level jumps. The sample is loud (its peaks reach 95% of full scale from 3 s
on and full scale in its last four seconds), so the Walkman's volume goes to
the minimum before any audible test.

### M8.3 listening check and the depth display fix (2026-11-03)

The owner listened to the burned test disc in the Release app (Walkman, volume
at the minimum, Decode HDCD on). The listening exposed a display bug, which
was fixed test-first and then confirmed on the disc with a rebuilt app. What
the owner saw and heard is marked as owner-reported; the rest comes from the
code, the tests, the captures or the unified log.

- **Listening before the fix (owner-reported; a Release app built from
  `39127c6`, which has the code of the M8.4 commit `852732f`).**
  - Track 1, decoding on: `CD DETECTED`, then `HDCD PLAYING`; source text
    `44.1 kHz / 20-bit HDCD`; clean sound.
  - Decode HDCD off on track 2, on again on track 3: `44.1 kHz / 16-bit
    HDCD`, then `44.1 kHz / 20-bit HDCD`; the decoded audio was clearly
    quieter; both clean.
  - Stop, track 5, Play, decoding on: the level dropped at the track 6
    boundary, as designed (late discovery), and track 6 read `20-bit HDCD`.
    The owner noted "at track 5 start, there was a click sound, 16-bit HDCD,
    after 2 seconds, 20-bit".
- **The display bug.** `PlaybackSnapshot.hdcdDecoded` was the producer's
  state. The producer reads ahead into a 30-second ring, faster than real
  time, so on a run from track 5 it crossed the track 6 boundary seconds
  after Play and set the flag well before the decoded audio played (the
  boundary is 12 s into the track). The owner's "after 2 seconds, 20-bit"
  fits. What the text showed during the first 2 s, the silent hold in which
  the model keeps the previous run's state, was not pinned down. The audio
  was right throughout: the render callback plays only what the producer
  wrote to the ring.
- **The fix.** The engine records the first frame it writes decoded
  (`hdcdDecodeFrame`): the run's start frame when decoding is decided at
  start-up or carried over from an earlier run on the same disc session, or
  the first frame of the track where a later switch happens. The snapshot
  reports decoded only once the playing position (`currentFrame`: the start
  frame plus the frames rendered) has reached it, so the text follows the
  audio to within one output buffer. The producer stores the frame with
  release ordering before it sets the flag, and the snapshot reads the flag
  and then the frame. The render callback is unchanged. `AudioCheck`'s
  `decoded:` line and its guard follow the same rule with no code change: the
  checksum covers only rendered frames, so a segment that stops before a
  later decode start no longer reports decoding it did not play. The
  engine's rule is covered by the offline test below; no `AudioCheck` window
  was re-run with the fix.
- **Tests.** The new test
  `decodedStateFollowsThePlayingPositionNotTheReadAheadProducer` uses three
  tracks of 88,200, 128 and 128 frames, with an effectual packet in track 2.
  It asserts not decoded at frame 0 and one frame before the boundary, with
  bit-exact undecoded audio; decoded at the boundary, with 64 decoded frames
  at the expected scale; and, after a stop and a new `prepare()`, decoded
  from frame 0. Before the fix it failed exactly the two display
  expectations. Removing the reset in `cd_playback_prepare` makes its last
  check fail (a mutation check, restored). All 441 CDKit and 29 AudioCheck
  tests pass normally, with AddressSanitizer and with ThreadSanitizer, with
  no sanitizer reports.
- **Re-test with the fix (owner-reported; a fresh process of a Release app
  built from the working tree, the burned test disc, the Walkman).** The
  disc left the drive and came back twice during the session: the system log
  (`diskarbitrationd`) records ejects at 20:10:02 and 20:12:21 and the disc
  appearing again at about 20:10:23 and 20:12:43, and the app opened three
  media IDs, 4295332407,
  4295336289 and 4295336395, the ID changing after each eject. The first is
  the ID the M8.3 observation windows used, the last has the test disc's
  table of contents (read with `OpticalCheck`), and the middle one's log
  shows runs starting at 36.12 s, the start of track 5. The ejects came from
  the app (found afterwards, offline): the persisted system log has an AppKit
  button click in CD Player 26 to 70 ms before each of the session's three
  unmount-and-eject requests (20:10:01, 20:12:21 and the 20:26:56 eject the
  owner made with the app's Eject), no request without one, and options
  matching `DiskEjectRequest` (unmount whole, then a default eject). At
  20:12:21 there were two clicks 0.53 s apart, the first logged by the app as
  a Stop; the log does not name the button, but Stop and Eject share the
  fourth button, so a quick second click ejected.
  - Track 1: `HDCD DETECTED`, `44.1 kHz / 20-bit HDCD`, no click at the
    start.
  - Track 5, decoding on: asked when the source text first read 20-bit HDCD,
    the owner chose "At the level drop when track 6 starts (the fix works)"
    over "A few seconds after the first sound, during track 5 (as before the
    fix)". The owner's notes: "Once the source text changed to 44.1kHz /
    20-bit HDCD, the audio was quiet (as per the track recorded), then the
    audio started and no click sound after playing track 6". They did not
    report the texts before the drop or a click at the start of track 5.
  - Track 3, asked about a click at the very start, about half a second of
    silence before the music, and the text: "yes, yes, 44.1 kHz / 20-bit
    HDCD".
- **The click.** The owner heard no click at the start of track 1 and a click
  at the start of track 3 (and, in the first listening, at the start of track
  5). This fits the drive's read offset, which the app does not correct
  (drive read-offset correction was left out of scope in M4). Measured: the
  captures equal the burned stream delayed by 667 frames (15.1 ms), and the
  app plays what the drive returns, so a run that starts at the start of
  track 2 to 7 begins with the last 667 frames of the track before it. On
  this disc those frames peak at 25,438 (77.6% of full scale) and start and
  end abruptly mid-waveform, while the first 667 frames of track 1 are zero.
  The sample begins with 20,137 frames of silence, so the burst is followed by
  0.457 s of silence on tracks 2 to 4, 6 and 7, and by 3.457 s on track 5.
  That matches the owner's two yes answers for track 3 (a click at the very
  start; about half a second of silence before the music), which were asked
  as questions. Play that runs across a boundary is contiguous and has no
  burst. The first listening reported tracks 2 and 3 as clean; how they were
  started was not recorded, so it is not known whether they began with the
  burst. No run without the burst was tried, so the cause is not proven. No
  code changed. On the
  ordinary CD of the control below, the owner heard no click at the start of
  track 2. A later read-only capture of that track's first second explains
  it: its leading 667 frames, the end of track 1, peak at 10.8% of full
  scale (−19.4 dBFS) and run without a break into track 2, which is already
  at −11.1 dBFS RMS in its first 100 ms, so nothing stands apart to be heard.
  On a normal album the previous track's last 15 ms is expected to
  be quiet or to continue the music, so this is expected to be rare outside
  a test disc whose tracks end abruptly at a high level.
- **Ordinary-CD control (the app side owner-reported; `AudioCheck` run
  afterwards, with the app quit).** The test disc was ejected (the system
  log records it at 20:26:56) and the owner inserted an ordinary commercial
  audio CD (10 tracks, 42:32, media ID 4295337022; the owner's copy, not
  named here, and not known to be HDCD). In the same app process:
  - The status line read `CD DETECTED`, then `CD PLAYING`, and the format
    text `44.1 kHz / 16-bit source`. No HDCD or 20-bit text was left over
    from the test disc, so the per-disc HDCD state resets on a disc swap.
  - Track 2 started from its beginning: no click.
  - App log: a run from the start paused at 15.50 s; a run resumed at 15.57 s
    and skipped to track 2 (buffering ended at 291.79 s, and track 2 starts at
    LBA 21880 = 291.73 s), paused at 298.22 s. Both summaries read `0 underrun
    frames; 0 concealed sectors`. The log has four slow raw reads (at LBA 0,
    1977, 1162 and 23195: 2.96, 2.36, 2.90 and 0.72 s), none of which caused
    an underrun.
  - `AudioCheck --activate-silent` (Release tool rebuilt from the working
    tree; Walkman; HDCD decoding on, the app's default): six segments (start,
    seek, track boundary, pause, resume, end of disc), each `HDCD: no HDCD
    packets; decoded: no; physical output 32-bit`, and each rendered
    checksum equal to the checksum of independent undecoded 16-bit reads of
    the same range. The Walkman went back to 384,000 Hz idle and unowned, the
    drive speed was restored and verified at 4233 kB/s, and no system volume
    or mute setting changed. 30.09 s of disc PCM; 1,891 reads, 1,630 kB/s
    including the reference reads. The transcript is in
    `docs/validation/hdcd-m8-3-test-disc-2026-11-03.log`.

  So an ordinary CD passes through the HDCD path untouched: no packets, no
  decoding, bit-exact undecoded output, and no HDCD text.
- **Unified log.** The app-only log of the re-test (PID 14932, 20:08 to
  20:18) shows 12 runs on the test disc, six stopped and six paused; the
  owner played more than the three asked for. The same process then played 2
  runs on the control disc. Every one of the 14 summaries ends `0 underrun
  frames; 0 concealed sectors`. The first listening (PID 95854, before the
  fix) shows 17 runs, nine stopped, seven paused and one ended, with the
  same counts. Apart from the speed-request line that each open logs at
  warning level (`Requested minimum drive speed 176 kB/s; reported 4233
  kB/s. Actual read throughput is measured separately.`), the only warnings
  in the test-disc sessions are slow raw reads, which the app logs for any
  read of 500 ms or more: six in each session, each at the start position of
  a run, 1.50 to 1.75 s (`Raw read at LBA N x7` or `x8, C2 true, succeeded
  after N ms`). The log does not record the HDCD state, so the text and
  level observations above rest on the owner's reports.
- **Screen texts on track 5 runs (screenshots, afterwards).** With the
  owner's approval, a freshly built Debug app played the test disc from
  track 5 into track 6 twice (Walkman at minimum volume) while
  `screencapture -l` took the player window about every 0.36 s. Run A, the
  first in the process: `PREPARING` and `BUFFERING` with `44.1 kHz / 16-bit
  source`; one shot of `CD PLAYING`, `16-bit source` as audio began; then
  `HDCD PLAYING`, `44.1 kHz / 16-bit HDCD` until track 6, where it read
  `20-bit HDCD`. Run B, straight after: `PREPARING` and `BUFFERING` kept the
  previous run's `20-bit HDCD`; from the first audio it read `16-bit HDCD`
  until track 6, then `20-bit HDCD`. After each Stop: `HDCD DETECTED`,
  `20-bit HDCD`. So the detection hold is spent in `PREPARING`/`BUFFERING`
  with the previous run's text, the source text reads 16-bit until the
  level drop, and on a disc not yet known as HDCD the first audio reads
  `CD` until the producer reaches track 5's first effect (it reads ahead,
  so `HDCD` showed while the opening silence still played). That is the
  designed "not yet known" behaviour; no code changed.

This closes the listening check, the check of the Release app's status line
and source text on an effectual disc, the ordinary-CD control, the screen
texts on track 5 runs, the cause of the re-test ejects and the control
track's missing click. The remaining real-program Peak Extend check is
recorded as follow-up after the synthetic offline and live validation below.

### M8.3 offline Peak Extend validation (2026-11-03)

The burned FATE sample barely exercises Peak Extend, so M8.3's remaining
offline DSP gap was tested with a deterministic synthetic signal. The focused
`HDCDPlaybackTests` case generates five seconds of phase-aligned 110 Hz
stereo PCM near full scale, with a Peak Extend control packet every 71 frames
(the packet plus decoder read-ahead interval). It verifies effectual HDCD
detection, decoded playback, a restored audio peak above 90% FS, finite
samples and no clipping.

`Tools/make-hdcd-peak-extend-test.py` creates a 10-second, 44.1 kHz stereo WAV
for a possible CD-RW test. `Tools/check-hdcd-peak-extend.sh` runs that signal
through `HDCDCheck` and FFmpeg's `hdcd` filter, compares their Int32 PCM byte
for byte, and checks the restored peak. The decoded output peaks at
1,995,068,338 / 2,147,483,648 (92.9% FS); with no Peak Extend, the
16-to-32-bit path peaks at 1,073,709,056 (50.0% FS). No clipping occurs.
The focused test, comparison script, full normal package suite, and full
AddressSanitizer and ThreadSanitizer package suites all passed.

This closes M8.3's offline Peak Extend validation under the agreed synthetic
test option. The owner then burned the generated WAV to a CD-RW; the live
read-only and silent playback evidence is in the following entry. Verification
with real-program HDCD whose musical peaks are lifted by Peak Extend remains
follow-up work. The generated burn WAV is kept outside the repository.

### M8.3 synthetic Peak Extend CD-RW live verification (2026-11-03)

After the owner burned and inserted the synthetic WAV, they approved
read-only PCM capture and silent `AudioCheck` first. CD Player was not running
for those checks. A separately approved app listening check followed. No
eject, volume change or mute change was performed.
The [text transcript](validation/hdcd-peak-extend-cdrw-2026-11-03.log) keeps
the command output and results.

- **Capture.** Drive 4295330750 (Pioneer BDR-XS07U), media 4295342691,
  track 1, sectors 0..<750. The 441,000 captured frames had no C2-flagged
  sectors. The drive reported 4233 kB/s before and after the requested
  176 kB/s; measured throughput was 448.8 kB/s. Its original speed was
  restored and verified. Captured PCM exactly matched the source after the
  established 667-frame offset, with 667 leading zero frames.
- **Independent decode.** FFmpeg and `HDCDCheck` matched byte for byte on the
  live capture. The decoded peak was 92.9% FS (1,995,068,338 /
  2,147,483,648), versus a 50.0% FS undecoded 16-to-32-bit peak, without
  clipping.
- **Silent playback path.** The standard full-disc `AudioCheck` requires at
  least 30 seconds and two tracks, so it refused this 10-second, one-track
  disc before playback. `AudioCheck --observe 0 9` on the Sony Walkman
  NW-A306 ran silently with HDCD decoding enabled, detected effectual HDCD,
  decoded on the 32-bit output and rendered frames 0..<397,824 with checksum
  `f6619b6109a04ec9`. The checksum computed from the independently decoded
  capture over the same frames was identical. There were no underruns or
  concealed sectors; playback stopped at 9.02 s, and the output returned to
  384 kHz, idle and unowned. The drive speed was restored and verified.
- **Audible app playback.** The Debug app was built and launched after a
  separate approval. Before Play it showed `44.1 kHz / 16-bit source`,
  `CD DETECTED`, WALKMAN, track 01 and 00:10. With headphones on the Walkman
  at minimum volume, the owner clicked Play, then Pause, and reported that the
  tone was audible. The app log showed the requested 176 kB/s (reported
  4233 kB/s), a first read at LBA 0 that succeeded after 1,633 ms, buffering
  ending at 0.06 s, and a pause at 3.53 s with 0 underrun frames and 0
  concealed sectors. The paused window showed `44.1 kHz / 20-bit HDCD` and
  `HDCD PAUSED` at 00:03.

This verifies the synthetic Peak Extend signal through a physical CD-RW,
drive read path, silent playback path and owner-confirmed audible app
playback with the HDCD status shown. It does not replace a real-program HDCD
listening check.

### M8 acceptance and version 1.3.0 (2026-11-03)

With M8.3 closed, the owner approved publishing version 1.3.0, which ships
M8.1–M8.4. The 442 CDKit and 29 AudioCheck tests pass normally and under both
AddressSanitizer and ThreadSanitizer, and all 20 native UI tests pass. The UI
tests ran with a separate derived-data path, so the Debug app, still open
with the synthetic CD-RW paused, was not rebuilt underneath itself.

Version 1.3.0 (build 4) is packaged as `CDPlayer-1.3.0-macOS.zip`. The
extracted app was checked for its version, macOS 14 minimum, both `arm64` and
`x86_64` architectures, valid ad-hoc signature and hardened runtime. Archive
integrity also passed. The package SHA-256 is:

```text
1af628e10d089dc5069e5c1b4203de7e028b5b551c20326f5c8303da62c82216
```

The [1.3.0 release](https://github.com/ylau674/CD-player/releases/tag/v1.3.0)
ships the accepted M8 work. Verification with real-program HDCD whose
musical peaks are lifted by Peak Extend remains follow-up. The repository
remains private, and the package is not Developer ID signed or notarized.

After publication, the owner asked for the installed copy to be updated.
With no CD Player running and no output-rate restore pending,
`/Applications/CDPlayer.app` 1.2.0 (build 3) was replaced by the app from the
1.3.0 release ZIP. The installed app reports 1.3.0 (build 4) and both
architectures. It passes strict code-signature verification with an ad-hoc
signature and the hardened runtime, and its CDHash
(`e5d425c65abb9ab57fdd700b876a5b3bab31c394`) equals the ZIP's. It has no
quarantine flag. The new ad-hoc signature may make macOS ask again for
removable-volume access at the first Play. It was not launched as part of
the update.

The GitHub Tests workflow for the tagged commit (`666dd3b`) failed before any
test ran: the runner's Swift 6.3.3 (Xcode 26.6) could not type-check, in
reasonable time, a PCM capture test that compared a `Range<UInt64>` with
untyped literal arithmetic. Swift 6.4.2 on the development Mac checks it in
under 5 ms. As with 1.1.0, the tag stayed in place and the test-only fix
followed on `main`; the app and the uploaded ZIP are unchanged. The uploaded
ZIP's SHA-256 matched the local package, and publishing waited for the fix
commit's workflow to pass.

### Version 1.3.1 (2026-11-03)

The owner asked for the meter CPU change, described under M9, to be committed,
packaged as a new release and installed. It is a patch release: the meters'
look and behaviour are unchanged, and the CI test fix already on `main`
(`d20a3f2`) ships with it. The change is commit `8d3a39c`.

Before packaging, the 448 CDKit and 29 AudioCheck tests were run again, since
only comments had changed after the last full run. They pass normally and under
both AddressSanitizer and ThreadSanitizer, and all 21 native UI tests pass.

Version 1.3.1 (build 5) is packaged as `CDPlayer-1.3.1-macOS.zip`. The
extracted app was checked for its version, macOS 14 minimum, both `arm64` and
`x86_64` architectures, valid ad-hoc signature and hardened runtime. Archive
integrity also passed. The package SHA-256 is:

```text
2d6193602f3576d91d71be55832f51fff26754db8ae8629de3514956b26a0ed4
```

With no CD Player running, no `ChangedOutputRates` record pending and the
earlier test build quit, `/Applications/CDPlayer.app` 1.3.0 (build 4) was
replaced by the app from that ZIP. The installed app reports 1.3.1 (build 5)
and both architectures. A recursive comparison finds it identical to the ZIP's
app. It passes strict code-signature verification with an ad-hoc signature and
the hardened runtime, its CDHash is `1f72f9fa40721c8d4621b04db28b4dff8bdc5435`,
and it has no quarantine flag. The new ad-hoc signature may make macOS ask
again for removable-volume access at the first Play. It was not launched as
part of the update. The installed app's meter CPU has not been measured; the
Release figures come from a build of the same code run from the build folder
before packaging.

## Playback memory (2026-11-04)

With the meters shown and CPU near 5%, the owner asked how to lower the app's
memory further.

### Measurement of 1.3.1

`footprint` on the installed 1.3.1 reported 48 MB while playing, with or
without meters, and the same 48 MB while paused. A bare SwiftUI window app
built with the same toolchain measured 25 MB. The difference was mostly:

- 10 MB of `Malloc Large`: the 30-second read-ahead ring, 1,323,000 stereo
  32-bit frames, fully written once playback had run for 30 seconds and kept
  while paused.
- About 1 MB of HDCD start-up buffers, two seconds of raw and decoded audio,
  kept for the life of the engine although they serve only the first two
  seconds of a play.
- A second playback handle. Reading the output's sample formats at launch
  went through the default (demo) engine, which created a full C playback
  handle, with its own 30-second ring, just to answer that query. The ring
  was allocated but never written, so it cost address space and Core Audio
  objects rather than footprint.

Large blocks returned by `free()` don't lower the footprint on macOS, so
freeing the ring on Pause would not have helped by itself.

### Changes

The owner chose all five options offered:

1. **Pages returned while paused or stopped.** The ring and the HDCD start-up
   buffer are now page-aligned `mmap` regions (`PageBuffer.c`). A claim of
   *n* bytes calls `madvise(MADV_FREE_REUSE)` on the pages it grows into, and
   a smaller claim calls `madvise(MADV_FREE_REUSABLE)` on the pages it gives
   up, which removes them from the footprint at once. `stop_playback` gives
   back both buffers once no producer, IOProc or converter remains; a stop
   request on its own keeps them, since the producer or render callback may
   still touch them. The next prepare claims what that play needs before
   anything writes. Under AddressSanitizer every byte outside the current
   claim is poisoned, so a stray write to a returned page fails the sanitized
   tests.
2. **HDCD start-up buffer returned once detection decides.** Prepare claims
   it only when this play will collect start-up audio, and the producer gives
   it back right after flushing that audio into the ring. A later play of the
   same disc, whose detection has already decided, claims nothing; a stop
   during detection gives it back and the next play collects again.
3. **Output inspection without a playback handle.** `CoreAudioPlaybackEngine`
   reads the output's formats with a static query (`AudioHandle.inspect`,
   passed to the worker as an `AudioOutputInspector`), so an engine creates
   its playback handle only when it first starts.
4. **15-second ring.** `CD_PLAYBACK_BUFFER_FRAMES` is 661,500 frames, down
   from 1,323,000.
5. **16-bit ring unless HDCD decoding can apply.** The ring stores Int32 only
   when this play could decode HDCD: the source is an audio CD, Decode HDCD is
   on and the output takes 20 bits or more. Otherwise it stores Int16. The
   disc's own HDCD status doesn't narrow this, because detection continues
   during play and a later track can start decoding, so a CD with no HDCD in
   its first two seconds still gets an Int32 ring. These facts are fixed for
   a play, so the width never changes mid-stream. The render path
   widens Int16 samples as `sample × 65,536`, the same value the 32-bit ring
   held, so float output, checksums and bit-exactness are unchanged. A 16-bit
   ring rejects decoded frames.

A 15-second ring is 2.6 MB at 16 bits and 5.3 MB at 32 bits, against 10.6 MB
before.

The shorter ring has a cost the owner accepted. Burst pacing's low watermark,
`min(capacity / 3, 10 s)`, is now 5 seconds, so burst reads refill after
441,000 frames are played rather than 882,000, and the drive spins up about
twice as often. A drive read that blocks for longer than the buffered audio,
now at most 15 seconds, empties the ring where the 30-second ring could have
absorbed it. Playback then underruns and buffers, and the existing 10-second
no-progress limit ends it with a read-timeout error. Read recovery is
unaffected because `ReadRecoveryBudget` already stops retrying after
2 seconds.

### Tests

New offline tests:

- `PlaybackMemoryTests`, under both read pacings: a stopped play's ring
  footprint drops to zero and is claimed again on resume, which then renders
  correctly. A stop request without a full stop keeps the pages.
- `PCMBufferTests`: 16- and 32-bit rings render every Int16 value
  identically; only a 32-bit ring accepts decoded frames; a ring claims only
  the pages its width needs and returns them on release. The planar and
  mapped render tests now run on both widths.
- `HDCDPlaybackTests`: the start-up pages are held only until detection
  decides and are not claimed again on a restart; a stop during detection
  returns them; outputs that cannot decode HDCD (16-bit, or decoding off) use
  a 16-bit ring without start-up pages. A gate holds the in-memory source so
  the test can observe memory mid-detection.
- `PlaybackLifecycleTests`: inspecting an output creates no playback handle;
  the handle is created only at start, off the main thread.

Ring-size expectations in `ReadPacingTests`, `PlaybackBufferingTests` and
`DiscReadRecoveryTests` were updated to 15 seconds. The burst test that expects
12 seconds of drive idle between refills keeps an explicit 30-second ring; a
15-second ring refills after 10 seconds.

The 457 CDKit and 29 AudioCheck tests pass normally and under both
AddressSanitizer and ThreadSanitizer, and all 21 native UI tests pass. A
one-off C probe confirmed that a write after a release is reported by
AddressSanitizer as `use-after-poison`, and that a claimed, written 1 MB
buffer counts 1 MB of footprint and 0 after release.

### Measurement

With the owner's approval, the installed 1.3.1 was quit and a Release build
of this change was run from its build folder. The owner played an ordinary
(non-HDCD) audio CD on an output that takes 20 bits or more, and `footprint`
was read at each step:

| Step | Footprint | Malloc Small | Ring pages counted |
| --- | --- | --- | --- |
| Launched, before Play | 29 MB | 17 MB | none |
| Playing, meters shown, Decode HDCD on | 39 MB | 21 MB | 5,168 KB (32-bit) |
| Playing, meters hidden | 39 MB | 21 MB | 5,168 KB |
| Paused | 33 MB | 21 MB | 0 |
| Playing, Decode HDCD off | 41 MB | 25 MB | 2,592 KB (16-bit) |
| Paused, Decode HDCD back on | 38 MB | 25 MB | 0 |

`vmmap` showed the ring's 5,168 KB mapping fully counted while the 32-bit
ring played (part resident, part compressed), exactly 2,592 KB counted with
Decode HDCD off, and no dirty pages while paused. The HDCD start-up mapping
had no dirty pages after detection decided. The ring pages are therefore
behaving as designed.

The rest of the footprint is the general heap. Malloc Small grew from 17 MB
to 21 MB with the first play and to 25 MB after the menu was used, which is
what 1.3.1 had shown. At that same heap, 1.3.1 measured 48 MB both playing
and paused; this build measured 41 MB playing with the 16-bit ring and 38 MB
paused. A `leaks` run while paused found only two 48-byte AppKit
accessibility objects (`NSAccessibilityWeakReferenceContainer`), none from
the app. The remaining gap to a bare SwiftUI window app (Malloc Small 15 MB)
is in the window and framework heap, which this change does not touch.

## Output lost at every launch (2026-11-04)

The owner reported that 1.3.1 showed `OUTPUT LOST` at every launch. Play
used the expected output, but the next launch showed the notice again.

### Investigation

- The saved output (`SelectedAudioOutputUID`) was the Sony WALKMAN on USB.
  The system log showed `usbaudiod` removing it at 00:04:09, and Core Audio
  no longer listed it. The listed outputs were MacBook Pro Speakers (the
  macOS default), an AirPlay receiver and two virtual meeting devices.
- Decision 14 names a saved output that is missing at launch. Play on the
  fallback cleared the notice but didn't save the fallback, so every launch
  found the WALKMAN missing again. This followed the specification but kept
  warning about an output the owner had stopped using.
- A bug made it worse. While the saved output is missing, the selector ticks
  the fallback. `selectOutput` ignored a choice equal to the ticked entry, so
  choosing MacBook Pro Speakers did nothing: nothing was saved and the
  notice stayed. The workaround was to choose System Default, then the
  speakers.

### Decision

The owner amended decision 14:

- Choosing the ticked entry saves it.
- While a saved wired output is missing, a successful Play on the shown
  fallback saves the fallback in its place. The notice then appears only up
  to the first Play after the output leaves. A reconnected output is no
  longer chosen again automatically; the user chooses it.

Nothing is saved in these cases:

- The saved choice is System Default. It follows macOS, and losing the
  default already pauses playback through the default-output path.
- The saved output is still listed but disabled, for example without
  44.1 kHz. It isn't lost.
- The start fails, or another action or shutdown supersedes it.

### Changes

- `PlayerModel.selectOutput` acts when the choice differs from either the
  displayed or the saved output.
- `savePreferredOutput` holds the saving step shared by a choice and by Play:
  the UID, the device name and whether the device is listed. It forgets the
  previous name first, so a device with the same name as the old one still
  saves its name.
- `togglePlayback` reads the displayed choice before starting.
  After a successful start, `adoptFallbackOutput` saves that choice only
  when:
  - the saved output is a device that isn't listed
    (`preferredOutputWasPresent == false`);
  - the choice differs from it.

  A device that returns while Play is starting counts as listed, so nothing
  is saved. A saved fallback is logged at notice level.

### Tests

In `SystemDefaultOutputTests`:

- `playOnTheFallbackForAMissingSavedOutputSavesTheFallback` replaces
  `aSavedOutputMissingAtLaunchIsNamedUntilPlayOnTheFallback`.
  - Play saves the speakers.
  - The PRO X reconnecting during and after playback doesn't take the
    selection back.
  - A new player with the same store, as at a relaunch, shows no notice.
- `choosingTheTickedFallbackSavesIt`:
  - choosing the ticked fallback clears the notice and saves it once,
    without starting playback;
  - a relaunch shows no notice.
- `playOnTheFallbackKeepsAListedButUnavailableSavedOutput` covers a saved
  output that is listed but disabled. `aFailedPlayOnTheFallbackKeepsTheMissingSavedOutput`
  covers a failed start.
- `losingSelectedWiredOutputPausesAtTheCurrentPosition` now continues:
  - Play resumes on the speakers at the same frame and saves them;
  - the PRO X returning while paused leaves the selection on the speakers.
- `aDisconnectedDefaultPausesWithOutputLost` checks that a saved System
  Default is never replaced.

In `PlayerModelTests`, `missingRememberedOutputFallsBackThenReconnectsByUID`
now reconnects without a Play first. It still covers a saved UID being
selected again when its device returns.

With the two model changes reverted, the new expectations fail, including
`OUTPUT LOST` at the relaunch in `choosingTheTickedFallbackSavesIt`, the
reported symptom. The 460 CDKit and 29 AudioCheck tests pass normally and
under both AddressSanitizer and ThreadSanitizer, and all 21 native UI tests
pass.

## Meter segments as layers (2026-11-04)

With the meters shown, the owner saw about 5% CPU against about 2% hidden,
and asked whether it could go lower. The saved 1.3.1 profile put the meters'
remaining main-thread cost, about 1.9 points of one core, mostly in AppKit
redrawing the bars. It recorded 40 `NSBezierPath` fills into a display list,
resolved each fill's colour with colour-space and headroom checks, and
rasterised the rounded paths into the backing store. The 15 Hz timer and the
read were a small share. The owner was offered three options: a layer per
segment, cheaper drawing, or a lower rate. They chose layers at the unchanged
15 Hz and approved a live before-and-after measurement.

### Changes

- `AudioLevelBarsView` keeps 40 `CALayer`s, one per segment, the L row then
  the R row. Each has a background colour and a 1 pt corner radius, and the
  render server composites them. A reading recolours only the segments whose
  lit, unlit or hold state changed. The colours are converted to `CGColor`
  once.
- Segment frames are computed only when the size or backing scale changes,
  with the same backing-aligned rects as before. `convertToLayer` converts
  them, so the flipped layout is unchanged.
- The view returns true from `wantsUpdateLayer` with an empty `updateLayer()`
  and sets `layerContentsRedrawPolicy` to `.never`. Its own layer therefore
  has no backing store, and nothing is drawn per read.
- Each segment layer's `actions` turn off implicit animations for its colour,
  bounds and position. By default Core Animation fades a hand-added layer's
  colour over 0.25 s.
- The driver, 15 Hz timer, ballistics, colours and dark, hidden and visibility
  rules are unchanged.

A spike checked the earlier reason for keeping `draw(_:)`, that
`cacheDisplay` renders only `draw(_:)`. In fact `cacheDisplay` renders the
layer tree, including hand-added sublayers, and AppKit never called
`draw(_:)` for a view that wants `updateLayer`. The UI pixel tests therefore
check the segment layers as they appear on screen and needed no rework.

### Tests

`testAudioLevelBarsReadOnTheirOwnTimerAndRedrawOnlyWhenASegmentChanges` now
also checks two things just after a falling bar changes segments: no segment
layer has an animation, and the bars view's layer has no contents. With the
segment layers' actions removed, it fails with eight `backgroundColor`
animations. The existing pixel tests pass unchanged against the layers. They
cover lit and dark bars, the peak hold's red and its width, and the scale
alignment. All 21 UI tests pass. The 460 CDKit and 29 AudioCheck tests, which
this change doesn't touch, pass normally and under both AddressSanitizer and
ThreadSanitizer.

### Measurement

With the owner's approval, the installed 1.3.1 was quit and two Release
builds ran from build folders, `main` before the change (`b19ea41`) and the
change. The owner played the same audio CD in each. `top -l 17 -s 1` on the
app process, ignoring the first sample, measured:

| Build | Meters | App CPU, mean (range) | WindowServer |
| --- | --- | --- | --- |
| Before (`b19ea41`) | Shown | 3.9% (3.0–4.5%) | 49% |
| Layers | Shown | 2.7% (2.0–3.3%) | 48% |
| Layers | Hidden | 2.0% (1.5–2.4%) | 48% |

Hidden meters were measured only with the change, since it doesn't touch
the hidden path. The meters' own cost fell from about 1.9 to about 0.7
points. In 8-second `sample` profiles, the main thread was busy for 224
samples with the old bars shown, 99 with the layers shown and 69 hidden:

- `AudioLevelBarsView.draw` fell from 17 samples to none.
- `display_if_needed` fell from 53 to 2.
- The Core Animation commit fell from 69 to 19.

Most of the remainder is the 15 Hz timer reading the meter, about 15
samples. WindowServer also composites everything else on screen, and its
CPU stayed within its noise. The owner saw the bars look and move as before.
The installed app was not updated.

### Version 1.3.2 (2026-11-04)

The owner asked for the meter change to be committed, then for a release to be
packaged and installed, and chose to publish it on GitHub too. It is a patch
release with three changes since 1.3.1, each described above:

- the playback memory reductions (`d7e8cc5`);
- saving the fallback output so `OUTPUT LOST` doesn't repeat at launch
  (`15fa7f8`);
- the meter segments as layers (`a93e78a`).

The SACD roadmap commit (`b19ea41`) is documentation only. The behaviour is
unchanged otherwise.

The 460 CDKit and 29 AudioCheck tests pass normally and under both
AddressSanitizer and ThreadSanitizer, and all 21 native UI tests pass. These
runs were on the code that was packaged; only the version, build number and
documentation changed afterwards.

Version 1.3.2 (build 6) is packaged as `CDPlayer-1.3.2-macOS.zip`. The
extracted app was checked for its version, macOS 14 minimum, both `arm64` and
`x86_64` architectures, strict signature validity with an ad-hoc signature and
the hardened runtime. Archive integrity also passed. The package SHA-256 is:

```text
63a7a34549a4234462df8baa6d75b8343740a9712e5abb634184651efd52ac76
```

With no CD Player running, no `ChangedOutputRates` record pending and the
earlier test build quit, `/Applications/CDPlayer.app` 1.3.1 (build 5) was
replaced by the app from that ZIP. The installed app reports 1.3.2 (build 6)
and both architectures. A recursive comparison finds it identical to the ZIP's
app. It passes strict code-signature verification with an ad-hoc signature and
the hardened runtime, its CDHash is `ac4a55e94d6970383fd4ef68a07e8f630048afec`,
and it has no quarantine flag. The new ad-hoc signature may make macOS ask
again for removable-volume access at the first Play. It was not launched as
part of the update. The installed app's own CPU and memory have not been
measured; the figures come from builds of the same code run from the build
folder before packaging.

## Public release (2026-11-04)

**Request.** The owner asked for a review of the considerations and risks of
making the GitHub repository public, then decided:

- The whole project belongs to the owner's personal GitHub account
  `ylau674`, and commits are authored as `ylau674`.
- The licence is Apache-2.0, chosen from the recommendation below.
- Personal data is removed, and the repository is published with fresh
  history instead of making the private one public.
- The bundle identifier moves to a domain the owner controls.
- Contributing, security and issue-template files are added.

The repository stays private until the owner changes its visibility.

### Licence

Apache-2.0 was recommended over MIT because it includes an explicit patent
grant, which matters for audio-format work such as HDCD and the planned SACD
support. It is compatible with the vendored libhdcd (BSD-2-Clause). The SACD
roadmap allows only one optional piece of third-party code, FFmpeg's DST
decoder (LGPL-2.1-or-later), and it rules out GPL code, which would force the
whole app under the GPL. MQA support would add no third-party code.

### Changes

- `LICENSE` holds the unmodified Apache-2.0 text, and `NOTICE` names the
  copyright holder and libhdcd.
- libhdcd's BSD licence requires its copyright notices, conditions and
  disclaimer in the documentation or other materials of a binary
  distribution, which the 1.x release ZIPs lacked. `App/Credits.rtf` now holds
  the licence line, the repository link and both libhdcd notices word for
  word. The standard About panel loads it automatically. It uses the system
  font and no colours, so it follows light and dark mode.
  `NSHumanReadableCopyright` was added to `Info.plist`.
- The bundle identifier changed from `dev.cdplayer.CDPlayer`, a domain the
  owner does not own, to `io.github.ylau674.CDPlayer`. The Logger subsystem,
  dispatch queue labels, the C rate-recovery domain and AudioCheck's output
  state domain use the new identifier. There is no migration code: earlier
  releases were private and installed only on the owner's Mac, whose two
  settings were copied by hand. Rate-recovery records written by 1.3.2 or
  earlier are not read by 1.3.3, so the installation was checked for none.
  The validation logs keep the old identifier, as recorded at the time.
- `Tools/package-release.sh` also checks the bundle identifier, the credits
  and the copyright string before writing the ZIP.
- `CONTRIBUTING.md`, `SECURITY.md`, a bug-report form and a pull-request
  template were added. The security policy uses GitHub private vulnerability
  reporting, and the templates ask reporters to redact device identifiers.
- Personal data was removed from the documents, one test fixture and three
  validation logs, as described at the top of this log. Product statements
  that macOS or a managed policy can refuse raw access remain.

### Tests

Two native UI-target tests check `Credits.rtf`. The first checks that it
contains both libhdcd notices from `Packages/CDKit/Sources/HDCD/LICENSE` word
for word (whitespace normalised) and the licence line. The second checks that
it uses only the system font family and sets no colours.

### Version 1.3.3 (2026-11-04)

The 460 CDKit and 29 AudioCheck tests pass normally and under both
AddressSanitizer and ThreadSanitizer, and all 23 native UI tests pass,
including the two new credits tests. Two UI tests check the output name's
scrolling, which runs only while the window is visible on screen. They failed
while the screen was locked and passed once it was unlocked.

Version 1.3.3 (build 7) is packaged as `CDPlayer-1.3.3-macOS.zip`. The script
confirmed the bundle identifier, the credits and the copyright string. The
extracted app was checked for its version, macOS 14 minimum, both `arm64` and
`x86_64` architectures, and strict signature validity with an ad-hoc
signature and the hardened runtime. It has no home-folder paths or old
identifier in its binary. The package SHA-256 is:

```text
58264988cedbc203d608efa88b9300b8eb9a8c4533bb8920a14cf62cd234f311
```

The source was first committed to the private repository, which was then
renamed `ylau674/CD-player-archive` with its releases 1.1.0–1.3.2 and tags
from `v1.0.0`. A new private `ylau674/CD-player` received one parentless
commit with the identical tree, authored and tagged as `ylau674` in UTC. Its
offline Tests workflow passed, the uploaded asset's digest matched, and the
release was published. In the local clone, the old branch is `archive-main`
on remote `archive`, which fetches no tags. The old tags were deleted locally
so that pushing tags cannot send the private history to the new repository.

With no CD Player running and no `ChangedOutputRates` record pending,
`/Applications/CDPlayer.app` 1.3.2 (build 6) was replaced by the app from the
ZIP. The installed app reports 1.3.3 (build 7), both architectures and the new
identifier. It is identical to the ZIP's app, passes strict code-signature
verification with an ad-hoc signature and the hardened runtime, has CDHash
`673ae70b926e214dcc23379f5e67bdbe68473faa`, and has no quarantine flag. The
owner's settings (the chosen output, Decode HDCD and the window frame) were
copied from the old preferences domain to the new one, and the old domain was
left in place. macOS is expected to ask again for removable-volume access at
the first Play. The app was not launched as part of the update.

## M10: SACD

The draft scope, design and proposed sub-milestones are in the
[SACD roadmap](SACD_ROADMAP.md).

### M10 planning and feasibility spike (2026-11-04)

**Request.** The owner put a burned SACD ISO disc (DVD+R) in the Pioneer
BDR-XS07U and asked for a milestone to play SACD discs by converting DSD to
PCM. The disc and the decoder were to be handled in-house where possible,
with another open-source decoder only where that is really impossible.

**Disc analysis.** With the owner's approval, a read-only Scarlet Book parser
read the unmounted `/dev/rdisk4`:

- It found a complete stereo-only image: plain DSD 3-in-14 at 2.8224 MHz.
- It has 10 tracks, 42:42.61 in all, in audio sectors 549–897533.
- It carries no disc or track text.
- A MusicBrainz fuzzy TOC lookup returned a false positive, so the album is
  unidentified.

The app shows the disc as `NOT AUDIO CD`, because detection uses only the
registry and treats all non-CD media as `.other`.

**Open-source survey.** Licences were checked in the source files:

- **sacd-ripper:** GPL-2.0-or-later. Its bundled DST decoder is the
  Philips/ISO reference code, whose notice permits use only in
  MPEG-4-conforming products.
- **Kodi `audiodecoder.sacd`:** GPL-2.0-or-later.
- **foo_input_sacd and `libdsdpcm`:** LGPL-2.1-or-later.
- **dsd2pcm:** BSD-2-Clause.
- **FFmpeg's `dstdec.c`:** LGPL-2.1-or-later, and the only independent
  open-source DST decoder.

**Owner decisions** (2026-11-04):

- scope limited to SACD images burned to DVD±R or BD-R;
- 24-bit output at 88.2 kHz, falling back to 44.1 kHz from the app's own
  converter;
- full modulation at 0 dBFS, so the SACD reference is −6 dBFS and nothing
  clips;
- the TOC read only on Play.

**Spike.** The owner approved one read-only capture of 10 s from track 1,
with CD Player and the check tools not running.

- **Sector layout:** confirmed and recorded in the roadmap. All 750 frames
  were complete, with consecutive timecodes.
- **Read rate:** stereo plain DSD needs 700 KiB/s. Reads ran at 1.70× real
  time, then 1.11× after requesting the DVD minimum speed. The drive still
  reported 11,080 KiB/s, so the minimum-speed policy needs measuring before
  it is fixed.
- **Converter:** an in-house two-stage converter in plain C, using
  Kaiser-windowed sinc filters (96 taps with byte tables, then 216 taps ÷4):
  - It is flat to within ±0.00001 dB up to 30 kHz, −3 dB at 36.0 kHz, and
    rejects at least 129 dB wherever aliases could land.
  - It used 1.58% of one M4 Pro core.
- **FFmpeg comparison** (FFmpeg 7.1.1's DSDIFF demuxer and `dsd_msbf`
  decoder):
  - Identical level, so FFmpeg also maps full modulation to 0 dBFS.
  - A 20 Hz–20 kHz residual of −93.0 dB (left) and −87.8 dB (right) relative
    to the music, at most −117 dBFS in any band.
  - Stage 1 matched FFmpeg's DSD-to-PCM stage to −120 dB.
- **Word length:** rounding to 24 bits adds −149.3 dBFS of error, far below
  DSD's own noise, so no dither is needed.

The captures and decoded audio were deleted after comparison; the spike tools
are scratch files outside the repository. Plain-DSD playback is therefore
feasible entirely in-house. DST is untested because no DST disc is available.

**Status.** No app code changed; only documentation was added. M10 awaits
implementation approval and the open decisions listed in the roadmap.
