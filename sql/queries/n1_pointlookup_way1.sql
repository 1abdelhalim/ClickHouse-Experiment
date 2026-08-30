-- N1: point lookup on a fixed event_id. event_id is in neither table's ORDER BY,
-- so the reordering (Way 1) must not change this query. (In practice both prune
-- to one granule anyway: event_id is monotonic with created_at, so the value
-- localises to one partition + granule. The point stands — Way 1 is neutral here.)
SELECT event_id, tenant_id, user_id, country, amount
FROM exp.events_orderby
WHERE event_id = 61000000;
