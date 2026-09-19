# Four ways to speed up one ClickHouse query

**Measure the work the engine skips, not the milliseconds on a warm laptop.**

A realistic dashboard query — daily purchase revenue by country, last 30 days,
top 10 — over a 100-million-row events table. ClickHouse already does the
obvious things: monthly partitions drop 12,212 granules to 1,037; the time-first
primary key takes that to 1,004; `PREWHERE` pulls the filters in front of the
read. Then it stops. The query needs about 410 thousand purchase rows. It reads
**8.22 million**. That 20× gap is the headroom.

This article is a controlled comparison of four ways to close it:

1. Redesign `ORDER BY`
2. Add a projection (leave the base table alone)
3. Add data skipping indexes
4. Precompute with a materialized view

The headline metric is not wall time. It is **granules and rows read**
(`SelectedMarks` / `read_rows`), verified with `EXPLAIN`. Latency on the box we
used is directional only: a 4-vCPU GitHub Codespace, 15.6 GB RAM, and a ~115 MB
working set that fits in memory many times over. Reproduce everything from
[this repository](https://github.com/1abdelhalim/ClickHouse-Experiment).

## The query

```sql
SELECT
    country,
    toDate(created_at) AS day,
    count()            AS purchases,
    sum(amount)        AS revenue
FROM exp.events
WHERE event_type = 'purchase'
  AND created_at >= toDateTime('2025-08-02 00:00:00')
  AND created_at <  toDateTime('2025-09-01 00:00:00')
GROUP BY country, day
ORDER BY revenue DESC, country, day
LIMIT 10;
```

Baseline table: `MergeTree`, `PARTITION BY toYYYYMM(created_at)`,
`ORDER BY (created_at, event_type)`. That is a deliberate time-first default —
the key you get if you model “events, ordered by time” and have not yet looked
at this query. Partitioning here is a lifecycle boundary (drop a month, TTL),
not a performance trick.

## Dataset

100 million rows, generated with no `rand()`: every column is a pure function of
the row index. Two reproducibility anchors:

- data checksum `14701560614780328933`
- result hash of THE query `15313934330332105907` — **identical** on baseline,
  the reordered table, three projection flavours, the skip-index table, and the
  materialized view

| property | value |
|---|---|
| On disk / uncompressed | 1.36 GiB / 3.54 GiB (codecs: `Delta,LZ4` / `ZSTD(1)`) |
| `event_type` | 12 values; `purchase` = 5.0% |
| `country` | 199 values, `pow(u,3)` skew; heaviest 17%, hash-scattered across granules |
| `tenant_id` | 2,000 values in contiguous 50k-row blocks — clustered |
| `created_at` | monotonic ramp over a year + ≤600 s jitter (append-like) |

`country` is the honest **negative** for a skip index (a heavy country appears in
every granule). `tenant_id` is the honest **positive** (one value per granule).
Same table, same query shape, one column swapped.

ClickHouse 26.9.1, native Linux binary, new analyzer on. One command:
`bench/run_all.sh`.

## What changed about the work

From `system.query_log` / `ProfileEvents`. Identical hot or cold. Checked against
`EXPLAIN indexes = 1`.

| approach | plan | granules | read_rows | vs baseline |
|---|---|--:|--:|--:|
| Baseline | `exp.events` | 1,004 | 8,222,000 | 1.0× |
| Way 1 — `ORDER BY (event_type, country, created_at)` | `exp.events_orderby` | **53** | **434,176** | **18.9× fewer** |
| Way 2 — narrow / full projection | auto-selected | **53** | **434,176** | **18.9× fewer** |
| Way 2 — lightweight (`_part_offset`) | *not selected* | 1,004 | 8,222,000 | 1.0× |
| Way 3 — skip indexes, THE query | `set(country)` unused | 1,004 | 8,222,000 | 1.0× |
| Way 4 — AggregatingMergeTree MV | 7,099 pre-aggregated rows | **1** | **7,099** | **1,158× fewer** |

These are the results. Way 1 and a narrow projection collapse the scan by putting
`event_type` first so generic-exclusion search skips ~95% non-purchase granules.
The MV answers from a rollup. A skip index on a scattered `country` column does
nothing for this query — and still costs a lookup on every granule.

### Way 1 — change the sort key

```sql
ORDER BY (event_type, country, created_at)
```

Low-cardinality filter first, `GROUP BY` column second, time last. Storage after
`OPTIMIZE FINAL` is the same 1.36 GiB. Rewrite took 150 seconds. The cost is
every *other* query that wanted time locality: a pure 30-day range with no
`event_type` filter reads **10.9× more rows** and 88 fragmented ranges (N2).

If this query is the product, change the key. If it is one query among many,
do not.

### Way 2 — a projection, same 19×, base table untouched

A **narrow** normal projection stores only the four columns THE query needs,
sorted the same way as Way 1:

```sql
ALTER TABLE exp.events ADD PROJECTION proj_narrow
(
    SELECT event_type, country, created_at, amount
    ORDER BY (event_type, country, created_at)
);
ALTER TABLE exp.events MATERIALIZE PROJECTION proj_narrow;
```

`EXPLAIN` shows `ReadFromMergeTree (proj_narrow)` — 53 granules, 434,176 rows.
The application SQL does not change. Storage: **+747 MiB (+54%)**. A full-column
projection gave the same read volume at +2.03 GiB; there is no reason to pay
that for this query.

A lightweight projection (`SELECT …, _part_offset ORDER BY (event_type, country)`)
was **larger than the narrow copy (838 MiB)** and **not selected**. THE query
aggregates `amount`, which that projection does not store. On 26.9 with this
syntax, ClickHouse fell back to the 1,004-granule base scan. That is a result
for *this* aggregate, not a verdict on ClickHouse 25.6+ secondary-index
projections or the 26.1 `PROJECTION … INDEX … TYPE basic` form — those are a
follow-up.

**Negative (N4):** `GROUP BY event_type` is served from the base table. The
optimizer is allowed to refuse a projection; always check `EXPLAIN`.

### Way 3 — skip indexes only where values cluster

Forensics first. Per granule: `tenant_id` has 1 distinct value (max 2);
`country` has 199 — fully scattered; the heaviest country covers 100% of
granules.

| probe | index | granules / rows | vs THE-query baseline |
|---|---|---|---|
| `tenant_id = 1920` | `minmax` | **7 / 57,344** | **143× fewer** |
| `country = 'c0'` (heavy) | `set(1000)` | 1,004 / 8.22M | 1.0× — zero prune |
| THE query (`GROUP BY country`) | `set(country)` | 1,004 / 8.22M | unused |
| `user_id = 9999979` (~84 rows) | `bloom_filter` | 185 / 1.52M | 82% granules skipped, **~18,000× over-read** |

A skip index is a granule filter, not a row index. If the value you care about
sits in every granule, the index is dead weight — on THE query, that tax showed
up as a slower run at the same 8.22 million rows. Measure coverage before
`ADD INDEX`.

### Way 4 — precomputation, not a transparent trick

```sql
CREATE TABLE exp.events_daily_country
(
    day       Date,
    country   LowCardinality(String),
    purchases AggregateFunction(count),
    revenue   AggregateFunction(sum, Decimal(10, 2))
)
ENGINE = AggregatingMergeTree
ORDER BY (day, country);

CREATE MATERIALIZED VIEW exp.mv_daily_country TO exp.events_daily_country AS
SELECT
    toDate(created_at) AS day,
    country,
    countState()       AS purchases,
    sumState(amount)   AS revenue
FROM exp.events
WHERE event_type = 'purchase'
GROUP BY day, country;
```

Query with `countMerge` / `sumMerge`. 7,099 rows, 1 granule, +437 KiB on disk.
The MV only sees **new** inserts; historical rows need a manual backfill (411 ms
here for 5.1 million purchases). A query the rollup cannot serve
(`GROUP BY product_id`) reads the raw table: **1,004 granules / 8.22 million
rows**. You keep a dual path or you accept that this dashboard is the only shape
you optimized.

A 1-million-row insert was not slower with the MV attached at this scale
(697 ms vs 846 ms without). Treat write amplification as unproven here, not as
“free.”

## What each lever costs

| | build | extra storage | write path | flexibility |
|---|---|---|---|---|
| Way 1 | 150 s rewrite | ±0 | wider sort key | queries off the prefix regress (N2) |
| Way 2 narrow | 91 s | +747 MiB | projection on insert | none — SQL unchanged |
| Way 3 minmax(tenant) | in-insert | +23 KiB | negligible | none, *if* the column is clustered |
| Way 3 set(country) | in-insert | +5.9 MiB | index lookup on read | unused for THE query |
| Way 4 | backfill | +437 KiB | extra aggregate on insert | only `(day, country)` purchases |

## A decision guide

- **This query is the product, and you can rebuild the table** → change
  `ORDER BY`. Cheapest storage. Pay with every other access pattern.
- **You cannot rewrite, or you have several sort orders** → a **narrow**
  projection. Same 19× for this query, +54% disk, optimizer must actually pick
  it (`EXPLAIN`).
- **You filter a column that clusters with the primary key** → a skip index,
  after you have measured per-granule coverage. Do not index a scattered
  dimension because the query mentions it.
- **The dashboard is fixed and you can maintain a rollup** → an incremental
  materialized view. Two-to-three orders of magnitude less work, coupled to one
  schema, with a backfill trap.

Do not start with skip indexes. Do not treat an MV as “the same as a
projection.” Do not quote a 12 ms delta on a 115 MB scan as a speedup.

## How to reproduce

```bash
# GitHub Codespace on this repo, or any Linux box with ClickHouse 26.9.1
bench/run_all.sh --smoke   # 12M rows, plumbing
bench/run_all.sh           # 100M rows → results/linux/
```

The installer and `docker-compose` image are pinned to **26.9.1**. The harness
pins `max_threads`, disables the query cache and query condition cache, stops
merges before every measurement block, and reports coefficient of variation.

Correctness: every variant must print `15313934330332105907`.

## Limitations (read these before citing a number)

1. **Not bare metal.** Shared Codespace vCPU, virtual disk. Absolute milliseconds
   are indicative. `read_rows` / `SelectedMarks` are the publishable output.
2. **Working set ≪ RAM.** ~115 MB for THE query. `min_bytes_to_use_direct_io = 1`
   bypasses the page cache; it does not make the query I/O-bound.
3. **The v2 interleaved latency table is invalid for baseline.** A leftover
   projection on `exp.events` served the interleaved “baseline” (53 marks).
   Standalone artifacts are the source of truth; the harness now drops that
   projection before interleave.
4. Single node, no replication, no TTL. Lightweight projections were tested with
   `_part_offset` syntax, not 26.1 indexing projections.

If you need quotable cold-cache wall times, re-run `bench/run_all.sh` on a
dedicated instance with a working set larger than RAM. The scripts do not
change.

## Takeaway

On one query, four physical layouts:

- **Sort key or a matching narrow projection** — ~19× fewer rows, if
  `event_type` leads the key.
- **Skip index** — 143× when the column is clustered; 1.0× (and extra work)
  when it is not.
- **Materialized view** — ~1,158× fewer rows, as precomputation, with
  operational cost.

Pick the lever that matches the query set you actually have. Measure granules
first.
