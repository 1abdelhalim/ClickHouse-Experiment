-- Phase 1: Baseline schema
-- Baseline MergeTree: realistic time-series default. Deliberately NOT optimized for
-- the country filter, to leave room for the 4 optimization approaches.
--
-- Design rationale (docs/dataset.md explains distributions):
--   PARTITION BY toYYYYMM(created_at): monthly partitions, standard for event data.
--     The 30-day window in THE query prunes to ~1-2 partitions.
--   ORDER BY (created_at, event_type): time-first ordering. Date range prunes granules
--     via the sparse index; event_type as 2nd key gives partial pruning; country is
--     NOT in the key -> the GROUP BY country reads nearly everything in range.

CREATE DATABASE IF NOT EXISTS exp;

CREATE TABLE IF NOT EXISTS exp.events
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
ORDER BY (created_at, event_type);
