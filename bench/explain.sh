#!/usr/bin/env bash
# bench/explain.sh — capture the mechanism evidence for one query:
#   * EXPLAIN indexes = 1   (which table/projection/index, parts + granules kept)
#   * EXPLAIN ESTIMATE      (rows the optimizer expects to scan)
# Writes results/<dir>/explain_<label>.txt
#   usage: bench/explain.sh <label> <query_file>
set -euo pipefail
CH=${CH:-clickhouse client}
RESULTS_DIR=${RESULTS_DIR:-results}
LABEL=${1:?label}
QFILE=${2:?query file}
Q=$(cat "$QFILE")
mkdir -p "$RESULTS_DIR"
OUT="${RESULTS_DIR}/explain_${LABEL}.txt"

{
  echo "### $LABEL  ($QFILE)"
  echo "--- EXPLAIN indexes=1 ---"
  $CH -q "EXPLAIN indexes = 1 $Q"
  echo
  echo "--- EXPLAIN ESTIMATE ---"
  $CH -q "EXPLAIN ESTIMATE $Q"
  echo
} | tee "$OUT"
