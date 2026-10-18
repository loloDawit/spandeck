# Developer ID signing and notarization plan (R11, #37)

**Status: plan only.** Nothing here is set up. SpanDeck has no Apple Developer account, certificate, signing secret or notarized build. `build.sh` signs ad hoc and `release.yml` publishes an unsigned DMG. **This document doesn't authorize a release.** A public or enterprise distribution also needs the open items in #3, #11 and the [roadmap](ROADMAP.md) release blockers.

## Where things stand (checked locally, 2026-10-15, macOS 26.5, Xcode 26.6, Swift 6.3.3)

**Historical:** this table was recorded on the pre-#11 `Headroom.app` build. It hasn't been re-recorded on `SpanDeck.app`; that is tracked on #11. The signing and Gatekeeper results are expected to be the same, since the build is still ad hoc, but that is unverified.

| Check | Command | Result today |
|---|---|---|
| Universal binary | `lipo -archs build/Headroom.app/Contents/MacOS/Headroom` | `x86_64 arm64` |
| App signature | `codesign --verify --deep --strict --verbose=2 build/Headroom.app` | valid on disk (**ad hoc**) |
| Signature details | `codesign -dvv build/Headroom.app` | `Signature=adhoc`, `TeamIdentifier=not set`, flags `adhoc` (no hardened runtime) |
| Gatekeeper, app | `spctl --assess --type execute --verbose=4 build/Headroom.app` | **rejected** (exit 3) |
| DMG integrity | `hdiutil verify build/Headroom-1.1.dmg` | checksum VALID |
| DMG signature | `codesign -dv build/Headroom-1.1.dmg` | not signed |
| Gatekeeper, DMG | `spctl --assess --type open --context context:primary-signature --verbose=4 build/Headroom-1.1.dmg` | **rejected**, "no usable signature" |

These were produced by `./build.sh dmg` into the git-ignored `build/` folder. Nothing was installed or launched. **Reproducibility isn't shown yet:** two consecutive builds gave the same binary hash, but the second build reused cached objects. A clean build on a second machine with the same pinned toolchain is still needed (step 9).

## Decisions needed before any signed build (product owner)

1. **Bundle identity.** *Decided and implemented in #11:* `CFBundleIdentifier = io.github.lolodawit.SpanDeck`, `CFBundleName`/`CFBundleExecutable = SpanDeck`, `~/Library/Application Support/SpanDeck/`, all from `Resources/identity.env`. The documented policy is no migration, and Headroom's state is never touched (`docs/USAGE_CACHE.md`, *Separate from Headroom*).
   - A Developer ID signature ties SpanDeck's Team ID to this identifier.
   - The Keychain access context follows the new identity.
   - The commands below now produce `build/SpanDeck.app` and `build/SpanDeck-<version>.dmg`. The inventory table above was recorded on the earlier `Headroom` build.
2. **Who holds the certificate.** Decide whether it is an individual or an organization Apple Developer account, who the Account Holder is, and who may sign.
3. **Where signing happens.** Choose either:
   - (a) the maintainer's Mac, by hand, with a local Keychain;
   - (b) a CI job with secrets. Hosted CI has run the test workflow since 2026-10-15, but signing in CI would still need a budget decision for macOS minutes, and secrets in CI need their own threat-model review.

   This plan describes (a) first, and (b) as a later option.
4. **Hardened Runtime exceptions.** None are expected (below), but each one needs approval.

## Prerequisites (need Apple credentials; not available today)

- Apple Developer Program membership (paid, annual). The Account Holder (or an Admin, if the account allows it) creates a **Developer ID Application** certificate. A **Developer ID Installer** certificate is needed only for `.pkg` files; SpanDeck ships a DMG.
- A private key generated on the signing Mac (Keychain Access ▸ Certificate Assistant, or Xcode ▸ Settings ▸ Accounts). It is non-exportable where possible, and never committed, emailed or pasted into an issue.
- Notarization credentials stored in the Keychain with `notarytool`, never in the repository or in shell history:
  ```sh
  xcrun notarytool store-credentials spandeck-notary --apple-id <id> --team-id <TEAMID>   # prompts for an app-specific password
  ```
  An App Store Connect API key (`--key`, `--key-id`, `--issuer`) is the alternative. Store the `.p8` file only in a secure location and revoke it when it's no longer used.

## Signing and notarization steps (manual, on the maintainer's Mac)

Run from a clean checkout of the **tagged** commit, with the toolchain recorded in the release notes.

1. **Build**, universal: `./build.sh`. It runs `swift build -c release --arch arm64 --arch x86_64` and assembles `build/SpanDeck.app`. Check both slices with `lipo -archs`.
2. **Sign the app** with Hardened Runtime and a secure timestamp, replacing the ad-hoc signature:
   ```sh
   codesign --force --options runtime --timestamp \
     --sign "Developer ID Application: <Name> (<TEAMID>)" build/SpanDeck.app
   ```
   The bundle has one executable and no nested frameworks or helpers, so `--deep` isn't needed. If nested code is ever added, sign it inside-out first.
3. **Entitlements: none planned.**
   - The app isn't sandboxed (it reads `~/.claude`, `~/.grok` and `/usr/bin/security`'s output), so it needs no sandbox entitlements.
   - Hardened Runtime doesn't restrict outgoing HTTPS, IOKit reads, launching `/usr/bin/security` or the Grok CLI as child processes, or `SMAppService`.
   - It doesn't use JIT, unsigned executable memory, `DYLD_*` environment variables, debugging of other processes, Apple Events or the camera or microphone.

   If a runtime test (step 8) shows a need, add a reviewed `SpanDeck.entitlements` and record why.
4. **Verify the app signature:**
   ```sh
   codesign --verify --strict --verbose=2 build/SpanDeck.app
   codesign -dvv build/SpanDeck.app      # Authority=Developer ID Application: …, TeamIdentifier=<TEAMID>, flags=0x10000(runtime), Timestamp=…
   ```
5. **Package and sign the DMG:** `./build.sh dmg` (or rebuild only the DMG from the signed app), then:
   ```sh
   codesign --force --timestamp --sign "Developer ID Application: <Name> (<TEAMID>)" build/SpanDeck-<version>.dmg
   codesign --verify --verbose=2 build/SpanDeck-<version>.dmg
   ```
   `build.sh dmg` currently re-runs the build and the ad-hoc signing. Before the first signed release, change it to take an already-signed app (a separate, reviewed change) so the DMG contains exactly the app verified in step 4.
6. **Notarize the DMG and wait for the verdict:**
   ```sh
   xcrun notarytool submit build/SpanDeck-<version>.dmg --keychain-profile spandeck-notary --wait
   xcrun notarytool log <submission-id> --keychain-profile spandeck-notary notary-log.json   # keep with the release record
   ```
   Only status `Accepted` continues. On `Invalid`, read the log, fix and resubmit. Never ship the rejected file.
7. **Staple and validate the ticket:**
   ```sh
   xcrun stapler staple build/SpanDeck-<version>.dmg
   xcrun stapler validate build/SpanDeck-<version>.dmg
   ```
8. **Gatekeeper assessment and runtime check** on a separate test Mac or user account with no real Claude or Grok data (#3 Phase 2):
   ```sh
   spctl --assess --type open --context context:primary-signature --verbose=4 build/SpanDeck-<version>.dmg   # accepted, source=Notarized Developer ID
   # after copying the app out of the mounted DMG:
   spctl --assess --type execute --verbose=4 /Applications/SpanDeck.app                                     # accepted, source=Notarized Developer ID
   ```
   Launch it once on Apple Silicon and once on Intel hardware, both on macOS 14 or later. Confirm that the R1–R10 defaults hold at runtime: no Keychain read, Grok key read or login item without consent, `--snapshot` refused, and cache modes `0700`/`0600`.
9. **Provenance record**, attached to the GitHub release and kept with the tag:
   - the tag and commit SHA;
   - `swift --version` and `xcodebuild -version`;
   - SHA-256 of the DMG and of the app binary;
   - the `codesign -dvv` output;
   - the notarization submission ID and log;
   - the `stapler validate` and `spctl` results.

   Reproducibility goal: a clean build of the same tag with the same toolchain on a second Mac gives the same **unsigned** binary hash. Signatures and DMG timestamps differ by design.
10. **Publish** only after steps 1–9, by uploading the stapled DMG to the release. Remove the "Not notarized yet … Open Anyway" sentence from `release.yml`'s notes in the same change that starts shipping signed builds.

## If signing later moves to CI (not planned now)

This needs, in its own reviewed change with a threat-model update:
- a protected `release` **environment** with required reviewers;
- secrets only in that environment: a base64 `.p12` with its password, and notarization credentials;
- a temporary Keychain created and deleted within the job (`security create-keychain`, `import`, `set-key-partition-list`, `delete-keychain` in an `always()` step);
- no secrets on `pull_request` runs;
- pinned actions and least permissions, as `scripts/check-workflows.py` enforces;
- a budget decision for hosted macOS minutes.

Until then `release.yml` stays unsigned and must not be given signing secrets.

## Certificates over time

- **Expiry:** Developer ID Application certificates are valid for about 5 years. Thanks to the secure timestamp, apps signed while the certificate was valid keep running after it expires. Renew before expiry; a new certificate (same Team ID) doesn't affect existing installs.
- **Rotation:** creating a new certificate doesn't invalidate earlier ones. Retire old private keys from the signing Keychain once unused.
- **Compromise:** revoke the certificate through Apple Developer Support / the developer account. Revocation can make previously signed builds stop launching for users. Then sign a new build with a new certificate, publish it, and post a security advisory (`SECURITY.md`).
- **Notarization credentials:** rotate app-specific passwords or API keys on maintainer change, and revoke them immediately on suspicion.

## Rollback

- A bad release: mark the GitHub release as a pre-release or delete its assets, publish a fixed version, and note it in the release notes. If the build is malicious or compromised, also revoke the certificate (see above).
- This plan and the R11 workflow changes are reverted with a normal revert PR. No credentials exist to clean up.

## What can be checked today versus later

| Today, locally, without Apple credentials | Needs a Developer ID and notarization credentials |
|---|---|
| `lipo -archs`, ad-hoc `codesign --verify`, `codesign -dvv` flags, `hdiutil verify`, `spctl` (expected to reject) | `codesign --sign "Developer ID Application: …"` with `--options runtime --timestamp` |
| `actionlint`, `scripts/check-workflows.py`, `scripts/test_check_workflows.py`, `swift test` (`WorkflowPolicyTests`) | `notarytool submit` / `log`, `stapler staple` / `validate` |
| Clean-build hash comparison on two Macs (unsigned binary) | `spctl` accepting with `source=Notarized Developer ID` |
| Reviewing `build.sh` and `release.yml` changes | Runtime launch on Apple Silicon and Intel test machines (also needs #3 Phase 2 setup) |
