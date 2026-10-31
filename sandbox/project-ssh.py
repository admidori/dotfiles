#!/usr/bin/env python3
"""Project Sandbox SSH lifecycle management tool.

Provides explicit, repeatable start/stop/status for localhost-only SSH access to
Docker Sandboxes. Binds exclusively to [::1]:PORT:2222/tcp6 on the host and runs
an OpenSSH server instance inside the guest under a transient WSL systemd user unit.

Usage:
  python3 sandbox/project-ssh.py start NAME --public-key PATH [--port 40222]
  python3 sandbox/project-ssh.py stop NAME
  python3 sandbox/project-ssh.py status NAME [--json]
"""

import argparse
import fcntl
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_PORT = 40222
GUEST_SSH_PORT = 2222
CMD_TIMEOUT = 15

NAME_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9.-]{1,63}$")

ALLOWED_KEY_TYPES = {
    "ssh-rsa",
    "ssh-dss",
    "ssh-ed25519",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
}

PRIVATE_KEY_MARKERS = [
    "BEGIN OPENSSH PRIVATE KEY",
    "BEGIN RSA PRIVATE KEY",
    "BEGIN DSA PRIVATE KEY",
    "BEGIN EC PRIVATE KEY",
    "BEGIN PRIVATE KEY",
]


def validate_sandbox_name(name: str) -> str:
    """Validate sandbox name against injection, dash/period prefixes, and format requirements."""
    if not name or not NAME_PATTERN.match(name) or name.startswith("-") or name.startswith(".") or name.endswith("-") or name.endswith("."):
        raise ValueError(
            f"Invalid sandbox name '{name}'. Must be 2-64 characters matching [a-zA-Z0-9][a-zA-Z0-9.-]* (no underscores, cannot start or end with '-' or '.')"
        )
    return name


def validate_port(port: int) -> int:
    """Validate TCP port number."""
    if not isinstance(port, int) or port < 1024 or port > 65535:
        raise ValueError(f"Invalid host port {port}. Must be an integer between 1024 and 65535.")
    return port


def validate_public_key_file(path: Path) -> tuple[str, str]:
    """Verify that file exists, is regular non-symlink file <= 8192 bytes, and contains exactly 1 valid public key.

    Supports comments containing spaces via split(maxsplit=2).
    Returns (key_line, fingerprint).
    """
    if not path.is_file():
        raise ValueError(f"Public key file not found: {path}")
    if path.is_symlink():
        raise ValueError(f"Public key file must not be a symlink: {path}")
    if path.stat().st_size > 8192:
        raise ValueError(f"Public key file too large ({path.stat().st_size} bytes, max 8192 bytes)")

    content = path.read_text(encoding="utf-8")
    for marker in PRIVATE_KEY_MARKERS:
        if marker in content:
            raise ValueError(f"File {path} appears to contain a private key! Refusing to proceed.")

    lines = [line.strip() for line in content.splitlines() if line.strip() and not line.strip().startswith("#")]
    if len(lines) != 1:
        raise ValueError(f"Public key file {path} must contain exactly 1 public key line (found {len(lines)})")

    key_line = lines[0]
    parts = key_line.split(maxsplit=2)
    if len(parts) < 2:
        raise ValueError(f"Malformed public key in {path}: expected at least key type and base64 blob")

    key_type = parts[0]
    if key_type not in ALLOWED_KEY_TYPES:
        raise ValueError(f"Unsupported public key type in {path}: {key_type}")

    keygen_bin = shutil.which("ssh-keygen") or "/usr/bin/ssh-keygen"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tf:
        tf.write(key_line + "\n")
        tmp_path = tf.name

    try:
        res = subprocess.run([keygen_bin, "-l", "-f", tmp_path], capture_output=True, text=True, timeout=10)
        if res.returncode != 0:
            raise ValueError(f"Invalid public key structure in {path}: ssh-keygen verification failed")
        out_parts = res.stdout.strip().split()
        fingerprint = out_parts[1] if len(out_parts) >= 2 else res.stdout.strip()
        return key_line, fingerprint
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def get_state_dir(create: bool = True) -> Path:
    """Retrieve state directory under XDG_STATE_HOME. If create=False, does not mutate directory."""
    xdg_state = os.environ.get("XDG_STATE_HOME")
    if xdg_state:
        base = Path(xdg_state)
    else:
        base = Path.home() / ".local" / "state"
    state_dir = base / "project-ssh"

    if create:
        state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(state_dir, 0o700)
    return state_dir


def get_guest_bootstrap_path() -> Path:
    """Find the canonical guest bootstrap script."""
    bootstrap = Path(__file__).resolve().parent / "kits" / "codex-workload" / "guest-bootstrap.py"
    if not bootstrap.is_file():
        raise FileNotFoundError(f"Canonical guest-bootstrap.py not found at {bootstrap}")
    return bootstrap


def get_unit_name(name: str) -> str:
    """Derive collision-free systemd unit name for the sandbox SSH service.

    Since sandbox names only contain [a-zA-Z0-9.-] and no underscores, escaping '.' as '_2e'
    guarantees unique, reversible, collision-free unit names.
    """
    escaped = name.replace(".", "_2e")
    return f"sbx-ssh-{escaped}"


class SandboxLock:
    """Advisory flock on state directory to prevent concurrent mutations for the same sandbox."""

    def __init__(self, name: str, state_dir: Path):
        self.lock_path = state_dir / f"{name}.lock"
        self._fd = None

    def __enter__(self):
        # Open with O_NOFOLLOW to avoid symlink traversal
        flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self._fd = os.open(self.lock_path, flags, 0o600)
        try:
            fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError) as e:
            os.close(self._fd)
            self._fd = None
            raise RuntimeError(
                f"Another project-ssh operation is currently in progress for sandbox '{self.lock_path.stem}'"
            ) from e
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            finally:
                os.close(self._fd)
                self._fd = None


def get_sandbox_info(name: str, sbx_bin: str = "sbx") -> dict | None:
    """Query sandbox metadata via read-only 'sbx ls --json'. Does not start stopped guests."""
    try:
        res = subprocess.run([sbx_bin, "ls", "--json"], capture_output=True, text=True, check=True, timeout=CMD_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Command '{sbx_bin} ls --json' timed out after {CMD_TIMEOUT}s. Sbx or keyring may be locked.")
    try:
        data = json.loads(res.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Failed to parse 'sbx ls --json' output: {e}")
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and item.get("name") == name:
                return item
    return None


def get_all_sandbox_port_mappings(sandbox_data: dict, guest_port: int = GUEST_SSH_PORT) -> list[dict]:
    """Find all published port mappings for guest port in sandbox data."""
    matches = []
    for p in sandbox_data.get("ports", []) or []:
        if p.get("sandbox_port") == guest_port:
            matches.append(p)
    return matches


def get_unit_status(unit_name: str, systemctl_bin: str = "systemctl") -> tuple[str, bool]:
    """Check active state of systemd user unit.

    Returns (status_str, is_clean). Missing unit is considered clean inactive state.
    D-Bus/systemctl execution errors return is_clean=False.
    """
    cmd = [systemctl_bin, "--user", "is-active", unit_name]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=CMD_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "timeout", False
    status = res.stdout.strip()
    if res.returncode == 0 and status == "active":
        return "active", True
    # Exit 3: unit inactive or failed; exit 4: unit not found
    if res.returncode in (3, 4) and status in ("inactive", "failed", "unknown"):
        return status, True
    return status if status else "error", False


def read_state_file(state_file: Path) -> dict | None:
    """Read and validate local state file with strict mode and permission checks."""
    if not state_file.exists():
        return None
    if state_file.is_symlink():
        raise RuntimeError(f"State file {state_file} must not be a symlink")
    st = state_file.lstat()
    if not stat.S_ISREG(st.st_mode):
        raise RuntimeError(f"State file {state_file} must be a regular file")
    mode = st.st_mode & 0o777
    if mode not in (0o600, 0o400):
        raise RuntimeError(f"State file {state_file} has unsafe permissions ({oct(mode)}), expected 0600")

    try:
        data = json.loads(state_file.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("State data must be a JSON object")
        return data
    except Exception as e:
        raise RuntimeError(f"Failed to parse state file {state_file}: {e}")


def write_state_file(state_file: Path, data: dict) -> None:
    """Write local state file atomically with 0600 permissions."""
    state_dir = state_file.parent
    with tempfile.NamedTemporaryFile("w", dir=state_dir, encoding="utf-8", delete=False) as tf:
        tmp_name = tf.name
        tf.write(json.dumps(data, indent=2))

    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, state_file)


def status_sandbox(name: str, as_json: bool = False, sbx_bin: str = "sbx", systemctl_bin: str = "systemctl") -> int:
    """Genuinely read-only status check for sandbox and SSH service."""
    validate_sandbox_name(name)
    sbx_info = get_sandbox_info(name, sbx_bin=sbx_bin)
    unit_name = get_unit_name(name)
    unit_status, is_clean = get_unit_status(unit_name, systemctl_bin=systemctl_bin)

    if not is_clean:
        sys.stderr.write(f"Error querying systemd unit status for '{unit_name}'. D-Bus connection or permissions failed.\n")
        return 1

    state_dir = get_state_dir(create=False)
    state_file = state_dir / f"{name}.json"
    saved_state = read_state_file(state_file)

    if sbx_info is None:
        result = {
            "name": name,
            "sandbox_status": "not_found",
            "ssh_service": "inactive",
            "unit": unit_name,
            "port_mappings": [],
            "published_port": None,
            "saved_state": saved_state,
        }
        if as_json:
            print(json.dumps(result, indent=2))
        else:
            print(f"Sandbox '{name}' not found.")
        return 1

    mappings = get_all_sandbox_port_mappings(sbx_info, GUEST_SSH_PORT)
    published_port = None
    for m in mappings:
        if m.get("host_ip") == "::1" and m.get("protocol") == "tcp6":
            published_port = m.get("host_port")
            break

    result = {
        "name": name,
        "sandbox_status": sbx_info.get("status", "unknown"),
        "ssh_service": unit_status,
        "unit": unit_name,
        "port_mappings": mappings,
        "published_port": published_port,
        "saved_state": saved_state,
    }

    if as_json:
        print(json.dumps(result, indent=2))
    else:
        print(f"Sandbox:        {name}")
        print(f"Sandbox Status: {result['sandbox_status']}")
        print(f"SSH Service:    {result['ssh_service']} (unit: {unit_name})")
        if mappings:
            for m in mappings:
                print(f"Published Port: [{m.get('host_ip')}]:{m.get('host_port')} -> {GUEST_SSH_PORT}/{m.get('protocol')}")
        else:
            print("Published Port: (none)")
    return 0


def start_sandbox_ssh(
    name: str,
    public_key_path: Path,
    port: int = DEFAULT_PORT,
    sbx_bin: str = "sbx",
    systemctl_bin: str = "systemctl",
    systemd_run_bin: str = "systemd-run",
) -> int:
    """Start SSH service for sandbox."""
    validate_sandbox_name(name)
    validate_port(port)
    _, client_fp = validate_public_key_file(public_key_path)

    state_dir = get_state_dir(create=True)
    with SandboxLock(name, state_dir):
        sbx_info = get_sandbox_info(name, sbx_bin=sbx_bin)
        if sbx_info is None:
            raise RuntimeError(f"Sandbox '{name}' does not exist. Create it first using 'sbx create'.")

        unit_name = get_unit_name(name)
        state_file = state_dir / f"{name}.json"
        saved_state = read_state_file(state_file)

        # If saved state exists, validate fields against requested operation under lock
        if saved_state is not None:
            saved_name = saved_state.get("name")
            saved_unit = saved_state.get("unit")
            saved_port = saved_state.get("port")
            saved_fp = saved_state.get("key_fingerprint")
            saved_ip = saved_state.get("host_ip")
            saved_proto = saved_state.get("protocol")

            mismatch = (
                saved_name != name
                or saved_unit != unit_name
                or saved_port != port
                or saved_fp != client_fp
                or saved_ip != "::1"
                or saved_proto != "tcp6"
            )
            if mismatch:
                raise RuntimeError(
                    f"Sandbox '{name}' has existing managed state with conflicting parameters "
                    f"(port {saved_port}, key {saved_fp}). Refusing to overwrite state. Run 'project-ssh.py stop {name}' first."
                )

        # Inspect all port mappings for guest port 2222
        existing_mappings = get_all_sandbox_port_mappings(sbx_info, GUEST_SSH_PORT)

        # Refuse unmanaged or conflicting mappings (wildcard, wrong ip/protocol, or wrong port)
        for m in existing_mappings:
            is_exact = (
                m.get("host_ip") == "::1"
                and m.get("protocol") == "tcp6"
                and m.get("host_port") == port
            )
            if not is_exact:
                raise RuntimeError(
                    f"Sandbox '{name}' has conflicting or unmanaged mapping for port {GUEST_SSH_PORT}: "
                    f"[{m.get('host_ip')}]:{m.get('host_port')}/{m.get('protocol')}. Refusing to proceed. Stop the conflicting mapping first."
                )

        unit_status, _ = get_unit_status(unit_name, systemctl_bin=systemctl_bin)

        # Check idempotent repeated start
        if existing_mappings and saved_state:
            if unit_status == "active":
                guest_stat = subprocess.run(
                    [sbx_bin, "exec", name, "python3", "/usr/local/bin/guest-bootstrap.py", "status"],
                    capture_output=True,
                    text=True,
                    timeout=CMD_TIMEOUT,
                )
                if guest_stat.returncode == 0:
                    print(f"SSH service is already active for sandbox '{name}' on [::1]:{port}.")
                    return 0

        # Refuse if mapping exists without matching saved state
        if existing_mappings and not saved_state:
            raise RuntimeError(
                f"Sandbox '{name}' already has port {GUEST_SSH_PORT} published, but no owned state exists. Refusing to adopt unmanaged mapping."
            )

        if saved_state:
            raise RuntimeError(
                f"Sandbox '{name}' has unfinished managed state. Run 'project-ssh.py stop {name}' before restarting."
            )

        # Record operation intent before any mutations
        intent_state = {
            "name": name,
            "port": port,
            "unit": unit_name,
            "key_fingerprint": client_fp,
            "host_ip": "::1",
            "protocol": "tcp6",
            "listener_started": False,
            "status": "starting",
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        write_state_file(state_file, intent_state)

        # 1. Publish port mapping if not already published
        if not existing_mappings:
            publish_spec = f"[::1]:{port}:{GUEST_SSH_PORT}/tcp6"
            try:
                res = subprocess.run(
                    [sbx_bin, "ports", name, "--publish", publish_spec],
                    capture_output=True,
                    text=True,
                    timeout=CMD_TIMEOUT,
                )
            except subprocess.TimeoutExpired:
                raise RuntimeError(f"Timeout publishing port mapping for sandbox '{name}'. Sbx daemon may be unresponsive.")
            if res.returncode != 0:
                raise RuntimeError(f"Failed to publish port for sandbox '{name}':\n{res.stderr.strip()}")

        # 2. Stage bootstrap script and public key
        stage_id = uuid.uuid4().hex[:12]
        stage_dir = f"/tmp/sbx-ssh-stage-{stage_id}"
        mkdir_res = subprocess.run([sbx_bin, "exec", name, "mkdir", "-p", stage_dir], capture_output=True, text=True, timeout=CMD_TIMEOUT)
        if mkdir_res.returncode != 0:
            raise RuntimeError(f"Failed to create staging directory in sandbox:\n{mkdir_res.stderr.strip()}")

        prep_data = {}
        try:
            # Copy public key
            cp_key = subprocess.run(
                [sbx_bin, "cp", str(public_key_path.resolve()), f"{name}:{stage_dir}/authorized_key.pub"],
                capture_output=True,
                text=True,
                timeout=CMD_TIMEOUT,
            )
            if cp_key.returncode != 0:
                raise RuntimeError(f"Failed to copy public key to sandbox:\n{cp_key.stderr.strip()}")

            # Copy canonical guest bootstrap
            bootstrap_path = get_guest_bootstrap_path()
            cp_boot = subprocess.run(
                [sbx_bin, "cp", str(bootstrap_path.resolve()), f"{name}:{stage_dir}/guest-bootstrap.py"],
                capture_output=True,
                text=True,
                timeout=CMD_TIMEOUT,
            )
            if cp_boot.returncode != 0:
                raise RuntimeError(f"Failed to copy bootstrap script to sandbox:\n{cp_boot.stderr.strip()}")

            # 3. Execute guest preparation AS AGENT (bootstrap extracts safe env before elevating via sudo -n)
            prep_cmd = [
                sbx_bin,
                "exec",
                name,
                "python3",
                f"{stage_dir}/guest-bootstrap.py",
                "prepare",
                "--key-file",
                f"{stage_dir}/authorized_key.pub",
            ]
            prep_res = subprocess.run(prep_cmd, capture_output=True, text=True, timeout=CMD_TIMEOUT)
            if prep_res.returncode != 0:
                raise RuntimeError(f"Guest SSH preparation failed:\n{prep_res.stderr.strip() or prep_res.stdout.strip()}")

            for line in prep_res.stdout.splitlines():
                if line.startswith("{") and line.endswith("}"):
                    try:
                        prep_data = json.loads(line)
                    except Exception:
                        pass
        finally:
            subprocess.run([sbx_bin, "exec", name, "rm", "-rf", stage_dir], capture_output=True, timeout=CMD_TIMEOUT)

        # 4. Stop existing unit if it was active
        if unit_status == "active":
            subprocess.run([systemctl_bin, "--user", "stop", "--no-block", unit_name], capture_output=True, timeout=CMD_TIMEOUT)

        # 5. Start transient user unit holding sshd in foreground
        run_cmd = [
            systemd_run_bin,
            "--user",
            f"--unit={unit_name}",
            "--collect",
            "--property=Restart=no",
            "--property=TimeoutStopSec=5",
            sbx_bin,
            "exec",
            name,
            "sudo",
            "-n",
            "/usr/sbin/sshd",
            "-D",
            "-f",
            "/etc/ssh/sshd_config.project",
        ]
        start_res = subprocess.run(run_cmd, capture_output=True, text=True, timeout=CMD_TIMEOUT)
        if start_res.returncode != 0:
            raise RuntimeError(f"Failed to start systemd service unit '{unit_name}':\n{start_res.stderr.strip()}")

        # Record that sshd was launched
        intent_state["listener_started"] = True
        write_state_file(state_file, intent_state)

        # 6. Boundedly verify BOTH systemd unit AND guest listener together
        verified = False
        stat = "unknown"
        for _ in range(25):
            stat, _ = get_unit_status(unit_name, systemctl_bin=systemctl_bin)
            if stat == "active":
                # Check guest listener status via elevated status check
                try:
                    check_guest = subprocess.run(
                        [sbx_bin, "exec", name, "python3", "/usr/local/bin/guest-bootstrap.py", "status"],
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    if check_guest.returncode == 0:
                        verified = True
                        break
                except subprocess.TimeoutExpired:
                    pass
            time.sleep(0.2)

        if not verified:
            intent_state["status"] = "failed"
            write_state_file(state_file, intent_state)
            raise RuntimeError(
                f"SSH service unit '{unit_name}' failed to achieve active listener state (unit status: {stat}). Run 'project-ssh.py stop {name}' to clean up."
            )

        # 7. Update state file to active
        intent_state["status"] = "active"
        intent_state["updated_at"] = datetime.now(timezone.utc).isoformat()
        write_state_file(state_file, intent_state)

        # 8. Print connection guidance
        print(f"SSH service started successfully for sandbox '{name}'.")
        print(f"  Listener:      [::1]:{port} -> {GUEST_SSH_PORT}/tcp6")
        print(f"  Systemd Unit:  {unit_name}")

        fps = prep_data.get("host_key_fingerprints", [])
        if fps:
            print("  Host Key Fingerprints:")
            for fp in fps:
                print(f"    - {fp}")

        print("\nWindows client configuration (~/.ssh/config):")
        print(f"  Host sbx-{name}")
        print("    HostName 127.0.0.1")
        print(f"    Port {port}")
        print("    User agent")
        print(f"    ProxyCommand wsl.exe -d Debian -- /usr/bin/nc -6 ::1 {port}")
        print("\nHost direct connection:")
        print(f"  ssh -p {port} agent@::1")
        return 0


def stop_sandbox_ssh(
    name: str,
    sbx_bin: str = "sbx",
    systemctl_bin: str = "systemctl",
) -> int:
    """Stop SSH service for sandbox without affecting container filesystem or other services.

    Removes only exact recorded mapping; without owned state, makes zero mutations.
    Retains state and returns nonzero if any cleanup step encounters an unexpected error.
    """
    validate_sandbox_name(name)
    state_dir = get_state_dir(create=False)
    state_file = state_dir / f"{name}.json"
    saved_state = read_state_file(state_file)

    # Without owned state, make NO mutations whatsoever
    if saved_state is None:
        print(f"No managed SSH state found for sandbox '{name}'.")
        return 0

    state_dir = get_state_dir(create=True)
    with SandboxLock(name, state_dir):
        saved_state = read_state_file(state_file)
        if saved_state is None:
            print(f"No managed SSH state found for sandbox '{name}'.")
            return 0
        recorded_port = saved_state.get("port")
        unit_name = get_unit_name(name)
        validate_port(recorded_port)
        if (saved_state.get("name") != name or saved_state.get("unit") != unit_name
                or saved_state.get("host_ip") != "::1" or saved_state.get("protocol") != "tcp6"):
            raise RuntimeError(f"Invalid managed SSH state for '{name}'; refusing cleanup.")
        listener_started = saved_state.get("listener_started", True)
        has_error = False

        # 1. Stop host systemd unit
        try:
            unit_res = subprocess.run([systemctl_bin, "--user", "stop", "--no-block", unit_name], capture_output=True, text=True, timeout=CMD_TIMEOUT)
            # Exit 0 or exit 4 (unit not found) are acceptable; D-Bus or permission failures are errors
            if unit_res.returncode not in (0, 4):
                unit_stat, is_clean = get_unit_status(unit_name, systemctl_bin=systemctl_bin)
                if not is_clean or unit_stat in ("error", "timeout"):
                    sys.stderr.write(f"Error stopping systemd unit {unit_name}: {unit_res.stderr.strip()}\n")
                    has_error = True
        except subprocess.TimeoutExpired:
            sys.stderr.write(f"Timeout stopping systemd unit {unit_name}.\n")
            has_error = True

        sbx_info = get_sandbox_info(name, sbx_bin=sbx_bin)
        if sbx_info is not None:
            sandbox_status = sbx_info.get("status")

            # 2. Stop guest listener ONLY if sandbox is running. Never call sbx exec on stopped sandbox!
            if sandbox_status == "running" and listener_started:
                # Stage canonical helper or call installed helper
                stop_cmd = [sbx_bin, "exec", name, "python3", "/usr/local/bin/guest-bootstrap.py", "stop"]
                try:
                    stop_res = subprocess.run(stop_cmd, capture_output=True, text=True, timeout=CMD_TIMEOUT)
                    if stop_res.returncode != 0:
                        # If /usr/local/bin/guest-bootstrap.py is missing (e.g. partial start failed early), stage canonical helper
                        stage_stop_path = f"/tmp/sbx-ssh-stop-{uuid.uuid4().hex[:8]}.py"
                        cp_res = subprocess.run(
                            [sbx_bin, "cp", str(get_guest_bootstrap_path().resolve()), f"{name}:{stage_stop_path}"],
                            capture_output=True,
                            text=True,
                            timeout=CMD_TIMEOUT,
                        )
                        if cp_res.returncode == 0:
                            stop_res = subprocess.run(
                                [sbx_bin, "exec", name, "python3", stage_stop_path, "stop"],
                                capture_output=True,
                                text=True,
                                timeout=CMD_TIMEOUT,
                            )
                            subprocess.run([sbx_bin, "exec", name, "rm", "-f", stage_stop_path], capture_output=True, timeout=5)

                        if stop_res.returncode != 0:
                            sys.stderr.write(f"Error terminating guest sshd: {stop_res.stderr.strip()}\n")
                            has_error = True
                except subprocess.TimeoutExpired:
                    sys.stderr.write(f"Timeout stopping guest sshd on '{name}'.\n")
                    has_error = True

            # 3. Unpublish ONLY the recorded mapping
            existing_mappings = get_all_sandbox_port_mappings(sbx_info, GUEST_SSH_PORT)
            for m in existing_mappings:
                if m.get("host_ip") == "::1" and m.get("protocol") == "tcp6" and m.get("host_port") == recorded_port:
                    unpub_spec = f"[::1]:{recorded_port}:{GUEST_SSH_PORT}/tcp6"
                    try:
                        unpub_res = subprocess.run(
                            [sbx_bin, "ports", name, "--unpublish", unpub_spec],
                            capture_output=True,
                            text=True,
                            timeout=CMD_TIMEOUT,
                        )
                        if unpub_res.returncode != 0:
                            sys.stderr.write(f"Error unpublishing port {unpub_spec}: {unpub_res.stderr.strip()}\n")
                            has_error = True
                    except subprocess.TimeoutExpired:
                        sys.stderr.write(f"Timeout unpublishing port {unpub_spec}.\n")
                        has_error = True

        # The sbx exec client can remain deactivating until its guest sshd exits.
        # Confirm completion after guest teardown, allowing systemd to settle.
        deadline = time.monotonic() + 10
        while True:
            unit_stat, is_clean = get_unit_status(unit_name, systemctl_bin=systemctl_bin)
            if is_clean and unit_stat in ("inactive", "failed", "unknown"):
                break
            if unit_stat not in ("active", "activating", "deactivating") or time.monotonic() >= deadline:
                sys.stderr.write(f"Systemd unit {unit_name} remained active or in error state after stop request.\n")
                has_error = True
                break
            time.sleep(0.2)

        if has_error:
            # Retain state file for recovery and return nonzero
            sys.stderr.write(f"Stop encountered errors for '{name}'. State retained.\n")
            return 1

        # All steps succeeded cleanly: remove state file
        if state_file.exists():
            state_file.unlink()

        print(f"SSH service stopped for sandbox '{name}'.")
        print(f"Note: Sandbox container remains intact. To stop the sandbox itself, run: sbx stop {name}")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="project-ssh",
        description="Manage localhost-only SSH lifecycle for Docker Sandboxes.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # start
    start_p = subparsers.add_parser("start", help="Start SSH listener for a sandbox")
    start_p.add_argument("name", help="Sandbox name")
    start_p.add_argument("--public-key", required=True, type=Path, help="Path to host public key")
    start_p.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Host loopback port to bind (default: {DEFAULT_PORT})",
    )

    # stop
    stop_p = subparsers.add_parser("stop", help="Stop SSH listener for a sandbox")
    stop_p.add_argument("name", help="Sandbox name")

    # status
    stat_p = subparsers.add_parser("status", help="Query SSH status for a sandbox")
    stat_p.add_argument("name", help="Sandbox name")
    stat_p.add_argument("--json", action="store_true", help="Output status as JSON")

    args = parser.parse_args()

    sbx_bin = shutil.which("sbx") or "/usr/bin/sbx"
    systemctl_bin = shutil.which("systemctl") or "/usr/bin/systemctl"
    systemd_run_bin = shutil.which("systemd-run") or "/usr/bin/systemd-run"

    try:
        if args.command == "start":
            return start_sandbox_ssh(
                name=args.name,
                public_key_path=args.public_key,
                port=args.port,
                sbx_bin=sbx_bin,
                systemctl_bin=systemctl_bin,
                systemd_run_bin=systemd_run_bin,
            )
        elif args.command == "stop":
            return stop_sandbox_ssh(
                name=args.name,
                sbx_bin=sbx_bin,
                systemctl_bin=systemctl_bin,
            )
        elif args.command == "status":
            return status_sandbox(
                name=args.name,
                as_json=args.json,
                sbx_bin=sbx_bin,
                systemctl_bin=systemctl_bin,
            )
    except Exception as exc:
        sys.stderr.write(f"Error: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
