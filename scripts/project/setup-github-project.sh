#!/usr/bin/env bash
# Sets up SpanDeck's project management on GitHub:
#   - milestones M0–M4 (no due dates), assigned to the existing issues and pull requests
#   - tracking issues for the pending remediations R10 and R11 (only if missing)
#   - sub-issue links: research issues under #2, remediation issues under their research issue
#   - the "SpanDeck — Product Roadmap" project (reused if it exists) with Status, Workstream,
#     Priority and Risk fields, and every issue and PR added once with initial values
#
# Safe to re-run. Existing milestones, parents and project items are left as they are; field values
# are written only for items newly added to the project (pass --reset-fields to rewrite them).
# Views and the project's built-in workflows are set in the web UI; see docs/PROJECT_MANAGEMENT.md.
#
# Needs: gh 2.40+ logged in as a repository admin, with the project scope:
#   gh auth refresh -s project
#   scripts/project/setup-github-project.sh --dry-run   # print the writes, change nothing
#   scripts/project/setup-github-project.sh
# Runs no GitHub Actions and changes no code.
set -euo pipefail

REPO="${SPANDECK_REPO:-loloDawit/spandeck}"
OWNER="${REPO%%/*}"
PROJECT_TITLE="SpanDeck — Product Roadmap"
DRY_RUN=0
RESET_FIELDS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --reset-fields) RESET_FIELDS=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "• $*" >&2; }
warn() { echo "! $*" >&2; }
# Runs a command that changes GitHub; in dry-run mode prints it and outputs nothing.
write() {
  if (( DRY_RUN )); then echo "[dry-run] $*" >&2; else "$@"; fi
}
# GraphQL request whose JSON body ({"query": ..., "variables": ...}) is read from stdin.
gql() { gh api graphql --input - "$@"; }
# Escapes a string for use inside a JSON string literal.
json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }

# ---------------------------------------------------------------------------------------------
# Plan. One row per issue or PR: number|kind|milestone|workstream|priority|status|parent|risk
#  - milestone: the roadmap phase (docs/ROADMAP.md). It is the project's Phase / Target milestone.
#  - priority: P0 now, P1 this milestone, P2 later. Empty for finished work.
#  - parent: issue the row is a sub-issue of. R10 / R11 stand for the issues created below.
# Status reflects main at 3972167 (2026-10-15).
ROWS=(
  "2|issue|M0|Program|P0|In progress||M0 exit: OS-level check, fixtures, performance baseline, ADR and supply-chain plan still open"
  "3|issue|M0|Security|P0|In progress|2|OS-level runtime verification (audit §7 Phase 2) not done; needs a supported Mac"
  "4|issue|M0|Security|P1|In progress|2|"
  "5|issue|M0|Privacy|P1|In progress|2|"
  "6|issue|M0|Accounting|P1|Backlog|2|"
  "7|issue|M0|Accounting|P1|In progress|2|"
  "8|issue|M0|Performance|P1|Backlog|2|No measurements yet; needs supported macOS hardware"
  "9|issue|M0|Architecture|P1|Blocked|2|Waits on findings from #3, #5, #6 and #7 (order set in #2)"
  "10|issue|M0|Integrations|P2|Backlog|2|"
  "11|issue|M0|Release|P1|Backlog|2|Hosted CI not run (budget); no signing or notarization"
  "12|issue|M0|Testing||Done|2|"
  "15|issue|M1|Security||Done|4|"
  "17|issue|M1|Security||Done|4|"
  "19|issue|M1|Security||Done|4|"
  "21|issue|M1|Security||Done|4|"
  "24|issue|M1|Security||Done|4|"
  "27|issue|M1|Security||Done|7|"
  "30|issue|M0|Accounting||Done|7|"
  "33|issue|M1|Privacy|P0|In progress|5|"
  "R10|issue|M1|Privacy|P0|Next|5|"
  "R11|issue|M0|Release|P0|Next|11|"
  "1|pr|M0|Program||Done||"
  "13|pr|M0|Security||Done||"
  "14|pr|M0|Testing||Done||"
  "16|pr|M1|Security||Done||"
  "18|pr|M1|Security||Done||"
  "20|pr|M1|Security||Done||"
  "22|pr|M1|Security||Done||"
  "23|pr|M1|Security||Done||"
  "25|pr|M1|Security||Done||"
  "26|pr|M1|Security||Done||"
  "28|pr|M1|Security||Done||"
  "29|pr|M1|Security||Done||"
  "31|pr|M0|Accounting||Done||"
  "32|pr|M0|Accounting||Done||"
)

MILESTONES=(
  "M0|M0 — Security and accounting baseline|Exit: known risks recorded, core arithmetic regression-tested, first hardening changes planned with measurable acceptance criteria. Tracked in #2."
  "M1|M1 — Privacy-first foundation|Exit: default experience has no unauthorized collection, secrets access, or persistent settings mutations."
  "M2|M2 — Claude observability|Exit: metrics reconcile in defined fixtures; gaps and confidence are visible to the user."
  "M3|M3 — Intelligence and alerts|Exit: low false-positive rate on test scenarios; every alert can be traced to events."
  "M4|M4 — Open-source release readiness|Exit: reproducible release process and documented user data lifecycle."
)

# Option lists: name|color|description. Colors: GRAY BLUE GREEN YELLOW ORANGE RED PINK PURPLE.
STATUS_OPTIONS=(
  "Backlog|GRAY|Accepted, not scheduled yet"
  "Next|BLUE|Pick this up next, in priority order"
  "In progress|YELLOW|Being worked on; branch or draft PR exists"
  "In review|PURPLE|PR open and waiting on review"
  "Blocked|RED|Cannot proceed; reason in the Risk field"
  "Done|GREEN|Closed as completed or PR merged"
)
WORKSTREAM_OPTIONS=(
  "Security|RED|Credentials, permissions, egress"
  "Privacy|PINK|Transcript and cache data minimization, retention"
  "Accounting|GREEN|Tokens, cost, quota provenance and deduplication"
  "Performance|ORANGE|Startup, indexing and steady-state overhead"
  "Architecture|PURPLE|Events, adapters, storage design"
  "Integrations|BLUE|Claude telemetry, status line, Bedrock"
  "Release|YELLOW|CI, supply chain, signing, distribution"
  "Testing|GRAY|Test seams and harnesses"
  "Program|GRAY|Epics and planning"
)
PRIORITY_OPTIONS=(
  "P0|RED|Now: in progress or next up"
  "P1|ORANGE|Needed for the current milestone exit"
  "P2|GRAY|Later; can slip to a following milestone"
)

# ---------------------------------------------------------------------------------------------
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in; run: gh auth login" >&2; exit 1; }
(( DRY_RUN )) && say "dry run: nothing on GitHub will change"

# 1. Milestones ---------------------------------------------------------------------------------
# bash 3.2 (macOS) has no associative arrays: MS_<key> holds the number, MS_TITLE_<key> the title.
for m in "${MILESTONES[@]}"; do
  IFS='|' read -r key title desc <<<"$m"
  n=$(gh api "repos/$REPO/milestones?state=all&per_page=100" \
        --jq ".[] | select(.title | startswith(\"$key \")) | .number" | head -n1)
  if [[ -z "$n" ]]; then
    say "create milestone: $title (no due date)"
    n=$(write gh api "repos/$REPO/milestones" -f title="$title" -f description="$desc" --jq .number)
  fi
  printf -v "MS_$key" '%s' "${n:-}"
  printf -v "MS_TITLE_$key" '%s' "$title"
done

# 2. Tracking issues for pending remediations ----------------------------------------------------
existing_titles=$(gh issue list -R "$REPO" --state all --limit 500 --json number,title \
                    --jq '.[] | "\(.number)\t\(.title)"')
find_issue() { awk -F'\t' -v p="$1" 'index($2, p) == 1 { print $1; exit }' <<<"$existing_titles"; }

R10_BODY=$(cat <<'EOF'
Remediation **R10 (audit priority P2)** from the #3 audit (`docs/audits/0003-security-inventory.md` §8, finding B14). Parent: #5.

## Risk
`--snapshot <dir>` renders the real status strip and popover (limits, usage, cost) into PNG files at any path, then exits.

## Change
Restrict `--snapshot` to debug builds, or make it render a synthetic store only.

## Acceptance criteria
- [ ] In a release configuration the argument writes nothing (ignored, or rejected with a message).
- [ ] Where snapshots remain available, they render synthetic fixtures, never the live ledger or quota state.
- [ ] A test covers the release-configuration behavior; `swift test` and `swift build` results recorded, or the reason they were not run.

## Compatibility and rollback
Release builds lose the snapshot flag. Rollback: revert the commit.
EOF
)
R11_BODY=$(cat <<'EOF'
Remediation **R11 (audit priority P2)** from the #3 audit (`docs/audits/0003-security-inventory.md` §8, finding F6). Parent: #11.

## Risk
Supply chain: workflow actions referenced by mutable tags and no explicit least-privilege `permissions` in `test.yml`; no Developer ID signing or notarization plan.

## Change
- Pin every action in `.github/workflows/*.yml` to a full commit SHA (tag kept as a comment).
- Declare explicit least `permissions` in `test.yml` (and `release.yml` where missing).
- Write the Developer ID signing and notarization plan (document only; no secrets in the repository).

## Acceptance criteria
- [ ] Workflow lint passes locally (for example `actionlint`) and a pin check finds no unpinned `uses:`.
- [ ] Each workflow declares `permissions` explicitly, at the least level its jobs need.
- [ ] Signing / notarization plan reviewed in #11.
- [ ] Hosted CI is not run for this change unless the owner approves it (budget); say so in the PR.

## Compatibility and rollback
No user-facing change until a release. Rollback: revert the workflow change.
EOF
)

for key in R10 R11; do
  n=$(find_issue "$key:")
  if [[ -z "$n" ]]; then
    if [[ $key == R10 ]]; then
      title="R10: restrict --snapshot to debug builds or a synthetic store"; body=$R10_BODY; ms=M1
    else
      title="R11: CI and release hardening (SHA-pinned actions, least permissions, signing plan)"; body=$R11_BODY; ms=M0
    fi
    say "create issue: $title"
    ms_title_var="MS_TITLE_$ms"
    url=$(write gh issue create -R "$REPO" --title "$title" --body "$body" --milestone "${!ms_title_var}")
    n="${url##*/}"
  fi
  printf -v "ISSUE_$key" '%s' "${n:-}"
done
resolve() { if [[ "$1" == R1[01] ]]; then local v="ISSUE_$1"; echo "${!v}"; else echo "$1"; fi; }

# 3. Milestone assignment and sub-issues ---------------------------------------------------------
for row in "${ROWS[@]}"; do
  IFS='|' read -r num kind ms _ _ _ parent _ <<<"$row"
  num=$(resolve "$num"); [[ -z "$num" ]] && continue
  ms_var="MS_$ms"; want="${!ms_var}"
  have=$(gh api "repos/$REPO/issues/$num" --jq '.milestone.number // empty')
  if [[ -z "$have" ]]; then
    say "#$num → milestone $ms"
    write gh api -X PATCH "repos/$REPO/issues/$num" -F milestone="$want" --silent
  elif [[ -n "$want" && "$have" != "$want" ]]; then
    warn "#$num already has another milestone; left unchanged"
  fi

  [[ -z "$parent" ]] && continue
  if gh api "repos/$REPO/issues/$parent/sub_issues?per_page=100" --jq '.[].number' | grep -qx "$num"; then
    continue
  fi
  current=$(gh api "repos/$REPO/issues/$num/parent" --jq '.number' 2>/dev/null || true)
  if [[ -n "$current" ]]; then
    warn "#$num is already a sub-issue of #$current; left unchanged"
    continue
  fi
  say "#$num → sub-issue of #$parent"
  write gh api -X POST "repos/$REPO/issues/$parent/sub_issues" \
    -F sub_issue_id="$(gh api "repos/$REPO/issues/$num" --jq .id)" --silent
done

# 4. Project ------------------------------------------------------------------------------------
owner_id=$(gh api graphql -f query='query($l:String!){user(login:$l){id}}' -f l="$OWNER" --jq .data.user.id)
repo_id=$(gh api "repos/$REPO" --jq .node_id)

say "existing projects for $OWNER:"
gh api graphql -f query='query($l:String!){user(login:$l){projectsV2(first:100){nodes{number title closed url}}}}' \
  -f l="$OWNER" --jq '.data.user.projectsV2.nodes[] | "    #\(.number) \(.title)\(if .closed then " (closed)" else "" end) \(.url)"' >&2

project=$(gh api graphql -f query='query($l:String!){user(login:$l){projectsV2(first:100){nodes{id title url closed}}}}' \
  -f l="$OWNER" --jq ".data.user.projectsV2.nodes[] | select(.title == \"$PROJECT_TITLE\" and (.closed | not)) | \"\(.id) \(.url)\"" | head -n1)
if [[ -z "$project" ]]; then
  say "create project: $PROJECT_TITLE (linked to $REPO)"
  project=$(write gql --jq '.data.createProjectV2.projectV2 | "\(.id) \(.url)"' <<EOF
{"query":"mutation(\$o:ID!,\$t:String!,\$r:ID!){createProjectV2(input:{ownerId:\$o,title:\$t,repositoryId:\$r}){projectV2{id url}}}",
 "variables":{"o":"$owner_id","t":"$(json_str "$PROJECT_TITLE")","r":"$repo_id"}}
EOF
)
fi
if [[ -z "$project" ]]; then
  say "dry run: project steps need the project to exist; stopping here"
  exit 0
fi
project_id="${project%% *}"
project_url="${project#* }"
say "project: $project_url"

write gql --silent <<EOF
{"query":"mutation(\$p:ID!){updateProjectV2(input:{projectId:\$p,shortDescription:\"What is done, in progress, next and blocking a release. Phase = milestone.\",readme:\"See docs/PROJECT_MANAGEMENT.md and docs/ROADMAP.md in loloDawit/spandeck.\"}){projectV2{id}}}",
 "variables":{"p":"$project_id"}}
EOF

fields_tsv() {
  gql --jq '.data.node.fields.nodes[] | select(.name != null) | "\(.name)\t\(.id)\t\(.dataType)\t\([(.options // [])[] | "\(.name)=\(.id)"] | join(";"))"' <<EOF
{"query":"query(\$p:ID!){node(id:\$p){... on ProjectV2{fields(first:50){nodes{... on ProjectV2FieldCommon{id name dataType} ... on ProjectV2SingleSelectField{options{id name}}}}}}}",
 "variables":{"p":"$project_id"}}
EOF
}
options_json() {
  local out="" name color desc
  for o in "$@"; do
    IFS='|' read -r name color desc <<<"$o"
    out+="${out:+,}{\"name\":\"$(json_str "$name")\",\"color\":\"$color\",\"description\":\"$(json_str "$desc")\"}"
  done
  printf '[%s]' "$out"
}
option_names() { local o; for o in "$@"; do printf '%s;' "${o%%|*}"; done; }

ensure_select_field() {   # name, options...
  local name=$1; shift
  local line; line=$(fields_tsv | awk -F'\t' -v n="$name" '$1 == n')
  if [[ -z "$line" ]]; then
    say "create field: $name"
    write gql --silent <<EOF
{"query":"mutation(\$p:ID!,\$n:String!,\$o:[ProjectV2SingleSelectFieldOptionInput!]){createProjectV2Field(input:{projectId:\$p,dataType:SINGLE_SELECT,name:\$n,singleSelectOptions:\$o}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}",
 "variables":{"p":"$project_id","n":"$(json_str "$name")","o":$(options_json "$@")}}
EOF
    return
  fi
  local have want field_id
  field_id=$(cut -f2 <<<"$line")
  have=$(cut -f4 <<<"$line" | tr ';' '\n' | sed 's/=.*//' | tr '\n' ';')
  want=$(option_names "$@")
  [[ "$have" == "$want" ]] && return
  if [[ "$name" == "Status" ]]; then
    say "set Status options: ${want//;/ · }"
    write gql --silent <<EOF || warn "could not update Status options; set them in the web UI (docs/PROJECT_MANAGEMENT.md)"
{"query":"mutation(\$f:ID!,\$o:[ProjectV2SingleSelectFieldOptionInput!]){updateProjectV2Field(input:{fieldId:\$f,singleSelectOptions:\$o}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}",
 "variables":{"f":"$field_id","o":$(options_json "$@")}}
EOF
  else
    warn "field $name exists with different options ($have); left unchanged"
  fi
}
ensure_text_field() {
  if ! fields_tsv | awk -F'\t' -v n="$1" '$1 == n { found = 1 } END { exit !found }'; then
    say "create field: $1"
    write gql --silent <<EOF
{"query":"mutation(\$p:ID!,\$n:String!){createProjectV2Field(input:{projectId:\$p,dataType:TEXT,name:\$n}){projectV2Field{... on ProjectV2Field{id}}}}",
 "variables":{"p":"$project_id","n":"$(json_str "$1")"}}
EOF
  fi
}

ensure_select_field Status "${STATUS_OPTIONS[@]}"
ensure_select_field Workstream "${WORKSTREAM_OPTIONS[@]}"
ensure_select_field Priority "${PRIORITY_OPTIONS[@]}"
ensure_text_field Risk

FIELDS=$(fields_tsv)
field_id() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' <<<"$FIELDS"; }
option_id() {   # field, option
  awk -F'\t' -v n="$1" '$1 == n { print $4 }' <<<"$FIELDS" | tr ';' '\n' | awk -F'=' -v o="$2" '$1 == o { print $2 }'
}

# Numbers already in the project, so a re-run does not overwrite field values edited since.
in_project=$(gql --jq '.data.node.items.nodes[].content.number // empty' <<EOF
{"query":"query(\$p:ID!){node(id:\$p){... on ProjectV2{items(first:100){nodes{content{... on Issue{number} ... on PullRequest{number}}}}}}}",
 "variables":{"p":"$project_id"}}
EOF
)

set_select() {   # item, field, option
  [[ -z "$3" ]] && return
  local f o; f=$(field_id "$2"); o=$(option_id "$2" "$3")
  if [[ -z "$f" || -z "$o" ]]; then warn "no $2 option \"$3\"; skipped"; return; fi
  write gql --silent <<EOF
{"query":"mutation(\$p:ID!,\$i:ID!,\$f:ID!,\$o:String!){updateProjectV2ItemFieldValue(input:{projectId:\$p,itemId:\$i,fieldId:\$f,value:{singleSelectOptionId:\$o}}){projectV2Item{id}}}",
 "variables":{"p":"$project_id","i":"$1","f":"$f","o":"$o"}}
EOF
}
set_text() {   # item, field, text
  [[ -z "$3" ]] && return
  write gql --silent <<EOF
{"query":"mutation(\$p:ID!,\$i:ID!,\$f:ID!,\$t:String!){updateProjectV2ItemFieldValue(input:{projectId:\$p,itemId:\$i,fieldId:\$f,value:{text:\$t}}){projectV2Item{id}}}",
 "variables":{"p":"$project_id","i":"$1","f":"$(field_id "$2")","t":"$(json_str "$3")"}}
EOF
}

for row in "${ROWS[@]}"; do
  IFS='|' read -r num kind _ workstream priority status _ risk <<<"$row"
  num=$(resolve "$num"); [[ -z "$num" ]] && continue
  if grep -qx "$num" <<<"$in_project" && (( ! RESET_FIELDS )); then
    continue
  fi
  if [[ $kind == pr ]]; then
    content_id=$(gh api "repos/$REPO/pulls/$num" --jq .node_id)
  else
    content_id=$(gh api "repos/$REPO/issues/$num" --jq .node_id)
  fi
  say "#$num → project: $status / $workstream${priority:+ / $priority}"
  item_id=$(write gql --jq .data.addProjectV2ItemById.item.id <<EOF
{"query":"mutation(\$p:ID!,\$c:ID!){addProjectV2ItemById(input:{projectId:\$p,contentId:\$c}){item{id}}}",
 "variables":{"p":"$project_id","c":"$content_id"}}
EOF
)
  [[ -z "$item_id" ]] && continue
  set_select "$item_id" Status "$status"
  set_select "$item_id" Workstream "$workstream"
  set_select "$item_id" Priority "$priority"
  set_text "$item_id" Risk "$risk"
done

say "done. Next: create the four views and enable the built-in workflows (docs/PROJECT_MANAGEMENT.md)."
echo "$project_url"
