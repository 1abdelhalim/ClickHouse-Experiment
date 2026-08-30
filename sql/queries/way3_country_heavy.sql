-- Way 3 NEGATIVE: THE query restricted to a heavy country (c0, ~17% of rows).
-- c0 is in essentially every granule -> the set() index prunes nothing.
SELECT country, toDate(created_at) AS day, count() AS purchases, sum(amount) AS revenue
FROM exp.events_skip
WHERE event_type = 'purchase' AND country = 'c0'
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY country, day ORDER BY revenue DESC, country, day LIMIT 10;
