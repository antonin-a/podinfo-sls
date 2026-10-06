#!/usr/bin/env bash
# metrics.sh : aggregated metrics of a container or function.
#
# Usage: tools/metrics.sh <container|function> <name> [window=PT1H] [--series]
#
# GET serverless/<kind>/{id}/metrics?window=<ISO8601 duration> and prints a
# compact table: requests, error count, p50/p95 latency, instances (avg/peak),
# cpu and memory (avg/peak), cold starts. Field names in the alpha payload are
# matched leniently (several spellings tried); the raw JSON is printed below
# the table so nothing is hidden. --series adds GET .../metrics/series.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 2 ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit $(( $# < 2 ? 2 : 0 )); }
need_cmd python3 jq
KIND="$1"; NAME="$2"; WINDOW="PT1H"; SERIES=0
shift 2
while (( $# )); do
  case "$1" in
    --series) SERIES=1 ;;
    P*) WINDOW="$1" ;;
    *) die "unexpected argument: $1" ;;
  esac
  shift
done

ID="$(sls_id "$KIND" "$NAME")"
[[ -n "$ID" ]] || die "$KIND '$NAME' not found"
BASE="$(sls_kind_path "$KIND")/${ID}/metrics"
M="$(api GET "$BASE" --query "window=${WINDOW}" --raw)"

row() { printf '%-22s %s\n' "$1" "$2"; }
val() { jq -r "$1 // \"-\"" <<<"$M"; }

printf '\n%s %s   window %s\n\n' "$KIND" "$NAME" "$WINDOW"
row "requests"        "$(val '.requests // .requestCount // .http.requests')"
row "errors (5xx)"    "$(val '.errors // .errorCount // .http.errors5xx')"
row "latency p50 ms"  "$(val '.latency.p50 // .latencyP50Ms // .p50LatencyMs')"
row "latency p95 ms"  "$(val '.latency.p95 // .latencyP95Ms // .p95LatencyMs')"
row "latency p99 ms"  "$(val '.latency.p99 // .latencyP99Ms // .p99LatencyMs')"
row "instances avg"   "$(val '.instances.avg // .instancesAvg // .avgInstances')"
row "instances peak"  "$(val '.instances.peak // .instances.max // .instancesPeak // .maxInstances')"
row "cpu avg"         "$(val '.cpu.avg // .cpuAvg // .cpuUsageAvg')"
row "cpu peak"        "$(val '.cpu.peak // .cpu.max // .cpuPeak')"
row "memory avg MiB"  "$(val '.memory.avg // .memoryAvg // .memoryUsageAvg')"
row "memory peak MiB" "$(val '.memory.peak // .memory.max // .memoryPeak')"
row "cold starts"     "$(val '.coldStarts // .coldStartCount')"
printf '\nraw: %s\n' "$(jq -c . <<<"$M")"

if (( SERIES )); then
  printf '\nseries:\n'
  api GET "${BASE}/series" --query "window=${WINDOW}"
fi
