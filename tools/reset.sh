#!/usr/bin/env bash
# reset.sh : delete every Serverless resource named demo-* and optionally reseed.
#
# Usage: tools/reset.sh [--yes] [--seed] [--help]
#
#   --yes   skip the confirmation prompt
#   --seed  run tools/seed.sh once everything is gone
#
# Lists GET serverless/resource, keeps items whose targetSpec.name starts with
# demo-, DELETEs each through its kind route (serverless/container/{id} or
# serverless/function/{id}), then polls until they disappear. Resources with
# other names are never touched.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

YES=0; SEED=0
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    --seed) SEED=1 ;;
    --help|-h) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $a" ;;
  esac
done
need_cmd python3 jq
[[ -n "${OVH_CLOUD_PROJECT:-}" ]] || die "OVH_CLOUD_PROJECT is not set"

# The aggregated list is assumed to expose the kind as .kind (CONTAINER|FUNCTION);
# when absent we infer it from the template shape.
list_demo() {
  api GET serverless/resource --raw | jq -c '
    (if type == "array" then . else (.resources // .items // []) end)
    | map(select(.targetSpec.name | startswith("demo-")))
    | map({id, name: .targetSpec.name,
           kind: ((.kind // (if .targetSpec.template.function then "FUNCTION" else "CONTAINER" end)) | ascii_downcase),
           status: .resourceStatus})'
}

ITEMS="$(list_demo)"
COUNT="$(jq 'length' <<<"$ITEMS")"
if (( COUNT == 0 )); then
  log "no demo-* resources found"
else
  printf '\n%-10s %-24s %-38s %s\n' KIND NAME ID STATUS
  jq -r '.[] | "\(.kind)|\(.name)|\(.id)|\(.status)"' <<<"$ITEMS" | while IFS='|' read -r k n i s; do
    printf '%-10s %-24s %-38s %s\n' "$k" "$n" "$i" "$s"
  done
  printf '\n'
  if (( ! YES )); then
    read -r -p "Delete these $COUNT resource(s)? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { log "aborted"; exit 0; }
  fi
  while IFS='|' read -r k n i; do
    is_demo_name "$n" || continue
    log "DELETE $(sls_kind_path "$k")/$i ($n)"
    api DELETE "$(sls_kind_path "$k")/$i" --raw >/dev/null || warn "delete of $n failed (already gone?)"
  done < <(jq -r '.[] | "\(.kind)|\(.name)|\(.id)"' <<<"$ITEMS")

  start=$(date +%s)
  while :; do
    left="$(list_demo | jq 'length')"
    el=$(( $(date +%s) - start ))
    printf '\r  %4ds  remaining=%s' "$el" "$left" >&2
    (( left == 0 )) && { printf '\n' >&2; log "all demo-* resources gone after ${el}s"; break; }
    (( el >= 600 )) && { printf '\n' >&2; die "timeout waiting for deletion"; }
    sleep "$SLS_POLL_INTERVAL"
  done
fi

if (( SEED )); then
  log "reseeding"
  exec "${TOOLS_DIR}/seed.sh"
fi
