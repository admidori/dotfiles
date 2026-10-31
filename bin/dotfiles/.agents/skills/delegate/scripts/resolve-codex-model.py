#!/usr/bin/env python3
"""Resolve Codex model attribution from active session rollout logs.

Inspects the rollout JSONL metadata for a given session ID (or CODEX_THREAD_ID)
under CODEX_HOME/sessions (or archived_sessions) and extracts the model from the
latest complete turn_context record.
"""

import argparse
import json
import os
import re
import sys

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
MODEL_SAFE_RE = re.compile(r"^[a-zA-Z0-9_.:@/-]+$")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Resolve Codex model identifier from session rollout metadata."
    )
    parser.add_argument(
        "--session-id",
        type=str,
        default=None,
        help="Session UUID (defaults to CODEX_THREAD_ID environment variable).",
    )
    parser.add_argument(
        "--codex-home",
        type=str,
        default=None,
        help="Path to Codex home directory (defaults to CODEX_HOME or ~/.codex).",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON with model, session_id, source_path, and turn_id.",
    )
    return parser.parse_args()


def is_matching_rollout_filename(fname: str, session_id: str) -> bool:
    fl = fname.lower()
    sl = session_id.lower()
    return fl.startswith("rollout-") and fl.endswith(f"-{sl}.jsonl")


def find_rollout_candidates(codex_home: str, session_id: str):
    session_dirs = [
        os.path.join(codex_home, "sessions"),
        os.path.join(codex_home, "archived_sessions"),
    ]
    candidates = []
    symlink_candidates = []

    for sdir in session_dirs:
        if not os.path.isdir(sdir):
            continue
        for root, _dirs, files in os.walk(sdir, followlinks=False):
            for fname in files:
                if is_matching_rollout_filename(fname, session_id):
                    fpath = os.path.join(root, fname)
                    if os.path.islink(fpath):
                        symlink_candidates.append(fpath)
                    elif not os.path.isfile(fpath):
                        symlink_candidates.append(fpath)
                    else:
                        candidates.append(fpath)

    return candidates, symlink_candidates


def stream_rollout_file(filepath: str, expected_session_id: str):
    session_meta_seen = False
    latest_turn_context = None
    expected_id_lower = expected_session_id.lower()

    with open(filepath, "rb") as f:
        while True:
            line = f.readline()
            if not line:
                break
            # Ignore only a final unterminated record that may still be being written
            if not line.endswith(b"\n"):
                break
            stripped = line.strip()
            if not stripped:
                continue

            try:
                record = json.loads(stripped.decode("utf-8"))
            except (ValueError, UnicodeError):
                sys.stderr.write("error: malformed JSON record in rollout file\n")
                return None, None, 1

            if not isinstance(record, dict):
                sys.stderr.write("error: malformed metadata in rollout file\n")
                return None, None, 1

            rec_type = record.get("type")
            if not isinstance(rec_type, str):
                sys.stderr.write("error: malformed metadata in rollout file\n")
                return None, None, 1

            if rec_type == "session_meta":
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    sys.stderr.write("error: malformed metadata in rollout file\n")
                    return None, None, 1
                meta_id = payload.get("id")
                if not isinstance(meta_id, str):
                    sys.stderr.write("error: malformed metadata in rollout file\n")
                    return None, None, 1
                if not session_meta_seen:
                    session_meta_seen = True
                    if meta_id.strip().lower() != expected_id_lower:
                        sys.stderr.write("error: session ID mismatch in session_meta\n")
                        return None, None, 1
            elif rec_type == "turn_context":
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    sys.stderr.write("error: malformed metadata in rollout file\n")
                    return None, None, 1
                latest_turn_context = payload

    if not session_meta_seen:
        sys.stderr.write("error: no valid session_meta found in rollout file\n")
        return None, None, 1

    if latest_turn_context is None:
        sys.stderr.write("error: no turn_context found in rollout file\n")
        return None, None, 1

    model = latest_turn_context.get("model")
    if not isinstance(model, str) or not model:
        sys.stderr.write("error: latest turn_context record has missing or invalid model\n")
        return None, None, 1

    # Validate model identifier: bounded, nonempty safe identifier without whitespace/newlines
    if any(c.isspace() for c in model):
        sys.stderr.write("error: model identifier contains forbidden whitespace\n")
        return None, None, 1

    if len(model) > 128 or not MODEL_SAFE_RE.match(model):
        sys.stderr.write("error: model identifier contains forbidden characters or exceeds length\n")
        return None, None, 1

    turn_id = latest_turn_context.get("turn_id")
    if not isinstance(turn_id, str) or not turn_id.strip():
        turn_id = None

    return model, turn_id, 0


def main():
    args = parse_args()

    # Session ID resolution
    session_id = args.session_id
    if session_id is None:
        session_id = os.environ.get("CODEX_THREAD_ID", "").strip()

    if not session_id:
        sys.stderr.write("error: session ID not provided and CODEX_THREAD_ID is unset or empty\n")
        return 1

    session_id = session_id.strip()
    if not UUID_RE.match(session_id):
        sys.stderr.write("error: invalid session ID: not a valid UUID format\n")
        return 1

    # Codex home resolution
    codex_home = args.codex_home
    if codex_home is None:
        codex_home = os.environ.get("CODEX_HOME", "").strip()
        if not codex_home:
            codex_home = os.path.expanduser("~/.codex")
    else:
        codex_home = os.path.expanduser(codex_home)

    if not os.path.isdir(codex_home):
        sys.stderr.write(f"error: codex home directory not found: {codex_home}\n")
        return 1

    # Locate rollout file candidates
    candidates, symlink_candidates = find_rollout_candidates(codex_home, session_id)

    if symlink_candidates:
        sys.stderr.write(
            f"error: candidate rollout file is a symlink or non-regular file: {symlink_candidates[0]}\n"
        )
        return 1

    if len(candidates) == 0:
        sys.stderr.write(f"error: no matching rollout file found for session {session_id}\n")
        return 1

    if len(candidates) > 1:
        sys.stderr.write(
            f"error: ambiguous rollout files found for session {session_id} ({len(candidates)} candidates)\n"
        )
        return 1

    candidate_file = candidates[0]
    try:
        model, turn_id, status = stream_rollout_file(candidate_file, session_id)
    except OSError:
        sys.stderr.write("error: unable to read matching rollout file\n")
        return 1
    if status != 0:
        return status

    if args.json:
        res = {
            "model": model,
            "session_id": session_id,
            "source_path": os.path.abspath(candidate_file),
        }
        if turn_id:
            res["turn_id"] = turn_id
        sys.stdout.write(json.dumps(res) + "\n")
    else:
        sys.stdout.write(model + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
