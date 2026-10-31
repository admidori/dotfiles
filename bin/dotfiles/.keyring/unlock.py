#!/usr/bin/python3 -I
"""Unlock an existing GNOME login keyring using a host-side 1Password CLI."""

import argparse
import json
import os
from pathlib import Path
import resource
import socket
import stat
import struct
import subprocess
import sys

SERVICE = "org.freedesktop.secrets"
COLLECTION = "/org/freedesktop/secrets/collection/login"
BUSCTL = "/usr/bin/busctl"
SYSTEMD_SERVICE = "org.freedesktop.systemd1"
SYSTEMD_PATH = "/org/freedesktop/systemd1"
SYSTEMD_MANAGER = "org.freedesktop.systemd1.Manager"
SYSTEMD_UNIT = "org.freedesktop.systemd1.Unit"
SYSTEMD_SERVICE_IFACE = "org.freedesktop.systemd1.Service"
SYSTEMD_SOCKET_IFACE = "org.freedesktop.systemd1.Socket"
KEYRING_SERVICE = "gnome-keyring-daemon.service"
KEYRING_SOCKET = "gnome-keyring-daemon.socket"


class UnlockError(Exception):
    """An error whose message is safe to show without secret values."""


def bus_json(*arguments):
    env = os.environ.copy()
    env.setdefault("DBUS_SESSION_BUS_ADDRESS",
                   f"unix:path=/run/user/{os.getuid()}/bus")
    result = subprocess.run(
        [BUSCTL, "--user", "--json=short", "--timeout=5", *arguments],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env=env, timeout=10,
    )
    if result.returncode:
        raise UnlockError("Cannot contact the login keyring on the user D-Bus.")
    try:
        return json.loads(result.stdout)["data"]
    except (ValueError, KeyError, TypeError):
        raise UnlockError("Unexpected D-Bus response.") from None


def is_locked():
    value = bus_json("get-property", SERVICE, COLLECTION,
                     "org.freedesktop.Secret.Collection", "Locked")
    if type(value) is not bool:
        raise UnlockError("Unexpected keyring lock state.")
    return value


def control_endpoint():
    directory = bus_json("call", SERVICE, "/org/gnome/keyring/daemon",
                         "org.gnome.keyring.Daemon", "GetControlDirectory")
    owner = bus_json("call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
                     "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                     "s", SERVICE)
    if (not isinstance(directory, list) or len(directory) != 1
            or not isinstance(directory[0], str)
            or not Path(directory[0]).is_absolute()
            or not isinstance(owner, list) or len(owner) != 1
            or type(owner[0]) is not int or owner[0] <= 0):
        raise UnlockError("Unexpected keyring control endpoint.")
    return Path(directory[0]) / "control", owner[0]


def is_valid_unit_path(unit_data):
    if (not isinstance(unit_data, list) or len(unit_data) != 1
            or not isinstance(unit_data[0], str)
            or not unit_data[0].isascii()
            or not unit_data[0].startswith("/org/freedesktop/systemd1/unit/")
            or len(unit_data[0]) <= len("/org/freedesktop/systemd1/unit/")
            or "//" in unit_data[0] or unit_data[0].endswith("/")
            or not all(c.isalnum() or c in "_/" for c in unit_data[0])):
        return False
    return True


def verify_systemd_peer(peer_pid, control_path, daemon_pid):
    try:
        manager = bus_json(
            "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "GetConnectionUnixProcessID",
            "s", SYSTEMD_SERVICE,
        )
        if (not isinstance(manager, list) or len(manager) != 1
                or type(manager[0]) is not int or manager[0] <= 0
                or manager[0] != peer_pid):
            return False

        service_data = bus_json(
            "call", SYSTEMD_SERVICE, SYSTEMD_PATH,
            SYSTEMD_MANAGER, "GetUnit", "s", KEYRING_SERVICE,
        )
        socket_data = bus_json(
            "call", SYSTEMD_SERVICE, SYSTEMD_PATH,
            SYSTEMD_MANAGER, "GetUnit", "s", KEYRING_SOCKET,
        )
        if (not is_valid_unit_path(service_data)
                or not is_valid_unit_path(socket_data)):
            return False
        service_path = service_data[0]
        socket_path = socket_data[0]
        if service_path == socket_path:
            return False

        service_active = bus_json(
            "get-property", SYSTEMD_SERVICE, service_path,
            SYSTEMD_UNIT, "ActiveState",
        )
        if service_active != "active":
            return False

        service_main_pid = bus_json(
            "get-property", SYSTEMD_SERVICE, service_path,
            SYSTEMD_SERVICE_IFACE, "MainPID",
        )
        if (type(service_main_pid) is not int or service_main_pid <= 0
                or service_main_pid != daemon_pid):
            return False

        socket_active = bus_json(
            "get-property", SYSTEMD_SERVICE, socket_path,
            SYSTEMD_UNIT, "ActiveState",
        )
        if socket_active != "active":
            return False

        socket_listen = bus_json(
            "get-property", SYSTEMD_SERVICE, socket_path,
            SYSTEMD_SOCKET_IFACE, "Listen",
        )
        if (not isinstance(socket_listen, list)
                or not all(isinstance(item, list) and len(item) == 2
                           and all(isinstance(value, str) for value in item)
                           for item in socket_listen)
                or ["Stream", str(control_path)] not in socket_listen):
            return False

        socket_triggers = bus_json(
            "get-property", SYSTEMD_SERVICE, socket_path,
            SYSTEMD_UNIT, "Triggers",
        )
        if (not isinstance(socket_triggers, list)
                or not all(isinstance(item, str) for item in socket_triggers)
                or KEYRING_SERVICE not in socket_triggers):
            return False

        return True
    except (UnlockError, OSError, subprocess.TimeoutExpired):
        return False


def read_password(op, reference):
    if not Path(op).is_absolute():
        raise UnlockError("The 1Password executable must be an absolute path.")
    if not reference.startswith("op://"):
        raise UnlockError("Use an op:// reference, never a password argument.")
    result = subprocess.run(
        [op, "read", reference, "--no-newline"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, timeout=120,
    )
    if result.returncode:
        raise UnlockError("1Password could not read the field; check the app and reference.")
    password = result.stdout
    # GNOME uses a C string and accepts at most 8 KiB through its login interface.
    if not password or len(password) > 8192 or b"\0" in password:
        raise UnlockError("1Password returned an empty or unsupported password.")
    return password


def receive_exact(connection, length):
    data = bytearray()
    while len(data) < length:
        block = connection.recv(length - len(data))
        if not block:
            raise UnlockError("The keyring closed its control connection.")
        data.extend(block)
    return bytes(data)


def unlock(op, reference):
    if not is_locked():
        return "Login keyring is already unlocked."
    path, expected_pid = control_endpoint()
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise UnlockError("The keyring control socket is not owned by this user.")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        pid, uid, _ = struct.unpack(
            "3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                       struct.calcsize("3i")))
        if uid != os.getuid():
            raise UnlockError("The control socket does not belong to the D-Bus keyring.")
        if (pid != expected_pid
                and not verify_systemd_peer(pid, path, expected_pid)):
            raise UnlockError("The control socket does not belong to the D-Bus keyring.")
        password = read_password(op, reference)
        # GNOME's PAM control protocol: credentials byte, big-endian packet size,
        # UNLOCK opcode (1), and a length-prefixed password without a trailing NUL.
        # Upstream: daemon/control/gkd-control-{client,server}.c (GNOME Keyring 48).
        packet = struct.pack(">III", 12 + len(password), 1, len(password)) + password
        connection.sendall(b"\0")
        connection.sendall(packet)
        size = struct.unpack(">I", receive_exact(connection, 4))[0]
        if size != 8:
            raise UnlockError("Unexpected keyring control response.")
        result = struct.unpack(">I", receive_exact(connection, 4))[0]
        if result != 0:
            raise UnlockError("The keyring rejected the password from 1Password.")
    if is_locked():
        raise UnlockError("The login keyring is still locked.")
    return "Login keyring unlocked."


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--op", required=True, help="Absolute path to Windows op.exe")
    parser.add_argument("--reference", required=True, help="1Password op:// field reference")
    args = parser.parse_args(argv)
    try:
        if os.getuid() == 0:
            raise UnlockError("Run this as your normal WSL user, without sudo.")
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        print(unlock(args.op, args.reference))
        return 0
    except UnlockError as error:
        print(f"keyring-unlock: {error}", file=sys.stderr)
    except (OSError, subprocess.TimeoutExpired):
        # Never include subprocess output or password-bearing buffers in errors.
        print("keyring-unlock: a required program or socket failed or timed out.",
              file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
