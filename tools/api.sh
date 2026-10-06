#!/usr/bin/env bash
# Thin wrapper around tools/api.py so CI and other scripts can call
#   tools/api.sh GET serverless/quota
# without caring where the Python CLI lives. All arguments are forwarded.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${HERE}/env.sh" ]] && source "${HERE}/env.sh"
exec python3 "${HERE}/api.py" "$@"
