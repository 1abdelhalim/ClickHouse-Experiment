-- N5 (Way 4): a query the MV target CANNOT serve (no product_id in it).
-- Run against exp.events (which has the Way 2 projection) to show the fallback.
SELECT product_id, count() AS c, sum(amount) AS revenue
FROM exp.events
WHERE event_type = 'purchase'
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY product_id
ORDER BY revenue DESC, product_id
LIMIT 10;
