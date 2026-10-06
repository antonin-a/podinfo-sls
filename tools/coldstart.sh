#!/usr/bin/env bash
# coldstart.sh : measure a cold start end to end.
#
# Usage: tools/coldstart.sh <container|function> <name> [--no-wait] [--path /api/info]
#
#   1. waits until currentState.readyInstances == 0 (prints an idle countdown
#      based on idleTimeoutSeconds), unless --no-wait
#   2. cold call: curl -w %{time_starttransfer} on <url><path>
#   3. two warm calls, same measurement
#   4. API side: POST serverless/<kind>/{id}/invoke with payloads/invoke-info.json
#      and prints latencyMs / coldStart for comparison
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 2 ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit $(( $# < 2 ? 2 : 0 )); }
need_cmd python3 jq curl
KIND="$1"; NAME="$2"; shift 2
WAIT=1; HTTP_PATH="/api/info"
while (( $# )); do
  case "$1" in
    --no-wait) WAIT=0 ;;
    --path) HTTP_PATH="$2"; shift ;;
    *) die "unexpected argument: $1" ;;
  esac
  shift
done

RES="$(sls_get_resource "$KIND" "$NAME")"
[[ -n "$RES" ]] || die "$KIND '$NAME' not found"
ID="$(jq -r '.id' <<<"$RES")"
KIND_PATH="$(sls_kind_path "$KIND")/${ID}"
URL="$(jq -r '.currentState.url // empty' <<<"$RES")"
[[ -n "$URL" ]] || die "no currentState.url on '$NAME'"
IDLE="$(jq -r '.targetSpec.scaling.idleTimeoutSeconds // 60' <<<"$RES")"

if (( WAIT )); then
  log "waiting for readyInstances == 0 on $NAME (idleTimeoutSeconds=${IDLE})"
  start=$(date +%s)
  while :; do
    ready="$(api GET "$KIND_PATH" --raw | jq -r '.currentState.readyInstances // 0')"
    el=$(( $(date +%s) - start ))
    remaining=$(( IDLE - el )); (( remaining < 0 )) && remaining=0
    printf '\r  %4ds  readyInstances=%-3s idle countdown ~%3ss' "$el" "$ready" "$remaining" >&2
    [[ "$ready" == "0" ]] && { printf '\n' >&2; log "scaled to zero after ${el}s"; break; }
    (( el > IDLE * 3 + 120 )) && { printf '\n' >&2; die "instances did not reach 0 (minInstances > 0? traffic still flowing?)"; }
    sleep "$SLS_POLL_INTERVAL"
  done
fi

measure() { # prints "ttfb_ms total_ms http_code"
  curl -s -o /dev/null --max-time 60 -w '%{time_starttransfer} %{time_total} %{http_code}' "${URL}${HTTP_PATH}" \
    | awk '{printf "%.0f %.0f %s\n", $1*1000, $2*1000, $3}'
}

log "cold call on ${URL}${HTTP_PATH}"
COLD="$(measure)"
WARM1="$(measure)"
WARM2="$(measure)"

printf '\n%-10s %10s %10s %6s\n' CALL TTFB_MS TOTAL_MS HTTP
printf '%-10s %10s %10s %6s\n' ---------- ---------- ---------- ------
printf '%-10s %10s %10s %6s\n' cold   $COLD
printf '%-10s %10s %10s %6s\n' warm-1 $WARM1
printf '%-10s %10s %10s %6s\n' warm-2 $WARM2

log "API invoke (POST ${KIND_PATH}/invoke)"
INV="$(api POST "${KIND_PATH}/invoke" --body "${PAYLOADS_DIR}/invoke-info.json" --raw)" || die "invoke failed"
printf '\n%-10s %10s %10s %8s %s\n' INVOKE LATENCY_MS COLDSTART TIMEDOUT HTTP
printf '%-10s %10s %10s %8s %s\n' api "$(jq -r '.latencyMs' <<<"$INV")" "$(jq -r '.coldStart' <<<"$INV")" "$(jq -r '.timedOut' <<<"$INV")" "$(jq -r '.status' <<<"$INV")"
printf '\nbody: %s\n' "$(jq -r '.body // empty' <<<"$INV" | cut -c1-200)"
