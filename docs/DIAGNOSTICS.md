# Local diagnostics (#94)

SpanDeck can record its own performance in a **diagnostic session** that the user starts and stops. It's off by default. It exists so decisions about the optimizations deferred in [`PERFORMANCE.md`](PERFORMANCE.md) can rest on the real app, not only on synthetic benchmarks:
- **U1–U3**, the popover re-render candidates (§4.7);
- **O1/O2**, the cache-save memory transient (§4.6).

## Controls
- **Start:** Settings ▸ **Start diagnostic session…** shows a disclosure card first. Nothing is measured or written until **Start diagnostic session** is pressed.
- **Stop:** Settings ▸ **Stop diagnostic session**. The instruments are removed at once, and nothing more is recorded.
- **Export:** Settings ▸ **Export diagnostics…** saves a JSON copy wherever the user chooses, through the standard save panel. Nothing is copied anywhere else.
- **Delete:** Settings ▸ **Delete diagnostic data** stops any session and deletes its file.

## What is recorded
Every event has one **kind**, from a fixed list, and only numbers or a fixed label beside it. There's no free-text field, so a path, file name, transcript text, prompt, model name, account detail or credential can't be recorded.

| Kind | Measures | Fields |
|---|---|---|
| `launch` | process start (kernel start time) → end of `applicationDidFinishLaunching` | `ms` |
| `firstUsage` | process start → first usage totals published | `ms` |
| `popoverOpen` | menu-bar click → main thread next idle: view built, laid out, committed. Not drawing on screen. | `ms` |
| `popoverClose` | close click on the menu-bar item → `popoverDidClose` (a click outside the popover isn't timed) | `ms` |
| `stall` | a main-thread busy span ≥ 100 ms (run-loop observer) | `ms` |
| `refresh` | one ledger refresh on its queue: `cold` (first scan without a cache), `full` (5-minute rescan), `tail` | `ms` |
| `cacheLoad` | reading the usage cache at the first refresh: `kept`, `discarded`, `absent` | `ms`, `bytes` |
| `cacheSave` | encoding and writing the usage cache: `saved` / `failed` | `ms`, `bytes` |
| `process` | every 30 s: CPU since the last sample (% of one core) and physical footprint | `cpuPercent`, `footprintMB` |
| `shutdown` | quit request → reply, with the ledger's outcome: `saved`, `nothingToSave`, `failed`, `timedOut` | `ms` |
| `error` | a failed operation, by category: `claudeQuota`, `grokQuota`, `usageCache`, `pricing` | — |
| `sessionStart`, `sessionResume` | session boundaries | — |

- **The export** adds `environment`: app name, version and build, macOS version, architecture and core count. It holds no host name, user name or path.
- **Timestamps:** `startedAt` and `updatedAt` are absolute. Events carry seconds since the session started.

## Storage and retention
- **Where:** `~/Library/Application Support/SpanDeck/diagnostics.json`.
  - Owner-only: the folder is `0700` and the file `0600`.
  - Written atomically, and excluded from backups.
  - The same protections as the usage cache (`PrivateDirectory`).
- **Bounded:** at most 5,000 events, about 100 bytes each, so about 0.5 MB. The oldest are dropped first and counted in `dropped`.
- **Written:** at most every 5 minutes while a session runs, when it stops, and at quit. Encoding and writing run on a background queue; stop and quit wait for the write. A crash loses up to 5 minutes of events.
- **Across relaunches:** a session continues, so start-up and quit are measured.
- **24-hour limit:** a session stops by itself 24 hours after it started.
- **Retention:** a stopped session's file is deleted at launch once it hasn't been written for 7 days. A damaged file, or one of another schema, is deleted at launch. Starting a new session replaces the previous one's data.
- **No network:** no upload, endpoint or background transfer of any kind. Diagnostics adds no request, credential read or subprocess.

## Overhead
**While off:**
- `record` reads the clock, takes one lock and returns.
- No observer or timer is installed.
- The session file is read once at launch, to resume or expire it.

**While on:**
- **Run-loop observers:** two, each doing two `mach_absolute_time` reads and a comparison per main run-loop pass.
- **Timer:** one at 30 s, doing a `getrusage` and a `task_info` call.
- **Recording:** an append under a lock, in place; at the cap, the oldest event is dropped.
- **Writes:** a JSON write of at most about 0.5 MB every 5 minutes, off the main thread.
- **Ledger timings:** a clock read around work that is already done.

## What it can't measure
- **Drawing:** `popoverOpen` ends when the main thread goes idle after the click. That covers build, layout and the Core Animation commit, but not the window server's drawing or the open animation.
- **Energy:** not measured.
- **Shutdown after the reply:** not measured.
- **Process start:** if the kernel's start time can't be read, `launch` and `firstUsage` are skipped.
- **Export result:** the save panel may close the popover. The result ("Diagnostics exported…") then shows the next time the popover opens.
- **Busy spans and time spent waiting:** a stall is a busy span of the main thread. Time the main thread spends waiting, such as for a modal panel, isn't a stall.

## Tests
`DiagnosticsTests` covers:
- off by default with nothing written;
- start, record and stop, which removes the instruments and records nothing afterwards;
- the bound;
- the 24-hour stop;
- resume at relaunch;
- 7-day retention;
- delete;
- an export containing no canary, model name, path, user or host name, and only the closed keys and labels;
- the disclosure text.
