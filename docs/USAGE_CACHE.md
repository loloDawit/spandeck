# Local usage cache: what is stored, and why (R8, #33)

SpanDeck counts Claude Code token usage by reading the transcripts in `~/.claude/projects` and `~/.config/claude/projects`. Re-reading every transcript on every launch would be slow, so it keeps an incremental index. This page describes that index as of R8. Storing data locally does not by itself make it private: any process running as your user can read your user's files.

## Files
All in `~/Library/Application Support/Headroom/`. The folder and file names are inherited from Headroom and kept for compatibility.

| File | Contents | Mode |
|---|---|---|
| (folder) | — | `0700`, checked and tightened before every cache write. Parent folders are never changed. |
| `claude-ledger.json` | Usage index, schema version 4 | `0600` |
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
| `files` | opaque file id → byte offset | Read only what was appended to each transcript |
| `seen` | opaque message id → hour + token counts per model | Count a streamed message once as it grows, and a message repeated in a resumed session once |
| `hours` | hour → model → token counts | Totals, windows and cost estimates |
| `version` | `4` | A different version is never loaded |

**Not stored:**
- transcript paths, project folder names or your user name;
- message ids or request ids;
- prompts, responses, code, tool arguments or tool output.

The parser reads each assistant line's `message.model`, `message.usage`, `message.id`, `requestId` and `timestamp`. The line is parsed as a whole, but nothing else from it is kept. Paths stay in memory only, for opening the files. Grok session files are read every refresh and never cached. Model names and token counts are shown in the UI. Nothing from transcripts is logged: the app's only `NSLog` reports a login-item error.

## Opaque ids and their limits
Each id is `HMAC-SHA256(key, "file" | path)` or `HMAC-SHA256(key, "message" | message id | request id)`:
- every part is length-prefixed;
- the result is truncated to 128 bits and written as hex;
- the key is generated with CryptoKit on first save and never leaves the machine (no Keychain, no credential store, no network).

What this protects against: someone who gets only the cache file can't read your paths or ids from it. Without the key, they also can't confirm a guess such as "is this project in it?" Ids also can't be matched across installs.

What it doesn't protect against:
- The key sits next to the cache, so anyone who can read both (any process running as you, or a backup containing both) can test guesses. A path or id with little randomness can then be confirmed by trying candidates.
- Hour buckets, models and token counts are stored in the clear. They show when and how much you used each model over the last 32 days.

## Retention
- Transcripts last modified more than 32 days ago are skipped.
- Hour buckets and message ids older than 32 days are pruned at each full scan (every 5 minutes while running).
- A transcript that disappears is dropped from `files`.
- The cache is saved at most every 10 minutes, and again on quit.

## Upgrading from a version 3 cache
Version 3 stored raw paths and ids, and SpanDeck doesn't try to convert them. When it finds a version 3 cache, it deletes it before reading anything else and re-indexes the transcripts still on disk. That's a one-time full read, after which totals and deduplication are the same as before. The same happens to:
- a corrupt cache;
- a cache whose key is missing;
- a symlink at the cache path (the link is removed, never its target);
- leftover temporary files.

If the old file can't be deleted, Settings says so. Usage from transcripts that are gone, or older than 32 days, can't be rebuilt. Transcripts are never modified.

Downgrading: older builds ignore a version 4 cache (version check) and re-index. They leave the key file unused.

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
- If the cache can't be deleted, nothing is reset and the failure is shown.
- If only the key can't be deleted, that is shown too.

## Backups and erasure
`~/Library/Application Support` is part of your home folder, so Time Machine and other backups include these files unless you exclude them; SpanDeck doesn't. Deleting a file (by clearing, migrating or replacing it) removes it from the folder, but it is not secure erasure:
- old contents can remain on the SSD until overwritten;
- they can also remain in APFS snapshots, local Time Machine snapshots and backups.
