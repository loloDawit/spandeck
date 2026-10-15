#!/usr/bin/env python3
"""Self-test for update-pricing-snapshot.py (R6). Synthetic input only; no network, nothing outside a temp dir.

Run: python3 -I scripts/test_update_pricing_snapshot.py
"""
import hashlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "update-pricing-snapshot.py"
COMMIT = "a" * 40
RETRIEVED = "2026-01-02T03:04:05Z"
SOURCE = (b'{"claude-synth-1":{"input_cost_per_token":2e-06,"output_cost_per_token":4e-06},'
          b'"gpt-x":{"input_cost_per_token":1,"output_cost_per_token":1}}')


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.source = self.root / "source.json"
        self.source.write_bytes(SOURCE)
        self.sha = hashlib.sha256(SOURCE).hexdigest()

    def tearDown(self):
        self.dir.cleanup()

    def run_script(self, *args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True)

    def generate(self, name, sha=None, retrieved=RETRIEVED, commit=COMMIT):
        out = self.root / name
        args = [commit, sha or self.sha, "--file", str(self.source), "--out", str(out)]
        if retrieved is not None:
            args += ["--retrieved", retrieved]
        return self.run_script(*args), out

    def test_same_invocation_gives_identical_bytes(self):
        r1, out1 = self.generate("one.swift")
        r2, out2 = self.generate("two.swift")
        self.assertEqual((r1.returncode, r2.returncode), (0, 0), r1.stderr + r2.stderr)
        self.assertEqual(out1.read_bytes(), out2.read_bytes())
        text = out1.read_text()
        self.assertIn(f'revision: "{COMMIT}"', text)
        self.assertIn(f'sourceSHA256: "{self.sha}"', text)
        self.assertIn(f'retrieved = "{RETRIEVED}"', text)
        # Missing cache prices use the 1.25x default, computed in binary floating point exactly as Swift's `input * 1.25`.
        self.assertIn(f'"cacheWrite": {2e-06 * 1.25!r}', text)
        self.assertNotIn("gpt-x", text)
        self.assertIn("MIT License, Copyright (c) 2023 Berri AI", text)

    def test_retrieved_is_required_and_checked(self):
        for retrieved in (None, "yesterday", "2026-01-02"):
            r, out = self.generate("x.swift", retrieved=retrieved)
            self.assertNotEqual(r.returncode, 0, retrieved)
            self.assertFalse(out.exists())

    def test_checksum_mismatch_refused_before_writing(self):
        r, out = self.generate("x.swift", sha="0" * 64)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("checksum mismatch", r.stderr)
        self.assertFalse(out.exists())

    def test_branch_or_tag_refused(self):
        for ref in ("main", "v1.0", "A" * 40):
            r, out = self.generate("x.swift", commit=ref)
            self.assertNotEqual(r.returncode, 0, ref)
            self.assertFalse(out.exists())

    def test_invalid_prices_refused(self):
        for body in (b"{}", b'{"claude-x":{"input_cost_per_token":-1,"output_cost_per_token":1e-06}}',
                     b'{"claude-x":{"input_cost_per_token":false,"output_cost_per_token":1e-06}}'):
            self.source.write_bytes(body)
            r, out = self.generate("x.swift", sha=hashlib.sha256(body).hexdigest())
            self.assertNotEqual(r.returncode, 0, body)
            self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
