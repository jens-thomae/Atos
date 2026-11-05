#!/usr/bin/env python3
"""M5 (brief §7): frame intervals from a `WAYLAND_DEBUG=client` log. Prints JSON.
Usage: frames.py <run.log> [refresh-hz=60]"""
import json, re, sys
from collections import defaultdict

log, hz = sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
commit = re.compile(r"^\[\s*(\d+\.\d+)\]\s+->\s+wl_surface@(\d+)\.commit\(\)")
commits, started, done = defaultdict(list), False, False
for line in open(log, errors="replace"):
    if "D006_AUTOSCROLL_DONE" in line:
        done = True
        break
    if "BUDGET_FIRST_FRAME" in line:
        started = True
        continue
    m = commit.match(line)
    if m and started:
        commits[m.group(2)].append(float(m.group(1)))
assert done and commits, "no BUDGET_FIRST_FRAME ... D006_AUTOSCROLL_DONE window with commits"
main = max(commits, key=lambda s: len(commits[s]))
t = commits[main]
iv = sorted(b - a for a, b in zip(t, t[1:]))
pct = lambda p: iv[min(len(iv) - 1, int(p / 100 * len(iv)))]
limit = 1.5 * 1000 / hz
print(json.dumps({
    "surface": main, "commits": len(t), "duration_ms": round(t[-1] - t[0], 1),
    "p50_ms": pct(50), "p95_ms": pct(95), "p99_ms": pct(99), "max_ms": iv[-1],
    "dropped": sum(1 for x in iv if x > limit), "dropped_limit_ms": limit,
    "other_surface_commits": sum(len(v) for k, v in commits.items() if k != main),
}))
