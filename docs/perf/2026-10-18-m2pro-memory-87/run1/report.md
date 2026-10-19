Commit `4d075f8` (dirty: False), Apple M2 Pro, macOS 26.5 (25F71), Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101); 5 rounds. MB = 10^6 bytes; median [range when rounds differ by > 5 %].

### Cold scan and warm load (one ledger per process)

| Dataset | Wall s | Live, steady | Live KB/msg | Footprint, steady | Footprint KB/msg | Live, highest (20 ms samples) | Footprint peak | Footprint, ledger released | Live, released |
|---|---|---|---|---|---|---|---|---|---|
| small cold | 0.34 [0.31–0.49] | 4 | 2.22 | 25 | 12.65 | 10 [6–13] | 25 | 25 | 1.3 [1.3–1.4] |
| small warm | 0.06 [0.05–0.06] | 4 | 2.21 | 17 [16–20] | 8.54 [8.25–10.05] | 9 [8–9] | 17 [16–20] | 17 [16–20] | 1.1 |
| medium cold | 4.82 [4.52–7.51] | 36 | 1.21 | 103 | 3.42 | 140 [130–151] | 166 | 103 | 1.5 |
| medium warm | 0.51 [0.47–0.54] | 38 | 1.28 | 109 | 3.64 | 94 [87–97] | 109 | 33 | 1.3 |
| large cold | 22.32 [20.53–25.16] | 129 | 1.08 | 280 | 2.34 | 522 [522–564] | 586 | 280 | 1.5 |
| large warm | 2.06 [1.93–2.13] | 137 | 1.14 | 383 [381–471] | 3.19 [3.18–3.93] | 356 [336–410] | 383 [381–545] | 23 [12–24] | 1.3 |

### Repeated warm loads in one process (each ledger released before the next)

| Dataset, load | Live, loaded | Footprint, loaded | Live, released | Footprint, released |
|---|---|---|---|---|
| small load 1 | 6 | 17 [17–20] | 1.1 | 17 [17–20] |
| small load 2 | 6 | 18 [17–22] | 1.2 | 18 [17–22] |
| small load 3 | 6 | 19 [18–22] | 1.2 | 19 [18–22] |
| small load 4 | 6 | 20 [18–23] | 1.2 | 20 [18–23] |
| small load 5 | 6 | 20 [18–23] | 1.3 | 20 [18–23] |
| medium load 1 | 52 | 108 | 1.2 | 33 |
| medium load 2 | 52 | 89 [89–101] | 1.4 [1.3–1.4] | 93 [89–102] |
| medium load 3 | 52 | 93 [89–109] | 1.4 [1.3–1.4] | 93 [89–109] |
| medium load 4 | 52 | 102 [86–109] | 1.5 [1.3–1.5] | 102 [86–109] |
| medium load 5 | 52 | 109 [87–113] | 1.5 [1.4–1.5] | 109 [87–113] |
| large load 1 | 186 | 383 [380–544] | 1.3 | 23 |
| large load 2 | 187 | 284 [278–543] | 1.5 [1.5–1.6] | 286 [278–543] |
| large load 3 | 187 | 356 [287–450] | 1.5 [1.3–1.6] | 370 [287–450] |
| large load 4 | 189 | 383 [292–477] | 1.6 [1.3–1.6] | 383 [292–477] |
| large load 5 | 189 | 372 [363–395] | 1.6 [1.5–1.6] | 373 [363–395] |

### Idle: refreshes with nothing new, back to back, after a warm load

| Dataset | Ticks | Live, loaded | Live, after ticks | Footprint, first tick | Footprint, last tick |
|---|---|---|---|---|---|
| small | 30 | 6 | 4 | 17 [16–19] | 17 [16–19] |
| medium | 30 | 52 | 38 | 109 | 109 |
| large | 30 | 186 | 137 | 381 [380–476] | 381 |

### Stop during a cold scan, release, resume

| Dataset | Stopped after | Result | Live, stopped | Footprint peak to the stop | Live, released | Footprint, released | Live, resumed | Live, highest during the resume |
|---|---|---|---|---|---|---|---|---|
| small | 150 ms | saved | 3 [3–3] | 18 [16–18] | 1.2 | 18 [17–18] | 5 [5–5] | 10 [9–14] |
| medium | 2,000 ms | saved | 15 [15–18] | 71 [69–83] | 1.4 | 51 [49–61] | 46 [43–47] | 147 [145–157] |
| large | 10,000 ms | saved | 67 [64–74] | 320 [305–351] | 1.4 | 164 [148–202] | 160 | 592 [552–598] |

### Incremental: new messages after a warm load (the first change saves the cache)

| Dataset, messages | Refresh ms | Written MB | Live, highest (20 ms samples) | Live, after | Footprint, after |
|---|---|---|---|---|---|
| small +10 | 42 [40–165] | 1.2 | 13 [12–14] | 4 | 28 [28–32] |
| small +100 | 24 [23–31] | 0.0 | 5 [4–5] | 5 | 29 [28–32] |
| small +1000 | 145 [144–157] | 0.0 | 6 [5–6] | 6 | 42 [41–45] |
| medium +10 | 386 [354–437] | 13.1 | 144 [135–159] | 38 | 126 [111–128] |
| medium +100 | 54 [51–67] | 0.0 | 39 | 38 | 127 [112–129] |
| medium +1000 | 175 [170–251] | 0.0 | 40 | 39 | 135 [118–135] |
| large +10 | 1,430 [1,309–1,592] | 47.9 | 495 | 137 | 295 |
| large +100 | 71 [66–104] | 0.0 | 139 | 137 | 295 |
| large +1000 | 193 [184–275] | 0.0 | 139 | 138 | 310 |

One-minute load average before each process: 4.62–9.74. Memory pressure levels seen at phases: [2] (1 normal, 2 warning, 4 critical).
