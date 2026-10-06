#!/usr/bin/env bash
# traffic.sh : split, promote or roll back traffic between revisions.
#
# Usage: tools/traffic.sh <name> canary|promote|rollback [stable_rev] [canary_rev]
#   KIND=function tools/traffic.sh demo-motd promote      (default KIND=container)
#
#   canary    stable 90 % / canary 10 % tagged "green"   (payloads/traffic-canary.json)
#   promote   canary 100 %                               (payloads/traffic-promote.json)
#   rollback  stable 100 %                               (payloads/traffic-rollback.json)
#
# Defaults: canary_rev = currentState.latestReadyRevision; stable_rev = the
# READY revision currently carrying the most weight that is not the canary,
# else the highest READY revision below the canary.
# Traffic changes do not create a revision; the script GETs the checksum, PUTs
# the rendered payload and prints the resulting currentState.traffic.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 2 ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit $(( $# < 2 ? 2 : 0 )); }
need_cmd python3 jq
NAME="$1"; ACTION="$2"; STABLE="${3:-}"; CANARY="${4:-}"
KIND="${KIND:-container}"
is_demo_name "$NAME" || die "refusing to touch '$NAME': only demo-* resources"

case "$ACTION" in
  canary)   PAYLOAD="traffic-canary.json" ;;
  promote)  PAYLOAD="traffic-promote.json" ;;
  rollback) PAYLOAD="traffic-rollback.json" ;;
  *) die "unknown action '$ACTION' (canary|promote|rollback)" ;;
esac

RES="$(sls_get_resource "$KIND" "$NAME")"
[[ -n "$RES" ]] || die "$KIND '$NAME' not found"
ID="$(jq -r '.id' <<<"$RES")"
CUR="$(api GET "$(sls_kind_path "$KIND")/${ID}" --raw)"
CHECKSUM="$(jq -r '.checksum' <<<"$CUR")"
LATEST="$(jq -r '.currentState.latestReadyRevision // empty' <<<"$CUR")"
[[ -n "$CANARY" ]] || CANARY="$LATEST"
[[ -n "$CANARY" ]] || die "no latestReadyRevision on '$NAME'"
if [[ -z "$STABLE" ]]; then
  STABLE="$(jq -r --argjson c "$CANARY" '
    ([.currentState.traffic[]? | select(.revision != null and .revision != $c)] | sort_by(-.weight) | .[0].revision)
    // ([.currentState.revisions[]? | select(.status == "READY" and .number < $c) | .number] | max)
    // empty' <<<"$CUR")"
fi
[[ -n "$STABLE" ]] || die "could not determine a stable revision; pass it explicitly"
[[ "$STABLE" != "$CANARY" || "$ACTION" != "canary" ]] || die "stable and canary are the same revision ($STABLE)"

log "$ACTION on $KIND '$NAME' (id=$ID): stable=r$STABLE canary=r$CANARY checksum=$CHECKSUM"
log "current traffic: $(jq -c '.currentState.traffic' <<<"$CUR")"
RENDERED="$(render_payload "$PAYLOAD" "CHECKSUM=${CHECKSUM}" "STABLE_REV=${STABLE}" "CANARY_REV=${CANARY}")"
api PUT "$(sls_kind_path "$KIND")/${ID}" --body "$RENDERED" --raw >/dev/null
log "PUT accepted"

sleep 2
AFTER="$(api GET "$(sls_kind_path "$KIND")/${ID}" --raw)"
printf '\n%-10s %-8s %-8s %s\n' REVISION WEIGHT TAG URL
jq -r '.currentState.traffic[]? | "\(.revision // "latest")|\(.weight)|\(.tag // "-")|\(.url // "-")"' <<<"$AFTER" | while IFS='|' read -r r w t u; do
  printf '%-10s %-8s %-8s %s\n' "r$r" "$w%" "$t" "$u"
done
printf '\ntargetSpec.traffic: %s\n' "$(jq -c '.targetSpec.traffic' <<<"$AFTER")"
