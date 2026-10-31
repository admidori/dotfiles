#!/usr/bin/env python3
"""Regression tests for resolve-codex-model.py."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESOLVER_SCRIPT = os.path.join(SCRIPT_DIR, "resolve-codex-model.py")


class ResolveCodexModelTests(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="codex-test-")
        self.codex_home = os.path.join(self.test_dir, ".codex")
        self.sessions_dir = os.path.join(self.codex_home, "sessions")
        os.makedirs(self.sessions_dir, exist_ok=True)
        self.archived_sessions_dir = os.path.join(self.codex_home, "archived_sessions")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def run_resolver(self, args=None, env=None):
        cmd = [sys.executable, RESOLVER_SCRIPT]
        if args:
            cmd.extend(args)
        run_env = os.environ.copy()
        # Clean inherited variables for test determinism
        run_env.pop("CODEX_THREAD_ID", None)
        run_env.pop("CODEX_HOME", None)
        if env:
            run_env.update(env)
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=run_env,
        )
        return proc

    def create_rollout(
        self,
        base_dir,
        session_id,
        filename=None,
        events=None,
        trailing_newline=True,
    ):
        if filename is None:
            filename = f"rollout-20261101120000-{session_id}.jsonl"
        filepath = os.path.join(base_dir, filename)
        os.makedirs(os.path.dirname(filepath), exist_ok=True)

        if events is None:
            events = [
                {"type": "session_meta", "payload": {"id": session_id, "cwd": "/tmp"}},
                {
                    "type": "turn_context",
                    "payload": {
                        "model": "gpt-6.1-sol",
                        "turn_id": "11111111-1111-1111-1111-111111111111",
                        "cwd": "/tmp",
                    },
                },
            ]

        with open(filepath, "w", encoding="utf-8") as f:
            for i, ev in enumerate(events):
                if isinstance(ev, str):
                    f.write(ev)
                else:
                    f.write(json.dumps(ev))
                if i < len(events) - 1 or trailing_newline:
                    f.write("\n")
        return filepath

    def test_explicit_session_id(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        self.create_rollout(self.sessions_dir, sid)
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertEqual(proc.returncode, 0, f"stderr: {proc.stderr}")
        self.assertEqual(proc.stdout.strip(), "gpt-6.1-sol")

    def test_env_session_id(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        self.create_rollout(self.sessions_dir, sid)
        proc = self.run_resolver(
            ["--codex-home", self.codex_home],
            env={"CODEX_THREAD_ID": sid},
        )
        self.assertEqual(proc.returncode, 0, f"stderr: {proc.stderr}")
        self.assertEqual(proc.stdout.strip(), "gpt-6.1-sol")

    def test_explicit_overrides_env(self):
        sid1 = "01234567-89ab-cdef-0123-456789abcdef"
        sid2 = "fedcba98-7654-3210-fedc-ba9876543210"
        self.create_rollout(
            self.sessions_dir,
            sid1,
            events=[
                {"type": "session_meta", "payload": {"id": sid1, "cwd": "/tmp"}},
                {"type": "turn_context", "payload": {"model": "model-1", "cwd": "/tmp"}},
            ],
        )
        self.create_rollout(
            self.sessions_dir,
            sid2,
            events=[
                {"type": "session_meta", "payload": {"id": sid2, "cwd": "/tmp"}},
                {"type": "turn_context", "payload": {"model": "model-2", "cwd": "/tmp"}},
            ],
        )
        proc = self.run_resolver(
            ["--session-id", sid2, "--codex-home", self.codex_home],
            env={"CODEX_THREAD_ID": sid1},
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "model-2")

    def test_invalid_uuid(self):
        for bad_id in [
            "not-a-uuid",
            "01234567-89ab-cdef-0123-456789abcdeg",  # invalid hex 'g'
            "0123456789abcdef0123456789abcdef",  # missing dashes
            "../../etc/passwd",
            "",
            "   ",
        ]:
            proc = self.run_resolver(
                ["--session-id", bad_id, "--codex-home", self.codex_home]
            )
            self.assertNotEqual(
                proc.returncode, 0, f"Expected failure for bad UUID: {bad_id}"
            )
            self.assertIn("error:", proc.stderr)

    def test_missing_session_id(self):
        proc = self.run_resolver(["--codex-home", self.codex_home])
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("error: session ID not provided", proc.stderr)

    def test_codex_home_env_and_explicit(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        self.create_rollout(self.sessions_dir, sid)
        # Using CODEX_HOME environment variable
        proc = self.run_resolver(
            ["--session-id", sid],
            env={"CODEX_HOME": self.codex_home},
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "gpt-6.1-sol")

    def test_codex_home_with_spaces(self):
        spaced_home = os.path.join(self.test_dir, "codex home with spaces")
        spaced_sessions = os.path.join(spaced_home, "sessions")
        os.makedirs(spaced_sessions, exist_ok=True)
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        self.create_rollout(spaced_sessions, sid)

        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", spaced_home]
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "gpt-6.1-sol")

    def test_nonexistent_codex_home(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", "/nonexistent/codex/path"]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("error: codex home directory not found", proc.stderr)

    def test_newest_wrong_session_ignored(self):
        sid_target = "01234567-89ab-cdef-0123-456789abcdef"
        sid_other = "ffffffff-ffff-ffff-ffff-ffffffffffff"

        # Target session has timestamp in past
        self.create_rollout(
            self.sessions_dir,
            sid_target,
            filename=f"rollout-20261101010000-{sid_target}.jsonl",
            events=[
                {"type": "session_meta", "payload": {"id": sid_target, "cwd": "/tmp"}},
                {"type": "turn_context", "payload": {"model": "target-model", "cwd": "/tmp"}},
            ],
        )

        # Other session has newer timestamp
        self.create_rollout(
            self.sessions_dir,
            sid_other,
            filename=f"rollout-20261101090000-{sid_other}.jsonl",
            events=[
                {"type": "session_meta", "payload": {"id": sid_other, "cwd": "/tmp"}},
                {"type": "turn_context", "payload": {"model": "other-model", "cwd": "/tmp"}},
            ],
        )

        proc = self.run_resolver(
            ["--session-id", sid_target, "--codex-home", self.codex_home]
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "target-model")

    def test_latest_model_change(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        turn1_id = "11111111-1111-1111-1111-111111111111"
        turn2_id = "22222222-2222-2222-2222-222222222222"
        events = [
            {"type": "session_meta", "payload": {"id": sid, "cwd": "/tmp"}},
            {"type": "turn_context", "payload": {"model": "gpt-5.6-sol", "turn_id": turn1_id, "cwd": "/tmp"}},
            {"type": "other_event", "payload": {"data": "something"}},
            {"type": "turn_context", "payload": {"model": "gpt-6-astra", "turn_id": turn2_id, "cwd": "/tmp"}},
        ]
        self.create_rollout(self.sessions_dir, sid, events=events)

        # Standard output
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "gpt-6-astra")

        # JSON output
        proc_json = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home, "--json"]
        )
        self.assertEqual(proc_json.returncode, 0)
        data = json.loads(proc_json.stdout)
        self.assertEqual(data["model"], "gpt-6-astra")
        self.assertEqual(data["session_id"], sid)
        self.assertEqual(data["turn_id"], turn2_id)
        self.assertTrue(os.path.isfile(data["source_path"]))

    def test_config_conflict_and_absence_ignored(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        self.create_rollout(self.sessions_dir, sid)

        # Write conflicting config.toml
        config_path = os.path.join(self.codex_home, "config.toml")
        with open(config_path, "w") as f:
            f.write('model = "wrong-config-default-model"\n')

        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "gpt-6.1-sol")

    def test_session_meta_mismatch(self):
        sid_target = "01234567-89ab-cdef-0123-456789abcdef"
        sid_inside = "99999999-9999-9999-9999-999999999999"

        # File name has sid_target, but session_meta.id inside has sid_inside
        events = [
            {"type": "session_meta", "payload": {"id": sid_inside, "cwd": "/tmp"}},
            {"type": "turn_context", "payload": {"model": "gpt-6.1-sol", "cwd": "/tmp"}},
        ]
        self.create_rollout(self.sessions_dir, sid_target, events=events)

        proc = self.run_resolver(
            ["--session-id", sid_target, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("error: session ID mismatch in session_meta", proc.stderr)

    def test_duplicate_candidate(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        os.makedirs(self.archived_sessions_dir, exist_ok=True)
        self.create_rollout(self.sessions_dir, sid, filename=f"rollout-1-{sid}.jsonl")
        self.create_rollout(self.archived_sessions_dir, sid, filename=f"rollout-2-{sid}.jsonl")

        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("ambiguous rollout files found", proc.stderr)

    def test_symlink_candidate_refused(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        real_file = self.create_rollout(self.test_dir, sid, filename=f"real-{sid}.jsonl")
        symlink_path = os.path.join(self.sessions_dir, f"rollout-link-{sid}.jsonl")
        os.symlink(real_file, symlink_path)

        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("symlink or non-regular file", proc.stderr)

    def test_missing_or_invalid_latest_model(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"

        # Missing model in latest turn_context (does not fall back to earlier turn)
        events_empty_model = [
            {"type": "session_meta", "payload": {"id": sid, "cwd": "/tmp"}},
            {"type": "turn_context", "payload": {"model": "gpt-5.6-sol", "cwd": "/tmp"}},
            {"type": "turn_context", "payload": {"model": "", "cwd": "/tmp"}},
        ]
        self.create_rollout(self.sessions_dir, sid, events=events_empty_model)
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("error: latest turn_context record has missing or invalid model", proc.stderr)

        # Model with newline / whitespace injection
        events_newline = [
            {"type": "session_meta", "payload": {"id": sid, "cwd": "/tmp"}},
            {"type": "turn_context", "payload": {"model": "gpt-6\ninjected", "cwd": "/tmp"}},
        ]
        self.create_rollout(self.sessions_dir, sid, events=events_newline)
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("forbidden whitespace", proc.stderr)

        # Model with forbidden shell characters
        events_bad_chars = [
            {"type": "session_meta", "payload": {"id": sid, "cwd": "/tmp"}},
            {"type": "turn_context", "payload": {"model": "gpt-6;rm", "cwd": "/tmp"}},
        ]
        self.create_rollout(self.sessions_dir, sid, events=events_bad_chars)
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("forbidden characters", proc.stderr)

    def test_malformed_complete_record(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        events = [
            json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": "/tmp"}}),
            '{"type": "turn_context", "broken_json": ',  # Ends with newline but is malformed JSON
        ]
        self.create_rollout(self.sessions_dir, sid, events=events, trailing_newline=True)
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("error: malformed JSON record in rollout file", proc.stderr)

    def test_partial_final_record(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        # Turn 1 is complete. Turn 2 is an unterminated write without trailing newline.
        events = [
            json.dumps({"type": "session_meta", "payload": {"id": sid, "cwd": "/tmp"}}),
            json.dumps({"type": "turn_context", "payload": {"model": "gpt-6.1-sol", "cwd": "/tmp"}}),
            '{"type": "turn_context", "payload": {"model": "incompl',  # No newline
        ]
        self.create_rollout(self.sessions_dir, sid, events=events, trailing_newline=False)
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertEqual(proc.returncode, 0, f"stderr: {proc.stderr}")
        self.assertEqual(proc.stdout.strip(), "gpt-6.1-sol")

    def test_no_raw_secret_like_fixture_text_in_stdout_stderr(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        secret = "SUPER_SECRET_TOKEN_XYZ_12345"

        # Case 1: Malformed JSON containing secret
        events = [
            json.dumps({"type": "session_meta", "payload": {"id": sid, "secret": secret}}),
            f'{{"type": "turn_context", "secret_payload": "{secret}", broken: ',
        ]
        self.create_rollout(self.sessions_dir, sid, events=events, trailing_newline=True)
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn(secret, proc.stdout)
        self.assertNotIn(secret, proc.stderr)

        # Case 2: Metadata mismatch containing secret
        events_mismatch = [
            {"type": "session_meta", "payload": {"id": "00000000-0000-0000-0000-000000000000", "token": secret}},
            {"type": "turn_context", "payload": {"model": "gpt-6", "secret": secret}},
        ]
        self.create_rollout(self.sessions_dir, sid, events=events_mismatch)
        proc2 = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc2.returncode, 0)
        self.assertNotIn(secret, proc2.stdout)
        self.assertNotIn(secret, proc2.stderr)

    def test_invalid_utf8_complete_record_fails_without_leaking(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        path = self.create_rollout(self.sessions_dir, sid)
        with open(path, "ab") as f:
            f.write(b'{"type":"event_msg","payload":"PRIVATE_FIXTURE_\xff"}\n')
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self.assertNotIn("PRIVATE_FIXTURE", proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)

    def test_partial_invalid_utf8_tail_is_ignored(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        path = self.create_rollout(self.sessions_dir, sid)
        with open(path, "ab") as f:
            f.write(b'{"type":"event_msg","payload":"partial_\xe3')
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "gpt-6.1-sol\n")

    def test_filename_requires_exact_uuid_suffix(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        self.create_rollout(self.sessions_dir, sid)
        self.create_rollout(
            self.sessions_dir, sid,
            filename=f"rollout-backup-{sid}-copy.jsonl",
            events=["PRIVATE_FIXTURE_INVALID_JSON"],
        )
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "gpt-6.1-sol\n")

    def test_nonregular_candidate_refused(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        os.mkfifo(os.path.join(self.sessions_dir, f"rollout-fifo-{sid}.jsonl"))
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("non-regular file", proc.stderr)

    def test_archived_sessions_lookup(self):
        sid = "01234567-89ab-cdef-0123-456789abcdef"
        os.makedirs(self.archived_sessions_dir, exist_ok=True)
        # Not in sessions, only in archived_sessions
        self.create_rollout(self.archived_sessions_dir, sid)
        proc = self.run_resolver(
            ["--session-id", sid, "--codex-home", self.codex_home]
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "gpt-6.1-sol")


if __name__ == "__main__":
    unittest.main()
