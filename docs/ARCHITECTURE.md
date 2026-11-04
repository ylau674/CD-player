# Architecture

CD Player is a thin SwiftUI/AppKit app over a Swift package, `CDKit`, which
contains all player logic. `CDKit` in turn sits on a small C library,
`CDAudioCore`, for the parts that Swift cannot or should not do: the CD
`ioctl`s and the real-time Core Audio path. The app target has almost no logic
of its own. Everything below the window is testable offline with fake drives
and engines.

```text
┌──────────────────────────── App (CDPlayer.app) ────────────────────────────┐
│ CDPlayerApp ─ scenes            PlayerCommands ─ menus/shortcuts            │
│ PlayerWindow ─ borderless, anchored resize   PlayerView ─ display + meters │
│ TransportButton ─ NSButton, click vs hold                                   │
└───────────────────────────────────┬────────────────────────────────────────┘
                                    │ @ObservedObject
┌───────────────────────────── CDKit (Swift) ────────────────────────────────┐
│ PlayerModel (@MainActor) ─ transport, display clock, meter model, policy    │
│   ├─ OpticalDriveService ← MacOpticalDriveService (IOKit + DiskArbitration)│
│   │     ├─ OpticalRegistry / CDTableOfContents ─ TOC from registry metadata │
│   │     └─ DiskEjectRequest ─ unmount (no force), then eject                │
│   ├─ DiscSession (actor, own serial queue) ─ open, verify TOC, speed, reads │
│   │     ├─ DiscReadRecovery ─ C2-aware single pass (default) or retry       │
│   │     └─ RawCDReader : CDSectorSource ─ read-only /dev/rdiskN             │
│   ├─ PlaybackEngine ← CoreAudioPlaybackEngine (demo tones or DiscPCMSource)│
│   ├─ AudioLevelSource ← CoreAudioLevelSource ─ atomic source-peak reads    │
│   ├─ AudioLevelMeter ─ dBFS segments, fall and peak hold                   │
│   ├─ OutputRateControl ← CoreAudioOutputRateControl ─ 44.1 kHz switch      │
│   └─ SleepPreventing / SystemPowerMonitoring ─ stay awake, pause on sleep  │
└───────────────────────────────────┬────────────────────────────────────────┘
                                    │ C ABI
┌────────────────────────────── HDCD (C) ────────────────────────────────────┐
│ Pinned BSD-licensed libhdcd decoder, called only on the PCM producer       │
└───────────────────────────────────┬────────────────────────────────────────┘
┌──────────────────────────── CDAudioCore (C) ───────────────────────────────┐
│ CDDiscReader.c ─ DKIOCCDREAD / READTOC / GET/SETSPEED, whole-disc open only│
│ AudioPlayback.c ─ output choice, rate set/restore, HDCD producer, IOProc   │
│ AudioLevels.c ─ atomic source peaks, outside the render callback           │
│ PCMBuffer.c ─ 15 s SPSC ring, 16- or 32-bit, pages returned when stopped   │
└────────────────────────────────────────────────────────────────────────────┘
```

## Modules

| Target | Kind | Purpose |
|---|---|---|
| `CDPlayer` (`App/`) | macOS app | The window, display, buttons and menus. It creates one `PlayerModel` with the real services and calls `shutdown()` before quitting. |
| `CDKit` | Swift library | The player model, drive discovery, disc sessions, read recovery, playback, wired-output discovery and selection, output-rate control, HDCD preference persistence and power handling. |
| `HDCD` | C target | Pinned libhdcd decoder; source and BSD license are vendored under `Packages/CDKit/Sources/HDCD`. |
| `CDAudioCore` | C library | CD I/O, Core Audio, PCM ring, demo tones, source peaks and producer-side HDCD integration; no Swift dependencies. |
| `AudioCheck` | executable | Read-only discovery, inspection and configuration snapshots; offline before/during/after comparison; a separately activated silent disc pipeline, optionally targeting a wired `--output-uid` or with HDCD decoding off (`--hdcd-off`), that reports each run's HDCD state, physical output depth and rendered checksum; and a developer-only, read-only PCM capture of one track to a WAV file (`--capture-pcm`). |
| `HDCDCheck` | developer executable | Converts interleaved S16LE PCM with the pinned libhdcd decoder for comparison with FFmpeg's `hdcd` filter, used by the temporary-sample check script; with `--seek-gaps`, measures how much audio passes between a decoder reset and the next HDCD packet. |
| `OpticalCheck` | executable | A hardware check: drive and TOC listing, notification watching, a read check, and a deliberate eject. |
| `CDKitTests` | Swift Testing | Offline tests using fake sector sources, drives, engines, recovery records, and injected power and output events. |
| `AudioCheckTests` | Swift Testing | Hardware-free snapshot, comparison, capture-consistency and CLI-isolation tests. |
| `CDPlayerUITests` | XCTest | Native view tests for layout, scrolling, menu, accessibility, audio-level window sizing and when the meters measure, with hardware-free fixtures; also checks the About-panel credits against the vendored libhdcd licence. |
| `Tools/cdprobe` | C tool | The original stand-alone, read-only probe for one disc, kept for reference. |
| `Tools/check-hdcd-ffmpeg.sh` | shell script | Downloads an FFmpeg FATE HDCD sample into a temporary directory, compares decoded PCM byte for byte, and removes the sample and outputs on exit. |

`AudioCheck --capture-output-state` uses an isolated Core Audio property reader,
not the playback engine or preferences adapter. Two matching reads are required
before writing a versioned JSON snapshot. Its HAL and file I/O use a dedicated
serial worker queue rather than the main actor or cooperative executor.
`--verify-output-state` only reads
snapshot files: it checks complete virtual/physical ASBDs, rates, ownership,
running state, protected controls, default routes and other captured wired
devices. It uses the production pure stereo-format selector to predict the
UID-targeted route, without calling any setter. These modes reject playback
and disc arguments before doing work; they do not change the existing silent
pipeline's activation policy.
`--recover-output-rates` is the exception: it reads the saved
`ChangedOutputRates` records and calls the same `CoreAudioOutputRateControl`
recovery that the app runs at launch, so it may write device rates and stream
formats. It is used only for approved crash-recovery tests.

## Playback data flow

1. **Detection.** `MacOpticalDriveService` registers IOKit arrival and removal
   notifications and Disk Arbitration media notifications. It publishes an
   `OpticalSnapshot`: the drives, then each drive's media and its
   `CDTableOfContents` parsed from the registry. It never opens the device or
   reads audio, and never mounts.
2. **Timeline.** `Disc` maps the TOC's audio tracks to one frame timeline,
   skipping data tracks and session gaps. Its `format` (`AudioSourceFormat`)
   comes from the TOC: 44.1 kHz, 16-bit stereo for an audio CD, so 588
   frames per sector. Previous, Next, ±10 s and elapsed time all work in
   frames, the same way for the demo disc and for real CDs.
3. **Play.** `PlayerModel.openDiscSession` first rechecks in the registry
   that the BSD name still identifies the same disc in the same drive. It
   then opens a `DiscSession`, which:
   - opens `/dev/rdiskN` read-only;
   - requires the device TOC to equal the registry TOC;
   - probes C2 support;
   - saves the drive speed and requests the minimum, 176 kB/s.

   The session is kept while paused. It is closed, and the speed restored and
   verified, on Stop, Eject, sleep, quit, a drive change, or when the disc is
   removed or replaced.
4. **Production.** `CoreAudioPlaybackEngine` wraps the session in a
   `DiscPCMSource` and hands it to `AudioPlayback.c` as a `CDPCMSource` C
   callback. A dedicated producer pthread calls it, with blocking reads of up
   to 33 sectors through `DiscReadRecovery` and `RawCDReader`. For CD sources it scans HDCD packets. With Playback > Decode HDCD enabled
   and a physical route of at least 20 bits, it holds the existing 2-second
   startup window before deciding whether effectful packets justify decoding.
   With the preference off, or a narrower/unknown output, detection continues
   without the hold or decoding. Non-effectual and ordinary PCM is shifted
   exactly into Int32; active decoding starts at the next track boundary if
   discovered later. The engine records the first decoded frame, and its
   snapshot reports decoding only once the playing position reaches it,
   because the producer runs up to a buffer ahead of playback. The producer
   writes to a 15-second ring of 661,500 stereo frames. Each start chooses
   the ring's sample width: Int32 only when HDCD decoding could begin in that
   run, and otherwise the CD's own Int16 samples, which render to exactly the
   same Float32 values and checksum. Decoding could begin whenever it is on
   and the output carries 20 bits or more, on any audio CD, because detection
   continues during play and can start decoding at a later track. Source peak measurement still uses the
   original Int16 values. Pacing follows consumption, so a quiet drive is not
   kept spinning at full speed.
5. **Output.** A Core Audio IOProc, the HAL render callback, converts Int32 to
   Float32 with the exact factor 2⁻³¹. It does no allocation, takes no lock,
   does no I/O and makes no Swift call. Startup and recovery after an underrun
   wait for 2 seconds of buffered audio. An underrun outputs silence and shows
   `BUFFERING`. If there is no read progress for 10 seconds, playback stops
   with an error. With System Default selected, when the default device
   cannot take 44.1 kHz stereo on a single stream, an AUHAL output unit's
   render callback does the same conversion under the same rules and
   macOS converts the rate and channels (`CDDeviceInfo.converts`). The
   conversion is exact for a sample with at most 24 significant bits, which
   covers every undecoded or no-effect sample (at most 16). libhdcd's
   gain-adjusted results can carry more, so they are rounded to Float32's 24
   bits, an error far below one 20-bit step.
6. **Meter.** `CoreAudioLevelSource` reads the current run's atomic table
   directly, without entering the audio worker. `PlayerModel` samples the
   slots at the latency-adjusted display position and applies the meter's
   segment thresholds, fall and peak hold. The meter reports the hold only
   at or above the bar's top segment, and the view draws it in the power
   button's red. Playback snapshots distinguish intentional HDMI/DisplayPort
   lead-in silence from advancing source audio.
   Once fully shown, the meters read on a plain 15 Hz main-run-loop timer
   only while playing and while the player window is visible (not hidden,
   miniaturized, fully occluded or off-screen); the 100 ms status poll does not
   touch the meter. `AudioLevelMeterDriver` runs that timer and hands on a
   reading only when a lit or held segment changes. AppKit's
   `AudioLevelBarsView` then recolours only the segments that changed. Each
   segment is its own rounded Core Animation layer with implicit animations
   off, so the app draws nothing as the levels move, and the SwiftUI player
   view is not updated: a SwiftUI `TimelineView` had re-rendered and laid out
   the whole view on every frame. Any other player change reads once and stops the timer
   when the meters are no longer live. Hiding the window clears the meter, and
   showing it again starts with a fresh reading. The meters sit inside the
   player panel, below the transport buttons.
   `PlayerWindow` alone sets the window height to show or hide them, with
   absolute heights and its top edge fixed. The SwiftUI content reports only
   its minimum size, and the panel fills whatever height the window has.
   `PlayerWindow` tells `PlayerModel` the meters are fully shown when the
   latest show's resize, or with Reduce Motion its fade-in, ends. Hiding them
   clears that at once, so nothing is read while the window extends, shrinks
   or is closed. It also tracks AppKit occlusion, window movement across
   screens, miniaturization, ordering and app hide/unhide notifications;
   `PlayerModel` reads only when the window is both fully shown and visible.
   The borderless window validates the native Minimize menu action and
   handles `performMiniaturize` by calling `miniaturize` directly: the
   standard implementation expects a title-bar button. Native Dock
   minimization/restoration and their visibility notifications are preserved.
   The window is non-opaque with a clear background. `PlayerPanelBackground`
   observes CDKit's `PanelTransparency`: a 0–90% transparency setting, initially
   15% when no preference is saved, persisted as `BackgroundTransparency` in
   the app's defaults. The app delegate shares that model with the window and
   View menu. SwiftUI command menus cannot host sliders on all supported macOS
   releases, so
   `PanelTransparencyMenuController` lazily creates the AppKit slider view
   the first time the submenu opens, then appends it with a separator after
   SwiftUI's Reset to 15% item. This avoids the slider's memory cost in
   sessions that never open the submenu. SwiftUI empties
   and refills that submenu when the View menu first opens, so the controller
   re-places the item whenever the submenu's items change, not only when
   tracking begins. `MenuTrackingSlider` tracks its own drag until mouse-up,
   because recent macOS routes `NSSlider` events to an internal view that can
   stay stuck after a release outside the menu. The slider updates the
   background while the menu stays open, and VoiceOver can step it with the
   slider's increment and decrement actions.
   Text, buttons, the border and meters retain their existing opacity.
   Reduce transparency makes the background solid and disables adjustments
   without overwriting the saved level. Resize steps still invalidate the
   window shadow.
7. **Status.** `PlayerModel` polls the engine snapshot every 100 ms for the
   current frame, buffering, end of disc and concealed sectors, and derives
   every string the view shows (`trackText`, `timeText`, `statusText`,
   `formatText`).

## Concurrency model

The project uses the Swift 6 language mode with strict concurrency.

| Context | What runs there |
|---|---|
| Main actor | `PlayerModel`, all UI, `MacOpticalDriveService` callbacks, `OpticalDriveService` and `SleepPreventing`. |
| `io.github.ylau674.CDPlayer.disc-session` | A `DiscSession` actor with a custom serial executor (`DispatchSerialQueue`). Every drive `ioctl` runs here, never on the main or cooperative threads. |
| `io.github.ylau674.CDPlayer.audio-worker` | Blocking Core Audio setup, status, stop, worker joins and handle destruction. The last engine reference is released here too. |
| Producer pthread (C) | Blocking PCM reads into the ring. It can be cancelled through `cd_playback_read_cancelled`. |
| HAL IOProc or AUHAL render callback (C) | Real-time rendering only. An atomic output gate mutes it immediately on stop. |
| `io.github.ylau674.CDPlayer.output-rate`, `io.github.ylau674.CDPlayer.output-changes` | Output-rate changes and Core Audio property listeners. |
| `io.github.ylau674.CDPlayer.system-power` | IOKit system power notifications (`IORegisterForSystemPower`). |

Rules that keep this safe:

- No blocking call on the main actor or the cooperative pool.
- Stop always mutes first, then waits for workers.
- Superseded or cancelled starts cannot re-enable output.
- Rapid seeks are coalesced: the restart happens 300 ms after the last seek.

## Key design decisions

- **Registry metadata for detection, the raw device only for playback.**
  This makes the app work on Macs where policy blocks mounting optical
  discs. It also lets the app avoid touching the drive until the user
  presses Play.
- **Read-only, unprivileged, no workarounds.** The app never mounts, uses
  SCSI pass-through, elevates or force-ejects. A policy refusal is shown as
  `[ERR] Access denied` and is not retried.
- **Single pass by default** (`DiscRetryPolicy.singlePass`). Each block is
  read once.
  - C2-flagged samples are interpolated, and failed blocks are split into
    single-sector reads to isolate the bad sector.
  - This keeps the drive quiet and slow, like a hardware player.
  - The hybrid `.retry` policy, which re-reads flagged blocks when the buffer
    has time to spare, remains available for testing (`AudioCheck --retry`).
  - Without C2, reads stay unverified rather than being re-read.
- **Shared, not exclusive, output.** The app does not use hog mode, so the
  volume keys work. It refuses to play only if another app has exclusive use
  of the output.
- **Playback memory only while playing.** The ring and the HDCD start-up
  buffers are anonymous mappings, sized once when the engine is created.
  Each start claims only the pages it needs (`madvise(MADV_FREE_REUSE)`);
  Pause and Stop, after the workers have joined, return them to macOS
  (`MADV_FREE_REUSABLE`), so they leave the app's footprint at once. The
  HDCD start-up pages are returned as soon as detection decides. A sanitized
  build poisons unclaimed bytes, so a write outside the claim fails the
  tests. Output inspection is a static Core Audio query and creates no
  playback engine or ring.
- **Source format from the disc.** A CD stores no sample-rate or bit-depth
  field. Each TOC track's control bits only mark it as audio or data, two- or
  four-channel, and with or without pre-emphasis. The Red Book fixes audio
  at 44.1 kHz and 16 bits, so `CDTableOfContents.audioFormat` is Red Book
  audio with the declared channel count. `PlayerModel.sourceFormat` passes
  it to output inspection, discovery and the rate switch, and
  `CDPCMSource.format` passes it to C. The C pipeline declares what it can
  carry unchanged: `cd_source_format_supported` accepts only 44.1 kHz,
  16-bit stereo. `cd_playback_create_source` refuses anything else with
  `CD_FORMAT_UNAVAILABLE` before touching an output. The output rate, the
  format checks and the labels all follow the source rate. Pre-emphasis is
  detected but still played as recorded. HDCD and MQA-CD discs are Red Book
  containers, so they are detected as 44.1 kHz, 16-bit sources. Once a
  playback run finds HDCD, `PlayerModel` keeps that for the loaded disc until
  it is ejected or changed; the status line then reads `HDCD …`, and the
  source text names the depth played, 16-bit or 20-bit once the audio being
  played is decoded.
- **Output rate and formats.** Play sets the chosen wired output to the
  source's native rate and a compatible PCM stream format, or requests the
  rate on the System Default device when it offers it. Pause, Stop and quit
  restore the saved rate and stream formats, including a USB DAC's original
  physical bit depth.
  - Before changing the rate, the original is saved in CFPreferences (domain
    `io.github.ylau674.CDPlayer`, key `ChangedOutputRates`).
  - After a crash, the next launch applies the existing recovery rules to the
    saved formats. If macOS holds a restore during sleep, it is retried after
    wake and Play waits until recovery finishes.
- **Power.** While playing, a user-initiated `ProcessInfo` activity prevents
  idle sleep. On a forced sleep, the player pauses and closes the session
  before acknowledging. After wake, the paused position is kept if the same
  TOC reappears.
  - Once sleep begins, macOS can hold an output change until wake, so the
    pause uses `cd_playback_stop_before_sleep`. A rate or format restore that
    does not finish marks the output's record for recovery instead of
    failing. At wake the same recovery as at launch finishes it; Play waits
    for it.
- **Vendored-code exception.** The only third-party code is pinned,
  BSD-licensed libhdcd under `Packages/CDKit/Sources/HDCD`; it has no runtime
  package-manager dependency. Its licence requires its notices in binary
  distributions, so `App/Credits.rtf` carries them into the standard About
  panel, and `CDPlayerUITests` checks they match the vendored `LICENSE`. The
  app otherwise uses Apple frameworks: SwiftUI, AppKit, IOKit,
  DiskArbitration, CoreAudio, AudioToolbox and OSLog.

## Logging

Logs use the unified log subsystem `io.github.ylau674.CDPlayer`, with the
categories `Player`, `Disc`, `DiscRead`, `Audio`, `Optical`, `Power` and
`Lifecycle`. The display shows only short errors; the technical detail goes to
the log:

```sh
log stream --level info --predicate 'subsystem == "io.github.ylau674.CDPlayer"'
```

The following are logged:

- Slow (≥ 0.5 s) or failed raw reads.
- `BUFFERING` changes.
- Per-run totals (underrun frames, concealed sectors) whenever playback
  stops.

## Where to change what

M6.1 moves the source format beside the power button. Row 2 contains
`OutputStatusLine`, an AppKit view with separate status and output-selector
accessibility elements. `OutputLineLayout` computes fit, scrolling and
Reduce Motion truncation; the selected output menu lists the wired Core
Audio entries, identified by UID and labelled by transport, then System
Default.
`CoreAudioOutputRateControl` discovers live wired, wireless and virtual
outputs; `PlayerModel` filters the list to the supported wired transports,
shows unsupported 44.1 kHz/stereo devices disabled with a reason, and
remembers the selected UID. M6.3b routes external wired entries by that UID.

M6.3a adds `OutputTarget`, passed from `PlayerModel` through
`PlaybackEngine` and `OutputRateControl` to `CDOutputTarget` in C:
`.builtIn` is the 1.0.0 rule and `.systemDefault` the macOS default output.
The menu ends with a separator and the System Default entry
(`OutputChoice.systemDefault`), saved as `SelectedAudioOutputIsSystemDefault`.
`PlayerModel.moveOutput` restarts playback at the same frame when the
target changes while playing, and `followDefaultOutputChange` moves
playback to a default the user chose, or pauses with "OUTPUT LOST" when the
previous default disappeared. `OutputTransport.symbol(usesSpeakers:)` maps
each connection type to the SF Symbol used by the menu and the rate icon.

M6.3b adds `.device(uid:)` through the same engine and rate-control
interfaces. C resolves the UID again at inspection and playback start,
validates that the device is live, wired and able to provide 44.1 kHz stereo,
then shares it without hog mode. Rate changes are recorded and restored for
that UID. Multi-stream outputs use AUHAL, whose channel map sends stereo to
the device's preferred output channels and leaves the rest silent. On the
IOProc path, a selected wired output may expose a wider Float32 stream at
44.1 kHz; the physical stream must be PCM with at least 16 bits and enough
channels. The pure `cd_audio_format_supports_native_playback` predicate is
shared by runtime validation and offline format tests. The mapped renderer
(`cd_ring_render_mapped`) preserves PCM checksums and silences unused channels
and EOF tails in both interleaved and planar tests. Silent CD checks pass on the PRO X, WALKMAN and a Samsung HDMI output with
one 8-channel stream. The owner confirmed distinct left/right playback on
the wired PRO X and through the HDMI receiver. Actual multistream AUHAL
layouts remain unvalidated. For a chosen single-stream output, C applies
the first advertised stereo Float32 virtual format with a stereo integer
physical format at the source rate, after saving both originals in the rate
record. `OutputRateRecovery.c` writes the physical format first and the
virtual format only when it is still wrong, then writes back a physical
format that the virtual write replaced. On a USB DAC, a virtual write
re-picked the physical bit depth.

M6.4 handles output loss and volume-key behavior. If a selected output
disappears, the player pauses, selects the next fallback and shows `OUTPUT
LOST`; reconnecting does not resume playback. A saved output missing at launch
is named the same way. While a saved wired output is missing, a successful
Play on the shown fallback saves the fallback (`PlayerModel.adoptFallbackOutput`),
so later launches don't repeat the notice; choosing the ticked fallback saves it
too. A saved System Default, or a saved output that is listed but disabled,
is never replaced this way. While playing on a directly
selected non-default output, `VolumeMirror` copies volume and mute changes
between that device and the macOS default when both expose host controls.
Starting the mirror aligns the default's level to the playing output, but
does not align mute; the resulting level is not restored when playback stops.
The mirror does not alter CD samples.

HDMI and DisplayPort starts include a one-second silent lead-in for receiver
rate lock. It does not consume source frames or count as an underrun. A
sleep-specific stop preserves the paused position and attempts restoration
before sleep; if macOS defers a format change, the saved record is recovered
after wake and playback stays gated until recovery completes. Display sleep
is different from system sleep: the Samsung TV can become silent while macOS
continues to report its HDMI output, so the app cannot detect that condition.

M6.5 acceptance passed on the available hardware: built-in wired output,
PRO X, Sony WALKMAN, N-50 USB, Samsung HDMI, WH-1000XM3 Bluetooth and AirPlay
to another Mac. The PRO X microphone remained idle and its input and sidetone
controls stayed unchanged through playback. DisplayPort and Thunderbolt were
not available to test; actual multistream AUHAL layouts also remain
unvalidated.

The name's space is never wider than `maximumNameWidth`, which `PlayerView`
sets to half of the whole 390 pt row (`PlayerView.rowWidth`), whether or not
the rate icon is shown. When the output name overflows the space between
the status and the menu indicator, or that maximum, Core Animation moves two copies of the name inside a clipping
layer, without a per-frame app timer. The status, the indicator and the rate
button are outside the moving layer and never move. The selector's click
target is the whole fixed name space plus the indicator, so it does not
follow the name. Status changes only move the start of the name space and
keep the scroll phase; a new name, fitting text, Reduce Motion and window
occlusion restart or stop the animation.

The same Core Audio change monitor refreshes the output catalog when devices,
default output, rates, streams or transport properties change. A
`UserDefaultsOutputSelectionStore` persists only the preferred UID. If it is
absent, the model selects the wired default, then built-in, then the first
supported wired output; reconnection restores the saved selection while
stopped or paused.

| Change | Start in |
|---|---|
| Layout, colours, buttons, audio-level meters | `App/PlayerView.swift`, `App/TransportButton.swift`, `App/OutputStatusLine.swift`, `OutputLineLayout.swift` |
| Menus and shortcuts | `App/PlayerCommands.swift`, `App/CDPlayerApp.swift` |
| Transport rules, display strings, drive selection | `Sources/CDKit/PlayerModel.swift` |
| Drive or disc discovery, eject | `MacOpticalDriveService.swift`, `DiskEjectRequest.swift`, `CDTableOfContents.swift` |
| Source format detection, supported formats | `CDTableOfContents.swift`, `AudioSourceFormat.swift`, `cd_source_format_supported` in `AudioPlayback.c` |
| Read policy, C2, error concealment | `DiscReadRecovery.swift`, `DiscSession.swift` |
| Buffer size, prefill, pacing, render path | `Sources/CDAudioCore/AudioPlayback.c`, `include/CDAudioCore.h` |
| Source peak table | `Sources/CDAudioCore/AudioLevels.c`, `AudioPlayback.c` |
| Meter model and display position | `Sources/CDKit/AudioLevels.swift`, `PlayerModel.swift` |
| Output selection and rate switching | `AudioPlayback.c`, `CoreAudioOutputRateControl.swift` |
| Sleep and wake | `SystemPower.swift`, `PlayerModel.swift` |

The full behaviour specification for each area is in the
[development log](DEVELOPMENT_LOG.md).
