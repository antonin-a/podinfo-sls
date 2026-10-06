# Serverless alpha demo tooling

Stage tooling for the OVHcloud Serverless alpha demo (APIv2, base path
`/publicCloud/project/{projectId}`). Everything here is self-contained: the
application itself lives at the repository root and is owned separately.

Safety rule: every script that creates, updates or deletes only touches
resources whose `targetSpec.name` starts with `demo-`. Anything else in the
project is left alone.

## Prerequisites

| need | why | install |
|---|---|---|
| python3 + `python-ovh` | `api.py` signs every API call | `pip3 install ovh` (>= 1.1 for OAuth2 and full endpoint URLs) |
| `jq` | JSON parsing in bash | `brew install jq` |
| `curl` | HTTP checks, cold start timing | preinstalled |
| Go >= 1.22 | `tools/load` fallback load generator | `brew install go` |
| `oha` (optional) | nicer load generator, used first when present | `brew install oha` |
| `docker` (optional) | GHCR manifest check in preflight | Docker Desktop |

## Configuration

1. Credentials: copy `ovh.conf.example` to `~/.ovh.conf` (`chmod 600`), fill
   the `[serverless-alpha]` section with the alpha gateway URL and either
   AK/AS/CK or an OAuth2 `client_id` / `client_secret`. `[default] endpoint`
   selects the profile. The `[ovh-cli]` section is only read by the
   `ovhcloud` CLI, which shares this file.
2. Environment: `cp env.example.sh env.sh` and fill in `OVH_CLOUD_PROJECT`,
   `AI_ENDPOINTS_TOKEN`, and adjust names if needed. `env.sh` is sourced by
   every script through `lib.sh`.
3. API prefix: calls go to `$SLS_API_PREFIX + /publicCloud/project/<id>/...`
   with `SLS_API_PREFIX=/v2` by default. If the gateway URL in `ovh.conf`
   already ends with `/v2`, set `SLS_API_PREFIX=""`.

Gitignore entries to add at the repository root (this directory does not own
the root `.gitignore`):

```
tools/env.sh
tools/*.tmp.json
```

## Scripts

| script | purpose |
|---|---|
| `api.py` / `api.sh` | Generic APIv2 client: `api.sh GET serverless/quota`, `api.sh POST serverless/container --body file.json`, `api.sh GET .../logs --query since=... --query limit=100`. Pretty JSON by default, `--raw` for compact. Non-zero exit with the OVH error class and message on stderr. |
| `lib.sh` | Shared helpers (sourced, not run): `need_cmd`, `api`, `sls_get_resource`, `sls_id`, `sls_checksum`, `sls_url`, `sls_wait_ready` (prints real elapsed seconds), `render_payload`. |
| `preflight.sh` | H-1 read-only checks: API reachable, runtime `python3.12`, flavor cpu 1 / memory 512, region, GitHub repos and branches, GHCR manifest, AI Endpoints token, local tools. PASS/FAIL table, exit 1 on any FAIL. |
| `seed.sh` | Idempotent starting state: `demo-podinfo-sls` (container, ref main, revision 1) and `demo-motd` (function) created only if missing, waits READY, prints URLs. `--skip-function` when no AI token. |
| `reset.sh` | Deletes every `demo-*` resource (confirmation unless `--yes`), waits until gone, `--seed` to reseed right after. |
| `deploy.sh` | Create-or-update + wait READY: `deploy.sh <container|function> <name> <payload> [KEY=VAL ...] [--create-only]`. Fetches the checksum before a PUT, converts a create payload into a `ResourceUpdate` when the resource exists, prints elapsed / URL / latest revision, and writes `url`, `revision`, `elapsed`, `id` to `$GITHUB_OUTPUT` in CI. |
| `traffic.sh` | `traffic.sh <name> canary|promote|rollback [stable_rev] [canary_rev]`: 90/10 split tagged `green`, promote to 100 %, or roll back. Prints the resulting `currentState.traffic`. |
| `canary-colors.sh` | `canary-colors.sh <url> [duration]`: one updating line with the colour histogram of `/api/info`, final summary. |
| `coldstart.sh` | Waits for `readyInstances == 0`, measures cold TTFB with curl, two warm calls, then compares with the API `invoke` route (`latencyMs`, `coldStart`). |
| `tail-logs.sh` | `tail-logs.sh <kind> <name> [revision]`: polls the logs route every second with a moving `since`, prints `ts level message`. |
| `metrics.sh` | `metrics.sh <kind> <name> [PT1H] [--series]`: compact table of the aggregated metrics plus the raw JSON. |
| `load.sh` / `load/` | `load.sh <url> [rps] [duration] [path]`: fixed-rate load through `oha` if installed, else the standard-library Go tool in `load/` (own module, prints req/s, p50/p95/p99, status and colour histograms every 5 s). |

Every script answers `--help`.

## Payloads

`payloads/*.json` contain `{{PLACEHOLDER}}` tokens that `render_payload`
replaces with `sed`. Create payloads carry `targetSpec` only; update payloads
are full `ResourceUpdate` bodies with `"checksum": "{{CHECKSUM}}"` (the
scripts GET the current checksum first; a stale checksum is refused with 412).

| payload | use |
|---|---|
| `container-from-repo.json` | create from GitHub source (`REF`, port 9898, env `SLS_UI_MESSAGE` + `SLS_REVISION_LABEL`, HTTP+SSE, cpu 1 / 512 MiB, autoscale 0..10, idle 60 s, rollbackErrorThreshold 5) |
| `container-from-image.json` | same, from `ghcr.io/antonin-a/podinfo-sls:latest` |
| `container-revision-green.json` | update: template on ref `green` (new revision), traffic stable 90 / latest 10 |
| `traffic-canary.json` | update: stable 90 / canary 10 tagged `green` (tags only on pinned revisions) |
| `traffic-promote.json` | update: canary 100 |
| `traffic-rollback.json` | update: stable 100 |
| `container-broken-build.json` | update: template on ref `broken-dockerfile`, traffic pinned on stable (build failure scene) |
| `function-motd-from-repo.json` | create function `python3.12`, entrypoint `main`, env `MOTD_THEME`, secret `AI_ENDPOINTS_TOKEN` |
| `function-motd-prompt-v2.json` | update function to ref `prompt-v2` |
| `scaling-manual-2.json` / `scaling-auto.json` | update scaling (no revision created) |
| `trigger-cron.json` | `POST .../trigger`: CRON every 5 min, `POST /events` |
| `invoke-info.json` | body for `POST .../invoke` |
| `feedback.json` | body for `POST serverless/feedback` |

Placeholders: `NAME`, `REGION`, `REPO_URL`, `REF`, `IMAGE`, `UI_MESSAGE`,
`REVISION_LABEL`, `MOTD_THEME`, `AI_ENDPOINTS_TOKEN`, `CHECKSUM`,
`STABLE_REV`, `CANARY_REV`, `MESSAGE`. `deploy.sh` fills sensible defaults;
anything passed as `KEY=VAL` wins.

Disabling a service is a console action: the API does not accept manual
scaling pinned to 0 instances (minimum 1), so there is no "disable" payload.

## Full rehearsal

```bash
# H-1
tools/preflight.sh

# starting state (revision 1 of the container + the function)
tools/seed.sh

# scene: deploy a second revision from branch green, split traffic, watch colours
tools/deploy.sh container demo-podinfo-sls tools/payloads/container-revision-green.json REF=green REVISION_LABEL=rev-green
tools/traffic.sh demo-podinfo-sls canary            # 90 % r1, 10 % r2 tagged green
tools/canary-colors.sh "$(tools/api.sh GET serverless/container --raw | jq -r '.[] | select(.targetSpec.name=="demo-podinfo-sls") | .currentState.url')" 30
tools/traffic.sh demo-podinfo-sls promote           # 100 % r2
tools/traffic.sh demo-podinfo-sls rollback 1        # back to r1

# scene: logs, load, metrics, cold start
tools/tail-logs.sh container demo-podinfo-sls
tools/load.sh "$URL" 20 60s /api/info
tools/metrics.sh container demo-podinfo-sls PT1H
tools/coldstart.sh container demo-podinfo-sls

# scene: failed build (traffic stays on the stable revision)
tools/deploy.sh container demo-podinfo-sls tools/payloads/container-broken-build.json STABLE_REV=1

# scene: function update
tools/deploy.sh function demo-motd tools/payloads/function-motd-prompt-v2.json

# cleanup and back to the starting state
tools/reset.sh --yes --seed
```

`sls_wait_ready` prints the real seconds between the API call and
`resourceStatus == READY`, so the numbers quoted on stage come from the clock,
not from a slide.

## GitHub workflows

- `.github/workflows/build-image.yml`: multi-arch image to GHCR on push to
  `main` (`:latest` + `:<sha>`) and on tags `v*` (`:<tag>`).
- `.github/workflows/deploy-on-push.yml`: redeploys `demo-podinfo-sls` from
  the pushed commit (`REF=$GITHUB_SHA`). Disabled unless the repository
  variable `SLS_DEPLOY_ENABLED` is `true`. Needs secrets `OVH_ENDPOINT`,
  `OVH_CLIENT_ID`, `OVH_CLIENT_SECRET` (OAuth2 service account) and the
  variable `OVH_CLOUD_PROJECT`. The job summary shows URL, revision and
  elapsed seconds.

## Assumptions about the alpha API

These are encoded leniently (several field spellings tried) and are the first
things to check against the real gateway:

- list routes return a JSON array (an object with `resources` or `items` is
  also accepted);
- `GET serverless/resource` items expose `kind` (`CONTAINER` / `FUNCTION`);
  when absent, the kind is inferred from `targetSpec.template`;
- the runtime catalogue items have `name` (or `id`) and an optional `status`;
  flavors have `cpu` / `memory`; regions are strings or objects with `name`;
- log entries are an array ordered oldest first with `timestamp`, `level`,
  `message`;
- metrics field names (`requests`, `latency.p95`, `instances.avg`, ...) are
  guesses; `metrics.sh` always prints the raw JSON too;
- `python-ovh` accepts a full URL as `endpoint` in `ovh.conf` (>= 1.1). On an
  older version `api.py` falls back to a named region and patches the base
  URL itself (AK/AS/CK only).
