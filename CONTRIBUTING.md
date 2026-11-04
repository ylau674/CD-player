# Contributing to CD Player

Thank you for your interest. CD Player is a small project with one
maintainer, tested on one Mac and one drive. Issues and pull requests are
welcome; please read this page first.

## Before you start

- For anything beyond a small fix, open an issue first to agree the approach.
- [docs/DEVELOPMENT_LOG.md](docs/DEVELOPMENT_LOG.md) is the detailed
  behaviour specification. Check it before changing behaviour.
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers setup, building, testing
  and the hardware check tools; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
  explains the design.

## Project rules

- Disc access stays read-only on `/dev/rdiskN`, as the logged-in user, and
  only after Play. No mounting, SCSI pass-through, privilege elevation, forced
  eject or workaround when macOS refuses access.
- Keep clean PCM bit-exact: no resampling, EQ, dither or gain. Don't add new
  changes to system volume or mute.
- The Core Audio render callback (C) must not allocate, lock, log, do I/O or
  call Swift.
- Swift 6 strict concurrency: no blocking calls on the main actor or the
  cooperative pool.
- No third-party dependencies. The vendored libhdcd decoder is the only
  exception.
- Every behaviour change needs offline tests using the fakes in
  `Packages/CDKit/Tests/CDKitTests`. Policy-dependent tests run under both
  `.singlePass` and `.retry`.
- Update the README, `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT_LOG.md` and
  `CHANGELOG.md` when behaviour changes.

## Checks before a pull request

```sh
swift test --package-path Packages/CDKit
swift test --package-path Packages/CDKit --sanitize=address
swift test --package-path Packages/CDKit --sanitize=thread
xcodegen generate
xcodebuild -project CDPlayer.xcodeproj -scheme CDPlayer -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' test
```

CI runs the offline package suite only; it has no optical drive or audio
output. The native UI tests need a graphical login session. In the pull
request, say which Mac, drive, disc and output you tested on, if any.

## Privacy

Core Audio output UIDs, Bluetooth addresses, Bonjour and computer names, and
LAN addresses can identify you or your devices. Replace them with
`<redacted>` in issues, logs and documentation.

## Licence

By contributing, you agree that your contribution is licensed under the
[Apache License, Version 2.0](LICENSE), as its section 5 describes. Don't
submit code copied from GPL-licensed projects or from the Philips/ISO DST
reference code, and don't add any other third-party code without discussing
it first.
