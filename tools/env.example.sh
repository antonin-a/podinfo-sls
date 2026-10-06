#!/usr/bin/env bash
# Environment for the Serverless alpha demo tooling.
# Copy to tools/env.sh (gitignored), fill in the values, then every script
# in tools/ sources it automatically.
#
#   cp tools/env.example.sh tools/env.sh
#   $EDITOR tools/env.sh

# Public Cloud project that hosts the demo resources.
export OVH_CLOUD_PROJECT="<PROJECT_ID>"

# Region used by every create payload.
export SLS_REGION="EU-WEST-PAR"

# Path prefix prepended to every API call. Keep /v2 unless the gateway URL
# in ovh.conf already includes it (then set it to an empty string).
export SLS_API_PREFIX="/v2"

# Credentials file read by python-ovh (defaults to ~/.ovh.conf).
export OVH_CONFIG_FILE="${HOME}/.ovh.conf"

# Demo resource names. Scripts only ever touch resources named demo-*.
export DEMO_CONTAINER="demo-podinfo-sls"
export DEMO_FUNCTION="demo-motd"

# Source repositories built by the platform.
export REPO_PODINFO="https://github.com/antonin-a/podinfo-sls"
export REPO_MOTD="https://github.com/antonin-a/serverless-fn-motd"

# Prebuilt image used by payloads/container-from-image.json.
export GHCR_IMAGE="ghcr.io/antonin-a/podinfo-sls:latest"

# AI Endpoints token injected as a secret into the demo-motd function.
export AI_ENDPOINTS_TOKEN="<AI_ENDPOINTS_TOKEN>"
