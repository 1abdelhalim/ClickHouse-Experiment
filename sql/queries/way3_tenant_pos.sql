-- Way 3 POSITIVE: one tenant_id. tenant_id is assigned in contiguous 50k-row
-- blocks and created_at is monotonic, so every granule carries a tight
-- tenant_id [min,max] -> the minmax index prunes almost every granule.
-- tenant 1920 = 50,000 rows, all within THE window (2025-08-17).
SELECT count(), sum(amount), min(created_at), max(created_at)
FROM exp.events_skip
WHERE tenant_id = 1920
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00');
