-- Phase 1: deterministic dataset generation, 100M rows.
-- Determinism: every column is a pure function of `number` (row index from
-- numbers_mt). No rand(), no state -> re-running produces byte-identical data.
--
-- Distributions (rationale in docs/dataset.md):
--   created_at : uniform seconds over 2024-09-01..2025-08-31 (31,536,000 s = 365 d)
--   event_type : 12 types; 'purchase' = 5% (bucket 0 of 20)
--   country    : 200 values 'c000'..'c199', skewed toward low ids (pow 0.5)
--   product_id : 100k products, skewed toward low ids (pow 2.0)
--   user_id    : 10M users
--   amount     : lognormal-ish, correlated with country id (per-country AOV)

INSERT INTO exp.events
WITH
    base AS
    (
        SELECT number AS n FROM numbers_mt(100000000)
    ),
    derived AS
    (
        SELECT
            n,
            (n * 668265263) % 20                                    AS type_bucket,
            toUInt8(199 * pow(((n * 1103515245 + 12345) % 1000000) / 1000000.0, 0.5)) AS country_idx,
            toUInt32(99999 * pow(((n * 22695477 + 1) % 1000000) / 1000000.0, 2.0))    AS product_id,
            toDateTime('2024-09-01 00:00:00') + (n * 2654435761) % 31536000           AS created_at,
            exp(((n * 48271) % 100000) / 100000.0 * 4.0)            AS amount_base
        FROM base
    )
SELECT
    n AS event_id,
    (n * 2654435761) % 10000000 AS user_id,
    multiIf(
        type_bucket = 0,  'purchase',
        type_bucket IN (1, 2, 3), 'page_view',
        type_bucket IN (4, 5),    'add_to_cart',
        type_bucket IN (6, 7),    'search',
        type_bucket = 8,  'signup',
        type_bucket = 9,  'login',
        type_bucket = 10, 'logout',
                          'share'
    ) AS event_type,
    concat('c', toString(country_idx)) AS country,
    product_id,
    created_at,
    toDecimal64(amount_base * (1 + country_idx % 20), 2) AS amount
FROM derived;
