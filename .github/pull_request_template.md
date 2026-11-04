## Summary

<!-- What changes, and why. Link the issue if there is one. -->

## Checklist

- [ ] `swift test --package-path Packages/CDKit` passes, also with `--sanitize=address` and `--sanitize=thread`
- [ ] Native UI tests pass (`xcodegen generate`, then `xcodebuild … -destination 'platform=macOS' test`), if the app changed
- [ ] Behaviour changes have offline tests using the fakes, under both `.singlePass` and `.retry` where the policy matters
- [ ] README, `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT_LOG.md` and `CHANGELOG.md` updated if behaviour changed
- [ ] No new third-party dependencies or copied code
- [ ] Clean PCM stays bit-exact; disc access stays read-only
- [ ] No serial numbers, device UIDs, addresses or computer names in code, logs or docs

## Hardware tested

<!-- Mac, drive, disc type and output, or "offline tests only". -->
