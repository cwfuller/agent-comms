#!/usr/bin/env python3
"""Seed a fresh isolated codex home's plugin cache and remote plugin catalog from one canonical tree.

codex fills a new CODEX_HOME with ~760 plugin files and a ~32 MB remote plugin catalog on its first turn.
This helper puts those two trees there with clonefile(2) (copy-on-write, new inodes, shared blocks) from a
canonical copy beside the mount store, and refreshes that copy from a home codex itself populated.

Usage:
  codex_seed.py seed    --root DIR --key codex-X.Y.Z --home DIR
  codex_seed.py promote --root DIR --key codex-X.Y.Z --home DIR

seed prints one line, `seeded`, `partial` or `skipped:<why>`, then ` <detail>`; promote prints `promoted` or
`skipped:<why>`, then ` <detail>`. Exit 0 whenever the home is seeded and verified or untouched. Exit 1 is a
usage error. Exit 2 (seed only) means a clone that failed verification could not be removed, so the home's
contents are unexplained and the caller must not run a turn in it.

There is NO byte-copy fallback anywhere in this file: a clone that fails for any reason (another volume, a
filesystem without clones, a missing symbol) leaves the home as it was, and codex downloads as before.
`_clonefile` is the only way a file reaches a home, and a test replaces it in-process; no environment
variable changes what is staged.
"""
import argparse
import ctypes
import ctypes.util
import errno
import hashlib
import os
import re
import secrets
import shutil
import stat
import sys
import time

KEY_RE = re.compile(r"codex-[0-9]+(\.[0-9]+)*\Z")
MAX_AGE_SECS = 7 * 24 * 3600     # codex does not refresh an old catalog by itself, so the canonical expires
SKEW_SECS = 3600                 # a creation epoch further in the future than this is not ours
CLONE_NOFOLLOW = 0x0001
# The two trees, as (canonical name, path under a codex home).
TREES = (("plugins-cache", ("plugins", "cache")), ("remote_plugin_catalog", ("cache", "remote_plugin_catalog")))
MANIFEST = "MANIFEST"


class Refused(Exception):
    """A reason code (the text after `skipped:`)."""


def _clonefile(src, dst):
    """clonefile(2) with CLONE_NOFOLLOW. Raises OSError; never copies bytes."""
    try:
        fn = ctypes.CDLL(ctypes.util.find_library("c") or "libc.dylib", use_errno=True).clonefile
    except (OSError, AttributeError):
        raise OSError(errno.ENOSYS, "clonefile is not available")
    fn.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32)
    fn.restype = ctypes.c_int
    if fn(os.fsencode(src), os.fsencode(dst), CLONE_NOFOLLOW) != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))


def _errname(e):
    return errno.errorcode.get(e.errno, str(e.errno))


def _lstat(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def _owned_dir(path, want_mode=0o700):
    """lstat a directory that must be a real one, ours, at exactly want_mode. None when absent."""
    st = _lstat(path)
    if st is None:
        return None
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != want_mode:
        raise Refused("bad-dir")
    return st


def walk(top, prefix):
    """Entries of the tree at `top` as (rel, type, mode, size, sha256, dev, ino), sorted by rel.

    lstat only, nothing followed. A symlink, a non-regular file or a regular file with a second link is
    refused: neither a seed nor a canonical may contain one. File content is read through an fd opened with
    O_NOFOLLOW and re-checked against the lstat, so a swap between the two is refused too."""
    out = []

    def one(path, rel):
        st = os.lstat(path)
        mode = stat.S_IMODE(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            raise Refused("symlink")
        if stat.S_ISDIR(st.st_mode):
            out.append((rel, "d", mode, 0, "-", st.st_dev, st.st_ino))
            with os.scandir(path) as it:
                names = sorted(e.name for e in it)
            for n in names:
                one(path + "/" + n, rel + "/" + n)
            return
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            raise Refused("link-or-special")
        h = hashlib.sha256()
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            fst = os.fstat(fd)
            if (fst.st_dev, fst.st_ino) != (st.st_dev, st.st_ino) or fst.st_nlink != 1:
                raise Refused("changed-while-read")
            while True:
                b = os.read(fd, 1 << 20)
                if not b:
                    break
                h.update(b)
        finally:
            os.close(fd)
        out.append((rel, "f", mode, st.st_size, h.hexdigest(), st.st_dev, st.st_ino))

    one(top, prefix)
    return sorted(out)


def lines(entries):
    return ["%s\t%s\t%o\t%d\t%s" % e[:5] for e in entries]


def digest(entry_lines):
    return hashlib.sha256(("\n".join(entry_lines) + "\n").encode()).hexdigest()


def _guard(fn, *args):
    """walk() with every filesystem error reported as a refusal code instead of a traceback."""
    try:
        return fn(*args)
    except Refused:
        raise
    except OSError as e:
        raise Refused("unreadable:" + _errname(e))


def home_trees(home):
    """(canonical name, path) for each tree present in a codex home, by lstat."""
    out = []
    for name, parts in TREES:
        p = os.path.join(home, *parts)
        if _lstat(p) is not None:
            out.append((name, p))
    return out


def read_manifest(path):
    """(header dict, entry lines) from a canonical MANIFEST, or Refused."""
    st = _lstat(path)
    if st is None or not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        raise Refused("canonical-tampered")
    try:
        with open(path, "rb") as f:
            text = f.read(64 << 20).decode()
    except (OSError, UnicodeDecodeError):
        raise Refused("canonical-tampered")
    head, sep, body = text.partition("\n\n")
    hdr = {}
    for ln in head.split("\n"):
        k, _, v = ln.partition("\t")
        hdr[k] = v
    if not sep or not hdr.get("digest") or not hdr.get("created", "").isdigit() or not hdr.get("version"):
        raise Refused("canonical-tampered")
    return hdr, [x for x in body.split("\n") if x]


def _canonical(root, key, now):
    """The canonical's path, header and entry lines when it is present, ours and young. Else Refused."""
    cdir = os.path.join(root, key)
    try:
        if _owned_dir(cdir) is None:
            raise Refused("no-seed")
    except Refused as r:
        if str(r) == "bad-dir":
            raise Refused("canonical-tampered")
        raise
    hdr, body = read_manifest(os.path.join(cdir, MANIFEST))
    created = int(hdr["created"])
    if hdr["version"] != key or created > now + SKEW_SECS:
        raise Refused("canonical-tampered")
    if now - created > MAX_AGE_SECS:
        raise Refused("stale")
    return cdir, hdr, body


def _check_root(root, home, create):
    hst = _lstat(home)
    if hst is None or not stat.S_ISDIR(hst.st_mode):
        raise Refused("bad-home")
    try:
        st = _owned_dir(root)
        if st is None:
            if not create:
                raise Refused("no-seed")
            os.mkdir(root, 0o700)
            st = _owned_dir(root)
    except OSError:
        raise Refused("bad-root")
    except Refused as r:
        raise Refused("bad-root" if str(r) == "bad-dir" else str(r))
    if st.st_dev != hst.st_dev:
        raise Refused("other-volume")


def _remove(path):
    """Remove a tree we created. rmtree does not follow symlinks and refuses a symlink at the top."""
    try:
        shutil.rmtree(path)
    except FileNotFoundError:
        pass


def _summary(entries):
    files = [e for e in entries if e[1] == "f"]
    return "entries=%d bytes=%d digest=%s" % (len(entries), sum(e[3] for e in files), digest(lines(entries))[:12])


def seed(root, key, home, now=None):
    """-> (status line, exit code)."""
    now = time.time() if now is None else now
    if not KEY_RE.match(key):
        return "skipped:no-key", 0
    try:
        # 1. fresh only; a symlink counts as present
        for _n, parts in TREES:
            if _lstat(os.path.join(home, parts[0])) is not None:
                raise Refused("warm")
        _check_root(root, home, create=False)
        # 2-3. the canonical is usable and intact
        cdir, hdr, body = _canonical(root, key, now)
        canon = []
        for name, _parts in TREES:
            if os.path.lexists(os.path.join(cdir, name)):
                canon += _guard(walk, os.path.join(cdir, name), name)
        if digest(lines(canon)) != hdr["digest"] or lines(canon) != body or not canon:
            raise Refused("canonical-tampered")
    except Refused as r:
        return "skipped:%s" % r, 0
    canon_ids = {(e[5], e[6]) for e in canon}

    # 4. clone each tree that exists in the canonical; the parents are ours to create and to remove
    made, results = [], {}
    for name, parts in TREES:
        src = os.path.join(cdir, name)
        if _lstat(src) is None:
            results[name] = "absent"
            continue
        dst = os.path.join(home, *parts)
        try:
            for i in range(1, len(parts)):
                parent = os.path.join(home, *parts[:i])
                if _lstat(parent) is None:
                    os.mkdir(parent, 0o700)
                    made.append(parent)
            _clonefile(src, dst)
            results[name] = "cloned"
        except OSError as e:
            results[name] = "clone-failed:" + _errname(e)

    # 5. verify exactly what was cloned, on the home side
    ok = [n for n, v in results.items() if v == "cloned"]
    try:
        got = []
        for name, parts in TREES:
            if name in ok:
                got += _guard(walk, os.path.join(home, *parts), name)
        want = [ln for ln in body if ln.split("\t", 1)[0].split("/", 1)[0] in ok]
        if lines(got) != want or any((e[5], e[6]) in canon_ids for e in got):
            raise Refused("clone-unverified")
    except Refused as r:
        results = {n: "clone-unverified" for n in results}
        ok = []
        why = str(r)
    else:
        why = ""
    if not ok:
        # remove exactly what this call created: the cloned trees' top directories, then the empty parents
        try:
            for name, parts in TREES:
                if results[name] in ("cloned", "clone-unverified"):
                    _remove(os.path.join(home, *parts))
            for p in sorted(made, key=len, reverse=True):
                if _lstat(p) is not None:
                    os.rmdir(p)
        except OSError as e:
            return "cleanup-failed %s" % _errname(e), 2
        bad = next((v for v in results.values() if v.startswith("clone-failed")), "")
        if why:
            return "skipped:%s %s" % ("clone-unverified", why), 0
        return "skipped:%s" % (bad or "clone-failed:none"), 0
    # a tree that failed to clone leaves its empty parents behind only when another tree needs them
    try:
        for p in sorted(made, key=len, reverse=True):
            if _lstat(p) is not None and not os.listdir(p):
                os.rmdir(p)
    except OSError:
        pass
    detail = " ".join("%s=%s" % (n, results[n]) for n, _p in TREES)
    return "%s %s %s" % ("seeded" if len(ok) == len(TREES) else "partial", detail, _summary(got)), 0


def _prune_and_reap(root, key, now):
    """Drop other versions' canonicals older than the cap and the temp directories of dead callers."""
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        m = re.match(r"\.(tmp|old)\.([0-9]+)\.", name)
        if m:
            try:
                os.kill(int(m.group(2)), 0)
                continue
            except ProcessLookupError:
                pass
            except OSError:
                continue
            _remove(path)
        elif KEY_RE.match(name) and name != key:
            try:
                hdr, _b = read_manifest(os.path.join(path, MANIFEST))
                born = int(hdr["created"])
            except Refused:
                born = int(os.lstat(path).st_mtime)
            if now - born > MAX_AGE_SECS:
                aside = os.path.join(root, ".old.%d.%s" % (os.getpid(), secrets.token_hex(4)))
                os.rename(path, aside)
                _remove(aside)


def promote(root, key, home, now=None):
    """-> (status line, exit code)."""
    now = time.time() if now is None else now
    if not KEY_RE.match(key):
        return "skipped:no-key", 0
    tmp = old = None
    try:
        trees = home_trees(home)
        if [n for n, _p in trees] != [n for n, _p in TREES]:
            raise Refused("incomplete-home")
        src = []
        for name, path in trees:
            src += _guard(walk, path, name)
        if not any(e[1] == "f" for e in src if e[0].startswith("plugins-cache")):
            raise Refused("incomplete-home")
        _check_root(root, home, create=True)   # only now: a home with nothing to promote creates nothing
        tmp = os.path.join(root, ".tmp.%d.%s" % (os.getpid(), secrets.token_hex(4)))
        os.mkdir(tmp, 0o700)
        for (name, path) in trees:
            try:
                _clonefile(path, os.path.join(tmp, name))
            except OSError as e:
                raise Refused("clone-failed:" + _errname(e))
        got = []
        for name, _p in trees:
            got += _guard(walk, os.path.join(tmp, name), name)
        if any((e[5], e[6]) in {(s[5], s[6]) for s in src} for e in got):
            raise Refused("clone-unverified")
        body = lines(got)
        fd = os.open(os.path.join(tmp, MANIFEST), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write("version\t%s\ncreated\t%d\ndigest\t%s\n\n%s\n" % (key, now, digest(body), "\n".join(body)))
        final = os.path.join(root, key)
        if _lstat(final) is not None:
            old = os.path.join(root, ".old.%d.%s" % (os.getpid(), secrets.token_hex(4)))
            try:
                os.rename(final, old)
            except FileNotFoundError:
                old = None
        try:
            os.rename(tmp, final)
        except OSError:
            raise Refused("lost-race")
        tmp = None
        if old is not None:
            _remove(old)
            old = None
        _prune_and_reap(root, key, now)
        return "promoted %s" % _summary(got), 0
    except Refused as r:
        return "skipped:%s" % r, 0
    except OSError as e:
        return "skipped:error:%s" % _errname(e), 0
    finally:
        for p in (tmp, old):
            if p is not None:
                try:
                    _remove(p)
                except OSError:
                    pass


def main(argv):
    ap = argparse.ArgumentParser(prog="codex_seed.py")
    ap.add_argument("verb", choices=("seed", "promote"))
    ap.add_argument("--root", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--home", required=True)
    try:
        a = ap.parse_args(argv)
    except SystemExit:
        return 1
    line, rc = (seed if a.verb == "seed" else promote)(a.root, a.key, a.home)
    print(line)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
