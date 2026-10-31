#!/usr/bin/env python3
"""Guest SSH bootstrap and configuration script for Docker Sandboxes.

Prepares agent-only public-key OpenSSH server configuration inside the sandbox,
generates missing host keys on first run, configures a single safe SetEnv
directive containing only non-secret sbx runtime variables, and handles explicit
shutdown of the owned listener.

Must be run inside a Docker Sandbox with root privileges (via sudo -n).
"""

import argparse
import json
import os
import pwd
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

MARKER_PATH = Path("/etc/agent-harness/docker-sandbox")
GUARD_ENV_VARS = ("SANDBOX_ID", "SANDBOX_VM_ID", "SBX_AGENT")

CONFIG_PATH = Path("/etc/ssh/sshd_config.project")
PID_PATH = Path("/run/sshd-project.pid")
GUEST_PORT = 2222
RUN_SSHD_DIR = Path("/run/sshd")

AGENT_USER = "agent"
AGENT_SSH_DIR = Path("/home/agent/.ssh")
AUTHORIZED_KEYS_PATH = AGENT_SSH_DIR / "authorized_keys"

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

# Exact approved allowlist of non-secret runtime variables to pass into ssh sessions
ALLOWED_ENV_VARS = {
    "PATH",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "SSL_CERT_FILE",
    "NODE_EXTRA_CA_CERTS",
    "NODE_USE_ENV_PROXY",
    "SANDBOX_ID",
    "SANDBOX_VM_ID",
    "SANDBOX_NAME",
    "SBX_AGENT",
    "SBX_CRED_OPENAI_MODE",
    "SBX_CRED_ANTIGRAVITY_MODE",
}


def verify_marker(marker_path: Path = MARKER_PATH) -> None:
    """Verify that the sandbox marker exists, is regular, not a symlink, and owned by root."""
    if marker_path.is_symlink():
        raise RuntimeError(f"Sandbox marker {marker_path} must not be a symlink")
    if not marker_path.is_file():
        raise RuntimeError(f"Sandbox marker {marker_path} not found")
    st = marker_path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_gid != 0:
        raise RuntimeError(f"Sandbox marker {marker_path} must be a regular file owned by root:root (UID 0, GID 0)")


def verify_guard_env(env: dict[str, str]) -> None:
    """Verify all three required sandbox guard variables are present and non-empty."""
    missing = [k for k in GUARD_ENV_VARS if not env.get(k)]
    if missing:
        raise RuntimeError(f"Missing required sandbox guard variables: {', '.join(missing)}")


def extract_safe_environment(env: dict[str, str]) -> dict[str, str]:
    """Extract and strictly validate allowed runtime environment variables.

    Rejects credential-bearing proxy URLs, newlines, and unsafe quoting by raising ValueError.
    Does NOT silently omit invalid values.
    """
    safe = {}
    for key in ALLOWED_ENV_VARS:
        if key in env:
            val = env[key]
            if any(c in val for c in ("\n", "\r", "\0", '"', "\\")):
                raise ValueError(f"Unsafe character in environment variable '{key}'")
            if "proxy" in key.lower() and "no_proxy" not in key.lower():
                parsed = urllib.parse.urlsplit(val)
                if parsed.username or parsed.password:
                    raise ValueError(f"Credential-bearing proxy URL in '{key}' is prohibited")
            safe[key] = val
    return safe


def format_setenv_directive(safe_env: dict[str, str]) -> str:
    """Format safe environment variables into a single combined SetEnv directive."""
    if not safe_env:
        return ""
    tokens = []
    for k in sorted(safe_env.keys()):
        v = safe_env[k]
        token = f"{k}={v}"
        if any(c.isspace() for c in token):
            tokens.append(f'"{token}"')
        else:
            tokens.append(token)
    return "SetEnv " + " ".join(tokens)


def validate_public_key_text(text: str) -> tuple[str, str]:
    """Validate public key text, returning (key_line, fingerprint).

    Enforces exactly one public key line, validates OpenSSH wire structure via ssh-keygen,
    allows comments with spaces (split maxsplit=2), and rejects private keys or malformed base64 without IndexError.
    """
    for marker in PRIVATE_KEY_MARKERS:
        if marker in text:
            raise ValueError("Input appears to be a private key, not a public key!")

    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    if len(lines) != 1:
        raise ValueError(f"Expected exactly 1 public key line, found {len(lines)}")

    key_line = lines[0]
    parts = key_line.split(maxsplit=2)
    if len(parts) < 2:
        raise ValueError("Malformed public key: expected at least key type and base64 blob")

    key_type = parts[0]
    if key_type not in ALLOWED_KEY_TYPES:
        raise ValueError(f"Unsupported public key type: {key_type}")

    keygen_bin = shutil.which("ssh-keygen") or "/usr/bin/ssh-keygen"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as f:
        f.write(key_line + "\n")
        tmp_path = f.name

    try:
        res = subprocess.run([keygen_bin, "-l", "-f", tmp_path], capture_output=True, text=True, timeout=10)
        if res.returncode != 0:
            raise ValueError("Invalid public key structure: ssh-keygen verification failed")
        out_parts = res.stdout.strip().split()
        if len(out_parts) >= 2:
            fingerprint = out_parts[1]
        else:
            fingerprint = res.stdout.strip()
        return key_line, fingerprint
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _extract_key_sig(line: str) -> tuple[str, str] | None:
    """Extract (key_type, blob) from an authorized_keys line (with or without options)."""
    parts = line.strip().split()
    if not parts:
        return None
    for i, token in enumerate(parts):
        if token in ALLOWED_KEY_TYPES and i + 1 < len(parts):
            return token, parts[i + 1]
    return None


def install_authorized_key(
    key_line: str,
    auth_keys_path: Path = AUTHORIZED_KEYS_PATH,
    agent_user: str = AGENT_USER,
) -> None:
    """Safely install public key to authorized_keys.

    Refuses symlink targets, uses unique atomic temporary files, preserves existing
    restrictions on already-listed identical keys, and preserves safe modes.
    """
    ssh_dir = auth_keys_path.parent
    if ssh_dir.is_symlink():
        raise RuntimeError(f"SSH directory {ssh_dir} must not be a symlink")

    try:
        pw = pwd.getpwnam(agent_user)
        agent_uid, agent_gid = pw.pw_uid, pw.pw_gid
    except KeyError:
        agent_uid, agent_gid = 1000, 1000

    ssh_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(ssh_dir, agent_uid, agent_gid)
    os.chmod(ssh_dir, 0o700)

    if auth_keys_path.is_symlink():
        raise RuntimeError(f"Authorized keys file {auth_keys_path} must not be a symlink")

    existing_lines = []
    if auth_keys_path.exists():
        st = auth_keys_path.lstat()
        if not stat.S_ISREG(st.st_mode):
            raise RuntimeError(f"Authorized keys file {auth_keys_path} must be a regular file")
        content = auth_keys_path.read_text(encoding="utf-8")
        existing_lines = [l.strip() for l in content.splitlines() if l.strip()]

    new_sig = _extract_key_sig(key_line)
    if not new_sig:
        raise ValueError("Invalid public key format for installation")

    # If the key is already listed (even with options/restrictions), preserve it untouched
    for existing in existing_lines:
        ex_sig = _extract_key_sig(existing)
        if ex_sig and ex_sig == new_sig:
            os.chown(auth_keys_path, agent_uid, agent_gid)
            os.chmod(auth_keys_path, 0o600)
            return

    # Atomic write with unique temp file in ssh_dir
    with tempfile.NamedTemporaryFile("w", dir=ssh_dir, encoding="utf-8", delete=False) as tf:
        tmp_name = tf.name
        new_content = "\n".join(existing_lines + [key_line]) + "\n"
        tf.write(new_content)

    os.chown(tmp_name, agent_uid, agent_gid)
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, auth_keys_path)


def verify_guest_port_available(port: int = GUEST_PORT) -> None:
    """Preflight check: refuse existing unmanaged guest listener on port before mutating keys or config."""
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("::", port))
    except OSError as e:
        raise RuntimeError(f"Guest port {port} is already in use by an unmanaged listener: {e}")
    finally:
        s.close()


def ensure_host_keys() -> None:
    """Generate missing host keys if needed without touching existing keys."""
    keygen_bin = shutil.which("ssh-keygen") or "/usr/bin/ssh-keygen"
    subprocess.run([keygen_bin, "-A"], check=True, capture_output=True, timeout=15)


def get_host_key_fingerprints() -> list[str]:
    """Retrieve SHA256 fingerprints of installed public host keys."""
    keygen_bin = shutil.which("ssh-keygen") or "/usr/bin/ssh-keygen"
    pub_files = sorted(Path("/etc/ssh").glob("ssh_host_*_key.pub"))
    fingerprints = []
    for pub_file in pub_files:
        try:
            res = subprocess.run(
                [keygen_bin, "-l", "-f", str(pub_file)],
                capture_output=True,
                text=True,
                check=True,
                timeout=10,
            )
            fingerprints.append(res.stdout.strip())
        except Exception:
            pass
    return fingerprints


def get_host_public_keys() -> list[str]:
    """Retrieve contents of installed public host keys."""
    pub_files = sorted(Path("/etc/ssh").glob("ssh_host_*_key.pub"))
    keys = []
    for pub_file in pub_files:
        try:
            content = pub_file.read_text(encoding="utf-8").strip()
            if content:
                keys.append(content)
        except Exception:
            pass
    return keys


def generate_sshd_config(safe_env: dict[str, str]) -> str:
    """Generate hardened OpenSSH daemon configuration for sandbox."""
    RUN_SSHD_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    os.chmod(RUN_SSHD_DIR, 0o755)

    setenv_line = format_setenv_directive(safe_env)
    config_lines = [
        "# Generated by project-ssh guest-bootstrap. Do not edit manually.",
        f"Port {GUEST_PORT}",
        f"PidFile {PID_PATH}",
        "",
        "# Hardened agent-only authentication",
        "UsePAM yes",
        "AuthenticationMethods publickey",
        "PermitRootLogin no",
        "PasswordAuthentication no",
        "KbdInteractiveAuthentication no",
        "PubkeyAuthentication yes",
        "AuthorizedKeysFile .ssh/authorized_keys",
        "AllowUsers agent",
        "",
        "# Forwarding and features",
        "AllowAgentForwarding no",
        "X11Forwarding no",
        "AllowTcpForwarding local",
        "PermitTunnel no",
        "GatewayPorts no",
        "PrintMotd no",
    ]
    if setenv_line:
        config_lines.extend(["", "# Runtime environment", setenv_line])
    config_lines.append("")
    content = "\n".join(config_lines)

    CONFIG_PATH.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=CONFIG_PATH.parent, encoding="utf-8", delete=False) as tf:
        tmp_name = tf.name
        tf.write(content)

    os.chown(tmp_name, 0, 0)
    os.chmod(tmp_name, 0o644)
    os.replace(tmp_name, CONFIG_PATH)
    return content


def validate_sshd_config() -> None:
    """Validate sshd configuration file syntax."""
    sshd_bin = shutil.which("sshd") or "/usr/sbin/sshd"
    if not os.path.isfile(sshd_bin):
        raise RuntimeError(f"sshd binary not found at {sshd_bin}. Ensure openssh-server is installed.")
    res = subprocess.run([sshd_bin, "-t", "-f", str(CONFIG_PATH)], capture_output=True, text=True, timeout=10)
    if res.returncode != 0:
        raise RuntimeError(f"sshd configuration validation failed:\n{res.stderr.strip()}")


def self_install_to_system() -> None:
    """Copy current bootstrap script to /usr/local/bin/guest-bootstrap.py if not already present."""
    dest = Path("/usr/local/bin/guest-bootstrap.py")
    src = Path(__file__).resolve()
    if src != dest and dest.parent.is_dir():
        shutil.copy2(src, dest)
        os.chmod(dest, 0o755)


def get_process_stat(pid: int) -> tuple[str, int] | None:
    """Read (state, starttime) from /proc/<pid>/stat."""
    stat_path = Path(f"/proc/{pid}/stat")
    if not stat_path.exists():
        return None
    try:
        content = stat_path.read_text(encoding="utf-8")
        rparen = content.rfind(")")
        if rparen == -1:
            return None
        fields = content[rparen + 1:].split()
        state = fields[0]  # Field 3: state ('R', 'S', 'Z', etc.)
        starttime = int(fields[19])  # Field 22: starttime
        return state, starttime
    except (OSError, IndexError, ValueError):
        return None


def check_owned_listener() -> tuple[str, int | None, int | None]:
    """Inspect PID file and /proc to verify owned sshd listener.

    Returns (status, pid, starttime) where status is:
      'active': process is running, owned sshd with CONFIG_PATH
      'inactive': PID file does not exist
      'stale': PID file exists but process is dead, zombie, not sshd, or wrong config
    """
    verify_marker()

    if not PID_PATH.exists():
        return "inactive", None, None

    if PID_PATH.is_symlink():
        return "stale", None, None

    st = PID_PATH.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0:
        return "stale", None, None
    try:
        config_stat = CONFIG_PATH.lstat()
    except OSError:
        return "stale", None, None
    if not stat.S_ISREG(config_stat.st_mode) or config_stat.st_uid != 0:
        return "stale", None, None

    try:
        pid = int(PID_PATH.read_text(encoding="utf-8").strip())
        if pid <= 1:
            return "stale", None, None
    except Exception:
        return "stale", None, None

    proc_stat = get_process_stat(pid)
    if proc_stat is None:
        return "stale", pid, None

    state, starttime = proc_stat
    if state == "Z":  # Zombie process
        return "stale", pid, starttime

    # Verify /proc/<pid>/exe points to sshd
    try:
        exe_target = os.readlink(f"/proc/{pid}/exe")
        if not (exe_target.endswith("/sshd") or exe_target == "sshd"):
            return "stale", pid, starttime
    except OSError:
        return "stale", pid, starttime

    # Verify cmdline tokens (supporting both normal argv and OpenSSH rewritten title)
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
        tokens = [t for part in raw.split(b"\x00") for t in part.decode("utf-8", "replace").split() if t]
        config_matched = False
        for i, token in enumerate(tokens):
            if token == "-f" and i + 1 < len(tokens) and tokens[i + 1] == str(CONFIG_PATH):
                config_matched = True
                break
        if not config_matched:
            return "stale", pid, starttime
    except OSError:
        return "stale", pid, starttime

    return "active", pid, starttime


def prepare_guest(key_file: Path, safe_env: dict[str, str]) -> dict:
    """Execute guest preparation: preflight, host keys, authorized_keys, config, and self-install."""
    verify_marker()
    verify_guard_env(safe_env)

    sshd_bin = shutil.which("sshd") or "/usr/sbin/sshd"
    if not os.path.isfile(sshd_bin):
        raise RuntimeError("openssh-server is not installed in the sandbox. Install openssh-server first.")

    # Refuse if port is already in use by an unmanaged listener
    verify_guest_port_available(GUEST_PORT)

    if not key_file.is_file():
        raise ValueError(f"Public key file not found: {key_file}")
    key_text = key_file.read_text(encoding="utf-8")
    key_line, client_fp = validate_public_key_text(key_text)

    ensure_host_keys()
    install_authorized_key(key_line)
    generate_sshd_config(safe_env)
    validate_sshd_config()
    self_install_to_system()

    return {
        "status": "ready",
        "client_key_fingerprint": client_fp,
        "config_path": str(CONFIG_PATH),
        "pid_path": str(PID_PATH),
        "env_vars_set": sorted(safe_env.keys()),
        "host_key_fingerprints": get_host_key_fingerprints(),
        "host_public_keys": get_host_public_keys(),
    }


def stop_sshd() -> str:
    """Explicitly terminate owned sshd process verified by PID, starttime, exe, and config match."""
    verify_marker()

    status, pid, starttime = check_owned_listener()
    if status == "inactive":
        return "already_stopped"

    if status == "stale":
        try:
            PID_PATH.unlink()
        except OSError:
            pass
        return "stale_pid_removed"

    # Process is verified active owned sshd at pid with starttime
    current = get_process_stat(pid)
    if current is None or current[0] == "Z" or current[1] != starttime:
        PID_PATH.unlink(missing_ok=True)
        return "stopped"
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        try:
            PID_PATH.unlink()
        except OSError:
            pass
        return "stopped"

    terminated = False
    for _ in range(50):
        curr = get_process_stat(pid)
        if curr is None or curr[0] == "Z" or curr[1] != starttime:
            terminated = True
            break
        time.sleep(0.1)

    if not terminated:
        # Re-verify starttime and exe before SIGKILL to avoid signaling reused PID
        curr = get_process_stat(pid)
        if curr is not None and curr[1] == starttime and curr[0] != "Z":
            try:
                exe = os.readlink(f"/proc/{pid}/exe")
                if exe.endswith("/sshd") or exe == "sshd":
                    os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass

        for _ in range(10):
            curr = get_process_stat(pid)
            if curr is None or curr[0] == "Z" or curr[1] != starttime:
                terminated = True
                break
            time.sleep(0.1)

    if not terminated:
        raise RuntimeError(f"Owned sshd process {pid} failed to terminate within timeout")

    try:
        PID_PATH.unlink()
    except OSError:
        pass

    return "stopped"


def status_sshd() -> str:
    """Query whether owned sshd process is currently active."""
    status, _, _ = check_owned_listener()
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description="Guest SSH bootstrap helper for Docker Sandboxes")
    subparsers = parser.add_subparsers(dest="action", required=True)

    # prepare
    prep_p = subparsers.add_parser("prepare", help="Prepare guest SSH environment")
    prep_p.add_argument("--key-file", required=True, type=Path, help="Path to staged public key")
    prep_p.add_argument("--env-json", type=str, default=None, help="JSON serialized safe environment from unprivileged caller")

    # stop
    subparsers.add_parser("stop", help="Stop guest SSH daemon")

    # status
    subparsers.add_parser("status", help="Query guest SSH daemon status")

    args = parser.parse_args()

    # Pre-elevation environment capture & guard verification
    if os.geteuid() != 0:
        verify_marker()
        verify_guard_env(dict(os.environ))
        if args.action == "prepare":
            safe_env = extract_safe_environment(dict(os.environ))
            cmd = [
                "sudo",
                "-n",
                sys.executable,
                str(Path(__file__).resolve()),
                "prepare",
                "--key-file",
                str(args.key_file),
                "--env-json",
                json.dumps(safe_env),
            ]
            os.execvp("sudo", cmd)
        elif args.action == "stop":
            cmd = ["sudo", "-n", sys.executable, str(Path(__file__).resolve()), "stop"]
            os.execvp("sudo", cmd)
        elif args.action == "status":
            cmd = ["sudo", "-n", sys.executable, str(Path(__file__).resolve()), "status"]
            os.execvp("sudo", cmd)

    # Running elevated as root
    try:
        verify_marker()
        if args.action == "prepare":
            if args.env_json:
                parsed_env = json.loads(args.env_json)
                safe_env = extract_safe_environment(parsed_env)
            else:
                verify_guard_env(dict(os.environ))
                safe_env = extract_safe_environment(dict(os.environ))
            verify_guard_env(safe_env)
            res = prepare_guest(key_file=args.key_file, safe_env=safe_env)
            print("guest_prepare_status: ready")
            print(json.dumps(res))
            return 0
        elif args.action == "stop":
            outcome = stop_sshd()
            print(f"guest_stop_status: {outcome}")
            return 0
        elif args.action == "status":
            stat_res = status_sshd()
            print(f"guest_sshd_status: {stat_res}")
            return 0 if stat_res == "active" else 1
    except Exception as exc:
        sys.stderr.write(f"Error: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
