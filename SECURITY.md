# Security policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please report privately: on the repository's **Security** tab, choose
**Report a vulnerability**. Don't open a public issue. Include the CD Player
and macOS versions, the steps to reproduce and the impact. This is a hobby
project maintained in spare time; expect an acknowledgement within a week.

Relevant reports include anything that lets the app or a crafted disc:

- read beyond the disc, or write to a disc or device;
- run with raised privileges or reach the network;
- leave an audio device's rate, format, volume or mute changed;
- crash or corrupt memory, for example through a malformed table of contents
  or subchannel data.

## Verifying downloads

Release ZIPs are ad-hoc signed and not notarized, so macOS cannot confirm who
built them. Download them only from this repository's
[Releases](https://github.com/ylau674/CD-player/releases) page, and compare
the ZIP's SHA-256 with the digest shown for the asset there and in the
release notes:

```sh
shasum -a 256 CDPlayer-<version>-macOS.zip
```
