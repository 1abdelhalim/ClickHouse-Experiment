-- N1: point lookup on event_id (a fixed id). NOT a prefix of any ORDER BY and
-- no created_at predicate -> neither layout can prune; both full-scan. Way 1's
-- reordering must NOT help.
SELECT event_id, tenant_id, user_id, country, amount
FROM exp.events
WHERE event_id = 61000000;
