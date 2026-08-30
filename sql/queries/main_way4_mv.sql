-- Way 4: THE query rewritten to read the pre-aggregated MV target.
-- Uses -Merge combinators over the AggregateFunction states.
SELECT
    country,
    day,
    countMerge(purchases) AS purchases,
    sumMerge(revenue)     AS revenue
FROM exp.events_daily_country
WHERE day >= '2025-08-02' AND day < '2025-09-01'
GROUP BY country, day
ORDER BY revenue DESC, country, day
LIMIT 10;
