# helpers/worktree.sh — the session-worktree verbs: `new`, `list`, `retire`.
#
# SOURCED by comms.sh (never executed on its own), so it shares main_repo_root, the presence
# readers and the error helpers instead of re-deriving them. Runs under comms.sh's
# `set -euo pipefail`.
#
# Design: docs/ROADMAP.md "session-lifecycle retirement" (2026-09-03) plus the basis retire
# gates. `list` only reports. `retire` is HAND-RUN: one target per invocation, re-enumerated
# from git at invocation time, dry-run unless --yes. Nothing calls it automatically —
# `integrate` retires nothing.
#
# Every unknown is fail-closed: a probe that cannot answer prints `?` in `list` and is a
# refusal in `retire`. An empty field must never read as a clean result.

# Ignored content a build or install recreates, matched against the BASENAME of each
# collapsed ignored entry (`git ls-files --directory`). Everything else that is ignored blocks
# retire: a worktree once held ~$22 of paid eval results in an ignored folder that existed
# nowhere else. Content INSIDE a listed directory is not inspected, except for nested repos.
# Directory names match only a DIRECTORY entry (`dist/`): an ignored FILE named `dist` is not
# a build tree. (grok, impl r1.) WT_REGENERABLE_FILES are the file-shaped entries.
WT_REGENERABLE="node_modules .next .nuxt .svelte-kit .turbo .parcel-cache .cache dist build out target coverage .nyc_output __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .venv venv .gradle"
WT_REGENERABLE_FILES=".DS_Store"

wt_is_regenerable() {  # <collapsed ignored entry, `dir/` for a directory>
  local n base="${1%/}"; base="${base##*/}"
  case "$1" in
    */) for n in $WT_REGENERABLE; do [ "$base" = "$n" ] && return 0; done ;;
    *)  for n in $WT_REGENERABLE_FILES; do [ "$base" = "$n" ] && return 0; done ;;
  esac
  return 1
}

wt_is_secret() {  # <basename> — checked BEFORE the regenerable list, so a secret is named as one
  case "$1" in
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.kdbx|*.secret) return 0 ;;
    id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*) return 0 ;;
    .npmrc|.pypirc|.netrc|.git-credentials|credentials|credentials.*|secrets|secrets.*) return 0 ;;
  esac
  return 1
}

# Symbolic refs under refs/heads that name <branch> as their target: deleting it would leave them
# dangling — fatal when one of them is the default branch (`main -> master`). (codex, impl r7.)
wt_symref_holders() {  # <root> <branch> -> space-separated names, or `?` when refs cannot be listed
  local out err
  err="$(mktemp)" || { printf '?'; return 0; }
  out="$(git -C "$1" for-each-ref --format='%(refname) %(symref)' refs/heads 2>"$err")" || { rm -f "$err"; printf '?'; return 0; }
  [ -s "$err" ] && { rm -f "$err"; printf '?'; return 0; }
  rm -f "$err"
  awk -v t="refs/heads/$2" '$2 == t {printf "%s ", $1}' <<<"$out"
}

wt_default_branch() {  # <root> -> main|master, the local default branch; non-zero when neither
  # Falls back to master only when main is PROVABLY absent. An unreadable main would otherwise
  # silently move the landing gate to master. (codex, impl r5.)
  local b
  for b in main master; do
    case "$(wt_branch_state "$1" "$b")" in
      present) printf '%s' "$b"; return 0 ;;
      absent) ;;
      *) return 1 ;;
    esac
  done
  return 1
}

wt_branch_state() {  # <root> <branch> -> present | absent | unknown
  local root="$1" ref="refs/heads/$2" rc common packed
  git -C "$root" rev-parse --verify -q "$ref^{commit}" >/dev/null 2>&1 && { printf present; return 0; }
  # `show-ref --exists` (git 2.43+) separates absent (2) from unreadable (other). Older git
  # rejects the option (129): decide from the ref store instead. (codex, impl r6.)
  git -C "$root" show-ref --exists "$ref" >/dev/null 2>&1 && rc=0 || rc=$?
  case "$rc" in
    0) printf unknown; return 0 ;;          # exists, yet did not resolve to a commit
    2) printf absent; return 0 ;;
    129) ;;
    *) printf unknown; return 0 ;;
  esac
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { printf unknown; return 0; }
  [ "$(wt_probe "$common/reftable")" = absent ] || { printf unknown; return 0; }
  [ "$(wt_probe "$common/$ref")" = absent ] || { printf unknown; return 0; }
  packed="$common/packed-refs"
  case "$(wt_probe "$packed")" in
    absent) printf absent ;;
    present)
      # Exact field match (a ref name may hold regex characters); awk's own failure is unknown.
      awk -v r="$ref" '$2 == r {f = 1} END {exit f ? 3 : 0}' "$packed" 2>/dev/null && rc=0 || rc=$?
      if [ "$rc" = 0 ]; then printf absent; else printf unknown; fi ;;
    *) printf unknown ;;
  esac
}

# present | absent | unknown. `absent` is concluded only when the entry is missing AND its parent
# could be searched (recursively: under an absent parent it is absent too). A symlink whose target
# cannot be reached, or a directory that cannot be searched, is `unknown` — never absent.
# The ONE existence test every metadata gate uses. (codex, impl r4/r5.)
wt_probe() {  # <path>
  [ -e "$1" ] && { printf present; return 0; }
  [ -L "$1" ] && { printf unknown; return 0; }
  local parent="${1%/*}"
  [ -n "$parent" ] || parent=/
  [ "$parent" != "$1" ] || { printf unknown; return 0; }
  if [ -d "$parent" ]; then
    [ -x "$parent" ] && printf absent || printf unknown
    return 0
  fi
  case "$(wt_probe "$parent")" in
    unknown) printf unknown ;;
    *) printf absent ;;          # parent absent, or present but not a directory
  esac
}

wt_owner_file() { printf '%s/.comms/worktrees/%s.owner' "$1" "$2"; }  # <root> <slug>

wt_phys() { (cd "$1" 2>/dev/null && pwd -P); }  # <dir> -> physical path, empty if unreachable

wt_show_path() {  # a path that cannot break the one-line output
  case "$1" in *[[:cntrl:]]*) printf '%q' "$1" ;; *) printf '%s' "$1" ;; esac
}

# ---------- enumeration ----------
# Parallel arrays, rebuilt from `git worktree list --porcelain -z` on every invocation; there
# is no cached list to go stale. Returns non-zero when git cannot enumerate.
WT_PATH=(); WT_HEAD=(); WT_BRANCH=(); WT_LOCK=(); WT_PRUNABLE=()
wt_enumerate() {  # <root>
  WT_PATH=(); WT_HEAD=(); WT_BRANCH=(); WT_LOCK=(); WT_PRUNABLE=()
  local raw f i=-1
  raw="$(mktemp)" || return 1
  if ! git -C "$1" worktree list --porcelain -z >"$raw" 2>/dev/null; then rm -f "$raw"; return 1; fi
  while IFS= read -r -d '' f; do
    case "$f" in
      "worktree "*) i=$((i + 1)); WT_PATH[i]="${f#worktree }"; WT_HEAD[i]=""; WT_BRANCH[i]=""; WT_LOCK[i]=""; WT_PRUNABLE[i]="" ;;
      "HEAD "*)     WT_HEAD[i]="${f#HEAD }" ;;
      "branch refs/heads/"*) WT_BRANCH[i]="${f#branch refs/heads/}" ;;
      locked)       WT_LOCK[i]="(no reason given)" ;;
      "locked "*)   WT_LOCK[i]="${f#locked }" ;;
      prunable|"prunable "*) WT_PRUNABLE[i]=1 ;;
    esac
  done <"$raw"
  rm -f "$raw"
  [ "$i" -ge 0 ]
}

# ---------- classification ----------
# kind: primary | managed | subagent | mount | unmanaged. `managed` is MECHANICAL: branch
# `worktree-<slug>` AND registered at <root>/.claude/worktrees/<slug> AND no symlink in the
# .claude/worktrees/<slug> components AND the physical path agrees. `subagent` is the same
# shape with an `agent-<hex>` slug (the Claude Code subagent isolation worktrees). A mount is
# identified by the external store's layout (<base>/<64-hex repo-key>/<ident>/view/tree), not by
# its base path, so no second copy of runphase's base default lives here.
WT_KIND=""; WT_SLUG=""
wt_classify() {  # <root> <root-phys> <index>
  local root="$1" rphys="$2" i="$3" path branch slug
  path="${WT_PATH[i]}"; branch="${WT_BRANCH[i]}"
  WT_KIND=unmanaged; WT_SLUG=""
  [ "$i" = 0 ] && { WT_KIND=primary; return 0; }
  if printf '%s' "$path" | grep -qE '/[0-9a-f]{64}/[^/]+/view/tree$'; then WT_KIND=mount; return 0; fi
  case "$branch" in worktree-*) slug="${branch#worktree-}" ;; *) return 0 ;; esac
  case "$slug" in *[![:lower:][:digit:]._-]*|""|.*) return 0 ;; esac   # classes, not ranges: locale-safe
  [ "$path" = "$root/.claude/worktrees/$slug" ] || return 0
  [ -L "$root/.claude" ] || [ -L "$root/.claude/worktrees" ] || [ -L "$path" ] && return 0
  [ "$(wt_phys "$path")" = "$rphys/.claude/worktrees/$slug" ] || return 0
  WT_SLUG="$slug"
  if printf '%s' "$slug" | grep -qE '^agent-[0-9a-f]{6,}$'; then WT_KIND=subagent; else WT_KIND=managed; fi
}

# ---------- on main ----------
# ancestor: the tip is reachable from main (the ONLY state retire accepts).
# cherry:   every commit on the branch has a patch-equivalent on main (`git cherry`).
# squash:   the branch's whole diff matches one commit on main (a squash merge).
# cherry and squash are signals for a human, never permission: equivalence of patches is not
# proof the landed commit is the reviewed one.
wt_on_main() {  # <root> <main> <tip> -> ancestor|cherry|squash|no|?
  # No `grep -q` at the end of a pipe: under pipefail its early exit SIGPIPEs the writer and
  # turns a match into a failure. Capture first, then match against the variable.
  local root="$1" main="$2" tip="$3" mb cherry want ids
  [ -n "$tip" ] || { printf '?'; return 0; }
  if git -C "$root" merge-base --is-ancestor "$tip" "refs/heads/$main" 2>/dev/null; then printf ancestor; return 0; fi
  cherry="$(git -C "$root" cherry "refs/heads/$main" "$tip" 2>/dev/null)" || { printf '?'; return 0; }
  if [ -n "$cherry" ] && ! grep -q '^+' <<<"$cherry"; then printf cherry; return 0; fi
  mb="$(git -C "$root" merge-base "refs/heads/$main" "$tip" 2>/dev/null)" || { printf no; return 0; }
  want="$(git -C "$root" diff "$mb" "$tip" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}')" || want=""
  ids="$(git -C "$root" log -p --format='commit %H' "$mb..refs/heads/$main" 2>/dev/null \
      | git patch-id --stable 2>/dev/null | awk '{print $1}')" || ids=""
  if [ -n "$want" ] && grep -qxF "$want" <<<"$ids"; then printf squash; return 0; fi
  printf no
}

# ---------- content ----------
# Sets WT_TRACKED / WT_UNTRACKED (counts), WT_IGN_UNKNOWN / WT_SECRETS / WT_NESTED (newline
# lists) and WT_CONTENT_OK (0 when any probe failed — every field is then unknown).
WT_TRACKED=0; WT_UNTRACKED=0; WT_IGN_UNKNOWN=""; WT_SECRETS=""; WT_NESTED=""; WT_PRIVREFS=""; WT_CONTENT_OK=1
wt_content() {  # <worktree path> <main branch>
  local p="$1" st ign e base
  WT_TRACKED=0; WT_UNTRACKED=0; WT_IGN_UNKNOWN=""; WT_SECRETS=""; WT_NESTED=""; WT_PRIVREFS=""; WT_CONTENT_OK=1
  st="$(git -C "$p" status --porcelain=v1 --untracked-files=normal --ignore-submodules=none 2>/dev/null)" \
    || { WT_CONTENT_OK=0; return 0; }
  WT_UNTRACKED="$(printf '%s\n' "$st" | grep -c '^??' || true)"
  WT_TRACKED="$(printf '%s\n' "$st" | grep -v '^??' | grep -c . || true)"
  # `git status` is blind to edits under skip-worktree (`S`) and assume-unchanged (lowercase
  # tag) paths, and `git worktree remove` deletes them anyway. Compare those paths' bytes to
  # HEAD directly; an absent sparse path has no bytes to lose. (grok, impl r1.)
  local hidden
  hidden="$(wt_hidden_edits "$p")" || { WT_CONTENT_OK=0; return 0; }
  WT_TRACKED=$((WT_TRACKED + hidden))
  ign="$(git -C "$p" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)" \
    || { WT_CONTENT_OK=0; return 0; }
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    base="${e%/}"; base="${base##*/}"
    if wt_is_secret "$base"; then WT_SECRETS="$WT_SECRETS$e"$'\n'
    elif ! wt_is_regenerable "$e"; then WT_IGN_UNKNOWN="$WT_IGN_UNKNOWN$e"$'\n'
    fi
  done <<<"$ign"
  # A nested repository anywhere, regenerable directories included: its history exists
  # nowhere else. find does not follow symlinks, so a node_modules linked into the primary
  # checkout is not walked. A find error (an unreadable directory) is unknown, not clean.
  # A BARE repository has no `.git`: recognise it by HEAD beside objects/ and refs/. (grok, impl r1.)
  # NUL-delimited end to end: a newline in a directory name split one path into fragments
  # that no sibling check matched. (codex, impl r2.) Listed paths are shown with %q.
  local raw h d
  raw="$(mktemp)" || { WT_CONTENT_OK=0; return 0; }
  if ! find "$p" -mindepth 2 \( -name .git -o \( -name HEAD -type f \) \) -print0 >"$raw" 2>/dev/null; then
    rm -f "$raw"; WT_CONTENT_OK=0; return 0
  fi
  while IFS= read -r -d '' h; do
    case "$h" in
      */.git) WT_NESTED="$WT_NESTED$(wt_show_path "$h")"$'\n' ;;
      */.git/HEAD) ;;
      *) d="${h%/HEAD}"
         # Not `[ -d ]`: a sibling that cannot be stat'd is unknown and counts. (grok, impl r6.)
         [ "$(wt_probe "$d/objects")" != absent ] && [ "$(wt_probe "$d/refs")" != absent ] \
           && WT_NESTED="$WT_NESTED$(wt_show_path "$d")"$'\n' ;;
    esac
  done <"$raw"
  rm -f "$raw"
  # Per-worktree refs live in the private git dir that removal deletes; one can be the only
  # name for unlanded history. (codex, impl r3.) The HEAD reflog is deleted too — a documented
  # residual: it holds every amended-away commit, so gating on it would block every tree.
  # for-each-ref OMITS a ref it cannot read (warning, exit 0), so an empty listing is not proof:
  # any stderr is unknown, and every loose per-worktree ref must itself be readable. (codex, r7.)
  local refs oid ref err gd d f
  err="$(mktemp)" || { WT_CONTENT_OK=0; return 0; }
  refs="$(git -C "$p" for-each-ref --format='%(objectname) %(refname)' refs/worktree refs/bisect refs/rewritten 2>"$err")" \
    || { rm -f "$err"; WT_CONTENT_OK=0; return 0; }
  if [ -s "$err" ]; then rm -f "$err"; WT_CONTENT_OK=0; return 0; fi
  rm -f "$err"
  gd="$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null)" || { WT_CONTENT_OK=0; return 0; }
  for d in refs/worktree refs/bisect refs/rewritten; do
    case "$(wt_probe "$gd/$d")" in absent) continue ;; unknown) WT_CONTENT_OK=0; return 0 ;; esac
    raw="$(mktemp)" || { WT_CONTENT_OK=0; return 0; }
    find "$gd/$d" -print0 >"$raw" 2>/dev/null || { rm -f "$raw"; WT_CONTENT_OK=0; return 0; }
    while IFS= read -r -d '' f; do
      if [ -d "$f" ]; then { [ -r "$f" ] && [ -x "$f" ]; } || { rm -f "$raw"; WT_CONTENT_OK=0; return 0; }
      else [ -r "$f" ] || { rm -f "$raw"; WT_CONTENT_OK=0; return 0; }
      fi
    done <"$raw"
    rm -f "$raw"
  done
  while read -r oid ref; do
    [ -n "$oid" ] || continue
    git -C "$p" merge-base --is-ancestor "$oid" "refs/heads/$2" 2>/dev/null || WT_PRIVREFS="$WT_PRIVREFS$ref"$'\n'
  done <<<"$refs"
  return 0
}

# Compares RAW bytes (`--no-filters`: a clean filter can make different content hash equal),
# the exact link text for a symlink, and the tracked MODE (type and executable bit). A benign
# difference — autocrlf, a clean filter — is a false refusal, which is the safe direction.
# (codex + grok, impl r2.)
wt_hidden_edits() {  # <worktree> -> count of flagged paths that differ from HEAD; non-zero on a probe failure
  local p="$1" raw rec tag path n=0 entry mode want have t f
  raw="$(mktemp)" || return 1
  git -C "$p" ls-files -v -z >"$raw" 2>/dev/null || { rm -f "$raw"; return 1; }
  while IFS= read -r -d '' rec; do
    tag="${rec%% *}"; path="${rec#* }"
    # [[:lower:]], never [a-z]: under en_US collation a range also matches uppercase (H).
    case "$tag" in S|[[:lower:]]) ;; *) continue ;; esac
    f="$p/$path"
    if [ ! -L "$f" ]; then
      case "$(wt_probe "$f")" in
        absent) continue ;;                          # an absent sparse path holds no bytes
        unknown) n=$((n + 1)); continue ;;
      esac
    fi
    # --literal-pathspecs: `:a` is otherwise pathspec magic for `a`, and the edited `:a` would
    # be compared against a different file. (codex, impl r3.)
    entry="$(git --literal-pathspecs -C "$p" ls-tree -z HEAD -- "$path" 2>/dev/null | tr '\0' '\n' | head -1)" || entry=""
    mode="${entry%% *}"; want="${entry#* * }"; want="${want%%$'\t'*}"
    [ -n "$entry" ] || { n=$((n + 1)); continue; }   # not in HEAD at all: new content
    if [ -L "$f" ]; then
      [ "$mode" = 120000 ] || { n=$((n + 1)); continue; }
      t="$(readlink -- "$f"; printf .)" || { rm -f "$raw"; return 1; }
      t="${t%.}"; t="${t%$'\n'}"                      # strip exactly readlink's own newline
      have="$(printf '%s' "$t" | git -C "$p" hash-object --no-filters --stdin 2>/dev/null)" || { rm -f "$raw"; return 1; }
    elif [ -f "$f" ]; then
      case "$mode" in
        100755) [ -x "$f" ] || { n=$((n + 1)); continue; } ;;
        100644) [ ! -x "$f" ] || { n=$((n + 1)); continue; } ;;
        *) n=$((n + 1)); continue ;;
      esac
      have="$(git -C "$p" hash-object --no-filters -- "$path" 2>/dev/null)" || { rm -f "$raw"; return 1; }
    else
      n=$((n + 1)); continue                         # a directory (or gitlink) where HEAD has a file
    fi
    [ "$have" = "$want" ] || n=$((n + 1))
  done <"$raw"
  rm -f "$raw"
  printf '%s' "$n"
}

wt_count() {  # <newline list> -> its length, or ?/- when the content was not (or could not be) read
  case "$WT_CONTENT_OK" in 1) ;; 0) printf '?'; return 0 ;; *) printf -- -; return 0 ;; esac
  [ -n "$1" ] && printf '%s' "$1" | grep -c . || printf 0
}

# ---------- processes ----------
# One system-wide lsof snapshot per invocation: `pid<TAB>path` for every cwd and open file the
# caller may see. WT_PROCS_OK=0 when lsof is missing or fails — then every worktree's process
# state is unknown, and retire refuses.
WT_PROCS_FILE=""; WT_PROCS_OK=0
wt_proc_snapshot() {
  WT_PROCS_OK=0
  WT_PROCS_FILE="$(mktemp)" || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  local raw; raw="$(mktemp)" || return 0
  if lsof -n -P -w -Fpn >"$raw" 2>/dev/null && [ -s "$raw" ]; then
    awk '/^p/ {pid = substr($0, 2)} /^n/ {print pid "\t" substr($0, 2)}' "$raw" >"$WT_PROCS_FILE" && WT_PROCS_OK=1
  fi
  rm -f "$raw"
}

wt_procs_in() {  # <physical path> -> space-separated pids with a cwd or open file at or under it
  awk -F'\t' -v p="$1" 'substr($2, 1, length(p)) == p && (length($2) == length(p) || substr($2, length(p) + 1, 1) == "/") && !seen[$1]++ {printf "%s ", $1}' "$WT_PROCS_FILE"
}

# ---------- presence ----------
# A worktree is associated with a presence record by its owner stamp (written by `worktree new`
# when the creating session exported COMMS_PRESENCE_NAME/INSTANCE) or by a record whose name
# equals the slug. Association can only ADD refusals. A dead record never blocks; a live or
# ambiguous one does unless it is the caller's own session.
WT_PRESENCE=""   # none | self | live:<name>-<inst8> | ambig:<name>-<inst8> | ?
wt_presence() {  # <root> <slug>
  local root="$1" slug="$2" dir of oname="" oinst="" f n inst v self_seen=0
  WT_PRESENCE=none
  [ -n "$slug" ] || { WT_PRESENCE=-; return 0; }
  of="$(wt_owner_file "$root" "$slug")"
  # A directory that exists but cannot be searched hides its files from `[ -f ]`: that is
  # unknown, not absent. (codex, impl r4.)
  local d
  for d in "$root/.comms" "$root/.comms/worktrees"; do
    if [ -e "$d" ] && ! { [ -r "$d" ] && [ -x "$d" ]; }; then WT_PRESENCE='?'; return 0; fi
  done
  case "$(wt_probe "$of")" in
    present) read -r oname oinst <"$of" 2>/dev/null || { WT_PRESENCE='?'; return 0; } ;;
    absent) ;;
    *) WT_PRESENCE='?'; return 0 ;;
  esac
  # presence_dir re-resolves the root; a failed resolution yields `/.comms/sessions`, which
  # must not read as "no sessions". (grok, impl r5.)
  dir="$(presence_dir)" || dir=""
  [ "$dir" = "$root/.comms/sessions" ] || { WT_PRESENCE='?'; return 0; }
  case "$(wt_probe "$dir")" in absent) return 0 ;; unknown) WT_PRESENCE='?'; return 0 ;; esac
  { [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ]; } || { WT_PRESENCE='?'; return 0; }
  # Association is decided from the FILENAME (`<name>-<instance>.json`) before any parse, so a
  # record that became unreadable or malformed is still associated — and presence_eval then
  # reads it as ambiguous, which blocks. Parsing first let an unreadable owner vanish.
  # (codex, impl r1.) The parsed name is a second, additive association.
  local b rest
  for f in "$dir"/*.json; do
    [ "$(wt_probe "$f")" = absent ] && continue      # the unmatched glob; unknown is kept
    b="$(basename "$f" .json)"; n=""; inst=""
    if [ -n "$oname" ] && [ "$b" = "$oname-$oinst" ]; then n="$oname"; inst="$oinst"
    else
      case "$b" in "$slug"-*) rest="${b#"$slug"-}" ;; *) rest="" ;; esac
      if [ -n "$rest" ] && printf '%s' "$rest" | grep -qE '^[a-z0-9]{8,64}$'; then n="$slug"; inst="$rest"
      elif [ "$(presence_field "$f" name)" = "$slug" ]; then n="$slug"; inst="$(presence_field "$f" instance)"
      else continue
      fi
    fi
    v="$(presence_eval "$f")" || v=ambig             # e.g. a heartbeat bash reads as bad octal
    [ "$v" = dead ] && continue
    if [ "$n" = "${COMMS_PRESENCE_NAME:-}" ] && [ "$inst" = "${COMMS_PRESENCE_INSTANCE:-}" ]; then self_seen=1; continue; fi
    WT_PRESENCE="$v:$n-$(printf '%.8s' "$inst")"; return 0
  done
  [ "$self_seen" = 1 ] && WT_PRESENCE=self
  return 0
}

# ---------- assessment ----------
# The ONE gate evaluator: `list` prints its result, `retire` acts on it. WT_REASONS is a
# newline list of `<gate>: <detail>`; empty means retirable. Also sets WT_ON_MAIN, WT_PROCS.
WT_REASONS=""; WT_ON_MAIN=""; WT_PROCS=""
wt_reason() { WT_REASONS="$WT_REASONS$1"$'\n'; }
wt_assess() {  # <root> <root-phys> <main> <index> <caller cwd (physical)>
  local root="$1" rphys="$2" main="$3" i="$4" cwd="$5" path branch phys
  path="${WT_PATH[i]}"; branch="${WT_BRANCH[i]}"
  WT_REASONS=""; WT_PROCS=""
  wt_classify "$root" "$rphys" "$i"
  WT_ON_MAIN="$(wt_on_main "$root" "$main" "${WT_HEAD[i]}")"
  [ -n "$branch" ] || WT_ON_MAIN=-
  case "$WT_KIND" in
    primary)   wt_reason "kind: the primary checkout is never retired" ;;
    mount)     wt_reason "kind: a review mount — use 'comms.sh clean mounts'" ;;
    unmanaged) wt_reason "kind: not a managed worktree (branch worktree-<slug> at .claude/worktrees/<slug>, no symlinked component)" ;;
  esac
  [ -n "$branch" ] || wt_reason "branch: detached HEAD — retire takes a branch"
  [ "$branch" = "$main" ] && wt_reason "branch: $main is the default branch"
  if [ -n "$branch" ]; then
    local holders; holders="$(wt_symref_holders "$root" "$branch")"
    case "$holders" in '') ;; '?') wt_reason "branch: could not list symbolic refs" ;; *) wt_reason "branch: symbolic ref ${holders% } points at it" ;; esac
  fi
  case "$WT_ON_MAIN" in
    ancestor|-) ;;
    cherry|squash) wt_reason "landed: on $main only by $WT_ON_MAIN-equivalence — not proof; review and delete by hand" ;;
    no) wt_reason "landed: tip ${WT_HEAD[i]:0:12} is not on $main" ;;
    *)  wt_reason "landed: could not determine whether the tip is on $main" ;;
  esac
  [ -n "${WT_LOCK[i]}" ] && wt_reason "lock: locked by its owner (${WT_LOCK[i]})"
  # In the shared evaluator so `list` and `retire` agree. (codex + grok, impl r3.)
  local busy
  if [ -n "$branch" ]; then
    busy="$(wt_operation_holder "$root" "$branch")"
    [ -z "$busy" ] || wt_reason "branch: held by $busy"
  fi
  WT_TRACKED='?'; WT_UNTRACKED='?'; WT_IGN_UNKNOWN=""; WT_SECRETS=""; WT_NESTED=""; WT_PRIVREFS=""; WT_CONTENT_OK=0
  if [ -n "${WT_PRUNABLE[i]}" ] || [ ! -d "$path" ]; then
    # Prune advice only when the path is truly gone: git also reports a tree it cannot READ as
    # prunable, and pruning that would discard a live worktree's registration.
    if [ "$(wt_probe "$path")" = absent ]; then
      wt_reason "missing: the directory is gone — 'git worktree prune' first"
    else
      wt_reason "unreadable: git cannot read this worktree — fix its permissions; do not prune it"
    fi
    WT_PROCS='?'; WT_PRESENCE='?'
    return 0
  fi
  # The primary checkout contains every in-checkout worktree, so its content and process
  # probes would describe them, not it. Never retired, so never inspected.
  [ "$WT_KIND" = primary ] && { WT_TRACKED=-; WT_UNTRACKED=-; WT_CONTENT_OK=-; WT_PROCS=-; WT_PRESENCE=-; return 0; }
  # Unguarded, a directory that exists but cannot be entered aborted the whole `list` under
  # set -e and made `retire` exit 1 instead of refusing. It is an unknown row. (codex, impl r4.)
  phys="$(wt_phys "$path")" || phys=""
  if [ -z "$phys" ]; then
    wt_reason "unreadable: cannot enter the directory"
    WT_PROCS='?'; WT_PRESENCE='?'
    return 0
  fi
  case "$cwd/" in "$phys"/*) wt_reason "cwd: you are standing in it — run retire from elsewhere" ;; esac
  wt_content "$path" "$main"
  if [ "$WT_CONTENT_OK" = 1 ]; then
    [ "$WT_TRACKED" != 0 ] && wt_reason "dirty: $WT_TRACKED tracked change(s)"
    [ "$WT_UNTRACKED" != 0 ] && wt_reason "dirty: $WT_UNTRACKED untracked path(s)"
    [ -n "$WT_SECRETS" ] && wt_reason "secrets: $(printf '%s' "$WT_SECRETS" | head -3 | tr '\n' ' ')"
    [ -n "$WT_IGN_UNKNOWN" ] && wt_reason "ignored: not on the regenerable list: $(printf '%s' "$WT_IGN_UNKNOWN" | head -3 | tr '\n' ' ')"
    [ -n "$WT_NESTED" ] && wt_reason "nested-git: $(printf '%s' "$WT_NESTED" | head -3 | tr '\n' ' ')"
    [ -n "$WT_PRIVREFS" ] && wt_reason "private-ref: not on $main: $(printf '%s' "$WT_PRIVREFS" | head -3 | tr '\n' ' ')"
  else
    WT_TRACKED='?'; WT_UNTRACKED='?'
    wt_reason "content: could not inspect the tree (git status, ignored listing or nested-repo scan failed)"
  fi
  if [ "$WT_PROCS_OK" = 1 ]; then
    WT_PROCS="$(wt_procs_in "$phys")" || WT_PROCS='?'
    if [ "$WT_PROCS" = '?' ]; then wt_reason "processes: could not read the process snapshot"
    elif [ -n "$WT_PROCS" ]; then wt_reason "processes: pid ${WT_PROCS% } has a cwd or open file inside"
    fi
  else
    WT_PROCS='?'
    wt_reason "processes: could not list processes (lsof missing or failed)"
  fi
  wt_presence "$root" "$WT_SLUG"
  case "$WT_PRESENCE" in
    none|self|-) ;;
    '?') wt_reason "presence: the sessions dir or owner stamp is unreadable" ;;
    *)   wt_reason "presence: $WT_PRESENCE" ;;
  esac
  return 0
}

wt_line() {  # <index> — the one-line report shared by list and retire
  local i="$1" nprocs verdict
  case "$WT_PROCS" in '?'|-) nprocs="$WT_PROCS" ;; *) nprocs="$(printf '%s' "$WT_PROCS" | wc -w | tr -d ' ')" ;; esac
  if [ "$WT_KIND" = primary ]; then verdict=never
  elif [ -z "$WT_REASONS" ]; then verdict=ok
  else verdict="blocked:$(printf '%s' "$WT_REASONS" | sed 's/:.*//' | awk '!s[$0]++' | paste -sd, -)"
  fi
  printf 'worktree-list v1 kind=%s branch=%s on_main=%s tracked=%s untracked=%s ignored_unknown=%s secrets=%s nested_git=%s procs=%s presence=%s locked=%s retire=%s path=%s\n' \
    "$WT_KIND" "${WT_BRANCH[i]:--}" "$WT_ON_MAIN" "$WT_TRACKED" "$WT_UNTRACKED" \
    "$(wt_count "$WT_IGN_UNKNOWN")" "$(wt_count "$WT_SECRETS")" "$(wt_count "$WT_NESTED")" \
    "$nprocs" "$WT_PRESENCE" "$( [ -n "${WT_LOCK[i]}" ] && printf yes || printf no)" "$verdict" \
    "$(wt_show_path "${WT_PATH[i]}")"
}

# ---------- verbs ----------
wt_context() {  # sets WT_ROOT, WT_RPHYS, WT_MAIN, WT_CWD; cd's to the root so this process
  # never holds a cwd inside a linked worktree it is inspecting.
  WT_CWD="$(pwd -P 2>/dev/null || true)"
  WT_ROOT="$(main_repo_root)"; [ -n "$WT_ROOT" ] || die "worktree: cannot resolve the main repo root"
  WT_RPHYS="$(wt_phys "$WT_ROOT")"; [ -n "$WT_RPHYS" ] || die "worktree: cannot resolve $WT_ROOT"
  WT_MAIN="$(wt_default_branch "$WT_ROOT")" || die "worktree: cannot determine the default branch (main unreadable, or neither main nor master exists)"
  cd "$WT_ROOT" || die "worktree: cannot cd to $WT_ROOT"
}

wt_list() {
  [ $# -eq 0 ] || usage_err "worktree list: takes no arguments"
  wt_context
  wt_enumerate "$WT_ROOT" || die "worktree list: git cannot enumerate worktrees"
  wt_proc_snapshot
  local i
  for i in "${!WT_PATH[@]}"; do
    wt_assess "$WT_ROOT" "$WT_RPHYS" "$WT_MAIN" "$i" "$WT_CWD"
    wt_line "$i"
  done
  rm -f "$WT_PROCS_FILE"
}

# The worktree or rebase/bisect state holding <branch> mid-operation, empty when none.
# Operations that own a branch while `git worktree list` shows no checkout of it (rebase,
# bisect, `rebase --update-refs` reservations), or that keep unrecoverable state in the git
# dir of the worktree on it (am, cherry-pick, revert, merge, the sequencer). State that exists
# but cannot be READ counts as held: a denied directory is not an absent one. (codex, grok r2.)
wt_operation_holder() {  # <root> <branch> [unenumerated]
  # With `unenumerated` (the branch-only path, where `git worktree list` showed no checkout), a
  # registration whose HEAD names the branch also holds it: git silently drops a registration it
  # cannot read from the listing. Any registration whose HEAD or gitdir file cannot be read holds
  # EVERY branch, since which one it has checked out is unknowable. (codex, impl r5.)
  local common gd f v ref="refs/heads/$2" head
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { printf 'an unreadable git dir'; return 0; }
  [ -r "$common" ] && [ -x "$common" ] || { printf 'an unreadable %s' "$common"; return 0; }
  case "$(wt_probe "$common/worktrees")" in
    present) [ -r "$common/worktrees" ] && [ -x "$common/worktrees" ] || { printf 'an unreadable %s' "$common/worktrees"; return 0; } ;;
    absent) ;;
    *) printf 'an unreadable %s' "$common/worktrees"; return 0 ;;
  esac
  for gd in "$common" "$common"/worktrees/*; do
    case "$(wt_probe "$gd")" in absent) continue ;; unknown) printf 'an unreadable %s' "$gd"; return 0 ;; esac
    [ -d "$gd" ] && [ -r "$gd" ] && [ -x "$gd" ] || { printf 'an unreadable %s' "$gd"; return 0; }
    if [ "$gd" != "$common" ]; then
      for f in HEAD gitdir; do
        [ "$(wt_probe "$gd/$f")" = present ] && [ -r "$gd/$f" ] || { printf 'an unreadable worktree registration (%s)' "$gd/$f"; return 0; }
      done
    fi
    if [ "${3:-}" = unenumerated ]; then
      head="$(cat "$gd/HEAD" 2>/dev/null)" || { printf 'an unreadable %s' "$gd/HEAD"; return 0; }
      [ "$head" = "ref: $ref" ] && { printf 'a checkout git did not list (%s)' "$gd"; return 0; }
    fi
    for f in rebase-merge rebase-apply sequencer; do
      case "$(wt_probe "$gd/$f")" in
        absent) continue ;;
        present) [ -r "$gd/$f" ] && [ -x "$gd/$f" ] && continue ;;
      esac
      printf 'an unreadable %s' "$gd/$f"; return 0
    done
    for f in rebase-merge/head-name rebase-apply/head-name; do
      case "$(wt_probe "$gd/$f")" in absent) continue ;; unknown) printf 'an unreadable %s' "$gd/$f"; return 0 ;; esac
      v="$(cat "$gd/$f" 2>/dev/null)" || { printf 'an unreadable %s' "$gd/$f"; return 0; }
      [ "$v" = "$ref" ] && { printf 'a rebase in progress (%s)' "$gd"; return 0; }
    done
    case "$(wt_probe "$gd/rebase-merge/update-refs")" in
      absent) ;;
      unknown) printf 'an unreadable %s' "$gd/rebase-merge/update-refs"; return 0 ;;
      present)
        v="$(cat "$gd/rebase-merge/update-refs" 2>/dev/null)" || { printf 'an unreadable %s' "$gd/rebase-merge/update-refs"; return 0; }
        grep -qxF "$ref" <<<"$v" && { printf 'a rebase --update-refs reservation (%s)' "$gd"; return 0; } ;;
    esac
    case "$(wt_probe "$gd/BISECT_START")" in
      absent) ;;
      unknown) printf 'an unreadable %s' "$gd/BISECT_START"; return 0 ;;
      present)
        v="$(cat "$gd/BISECT_START" 2>/dev/null)" || { printf 'an unreadable %s' "$gd/BISECT_START"; return 0; }
        { [ "$v" = "$2" ] || [ "$v" = "$ref" ]; } && { printf 'a bisect in progress (%s)' "$gd"; return 0; } ;;
    esac
    # am, cherry-pick, revert, merge, the sequencer and a paused notes merge (whose manual
    # resolutions live in NOTES_MERGE_WORKTREE) keep HEAD on the branch; their state is in this
    # git dir, which `git worktree remove` deletes. (grok r2; codex r3.)
    for f in rebase-apply CHERRY_PICK_HEAD REVERT_HEAD MERGE_HEAD sequencer NOTES_MERGE_PARTIAL NOTES_MERGE_REF NOTES_MERGE_WORKTREE; do
      case "$(wt_probe "$gd/$f")" in absent) continue ;; unknown) printf 'an unreadable %s' "$gd/$f"; return 0 ;; esac
      head="$(cat "$gd/HEAD" 2>/dev/null)" || { printf 'an unreadable %s' "$gd/HEAD"; return 0; }
      [ "$head" = "ref: $ref" ] && { printf 'an operation in progress (%s in %s)' "$f" "$gd"; return 0; }
    done
  done
  return 0
}

# Exit: 0 retired, or (dry run) retirable / 2 usage / 3 refused / 4 the branch moved after it
# was checked (left in place; the message says whether the worktree was removed) / 1 other
# failure (same report).
wt_retire() {
  local target="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1 ;;
      -*) usage_err "worktree retire: unknown flag '$(clip "$1")'" ;;
      *) [ -z "$target" ] || usage_err "worktree retire: one target at a time"; target="$1" ;;
    esac
    shift
  done
  [ -n "$target" ] || usage_err "worktree retire: expected <branch>"
  case "$target" in *[[:cntrl:]]*|refs/*) usage_err "worktree retire: expected a branch name, not '$(clip "$target")'" ;; esac
  git check-ref-format --branch "$target" >/dev/null 2>&1 || usage_err "worktree retire: invalid branch name '$(clip "$target")'"
  wt_context
  local tip i idx=-1 n=0 busy
  # A symbolic branch (`refs/heads/alias -> refs/heads/main`) would pass every gate as its
  # target and then take the target down with it on delete. Refused outright; the delete
  # below is also --no-deref, so a ref converted to a symref after this check fails the CAS
  # instead of following it. (codex, impl r1.)
  if git -C "$WT_ROOT" symbolic-ref -q "refs/heads/$target" >/dev/null 2>&1; then
    echo "worktree retire: REFUSED $target — a symbolic ref (points at $(git -C "$WT_ROOT" symbolic-ref -q "refs/heads/$target")); delete it by hand" >&2
    return 3
  fi
  tip="$(git -C "$WT_ROOT" rev-parse --verify -q "refs/heads/$target^{commit}" 2>/dev/null)" \
    || { echo "worktree retire: REFUSED $target — no such local branch (or it cannot be read)" >&2; return 3; }
  # Re-enumerate NOW: never act on an earlier listing. A retire that removed one worktree
  # changes the field, which is why there is no multi-target mode.
  wt_enumerate "$WT_ROOT" || die "worktree retire: git cannot enumerate worktrees"
  for i in "${!WT_PATH[@]}"; do
    [ "${WT_BRANCH[i]}" = "$target" ] && { idx="$i"; n=$((n + 1)); }
  done
  [ "$n" -le 1 ] || { echo "worktree retire: REFUSED $target — checked out in $n worktrees" >&2; return 3; }
  # A rebase or bisect detaches HEAD but still owns the branch it will restore or update, so
  # the porcelain shows no checkout for it. (codex, impl r1.) On the branch-only path an
  # unlisted registration naming the branch holds it too. (codex, impl r5.)
  local mode=""; [ "$idx" -lt 0 ] && mode=unenumerated
  busy="$(wt_operation_holder "$WT_ROOT" "$target" $mode)"

  if [ "$idx" -lt 0 ]; then
    # A branch with no worktree: only the ref is at stake.
    local on; on="$(wt_on_main "$WT_ROOT" "$WT_MAIN" "$tip")"
    WT_REASONS=""
    [ "$target" = "$WT_MAIN" ] && wt_reason "branch: $WT_MAIN is the default branch"
    local holders; holders="$(wt_symref_holders "$WT_ROOT" "$target")"
    case "$holders" in '') ;; '?') wt_reason "branch: could not list symbolic refs" ;; *) wt_reason "branch: symbolic ref ${holders% } points at it" ;; esac
    case "$on" in
      ancestor) ;;
      cherry|squash) wt_reason "landed: on $WT_MAIN only by $on-equivalence — not proof; review and delete by hand" ;;
      *) wt_reason "landed: tip ${tip:0:12} is not on $WT_MAIN" ;;
    esac
    [ -z "$busy" ] || wt_reason "branch: held by $busy"
    echo "worktree retire: $target at ${tip:0:12} (no worktree) on_main=$on"
  else
    wt_proc_snapshot
    wt_assess "$WT_ROOT" "$WT_RPHYS" "$WT_MAIN" "$idx" "$WT_CWD"
    rm -f "$WT_PROCS_FILE"
    [ "${WT_HEAD[idx]}" = "$tip" ] || wt_reason "landed: the branch moved while it was being inspected"
    wt_line "$idx"
  fi
  if [ -n "$WT_REASONS" ]; then
    printf '%s' "$WT_REASONS" | sed 's/^/  refused: /' >&2
    echo "worktree retire: REFUSED $target" >&2
    return 3
  fi
  if [ "$yes" != 1 ]; then
    if [ "$idx" -ge 0 ]; then
      echo "worktree retire: would remove $(wt_show_path "${WT_PATH[idx]}") and delete $target at ${tip:0:12} (dry run; --yes to act)"
    else
      echo "worktree retire: would delete $target at ${tip:0:12} (dry run; --yes to act)"
    fi
    return 0
  fi
  # Re-check the operation gate at the last moment: it is the one state a short-lived command
  # (a stopped cherry-pick) can create in the time the content and process probes take. It
  # narrows that window; nothing here can close it against a writer that ignores presence.
  busy="$(wt_operation_holder "$WT_ROOT" "$target" $mode)"
  [ -z "$busy" ] || { echo "  refused: branch: held by $busy" >&2; echo "worktree retire: REFUSED $target" >&2; return 3; }
  if [ "$idx" -ge 0 ]; then
    # Never --force: git itself then refuses a tree that became dirty or locked since the
    # assessment. It does NOT refuse ignored files, which is why they are gated above.
    git -C "$WT_ROOT" worktree remove "${WT_PATH[idx]}" \
      || { echo "worktree retire: git worktree remove refused — the branch is untouched" >&2; return 1; }
    echo "worktree retire: removed $(wt_show_path "${WT_PATH[idx]}")"
  fi
  # Compare-and-swap delete, never `git branch -d`: -d asks "merged into HEAD?", not "on
  # main?", and once the worktree is gone the branch is unlocked, so another process may have
  # advanced it. The old-value argument makes the delete refuse that.
  local removed=no cur err
  [ "$idx" -ge 0 ] && removed=yes
  if ! err="$(git -C "$WT_ROOT" update-ref --no-deref -d "refs/heads/$target" "$tip" 2>&1)"; then
    # Say what actually happened: only a ref that now holds something else "moved".
    cur="$(git -C "$WT_ROOT" rev-parse -q --verify "refs/heads/$target" 2>/dev/null || true)"
    if [ -n "$cur" ] && [ "$cur" != "$tip" ] || git -C "$WT_ROOT" symbolic-ref -q "refs/heads/$target" >/dev/null 2>&1; then
      echo "worktree retire: $target moved after ${tip:0:12} was checked — branch left in place (worktree removed: $removed)" >&2
      return 4
    fi
    echo "worktree retire: could not delete $target ($(clip "$err")) — branch left in place (worktree removed: $removed)" >&2
    return 1
  fi
  case "$target" in worktree-*) rm -f "$(wt_owner_file "$WT_ROOT" "${target#worktree-}")" 2>/dev/null || true ;; esac
  echo "worktree retire: deleted $target (was ${tip:0:12})"
  return 0
}

wt_new() {
  # worktree new [<slug>] — a session worktree under the MAIN root (never nested,
  # never cwd-relative: the two-resolver rule, third appearance — grok, plan r7),
  # branched from the LOCAL default-branch tip (origin can lag a full unpushed day).
  local slug="${1:-session-$$-$RANDOM}"
  # Whole-scalar check before grep, same rule as presence_validate_ids: grep
  # validates LINES, and the slug becomes a path and a branch name. Git happens
  # to refuse newline-bearing refs today, but the validator must not lean on it.
  # (codex, impl r8 advisory.)
  case "$slug" in *$'\n'*|*$'\r'*) usage_err "worktree new: invalid slug '$(clip "$slug")'" ;; esac
  printf '%s' "$slug" | grep -qE '^[a-z0-9][a-z0-9._-]{0,40}$' \
    || usage_err "worktree new: invalid slug '$(clip "$slug")'"
  local root main tip path branch of
  root="$(main_repo_root)"; [ -n "$root" ] || die "worktree new: cannot resolve the main repo root"
  main="$(wt_default_branch "$root")" || die "worktree new: no local main/master tip to branch from"
  tip="$(git -C "$root" rev-parse --verify "refs/heads/$main")"
  path="$root/.claude/worktrees/$slug"; branch="worktree-$slug"
  [ -e "$path" ] && die "worktree new: $path already exists"
  git -C "$root" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1 \
    && die "worktree new: branch $branch already exists"
  # The ignore coverage is load-bearing: an unignored in-checkout worktree walks a
  # full second repo copy into every review artifact. Verified, not assumed.
  mkdir -p "$root/.claude/worktrees" 2>/dev/null || true
  git -C "$root" check-ignore -q ".claude/worktrees/$slug" \
    || die "worktree new: .claude/worktrees/ is not ignore-covered — refusing (re-run install.sh or restore the .gitignore entry)"
  git -C "$root" worktree add -b "$branch" "$path" "$tip" >/dev/null 2>&1 \
    || die "worktree new: git worktree add failed"
  echo "worktree: $path"
  echo "branch:   $branch (from $(git -C "$root" rev-parse --short "$tip"))"
  # Owner stamp: ties this worktree to the creating session's presence record, so `retire`
  # refuses while that session is live. Best effort — a missing stamp only means retire falls
  # back to the name match, never that it permits more.
  if [ -n "${COMMS_PRESENCE_NAME:-}" ] && [ -n "${COMMS_PRESENCE_INSTANCE:-}" ] \
      && presence_validate_ids "$COMMS_PRESENCE_NAME" "$COMMS_PRESENCE_INSTANCE"; then
    of="$(wt_owner_file "$root" "$slug")"
    if mkdir -p "$(dirname "$of")" 2>/dev/null && printf '%s %s\n' "$COMMS_PRESENCE_NAME" "$COMMS_PRESENCE_INSTANCE" >"$of" 2>/dev/null; then
      echo "owner:    $COMMS_PRESENCE_NAME-$(printf '%.8s' "$COMMS_PRESENCE_INSTANCE")"
    fi
  fi
  return 0
}

cmd_worktree() {
  local sub="${1:-new}"; shift 2>/dev/null || true
  case "$sub" in
    new)    wt_new "$@" ;;
    list)   wt_list "$@" ;;
    retire) wt_retire "$@" ;;
    *) usage_err "worktree: expected new|list|retire" ;;
  esac
}
