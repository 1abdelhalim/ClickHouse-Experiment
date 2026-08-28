-- N2: pure time-range query, NO event_type filter. The time-first baseline
-- ordering should beat Way 1 here (Way 1 destroys time locality).
SELECT toDate(created_at) AS day, count()
FROM exp.events
WHERE created_at >= toDateTime('2025-08-30 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY day
ORDER BY day;
