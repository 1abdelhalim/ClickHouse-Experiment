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
*slower* than baseline. On 26.9, via this 25.5-era `_part_offset` syntax, the
"projection as a lightweight secondary index, fetch the rest from the base part"
path is not transparently used here. That is **not** a claim that lightweight
projections do not work in general: ClickHouse 25.6/25.11 granule-level pruning
and the 26.1 `PROJECTION … INDEX … TYPE basic` syntax are a follow-up, not
measured in this run. The **narrow 4-column normal projection is the practical
answer for this aggregate**: same 19× read reduction as Way 1, +747 MiB, no
base-table rewrite.

## 4. Results — latency

Two regimes. **`directio`** sets `min_bytes_to_use_direct_io = 1` so reads use
O_DIRECT and skip the OS page cache. **`hot`** is fully cached and is only
meaningful *relative* to other variants.

**Do not quote the v2 interleaved table as a fair ranking.** After Way 2
negatives, `proj_country_day` was left on `exp.events`. `results/linux/interleaved.csv`
shows the "baseline" reading **434,176 rows / 53 marks** — the projection — while
the standalone baseline correctly reads 8.22 M / 1,004. The 133 ms (standalone)
vs 27 ms (interleaved) gap is therefore mostly a leftover projection, not
Codespace noise. The harness now drops that projection before Way 3/4 and
interleave; a future run will produce a fair interleaved pass. Until then,
standalone read-volume (§3) is the source of truth, and standalone latency below
is directional only.

### Standalone regimes (per query, measured once in sequence)

| approach | hot p50 (CV) | directio p50 (CV) |
|---|--:|--:|
| baseline | 113 (79 % ⚠︎) | 133 (17 % ⚠︎) |
| Way 1 | 27 (17 %) | 29 (22 % ⚠︎) |
| Way 2 (narrow) | 35 (141 % ⚠︎) | 28 (178 % ⚠︎) |
| Way 3 (main) | 142 (19 % ⚠︎) | 136 (15 % ⚠︎) |
| Way 4 | 5 (17 % ⚠︎) | 6 (29 % ⚠︎) |

**Read this honestly:**

- **Read-volume ranking is exact** (see §3): MV ≪ Way 1 = Way 2 narrow/full ≪
  baseline = Way 3-on-THE-query. Latency ordering is consistent with that, but
  CVs of 17–178 % mean millisecond deltas are not a result.
- **Absolute milliseconds are soft.** A shared Codespace vCPU with a virtual
  block device that caches under O_DIRECT cannot produce quotable cold-cache
  numbers. See §7.
- **Way 3's main query is genuinely slower than baseline** on this box — it
  reads the same 1,004 granules *and* checks the `set()` index on every one for
  nothing. Treat the ~5× wall-time gap as directional; the unused-index tax is
  the mechanism.

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
| **Way 4 N5** — `GROUP BY product_id` | MV can't serve; fall back to the raw table | `ReadFromMergeTree (exp.events)`, **1,004 granules / 8.22 M rows** — same in-range scan as baseline. (`explain_way4_n5_product.txt`; SUMMARY `way4_n5_product`) |

Skip-index forensics (`way3_forensics.txt`): `tenant_id` = **1 distinct value per
granule** (max 2); `country` = **199 per granule** (fully scattered); `c0`
coverage **100 %**. The positive and negative cases are the same table, same
query shape, one column swapped.

> Provenance note: the `way3_country_heavy` probe was run in a separate targeted
> pass (its query file was briefly missing during the main run); it used the same
> harness, table, and `SYSTEM STOP MERGES`. Every other number here is from the
> single `run_all.sh` invocation logged in `results/linux/run_all.log`.
>
> **Correction (2026-09-19):** N5 was previously written as "served by
> `proj_country_day`, 53 marks." The artifacts show the base table at 1,004
> granules. The leftover `proj_country_day` on `exp.events` *did* serve the
> interleaved "baseline" (53 marks); it did not serve N5.

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
   cache off, `directio` regime, 20 iterations, CV reported and flagged at >10 %.
   **Result:** the read-volume metrics (§3) are trustworthy; the *absolute*
   millisecond figures are indicative only. A few hours on a dedicated instance
   is the one thing that would harden them — and `bench/run_all.sh` runs there
   unchanged (`CH` + `RESULTS_DIR`).
2. **Working set < RAM.** THE query touches ~115 MB. `directio` removes the
   page-cache confound; it does not make the query I/O-*bound* the way a 50 GB
   scan would. Read volume is the honest headline; latency is context.
3. **v2 interleaved pass is not a fair baseline.** `proj_country_day` remained
   attached; see §4. Fixed in the harness after this run.
4. **Single node**, no replication, no `Nullable`, no TTL. Scope boundary.
5. **`pow()`/`exp()` shape the skew in floating point** (the uniform inputs are
   integer `cityHash64`). The checksum reproduced across Apple M3 and AMD EPYC in
   v1, so this is stable in practice; a fully-integer generator would remove even
   that caveat.
6. `index_granularity` was not varied (left at 8192).
7. Lightweight projections were measured with `_part_offset` syntax, not the
   26.1 `INDEX … TYPE basic` form.

## 8. Verdict

Against the bar `docs/critical_review.md` set:

- **Methodology — PASS, with one post-run correction.** Deterministic generator +
  checksum + result hash across 7 variants; pre-registered hypotheses; mandatory
  negative tests that found real regressions (N2: 10.9×); optimiser selection
  verified by EXPLAIN, not assumed; three projection flavours and three
  skip-index types measured; merge-quiescing, thread pinning, query-cache
  disable, CV reporting all in place. The v2 interleaved pass is **not** a fair
  baseline comparison (leftover projection); that is corrected in the harness
  and must not be published as latency ranking.
- **Read-volume analysis — PASS.** Exact, mechanism-verified, and every variant
  reproduces the same result hash. 19× (Way 1/2), 1,158× (Way 4), 143× on the
  skip-index positive case, and honest 1.0× on the three negatives. Standalone
  artifacts, not `interleaved.csv`, are the source of truth.
- **Absolute latency benchmark — CONDITIONAL.** The rigour controls are all
  present, but a shared Codespace vCPU with block-device caching cannot produce
  quotable cold-cache milliseconds. Closing this needs dedicated hardware, not
  more code.

**Bottom line:** v2 is a sound, reproducible analysis of *what each optimisation
changes about the work ClickHouse does*, with latency reported honestly as
directional. If the article is scoped that way — and it should be — it stands.
The draft is `docs/article.md`.
