# Audio Levels Roadmap

**Status:** M9.1–M9.4 are complete on 2026-11-03. The full 20-test UI suite,
normal and sanitized package tests, and live built-in, USB and AirPlay checks
passed. The owner also passed shadow, hide/restore, cover/uncover and native
minimize/restore checks. The README includes the extended-window screenshot.
**Release:** [Version 1.2.0](https://github.com/ylau674/CD-player/releases/tag/v1.2.0),
as milestone M9. It does not depend on the
[MQA-CD roadmap](MQA_CD_ROADMAP.md) (M7), which remains a draft, or the
[HDCD roadmap](HDCD_ROADMAP.md) (M8), which shipped later in 1.3.0.
**Basis:** A review of the 1.1.0 playback path, display and window code.
The source capture, Swift meter model and meter display are implemented and
accepted.

## Summary

Optional LED-style peak meters for the left and right channels sit at the
bottom of the player, below the transport buttons. **View › Show Audio
Levels** (⌘L) extends the window downward to show them, and they start
measuring once it is fully extended and visible. They stop measuring when
hidden, miniaturized, fully occluded or off-screen, and resume with a fresh
reading when visible again. The same command shrinks the window back. They
show the level of the source, the disc's own samples, measured as the disc is
read. The audio callback does not change, so the output stays bit-identical.

The current AppKit meter refresh rate is 10 Hz (reduced from the 15 Hz
described in the earlier implementation notes below). It changes only how
often the display samples and redraws level segments, not the captured PCM.

## Behaviour

### Showing and hiding

- **View › Show Audio Levels**, ⌘L. While the meters are shown, the item reads
  **Hide Audio Levels**. The item is always available, with or without a
  disc.
- The window's bottom edge moves down in about 0.25 s and uncovers the meters
  below the transport buttons. Hiding them moves the edge back up, to the
  window's original size. With Reduce Motion on, the window resizes at once
  and the meters fade in and out instead; when hiding, the window shrinks
  after the fade.
- **Measured only when fully shown** (decision 12):
  - The meters stay dark while the window extends, and start measuring once
    its bottom edge stops. With Reduce Motion, they start once they have
    faded in.
  - Hiding them darkens them and stops measuring at once, before the window
    shrinks or they fade out. Nothing is read while they are hidden.
  - After quick toggles, only the last show counts: the meters start once
    its animation ends.
- **Visible window:** the meters also stop reading and go dark when the
  player window is hidden, miniaturized, fully occluded or off-screen. They
  resume with a fresh reading when any part becomes visible again. Source
  recording remains on throughout.
- The window grows downward with its top edge fixed. If the taller window
  would go below the screen's visible area, the window first moves up just
  enough. Hiding the meters does not move the window back.
- The meters are hidden at every launch. Their state is not remembered.
- The meters have no buttons. Dragging them moves the window, like the
  display.

### Look

- **Style:** part of the display, inside the same dark-green panel with its
  white 1 pt border and rounded corners. They use the display's mint tint and
  monospaced labels, with no box of their own. (Versions after 1.3.5 replace
  that panel with Liquid Glass; the meters then use the system label colour.)
- **Bars:** two horizontal bars, L above R, with 20 segments each.
  - Lit segments use the display's mint. The peak-hold segment uses the power
    icon's red. Segments do not change colour with level: there is no amber
    or red zone.
  - Unlit segments stay faintly visible, like unlit LCD segments.
- **Scale:** labels under the bars at −40, −20, −10, −6, −3, −1 and 0 dB. Each
  is centred under the segment whose lower edge it names, and "dB" sits in
  the L/R legend column.
- **Size:** the window grows by 52 pt: a 10 pt gap below the buttons, then
  42 pt of meters (two 12 pt bar rows and a 10 pt scale row, 4 pt apart).

```
╭──────────────────────────────────────────────╮
│ display (unchanged)                          │
│ transport buttons (unchanged)                │
│                                              │   shown: the bottom edge
│ L  ■■■■■■■■■■■■■□□■□□□□                      │   moves down to uncover
│ R  ■■■■■■■■■■■□□□□■□□□□                      │   the meters
│ dB -40  -20  -10 -6 -3 -1 0                  │   ■ lit   □ unlit (faint)
╰──────────────────────────────────────────────╯   lone ■ = peak hold (red)
```

### What the meters show

- **What is measured:** the sample peak of each channel, in dBFS, of the
  source: the disc's 16-bit samples as they are read, after any concealment of
  unreadable sectors and before they enter the playback buffer.
  - The app sends these samples unchanged, so on a directly selected output
    this is also the level the DAC receives.
  - On a System Default route that macOS converts, the meters still show the
    disc's level.
  - The volume keys, the menu-bar slider and the device's volume do not move
    the meters.
- **Segment thresholds** (the lower edge of each segment, in dBFS): −40, −36,
  −32, −28, −24, −20, −18, −16, −14, −12, −10, −8, −6, −5, −4, −3, −2, −1,
  −0.5, then full scale.
  - The top segment lights only for a full-scale sample (+32767 or −32768)
    on the disc.
- **Ballistics:**
  - The bar rises instantly and falls about 20 dB in 1.7 s.
  - One peak-hold segment stays at the highest recent level for 1.5 s, then
    drops to the bar. At a new peak it is the bar's top segment.
  - The hold shows only at or above the bar's top. A hold that restarts from
    a quieter block while the bar is still falling stays hidden until the bar
    falls to it, so red never appears inside the bar.
- **Timing:** the meters are for reference, like the time display. They follow
  the position the time display shows, which already allows for the output's
  reported latency (2.0 s on AirPlay).
  - Any remaining offset from the sound is accepted. For example, Bluetooth
    reported no latency for the WH-1000XM3, so there the meters and the clock
    may run slightly ahead of the sound.
- **When the bars go dark:** they fall to off whenever the play position stops
  advancing: while playback is paused, stopped or buffering, during the HDMI
  lead-in, and after an output is lost. They are also dark with no disc,
  while the window extends or shrinks, and whenever it is not visible
  (decision 12). There is no
  power-on sweep.
- **Demo disc:** its test tones (amplitude 3,276) read −20 dBFS.
- **HDCD and MQA-CD:** the meters show the disc's samples as recorded, like
  any CD. If HDCD decoding (M8) ships, M8 decides whether they should show the
  decoded signal instead.

## Design

### Capture at the source (C)

- **Where:** the producer thread (`produce_audio` in
  [AudioPlayback.c](../Packages/CDKit/Sources/CDAudioCore/AudioPlayback.c))
  reads each block of up to 4,096 frames from the disc or the demo source,
  then writes it to the 30 s playback buffer. Once a block is in the buffer, a
  small C function records its per-channel peaks in the level table, by disc
  position.
- **The audio callback does not change.** The HAL render callback and the
  ring buffer's render code stay as they are in 1.1.0, so measuring cannot
  affect the output or its timing.
- **Always on:** the producer reads up to 30 s ahead of playback, so it
  records every block it reads, whether or not the meters are shown. When
  they are fully shown, the levels for the part now playing are already in
  the table. Only the meters' reads wait for that (decision 12).
- **Cost:** one compare per sample and one atomic store per 10 ms slot, on
  the producer thread, which is not a real-time thread. Recording allocates
  nothing and takes no locks, so it cannot block reading.

### Level table

- **Layout:** a fixed table of 10 ms slots (441 frames), indexed by disc
  frame. Its 4,096 slots cover about 41 s: the 30 s playback buffer plus
  AirPlay's 2.0 s latency, with room to spare.
- **Slots:** each slot is a single 64-bit atomic holding a run number, the slot
  number, and the left and right peaks.
  - One store publishes a slot, so a reader never sees half of one.
  - The packed value contains an 8-bit run tag, a 24-bit slot number, and two
    16-bit peak magnitudes. The full run ID is wider; the table is cleared
    before a run tag is reused.
  - Every Play, resume, seek or track change starts a new producer, which
    takes a new run number. The reader accepts only the current run's slots
    with the expected slot number, so it never shows levels from an earlier
    position or disc.
  - A block's peaks go into every slot it overlaps. When two blocks share a
    slot, the slot keeps the larger peak. Only the producer writes, so this
    needs no lock.
- **Allocation:** the table is allocated once, before any playback, and is
  checked to be lock-free at creation, like the PCM ring.
- **Ownership:** one table lives for the whole time the app runs and is handed
  to every Core Audio engine; the C playback holds only a pointer.
  - A UI read therefore never races engine teardown.
  - This includes the path that keeps callback storage until exit after a
    failed cleanup.

### Reading (Swift)

- **Access:** the UI reads the table with atomic loads on the main actor. It
  never goes through the audio worker queue, which can be busy during start
  and stop.
- **Position:** the meters read the slots at the position the time display
  shows: the playback position minus the output's reported latency
  (`updateDisplayClock` in
  [PlayerModel.swift](../Packages/CDKit/Sources/CDKit/PlayerModel.swift)).
  - The player updates that position ten times a second. Between updates,
    the meters move it on with the clock, but only while it is advancing, and
    never more than 0.2 s past the last update.
  - On each animation frame, the meter takes the largest peak in the slots
    between the previous read and the new position.
  - Like the clock, this is a reference, not sample-accurate (decision 11).
- **Meter model:** a pure Swift model in CDKit.
  - It converts peaks to dB and applies the rise, fall and hold.
  - It maps the results to lit segments.
  - It takes an injected clock, so it can be tested offline.
- **No extra redraws:** readings are not `@Published`, the same as
  `currentFrame`, so the main display does not redraw at the meters' rate.

### Drawing and animation (app)

- **Rendering:** an AppKit view, `AudioLevelBarsView`, shows both bars as 40
  rounded Core Animation layers, one per segment. A plain 15 Hz
  main-run-loop timer in `AudioLevelMeterDriver` reads the meter at the
  display position. Readings are pulled by the meters, not pushed by the 10 Hz
  playback poll, and only a change of lit or held segment recolours the
  segments that changed. The view itself draws nothing.
  The legends and the dB scale stay in SwiftUI, which does no work per read.
  - It runs only while the meters are fully shown, the window is visible and
    the player is playing. `PlayerWindow` reports them fully shown when the
    latest show's resize ends, or with Reduce Motion when their fade-in ends.
    Hiding them or losing window visibility clears that at once, so they stop
    reading before the window shrinks or while occluded.
  - At any other time the meter is already dark. A change of player state
    reads once and recolours it if needed, and the timer stops, so an idle
    meter uses no CPU.
  - Only the Reduce Motion fade is animated. The segments' colours change at
    once, so hidden meters are dark for the whole shrink or fade-out.
- **One window:** the meters are part of the player panel, in a clipped slot
  below the transport buttons whose ideal height is zero. `PlayerWindow`
  alone sets its height, resizing with its top edge fixed, and the panel
  fills whatever height the window has. As the bottom edge moves down, the
  meters are uncovered in place; as it moves up, they are covered again. The
  SwiftUI content only sets a minimum size. Keyboard focus, menus, dragging
  and VoiceOver keep working as they do today.
- **No second window:** the owner chose this over a drawer on 2026-11-03, so
  there is no child window and no transparent area beside the panel. The
  borderless window's shadow is recomputed on every resize step, so it follows
  the animation.
- **VoiceOver:** the meters are labelled "Audio levels" and are hidden from
  VoiceOver while not shown. Level values are not announced.

## Milestones

Each step passes the offline suites normally, with AddressSanitizer and with
ThreadSanitizer before the next step starts.

### M9.1 — Source peak capture and level table (C, offline; complete)

- **Changes:**
  - Add the level-table API: create and destroy, start a run, record a block,
    and read from any thread.
  - Record each block's peaks in the producer after the block enters the
    playback buffer.
  - Pass the table to the playback at creation.
  - No change to the render callback or the ring buffer's render code.
- **Tests:**
  - Full-scale samples (+32767 and −32768) read as full scale.
  - The demo tone reads −20.0 dBFS.
  - A left-only signal leaves R at 0.
  - Blocks that start or end inside a slot, and two blocks sharing a slot.
  - A new run hides the previous run's slots, even at the same position.
  - A slot overwritten after wrap-around is not returned for its old position.
  - A failed or cancelled read records nothing.
  - The producer writing while a reader reads, under ThreadSanitizer.
  - The existing render, checksum and playback tests pass unchanged.

**Acceptance:** all suites pass, and no existing test changes.

**Result (2026-11-03):** the C level-table API and producer integration are
implemented in `CDAudioCore`. Eight new offline tests cover full-scale and
per-channel peaks, slot boundaries and merges, run and table wraparound,
demo-tone level, failed and cancelled reads, and concurrent publication.
All 407 CDKit tests and 20 AudioCheck tests pass normally and under
AddressSanitizer and ThreadSanitizer. Existing tests are unchanged. No hardware
was accessed.

### M9.2 — Meter model and player state (Swift, offline; complete)

- **Changes:**
  - Add the meter model.
  - Add a level-source protocol, with a fake for tests.
  - Add `showsAudioLevels` and its toggle to `PlayerModel`.
  - Read levels at the time display's position.
- **Tests:**
  - The timing of the rise, fall and hold.
  - The segment thresholds, including full scale.
  - The position follows the time display, including the reported latency.
    Between updates it advances only while playing, by at most 0.2 s.
  - Dark when paused, stopped, ejected or buffering, during the lead-in, and
    after an output is lost.
  - After a seek or track change, only the new position's levels are shown.
  - The disc-fed path under both `.singlePass` and `.retry`.
  - The meters are hidden at launch.

**Acceptance:** all suites pass.

**Result (2026-11-03):** added the shared Core Audio level source, injected
fake level source for offline tests, and a pure Swift meter model with the
documented segment thresholds, 1.5 s peak hold and 20 dB/1.7 s fall. The player
starts with the meters hidden, reads peaks at the latency-adjusted display
position, and caps between-poll advancement at 0.2 s. The meter clears while
paused, buffering, in HDMI/DisplayPort lead-in, after output loss, and across
seek or track changes. The playback snapshot now reports intentional lead-in
silence. Tests cover timing, thresholds, display position, idle states,
seek/track changes, and disc-fed reads under `.singlePass` and `.retry`.

### M9.3 — Meters, menu and shortcut (app; complete)

- **Changes:** the meters view; extending and shrinking the window; the
  Reduce Motion fade; the View menu item and ⌘L.
- **App view tests:**
  - With the meters hidden, the window size is unchanged.
  - Showing the meters adds their height, and hiding them restores the
    original size.
  - The menu item and its shortcut exist, and the item's title changes when
    the meters are shown.
- **Demo-disc check on this Mac** (no disc and no other hardware):
  - Show and hide the meters in the middle of a track.
  - Drag the window by the meters.
  - Show the meters with the window near the bottom of the screen.
  - Try it with Reduce Motion on.
  - Take a screenshot for the README.

**Acceptance:** the app builds, and the view tests pass.

**Result (2026-11-03):** added the LED-style L/R drawer, animated downward
window resizing with the top edge anchored, visible-screen bottom correction,
Reduce Motion fade, and **View › Show/Hide Audio Levels** (⌘L). The drawer uses
the meter model's 20-segment readings, pauses its timeline when dark, and is
labelled "Audio levels" for VoiceOver. Offline UI tests check the window's
closed/open size, top-edge anchoring, and command title/shortcut. The app build
and UI tests passed at this stage; no app playback or hardware was accessed.
Owner-approved visual acceptance and the README screenshot followed in M9.4
using a physical CD.

**Fix (2026-11-03):** the owner's first run found that closing the drawer
clipped the top and bottom of the display and moved the window up. The SwiftUI
content and the window were both resizing the window: the content kept its
open height during its removal transition, so it was centred and clipped in the
shrinking window. The window is now the only size authority, using absolute
open and closed heights. The display is pinned to the top, the drawer slides
from a clipped slot beneath it, and with Reduce Motion the window shrinks only
after the fade. Reviewing the fix also showed that nothing refreshed the meters
after the drawer opened. The drawer now takes a reading on every frame while it
is open and the player is playing. New UI tests check that the display stays at
the top throughout both animations, that toggling mid-animation settles
exactly, the Reduce Motion sequencing, and that the meters light while playing
and darken when paused.

**Revision (2026-11-03):** the owner simplified the design: no drawer. The
meters are now part of the player panel, below the transport buttons, in the
display's style with no box of their own. Showing them moves the window's
bottom edge down by 52 pt in 0.25 s and uncovers them in place. Hiding them
moves it back up, to the original size. The scale labels now sit under the
segments they name, with "dB" in the legend column, and the window's shadow is
recomputed on every resize step. The UI tests also check that the panel fills
the window throughout both animations, with the display's border on the top
row and, once settled, the panel's border on the bottom row. A new test checks
the scale labels against the segment thresholds. The app build, the 13 UI
tests and the CDKit suites passed. The owner's app check followed in M9.4.

**Peak-hold colour (2026-11-03):** at the owner's request, the peak-hold
segment uses the power icon's red, from one colour that both share; the bar
stays mint. A red hold would otherwise have shown inside the bar for a moment
after restarting below a bar still falling from an earlier peak, so the meter
model now reports the hold only at or above the bar's top. A new CDKit test
covers that rule. A new UI test checks that at a new peak the bar's top
segment is red, in the power icon's exact colour, and that it stays in place
as the bar falls until the hold drops after 1.5 s. The 14 UI tests and the
CDKit suites pass.

**Measured only when fully shown (2026-11-03):** at the owner's request, the
meters measure only once the window is fully extended, or with Reduce Motion
once they have faded in. They are dark and read nothing while the window
extends or shrinks, or while they are hidden; recording at the source stays
always on. `PlayerWindow` reports the end of the latest show's animation to
`PlayerModel`, and a show replaced by a later toggle never reports. Hiding
the meters now darkens them at once: the fade's animation had also faded the
cleared segments over 0.25 s, so it now applies to the opacity alone. New
CDKit and UI tests check that nothing is read and no segment is lit while
the window extends, shrinks or fades, and that only the last of several
quick toggles counts. The 17 UI tests and the CDKit suites pass.

### M9.4 — Live check, docs and release 1.2.0

- **Live check, with the owner's approval,** playing a CD to the built-in
  speakers, one USB DAC, and AirPlay or HDMI:
  - The meters move with the music and follow the clock. Small offsets from
    the sound are accepted (decision 11).
  - ⌘L in the middle of a track shows levels as soon as the window is
    fully extended.
  - Compare CPU use with the meters shown and hidden.
- **Live results (2026-11-03),** Debug build, PIONEER BDR-XS07U, Apple
  silicon:
  - **Built-in speakers:** passed. Audible, the meters follow the music, and
    they stay dark while the window extends.
  - **USB DAC (Sony WALKMAN):** passed. Audible, the meters follow the music,
    and the owner judged their alignment with the sound acceptable.
  - **AirPlay (another receiver, via System Default):** passed. Audible,
    the meters follow the music and stay dark while the window extends, and
    the owner judged their alignment with the delayed AirPlay sound
    acceptable. The N-50 AirPlay receiver could not be connected; no HDMI
    output was present.
  - **CPU** (`top`, process total including disc reads and decoding): at
    30 Hz, about 25% hidden and 39–40% shown; after the owner chose 15 Hz,
    about 31–33% hidden and 40% shown. Readings were noisy and the hidden
    baseline varied between runs. The owner found 15 Hz smooth enough.
  - **Window:** the owner passed size/position/shadow, app hide/restore and
    cover/uncover checks. Window › Minimize (⌘M) was disabled; a borderless
    window action fix passed an offline minimize/restore regression and
    the owner's menu, shortcut and Dock-restoration recheck.
- **Docs complete:** README (the feature, the shortcut table and a screenshot),
  [architecture](ARCHITECTURE.md), the
  [development log](DEVELOPMENT_LOG.md), the [changelog](../CHANGELOG.md),
  and this roadmap's status.
- **Release:** version 1.2.0, released the same way as 1.1.0 (see
  [publishing](PUBLISHING.md)).

## Confirmed decisions

Confirmed by the owner on 2026-11-03.

1. **Placement:** a milestone of its own, M9, shipping in 1.2.0. It does not
   wait for M7 (MQA-CD) or M8 (HDCD).
2. **Toggle:** **View › Show Audio Levels**, ⌘L, always available.
3. **In the main window:** the meters sit below the transport buttons. The
   window's bottom edge moves down in about 0.25 s to show them and back up
   to hide them; with Reduce Motion on, they fade. The owner replaced the
   original drawer below the display with this on 2026-11-03.
4. **Not remembered:** the meters are hidden at every launch.
5. **Meter type:** a per-channel sample-peak meter in dBFS, with a 1.5 s peak
   hold. It is not an RMS or VU meter.
6. **Colour:** the display's mint, with faint unlit segments. The peak-hold
   segment uses the power icon's red, which the owner chose on 2026-11-03.
7. **Layout:** horizontal bars, L above R.
8. **Idle:** dark when not playing, with no power-on sweep.
9. **Level of the source:** the meters measure the disc's own samples as they
   are read, before the playback buffer and before macOS volume.
   - The audio callback does not change, and the output stays bit-identical.
   - The volume does not move the meters.
10. **Always recorded:** levels are recorded as the disc is read, throughout
    playback, whether or not the meters are shown, so they have levels as
    soon as they are fully shown.
11. **Timing is a reference:** the meters follow the time display's position,
    which allows for the output's reported latency. Any remaining offset
    from the sound, as on Bluetooth, is accepted.
12. **Measured only when fully shown and visible:** the meters measure only
    once the window has finished extending, or with Reduce Motion once they
    have faded in, and while the window is visible. They read nothing while
    the window extends or shrinks, or when it is hidden, miniaturized, fully
    occluded or off-screen. They resume with a fresh reading when visible.
    The owner chose this on 2026-11-03 and kept recording always on (decision
    10).

## Verification notes

- **View menu:** implemented as View › Show Audio Levels (⌘L), always
  available, including with no disc.
- **Shadow:** the owner confirmed that it follows the animation and fits
  the shown and hidden sizes on 2026-11-03.
- **CPU:** measured on Apple silicon in a Debug build (see M9.4), then in
  Release after 1.3.0 and after 1.3.1 (see the CPU follow-ups below). Intel
  Mac performance was never measured, and Intel Macs are not supported after
  1.3.5.

### CPU follow-up after 1.3.0 (2026-11-03)

Shipped in version 1.3.1.

The owner saw installed Release 1.3.0 rise from about 2% to about 10% CPU
when the meters were shown. Measured with `top` while playing the same CD,
it was 2.2% hidden and 12.5% shown. A `sample` profile showed almost no time
in the meter code. The 15 Hz `TimelineView` made SwiftUI update, lay out and
re-render the whole player view on every frame: AttributeGraph invalidation,
`NSHostingView.layout` and `updateConstraints`.

The bars are now drawn by an AppKit view on a plain 15 Hz timer, and only a
segment change redraws them; SwiftUI does no work per read. The look,
ballistics, 15 Hz rate and dark, hidden and visibility rules are unchanged. A
Release build of the change measured 2.2% hidden and 4.2% shown on the same
disc, so the meters' own cost fell from about 10.3 to about 2.0 points. Most
of what remains is AppKit redrawing the bars' backing store about 15 times a
second.

### CPU follow-up after 1.3.1 (2026-11-04)

Shipped in version 1.3.2.

The owner asked whether the meters could use less CPU still. The 1.3.1
profile put most of their remaining main-thread cost in AppKit redrawing and
rasterising the 40 rounded segments into the bars' backing store. Each
segment is now its own rounded Core Animation layer, and a reading recolours
only the segments that changed, with implicit animations off. The view has
no backing store, so nothing is drawn per read. The look, ballistics, 15 Hz
rate and dark, hidden and visibility rules are unchanged.

Release builds before and after the change, run from the build folder on the
same CD, measured 3.9% before and 2.7% after with the meters shown, and 2.0%
hidden. The meters' own cost fell from about 1.9 to about 0.7 points. Most of
the remainder is the 15 Hz timer reading the meter. See
[the development log](DEVELOPMENT_LOG.md#meter-segments-as-layers-2026-11-04).

### Current 10 Hz refresh (2026-11-13)

The meter timer now runs at 10 Hz instead of 15 Hz, an owner-approved
trade-off to reduce CPU while keeping the bars responsive. The playback
status poll is 5 Hz; the meter still reads its level table directly on its
own timer, only while fully shown and visible.

In a 60-second Release sample on the test Mac, playback used 1.21% CPU with
meters shown, compared with 2.74% in the 1.4.0 baseline. See the
[CPU optimization log](DEVELOPMENT_LOG.md#cpu-optimization-2026-11-13) for
the hidden-meter and wakeup measurements and test details.

## Out of scope

- RMS, VU, loudness (LUFS) or true-peak (inter-sample) metering, and spectrum
  analysers.
- Metering after macOS processing: its conversion, or the system or device
  volume.
- Sample-accurate sync between the meters and the sound on every output.
- Clip counters, clip logging or clip warnings.
- A button on the display to show or hide the meters.
- Remembering whether the meters are shown, and colour options.
- Metering in `AudioCheck` or `OpticalCheck`.
