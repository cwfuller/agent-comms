# agent-comms settings loader — SOURCED (never executed) by every entry helper, so a setting
# works in any shell that runs them: interactive terminals, agent tool shells that skip the
# shell rc, cron, CI. Precedence, highest first:
#
#   1. the process environment          (an explicit `KEY=v cmd` or export always wins)
#   2. <main repo>/.comms/settings      (per-project overrides; gitignored with .comms/)
#   3. ${AGENT_COMMS_HOME:-~/.agent-comms}/settings   (per-user defaults, written by `comms.sh setup`)
#   4. ${AGENT_COMMS_HOME:-~/.agent-comms}/secrets    (TYPESAFE_API_KEY only; must be mode 0600)
#
# Files are `KEY=value` lines, `#` comments. They are PARSED, never sourced or evaluated: a value
# like `$(rm -rf ~)` is a literal string. Only keys in AC_SETTINGS_KEYS / AC_SECRET_KEYS are
# honoured; anything else is reported and ignored, so a typo cannot silently set an unrelated
# variable. A value is applied only when the variable is UNSET, so re-sourcing is idempotent.

AC_SETTINGS_KEYS=" COMMS_REVIEW_ROUTE COMMS_ROUTE COMMS_ROUTE_BACKEND COMMS_ROUTE_MODEL COMMS_ROUTE_TIMEOUT_SECS COMMS_ACP_CODEX_PATH COMMS_ACP_CODEX_MODEL COMMS_ACP_CODEX_EFFORT COMMS_ACP_CANARY_SECS COMMS_ACP_RUNTIME_PROBE_SECS COMMS_RUNPHASE_TIMEOUT_SECS COMMS_RUNPHASE_ALLOW_UNCONTAINED ACPX_BIN "
AC_SECRET_KEYS=" TYPESAFE_API_KEY "
# A PROJECT file may only tune depth and time. It is repository content, not operator consent
# (a cloned repo can track one), so nothing that executes a binary, lifts containment, or turns
# ON sending text to TypeSafe is honoured from it: ACPX_BIN, COMMS_ACP_CODEX_PATH,
# COMMS_RUNPHASE_ALLOW_UNCONTAINED, COMMS_ROUTE_BACKEND and COMMS_ROUTE_MODEL are user-only, and
# COMMS_ROUTE only as `0` (a project may opt OUT of classification, never in).
AC_PROJECT_KEYS=" COMMS_REVIEW_ROUTE COMMS_ROUTE COMMS_ROUTE_TIMEOUT_SECS COMMS_ACP_CODEX_MODEL COMMS_ACP_CODEX_EFFORT COMMS_ACP_CANARY_SECS COMMS_ACP_RUNTIME_PROBE_SECS COMMS_RUNPHASE_TIMEOUT_SECS "

ac_home() { printf '%s' "${AGENT_COMMS_HOME:-$HOME/.agent-comms}"; }

# ac_file_mode <file> — octal permission bits (e.g. 600), or empty. GNU form FIRST: on Linux
# `stat -f FMT` is a filesystem query that takes FMT as another FILENAME, exits non-zero AND
# prints a statfs dump, so a BSD-first `a || b` captures garbage (the install.sh stat_mode lesson).
# Each probe's output is kept only when it succeeded and is purely octal.
ac_file_mode() {
  local v
  if v="$(stat -c '%a' "$1" 2>/dev/null)"; then case "$v" in ''|*[!0-7]*) ;; *) printf '%s' "$v"; return 0 ;; esac; fi
  if v="$(stat -f '%Lp' "$1" 2>/dev/null)"; then case "$v" in ''|*[!0-7]*) ;; *) printf '%s' "$v"; return 0 ;; esac; fi
  return 1
}

# ac_settings_apply <file> <allowed-keys> [secret|project] — apply one file under the rules above.
# Every applied key is recorded in AC_SETTINGS_FROM ("KEY<TAB>file<TAB>value" lines) so `setup --show` can
# tell a file value from an environment override.
ac_settings_apply() {
  local f="$1" allowed="$2" kind="${3:-}" line k v mode n=0
  [ -f "$f" ] && [ -r "$f" ] || return 0
  if [ "$kind" = secret ]; then
    # A secret readable by anyone else is refused, not trusted: the key would already be exposed.
    mode="$(ac_file_mode "$f")"
    case "$mode" in
      600|400) ;;
      *) echo "agent-comms: ignoring $f (mode ${mode:-unknown}; must be 600) — run: chmod 600 '$f'" >&2; return 0 ;;
    esac
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    case "$line" in ''|'#'*|[[:space:]]'#'*) continue ;; esac
    case "$line" in *=*) ;; *) echo "agent-comms: $f:$n: not KEY=value — ignored" >&2; continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
    case "$k" in ''|*[!A-Z0-9_]*|[0-9]*) echo "agent-comms: $f:$n: invalid key — ignored" >&2; continue ;; esac
    case "$allowed" in *" $k "*) ;; *)
      case "$kind$AC_SETTINGS_KEYS" in
        project*" $k "*) echo "agent-comms: $f:$n: '$k' is honoured only in $(ac_home)/settings, not a project file — ignored" >&2 ;;
        *) echo "agent-comms: $f:$n: unknown setting '$k' — ignored" >&2 ;;
      esac
      continue ;; esac
    case "$v" in *[[:cntrl:]]*) echo "agent-comms: $f:$n: control character in '$k' — ignored" >&2; continue ;; esac
    # Optional matching quotes around the whole value are removed; nothing inside is interpreted.
    case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
    if [ "$kind" = project ] && [ "$k" = COMMS_ROUTE ] && [ "$v" != 0 ]; then
      echo "agent-comms: $f:$n: a project may only set COMMS_ROUTE=0 — ignored" >&2; continue
    fi
    # $k is proven [A-Z0-9_]+ and allowlisted, so the eval below sees only a variable NAME.
    if eval "[ -z \"\${$k+x}\" ]"; then
      export "$k=$v"
      AC_SETTINGS_FROM="${AC_SETTINGS_FROM:-}$k"$'\t'"$f"$'\t'"$v"$'\n'
    fi
  done < "$f"
}

# ac_project_root — the MAIN repository root (shared by every worktree and review mount), or empty.
ac_project_root() {
  local out root
  out="$(env -u GIT_DIR -u GIT_WORK_TREE git worktree list --porcelain 2>/dev/null)" || return 0
  root="$(printf '%s\n' "$out" | sed -n '1s/^worktree //p')"
  [ -n "$root" ] && printf '%s' "$root"
}

ac_settings_load() {
  local root
  root="$(ac_project_root)"
  [ -n "$root" ] && ac_settings_apply "$root/.comms/settings" "$AC_PROJECT_KEYS" project
  ac_settings_apply "$(ac_home)/settings" "$AC_SETTINGS_KEYS"
  ac_settings_apply "$(ac_home)/secrets" "$AC_SECRET_KEYS" secret
  return 0
}

# Once per process TREE: the values are exported, so a child helper already has them, and a
# second pass would only repeat any warning (comms.sh -> runphase.sh -> acp.sh).
if [ -z "${AC_SETTINGS_LOADED:-}" ]; then
  ac_settings_load
  export AC_SETTINGS_LOADED=1 AC_SETTINGS_FROM="${AC_SETTINGS_FROM:-}"
fi
