#!/usr/bin/env python3
"""#88: renders the results of scripts/bench-ui.sh as the Markdown tables in docs/PERFORMANCE.md §4.7.

    scripts/bench-ui-report.py DIR

Statistics as in the Swift harness: median, p95 by nearest rank (the ceil(0.95 n)-th smallest; with n <= 19 it is the
worst sample) and worst, with n in each cell.
"""
import glob
import json
import math
import os
import sys

SETS = ["small", "medium", "large"]


def stats(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return None
    med = s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2
    return {"median": med, "p95": s[min(n - 1, math.ceil(0.95 * n) - 1)], "max": s[-1], "min": s[0], "n": n}


def fmt(v, digits=1):
    return f"{v:,.{digits}f}"


def cell(st, digits=1):
    """median / p95 / worst (n) from a stats dict."""
    if not st:
        return "–"
    return f"{fmt(st['median'], digits)} / {fmt(st['p95'], digits)} / {fmt(st['max'], digits)} ({int(st['n'])})"


def load(path):
    with open(path) as f:
        return json.load(f)


def main(d):
    env = load(os.path.join(d, "env.json"))
    keys = ["model", "cpu", "cores", "memory_bytes", "macos", "macos_build", "swift", "xcode", "commit", "dirty", "power",
            "build", "runs"]
    print("**Environment:** " + ", ".join(f"{k} `{env.get(k)}`" for k in keys))
    print()
    probe = os.path.join(d, "ui-probe.json")
    if os.path.exists(probe):
        p = load(probe)
        print("**Probe:** " + ", ".join(f"{k} `{v}`" for k, v in sorted(p.items())))
        print()

    # First render (B11).
    print("#### First popover render, one per fresh process (ms: median / p95 / worst (n))")
    print()
    print("| Dataset | Path | First render | Re-open, per-process medians | Re-open, worst | Load average before (1 min), range |")
    print("|---|---|---|---|---|---|")
    pieces = {}
    for s in SETS:
        for v in ["hosting", "image"]:
            files = sorted(glob.glob(os.path.join(d, f"{s}-ui-first-{v}-*.json")))
            if not files:
                continue
            rs = [load(f) for f in files]
            first = stats([r["first"]["total_ms"] for r in rs])
            re_med = stats([r["reopen_total_ms"]["median"] for r in rs])
            re_max = max(r["reopen_total_ms"]["max"] for r in rs)
            loads = [float(r["load_average"]["before"].strip("{} ").split()[0]) for r in rs if "load_average" in r]
            lr = f"{min(loads):.1f}–{max(loads):.1f}" if loads else "–"
            print(f"| {s} | {v} | {cell(first)} | {cell(re_med)} | {fmt(re_max)} | {lr} |")
            if v == "hosting":
                pieces[s] = rs
    print()
    if pieces:
        print("Hosting path, first render in steps (median ms over processes) and re-open steps:")
        print()
        print("| Dataset | Construct | Attach to window | Layout | Display + flush | Deferred, worst span | Re-open layout (median of medians) | Close (median of medians) | Size |")
        print("|---|---|---|---|---|---|---|---|---|")
        for s, rs in pieces.items():
            m = lambda k: stats([r["first"][k] for r in rs])["median"]
            dm = max(r["first"]["deferred_max_span_ms"] for r in rs)
            rl = stats([r["reopen_layout_ms"]["median"] for r in rs])["median"]
            cl = stats([r["close_ms"]["median"] for r in rs])["median"]
            size = f"{int(rs[0]['first']['width'])}×{int(rs[0]['first']['height'])}"
            print(f"| {s} | {fmt(m('construct_ms'), 2)} | {fmt(m('attach_ms'))} | {fmt(m('layout_ms'))} | "
                  f"{fmt(m('display_ms'))} | {fmt(dm, 2)} | {fmt(rl)} | {fmt(cl, 2)} | {size} |")
        print()
        print("Warm start publish, popover closed (the first `refreshUsage` in each hosting process):")
        print()
        print("| Dataset | Refresh wall | Publish (µs) | Publish span | Longest span |")
        print("|---|---|---|---|---|")
        for s, rs in pieces.items():
            w = [r["warm_start"] for r in rs]
            print(f"| {s} | {cell(stats([x['refresh_wall_ms'] for x in w]))} | "
                  f"{cell(stats([x['publish_ms'] * 1000 for x in w if 'publish_ms' in x]), 0)} | "
                  f"{cell(stats([x['publish_span_ms'] for x in w]), 3)} | {cell(stats([x['max_span_ms'] for x in w]), 3)} |")
        print()

    # Post-refresh publish (B2).
    pubs = {s: load(os.path.join(d, f"{s}-ui-publish.json")) for s in SETS
            if os.path.exists(os.path.join(d, f"{s}-ui-publish.json"))}
    if not pubs:
        return
    series = [("tick_closed_nothing_new", "closed, nothing new"), ("tick_closed_10_new", "closed, 10 new messages"),
              ("tick_open_nothing_new", "open, nothing new"), ("tick_open_10_new", "open, 10 new messages")]
    print("#### Refresh tick: main-thread busy spans (ms: median / p95 / worst (n))")
    print()
    print("| Dataset | Popover | Longest span | Publish span (with its update pass) | Other update span | "
          "Publish, assignments only (µs) | Update passes per tick (median) | Refresh wall (median) | Load before → after |")
    print("|---|---|---|---|---|---|---|---|---|")
    for s, r in pubs.items():
        la = r.get("load_average", {})
        for k, label in series:
            x = r[k]
            print(f"| {s} | {label} | {cell(x['max_span_ms'])} | {cell(x['publish_span_ms'])} | "
                  f"{cell(x['other_update_span_ms'])} | {cell({kk: v * 1000 if kk != 'n' else v for kk, v in x['publish_ms'].items()}, 0)} | "
                  f"{fmt(x['update_spans']['median'], 0)} | {fmt(x['refresh_wall_ms']['median'])} | "
                  f"{la.get('before', '')} → {la.get('after', '')} |")
    print()
    print("#### 1 s sample tick with the popover open (ms: median / p95 / worst (n))")
    print()
    print("| Dataset | Longest span | Sampling + strip | Forced: graph + layout | Forced: display + flush | "
          "Views re-evaluated in layout (median) | Residual span | Quiet floor, closed / open (worst span) |")
    print("|---|---|---|---|---|---|---|---|")
    for s, r in pubs.items():
        x, f = r["sample_tick_open"], r.get("sample_tick_open_forced")
        q = f"{fmt(r['quiet_closed']['max'], 2) if r['quiet_closed'] else '–'} / " \
            f"{fmt(r['quiet_open']['max'], 2) if r['quiet_open'] else '–'}"
        if f:
            print(f"| {s} | {cell(x['max_span_ms'])} | {cell(x['work_ms'], 2)} | {cell(f['layout_ms'])} | "
                  f"{cell(f['display_ms'])} | {fmt(f['bodies_in_layout']['median'], 0)} | {cell(f['residual_span_ms'], 2)} | {q} |")
        else:
            print(f"| {s} | {cell(x['max_span_ms'])} | {cell(x['work_ms'], 2)} | – | – | – | – | {q} |")
    print()
    print("#### Cold scan with the popover open")
    print()
    print("| Dataset | Scan wall | `indexing` publishes | Update passes | Longest span | Spans: median / p95 / worst (n) | Main-thread busy, total |")
    print("|---|---|---|---|---|---|---|")
    for s, r in pubs.items():
        c = r["cold_scan_open"]
        print(f"| {s} | {fmt(c['scan_wall_s'], 2)} s | {int(c['indexing_publishes'])} | {int(c['update_spans'])} | "
              f"{fmt(c['max_span_ms'])} ms | {cell(r['cold_scan_spans_ms'], 2)} | {fmt(c['busy_ms'])} ms |")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: scripts/bench-ui-report.py DIR")
    main(sys.argv[1])
