-- THE query against exp.events_skip. THE query; every variant must return an identical
-- result hash (see results/linux/correctness_*.txt).
SELECT
    country,
    toDate(created_at) AS day,
    count()            AS purchases,
    sum(amount)        AS revenue
FROM exp.events_skip
WHERE event_type = 'purchase'
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY country, day
ORDER BY revenue DESC, country, day
LIMIT 10;
