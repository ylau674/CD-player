# MQA-CD Roadmap (Draft)

**Status:** Scope and recommendations confirmed; implementation not approved.  
**Target:** A future 1.x milestone (working label M7), after the
[audio output selection roadmap](AUDIO_OUTPUT_ROADMAP.md) (M6).  
**Basis:** Web research on 2026-11-01; see [Sources](#sources). No MQA-CD or
MQA decoder has been tested with CD Player yet, and none of the three USB DACs
checked so far decodes MQA over USB.

## Can CD Player decode MQA-CD?

Not inside the app, but it can play MQA-CDs to a DAC that decodes them.

| Approach | Possible? | Why |
|---|---|---|
| Decode in the app, with a licence | Not in practice | Lenbrook licenses MQA to established partners; no public SDK or terms. |
| Decode in the app, without a licence | No | No independent open-source decoder exists; patents and trademarks apply. |
| Send the disc bit-perfect to an MQA decoder DAC | Yes, after M6 | No licence needed. This is how a CD transport feeds an MQA DAC. |
| Play with no decoder | Yes, today | An MQA-CD is a standard Red Book CD and plays as one in 1.0.0. |

So "MQA-CD support" for CD Player means:

- deliver the disc's samples unchanged at 44.1 kHz to an external DAC that
  is a full MQA decoder;
- verify that the DAC decodes them;
- document what interrupts decoding.

The app itself never decodes, detects or labels MQA.

## How MQA-CD works

- **A normal CD.** An MQA-CD is a Red Book 16-bit/44.1 kHz disc. MQA's
  inventor describes it as "100% compatible with any existing CD player"; it
  plays without a decoder. Masters at 44.1, 88.2, 176.4 or 352.8 kHz can be
  folded into it. (Stereophile, 2017.)
- **Hidden data in the low-order bits.** MQA adds a data stream formed by
  XOR-ing one bit of the left and right samples in each frame. A published
  reverse-engineered description puts that bit at positions 8–15 of a 24-bit
  sample, which is the low-order byte of a CD's 16-bit sample. The stream
  carries:
  - the information to rebuild the higher-rate audio;
  - the original sample rate;
  - authentication hashes, which let a decoder check that the audio is
    unaltered.

  (mansr/mqa.)
- **Without a decoder,** those bits play as low-level noise near the bottom
  of the 16-bit range. MQA says this is inaudible; independent measurements
  of undecoded MQA disagree on how much it matters (see
  [Sound quality claims](#sound-quality-claims)).
- **Decoding stages:**
  1. **Core decoding**, the first unfold, doubles the rate: 44.1 kHz becomes
     88.2 kHz. It can run in software or in a DAC. Under MQA's rules,
     software may do only this stage. (Audirvana.)
  2. **Rendering**, the further unfold to the original rate (for example
     176.4 kHz), uses filter settings matched to the DAC. It runs only in
     certified DAC hardware. (Audirvana, Stereophile.)
- **Decoder and renderer DACs differ.**
  - A *decoder* DAC does both stages by itself.
  - A *renderer* DAC does only the last stage and needs software to do the
    first unfold. With undecoded input, it plays the plain CD audio.
  - Because CD Player will not decode, only *decoder* DACs work with it.
    (iFi.)
- **Indicator.** A decoding DAC shows that MQA is playing, usually by a
  colour: blue or "Studio" for audio authenticated as the studio master,
  green for other MQA audio. Many also show the original sample rate.
  (Audirvana, mansr/mqa.)

## What a decoder DAC needs from the player

MQA's inventor says a CD player's digital output decodes on "any MQA decoder
with bit-accurate S/PDIF, optical, or HDMI input", provided the player does
not upsample. In practice the DAC needs:

1. **Exact samples.** Every 16-bit value must arrive unchanged. Volume, EQ,
   resampling, dither, limiting or mixing in other audio all alter the
   low-order bits and break decoding while they last.
2. **44.1 kHz.** The DAC must receive the disc's own rate.
3. **Any container width.** 16-bit values carried in a 24- or 32-bit USB
   format are fine, as long as they are not altered.
4. **A full decoder,** not a renderer (see above).

A drive's read offset only shifts the whole stream, so it does not matter.

## How CD Player measures up

| Requirement | CD Player 1.0.0 | After M6 | Remaining risk |
|---|---|---|---|
| Exact values leave the app | Yes. Tests cover all 65,536 values through the conversion and output callback. | Same | None known. |
| Exact values reach the DAC | Not measured end to end | Not measured | Core Audio converts the app's Float32 to the device's integer format. With one client at unity gain this should be exact, but an MQA indicator is the first direct check (M7.1). |
| 44.1 kHz | Built-in output only | Selected wired output (M6.3b) | None known. |
| No volume or processing | App: none | Same | Devices with hardware volume change it in the device; devices without have no macOS volume (expected; verify). Processing in the DAC itself must be off. |
| Nothing mixed in | Shared output, no exclusive mode | Same (output roadmap decision 5) | Alert sounds and other apps' audio on the same output break decoding while they play. |
| Output to an external DAC | No (built-in only) | Yes (M6.2–M6.3b) | None known. |
| Undamaged audio | Concealment on damaged sectors | Same | Each concealed sector (`ERR n`, 13.3 ms of audio) changes samples, so the DAC will probably drop out of MQA briefly. Not yet observed. |

Two practical consequences:

- **Alert sounds.** macOS plays alert sounds through the default output
  unless "Play sound effects through" in Sound settings names another device.
  With M6, the CD can play to a DAC that is *not* the macOS default, so
  alerts go elsewhere without exclusive mode.
- **An end-to-end bit-perfect check.** An MQA-CD and a decoder DAC give CD
  Player its first way to confirm, outside the app, that the samples reach a
  DAC unchanged. This is useful for M6 whether or not anyone listens to MQA.

## Hardware

### Devices already checked

None of them decodes MQA from a Mac:

| Device | MQA from a Mac over USB | Notes |
|---|---|---|
| Built-in Mac output | No | macOS has no MQA decoder. |
| Sony Walkman NW-A306 | Not documented; reportedly no | Sony lists MQA for the Walkman's own music player. Its USB-DAC help page does not mention MQA, and user reports say USB-DAC input is not decoded. Sony also says the Walkman's sound adjustments apply to USB-DAC input, which would alter the samples. |
| beyerdynamic PRO X | No | PCM only, up to 384 kHz/32-bit. |
| Pioneer N-50 | No | A 2012 design; its USB-DAC input is PCM only. |

The Walkman is worth one check in M7.1, with its sound adjustments turned
off, but it is not expected to decode.

### What to test with

- **A USB DAC that is a full MQA decoder.** For example, iFi lists the ZEN
  DAC V2, ZEN DAC Signature V2, hip-dac2, NEO iDSD, iDSD Diablo and Pro iDSD
  Signature as decoders. Stereophile names Mytek and Meridian DACs as MQA
  decoders with digital inputs. Check the model's specification for "MQA
  decoder", not "MQA renderer". Renderer-only DACs and dongles will not
  decode CD Player's output.
- **Alternatively, a USB-to-S/PDIF interface** feeding a decoder DAC's
  coaxial or optical input. M6 treats it as a USB output.
- **HDMI:** an AV receiver works only if it decodes MQA on that input. None
  has been identified or tested.

### Discs

- The first MQA-CD was Ottava/UNAMAS's *A. Piazzolla by Strings and Oboe*
  (Japan, 2017). (Stereophile.)
- Universal Music Japan's "MQA-CD x UHQCD" (Hi-Res CD) series was still
  issuing titles in 2025, as was Universal Music Hong Kong. Examples are
  listed on CDJapan, Universal Music Store Japan and Discogs.
- Look for "MQA-CD" and "UHQCD" on the obi strip or cover.
- An ordinary CD of the same music makes a useful control.

## Options considered

1. **Bit-perfect passthrough to a decoder DAC: recommended.**
   - No licence, no format code and no trademark use.
   - It reuses M6's output path and needs no new audio processing.
   - What remains is verification and documentation.
2. **Detection only: not recommended.**
   - A read-only scan of the hidden bitstream could show that a disc carries
     MQA data. It would be technically small.
   - However:
     - The only public format description was reverse engineered from
       MQA's decoder binary.
     - "MQA" is a trademark now owned by Lenbrook.
     - The app cannot tell whether the selected DAC decodes MQA, so the
       information is not actionable.
     - The DAC's own indicator already says whether decoding is happening.
3. **Licensed software decoding: not recommended.**
   - Lenbrook acquired MQA's assets in 2023 and runs licensing through MQA
     Labs. It works with established partners such as Roon, Audirvāna and
     BluOS, and publishes no SDK, terms or certification process for small
     developers.
   - Even with a licence, software may only do the first unfold, to
     88.2 kHz for a CD.
   - Software support is shrinking:
     - Tidal removed MQA in July 2024.
     - Audirvāna users report its MQA decoding stopped working in 2026
       (unconfirmed by the vendor).
4. **Unlicensed decoding: rejected.**
   - No independent decoder exists. The open-source `mqadec` and
     `mqarender` tools are wrappers around `libbluos_ssc.so`, a proprietary
     library downloaded from archived Bluesound firmware.
   - Shipping or depending on such code, or re-creating MQA's reconstruction
     without a licence, carries patent, copyright and trademark risk.
   - It would also break the project's rule of no third-party dependencies.

## Sound quality claims

This roadmap makes no sound-quality claim, and neither should the app.

- MQA's inventor says an MQA-CD sounds "slightly better than a typical CD"
  even without a decoder, because the audio is "de-blurred" in the studio.
  Decoded, it is unfolded to the original rate and "rendered to the DAC at
  24-bit". (Stereophile, 2017.)
- Independent analyses dispute MQA's claims. Archimago measured undecoded
  and decoded MQA and ran a public blind test of core-decoded MQA against
  the original high-resolution files. GoldenSound showed that MQA is not
  lossless.
- No independent comparison of an MQA-CD with an ordinary CD of the same
  master was found.

## Proposed milestones

### M7.1 — Verify passthrough with a decoder DAC

- **Prerequisite:** M6.3b (native 44.1 kHz on the selected wired output).
  Alternatively, an earlier feasibility check can use a one-off harness, like
  the silent 44.1 kHz checks on the N-50 and PRO X.
- **Hardware:** a full-decoder DAC, an MQA-CD and an ordinary CD.
- **Checks:**
  - The DAC's MQA indicator lights for the MQA-CD and not for the ordinary
    CD. Record the colour and rate it shows.
  - It stays lit through a whole track and across track changes.
  - Note what happens after pause and resume, a seek and the 10-second
    skips, including any undecoded start.
  - With the DAC as the macOS default, an alert sound interrupts decoding
    (expected). With the DAC selected in CD Player but not the default, it
    does not.
  - Another app playing to the same DAC interrupts decoding (expected).
  - Volume keys, if the DAC is the default and has hardware volume.
  - On a damaged MQA-CD, if one is available, compare drop-outs with the
    `ERR` count and the concealed LBAs in the log.
  - The Walkman in USB-DAC mode with its sound adjustments off: record
    whether it shows MQA (not expected).
- **Record** the results in the development log.
- **No app changes are expected.** If decoding drops out without a cause
  from the list above, investigate the output path before M7.2.

**Acceptance:**

- With no other audio on the output, the indicator stays lit through a
  clean MQA-CD.
- The interruptions match the expected causes.
- The result is recorded as end-to-end bit-perfect evidence for the
  external output path.

### M7.2 — Documentation

- **README:** add a short "MQA-CDs" section:
  - MQA-CDs play as standard CDs on every output.
  - Decoding needs a full MQA decoder DAC selected as the output.
  - Alert sounds, other apps, volume processing and damaged sectors
    interrupt it.
  - CD Player does not decode or detect MQA and is not MQA licensed or
    certified.
  - A trademark notice.
- **Hardware test guide:** add the M7.1 checks.
- **No in-app MQA wording.**

**Acceptance:** the docs match the M7.1 results.

### Possible later work (not planned)

- **Fewer concealed sectors on MQA-CDs:** the hybrid retry policy re-reads
  damaged blocks. On the damaged test disc it changed the concealed count
  little, so it is unlikely to help much.
- **Exclusive output while playing:** this would keep alert sounds and
  other apps out, but it conflicts with the audio output roadmap's sharing
  policy (decision 5). Playing to a non-default output solves most of the
  problem.
- **Detection or licensed decoding:** see
  [Options considered](#options-considered).

## Confirmed decisions

1. **Scope:** passthrough to a full MQA decoder DAC, plus verification and
   documentation. No decoding in the app.
2. **No licence:** do not approach Lenbrook. A software licence would allow
   only the first unfold, and software support for MQA is shrinking.
3. **No MQA wording in the app.** The docs mention MQA only descriptively,
   with a trademark notice.
4. **Keep shared output** (audio output roadmap, decision 5). Recommend
   playing to a DAC that is not the macOS default.
5. **Test hardware:** M7.1 needs a full-decoder DAC and at least one
   MQA-CD. Neither is available yet.

## Out of scope

- Decoding or rendering MQA in the app, with or without a licence.
- Code or binaries derived from MQA decoders, including libraries taken from
  device firmware.
- Detecting MQA, or showing "MQA", its logo, indicator colours or the
  original sample rate in the app; claiming MQA support or certification.
- MQA files, streaming, ripping, or MQA's CD Tag Restorer.
- Upsampling or "MQA-like" filters.

## Sources

All accessed on 2026-11-01. Forum and retailer pages are used only where
noted.

- Stereophile, "MQA-Encoded CDs? Yes!" (2017): Bob Stuart on MQA-CD
  compatibility, folding, decoding and CD transports.
  <https://www.stereophile.com/content/mqa-encoded-cds-yes>
- Måns Rullgård, `mansr/mqa`: the reverse-engineered bitstream description,
  a BSD-licensed scanner, and decoder wrappers around firmware libraries.
  <https://code.videolan.org/mansr/mqa/-/raw/master/mqa.rst>,
  <https://code.videolan.org/mansr/mqa/-/raw/master/mqascan.c>,
  <https://code.videolan.org/mansr/mqa/-/raw/master/get-bluos-ssc>
- Audirvāna, "How MQA decoding works in Audirvāna": software limited to the
  first unfold; decoder and renderer DACs; indicator colours.
  <https://help.audirvana.com/en/support/solutions/articles/202000051095-how-mqa-decoding-works-in-audirv%C4%81na->
- Audirvāna community forum (user reports, 2026): MQA handling no longer
  working. <https://community.audirvana.com/t/no-more-mqa-handling-as-in-version-2x/46944>
- iFi audio, "Can my DAC fully unfold MQA?": decoder and renderer DACs.
  <https://downloads.ifi-audio.com/faqs/can-my-dac-fully-unfold-mqa/>
- Lenbrook, acquisition of MQA's assets (September 2023).
  <https://lenbrook.com/lenbrook-extends-leadership-in-hi-res-audio-with-mqa-acquisition/>
- Lenbrook Media Group, MQA Labs announcement (June 2024).
  <https://lenbrookmediagroup.com/lenbrook-media-group-unveils-plans-for-mqa-labs/>
- SoundStage! Simplifi, "MQA Update, October 2025": playback engine offered
  to partners such as Roon, Audirvāna and BluOS.
  <https://soundstagesimplifi.com/index.php/feature-articles/294-mqa-update-october-2025>
- Tidal, "Audio Format Updates" (updated January 2026): MQA removed on
  24 July 2024. <https://support.tidal.com/hc/en-us/articles/25876825185425-Audio-Format-Updates>
- US patent 10,896,683 B2 (MQA Ltd): lossless band-splitting.
  <https://patents.google.com/patent/US10896683B2/en>
- Sony, NW-A306 USB-DAC help page.
  <https://helpguide.sony.net/dmp/1301/v1/en/contents/TP1000729844.html>
- Head-Fi NW-A300 thread (user reports): no MQA decoding in USB-DAC mode.
  <https://www.head-fi.org/threads/new-sony-walkman-nw-a300-series-android-12.966467/page-205>
- beyerdynamic, PRO X USB-C cable specification.
  <https://global.beyerdynamic.com/p/pro-x-usb-c-cable>
- Archimago, "MQA Core vs. Hi-Res Blind Test, Part I" (2017), which links his
  measurements of undecoded and decoded MQA.
  <https://archimago.blogspot.com/2017/09/mqa-core-vs-hi-res-blind-test-part-i.html>
- GoldenSound, "Tidal HiFi is not lossless" (2021).
  <https://goldensound.audio/2021/11/29/tidal-hifi-is-not-lossless/>
- Retailer and catalogue listings for current MQA-CD x UHQCD titles:
  <https://www.cdjapan.co.jp/product/UICY-40198>,
  <https://store.universal-music.co.jp/collections/hires-maiban>,
  <https://www.discogs.com/release/33639360-%E5%BC%B5%E5%AD%B8%E5%8F%8B-%E6%84%9B%E7%81%AB%E8%8A%B1>
