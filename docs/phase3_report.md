# Phase 3 Report — Baseline Autopsy

**Status: COMPLETE** — 2026-08-26

## THE query (baseline)
Top-10 countries by daily revenue, purchases only, last 30 days (2025-08-02..2025-09-01).

## Correctness anchor
- Result set saved: `results/baseline_result.txt` (md5 `457bdd7208dd238bb57cb6062bcc2a07`)
- Correctness hash (cityHash64 of full result): **10593978362403202577**
- Every Way must reproduce this exact hash via `sql/99_correctness.sql`.

## Measured baseline (hot cache, 15 runs)
| Metric | Value |
|---|---|
| Latency p50 | **21 ms** (p25 21, p75 22, min 20, max 23) |
| read_rows | **8,247,393** |
| read_bytes | **115,477,976** (110 MiB) |
| memory_usage | **6,818,020** (6.5 MiB) |

## Why it reads what it reads (EXPLAIN evidence)
EXPLAIN plan:
```
ReadFromMergeTree (exp.events)
  Parts: 9 | Granules: 1013
  Prewhere: created_at in window AND event_type='purchase'
→ Aggregating (keys: country, toDate(created_at)) → Sorting → Limit 10
```

Granule math:
- Full table: **12,364 granules** (marks) across 12 partitions.
- Partition pruning: only `202508` (and edge of window) → window partition has **1,052 granules**.
- Query reads **1,013 granules / 8,247,393 rows** = essentially the whole in-window partition.

## The core inefficiency (this is what Ways 1–3 attack)
- **Partition + date pruning works**: 12,364 → 1,013 granules (12× reduction). Good.
- **event_type pruning fails**: `purchase` is only 5% of rows, but the sparse index on `(created_at, event_type)` can't skip granules on `event_type` because `created_at` is the leading (high-cardinality, ever-increasing) key — every granule spans many event_types. So CH reads **all 8.25M in-window rows** to find the **410,957 purchases** (5%).
- **country is not indexed at all** → GROUP BY country touches every read row.
- Net: **20× more rows read than the 411k the query logically needs.**

## Diagnosis
- I/O profile: 110 MiB read for a 30-day analytical aggregation. Latency is small in absolute terms (21 ms) because the data fits in cache — but the *work* done (8.25M rows scanned, full-column read of country/amount) is the target.
- Not sort-bound (only 10 output rows), not aggregation-bound (411k groups→rows trivial). **It is scan/read-bound**: the cost is reading 8.25M rows to locate 5% purchases and group by an unindexed country.

## Prediction for the Ways (recorded before testing)
- **Way 1 (ORDER BY event_type, country, created_at)**: should collapse read_rows toward ~411k + grouping locality. Expect large read_bytes drop. Risk: date pruning worsens (created_at now 3rd key) — but partition key still handles it.
- **Way 2 (Projection)**: same benefit without touching base table; must prove optimizer selection.
- **Way 3 (skip index on country)**: expected to NOT help THE query (all countries needed); helps only single-country drill-downs. Honest negative expected.
- **Way 4 (MV)**: reads ~pre-aggregated rows; biggest latency win, priced as precomputation.

## Next
Way 1: ORDER BY redesign (gate: this report complete ✅).
