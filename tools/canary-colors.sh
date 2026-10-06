#!/usr/bin/env bash
# canary-colors.sh : live histogram of the colour served by /api/info.
#
# Usage: tools/canary-colors.sh <url> [duration_s=60] [interval_s=0.2]
#
# Calls  curl -s $url/api/info | jq -r .color  every interval, keeps one
# updating line with per-colour counts and percentages (so the 90/10 canary
# split is visible on stage), then prints a final summary. Ctrl-C stops early
# and still prints the summary. Non-JSON or failed responses count as "error".
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 1 ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit $(( $# < 1 ? 2 : 0 )); }
need_cmd curl jq
URL="${1%/}"; DURATION="${2:-60}"; INTERVAL="${3:-0.2}"
SAMPLES="$(mktemp "${TMPDIR:-/tmp}/canary-colors.XXXXXX")"
trap 'rm -f "$SAMPLES"' EXIT

histogram() { # prints "colour count pct" lines sorted by count desc
  local total
  total="$(wc -l <"$SAMPLES" | tr -d ' ')"
  (( total == 0 )) && return 0
  sort "$SAMPLES" | uniq -c | sort -rn | awk -v t="$total" '{printf "%s %d %.1f\n", $2, $1, 100*$1/t}'
}

summary() {
  printf '\n\nFinal distribution (%s samples):\n' "$(wc -l <"$SAMPLES" | tr -d ' ')"
  histogram | awk '{printf "  %-10s %5d  %5.1f%%\n", $1, $2, $3}'
}
trap 'summary; rm -f "$SAMPLES"; exit 0' INT

START=$(date +%s)
log "polling ${URL}/api/info every ${INTERVAL}s for ${DURATION}s"
while (( $(date +%s) - START < DURATION )); do
  color="$(curl -s --max-time 5 "${URL}/api/info" | jq -r '.color // "nocolor"' 2>/dev/null || true)"
  [[ -n "$color" ]] || color="error"
  echo "$color" >> "$SAMPLES"
  line="$(histogram | awk '{printf "%s %d (%.0f%%)   ", $1, $2, $3}')"
  printf '\r  %3ds  %s' "$(( $(date +%s) - START ))" "$line"
  sleep "$INTERVAL"
done
summary
