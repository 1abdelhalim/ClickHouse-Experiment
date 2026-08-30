-- Way 4: Materialized View — precomputation, NOT a query-transparent optimization.
--
-- Target: events_daily_country (AggregatingMergeTree), ORDER BY (day, country).
--   v2 change: v1 used ORDER BY (country, day), but THE query filters on a day
--   range and groups by (country, day) — (day, country) lets the range prune the
--   primary index. Immaterial at ~72k rows, correct at scale (docs/critical_review.md §7).
-- The MV filters event_type='purchase' inside, so it only serves purchase queries.
-- The MV sees only NEW inserts; historical rows need a manual backfill (the trap).

DROP TABLE IF EXISTS exp.mv_daily_country;
DROP TABLE IF EXISTS exp.events_daily_country;

CREATE TABLE exp.events_daily_country
(
    day       Date,
    country   LowCardinality(String),
    purchases AggregateFunction(count),
    revenue   AggregateFunction(sum, Decimal(10, 2))
)
ENGINE = AggregatingMergeTree
ORDER BY (day, country);

CREATE MATERIALIZED VIEW exp.mv_daily_country
TO exp.events_daily_country
AS
SELECT
    toDate(created_at) AS day,
    country,
    countState()     AS purchases,
    sumState(amount) AS revenue
FROM exp.events
WHERE event_type = 'purchase'
GROUP BY day, country;
