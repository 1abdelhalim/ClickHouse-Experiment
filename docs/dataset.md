# Dataset

## Shape
- Table: `exp.events`, 100,000,000 rows, fully deterministic (pure function of row index; no rand()).
- Size: 2.26 GB compressed / 3.4 GB uncompressed, 12 monthly partitions, 108 parts.
- Load time: 24.7 s.
- Checksum (reproducibility anchor): `sum(cityHash64(...)) = 3125091598845950461`.

## Distributions (measured, not just designed)
| Column | Design | Measured |
|---|---|---|
| created_at | uniform over 2024-09-01..2025-08-31 | min 2024-09-01 00:00:00, max 2025-08-31 23:59:59 |
| event_type | 12 types, purchase = 5% | purchase share = 5.00% |
| country | 200 values, skewed | 199 distinct; top-10 countries = 9.8% of rows; heaviest c198=1.00M, lightest c0=3k |
| product_id | 100k, skewed | 99,999 distinct |
| user_id | 10M | 10,000,000 distinct |
| amount | lognormal-ish, country-correlated | multiplier (1 + country_idx % 20) |

## Why these choices matter per optimization
- **created_at uniform** → monthly partition pruning works; date range is the only predicate that prunes the baseline sparse index.
- **purchase = 5%** → high selectivity on event_type. Baseline ORDER BY (created_at, event_type) gives partial pruning; Way 1 (reorder) exploits this.
- **country skewed, 199 values** → realistic GROUP BY cardinality. Skew matters for Way 3 (skip index): if heavy countries appear in most granules, a skip index can't prune them.
- **amount country-correlated** → realistic revenue variation; prevents degenerate aggregates.

## THE query window
- Window: 2025-08-02 .. 2025-09-01 (30 days, last month of data).
- Rows in window: 8,219,181; purchases in window: 410,957.
- This is the scan set every variant must reduce.
