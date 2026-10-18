#!/usr/bin/env python3
"""Checks the GitHub Actions workflows against SpanDeck's hardening policy (R11). Standard library only.

Usage: python3 -I scripts/check-workflows.py [WORKFLOW_DIR]   (default: .github/workflows next to this script)

Fails (exit 1, one line per problem) when:
  - a `uses:` reference is not pinned to a full 40-character commit SHA with a `# <version>` comment
    (local `./` actions and `docker://...@sha256:<64 hex>` images are allowed);
  - a workflow has no top-level `permissions:`, or any job's effective permissions differ from POLICY below
    (`read-all` / `write-all` never match);
  - an `actions/checkout` step doesn't set `persist-credentials: false`;
  - a `run:` script contains `${{ ... }}` (pass values through `env:` instead, to avoid script injection);
  - `github.token` or `secrets.` appears outside a step (a workflow- or job-level `env:` hands it to every step);
  - a workflow uses `pull_request_target`;
  - a workflow file isn't listed in POLICY (new workflows need a reviewed entry);
  - release safety (#11), in a job that can write: a step that is given the token or a secret, uses an action other
    than actions/checkout, or publishes (`gh release create|upload|edit`, `gh api …/releases`, the uploads API) comes
    before the release gate; the gate isn't exactly `run: scripts/verify-release.sh "build/<name>.dmg"` with only
    `name`, `id` and a `SPANDECK_TEAM_ID` env (no `if:`, `continue-on-error:`, `shell:`, `working-directory:`, wrapper
    or trailing command); a step after it isn't the upload of the verified bytes (`shasum -a 256 -c` against
    `steps.<gate id>.outputs.sha256`); a step runs after a failure (`always()`, `failure()`, `cancelled()`); or
    something rebuilds or re-signs between the gate and the upload;
  - a publishing command sits where this checker can't see it as a step, or a workflow uses YAML anchors/aliases or
    `defaults:` (which could change how every step, the gate included, runs);
  - any workflow tells users to bypass Gatekeeper (Open Anyway, removing the quarantine attribute, disabling spctl).

It reads only the YAML subset these workflows use (block mappings, `- ` lists, `|` scripts); it is a policy
check, not a YAML parser. `scripts/test_check_workflows.py` tests it. actionlint checks general correctness.
"""
import re
import sys
from pathlib import Path

# Exact token permissions per workflow: the top-level default (WORKFLOW, which a new job would inherit) and each
# job's effective permissions. Widening any of them is a reviewed change to this table.
WORKFLOW = "(workflow)"
POLICY = {
    "test.yml": {WORKFLOW: {"contents": "read"}, "test": {"contents": "read"}},
    "release.yml": {WORKFLOW: {}, "release": {"contents": "write"}},
}

# Any attempt to run the gate on an artifact (`--preflight` or a mention in quoted text isn't one) ...
GATE = re.compile(r'(^|[\s;&|(!])(\./)?scripts/verify-release\.sh\s+(?!--preflight\b)[^\s"]*"?(\$|[^\s"]*\.dmg\b)')
# ... and its one accepted form: the script itself, one quoted DMG under build/, nothing before or after it.
GATE_RUN = re.compile(r'^run:\s+(\./)?scripts/verify-release\.sh\s+"build/[\w.${}#-]+\.dmg"$')
GATE_KEYS, GATE_ENV = {"name", "id", "env", "run"}, {"SPANDECK_TEAM_ID"}
PUBLISH = re.compile(r"\bgh\s+release\s+(create|upload|edit)\b|\bgh\s+api\b.*/releases\b|uploads\.github\.com|"
                     r"api\.github\.com/repos/\S*/releases\b")
PRIVILEGED = re.compile(r"github\.token|secrets\.|GITHUB_TOKEN")
AFTER_FAILURE = re.compile(r"\b(always|failure|cancelled)\s*\(")
HASH_CHECK = re.compile(r"\bshasum\s+-a\s+256\s+-c\b")
ANCHOR = re.compile(r"(^|[\s\[{,])&[\w-]+(\s|$)|(^|[\s\[{,:-])\*[\w-]+\s*$|<<\s*:")
REBUILD = re.compile(r"\bbuild\.sh\b|\bcodesign\b|\bhdiutil\b|\bswift\s+build\b")
# Removing an attribute (-d) or all of them (-c) with xattr; reading one (-p, -l, -r alone) is fine.
BYPASS = re.compile(r"open anyway|\bxattr\s+(-[a-z]*\s+)*-[a-z]*[dc]|spctl\s+--(master|global)-disable", re.I)
PINNED = re.compile(r"^[\w.-]+/[\w.-]+(/[\w./-]+)?@[0-9a-f]{40}$")
DOCKER = re.compile(r"^docker://[^@\s]+@sha256:[0-9a-f]{64}$")


def indent(line):
    return len(line) - len(line.lstrip(" "))


def strip_comment(value):
    """Splits `value # comment` into (value, comment)."""
    m = re.match(r"^(.*?)\s+#\s*(.*)$", value)
    return (m.group(1).strip(), m.group(2).strip()) if m else (value.strip(), "")


def unquote(v):
    return v[1:-1] if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"" else v


def block(lines, start, parent_indent):
    """Indices of the lines nested under lines[start] (indented deeper than parent_indent)."""
    out = []
    for i in range(start + 1, len(lines)):
        if lines[i].strip() == "" or lines[i].lstrip().startswith("#"):
            continue
        if indent(lines[i]) <= parent_indent:
            break
        out.append(i)
    return out


def in_step(lines, i):
    """Whether lines[i] is inside a `- ` list item under a `steps:` key."""
    level = indent(lines[i])
    for k in range(i, -1, -1):
        if not lines[k].strip() or lines[k].lstrip().startswith("#"):
            continue
        if indent(lines[k]) < level or (k == i and lines[k].lstrip().startswith("- ")):
            text = lines[k].strip()
            if text.startswith("- "):
                # The list must belong to `steps:`, the nearest less-indented key above it.
                for m in range(k - 1, -1, -1):
                    if lines[m].strip() and indent(lines[m]) < indent(lines[k]):
                        return lines[m].strip() == "steps:"
                return False
            level = indent(lines[k])
    return False


def permissions_at(lines, i):
    """The permissions mapping declared at lines[i] (`permissions: ...`), as a dict or a string."""
    value, _ = strip_comment(lines[i].split(":", 1)[1])
    if value == "{}":
        return {}
    if value:
        return value  # read-all, write-all, or something unexpected
    perms = {}
    for j in block(lines, i, indent(lines[i])):
        k, v = lines[j].strip().split(":", 1)
        perms[k.strip()] = strip_comment(v)[0]
    return perms


def job_steps(lines):
    """{job: [(first line index, [line indices])]} for each job's `steps:` list (items two spaces deeper than the key)."""
    out = {}
    for i, line in enumerate(lines):
        if indent(line) == 0 and line.startswith("jobs:"):
            for j in block(lines, i, 0):
                if indent(lines[j]) == 2 and lines[j].rstrip().endswith(":"):
                    steps = out.setdefault(lines[j].strip()[:-1], [])
                    for k in block(lines, j, 2):
                        if lines[k].strip() == "steps:":
                            inner = block(lines, k, indent(lines[k]))
                            items = [m for m in inner if lines[m].lstrip().startswith("- ")
                                     and indent(lines[m]) == indent(lines[k]) + 2]
                            for n, m in enumerate(items):
                                end = items[n + 1] if n + 1 < len(items) else inner[-1] + 1
                                steps.append((m, [x for x in range(m, end) if lines[x].strip()]))
    return out


def step_keys(lines, start, idx):
    """The step's keys, the env names it sets, and its key lines, for the step whose `- ` item is lines[start]."""
    level = indent(lines[start]) + 2
    keys, env, key_lines = [], [], {}
    for x in idx:
        text = lines[x].strip()
        if x == start:
            text = text[2:].strip()
        elif indent(lines[x]) != level or text.startswith("#"):
            continue
        m = re.match(r"^([\w-]+):", text)
        if m:
            keys.append(m.group(1))
            key_lines[m.group(1)] = text
    if "env" in key_lines:
        env_line = next(x for x in idx if re.match(r"^(-\s+)?env:", lines[x].strip()))
        env = [lines[x].strip().split(":", 1)[0] for x in block(lines, env_line, indent(lines[env_line]))]
    return keys, env, key_lines


def release_safety(lines, bad, writers):
    """#11: in a job that can write, nothing gets the token or publishes before the gate passed, the gate has its one
    fixed form, and what follows it uploads the verified bytes. Publishing outside a parsable step is refused too."""
    covered = set()
    for job, steps in job_steps(lines).items():
        writer = job in writers
        gate_id, gated = None, False
        for n, (start, idx) in enumerate(steps):
            covered.update(idx)
            body = [lines[x] for x in idx if not lines[x].strip().startswith("#")]
            text = "\n".join(body)
            keys, env, key_lines = step_keys(lines, start, idx)
            uses = key_lines.get("uses", "")
            if writer and AFTER_FAILURE.search(key_lines.get("if", "")):
                bad(start + 1, f"job {job}: a step runs after a failed step; a failed release gate must stop the job")
            if GATE.search(text):
                problems = [k for k in keys if k not in GATE_KEYS] + [f"env {e}" for e in env if e not in GATE_ENV]
                if "id" not in keys:
                    problems.append("no id")
                if not GATE_RUN.match(key_lines.get("run", "")):
                    problems.append("a run: other than the script and one quoted build/*.dmg")
                if problems:
                    bad(start + 1, "release gate step must be exactly `run: scripts/verify-release.sh \"build/<name>.dmg\"` "
                                   f"with only name, id and env SPANDECK_TEAM_ID; found {', '.join(problems)}")
                else:
                    gate_id, gated = key_lines["id"].split(":", 1)[1].strip(), True
                continue
            publishes = any(PUBLISH.search(b) for b in body)
            action = bool(uses) and not re.match(r"^uses:\s*actions/checkout@", uses)
            privileged = publishes or (writer and (action or PRIVILEGED.search(text)))
            if privileged and not gated:
                bad(start + 1, f"job {job}: a step that publishes or holds the token runs before passing scripts/verify-release.sh")
            elif privileged and (not HASH_CHECK.search(text) or f"steps.{gate_id}.outputs.sha256" not in text):
                bad(start + 1, f"job {job}: a step after the gate publishes without checking the verified hash "
                               f"(shasum -a 256 -c against steps.{gate_id}.outputs.sha256)")
            elif gated and REBUILD.search(text) and any(
                    PUBLISH.search(lines[x]) or PRIVILEGED.search(lines[x]) for _, later in steps[n + 1:] for x in later):
                bad(start + 1, f"job {job} changes the build after the release gate and before publishing")
    for i, line in enumerate(lines):
        if i not in covered and not line.strip().startswith("#") and PUBLISH.search(line):
            bad(i + 1, "publishing command outside a step this checker can parse")


def run_bodies(lines):
    """Line indices that are `run:` values or inside `run: |` scripts (shell text, not YAML)."""
    out = set()
    for i, line in enumerate(lines):
        r = re.match(r"^(\s*)(-\s+)?run:", line)
        if r:
            out.add(i)
            out.update(block(lines, i, len(r.group(1)) + (2 if r.group(2) else 0)))
    return out


def check(path, policy):
    name = path.name
    text = path.read_text()
    lines = text.splitlines()
    problems = []

    def bad(lineno, msg):
        problems.append(f"{name}:{lineno}: {msg}")

    if name not in policy:
        return [f"{name}: not in the workflow policy; add a reviewed entry to scripts/check-workflows.py"]
    if re.search(r"^\s*pull_request_target\s*:", text, re.M) or re.search(r"\bpull_request_target\b", text):
        bad(0, "pull_request_target is not allowed")

    # Top-level permissions and jobs.
    workflow_perms, jobs = None, {}
    for i, line in enumerate(lines):
        if indent(line) == 0 and line.startswith("permissions:"):
            workflow_perms = permissions_at(lines, i)
        if indent(line) == 0 and line.startswith("jobs:"):
            for j in block(lines, i, 0):
                if indent(lines[j]) == 2 and lines[j].rstrip().endswith(":"):
                    job = lines[j].strip()[:-1]
                    jobs[job] = None
                    for k in block(lines, j, 2):
                        if indent(lines[k]) == 4 and lines[k].strip().startswith("permissions:"):
                            jobs[job] = permissions_at(lines, k)
    expected = policy[name]
    if workflow_perms is None:
        bad(0, "no top-level permissions: block")
    elif workflow_perms != expected[WORKFLOW]:
        bad(0, f"top-level permissions {workflow_perms!r}, policy is {expected[WORKFLOW]!r}")
    writers = set()
    for job, perms in jobs.items():
        effective = perms if perms is not None else workflow_perms
        if isinstance(effective, str) or any(v != "read" for v in (effective or {}).values()):
            writers.add(job)
        if job not in expected:
            bad(0, f"job {job} is not in the workflow policy")
        elif effective != expected[job]:
            bad(0, f"job {job} has permissions {effective!r}, policy is {expected[job]!r}")
    for job in expected:
        if job != WORKFLOW and job not in jobs:
            bad(0, f"policy job {job} not found")

    # uses:, checkout credentials, and expressions inside run: scripts.
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)(-\s+)?uses:\s*(.*)$", line)
        if m:
            ref, comment = strip_comment(m.group(3))
            ref = unquote(ref)
            if ref.startswith("./"):
                pass
            elif ref.startswith("docker://"):
                if not DOCKER.match(ref):
                    bad(i + 1, f"docker image not pinned by sha256 digest: {ref}")
            elif not PINNED.match(ref):
                bad(i + 1, f"action not pinned to a full commit SHA: {ref}")
            elif not re.match(r"^v?\d", comment):
                bad(i + 1, f"pinned action has no '# <version>' comment: {ref}")
            if ref.startswith("actions/checkout@"):
                step_indent = len(m.group(1))
                step = [lines[k].strip() for k in block(lines, i, step_indent)]
                if "persist-credentials: false" not in step:
                    bad(i + 1, "actions/checkout without persist-credentials: false")
        if "github.token" in line or "secrets." in line:
            if not in_step(lines, i):
                bad(i + 1, "token or secret outside a step; give it only to the step that needs it")
        r = re.match(r"^(\s*)(-\s+)?run:\s*(.*)$", line)
        if r:
            body = [r.group(3)] + [lines[k] for k in block(lines, i, len(r.group(1)))]
            if any("${{" in b for b in body):
                bad(i + 1, "${{ }} inside a run: script; pass it through env: instead")
        if BYPASS.search(line):
            bad(i + 1, "Gatekeeper bypass instruction; ship a notarized build instead (#11)")
    shell = run_bodies(lines)
    for i, line in enumerate(lines):
        if line.strip().startswith("#") or i in shell:
            continue
        if ANCHOR.search(line):
            bad(i + 1, "YAML anchors and aliases aren't allowed: this checker can't follow them")
        if indent(line) in (0, 4) and line.strip().startswith("defaults:"):
            bad(i + 1, "defaults: isn't allowed: it changes the shell or directory of every step, the release gate included")
    release_safety(lines, bad, writers)
    return problems


def main(argv):
    folder = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent.parent / ".github" / "workflows"
    files = sorted(list(folder.glob("*.yml")) + list(folder.glob("*.yaml")))
    if not files:
        print(f"no workflows found in {folder}", file=sys.stderr)
        return 1
    problems = [p for f in files for p in check(f, POLICY)]
    for p in problems:
        print(p, file=sys.stderr)
    if not problems:
        print(f"workflow policy OK: {', '.join(f.name for f in files)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
