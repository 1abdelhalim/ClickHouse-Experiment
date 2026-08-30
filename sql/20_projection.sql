-- Way 2: Projection on the BASELINE table (no base-table rewrite).
--
-- v2 change (docs/critical_review.md §5.1, §7): v1 used a full 7-column
-- projection — a complete second copy of the table (+100% storage). For THE
-- query you only need four columns. This NARROW normal projection is the
-- sensible default. run_all.sh additionally measures:
--   * proj_full  — the v1 all-columns projection, for the storage contrast
--   * proj_lw    — a lightweight (_part_offset) projection, ClickHouse >= 25.5,
--                  which stores only its sort key + a pointer back to the base
--                  part and behaves like a secondary index
--
-- Hypothesis: the optimiser auto-selects proj_country_day for THE query,
-- giving the same granule reduction as Way 1 with no base-table rewrite.

ALTER TABLE exp.events
ADD PROJECTION proj_country_day
(
    SELECT event_type, country, created_at, amount
    ORDER BY (event_type, country, created_at)
);

ALTER TABLE exp.events
MATERIALIZE PROJECTION proj_country_day;
