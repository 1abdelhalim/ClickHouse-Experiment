#!/usr/bin/env bash
# bench/correctness.sh — print the correctness hash of THE query's result for a
# given source table. Every variant must print 10593978362403202577.
#   usage: bench/correctness.sh <table>          (row-level source: events / events_orderby / events_skip)
#          bench/correctness.sh --mv              (the AggregatingMergeTree target)
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
    ORDER BY revenue DESC
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
  ORDER BY revenue DESC
  LIMIT 10
)"
