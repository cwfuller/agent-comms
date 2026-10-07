#!/usr/bin/env bash
# box.sh — kernel containment for a reviewer whose tools run in ITS OWN process (grok).
#
#   box.sh supports <provider>                          which backend this host has for the provider
#   box.sh prepare  <provider> --dir D --home H --mount M [--bin P] [--cred-dir C]
#                                                       write the profile and launch shims, then PROVE them
#   box.sh client-check --dir D --flags F -- LAUNCHER   prove the ACP client refuses fs/terminal requests under F
#   box.sh launched --dir D                             did the shim launch the provider under THIS preparation
#
# WHY THIS EXISTS. codex ships its own kernel sandbox and claude/gemini (agy) a mode pin; grok ships neither
# that holds on macOS (its docs: child-network blocking is Linux-only, and every profile write-allows
# /tmp). So the containment is applied from outside, with the OS's own Seatbelt (`sandbox-exec`), around
# the ONE process that executes a grok reviewer's tools.
#
# THE PART THAT IS EASY TO MISS: acpx advertises ACP terminal and filesystem capabilities by default, and
# when it does, a grok shell command or file write is executed by the CLIENT — the unsandboxed acpx queue
# owner — not by grok. A Seatbelt around grok alone then contains nothing (measured 2026-10-03: the write
# landed and `ls ~` listed the real home). The caller therefore MUST launch acpx with `--no-terminal
# --no-fs`, which makes grok run its tools in-process, inside the profile. `prepare` prints that as the
# `acpx_flags` line so the flags are defined once, here, beside the profile that depends on them.
#
# WHAT IS ENFORCED (by the kernel, for grok and everything it spawns):
#   writes      only the isolated grok home and a per-mount scratch dir (which is also HOME and TMPDIR);
#               NOT the reviewed tree, NOT /tmp, NOT the repository, NOT the run directory.
#   reads       the real home directory and /tmp are unreadable except for the allow-backs the review needs
#               (the isolated home, scratch, the reviewed tree, its git object store, the grok install).
#               The operator's own credential stores — ~/.grok, ~/.ssh, ~/.config/gh, the keychain files,
#               a git credential file — are all under the denied home, and the grok login is denied BY ITS
#               PHYSICAL PATH too, so a GROK_HOME that points outside the home is closed the same way. This is a DENYLIST of a tree, not
#               an allowlist of the machine: a world-readable file outside the home is still readable.
#   keychain    the Security daemons are unreachable, so the git osxkeychain helper cannot answer.
#   processes   signals reach only the contained process itself and its children; process-info of other
#               processes is denied (no reading another process's environment); the launchd and
#               LaunchServices escape hatches (launchctl, open, osascript, sudo) cannot be executed or
#               looked up. These are the known routes out of Seatbelt, named, not an exhaustive proof.
#   sockets     outbound TCP is :443 only, UDP only :53; unix-domain sockets (the acpx owner control plane,
#               the keychain and launchd sockets) are unreachable.
#   environment the child gets an ALLOWLISTED environment, not the operator's: no GIT_*/GITHUB_*/AWS_*
#               tokens ride in.
# WHAT IS NOT: the network is open on :443 (Seatbelt cannot filter by host), so the staged grok login is
# readable and could be sent out; an API key placed in XAI_API_KEY is inherited by design. Both residuals
# are the same shape as codex's staged auth.json and are recorded in docs/ROADMAP.md.
#
# Every claim above is checked by `prepare` against the profile it just wrote, not asserted: it runs the
# real shim under the real profile and requires the positive probes to succeed AND the negative ones to
# fail. Exit codes: 0 ok, 1 no backend for this provider/OS, 3 a backend exists but a prerequisite or
# a probe failed (the reason is the last line on stderr), 2 usage.
set -uo pipefail

die()   { echo "box.sh: $*" >&2; exit 3; }
usage() { echo "usage: box.sh supports <provider> | prepare <provider> --dir D --home H --mount M [--bin P] [--cred-dir C] | client-check --dir D --flags F -- LAUNCHER... | launched --dir D" >&2; exit 2; }

BOX_SB=/usr/bin/sandbox-exec

# backend_for <provider> — the backend name this host has, or nothing. ONE table; supports and prepare
# both read it, so the foreground check and the runner cannot disagree.
backend_for() {
  case "$1:$(uname -s)" in
    grok:Darwin) echo grok-seatbelt ;;
  esac
}

# prereq <provider> — print the reason this host cannot use its backend, or nothing. Cheap and side-effect
# free: this is what `doctor` and the foreground refusal call.
prereq() {
  [ -x "$BOX_SB" ] || { echo "$BOX_SB is missing, so no kernel sandbox can be applied (it ships with macOS; a minimal or restricted install may have removed it)"; return; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 is missing, and the containment probes need it"; return; }
  case "$1" in
    grok) resolve_bin "" >/dev/null 2>&1 || echo "the grok CLI was not found on PATH (install it, or pass its path), so there is nothing to contain" ;;
  esac
}

# resolve_bin <explicit-or-empty> — the real executable, symlinks resolved, never one of our own shims.
resolve_bin() {
  local p="$1" real=""
  if [ -z "$p" ]; then
    local IFS=: d
    for d in $PATH; do
      [ -x "$d/grok" ] && [ ! -f "$d/.agent-comms-box" ] || continue
      p="$d/grok"; break
    done
  fi
  [ -n "$p" ] && [ -x "$p" ] || return 1
  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null)" || return 1
  [ -f "$real" ] && [ -x "$real" ] || return 1
  printf '%s' "$real"
}

# physdir <dir> — the physical path of an existing directory, or fail. Seatbelt matches physical paths:
# a /tmp or /var spelling would silently match nothing.
physdir() { ( cd "$1" 2>/dev/null && pwd -P ); }

# plain <path> — refuse anything that could break a profile or a shell word. Paths reach the profile only
# through -D parameters (never spliced into the profile text), and the shims quote with %q, so this is a
# second lock, not the only one.
plain() { case "$1" in /*) ;; *) return 1 ;; esac; case "$1" in *[[:cntrl:]]*|*\"*|*\\*|*\;*) return 1 ;; esac; }

profile_text() {
  cat <<'SBPL'
(version 1)
;; agent-comms reviewer containment. Parameters arrive as -D, never spliced into this text.
(allow default)

;; WRITES: nothing but the isolated provider home and the per-mount scratch dir.
(deny file-write*)
(allow file-write*
  (subpath (param "HOME_ISO"))
  (subpath (param "SCRATCH"))
  (literal "/dev/null") (literal "/dev/dtracehelper") (literal "/dev/tty")
  (regex #"^/dev/tty[a-z0-9]*$") (regex #"^/dev/fd/[0-9]+$"))

;; READS: the operator's home and the shared temp areas are closed, then exactly what a review needs is
;; opened back. Later rules win, and an allow must name the same operation as the deny it overrides.
(deny file-read-data
  (subpath (param "REAL_HOME"))
  (subpath (param "CRED_SRC"))
  (subpath "/private/tmp") (subpath "/private/var/tmp")
  (subpath "/Library/Keychains"))
(allow file-read-data
  (subpath (param "HOME_ISO"))
  (subpath (param "SCRATCH"))
  (subpath (param "MOUNT"))
  (subpath (param "GIT_COMMON"))
  (subpath (param "RUNTIME")))
;; The operator's login stays closed whatever was opened back above (the CLI may be installed beside it):
;; the original holds the refresh token, and the staged copy has none.
(deny file-read-data (literal (param "CRED_FILE")))

;; PROCESSES: signal only yourself and your children; read no other process's state.
(deny signal)
(allow signal (target self) (target children))
(deny process-info* (target others))

;; ESCAPES: the routes out of Seatbelt are launchd jobs, LaunchServices, AppleScript and the keychain.
(deny mach-lookup
  (global-name "com.apple.coreservices.launchservicesd")
  (global-name-prefix "com.apple.lsd")
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.secd")
  (global-name "com.apple.securityd"))
(deny process-exec
  (literal "/usr/bin/open") (literal "/bin/launchctl") (literal "/usr/bin/osascript") (literal "/usr/bin/sudo"))

;; NETWORK: HTTPS and DNS only; no unix-domain sockets except the resolver's.
(deny network-outbound)
(allow network-outbound
  (remote tcp "*:443")
  (remote udp "*:53")
  (literal "/private/var/run/mDNSResponder"))
SBPL
}

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# The environment the contained child gets: names, not values. Everything else is dropped.
ENV_ALLOW="PATH LANG LC_ALL LC_CTYPE TERM USER LOGNAME XAI_API_KEY HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR COMMS_REVIEW_TURN"

write_shims() {  # <dir> <home> <scratch> <mount> <git-common> <runtime> <real-bin> <profile> <cred-src> <cred-file> <generation>
  local dir="$1" home="$2" scratch="$3" mount="$4" gitc="$5" rt="$6" bin="$7" prof="$8" csrc="$9" cfile="${10}" gen="${11}" sha
  sha="$(sha_of "$prof")"
  {
    printf '#!/bin/bash\n# generated by box.sh — runs its arguments inside the reviewer profile\n'
    printf 'env_args=(HOME=%q TMPDIR=%q GROK_HOME=%q)\n' "$scratch" "$scratch" "$home"
    printf 'for n in %s; do [ -n "${!n+x}" ] && env_args+=("$n=${!n}"); done\n' "$ENV_ALLOW"
    printf 'exec /usr/bin/env -i "${env_args[@]}" %q -f %q \\\n' "$BOX_SB" "$prof"
    printf '  -D HOME_ISO=%q -D SCRATCH=%q -D REAL_HOME=%q -D MOUNT=%q -D GIT_COMMON=%q -D RUNTIME=%q -D CRED_SRC=%q -D CRED_FILE=%q "$@"\n' \
      "$home" "$scratch" "$REAL_HOME" "$mount" "$gitc" "$rt" "$csrc" "$cfile"
  } > "$dir/bin/box-run"
  {
    printf '#!/bin/bash\n# generated by box.sh — the provider launcher a reviewer gets; it always runs contained\n'
    printf 'printf "launch %%s pid=%%s sha=%%s gen=%%s\\n" "$(date +%%s)" "$$" %q %q >> %q\n' "$sha" "$gen" "$dir/launch.log"
    printf 'exec %q %q "$@"\n' "$dir/bin/box-run" "$bin"
  } > "$dir/bin/grok"
  : > "$dir/bin/.agent-comms-box"
  chmod 755 "$dir/bin/box-run" "$dir/bin/grok"
  printf '%s' "$sha"
}

# ---- the probes ---------------------------------------------------------------------------------------
# Each runs a command through the SAME box-run the reviewer's grok is launched with. A positive probe
# must succeed and a negative one must fail, and every negative one is also checked against the world
# (the file did not appear, the process still lives) because an exit status alone can lie.
PROBE_FAIL=""
bad() { PROBE_FAIL="${PROBE_FAIL:+$PROBE_FAIL; }$1"; }
run_in() { "$BOX_DIR/bin/box-run" "$@"; }

probes() {
  local tag="box-probe-$$-$RANDOM" f sock_py out pid port srv psock
  # positive: the places a review legitimately writes
  run_in /bin/sh -c ": > '$SCRATCH/$tag'" 2>/dev/null && [ -f "$SCRATCH/$tag" ] || bad "positive: the scratch dir is not writable"
  run_in /bin/sh -c ": > '$HOME_ISO/$tag'" 2>/dev/null && [ -f "$HOME_ISO/$tag" ] || bad "positive: the isolated provider home is not writable"
  rm -f "$SCRATCH/$tag" "$HOME_ISO/$tag"
  # positive: the places a review legitimately reads
  run_in /bin/ls "$MOUNT" >/dev/null 2>&1 || bad "positive: the reviewed tree is not readable"
  # negative: writes anywhere else, ground-truthed against the filesystem
  for f in "$MOUNT/$tag" "/private/tmp/$tag" "$BOX_DIR/$tag" "$GIT_COMMON/$tag"; do
    run_in /bin/sh -c ": > '$f'" 2>/dev/null
    if [ -e "$f" ]; then rm -f "$f"; bad "negative: a contained process WROTE $(basename "$(dirname "$f")")/…"; fi
  done
  # negative: the operator's home and its credential store are closed
  run_in /bin/ls "$REAL_HOME" >/dev/null 2>&1 && bad "negative: a contained process could list the real home directory"
  # (the login is wherever the runner will read it from — GROK_HOME may point outside the home — and the
  # default location is probed too, in case the two differ)
  for f in "$CRED_FILE" "$REAL_HOME/.grok/auth.json"; do
    [ -f "$f" ] || continue
    run_in /bin/cat "$f" >/dev/null 2>&1 && bad "negative: a contained process could READ the operator's grok login"
  done
  # negative: the environment is an allowlist, not the operator's
  out="$(COMMS_BOX_CANARY=leaked GITHUB_TOKEN=leaked AWS_SECRET_ACCESS_KEY=leaked run_in /usr/bin/env 2>/dev/null)"
  case "$out" in *leaked*) bad "negative: the operator's environment reached the contained process" ;; esac
  # negative: signals and process inspection
  # (the victim gets its OWN session: a sleeper in this script's process group would be a legitimate target)
  pid="$(python3 -c 'import subprocess as s; print(s.Popen(["/bin/sleep","60"], start_new_session=True, stdin=s.DEVNULL, stdout=s.DEVNULL, stderr=s.DEVNULL).pid)' 2>/dev/null)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then bad "probe setup: could not start the signal target"
  else
    run_in /bin/kill -TERM "$pid" >/dev/null 2>&1
    sleep 0.2
    kill -0 "$pid" 2>/dev/null || bad "negative: a contained process signalled a process outside its own tree"
    kill "$pid" 2>/dev/null
  fi
  # negative: the launchd route out
  run_in /bin/launchctl version >/dev/null 2>&1 && bad "negative: a contained process could run launchctl"
  # negative: sockets — a loopback TCP service and a unix-domain socket (the acpx owner's control plane is one)
  # A unix-domain socket path is capped near 104 bytes and a mount path is not, so the socket is made and
  # used by RELATIVE name from inside its own directory (which the box can read: the denial must come from
  # the network rule, not from the path being unreadable).
  sock_py='
import os, socket, sys, time
os.chdir(sys.argv[1])
t = socket.socket(); t.bind(("127.0.0.1", 0)); t.listen(4)
if os.path.exists("c.sock"): os.unlink("c.sock")
u = socket.socket(socket.AF_UNIX); u.bind("c.sock"); u.listen(4)
print(t.getsockname()[1], flush=True)
time.sleep(float(sys.argv[2]))
'
  psock="$SCRATCH/probe-sock"
  mkdir -p "$psock"
  srv="$psock/port"
  python3 -c "$sock_py" "$psock" 8 > "$srv" 2>/dev/null &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -s "$srv" ] && break; sleep 0.2; done
  port="$(cat "$srv" 2>/dev/null)"
  if [ -n "$port" ] && [ -S "$psock/c.sock" ]; then
    # the listeners are real: the same connects must work OUTSIDE the box, or the denial proves nothing
    python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2)' "$port" 2>/dev/null \
      || bad "probe setup: the loopback listener did not accept an uncontained connect"
    ( cd "$psock" && /usr/bin/nc -U -w 2 c.sock </dev/null >/dev/null 2>&1 ) \
      || bad "probe setup: the unix listener did not accept an uncontained connect"
    # SYSTEM binaries only inside the box: a python3 or nc that lives under the closed home would fail to
    # run at all, and that failure would read as a pass. The controls prove the tools themselves start.
    run_in /bin/bash -c 'exit 0' >/dev/null 2>&1 || bad "probe setup: /bin/bash does not start inside the box"
    out="$(run_in /usr/bin/nc -h 2>&1)"
    case "$out" in *[Uu]sage*) ;; *) bad "probe setup: /usr/bin/nc does not start inside the box" ;; esac
    run_in /bin/bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" >/dev/null 2>&1 \
      && bad "negative: a contained process reached a non-443 TCP service"
    ( cd "$psock" && run_in /usr/bin/nc -U -w 2 c.sock </dev/null >/dev/null 2>&1 ) \
      && bad "negative: a contained process reached a unix-domain socket"
  else
    bad "probe setup: could not start the loopback listeners"
  fi
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rm -rf "$psock"
}

# ---- the ACP client check ------------------------------------------------------------------------------
# A fake ACP agent, written beside the probe, that behaves as a hostile contained agent would: whatever
# the client advertised, it sends the filesystem and terminal requests anyway and records the answers.
# Run with the capabilities left ON it proves the agent can drive the client (the control); run with the
# flags it proves the client REFUSES instead of executing for it. Nothing here relies on grok.
client_agent_py() {
  cat <<'CAPY'
import json, sys
out, target, canary = sys.argv[1], sys.argv[2], sys.argv[3]
log = {}
nid = [100]
def send(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def call(method, params):
    nid[0] += 1; i = nid[0]
    send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
    while True:
        line = sys.stdin.readline()
        if not line: return {"error": "eof"}
        m = json.loads(line)
        if m.get("id") == i and "method" not in m: return m
for line in sys.stdin:
    m = json.loads(line)
    meth, id_ = m.get("method"), m.get("id")
    if meth == "initialize":
        log["caps"] = m["params"].get("clientCapabilities")
        send({"jsonrpc": "2.0", "id": id_, "result": {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}})
    elif meth == "session/new":
        send({"jsonrpc": "2.0", "id": id_, "result": {"sessionId": "s1"}})
    elif meth == "session/prompt":
        log["write"] = call("fs/write_text_file", {"sessionId": "s1", "path": target, "content": "written"})
        log["read"] = call("fs/read_text_file", {"sessionId": "s1", "path": canary})
        log["term"] = call("terminal/create", {"sessionId": "s1", "command": "/bin/sh", "args": ["-c", ": > '" + target + ".term'"]})
        tid = (log["term"].get("result") or {}).get("terminalId")
        if tid: call("terminal/wait_for_exit", {"sessionId": "s1", "terminalId": tid})
        open(out, "w").write(json.dumps(log))
        send({"jsonrpc": "2.0", "id": id_, "result": {"stopReason": "end_turn"}})
        sys.exit(0)
CAPY
}

# client_probe_run <result> <target> <flags...> — one run of the launcher against the fake agent. The
# client runs as the OWNER does: unsandboxed, approving every permission, so a refusal can only come from
# the capability being off and never from a prompt nobody answered.
client_probe_run() {
  local res="$1" target="$2"; shift 2
  ( cd "$CP_DIR" && "${CP_LAUNCH[@]}" "$@" --approve-all --format quiet --timeout 60 --cwd "$CP_DIR" \
      --agent "$CP_PY $CP_DIR/agent.py $res $target $CP_DIR/canary.txt" exec go </dev/null >/dev/null 2>"$CP_DIR/last.err" )
}

cmd_client_check() {
  local flags="" w ok_c=1 i
  BOX_DIR=""; CP_LAUNCH=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)   [ "$#" -ge 2 ] || usage; BOX_DIR="$2"; shift ;;
      --flags) [ "$#" -ge 2 ] || usage; flags="$2"; shift ;;
      --)      shift; CP_LAUNCH=("$@"); break ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$BOX_DIR" ] && [ -n "$flags" ] && [ "${#CP_LAUNCH[@]}" -gt 0 ] || usage
  [ -d "$BOX_DIR" ] && [ ! -L "$BOX_DIR" ] || die "the box dir ($BOX_DIR) does not exist or is a symlink"
  BOX_DIR="$(physdir "$BOX_DIR")" || die "the box dir does not resolve"
  CP_DIR="$BOX_DIR/client-probe"
  [ ! -L "$CP_DIR" ] || die "the client-probe dir is a symlink — refusing"
  rm -rf "$CP_DIR"; mkdir -p "$CP_DIR" || die "cannot create the client-probe dir"
  CP_PY="$(command -v python3)" || die "python3 is missing, and the client check needs it"
  case "$CP_DIR$CP_PY" in *[[:space:]]*) die "the client-probe paths contain whitespace, which the --agent command line cannot carry" ;; esac
  plain "$CP_DIR" && plain "$CP_PY" || die "a client-probe path contains a character the agent command cannot carry"
  client_agent_py > "$CP_DIR/agent.py"
  printf 'canary-content\n' > "$CP_DIR/canary.txt"
  # CONTROL: capabilities left on. The fake agent must be able to make the client do all three things, or
  # a refusal in the next run proves nothing (a broken agent, a changed protocol, a client that never ran).
  client_probe_run "$CP_DIR/control.json" "$CP_DIR/control-target" || true
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$CP_DIR/control-target.term" ] && break; sleep 0.2; done
  [ -s "$CP_DIR/control.json" ] || ok_c=0
  [ -f "$CP_DIR/control-target" ] && [ -e "$CP_DIR/control-target.term" ] || ok_c=0
  if [ "$ok_c" = 1 ] && ! grep -q 'canary-content' "$CP_DIR/control.json"; then ok_c=0; fi
  [ "$ok_c" = 1 ] || die "the ACP client check could not run: with its capabilities left on, the launcher '${CP_LAUNCH[*]}' did not execute the probe agent's filesystem and terminal requests ($(tr '\n' ' ' < "$CP_DIR/last.err" | cut -c1-160))"
  # THE CHECK: the same run under the flags. Every request must come back as an error and nothing may exist.
  # shellcheck disable=SC2086
  client_probe_run "$CP_DIR/enforced.json" "$CP_DIR/enforced-target" $flags || true
  sleep 0.5
  [ -s "$CP_DIR/enforced.json" ] || die "the ACP client check could not run: the launcher gave no answer to the probe agent under '$flags'"
  python3 - "$CP_DIR/enforced.json" <<'CPCHK' || die "the ACP client '${CP_LAUNCH[*]}' does not refuse filesystem or terminal requests under '$flags' — it would run a contained agent's commands outside the sandbox. Use acpx >= 0.17.1 (unset ACPX_BIN or point it at one)"
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if all(isinstance(d.get(k), dict) and "error" in d[k] and "result" not in d[k] for k in ("write", "read", "term")) else 1)
CPCHK
  [ ! -e "$CP_DIR/enforced-target" ] && [ ! -e "$CP_DIR/enforced-target.term" ] \
    || die "the ACP client '${CP_LAUNCH[*]}' created files for the probe agent under '$flags' — it would run a contained agent's commands outside the sandbox. Use acpx >= 0.17.1"
  ! grep -q 'canary-content' "$CP_DIR/enforced.json" || die "the ACP client '${CP_LAUNCH[*]}' read a file for the probe agent under '$flags'. Use acpx >= 0.17.1"
  rm -rf "$CP_DIR"
  printf 'client_check\tok\n'
}

cmd_supports() {
  local provider="${1:-}" b r
  [ -n "$provider" ] || usage
  b="$(backend_for "$provider")"
  if [ -z "$b" ]; then
    echo "box.sh: no kernel-sandbox backend is implemented for '$provider' on $(uname -s)" >&2
    exit 1
  fi
  r="$(prereq "$provider")"
  if [ -n "$r" ]; then echo "$r" >&2; exit 3; fi
  printf 'backend\t%s\n' "$b"
}

cmd_prepare() {
  local provider="${1:-}" bin="" real_bin="" sha="" b r gitc="" rt="" cred_dir="" gen=""
  [ -n "$provider" ] || usage
  shift
  BOX_DIR=""; HOME_ISO=""; MOUNT=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)   [ "$#" -ge 2 ] || usage; BOX_DIR="$2"; shift ;;
      --home)  [ "$#" -ge 2 ] || usage; HOME_ISO="$2"; shift ;;
      --mount) [ "$#" -ge 2 ] || usage; MOUNT="$2"; shift ;;
      --bin)   [ "$#" -ge 2 ] || usage; bin="$2"; shift ;;
      --cred-dir) [ "$#" -ge 2 ] || usage; cred_dir="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$BOX_DIR" ] && [ -n "$HOME_ISO" ] && [ -n "$MOUNT" ] || usage
  b="$(backend_for "$provider")"
  [ -n "$b" ] || { echo "box.sh: no kernel-sandbox backend is implemented for '$provider' on $(uname -s)" >&2; exit 1; }
  r="$(prereq "$provider")"
  [ -z "$r" ] || die "$r"
  [ -n "${HOME:-}" ] || die "HOME is unset, so the home directory to close cannot be named"
  REAL_HOME="$(physdir "$HOME")" || die "HOME ($HOME) is not a directory"
  # A symlinked box dir would steer the profile and the shims out of the place the caller chose.
  [ ! -L "$BOX_DIR" ] || die "the box dir ($BOX_DIR) is a symlink — refusing to follow it"
  mkdir -p "$BOX_DIR/bin" "$BOX_DIR/scratch" || die "cannot create the box dir ($BOX_DIR)"
  BOX_DIR="$(physdir "$BOX_DIR")" || die "the box dir does not resolve"
  [ ! -L "$BOX_DIR/bin" ] && [ ! -L "$BOX_DIR/scratch" ] || die "a box subdirectory is a symlink — refusing"
  SCRATCH="$BOX_DIR/scratch"
  # The scratch dir is the one place the reviewer could leave things for a LATER round; start each from empty.
  find "$SCRATCH" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
  HOME_ISO="$(physdir "$HOME_ISO")" || die "the isolated provider home does not exist"
  MOUNT="$(physdir "$MOUNT")" || die "the reviewed tree does not exist"
  GIT_COMMON="$BOX_DIR/no-git-store"
  gitc="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$MOUNT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || gitc=""
  if [ -n "$gitc" ] && [ -d "$gitc" ]; then GIT_COMMON="$(physdir "$gitc")"; fi
  real_bin="$(resolve_bin "$bin")" || die "the $provider CLI was not found${bin:+ at $bin}"
  rt="$(dirname "$real_bin")"
  # THE OPERATOR'S LOGIN, by physical path: wherever the runner stages it from (GROK_HOME, else ~/.grok).
  # A store outside the home is not covered by the home-wide deny, so it is named here and probed below.
  [ -n "$cred_dir" ] || cred_dir="${GROK_HOME:-$HOME/.grok}"
  CRED_SRC="$BOX_DIR/no-cred-store"; CRED_FILE="$BOX_DIR/no-cred-file"
  if [ -d "$cred_dir" ]; then
    CRED_SRC="$(physdir "$cred_dir")" || die "the grok credential directory ($cred_dir) does not resolve"
    if [ -e "$cred_dir/auth.json" ] || [ -L "$cred_dir/auth.json" ]; then
      # A symlinked login is read through its target, so the target is what gets denied.
      CRED_FILE="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$cred_dir/auth.json" 2>/dev/null)"         || die "the grok login ($cred_dir/auth.json) does not resolve"
    else
      CRED_FILE="$CRED_SRC/auth.json"
    fi
  fi
  local p
  for p in "$BOX_DIR" "$HOME_ISO" "$SCRATCH" "$MOUNT" "$GIT_COMMON" "$rt" "$REAL_HOME" "$real_bin" "$CRED_SRC" "$CRED_FILE"; do
    plain "$p" || die "a path contains a character the profile will not carry ($p)"
  done
  case "$HOME_ISO" in "$REAL_HOME"/.grok|"$REAL_HOME"/.grok/*) die "the isolated provider home is inside the operator's real ~/.grok — it would be the credential store itself" ;; esac
  case "$HOME_ISO/" in "$CRED_SRC"/*) die "the isolated provider home is inside the operator's grok credential store ($CRED_SRC) — it would be the credential store itself" ;; esac
  case "$SCRATCH/" in "$CRED_SRC"/*) die "the scratch dir is inside the operator's grok credential store ($CRED_SRC)" ;; esac
  case "$MOUNT/" in "$CRED_SRC"/*) die "the reviewed tree is inside the operator's grok credential store ($CRED_SRC)" ;; esac
  profile_text > "$BOX_DIR/box.sb.tmp" && mv -f "$BOX_DIR/box.sb.tmp" "$BOX_DIR/box.sb" || die "cannot write the profile"
  # LAUNCH EVIDENCE BELONGS TO ONE PREPARATION. The directory is durable across rounds and the profile text
  # is identical every time (paths arrive as -D), so a hash alone cannot tell this round's launch from last
  # round's. Each preparation starts an empty log and a fresh generation, and `launched` wants both.
  gen="$(python3 -c 'import secrets; print(secrets.token_hex(16))' 2>/dev/null)" && [ -n "$gen" ] || die "cannot draw a launch generation"
  : > "$BOX_DIR/launch.log" || die "cannot reset the launch log"
  printf '%s\n' "$gen" > "$BOX_DIR/generation" || die "cannot record the launch generation"
  sha="$(write_shims "$BOX_DIR" "$HOME_ISO" "$SCRATCH" "$MOUNT" "$GIT_COMMON" "$rt" "$real_bin" "$BOX_DIR/box.sb" "$CRED_SRC" "$CRED_FILE" "$gen")"
  # Prove the profile parses before the probes try to read meaning into failures.
  run_in /usr/bin/true 2>"$BOX_DIR/probe.err" || die "the sandbox profile did not apply: $(tr '\n' ' ' < "$BOX_DIR/probe.err" | cut -c1-200)"
  probes
  [ -z "$PROBE_FAIL" ] || die "containment self-check failed — $PROBE_FAIL"
  printf 'backend\t%s\nprofile_sha\t%s\npath_prefix\t%s\nacpx_flags\t--no-terminal --no-fs\n' "$b" "$sha" "$BOX_DIR/bin"
}

cmd_launched() {
  local dir="" sha gen
  [ "${1:-}" = --dir ] && [ -n "${2:-}" ] || usage
  dir="$2"
  [ -f "$dir/box.sb" ] && [ -f "$dir/launch.log" ] && [ -f "$dir/generation" ] || { echo "box.sh: the provider was never launched through the containment shim" >&2; exit 1; }
  sha="$(sha_of "$dir/box.sb")"; gen="$(cat "$dir/generation" 2>/dev/null)"
  [ -n "$gen" ] || { echo "box.sh: no launch generation is recorded for this preparation" >&2; exit 1; }
  grep -q " sha=$sha gen=$gen\$" "$dir/launch.log" || { echo "box.sh: no launch through the shim under this preparation's profile and generation" >&2; exit 1; }
}

[ "$#" -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  supports) cmd_supports "$@" ;;
  prepare)  cmd_prepare "$@" ;;
  client-check) cmd_client_check "$@" ;;
  launched) cmd_launched "$@" ;;
  *) usage ;;
esac
