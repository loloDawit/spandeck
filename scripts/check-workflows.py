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
  - a step publishes a release (`gh release create|upload`, `gh api …/releases`, or a release action) before an
    earlier step of the same job ran `scripts/verify-release.sh <dmg>` (#11; `--preflight` doesn't count), the gate step
    has `if:`, `continue-on-error:` or `|| true`, or a step between the gate and the publish rebuilds or re-signs;
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

# An invocation with a DMG argument (a path ending .dmg, or a variable); `--preflight` or a mention in text isn't one.
GATE = re.compile(r'(^|[\s;&|(])(\./)?scripts/verify-release\.sh\s+"?(\$|[^\s"]*\.dmg\b)')
PUBLISH = re.compile(r"\bgh\s+release\s+(create|upload)\b|\bgh\s+api\b.*/releases\b|^\s*(-\s+)?uses:\s*[\w.-]+/[\w.-]*release")
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
    """{job: [(first line index, [step lines])]} for each job's `steps:` list."""
    out = {}
    for i, line in enumerate(lines):
        if indent(line) == 0 and line.startswith("jobs:"):
            for j in block(lines, i, 0):
                if indent(lines[j]) == 2 and lines[j].rstrip().endswith(":"):
                    steps = out.setdefault(lines[j].strip()[:-1], [])
                    for k in block(lines, j, 2):
                        if lines[k].strip() == "steps:":
                            items = [m for m in block(lines, k, indent(lines[k])) if lines[m].lstrip().startswith("- ")
                                     and indent(lines[m]) == indent(lines[k]) + 2]
                            for n, m in enumerate(items):
                                end = items[n + 1] if n + 1 < len(items) else (block(lines, k, indent(lines[k])) or [m])[-1] + 1
                                steps.append((m, [s for s in lines[m:end] if s.strip()]))
    return out


def release_safety(lines, bad):
    """#11: publish only after the release gate in the same job, with nothing rebuilt in between."""
    for job, steps in job_steps(lines).items():
        gated_at = None
        for idx, (start, body) in enumerate(steps):
            text = "\n".join(body)
            if GATE.search(text):
                weak = [w for w in ("if:", "continue-on-error:") if any(s.strip().startswith(w) for s in body)]
                if "|| true" in text or "|| :" in text:
                    weak.append("|| true")
                if weak:
                    bad(start + 1, f"release gate step must not have {', '.join(weak)}")
                gated_at = idx
            elif gated_at is not None and REBUILD.search(text) and any(PUBLISH.search(s) for _, b in steps[idx:] for s in b):
                bad(start + 1, f"job {job} changes the build after the release gate and before publishing")
            if any(PUBLISH.search(s) for s in body) and gated_at is None:
                bad(start + 1, f"job {job} publishes without passing scripts/verify-release.sh first")


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
    for job, perms in jobs.items():
        effective = perms if perms is not None else workflow_perms
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
    release_safety(lines, bad)
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
