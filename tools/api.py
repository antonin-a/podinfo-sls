#!/usr/bin/env python3
"""Minimal CLI over python-ovh for the OVHcloud Serverless alpha (APIv2).

Usage:
  api.py GET    <path> [--query k=v ...] [--raw]
  api.py POST   <path> [--body file.json|-] [--raw]
  api.py PUT    <path> [--body file.json|-] [--raw]
  api.py DELETE <path> [--raw]
  api.py --help

<path> is relative to /publicCloud/project/$OVH_CLOUD_PROJECT/ unless it
starts with a slash, in which case it is used verbatim (after the prefix).
The full request path is:  $SLS_API_PREFIX + /publicCloud/project/<id>/<path>

Environment:
  OVH_CLOUD_PROJECT  Public Cloud project id (required for relative paths)
  SLS_API_PREFIX     path prefix, default "/v2". Set to "" if the endpoint
                     URL in ovh.conf already ends with /v2.
  OVH_CONFIG_FILE    ini file read by python-ovh (default ~/.ovh.conf)
  OVH_ENDPOINT       profile name or full URL; overrides [default] endpoint

Examples:
  api.py GET serverless/quota
  api.py GET serverless/container/abc/logs --query since=2026-10-06T10:00:00Z --query limit=200
  api.py POST serverless/container --body payloads/container.tmp.json
  api.py PUT  serverless/container/abc --body -   < update.json
  api.py DELETE serverless/container/abc

Exit codes: 0 ok, 1 API error (class and message on stderr), 2 usage,
3 python-ovh not installed (pip3 install ovh).

Prerequisite: pip3 install ovh   (python-ovh >= 1.1 for OAuth2 and for full
endpoint URLs in ovh.conf). Older versions only know the named endpoints
(ovh-eu, ovh-ca, ...); this script then patches the client endpoint itself.
"""

import argparse
import json
import os
import sys
from urllib.parse import urlencode



def import_ovh():
    """Import python-ovh lazily so --help works without it."""
    try:
        import ovh
        import ovh.exceptions  # noqa: F401
    except ImportError:
        sys.stderr.write("api.py: python-ovh is not installed, run: pip3 install ovh\n")
        sys.exit(3)
    return ovh


def build_client():
    ovh = import_ovh()
    """Create the python-ovh client from ovh.conf / environment.

    python-ovh resolves the endpoint name from [default] endpoint, then reads
    the matching section. If that section's own `endpoint=` is a full URL
    (alpha gateway) and the installed python-ovh rejects it with
    InvalidRegion, fall back to a known region and override the base URL.
    """
    config_file = os.environ.get("OVH_CONFIG_FILE") or None
    endpoint = os.environ.get("OVH_ENDPOINT") or None
    try:
        return ovh.Client(endpoint=endpoint, config_file=config_file)
    except ovh.exceptions.InvalidRegion:
        # Old python-ovh: read the URL ourselves and patch the client.
        from ovh.config import ConfigurationManager

        cfg = ConfigurationManager()
        if config_file:
            cfg.config.read(config_file)
        profile = endpoint or cfg.get("default", "endpoint")
        url = cfg.get(profile, "endpoint")
        if not url or not url.startswith("http"):
            raise
        client = ovh.Client(
            endpoint="ovh-eu",
            application_key=cfg.get(profile, "application_key"),
            application_secret=cfg.get(profile, "application_secret"),
            consumer_key=cfg.get(profile, "consumer_key"),
        )
        client._endpoint = url.rstrip("/")
        return client


def full_path(rel_path):
    prefix = os.environ.get("SLS_API_PREFIX", "/v2").rstrip("/")
    if rel_path.startswith("/"):
        return prefix + rel_path
    project = os.environ.get("OVH_CLOUD_PROJECT")
    if not project:
        sys.stderr.write("api.py: OVH_CLOUD_PROJECT is not set\n")
        sys.exit(2)
    return "%s/publicCloud/project/%s/%s" % (prefix, project, rel_path)


def read_body(spec):
    if spec is None:
        return None
    raw = sys.stdin.read() if spec == "-" else open(spec, "r", encoding="utf-8").read()
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.stderr.write("api.py: body is not valid JSON: %s\n" % exc)
        sys.exit(2)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="api.py",
        description="OVHcloud APIv2 Serverless helper (see module docstring)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("method", choices=["GET", "POST", "PUT", "DELETE"])
    parser.add_argument("path", help="path relative to /publicCloud/project/<id>/")
    parser.add_argument("--query", action="append", default=[], metavar="k=v",
                        help="query parameter (repeatable)")
    parser.add_argument("--body", metavar="file.json|-", help="JSON body file or - for stdin")
    parser.add_argument("--raw", action="store_true", help="compact JSON output")
    args = parser.parse_args(argv)

    path = full_path(args.path)
    if args.query:
        pairs = []
        for item in args.query:
            if "=" not in item:
                parser.error("--query expects k=v, got %r" % item)
            k, v = item.split("=", 1)
            pairs.append((k, v))
        path += ("&" if "?" in path else "?") + urlencode(pairs)

    body = read_body(args.body) if args.method in ("POST", "PUT") else None

    ovh = import_ovh()
    client = build_client()
    try:
        result = client.call(args.method, path, body, True)
    except ovh.exceptions.APIError as exc:
        sys.stderr.write("api.py: %s %s failed: %s: %s\n"
                         % (args.method, path, exc.__class__.__name__, exc))
        return 1

    if result is None:
        return 0
    if args.raw:
        sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    else:
        sys.stdout.write(json.dumps(result, indent=2, sort_keys=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
