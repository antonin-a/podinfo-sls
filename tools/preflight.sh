#!/usr/bin/env bash
# preflight.sh : H-1 read-only checks before the demo.
#
# Usage: tools/preflight.sh [--help]
#
# Checks (nothing is created or modified):
#   - local tools: python3 + python-ovh, jq, curl; go / oha / docker optional
#   - env: OVH_CLOUD_PROJECT, OVH_CONFIG_FILE present
#   - API reachable: GET serverless/quota
#   - runtime catalogue has python3.12 available
#   - flavor catalogue has cpu 1 / memory 512
#   - region catalogue has $SLS_REGION
#   - GitHub repos reachable over https, raw Dockerfile reachable,
#     demo branches (green, broken-dockerfile, prompt-v2) exist (warn only)
#   - GHCR image manifest reachable (docker manifest inspect or token flow)
#   - AI Endpoints token accepted (GET /v1/models == 200)
# Prints a PASS/FAIL/WARN/SKIP table; exits 1 if any check FAILed.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0
fi

ROWS=()
FAILS=0
add() { # add STATUS NAME DETAIL
  ROWS+=("$1|$2|$3")
  [[ "$1" == "FAIL" ]] && FAILS=$((FAILS + 1)) || true
}
http_code() { curl -sSL -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null || echo "000"; }

# 1. local tools
for c in python3 jq curl; do
  if command -v "$c" >/dev/null 2>&1; then add PASS "tool $c" "$(command -v "$c")"; else add FAIL "tool $c" "not found"; fi
done
for c in go oha docker; do
  if command -v "$c" >/dev/null 2>&1; then add PASS "tool $c (optional)" "$(command -v "$c")"; else add WARN "tool $c (optional)" "not found"; fi
done
if python3 -c 'import ovh' 2>/dev/null; then
  add PASS "python-ovh" "$(python3 -c 'import ovh; print(getattr(ovh, "__version__", "?"))')"
else
  add FAIL "python-ovh" "pip3 install ovh"
fi

# 2. environment
[[ -n "${OVH_CLOUD_PROJECT:-}" ]] && add PASS "OVH_CLOUD_PROJECT" "$OVH_CLOUD_PROJECT" || add FAIL "OVH_CLOUD_PROJECT" "unset (copy env.example.sh to env.sh)"
cfg="${OVH_CONFIG_FILE:-$HOME/.ovh.conf}"
[[ -f "$cfg" ]] && add PASS "ovh.conf" "$cfg" || add FAIL "ovh.conf" "$cfg missing"
add PASS "SLS_API_PREFIX" "'${SLS_API_PREFIX}' (set to '' if the endpoint URL already ends with /v2)"

# 3. API reachability and catalogues
if quota="$(api GET serverless/quota --raw 2>/tmp/preflight.err.$$)"; then
  add PASS "API GET serverless/quota" "$(jq -c '.' <<<"$quota" | cut -c1-70)"
  if rt="$(api GET reference/serverless/runtime --raw 2>/dev/null)"; then
    if jq -e '[ (if type=="array" then .[] else (.runtimes // .items // [])[] end)
               | select(((.name // .id // .runtime // "") == "python3.12")
                        and (((.status // .availability // "AVAILABLE") | ascii_upcase) | test("AVAILABLE|GA|BETA|ALPHA")))
             ] | length > 0' <<<"$rt" >/dev/null; then
      add PASS "runtime python3.12" "available"
    else
      add FAIL "runtime python3.12" "not found or not available in catalogue"
    fi
  else
    add FAIL "reference/serverless/runtime" "request failed"
  fi
  if fl="$(api GET reference/serverless/flavor --raw 2>/dev/null)"; then
    if jq -e '[ (if type=="array" then .[] else (.flavors // .items // [])[] end)
               | select(((.cpu // .resources.cpu) == 1) and ((.memory // .resources.memory) == 512))
             ] | length > 0' <<<"$fl" >/dev/null; then
      add PASS "flavor cpu 1 / memory 512" "present"
    else
      add FAIL "flavor cpu 1 / memory 512" "not in catalogue"
    fi
  else
    add FAIL "reference/serverless/flavor" "request failed"
  fi
  if rg="$(api GET reference/serverless/region --raw 2>/dev/null)"; then
    if jq -e --arg r "$SLS_REGION" '[ (if type=="array" then .[] else (.regions // .items // [])[] end)
               | (if type=="string" then . else (.name // .id // .region // "") end)
               | select(. == $r) ] | length > 0' <<<"$rg" >/dev/null; then
      add PASS "region $SLS_REGION" "present"
    else
      add FAIL "region $SLS_REGION" "not in catalogue"
    fi
  else
    add FAIL "reference/serverless/region" "request failed"
  fi
else
  add FAIL "API GET serverless/quota" "$(tr '\n' ' ' </tmp/preflight.err.$$ | cut -c1-90)"
  add SKIP "runtime / flavor / region catalogues" "API unreachable"
fi
rm -f /tmp/preflight.err.$$

# 4. GitHub
for repo in "$REPO_PODINFO" "$REPO_MOTD"; do
  code="$(http_code -I "$repo")"
  [[ "$code" == "200" ]] && add PASS "repo $repo" "HTTP $code" || add FAIL "repo $repo" "HTTP $code"
done
raw_df="${REPO_PODINFO/github.com/raw.githubusercontent.com}/main/Dockerfile"
code="$(http_code -I "$raw_df")"
[[ "$code" == "200" ]] && add PASS "raw Dockerfile (main)" "HTTP $code" || add FAIL "raw Dockerfile (main)" "HTTP $code $raw_df"
for b in green broken-dockerfile; do
  code="$(http_code -I "${REPO_PODINFO}/tree/${b}")"
  [[ "$code" == "200" ]] && add PASS "branch podinfo-sls:$b" "HTTP $code" || add WARN "branch podinfo-sls:$b" "HTTP $code (needed for canary / broken build scenes)"
done
code="$(http_code -I "${REPO_MOTD}/tree/prompt-v2")"
[[ "$code" == "200" ]] && add PASS "branch serverless-fn-motd:prompt-v2" "HTTP $code" || add WARN "branch serverless-fn-motd:prompt-v2" "HTTP $code (needed for function update scene)"

# 5. GHCR image
img_repo="${GHCR_IMAGE#ghcr.io/}"; img_repo="${img_repo%%:*}"; img_tag="${GHCR_IMAGE##*:}"
if command -v docker >/dev/null 2>&1 && docker manifest inspect "$GHCR_IMAGE" >/dev/null 2>&1; then
  add PASS "GHCR $GHCR_IMAGE" "docker manifest inspect ok"
else
  tok="$(curl -s --max-time 15 "https://ghcr.io/token?scope=repository:${img_repo}:pull" | jq -r '.token // empty' 2>/dev/null || true)"
  if [[ -n "$tok" ]]; then
    code="$(http_code -H "Authorization: Bearer $tok" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/${img_repo}/manifests/${img_tag}")"
    [[ "$code" == "200" ]] && add PASS "GHCR $GHCR_IMAGE" "manifest HTTP $code (token flow)" || add FAIL "GHCR $GHCR_IMAGE" "manifest HTTP $code (is the package public and pushed by build-image.yml?)"
  else
    add FAIL "GHCR $GHCR_IMAGE" "could not obtain anonymous pull token"
  fi
fi

# 6. AI Endpoints token
if [[ -z "${AI_ENDPOINTS_TOKEN:-}" || "$AI_ENDPOINTS_TOKEN" == "<AI_ENDPOINTS_TOKEN>" ]]; then
  add FAIL "AI_ENDPOINTS_TOKEN" "unset or placeholder"
else
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $AI_ENDPOINTS_TOKEN" https://oai.endpoints.kepler.ai.cloud.ovh.net/v1/models || echo 000)"
  [[ "$code" == "200" ]] && add PASS "AI Endpoints token" "GET /v1/models HTTP $code" || add FAIL "AI Endpoints token" "GET /v1/models HTTP $code"
fi

# Report
printf '\n%-6s %-42s %s\n' STATUS CHECK DETAIL
printf '%-6s %-42s %s\n' ------ ------------------------------------------ ------
for row in "${ROWS[@]}"; do
  IFS='|' read -r st name detail <<<"$row"
  printf '%-6s %-42s %s\n' "$st" "$name" "$detail"
done
printf '\n'
if (( FAILS > 0 )); then
  echo "preflight: $FAILS check(s) FAILED" >&2
  exit 1
fi
echo "preflight: all checks passed"
