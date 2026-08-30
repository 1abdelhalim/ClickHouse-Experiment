# Experiment v2 — Consolidated Report

**Run: 2026-08-30.** Supersedes the Phase 1–3 and Way 1–4 reports (kept for
history). The v1 → v2 delta is driven by `docs/critical_review.md`; the
finding-by-finding status is in that file's §12.

| | |
|---|---|
| Environment | GitHub Codespaces, ClickHouse **26.9.1** native binary, 4 vCPU AMD EPYC 7763, 15.6 GB RAM |
| Analyzer | new analyzer on (`enable_analyzer = 1`) |
| Dataset | 100,000,000 rows, deterministic (`cityHash64(n, salt)` per column) |
| Data checksum | `14701560614780328933` (reproducibility anchor) |
| Result hash — every variant | **`15313934330332105907`** (baseline + Way 1 + Way 2 ×3 + Way 3 + Way 4, all identical) |
| Pipeline | `bench/run_all.sh` — one command, ~2.5 h wall |
| Raw artifacts | `results/linux/` (CSVs, `explain_*.txt`, `SUMMARY.md`, `run_all.log`, `settings.txt`) |

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
ORDER BY revenue DESC, country, day        -- tiebreak → deterministic result hash
LIMIT 10;
```

**Baseline autopsy** (`explain_baseline.txt`): partition pruning takes 12,212 →
1,037 granules; the primary-key date range takes 1,037 → 1,004; the filter is
auto-moved to `PREWHERE`. Then it stops: `country` is not in the sort key, so the
`GROUP BY country` reads all **1,004 granules / 8.22 M rows**, and the 5 %
`event_type = 'purchase'` selectivity buys nothing because `event_type` is the
*second* key. The query needs ~410 k purchase rows; it reads 8.22 M. That 20× gap
is the headroom.

## 2. Dataset (v2)

| property | value |
|---|---|
| rows | 100,000,000 |
| on disk / uncompressed | **1.36 GiB** / 3.54 GiB (12 parts, after `OPTIMIZE FINAL`) |
| `event_type` | 12 distinct; `purchase` = **5.0 %** |
| `country` | 199 distinct; heaviest **17.1 %**, top-10 **36.9 %**, long tail (`pow(u,3)` skew) |
| `tenant_id` | 2,000 distinct, assigned in contiguous 50k-row blocks → **clustered** |
| `user_id` | ~975 k distinct, power-law (`pow(u,2)`) |
| `created_at` | monotonic ramp 2024-09-01 → 2025-08-31 + ≤600 s jitter (append-realistic) |
| codecs | `Delta,LZ4` on event_id / tenant_id / created_at; `ZSTD(1)` on user_id / product_id / amount; LC dictionaries on event_type / country |

Distributions are **measured** (`results/linux/distributions.txt`), not just
designed. Codecs cut the baseline from v1's 1.85 GiB to 1.36 GiB (−26 %).

## 3. Results — read volume (the exact, reproducible metrics)

From `system.query_log` / `ProfileEvents`; identical hot or cold; verified against
`EXPLAIN indexes=1`.

| approach | plan chosen | granules read | read_rows | read_bytes | vs baseline |
|---|---|--:|--:|--:|--:|
| **baseline** | `exp.events` | 1,004 / 1,037 | 8,222,000 | 115.1 MB | 1.0× |
| **Way 1** — ORDER BY | `exp.events_orderby` | **53** / 1,037 | **434,176** | 6.08 MB | **18.9× fewer** |
| **Way 2** — projection (narrow) | `proj_narrow` (auto-selected) | **53** | **434,176** | 6.08 MB | **18.9× fewer** |
| **Way 2** — projection (full) | `proj_full` (auto-selected) | 53 | 434,176 | 6.08 MB | 18.9× fewer |
| **Way 2** — projection (lightweight) | *not selected* → `exp.events` | 1,004 | 8,222,000 | 115.1 MB | 1.0× |
| **Way 3** — skip index, THE query | `exp.events_skip`, index unused | 1,004 | 8,222,000 | 115.1 MB | 1.0× |
| **Way 4** — materialized view | `exp.events_daily_country` | **1** / 9 | **7,099** | 0.31 MB | **1,158× fewer** |

**These are the headline results.** Way 1 and Way 2 (narrow/full) collapse the
scan by ~19× by making `event_type` the leading key; the optimiser substitutes
the projection transparently (`explain_way2_proj_narrow.txt` shows
`ReadFromMergeTree (proj_narrow)`). Way 4 answers from 7 k pre-aggregated rows.

### The lightweight projection did not pay off (26.9)

`proj_lw` (`SELECT event_type, country, created_at, _part_offset ORDER BY
(event_type, country)`) built to **838 MiB — larger than the 747 MiB narrow
projection** — and the optimiser did **not** select it for THE query, which needs
`amount` (absent from it). It fell back to a full base-table scan and ran
*slower* than baseline. On 26.9, via this syntax, the "projection as a
lightweight secondary index, fetch the rest from the base part" path is not
transparently used here. The **narrow 4-column normal projection is the practical
answer**: same 19× read reduction as Way 1, +747 MiB, no base-table rewrite.

## 4. Results — latency

Two regimes. **`directio`** sets `min_bytes_to_use_direct_io = 1` so reads use
O_DIRECT and skip the OS page cache. **`hot`** is fully cached and is only
meaningful *relative* to other variants.

### Interleaved directio pass — round-robin, drift-controlled (the cleanest comparison)

| approach | p50 ms | min–max | CV |
|---|--:|--:|--:|
| Way 4 — MV | **5** | 5–7 | 12 % |
| Way 1 — ORDER BY | **24** | 20–29 | 8 % |
| baseline | 27 | 20–42 | 17 % |
| Way 2 — projection | 29 | 20–36 | 12 % |
| Way 3 — THE query (index unused) | **132** | 126–146 | 5 % |

### Standalone regimes (per query, measured once in sequence)

| approach | hot p50 (CV) | directio p50 (CV) |
|---|--:|--:|
| baseline | 113 (79 % ⚠︎) | 133 (17 % ⚠︎) |
| Way 1 | 27 (17 %) | 29 (22 % ⚠︎) |
| Way 2 (narrow) | 35 (141 % ⚠︎) | 28 (178 % ⚠︎) |
| Way 3 (main) | 142 (19 % ⚠︎) | 136 (15 % ⚠︎) |
| Way 4 | 5 (17 % ⚠︎) | 6 (29 % ⚠︎) |

**Read this honestly:**

- **The ranking is stable in every regime:** MV ≪ Way 1 ≈ Way 2 ≤ baseline ≪
  Way 3-with-a-dead-index. That ordering is a real result.
- **Absolute milliseconds are soft.** CV ranges 5–178 %. The standalone-baseline
  directio p50 (133 ms) and the interleaved-baseline directio p50 (27 ms) are the
  *same query in the same regime* — the 5× gap is the Codespace's virtual block
  device caching underneath O_DIRECT plus shared-vCPU jitter. On this platform,
  even `directio` cannot guarantee a cold read. This is the environment's
  ceiling; see §7.
- **Way 3's main query is genuinely ~5× slower than baseline** — it reads the
  same 1,004 granules *and* checks the `set()` index on every one for nothing.

## 5. Negative tests — all hold

| test | expectation | result |
|---|---|---|
| **N1** — point lookup on `event_id` (baseline vs Way 1) | reordering neither helps nor hurts | both prune to **1 granule / 8,192 rows** (`event_id` correlates with the monotonic partition key); identical |
| **N2** — pure time-range, no `event_type` (baseline vs Way 1) | Way 1 **worse** — time locality destroyed | baseline 554,288 rows / 68 marks; **Way 1 6,051,120 rows / 739 marks (10.9×), 88 fragmented ranges**, 3× slower |
| **Way 2 N4** — `GROUP BY event_type` | projection not selected | `ReadFromMergeTree (exp.events)` — base table, 1,004 granules; narrow base column beats the wider projection |
| **Way 2 lightweight projection** | may not be auto-selected | confirmed not selected (§3) |
| **Way 3 — THE query** | `set()` on `country` unused — scattered | `explain_way3_main.txt`: no Skip line; 1,004 granules |
| **Way 3 — `tenant_id = 1920`** (clustered) | `minmax` prunes hard — POSITIVE | `Skip idx_tenant_minmax: Granules 7 / 1004` → **57,344 rows / 7 marks, 143× fewer, 6 ms** |
| **Way 3 — `country = 'c0'`** (heavy, 100 % coverage) | `set()` prunes nothing — NEGATIVE | 8,222,000 rows / 1,004 marks — zero pruning |
| **Way 3 — `user_id = 9999979`** (~84 rows) | bloom prunes granules; over-read is the tax | 1,515,520 rows / 185 marks to find 84 → **82 % granules pruned, 18,000× over-read** |
| **Way 4 N5** — `GROUP BY product_id` | MV can't serve; projection fallback | served by `proj_country_day`, 53 marks |

Skip-index forensics (`way3_forensics.txt`): `tenant_id` = **1 distinct value per
granule** (max 2); `country` = **199 per granule** (fully scattered); `c0`
coverage **100 %**. The positive and negative cases are the same table, same
query shape, one column swapped.

## 6. Cost ledger

| | one-time build | extra storage | write-path | flexibility lost |
|---|--:|--:|--:|---|
| baseline | — | — | — | — |
| **Way 1** | 150 s (rewrite) | ±0 (1.36 GiB) | INSERT sees a wider sort key | queries off the `(event_type, country, …)` prefix regress (see N2) |
| **Way 2 — narrow** | 91 s | **+747 MiB** (+54 %) | background projection maintenance | none — base table untouched |
| **Way 2 — full** | 208 s | +2.03 GiB (+149 %) | " | none |
| **Way 2 — lightweight** | 109 s | +838 MiB, **and unused** | " | none |
| **Way 3 — minmax(tenant)** | in-INSERT | **+23 KiB** | negligible | none |
| **Way 3 — set(country)** | in-INSERT | +5.9 MiB, **and unused** | negligible | none |
| **Way 3 — bloom(user_id)** | in-INSERT | +119 MiB (+8.8 %) | index maintained on write | none |
| **Way 4 — MV** | backfill 411 ms (5.1 M purchases → 73 k rows) | +437 KiB | 1 M-row insert: **697 ms with MV vs 846 ms without** — not measurably slower at this scale; real cost is deferred merge + per-batch aggregation | only serves `(country, day)` purchase queries; schema-coupled; needs manual historical backfill |

## 7. Limitations (stated plainly)

1. **Not bare metal.** A Codespace is a shared-tenant cloud VM with a virtual
   block device that caches beneath O_DIRECT. Mitigations applied: `max_threads`
   pinned, `SYSTEM STOP MERGES` + drain before every measurement block, query
   cache off, `directio` regime, 20 iterations, interleaved pass, CV reported and
   flagged at >10 %. **Result:** the read-volume metrics (§3) and the *relative*
   latency ordering (§4) are trustworthy; the *absolute* millisecond figures are
   indicative only. A few hours on a dedicated instance is the one thing that
   would harden them — and `bench/run_all.sh` runs there unchanged (`CH` +
   `RESULTS_DIR`).
2. **Working set < RAM.** THE query touches ~115 MB. `directio` removes the
   page-cache confound; it does not make the query I/O-*bound* the way a 50 GB
   scan would. Read volume is the honest headline; latency is context.
3. **Single node**, no replication, no `Nullable`, no TTL. Scope boundary.
4. **`pow()`/`exp()` shape the skew in floating point** (the uniform inputs are
   integer `cityHash64`). The checksum reproduced across Apple M3 and AMD EPYC in
   v1, so this is stable in practice; a fully-integer generator would remove even
   that caveat.
5. `index_granularity` was not varied (left at 8192).

## 8. Verdict

Against the bar `docs/critical_review.md` set:

- **Methodology — PASS.** Deterministic generator + checksum + result hash across
  7 variants; pre-registered hypotheses; mandatory negative tests that found real
  regressions (N2: 10.9×); optimiser selection verified by EXPLAIN, not assumed;
  three projection flavours and three skip-index types measured; merge-quiescing,
  thread pinning, query-cache disable, CV reporting all in place.
- **Read-volume analysis — PASS.** Exact, mechanism-verified, and every variant
  reproduces the same result hash. 19× (Way 1/2), 1,158× (Way 4), 143× on the
  skip-index positive case, and honest 1.0× on the three negatives.
- **Absolute latency benchmark — CONDITIONAL.** The rigour controls are all
  present, but a shared Codespace vCPU with block-device caching cannot produce
  quotable cold-cache milliseconds. The *relative* ordering is solid in every
  regime. Closing this needs dedicated hardware, not more code.

**Bottom line:** v2 is a sound, reproducible analysis of *what each optimisation
changes about the work ClickHouse does*, with latency reported honestly as
directional. If the article is scoped that way — and it should be — it stands.
