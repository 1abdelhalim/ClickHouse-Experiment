-- Way 3, Step 1: distribution forensics BEFORE choosing an index.
-- Build a temp table with sequential row numbers in ORDER BY key order,
-- then group into 8192-row granules to measure country clustering.

DROP TABLE IF EXISTS exp._tmp_forensics;

CREATE TABLE exp._tmp_forensics
ENGINE = MergeTree
ORDER BY rn AS
SELECT
    rowNumberInAllBlocks() + 1 AS rn,
    country
FROM
(
    SELECT country
    FROM exp.events
    WHERE created_at >= toDateTime('2025-08-01 00:00:00')
      AND created_at <  toDateTime('2025-09-01 00:00:00')
    ORDER BY created_at, event_type
    LIMIT 1000000
)
SETTINGS max_threads = 1;

SELECT 'countries_per_granule';
SELECT
    quantile(0.5)(uniq_countries) AS median_countries_per_granule,
    quantile(0.9)(uniq_countries) AS p90_countries_per_granule,
    max(uniq_countries)           AS max_countries_per_granule
FROM
(
    SELECT intDiv(rn - 1, 8192) AS granule,
           uniqExact(country) AS uniq_countries
    FROM exp._tmp_forensics
    GROUP BY granule
);

SELECT 'c198_coverage';
SELECT
    countIf(has_country = 1) AS granules_with_c198,
    count()                  AS total_granules,
    round(countIf(has_country = 1) / count() * 100, 1) AS pct
FROM
(
    SELECT intDiv(rn - 1, 8192) AS granule,
           max(country = 'c198') AS has_country
    FROM exp._tmp_forensics
    GROUP BY granule
);

SELECT 'c0_coverage';
SELECT
    countIf(has_country = 1) AS granules_with_c0,
    count()                  AS total_granules,
    round(countIf(has_country = 1) / count() * 100, 1) AS pct
FROM
(
    SELECT intDiv(rn - 1, 8192) AS granule,
           max(country = 'c0') AS has_country
    FROM exp._tmp_forensics
    GROUP BY granule
);

DROP TABLE exp._tmp_forensics;
