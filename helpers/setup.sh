#!/bin/bash
# agent-comms setup — the interactive (and scriptable) configuration flow. Re-runnable: every
# question shows the CURRENT value as its default, so running it again only changes what you
# change. Reached as `comms.sh setup`; install.sh offers it when a terminal is present.
#
#   comms.sh setup                 interactive, one section at a time
#   comms.sh setup --yes           accept every default (detected / current) without asking
#   comms.sh setup --show          print the effective settings and where each came from
#   comms.sh setup --set K=V ...   write user settings directly (repeatable), no questions
#
# Writes:
#   ${AGENT_COMMS_HOME:-~/.agent-comms}/settings   user settings (KEY=value, read by helpers/settings.sh)
#   ${AGENT_COMMS_HOME:-~/.agent-comms}/secrets    TYPESAFE_API_KEY, mode 0600
#   <repo>/.comms/config                           agents + default-target for THIS project
#   ${AGENT_COMMS_HOME:-~/.agent-comms}/route-shadow-allow   project permit for Jev classification
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Settings as they are NOW, before this run changes anything — they are the defaults offered.
# shellcheck source=settings.sh
[ -f "$HERE/settings.sh" ] && . "$HERE/settings.sh"
HOME_DIR="${AGENT_COMMS_HOME:-$HOME/.agent-comms}"
SETTINGS="$HOME_DIR/settings"
SECRETS="$HOME_DIR/secrets"
ALLOW="${COMMS_ROUTE_SHADOW_ALLOW:-$HOME_DIR/route-shadow-allow}"
KNOWN_AGENTS="claude codex grok"

YES=0; SHOW=0; SETS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --show)   SHOW=1 ;;
    --set)    [ "$#" -ge 2 ] || { echo "setup: --set needs KEY=VALUE" >&2; exit 2; }; SETS+=("$2"); shift ;;
    -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "setup: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done

# ---- terminal I/O: prompts go to /dev/tty so piped installs still reach a human -------------
TTY=0
if [ "$YES" = 0 ] && [ "$SHOW" = 0 ] && [ "${#SETS[@]}" -eq 0 ] && { exec 3<>/dev/tty; } 2>/dev/null; then TTY=1; fi
say() { if [ "$TTY" = 1 ]; then printf '%s\n' "$*" >&3; else printf '%s\n' "$*"; fi; }
ask() {  # ask <prompt> <default> -> answer (default on Enter, or without a terminal)
  local a=""
  if [ "$TTY" = 1 ]; then printf '%s [%s]: ' "$1" "$2" >&3; IFS= read -r a <&3 || a=""; fi
  printf '%s' "${a:-$2}"
}
ask_yn() {  # ask_yn <prompt> <y|n> -> 0 yes / 1 no
  local a
  a="$(ask "$1 (y/n)" "$2")"
  case "$a" in y|Y|yes|YES|Yes|1|on|true) return 0 ;; *) return 1 ;; esac
}
ask_secret() {  # hidden input; empty keeps the current value
  local a=""
  [ "$TTY" = 1 ] || { printf ''; return; }
  printf '%s (Enter to keep current): ' "$1" >&3
  stty -echo <&3 2>/dev/null; IFS= read -r a <&3 || a=""; stty echo <&3 2>/dev/null; printf '\n' >&3
  printf '%s' "$a"
}
yn_of() { case "${1:-}" in 1|true|yes|on|TRUE|YES|ON) printf y ;; *) printf n ;; esac; }

# ---- settings file writer: rewrites only the keys given, keeps every other line --------------
# set_user <KEY> <value|"">   empty value removes the key.
PENDING=""
set_user() { PENDING="$PENDING$1=$2"$'\n'; }
flush_user() {
  [ -n "$PENDING" ] || return 0
  mkdir -p "$HOME_DIR" || { echo "setup: cannot create $HOME_DIR" >&2; return 1; }
  local tmp; tmp="$(mktemp "$HOME_DIR/.settings.XXXXXX")" || return 1
  PENDING="$PENDING" python3 - "$SETTINGS" "$tmp" <<'PY' || { rm -f "$tmp"; return 1; }
import os,sys
src,dst=sys.argv[1],sys.argv[2]
want={}
for l in os.environ["PENDING"].splitlines():
    if "=" in l:
        k,v=l.split("=",1); want[k]=v
lines=[]
try:
    lines=open(src).read().splitlines()
except OSError:
    lines=["# agent-comms user settings — written by `comms.sh setup`; env vars override these.",
           "# KEY=value, one per line. See docs/INSTALL.md \"Settings\"."]
out=[];seen=set()
for l in lines:
    k=l.split("=",1)[0].strip() if "=" in l and not l.lstrip().startswith("#") else None
    if k in want:
        if k not in seen and want[k]!="": out.append("%s=%s"%(k,want[k]))
        seen.add(k); continue
    out.append(l)
for k,v in want.items():
    if k not in seen and v!="": out.append("%s=%s"%(k,v))
open(dst,"w").write("\n".join(out)+"\n")
PY
  mv -f "$tmp" "$SETTINGS"
  PENDING=""
}
write_secret() {  # write_secret <value>
  mkdir -p "$HOME_DIR" || return 1
  local tmp; tmp="$(umask 077; mktemp "$HOME_DIR/.secrets.XXXXXX")" || return 1
  chmod 600 "$tmp"
  { grep -v '^TYPESAFE_API_KEY=' "$SECRETS" 2>/dev/null; printf 'TYPESAFE_API_KEY=%s\n' "$1"; } > "$tmp"
  mv -f "$tmp" "$SECRETS"
}

# ---- --set: scripted writes, no questions -----------------------------------------------------
if [ "${#SETS[@]}" -gt 0 ]; then
  for kv in "${SETS[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$kv" in *=*) ;; *) echo "setup: --set expects KEY=VALUE (got '$kv')" >&2; exit 2 ;; esac
    if [ "$k" = TYPESAFE_API_KEY ]; then write_secret "$v" || exit 1; continue; fi
    case "$AC_SETTINGS_KEYS" in *" $k "*) ;; *) echo "setup: unknown setting '$k' (known:$AC_SETTINGS_KEYS)" >&2; exit 2 ;; esac
    set_user "$k" "$v"
  done
  flush_user || exit 1
  echo "setup: wrote $SETTINGS"
  exit 0
fi

# ---- --show: effective values and their source ------------------------------------------------
source_of() {  # which layer supplies KEY
  local k="$1" root f
  root="$(ac_project_root)"
  for f in "$root/.comms/settings" "$SETTINGS" "$SECRETS"; do
    [ -f "$f" ] && grep -q "^[[:space:]]*$k=" "$f" 2>/dev/null && { printf '%s' "$f"; return; }
  done
  printf 'environment'
}
if [ "$SHOW" = 1 ]; then
  echo "agent-comms settings (env > project .comms/settings > $SETTINGS > $SECRETS)"
  for k in $AC_SETTINGS_KEYS $AC_SECRET_KEYS; do
    if eval "[ -n \"\${$k+x}\" ]"; then
      v="$(eval "printf '%s' \"\$$k\"")"
      [ "$k" = TYPESAFE_API_KEY ] && v="(set, ${#v} chars)"
      printf '  %-34s %-28s %s\n' "$k" "$v" "$(source_of "$k")"
    else
      printf '  %-34s %s\n' "$k" "(unset)"
    fi
  done
  exit 0
fi

# ---- 1. prerequisites -------------------------------------------------------------------------
say ""
say "agent-comms setup — Enter keeps the value in [brackets]. Re-run any time: comms.sh setup"
say ""
say "1/5 Prerequisites"
ok() { say "  ok    $*"; }; bad() { say "  MISSING  $*"; }
command -v git >/dev/null 2>&1 && ok "git" || bad "git (required)"
command -v python3 >/dev/null 2>&1 && ok "python3" || bad "python3 (routing, reply checks and setup need it)"
if "$HERE/acp.sh" supports codex >/dev/null 2>&1; then ok "node $(node --version 2>/dev/null) (ACP transport)"
else bad "node >= 22.13 (the ACP review transport needs it)"; fi

# ---- 2. agents --------------------------------------------------------------------------------
say ""
say "2/5 Agents"
DETECTED=""
for a in $KNOWN_AGENTS; do
  if command -v "$a" >/dev/null 2>&1; then
    DETECTED="$DETECTED $a"; ok "$a $("$a" --version 2>/dev/null | head -1)"
  else say "  -     $a not found on PATH"; fi
done
DETECTED="${DETECTED# }"
ROOT="$(ac_project_root)"
CFG=""
[ -n "$ROOT" ] && [ -d "$ROOT/.comms" ] && CFG="$ROOT/.comms/config"
if [ -n "$CFG" ]; then
  CUR_AGENTS="$(sed -n 's/^[[:space:]]*agents[[:space:]]*=[[:space:]]*//p' "$CFG" 2>/dev/null | head -1)"
  CUR_DEFAULT="$(sed -n 's/^[[:space:]]*default-target[[:space:]]*=[[:space:]]*//p' "$CFG" 2>/dev/null | head -1)"
  AGENTS="$(ask "  agents for this project ($ROOT)" "${CUR_AGENTS:-${DETECTED:-claude codex}}")"
  bad_agent=""
  for a in $AGENTS; do case " $KNOWN_AGENTS " in *" $a "*) ;; *) bad_agent="$a" ;; esac; done
  if [ -n "$bad_agent" ]; then
    say "  '$bad_agent' is not a supported agent ($KNOWN_AGENTS) — keeping: ${CUR_AGENTS:-unchanged}"
    AGENTS="$CUR_AGENTS"
  fi
  first="${AGENTS%% *}"; dflt_default="$CUR_DEFAULT"
  case " $AGENTS " in *" $dflt_default "*) ;; *) dflt_default="$( case " $AGENTS " in *" codex "*) echo codex ;; *) echo "$first" ;; esac )" ;; esac
  DEFAULT="$(ask "  default reviewer (for /ask and single-reviewer loops)" "$dflt_default")"
  case " $AGENTS " in *" $DEFAULT "*) ;; *) say "  '$DEFAULT' is not in the agent list — using $dflt_default"; DEFAULT="$dflt_default" ;; esac
  if [ -n "$AGENTS" ]; then
    tmp="$(mktemp "$ROOT/.comms/.config.XXXXXX")" && {
      { grep -vE '^[[:space:]]*(agents|default-target)[[:space:]]*=' "$CFG" 2>/dev/null
        printf 'agents = %s\ndefault-target = %s\n' "$AGENTS" "$DEFAULT"; } > "$tmp" && mv -f "$tmp" "$CFG"; }
  fi
else
  say "  (not inside an initialised project — run install.sh --scope=project there to register agents)"
  AGENTS="$DETECTED"
fi

# ---- 3. reviewer safety -----------------------------------------------------------------------
say ""
say "3/5 Reviewer containment"
say "  codex and claude reviewers run contained. grok has no verified sandbox, so a grok REVIEW"
say "  turn is refused unless you allow uncontained reviews — then it can write outside its"
say "  mount and reach the network with your git credentials. Fine for your own code on your"
say "  own machine; not for code you did not write."
cur_unc="$(yn_of "${COMMS_RUNPHASE_ALLOW_UNCONTAINED:-}")"
case " $AGENTS " in
  *" grok "*) if ask_yn "  allow uncontained (grok) reviews" "$cur_unc"; then set_user COMMS_RUNPHASE_ALLOW_UNCONTAINED 1; else set_user COMMS_RUNPHASE_ALLOW_UNCONTAINED ""; fi ;;
  *) say "  grok is not registered here — nothing to allow." ;;
esac

# ---- 4. Jev routing ---------------------------------------------------------------------------
say ""
say "4/5 Model routing (Jev, via TypeSafe) — optional"
say "  The classifier sizes work: whether a task needs an approach review, and how deeply each"
say "  Codex reviewer should think (cheap for trivial diffs, full depth otherwise). It sends task"
say "  and review-request text to TypeSafe."
if [ -n "${TYPESAFE_API_KEY:-}" ]; then say "  TypeSafe key: set ($(source_of TYPESAFE_API_KEY))"; else say "  TypeSafe key: not set"; fi
cur_route="$( [ "${COMMS_ROUTE_BACKEND:-}" = typesafe ] || [ "$(yn_of "${COMMS_ROUTE:-}")" = y ] && echo y || echo n )"
if ask_yn "  enable routing" "$cur_route"; then
  k="$(ask_secret "  TypeSafe API key")"
  [ -n "$k" ] && { write_secret "$k" && say "  key saved to $SECRETS (mode 600)"; }
  [ -n "$k" ] || [ -n "${TYPESAFE_API_KEY:-}" ] || say "  note: no key yet — routing stays at the default depth until one is set (comms.sh setup, or TYPESAFE_API_KEY)."
  set_user COMMS_ROUTE_BACKEND typesafe
  if ask_yn "  also route REVIEWER depth per thread" "$(yn_of "${COMMS_REVIEW_ROUTE:-1}")"; then set_user COMMS_REVIEW_ROUTE 1; else set_user COMMS_REVIEW_ROUTE ""; fi
  if [ -n "$ROOT" ] && command -v python3 >/dev/null 2>&1; then
    key="$(cd "$ROOT" && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import route_backend as b; print(b.canonical_project()[0])' "$HERE" 2>/dev/null)"
    if [ -n "$key" ]; then
      permitted=n; grep -qxF "$key" "$ALLOW" 2>/dev/null && permitted=y
      if ask_yn "  allow THIS project's review text to be sent for classification" "$permitted"; then
        [ "$permitted" = y ] || { mkdir -p "$(dirname "$ALLOW")" && printf '%s\n' "$key" >> "$ALLOW" && say "  permitted ($ROOT)"; }
      elif [ "$permitted" = y ]; then
        tmp="$(mktemp "$ALLOW.XXXXXX")" && grep -vxF "$key" "$ALLOW" > "$tmp"; mv -f "$tmp" "$ALLOW"; say "  permit removed"
      fi
    fi
  fi
else
  set_user COMMS_ROUTE_BACKEND ""; set_user COMMS_REVIEW_ROUTE ""
fi

# ---- 5. codex reviewer runtime + timeout ------------------------------------------------------
say ""
say "5/5 Codex reviewer runtime"
rt_auto="$(env -u COMMS_ACP_CODEX_PATH "$HERE/acp.sh" resolve codex 2>/dev/null | awk -F'\t' '$1=="runtime"{r=$2} $1=="runtime_version"{v=$2} END{print r" "v}')"
say "  auto-detected: ${rt_auto:-unknown}  (GPT-6 Sol/Luna need codex >= 0.155; older falls back to GPT-5.6)"
RT="$(ask "  runtime: auto | bundled | /path/to/codex" "${COMMS_ACP_CODEX_PATH:-auto}")"
case "$RT" in auto|"") set_user COMMS_ACP_CODEX_PATH "" ;; bundled) set_user COMMS_ACP_CODEX_PATH bundled ;;
  /*) if [ -x "$RT" ]; then set_user COMMS_ACP_CODEX_PATH "$RT"; else say "  '$RT' is not executable — keeping auto"; set_user COMMS_ACP_CODEX_PATH ""; fi ;;
  *) say "  unrecognised — keeping auto"; set_user COMMS_ACP_CODEX_PATH "" ;; esac
TO="$(ask "  review turn timeout, seconds" "${COMMS_RUNPHASE_TIMEOUT_SECS:-1800}")"
case "$TO" in ''|*[!0-9]*) say "  not a number — keeping ${COMMS_RUNPHASE_TIMEOUT_SECS:-1800}" ;;
  1800) set_user COMMS_RUNPHASE_TIMEOUT_SECS "" ;; *) set_user COMMS_RUNPHASE_TIMEOUT_SECS "$TO" ;; esac

flush_user || { echo "setup: could not write $SETTINGS" >&2; exit 1; }
say ""
say "Saved. Settings: $SETTINGS   (show them: comms.sh setup --show)"
say "Environment variables still override these for a single command, e.g. COMMS_ROUTE=0."
[ "$TTY" = 1 ] && exec 3>&-
exit 0
