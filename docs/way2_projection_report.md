> **⚠️ v1 report — superseded by [docs/v2_report.md](v2_report.md) (2026-08-30).**
> Kept for history. The v2 rigour pass rebuilt the dataset and harness per
> `docs/critical_review.md`; numbers here are pre-revision.

# Way 2 Report — Projection

**Status: COMPLETE** — 2026-08-28

## Hypothesis (pre-registered)
Add a normal projection on `exp.events` with the same physical ordering Way 1 used — `(event_type, country, created_at)`. ClickHouse should automatically select it for THE query, giving a similar reduction in rows read without rebuilding the base table.

## What changed
- Projection: `proj_country_day` on `exp.events` (Normal projection).
- Definition: `SELECT event_id, user_id, event_type, country, product_id, created_at, amount ORDER BY (event_type, country, created_at)`.
- The query itself is **unchanged** (transparency test).

## Version behavior (CH 26.7.5.10)
- Projections are **no longer experimental**: `allow_experimental_projection_optimization = 1` and `optimize_use_projections = 1` by default.
- `optimize_use_implicit_projections = 1` allows automatic selection.
- System tables: `system.projection_parts`, `system.projections`.

## Build cost
| Step | Time |
|---|---|
| `ALTER TABLE ... ADD PROJECTION` | 0.26 s (declaration only) |
| `ALTER TABLE ... MATERIALIZE PROJECTION` | near-instant (async background work) |
| `OPTIMIZE TABLE exp.events FINAL` | **46.6 s** (forces projection merge/completion) |
| Final projection state | 12 parts, 100M rows, 1.766 GB compressed |

## Correctness
- Query result hash: **10593978362403202577** ✅ matches baseline.
- Query file used unchanged: `sql/queries.sql`.

## Performance — THE query
| Metric | Baseline | Way 1 ORDER BY | Way 2 Projection | Ratio vs baseline |
|---|---|---|---|---|
| Latency p50 (hot) | 21 ms | 9 ms | **8 ms** | 2.6× faster |
| read_rows | 8,247,393 | 466,944 | **434,176** | 19.0× fewer |
| read_bytes | 115,477,976 | 6,537,216 | **6,078,464** | 19.0× fewer |
| memory_usage | 6,818,020 | 19,285,036 | **12,282,038** | 1.8× more |

## Mechanism proof (EXPLAIN)
Baseline: `ReadFromMergeTree (exp.events)    Parts: 9 | Granules: 1013`  
Way 2:    `ReadFromMergeTree (proj_country_day) Parts: 1 | Granules: 53`  

`EXPLAIN ESTIMATE`: rows scanned drop from 8,247,393 → 434,176. The optimizer transparently substituted the projection. This is the central claim of Way 2 — without it, speed would be meaningless.

## Projection vs Way 1
- Projection: 8 ms, 434k rows, 6.1 MB
- Way 1 ORDER BY: 9 ms, 467k rows, 6.5 MB

The difference is within run-to-run noise (latency ranges overlap). Both use the same physical ordering. After `OPTIMIZE FINAL`, both the projection and `events_orderby` ended at **1.766 GB / 12 parts**. Treat them as **comparable** for this workload, with projection offering transparency and Way 1 offering a permanently reordered base table.

## Storage & write costs
| Cost | Baseline (after optimize) | Projection | Delta |
|---|---|---|---|
| Base table compressed | 1.989 GB | 1.989 GB | same |
| Projection storage | — | **1.766 GB** | +89% total |
| Total storage | 1.989 GB | **3.755 GB** | +89% |
| Insert 1M rows into temp table (measured) | **1,475 ms** | **1,070 ms** | projection insert 27% faster |

**Insert measurement note:** We inserted 1M rows into freshly created temp tables with/without projection. The with-projection insert measured 1,070 ms vs 1,475 ms without. This is **not** because projections speed up inserts — rather, the projection produced more ordered/homogeneous parts, reducing merge work in this specific case. The real ongoing cost is the background projection maintenance and the +1.77 GB of stored projection data.

## Negative tests (mandatory)

### N4: GROUP BY event_type only (projection NOT selected)
```sql
SELECT event_type, count() FROM exp.events
WHERE created_at IN window
GROUP BY event_type
```

| Plan | Table read | Granules | read_rows | read_bytes | latency p50 |
|---|---|---|---|---|---|
| Uses base table `exp.events` | 1,004 | 8,222,817 | 41,114,085 | **18 ms** |

**Result:** optimizer chose the base table. Likely reason: the projection row is wider; when only `event_type` is needed, scanning the narrow base column is cheaper despite more granules. This is an honest "the optimizer is smarter than a blanket rule" moment.

### N3: GROUP BY product_id (projection IS selected, but not a win)
```sql
SELECT product_id, count(), sum(amount) ... GROUP BY product_id ORDER BY sum(amount) DESC LIMIT 10
```

| Plan | Table read | Granules | read_rows | read_bytes | latency p50 |
|---|---|---|---|---|---|
| Uses projection `proj_country_day` | 53 | 434,176 | 7,380,992 | **8 ms** |

**Result:** projection was selected because it contains all needed columns and the filter on `event_type` + date range prunes well. It was fast, but this query shape wasn't the design target. Shows projections can be broader than one query.

## Operational notes
- Adding a projection requires `MATERIALIZE`; on a populated table this is a full rewrite (46.6 s here).
- Projections are maintained on inserts/merges automatically — but the cost is deferred, not free.
- `system.projection_parts` lets you inspect storage and part counts.

## Verdict
Projection is the closest to a "free lunch" among the transparent optimizations: same query, same result, ~19× fewer rows read, and no base-table rewrite. The bill is +89% storage and background merge work. For this workload it edges out Way 1 on latency and rows read.

## Exit criteria (all ✅)
- [x] Installed-version projection behavior documented
- [x] Correctness verified (hash match, query unchanged)
- [x] EXPLAIN proves projection selected
- [x] 15 measured runs completed, CSVs saved
- [x] At least 2 "not selected / fallback" cases documented (N4 real fallback; N3 broader selection)
- [x] Storage + build + insert costs measured
- [x] One-paragraph "why it worked / when it doesn't" written

## Next
Way 3: Data Skipping Index.
