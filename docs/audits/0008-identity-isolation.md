# Audit 0008 — SpanDeck identity isolation from Headroom (#11)

**Issue:** #11 (M0), from #5 finding P3. **Contract:** [owner decision on #11](https://github.com/loloDawit/spandeck/issues/11#issuecomment-6232125128). **Base:** `main` at `d529fa8`.
**Why:** before this change SpanDeck used upstream Headroom's macOS identity and storage. On one account, the two apps would replace each other's cache, share preferences and consent, and `./build.sh install` would quit and delete `Headroom.app`. The owner's main account already has a `~/Library/Application Support/Headroom/` of unknown origin. It stays untouched.

Evidence labels follow [audit 0003](0003-security-inventory.md): `[code]`, `[test]`, `[runtime]`, `[assumption]`. Nothing in this audit is `[runtime]` yet. §5 is the owner's run.

## 1. Identity

| | Before (inherited) | After |
|---|---|---|
| App, executable, process name | `Headroom.app`, `Headroom` | `SpanDeck.app`, `SpanDeck` |
| Bundle id, so also the preferences domain and login-item record | `dev.headroom.Headroom` | `io.github.lolodawit.SpanDeck` |
| Application Support (cache, key, price files) | `~/Library/Application Support/Headroom/` | `~/Library/Application Support/SpanDeck/` |
| Hover diagnostic log (hidden `debugHover` only) | `~/Library/Logs/Headroom-hover.log` | `~/Library/Logs/SpanDeck-hover.log` |
| SwiftPM product, debug binary | `Headroom` | `SpanDeck` |
| Swift module and target | `Headroom` | `Headroom` (unchanged, per the decision) |
| DMG | `Headroom-<version>.dmg` | `SpanDeck-<version>.dmg` |

**One source.** `Resources/identity.env` holds the identity:
- `scripts/install-app.sh` and `scripts/runtime-verify.sh` source it. `stage` copies it next to the staged build.
- `build.sh` sources it and refuses to build if `Info.plist` disagrees.
- `Sources/Headroom/Identity.swift` (`AppIdentity`), `Resources/Info.plist` and the `Package.swift` product must agree with it: `IdentityTests.sourcesAgree`.

**Unbundled debug binary.** `swift run SpanDeck` runs outside a bundle, so macOS names its preferences domain after the process (`SpanDeck`) rather than the bundle id. That is never Headroom's domain. The only sanctioned use of the debug binary is `--snapshot`, which writes no preferences. Decision recorded here rather than adding a custom preferences suite.

## 2. What changed
- **[code] `Identity.swift`:** new; `AppIdentity` with the four values and two path helpers.
- **[code] `Util.swift`:** `appSupportDir` comes from `AppIdentity.applicationSupport(in:)`.
- **[code] `Hover.swift`:** the log path comes from `AppIdentity.hoverLogURL(home:)`. Compiling the log out of release builds is P2, a separate change.
- **[code] `PopoverView.swift`:** the login-item error log is prefixed with the app's name.
- **[code] `Info.plist`, `Package.swift`:** the new identity, plus the `SpanDeck` executable product.
- **[code] `build.sh`:** names from `identity.env`, plus the plist check. `install` now calls `scripts/install-app.sh`; the old inline `pkill -x Headroom` and `rm -rf /Applications/Headroom.app` are gone.
- **[code] `scripts/install-app.sh`:** new. It:
  - installs only `SpanDeck.app` whose bundle id is SpanDeck's;
  - refuses to replace an existing target that isn't SpanDeck's, or that is a link;
  - quits only processes named exactly `SpanDeck`;
  - takes `INSTALL_DIR` and `NO_LAUNCH` for tests.
- **[code] `release.yml`:** DMG name and release title.
- **[code] `scripts/runtime-verify.sh`:** SpanDeck's names come from `identity.env`, and Headroom's names appear only as `LEGACY_*` constants, which are observed only. Additions:
  - `stage-legacy SHA` and `legacy-launch`/`quit-legacy`;
  - `fingerprint`/`compare` (names, modes, sizes, dates and SHA-256 of both apps' files, plus preference key names and export hashes; never contents);
  - `seed-legacy-consent`/`unseed-legacy-consent` and `clean-legacy`;
  - a per-run fixture registry: a new run refuses transcripts it didn't write and lists them by name without deleting them; later steps of the same run register theirs.

  The `clean` command now removes SpanDeck's state only.
- **Docs:** `USAGE_CACHE.md` (*Separate from Headroom*), `RELEASE_SIGNING.md` step 1, `README.md`, `CONTRIBUTING.md`, and audit 0007 P3 status.

## 3. Policy: no migration
SpanDeck never opens, reads, imports, renames or deletes Headroom's folder, preferences, log, app or login item. It doesn't check whether they exist either: documentation only, per the decision. On first launch it re-indexes transcripts into its own folder. Usage from deleted transcripts can't be rebuilt. Consent and every other setting start from defaults (off). Old state stays as it was, whoever created it.

## 4. Evidence (local)
- **[test] `IdentityTests`:**
  - `identity.env` holds exactly the approved values;
  - Swift, `Info.plist` and the SwiftPM product agree with it;
  - the storage paths are SpanDeck's;
  - no app source names `dev.headroom`, `Headroom-hover`, `Application Support/Headroom`, `Headroom.app` or `"Headroom"`;
  - `build.sh` and `install-app.sh` read `identity.env` and name no Headroom app, process, id or DMG, and `build.sh` has no `pkill`;
  - the release workflow uses SpanDeck names; `runtime-verify.sh` reads `identity.env`.
- **[test] `CoexistenceTests.headroomStateIsNeverTouched`:** a seeded Headroom folder holds a cache with 999,999 tokens under the same file name, a key, price files and a hover log. Through SpanDeck's index, relaunch, Clear, rebuild and a failed save:
  - every Headroom file keeps its SHA-256, mode and modification date;
  - SpanDeck counts only the transcripts (300), never Headroom's cache;
  - Clear removes only SpanDeck's cache.
- **Written first:** both suites were committed before the change (`81ff12a`) and failed on the inherited identity. The coexistence test showed SpanDeck rewriting Headroom's cache.
- **[test, shell] `scripts/test-install.sh`:** synthetic installs in a temporary folder, with recording stand-ins for `pkill` and `open`. 10 checks pass:
  - installing over an older SpanDeck, with `Headroom.app` byte-identical;
  - only `pkill -x SpanDeck` runs;
  - launch opens only `SpanDeck.app`;
  - four refusals change and quit nothing: a `Headroom.app` source, Headroom's bundle id, a foreign installed `SpanDeck.app`, and an installed `SpanDeck.app` that links to `Headroom.app`.

  Two mutations each fail it: `pkill -x Headroom`, and dropping the installed-app id check.
- **[code] `./build.sh`:** produces `build/SpanDeck.app` with `Identifier=io.github.lolodawit.SpanDeck`, executable `SpanDeck`, universal. A plist with `CFBundleName = Headroom` stops the build ("Info.plist CFBundleName is not SpanDeck").
- **[test] Runtime script dry run** in a scratch home with a `defaults` stand-in, so this account's preferences aren't read:
  - fixtures register per run, and a new run refuses the earlier run's four transcripts by name;
  - `compare` reports "SpanDeck state CHANGED" and "legacy unchanged", and the reverse, correctly.

## 5. Runtime coexistence run (owner, `spandecktest`): pending
**Build account:**
1. `scripts/runtime-verify.sh stage` on this PR's head.
2. `scripts/runtime-verify.sh stage-legacy 226a7d6`: the last build with Headroom's identity, built in a temporary worktree, never installed.

**`spandecktest` still holds Run 3's state.** Run 3 used `c68b108`, built with Headroom's identity, so the account holds:
- `Application Support/Headroom/` with a v7 cache and key;
- `dev.headroom.Headroom` preferences;
- Run 3's transcripts.

Handle it like this, before step 1:
- **Stage first.** Until `stage` moves `current`, `$RV` still resolves to `c68b108`'s script, whose `clean` deletes the Headroom-named state.
- **Keep Run 3's Headroom state as the pre-existing legacy state** for Order A. It's the realistic case, and `226a7d6` loads that v7 cache. Step 2's `0-start` fingerprint records it. If you'd rather start from nothing, run `$RV clean-legacy` instead; it asks first.
- **Remove Run 3's transcripts** with the new script's `$RV clean`. It removes the fixtures and SpanDeck state only, never Headroom's.

**`spandecktest`**, with `RV=/Users/Shared/spandeck-rv/$(cat /Users/Shared/spandeck-rv/current)/runtime-verify.sh`, after checking that `current` names this PR's head:
1. **`$RV preflight`.** It must pass: no SpanDeck app, process, folder or preferences, and no leftover transcripts. If transcripts remain, it lists them by name and deletes nothing: run `$RV clean` and preflight again. Legacy state is recorded, not failed.
2. **Fixtures:** `$RV fixtures 0`, `identity`, `completeness`, `privacy`. Then `$RV fingerprint 0-start`.
3. **Order A, legacy first.**
   - `$RV legacy-launch 90`, quit it from its menu, `$RV quit-legacy`, then `$RV fingerprint 1-legacy`.
   - `$RV launch 120 main`: open the popover and screenshot it. Then `$RV quit` (quit from the menu) and `$RV fingerprint 2-spandeck`.
   - `$RV compare 1-legacy 2-spandeck` → **legacy unchanged**.
   - `$RV capture 2-after`: the SpanDeck cache is version 7 in `Application Support/SpanDeck`, with no canary.
4. **Clear.** `$RV launch 60 clear`, then Settings ▸ Clear cached usage data ▸ confirm. Quit, then `$RV fingerprint 3-cleared`. `$RV compare 2-spandeck 3-cleared` → **legacy unchanged**, SpanDeck changed (new key).
5. **Order B, legacy after SpanDeck (the downgrade case).** `$RV legacy-launch 60 after`, quit, `$RV fingerprint 4-legacy-again`. `$RV compare 3-cleared 4-legacy-again` → **SpanDeck unchanged**.
6. **Both at once.**
   - `$RV legacy-launch 60 both`, and while it runs, from a second terminal, `$RV launch 60 both`.
   - Both processes show in their own `forks.txt` and `process.txt`, under distinct names, each with its own menu-bar item.
   - Quit both.
7. **Consent not inherited.**
   - `$RV seed-legacy-consent`, then `$RV launch 90 seeded`.
   - `consent.txt` shows SpanDeck's domain absent or off while the legacy domain says 1. `forks.txt`: 0 children (no `security`, no `grok`). The popover shows "Plan limits are off".
   - Quit, then `$RV unseed-legacy-consent` **before** any further legacy launch.
8. **Relaunch.** `$RV launch 60 relaunch`, quit, `$RV fingerprint 5-end`. `$RV compare 4-legacy-again 5-end` → legacy unchanged.
9. **Login items:** System Settings ▸ Login Items lists neither app unless you enabled it. Optional: enable *Launch at login* in SpanDeck, confirm it's listed as SpanDeck and Headroom's entry, if any, is unaffected, then turn it off.
10. **`$RV summary`.**

**Stop conditions:**
- any **legacy unchanged** check that says CHANGED after a SpanDeck step;
- SpanDeck consent on, or a `security`/`grok` fork, in step 7;
- a canary in any SpanDeck file;
- a Keychain or permission prompt.

## 6. Limits and what this doesn't do
- **Existing Headroom state** on any account isn't inspected, migrated or cleaned up. Whose it is stays unknown, and that's deliberate.
- **The unbundled debug binary's preferences domain** is the process name (§1).
- **Out of scope** (separate approved work):
  - P2: compiling the hover log out of release builds;
  - P1: model-id validation;
  - P4: backup exclusion;
  - the Swift module rename;
  - UI changes.
- **The personal-account trial remains NO-GO** until this PR passes review and the §5 run, followed by a deliberate trial decision.
