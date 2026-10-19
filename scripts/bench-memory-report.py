#!/usr/bin/env python3
"""#87: renders scripts/bench-memory.sh results as Markdown tables.

    scripts/bench-memory-report.py DIR

Each cell is the median over rounds, with the range [min–max] when rounds differ by more than 5 %. MB are 10^6 bytes.
"Live" is the allocator's bytes in live blocks (malloc_zone_statistics size_in_use), "footprint" the kernel's
phys_footprint (Activity Monitor's Memory). Per-message figures divide by the dataset's logged messages.
"""
import glob, json, os, statistics, sys

MESSAGES = {"small": 2_000, "medium": 30_000, "large": 120_000}
ORDER = ["small", "medium", "large"]


def load(root):
    runs = {}
    for p in sorted(glob.glob(os.path.join(root, "round-*", "*-memory-*.json"))):
        r = json.load(open(p))
        runs.setdefault((r["dataset"], r["mode"]), []).append(r)
    return runs


def phase(r, name):
    for x in r["phases"]:
        if x["phase"] == name:
            return x
    raise KeyError(f"{r['dataset']} {r['mode']}: no phase {name!r}")


def cell(values, scale=1e6, digits=0):
    values = [v / scale for v in values]
    m = statistics.median(values)
    lo, hi = min(values), max(values)
    f = f"{{:,.{digits}f}}"
    if m and (hi - lo) / m > 0.05:
        return f"{f.format(m)} [{f.format(lo)}–{f.format(hi)}]"
    return f.format(m)


def kb_per_message(values, d):
    return cell([v / MESSAGES[d] for v in values], scale=1e3, digits=2)


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out)


def main(root):
    runs = load(root)
    sets = [d for d in ORDER if (d, "cold") in runs]
    env = json.load(open(os.path.join(root, "env.json")))
    rounds = max(len(v) for v in runs.values())
    print(f"Commit `{env['commit'][:7]}` (dirty: {env['dirty']}), {env['cpu']}, macOS {env['macos']} ({env['macos_build']}), "
          f"{env['swift']}; {rounds} rounds. MB = 10^6 bytes; median [range when rounds differ by > 5 %].\n")

    # Cold and warm: one ledger, scan or load, its first save (cold only), the steady state, then released.
    rows = []
    for d in sets:
        for mode in ("cold", "warm"):
            rs = runs[(d, mode)]
            steady = [phase(r, "steady") for r in rs]
            scanned = [phase(r, "scanned") for r in rs]
            released = [phase(r, "released") for r in rs]
            rows.append([f"{d} {mode}", cell([r["wall_s"] for r in rs], scale=1, digits=2),
                         cell([x["malloc_in_use"] for x in steady]), kb_per_message([x["malloc_in_use"] for x in steady], d),
                         cell([x["footprint"] for x in steady]), kb_per_message([x["footprint"] for x in steady], d),
                         cell([x["series_max_in_use"] for x in scanned]), cell([x["footprint_peak"] for x in steady]),
                         cell([x["footprint"] for x in released]), cell([x["malloc_in_use"] for x in released], digits=1)])
    print("### Cold scan and warm load (one ledger per process)\n")
    print(table(["Dataset", "Wall s", "Live, steady", "Live KB/msg", "Footprint, steady", "Footprint KB/msg",
                 "Live, highest (20 ms samples)", "Footprint peak", "Footprint, ledger released", "Live, released"], rows))

    # Repeated warm loads in one process.
    rows = []
    for d in sets:
        rs = runs.get((d, "repeat"), [])
        if not rs:
            continue
        n = sum(1 for x in rs[0]["phases"] if x["phase"].startswith("loaded "))
        for i in range(1, n + 1):
            rows.append([f"{d} load {i}", cell([phase(r, f"loaded {i}")["malloc_in_use"] for r in rs]),
                         cell([phase(r, f"loaded {i}")["footprint"] for r in rs]),
                         cell([phase(r, f"released {i}")["malloc_in_use"] for r in rs], digits=1),
                         cell([phase(r, f"released {i}")["footprint"] for r in rs])])
    print("\n### Repeated warm loads in one process (each ledger released before the next)\n")
    print(table(["Dataset, load", "Live, loaded", "Footprint, loaded", "Live, released", "Footprint, released"], rows))

    # Idle ticks after a warm load.
    rows = []
    for d in sets:
        rs = runs.get((d, "idle"), [])
        if not rs:
            continue
        last = [x for x in rs[0]["phases"] if x["phase"].startswith("ticks ")][0]["phase"]
        ticks = [phase(r, last) for r in rs]
        rows.append([d, last.split()[1], cell([phase(r, "loaded")["malloc_in_use"] for r in rs]),
                     cell([x["malloc_in_use"] for x in ticks]),
                     cell([x["footprint_each_tick"][0] for x in ticks]), cell([x["footprint_each_tick"][-1] for x in ticks])])
    print("\n### Idle: refreshes with nothing new, back to back, after a warm load\n")
    print(table(["Dataset", "Ticks", "Live, loaded", "Live, after ticks", "Footprint, first tick", "Footprint, last tick"], rows))

    # Cancellation: a cold scan stopped as quit does, the ledger released, then a resume.
    rows = []
    for d in sets:
        rs = runs.get((d, "cancel"), [])
        if not rs:
            continue
        st = [phase(r, "stopped") for r in rs]
        rows.append([d, f"{st[0]['stop_ms']:,} ms", ", ".join(sorted({x["result"] for x in st})),
                     cell([x["malloc_in_use"] for x in st]), cell([x["footprint_peak"] for x in st]),
                     cell([phase(r, "released")["malloc_in_use"] for r in rs], digits=1),
                     cell([phase(r, "released")["footprint"] for r in rs]),
                     cell([phase(r, "resumed")["malloc_in_use"] for r in rs]),
                     cell([phase(r, "resumed")["series_max_in_use"] for r in rs])])
    print("\n### Stop during a cold scan, release, resume\n")
    print(table(["Dataset", "Stopped after", "Result", "Live, stopped", "Footprint peak to the stop",
                 "Live, released", "Footprint, released", "Live, resumed", "Live, highest during the resume"], rows))

    # Incremental: new messages after a warm load; the first change after a start saves the cache.
    rows = []
    for d in sets:
        rs = runs.get((d, "incremental"), [])
        if not rs:
            continue
        for n in (10, 100, 1000):
            ps = [phase(r, f"appended {n}") for r in rs]
            rows.append([f"{d} +{n}", cell([x["wall_s"] for x in ps], scale=1e-3, digits=0),
                         cell([x["written_bytes"] for x in ps], digits=1),
                         cell([x["series_max_in_use"] for x in ps]), cell([x["malloc_in_use"] for x in ps]),
                         cell([x["footprint"] for x in ps])])
    print("\n### Incremental: new messages after a warm load (the first change saves the cache)\n")
    print(table(["Dataset, messages", "Refresh ms", "Written MB", "Live, highest (20 ms samples)", "Live, after",
                 "Footprint, after"], rows))

    loads = sorted({r["load_average"]["before"] for v in runs.values() for r in v})
    levels = sorted({x["pressure_level"] for v in runs.values() for r in v for x in r["phases"]})
    print(f"\nLoad average before each process: {loads[0]} … {loads[-1]}. Memory pressure levels seen at phases: {levels} "
          "(1 normal, 2 warning, 4 critical).")


if __name__ == "__main__":
    main(sys.argv[1])
