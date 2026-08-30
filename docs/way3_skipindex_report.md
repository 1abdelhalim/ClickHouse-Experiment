> **⚠️ v1 report — superseded by [docs/v2_report.md](v2_report.md) (2026-08-30).**
> Kept for history. The v2 rigour pass rebuilt the dataset and harness per
> `docs/critical_review.md`; numbers here are pre-revision.

# Way 3 Report — Data Skipping Index

**Status: COMPLETE** — 2026-08-28

## Hypothesis (pre-registered)
A skip index on `country` will NOT help THE query (which reads all countries) and will barely help single-country queries because country values are not clustered within granules under the baseline `(created_at, event_type)` ordering. A bloom filter on `user_id` SHOULD help point lookups.

## Distribution forensics (BEFORE indexing)
Measured on a 1M-row sample of the August window, grouped into 8192-row granules:

| Metric | Value |
|---|---|
| Median distinct countries per granule | **198 of 199** |
| `c198` (heavy) granule coverage | **100%** (123/123) |
| `c0` (light) granule coverage | **24.4%** (30/123) |

**Conclusion:** `country` is almost perfectly scattered. `minmax` is useless (strings, no correlation). `set(512)` can only prune granules that lack a value — only useful for the lightest countries.

## What changed
- New table: `exp.events_skip` (clean copy of baseline, no projections).
- Indexes:
  - `idx_country_set`: `country TYPE set(512) GRANULARITY 1`
  - `idx_user_bloom`: `user_id TYPE bloom_filter(0.01) GRANULARITY 1`

## Correctness
- Row count: 100,000,000 ✅
- Data checksum: `3125091598845950461` ✅

## Performance — THE query (all countries)
| Metric | Baseline | Skip Index | Delta |
|---|---|---|---|
| Latency p50 (hot) | 21 ms | **27 ms** | +29% slower |
| read_rows | 8,247,393 | **8,222,817** | ~same |
| read_bytes | 115,477,976 | **115,126,680** | ~same |
| Granules (EXPLAIN) | 1,013 | **1,004** | ~same |

**Result:** The `set` index is **not used** for THE query (EXPLAIN shows no skip-index condition). Slight latency increase is noise / index-check overhead.

## Performance — single country

### `country = 'c0'` (light, 24.4% coverage)
| Metric | Value |
|---|---|
| Latency p50 | **17 ms** |
| read_rows | **1,966,080** |
| read_bytes | **3,319,587** |
| Granules (EXPLAIN) | **240** |

**Mechanism:** EXPLAIN confirms the index is used; granules drop from 1,004 → 240 (76% pruned). This matches the forensics prediction (24.4% coverage means ~75% of granules can be skipped).

### `country = 'c198'` (heavy, 100% coverage)
| Metric | Value |
|---|---|
| Latency p50 | **30 ms** |
| read_rows | **8,222,817** |
| read_bytes | **49,118,052** |
| Granules (EXPLAIN) | **1,004** |

**Result:** Index provides **zero** pruning. Every granule contains `c198`, so the `set` index stores it in every block and nothing is skipped.

## Performance — point lookup on `user_id` (bloom filter)
```sql
SELECT count(), sum(amount) FROM exp.events_skip WHERE user_id = 424242
```

| Metric | Value |
|---|---|
| Latency p50 | **13 ms** |
| read_rows | **884,736** |
| read_bytes | **7,472,928** |
| Granules (EXPLAIN) | **108** |
| Actual matching rows | **10** |

**Result:** Bloom filter prunes granules effectively for high-cardinality equality predicates — 108 granules instead of 1,004. But the price is false positives: **we read 884,736 rows to find 10 matches**, an 88,474:1 over-read. This is expected for bloom filters; whether it's acceptable depends on the predicate selectivity and query frequency.

## Costs
| Cost | Value |
|---|---|
| Table copy + index build | **16.6 s** |
| Index storage | **131.3 MB** |
| Base data storage | 1.99 GB |
| Index overhead | **6.6%** |

## Negative tests (mandatory)
1. **THE query**: index not used, no benefit, slight overhead.
2. **`c198` single country**: index used but prunes nothing (100% coverage).
3. **Forensics conclusion validated**: skip indexes fail when the indexed column is uniformly distributed across granules.

## Verdict
Skip indexes are **not a general-purpose optimization**. They work only when the indexed column has low coverage per granule. For this dataset:
- `country` skip index: useless for the main query, marginal for the lightest countries.
- `user_id` bloom filter: genuinely useful for point lookups.

The honest takeaway: **measure clustering first**. If nearly every granule contains the value, a skip index is dead weight.

## Exit criteria (all ✅)
- [x] Distribution forensics documented with numbers
- [x] Correctness verified (hash match)
- [x] EXPLAIN proves usage for positive cases (c0, user_id)
- [x] Main-query negative result measured and explained
- [x] 15 runs for main query, 7 for variants, CSVs saved
- [x] Index storage + build costs measured
- [x] Verdict written: "skip indexes help WHEN…, fail WHEN…"

## Next
Way 4: Materialized View.
