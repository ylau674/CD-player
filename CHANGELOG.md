# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## [Unreleased]

### Changed

- The player panel's background defaults to 70% transparent. View › Background
  Transparency adjusts it live from 0% to 90% and remembers the level across
  launches. Text, buttons, the border and audio-level meters keep their
  existing appearance. The slider view is created only when the menu first
  opens. Reduce transparency makes the background solid and disables the
  adjustment without changing the saved level.

## [1.3.3] - 2026-11-04

First public release. Versions before 1.3.3 were developed in a private
repository; their entries are kept below, but their tags and release
downloads are not published here.

### Added

- CD Player is licensed under the Apache License, Version 2.0, with a
  `NOTICE` file, contributing guidelines, a security policy, and issue and
  pull request templates.
- **CD Player › About CD Player** shows the copyright, the licence and the
  full BSD notices of the vendored libhdcd decoder, which its licence
  requires in binary distributions.

### Changed

- The bundle identifier is now `io.github.ylau674.CDPlayer`, replacing
  `dev.cdplayer.CDPlayer`. Settings saved by earlier versions (the chosen
  output and Decode HDCD) are not carried over, and macOS asks again for
  access to removable volumes at the first Play. Log subsystem and queue
  labels use the new identifier. Playback and output are unchanged.
- Device serial numbers, output UIDs, network addresses and computer names
  are redacted from the documentation and validation logs.

## [1.3.2] - 2026-11-04

### Changed

- CD Player uses less memory. The read-ahead buffer returns its memory to
  macOS on Pause and Stop and holds 15 seconds instead of 30. It stores 16-bit
  samples when HDCD decoding cannot apply: with Decode HDCD off or an output
  below 20 bits. The HDCD start-up buffer is returned once detection decides,
  and checking the output's formats no longer sets up a playback engine.
  Output stays bit-exact. A Release build playing a CD measured 41 MB, and
  38 MB paused, where 1.3.1 measured 48 MB for both. With burst reading the
  drive refills about twice as often. A stalled drive read now empties the
  buffer after at most 15 seconds instead of 30; playback then shows
  buffering, and stops with a read error if the stall lasts 10 seconds more,
  as before.
- When the saved output is missing, pressing Play on the fallback the output
  selector shows now saves that fallback. Before, the fallback lasted only for
  that session, so every launch showed `OUTPUT LOST` again until the missing
  output returned. A reconnected output is no longer chosen again
  automatically after Play on the fallback; choose it in the output selector.
  A saved System Default, or a saved output that is listed but unavailable,
  is kept as before.
- The audio level meters use less CPU again. Each segment is now its own
  Core Animation layer, recoloured only when its state changes, so the app no
  longer redraws the bars about 15 times a second. With the meters shown, a
  Release build playing a CD measured 2.7% of one core, down from 3.9%; with
  them hidden it measured 2.0%. The meters' look, ballistics and rate are
  unchanged.

### Fixed

- Choosing the ticked output while `OUTPUT LOST` was shown did nothing. The
  selector ticks the fallback for a missing saved output; choosing it now
  saves it and clears the notice.

## [1.3.1] - 2026-11-03

### Changed

- The audio level meters use much less CPU. With the meters shown, a Release
  build playing a CD measured 4.2% of one core, down from 12.5%; with them
  hidden it stays at 2.2%. A 15 Hz SwiftUI timeline had updated and laid out
  the whole player view on every frame. An AppKit view now draws the bars on
  a plain 15 Hz timer and redraws only when a segment changes. The meters'
  look, ballistics and rate are unchanged.

### Fixed

- The offline test suite compiles again on GitHub's runner. Its Swift 6.3.3
  ran out of time type-checking one PCM capture test's expected range, written
  as untyped literal arithmetic; the range now uses typed constants. The app
  is unchanged.

## [1.3.0] - 2026-11-03

### Added

- M8.1 producer-side HDCD detection and decoding with pinned BSD-licensed
  libhdcd. Effectful packets are decoded only for physical outputs reporting
  at least 20 bits; ordinary CDs and no-effect HDCD sources remain bit-perfect.
  Detection is held for the startup window, and later activation waits for a
  track boundary or seek. The ring now carries Int32 PCM; the HAL callback
  remains allocation-free and only converts to Float32.
- A developer-only FFmpeg FATE cross-check that verifies libhdcd output
  against FFmpeg's `hdcd` filter bit for bit using temporary files.
- Playback › Decode HDCD, enabled by default and remembered between launches,
  plus HDCD source/decoded display text and explanatory tooltip and VoiceOver
  labels. The preference takes effect on the next Play, track start or seek.
- Developer-only `AudioCheck --capture-pcm`, which copies a stretch of one
  stereo track, read-only at the drive's minimum speed, into a new WAV file
  for analysis. It plays nothing and never overwrites a file. It was used to
  analyse an HDCD disc for M8.
- M8.3 diagnostics: the silent `AudioCheck` run takes `--hdcd-off` and reports
  each segment's HDCD state, physical output depth and time to first audio;
  `--observe` also prints the final run's rendered checksum and frame range,
  for comparison with an external decode. `HDCDCheck --seek-gaps` measures
  the audio between a decoder reset and the next HDCD packet.

### Changed

- The HDCD roadmap (M8) is approved. Its N-50 notes now follow the N-50
  manual: the USB input takes 16-, 24- and 32-bit PCM.
- M8.3 live verification with the owner's HDCD disc, whose packets switch
  nothing on, is recorded in the roadmap and a text-only transcript. It plays
  bit-perfect on the Walkman NW-A306, which macOS drives at 32-bit integer.
- M8.3 live verification of decoding, on a CD-RW burned from FFmpeg's HDCD
  test sample (heavy gain adjustment; Peak Extend flagged but barely used) and
  run silently on the Walkman. The engine's decoded output equalled an
  independent FFmpeg decode bit for bit over a disc start, a track whose
  effect starts after the 2-second hold and a mid-track seek. The roadmap,
  development log and a text-only transcript record it; there is no
  behaviour change. A real-program disc where Peak Extend lifts musical
  peaks remains follow-up.
- M8.3 live listening and control on the same disc and drive. The owner heard
  clean audio, read the expected status line and source text, and found the
  decoded audio clearly quieter than the undecoded. An ordinary commercial CD,
  tried as a control, read `CD DETECTED`, `CD PLAYING` and `44.1 kHz / 16-bit
  source` with no HDCD text left over, and the silent `AudioCheck` run on it
  passed all six segments. The listening also found the depth display bug
  listed under Fixed, and a click at some track starts, which fits the drive's
  read offset (667 frames, 15 ms, not corrected; see the README's Known
  limitations). Nothing changed for the click.
- M8.3 follow-up checks, with no behaviour change: screenshots of two runs
  from track 5 of the test disc show the start-up hold spent in `PREPARING`
  and `BUFFERING` with the previous run's text, and a 16-bit source text
  until the level drop at track 6; the system log ties the two unexplained
  ejects in the re-test to clicks in the app; and a read-only capture shows
  why the ordinary CD's track 2 had no click (the previous track's last 15 ms
  peak at 10.8% of full scale and run straight into the music).
- M8.3 synthetic offline Peak Extend validation: a sustained near-full-scale
  test signal restores a 92.9% FS peak without clipping, and `HDCDCheck`
  matches FFmpeg bit for bit. Normal, AddressSanitizer and ThreadSanitizer
  package test runs pass. A synthetic CD-RW then passed read-only capture and
  silent playback verification: the capture matched the source after the
  drive's read offset, and the rendered checksum matched an independent
  decode. The owner then heard it in the app, which showed
  `44.1 kHz / 20-bit HDCD` with no underruns or concealed sectors. Live
  listening verification with real-program HDCD remains follow-up.
- The architecture notes now say that the Int32-to-Float32 conversion rounds
  libhdcd's gain-adjusted results to 24 bits, and the roadmap no longer claims
  that they lie on a 20-bit grid; the test disc showed they do not.
- The README's CPU and memory figures are the M8.3 Release measurement of the
  whole player with the meters hidden: about 2% of one core and 41 MB.
- Once playback finds HDCD, the status line reads `HDCD DETECTED`,
  `HDCD PLAYING`, `HDCD PAUSED` or `HDCD END` instead of `CD …`, until the
  disc is ejected or changed. The source text names the depth an HDCD disc
  plays at, `44.1 kHz / 16-bit HDCD` unchanged or `44.1 kHz / 20-bit HDCD`
  decoded, instead of `HDCD source` or `HDCD decoded`. A later Play, skip or
  seek keeps both while that run detects again.

### Fixed

- PCM capture file creation runs on its worker queue. Failed cleanup is
  reported explicitly, and zero-progress file writes fail instead of looping.
- The player no longer redraws its window and menus on every 100 ms playback
  poll while an HDCD disc plays. The HDCD source state was reassigned even
  when unchanged, raising Release CPU from about 2% to 7%.
- The silent `AudioCheck` run compares its checksum with the engine's 32-bit
  rendered samples, so it no longer fails on correct playback.
- The source text's depth for an HDCD disc follows the audio being played. On
  a run whose decoding starts at a later track (a late discovery), it read
  `20-bit HDCD` seconds before that track played, because the engine reported
  the read-ahead producer's state. The engine now records the first decoded
  frame and reports decoding only once playback reaches it. The
  `AudioCheck` line `decoded:` follows the same rule. The audio and the
  decoding rule are unchanged.

## [1.2.0] - 2026-11-03

### Added

- Internal source-peak capture and a lock-free 10 ms level table for the
  audio-level meters, plus a latency-aware Swift meter model with source
  readback, 1.5 s peak hold and 20 dB/1.7 s fall. View › Show Audio Levels
  (⌘L) animates the window's bottom edge down to show LED-style meters below
  the transport buttons, with the peak-hold segment in the power icon's red,
  and back up to hide them; Reduce Motion fades the meters instead. The
  meters measure only once fully shown, and stay dark while the window
  extends or shrinks. They also stop measuring when the window is hidden,
  miniaturized, fully occluded or off-screen, then resume with a fresh reading
  when visible again. They refresh at up to 15 Hz. The meter's accessibility
  element is exposed to VoiceOver only while the meters are shown.

### Fixed

- Window › Minimize (⌘M) works for the borderless player. Meter reads stop
  while minimized and resume on restoration without stopping playback.
- Offline tests no longer use the host Mac's audio outputs, saved output,
  rate-recovery record, volume, sleep or power services. One output-description
  test had failed on GitHub's runner because of the runner's audio devices.

## [1.1.0] - 2026-11-02

### Added

- Selection of wired Core Audio outputs by persistent device UID, plus an
  opt-in System Default route for Bluetooth, AirPlay and other macOS outputs.
- Output-type icons and scrolling long output names.
- Read-only `AudioCheck` configuration snapshots and offline before/during/after
  checks for complete stream formats, rates, protected controls and other
  captured wired devices. These commands do not activate playback or recover
  application preferences.
- `AudioCheck --recover-output-rates` and a `crashed` verification phase for
  testing that output rates and stream formats saved before a killed silent
  run are restored the way the app restores them at launch.

### Changed

- Built-in output discovery skips built-in devices without a stereo output,
  such as the input-only microphone, instead of failing before finding the
  speakers.
- Missing outputs are identified in the player; playback pauses and does not
  resume by itself when the output returns.
- Volume keys are mirrored to a directly selected non-default output when
  both outputs expose host volume controls.
- The source format (sample rate, bit depth and channels) now comes from the
  disc's table of contents instead of fixed 44.1 kHz / 16-bit constants. The
  output rate, format checks and labels follow it. Audio CDs play exactly as
  before. A disc whose table of contents declares four-channel audio is
  refused with an explanation instead of being played as stereo.
- CI uses `actions/checkout@v7`, which runs on Node 24.
- The documentation records the GitHub repository and the CI toolchain.
- The Gatekeeper instructions now cover macOS 15 and later, where Open Anyway
  replaces Control-click › Open. A new guide covers testing on another Mac.

### Fixed

- An output whose resting bit depth differs from the playback format, such
  as a Pioneer N-50 over USB at 48 kHz 16-bit, gets that bit depth back after
  playback. Previously a needless virtual-format write let macOS replace it
  with 32-bit.
- Sleeping while a CD plays on a USB output, such as the N-50, no longer
  shows an audio error. macOS holds the output's format change until wake,
  so the app now finishes putting the output back after wake.
- Output recovery preserves the original physical bit depth when virtual and
  physical formats are coupled by a USB DAC.
- HDMI and DisplayPort playback starts with one second of silence so the
  receiver can lock before the first CD sample.

## [1.0.0] - 2026-10-31

The first complete version, accepted on a MacBook Pro with a Pioneer
BDR-XS07U USB drive.

### Added

- Borderless player window with a single display:
  - Track number and elapsed time, or the track count and total time.
  - A status line and the source format.
  - A status-line icon that shows and switches the output sample rate.
- Transport:
  - Previous and Next. Hold either to skip 10 seconds back or forward.
  - Play/Pause.
  - Eject, which becomes Stop while playing.
  - A power icon to quit.
  - Keyboard shortcuts and VoiceOver actions.
- Optical drives:
  - Discovery through IOKit and Disk Arbitration, including hot-plug.
  - Track tables read from registry metadata, with no mounting required.
  - Selecting between several drives.
  - Eject that unmounts first, without force.
- Playback:
  - Read-only raw-device reads, started only by Play.
  - A best-effort minimum drive speed (176 kB/s), restored afterwards.
  - A 30-second buffer with a 2-second start gate and automatic recovery
    from underruns.
- Audio:
  - Shared built-in output at 44.1 kHz with exact Int16 to Float32
    conversion.
  - No resampling, EQ, dither or gain, and no change to the system volume.
- Damaged discs: C2-aware single-pass reading, with interpolation of flagged
  samples and silence for unreadable sectors, counted on the display. A
  hybrid retry policy is available to the hardware check tool.
- Hardening:
  - Keeps the Mac awake while playing, and pauses before sleep.
  - Pauses when the output changes.
  - Restores the output sample rate after a crash.
  - Hot-unplug safety.
- Demo mode with a simulated three-track disc of test tones.
- Hardware check tools `AudioCheck` and `OpticalCheck`, and the `cdprobe`
  reference probe.
- App icon, a universal Release build with the hardened runtime, ad-hoc
  signing, and `Tools/package-release.sh`.
- 295 offline tests, passing normally and under AddressSanitizer and
  ThreadSanitizer.
- Documentation for continuing development:
  - [architecture](docs/ARCHITECTURE.md);
  - the [development guide](docs/DEVELOPMENT.md);
  - the [publishing checklist](docs/PUBLISHING.md);
  - the full [behaviour specification and development log](docs/DEVELOPMENT_LOG.md).
- A GitHub Actions workflow that runs the offline test suite on macOS.

[Unreleased]: https://github.com/ylau674/CD-player/compare/v1.3.3...HEAD
[1.3.3]: https://github.com/ylau674/CD-player/releases/tag/v1.3.3
