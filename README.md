# ClickHouse optimization experiment

Measuring four ways to speed up one analytical query on a 100M-row events table:

1. **ORDER BY / primary-key redesign** — `docs/way1_orderby_report.md`
2. **Projection** — `docs/way2_projection_report.md`
3. **Data skipping index** — `docs/way3_skipindex_report.md`
4. **Materialized view** (precomputation, priced separately) — `docs/way4_mv_report.md`

THE query, dataset design, and methodology: `docs/phase1_report.md` →
`docs/phase3_report.md`, `docs/dataset.md`, `sql/`.

## Two environments

| | how | results |
|---|---|---|
| **Mac (dev)** | `docker compose up -d`, then `CH="docker exec -i ch_experiment clickhouse-client" bench/run.sh …` | `results/*.csv`, `env/manifest.md` |
| **Linux (quotable)** | GitHub Codespace, ClickHouse native — see `docs/codespaces.md` | `results/linux/`, `env/manifest_linux.md` |

The Linux run exists to remove the "fanless laptop + Docker VM" objection. Run
`bench/run_all.sh` there and cross-check with `docs/mac_vs_linux.md`.

## Layout

```
sql/            schema, generator, per-way DDL, correctness anchor
sql/queries/    one SELECT per variant + negative test (used by bench/run_all.sh)
bench/run.sh    single-query harness (CH + RESULTS_DIR env vars)
bench/run_all.sh   full pipeline -> results/linux/
bench/explain.sh / correctness.sh / env_capture.sh / interleave.py / summarize.py
docs/           per-phase and per-way reports
```
