# Run 4: runtime verification of P1–P4 (#5) — guide, **pending**

**Issue:** #5 (M0, privacy). **Follows:** [audit 0007](0007-privacy-verification.md) §7–§8 and [audit 0008](0008-identity-isolation.md).
**Build under test:** `main` at `6e777c0` (P1 #66, P2 #68, P3 #11, P4 #70; hosted CI run 39076084193 green).
**Pre-#70 build** (to create an "existing install"): `6ce1987` (main after #69; has P1, P2 and P3, not P4).
**Status:** **pending, owner.** Nothing here has been run. Don't record a result until the run has happened.

Run 3 (`c68b108`) and the audit 0008 run (`b57dea6`) predate P1, P2 and P4. This run checks them in the running app:

| Check | What it shows | How |
|---|---|---|
| **P1** | Invalid model ids become `unknown`, keep their tokens, aren't priced and don't appear anywhere | A fifth synthetic fixture with 5 invalid ids carrying a `RVBADMODEL` canary; `capture`'s canary search; UI |
| **P2** | With `debugHover` set, the release app doesn't create or change `SpanDeck-hover.log` | Absent stays absent; a seeded log keeps its size, mtime and hash |
| **P3** | SpanDeck and Headroom stay apart | `fingerprint` / `compare` of both apps' folders, preferences and logs |
| **P4** | A pre-#70 cache and key get the backup-exclusion attribute at load; the key's bytes don't change; replacement and Clear keep it | xattr + `tmutil isexcluded` in `~/Library/Application Support` (eligible location) with an `[Included]` control |
| **Consent, canaries** | Both integrations stay off; no canary but the allowed model in any file the app writes | `launch`'s consent and fork/socket monitors; `capture`'s canary search |

## Rules
- **Run every block in `bash`:** type `bash` and press Return before pasting.
  - macOS's default zsh doesn't treat `#` as a comment in pasted lines. A line like `X=1   # note` then runs `#` as a command and drops the assignment.
  - No code line here carries a trailing comment, but bash is still the shell this guide was checked in (`bash -n` and dry runs).
- **Two accounts, never mixed:**
  - **Build steps (B1, B2) run in your normal account.** They build and stage, and launch nothing. They stage from throwaway worktrees at fixed commits, so your checkout isn't switched, pulled or changed.
  - **Everything else runs in the dedicated Standard account `spandecktest`.** The helpers refuse to define themselves in any other account, every step function checks the account again, and `preflight` refuses any other account.
- **Synthetic data only:** the script's fixtures and the P1 fixture below. No real transcripts, credentials or provider accounts. Both consent switches stay off.
- **What gets removed, and only where this guide says so:**
  - the script's `clean` (SpanDeck's own state, its registered fixtures and `SpanDeck-hover.log`; never Headroom's);
  - `rv4_abort`/T7's removal of the one `debugHover` key and of this run's control file;
  - B1/B2's removal of their own temporary worktrees.
- **Never overwritten:** an existing hover log is copied to `~/rv4-hover-log.keep` first, and that copy is never overwritten. A restore only happens when the log is absent.
- **Evidence** stays in `~/spandeck-rv-evidence/<run>/`, plus `summary`'s sanitized file. `summary` collects only the `*/*.txt` capture files. The `p1-`, `p2-` and `p4-*.txt` files in the run folder are read by hand for the report.
- **What goes to GitHub** is the pass/fail table in §Report: no paths, no hashes (only *same*/*different*), no fixture token.
- **`tmutil isexcluded` under `/private/tmp` (or `$TMPDIR`) proves nothing:** Time Machine excludes those folders, so everything there reads `[Excluded]`. This guide checks only in `~/Library/Application Support`, against a control.
- **Answer the script's prompts:** `preflight` asks about Login Items, and `clean` asks before it removes anything.

## Stop conditions
Stop, don't continue, run `rv4_abort`, and report it:
- **P0:** any canary other than `model` (`claude-rvmodel…`) in a file the app wrote (`capture`'s `canaries.txt`), in the usage cache (`inspect_cache` says `contains canary …: true`), or in a screenshot. **This includes `badmodel`.**
- `preflight` reports any `FAIL`, or a helper prints `STOP`.
- A consent value turns true, or `launch` reports child processes or socket lines.
- `SpanDeck-hover.log` appears, or its size, mtime or hash changes (P2 fail).
- `compare` reports `legacy state CHANGED` (P3 fail).
- The key's hash changes before Clear (P4 fail).

Recorded as **inconclusive**, without stopping the run:
- the control file reads `[Excluded]` (the location isn't eligible here);
- `tmutil` errors.

The xattr evidence still counts in both cases.

## B. Build-account helpers (normal account, in `bash`)
```bash
rv4_stage() {
  local co=${1:?usage: rv4_stage CHECKOUT COMMIT} want=${2:?usage: rv4_stage CHECKOUT COMMIT} full wt rc
  [ "$(id -un)" != spandecktest ] || { echo "STOP: build steps run in your normal account"; return 1; }
  git -C "$co" rev-parse --git-dir >/dev/null 2>&1 || { echo "STOP: $co is not a git checkout"; return 1; }
  git -C "$co" fetch -q origin || { echo "STOP: git fetch failed"; return 1; }
  full=$(git -C "$co" rev-parse --verify "$want^{commit}") || { echo "STOP: unknown commit $want"; return 1; }
  wt=$(mktemp -d "${TMPDIR:-/tmp}/rv4-stage.XXXXXX") || return 1
  git -C "$co" worktree add -q --detach "$wt" "$full" || { rmdir "$wt"; echo "STOP: worktree failed"; return 1; }
  "$wt/scripts/runtime-verify.sh" stage; rc=$?
  git -C "$co" worktree remove --force "$wt"
  [ "$rc" = 0 ] && [ "$(cat /Users/Shared/spandeck-rv/current)" = "$full" ] || { echo "STOP: staging $want failed"; return 1; }
  echo "OK: staged $full"
}
```
`stage` builds the release app and the debug binary, copies them, the script and `identity.env` to `/Users/Shared/spandeck-rv/<sha>/`, and writes a manifest. It launches nothing and reads no transcripts. `scripts/runtime-verify.sh` and `Resources/identity.env` are identical at `6ce1987` and `6e777c0`, and both builds have SpanDeck's own identity (`io.github.lolodawit.SpanDeck`, `Application Support/SpanDeck`), which `build.sh` enforces with `check-identity.sh`.

## T. `spandecktest` helpers (paste once per shell, in `bash`)
```bash
if [ "$(id -un)" != spandecktest ]; then echo "STOP: not spandecktest; no helpers defined"; else
APPSUP="$HOME/Library/Application Support/SpanDeck"
CONTROL="$HOME/Library/Application Support/spandeck-rv4-control.txt"
HLOG="$HOME/Library/Logs/SpanDeck-hover.log"
KEEP="$HOME/rv4-hover-log.keep"
STAGE=/Users/Shared/spandeck-rv
rv4_me() { [ "$(id -un)" = spandecktest ] || { echo "STOP: not spandecktest"; return 1; }; }
ev() { cat "$HOME/spandeck-rv-evidence/current" 2>/dev/null; }
rv4_use() {
  rv4_me || return 1
  local want=${1:?usage: rv4_use COMMIT} sha d
  sha=$(cat "$STAGE/current" 2>/dev/null); d="$STAGE/$sha"
  case "$sha" in "$want"*) ;; *) echo "STOP: staged build is ${sha:-none}, not $want"; return 1 ;; esac
  [ "$(awk '/^release sha256:/{print $3}' "$d/manifest.txt")" = "$(shasum -a 256 "$d/SpanDeck.app/Contents/MacOS/SpanDeck" | cut -d' ' -f1)" ] || { echo "STOP: manifest mismatch"; return 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$d/SpanDeck.app/Contents/Info.plist")" = io.github.lolodawit.SpanDeck ] || { echo "STOP: wrong bundle id"; return 1; }
  ! xattr -r "$d/SpanDeck.app" 2>/dev/null | grep -q com.apple.quarantine || { echo "STOP: quarantined"; return 1; }
  RV="$d/runtime-verify.sh"; echo "OK: using $sha"
}
rv4_keep_log() {
  rv4_me || return 1
  if [ -L "$HLOG" ]; then echo "STOP: the hover log is a symlink; leave it and resolve first"; return 1; fi
  if [ ! -e "$HLOG" ]; then echo "no existing hover log"; return 0; fi
  if [ -e "$KEEP" ]; then
    cmp -s "$HLOG" "$KEEP" && { echo "keep copy already matches the log"; return 0; }
    echo "STOP: $KEEP exists and differs from the log; resolve by hand (nothing was overwritten)"; return 1
  fi
  cp -pn "$HLOG" "$KEEP" && cmp -s "$HLOG" "$KEEP" && echo "kept a copy of the existing hover log"
}
rv4_restore_log() {
  rv4_me || return 1
  [ -e "$KEEP" ] || { echo "nothing to restore"; return 0; }
  if [ -e "$HLOG" ] || [ -L "$HLOG" ]; then echo "the hover log exists; not restoring over it"; return 0; fi
  mkdir -p "$HOME/Library/Logs" && cp -p "$KEEP" "$HLOG" && cmp -s "$KEEP" "$HLOG" && echo "restored the hover log"
}
rv4_control() {
  rv4_me || return 1
  [ -e "$CONTROL" ] || [ -L "$CONTROL" ] || printf 'rv4 control, synthetic\n' > "$CONTROL"
  [ -f "$CONTROL" ] && [ ! -L "$CONTROL" ] || { echo "STOP: control file problem"; return 1; }
}
rv4_debughover() {
  rv4_me || return 1
  case "${1:-}" in
    on) defaults write io.github.lolodawit.SpanDeck debugHover -bool true ;;
    off) defaults delete io.github.lolodawit.SpanDeck debugHover 2>/dev/null || true ;;
    *) echo "usage: rv4_debughover on|off"; return 1 ;;
  esac
}
rv4_p1_fixture() {
  rv4_me || return 1
  local run tok mark dir f ts long m n=0
  run=$(ev); [ -n "$run" ] && [ -f "$run/canaries.txt" ] || { echo "STOP: no run with fixtures"; return 1; }
  tok=$(sed -n 's/^id=rvid//p' "$run/canaries.txt"); [[ "$tok" =~ ^[0-9a-f]{12}$ ]] || { echo "STOP: no fixture token"; return 1; }
  mark="$HOME/.claude/projects/.spandeck-rv-fixtures"
  [ "$(sed -n 's/^run=//p' "$mark" 2>/dev/null | head -1)" = "$(basename "$run")" ] || { echo "STOP: the fixture marker isn't this run's"; return 1; }
  dir="$HOME/.claude/projects/-Users-spandecktest-rvpath$tok"; f="$dir/rvid$tok-p1models.jsonl"
  [ -d "$dir" ] && [ ! -L "$dir" ] || { echo "STOP: the fixture folder from T1 is missing"; return 1; }
  if [ -e "$f" ] || [ -L "$f" ]; then echo "P1 fixture already written"; return 0; fi
  grep -q '^badmodel=' "$run/canaries.txt" || echo "badmodel=RVBADMODEL$tok" >> "$run/canaries.txt"
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z); long=$(printf 'x%.0s' $(seq 1 120))
  for m in "claude-sonnet-4-5 RVBADMODEL$tok" "../RVBADMODEL$tok/model" "sk-ant-RVBADMODEL$tok" "claude-RVBADMODEL$tok$long" "claude-RVBADMODEL$tok"'\u0007'; do
    n=$((n + 1))
    printf '{"type":"assistant","timestamp":"%s","requestId":"req_rvid%s_p1_%d","message":{"id":"msg_rvid%s_p1_%d","model":"%s","usage":{"input_tokens":10,"output_tokens":5}}}\n' "$ts" "$tok" "$n" "$tok" "$n" "$m"
  done > "$f"
  grep -qxF "file=${f#"$HOME/.claude/projects/"}" "$mark" || echo "file=${f#"$HOME/.claude/projects/"}" >> "$mark"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) p1: 5 records, 75 tokens, all invalid model ids" >> "$run/log.txt"
  echo "OK: P1 fixture written and registered"
}
rv4_seed_log() {
  rv4_me || return 1
  if [ ! -e "$HLOG" ] && [ ! -L "$HLOG" ]; then
    mkdir -p "$HOME/Library/Logs" && printf 'rv4 synthetic existing hover log\n' > "$HLOG" && touch -t 202601010000 "$HLOG"
  fi
  [ -f "$HLOG" ] && [ ! -L "$HLOG" ] || { echo "STOP: no regular hover log to test against"; return 1; }
  rv4_log seeded
}
rv4_excl() {
  { for f in claude-ledger.key claude-ledger.json; do
      a=no; xattr -p com.apple.metadata:com_apple_backup_excludeItem "$APPSUP/$f" >/dev/null 2>&1 && a=yes
      echo "$f attr=$a inode=$(stat -f %i "$APPSUP/$f" 2>&1) tmutil=$(tmutil isexcluded "$APPSUP/$f" 2>&1 | awk '{print $1}')"
    done
    echo "folder tmutil=$(tmutil isexcluded "$APPSUP" 2>&1 | awk '{print $1}')"
    echo "control tmutil=$(tmutil isexcluded "$CONTROL" 2>&1 | awk '{print $1}')"
    echo "key sha256=$(shasum -a 256 "$APPSUP/claude-ledger.key" 2>&1 | cut -d' ' -f1)"
  } | tee "$(ev)/p4-${1:?label}.txt"; }
rv4_log() {
  { if [ -e "$HLOG" ] || [ -L "$HLOG" ]; then
      echo "present size=$(stat -f %z "$HLOG") mtime=$(stat -f %m "$HLOG") sha256=$(shasum -a 256 "$HLOG" | cut -d' ' -f1)"
    else echo "absent"; fi; } | tee "$(ev)/p2-${1:?label}.txt"; }
rv4_unknown() { echo "unknown# keys: $(grep -oE '"unknown#[0-9a-f]{32}"' "$APPSUP/claude-ledger.json" | sort -u | wc -l | tr -d ' ')" | tee "$(ev)/p1-${1:?label}.txt"; }
rv4_abort() {
  rv4_me || return 1
  pgrep -x SpanDeck >/dev/null && echo "Quit SpanDeck from its menu first, then run rv4_abort again" && return 1
  rv4_debughover off; rm -f "$CONTROL"; rv4_restore_log
  echo "debugHover removed, control removed. SpanDeck's state and fixtures are left for inspection; run \"\$RV\" clean to remove them, then rv4_restore_log."
}
echo "rv4 helpers defined"
fi
```
- **Read-only helpers:** `rv4_excl`, `rv4_log`, `rv4_unknown`. They write only to the evidence folder.
- **Helpers that change something** check the account first and return on any problem, touching only:
  - this run's P1 fixture and its registry line;
  - the control file;
  - the one `debugHover` key;
  - the seeded log, only if no log exists;
  - the restore, only if the log is absent.
- **Safe to re-run:**
  - `rv4_p1_fixture` writes and registers its fixture once;
  - `rv4_keep_log` never overwrites the keep copy;
  - `rv4_restore_log` never overwrites a log;
  - `rv4_control` and `rv4_seed_log` create only when absent.

## Procedure

### B1. Build account: stage the pre-#70 build
In your normal account, open Terminal, type `bash` and press Return, paste the build-account helpers (§B), then:
```bash
rv4_stage "$HOME/path/to/your/spandeck/checkout" 6ce1987
```
Replace the path with your checkout's. Expect `OK: staged 6ce1987…`. **Don't run B1 again after B2:** it would make `6ce1987` the staged build again. If that happens, `rv4_use` in T3 refuses to go on.

### T0. `spandecktest`: start from a clean SpanDeck state, keeping Headroom's state and any hover log
Open a Terminal in `spandecktest`, type `bash`, paste the helpers, then:
```bash
rv4_use 6ce1987
rv4_keep_log
"$RV" preflight
```
- **All `PASS`:** go on.
- **`FAIL` only on SpanDeck state, its preferences or old fixtures:**
  1. Run `"$RV" clean`, and answer `y` when it asks. It removes SpanDeck's state, this script's registered fixtures and the hover log. It keeps Headroom's state and the evidence. For Run 3's unregistered fixtures, run `"$RV" clean-fixtures-legacy`.
  2. Run `rv4_restore_log`.
  3. Run `"$RV" preflight` again. It must pass.
- **`FAIL` because SpanDeck is running:** quit it from its menu and run `preflight` again.
- **Any other `FAIL`:** stop.

Then:
```bash
"$RV" fingerprint start
rv4_log start
```
`fingerprint start` records both apps' files and preferences. Note whether the `[legacy]` entries exist. If they show only `absent`, Headroom's state isn't on this account. P3 is then checked only as "SpanDeck creates nothing under Headroom's names"; mark it **limited**. Repeating audit 0008's coexistence run is optional.

`rv4_log start` records `absent`, or the existing log's size, mtime and hash.

### T1. Fixtures and baseline
```bash
"$RV" fixtures 0
"$RV" identity
"$RV" completeness
"$RV" privacy
rv4_control
"$RV" capture before
```
Expected totals are what the script records in `log.txt`. The audit 0008 run, with the same four steps, showed **877 tokens: 867 `claude-sonnet-4-5` and 10 unpriced `claude-rvmodel…`**.

### T2. Pre-#70 build: create the existing cache and key
```bash
"$RV" launch 120 pre70
```
Wait until the menu bar shows the Claude total; the popover's totals should match T1. Quit from the app's menu, then:
```bash
"$RV" quit
"$RV" capture pre70
rv4_excl pre70
```
**Expected:**
- both files `attr=no tmutil=[Included]` (not yet excluded: the "before" state);
- `folder` and `control` are `[Included]`;
- `capture`'s canary lines are empty and `inspect_cache` reports `contains canary …: false` for every kind but `model`.

If `control` reads `[Excluded]`, mark P4's `tmutil` part inconclusive and go on with the xattr evidence.

### B2. Build account: stage the build under test
```bash
rv4_stage "$HOME/path/to/your/spandeck/checkout" 6e777c0
```
Expect `OK: staged 6e777c0…`. For a newer verified commit, use its SHA here and in T3.

### T3. `spandecktest`: switch to the new build, add the P1 fixture, set `debugHover`
```bash
rv4_use 6e777c0
rv4_p1_fixture
rv4_debughover on
rv4_log before-main
```
`rv4_use` checks four things and refuses to go on otherwise: the staged commit, the manifest hash, the bundle id and the quarantine attribute. The `gate` inside `launch` only checks that this run's preflight passed, so this check is what stops the wrong build from being launched.

**The P1 fixture** holds 5 assistant records, 10 input + 5 output tokens each. Every model id is invalid under #66 for a reason unrelated to the canary; all five were checked against `Ledger.modelID`:
1. a space;
2. a path;
3. an `sk-` prefix;
4. longer than 100 characters;
5. a control character.

### T4. `6e777c0`: existing install, replacement, P1 and P2 (absent case)
```bash
"$RV" launch 180 main
```
While it runs, after the totals appear:
- **P2 hover:** hover each menu-bar segment (CPU, GPU, memory, battery, Claude) for at least 3 seconds. Each shows its panel under the bar, positioned as before.
- **P1 UI:**
  - The model list shows `unknown` with **75** tokens and cost `n/a`, and `claude-rvmodel…` with 10 tokens and `n/a`.
  - The cost-coverage note lists `unknown` among the unpriced models.
  - No `RVBADMODEL` text anywhere in the popover, Settings or notes.
  - Take screenshots of the popover's model list and notes.
- **Totals:** 877 + 75 = **952 tokens** (867 `claude-sonnet-4-5`; 10 `claude-rvmodel…`; 75 `unknown`). Unpriced: 85.
- **Identity note:** its "Of N logged messages" count is **5 higher** than the `identity` line in `log.txt`, because the P1 records carry both ids. The completeness note doesn't change.

Quit from the app's menu, then:
```bash
"$RV" quit
"$RV" capture main
rv4_excl main
rv4_unknown main
rv4_log after-main
"$RV" fingerprint main
"$RV" compare start main
```
**Expected:**
- **P4:**
  - both files `attr=yes tmutil=[Excluded]`;
  - key `sha256` and `inode` **equal** `p4-pre70.txt`'s (marked in place, bytes unchanged);
  - cache `inode` **differs** from pre70's (the new data made a save replace it, and the replacement is excluded);
  - `folder` and `control` are `[Included]`.
- **P1:**
  - `unknown# keys: 5`;
  - `inspect_cache` reports `contains canary badmodel: false`;
  - `canaries.txt`'s `badmodel:` line is empty.
- **P2:** `after-main` equals `before-main`: `absent` if it was absent, otherwise the same size, mtime and hash.
- **P3:**
  - `compare start main` reports `legacy state unchanged`. Its SpanDeck line reports `CHANGED`, which is expected.
  - `new-files.txt` lists no new file with `Headroom` in its name.
- **Consent:**
  - `launch` records `claude.limits.enabled=absent grok.enabled=absent` (or `0`) for SpanDeck throughout;
  - 0 child processes and 0 socket lines;
  - `preferences.txt` shows `debugHover = 1` and no consent key set to 1.

### T5. Make sure an existing hover log is there for the next check
```bash
rv4_seed_log
```
If no log existed, this creates a synthetic one dated 2026-01-01; an existing log is left as it is. It must print `present …`; otherwise it prints `STOP`.

### T6. `6e777c0` again: quiet relaunch, P2 (existing case), then Clear
```bash
"$RV" launch 120 relaunch
```
Hover each segment again for at least 3 seconds. Quit from the app's menu, then:
```bash
"$RV" quit
rv4_excl relaunch
rv4_log after-relaunch
```
**Expected:**
- **P4:** key `sha256` and `inode` equal `p4-main.txt`'s, and both files are still `attr=yes [Excluded]`.
- **The cache inode is an observation, not a pass/fail:** the app saves only when something changed, but a refresh can still mark the cache dirty, and then a save replaces it.
- **P2:** `after-relaunch` equals `seeded`: same size, mtime and hash.

Then Clear:
```bash
"$RV" launch 120 clear
```
In Settings ▸ *Cached usage data* ▸ *Clear cached usage data…*, confirm. Wait until the totals are back at **952**; the next refresh re-indexes the fixtures. Quit from the app's menu, then:
```bash
"$RV" quit
"$RV" capture after-clear
rv4_excl after-clear
rv4_unknown after-clear
"$RV" fingerprint after-clear
"$RV" compare main after-clear
```
**Expected:**
- **P4:** both files `attr=yes tmutil=[Excluded]`, and the key `sha256` **differs** from `p4-relaunch.txt`'s (a new key after Clear).
- **P1:** `unknown# keys: 5` (opaque ids under the new key); no `badmodel` hit.
- **P3:** `legacy state unchanged`. The SpanDeck line reports `CHANGED`, which is expected.

### T7. Finish
```bash
rv4_debughover off
"$RV" snapshot
"$RV" summary
rm -f "$CONTROL"
```
- **Order:** `debugHover` comes off before `snapshot`, which also runs the debug binary. A debug build does honour `debugHover`.
- **`snapshot`** is a smoke check: the release app refuses `--snapshot` (exit 64, 0 files).
- **Left on purpose:**
  - SpanDeck's state and the fixtures, for inspection;
  - the seeded hover log;
  - `~/rv4-hover-log.keep`, until the report is accepted.
- **Removing them later:** run `"$RV" clean` (it deletes `SpanDeck-hover.log` too), then `rv4_restore_log`.

### If you abort
Quit SpanDeck from its menu, then run `rv4_abort`. It removes the one `debugHover` key and the control file, and restores the kept hover log only if the log is absent. Run `"$RV" clean` when you want SpanDeck's state and fixtures gone, then `rv4_restore_log` again. A new attempt starts at T0 with a new `preflight`.

## Report (post on #5: sanitized, no paths, hashes or tokens)
| ID | Check | Expected | Result |
|---|---|---|---|
| R4-0 | `preflight` (T0) all PASS; `rv4_use` OK for both builds | PASS | |
| R4-P1a | `unknown` row: 75 tokens, cost n/a; listed as unpriced; no false pricing | as stated | |
| R4-P1b | `badmodel` canary in cache, new files, screenshots | none | |
| R4-P1c | `unknown#` keys in cache (main, after-clear) | 5, 5 | |
| R4-P2a | Hover log with `debugHover` set, absent or existing case (T4) | unchanged (`absent` stays `absent`) | |
| R4-P2b | Hover log, existing case (T6) | size, mtime, hash equal to `seeded` | |
| R4-P2c | Hover panels appear and position as before | yes | |
| R4-P3 | `compare` start→main, main→after-clear: legacy | unchanged (or **limited**: no legacy state) | |
| R4-P4a | Pre-#70 files before 6e777c0 (T2) | attr=no, `[Included]` | |
| R4-P4b | Existing key and cache after load (T4) | attr=yes, `[Excluded]`; key hash same; key inode same | |
| R4-P4c | Cache replaced by a save (T4) | new inode, attr=yes, `[Excluded]` | |
| R4-P4d | Quiet relaunch (T6) | key unchanged; both still excluded (cache inode noted) | |
| R4-P4e | After Clear (T6) | new key hash; both attr=yes, `[Excluded]` | |
| R4-P4f | Control and folder verdicts | `[Included]` (else P4 `tmutil` part inconclusive) | |
| R4-C1 | Consent: SpanDeck keys absent/0 throughout; forks 0; socket lines 0 | as stated | |
| R4-C2 | Canary hits other than `model` in app-written files and screenshots | none | |
| R4-T | Totals main / after-clear | 952 / 952 | |

Add one line each for: the build SHAs (`6ce1987`, `6e777c0`), the macOS version, and any step that was inconclusive, with the reason.

## What this run can't show
- **That the release app never *opens* the hover log.** Opens can't be observed without root (`fs_usage`). The runtime evidence is that the log isn't created or changed. That the code can't open it rests on the build check (`scripts/check-hover-log-release.sh`: no `HoverDebugLog` symbols in the packaged binary, #68).
- **That `debugHover` was ever honoured.** P2 has no positive control: "unchanged" would also hold if hovering never reached a logger. The release binary has no logger to reach, so this run confirms behaviour; the gate itself is the build check.
- **What a real backup contains.** `tmutil isexcluded` reports Time Machine's verdict; no backup is made or inspected. Other backup and sync tools aren't covered. Earlier backups and snapshots aren't affected (audit 0007 §4).
- **An existing install from a real older release.** The "existing install" is `6ce1987`'s cache and key in a synthetic account.
- **Grok model ids.** P1's Grok path stays covered by `ModelIdentifierTests` only: both integrations stay off by design.
- **Some OS state:** crash reports, Spotlight, and the OS's own background files. The audit 0008 run saw Keychain and other system files change without attribution; the same applies here.
- **Monitor limits:** absence of network, child-process and log activity holds only within the monitor windows and filters.
- **Manual observations:** the hover and UI checks are manual and rest on the owner's observation and screenshots.
- **`tmutil` in a Standard account:** expected to work but not yet seen there. If it errors, the xattr evidence stands alone.
