# Audio Output Selection: Design and Validation Record

**Status:** Shipped in version 1.1.0 after M6.5 checks A–F passed on
2026-11-02. Built-in, USB and HDMI outputs were exercised; DisplayPort and
Thunderbolt remain untested because suitable hardware was unavailable.
On the Samsung, display sleep silences the TV while macOS keeps the HDMI
output listed, so the app cannot detect it.
See the
[M6.1 results](DEVELOPMENT_LOG.md#m61-layout-and-built-in-selector-2026-11-01),
[M6.2 results](DEVELOPMENT_LOG.md#m62-wired-output-discovery-and-selection-2026-11-01)
and [M6.3a results](DEVELOPMENT_LOG.md#m63a-system-default-and-device-icons-2026-11-01),
and [M6.3b results](DEVELOPMENT_LOG.md#m63b-selected-wired-output-routing-2026-11-01),
with the later [silent CD results](DEVELOPMENT_LOG.md#m63b-silent-cd-checks-on-usb-and-hdmi-2026-11-01).

On 2026-11-01 the user asked for System Default first, because it is quicker,
and then the wired outputs. The former M6.4 (System Default) became M6.3a,
the former M6.3 (wired outputs) became M6.3b, and the later milestones moved
up one number: disconnects are now M6.4 and hardware validation M6.5.

**Release:** CD Player 1.1.0 (M6).
**Basis:** Read-only inspection of three USB audio devices on macOS, silent
44.1 kHz switching checks on the Pioneer N-50 and beyerdynamic PRO X, and the
current CD Player 1.0.0 output path. Subsequent silent CD checks cover selected
PRO X and WALKMAN USB outputs and Samsung HDMI. Later live checks played
through System Default to WH-1000XM3 Bluetooth headphones and over AirPlay to
another Mac. DisplayPort and Thunderbolt playback have not been tested yet;
retrying AirPlay to the N-50 is optional.

## Goal

Let the user choose which output plays the CD. Several outputs can be
available, but only the selected one is used. There are two kinds of entry,
in order of preference.

1. **Wired outputs: the sound-quality path.**
   - the built-in output, as today;
   - USB DACs;
   - HDMI or DisplayPort receivers and displays;
   - Thunderbolt audio interfaces.

   Each gets the same treatment as the built-in output in 1.0.0:
   - Play switches the output to the disc's native 44.1 kHz.
   - The app sends the CD's 16-bit samples with no volume, EQ or resampling.
   - Pause, Stop and quit restore the original rate unless the user keeps
     44.1 kHz with the rate icon.
2. **System Default: best effort.**
   - Plays to whatever macOS is currently using as its default output. This
     is how Bluetooth, AirPlay and any other unlisted output are reached.
   - The app still asks for 44.1 kHz where the device allows it and adds no
     processing of its own, but bit-perfect output is best effort only:
     - macOS may convert the rate or channel layout;
     - a wireless link may re-encode the audio.
   - It ranks below every wired output, because the app's focus is sound
     quality. It is used when the user selects it, or as the last fallback
     when no wired output is available.

Changing outputs follows two rules:

- **The user chooses another output:** playback moves to it at once and
  continues from the same position. This covers choosing an entry in the
  app, and choosing a new default in the macOS Sound menu while System
  Default is selected.
- **The selected output is missing or lost:** playback pauses, the next best
  output is selected, and the app waits for the user to press Play.

Inserting a disc or connecting a device never starts playback, and paused
playback never resumes on its own. Built-in playback stays exactly as it is.

The measurable sound-quality goal is to avoid unnecessary sample-rate
conversion, volume scaling and processing in the app. A DAC's asynchronous
clocking can help it manage its own timing, but by itself it does not
guarantee an audible improvement. "Matching the source" means the output runs
at 44.1 kHz and the app adds no processing. It does not cover:

- audio other apps mix into the same output;
- processing inside macOS, a wireless link, a DAC, a receiver or a display.

The app must not claim end-to-end bit-perfect output in those cases, and never
claims it for System Default.

## Interface plan

The window keeps its width (426 pt) and its four rows; only the top two rows
change.

```text
1.0.0
[drive] PIONEER BD-RW BDR-XS07U                          [power]
CD PLAYING                     44.1 kHz / 16-bit source  [rate]
TRK 03                                              02:41
[prev]      [play]      [next]      [eject]

Proposed, wired output selected
[drive] PIONEER BD-RW BDR-XS07U 44.1 kHz / 16-bit source [power]
CD PLAYING                          beyerdynamic PRO X ▾ [rate]

Proposed, System Default selected (here, the N-50's AirPlay output)
CD PLAYING                                        N-50 ▾ [rate]
```

- **Row 1:**
  - The source description ("44.1 kHz / 16-bit source" or "Optical
    media") moves up, just left of the power button.
  - It stays hidden when there is no disc, as now.
  - The drive name truncates in the middle before the source text does.
- **Row 2:**
  - The output selector takes the source text's old place. It shows only the
    output's device name and a menu indicator. System Default shows the name
    of the device macOS is currently using, with no prefix.
  - When the status text and the output name fit, they stay still: the
    status on the left, the output name on the right, as in the sketch.
  - The output name is shown no wider than half of the whole row (195 pt of
    the 390 pt row, including the rate icon), whether or not the rate icon
    is shown. A longer name scrolls within that width, even when the status
    is short. Every output name seen so far is narrower than that.
  - When they do not fit, only the output name scrolls. The status stays
    still at the left, and the menu indicator ("▾") and the rate icon stay
    still at the right. The name scrolls horizontally within the space
    between the status and the indicator, at most half of the row, clipped
    at both ends.
  - Scrolling:
    - It starts after a short pause, moves slowly and loops, with a gap
      before the name starts again.
    - Status updates, such as a new error count, do not restart it; a longer
      or shorter status only moves the start of the name's space. A
      different output name starts a new pass. It stops, back at the start,
      once the name fits again.
    - The whole name space and the indicator open the menu, so the click
      target does not move with the name.
    - It runs only while the name overflows and the window is visible, so it
      costs nothing otherwise.
    - With macOS "Reduce motion" turned on, the name does not scroll. It
      truncates in the middle instead, and the tooltip shows it in full.
    - The status is never scrolled. It is cut short with "…" only if it
      would otherwise leave room for fewer than about seven characters of
      the name; the tooltip and VoiceOver still give it in full. The longest
      current statuses leave far more room than that.
  - The tooltip and accessibility label give the full name and connection
    type. For System Default they also say "System Default, best effort".
    VoiceOver reads the status and the output selector as separate items,
    not as the scrolling name.
- **Rate icon:** stays at the right end of row 2 and keeps its 1.0.0
  behaviour, now for the selected output:
  - It is lit while that output runs at 44.1 kHz. For System Default, that
    means the current default device.
  - Clicking it keeps 44.1 kHz between plays, or restores the recorded
    original rate.
  - It is disabled during playback, while busy, when the output cannot run
    at 44.1 kHz, or when another app has exclusive use of the output.
  - For System Default, its label adds that bit-perfect output is best
    effort. A lit icon shows only the rate, not a bit-perfect path.
  - Its symbol shows the type of the output it describes (added in M6.3a at
    the user's request). Menu entries use the same symbols. For System
    Default, the symbol is that of the device macOS is using now.

    | Output | SF Symbol |
    |---|---|
    | Built-in speakers | `speaker.wave.2` |
    | Built-in headphones (any other built-in output) | `headphones` |
    | USB | `cable.connector` |
    | HDMI | `tv` |
    | DisplayPort | `display` |
    | Thunderbolt | `bolt` |
    | AirPlay | `airplayaudio` |
    | Bluetooth headphones | `headphones` |
    | Bluetooth speakers | `hifispeaker` |
    | Aggregate, virtual, other, or no output | `hifispeaker` |

  - "Speakers" means a "Speaker" terminal or "speaker" in the device name,
    the 1.0.0 test. All of these symbols are available from macOS 11, below
    the app's macOS 14 minimum.
  - This replaces the 1.0.0 waveform for built-in speakers. It also settles
    the open question about the PRO X: the headset reports a "Speaker"
    terminal, but a USB output shows the USB symbol whatever its terminal.
- **Fit check:** measured in the app's 10 pt monospaced font (about 6.2 pt
  per character), against the 390 pt available inside the padding:
  - Row 1 with the longest drive name seen so far ("PIONEER BD-RW
    BDR-XS07U"), the drive selector and the source text needs 361 pt.
  - With a plain status such as "CD PLAYING", every name tried fits in row 2.
  - With the longest quality status ("CD PLAYING | ERR 12 | UNVERIFIED"),
    these fit: "N-50 ▾", "AirPods Pro ▾", "beyerdynamic PRO X ▾" and
    "MacBook Pro Speakers ▾" (368 pt).
  - Only "Pioneer USB Audio Device ▾" does not fit (by 3 pt in the measured
    AppKit font), so with that status its name scrolls.

### Selector behaviour

- **Menu:** clicking the output name opens a menu. Each entry shows its
  connection type, and the selected entry is ticked. Entries appear in order
  of preference:
  1. **Built-in**, for example "MacBook Pro Speakers — Built-in".
  2. **Wired external outputs**, for example "beyerdynamic PRO X — USB".
  3. **System Default** after a separator, for example "System Default — N-50
     (AirPlay), best effort".
- **Built-in entry:** one entry that keeps the 1.0.0 rule and shows the
  chosen device's current name. The rule picks, in order:
  - the built-in device that is the macOS default output;
  - otherwise a built-in device with "headphone" in its name;
  - otherwise another built-in output.

  It is selected on first launch and whenever no other choice is saved, so
  existing users see no change.
- **Wired external outputs:**
  - They are listed individually and identified by UID, never by name.
  - Outputs that cannot play 44.1 kHz stereo PCM are not resampled by the
    app. They are listed but disabled, with the reason. To use one, the user
    makes it the macOS default and chooses System Default, which plays it
    best effort.
- **System Default entry:**
  - It is available whenever macOS has a default output, and shows which
    device and connection that is.
  - If that device is also listed as a wired entry, the tooltip suggests
    choosing it directly for the sound-quality path.
  - The saved choice is "System Default", not a device UID.
- **Choosing an output:**
  - Choosing never starts playback.
  - While stopped or paused, it only selects. The output is inspected so the
    rate icon reflects its current rate, and the rate changes on Play or
    with the rate icon, as built-in output works now. After a pause, Play
    continues from the paused position on the new output.
  - While playing, the audio moves at once (see below).
- **Availability:** the selector is usable whenever the player is not busy
  (preparing, ejecting, changing a rate or shutting down). That includes
  during playback, and when another app has exclusive use of the current
  output, so the user can move away from it. The rate icon keeps its 1.0.0
  rules and stays disabled during playback.
- **Remembered choice:** saved by UID, or as System Default. The saved choice
  is kept while its output is missing.

### Moving playback to another output

This applies when the user chooses another output during playback: in the
app, or in the macOS Sound menu while System Default is selected.

- Playback continues from the same position on the new output, without the
  user pressing Play. Keeping audio already read from the disc, so the
  drive does not have to seek again, remains a possible refinement; M6.3a
  reads from the position again.
- The new output is prepared as on Play. A wired output is switched to
  44.1 kHz and verified; System Default is best effort.
- The previous output gets back the rate Play changed, as on Pause. A rate
  the user kept with the rate icon stays, and quitting restores it, as in
  1.0.0.
- Expect a short gap while the new output changes rate. HDMI receivers may
  need longer to lock (M6.4).
- If the new output cannot start, playback stops at that position with an
  error naming the output, as a failed Play does, and Play tries the new
  output again from there. It does not go back to the previous output.
  (Revised in M6.3a from "pauses", which would hide the error.)

### When the selected output is missing

This applies when the selected output is not available at launch, while
stopped or paused, or because it disappears during playback.

- **What happens:**
  - If it was playing, playback pauses at the current position.
  - The next best available output is selected.
  - The status line shows `OUTPUT LOST` in the warning colour, and the
    selector's tooltip names the lost output. The app saves the output's
    name with its UID, so it can name an output missing at launch.
  - The notice stays until the user presses Play, chooses another output,
    or the lost output reconnects (decision 14).
  - The app waits for the user to press Play, which continues on the new
    output. It never resumes automatically.
- **Next best, in order:**
  1. the macOS default output, if it is a listed wired output that can play
     44.1 kHz stereo;
  2. the Built-in entry;
  3. System Default, as the last resort.
- **Reconnection:** the saved choice is kept. When that output
  reappears with the same UID:
  - if playback is stopped or paused, the selector returns to it, without
    starting playback;
  - if playback is running on the fallback, it continues there until the
    user chooses an output.
- **System Default:**
  - macOS picks a new default by itself when the default device disappears,
    for example when Bluetooth headphones are switched off.
  - That counts as a lost output: playback pauses, and the selector shows
    the new default. It does not move the audio, so playback never jumps
    from headphones to speakers.
  - Only a default the user chooses moves the audio at once.

## Device evidence

These are observations from the connected devices, not promises about every
device of the same brand. All three expose 44.1 kHz stereo PCM to Core Audio.

| Device | USB timing | Observed rate options | Volume controls exposed to macOS | Relevant constraints |
|---|---|---|---|---|
| Sony Walkman NW-A306 | Asynchronous, feedback endpoint | 8 rates, 44.1–384 kHz | None | macOS does not expose its raw-data/DSD alternate setting |
| beyerdynamic PRO X | Synchronous | 8 rates, 44.1–384 kHz | Hardware volume and mute | Mic and sidetone controls are present and remained unchanged in M6.5; no sidetone was audible during CD playback |
| Pioneer N-50 | Asynchronous, feedback endpoint | 5 rates: 44.1, 48, 88.2, 96, 192 kHz | Mute only | Line-level output; the device reports a “Speaker” terminal; its USB-DAC input and Hi-Bit32/Pure Audio processing are managed on the unit |

### Live check on the N-50

With the output idle, a throw-away harness (not part of the app) switched the
N-50's USB output from 48 kHz to 44.1 kHz and played 10 seconds of
zero-valued samples, so nothing was audible, then restored 48 kHz.

- macOS accepted 44.1 kHz, and the N-50's own clock-source register read back
  44,100 Hz and valid, twice, during playback.
- A manual check of the unit's front-panel display showed 44.1 kHz, matching
  the clock-source reading.
- Core Audio used a 16-bit stereo physical format at 44.1 kHz, so CD samples
  need no wider container on this device.
- The driver used asynchronous mode with explicit feedback. The harness
  counted 866 callbacks in 10 s at 512 frames per buffer (about 861 expected),
  and the driver log showed no errors while streaming. One "abort pipe failed
  (not found)" message was logged at the moment of stop, while Core Audio
  reported the stop with error 0; its cause was not investigated.
- The rate returned to 48 kHz. Core Audio verified it, the driver log shows it
  setting the clock to 48,000 Hz and reading that back, and a separate
  read-only query afterwards found the device's clock register at 48,000 Hz,
  valid and not muted, with no hog owner on the output.

Not recorded: which input the unit had selected, and when the display was read
relative to the 10-second run.

### Observations that affect the design

- **One unit, two outputs.** The N-50 appears in the Sound menu twice: as its
  USB output, "Pioneer USB Audio Device", and as an AirPlay output named
  "N-50". The AirPlay output has a different transport and UID (the UID
  contains the unit's hardware address) and offers only 44.1 kHz. Core Audio
  created that AirPlay device only while it was selected as the output.
  Outputs must be identified by transport and UID, never by name.
- **Other apps use the DAC too.** A WebKit audio process
  (`com.apple.WebKit.GPU`) held the Pioneer output open across several of the
  checks, including a 40-second continuous poll, and the harness correctly
  refused to change the rate while it did. A rate change affects every client
  of the device, so sharing is the normal case. Under the confirmed sharing
  policy (decision 5), the player still switches the rate when other apps
  are playing, as it does for built-in output, and refuses only when another
  app has exclusive use. CD Player 1.0.0 reads the device's "in use"
  flag, but only the hardware check tool acts on it; the player does not.
- **Device IDs and UIDs.** When the PRO X was unplugged and reconnected, Core
  Audio gave its output and microphone new object IDs (117 → 112 and
  111 → 106) but the same UIDs. The PRO X's UID contains its USB serial
  number. The N-50's UID contains `2100000`, which matches the USB port
  location in the driver log (`Pioneer USB Audio Device@02100000`), so it
  probably changes if that unit is moved to another port (not tested). The
  PRO X's output and microphone are separate Core Audio devices with the same
  model ID, so a model ID alone does not select an output.
- **PRO X silent-output check.** With the device idle, a one-off harness
  switched it from 384 kHz to 44.1 kHz, streamed zero-valued samples for 45
  seconds, then restored 384 kHz. Core Audio used 32-bit stereo physical PCM
  at 44.1 kHz, and the callback count reached 3,892. The playback volume
  remained −21.5 dB, mute remained off, and the microphone/sidetone controls
  read the same values before and after. The test did not change those
  controls. The device exposes a sidetone-enabled flag at 0 dB, but whether a
  microphone tap was audible was not confirmed after the run.

## Proposed milestones

### M6.1 — Layout change, built-in output only

**Complete:** 304 package tests pass normally and under ASan/TSan; six
native AppKit tests pass. The full Release UI with silent CD playback used
1.81% CPU while scrolling, versus 1.79% stationary. Menu, accessibility,
layout, visibility and built-in playback/rate restoration checks passed.
The long name and quality warnings used to force scrolling were display-only
fixtures, not a selected USB output or actual disc errors.

Revised on 2026-11-01 so that only the output name scrolls; the status, the
menu indicator and the rate icon stay still. The name is also limited to
half of row 2, so a longer name scrolls within that width. On-screen
captures confirmed that the status and the indicator/rate-icon pixels did
not change while the name moved, and that the name's space was 195 pt. The
CPU figures above were measured with the earlier whole-line scrolling; the
revision uses the same Core Animation mechanism with fewer moving layers,
and hardware-free checks measured the UI's app-process CPU at 0.007–0.14%
while scrolling (see the
[development log](DEVELOPMENT_LOG.md#name-only-scrolling-2026-11-01)).

- Move the source text to row 1 and add the selector to row 2, with a single
  Built-in entry.
- Make the output name scroll horizontally when it does not fit, with the
  status, the menu indicator and the rate icon fixed (see "Interface plan").
- No change to playback or output behaviour.
- Check the layout at the current window width with:
  - long drive and output names, including "Pioneer USB Audio Device" with
    the longest status;
  - demo mode and no disc;
  - error and UNVERIFIED states;
  - the drive selector shown and hidden;
  - "Reduce motion" on and off, and VoiceOver.

**Acceptance:**

- Built-in playback, the rate icon and the status text behave exactly as in
  1.0.0.
- Only the output name scrolls, and only while it does not fit; the status,
  the menu indicator and the rate icon never move, and the output name
  opens the menu while it scrolls.
- With row 2 scrolling during playback, the whole player's CPU in a Release
  build is measured against the 1.7% recorded for 1.0.0 (see the
  [CPU and memory check](DEVELOPMENT_LOG.md#cpu-and-memory-check-2026-10-31)).
  The target is no more than about one percentage point above that.
- Existing tests pass, apart from expectations that are about layout.

### M6.2 — Wired output discovery and selection

**Complete:** 311 package tests pass normally and under ASan/TSan; six native
AppKit tests pass. Debug and Release app builds pass. Fake-device tests cover
transport filtering, disabled reasons, UID persistence, missing-device
fallback, reconnection with a new object ID, and monitor-driven list updates.
A read-only live check classified the PRO X as USB and the MacBook Pro
Speakers as Built-in, and left out the Teams and Zoom virtual devices. HDMI,
DisplayPort and Thunderbolt have not been validated live. No playback,
sample-rate change, or optical-drive access was performed. M6.3b now
implements routing to a selected wired output.

- **Which outputs to list:** outputs that have an output stream and a wired
  transport (built-in, USB, HDMI, DisplayPort or Thunderbolt).
- **Which to leave out of the list:**
  - Bluetooth and AirPlay;
  - aggregate, multi-output and virtual devices;
  - anything whose transport cannot be read.

  These remain playable through System Default (M6.3a) when macOS uses them as
  its default output. Other wired transports, such as PCI, can be added after
  hardware testing.
- **Identity:**
  - Identify each output by transport and UID.
  - Show the transport in the menu, because one product can appear twice:
    the N-50 is both a USB DAC and an AirPlay output.
  - Remember the choice by UID only. Core Audio object IDs change when a
    device is reconnected, and some UIDs include the USB port location (the
    N-50's does).
- **Inspection:** inspect each output the way the built-in output is inspected
  now: name, current rate, 44.1 kHz support, exclusive owner, terminal type,
  output channel count, and any saved original rate. An entry without both
  nominal 44.1 kHz support and at least two output channels is listed
  disabled, with its reason. Exact physical-format validation is M6.3b.
- **Live list:** keep the menu current as devices come and go. The existing
  output-change monitor already watches the device list and the default
  output.
- **Missing output while not playing:** at launch and while stopped or
  paused, apply the next-best and reconnection rules. Loss during playback is
  part of M6.4.
- **Terminal type is descriptive only:**
  - Do not treat the N-50's line output as laptop speakers just because it
    reports "Speaker".
  - The built-in speaker note ("built-in speakers use Apple DSP") must apply
    only to built-in speakers.

**Acceptance:** Fake-engine tests cover:

- listing and filtering;
- selection and persistence;
- a remembered output missing at launch, with the next best selected;
- reconnection with a new object ID, returning the selector to the saved
  output.

Built-in output continues to work as before.

### M6.3 — Routing to the selected output, and device icons

Playback goes to the selected output, and each output shows a symbol for its
type. At the user's request this is done in two parts: System Default first,
because it is quicker, then the wired outputs.

#### M6.3a — System Default, best effort, and device icons

**Complete offline (2026-11-01):** 323 package tests pass normally and under
ASan/TSan; six native AppKit tests pass; Debug and Release app builds pass.
Nothing was played and no rate was changed on real hardware; see "Still to
check live" below. At this stage, choosing a wired entry other than Built-in
was still saved only; M6.3b below now implements that route.

- **Entry:**
  - The System Default entry is listed last, after a separator, for example
    "System Default — PRO X (USB), best effort".
  - It is disabled when macOS has no default output.
  - The choice is saved as System Default, not as a UID.
  - Row 2 shows only the device name, and the tooltip says
    "PRO X — System Default (USB), best effort".
- **Device icons:** menu entries and the rate icon show the output type (see
  the table under "Interface plan"). System Default uses the symbol of the
  device macOS is using.
- **Resolve at Play:** use the device macOS has as its default output at the
  moment Play is pressed.
- **Ask for 44.1 kHz where possible:**
  - When the device offers 44.1 kHz and no other app has exclusive use, apply
    the same record, switch, verify and restore rules as the built-in output.
  - After the switch, play directly to the device, as on the built-in
    output, only when it accepts 44.1 kHz stereo on a single output stream.
    Otherwise use the conversion path below, at 44.1 kHz.
  - The N-50's AirPlay output offered only 44.1 kHz in the checks so far.
- **Play anyway when it cannot match:**
  - If the default device has no 44.1 kHz rate, no 2-channel format or more
    than one output stream, play through Apple's HAL output unit (AUHAL),
    which converts rate and channel layout inside macOS. Do not fail as the
    wired path does, and do not change the device's rate.
  - The app gives the unit 44.1 kHz Float32 stereo, converted from the CD's
    16-bit samples with the same exact 2⁻¹⁵ factor. The app itself still
    does not resample, apply gain or mix.
  - The unit plays to the device's first two channels; there is no channel
    map yet.
  - While converting, a rate or format change on the device does not stop
    playback, because macOS follows it.
  - The output line and the rate icon's label say "Converted by macOS" and
    "macOS converts the audio"; otherwise they say "Native 44.1 kHz".
- **Choosing an output while playing:** playback moves between System
  Default and the built-in rule at once, at the same position. Stop restores
  any rate Play changed on the previous output; audio already read is not
  kept, so the drive reads from that position again.
- **A move that cannot start** stops at that position with the new output's
  error, as a failed Play does. Play tries the selected output again from
  there.
- **Default changes:**
  - While playing, a default the user chooses in the Sound menu moves
    playback to it at once, as a choice in the app does.
  - A default that changes because the previous default device disappeared
    pauses playback instead, shows "OUTPUT LOST", and names the lost device
    in the tooltip (see "When the selected output is missing"). Play, Stop,
    a track change or seek, or choosing an output clears it.
  - The two are told apart by checking whether the previous default device
    still exists after a 500 ms settling delay. macOS may announce the new
    default before it removes the old device, and the device-list and
    default-output notifications can arrive in either order.
  - The default change is noticed either by the output monitor or by the
    playback status check, whichever comes first.
  - While stopped or paused, the selector just shows the new default.
- **Fallback:** System Default is the last-resort automatic choice, so when
  no wired output can play 44.1 kHz stereo it is selected and labelled
  "best effort".
- **Wording:** labels say "best effort" and never "bit-perfect".
- **Deferred to M6.3b:** when the default device is also listed as a wired
  entry, the tooltip should suggest choosing it directly for the
  sound-quality path. That waits until choosing a wired entry routes to it;
  today it would play through the built-in rule instead.

**Acceptance (met offline):** fake-engine tests cover:

- resolving the default, and its icon;
- a chosen default change while playing (the audio moves, through either
  notification path) and while stopped (the selector updates);
- a default change caused by a disconnect (playback pauses), with the
  notifications in either order;
- moving between System Default and the built-in rule while playing, and a
  move that cannot start;
- the conversion labels when 44.1 kHz or stereo is unavailable;
- no rate change when the device cannot switch;
- no default output, which disables the entry.

**Still to check live:**

- **Verified live (2026-11-01), WH-1000XM3:** with System Default selected
  and WH-1000XM3 as macOS's Bluetooth default at 44.1 kHz stereo, the owner
  heard playback. While it played, the owner switched the Mac's output from
  the Sound menu to the MacBook Pro Speakers and then back to WH-1000XM3. The
  app followed both changes at the same position (166.01 s and 171.21 s),
  with 0 underrun frames and 0 concealed sectors, and the owner heard audio
  in every case. After a manual pause, the speakers were idle at their
  original 48 kHz with unchanged volume and mute, every wired device matched
  its setup snapshot, and no rate-recovery record remained. The speakers' rate
  during their brief use was not captured. Since this endpoint advertises
  44.1 kHz stereo, this run does not exercise the conversion fallback or its
  label.
- **Subjective Bluetooth delay check (2026-11-01):** during WH-1000XM3
  playback, the owner reported no noticeable offset between the display and
  the music, and no audible sound continuing after Pause. This is a subjective
  check, not a measured latency.
- **N-50 AirPlay preflight (2026-11-01):** the owner selected N-50 in
  macOS's output menu while CDPlayer was paused on System Default.
  Read-only discovery identified N-50 as the default at 44.1 kHz stereo.
  When playback was attempted, the log recorded 0 underruns at start, then
  macOS changed the default back to WH-1000XM3 and CDPlayer followed it.
  The owner reported the Sound menu kept loading and could not select N-50;
  N-50 audibility was not confirmed. The AirPlay-to-Mac check below replaces
  this as the AirPlay pass. Either way, CDPlayer plays into a macOS AirPlay
  output on System Default and never talks to the receiver. Retrying the
  N-50 is optional. It would add a receiver that supports only the original
  AirPlay (it advertises `_raop._tcp` but not `_airplay._tcp`), its
  front-panel input rate, and wake from network standby. After the owner
  turned the N-50 off, macOS kept a stale "N-50 (AirPlay)" output in the
  Sound menu and CoreAudio, even after a Wi-Fi reconnect, although Bonjour
  no longer listed it. This is a macOS issue, not a CDPlayer one.
- **Verified live (2026-11-01), AirPlay to another Mac:** the owner chose
  another Mac on the network as the AirPlay receiver while CDPlayer stayed on
  System Default, and heard the CD there. macOS's default output was an
  AirPlay device named "AirPlay" at 44.1 kHz stereo; the selector showed
  "AirPlay" with no conversion label. Playback ran from 713.62 s to a normal
  pause at 841.39 s with 0 underrun frames and 0 concealed sectors. The owner
  reported no noticeable display offset and no sound after Pause. The wired
  devices were unchanged, and no rate-recovery record remained. The 44.1 kHz
  rate is that of the local AirPlay device only. It says nothing about the
  network stream or the receiving Mac's output, so this is not a bit-perfect
  claim.
- **AirPlay receiver sleep during playback (2026-11-01):** the owner put the
  receiving Mac to sleep while CDPlayer played over AirPlay. The owner
  reported that CDPlayer kept playing but there was no audio. The player log
  recorded no output-loss pause or route change; after the test, macOS still
  listed AirPlay as the system default at 44.1 kHz. CDPlayer did not show
  "OUTPUT LOST" or switch to another output. The test did not establish
  whether CoreAudio notified the app that the remote receiver had gone
  silent. This differs from a Bluetooth device or wired device disconnect,
  which CDPlayer detected and paused for.
- **Verified live (2026-11-01), AirPlay receiver Wi-Fi disconnected:** while
  playback was audible on the receiving Mac, the owner turned off its Wi-Fi.
  A read-only output monitor showed AirPlay remained the system default until
  23:25:25, when macOS switched the default to MacBook Pro Speakers. At
  23:25:24, CDPlayer paused because the output disappeared, with 0 underrun
  frames and 0 concealed sectors. The window showed `OUTPUT LOST` and
  MacBook Pro Speakers in the selector. The app remained paused; it did not
  resume on the speakers. This verifies recovery when macOS removes the
  AirPlay route. It complements the sleep test, where macOS retained a silent
  AirPlay output and CDPlayer could not detect receiver loss.
- **AirPlay receiver reconnection while paused (2026-11-01):** after the
  receiving Mac's Wi-Fi was turned back on, Bonjour advertised the receiver
  again. The owner selected it from macOS's Sound menu;
  AudioCheck then showed the AirPlay output as the system default at 44.1 kHz
  stereo. CDPlayer remained paused and continued to show `OUTPUT LOST`; it
  did not auto-resume. After the owner pressed Play manually, playback resumed
  audibly over AirPlay; the log showed 0 underruns and the window returned to
  `CD PLAYING`. Restoring the route does not auto-resume a paused CD, but
  manual playback recovery succeeded.
- **Verified live (2026-11-01), Bluetooth disconnect:** with System Default
  selected and WH-1000XM3 playing, the owner turned the headphones off.
  Playback paused through the disappeared-output path at 182.04 s, with
  0 underrun frames and 0 concealed sectors. It did not move to the speakers.
  The window showed "OUTPUT LOST" with MacBook Pro Speakers, macOS's new
  default, in the selector. The strict wired `after` check against the setup
  snapshot passed, and no rate-recovery record remained.
- **Verified live (2026-11-01), wired-default unplug:** with System Default
  selected and the PRO X as macOS's default playing at 44.1 kHz stereo, the
  owner unplugged its USB cable. Playback paused at 343.24 s through the
  disappeared-output path, with 0 underrun frames and 0 concealed sectors,
  and showed "OUTPUT LOST" without moving to the speakers. The PRO X's rate
  record was kept while it was absent; other wired devices were unchanged.
  After the owner reconnected it, CDPlayer stayed paused; the PRO X was idle
  at its original 384 kHz with volume and mute unchanged, and the record was
  cleared. macOS made the PRO X its default again on reconnection.
- **Verified live (2026-11-01), System Default conversion through 8-channel
  Samsung HDMI:** the owner selected Samsung HDMI as macOS's default while
  CDPlayer remained on System Default. Before playback, the output was idle at
  48 kHz with an 8-channel stream. During playback it was running at 44.1 kHz
  with 8 channels; the owner heard audio from the receiver and reported the
  best-effort/macOS-conversion path. Playback had 0 underruns. After Pause,
  the output returned to its original 48 kHz/8-channel formats, the recovery
  record was cleared, and AudioCheck's `after` comparison passed. This checks
  the macOS channel-layout conversion path for a stereo CD source on an
  8-channel default output; it is not evidence of bit-perfect delivery.
- **Delay:** Core Audio reported 88,200 output-stream latency frames for
  AirPlay at 44.1 kHz (2.0 seconds), matching the owner's later observation
  that sound trailed the display by about two seconds. CDPlayer now applies
  reported stream latency to the displayed track and time while leaving the
  playback cursor unchanged. Unit coverage checks start clamping and stable
  pause/resume. The owner re-tested live on the receiving Mac and confirmed
  that the
  display tracks the audio and stays stable after Pause. The reported value
  is not a direct acoustic measurement. The owner also confirmed that the
  display aligns with WH-1000XM3 Bluetooth audio and stays stable after Pause.
  `AudioCheck --system-default` returned 0 latency frames at 44.1 kHz during
  audible Bluetooth playback, but also reported `Already running: false`, so
  that quantitative reading is inconclusive.

#### M6.3b — Native 44.1 kHz on the selected wired output

**Partly implemented (2026-11-01).** Playback routes to a selected USB, HDMI,
DisplayPort or Thunderbolt output by persistent UID, and the offline suites
pass, but some of the items below and part of the acceptance are still open
(see "Status against the acceptance"). Subsequent silent CD checks pass on
the PRO X, WALKMAN and Samsung HDMI; these do not establish audible channel
placement or end-to-end bit-perfect output.

- **Same rate rules as built-in output:**
  - Play switches the selected output to 44.1 kHz and verifies the rate.
  - Pause, Stop, eject and quit restore the original rate, unless the rate
    icon keeps 44.1 kHz.
  - After a crash, the next launch restores the rate.
  - The existing per-UID rate records already work for any device. A record
    for a device that is disconnected when the app restores rates is kept
    until the device returns.
  - The 48 kHz fallback is offered only when no record exists, as now.
- **Same sharing policy as 1.0.0:**
  - No exclusive (hog) mode.
  - Switch the rate even when other apps are playing to the device; refuse
    only when another app has exclusive use.
  - macOS resamples the other apps' audio, and while they make sound the
    output is a mix.
- **Same sample path:**
  - Send the CD's 16-bit samples as 32-bit float with no app gain.
  - Accept whatever stereo integer physical format the device uses at
    44.1 kHz: 16-bit on the N-50 and 32-bit on the PRO X in the live checks.
    16-bit values pass through either format unchanged. Chosen directly,
    the N-50 plays at 32-bit, the first format it advertises at 44.1 kHz.
- **Multichannel outputs (common on HDMI):**
  - The current implementation retains the output's channel layout and can
    play a single multichannel Float32 stream with compatible physical PCM.
  - Prefer an advertised 2-channel 44.1 kHz Float32 virtual format paired
    with an advertised 2-channel integer PCM physical format. If the device
    offers no compatible pair, retain the existing multichannel route.
  - Persist the original virtual and physical formats before changing the
    output. Restore only formats that still match the app-applied values;
    preserve external changes and retain records when recovery cannot finish.
  - Write the physical format first, and the virtual format only if it is
    still not the target. A virtual write lets macOS re-pick the physical
    bit depth: on the N-50, 48 kHz 16-bit came back as 32-bit (M6.5).
  - Otherwise, send left and right to the device's preferred stereo channels
    and silence to the rest.
  - This needs hardware testing before it ships.
- **Moving playback between wired outputs:** extend the M6.3a move to
  every wired output (see "Moving playback to another output"). Stop the
  old output at the current frame, restore the rate Play changed on it,
  prepare the new output, and continue from the same frame.
- **System Default tooltip:** when the default device is also a listed
  wired entry, suggest choosing it directly (deferred from M6.3a).
- **Route checks during playback:**
  - Look up the selected UID instead of re-running the built-in rule.
  - If the output disappears, follow the missing-output rules (M6.4).
  - If its rate changes or another app takes exclusive use, pause at the
    current position, as 1.0.0 does for built-in route changes.
- **Errors** name the selected output instead of "the built-in output".
- **Clock:** do not try to control a DAC's clock. Asynchronous DACs use their
  own clock and USB feedback.

**Acceptance:** Offline tests, for a non-built-in output, cover:

- rate and preferred-format switching/restoration on every exit path,
  including partial setter failures and recovery while retaining a
  user-kept 44.1 kHz rate;
- refusal when another app has exclusive use;
- crash recovery with the device absent and present;
- multichannel mapping;
- an output without 44.1 kHz;
- moving playback between two outputs: the position is kept, the previous
  output's rate is restored, the new rate is verified, and a failure to start
  stops at that position, as in M6.3a.

Live checks confirm both the Core Audio rate and, where the device reports
it, the device's own rate.

**Status against the acceptance (2026-11-01 review):**

- Covered by offline tests: UID-targeted inspection, rate selection and
  playback; moving playback at the same frame, with a failed start stopping
  there and a retry; selected-output loss, pause at the current position and
  fallback; the mapped PCM renderer on its own. Regression tests now cover
  acceptance of 8-channel interleaved and planar formats, rejection of
  incompatible formats, and exact mapped PCM/checksums with unused channels
  and EOF tails silent. The selector refuses an unsupported-rate output;
  injected exclusive-use failures stay on the selected wired UID; and quit
  forwards rate cleanup for that UID. The shared C rate coordinator is now
  exercised with an injected offline device/rate/store backend for apply,
  restore, external rate changes, external hog ownership, absent/reconnected
  outputs, recovery-only filtering, failure retention and two-output moves.
- Still not verified against the production adapters or live hardware:
  Core Audio's actual refusal when another app has exclusive use, and crash
  recovery on a physical output that is absent and later reconnects. (Real
  CFPreferences persistence across a killed process, and recovery on a
  present output, have since passed live on HDMI.) The new stereo
  preference is covered by offline format-selection and recovery tests, but
  the production playback format-enumeration/setter path has not yet been
  exercised on hardware. Read-only diagnostic enumeration is tracked below
  and does not invoke that playback path. Offline tests execute the shared C recovery
  coordinator with an isolated fake device and record store; they never
  access Core Audio devices or the app's preferences domain.
- The System Default selector tooltip and accessibility help now suggest
  choosing the matching enabled wired entry for direct 44.1 kHz playback.
  Unsupported wired defaults and wireless defaults do not receive that
  suggestion.
- Subsequent live coverage: about 30 seconds of silent real-CD PCM on each
  of PRO X, WALKMAN and Samsung HDMI. Engine-level start, seek, track boundary,
  pause/resume and exact disc end all pass, with independent reference-read
  checksums and restoration after every segment. Core Audio physical formats
  were independently observed at 44.1 kHz: stereo 32-bit PCM on both USB
  devices and 8-channel 24-bit PCM on HDMI. This fixes and exercises the
  single-stream multichannel blocker, but does not close the other acceptance
  gaps above or replace listening, disconnect/reconnect, receiver-lock or
  multistream AUHAL checks.
- Subsequent offline coverage: the output-format predicate, multichannel
  renderer, unsupported-rate selector behavior, injected exclusive-use
  failure handling, and quit-time cleanup request for the selected UID pass.
  See the M6.3b test follow-up in the development log.
- Stream topology handling now distinguishes a successful single-stream
  query, a successful multi-stream query, and failed or malformed queries.
  Only a successful multi-stream result selects AUHAL conversion; property
  query failures are surfaced instead of being treated as multistream.
- The single-stream wired route now prefers an advertised 44.1 kHz stereo
  Float32 virtual format and stereo integer physical format. It saves the
  original virtual and physical ASBDs in the existing per-UID recovery
  record before changing either the rate or stream formats. Devices without
  a compatible pair keep the existing multichannel mapping path. Offline
  tests cover candidate selection, rate-only record compatibility, retry
  after partial format changes, external changes, reconnect recovery and
  restoration without undoing a user-kept 44.1 kHz rate.
- Before/during/after configuration checks are now prepared as read-only JSON
  snapshots and offline comparisons in `AudioCheck`. They verify full ASBDs,
  rates, protected controls, input streams and other captured wired devices;
  they do not activate playback or perform recovery. The initial read-only
  preflight on 2026-11-01 found neither PRO X, Sony USB DAC nor HDMI currently
  exposed to macOS. Built-in states matched across captures.
- After the owner connected PRO X, its read-only readiness and unchanged-state
  comparisons passed. It was idle/unowned at 384 kHz, with stereo Float32
  virtual and Int32 physical PCM, an advertised 44.1 kHz stereo pair and
  writable rate/format properties. MacBook Pro Speakers remained the default
  and system output; input devices and exposed controls were unchanged.
  Restoration from this baseline must return PRO X to 384 kHz; take a fresh
  baseline after reconnecting and before any later authorized activation.
  This advertised pair changes only the sample rate, not the channel count or
  PCM representation.
- Sony USB DAC (WALKMAN) also passed read-only readiness and unchanged-state
  checks. It was idle/unowned at 384 kHz, with stereo Float32 virtual and
  Int32 physical PCM, an advertised 44.1 kHz pair and writable rate/format
  properties. Default routes, exposed clock metadata and built-in controls
  stayed unchanged. Sony exposes no volume/mute properties to this reader,
  so its hardware volume is outside the snapshot verification. This pair
  also changes only the sample rate; a later activation needs a fresh
  baseline.
- Samsung HDMI also passed read-only readiness and unchanged-state checks.
  It was idle/unowned at 48 kHz with one 8-channel stream (Float32 virtual,
  24-bit integer physical) and advertises a 44.1 kHz **stereo** pair, so
  selected-UID playback would now change its channel count from 8 to 2, not
  just the rate. The earlier silent check used the 8-channel mapped path, so
  its new stereo transition was then exercised by an approved silent
  selected-UID CD test. The during snapshot and comparator passed at 44.1 kHz
  stereo; start, seek, track-boundary, pause/resume and end segments passed
  PCM checksum and zero-underrun checks. Every segment restored 48 kHz, and
  the final strict snapshot matched both original 8-channel ASBDs and the
  other captured state. The original drive speed was restored. This confirms
  the reported Core Audio format transition and app-level restoration, not
  audible output or physical TV lock/channel mapping: the callback emitted
  zero samples and TV volume/mute are not exposed. The remaining
  format-changing checks remain pending.
- PRO X then passed the same silent selected-UID test: 44.1 kHz stereo during
  playback, six segments with matching checksums and no underruns, 384 kHz
  restored after each segment, and a strict after snapshot matching the
  baseline, including its exposed volume and mute. Sony live testing and
  restart recovery were still pending at this point; both results are
  recorded below.
- Sony WALKMAN then passed the same silent selected-UID test: 44.1 kHz stereo
  Float32/Int32 during playback, six segments with matching checksums and no
  underruns, 384 kHz restored after each segment, the original drive speed
  restored, and a strict after snapshot matching the baseline. All three
  wired outputs have now passed the live stereo-format test. Sony
  restart/crash recovery had not yet been tested at this point.
- Crash-recovery tooling is ready: `AudioCheck --verify-output-state crashed`
  proves a killed silent run left the applied formats behind, and
  `AudioCheck --recover-output-rates` runs the app's launch-time recovery and
  requires every saved record to be cleared. Drive read speed has no saved
  recovery record (known gap).
- **The live kill-and-recover test passed on Samsung HDMI.**
  - A selected-UID silent run was killed with SIGKILL during its first
    segment. The saved record survived the kill.
  - The crashed check found HDMI idle but still in the applied 44.1 kHz
    stereo pair, with everything else unchanged.
  - The launch recovery restored 48 kHz and the original 8-channel
    Float32/24-bit integer formats, then cleared the record. The strict
    after check matched the baseline.
  - The drive's speed readback was 4,233 kB/s afterwards. This drive never
    reports the minimum-speed request, so the speed gap could not be
    observed.
  - The absent-output case also passed: with HDMI disconnected, recovery
    failed as expected and kept the complete record unchanged; other
    devices, defaults and protected controls stayed unchanged. After HDMI
    reconnected, it retained the applied 44.1 kHz stereo formats; recovery
    restored the original 48 kHz, 8-channel formats and cleared the record.
  - The rebuilt Release GUI app also recovered the pending HDMI record on
    launch, without starting playback. A strict after check matched the
    original baseline and the record was cleared.
  - First audible check passed: the Release GUI app played a CD through
    Samsung HDMI and the owner heard it from the receiver. The short run
    (with a seek) logged 0 underrun frames and 0 concealed sectors. After
    pause, HDMI was back at 48 kHz with 8 channels and no record remained.
  - A read-only capture during a second playback confirmed Samsung HDMI was
    running at 44.1 kHz, stereo (32-bit float virtual / 24-bit integer
    physical); the strict during-state comparison passed.
  - Receiver-side format verification also passed: during playback, the
    owner read PCM, 44.1 kHz and 2 channels from the Yamaha HTR-3066's
    Signal Info menu, matching the Mac-side capture.
  - Physical channel check passed: the owner heard distinct left and right
    channels through the receiver's speakers and through its headphone
    output. A labelled left/right identification track was not used, so a
    swap is not formally excluded.
  - PRO X audible check passed: with the PRO X selected, the owner heard
    distinct left and right channels. A read-only capture during playback
    showed it running at 44.1 kHz stereo (32-bit float virtual / 32-bit
    integer physical), down from its 384 kHz baseline.
  - After pause, the PRO X returned to 384 kHz and was idle. The strict
    after-state check reported volume-control differences on both the PRO X
    and MacBook Pro Speakers; Control Center logs show volume changes during
    the test, not writes by CDPlayer. No volume or mute was restored by the
    agent.
  - Sony WALKMAN live-format check passed on a second playback: while running,
    its virtual and physical stereo formats were 44.1 kHz, and the strict
    during-state comparison passed.
  - After the owner paused, the WALKMAN returned idle to its original
    384 kHz stereo virtual/physical formats; the strict after-state comparison
    passed. The app logged 0 underrun frames and 0 concealed sectors. The
    owner subsequently confirmed hearing both left and right channels.
  - Live move from a selected wired output to System Default passed. While
    the PRO X was playing as the selected output, the owner chose System
    Default in CDPlayer's selector. macOS's default was the MacBook Pro
    Speakers. Playback moved at 223.69 s with 0 underrun frames and 0
    concealed sectors and, as the owner reported, continued audibly. After
    the owner paused, the PRO X was idle at its original 384 kHz formats,
    with volume and mute unchanged. The strict after checks for PRO X and the
    speakers passed against the setup snapshot, and no rate-recovery record
    remained. Formats during the brief PRO X and speaker playback were not
    captured.
  - Wired-output handoff passed live in both directions. With the PRO X as
    macOS's default and CDPlayer on System Default, playback moved to the
    selected WALKMAN at 433.11 s; the owner heard it continue. The owner
    then selected the PRO X directly, and playback moved back at 528.37 s.
    Both moves logged 0 underrun frames and 0 concealed sectors. During the
    handoffs, the active output was at 44.1 kHz stereo; the inactive device
    returned to 384 kHz. After pause at 560.53 s, both devices were idle at
    their original 384 kHz formats and the recovery record was cleared.
    Volume and mute values were unchanged. The strict after checks reported
    only the default-input change associated with macOS's PRO X selection.
    The first leg began on System Default (physically the PRO X), not on an
    explicitly selected PRO X UID; the return leg was a direct selected
    WALKMAN-to-PRO-X handoff.
  - **PRO X crash/restart recovery passed (2026-11-02).** A fresh baseline
    showed the output idle at 384 kHz with its original stereo formats and no
    recovery record. A silent observation changed it to 44.1 kHz stereo; the
    active-state comparison passed and the saved record preserved the original
    384 kHz virtual/physical formats. After the run was killed with SIGKILL,
    the crashed-state comparison passed with the output idle at 44.1 kHz and
    the record intact. Launching the rebuilt GUI app restored 384 kHz and
    cleared the record; the strict after comparison passed. The kill bypassed
    drive-speed cleanup, so post-test drive speed was not verified. Sony
    recovery is recorded in the following test result.
  - **Sony WALKMAN crash/restart recovery passed (2026-11-02).** The fresh
    baseline showed the output idle at 384 kHz with its original stereo
    formats and no recovery record. The silent run started, and its active
    snapshot passed at 44.1 kHz stereo; the saved record retained the original
    384 kHz formats. After SIGKILL, the crashed-state check passed with the
    output idle at 44.1 kHz and the record intact. Launching the rebuilt GUI
    app restored 384 kHz and cleared the record; the strict after comparison
    passed. The kill bypassed drive-speed cleanup, so post-test drive speed
    was not verified.
  - The full package suite passed normally and under Thread Sanitizer:
    365 CDKit tests in 7 suites and 20 AudioCheck tests in 1 suite for each
    run.

### M6.4 — Disconnects, receivers and volume guidance

- **Device changes during playback:**
  - unplug or power-off;
  - an input or mode change;
  - display sleep, which can remove HDMI audio (on the Samsung it silences
    the TV but macOS keeps the output, so the app cannot detect it);
  - other device-list changes.

  In each case:
  - pause at the current position;
  - select the next best output and show which output was lost;
  - keep the rate record for later restoration;
  - never resume automatically.
- **Reconnection:** apply the reconnection rule from "When the selected output
  is missing".
- **Volume:**
  - Detect whether the selected output exposes host volume or mute controls.
  - macOS volume keys change the system default output. With System Default
    selected that is the output playing the CD; with a wired output selected
    it may not be. Observed live on 2026-11-01: during PRO X playback, the
    keyboard volume keys changed MacBook Pro Speakers (the system default),
    not the app-selected PRO X. The owner reported they could not change
    headphone volume. A later Control Center event changed the PRO X host
    volume too; the source of that adjustment was not established.
  - Some devices have no host volume at all: the Walkman, the N-50 (mute
    only), and probably many HDMI receivers.
  - For such outputs, say "volume on device" in the menu entry and tooltip
    only. There is no status-line warning (decision 15).
  - When a directly selected output is not the macOS default, the tooltip
    names the output the volume keys control, such as "Volume keys control
    MacBook Pro Speakers" (decision 16).
  - While the CD plays on such an output, the default's volume and mute are
    mirrored onto it, so the volume keys reach the output that is playing
    (decision 19). Otherwise the app never changes volume or mute, and it
    adds no software volume control.
- **Device settings:**
  - Explain settings that must be made on the device, such as the USB-DAC
    input on the N-50 or a "Direct"/"Pure" mode on a receiver.
  - Do not claim to detect those settings.
- **Receiver lock time:**
  - HDMI receivers may mute briefly while they lock to a new rate, both on
    Play and when playback moves to them.
  - On HDMI and DisplayPort outputs, every start plays a silent lead-in of
    at least 1 second before the first CD sample (decision 17). Test by ear
    whether the start of the audio is still lost, and tune the duration.
- **Lost-output notice:** see "When the selected output is missing" and
  decision 14. A directly selected wired output that disappears during
  playback must show `OUTPUT LOST`, not only `CD PAUSED`.

**Acceptance:**

- Fake-engine tests cover a disconnect while stopped, paused and playing,
  the next best output chosen, the notice, and reconnection.
- Offline render tests cover the lead-in: silence first, then the source
  from the start position, with no underrun, clock or checksum change.
- Hardware tests confirm a safe pause, the fallback, rate restoration and
  recovery after reconnect.

**Implementation (2026-11-02, offline):**

- **Lost output:** the selected device's name is saved with its UID.
  `OUTPUT LOST` outranks the disc statuses (`NO DISC`, `READING`) because the
  user must act on it, and only an error outranks it. During playback, the
  snapshot path checks whether a failed device is still listed, so exclusive
  use by another app stays a plain pause. A missing saved output at launch is
  named until Play on the fallback; it is not raised again after that.
- **Volume:** the C core reports `hasVolumeControl` when the output has a
  settable volume on its main or first two channels. AirPlay outputs report
  host volume. The tooltip is built from sentences: the output, the System
  Default suggestion, the volume-keys hint and the lost-output text.
- **Lead-in:** `cd_output_lead_in_frames` returns 1 second of frames for
  HDMI and DisplayPort and none otherwise. Start sets it for the output it
  chooses and every prepare restarts it. The callback writes zeros and
  counts down only after output is enabled, rounding up to whole callback
  buffers; the ring, the clock, underruns and the checksum are untouched.
  `AudioCheck --list-outputs` prints the host-volume flag.
- **Volume keys (decision 19):** `PlayerModel` recomputes the pair (the
  listed default and the listed output that is playing, both with host
  volume) whenever the state, the output, the output list or the playback
  target changes, and passes it to a `VolumeMirroring` dependency.
  `VolumeMirrorSync` holds the rules without Core Audio, so fakes test the
  alignment direction, both copy directions, mute, driver rounding,
  late-applied writes and a change that arrives during a write. Only the
  written side is read back, so such a change is still copied. `CoreAudioVolumeMirror` resolves each UID on every
  call, reads and writes `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`
  and mute, and listens for volume and mute changes on both devices from a
  private queue.
- The hardware tests are listed in the
  [development guide](DEVELOPMENT.md#external-outputs-and-receivers).

### M6.5 — Hardware validation and release

- **Devices:**
  - the Walkman, PRO X and N-50 over USB;
  - built-in speakers and wired headphones;
  - at least one HDMI receiver or TV;
  - a DisplayPort or USB-C display with speakers, if one is available;
  - for System Default: Bluetooth headphones and an AirPlay output.
- **Scenarios:**
  - switching between outputs while stopped, paused and playing;
  - a remembered output absent at launch, and its reconnection;
  - stop, eject and quit;
  - unplugging during playback;
  - with System Default selected, choosing a new default in the Sound menu,
    and switching off Bluetooth headphones, during playback;
  - the output name scrolling with the N-50's USB name and an error status;
  - sleep and wake.
- **Rate and format:**
  - Confirm them using Core Audio and, where available, the device's own
    display (the N-50's front panel showed 44.1 kHz in the first live check).
  - Record whether other apps were playing to the device during each test.
- **PRO X:**
  - Check that CD Player does not enable or change the mic or sidetone
    settings.
  - Record whether sidetone is audible during CD playback. Check F confirmed
    no audible sidetone while stopped or playing. The microphone stayed
    idle at 48 kHz, with its formats, volume, mute and driver-reported
    sidetone settings unchanged before, during playback and after Stop.
- **Docs:** update the architecture, development guide, changelog and hardware
  test instructions before release.

**Acceptance:**

- Existing offline tests, AddressSanitizer, ThreadSanitizer and the build
  pass.
- The manual hardware matrix passes.
- Built-in playback behaviour is unchanged.

**Coverage so far (2026-11-02):**

- Done: PRO X and WALKMAN over USB (playback, a move while playing, unplug,
  absent at launch, reconnect, crash recovery, volume); Samsung HDMI
  (format, lead-in, input change, display sleep); WH-1000XM3 Bluetooth and
  AirPlay to another Mac through System Default (following a new default,
  disconnect); built-in speakers as the fallback.
- Done in M6.5: A. wired headphones on the built-in jack; B. the N-50 over
  USB (44.1 kHz on its front panel, the tooltip, the name beside
  `CD PLAYING`); C. switching outputs while stopped and while paused;
  D. Stop, Eject while stopped, and Quit while playing on the N-50, each
  leaving it at its original 48 kHz 16-bit.
- E. Mac sleep and wake, then Play and Stop, passed on the N-50 and Samsung
  HDMI with the fixes (23:11–23:23). Both stayed paused at the saved position
  after wake with no error and resumed audibly only on Play, with
  0 underrun frames. Fresh snapshots matched after wake and after Stop:
  48 kHz 16-bit stereo on the N-50, and the original 48 kHz eight-channel
  formats with 24-bit physical PCM on HDMI. No recovery record remained.
  The N-50 needed deferred restoration after wake; HDMI finished restoring
  before sleep.
- Fixed in M6.5: after Stop the N-50 came back at 48 kHz 32-bit instead of
  16-bit. Restore now skips a virtual-format write the physical restore
  already made unnecessary (see the development log). Check D was run
  with the fix. Sleep while playing on the N-50 showed an audio error,
  because macOS holds the format restore until wake; the restore now
  finishes after wake (decision 22).
- F. PRO X mic and sidetone check passed (23:36–23:38). The owner heard normal
  CD playback and no sidetone, either stopped or playing. Getter-only samples
  showed the separate microphone idle at 48 kHz with unchanged input formats,
  volume, mute and sidetone controls. After Stop, the output returned to its
  original 384 kHz formats. The only snapshot difference was the approved
  Play-time alignment of the default speakers' volume to the PRO X; the
  PRO X's own volume did not change.
- All available M6.5 hardware checks A–F are complete.
- Not available: a DisplayPort or USB-C display with speakers. DisplayPort
  and Thunderbolt playback stay untested for 1.1.0.
- Release (decision 21): changelog, architecture and development guide, the
  version set to 1.1.0, Release build and signature check, ZIP, tag, push
  and GitHub release.

## Decisions

Confirmed by the user on 2026-10-31 (1–8), 2026-11-01 (9–13, and the
scrolling row 2 in decision 4) and 2026-11-02 (14–22):

1. **One output at a time.** Several outputs can be listed, but only the
   selected one plays. There is no simultaneous playback.
2. **Wired outputs are the sound-quality path.** These are built-in, USB,
   HDMI, DisplayPort and Thunderbolt. Bluetooth and AirPlay play through
   System Default, where bit-perfect output is best effort only.
3. **System Default has the lowest preference.** It is listed last, because
   the app focuses on sound quality. It is used when the user selects it, or
   as the last fallback when no wired output is available.
4. **Layout:**
   - The source text moves beside the power button.
   - The output selector takes its old place and shows only the device name,
     with no "Default:" prefix, even for System Default.
   - When row 2's text does not fit, only the output name scrolls
     horizontally instead of truncating; the status stays fixed at the left,
     and the menu indicator and the rate icon stay fixed at the right
     (refined by the user on 2026-11-01).
   - The output name is shown no wider than half of row 2; a longer name
     scrolls within that width (added by the user on 2026-11-01).
   - The rate icon keeps its current behaviour.
5. **The selected output follows the built-in output's behaviour.**
   - Native 44.1 kHz on Play, with the same restore rules.
   - The same sharing policy: switch the rate even when other apps play to
     the device, refuse only when another app has exclusive use, and no hog
     mode.
   - This replaces the earlier proposal to warn before changing the rate of
     a device another app is using.
6. **No resampling on the wired path.** Wired outputs without 44.1 kHz
   stereo PCM are listed but disabled, and are used through System Default.
7. **A missing or lost output pauses and falls back.** Playback pauses, the
   next best output is selected, and the app waits for the user to press
   Play.
8. **Choosing another output moves the audio at once.** This applies to a
   choice in the app during playback, and to a new default chosen in the
   macOS Sound menu while System Default is selected.
9. **Next best order:** the macOS default output if it is a listed wired
   output that can play 44.1 kHz stereo, then Built-in, then System Default.
10. **Reconnection:** the saved choice is kept. When it reappears, the
    selector returns to it if playback is stopped or paused; playback running
    on the fallback continues until the user chooses.
11. **Default lost while System Default is selected:** when macOS changes
    the default because the previous device disappeared (for example,
    Bluetooth headphones switched off), playback pauses rather than moving to
    the new default, so it never jumps from headphones to speakers.
12. **Icons show the output type.** Menu entries and the rate icon use a
    symbol for the output's connection, such as USB, HDMI or AirPlay (see
    the table under "Interface plan").
13. **System Default first.** System Default and the icons come before
    routing to wired outputs: M6.3a, then M6.3b.
14. **Lost-output notice.** When the saved output is missing at launch, or
    disappears while stopped, paused or playing, the status line shows
    `OUTPUT LOST` in the warning colour and the selector's tooltip names the
    output. The notice clears on Play, another output choice, or
    reconnection of the lost output.
15. **Volume guidance without a status warning.** Outputs without a host
    volume control say "volume on device" in the menu entry and tooltip
    only. The app changes volume or mute only to mirror the volume keys
    (decision 19).
16. **Volume-keys hint.** When a directly selected output is not the macOS
    default, the tooltip names the output that the volume keys control.
    When decision 19 applies, it says the keys set both outputs while
    playing.
17. **HDMI and DisplayPort lead-in, always.** Every start on these outputs
    (Play, resume, seek, track change or a move to the output) plays at
    least 1 second of silence before the first CD sample. It overlaps
    start-up buffering, so it adds delay only when the buffer fills sooner.
    It is not an underrun, does not move the clock, and is not part of the
    PCM checksum. The duration is a constant, tuned on the Yamaha
    HTR-3066.
18. **Code first.** M6.4 code and offline tests come before its hardware
    tests.
19. **The volume keys follow a directly chosen output (2026-11-02).** The
    owner asked for the volume keys to change the PRO X when it is chosen
    directly while another output is the macOS default. This replaces "the
    app never changes volume or mute" from decision 15.
    - **When:** the CD is playing on a directly chosen output that is not
      the macOS default, and both outputs have a host volume control. A
      level outside 0–1, as the N-50's AirPlay output reports, counts as no
      control. There is no mirroring on System Default, while stopped or
      paused, or for an output whose volume is on the device.
    - **Start:** when mirroring starts (Play, resume, a move to the output
      or a new default), the default's level is set to the chosen output's
      level, so the output that is playing never jumps. Mute is not aligned:
      starting never mutes or unmutes either output.
    - **While playing:** a volume or mute change on either output is copied
      to the other, and the default wins when both change at once. This
      covers the volume keys, the menu-bar slider, Control Center and other
      apps. The written side is read back after each write, so driver
      rounding cannot start a loop.
    - **After:** nothing is restored. The default keeps the last mirrored
      level.
    - **Known effect:** if the default was muted when mirroring started, the
      first press of the mute key only unmutes the default; the next press
      mutes both.
    - The CD samples are unchanged. The level is applied by the output or
      its driver, exactly as when the user moves its slider.
20. **HDMI display sleep is documented, not handled (2026-11-02).** On the
    Samsung, display sleep silences the TV while macOS keeps the HDMI output
    listed and running, so the app has no signal to pause on. The
    development guide advises pausing before the display sleeps; the app
    does not pause on display sleep.
21. **Release 1.1.0 (2026-11-02).** M6 ships as version 1.1.0 once M6.5
    passes: a Release build, the ZIP from `Tools/package-release.sh`, a
    `v1.1.0` tag, `main` and the tag pushed to GitHub, and a GitHub release
    with the ZIP attached.
22. **An output macOS holds at sleep is restored after wake (2026-11-02).**
    Once sleep begins, macOS holds output format changes until the Mac
    wakes. The pause before sleep still tries to put the output back. If
    that does not finish, the app shows no error: it shows `CD PAUSED` at
    the same position, logs the failure and marks the output for recovery.
    After wake it finishes the restore under the usual rules. An output
    that is already back has its record dropped, one still at the playback
    format is restored, and a change made by someone else is left alone. A
    failure then shows the short audio error, as recovery does at launch.

## Out of scope for the first audio output milestone

- Playing to more than one output at once, whether through a macOS
  multi-output device or in the app.
- Listing Bluetooth, AirPlay, aggregate or virtual outputs individually, or
  claiming bit-perfect output for them. They play only through System
  Default.
- Encoded Dolby/DTS passthrough, upmixing or surround processing. CD audio is
  stereo PCM.
- Native DSD, or the Walkman's non-PCM raw-data mode. macOS does not expose
  that mode through the device's current Core Audio interface.
- Device-specific firmware commands, automatic input switching, volume or
  mute changes other than the volume-key mirror (decision 19), or control of
  a device's processing modes.
- Automatic playback, EQ, replay gain, loudness normalization, or software
  volume.
- Claims that a higher advertised bit depth or sample rate improves the CD
  source.
