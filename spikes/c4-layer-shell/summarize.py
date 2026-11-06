#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Summary of one measure.sh run (#59). Usage: summarize.py <out dir>"""
import json, os, statistics, sys

out = sys.argv[1]
BUDGET_MS, SHELL_MB = 100, 300  # §7 popover budget; D-006 shell share (single process)


def read(name):
    p = os.path.join(out, name)
    return open(p).read() if os.path.exists(p) else ""


def ok(b):
    return "✅" if b else "❌"


print("### #59 layer-shell spike\n")
print("```\n" + read("environment.txt").strip() + "\n" + read("popover-pixels.txt").strip() + "\n```\n")
print("| Metric | Budget | Measured | Result |\n| --- | --- | --- | --- |")
for run, label in (("0-cold", "new EGL context per open, cold shader cache"),
                   ("1-cold", "pre-warmed popup pool, cold shader cache"),
                   ("1-warm", "pre-warmed popup pool, warm shader cache")):
    vis = []
    for line in read(f"popover-{run}.txt").splitlines():
        f = line.split()
        if f[0] == "T59_POPOVER_VISIBLE_MS" and f[1].replace(".", "").isdigit():
            vis.append(float(f[1]))
    if not vis:
        print(f"| Popover fully visible ({label}) | ≤ {BUDGET_MS} ms | not measured | ❌ |")
        continue
    rest = vis[1:] or vis
    print(f"| Popover fully visible, first open ({label}) | ≤ {BUDGET_MS} ms | {vis[0]:.1f} ms | {ok(vis[0] <= BUDGET_MS)} |")
    print(f"| Popover fully visible, later opens, median / max, n={len(rest)} ({label}) | ≤ {BUDGET_MS} ms | "
          f"{statistics.median(rest):.1f} / {max(rest):.1f} ms | {ok(max(rest) <= BUDGET_MS)} |")
    rss = dict(l.split(":", 1) for l in read(f"rss-{run}.txt").splitlines() if ":" in l)
    if "VmRSS" in rss:
        mb = int(rss["VmRSS"].split()[0]) / 1024
        parts = ", ".join(f"{k} {int(v.split()[0]) / 1024:.1f}" for k, v in rss.items() if k != "VmRSS")
        print(f"| Idle RSS after {len(vis)} opens ({label}) | ≤ {SHELL_MB} MB | {mb:.1f} MB ({parts}) | {ok(mb <= SHELL_MB)} |")
try:
    b = json.load(open(os.path.join(out, "budgets.json")))
except (OSError, ValueError):
    b = {}
if "cold_start_ms" in b:
    print(f"| Start to first panel frame (budgets harness) | – | {b['cold_start_ms']:.0f} ms | – |")
if "idle_rss_mb" in b:
    print(f"| Idle RSS 5 s after first frame (budgets harness) | ≤ {SHELL_MB} MB | {b['idle_rss_mb']:.1f} MB | {ok(b['idle_rss_mb'] <= SHELL_MB)} |")
if "idle_cpu_percent" in b:
    print(f"| Idle CPU over {b.get('cpu_window_s')} s (budgets harness) | ≤ 1 % | {b['idle_cpu_percent']:.2f} % | {ok(b['idle_cpu_percent'] <= 1)} |")
