-- N3 (Way 2): GROUP BY product_id. Projection contains all needed columns, so it
-- CAN be selected even though this is not the design-target query shape.
SELECT product_id, count() AS c, sum(amount) AS revenue
FROM exp.events
WHERE event_type = 'purchase'
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY product_id
ORDER BY revenue DESC, product_id
LIMIT 10;
