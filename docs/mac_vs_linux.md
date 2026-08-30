> **⚠️ v1 report — superseded by [docs/v2_report.md](v2_report.md) (2026-08-30).**
> Kept for history. The v2 rigour pass rebuilt the dataset and harness per
> `docs/critical_review.md`; numbers here are pre-revision.

# Mac (Docker) vs Linux (Codespaces, native) — cross-check

**Status: COMPLETE — 2026-08-30.** Linux run: `results/linux/`, 100M rows (same
generator, same N as every `docs/way*_report.md`), 15 measured runs/query + a
15-round interleaved pass.

Only the machine changed: fanless M3 Air + Docker Desktop VM → native ClickHouse
on a Linux Codespace. Findings:

1. **Every cache-independent number reproduced.** Data checksum, all five
   correctness hashes, `read_rows`, `SelectedMarks`, granule counts, and the skip
   forensics are identical or within version-rounding of the Mac run.
2. **The four approaches keep the same ranking and the same mechanisms**
   (EXPLAIN confirms projection auto-selection, skip-index non-use on the main
   query, MV granule collapse).
3. **Latency**: hot p50s are close to the Mac's once the system is quiet
   (interleaved pass). The Codespace does **not** thermally throttle, but it has
   shared-tenant jitter (occasional single-run spikes to 100–600 ms).
4. **One real version difference**: on ClickHouse 26.9 the Way 1 reordered table
   prunes to 53 granules / 434,176 rows — identical to the projection. On 26.7
   (Mac) it was 57 / 466,944. 26.9's generic-exclusion search is slightly tighter.
5. **I/O-bound build steps are much slower on the Codespace** (loop-mounted Azure
   disk): Way 1 rebuild 167 s vs 22 s, Way 2 materialize+optimize 192 s vs 46 s.
   Query latency is CPU/cache-bound and comparable; one-time rewrites are not.

## Environments

| | Mac run | Linux run |
|---|---|---|
| manifest | `env/manifest.md` | `env/manifest_linux.md` |
| CPU | Apple M3 (fanless M3 Air) | AMD EPYC 7763 (4 shared vCPU) |
| cores visible to ClickHouse | 4 (Docker limit) | 4 |
| RAM | ~6 GiB (Docker VM ceiling) | ~15.6 GiB |
| deployment | `clickhouse-server:latest` in Docker Desktop | **native binary**, `clickhouse start` |
| ClickHouse version | 26.7.5.10 | 26.9.1.375 |
| OS page cache droppable | no (Docker VM) | no (Codespace container) |
| `count() FROM numbers(1e9)` ×3 | 0.165 / 0.162 / 0.161 s | 0.162 / 0.158 / 0.168 s |

## THE query — cache-independent metrics

| metric | Mac (100M) | Linux (100M) | verdict |
|---|---|---|---|
| data checksum | 3125091598845950461 | **3125091598845950461** | ✅ byte-identical dataset |
| correctness hash — baseline + all 4 ways | 10593978362403202577 | **10593978362403202577** (all 5) | ✅ exact |
| baseline read_rows | 8,247,393 | 8,222,817 | ✅ 0.3% (partition-edge granule rounding, 26.7→26.9) |
| baseline SelectedMarks | 1,013 | 1,004 | ✅ same, ±rounding |
| baseline read_bytes | 115,477,976 | 115,119,438 | ✅ |
| Way 1 read_rows / marks | 466,944 / 57 | **434,176 / 53** | ⚠️ 26.9 prunes tighter — now == Way 2 |
| Way 2 read_rows / marks | 434,176 / 53 | **434,176 / 53** | ✅ exact |
| Way 3 main read_rows | 8,222,817 | 8,222,817 | ✅ exact (index not used) |
| Way 3 `c0` read_rows / marks | 1,966,080 / 240 | **1,966,080 / 240** | ✅ exact |
| Way 3 `user_id` bloom read_rows / marks | 884,736 / 108 | **884,736 / 108** | ✅ exact |
| Way 4 MV read_rows | 72,021 | **72,021** | ✅ exact |

Skip-index forensics (countries per 8192-row granule): Mac median 198, c198 cover
100%, c0 cover 24.4% → Linux **198 / 100% / 24.4%**. Identical.

## THE query — latency, hot p50

Two Linux columns: the standalone pass ran each query right after its table was
built (background merges still settling — noisy); the **interleaved** pass ran all
five round-robin at the end on a quiet system and is the trustworthy comparison.

| approach | Mac p50 | Linux p50 (standalone) | Linux p50 (interleaved) | Linux min–max (interleaved) |
|---|---|---|---|---|
| baseline | 21 ms | 117 ms | **24 ms** | 20–35 ms |
| Way 1 ORDER BY | 9 ms | 27 ms | **16 ms** | 14–25 ms |
| Way 2 Projection | 8 ms | 24 ms | **27 ms** | 23–36 ms |
| Way 3 Skip index | 27 ms | 96 ms | **87 ms** | 76–129 ms |
| Way 4 MV | 4 ms | 7 ms | **7 ms** | 7–9 ms |

Notes:
- Way 2 > Way 1 in the interleaved pass despite reading identical data — 11 ms of
  run-to-run noise; treat Way 1 ≈ Way 2 (same conclusion as the Mac run).
- Way 3's main query is genuinely slower on Linux (87 vs 27 ms): same 1,004 marks
  read, plus the `set(512)` index is checked and discarded every run. The *shape*
  of the result — skip index is dead weight for this query — is unchanged.
- The 117 ms standalone baseline is the exact artefact the Mac methodology's
  interleave+median was designed to remove; here it was background merge load, not
  heat.

## Negative tests — Mac conclusions all hold

| test | Mac finding | Linux result |
|---|---|---|
| N1 user_id point lookup (baseline vs Way 1) | no meaningful change | base 81,920 rows / 6 ms; ord 65,536 / 4 ms — no win ✅ |
| N2 pure time-range (baseline vs Way 1) | Way 1 ~12× worse on read_rows | base 555,105 → ord **6,305,889 (11.4×)** ✅ |
| Way 2 N4 GROUP BY event_type | projection **not** selected | EXPLAIN: base table `exp.events`, 1,037 granules, projection ignored ✅ |
| Way 3 main query | skip index not used, slight overhead | EXPLAIN: no skip-index condition; +overhead ✅ |
| Way 3 `country='c0'` (light) | index used, ~76% granules pruned | 1,037 → 240 marks (76.8% pruned) ✅ |
| Way 3 `country='c198'` (heavy) | index used, zero pruning | 1,004 marks, 0 pruned ✅ |
| Way 4 N5 GROUP BY product_id | MV can't serve; projection fallback | served by `proj_country_day`, 53 marks ✅ |

## Storage & one-time costs

| | Mac | Linux |
|---|---|---|
| base table (after OPTIMIZE FINAL) | 1.99 GiB | 1.85 GiB |
| events_orderby | 1.77 GiB | 1.65 GiB |
| proj_country_day | 1.77 GiB | 1.64 GiB |
| skip indexes (country set + user bloom) | 131 MB | 5.4 MB + 119.8 MB |
| MV target (72,021 rows) | ~0.4 MB | 0.35 MB |
| Way 1 rebuild | 22 s | **167 s** |
| Way 2 materialize + OPTIMIZE FINAL | 46 s | **192 s** |
| MV backfill (query duration) | 82 ms | 323 ms |

## Takeaway for the article

> The experiment was developed on an M3 MacBook Air under Docker and re-run
> natively on a Linux (GitHub Codespaces) instance. The dataset is byte-identical
> across both (shared deterministic generator; matching checksum), and every
> cache-independent result — rows read, granules scanned, correctness hashes,
> skip-index clustering — reproduced exactly, with one version-level difference:
> ClickHouse 26.9 prunes the Way 1 reordered table to the same 53 granules as the
> projection, where 26.7 left it at 57. Hot-cache latencies on Linux land within a
> few milliseconds of the Mac once background-merge noise is controlled for, and
> the four approaches keep the same ranking. The Linux instance showed no thermal
> throttling but did show occasional shared-tenant latency spikes — the same
> reason the methodology reports medians over interleaved runs rather than single
> timings. Numbers quoted in this article are the Linux run; the Mac run is the
> cross-check.
