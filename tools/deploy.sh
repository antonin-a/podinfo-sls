#!/usr/bin/env bash
# deploy.sh : create-or-update a Serverless container or function and wait READY.
#
# Usage:
#   tools/deploy.sh <container|function> <name> <payload.json> [KEY=VAL ...] [--create-only] [--timeout S]
#
# Behaviour:
#   - if a resource with targetSpec.name == <name> exists: GET its checksum and
#     PUT a ResourceUpdate (a create payload is converted: region dropped,
#     checksum injected); 412 means someone changed it in between, rerun.
#   - else: POST the payload (an update payload with {{CHECKSUM}} is refused).
#   - waits until resourceStatus == READY; when the payload carries a template
#     the wait also requires a new latestReadyRevision.
#   - prints elapsed seconds, URL and latest revision; also emits
#     SLS_URL / SLS_REVISION / SLS_ELAPSED lines and appends them to
#     $GITHUB_OUTPUT when set.
#
# Placeholders rendered into the payload (defaults in brackets):
#   NAME=<name>  REGION=[$SLS_REGION]  REPO_URL=[repo for kind]  REF=[main]
#   IMAGE=[$GHCR_IMAGE]  UI_MESSAGE=[Hello from OVHcloud Serverless]
#   REVISION_LABEL=[rev-<REF>]  MOTD_THEME=[ocean]
#   AI_ENDPOINTS_TOKEN=[$AI_ENDPOINTS_TOKEN]  CHECKSUM=[fetched]
#   STABLE_REV / CANARY_REV when the payload needs them.
#
# Examples:
#   tools/deploy.sh container demo-podinfo-sls tools/payloads/container-from-repo.json
#   tools/deploy.sh container demo-podinfo-sls tools/payloads/container-from-repo.json REF=$GITHUB_SHA
#   tools/deploy.sh function  demo-motd tools/payloads/function-motd-from-repo.json MOTD_THEME=space
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
[[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -lt 3 ]] && { usage; exit $(( $# < 3 ? 2 : 0 )); }

need_cmd python3 jq
KIND="$1"; NAME="$2"; PAYLOAD="$3"; shift 3
CREATE_ONLY=0; TIMEOUT=900; EXTRA=()
while (( $# )); do
  case "$1" in
    --create-only) CREATE_ONLY=1 ;;
    --timeout) TIMEOUT="$2"; shift ;;
    *=*) EXTRA+=("$1") ;;
    *) die "unexpected argument: $1" ;;
  esac
  shift
done

is_demo_name "$NAME" || die "refusing to touch '$NAME': scripts only manage resources named demo-*"
[[ -n "${OVH_CLOUD_PROJECT:-}" ]] || die "OVH_CLOUD_PROJECT is not set"
KIND_PATH="$(sls_kind_path "$KIND")"

# REF given explicitly drives the default REVISION_LABEL (bash 3.2 compatible)
REF="main"
for kv in "${EXTRA[@]:-}"; do [[ "$kv" == REF=* ]] && REF="${kv#REF=}"; done
SHORT_REF="$REF"; [[ ${#SHORT_REF} -eq 40 ]] && SHORT_REF="${SHORT_REF:0:7}"
DEFAULTS=(
  "NAME=${NAME}"
  "REGION=${SLS_REGION}"
  "REPO_URL=$(sls_default_repo "$KIND")"
  "REF=${REF}"
  "IMAGE=${GHCR_IMAGE}"
  "UI_MESSAGE=Hello from OVHcloud Serverless"
  "REVISION_LABEL=rev-${SHORT_REF}"
  "MOTD_THEME=ocean"
  "AI_ENDPOINTS_TOKEN=${AI_ENDPOINTS_TOKEN:-}"
)

EXISTING="$(sls_get_resource "$KIND" "$NAME")"
START=$(date +%s)
if [[ -n "$EXISTING" ]]; then
  ID="$(jq -r '.id' <<<"$EXISTING")"
  if (( CREATE_ONLY )); then
    log "$KIND '$NAME' already exists (id=$ID), --create-only: nothing to do"
    URL="$(jq -r '.currentState.url // empty' <<<"$EXISTING")"
    REV="$(jq -r '.currentState.latestReadyRevision // empty' <<<"$EXISTING")"
    echo "SLS_URL=${URL}"; echo "SLS_REVISION=${REV}"; echo "SLS_ELAPSED=0"
    exit 0
  fi
  CHECKSUM="$(jq -r '.checksum' <<<"$EXISTING")"
  PREV_REV="$(jq -r '.currentState.latestReadyRevision // 0' <<<"$EXISTING")"
  log "$KIND '$NAME' exists (id=$ID, checksum=$CHECKSUM, latestReady=$PREV_REV): updating"
  RENDERED="$(render_payload "$PAYLOAD" "${DEFAULTS[@]}" "CHECKSUM=${CHECKSUM}" "${EXTRA[@]:-}")"
  # Convert a create payload into a ResourceUpdate when needed.
  if ! jq -e 'has("checksum")' "$RENDERED" >/dev/null; then
    tmp="${RENDERED%.json}.upd.json"
    jq --arg c "$CHECKSUM" '{checksum: $c, targetSpec: (.targetSpec | del(.region))}' "$RENDERED" > "$tmp"
    mv "$tmp" "$RENDERED"
  fi
  MIN_REV="$PREV_REV"
  jq -e '.targetSpec | has("template")' "$RENDERED" >/dev/null && MIN_REV=$((PREV_REV + 1))
  api PUT "${KIND_PATH}/${ID}" --body "$RENDERED" --raw >/dev/null
  log "PUT accepted, waiting for READY (min revision ${MIN_REV})"
else
  RENDERED="$(render_payload "$PAYLOAD" "${DEFAULTS[@]}" "CHECKSUM=none" "${EXTRA[@]:-}")"
  jq -e 'has("checksum")' "$RENDERED" >/dev/null && die "'$NAME' does not exist and $PAYLOAD is an update payload; use a create payload"
  log "$KIND '$NAME' not found: creating"
  CREATED="$(api POST "$KIND_PATH" --body "$RENDERED" --raw)"
  ID="$(jq -r '.id' <<<"$CREATED")"
  [[ -n "$ID" && "$ID" != "null" ]] || die "POST did not return an id: $CREATED"
  MIN_REV=1
  log "created id=$ID, waiting for READY"
fi

ELAPSED="$(sls_wait_ready "$KIND" "$ID" "$TIMEOUT" "$MIN_REV")" || die "$KIND '$NAME' did not become READY"
FINAL="$(api GET "${KIND_PATH}/${ID}" --raw)"
URL="$(jq -r '.currentState.url // empty' <<<"$FINAL")"
REV="$(jq -r '.currentState.latestReadyRevision // empty' <<<"$FINAL")"
TOTAL=$(( $(date +%s) - START ))

printf '\n%-18s %s\n' "resource" "$KIND $NAME ($ID)"
printf '%-18s %ss (wait %ss)\n' "elapsed" "$TOTAL" "$ELAPSED"
printf '%-18s %s\n' "url" "$URL"
printf '%-18s %s\n' "latest revision" "$REV"
printf '%-18s %s\n\n' "traffic" "$(jq -c '.currentState.traffic' <<<"$FINAL")"
echo "SLS_URL=${URL}"; echo "SLS_REVISION=${REV}"; echo "SLS_ELAPSED=${TOTAL}"; echo "SLS_ID=${ID}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "url=${URL}"; echo "revision=${REV}"; echo "elapsed=${TOTAL}"; echo "id=${ID}"; } >> "$GITHUB_OUTPUT"
fi
