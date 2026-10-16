# Ledger accounting fixtures (#6)

Synthetic Claude Code transcript records and hand-derived expected results for `LedgerFixtureTests`. All data is invented: no real transcripts, prompts, ids, paths or accounts. Records carry only the fields the ledger reads (`type`, `timestamp`, `requestId`, `message.id`, `message.model`, `message.usage`).

The findings are in [`docs/audits/0006-ledger-accounting.md`](../../../../docs/audits/0006-ledger-accounting.md).

## Independence of the expected values

Each `fixture.json` holds the expected result **for the policy below**, worked out by hand. Its `derivation` field shows the arithmetic. None was produced by running the ledger.

Where the ledger does something else today, `baseline` records what it does. That was also worked out by reading `Ledger.swift` before the first run, and the first run confirmed every baseline. A baseline is not the expected result; it pins current behavior so that a fix, or an accidental change, is noticed.

## Format

```jsonc
{
  "title": "…",
  "matrix": ["rows of the #6 fixture matrix this covers"],
  "classification": "pass | defect | ambiguous",
  "followUp": "#55",            // where a defect or an open policy is tracked, or the fix a passing fixture verifies
  "policy": "Pn: …",            // the rule the expected values assume
  "timeZone": "America/Los_Angeles",
  "now": "2026-03-10T19:00:00Z", // the ledger's clock for this fixture
  "windowStart": "…",           // optional 5-hour window start
  "records": 3, "duplicates": 2, // usage records in the inputs; how many of them repeat an operation
  "derivation": "the arithmetic",
  "steps": [{
    "ops": [{"op": "write | append | delete | rename", "path": "<project>/<file>.jsonl", "from": "<input>", "to": "<path>"}],
    "expect":   { … },          // the correct result after this step
    "baseline": { … },          // today's result, when it differs
    "baselineByMode": {"tail": { … }, "fullScan": { … }, "relaunch": { … }}
  }],
  "rebuild": {"expect": { … }, "baseline": { … }} // after clearing the cache; defaults to the last step
}
```

The fields of an expectation are all optional, and only the fields present are checked:

| Field | Meaning |
|---|---|
| `hours` | Every UTC hour bucket (`yyyy-MM-ddTHH`) → model → `[input, output, 5m cache write, 1h cache write, cache read, calls]`. Compared exactly. |
| `operations` | Unique operations: the sum of `calls` over all buckets. |
| `days` | Local day (in `timeZone`) → tokens, over the 30-day range. |
| `today`, `week`, `month`, `window` | Token totals for today, the last 7 days, the last 30 days and the 5-hour window. |
| `coverage`, `models` | Cost coverage (`complete`, `partial`, `unavailable`) for the 30 days and per model. |
| `knownCost` | The known part of the 30-day cost estimate, in USD, at the bundled list prices. |
| `identity` | How the 30 days' operations were identified (#55): `identified` (both ids), `incomplete` (one id, alone or joined to a pair), `fingerprinted` (neither id), `ambiguous` (one id that more than one pair carries). |

`write` replaces a file in place (same inode), `append` adds bytes, `rename` moves a file and `delete` removes it. After every step, all modification times under `.claude/projects` are set to one minute before `now`. Otherwise "recently modified" would depend on the day the tests run.

## How each fixture runs

| Run | What it exercises |
|---|---|
| `tail` | One ledger with the clock fixed: the first refresh is a full scan, later ones take the incremental path (new-file discovery and hot-file tailing). |
| `fullScan` | One ledger with the clock moved 301 s before each step, so every refresh is a full scan. |
| `relaunch` | `flush()` and a new ledger over the same cache before each step. |
| `rebuild` | All steps, then `clearCache`, then a fresh index of the files left on disk. |

The expected result (`expect`) is the same in every mode. Before #55, the ledger didn't always agree with itself: F15 recorded 590 when tailing and 810 after a full scan or relaunch. `baselineByMode` remains in the format for such cases.

After every step a second refresh with no changes must return the same result. `unsavedProgressIsNotCountedTwice` additionally starts a new ledger from a cache saved before the last records were counted, as after a crash.

## Policies the expected values assume

These are proposals for review. The ones marked *ambiguous* need a decision, and #9 records the identity rules.

| | Policy |
|---|---|
| P1 | An operation is identified by message id + request id; every record with that identity is the same operation, in any file. |
| P2 | *Ambiguous.* Repeated records are cumulative snapshots: each field counts its largest value, so totals never go down. |
| P3 | An operation belongs to the hour of the first record read; later growth is added there, even if a later record's timestamp is in another hour or earlier. |
| P4 | *Decided on #9 for #55.* An id that is missing, empty, only whitespace or not a string is absent. With one id absent, the other alone identifies the operation (`message-only` or `request-only`), and joins the one pair that carries the same id. If more than one pair carries it, the record is counted on its own as ambiguous, never merged into either. A join is never undone. Records with neither id are identified by a keyed fingerprint of timestamp, model and every usage counter (absent ≠ 0), so an identical record counts once in any file. Changed counters count again (F33) and identical distinct operations count once (F32); both are accepted limitations. Anything but both ids makes the total uncertain (`identity`). |
| P5 | *Ambiguous.* The same message id under another request id is another operation (as in ccusage). |
| P6 | *Ambiguous for the last line.* A line counts once its newline is written. |
| P7 | A record that can't be read isn't counted and should be reported as unread. User records and `<synthetic>` records are not usage. A record without a model is counted under `unknown`, with an unknown cost. |
| P8 | A negative or non-numeric counter is invalid and never subtracts. A cache-write breakdown is used when the flat total is absent. Valid JSON is read whatever its whitespace. |
| P9 | *Ambiguous.* When the 5m + 1h breakdown doesn't add up to the flat total, the flat total is used and priced as 5-minute writes. |
| P10 | *Ambiguous.* One operation has one model; a re-log under another model adds nothing. |
| P11 | *Assumption.* Top-level usage covers the main model. Iterations of another model are extra operations. Iterations of type `message` or of the main model are already included. |
| P12 | Usage already counted stays counted when its transcript is rewritten or deleted. A rebuild can only count what is still on disk. |
| P13 | A file whose content was replaced is read again from the start, and identity dedupe prevents double counting. |
| P14 | A record belongs to the local day of its own timestamp. |
| P15 | *Ambiguous.* The 5-hour window holds records at or after its start. |
| P16 | Hours older than 32 days are dropped with their dedupe keys. The 30-day total starts at local midnight 29 days before today. |
| P17 | A model without a price has an unknown cost, never $0 (R7). |
