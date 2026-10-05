#!/usr/bin/env python3
"""Bench for the picture-based lookup (VisualProbe): real screenshots and the box
that should be found at each point, checked by hand once and kept as the answer.

The pictures show people's screens, so they live only on this Mac, in ~/.aki/bench
(never in the repo): cases.json lists, per picture, points and the expected first
box [x, y, width, height] in points. Run after changing VisualProbe:

    python3 scripts/visual-bench.py            # check every case
    python3 scripts/visual-bench.py --record   # take today's answers as the right ones (after looking!)
"""
import json, os, re, subprocess, sys

BENCH = os.path.expanduser("~/.aki/bench")
CASES = os.path.join(BENCH, "cases.json")
AKI = os.path.join(os.path.dirname(__file__), "..", ".build", "release", "Aki")
TOLERANCE = 6  # points, on each side

def probe(picture, points):
    out = os.path.join(BENCH, "out-" + os.path.splitext(picture)[0] + ".png")
    args = [AKI, "visual-probe", os.path.join(BENCH, picture), out] + [f"{x},{y}" for x, y in points]
    found = {}
    for line in subprocess.run(args, capture_output=True, text=True, check=True).stdout.splitlines():
        m = re.match(r"(\d+(?:\.\d+)?),(\d+(?:\.\d+)?): (\d+),(\d+) (\d+)x(\d+)", line)
        if m:
            found[(float(m[1]), float(m[2]))] = [int(m[3]), int(m[4]), int(m[5]), int(m[6])]
    return found

def main():
    if not os.path.exists(CASES):
        print("no bench on this Mac (~/.aki/bench/cases.json)"); return 0
    subprocess.run(["swift", "build", "-c", "release"], check=True, capture_output=True, cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    cases = json.load(open(CASES))
    record = "--record" in sys.argv
    passed = failed = 0
    for picture, points in cases.items():
        found = probe(picture, [(p["x"], p["y"]) for p in points])
        for p in points:
            got = found.get((float(p["x"]), float(p["y"])))
            if record:
                p["box"] = got; continue
            want = p.get("box")
            ok = got and want and all(abs(a - b) <= TOLERANCE for a, b in zip(got, want))
            passed += bool(ok); failed += not ok
            if not ok:
                print(f"✗ {picture} {p['name']} ({p['x']},{p['y']}): want {want}, got {got}")
    if record:
        json.dump(cases, open(CASES, "w"), indent=1, ensure_ascii=False); print("recorded"); return 0
    print(f"{passed}/{passed + failed} boxes right")
    return 1 if failed else 0

sys.exit(main())
