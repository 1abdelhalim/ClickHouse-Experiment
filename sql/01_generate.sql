-- Phase 1: deterministic dataset generation (v2 — rigour pass).
--
-- Determinism: every column is a pure function of the row index `n`. The uniform
-- component comes from cityHash64(n, <salt>) — a fixed algorithm, stable across
-- ClickHouse builds and CPU architectures (the v1 checksum matched between Apple
-- M3 and AMD EPYC). pow()/exp() only *shape* an already-uniform input.
--
-- What changed vs v1 (docs/critical_review.md §6):
--   created_at : monotonic ramp over the data year + ±5 min jitter, so the table
--                is append-ordered like real ingestion. v1 was uniform-random
--                per row.
--   tenant_id  : assigned in contiguous 50k-row blocks -> clustered within
--                granules. Skip-index POSITIVE case. 3000 tenants.
--   country    : real skew, pow(u,3): heaviest ~17% of rows, top-10 ~37%, long
--                tail. Hash-scattered -> skip-index NEGATIVE case, and still the
--                GROUP BY target that is absent from the baseline ORDER BY.
--                v1 used pow(u,0.5) which was near-uniform (top-10 9.8%).
--   event_type : 12 DISTINCT types (v1 collapsed to 8 while docs claimed 12).
--                'purchase' is bucket 0 = 5%.
--   user_id    : power-law, pow(u,2). v1's (n*K)%1e7 gave every user exactly 10
--                events. Now a few thousand heavy users + a long light tail.
--   event_id   : still = n. Now it has a job: the guaranteed-single-row point-
--                lookup key (N1). Delta-coded.
--   salts      : every derived column draws an independent cityHash64 salt — no
--                two columns correlate (v1 reused one multiplier for user_id and
--                created_at).
--
-- {ROWS} is templated by bench/run_all.sh; default 150000000.

INSERT INTO exp.events
WITH
    base AS
    (
        SELECT number AS n FROM numbers_mt({ROWS})
    ),
    hashed AS
    (
        SELECT
            n,
            cityHash64(n, 1) % 20                              AS type_bucket,
            (cityHash64(n, 2) % 1000000) / 1000000.0           AS u_country,
            (cityHash64(n, 3) % 1000000) / 1000000.0           AS u_product,
            cityHash64(n, 4) % 601                             AS jitter,   -- 0..600 s
            (cityHash64(n, 5) % 1000000) / 1000000.0           AS u_user,
            (cityHash64(n, 6) % 100000)  / 100000.0            AS u_amount
        FROM base
    ),
    derived AS
    (
        SELECT
            n,
            type_bucket,
            toUInt16(199 * pow(u_country, 3.0))                         AS country_idx,
            toUInt32(99999 * pow(u_product, 2.0))                       AS product_id,
            -- monotonic ramp over the data year, plus 0..600 s jitter.
            -- Ramp span 31 535 400 s + max jitter 600 s = 31 536 000 s exactly,
            -- so created_at stays within [2024-09-01 00:00:00, 2025-08-31 23:59:59]
            -- -> clean 12 monthly partitions.
            toDateTime('2024-09-01 00:00:00')
              + toInt64(intDiv(n * 31535400, {ROWS}))
              + toInt64(jitter)                                         AS created_at,
            toUInt64(9999999 * pow(u_user, 2.0))                        AS user_id,
            toUInt32(intDiv(n, 50000) % 3000)                           AS tenant_id,
            exp(u_amount * 4.0)                                         AS amount_base
        FROM hashed
    )
SELECT
    n AS event_id,
    tenant_id,
    user_id,
    multiIf(
        type_bucket = 0,             'purchase',
        type_bucket IN (1,2,3,4,5,6),'page_view',
        type_bucket IN (7,8,9),      'add_to_cart',
        type_bucket IN (10,11),      'search',
        type_bucket = 12,            'signup',
        type_bucket = 13,            'login',
        type_bucket = 14,            'logout',
        type_bucket = 15,            'wishlist_add',
        type_bucket = 16,            'product_view',
        type_bucket = 17,            'review_submit',
        type_bucket = 18,            'share',
                                     'refund'
    ) AS event_type,
    concat('c', toString(country_idx)) AS country,
    product_id,
    created_at,
    toDecimal64(amount_base * (1 + country_idx % 20), 2) AS amount
FROM derived;
