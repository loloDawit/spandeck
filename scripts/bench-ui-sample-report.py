#!/usr/bin/env python3
"""#88: groups the main thread of a macOS `sample` report into frame groups (docs/perf/2026-10-19-m2pro-ui-88/profiles).

    scripts/bench-ui-sample-report.py SAMPLE.txt

Counts are inclusive samples on the main thread. A frame counts for a group only when no caller already matched that
group, so recursion isn't counted twice; groups overlap one another (Charts frames are inside the SwiftUI update).
Prints counts and shares only: no symbol path or address.
"""
import re
import sys
groups={
 'idle (mach_msg wait)': r'mach_msg2_trap|__CFRunLoopServiceMachPort',
 'run-loop observer pass (beforeWaiting)': r'__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER',
 'SwiftUI graph update (AG::Subgraph::update / ViewGraph)': r'AG::Subgraph::update|ViewGraph\.(updateOutputs|runTransaction)',
 'Charts (any frame in Charts.framework)': r'\(in Charts\)',
 'LiveChart.body': r'LiveChart\.body',
 'DailyChart.body': r'DailyChart\.body',
 'PopoverView/cards .body (Headroom views)': r'(PopoverView|SystemGrid|LimitsCard|UsageCard|Footer|MetricCard|CoreBars|BatteryCard|StatTile|UsageBar|LimitRow)\.body',
 'Text layout (CoreText / NSAttributedString / TextLayout)': r'\(in CoreText\)|NSTextLineFragment|TextLayout',
 'Layout (sizeThatFits/placeSubviews)': r'sizeThatFits|placeSubviews|LayoutComputer',
 'ledger refresh continuation (refreshUsage)': r'refreshUsage',
 'store.record / StatusRenderer': r'Store\.record|StatusRenderer\.render',
}
txt=open(sys.argv[1]).read()
lines=txt.split('\n')
# find main thread block
start=None
for i,l in enumerate(lines):
    if 'com.apple.main-thread' in l and re.match(r'\s+\d+ Thread_',l): start=i;break
total=int(re.match(r'\s+(\d+)',lines[start]).group(1))
res={g:0 for g in groups}
stack=[] # (depth, set of groups matched at or above)
for l in lines[start+1:]:
    m=re.match(r'^(\s+)([+!:| ]*)(\d+) (.*)',l)
    if not m: 
        if l.strip()=='' : break
        continue
    if re.match(r'\s+\d+ Thread_',l): break
    depth=len(m.group(1))+len(m.group(2)); n=int(m.group(3)); sym=m.group(4)
    while stack and stack[-1][0]>=depth: stack.pop()
    anc=stack[-1][1] if stack else frozenset()
    mine=set(anc)
    for g,p in groups.items():
        if re.search(p,sym):
            if g not in anc: res[g]+=n
            mine.add(g)
    stack.append((depth,frozenset(mine)))
print(sys.argv[1].split('/')[-1],'main-thread samples',total)
for g,v in res.items(): print(f'  {v:6d}  {100*v/total:5.1f}%  {g}')
