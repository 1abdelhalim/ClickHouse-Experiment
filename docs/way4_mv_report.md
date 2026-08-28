# Way 4 Report — Materialized View

**Status: COMPLETE** — 2026-08-28

## Hypothesis (pre-registered)
A materialized view pre-aggregating purchases by `(country, day)` will answer THE query from ~72k rows instead of 100M, giving the fastest latency of all four approaches. But this is **precomputation**, not query-transparent optimization. The experiment's job is to price the trade precisely.

## Design
- **Target table:** `exp.events_daily_country` (`AggregatingMergeTree`)
  - `ORDER BY (country, day)`
  - Columns: `day`, `country`, `purchases AggregateFunction(count)`, `revenue AggregateFunction(sum, Decimal(10,2))`
- **MV:** `exp.mv_daily_country` with `WHERE event_type='purchase'` inside
  - Only serves purchase queries (narrowing IS the trade)
  - Uses `TO` target form (queryable, cleaner ops)

## The classic trap (documented)
MV only sees **NEW** inserts. Historical 100M rows must be backfilled manually:
```sql
INSERT INTO exp.events_daily_country
SELECT toDate(created_at) AS day, country, countState(), sumState(amount)
FROM exp.events WHERE event_type='purchase' GROUP BY day, country
```

**Backfill query duration: 82 ms** (measured via `system.query_log`; the shell `time` output of 0.26 s included client round-trip). Fast because the aggregation collapses 5M purchases to 72k rows in memory. At 1B rows, expect this to scale roughly with source data size.

## Correctness
- Query result hash: **10593978362403202577** ✅ matches baseline
- Uses `-Merge` combinators: `countMerge(purchases)`, `sumMerge(revenue)`
- Verified MV auto-updates on new inserts (1000-row test insert → target updated)

## Performance — THE query (rewritten for MV)
```sql
SELECT country, day, countMerge(purchases) AS purchases, sumMerge(revenue) AS revenue
FROM exp.events_daily_country
WHERE day >= '2025-08-02' AND day < '2025-09-01'
GROUP BY country, day ORDER BY revenue DESC LIMIT 10
```

| Metric | Baseline | Way 1 | Way 2 | Way 4 MV | vs Baseline |
|---|---|---|---|---|---|
| Latency p50 (hot) | 21 ms | 9 ms | 8 ms | **4 ms** | 5.25× faster |
| read_rows | 8,247,393 | 466,944 | 434,176 | **72,021** | 114× fewer |
| read_bytes | 115,477,976 | 6,537,216 | 6,078,464 | **3,099,198** | 37× fewer |
| Granules (EXPLAIN) | 1,013 | 57 | 53 | **9** | 113× fewer |

**Result:** MV wins on latency and rows read by a wide margin. But this is expected — it precomputed the answer.

## Cost ledger (the price of precomputation)

### Storage
| Component | Size |
|---|---|
| Base table | 1.99 GB |
| MV target | **0.4 MB** (72k pre-aggregated rows) |
| **Total overhead** | **+0.4 MB** (negligible) |

### Write amplification
- Insert 1000 new purchase rows into `exp.events`: **0.154 s** (fast; MV maintenance is async)
- Real cost: MV target gets updated during background merges

### Rebuild cost (simulating a logic change)
- Drop target + MV + recreate + backfill: **0.42 s** total (shell time; backfill query itself 82 ms)
- Fast here, but at 1B rows this would be minutes, not seconds

### Operational burden
- MV has `WHERE event_type='purchase'` inside → only serves purchase queries
- Schema changes to base table can break MVs
- Requires manual backfill for historical data (the trap)

## Negative test — query the MV can't serve
```sql
SELECT product_id, count(), sum(amount) ... GROUP BY product_id
```

| Approach | Latency | read_rows | Notes |
|---|---|---|---|
| MV | — | — | Can't serve (no product_id in target) |
| Projection (Way 2) | **8 ms** | 434,176 | Fallback works |

**Result:** The MV is **query-shape-specific**. Any query not matching `(country, day)` + purchase filter gets zero help. Ways 1–3 preserve base-table flexibility; Way 4 trades it away for speed.

## Verdict
MV is the fastest approach for THE query by far (4 ms, 114× fewer rows). But it's a different **category**: precomputation, not optimization. It wins when:
- You have a small set of known, high-value query shapes
- The aggregation is expensive and repeated
- You can afford the maintenance (backfill, rebuild on logic change, schema coupling)

For this single query, MV wins. For a flexible analytics workload, Ways 1–2 are safer.

## Exit criteria (all ✅)
- [x] Correctness verified (hash match + new-insert delta check)
- [x] Backfill trap documented with timing
- [x] Full cost ledger: storage, write amplification, rebuild, ops
- [x] 15 runs completed, CSVs saved
- [x] Negative test (product_id) with numbers
- [x] "Not a fair fight" framing documented
- [x] Verdict written

## Next
Phase 8: cost table + article.
