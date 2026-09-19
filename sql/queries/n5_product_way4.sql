-- N5 (Way 4): a query the MV target CANNOT serve (no product_id in it).
-- Run against exp.events after Way 2's negative-test projection has been
-- dropped, so this is a raw in-range scan — the dual-path you keep if the
-- rollup does not cover the question.
SELECT product_id, count() AS c, sum(amount) AS revenue
FROM exp.events
WHERE event_type = 'purchase'
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY product_id
ORDER BY revenue DESC, product_id
LIMIT 10;
