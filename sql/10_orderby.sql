-- Way 1: alternative physical ordering.
-- ONLY change vs baseline: ORDER BY (event_type, country, created_at).
-- Hypothesis: purchase (5%) becomes the leading sort key -> sparse index skips
-- ~95% of granules; country second clusters aggregates. created_at moves to 3rd,
-- but partition key still prunes by month.

CREATE TABLE IF NOT EXISTS exp.events_orderby
(
    event_id   UInt64,
    user_id    UInt64,
    event_type LowCardinality(String),
    country    LowCardinality(String),
    product_id UInt32,
    created_at DateTime,
    amount     Decimal(10, 2)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (event_type, country, created_at);
