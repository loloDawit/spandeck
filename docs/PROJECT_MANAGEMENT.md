# Project management

Where SpanDeck's work is tracked, and how to keep that tracking accurate with little effort.

## Sources of truth

| Question | Where | Kept current by |
|---|---|---|
| What state is each item in? | GitHub Project **SpanDeck — Product Roadmap** ([repository Projects tab](https://github.com/loloDawit/spandeck/projects)) | Built-in workflows (closed / merged → Done), plus moving cards by hand |
| Which phase is it in? | GitHub Milestones `M0` … `M4` | Set once, when an issue or PR is opened |
| What does a phase mean, and in what order? | [`ROADMAP.md`](ROADMAP.md) | Updated when a milestone's scope or status changes, not on every PR |
| What remains for a research issue? | The issue's acceptance checklist, with its sub-issues | Whoever completes a checklist item |
| Remediation details (R1–R12) | [`audits/0003-security-inventory.md`](audits/0003-security-inventory.md) §8 | The remediation PR |

The roadmap document records a dated snapshot. When it disagrees with the Project, the Project is right.

## Structure

- **Milestones = phases.** `M0 — Security and accounting baseline`, `M1 — Privacy-first foundation`, `M2 — Claude observability`, `M3 — Intelligence and alerts`, `M4 — Open-source release readiness`. None has a due date. Dates are added only when the owner commits to one. The milestone is the project's **Phase** and **Target milestone**: one native field, so the two cannot disagree.
- **Epic → research → remediation.** #2 (M0 epic) has research issues #3–#12 as sub-issues. Remediation issues (R-numbers) are sub-issues of the research issue that found them: R1–R5 and R9 under #4, R6–R7 under #7, R8 and R10 under #5, R11 under #11. Parent issues show their sub-issues' progress natively.
- **Research issues stay open** until every acceptance criterion is met, even when all their remediation sub-issues are closed. Remediation PRs say `Refs #<research issue>` and `Closes #<remediation issue>`, never `Closes #<research issue>`.
- **PRs are items too.** Each merged PR is in the project as Done, under the same milestone as its issue. Count progress by issues, not by PRs; the Roadmap view filters to issues.

## Project fields

| Field | Type | Values | Meaning |
|---|---|---|---|
| Status | single select (built-in) | Backlog · Next · In progress · In review · Blocked · Done | Backlog: accepted, not scheduled. Next: take these first, P0 before P1. In progress: a branch or draft PR exists and someone owns it. In review: PR ready for review. Blocked: cannot proceed; the reason is in **Risk**. Done: closed as completed or merged. |
| Milestone | built-in | M0 … M4 | Phase / target milestone (see above). |
| Workstream | single select | Security · Privacy · Accounting · Performance · Architecture · Integrations · Release · Testing · Program | Area of the product. |
| Priority | single select | P0 · P1 · P2 | P0: now or next up. P1: needed for the current milestone's exit. P2: later; may slip a milestone. Empty on finished work. This is scheduling order, not the audit's severity rating. |
| Risk | text | free text, one line | What blocks the item or puts a release at risk. Empty when nothing does. |

Labels are not used for any of these, so nothing is tracked twice. The default repository labels remain for ad-hoc use.

## Views

Views are created in the web UI; the GitHub API cannot create them.

| View | Layout | Filter | Group / columns | Sort | Answers |
|---|---|---|---|---|---|
| **Execution Board** | Board | `-status:Done` | Columns by Status; field sum off; card fields Priority, Workstream, Milestone, Linked pull requests | Priority ↑ | What's being worked on, and what's next? |
| **Roadmap** | Table | `is:issue` | Group by Milestone; columns Status, Priority, Workstream, Sub-issues progress, Parent issue, Risk | Priority ↑, then Status | How far along is each phase? |
| **Risks / Blockers** | Table | `is:open has:risk` (if your project rejects it, use `is:open status:Blocked`) | Group by Status; columns Risk, Priority, Milestone, Workstream | Priority ↑ | What's preventing a release? |
| **Completed** | Table | `status:Done` | Group by Milestone; columns Type, Linked pull requests, Workstream | Number ↓ | What's done? |

The Roadmap view is a table grouped by milestone rather than a timeline, because there are no committed dates. Switch it to the Roadmap layout once milestones get due dates.

## Built-in workflows

Project → ⋯ → **Workflows**. These keep the board current without manual updates:

- **Auto-add to project:** repository `loloDawit/spandeck`, filter `is:issue,pr is:open`.
- **Item added to project:** set Status to **Backlog**.
- **Item closed:** set Status to **Done**.
- **Pull request merged:** set Status to **Done**.
- **Item reopened:** set Status to **Backlog**.
- **Auto-archive items:** leave off, so the Completed view keeps history.

All of these run inside GitHub Projects; none uses GitHub Actions minutes.

## Setting it up

[`scripts/project/setup-github-project.sh`](../scripts/project/setup-github-project.sh) does everything the API allows:

- creates milestones M0–M4 and assigns every existing issue and PR to one;
- creates the R10 and R11 tracking issues if they don't exist yet;
- links the sub-issues;
- creates or reuses the project, with its fields, items and initial values.

It is safe to re-run. It does not overwrite a milestone, parent or field value that is already set; `--reset-fields` rewrites the field values.

```sh
gh auth refresh -s project                          # once: grants the project scope
scripts/project/setup-github-project.sh --dry-run   # review what would change
scripts/project/setup-github-project.sh
```

Then create the four views and turn on the workflows above. That is about five minutes in the browser.

## Day-to-day rules

1. **New work starts as an issue**, with acceptance criteria and a milestone. Auto-add puts it in Backlog; set Workstream and Priority.
2. **Starting work:** assign yourself and move the item to In progress. Only one owner per item. Don't start on something that is In progress or assigned to someone else.
3. **Opening a PR:** give it the issue's milestone and link the issue (`Closes #n` for remediation or bug issues, `Refs #n` for research issues). Move it to In review when it's ready.
4. **Blocked:** set Status to Blocked and write the reason in Risk. Clear Risk when it no longer applies.
5. **Finishing:** merging and closing move items to Done automatically. Tick the research issue's acceptance checkbox in the same PR, or right after it.
6. **Roadmap document:** update [`ROADMAP.md`](ROADMAP.md) when a milestone's scope, order or exit status changes, or when a priority changes. Not for every PR.
