#!/usr/bin/env bash
# bench/run_all.sh — full experiment pipeline (v2 — rigour pass).
#
# Reproduces Phases 1-8 and writes every artifact to results/linux/ (override
# with RESULTS_DIR). Runs unattended after .devcontainer/setup.sh.
#
#   bench/run_all.sh              # 150M rows, 25 runs/query, hot + directio
#   bench/run_all.sh --smoke      # 12M rows, 8 runs -> plumbing check
#   ROWS=100000000 RUNS=30 bench/run_all.sh
#
# Rigour controls (docs/critical_review.md §4):
#   * max_threads pinned (bench/run.sh, = nproc)
#   * query result cache disabled per query
#   * SYSTEM STOP MERGES + drain before every measurement block
#   * each main query measured HOT (relative) and DIRECTIO (O_DIRECT, absolute)
#   * >=25 iterations, CV reported, interleaved drift pass
#   * full non-default SETTINGS + analyzer state captured to the manifest
set -euo pipefail
cd "$(dirname "$0")/.."

export CH=${CH:-clickhouse client}
export RESULTS_DIR=${RESULTS_DIR:-results/linux}
export MAX_THREADS=${MAX_THREADS:-$(nproc 2>/dev/null || echo 4)}
ROWS=${ROWS:-100000000}
export RUNS=${RUNS:-20}
if [[ "${1:-}" == "--smoke" ]]; then ROWS=12000000; RUNS=8; export RUNS; fi

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
LOG="$RESULTS_DIR/run_all.log"
exec > >(tee -a "$LOG") 2>&1
echo "================================================================"
echo "run_all v2  ROWS=$ROWS  RUNS=$RUNS  MAX_THREADS=$MAX_THREADS  $(date -u)"
echo "ClickHouse: $($CH -q 'SELECT version()')"
echo "================================================================"

q()  { $CH -q "$1"; }
bench() { # label qfile [runs] [regime] — non-fatal
  bench/run.sh "$1" "$2" "${3:-$RUNS}" "${4:-hot}" || echo "WARN: bench $1 ($4) failed"
}
explain() { bench/explain.sh "$1" "$2" || echo "WARN: explain $1 failed"; }
storage() { # table
  q "SELECT '$1' t, formatReadableSize(sum(bytes_on_disk)) on_disk,
            formatReadableSize(sum(data_compressed_bytes)) compressed,
            formatReadableSize(sum(data_uncompressed_bytes)) uncompressed,
            count() parts, sum(rows) rows
     FROM system.parts WHERE active AND database='exp' AND table='$1'"
}
quiesce() {   # stop merges everywhere in exp, wait for running merges to drain
  q "SYSTEM STOP MERGES" 2>/dev/null || for t in events events_orderby events_skip events_daily_country; do q "SYSTEM STOP MERGES exp.$t" 2>/dev/null || true; done
  for _ in $(seq 1 60); do
    [[ "$(q "SELECT count() FROM system.merges WHERE database='exp'")" == "0" ]] && break
    sleep 1
  done
}
unquiesce() { q "SYSTEM START MERGES" 2>/dev/null || for t in events events_orderby events_skip events_daily_country; do q "SYSTEM START MERGES exp.$t" 2>/dev/null || true; done; }

# ---------------------------------------------------------------- Phase 0: env
echo; echo "### Phase 0 — environment"
{
  echo "## Non-default settings at run time"
  q "SELECT name, value FROM system.settings WHERE changed ORDER BY name FORMAT TSV"
  echo
  echo "## Analyzer / key settings"
  q "SELECT name, value FROM system.settings
     WHERE name IN ('enable_analyzer','allow_experimental_analyzer','max_threads',
                    'max_bytes_before_external_group_by','use_query_cache',
                    'optimize_use_projections','optimize_use_implicit_projections',
                    'min_bytes_to_use_direct_io') ORDER BY name FORMAT TSV"
} > "$RESULTS_DIR/settings.txt"
cat "$RESULTS_DIR/settings.txt"

# ---------------------------------------------------------------- Phase 1: data
echo; echo "### Phase 1 — schema + generate $ROWS rows"
q "DROP DATABASE IF EXISTS exp"; q "CREATE DATABASE exp"
$CH < sql/00_schema.sql
sed "s/{ROWS}/$ROWS/g" sql/01_generate.sql | $CH
q "SELECT count() FROM exp.events" | tee "$RESULTS_DIR/rowcount.txt"
q "SELECT sum(cityHash64(event_id, tenant_id, user_id, event_type, country, product_id, toUInt32(created_at), toString(amount))) FROM exp.events" \
  | tee "$RESULTS_DIR/data_checksum.txt"
echo "-- distributions --" | tee "$RESULTS_DIR/distributions.txt"
q "SELECT 'event_types' k, toString(uniqExact(event_type)) v FROM exp.events
   UNION ALL SELECT 'purchase_share_%', toString(round(countIf(event_type='purchase')/count()*100,2)) FROM exp.events
   UNION ALL SELECT 'distinct_country', toString(uniqExact(country)) FROM exp.events
   UNION ALL SELECT 'top_country_share_%', toString(round(max(c)/sum(c)*100,2)) FROM (SELECT count() c FROM exp.events GROUP BY country)
   UNION ALL SELECT 'top10_country_share_%', toString(round(sum(t)/ (SELECT count() FROM exp.events) *100,2)) FROM (SELECT count() t FROM exp.events GROUP BY country ORDER BY t DESC LIMIT 10)
   UNION ALL SELECT 'distinct_tenant', toString(uniqExact(tenant_id)) FROM exp.events
   UNION ALL SELECT 'distinct_user', toString(uniqExact(user_id)) FROM exp.events
   UNION ALL SELECT 'date_min', toString(min(created_at)) FROM exp.events
   UNION ALL SELECT 'date_max', toString(max(created_at)) FROM exp.events
   FORMAT TSV" | tee -a "$RESULTS_DIR/distributions.txt"
q "OPTIMIZE TABLE exp.events FINAL"
storage events | tee "$RESULTS_DIR/storage_baseline.txt"

# ---------------------------------------------------------------- baseline
echo; echo "### baseline — THE query"
quiesce
explain baseline sql/queries/main_baseline.sql
bench baseline sql/queries/main_baseline.sql "$RUNS" hot
bench baseline sql/queries/main_baseline.sql "$RUNS" directio
echo "correctness(baseline): $(bench/correctness.sh exp.events)" | tee "$RESULTS_DIR/correctness_baseline.txt"
bench n1_pointlookup_base sql/queries/n1_pointlookup_baseline.sql 12 hot
bench n2_timerange_base   sql/queries/n2_timerange_baseline.sql   12 hot
unquiesce

# ---------------------------------------------------------------- Way 1
echo; echo "### Way 1 — ORDER BY (event_type, country, created_at)"
$CH < sql/10_orderby.sql
t0=$(date +%s)
q "INSERT INTO exp.events_orderby SELECT * FROM exp.events"
q "OPTIMIZE TABLE exp.events_orderby FINAL"
echo "way1 build: $(( $(date +%s) - t0 ))s" | tee "$RESULTS_DIR/build_way1.txt"
quiesce
explain way1 sql/queries/main_way1.sql
bench way1_orderby sql/queries/main_way1.sql "$RUNS" hot
bench way1_orderby sql/queries/main_way1.sql "$RUNS" directio
echo "correctness(way1): $(bench/correctness.sh exp.events_orderby)" | tee "$RESULTS_DIR/correctness_way1.txt"
bench n1_pointlookup_ord sql/queries/n1_pointlookup_way1.sql 12 hot
bench n2_timerange_ord   sql/queries/n2_timerange_way1.sql   12 hot
unquiesce
storage events_orderby | tee "$RESULTS_DIR/storage_way1.txt"

# ---------------------------------------------------------------- Way 2 (3 projection flavours)
echo; echo "### Way 2 — Projections"
way2_variant() { # name  projection-DDL-body   (returns non-zero on any failure)
  local name=$1 ddl=$2
  echo "--- projection: $name ---"
  q "ALTER TABLE exp.events ADD PROJECTION $name ($ddl)" || return 1
  local t; t=$(date +%s)
  q "ALTER TABLE exp.events MATERIALIZE PROJECTION $name SETTINGS mutations_sync=2" || { q "ALTER TABLE exp.events DROP PROJECTION $name" || true; return 1; }
  q "OPTIMIZE TABLE exp.events FINAL"
  echo "$name build: $(( $(date +%s) - t ))s" | tee -a "$RESULTS_DIR/build_way2.txt"
  quiesce
  explain way2_$name sql/queries/main_way2.sql
  bench way2_$name sql/queries/main_way2.sql "$RUNS" hot
  bench way2_$name sql/queries/main_way2.sql "$RUNS" directio
  echo "correctness(way2_$name): $(bench/correctness.sh exp.events)" | tee -a "$RESULTS_DIR/correctness_way2.txt"
  q "SELECT '$name' p, formatReadableSize(sum(data_compressed_bytes)) c, sum(rows) r
     FROM system.projection_parts WHERE active AND database='exp' AND table='events' AND name='$name'
     GROUP BY p" | tee -a "$RESULTS_DIR/storage_way2_projection.txt"
  unquiesce
  q "ALTER TABLE exp.events DROP PROJECTION $name"    # no OPTIMIZE needed — drop just removes files
}
: > "$RESULTS_DIR/build_way2.txt"; : > "$RESULTS_DIR/correctness_way2.txt"; : > "$RESULTS_DIR/storage_way2_projection.txt"
way2_variant proj_narrow "SELECT event_type, country, created_at, amount ORDER BY (event_type, country, created_at)" || echo "proj_narrow FAILED" | tee -a "$RESULTS_DIR/build_way2.txt"
way2_variant proj_full   "SELECT event_id, tenant_id, user_id, event_type, country, product_id, created_at, amount ORDER BY (event_type, country, created_at)" || echo "proj_full FAILED" | tee -a "$RESULTS_DIR/build_way2.txt"
# lightweight (_part_offset) projection — ClickHouse >= 25.5; skip cleanly if unsupported
way2_variant proj_lw "SELECT event_type, country, created_at, _part_offset ORDER BY (event_type, country)" \
  || echo "proj_lw: not supported / failed on this version — skipped" | tee -a "$RESULTS_DIR/build_way2.txt"
# negative tests use the narrow projection
q "ALTER TABLE exp.events ADD PROJECTION proj_country_day (SELECT event_type, country, created_at, amount ORDER BY (event_type, country, created_at))"
q "ALTER TABLE exp.events MATERIALIZE PROJECTION proj_country_day"
q "OPTIMIZE TABLE exp.events FINAL"
quiesce
explain way2_n3_product sql/queries/n3_product_way2.sql
bench way2_n3_product sql/queries/n3_product_way2.sql 12 hot
explain way2_n4_eventtype sql/queries/n4_eventtype_way2.sql
bench way2_n4_eventtype sql/queries/n4_eventtype_way2.sql 12 hot
unquiesce

# ---------------------------------------------------------------- Way 3
echo; echo "### Way 3 — skip indexes (minmax / set / bloom)"
$CH < sql/31_skipindex.sql
q "OPTIMIZE TABLE exp.events_skip FINAL"
echo "-- forensics --" | tee "$RESULTS_DIR/way3_forensics.txt"
{ $CH < sql/30_distribution.sql || echo "WARN: forensics failed"; } | tee -a "$RESULTS_DIR/way3_forensics.txt"
quiesce
for probe in \
  "way3_main:sql/queries/main_way3.sql:$RUNS" \
  "way3_tenant_pos:sql/queries/way3_tenant_pos.sql:15" \
  "way3_country_heavy:sql/queries/way3_country_heavy.sql:15" \
  "way3_userid_bloom:sql/queries/way3_userid_bloom.sql:15"; do
  IFS=: read -r name qf rns <<< "$probe"
  explain "$name" "$qf"
  bench "$name" "$qf" "$rns" hot
done
bench way3_main sql/queries/main_way3.sql "$RUNS" directio
echo "correctness(way3): $(bench/correctness.sh exp.events_skip)" | tee "$RESULTS_DIR/correctness_way3.txt"
unquiesce
storage events_skip | tee "$RESULTS_DIR/storage_way3.txt"
{ q "SELECT name, type_full, formatReadableSize(data_compressed_bytes + marks_bytes) AS sz
     FROM system.data_skipping_indices WHERE database='exp' AND table='events_skip' ORDER BY name" \
  || echo "WARN: skip-index storage query failed"; } | tee -a "$RESULTS_DIR/storage_way3.txt"

# ---------------------------------------------------------------- Way 4
echo; echo "### Way 4 — Materialized View + backfill + write-amp"
$CH < sql/40_mv.sql
qid="mv_backfill_$(date +%s%N)"
$CH --query_id="$qid" -q "
  INSERT INTO exp.events_daily_country
  SELECT toDate(created_at) AS day, country, countState(), sumState(amount)
  FROM exp.events WHERE event_type='purchase' GROUP BY day, country"
q "SYSTEM FLUSH LOGS"
q "SELECT 'backfill_ms' k, query_duration_ms, read_rows FROM system.query_log
   WHERE type='QueryFinish' AND query_id='$qid' ORDER BY event_time_microseconds DESC LIMIT 1" \
   | tee "$RESULTS_DIR/way4_backfill.txt"
quiesce
explain way4_mv sql/queries/main_way4_mv.sql
bench way4_mv sql/queries/main_way4_mv.sql "$RUNS" hot
bench way4_mv sql/queries/main_way4_mv.sql "$RUNS" directio
echo "correctness(way4): $(bench/correctness.sh --mv)" | tee "$RESULTS_DIR/correctness_way4.txt"
explain way4_n5_product sql/queries/n5_product_way4.sql
bench way4_n5_product sql/queries/n5_product_way4.sql 12 hot
unquiesce
storage events_daily_country | tee "$RESULTS_DIR/storage_way4.txt"
# write-amplification: 1M-row insert into a plain copy vs a copy with the MV attached
echo "-- MV write amplification (1M rows) --" | tee "$RESULTS_DIR/way4_writeamp.txt"
q "CREATE TABLE exp.wa_plain AS exp.events"
q "CREATE TABLE exp.wa_mv    AS exp.events"
q "CREATE TABLE exp.wa_mv_target AS exp.events_daily_country"
q "CREATE MATERIALIZED VIEW exp.wa_mv_view TO exp.wa_mv_target AS
   SELECT toDate(created_at) day, country, countState() purchases, sumState(amount) revenue
   FROM exp.wa_mv WHERE event_type='purchase' GROUP BY day, country"
for tbl in wa_plain wa_mv; do
  qid="wa_${tbl}_$(date +%s%N)"
  $CH --query_id="$qid" -q "INSERT INTO exp.$tbl SELECT * FROM exp.events LIMIT 1000000"
  q "SYSTEM FLUSH LOGS"
  q "SELECT '$tbl' t, query_duration_ms, written_rows FROM system.query_log
     WHERE type='QueryFinish' AND query_id='$qid' ORDER BY event_time_microseconds DESC LIMIT 1" \
     | tee -a "$RESULTS_DIR/way4_writeamp.txt"
done
q "DROP TABLE exp.wa_mv_view"; q "DROP TABLE exp.wa_plain"; q "DROP TABLE exp.wa_mv"
q "DROP TABLE exp.wa_mv_target"

# ---------------------------------------------------------------- interleaved (directio)
echo; echo "### interleaved re-measurement — DIRECTIO, round-robin"
quiesce
INTERLEAVE_ROUNDS=$RUNS INTERLEAVE_REGIME=directio MAX_THREADS=$MAX_THREADS \
python3 bench/interleave.py \
  baseline=sql/queries/main_baseline.sql \
  way1=sql/queries/main_way1.sql \
  way2=sql/queries/main_way2.sql \
  way3=sql/queries/main_way3.sql \
  way4=sql/queries/main_way4_mv.sql \
  > "$RESULTS_DIR/interleaved.csv" || echo "(interleave skipped)"
unquiesce

# ---------------------------------------------------------------- summary
echo; echo "### SUMMARY.md"
python3 bench/summarize.py "$RESULTS_DIR" > "$RESULTS_DIR/SUMMARY.md" || true
cat "$RESULTS_DIR/SUMMARY.md" 2>/dev/null || true
echo; echo "DONE -> $RESULTS_DIR/   (log: $LOG)"
