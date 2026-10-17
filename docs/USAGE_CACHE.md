# Local usage cache: what is stored, and why (R8, #33)

SpanDeck counts Claude Code token usage by reading the transcripts in `~/.claude/projects` and `~/.config/claude/projects`. Re-reading every transcript on every launch would be slow, so it keeps an incremental index. This page describes that index as of R8, with schema version 7 (#55, #58, #57). Storing data locally does not by itself make it private: any process running as your user can read your user's files.

## Files
All in `~/Library/Application Support/Headroom/`. The folder and file names are inherited from Headroom and kept for compatibility.

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
| `files` | opaque file id → byte offset; since #56 also a keyed id of the file's change time (`stamp`) and a keyed id of the bytes before the offset (`anchor`: the first and the last 4 KiB) | Read only what was appended to each transcript, and read a transcript rewritten in place (at any size) again from the start (#56). The stamp is only compared, so no precise time is stored |
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

Only lines with a `"usage"` key (with any JSON whitespace before its colon) are parsed. The parser reads each assistant line's `message.model`, `message.usage`, `message.id`, `requestId` and `timestamp`. The line is parsed as a whole, but nothing else from it is kept. Paths stay in memory only, for opening the files. Grok session files are read every refresh and never cached. Model names and token counts are shown in the UI. Nothing from transcripts is logged: the app's only `NSLog` reports a login-item error.

## Opaque ids and their limits
Each id is one of:
- `HMAC-SHA256(key, "file" | path)`;
- `HMAC-SHA256(key, "message" | message id | request id)` for a record with both ids;
- `HMAC-SHA256(key, "message-only" | message id)` or `HMAC-SHA256(key, "request-only" | request id)` for a record with one (#55);
- `HMAC-SHA256(key, "unread" | the line's bytes)` for a line that couldn't be read (#58). The same bytes give the same id in any file, so a rescan, rewrite, rename or copy reports it once;
- `HMAC-SHA256(key, "fingerprint" | time | model | each usage counter …)` for a record with neither. The time is the instant as parsed, in milliseconds since 1970, so `Z`, `+00:00`, other offsets and trailing fractional zeros don't matter. Two records whose times differ by less than a millisecond get the same time. The model is used as written. Every counter the ledger reads (including the cache breakdown and iterations) follows in a fixed order, each as absent, its numeric value (`50`, `50.0` and `5e1` are the same) or something else. No path or offset is in it.

In every case:
- every part is length-prefixed;
- the result is truncated to 128 bits and written as hex;
- the key is generated with CryptoKit on first save and never leaves the machine (no Keychain, no credential store, no network).

What this protects against: someone who gets only the cache file can't read your paths or ids from it. Without the key, they also can't confirm a guess such as "is this project in it?" Ids also can't be matched across installs.

What it doesn't protect against:
- The key sits next to the cache, so anyone who can read both (any process running as you, or a backup containing both) can test guesses. A path or id with little randomness can then be confirmed by trying candidates.
- Time buckets (15-minute UTC slots since #57), models and token counts are stored in the clear. They show when, to the quarter hour, and how much you used each model over the last 32 days.
- A fingerprint covers only a timestamp, a model name and token counts. Someone with the key who can guess all of those for a record can confirm it.
- A file's anchor covers the first and the last 4 KiB before its saved offset (#56). Someone with the key who can guess those exact bytes can confirm them. They learn nothing about bytes they can't guess.
- An unread line's id covers the whole line. Someone with the key who can guess the exact bytes of a broken line can confirm it was in a transcript. They learn nothing about lines they can't guess.

## Retention
- Transcripts last modified more than 32 days ago are skipped.
- Time buckets, operation ids, single-id links, identity counts, flaw counts and unread lines older than 32 days are pruned at each full scan (every 5 minutes while running). An unread line without a usable timestamp is pruned 32 days after it was found.
- Unread lines stay counted when their transcript is deleted or rewritten without them, like usage already counted: the totals still lack them. A cleared cache only reports what is still on disk.
- A transcript that disappears is dropped from `files`.
- The cache is saved at most every 10 minutes, and again on quit.

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
A version 7 cache saved before #56 has offsets but no `stamp` or `anchor`. It is still loaded. A transcript checked without an anchor resumes at its offset as before, and takes a stamp and an anchor: one read of at most 8 KiB, no line parsed. From then on, a rewrite in place is detected. The one gap is a same-size rewrite that happened before the upgrade, which stays uncounted as before. Older builds ignore the two fields. Their marks have no anchor, so if they later write one, the next check adopts it again.

**Limit (option (a) on #56):** a same-size edit confined to the middle of a transcript larger than 8 KiB, with its first 4 KiB and the 4 KiB before the saved offset intact, isn't detected. A metadata-only change (a `touch`, an extended attribute) costs only that check, never a full read.

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
Older builds ignore a newer cache (version check), delete it and re-index with their own rules: a version 6 build goes back to whole UTC hours (and wrong days in fractional-offset zones), and older ones also bring back the miscounting each version fixed. Each such re-index loses usage whose transcripts are gone, as an upgrade does. They leave the key file in place and reuse it. A version 5 or older build can't show what couldn't be read, and a version 4 or older build can't show identity coverage.

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

## Backups and erasure
`~/Library/Application Support` is part of your home folder, so Time Machine and other backups include these files unless you exclude them; SpanDeck doesn't. Deleting a file (by clearing, migrating or replacing it) removes it from the folder, but it is not secure erasure:
- old contents can remain on the SSD until overwritten;
- they can also remain in APFS snapshots, local Time Machine snapshots and backups.
