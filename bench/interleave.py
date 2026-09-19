#!/usr/bin/env python3
"""Interleaved re-measurement of several queries, round-robin.

Runs label=query pairs in A,B,C,A,B,C,... order for N rounds so any
time-correlated drift (throttling, background merges, noisy neighbour) hits
every variant equally instead of being confounded with the variant itself.

Env:
  CH                 client command (default "clickhouse client")
  INTERLEAVE_ROUNDS  rounds (default 20)
  INTERLEAVE_REGIME  "hot" (default) or "directio" (O_DIRECT + drop CH caches each run)
  MAX_THREADS        pinned max_threads (default 4)

CSV to stdout: round,label,wall_ms,duration_ms,read_rows,read_bytes,selected_marks
"""
import os, subprocess, sys, time

CH = os.environ.get("CH", "clickhouse client").split()
ROUNDS = int(os.environ.get("INTERLEAVE_ROUNDS", "20"))
REGIME = os.environ.get("INTERLEAVE_REGIME", "hot")
MAX_THREADS = os.environ.get("MAX_THREADS", "4")
WARMUP = 2

SETTINGS = f"max_threads={MAX_THREADS}, use_query_cache=0, use_query_condition_cache=0"
if REGIME == "directio":
    SETTINGS += ", min_bytes_to_use_direct_io=1"


def ch(sql, qid=None):
    cmd = CH + (["--query_id", qid] if qid else []) + ["-q", sql]
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def drop_caches():
    for c in (
        "SYSTEM DROP MARK CACHE",
        "SYSTEM DROP UNCOMPRESSED CACHE",
        "SYSTEM DROP QUERY CACHE",
        "SYSTEM DROP QUERY CONDITION CACHE",
    ):
        try:
            ch(c)
        except subprocess.CalledProcessError:
            pass


pairs = []
for arg in sys.argv[1:]:
    label, _, path = arg.partition("=")
    q = open(path).read().rstrip().rstrip(";").rstrip()
    pairs.append((label, f"{q}\nSETTINGS {SETTINGS}"))

for _, sql in pairs:                       # warm every variant first
    for _ in range(WARMUP):
        ch(sql)

print("round,label,wall_ms,duration_ms,read_rows,read_bytes,selected_marks")
for r in range(1, ROUNDS + 1):
    for label, sql in pairs:
        if REGIME == "directio":
            drop_caches()
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
