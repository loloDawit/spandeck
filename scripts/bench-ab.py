#!/usr/bin/env python3
"""Compares the two sides of an interleaved A/B (docs/perf/*/ab-vs-*/): <dataset>-<side>-<round>.json, as written by
running PerformanceBenchTests from two worktrees in alternation. Prints, per scenario, each side's CPU median averaged
over its rounds and the difference, then first-scan throughput.

Throughput, in MB (10^6 bytes) per CPU second: cold_first_scan.bytes_scanned / (cold_first_scan.cpu_s.median -
cache_save.cpu_s.median), so the first save the first refresh makes isn't counted as scanning; the mean over rounds.

    scripts/bench-ab.py DIR A_SIDE B_SIDE      e.g.  scripts/bench-ab.py docs/perf/.../ab-vs-main main new
"""
import glob
import json
import os
import re
import sys

d, a_side, b_side = sys.argv[1:4]
files = {}
for p in glob.glob(os.path.join(d, "*.json")):
    m = re.fullmatch(r"(.+)-([a-z0-9]+)-(\d+)\.json", os.path.basename(p))
    if m:
        files.setdefault((m.group(1), m.group(2)), []).append(json.load(open(p)))

for ds in sorted({k[0] for k in files}):
    a, b = files.get((ds, a_side), []), files.get((ds, b_side), [])
    if not a or not b:
        continue
    print(f"== {ds}: {a_side} ({len(a)} rounds) vs {b_side} ({len(b)} rounds), CPU median in ms")
    keys = sorted(k for k, v in a[0].items() if isinstance(v, dict) and isinstance(v.get("cpu_s"), dict) and k in b[0])
    for k in keys:
        x = sum(r[k]["cpu_s"]["median"] for r in a) / len(a)
        y = sum(r[k]["cpu_s"]["median"] for r in b) / len(b)
        print(f"  {k:32} {x * 1000:10.2f} -> {y * 1000:10.2f}  {(y - x) / x * 100:+6.1f}%")
    tp = lambda rs: sum(r["cold_first_scan"]["bytes_scanned"] / 1e6
                        / (r["cold_first_scan"]["cpu_s"]["median"] - r["cache_save"]["cpu_s"]["median"]) for r in rs) / len(rs)
    print(f"  first-scan throughput: {tp(a):.1f} -> {tp(b):.1f} MB/s")
