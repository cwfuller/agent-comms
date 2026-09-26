"""Private runtime state shared by optional ACP adapters."""
import json
import os
from pathlib import Path
import tempfile


def private_directory(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("runtime state directory must not be a symlink")
    if path.resolve() != path.absolute():
        raise ValueError("runtime state directory has a symlink ancestor")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_mode & 0o077:
        raise ValueError("runtime state directory must be private (mode 0700)")
    return path


def place(path, value):
    path = Path(path)
    fd, temp = tempfile.mkstemp(prefix=".stage-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(json.dumps(value))
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
