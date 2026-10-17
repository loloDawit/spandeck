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
- **Only the dedicated Standard account `spandecktest`.** The build steps run in your normal account and launch nothing; every launch runs in `spandecktest`. `preflight` refuses any other account.
- **Synthetic data only**: the script's fixtures and the P1 fixture below. No real transcripts, credentials or provider accounts. Both consent switches stay off.
- **Nothing is deleted** except by the script's own `clean`, and only where this guide says so. `clean` removes `~/Library/Logs/SpanDeck-hover.log`, so step T0 copies it first and restores it.
- **Evidence** stays in `~/spandeck-rv-evidence/<run>/`, plus `summary`'s sanitized file. What goes to GitHub is the pass/fail table in §Report: no paths, no hashes (only *same*/*different*), no fixture token.
- **`tmutil isexcluded` under `/private/tmp` (or `$TMPDIR`) proves nothing:** Time Machine excludes those folders, so everything there reads `[Excluded]`. This guide checks only in `~/Library/Application Support`, against a control.

## Stop conditions
Stop, don't continue, and report it:
- **P0:** any canary other than `model` (`claude-rvmodel…`) in a file the app wrote (`capture`'s `canaries.txt`), in the usage cache (`inspect_cache` says `contains canary …: true`), or in a screenshot. **This includes `badmodel`.**
- `preflight` reports any `FAIL`.
- A consent value turns true, or `launch` reports child processes or socket lines.
- `SpanDeck-hover.log` appears, or its size, mtime or hash changes (P2 fail).
- `compare` reports `legacy state CHANGED` (P3 fail).
- The key's hash changes before Clear (P4 fail).

Recorded as **inconclusive**, without stopping the run:
- the control file reads `[Excluded]` (the location isn't eligible here);
- `tmutil` errors.

The xattr evidence still counts in both cases.

## Helpers (paste into the `spandecktest` shell once; read-only, they write only to the evidence folder)
```bash
APPSUP="$HOME/Library/Application Support/SpanDeck"
CONTROL="$HOME/Library/Application Support/spandeck-rv4-control.txt"
HLOG="$HOME/Library/Logs/SpanDeck-hover.log"
ev() { cat "$HOME/spandeck-rv-evidence/current"; }
# P4: attribute, inode, tmutil verdict for cache and key; folder and control verdicts; key hash (evidence only).
rv4_excl() {
  { for f in claude-ledger.key claude-ledger.json; do
      a=no; xattr -p com.apple.metadata:com_apple_backup_excludeItem "$APPSUP/$f" >/dev/null 2>&1 && a=yes
      echo "$f attr=$a inode=$(stat -f %i "$APPSUP/$f") tmutil=$(tmutil isexcluded "$APPSUP/$f" 2>&1 | awk '{print $1}')"
    done
    echo "folder tmutil=$(tmutil isexcluded "$APPSUP" 2>&1 | awk '{print $1}') (expect [Included]: the folder isn't marked)"
    echo "control tmutil=$(tmutil isexcluded "$CONTROL" 2>&1 | awk '{print $1}') (expect [Included])"
    echo "key sha256=$(shasum -a 256 "$APPSUP/claude-ledger.key" | cut -d' ' -f1)"
  } | tee "$(ev)/p4-$1.txt"; }
# P2: whether the hover log exists, and its size, mtime, inode and hash.
rv4_log() {
  { if [ -e "$HLOG" ] || [ -L "$HLOG" ]; then
      echo "present size=$(stat -f %z "$HLOG") mtime=$(stat -f %m "$HLOG") inode=$(stat -f %i "$HLOG") sha256=$(shasum -a 256 "$HLOG" | cut -d' ' -f1)"
    else echo "absent"; fi; } | tee "$(ev)/p2-$1.txt"; }
# P1: how many rejected-model keys the cache holds (a count only).
rv4_unknown() { echo "unknown# keys: $(grep -oE '"unknown#[0-9a-f]{32}"' "$APPSUP/claude-ledger.json" | sort -u | wc -l | tr -d ' ')" | tee "$(ev)/p1-$1.txt"; }
```

## Procedure

### B1. Build account: stage the pre-#70 build (launches nothing)
```bash
CHECKOUT=~/path/to/spandeck                     # set to your checkout
cd "$CHECKOUT" && git fetch origin && git switch main && git pull --ff-only   # at 6e777c0 or later
git status --porcelain --untracked-files=no      # must print nothing
WT=$(mktemp -d "${TMPDIR:-/tmp}/rv4-pre70.XXXXXX")
git worktree add --detach "$WT" 6ce1987
"$WT/scripts/runtime-verify.sh" stage            # builds 6ce1987's release + debug and stages them; prints the manifest
git worktree remove --force "$WT"
cat /Users/Shared/spandeck-rv/current            # expect 6ce1987…
```
The script is unchanged between `6ce1987` and `6e777c0`, so the staged copy behaves the same in both phases.

### T0. `spandecktest`: start from a clean SpanDeck state, keeping Headroom's and any hover log
```bash
RV=/Users/Shared/spandeck-rv/$(cat /Users/Shared/spandeck-rv/current)/runtime-verify.sh
# Keep any existing hover log (clean would delete it).
[ -e "$HOME/Library/Logs/SpanDeck-hover.log" ] && cp -p "$HOME/Library/Logs/SpanDeck-hover.log" "$HOME/rv4-hover-log.keep"
"$RV" preflight
```
- **All `PASS`:** go to T1.
- **`FAIL` on SpanDeck state, preferences or old fixtures:**
  1. Run `"$RV" clean`. It removes SpanDeck's state and this script's registered fixtures, and keeps Headroom's state and the evidence. For Run 3's unregistered fixtures, use `"$RV" clean-fixtures-legacy`.
  2. Restore the log, if one was kept: `[ -e "$HOME/rv4-hover-log.keep" ] && cp -p "$HOME/rv4-hover-log.keep" "$HOME/Library/Logs/SpanDeck-hover.log"`.
  3. Run `"$RV" preflight` again. It must pass.
- **Any other `FAIL`:** stop.

Then paste the helpers above, and run:
```bash
"$RV" fingerprint start            # both apps' files and preferences; note whether [legacy] entries exist
rv4_log start                      # "absent", or the kept log's size/mtime/hash
```
If `[legacy]` shows only `absent`, Headroom's state isn't on this account, and P3 is checked only as "SpanDeck creates nothing under Headroom's names". Mark it **limited**. Repeating audit 0008's coexistence run (`stage-legacy`, `legacy-launch`) is optional.

### T1. Fixtures and baseline
```bash
"$RV" fixtures 0 && "$RV" identity && "$RV" completeness && "$RV" privacy
printf 'rv4 control, synthetic\n' > "$CONTROL"
"$RV" capture before
```
Expected totals are what the script records in `log.txt`. The audit 0008 run, with the same four steps, showed **877 tokens: 867 `claude-sonnet-4-5` and 10 unpriced `claude-rvmodel…`**.

### T2. Pre-#70 build: create the existing cache and key
```bash
"$RV" launch 120 pre70
```
- Wait until the menu bar shows the Claude total. The popover's totals should match T1.
- Quit from the app's menu, then run:
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

### B2. Build account: stage `6e777c0`
```bash
cd "$CHECKOUT" && git rev-parse --short HEAD   # 6e777c0 (or the newer verified commit)
scripts/runtime-verify.sh stage
cat /Users/Shared/spandeck-rv/current                        # expect 6e777c0…
```

### T3. `spandecktest`: check the new staging, then add the P1 fixture and set `debugHover`
```bash
SHA=$(cat /Users/Shared/spandeck-rv/current); D=/Users/Shared/spandeck-rv/$SHA
[ "$(awk '/^release sha256:/{print $3}' "$D/manifest.txt")" = "$(shasum -a 256 "$D/SpanDeck.app/Contents/MacOS/SpanDeck" | cut -d' ' -f1)" ] && echo "manifest OK" || echo "STOP: manifest mismatch"
xattr -r "$D/SpanDeck.app" | grep -q com.apple.quarantine && echo "STOP: quarantined" || echo "not quarantined"
RV=$D/runtime-verify.sh
```
**P1 fixture**: 5 assistant records, 10 input + 5 output tokens each. Every model id is invalid under #66 for a reason unrelated to the canary:
1. a space;
2. a path;
3. an `sk-` prefix;
4. longer than 100 characters;
5. a control character.
```bash
RUN=$(ev); TOK=$(sed -n 's/^id=rvid//p' "$RUN/canaries.txt"); MARK="$HOME/.claude/projects/.spandeck-rv-fixtures"
[ "$(sed -n 's/^run=//p' "$MARK" | head -1)" = "$(basename "$RUN")" ] || echo "STOP: the fixture marker isn't this run's"
DIR="$HOME/.claude/projects/-Users-$(id -un)-rvpath$TOK"; F="$DIR/rvid$TOK-p1models.jsonl"
[ -d "$DIR" ] && [ ! -L "$DIR" ] || echo "STOP: the fixture folder from T1 is missing"
grep -q '^badmodel=' "$RUN/canaries.txt" || echo "badmodel=RVBADMODEL$TOK" >> "$RUN/canaries.txt"
TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z); LONG=$(printf 'x%.0s' $(seq 1 120)); n=0
for m in "claude-sonnet-4-5 RVBADMODEL$TOK" "../RVBADMODEL$TOK/model" "sk-ant-RVBADMODEL$TOK" "claude-RVBADMODEL$TOK$LONG" "claude-RVBADMODEL$TOK"'\u0007'; do
  n=$((n + 1))
  printf '{"type":"assistant","timestamp":"%s","requestId":"req_rvid%s_p1_%d","message":{"id":"msg_rvid%s_p1_%d","model":"%s","usage":{"input_tokens":10,"output_tokens":5}}}\n' "$TS" "$TOK" "$n" "$TOK" "$n" "$m"
done > "$F"
echo "file=${F#"$HOME/.claude/projects/"}" >> "$MARK"     # registered, so clean removes it and the next preflight doesn't trip
echo "p1: 5 records, 75 tokens, all invalid model ids" >> "$RUN/log.txt"
```
**P2: set the hidden preference** (the release build must ignore it):
```bash
defaults write io.github.lolodawit.SpanDeck debugHover -bool true
rv4_log before-main
```

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

Quit from the app's menu, then:
```bash
"$RV" quit
"$RV" capture main
rv4_excl main; rv4_unknown main; rv4_log after-main
"$RV" fingerprint main; "$RV" compare start main
```
**Expected:**
- **P4:**
  - both files `attr=yes tmutil=[Excluded]`;
  - key `sha256` **equals** `p4-pre70.txt`'s;
  - key `inode` equals pre70's (marked in place);
  - cache `inode` **differs** from pre70's (the new data made a save replace it, and the replacement is excluded);
  - `folder` and `control` are `[Included]`.
- **P1:**
  - `unknown# keys: 5`;
  - `inspect_cache` reports `contains canary badmodel: false`;
  - `canaries.txt`'s `badmodel:` line is empty.
- **P2:** `after-main` equals `before-main`: `absent` if it was absent, otherwise the same size, mtime and hash.
- **P3:** `compare start main` reports `legacy state unchanged`. `new-files.txt` lists no new file with `Headroom` in its name.
- **Consent:**
  - `launch` records `claude.limits.enabled=absent grok.enabled=absent` (or `0`) for SpanDeck throughout;
  - 0 child processes and 0 socket lines;
  - `preferences.txt` shows `debugHover = 1` and no consent key set to 1.

### T5. Seed an existing hover log (only if it was absent)
```bash
[ -e "$HLOG" ] || { printf 'rv4 synthetic existing hover log\n' > "$HLOG"; touch -t 202601010000 "$HLOG"; }
rv4_log seeded
```

### T6. `6e777c0` again: quiet relaunch, P2 (existing case), Clear
```bash
"$RV" launch 120 relaunch
```
While it runs:
1. **Hover** each segment again for at least 3 seconds.
2. **Quiet relaunch:** run `rv4_excl relaunch`. Expect the same key hash and the same cache inode as `p4-main.txt` (no new data, so no rewrite), with both still `attr=yes [Excluded]`.
3. **Clear:** Settings ▸ *Cached usage data* ▸ *Clear cached usage data…* ▸ confirm. Wait until the totals are back at **952**; the next refresh re-indexes the fixtures.
4. Quit from the app's menu.

Then:
```bash
"$RV" quit
"$RV" capture after-clear
rv4_excl after-clear; rv4_unknown after-clear; rv4_log after-relaunch
"$RV" fingerprint after-clear; "$RV" compare main after-clear
```
**Expected:**
- **P4:** both files `attr=yes tmutil=[Excluded]`, and the key `sha256` **differs** from `p4-relaunch.txt`'s (a new key after Clear).
- **P1:** `unknown# keys: 5` (opaque ids under the new key); no `badmodel` hit.
- **P2:** `after-relaunch` equals `seeded`: same size, mtime and hash.
- **P3:** `legacy state unchanged`.

### T7. Finish
```bash
defaults delete io.github.lolodawit.SpanDeck debugHover
"$RV" snapshot          # smoke: the release app refuses --snapshot (exit 64, 0 files)
"$RV" summary           # sanitized results file in /Users/Shared/spandeck-rv-results
rm -f "$CONTROL"
```
- Don't run `clean` afterwards unless you mean to: it deletes `SpanDeck-hover.log`, including the seeded one.
- Keep `~/rv4-hover-log.keep` until the report is accepted.

## Report (post on #5: sanitized, no paths, hashes or tokens)
| ID | Check | Expected | Result |
|---|---|---|---|
| R4-0 | `preflight` (T0) all PASS; staged manifests match (B1, T3) | PASS | |
| R4-P1a | `unknown` row: 75 tokens, cost n/a; listed as unpriced; no false pricing | as stated | |
| R4-P1b | `badmodel` canary in cache, new files, screenshots | none | |
| R4-P1c | `unknown#` keys in cache (main, after-clear) | 5, 5 | |
| R4-P2a | Hover log with `debugHover` set, absent case (T4) | stays absent | |
| R4-P2b | Hover log, existing case (T6) | size, mtime, hash unchanged | |
| R4-P2c | Hover panels appear and position as before | yes | |
| R4-P3 | `compare` start→main, main→after-clear: legacy | unchanged (or **limited**: no legacy state) | |
| R4-P4a | Pre-#70 files before 6e777c0 (T2) | attr=no, `[Included]` | |
| R4-P4b | Existing key and cache after load (T4) | attr=yes, `[Excluded]`; key hash same; key inode same | |
| R4-P4c | Cache replaced by a save (T4) | new inode, attr=yes, `[Excluded]` | |
| R4-P4d | Quiet relaunch (T6) | unchanged, still excluded | |
| R4-P4e | After Clear (T6) | new key hash; both attr=yes, `[Excluded]` | |
| R4-P4f | Control and folder verdicts | `[Included]` (else P4 `tmutil` part inconclusive) | |
| R4-C1 | Consent: SpanDeck keys absent/0 throughout; forks 0; socket lines 0 | as stated | |
| R4-C2 | Canary hits other than `model` in app-written files and screenshots | none | |
| R4-T | Totals main / after-clear | 952 / 952 | |

Add one line each for: the build SHAs (`6ce1987`, `6e777c0`), the macOS version, and any step that was inconclusive, with the reason.

## What this run can't show
- **That the release app never *opens* the hover log.** Opens can't be observed without root (`fs_usage`). The runtime evidence is that the log isn't created or changed. That the code can't open it rests on the build check (`scripts/check-hover-log-release.sh`: no `HoverDebugLog` symbols in the packaged binary, #68).
- **What a real backup contains.** `tmutil isexcluded` reports Time Machine's verdict; no backup is made or inspected. Other backup and sync tools aren't covered. Earlier backups and snapshots aren't affected (audit 0007 §4).
- **An existing install from a real older release.** The "existing install" is `6ce1987`'s cache and key in a synthetic account.
- **Grok model ids.** P1's Grok path stays covered by `ModelIdentifierTests` only: both integrations stay off by design.
- **Some OS state:** crash reports, Spotlight, and the OS's own background files. The audit 0008 run saw Keychain and other system files change without attribution; the same applies here.
- **Monitor limits:** absence of network, child-process and log activity holds only within the monitor windows and filters.
- **Manual observations:** the hover and UI checks are manual and rest on the owner's observation and screenshots.
