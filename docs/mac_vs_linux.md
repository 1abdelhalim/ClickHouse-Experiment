# Mac (Docker) vs Linux (Codespaces, native) — cross-check

**Status: TEMPLATE — fill after running `bench/run_all.sh` in the Codespace.**

Purpose: show the two environments agree on the *cache-independent* metrics
(`read_rows`, `read_bytes`, `SelectedMarks` — these are a property of the schema,
not the hardware) and report how the *latency* numbers move when the fanless
laptop and the Docker VM are removed.

## Environments

| | Mac run | Linux run |
|---|---|---|
| source | `env/manifest.md` | `env/manifest_linux.md` |
| CPU | Apple M3 (fanless M3 Air) | _(fill: `model name` from manifest)_ |
| cores visible to CH | 4 (Docker limit) | _(fill: nproc)_ |
| RAM ceiling for CH | ~6 GiB (Docker VM) | _(fill)_ |
| deployment | `clickhouse/clickhouse-server:latest` in Docker | native binary, `clickhouse start` |
| ClickHouse version | 26.7.5.10 | _(fill: `SELECT version()`)_ |
| OS page cache droppable | no (Docker VM) | _(fill — expected: no)_ |

## THE query — the numbers that MUST match (cache-independent)

| metric | Mac | Linux | agree? |
|---|---|---|---|
| baseline read_rows | 8,247,393 | | |
| baseline read_bytes | 115,477,976 | | |
| way1 read_rows | 466,944 | | |
| way2 read_rows | 434,176 | | |
| way4 read_rows | 72,021 | | |
| correctness hash (all ways) | 10593978362403202577 | | |

> If these diverge by more than rounding, something differs in the dataset or the
> version's projection/index behaviour — investigate before trusting the latency
> table.

## THE query — latency (hot p50, expected to change)

| approach | Mac p50 | Linux p50 | Linux min–max |
|---|---|---|---|
| baseline | 21 ms | | |
| Way 1 ORDER BY | 9 ms | | |
| Way 2 Projection | 8 ms | | |
| Way 3 Skip index | 27 ms | | |
| Way 4 MV | 4 ms | | |

## Drift check (Linux `interleaved.csv`)

Round-robin A/B/C/D/E ×15. If baseline p50 in round 1–5 vs round 11–15 differs by
more than run-to-run noise, note it — the Codespace had a noisy neighbour or was
itself throttled.

| approach | rounds 1–5 p50 | rounds 11–15 p50 |
|---|---|---|
| baseline | | |

## One-line takeaway for the article

_(fill: e.g. "read-volume metrics reproduced exactly on Linux; hot-cache latencies
were ~Nx lower / within noise; the ranking of the four approaches was unchanged.")_
