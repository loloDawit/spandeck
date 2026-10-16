# Audit 0003 — Runtime verification on macOS (§7 Phase 2)

Issue: [#3](https://github.com/loloDawit/spandeck/issues/3) · Parent: [#2](https://github.com/loloDawit/spandeck/issues/2) · Related: #5, #8, #11, #46 · Code inventory: [0003-security-inventory.md](0003-security-inventory.md)

> **Status (2026-10-16): runtime verification done on one Mac (runs 1 and 2).**
> - **Default launch:** no credential or Keychain access, no child process, no network observed, no login item, no consent change. Its only side effects are local: it creates `~/Library/Application Support/Headroom` (`0700`) with an index cache and key (`0600`) that hold no paths, ids or content, plus a preferences file. Labeled [runtime] in §8.4, within the limits in §9.
> - **Run 2** used a kernel-reported fork monitor, proven by a positive control in the same account.
> - **Not verified:** V16 (consent-enabled requests; by design), Intel and other macOS versions, and file reads (not observable without root).
> - **No app defect found.**

**Terms used below:**
- **Menu-bar item:** the app's gauges near the clock, top right (for example `10% ▁▂ 85%` for CPU and memory). It has no icon or name.
- **Popover:** the panel that opens when you click the menu-bar item, with the CPU, GPU, Memory, Battery, Claude Code and Token Usage cards. Click the item again, or anywhere else, to close it.
- **Settings:** the menu at the popover's bottom left.

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
| No Headroom running or installed; no Application Support folder; no preferences stored for `dev.headroom.Headroom` | `pgrep`, file tests, `defaults read` (an empty leftover plist is allowed) |
| Headroom not in Login Items | owner looks at System Settings ▸ General ▸ Login Items & Extensions |
| The build under test matches its manifest hash and carries no quarantine flag (no Gatekeeper bypass) | `shasum`, `xattr` |
| No employer code, private transcripts or production tokens in the account | owner confirms; never sign in to Claude Code, Grok or work accounts there |

The procedure doesn't use `HOME=…` redirection, admin rights, packet capture, `fs_usage`, `eslogger`, DTrace or any security-setting change. It never creates Keychain items or provider keys, and never sends a credential anywhere.

## 3. Verification matrix

Expected results are for the current code. "Evidence today" lists what exists now; **no row has [runtime] evidence yet**. Steps refer to §5.

| ID | Boundary | Expected | Evidence today | Runtime check (step) | Pass | Fail → stop? |
|---|---|---|---|---|---|---|
| V1 | Normal start | Menu-bar item appears; no error UI; no Dock icon | [code] | 7–8: launch, look at the menu bar and popover | Item shows gauges; popover opens | No item, or a crash → record |
| V2 | Claude credential | No Keychain access, no prompt, no `security` child | [code] [mocked] `defaultLaunchSideEffects` [CI] | 7: `forks.txt` (kernel-reported forks, run 2 onward), `tool-log.txt`, prompt watch over ≥ 330 s; positive control in step 13b | No child; no Headroom-attributed `security` event; no prompt | Any → **stop** (§6) |
| V3 | Grok credential and CLI | No `grok` child; no `auth.json` read | [code] [mocked] `GrokConsentTests` [CI] | 7: `forks.txt`. A read of the absent `auth.json` can't be seen without root tracing | No `grok` child | `grok` child → **stop**. The read itself stays **[not verified]** |
| V4 | Network | No connection by the app | [code] [mocked] (transport fake records none) [CI] | 7: `lsof -i` every 1 s, `nettop` bytes at the end, app log network events | No socket lines; `nettop` 0 bytes; no `nw_` / `Task <` events | Any → **stop**, record hostnames only |
| V5 | Pricing | No download; `pricing-source.json` absent | [code] [mocked] `offlineStartupUsesBundledPricing` | 6, 9: V4 plus `app-support.txt` | Absent and no network | File present, or network → **stop** |
| V6 | Login item | Not registered; no "Login item added" notification | [code] [mocked] `existingLoginItemIsLeftAlone`, `defaultLaunchSideEffects` | 7–8: Login Items list, notifications, ServiceManagement log events | Not listed; no notification | Listed → **stop** |
| V7 | Preferences | Consent keys absent or false; no unexpected keys | [code] | 9: `preferences.txt` | `claude.limits.enabled` / `grok.enabled` absent or 0. AppKit status-item keys may appear and are recorded | Consent key true → **stop** |
| V8 | Files written | Only `~/Library/Application Support/Headroom/` (`0700`) with `claude-ledger.json` and `.key` (`0600`); macOS-owned files attributed separately | [code] [mocked] mode assertions | 9: `app-support.txt`, `new-files.txt` | Modes as stated; no other app files | Files outside scope → **stop** |
| V9 | Background work | No power assertion; no subprocesses; timers only | [code] | 7, 9: `assertions.txt`, `forks.txt`, CPU samples | No assertion; 0 children over ≥ 330 s (covers the 60 s, 10 s and 5 min timers) | Unexpected process → record |
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

The script is standard macOS shell (bash 3.2, `osascript -l JavaScript`, `lsof`, `nettop`, `log`, `pmset`). It needs no admin rights and installs nothing. Evidence is written to `~/spandeck-rv-evidence/<run>/` (`0700`), and `summary` writes a sanitized copy to `/Users/Shared/spandeck-rv-results/`. Evidence contains file names, modes, counts and pass/fail lines. It never contains transcript text, credential values or network payloads.

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
  - 0.5-second child processes (`children.txt`, the run 1 sampler);
  - a loopback listening socket (`lsof`);
  - a `nettop` row without admin rights.

  A stand-in "release" build that wrote PNGs was reported as failing the snapshot check.
- **`stage`:** built `83a9af8`, a universal ad-hoc release build plus the arm64 debug build, into a scratch folder, and launched nothing.
- `shellcheck -S warning` is clean.

### Since run 1: kernel-reported forks and consent capture

Run 1 showed that the 0.1 s process sampler and the log streams missed `security` runs that are known to have happened (§8.2). From run 2 onward:
- **`launch` uses `procwatch`** (`scripts/runtime/procwatch.c`, compiled by `stage`; its hash is in the manifest).
  - It registers a `kqueue` `EVFILT_PROC` filter (`NOTE_FORK | NOTE_EXEC | NOTE_EXIT`) on the app's pid, so the kernel reports every fork. Nothing is sampled, and no privileges are needed for a same-user process.
  - On each fork it looks up the new child's path at once. If the child is already gone, it still logs `fork child-already-exited`, so the count stays complete.
  - It's started right after the pid appears. The app starts no child in its first milliseconds, and the 60 s and 10 s timers come later.
- **`launch` records `claude.limits.enabled` and `grok.enabled`** at the start, every 5 s, and on every change (`consent.txt`).
- **`fixtures` gives every file its own message ids,** so the timing sessions no longer deduplicate into the privacy session. The expected totals are printed.

**Checked here (tool checks, not app evidence):**
- **Stand-in program named `Headroom`, started by `open` through `launch`:** `procwatch` reported **9 of 9** children, with paths, in 3 runs out of 3:
  - 5 through Foundation `Process` with a pipe, the way `runProcess` does it;
  - 3 through raw `posix_spawn`, 5 ms apart, each running `/usr/bin/true`, which exits almost at once;
  - 1 from `Task.detached`, like `grok models`.
- **Fixtures with 2 timing files:** the production `Ledger` (a temporary test, not committed) gave exactly the printed totals: `claude-sonnet-4-5` 60,600 tokens, complete; the unpriced model 30 tokens, unavailable.
- `shellcheck -S warning` is clean, and `clang -Wall -Wextra` gives no warnings.

### Run 2 procedure (rerun of V2, V3, V9 and V14, plus the consent question)

Build with `scripts/runtime-verify.sh stage` in your normal account, after this change is merged (or from its branch). Then, in `spandecktest`:
1. **Reset:** `$RV clean`, then check that Login Items doesn't list Headroom.
2. **Gate:** `$RV preflight`. Any FAIL → stop.
3. **Fixtures:** `$RV fixtures 50`, then `$RV capture 0-before`.
4. **Main launch:** `$RV launch 330 main`.
   - You may open the popover (click the menu-bar gauges) and look at it.
   - **Don't click "Enable Claude plan limits" or "Set up Grok credits…".** Don't change Settings.
   - Expect `forks: 0` and `consent ... absent` throughout.
5. **While running:** `$RV capture 1-running`.
6. **Quit** from the app's menu, then `$RV capture 2-after-quit`.
7. **Relaunch:** `$RV launch 120 relaunch` (V14: consent still absent, still 0 forks), then quit from the menu.
8. **Positive control** (shows the monitor sees a `security` run in this account):
   - `$RV launch 90 control`, then click **Enable Claude plan limits** once.
   - There is no Keychain item, so `security` finds nothing and nothing is sent.
   - Expect at least one `fork child … /usr/bin/security` in `launch-control/forks.txt`, plus another every 60 s, and `claude.limits.enabled=1` from the click on.
   - Then Settings ▸ **Turn off Claude plan limits**, and quit.
9. **Finish:** `$RV summary`, then `$RV clean`.

**Stop conditions (§6) apply.** In particular, any fork or consent change in steps 4–7 means stop and keep the evidence.

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
   - Click the app's menu-bar gauges to open the popover, and screenshot it (V1, V11, V20; synthetic data only).
   - Check Login Items and Notification Center (V6).
   - Close it (click elsewhere), open it again while indexing is still running, and note whether it opens promptly.
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
15. `$RV summary`. This writes `/Users/Shared/spandeck-rv-results/results-<sha>-<run>.md`, a folder the test account creates and your account can read. Read it before sharing; it should contain only names, modes, counts and pass/fail lines.

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
- Run `rm -rf /Users/Shared/spandeck-rv`. The test account removes `/Users/Shared/spandeck-rv-results` once the results are recorded.
- Deleting the `spandecktest` account is your call; nothing here deletes accounts.

## 8. Results

### 8.1 Run 1: 2026-10-16, 05:03–05:24 UTC (owner)

**Setup:**
- **Build:** `227015c` (release `6390dbef…`, debug `1a5974f5…`), universal ad-hoc release build, staged from the owner's account. No quarantine flag and no Gatekeeper bypass.
- **Machine and account:** Apple M2 Pro, 12 cores, 16 GB, macOS 26.5 (25F71). Account `spandecktest` (uid 502, Standard user, not MDM-enrolled).
- **Preflight:** all 14 checks passed.
  - No Claude Keychain item, `~/.claude/.credentials.json`, `~/.grok/auth.json` or `grok` binary.
  - Fresh account: no Application Support folder or preferences, no install.
  - The owner saw no Headroom entry in Login Items.

**Fixtures:**
- 1 privacy session: 20 messages, each streamed twice, plus 1 unpriced message.
- 50 timing sessions of 1000 messages each, about 50 MB.

**Evidence:**
- The owner's sanitized `results-227015c…-20261016T050315Z.md`.
- 5 screenshots: 10:11:56, 10:15:38, 10:18:46, 10:18:56 and 10:23:46 PM local (UTC−7).

These stay with the owner and aren't committed: one shows unrelated windows. Times below are UTC.

| ID | Result | Evidence and notes |
|---|---|---|
| V1 Normal start | **Pass** [runtime] | Process up 99–182 ms after `open` across 4 launches. Menu-bar gauges and popover work (screenshot 05:11:56). |
| V2 Claude credential | **Not verified** in run 1; **pass in run 2** (§8.4) | 0 child processes and 0 log events in all launches. That includes windows where consent was **on**, so `security` must have run (§8.2). The monitor can't show absence. No Keychain prompt was reported; with no Keychain item, none is expected either way. |
| V3 Grok credential and CLI | **Not verified** in run 1; **CLI pass in run 2** (§8.4) | No `grok` binary exists in the account, so `grok models` couldn't run. Grok consent stayed off ("Set up Grok credits…" in Settings). An `auth.json` read isn't observable (§9). |
| V4 Network | **Pass, with limits** [runtime] | `lsof -i` at 1 Hz showed 0 sockets in 4 launches (570 s in total). `nettop` showed no rows. 0 network log events. Consistent with the code even after consent: with no credential, no request is sent. Short connections between samples can't be excluded (§9). |
| V5 Pricing | **Pass** [runtime] | No `pricing-source.json` in any capture. Settings shows "LiteLLM 4d52918 · built in". No network (V4). |
| V6 Login item at launch | **Pass** [runtime, owner observation] | Absent before launch (preflight). The owner confirmed it was still absent after the earlier launches, before they turned it on (V15). The app log recorded no ServiceManagement event, but that's not evidence either way (§8.2). |
| V7 Preferences | **Pass for default launch** [runtime]; consent change pending confirmation | Domain absent before launch. The 05:11:56 screenshot, about 70 s after launch, shows "Plan limits are off". By 05:15:38 Settings shows "Turn off Claude plan limits", and `claude.limits.enabled = 1` from 05:16:46 on (§8.2). Also `usage.metric` (the Cost/Tokens switch). |
| V8 Files written | **Pass** [runtime] | The app wrote:<br>• `~/Library/Application Support/Headroom/` (`drwx------`) with `claude-ledger.json` and `claude-ledger.key` (`-rw-------`);<br>• `~/Library/Preferences/dev.headroom.Headroom.plist`;<br>• the per-user Metal shader cache `…/C/dev.headroom.Headroom/com.apple.metal/…`, written by system graphics frameworks for the process.<br>The other changed files belong to macOS services, Chrome, Warp and Docker in the test account. |
| V9 Background work | **Pass for power assertions** [runtime]; subprocesses not verified in run 1, **pass in run 2** (§8.4) | No Headroom power assertion in any capture. Subprocess absence can't be shown (V2). |
| V10 Cache minimization | **Pass** [runtime] | Schema 4. 51 `files` and 1001 `seen` entries, all 32-hex ids. Hex `keyCheck`. No `/`. No content, path or id canary. The model canary is present, which shows indexing ran. The same result held at every capture, including after clear and after relaunch. |
| V11 Accounting display | **Pass** [runtime] | `claude-sonnet-4-5` shows 30.0K tokens at $0.33, and `claude-rvmodel…` shows 10 tokens at n/a. Totals read `≥$0.33`, with an explanation and "?" on the chart. 30.0K is correct: the timing sessions reused the privacy session's message ids, so 51,020 streamed records deduplicated to 1000 unique messages of 30 tokens each. That's a fixture design flaw (§8.2); the app's arithmetic is right ($3/M input, $15/M output). |
| V12 Temporary files | **Pass** [runtime] | No `.claude-ledger.*.tmp-*` after quit. |
| V13 Clear cached usage | **Pass** [runtime] | The confirmation text names only the cache and key, and says transcripts, credentials, prices and consent are kept. After confirming: "Cached usage data cleared. Totals are being rebuilt". The rebuild took about 6 s at 55–97 % CPU, and totals were unchanged.<br>Owner's `shasum` comparison (equality only, no hashes shared): `claude-ledger.key` **different** before and after, so a new key was made and the old one didn't come back; fixture transcripts **same**, so they weren't modified. |
| V14 "Off" persists | **Not verified** in run 1; **pass in run 2** (§8.4) | Consent was on before the relaunch, so this tested the reverse: **consent on persisted** across the relaunch (`claude.limits.enabled = 1` at 05:22:35). Needs a rerun with consent never enabled. |
| V15 Login item opt-in | **Pass** [runtime, owner observation] | After Settings ▸ Launch at login, macOS showed a notification and listed "Headroom — Application" under Open at Login (screenshot 05:23:46). Turning the toggle off removed it. |
| V16 Consent-enabled paths | **Not verified** (by design) | — |
| V17 `--snapshot`, release | **Pass** [runtime] | Exit 64; 0 files; no process left running; Application Support still absent. |
| V18 `--snapshot`, debug | **Pass** [runtime] | Exit 0; `popover.png`, `strip-dark.png`, `strip-light.png`; no process left running; Application Support still absent.<br>`popover.png` (shared by the owner and checked) shows only `SnapshotFixture` data: `claude-example-opus`, `claude-example-sonnet`, `grok-example`, "Example plan". There's no fixture model, and the system figures don't match the test Mac (32 GB memory and a discharging battery, against 16 GB and fully charged).<br>Cosmetic, not security: the Cost/Tokens switch, Settings, Keep awake, refresh and Quit controls render as yellow 🚫 placeholders. Likely SwiftUI `ImageRenderer` not drawing those controls; not investigated. |
| V19 Performance (#8) | Recorded [runtime] | Time to process: 99–182 ms. First index of about 50 MB: 5 one-second samples above 60 % CPU (1–5 s after launch).<br>CPU in the main launch, by 20 s window:<br>• 20–60 s: 3.3–3.4 %, popover presumably closed;<br>• 60–200 s: 7–14 % (median 9.9 %, p90 16 %), while the owner had the popover and Settings open and enabled consent. These causes can't be separated.<br>CPU after relaunch with the cache present: 2.0 % mean (peak 32.6 %).<br>RSS: 71–87 MB.<br>Only one machine and one run. Samples include the app's own 1 s system sampling (the default interval). The summary keeps the first 200 samples of each launch. |
| V20 Responsiveness (#46) | No symptom reported | The popover opened during and after indexing (screenshots). Latency wasn't measured. |

### 8.2 What the run showed beyond the matrix

1. **Claude consent turned on during the main launch, between 05:11:56 and 05:15:38.**
   - The default launch left it off: the 05:11:56 screenshot shows "Plan limits are off" with the "Enable Claude plan limits" button, about 70 s after launch.
   - **The owner isn't sure whether they clicked "Enable Claude plan limits".** The cause is therefore **unresolved**.
   - [code] The only place that stores `true` is `ProviderServices.setClaudeLimitsEnabled(true)`. It's reached only from the consent card's "Enable Claude plan limits" button (`PopoverView.swift:541`, no keyboard shortcut). Settings can only turn consent off, and nothing at launch or on a timer writes it.
   - **An accidental click is the likely explanation, but that comes from the code, not from the run.** No defect is filed. The rerun (§10) leaves the popover's consent card untouched and captures the value at fixed times, which settles it. A `true` value without a click would be a P0 consent defect.
2. **The monitor's zero counts aren't evidence of absence.** With consent on and no Keychain item, the code [code: `ProviderServices.refreshClaude`, `ClaudeLimitsClient.credentials`, `KeychainCredentialStore`] runs `/usr/bin/security` when consent is given and every 60 s after. The UI's "No Claude Code or Grok account found" appears only after that read returned nothing. Yet:
   - `children.txt` (sampled every 0.1 s) recorded 0 processes in the main launch and 0 in the 120 s relaunch, where at least two runs were expected;
   - the `security` / `grok` log stream recorded nothing;
   - the app log recorded no ServiceManagement event when the login item was registered (V15).

   A `security` lookup that fails fast finishes between samples, and these processes evidently don't log at the captured level. **V2, V3 (subprocess part), V6 and V9 (subprocess part) need a monitor that sees every fork**, such as a `kqueue` `EVFILT_PROC` watcher on the app's process, checked first against a known positive.
3. **The test account isn't pristine.** Chrome (cookies and history changing during the run), Warp (with Sentry session files), Docker and Google Updater are installed and active. None of their files are attributed to Headroom, but the "no other activity" baseline is noisier than intended, and per-user Keychain database writes (`keychain-2.db-wal`) can't be attributed. A fresh account, or one with only the default apps, would give a cleaner baseline.
4. **The timing fixture reused message ids** across all 51 files, so deduplication left 1000 unique messages. The indexing time still covers parsing about 50 MB. The fixture needs unique ids per file to measure ingesting 51,000 distinct messages.

### 8.3 Owner input needed

1. **Consent change:** the owner is unsure. Left unresolved until the rerun (§8.2).
2. ~~**Login items** (V6, V15)~~: answered. It was absent before the toggle, a notification appeared on enabling, and it was removed on disabling.
3. ~~**V13 hashes**~~: answered. Key: different; fixtures: same.
4. ~~**V18 visual check**~~: answered. The owner shared the image, and it is synthetic only (V18).

### 8.4 Run 2: 2026-10-16, 06:27–06:38 UTC (owner)

**Setup:**
- **Build:** `855b6f8`, same app binaries as run 1 (release `6390dbef…`, debug `1a5974f5…`), plus `procwatch` `ccb4a99a…`.
- **Account:** `spandecktest`, reset with `clean`. All 14 preflight checks passed, and Login Items didn't list Headroom.
- **Fixtures:** the privacy session plus 50 timing sessions, with message ids unique per file: 50,071 distinct messages.
- **Rules:** the owner was told not to touch the consent card or Settings in the main launch and the relaunch, and to click "Enable Claude plan limits" once in the control launch.

**Evidence:** the owner's sanitized `results-855b6f8…-20261016T062737Z.md`. No screenshots.

| ID | Result | Evidence |
|---|---|---|
| V2 Claude credential | **Pass** [runtime] | Main launch, 330 s: `procwatch` reported **0 forks**, with five 60 s refresh ticks inside the window. Relaunch, 79 s: 0 forks. Control: after the Enable click, **2 forks of `/usr/bin/security`**: 06:37:18.2, the forced refresh, and 06:37:48.1, the 60 s timer, exactly 60 s after launch at 06:36:47.9. So the monitor sees `security` in this account, and its 0 in the main launch means no Keychain lookup. Nothing was sent: there was no credential, and no sockets were seen. |
| V3 Grok credential and CLI | **Pass for the CLI** [runtime]; **file read not verified** | 0 forks in the main launch and the relaunch, so no `grok`. Grok consent stayed `absent` throughout. An `auth.json` read isn't observable (§9). |
| V4 Network | **Pass, with limits** [runtime] | 0 socket lines in all 3 launches (500 s in total). `nettop` showed no rows. 0 network log events. |
| V7 Preferences | **Pass** [runtime] | `claude.limits.enabled` and `grok.enabled` were `absent` at every 5 s check: main launch 06:28:39–06:34:14, relaunch 06:35:01–06:36:19. The only stored key was `usage.metric`, the popover's Cost/Tokens switch (`@AppStorage` at `PopoverView.swift:618`). In the control, `claude.limits.enabled=1` appeared at the first check after the click (06:37:19). |
| V9 Background work | **Pass** [runtime] | No Headroom power assertion. 0 forks. |
| V10 Cache minimization | **Pass** [runtime] | Schema 4. 51 `files` and 50,071 `seen` entries, all 32-hex ids. No `/`. No content, path or id canary. Model canary present. Cache 8.2 MB (`0600`), folder `0700`. The same result held after quit. |
| V12 Temporary files | **Pass** [runtime] | None after quit. |
| V14 "Off" persists | **Pass** [runtime] | After quitting and relaunching, consent was still `absent`, with 0 forks over 79 s, which includes one 60 s tick. The owner quit at 06:36:19, before the 120 s window ended. |
| V19 Performance (#8) | Recorded [runtime] | Time to process: 156–208 ms. First index of 50,071 messages (about 50 MB): about 6 s at 67–99 % CPU.<br>Peak RSS: 161 MB during the first index, then 51–70 MB. 143 MB while a relaunch loaded the 8.2 MB cache.<br>CPU, by 30 s window after indexing: 0.4–7 %. Mean over the relaunch: 4.8 %.<br>One machine; the summary keeps the first 200 samples of each launch. |

**The consent question from run 1 is resolved.** Across 409 s of the main launch and the relaunch, with the popover in use, consent never changed. It changed exactly once, at the deliberate click in the control. No automatic enabling was observed, and the code has no path for it (§8.2), so run 1's change is attributed to a click. **No defect.**

**Answer to #3's last criterion: is the default launch quiet and offline?**

*Offline:* yes, as observed.
- No connection was seen: sockets sampled every second, `nettop`, and the log.
- No credential was read: kernel-reported forks, checked against a positive control.

*Side effects:* local and expected.
- It reads `~/.claude/projects` (and `~/.config/claude/projects`, `~/.grok/sessions`).
- It creates `~/Library/Application Support/Headroom/` (`0700`) with `claude-ledger.json` and `claude-ledger.key` (`0600`). These hold opaque ids and hourly token counts per model, not paths, ids or content.
- It writes `~/Library/Preferences/dev.headroom.Headroom.plist` (UI settings only), and macOS adds a Metal shader cache.
- It registers no login item and holds no power assertion.

*Scope:* one Apple Silicon Mac on macOS 26.5, with an ad-hoc build, under the limits in §9.

## 9. Observation limits

- **Sampling:** child processes are sampled every 0.1 s, and sockets every 1 s. A process or connection shorter than that can be missed. **Run 1 confirmed this:** `security` runs that the code and UI show happened were not recorded (§8.2).
  - The unified log stream (`process == "Headroom"`, network, security and ServiceManagement subsystems) adds an event record, but hostnames are usually `<private>`.
  - The `security` / `grok` log covers the whole account. On the developer account it showed about 15 `security` lines per second from other software, so it's only meaningful in a quiet test account, and only alongside `forks.txt`.
- **File reads aren't observable without root** (`fs_usage`, `eslogger`). A read of an absent `~/.grok/auth.json` or of transcripts can't be seen directly. Reads are inferred from writes, child processes and the UI.
- **An empty network snapshot isn't proof** that no short connection happened. V4 combines three methods and still lists this limit.
- **File attribution:** `new-files.txt` lists every file changed in the home folder since preflight. macOS services write there too, so each entry is attributed by hand.
- **One machine:** this is one Apple Silicon machine on macOS 26.5. Intel and other macOS versions stay [not verified] (see [RELEASE_SIGNING.md](../RELEASE_SIGNING.md) step 8).

## 10. What #3 still needs

Every #3 deliverable now has evidence. The last one, "Confirm whether the default launch is quiet/offline or has side effects, using reproducible observations", is answered in §8.4. **Closing #3 is the owner's decision.** What stays open or out of scope:
- **V16, consent-enabled paths:** not verified by design (no real credentials or provider requests). Covering them needs a separately approved local-transport design.
- **Coverage:** Intel Macs, other macOS versions and a Developer ID-signed build aren't covered. Signing is tracked in #11; see [RELEASE_SIGNING.md](../RELEASE_SIGNING.md) step 8.
- **File reads aren't observable without root.** A read of the absent `auth.json`, or of transcripts outside the expected folders, isn't shown.
- **Hand-offs:** V19 figures go to #8. Nothing responsiveness-related (V20) was observed for #46.
- **Debug snapshot cosmetics:** some controls render as 🚫 placeholders (V18). Owner to decide whether to track it.
