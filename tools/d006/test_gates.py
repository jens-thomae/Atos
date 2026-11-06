#!/usr/bin/env python3
"""Edge cases of the G1–G5 logic in summarize.py on synthetic results (Intel renderer lines). No framework:
exits non-zero with the failing case. Usage: test_gates.py"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def result(cold=(100,) * 5, c10=(100,) * 5, cpu=0.1, dropped=(0,) * 5, rss=150, m5rc=None, runs=5, egl="Mesa Intel(R) UHD Graphics"):
    d = tempfile.mkdtemp()
    w = lambda p, t: (os.makedirs(os.path.dirname(f"{d}/{p}"), exist_ok=True), open(f"{d}/{p}", "w").write(t))
    w("environment.txt", f"runs: {runs}\negl: {egl}\nrenderer slint: slint gl Mesa Intel(R) UHD Graphics\noutput: HEADLESS-1 1920x1080@60Hz scale 1.0\n")
    for f, vals in (("small", cold), ("10k", c10)):
        for i, v in enumerate(vals, 1):
            j = {"cold_start_ms": v, "idle_rss_mb": rss, "idle_cpu_percent": cpu, "cpu_window_s": 5}
            w(f"m1-m4/slint-{f}-{i}.json", json.dumps(j)); w(f"m1-m4/slint-{f}-{i}.rc", "0")
    for i, v in enumerate(dropped, 1):
        j = {k: 1 for k in ("p50_ms", "p95_ms", "p99_ms", "max_ms", "commits")} | {"dropped": v}
        w(f"m5/slint-{i}.json", json.dumps(j)); w(f"m5/slint-{i}.rc", str((m5rc or {}).get(i, 0)))
    return d


def verdict(**kw):
    out = subprocess.run([sys.executable, f"{HERE}/summarize.py", result(**kw)], capture_output=True, text=True, check=True).stdout
    line = next(l for l in out.splitlines() if l.startswith("| Slint default"))
    return line.split("|")[-2].strip().strip("*")


cases = [
    ("all pass", {}, "PASS"),
    ("G1 300 ms", dict(cold=(300, 1, 1, 1, 1)), "PASS"), ("G1 301 ms", dict(cold=(301, 1, 1, 1, 1)), "FAIL"),
    ("G2 500 ms", dict(c10=(500, 1, 1, 1, 1)), "PASS"), ("G2 501 ms", dict(c10=(501, 1, 1, 1, 1)), "FAIL"),
    ("G3 1 %", dict(cpu=1.0), "PASS"), ("G3 1.01 %", dict(cpu=1.01), "FAIL"),
    ("G4 0,0,0,1,1", dict(dropped=(0, 0, 0, 1, 1)), "PASS"),
    ("G4 0,0,0,0,2", dict(dropped=(0, 0, 0, 0, 2)), "FAIL"), ("G4 0,0,1,1,1", dict(dropped=(0, 0, 1, 1, 1)), "FAIL"),
    ("G4 crashed run", dict(m5rc={3: 1}), "FAIL"),
    ("G5 300 MB", dict(rss=300), "PASS"), ("G5 301 MB", dict(rss=301), "FAIL"),
    ("missing M5 runs", dict(dropped=(0, 0)), "FAIL"), ("missing M1 launches", dict(cold=(1, 1)), "FAIL"),
    ("missing M2 launches", dict(c10=(1, 1)), "FAIL"),
    ("software egl", dict(egl="llvmpipe (LLVM 20.1.2, 128 bits)"), "not measured"),
]
bad = [(n, want, got) for n, kw, want in cases if (got := verdict(**kw)) != want]
for b in bad:
    print("FAIL", *b)
sys.exit(1 if bad else print(f"{len(cases)} gate cases ok") or 0)
