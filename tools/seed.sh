#!/usr/bin/env bash
# seed.sh : create the demo starting state if absent (idempotent).
#
# Usage: tools/seed.sh [--skip-function] [--help]
#
# Creates, only when missing:
#   - container $DEMO_CONTAINER (demo-podinfo-sls) from the podinfo-sls repo,
#     ref main, revision 1, waits READY and prints the elapsed seconds
#   - function  $DEMO_FUNCTION (demo-motd) from serverless-fn-motd, ref main,
#     with the AI_ENDPOINTS_TOKEN secret (requires AI_ENDPOINTS_TOKEN in env.sh)
# Existing resources are left untouched (no revision added). Prints the URLs.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }
SKIP_FN=0; [[ "${1:-}" == "--skip-function" ]] && SKIP_FN=1

need_cmd python3 jq
[[ -n "${OVH_CLOUD_PROJECT:-}" ]] || die "OVH_CLOUD_PROJECT is not set"

log "seed: container $DEMO_CONTAINER"
OUT_C="$("${TOOLS_DIR}/deploy.sh" container "$DEMO_CONTAINER" "${PAYLOADS_DIR}/container-from-repo.json" REF=main REVISION_LABEL=rev-main --create-only)"
echo "$OUT_C" | grep -v '^SLS_' || true
URL_C="$(grep '^SLS_URL=' <<<"$OUT_C" | cut -d= -f2-)"

URL_F=""
if (( SKIP_FN )); then
  log "seed: function skipped (--skip-function)"
elif [[ -z "${AI_ENDPOINTS_TOKEN:-}" || "$AI_ENDPOINTS_TOKEN" == "<AI_ENDPOINTS_TOKEN>" ]]; then
  warn "AI_ENDPOINTS_TOKEN is not set: skipping function $DEMO_FUNCTION (set it in tools/env.sh or pass --skip-function to silence)"
else
  log "seed: function $DEMO_FUNCTION"
  OUT_F="$("${TOOLS_DIR}/deploy.sh" function "$DEMO_FUNCTION" "${PAYLOADS_DIR}/function-motd-from-repo.json" REF=main --create-only)"
  echo "$OUT_F" | grep -v '^SLS_' || true
  URL_F="$(grep '^SLS_URL=' <<<"$OUT_F" | cut -d= -f2-)"
fi

printf '\nSeed complete.\n'
printf '  %-20s %s\n' "$DEMO_CONTAINER" "${URL_C:-<no url yet>}"
[[ -n "$URL_F" ]] && printf '  %-20s %s\n' "$DEMO_FUNCTION" "$URL_F"
exit 0
