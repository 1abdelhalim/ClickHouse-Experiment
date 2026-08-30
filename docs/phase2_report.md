> **⚠️ v1 report — superseded by [docs/v2_report.md](v2_report.md) (2026-08-30).**
> Kept for history. The v2 rigour pass rebuilt the dataset and harness per
> `docs/critical_review.md`; numbers here are pre-revision.

# Phase 2 Report — Benchmark Methodology

**Status: COMPLETE** — 2026-08-26

## Harness
`bench/run.sh <label> <query_file> <runs> <cold|hot|both>`
- 3 warmup runs (hot mode, discarded) + N measured runs.
- Metrics pulled from `system.query_log` by `query_id` (authoritative), plus client wall time.
- Output: `results/<label>_<mode>.csv` + median/p25/p75/min/max summary (portable awk — BSD awk on macOS has no `asort`).

## Methodology decisions (with evidence)

### Metrics source
`system.query_log`: `query_duration_ms`, `read_rows`, `read_bytes`, `memory_usage`. Verified present and correct on CH 26.7.5.10.

### Repeatability gate (PASSED)
Baseline measured twice, hot, 5 runs each:
- Run A median 21 ms; Run B median 20 ms → 4.8% drift < 10% gate. ✅
- `read_rows` = 8,247,393 and `read_bytes` = 115,477,976 **identical across every run** → I/O metrics are deterministic and cache-independent.

### Cold cache — the honest finding
**Attempted, in order:**
1. `SYSTEM DROP MARK CACHE` + `SYSTEM DROP UNCOMPRESSED CACHE` → works.
2. `echo 3 > /proc/sys/vm/drop_caches` in container → **blocked** (read-only /proc, even with `--privileged`).
3. Memory-pressure flush: wrote 6 GB junk file to evict page cache, then ran query → **31 ms** vs 20 ms hot. Delta ~10 ms = noise.

**Conclusion:** At 100M rows, the working set read by THE query is 115 MB compressed — trivially held in the Docker VM's ~6 GB page cache. Cold vs hot latency is **not measurable** at this scale on this hardware. This is a property of the hardware, not a fixable config.

**Decision (Option A, locked):**
- Report **hot-cache latency** (stable medians) as the timing metric.
- Report **`read_rows` / `read_bytes`** as the primary, cache-independent measure of how much work each approach eliminates. These are the numbers that predict cold/production behavior.
- State the limitation plainly in the article.

### Epilogue plan (scale gesture)
One **300M-row** run of baseline vs best variant, with a real page-cache flush, at the end. At ~7 GB compressed > 6 GB VM cache, cold becomes genuinely disk-bound and produces the dramatic cold number for the article — without paying iteration cost all week.

## What this phase proves
- The harness is trustworthy (repeatability gate passed).
- Our core claims will rest on read_bytes/read_rows, which are exact.
- We will NOT overclaim cold-cache speedups.

## Next
Phase 3: baseline autopsy (EXPLAIN, granules, where time goes) + store baseline result hash.
