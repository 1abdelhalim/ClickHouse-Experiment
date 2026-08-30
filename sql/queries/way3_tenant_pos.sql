-- Way 3 POSITIVE: filter one tenant_id (picked from within THE window by a
-- scalar subquery, so it works at any dataset size). tenant_id is assigned in
-- contiguous blocks and created_at is monotonic -> every granule has a tight
-- tenant_id [min,max] -> the minmax index prunes almost every granule.
SELECT count(), sum(amount), min(created_at), max(created_at)
FROM exp.events_skip
WHERE tenant_id = (
        SELECT tenant_id FROM exp.events_skip
        WHERE created_at >= toDateTime('2025-08-16 12:00:00') LIMIT 1
      )
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00');
