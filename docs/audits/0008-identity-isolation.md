# Audit 0008 — SpanDeck identity isolation from Headroom (#11)

**Issue:** #11 (M0), from #5 finding P3. **Contract:** [owner decision on #11](https://github.com/loloDawit/spandeck/issues/11#issuecomment-6232125128). **Base:** `main` at `d529fa8`.
**Why:** before this change SpanDeck used upstream Headroom's macOS identity and storage. On one account, the two apps would replace each other's cache, share preferences and consent, and `./build.sh install` would quit and delete `Headroom.app`. The owner's main account already has a `~/Library/Application Support/Headroom/` of unknown origin. It stays untouched.

Evidence labels follow [audit 0003](0003-security-inventory.md): `[code]`, `[test]`, `[runtime]`, `[assumption]`. §5's results are `[runtime]`. The owner ran it on 2026-10-17 in `spandecktest`, as run `20261017T165341Z` at `b57dea6`. The independent reviewer checked an owner-supplied report and screenshots and posted findings on [#11](https://github.com/loloDawit/spandeck/issues/11#issuecomment-6237971909) and [#5](https://github.com/loloDawit/spandeck/issues/5#issuecomment-6237973276). Neither the reviewer nor this audit's author ran it.

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

  **Cleanup fails closed** (review of `e39f9c5`):
  - `clean` removes SpanDeck's state and only the fixture files the script registered, each checked as a plain file under an expected path.
  - It refuses an old marker without a registry, showing a read-only inventory, and refuses a linked projects folder.
  - It never removes `~/.claude/projects` wholesale.
  - `clean-fixtures-legacy` handles Run 3's unregistered fixtures (§5).
- **[code] `scripts/check-identity.sh`** (review of `e39f9c5`): Info.plist and **every `AppIdentity` constant** must match `identity.env`. Each constant must be declared exactly once as an exact line, and `AppIdentity` must not be declared or extended in another file. `build.sh` runs it before compiling or packaging, so `./build.sh dmg` in `release.yml` is guarded too.
- **[code] `install-app.sh` overlap check** (review of `e39f9c5`): source and target are compared as resolved paths. It refuses the installed app as its own source (also through a link), a source inside it, and a target inside the source, before anything is quit or removed.
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

  Since the review of `e39f9c5`, it has 14 checks. The four overlap cases failed before the fix (each quit SpanDeck and deleted the installed app) and pass now.
- **[test, shell] `scripts/test-identity-check.sh`:** 7 checks:
  - the checkout passes;
  - a changed `supportFolder` alone, a changed `bundleID` alone, a second declaration, a missing declaration and a drifted plist are each refused;
  - `./build.sh dmg` with a drifted `supportFolder` stops before `swift build` runs, with no `build/` created.
- **[test, shell] `scripts/test-runtime-clean.sh`:** 16 checks, in a scratch home with stand-ins for `defaults` and `dsmemberutil`:
  - `clean` keeps an unregistered transcript, a sentinel and the evidence, and removes only the registered fixtures;
  - an old marker is refused with an inventory, and nothing is deleted;
  - `clean-fixtures-legacy` deletes nothing when declined, and exactly the Run 3 fixtures when confirmed;
  - it refuses an unexpected file, another project folder, an untokened name, a link and a registered marker;
  - a linked projects folder is refused by both commands.

  7 checks failed before the fix; the old `clean` deleted everything.
- **[test] `IdentityTests.checksComeBeforeDestructiveSteps`:** the identity check precedes `swift build` in `build.sh`, and the overlap check precedes `pkill` and `rm -rf` in `install-app.sh`.
- **[code] `./build.sh`:** produces `build/SpanDeck.app` with `Identifier=io.github.lolodawit.SpanDeck`, executable `SpanDeck`, universal. A plist with `CFBundleName = Headroom` stops the build ("Info.plist CFBundleName is not SpanDeck").
- **[test] Runtime script dry run** in a scratch home with a `defaults` stand-in, so this account's preferences aren't read:
  - fixtures register per run, and a new run refuses the earlier run's four transcripts by name;
  - `compare` reports "SpanDeck state CHANGED" and "legacy unchanged", and the reverse, correctly.

## 5. Runtime coexistence run (owner, `spandecktest`): completed 2026-10-17
Results and limits are in §5.1. The procedure as run follows.
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
- **Remove Run 3's transcripts with `$RV clean-fixtures-legacy`**, not `$RV clean`. Run 3's marker has no file registry, so `clean` refuses it and only lists what's there.
  - `clean-fixtures-legacy` runs only in this Standard account.
  - It deletes only if every entry under `~/.claude/projects` is positively a Run 3 fixture: the old marker, `-Users-spandecktest-rvpath<token>` folders, and plain `rvid<token>-{main,identity,completeness,privacy,perfN}.jsonl` files containing their token.
  - It lists them and asks first. Anything else (another file, another project, a link) stops it with nothing deleted.
  - It never removes `~/.claude/projects` wholesale, and keeps the evidence.

**`spandecktest`**, with `RV=/Users/Shared/spandeck-rv/$(cat /Users/Shared/spandeck-rv/current)/runtime-verify.sh`, after checking that `current` names this PR's head:
1. **`$RV preflight`.** It must pass: no SpanDeck app, process, folder or preferences, and no leftover transcripts. If transcripts remain, it lists them by name and deletes nothing. Run `clean-fixtures-legacy` (above) for Run 3's, or `$RV clean` for a registered run's, then preflight again. Legacy state is recorded, not failed.
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

### 5.1 Results: run `20261017T165341Z`, build `b57dea6`
**Result: pass for the scoped coexistence checks, within the limits below.** No stop condition was hit. These bullets come from the run's sanitized results file (1,178 lines), kept in the owner's shared results folder and not committed. Items that come only from the owner-supplied report or screenshots the reviewer saw are marked that way.

- **[runtime] Preflight passed.**
  - Standard account; no Claude Code Keychain item (attribute lookup only); no Claude or Grok credential files.
  - No earlier run's transcripts; no SpanDeck app, process, folder or preferences.
  - The staged app is `io.github.lolodawit.SpanDeck` and matches its manifest hash.
  - Legacy state was recorded, not failed: `Application Support/Headroom` and `dev.headroom.Headroom` preferences present, no `/Applications/Headroom.app`.
- **[runtime] Clean accounting:** 4 synthetic transcripts. The expected totals add up to 600 + 180 + 72 + 15 = 867 `claude-sonnet-4-5` tokens, plus 10 unpriced, for 877 in total. Run 3's leftover-fixture discrepancy doesn't recur. The 877 shown in the UI comes from the owner's screenshots, which aren't in the shared folder.
- **[runtime] Fingerprint comparisons, the four that were recorded:**

  | Compare | Step | SpanDeck | Legacy |
  |---|---|---|---|
  | `1-legacy → 2-spandeck` | 3, Order A | CHANGED (expected) | **unchanged** |
  | `2-spandeck → 3-cleared` | 4, Clear | CHANGED (expected) | **unchanged** |
  | `3-cleared → 4-legacy-again` | 5, Order B | **unchanged** | unchanged |
  | `4-post-consent → 5-end` | 8, relaunch | **unchanged** | **unchanged** |

- **[runtime] Keys:** in `2-after/state.txt`, SpanDeck's key begins `f7f6f01a…` and Headroom's begins `82ea0af6…`. Headroom's is unchanged through Clear, per the compare above. After Clear, SpanDeck's state CHANGED. The new key's hash, `330aada3…`, comes from the owner-supplied report on #11 and isn't in the shared file.
- **[runtime] Both at once:** Headroom (pid 56569) ran from 17:34:42 and SpanDeck (pid 57524) from 17:35:11. SpanDeck quit at 17:36:40 and Headroom at 17:36:55, so the two ran together. Separate menu-bar items come from the owner's screenshot.
- **[runtime] Consent not inherited:**
  - `seed-legacy-consent` set `dev.headroom.Headroom` `claude.limits.enabled=1 grok.enabled=1`.
  - Over the 90-second seeded launch, SpanDeck's domain read `claude.limits.enabled=absent grok.enabled=absent`.
  - The legacy keys were then removed with `unseed-legacy-consent`. SpanDeck's keys were absent in every launch.
- **[runtime] No observed side effects:** in all eight launch windows (60–120 s each, both apps), there were 0 kernel-reported child forks, 0 socket lines, 0 app-log network, security or login-item events, and 0 `security`/`grok` process log lines.
- **[runtime] Cache, at `2-after`** (after the first index, before Clear):
  - `Application Support/SpanDeck` is `0700`; `claude-ledger.json` and `claude-ledger.key` are `0600`.
  - Version 7, with 4 files, 31 `seen` and 53 `links`, all 32-hex ids. 4 of 4 marks have a stamp and anchor.
  - `unread`: `malformed=2 undated=1 invalidUsage=1`; 1 flawed group; cache-write tokens `tier-unresolved=10 disputed=20`. There's no `/` in the cache.
  - No content, path, id, secret, code, tool, thinking or branch canary in the cache or in any file outside the fixtures. The model canary is present by design (the model field).
- **[runtime] Final relaunch:** `4-post-consent → 5-end` was unchanged for both apps. The quit step logged `quit SpanDeck: not running`: the app had already exited.

**Evidence limits:**
- **No comparison covers steps 6 and 7.** Step 8 asks for `compare 4-legacy-again 5-end`, but the run compared `4-post-consent → 5-end`. `4-post-consent` was taken after the seeded launch and the unseed. So neither app's state is compared across the both-at-once and seeded-consent window; only the consent keys and side effects are recorded for it.
- **Keychain:** the changed-files list includes `~/Library/Keychains/login.keychain-db` and a `keychain-2.db-wal`. They're not attributed to SpanDeck, and they're not shown to be unrelated either. Other macOS services and Chrome also wrote files during the run. The only Keychain check is preflight's attribute lookup, before any launch. This doesn't show the Keychain was untouched; it shows no observed app-attributed child process, socket or filtered log event, and no prompt reported.
- **Bounded negatives:** fork, socket and log results cover only each watch window and its filters, not everything macOS does.
- **Not examined:** crash reports, Spotlight, Time Machine and APFS snapshots, and every provider's credential stores.
- **Single capture point:** the canary, version and mode checks are from `2-after` only, the one capture the procedure asks for.
- **Process names:** step 6's `process.txt` check isn't in the shared file. Concurrency rests on the pids and times above and the owner's screenshot.
- **Login Items:** preflight records the owner's observation that neither app is listed. Step 9's optional enable and disable wasn't done.
- **Report size:** the reviewer's comment cites a 1,334-line report. This section was checked against the 1,178-line shared file.
- **Separate UI follow-ups noted in the run:** the screen-width Clear confirmation, the Battery heading wrap and the long cost explanation.

## 6. Limits and what this doesn't do
- **Existing Headroom state** on any account isn't inspected, migrated or cleaned up. Whose it is stays unknown, and that's deliberate.
- **The unbundled debug binary's preferences domain** is the process name (§1).
- **Out of scope** (separate approved work):
  - P2: compiling the hover log out of release builds;
  - P1: model-id validation;
  - P4: backup exclusion;
  - the Swift module rename;
  - UI changes.
- **The personal-account trial remains NO-GO.** Code review and §5 are done, but they don't lift it. It waits on an explicit owner GO and the remaining #5 decisions: P1, P2, P4 and the residual risks.
