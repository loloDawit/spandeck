# Local usage cache: what is stored, and why (R8, #33)

SpanDeck counts Claude Code token usage by reading the transcripts in `~/.claude/projects` and `~/.config/claude/projects`. Re-reading every transcript on every launch would be slow, so it keeps an incremental index. This page describes that index as of R8, with schema version 7 (#55, #58, #57). Storing data locally does not by itself make it private: any process running as your user can read your user's files.

## Files
All in `~/Library/Application Support/SpanDeck/` since #11 (SpanDeck's own identity, from `Resources/identity.env`). Builds before #11 used `~/Library/Application Support/Headroom/`, the folder upstream Headroom uses. SpanDeck never opens, reads, imports, renames or deletes anything there (see *Separate from Headroom* below).

| File | Contents | Mode |
|---|---|---|
| (folder) | — | `0700`, checked and tightened before every cache write. Parent folders are never changed. |
| `claude-ledger.json` | Usage index, schema version 7 | `0600` |
| `claude-ledger.key` | 32 random bytes: the key for the opaque ids below | `0600` |
| `.claude-ledger.*.tmp-*` | Only while a save is in progress | created `0600` |
| `pricing-source.json`, `pricing.json` | Public price data (R6); not part of the usage cache | not changed by R8 |

Writes create a temporary file `0600` before writing any data to it (`O_CREAT|O_EXCL|O_NOFOLLOW`), then rename it over the old file. Files are read without following symlinks. The folder must be a real folder owned by you. If it is a symlink, isn't a folder, belongs to someone else, or can't be set to `0700`, then:
- the cache is not written, neither there nor anywhere else;
- usage is counted in memory only;
- Settings ▸ Cached usage data shows the reason.

## What the index holds
| Field | Persisted as | Why it's kept |
|---|---|---|
| `files` | opaque file id → byte offset; since #56 also the file's size when last looked at (`size`), a keyed id of its change time (`stamp`) and a keyed id of sampled bytes before the offset (`anchor`: the first and the last 4 KiB and 16 evenly spaced 4 KiB windows between them) | Read only what was appended to each transcript, and read one rewritten in place again from the start (#56; see the limit below). The stamp is only compared, so no precise time is stored |
| `seen` | opaque operation id → slot, token counts per model, how it was identified, and whether it was counted with an invalid counter (#58, only when it was) | Count a streamed message once as it grows, and a message repeated in a resumed session once |
| `links` | opaque single id → opaque operation id (or `ambiguous`) + slot | Join a record that has only a message id or only a request id to the one pair that carries it (#55) |
| `slots` | 15-minute UTC slot (#57) → model → token counts. Only where P9 applies (#58), also cache-write tokens whose tier is unresolved and tokens disputed between a flat total and its breakdown | Totals, windows and cost estimates. Each operation's counts in `seen` carry the same fields, so a #55 merge or a held (`Int.max`) sum can be rebuilt from them |
| `identity` | slot → number of identity groups (logged messages with their streamed copies) identified by both ids, one id, a fingerprint, or an ambiguous id | The "Usage may be approximate" note (#55) |
| `flawed` | slot → number of identity groups counted with an invalid counter left out | The "Some usage records couldn't be read" note (#58) |
| `unread` | opaque line id → kind (`invalidUsage`, `undated` or `malformed`) + slot | Report a record that couldn't be read, once however often it is read again (#58). Identical broken lines, in one file or several, are one entry, so the count is of distinct lines, not of occurrences. The hour is the record's own for `invalidUsage`; for the others it is the hour the line was found, used only for pruning |
| `version` | `7` | A different version is never loaded |
| `keyCheck` | opaque id of a fixed input under the key | The cache is loaded only with the key it was written under. Otherwise, for example with an old cache restored from a backup after a clear made a new key, every id would miss and everything would be counted twice; such a cache is deleted and rebuilt |

**Not stored:**
- transcript paths, project folder names or your user name;
- message ids or request ids;
- prompts, responses, code, tool arguments or tool output;
- any part of a line that couldn't be read (#58): only its opaque id and kind.

Which transcripts end in an unfinished line (#58) is kept in memory only. Every such file is read again on the first full scan after a launch, because its saved offset is short of its size.

Only lines with a `"usage"` key (with any JSON whitespace before its colon) are parsed. The parser reads each assistant line's `message.model`, `message.usage`, `message.id`, `requestId` and `timestamp`. The line is parsed as a whole, but nothing else from it is kept. Paths stay in memory only, for opening the files. Grok session files are listed every refresh, read again when they change, and never cached; their model ids are shown in the UI and never written. Model names and token counts are shown in the UI. Model ids are validated first (#66, below): one that isn't shaped like a provider's is counted, cached and shown as `unknown`. Nothing from transcripts is logged: the app's only `NSLog` reports a login-item error. One more file can be written outside this folder: with the hidden preference `debugHover` set (release builds included), `~/Library/Logs/SpanDeck-hover.log` (`Headroom-hover.log` before #11) records hover-panel geometry and timestamps, no usage data; *Clear cached usage data* doesn't remove it (#5, audit 0007 finding P2).

A field-level inventory of everything read, kept in memory, written and shown, and a check of each statement on this page against the code, is in [audit 0007](audits/0007-privacy-verification.md).

## Model ids (#66)
Model ids come from files SpanDeck doesn't control: Claude's `message.model` and `usage.iterations[].model`, and Grok's `primaryModelId`. An id is kept as written only when all of these hold:
- 1 to 100 characters, each `A-Z`, `a-z`, `0-9`, `.`, `:`, `@` or `-`;
- it starts with a letter;
- no run of letters and digits is longer than 32 characters;
- it doesn't start with `sk-` or `xai-` (in any case), `AKIA` or `ASIA`.

That covers every id SpanDeck prices or has fixtures for: first-party ids (`claude-sonnet-4-5`), dated ids (`claude-haiku-4-5-20251001`), Bedrock ids (`us.anthropic.claude-sonnet-4-5-20250929-v1:0`), Vertex ids (`claude-opus-4-5@20251101`) and Grok's (`grok-4.6-build`). `/` and `_` aren't allowed. No supported id uses them, and they would let paths, ARNs (`…/profile-id`) and most token formats (`ghp_…`, `github_pat_…`) through.

Any other id (text with spaces, control or non-ASCII characters, a path, an over-long string, a credential-shaped value) is shown as `unknown`, with all its tokens. Its cost is unknown, as for any unpriced model. A missing Claude id is `unknown` and a missing Grok id is `grok`, as before. Before validation:
- a `<synthetic>` record is still recognised and skipped;
- an iteration is still compared with its message's model as written. A sub-call of another rejected id is still an extra operation.

**Kept apart, shown together (Claude).** In the cache, each rejected Claude id is kept under its own key: `unknown#` followed by `HMAC-SHA256(key, "model" | the id)`, truncated like every opaque id below. Streamed copies of a message are reconciled one model at a time, keeping each counter's largest value (#58). Merging rejected ids into one key before that step would lose counts: two copies whose sub-calls move from 50 and 10 output tokens to 10 and 50 would keep 60 instead of 100. These keys, a missing model's `unknown` and a literal `unknown` stay separate. They are added together only for totals, the model list, cost notes and the chart. `#` never passes the policy, so no transcript id has this form. Grok turns aren't reconciled per model (a copy of a turn counts whole, once), and Grok usage is never cached, so a rejected Grok id simply becomes `unknown`.

One label changes: an iteration (sub-call) whose model is `<synthetic>` used to get its own `<synthetic>` row. It is now counted under `unknown`, with the same tokens. None of the fixtures has one.

A fingerprint still hashes the id as written (keyed, never stored), so dedupe keys don't change.

**Limits:**
- This bounds the shape of what is stored and shown. It can't tell a secret that looks like a model id (letters, digits and hyphens, short runs) from a real id, so it doesn't guarantee that no sensitive string is ever stored.
- Ids that Claude Code might write with other characters (for example a `[1m]` suffix) would show as `unknown`. [assumption: the API's response model, which transcripts record, never carries that suffix; not verified against real transcripts]

**Caches written before #66** (still version 7) can hold any id, in `slots` and in each operation's counts in `seen`. At load, each rejected id in either is moved to its `unknown#…` key, which is the key the same records get when they're read now. A key that starts with `unknown#` but isn't followed by an opaque id is treated as a raw id. The cache is saved without the raw ids on the next refresh, which is the first one after launch. Totals, buckets, deduplication and identity counts are unchanged, and so is per-model reconciliation. A later streamed copy of an operation counted before the upgrade adds only its growth per model. A transcript read again later (a rewrite, a re-scan, an append) adds nothing that was counted already. There is no version change, no re-index and no history lost. The raw ids can remain in earlier copies of the file, as for anything else (see *Backups and erasure*).

## Opaque ids and their limits
Each id is one of:
- `HMAC-SHA256(key, "file" | path)`;
- `HMAC-SHA256(key, "message" | message id | request id)` for a record with both ids;
- `HMAC-SHA256(key, "message-only" | message id)` or `HMAC-SHA256(key, "request-only" | request id)` for a record with one (#55);
- `HMAC-SHA256(key, "model" | model id)` after `unknown#`, for a Claude model id that fails the policy (#66);
- `HMAC-SHA256(key, "unread" | the line's bytes)` for a line that couldn't be read (#58). The same bytes give the same id in any file, so a rescan, rewrite, rename or copy reports it once;
- `HMAC-SHA256(key, "fingerprint" | time | model | each usage counter …)` for a record with neither. The time is the instant as parsed, in milliseconds since 1970, so `Z`, `+00:00`, other offsets and trailing fractional zeros don't matter. Two records whose times differ by less than a millisecond get the same time. The model is used as written. Every counter the ledger reads (including the cache breakdown and iterations) follows in a fixed order, each as absent, its numeric value (`50`, `50.0` and `5e1` are the same) or something else. No path or offset is in it.

In every case:
- every part is length-prefixed;
- the result is truncated to 128 bits and written as hex;
- the key is generated with CryptoKit on first save and never leaves the machine (no Keychain, no credential store, no network).

What this protects against: someone who gets only the cache file can't read your paths or ids from it. Without the key, they also can't confirm a guess such as "is this project in it?" Ids also can't be matched across installs.

What it doesn't protect against:
- The key sits next to the cache, so anyone who can read both (any process running as you, or a backup containing both: one made before #70, or by a tool that ignores the backup-exclusion attribute) can test guesses. A path or id with little randomness can then be confirmed by trying candidates.
- Time buckets (15-minute UTC slots since #57), models and token counts are stored in the clear. They show when, to the quarter hour, and how much you used each model over the last 32 days.
- A fingerprint covers only a timestamp, a model name and token counts. Someone with the key who can guess all of those for a record can confirm it.
- A file's anchor covers up to 18 windows of 4 KiB before its saved offset (#56). Someone with the key who can guess the exact bytes of all of them can confirm them. They learn nothing about bytes they can't guess.
- An unread line's id covers the whole line. Someone with the key who can guess the exact bytes of a broken line can confirm it was in a transcript. They learn nothing about lines they can't guess.

## Retention
- Transcripts last modified more than 32 days ago are skipped.
- Time buckets, operation ids, single-id links, identity counts, flaw counts and unread lines older than 32 days are pruned at each full scan (every 5 minutes while running). An unread line without a usable timestamp is pruned 32 days after it was found.
- Unread lines stay counted when their transcript is deleted or rewritten without them, like usage already counted: the totals still lack them. A cleared cache only reports what is still on disk.
- A transcript that disappears is dropped from `files`.
- The cache is saved at most every 10 minutes, and again on quit.
- **Claude Code's own cleanup [doc, not runtime-verified]:**
  - Claude Code deletes transcripts, and their subagent transcripts, once they're older than its `cleanupPeriodDays` setting, **30 days by default**. Claude Desktop and Cowork transcripts follow their own rule (`desktopSessionCleanupPeriodDays`).
  - Sources: Claude Code docs, *sessions › Where transcripts are stored* and *.claude directory › cleaned up automatically*, retrieved 2026-10-18 ([audit 0010](audits/0010-claude-observability-surfaces.md) §2.1). The docs don't say whether "older" means last modified or created.
  - **While the cache is intact,** usage SpanDeck already counted stays for the full 32 days, even after Claude Code deletes the transcript.
  - **After a rebuild** (a version change, a cleared cache, a lost key or a restored backup), only transcripts still on disk are re-read. With the default setting, the oldest days of the 32-day window, roughly days 31–32, can come back lower than before or empty. Days 31–32 can come back complete only if `cleanupPeriodDays` is above 32. A lower setting makes the gap larger.
  - This is the history loss P12 already accepts. SpanDeck never reads or changes Claude Code's settings to work around it.

## Upgrading from a version 3 cache
Version 3 stored raw paths and ids, and SpanDeck doesn't try to convert them. When it finds a version 3 cache, it deletes it before reading anything else and re-indexes the transcripts still on disk. That's a one-time full read, after which totals and deduplication are the same as before. The same happens to:
- a corrupt cache;
- a cache whose key is missing or different;
- a symlink at the cache path (the link is removed, never its target);
- leftover temporary files.

If the old file can't be deleted, Settings says so. Usage from transcripts that are gone, or older than 32 days, can't be rebuilt. Transcripts are never modified.

## Upgrading from a version 4 cache (#55)
Version 4 counted every record without ids each time it was read, and treated empty ids as one shared id. Its totals can't be separated from those errors, and its opaque ids don't say which kind of record they came from, so it can't be converted. A version 4 cache is deleted when found, before anything else is read, and the transcripts still on disk are re-indexed under the existing key. Old and new totals are never mixed: one file holds one version.

What users will notice:
- **One-time re-index** on the first launch after the upgrade.
- **Lost history:** usage whose transcripts have since been deleted or rotated away can't be rebuilt, so it disappears from the totals, permanently. Transcripts not modified in 32 days are skipped, as always.
- **Lower totals** where records without ids or with empty ids were inflated or merged before: they are now counted once each, and the totals say they may be approximate.

Interruptions: if the app stops after deleting the old cache but before saving the new one, the next launch finds no cache and indexes again. If the cache folder can't be made owner-only, nothing is read or deleted, and the old cache waits for the next launch. No backup of the version 4 file is kept.

## Upgrading from a version 5 cache (#58)
Version 5 subtracted negative counters, dropped a cache-write breakdown that came without a flat total, and never parsed `"usage": {` written with a space. Its offsets are already past those lines, so they would never be read again, and it kept no record of lines it couldn't read. Its totals can't be corrected in place. A version 5 cache is deleted when found, exactly as a version 4 cache is (above), and the transcripts still on disk are re-indexed under the existing key.

What users will notice:
- **One-time re-index** on the first launch after the upgrade.
- **Lost history:** as with version 4, usage whose transcripts are gone disappears from the totals, permanently. This is the second such re-index after #55.
- **Different totals** only where transcripts held such records: higher where a breakdown or spaced JSON was missed, higher where a negative counter subtracted. A note appears when something couldn't be read.

Interruptions behave as for version 4. No backup of the version 5 file is kept.

## Rewrite detection without a new version (#56)
What is detected (the policy recorded on #56):
- **Same size:** a transcript whose change time moved while its size stayed the same, as seen last time, is read again from the start. That catches any same-size rewrite in place, wherever the edit is, also when the file ends with an incomplete line (its saved offset is then short of its size, so the size seen last time is kept). A metadata-only change (a `touch`, an extended attribute) costs the same one full read, which counts nothing twice.
- **Shorter:** read again from the start, as before.
- **Larger:** read again from the start when any of the 18 anchor windows before the saved offset changed (the first and the last 4 KiB and 16 evenly spaced between them), else read on from the offset, as an append. **Accepted limit:** a larger rewrite that changes only bytes outside all 18 windows isn't detected. It is deterministic (the windows depend only on the saved offset), and only files larger than about 72 KiB have such bytes.
- **Change time unavailable:** a file whose change time can't be read is checked by size alone, as before #56.

A version 7 cache saved before #56 has offsets but no `size`, `stamp` or `anchor`. It is still loaded. A transcript checked without an anchor resumes at its offset as before and takes the new fields: one read of at most 72 KiB, no line parsed. From then on, rewrites are detected as above. A rewrite that happened before the upgrade isn't. Older builds ignore the new fields.

## Separate from Headroom (#11)
SpanDeck is a fork of Headroom and, before #11, used Headroom's identity:
- the bundle id `dev.headroom.Headroom`, and with it the same preferences domain and login-item record;
- the `~/Library/Application Support/Headroom/` folder and `claude-ledger.json`;
- `~/Library/Logs/Headroom-hover.log`.

With both apps on one account they would replace each other's cache. Since #11, SpanDeck has its own identity:
- **`SpanDeck.app`**, with the bundle id `io.github.lolodawit.SpanDeck`, its own preferences domain and its own login-item record;
- **`~/Library/Application Support/SpanDeck/`** for its cache, key and price files;
- **`~/Library/Logs/SpanDeck-hover.log`**, still only with the hidden `debugHover` preference, and since #68 only in debug builds (see [Hover debug log](#hover-debug-log-68)).

**No migration.** SpanDeck never looks inside Headroom's folder, preferences or log, and never imports, renames or deletes them, whichever app created them. That includes state left by a SpanDeck build from before #11. It also doesn't check whether they exist.

What users of a build from before #11 will notice:
- **One-time re-index** into the new folder.
- **Lost history:** usage whose transcripts have since been deleted can't be rebuilt, as with every re-index (see the version 4–6 notes below).
- **Settings start from defaults:** both consent switches are off, the display settings are reset, and *Launch at login* is off. The old preferences domain isn't read.
- **The old state stays as it was:** `Application Support/Headroom/`, the `dev.headroom.Headroom` preferences and any old login item. Delete them yourself if they're yours and you no longer need them; SpanDeck can't tell whose they are.

Going back to a build from before #11 uses the Headroom folder again and never sees SpanDeck's. `scripts/install-app.sh` (used by `./build.sh install`) only replaces an app whose bundle id is SpanDeck's, quits only processes named exactly `SpanDeck`, and never touches `Headroom.app` (`scripts/test-install.sh`).

## Upgrading from a version 6 cache (#57)
Version 6 kept usage per whole UTC hour. In a time zone whose offset isn't a whole number of hours (+05:30, +05:45, −03:30 and others), local midnight falls inside an hour, and that hour's usage can't be split between the two days without the record times, which the cache doesn't hold. So version 6 hours are never reinterpreted as 15-minute slots: a version 6 cache is deleted when found, exactly as a version 4 or 5 cache is (above), and the transcripts still on disk are re-indexed under the existing key.

Every current time zone's offset is a multiple of 15 minutes, so with 15-minute slots every local midnight is a slot boundary: days, today, the 7 and 30 days are exact in every zone in use, and days are worked out when the totals are, so a change of time zone needs no re-index. The 5-hour window's start is rounded down to 15 minutes instead of an hour.

What users will notice:
- **One-time re-index** on the first launch after the upgrade.
- **Lost history:** as before, usage whose transcripts were deleted within the last 30 days, which the version 6 cache still counted, disappears from the totals, permanently. This is the third such re-index, after #55 and #58.
- **Different days** only in time zones with a fractional offset: up to 45 minutes of usage around midnight moves to its correct day. Totals over 30 days only change at the first day's edge. Identity, completeness, quantity and cost coverage are recounted from the transcripts.
- **A larger cache:** at most four buckets per active hour and model instead of one.

Interruptions behave as for version 4. No backup of the version 6 file is kept.

## Downgrading
Older builds ignore a newer cache (version check), delete it and re-index with their own rules: a version 6 build goes back to whole UTC hours (and wrong days in fractional-offset zones), and older ones also bring back the miscounting each version fixed. Each such re-index loses usage whose transcripts are gone, as an upgrade does. They leave the key file in place and reuse it. A version 7 build from before #66 loads a cache written after it as it is. It shows each rejected id's usage as its own model row named `unknown#` followed by 32 hex digits, never the raw id. If that build then reads a transcript again from the start (after a rewrite), records with a rejected model id are counted a second time under the raw id, until they age out after 32 days or the cache is cleared. A version 5 or older build can't show what couldn't be read, and a version 4 or older build can't show identity coverage.

## Clear cached usage data
Settings ▸ Cached usage data ▸ *Clear cached usage data…* asks for confirmation, then deletes `claude-ledger.json`, its key and any temporary files.

It does not:
- delete Claude Code or Grok transcripts, price files or credentials;
- change plan-limit consent or any other setting.

The clear runs on the ledger's serial queue, so it can't interleave with a refresh or a save.

**What happens to memory and the screen:**
- It resets the in-memory index, cached totals and the full-scan timer, and makes a new key.
- A refresh that started before the clear can't publish its totals afterwards.
- Quitting right after a clear writes nothing.
- The next refresh re-reads all transcripts and saves a fresh cache under the new key. That's expected, since the transcripts are still there.

**If something fails:**
- Leftover temporary files are listed before anything is deleted. If the folder can't be listed (for example, it is writable but not readable), nothing is deleted and the failure is shown.
- If the cache can't be deleted, nothing is reset and the failure is shown.
- If the key or a temporary file can't be deleted after the cache is gone, that is shown, not success.

## Hover debug log (#68)
`~/Library/Logs/SpanDeck-hover.log` holds hover diagnostics: timestamps, mouse coordinates, panel frames and the hovered segment. No usage, transcript, model or credential data goes into it.
- **Release builds** (`./build.sh`, the release workflow, `swift build -c release`) don't contain it. The `debugHover` lookup and the file writer are compiled only into debug builds (`#if DEBUG`, audit 0007, P2), so setting `debugHover` does nothing and a release build never creates, appends to, truncates or deletes the file. `build.sh` refuses to package a binary that has it (`scripts/check-hover-log-release.sh`).
- **Debug builds** (`swift build`, `swift run SpanDeck`) write it only when `debugHover` is set in their preferences domain, read once at launch. `build.sh` never packages a debug build, so in practice that is the unbundled binary, whose domain is the process name ([audit 0008 §1](audits/0008-identity-isolation.md)): `defaults write SpanDeck debugHover -bool true` turns it on, and `defaults delete SpanDeck debugHover` and a relaunch turn it off. It is a development aid for a test account, not for an account with real usage data. The file is created `0600`, appended to, never followed through a symlink, and only if `~/Library/Logs` exists. An existing log that isn't a regular file of yours, or that others can read or write (a `0644` log from before #68, say), is left as it is: not appended to and not re-moded. Delete it or `chmod 600` it yourself to log again.
- **Not erased:** *Clear cached usage data* doesn't touch it, and this change deletes no log, including `Headroom-hover.log` and a `SpanDeck-hover.log` from an earlier build. Copies in backups and snapshots stay too (see below). Delete them yourself if they're yours.

## Backups and erasure
**Excluded from backups (#70).** `claude-ledger.json` and `claude-ledger.key` are marked with Foundation's `isExcludedFromBackup`, the `com.apple.metadata:com_apple_backup_excludeItem` attribute that Time Machine reads (`tmutil isexcluded` shows `[Excluded]`).
- **Every save** marks its temporary file before `rename(2)` puts it in place. A replacement doesn't inherit the old file's attribute but keeps its own, so the cache is never in place unmarked.
- **Existing installs:** a key and cache written before #70 are marked when they're loaded. Nothing is rewritten, re-indexed or deleted.
- **After *Clear cached usage data*,** the new key and cache are marked as they're written.
- **If marking fails** (for example on a volume without extended attributes):
  - a new cache or key isn't written at all, Settings shows *Usage cache not saved: the cache or its key couldn't be excluded from backups*, and totals stay in memory;
  - an existing cache or key is kept and used, and Settings says it couldn't be excluded. The key is written once, so that message stays until the key is marked; each save tries again.
- **Only future backups.** Backups, APFS snapshots and local Time Machine snapshots made before the upgrade keep their copies; this change doesn't erase them.
- **Only tools that honour the attribute.** Time Machine does. A copy made with `cp`, `rsync`, cloud sync or another backup tool may ignore it, depending on the tool and its options.
- **Not covered:** the price files, the folder itself and the hover debug log aren't marked.
- **Marking is by path** (Foundation's API), after a check that the file is a regular file of yours. Only a process already running as you could swap the file in the `0700` folder between the check and the mark.
- **Trade-off:** after restoring a backup, the cache is rebuilt from the transcripts that are still there, so usage from transcripts deleted since is gone.

Other backups of `~/Library/Application Support` include SpanDeck's other files. Deleting a file (by clearing, migrating or replacing it) removes it from the folder, but it is not secure erasure:
- old contents can remain on the SSD until overwritten;
- they can also remain in APFS snapshots, local Time Machine snapshots and backups.
