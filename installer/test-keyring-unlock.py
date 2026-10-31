#!/usr/bin/env python3
"""Secret-free unit and optional isolated GNOME Keyring integration checks."""

import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "bin/dotfiles/.keyring/unlock.py"
spec = importlib.util.spec_from_file_location("keyring_unlock", HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
REFERENCE = "op://Test/Fixture/password"
DUMMY = b"non-credential test fixture\n"


class UnlockTests(unittest.TestCase):
    def fake_socket(self, response=None, pid=1234, uid=None):
        connection = MagicMock()
        connection.__enter__.return_value = connection
        connection.getsockopt.return_value = struct.pack(
            "3i", pid, os.getuid() if uid is None else uid, os.getgid())
        data = bytearray(struct.pack(">II", 8, 0) if response is None else response)

        def receive(length):
            # Short reads are legal even on the local control socket.
            length = min(length, 2, len(data))
            result = bytes(data[:length])
            del data[:length]
            return result
        connection.recv.side_effect = receive
        return connection

    def run_unlock(self, connection, states=(True, False), mode=stat.S_IFSOCK,
                   owner=None):
        info = SimpleNamespace(st_mode=mode,
                               st_uid=os.getuid() if owner is None else owner)
        with patch.object(helper, "is_locked", side_effect=states), \
             patch.object(helper, "control_endpoint",
                          return_value=(Path("/fixture/control"), 1234)), \
             patch.object(Path, "lstat", return_value=info), \
             patch.object(helper.socket, "socket", return_value=connection), \
             patch.object(helper, "read_password", return_value=DUMMY) as read:
            try:
                return helper.unlock("/fixture/op.exe", REFERENCE), read
            finally:
                self.password_reads = read.call_count

    def test_already_unlocked_does_not_read_password_or_connect(self):
        with patch.object(helper, "is_locked", return_value=False), \
             patch.object(helper, "control_endpoint") as endpoint, \
             patch.object(helper, "read_password") as read:
            self.assertIn("already unlocked", helper.unlock("/missing/op", REFERENCE))
            endpoint.assert_not_called()
            read.assert_not_called()

    def test_wire_format_and_fragmented_reply(self):
        connection = self.fake_socket()
        result, read = self.run_unlock(connection)
        self.assertEqual(result, "Login keyring unlocked.")
        self.assertEqual(self.password_reads, 1)
        self.assertEqual(connection.sendall.call_args_list[0].args, (b"\0",))
        packet = connection.sendall.call_args_list[1].args[0]
        self.assertEqual(packet, struct.pack(">III", 12 + len(DUMMY), 1, len(DUMMY)) + DUMMY)

    def test_wrong_peer_rejected_before_secret_access(self):
        for pid, uid in ((5678, os.getuid()), (1234, os.getuid() + 1)):
            with self.subTest(pid=pid, uid=uid), self.assertRaises(helper.UnlockError):
                self.run_unlock(self.fake_socket(pid=pid, uid=uid))
            self.assertEqual(self.password_reads, 0)

    def test_non_socket_and_foreign_socket_rejected(self):
        for mode, owner in ((stat.S_IFLNK, os.getuid()),
                            (stat.S_IFREG, os.getuid()),
                            (stat.S_IFSOCK, os.getuid() + 1)):
            with self.subTest(mode=mode, owner=owner), self.assertRaises(helper.UnlockError):
                self.run_unlock(self.fake_socket(), mode=mode, owner=owner)
            self.assertEqual(self.password_reads, 0)

    def test_denied_malformed_and_truncated_responses_fail(self):
        for response in (struct.pack(">II", 8, 1), struct.pack(">I", 999999), b""):
            with self.subTest(response=response), self.assertRaises(helper.UnlockError):
                self.run_unlock(self.fake_socket(response))

    def test_still_locked_is_not_success(self):
        with self.assertRaises(helper.UnlockError):
            self.run_unlock(self.fake_socket(), states=(True, True))

    def test_password_is_not_trimmed_or_passed_in_arguments(self):
        with patch.object(helper.subprocess, "run",
                          return_value=SimpleNamespace(returncode=0, stdout=DUMMY)) as run:
            self.assertEqual(helper.read_password("/fixture/op.exe", REFERENCE), DUMMY)
        self.assertEqual(run.call_args.args[0],
                         ["/fixture/op.exe", "read", REFERENCE, "--no-newline"])
        self.assertIs(run.call_args.kwargs["stdout"], subprocess.PIPE)
        self.assertIs(run.call_args.kwargs["stderr"], subprocess.DEVNULL)

    def test_invalid_secret_values_fail(self):
        for value in (b"", b"x\0y", b"x" * 8193):
            with self.subTest(size=len(value)), \
                 patch.object(helper.subprocess, "run",
                              return_value=SimpleNamespace(returncode=0, stdout=value)), \
                 self.assertRaises(helper.UnlockError):
                helper.read_password("/fixture/op.exe", REFERENCE)

    def test_invalid_cli_source_fails_before_execution(self):
        for op, reference in (("op", REFERENCE), ("/fixture/op.exe", "plaintext")):
            with patch.object(helper.subprocess, "run") as run, \
                 self.assertRaises(helper.UnlockError):
                helper.read_password(op, reference)
            run.assert_not_called()

    def test_failure_and_timeout_do_not_print_subprocess_output(self):
        for result in (SimpleNamespace(returncode=1, stdout=DUMMY),
                       subprocess.TimeoutExpired("op", 1, output=DUMMY, stderr=DUMMY)):
            out, err = io.StringIO(), io.StringIO()
            kwargs = {"side_effect": result} if isinstance(result, Exception) else {"return_value": result}
            with patch.object(helper, "unlock",
                              side_effect=lambda op, ref: helper.read_password(op, ref)), \
                 patch.object(helper.os, "getuid", return_value=1000), \
                 patch.object(helper.resource, "setrlimit"), \
                 patch.object(helper.subprocess, "run", **kwargs), \
                 redirect_stdout(out), redirect_stderr(err):
                status = helper.main(["--op", "/fixture/op.exe", "--reference", REFERENCE])
            self.assertEqual(status, 1)
            self.assertEqual(out.getvalue(), "")
            self.assertNotIn(DUMMY.decode().strip(), err.getvalue())

    def test_bus_failures_and_invalid_json_fail_closed(self):
        for result in (SimpleNamespace(returncode=1, stdout=b""),
                       SimpleNamespace(returncode=0, stdout=b"not json"),
                       SimpleNamespace(returncode=0, stdout=b"{}")):
            with patch.object(helper.subprocess, "run", return_value=result), \
                 self.assertRaises(helper.UnlockError):
                helper.is_locked()
        with patch.object(helper, "bus_json", return_value="false"), \
             self.assertRaises(helper.UnlockError):
            helper.is_locked()


def isolated_case():
    """Runs only under a private D-Bus and private XDG data/runtime directories."""
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    control = runtime / "keyring"
    control.mkdir()
    daemon = subprocess.Popen(
        ["gnome-keyring-daemon", "--foreground", "--unlock", "--components=secrets",
         "--control-directory", str(control)],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        daemon.stdin.write(DUMMY)
        daemon.stdin.close()
        for _ in range(100):
            owner = helper.bus_json("call", "org.freedesktop.DBus",
                                   "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                   "NameHasOwner", "s", helper.SERVICE)
            if owner == [True]:
                break
            time.sleep(.05)
        else:
            raise AssertionError("Fixture daemon did not acquire its bus name")
        assert not helper.is_locked()
        before = helper.control_endpoint()[1]
        calls = runtime / "op-calls"
        fake_op = runtime / "op.exe"

        def write_op(value):
            fake_op.write_text("#!/usr/bin/python3\nfrom pathlib import Path\n"
                               + f"p=Path({str(calls)!r})\n"
                               + "with p.open('a') as f: f.write('read\\n')\n"
                               + f"import sys\nsys.stdout.buffer.write({value!r})\n")
            fake_op.chmod(0o700)

        def lock():
            helper.bus_json("call", helper.SERVICE, "/org/freedesktop/secrets",
                            "org.freedesktop.Secret.Service", "Lock",
                            "ao", "1", helper.COLLECTION)
            assert helper.is_locked()

        write_op(DUMMY)
        lock()
        assert helper.unlock(str(fake_op), REFERENCE) == "Login keyring unlocked."
        assert helper.control_endpoint()[1] == before
        assert helper.unlock(str(fake_op), REFERENCE) == "Login keyring is already unlocked."
        assert calls.read_text().splitlines() == ["read"]
        write_op(b"incorrect fixture password")
        lock()
        try:
            helper.unlock(str(fake_op), REFERENCE)
        except helper.UnlockError:
            pass
        else:
            raise AssertionError("Incorrect fixture password was accepted")
        assert helper.is_locked()
        assert helper.control_endpoint()[1] == before
        print("Isolated GNOME unlock, no-op, rejection, and stable PID checks passed.")
    finally:
        daemon.terminate()
        daemon.wait(timeout=10)


class IntegrationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gnome-keyring-daemon")
                         and shutil.which("dbus-run-session"),
                         "Optional live fixture needs gnome-keyring and dbus-run-session")
    def test_real_daemon_on_private_bus(self):
        with tempfile.TemporaryDirectory(prefix="keyring-test-") as directory:
            root = Path(directory)
            for name in ("data", "config", "runtime"):
                (root / name).mkdir(mode=0o700)
            env = {"PATH": "/usr/bin:/bin",
                   "XDG_DATA_HOME": str(root / "data"),
                   "XDG_CONFIG_HOME": str(root / "config"),
                   "XDG_RUNTIME_DIR": str(root / "runtime")}
            result = subprocess.run(
                ["dbus-run-session", "--", "/usr/bin/python3", "-I",
                 str(Path(__file__).resolve()), "--isolated-case"],
                env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    if sys.argv[1:] == ["--isolated-case"]:
        isolated_case()
    else:
        unittest.main()
