#!/usr/bin/env bash
# bench/run_all.sh — full experiment pipeline, end to end, on the current host.
#
# Reproduces Phases 1-8 of the plan and writes every artifact to results/linux/
# (override with RESULTS_DIR). Designed to run unattended in a Codespace after
# .devcontainer/setup.sh has installed ClickHouse natively.
#
#   bench/run_all.sh              # full run: 100M rows, 15 measured runs per query
#   bench/run_all.sh --smoke      # 10M rows, 8 runs  -> sizing / plumbing check
#   ROWS=300000000 RUNS=20 bench/run_all.sh   # custom
#
# The reviewer's advice, baked in:
#   * native binary, not Docker (setup.sh)
#   * size by target query time -> run --smoke first, read baseline p50, decide ROWS
#   * granule-level truth: SelectedMarks/Parts/Ranges captured every run (run.sh)
#   * interleaved re-measurement pass at the end (A/B/C/A/B/C) to expose drift
#   * SYSTEM FLUSH LOGS before every query_log read (run.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

export CH=${CH:-clickhouse client}
export RESULTS_DIR=${RESULTS_DIR:-results/linux}
ROWS=${ROWS:-100000000}
RUNS=${RUNS:-15}
if [[ "${1:-}" == "--smoke" ]]; then ROWS=10000000; RUNS=8; fi

mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/run_all.log"
exec > >(tee -a "$LOG") 2>&1
echo "================================================================"
echo "run_all  ROWS=$ROWS  RUNS=$RUNS  RESULTS_DIR=$RESULTS_DIR  $(date -u)"
echo "ClickHouse: $($CH -q 'SELECT version()')"
echo "================================================================"

q()  { $CH -q "$1"; }
bench() { RUNS_ARG=${3:-$RUNS}; bench/run.sh "$1" "$2" "$RUNS_ARG" hot; }
storage() {  # $1 = table
  q "SELECT '$1' AS t,
            formatReadableSize(sum(bytes_on_disk)) AS on_disk,
            formatReadableSize(sum(data_compressed_bytes)) AS compressed,
            formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
            count() AS parts, sum(rows) AS rows
     FROM system.parts WHERE active AND database='exp' AND table='$1'"
}

# ---------------------------------------------------------------- Phase 1: data
echo; echo "### Phase 1 — schema + generate $ROWS rows"
q "DROP DATABASE IF EXISTS exp"
$CH < sql/00_schema.sql
sed "s/numbers_mt(100000000)/numbers_mt($ROWS)/" sql/01_generate.sql | $CH
q "SELECT count() FROM exp.events" | tee "$RESULTS_DIR/rowcount.txt"
# Reproducibility anchor for THIS (Linux) run. Column list is fixed here; it is a
# within-run invariant (re-run -> identical), not necessarily equal to the Mac
# anchor in docs/dataset.md if that used a different argument order.
echo "data checksum:"
q "SELECT sum(cityHash64(event_id,user_id,event_type,country,product_id,created_at,amount)) FROM exp.events" \
  | tee "$RESULTS_DIR/data_checksum.txt"
q "OPTIMIZE TABLE exp.events FINAL"
storage events | tee "$RESULTS_DIR/storage_baseline.txt"

# ---------------------------------------------------------------- Phase 3: baseline
echo; echo "### baseline — THE query"
bench/explain.sh baseline sql/queries/main_baseline.sql
bench baseline sql/queries/main_baseline.sql
echo "correctness (baseline): $(bench/correctness.sh exp.events)" | tee "$RESULTS_DIR/correctness_baseline.txt"

# ---------------------------------------------------------------- Way 1: ORDER BY
echo; echo "### Way 1 — ORDER BY (event_type, country, created_at)"
$CH < sql/10_orderby.sql
t0=$(date +%s); q "INSERT INTO exp.events_orderby SELECT * FROM exp.events"; \
  q "OPTIMIZE TABLE exp.events_orderby FINAL"; \
  echo "way1 build: $(( $(date +%s) - t0 ))s" | tee "$RESULTS_DIR/build_way1.txt"
bench/explain.sh way1 sql/queries/main_way1.sql
bench way1_orderby sql/queries/main_way1.sql
echo "correctness (way1): $(bench/correctness.sh exp.events_orderby)" | tee "$RESULTS_DIR/correctness_way1.txt"
bench n1_userid_base sql/queries/n1_userid_baseline.sql 10
bench n1_userid_ord  sql/queries/n1_userid_way1.sql     10
bench n2_timerange_base sql/queries/n2_timerange_baseline.sql 10
bench n2_timerange_ord  sql/queries/n2_timerange_way1.sql     10
storage events_orderby | tee "$RESULTS_DIR/storage_way1.txt"

# ---------------------------------------------------------------- Way 2: Projection
echo; echo "### Way 2 — Projection proj_country_day on exp.events"
t0=$(date +%s); $CH < sql/20_projection.sql; q "OPTIMIZE TABLE exp.events FINAL"; \
  echo "way2 build: $(( $(date +%s) - t0 ))s" | tee "$RESULTS_DIR/build_way2.txt"
bench/explain.sh way2 sql/queries/main_way2.sql   # inspect: is proj_country_day selected?
bench way2_projection sql/queries/main_way2.sql
echo "correctness (way2): $(bench/correctness.sh exp.events)" | tee "$RESULTS_DIR/correctness_way2.txt"
bench/explain.sh way2_n3_product sql/queries/n3_product_way2.sql
bench way2_n3_product sql/queries/n3_product_way2.sql 10
bench/explain.sh way2_n4_eventtype sql/queries/n4_eventtype_way2.sql
bench way2_n4_eventtype sql/queries/n4_eventtype_way2.sql 10
q "SELECT name, formatReadableSize(sum(data_compressed_bytes)) c, sum(rows) r
   FROM system.projection_parts WHERE active AND database='exp' AND table='events'
   GROUP BY name" | tee "$RESULTS_DIR/storage_way2_projection.txt"

# ---------------------------------------------------------------- Way 3: Skip index
echo; echo "### Way 3 — skip index (forensics first)"
$CH < sql/31_skipindex.sql
q "OPTIMIZE TABLE exp.events_skip FINAL"
echo "-- distribution forensics --" | tee "$RESULTS_DIR/way3_forensics.txt"
$CH < sql/30_distribution.sql | tee -a "$RESULTS_DIR/way3_forensics.txt"
bench/explain.sh way3_main sql/queries/main_way3.sql
bench way3_skip_main sql/queries/main_way3.sql
echo "correctness (way3): $(bench/correctness.sh exp.events_skip)" | tee "$RESULTS_DIR/correctness_way3.txt"
bench/explain.sh way3_c0   sql/queries/way3_c0.sql
bench way3_skip_c0   sql/queries/way3_c0.sql   10
bench/explain.sh way3_c198 sql/queries/way3_c198.sql
bench way3_skip_c198 sql/queries/way3_c198.sql 10
bench/explain.sh way3_userid_bloom sql/queries/way3_userid_bloom.sql
bench way3_userid_bloom sql/queries/way3_userid_bloom.sql 10
storage events_skip | tee "$RESULTS_DIR/storage_way3.txt"
q "SELECT name, formatReadableSize(sum(data_compressed_bytes)) FROM system.data_skipping_indices
   WHERE database='exp' AND table='events_skip' GROUP BY name" | tee -a "$RESULTS_DIR/storage_way3.txt"

# ---------------------------------------------------------------- Way 4: MV
echo; echo "### Way 4 — Materialized View + backfill"
$CH < sql/40_mv.sql
qid="mv_backfill_$(date +%s%N)"
$CH --query_id="$qid" -q "
  INSERT INTO exp.events_daily_country
  SELECT toDate(created_at) AS day, country, countState(), sumState(amount)
  FROM exp.events WHERE event_type='purchase' GROUP BY day, country"
q "SYSTEM FLUSH LOGS"
q "SELECT 'backfill_ms', query_duration_ms, read_rows FROM system.query_log
   WHERE type='QueryFinish' AND query_id='$qid'" | tee "$RESULTS_DIR/way4_backfill.txt"
bench/explain.sh way4_mv sql/queries/main_way4_mv.sql
bench way4_mv sql/queries/main_way4_mv.sql
echo "correctness (way4): $(bench/correctness.sh --mv)" | tee "$RESULTS_DIR/correctness_way4.txt"
bench/explain.sh way4_n5_product sql/queries/n5_product_way4.sql
bench way4_n5_product sql/queries/n5_product_way4.sql 10
storage events_daily_country | tee "$RESULTS_DIR/storage_way4.txt"

# ---------------------------------------------------------------- interleaved pass
echo; echo "### interleaved re-measurement (A/B/C/D/E round-robin, drift check)"
python3 bench/interleave.py \
  baseline=sql/queries/main_baseline.sql \
  way1=sql/queries/main_way1.sql \
  way2=sql/queries/main_way2.sql \
  way3=sql/queries/main_way3.sql \
  way4=sql/queries/main_way4_mv.sql \
  > "$RESULTS_DIR/interleaved.csv" || echo "(interleave pass skipped)"

# ---------------------------------------------------------------- summary
echo; echo "### building SUMMARY.md"
python3 bench/summarize.py "$RESULTS_DIR" > "$RESULTS_DIR/SUMMARY.md" || true
cat "$RESULTS_DIR/SUMMARY.md" 2>/dev/null || true
echo; echo "DONE. Artifacts in $RESULTS_DIR/  (log: $LOG)"
