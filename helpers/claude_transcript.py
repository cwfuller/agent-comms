#!/usr/bin/env python3
"""What a bound Claude review leg actually ran, read from Claude's OWN transcript.

A bound leg names a model and a native effort; the adapter accepting them is not proof the billable
turn ran them. Claude Code writes one record per assistant response under
<config>/projects/<cwd-slug>/**/*.jsonl, carrying the model it served (`message.model`) and the
effort it ran at (`effort`). This reads the records appended between a snapshot and now, for the
mount's cwd only, and reports the one (model, effort) pair they agree on, or refuses.

THE WINDOW IS ATTRIBUTED BY DIRECTORY AND FILE, never by a record's own `cwd` field (which moves when
the reviewer changes directory): every .jsonl file, subagent files included, under each project
directory named for the mount cwd's slug, or for that slug followed by "-" (any path under the
mount). No record in those directories is filtered out, so a record written after a `cd`, or by a
subagent on another model, is seen and judged: including too much can only refuse.

A TRUNCATED project directory is refused, never filtered. Claude truncates a slug longer than
leg_usage.CLAUDE_SLUG_MAX characters and appends a hash this code does not reproduce, and a
truncated prefix can be shared with another mount; the usage reader may filter such a directory by
each record's `cwd` (an advisory spend figure), attestation may not.

The window rules (a vanished, replaced or truncated file, a partial last line, a malformed or
non-UTF-8 record) are leg_usage's, reused, so they exist once.

Usage:
  claude_transcript.py snapshot <records-root> <cwd> <out-file>
      exit 0 the snapshot is written; 21 refused (a truncated project directory, an unreadable root)
  claude_transcript.py observe <records-root> <cwd> <snapshot-file>
      exit 0 and one line "<effort or empty>\\t<model>\\t<sessions>\\t<records>\\t<cli version or empty>";
      21 undecidable, with the reason on stderr and never any record content
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leg_usage  # noqa: E402  (a sibling helper; -I keeps the script's own directory off sys.path)

UNDECIDABLE = 21
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")


def slugs(cwd):
    """The project-directory name of every form of the mount cwd (logical and physical)."""
    return [leg_usage.claude_slug(form) for form in leg_usage.cwd_forms(cwd)]


def window_files(root, cwd):
    """Every record file attributed to the mount, by directory. Raises Undecidable for a slug Claude
    would truncate (the directory could not be told apart from another mount's)."""
    names = slugs(cwd)
    if any(len(slug) > leg_usage.CLAUDE_SLUG_MAX for slug in names):
        raise leg_usage.Undecidable("the mount's transcript directory name would be truncated "
                                    "(a slug over %d characters): use a shorter mount base (COMMS_MOUNT_BASE)"
                                    % leg_usage.CLAUDE_SLUG_MAX)
    if leg_usage.absent(root):
        return []
    files = []
    for entry in sorted(os.listdir(root)):
        if not any(entry == slug or entry.startswith(slug + "-") for slug in names):
            continue
        for d, _, found in os.walk(os.path.join(root, entry), onerror=leg_usage._boom):
            files.extend(os.path.join(d, n) for n in found if n.endswith(".jsonl"))
    return sorted(set(files))


def observe(root, cwd, snap):
    """(effort or None, model, sessions, records, cli versions) for the window, or Undecidable."""
    pairs, sessions, versions, count = set(), set(), set(), 0
    for _f, _start, records in leg_usage.window_records(window_files(root, cwd), snap):
        for r in records:
            if not isinstance(r, dict) or r.get("type") != "assistant":
                continue
            m = r.get("message")
            model = m.get("model") if isinstance(m, dict) else None
            # Claude Code's own synthetic messages (an interrupted or failed request) made no API call
            # only while their usage SAYS so: the usage reader's rule, reused.
            if model == "<synthetic>":
                if leg_usage.is_zero_usage(m.get("usage")):
                    continue
                raise leg_usage.Undecidable("a synthetic record carries tokens or no usage")
            if not isinstance(model, str) or not TOKEN.fullmatch(model):
                raise leg_usage.Undecidable("an assistant record names no served model")
            effort = r.get("effort")
            if effort is not None and (not isinstance(effort, str) or not TOKEN.fullmatch(effort)):
                raise leg_usage.Undecidable("an assistant record carries an unreadable effort")
            turn = r.get("perTurnEffort")
            if turn is not None and turn != effort:
                raise leg_usage.Undecidable("an assistant record's perTurnEffort differs from its effort")
            pairs.add((model, effort))
            count += 1
            if isinstance(r.get("sessionId"), str):
                sessions.add(r["sessionId"])
            if isinstance(r.get("version"), str) and TOKEN.fullmatch(r["version"]):
                versions.add(r["version"])
    if not pairs:
        raise leg_usage.Undecidable("the window holds no assistant record")
    if len(pairs) > 1:
        # How a second model (a subagent on another one, an SDK fallback mid-turn) or a moved effort shows.
        raise leg_usage.Undecidable("the window's records disagree on the model or the effort (%d distinct pairs)" % len(pairs))
    model, effort = next(iter(pairs))
    return effort, model, len(sessions), count, ",".join(sorted(versions))


def main(argv):
    if len(argv) != 5 or argv[1] not in ("snapshot", "observe"):
        sys.stderr.write("usage: claude_transcript.py snapshot|observe <records-root> <cwd> <file>\n")
        return 2
    verb, root, cwd, path = argv[1:]
    try:
        if verb == "snapshot":
            snap = leg_usage.snapshot_files(window_files(root, cwd))
            with open(path, "w") as fh:
                json.dump(snap, fh)
            return 0
        with open(path) as fh:
            snap = json.load(fh)
        if not isinstance(snap, dict):
            raise leg_usage.Undecidable("the snapshot is not an object")
        effort, model, sessions, count, versions = observe(root, cwd, snap)
    except (OSError, ValueError, leg_usage.Undecidable) as e:
        sys.stderr.write("claude transcript %s: %s\n" % (verb, e if isinstance(e, leg_usage.Undecidable) else type(e).__name__))
        return UNDECIDABLE
    sys.stdout.write("%s\t%s\t%d\t%d\t%s\n" % (effort or "", model, sessions, count, versions))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
