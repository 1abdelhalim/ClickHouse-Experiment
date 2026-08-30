-- THE query. Business meaning:
-- "Daily revenue and purchase count per country for the last 30 days of the dataset,
--  top 10 countries by revenue."
--
-- Reference date is fixed (max created_at in the data) so the query is stable and
-- reproducible regardless of when it is run. Dataset spans 2024-09-01..2025-08-31,
-- so the window is 2025-08-02..2025-09-01.
--
-- Every optimized variant must return results logically equivalent to this.

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
ORDER BY revenue DESC, country, day
LIMIT 10;
