-- Way 3, Step 1: distribution forensics BEFORE choosing an index.
--
-- A skip index prunes a granule only when the filtered value is ABSENT from it.
-- So: measure per-granule concentration of each candidate column, in primary-key
-- order, over THE query's window.
--
--   tenant_id : assigned in contiguous 50k-row blocks, and created_at is
--               monotonic, so a granule spans a tiny tenant range
--               -> minmax index prunes hard.  POSITIVE case.
--   country   : hash-scattered. Heavy countries (c0..) sit in ~every granule;
--               tail countries in a small fraction.  set() index is dead weight
--               for the heavy ones.  NEGATIVE case.

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

SELECT 'total_granules_in_window' AS k, toString(ceil(max(rn) / 8192)) AS v FROM exp._tmp_forensics
UNION ALL
SELECT 'tenant_distinct_per_granule_p50',
       toString(quantile(0.5)(u)) FROM (SELECT intDiv(rn-1,8192) g, uniqExact(tenant_id) u FROM exp._tmp_forensics GROUP BY g)
UNION ALL
SELECT 'tenant_distinct_per_granule_max',
       toString(max(u)) FROM (SELECT intDiv(rn-1,8192) g, uniqExact(tenant_id) u FROM exp._tmp_forensics GROUP BY g)
UNION ALL
SELECT 'country_distinct_per_granule_p50',
       toString(quantile(0.5)(u)) FROM (SELECT intDiv(rn-1,8192) g, uniqExact(country) u FROM exp._tmp_forensics GROUP BY g)
UNION ALL
SELECT 'country_distinct_per_granule_max',
       toString(max(u)) FROM (SELECT intDiv(rn-1,8192) g, uniqExact(country) u FROM exp._tmp_forensics GROUP BY g);

SELECT 'granule_coverage_%' AS metric, kind, val, round(countIf(present)/count()*100, 2) AS pct
FROM
(
    SELECT 'tenant' kind, '2900' val, intDiv(rn-1,8192) g, max(tenant_id = 2900) present FROM exp._tmp_forensics GROUP BY g
    UNION ALL SELECT 'country','c0',   intDiv(rn-1,8192), max(country='c0')   FROM exp._tmp_forensics GROUP BY g
    UNION ALL SELECT 'country','c120', intDiv(rn-1,8192), max(country='c120') FROM exp._tmp_forensics GROUP BY g
)
GROUP BY kind, val ORDER BY kind, val;

DROP TABLE exp._tmp_forensics;
