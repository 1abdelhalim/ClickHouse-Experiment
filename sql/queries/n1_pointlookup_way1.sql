-- N1: point lookup on event_id (unique, sequential, NOT a prefix of any ORDER BY).
-- Way 1's reordering must NOT help this — it only helps predicates matching the key.
SELECT event_id, tenant_id, user_id, country, amount
FROM exp.events_orderby
WHERE event_id = 77000000;
