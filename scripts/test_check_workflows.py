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


PREFLIGHT_STEP = """      - name: Release signing configured
        env:
          SPANDECK_TEAM_ID: ${{ vars.SPANDECK_TEAM_ID }}
        run: scripts/verify-release.sh --preflight
"""
BUILD_STEP = """      - name: Build DMG
        run: ./build.sh dmg
"""
GATE_STEP = """      - name: Verify release
        id: verify
        env:
          SPANDECK_TEAM_ID: ${{ vars.SPANDECK_TEAM_ID }}
        run: scripts/verify-release.sh "build/SpanDeck-${TAG#v}.dmg"
"""
PUBLISH_STEP = """      - name: Publish
        env:
          GH_TOKEN: ${{ github.token }}
          DMG_SHA256: ${{ steps.verify.outputs.sha256 }}
        run: |
          art="$(mktemp -d)/SpanDeck-${TAG#v}.dmg"
          cp "build/SpanDeck-${TAG#v}.dmg" "$art"
          echo "$DMG_SHA256  $art" | shasum -a 256 -c -
          gh release create "$TAG" "$art"
"""
RELEASE_HEAD = RELEASE[:RELEASE.index("      - name: Publish\n")]
GATED = RELEASE_HEAD + PREFLIGHT_STEP + BUILD_STEP + GATE_STEP + PUBLISH_STEP
# A step that publishes in a way a text match for `gh release` misses; it holds the token, so it is privileged.
SNEAKY_STEP = """      - name: Notes
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          g=gh; "$g" 'release' create "$TAG" build/x.dmg
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
        self.assertEqual(self.run_checker({"test.yml": TEST, "release.yml": GATED}), (0, ""))

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

    def test_token_only_in_steps(self):
        job_env = RELEASE.replace("    env:\n      TAG:", "    env:\n      GH_TOKEN: ${{ github.token }}\n      TAG:")
        self.assert_rejected({"release.yml": job_env}, "outside a step")
        workflow_env = RELEASE.replace("permissions: {}\n", "permissions: {}\nenv:\n  T: ${{ secrets.X }}\n")
        self.assert_rejected({"release.yml": workflow_env}, "outside a step")

    def test_pull_request_target_rejected(self):
        self.assert_rejected({"test.yml": TEST.replace("  pull_request:\n", "  pull_request_target:\n")},
                             "pull_request_target")

    def test_unknown_workflow_or_job_rejected(self):
        self.assert_rejected({"deploy.yml": TEST}, "not in the workflow policy")
        self.assert_rejected({"test.yml": TEST.replace("  test:\n", "  lint:\n")}, "job lint is not in the workflow policy")

    # Release safety (#11): in a job that can write, nothing touches the token or publishes unless the release gate passed
    # first in that job, in its one fixed form, and the upload checks the bytes the gate verified.
    def test_gated_release_passes(self):
        self.assertEqual(self.run_checker({"release.yml": GATED}), (0, ""))

    def test_ordinary_steps_still_accepted(self):
        # Comments and notes may mention publishing; read-only jobs may use other actions; globs aren't YAML aliases.
        notes = ('      - name: Notes\n        run: |\n          # gh release create happens later, after the gate\n'
                 '          echo "checked by scripts/verify-release.sh before upload" > notes.md\n          ls build/*.dmg\n')
        self.assertEqual(self.run_checker({"release.yml": GATED.replace(GATE_STEP, notes + GATE_STEP)}), (0, ""))
        cache = f"      - uses: actions/cache@{SHA} # v4.2.0\n        with:\n          path: .build\n"
        self.assertEqual(self.run_checker({"test.yml": TEST.replace("      - name: Run tests\n", cache + "      - name: Run tests\n")}),
                         (0, ""))

    def test_publish_without_gate_rejected(self):
        # The configuration preflight (still present here) verifies no artifact, so it doesn't count as the gate.
        self.assert_rejected({"release.yml": GATED.replace(GATE_STEP, "")}, "before passing scripts/verify-release.sh")
        # Nor does a mention in text, such as release notes naming the script.
        mention = "      - name: Notes\n        run: echo \"checked by scripts/verify-release.sh before upload\"\n"
        self.assert_rejected({"release.yml": GATED.replace(GATE_STEP, mention)}, "before passing")
        for publish in ('gh release upload "$TAG" x.dmg --clobber', "gh api repos/o/r/releases -f tag_name=v1",
                        'gh release edit "$TAG" --draft=false'):
            self.assert_rejected({"release.yml": GATED.replace(GATE_STEP, "").replace('gh release create "$TAG" "$art"', publish)},
                                 "before passing")
        action = f"      - uses: softprops/action-gh-release@{SHA} # v2.0.0\n"
        self.assert_rejected({"release.yml": GATED.replace(GATE_STEP, "").replace(PUBLISH_STEP, action)}, "before passing")

    def test_gate_after_publish_rejected(self):
        moved = GATED.replace(GATE_STEP, "").replace(PUBLISH_STEP, PUBLISH_STEP + GATE_STEP)
        self.assert_rejected({"release.yml": moved}, "before passing scripts/verify-release.sh")

    def test_privileged_steps_before_the_gate_rejected(self):
        # Whatever its command looks like, a step given the token, or an action that may take it by default, can publish.
        self.assert_rejected({"release.yml": GATED.replace(GATE_STEP, SNEAKY_STEP + GATE_STEP)}, "before passing")
        quiet = f"      - uses: someone/notes-action@{SHA} # v1.0.0\n"
        self.assert_rejected({"release.yml": GATED.replace(GATE_STEP, quiet + GATE_STEP)}, "before passing")
        curl = ('      - name: Upload\n        run: curl -X POST --data-binary @x.dmg '
                '"https://uploads.github.com/repos/o/r/releases/1/assets?name=x.dmg"\n')
        self.assert_rejected({"release.yml": GATED.replace(GATE_STEP, curl + GATE_STEP)}, "before passing")

    def test_gate_has_one_fixed_form(self):
        weakened = {
            "if": GATE_STEP.replace("        id: verify\n", "        id: verify\n        if: ${{ vars.X != '' }}\n"),
            "if first": GATE_STEP.replace("      - name: Verify release\n", "      - if: ${{ vars.X != '' }}\n        name: Verify release\n"),
            "continue-on-error": GATE_STEP.replace("        id: verify\n", "        id: verify\n        continue-on-error: true\n"),
            "shell": GATE_STEP.replace("        id: verify\n", "        id: verify\n        shell: true {0}\n"),
            "working-directory": GATE_STEP.replace("        id: verify\n", "        id: verify\n        working-directory: elsewhere\n"),
            "extra env": GATE_STEP.replace("          SPANDECK_TEAM_ID", "          BASH_ENV: x\n          SPANDECK_TEAM_ID"),
            "no id": GATE_STEP.replace("        id: verify\n", ""),
        }
        for tail in (" || true", "; true", " || exit 0", " || echo skipped", " &", " | tee gate.log"):
            weakened[tail] = GATE_STEP.replace('.dmg"\n', '.dmg"' + tail + "\n")
        for prefix in ("bash ", "set +e; ", "! ", "if ", "sh -c "):
            weakened[prefix] = GATE_STEP.replace("run: scripts/", "run: " + prefix + "scripts/")
        weakened["block"] = GATE_STEP.replace('run: scripts/verify-release.sh "build/SpanDeck-${TAG#v}.dmg"',
                                              'run: |\n          scripts/verify-release.sh "build/SpanDeck-${TAG#v}.dmg" || true')
        for name, gate in weakened.items():
            with self.subTest(name):
                self.assert_rejected({"release.yml": GATED.replace(GATE_STEP, gate)}, "release gate step must")

    def test_nothing_runs_after_a_failed_gate(self):
        for cond in ("always()", "failure()", "cancelled()", "${{ always() }}", "!cancelled()"):
            publish = PUBLISH_STEP.replace("        env:\n", f"        if: {cond}\n        env:\n", 1)
            with self.subTest(cond):
                self.assert_rejected({"release.yml": GATED.replace(PUBLISH_STEP, publish)}, "after a failed step")

    def test_upload_checks_the_verified_hash(self):
        unchecked = PUBLISH_STEP.replace('          echo "$DMG_SHA256  $art" | shasum -a 256 -c -\n', "")
        self.assert_rejected({"release.yml": GATED.replace(PUBLISH_STEP, unchecked)}, "verified hash")
        unbound = PUBLISH_STEP.replace("          DMG_SHA256: ${{ steps.verify.outputs.sha256 }}\n", "")
        self.assert_rejected({"release.yml": GATED.replace(PUBLISH_STEP, unbound)}, "verified hash")
        other = PUBLISH_STEP.replace("steps.verify.outputs", "steps.other.outputs")
        self.assert_rejected({"release.yml": GATED.replace(PUBLISH_STEP, other)}, "verified hash")

    def test_nothing_rebuilt_between_gate_and_publish(self):
        for rebuild in (BUILD_STEP, "      - name: Re-sign\n        run: codesign --force --sign - build/SpanDeck.app\n"):
            self.assert_rejected({"release.yml": GATED.replace(PUBLISH_STEP, rebuild + PUBLISH_STEP)},
                                 "changes the build after the release gate")

    def test_steps_the_checker_cannot_parse_rejected(self):
        # A `steps:` list at the same indent as its key is valid YAML but isn't parsed as steps here; publishing in it
        # must not slip through.
        flat = GATED.replace("    steps:\n", "    steps:\n").replace("\n      - ", "\n    - ").replace("\n        ", "\n      ")
        self.assertNotEqual(self.run_checker({"release.yml": flat})[0], 0)
        self.assert_rejected({"release.yml": flat}, "outside a step")
        anchored = GATED.replace("      - name: Publish\n", "      - &publish\n        name: Publish\n")
        self.assert_rejected({"release.yml": anchored}, "YAML anchors")
        self.assert_rejected({"release.yml": GATED.replace("jobs:\n", "defaults:\n  run:\n    shell: bash\njobs:\n")},
                             "defaults:")

    def test_gatekeeper_bypass_instructions_rejected(self):
        for text in ("allow it under System Settings > Privacy & Security > Open Anyway",
                     "xattr -d com.apple.quarantine SpanDeck.app", "xattr -cr SpanDeck.app", "sudo spctl --master-disable",
                     "spctl --global-disable"):
            notes = GATED.replace('gh release create "$TAG"', f'echo "{text}"\n          gh release create "$TAG"')
            self.assert_rejected({"release.yml": notes}, "Gatekeeper bypass")
            self.assert_rejected({"test.yml": TEST.replace("run: swift test", f"run: echo '{text}'")}, "Gatekeeper bypass")

    def test_docker_images_need_digest(self):
        step = "      - uses: docker://alpine:3.20\n"
        self.assert_rejected({"test.yml": TEST.replace("      - name: Run tests\n", step + "      - name: Run tests\n")},
                             "docker image not pinned")


if __name__ == "__main__":
    unittest.main()
