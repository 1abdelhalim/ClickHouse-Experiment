#!/usr/bin/env python3
"""Collapse results/<dir>/*_hot.csv into a single SUMMARY.md table.

Columns per CSV (from bench/run.sh):
  mode,run,wall_ms,duration_ms,read_rows,read_bytes,memory_usage,
  selected_marks,selected_parts,selected_ranges
"""
import csv, glob, os, statistics, sys

d = sys.argv[1] if len(sys.argv) > 1 else "results/linux"

def med(xs):
    xs = sorted(xs)
    return xs[len(xs)//2] if xs else 0

rows = []
for path in sorted(glob.glob(os.path.join(d, "*_hot.csv"))):
    label = os.path.basename(path)[:-len("_hot.csv")]
    dur, rr, rb, sm = [], [], [], []
    with open(path) as f:
        for rec in csv.DictReader(f):
            try:
                dur.append(int(rec["duration_ms"])); rr.append(int(rec["read_rows"]))
                rb.append(int(rec["read_bytes"])); sm.append(int(rec.get("selected_marks") or 0))
            except (ValueError, KeyError):
                pass
    if not dur:
        continue
    rows.append((label, len(dur), med(dur), min(dur), max(dur), med(rr), med(rb), med(sm)))

base = next((r for r in rows if r[0] == "baseline"), None)

print(f"# Linux run — SUMMARY\n\n_dir: `{d}`_\n")
print("| label | runs | p50 ms | min | max | read_rows p50 | read_bytes p50 | sel_marks p50 | vs baseline (rows) |")
print("|---|---|---|---|---|---|---|---|---|")
for label, n, p50, mn, mx, rr, rb, sm in rows:
    ratio = f"{base[5]/rr:.1f}x" if base and rr else "-"
    print(f"| {label} | {n} | {p50} | {mn} | {mx} | {rr:,} | {rb:,} | {sm:,} | {ratio} |")

il = os.path.join(d, "interleaved.csv")
if os.path.exists(il):
    agg = {}
    with open(il) as f:
        for rec in csv.DictReader(f):
            agg.setdefault(rec["label"], []).append(int(rec["duration_ms"]))
    print("\n## Interleaved pass (drift-controlled)\n")
    print("| label | rounds | p50 ms | min | max |")
    print("|---|---|---|---|---|")
    for label, xs in agg.items():
        print(f"| {label} | {len(xs)} | {med(xs)} | {min(xs)} | {max(xs)} |")
