# Environment Manifest

Captured: 2026-08-26

## ClickHouse
- Version: **26.7.5.10**
- Image: `clickhouse/clickhouse-server:latest`
- Image digest: `sha256:800e82865530eb2f1c4bc1b960e43b435fd9b2d83b4bd04a2564a5cfd88fdb6e`
- Deployment: single node, Docker container `ch_experiment`

## Container limits
- CPUs: 4 (NanoCPUs=4000000000)
- Memory: 6 GiB (6442450944 bytes) — aligned to Docker Desktop VM size (see Notes)
- nofile ulimit: 262144

## Sanity benchmark (gate: 3 runs within 10%)
- `SELECT count() FROM numbers(1000000000)` ×3: 0.165 / 0.162 / 0.161 s → spread 2.4% ✅
- query_log verified: exposes query_duration_ms, read_rows, read_bytes, memory_usage ✅

## Docker Desktop VM
- Total memory visible to VM: 8,321,798,144 bytes (~7.75 GiB)  ← **CONFLICT with 12G limit**
- CPUs visible: 8
- Docker server: Docker Desktop (macOS)

## Host
- CPU: Apple M3
- RAM: 17,179,869,184 bytes (16 GiB)
- macOS: 26.6.2 (Build 25G83)
- Disk: /dev/disk3s5, 460 Gi total, 370 Gi available at capture (APFS, SSD)

## Notes / risks
- Docker Desktop VM total memory (~7.75 GiB) was < initial container limit (12 GiB) → limit was ineffective. Resolved: container limit lowered to 6 GiB, matching real VM capacity with headroom. Real memory ceiling for ClickHouse ≈ 6 GiB.
- Fanless M3 Air → thermal throttling possible on long runs; methodology uses interleaving + medians.
- Docker Desktop adds VM I/O layer; numbers internally consistent, not absolute bare-metal claims.
