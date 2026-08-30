-- Way 3, Step 1: distribution forensics BEFORE choosing an index.
--
-- A skip index prunes a granule only when the filtered value is ABSENT from it.
-- Measure per-granule concentration of each candidate column, in primary-key
-- order, over THE query's window:
--   tenant_id : block-assigned + monotonic created_at -> a granule spans a tiny
--               tenant range -> minmax index prunes hard.  POSITIVE case.
--   country   : hash-scattered -> ~every granule holds ~every country ->
--               set() index is dead weight.  NEGATIVE case.

DROP TABLE IF EXISTS exp._tmp_forensics;

CREATE TABLE exp._tmp_forensics
ENGINE = MergeTree ORDER BY rn AS
SELECT rowNumberInAllBlocks() + 1 AS rn, tenant_id, country
FROM
(
    SELECT tenant_id, country
    FROM exp.events
    WHERE created_at >= toDateTime('2025-08-02 00:00:00')
      AND created_at <  toDateTime('2025-09-01 00:00:00')
    ORDER BY created_at, event_type
)
SETTINGS max_threads = 1;

-- distinct values per 8192-row granule
SELECT
    'granules_in_window'        AS metric, toString(count())                       AS value FROM (SELECT 1 FROM exp._tmp_forensics GROUP BY intDiv(rn-1, 8192))
UNION ALL SELECT 'tenant_distinct_per_granule_p50', toString(quantile(0.5)(u)) FROM (SELECT uniqExact(tenant_id) u FROM exp._tmp_forensics GROUP BY intDiv(rn-1,8192))
UNION ALL SELECT 'tenant_distinct_per_granule_max', toString(max(u))           FROM (SELECT uniqExact(tenant_id) u FROM exp._tmp_forensics GROUP BY intDiv(rn-1,8192))
UNION ALL SELECT 'country_distinct_per_granule_p50', toString(quantile(0.5)(u)) FROM (SELECT uniqExact(country) u   FROM exp._tmp_forensics GROUP BY intDiv(rn-1,8192))
UNION ALL SELECT 'country_distinct_per_granule_max', toString(max(u))          FROM (SELECT uniqExact(country) u   FROM exp._tmp_forensics GROUP BY intDiv(rn-1,8192));

-- granule coverage of the heaviest country (expect ~100% -> set() cannot prune it)
SELECT 'coverage_country_c0_pct' AS metric,
       round(countIf(present) / count() * 100, 2) AS value
FROM (SELECT max(country = 'c0') AS present FROM exp._tmp_forensics GROUP BY intDiv(rn-1, 8192));

DROP TABLE exp._tmp_forensics;
