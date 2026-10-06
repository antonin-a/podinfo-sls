# podinfo-sls

A tiny Go web application that makes serverless runtime behaviour visible on stage.
It is the demo container of the OVHcloud Serverless alpha: cold starts, instance
identity, revisions driven by environment variables, canary colour alternation,
scale to zero, health probes, chaos endpoints, Server-Sent Events, a CloudEvents
receiver and structured JSON logs.

podinfo-sls is inspired by [podinfo](https://github.com/stefanprodan/podinfo) by
Stefan Prodan (Apache 2.0). It is a compact, standard-library-only rewrite with a
serverless focus; see `NOTICE`.

## Why

When you demo a serverless platform you need an app that *shows* what is happening:
which instance answered, whether it was just started, which revision is live, how
traffic splits between two revisions, what the platform does when the app is slow,
crashes or receives an event. podinfo-sls does only that, in one static binary with
no dependencies, so the platform can build it live in a few seconds.

## Configuration

Everything is driven by environment variables. Every variable has a default.

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `9898` | Listen port. Injected by the platform. `-port` flag overrides it. |
| `SLS_UI_COLOR` | `#000E9C` | Colour of the top band on `/`. Change it between revisions to see canaries. |
| `SLS_UI_MESSAGE` | `Hello from OVHcloud Serverless` | Headline on `/`. |
| `SLS_UI_LOGO` | empty | URL of a logo. Empty renders a `podinfo-sls` text wordmark. |
| `SLS_REVISION_LABEL` | `rev-unknown` | Free text shown in the UI, in `/api/info`, in every log line and in `X-Revision-Label`. |
| `SLS_VERSION` | build value or `dev` | Version string. Set at build with `-ldflags "-X main.version=..."`; the env var overrides it. |
| `SLS_FAIL_EVENTS` | `false` | When `true`, `POST /events` answers 500 to demonstrate retries and dead-lettering. |
| `SLS_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error`. Probes are logged at `debug`. |
| `SLS_SECRET_*` | none | Any variable with this prefix is masked in `/api/env` (length and sha256 prefix only). |

## Routes

| Route | Description |
|---|---|
| `GET /` | HTML page: colour band, message, version, revision label, Instance card (hostname, instanceId, startedAt, uptime, requestsServed, cold start badge), Runtime card. Add `?refresh=1` to reload every 2s. |
| `GET /api/info` | JSON instance and revision metadata, including `coldStart` (uptime under 5s). |
| `GET /api/env` | JSON of `PORT` and all `SLS_*` variables, sorted, secrets masked. |
| `GET /healthz` | Liveness, always `200 {"status":"ok"}`. |
| `GET /readyz` | Readiness, `200` or `503` when disabled. |
| `POST /readyz/disable`, `POST /readyz/enable` | Toggle readiness. |
| `GET /delay/{seconds}` | Sleeps (cap 60s) then returns `{"delay": n}`. |
| `GET /status/{code}` | Returns that HTTP status with `{"status": code}`. |
| `GET /panic` | Logs then exits with code 255 (simulated crash). |
| `GET /burn/cpu?s=N` | Busy-loops every CPU for N seconds (cap 30). |
| `GET /burn/mem?mb=N` | Allocates and touches N MiB (cap 2048) and keeps it referenced. |
| `GET /burn/mem/release` | Drops held memory and returns it to the OS. |
| `GET /stream?s=N` | Server-Sent Events, one `tick` event per second for N seconds (cap 300). |
| `POST /events` | CloudEvents receiver, structured (`application/cloudevents+json`) and binary (`ce-*` headers) modes. `202` or `500` when `SLS_FAIL_EVENTS=true`. |
| `GET /events` | Last 20 received events, newest first. |
| anything else | `404` JSON. |

Every response carries `X-Instance-Id`, `X-Revision-Label` and `X-Served-By: podinfo-sls/<version>`.

Logs are JSON lines on stdout (`log/slog`): one line per request with method, path,
status, duration, instance id, revision label, remote address and user agent;
`instance started` at boot; `SIGTERM received, draining` then `instance stopped`
on shutdown (10s drain timeout).

## Run locally

```sh
go run .
# or
go build -ldflags "-X main.version=0.1.0" -o podinfo-sls . && ./podinfo-sls -port 8080

# container
docker build -t podinfo-sls:dev --build-arg VERSION=0.1.0 .
docker run --rm -e PORT=8080 -p 8080:8080 \
  -e SLS_UI_COLOR='#0050D7' -e SLS_REVISION_LABEL=blue podinfo-sls:dev
```

Open <http://localhost:8080/?refresh=1>.

## Example calls

```sh
BASE=http://localhost:8080

curl -s $BASE/api/info | jq
curl -s $BASE/api/env | jq
curl -si $BASE/healthz | head -1
curl -s $BASE/status/418
curl -s $BASE/delay/2
curl -s "$BASE/burn/cpu?s=3"
curl -s "$BASE/burn/mem?mb=256" && curl -s $BASE/burn/mem/release
curl -N "$BASE/stream?s=5"

# readiness toggle
curl -s -X POST $BASE/readyz/disable; curl -si $BASE/readyz | head -1
curl -s -X POST $BASE/readyz/enable

# CloudEvent, structured mode
curl -s -X POST $BASE/events \
  -H 'Content-Type: application/cloudevents+json' \
  -d '{
    "specversion": "1.0",
    "id": "evt-001",
    "type": "com.ovhcloud.demo.order.created",
    "source": "/demo/checkout",
    "subject": "order/42",
    "time": "2026-10-06T10:00:00Z",
    "datacontenttype": "application/json",
    "data": {"orderId": 42, "amount": 19.9}
  }'

# CloudEvent, binary mode
curl -s -X POST $BASE/events \
  -H 'ce-specversion: 1.0' -H 'ce-id: evt-002' \
  -H 'ce-type: com.ovhcloud.demo.order.paid' -H 'ce-source: /demo/payments' \
  -H 'ce-subject: order/42' -H 'Content-Type: application/json' \
  -d '{"orderId": 42}'

curl -s $BASE/events | jq

# simulate a crash
curl -s $BASE/panic
```

## Demo branches

The repository is meant to be deployed straight from Git by the platform. Two
branches support the live demo:

- `green`: changes the default colour and message in code (`internal/app/config.go`),
  so that deploying it next to `main` produces a visible blue/green or canary
  alternation when the page auto-refreshes, without touching any environment variable.
- `broken-dockerfile`: breaks the `Dockerfile` on purpose (for example a wrong base
  image or a bad build command) to show how the platform reports a failed build and
  keeps the previous revision serving traffic.

## Credits

Inspired by [stefanprodan/podinfo](https://github.com/stefanprodan/podinfo), licensed
under the Apache License 2.0. Thank you Stefan.
