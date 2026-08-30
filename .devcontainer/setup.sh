#!/usr/bin/env bash
# .devcontainer/setup.sh — install ClickHouse NATIVELY (no Docker) in the Codespace.
#
# Why native and not the docker-compose stack:
#   - The published article's headline objection is "benchmarked on a fanless
#     laptop under Docker Desktop's VM". A Codespace is a Linux container on
#     server-class hardware; running the ClickHouse binary directly removes the
#     last VM/virtiofs I/O layer so the Linux numbers are as clean as we can get
#     without renting a bare-metal box.
#   - ClickHouse's production target is Linux. macOS + Docker numbers were
#     "internally consistent, not absolute"; these are meant to be quotable.
set -euo pipefail

echo "== installing prerequisites (python3 for the summary/interleave helpers) =="
sudo apt-get update -q
sudo apt-get install -y -q python3

echo "== installing ClickHouse (native) =="
# Download into a temp dir — the installer drops a ~700MB `clickhouse` binary in
# CWD, and CWD here is the repo root. Leaving it there risks `git add -A` staging
# it (and a rejected >100MB push).
_chtmp=$(mktemp -d)
( cd "$_chtmp" && curl -fsSL https://clickhouse.com/ | sh \
  && ( sudo ./clickhouse install --noninteractive || sudo ./clickhouse install ) )
rm -rf "$_chtmp"
sudo clickhouse start

# Wait for the server to accept connections.
for i in $(seq 1 30); do
  if clickhouse client -q "SELECT 1" >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "== ClickHouse version =="
clickhouse client -q "SELECT version()"

echo "== capturing Linux environment manifest =="
bash bench/env_capture.sh > env/manifest_linux.md || true
cat env/manifest_linux.md

echo
echo "Codespace ready. Next:"
echo "  bench/run_all.sh            # full pipeline -> results/linux/"
echo "  bench/run_all.sh --smoke    # 10M-row sizing run first (recommended)"
