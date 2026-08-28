-- Way 3: THE query restricted to a single country (c198) on exp.events_skip.
-- Tests whether the set(512) index on country can prune granules.
SELECT country, toDate(created_at) AS day, count() AS purchases, sum(amount) AS revenue
FROM exp.events_skip
WHERE event_type = 'purchase'
  AND country = 'c198'
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY country, day
ORDER BY revenue DESC
LIMIT 10;
