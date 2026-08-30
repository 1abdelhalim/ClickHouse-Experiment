-- N1: point lookup on event_id — NOT a prefix of any ORDER BY, and the query has
-- no created_at predicate, so neither layout can prune. Way 1's reordering must
-- NOT help. (id chosen from within the data by a subquery -> size-independent.)
SELECT event_id, tenant_id, user_id, country, amount
FROM exp.events_orderby
WHERE event_id = (SELECT event_id FROM exp.events_orderby WHERE country = 'c5' LIMIT 1);
