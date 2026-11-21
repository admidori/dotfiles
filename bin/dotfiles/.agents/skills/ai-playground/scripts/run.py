#!/usr/bin/env python3
"""ai-playground: portable Google Colab experiment runner.

Executes local Python scripts and Jupyter notebooks on managed Google Colab VMs
using the official google-colab-cli (version 0.7.4+). Direct local/VM file transfer,
local-only artifacts, isolated private session store, verified lifecycle teardown,
and failure detection via structured flat JSONL history events.
"""

import argparse
import json
import math
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid
from typing import Any, Dict, List, Optional


class ValidationError(Exception):
    """Raised when pre-allocation arguments or paths fail validation."""
    pass


class TerminateRequested(Exception):
    """Raised when SIGTERM is received during execution."""
    pass


def is_valid_leaf_name(name: str) -> bool:
    """Validate that name is a single valid filename without path components."""
    if not name or not isinstance(name, str):
        return False
    if name in (".", ".."):
        return False
    if "/" in name or "\\" in name:
        return False
    if "\x00" in name:
        return False
    return True


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    """Parse CLI options for ai-playground runner."""
    parser = argparse.ArgumentParser(
        prog="run.py",
        description="Execute Python scripts or Jupyter notebooks on Google Colab via colab CLI.",
    )
    parser.add_argument(
        "script",
        metavar="SCRIPT",
        help="Path to local Python script (.py) or Jupyter notebook (.ipynb) to execute",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        metavar="DIR",
        help="Required fresh local directory to collect output artifacts and logs",
    )
    parser.add_argument(
        "--input",
        action="append",
        default=[],
        dest="input",
        metavar="FILE",
        help="Input file to stage into /content/ai-playground/inputs (repeatable)",
    )
    parser.add_argument(
        "--output",
        action="append",
        default=[],
        dest="output",
        metavar="NAME",
        help="Declared output filename to retrieve from /content/ai-playground/outputs (repeatable)",
    )
    parser.add_argument(
        "--requirements",
        metavar="FILE",
        help="Optional requirements.txt file to install via colab install",
    )
    hw_group = parser.add_mutually_exclusive_group()
    hw_group.add_argument(
        "--gpu",
        nargs="?",
        const="T4",
        default=None,
        metavar="ACCELERATOR",
        help="Request GPU VM runtime (default accelerator: T4). Mutually exclusive with --tpu.",
    )
    hw_group.add_argument(
        "--tpu",
        nargs="?",
        const="v5e1",
        default=None,
        metavar="ACCELERATOR",
        help="Request TPU VM runtime (default accelerator: v5e1). Mutually exclusive with --gpu.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=1800.0,
        metavar="SECONDS",
        help="Execution timeout in positive seconds (default: 1800s / 30m, suitable for training)",
    )
    parser.add_argument(
        "--keep-on-failure",
        action="store_true",
        help="Keep remote VM and local private state preserved on failure for debugging",
    )
    return parser.parse_args(argv)


def validate_pre_allocation(args: argparse.Namespace) -> None:
    """Validate all paths, leaf names, collisions, and options before allocating any VM."""
    # 1. Positional SCRIPT validation
    if not args.script:
        raise ValidationError("Positional SCRIPT path is required.")
    if not os.path.exists(args.script):
        raise ValidationError(f"Script file does not exist: {args.script}")
    if not os.path.isfile(args.script):
        raise ValidationError(f"Script path must be a regular file: {args.script}")

    # Installed Colab CLI dispatches notebooks only on lowercase .ipynb suffix
    if not (args.script.endswith(".py") or args.script.endswith(".ipynb")):
        raise ValidationError(
            f"Script must have lowercase .py or .ipynb extension: {args.script}"
        )
    script_base = os.path.basename(args.script)
    if not is_valid_leaf_name(script_base):
        raise ValidationError(f"Invalid script filename: {script_base}")

    # 2. Output directory validation: must be a fresh path (refusing existing empty dir or symlink)
    if not args.output_dir:
        raise ValidationError("--output-dir must be specified.")
    if os.path.exists(args.output_dir) or os.path.islink(args.output_dir):
        raise ValidationError(
            f"Output directory '{args.output_dir}' already exists or is a symlink (must be a fresh path)"
        )

    # 3. Requirements file validation
    if args.requirements:
        if not os.path.exists(args.requirements):
            raise ValidationError(f"Requirements file does not exist: {args.requirements}")
        if not os.path.isfile(args.requirements):
            raise ValidationError(f"Requirements path must be a regular file: {args.requirements}")

    # 4. Input files validation
    seen_input_leafs = set()
    for inp in args.input:
        if not os.path.exists(inp):
            raise ValidationError(f"Input file does not exist: {inp}")
        if not os.path.isfile(inp):
            raise ValidationError(f"Input path must be a regular file: {inp}")
        leaf = os.path.basename(inp)
        if not is_valid_leaf_name(leaf):
            raise ValidationError(f"Input leaf name is invalid: {leaf}")
        if leaf in seen_input_leafs:
            raise ValidationError(f"Declared input leaf name collision: '{leaf}' declared multiple times")
        seen_input_leafs.add(leaf)

    # 5. Output names validation
    seen_output_names = set()
    stem = pathlib.Path(args.script).stem
    expected_nb_output = f"{stem}_output.ipynb" if args.script.endswith(".ipynb") else None

    for out in args.output:
        if not is_valid_leaf_name(out) or os.path.basename(out) != out or "/" in out or "\\" in out:
            raise ValidationError(
                f"Declared output '{out}' is not a valid single leaf name without directory separators."
            )
        if out in seen_output_names:
            raise ValidationError(f"Declared output name collision: '{out}' declared multiple times")
        # Collisions with runner-reserved filenames
        if out == "run.json":
            raise ValidationError("Declared output 'run.json' collides with runner metadata file")
        if out == "execution.jsonl":
            raise ValidationError("Declared output 'execution.jsonl' collides with runner log file")
        if expected_nb_output and out == expected_nb_output:
            raise ValidationError(
                f"Declared output '{out}' collides with expected notebook execution artifact"
            )
        seen_output_names.add(out)

    # 6. Timeout validation: must be finite and positive (> 0)
    if (
        not isinstance(args.timeout, (int, float))
        or not math.isfinite(args.timeout)
        or args.timeout <= 0
    ):
        raise ValidationError(
            f"Execution timeout must be a finite positive number (> 0), got: {args.timeout}"
        )


class ColabRunner:
    """Manages the lifecycle of a single Colab experiment execution."""

    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.session_name = f"ai-playground-{uuid.uuid4().hex[:12]}"
        self.temp_state_dir = tempfile.mkdtemp(prefix=f"ai-playground-{self.session_name}-")
        self.config_path = os.path.join(self.temp_state_dir, "sessions.json")
        self.work_dir = os.path.join(self.temp_state_dir, "work")
        os.makedirs(self.work_dir, exist_ok=True)
        self.output_dir = os.path.abspath(args.output_dir)

        self.artifacts_collected: List[str] = []
        self.execution_outcome = "failure"
        self.vm_cleanup_outcome = "not_started"
        self.vm_allocated = False
        self.error_message: Optional[str] = None
        self.metadata_write_failed = False
        self.staged_script: Optional[str] = None
        self.expected_output_notebook: Optional[str] = None
        self.exec_result: Optional[subprocess.CompletedProcess] = None
        self.setup_exec_event_count = 0
        self.staged_requirements_path: Optional[str] = None

        # Preserve requested accelerator name including T4/v5e1 losslessly
        if self.args.gpu:
            self.requested_hardware = f"gpu:{self.args.gpu}"
        elif self.args.tpu:
            self.requested_hardware = f"tpu:{self.args.tpu}"
        else:
            self.requested_hardware = "cpu"

    def _format_timeout(self) -> str:
        """Format the timeout losslessly as a string."""
        if isinstance(self.args.timeout, float) and self.args.timeout.is_integer():
            return str(int(self.args.timeout))
        return str(self.args.timeout)

    def _run_command(
        self,
        argv: List[str],
        timeout: Optional[float] = None,
        check: bool = False,
    ) -> subprocess.CompletedProcess:
        """Run a subprocess command with argv list and no shell interpolation."""
        cmd_str = " ".join(shlex.quote(c) for c in argv)
        sys.stdout.write(f"--> {cmd_str}\n")
        sys.stdout.flush()
        try:
            res = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=check,
            )
            if res.stdout:
                sys.stdout.write(res.stdout)
                sys.stdout.flush()
            if res.stderr:
                sys.stderr.write(res.stderr)
                sys.stderr.flush()
            return res
        except subprocess.TimeoutExpired as exc:
            sys.stderr.write(f"Command timed out after {timeout} seconds: {cmd_str}\n")
            raise exc

    def _parse_jsonl(self, file_path: str) -> List[Dict[str, Any]]:
        """Parse structured JSONL log events exported by colab log."""
        events: List[Dict[str, Any]] = []
        if not os.path.exists(file_path):
            raise RuntimeError(f"Log file does not exist: {file_path}")
        with open(file_path, "r", encoding="utf-8") as f:
            line_num = 0
            for line in f:
                line_num += 1
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                    if not isinstance(ev, dict):
                        raise RuntimeError(f"Malformed event at line {line_num} in {file_path}")
                    events.append(ev)
                except json.JSONDecodeError as exc:
                    raise RuntimeError(
                        f"Malformed JSON at line {line_num} in {file_path}: {exc}"
                    )
        return events

    def _has_error_output(self, event: Dict[str, Any]) -> bool:
        """Reject malformed Colab CLI history and explicit kernel errors."""
        outputs = event.get("outputs")
        return not isinstance(outputs, list) or any(
            not isinstance(output, dict)
            or not isinstance(output.get("output_type"), str)
            or output["output_type"] == "error"
            for output in outputs
        )

    def _session_state_exists(self) -> bool:
        """Check if the isolated sessions store contains a record for this session."""
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, "r", encoding="utf-8") as f:
                    content = f.read()
                if self.session_name in content:
                    return True
            except Exception:
                pass
        return False

    def _allocate_vm(self) -> None:
        """Allocate the named VM session with isolated --config."""
        cmd = ["colab", "--config", self.config_path, "new", "-s", self.session_name]
        if self.args.gpu:
            cmd.extend(["--gpu", str(self.args.gpu)])
        elif self.args.tpu:
            cmd.extend(["--tpu", str(self.args.tpu)])

        sys.stdout.write(
            f"[ai-playground] Allocating Colab VM '{self.session_name}' (hardware: {self.requested_hardware})...\n"
        )
        try:
            res = self._run_command(cmd, timeout=120.0)
            if res.returncode != 0:
                raise RuntimeError(
                    f"Failed to allocate Colab VM (exit {res.returncode}): {res.stderr or res.stdout}"
                )
            self.vm_allocated = True
            self.vm_cleanup_outcome = "pending"
        except Exception as exc:
            # Check if allocation record was created
            if self._session_state_exists():
                self.vm_allocated = True
                self.vm_cleanup_outcome = "uncertain"
            else:
                self.vm_cleanup_outcome = "uncertain"
            raise exc

    def _setup_vm_directories(self) -> None:
        """Guard VM directory setup before staging user files."""
        setup_script = os.path.join(self.work_dir, "_setup_dirs.py")
        with open(setup_script, "w", encoding="utf-8") as f:
            f.write(
                "import os\n"
                "os.makedirs('/content/ai-playground/inputs', exist_ok=True)\n"
                "os.makedirs('/content/ai-playground/outputs', exist_ok=True)\n"
            )

        cmd = [
            "colab",
            "--config",
            self.config_path,
            "exec",
            "-s",
            self.session_name,
            "-f",
            setup_script,
        ]
        sys.stdout.write(
            "[ai-playground] Setting up VM directories (/content/ai-playground/{inputs,outputs})...\n"
        )
        res = self._run_command(cmd, timeout=60.0)
        if res.returncode != 0:
            raise RuntimeError(
                f"VM directory setup failed with exit code {res.returncode}: {res.stderr or res.stdout}"
            )

        setup_log = os.path.join(self.work_dir, "setup_log.jsonl")
        log_res = self._run_command(
            ["colab", "--config", self.config_path, "log", "-s", self.session_name, "-o", setup_log],
            timeout=30.0,
        )
        if log_res.returncode != 0 or not os.path.exists(setup_log):
            raise RuntimeError("Failed to export log after VM directory setup")

        events = self._parse_jsonl(setup_log)
        exec_events = [e for e in events if e.get("event_type") == "execution"]
        if not exec_events:
            raise RuntimeError("VM directory setup log missing expected execution event")
        if self._has_error_output(exec_events[-1]):
            raise RuntimeError("VM directory setup encountered error in execution output")

        self.setup_exec_event_count = len(exec_events)

    def _install_requirements(self) -> None:
        """Stage requirements file locally as requirements.txt and install on VM."""
        # Colab CLI 0.7.4 does quote-unsafe interpolation of the basename; stage safely as requirements.txt
        self.staged_requirements_path = os.path.join(self.work_dir, "requirements.txt")
        shutil.copy2(os.path.abspath(self.args.requirements), self.staged_requirements_path)

        cmd = [
            "colab",
            "--config",
            self.config_path,
            "install",
            "-s",
            self.session_name,
            "-r",
            self.staged_requirements_path,
        ]
        sys.stdout.write(f"[ai-playground] Installing requirements from {self.args.requirements}...\n")
        res = self._run_command(cmd, timeout=300.0)
        if res.returncode != 0:
            raise RuntimeError(
                f"Requirements installation failed with exit code {res.returncode}: {res.stderr or res.stdout}"
            )

        install_log = os.path.join(self.work_dir, "install_log.jsonl")
        log_res = self._run_command(
            ["colab", "--config", self.config_path, "log", "-s", self.session_name, "-o", install_log],
            timeout=30.0,
        )
        if log_res.returncode != 0 or not os.path.exists(install_log):
            raise RuntimeError("Failed to export log after requirements install")

        events = self._parse_jsonl(install_log)
        auto_events = [
            e for e in events
            if e.get("event_type") == "automation_result" and e.get("op") == "install"
        ]
        if not auto_events:
            raise RuntimeError("Requirements installation log missing expected automation_result event")
        last_auto = auto_events[-1]
        if self._has_error_output(last_auto):
            raise RuntimeError("Requirements installation reported error outputs in automation_result")

    def _upload_inputs(self) -> None:
        """Stage input files to /content/ai-playground/inputs on VM."""
        for inp in self.args.input:
            leaf = os.path.basename(inp)
            remote_path = f"content/ai-playground/inputs/{leaf}"
            cmd = [
                "colab",
                "--config",
                self.config_path,
                "upload",
                "-s",
                self.session_name,
                os.path.abspath(inp),
                remote_path,
            ]
            sys.stdout.write(f"[ai-playground] Uploading {inp} -> {remote_path}...\n")
            res = self._run_command(cmd, timeout=120.0)
            if res.returncode != 0:
                raise RuntimeError(
                    f"Failed to upload input '{inp}' to '{remote_path}': {res.stderr or res.stdout}"
                )

    def _run_user_script(self) -> None:
        """Execute user script or notebook on the VM."""
        timeout_val = self._format_timeout()
        if self.args.script.endswith(".ipynb"):
            script_base = os.path.basename(self.args.script)
            stem = pathlib.Path(script_base).stem
            # Ensure staged notebook ends with lowercase .ipynb
            self.staged_script = os.path.join(self.work_dir, f"{stem}.ipynb")
            shutil.copy2(self.args.script, self.staged_script)
            self.expected_output_notebook = os.path.join(self.work_dir, f"{stem}_output.ipynb")
            cmd = [
                "colab",
                "--config",
                self.config_path,
                "exec",
                "-s",
                self.session_name,
                "-f",
                self.staged_script,
                "--timeout",
                timeout_val,
            ]
        else:
            self.staged_script = os.path.abspath(self.args.script)
            self.expected_output_notebook = None
            cmd = [
                "colab",
                "--config",
                self.config_path,
                "exec",
                "-s",
                self.session_name,
                "-f",
                self.staged_script,
                "--timeout",
                timeout_val,
            ]

        sys.stdout.write(
            f"[ai-playground] Executing {self.args.script} (cell timeout: {timeout_val}s)...\n"
        )
        # Avoid imposing single-cell deadline on an entire multi-cell notebook execution:
        # Colab CLI enforces the per-cell timeout internally.
        self.exec_result = self._run_command(cmd, timeout=None)

    def _check_execution_log(self) -> None:
        """Export history log and verify execution outcome across all new user events."""
        log_file = os.path.join(self.output_dir, "execution.jsonl")
        log_res = self._run_command(
            ["colab", "--config", self.config_path, "log", "-s", self.session_name, "-o", log_file],
            timeout=60.0,
        )

        if self.exec_result is None or self.exec_result.returncode != 0:
            rc = getattr(self.exec_result, "returncode", "unknown")
            raise RuntimeError(f"User script execution returned nonzero exit code: {rc}")

        if log_res.returncode != 0 or not os.path.exists(log_file):
            raise RuntimeError("Failed to export execution history log")

        events = self._parse_jsonl(log_file)
        all_exec = [e for e in events if e.get("event_type") == "execution"]

        # User events are those appended after directory setup
        user_exec_events = all_exec[self.setup_exec_event_count:]
        if not user_exec_events:
            raise RuntimeError(
                "Execution log missing expected user execution events (zero new user events after setup)"
            )

        # Inspect ALL new execution events, not just the last one
        for idx, ev in enumerate(user_exec_events, 1):
            if self._has_error_output(ev):
                raise RuntimeError(
                    f"Kernel execution error detected in execution event {idx} of {len(user_exec_events)}"
                )

        self.execution_outcome = "success"

    def _preserve_output_notebook_if_present(self) -> None:
        """Preserve executed notebook into output directory if generated."""
        if self.expected_output_notebook and os.path.exists(self.expected_output_notebook):
            dest_nb = os.path.join(self.output_dir, os.path.basename(self.expected_output_notebook))
            if not os.path.exists(dest_nb):
                shutil.copy2(self.expected_output_notebook, dest_nb)
            nb_name = os.path.basename(dest_nb)
            if nb_name not in self.artifacts_collected:
                self.artifacts_collected.append(nb_name)

    def _collect_artifacts(self) -> None:
        """Download declared outputs via temporary sibling files and verify on disk."""
        self._preserve_output_notebook_if_present()

        missing_outputs = []
        for out in self.args.output:
            remote_path = f"content/ai-playground/outputs/{out}"
            final_path = os.path.join(self.output_dir, out)
            tmp_path = os.path.join(self.output_dir, f".tmp_{uuid.uuid4().hex}_{out}")

            cmd = [
                "colab",
                "--config",
                self.config_path,
                "download",
                "-s",
                self.session_name,
                remote_path,
                tmp_path,
            ]
            sys.stdout.write(f"[ai-playground] Downloading output {remote_path} -> {final_path}...\n")
            res = self._run_command(cmd, timeout=120.0)
            if res.returncode == 0 and os.path.isfile(tmp_path):
                # Move to final name only on verified success
                os.replace(tmp_path, final_path)
                if out not in self.artifacts_collected:
                    self.artifacts_collected.append(out)
            else:
                if os.path.exists(tmp_path):
                    try:
                        os.remove(tmp_path)
                    except Exception:
                        pass
                missing_outputs.append(out)

        if missing_outputs and self.execution_outcome == "success":
            raise RuntimeError(
                f"Required output artifact(s) missing or failed to download: {', '.join(missing_outputs)}"
            )

    def _print_recovery_commands(self) -> None:
        """Display shell-safe manual recovery commands without angle-bracket redirections."""
        cfg_q = shlex.quote(self.config_path)
        sess_q = shlex.quote(self.session_name)
        sys.stdout.write("\n" + "=" * 65 + "\n")
        sys.stdout.write(f"[ai-playground] Session preserved at {self.config_path}\n")
        sys.stdout.write("Manual recovery commands:\n")
        sys.stdout.write(f"  Status:   colab --config {cfg_q} status -s {sess_q}\n")
        sys.stdout.write(
            f"  Download: colab --config {cfg_q} download -s {sess_q} content/ai-playground/outputs/FILENAME LOCAL_DEST\n"
        )
        sys.stdout.write(f"  Stop:     colab --config {cfg_q} stop -s {sess_q}\n")
        sys.stdout.write("=" * 65 + "\n\n")
        sys.stdout.flush()

    def _write_metadata(self) -> None:
        """Write execution metadata to run.json in the output directory."""
        meta = {
            "session_name": self.session_name,
            "requested_hardware": self.requested_hardware,
            "execution_outcome": self.execution_outcome,
            "artifacts_collected": sorted(self.artifacts_collected),
            "vm_cleanup_outcome": self.vm_cleanup_outcome,
        }
        if self.error_message:
            meta["error"] = self.error_message
        meta_path = os.path.join(self.output_dir, "run.json")
        try:
            with open(meta_path, "w", encoding="utf-8") as f:
                json.dump(meta, f, indent=2)
                f.write("\n")
        except Exception as exc:
            self.metadata_write_failed = True
            sys.stderr.write(f"[ai-playground] Error: failed to write run.json: {exc}\n")

    def _cleanup_and_finalize(self) -> None:
        """Independent finally cleanup path guaranteeing bounded teardown and safe state."""
        # 1. Preserve notebook result even on failure if present
        try:
            self._preserve_output_notebook_if_present()
        except Exception as exc:
            sys.stderr.write(f"[ai-playground] Warning: failed to preserve notebook: {exc}\n")

        # 2. If execution failed, attempt bounded log export and artifact retrieval before stop
        if self.vm_allocated and self.execution_outcome != "success":
            log_file = os.path.join(self.output_dir, "execution.jsonl")
            if not os.path.exists(log_file):
                try:
                    self._run_command(
                        ["colab", "--config", self.config_path, "log", "-s", self.session_name, "-o", log_file],
                        timeout=30.0,
                    )
                except Exception:
                    pass

            for out in self.args.output:
                if out not in self.artifacts_collected:
                    remote_path = f"content/ai-playground/outputs/{out}"
                    final_path = os.path.join(self.output_dir, out)
                    tmp_path = os.path.join(self.output_dir, f".tmp_{uuid.uuid4().hex}_{out}")
                    try:
                        res = self._run_command(
                            [
                                "colab",
                                "--config",
                                self.config_path,
                                "download",
                                "-s",
                                self.session_name,
                                remote_path,
                                tmp_path,
                            ],
                            timeout=30.0,
                        )
                        if res.returncode == 0 and os.path.isfile(tmp_path):
                            os.replace(tmp_path, final_path)
                            self.artifacts_collected.append(out)
                        elif os.path.exists(tmp_path):
                            os.remove(tmp_path)
                    except Exception:
                        if os.path.exists(tmp_path):
                            try:
                                os.remove(tmp_path)
                            except Exception:
                                pass

        # 3. Handle VM teardown or keep-on-failure
        if self.vm_allocated:
            if self.args.keep_on_failure and self.execution_outcome != "success":
                self.vm_cleanup_outcome = "preserved"
                sys.stdout.write("[ai-playground] --keep-on-failure active; preserving VM session.\n")
                self._print_recovery_commands()
            else:
                sys.stdout.write(f"[ai-playground] Stopping VM session '{self.session_name}'...\n")
                try:
                    res = self._run_command(
                        ["colab", "--config", self.config_path, "stop", "-s", self.session_name],
                        timeout=60.0,
                    )
                    if res.returncode == 0:
                        self.vm_cleanup_outcome = "released"
                        try:
                            shutil.rmtree(self.temp_state_dir, ignore_errors=True)
                        except Exception:
                            pass
                    else:
                        self.vm_cleanup_outcome = "failed"
                        sys.stderr.write(
                            f"[ai-playground] Failed to stop VM '{self.session_name}': {res.stderr or res.stdout}\n"
                        )
                        self._print_recovery_commands()
                except Exception as exc:
                    self.vm_cleanup_outcome = "failed"
                    sys.stderr.write(
                        f"[ai-playground] Exception while stopping VM '{self.session_name}': {exc}\n"
                    )
                    self._print_recovery_commands()
        else:
            if self.vm_cleanup_outcome != "uncertain":
                self.vm_cleanup_outcome = "not_started"
            try:
                shutil.rmtree(self.temp_state_dir, ignore_errors=True)
            except Exception:
                pass

        # 4. Write run.json
        self._write_metadata()

    def run(self) -> int:
        """Execute the full Colab experiment lifecycle with signal and error safety."""
        # Atomically create fresh output directory
        try:
            os.mkdir(self.output_dir)
        except OSError as exc:
            shutil.rmtree(self.temp_state_dir, ignore_errors=True)
            sys.stderr.write(f"Failed to create fresh output directory '{self.output_dir}': {exc}\n")
            return 2

        # Setup SIGTERM handler
        def _sigterm_handler(signum, frame):
            raise TerminateRequested("Received SIGTERM signal")

        original_sigterm = signal.signal(signal.SIGTERM, _sigterm_handler)

        try:
            self._allocate_vm()
            self._setup_vm_directories()
            if self.args.requirements:
                self._install_requirements()
            if self.args.input:
                self._upload_inputs()
            self._run_user_script()
            self._check_execution_log()
            self._collect_artifacts()
        except KeyboardInterrupt:
            self.error_message = "Execution cancelled by KeyboardInterrupt"
            self.execution_outcome = "failure"
            sys.stderr.write(f"\n[ai-playground] {self.error_message}\n")
            self._cleanup_and_finalize()
            return 130
        except TerminateRequested:
            self.error_message = "Execution terminated by SIGTERM"
            self.execution_outcome = "failure"
            sys.stderr.write(f"\n[ai-playground] {self.error_message}\n")
            self._cleanup_and_finalize()
            return 143
        except subprocess.TimeoutExpired as exc:
            self.error_message = f"Execution timed out: {exc}"
            self.execution_outcome = "failure"
            sys.stderr.write(f"\n[ai-playground] {self.error_message}\n")
            self._cleanup_and_finalize()
            return 1
        except Exception as exc:
            self.error_message = str(exc)
            self.execution_outcome = "failure"
            sys.stderr.write(f"\n[ai-playground] Execution failed: {exc}\n")
            self._cleanup_and_finalize()
            return 1
        finally:
            signal.signal(signal.SIGTERM, original_sigterm)

        # Cleanup on success
        self._cleanup_and_finalize()

        if self.metadata_write_failed:
            return 1
        if self.execution_outcome == "success" and self.vm_cleanup_outcome == "released":
            return 0
        return 1


def main(argv: Optional[List[str]] = None) -> int:
    try:
        args = parse_args(argv)
        validate_pre_allocation(args)
    except ValidationError as err:
        sys.stderr.write(f"Validation error: {err}\n")
        return 2
    except SystemExit as err:
        return err.code if err.code is not None else 0

    runner = ColabRunner(args)
    return runner.run()


if __name__ == "__main__":
    sys.exit(main())
