# Publishing

This document records how the repository is published, how releases are made,
and what remains before and after making the repository public.

## Current state

- The repository is [ylau674/CD-player](https://github.com/ylau674/CD-player),
  under the owner's personal account. It is **private** until the owner
  changes its visibility.
- It was created on 2026-11-04 with fresh history: one squashed commit holding
  version 1.3.3, authored as `ylau674` with the GitHub no-reply address.
  `v1.3.3` is the latest release.
- The development history and releases 1.0.0–1.3.2 are in the private
  repository `ylau674/CD-player-archive`, which stays private. Commit hashes
  cited in the [development log](DEVELOPMENT_LOG.md) and the
  [validation logs](validation/) refer to it.
- The project is licensed under Apache-2.0 ([LICENSE](../LICENSE),
  [NOTICE](../NOTICE)). The vendored libhdcd keeps its BSD 2-Clause licence,
  whose notices the app shows in its About panel
  ([Credits.rtf](../App/Credits.rtf)). `Tools/package-release.sh` refuses to
  package an app without them.
- [CONTRIBUTING.md](../CONTRIBUTING.md), [SECURITY.md](../SECURITY.md) and
  issue and pull-request templates are in place.
- Release ZIPs are not committed: `build/` is ignored. They are attached to
  GitHub releases.

## Make the repository public

1. Check once more for personal data. The search below should print only the
   app icon's `@2x` file names and the GitHub no-reply address. The
   validation logs keep the old bundle identifier, which is not personal.

   ```sh
   git grep -nIE '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}|(^|[^0-9.])(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}|[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|/Users/'
   git log --format='%an <%ae> %ad'
   ```

2. Confirm that you hold the rights to release the app icon under
   Apache-2.0.
3. Change the visibility. It can be changed back, but clones, forks and
   caches made while public cannot be withdrawn.

   ```sh
   gh repo edit ylau674/CD-player --visibility public --accept-visibility-change-consequences
   ```

4. Turn on the protections that matter once others can see and contribute:

   ```sh
   # Private vulnerability reporting, which SECURITY.md relies on
   gh api -X PUT repos/ylau674/CD-player/private-vulnerability-reporting

   # Secret scanning with push protection
   gh api -X PATCH repos/ylau674/CD-player --input - <<'JSON'
   {"security_and_analysis": {
     "secret_scanning": {"status": "enabled"},
     "secret_scanning_push_protection": {"status": "enabled"}}}
   JSON

   # main: no force pushes or deletion, and the offline tests must pass
   # before a pull request merges. Admins (the owner) can still push.
   gh api -X PUT repos/ylau674/CD-player/branches/main/protection --input - <<'JSON'
   {"required_status_checks": {"strict": true, "contexts": ["Offline test suite"]},
    "enforce_admins": false,
    "required_pull_request_reviews": null,
    "restrictions": null,
    "allow_force_pushes": false,
    "allow_deletions": false}
   JSON

   # Unused features, and topics for discovery
   gh repo edit ylau674/CD-player --enable-projects=false --enable-wiki=false \
     --add-topic macos,swift,swiftui,audio-cd,cd-player,bit-perfect,hdcd
   ```

5. Optional: pin `actions/checkout` in
   [ci.yml](../.github/workflows/ci.yml) to a full commit SHA, and add a code
   of conduct if contributors arrive.

macOS runners use ten times the minutes on private repositories; public
repositories run them free. The workflow runs only on pushes to `main`, pull
requests and manual dispatch.

## Release a version

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in
   [Info.plist](../App/Info.plist), `VERSION` in
   [package-release.sh](../Tools/package-release.sh), the
   [changelog](../CHANGELOG.md) and the README status line and ZIP link.
2. Run the three CDKit test suites and the native UI tests, then package. Note
   the printed SHA-256.

   ```sh
   ./Tools/package-release.sh
   ```

3. Commit, tag, push and create a draft release, for example for 1.3.3:

   ```sh
   git tag -a v1.3.3 -m "CD Player 1.3.3"
   git push --atomic origin main v1.3.3
   gh release create v1.3.3 build/packages/CDPlayer-1.3.3-macOS.zip \
     --verify-tag --draft --title "CD Player 1.3.3" --notes-file <notes>
   ```

   The notes should give the ZIP's SHA-256 and say that the app is ad-hoc
   signed and not notarized: on another Mac, use **Open Anyway** in
   System Settings › Privacy & Security.

4. When the pushed commit's Tests workflow passes and the uploaded asset's
   digest matches the local SHA-256, publish the draft:

   ```sh
   gh release view v1.3.3 --json assets --jq '.assets[].digest'
   gh release edit v1.3.3 --draft=false --latest
   ```

## Notarization

Downloads from GitHub are quarantined, and Gatekeeper blocks ad-hoc signed
apps until the user chooses Open Anyway. Removing that step needs an Apple
Developer Program membership (US$99 a year), Developer ID signing and
notarization with `notarytool`. Until then, the README documents Open Anyway,
and [SECURITY.md](../SECURITY.md) asks users to compare the ZIP's SHA-256.

## Licence

Apache-2.0 was chosen for its explicit patent grant, which suits audio-format
work, and its compatibility with the code the roadmaps allow:

- libhdcd (BSD-2-Clause) is vendored with its `LICENSE` and `AUTHORS`.
  Binary distributions must carry its notices, which the About panel does.
- The [SACD roadmap](SACD_ROADMAP.md) allows FFmpeg's `dstdec.c`
  (LGPL-2.1-or-later) only as an owner-approved fallback.
- GPL code, and code under restrictive reference-implementation notices, are
  not used.

When adding third-party code, keep its licence file beside it, add it to
[NOTICE](../NOTICE) and [Credits.rtf](../App/Credits.rtf), and extend
`Tests/AppTests/CreditsTests.swift`.

## How the public repository was created

The private repository, with its history and releases, was renamed and kept.
A new private repository was then created under the original name, holding a
single commit of the final tree:

```sh
gh repo rename CD-player-archive -R ylau674/CD-player --yes
gh repo create ylau674/CD-player --private \
  --description "Minimal native macOS audio CD player: bit-perfect 44.1 kHz output, slowest drive speed, C2-aware concealment"
git checkout --orphan public main
git commit -m "CD Player 1.3.3"
```

## Continue on another Mac

```sh
gh auth login                       # as ylau674
gh repo clone ylau674/CD-player
cd CD-player
git config user.name  "ylau674"
git config user.email "36315627+ylau674@users.noreply.github.com"
```

To read the earlier history as well:

```sh
git remote add archive https://github.com/ylau674/CD-player-archive.git
git fetch archive
```

Then follow [new-Mac setup](DEVELOPMENT.md#set-up-a-new-mac).
