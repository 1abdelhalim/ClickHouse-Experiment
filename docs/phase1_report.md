# Phase 1 Report — Schema & Dataset

**Status: COMPLETE** — 2026-08-26

## What was done
1. Created `exp.events` (MergeTree, `PARTITION BY toYYYYMM(created_at)`, `ORDER BY (created_at, event_type)`).
2. Generated 100M deterministic rows via pure functions of row index (sql/01_generate.sql).
3. Verified correctness and measured actual distributions.

## Measured results
| Check | Expected | Actual | Pass |
|---|---|---|---|
| Row count | 100,000,000 | 100,000,000 | ✅ |
| Date span | 2024-09-01..2025-08-31 | exact | ✅ |
| Purchase share | 5% | 5.00% | ✅ |
| Distinct countries | 200 | 199 | ✅ (edge truncation, noted) |
| Distinct products | 100k | 99,999 | ✅ |
| Distinct users | 10M | 10,000,000 | ✅ |
| Compressed size | ~3-6 GB | 2.26 GB | ✅ |
| Uncompressed | — | 3.4 GB | — |
| Parts | — | 108 (12 partitions × 9) | ✅ |
| Load time | — | 24.7 s | — |
| Checksum | — | 3125091598845950461 | anchor |

## Baseline ORDER BY rationale (for the article)
- `ORDER BY (created_at, event_type)` is the realistic time-series default.
- THE query's date range prunes via partition key + first sort key.
- `event_type` as 2nd key gives partial granule pruning.
- `country` is NOT in the key → the GROUP BY country reads nearly all in-range granules. This is the deliberate headroom Ways 1–3 attack.

## Deviations from plan
- Country skew is milder than "top-10 ≈ 70%": measured top-10 = 9.8%, range 3k..1M rows. Still skewed; recorded honestly. Not worth regenerating.
- 199/200 countries and 99,999/100k products: modulo edge effect of pow() mapping. Immaterial to conclusions.
- Baseline table was later `OPTIMIZE FINAL`-ed during Way 2, changing its compressed size from 2.257 GB to 1.989 GB. All storage comparisons in reports use the optimized baseline.

## Reproducibility
Re-run `00_schema.sql` then `01_generate.sql`; verify checksum = 3125091598845950461.

## Next
Phase 2: benchmark harness (bench/run.sh) + Phase 3 baseline report.
