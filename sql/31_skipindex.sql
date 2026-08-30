-- Way 3: Data Skipping Index experiment.
--
-- Three index types on one table, so the positive and negative cases come from
-- the same data, same query shape, one column swapped:
--   idx_tenant_minmax : minmax on tenant_id (block-clustered) -> PRUNES HARD
--   idx_country_set   : set(1000) on country (hash-scattered) -> DEAD WEIGHT for
--                       heavy countries, useful only for the light tail
--   idx_user_bloom    : bloom_filter on user_id -> high-cardinality point lookup
--
-- Codecs match the baseline for a fair storage comparison. events_skip is a
-- clean copy of the baseline (no projection) so Way 3 is isolated from Way 2.

DROP TABLE IF EXISTS exp.events_skip;

CREATE TABLE exp.events_skip
(
    event_id   UInt64                  CODEC(Delta, LZ4),
    tenant_id  UInt32                  CODEC(Delta, LZ4),
    user_id    UInt64                  CODEC(ZSTD(1)),
    event_type LowCardinality(String),
    country    LowCardinality(String),
    product_id UInt32                  CODEC(ZSTD(1)),
    created_at DateTime                CODEC(Delta, LZ4),
    amount     Decimal(10, 2)          CODEC(ZSTD(1)),
    INDEX idx_tenant_minmax tenant_id TYPE minmax           GRANULARITY 1,
    INDEX idx_country_set   country   TYPE set(1000)        GRANULARITY 1,
    INDEX idx_user_bloom    user_id   TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (created_at, event_type);

INSERT INTO exp.events_skip SELECT * FROM exp.events;
