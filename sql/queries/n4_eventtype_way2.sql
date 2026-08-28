-- N4 (Way 2): GROUP BY event_type only. Expect the optimizer to stay on the
-- narrow base column and NOT use the (wider) projection. Honest fallback case.
SELECT event_type, count() AS c
FROM exp.events
WHERE created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY event_type
ORDER BY c DESC;
