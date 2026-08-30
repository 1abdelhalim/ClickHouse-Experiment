#!/usr/bin/env bash
# bench/correctness.sh — cityHash64 of THE query's full result for a given source.
# Every variant must print the SAME value (the run's anchor is in
# results/linux/correctness_baseline.txt). The ORDER BY tiebreaker (revenue,
# country, day) makes the row order — and therefore the hash — deterministic
# regardless of which physical layout produced it.
#   usage: bench/correctness.sh <table>   # exp.events / exp.events_orderby / exp.events_skip
#          bench/correctness.sh --mv      # the AggregatingMergeTree target
set -euo pipefail
CH=${CH:-clickhouse client}

if [[ "${1:-}" == "--mv" ]]; then
  $CH -q "
  SELECT cityHash64(groupArray(tuple(country, day, purchases, revenue)))
  FROM (
    SELECT country, day, countMerge(purchases) AS purchases, sumMerge(revenue) AS revenue
    FROM exp.events_daily_country
    WHERE day >= '2025-08-02' AND day < '2025-09-01'
    GROUP BY country, day
    ORDER BY revenue DESC, country, day
    LIMIT 10
  )"
  exit 0
fi

TABLE=${1:?"table required (e.g. exp.events)"}
$CH -q "
SELECT cityHash64(groupArray(tuple(country, day, purchases, revenue)))
FROM (
  SELECT country, toDate(created_at) AS day, count() AS purchases, sum(amount) AS revenue
  FROM ${TABLE}
  WHERE event_type = 'purchase'
    AND created_at >= toDateTime('2025-08-02 00:00:00')
    AND created_at <  toDateTime('2025-09-01 00:00:00')
  GROUP BY country, day
  ORDER BY revenue DESC, country, day
  LIMIT 10
)"
