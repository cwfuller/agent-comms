# Task 401: seed a fresh isolated codex home's plugins and catalog by APFS clone

Status: plan, not yet implemented. Scope is agent-comms only. Decided by the operator before this
plan: option b. The reviewer keeps the same tools, plugin sync stays on, homes stay isolated per
ident, and existing homes are not touched (their deletion belongs to other tasks).

## Goal

A mounted codex reviewer leg gets a fresh isolated `CODEX_HOME` (`$mount_kdir/home`) on its first
turn. Today codex fills that home itself: a 762-entry, 31.4 MB `plugins/cache` tree plus a
~32 MB `cache/remote_plugin_catalog/<id>.json`, downloaded and written per ident (10-08: 247 homes,
7.9 GB). The change makes the runner put those two trees there by `clonefile(2)` from one canonical
copy, so the bytes are shared copy-on-write and nothing is downloaded, while everything codex does
afterwards (sync, install markers, `codex_apps_*` cache, sessions) is unchanged.

## Canary: what codex 0.160.1 does with a seeded home (measured 2026-10-08)

Method: scratch `CODEX_HOME` under `$TMPDIR` (five-key-style config, `auth.json` copied in, low
effort), seed source = the newest live reviewer home, a manifest (path, type, size, sha256 prefix,
birth time) taken of `plugins/` and `cache/` before and after one turn. Two drivers: `codex exec`,
and `codex app-server` (initialize, `thread/start`, `plugin/list`, `turn/start`), because
`codex exec` never creates the remote catalog and `plugin/list` does. The scripts lived in `$TMPDIR`
and are not committed; the implementation phase repeats this canary through the real mounted
runner (see "Showing it work"), so the numbers below are the plan's evidence, not the final proof.

| arm | plugins before -> after | cache/ before -> after | what changed |
|---|---|---|---|
| fresh, no seed (exec) | 0 -> 762 entries, 535 files, 31,439,077 B | 0 -> 5 entries, 2,136,597 B (`codex_apps_*` only, no catalog) | everything is new |
| fresh, no seed (app-server + `plugin/list`) | 0 -> 762 / 31,439,077 B | catalog appears, 32,463,696 B; `plugin/list` took 29 s | everything is new |
| plugins seeded (same codex version) | 761 / 31,439,077 B -> **identical**, same digest | catalog fetched fresh, 32,463,696 B | 0 content changes; 11 files rewritten with identical bytes (`<plugin>/.codex-remote-plugin-install.json`, ~50 B each, new inode) |
| plugins + catalog seeded | plugins as above | 3 entries / 32,438,338 B -> same file, **same hash, same birth time**, plus `codex_apps_*` (+2.1 MB); `plugin/list` took 7 s | catalog accepted and untouched |
| **stale** seed (5-day-old tree, 646 entries; 5-day-old 30,851,229 B catalog) | 646 -> 762 entries (31,438,934 B); 176 entries added or changed | catalog byte-identical and not rewritten after `plugin/list` | codex syncs the plugins tree incrementally, and does not refresh an old catalog on its own |

Conclusions the mechanism relies on:

1. codex does **not** rewrite the plugins cache each turn. Against a current seed it rewrites 11
   tiny marker files; against a stale seed it adds or changes only what differs. So seeding the
   plugins tree is worth shipping (acceptance criterion 1's stop condition did not trigger).
2. codex **accepts** a pre-seeded catalog and leaves it byte-identical (so the catalog is seeded).
   It also showed no age limit up to 5 days, so a seeded catalog is only as fresh as the seed.
   That is why the canonical copy carries a maximum age (below).
3. The installed plugin set (11 ids, with their `enabled` flags) from `plugin/list` is identical for
   an unseeded and a seeded home. The 5 differing catalog rows are uninstalled catalog entries that
   drifted between the snapshot and the fresh fetch. So the reviewer's tool surface is unchanged.
4. The "catalog is rewritten per session" observation in older homes did not reproduce in a single
   fresh-home session. The plan does not add a fix for it; see "What it will not do".
5. Cost of a clone on this Mac: `cp -c -R` of the plugins tree 0.08 s; `clonefile(2)` of the
   directory 8 ms; the clone has zero symlinks and zero files with link count above 1, and its
   inodes differ from the source's.
6. **`cp -c` is not usable.** Its man page says it falls back to `copyfile(2)` (a real byte copy)
   when cloning is not possible. Acceptance criterion 2 forbids that fallback, so the clone must
   call `clonefile(2)` directly and treat any error as "no seed".

## Mechanism

### Layout and key

- New helper `helpers/codex_seed.py`, Python 3 stdlib only (`ctypes` for `clonefile`), run as
  `python3 -I`, like `method_guidance.py` and `leg_usage.py`. It owns every filesystem step below,
  so `runphase.sh` only calls two verbs and records their one-line result. One definition, no
  shell reimplementation of the checks.
- Seed root: `codex-seed/` as a sibling of the mount base (`dirname "$MOUNT_BASE_DIR"/codex-seed`),
  the way `profiles/` is a sibling of `mounts/`. It must be on the same volume as the homes
  (`st_dev` equal), a real directory, not a symlink, owned by the current uid, mode 700; the
  helper creates it 700 and refuses anything else. A `COMMS_MOUNT_BASE` override (tests, operators)
  moves the seed root with it, so a test never touches the live store.
- Canonical tree: `<root>/codex-<version>/` holding `plugins-cache/` (a copy of `plugins/cache`),
  `remote_plugin_catalog/` (a copy of `cache/remote_plugin_catalog`), and `MANIFEST`: a sorted
  line per entry (relative path, type, size, sha256 of content), a digest over those lines, the
  codex version and the creation epoch.
- Key = the codex runtime version, taken from the `runtime_version` row of the persisted policy
  record (`$acp_policy`, already hash-checked before use). It must match `^[0-9]+(\.[0-9]+)*$`.
  A `bundled` runtime reports `unknown`: no key, so no seed and no promotion (the turn runs as
  today). Plugin tree contents are not account-specific (no credentials; the markers carry only
  a plugin id), and codex reconciles any difference on its own, as the stale-seed row shows.

### Seeding a fresh home (before the turn)

Called from the codex arm of `runphase.sh` after `stage_method_guidance` and before the runtime
resolution, so `_iso_place`, `stage_method_guidance` and the five-key config are untouched, and
after the existing symlink and realpath checks of `$acp_iso_home`. Verb:
`codex_seed.py seed --root R --key K --home H`. In order, every step failing closed to "no seed":

1. **Fresh only.** Seed only when neither `H/plugins` nor `H/cache` exists (`lstat`, so a
   symlink counts as existing). A warm resumed home is never re-seeded: swapping a tree under a
   possibly live queue owner is unsafe, codex already syncs it incrementally, and the cost
   being removed is the first-turn cost. Result `skipped:warm`.
2. **Canonical usable.** `R/codex-<K>` exists, is a real directory, owner and mode as above,
   `MANIFEST` is a regular file, the creation epoch is at most 7 days old (constant in the helper;
   codex does not refresh an old catalog by itself), and same `st_dev` as `H`. Else `skipped:no-seed`
   / `skipped:stale`.
3. **Canonical intact.** Walk with `lstat` and no symlink following; refuse a symlink, a
   non-regular file, or a file with link count above 1; recompute the manifest and compare its
   digest to the recorded one (about 64 MB of sha256, measured in the implementation phase
   against a 0.5 s budget). Else `skipped:canonical-tampered` and the canonical is left in place.
4. **Clone.** `mkdir H/plugins` and `H/cache` (mode 700), then `clonefile(canonical/plugins-cache,
   H/plugins/cache, CLONE_NOFOLLOW)` and `clonefile(canonical/remote_plugin_catalog,
   H/cache/remote_plugin_catalog, CLONE_NOFOLLOW)`. `clonefile` on a directory is all or nothing
   for that tree. Any error (EXDEV, ENOTSUP, EEXIST, a missing symbol on a non-Darwin libc) is
   `skipped:clone-failed:<errno>`; there is no `cp`, `rsync`, `ditto` or `shutil` copy anywhere in
   the helper.
5. **Verify the clone.** Same walk on the home side: no symlink, no link count above 1, no inode in
   common with the canonical walk, and a manifest digest equal to the canonical's. On a failed
   verification remove exactly the paths this call created (`H/plugins`, `H/cache`) and proceed
   unseeded; if that removal fails, exit non-zero and `runphase.sh` refuses the turn (the
   same rule as a stale `auth.json` that cannot be cleared: a home whose contents are unexplained
   does not run).
6. A partial outcome (plugins cloned, catalog not) is valid and reported as such: the plugins tree
   is complete and verified, and codex fetches the catalog as before.

Exit codes: 0 for any outcome that leaves the home either seeded and verified or untouched (the
outcome is the printed status line), non-zero only for "could not restore the home to a known state".
The runner appends `codex_seed\t<status>\t<key>` to `turn.tsv` and a line to `runner.log`, the
pattern `stage_method_guidance` uses. `result.json` is unchanged.

### Refreshing the canonical tree (after the turn)

Verb `codex_seed.py promote --root R --key K --home H`, called once the post-turn attestation of a
codex mounted turn has passed, only when all of these hold: this turn's seed status was a skip
for a reason that means the canonical is missing, stale or tampered (never `skipped:warm`, never a
seeded home, so provenance is always a home codex itself populated and the staleness clock cannot
be reset by copying a copy); the codex version evidenced by the attested rollout's `cli_version`
equals the policy version `K`; and the home's two trees pass the same walk (non-empty plugins
tree, catalog present, no symlinks or multi-link files).

1. `clonefile` both home trees into `R/.tmp.<pid>.<random>/`, compute the manifest from the
   clone, write `MANIFEST`.
2. Publish by `rename(2)` onto `R/codex-<K>`. If a stale canonical exists, rename it aside to
   `R/.old.<pid>` first (atomic; one caller wins), publish, then delete the `.old` and the
   `.tmp` directories this call created. A caller that loses either rename discards its own tmp.
   A seeder racing the deletion either fails its clone or fails digest verification, and falls
   back to unseeded.
3. Prune `codex-*` directories for other versions only when older than 7 days, so two codex
   versions in use at once do not evict each other.
4. A failed promote never changes the turn's outcome (it is a cache); the status goes to
   `turn.tsv` and `runner.log`.

A codex upgrade therefore refreshes the canonical on its own: a new version is a new key, the first
turn on it runs unseeded (as today) and promotes. The age cap handles a long-lived version.

Known limit, accepted: the queue owner may still be writing into the home when the post-turn
promote clones it, so the snapshot is not atomic across files. The manifest is taken from the
clone, so the canonical is self-consistent for the digest, and a torn tree only costs extra
incremental sync in later homes (shown by the stale-seed row), not a different tool surface.

### Interface

```
codex_seed.py seed    --root DIR --key codex-X.Y.Z --home DIR  -> stdout: "seeded|partial|skipped:<why>" [+ detail]
codex_seed.py promote --root DIR --key codex-X.Y.Z --home DIR  -> stdout: "promoted|skipped:<why>"
```

## Error propagation and state on partial failure

- Any seed failure leaves the home as it would be today (empty of `plugins` and `cache`) and the
  turn proceeds. The one refusal is a failed cleanup of a clone that failed verification.
- Promote failures leave the previous canonical, or none. Temp directories carry the creator's
  pid and are the only thing the helper deletes besides the canonical it replaces.
- Siblings: gemini (`.gemini/`), grok (`GROK_HOME`) and claude (no home) have no equivalent
  tree, and their staging is unchanged. A later provider with a large cache adds a verb call, not
  a second copy of the checks. `install.sh` must install `helpers/codex_seed.py` (as it does for
  `agy_stream.py`), with its install test updated in the same commit.

## Invariants it must not break

- No symlink and no hard link in a seeded home, and none to the canonical: `clonefile` creates
  new inodes, and the helper verifies it on both sides (criterion 3). The existing realpath and
  symlink checks on `$acp_iso_home` (`runphase.sh` ~4170-4183) stay and run first.
- Fail closed to "unseeded", never to a byte copy (criterion 2).
- `auth.json`, `config.toml` and `AGENTS.md` staging, and the five-key config from `acp.sh`
  (`provider-config`), are not edited. Plugin sync is not disabled; no feature flag or
  `-c` override is added to the codex launch.
- The reviewer's sandbox, adapter pin, mode and attestation are not touched. The canonical
  directory is readable by the child like everything else in the store, and a read-only sandbox
  still refuses writes into it; the plugin trees are content codex itself wrote.
- No setting is added: the version key, the 7-day cap and the root location are fixed in the
  helper and the runner, so a project file cannot choose the content staged into a reviewer's home.

## What it deliberately will not do

- Change, shrink or delete existing homes (d4 and task 394 own that), or re-seed a warm home.
- Disable plugin sync or plugins, or prune the 11 connector plugins.
- Add its own fix for the per-session catalog rewrite. The canary did not reproduce it. If the
  live measurement shows codex rewriting the seeded catalog during a real turn, that file is
  unshared copy-on-write, which costs what today costs for it, and the result is reported.
- Seed from the operator's `~/.codex` (it holds other plugins, which would change the tool
  surface) or from a bundled runtime of unknown version.
- Use `cp -c`, `cp -R`, `rsync`, `ditto`, symlinks or hard links as a seed method.

## Showing it work (criteria 1, 6)

Entrypoint: a mounted codex review turn through `helpers/runphase.sh`, run with `COMMS_MOUNT_BASE`
and `XDG_STATE_HOME` pointed at a scratch directory under `$TMPDIR`, so the live mount store and
`~/.local/state/agent-comms` are untouched. The fixture is a trivial review request on a scratch
repo, at the lowest effort the policy map allows; access needed is the operator's existing
`~/.codex/auth.json` that the runner already copies into an isolated home, plus network. Ready =
the turn's `result.json` reports a published reply.

1. Baseline on main (33c4d15): one fresh-ident turn; record entries, apparent bytes and physical
   bytes of the home, plus wall time.
2. This branch, canonical absent: first turn runs unseeded and promotes (`turn.tsv` shows
   `skipped:no-seed`, then `promoted`).
3. This branch, second fresh ident: `seeded`; record the same numbers, the manifest diff before and
   after the turn (which files changed), and the `plugin/list` installed-set comparison with an
   unseeded home.
4. Physical bytes are measured as the change in volume used (`df -k` on the data volume around the
   turn, repeated, with a no-op control for the noise floor), because `du` counts clones twice.
   Expected: entries and apparent bytes about the same (762 plugin entries, ~63 MB), physical
   growth down by about the clone size; if the numbers disagree, the report says so.

## Tests (pinned as deltas against the contract at the commit under test)

New assertions in `tests/groups/isolation.sh` or a new group, with `tests/expected-counts.tsv`
and `tests/section-counts.tsv` updated by `+N` in the same commit. Darwin/APFS-dependent
assertions are named `skip_ok` tickets, never uncounted notes. Cases: clone shares no inode and
leaves zero symlinks or multi-link files; missing canonical, wrong version, stale epoch, planted
symlink, tampered file (digest) and warm home each produce the unseeded result; a forced clone
error (module-level `_clonefile` replaced in an in-process test, since the production path takes no
environment override) never produces a copied file; promote refuses a seeded home and a
version mismatch, and publishes atomically with a racing second promote; the runner leaves
`_iso_place`, the five-key config text and `stage_method_guidance` byte-identical (source checks in
the style of the existing isolation assertions) and does not add any plugin-disabling key.
Docs: `docs/INTERNALS.md` (mechanism and rationale), `docs/ROADMAP.md` (canary table and the
`cp -c` fallback finding), `docs/PROTOCOL.md` only if it lists the home's contents. Focused runs
only: `bash tests/run.sh --group isolation` plus any group touched; integrate runs the suite.
