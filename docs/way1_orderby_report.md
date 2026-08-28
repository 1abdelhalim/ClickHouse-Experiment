# Way 1 Report — ORDER BY / Primary-Key Redesign

**Status: COMPLETE** — 2026-08-27

## Hypothesis (pre-registered)
Reordering from `(created_at, event_type)` to `(event_type, country, created_at)` should let the sparse index skip the 95% non-purchase granules and cluster country rows for the GROUP BY. The date predicate still prunes via the partition key.

## What changed
- New table: `exp.events_orderby`
- Only change vs baseline: `ORDER BY (event_type, country, created_at)`
- Same partition key, same columns, same data.

## Correctness
- Row count: 100,000,000 (same)
- Data checksum: `3125091598845950461` (same)
- Query result hash via `sql/99_correctness.sql` (adapted): **10593978362403202577** ✅ matches baseline

## Performance — THE query
| Metric | Baseline | Way 1 ORDER BY | Ratio |
|---|---|---|---|
| Latency p50 (hot) | 21 ms | **9 ms** | 2.3× faster |
| read_rows | 8,247,393 | **466,944** | 17.7× fewer |
| read_bytes | 115,477,976 | **6,537,216** | 17.7× fewer |
| memory_usage | 6,818,020 | **19,285,036** | 2.8× more |

## Mechanism proof (EXPLAIN)
Baseline: `ReadFromMergeTree ... Parts: 9 | Granules: 1013`  
Way 1:    `ReadFromMergeTree ... Parts: 5 | Granules: 57`  
`EXPLAIN ESTIMATE`: rows scanned drop from 8,247,393 → 466,944.

Why: the leading `event_type` key means the sparse index can skip nearly all non-purchase granules. The second key `country` also clusters rows so the GROUP BY aggregation processes contiguous groups. The third key `created_at` retains some date ordering inside each (event_type, country) stripe, and the partition key still narrows to the window month.

## Memory is higher — why
19.3 MiB vs 6.8 MiB. Likely cause: Way 1 reads fewer but non-contiguous granule ranges across multiple parts, so CH keeps more readers/state in memory than baseline, which reads a contiguous 1,013-granule sweep in one in-window region. We did not fully isolate this with ProfileEvents, so treat it as an observed cost rather than a proven mechanism. At 1B rows this difference could matter.

## Storage & write costs
| Cost | Baseline | Way 1 | Delta |
|---|---|---|---|
| Compressed size (after OPTIMIZE FINAL on both) | 1.989 GB | **1.766 GB** | -11.2% |
| Parts | 13 | 12 | similar after merge |
| One-time rewrite | — | **22.4 s** | cost to create |
| 1M-row insert (temp table) | 0.493 s | **0.668 s** | +35% slower |

### Why is storage smaller?
After forcing both tables through `OPTIMIZE FINAL`, the reordered table is 11% smaller. This is because:
1. `event_type='purchase'` is only 5% — sorting by event_type first creates very homogeneous LZ4 blocks for the LowCardinality `event_type` and the correlated `country`/`amount` columns.
2. The reordering happens to compress better than the baseline for this distribution.

**Correction note:** An earlier draft compared Way 1 to the *unoptimized* baseline (2.257 GB) and claimed -16.5%. That was unfair because the baseline had not been optimized. The fair comparison is -11.2%.

## Negative tests (mandatory)
These show the new ordering is not universally better.

### N1: point lookup on `user_id` (not in either key)
| Table | Latency p50 | read_rows | read_bytes |
|---|---|---|---|
| baseline | 2 ms | 81,920 | 1,079,632 |
| orderby | 2 ms | 81,920 | 1,060,720 |

**Result:** no improvement. The reordering only helps predicates that match the key prefix.

### N2: pure time-range query, no event_type filter
```sql
SELECT toDate(created_at), count() FROM ... WHERE created_at IN last 2 days GROUP BY 1
```

| Table | Latency p50 | read_rows | read_bytes |
|---|---|---|---|
| baseline | 3 ms | 579,681 | 2,318,724 |
| orderby | 5 ms | 6,649,953 | 26,599,812 |

**Result:** ORDER BY makes this query **~12× worse** on read_rows. Without the event_type filter, the time-first ordering is destroyed; CH must scan many more granules to satisfy the date range.

## Verdict
Works exactly as hypothesized for THE query: **17× fewer rows/bytes, 2.3× faster**. But it's a one-query optimization — queries not matching the `(event_type, country, ...)` prefix can regress. Storage and write costs are modest.

## Exit criteria (all ✅)
- [x] Correctness verified (hash match)
- [x] EXPLAIN proves granule pruning (1013 → 57)
- [x] 15 measured runs completed, CSVs saved
- [x] 2 negative tests documented
- [x] Storage + write costs measured
- [x] "Why it worked" paragraph written

## Next
Way 2: Projection.
