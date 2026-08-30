# Dataset (v2)

## Shape
- Table `exp.events`, **100,000,000 rows**, fully deterministic — every column is
  a pure function of the row index `n` via `cityHash64(n, <salt>)` for the
  uniform part; `pow()`/`exp()` only shape skew. No `rand()`, no state.
- **1.36 GiB** compressed / 3.54 GiB uncompressed, 12 monthly partitions, 12 parts
  after `OPTIMIZE FINAL`.
- Reproducibility anchors: data checksum
  `sum(cityHash64(all cols)) = 14701560614780328933`; THE query result hash
  `15313934330332105907` (every variant must match).

## Columns

| column | type + codec | distribution (measured) |
|---|---|---|
| `event_id` | `UInt64 CODEC(Delta,LZ4)` | `= n`, unique, sequential — the N1 point-lookup key |
| `tenant_id` | `UInt32 CODEC(Delta,LZ4)` | `intDiv(n,50000) % 3000` → 2,000 distinct, assigned in **contiguous 50k-row blocks** (clustered) |
| `user_id` | `UInt64 CODEC(ZSTD(1))` | `9 999 999 · u²` → ~975 k distinct, **power-law** (heavy head, long tail) |
| `event_type` | `LowCardinality(String)` | **12** distinct; `purchase` = **5.0 %** (bucket 0 of 20) |
| `country` | `LowCardinality(String)` | `199 · u³` → 199 distinct `c0..c198`; **heaviest 17.1 %, top-10 36.9 %**, long tail |
| `product_id` | `UInt32 CODEC(ZSTD(1))` | `99 999 · u²` → ~100 k distinct, skewed to low ids |
| `created_at` | `DateTime CODEC(Delta,LZ4)` | **monotonic ramp** 2024-09-01 → 2025-08-31 + 0–600 s jitter (append-realistic) |
| `amount` | `Decimal(10,2) CODEC(ZSTD(1))` | `exp(u·4)`, multiplied by a per-country factor (`1 + country_idx % 20`) |

`PARTITION BY toYYYYMM(created_at)` · `ORDER BY (created_at, event_type)`.

## Why each choice matters

- **`created_at` monotonic** → the table is append-ordered like real ingestion.
  v1's uniform-random timestamps shuffled every part by time and made the
  baseline artificially pessimistic. Now the 30-day window is a near-contiguous
  slice; partition + primary-key pruning behave realistically (12,212 → 1,004
  granules for THE query).
- **`event_type` = 5 % purchase, second in the key** → the baseline's
  primary index can't skip non-purchase granules, so Way 1 (make `event_type`
  the *leading* key) has room: 1,004 → 53 granules.
- **`country` skewed and hash-scattered** → a realistic `GROUP BY` cardinality
  (199), and — because heavy countries land in ~every granule — the honest
  negative case for a `set()` skip index. v1's `pow(u,0.5)` was near-uniform
  (top-10 9.8 %) and mislabelled "designed for 70 %".
- **`tenant_id` block-clustered** → 1 distinct value per granule (max 2). The
  honest *positive* case for a `minmax` skip index: `tenant_id = X` prunes
  1,004 → 7 granules. Same table, one column swapped vs the `country` negative.
- **`user_id` power-law** → the bloom-filter section sees a realistic
  distribution; `user_id = <rare>` returns ~84 rows scattered across the table.
- **`amount` country-correlated** → revenue varies enough that the top-10 isn't
  degenerate.

## THE query window
- 2025-08-02 .. 2025-09-01 (30 days, last month).
- ~8.22 M rows in window; ~410 k purchases. That 8.22 M scan set is what every
  variant must reduce.
