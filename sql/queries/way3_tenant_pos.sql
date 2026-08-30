-- Way 3 POSITIVE: filter a single tenant_id. tenant_id is block-clustered, so the
-- minmax index gives every granule a tight [min,max] and prunes almost everything.
SELECT count(), sum(amount), min(created_at), max(created_at)
FROM exp.events_skip
WHERE tenant_id = 2900
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00') ;
