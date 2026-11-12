# Publishing

This document records how the repository is published, how releases are made,
and what remains before and after making the repository public.

## Current state

- The repository is [ylau674/CD-player](https://github.com/ylau674/CD-player),
  under the owner's personal account. It has been **public** since
  2026-11-04.
- It was created on 2026-11-04 with fresh history: a squashed version 1.3.3
  commit followed by documentation updates, authored as `ylau674` with the
  GitHub no-reply address. `v1.3.3` was the first public release; later
  releases are on the [releases page](https://github.com/ylau674/CD-player/releases).
- The development history and releases 1.0.0–1.3.2 are in the private
  repository `ylau674/CD-player-private`, which stays private. It was named
  `CD-player-archive` at publication and now also holds work under private
  evaluation. Commit hashes cited in the
  [development log](DEVELOPMENT_LOG.md) and the
  [validation logs](validation/) refer to it.
- The project is licensed under Apache-2.0 ([LICENSE](../LICENSE),
  [NOTICE](../NOTICE)). The vendored libhdcd keeps its BSD 2-Clause licence,
  whose notices the app shows in its About panel
  ([Credits.rtf](../App/Credits.rtf)). `Tools/package-release.sh` refuses to
  package an app without them.
- [CONTRIBUTING.md](../CONTRIBUTING.md), [SECURITY.md](../SECURITY.md) and
  issue and pull-request templates are in place.
- Private vulnerability reporting, secret scanning and push protection are
  enabled. The `main` branch requires the offline test check and one
  pull-request approval; force pushes and deletion are blocked. The owner
  account is exempt from enforcement. Projects and Wiki are disabled, and
  repository topics are set.
- Release ZIPs are not committed: `build/` is ignored. They are attached to
  GitHub releases.

## Public repository setup (completed 2026-11-04)

The following checklist records the publication steps and the commands used.
The visibility change is complete; changing it back cannot withdraw copies,
forks or caches made while public.

1. Check once more for personal data. The search below should print only the
   app icon's `@2x` file names and the GitHub no-reply address. The
   validation logs keep the old bundle identifier, which is not personal.

   ```sh
   git grep -nIE '([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}|(^|[^0-9.])(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}|[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|/Users/'
   git log --format='%an <%ae> %ad'
   ```

2. Confirm that you hold the rights to release the app icon under
   Apache-2.0.
3. Change the visibility:

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

   # main: require the offline tests and one approval for pull requests;
   # prevent force pushes and deletion. The owner is exempt from enforcement
   # and can bypass these rules for their own changes.
   gh api -X PUT repos/ylau674/CD-player/branches/main/protection --input - <<'JSON'
   {
     "required_status_checks": {"strict": true, "contexts": ["Offline test suite"]},
     "enforce_admins": false,
     "required_pull_request_reviews": {
       "dismiss_stale_reviews": true,
       "require_code_owner_reviews": false,
       "required_approving_review_count": 1
     },
     "restrictions": null,
     "allow_force_pushes": false,
     "allow_deletions": false
   }
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

After publication, the archive repository was renamed `CD-player-private`;
GitHub redirects the old name.

## Continue on another Mac

```sh
gh auth login                       # as ylau674
gh repo clone ylau674/CD-player
cd CD-player
git config user.name  "ylau674"
git config user.email "36315627+ylau674@users.noreply.github.com"
```

To read the earlier history and private work as well (owner only):

```sh
git remote add --no-tags private https://github.com/ylau674/CD-player-private.git
git fetch private
```

`--no-tags` keeps the private repository's pre-publication tags out of the
clone, so that `git push --tags` cannot send that history here. Before pushing
from a clone with both remotes, install the pre-push guard kept in the private
repository; it refuses to push private branches or history to this one.

Then follow [new-Mac setup](DEVELOPMENT.md#set-up-a-new-mac).
