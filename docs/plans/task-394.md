# Task 394: move bulk deletes off the turn, dispatch and landing paths

Status: plan, not yet implemented. Scope is agent-comms only. Basis needs no change. The lines it
reads (`clean-mounts-target v1`, `integrate-result v1`) keep their fields and meanings. Its keeper
supervises by process group, and the reaper leaves that group (see "The reaper"). Its relocate
inspection lists only non-dot idents under a repo key, so it never sees a trash dir.

## Goal

No review turn, panel dispatch or landing waits on a recursive delete of a checkout or a provider
home. Each discarded bulk tree is renamed into a trash dir on the same volume, which takes constant
time. One detached, low-priority reaper deletes it later. Retention does not change, with one
exception: the existing 120-minute aside horizon now applies across the whole mount store, not only
when the same ident restages.

## What the code does today (verified at 33c4d15)

| Site | What it deletes inline |
|---|---|
| `runphase.sh:2140` `mount_restage` | expired asides of this ident only (`find … -mmin +120 -exec rm -rf`), under the restaging runner's own ident claim |
| `runphase.sh:2349-2350` `unmount_artifact` | a pending `.new.*` generation (`worktree remove --force`, then `rm -rf`) |
| `runphase.sh:2354`, `:2362` `unmount_artifact` | a throwaway mount's tree (`worktree remove --force`), then its whole ident dir, including `home/auth.json` (`rm -rf`) |
| `runphase.sh:5884` → `cm_rm_last` (`:5717`) | a retired ident's payload in its tombstone, after the admin drop and journal (`:5875-5882`) |
| `comms.sh:5256-5258` `suite_verify_candidate` | pre-clean of a same-named verification tree (`worktree remove --force`, repo-wide `worktree prune`, `rm -rf`) |
| `comms.sh:5537`, `:5598` (traps), `:5665` (success) | the `.integrate-${instance:-$$}` tree |
| `comms.sh:5912-5916` `verify_fresh` | the `.verify-$$-$RANDOM` tree |

These facts shape the design:

- Basis's keeper runs integrate and dispatch in process group K. It waits until no other member of K
  is left, and after the linger bound it signals `-K`. Anything that stays in K delays the landing
  slot. Anything that leaves K is neither waited for nor killed. `presence with-beat`'s quiescence
  sweep (`pgroup_stop`) is also group-based.
- A runner that cannot take its ident's claim fails the turn (`runphase.sh:3480-3486`). It does not
  wait and it does not degrade. So nothing new may hold a durable ident's claim, even briefly.
- `git worktree add` names an admin dir after the tree's basename and reuses the lowest free name.
  `.integrate-<instance>` is reused by every integrate of one presence instance. An asynchronous
  sweeper could therefore take a new live tree for the leaked tree it had judged dead.
- The integrate owner record (section 4) is written by `comms.sh` and judged by the reaper. Both
  sides must render a process start time with the same bytes. Today only runphase's `proc_state`
  pins the rendering (`LC_ALL=C TZ=UTC`). comms.sh's presence probes do not pin it.

## Mechanism

### 1. One helper: `helpers/trash.sh`

`helpers/trash.sh` is a new sourced library, like `settings.sh`. It is added to `HELPERS` in
`install.sh`. It owns the trash paths, the rename, the worktree-aware rename, the reaper start and
the process-liveness probe. No delete site renames, unregisters or starts a reaper on its own.

```
TRASH_LEAF=.comms-trash
trash_dir_for <parent>                         # <parent>/.comms-trash
trash_ensure <trash>                           # 0 usable | 1 (+TRASH_NOTE)
trash_put <trash> <kind> <src>                 # 0 + TRASH_ENTRY | 1, nothing moved
trash_tree <git-common-dir> <trash> <kind> <dir> [<tree-relpath>]
                                               # 0 moved and unregistered | 1 nothing moved
                                               # 2 moved, registration left in place
trash_reap_start store <mount-base> | repo <repo-root>   # never waits; always returns 0
trash_owner_write <admin-dir>                  # best-effort owner record (section 4)
proc_state <pid>                               # moved here verbatim from runphase.sh
```

**Sourcing.** `runphase.sh` sources `trash.sh` next to itself and dies at startup with a "reinstall"
message if it is missing, because every claim needs `proc_state`. `comms.sh` sources it like
`settings.sh` (only if present). Each comms.sh site checks `declare -F trash_tree` and runs today's
code when the check fails, so a test that copies `comms.sh` alone keeps working. The fixtures that
copy `runphase.sh` alone (`tests/groups/agents.sh:534`, `events.sh:896`, `:921`, `:953`) also copy
`trash.sh`. `proc_state` moves without any change to its text, so claims, `cm_claims` and the owner
record share one rendering.

**Trash paths.** One trash per mount store, `<base>/.comms-trash` (next to the 64-hex repo-key
dirs). One per repo, `<main root>/.claude/worktrees/.comms-trash`. Each trash shares a parent
directory with every tree it receives, so the two are on the same volume. The leaf name belongs to
agent-comms, so no other tool's trash (for example ticket 382's) shares it. The name is dot-prefixed,
so none of these ever sees it:

- the `"$base"/*/` and `"$scope"/*/` globs,
- `mount_report_orphans` and the whole-store GC,
- Basis's relocate inspection,
- the worktree slug grammar (`^[a-z0-9]…`).

`.claude/worktrees` is already ignore-covered and is one of `SNAPSHOT_RUNTIME_ROOTS`. `trash_ensure`
creates the trash dir mode 700. It then requires a real directory, not a symlink, at its own
physical path, owned by the current uid. No one writes to or reaps from a trash that fails this
check.

**Entry names.** An entry is named `<10-digit epoch>.<kind>.<pid>.<6 hex>`. `<kind>` is one of
`aside`, `throwaway`, `pending`, `retire`, `integrate` or `verify`. The names sort by age. None
matches `tmp-*`, `.retire.*`, `.integrate-*` or `.verify-*`. The reaper deletes only direct
children whose name matches this grammar exactly. Dot-names (`.reaper.lock`) are control files.
Anything else in a trash dir is left alone. If a generated name already exists, the put draws a
new one.

**The rename.** `trash_put` runs a short `python3 -I` program owned by `trash.sh`, which calls
`os.rename`. That call can fail with `EXDEV`, but it never copies. `mv` is not used, because on
`EXDEV` it falls back to copy-and-delete, which criterion 2 forbids. The program moves `<src>` only
when all of these hold:

- `<src>` is a real directory (lstat, not a symlink).
- `<src>`'s parent sits at its own physical path, so no symlinked ancestor can redirect the move
  out of the store or the repo.
- The trash passes the `trash_ensure` checks, done again in Python.

On any failure it returns 1 and nothing has moved, so the caller runs today's code unchanged.
`python3` is already a prerequisite of both helpers. If it is missing, every put fails and every
site keeps today's behavior. A test seam, `COMMS_TEST_TRASH_RENAME_ERRNO`, makes the program raise
a chosen errno (for example `EXDEV`), so the fallback is tested on every host.

**The worktree-aware rename (criterion 3).** `trash_tree` handles every git tree. It runs no git
command:

1. Read `<dir>/<rel>/.git`. It must be a regular file `gitdir: <A>`, where `<A>` is absolute.
   `<A>` must be a real directory directly under `<git-common-dir>/worktrees/`, at its own
   physical path, with no `locked` file. Its `gitdir` file must hold exactly the physical path of
   `<dir>/<rel>/.git`.
   - If `<dir>/<rel>` does not exist (a throwaway that never staged), there is no registration and
     the dir is moved plainly.
   - Any other mismatch returns 1, including relative pointers (`worktree.useRelativePaths`). The
     site then keeps today's path.
2. `trash_put` the whole `<dir>`.
3. Check both pointers again after the move:
   - `<entry>/<rel>/.git` must still be `gitdir: <A>`.
   - `<A>/gitdir` must still name the pre-rename path.

   The second check stops it from deleting an admin dir that git freed and gave to another tree in
   between. Only when both hold does it delete `<A>`, which is small (HEAD, index, logs). It deletes
   `gitdir` last, so a partial delete leaves a registration that git lists as prunable. Otherwise
   it leaves `<A>` and returns 2.

No `git worktree repair` and no repo-wide `git worktree prune` is part of this step.

**Credentials (criterion 4).** One runphase function, `mount_cred_clear <ident-dir>`, unlinks
`<ident-dir>/home/auth.json`. That file is the only credential the runner stages into a mount home
(the codex and grok arms, `runphase.sh:4196` and `:4333`). The function succeeds only if the file is
gone afterwards. A site that cannot clear it does not trash the ident. It runs today's inline delete
instead, so no credential copy ever enters a trash.

### 2. The reaper: `runphase.sh reap --store <base> | --repo <root>`

The reaper is an internal subcommand, listed in the runphase header as internal. It lives in
runphase.sh because it needs runphase's code: `mount_claim_take`, `cm_claims` and
`mount_cred_clear`. comms.sh starts it through `trash_reap_start`, which finds `runphase.sh` next
to `trash.sh`. If the reaper is not executable there, `trash_put` refuses, so nothing is moved that
no reaper could delete.

**Start and detach.** `trash_reap_start` runs a short `python3 -I` launcher, which does this:

1. Open `<trash>/.reaper.lock` with `O_NOFOLLOW` and try `flock(LOCK_EX|LOCK_NB)`. If the lock is
   held, exit 0: a reaper is running, and it rescans before it exits.
2. Move the lock fd to fd 9 (`dup2`), which neither helper uses. Then start the reaper with
   `subprocess.Popen([prefix…, runphase.sh, reap, …])` and these options:
   - `start_new_session=True`, so the reaper calls `setsid` and gets a new session and process
     group. macOS has no `setsid` command.
   - `cwd="/"`.
   - stdin, stdout and stderr on `/dev/null`.
   - `close_fds=True` with `pass_fds=(9,)`.
   - `COMMS_PRESENCE_*` and `COMMS_SELF` removed from the environment.
3. Exit at once without waiting. `Popen` returns only after the child has exec'd, so the reaper is
   out of the caller's group before the launcher leaves it. The reaper is reparented to pid 1. It
   holds none of the caller's descriptors. Basis's keeper does not count it toward K, and neither
   its `kill(-K)` nor with-beat's `pgroup_stop` reaches it. A command substitution that captures
   integrate's stdout does not wait for it.

**Priority.** If `/usr/sbin/taskpolicy` is executable (macOS), the prefix is `taskpolicy -b`
(background QoS: throttled CPU and I/O, inherited by `rm`). Otherwise it is `nice -n 19`.

**Lock (criterion 6).** fd 9 holds the flock, in the reaper and in every child it starts, `rm`
included. So at most one deleter runs per trash dir. The kernel drops the lock when the last holder
exits, SIGKILL included, so a killed reaper leaves no stale lock to judge. Its half-deleted entry is
still a well-named entry, and the next reaper deletes the rest. `reap` refuses to run (exit 2)
unless fd 9 is open on `<trash>/.reaper.lock` (`[ /dev/fd/9 -ef … ]`) and `COMMS_TRASH_LOCK_FD=9`.
So a manual run cannot bypass the lock.

**One run.**

1. Domain sweep (section 3b for `--store`, section 4 for `--repo`).
2. Delete pass, oldest entry first. If an entry has top-level `.claim.*` files (`retire` and
   `throwaway` entries), the reaper takes the entry's claim with `mount_claim_take` (holder
   `reaper:<pid>`).
   - A claim held by a live process defers the entry.
   - A dead or released holder is superseded exactly as today. This is the tombstone claim of
     criterion 9.

   The reaper then unlinks any `home/auth.json` left in the entry, as defense in depth (the site
   already cleared it). Then it runs `rm -rf -- <entry>`. Taking a claim on a trash entry can
   never fail a turn, because no runner contends for a trash entry.
3. Deferred entries are retried after the others, then polled every second for up to 30 seconds.
   An entry still held after that waits for the next reaper. Repeat steps 2-3 while new names
   appear.
4. Close fd 9. If the trash now holds a name this run never saw (a put that raced its exit), call
   `trash_reap_start` again. That call either takes the lock or finds another reaper holding it.
   A put renames first and starts second, and the reaper closes first and rescans second. So every
   put is seen by a reaper.

Test seam: `COMMS_TEST_REAP_HOOK`, called as `<hook> <event> <entry>` at `locked` and
`before-delete`. It has the same shape as `cm_hook`.

**Per delete or per run.** Every successful put calls `trash_reap_start`, and so does every
`mount_restage` (section 3b). So the store-wide sweep runs at least once per mounted turn. The lock
folds these calls into at most one reaper per trash, and a running reaper absorbs puts that arrive
while it runs. A launch costs one Python process, about 30 ms. Everything else happens in the
detached reaper.

### 3. The sites

**a. Throwaway teardown (`unmount_artifact`).**

1. A pending generation goes through `trash_tree <common> <store trash> pending <tmp>`. This step
   runs first, so the pending tree does not ride inside the ident dir with its registration still
   in place. Its fallback is today's two lines. A return of 2 leaves a registered-but-missing
   `.new.*`. For a durable ident, the next restage's existing pending recovery removes it with
   `worktree remove --force` (git accepts a missing tree).
2. A throwaway (always a real dir allocated by this run, as today) has `mount_cred_clear` run first.
   Then `trash_tree <common> <store trash> throwaway <ident-dir> view/tree` moves the whole ident
   dir (tree, home, state, claims) in one rename. It drops the tree's admin under the criterion 3
   checks.
3. The runner's claim moved with the ident dir. `MOUNT_HOLDER` is re-pointed at
   `<entry>/.claim.N` before `mount_claim_release`, so the reaper can take it at once.
4. On return 1, or a credential that would not clear, today's `worktree remove --force` and
   `rm -rf` run unchanged.
5. The store reaper is started.

`<common>` is `mount_git -C "$main_root" rev-parse --git-common-dir`, made absolute. The store base
comes from the ident dir's path (`<base>/<key>/<ident>`), not from a `cmd_run` local, because the
function runs in the EXIT trap.

**b. Asides (`mount_restage`, criterion 7).** One function, `mount_asides_expired <ident-dir>`,
selects asides. It finds real directories named `.aside.*` directly in the ident dir with
`find -P … -mmin +$MOUNT_ASIDE_HORIZON_MIN`. `MOUNT_ASIDE_HORIZON_MIN=120` is defined once, and the
test is exactly today's `-mmin +120`. Two callers use it:

- **The restaging runner, for its own ident.** At `:2140`, the inline `find … -exec rm -rf` becomes
  one `trash_put <store trash> aside <aside>` per expired aside. The runner holds its ident's claim,
  as today. If a put fails, the runner runs today's `rm -rf` on that aside, which is criterion 2's
  fallback. Then it calls `trash_reap_start store <base>`.
- **The store sweep, for every other ident.** One `find -P` over the store selects
  `<base>/<64-hex key>/<ident>/.aside.*` past the horizon. It prunes dot-named entries at depths 1
  and 2, so trash entries and `.retire.*` tombstones are never entered. For each ident with a
  match, the sweep reads the ident's claims with `cm_claims` (read-only) and skips the ident if any
  claim is held by a live or unverifiable process. The sweep never takes an ident claim, because a
  runner that met that claim would fail its turn (`:3480-3486`). It then calls `trash_put` on each
  aside. A failed put leaves that aside where it is, which is today's state for an ident that never
  restages. The sweep never deletes in place. This covers the 288 expired asides on idents that
  never restage.

A race remains: a `clean mounts --thread` can claim the ident between the sweep's read-only check
and its rename. The rename is atomic, so `cm_check` either never sees the aside, skips it
(`[ -d "$e/held" ] || continue`), or fails its content scan closed (`content-unverifiable`). A
re-run then proceeds. A concurrent restage only ever creates fresh asides, which the horizon
excludes. The retention note at `:2133-2139` (a detached holder may lose its cwd) does not change.

**c. `clean mounts --thread` hand-off (criteria 4 and 9).** `cm_remove` does not change up to the
tombstone rename (`:6018`). `cm_finish_tomb` does not change through the admin drop, the journal of
`admin=` (`:5875-5882`) and the `unregistered` hook. Then, when the tombstone holds the ident:

1. `mount_cred_clear "$tomb/$ident"`.
2. `trash_put <store trash> retire "$tomb"` moves the whole tombstone (record, claims and payload)
   into the store trash in one rename. A new `handed-off` hook fires. The result is `CM_ST=removed`,
   `CM_WHY=proven`.
3. The callers (`cm_remove`, `cm_replay_tomb`) release the tombstone claim at its new path, set in
   `CM_TOMB_AT`. They start the store reaper. The clean returns. Nothing in the payload has been
   deleted.

If the credential will not clear, or the put fails, today's `cm_rm_last` and `cm_drop_tomb` run
inline with today's statuses.

An interruption leaves only states that already exist:

- Before the put, the tombstone is still at `<scope>/.retire.<ident>.XXXXXX`. The existing replay
  (claim, regate, `cm_finish_tomb`) finishes it through the same hand-off.
- After the put and before the release, the entry's claim names a dead pid, which the reaper
  supersedes.
- A handed-off tombstone has left the scope, so `cm_target` and `cm_tomb_scan` no longer see it. A
  re-run reports `absent`, exactly as after a full inline removal today. The record format,
  `cm_tomb_match` and the replay logic do not change.

`status=removed` keeps its field set. Its meaning becomes "unregistered and moved out of the
store's live namespace; the reaper deletes the payload". `docs/COMMANDS.md` says so.

**d. Integrate and verify fresh.** One comms.sh function, `integrate_tree_drop <root> <tree>`,
replaces every teardown of these trees:

- the success path at `:5665`,
- both EXIT trap strings (the literals are still baked in, now as arguments to a file-scope
  function),
- `verify_fresh` at `:5912-5916`,
- the tree part of the pre-clean at `:5256` and `:5258`.

It runs `trash_tree <common> <repo trash> integrate|verify <tree>`. On 0 or 2 it starts the repo
reaper. On 1, or when `trash.sh` is absent, it runs today's `git worktree remove --force` and
`rm -rf`.

The verification tree becomes `.integrate-$$-$RANDOM`, unique per run like `.verify-$$-$RANDOM`.
This removes the name-reuse race described in "What the code does today". It does not change what
is checked out or what the suite runs. Only the path name changes. Basis's `integration-failure.ts`
pattern `\.integrate-[^/]+/` and the suite's `.integrate-*` globs still match it.

The repo-wide `git worktree prune` at `:5257` stays where it is. It is today's crash recovery for a
registered-but-missing tree. It also clears a stale registration of `main` that the final occupancy
guard would otherwise refuse on, so removing it would change landing behavior. No trash step calls
it or depends on it. A concurrent prune can only remove an admin dir that `trash_tree` was about to
remove. The post-rename check then finds nothing to do.

### 4. Leaked `.integrate-*` and `.verify-*` trees (criterion 8)

**Owner record.** `suite_verify_candidate` is the one site that creates trees for both integrate
and verify. Right after its `git worktree add`, `trash_owner_write` writes
`<admin>/agent-comms-owner` with `pid=$$`, `fmt=v2` and `start=$PROC_START` (from `proc_state $$`).
It goes through a temp file and a rename. The admin dir is outside the checked-out tree, so the
post-suite cleanliness check never sees the record. Git and `worktree.sh` read only `HEAD`,
`gitdir` and the rebase dirs there. The record is dropped with the tree. If the write fails, the
landing is not affected, and the sweep below falls back to the pid in the tree's name.

**The repo sweep** in `reap --repo`. For each real directory `<root>/.claude/worktrees/.integrate-*`
or `.verify-*`, the owner is proven dead only by one of these:

- **Record:** a readable record whose pid matches the pid in the name, and `proc_state` returns
  either `dead`, or `live` with a start time different from the recorded one (a recycled pid).
- **No record:** a pid parsed from the name, and `proc_state` returns `dead`. These names carry a
  pid:
  - new `.integrate-<pid>-<n>`,
  - legacy `.integrate-<1-7 digits>` (a pid, because presence instances are 8-64 characters,
    `comms.sh:4462`),
  - `.verify-<pid>-<n>`.

Everything else is kept: `live`, `ambig`, a malformed record, or a legacy instance-named tree with
no record. Age is never consulted.

- A tree proven dead goes through `trash_tree`.
- On return 1 the tree is left alone. The sweep never deletes in place or falls back to `--force`.
- On return 2 the tree is in trash and its stale registration is left for integrate's existing
  pre-clean prune.

The live integrate tree seen on 10-08 (`.integrate-43273`) is kept by this rule. The first repo
reap after deploy sweeps the two leaked basis trees from 10-02 and 10-06, if their pids are dead,
as they are expected to be.

## Invariants this must not break

- Deletion is delayed, never skipped. Everything that is put has a reaper started for it, or is
  already covered by a running reaper that rescans before it exits.
- What is retained, and for how long, does not change, except the store-wide aside horizon.
- Nothing new ever holds a durable ident's claim. The only claims the reaper takes are on trash
  entries.
- The restage still builds a new generation per turn. The small inline deletes at `:2215` (the
  previous admin dir) and `:2225` (the empty tmp) stay.
- No credential copy is ever moved into a trash.
- An admin dir is removed only when the tree's `.git` and the admin's `gitdir` name each other,
  checked after the move against the pre-rename path. Nothing runs a repo-wide prune for this
  purpose.
- `clean mounts --thread` keeps its claim, regate, content gate and journal ordering up to the admin
  drop. Every interrupted state stays replayable or reapable.
- The reaper deletes only well-named direct children of a trash that passes the
  real-dir/owner/physical-path check, and never follows a symlink. Sweeps only rename. They never
  delete in place.
- Integrate's stdout contract, exit classes, CAS, attestation and suite supervision do not change.
- The trash functions write nothing to stdout.

## Errors and partial failure

Every helper function returns a status. A failure to move falls back to the site's existing code, so
no turn, landing or clean fails because of this change where it did not fail before.

The reaper's own failures are silent, because its stdio is `/dev/null`. The trash dir listing is
the observable. Some entries stay in the trash and every later reaper retries them:

- an entry that `rm -rf` cannot fully delete (for example a read-only directory, the same limit as
  today),
- an entry whose claim cannot be judged (unreadable, or a live holder past 30 seconds).

When `trash_tree` returns 2, the old registration is left registered-but-missing, which is what a
crashed integrate leaves today. Git lists it as prunable. For an integrate tree, integrate's
existing pre-clean prune clears it. For a pending mount generation, the next restage's pending
recovery clears it.

A risk, not a defect: background QoS throttles I/O hard. If a machine stays busy enough that
deletes fall behind creation, the trash grows. The listing shows it. The fix would be a different
priority prefix in `trash_reap_start`, which is one place.

## Deliberately not done

- These still delete inline: the whole-store GC (`clean mounts --yes` without `--thread`), the
  restage's pending-generation reclaim (`:2151-2152`), the symlink-deposit cleanup (`:2271-2272`)
  and `worktree retire`. None of them is on a turn, dispatch or landing path. They are operator
  commands or rare crash recovery. Each can adopt `trash_tree` later with one call.
- No change to what is checked out or tested, to the aside horizon or to the generation-per-turn
  restage.
- No change to ticket 382's `$TMPDIR` snapshot or its deleter. Its trash is not this one.
- No reaper log file, no Spotlight or Time Machine exclusion, no `ionice`, and no priority option.
- No change to comms.sh's presence `lstart` probes. Only the new owner record uses `proc_state`.

## How it will be shown working

New assertions are added. `tests/expected-counts.tsv` and `tests/section-counts.tsv` change in the
same commit, by delta.

- **Criterion 2, rename (mountclean, mounts and core groups).** A throwaway, an integrate tree and a
  retired tombstone each appear as one entry in their trash after the site returns. The source path
  is gone.
- **Criterion 2, fallback.** The fallback is tested twice: with an unwritable trash, and with
  `COMMS_TEST_TRASH_RENAME_ERRNO=EXDEV`. Each time the site removes the tree inline exactly as
  today, and the trash holds no entry. The same holds for an aside on its restaging ident.
- **Criterion 3.**
  - `trash_tree` drops exactly the moved tree's admin dir.
  - A decoy registration whose directory is missing is still registered afterwards, which proves no
    repo-wide prune ran.
  - When the admin's `gitdir` is rewritten to another path before the move, the admin is kept.
  - When a hook makes the admin's `gitdir` name another tree after the rename, the admin is kept and
    the result is 2.
  - A relative gitfile returns 1.
- **Criterion 4.** At the reap hook's `before-delete`, no `auth.json` exists anywhere in a
  `throwaway` or `retire` entry.
- **Criterion 5 (core group).**
  1. Start `comms.sh integrate` in a fixture repo from Python as a session leader, the way the
     keeper runs it. Set `COMMS_TEST_REAP_HOOK` to a hook that blocks on a file, with a bounded
     wait.
  2. Poll until integrate's process group is empty. Assert this happened within a few seconds.
  3. At that moment, assert the reaper is still blocked, in a different session and process group.
     Assert its stdin, stdout and stderr resolve to `/dev/null` and its cwd to `/` (`lsof -p`).
  4. Send `kill(-K, SIGTERM)` to integrate's old group, as the keeper does after its linger bound.
     Assert the reaper is still alive.
  5. Release the hook and wait for the trash to empty.
- **Criterion 6.**
  - While one reaper is blocked in the hook, a second `trash_reap_start` starts nothing: the hook
    fires once.
  - A hook deletes part of an entry and then blocks. SIGKILL the reaper's whole group. The next
    start takes the lock and removes the rest of the entry.
- **Criterion 7.** Asides backdated 121 minutes (`touch -t`) on an ident that never restages are
  moved by a reap that another ident's put started. A 119-minute aside is not moved. Neither is an
  expired aside on an ident whose claim a live process holds.
- **Criterion 8.** These trees are swept:
  - a leaked tree with a dead recorded pid,
  - a tree whose recorded pid is live but whose start time differs from the record,
  - a legacy `.integrate-<pid>` whose pid is dead.

  These trees are kept:
  - a tree owned by a live process,
  - a legacy instance-named tree with no record, even backdated by days.
- **Criterion 9.**
  - The existing mountclean replay and kill-boundary tests keep passing.
  - A new test asserts that `clean mounts --thread --yes` returns `removed` while the reap hook
    blocks, with the tombstone gone from the scope and the payload in trash.
  - A kill at `handed-off` leaves an entry that the reaper finishes.
- Existing tests that assert bytes are gone from the store, rather than gone from the live
  namespace, wait for the reaper through a test-lib `reap_wait <trash>` (lock free, no entries,
  bounded).
- Run the focused groups (`mounts`, `mountclean`, `core`, `install`, `isolation`, `worktree`,
  `agents`, `events`). Integrate runs the full suite.

**Criterion 10 measurement.** This runs on this Mac, in `$TMPDIR`. It never touches the live basis
checkout, the live mount store or `~/.local/state`:

1. Make a scratch `git clone` of the basis repo. Its tracked tree is about 2k entries / 80 MB, the
   same tree a real landing checks out.
2. Give the clone a local `.comms/config` with a `suite-cmd` that passes and no
   `suite-attest-secs`, so every run builds the verification tree. The clone has no counts
   contract, so no completion line is required.
3. Add a `reference-transaction` hook that records `time.time()` when `refs/heads/main` commits.
4. Land a one-commit branch three times with the 33c4d15 helpers (`git archive` into scratch). Then
   land one three times with the branch's helpers.
5. Record the time from update-ref to integrate's exit for each run. Report the medians before and
   after.

The docs record only the anonymized tree size.

## Docs updated in the same commit

- `docs/INTERNALS.md`: a new section, "Deferred deletion: trash and reaper". It covers paths, names,
  lock, detach, priority, the sweeps and their claim rule, the owner record and partial-failure
  states. The mount-cleanup section notes the hand-off.
- `docs/COMMANDS.md`:
  - `clean mounts --thread` (`removed` now means handed to the reaper).
  - Integrate's verification-tree naming and cleanup, including exit 18's "the verification tree is
    removed".
  - `verify fresh`.
  - The store layout gaining `.comms-trash`.
- `docs/PROTOCOL.md`: wherever the store layout is described.
- `docs/ROADMAP.md`: the field report and the before/after figures.
- The `runphase.sh` header lists `reap` as internal.
