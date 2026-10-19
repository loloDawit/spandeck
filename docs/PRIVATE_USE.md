# Private-use contract (#94)

**Status:** the first usable version's promises, as of `main` after #95 and #97. This page defines what SpanDeck must do for the owner's private daily use. It is not a release and not a public support statement.
- [`METRIC_CONTRACT.md`](METRIC_CONTRACT.md) defines what each number means.
- [`INSTALL.md`](INSTALL.md) covers install, upgrade, uninstall and rollback.
- [`VALIDATION.md`](VALIDATION.md) records how each promise is verified, including what still needs the owner's run.

## 1. What SpanDeck is today
SpanDeck is a macOS 14+ menu-bar app (Apple Silicon and Intel) that shows four things:
- **Token usage and estimated API-equivalent cost** from Claude Code's local transcripts (`~/.claude/projects`, `~/.config/claude/projects`) and Grok CLI's local usage files.
  - Windows: today, 7 days, 30 days and Claude's 5-hour window.
  - It also shows a 30-day chart and a per-model list.
- **Plan quota percentages**, only if the user opts in:
  - Claude Code plan limits: an unofficial endpoint, using the Claude Code credential from the Keychain.
  - Grok credits: the Grok CLI's endpoint, using its key.
- **System load** (CPU, GPU, memory, battery), with the top processes on hover. Inherited from Headroom.
- **Keep awake**: manual, or while Claude Code or Grok is working. Inherited.

It runs locally. At default launch it makes no network request and reads no credential.

## 2. Promises

### Application lifecycle
| Promise | How it's kept |
|---|---|
| Launches into the menu bar, opens and closes its popover | `NSStatusItem` + `NSPopover`; the popover's views are dropped when it closes |
| Loads existing local data | The usage cache (v7) is read at the first refresh. Only Claude and Grok files in their usual locations are read. |
| Refresh doesn't block interaction | Ledger work runs on its own queue; the main thread is held at most a few ms (#8, #88) |
| Quits cleanly, even mid-scan | #86: the scan stops at a checkpoint and saves off the main thread, with a 5 s cap |
| Relaunch gives consistent totals | Cache plus offsets: each record is counted once across relaunches (F01–F49, `relaunchKeepsIdsAndOffsets`) |
| Missing or corrupt cache handled safely | A missing cache means a full re-index. A corrupt cache, one of another version, or one with another key is discarded and rebuilt from the transcripts. Never misread. |

### Usage visibility
| Promise | How it's kept |
|---|---|
| Tokens, quota percentages and costs are never mixed | Five kinds of number (contract §1). Quotas appear only in the limits card; tokens and costs only in the usage card. |
| Estimated cost isn't a bill | Every cost is labelled an estimate at list prices, with the price revision. A partial or unknown cost shows as `≥`, `~` or `n/a`, never `$0`. |
| Missing, stale, estimated and unsupported data are explained | Each has a note: unread records, uncertain identity, provisional quantities, unpriced models, a missing or unreadable transcript folder (#95), a quota window that has reset (#95), and provider failures with guidance (#21) |
| No misleading aggregation | Claude and Grok are shown per provider and as a labelled combination. Overlapping Claude sources aren't summed: only the transcripts are read today (ADR 0001). |

### User experience
- **States:**
  - loading ("Reading usage…", indexing progress);
  - empty (an existing folder with no usage reads as an observed 0);
  - not set up (no transcript folder: guidance text);
  - error (provider failures with what to do);
  - unsupported (an unpriced model: `n/a`).
- **Freshness:** the footer shows "Usage updated ⟨age⟩". A stale quota shows its age. Settings shows the price revision.
- **No Terminal needed:**
  - consent cards cover the integrations;
  - Settings covers clearing the cache, launch at login, diagnostics, the quota switches and the sampling rate.

### Reliability
- No silent loss of valid data: usage counted before a transcript or folder disappeared is kept and labelled.
- No configuration change outside SpanDeck's own preferences domain and Application Support folder. The Grok CLI may update its own files when SpanDeck runs `grok models`; that is opt-in and disclosed.
- No crash in supported workflows. This is covered by the automated suite, and by the owner's runtime checks in [`VALIDATION.md`](VALIDATION.md).

## 3. Integrations and permissions (all off by default)
| Integration | What it accesses | Consent | Turn off / roll back |
|---|---|---|---|
| Claude plan limits | Keychain item `Claude Code-credentials` (read via `/usr/bin/security`); sends its OAuth token to `api.anthropic.com/api/oauth/usage` (unofficial) | Inline card with this disclosure | Settings ▸ Turn off Claude plan limits: stops reads and requests, clears what was shown |
| Grok credits | `~/.grok/auth.json`; `cli-chat-proxy.grok.com/v1/billing`; may run `~/.grok/bin/grok models` at most every 10 min | Card from Settings ▸ Set up Grok credits… | Settings ▸ Turn off Grok credits |
| Launch at login | `SMAppService.mainApp` | Settings toggle | Same toggle; an existing registration is never changed silently |
| Price download | One pinned, SHA-256-checked file from `raw.githubusercontent.com` | Button, offered only when the built-in prices don't verify | n/a (only replaces SpanDeck's price file) |
| Diagnostics | Nothing outside SpanDeck's folder; no network | Disclosure card (#97) | Stop / Delete in Settings |

**No integration changes Claude Code's own settings, hooks, status line or files.** A status-line or OTel adapter is M2 work (#84) and needs its own consent, change-preview and rollback design (#4).

## 4. Inherited Headroom functionality
| Feature | Decision | Why |
|---|---|---|
| System gauges and top consumers | **Keep** | Local, no new permission, useful context for agent load |
| Keep awake (manual, while agents work) | **Keep** | A local power assertion only. "While agents work" is off by default and reads only file modification times. |
| Grok token usage and credits | **Keep, secondary** | Same safeguards as Claude (#17, #21, F-1) |
| Hover debug log | **Debug builds only** (#68) | Privacy |
| `--snapshot` | **Debug builds only, synthetic data** (R10) | Privacy |
| Unofficial Claude quota endpoint | **Keep, opt-in, labelled unofficial** | No supported credential-free source exists (#4, audit 0010). Without consent, quotas are simply not shown. |

## 5. Not promised in this version
- Session, project, agent or tool views (M2), and alerts (M3).
- Bedrock, Vertex or Enterprise billing (contract §8), and any actual charge.
- Claude data from OTel or the status line (#84, M2).
- A signed, notarized release, or auto-update.
- The 5-hour window's first slot is exact only when resets fall on a quarter hour (P15).
