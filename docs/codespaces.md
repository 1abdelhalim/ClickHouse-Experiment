# Running the experiment on GitHub Codespaces (Linux, native)

The Mac run (`env/manifest.md`, all the `docs/way*_report.md`) was done under Docker
Desktop on a fanless M3 Air. Those numbers are internally consistent but carry two
objections a reviewer will raise immediately:

1. **Fanless laptop** — sustained multi-core work thermally throttles; run 1 and
   run 15 are not the same machine.
2. **Docker Desktop VM** — virtiofs adds an I/O layer, and macOS is not
   ClickHouse's production target.

This Codespace removes both. ClickHouse is installed **natively** (no Docker) on a
Linux container running on server-class hardware.

## Launch

1. Repo → **Code ▸ Codespaces ▸ Create codespace on `linux-validation`**.
   Pick a **4-core / 16 GB** machine (the devcontainer requests this via
   `hostRequirements`; accept a bigger one if offered).
2. Wait for `onCreateCommand` to finish. It installs ClickHouse, starts the
   server, and writes `env/manifest_linux.md`. You'll see the version string and a
   sanity benchmark.

## Run

```bash
bench/run_all.sh --smoke      # ~2 min: 10M rows, plumbing + sizing check
```

Read `results/linux/SUMMARY.md`. Look at the **baseline p50**:

- **< ~300 ms** → dataset too small, query startup and noise dominate. Scale up.
- **1–3 s** → ideal. Note the `ROWS` that produced it.
- **> ~10 s** → too big to afford 15 runs × 5 variants × negatives.

Then the real run, sized by that target time (100M is the plan's default and is
usually in range on 4 cores):

```bash
bench/run_all.sh                       # 100M rows, 15 runs/query
# or, if the smoke run said you need more:
ROWS=150000000 RUNS=20 bench/run_all.sh
```

Full run is roughly 20–40 min wall time. **Disk ceiling:** the pipeline builds
four full copies of the table (base + `events_orderby` + projection + `events_skip`)
plus transient `OPTIMIZE FINAL` space, so ~150M rows is the most that fits a 32 GB
Codespace. For larger N, create the Codespace with more storage or run
`bench/run_all.sh` on a bigger box (the scripts only need `CH` + `RESULTS_DIR`).

## What you get in `results/linux/`

| file | what |
|---|---|
| `SUMMARY.md` | one table: p50/min/max ms, read_rows, read_bytes, SelectedMarks, ratio vs baseline |
| `*_hot.csv` | every individual run (check for a downward drift in `duration_ms` before trusting a median) |
| `explain_*.txt` | `EXPLAIN indexes=1` + `EXPLAIN ESTIMATE` — the mechanism proof (which projection/index was actually chosen, granules kept) |
| `correctness_*.txt` | must all print `10593978362403202577` |
| `storage_*.txt`, `build_*.txt` | disk + one-time rebuild cost per way |
| `way3_forensics.txt` | country-per-granule clustering (why the skip index does/doesn't prune) |
| `way4_backfill.txt` | MV historical backfill timing |
| `interleaved.csv` | all 5 main queries re-measured round-robin (A/B/C/D/E ×15) so drift hits every variant equally, not just the one measured last |
| `run_all.log` | full transcript |

## Then

Fill in `docs/mac_vs_linux.md` from `SUMMARY.md` and `env/manifest_linux.md`, and
cite the Linux numbers as the headline results in the article, with the Mac run
kept as the "developed on / cross-checked against" note.

## Notes / limitations that still apply

- **Cold cache**: a Codespace container also has a read-only
  `/proc/sys/vm/drop_caches`, so true disk-cold runs still aren't possible. The
  harness drops ClickHouse's own caches in `cold` mode; `read_rows` / `read_bytes`
  / `SelectedMarks` stay the cache-independent measure of work eliminated. This is
  the same caveat as the Mac run — state it in the article.
- **Not bare metal**: a Codespace is a shared, containerised VM. It kills the
  "fanless laptop" and "Docker Desktop" objections; it is not a dedicated server.
  For truly quotable absolute numbers, run the same `bench/run_all.sh` on a rented
  dedicated box — the scripts are host-agnostic (`CH` + `RESULTS_DIR` env vars).
