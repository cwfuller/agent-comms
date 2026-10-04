#!/usr/bin/env python3
"""Verify a staged copy of the operator's shared-guidance bundle.

The bundle is a directory written by the guidance repository's `snapshot` verb: `method-guidance.md`
plus `snapshot.json` carrying `format`, `revision`, `guidance_file` and `guidance_sha256`. runphase.sh
stages the file into a reviewer's isolated home FIRST and verifies the STAGED bytes with this helper,
so the bytes that were checked are the bytes the reviewer reads.

Usage:
  method_guidance.py verify --record <snapshot.json> --staged <staged-file>

Exit 0 prints `<revision><TAB><sha256>`. Exit 1 prints one short reason code and nothing else:
  record       the snapshot record is unreadable, not JSON, or not an object
  format       `format` is not 1
  guidance-file `guidance_file` is not `method-guidance.md`
  revision     `revision` is not 40 lowercase hex characters
  digest       `guidance_sha256` is not 64 lowercase hex characters
  staged       the staged file is unreadable or not a regular file
  empty        the staged file has no bytes
  oversize     the staged file is larger than 64 KiB
  hash         the SHA-256 of the staged bytes differs from `guidance_sha256`

The record is TRUSTED only as far as the directory it sits in: this proves integrity against the
sibling record, not authenticity.
"""
import argparse
import hashlib
import json
import os
import re
import stat
import sys

GUIDANCE_FILE = "method-guidance.md"
MAX_BYTES = 64 * 1024
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")


def verify(record_path, staged_path):
    """Return (revision, sha256) or raise ValueError(code)."""
    try:
        with open(record_path, "rb") as f:
            record = json.loads(f.read(MAX_BYTES + 1))
    except (OSError, ValueError):
        raise ValueError("record")
    if not isinstance(record, dict):
        raise ValueError("record")
    # `format` must be the integer 1: True == 1 in Python, and a boolean is not a format number.
    if type(record.get("format")) is not int or record["format"] != 1:
        raise ValueError("format")
    if record.get("guidance_file") != GUIDANCE_FILE:
        raise ValueError("guidance-file")
    revision = record.get("revision")
    if not isinstance(revision, str) or not HEX40.match(revision):
        raise ValueError("revision")
    expected = record.get("guidance_sha256")
    if not isinstance(expected, str) or not HEX64.match(expected):
        raise ValueError("digest")
    try:
        st = os.lstat(staged_path)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("staged")
        with open(staged_path, "rb") as f:
            data = f.read(MAX_BYTES + 1)
    except OSError:
        raise ValueError("staged")
    if not data:
        raise ValueError("empty")
    if len(data) > MAX_BYTES:
        raise ValueError("oversize")
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        raise ValueError("hash")
    return revision, actual


def main(argv):
    ap = argparse.ArgumentParser(prog="method_guidance.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verify")
    v.add_argument("--record", required=True)
    v.add_argument("--staged", required=True)
    args = ap.parse_args(argv)
    try:
        revision, digest = verify(args.record, args.staged)
    except ValueError as e:
        print(e.args[0])
        return 1
    print("%s\t%s" % (revision, digest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
