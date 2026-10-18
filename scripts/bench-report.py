#!/usr/bin/env python3
"""Renders a scripts/bench.sh result folder (env.json + <dataset>.json) as the Markdown tables in docs/PERFORMANCE.md.

    scripts/bench-report.py DIR
"""
import json
import os
import sys

d = sys.argv[1]
env = json.load(open(os.path.join(d, "env.json")))
sets = [s for s in ("small", "medium", "large") if os.path.exists(os.path.join(d, f"{s}.json"))]
res = {s: json.load(open(os.path.join(d, f"{s}.json"))) for s in sets}


def ms(x):
    return f"{x * 1000:,.1f}"


def mb(b):
    return f"{b / 1e6:.1f}"


print("**Environment:**", ", ".join(f"{k} `{env[k]}`" for k in
      ("model", "cpu", "cores", "memory_bytes", "macos", "macos_build", "swift", "xcode", "commit", "build", "power")
      if env.get(k)))
print()
print("| Dataset | Transcripts | Messages | Lines | Bytes on disk | Grok turns | Load avg before → after |")
print("|---|---|---|---|---|---|---|")
for s in sets:
    sh = res[s]["shape"]; la = res[s].get("load_average", {})
    print(f"| {s} | {sh['transcripts']} | {sh['messages']:,} | {sh['lines']:,} | {mb(sh['bytes'])} MB | {sh['grok_turns']:,} "
          f"| {la.get('before', '?')} → {la.get('after', '?')} |")
print()

rows = [
    ("Ledger cold start: first scan, no cache (not app launch)", "cold_first_scan"),
    ("Ledger warm start: cache load + first refresh (not app launch)", "warm_launch"),
    ("10 s tick, nothing new", "tick_no_change"),
    ("10 s tick, 10 new messages (no save)", "tick_incremental_10_messages"),
    ("Cache save (`flush`)", "cache_save"),
    ("5 min full scan, nothing new", "full_scan_no_change"),
    ("Summary only (window change)", "summary_recompute"),
    ("Simulated wake, clock +8 h (full scan, 3 files grew, cache save)", "wake_after_8h"),
    ("Rebuild after Clear cached usage data", "rebuild_after_clear"),
]
print("Wall time in ms: median / p95 / worst (n). CPU is the median, in ms. p95 is nearest-rank; with n ≤ 19 it is the worst sample.")
print()
print("| Scenario | " + " | ".join(sets) + " |")
print("|---|" + "---|" * len(sets))
for label, key in rows:
    cells = []
    for s in sets:
        v = res[s][key]; w = v["wall_s"]; c = v["cpu_s"]
        cells.append(f"{ms(w['median'])} / {ms(w['p95'])} / {ms(w['max'])} ({int(w['n'])}); CPU {ms(c['median'])}")
    print(f"| {label} | " + " | ".join(cells) + " |")
print()

print("| Measure | " + " | ".join(sets) + " |")
print("|---|" + "---|" * len(sets))
def row(label, f):
    print(f"| {label} | " + " | ".join(f(res[s]) for s in sets) + " |")
row("Bytes scanned, first scan", lambda r: f"{mb(r['cold_first_scan']['bytes_scanned'])} MB")
row("Cache file", lambda r: f"{mb(r['cache_bytes'])} MB")
row("Disk written, first scan (median)", lambda r: f"{mb(r['cold_first_scan']['disk_written_bytes']['median'])} MB")
row("Incremental tick samples that saved the cache (want 0)",
    lambda r: str(r['tick_incremental_10_messages'].get('samples_with_a_save', '?')))
row("First change after a ledger start: wall / written (it saves the cache)",
    lambda r: f"{ms(r['tick_incremental_10_messages']['first_change_after_start_wall_s'])} ms / "
              f"{mb(r['tick_incremental_10_messages']['first_change_after_start_written_bytes'])} MB")
row("Disk written, wake (median)", lambda r: f"{mb(r['wake_after_8h']['disk_written_bytes']['median'])} MB")
row("Disk written, one cache save (median)", lambda r: f"{mb(r['cache_save']['disk_written_bytes']['median'])} MB")
row("Disk read, first scan (median; file cache warm)", lambda r: f"{mb(r['cold_first_scan']['disk_read_bytes']['median'])} MB")
row("All-scenario process: footprint peak (incl. generator, several ledgers)",
    lambda r: f"{mb(r['memory_bytes']['footprint_peak'])} MB")
row("10 refreshes at once (ledger queue)", lambda r: f"{ms(r['ledger_burst_10']['wall_s'])} ms")
row("Quit (`flush`) 50 ms into a cold scan: main thread blocked", lambda r: f"{ms(r['quit_flush_during_cold_scan']['wall_s'])} ms")
row("Hover top consumers, cpu / memory (median)",
    lambda r: " / ".join(f"{r['hover_top_consumers_median_ms'][k]:.2f}" for k in ("cpu", "memory")) + " ms")
row("App refreshes dropped while one runs", lambda r: f"{r['main_thread_during_cold_scan']['overlapping_refreshes_dropped_of_10']} of 10")
row("Main-actor lateness during a cold scan, p95 / worst",
    lambda r: "{:.1f} / {:.1f} ms".format(r['main_thread_during_cold_scan']['heartbeat_late_ms']['p95'],
                                          r['main_thread_during_cold_scan']['heartbeat_late_ms']['max']))
row("Menu-bar strip render, median / worst",
    lambda r: "{:.3f} / {:.1f} ms".format(r['render_ms']['menu_bar_strip']['median'], r['render_ms']['menu_bar_strip']['max']))
row("Popover full render, median / worst (first)",
    lambda r: "{:.1f} / {:.1f} ms".format(r['render_ms']['popover_full_render']['median'], r['render_ms']['popover_full_render']['max']))
row("Sampler cpu / memory / gpu / battery (median)",
    lambda r: " / ".join(f"{r['sampler_median_ms'][k]:.3f}" for k in ("cpu", "memory", "gpu", "battery")) + " ms")
if any("idle_cadence" in res[s] for s in sets):
    row("Idle at app cadence, CPU share of one core",
        lambda r: f"{r['idle_cadence']['cpu_share_of_one_core'] * 100:.2f}% over {r['idle_cadence']['seconds']:.0f} s"
        if "idle_cadence" in r else "not run")

mem = {}
for s_ in sets:
    for m in ("cold", "warm"):
        p = os.path.join(d, f"{s_}-memory-{m}.json")
        if os.path.exists(p): mem[(s_, m)] = json.load(open(p))
if mem:
    print()
    print("One ledger per process (memory runs):")
    print()
    print("| Dataset | Run | Wall | Footprint before | After the scan | Steady (next tick) | Peak | Max RSS |")
    print("|---|---|---|---|---|---|---|---|")
    for (s_, m), r in sorted(mem.items()):
        print(f"| {s_} | {m} | {ms(r['wall_s'])} ms | {mb(r['footprint_before'])} MB | {mb(r['footprint_after_scan'])} MB "
              f"| {mb(r['footprint_steady'])} MB | {mb(r['footprint_peak'])} MB | {mb(r['max_rss'])} MB |")
