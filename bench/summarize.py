#!/usr/bin/env python3
"""Collapse results/<dir>/*_{hot,directio,cold}.csv into SUMMARY.md.

CSV columns (bench/run.sh v2):
  regime,run,wall_ms,duration_ms,read_rows,read_bytes,memory_usage,
  selected_marks,selected_parts,selected_ranges
"""
import csv, glob, math, os, re, sys

d = sys.argv[1] if len(sys.argv) > 1 else "results/linux"


def stats(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return dict(n=0)
    mean = sum(xs) / n
    var = sum((x - mean) ** 2 for x in xs) / n
    sd = math.sqrt(var)
    return dict(n=n, p50=xs[n // 2], mn=xs[0], mx=xs[-1],
                mean=mean, sd=sd, cv=(100 * sd / mean if mean else 0))


def load(path):
    dur, rr, rb, sm = [], [], [], []
    with open(path) as f:
        for rec in csv.DictReader(f):
            try:
                dur.append(int(rec["duration_ms"])); rr.append(int(rec["read_rows"]))
                rb.append(int(rec["read_bytes"])); sm.append(int(rec.get("selected_marks") or 0))
            except (ValueError, KeyError):
                pass
    return dur, rr, rb, sm


rows = {}   # (label, regime) -> (durstats, rr_p50, rb_p50, sm_p50)
for path in sorted(glob.glob(os.path.join(d, "*.csv"))):
    m = re.match(r"(.+)_(hot|directio|cold)\.csv$", os.path.basename(path))
    if not m:
        continue
    label, regime = m.group(1), m.group(2)
    dur, rr, rb, sm = load(path)
    if not dur:
        continue
    s = stats(dur)
    rows[(label, regime)] = (s, sorted(rr)[len(rr)//2], sorted(rb)[len(rb)//2], sorted(sm)[len(sm)//2])

print(f"# Experiment v2 — SUMMARY\n\n_dir: `{d}`_\n")

for regime in ("hot", "directio", "cold"):
    sub = {l: v for (l, r), v in rows.items() if r == regime}
    if not sub:
        continue
    base = sub.get("baseline")
    print(f"## Regime: {regime}\n")
    print("| label | n | p50 ms | min–max | CV | read_rows p50 | read_bytes p50 | marks p50 | ×rows vs base |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|--:|")
    for label in sorted(sub):
        s, rr, rb, sm = sub[label]
        ratio = f"{base[1]/rr:.1f}×" if base and rr else "—"
        flag = " ⚠︎" if s["cv"] > 10 else ""
        print(f"| {label} | {s['n']} | {s['p50']} | {s['mn']}–{s['mx']} | {s['cv']:.0f}%{flag} "
              f"| {rr:,} | {rb:,} | {sm:,} | {ratio} |")
    print()

il = os.path.join(d, "interleaved.csv")
if os.path.exists(il):
    agg = {}
    with open(il) as f:
        for rec in csv.DictReader(f):
            agg.setdefault(rec["label"], []).append(int(rec["duration_ms"]))
    if agg:
        print("## Interleaved pass (directio, drift-controlled)\n")
        print("| label | rounds | p50 ms | min–max | CV |")
        print("|---|--:|--:|--:|--:|")
        for label, xs in agg.items():
            s = stats(xs)
            flag = " ⚠︎" if s["cv"] > 10 else ""
            print(f"| {label} | {s['n']} | {s['p50']} | {s['mn']}–{s['mx']} | {s['cv']:.0f}%{flag} |")

print("\n_⚠︎ = CV > 10%: run-to-run noise exceeds the signal; treat that median as directional only._")
