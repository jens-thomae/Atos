#!/usr/bin/env python3
"""Markdown summary of one `measure.sh` results directory (used for the job summary and the results document).
Usage: summarize.py <results-dir>"""
import glob, json, os, statistics, sys

root = sys.argv[1]
APPS = [("iced", "libcosmic (iced)"), ("slint", "Slint")]


def load(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return None


def fmt(vals, unit="", digits=1):
    if not vals:
        return "n/a"
    v = sorted(vals)
    r = lambda x: f"{x:.{digits}f}"
    return f"**{r(statistics.median(v))}**{unit} ({r(v[0])}–{r(v[-1])}, n={len(v)})"


def harness(app, folder):
    """(cold_ms list, timeouts, rss list, cpu list, exit codes) over the runs of one app and folder."""
    cold, rss, cpu, rcs = [], [], [], []
    for rcf in sorted(glob.glob(f"{root}/m1-m4/{app}-{folder}-*.rc")):
        rc = int(open(rcf).read())
        rcs.append(rc)
        j = load(rcf[:-3] + ".json")
        if rc != 2 and j:
            cold.append(j["cold_start_ms"]); rss.append(j["idle_rss_mb"]); cpu.append(j["idle_cpu_percent"])
    return cold, rcs.count(2), rss, cpu, rcs


print("### Environment\n")
print("```text\n" + open(f"{root}/environment.txt").read().strip() + "\n```\n")

print("### M1–M4: harness (`tools/budgets`)\n")
print("Median (min–max, n runs). Cold start is with a warm page cache.\n")
print("| Metric | Budget | " + " | ".join(t for _, t in APPS) + " |\n| --- | --- | " + " | ".join("---" for _ in APPS) + " |")
cells = {}
for a, _ in APPS:
    for f in ("small", "10k"):
        cells[a, f] = harness(a, f)


def row(label, budget, pick, unit, digits=1, f="small", timeout_note=True):
    out = []
    for a, _ in APPS:
        c = cells[a, f]
        s = fmt(pick(c), unit, digits)
        if timeout_note and c[1]:
            s += f"; **{c[1]} of {len(c[4])} runs: > 3000 ms (timeout)**"
        out.append(s)
    print(f"| {label} | {budget} | " + " | ".join(out) + " |")


row("M1 cold start, `small`", "≤ 300 ms", lambda c: c[0], " ms")
row("M2 10,000-item first paint, `10k`", "≤ 500 ms", lambda c: c[0], " ms", f="10k")
row("M3 idle RSS, `small`, 5 s after first frame", "800 MB (desktop)", lambda c: c[2], " MB")
row("M4 idle CPU, `small`", "≤ 1 %", lambda c: c[3], " %", digits=2)
print()
for a, t in APPS:
    for f in ("small", "10k"):
        w = {j["cpu_window_s"] for p in glob.glob(f"{root}/m1-m4/{a}-{f}-*.json") if (j := load(p))}
        print(f"- {t} `{f}`: harness exit codes {cells[a, f][4]}, CPU window {sorted(w)} s")
print()

print("### M5: frame interval while scrolling the 10,000-item list\n")
print("Median over runs of each run's value (min–max). Dropped = intervals > 1.5 × refresh period.\n")
print("| | " + " | ".join(t for _, t in APPS) + " |\n| --- | " + " | ".join("---" for _ in APPS) + " |")
m5 = {a: [j for p in sorted(glob.glob(f"{root}/m5/{a}-*.json")) if (j := load(p))] for a, _ in APPS}
for key, lab, d in (("p50_ms", "p50", 1), ("p95_ms", "p95", 1), ("p99_ms", "p99", 1), ("max_ms", "max", 1),
                    ("commits", "commits per run", 0), ("dropped", "dropped frames per run", 0)):
    print(f"| {lab} | " + " | ".join(fmt([j[key] for j in m5[a]], " ms" if key.endswith("ms") else "", d) for a, _ in APPS) + " |")
print()

print("### M6: accessibility tree\n")
for a, t in APPS:
    j = load(f"{root}/m6/{a}/m6.json")
    if not j:
        print(f"**{t}**: no result\n")
        continue
    print(f"**{t}**: {j['failing']} of {j['total']} checked controls missing or wrong. "
          f"Nodes in the tree: {j['node_count']}. Focused node(s): {j['focused']}\n")
    print("| Control | Expected role | Expected name | Result |\n| --- | --- | --- | --- |")
    for r in j["rows"]:
        print(f"| {r['control']} | {r['expected_role']} | {r['expected_name'] or '–'} | {r['result']} |")
    print()

print("### M7: keyboard walkthrough (automated checks)\n")
print("`pass`/`fail` come from AT-SPI, stdout or the clipboard; `unverifiable` means the toolkit exposes nothing to check.\n")
for a, t in APPS:
    j = load(f"{root}/m7/{a}/m7.json")
    if not j:
        print(f"**{t}**: no result\n")
        continue
    print(f"**{t}**\n\n| Step | Check | Result | Observed |\n| --- | --- | --- | --- |")
    for s in j:
        for c in s["checks"]:
            print(f"| {s['step']} | {c['check']} | {c['result']} | {c['observed']} |")
    print()

m9 = load(f"{root}/m9.json")
if m9:
    print("### M9: build\n")
    print("| | " + " | ".join(t for _, t in APPS) + " |\n| --- | " + " | ".join("---" for _ in APPS) + " |")
    for k, lab in (("build_seconds", "Clean release build (s)"), ("stripped_bytes", "Stripped binary (bytes)"),
                   ("crates", "Crates in Cargo.lock"), ("lines", "Lines of Rust and markup")):
        print(f"| {lab} | " + " | ".join(str(m9[a][k]) for a, _ in APPS) + " |")
