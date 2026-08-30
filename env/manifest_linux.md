# Environment Manifest — Linux (Codespaces / native)

Captured: 2026-08-30 06:21:08Z

## ClickHouse
- Version: **26.9.1.375**
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
0.162
0.158
0.168
```
spread 6.3% ✅

## Machine
- GitHub Codespaces, `4 cores, 16 GB RAM, 32 GB storage`
- Devcontainer: `mcr.microsoft.com/devcontainers/base:ubuntu-24.04` + sshd feature,
  ClickHouse installed natively by `.devcontainer/setup.sh`

## Notes
- Compare against `env/manifest.md` (the macOS / Docker Desktop run) and
  `docs/mac_vs_linux.md`.
- Cold-cache caveat: page cache not droppable, so `read_rows` / `read_bytes` /
  `SelectedMarks` remain the cache-independent ground truth for "work eliminated",
  exactly as on the Mac run. Hot-cache latency medians are the timing metric.
- I/O-bound operations (large INSERT...SELECT, OPTIMIZE FINAL) are markedly slower
  here than on the Mac — the Codespace disk is a loop-mounted image on Azure
  storage. Query latency (CPU/cache-bound) is comparable.
