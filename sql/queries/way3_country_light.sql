-- Way 3 PARTIAL: THE query restricted to a light-tail country (c120).
-- c120 is absent from many granules -> the set() index prunes those.
SELECT country, toDate(created_at) AS day, count() AS purchases, sum(amount) AS revenue
FROM exp.events_skip
WHERE event_type = 'purchase' AND country = 'c120'
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY country, day ORDER BY revenue DESC, country, day LIMIT 10;
