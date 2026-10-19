**Environment:** model `Mac14,10`, cpu `Apple M2 Pro`, cores `12`, memory_bytes `17179869184`, macos `26.5`, macos_build `25F71`, swift `Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`, xcode `Xcode 26.6 Build version 17F113`, commit `e1f1fccd35fa36ef6f8f10f607339de6654f0f13`, dirty `False`, power `Now drawing from 'AC Power'`, build `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`, runs `20`

**Probe:** bodies_100ms_after_3_publishes_in_one_turn `1`, bodies_100ms_after_a_publish `1`, bodies_counted_inside_a_span `2`, bodies_right_after_a_publish `0`, main_run_loop_mode `kCFRunLoopDefaultMode`, main_thread `True`, view_needs_layout_right_after_a_publish `True`, window_visible `False`

#### First popover render, one per fresh process (ms: median / p95 / worst (n))

| Dataset | Path | First render | Re-open, per-process medians | Re-open, worst | Load average before (1 min), range |
|---|---|---|---|---|---|
| small | hosting | 158.1 / 253.4 / 415.3 (20) | 78.4 / 91.5 / 92.5 (20) | 201.4 | 3.3–9.0 |
| small | image | 105.7 / 131.5 / 133.5 (20) | 41.8 / 43.4 / 45.0 (20) | 126.9 | 3.3–8.2 |
| medium | hosting | 147.7 / 176.4 / 374.7 (20) | 73.7 / 82.9 / 85.0 (20) | 148.1 | 3.8–11.8 |
| medium | image | 103.9 / 159.8 / 614.8 (20) | 40.1 / 43.1 / 104.3 (20) | 343.6 | 3.8–9.8 |
| large | hosting | 153.3 / 169.0 / 172.9 (20) | 77.8 / 81.7 / 82.2 (20) | 96.5 | 3.6–9.0 |
| large | image | 108.0 / 115.8 / 120.7 (20) | 38.2 / 40.7 / 42.9 (20) | 49.0 | 3.9–9.4 |

Hosting path, first render in steps (median ms over processes) and re-open steps:

| Dataset | Construct | Attach to window | Layout | Display + flush | Deferred, worst span | Re-open layout (median of medians) | Close (median of medians) | Size |
|---|---|---|---|---|---|---|---|---|
| small | 2.15 | 96.6 | 23.5 | 35.8 | 0.34 | 17.9 | 1.89 | 700×725 |
| medium | 1.90 | 90.3 | 21.9 | 34.5 | 0.14 | 17.8 | 1.52 | 700×725 |
| large | 2.50 | 94.8 | 21.5 | 34.4 | 0.20 | 17.9 | 2.06 | 700×725 |

Warm start publish, popover closed (the first `refreshUsage` in each hosting process):

| Dataset | Refresh wall | Publish (µs) | Publish span | Longest span |
|---|---|---|---|---|
| small | 52.7 / 63.0 / 63.3 (20) | 25 / 28 / 29 (20) | 0.055 / 0.065 / 0.076 (20) | 0.059 / 0.077 / 0.245 (20) |
| medium | 475.4 / 620.1 / 1,460.3 (20) | 27 / 36 / 40 (20) | 0.062 / 0.082 / 0.111 (20) | 0.074 / 0.104 / 0.111 (20) |
| large | 1,740.2 / 1,914.5 / 2,128.6 (20) | 26 / 29 / 31 (20) | 0.058 / 0.122 / 0.300 (20) | 0.093 / 0.300 / 0.432 (20) |

#### Refresh tick: main-thread busy spans (ms: median / p95 / worst (n))

| Dataset | Popover | Longest span | Publish span (with its update pass) | Other update span | Publish, assignments only (µs) | Update passes per tick (median) | Refresh wall (median) | Load before → after |
|---|---|---|---|---|---|---|---|---|
| small | closed, nothing new | 0.1 / 0.4 / 0.6 (30) | 0.0 / 0.0 / 0.0 (30) | 0.0 / 0.0 / 0.0 (30) | 6 / 14 / 14 (30) | 0 | 1.9 | { 5.33 5.68 8.29 } → { 5.24 5.58 8.12 } |
| small | closed, 10 new messages | 0.9 / 2.5 / 21.6 (30) | 0.0 / 0.0 / 0.0 (30) | 0.0 / 0.0 / 0.0 (30) | 8 / 12 / 18 (30) | 0 | 13.0 | { 5.33 5.68 8.29 } → { 5.24 5.58 8.12 } |
| small | open, nothing new | 13.9 / 34.5 / 45.4 (30) | 13.1 / 34.5 / 45.4 (30) | 13.5 / 27.0 / 30.4 (30) | 16 / 41 / 107 (30) | 2 | 14.7 | { 5.33 5.68 8.29 } → { 5.24 5.58 8.12 } |
| small | open, 10 new messages | 17.4 / 25.4 / 25.8 (30) | 16.0 / 20.7 / 22.0 (30) | 16.6 / 25.4 / 25.8 (30) | 18 / 24 / 29 (30) | 2 | 19.8 | { 5.33 5.68 8.29 } → { 5.24 5.58 8.12 } |
| medium | closed, nothing new | 0.0 / 0.1 / 0.4 (30) | 0.0 / 0.0 / 0.0 (30) | 0.0 / 0.0 / 0.0 (30) | 4 / 5 / 6 (30) | 0 | 1.6 | { 5.03 5.87 7.52 } → { 4.17 5.46 7.26 } |
| medium | closed, 10 new messages | 1.2 / 4.3 / 4.5 (30) | 0.0 / 0.0 / 0.0 (30) | 0.0 / 0.0 / 0.0 (30) | 7 / 10 / 13 (30) | 0 | 43.9 | { 5.03 5.87 7.52 } → { 4.17 5.46 7.26 } |
| medium | open, nothing new | 21.0 / 26.6 / 29.5 (30) | 15.6 / 17.9 / 18.1 (30) | 21.0 / 26.6 / 29.5 (30) | 21 / 27 / 29 (30) | 2 | 23.6 | { 5.03 5.87 7.52 } → { 4.17 5.46 7.26 } |
| medium | open, 10 new messages | 22.1 / 23.5 / 24.5 (30) | 15.2 / 16.8 / 16.9 (30) | 22.1 / 23.5 / 24.5 (30) | 18 / 23 / 25 (30) | 2 | 59.7 | { 5.03 5.87 7.52 } → { 4.17 5.46 7.26 } |
| large | closed, nothing new | 0.1 / 0.5 / 3.7 (30) | 0.0 / 0.0 / 0.0 (30) | 0.0 / 0.0 / 0.0 (30) | 10 / 15 / 16 (30) | 0 | 9.4 | { 4.78 5.16 6.54 } → { 5.36 5.14 6.40 } |
| large | closed, 10 new messages | 6.1 / 7.6 / 8.0 (30) | 0.0 / 0.0 / 0.1 (30) | 0.0 / 0.0 / 0.0 (30) | 8 / 13 / 14 (30) | 0 | 76.1 | { 4.78 5.16 6.54 } → { 5.36 5.14 6.40 } |
| large | open, nothing new | 23.8 / 26.9 / 27.6 (30) | 16.4 / 18.6 / 18.7 (30) | 23.8 / 26.9 / 27.6 (30) | 23 / 26 / 32 (30) | 2 | 33.0 | { 4.78 5.16 6.54 } → { 5.36 5.14 6.40 } |
| large | open, 10 new messages | 20.9 / 22.6 / 23.4 (30) | 14.2 / 15.9 / 17.4 (30) | 20.9 / 22.6 / 23.4 (30) | 18 / 26 / 32 (30) | 2 | 75.3 | { 4.78 5.16 6.54 } → { 5.36 5.14 6.40 } |

#### 1 s sample tick with the popover open (ms: median / p95 / worst (n))

| Dataset | Longest span | Sampling + strip | Forced: graph + layout | Forced: display + flush | Views re-evaluated in layout (median) | Residual span | Quiet floor, closed / open (worst span) |
|---|---|---|---|---|---|---|---|
| small | 36.4 / 44.4 / 55.2 (60) | 1.64 / 8.64 / 27.90 (60) | 36.9 / 43.0 / 43.3 (30) | 0.1 / 0.1 / 0.1 (30) | 1 | 0.01 / 0.04 / 0.10 (30) | 14.69 / 0.01 |
| medium | 38.6 / 44.9 / 57.0 (60) | 1.89 / 8.47 / 27.67 (60) | 27.1 / 44.3 / 44.9 (30) | 0.1 / 0.1 / 0.1 (30) | 1 | 0.01 / 0.04 / 0.05 (30) | 10.55 / 0.01 |
| large | 40.1 / 44.0 / 64.2 (60) | 2.18 / 8.83 / 37.54 (60) | 42.5 / 47.1 / 49.2 (30) | 0.1 / 0.1 / 0.1 (30) | 1 | 0.01 / 0.04 / 0.05 (30) | 17.69 / 0.02 |

#### Cold scan with the popover open

| Dataset | Scan wall | `indexing` publishes | Update passes | Longest span | Spans: median / p95 / worst (n) | Main-thread busy, total |
|---|---|---|---|---|---|---|
| small | 0.45 s | 2 | 4 | 39.3 ms | 0.03 / 39.25 / 39.25 (9) | 82.9 ms |
| medium | 4.85 s | 5 | 7 | 33.2 ms | 0.03 / 33.18 / 33.18 (15) | 116.6 ms |
| large | 24.37 s | 14 | 16 | 52.5 ms | 0.05 / 34.09 / 52.47 (33) | 299.3 ms |
