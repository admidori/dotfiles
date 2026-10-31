#!/usr/bin/env python3
"""Preflight TLS proxy interception check.

Connects to the OAuth endpoints (auth.openai.com and oauth2.googleapis.com)
through HTTPS_PROXY using standard HTTP CONNECT and ssl to verify that outbound connections are actively
intercepted by the Docker Sandbox proxy CA (Docker Sandboxes Proxy CA).

Outputs strictly certificate issuer information and boolean interception status.
Never reads or accesses secrets, tokens, or credentials.
Exits 0 if both endpoints are intercepted by Docker Sandboxes Proxy CA; exits 1 otherwise.
"""

import http.client
import os
import urllib.parse
import ssl
import sys

TARGET_ENDPOINTS = [
    ("auth.openai.com", 443),
    ("oauth2.googleapis.com", 443),
]

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


def main() -> int:
    all_intercepted = True

    for host, port in TARGET_ENDPOINTS:
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
