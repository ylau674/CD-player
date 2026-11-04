# CD Player: project guidelines

A minimal native macOS audio CD player. SwiftUI/AppKit app in `App/`, all logic in
the Swift package `Packages/CDKit`, with a C shim `CDAudioCore` for CD `ioctl`s and
the real-time Core Audio path. See [README](../README.md),
[architecture](../docs/ARCHITECTURE.md) and [development guide](../docs/DEVELOPMENT.md).
[docs/DEVELOPMENT_LOG.md](../docs/DEVELOPMENT_LOG.md) is the detailed behaviour
specification; check it before changing behaviour.

## Build and test

- Tests (offline, no hardware): `swift test --package-path Packages/CDKit`. Before
  finishing a code change, also run with `--sanitize=address` and `--sanitize=thread`.
- App: `xcodegen generate`, then `xcodebuild -project CDPlayer.xcodeproj -scheme CDPlayer
  -configuration Debug -derivedDataPath build build`. The `.xcodeproj` is generated
  from `project.yml` and must not be committed.
- Release: `./Tools/package-release.sh`.

## Hard rules

- Ask the owner before any live hardware step: running `AudioCheck`/`OpticalCheck`
  against a disc or output, ejecting, launching the app to play, or installing into
  `/Applications`. The owner performs physical actions. Never run a check tool while
  the app is playing the same disc.
- Disc access stays read-only on `/dev/rdiskN` as the logged-in user, only after Play.
  Never add mounting, SCSI pass-through, privilege elevation, forced eject or any
  workaround for a policy refusal.
- Never change system volume or mute. Keep clean PCM bit-exact: no resampling, EQ,
  dither or gain.
- The HAL render callback (C) must not allocate, lock, log, do I/O or call Swift.
- Swift 6 strict concurrency: no blocking calls on the main actor or cooperative
  pool; drive I/O on the `DiscSession` executor, Core Audio setup/teardown on the
  audio worker queue.
- No third-party dependencies.

## Conventions

- Every behaviour change gets offline tests using the fakes in `Tests/CDKitTests`.
  Create players with `PlayerModel.offline(…)`, never `PlayerModel(…)`, whose
  defaults are real Mac services. Policy-dependent tests run under both
  `.singlePass` and `.retry`.
- Comment only where code needs clarification; explain why, not what.
- Log with `Logger(subsystem: "io.github.ylau674.CDPlayer", category: ...)`;
  the UI shows only short errors.
- Update the README, `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT_LOG.md` and
  `CHANGELOG.md` when behaviour changes.
