#!/usr/bin/env bash
# bench/run.sh — benchmark harness for the ClickHouse experiment.
#
# Usage:
#   bench/run.sh <label> <query_file> <runs> <mode>
#     label      : e.g. baseline, way1_orderby  (used in CSV output name)
#     query_file : path to .sql containing ONE SELECT
#     runs       : number of MEASURED runs (default 15)
#     mode       : cold | hot | both   (default both)
#
# Environment:
#   CH           : ClickHouse client command.
#                  Native (Codespaces / Linux):  "clickhouse client"   (default)
#                  Docker (original Mac run):     "docker exec -i ch_experiment clickhouse-client"
#   RESULTS_DIR  : output directory (default "results"; the Linux run uses "results/linux")
#
# Regimes:
#   hot  : 3 warmup runs (discarded) then N measured runs, no cache drops.
#   cold : before each measured run, drop CH mark + uncompressed cache.
#          NOTE: the OS page cache is only droppable where /proc/sys/vm/drop_caches
#          is writable (NOT in Docker Desktop's VM, NOT in a Codespace). Where it
#          is not, "cold" means "ClickHouse caches cold", not "disk cold".
#          read_rows / read_bytes / SelectedMarks are the cache-independent ground
#          truth for I/O volume and are identical hot or cold.
#
# Metrics are pulled from system.query_log by query_id (authoritative), plus a
# client-side wall time, plus granule-level ProfileEvents (SelectedMarks /
# SelectedParts / SelectedRanges — these live in ProfileEvents, not top-level cols).

set -euo pipefail

LABEL=${1:?"label required"}
QFILE=${2:?"query file required"}
RUNS=${3:-15}
MODE=${4:-both}
WARMUP=3
CH=${CH:-clickhouse client}
RESULTS_DIR=${RESULTS_DIR:-results}

ch() { $CH "$@"; }

[[ -f "$QFILE" ]] || { echo "no such query file: $QFILE" >&2; exit 1; }
QUERY=$(cat "$QFILE")

mkdir -p "$RESULTS_DIR"

CSV_HEADER="mode,run,wall_ms,duration_ms,read_rows,read_bytes,memory_usage,selected_marks,selected_parts,selected_ranges"

run_once() {
  # $1 = mode (cold|hot), $2 = run index. Appends one CSV line.
  local mode=$1 runidx=$2
  local qid="${LABEL}_${mode}_${runidx}_$(date +%s%N)"

  if [[ "$mode" == "cold" ]]; then
    ch -q "SYSTEM DROP MARK CACHE" >/dev/null
    ch -q "SYSTEM DROP UNCOMPRESSED CACHE" >/dev/null
    # Best-effort OS page-cache drop; silently no-ops where not permitted.
    if [[ -w /proc/sys/vm/drop_caches ]]; then sync; echo 3 > /proc/sys/vm/drop_caches; fi
  fi

  local start end wall_ms
  start=$(date +%s%N)
  ch --query_id="$qid" -q "$QUERY" >/dev/null
  end=$(date +%s%N)
  wall_ms=$(( (end - start) / 1000000 ))

  ch -q "SYSTEM FLUSH LOGS" >/dev/null
  ch -q "
    SELECT '${mode}','${runidx}','${wall_ms}',
           query_duration_ms, read_rows, read_bytes, memory_usage,
           ProfileEvents['SelectedMarks'],
           ProfileEvents['SelectedParts'],
           ProfileEvents['SelectedRanges']
    FROM system.query_log
    WHERE type='QueryFinish' AND query_id='${qid}'
    ORDER BY event_time_microseconds DESC
    LIMIT 1
    FORMAT CSV"
}

emit_summary() {
  local file=$1
  echo "== summary: $file =="
  awk -F, 'NR>1{
    n++; d[n]=$4+0; rb[n]=$6+0; rr[n]=$5+0; mem[n]=$7+0; sm[n]=$8+0
    # throttle / drift check: track first vs last third of duration
  } END{
    for(i=2;i<=n;i++){v=d[i];j=i-1;while(j>=1&&d[j]>v){d[j+1]=d[j];j--}d[j+1]=v}
    for(i=2;i<=n;i++){v=rb[i];j=i-1;while(j>=1&&rb[j]>v){rb[j+1]=rb[j];j--}rb[j+1]=v}
    for(i=2;i<=n;i++){v=rr[i];j=i-1;while(j>=1&&rr[j]>v){rr[j+1]=rr[j];j--}rr[j+1]=v}
    for(i=2;i<=n;i++){v=mem[i];j=i-1;while(j>=1&&mem[j]>v){mem[j+1]=mem[j];j--}mem[j+1]=v}
    for(i=2;i<=n;i++){v=sm[i];j=i-1;while(j>=1&&sm[j]>v){sm[j+1]=sm[j];j--}sm[j+1]=v}
    p50=int(n*0.5); p25=int(n*0.25); p75=int(n*0.75);
    if(p50<1)p50=1; if(p25<1)p25=1; if(p75<1)p75=1;
    printf "runs=%d\n", n;
    printf "duration_ms  p25=%d p50=%d p75=%d min=%d max=%d\n", d[p25], d[p50], d[p75], d[1], d[n];
    printf "read_rows    p50=%d\n", rr[p50];
    printf "read_bytes   p50=%d\n", rb[p50];
    printf "sel_marks    p50=%d\n", sm[p50];
    printf "memory_usage p50=%d\n", mem[p50];
  }' "$file"
}

do_mode() {
  local m=$1
  local out="${RESULTS_DIR}/${LABEL}_${m}.csv"
  echo "$CSV_HEADER" > "$out"

  if [[ "$m" == "hot" ]]; then
    for i in $(seq 1 $WARMUP); do run_once hot "warmup$i" >/dev/null; done
  fi
  for i in $(seq 1 $RUNS); do
    run_once "$m" "$i" >> "$out"
  done
  emit_summary "$out"
}

case "$MODE" in
  cold) do_mode cold ;;
  hot)  do_mode hot  ;;
  both) do_mode hot; do_mode cold ;;
  *) echo "mode must be cold|hot|both" >&2; exit 1 ;;
esac

echo "done: $LABEL ($MODE, $RUNS runs) -> $RESULTS_DIR/"
