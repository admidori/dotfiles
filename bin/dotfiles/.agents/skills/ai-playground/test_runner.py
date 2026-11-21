#!/usr/bin/env python3
"""Unit tests for the ai-playground Colab runner.

Covers:
- Pre-allocation validation (paths, leaf names, collisions with run.json/execution.jsonl/stem_output.ipynb,
  lowercase suffixes, finite positive timeouts, refusal of existing output dir/symlink)
- Normal Python and notebook executions with lifecycle verification and run.json generation
- Flattened official JSONL event fixtures matching Colab CLI 0.7.4 (HistoryLogger / converter)
- Flat exit-zero error in an early notebook cell followed by a successful cell (inspecting all new user events)
- Requirements file staged locally as requirements.txt before colab install
- Temporary sibling file download and atomic move verification
- VM directory setup failure and command trace stopping
- Empty user execution failure (zero new user events after setup)
- Requirements install failure (nonzero exit and flat automation_result with error output)
- Download failure and clean artifact state
- Stop failure recovery and safe recovery command display without shell redirection symbols
- Keep-on-failure behavior
- KeyboardInterrupt and SIGTERM signal handling for orderly agent cleanup
- Metadata write failure reporting nonzero exit
- GPU allocation without unrequested fallback
- Allocation uncertainty handling
"""

import io
import json
import math
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

# Add skill scripts directory to sys.path
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))

import run


class BaseRunnerTest(unittest.TestCase):
    """Base class providing temporary directory isolation and mock helpers."""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="ai-playground-test-")
        # Define fresh output_dir path that does NOT exist yet
        self.output_dir = os.path.join(self.test_dir, "output")
        self.script_file = os.path.join(self.test_dir, "train.py")
        with open(self.script_file, "w", encoding="utf-8") as f:
            f.write("print('Hello from Colab')\n")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)


class TestPreAllocationValidation(BaseRunnerTest):
    """Tests for argument and path validation before VM allocation."""

    def test_missing_script(self):
        non_existent = os.path.join(self.test_dir, "missing.py")
        args = run.parse_args([non_existent, "--output-dir", self.output_dir])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("does not exist", str(ctx.exception))

    def test_invalid_script_extension(self):
        sh_file = os.path.join(self.test_dir, "script.sh")
        with open(sh_file, "w") as f:
            f.write("echo hi\n")
        args = run.parse_args([sh_file, "--output-dir", self.output_dir])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("lowercase .py or .ipynb", str(ctx.exception))

    def test_uppercase_script_extension(self):
        nb_upper = os.path.join(self.test_dir, "script.IPYNB")
        with open(nb_upper, "w") as f:
            f.write("{}\n")
        args = run.parse_args([nb_upper, "--output-dir", self.output_dir])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("lowercase .py or .ipynb", str(ctx.exception))

    def test_refuse_existing_output_dir(self):
        # Must refuse even an existing empty directory
        os.makedirs(self.output_dir, exist_ok=True)
        args = run.parse_args([self.script_file, "--output-dir", self.output_dir])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("already exists", str(ctx.exception))

    def test_refuse_existing_symlink_output_dir(self):
        target_dir = os.path.join(self.test_dir, "real_target")
        os.makedirs(target_dir, exist_ok=True)
        os.symlink(target_dir, self.output_dir)
        args = run.parse_args([self.script_file, "--output-dir", self.output_dir])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("already exists or is a symlink", str(ctx.exception))

    def test_missing_requirements(self):
        non_existent_req = os.path.join(self.test_dir, "no_req.txt")
        args = run.parse_args([
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--requirements",
            non_existent_req,
        ])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("Requirements file does not exist", str(ctx.exception))

    def test_missing_input_file(self):
        non_existent_inp = os.path.join(self.test_dir, "missing.csv")
        args = run.parse_args([
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--input",
            non_existent_inp,
        ])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("Input file does not exist", str(ctx.exception))

    def test_duplicate_input_leaf(self):
        dir1 = os.path.join(self.test_dir, "dir1")
        dir2 = os.path.join(self.test_dir, "dir2")
        os.makedirs(dir1, exist_ok=True)
        os.makedirs(dir2, exist_ok=True)
        f1 = os.path.join(dir1, "data.csv")
        f2 = os.path.join(dir2, "data.csv")
        with open(f1, "w") as f:
            f.write("1\n")
        with open(f2, "w") as f:
            f.write("2\n")

        args = run.parse_args([
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--input",
            f1,
            "--input",
            f2,
        ])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("Declared input leaf name collision", str(ctx.exception))

    def test_invalid_output_leaf_names(self):
        for bad_out in ["dir/out.txt", "out/file.csv", "..", ".", ""]:
            args = run.parse_args([
                self.script_file,
                "--output-dir",
                self.output_dir,
                "--output",
                bad_out,
            ])
            with self.assertRaises(run.ValidationError) as ctx:
                run.validate_pre_allocation(args)
            self.assertIn("not a valid single leaf name", str(ctx.exception))

    def test_duplicate_output(self):
        args = run.parse_args([
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--output",
            "model.pt",
            "--output",
            "model.pt",
        ])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("Declared output name collision", str(ctx.exception))

    def test_collision_with_run_json(self):
        args = run.parse_args([
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--output",
            "run.json",
        ])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("collides with runner metadata file", str(ctx.exception))

    def test_collision_with_execution_jsonl(self):
        args = run.parse_args([
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--output",
            "execution.jsonl",
        ])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("collides with runner log file", str(ctx.exception))

    def test_notebook_output_name_collision(self):
        nb_file = os.path.join(self.test_dir, "experiment.ipynb")
        with open(nb_file, "w") as f:
            f.write("{}\n")
        args = run.parse_args([
            nb_file,
            "--output-dir",
            self.output_dir,
            "--output",
            "experiment_output.ipynb",
        ])
        with self.assertRaises(run.ValidationError) as ctx:
            run.validate_pre_allocation(args)
        self.assertIn("collides with expected notebook execution artifact", str(ctx.exception))

    def test_invalid_timeout(self):
        for bad_timeout in ["0", "--timeout=-10", "inf", "--timeout=-inf", "nan"]:
            if bad_timeout.startswith("--timeout="):
                argv = [self.script_file, "--output-dir", self.output_dir, bad_timeout]
            else:
                argv = [self.script_file, "--output-dir", self.output_dir, "--timeout", bad_timeout]
            args = run.parse_args(argv)
            with self.assertRaises(run.ValidationError) as ctx:
                run.validate_pre_allocation(args)
            self.assertIn("must be a finite positive number", str(ctx.exception))

    def test_mutually_exclusive_gpu_tpu(self):
        with self.assertRaises(SystemExit):
            run.parse_args([
                self.script_file,
                "--output-dir",
                self.output_dir,
                "--gpu",
                "--tpu",
            ])


class TestExecutionLifecycle(BaseRunnerTest):
    """Lifecycle and regression tests mocking subprocess calls to colab CLI with flat 0.7.4 records."""

    def _create_mock_colab(
        self,
        kernel_error=False,
        early_cell_error_then_success=False,
        empty_user_execution=False,
        dir_setup_error=False,
        install_error_nonzero=False,
        install_error_output=False,
        download_fail_target=None,
        stop_error=False,
        generate_notebook_output=True,
    ):
        recorded_calls = []

        def mock_run(argv, capture_output=True, text=True, timeout=None, check=False):
            recorded_calls.append(list(argv))
            cmd_type = None
            if len(argv) >= 4 and argv[0] == "colab":
                cmd_type = argv[3]

            if cmd_type == "new":
                return subprocess.CompletedProcess(argv, returncode=0, stdout="Session created\n", stderr="")

            if cmd_type == "exec":
                # Directory setup script
                if "_setup_dirs.py" in str(argv):
                    if dir_setup_error:
                        return subprocess.CompletedProcess(
                            argv, returncode=1, stdout="", stderr="Setup directory failed"
                        )
                    return subprocess.CompletedProcess(argv, returncode=0, stdout="dirs created\n", stderr="")

                # User script / notebook execution
                for arg in argv:
                    if str(arg).endswith(".ipynb"):
                        if generate_notebook_output:
                            staged_path = pathlib.Path(arg)
                            stem = staged_path.stem
                            out_nb = staged_path.parent / f"{stem}_output.ipynb"
                            with open(out_nb, "w") as f:
                                f.write('{"cells": [], "metadata": {}}\n')

                return subprocess.CompletedProcess(argv, returncode=0, stdout="Script executed\n", stderr="")

            if cmd_type == "install":
                if install_error_nonzero:
                    return subprocess.CompletedProcess(
                        argv, returncode=1, stdout="", stderr="pip install failed"
                    )
                return subprocess.CompletedProcess(argv, returncode=0, stdout="Packages installed\n", stderr="")

            if cmd_type == "upload":
                return subprocess.CompletedProcess(argv, returncode=0, stdout="Uploaded\n", stderr="")

            if cmd_type == "download":
                remote_target = argv[6]
                local_dest = argv[7]
                if download_fail_target and download_fail_target in remote_target:
                    return subprocess.CompletedProcess(
                        argv, returncode=1, stdout="", stderr="Download failed"
                    )
                # Create the file locally at temp dest to simulate successful download
                os.makedirs(os.path.dirname(os.path.abspath(local_dest)), exist_ok=True)
                with open(local_dest, "w") as f:
                    f.write(f"content of {remote_target}\n")
                return subprocess.CompletedProcess(argv, returncode=0, stdout="Downloaded\n", stderr="")

            if cmd_type == "log":
                out_file = argv[argv.index("-o") + 1] if "-o" in argv else "log.jsonl"
                events = []
                # 1. Directory setup execution event (flat row matching 0.7.4)
                events.append({
                    "event_type": "execution",
                    "code": "import os\n...",
                    "outputs": [] if not dir_setup_error else [{"output_type": "error"}],
                })

                # 2. Install event if install was called (flat row matching 0.7.4 with op='install')
                if any(c[3] == "install" for c in recorded_calls if len(c) >= 4):
                    if install_error_output:
                        events.append({
                            "event_type": "automation_result",
                            "op": "install",
                            "outputs": [{"output_type": "error", "ename": "InstallError"}],
                        })
                    else:
                        events.append({
                            "event_type": "automation_result",
                            "op": "install",
                            "outputs": [],
                        })

                # 3. User script execution events (flat rows matching 0.7.4)
                user_exec_called = any(
                    c[3] == "exec" and "_setup_dirs.py" not in str(c) for c in recorded_calls if len(c) >= 4
                )
                if user_exec_called and not empty_user_execution:
                    if early_cell_error_then_success:
                        # Cell 1: Error output
                        events.append({
                            "event_type": "execution",
                            "code": "1 / 0",
                            "outputs": [
                                {
                                    "output_type": "error",
                                    "ename": "ZeroDivisionError",
                                    "evalue": "division by zero",
                                    "traceback": ["ZeroDivisionError: division by zero"],
                                }
                            ],
                        })
                        # Cell 2: Successful stream output (Colab continues execution across cells)
                        events.append({
                            "event_type": "execution",
                            "code": "print('done')",
                            "outputs": [{"output_type": "stream", "text": "done\n"}],
                        })
                    elif kernel_error:
                        events.append({
                            "event_type": "execution",
                            "code": "raise RuntimeError('boom')",
                            "outputs": [
                                {
                                    "output_type": "error",
                                    "ename": "RuntimeError",
                                    "evalue": "boom",
                                    "traceback": ["RuntimeError: boom"],
                                }
                            ],
                        })
                    else:
                        events.append({
                            "event_type": "execution",
                            "code": "print('OK')",
                            "outputs": [{"output_type": "stream", "text": "OK\n"}],
                        })

                os.makedirs(os.path.dirname(os.path.abspath(out_file)), exist_ok=True)
                with open(out_file, "w", encoding="utf-8") as f:
                    for ev in events:
                        f.write(json.dumps(ev) + "\n")
                return subprocess.CompletedProcess(argv, returncode=0, stdout="Log exported\n", stderr="")

            if cmd_type == "stop":
                if stop_error:
                    return subprocess.CompletedProcess(
                        argv, returncode=1, stdout="", stderr="Failed to stop session"
                    )
                return subprocess.CompletedProcess(argv, returncode=0, stdout="Session stopped\n", stderr="")

            return subprocess.CompletedProcess(argv, returncode=0, stdout="", stderr="")

        return mock_run, recorded_calls

    def test_normal_python_run_success(self):
        mock_run, calls = self._create_mock_colab()
        input_file = os.path.join(self.test_dir, "input.txt")
        req_file = os.path.join(self.test_dir, "requirements-test.txt")
        with open(input_file, "w") as f:
            f.write("input data\n")
        with open(req_file, "w") as f:
            f.write("torch\n")

        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--input",
            input_file,
            "--output",
            "model.pt",
            "--requirements",
            req_file,
            "--gpu",
            "T4",
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 0)
        # Check run.json
        run_file = os.path.join(self.output_dir, "run.json")
        self.assertTrue(os.path.exists(run_file))
        with open(run_file) as f:
            meta = json.load(f)
        self.assertEqual(meta["execution_outcome"], "success")
        self.assertEqual(meta["requested_hardware"], "gpu:T4")
        self.assertEqual(meta["vm_cleanup_outcome"], "released")
        self.assertIn("model.pt", meta["artifacts_collected"])

        # Check call trace
        subcmds = [c[3] for c in calls if len(c) >= 4]
        self.assertEqual(subcmds[0], "new")
        self.assertIn("upload", subcmds)
        self.assertIn("install", subcmds)
        self.assertEqual(subcmds[-1], "stop")

        # Verify requirements file was staged locally as requirements.txt
        install_call = [c for c in calls if len(c) >= 4 and c[3] == "install"][0]
        staged_req_arg = install_call[install_call.index("-r") + 1]
        self.assertTrue(staged_req_arg.endswith("requirements.txt"))

        # Verify all commands used isolated config and generated session name
        session_name = meta["session_name"]
        for call in calls:
            self.assertEqual(call[0], "colab")
            self.assertEqual(call[1], "--config")
            self.assertIn("-s", call)
            sess_idx = call.index("-s")
            self.assertEqual(call[sess_idx + 1], session_name)

    def test_normal_notebook_run_success(self):
        mock_run, calls = self._create_mock_colab()
        nb_file = os.path.join(self.test_dir, "notebook.ipynb")
        with open(nb_file, "w") as f:
            f.write('{"cells": []}\n')

        argv = [
            nb_file,
            "--output-dir",
            self.output_dir,
            "--output",
            "metrics.json",
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 0)
        out_nb = os.path.join(self.output_dir, "notebook_output.ipynb")
        self.assertTrue(os.path.exists(out_nb))
        out_metrics = os.path.join(self.output_dir, "metrics.json")
        self.assertTrue(os.path.exists(out_metrics))

        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertIn("notebook_output.ipynb", meta["artifacts_collected"])
        self.assertIn("metrics.json", meta["artifacts_collected"])
        self.assertEqual(meta["requested_hardware"], "cpu")

    def test_early_notebook_cell_error_then_success_fails(self):
        """Failure detection must inspect ALL new execution events, not merely the last one."""
        mock_run, calls = self._create_mock_colab(early_cell_error_then_success=True)
        nb_file = os.path.join(self.test_dir, "cells.ipynb")
        with open(nb_file, "w") as f:
            f.write('{"cells": []}\n')

        argv = [
            nb_file,
            "--output-dir",
            self.output_dir,
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 1, "Must fail closed when an early cell has an error")
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["execution_outcome"], "failure")
        self.assertIn("Kernel execution error detected", meta.get("error", ""))
        # Result notebook is preserved
        self.assertTrue(os.path.exists(os.path.join(self.output_dir, "cells_output.ipynb")))

    def test_empty_user_execution_fails_closed(self):
        """Zero new user events after setup must fail closed."""
        mock_run, calls = self._create_mock_colab(empty_user_execution=True)
        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["execution_outcome"], "failure")
        self.assertIn("zero new user events", meta.get("error", ""))

    def test_exit_zero_kernel_error(self):
        mock_run, calls = self._create_mock_colab(kernel_error=True)
        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["execution_outcome"], "failure")
        self.assertEqual(meta["vm_cleanup_outcome"], "released")

    def test_directory_setup_failure(self):
        mock_run, calls = self._create_mock_colab(dir_setup_error=True)
        input_file = os.path.join(self.test_dir, "input.txt")
        with open(input_file, "w") as f:
            f.write("data\n")

        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--input",
            input_file,
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        subcmds = [c[3] for c in calls if len(c) >= 4]
        # Must not upload or execute user script
        self.assertNotIn("upload", subcmds)
        self.assertIn("stop", subcmds)

    def test_requirements_install_failure_nonzero(self):
        mock_run, calls = self._create_mock_colab(install_error_nonzero=True)
        req_file = os.path.join(self.test_dir, "requirements.txt")
        with open(req_file, "w") as f:
            f.write("bad-package\n")

        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--requirements",
            req_file,
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        exec_calls = [c for c in calls if len(c) >= 4 and c[3] == "exec"]
        self.assertEqual(len(exec_calls), 1)
        self.assertIn("_setup_dirs.py", str(exec_calls[0]))

    def test_requirements_install_automation_error_exit_zero(self):
        mock_run, calls = self._create_mock_colab(install_error_output=True)
        req_file = os.path.join(self.test_dir, "requirements.txt")
        with open(req_file, "w") as f:
            f.write("bad-package\n")

        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--requirements",
            req_file,
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        exec_calls = [c for c in calls if len(c) >= 4 and c[3] == "exec"]
        self.assertEqual(len(exec_calls), 1)
        self.assertIn("_setup_dirs.py", str(exec_calls[0]))

    def test_download_failure_leaves_no_corrupted_partial_file(self):
        mock_run, calls = self._create_mock_colab(download_fail_target="weights.pt")
        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--output",
            "weights.pt",
        ]

        with mock.patch("subprocess.run", side_effect=mock_run):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        final_file = os.path.join(self.output_dir, "weights.pt")
        self.assertFalse(os.path.exists(final_file), "Failed partial download must not exist under final name")
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["execution_outcome"], "failure")

    def test_stop_failure_leaves_private_state_and_safe_commands(self):
        mock_run, calls = self._create_mock_colab(stop_error=True)
        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
        ]

        stdout_buf = io.StringIO()
        with mock.patch("subprocess.run", side_effect=mock_run), mock.patch("sys.stdout", stdout_buf):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["vm_cleanup_outcome"], "failed")

        output_str = stdout_buf.getvalue()
        self.assertIn("Manual recovery commands:", output_str)
        self.assertIn("status -s", output_str)
        self.assertIn("stop -s", output_str)
        # Must not contain raw shell redirection angle brackets
        self.assertNotIn("<NAME>", output_str)
        self.assertNotIn("<LOCAL_PATH>", output_str)

    def test_keep_on_failure(self):
        mock_run, calls = self._create_mock_colab(kernel_error=True)
        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--keep-on-failure",
        ]

        stdout_buf = io.StringIO()
        with mock.patch("subprocess.run", side_effect=mock_run), mock.patch("sys.stdout", stdout_buf):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["vm_cleanup_outcome"], "preserved")

        subcmds = [c[3] for c in calls if len(c) >= 4]
        self.assertNotIn("stop", subcmds, "colab stop must not be called when --keep-on-failure is set")

        output_str = stdout_buf.getvalue()
        self.assertIn("Manual recovery commands:", output_str)
        self.assertIn("status -s", output_str)
        self.assertIn("stop -s", output_str)

    def test_keyboard_interrupt(self):
        mock_run, calls = self._create_mock_colab()

        def mock_interrupt(argv, **kwargs):
            if len(argv) >= 4 and argv[3] == "exec" and "_setup_dirs.py" not in str(argv):
                raise KeyboardInterrupt()
            return mock_run(argv, **kwargs)

        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
        ]

        with mock.patch("subprocess.run", side_effect=mock_interrupt):
            rc = run.main(argv)

        self.assertEqual(rc, 130)
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["execution_outcome"], "failure")
        self.assertEqual(meta["vm_cleanup_outcome"], "released")

    def test_sigterm_handling(self):
        mock_run, calls = self._create_mock_colab()

        def mock_sigterm(argv, **kwargs):
            if len(argv) >= 4 and argv[3] == "exec" and "_setup_dirs.py" not in str(argv):
                # Trigger SIGTERM
                os.kill(os.getpid(), signal.SIGTERM)
            return mock_run(argv, **kwargs)

        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
        ]

        with mock.patch("subprocess.run", side_effect=mock_sigterm):
            rc = run.main(argv)

        self.assertEqual(rc, 143)
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["execution_outcome"], "failure")
        self.assertEqual(meta["vm_cleanup_outcome"], "released")

    def test_metadata_write_failure_exits_nonzero(self):
        mock_run, calls = self._create_mock_colab()
        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
        ]

        real_open = open

        def mock_open(file, *args, **kwargs):
            if str(file).endswith("run.json"):
                raise OSError("Disk quota exceeded")
            return real_open(file, *args, **kwargs)

        with mock.patch("subprocess.run", side_effect=mock_run), mock.patch("builtins.open", side_effect=mock_open):
            rc = run.main(argv)

        self.assertEqual(rc, 1, "Must return nonzero status if metadata writing fails")

    def test_gpu_allocation_failure_no_fallback(self):
        recorded_calls = []

        def mock_run_gpu_fail(argv, **kwargs):
            recorded_calls.append(list(argv))
            if len(argv) >= 4 and argv[3] == "new":
                return subprocess.CompletedProcess(argv, returncode=1, stdout="", stderr="GPU quota exceeded")
            return subprocess.CompletedProcess(argv, returncode=0, stdout="", stderr="")

        argv = [
            self.script_file,
            "--output-dir",
            self.output_dir,
            "--gpu",
            "A100",
        ]

        with mock.patch("subprocess.run", side_effect=mock_run_gpu_fail):
            rc = run.main(argv)

        self.assertEqual(rc, 1)
        new_calls = [c for c in recorded_calls if len(c) >= 4 and c[3] == "new"]
        self.assertEqual(len(new_calls), 1)
        self.assertIn("--gpu", new_calls[0])
        self.assertIn("A100", new_calls[0])
        with open(os.path.join(self.output_dir, "run.json")) as f:
            meta = json.load(f)
        self.assertEqual(meta["requested_hardware"], "gpu:A100")


if __name__ == "__main__":
    unittest.main()
