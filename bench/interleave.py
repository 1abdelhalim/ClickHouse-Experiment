#!/usr/bin/env python3
"""Interleaved re-measurement of several queries, round-robin.

Runs label=query pairs in A,B,C,A,B,C,... order for N rounds so that any
time-correlated drift (throttling, background merges, noisy neighbour) hits
every variant equally instead of being confounded with the variant itself.

Metrics come from system.query_log by query_id. Emits CSV to stdout:
    round,label,wall_ms,duration_ms,read_rows,read_bytes,selected_marks
"""
import os, subprocess, sys, time

CH = os.environ.get("CH", "clickhouse client").split()
ROUNDS = int(os.environ.get("INTERLEAVE_ROUNDS", "15"))
WARMUP = 2

def ch(sql, qid=None):
    cmd = CH + (["--query_id", qid] if qid else []) + ["-q", sql]
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout

pairs = []
for arg in sys.argv[1:]:
    label, _, path = arg.partition("=")
    pairs.append((label, open(path).read()))

for label, sql in pairs:            # warm every variant first
    for _ in range(WARMUP):
        ch(sql)

print("round,label,wall_ms,duration_ms,read_rows,read_bytes,selected_marks")
for r in range(1, ROUNDS + 1):
    for label, sql in pairs:
        qid = f"il_{label}_{r}_{time.time_ns()}"
        t0 = time.time_ns()
        ch(sql, qid)
        wall = (time.time_ns() - t0) // 1_000_000
        ch("SYSTEM FLUSH LOGS")
        row = ch(
            "SELECT query_duration_ms, read_rows, read_bytes, "
            "ProfileEvents['SelectedMarks'] "
            f"FROM system.query_log WHERE type='QueryFinish' AND query_id='{qid}' "
            "ORDER BY event_time_microseconds DESC LIMIT 1 FORMAT CSV"
        ).strip()
        print(f"{r},{label},{wall},{row}")
        sys.stdout.flush()
