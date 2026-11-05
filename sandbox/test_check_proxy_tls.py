#!/usr/bin/env python3
"""Focused behavioral tests for check_proxy_tls service selection and TLS interception.

Verifies:
- Explicit service selection (--service openai, --service antigravity, --service both)
- Selecting antigravity contacts only Google OAuth and never OpenAI
- Selecting openai contacts only OpenAI
- Default behavior without arguments checks both endpoints
- Failure exit and notification on unintercepted endpoints
- Invalid service choice rejected via argparse SystemExit before network access
- Proxy CA certificate issuer verification and mismatch handling
- Safe handling of unsupported/credential-bearing proxy configurations
- Secret-free connection error reporting
"""

import importlib.util
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECK_PROXY_TLS_PATH = REPO_ROOT / "sandbox" / "kits" / "check_proxy_tls.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


check_proxy_tls = load_module("check_proxy_tls", CHECK_PROXY_TLS_PATH)


class TestServiceSelectionBehavior(unittest.TestCase):
    """Test CLI service selection and endpoint isolation."""

    @patch("check_proxy_tls.check_endpoint_issuer")
    def test_antigravity_service_calls_only_google(self, mock_issuer):
        mock_issuer.return_value = (True, "commonName=Docker Sandboxes Proxy CA")

        exit_code = check_proxy_tls.main(["--service", "antigravity"])
        self.assertEqual(exit_code, 0)
        mock_issuer.assert_called_once_with("oauth2.googleapis.com", 443)

    @patch("check_proxy_tls.check_endpoint_issuer")
    def test_openai_service_calls_only_openai(self, mock_issuer):
        mock_issuer.return_value = (True, "commonName=Docker Sandboxes Proxy CA")

        exit_code = check_proxy_tls.main(["--service", "openai"])
        self.assertEqual(exit_code, 0)
        mock_issuer.assert_called_once_with("auth.openai.com", 443)

    @patch("check_proxy_tls.check_endpoint_issuer")
    def test_default_both_service_calls_both_endpoints(self, mock_issuer):
        mock_issuer.return_value = (True, "commonName=Docker Sandboxes Proxy CA")

        exit_code = check_proxy_tls.main([])
        self.assertEqual(exit_code, 0)
        self.assertEqual(mock_issuer.call_count, 2)
        mock_issuer.assert_any_call("auth.openai.com", 443)
        mock_issuer.assert_any_call("oauth2.googleapis.com", 443)

    @patch("check_proxy_tls.check_endpoint_issuer")
    def test_explicit_both_service_calls_both_endpoints(self, mock_issuer):
        mock_issuer.return_value = (True, "commonName=Docker Sandboxes Proxy CA")

        exit_code = check_proxy_tls.main(["--service", "both"])
        self.assertEqual(exit_code, 0)
        self.assertEqual(mock_issuer.call_count, 2)

    @patch("check_proxy_tls.check_endpoint_issuer")
    def test_failure_exit_when_unintercepted(self, mock_issuer):
        mock_issuer.return_value = (False, "commonName=Commercial CA")

        buf = io.StringIO()
        with patch("sys.stdout", buf):
            exit_code = check_proxy_tls.main(["--service", "antigravity"])

        self.assertEqual(exit_code, 1)
        output = buf.getvalue()
        self.assertIn("proxy_tls_intercepted: False", output)
        self.assertIn("STOP: Proxy interception check failed.", output)

    @patch("check_proxy_tls.check_endpoint_issuer")
    def test_invalid_choice_rejected_before_network(self, mock_issuer):
        with patch("sys.stderr", io.StringIO()):
            with self.assertRaises(SystemExit) as cm:
                check_proxy_tls.main(["--service", "invalid_choice"])

        self.assertEqual(cm.exception.code, 2)
        mock_issuer.assert_not_called()


class TestTLSProxyVerification(unittest.TestCase):
    """Test certificate issuer verification, proxy validation, and error safety."""

    @patch("http.client.HTTPSConnection")
    @patch("urllib.parse.urlsplit")
    def test_proxy_ca_valid(self, mock_urlsplit, mock_conn_cls):
        mock_urlsplit.return_value = MagicMock(
            scheme="http",
            hostname="127.0.0.1",
            port=8080,
            username=None,
            password=None,
        )
        mock_conn = MagicMock()
        mock_sock = MagicMock()
        mock_sock.getpeercert.return_value = {
            "issuer": ((("commonName", "Docker Sandboxes Proxy CA"),),)
        }
        mock_conn.sock = mock_sock
        mock_conn_cls.return_value = mock_conn

        ok, msg = check_proxy_tls.check_endpoint_issuer("oauth2.googleapis.com")
        self.assertTrue(ok)
        self.assertIn("commonName=Docker Sandboxes Proxy CA", msg)

    @patch("http.client.HTTPSConnection")
    @patch("urllib.parse.urlsplit")
    def test_proxy_ca_mismatch(self, mock_urlsplit, mock_conn_cls):
        mock_urlsplit.return_value = MagicMock(
            scheme="http",
            hostname="127.0.0.1",
            port=8080,
            username=None,
            password=None,
        )
        mock_conn = MagicMock()
        mock_sock = MagicMock()
        mock_sock.getpeercert.return_value = {
            "issuer": ((("commonName", "Commercial CA"),),)
        }
        mock_conn.sock = mock_sock
        mock_conn_cls.return_value = mock_conn

        ok, msg = check_proxy_tls.check_endpoint_issuer("oauth2.googleapis.com")
        self.assertFalse(ok)
        self.assertIn("commonName=Commercial CA", msg)

    @patch("urllib.parse.urlsplit")
    def test_credential_bearing_proxy_rejected(self, mock_urlsplit):
        mock_urlsplit.return_value = MagicMock(
            scheme="http",
            hostname="127.0.0.1",
            port=8080,
            username="user",
            password="secret_password",
        )
        ok, msg = check_proxy_tls.check_endpoint_issuer("oauth2.googleapis.com")
        self.assertFalse(ok)
        self.assertEqual(msg, "supported proxy configured: False")
        self.assertNotIn("secret_password", msg)

    @patch("urllib.parse.urlsplit")
    def test_unsupported_proxy_scheme_rejected(self, mock_urlsplit):
        mock_urlsplit.return_value = MagicMock(
            scheme="socks5",
            hostname="127.0.0.1",
            port=1080,
            username=None,
            password=None,
        )
        ok, msg = check_proxy_tls.check_endpoint_issuer("oauth2.googleapis.com")
        self.assertFalse(ok)
        self.assertEqual(msg, "supported proxy configured: False")

    @patch("http.client.HTTPSConnection")
    @patch("urllib.parse.urlsplit")
    def test_connection_error_secret_free(self, mock_urlsplit, mock_conn_cls):
        mock_urlsplit.return_value = MagicMock(
            scheme="http",
            hostname="127.0.0.1",
            port=8080,
            username=None,
            password=None,
        )
        mock_conn = MagicMock()
        mock_conn.connect.side_effect = TimeoutError("detailed secret token in url")
        mock_conn_cls.return_value = mock_conn

        ok, msg = check_proxy_tls.check_endpoint_issuer("oauth2.googleapis.com")
        self.assertFalse(ok)
        self.assertEqual(msg, "connection failed (TimeoutError)")
        self.assertNotIn("secret", msg)


if __name__ == "__main__":
    unittest.main()
