# Experiment v2 — Consolidated Report

**Status: DRAFT — numbers filled from `results/linux/` after the v2 run.**
Supersedes the Phase 1–3 and Way 1–4 reports (kept for history; each carries a
banner pointing here). The v1→v2 delta is driven by `docs/critical_review.md`.

- **Environment:** GitHub Codespaces, ClickHouse `26.9.1` **native binary**,
  4 vCPU AMD EPYC 7763, 16 GB RAM. Not bare metal — see §7.
- **Dataset:** 100 M rows, deterministic (`cityHash64(n, salt)` per column),
  `env/manifest_linux.md` + `results/linux/settings.txt` for the exact runtime.
- **Pipeline:** `bench/run_all.sh` — one command, ~2 h wall.

---

## 1. THE query

> Daily revenue and purchase count per country, last 30 days of the dataset,
> top 10 countries by revenue.

```sql
SELECT country, toDate(created_at) AS day, count() AS purchases, sum(amount) AS revenue
FROM exp.events
WHERE event_type = 'purchase'
  AND created_at >= '2025-08-02 00:00:00' AND created_at < '2025-09-01 00:00:00'
GROUP BY country, day
ORDER BY revenue DESC, country, day        -- tiebreak -> deterministic result hash
LIMIT 10;
```

The baseline `ORDER BY (created_at, event_type)` prunes the date range well
(monotonic `created_at` + monthly partitions) but **`country` is not in the key**,
so the `GROUP BY country` still reads every in-window granule, and the 5%
`event_type='purchase'` selectivity buys almost nothing because `event_type` is
the *second* key. That headroom is what Ways 1–3 attack. Way 4 sidesteps it.

## 2. Dataset (v2)

| property | value |
|---|---|
| rows | 100,000,000 |
| compressed / uncompressed | _(fill)_ / _(fill)_ |
| partitions / parts | 12 / _(fill)_ |
| `event_type` | 12 distinct; `purchase` = _(fill)_% |
| `country` | 199 distinct; heaviest _(fill)_%, top-10 _(fill)_%, long tail |
| `tenant_id` | _(fill)_ distinct, assigned in 50k-row blocks (clustered) |
| `user_id` | _(fill)_ distinct, power-law |
| `created_at` | monotonic ramp 2024-09-01 → 2025-08-31 + ≤600 s jitter |
| codecs | `Delta,LZ4` on event_id/tenant_id/created_at; `ZSTD(1)` on user_id/product_id/amount; LC dictionaries elsewhere |
| data checksum | _(fill)_ — reproducibility anchor |
| result hash (all variants) | _(fill)_ |

Distributions are **measured, not just designed** — `results/linux/distributions.txt`.

## 3. Results — read volume (cache-independent, exact)

These come straight from `system.query_log` / `ProfileEvents` and are identical
hot or cold. They are the primary results.

| approach | table/plan | SelectedMarks | read_rows | read_bytes | ×rows vs baseline |
|---|---|--:|--:|--:|--:|
| baseline | `exp.events` | _(fill)_ | _(fill)_ | _(fill)_ | 1.0× |
| Way 1 — ORDER BY | `exp.events_orderby` | | | | |
| Way 2 — projection (narrow) | `proj_country_day` | | | | |
| Way 2 — projection (full) | `proj_full` | | | | |
| Way 2 — projection (lightweight) | _(fill: selected? )_ | | | | |
| Way 3 — skip index (main query) | `exp.events_skip` | | | | |
| Way 4 — materialized view | `exp.events_daily_country` | | | | |

Mechanism evidence: `results/linux/explain_*.txt` (EXPLAIN indexes=1 shows which
table/projection/index the optimiser actually chose, and the granule counts).

## 4. Results — latency

Two regimes. **`directio`** (`SETTINGS min_bytes_to_use_direct_io=1`) forces every
read through O_DIRECT, bypassing the OS page cache, so each run does real disk
I/O — this is where absolute numbers mean something on a dataset this size.
**`hot`** is fully cached and only meaningful *relative* to other variants.

| approach | hot p50 (CV) | directio p50 (CV) | directio min–max |
|---|--:|--:|--:|
| baseline | | | |
| Way 1 | | | |
| Way 2 (narrow) | | | |
| Way 3 (main) | | | |
| Way 4 | | | |

Interleaved directio pass (round-robin, drift-controlled):
`results/linux/interleaved.csv`, summarised in `SUMMARY.md`.

`⚠︎ CV > 10%` on any row means run-to-run noise exceeds the signal for that
measurement — treat it as directional only.

## 5. Negative tests (all must hold)

| test | expectation | result |
|---|---|---|
| N1 — point lookup on `event_id` (baseline vs Way 1) | no change; not a key prefix | |
| N2 — pure time-range, no `event_type` (baseline vs Way 1) | Way 1 **worse** (time locality destroyed) | |
| Way 2 N4 — `GROUP BY event_type` | projection **not** selected (narrow base column cheaper) | |
| Way 3 main query | `set()` index on `country` **not used** — scattered | |
| Way 3 — `tenant_id = X` | `minmax` index **prunes hard** — clustered (POSITIVE) | |
| Way 3 — `country = 'c0'` (heavy) | `set()` prunes nothing — c0 in ~every granule (NEGATIVE) | |
| Way 3 — `user_id = <rare>` | `bloom_filter` prunes granules; over-read = the bloom tax | |
| Way 4 N5 — `GROUP BY product_id` | MV can't serve; projection fallback works | |

## 6. Cost ledger

| | baseline | Way 1 | Way 2 (narrow / full / lw) | Way 3 | Way 4 |
|---|--:|--:|--:|--:|--:|
| extra storage | — | | | | |
| one-time build | — | | | | |
| write-path cost | — | | | MV: _(fill)_ (1M-row insert with vs without) |
| flexibility lost | — | queries off the new key prefix regress | none (base table intact) | none | only serves `(country, day)` purchase queries |

## 7. Limitations (stated plainly)

1. **Not bare metal.** A Codespace is a shared-tenant cloud VM. Mitigations:
   `max_threads` pinned, merges stopped during measurement, query cache off,
   `directio` regime, ≥20 iterations, interleaved pass, CV reported. Absolute
   latencies are *indicative*; the read-volume metrics and the *relative*
   ordering of the approaches are solid. A dedicated instance would tighten the
   absolute latency numbers and nothing else.
2. **Working set still < RAM.** THE query touches ~_(fill)_ MB. `directio`
   removes the page-cache confound; it does not make the query I/O-*bound* the
   way a 50 GB scan would. Read-volume metrics are the honest headline.
3. **Single node, no replication, no `Nullable`, no TTL.** Scope boundary.
4. **`pow()` in the generator** shapes skew in floating point; the uniform inputs
   are integer `cityHash64`. The v1 checksum matched across Apple M3 and AMD
   EPYC, so this is stable in practice, but a fully-integer generator would
   remove even that caveat.

## 8. Verdict

_(fill after numbers: does v2 clear the bar the critical review set? Which
findings are fully resolved, which are mitigated, which remain.)_
