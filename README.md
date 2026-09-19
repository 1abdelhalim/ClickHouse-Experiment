# ClickHouse optimization experiment

Measuring four ways to speed up one analytical query on a 100M-row events table:

1. **ORDER BY / primary-key redesign**
2. **Projection** (narrow / full / lightweight `_part_offset`)
3. **Data skipping index** (minmax / set / bloom_filter)
4. **Materialized view** (precomputation, priced separately)

## Start here

- **[docs/article.md](docs/article.md)** — ClickHouse blog draft (mechanism-first;
  100M-row v2 artifacts).
- **[docs/v2_report.md](docs/v2_report.md)** — consolidated engineering report
  (2026-08-30, ClickHouse 26.9.1, 100M rows). Results, mechanism evidence, cost
  ledger, limitations, verdict.
- **[docs/critical_review.md](docs/critical_review.md)** — a maintainer-stance
  critique of the experiment; §12 tracks how each finding was resolved in v2
  (including the post-v2 interleaved-projection correction).
- [docs/dataset.md](docs/dataset.md) — the v2 dataset.
- [docs/codespaces.md](docs/codespaces.md) — how to reproduce the run.

The Phase 1–3 and Way 1–4 reports are the v1 pass, kept for history with a
banner pointing here. `docs/mac_vs_linux.md` is the v1 Mac↔Linux cross-check.
Canonical numbers live in `results/linux/`; ignore loose `results/*.csv` (v1).

## Reproduce

```bash
# in a GitHub Codespace on this repo (native ClickHouse, see docs/codespaces.md)
bench/run_all.sh --smoke      # ~12 min plumbing check at 12M rows
bench/run_all.sh              # full run: 100M rows -> results/linux/
```

`bench/run_all.sh` is host-agnostic (`CH`, `RESULTS_DIR`, `MAX_THREADS` env
vars); on a dedicated Linux box it runs unchanged and gives harder absolute
latency numbers.

## Layout

```
sql/            schema, generator ({ROWS} templated), per-way DDL, correctness anchor
sql/queries/    one SELECT per variant + negative test
bench/run.sh    single-query harness — hot | cold | directio regimes, CV reported
bench/run_all.sh   full Phase 1-8 pipeline -> results/linux/
bench/{explain,correctness,env_capture}.sh, interleave.py, summarize.py
docs/           article draft + v2 report + critical review + v1 history
results/linux/  the v2 run artifacts (cite these, not results/*.csv)
```
