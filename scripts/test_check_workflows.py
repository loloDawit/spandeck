#!/usr/bin/env python3
"""Self-test for check-workflows.py (R11). Synthetic workflows in a temp dir; no network.

Run: python3 -I scripts/test_check_workflows.py
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "check-workflows.py"
REPO_WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"
SHA = "fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"

TEST = f"""name: Tests
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@{SHA} # v5.1.0
        with:
          persist-credentials: false
      - name: Run tests
        run: swift test
"""

RELEASE = f"""name: Release
on:
  workflow_dispatch:
    inputs:
      tag:
        required: true
permissions: {{}}
jobs:
  release:
    runs-on: macos-15
    permissions:
      contents: write
    env:
      TAG: ${{{{ inputs.tag }}}}
    steps:
      - uses: actions/checkout@{SHA} # v5.1.0
        with:
          ref: ${{{{ inputs.tag }}}}
          persist-credentials: false
      - name: Publish
        env:
          GH_TOKEN: ${{{{ github.token }}}}
        run: |
          gh release view "$TAG"
"""


class CheckerTests(unittest.TestCase):
    def run_checker(self, files):
        with tempfile.TemporaryDirectory() as d:
            for name, text in files.items():
                (Path(d) / name).write_text(text)
            r = subprocess.run([sys.executable, "-I", str(SCRIPT), d], capture_output=True, text=True)
            return r.returncode, r.stderr

    def assert_rejected(self, files, needle):
        code, err = self.run_checker(files)
        self.assertNotEqual(code, 0, f"accepted; expected {needle!r}")
        self.assertIn(needle, err)

    def test_repository_workflows_pass(self):
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), str(REPO_WORKFLOWS)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_good_fixtures_pass(self):
        self.assertEqual(self.run_checker({"test.yml": TEST, "release.yml": RELEASE}), (0, ""))

    def test_mutable_or_short_refs_rejected(self):
        for ref in ("actions/checkout@v5", "actions/checkout@main", f"actions/checkout@{SHA[:7]}",
                    f"actions/checkout@{SHA.upper()}"):
            self.assert_rejected({"test.yml": TEST.replace(f"actions/checkout@{SHA}", ref)}, "not pinned")

    def test_pin_needs_version_comment(self):
        self.assert_rejected({"test.yml": TEST.replace(" # v5.1.0", "")}, "no '# <version>' comment")

    def test_permissions_required_and_exact(self):
        self.assert_rejected({"test.yml": TEST.replace("permissions:\n  contents: read\n", "")}, "no top-level permissions")
        for broader in ("permissions: write-all\n", "permissions: read-all\n",
                        "permissions:\n  contents: write\n", "permissions:\n  contents: read\n  actions: write\n"):
            self.assert_rejected({"test.yml": TEST.replace("permissions:\n  contents: read\n", broader)}, "policy is")
        # Release: write access moved up to the workflow (a new job would inherit it), or widened on the job.
        self.assert_rejected({"release.yml": RELEASE.replace("permissions: {}", "permissions:\n  contents: write")},
                             "top-level permissions")
        self.assert_rejected({"release.yml": RELEASE.replace("      contents: write\n",
                                                             "      contents: write\n      packages: write\n")},
                             "policy is")

    def test_checkout_must_not_persist_credentials(self):
        self.assert_rejected({"test.yml": TEST.replace("        with:\n          persist-credentials: false\n", "")},
                             "persist-credentials")

    def test_expressions_not_allowed_in_scripts(self):
        self.assert_rejected({"release.yml": RELEASE.replace('gh release view "$TAG"', 'gh release view "${{ inputs.tag }}"')},
                             "inside a run: script")

    def test_pull_request_target_rejected(self):
        self.assert_rejected({"test.yml": TEST.replace("  pull_request:\n", "  pull_request_target:\n")},
                             "pull_request_target")

    def test_unknown_workflow_or_job_rejected(self):
        self.assert_rejected({"deploy.yml": TEST}, "not in the workflow policy")
        self.assert_rejected({"test.yml": TEST.replace("  test:\n", "  lint:\n")}, "job lint is not in the workflow policy")

    def test_docker_images_need_digest(self):
        step = "      - uses: docker://alpine:3.20\n"
        self.assert_rejected({"test.yml": TEST.replace("      - name: Run tests\n", step + "      - name: Run tests\n")},
                             "docker image not pinned")


if __name__ == "__main__":
    unittest.main()
