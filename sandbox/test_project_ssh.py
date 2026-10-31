#!/usr/bin/env python3
"""Comprehensive regression and unit tests for project-ssh and guest-bootstrap lifecycle scripts.

Covers review-3 findings:
- Live OpenSSH rewritten process title matching with strict token boundaries
- Guest status root elevation for reading /proc/<pid>/exe
- Process starttime tracking & zombie handling to prevent signaling reused PIDs
- Mismatched saved state / key refusal before mutations in start
- Partial-start recovery and cleanup in stop
- Systemctl stop failure and D-Bus error handling (retaining state and returning nonzero)
- Zero-mutation stop when no owned state exists
- Subprocess timeout parameter enforcement
- Public key comments containing spaces (split maxsplit=2)
- Revalidation of safe environment on root side and trimming unapproved CA variables
"""

import importlib.util
import json
import os
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch

SANDBOX_DIR = Path(__file__).resolve().parent

def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod

guest_bootstrap = load_module("guest_bootstrap", SANDBOX_DIR / "kits" / "codex-workload" / "guest-bootstrap.py")
project_ssh = load_module("project_ssh", SANDBOX_DIR / "project-ssh.py")

VALID_ED25519_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMrGEuyuTv/kslmYJp3dzKsrWGv89iVltYwhVK7L73Ue test@host with spaces in comment"
VALID_FP = "SHA256:qkDLqyBRBh1qGWHHN6YVoSLX4jMbjdzgPd6mMiXEDjo"


class TestInputValidationAndNaming(unittest.TestCase):
    """Test validation of sandbox names, ports, and public keys."""

    def test_validate_sandbox_name_valid(self):
        valid_names = ["dotfiles-dev", "task-01", "dev.box", "sandbox123", "a-b.c-d"]
        for name in valid_names:
            with self.subTest(name=name):
                self.assertEqual(project_ssh.validate_sandbox_name(name), name)

    def test_validate_sandbox_name_invalid(self):
        invalid_names = [
            "-bad",          # starts with dash
            ".bad",          # starts with period
            "bad-",          # ends with dash
            "bad.",          # ends with period
            "name_with_underscore",  # sbx names have no underscores
            "a",             # length < 2
            "",
            "name with spaces",
            "name;rm",
            "name/slash",
            "a" * 65,
        ]
        for name in invalid_names:
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    project_ssh.validate_sandbox_name(name)

    def test_unit_name_collision_free(self):
        # '.' is escaped to '_2e'; since input names cannot contain '_', collisions are impossible
        u1 = project_ssh.get_unit_name("foo.bar")
        u2 = project_ssh.get_unit_name("foo-bar")
        self.assertEqual(u1, "sbx-ssh-foo_2ebar")
        self.assertEqual(u2, "sbx-ssh-foo-bar")
        self.assertNotEqual(u1, u2)

    def test_validate_port(self):
        self.assertEqual(project_ssh.validate_port(1024), 1024)
        self.assertEqual(project_ssh.validate_port(40222), 40222)
        for bad in (22, 80, 1023, 65536, "40222"):
            with self.assertRaises(ValueError):
                project_ssh.validate_port(bad)

    def test_validate_public_key_strict_ssh_keygen(self):
        # Valid key
        key_line, fp = guest_bootstrap.validate_public_key_text(VALID_ED25519_KEY)
        self.assertEqual(key_line, VALID_ED25519_KEY)
        self.assertIn("SHA256:", fp)

        # Malformed key from review 2 (AQIDBA==) must be rejected
        with self.assertRaises(ValueError):
            guest_bootstrap.validate_public_key_text("ssh-ed25519 AQIDBA== test")

        # Multiple keys must be rejected
        multi = f"{VALID_ED25519_KEY}\n{VALID_ED25519_KEY}\n"
        with self.assertRaises(ValueError) as cm:
            guest_bootstrap.validate_public_key_text(multi)
        self.assertIn("Expected exactly 1 public key line", str(cm.exception))

        # Short / empty / whitespace tokens must not crash with IndexError
        for bad_input in ("", "   ", "ssh-ed25519", "ssh-ed25519 a b c d"):
            with self.subTest(bad=bad_input):
                with self.assertRaises(ValueError):
                    guest_bootstrap.validate_public_key_text(bad_input)

        # Private keys must be rejected
        with self.assertRaises(ValueError):
            guest_bootstrap.validate_public_key_text("-----BEGIN OPENSSH PRIVATE KEY-----\nsecret")


class TestLiveProcessMatchingAndStopSafety(unittest.TestCase):
    """Test live OpenSSH process title matching, zombie handling, and PID reuse prevention."""

    def test_live_openssh_process_title_matching(self):
        """Review 3 Finding 1: /proc/PID/cmdline has rewritten process title 'sshd: /usr/sbin/sshd ... [listener]'."""
        live_title = b"sshd: /usr/sbin/sshd -D -f /etc/ssh/sshd_config.project [listener] 0 of 10-100 startups\x00"

        with tempfile.TemporaryDirectory() as tmpdir:
            pid_file = Path(tmpdir) / "sshd.pid"
            pid_file.write_text("12345\n")

            with patch("guest_bootstrap.PID_PATH", pid_file), \
                 patch.object(guest_bootstrap, "verify_marker"), \
                 patch("pathlib.Path.lstat", return_value=MagicMock(st_mode=stat.S_IFREG | 0o600, st_uid=0)), \
                 patch("guest_bootstrap.get_process_stat", return_value=("S", 100)), \
                 patch("os.readlink", return_value="/usr/sbin/sshd"), \
                 patch("pathlib.Path.read_bytes", return_value=live_title):

                status, pid, starttime = guest_bootstrap.check_owned_listener()
                self.assertEqual(status, "active")
                self.assertEqual(pid, 12345)
                self.assertEqual(starttime, 100)

    def test_process_title_strict_token_boundary(self):
        """Review 3 Finding 1: strict token boundary must reject prefix matches like sshd_config.project-other."""
        prefix_title = b"sshd: /usr/sbin/sshd -D -f /etc/ssh/sshd_config.project-other [listener]\x00"

        with tempfile.TemporaryDirectory() as tmpdir:
            pid_file = Path(tmpdir) / "sshd.pid"
            pid_file.write_text("12345\n")

            with patch("guest_bootstrap.PID_PATH", pid_file), \
                 patch.object(guest_bootstrap, "verify_marker"), \
                 patch("pathlib.Path.lstat", return_value=MagicMock(st_mode=stat.S_IFREG | 0o600, st_uid=0)), \
                 patch("guest_bootstrap.get_process_stat", return_value=("S", 100)), \
                 patch("os.readlink", return_value="/usr/sbin/sshd"), \
                 patch("pathlib.Path.read_bytes", return_value=prefix_title):

                status, pid, _ = guest_bootstrap.check_owned_listener()
                self.assertEqual(status, "stale")

    def test_zombie_process_handled_as_stopped(self):
        """Review 3 Finding 1: zombie termination (state == 'Z') must be recognized as dead/stopped."""
        with tempfile.TemporaryDirectory() as tmpdir:
            pid_file = Path(tmpdir) / "sshd.pid"
            pid_file.write_text("12345\n")

            with patch("guest_bootstrap.PID_PATH", pid_file), \
                 patch.object(guest_bootstrap, "verify_marker"), \
                 patch("pathlib.Path.lstat", return_value=MagicMock(st_mode=stat.S_IFREG | 0o600, st_uid=0)), \
                 patch("guest_bootstrap.get_process_stat", return_value=("Z", 100)):

                status, pid, _ = guest_bootstrap.check_owned_listener()
                self.assertEqual(status, "stale")

    def test_stop_prevents_signaling_reused_pid(self):
        """Review 3 Finding 1: stop must verify process starttime to avoid signaling reused PID."""
        with tempfile.TemporaryDirectory() as tmpdir:
            pid_file = Path(tmpdir) / "sshd.pid"
            pid_file.write_text("12345\n")

            with patch("guest_bootstrap.PID_PATH", pid_file), \
                 patch.object(guest_bootstrap, "verify_marker"), \
                 patch("guest_bootstrap.check_owned_listener", return_value=("active", 12345, 100)), \
                 patch("guest_bootstrap.get_process_stat") as mock_stat, \
                 patch("os.kill") as mock_kill:

                # PID changed after inspection but before the first signal.
                mock_stat.return_value = ("S", 200)

                res = guest_bootstrap.stop_sshd()
                self.assertEqual(res, "stopped")
                mock_kill.assert_not_called()

    def test_guest_status_elevates_to_root(self):
        """Review 3 Finding 1: agent cannot read root /proc/<pid>/exe; status must elevate via sudo -n."""
        with patch("os.geteuid", return_value=1000), patch("os.execvp") as mock_execvp:
            with patch.object(guest_bootstrap, "verify_marker"), \
                 patch.object(guest_bootstrap, "verify_guard_env"):
                with patch("sys.argv", ["guest-bootstrap.py", "status"]):
                    guest_bootstrap.main()
                    self.assertTrue(mock_execvp.called)
                    cmd = mock_execvp.call_args[0][1]
                    self.assertEqual(cmd[0], "sudo")
                    self.assertEqual(cmd[1], "-n")
                    self.assertIn("status", cmd)


class TestGuestBootstrapSecurity(unittest.TestCase):
    """Test guest bootstrap guard checks, safe environment extraction, and config directives."""

    def test_guard_marker_and_env_strictness(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            marker = Path(tmpdir) / "docker-sandbox"
            marker.touch()

            # Requires root ownership
            with patch("pathlib.Path.lstat") as mock_lstat:
                # Simulate non-root ownership -> fails
                mock_lstat.return_value = MagicMock(st_mode=stat.S_IFREG | 0o644, st_uid=1000, st_gid=1000)
                with self.assertRaises(RuntimeError) as cm:
                    guest_bootstrap.verify_marker(marker)
                self.assertIn("owned by root:root", str(cm.exception))

                # Symlink -> fails
                with patch("pathlib.Path.is_symlink", return_value=True):
                    with self.assertRaises(RuntimeError):
                        guest_bootstrap.verify_marker(marker)

            # Env requires ALL 3 guard variables
            complete_env = {"SANDBOX_ID": "id-1", "SANDBOX_VM_ID": "vm-1", "SBX_AGENT": "1"}
            guest_bootstrap.verify_guard_env(complete_env)

            # Missing any one of the three must fail
            for k in ("SANDBOX_ID", "SANDBOX_VM_ID", "SBX_AGENT"):
                incomplete = dict(complete_env)
                del incomplete[k]
                with self.assertRaises(RuntimeError):
                    guest_bootstrap.verify_guard_env(incomplete)

    def test_environment_allowlist_rejects_unsafe_without_silent_omission(self):
        # Credential-bearing proxy must RAISE ValueError (not silently dropped)
        bad_proxy_env = {
            "PATH": "/usr/bin",
            "http_proxy": "http://user:secret@127.0.0.1:8080",
            "SANDBOX_ID": "1",
            "SANDBOX_VM_ID": "1",
            "SBX_AGENT": "1",
        }
        with self.assertRaises(ValueError) as cm:
            guest_bootstrap.extract_safe_environment(bad_proxy_env)
        self.assertIn("Credential-bearing proxy URL", str(cm.exception))

        # Unsafe quoting / newlines must RAISE ValueError
        bad_nl_env = {
            "PATH": "/usr/bin\n/evil",
            "SANDBOX_ID": "1",
            "SANDBOX_VM_ID": "1",
            "SBX_AGENT": "1",
        }
        with self.assertRaises(ValueError) as cm:
            guest_bootstrap.extract_safe_environment(bad_nl_env)
        self.assertIn("Unsafe character", str(cm.exception))

        # Allowed variables kept; unapproved variables (all_proxy, NAME, VM_ID, secrets) omitted
        test_env = {
            "PATH": "/usr/local/bin:/usr/bin",
            "http_proxy": "http://127.0.0.1:8080",
            "HTTPS_PROXY": "http://127.0.0.1:8080",
            "NO_PROXY": "localhost",
            "SSL_CERT_FILE": "/etc/ssl/certs/ca-certificates.crt",
            "SANDBOX_ID": "sbx-id",
            "SANDBOX_VM_ID": "vm-id",
            "SANDBOX_NAME": "my-box",
            "SBX_AGENT": "1",
            "SBX_CRED_OPENAI_MODE": "proxy",
            # Unapproved variables:
            "all_proxy": "socks5://127.0.0.1:1080",
            "NAME": "bad-name",
            "VM_ID": "bad-vm",
            "OPENAI_API_KEY": "secret-key",
        }
        safe = guest_bootstrap.extract_safe_environment(test_env)
        self.assertIn("PATH", safe)
        self.assertIn("http_proxy", safe)
        self.assertIn("SANDBOX_NAME", safe)
        self.assertNotIn("all_proxy", safe)
        self.assertNotIn("NAME", safe)
        self.assertNotIn("VM_ID", safe)
        self.assertNotIn("OPENAI_API_KEY", safe)

    def test_sshd_config_hardening_directives(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg_path = Path(tmpdir) / "sshd_config.project"
            run_dir = Path(tmpdir) / "run_sshd"
            with patch("guest_bootstrap.CONFIG_PATH", cfg_path), patch("guest_bootstrap.RUN_SSHD_DIR", run_dir), patch("os.chown"):
                content = guest_bootstrap.generate_sshd_config({"PATH": "/usr/bin"})
                self.assertIn("UsePAM yes", content)
                self.assertIn("AuthenticationMethods publickey", content)
                self.assertIn("AllowTcpForwarding local", content)
                self.assertIn("AllowAgentForwarding no", content)
                self.assertIn("X11Forwarding no", content)
                self.assertIn("PermitRootLogin no", content)
                self.assertIn("SetEnv PATH=/usr/bin", content)
                self.assertTrue(run_dir.exists())

    def test_authorized_keys_symlink_refusal_and_preserving_restrictions(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            ssh_dir = Path(tmpdir) / ".ssh"
            ssh_dir.mkdir(mode=0o700)
            auth_file = ssh_dir / "authorized_keys"

            # 1. Existing restricted key line
            restricted_line = f"no-port-forwarding,no-pty {VALID_ED25519_KEY}"
            auth_file.write_text(restricted_line + "\n", encoding="utf-8")

            # Attempting to install the identical key unrestricted must NOT add an unrestricted duplicate!
            with patch("pwd.getpwnam", return_value=MagicMock(pw_uid=1000, pw_gid=1000)), patch("os.chown"):
                guest_bootstrap.install_authorized_key(VALID_ED25519_KEY, auth_keys_path=auth_file)

            lines = auth_file.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 1)
            self.assertEqual(lines[0], restricted_line)

            # 2. Refuses symlink authorized_keys
            sym_auth = ssh_dir / "sym_auth"
            sym_auth.symlink_to(auth_file)
            with self.assertRaises(RuntimeError) as cm:
                guest_bootstrap.install_authorized_key(VALID_ED25519_KEY, auth_keys_path=sym_auth)
            self.assertIn("must not be a symlink", str(cm.exception))

    def test_preflight_port_check_refuses_occupied_port(self):
        # Find an open port and listen on it
        sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("::", 0))
        test_port = sock.getsockname()[1]
        sock.listen(1)
        try:
            with self.assertRaises(RuntimeError) as cm:
                guest_bootstrap.verify_guest_port_available(test_port)
            self.assertIn("already in use by an unmanaged listener", str(cm.exception))
        finally:
            sock.close()

        # After closing, port check passes
        guest_bootstrap.verify_guest_port_available(test_port)


class TestEnvironmentAndPublicKeyRefinement(unittest.TestCase):
    """Test public key comments with spaces and strict environment allowlist trimming."""

    def test_public_key_comment_with_spaces_valid(self):
        """Review 3 Finding 5: split(maxsplit=2) must preserve comments with spaces."""
        key_line, fp = guest_bootstrap.validate_public_key_text(VALID_ED25519_KEY)
        self.assertEqual(key_line, VALID_ED25519_KEY)
        self.assertIn("SHA256:", fp)

    def test_root_revalidation_trims_unapproved_ca_vars(self):
        """Review 3 Finding 5: env-json revalidated on root side, trimming SSL_CERT_DIR/REQUESTS_CA_BUNDLE/CURL_CA_BUNDLE."""
        test_env = {
            "PATH": "/usr/bin",
            "SSL_CERT_FILE": "/etc/ssl/certs/ca.crt",
            "NODE_EXTRA_CA_CERTS": "/etc/ssl/node.crt",
            # Unapproved CA vars that must be trimmed:
            "SSL_CERT_DIR": "/etc/ssl/certs",
            "REQUESTS_CA_BUNDLE": "/etc/ssl/ca.crt",
            "CURL_CA_BUNDLE": "/etc/ssl/ca.crt",
            "SANDBOX_ID": "1",
            "SANDBOX_VM_ID": "1",
            "SBX_AGENT": "1",
        }
        safe = guest_bootstrap.extract_safe_environment(test_env)
        self.assertIn("SSL_CERT_FILE", safe)
        self.assertIn("NODE_EXTRA_CA_CERTS", safe)
        self.assertNotIn("SSL_CERT_DIR", safe)
        self.assertNotIn("REQUESTS_CA_BUNDLE", safe)
        self.assertNotIn("CURL_CA_BUNDLE", safe)


class TestHostLifecycleStateSafety(unittest.TestCase):
    """Test host start/stop state mismatch refusal, partial-start cleanup, and zero-mutation stop."""

    def test_start_refuses_mismatched_saved_state_before_mutation(self):
        """Review 3 Finding 2: host start refuses state overwrite when key/port differ."""
        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = Path(tmpdir)
            st_file = state_dir / "my-box.json"
            # Existing state has port 40222 and key fp1
            st_file.write_text(json.dumps({
                "name": "my-box",
                "unit": "sbx-ssh-my-box",
                "port": 40222,
                "key_fingerprint": "SHA256:different_key",
                "host_ip": "::1",
                "protocol": "tcp6",
                "status": "active"
            }))
            os.chmod(st_file, 0o600)

            key_file = state_dir / "id.pub"
            key_file.write_text(VALID_ED25519_KEY + "\n")

            with patch("project_ssh.get_state_dir", return_value=state_dir), patch("subprocess.run") as mock_run:
                mock_run.return_value = MagicMock(returncode=0, stdout=json.dumps([{"name": "my-box", "status": "running"}]), stderr="")

                # Attempting to start with different key must be refused before mutation
                with self.assertRaises(RuntimeError) as cm:
                    project_ssh.start_sandbox_ssh("my-box", key_file, port=40222)
                self.assertIn("existing managed state with conflicting parameters", str(cm.exception))

                # Verify state file was NOT overwritten
                current_data = json.loads(st_file.read_text())
                self.assertEqual(current_data.get("key_fingerprint"), "SHA256:different_key")

    def test_stop_with_no_owned_state_is_zero_mutation(self):
        """Review 3 Finding 4: with NO owned state, make NO mutations (no systemctl stop, no unpublish)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("project_ssh.get_state_dir", return_value=Path(tmpdir)), patch("subprocess.run") as mock_run:
                code = project_ssh.stop_sandbox_ssh("unmanaged-box")
                self.assertEqual(code, 0)
                # ZERO subprocess calls allowed
                mock_run.assert_not_called()

    def test_partial_start_recovery_and_cleanup(self):
        """Review 3 Finding 3: partial start failed before helper installation can be cleanly stopped."""
        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = Path(tmpdir)
            st_file = state_dir / "failed-box.json"
            st_file.write_text(json.dumps({
                "name": "failed-box",
                "unit": "sbx-ssh-failed-box",
                "port": 40222,
                "key_fingerprint": VALID_FP,
                "host_ip": "::1",
                "protocol": "tcp6",
                "listener_started": False,  # Failed before sshd was started
                "status": "starting"
            }))
            os.chmod(st_file, 0o600)

            running_sbx_ls = json.dumps([
                {
                    "name": "failed-box",
                    "status": "running",
                    "ports": [{"host_ip": "::1", "host_port": 40222, "sandbox_port": 2222, "protocol": "tcp6"}],
                }
            ])

            with patch("project_ssh.get_state_dir", return_value=state_dir), patch("subprocess.run") as mock_run:
                def fake_run(cmd, *args, **kwargs):
                    if "ls" in cmd:
                        return MagicMock(returncode=0, stdout=running_sbx_ls, stderr="")
                    if "is-active" in cmd:
                        return MagicMock(returncode=3, stdout="inactive\n", stderr="")
                    return MagicMock(returncode=0, stdout="", stderr="")

                mock_run.side_effect = fake_run
                code = project_ssh.stop_sandbox_ssh("failed-box")
                self.assertEqual(code, 0)
                # State file removed cleanly
                self.assertFalse(st_file.exists())
                # Unpublish was called for the owned port
                unpub_called = any("--unpublish" in c[0][0] for c in mock_run.call_args_list)
                self.assertTrue(unpub_called)

    def test_stop_systemctl_failure_retains_state_and_returns_nonzero(self):
        """Review 3 Finding 4: failed systemctl stop retains state and returns nonzero."""
        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = Path(tmpdir)
            st_file = state_dir / "dbus-fail.json"
            st_file.write_text(json.dumps({
                "name": "dbus-fail",
                "unit": "sbx-ssh-dbus-fail",
                "port": 40222,
                "key_fingerprint": VALID_FP,
                "host_ip": "::1",
                "protocol": "tcp6",
                "status": "active"
            }))
            os.chmod(st_file, 0o600)

            with patch("project_ssh.get_state_dir", return_value=state_dir), patch("subprocess.run") as mock_run:
                def fake_run(cmd, *args, **kwargs):
                    if "ls" in cmd:
                        return MagicMock(returncode=0, stdout="[]", stderr="")
                    if "systemctl" in cmd and "stop" in cmd:
                        return MagicMock(returncode=1, stdout="", stderr="Failed to connect to bus: Connection refused")
                    if "systemctl" in cmd and "is-active" in cmd:
                        return MagicMock(returncode=1, stdout="", stderr="Failed to connect to bus")
                    return MagicMock(returncode=0, stdout="", stderr="")

                mock_run.side_effect = fake_run
                code = project_ssh.stop_sandbox_ssh("dbus-fail")
                self.assertEqual(code, 1)
                # State retained
                self.assertTrue(st_file.exists())

    def test_stop_waits_for_guest_teardown_before_checking_unit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = Path(tmpdir)
            st_file = state_dir / "stopping-box.json"
            st_file.write_text(json.dumps({
                "name": "stopping-box", "unit": "sbx-ssh-stopping-box",
                "port": 40222, "host_ip": "::1", "protocol": "tcp6",
                "listener_started": True,
            }))
            st_file.chmod(0o600)
            events = []

            def fake_run(cmd, *args, **kwargs):
                if "ls" in cmd:
                    return MagicMock(returncode=0, stdout=json.dumps([
                        {"name": "stopping-box", "status": "running", "ports": []}
                    ]))
                if "exec" in cmd:
                    events.append("guest-stopped")
                return MagicMock(returncode=0, stdout="", stderr="")

            states = iter([("deactivating", False), ("inactive", True)])

            def unit_status(*args, **kwargs):
                self.assertIn("guest-stopped", events)
                return next(states)

            with patch("project_ssh.get_state_dir", return_value=state_dir), \
                 patch("subprocess.run", side_effect=fake_run), \
                 patch("project_ssh.get_unit_status", side_effect=unit_status), \
                 patch("time.sleep"):
                self.assertEqual(project_ssh.stop_sandbox_ssh("stopping-box"), 0)
            self.assertFalse(st_file.exists())

    def test_stop_rejects_state_for_another_unit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_dir = Path(tmpdir)
            st_file = state_dir / "my-box.json"
            st_file.write_text(json.dumps({
                "name": "my-box", "unit": "unrelated-service",
                "port": 40222, "host_ip": "::1", "protocol": "tcp6",
            }))
            st_file.chmod(0o600)
            with patch("project_ssh.get_state_dir", return_value=state_dir), \
                 patch("subprocess.run") as run:
                with self.assertRaisesRegex(RuntimeError, "Invalid managed SSH state"):
                    project_ssh.stop_sandbox_ssh("my-box")
                run.assert_not_called()
            self.assertTrue(st_file.exists())

    def test_status_reports_dbus_error_as_nonzero(self):
        """Review 3 Finding 4: read-only status must report D-Bus errors, not success."""
        with patch("subprocess.run") as mock_run, patch("project_ssh.get_state_dir", return_value=Path("/tmp")):
            mock_run.side_effect = [
                MagicMock(returncode=0, stdout=json.dumps([{"name": "box-1", "status": "running"}]), stderr=""),
                # systemctl fails with D-Bus error
                MagicMock(returncode=1, stdout="", stderr="Failed to connect to bus"),
            ]
            code = project_ssh.status_sandbox("box-1")
            self.assertEqual(code, 1)

    def test_subprocess_timeout_enforced(self):
        """Review 3 Finding 4: all subprocess calls must include a timeout."""
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="[]", stderr="")
            project_ssh.get_sandbox_info("test-box")
            self.assertTrue(mock_run.called)
            kwargs = mock_run.call_args[1]
            self.assertIn("timeout", kwargs)
            self.assertGreater(kwargs["timeout"], 0)


if __name__ == "__main__":
    unittest.main()
