# Critical Review — ClickHouse 4-Way Optimization Experiment

**Reviewer stance:** ClickHouse maintainer / performance engineer reviewing this
as if it were a benchmark submission or a piece to be published under the project's
name. Date: 2026-08-30. Scope: everything on `main` through commit `14a95fe`
(Phases 1–8 on macOS/Docker + the Linux/Codespaces validation run).

**One-line verdict:** the *methodology* passes with revisions; the *latency
numbers* do not. Lead with `read_rows` / `SelectedMarks` (correct and
reproducible), demote latency to "hot, directional, cache-bound," and re-run on a
real box at 5–10 GB before quoting milliseconds.

---

## 1. Scorecard

| Area | Grade | Summary |
|---|---|---|
| Reproducibility (generator, checksums, anchors) | **A** | Deterministic pure-function generator, no `rand()`, checksum anchor, byte-identical across two hosts. Better than most published work. |
| Experimental discipline | **A−** | Pre-registered hypotheses, mandatory negative tests, optimizer-selection verified via EXPLAIN, correctness hash on every variant. Rare rigor. |
| Metric choice | **B** | `read_rows`/`read_bytes`/`SelectedMarks` are the right primary metrics and are captured correctly. But the reports still headline latency ratios ("2.3× faster", "5.25× faster"). |
| **Dataset sizing** | **D** | 100M rows / 115 MB working set fits entirely in page cache. No disk I/O is being measured. This is the central flaw. |
| Benchmark environment | **D** | macOS + Docker Desktop VM (disqualifying) and a shared-tenant Codespace vCPU (not a benchmarking environment). No dedicated instance. |
| Measurement hygiene | **C** | 15 iterations + warmup + interleaving is good. But no `max_threads` pin, no `SYSTEM STOP MERGES`, no query-cache disable, no variance statistics. |
| Currency vs ClickHouse 26.x | **C+** | Correct on `system.query_log`, `FLUSH LOGS`, `ProfileEvents`, projection auto-selection. Misses: lightweight (`_part_offset`) projections (25.5+), codec baseline, `PREWHERE`/column-pruning acknowledgement. |
| Schema realism | **B−** | Correct types and `LowCardinality`. But default codecs only, uniform `user_id`, weaker `country` skew than designed, `created_at` uncorrelated with insertion order. |
| Per-"way" engineering | **B+** | All four mechanisms are sound and correctly demonstrated. Way 2 tests only the heavyweight projection; Way 3's forensics-first approach is exemplary. |

---

## 2. The central problem: the dataset is 50–100× too small

### The numbers

| | value |
|---|---|
| Rows | 100,000,000 |
| Table on disk (LZ4, after `OPTIMIZE FINAL`) | 1.85 GiB |
| Uncompressed | 3.17 GiB |
| **Working set for THE query** | **~115 MB compressed / 1,004 granules** |
| Host RAM (Linux run) | 15.6 GiB |
| Host RAM (Mac run, Docker VM) | ~6 GiB |

The query's entire hot path fits in RAM ~50× over. After the first warmup run,
**every measurement is CPU + memory-bandwidth only** — there is no storage I/O in
the loop. The harness itself says this (`docs/phase2_report.md`: "Cold vs hot
latency is *not measurable* at this scale on this hardware"), then the per-way
reports proceed to quote latency deltas as headline results anyway.

### Why this matters for each claim

- **"Way 1 is 2.3× faster (21 ms → 9 ms)"** — you moved 12 ms. At this timescale,
  query planning, thread-pool scheduling, the `system.query_log` insert, and
  client round-trip are a large fraction of the total. The interleaved data shows
  Way 1 at 14–25 ms and Way 2 (which reads *byte-identical* data) at 23–36 ms —
  the two are indistinguishable, and their "difference" is pure noise. A 12 ms
  delta is not a result.
- **"Way 4 MV is 5.25× faster"** — 21 ms → 4–7 ms. Same story. The MV genuinely
  reads 114× fewer rows (72,021 vs 8.2M), which is the real finding; the
  millisecond number just reflects "both are instant when cached."
- **Way 3 "slight overhead"** — the interleaved p50 is 87 ms vs baseline 24 ms, a
  63 ms gap on an identical 115 MB scan, with a 76–129 ms spread. That is not
  "slight"; it is unexplained (index-file reads? part layout? noise?) and the
  report waves it away.

### What a maintainer would want instead

Size N so the **baseline query lands at 1–3 s** (the reviewer's original advice,
not followed). At 100M the baseline is ~21 ms; you need the query to touch
~50–100× more data. Options:

1. **5–10 GB working set** — roughly 2–5 B rows at this schema, or a wider query
   (no 30-day window, more columns aggregated). Then page cache stops hiding I/O
   and `read_bytes` → latency becomes a real relationship.
2. **Force `O_DIRECT`** — `SETTINGS min_bytes_to_use_direct_io = 1` bypasses the
   OS page cache without needing `drop_caches`. This was available and never
   tried; it is the standard container-friendly way to measure cold reads.
3. **If you keep 100M** — then commit fully: the deliverable is *"what each
   optimization changes about the work the engine does"* (`SelectedMarks`,
   `read_rows`, `read_bytes`, `SelectedParts`), and latency is shown once, in a
   single caveated table, never as a per-way headline.

The `read_rows` / `SelectedMarks` reductions **are** correct, reproducible, and
genuinely useful — 8.2M → 434K → 72K rows, 1,004 → 53 → 9 marks. That is the
experiment's real output and it survived the Linux cross-check exactly.

---

## 3. Benchmark environment

Neither environment is one a maintainer would accept for quotable numbers.

| | Mac run | Linux run |
|---|---|---|
| | Apple M3 Air (fanless), Docker Desktop | GitHub Codespace, 4 vCPU of AMD EPYC 7763 |
| Disqualifier | macOS Docker = a Linux VM under virtualization.framework + virtiofs. Every I/O, and the RAM ceiling, is filtered through the VM. Also thermal throttling on sustained load. | Shared-tenant cloud vCPU. Noisy neighbours (one run spiked to 598 ms), no CPU pinning, throttled fraction of a 64-core part. Loop-mounted Azure disk (I/O-bound steps 5–8× slower). |

ClickBench and the ClickHouse team's own benchmarks require **dedicated bare-metal
or dedicated cloud instances** for exactly these reasons.

**Recommendation:** delete the Mac numbers from any published version (keep them
as "developed on / smoke-tested"), and treat the Codespace run as
"cross-check that the *analytical* results are host-independent" — which it
successfully is — not as the source of latency data. For real latency, one
afternoon on a dedicated instance (Hetzner, a dedicated EC2/GCP type, etc.).

---

## 4. Measurement hygiene — what's missing

Present and correct: `system.query_log` by `query_id`; `SYSTEM FLUSH LOGS` before
reading; `ProfileEvents['SelectedMarks'/'SelectedParts'/'SelectedRanges']`
(correctly identified as *not* top-level columns); 3 discarded warmups; 15
measured runs; an interleaved A/B/C/D/E re-measurement pass to spread
time-correlated drift across variants (good, and uncommon to see).

Missing, in rough priority order:

1. **`SETTINGS max_threads = N`** — never pinned for the benchmark queries (only
   in the forensics query). On a 4-core box, thread-scheduling variance at 20 ms
   is enormous. Pin it.
2. **`SYSTEM STOP MERGES` + wait for `system.merges` empty** before measuring.
   The 117 ms standalone-baseline anomaly (vs 24 ms interleaved) was almost
   certainly background merges from the freshly built table. Quiesce, or record
   `system.merges` alongside each run.
3. **Variance statistics.** The reports give p25/p50/p75/min/max. A maintainer
   wants coefficient of variation or MAD/median. When CV > ~10% (Way 3 here is
   ~30%), the median comparison is not trustworthy and that must be stated
   numerically, not narratively.
4. **`SET use_query_cache = 0` + `SYSTEM DROP QUERY CACHE`.** The result cache
   (24.x+) is off by default but a benchmark should disable it explicitly. The
   harness drops the mark and uncompressed caches but not this one.
5. **Pin `max_execution_time`, `max_bytes_before_external_group_by`,
   `max_block_size`** or at least dump the full non-default `SETTINGS` into the
   manifest, so another engineer reproduces the same execution.
6. **Report `ProfileEvents` for CPU** — `OSCPUVirtualTimeMicroseconds`,
   `UserTimeMicroseconds`, `SelectedRows` vs `read_rows`. At in-cache timescales
   these are more stable than wall time.

---

## 5. Currency with ClickHouse 26.x documentation & practice

**Correct / current:**

- Projections are no longer experimental; `optimize_use_projections` and
  `optimize_use_implicit_projections` default on — the report checks this.
- Verifying the optimizer *actually substitutes* the projection via
  `EXPLAIN indexes = 1` instead of assuming — this is the single most common
  mistake in projection blog posts, and it's done right here.
- `system.projections`, `system.projection_parts`,
  `system.data_skipping_indices` — correct system tables.
- Skip-index "measure clustering first" — matches current guidance that skip
  indexes only help when the indexed value's per-granule coverage is low.
- MV framed as precomputation with a mandatory manual backfill — correct, and the
  backfill trap is documented with timing.

**Behind / missing:**

1. **Lightweight projections (`_part_offset`, since 25.5; granule-level pruning
   since 25.11).** Running 26.9, the *modern* way to do "Way 2" is a projection
   that stores only the alternate sort key plus a pointer back to the base part —
   a fraction of the storage of the full-column copy tested here (+1.64 GiB, a
   100% storage increase). The experiment tests the 2023-era heavyweight
   projection only. For a 2026 write-up this should at least be measured
   alongside, or acknowledged.
2. **Codec baseline.** Schema uses default LZ4 everywhere. Current practice for a
   sort-key `DateTime` is `CODEC(Delta, LZ4)` or `(Delta, ZSTD)`; for a
   monotonic `event_id`, `Delta`. Every storage number in the reports (e.g.
   "Way 1 is 11% smaller") is a default-LZ4 artifact and would move under proper
   codecs. The "honest baseline" claim covers types but not codecs.
3. **`PREWHERE` / column pruning / `optimize_read_in_order`.** The reviewer
   flagged these as untested dimensions that beat all four "ways" in real work.
   They don't need testing, but the write-up should acknowledge they exist or it
   reads as unaware of them. (ClickHouse auto-moves the filter to PREWHERE here —
   visible in the baseline EXPLAIN — so the baseline already benefits; that
   should be noted.)
4. **`ORDER BY` primary-key granularity / `index_granularity`.** Default 8192,
   never varied. `SELECT ... SETTINGS index_granularity` or a lower-granularity
   variant is a legitimate fifth lever and a natural comparison point for the
   skip-index story.
5. **`analyze` / new analyzer.** 26.x uses the new analyzer by default. No note on
   whether `allow_experimental_analyzer` state was recorded. Plan differences
   between analyzers can change projection selection — worth capturing in the
   manifest.

---

## 6. Schema & data-generator critique

**Good:** correct types, `LowCardinality(String)` for `event_type`/`country`,
`Decimal(10,2)` for money, deterministic generation, measured-vs-designed
distribution table in `docs/dataset.md`.

**Issues:**

1. **`country` skew is weaker than designed and mislabelled.**
   `country_idx = toUInt8(199 * pow(u, 0.5))` with `u` uniform. `sqrt(u)` has
   *increasing* density → the skew is toward **high** ids (c198/c199 heaviest),
   not "low ids" as the comment says. And `sqrt` is a weak skew function: the
   heaviest country is ~1% of rows, top-10 ≈ 9.8% (design target was ~70%). The
   skip-index "negative result" is therefore partly *"we didn't manage to create
   skew"*, not *"we created skew and the index still failed."* Both framings
   support the teaching point (near-uniform column → skip index useless), but the
   report's wording overclaims the design. A real Zipf (`pow(u, k)` with large
   `k`, or an explicit rank table) would be more honest and would also give a
   genuine positive skip-index case for the heavy countries.
2. **`user_id = (n * 2654435761) % 10^7` is a bijection per 10M block → every user
   has exactly 10 events.** Real user activity is a power law. The bloom-filter
   test ("884,736 rows read to find 10 matches") and the `user_id` point lookup
   would look materially different with realistic skew (heavy users → many more
   matching rows, lighter false-positive ratio). Fine for a teaching example,
   should be stated.
3. **`created_at` is uniform over the year and uncorrelated with `n` (insertion
   order).** Real event ingestion is append-mostly (`created_at` ≈ monotonic with
   insert). Here row `n` gets a random timestamp, so within a monthly partition
   the data is effectively shuffled by time. Net effect: the baseline's
   time-locality is slightly *worse* than a real append workload, which makes the
   optimizations look slightly *better* than they would in production. Small, but
   it's a systematic bias in the optimizations' favour and should be disclosed.
4. **`event_id UInt64`** is generated, stored, indexed nowhere, and used in no
   query. 8 bytes/row of dead weight in every table and projection. Either use it
   (e.g. as the point-lookup key instead of `user_id`) or drop it.
5. **8 distinct `event_type` values, not 12.** The `multiIf` collapses 20 buckets
   into 8 labels (`page_view` gets 3 buckets, `share` gets 9, etc.). The comment
   says "12 types." Cosmetic, but a reader checking cardinality will be confused.
6. **No `Nullable`, no `DEFAULT`, no `MATERIALIZED` columns, single-shard,
   no replication.** All defensible simplifications; list them explicitly as
   scope boundaries.
7. **`pow()` in the generator returns `Float64`** and is then truncated with
   `toUInt8` / `toUInt32`. Fine and deterministic on a given ClickHouse build,
   but floating-point `pow` results *can* differ across CPU architectures /
   libm versions. The checksum matched between the M3 (Mac) and EPYC (Linux)
   runs — good, that's evidence it's stable — but a fully integer generator
   (e.g. hashing `n` and taking modulo buckets) would remove even that risk.

---

## 7. Per-"way" engineering notes

### Way 1 — ORDER BY redesign
Sound. `ORDER BY (event_type, country, created_at)` puts the 8-value
`LowCardinality` column first; generic-exclusion search prunes to 53 granules.
Storage compared *after* `OPTIMIZE FINAL` on both tables — correct methodology,
and an earlier unfair comparison (optimized vs unoptimized) was caught and fixed.
No complaints beyond §2 (the latency delta is noise; the mark-count delta is the
result).

### Way 2 — Projection
Mechanism correct and optimizer-selection verified. Two notes:
- The projection is `SELECT <all 7 columns> ORDER BY (...)` — a full second copy
  (+1.64 GiB, +100% storage). For *this query* you only need
  `event_type, country, created_at, amount`; a 4-column projection is ~40%
  smaller and serves the query identically. The report notes "it's a second copy"
  but doesn't minimise it.
- Only the heavyweight projection is tested. See §5.1 — the 25.5+ lightweight
  projection is the current answer and would change the storage verdict
  substantially.

### Way 3 — Skip index
Best-executed of the four. Forensics-first (measure per-granule country coverage
*before* building the index) is exactly right. `set(512)` on a 200-value column
seen at ~198/granule is correctly predicted useless; `c0` (24% coverage) is a
fair positive case (76% granules pruned); the `user_id` bloom filter is a fair
positive (108 vs 1,004 granules) with the over-read cost honestly stated
(884,736 rows for 10 matches). The unexplained +63 ms latency on the main query
(§2) is the only loose end.

### Way 4 — Materialized View
Correct engine (`AggregatingMergeTree`), correct combinators
(`countState`/`sumState` → `countMerge`/`sumMerge`), `TO` form, filter inside the
MV, backfill trap documented. Two notes:
- Target `ORDER BY (country, day)` but the query filters on `day` range → scans
  all countries. Irrelevant at 72K rows; would matter at scale. `ORDER BY
  (day, country)` fits this query better.
- Write-amplification is under-measured: "insert 1000 rows = 0.154 s" doesn't
  isolate the MV's contribution vs a plain insert. Measure with and without the
  MV attached.

---

## 8. What is genuinely strong

Not faint praise — these put the work above most published ClickHouse content:

- **Deterministic generator + checksum anchor.** Reproduced byte-for-byte on a
  different CPU architecture and ClickHouse version. This is rare.
- **Pre-registered hypotheses** ("recorded before testing") per way.
- **Mandatory negative tests** — and they found real regressions: the pure
  time-range query is 11–17× worse on `read_rows` under Way 1's ordering.
- **Optimizer-selection verified**, not assumed (Way 2, Way 4 fallback).
- **Correctness hash on all five variants** — all identical
  (`10593978362403202577`).
- **MV treated as a separate category** (precomputation), not lumped in with the
  transparent optimizations.
- **Cost ledgers** (storage delta, one-time build time, write path) per way.
- **Dual-environment cross-check** with an honest version-difference callout
  (26.9 prunes Way 1's table to 53 granules; 26.7 left it at 57).
- **Honest limitations sections** — the cache-bound caveat is stated, even if the
  headline numbers then ignore it.

---

## 9. Does it pass?

**As a methodology reference / teaching artifact: PASS, with the revisions in
§10.** The discipline is above the bar for published work.

**As a performance benchmark producing quotable latency numbers: FAIL.** Dataset
50–100× too small; the measured deltas are below the noise floor; neither
environment is a valid benchmarking platform; key reproducibility settings
(`max_threads`, merge quiescing, query-cache disable) are unpinned.

**As an analysis of what each optimization changes about engine work
(`read_rows` / `SelectedMarks` / `SelectedParts`): PASS.** Those results are
correct, mechanism-verified, and reproduced exactly on a second host. If the
write-up is scoped to that, it stands.

---

## 10. Required revisions before publishing

**Must fix:**

1. Re-scope the write-up around `read_rows` / `read_bytes` / `SelectedMarks` /
   `SelectedParts`. One caveated latency table total, never a per-way "N× faster"
   headline — unless you also do (2).
2. Either re-run at a 5–10 GB working set on a **dedicated instance**, or add
   `SETTINGS min_bytes_to_use_direct_io = 1` runs, so at least one latency number
   reflects real I/O.
3. Drop the macOS/Docker numbers from the published version (keep as an
   appendix / "developed on").
4. Pin `max_threads`; `SYSTEM STOP MERGES` before each measurement block; dump
   full non-default `SETTINGS` into both manifests.
5. Fix the `country` skew claim (§6.1) — either regenerate with a real Zipf, or
   change the wording to "near-uniform, weak skew" and drop "designed for 70%
   top-10."

**Should fix:**

6. Add a lightweight-projection (`_part_offset`) variant to Way 2, or a paragraph
   explaining it's the current answer and why it wasn't measured.
7. Add a codec pass (at least `Delta` on `created_at` / `event_id`) or state that
   all storage numbers are default-LZ4.
8. One paragraph acknowledging `PREWHERE` (already active in the baseline),
   column pruning, `optimize_read_in_order`.
9. Report CV / MAD per query; flag every comparison where CV > 10%.
10. Trim `event_id` or give it a job; fix the "12 event types" / "skewed toward
    low ids" comments.

**Nice to have:**

11. `index_granularity` as a fifth lever.
12. Isolate MV write-amplification (with/without MV).
13. Realistic `user_id` skew for the bloom-filter section.

---

## 11. If only one thing changes

Re-run the five main queries once on a dedicated box with a working set larger
than RAM (or `min_bytes_to_use_direct_io=1`), pinning `max_threads`. That single
run converts the entire latency story from "everything is instant when cached"
to a real bytes-read → time relationship, and it's an afternoon of work on
hardware that costs less than lunch. Everything else in this list is polish on
top of that.

---

## 12. v2 resolution (2026-08-30)

A v2 pass rebuilt the dataset and harness and re-ran on the Codespace
(`docs/v2_report.md`, `results/linux/`). Status of each item:

| # | item | v2 status |
|---|---|---|
| Must 1 | re-scope around read-volume metrics | **done** — v2_report §3 leads with SelectedMarks/read_rows; latency is §4, two regimes, CV-flagged |
| Must 2 | real I/O measurement | **mitigated** — new `directio` regime (`min_bytes_to_use_direct_io=1`) makes every run do real disk reads; still not I/O-*bound* (working set < RAM) — dedicated box still the only full fix |
| Must 3 | drop macOS/Docker numbers | **done** — v1 Mac run is history; v2 is Linux-native only, `docs/mac_vs_linux.md` relabelled as the v1 cross-check |
| Must 4 | pin max_threads / stop merges / dump SETTINGS | **done** — `bench/run.sh` pins `max_threads`, disables query cache; `run_all.sh` `SYSTEM STOP MERGES` + drains before every block; `results/linux/settings.txt` |
| Must 5 | fix the country-skew claim | **done** — generator now `pow(u,3)`; measured top-country ~17%, top-10 ~37% (was 9.8%); `docs/dataset.md` rewritten from measurement |
| Should 6 | lightweight projection | **done, negative result** — v2 measures `proj_lw` (`_part_offset`); on 26.9 it was neither smaller than the narrow projection nor auto-selected for THE query (which needs `amount`, absent from it). Reported as-is |
| Should 7 | codec baseline | **done** — schema specifies `Delta,LZ4` / `ZSTD(1)`; all storage numbers are now real-codec |
| Should 8 | acknowledge PREWHERE etc. | **done** — baseline EXPLAIN shows the filter auto-moved to PREWHERE; noted in v2_report |
| Should 9 | CV / MAD per query | **done** — `bench/run.sh` + `summarize.py` report CV, ⚠︎ flag at >10% |
| Should 10 | event_id job / comment fixes | **done** — `event_id` is now the N1 point-lookup key; 12 real event types; comments corrected |
| Nice 11 | `index_granularity` lever | **not done** — out of scope for v2 |
| Nice 12 | isolate MV write-amp | **done** — `run_all.sh` measures a 1M-row insert into a plain copy vs a copy with the MV attached |
| Nice 13 | realistic `user_id` skew | **done** — generator `pow(u,2)`; power-law, not the v1 bijection |

**Remaining gap:** the environment. A shared Codespace vCPU is not a benchmarking
platform for *absolute* latency, and the working set still fits in RAM. v2's
mitigations (directio, pinning, merge-stop, CV, interleaving) make the relative
comparisons and all read-volume numbers trustworthy; a few hours on a dedicated
instance is the only thing that would harden the absolute millisecond figures.
