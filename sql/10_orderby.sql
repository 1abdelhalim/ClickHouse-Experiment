-- Way 1: alternative physical ordering.
-- ONLY change vs baseline: ORDER BY (event_type, country, created_at).
-- Codecs are identical to the baseline so the storage comparison is fair
-- (see docs/critical_review.md §6, §7).
--
-- Hypothesis: 'purchase' (5%) becomes the leading sort key -> the primary index
-- skips ~95% of non-purchase granules; country second clusters the GROUP BY.
-- created_at moves to 3rd, but PARTITION BY month still prunes the date range.

DROP TABLE IF EXISTS exp.events_orderby;

CREATE TABLE exp.events_orderby
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
ORDER BY (event_type, country, created_at);
