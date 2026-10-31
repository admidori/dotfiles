#!/usr/bin/env python3
"""Credential marker validation helper.

Sanity-checks that runtime or static credential files match expected proxy
sentinels and full-access configurations without ever printing actual values
or leaking secrets.

Requires Python >= 3.11 (standard in runtime images). Fails closed (exit code 1)
on unsupported Python versions, any mismatch, missing files, or malformed data.
Outputs strictly boolean status flags.
"""

import argparse
import json
import os
import sys
from pathlib import Path

if sys.version_info < (3, 11):
    print("python_version_supported: False")
    print("all_sentinels_valid: False")
    sys.exit(1)

import tomllib


CODEX_AUTH_SENTINEL = "proxy-managed"
CODEX_BEARER_SENTINEL = "oai-oat01-proxy-managed"
AGY_ACCESS_SENTINEL = "agy-oauth-access-proxy-managed"
AGY_REFRESH_SENTINEL = "agy-oauth-refresh-proxy-managed"


def validate_codex_auth(auth_path: Path) -> bool:
    """Validate that Codex auth.json contains only the proxy sentinel."""
    if not auth_path.is_file():
        return False
    try:
        with auth_path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return False
        # Sentinel verification: only OPENAI_API_KEY equals proxy-managed
        if data.get("OPENAI_API_KEY") != CODEX_AUTH_SENTINEL:
            return False
        if len(data) != 1:
            return False
        return True
    except Exception:
        return False


def validate_codex_config(config_path: Path) -> bool:
    """Validate Codex config.toml has proxy provider and danger-full-access."""
    if not config_path.is_file():
        return False
    try:
        with config_path.open("rb") as f:
            data = tomllib.load(f)

        if not isinstance(data, dict):
            return False

        if data.get("approval_policy") != "never":
            return False
        if data.get("sandbox_mode") != "danger-full-access":
            return False
        if data.get("forced_login_method") != "api":
            return False
        if data.get("model_provider") != "sandboxd":
            return False

        providers = data.get("model_providers", {})
        sandboxd = providers.get("sandboxd", {})
        if sandboxd.get("name") != "Sandbox Proxy":
            return False
        if sandboxd.get("base_url") != "https://chatgpt.com/backend-api/codex":
            return False
        if sandboxd.get("experimental_bearer_token") != CODEX_BEARER_SENTINEL:
            return False
        if sandboxd.get("requires_openai_auth") is not False:
            return False

        return True
    except Exception:
        return False


def validate_antigravity_token(token_path: Path) -> bool:
    """Validate Antigravity credential file matches proxy sentinels."""
    if not token_path.is_file():
        return False
    try:
        with token_path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return False

        if data.get("auth_method") != "consumer":
            return False

        token = data.get("token", {})
        if not isinstance(token, dict):
            return False

        if token.get("access_token") != AGY_ACCESS_SENTINEL:
            return False
        if token.get("refresh_token") != AGY_REFRESH_SENTINEL:
            return False
        if token.get("token_type") != "Bearer":
            return False

        return True
    except Exception:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check credential sentinel markers and report boolean statuses."
    )
    parser.add_argument(
        "--codex-auth",
        type=Path,
        default=None,
        help="Path to Codex auth.json (default: ~/.codex/auth.json)",
    )
    parser.add_argument(
        "--codex-config",
        type=Path,
        default=None,
        help="Path to Codex config.toml (default: ~/.codex/config.toml)",
    )
    parser.add_argument(
        "--antigravity-token",
        type=Path,
        default=None,
        help="Path to Antigravity oauth token (default: ~/.gemini/antigravity-cli/antigravity-oauth-token)",
    )
    args = parser.parse_args()

    explicit_mode = any(
        arg is not None
        for arg in (args.codex_auth, args.codex_config, args.antigravity_token)
    )

    checks = {}

    if explicit_mode:
        if args.codex_auth is not None:
            checks["codex_auth_sentinel"] = validate_codex_auth(args.codex_auth)
        if args.codex_config is not None:
            checks["codex_config_ok"] = validate_codex_config(args.codex_config)
        if args.antigravity_token is not None:
            checks["antigravity_token_sentinel"] = validate_antigravity_token(
                args.antigravity_token
            )
    else:
        # Default runtime mode: check default home paths
        codex_auth = Path(os.path.expanduser("~/.codex/auth.json"))
        codex_config = Path(os.path.expanduser("~/.codex/config.toml"))
        agy_token = Path(
            os.path.expanduser("~/.gemini/antigravity-cli/antigravity-oauth-token")
        )

        checks["codex_auth_sentinel"] = validate_codex_auth(codex_auth)
        checks["codex_config_ok"] = validate_codex_config(codex_config)
        checks["antigravity_token_sentinel"] = validate_antigravity_token(agy_token)

    all_passed = bool(checks) and all(checks.values())

    for name, result in checks.items():
        print(f"{name}: {result}")
    print(f"all_sentinels_valid: {all_passed}")

    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
