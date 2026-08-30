#!/usr/bin/env bash
# bench/run.sh — benchmark harness for the ClickHouse experiment (v2).
#
# Usage:
#   bench/run.sh <label> <query_file> <runs> <regime>
#     label      : e.g. baseline, way1_orderby  (CSV output name)
#     query_file : path to .sql containing ONE SELECT (trailing ; is stripped)
#     runs       : number of MEASURED runs (default $RUNS or 25)
#     regime     : hot | cold | directio | all   (default hot)
#
# Regimes:
#   hot       : 3 warmup runs discarded, then N runs, all caches warm.
#               Measures CPU + memory bandwidth. Latency here is only meaningful
#               relative to other variants at the same regime.
#   cold      : drop ClickHouse mark + uncompressed + query caches before each
#               run (OS page cache untouched — not droppable in a container).
#   directio  : as cold, PLUS SETTINGS min_bytes_to_use_direct_io=1 so every read
#               goes through O_DIRECT and bypasses the OS page cache. This is the
#               closest a container can get to a true cold-disk read, and it is
#               where absolute latency numbers become defensible.
#
# Every measured query runs with a fixed SETTINGS block (see mk_query) so results
# are reproducible across hosts: max_threads pinned, query cache off.
#
# Environment:
#   CH          : ClickHouse client command (default "clickhouse client";
#                 Docker: "docker exec -i ch_experiment clickhouse-client")
#   RESULTS_DIR : output dir (default "results")
#   MAX_THREADS : pinned max_threads (default: nproc)
#   RUNS        : default measured-run count (default 25)
#
# Metrics: system.query_log by query_id (authoritative) + client wall time +
# granule ProfileEvents (SelectedMarks/Parts/Ranges — not top-level columns).

set -euo pipefail

LABEL=${1:?"label required"}
QFILE=${2:?"query file required"}
RUNS=${3:-${RUNS:-25}}
REGIME=${4:-hot}
WARMUP=3
CH=${CH:-clickhouse client}
RESULTS_DIR=${RESULTS_DIR:-results}
MAX_THREADS=${MAX_THREADS:-$(nproc 2>/dev/null || echo 4)}

ch() { $CH "$@"; }

[[ -f "$QFILE" ]] || { echo "no such query file: $QFILE" >&2; exit 1; }
# strip comments? no — ClickHouse handles leading -- comments. Just drop trailing ; and blank tail.
RAW_QUERY=$(sed -e 's/;[[:space:]]*$//' "$QFILE")

mkdir -p "$RESULTS_DIR"

CSV_HEADER="regime,run,wall_ms,duration_ms,read_rows,read_bytes,memory_usage,selected_marks,selected_parts,selected_ranges"

mk_query() {  # $1 = regime — echoes the query with its SETTINGS block
  local regime=$1
  local settings="max_threads=${MAX_THREADS}, use_query_cache=0"
  [[ "$regime" == "directio" ]] && settings="${settings}, min_bytes_to_use_direct_io=1"
  printf '%s\nSETTINGS %s' "$RAW_QUERY" "$settings"
}

drop_ch_caches() {
  ch -q "SYSTEM DROP MARK CACHE" >/dev/null
  ch -q "SYSTEM DROP UNCOMPRESSED CACHE" >/dev/null
  ch -q "SYSTEM DROP QUERY CACHE" >/dev/null 2>&1 || true
}

run_once() {  # $1 = regime, $2 = run index. Appends one CSV line.
  local regime=$1 runidx=$2
  local qid="${LABEL}_${regime}_${runidx}_$(date +%s%N)"
  local query; query=$(mk_query "$regime")

  [[ "$regime" != "hot" ]] && drop_ch_caches

  local start end wall_ms
  start=$(date +%s%N)
  ch --query_id="$qid" -q "$query" >/dev/null
  end=$(date +%s%N)
  wall_ms=$(( (end - start) / 1000000 ))

  ch -q "SYSTEM FLUSH LOGS" >/dev/null
  ch -q "
    SELECT '${regime}','${runidx}','${wall_ms}',
           query_duration_ms, read_rows, read_bytes, memory_usage,
           ProfileEvents['SelectedMarks'],
           ProfileEvents['SelectedParts'],
           ProfileEvents['SelectedRanges']
    FROM system.query_log
    WHERE type='QueryFinish' AND query_id='${qid}'
    ORDER BY event_time_microseconds DESC LIMIT 1
    FORMAT CSV"
}

emit_summary() {  # $1 = csv file — median + spread + coefficient of variation
  local file=$1
  echo "== summary: $file =="
  awk -F, 'NR>1{ n++; d[n]=$4+0; rr[n]=$5+0; rb[n]=$6+0; sm[n]=$8+0; s+=$4; ss+=($4)*($4) }
  END{
    if(n==0){print "  (no rows)"; exit}
    for(i=2;i<=n;i++){v=d[i];j=i-1;while(j>=1&&d[j]>v){d[j+1]=d[j];j--}d[j+1]=v}
    for(i=2;i<=n;i++){v=rr[i];j=i-1;while(j>=1&&rr[j]>v){rr[j+1]=rr[j];j--}rr[j+1]=v}
    for(i=2;i<=n;i++){v=rb[i];j=i-1;while(j>=1&&rb[j]>v){rb[j+1]=rb[j];j--}rb[j+1]=v}
    for(i=2;i<=n;i++){v=sm[i];j=i-1;while(j>=1&&sm[j]>v){sm[j+1]=sm[j];j--}sm[j+1]=v}
    p50=int(n*0.5); if(p50<1)p50=1;
    mean=s/n; var=ss/n-mean*mean; if(var<0)var=0; sd=sqrt(var); cv=(mean>0)?100*sd/mean:0;
    printf "  runs=%d\n", n;
    printf "  duration_ms  p50=%d  min=%d  max=%d  mean=%.1f  sd=%.1f  cv=%.1f%%%s\n", \
           d[p50], d[1], d[n], mean, sd, cv, (cv>10?"   <-- CV>10%, medians unreliable":"");
    printf "  read_rows    p50=%d\n", rr[p50];
    printf "  read_bytes   p50=%d\n", rb[p50];
    printf "  sel_marks    p50=%d\n", sm[p50];
  }' "$file"
}

do_regime() {
  local r=$1
  local out="${RESULTS_DIR}/${LABEL}_${r}.csv"
  echo "$CSV_HEADER" > "$out"
  if [[ "$r" == "hot" ]]; then
    for i in $(seq 1 $WARMUP); do run_once hot "warmup$i" >/dev/null; done
  fi
  for i in $(seq 1 $RUNS); do run_once "$r" "$i" >> "$out"; done
  emit_summary "$out"
}

case "$REGIME" in
  hot|cold|directio) do_regime "$REGIME" ;;
  all) do_regime hot; do_regime directio ;;
  *) echo "regime must be hot|cold|directio|all" >&2; exit 1 ;;
esac

echo "done: $LABEL ($REGIME, $RUNS runs) -> $RESULTS_DIR/"
