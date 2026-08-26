-- Correctness anchor: returns a single hash of THE query's full result.
-- Every variant must return the SAME value as baseline.
-- Baseline value recorded in docs/phase3_report.md.
SELECT cityHash64(groupArray(tuple(country, day, purchases, revenue)))
FROM
(
    SELECT
        country,
        toDate(created_at) AS day,
        count()            AS purchases,
        sum(amount)        AS revenue
    FROM exp.events
    WHERE event_type = 'purchase'
      AND created_at >= toDateTime('2025-08-02 00:00:00')
      AND created_at <  toDateTime('2025-09-01 00:00:00')
    GROUP BY country, day
    ORDER BY revenue DESC
    LIMIT 10
);
