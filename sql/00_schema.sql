-- Phase 1: Baseline schema (v2 — rigour pass)
--
-- Baseline MergeTree: a realistic time-series default. Deliberately NOT tuned for
-- the country filter, so the four optimisation approaches have room to work.
--
-- What changed vs v1 (see docs/critical_review.md §6):
--   * Codecs specified. v1 used default LZ4 everywhere. Current practice:
--       created_at (sorted, monotonic within a part) -> Delta, LZ4
--       event_id   (sequential)                      -> Delta, LZ4
--       tenant_id  (block-clustered, low churn)      -> Delta, LZ4
--       user_id / product_id / amount (scattered)    -> ZSTD(1)
--     LowCardinality columns keep dictionary encoding + default LZ4.
--     This is the honest baseline: correct types AND codecs.
--   * created_at is now monotonic-with-insertion (a ramp over the year + jitter),
--     i.e. append-mostly like real ingestion. v1's created_at was uniform random
--     per row, which shuffled every part by time and made the baseline
--     artificially pessimistic.
--   * New column tenant_id: assigned in contiguous blocks, so it is *clustered*
--     within granules. It is the skip-index POSITIVE case; country (hash-
--     scattered) is the NEGATIVE case. Same table, one query shape, one column
--     swapped (docs/critical_review.md §6.1, §7).
--
--   PARTITION BY toYYYYMM(created_at): a data-management boundary (TTL / DROP),
--     not a performance device. THE query's 30-day window prunes to 1-2
--     partitions as a side effect.
--   ORDER BY (created_at, event_type): time-first. Date range prunes granules via
--     the primary index; event_type as 2nd key gives only partial pruning;
--     country is NOT in the key, so GROUP BY country reads nearly every in-range
--     granule. That headroom is what Ways 1-3 attack.

CREATE DATABASE IF NOT EXISTS exp;

DROP TABLE IF EXISTS exp.events;

CREATE TABLE exp.events
(
    event_id   UInt64                  CODEC(Delta, LZ4),
    tenant_id  UInt32                  CODEC(Delta, LZ4),
    user_id    UInt64                  CODEC(ZSTD(1)),
    event_type LowCardinality(String),
    country    LowCardinality(String),
    product_id UInt32                  CODEC(ZSTD(1)),
    created_at DateTime                CODEC(Delta, LZ4),
    amount     Decimal(10, 2)          CODEC(ZSTD(1))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at, event_type);
