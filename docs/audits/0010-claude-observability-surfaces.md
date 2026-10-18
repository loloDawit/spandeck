# Audit 0010 — Claude observability surfaces, Enterprise and Bedrock coverage (#10)

**Issue:** #10 (M0). **Base:** `main` at `fff19fd`. **Companions:** [ADR 0001](../adr/0001-canonical-events-identity-and-storage.md) (D1–D8), [metric contract](../METRIC_CONTRACT.md) 0.3.
**Scope:** documentation, repository code and synthetic examples only. Nothing here was run against Claude Code. No credentials or transcripts were read, telemetry wasn't enabled, no hooks were installed and no Claude settings were changed. Research only: no code changes.

**Evidence labels:**
- **`[doc]`:** stated in a primary Anthropic document (sources in §1).
- **`[sdk]`:** stated in the official SDK's generated type declarations.
- **`[code]`:** read in this repository.
- **`[third-party]`:** a claim by someone else, not checked here.
- **`[inference]`:** reasoned from labelled facts.
- **`[unknown]`:** no source found.

Documents can be wrong or out of date. None of the `[doc]` claims has been checked against a running Claude Code (`[runtime]`), and none can be until the owner runs a consented check.

## 1. Source matrix

Retrieved **2026-10-18 17:43 UTC** as markdown (`<page>.md`). The pages carry no version number, so the minimum versions below are the ones the pages themselves state. Hashes are the first 16 hex digits of the SHA-256 of each retrieved file, so a reviewer can check against the same bytes.

| Source | URL | SHA-256 (16) | Used for |
|---|---|---|---|
| Status line | https://code.claude.com/docs/en/statusline | `bbe651578fa8edf2` | §2.2, §3, §5 |
| Monitoring (OpenTelemetry) | https://code.claude.com/docs/en/monitoring-usage | `c4984d5c294fd8c8` | §2.3 |
| Sessions | https://code.claude.com/docs/en/sessions | `a4d0d58234728333` | §2.1 |
| `.claude` directory | https://code.claude.com/docs/en/claude-directory | `1aab55aa4a8a6632` | §2.1 retention |
| Subagents | https://code.claude.com/docs/en/sub-agents | `2ef84ba688983c9d` | §2.1 |
| Costs | https://code.claude.com/docs/en/costs | `6622bdc6962b23a8` | §2.4, §2.5 |
| Amazon Bedrock | https://code.claude.com/docs/en/amazon-bedrock | `4790981fe3750642` | §2.5 |
| Model configuration | https://code.claude.com/docs/en/model-config | `cf781dd9bd0954ef` | §6 P10 |
| Advisor tool (API) | https://platform.claude.com/docs/en/agents-and-tools/tool-use/advisor-tool | `113496b2e464a2d0` | §2.1 iterations |
| Compaction at a threshold (API) | https://platform.claude.com/docs/en/build-with-claude/compaction-threshold | `974579ddaca9ae07` | §2.1 iterations |
| `@anthropic-ai/sdk@0.115.0` `resources/beta/messages/messages.d.ts` | https://unpkg.com/@anthropic-ai/sdk@0.115.0/resources/beta/messages/messages.d.ts | `2d03edf110c7eb5c` | §2.1 iterations |
| Upstream Headroom PR #1 (open, unmerged) | https://github.com/sandrich/headroom/pull/1 | n/a (read 2026-10-18) | §2.5 `[third-party]` |

Also read: `settings-reference`, `managed-settings`, `prompt-caching`, `claude-apps-gateway-spend-limits`, `iam`, `data-usage`, `llm-gateway`, `google-vertex-ai` (same retrieval). Every claim below names its page and section.

## 2. Findings per surface

### 2.1 Claude Code JSONL transcripts (today's only Claude usage source)

**Location and format:**
- `~/.claude/projects/<project>/<session-id>.jsonl` `[doc: sessions › Where transcripts are stored]`.
- Subagent transcripts are separate files, `projects/<project>/<session>/subagents/agent-<agentId>.jsonl` `[doc: sub-agents; claude-directory › cleaned up automatically]`.
- **The entry format is "internal to Claude Code and changes between versions"** `[doc: sessions]`, so every field SpanDeck parses (`message.usage`, `message.id`, `requestId`, `usage.iterations`) is undocumented for transcripts.
- What *is* documented is the Messages API response those fields appear to copy `[inference]`.

**Session identity:**
- The file name is the session id `[doc]`.
- The ledger doesn't use it, and keeps project and session opaque (ADR D7) `[code]`.
- `/branch` copies a transcript, and resuming one session in two terminals interleaves both into one file `[doc: sessions]`.
- Both are already covered by identity dedupe and P13 `[code]`.

**Retention (new finding):**
- Claude Code deletes top-level transcripts **and their subagent transcripts** once they're older than `cleanupPeriodDays`, **30 days by default** `[doc: claude-directory › cleaned up automatically; sessions]`.
- Desktop and Cowork transcripts are kept at any age unless `desktopSessionCleanupPeriodDays` or managed settings say otherwise `[doc]`.
- SpanDeck keeps 32 days and rebuilds its cache from the transcripts still on disk (P12, P16) `[code]`. So by default, **days 31–32 can't be rebuilt after a cache rebuild**, and a rebuild shows them lower than before.
- That is consistent with P12's accepted loss, but `USAGE_CACHE.md` doesn't name the 30-day sweep. Follow-up proposed in §8.

**`usage.iterations` (P11):** the API semantics are documented. Their pass-through into transcripts is `[inference]`.

| Iteration `type` | In top-level `usage`? | Has `model`? | Ledger today (`ingestClaudeLine`) `[code]` | Result if transcripts copy the API |
|---|---|---|---|---|
| `message` (executor) | **yes**: top-level is the sum of executor iterations `[doc: advisor-tool › Usage and billing]` | yes `[sdk]` | skipped (`type == "message"`) | correct |
| `advisor_message`, other model | **no**: "Advisor tokens are not rolled into the top-level totals" `[doc]` | yes `[sdk]` | added as an extra part under that model | correct (F13) |
| `advisor_message`, **same model** | no `[doc]` | yes | **skipped** (`sub != model` fails) | **undercount**: the advisor's tokens are lost. Almost every executor can advise itself; 13 of the 14 executor rows in the pairing table list the executor's own model as a valid advisor `[doc: advisor-tool › model pairs]` |
| `compaction` (server-side compaction) | **no**: "do not include compaction iteration usage… sum across all entries… to calculate total tokens consumed and billed" `[doc: compaction-threshold › Understanding usage]` | **no** `[sdk]` | skipped (no `model`) | **undercount** of compaction tokens, *if* Claude Code uses API compaction and writes these entries `[unknown]` |
| `fallback_message` (server-side fallback) | **not stated** in docs or SDK `[unknown]` | yes `[sdk]` | added if its model differs | **double count if included** in top-level; correct if excluded |

So P11 is **confirmed for the case F13 encodes**: a different-model advisor. The table also shows **two documented gaps** in the same rule (same-model advisor, compaction) and **one open question** (fallback). None can be checked against a real transcript without a consented, redacted record (see the owner's 2026-10-16 note on #10).

### 2.2 Status line (`statusLine` command)

**Delivery:**
- Claude Code runs a user-configured command with session JSON on stdin and shows its stdout `[doc: statusline › How status lines work]`.
- It runs at session start and resume, on each new assistant message, after `/compact`, when the permission mode changes, on an optional `refreshInterval`, **when a `rate_limits` window reaches its `resets_at`**, and when the prompt cache expires. Runs are debounced at 300 ms, and a newer run cancels one in flight `[doc]`.
- **Only while a session runs.** There's no data between sessions `[inference]`.

**Fields relevant to SpanDeck** `[doc: statusline › Available data]`:

| Field | Meaning | Overlap with JSONL |
|---|---|---|
| `rate_limits.five_hour` / `seven_day`: `used_percentage` (0–100), `resets_at` (epoch s) | subscription quota | none: JSONL has no quota |
| `rate_limits.spend_limit.used_percentage`, `used_usd`, `limit_usd` | gateway spend limit; **can exceed 100**; `used_usd` is an estimate, "not a billed amount" | none |
| `context_window.*`, `current_usage` | last API response's counts (input includes cache) | the same counts as the last assistant record's usage `[inference]`, but **without** message or request id |
| `cost.total_cost_usd` | client-side estimate at list price, per session | none (SpanDeck estimates independently) |
| `session_id`, `prompt_id`, `version`, `model.id` | identity and version | `session_id` = transcript file name `[doc]`; `prompt_id` = OTel `prompt.id` `[doc]` |
| `cwd`, `workspace.*` (incl. `repo.owner`/`name`), `transcript_path`, `session_name`, `pr.url`, `worktree.*` | paths, names, repos | **sensitive** under D7: never to be persisted |

**Availability:**
- `rate_limits` appears **"only for claude.ai Pro and Max subscribers, or behind a Claude apps gateway"**, and only after the session's first API response `[doc]`.
- Each window may be absent on its own, and **"Claude Code drops a window once its `resets_at` time passes"** `[doc]`.
- Team and Enterprise seats do have 5-hour and weekly allowances `[doc: costs › Claude for Teams and Enterprise]`, but the status line isn't documented to carry them `[doc]`.

**Settings interaction:**
- One `statusLine` per settings file `[doc: statusline › Manually configure]`. Installing SpanDeck's means **modifying `~/.claude/settings.json`** and coexisting with the user's own command.
- Under managed `allowManagedHooksOnly`, a custom status line "disappears without warning". Under `disableAllHooks`, only a managed one runs `[doc: statusline › Troubleshooting]`.
- Subagent rows have their own `subagentStatusLine`, with `tokenCount` per subagent `[doc: statusline › Subagent status lines]`.

### 2.3 OpenTelemetry (metrics, events, beta traces)

**Enabling:**
- `CLAUDE_CODE_ENABLE_TELEMETRY=1` plus an exporter: `otlp` (gRPC or HTTP to a collector), `prometheus` (scraped from `http://localhost:9464/metrics`) or `console` `[doc: monitoring-usage › Configuration details; Example configurations]`.
- **A repository's `.claude/settings*.json` can't turn it on.** Only managed settings, the shell or user settings can `[doc: › Administrator configuration]`.
- Managed settings can **pin the destination**, removing a developer's endpoints `[doc: › How managed settings lock the OTLP destination]`.

**Metrics:**
- `claude_code.token.usage` (`type` input / output / cacheRead / cacheCreation; `model`; `query_source` main / subagent / auxiliary) and `claude_code.cost.usage` (an estimate; "Cost metrics are approximations") `[doc: › Metrics; Cost monitoring]`.
- Each streaming response is counted once since v2.1.214 `[doc]`.
- Cache creation merges the 5-minute and 1-hour tiers `[doc]`, so the P9 tier split isn't available.

**Events:**
- `claude_code.api_request` carries per-request `input_tokens` (excluding cache), `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd`, `model`, `query_source` and **`request_id`** `[doc: › API request event]`.
- `request_id` is documented to match the transcript's `requestId`, and `message.uuid` to match transcript entries, **but the join is "version-specific rather than a stable contract"** `[doc: › Event correlation attributes]`.
- On Bedrock, `request_id` comes from `x-amzn-requestid` (v2.1.282+) `[doc]`.
- Also available: `compaction` (pre and post tokens) and `subagent_completed` (`total_tokens` is the final request only, not a sum) `[doc]`.

**Privacy:**
- **Every export carries `user.email`, `user.account_uuid`, `user.account_id` and `organization.id` by default** (the account ids can be turned off; email can't) `[doc: › Standard attributes]`.
- Content flags (`OTEL_LOG_USER_PROMPTS`, `OTEL_LOG_ASSISTANT_RESPONSES`, `OTEL_LOG_TOOL_DETAILS`, `OTEL_LOG_TOOL_CONTENT`, `OTEL_LOG_RAW_API_BODIES`) are all off by default. The last one exports entire conversations `[doc]`. SpanDeck must never set any of them.

**Fit with SpanDeck:**
- Receiving OTel means a local listener (an OTLP endpoint) or scraping a port that only **one** Claude Code process can bind (the docs note that only one session binds 9464 on a self-hosted runner).
- ADR D1 rejects a listener unless measured need justifies one. The identity attributes would have to be dropped on receipt `[inference]`.
- OTel is the only documented source with request ids plus a subagent split, which makes it the natural *second* source for D4's cross-source rule. It isn't the first.

### 2.4 Subscription quota (what SpanDeck reads today)

- **`ClaudeLimitsClient`** calls the undocumented `api/oauth/usage` with Claude Code's Keychain OAuth token, opt-in `[code]`. No Anthropic document describes this endpoint, its window semantics, rate limits or latency `[unknown]`.
- **Claude Code's own `/usage`:** when the plan-limit request fails, "most often because the usage endpoint is rate limited", it shows the last bars loaded on this machine **within the past 60 minutes**, with a "Showing last-known usage" note `[doc: costs › When the usage request fails]`. Whether that is the same endpoint is `[unknown]`.
- **Windows:** "rolling five-hour" and weekly `[doc: costs; statusline › Rate limit usage]`. **No document defines a window's start.** `resets_at − 5 h` (`main.swift:148`) stays an assumption `[code]`.
- **Polling and sleep/wake:**
  - SpanDeck polls limits every 60 s and usage every 10 s, and refreshes both on `NSWorkspace.didWakeNotification` `[code: main.swift:42–43, 55–58]`.
  - Nothing documents the endpoint's behaviour across sleep `[unknown]`.
  - A timer that fires late after wake is covered by the wake refresh `[code]`. The first refresh after wake may still fail if the network isn't up yet `[inference]`; nothing in the code retries sooner than the next 60 s tick `[code]`.

### 2.5 Enterprise, Bedrock, Desktop/Cowork

**Teams / Enterprise:**
- Per-seat 5-hour and weekly allowances, shared with chat and Cowork `[doc: costs]`. The status line isn't documented to carry them `[doc]`.
- The organisation's views (spend report, analytics, Enterprise Analytics API) are admin-scoped and need admin keys `[doc]`, so they're out of scope for a local app.
- Usage inside the allowance "isn't metered in dollars" `[doc]`.

**Bedrock (and Agent Platform, Foundry):**
- Billed per token to the cloud account. Spend lives in the cloud billing console, and Anthropic's analytics don't cover it `[doc: costs › Cloud providers]`.
- Models can be addressed by inference-profile IDs (`us.anthropic.…`), **application inference profile ARNs** or Mantle IDs (`anthropic.claude-sonnet-5`) `[doc: amazon-bedrock]`.
- SpanDeck's model-id validation rejects `/` (`Ledger.swift` `modelID`) `[code]`. If a transcript recorded an ARN, those tokens would count under an opaque `unknown#…` model, unpriced. Whether transcripts record the ARN or the resolved id is `[unknown]`.
- `rate_limits` is absent on Bedrock `[doc: only Pro/Max or gateway]`.
- Upstream Headroom PR #1 `[third-party, unmerged, tested on its author's logs only]` claims three things:
  - Bedrock transcripts have message ids `msg_bdrk_…` and usually no `requestId`;
  - Cowork transcripts live under `~/Library/Application Support/Claude*/local-agent-mode-sessions/**/.claude/projects`, with duplicate `audit.jsonl` files beside them;
  - Bedrock usage can be read from CloudWatch through the AWS CLI.

  The CloudWatch path needs AWS credentials and cloud reads, which #10's non-goals exclude. The other two claims would change SpanDeck's coverage (Cowork isn't read today `[code: claudeRoots]`) and dedupe (P4 one-id identity), and need consented verification.

**Desktop / Cowork:**
- Their transcripts follow their own retention rule `[doc]`. Their location isn't in the Claude Code docs `[unknown]`.
- The Cowork OpenTelemetry form in the admin console doesn't apply to the CLI `[doc: monitoring-usage › Administrator configuration]`.

## 3. Capability matrix

`✓` documented and available. `—` documented as absent. `?` undocumented or unknown. "JSONL" means today's parser.

| Metric | Pro / Max | Team / Enterprise | Bedrock / Agent Platform | Offline (no network) | Nested agents |
|---|---|---|---|---|---|
| Token quantities | JSONL ✓ (format internal); OTel ✓ | same | JSONL ✓ (ids, model ids ? §2.5); OTel ✓ | JSONL ✓ (local files) | JSONL: subagent files are read via `/subagents/` but not attributed `[code]`; OTel `query_source` ✓ |
| Estimated API-equivalent cost | SpanDeck estimate ✓ (R6); status line / OTel ✓ (list price or `modelPricing`) | same | same, at *Anthropic* list price, not the Bedrock price (contract §8) | ✓ (built-in prices) | per model ✓ |
| Provider-reported cost | — | — | — (the cloud console isn't read: non-goal) | — | — |
| Actual billed charge | — (*unavailable*, contract §1) | — (admin spend report, out of scope) | — (cloud billing, out of scope) | — | — |
| Quota % and reset | status line ✓ (0–100); endpoint ✓ (unofficial) | status line —; endpoint ? | — | — (stale or unavailable, F-3) | n/a |
| Gateway spend limit | n/a | status line ✓ behind a gateway (may exceed 100) | status line ✓ behind a gateway | — | n/a |
| Context % | status line ✓ | status line ✓ | status line ✓ | ✓ (local) | `subagentStatusLine` `tokenCount` ✓ |
| Session id | JSONL file name ✓, status line ✓, OTel ✓ | same | same | ✓ | subagent ids in file names ✓ |
| Agent / subagent split | OTel ✓; JSONL path only | same | same | — for OTel | OTel `subagent_completed` (final request only) |
| Tool counts | OTel events ✓ (names redacted by default) | same | same | — | ✓ |
| Account dimension | — today (contract §8); OTel carries account ids (sensitive) | same | — | — | — |

**For #81's provisional percent range:** documented subscription windows run 0–100 `[doc]`, which supports 0–100 for the endpoint's session and weekly limits. A gateway spend limit **can exceed 100** `[doc]`. SpanDeck doesn't read spend limits today; if it ever does, that source needs its own range.

## 4. Proposed install, consent and rollback contract (status line and telemetry)

This feeds #4's consent / change-preview / rollback spec; #4 owns the final version.

1. **Off by default, an explicit opt-in per source.** It's separate from the quota-endpoint consent (#15).
2. **Preview:**
   - show the exact JSON change to `~/.claude/settings.json` (user settings only, never project settings);
   - show the command it will run, a SpanDeck-owned, signed helper path;
   - list the data SpanDeck will keep (§5's normalized fields only) and what it drops.
3. **Coexistence:**
   - if a `statusLine` already exists, wrap it: run the user's command, pass stdin through, print its stdout unchanged, and record SpanDeck's copy;
   - never replace it silently, never change `refreshInterval` or `padding`, never touch `subagentStatusLine`.
4. **Write safely:**
   - read, back up (owner-only, excluded from backup like R8 files), write atomically, re-read and verify;
   - refuse when the file isn't valid JSON, is a symlink, or managed settings set `allowManagedHooksOnly` or `disableAllHooks` (the line wouldn't run, §2.2).
5. **Data path:**
   - the helper writes the normalized snapshot to a SpanDeck file (`0600`, in `PrivateDirectory`);
   - no listener, no network;
   - the raw stdin is never written.
6. **Rollback:**
   - turning the source off, *Clear cached usage data*, or uninstalling restores the backed-up `statusLine` (or removes the key if there was none) and deletes the helper's files;
   - a settings file that changed since install is not overwritten. SpanDeck shows the manual step instead.
7. **Telemetry:**
   - SpanDeck **never sets** `CLAUDE_CODE_ENABLE_TELEMETRY` or any `OTEL_LOG_*` flag;
   - if a later slice reads OTel, it does so only from a destination the user already configured, behind its own consent and threat-model review (D1 revisit trigger 1).

## 5. Synthetic examples and normalized output

All values are invented. No field comes from a real session.

**5.1 Status line input** (the shape follows `[doc: statusline › Full JSON schema]`):
```json
{"session_id":"00000000-0000-4000-8000-000000000001","prompt_id":"00000000-0000-4000-8000-0000000000aa",
 "transcript_path":"/Users/example/.claude/projects/-Users-example-proj/00000000-0000-4000-8000-000000000001.jsonl",
 "cwd":"/Users/example/proj","workspace":{"current_dir":"/Users/example/proj","repo":{"host":"github.com","owner":"example","name":"private-repo"}},
 "model":{"id":"claude-test-1","display_name":"Test"},"version":"2.1.300",
 "cost":{"total_cost_usd":0.42},"context_window":{"used_percentage":12,"context_window_size":200000},
 "rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1893456000},"seven_day":{"used_percentage":0,"resets_at":1893888000}}}
```
**Normalized** (ADR D2 quota observations; kept fields only):

| `source` | `limit` | `percent` | `resetsAt` | `observedAt` | status |
|---|---|---|---|---|---|
| `claude.statusline` | `five_hour` | 23.5 | 2030-01-01T00:00:00Z | the helper's write time | observed |
| `claude.statusline` | `seven_day` | **0** (a valid zero) | 2030-01-06T00:00:00Z | same | observed |

- **Dropped at the boundary:** `transcript_path`, `cwd`, `workspace.*`, `session_name`, `pr.*`, `worktree.*` and `cost`.
- **`session_id`:** kept only as an opaque keyed id (D7).
- **Missing windows:** a missing `rate_limits` or window is **unavailable**, never 0 % (contract §4). A window whose `resets_at` has passed is unavailable (§3 stale rule; matches `[doc]` "drops a window once its `resets_at` time passes").
- **Confidence:** documented field, Pro and Max only, fresh only while a session runs.

**5.2 OpenTelemetry `api_request` event** (attributes `[doc]`; the identity values are synthetic):
`{model: "claude-test-1", input_tokens: 100, output_tokens: 10, cache_read_tokens: 30, cache_creation_tokens: 0, cost_usd: 0.0012, request_id: "req_synthetic_01", query_source: "repl_main_thread", user.email: "<dropped>", user.account_uuid: "<dropped>"}`

- **Normalized:** an Observation `{provider: anthropic, source: claude.otel, requestID: req_synthetic_01, model: claude-test-1, counters: input 100, output 10, cacheRead 30}`.
- **Joins:** to F01-style JSONL operations by `requestId` when the documented join holds for that version. Otherwise it is kept as a separate view, never summed (I-7).
- **Confidence:** documented attribute. The join is version-specific `[doc]`.

**5.3 JSONL line with iterations** (the shape is `[inference]` from the API; counters synthetic):
`usage: {input_tokens: 100, output_tokens: 20, iterations: [{type: "message", input_tokens: 100, output_tokens: 20}, {type: "advisor_message", model: "claude-test-1", input_tokens: 50, output_tokens: 5}, {type: "compaction", input_tokens: 40, output_tokens: 8}]}` with top-level `model: "claude-test-1"`.

| Part | Today `[code]` | Per the API docs |
|---|---|---|
| executor | 120 | 120 |
| advisor (same model) | **0**: skipped | 55 |
| compaction | **0**: skipped | 48 |
| total | 120 | **223** |

This is the proposed fixture for the P11 follow-up (§8), as a new F-numbered case beside F13.

## 6. Implications for P10, P11, P15 and F-3

- **P10** (one pair, records under more than one model):
  - Claude Code's automatic and chained model fallbacks *re-run* the request on another model `[doc: model-config › Automatic model fallback; Fallback model chains]`, which makes a new API request `[inference]`, so it shouldn't share a request id.
  - The docs give no mechanism that would re-log one request under another model. H1 and H2 (ADR §D4.1) stay unproven. The bounds proposal is unaffected.
- **P11:** confirmed for different-model advisors. Two documented gaps (same-model advisor, compaction) and one open question (`fallback_message`), §2.1.
- **P15:** the only documented wording is a "rolling five-hour window" with `resets_at`. No source defines its start, and the status line adds nothing beyond `resets_at`. **P15 stays blocked**, and the boundary-uncertain rule (contract §7) remains the safe display.
- **F-3** (stale threshold), two documented behaviours to weigh:
  1. The status line drops a window at its `resets_at`. That matches the accepted stale direction: unavailable after the reset.
  2. Claude Code's own `/usage` shows last-known plan usage for **up to 60 minutes** after a failed fetch, with a note. As a candidate for contract §3's open threshold: *stale with its age for up to 60 minutes and while now < `resets_at`, then unavailable*. Whether that endpoint is the one SpanDeck polls is unknown, so this is an input to the owner's decision, not a decision.

## 7. Decision: the smallest supported adapter to prototype first

**The status line, as a parser-only slice.**

**Why this one:**
- It's the only *documented* source of the quota SpanDeck shows today, and reading it needs no Keychain token. That is #4's credential-free direction.
- It needs no listener. OTel would need a collector or a single-bind scrape port, contrary to D1, and it carries email and account ids by default.

**What the first slice does:**
- Implements a parser and normalizer from the documented schema to quota observations.
- Drops every sensitive field at the boundary.
- **Has no runtime path:** no install, no settings change, no helper.
- **Tests:**
  - synthetic payloads from §5.1;
  - absent and expired windows;
  - valid zero;
  - out-of-range and invalid values;
  - a `PrivacyCanaryTests`-style proof that no dropped field survives.

**What it doesn't do** (stated limits):
- No data between sessions, so it **supplements** the endpoint rather than replacing it, until #4 decides.
- Absent for Team/Enterprise, Bedrock, `allowManagedHooksOnly` and `disableAllHooks`.
- One `statusLine` per file, so it must wrap the user's own.

**Install (slice 2) is gated on #4's contract (§4).**

**Not chosen first:**
- **OTel:** listener, identity payload, managed destination pinning. It's the right *second* source once D4's per-field precedence is written.
- **Bedrock or Cowork paths:** need consented verification of upstream's claims first.

**Implementation ticket (owner approval needed before it's created):**
- *Title:* "[M2][Integrations] Status-line quota parser (no install), synthetic fixtures".
- *Acceptance:*
  - observations match §5.1;
  - sensitive fields never persist (canary test);
  - missing, expired or invalid windows are unavailable;
  - no settings or file writes outside tests.
- *Milestone:* the owner's choice (it feeds M1/M2).

## 8. Follow-ups proposed (none started; owner decides where they live)

1. **P11 iterations (with #7):**
   - count same-model `advisor_message` iterations, and count `compaction` iterations, which have no model and so belong under the top-level model;
   - leave `fallback_message` as is until its semantics are documented;
   - add the §5.3 fixture.

   This changes counted semantics, so it needs a cache version bump (D8, discard and rebuild).
2. **`USAGE_CACHE.md`:** name Claude Code's 30-day `cleanupPeriodDays` sweep and its effect on days 31–32 after a rebuild.
3. **Consented verification**, by the owner on a test account, redacted, never committed:
   - whether transcripts carry `usage.iterations` verbatim;
   - Bedrock message-id and `requestId` shape;
   - whether Bedrock model ids are ARNs;
   - the Cowork transcript location.

## 9. #10 acceptance criteria

| Criterion | Status |
|---|---|
| Versioned source matrix, tested vs documented | §1 and the labels throughout. Nothing is runtime-tested |
| Capability matrix | §3 |
| Install / consent / rollback contract | §4, proposed. #4 owns the final version |
| Synthetic payloads, normalized outputs, confidence | §5 |
| Decision on the smallest adapter, with a separate ticket | §7 decision; ticket awaiting owner approval |

#10 stays open until the owner accepts the decision and the ticket exists.
