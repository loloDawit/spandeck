# Running the private-use validation (#94)

This guide runs [`VALIDATION.md`](VALIDATION.md) §2, steps A–C, on the real app inside the dedicated test account. It uses two scripts:

| Script | Where it runs | What it does |
|---|---|---|
| `scripts/validation/stage.sh` | your normal account | Checks the candidate DMG against the SHA-256 you give it. Builds the small fork monitor (`procwatch`). Copies the package to `/Users/Shared/spandeck-validation/<commit>/`. Launches nothing and reads no transcripts or credentials. |
| `validate.sh` (in the package) | `spandecktest` only | The isolation gate first. Then a guided run of A–C on synthetic data, with measurements, the report, and cleanup of its own artifacts. |

`validate.sh` never needs `sudo`, never changes your main account, and never enables an integration or creates a credential. It never clicks for you, so it needs no Accessibility or Automation permission. You do the clicks, and it measures and checks what happened. Allow about 30–40 minutes.

## What it checks
**P. Isolation and package gate.** If any check fails, nothing is installed or launched.
- **The test account:**
  - you are `spandecktest`, which is not an admin;
  - `HOME` is the account's real home;
  - the main account is a different user.
- **The main account is unreachable:** its home can't be listed or traversed, and none of its Claude, Codex, Grok, Keychain, preferences or SpanDeck paths is readable.
- **No redirects:**
  - no shell or launchd environment variable points outside this home (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `XDG_*`, `CFFIXED_USER_HOME`, `HOME`, `GROK_HOME`);
  - no symlink anywhere in this home points into the main account;
  - none of the paths SpanDeck uses is a link.
- **Keychain:** this account's keychains are its own, and there's no Claude Code item (attributes only, never a secret).
- **No credentials:** no Claude, Grok or Codex credential or CLI is present.
- **A clean slate:** no SpanDeck process, state, preferences or app copy in this account.
  - Leftover SpanDeck state wasn't created by this tool, so it stops the run and is never deleted by it. Remove it by hand: see *Leftover state* below.
  - Leftover `~/.claude/projects` or `~/.grok` entries stop the run unless you pass `--park-existing`, which sets them aside and puts them back at cleanup.
- **Free disk space:** at least about 3 GB. Each large batch is about 300 MB, and there can be up to 3.
- **The package:**
  - the DMG's SHA-256 equals the value **you type** from the #94 report;
  - `SHA256SUMS` and `PACKAGE.sha256` verify;
  - there's no quarantine attribute;
  - every package file is a plain file owned by your staging account.
- **Login Items:** SpanDeck isn't listed in Login Items. This is your observation.

**A. Install and default launch**
- The app is copied from the read-only mounted DMG to `~/Applications/SpanDeck.app`, and the executable's SHA-256 must match `PROVENANCE.txt`.
- The first launch is watched for 60 s. Expected:
  - 0 child processes (kernel fork monitor);
  - 0 network sockets (`lsof` every 2 s);
  - no `security` or `grok` process;
  - consent switches absent or off.
- The files changed in the home during launch are listed.
- **Your checks:**
  - no Keychain or permission dialog;
  - "No Claude Code transcripts found…" instead of 0 / $0.00;
  - plan limits off.

**B. Everyday use**
- **B5, diagnostics:** you start a session in the app. The script checks that `diagnostics.json` appears with mode `0600`, and you confirm the disclosure.
- **B2, refresh:** synthetic fixtures are added: Claude 610 tokens with one unpriced model, and Grok 300 tokens. You confirm the totals, the "Claude + Grok" header and the unpriced note. Then 10 messages are appended, and you confirm the total grows once, to 910.
- **B1, popover:** you open and close the popover 10 times and confirm there's no visible hitch. The app's own diagnostics measure each open.
- **B3, quit during indexing:** first a normal quit. Then, with SpanDeck quit, a large synthetic batch is written (5,000 files × 40 messages by default) and SpanDeck is relaunched. With the popover open, you press Return and click Quit while the footer shows "Indexing Claude logs n/N"; you get up to 3 tries. The app's own quit time (request to reply, from diagnostics) must be within its 5 s cap. After the relaunch, you confirm the totals, and the script checks that the usage cache holds **exactly** the expected token count, with no path, transcript text or message id.
- **B4, corrupt cache:** the cache is overwritten with garbage while SpanDeck is quit. After the relaunch you confirm the totals are rebuilt, and the final cache is version 7 with the exact count.
- **B5, export:** you export diagnostics into the run folder. The script checks:
  - there's no path, user name, canary or model name;
  - only the documented keys appear;
  - these events are present: `launch`, `firstUsage`, `popoverOpen`, `refresh`, `cacheSave`, `shutdown`, `sessionResume` and `process`.

  You then Stop and Delete, and the script checks the file is gone.
- **B6, VoiceOver:** optional, with a skip option.

**C. Integrations**
- **Launch at login:** turn it on and off, confirming in System Settings each time.
- **After the final quit, across every launch:**
  - 0 child processes, 0 sockets, 0 `security` or `grok` processes;
  - consent never given;
  - no credential created.

**Report.** Written to `~/spandeck-validation/<run>/report.md`, with a copy in `/Users/Shared/spandeck-validation-results/`. It contains:
- a PASS/FAIL/SKIP/INFO table;
- diagnostics statistics: median, p95 and max per kind;
- CPU and RSS per launch;
- the changed files (names only);
- the log.

Paths are shown as `~`, and account names are replaced. Screenshots, if you choose `--screenshots`, stay in the run folder until you decide to share them.

## Commands

### 1. In your normal account
After the permission change you're making:
```bash
cd ~/Desktop/project/spandeck
git fetch origin && git switch validation/94-package      # the reviewed package (or main once it's merged)
ls build/candidate/957a441/                                # the candidate from the #94 report; if missing:
#   git switch --detach 957a441 && scripts/package-candidate.sh && git switch -
scripts/validation/stage.sh 957a441 c6f9f3a9ce797f358121776fc1fae555020760e91e5f10a6121eb0b574c07e2a
```
- **Note the `validate.sh SHA-256` it prints.** Check it matches `shasum -a 256 scripts/validation/validate.sh` of the version you reviewed.
- **To restage:** first `rm -rf /Users/Shared/spandeck-validation/957a441`.

### 2. Log in as `spandecktest`
Use fast user switching. In Terminal:
```bash
ls /Users/<your-main-user>               # must say: Permission denied
cd /Users/Shared/spandeck-validation/957a441
shasum -a 256 validate.sh                # same value as step 1
./validate.sh run                        # add --park-existing if ~/.claude or ~/.grok exists; --screenshots for captures
```
- **When asked for the DMG SHA-256:** type `c6f9f3a9ce797f358121776fc1fae555020760e91e5f10a6121eb0b574c07e2a` from the #94 report. Don't copy it from the staged folder.
- **Then:** follow the prompts. Answer `y` or `n` honestly; a `n` asks for one line describing what you saw. Don't enable Claude plan limits or Grok credits when the app offers them.
- **For clean "Today" checks:** avoid starting within an hour of local midnight.

### 3. When it finishes
Still in `spandecktest`:
```bash
./validate.sh cleanup        # removes this run's app copy, the SpanDeck state it created, and its fixtures; restores parked folders; keeps evidence
```
If the run stops part-way, or you press Ctrl-C, run `./validate.sh cleanup` too. Background monitors stop on their own. `./validate.sh report` rebuilds the report of the last run.

**Leftover state.** This is only needed if the gate reports `P5.clean-slate`. It's state from an earlier run that this tool didn't create. Remove it in `spandecktest` with SpanDeck quit:
```bash
rm -rf ~/Applications/SpanDeck.app "$HOME/Library/Application Support/SpanDeck"
defaults delete io.github.lolodawit.SpanDeck
```

### 4. Back in your normal account
The report is in `/Users/Shared/spandeck-validation-results/report-<run>.md`. Tell me its path, or paste it. Screenshots stay in the test account's `~/spandeck-validation/<run>/screenshots/`.

## What it can't show
- **Drawing and click-to-content time:** these aren't measured. `popoverOpen` runs from the click to main-thread idle. Your y/n answers cover what you see.
- **File reads:** reads can't be observed without root, so "never reads the main account" rests on that account being unreachable (gate P2).
- **System log:** `log stream` may be unavailable to a Standard account. That check is then INFO, and the kernel fork monitor still covers child processes.
- **macOS's own background writes** appear in the changed-files list. They're listed, not attributed.
- **Grok** only has local usage files. Its credits integration, like Claude's plan limits, stays off: V16 is unverified by your rule.
