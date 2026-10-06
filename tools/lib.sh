#!/usr/bin/env bash
# Shared helpers for the Serverless alpha demo scripts. Source it, do not run it:
#   source "$(dirname "$0")/lib.sh"
#
# Provides:
#   log, warn, die, need_cmd CMD...
#   api METHOD PATH [args]            wrapper around tools/api.py (compact JSON)
#   sls_kind_path KIND                container|function -> serverless/<kind>
#   sls_get_resource KIND NAME        full resource JSON (empty if absent)
#   sls_id KIND NAME                  resource id (empty if absent)
#   sls_checksum KIND ID              current checksum for a ResourceUpdate
#   sls_url KIND ID                   currentState.url
#   sls_wait_ready KIND ID [TIMEOUT] [MIN_REVISION]
#                                     poll until READY (and latestReadyRevision
#                                     >= MIN_REVISION), prints elapsed seconds
#   render_payload FILE KEY=VAL...    sed {{KEY}} tokens into a *.tmp.json copy,
#                                     prints the temp path (cleaned at exit)
#   is_demo_name NAME                 true if NAME starts with demo-
#
# Sources tools/env.sh when present (gitignored, see env.example.sh).

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOADS_DIR="${TOOLS_DIR}/payloads"

# shellcheck disable=SC1091
if [[ -f "${TOOLS_DIR}/env.sh" ]]; then
  source "${TOOLS_DIR}/env.sh"
fi

: "${SLS_REGION:=EU-WEST-PAR}"
: "${SLS_API_PREFIX:=/v2}"
: "${DEMO_CONTAINER:=demo-podinfo-sls}"
: "${DEMO_FUNCTION:=demo-motd}"
: "${REPO_PODINFO:=https://github.com/antonin-a/podinfo-sls}"
: "${REPO_MOTD:=https://github.com/antonin-a/serverless-fn-motd}"
: "${GHCR_IMAGE:=ghcr.io/antonin-a/podinfo-sls:latest}"
: "${SLS_POLL_INTERVAL:=3}"
export SLS_REGION SLS_API_PREFIX

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
  done
}

api() {
  python3 "${TOOLS_DIR}/api.py" "$@"
}

sls_kind_path() {
  case "$1" in
    container|containers) echo "serverless/container" ;;
    function|functions)   echo "serverless/function" ;;
    *) die "unknown kind '$1' (expected container|function)" ;;
  esac
}

# The list endpoint is assumed to return a JSON array; an object wrapper with
# .resources or .items is tolerated.
sls_get_resource() {
  local kind="$1" name="$2" path
  path="$(sls_kind_path "$kind")"
  api GET "$path" --raw | jq -c --arg n "$name" '
    (if type == "array" then . else (.resources // .items // []) end)
    | map(select(.targetSpec.name == $n)) | .[0] // empty'
}

sls_id() {
  sls_get_resource "$1" "$2" | jq -r '.id // empty'
}

sls_checksum() {
  local kind="$1" id="$2"
  api GET "$(sls_kind_path "$kind")/${id}" --raw | jq -r '.checksum'
}

sls_url() {
  local kind="$1" id="$2"
  api GET "$(sls_kind_path "$kind")/${id}" --raw | jq -r '.currentState.url // empty'
}

# sls_wait_ready KIND ID [TIMEOUT_S=900] [MIN_REVISION=0]
# Polls the resource until resourceStatus == READY and
# currentState.latestReadyRevision is set (and >= MIN_REVISION when given).
# Prints one progress line per poll and "READY after Ns" at the end.
# Returns 1 on timeout or when resourceStatus becomes ERROR.
sls_wait_ready() {
  local kind="$1" id="$2" timeout="${3:-900}" min_rev="${4:-0}"
  local path start now elapsed res status lrr detail
  path="$(sls_kind_path "$kind")/${id}"
  start=$(date +%s)
  while :; do
    res="$(api GET "$path" --raw)" || return 1
    status="$(jq -r '.resourceStatus // "UNKNOWN"' <<<"$res")"
    lrr="$(jq -r '.currentState.latestReadyRevision // empty' <<<"$res")"
    detail="$(jq -r '[.currentState.revisions[]? | "r\(.number):\(.status)"] | join(" ")' <<<"$res")"
    now=$(date +%s); elapsed=$((now - start))
    printf '\r  %4ds  status=%-10s latestReady=%-4s %s' "$elapsed" "$status" "${lrr:-none}" "$detail" >&2
    if [[ "$status" == "READY" && -n "$lrr" && "$lrr" -ge "$min_rev" ]]; then
      printf '\n' >&2
      log "READY after ${elapsed}s (latestReadyRevision=${lrr})"
      echo "$elapsed"
      return 0
    fi
    if [[ "$status" == "ERROR" ]]; then
      printf '\n' >&2
      warn "resource entered ERROR after ${elapsed}s"
      jq '.currentState' <<<"$res" >&2
      return 1
    fi
    if (( elapsed >= timeout )); then
      printf '\n' >&2
      warn "timeout after ${elapsed}s waiting for READY"
      return 1
    fi
    sleep "$SLS_POLL_INTERVAL"
  done
}

# Rendered payloads are named <payload>.<pid>.tmp.json; render_payload usually
# runs inside $(...), so cleanup globs on the pid instead of tracking a list.
_sls_cleanup() {
  rm -f "${TOOLS_DIR}"/*."$$".tmp.json 2>/dev/null || true
}
trap _sls_cleanup EXIT

_sed_escape() {
  # escape the sed replacement specials for the | delimiter
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# render_payload FILE KEY=VAL...  -> prints path of rendered temp file
# FILE may be a bare name resolved under payloads/. Dies if a {{TOKEN}} is left.
render_payload() {
  local src="$1"; shift
  [[ -f "$src" ]] || src="${PAYLOADS_DIR}/${src}"
  [[ -f "$src" ]] || die "payload not found: $1"
  local out="${TOOLS_DIR}/$(basename "${src%.json}").$$.tmp.json"
  local expr="" kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    expr+="s|{{${key}}}|$(_sed_escape "$val")|g;"
  done
  sed -e "$expr" "$src" > "$out"
  if grep -qo '{{[A-Z_]*}}' "$out"; then
    warn "unrendered tokens in $(basename "$src"): $(grep -o '{{[A-Z_]*}}' "$out" | sort -u | tr '\n' ' ')"
    rm -f "$out"
    return 1
  fi
  echo "$out"
}

is_demo_name() {
  [[ "$1" == demo-* ]]
}

# default repo URL for a kind
sls_default_repo() {
  case "$1" in
    container*) echo "$REPO_PODINFO" ;;
    function*)  echo "$REPO_MOTD" ;;
  esac
}
