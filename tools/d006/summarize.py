#!/usr/bin/env python3
"""Markdown summary of one `measure.sh` results directory (used for the job summary and the results document).
Usage: summarize.py <results-dir>"""
import glob, json, os, re, statistics, sys

root = sys.argv[1]
LABELS = {"iced": "libcosmic default (tiny-skia)", "iced-wgpu": "libcosmic `wgpu`",
          "slint": "Slint default (femtovg, GL)", "slint-sw": "Slint software renderer",
          "slint-fork": "Slint fork (GL), tree off", "slint-fork-a11y": "Slint fork (GL), tree on"}
# Older results directories (#12) have only iced and slint; those before #97 have no fork variants.
APPS = [(k, t) for k, t in LABELS.items() if glob.glob(f"{root}/m1-m4/{k}-small-*.rc")]
SHELL_SHARE_MB, SHELL_N = 300, 1  # D-006 §4.1 G5: owner-confirmed share (spec §5 D-006), N = 1 process


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
        if rc == 2:
            cold.append(3000.0)  # timeout: counted as the 3 s limit, a lower bound
        elif j:
            cold.append(j["cold_start_ms"]); rss.append(j["idle_rss_mb"]); cpu.append(j["idle_cpu_percent"])
    return cold, rcs.count(2), rss, cpu, rcs


print("### Environment\n")
print("```text\n" + open(f"{root}/environment.txt").read().strip() + "\n```\n")

# --- G1–G5 (D-006 §4.1) ------------------------------------------------------------------
env = open(f"{root}/environment.txt").read()
# Hard-coded on purpose: a results directory can never be re-read with a weaker rule (§3.3, §4.1).
pattern = "Intel"
soft = r"llvmpipe|lavapipe|softpipe|swrast"
is_gpu = lambda text: bool(re.search(pattern, text, re.I)) and not re.search(soft, text, re.I)
RUNS_MIN = 5  # §4.1: each variant gets 5 runs
runs = int((re.search(r"^runs: (\d+)", env, re.M) or [0, 0])[1])


def proof(a):
    """(True, how) if the run of this variant counts as a GPU run, else (False, why)."""
    egl = (re.search(r"^egl: (.*)$", env, re.M) or [0, "none"])[1]
    if not is_gpu(egl):
        return False, f"compositor's Wayland `egl:` line is `{egl}`"
    line = (re.search(rf"^renderer {re.escape(a)}: (.*)$", env, re.M) or [0, "none"])[1]
    if line == "none":
        return False, "the app logged no renderer line"
    if a in ("iced", "slint-sw"):  # CPU renderers by design: nothing to prove beyond the compositor
        return (True, line) if re.search(r"tiny-skia|software", line, re.I) else (False, f"unexpected renderer `{line}`")
    if a == "iced-wgpu" and not re.search("vulkan", line, re.I):
        return False, f"wgpu did not use Vulkan: `{line}`"
    return (True, line) if is_gpu(line) else (False, f"app renderer is `{line}`")


def gates(a, cells, m5):
    """{gate: (ok, text)} for one variant (§4.1). Every run counts: a missing, crashed or timed-out run fails its gate."""
    cold, rss, cpu = cells[a, "small"][0], cells[a, "small"][2], cells[a, "small"][3]
    c10 = cells[a, "10k"][0]
    n1, n2 = len(cells[a, "small"][4]), len(cells[a, "10k"][4])  # launches that left an exit code
    rcs = [int(open(f).read()) for f in sorted(glob.glob(f"{root}/m5/{a}-[0-9]*.rc"))]
    dr = [j["dropped"] for j in m5[a]]
    full = lambda n: n == runs and n >= RUNS_MIN
    note = lambda n: "" if full(n) else f"; **{n} of {runs} runs (need {RUNS_MIN}+ and all)**"
    out = {}
    out["G1 cold start: every launch ≤ 300 ms"] = (
        full(n1) and len(cold) == n1 and max(cold) <= 300, (f"max {max(cold):.0f} ms of {len(cold)}" if cold else "n/a") + note(n1))
    out["G2 10k first paint: every launch ≤ 500 ms"] = (
        full(n2) and len(c10) == n2 and max(c10) <= 500, (f"max {max(c10):.0f} ms of {len(c10)}" if c10 else "n/a") + note(n2))
    out["G3 idle CPU: median ≤ 1 %"] = (bool(cpu) and statistics.median(cpu) <= 1, f"median {statistics.median(cpu):.2f} %" if cpu else "n/a")
    ok4 = full(len(rcs)) and len(dr) == len(rcs) and all(r == 0 for r in rcs) and statistics.median(dr) == 0 and max(dr) <= 1
    out["G4 scrolling: median 0 dropped, no run above 1"] = (
        ok4, (f"median {statistics.median(dr):g}, max {max(dr)} of {len(dr)} runs" if dr else "n/a")
        + (f"; **scroll exit codes {rcs}**" if any(rcs) else "") + note(len(rcs)))
    out[f"G5 shell memory: {SHELL_N} × M3 ≤ {SHELL_SHARE_MB} MB"] = (
        bool(rss) and SHELL_N * statistics.median(rss) <= SHELL_SHARE_MB, f"{SHELL_N} × {statistics.median(rss):.0f} MB" if rss else "n/a")
    return out


print("### M1–M4: harness (`tools/budgets`)\n")
print("Median (min–max, n runs). Page cache is warm. M3 and M4 use only the runs that gave a reading.\n")
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
            s += f"; **{c[1]} of {len(c[4])} runs: > 3000 ms (timeout), counted as 3000 ms, gate fail**"
        out.append(s)
    print(f"| {label} | {budget} | " + " | ".join(out) + " |")


row("M1 cold start, `small`", "≤ 300 ms", lambda c: c[0], " ms")
row("M2 10,000-item first paint, `10k`", "≤ 500 ms", lambda c: c[0], " ms", f="10k")
row("M3 idle RSS, `small`, 5 s after first frame", "800 MB (desktop)", lambda c: c[2], " MB", timeout_note=False)
row("M4 idle CPU, `small`", "≤ 1 %", lambda c: c[3], " %", digits=2, timeout_note=False)
print()
for a, t in APPS:
    for f in ("small", "10k"):
        w = {j["cpu_window_s"] for p in glob.glob(f"{root}/m1-m4/{a}-{f}-*.json") if (j := load(p))}
        print(f"- {t} `{f}`: harness exit codes {cells[a, f][4]}, CPU window {sorted(w)} s")
print()

print("### M5: frame interval while scrolling the 10,000-item list\n")
print("Median over runs of each run's value (min–max). Dropped = intervals > 1.5 × refresh period.\n")
print("| | " + " | ".join(t for _, t in APPS) + " |\n| --- | " + " | ".join("---" for _ in APPS) + " |")
m5 = {a: [j for p in sorted(glob.glob(f"{root}/m5/{a}-[0-9]*.json")) if (j := load(p))] for a, _ in APPS}
for key, lab, d in (("p50_ms", "p50", 1), ("p95_ms", "p95", 1), ("p99_ms", "p99", 1), ("max_ms", "max", 1),
                    ("commits", "commits per run", 0), ("dropped", "dropped frames per run", 0)):
    print(f"| {lab} | " + " | ".join(fmt([j[key] for j in m5[a]], " ms" if key.endswith("ms") else "", d) for a, _ in APPS) + " |")
print()

print("### G1–G5: GPU gates (`docs/decisions/D-006-toolkit.md` §4.1)\n")
print(f"A variant is evaluated only if its run is proven to use the GPU: the compositor's Wayland `egl:` line and the app's own "
      f"renderer line must match `{pattern}` (CPU renderers by design need only the `egl:` line). Otherwise **not measured**, never a GPU number. "
      f"G5 uses N = {SHELL_N} and a {SHELL_SHARE_MB} MB shell share. Every run must be present: {RUNS_MIN}+ runs, none missing or crashed.\n")
hz = re.search(r"^output: .*@(\d+)Hz", env, re.M)
if not hz or int(hz[1]) != 60:
    print(f"> **Warning:** the output runs at {hz[1] + ' Hz' if hz else 'an unknown rate'}, but G4 is defined at 60 Hz (25 ms). Dropped frames here use 1.5 × that output's period.\n")
print("| Variant | Renderer proof | " + " | ".join(["G1", "G2", "G3", "G4", "G5"]) + " | Result |\n| --- | --- | --- | --- | --- | --- | --- | --- |")
details = []
for a, t in APPS:
    ok, why = proof(a)
    if not ok:
        print(f"| {t} | ❌ {why} | – | – | – | – | – | **not measured** |")
        continue
    g = gates(a, cells, m5)
    details += [f"- {t}: {k}: {'✅' if v[0] else '❌'} {v[1]}" for k, v in g.items()]
    print(f"| {t} | ✅ `{why}` | " + " | ".join("✅" if v[0] else "❌" for v in g.values()) + f" | **{'PASS' if all(v[0] for v in g.values()) else 'FAIL'}** |")
print("\n" + "\n".join(details) + "\n")

print("### M6: accessibility tree\n")
for a, t in APPS:
    if not os.path.isdir(f"{root}/m6/{a}"):
        continue
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
    if not os.path.isdir(f"{root}/m7/{a}"):
        continue
    j = load(f"{root}/m7/{a}/m7.json")
    if not j:
        print(f"**{t}**: no result\n")
        continue
    print(f"**{t}**\n\n| Step | Check | Result | Observed |\n| --- | --- | --- | --- |")
    for s in j:
        for c in s["checks"]:
            print(f"| {s['step']} | {c['check']} | {c['result']} | {c['observed']} |")
    print()

LABELS_M9 = [(k, LABELS[k]) for k in ("iced", "slint")]
m9 = load(f"{root}/m9.json")
if m9:
    print("### M9: build\n")
    print("| | " + " | ".join(t for _, t in LABELS_M9) + " |\n| --- | " + " | ".join("---" for _ in LABELS_M9) + " |")
    for k, lab in (("build_seconds", "Clean release build (s)"), ("stripped_bytes", "Stripped binary (bytes)"),
                   ("crates", "Crates in Cargo.lock"), ("lines", "Lines of Rust and markup")):
        print(f"| {lab} | " + " | ".join(str(m9[a][k]) for a, _ in LABELS_M9) + " |")
