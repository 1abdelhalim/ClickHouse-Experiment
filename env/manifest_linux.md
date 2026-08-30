# Environment Manifest — Linux (Codespaces / native)

Captured: 2026-08-30 09:57:34Z

## ClickHouse
- Version: **26.9.1.376**
- Deployment: single node, **native binary** (no Docker), started via `clickhouse start`

## Host
- CPU: AMD EPYC 7763 64-Core Processor
- Cores (nproc): **4**
- RAM: 15.62 GiB (16379756 kB)
- Disk: 12G free of 32G
- Kernel: Linux 6.8.0-1052-azure
- OS page cache droppable: **NO (read-only /proc — 'cold' = ClickHouse caches only, same limitation as the Mac run)**

## Sanity benchmark (gate: 3 runs within 10%)
```
0.199
0.174
0.195
```

## Analyzer & projection settings
```
| name | value |
|:-|:-|
| allow_experimental_analyzer | 1 |
| enable_analyzer | 1 |
| max_threads | auto(4) |
| optimize_use_implicit_projections | 1 |
| optimize_use_projections | 1 |
| use_query_cache | 0 |
```

## Notes
- Compare against `env/manifest.md` (the macOS / Docker Desktop run).
- Cold-cache caveat: if page cache is not droppable, `read_rows` / `read_bytes` /
  `SelectedMarks` remain the cache-independent ground truth for "work eliminated",
  exactly as on the Mac run. Hot-cache latency medians are the timing metric.
