#!/usr/bin/env bash
# bench/env_capture.sh — print a Markdown environment manifest for the current host.
# Used by the devcontainer setup to write env/manifest_linux.md, and can be run
# by hand any time to re-capture.
set -euo pipefail
CH=${CH:-clickhouse client}

date_utc=$(date -u +"%Y-%m-%d %H:%M:%SZ")
ch_version=$($CH -q "SELECT version()" 2>/dev/null || echo "unknown")
cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/.*: //' || echo "unknown")
nproc_val=$(nproc 2>/dev/null || echo "?")
mem_total=$(awk '/MemTotal/{printf "%.2f GiB (%d kB)", $2/1048576, $2}' /proc/meminfo 2>/dev/null || echo "unknown")
disk_avail=$(df -h . | awk 'NR==2{print $4" free of "$2}')
kernel=$(uname -sr)

# Can we actually drop the OS page cache here? (Codespaces: almost certainly not.)
if [ -w /proc/sys/vm/drop_caches ]; then droppable="YES (page cache is droppable — true cold runs possible)"; else droppable="NO (read-only /proc — 'cold' = ClickHouse caches only, same limitation as the Mac run)"; fi

cat <<EOF
# Environment Manifest — Linux (Codespaces / native)

Captured: $date_utc

## ClickHouse
- Version: **$ch_version**
- Deployment: single node, **native binary** (no Docker), started via \`clickhouse start\`

## Host
- CPU: $cpu_model
- Cores (nproc): **$nproc_val**
- RAM: $mem_total
- Disk: $disk_avail
- Kernel: $kernel
- OS page cache droppable: **$droppable**

## Sanity benchmark (gate: 3 runs within 10%)
EOF

echo '```'
for i in 1 2 3; do
  $CH -q "SELECT count() FROM numbers(1000000000)" --time 2>&1 | tail -1
done
echo '```'

echo
echo "## Analyzer & projection settings"
echo '```'
$CH -q "SELECT name, value FROM system.settings
        WHERE name IN ('enable_analyzer','allow_experimental_analyzer',
                       'optimize_use_projections','optimize_use_implicit_projections',
                       'use_query_cache','max_threads') ORDER BY name" 2>/dev/null || true
echo '```'

cat <<'EOF'

## Notes
- Compare against `env/manifest.md` (the macOS / Docker Desktop run).
- Cold-cache caveat: if page cache is not droppable, `read_rows` / `read_bytes` /
  `SelectedMarks` remain the cache-independent ground truth for "work eliminated",
  exactly as on the Mac run. Hot-cache latency medians are the timing metric.
EOF
