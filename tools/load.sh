#!/usr/bin/env bash
# load.sh : fixed-rate HTTP load against the demo URL.
#
# Usage: tools/load.sh <url> [rps=20] [duration=60s] [path=/api/info] [workers=10]
#
# Uses oha when installed (oha -q <rps> -z <duration> -c <workers> --no-tui),
# otherwise falls back to the standard-library Go tool in tools/load
# (go run), which prints every 5s: achieved req/s, p50/p95/p99 ms, status
# histogram and colour histogram (when /api/info returns a "color" field).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 1 ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit $(( $# < 1 ? 2 : 0 )); }
URL="${1%/}"; RPS="${2:-20}"; DURATION="${3:-60s}"; HTTP_PATH="${4:-/api/info}"; WORKERS="${5:-10}"

if [[ "${SLS_LOAD_TOOL:-}" != "go" ]] && command -v oha >/dev/null 2>&1; then
  log "oha: ${RPS} req/s for ${DURATION} on ${URL}${HTTP_PATH} (${WORKERS} connections)"
  exec oha -q "$RPS" -z "$DURATION" -c "$WORKERS" --no-tui --latency-correction "${URL}${HTTP_PATH}"
fi

need_cmd go
log "go run tools/load: ${RPS} req/s for ${DURATION} on ${URL}${HTTP_PATH} (${WORKERS} workers)"
cd "${TOOLS_DIR}/load"
exec go run . -url "$URL" -rps "$RPS" -duration "$DURATION" -path "$HTTP_PATH" -workers "$WORKERS"
