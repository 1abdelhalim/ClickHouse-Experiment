-- Way 2: Projection on the BASELINE table.
-- Projection mirrors Way 1's physical ordering (event_type, country, created_at)
-- without changing the base table. Hypothesis: CH's optimizer auto-selects this
-- for THE query, giving similar read_rows reduction to Way 1.
--
-- We use a NORMAL projection (not aggregating) to keep the comparison to Way 1
-- apples-to-apples: same data layout, just transparently selected.

ALTER TABLE exp.events
ADD PROJECTION proj_country_day
(
    SELECT event_id, user_id, event_type, country, product_id, created_at, amount
    ORDER BY (event_type, country, created_at)
);

ALTER TABLE exp.events
MATERIALIZE PROJECTION proj_country_day;
