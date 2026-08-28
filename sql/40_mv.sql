-- Way 4: Materialized View — precomputation, NOT a query-transparent optimization.
--
-- Design:
--   Target table: events_daily_country (AggregatingMergeTree)
--     ORDER BY (country, day) — small, grouped by country/day
--     Stores AggregateFunction states for purchases and revenue.
--   MV: only sees NEW inserts. Historical 100M rows must be backfilled manually
--     (the classic trap).
--
-- The MV filters event_type='purchase' inside, so it only serves purchase queries.

-- Target table for pre-aggregated data
CREATE TABLE IF NOT EXISTS exp.events_daily_country
(
    day      Date,
    country  LowCardinality(String),
    purchases AggregateFunction(count),
    revenue   AggregateFunction(sum, Decimal(10, 2))
)
ENGINE = AggregatingMergeTree
ORDER BY (country, day);

-- Materialized View: incrementally maintains the target table
CREATE MATERIALIZED VIEW IF NOT EXISTS exp.mv_daily_country
TO exp.events_daily_country
AS
SELECT
    toDate(created_at) AS day,
    country,
    countState()       AS purchases,
    sumState(amount)   AS revenue
FROM exp.events
WHERE event_type = 'purchase'
GROUP BY day, country;
