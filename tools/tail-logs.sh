#!/usr/bin/env bash
# tail-logs.sh : follow the logs of a container or function.
#
# Usage: tools/tail-logs.sh <container|function> <name> [revision] [--since 2026-10-06T10:00:00Z]
#
# Polls GET serverless/<kind>/{id}/logs?since=<RFC3339>&limit=500[&revision=N]
# every second (SLS_POLL_INTERVAL ignored, 1s fixed), prints
#   <timestamp> <level> <message>
# and moves `since` to the last timestamp seen. Entries are assumed to be an
# array ordered oldest first with fields timestamp|ts|time, level|severity,
# message|msg (and optional revision). Ctrl-C to stop.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 2 ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit $(( $# < 2 ? 2 : 0 )); }
need_cmd python3 jq
KIND="$1"; NAME="$2"; shift 2
REVISION=""; SINCE=""
while (( $# )); do
  case "$1" in
    --since) SINCE="$2"; shift ;;
    [0-9]*) REVISION="$1" ;;
    *) die "unexpected argument: $1" ;;
  esac
  shift
done

ID="$(sls_id "$KIND" "$NAME")"
[[ -n "$ID" ]] || die "$KIND '$NAME' not found"
LOGS_PATH="$(sls_kind_path "$KIND")/${ID}/logs"
if [[ -z "$SINCE" ]]; then
  # start one minute back; GNU and BSD date differ
  SINCE="$(date -u -v-60S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
fi
SEEN="$(mktemp "${TMPDIR:-/tmp}/tail-logs.XXXXXX")"
trap 'rm -f "$SEEN"' EXIT
log "tailing $KIND $NAME (id=$ID) since $SINCE ${REVISION:+revision=$REVISION}; Ctrl-C to stop"

while :; do
  args=(--query "since=${SINCE}" --query "limit=500")
  [[ -n "$REVISION" ]] && args+=(--query "revision=${REVISION}")
  if ! batch="$(api GET "$LOGS_PATH" "${args[@]}" --raw 2>/dev/null)"; then
    warn "logs request failed, retrying"; sleep 2; continue
  fi
  lines="$(jq -r '
    (if type == "array" then . else (.logs // .entries // .items // []) end)[]
    | "\(.timestamp // .ts // .time // "")\t\(.level // .severity // "INFO")\t\(.message // .msg // "")"' <<<"$batch")"
  if [[ -n "$lines" ]]; then
    # drop lines already printed (same since timestamp is inclusive)
    new="$(grep -vxF -f "$SEEN" <<<"$lines" || true)"
    if [[ -n "$new" ]]; then
      printf '%s\n' "$new" | awk -F'\t' '{printf "%s %-5s %s\n", $1, $2, $3}'
      last="$(tail -n1 <<<"$new" | cut -f1)"
      [[ -n "$last" ]] && SINCE="$last"
      # remember the lines carrying the newest timestamp
      awk -F'\t' -v t="$SINCE" '$1 == t' <<<"$lines" > "$SEEN"
    fi
  fi
  sleep 1
done
