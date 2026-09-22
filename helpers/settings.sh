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

ac_home() { printf '%s' "${AGENT_COMMS_HOME:-$HOME/.agent-comms}"; }

# ac_file_mode <file> — octal permission bits (e.g. 600), BSD or GNU stat.
ac_file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

# ac_settings_apply <file> <allowed-keys> [secret] — apply one file under the rules above.
ac_settings_apply() {
  local f="$1" allowed="$2" secret="${3:-}" line k v mode n=0
  [ -f "$f" ] && [ -r "$f" ] || return 0
  if [ -n "$secret" ]; then
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
    case "$allowed" in *" $k "*) ;; *) echo "agent-comms: $f:$n: unknown setting '$k' — ignored" >&2; continue ;; esac
    case "$v" in *[[:cntrl:]]*) echo "agent-comms: $f:$n: control character in '$k' — ignored" >&2; continue ;; esac
    # Optional matching quotes around the whole value are removed; nothing inside is interpreted.
    case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
    # $k is proven [A-Z0-9_]+ and allowlisted, so the eval below sees only a variable NAME.
    if eval "[ -z \"\${$k+x}\" ]"; then export "$k=$v"; fi
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
  [ -n "$root" ] && ac_settings_apply "$root/.comms/settings" "$AC_SETTINGS_KEYS"
  ac_settings_apply "$(ac_home)/settings" "$AC_SETTINGS_KEYS"
  ac_settings_apply "$(ac_home)/secrets" "$AC_SECRET_KEYS" secret
  return 0
}

# Once per process TREE: the values are exported, so a child helper already has them, and a
# second pass would only repeat any warning (comms.sh -> runphase.sh -> acp.sh).
if [ -z "${AC_SETTINGS_LOADED:-}" ]; then
  ac_settings_load
  export AC_SETTINGS_LOADED=1
fi
