# Audit 0003 — Runtime verification on macOS (§7 Phase 2)

Issue: [#3](https://github.com/loloDawit/spandeck/issues/3) · Parent: [#2](https://github.com/loloDawit/spandeck/issues/2) · Related: #5, #8, #11, #46 · Code inventory: [0003-security-inventory.md](0003-security-inventory.md)

> **Status (2026-10-15): procedure ready; runtime verification not yet run.** This page contains no [runtime] result. The session that prepared it ran in the owner's normal administrator account, where the safety gate forbids launching the app (§2). The checks below must be run by the owner in the dedicated test account, then recorded in §8.

## Evidence labels

| Label | Meaning |
|---|---|
| **[runtime]** | Observed on a real SpanDeck process on macOS, with the method stated |
| **[CI]** | Shown by GitHub Actions (the [mocked] suite on a hosted runner) |
| **[mocked]** | Shown by tests with fake Keychain, network, process, login-item and preference dependencies |
| **[code]** | Read from source |
| **[not verified]** | Not tested, or the evidence isn't enough |

A green CI run, a passing mocked test or a code reading is never relabeled as [runtime].

## 1. What the app should do today

These expectations were read from `main` at `83a9af8`. A run tests whatever commit `stage` records in its manifest; if that's newer, re-check this section against the diff first.

§7 Phase 2 of the inventory was written for the inherited Headroom code. Several of its expectations no longer apply. For example, it expected a request to `raw.githubusercontent.com` at launch, but R6 removed that request. The expected behavior below comes from the current source, not the inherited behavior.

**Default launch, without any consent** [code: `main.swift`, `ProviderServices.swift`, `Dependencies.swift`, `Ledger.swift`; mocked: `LaunchPathTests`, `GrokConsentTests`, `LedgerCacheTests`; CI: run 38844113831]:
- `Prefs.register()` registers defaults in memory only. Consent keys `claude.limits.enabled` and `grok.enabled` default to off, and `awake.agents` defaults to off.
- `AppEnvironment.live` resolves `~/Library/Application Support/Headroom` and prepares it as `0700` (R8). `ProviderServices.start()` loads the **built-in** price snapshot: no request (R6), no login-item call (R1).
- **Every 1 s:** samples CPU, GPU, memory and battery in-process (mach `host_*`, `sysctlbyname`, IOKit `IOAccelerator` / `AppleSmartBattery`). No subprocess.
- **Every 60 s:** `refreshLimits` calls `refreshClaude` and `refreshGrok`. With consent off, both return before reading a credential, starting a process or sending a request.
- **Every 10 s:** usage refresh reads `~/.claude/projects`, `~/.config/claude/projects` and `~/.grok/sessions` (files modified in the last 32 days). The cache is written `0600` after the first refresh that finds data, then at most every 10 minutes, and on quit. A full rescan runs every 5 minutes.
- Nothing is logged except one `NSLog` on a login-item error.
- **Not started:** `/usr/bin/security`, `~/.grok/auth.json` reads, `~/.grok/bin/grok`, provider requests, the pricing download, `SMAppService.register`, power assertions.

**Only after the user acts:**
- Claude consent: Keychain read through `/usr/bin/security`, then `api.anthropic.com`.
- Grok consent: `~/.grok/auth.json`, `cli-chat-proxy.grok.com`, `grok models` at most every 10 minutes.
- "Update prices": one pinned download from `raw.githubusercontent.com`, offered only if the built-in snapshot fails verification.
- Launch at login: Settings toggle.
- Keep awake: power assertion.

**`--snapshot`** (R10) is decided before the app delegate exists:
- **Release build:** exits 64 and writes nothing.
- **Debug build:** renders a synthetic store to 3 PNGs in an existing folder, then exits 0.

## 2. Safety gate and test environment

**This session's environment, checked 2026-10-16 about 04:05 UTC:**
- **Account:** `dawitnoah`, an administrator. Its home is `/Users/dawitnoah`, and it already has `~/Library/Application Support/Headroom`. It is the owner's normal developer account, so **the app was not launched and `--snapshot` was not run here.**
- **Machine:** Apple M2 Pro, 12 cores, 16 GB, macOS 26.5 (25F71), arm64. Not MDM-enrolled (`profiles status`).
- **Test account:** `spandecktest` exists ("SpanDeck Test", uid 502, Standard user: not in `admin`, home `/Users/spandecktest`, mode `750`). Its contents weren't inspected.

**Test account requirements** (the script's `preflight` checks the automatable ones and stops on any failure):

| Requirement | How it's checked |
|---|---|
| Running as `spandecktest`, a Standard (non-admin) user | `id -un`, `dsmemberutil checkmembership … -G admin` |
| `$HOME` is the account's real home (Foundation resolves the account's home, not `$HOME`) | `dscl . -read /Users/spandecktest NFSHomeDirectory` |
| No Claude Code Keychain item | `security find-generic-password -s "Claude Code-credentials"`: attribute lookup only, never `-w` |
| No `~/.claude/.credentials.json`, `~/.grok/auth.json`, `~/.grok/bin/grok`, `~/.config/claude/projects` | file tests |
| `~/.claude/projects` absent, or containing only this procedure's fixtures | marker file `.spandeck-rv-fixtures` |
| No Headroom running or installed; no Application Support folder; no preferences for `dev.headroom.Headroom` | `pgrep`, file tests |
| Headroom not in Login Items | owner looks at System Settings ▸ General ▸ Login Items & Extensions |
| The build under test matches its manifest hash and carries no quarantine flag (no Gatekeeper bypass) | `shasum`, `xattr` |
| No employer code, private transcripts or production tokens in the account | owner confirms; never sign in to Claude Code, Grok or work accounts there |

The procedure doesn't use `HOME=…` redirection, admin rights, packet capture, `fs_usage`, `eslogger`, DTrace or any security-setting change. It never creates Keychain items or provider keys, and never sends a credential anywhere.

## 3. Verification matrix

Expected results are for the current code. "Evidence today" lists what exists now; **no row has [runtime] evidence yet**. Steps refer to §5.

| ID | Boundary | Expected | Evidence today | Runtime check (step) | Pass | Fail → stop? |
|---|---|---|---|---|---|---|
| V1 | Normal start | Menu-bar item appears; no error UI; no Dock icon | [code] | 7–8: launch, look at the menu bar and popover | Item shows gauges; popover opens | No item, or a crash → record |
| V2 | Claude credential | No Keychain access, no prompt, no `security` child | [code] [mocked] `defaultLaunchSideEffects` [CI] | 7: `children.txt`, `tool-log.txt`, prompt watch over ≥ 330 s | No child; no Headroom-attributed `security` event; no prompt | Any → **stop** (§6) |
| V3 | Grok credential and CLI | No `grok` child; no `auth.json` read | [code] [mocked] `GrokConsentTests` [CI] | 7: `children.txt`. A read of the absent `auth.json` can't be seen without root tracing | No `grok` child | `grok` child → **stop**. The read itself stays **[not verified]** |
| V4 | Network | No connection by the app | [code] [mocked] (transport fake records none) [CI] | 7: `lsof -i` every 1 s, `nettop` bytes at the end, app log network events | No socket lines; `nettop` 0 bytes; no `nw_` / `Task <` events | Any → **stop**, record hostnames only |
| V5 | Pricing | No download; `pricing-source.json` absent | [code] [mocked] `offlineStartupUsesBundledPricing` | 6, 9: V4 plus `app-support.txt` | Absent and no network | File present, or network → **stop** |
| V6 | Login item | Not registered; no "Login item added" notification | [code] [mocked] `existingLoginItemIsLeftAlone`, `defaultLaunchSideEffects` | 7–8: Login Items list, notifications, ServiceManagement log events | Not listed; no notification | Listed → **stop** |
| V7 | Preferences | Consent keys absent or false; no unexpected keys | [code] | 9: `preferences.txt` | `claude.limits.enabled` / `grok.enabled` absent or 0. AppKit status-item keys may appear and are recorded | Consent key true → **stop** |
| V8 | Files written | Only `~/Library/Application Support/Headroom/` (`0700`) with `claude-ledger.json` and `.key` (`0600`); macOS-owned files attributed separately | [code] [mocked] mode assertions | 9: `app-support.txt`, `new-files.txt` | Modes as stated; no other app files | Files outside scope → **stop** |
| V9 | Background work | No power assertion; no subprocesses; timers only | [code] | 7, 9: `assertions.txt`, `children.txt`, CPU samples | No assertion; 0 children over ≥ 330 s (covers the 60 s, 10 s and 5 min timers) | Unexpected process → record |
| V10 | Cache minimization | Schema 4; `files`/`seen` keys are 32-hex ids; no `/`; no content, path or id canary; model canary present (proves indexing happened) | [mocked] `ledgerCacheKeepsNoPathsOrContent` | 9: `canaries.txt` cache summary | As expected | Any canary or `/` → **stop**, file an issue |
| V11 | Accounting display | `claude-sonnet-4-5` 600 tokens; `claude-rvmodel…` shown as unpriced; totals marked partial (`≥$`) | [code] [mocked] (fixture parsed by the production `Ledger`, §9) | 8: popover screenshot | Matches | Wrong totals → record |
| V12 | Temporary files | No `.claude-ledger.*.tmp-*` after quit | [code] [mocked] | 10–11: `app-support.txt` after quit | None | Leftovers → record |
| V13 | Clear cached usage | Settings ▸ Clear cached usage data removes cache and key; the next refresh rebuilds from transcripts with a **new** key; fixtures unchanged | [code] [mocked] `LedgerCacheTests` | 12: before/after captures, key-file hash comparison (equality only), fixture `shasum` | New key; same totals; transcripts byte-identical | Old key back, or transcripts changed → record |
| V14 | Persistence of "off" | After relaunch, consent still off and V2–V6 still hold | [code] [mocked] | 13: second launch | Same as first launch | Any provider activity → **stop** |
| V15 | Login item opt-in / out (optional, owner-authorized) | Toggle on: listed, with a notification. Toggle off: removed | [code] [mocked] | 14 | Listed, then removed | Not removed → record, clean up by hand |
| V16 | Consent-enabled paths | — | [code] [mocked] only | **Not run.** Needs real credentials or requests to provider endpoints, which the owner's rules forbid. Would need a debug-only local transport (a `URLProtocol` or local mock server injected into a debug build) | — | **[not verified]** |
| V17 | `--snapshot`, release | Exit 64; no PNG; no menu-bar UI; no Application Support created | [code] [mocked] `SnapshotTests`; release binary inspected with `nm` | 4–5: `snapshot` | Exactly that | PNG written, or UI starts → **stop** |
| V18 | `--snapshot`, debug | Exit 0; 3 PNGs; synthetic data only; no Application Support; no app left running | [code] [mocked] `SnapshotTests` | 4–5: `snapshot`, visual check of `popover.png` | Shows `SnapshotFixture` models, not `claude-rvmodel…` | Fixture or real data in a PNG → **stop** |
| V19 | Performance (#8) | Recorded, no pass bar yet | — | 7, 15: time to process, CPU and RSS samples, indexing with N timing fixtures | Recorded | — |
| V20 | Responsiveness (#46) | Recorded only; not fixed here | — | 8: popover open and close latency while indexing | Recorded | Hangs → note in #46 |

## 4. Tool: `scripts/runtime-verify.sh`

The script is standard macOS shell (bash 3.2, `osascript -l JavaScript`, `lsof`, `nettop`, `log`, `pmset`). It needs no admin rights and installs nothing. Evidence is written to `~/spandeck-rv-evidence/<run>/` (`0700`), and `summary` writes a sanitized copy to the shared stage folder. Evidence contains file names, modes, counts and pass/fail lines. It never contains transcript text, credential values or network payloads.

**How the tool itself was checked (2026-10-16, in this session; this is not evidence about the app):**
- `preflight` refuses the developer account by name. With the account name spoofed, it refuses again because the account is an administrator. In both cases it stops before creating anything.
- After a preflight that didn't pass, `fixtures`, `launch` and `snapshot` refuse to run and create nothing.
- Each `launch` writes to its own `launch-<label>` folder and refuses to reuse one, so later runs can't overwrite the main run's evidence.
- **Fixtures, against the real indexer [mocked]:** the production `Ledger` parsed them, using a temporary test that was not committed. Result:
  - `claude-sonnet-4-5`: 600 tokens, complete;
  - `claude-rvmodel…`: unavailable;
  - month total: partial;
  - the written cache contains the model canary and no content, path or id canary, and no `/`.
- **Cache check, against hand-made caches:** a clean v4-shaped cache passes. A leaky one is flagged on every canary, on `/` and on non-hex ids.
- **Monitor, against a stand-in program named `Headroom`** (not the app). It caught:
  - 0.5-second child processes (`children.txt`);
  - a loopback listening socket (`lsof`);
  - a `nettop` row without admin rights.

  A stand-in "release" build that wrote PNGs was reported as failing the snapshot check.
- **`stage`:** built `83a9af8`, a universal ad-hoc release build plus the arm64 debug build, into a scratch folder, and launched nothing.
- `shellcheck -S warning` is clean.

## 5. Procedure (owner, in the `spandecktest` account)

**In your normal account, building only:**
1. `cd ~/Desktop/project/spandeck && git checkout main && git pull --ff-only && scripts/runtime-verify.sh stage`. This records the commit, toolchain and hashes in `/Users/Shared/spandeck-rv/<sha>/manifest.txt`. It does not launch anything. Until this page's PR is merged, the script isn't on `main`: check out `docs/runtime-verification-plan` instead. `stage` records whichever commit is checked out.
2. Log out, or use Fast User Switching, then log in as **`spandecktest`**. Don't sign in to any Apple ID, Claude, Grok or work service there.

**In `spandecktest`**, with `RV=/Users/Shared/spandeck-rv/$(cat /Users/Shared/spandeck-rv/current)/runtime-verify.sh`:

3. `$RV preflight`: answer the Login Items question. **Any FAIL → stop.** Until a preflight passes, `fixtures`, `snapshot` and `launch` refuse to run.
4. `$RV fixtures 50`: the privacy fixture plus 50 timing sessions of 1000 messages each. Then `$RV capture 0-before`.
5. `$RV snapshot`, then open the debug `popover.png` (V18). Then `$RV capture 1-after-snapshot`. Application Support must still be absent (V17, V18).
6. Check that no Headroom process is left running: `pgrep -x Headroom` should print nothing.
7. `$RV launch 330 main`. This launches the staged app normally with `open`, watches for 330 s, and records process, socket, log and CPU/RSS samples. During the run, watch for any Keychain or permission prompt or notification. **If one appears, deny or close it, take a screenshot, and stop (§6).**
8. While the app is still running:
   - Open the popover and screenshot it (V1, V11, V20; synthetic data only).
   - Check Login Items and Notification Center (V6).
   - Note whether the popover opens promptly while indexing.
9. `$RV capture 2-running` (V5, V7–V10).
10. `$RV quit`, then quit from the app's menu (Quit).
11. `$RV capture 3-after-quit` (V12).
12. **V13:**
    - `shasum -a 256 ~/Library/Application\ Support/Headroom/claude-ledger.key > ~/spandeck-rv-evidence/key-before.txt`. Keep only the hash, and compare for equality only.
    - Also `shasum ~/.claude/projects/*/*.jsonl > ~/spandeck-rv-evidence/fixtures-before.txt`.
    - `$RV launch 60 clear`, then Settings ▸ Clear cached usage data ▸ confirm. Wait about 20 s, then `$RV capture 4-after-clear`.
    - Quit from the menu, then repeat both `shasum` commands into `*-after.txt` and compare.
13. **V14:** `$RV launch 120 relaunch`, then `$RV capture 5-relaunch`, then quit from the menu.
14. **V15** (optional; only if you authorize it for this account):
    - Launch the app with `$RV launch 60 loginitem`. Turn on Settings ▸ Launch at login, then check Login Items and the notification, and screenshot both.
    - Turn the toggle off, check again, and quit.
    - If it stays listed, remove it in System Settings.
15. `$RV summary`. This writes `/Users/Shared/spandeck-rv/<sha>/results-<run>.md`. Read it before sharing; it should contain only names, modes, counts and pass/fail lines.

## 6. Stop conditions

Stop the current step at once if any of these happen:
- A Keychain prompt appears, or a `security` child of Headroom shows up.
- A `grok` process starts.
- A network socket, `nettop` bytes or a connection event is attributed to Headroom.
- A login item is registered without the toggle.
- Files outside `~/Library/Application Support/Headroom` are written by the app.
- A canary appears in the cache, or fixture or real data appears in a snapshot.
- Any step asks for an admin password or a security-setting change.

**What to do then:**
- Quit the app from its menu. If it won't quit, use `kill`.
- Run `$RV capture stop` and `$RV summary`, and keep the evidence folder.
- Don't try to fix anything.

**What gets filed:** a separate issue per confirmed defect, with:
- severity;
- expected and actual behavior;
- impact;
- safe reproduction steps from this page;
- rollback considerations.

Include names, counts and modes only.

## 7. Cleanup

In `spandecktest`:
1. If Launch at login was turned on, turn it off in the app first.
2. Run `$RV clean`. It quits the app and removes:
   - Application Support;
   - the `dev.headroom.Headroom` preferences and the app's Caches, HTTPStorages and Saved Application State;
   - the fixtures, only when they're marked as fixtures.

   Evidence stays in `~/spandeck-rv-evidence`.
3. Check Login Items again.

In your normal account, when you're done:
- Run `rm -rf /Users/Shared/spandeck-rv`.
- Deleting the `spandecktest` account is your call; nothing here deletes accounts.

## 8. Results

**Not run yet.** Every boundary is **[not verified]** at runtime until the owner runs §5 and the results are recorded here.

| ID | Result | Evidence |
|---|---|---|
| V1–V15, V17–V20 | **Pending**: [not verified] | — |
| V16 | **[not verified]** by design (no real credentials or provider requests) | [code] [mocked] only |

When results arrive, record for each row:
- **Result:** pass, fail or not verified;
- **Evidence:** timestamp, the method, and the evidence file name from the summary;
- **Run details:** commit, build hashes and the machine and account details from `preflight`.

## 9. Observation limits

- **Sampling:** child processes are sampled every 0.1 s, and sockets every 1 s. A process or connection shorter than that can be missed.
  - The unified log stream (`process == "Headroom"`, network, security and ServiceManagement subsystems) adds an event record, but hostnames are usually `<private>`.
  - The `security` / `grok` log covers the whole account. On the developer account it showed about 15 `security` lines per second from other software, so it's only meaningful in a quiet test account, and only alongside `children.txt`.
- **File reads aren't observable without root** (`fs_usage`, `eslogger`). A read of an absent `~/.grok/auth.json` or of transcripts can't be seen directly. Reads are inferred from writes, child processes and the UI.
- **An empty network snapshot isn't proof** that no short connection happened. V4 combines three methods and still lists this limit.
- **File attribution:** `new-files.txt` lists every file changed in the home folder since preflight. macOS services write there too, so each entry is attributed by hand.
- **One machine:** this is one Apple Silicon machine on macOS 26.5. Intel and other macOS versions stay [not verified] (see [RELEASE_SIGNING.md](../RELEASE_SIGNING.md) step 8).

## 10. What #3 still needs

- [ ] §5 run in `spandecktest`, with results recorded in §8 for V1–V15 and V17–V20.
- [ ] Each confirmed defect filed as its own issue; none silently fixed.
- [ ] Inventory §9 item "Default launch confirmed with reproducible runtime observations" updated from §8.
- [ ] Roadmap and inventory status updated with the [runtime] results.
- [ ] V16 (consent-enabled paths) either accepted by the owner as [not verified] for #3, or covered by a separately approved local-transport design.

The performance numbers from V19 feed #8, and responsiveness notes from V20 feed #46. Neither is required to close #3.
