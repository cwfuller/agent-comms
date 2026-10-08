# agent-comms deferred deletion — SOURCED (never executed) by runphase.sh and comms.sh.
#
# No review turn, panel dispatch or landing waits on a recursive delete. A discarded bulk tree (a
# throwaway mount, a retired ident's tombstone, a pending generation, an expired aside, an
# integrate or `verify fresh` tree) is RENAMED into a trash dir on the same volume, which takes
# constant time, and one detached, low-priority reaper (`runphase.sh reap`) deletes it later.
# This file is the ONE owner of the trash paths, the rename, the worktree-aware rename, the reaper
# start and the process-liveness probe; no site renames, unregisters or starts a reaper on its own.
# docs/INTERNALS.md "Deferred deletion: trash and reaper" is the design.
#
# Every function returns a status and writes nothing to stdout except the one accessor
# (trash_dir_for). A failure to move is never fatal: the caller keeps its existing inline delete.
#
# Layout: <parent>/.comms-trash/
#   .hold.<10-digit epoch>.<kind>.<pid>.<6 hex>/{owner,payload/}   a put still owned by its maker
#   <10-digit epoch>.<kind>.<pid>.<6 hex>/{owner,payload/}         an entry: the reaper's to delete
#   .reaper.lock                                                    flock: one reaper per trash
# A reaper never deletes a hold, so nothing a site still reads after its rename can disappear
# under it. Anything else in a trash dir is left alone.

TRASH_LEAF=.comms-trash
TRASH_KINDS="aside throwaway pending retire integrate verify"
TRASH_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || TRASH_HELPER_DIR=""
TRASH_NOTE=""; TRASH_HOLD=""

# `ps -o lstart=` renders a LOCALE- and TZ-dependent string, and LC_ALL overrides LC_TIME.
# Two runners under different environments would otherwise read the same live process as two
# different processes, each conclude the other's pid was recycled, and both restage one mount.
# Pin both, so the recorded and compared forms are always the same bytes.
# PROC_STATE: live | dead | ambig. Deliberately three-valued, because "ps failed" is not
# "the process is gone": a transient or operational ps error (EPERM, a broken ps, a container
# without /proc) would otherwise read as positive proof of absence and reclaim a LIVE holder.
# Only an exit of 1 with NOTHING on stdout AND NOTHING on stderr is absence; anything else
# that is not a clean success is ambiguous and never licenses a reclaim.
PROC_START=""; PROC_STATE=""
proc_state() {  # <pid> -> sets PROC_STATE (live|dead|ambig) and PROC_START. NEVER call this
                # in a command substitution: the globals would be set in a subshell and the
                # caller would silently keep its own previous values.
  PROC_START=""; PROC_STATE="ambig"
  local pid="${1:-}" out err rc=0 errf
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  errf="$(mktemp 2>/dev/null)" || return 0
  out="$(LC_ALL=C TZ=UTC ps -p "$pid" -o lstart= 2>"$errf")" || rc=$?
  err="$(cat "$errf" 2>/dev/null)"; rm -f "$errf" 2>/dev/null || true
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    PROC_START="$(printf '%s' "$out" | tr -s ' ' | sed 's/^ *//; s/ *$//')"
    PROC_STATE="live"; return 0
  fi
  if [ "$rc" -eq 1 ] && [ -z "$out" ] && [ -z "$err" ]; then PROC_STATE="dead"; return 0; fi
  return 0
}

trash_dir_for() { printf '%s/%s' "${1%/}" "$TRASH_LEAF"; }   # <parent> -> <parent>/.comms-trash

# A TEST SEAM, cm_hook's shape: when set, called as `<hook> held <hold>` after a put's rename and
# before trash_tree's post-rename checks. Its status is ignored; unset, it costs nothing.
trash_hook() {
  [ -n "${COMMS_TEST_TRASH_HOOK:-}" ] || return 0
  "$COMMS_TEST_TRASH_HOOK" "$@" || true
}

# trash_ensure <trash> — create the trash (mode 700) if it is absent, then require a real directory,
# not a symlink, at its own physical path, owned by the current uid. Nothing is written to or reaped
# from a trash that fails this. 0 usable | 1 (+TRASH_NOTE).
trash_ensure() {
  local t="$1" phys own
  TRASH_NOTE=""
  if [ ! -e "$t" ] && [ ! -L "$t" ]; then mkdir -m 700 "$t" 2>/dev/null || true; fi
  if [ -L "$t" ] || [ ! -d "$t" ]; then TRASH_NOTE="$t is not a real directory"; return 1; fi
  phys="$(cd "$t" 2>/dev/null && pwd -P)" || phys=""
  [ "$phys" = "$t" ] || { TRASH_NOTE="$t does not sit at its own physical path"; return 1; }
  own="$(ls -ldn "$t" 2>/dev/null | awk 'NR==1{print $3}')" || own=""
  [ "$own" = "$(id -u)" ] || { TRASH_NOTE="$t is not owned by uid $(id -u)"; return 1; }
  return 0
}

# The entry grammar. A name that does not match it exactly is never the reaper's to delete.
trash_entry_name_ok() {  # <name> — <10-digit epoch>.<kind>.<pid>.<6 hex>
  local re='^[0-9]{10}\.(aside|throwaway|pending|retire|integrate|verify)\.[0-9]+\.[0-9a-f]{6}$'
  [[ $1 =~ $re ]]
}

# THE RENAME. os.rename can fail with EXDEV, but it never copies: `mv` would fall back to a copy and
# delete across volumes, which is exactly the slow delete this exists to avoid. The program re-checks
# the trash itself, moves <src> only when it is a real directory whose parent sits at its own
# physical path (no symlinked ancestor can redirect the move), writes the hold's owner record BEFORE
# anything moves in, and removes the empty hold when the move fails. COMMS_TEST_TRASH_RENAME_ERRNO is
# a test seam: the move raises that errno, so the fallback is exercised on every host.
TRASH_PUT_PY='
import errno, os, stat, sys, time
trash, kind, src, pid, start = sys.argv[1:6]
def real_dir(p):
    try:
        st = os.lstat(p)
    except OSError:
        return None
    if not stat.S_ISDIR(st.st_mode) or os.path.realpath(p) != p:
        return None
    return st
t = real_dir(trash)
if t is None or t.st_uid != os.getuid():
    sys.exit(1)
if not os.path.isabs(src) or os.path.normpath(src) != src or os.path.basename(src) in ("", ".", ".."):
    sys.exit(1)
parent = os.path.dirname(src)
try:
    s = os.lstat(src)
except OSError:
    sys.exit(1)
if not stat.S_ISDIR(s.st_mode) or os.path.realpath(parent) != parent:
    sys.exit(1)
hold = None
for _ in range(16):
    tail = "%010d.%s.%s.%s" % (int(time.time()), kind, pid, os.urandom(3).hex())
    if os.path.lexists(os.path.join(trash, tail)):
        continue
    try:
        os.mkdir(os.path.join(trash, ".hold." + tail), 0o700)
    except FileExistsError:
        continue
    except OSError:
        sys.exit(1)
    hold = os.path.join(trash, ".hold." + tail)
    break
if hold is None:
    sys.exit(1)
try:
    tmp = os.path.join(hold, "owner.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("pid=%s\nfmt=v2\nstart=%s\n" % (pid, start))
    os.rename(tmp, os.path.join(hold, "owner"))
    seam = os.environ.get("COMMS_TEST_TRASH_RENAME_ERRNO", "")
    if seam:
        raise OSError(getattr(errno, seam, errno.EIO), "test seam: " + seam)
    os.rename(src, os.path.join(hold, "payload"))
except OSError:
    for n in ("owner.tmp", "owner"):
        try:
            os.unlink(os.path.join(hold, n))
        except OSError:
            pass
    try:
        os.rmdir(hold)
    except OSError:
        pass
    sys.exit(1)
sys.stdout.write(hold)
'

# trash_put <trash> <kind> <src> — move <src> into a new hold of <trash>. 0: <src> is now
# $TRASH_HOLD/payload | 1: nothing moved. Refused when no reaper sits beside this file, so nothing is
# ever moved that no reaper could delete. The caller finishes its own bookkeeping, then trash_commit.
trash_put() {
  local trash="$1" kind="$2" src="$3" hold
  TRASH_HOLD=""; TRASH_NOTE=""
  case " $TRASH_KINDS " in *" $kind "*) ;; *) return 1 ;; esac
  [ -n "$TRASH_HELPER_DIR" ] && [ -x "$TRASH_HELPER_DIR/runphase.sh" ] \
    || { TRASH_NOTE="no reaper (runphase.sh) beside trash.sh"; return 1; }
  command -v python3 >/dev/null 2>&1 || { TRASH_NOTE="python3 is not available"; return 1; }
  trash_ensure "$trash" || return 1
  proc_state "$$"
  hold="$(python3 -I -c "$TRASH_PUT_PY" "$trash" "$kind" "$src" "$$" "$PROC_START" 2>/dev/null)" || hold=""
  [ -n "$hold" ] || { TRASH_NOTE="could not move $src into $trash"; return 1; }
  TRASH_HOLD="$hold"
  trash_hook held "$hold"
  return 0
}

# trash_admin <git-common-dir, physical> <tree> — the admin dir <tree>'s gitfile names, when that is
# a real directory directly under <common>/worktrees at its own physical path. Prints it, or 1.
trash_admin() {
  local common="$1" tree="$2" gl adm
  [ -f "$tree/.git" ] && [ ! -L "$tree/.git" ] || return 1
  gl="$(cat "$tree/.git" 2>/dev/null)" || return 1
  adm="${gl#gitdir: }"
  [ "$gl" = "gitdir: $adm" ] || return 1
  case "$adm" in /*) ;; *) return 1 ;; esac   # a relative pointer (worktree.useRelativePaths) is not judged
  case "${adm#"$common"/worktrees/}" in "$adm"|''|*/*) return 1 ;; esac
  [ -d "$adm" ] && [ ! -L "$adm" ] && [ "$(cd "$adm" 2>/dev/null && pwd -P)" = "$adm" ] || return 1
  printf '%s' "$adm"
}

# Drop one admin dir, its `gitdir` back-pointer LAST: a partial delete leaves a registration git
# lists as prunable, never a dir that still claims a tree it no longer describes. 0 once it is gone.
trash_admin_drop() {  # <admin dir>
  local a="$1" e
  for e in "$a"/* "$a"/.[!.]* "$a"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ "$e" = "$a/gitdir" ] || rm -rf -- "$e" 2>/dev/null || true
  done
  rm -f -- "$a/gitdir" 2>/dev/null || true
  rmdir -- "$a" 2>/dev/null || true
  [ ! -e "$a" ] && [ ! -L "$a" ]
}

# trash_tree <git-common-dir> <trash> <kind> <dir> [<tree-relpath>] — the WORKTREE-AWARE rename.
# Moves <dir> (whose checkout is <dir>/<rel>, or <dir> itself) into a hold and drops exactly that
# tree's admin dir — never a repo-wide prune, and no git command at all. Before the move the tree's
# .git and the admin's gitdir must name each other; after it, the moved .git must still name the
# admin AND the admin must still name the PRE-rename path, so an admin dir git freed and handed to
# another tree in between is never deleted. 0 held and unregistered | 1 nothing moved | 2 held, the
# registration left in place (registered-but-missing, which git lists as prunable). Never commits:
# the caller does, after its own remaining steps.
trash_tree() {
  local common trash="$2" kind="$3" dir="$4" rel="${5:-}" tree adm tphys moved
  TRASH_HOLD=""
  common="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  tree="$dir${rel:+/$rel}"
  if [ ! -e "$tree" ] && [ ! -L "$tree" ]; then
    # A dir whose checkout was never staged has no registration: it moves plainly.
    [ -n "$rel" ] || return 1
    trash_put "$trash" "$kind" "$dir"; return $?
  fi
  [ -d "$tree" ] && [ ! -L "$tree" ] || return 1
  adm="$(trash_admin "$common" "$tree")" || return 1
  [ ! -e "$adm/locked" ] && [ ! -L "$adm/locked" ] || return 1
  tphys="$(cd "$tree" 2>/dev/null && pwd -P)" || return 1
  tphys="$tphys/.git"
  [ "$(cat "$adm/gitdir" 2>/dev/null)" = "$tphys" ] || return 1
  trash_put "$trash" "$kind" "$dir" || return 1
  moved="$TRASH_HOLD/payload${rel:+/$rel}/.git"
  if [ -f "$moved" ] && [ ! -L "$moved" ] && [ "$(cat "$moved" 2>/dev/null)" = "gitdir: $adm" ] \
     && [ "$(cat "$adm/gitdir" 2>/dev/null)" = "$tphys" ] && trash_admin_drop "$adm"; then
    return 0
  fi
  return 2
}

# trash_seal <hold> — hold -> entry: a rename within one directory, so constant time. 0 | 1.
trash_seal() {
  local h="$1" d n
  d="${h%/*}"; n="${h##*/}"
  case "$n" in .hold.*) ;; *) return 1 ;; esac
  trash_entry_name_ok "${n#.hold.}" || return 1
  [ -d "$h" ] && [ ! -L "$h" ] || return 1
  [ ! -e "$d/${n#.hold.}" ] && [ ! -L "$d/${n#.hold.}" ] || return 1
  command mv -- "$h" "$d/${n#.hold.}" 2>/dev/null
}

# trash_commit <trash> <hold> — seal the hold, then start the reaper EVEN IF the seal failed: a hold
# whose maker is gone is committed by the next reaper on proof of death. Always 0.
trash_commit() {
  [ -z "${2:-}" ] || trash_seal "$2" || true
  local p="${1%/*}"
  case "$p" in
    */.claude/worktrees) trash_reap_start repo "${p%/.claude/worktrees}" ;;
    *) trash_reap_start store "$p" ;;
  esac
  return 0
}

# THE START. Takes the trash's lock without blocking — held means a reaper is running, and it rescans
# before it exits, so there is nothing to do — and hands the locked fd (as fd 9) to a reaper in a NEW
# SESSION and process group (setsid through start_new_session: macOS has no setsid command), with cwd
# /, stdin/stdout/stderr on /dev/null, no other inherited descriptor, and no presence identity. It
# exits once the reaper has exec'd and never waits for it, so the reaper is out of the caller's
# process group before the launcher leaves it: a keeper that waits on (or kills) that group, and a
# command substitution that captures the caller's stdout, never wait on the reaper.
TRASH_LAUNCH_PY='
import fcntl, os, subprocess, sys
trash, mode, root, reaper = sys.argv[1:5]
prefix = sys.argv[5:]
try:
    fd = os.open(os.path.join(trash, ".reaper.lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
except OSError:
    sys.exit(1)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
if fd != 9:
    os.dup2(fd, 9)
    os.close(fd)
env = dict((k, v) for k, v in os.environ.items()
           if not (k.startswith("COMMS_PRESENCE_") or k == "COMMS_SELF" or k.startswith("GIT_")))
env["COMMS_TRASH_LOCK_FD"] = "9"
subprocess.Popen(prefix + [reaper, "reap", "--" + mode, root], cwd="/", env=env,
                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                 close_fds=True, pass_fds=(9,), start_new_session=True)
'

# trash_reap_start store <mount-base> | repo <repo-root> — never waits; always 0. Background QoS on
# macOS (taskpolicy -b: throttled CPU and I/O, inherited by rm), nice 19 elsewhere.
trash_reap_start() {
  local mode="${1:-}" root="${2:-}" trash reaper
  root="${root%/}"
  [ -n "$root" ] || return 0
  case "$mode" in
    store) trash="$root/$TRASH_LEAF" ;;
    repo) trash="$root/.claude/worktrees/$TRASH_LEAF" ;;
    *) return 0 ;;
  esac
  reaper="$TRASH_HELPER_DIR/runphase.sh"
  [ -n "$TRASH_HELPER_DIR" ] && [ -x "$reaper" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  trash_ensure "$trash" || return 0
  local -a prefix
  if [ -x /usr/sbin/taskpolicy ]; then prefix=(/usr/sbin/taskpolicy -b)
  else prefix=("$(command -v nice 2>/dev/null || printf nice)" -n 19); fi
  python3 -I -c "$TRASH_LAUNCH_PY" "$trash" "$mode" "$root" "$reaper" "${prefix[@]}" </dev/null >/dev/null 2>&1 || true
  return 0
}

# trash_lock_held <trash> — fd 9 is <trash>/.reaper.lock AND holds its flock. Compared through
# fstat in Python: on macOS stat(/dev/fd/9) reports devfs's device, so `[ /dev/fd/9 -ef … ]` is
# false even for the right file. flock on fd 9 succeeds only for the description that holds the lock
# (or takes a free one), so a run that did not come through the launcher still cannot share a trash.
trash_lock_held() {
  python3 -I -c '
import fcntl, os, sys
a = os.fstat(9)
b = os.lstat(sys.argv[1])
if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
    sys.exit(1)
fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
' "$1/.reaper.lock" 2>/dev/null
}

# trash_record_dead <record> [<pid it must name>] — is the maker this record names PROVEN dead? ps
# reports no such process, or a v2 record's start time differs (a recycled pid). A live pid, an
# unverifiable ps, an unreadable or malformed record, or a pid other than the one required never is.
trash_record_dead() {
  local f="$1" body pid start fmt
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  body="$(cat "$f" 2>/dev/null)" || return 1
  pid="$(sed -n '/^pid=/{s/^pid=//p;q;}' <<<"$body")"
  start="$(sed -n '/^start=/{s/^start=//p;q;}' <<<"$body")"
  fmt="$(sed -n '/^fmt=/{s/^fmt=//p;q;}' <<<"$body")"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -z "${2:-}" ] || [ "$pid" = "$2" ] || return 1
  proc_state "$pid"
  [ "$PROC_STATE" = dead ] && return 0
  [ "$PROC_STATE" = live ] && [ "$fmt" = v2 ] && [ -n "$start" ] && [ -n "$PROC_START" ] \
    && [ "$PROC_START" != "$start" ] && return 0
  return 1
}

# trash_owner_write <admin-dir> — the owner record of an integrate or verify-fresh tree, beside its
# registration (outside the checked-out tree, so the post-suite cleanliness check never sees it):
# pid, fmt=v2 and start rendered by proc_state, through a temp file and a rename. Best-effort: a
# failed write costs only this proof, and the repo sweep falls back to the pid in the tree's name.
trash_owner_write() {
  local a="$1" tmp
  [ -d "$a" ] && [ ! -L "$a" ] || return 0
  proc_state "$$"
  tmp="$(mktemp "$a/agent-comms-owner.XXXXXX" 2>/dev/null)" || return 0
  if printf 'pid=%s\nfmt=v2\nstart=%s\n' "$$" "$PROC_START" > "$tmp" 2>/dev/null \
     && command mv -f "$tmp" "$a/agent-comms-owner" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# trash_tree_pid <tree basename> — the pid an integrate or verify tree's NAME carries, or nothing:
# .integrate-<pid>-<n> and .verify-<pid>-<n> (every tree made since deferred deletion), and the legacy
# .integrate-<1-7 digits> (a pid: presence instances are 8-64 characters). A legacy instance-named
# tree carries none.
trash_tree_pid() {
  local n="$1" p
  case "$n" in
    .integrate-*-*|.verify-*-*)
      p="${n#.*-}"
      case "${p#*-}" in ''|*[!0-9]*) return 0 ;; esac
      p="${p%%-*}" ;;
    .integrate-*)
      p="${n#.integrate-}"
      [ "${#p}" -le 7 ] || return 0 ;;
    *) return 0 ;;
  esac
  case "$p" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$p"
}
