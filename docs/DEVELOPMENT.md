# Development guide

This guide covers everything needed to continue developing CD Player on
another Mac: setup, daily commands, hardware checks and their safety rules,
the release steps, the process the project followed, and the open backlog.

## Set up a new Mac

1. Install **Xcode** from the App Store, open it once to install its
   components, then select it and accept the license:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   ```

   Version 1.0.0 was developed with Xcode 27.1 (Swift 6.4) on macOS 27.2.
   The offline suite also passes in CI with Xcode 26.6 (Swift 6.3.3). The
   package and app use the Swift 6 language mode and target macOS 14.
2. Install [Homebrew](https://brew.sh) if necessary, then **XcodeGen**:

   ```sh
   brew install xcodegen
   ```

3. Clone and verify:

   ```sh
   git clone https://github.com/ylau674/CD-player.git
   cd CD-player
   swift test --package-path Packages/CDKit     # Offline tests, no hardware needed
   xcodegen generate
   xcodebuild -project CDPlayer.xcodeproj -scheme CDPlayer \
     -configuration Debug -derivedDataPath build build
   open build/Build/Products/Debug/CDPlayer.app
   ```

`CDPlayer.xcodeproj` is generated from [project.yml](../project.yml) and is
not committed. After adding, removing or renaming files under `App/`, or
changing build settings, edit `project.yml` and run `xcodegen generate` again.
Files inside `Packages/CDKit` are picked up by Swift Package Manager
automatically.

There are no secrets, signing certificates or third-party packages to install.
The pinned BSD-licensed libhdcd C source is vendored in
`Packages/CDKit/Sources/HDCD`, including its `LICENSE` and `AUTHORS`. The app
is signed ad hoc (`CODE_SIGN_IDENTITY "-"`) on every machine.

## Daily commands

| Task | Command |
|---|---|
| Offline tests | `swift test --package-path Packages/CDKit` |
| One suite or test | `swift test --package-path Packages/CDKit --filter DiscReadRecoveryTests` |
| AddressSanitizer | `swift test --package-path Packages/CDKit --sanitize=address` |
| ThreadSanitizer | `swift test --package-path Packages/CDKit --sanitize=thread` |
| HDCD decoder cross-check (downloads temporary FFmpeg FATE sample) | `./Tools/check-hdcd-ffmpeg.sh` |
| Synthetic Peak Extend / FFmpeg cross-check | `./Tools/check-hdcd-peak-extend.sh` |
| Native UI tests (31, no audio or disc access) | `xcodebuild -project CDPlayer.xcodeproj -scheme CDPlayer -configuration Debug -derivedDataPath build -destination 'platform=macOS' test` |
| Generate the Xcode project | `xcodegen generate` |
| Debug app | `xcodebuild -project CDPlayer.xcodeproj -scheme CDPlayer -configuration Debug -derivedDataPath build build` |
| Release ZIP | `./Tools/package-release.sh` |
| Live logs | `log stream --level info --predicate 'subsystem == "io.github.ylau674.CDPlayer"'` |
| Sleep assertion while playing | `pmset -g assertions \| grep "Playing an audio CD"` |
| Pending rate-recovery record | `defaults read io.github.ylau674.CDPlayer ChangedOutputRates` |
| Memory of the running app | `footprint CDPlayer` |

The test suite uses Swift Testing (`import Testing`). It uses no audio device
and no optical drive, and makes no sound: every hardware boundary
(`CDSectorSource`, `OpticalDriveService`, `PlaybackEngine`,
`OutputRateControl`, `OutputSelectionStore`, `VolumeMirroring`,
`SystemPowerMonitoring`, `SleepPreventing`, `DiscOpener`) has a fake in
`Tests/CDKitTests`. A full run takes about 20 seconds after building. Before
every commit that changes code, run all three (normal, ASan, TSan). The ring
and HDCD start-up buffers return their pages to macOS when unused, and ASan
poisons any byte outside the current claim, so the sanitized run also catches
a write to a returned page.

Create players in tests with `PlayerModel.offline(engine:…)`, never
`PlayerModel(…)`. The initializer's defaults are the real Mac services. With
them, results depend on the machine's audio outputs (one test failed on
GitHub's runner this way), and shutting a player down can restore output rates
recorded by the installed app. Only a few tests create a real service
directly, to check that it fails safely without hardware.

Xcode may print CoreDevice or CoreSimulator plugin warnings during
`xcodebuild`. They are harmless for a macOS-only build.

The native UI tests compile the app's actual views in a separate unit-test
bundle. Run `xcodegen generate` first. They briefly display fixture windows
and an output menu, exercising AppKit and accessibility in-process rather
than sending synthetic input to another app. Test screenshots are attached
to the Xcode result bundle under `build/Logs/Test/`. A graphical login session
with the screen unlocked is needed: the output-name scrolling tests fail while
the screen is locked, because scrolling runs only while the window is visible.
No automation permission, optical drive or audio output is used.

## Hardware checks

The `AudioCheck` and `OpticalCheck` tools in `Packages/CDKit` exercise the real
drive and output. Add `-c release` to `swift run`, or use
`Packages/CDKit/.build/{debug,release}/<tool>` after building.

| Command | Effect |
|---|---|
| `swift run --package-path Packages/CDKit OpticalCheck` | Lists drives, media, TOCs and timelines. Registry only, no disc reads. |
| `… OpticalCheck --watch 10` | Also prints drive and disc notifications for 10 s. |
| `… AudioCheck` | Inspects the built-in output, read-only. Does not start audio. |
| `… AudioCheck --list-outputs` | Lists output names, transports, UIDs and basic capabilities, including whether macOS can set the output's volume ("host volume"), read-only. |
| `… AudioCheck --system-default` | Read-only inspection of macOS's current default output, including reported stream latency. Run during playback; idle latency may be zero. |
| `… AudioCheck --output-uid "<UID>"` | Inspects that wired output, read-only. Does not start audio. |
| `… AudioCheck --capture-output-state <new.json>` | Captures rates, complete formats, advertised capabilities and exposed controls of wired devices; getters only, no preferences access. |
| `… AudioCheck --verify-output-state before <before.json> --output-uid "<UID>"` | Checks baseline prerequisites from JSON only. |
| `… AudioCheck --verify-output-state <during\|after> <before.json> <observed.json> --output-uid "<UID>"` | Compares saved snapshots offline; never starts audio or restores settings. |
| `… OpticalCheck --read-check <drive-id>` | Reads sectors, probes C2 and sets, then restores, the minimum speed. |
| `… AudioCheck --capture-pcm <drive-id> <track> <start-s> <secs> <new.wav>` | Developer-only: copies up to 600 s of one stereo track, read-only at the minimum speed, into a new 16-bit WAV for analysis such as FFmpeg's `hdcd` filter. Plays nothing; never overwrites; the file holds the disc's audio, so delete it afterwards. |
| `… AudioCheck --disc <drive-id> --activate-silent` | Full silent pipeline: real disc reads, output at 44.1 kHz, zero-valued samples, PCM checksum compared. Each segment also reports the HDCD state, the output's physical bit depth and the time to first audio. |
| `… AudioCheck --output-uid "<UID>" --disc <drive-id> --activate-silent` | The same check on the selected wired output; verifies its UID and restores its rate after each segment. |
| `… AudioCheck --disc <drive-id> --activate-silent --hdcd-off` | The same check with HDCD decoding off, for comparing startup with the default. A segment that was decoded fails the default run, because its checksum cannot match the disc; rerun with this flag. |
| `… AudioCheck --disc <drive-id> --activate-silent --observe <start-s> <secs> [--retry]` | Silent run over a stretch of a damaged disc, reporting buffering, concealment and slow reads. Also reports the HDCD state and, when the final run was undamaged, its rendered checksum and exact frame range, for comparison with an external decode. |
| `… HDCDCheck --seek-gaps <input.s16le> [step-s]` | Developer-only, offline: resets the decoder every `step-s` (default 0.37 s) of raw 16-bit PCM and reports how much audio passes before the next HDCD packet. Strip the 44-byte header from a `--capture-pcm` WAV first (`tail -c +45`). |
| `… OpticalCheck --eject <drive-id> --watch 2` | **Physically ejects** the disc. |

`<drive-id>` is the registry ID that `OpticalCheck` prints.
Use the UID printed by `AudioCheck --list-outputs`, quoted because it may
contain spaces. `--output-uid` also applies to `--observe` and
`--compare-pacing`; without it, the tool retains the built-in output rule.
The silent check requires an idle, unowned output and preserves volume and
mute. A matching callback checksum verifies the app's consumed CD PCM, not
the digital samples received by the DAC or audible channel placement.
The engine renders 32-bit samples, so the checksum covers each undecoded
16-bit sample shifted left by 16. To check decoding on an HDCD disc whose
packets enable Peak Extend or gain adjustment, capture the frames that
`--observe` reports, decode the capture from the same start with
`HDCDCheck` or FFmpeg's `hdcd` filter (`-c:a pcm_s32le`), and compare the
FNV-1a checksum of the decoded bytes.

Neither of the owner's HDCD discs enables either feature, so decoding was
checked on a CD-RW burned from FFmpeg's FATE sample `hdcd-mix.flac`, for
private use only: the disc, its captures and decodes are never committed (the
[transcript](validation/hdcd-m8-3-test-disc-2026-11-03.log) keeps text only).
To repeat it:

- Make bit-exact 16-bit/44.1 kHz stereo AIFFs of the sample, plus one with 3 s
  of silence ahead of it, whose effect starts after the 2-second hold. Burn
  them gapless: `drutil -drive <n> burn -audio -pregap 0 -speed <x> -noverify
  -mount <folder>`. A burn is a hardware step, so ask the owner first, and
  never erase a rewritable disc without asking.
- `drutil` did not keep the order of the files, so check the track lengths
  with `OpticalCheck`. Do not use `-test` on a CD-RW: it ejected the disc
  despite `-mount` and left an empty reserved track.
- The drive's read offset delays the read-back (667 frames here). It does not
  matter for the comparison, because the engine and `--capture-pcm` read
  through the same drive. It does reach the listener: the app plays what the
  drive returns and does not correct the offset, so a run that starts at the
  beginning of a track plays the previous track's last 667 frames (15 ms)
  first. On this disc that is a burst peaking at 77.6% of full scale, then
  0.46 s of silence, and the owner heard a click at some track starts. A run
  across a boundary has no such burst: the stream is contiguous there.
- Compare each `--observe` window with a reference chained across the tracks
  it plays: decoded from each track's start (the decoder resets at every
  track boundary and seek), except a track whose effect appears after the
  hold, which plays undecoded (`int16 << 16`) and is decoded from the next
  track. The tool prints no checksum for a run with a concealed sector; run
  it again, with `--retry` if needed.
- The sample is loud: its peaks reach 95% of full scale from 3 s on and full
  scale in its last four seconds. Keep every check silent, or set the
  output's volume to the minimum before any audible test.

Safety rules followed throughout development:

- **Ask before any live hardware step.** Reading a disc, changing the drive
  speed, activating the output, ejecting, and installing into
  `/Applications` all need the owner's explicit approval. The owner performs
  every physical action: inserting, unplugging and listening.
- **One process per drive.** Never run `AudioCheck` or `OpticalCheck` on a
  disc that the app is playing. Two readers compete for the drive, and the
  tool's output-rate restore pauses the app.
- Avoid silent output checks during calls, because they temporarily set the
  output to 44.1 kHz.
- Never add mounting, SCSI pass-through, privilege elevation, forced eject or
  any workaround for a policy refusal.

### Output configuration snapshots

Use the Release `AudioCheck` binary after building it with:

```sh
swift build --package-path Packages/CDKit -c release --product AudioCheck
```

Below, `AudioCheck` means `Packages/CDKit/.build/release/AudioCheck`. Keep the
new mode flag first and the argument order exactly as shown; mixed playback,
disc or retry flags, duplicate options and unknown phases are rejected.

For M6.3b, connect and inspect one output at a time: PRO X, then Sony USB DAC,
then HDMI. The owner performs the physical actions. Capture and comparison
do not grant permission for an activation test.
Repeat the before capture after reconnecting and immediately before any
separately approved activation. An earlier discovery preflight is not a
substitute for the live test's fresh baseline.

**Before, read-only:** store each run's JSON files in a new directory outside
the repository. Captures refuse to overwrite existing files. A capture makes
two matching property-read passes; changing configurations or unexpected HAL
errors fail explicitly instead of producing an apparently valid snapshot.

```sh
AudioCheck --capture-output-state /path/to/run/before.json
AudioCheck --verify-output-state before /path/to/run/before.json --output-uid "<UID>"
```

The capture prints device UIDs, current virtual and physical ASBDs, settable
flags, and the advertised stereo pair, if any. The JSON also contains full
format/rate ranges, input streams and exposed volume, mute, clock-source,
clock-domain and data-source values. Missing optional properties are recorded
as unexposed, not guessed. Built-in, USB, HDMI, DisplayPort and Thunderbolt
devices are captured; virtual and wireless devices are outside this snapshot
scope, but the default input/output/system-output UIDs are recorded.

The baseline check requires an idle, alive, unowned wired output, nominal
44.1 kHz support, and writable properties where the UID-targeted route would
need setters. An advertised format and a writable flag do not prove that a
future setter will succeed. This verifier models `--output-uid`, not the
app's separate Built-in or System Default selection.

**During a separately approved silent run:** while the target is actually
running, take a new read-only sample and compare it:

```sh
AudioCheck --capture-output-state /path/to/run/during.json
AudioCheck --verify-output-state during /path/to/run/before.json /path/to/run/during.json --output-uid "<UID>"
```

It requires 44.1 kHz, a running target and the exact advertised stereo
virtual/physical pair selected from the baseline. Without such a pair, it
checks compatible native PCM and retained channel counts. It also checks
ownership, exposed controls, preferred channels, input streams, default
routes and the other captured wired devices for unexpected changes.

**After the approved run has stopped:** capture again and require full
restoration, not just the nominal rate:

```sh
AudioCheck --capture-output-state /path/to/run/after.json
AudioCheck --verify-output-state after /path/to/run/before.json /path/to/run/after.json --output-uid "<UID>"
```

All ASBD fields, rate, idle/ownership state and protected controls must match
the baseline. A baseline already at a user-kept 44.1 kHz must remain there.
Devices are matched by UID and streams by direction/starting channel, not
ephemeral Core Audio object IDs. Reusing the baseline as the observed capture,
older captures, duplicate identities and unknown JSON schema versions fail.

Apply this strict comparison to normal Pause, Stop, disc-end and quit
scenarios. A failed start can be checked against its baseline without a
successful during sample. Actual same-position output moves and tests that
deliberately change external settings, take hog ownership, or remove a device
need scenario-specific expectations; this strict single-output comparator
intentionally reports changes to other captured devices.

A matching after sample alone does not prove that playback occurred or that
the application performed restoration. These snapshots do not prove PCM
delivery, acoustic channel placement, receiver lock, or CFPreferences crash
recovery. Continue using the silent-pipeline checksum checks and the separate
hardware/restart acceptance steps. The capture and verify commands above do
not activate audio, open a disc, write a device property, or read/write the
app's recovery preferences.

**Crash recovery, separately approved:** playback saves each output's
original rate and stream formats under `ChangedOutputRates` in the
`io.github.ylau674.CDPlayer` preferences before changing them. The app
restores those saved records at its next launch. To test this, quit the app, take a
fresh before capture and start a silent run as above. While it is active,
check that a record exists, then kill the run instead of letting it stop:

```sh
defaults read io.github.ylau674.CDPlayer ChangedOutputRates
kill -9 <AudioCheck PID>
AudioCheck --capture-output-state /path/to/run/crashed.json
AudioCheck --verify-output-state crashed /path/to/run/before.json /path/to/run/crashed.json --output-uid "<UID>"
AudioCheck --recover-output-rates
```

The `crashed` phase expects the target to be idle but still in the applied
44.1 kHz formats, with everything else unchanged. If it matches the original
instead, there is nothing to recover and the test proves nothing.
`--recover-output-rates` lists the saved records and runs the same recovery as
app launch. It fails if any record remains, such as for a disconnected
output. Then use the strict after check above. A killed run cannot restore the
drive's read speed. That speed is not saved for recovery, so it may stay at
the minimum until the drive resets, for example when it is reconnected.

### External outputs and receivers

M6.4 covers what happens when an output leaves, and what
must be set on the device itself. The app cannot detect device settings and
does not claim to.

- **Settings on the device.** Select the input that receives the Mac's audio,
  for example the USB-DAC input on the Pioneer N-50. On a receiver, a
  "Direct" or "Pure" mode bypasses its tone and room processing. The app
  delivers unaltered 44.1 kHz PCM; anything after that is the device's.
- **Volume.** An output without host volume, such as the Sony WALKMAN, shows
  "volume on device" in the output menu and tooltip; turn it up on the
  device. `AudioCheck --list-outputs` prints each output's host-volume flag.
  The app changes volume or mute only for the volume keys, below.
- **Volume keys.** macOS volume keys change the macOS default output. When a
  directly selected output is not the default and both have host volume,
  the app mirrors the default's volume and mute onto it while the CD plays
  (roadmap decision 19). Play sets the default's level to the selected
  output's level, so the output that is playing never jumps; mute is left
  as it is. After that, a change on either side is copied to the other,
  including the menu-bar slider and other apps. Nothing is restored when
  playback stops. If the default was muted at Play, the first press of the
  mute key only unmutes it. The selector's tooltip says which outputs the
  keys control.
- **A lost output.** When the selected output disappears, playback pauses,
  the next best output is selected, and the status line shows `OUTPUT LOST`.
  The tooltip names the lost output, even at launch. Play, another output
  choice or the output's return clears the notice; playback never resumes by
  itself.
- **HDMI and DisplayPort.** Receivers may mute while they lock to a new rate.
  Every start on these outputs (Play, resume, seek, track change or a move)
  plays 1 second of silence before the first CD sample. The time display
  stays at the start position during it, and it is not counted as an
  underrun.
- **AirPlay receiver sleep.** macOS may keep a sleeping AirPlay receiver as
  the default output, so the app keeps playing silently and cannot show
  `OUTPUT LOST`. It pauses when macOS drops the route.
- **HDMI display sleep.** On the Samsung, display sleep silences the TV but
  macOS keeps the HDMI output listed and running, so the CD keeps playing
  unheard and the app cannot show `OUTPUT LOST`. Pause before letting the
  display sleep. Changing the TV's input and back did not interrupt the
  output.

M6.4 hardware checks, each with the owner's approval:

1. Select the PRO X directly, then unplug it while playing and while paused:
   expect `OUTPUT LOST`, the tooltip naming PRO X, and a paused player.
2. Quit, unplug the PRO X and launch: expect `OUTPUT LOST` naming PRO X on
   the fallback. Play clears it and saves the fallback, so a second launch
   with the PRO X still unplugged shows no notice.
3. Reconnect the PRO X while playing on the fallback: playback continues on
   the fallback, and after pausing the selector stays there until the PRO X
   is chosen.
4. Run `AudioCheck --list-outputs` with the WALKMAN and PRO X connected and
   record each host-volume flag.
5. On HDMI to the receiver, listen for the start of track 1 after Play, a
   seek and a track change; tune `CD_PLAYBACK_LEAD_IN_MILLISECONDS` if the
   start is still lost.
6. Let the display sleep and change the receiver's input during HDMI
   playback; record what macOS reports and how the app responds.
7. Volume keys (decision 19): with MacBook Pro Speakers as the default, set
   the PRO X low and select it directly. Press Play: the PRO X level must
   not change and the speakers' level must move to it. Press volume up and
   down, Option-Shift for quarter steps, and mute twice: the PRO X follows.
   Drag the PRO X quickly in Audio MIDI Setup: the speakers follow and end
   level with it. Pause, then
   press a volume key: only the speakers change.

### M6.5 hardware acceptance

The available 1.1.0 hardware checks passed on 2026-11-02. They were run on
one MacBook Pro with a Pioneer BDR-XS07U and one three-track audio CD. The
owner performed every physical and listening step; configuration snapshots
and comparisons were read-only.

| Check | Result |
|---|---|
| Built-in wired headphones | Passed: playback at 44.1 kHz and original format restored. |
| Pioneer N-50 over USB | Passed: 44.1 kHz shown on the front panel; Stop, sleep/wake, resume and Stop restored the original 48 kHz/16-bit format. |
| Stopped/paused output selection | Passed: changing the selection did not start playback. |
| Stop, Eject and Quit | Passed: N-50 returned to its original format. |
| Mac sleep and wake | Passed on N-50 and Samsung HDMI. Playback stayed paused at its position after wake; Play resumed it. All after-wake and after-Stop configuration comparisons passed. |
| PRO X microphone and sidetone | Passed: normal playback, no audible sidetone; input remained idle and input/sidetone properties matched before, during and after playback. |
| DisplayPort/Thunderbolt | Not tested: suitable audio-capable display/interface was unavailable. |

During the PRO X check, the approved volume mirror aligned the default
speakers' volume to the selected PRO X level. That expected change is not
restored at Stop; the PRO X output volume and its microphone controls were
unchanged. On Samsung HDMI, display sleep silences the TV while macOS keeps
the output listed, so pause before the display sleeps. These tests do not
prove end-to-end DAC samples, and the available HDMI checks do not validate
multistream AUHAL layouts. See the [roadmap](AUDIO_OUTPUT_ROADMAP.md) and
[development log](DEVELOPMENT_LOG.md) for run evidence and limitations.

## Test on another Mac

There are two ways to test, depending on what you want to check.

**Build from source.** Use this on a Mac where you also develop. Follow
[set up a new Mac](#set-up-a-new-mac), then run the Debug build, or
`./Tools/package-release.sh` and drag the app from
`build/packages/CDPlayer-<version>-macOS.zip` into `/Applications`. A locally
built app is not quarantined, so Gatekeeper does not block it.

**Install the Release ZIP, as a user would.** Use this on a Mac without Xcode.

1. Copy `CDPlayer-<version>-macOS.zip` across by USB drive, AirDrop or a
   private GitHub release.
2. Double-click the ZIP to unpack it, then drag `CDPlayer.app` into
   `/Applications`. Don't launch it from Downloads.
3. Open it. If macOS says it cannot verify the app, go to **System Settings ›
   Privacy & Security** and click **Open Anyway**. On macOS 14, Control-click
   the app and choose **Open** instead. A copy from a USB drive is usually not
   quarantined and opens directly.

Whichever way you install it:

- The ZIP keeps the code signature intact; a DMG adds no benefit until the app
  is notarized.
- Don't strip the quarantine flag with `xattr` on a Mac you don't manage; use
  Open Anyway.
- A managed (MDM) Mac may disallow Open Anyway altogether.

On the test Mac, check:

- **First Play:** allow the prompt to access files on a removable volume.
- **Mounted disc:** if macOS mounts audio CDs there, this is the first live
  test of a mounted disc. Check Play, Pause, seek, Stop, Eject, and Eject while
  Finder or Music is using the disc, as described in the
  [mounted-disc notes](DEVELOPMENT_LOG.md#m3-physical-drive-and-disc-status).
  Set **System Settings › CDs & DVDs › When you insert a music CD** to
  **Ignore** first, so that Music does not read the disc at the same time.
- **Other drives:** a different drive tests the C2 and speed fallbacks. Watch
  the log while playing:
  `log stream --level info --predicate 'subsystem == "io.github.ylau674.CDPlayer"'`.
- **Output:** wired headphones and speakers, the 44.1 kHz icon, and that the
  previous rate returns after Stop and Quit.
- **Intel Macs:** the app is universal, so an Intel Mac on macOS 14 or later is
  a useful extra check.

To remove it, quit normally, then move `/Applications/CDPlayer.app` to the
Trash.

## Troubleshooting

- **macOS asks again for access to removable volumes after a rebuild.** Each
  ad-hoc signature is different, so privacy permissions (TCC) treat each
  rebuild as a new app. Allow the prompt. To start clean, run
  `tccutil reset SystemPolicyRemovableVolumes io.github.ylau674.CDPlayer`.
- **`[ERR] Access denied` on Play.** macOS or managed policy refused to open
  the raw device. This is by design: the app does not retry or work around
  it.
- **The output stays at 44.1 kHz after a crash.** Relaunch the app. The
  pending record is restored if the output is still at 44.1 kHz.
- **`BUFFERING` on a good disc.** Check that no other app (Music, Finder
  preview, a hardware check tool) is reading the disc.

## Versioning and releases

The project uses semantic versioning. For a release:

1. Update `CFBundleShortVersionString`, and increment `CFBundleVersion`, in
   [App/Info.plist](../App/Info.plist).
2. Update `VERSION` in [Tools/package-release.sh](../Tools/package-release.sh).
3. Add an entry to [CHANGELOG.md](../CHANGELOG.md).
4. Run the three test suites, then `./Tools/package-release.sh`. Note the
   printed SHA-256.
5. Commit, tag (`git tag -a vX.Y.Z -m "CD Player X.Y.Z"`) and push the tag.
   A GitHub release can attach the ZIP from `build/packages/`.

The ZIP is ad-hoc signed and not notarized (see [publishing](PUBLISHING.md)).

## How the project was developed

### Original requirements

A simple Mac application to play audio CDs:

- A simple interface with only clickable buttons: fast backward, previous
  track, play, next track, fast forward, eject.
- A simple display showing the track number and play time.
- Detect the CD or Blu-ray drive.
- Detect an inserted CD and be ready to play it when the user clicks a button.
- Play the CD at the slowest read speed.
- Bit-perfect, top sound quality through the Mac's built-in DAC.

Fast backward and fast forward became a hold on Previous and Next, so there
are four transport buttons. Stop shares the Eject button while playing.

### Process

The work was split into milestones (M1–M5), each with agreed decisions, then
subtasks in build order with explicit prerequisites. For each subtask:

1. Agree the behaviour, including edge cases, before coding. Record it in the
   [development log](DEVELOPMENT_LOG.md).
2. Implement it behind a protocol boundary, and add offline tests with fakes
   for normal, failure and race cases.
3. Run the full suite normally and under AddressSanitizer and
   ThreadSanitizer. All three must pass.
4. If hardware is involved: approve a live check, run it, and record the
   date, commands, results and any limitation.
5. Mark the subtask complete in the log only when the evidence is recorded.

### Milestones

| Milestone | Result |
|---|---|
| M1 | UI: borderless display, transport buttons with click/hold, simulated demo disc with test tones. |
| M2 | Audio path: built-in output selection, 44.1 kHz switching, 30 s ring buffer, real-time IOProc, exact Int16 to Float32 conversion. |
| M3 | Optical drives: IOKit and Disk Arbitration discovery, registry TOC parsing, status display, eject, multi-drive selection. |
| M4.1–M4.10 | Physical playback: disc timeline, raw reader (C), disc session, disc-fed producer and buffering, speed control and pacing, C2-aware recovery, player integration, quality display, hardware check tools, live verification. |
| M5.1–M5.4 | Hardening: sleep and wake, pause on output changes, rate recovery after a crash, hot-unplug stress. |
| M5.5–M5.6b | Multi-drive coverage (offline), whole-disc endurance, damaged-disc handling, then single pass by default. |
| M5.7–M5.8 | Icon, version 1.0.0, Release packaging, installation, final acceptance. |
| M6.1–M6.5 | Version 1.1.0: output selection and recovery; lost-output handling and volume-key mirroring; HDMI/DisplayPort lead-in; hardware checks A–F. DisplayPort, Thunderbolt and multistream AUHAL layouts remain untested. |
| M9.1 | Source peak capture and atomic level table; offline acceptance complete. |
| M9.2 | Swift source-level reader, meter ballistics and latency-aware player state; offline acceptance complete. |
| M9.3 | Audio-level meters below the transport buttons, shown by extending the window, plus the View menu command and ⌘L; app build and UI tests complete. |
| M9.4 | Version 1.2.0: approved built-in, USB DAC and AirPlay live checks; native window and Minimize checks; final docs and extended-window screenshot. |
| M8.1–M8.2 | HDCD: vendored libhdcd, producer-side detection and decoding into an Int32 ring, and the Decode HDCD preference; offline tests and FFmpeg cross-check. |
| M8.3–M8.4 | Version 1.3.0: live HDCD checks on the owner's discs and burned test discs, decoding bit-exact against FFmpeg; listening and ordinary-CD control; synthetic Peak Extend validation; HDCD on the status line, with the depth following playback. |
| Meter CPU | Version 1.3.1: profiled installed 1.3.0, then moved the meter bars out of SwiftUI into an AppKit view on a plain timer; Release CPU with the meters shown fell from 12.5% to 4.2%. |
| Memory, OUTPUT LOST, meter layers | Version 1.3.2: playback returns its read-ahead memory to macOS when not playing; a missing saved output is replaced by the fallback on Play, so `OUTPUT LOST` no longer repeats at launch; each meter segment is a Core Animation layer, taking Release CPU with the meters shown from 3.9% to 2.7%. |
| Public release | Version 1.3.3: Apache-2.0 licence, About-panel credits with libhdcd's BSD notices, bundle identifier `io.github.ylau674.CDPlayer`, contributing and security files, personal data redacted, published with fresh history. |
| Translucent panel | Version 1.3.5: the panel's background is adjustable from 0% to 90% with a View menu slider and remembered; new installations start at 15% transparency; text, buttons and meters stay solid. |

The [development log](DEVELOPMENT_LOG.md) holds the full detail and evidence
for every row.

## Conventions

- **Swift 6 strict concurrency.**
  - UI state lives on the main actor.
  - Drive I/O runs on the `DiscSession` executor.
  - Core Audio setup and teardown run on the audio worker queue.
  - Never block the main actor or the cooperative pool.
- **Real-time safety.** The IOProc must not allocate, lock, log, do I/O or
  call Swift. Keep it in C.
- **Use C only where needed**: `ioctl`s that Swift cannot import, and the
  real-time path. Everything else stays in Swift.
- **Vendored-code exception.** Pinned BSD-licensed libhdcd is the only
  third-party source; no package-manager dependency is fetched at build time.
- **Comments only where the code needs clarification.** Explain *why*, not
  *what*.
- **Logging.** Use `Logger(subsystem: "io.github.ylau674.CDPlayer", category: …)`.
  Mark values `.public` only if they contain no personal data. Show only
  short errors in the UI.
- **Tests.**
  - Every behaviour change gets offline tests.
  - Create players with `PlayerModel.offline(…)` so that no default reaches
    the Mac's audio, power or preferences.
  - Tests that depend on the read policy run under both `.singlePass` and
    `.retry`.
  - Avoid timing-sensitive sleeps; use the existing suspend/resume hooks on
    the fakes.
  - Give literal arithmetic inside `#expect` an explicit type, for example
    `let end: UInt64 = 150 + 75 * 40`. GitHub's runner may use an older Swift
    whose type checker gives up on untyped literal expressions that compile
    instantly here.
- **Docs.** Keep the README, [architecture](ARCHITECTURE.md) and the
  [development log](DEVELOPMENT_LOG.md) in step with behaviour changes.

## Backlog and open items

Verified gaps from 1.0.0:

- Live playback of a disc that macOS has mounted, on a Mac without the mount
  restriction. Covered by offline tests only.
- Other drives: C2-less and non-stream-accurate fallbacks, and confirmation
  of the minimum speed.
- Multiple real drives at once. Covered offline only.

Next:

- M8 (HDCD) is complete and shipped in version 1.3.0; see the
  [HDCD roadmap](HDCD_ROADMAP.md). M8.1 (decoder and detection), M8.2 (the
  Decode HDCD preference), M8.3 (live checks on the owner's no-effect HDCD
  disc and on a burned test disc, where decoding matched an independent
  decode bit for bit; the owner's listening check and an ordinary-CD control)
  and M8.4 (HDCD on the status line, whose bit depth follows the playing
  position) are done. M8.3's offline and synthetic CD-RW Peak Extend tests
  confirm peak restoration and bit-exact agreement with FFmpeg; the CD-RW also
  played audibly in the app with HDCD shown. Live
  verification with real-program HDCD whose musical peaks are lifted by Peak
  Extend remains follow-up work. M7 (MQA-CD) remains a draft. M10 (SACD) is a
  draft whose feasibility spike passed; see below.

Possible next features (not agreed):

- Developer ID signing and notarization, for distribution beyond this Mac.
- MQA-CD: play MQA-CDs bit-perfect to an MQA decoder DAC selected as the
  output; the app itself does not decode MQA. See the
  [MQA-CD roadmap](MQA_CD_ROADMAP.md) (draft; scope confirmed, implementation
  not yet approved).
- SACD: play SACD images burned to DVD±R or BD-R (stereo area). The app
  converts their DSD to 24-bit, 88.2 kHz PCM with its own filter; pressed
  SACDs can't be read by computer drives. See the
  [SACD roadmap](SACD_ROADMAP.md) (draft M10; scope confirmed, plain-DSD
  decoding proven against FFmpeg, implementation not yet approved).
- CD-Text track titles, or an opt-in online metadata lookup.
- Repeat and shuffle, and a remaining-time display.
- Localization.

Continuous integration runs the offline suite on GitHub's macOS runners
([.github/workflows/ci.yml](../.github/workflows/ci.yml)) for pushes to
`main`, pull requests and manual runs. Hardware checks cannot run there, so
live verification stays manual. See [publishing](PUBLISHING.md) about runner
costs.
