# Running the experiment on GitHub Codespaces (Linux, native)

The Mac run (`env/manifest.md`, the v1 `docs/way*_report.md`) was done under
Docker Desktop on a fanless M3 Air. Those numbers are internally consistent but
carry two objections a reviewer will raise immediately:

1. **Fanless laptop** — sustained multi-core work thermally throttles; run 1 and
   run 15 are not the same machine.
2. **Docker Desktop VM** — virtiofs adds an I/O layer, and macOS is not
   ClickHouse's production target.

This Codespace removes both. ClickHouse is installed **natively** (no Docker) on a
Linux container running on server-class hardware. The installer is **pinned to
26.9.1** (the v2 artifact version); override with `CLICKHOUSE_VERSION`.

## Launch

1. Repo → **Code ▸ Codespaces ▸ Create codespace on `main`**.
   Pick a **4-core / 16 GB** machine (the devcontainer requests this via
   `hostRequirements`; accept a bigger one if offered).
2. Wait for `onCreateCommand` to finish. It installs ClickHouse 26.9.1, starts the
   server, and writes `env/manifest_linux.md`. You'll see the version string and a
   sanity benchmark.

## Run

```bash
bench/run_all.sh --smoke      # ~12 min: 12M rows, plumbing check
```

Read `results/linux/SUMMARY.md`. Look at the **baseline p50**:

- **< ~300 ms** → dataset too small for *latency* claims; read-volume is still
  valid. Scale up only if you want wall-clock to dominate startup noise.
- **1–3 s** → the original target for quotable milliseconds (not reached at 100M
  on this box).
- **> ~10 s** → too big to afford 20 runs × variants × negatives.

The published v2 run is 100M rows / 20 measured runs:

```bash
bench/run_all.sh                       # 100M rows, 20 runs/query -> results/linux/
# optional larger:
ROWS=150000000 RUNS=20 bench/run_all.sh
```

Full run is roughly 2.5 h wall time at 100M. **Disk ceiling:** the pipeline
builds several copies of the table (base + `events_orderby` + skip copy +
transient projections + `OPTIMIZE FINAL` space). ~150M rows is the most that
fits a 32 GB Codespace. For larger N, add storage or run `bench/run_all.sh` on a
bigger box (`CH` + `RESULTS_DIR`).

## What you get in `results/linux/`

Canonical v2 artifacts live **only** here. Loose files under `results/*.csv` are
v1 leftovers and must not be cited.

| file | what |
|---|---|
| `SUMMARY.md` | hot + directio tables: p50/min/max ms, read_rows, read_bytes, SelectedMarks |
| `*_hot.csv` / `*_directio.csv` | every individual run |
| `explain_*.txt` | `EXPLAIN indexes=1` (+ `projections=1` on future runs) and `EXPLAIN ESTIMATE` |
| `correctness_*.txt` | must all print **`15313934330332105907`** (v2 result hash) |
| `data_checksum.txt` | **`14701560614780328933`** (v2 data checksum) |
| `storage_*.txt`, `build_*.txt` | disk + one-time rebuild cost per way |
| `way3_forensics.txt` | per-granule clustering (why the skip index does/doesn't prune) |
| `way4_backfill.txt` | MV historical backfill timing |
| `interleaved.csv` | v2 file is **not a fair baseline** (leftover projection; 53 marks). Future runs drop the projection first. |
| `run_all.log` | full transcript |

## Then

The article draft is [article.md](article.md). Cite standalone `read_rows` /
`SelectedMarks` from `SUMMARY.md`, not v2 interleaved milliseconds. The Mac run
(`docs/mac_vs_linux.md`) stays as "developed on / v1 cross-check."

## Notes / limitations that still apply

- **Cold cache**: a Codespace container has a read-only `/proc/sys/vm/drop_caches`,
  so true disk-cold runs still aren't possible. The harness drops ClickHouse's
  own caches in `cold` / `directio` mode and sets `min_bytes_to_use_direct_io=1`
  plus `use_query_condition_cache=0`. `read_rows` / `read_bytes` / `SelectedMarks`
  remain the cache-independent measure of work eliminated.
- **Not bare metal**: a Codespace is a shared, containerised VM. It kills the
  "fanless laptop" and "Docker Desktop" objections; it is not a dedicated server.
  For truly quotable absolute numbers, run the same `bench/run_all.sh` on a rented
  dedicated box — the scripts are host-agnostic (`CH` + `RESULTS_DIR` env vars).
