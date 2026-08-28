-- Way 3: Data Skipping Index experiment.
-- Forensics (sql/30_distribution.sql) proved country is NOT clustered:
--   - median 198/199 distinct countries per 8192-row granule
--   - c198 in 100% of granules, c0 in 24.4%
-- Therefore a skip index on country should provide little/no pruning.
-- We create it anyway to prove the negative result with measurements.

-- Isolate from Way 2's projection by using a clean copy of the baseline table.
CREATE TABLE IF NOT EXISTS exp.events_skip
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

INSERT INTO exp.events_skip SELECT * FROM exp.events;

-- Add the index the forensics say shouldn't help, plus a bloom_filter on user_id
-- as a secondary teaching case (high-cardinality point lookups).
ALTER TABLE exp.events_skip ADD INDEX idx_country_set country TYPE set(512) GRANULARITY 1;
ALTER TABLE exp.events_skip ADD INDEX idx_user_bloom user_id TYPE bloom_filter(0.01) GRANULARITY 1;
ALTER TABLE exp.events_skip MATERIALIZE INDEX idx_country_set;
ALTER TABLE exp.events_skip MATERIALIZE INDEX idx_user_bloom;
