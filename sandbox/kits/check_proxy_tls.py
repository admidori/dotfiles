#!/usr/bin/env python3
"""Preflight TLS proxy interception check.

Connects to the OAuth endpoints (auth.openai.com and/or oauth2.googleapis.com)
through HTTPS_PROXY using standard HTTP CONNECT and ssl to verify that outbound connections are actively
intercepted by the Docker Sandbox proxy CA (Docker Sandboxes Proxy CA).

Supports explicit service selection via --service ('openai', 'antigravity', or 'both', default 'both').
Selecting 'antigravity' tests only Google OAuth endpoints and never contacts OpenAI.
Exits 0 if selected endpoints are intercepted by Docker Sandboxes Proxy CA; exits 1 otherwise.

Outputs strictly certificate issuer information and boolean interception status.
Never reads or accesses secrets, tokens, or credentials.
"""

import argparse
import http.client
import os
import ssl
import sys
import urllib.parse

OPENAI_ENDPOINT = ("auth.openai.com", 443)
ANTIGRAVITY_ENDPOINT = ("oauth2.googleapis.com", 443)

SERVICES = {
    "openai": [OPENAI_ENDPOINT],
    "antigravity": [ANTIGRAVITY_ENDPOINT],
    "both": [OPENAI_ENDPOINT, ANTIGRAVITY_ENDPOINT],
}

EXPECTED_PROXY_CA_CN = "Docker Sandboxes Proxy CA"


def check_endpoint_issuer(host: str, port: int = 443, timeout: float = 5.0) -> tuple[bool, str]:
    """Connect to host:port, extract TLS peer certificate issuer, and verify proxy CA."""
    ctx = ssl.create_default_context()
    try:
        proxy = urllib.parse.urlsplit(os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy", ""))
        if proxy.scheme != "http" or not proxy.hostname or proxy.username or proxy.password:
            return False, "supported proxy configured: False"
        conn = http.client.HTTPSConnection(proxy.hostname, proxy.port or 80,
                                           context=ctx, timeout=timeout)
        conn.set_tunnel(host, port)
        try:
            conn.connect()
            issuer_dict = {key: val for rdn in conn.sock.getpeercert().get("issuer", ())
                           for key, val in rdn}
            issuer_repr = ", ".join(f"{k}={v}" for k, v in issuer_dict.items())
            return issuer_dict.get("commonName") == EXPECTED_PROXY_CA_CN, issuer_repr
        finally:
            conn.close()
    except Exception as exc:
        return False, f"connection failed ({exc.__class__.__name__})"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Preflight TLS proxy interception check."
    )
    parser.add_argument(
        "--service",
        choices=["openai", "antigravity", "both"],
        default="both",
        help="Service to check: 'openai', 'antigravity', or 'both' (default: 'both')",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    endpoints = SERVICES[args.service]

    all_intercepted = True

    for host, port in endpoints:
        is_intercepted, issuer_str = check_endpoint_issuer(host, port)
        print(f"{host} issuer: {issuer_str}")
        if not is_intercepted:
            all_intercepted = False

    print(f"proxy_tls_intercepted: {all_intercepted}")

    if not all_intercepted:
        print("STOP: Proxy interception check failed. Do NOT proceed with OAuth login.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
